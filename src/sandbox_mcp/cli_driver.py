"""CLI driver: implements SandboxAdapter by shelling out to the `aca` CLI.

This is the *proven* path — every command here was validated live against a
real `Microsoft.App/SandboxGroups` (preview, api 2026-02-01-preview). It is the
default driver; the SDK driver is preferred once its preview surface stabilizes.

Auth: `aca` delegates to the Azure CLI (`az`) session, and the ADC data plane
token is acquired the same way. The caller (the OpenClaw Gateway's managed
identity, or a developer's `az login`) must hold the
`Container Apps SandboxGroup Data Owner` role on the group.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

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

_UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
# Well-known ACR token username used with an AAD access token (passwordless).
_ACR_TOKEN_USER = "00000000-0000-0000-0000-000000000000"
_EXIT_MARKER = "__ACA_EXIT_"


class CliSandboxDriver(SandboxAdapter):
    def __init__(self, cfg: GroupConfig, aca_path: str = "aca", az_path: str = "az"):
        self.cfg = cfg
        self.aca = shutil.which(aca_path) or aca_path
        self.az = shutil.which(az_path) or az_path

    # ------------------------------------------------------------------ utils
    def _run(self, argv: list[str], timeout: int = 300, check: bool = True) -> str:
        try:
            proc = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:  # pragma: no cover - timing
            raise SandboxError(f"timeout running {argv[0]} {argv[1:3]}") from exc
        if check and proc.returncode != 0:
            raise SandboxError(
                f"{argv[0]} failed ({proc.returncode}): "
                f"{(proc.stderr or proc.stdout).strip()[:500]}"
            )
        return proc.stdout

    def _aca(self, *args: str, timeout: int = 300, check: bool = True) -> str:
        argv = [
            self.aca,
            *args,
            "--group",
            self.cfg.group_name,
            "-g",
            self.cfg.resource_group,
            "-s",
            self.cfg.subscription_id,
            "--region",
            self.cfg.region,
        ]
        if self.cfg.managed_identity:
            argv += ["--managed-identity", self.cfg.managed_identity]
        return self._run(argv, timeout=timeout, check=check)

    @staticmethod
    def _json(text: str):
        text = (text or "").strip()
        if not text:
            return None
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            # `aca` sometimes prints human status lines before/after JSON.
            start = text.find("[") if text.lstrip().startswith("[") else text.find("{")
            if start >= 0:
                try:
                    return json.loads(text[start:])
                except json.JSONDecodeError:
                    return None
            return None

    @staticmethod
    def _first_uuid(text: str) -> str | None:
        m = _UUID_RE.search(text or "")
        return m.group(0) if m else None

    # ---------------------------------------------------------- image/snapshot
    def ensure_disk_image(self, acr_image_ref: str, image_digest: str) -> str:
        # Hash-gate: reuse a disk image already labelled with this digest.
        existing = self._json(self._aca("sandboxgroup", "disk", "list", "-o", "json"))
        if isinstance(existing, list):
            for disk in existing:
                if (disk.get("labels") or {}).get("digest") == image_digest:
                    return disk["id"]

        # Build it. ACR pull via managed identity 401s in preview, so use a
        # short-lived AAD ACR token (passwordless, no admin creds).
        registry = acr_image_ref.split("/", 1)[0]
        acr_name = registry.split(".", 1)[0]
        token = self._run(
            [self.az, "acr", "login", "-n", acr_name, "--expose-token",
             "--query", "accessToken", "-o", "tsv"]
        ).strip()
        if not token:
            raise SandboxError("could not obtain an AAD ACR token (az acr login --expose-token)")
        name = f"openclaw-exec-{image_digest[:12]}"
        out = self._aca(
            "sandboxgroup", "disk", "create",
            "--image", acr_image_ref,
            "--name", name,
            "--label", f"digest={image_digest}",
            "--username", _ACR_TOKEN_USER,
            "--token", token,
            "-o", "json",
            timeout=900,
        )
        data = self._json(out)
        disk_id = (data or {}).get("id") or self._first_uuid(out)
        if not disk_id:
            raise SandboxError(f"disk image create returned no id: {out[:300]}")
        return disk_id

    def create_warm_snapshot(self, disk_image_id: str, warmup: WarmupSpec) -> str:
        warm_name = f"openclaw-warm-{_short_hash(warmup)}"
        # Idempotent: reuse an existing snapshot with this warm name.
        snaps = self._json(self._aca("sandboxgroup", "snapshot", "list", "-o", "json"))
        if isinstance(snaps, list):
            for s in snaps:
                if (s.get("labels") or {}).get("name") == warm_name:
                    return warm_name

        spec = SandboxSpec(role="warmup", env=dict(warmup.boot_env), labels={"role": "warmup"})
        handle = self.boot_from_disk_image(disk_image_id, spec)
        try:
            self._wait_ready(handle, timeout_s=warmup.timeout_s)
            for cmd in warmup.commands:
                self.exec(handle, ExecRequest(command=cmd, timeout_s=warmup.timeout_s))
            self._aca(
                "sandbox", "snapshot", "--id", handle.sandbox_id, "--name", warm_name,
                timeout=warmup.timeout_s,
            )
        finally:
            self.destroy(handle)
        return warm_name

    # ------------------------------------------------------------- sandboxes
    def fork_from_snapshot(self, snapshot_id: str, spec: SandboxSpec) -> SandboxHandle:
        args = ["sandbox", "create", "--snapshot", snapshot_id]
        args += self._size_args(spec) + self._label_args(spec, "openclaw-worker")
        out = self._aca(*args, "-o", "json", timeout=120)
        return self._handle_from_create(out, spec, source="snapshot")

    def boot_from_disk_image(self, disk_image_id: str, spec: SandboxSpec) -> SandboxHandle:
        args = ["sandbox", "create", "--disk-id", disk_image_id]
        args += self._size_args(spec) + self._label_args(spec, "openclaw-worker")
        # Cold boot CAN take env (no warm process yet).
        for k, v in self._boot_env(spec).items():
            args += ["--env", f"{k}={v}"]
        out = self._aca(*args, "-o", "json", timeout=120)
        return self._handle_from_create(out, spec, source="diskimage")

    def specialize(self, handle: SandboxHandle, spec: SandboxSpec) -> None:
        # Runtime env (forks can't take boot env) — carried on the handle and
        # exported by exec(). Cold-booted sandboxes already have boot env, but
        # carrying it here too is harmless and uniform.
        handle.env.update(self._boot_env(spec))
        handle.role = spec.role
        # Deny-default egress + per-role host allowlist. The aca CLI takes the
        # allow-list as `--rule "<host>:Allow"` entries (verified against
        # 1.0.0-preview.1; `aca sandbox egress set --default Deny --rule ...`).
        if spec.egress_default_deny or spec.egress_allow_hosts:
            args = ["sandbox", "egress", "set", "--id", handle.sandbox_id]
            args += ["--default", "Deny" if spec.egress_default_deny else "Allow"]
            for host in spec.egress_allow_hosts:
                args += ["--rule", f"{host}:Allow"]
            self._aca(*args, check=False)

    # ------------------------------------------------------------------- work
    def exec(self, handle: SandboxHandle, request: ExecRequest) -> ExecResult:
        env = {**handle.env, **request.env}
        prefix = "".join(f"export {k}={_shq(v)}; " for k, v in env.items())
        if request.cwd:
            prefix += f"cd {_shq(request.cwd)}; "
        marker = f"{_EXIT_MARKER}{uuid.uuid4().hex}__"
        script = f"{prefix}{request.command}; printf '\\n{marker}%s__' \"$?\""
        started = time.monotonic()
        timed_out = False
        try:
            out = self._aca(
                "sandbox", "exec", "--id", handle.sandbox_id, "-c", script,
                timeout=request.timeout_s, check=False,
            )
        except SandboxError:
            out, timed_out = "", True
        duration = time.monotonic() - started
        exit_code, body = _split_exit(out, marker)
        if timed_out:
            exit_code = 124
        return ExecResult(
            exit_code=exit_code,
            stdout=body,
            stderr="",  # aca exec merges streams; kept for interface symmetry
            duration_s=round(duration, 3),
            timed_out=timed_out,
        )

    def expose_port(self, handle: SandboxHandle, port: int, gate: PortGate) -> str:
        if gate.mode == "anonymous":
            out = self._aca(
                "sandbox", "port", "add", "--id", handle.sandbox_id,
                "--port", str(port), "--anonymous", "-o", "json",
            )
            data = self._json(out) or []
            return (data[0] if isinstance(data, list) and data else data).get("url", "")
        # Entra-gated: the CLI only sets a single --email, so post the full
        # allow-list to the data plane.
        entra: dict = {"enabled": True}
        if gate.emails:
            entra["emails"] = gate.emails
        if gate.email_suffixes:
            entra["emailSuffixes"] = gate.email_suffixes
        if gate.object_ids:
            entra["objectIds"] = gate.object_ids
        if gate.tenant_ids:
            entra["tenantIds"] = gate.tenant_ids
        body = {"port": port, "auth": {"entraId": entra}}
        uri = (
            f"https://management.{self.cfg.region}.azuredevcompute.io/subscriptions/"
            f"{self.cfg.subscription_id}/resourceGroups/{self.cfg.resource_group}/"
            f"sandboxGroups/{self.cfg.group_name}/sandboxes/{handle.sandbox_id}/"
            f"ports/add?api-version={self.cfg.api_version}"
        )
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(body, fh)
            tmp = fh.name
        try:
            out = self._run([
                self.az, "rest", "--method", "post", "--url", uri,
                "--resource", "https://dynamicsessions.io",
                "--headers", "Content-Type=application/json",
                "--body", f"@{tmp}",
            ])
        finally:
            Path(tmp).unlink(missing_ok=True)
        data = self._json(out) or {}
        ports = data.get("ports") or []
        return (ports[0].get("url") if ports else data.get("url")) or ""

    # -------------------------------------------------------------- lifecycle
    def suspend(self, handle: SandboxHandle) -> None:
        self._aca("sandbox", "stop", "--id", handle.sandbox_id, check=False)

    def resume(self, handle: SandboxHandle) -> None:
        self._aca("sandbox", "resume", "--id", handle.sandbox_id, check=False)

    def destroy(self, handle: SandboxHandle) -> None:
        self._aca("sandbox", "delete", "--id", handle.sandbox_id, "--yes", check=False)

    # --------------------------------------------------------------- internals
    def _handle_from_create(self, out: str, spec: SandboxSpec, source: str) -> SandboxHandle:
        data = self._json(out)
        sid = (data or {}).get("id") if isinstance(data, dict) else None
        if not sid:
            sid = self._first_uuid(out)
        if not sid:
            raise SandboxError(f"sandbox create returned no id: {out[:300]}")
        return SandboxHandle(
            sandbox_id=sid, role=spec.role, labels=dict(spec.labels), source=source
        )

    def _wait_ready(self, handle: SandboxHandle, timeout_s: int) -> None:
        deadline = time.monotonic() + min(timeout_s, 120)
        while time.monotonic() < deadline:
            out = self._aca("sandbox", "get", "--id", handle.sandbox_id, "-o", "json", check=False)
            data = self._json(out) or {}
            if str(data.get("state", "")).lower() == "running":
                return
            time.sleep(2)

    @staticmethod
    def _size_args(spec: SandboxSpec) -> list[str]:
        args: list[str] = []
        if spec.cpu:
            args += ["--cpu", spec.cpu]
        if spec.memory:
            args += ["--memory", spec.memory]
        return args

    @staticmethod
    def _label_args(spec: SandboxSpec, name: str) -> list[str]:
        args = ["--label", f"name={name}", "--label", f"role={spec.role}"]
        for k, v in spec.labels.items():
            args += ["--label", f"{k}={v}"]
        return args

    @staticmethod
    def _boot_env(spec: SandboxSpec) -> dict[str, str]:
        env = dict(spec.env)
        if spec.identity_client_id:
            env.setdefault("AZURE_CLIENT_ID", spec.identity_client_id)
            env.setdefault("AZURE_OPENAI_AUTH", "managed-identity")
        return env


def _shq(value: str) -> str:
    """Minimal POSIX single-quote shell escaping."""
    return "'" + str(value).replace("'", "'\"'\"'") + "'"


def _split_exit(out: str, marker: str) -> tuple[int, str]:
    idx = out.rfind(marker)
    if idx < 0:
        return 0, out.strip()
    body = out[:idx].rstrip("\n")
    tail = out[idx + len(marker):]
    code_str = tail.split("__", 1)[0].strip()
    try:
        return int(code_str), body
    except ValueError:
        return 0, body


def _short_hash(warmup: WarmupSpec) -> str:
    import hashlib

    payload = json.dumps(
        {"c": warmup.commands, "e": warmup.boot_env}, sort_keys=True
    ).encode()
    return hashlib.sha256(payload).hexdigest()[:12]
