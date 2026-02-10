#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
ANTFARM_PORT="${ANTFARM_PORT:-3333}"
TOKEN="$(jq -r '.gateway.auth.token' ~/.openclaw/openclaw.json)"

docker compose -f "$ROOT_DIR/docker-compose.yml" up -d openclaw-gateway
sudo tailscale serve --bg "$GATEWAY_PORT"

TS_URL="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
echo "https://$TS_URL/?token=$TOKEN"
