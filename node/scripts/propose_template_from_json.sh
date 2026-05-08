#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[error] line $LINENO: command failed: $BASH_COMMAND" >&2' ERR

TEMPLATE_JSON=""
ENV_FILE=""
TEMPLATE_ID_OVERRIDE=""
ALLOW_DUPLICATE=0
PROPOSAL_TIMEOUT_MS="${PROPOSAL_TIMEOUT_MS:-600000}"
GAS_BUDGET="${GAS_BUDGET:-50000000}"
CONTROLLER_ADDRESS_OR_ALIAS="${CONTROLLER_ADDRESS_OR_ALIAS:-}"
SYSTEM_PKG="${SYSTEM_PKG:-${ORACLE_SYSTEM_PACKAGE_ID:-}}"
STATE_ID="${STATE_ID:-${ORACLE_STATE_ID:-}}"
NODE_REGISTRY_ID="${NODE_REGISTRY_ID:-${ORACLE_NODE_REGISTRY_ID:-}}"
CONTROLLER_CAP_ID="${CONTROLLER_CAP_ID:-}"
CLOCK_ID="${CLOCK_ID:-0x6}"
NETWORK=""

usage() {
  cat <<'EOF'
Propose a new task template from a JSON file.
The proposal is created on-chain and remains pending approval.

Usage:
  ./scripts/propose_template_from_json.sh --file <template_or_example.json> [options]

Options:
  --file <path>                 JSON file containing template_id and type
  --template-id <u64>           Optional override when JSON does not include template_id
  --allow-duplicate             Allow proposing even if template is already approved/pending
  --env-file <path>             Optional env file to load first (default: ./ .env if present)
  --controller <addr_or_alias>  Controller address/alias that owns controller cap
  --proposal-timeout-ms <u64>   Proposal timeout in milliseconds (default: 600000)
  --gas-budget <u64>            Gas budget (default: 50000000)
  --system-pkg <id>             System package id
  --state-id <id>               Oracle state object id
  --node-registry-id <id>       Oracle node registry object id
  --controller-cap-id <id>      Oracle controller cap id
  --clock-id <id>               Clock object id (default: 0x6)
  --network <name>              Network for listTemplates check (devnet|testnet|mainnet)
  -h, --help                    Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --file" >&2; usage; exit 1; }
      TEMPLATE_JSON="$1"
      ;;
    --template-id)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --template-id" >&2; usage; exit 1; }
      TEMPLATE_ID_OVERRIDE="$1"
      ;;
    --allow-duplicate)
      ALLOW_DUPLICATE=1
      ;;
    --env-file)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --env-file" >&2; usage; exit 1; }
      ENV_FILE="$1"
      ;;
    --controller)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --controller" >&2; usage; exit 1; }
      CONTROLLER_ADDRESS_OR_ALIAS="$1"
      ;;
    --proposal-timeout-ms)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --proposal-timeout-ms" >&2; usage; exit 1; }
      PROPOSAL_TIMEOUT_MS="$1"
      ;;
    --gas-budget)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --gas-budget" >&2; usage; exit 1; }
      GAS_BUDGET="$1"
      ;;
    --system-pkg)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --system-pkg" >&2; usage; exit 1; }
      SYSTEM_PKG="$1"
      ;;
    --state-id)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --state-id" >&2; usage; exit 1; }
      STATE_ID="$1"
      ;;
    --node-registry-id)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --node-registry-id" >&2; usage; exit 1; }
      NODE_REGISTRY_ID="$1"
      ;;
    --controller-cap-id)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --controller-cap-id" >&2; usage; exit 1; }
      CONTROLLER_CAP_ID="$1"
      ;;
    --clock-id)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --clock-id" >&2; usage; exit 1; }
      CLOCK_ID="$1"
      ;;
    --network)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --network" >&2; usage; exit 1; }
      NETWORK="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[error] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"

if [[ -z "$ENV_FILE" && -f "${PROJECT_DIR}/.env" ]]; then
  ENV_FILE="${PROJECT_DIR}/.env"
