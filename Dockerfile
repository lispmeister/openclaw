# Build stage
FROM node:22-bookworm@sha256:cd7bcd2e7a1e6f72052feb023c7f6b722205d3fcab7bbcbd2d1bfdab10b1e935 AS builder

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app
RUN chown node:node /app

ARG OPENCLAW_DOCKER_APT_PACKAGES="git curl jq cron"
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --chown=node:node ui/package.json ./ui/package.json
COPY --chown=node:node patches ./patches
COPY --chown=node:node scripts ./scripts

USER node
RUN pnpm install --frozen-lockfile

# Optionally install Chromium and Xvfb for browser automation.
# Build with: docker build --build-arg OPENCLAW_INSTALL_BROWSER=1 ...
# Adds ~300MB but eliminates the 60-90s Playwright install on every container start.
# Must run after pnpm install so playwright-core is available in node_modules.
USER root
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
      mkdir -p /home/node/.cache/ms-playwright && \
      PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      chown -R node:node /home/node/.cache/ms-playwright && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY --chown=node:node . .
RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# Prune devDependencies and strip non-essential files for production.
# Remove node-llama-cpp platform binaries that don't match the build arch
# (CUDA, Vulkan, ARM, ARM64 — saves ~660 MB).
RUN CI=true pnpm prune --prod && \
    find node_modules \( -name "*.map" -o \( -name "*.md" ! -name "LICENSE*" \) \) -delete 2>/dev/null; \
    ARCH=$(uname -m); \
    case "$ARCH" in x86_64) KEEP="linux-x64" ;; aarch64) KEEP="linux-arm64" ;; armv7l) KEEP="linux-armv7l" ;; *) KEEP="" ;; esac; \
    if [ -n "$KEEP" ]; then \
      find node_modules/.pnpm -maxdepth 1 -type d -name '@node-llama-cpp+*' \
        ! -name "*+${KEEP}@*" -exec rm -rf {} + 2>/dev/null; \
    fi; \
    true

# Pre-download the default local embedding model so the image is self-contained.
# resolveModelFile() caches the GGUF to /root/.node-llama-cpp/models/.
ARG OPENCLAW_EMBEDDING_MODEL="hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf"
RUN node -e " \
  import('node-llama-cpp').then(async (m) => { \
    console.log('Downloading embedding model…'); \
    const path = await m.resolveModelFile(process.env.OPENCLAW_EMBEDDING_MODEL); \
    console.log('Model cached at:', path); \
  }).catch(e => { console.error(e); process.exit(1); }); \
" && ls -lh /root/.node-llama-cpp/models/

# Production stage — slim base (no compilers, fewer system libs)
FROM node:22-bookworm-slim

WORKDIR /app

# Install runtime packages only
ARG OPENCLAW_DOCKER_APT_PACKAGES="git curl jq cron"
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

# Copy built artifacts from builder with correct ownership
COPY --from=builder --chown=node:node /app/dist /app/dist
COPY --from=builder --chown=node:node /app/node_modules /app/node_modules
COPY --from=builder --chown=node:node /app/package.json /app/package.json
COPY --from=builder --chown=node:node /app/pnpm-lock.yaml /app/pnpm-lock.yaml
COPY --from=builder --chown=node:node /app/pnpm-workspace.yaml /app/pnpm-workspace.yaml
COPY --from=builder --chown=node:node /app/.npmrc /app/.npmrc
COPY --from=builder --chown=node:node /app/extensions /app/extensions
COPY --from=builder --chown=node:node /app/docs /app/docs
COPY --from=builder --chown=node:node /app/skills /app/skills
COPY --from=builder --chown=node:node /app/openclaw.mjs /app/openclaw.mjs

# Pre-downloaded embedding model — placed in the node user's home directory
COPY --from=builder --chown=node:node /root/.node-llama-cpp/models /home/node/.node-llama-cpp/models

ENV NODE_ENV=production

# Security hardening: Run as non-root user
# The node:22-bookworm-slim image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges
USER node

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
