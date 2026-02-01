#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"

# Load .env if it exists (created by docker-setup.sh)
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Read gateway token from openclaw.json (source of truth)
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
CONFIG_FILE="$OPENCLAW_CONFIG_DIR/openclaw.json"
if [[ -f "$CONFIG_FILE" ]]; then
  TOKEN="$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE")"
  if [[ -n "$TOKEN" ]]; then
    OPENCLAW_GATEWAY_TOKEN="$TOKEN"
    export OPENCLAW_GATEWAY_TOKEN
  fi
fi

if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  echo "Error: No gateway token found in $CONFIG_FILE or environment." >&2
  echo "Run ./docker-setup.sh first, or set gateway.auth.token in openclaw.json." >&2
  exit 1
fi

# Require tailscale on the host
if ! command -v tailscale >/dev/null 2>&1; then
  echo "Error: tailscale CLI not found on the host." >&2
  exit 1
fi

GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

# Start Tailscale Serve (tailnet-only HTTPS → localhost:gateway port)
echo "==> Starting Tailscale Serve on port $GATEWAY_PORT"
tailscale serve --bg "$GATEWAY_PORT"

# Start the container
echo "==> Starting gateway container"
COMPOSE_FILES=("-f" "$ROOT_DIR/docker-compose.yml")
if [[ -f "$ROOT_DIR/docker-compose.extra.yml" ]]; then
  COMPOSE_FILES+=("-f" "$ROOT_DIR/docker-compose.extra.yml")
fi

docker compose "${COMPOSE_FILES[@]}" up -d openclaw-gateway

TS_URL="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
echo ""
echo "Gateway is running."
echo "  https://$TS_URL/?token=$OPENCLAW_GATEWAY_TOKEN"
echo ""
echo "To stop:"
echo "  ./shutdown-container.sh"
