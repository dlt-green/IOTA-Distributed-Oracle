import assert from 'node:assert/strict';
import test, { after } from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { Ed25519Keypair } from '@iota/iota-sdk/keypairs/ed25519';
import { Transaction, TransactionDataBuilder } from '@iota/iota-sdk/transactions';
import { signAndExecuteWithLockRetry } from '../src/txRetry';
import { journalPath, readJournal, writeJournal } from '../src/daemonJournal';

const storage = mkdtempSync(join(tmpdir(), 'oracle-replay-'));
const before = process.env.STORAGE_DIR;
process.env.STORAGE_DIR = storage;
after(() => { if (before === undefined) delete process.env.STORAGE_DIR; else process.env.STORAGE_DIR = before;
  rmSync(storage, { recursive: true, force: true }); });

async function fixture() {
  const signer = new Ed25519Keypair();
  const owner = signer.toIotaAddress();
  const path = journalPath('transaction', owner);
  const calls: any[] = [];
  let signs = 0;
  const originalSign = signer.signTransaction.bind(signer);
  signer.signTransaction = async bytes => { signs++; return originalSign(bytes); };
  const factory = () => { const t = new Transaction(); t.setGasBudget(50); t.setGasPrice(1); return t; };
  const client: any = {
    getCoins: async () => ({ data: [{ coinObjectId: '0x1', balance: '100' }] }),
    getObject: async () => ({ data: { objectId: '0x1', version: '1', digest: '11111111111111111111111111111111', content: { fields: { balance: '100' } } } }),
    executeTransactionBlock: async (args: any) => {
      calls.push(args);
      const saved = readJournal<any>(path);
      assert.equal(saved.signed.bytes, args.transactionBlock);
      assert.equal(saved.signed.signature, args.signature);
      throw new Error('submission response lost');
    },
    getTransactionBlock: async ({ digest }: any) => { throw new Error(`Could not find the referenced transaction [${digest}]`); },
  };
  const run = (label = 'scheduler') => signAndExecuteWithLockRetry({ client, signer, transactionFactory: factory, label, maxAttempts: 1 });
  await assert.rejects(run(), /submission response lost/);
  const pending = readJournal<any>(path);
  assert.equal(TransactionDataBuilder.getDigestFromBytes(Buffer.from(pending.signed.bytes, 'base64')), pending.digest);
  return { run, pending, path, calls, client, signer, signs: () => signs };
}

test('lost submission is recovered from persisted authorization without rebuilding or signing', async () => {
  const f = await fixture();
  f.client.getCoins = async () => { throw new Error('must not refresh gas'); };
  f.signer.signTransaction = async () => { throw new Error('must not sign again'); };
  f.client.executeTransactionBlock = async (args: any) => {
    f.calls.push(args);
    return { digest: f.pending.digest, checkpoint: '10', effects: { status: { status: 'success' } } };
  };
  const result = await f.run();
  assert.equal(result.digest, f.pending.digest);
  assert.equal(f.calls[0].transactionBlock, f.calls[1].transactionBlock);
  assert.equal(f.calls[0].signature, f.calls[1].signature);
  assert.equal(f.signs(), 1);
  assert.deepEqual(readJournal(f.path), { effects: result.effects });
});

test('already executed transaction is recovered by lookup without retransmission', async () => {
  const f = await fixture();
  f.client.getTransactionBlock = async () => ({ digest: f.pending.digest, checkpoint: '10', effects: { status: { status: 'success' } } });
  await f.run(); assert.equal(f.calls.length, 1);
});

test('a fresh process can replay the journal without access to the private key', async () => {
  const f = await fixture();
  const script = `
    import assert from 'node:assert/strict';
    import { readFileSync } from 'node:fs';
    import { Transaction } from '@iota/iota-sdk/transactions';
    import { signAndExecuteWithLockRetry } from './src/txRetry.ts';
    const pending = JSON.parse(readFileSync(process.env.REPLAY_TEST_PATH, 'utf8'));
    const signer = {getPublicKey: () => ({toIotaAddress: () => pending.signed.owner}),
      signTransaction: () => {throw new Error('unexpected signing');}};
    const client = {
      getTransactionBlock: async () => {throw new Error('Could not find the referenced transaction [' + pending.digest + ']');},
      executeTransactionBlock: async args => {
        assert.equal(args.transactionBlock, pending.signed.bytes);
        assert.equal(args.signature, pending.signed.signature);
        return {digest: pending.digest, checkpoint: '1', effects: {status: {status: 'success'}}};
      }
    };
    const transactionFactory = () => {const t = new Transaction();t.setGasBudget(50);t.setGasPrice(1);return t;};
    await signAndExecuteWithLockRetry({client, signer, transactionFactory, label: 'scheduler'});
    console.log('recovered');
  `;
  const output = execFileSync(process.execPath, ['--import', 'tsx', '--input-type=module', '-e', script], {
    cwd: new URL('..', import.meta.url), env: { ...process.env, REPLAY_TEST_PATH: f.path }, timeout: 30000,
  });
  assert.match(output.toString(), /recovered/);
  assert.equal(readJournal<any>(f.path).digest, undefined);
});