fi
if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || { echo "[error] env file not found: $ENV_FILE" >&2; exit 1; }
  for k in \
    DEVNET_IOTA_RPC_URL DEVNET_IOTA_RPC_URLS DEVNET_IOTA_CLOCK_ID DEVNET_ORACLE_TASKS_PACKAGE_ID DEVNET_ORACLE_SYSTEM_PACKAGE_ID DEVNET_ORACLE_STATE_ID DEVNET_ORACLE_NODE_REGISTRY_ID DEVNET_CONTROLLER_CAP_ID DEVNET_CONTROLLER_ADDRESS_OR_ALIAS DEVNET_ORACLE_CONTROLLER_ADDRESS \
    TESTNET_IOTA_RPC_URL TESTNET_IOTA_RPC_URLS TESTNET_IOTA_CLOCK_ID TESTNET_ORACLE_TASKS_PACKAGE_ID TESTNET_ORACLE_SYSTEM_PACKAGE_ID TESTNET_ORACLE_STATE_ID TESTNET_ORACLE_NODE_REGISTRY_ID TESTNET_CONTROLLER_CAP_ID TESTNET_CONTROLLER_ADDRESS_OR_ALIAS TESTNET_ORACLE_CONTROLLER_ADDRESS \
    MAINNET_IOTA_RPC_URL MAINNET_IOTA_RPC_URLS MAINNET_IOTA_CLOCK_ID MAINNET_ORACLE_TASKS_PACKAGE_ID MAINNET_ORACLE_SYSTEM_PACKAGE_ID MAINNET_ORACLE_STATE_ID MAINNET_ORACLE_NODE_REGISTRY_ID MAINNET_CONTROLLER_CAP_ID MAINNET_CONTROLLER_ADDRESS_OR_ALIAS MAINNET_ORACLE_CONTROLLER_ADDRESS
  do
    unset "$k" || true
  done
  set -a
  # shellcheck disable=SC1090
  source <(sed 's/\r$//' "$ENV_FILE")
  set +a
fi

NETWORK="$(echo "${NETWORK:-${IOTA_NETWORK:-${ORACLE_NETWORK:-${NODE_NETWORK:-${NODE_1_NETWORK:-}}}}}" | tr '[:upper:]' '[:lower:]' | xargs)"
case "$NETWORK" in
  "") ;;
  dev|devent|local|localnet) NETWORK="devnet" ;;
  test) NETWORK="testnet" ;;
  main) NETWORK="mainnet" ;;
esac
[[ -z "$NETWORK" || "$NETWORK" == "devnet" || "$NETWORK" == "testnet" || "$NETWORK" == "mainnet" ]] || {
  echo "[error] invalid --network value: ${NETWORK}. Use devnet|testnet|mainnet" >&2
  exit 1
}
if [[ -n "$NETWORK" ]]; then
  export IOTA_NETWORK="$NETWORK"
fi

NET_PREFIX=""
if [[ -n "$NETWORK" ]]; then
  NET_PREFIX="$(echo "$NETWORK" | tr '[:lower:]' '[:upper:]')"
fi

get_prefixed_env() {
  local key="$1"
  if [[ -n "$NET_PREFIX" ]]; then
    local prefixed="${NET_PREFIX}_${key}"
    local pv="${!prefixed:-}"
    if [[ -n "$pv" ]]; then
      printf "%s" "$pv"
      return 0
    fi
  fi
  printf "%s" "${!key:-}"
}

network_system_state_report() {
  case "$NETWORK" in
    devnet) printf "%s" "${REPO_ROOT}/move/devnet/oracle_system_state_devnet/devnet_system_state.txt" ;;
    testnet) printf "%s" "${REPO_ROOT}/move/testnet/oracle_system_state_testnet/testnet_system_state.txt" ;;
    *) return 1 ;;
  esac
}

if [[ -z "$SYSTEM_PKG" ]]; then
  SYSTEM_PKG="$(get_prefixed_env ORACLE_SYSTEM_PACKAGE_ID)"
fi
if [[ -z "$STATE_ID" ]]; then
  STATE_ID="$(get_prefixed_env ORACLE_STATE_ID)"
fi
if [[ -z "$NODE_REGISTRY_ID" ]]; then
  NODE_REGISTRY_ID="$(get_prefixed_env ORACLE_NODE_REGISTRY_ID)"
fi
if [[ -z "$CONTROLLER_CAP_ID" ]]; then
  CONTROLLER_CAP_ID="$(get_prefixed_env CONTROLLER_CAP_ID)"
fi
if [[ -z "$CLOCK_ID" || "$CLOCK_ID" == "0x6" ]]; then
  CLOCK_ID="$(get_prefixed_env IOTA_CLOCK_ID)"
  CLOCK_ID="${CLOCK_ID:-0x6}"
fi
if [[ -z "$CONTROLLER_ADDRESS_OR_ALIAS" ]]; then
  CONTROLLER_ADDRESS_OR_ALIAS="$(get_prefixed_env CONTROLLER_ADDRESS_OR_ALIAS)"
fi
if [[ -z "$CONTROLLER_ADDRESS_OR_ALIAS" ]]; then
  CONTROLLER_ADDRESS_OR_ALIAS="$(get_prefixed_env ORACLE_CONTROLLER_ADDRESS)"
