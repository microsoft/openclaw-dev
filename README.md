# 🦞 OpenClaw on Azure

> **Alpha** — Experimental reference for hosting [OpenClaw](https://github.com/openclaw/openclaw) on Azure. No production-readiness guarantees. Review all configurations before deploying with sensitive data.

Run [OpenClaw](https://github.com/openclaw/openclaw) — the open-source AI assistant — in an isolated Azure container. No laptop install. No API keys. Nuke-and-pave in one command.

## Why cloud instead of your laptop?

OpenClaw runs arbitrary code and can be deceived by prompt injection. **Don't run it on your work machine.** This template gives you an isolated, ephemeral container instead.

| | Your laptop ❌ | This template ✅ |
|---|---|---|
| **Isolation** | Shares your credentials | Ephemeral container — nothing to compromise |
| **Credentials** | API keys on disk | Managed identity — no keys anywhere |
| **Nuke & pave** | Reinstall OS | `msftclaw down && msftclaw up` (~6 min) |
| **Always on** | Only when open | Always on. `msftclaw stop` = $0 |
| **Teams/mobile** | Only when laptop is on | Always connected |
| **Cost** | Your hardware | ~$2-5/day running, $0 stopped |

## Quick start

### Prerequisites

- [Azure CLI](https://aka.ms/install-azure-cli) + [Azure Developer CLI](https://aka.ms/azd-install)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (running)
- An Azure subscription ([free](https://azure.microsoft.com/free))

### Deploy

```bash
git clone https://github.com/microsoft/openclaw
cd openclaw

# macOS/Linux/WSL
./msftclaw up

# Windows (cmd or PowerShell)
.\msftclaw.cmd up
```

First run takes ~6 minutes. Subsequent deploys take ~30 seconds.

### Verify

```bash
msftclaw test
```

### Open the WebChat UI

After deployment, open the URL from `msftclaw status` in your browser. The default gateway password is `openclaw-azure-test` (change it — see [Security](#changing-the-gateway-password)).

## CLI reference

```
msftclaw up         Deploy OpenClaw to Azure (provision + build + deploy)
msftclaw test       Verify the deployment is healthy
msftclaw status     Show container status, FQDN, auth mode
msftclaw logs       Stream live container logs
msftclaw start      Scale to 1 replica (resume after stop)
msftclaw stop       Scale to 0 replicas ($0, state preserved)
msftclaw restart    Restart the active revision
msftclaw deploy     Rebuild and deploy after code changes
msftclaw teams      Set up Microsoft Teams integration
msftclaw down       Delete ALL Azure resources (nuke & pave)
msftclaw login      Switch Azure account
```

## What can I do with this?

Your own **always-on AI assistant** — accessible from Teams on your phone, the WebChat UI, or any OpenClaw channel.

- **"Summarize my meeting notes"** — paste transcripts via Teams, get action items
- **"Draft a reply to this email"** — send the thread, get a polished response
- **"Explain this error log"** — paste a stack trace, get a diagnosis
- **"Review this PR"** — paste a GitHub PR link, get code review feedback
- **"Write my weekly status"** — the agent tracks your sessions

## Architecture

| Resource | Purpose |
|---|---|
| **Azure Container Apps** | Hosts OpenClaw gateway — public HTTPS, ephemeral container |
| **Azure OpenAI (GPT-5-mini)** | LLM backend via `/openai/v1/` — keyless (`disableLocalAuth: true`) |
| **Managed Identity** | Container → OpenAI auth via short-lived Entra ID tokens |
| **Azure Files** | Persists credentials, workspace, sessions across restarts |
| **Container Registry** | Stores the container image |
| **Log Analytics** | Container and gateway logs |

```mermaid
graph LR
    User["👤 User<br/>Teams / WebChat / Mobile"]
    subgraph ACA["Azure Container Apps"]
        GW["🦞 OpenClaw Gateway<br/>:18789 · password auth"]
    end
    AOAI["Azure OpenAI<br/>GPT-5-mini<br/>disableLocalAuth: true"]
    MI["Managed Identity<br/>Entra ID token"]
    AF["Azure Files<br/>credentials / workspace / sessions"]

    User -->|"HTTPS"| GW
    GW -->|"Bearer token"| AOAI
    GW -.->|"Volume mount"| AF
    MI -.->|"RBAC: Cognitive Services User"| AOAI
```

## Security

### What this template does

| Risk | Mitigation |
|---|---|
| Run on work laptop | ✅ Isolated ACA container — no host access |
| API keys stolen | ✅ No keys exist. `disableLocalAuth: true` + managed identity |
| Machine compromised | ✅ Ephemeral. `msftclaw down && msftclaw up` = clean slate |
| Credentials on disk | ✅ Managed identity injected by platform. No secrets in code |

### What to be aware of

- **Public FQDN** — gateway is password-protected but discoverable. Add Azure Front Door / WAF for hardening
- **Skills run arbitrary code** — a malicious skill can access the managed identity. Only install trusted skills
- **Prompt injection** — OpenClaw is susceptible. Nuke and repave if behavior changes
- **Container runs as root** — add a non-root user for hardened deployments

### Changing the gateway password

```bash
az containerapp update --name <app-name> --resource-group <rg> \
  --set-env-vars "OPENCLAW_GATEWAY_PASSWORD=your-strong-password"
```

### Usage guidelines

1. **Don't paste confidential data** — conversations flow through Azure OpenAI
2. **Don't install credential-heavy skills** — no email, bank, or internal API skills
3. **Nuke and pave regularly** — `msftclaw down && msftclaw up` if anything seems off
4. **Monitor logs** — `msftclaw logs`

## Teams Setup

Connect OpenClaw to Microsoft Teams so you can chat with it from your phone.

### Step 1: Create an Azure Bot

1. Go to [Azure Portal → Create Azure Bot](https://portal.azure.com/#create/Microsoft.AzureBot)
2. **Bot handle**: `openclaw-bot`, **Type**: Single Tenant, click **Create**
3. Copy the **Microsoft App ID** from Configuration
4. Create a **Client Secret** (Configuration → Manage Password → New)
5. Note your **Tenant ID** (Portal top-right → Directory ID)
6. **Channels** → Add **Microsoft Teams** → Save
7. Set **Messaging endpoint** to: `https://<your-fqdn>/api/messages` (get FQDN from `msftclaw status`)

### Step 2: Configure and deploy

```bash
msftclaw teams    # prompts for App ID, Secret, Tenant ID
msftclaw deploy   # redeploys with Teams config
```

### Step 3: Install in Teams

1. Teams → **Apps** → **Manage your apps** → **Upload a custom app**
2. Select `teams/openclaw-teams-app.zip`
3. **Add** → DM the bot to test

```
Summarize the latest commits on https://github.com/<your-user>/<your-repo>
```

OpenClaw will browse the repo and respond in Teams.

## Troubleshooting

### Container won't start

| Symptom | Cause | Fix |
|---|---|---|
| `Activating` for >2 min | Token acquisition retrying | Normal — allows up to 5 min. Check `msftclaw logs` |
| `ActivationFailed` | Container crashed | Check Azure Portal → Container App → Log stream |
| `Cannot find module '@buape/carbon'` | Cached broken Docker layer | `docker build --no-cache ./src` then `msftclaw deploy` |
| `Config invalid: Unrecognized key` | Old config format | Config must be `{"gateway":{"mode":"local"}}` |

### Auth issues

| Symptom | Cause | Fix |
|---|---|---|
| `401 invalid issuer` | RBAC not propagated | Wait 5 min. Verify: `az role assignment list --assignee <principal-id> --all` |
| Token retries failing | IMDS slow to initialize | Normal — retries for 60s |
| `disableLocalAuth` blocks `list-keys` | By design | Expected — managed identity only |

### Gateway issues

| Symptom | Cause | Fix |
|---|---|---|
| HTTP 500 on all routes | Missing plugin deps | Rebuild with `docker build --no-cache ./src` |
| Can't access WebChat UI | Wrong password | Default: `openclaw-azure-test`. Set via `OPENCLAW_GATEWAY_PASSWORD` env var |

### CLI issues

| Symptom | Cause | Fix |
|---|---|---|
| `az containerapp exec` crashes | Azure CLI Unicode bug (🦞) | Use Azure Portal Console instead |
| `az containerapp logs` hangs | SSL issue | Use Azure Portal Log stream |
| `azd up` warns about permissions | azd heuristic | Safe to proceed. Or add `User Access Administrator` role |

### Testing Azure OpenAI directly

```bash
TOKEN=$(az account get-access-token --resource "https://cognitiveservices.azure.com" --query accessToken -o tsv)
ENDPOINT=$(az cognitiveservices account list -g <rg> --query "[0].properties.endpoint" -o tsv)

curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-5-mini","messages":[{"role":"user","content":"Hello"}]}' \
  "$ENDPOINT/openai/v1/chat/completions"
```

## Clean up

```bash
msftclaw down    # Destroys ALL resources
```
