#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required}"
ENV_SECRET="${ENV_SECRET:-}"
DDCLIENT_SECRET="${DDCLIENT_SECRET:-}"
SECRETS_DIR="${SECRETS_DIR:-/run/vaultwarden-gcp-deploy}"

GCLOUD_IMAGE="google/cloud-sdk:slim"

fetch_secret() {
  local secret_name="$1"
  local output_path="$2"
  local output_dir
  local output_name

  output_dir="$(dirname "$output_path")"
  output_name="$(basename "$output_path")"

  docker run --rm \
    -e CLOUDSDK_CORE_PROJECT="$PROJECT_ID" \
    -e SECRET_NAME="$secret_name" \
    -e OUTPUT_NAME="$output_name" \
    -v "$output_dir:/secrets" \
    "$GCLOUD_IMAGE" \
    sh -lc 'gcloud secrets versions access latest --secret="$SECRET_NAME" > "/secrets/$OUTPUT_NAME"'
}

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [ -n "$ENV_SECRET" ]; then
  fetch_secret "$ENV_SECRET" "$SECRETS_DIR/.env"
  chmod 600 "$SECRETS_DIR/.env"
fi

if [ -n "$DDCLIENT_SECRET" ]; then
  fetch_secret "$DDCLIENT_SECRET" "$SECRETS_DIR/ddclient.conf"
  chmod 600 "$SECRETS_DIR/ddclient.conf"
fi
