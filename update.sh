#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NETWORK="auto"
SKIP_GIT=0
SKIP_ENV=0
SKIP_LOCAL_BUILD=0
SKIP_DOCKER=0
INCLUDE_WEBVIEW=1
INCLUDE_TRAEFIK=0
DEVNET_COMPOSE=0
REMOVE_ORPHANS=0
READY_TIMEOUT="${UPDATE_READY_TIMEOUT:-180}"

usage() {
  cat <<'EOF'
Usage: ./update.sh [options]

Updates the oracle node checkout, environment values, dependencies, builds, and
Docker services. Docker upgrades build inside Node 24 images and need no host npm.
Existing wallet keys, delegated caps and provider credentials are preserved.
Node readiness is checked before success (UPDATE_READY_TIMEOUT, default 180s).

Options:
  --network auto|testnet|devnet  Env sync script to run (default: auto)
  --devnet-compose              Use node/docker-compose_devnet.yml for nodes
  --skip-git                    Do not run git pull
  --skip-env                    Do not run move/<network>/update_<network>_envs.sh
  --skip-local-build            Do not run npm ci / npm build locally
  --skip-docker                 Do not rebuild/restart Docker services
  --no-webview                  Do not update the webview Docker service
  --with-traefik                Also update the traefik Docker service
  --remove-orphans              Remove Compose orphan containers during Docker update
  -h, --help                    Show this help
EOF
}

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    env -u COMPOSE_PROJECT_NAME -u COMPOSE_FILE docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    env -u COMPOSE_PROJECT_NAME -u COMPOSE_FILE docker-compose "$@"
  else
    echo "Missing Docker Compose. Install 'docker compose' or 'docker-compose'." >&2
    exit 1
  fi
}

env_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '
    $0 !~ /^[[:space:]]*#/ && $1 == k {
      value=$0
      sub("^[^=]*=", "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      print value
      exit
    }
  ' "$file"
}

detect_network() {
  local value
  value="$(env_value IOTA_NETWORK node/.env || true)"
  case "${value,,}" in
    testnet) printf 'testnet' ;;
    dev|devnet|local|localnet) printf 'devnet' ;;
    "") printf 'testnet' ;;
    *)
      echo "Unsupported IOTA_NETWORK in node/.env: $value" >&2
      echo "Pass --network testnet or --network devnet explicitly." >&2
      exit 1
      ;;
  esac
}

backup_envs() {
  local backup_dir=".update-backups/$(date '+%Y%m%d-%H%M%S')"
  local copied=0

  for file in node/.env webview/.env client/.env traefik/.env; do
    if [[ -f "$file" ]]; then
      mkdir -p "$backup_dir/$(dirname "$file")"
      cp -p "$file" "$backup_dir/$file"
      copied=1
    fi
  done

  if [[ "$copied" == 1 ]]; then
    echo "Env backup written to $backup_dir"
  fi
}

npm_install_and_build() {
  local dir="$1"
  [[ -f "$dir/package.json" ]] || return 0

  log "Installing dependencies in $dir"
  (cd "$dir" && npm ci)

  if (cd "$dir" && npm run | grep -qE '^[[:space:]]+build$|^[[:space:]]+build[[:space:]]'); then
    log "Building $dir"
    (cd "$dir" && npm run build)
  fi
}

docker_up() {
  local compose_file="$1"
  local project_dir="$2"
  local args=(up --build --force-recreate -d)

  if [[ ! -f "$compose_file" ]]; then
    echo "Compose file not found: $compose_file" >&2
    exit 1
  fi

  if [[ "$REMOVE_ORPHANS" == 1 ]]; then
    args+=(--remove-orphans)
  fi

  log "Updating Docker services from $compose_file"
  (cd "$project_dir" && compose -f "$(basename "$compose_file")" "${args[@]}")
}

