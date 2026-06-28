---
name: openclaw-dev
description: >-
  Deploy, operate, and troubleshoot the openclaw-dev template: a secure, hosted
  OpenClaw AI assistant on Azure (Azure Container Apps + Azure OpenAI in Foundry
  Models, passwordless via Managed Identity, Entra ID Easy Auth, ephemeral
  sandbox execution, optional Microsoft Teams channel) using the repo's
  `devclaw` wrapper around the Azure Developer CLI (azd). USE FOR: deploy
  openclaw-dev / OpenClaw to Azure in one prompt, "devclaw up" / "azd up"
  failing, set the model or region, switch tool execution to ephemeral sandboxes
  (EXECUTION_MODE=sandbox / devclaw exec-mode), clone another sandbox, connect
  OpenClaw to Microsoft Teams / use it from a phone, stop to save cost,
  start/restart, stream logs, verify the deployment, configure Entra ID sign-in,
  restrict access to specific users, tear everything down (nuke & pave). DO NOT
  USE FOR: editing OpenClaw's own source on npm, general Azure resource creation
  unrelated to this template, non-Azure hosting.
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
> Foundry Models** (default `gpt-5.4-mini`), with scope to add Claude and other
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

## Deploy in one prompt (zero-effort path)

This skill is built so the user can drive the whole lifecycle in plain English —
no hand-typed `azd`/`az`. When the user asks, do the work for them end to end and
report the result:

- *"Deploy openclaw-dev to eastus2."* → confirm prereqs, `azd env set AZURE_LOCATION eastus2`, `./devclaw up`, then open/print the URL from `devclaw status`.
- *"Run tool execution in ephemeral sandboxes."* → `devclaw exec-mode sandbox` then `./devclaw up`.
- *"Connect it to Teams so I can use it from my phone."* → `devclaw teams`, then walk the one-time sideload step.
- *"Stop it to save money."* → `devclaw stop`. *"Bring it back."* → `devclaw start`.
- *"Why is `devclaw up` failing?"* → read the error, match the catalog below, apply the fix.
- *"Tear it all down."* → state exactly what will be deleted, get confirmation, then `devclaw down`.

Minimal happy path (browser-only, default in-process execution):

```bash
azd env set AZURE_LOCATION eastus2     # an allowed region (list below)
./devclaw up                            # provision + build + deploy (~6 min)
./devclaw status                        # open the printed URL, sign in
```

Everything else — Teams, sandbox execution, cost controls — is an opt-in layer on
top of that same `devclaw up`.

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
| `teams` | **Opt-in.** Enables Teams (re-provisions + redeploys on first run) and builds the sideload zip | `azd provision` + `azd deploy` + enable Teams channel + zip |
| `exec-mode <inproc\|sandbox>` | Choose where tools run: in the Gateway container (`inproc`, default) or in ephemeral ACA Sandboxes (`sandbox`). Apply with `devclaw up` | `azd env set EXECUTION_MODE …` |
| `clone` | (ACA Sandboxes host only) Boot another OpenClaw from the existing disk image — independent URL + token | `aca sandbox …` |
| `login` | Switch Azure account | `az login` + `azd auth login` |
| `down` | **DESTRUCTIVE** — delete all resources + Entra app regs | `azd down --purge` + `az ad app delete` |

The fastest real smoke test is the **WebChat UI** (open the URL from `devclaw status`),
not `devclaw test`.

---

## Prerequisites (check before deploying)

- **Azure CLI** (`az`) and **Azure Developer CLI** (`azd`) installed and logged in
  (`az login`, `azd auth login`). `devclaw` checks for both and exits if missing.
- An Azure subscription and a tenant where the user can create **one Entra ID app
  registration** for the Easy Auth login gate. The optional Teams add-on creates a
  second app registration (the Bot) plus a client secret — some tenants restrict
  this (see error catalog).
- Either local **Docker Desktop** running **or** the default `remoteBuild: true` in
  `azure.yaml` (ACR builds the image — no local Docker needed).
- **PowerShell 7+** (`pwsh`) on Windows only if running `devclaw teams` (optional Teams add-on).

---

## Configuration contract (`azd env set` before `devclaw up`)

