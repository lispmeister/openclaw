# OpenClaw Local Patches

Local feature patches applied on top of upstream OpenClaw releases.
These changes are maintained on the `feat/think-hooks` branch of the fork at
https://github.com/lispmeister/openclaw.

## Patches

### `think-hooks` — `message:submit` and `message:response-ready` events

Adds two new internal hook events to fix timing problems with the
`matrix-thinking` workspace hook (Matrix LED display driver):

| Event | Fires when |
|---|---|
| `message:submit` | After transcription and media enrichment, just before agent inference begins |
| `message:response-ready` | After LLM finishes, before the first chunk is delivered to the channel |

**Why:** `message:received` fires before transcription (animation starts too
early for voice messages); `message:sent` fires once per streaming chunk
(animation stops and restarts mid-response).

Source branch: `feat/think-hooks`
Plan: see `think-hook-plan.md` in the repo root.

## Upgrade workflow

When a new upstream release drops, run:

```sh
bash ~/.openclaw/patches/apply-think-hooks.sh
```

The script:

1. Fetches `upstream` (`github.com/openclaw/openclaw`)
2. Rebases `feat/think-hooks` onto `upstream/main`
3. Builds from source (`pnpm build`)
4. Installs to the local npm-global prefix (`~/.npm-global`)
5. Restarts the gateway

If the rebase conflicts (unlikely — all changes are additive), git will pause
for manual resolution. Once resolved:

```sh
git rebase --continue
# then re-run from the build step:
cd /mnt/sylvester/openclaw/openclaw
pnpm build
npm install -g . --prefix /mnt/sylvester/openclaw/.npm-global
pkill -9 -f openclaw-gateway || true
nohup openclaw gateway run --bind loopback --port 18789 --force \
  > /tmp/openclaw-gateway.log 2>&1 &
```

After upgrading, push the rebased branch back to the fork:

```sh
git push --force-with-lease origin feat/think-hooks
```

## Repository layout

```
upstream   https://github.com/openclaw/openclaw        (read-only, never push)
origin     https://github.com/lispmeister/openclaw     (fork, push here)
branch     feat/think-hooks                             (our changes)
main       tracks upstream/main                         (never commit here directly)
```

## Adding a new patch

1. Commit changes to `feat/think-hooks` (or a new branch off it)
2. Push to `origin`
3. Add a section to this README describing the patch
4. Update `apply-think-hooks.sh` if the build/install steps change
