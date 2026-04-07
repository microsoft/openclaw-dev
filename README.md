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
| Azure OpenAI (GPT-5-mini) | LLM backend via the OpenAI-compatible `/openai/v1` endpoint |
| Azure Container Apps | Hosts the OpenClaw gateway container with system-assigned managed identity |
| Azure Files | Persists OpenClaw state (credentials, workspace, sessions) across restarts |
| Azure Container Registry | Stores the custom OpenClaw container image |
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

## Security

- **No API keys** — managed identity with Entra ID tokens only; `disableLocalAuth: true` on Azure OpenAI
- **RBAC** — `Cognitive Services User` role scoped to the specific Azure OpenAI resource
- **Token refresh** — automatic via `getBearerTokenProvider` from `@azure/identity` (caches + refreshes internally)

## Clean up

```bash
azd down
```