| Env var | Required | Default | Notes |
|---|---|---|---|
| `AZURE_ENV_NAME` | prompted | — | Names the env and `rg-<env-name>` |
| `AZURE_LOCATION` | prompted | — | Must be in the allowed region list (below) |
| `AZURE_SUBSCRIPTION_ID` | no | prompted | Set to skip the interactive picker |
| `AZURE_OPENAI_LOCATION` | no | = `AZURE_LOCATION` | Override when the chosen region lacks the model SKU (e.g. ACA in `eastasia`, OpenAI in `eastus2`) |
| `USE_EXPRESS_ENV` | no | `false` | ACA Express mode (preview); only in supported regions (East Asia, West Central US) |
| `USE_SANDBOX` | no | `false` | Use the **ACA Sandboxes** host (preview / Early Access) instead of Azure Container Apps. Mutually exclusive with the Container Apps host and the Teams add-on. Bicep provisions a `Microsoft.App/SandboxGroups` resource + user-assigned managed identity (keyless Azure OpenAI); the postprovision hook (`infra/hooks/sandbox.*`) installs the `aca` CLI, builds the OpenClaw image into ACR, imports it as a disk image, boots a sandbox, and exposes the gateway port. `devclaw up` runs `azd provision` only (sandboxes aren't an azd-native host). Requires the Early Access feature enabled on the subscription; if SandboxGroups fails with an api-version error, update the literal in `infra/sandbox.bicep`. |
| `SANDBOX_PUBLIC` | no | `false` | Only with `USE_SANDBOX=true`. `false` = the sandbox port is **Entra-gated** to the deployer via the ADC data plane: an allow-list of the deployer's object id (the reliable `oid` claim) + email. `true` = anonymous public URL (anyone with the link). |
| `SANDBOX_ALLOW_DOMAIN` | no | `false` | Only with `USE_SANDBOX=true` and `SANDBOX_PUBLIC=false`. When `true`, also allow-lists the deployer's email **domain** (e.g. `@contoso.com`) so any corporate login in that domain can reach the sandbox — not just the deployer. The `aca` CLI's `--email` flag alone is unreliable for guest/B2B identities (their token presents a `#EXT#` UPN, not the `mail` claim), so the hook posts `objectIds`/`emails`/`emailSuffixes` directly to the data plane. |
| `EXECUTION_MODE` | no | `inproc` | **Orchestrator + sandbox execution.** `inproc` = today's single-container behavior (tools run in the Gateway). `sandbox` = the Gateway **stays on ACA** but offloads untrusted tool execution (shell/codegen/file/browser) to **ephemeral ACA Sandboxes**, one per task/session, via the sandbox **MCP server** (`src/sandbox_mcp/`). Bicep provisions an execution sandbox group + worker MI + role assignments (incl. SandboxGroup Data Owner for the Gateway MI); the post-provision hook (`infra/hooks/execution.*`) builds the exec image (`src/execution-env/`), a hash-gated disk image, and a warm snapshot, then injects the ids into the Gateway. Distinct from `USE_SANDBOX` (which replaces the whole host). Set via `devclaw exec-mode sandbox`. |
| `SKIP_STORAGE` | no | `false` | Set to `true` if Azure Policy blocks `allowSharedKeyAccess: true` on storage accounts (ACA file mounts require shared keys today). Skips the storage account, file share, and volume mount. Trade-off: gateway token + sessions don't persist across replica restarts. |
| `SERVICE_MANAGEMENT_REFERENCE` | no | unset | Set to a service-management-reference GUID if your tenant requires `serviceManagementReference` on every new app registration (common on large corporate tenants). The preprovision hook passes it to `az ad app create` for both the Easy Auth and the Bot app registrations. |
| `ENABLE_TEAMS` | no | unset (Teams disabled) | Set to `true` *before* `devclaw up` (or before `devclaw teams`) to opt into the Microsoft Teams add-on. When unset, the preprovision hook skips bot app creation, Bicep skips the Azure Bot + Teams channel + MSTEAMS_* env vars, and the runtime disables the msteams plugin. |
| `BOT_APP_ID` / `BOT_APP_SECRET` / `BOT_TENANT_ID` | auto (when `ENABLE_TEAMS=true`) | — | Created by the preprovision hook when the Teams add-on is enabled; do not set by hand unless your tenant blocks `az ad app credential reset` and you're providing a pre-created bot app reg |
| `EASYAUTH_APP_ID` | auto | — | Created by the preprovision hook |
| `SERVICE_OPENCLAW_IMAGE_NAME` | auto | — | Populated by azd after first deploy |
| `AOAI_DEFAULT_API_VERSION` | no | unset | Escape hatch in `src/auth-proxy.mjs`. Only set when targeting a **non-v1** AOAI surface (e.g. `2024-10-21`). When set, the proxy appends `?api-version=<value>` to `/openai/...` requests that don't already have one. Leave unset for the shipped v1 (`/openai/v1/...`) path. |

**Allowed `AZURE_LOCATION` values:** `australiaeast`, `eastasia`, `eastus`, `eastus2`,
`japaneast`, `koreacentral`, `southindia`, `swedencentral`, `switzerlandnorth`,
`uksouth`, `westcentralus`.

**Model:** `gpt-5.4-mini` (version `2026-03-17`, capacity 50 TPM-thousands) is set in
`infra/main.bicep`. To change the model/version/capacity, edit the `openai` module
params there (`aiModelName`, `aiModelVersion`, `aiModelCapacity`) — they are not env
vars. Keep it to an **Azure OpenAI** model available in `AZURE_OPENAI_LOCATION`, and
keep `src/openclaw.json`'s model id in sync with `aiModelName`.

Example region split when the model isn't in your ACA region:

```bash
azd env set AZURE_LOCATION eastasia
azd env set AZURE_OPENAI_LOCATION eastus2
./devclaw up
```

---

## Execution & host modes (pick one)

| Mode | How | What it means |
|---|---|---|
| **In-process** (default) | nothing to set, or `devclaw exec-mode inproc` | The Gateway runs tools itself, inside its own ACA container. Simplest. |
| **Sandbox execution** (recommended for untrusted work) | `devclaw exec-mode sandbox` then `devclaw up` | The Gateway **stays on ACA** but offloads each untrusted tool run (shell / codegen / browser) to an **ephemeral ACA Sandbox** via the sandbox MCP server, then throws it away. Teams-compatible. This is the "one brain, many disposable sandboxes" model in the architecture diagram. |
| **Sandbox host** (experimental) | `azd env set USE_SANDBOX true` then `devclaw up` | The **entire** Gateway runs inside an ACA Sandbox instead of a Container App. Provision-only; **no Teams**. Most users should prefer sandbox *execution* over this. |

`EXECUTION_MODE=sandbox` and `USE_SANDBOX=true` are mutually exclusive. Both
require the ACA Sandboxes Early Access feature enabled on the subscription.

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

### Connect to Microsoft Teams (optional add-on — phone access)
Teams is **off by default**. Enable it with:
```bash
azd env set ENABLE_TEAMS true
devclaw teams      # first run: re-provisions + redeploys, then enables channel + builds zip
```
If the user runs `devclaw teams` without setting `ENABLE_TEAMS`, the wrapper
will prompt to enable it and re-provision in one step.

1. `devclaw teams` — (re-)provisions the bot app reg + Azure Bot when needed,
   enables the Teams channel, and builds `teams/openclaw-teams-app.zip`
   (regenerated; gitignored). The zip is baked from `teams/manifest.json`
   (committed source); `teams/package/manifest.json` is the generated copy and
   is gitignored — only edit the source.
2. In Teams: **Apps → Manage your apps → Upload a custom app →** select the zip → **Add** → DM the bot.
- Requires `pwsh` on Windows. The msteams plugin must be active in `src/openclaw.json`
  (`plugins.allow: ["msteams"]` + `plugins.entries.msteams.enabled: true`) — already shipped.
  When Teams is disabled the entrypoint disables the plugin at boot so the
  gateway doesn't try to authenticate with empty Bot Framework credentials.
- **Legal URLs in the manifest** show up in Teams' *About* dialog ("Created by …",
  *Privacy policy*, *Terms of use*). The shipped `teams/manifest.json` points
  `privacyUrl` and `termsOfUseUrl` at Microsoft's generic statements
  (`microsoft.com/en-us/privacy/privacystatement`,
  `microsoft.com/en-us/legal/terms-of-use`) and `websiteUrl` at the README's
  `#alpha` anchor so users see the alpha caveat. Anyone forking under a different
  org **must** repoint these to their own policy URLs before sideloading.

