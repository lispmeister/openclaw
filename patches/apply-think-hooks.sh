#!/usr/bin/env bash
# apply-think-hooks.sh
#
# Rebases feat/think-hooks onto the latest upstream main, builds, and
# installs the result into the local npm-global prefix.
#
# Usage: bash ~/.openclaw/patches/apply-think-hooks.sh

set -euo pipefail

REPO=/mnt/sylvester/openclaw/openclaw
NPM_PREFIX=/mnt/sylvester/openclaw/.npm-global
BRANCH=feat/think-hooks
GATEWAY_LOG=/tmp/openclaw-gateway.log
GATEWAY_PORT=18789

echo "==> Fetching upstream..."
cd "$REPO"
git fetch upstream

echo "==> Rebasing $BRANCH onto upstream/main..."
git checkout "$BRANCH"
git rebase upstream/main

echo "==> Building..."
pnpm build

echo "==> Installing to $NPM_PREFIX..."
npm install -g . --prefix "$NPM_PREFIX"

echo "==> Restarting gateway..."
pkill -9 -f openclaw-gateway || true
nohup openclaw gateway run --bind loopback --port "$GATEWAY_PORT" --force \
  > "$GATEWAY_LOG" 2>&1 &

echo ""
echo "Done. Verify with:"
echo "  openclaw --version"
echo "  tail -f $GATEWAY_LOG"
