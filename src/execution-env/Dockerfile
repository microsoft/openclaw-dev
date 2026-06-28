# OpenClaw execution-environment image.
#
# This is the *common base* for sandbox workers (decision rule: truly common
# OS/runtime/tools -> disk image). It is built once per version, pushed to ACR,
# converted to a sandbox disk image (hash-gated), and every worker boots/forks
# from it. Per-role differences (creds, egress, payload) are injected at
# RUNTIME, never baked here.
#
# Keep it lean: image size drives disk-image build time. Heavy, optional
# capabilities (a real browser) are behind the INSTALL_BROWSER build arg.

FROM node:24-slim

ARG INSTALL_BROWSER=false

# Core runtimes + tools an agent commonly needs for shell/codegen/file ops.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        git curl ca-certificates jq ripgrep unzip xz-utils \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Optional: Playwright + Chromium for browser automation workers.
# Enable with: az acr build --build-arg INSTALL_BROWSER=true ...
RUN if [ "$INSTALL_BROWSER" = "true" ]; then \
        npm install -g playwright@latest && \
        npx --yes playwright install --with-deps chromium ; \
    fi

# A predictable workspace and an env marker the warmup/specialize steps detect.
RUN mkdir -p /workspace && echo "openclaw-exec" > /etc/openclaw-exec-env
WORKDIR /workspace

# Sandboxes execute commands via the data plane; this CMD just keeps a benign
# foreground process so the microVM has a stable PID 1 when booted.
CMD ["sleep", "infinity"]
