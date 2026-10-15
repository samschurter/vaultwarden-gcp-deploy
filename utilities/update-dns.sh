#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DDCLIENT_CONF_FILE="${DDCLIENT_CONF_FILE:-/mnt/stateful_partition/run/vaultwarden-gcp-deploy/ddclient.conf}"
DDCLIENT_IMAGE="${DDCLIENT_IMAGE:-lscr.io/linuxserver/ddclient:latest}"
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip"

if [ ! -s "$DDCLIENT_CONF_FILE" ]; then
  echo "dns-update: required ddclient config is missing or empty" >&2
  exit 1
fi

valid_ipv4() {
  local ip="$1" octet
  local -a octets
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
  [ "$ip" != '0.0.0.0' ]
}

for attempt in 1 2 3; do
  external_ip="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
    --noproxy '*' -H 'Metadata-Flavor: Google' "$METADATA_URL" 2>/dev/null || true)"
  if valid_ipv4 "$external_ip"; then
    # Bypass /init and s6 entirely. timeout bounds the whole provider operation,
    # including multiple API calls; each retry gets a fresh ephemeral cache.
    # Suppress raw provider output, which can contain tokens or request URLs.
    if docker run --rm --restart=no --log-driver=none \
      --mount "type=bind,src=$DDCLIENT_CONF_FILE,dst=/config/ddclient.conf,readonly" \
      --mount "type=bind,src=$ROOT_DIR/utilities/ddclient-once.pl,dst=/run/ddclient-once.pl,readonly" \
      --entrypoint /bin/sh "$DDCLIENT_IMAGE" \
      -c 'exec timeout -s KILL 120 /usr/bin/perl /run/ddclient-once.pl "$1"' sh "$external_ip" \
      >/dev/null 2>&1; then
      echo "dns-update: completed for VM external IPv4 $external_ip" >&2
      exit 0
    fi
    echo "dns-update: ddclient failed or timed out (attempt $attempt/3); check provider settings and credentials" >&2
  else
    echo "dns-update: could not obtain a valid metadata external IPv4 (attempt $attempt/3)" >&2
  fi
  if [ "$attempt" -lt 3 ]; then
    sleep 10
  fi
done

echo "dns-update: retries exhausted; application startup aborted" >&2
exit 1
