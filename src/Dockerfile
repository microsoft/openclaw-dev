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

# Create directories for config and state
RUN mkdir -p /root/.openclaw /mnt/state /opt/openclaw-auth

# Install @azure/identity locally where token-refresh.mjs can find it
WORKDIR /opt/openclaw-auth
RUN npm init -y && npm install @azure/identity
WORKDIR /

# Copy pre-configured openclaw.json (points agent to Azure OpenAI via env vars)
# Keep a canonical copy that the entrypoint restores after Azure Files state restore
COPY openclaw.json /root/.openclaw/openclaw.json
COPY openclaw.json /opt/openclaw.json.canonical

# Copy token-refresh wrapper INTO the @azure/identity install dir
# so ESM import resolution finds node_modules as a sibling
COPY token-refresh.mjs /opt/openclaw-auth/token-refresh.mjs
RUN sed -i 's/\r$//' /opt/openclaw-auth/token-refresh.mjs

# Copy entrypoint (handles state restore/save with Azure Files)
# Fix line endings to LF (git on Windows may convert to CRLF)
COPY entrypoint.sh /opt/entrypoint.sh
RUN sed -i 's/\r$//' /opt/entrypoint.sh && chmod +x /opt/entrypoint.sh

# Test script for agent conversations (strips emoji to avoid ACA exec Unicode crashes)
RUN printf '#!/bin/sh\nopenclaw agent -m "$1" 2>&1 | LC_ALL=C tr -cd "\\11\\12\\15\\40-\\176"\n' > /opt/test-agent.sh && chmod +x /opt/test-agent.sh

# OpenClaw gateway port
EXPOSE 18789

ENTRYPOINT ["/opt/entrypoint.sh"]
