"""Sandbox pool: orchestrates the hybrid startup + lifecycle on top of an adapter.

Decision rules (from the architecture):
  * truly common base (OS/runtime/tools)  -> disk image (hash-gated, built once)
  * expensive shared warm state           -> warm snapshot, then fork per task
  * per-task/per-role differences         -> applied at runtime via specialize()
  * idle per-user session reuse           -> suspend/resume lifecycle

STARTUP=snapshot prefers fork-from-snapshot and auto-falls-back to a cold disk
boot if the snapshot/fork path is unavailable in the current preview.
"""

from __future__ import annotations

import threading
import time

from .factory import ServerSettings
from .interface import (
    ExecRequest,
    ExecResult,
    SandboxAdapter,
    SandboxError,
    SandboxHandle,
    SandboxSpec,
    WarmupSpec,
)


class SandboxPool:
    def __init__(self, adapter: SandboxAdapter, settings: ServerSettings):
        self.adapter = adapter
        self.s = settings
        self._lock = threading.Lock()
        self._disk_id: str | None = None
        self._snapshot_id: str | None = None
        self._snapshot_unavailable = False
        self._sessions: dict[str, SandboxHandle] = {}

    # ----------------------------------------------------------- amortized setup
    def _ensure_disk(self) -> str:
        if self._disk_id:
            return self._disk_id
        with self._lock:
            if self._disk_id:
                return self._disk_id
            if self.s.disk_id:
                # Operator pinned a prebuilt disk image id.
                self._disk_id = self.s.disk_id
                return self._disk_id
            if not self.s.acr_image or not self.s.image_digest:
                raise SandboxError(
                    "EXEC_ACR_IMAGE / EXEC_IMAGE_DIGEST not set — run the "
                    "post-provision hook to build the execution image first."
                )
            self._disk_id = self.adapter.ensure_disk_image(self.s.acr_image, self.s.image_digest)
            return self._disk_id

    def _ensure_snapshot(self, disk_id: str) -> str | None:
        if self.s.startup != "snapshot" or self._snapshot_unavailable:
            return None
        if self._snapshot_id:
            return self._snapshot_id
        with self._lock:
            if self._snapshot_id:
                return self._snapshot_id
            if self.s.snapshot_id:
                # Operator pinned a prebuilt warm snapshot.
                self._snapshot_id = self.s.snapshot_id
                return self._snapshot_id
            try:
                warm = WarmupSpec(
                    commands=_warmup_commands(self.s),
                    boot_env=self._worker_env(),
                )
                self._snapshot_id = self.adapter.create_warm_snapshot(disk_id, warm)
                return self._snapshot_id
            except SandboxError:
                # Snapshot/fork not available in this preview — degrade to disk.
                self._snapshot_unavailable = True
                return None

    # ----------------------------------------------------------------- acquire
    def acquire(self, role: str, egress_allow: list[str] | None, session_key: str | None) -> SandboxHandle:
        disk = self._ensure_disk()
        spec = SandboxSpec(
            role=role,
            env=self._worker_env(),
            identity_client_id=self.s.worker_identity_client_id or None,
            egress_allow_hosts=egress_allow if egress_allow is not None
            else list(self.s.default_egress_allow),
            egress_default_deny=True,
            labels={"managed-by": "openclaw-gateway"},
        )

        if session_key and session_key in self._sessions:
            handle = self._sessions[session_key]
            self.adapter.resume(handle)  # no-op if already running
            return handle

        handle = self._boot(disk, spec)
        self.adapter.specialize(handle, spec)
        if session_key:
            self._sessions[session_key] = handle
        return handle

    def _boot(self, disk: str, spec: SandboxSpec) -> SandboxHandle:
        snap = self._ensure_snapshot(disk)
        if snap:
            try:
                return self.adapter.fork_from_snapshot(snap, spec)
            except SandboxError:
                self._snapshot_unavailable = True  # fall through to disk
        return self.adapter.boot_from_disk_image(disk, spec)

    # --------------------------------------------------------------------- run
    def run(self, handle: SandboxHandle, command: str, cwd: str | None, timeout_s: int | None) -> ExecResult:
        # Workers cold-booted from disk need a moment for the runtime to settle;
        # forked-from-snapshot workers are already warm.
        if handle.source == "diskimage":
            self._await_ready(handle)
        return self.adapter.exec(
            handle,
            ExecRequest(command=command, cwd=cwd, timeout_s=timeout_s or self.s.exec_timeout_s),
        )

    def release(self, handle: SandboxHandle, session_key: str | None) -> None:
        if session_key:
            # Persistent session: keep for reuse; suspend so idle costs nothing.
            self.adapter.suspend(handle)
        else:
            # Ephemeral per-task: throw it away.
            self.adapter.destroy(handle)

    def shutdown(self) -> None:
        for handle in list(self._sessions.values()):
            self.adapter.destroy(handle)
        self._sessions.clear()

    # --------------------------------------------------------------- internals
    def _worker_env(self) -> dict[str, str]:
        env: dict[str, str] = {}
        if self.s.model_base_url:
            env["OPENAI_BASE_URL"] = self.s.model_base_url
        if self.s.model_deployment:
            env["OPENAI_MODEL_DEPLOYMENT"] = self.s.model_deployment
        if self.s.worker_identity_client_id:
            env["AZURE_OPENAI_AUTH"] = "managed-identity"
            env["AZURE_CLIENT_ID"] = self.s.worker_identity_client_id
        return env

    def _await_ready(self, handle: SandboxHandle, attempts: int = 12) -> None:
        # Best-effort readiness probe via a trivial exec; ignores failures.
        for _ in range(attempts):
            res = self.adapter.exec(handle, ExecRequest(command="true", timeout_s=10))
            if res.exit_code == 0 and not res.timed_out:
                return
            time.sleep(1.5)


def _warmup_commands(s: ServerSettings) -> list[str]:
    import os

    raw = os.environ.get("SANDBOX_WARMUP_CMDS", "").strip()
    if raw:
        return [c.strip() for c in raw.split(";;") if c.strip()]
    # Minimal default: touch the runtime so the snapshot captures a warm process.
    return ["node --version 2>/dev/null || true", "python3 --version 2>/dev/null || true"]
