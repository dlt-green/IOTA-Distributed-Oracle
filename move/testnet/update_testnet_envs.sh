#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

VALIDATOR_CAPS_REPORT="${REPO_ROOT}/move/testnet/oracle_validator_caps_testnet/testnet_validator_caps.txt"
SYSTEM_STATE_REPORT="${REPO_ROOT}/move/testnet/oracle_system_state_testnet/testnet_system_state.txt"
TASKS_REPORT="${REPO_ROOT}/move/testnet/oracle_tasks_testnet/testnet_oracle_tasks.txt"

python3 - "$REPO_ROOT" "$VALIDATOR_CAPS_REPORT" "$SYSTEM_STATE_REPORT" "$TASKS_REPORT" "$@" <<'PY'
from pathlib import Path
import re
import sys

repo_root = Path(sys.argv[1])
validator_caps_report = Path(sys.argv[2])
system_report = Path(sys.argv[3])
tasks_report = Path(sys.argv[4])
args = sys.argv[5:]
if args not in ([], ["--check"]):
    raise SystemExit("Usage: update_testnet_envs.sh [--check]")
check_only = args == ["--check"]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def package_id_from_report(path: Path) -> str | None:
    if not path.exists():
        return None
    text = read(path)
    matches = re.findall(r'PackageID:\s*(0x[a-fA-F0-9]+)', text)
    if len(matches) > 1:
        raise SystemExit("Ambiguous publish report: " + str(path))
    return matches[0] if matches else None


def object_id_for_type(text: str, suffix: str, package: str | None) -> str | None:
    if not package:
        return None
    blocks = re.findall(r"│  ┌──[\s\S]*?│  └──", text)
    type_pattern = re.compile(r"ObjectType:\s*" + re.escape(package + "::" + suffix) + r"(?=\s|$)")
    id_pattern = re.compile(r"ObjectID:\s*(0x[a-fA-F0-9]+)")
    ids = []
    for block in blocks:
        if not type_pattern.search(block):
            continue
        match = id_pattern.search(block)
        if match:
            ids.append(match.group(1))
    if len(ids) > 1:
        raise SystemExit("Ambiguous object in publish report: " + suffix)
    return ids[0] if ids else None


def read_env(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore") if path.exists() else ""


def env_map(path: Path) -> dict[str, str]:
    result = {}
    for line in read_env(path).splitlines():
        match = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(.*)$', line)
        if match:
            value = match[2].strip()
            quoted = re.match(r'''^(["'])(.*?)\1(?:\s*#.*)?$''', value)
            result[match[1]] = quoted[2] if quoted else value.split('#', 1)[0].strip()
    return result


system_text = read(system_report)
tasks_text = read(tasks_report)
system_package = package_id_from_report(system_report)
tasks_package = package_id_from_report(tasks_report)

values = {
    "TESTNET_ORACLE_VALIDATOR_CAPS_PACKAGE_ID": package_id_from_report(validator_caps_report),
    "TESTNET_ORACLE_SYSTEM_PACKAGE_ID": system_package,
    "TESTNET_ORACLE_TASKS_PACKAGE_ID": tasks_package,
    "TESTNET_ORACLE_STATE_ID": object_id_for_type(system_text, "systemState::State", system_package),
    "TESTNET_ORACLE_TREASURY_ID": object_id_for_type(system_text, "systemState::OracleTreasury", system_package),
    "TESTNET_CONTROLLER_CAP_ID": object_id_for_type(system_text, "systemState::ControllerCap", system_package),
    "TESTNET_ORACLE_NODE_REGISTRY_ID": object_id_for_type(system_text, "systemState::NodeRegistry", system_package),
    "TESTNET_ORACLE_TASK_REGISTRY_ID": object_id_for_type(tasks_text, "oracle_tasks::TaskRegistry", tasks_package),
    "TESTNET_ORACLE_TASK_SCHEDULER_QUEUE_ID": object_id_for_type(tasks_text, "oracle_tasks::SchedulerQueue", tasks_package),
}

missing = [key for key, value in values.items() if not value]
if missing:
    raise SystemExit("Missing required values from publish reports: " + ", ".join(missing))

# Refuse reports for the cap-free legacy deployment. A new system package and
# fresh objects are required; changing only the client code is not a migration.
legacy_system = "0x55a6b6848a5a343a8ad5ec5db46a93b15011bc3e50fd164e03d996f1aa317425"
legacy_tasks = "0x9f995808cd2cd8cee26c1b4fdc7f3b45d578ebd13da0f41d32d7698572a3a77f"
if values["TESTNET_ORACLE_SYSTEM_PACKAGE_ID"].lower() == legacy_system or values["TESTNET_ORACLE_TASKS_PACKAGE_ID"].lower() == legacy_tasks:
    raise SystemExit("Legacy testnet publish reports: publish the corrected fresh kit before updating configuration.")
if check_only:
    print("[ok] Fresh publication reports are complete; no environment files changed.")
    raise SystemExit(0)


def upsert_lines(path: Path, pairs: list[tuple[str, str]]) -> None:
    if not path.exists():
      return
    lines = read_env(path).splitlines()
    changed = False
    for key, value in pairs:
        regex = re.compile(rf'^\s*(?:export\s+)?{re.escape(key)}\s*=.*$')
        for idx, line in enumerate(lines):
            if regex.match(line):
                new_line = f"{key}={value}"
                if lines[idx] != new_line:
                    lines[idx] = new_line
                    changed = True
        if not any(regex.match(line) for line in lines):
            lines.append(f"{key}={value}")
            changed = True
    if changed:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"[updated] {path}")