fi

[[ -n "$TEMPLATE_JSON" ]] || { echo "[error] --file is required" >&2; usage; exit 1; }
[[ -f "$TEMPLATE_JSON" ]] || { echo "[error] JSON file not found: $TEMPLATE_JSON" >&2; exit 1; }
[[ -z "$TEMPLATE_ID_OVERRIDE" || "$TEMPLATE_ID_OVERRIDE" =~ ^[0-9]+$ ]] || { echo "[error] --template-id must be numeric" >&2; exit 1; }
[[ -n "$SYSTEM_PKG" ]] || { echo "[error] missing SYSTEM_PKG / ORACLE_SYSTEM_PACKAGE_ID" >&2; exit 1; }
[[ -n "$STATE_ID" ]] || { echo "[error] missing STATE_ID / ORACLE_STATE_ID" >&2; exit 1; }
[[ -n "$NODE_REGISTRY_ID" ]] || { echo "[error] missing NODE_REGISTRY_ID / ORACLE_NODE_REGISTRY_ID" >&2; exit 1; }
[[ -n "$CONTROLLER_CAP_ID" ]] || { echo "[error] missing CONTROLLER_CAP_ID" >&2; exit 1; }
[[ -n "$CONTROLLER_ADDRESS_OR_ALIAS" ]] || { echo "[error] missing controller address/alias" >&2; exit 1; }
[[ "$PROPOSAL_TIMEOUT_MS" =~ ^[0-9]+$ ]] || { echo "[error] --proposal-timeout-ms must be numeric" >&2; exit 1; }
[[ "$GAS_BUDGET" =~ ^[0-9]+$ ]] || { echo "[error] --gas-budget must be numeric" >&2; exit 1; }

