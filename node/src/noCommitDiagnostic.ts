// Raw failure details belong in operator logs, never in the public diagnostic.
function inferDiagnosticStage(taskType: string, errMsg: string): string {
  const msg = errMsg.toLowerCase();
  if (msg.includes("missing payload.") || msg.includes("missing template_id") || msg.includes("invalid ") || msg.includes("unsupported task type")) {
    return "input_validation";
  }
  if (msg.includes("http ") || /^task_http_[1-5]\d{2}$/.test(msg) || msg.includes("timeout") || msg.includes("fetch") || msg.includes("download")) {
    return "input_fetch";
  }
  if (msg.includes("json response") || msg.includes("parse") || msg.includes("schema")) {
    return "parse_or_schema";
  }
  if (msg.includes("ipfs")) {
    return "storage_upload";
  }
  if (msg.includes("llm") || taskType.startsWith("LLM_")) {
    return "llm_call";
  }
  return "task_execute";
}

function inferErrorClass(errMsg: string): string {
  const msg = errMsg.toLowerCase();
  if (msg.includes("timeout")) return "timeout";
  if (msg.includes("http ") || /^task_http_[1-5]\d{2}$/.test(msg)) return "http_error";
  if (msg.includes("schema")) return "schema_error";
  if (msg.includes("json")) return "json_error";
  if (msg.includes("ipfs")) return "ipfs_error";
  if (msg.includes("llm")) return "llm_error";
  if (msg.includes("missing ") || msg.includes("invalid ")) return "validation_error";
  return "execution_error";
}

export function buildNoCommitDiagnostic(params: {
  nodeAddress: string;
  nodeId: string;
  taskId: string;
  round: number;
  taskType: string;
  templateId: number;
  reasonCode: number;
  errMsg: string;
  elapsedMs: number;
}): string {
  const {
    nodeAddress,
    nodeId,
    taskId,
    round,
    taskType,
    templateId,
    reasonCode,
    errMsg,
    elapsedMs,
  } = params;

  const diagnostic = {
    schema: "oracle_no_commit_diag_v1",
    node_address: nodeAddress,
    node_id: nodeId,
    task_id: taskId,
    round,
    task_type: taskType,
    template_id: templateId,
    stage: inferDiagnosticStage(taskType, errMsg),
    error_class: inferErrorClass(errMsg),
    reason_code: reasonCode,
    // Keep v1 compatibility without forwarding any free-form failure detail.
    error_message: inferErrorClass(errMsg),
    target: null,
    elapsed_ms: Math.max(0, Math.floor(elapsedMs)),
    emitted_at: new Date().toISOString(),
  };

  return JSON.stringify(diagnostic);
}

