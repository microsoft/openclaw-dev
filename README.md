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

OpenClaw natively uses the OpenAI SDK. The container app sets two environment variables that redirect it to Azure OpenAI's v1 endpoint:

- `OPENAI_BASE_URL` → `https://<resource>.openai.azure.com/openai/v1/`
- `OPENAI_API_KEY` → API key from the provisioned Azure OpenAI resource

The pre-configured `src/openclaw.json` sets the model to `openai/gpt-5-mini`, matching the deployed Azure OpenAI model.

## Future: managed identity

The template is structured for a future switch to managed identity (keyless auth). The `TODO` comments in `infra/aca.bicep` show the exact changes: enable system-assigned identity on the container app, assign the Cognitive Services User role, and remove the API key secret.

## Clean up

```bash
azd down
```