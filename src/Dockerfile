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

# Copy entrypoint (handles state restore/save with Azure Files)
# Fix line endings to LF (git on Windows may convert to CRLF)
COPY entrypoint.sh /opt/entrypoint.sh
RUN sed -i 's/\r$//' /opt/entrypoint.sh && chmod +x /opt/entrypoint.sh

# Test script for agent conversations (strips emoji to avoid ACA exec Unicode crashes)
RUN printf '#!/bin/sh\nopenclaw agent -m "$1" 2>&1 | LC_ALL=C tr -cd "\\11\\12\\15\\40-\\176"\n' > /opt/test-agent.sh && chmod +x /opt/test-agent.sh

# OpenClaw gateway port
EXPOSE 18789

ENTRYPOINT ["/opt/entrypoint.sh"]
