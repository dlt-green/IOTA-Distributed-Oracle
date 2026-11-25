import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { buildNoCommitDiagnostic } from "../src/noCommitDiagnostic";

const context = {
  nodeAddress: "0x123", nodeId: "1", taskId: "0x456", round: 2,
  taskType: "GET_JSON_CANONICAL", templateId: 3, reasonCode: 1, elapsedMs: 42,
};

test("public diagnostics discard response bodies and all URL representations", () => {
  const secret = "PRIVATE_RESPONSE_SECRET";
  for (const errMsg of [
    `HTTP 404 Not Found: <html>${secret}</html>`,
    `Invalid JSON response: Unexpected token '${secret}'`,
    `LLM HTTP 500: {"token":"${secret}"}`,
    `Invalid LLM JSON envelope: ${secret}`,
    `fetch failed https://user:${secret}@internal.example/admin?token=${secret}#fragment`,
    `unknown error https%3A%2F%2Finternal.example%2F${secret}`,
    `unknown error\n{"target":"http://internal.example/${secret}"}`,
  ]) {
    // Even stale callers passing payloadJson must not restore the old URL field.
    const input = { ...context, errMsg, payloadJson: {
      request: { url: `http://internal.example/${secret}` },
      source: { url: `https://internal.example/?token=${secret}`, kind: secret },
      url: `http://internal.example/${secret}`,
    } };
    const serialized = buildNoCommitDiagnostic(input);
    const diagnostic = JSON.parse(serialized);
    assert.equal(diagnostic.target, null);
    assert.ok(!serialized.includes(secret));
    assert.ok(!serialized.includes("internal.example"));
    assert.ok(!serialized.includes("<html>"));
    assert.ok(["http_error", "json_error", "execution_error"].includes(diagnostic.error_message));
  }
});

test("safe failure categories and task correlation remain available", () => {
  for (const [errMsg, errorClass, stage] of [
    ["TASK_HTTP_404", "http_error", "input_fetch"],
    ["TASK_FETCH_TIMEOUT", "timeout", "input_fetch"],
    ["Invalid JSON response: secret", "json_error", "input_validation"],
    ["unrecognized secret", "execution_error", "task_execute"],
  ]) {
    const result = JSON.parse(buildNoCommitDiagnostic({ ...context, errMsg }));
    assert.equal(result.schema, "oracle_no_commit_diag_v1");
    assert.equal(result.task_id, context.taskId);
    assert.equal(result.node_address, context.nodeAddress);
    assert.equal(result.round, context.round);
    assert.equal(result.elapsed_ms, 42);
    assert.equal(result.error_class, errorClass);
    assert.equal(result.error_message, errorClass);
    assert.equal(result.stage, stage);
    assert.equal(result.target, null);
  }
});

test("assignment failure publishes the sanitized diagnostic, not the raw error", () => {
  const source = readFileSync(new URL("../src/handlers/assigned.ts", import.meta.url), "utf8");
  assert.match(source, /import \{ buildNoCommitDiagnostic \} from "\.\.\/noCommitDiagnostic"/);
  assert.match(source, /const diagnosticPayload = buildNoCommitDiagnostic\(/);
  assert.match(source, /publishNoCommit\(\{[^}]*message: diagnosticPayload,/s);
  assert.doesNotMatch(source, /function buildNoCommitDiagnostic|pickTaskTarget|truncateForDiagnostic/);
});