command -v iota >/dev/null 2>&1 || { echo "[error] iota CLI not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "[error] node not found" >&2; exit 1; }

sync_iota_cli_env() {
  local active_env=""
  active_env="$(iota client active-env 2>/dev/null | tr -d '\r' | xargs || true)"
  if [[ -n "$NETWORK" && "$active_env" != "$NETWORK" ]]; then
    echo "[info] switching iota client env: ${active_env:-<unset>} -> ${NETWORK}" >&2
    iota client switch --env "$NETWORK" >/dev/null
  fi
}

controller_cap_id_from_report() {
  local report_file="$1"
  [[ -f "$report_file" ]] || return 1
  node -e '
const fs = require("fs");
const text = fs.readFileSync(process.argv[1], "utf8");
const match = text.match(/ObjectID:\s*(0x[a-fA-F0-9]+)[\s\S]*?ObjectType:\s*(0x[a-fA-F0-9]+::systemState::ControllerCap)/);
if (match) process.stdout.write(match[1]);
' "$report_file"
}

read_object_type() {
  local object_id="$1"
  iota client object "$object_id" --json \
    | node -e '
const fs = require("fs");
const txt = fs.readFileSync(0, "utf8");
if (!txt.trim().startsWith("{")) process.exit(0);
const data = JSON.parse(txt);
const type = data?.data?.type ?? data?.type ?? data?.content?.type ?? "";
if (type) process.stdout.write(String(type));
'
}

validate_or_resolve_controller_cap() {
  local current_id="$1"
  local expected_type="${SYSTEM_PKG}::systemState::ControllerCap"
  local resolved_id="$current_id"
  local current_type=""
  local report_file=""

  report_file="$(network_system_state_report || true)"

  if [[ -n "$resolved_id" ]]; then
    current_type="$(read_object_type "$resolved_id" || true)"
  fi

  if [[ "$current_type" == "$expected_type" ]]; then
    printf "%s" "$resolved_id"
    return 0
  fi

  local report_id=""
  report_id="$(controller_cap_id_from_report "$report_file" || true)"
  if [[ -n "$report_id" ]]; then
    local report_type=""
    report_type="$(read_object_type "$report_id" || true)"
    if [[ "$report_type" == "$expected_type" ]]; then
      if [[ -n "$resolved_id" && "$resolved_id" != "$report_id" ]]; then
        echo "[warn] CONTROLLER_CAP_ID=${resolved_id} is not a ControllerCap for package ${SYSTEM_PKG} (type=${current_type:-unknown})" >&2
        echo "[info] using ControllerCap from publish report: ${report_id}" >&2
      fi
      printf "%s" "$report_id"
      return 0
    fi
  fi

  echo "[error] CONTROLLER_CAP_ID=${resolved_id:-<empty>} is invalid for ${expected_type}." >&2
  if [[ -n "$current_type" ]]; then
    echo "[error] current object type: ${current_type}" >&2
  fi
  if [[ -n "$report_id" ]]; then
    echo "[error] publish report candidate exists but could not be validated: ${report_id}" >&2
  fi
  echo "[error] update CONTROLLER_CAP_ID in your .env or rerun update_${NETWORK:-current}_envs.sh." >&2
  exit 1
}

FULL_JSON_PATH="$(cd "$(dirname "$TEMPLATE_JSON")" && pwd)/$(basename "$TEMPLATE_JSON")"
sync_iota_cli_env
CONTROLLER_CAP_ID="$(validate_or_resolve_controller_cap "$CONTROLLER_CAP_ID")"

current_proposal_counter() {
  iota client object "${STATE_ID}" --json \
    | node -e '
const fs = require("fs");
const txt = fs.readFileSync(0, "utf8");
const data = JSON.parse(txt);
function walk(x) {
  if (!x || typeof x !== "object") return undefined;
  if (Object.prototype.hasOwnProperty.call(x, "template_proposal_id")) return x.template_proposal_id;
  for (const v of Object.values(x)) {
    const out = walk(v);
    if (out !== undefined) return out;
  }
  return undefined;
}
const v = walk(data);
if (v === undefined || v === null || v === "") throw new Error("template_proposal_id not found");
process.stdout.write(String(v));
'
}

template_status() {
  local args=(--json)
  if [[ -n "$NETWORK" ]]; then
    args+=(--network "$NETWORK")
  fi
  args+=(--state-id "$STATE_ID")
  local output=""
  local attempt=1
  local max_attempts=3
  while (( attempt <= max_attempts )); do
    if output="$(cd "${PROJECT_DIR}" && npm exec -- tsx src/tools/listTemplates.ts "${args[@]}" 2>/dev/null)"; then
      if [[ -n "$output" ]]; then
        break
      fi
    fi
    if (( attempt == max_attempts )); then
      echo "[warn] unable to determine template status for template_id=$1 after ${max_attempts} attempts; continuing as none" >&2
      printf "%s" "none"
      return 0
    fi
    local backoff_ms=$(( attempt * 500 ))
    echo "[warn] template status lookup failed for template_id=$1, retrying in ${backoff_ms} ms" >&2
    sleep "$(awk "BEGIN { printf \"%.3f\", ${backoff_ms}/1000 }")"
    (( attempt += 1 ))
  done

  printf "%s" "$output" | node -e '
const fs = require("fs");
const templateId = Number(process.argv[1]);
const raw = fs.readFileSync(0, "utf8");
if (!raw.trim()) {
  process.stdout.write("none");
  process.exit(0);
}
const data = JSON.parse(raw);
const approved = Array.isArray(data?.approvedTemplates) ? data.approvedTemplates : [];
const pending = Array.isArray(data?.pendingProposals) ? data.pendingProposals : [];
if (approved.some((x) => Number(x?.templateId) === templateId)) {
  process.stdout.write("approved");
} else if (pending.some((x) => Number(x?.templateId) === templateId && String(x?.kind ?? "") === "upsert")) {
  process.stdout.write("pending");
} else {
  process.stdout.write("none");
}
' "$1"
}

PARSED_TEMPLATE="$(
  node -e '
const fs = require("fs");
const file = process.argv[1];
const templateIdOverrideRaw = process.argv[2];
const raw = fs.readFileSync(file, "utf8");
const j = JSON.parse(raw);
const t = (j && typeof j.template === "object" && !Array.isArray(j.template)) ? j.template : {};
const pick = (k) => (t[k] ?? j[k]);
const toInt = (v, d) => {
  if (v === undefined || v === null || v === "") return d;
  const n = Number(v);
  if (!Number.isFinite(n)) return d;
  return Math.trunc(n);
};
const taskType = String(pick("type") ?? "").trim();
if (!taskType) throw new Error("JSON must contain non-empty type");
let templateId = toInt(pick("template_id"), NaN);
const templateIdOverride = toInt(templateIdOverrideRaw, NaN);
if (Number.isFinite(templateIdOverride) && templateIdOverride > 0) templateId = templateIdOverride;
if (!Number.isFinite(templateId) || templateId <= 0) {
  throw new Error("JSON must contain numeric template_id (or use --template-id)");
}
const isStorage = taskType.toUpperCase() === "STORAGE";
const allowStorage = toInt(pick("allow_storage"), isStorage ? 1 : 0);
const minRetention = toInt(pick("min_retention_days"), allowStorage ? 30 : 0);
const maxRetention = toInt(pick("max_retention_days"), allowStorage ? 365 : 0);
const vals = [
  templateId,
  taskType,
  toInt(pick("is_enabled"), 1),
  toInt(pick("base_price_iota"), isStorage ? 0 : 1000000000),
  toInt(pick("scheduler_fee_iota"), 0),
  toInt(pick("max_input_bytes"), 8192),
  toInt(pick("max_output_bytes"), isStorage ? 10485760 : 8192),
  toInt(pick("included_download_bytes"), isStorage ? 10485760 : 8192),
  toInt(pick("price_per_download_byte_iota"), 0),
  allowStorage,
  minRetention,
  maxRetention,
  toInt(pick("price_per_retention_day_iota"), allowStorage ? 347034 : 0),
];
process.stdout.write(vals.join(" "));
  ' "$FULL_JSON_PATH" "$TEMPLATE_ID_OVERRIDE"
)"

