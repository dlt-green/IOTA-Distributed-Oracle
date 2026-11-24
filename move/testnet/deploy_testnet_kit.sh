#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[error] line $LINENO: command failed: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

VALIDATOR_CAPS_DIR="${SCRIPT_DIR}/oracle_validator_caps_testnet"
SYSTEM_STATE_DIR="${SCRIPT_DIR}/oracle_system_state_testnet"
TASKS_DIR="${SCRIPT_DIR}/oracle_tasks_testnet"
SCHEDULER_DIR="${SCRIPT_DIR}/iota_task_scheduler_testnet"

VALIDATOR_CAPS_TXT="${VALIDATOR_CAPS_DIR}/testnet_validator_caps.txt"
SYSTEM_STATE_TXT="${SYSTEM_STATE_DIR}/testnet_system_state.txt"
TASKS_TXT="${TASKS_DIR}/testnet_oracle_tasks.txt"
SCHEDULER_TXT="${SCHEDULER_DIR}/testnet_scheduler.txt"

TARGET_ENV="${TARGET_ENV:-testnet}"
DEPLOY_ADDRESS="${DEPLOY_ADDRESS:-OID_Groundcontrol}"
VALIDATOR_CAPS_PKG="${VALIDATOR_CAPS_PKG:-}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[error] command not found: $1" >&2
    exit 1
  }
}

extract_package_id() {
  local report_file="$1"
  local pkg_id
  pkg_id="$(
    python3 - "$report_file" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore")
match = re.search(r'PackageID:\s*(0x[a-fA-F0-9]+)', text)
if match:
    print(match.group(1))
PY
  )"
  pkg_id="$(printf '%s' "$pkg_id" | tr -d '[:space:]')"
  if [[ -z "$pkg_id" ]]; then
    echo "[error] could not extract PackageID from ${report_file}" >&2
    return 1
  fi
  printf '%s\n' "$pkg_id"
}

extract_published_at() {
  local move_toml="$1"
  local pkg_id
  pkg_id="$(
    python3 - "$move_toml" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore")
match = re.search(r'(?m)^published-at = "(0x[a-fA-F0-9]+)"$', text)
if match and match.group(1).lower() != "0x0":
    print(match.group(1))
PY
  )"
  pkg_id="$(printf '%s' "$pkg_id" | tr -d '[:space:]')"
  [[ -n "$pkg_id" ]] && printf '%s\n' "$pkg_id"
}

update_move_toml_identity() {
  local move_toml="$1"
  local address_name="$2"
  local package_id="$3"

  python3 - "$move_toml" "$address_name" "$package_id" <<'PY'
from pathlib import Path
import re
import sys

move_toml = Path(sys.argv[1])
address_name = sys.argv[2]
package_id = sys.argv[3]
text = move_toml.read_text(encoding="utf-8", errors="ignore")

text, count_pub = re.subn(r'(?m)^published-at = ".*"$', f'published-at = "{package_id}"', text, count=1)
if count_pub != 1:
    raise SystemExit(f"failed to update published-at in {move_toml}")

pattern = rf'(?m)^{re.escape(address_name)} = ".*"$'
text, count_addr = re.subn(pattern, f'{address_name} = "{package_id}"', text, count=1)
if count_addr != 1:
    raise SystemExit(f"failed to update address {address_name} in {move_toml}")

move_toml.write_text(text, encoding="utf-8")
PY
}

set_move_toml_unpublished() {
  local move_toml="$1"
  local address_name="$2"

  python3 - "$move_toml" "$address_name" <<'PY'
from pathlib import Path
import re
import sys

move_toml = Path(sys.argv[1])
address_name = sys.argv[2]
text = move_toml.read_text(encoding="utf-8", errors="ignore")

text, count_pub = re.subn(r'(?m)^published-at = ".*"$', 'published-at = "0x0"', text, count=1)
if count_pub != 1:
    raise SystemExit(f"failed to reset published-at in {move_toml}")

pattern = rf'(?m)^{re.escape(address_name)} = ".*"$'
text, count_addr = re.subn(pattern, f'{address_name} = "0x0"', text, count=1)
if count_addr != 1:
    raise SystemExit(f"failed to reset address {address_name} in {move_toml}")

move_toml.write_text(text, encoding="utf-8")
PY
}

switch_context() {
  echo "[info] switching env to ${TARGET_ENV}" >&2
  iota client switch --env "${TARGET_ENV}" >&2

  echo "[info] switching address to ${DEPLOY_ADDRESS}" >&2
  iota client switch --address "${DEPLOY_ADDRESS}" >&2
}

publish_package() {
  local package_dir="$1"
  local report_file="$2"
  local address_name="$3"
  local label="$4"
  local result_var="$5"
  local move_toml="${package_dir}/Move.toml"
  local package_id

  echo >&2
  echo "[publish] ${label}" >&2
  echo "[path] ${package_dir}" >&2

  set_move_toml_unpublished "${move_toml}" "${address_name}"

  if ! (
    cd "$package_dir"
    iota client publish
  ) >"$report_file" 2>&1; then
    echo "[error] publish failed for ${label}" >&2
    echo "[report] ${report_file}" >&2
    return 1
  fi

  package_id="$(extract_package_id "$report_file")"
  update_move_toml_identity "${move_toml}" "$address_name" "$package_id"
  printf -v "$result_var" '%s' "$package_id"

  echo "[ok] ${label} package_id=${package_id}" >&2
  echo "[report] ${report_file}" >&2
}

