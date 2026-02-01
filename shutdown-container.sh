#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Stopping gateway container"
COMPOSE_FILES=("-f" "$ROOT_DIR/docker-compose.yml")
if [[ -f "$ROOT_DIR/docker-compose.extra.yml" ]]; then
  COMPOSE_FILES+=("-f" "$ROOT_DIR/docker-compose.extra.yml")
fi
docker compose "${COMPOSE_FILES[@]}" down

echo "==> Stopping Tailscale Serve"
tailscale serve --bg off 2>/dev/null || true

echo "Done."
