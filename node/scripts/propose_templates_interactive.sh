#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[error] line $LINENO: command failed: $BASH_COMMAND" >&2' ERR

ENV_FILE=""
NETWORK=""
EXAMPLES_DIR=""
ALLOW_DUPLICATE=0

usage() {
  cat <<'EOF'
Interactive template proposer from JSON examples.
Loads .env, lists JSON files under examples, asks which ones to propose.

Usage:
  ./scripts/propose_templates_interactive.sh [--network devnet|testnet|mainnet] [--env-file /path/.env] [--examples-dir /path/examples] [--allow-duplicate]

Examples:
  ./scripts/propose_templates_interactive.sh
  ./scripts/propose_templates_interactive.sh --network devnet
  ./scripts/propose_templates_interactive.sh --network devnet --allow-duplicate
  ./scripts/propose_templates_interactive.sh --network testnet --env-file ./../.env
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --env-file" >&2; usage; exit 1; }
      ENV_FILE="$1"
      ;;
    --network)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --network" >&2; usage; exit 1; }
      NETWORK="$1"
      ;;
    --examples-dir)
      shift
      [[ $# -gt 0 ]] || { echo "[error] missing value for --examples-dir" >&2; usage; exit 1; }
      EXAMPLES_DIR="$1"
      ;;
    --allow-duplicate)
      ALLOW_DUPLICATE=1
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
PROPOSER_SCRIPT="${SCRIPT_DIR}/propose_template_from_json.sh"
REPO_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"

[[ -f "$PROPOSER_SCRIPT" ]] || { echo "[error] proposer script not found: $PROPOSER_SCRIPT" >&2; exit 1; }

if [[ -z "$ENV_FILE" ]]; then
  if [[ -f "${PROJECT_DIR}/.env" ]]; then
    ENV_FILE="${PROJECT_DIR}/.env"
  else
    echo "[error] .env not found under ${PROJECT_DIR}. Use --env-file." >&2
    exit 1
  fi
fi
[[ -f "$ENV_FILE" ]] || { echo "[error] env file not found: $ENV_FILE" >&2; exit 1; }

if [[ -z "$EXAMPLES_DIR" ]]; then
  EXAMPLES_DIR="${PROJECT_DIR}/src/tasks/examples"
fi
[[ -d "$EXAMPLES_DIR" ]] || { echo "[error] examples dir not found: $EXAMPLES_DIR" >&2; exit 1; }

# Prevent stale exported network vars from caller shell from leaking in.
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

if [[ -z "$NETWORK" ]]; then
  NETWORK="${IOTA_NETWORK:-${ORACLE_NETWORK:-${NODE_NETWORK:-${NODE_1_NETWORK:-}}}}"
fi
NETWORK="$(echo "${NETWORK}" | tr '[:upper:]' '[:lower:]' | xargs)"
case "$NETWORK" in
  dev|devent|local|localnet) NETWORK="devnet" ;;
  test) NETWORK="testnet" ;;
  main) NETWORK="mainnet" ;;
esac
[[ "$NETWORK" == "devnet" || "$NETWORK" == "testnet" || "$NETWORK" == "mainnet" ]] || {
  echo "[error] invalid or missing network. Use --network devnet|testnet|mainnet or set IOTA_NETWORK/NODE_1_NETWORK in .env" >&2
  exit 1
}

NET_PREFIX="$(echo "$NETWORK" | tr '[:lower:]' '[:upper:]')"

