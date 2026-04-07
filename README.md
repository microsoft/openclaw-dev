# 🦞 OpenClaw in the Microsoft Cloud

Run [OpenClaw](https://github.com/openclaw/openclaw) — the open-source personal AI assistant — hosted in a secure, always-on Azure sandbox. No local machine needed. No API keys to manage. Just your assistant, running 24/7 in your own cloud.

## Why host OpenClaw in the cloud?

| | Local (Mac/PC) | Cloud (this template) |
|---|---|---|
| **Availability** | Only when your machine is on | Always on, 24/7 |
| **Security** | Runs with your user permissions | Network-isolated VNet sandbox — no public internet access |
| **API keys** | You manage and rotate them | Zero keys — managed identity with auto-refreshing Entra ID tokens |
| **State** | Lost if disk fails | Persisted on Azure Files — survives restarts, upgrades, crashes |
| **Channels** | Work when your machine is awake | WhatsApp, Telegram, Slack, Discord always connected |
| **Cost** | Your hardware | ~$2-5/day on Azure (stop anytime with `msftclaw stop`) |

## Quick start

```bash
git clone https://github.com/microsoft/openclaw
cd openclaw

# macOS/Linux/WSL
./msftclaw up

# Windows (cmd or PowerShell)
.\msftclaw.cmd up
```

That's it. The CLI handles Azure login, infrastructure provisioning, container build, and deployment.

## CLI commands

```
msftclaw up         Deploy OpenClaw to Azure
msftclaw test       Verify it's working
msftclaw start      Start the agent
msftclaw stop       Stop the agent (state preserved, no charges)
msftclaw restart    Restart the agent
msftclaw status     Check agent status
msftclaw logs       Stream live logs
msftclaw deploy     Rebuild and deploy after code changes
msftclaw down       Delete all Azure resources
msftclaw login      Switch Azure account
```

## Testing your deployment

After `msftclaw up`, run `msftclaw test` to verify the infrastructure is healthy. Then open the Azure Portal Console to interact with the agent:

1. **Portal** → Container Apps → your app → **Console**
2. Select `/bin/bash`
3. Run:

```bash
# Health check
curl -s http://localhost:18789/api/health

# Send a test message
openclaw agent --message "Hello from the Microsoft Cloud!"

# Verify managed identity auth
echo "Auth: $AZURE_OPENAI_AUTH"
echo "Endpoint: $OPENAI_BASE_URL"
```

## What can I do with this?

This template gives you your own **always-on AI assistant in a secure enterprise sandbox** — accessible from Microsoft Teams on your phone, laptop, or any device with your work profile. Here's what people actually use it for:

### Personal productivity (try these first)

- **"Summarize my meeting notes"** — paste or forward meeting transcripts via Teams DM and get structured action items back
- **"Draft a reply to this email"** — send the email thread, get a polished response you can copy-paste
- **"Explain this error log"** — paste a stack trace or error from any system, get a plain-English diagnosis
- **"Research this topic"** — ask the agent to research a topic with web search and get a structured brief with citations

### Enterprise workflows (natural next steps)

- **PR review assistant** — connect to a Teams channel, paste a PR link, get feedback on code quality and security
- **Slack/Teams auto-support** — point the agent at a support channel, it responds to common questions and escalates the rest
- **Document drafting** — "Write a one-pager on X for my VP" — iterates on tone, structure, and content until you're satisfied
- **Weekly status reports** — the agent remembers your session history, so "write my weekly status" actually works because it's been tracking your conversations

### Why Teams + mobile works well

OpenClaw has a [bundled Microsoft Teams plugin](https://docs.openclaw.ai/channels/msteams) that works with your existing Azure AD / Entra ID tenant. Once configured:

- **DM the bot from Teams desktop or mobile** — works on your phone's work profile, no personal apps needed
- **Add it to a team channel** — the agent responds when @mentioned, with per-channel tool policies
- **Adaptive Cards** — the agent can send polls, structured responses, and interactive cards
- **File handling** — send documents via Teams DM, the agent processes them and responds

### What works vs. desktop

| Capability | Cloud sandbox | Desktop (Mac/PC) |
|---|---|---|
| Agent + gateway | ✅ | ✅ |
| Teams / Slack / Discord / Telegram | ✅ Always connected | ⚠️ Only when machine is on |
| Browser automation | ✅ (headless Chromium) | ✅ |
| Code execution | ✅ (sandboxed) | ✅ |
| Skills + workspace | ✅ (persisted on Azure Files) | ✅ |
| Camera / screen capture / notifications | ❌ (pair a device node) | ✅ |
| Voice Wake / Talk Mode | ❌ (pair an iOS/Android node) | ✅ |

## Security

Everything is network-isolated. Nothing is accessible from the public internet.

| Layer | Control |
|---|---|
| **Network** | VNet with private endpoints — all traffic stays internal |
| **ACA** | `internal: true` — no public FQDN |
| **Azure OpenAI** | `publicNetworkAccess: Disabled`, `disableLocalAuth: true` |
| **Storage** | `publicNetworkAccess: Disabled` — state files only via private endpoint |
| **Auth** | Managed identity + `getBearerTokenProvider` — auto-refreshing Entra ID tokens |
| **RBAC** | `Cognitive Services User` scoped to the specific Azure OpenAI resource |

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| `msftclaw test` shows "Activating" | Container is pulling the image for the first time | Wait 1-2 minutes and retry |
| `ActivationFailed` status | Container entrypoint crashed | Run `msftclaw logs` — common cause: CRLF line endings (fixed in current Dockerfile with `sed -i 's/\r$//'`) |
| `ERR_MODULE_NOT_FOUND: @azure/identity` | Node.js ESM can't find packages installed globally | The Dockerfile installs `@azure/identity` locally in `/opt/openclaw-auth/` alongside `token-refresh.mjs` — ESM resolves from the file's directory |
| `az containerapp exec` SSL error | The ACA environment is internal-only (VNet-isolated) | Use Azure Portal Console instead: Portal → Container App → Console → `/bin/bash` |
| Can't access the gateway FQDN in browser | FQDN is `.internal.*` — not publicly routable | Connect via VPN, Bastion, or Portal Console. This is the security hardening working correctly |
| Pre-flight warning about `roleAssignments/write` | azd checks permissions before deploying | Type `Y` to proceed — the deployment works. The warning is advisory only |
| `disableLocalAuth` prevents `list-keys` | No API keys exist by design | This is expected — managed identity is the only auth method |
| Logs show `[auth] Fatal` | Managed identity token acquisition failed | Verify the `Cognitive Services User` role is assigned: `az role assignment list --scope <openai-resource-id>` |
| Docker build uses cached (broken) image | `azd deploy` reuses Docker cache | Force rebuild: `docker build --no-cache -t <tag> ./src` then push and update |
| State lost after restart | Azure Files mount not working | Check `az containerapp show` for volume mount config — verify the storage account and file share exist |
| WORKDIR changes in Dockerfile break paths | Node.js ESM resolves imports from the file's location, not CWD | Place `.mjs` files in the same directory as their `node_modules` |

## Clean up

```bash
msftclaw down
```

---

## Advanced: architecture

<details>
<summary>Click to expand full architecture details</summary>

### What's deployed

| Resource | Purpose |
|---|---|
| Virtual Network | Network isolation — all resources communicate via private endpoints |
| Azure OpenAI (GPT-5-mini) | LLM backend via `/openai/v1` (public access disabled, keyless only) |
| Azure Container Apps (internal) | Hosts the OpenClaw gateway — no public ingress |
| Azure Files | Persists state (credentials, workspace, sessions) across restarts |
| Azure Container Registry | Stores the custom OpenClaw container image |
| Private Endpoints + DNS Zones | Azure OpenAI and Storage reachable only inside the VNet |
| Log Analytics | Gateway and container logs |

### How Azure OpenAI integration works

OpenClaw natively uses the OpenAI Node.js SDK. The container sets `OPENAI_BASE_URL` to the Azure OpenAI v1 endpoint. Authentication uses `getBearerTokenProvider` from `@azure/identity` ([same pattern as the Azure OpenAI Starter Kit](https://github.com/Azure-Samples/azure-openai-starter/blob/main/src/typescript/responses_example_entra.ts)):

```js
const credential = new DefaultAzureCredential();
const tokenProvider = getBearerTokenProvider(credential,
    "https://cognitiveservices.azure.com/.default");
const token = await tokenProvider();
```

The token-refresh wrapper (`src/token-refresh.mjs`) sets the bearer token as `OPENAI_API_KEY`, spawning OpenClaw with it. A periodic refresh (every 45 min) keeps tokens fresh.

### Auth flow

```
Container App                    Entra ID                    Azure OpenAI
     │                              │                             │
     │  1. getBearerTokenProvider() │                             │
     │  ──────────────────────────▶ │                             │
     │     scope: cognitiveservices │                             │
     │       .azure.com/.default   │                             │
     │                              │                             │
     │  2. Bearer token (JWT)       │                             │
     │  ◀────────────────────────── │                             │
     │                              │                             │
     │  3. Set OPENAI_API_KEY=token │                             │
     │  ─── spawn openclaw gateway  │                             │
     │                              │                             │
     │  4. OpenAI SDK request       │                             │
     │  ─────────────────────────────────────────────────────────▶│
     │     Authorization: Bearer <token>                          │
     │     POST /openai/v1/chat/completions                       │
     │                              │                             │
     │  5. Response                 │                             │
     │  ◀─────────────────────────────────────────────────────────│
     │                              │                             │
     │  ... (every 45 min)          │                             │
     │  6. tokenProvider() refresh  │                             │
     │  ──────────────────────────▶ │                             │
     │  7. Fresh token              │                             │
     │  ◀────────────────────────── │                             │
     │  8. Update OPENAI_API_KEY    │                             │
     │                              │                             │
```

### Managing the agent

```bash
# Stop (scale to 0 — no compute charges, state preserved)
msftclaw stop

# Start (scale back to 1 — state restored from Azure Files)
msftclaw start

# Restart (new revision, same config)
msftclaw restart

# Check status
msftclaw status

# Stream logs
msftclaw logs

# Redeploy after code changes
msftclaw deploy
```

### Project structure

```
msftclaw                    # Bash CLI (macOS/Linux/WSL)
msftclaw.cmd                # Windows CLI (cmd/PowerShell)
azure.yaml                  # azd service definition

src/
  Dockerfile                # Container image (node:24-slim + openclaw + @azure/identity)
  entrypoint.sh             # State restore/save + gateway launch
  token-refresh.mjs         # Managed identity → bearer token for OpenAI SDK
  openclaw.json             # Agent config (model: openai/gpt-5-mini)

infra/
  main.bicep                # Top-level orchestration
  main.parameters.json      # azd parameter bindings
  resources.bicep           # Azure OpenAI resource
  aca.bicep                 # VNet, ACA, storage, private endpoints, RBAC

validate.sh                 # Automated validation script
```

</details>
