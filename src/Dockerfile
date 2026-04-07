FROM node:24-slim

# Install OpenClaw and fix missing bundled-plugin dependencies
# OpenClaw's bundled channel plugins (Discord, Feishu, Slack, etc.) require packages
# that aren't declared in package.json. Running npm install inside the module dir
# resolves all transitive deps from the lockfile.
# See: https://github.com/openclaw/openclaw/issues/62749
RUN npm install -g openclaw@latest && \
    cd /usr/local/lib/node_modules/openclaw && npm install 2>/dev/null || true

# Create directories for config and state
RUN mkdir -p /root/.openclaw /mnt/state /opt/openclaw-auth

# Install @azure/identity locally where token-refresh.mjs can find it
WORKDIR /opt/openclaw-auth
RUN npm init -y && npm install @azure/identity
WORKDIR /

# Copy pre-configured openclaw.json (points agent to Azure OpenAI via env vars)
COPY openclaw.json /root/.openclaw/openclaw.json

# Copy token-refresh wrapper INTO the @azure/identity install dir
# so ESM import resolution finds node_modules as a sibling
COPY token-refresh.mjs /opt/openclaw-auth/token-refresh.mjs
RUN sed -i 's/\r$//' /opt/openclaw-auth/token-refresh.mjs

# Copy entrypoint (handles state restore/save with Azure Files)
# Fix line endings to LF (git on Windows may convert to CRLF)
COPY entrypoint.sh /opt/entrypoint.sh
RUN sed -i 's/\r$//' /opt/entrypoint.sh && chmod +x /opt/entrypoint.sh

# OpenClaw gateway port
EXPOSE 18789

ENTRYPOINT ["/opt/entrypoint.sh"]