print_summary() {
  local validator_caps_pkg="$1"
  local system_state_pkg="$2"
  local tasks_pkg="$3"
  local scheduler_pkg="$4"

  cat <<EOF

[summary]
  validator caps package: ${validator_caps_pkg}
  system_state package:   ${system_state_pkg}
  tasks package:          ${tasks_pkg}
  scheduler package:      ${scheduler_pkg}

[reports]
  ${VALIDATOR_CAPS_TXT}
  ${SYSTEM_STATE_TXT}
  ${TASKS_TXT}
  ${SCHEDULER_TXT}

[next env values]
  TESTNET_ORACLE_VALIDATOR_CAPS_PACKAGE_ID=${validator_caps_pkg}
  TESTNET_ORACLE_SYSTEM_PACKAGE_ID=${system_state_pkg}
  TESTNET_ORACLE_TASKS_PACKAGE_ID=${tasks_pkg}
  TESTNET_ORACLE_SCHEDULER_PACKAGE_ID=${scheduler_pkg}
EOF
}

require_cmd iota
require_cmd python3
python3 "${SCRIPT_DIR}/prepare_bootstrap.py" --check

[[ "$TARGET_ENV" == "testnet" ]] || { echo "[error] this kit is testnet-only" >&2; exit 1; }
# Never republish a checkout that still contains the cap-free testnet writer.
python3 - "${SYSTEM_STATE_DIR}/sources/iota_oracle_system_state.move" <<'PY'
from pathlib import Path
import re
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r'public entry fun register_oracle_node_dev\([^)]*\)\s*\{([^}]*)\}', source, re.S)
if not match or re.sub(r'//[^\n]*', '', match.group(1)).strip() != 'abort EInvalidNetworkMode':
    raise SystemExit("Refusing publish: testnet dev registration must unconditionally abort")
PY

[[ -d "$VALIDATOR_CAPS_DIR" ]] || { echo "[error] missing dir: $VALIDATOR_CAPS_DIR" >&2; exit 1; }
[[ -d "$SYSTEM_STATE_DIR" ]] || { echo "[error] missing dir: $SYSTEM_STATE_DIR" >&2; exit 1; }
[[ -d "$TASKS_DIR" ]] || { echo "[error] missing dir: $TASKS_DIR" >&2; exit 1; }
[[ -d "$SCHEDULER_DIR" ]] || { echo "[error] missing dir: $SCHEDULER_DIR" >&2; exit 1; }

switch_context

echo "[verify] running registration regression tests before publication"
iota move test --path "$SYSTEM_STATE_DIR" --skip-fetch-latest-git-deps

echo "[info] active env: $(iota client active-env 2>/dev/null | tr -d '\n')"
echo "[info] active address: $(iota client active-address 2>/dev/null | tr -d '\n')"
echo "[info] mode: reuse validator_caps, fresh publish for system_state/tasks/scheduler"

if [[ -z "$VALIDATOR_CAPS_PKG" && -f "$VALIDATOR_CAPS_TXT" ]]; then
  VALIDATOR_CAPS_PKG="$(extract_package_id "$VALIDATOR_CAPS_TXT" || true)"
fi
if [[ -z "$VALIDATOR_CAPS_PKG" ]]; then
  VALIDATOR_CAPS_PKG="$(extract_published_at "${VALIDATOR_CAPS_DIR}/Move.toml" || true)"
fi
[[ "$VALIDATOR_CAPS_PKG" =~ ^0x[0-9a-fA-F]+$ ]] || {
  echo "[error] could not resolve validator caps package id. Set VALIDATOR_CAPS_PKG or restore ${VALIDATOR_CAPS_TXT}." >&2
  exit 1
}

SYSTEM_STATE_PKG=""
TASKS_PKG=""
SCHEDULER_PKG=""

update_move_toml_identity "${VALIDATOR_CAPS_DIR}/Move.toml" "iota_oracle_validator_caps" "${VALIDATOR_CAPS_PKG}"
cat >"${VALIDATOR_CAPS_TXT}" <<EOF
[reuse]
validator caps package: ${VALIDATOR_CAPS_PKG}
PackageID: ${VALIDATOR_CAPS_PKG}
report: package reused, not republished
EOF

publish_package "$SYSTEM_STATE_DIR" "$SYSTEM_STATE_TXT" "iota_oracle_system_state" "system state" SYSTEM_STATE_PKG
publish_package "$TASKS_DIR" "$TASKS_TXT" "iota_oracle_tasks" "oracle tasks" TASKS_PKG
publish_package "$SCHEDULER_DIR" "$SCHEDULER_TXT" "iota_oracle_scheduler" "scheduler" SCHEDULER_PKG

print_summary "$VALIDATOR_CAPS_PKG" "$SYSTEM_STATE_PKG" "$TASKS_PKG" "$SCHEDULER_PKG"
echo "[next] Run bash move/testnet/update_testnet_envs.sh --check, then without --check."
echo "[next] Migrate all runtime IDs and re-register nodes. Old packages/tasks remain callable."
echo "[guide] docs/TESTNET_REGISTRATION_MIGRATION.md"
