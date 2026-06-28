"""OpenClaw sandbox execution layer — adapter + MCP server.

Public surface:
    from sandbox_mcp import make_adapter, group_config_from_env, settings_from_env
    from sandbox_mcp.interface import SandboxSpec, ExecRequest, PortGate
    from sandbox_mcp.pool import SandboxPool
"""

from .factory import group_config_from_env, make_adapter, settings_from_env
from .interface import (
    ExecRequest,
    ExecResult,
    GroupConfig,
    PortGate,
    SandboxAdapter,
    SandboxError,
    SandboxHandle,
    SandboxSpec,
    WarmupSpec,
)
from .pool import SandboxPool

__all__ = [
    "ExecRequest",
    "ExecResult",
    "GroupConfig",
    "PortGate",
    "SandboxAdapter",
    "SandboxError",
    "SandboxHandle",
    "SandboxSpec",
    "WarmupSpec",
    "SandboxPool",
    "group_config_from_env",
    "make_adapter",
    "settings_from_env",
]
