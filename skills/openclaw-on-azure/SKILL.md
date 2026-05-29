---
name: openclaw-on-azure
description: >-
  Deploy, operate, and troubleshoot a secure, hosted OpenClaw AI assistant on
  Azure (Azure Container Apps + Azure OpenAI in Foundry Models, passwordless via
  Managed Identity, Entra ID Easy Auth, optional Microsoft Teams channel) using
  the repo's `devclaw` wrapper around the Azure Developer CLI (azd). USE FOR:
  deploy OpenClaw to Azure, "devclaw up" / "azd up" failing, set the model or
  region, connect OpenClaw to Microsoft Teams / use it from a phone, stop to
  save cost, start/restart, stream logs, verify the deployment, configure Entra
  ID sign-in, restrict access to specific users, tear everything down (nuke &
  pave). DO NOT USE FOR: editing OpenClaw's own source on npm, general Azure
  resource creation unrelated to this template, non-Azure hosting.
license: MIT
---

# OpenClaw on Azure — setup & operations playbook

This skill lets an AI assistant set up, run, and fix the **openclaw-dev** template
in plain English. It deploys [OpenClaw](https://github.com/openclaw/openclaw) as a
secure, always-on AI assistant on **Azure Container Apps**, wired to **Azure OpenAI
in Foundry Models** over a **Managed Identity** (no API keys), gated by **Entra ID
Easy Auth**, and optionally reachable from **Microsoft Teams** on the user's phone.

Use this repo's own scripts, env-var contract, region list, and error catalog
**instead of guessing**. Always confirm with the user before any destructive
action (`devclaw down`, `azd down`, deleting app registrations, RBAC removal).

> Alpha / dev-test template, single-tenant. Today it targets **Azure OpenAI in
> Foundry Models** (default `gpt-5-mini`), with scope to add Claude and other
> Foundry Models later. Do not promise non-OpenAI models work today.

---

## The one thing to know

Everything is driven by the **`devclaw`** wrapper (a thin shell around `azd`):

```bash
./devclaw up        # macOS/Linux/WSL  — provision + build + deploy (~6 min first run)
.\devclaw.cmd up    # Windows (cmd or PowerShell)
```

On first `up`, `azd` prompts for a **subscription, region, and environment name**;
it creates resource group `rg-<env-name>` automatically. There is no separate
`.env` to edit — configuration is done with `azd env set <KEY> <VALUE>` before `up`.

If `devclaw`/`devclaw.cmd` is not executable, call `azd` directly (`azd up`, `azd down`,
`azd deploy`) — `devclaw` only adds friendly status/logs/start/stop/teams helpers.

---

## Command map (`devclaw <cmd>`)

| Command | What it does | Underlying call |
|---|---|---|
| `up` | Provision + remote build + deploy | `azd up` |
| `deploy` | Rebuild & redeploy after code changes (~3–4 min) | `azd deploy` |
| `status` | Container state, FQDN, URL, resource group | `az containerapp ...` |
| `logs` | Stream live container logs | `az containerapp logs show --follow` |
| `test` | Print container/auth/identity summary + console hint (NOT an e2e model test) | `az containerapp show` |
| `start` | Scale to 1 replica (resume after stop) | `az containerapp update --min/max-replicas 1` |
| `stop` | Scale to 0 replicas — **$0**, state preserved on Azure Files | `az containerapp update --min/max-replicas 0` |
| `restart` | Restart the active revision | `az containerapp revision restart` |
| `teams` | Enable Teams channel + build sideload zip | `az bot msteams ...` + zip |
| `login` | Switch Azure account | `az login` + `azd auth login` |
| `down` | **DESTRUCTIVE** — delete all resources + Entra app regs | `azd down --purge` + `az ad app delete` |

The fastest real smoke test is the **WebChat UI** (open the URL from `devclaw status`),
not `devclaw test`.

---

## Prerequisites (check before deploying)

- **Azure CLI** (`az`) and **Azure Developer CLI** (`azd`) installed and logged in
  (`az login`, `azd auth login`). `devclaw` checks for both and exits if missing.
- An Azure subscription and a tenant where the user can create **Entra ID app
  registrations** (the preprovision hook creates two: a Bot app and an Easy Auth app).
- Either local **Docker Desktop** running **or** the default `remoteBuild: true` in
  `azure.yaml` (ACR builds the image — no local Docker needed).
- **PowerShell 7+** (`pwsh`) on Windows only if running `devclaw teams`.

---

## Configuration contract (`azd env set` before `devclaw up`)

| Env var | Required | Default | Notes |
|---|---|---|---|
| `AZURE_ENV_NAME` | prompted | — | Names the env and `rg-<env-name>` |
| `AZURE_LOCATION` | prompted | — | Must be in the allowed region list (below) |
| `AZURE_SUBSCRIPTION_ID` | no | prompted | Set to skip the interactive picker |
| `AZURE_OPENAI_LOCATION` | no | = `AZURE_LOCATION` | Override when the chosen region lacks the model SKU (e.g. ACA in `eastasia`, OpenAI in `eastus2`) |
| `USE_EXPRESS_ENV` | no | `false` | ACA Express mode (preview); only in supported regions (East Asia, West Central US) |
| `BOT_APP_ID` / `BOT_APP_SECRET` / `BOT_TENANT_ID` | auto | — | Created by the preprovision hook; do not set by hand |
| `EASYAUTH_APP_ID` | auto | — | Created by the preprovision hook |
| `SERVICE_OPENCLAW_IMAGE_NAME` | auto | — | Populated by azd after first deploy |

**Allowed `AZURE_LOCATION` values:** `australiaeast`, `eastasia`, `eastus`, `eastus2`,
`japaneast`, `koreacentral`, `southindia`, `swedencentral`, `switzerlandnorth`,
`uksouth`, `westcentralus`.

**Model:** `gpt-5-mini` (version `2025-08-07`, capacity 10 TPM-thousands) is set in
`infra/main.bicep`. To change the model/version/capacity, edit the `openai` module
params there (`aiModelName`, `aiModelVersion`, `aiModelCapacity`) — they are not env
vars. Keep it to an **Azure OpenAI** model available in `AZURE_OPENAI_LOCATION`.

Example region split when the model isn't in your ACA region:

```bash
azd env set AZURE_LOCATION eastasia
azd env set AZURE_OPENAI_LOCATION eastus2
./devclaw up
```

---

## Common tasks

### Deploy from scratch
1. Confirm `az`/`azd` installed and logged in (`devclaw login` if not).
2. Optional: `azd env set AZURE_SUBSCRIPTION_ID <id>` / `AZURE_LOCATION <region>` /
   `AZURE_OPENAI_LOCATION <region>`.
3. `./devclaw up` (or `.\devclaw.cmd up`). First run ~6 min.
4. Verify: `devclaw status` (expect `Running`), then open the URL in a browser —
   Entra ID prompts for Microsoft sign-in, then the WebChat UI loads.

### Save cost when idle
`devclaw stop` scales to 0 replicas ($0, state preserved on Azure Files);
`devclaw start` resumes. Don't use `down` for this — `down` deletes everything.

### Connect to Microsoft Teams (phone access)
1. `devclaw teams` — enables the Teams channel on the Azure Bot and builds
   `teams/openclaw-teams-app.zip` (regenerated; gitignored).
2. In Teams: **Apps → Manage your apps → Upload a custom app →** select the zip → **Add** → DM the bot.
- Requires `pwsh` on Windows. The msteams plugin must be active in `src/openclaw.json`
  (`plugins.allow: ["msteams"]` + `plugins.entries.msteams.enabled: true`) — already shipped.

### Restrict access to specific users/groups
Easy Auth is configured automatically by `devclaw up`. To lock it down:
Azure Portal → Entra ID → App registrations → `openclaw-auth-<env>` → Enterprise
applications → set **Assignment required? = Yes** and assign users/groups.

### Tear everything down (DESTRUCTIVE — confirm first)
`devclaw down` deletes the resource group, ACA, OpenAI, storage, **and** the two
Entra app registrations. Always confirm with the user before running it.

---

## Error catalog (match symptom → fix)

| Symptom | Cause | Fix |
|---|---|---|
| Container `Activating` >2 min | Token acquisition retrying | Normal up to ~5 min; `devclaw logs` |
| `ActivationFailed` | Container crashed | Portal → Container App → Log stream |
| `Cannot find module '@buape/carbon'` / HTTP 500 on all routes | Cached/broken Docker layer or missing plugin deps | `docker build --no-cache ./src` then `devclaw deploy` |
| `Config invalid: Unrecognized key` | Old config format | Config must be `{"gateway":{"mode":"local"}}` shape |
| `Circular dependency detected on resource ... containerApps` during `azd provision` | Old `aca.bicep` self-reference | Pull latest (uses a `containerImage` parameter) |
| `401 invalid issuer` | RBAC not propagated | Wait ~5 min; `az role assignment list --assignee <principal-id> --all` |
| `disableLocalAuth` blocks `list-keys` | By design | Expected — Managed Identity only, no keys |
| `pairing required` | Missing `dangerouslyDisableDeviceAuth`/`trustedProxies` | Ensure both are in `src/openclaw.json` |
| `Proxy headers detected from untrusted address` | Reverse proxy not trusted | Add proxy CIDRs to `gateway.trustedProxies` |
| WebChat shows login screen / token not injected | `entrypoint.sh` didn't finish | Check `devclaw logs` |
| `POST /api/messages` → **502** | msteams plugin didn't load (nothing on `:3978`) | Confirm the `plugins` block in `src/openclaw.json`, `devclaw deploy`, look for `… msteams …` in `[gateway] http server listening` log |
| `POST /api/messages` → **401** to a curl test | Bot Framework JWT auth rejecting unsigned request | None — real Teams traffic carries a valid token |
| Bot replies in WebChat but not Teams | Teams channel off or wrong `botId` in sideload | Re-run `devclaw teams` |
| `az containerapp exec`/`logs` crashes or hangs (🦞 Unicode / SSL) | Azure CLI bug | Use Azure Portal Console / Log stream |
| `azd up` warns about permissions | azd heuristic | Safe to proceed, or grant `User Access Administrator` |

### Test the model endpoint directly (keyless)
```bash
TOKEN=$(az account get-access-token --resource "https://cognitiveservices.azure.com" --query accessToken -o tsv)
ENDPOINT=$(az cognitiveservices account list -g <rg> --query "[0].properties.endpoint" -o tsv)
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-5-mini","messages":[{"role":"user","content":"Hello"}]}' \
  "$ENDPOINT/openai/v1/chat/completions"
```

---

## Architecture (for accurate answers)

- **Azure Container Apps** hosts the OpenClaw gateway; public HTTPS on `:18789`.
  Inside the container, `src/entrypoint.sh` starts three Node processes:
  `gateway-proxy` (`:18789`, splits ingress by path), the **OpenClaw gateway**
  (`:18788`), and the **auth-proxy** (`:18790`, injects a fresh MI bearer token).
- **Azure OpenAI in Foundry Models** is called via the OpenAI-compatible
  **Responses API** (`/openai/v1/responses`, adapter `azure-openai-responses` in
  `src/openclaw.json`) — no `openai` npm SDK. `disableLocalAuth: true` (no keys).
- **Managed Identity** has the **Cognitive Services User** role on the model account.
- **Entra ID Easy Auth** forces Microsoft sign-in before the container; `/api/messages`
  is excluded so Bot Framework can call in with its own JWT.
- **Azure Bot Service** fronts the Teams channel; **Azure Files** persists state;
  **Container Registry** stores the image; **Log Analytics** holds logs.

## Security model (defense in depth — 4 layers)
1. **Entra ID Easy Auth** (Microsoft login, tenant-scoped) before the container.
2. **Gateway token** — random per-container token required for the WebSocket API.
3. **Managed Identity** — short-lived Entra tokens, `disableLocalAuth: true`, no keys.
4. **Ephemeral container** — disposable; `devclaw down && devclaw up` = clean slate.

Warn the user that: OpenClaw runs **arbitrary code** and is susceptible to **prompt
injection** (don't run it on a work laptop — that's the whole point of this template);
only install **trusted skills**; **don't paste highly sensitive data** (it flows
through the model endpoint); the container runs as **root** (harden for production).

---

## Destructive-action policy (always follow)

Before running any of these, **state what will be deleted and ask the user to confirm**:
- `devclaw down` / `azd down --purge` (deletes the whole resource group)
- `az ad app delete` (removes the Bot / Easy Auth app registrations)
- removing role assignments, or `rm -rf .azure*` / state files

Never use `--no-prompt`/`--force` to skip a confirmation the user hasn't given.
