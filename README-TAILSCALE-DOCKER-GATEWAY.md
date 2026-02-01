# Running OpenClaw Gateway in Docker with Tailscale

Access the OpenClaw Gateway dashboard from any device on your Tailscale network (tailnet) via HTTPS. The gateway runs in a Docker container on the host, and Tailscale Serve on the host proxies tailnet traffic to it.

## Architecture

```
Tailnet device (browser) --> Tailscale Serve (host, HTTPS) --> localhost:18789 --> Docker port map --> Container gateway
```

- The gateway runs inside Docker, bound to `lan` (all container interfaces).
- Docker maps container port 18789 to the host.
- Tailscale Serve on the host proxies `https://<machine>.tailnet.ts.net/` to `localhost:18789`.
- Tailscale is **not** installed inside the container. It runs on the host only.
- `tailscale serve` exposes the port to your **tailnet only** (not the public internet).

## Prerequisites

- Docker + Docker Compose v2 on the host
- Tailscale installed, logged in, and running on the host
- `jq` installed on the host (used by the boot script to read the gateway token)
- Initial setup completed via `./docker-setup.sh`

## Config changes (openclaw.json)

In `~/.openclaw/openclaw.json`, the `gateway` section needs:

```json
{
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "lan",
    "trustedProxies": ["172.18.0.1"],
    "tailscale": {
      "mode": "off",
      "resetOnExit": false
    },
    "auth": {
      "mode": "token",
      "token": "<your-token>"
    },
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
```

Key settings:

| Setting | Value | Why |
|---------|-------|-----|
| `bind` | `"lan"` | Allows connections from outside the container (Docker bridge network). `"loopback"` would reject them. |
| `tailscale.mode` | `"off"` | Tailscale Serve runs on the host, not inside the container, so the gateway doesn't manage it. |
| `controlUi.dangerouslyDisableDeviceAuth` | `true` | Skips device pairing for the Control UI. Without this, remote browser connections are rejected with "pairing required". Acceptable since access is restricted to your tailnet. |
| `trustedProxies` | `["172.18.0.1"]` | Trusts the Docker bridge gateway IP for forwarded headers from Tailscale Serve. |

## Scripts

### boot-container-with-tailscale.sh

Starts the gateway container and Tailscale Serve, then prints a clickable URL with the token embedded:

```bash
./boot-container-with-tailscale.sh
```

Output:

```
==> Starting Tailscale Serve on port 18789
==> Starting gateway container
Gateway is running.
  https://grey-area.emperor-garibaldi.ts.net/?token=081f8739...
```

The script reads the gateway token from `~/.openclaw/openclaw.json` so the URL always matches the running gateway.

### shutdown-container.sh

Stops the gateway container and turns off Tailscale Serve:

```bash
./shutdown-container.sh
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `gateway.mode: Invalid input` | `mode` set to `"lan"` instead of `"local"` | Set `gateway.mode` to `"local"` and `gateway.bind` to `"lan"` |
| `token mismatch` | Token in URL differs from `openclaw.json` | The boot script reads from `openclaw.json` directly; ensure it exists there |
| `pairing required` | Device auth enabled for Control UI | Add `"controlUi": { "dangerouslyDisableDeviceAuth": true }` |
| Container unreachable from tailnet | `bind` set to `"loopback"` | Change `gateway.bind` to `"lan"` |
