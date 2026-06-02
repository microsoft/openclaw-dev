# Copilot instructions — openclaw-dev

This repo deploys **OpenClaw** as a secure, hosted AI assistant on **Azure
Container Apps**, wired to **Azure OpenAI in Foundry Models** over a **Managed
Identity** (no API keys), gated by **Entra ID Easy Auth**, with an optional
**Microsoft Teams** channel. It is an alpha, single-tenant dev/test template.

When the user asks you to deploy, configure, operate, troubleshoot, connect to
Teams, or tear down this template, **follow the playbook in
[`skills/openclaw-on-azure/SKILL.md`](../skills/openclaw-on-azure/SKILL.md)**.
Use this repo's own scripts, env-var contract, region list, and error catalog
instead of guessing.

## Always-on rules

- **Single entrypoint:** drive everything through `./devclaw <cmd>` (Windows:
  `.\devclaw.cmd <cmd>`), which wraps `azd`. Fall back to `azd up`/`azd deploy`/
  `azd down` directly only if the wrapper isn't runnable.
- **Configuration** is via `azd env set <KEY> <VALUE>` before `devclaw up` — there
  is no `.env` file to edit. Model/version/capacity are Bicep params in
  `infra/main.bicep` (`aiModelName`/`aiModelVersion`/`aiModelCapacity`), not env vars.
- **Region:** `AZURE_LOCATION` must be in the allowed list in `infra/main.bicep`.
  If the chosen region lacks the model SKU, set `AZURE_OPENAI_LOCATION` separately.
- **Teams is opt-in:** default `devclaw up` is browser-only — no Bot app
  registration, no Azure Bot, no Teams channel. To enable: `azd env set
  ENABLE_TEAMS true` then re-run `devclaw up`, or just run `devclaw teams` (it
  prompts to enable and re-provisions). Don't suggest creating bot app
  registrations by default — they fail on restricted tenants.
- **Restricted subscriptions/tenants:** before `devclaw up`, set whichever of
  these apply: `SERVICE_MANAGEMENT_REFERENCE=<service-tree-guid>` (tenants that
  require it on new app regs), `SKIP_STORAGE=true` (subscriptions whose Azure
  Policy blocks shared-key storage — ACA file mounts need shared keys today;
  gateway token + sessions won't persist across replica restarts). ACR admin
  is already disabled; image pulls use the container app's managed identity.
- **Model scope:** today this targets **Azure OpenAI** models only (default
  `gpt-5-mini`). Do not claim Claude or other Foundry Models work today — they are
  "near future" scope.
- **Passwordless:** the model is called keyless via Managed Identity
  (`disableLocalAuth: true`). Never add API keys or suggest key-based auth.
- **Secrets:** never commit secrets. `_local/`, `.azure/`, `.azure-cli/`,
  `.azd-config/`, the generated `teams/package/manifest.json`, and
  `teams/openclaw-teams-app.zip` are gitignored — keep it that way.
- **Confirm destructive actions:** before `devclaw down` / `azd down`,
  `az ad app delete`, RBAC removal, or deleting state, state exactly what will be
  destroyed and get explicit user confirmation. Never pass `--force`/`--no-prompt`
  to skip a confirmation the user hasn't given.
- **Cost:** to pause, use `devclaw stop` (scale to 0, $0, state kept) — not `down`.

## Quick verification

After a deploy: `devclaw status` should show `Running`; open the URL it prints,
sign in with a Microsoft account, and confirm the WebChat UI loads. `devclaw test`
only prints a status summary — it is not an end-to-end model test.