def remove_keys(path: Path, keys: list[str]) -> None:
    if not path.exists():
        return
    lines = read_env(path).splitlines()
    filtered = [line for line in lines if not any(line.startswith(f"{key}=") for key in keys)]
    if filtered != lines:
        path.write_text("\n".join(filtered) + "\n", encoding="utf-8")
        print(f"[cleaned] {path}")


client_env = repo_root / "client" / ".env"
client_example = repo_root / "client" / ".env.example"
node_env = repo_root / "node" / ".env"
node_example = repo_root / "node" / ".env.example"
webview_example = repo_root / "webview" / ".env.example"
webview_env = repo_root / "webview" / ".env"

runtime_pairs = [
    ("IOTA_NETWORK", "testnet"),
    ("IOTA_RPC_URL", "https://api.testnet.iota.cafe"),
    ("IOTA_FAUCET_URL", "https://faucet.testnet.iota.cafe/gas"),
    ("ORACLE_VALIDATOR_CAPS_PACKAGE_ID", values["TESTNET_ORACLE_VALIDATOR_CAPS_PACKAGE_ID"]),
    ("ORACLE_TASKS_PACKAGE_ID", values["TESTNET_ORACLE_TASKS_PACKAGE_ID"]),
    ("ORACLE_SYSTEM_PACKAGE_ID", values["TESTNET_ORACLE_SYSTEM_PACKAGE_ID"]),
    ("ORACLE_STATE_ID", values["TESTNET_ORACLE_STATE_ID"]),
    ("ORACLE_TREASURY_ID", values["TESTNET_ORACLE_TREASURY_ID"]),
    ("CONTROLLER_CAP_ID", values["TESTNET_CONTROLLER_CAP_ID"]),
    ("ORACLE_NODE_REGISTRY_ID", values["TESTNET_ORACLE_NODE_REGISTRY_ID"]),
    ("ORACLE_TASK_REGISTRY_ID", values["TESTNET_ORACLE_TASK_REGISTRY_ID"]),
    ("ORACLE_TASK_SCHEDULER_QUEUE_ID", values["TESTNET_ORACLE_TASK_SCHEDULER_QUEUE_ID"]),
]

client_network_pairs = [
    ("TESTNET_IOTA_RPC_URL", "https://api.testnet.iota.cafe"),
    ("TESTNET_ORACLE_VALIDATOR_CAPS_PACKAGE_ID", values["TESTNET_ORACLE_VALIDATOR_CAPS_PACKAGE_ID"]),
    ("TESTNET_ORACLE_TASKS_PACKAGE_ID", values["TESTNET_ORACLE_TASKS_PACKAGE_ID"]),
    ("TESTNET_ORACLE_SYSTEM_PACKAGE_ID", values["TESTNET_ORACLE_SYSTEM_PACKAGE_ID"]),
    ("TESTNET_ORACLE_STATE_ID", values["TESTNET_ORACLE_STATE_ID"]),
    ("TESTNET_ORACLE_TREASURY_ID", values["TESTNET_ORACLE_TREASURY_ID"]),
    ("TESTNET_ORACLE_NODE_REGISTRY_ID", values["TESTNET_ORACLE_NODE_REGISTRY_ID"]),
    ("TESTNET_ORACLE_TASK_REGISTRY_ID", values["TESTNET_ORACLE_TASK_REGISTRY_ID"]),
    ("TESTNET_ORACLE_TASK_SCHEDULER_QUEUE_ID", values["TESTNET_ORACLE_TASK_SCHEDULER_QUEUE_ID"]),
]