read -r TEMPLATE_ID TASK_TYPE IS_ENABLED BASE_PRICE SCHEDULER_FEE MAX_INPUT MAX_OUTPUT INCLUDED_DOWNLOAD PRICE_PER_DOWNLOAD ALLOW_STORAGE MIN_RETENTION MAX_RETENTION PRICE_PER_RETENTION <<<"$PARSED_TEMPLATE"

if [[ "$ALLOW_DUPLICATE" -ne 1 ]]; then
  STATUS="$(template_status "$TEMPLATE_ID")"
  if [[ "$STATUS" == "approved" ]]; then
    if [[ "$NETWORK" == "devnet" ]]; then
      echo "[warn] template_id=${TEMPLATE_ID} appears already approved on state_id=${STATE_ID}, but devnet duplicate checks are advisory. Continuing."
    else
      echo "[skip] template_id=${TEMPLATE_ID} already approved. Use --allow-duplicate to force."
      exit 0
    fi
  fi
  if [[ "$STATUS" == "pending" ]]; then
    echo "[skip] template_id=${TEMPLATE_ID} already pending for upsert. Use --allow-duplicate to force."
    exit 0
  fi
fi

echo "[info] project: ${PROJECT_DIR}"
echo "[info] json: ${FULL_JSON_PATH}"
[[ -n "$NETWORK" ]] && echo "[info] network: ${NETWORK}"
echo "[info] template_id: ${TEMPLATE_ID}"
echo "[info] task_type: ${TASK_TYPE}"

CAP_OWNER_ADDRESS="$(
  iota client object "${CONTROLLER_CAP_ID}" --json \
    | node -e '
const fs = require("fs");
const txt = fs.readFileSync(0, "utf8");
const data = JSON.parse(txt);
const owner = data?.owner?.AddressOwner ?? "";
if (owner && /^0x[0-9a-fA-F]+$/.test(String(owner))) {
  process.stdout.write(String(owner));
}
'
)"

if [[ -n "$CAP_OWNER_ADDRESS" && "$CAP_OWNER_ADDRESS" != "$CONTROLLER_ADDRESS_OR_ALIAS" ]]; then
  echo "[warn] controller/address mismatch: provided=${CONTROLLER_ADDRESS_OR_ALIAS} cap_owner=${CAP_OWNER_ADDRESS}"
  echo "[info] using ControllerCap owner address for signing."
  CONTROLLER_ADDRESS_OR_ALIAS="$CAP_OWNER_ADDRESS"
fi

iota client switch --address "$CONTROLLER_ADDRESS_OR_ALIAS" >/dev/null

iota client ptb \
  --move-call "${SYSTEM_PKG}::systemState::propose_task_template_upsert" \
  "@${CONTROLLER_CAP_ID}" \
  "@${NODE_REGISTRY_ID}" \
  "@${STATE_ID}" \
  "@${CLOCK_ID}" \
  "$PROPOSAL_TIMEOUT_MS" \
  "$TEMPLATE_ID" \
  "\"$TASK_TYPE\"" \
  "$IS_ENABLED" \
  "$BASE_PRICE" \
  "$SCHEDULER_FEE" \
  "$MAX_INPUT" \
  "$MAX_OUTPUT" \
  "$INCLUDED_DOWNLOAD" \
  "$PRICE_PER_DOWNLOAD" \
  "$ALLOW_STORAGE" \
  "$MIN_RETENTION" \
  "$MAX_RETENTION" \
  "$PRICE_PER_RETENTION" \
  --gas-budget "$GAS_BUDGET"

PROPOSAL_ID="$(current_proposal_counter || true)"
echo "[ok] proposal created for template_id=${TEMPLATE_ID}."
[[ -n "${PROPOSAL_ID}" ]] && echo "[ok] proposal_id=${PROPOSAL_ID}"
