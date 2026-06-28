# OpenClaw Sandbox Execution Layer (MCP adapter)

This module is the **execution layer** of the "orchestrator + sandbox" pattern:
the OpenClaw **Gateway stays on Azure Container Apps** (the brain — channels,
memory, model dispatch), and every untrusted tool call (shell, codegen/run,
file ops, browser) is offloaded to a **throwaway, Hyper-V-isolated ACA
Sandbox**, one per task (or per session).

The Gateway reaches this layer over **MCP** — OpenClaw's native tool protocol —
so no OpenClaw internals are patched. The model calls `sandbox_run` /
`sandbox_run_code`; this server forks an ACA Sandbox, runs the call keyless via
managed identity, returns the result, and destroys (or suspends) the sandbox.

```
OpenClaw Gateway (ACA)  --MCP stdio-->  sandbox_mcp.server  --aca/SDK-->  ACA Sandbox Group
        brain                              adapter                         ephemeral workers
```

## Why MCP and not a Node-Host patch

OpenClaw already has a built-in agent-sandbox subsystem (`docker | ssh |
openshell` backends), but none map to ACA Sandboxes (no sshd; HTTP-only port
proxy; no co-located Docker daemon). ACA Sandboxes only execute via the **ADC
data plane** (`aca sandbox exec`). MCP is the clean, supported seam: it's
first-class in OpenClaw (`mcp.servers`) and survives OpenClaw upgrades.

## Components

| File | Role |
|---|---|
| `interface.py` | The single seam: `SandboxAdapter` Protocol + dataclasses. **All preview-sensitive surface is isolated behind this.** |
| `cli_driver.py` | Adapter impl via the `aca` CLI (validated path; default). MI-native via `--managed-identity`. |
| `sdk_driver.py` | Adapter impl: `azure-identity` (MI-native) + data-plane HTTP for verified ops, CLI-backed for the rest. Preferred as the SDK stabilizes. |
| `pool.py` | Hybrid startup + lifecycle: disk image → warm snapshot → fork; per-task vs per-session; auto-fallback. |
| `server.py` | The MCP server (stdio) exposing `sandbox_run`, `sandbox_run_code`, `sandbox_end_session`. |
| `provision.py` | Build exec image → hash-gated disk image → warm snapshot. Run by the azd post-provision hook. |
| `factory.py` | Builds config + selects the driver from env. |
| `selftest.py` / `mcp_smoke.py` | Live validation (adapter round-trip / full MCP path). |
| `../execution-env/Dockerfile` | The common worker base image (built once, hash-gated). |

## The disk-image / snapshot hybrid

| Layer | What | When rebuilt |
|---|---|---|
| **Disk image** (cold template) | OS + Node + Python + tools (the `execution-env` image) | only when the image **digest** changes (hash-gated) |
| **Warm snapshot** (sub-second fork) | one sandbox booted + warmed (runtime/deps/browser), then snapshotted | when the warmup hash changes |
| **Runtime specialization** | per-role creds / egress allow-list / payload, applied **after** resume via `specialize()` + `exec()` | every task (never baked into the image) |
| **Autosuspend** | idle per-session sandbox → suspend → sub-second resume | lifecycle policy |

Measured live (eastasia): full image build ≈ 4 min; disk-image reuse boot ≈ 5 s;
**snapshot fork → warm gateway ≈ 1 s**.

## Configuration (env)

| Var | Meaning |
|---|---|
| `EXECUTION_MODE` | `inproc` (today's single-container behavior) or `sandbox` (this layer). Set on the Gateway. |
| `STARTUP` | `snapshot` (fork warm; default) or `diskimage` (cold boot). Auto-falls-back to `diskimage` if fork is unavailable. |
| `SANDBOX_DRIVER` | `cli` (default, validated) or `sdk` (MI-native). |
| `SANDBOX_SCOPE` | default lifecycle when the model omits `session_id`: `task` (ephemeral) or `session`. |
| `AZURE_SUBSCRIPTION_ID` / `AZURE_RESOURCE_GROUP` / `AZURE_SANDBOX_GROUP_NAME` / `AZURE_LOCATION` | the sandbox group. |
| `SANDBOX_MANAGED_IDENTITY` | `system` or a user-assigned client-id — keyless auth for the Gateway → data plane. |
| `WORKER_IDENTITY_CLIENT_ID` | the MI client-id workers use for keyless Azure OpenAI. |
| `EXEC_ACR_IMAGE` / `EXEC_IMAGE_DIGEST` / `EXEC_DISK_ID` / `EXEC_SNAPSHOT` | written by `provision.py`; pin the built image/disk/snapshot. |
| `SANDBOX_EGRESS_ALLOW` | default deny-default host allow-list for workers (comma-separated). |
| `SANDBOX_WARMUP_CMDS` | `;;`-separated warmup commands baked into the snapshot. |

## Bumping the image / re-warming the snapshot

1. Edit `src/execution-env/Dockerfile`.
2. Re-run the post-provision hook (or `python -m sandbox_mcp.provision`). The
   new image gets a new digest, so `ensure_disk_image` builds a fresh disk
   image (hash-gated — unchanged images are skipped) and a new warm snapshot.
3. The hook writes the new `EXEC_*` values to the azd env; restart the Gateway
   to pick them up.

## MCP tools exposed to the model

- `sandbox_run(command, session_id?, role?, egress_allow?, cwd?, timeout_s?)`
- `sandbox_run_code(language, code, session_id?, ...)` — `python | node | bash`
- `sandbox_end_session(session_id)`

Pass a stable `session_id` for a persistent workspace (suspended when idle,
sub-second resume). Omit it for a one-shot ephemeral sandbox.

## Local validation

```bash
cd src
# adapter round-trip (boot, specialize, exec, destroy):
python -m sandbox_mcp.selftest          # set EXEC_DISK_ID + AZURE_* first
# full MCP path (server over stdio + tool call):
python -m sandbox_mcp.mcp_smoke
```
