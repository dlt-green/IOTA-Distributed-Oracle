import assert from 'node:assert/strict';
import test from 'node:test';
import * as v from 'valibot';

test('record validation errors with inherited property names can be flattened safely', () => {
  const result = v.safeParse(v.record(v.string(), v.number()), JSON.parse('{"toString":"invalid","valueOf":"invalid","hasOwnProperty":"invalid"}'));
  assert.equal(result.success, false);
  assert.doesNotThrow(() => v.flatten(result.issues!));
});
