# Issue: OpenClaw Gateway Hangs During Startup in ACA

## Summary

The OpenClaw gateway container starts in Azure Container Apps, but the gateway process **hangs during initialization** — it prints `[gateway] starting...` and never reaches `[gateway] ready`. The process stays alive but never binds to port 18789, causing the startup probe to fail and ACA to eventually mark the revision as Failed.

The same image starts in ~2.5 seconds locally.

## Breakthrough: the gateway is NOT crashing

Previous debugging assumed the container was exiting. With a diagnostic entrypoint that captures gateway output and keeps the container alive via `tail -f /dev/null`, we proved:

1. **The container stays alive** — `tail -f /dev/null` keeps it running
2. **The gateway process is alive** — `kill -0 $GW_PID` succeeds after 5 seconds
3. **The gateway is STUCK** — output stops at `[gateway] starting...`, never reaches `[gateway] ready` or `starting HTTP server...`
4. **This is NOT a managed identity issue** — happens with `AZURE_OPENAI_AUTH=api-key` and a dummy key too
5. **This is NOT a config issue** — the config is `{"gateway":{"mode":"local"}}` and validates correctly
6. **This is NOT a module loading issue** — `openclaw --version` works fine

### ACA console log (captured from Log Analytics):
```
Container starting...
Hostname: openclaw-5kylywa2qbx3s--v16-7959599cd4-dp6hl
AZURE_OPENAI_AUTH=api-key
OPENAI_API_KEY=dummy-test-key
OPENAI_BASE_URL=https://openai-5kylywa2qbx3s.openai.azure.com/openai/v1/
OpenClaw version: 2026.4.7 (5050017)
Attempting gateway start...
Gateway is running (PID 22)
[gateway] loading configuration…
[gateway] resolving authentication…
[gateway] starting...
<--- HANGS HERE - never prints "ready" or "starting HTTP server" --->
```

### Local docker run (same image, same env vars):
```
[gateway] loading configuration…
[gateway] resolving authentication…
[gateway] starting...
[gateway] starting HTTP server...
[canvas] host mounted at http://0.0.0.0:18789/
[gateway] ready (5 plugins, 2.4s)
```

## What's been fixed so far

| # | Issue | Root Cause | Fix |
|---|---|---|---|
| 1 | `Cannot find module @buape/carbon` | `node:24-slim` lacks `git` + `ca-certificates` needed by OpenClaw's `postinstall-bundled-plugins.mjs` | Dockerfile: `apt-get install git ca-certificates` + `git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"` |
| 2 | `Config invalid: Unrecognized key "agent"` | OpenClaw 2026.4.5 removed the `agent` top-level key | Changed `openclaw.json` from `{"agent":{"model":"openai/gpt-5-mini"}}` to `{"gateway":{"mode":"local"}}` |
| 3 | `PortIsLoopback` — ACA can't reach port | Gateway defaults to `127.0.0.1` | Added `--bind lan` to gateway startup args |
| 4 | `set -e` + backgrounded process = silent exit | `set -e` + `&` + `wait` made the entrypoint exit when the child crashed | Removed `set -e`, changed to foreground execution |
| 5 | Token acquisition crash kills container | `DefaultAzureCredential` fails before IMDS is ready | Start gateway first, acquire token async with retries |
| 6 | Stale `openclaw.json` from Azure Files | State restore may copy old config over the correct one | Dockerfile keeps a canonical copy; entrypoint restores it after state restore |

## The remaining problem

After all fixes, the gateway starts correctly:
- Locally: `[gateway] ready (5 plugins, 2.4s)` — stays alive
- In ACA: exits with code 0 within 1-3 seconds of starting

### Key evidence

**ACA system logs (both envs):**
```
Container 'openclaw' was terminated with exit code '0' and reason 'ProcessExited'
```

**Local docker run (same image, same env vars):**
```
[openclaw] Starting gateway on port 18789...
[auth] Starting gateway (token will be acquired in background)...
[auth] Token attempt 1/24 failed: ChainedTokenCredential authentication failed.
[gateway] loading configuration…
[gateway] resolving authentication…
[gateway] starting...
[gateway] starting HTTP server...
[canvas] host mounted at http://0.0.0.0:18789/
[gateway] ready (5 plugins, 2.4s)
[plugins] embedded acpx runtime backend ready
# ... stays alive indefinitely
```

### Architecture

```
entrypoint.sh (foreground, no set -e)
  └─ restore_state (copies credentials/workspace/sessions from Azure Files)
  └─ cp canonical openclaw.json
  └─ node token-refresh.mjs --bind lan --port 18789
       ├─ spawns: openclaw gateway --bind lan --port 18789 (child, stdio: inherit)
       ├─ retries token acquisition async (24 attempts × 5s)
       └─ on child exit → process.exit(child_code)
```

