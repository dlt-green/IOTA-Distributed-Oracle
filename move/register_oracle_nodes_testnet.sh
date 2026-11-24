#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[error] line $LINENO: command failed: $BASH_COMMAND" >&2' ERR

SYSTEM_PKG="${SYSTEM_PKG:-${TESTNET_ORACLE_SYSTEM_PACKAGE_ID:-}}"
STATE_ID="${STATE_ID:-${TESTNET_ORACLE_STATE_ID:-}}"
NODE_REGISTRY_ID="${NODE_REGISTRY_ID:-${TESTNET_ORACLE_NODE_REGISTRY_ID:-}}"
IOTA_SYSTEM_STATE_ID="${IOTA_SYSTEM_STATE_ID:-0x5}"
GAS_BUDGET="${GAS_BUDGET:-50000000}"

ACCEPTED_TEMPLATE_IDS="${ACCEPTED_TEMPLATE_IDS:-[1,2,3,4,5,6,7,8,9,10,11]}"
NODE1_ALIAS="${NODE1_ALIAS:-oracle-node-1}"
NODE2_ALIAS="${NODE2_ALIAS:-oracle-node-2}"
NODE3_ALIAS="${NODE3_ALIAS:-oracle-node-3}"

NODE1_DELEGATED_CONTROLLER_CAP_ID="${NODE1_DELEGATED_CONTROLLER_CAP_ID:-${DELEGATED_CONTROLLER_CAP_ID_NODE1:-}}"
NODE2_DELEGATED_CONTROLLER_CAP_ID="${NODE2_DELEGATED_CONTROLLER_CAP_ID:-${DELEGATED_CONTROLLER_CAP_ID_NODE2:-}}"
NODE3_DELEGATED_CONTROLLER_CAP_ID="${NODE3_DELEGATED_CONTROLLER_CAP_ID:-${DELEGATED_CONTROLLER_CAP_ID_NODE3:-}}"

resolve_address() {
  local who="$1"
  if [[ "$who" == 0x* ]]; then
    printf '%s\n' "$who"
    return 0
  fi

  local addresses_json
  addresses_json="$(iota client addresses --json 2>/dev/null)"

  local resolved
  resolved="$(
    python3 - "$who" "$addresses_json" <<'PY'
import json
import sys

target = sys.argv[1]
data = json.loads(sys.argv[2])
for entry in data.get("addresses", []):
    if len(entry) >= 2 and entry[0] == target:
        print(entry[1])
        break
PY
  )"

  [[ -n "$resolved" ]] || {
    echo "[error] alias not found in client config: $who" >&2
    exit 1
  }

  printf '%s\n' "$resolved"
}

register_node() {
  local alias="$1"
  local delegated_cap_id="$2"
  local pubkey_bytes="$3"
  local accepted_template_ids="${4:-$ACCEPTED_TEMPLATE_IDS}"

  [[ -n "$delegated_cap_id" ]] || {
    echo "[error] missing delegated controller cap id for ${alias}" >&2
    exit 1
  }

  local oracle_addr
  oracle_addr="$(resolve_address "$alias")"

  echo "[register] alias=${alias} oracle_addr=${oracle_addr}"
  iota client switch --address "$alias" >/dev/null
  iota client ptb \
    --make-move-vec "<u8>" "$pubkey_bytes" \
    --assign pubkey \
    --make-move-vec "<u64>" "$accepted_template_ids" \
    --assign accepted \
    --move-call "${SYSTEM_PKG}::systemState::register_oracle_node" \
      "@${NODE_REGISTRY_ID}" \
      "@${STATE_ID}" \
      "@${IOTA_SYSTEM_STATE_ID}" \
      "@${delegated_cap_id}" \
      "@${oracle_addr}" \
      pubkey \
      accepted \
    --gas-budget "$GAS_BUDGET" \
    --summary
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[error] command not found: $1" >&2
    exit 1
  }
}

require_cmd iota
require_cmd python3
[[ "$(iota client active-env 2>/dev/null | tr -d '\r\n')" == "testnet" ]] || {
  echo "[error] switch the IOTA CLI to testnet before registration" >&2; exit 1;
}
[[ -n "$SYSTEM_PKG" ]] || { echo "[error] set SYSTEM_PKG or TESTNET_ORACLE_SYSTEM_PACKAGE_ID" >&2; exit 1; }
[[ -n "$STATE_ID" ]] || { echo "[error] set STATE_ID or TESTNET_ORACLE_STATE_ID" >&2; exit 1; }
[[ -n "$NODE_REGISTRY_ID" ]] || { echo "[error] set NODE_REGISTRY_ID or TESTNET_ORACLE_NODE_REGISTRY_ID" >&2; exit 1; }

echo "[info] env=$(iota client active-env 2>/dev/null | tr -d '\n')"
echo "[info] active-address=$(iota client active-address 2>/dev/null | tr -d '\n')"
echo "[info] SYSTEM_PKG=$SYSTEM_PKG"
echo "[info] STATE_ID=$STATE_ID"
echo "[info] NODE_REGISTRY_ID=$NODE_REGISTRY_ID"
echo "[info] IOTA_SYSTEM_STATE_ID=$IOTA_SYSTEM_STATE_ID"
echo "[info] ACCEPTED_TEMPLATE_IDS=$ACCEPTED_TEMPLATE_IDS"

register_node \
  "$NODE1_ALIAS" \
  "$NODE1_DELEGATED_CONTROLLER_CAP_ID" \
  "[190,212,235,229,87,205,38,143,177,82,30,197,240,223,70,213,112,19,19,2,43,87,13,223,205,83,131,61,202,145,42,2]"

register_node \
  "$NODE2_ALIAS" \
  "$NODE2_DELEGATED_CONTROLLER_CAP_ID" \
  "[65,93,12,132,189,26,78,84,236,177,28,199,138,5,17,173,131,172,155,75,41,76,167,112,100,19,184,218,0,66,243,136]"

register_node \
  "$NODE3_ALIAS" \
  "$NODE3_DELEGATED_CONTROLLER_CAP_ID" \
  "[138,135,89,96,229,2,69,242,147,240,249,225,123,151,229,111,215,254,193,176,26,87,19,52,215,251,35,107,93,199,175,91]"

echo
echo "[ok] oracle nodes registered or updated on testnet"