### Restrict access to specific users/groups
Easy Auth is configured automatically by `devclaw up`. To lock it down:
Azure Portal → Entra ID → App registrations → `openclaw-auth-<env>` → Enterprise
applications → set **Assignment required? = Yes** and assign users/groups.

### Tear everything down (DESTRUCTIVE — confirm first)
`devclaw down` deletes the resource group, ACA, OpenAI, storage, **and** the
Entra app registrations that were created (Easy Auth always; Bot only when the
Teams add-on is enabled). Always confirm with the user before running it.

---

## Error catalog (match symptom → fix)

| Symptom | Cause | Fix |
|---|---|---|
| `Please run 'az login' to setup account.` inside the `[preprovision]` hook even though `az account show` works in your normal shell | azd points `AZURE_CONFIG_DIR` at the repo-local `.azure/` folder; that folder has no signed-in account. | Already shipped: the preprovision hook detects this and unsets `AZURE_CONFIG_DIR` so `az` falls back to the user's default (`~/.azure` / `%USERPROFILE%\.azure`). If you still see it, run `az login` in the same shell you'll run `devclaw up` from. |
| `[preprovision] ERROR: Failed to create ... app registration` and `ServiceManagementReference field is required for Create` | Restricted tenant requires `serviceManagementReference` (a service-management-reference GUID) on every new app registration. | `azd env set SERVICE_MANAGEMENT_REFERENCE <guid>` and re-run `devclaw up`. The hook forwards it to both `az ad app create` calls (Easy Auth + Bot). Get the GUID from your tenant admin. |
| `Resource 'acr...' was disallowed by policy ... Container registries should have local admin account disabled.` | Subscription policy requires `adminUserEnabled: false` on ACR. | Already shipped: ACR is created with admin disabled and the container app pulls images via its system-assigned managed identity (AcrPull role assigned by Bicep). No env var needed. |
| `Local authentication methods are not allowed` on the storage account, or `allowSharedKeyAccess: true` is disallowed by policy | Subscription policy blocks shared-key access on storage; ACA file mounts require shared keys today. | `azd env set SKIP_STORAGE true` then re-run `devclaw up`. The storage account, file share, and volume mount are skipped; the entrypoint falls back to an in-container ephemeral state dir. Gateway token + sessions won't survive a replica restart. |
| `Failed to provision revision for container app — Operation expired` (~20 min timeout) on first provision | The placeholder image (`mcr.microsoft.com/k8se/quickstart:latest`) listens on `:80`, but probes/ingress were targeting `:18789`. | Already shipped: on first provision (`containerImage` empty) Bicep targets ingress at `:80` and skips probes; the `postdeploy` hook flips ingress back to `:18789` after the first real `azd deploy` lands. |
| `eastus` provisioning hangs/times out for ACA even with the probe fix | Transient/regional ACA platform issue in `eastus`. | Try a different region from the allowed list — `westus2`, `eastus2`, and `westcentralus` have been the most reliable lately. Switch with `azd env set AZURE_LOCATION <region>` and re-run `devclaw up`. |
| `[preprovision] ERROR: Failed to create bot client secret` with `Credential type not allowed as per assigned policy` from `az ad app credential reset` | Restricted tenant policy blocks programmatic client-secret creation. Common on large corporate tenants. | Leave Teams off (don't set `ENABLE_TEAMS=true`) — the browser experience deploys fine. To use Teams anyway, ask the tenant admin to create the bot app registration + secret, then `azd env set BOT_APP_ID <id>`, `azd env set BOT_APP_SECRET <secret>`, `azd env set BOT_TENANT_ID <tenant>`, `azd env set ENABLE_TEAMS true`, then `devclaw teams`. |
| `[preprovision] ERROR: Failed to create bot app registration` with `serviceManagementReference` required | Restricted tenant requires `serviceManagementReference` on new app registrations. | Set `SERVICE_MANAGEMENT_REFERENCE` (see row above) so the hook can create the bot app reg too — or, if your tenant also blocks the secret reset, keep Teams off / supply a pre-created bot via `BOT_APP_ID`/`BOT_APP_SECRET`/`BOT_TENANT_ID`. |
| `devclaw teams` says "Teams is an optional add-on and isn't enabled" | Default since Teams was made opt-in. | Either accept the prompt to enable now (the wrapper sets `ENABLE_TEAMS=true` and re-provisions), or set it ahead of time: `azd env set ENABLE_TEAMS true && devclaw teams`. |
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
| Teams DM is acknowledged (200) but bot never replies | `channels.msteams.dmPolicy` defaults to `"pairing"` — unknown senders are silently ignored until approved via CLI | Already shipped: `src/openclaw.json` sets `dmPolicy: "open"` + `allowFrom: ["*"]`. Single-tenant AAD + Easy Auth keeps reach scoped to the deployer's tenant. |
| Direct Line / Web Chat / Teams test channel: user message acked (200) but bot reply never arrives. Container logs show `Blocked Microsoft Teams serviceUrl host: directline.botframework.com` | The bundled `@openclaw/msteams` plugin's SSRF guard only allows `smba.trafficmanager.net` + `smba.infra.{gcc,gov,dod}.*` (real Teams channel hosts). Direct Line uses `directline.botframework.com`, so every reply is silently dropped inside the streaming pipeline. | Already shipped: `src/patch-msteams-allowlist.mjs` runs at image build (see `src/Dockerfile`) and extends the plugin's allowlist to include `directline.botframework.com` + `europe.directline.botframework.com`. Idempotent. Remove once upstream plugin exposes a public hook. |
| Bot reply attempt fails with `AADSTS7000229: The client application <bot-app-id> is missing service principal in the tenant <tenant-id>` | The Bot App Registration was created without an enterprise application (service principal) in the consuming tenant — the Bot Framework token endpoint can't issue tokens to an appId with no SP. Happens when an app reg is provisioned via Graph without `az ad sp create`, or when the bot is consumed cross-tenant. | One-time fix: `az ad sp create --id $(azd env get-value BOT_APP_ID)`. If `az` is rate-limited, call Graph directly: `curl -s -X POST https://graph.microsoft.com/v1.0/servicePrincipals -H "Authorization: Bearer $(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)" -H "Content-Type: application/json" -d "{\"appId\":\"$(azd env get-value BOT_APP_ID)\"}"`. No redeploy needed — propagates in <30s. |
| Bot replies in WebChat but not Teams | Teams channel off or wrong `botId` in sideload | Re-run `devclaw teams` |
| `devclaw teams` prints "No Azure Bot found" but the bot exists | The wrapper's `az resource list` ran against a config dir with no `az` login (AZURE_CONFIG_DIR pinned to a dir without a session). | Already shipped: the wrapper now respects an env-scoped `AZURE_CONFIG_DIR` and, when `BOT_APP_ID` is set, builds the sideload zip anyway (skipping the idempotent channel enable). If you still hit it, confirm `az account show` works in the same shell, then re-run `devclaw teams`. |
| `az containerapp exec`/`logs` crashes or hangs (🦞 Unicode / SSL) | Azure CLI bug | Use Azure Portal Console / Log stream |
| `azd up` warns about permissions | azd heuristic | Safe to proceed, or grant `User Access Administrator` |

### Test the model endpoint directly (keyless)
```bash
TOKEN=$(az account get-access-token --resource "https://cognitiveservices.azure.com" --query accessToken -o tsv)
ENDPOINT=$(az cognitiveservices account list -g <rg> --query "[0].properties.endpoint" -o tsv)
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Hello"}]}' \
  "$ENDPOINT/openai/v1/chat/completions"
```

---

## Architecture (for accurate answers)

- **Azure Container Apps** hosts the OpenClaw gateway; public HTTPS on `:18789`.
  Inside the container, `src/entrypoint.sh` starts three Node processes:
  `gateway-proxy` (`:18789`, splits ingress by path), the **OpenClaw gateway**
  (`:18788`), and the **auth-proxy** (`:18790`, injects a fresh MI bearer token).
- **Azure OpenAI in Foundry Models** is called via the OpenAI-compatible
  REST API under `/openai/v1/...` — `src/openclaw.json` sets the adapter to
  `"api": "openai-completions"` and `src/auth-proxy.mjs` injects the MI bearer.
  No `openai` npm SDK. `disableLocalAuth: true` (no keys). To target a non-v1
  AOAI surface, set `AOAI_DEFAULT_API_VERSION` (see env-var table).
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
