import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { createRequire } from 'node:module';
import { gzipSync } from 'node:zlib';
import http from 'node:http';

const require = createRequire(import.meta.url);
const proxyaddr = require('proxy-addr');
const qs = require('qs');

test('mapped IPv6 trust prefixes cannot trust arbitrary IPv4 clients', () => {
  const valid = proxyaddr.compile(['10.0.0.0/8']);
  assert.equal(valid('10.1.2.3', 0), true);
  assert.equal(valid('203.0.113.7', 0), false);
  try {
    const malformed = proxyaddr.compile(['::ffff:10.0.0.0/8']);
    assert.equal(malformed('203.0.113.7', 0), false);
  } catch (error) {
    if (error instanceof assert.AssertionError) throw error;
    // Rejecting the malformed trust configuration also fails closed.
    assert.ok(error instanceof Error);
  }
});

test('query serialization handles hostile object methods without an uncaught TypeError', () => {
  const input = qs.parse('x[constructor][isBuffer]=not-callable', { plainObjects: true });
  assert.doesNotThrow(() => qs.stringify(input));
  assert.doesNotThrow(() => qs.stringify({ a: [{ toString: 'not-callable' }] }, { arrayFormat: 'comma' }));
});

test('body parser rejects an invalid size limit rather than disabling enforcement', () => {
  assert.throws(() => express.json({ limit: 'invalid-size' }));
});

test('compressed request handling stays available after a malformed gzip body', async t => {
  const app = express();
  app.use(express.json({ limit: '2mb' }));
  app.post('/input', (req, res) => { res.json(req.body); });
  app.get('/health', (_req, res) => { res.json({ ok: true }); });
  app.use((_error: unknown, _req: any, res: any, _next: any) => { res.sendStatus(400); });
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(r => server.once('listening', r));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const port = (server.address() as any).port;
  const post = (body: Buffer) => new Promise<number>((resolve, reject) => {
    const request = http.request({ hostname: '127.0.0.1', port, path: '/input', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Encoding': 'gzip', 'Content-Length': body.length } }, response => {
      response.resume(); response.once('end', () => resolve(response.statusCode!));
    });
    request.setTimeout(2000, () => request.destroy(new Error('fixture timeout')));
    request.once('error', reject); request.end(body);
  });
  assert.equal(await post(gzipSync(Buffer.from('{"ok":true}'))), 200);
  const malformed = Buffer.concat([gzipSync(Buffer.from('{}')), Buffer.from([0, 0x41, 0x42, 0x43])]);
  const status = await post(malformed);
  assert.ok(status === 200 || status === 400);
  await new Promise(r => setTimeout(r, 30));
  const health = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(2000) });
  assert.equal(health.status, 200);
});