wait_for_nodes() {
  local compose_file="$1"
  local service deadline services found=0
  services="$(cd node && compose -f "$compose_file" config --services)" || return 1
  while IFS= read -r service; do
    [[ "$service" == oracle-node-* ]] || continue
    found=1
    deadline=$((SECONDS + READY_TIMEOUT))
    log "Waiting for $service registration and readiness (timeout ${READY_TIMEOUT}s)"
    until (cd node && compose -f "$compose_file" exec -T "$service" node -e '
      const id = process.env.NODE_ID || "1";
      const port = process.env[`NODE_${id}_MONITOR_PORT`] || process.env.MONITOR_PORT || (9080 + Number(id) - 1);
      const rawHost = process.env[`NODE_${id}_MONITOR_HOST`] || process.env.MONITOR_HOST || "127.0.0.1";
      const host = rawHost === "0.0.0.0" ? "127.0.0.1" : rawHost === "::" ? "[::1]" : rawHost;
      fetch(`http://${host}:${port}/health`, {signal: AbortSignal.timeout(4000)})
        .then(r => { if (!r.ok) process.exit(1); }).catch(() => process.exit(1));
    ') >/dev/null 2>&1; do
      if (( SECONDS >= deadline )); then
        echo "[error] $service did not become ready. Check node logs, delegated cap ownership and RPC availability." >&2
        echo "[error] Upgrade is not confirmed; no automatic rollback to the vulnerable package." >&2
        return 1
      fi
      sleep 3
    done
    log "$service ready"
  done <<< "$services"
  [[ "$found" == 1 ]] || { echo "[error] No oracle-node services found; upgrade not confirmed." >&2; return 1; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      NETWORK="${2:-}"
      shift 2
      ;;
    --devnet-compose)
      DEVNET_COMPOSE=1
      shift
      ;;
    --skip-git)
      SKIP_GIT=1
      shift
      ;;
    --skip-env)
      SKIP_ENV=1
      shift
      ;;
    --skip-local-build)
      SKIP_LOCAL_BUILD=1
      shift
      ;;
    --skip-docker)
      SKIP_DOCKER=1
      shift
      ;;
    --no-webview)
      INCLUDE_WEBVIEW=0
      shift
      ;;
    --with-traefik)
      INCLUDE_TRAEFIK=1
      shift
      ;;
    --remove-orphans)
      REMOVE_ORPHANS=1
      shift
      ;;
    --no-traefik)
      INCLUDE_TRAEFIK=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "$NETWORK" in
  auto) NETWORK="$(detect_network)" ;;
  testnet|devnet) ;;
  *)
    echo "Invalid network: $NETWORK" >&2
    usage
    exit 1
    ;;
esac

log "Starting update for $NETWORK"
require_cmd git
require_cmd python3
[[ "$READY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid UPDATE_READY_TIMEOUT" >&2; exit 1; }

if [[ "$SKIP_DOCKER" == 0 ]]; then
  require_cmd docker
fi

if [[ "$SKIP_LOCAL_BUILD" == 0 ]]; then
  if [[ "$SKIP_DOCKER" == 0 ]]; then
    # Docker builds use the pinned Node 24 image; host Node/npm are unnecessary.
    SKIP_LOCAL_BUILD=1
  else
    require_cmd npm
  fi
fi

if [[ "$SKIP_GIT" == 0 ]]; then
  log "Pulling latest code"
  git pull --ff-only origin main
fi

backup_envs

if [[ "$SKIP_ENV" == 0 ]]; then
  ENV_SCRIPT="move/${NETWORK}/update_${NETWORK}_envs.sh"
  if [[ -x "$ENV_SCRIPT" || -f "$ENV_SCRIPT" ]]; then
    log "Syncing ${NETWORK} environment values"
    bash "$ENV_SCRIPT"
  else
    echo "Env update script not found: $ENV_SCRIPT" >&2
    exit 1
  fi
fi

if [[ "$SKIP_LOCAL_BUILD" == 0 ]]; then
  npm_install_and_build node
  npm_install_and_build client
  npm_install_and_build webview
fi

if [[ "$SKIP_DOCKER" == 0 ]]; then
  if [[ "$INCLUDE_TRAEFIK" == 1 || "$INCLUDE_WEBVIEW" == 1 ]]; then
    if ! docker network inspect traefik_proxy >/dev/null 2>&1; then
      log "Creating Docker network traefik_proxy"
      docker network create traefik_proxy
    fi
  fi

  if [[ "$INCLUDE_TRAEFIK" == 1 ]]; then
    docker_up "traefik/docker-compose.yml" "traefik"
  fi

  NODE_COMPOSE="docker-compose.yml"
  if [[ "$DEVNET_COMPOSE" == 1 ]]; then
    NODE_COMPOSE="docker-compose_devnet.yml"
  fi
  docker_up "node/$NODE_COMPOSE" "node"

  if [[ "$INCLUDE_WEBVIEW" == 1 ]]; then
    docker_up "webview/docker-compose.yml" "webview"
  fi

  wait_for_nodes "$NODE_COMPOSE"

  log "Current containers"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
fi

log "Update completed"
