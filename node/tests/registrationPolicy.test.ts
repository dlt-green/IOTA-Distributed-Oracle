import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveRegisterMode, validateRegistrationState } from '../src/registrationPolicy.js';

test('testnet/mainnet require prod and reject an explicit dev override', () => {
  for (const network of ['test', 'testnet', 'main', 'mainnet', ' TESTNET ']) {
    assert.equal(resolveRegisterMode(network, ''), 'prod');
    assert.equal(resolveRegisterMode(network, 'prod'), 'prod');
    assert.throws(() => resolveRegisterMode(network, 'dev'), /forbidden/);
  }
});
test('devnet/localnet still support cap-free registration; unspecified networks fail closed', () => {
  for (const network of ['dev', 'devnet', 'local', 'localnet']) assert.equal(resolveRegisterMode(network, ''), 'dev');
  for (const network of ['', 'typo']) assert.throws(() => resolveRegisterMode(network, 'dev'), /IOTA_NETWORK/);
  assert.throws(() => resolveRegisterMode('testnet', 'typo'), /REGISTER_MODE/);
  assert.equal(resolveRegisterMode('testnet', 'off'), 'off');
});
test('registration refuses mixed deployments, wrong network and unreadable State', async () => {
  const before = process.env.IOTA_NETWORK;
  process.env.IOTA_NETWORK = 'testnet';
  const fixture = (type = '0x123::systemState::State', network = 'testnet') => ({
    getObject: async () => ({ data: { type, content: { dataType: 'moveObject', fields: {
      network: [...Buffer.from(network)], node_registry_id: '0x456',
    } } } }),
  }) as any;
  try {
    assert.equal(await validateRegistrationState(fixture(), '0x1', '0x123'), '0x456');
    assert.equal(await validateRegistrationState(fixture(), '0x1', '0x123', '0x0456'), '0x456');
    await assert.rejects(validateRegistrationState(fixture(), '0x1', '0x999'), /package\/State mismatch/);
    await assert.rejects(validateRegistrationState(fixture(), '0x1', '0x123', '0x999'), /State\/NodeRegistry mismatch/);
    await assert.rejects(validateRegistrationState(fixture(undefined, 'devnet'), '0x1', '0x123'), /network/);
    await assert.rejects(validateRegistrationState(fixture('0x123::other::State'), '0x1', '0x123'), /package\/State mismatch/);
    await assert.rejects(validateRegistrationState({ getObject: async () => { throw new Error('RPC unavailable'); } } as any, '0x1', '0x123'), /RPC unavailable/);
  } finally {
    if (before === undefined) delete process.env.IOTA_NETWORK; else process.env.IOTA_NETWORK = before;
  }
});
