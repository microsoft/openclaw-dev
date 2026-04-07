FROM node:24-slim

# Install OpenClaw and Azure Identity SDK for managed identity token auth
RUN npm install -g openclaw@latest && \
    npm install -g @azure/identity

# Create directories for config and state
RUN mkdir -p /root/.openclaw /mnt/state

# Copy pre-configured openclaw.json (points agent to Azure OpenAI via env vars)
COPY openclaw.json /root/.openclaw/openclaw.json

# Copy token-refresh wrapper (managed identity -> bearer token for OpenAI SDK)
COPY token-refresh.mjs /opt/token-refresh.mjs

# Copy entrypoint (handles state restore/save with Azure Files)
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

# OpenClaw gateway port
EXPOSE 18789

ENTRYPOINT ["/opt/entrypoint.sh"]
