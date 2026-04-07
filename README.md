# OpenClaw on Azure

azd template that deploys [OpenClaw](https://github.com/openclaw/openclaw) on Azure Container Apps with Azure OpenAI (v1 API).

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Azure Resource Group                        │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │              Azure Container Apps Environment                │   │
│  │                                                              │   │
│  │  ┌────────────────────────────────────────────────────────┐  │   │
│  │  │           Container App (openclaw)                      │  │   │
│  │  │           System-Assigned Managed Identity              │  │   │
│  │  │                                                        │  │   │
│  │  │  ┌──────────────────┐    ┌──────────────────────────┐  │  │   │
│  │  │  │ token-refresh.mjs│    │   OpenClaw Gateway       │  │  │   │
│  │  │  │                  │───▶│   (openclaw gateway)     │  │  │   │
│  │  │  │ @azure/identity  │    │                          │  │  │   │
│  │  │  │ getBearerToken-  │    │   OpenAI Node.js SDK     │  │  │   │
│  │  │  │   Provider()     │    │   OPENAI_BASE_URL ──────────────┐  │
│  │  │  └──────────────────┘    │   OPENAI_API_KEY=token  │  │  ││  │
│  │  │           │              └──────────────────────────┘  │  ││  │
│  │  │           │ Entra ID token                             │  ││  │
│  │  └───────────┼────────────────────────────────────────────┘  ││  │
│  │              │         ┌────────────────────┐                ││  │
│  │              │         │   Azure Files      │                ││  │
│  │              │         │   /mnt/state       │                ││  │
│  │              │         │   • credentials    │                ││  │
│  │              │         │   • workspace      │                ││  │
│  │              │         │   • sessions       │                ││  │
│  │              │         └────────────────────┘                ││  │
│  └──────────────┼───────────────────────────────────────────────┘│  │
│                 │                                                │  │
│                 │ DefaultAzureCredential                         │  │
│                 │ (managed identity)                             │  │
│                 ▼                                                ▼  │
│  ┌──────────────────────────┐     ┌─────────────────────────────┐  │
│  │      Microsoft Entra ID  │     │     Azure OpenAI            │  │
│  │                          │     │     (disableLocalAuth: true) │  │
│  │  Token:                  │     │                             │  │
│  │  cognitiveservices       │     │     /openai/v1/             │  │
│  │    .azure.com/.default   │     │     GPT-5-mini deployment  │  │
│  └──────────────────────────┘     │                             │  │
│                                   │  Cognitive Services User    │  │
│                                   │  role ◀── Container App MI  │  │
│                                   └─────────────────────────────┘  │
│                                                                    │
│  ┌──────────────────────────┐     ┌─────────────────────────────┐  │
│  │  Azure Container Registry│     │     Log Analytics           │  │
│  │  (openclaw image)        │     │     (gateway logs)          │  │
│  └──────────────────────────┘     └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### Configuration & SDK flow

```
openclaw.json                      Environment Variables
┌─────────────────────┐            ┌──────────────────────────────────────────────┐
│ {                   │            │ OPENAI_BASE_URL=https://<res>.openai.azure   │
│   "agent": {        │            │   .com/openai/v1/                            │
│     "model":        │            │ OPENAI_API_KEY=<Entra ID bearer token>       │
│       "openai/      │            │ AZURE_OPENAI_AUTH=managed-identity           │
│        gpt-5-mini"  │            └──────────────┬───────────────────────────────┘
│   }                 │                           │
│ }                   │                           ▼
└────────┬────────────┘            ┌──────────────────────────────────────────────┐
         │                         │         OpenAI Node.js SDK (openai)          │
         │ model selection         │                                              │
         └────────────────────────▶│  new OpenAI({                               │
                                   │    baseURL: process.env.OPENAI_BASE_URL,    │
                                   │    apiKey:  process.env.OPENAI_API_KEY      │
                                   │  })                                         │
                                   └──────────────┬───────────────────────────────┘
                                                  │
                                                  │ HTTPS (bearer token in header)
                                                  ▼
                                   ┌──────────────────────────────────────────────┐
                                   │  Azure OpenAI  /openai/v1/                  │
                                   │  ┌──────────────────────────────────────┐    │
                                   │  │ gpt-5-mini (GlobalStandard)         │    │
                                   │  │ OpenAI-compatible chat/responses API│    │
                                   │  └──────────────────────────────────────┘    │
                                   └──────────────────────────────────────────────┘
```

### Auth flow (keyless)

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

## What's deployed

| Resource | Purpose |
|---|---|
| Virtual Network | Network isolation — all resources communicate via private endpoints |
| Azure OpenAI (GPT-5-mini) | LLM backend via `/openai/v1` (public access disabled, keyless auth only) |
| Azure Container Apps (internal) | Hosts the OpenClaw gateway — no public ingress |
| Azure Files | Persists OpenClaw state (credentials, workspace, sessions) across restarts |
| Azure Container Registry | Stores the custom OpenClaw container image |
| Private Endpoints + DNS Zones | Azure OpenAI and Storage reachable only inside the VNet |
| Log Analytics | Gateway and container logs |

## Quick start

```bash
az login && azd auth login
azd up
```

The OpenClaw gateway will be available at the FQDN printed in the output.

## How the Azure OpenAI integration works

OpenClaw natively uses the OpenAI Node.js SDK. The container app sets `OPENAI_BASE_URL` to point at the Azure OpenAI v1 endpoint:

- `OPENAI_BASE_URL` → `https://<resource>.openai.azure.com/openai/v1/`

Authentication is **fully keyless** via managed identity, using the same pattern as the [Azure OpenAI Starter Kit](https://github.com/Azure-Samples/azure-openai-starter/blob/main/src/typescript/responses_example_entra.ts):

```js
const credential = new DefaultAzureCredential();
const tokenProvider = getBearerTokenProvider(credential,
    "https://cognitiveservices.azure.com/.default");
const token = await tokenProvider();
```

The token-refresh wrapper (`src/token-refresh.mjs`) calls `getBearerTokenProvider` from `@azure/identity`, sets the returned bearer token as `OPENAI_API_KEY`, then spawns the OpenClaw gateway. The provider handles token caching and auto-refresh internally. A periodic refresh (every 45 min) pushes fresh tokens to the OpenClaw process.

No API keys are created, stored, or rotated — `disableLocalAuth` is set to `true` on the Azure OpenAI resource.

## Security — locked-down sandbox

Every resource in this template is network-isolated. Nothing is accessible from the public internet.

### Security boundaries

| Layer | Control | Effect |
|---|---|---|
| **Network** | VNet with private endpoints | All traffic stays inside the VNet — no public internet paths |
| **ACA Environment** | `internal: true` | Gateway has no public FQDN; only reachable from inside the VNet |
| **Azure OpenAI** | `publicNetworkAccess: Disabled` | Cannot be called from the internet; only via private endpoint |
| **Azure Storage** | `publicNetworkAccess: Disabled` | State files only accessible via private endpoint inside the VNet |
| **Authentication** | `disableLocalAuth: true` | No API keys exist or can be created; Entra ID tokens only |
| **RBAC** | `Cognitive Services User` | Scoped to the single Azure OpenAI resource; least-privilege |
| **Token auth** | `getBearerTokenProvider` | Short-lived JWT tokens (∼60 min); auto-refreshed every 45 min |
| **DNS** | Private DNS zones | `privatelink.openai.azure.com` and `privatelink.file.core.windows.net` resolve inside VNet only |

### How to access the gateway

Since the ACA environment is internal-only, you must connect to the VNet to reach the OpenClaw gateway:

- **VPN Gateway** — connect your machine to the VNet via point-to-site VPN
- **Azure Bastion** — jump box inside the VNet
- **`az containerapp exec`** — shell into the running container directly
- **Tailscale** — OpenClaw supports Tailscale Serve/Funnel natively (configure via `gateway.tailscale.mode` in `openclaw.json`)

## Testing

After deploying with `azd up`, validate via `az containerapp exec`:

```bash
# Get the container app name
APP_NAME=$(az containerapp list --resource-group <rg> --query "[0].name" -o tsv)

# Shell into the container
az containerapp exec --name $APP_NAME --resource-group <rg>

# Inside the container — test the agent
openclaw agent --message "Say hello in exactly 5 words."

# Verify managed identity auth is active
echo $AZURE_OPENAI_AUTH   # should print: managed-identity
echo $OPENAI_BASE_URL     # should print: https://<resource>.openai.azure.com/openai/v1/

# Check state persistence
ls -la /mnt/state/

# Check gateway health
curl -s http://localhost:18789/api/health
```

A full validation script is included at `validate.sh` for automated testing from inside the VNet.

### What to try

1. **Basic agent test** — `openclaw agent --message "Explain what OpenClaw is."` — confirms Azure OpenAI is responding via managed identity
2. **Session persistence** — send a message, restart the container (`az containerapp revision restart`), send another — the session history should survive via Azure Files
3. **Verify no API keys** — `az cognitiveservices account list-keys` should fail because `disableLocalAuth: true`
4. **Check logs** — `az containerapp logs show --name $APP_NAME --resource-group <rg> --follow` — look for `[auth] Obtained Entra ID token via getBearerTokenProvider`

### Sample end-to-end test

Run this from inside the container (`az containerapp exec`) to confirm the full pipeline — managed identity, Azure OpenAI v1, and the OpenClaw agent — works:

```bash
# 1. Verify the gateway is up
curl -sf http://localhost:18789/api/health && echo "✅ Gateway healthy" || echo "❌ Gateway down"

# 2. Ask the agent a question (hits Azure OpenAI via managed identity)
openclaw agent --message "What is 2+2? Reply with just the number."
# Expected: 4

# 3. Test a multi-turn conversation
openclaw agent --message "Remember the word 'lobster'."
openclaw agent --message "What word did I just ask you to remember?"
# Expected: lobster

# 4. Verify state survives restart — check Azure Files
ls /mnt/state/sessions/
# Should show session files after the above conversation

# 5. Verify auth mode
echo "Auth: $AZURE_OPENAI_AUTH"
echo "Endpoint: $OPENAI_BASE_URL"
# Expected: managed-identity, https://<resource>.openai.azure.com/openai/v1/
```

## Managing the OpenClaw agent

### Stop the agent

Scale the container app to zero replicas — the gateway stops, no compute charges, state is preserved on Azure Files:

```bash
# Set your resource group and app name
RG="<your-resource-group>"
APP_NAME=$(az containerapp list --resource-group $RG --query "[0].name" -o tsv)

# Stop (scale to 0)
az containerapp update --name $APP_NAME --resource-group $RG \
    --min-replicas 0 --max-replicas 0

echo "✅ OpenClaw stopped. No compute running."
```

### Start the agent

Scale back to 1 replica — the entrypoint restores state from Azure Files automatically:

```bash
# Start (scale to 1)
az containerapp update --name $APP_NAME --resource-group $RG \
    --min-replicas 1 --max-replicas 1

echo "✅ OpenClaw started. State restored from Azure Files."
```

### Restart the agent

Restart the active revision without changing scale — useful after config changes:

```bash
# Get the active revision
REVISION=$(az containerapp revision list --name $APP_NAME --resource-group $RG \
    --query "[?properties.active].name" -o tsv)

# Restart it
az containerapp revision restart --name $APP_NAME --resource-group $RG \
    --revision $REVISION

echo "✅ OpenClaw restarted."
```

### Check status

```bash
# Running state
az containerapp show --name $APP_NAME --resource-group $RG \
    --query "{status: properties.runningStatus, replicas: properties.template.scale}" -o table

# Live logs
az containerapp logs show --name $APP_NAME --resource-group $RG --follow

# Recent log snapshot
az containerapp logs show --name $APP_NAME --resource-group $RG --tail 50
```

### Redeploy after code changes

```bash
# Rebuild the container image and deploy the new revision
azd deploy
```

## Clean up

```bash
azd down
```