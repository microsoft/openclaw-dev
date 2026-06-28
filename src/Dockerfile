FROM node:24-slim

# OpenClaw's postinstall installs bundled channel runtime deps via npm.
# Some transitive deps reference git+ssh URLs (e.g. whiskeysockets/libsignal-node).
# Without git the postinstall fails silently and the gateway crashes at boot.
# We rewrite SSH→HTTPS so git clones work without SSH keys, and install
# ca-certificates so git can verify GitHub's TLS certificate.
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" && \
    git config --global url."https://github.com/".insteadOf "git@github.com:" && \
    npm install -g openclaw@latest

# Install critical bundled plugin runtime deps that postinstall misses
RUN cd /usr/local/lib/node_modules/openclaw && \
    npm install --omit=dev --no-save --package-lock=false \
      @microsoft/teams.api@2.0.6 @microsoft/teams.apps@2.0.6 \
      @buape/carbon@0.14.0 @larksuiteoapi/node-sdk@^1.60.0 \
      @slack/bolt@^4.6.0 grammy@^1.0.0 @grammyjs/runner@^2.0.3 \
      express@^5.2.1 2>/dev/null || true

# Create directories for config and state
RUN mkdir -p /root/.openclaw /mnt/state /opt/openclaw-auth

# Install the Microsoft Teams channel as an OpenClaw plugin.
# As of 2026.4.10, msteams shipped as an external npm plugin (@openclaw/msteams)
# rather than a bundled extension. Without this the channel never starts even
# when channels.msteams.enabled=true in openclaw.json.
# The openclaw CLI registers the plugin in /root/.openclaw/npm/node_modules
# and writes an install record so the gateway loads it at boot.
RUN openclaw plugins install npm:@openclaw/msteams || \
    ( mkdir -p /root/.openclaw/npm && cd /root/.openclaw/npm && \
      npm init -y >/dev/null && \
      npm install --omit=dev --no-save --package-lock=false @openclaw/msteams )

# Install @azure/identity (for auth-proxy.mjs) and http-proxy (for gateway-proxy.mjs).
# gateway-proxy.mjs is a tiny reverse proxy that routes /api/messages (Bot
# Framework webhook) to the msteams plugin on :3978 and everything else to the
# openclaw gateway on :18788. This is required because the msteams plugin
# binds its own Express server on a separate port — without the proxy, ACA's
# single public ingress on :18789 only reaches the gateway and the bot 404s.
WORKDIR /opt/openclaw-auth
RUN npm init -y && npm install @azure/identity http-proxy
WORKDIR /

# Copy pre-configured openclaw.json (points agent to Azure OpenAI via env vars)
# Keep a canonical copy that the entrypoint restores after Azure Files state restore
COPY openclaw.json /root/.openclaw/openclaw.json
COPY openclaw.json /opt/openclaw.json.canonical

# Copy auth-proxy INTO the @azure/identity install dir so ESM import
# resolution finds node_modules as a sibling. The proxy injects a fresh
# Entra ID bearer token on every forwarded request, so OpenClaw never sees
# token expiry. Replaces the broken token-refresh.mjs (env-var refresh
# couldn't propagate to the spawned gateway child).
COPY auth-proxy.mjs /opt/openclaw-auth/auth-proxy.mjs
RUN sed -i 's/\r$//' /opt/openclaw-auth/auth-proxy.mjs

# Gateway proxy: routes /api/messages -> msteams plugin on :3978,
# everything else -> openclaw gateway on :18788. Listens on :18789 (the
# ACA ingress targetPort).
COPY gateway-proxy.mjs /opt/openclaw-auth/gateway-proxy.mjs
RUN sed -i 's/\r$//' /opt/openclaw-auth/gateway-proxy.mjs

# PERMANENT FIX: extend the @openclaw/msteams plugin's Bot Framework serviceUrl
# allowlist to include directline.botframework.com so Direct Line / Web Chat
# replies are not blocked by the plugin's SSRF guard. See
# patch-msteams-allowlist.mjs for the full explanation.
COPY patch-msteams-allowlist.mjs /opt/patch-msteams-allowlist.mjs
RUN sed -i 's/\r$//' /opt/patch-msteams-allowlist.mjs && \
    node /opt/patch-msteams-allowlist.mjs || echo "[Dockerfile] patch-msteams-allowlist failed but continuing"

# ---------------------------------------------------------------------------
# Execution layer (EXECUTION_MODE=sandbox): the Gateway launches the sandbox
# MCP server, which offloads untrusted tool execution to ephemeral ACA
# Sandboxes. Needs Python + the MCP/azure SDKs + the `aca` CLI + the adapter
# package. Inert unless EXECUTION_MODE=sandbox (entrypoint registers the MCP
# server only then), so this adds capability without changing inproc behavior.
# ---------------------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv curl && \
    # The `aca` CLI (preview, .NET single-file) is built against glibc 2.38, but
    # the OpenClaw base image is Debian 12 bookworm (glibc 2.36). glibc is
    # backward compatible (newer libc runs older binaries), so pull libc6 from
    # Debian trixie to satisfy aca's floor — node keeps working against 2.41.
    echo 'deb http://deb.debian.org/debian trixie main' > /etc/apt/sources.list.d/trixie.list && \
    apt-get update && \
    apt-get install -y -t trixie libc6 && \
    rm -f /etc/apt/sources.list.d/trixie.list && \
    rm -rf /var/lib/apt/lists/* && \
    pip3 install --no-cache-dir --break-system-packages "mcp>=1.2" "anyio>=4.0" "azure-identity>=1.19" "requests>=2.32" && \
    (curl -fsSL https://aka.ms/aca-cli-install | sh || echo "[Dockerfile] aca CLI install deferred to runtime") && \
    # Fail the build loudly if aca still can't run (glibc floor not met).
    aca --version
ENV PATH="/root/.aca/bin:${PATH}" \
    PYTHONPATH="/opt:${PYTHONPATH}"
COPY sandbox_mcp /opt/sandbox_mcp
# Make `sandbox_mcp` importable WITHOUT PYTHONPATH. The OpenClaw MCP host spawns
# stdio servers with a scrubbed environment and hard-blocks PYTHONPATH (anti
# code-injection), so `python3 -m sandbox_mcp.server` must resolve the package
# from site-packages. Symlink it next to the already-installed `mcp` package.
RUN SP="$(python3 -c 'import mcp,os;print(os.path.dirname(os.path.dirname(mcp.__file__)))')" && \
    ln -sfn /opt/sandbox_mcp "$SP/sandbox_mcp" && \
    python3 -c "import sandbox_mcp; print('[Dockerfile] sandbox_mcp importable at', sandbox_mcp.__file__)"

# Copy entrypoint (handles state restore/save with Azure Files)
# Fix line endings to LF (git on Windows may convert to CRLF)
COPY entrypoint.sh /opt/entrypoint.sh
RUN sed -i 's/\r$//' /opt/entrypoint.sh && chmod +x /opt/entrypoint.sh

# Test script for agent conversations (strips emoji to avoid ACA exec Unicode crashes)
RUN printf '#!/bin/sh\nopenclaw agent -m "$1" 2>&1 | LC_ALL=C tr -cd "\\11\\12\\15\\40-\\176"\n' > /opt/test-agent.sh && chmod +x /opt/test-agent.sh

# OpenClaw gateway port
EXPOSE 18789

ENTRYPOINT ["/opt/entrypoint.sh"]