test('checkpoint wait timeout retains signed bytes until lookup confirms the result', async () => {
  const f = await fixture();
  const result = { digest: f.pending.digest, effects: { status: { status: 'success' } } };
  f.client.executeTransactionBlock = async () => result;
  f.client.waitForTransaction = async () => { throw new Error('checkpoint timeout'); };
  await assert.rejects(f.run(), /checkpoint timeout/);
  assert.deepEqual(readJournal<any>(f.path).signed, f.pending.signed);
  f.client.getTransactionBlock = async () => ({ ...result, checkpoint: '1' });
  await f.run(); assert.equal(readJournal<any>(f.path).digest, undefined);
});

test('legacy journal remains blocked when absent and resolves when found', async () => {
  const f = await fixture(); delete f.pending.signed; writeJournal(f.path, f.pending);
  await assert.rejects(f.run(), /LEGACY_JOURNAL_NO_SIGNED_TRANSACTION/);
  assert.equal(f.calls.length, 1);
  f.client.getTransactionBlock = async () => ({ effects: { status: { status: 'success' } }, checkpoint: '1' });
  await f.run(); assert.equal(readJournal<any>(f.path).digest, undefined);
});

test('lookup transport failures do not trigger replay or discard pending data', async () => {
  const f = await fixture();
  f.client.getTransactionBlock = async () => { throw new Error('HTTP 503'); };
  await assert.rejects(f.run(), /reason=LOOKUP_FAILED/);
  assert.deepEqual(readJournal(f.path), f.pending); assert.equal(f.calls.length, 1);
});

test('corrupt bytes, signature, owner and journal context prevent retransmission', async () => {
  for (const field of ['bytes', 'signature', 'owner', 'journal', 'digest']) {
    const f = await fixture();
    if (field === 'digest') f.pending.digest = 'wrong'; else f.pending.signed[field] = 'wrong';
    writeJournal(f.path, f.pending);
    await assert.rejects(f.run(), /SIGNED_DATA_INVALID/);
    assert.equal(f.calls.length, 1); assert.deepEqual(readJournal(f.path), f.pending);
  }
});

test('ambiguous replay errors retain authorization and persistent backoff', async () => {
  const f = await fixture();
  f.client.executeTransactionBlock = async () => { throw new Error('is not available for consumption, current version'); };
  await assert.rejects(f.run(), /REPLAY_FAILED/);
  const saved = readJournal<any>(f.path);
  assert.deepEqual(saved.signed, f.pending.signed); assert.equal(saved.replayAttempts, 1);
  await assert.rejects(f.run(), /REPLAY_BACKOFF/);
  assert.deepEqual(readJournal(f.path), saved);
});

test('recovered previous workflow never satisfies a different operation', async () => {
  const f = await fixture();
  f.client.executeTransactionBlock = async () => ({ digest: f.pending.digest, checkpoint: '1', effects: { status: { status: 'success' } } });
  await assert.rejects(f.run('register'), /PREVIOUS_TRANSACTION_RESOLVED_RETRY_CURRENT_OPERATION/);
  assert.equal(readJournal<any>(f.path).digest, undefined);
});

test('definitive replay failure clears pending authorization but preserves effects', async () => {
  const f = await fixture();
  const effects = { status: { status: 'failure', error: 'MoveAbort' } };
  f.client.executeTransactionBlock = async () => ({ digest: f.pending.digest, effects });
  await assert.rejects(f.run(), /PREVIOUS_TRANSACTION_FAILED_ON_CHAIN/);
  assert.deepEqual(readJournal(f.path), { effects });
});

test('response mismatch or missing effects never clears a pending replay', async () => {
  for (const result of [{ digest: 'wrong', effects: { status: { status: 'success' } } }, {}]) {
    const f = await fixture(); f.client.executeTransactionBlock = async () => result;
    await assert.rejects(f.run(), /REPLAY_UNCONFIRMED/);
    assert.equal(readJournal<any>(f.path).digest, f.pending.digest);
  }
});