get_prefixed_env() {
  local key="$1"
  local prefixed="${NET_PREFIX}_${key}"
  local v="${!prefixed:-}"
  if [[ -n "$v" ]]; then
    printf "%s" "$v"
    return 0
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

sync_iota_cli_env() {
  command -v iota >/dev/null 2>&1 || { echo "[error] iota CLI not found" >&2; exit 1; }
  local active_env=""
  active_env="$(iota client active-env 2>/dev/null | tr -d '\r' | xargs || true)"
  if [[ "$active_env" != "$NETWORK" ]]; then
    echo "[info] switching iota client env: ${active_env:-<unset>} -> ${NETWORK}"
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
const data = JSON.parse(txt);
const type = data?.data?.type ?? data?.type ?? data?.content?.type ?? "";
if (type) process.stdout.write(String(type));
'
}

SYSTEM_PKG="$(get_prefixed_env ORACLE_SYSTEM_PACKAGE_ID)"
STATE_ID="$(get_prefixed_env ORACLE_STATE_ID)"
NODE_REGISTRY_ID="$(get_prefixed_env ORACLE_NODE_REGISTRY_ID)"
CLOCK_ID="$(get_prefixed_env IOTA_CLOCK_ID)"
CONTROLLER_CAP_ID="$(get_prefixed_env CONTROLLER_CAP_ID)"
CONTROLLER_ADDRESS_OR_ALIAS="$(get_prefixed_env CONTROLLER_ADDRESS_OR_ALIAS)"
if [[ -z "$CONTROLLER_ADDRESS_OR_ALIAS" ]]; then
  CONTROLLER_ADDRESS_OR_ALIAS="$(get_prefixed_env ORACLE_CONTROLLER_ADDRESS)"
fi

if [[ -z "$CONTROLLER_ADDRESS_OR_ALIAS" ]]; then
  CONTROLLER_ADDRESS_OR_ALIAS="$(iota client active-address | tr -d '\r' | xargs)"
fi

[[ -n "$SYSTEM_PKG" ]] || { echo "[error] missing ${NET_PREFIX}_ORACLE_SYSTEM_PACKAGE_ID (or ORACLE_SYSTEM_PACKAGE_ID) in env" >&2; exit 1; }
[[ -n "$STATE_ID" ]] || { echo "[error] missing ${NET_PREFIX}_ORACLE_STATE_ID (or ORACLE_STATE_ID) in env" >&2; exit 1; }
[[ -n "$NODE_REGISTRY_ID" ]] || { echo "[error] missing ${NET_PREFIX}_ORACLE_NODE_REGISTRY_ID (or ORACLE_NODE_REGISTRY_ID) in env" >&2; exit 1; }
[[ -n "$CONTROLLER_CAP_ID" ]] || { echo "[error] missing ${NET_PREFIX}_CONTROLLER_CAP_ID (or CONTROLLER_CAP_ID) in env" >&2; exit 1; }
[[ -n "$CONTROLLER_ADDRESS_OR_ALIAS" ]] || { echo "[error] missing controller address/alias in env and active-address unavailable" >&2; exit 1; }

EXPECTED_CONTROLLER_CAP_TYPE="${SYSTEM_PKG}::systemState::ControllerCap"
REPORT_FILE="$(network_system_state_report || true)"
sync_iota_cli_env
CURRENT_CONTROLLER_CAP_TYPE="$(read_object_type "${CONTROLLER_CAP_ID}" || true)"
if [[ "$CURRENT_CONTROLLER_CAP_TYPE" != "$EXPECTED_CONTROLLER_CAP_TYPE" ]]; then
  REPORT_CONTROLLER_CAP_ID="$(controller_cap_id_from_report "$REPORT_FILE" || true)"
  if [[ -n "$REPORT_CONTROLLER_CAP_ID" ]]; then
    REPORT_CONTROLLER_CAP_TYPE="$(read_object_type "${REPORT_CONTROLLER_CAP_ID}" || true)"
    if [[ "$REPORT_CONTROLLER_CAP_TYPE" == "$EXPECTED_CONTROLLER_CAP_TYPE" ]]; then
      echo "[warn] controller cap from env is invalid for current package: id=${CONTROLLER_CAP_ID} type=${CURRENT_CONTROLLER_CAP_TYPE:-unknown}"
      echo "[info] using ControllerCap from publish report: ${REPORT_CONTROLLER_CAP_ID}"
      CONTROLLER_CAP_ID="$REPORT_CONTROLLER_CAP_ID"
    fi
  fi
fi

[[ "$(read_object_type "${CONTROLLER_CAP_ID}" || true)" == "$EXPECTED_CONTROLLER_CAP_TYPE" ]] || {
  echo "[error] CONTROLLER_CAP_ID=${CONTROLLER_CAP_ID} is not ${EXPECTED_CONTROLLER_CAP_TYPE}" >&2
  echo "[error] rerun update_${NETWORK}_envs.sh or fix the .env manually." >&2
  exit 1
}

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
  echo "[warn] controller/address mismatch from env: provided=${CONTROLLER_ADDRESS_OR_ALIAS} cap_owner=${CAP_OWNER_ADDRESS}"
  echo "[info] using ControllerCap owner address for signing."
  CONTROLLER_ADDRESS_OR_ALIAS="$CAP_OWNER_ADDRESS"
fi

mapfile -t JSON_FILES < <(find "$EXAMPLES_DIR" -maxdepth 1 -type f -name '*.json' | sort)
[[ ${#JSON_FILES[@]} -gt 0 ]] || { echo "[error] no json files found in $EXAMPLES_DIR" >&2; exit 1; }

echo "[info] env-file=${ENV_FILE}"
echo "[info] network=${NETWORK}"
echo "[info] system_pkg=${SYSTEM_PKG}"
echo "[info] state_id=${STATE_ID}"
echo "[info] node_registry_id=${NODE_REGISTRY_ID}"
echo "[info] controller=${CONTROLLER_ADDRESS_OR_ALIAS}"
echo "[info] controller_cap_id=${CONTROLLER_CAP_ID}"
echo "[info] examples_dir=${EXAMPLES_DIR}"
export IOTA_NETWORK="$NETWORK"
echo ""
echo "Available templates:"
for i in "${!JSON_FILES[@]}"; do
  printf "  %2d) %s\n" "$((i + 1))" "$(basename "${JSON_FILES[$i]}")"
done
echo ""
echo "Select templates to propose:"
echo "  - type numbers separated by space/comma (example: 1 3 5)"
echo "  - or type 'all'"
echo "  - or type 'q' to quit"
read -r -p "> " SELECTION

SELECTION="$(echo "$SELECTION" | tr '[:upper:]' '[:lower:]' | xargs)"
if [[ "$SELECTION" == "q" || "$SELECTION" == "quit" || "$SELECTION" == "exit" ]]; then
  echo "[info] cancelled."
  exit 0
fi
[[ -n "$SELECTION" ]] || { echo "[error] empty selection" >&2; exit 1; }

SELECTED_FILES=()
if [[ "$SELECTION" == "all" ]]; then
  SELECTED_FILES=("${JSON_FILES[@]}")
else
  NORMALIZED="$(echo "$SELECTION" | tr ',' ' ')"
  declare -A seen=()
  for token in $NORMALIZED; do
    [[ "$token" =~ ^[0-9]+$ ]] || { echo "[error] invalid token: $token" >&2; exit 1; }
    idx=$((token - 1))
    (( idx >= 0 && idx < ${#JSON_FILES[@]} )) || { echo "[error] index out of range: $token" >&2; exit 1; }
    if [[ -z "${seen[$idx]:-}" ]]; then
      SELECTED_FILES+=("${JSON_FILES[$idx]}")
      seen[$idx]=1
    fi
  done
fi

[[ ${#SELECTED_FILES[@]} -gt 0 ]] || { echo "[error] no templates selected" >&2; exit 1; }

echo ""
echo "[info] proposing ${#SELECTED_FILES[@]} template(s)..."
PROPOSER_EXTRA_ARGS=()
if [[ "$ALLOW_DUPLICATE" -eq 1 ]]; then
  PROPOSER_EXTRA_ARGS+=(--allow-duplicate)
fi

for file in "${SELECTED_FILES[@]}"; do
  echo ""
  echo "============================================================"
  echo "[propose] $(basename "$file")"
  echo "============================================================"
  bash "$PROPOSER_SCRIPT" \
    --file "$file" \
    --network "$NETWORK" \
    --env-file "$ENV_FILE" \
    --controller "$CONTROLLER_ADDRESS_OR_ALIAS" \
    --system-pkg "$SYSTEM_PKG" \
    --state-id "$STATE_ID" \
    --node-registry-id "$NODE_REGISTRY_ID" \
    --controller-cap-id "$CONTROLLER_CAP_ID" \
    "${PROPOSER_EXTRA_ARGS[@]}" \
    ${CLOCK_ID:+--clock-id "$CLOCK_ID"}
done

echo ""
echo "[ok] done. proposals submitted."