## Hypotheses to investigate

### 1. Network/DNS resolution blocking (MOST LIKELY)
- Between `starting...` and `starting HTTP server...`, OpenClaw likely does network I/O:
  - DNS resolution for the OpenAI endpoint
  - Bonjour/mDNS gateway name registration (seen in local logs: `[bonjour] gateway name conflict resolved`)
  - Plugin initialization that phones home
- ACA containers may have restricted mDNS or different DNS resolver behavior
- **Test**: Run gateway with `--no-bonjour` or equivalent flag if available
- **Test**: Add `strace -e trace=network` to capture what network calls hang
- **Test**: Try `openclaw gateway --bind lan --port 18789 --compact` or other flags that skip network init

### 2. Bonjour/mDNS hanging in ACA
- The local logs show `[bonjour] gateway name conflict resolved` after `ready`
- In ACA, mDNS multicast may be blocked or timeout slowly
- OpenClaw may do Bonjour registration BEFORE listening on the port
- **Test**: Set `gateway.bonjour.enabled: false` in openclaw.json if schema supports it
- **Test**: Check if there's a `NO_BONJOUR` or `OPENCLAW_NO_BONJOUR` env var

### 3. Chromium/browser startup blocking
- Local logs show `[browser] control listening on http://127.0.0.1:18791/`  
- OpenClaw might spawn a headless Chromium during init
- In ACA's limited container, Chromium might hang on startup
- **Test**: Set an env var to disable browser/UI features
- **Test**: Check if `--headless` or browser-related config exists

### 4. File system write blocking on Azure Files
- The gateway writes to `~/.openclaw/openclaw.json` during startup (config writes)
- Azure Files mount might cause slow I/O on first write
- **Test**: Pre-populate the config with all required auto-generated fields

## Recommended investigation steps

```bash
# 1. Most promising: try disabling Bonjour/mDNS
# In openclaw.json, try adding:
# {"gateway":{"mode":"local","bonjour":{"enabled":false}}}
# Or set env var: OPENCLAW_NO_BONJOUR=1

# 2. Check what the gateway is actually doing when stuck
# Deploy with strace wrapper:
# ENTRYPOINT: strace -f -e trace=network openclaw gateway --bind lan --port 18789

# 3. Try increasing resources (rule out OOM/throttling)
az containerapp update --name <app> --resource-group <rg> \
  --cpu 2 --memory 4Gi

# 4. Try with no bundled plugins (env var to skip plugin loading)
# Check: OPENCLAW_DISABLE_BUNDLED_PLUGIN_POSTINSTALL=1
# Or: openclaw gateway --bind lan --port 18789 --no-plugins (if flag exists)

# 5. Get the full gateway log from the running diagnostic container
az containerapp exec --name openclaw-5kylywa2qbx3s \
  --resource-group achand-openclaw-3 --command "cat /tmp/gw.log"
```

## Files involved

| File | Purpose |
|---|---|
| `src/Dockerfile` | Image build — installs git, ca-certs, openclaw, @azure/identity |
| `src/entrypoint.sh` | Container entry — state restore/save, launches gateway |
| `src/token-refresh.mjs` | Managed identity wrapper — spawns gateway, acquires tokens |
| `src/openclaw.json` | Gateway config — `{"gateway":{"mode":"local"}}` |
| `infra/aca.bicep` | ACA infra — startup/liveness probes, scale, env vars |

## Environments

| Environment | RG | Container App | ACR | Type |
|---|---|---|---|---|
| `openclaw-dev` | `achand-openclaw-1` | `openclaw-76y6k6w65rdpo` | `acr76y6k6w65rdpo` | VNet-internal |
| `openclaw-express` | `achand-openclaw-express` | `openclaw-7dgxunjscqoyq` | `acr7dgxunjscqoyq` | Public ingress |

## Quick deploy command

```powershell
$env:AZURE_CONFIG_DIR = "$PWD\.azure"
$ACR = "acr7dgxunjscqoyq"  # or acr76y6k6w65rdpo for dev
$TAG = "vN-$(Get-Date -Format 'yyyyMMddHHmmss')"
docker build -t "$ACR.azurecr.io/openclaw-azure/openclaw-openclaw-express:$TAG" ./src
az acr login --name $ACR
docker push "$ACR.azurecr.io/openclaw-azure/openclaw-openclaw-express:$TAG"
az containerapp update --name openclaw-7dgxunjscqoyq --resource-group achand-openclaw-express `
  --image "$ACR.azurecr.io/openclaw-azure/openclaw-openclaw-express:$TAG" `
  --revision-suffix "vN" --min-replicas 1 --max-replicas 1
```
