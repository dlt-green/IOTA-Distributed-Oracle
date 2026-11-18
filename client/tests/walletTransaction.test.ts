import assert from 'node:assert/strict';
import test from 'node:test';
import { Transaction } from '@iota/iota-sdk/transactions';
import { serializeTransactionForWallet } from '../src/walletTransaction.js';

test('wallet preparation JSON round-trips with SDK 1.17 without gas selection, RPC or signing', async () => {
  const tx = new Transaction();
  tx.setSender('0x1');
  tx.setGasBudget(50000000);
  tx.moveCall({ target: '0x2::oracle_tasks::create_task', arguments: [tx.object('0x3'), tx.pure.u64(123)] });
  const client = new Proxy({} as any, { get: () => { throw new Error('Preparation must not query or sign'); } });
  const json = await serializeTransactionForWallet(tx, client);
  assert.equal(JSON.parse(json).version, 2);
  const restored = Transaction.from(json).getData();
  assert.deepEqual(restored.inputs, tx.getData().inputs);
  assert.equal(restored.sender, tx.getData().sender);
  assert.equal(restored.commands[0].MoveCall?.function, 'create_task');
  assert.deepEqual(restored.commands[0].MoveCall?.arguments.map(arg => arg.Input), [0, 1]);
  assert.equal(restored.gasData.payment, null);
  assert.equal(restored.gasData.budget, '50000000');
});

test('wallet round-trip preserves executable Move-call bytes', async () => {
  const tx = new Transaction();
  tx.moveCall({ target: '0x2::oracle_tasks::create_task', arguments: [
    tx.objectRef({ objectId: '0x3', version: '1', digest: '11111111111111111111111111111111' }), tx.pure.u64(123),
  ] });
  const client = new Proxy({} as any, { get: () => { throw new Error('No RPC expected'); } });
  const json = await serializeTransactionForWallet(tx, client);
  assert.deepEqual(await Transaction.from(json).build({ onlyTransactionKind: true, client }),
    await tx.build({ onlyTransactionKind: true, client }));
});
