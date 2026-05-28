#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-/run/vaultwarden-gcp-deploy}"
ENV_FILE="${ENV_FILE:-$SECRETS_DIR/.env}"
DDCLIENT_CONF_FILE="${DDCLIENT_CONF_FILE:-$SECRETS_DIR/ddclient.conf}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-$SECRETS_DIR/compose.env}"
COMPOSE_RUNNER_IMAGE="${COMPOSE_RUNNER_IMAGE:-docker:27.4.1-cli}"

load_env_file() {
  local env_path="$1"
  local line
  local key
  local value

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"

    case "$line" in
      ''|'#'*)
        continue
        ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        export "$key=$value"
        ;;
      *)
        printf 'Error: invalid env file line: %s\n' "$line" >&2
        return 1
        ;;
    esac
  done < "$env_path"
}

require_bootstrap_inputs() {
  if [ ! -s "$ENV_FILE" ]; then
    printf 'Error: required env file is missing or empty: %s\n' "$ENV_FILE" >&2
    return 1
  fi

  if grep -q '^  ddns:' docker-compose.yml && [ ! -s "$DDCLIENT_CONF_FILE" ]; then
    printf 'Error: required ddclient config is missing or empty: %s\n' "$DDCLIENT_CONF_FILE" >&2
    return 1
  fi
}

write_compose_env_file() {
  : > "$COMPOSE_ENV_FILE"

  if [ -f "$ENV_FILE" ]; then
    cat "$ENV_FILE" >> "$COMPOSE_ENV_FILE"
    printf '\n' >> "$COMPOSE_ENV_FILE"
  fi

  printf 'VWGC_DDCLIENT_CONF=%s\n' "$DDCLIENT_CONF_FILE" >> "$COMPOSE_ENV_FILE"
  chmod 600 "$COMPOSE_ENV_FILE"
}

run_compose() {
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$ROOT_DIR:$ROOT_DIR" \
    -v "$SECRETS_DIR:$SECRETS_DIR:ro" \
    -w "$ROOT_DIR" \
    "$COMPOSE_RUNNER_IMAGE" \
    compose \
    --env-file "$COMPOSE_ENV_FILE" \
    "$@"
}

cd "$ROOT_DIR"

require_bootstrap_inputs

if [ -f "$ENV_FILE" ]; then
  load_env_file "$ENV_FILE"

  export VWGC_ENV_FILE="$ENV_FILE"
  export VWGC_DDCLIENT_CONF="$DDCLIENT_CONF_FILE"

  if printf ',%s,' "${BACKUP:-}" | grep -qi ',rclone,'; then
    host_rclone_dir="$ROOT_DIR/vaultwarden/rclone"
    host_conf="$host_rclone_dir/rclone.conf"
    mkdir -p "$host_rclone_dir"

    if [ ! -f "$host_conf" ]; then
      cat > "$host_conf" <<'EOF'
[gcs]
type = google cloud storage
provider = GCE
env_auth = true
EOF
      chmod 600 "$host_conf"
    fi
  fi
fi

write_compose_env_file
run_compose up -d --build --quiet-pull
