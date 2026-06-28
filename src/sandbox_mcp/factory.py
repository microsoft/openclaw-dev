"""Driver factory + server settings, all sourced from the environment.

The OpenClaw Gateway launches the MCP server (server.py) with these env vars
set from the azd environment / container env. Nothing here is OpenClaw- or
Azure-version specific beyond the driver it selects.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from .interface import GroupConfig, SandboxAdapter


@dataclass(frozen=True)
class ServerSettings:
    # Hybrid startup
    startup: str = "snapshot"          # snapshot | diskimage
    scope: str = "task"                # task | session
    driver: str = "cli"               # cli | sdk
    # Execution-environment image (built + pushed by the post-provision hook)
    acr_image: str = ""               # e.g. acrXXXX.azurecr.io/openclaw-exec:<tag>
    image_digest: str = ""            # sha256:... — hash-gates the disk image
    disk_id: str = ""                 # optional: pin a prebuilt disk image id
    snapshot_id: str = ""             # optional: pin a prebuilt warm snapshot
    # Keyless model auth that workers inherit
    model_base_url: str = ""
    model_deployment: str = ""
    worker_identity_client_id: str = ""
    # Default deny-default egress allow-list for workers (comma-separated hosts)
    default_egress_allow: tuple[str, ...] = ()
    # Idle/suspend + cleanup
    session_idle_suspend_s: int = 600
    exec_timeout_s: int = 120


def _split(csv: str) -> tuple[str, ...]:
    return tuple(h.strip() for h in csv.split(",") if h.strip())


def group_config_from_env() -> GroupConfig:
    missing = [
        k for k in (
            "AZURE_SUBSCRIPTION_ID", "AZURE_RESOURCE_GROUP",
            "AZURE_SANDBOX_GROUP_NAME", "AZURE_LOCATION",
        )
        if not os.environ.get(k)
    ]
    if missing:
        raise RuntimeError(f"missing required env for sandbox group: {', '.join(missing)}")
    return GroupConfig(
        subscription_id=os.environ["AZURE_SUBSCRIPTION_ID"],
        resource_group=os.environ["AZURE_RESOURCE_GROUP"],
        group_name=os.environ["AZURE_SANDBOX_GROUP_NAME"],
        region=os.environ["AZURE_LOCATION"],
        api_version=os.environ.get("SANDBOX_API_VERSION", "2026-02-01-preview"),
        managed_identity=os.environ.get("SANDBOX_MANAGED_IDENTITY") or None,
    )


def settings_from_env() -> ServerSettings:
    return ServerSettings(
        startup=os.environ.get("STARTUP", "snapshot").lower(),
        scope=os.environ.get("SANDBOX_SCOPE", "task").lower(),
        driver=os.environ.get("SANDBOX_DRIVER", "cli").lower(),
        acr_image=os.environ.get("EXEC_ACR_IMAGE", ""),
        image_digest=os.environ.get("EXEC_IMAGE_DIGEST", ""),
        disk_id=os.environ.get("EXEC_DISK_ID", ""),
        snapshot_id=os.environ.get("EXEC_SNAPSHOT", ""),
        model_base_url=os.environ.get("OPENAI_BASE_URL", ""),
        model_deployment=os.environ.get("OPENAI_MODEL_DEPLOYMENT", ""),
        worker_identity_client_id=os.environ.get("WORKER_IDENTITY_CLIENT_ID", "")
        or os.environ.get("AZURE_SANDBOX_IDENTITY_CLIENT_ID", ""),
        default_egress_allow=_split(os.environ.get("SANDBOX_EGRESS_ALLOW", "")),
        session_idle_suspend_s=int(os.environ.get("SANDBOX_IDLE_SUSPEND_S", "600")),
        exec_timeout_s=int(os.environ.get("SANDBOX_EXEC_TIMEOUT_S", "120")),
    )


def make_adapter(cfg: GroupConfig, driver: str) -> SandboxAdapter:
    if driver == "sdk":
        from .sdk_driver import SdkSandboxDriver

        return SdkSandboxDriver(cfg)  # type: ignore[return-value]
    from .cli_driver import CliSandboxDriver

    return CliSandboxDriver(cfg)
