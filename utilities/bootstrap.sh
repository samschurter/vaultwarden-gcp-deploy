#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-/run/vaultwarden-gcp-deploy}"
ENV_FILE="${ENV_FILE:-$SECRETS_DIR/.env}"
DDCLIENT_CONF_FILE="${DDCLIENT_CONF_FILE:-$SECRETS_DIR/ddclient.conf}"

cd "$ROOT_DIR"

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a

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

if docker compose version >/dev/null 2>&1; then
  docker compose up -d --build
else
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$ROOT_DIR:$ROOT_DIR" \
    -w "$ROOT_DIR" \
    docker/compose:latest \
    up -d --build
fi
