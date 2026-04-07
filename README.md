# OpenClaw on Azure

azd template that deploys [OpenClaw](https://github.com/openclaw/openclaw) on Azure Container Apps with Azure OpenAI (v1 API).

## What's deployed

| Resource | Purpose |
|---|---|
| Azure OpenAI (GPT-5-mini) | LLM backend via the OpenAI-compatible `/openai/v1` endpoint |
| Azure Container Apps | Hosts the OpenClaw gateway container |
| Azure Files | Persists OpenClaw state (credentials, workspace, sessions) across restarts |
| Azure Container Registry | Stores the custom OpenClaw container image |

## Quick start

```bash
az login && azd auth login
azd up
```

The OpenClaw gateway will be available at the FQDN printed in the output.

## How the Azure OpenAI integration works

OpenClaw natively uses the OpenAI SDK. The container app sets `OPENAI_BASE_URL` to point at the Azure OpenAI v1 endpoint:

- `OPENAI_BASE_URL` → `https://<resource>.openai.azure.com/openai/v1/`

Authentication is **fully keyless** via managed identity. The container app has a system-assigned managed identity with the `Cognitive Services User` role on the Azure OpenAI resource. A lightweight token-refresh wrapper (`src/token-refresh.mjs`) uses `@azure/identity`'s `DefaultAzureCredential` to obtain an Entra ID bearer token, sets it as `OPENAI_API_KEY` for the OpenAI SDK, and refreshes it automatically before expiry.

No API keys are created, stored, or rotated — `disableLocalAuth` is set to `true` on the Azure OpenAI resource.

## Security

- **No API keys** — managed identity with Entra ID tokens only; `disableLocalAuth: true` on Azure OpenAI
- **RBAC** — `Cognitive Services User` role scoped to the specific Azure OpenAI resource
- **Token refresh** — automatic refresh 5 minutes before expiry via `@azure/identity`

## Clean up

```bash
azd down
```