"""OpenClaw Sandbox MCP server (stdio).

Exposes ACA Sandbox execution to the OpenClaw Gateway as MCP tools. The model
calls these instead of running shell/code in-process, so all untrusted
execution lands in a throwaway, Hyper-V-isolated ACA Sandbox.

Tools:
  * sandbox_run        — run a shell command in a sandbox
  * sandbox_run_code   — run a code snippet (python|node|bash) in a sandbox
  * sandbox_end_session— tear down a persistent session sandbox

Pass a stable `session_id` to reuse a warm, persistent workspace (suspended
when idle, resumed in sub-second). Omit it for a one-shot ephemeral sandbox
that is destroyed right after the call.

Launch (OpenClaw `mcp.servers` stdio entry):
    python -m sandbox_mcp.server
"""

from __future__ import annotations

import base64
import json
import os

import anyio

# OpenClaw spawns this server over stdio with a scrubbed environment that drops
# the Azure managed-identity token vars (IDENTITY_ENDPOINT/IDENTITY_HEADER/
# MSI_ENDPOINT) needed for keyless auth. The gateway forwards them under
# aliased SANDBOX_MI_* names (which pass the stdio env allow-list); restore the
# canonical names here so the `aca` subprocess and azure-identity can acquire a
# token instead of hanging. Must run before any adapter/aca invocation.
for _alias, _canonical in (
    ("SANDBOX_MI_ENDPOINT", "IDENTITY_ENDPOINT"),
    ("SANDBOX_MI_HEADER", "IDENTITY_HEADER"),
    ("SANDBOX_MSI_ENDPOINT", "MSI_ENDPOINT"),
):
    _val = os.environ.get(_alias)
    if _val and not os.environ.get(_canonical):
        os.environ[_canonical] = _val

from .factory import group_config_from_env, make_adapter, settings_from_env
from .interface import SandboxHandle
from .pool import SandboxPool

try:
    from mcp.server.fastmcp import FastMCP
except ImportError as exc:  # pragma: no cover - import guard
    raise SystemExit(
        "The MCP SDK is required: pip install 'mcp>=1.2'  (see requirements.txt)"
    ) from exc


_settings = settings_from_env()
_cfg = group_config_from_env()
_pool = SandboxPool(make_adapter(_cfg, _settings.driver), _settings)

mcp = FastMCP("openclaw-sandbox")

_LANG_RUNNERS = {
    # Code is base64-encoded and piped to the interpreter as a single line.
    # A heredoc would break here: the driver appends `; printf <marker> "$?"`
    # to every command, which lands on the same line as the heredoc terminator
    # and stops it from terminating (so stdout is lost). base64 over a pipe has
    # no quoting, newline, or terminator hazards.
    "python": "printf %s {code_b64} | base64 -d | python3",
    "node": "printf %s {code_b64} | base64 -d | node",
    "bash": "printf %s {code_b64} | base64 -d | bash",
}


def _format(result, sandbox_id: str) -> str:
    payload = {
        "exit_code": result.exit_code,
        "timed_out": result.timed_out,
        "duration_s": result.duration_s,
        "sandbox_id": sandbox_id,
        "output": result.stdout,
    }
    return json.dumps(payload, ensure_ascii=False)


async def _run_in_sandbox(command: str, *, session_id, role, egress_allow, cwd, timeout_s) -> str:
    def work() -> str:
        handle: SandboxHandle | None = None
        try:
            handle = _pool.acquire(role=role or "default", egress_allow=egress_allow, session_key=session_id)
            result = _pool.run(handle, command, cwd=cwd, timeout_s=timeout_s)
            return _format(result, handle.sandbox_id)
        finally:
            if handle is not None:
                _pool.release(handle, session_key=session_id)

    return await anyio.to_thread.run_sync(work)


@mcp.tool()
async def sandbox_run(
    command: str,
    session_id: str | None = None,
    role: str = "default",
    egress_allow: list[str] | None = None,
    cwd: str | None = None,
    timeout_s: int | None = None,
) -> str:
    """Run a shell command inside an isolated, ephemeral ACA Sandbox and return
    a JSON result {exit_code, output, ...}. Provide `session_id` to reuse a
    persistent workspace across calls; omit it for a throwaway sandbox.
    `egress_allow` is a deny-default host allow-list applied at runtime."""
    return await _run_in_sandbox(
        command, session_id=session_id, role=role, egress_allow=egress_allow,
        cwd=cwd, timeout_s=timeout_s,
    )


@mcp.tool()
async def sandbox_run_code(
    language: str,
    code: str,
    session_id: str | None = None,
    role: str = "default",
    egress_allow: list[str] | None = None,
    cwd: str | None = None,
    timeout_s: int | None = None,
) -> str:
    """Run a code snippet (`language` = python | node | bash) inside an isolated
    ACA Sandbox and return a JSON result. Same session/egress semantics as
    sandbox_run."""
    lang = language.lower().strip()
    tmpl = _LANG_RUNNERS.get(lang)
    if not tmpl:
        return json.dumps({"exit_code": 2, "output": f"unsupported language: {language}"})
    code_b64 = base64.b64encode(code.encode()).decode()
    command = tmpl.format(code_b64=code_b64)
    return await _run_in_sandbox(
        command, session_id=session_id, role=role, egress_allow=egress_allow,
        cwd=cwd, timeout_s=timeout_s,
    )


@mcp.tool()
async def sandbox_end_session(session_id: str) -> str:
    """Destroy a persistent session sandbox created with `session_id`."""
    def work() -> str:
        handle = _pool._sessions.pop(session_id, None)
        if handle is None:
            return json.dumps({"ok": True, "note": "no such session"})
        _pool.adapter.destroy(handle)
        return json.dumps({"ok": True, "destroyed": handle.sandbox_id})

    return await anyio.to_thread.run_sync(work)


def main() -> None:
    mcp.run()  # stdio transport


if __name__ == "__main__":
    main()
