"""SDK driver: managed-identity-native data-plane access via azure-identity.

This is the *production-preferred* auth path: it acquires tokens with
`azure-identity`'s `DefaultAzureCredential` (so it works with the Gateway
container's user-assigned managed identity — no `az login`, no keys) and calls
the ADC data plane directly over HTTPS for the operations whose REST shape is
verified (sandbox state, port exposure with the full Entra allow-list).

For the operations whose preview REST/SDK surface is not yet pinned
(disk-image build, snapshot, sandbox create/exec, lifecycle) it composes the
proven `CliSandboxDriver` — itself made MI-native via `--managed-identity`.
This keeps ONE module to migrate: as `azure-containerapps-sandbox` stabilizes,
replace the delegated calls below with native SDK calls and nothing else
changes.

Select with SANDBOX_DRIVER=sdk.
"""

from __future__ import annotations

from .cli_driver import CliSandboxDriver
from .interface import (
    ExecRequest,
    ExecResult,
    GroupConfig,
    PortGate,
    SandboxError,
    SandboxHandle,
    SandboxSpec,
    WarmupSpec,
)

_DATAPLANE_SCOPE = "https://dynamicsessions.io/.default"


class SdkSandboxDriver:
    def __init__(self, cfg: GroupConfig):
        try:
            import requests
            from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
        except ImportError as exc:  # pragma: no cover - import guard
            raise SandboxError(
                "SDK driver needs 'azure-identity' and 'requests'. "
                "pip install azure-identity requests  (or set SANDBOX_DRIVER=cli)"
            ) from exc

        self.cfg = cfg
        self._requests = requests
        # MI-native: prefer the configured user-assigned identity in Azure,
        # else fall back to the full DefaultAzureCredential chain (az login,
        # VS Code, etc.) for local development.
        if cfg.managed_identity and cfg.managed_identity != "system":
            self._cred = ManagedIdentityCredential(client_id=cfg.managed_identity)
        elif cfg.managed_identity == "system":
            self._cred = ManagedIdentityCredential()
        else:
            self._cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
        # Proven CLI path for create/exec/snapshot/lifecycle, also MI-native.
        self._cli = CliSandboxDriver(cfg)

    # --------------------------------------------------------------- helpers
    def _token(self, scope: str = _DATAPLANE_SCOPE) -> str:
        return self._cred.get_token(scope).token

    def _dp_url(self, suffix: str) -> str:
        return (
            f"https://management.{self.cfg.region}.azuredevcompute.io/subscriptions/"
            f"{self.cfg.subscription_id}/resourceGroups/{self.cfg.resource_group}/"
            f"sandboxGroups/{self.cfg.group_name}/{suffix}"
            f"?api-version={self.cfg.api_version}"
        )

    def _dp(self, method: str, suffix: str, body: dict | None = None) -> dict:
        resp = self._requests.request(
            method,
            self._dp_url(suffix),
            headers={
                "Authorization": f"Bearer {self._token()}",
                "Content-Type": "application/json",
            },
            json=body,
            timeout=60,
        )
        if resp.status_code >= 400:
            raise SandboxError(f"data plane {method} {suffix} -> {resp.status_code}: {resp.text[:300]}")
        return resp.json() if resp.content else {}

    # ---- verified native (MI) data-plane operations ----
    def get_state(self, handle: SandboxHandle) -> str:
        data = self._dp("GET", f"sandboxes/{handle.sandbox_id}")
        return str(data.get("state", "")).lower()

    def expose_port(self, handle: SandboxHandle, port: int, gate: PortGate) -> str:
        if gate.mode == "anonymous":
            auth: dict = {"anonymous": True}
        else:
            entra: dict = {"enabled": True}
            if gate.emails:
                entra["emails"] = gate.emails
            if gate.email_suffixes:
                entra["emailSuffixes"] = gate.email_suffixes
            if gate.object_ids:
                entra["objectIds"] = gate.object_ids
            if gate.tenant_ids:
                entra["tenantIds"] = gate.tenant_ids
            auth = {"entraId": entra}
        data = self._dp("POST", f"sandboxes/{handle.sandbox_id}/ports/add",
                        {"port": port, "auth": auth})
        ports = data.get("ports") or []
        return (ports[0].get("url") if ports else data.get("url")) or ""

    # ---- delegated to the proven CLI path (migrate to SDK as it stabilizes) ----
    def ensure_disk_image(self, acr_image_ref: str, image_digest: str) -> str:
        return self._cli.ensure_disk_image(acr_image_ref, image_digest)

    def create_warm_snapshot(self, disk_image_id: str, warmup: WarmupSpec) -> str:
        return self._cli.create_warm_snapshot(disk_image_id, warmup)

    def fork_from_snapshot(self, snapshot_id: str, spec: SandboxSpec) -> SandboxHandle:
        return self._cli.fork_from_snapshot(snapshot_id, spec)

    def boot_from_disk_image(self, disk_image_id: str, spec: SandboxSpec) -> SandboxHandle:
        return self._cli.boot_from_disk_image(disk_image_id, spec)

    def specialize(self, handle: SandboxHandle, spec: SandboxSpec) -> None:
        return self._cli.specialize(handle, spec)

    def exec(self, handle: SandboxHandle, request: ExecRequest) -> ExecResult:
        return self._cli.exec(handle, request)

    def suspend(self, handle: SandboxHandle) -> None:
        return self._cli.suspend(handle)

    def resume(self, handle: SandboxHandle) -> None:
        return self._cli.resume(handle)

    def destroy(self, handle: SandboxHandle) -> None:
        return self._cli.destroy(handle)
