# AGENTS.md — openclaw-dev

Guidance for AI coding agents (Claude Code, OpenAI Codex, Cursor, Gemini CLI,
Amp, and others) working in this repository.

This repo deploys **OpenClaw** as a secure, hosted AI assistant on **Azure
Container Apps**, wired to **Azure OpenAI in Foundry Models** over a **Managed
Identity** (no API keys), gated by **Entra ID Easy Auth**, with an optional
**Microsoft Teams** channel. Alpha, single-tenant, dev/test.

## Start here

For any deploy / configure / operate / Teams / troubleshoot / teardown request,
follow the full playbook in **[`skills/openclaw-on-azure/SKILL.md`](skills/openclaw-on-azure/SKILL.md)**.
It contains the command map, env-var contract, region list, and error catalog.

## Non-negotiable rules

- **Single entrypoint:** use `./devclaw <cmd>` (Windows `.\devclaw.cmd <cmd>`),
  a thin wrapper over the Azure Developer CLI (`azd`). Fall back to `azd` directly
  only if the wrapper can't run.
- **Configure with `azd env set <KEY> <VALUE>`** before `devclaw up`. There is no
  `.env` file. Model/version/capacity live in `infra/main.bicep`, not env vars.
- **Region** `AZURE_LOCATION` must be in the allowed list in `infra/main.bicep`;
  set `AZURE_OPENAI_LOCATION` separately if that region lacks the model SKU.
- **Azure OpenAI only today** (default `gpt-5-mini`). Don't claim Claude / other
  Foundry Models work yet — they're future scope.
- **Passwordless:** model calls use Managed Identity (`disableLocalAuth: true`).
  Never add or suggest API keys.
- **Never commit secrets.** `_local/`, `.azure/`, `.azure-cli/`, `.azd-config/`,
  the generated `teams/package/manifest.json`, and `teams/openclaw-teams-app.zip`
  are gitignored.
- **Confirm before destructive actions** (`devclaw down`/`azd down`,
  `az ad app delete`, RBAC removal, deleting state): state what will be deleted and
  get explicit confirmation. Never use `--force`/`--no-prompt` to skip it.
- **To pause cheaply** use `devclaw stop` (scale to 0, $0, state kept), not `down`.

## Verify

`devclaw status` should show `Running`; open the printed URL, sign in with a
Microsoft account, confirm the WebChat UI loads. `devclaw test` is only a status
summary, not an end-to-end model test.
