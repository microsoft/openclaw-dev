"""Sandbox adapter interface.

All ACA Sandbox *preview* surface is isolated behind this interface so a
breaking change in the `aca` CLI or the `azure-containerapps-sandbox` SDK is
contained to a single driver module. The MCP server (server.py) and any other
caller only ever depend on `SandboxAdapter` — never on a concrete driver.

Two concrete drivers implement this interface:
  * cli_driver.CliSandboxDriver  — shells out to the `aca` CLI (proven path)
  * sdk_driver.SdkSandboxDriver  — uses the Python SDK (preferred once stable)

Select with the SANDBOX_DRIVER env var (cli | sdk); see factory.py.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable


@dataclass(frozen=True)
class GroupConfig:
    """Static configuration shared by every sandbox operation."""

    subscription_id: str
    resource_group: str
    group_name: str
    region: str
    # API version for the ADC data plane (preview). Pinned so a server-side
    # default change can't silently alter behaviour.
    api_version: str = "2026-02-01-preview"
    # Managed identity for keyless auth when running in Azure (e.g. the Gateway
    # container). "system", a user-assigned client-id UUID, or None (use the
    # ambient az login / DefaultAzureCredential chain for local/dev).
    managed_identity: str | None = None


@dataclass(frozen=True)
class WarmupSpec:
    """The expensive, *shared* warmup run once to build a warm snapshot.

    `commands` are executed in order inside a sandbox booted from the disk
    image (runtime init, dependency load, browser warmup, auth handshake) —
    everything that is identical across all workers. Per-role differences must
    NOT go here; they are applied at runtime via SandboxSpec.
    """

    commands: list[str] = field(default_factory=list)
    boot_env: dict[str, str] = field(default_factory=dict)
    timeout_s: int = 600


@dataclass(frozen=True)
class SandboxSpec:
    """Per-task / per-session specialization applied AFTER boot/fork.

    A fork resumes an already-running process, so boot env never reaches it.
    These fields are applied at runtime by `specialize()` via exec / egress /
    secret injection.
    """

    role: str = "default"
    # Extra environment exported into the worker's shell before tasks run.
    env: dict[str, str] = field(default_factory=dict)
    # Managed-identity client id the worker should use for keyless Azure auth.
    # Lets different roles use different user-assigned identities on the group.
    identity_client_id: str | None = None
    # Deny-default egress: only these hosts are reachable. Empty => no egress
    # change (inherits the snapshot/disk default).
    egress_allow_hosts: list[str] = field(default_factory=list)
    egress_default_deny: bool = True
    # Free-form labels for fleet management / billing.
    labels: dict[str, str] = field(default_factory=dict)
    # CPU / memory overrides (millicores / Mi). None => platform default.
    cpu: str | None = None
    memory: str | None = None


@dataclass(frozen=True)
class ExecRequest:
    """A single command (or script) to run inside a sandbox."""

    command: str
    # Working directory inside the sandbox.
    cwd: str | None = None
    # Per-call env overrides (merged over the spec env).
    env: dict[str, str] = field(default_factory=dict)
    timeout_s: int = 120


@dataclass(frozen=True)
class ExecResult:
    exit_code: int
    stdout: str
    stderr: str
    duration_s: float
    timed_out: bool = False


@dataclass(frozen=True)
class PortGate:
    """How an exposed HTTP port is secured."""

    # "anonymous" | "entra"
    mode: str = "entra"
    emails: list[str] = field(default_factory=list)
    email_suffixes: list[str] = field(default_factory=list)
    object_ids: list[str] = field(default_factory=list)
    tenant_ids: list[str] = field(default_factory=list)


@dataclass
class SandboxHandle:
    """An opaque-ish handle to a live sandbox.

    `sandbox_id` is the only field the data plane needs; the rest is metadata
    the caller may use for routing / cleanup. `env` holds the runtime-injected
    specialization env so `exec()` can apply it (a fork can't take boot env).
    """

    sandbox_id: str
    role: str = "default"
    labels: dict[str, str] = field(default_factory=dict)
    source: str = "unknown"  # "snapshot" | "diskimage"
    env: dict[str, str] = field(default_factory=dict)


class SandboxError(RuntimeError):
    """Raised when a sandbox operation fails. Drivers wrap provider errors."""


@runtime_checkable
class SandboxAdapter(Protocol):
    """The single seam every caller depends on."""

    # --- image / snapshot lifecycle (amortized, infrequent) ---
    def ensure_disk_image(self, acr_image_ref: str, image_digest: str) -> str:
        """Return a disk-image id for the given ACR image, building it only if
        no disk image labelled with `image_digest` already exists (idempotent,
        hash-gated)."""

    def create_warm_snapshot(self, disk_image_id: str, warmup: WarmupSpec) -> str:
        """Boot one sandbox from the disk image, run the shared warmup, snapshot
        it, and return the snapshot id/name. Idempotent on the warmup hash."""

    # --- per-task / per-session sandboxes ---
    def fork_from_snapshot(self, snapshot_id: str, spec: SandboxSpec) -> SandboxHandle:
        """Sub-second fork of a warm snapshot. Does NOT specialize."""

    def boot_from_disk_image(self, disk_image_id: str, spec: SandboxSpec) -> SandboxHandle:
        """Cold boot from a disk image (fallback when no snapshot)."""

    def specialize(self, handle: SandboxHandle, spec: SandboxSpec) -> None:
        """Apply per-role runtime differences AFTER resume: scoped creds/env,
        deny-default egress + host allowlist, role labels."""

    # --- work ---
    def exec(self, handle: SandboxHandle, request: ExecRequest) -> ExecResult:
        """Run a command inside the sandbox and capture the result."""

    def expose_port(self, handle: SandboxHandle, port: int, gate: PortGate) -> str:
        """Expose an HTTP port and return its public URL (optional)."""

    # --- lifecycle ---
    def suspend(self, handle: SandboxHandle) -> None: ...
    def resume(self, handle: SandboxHandle) -> None: ...
    def destroy(self, handle: SandboxHandle) -> None: ...