node_pairs = [
    ("TESTNET_IOTA_RPC_URL", "https://api.testnet.iota.cafe"),
    ("TESTNET_ORACLE_VALIDATOR_CAPS_PACKAGE_ID", values["TESTNET_ORACLE_VALIDATOR_CAPS_PACKAGE_ID"]),
    ("TESTNET_ORACLE_TASKS_PACKAGE_ID", values["TESTNET_ORACLE_TASKS_PACKAGE_ID"]),
    ("TESTNET_ORACLE_SYSTEM_PACKAGE_ID", values["TESTNET_ORACLE_SYSTEM_PACKAGE_ID"]),
    ("TESTNET_ORACLE_STATE_ID", values["TESTNET_ORACLE_STATE_ID"]),
    ("TESTNET_ORACLE_TREASURY_ID", values["TESTNET_ORACLE_TREASURY_ID"]),
    ("TESTNET_CONTROLLER_CAP_ID", values["TESTNET_CONTROLLER_CAP_ID"]),
    ("TESTNET_ORACLE_NODE_REGISTRY_ID", values["TESTNET_ORACLE_NODE_REGISTRY_ID"]),
    ("TESTNET_ORACLE_TASK_REGISTRY_ID", values["TESTNET_ORACLE_TASK_REGISTRY_ID"]),
    ("TESTNET_ORACLE_TASK_SCHEDULER_QUEUE_ID", values["TESTNET_ORACLE_TASK_SCHEDULER_QUEUE_ID"]),
    ("REGISTER_MODE", "prod"),
    ("AUTO_REGISTER", "true"),
]

webview_pairs = list(values.items())
legacy_node_runtime_keys = []  # Operator-owned delegated cap IDs must survive migration.
legacy_generic_runtime_keys = [
]

def migrate(path: Path, pairs: list[tuple[str, str]], nodes: bool = False) -> None:
    existing = env_map(path)
    # Keep operator RPC/faucet endpoints, including authenticated/private RPCs.
    effective = [(key, value) for key, value in pairs
                 if not ((key.endswith('IOTA_RPC_URL') or key.endswith('IOTA_FAUCET_URL')) and existing.get(key))]
    if nodes:
        node_ids = {m[1] for key in existing if (m := re.match(r'NODE_(\d+)_', key))}
        if not node_ids:
            node_ids = {'1'}
        for node_id in sorted(node_ids):
            prefix = f'NODE_{node_id}_'
            network = existing.get(prefix + 'NETWORK', existing.get(prefix + 'IOTA_NETWORK', existing.get('IOTA_NETWORK', 'testnet'))).lower()
            if network not in ('test', 'testnet'):
                continue
            effective.extend([(prefix + 'NETWORK', 'testnet'), (prefix + 'REGISTER_MODE', 'prod'), (prefix + 'AUTO_REGISTER', 'true')])
            # Node-scoped keys override globals at bootstrap: migrate them too.
            for key, value in pairs:
                if key.startswith('ORACLE_') or key.startswith('TESTNET_ORACLE_') or key in ('CONTROLLER_CAP_ID', 'TESTNET_CONTROLLER_CAP_ID'):
                    if prefix + key in existing:
                        effective.append((prefix + key, value))
    replacements = {legacy_system: system_package, legacy_tasks: tasks_package}
    for key, value in existing.items():
        if key.endswith('_EVENT_TYPE'):
            for old, new in replacements.items():
                if value.startswith(old + '::'):
                    effective.append((key, new + value[len(old):]))
    upsert_lines(path, effective)

migrate(client_env, [*client_network_pairs, *runtime_pairs])
migrate(client_example, [*client_network_pairs, *runtime_pairs])
migrate(node_env, [*node_pairs, *runtime_pairs], nodes=True)
migrate(node_example, [*node_pairs, *runtime_pairs], nodes=True)
migrate(webview_env, [*webview_pairs, *runtime_pairs])
migrate(webview_example, [*webview_pairs, *runtime_pairs])
remove_keys(node_env, legacy_node_runtime_keys)
remove_keys(node_example, legacy_node_runtime_keys)
remove_keys(client_env, legacy_generic_runtime_keys)
remove_keys(client_example, legacy_generic_runtime_keys)
remove_keys(webview_env, legacy_generic_runtime_keys)
remove_keys(webview_example, legacy_generic_runtime_keys)
PY
