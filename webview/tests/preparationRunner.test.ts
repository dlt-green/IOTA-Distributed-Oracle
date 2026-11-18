import assert from 'node:assert/strict';
import test from 'node:test';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { createPreparationRunner, preparationLimit, blockedDestinations } from '../server/preparationRunner.js';
import { createAuditFile } from '../server/auditFile.js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

function child() { return Object.assign(new EventEmitter(), { stdout: new PassThrough(), stderr: new PassThrough() }) as any; }
function fixture(limit = 1, timeoutMs = 1000) {
  const events: any[] = []; const terminated: string[] = [];
  const run = createPreparationRunner({ limit, timeoutMs: () => timeoutMs,
    terminate: (_child, reason) => { terminated.push(reason); }, emit: entry => { events.push(entry); } });
  return { run, events, terminated };
}

test('one global reservation covers different clients and asynchronous process creation', async () => {
  const f = fixture(); let spawn!: (child: any) => void; let secondSpawned = false;
  const first = f.run(() => new Promise(resolve => { spawn = resolve; }));
  await assert.rejects(f.run(async () => { secondSpawned = true; return child(); }), /PREPARATION_CAPACITY/);
  assert.equal(secondSpawned, false);
  const c = child(); spawn(c); await new Promise(r => setImmediate(r));
  c.emit('close', 0); await first;
  const next = child(); const second = f.run(async () => next); await new Promise(r => setImmediate(r)); next.emit('close', 0); await second;
  assert.equal(f.events[0].event, 'preparation_capacity_rejected');
});

test('factory failure releases the reserved slot', async () => {
  const f = fixture();
  await assert.rejects(f.run(async () => { throw new Error('spawn failed'); }), /spawn failed/);
  const c = child(); const pending = f.run(async () => c); await new Promise(r => setImmediate(r)); c.emit('close', 0); await pending;
});

test('timeout and child error do not release capacity until the actual close event', async () => {
  const f = fixture(1, 10), c = child();
  const pending = f.run(async () => c); const failed = assert.rejects(pending, /kill failed/);
  await new Promise(r => setTimeout(r, 20));
  assert.deepEqual(f.terminated, ['timeout']);
  c.emit('error', new Error('kill failed'));
  await assert.rejects(f.run(async () => child()), /PREPARATION_CAPACITY/);
  c.emit('close', null); await failed;
});

test('excessive child output is bounded and termination does not free a running slot', async () => {
  const f = fixture(), c = child();
  const pending = f.run(async () => c); const failed = assert.rejects(pending, /PREPARATION_OUTPUT_LIMIT/);
  await new Promise(r => setImmediate(r)); c.stdout.write('x'.repeat(1_000_001));
  assert.deepEqual(f.terminated, ['output_limit']);
  await assert.rejects(f.run(async () => child()), /PREPARATION_CAPACITY/);
  c.emit('close', null); await failed;
});

test('audit sink failure cannot bypass capacity rejection or strand process completion', async () => {
  const run = createPreparationRunner({ limit: 1, timeoutMs: () => 1000, terminate: () => {}, emit: () => { throw new Error('disk unavailable'); } });
  const c = child(); const pending = run(async () => c); await new Promise(r => setImmediate(r));
  await assert.rejects(run(async () => child()), /PREPARATION_CAPACITY/);
  c.stderr.write('ORACLE_TASK_DESTINATION_BLOCKED {"hostname":"blocked.example.com","code":"TASK_DESTINATION_FORBIDDEN"}\n');
  c.emit('close', 1); assert.equal((await pending).exitCode, 1);
});

test('blocked hostname diagnostics reach the rotating audit file without unrelated stderr', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'oracle-preparation-audit-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'audit.log');
  const audit = createAuditFile({ enabled: true, file, maxBytes: 10000, maxFiles: 2, stdout: false });
  const run = createPreparationRunner({ limit: 1, timeoutMs: () => 1000, terminate: () => {}, emit: audit.emit });
  const c = child(); const pending = run(async () => c); await new Promise(r => setImmediate(r));
  c.stderr.write('private provider diagnostic secret=do-not-log\nORACLE_TASK_DESTINATION_');
  c.stderr.write('BLOCKED {"hostname":"metadata.example.com","code":"TASK_DESTINATION_FORBIDDEN"}\n');
  c.emit('close', 1); await pending;
  const text = fs.readFileSync(file, 'utf8'); const entry = JSON.parse(text.trim());
  assert.equal(entry.hostname, 'metadata.example.com');
  assert.equal(entry.event, 'task_destination_blocked');
  assert.doesNotMatch(text, /secret|do-not-log|provider diagnostic/);
});

test('diagnostic parsing rejects paths, credentials and control characters and bounds records', () => {
  const record = (hostname: string) => `ORACLE_TASK_DESTINATION_BLOCKED ${JSON.stringify({ hostname, code: 'TASK_DESTINATION_FORBIDDEN' })}`;
  assert.deepEqual(blockedDestinations([record('host/path'), record('user:pass@host'), record('host\nforged'), record('host?secret=1')].join('\n')), []);
  assert.equal(blockedDestinations(Array.from({ length: 20 }, (_, i) => record(`blocked${i}.example.com`)).join('\n')).length, 8);
  assert.equal(blockedDestinations([record('example.com'), record('example.com')].join('\n')).length, 1);
});

test('configuration defaults to the existing limit of four and rejects invalid capacities', () => {
  assert.equal(preparationLimit({}), 4);
  assert.equal(preparationLimit({ WEBVIEW_PREPARATION_CONCURRENCY: '2' }), 2);
  for (const value of ['0', '-1', '33', '1.5', 'invalid', '']) assert.throws(() => preparationLimit({ WEBVIEW_PREPARATION_CONCURRENCY: value }));
});

test('actual preparation transport sends a redacted blocked host through child stderr into the audit sink', async () => {
  const f = fixture(1, 10000);
  const transport = new URL('../../client/src/taskHttp.ts', import.meta.url).href;
  const loader = new URL('../node_modules/tsx/dist/loader.mjs', import.meta.url).href;
  const script = `import {createTaskHttpClient} from ${JSON.stringify(transport)};
    try { await createTaskHttpClient()({url:'http://user:password@127.0.0.1/private?token=secret'}); }
    catch(error) { console.log(JSON.stringify({error:error.message})); process.exitCode=1; }`;
  const result = await f.run(async () => spawn(process.execPath, ['--import', loader, '--input-type=module', '-e', script], {
    env: { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, ORACLE_PREPARE_ONLY: '1' },
  }));
  assert.equal(result.exitCode, 1);
  assert.equal(JSON.parse(result.stdout).error, 'TASK_URL_FORBIDDEN');
  assert.equal(f.events[0].hostname, '127.0.0.1');
  assert.equal(f.events[0].event, 'task_destination_blocked');
  assert.doesNotMatch(JSON.stringify(f.events), /password|secret|token|private/);
});
