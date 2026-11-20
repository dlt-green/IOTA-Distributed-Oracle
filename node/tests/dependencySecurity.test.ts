import assert from 'node:assert/strict';
import test from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const FormData = require('form-data');

test('multipart field names and filenames cannot inject additional header lines', () => {
  const form = new FormData();
  form.append('name"\r\nX-Injected: yes\r\nname="', 'value');
  form.append('file', Buffer.from('content'), { filename: 'name"\r\nX-Injected: yes\r\nfilename="' });
  const body = form.getBuffer().toString('utf8');
  assert.doesNotMatch(body, /\r\nX-Injected:/);
  assert.match(body, /value/);
});
