"""Live self-test for the sandbox adapter (Phase 1 round-trip).

Boots a sandbox, specializes it, runs a command, prints the result, and
destroys it — no MCP, no Gateway. Validates the adapter end-to-end against a
real sandbox group.

Usage (PowerShell):
    $env:AZURE_SUBSCRIPTION_ID="..."; $env:AZURE_RESOURCE_GROUP="rg-...";
    $env:AZURE_SANDBOX_GROUP_NAME="sbg-..."; $env:AZURE_LOCATION="eastasia";
    # either point at an existing disk image:
    $env:EXEC_DISK_ID="<disk-image-id>"
    # or build/reuse one from ACR:
    # $env:EXEC_ACR_IMAGE="acrXXXX.azurecr.io/openclaw-exec:tag"; $env:EXEC_IMAGE_DIGEST="sha256:..."
    python -m sandbox_mcp.selftest
"""

from __future__ import annotations

import os
import sys

from .factory import group_config_from_env, make_adapter, settings_from_env
from .interface import ExecRequest, SandboxSpec


def main() -> int:
    cfg = group_config_from_env()
    s = settings_from_env()
    adapter = make_adapter(cfg, s.driver)
    print(f"[selftest] driver={s.driver} group={cfg.group_name} region={cfg.region}")

    disk_id = os.environ.get("EXEC_DISK_ID")
    if not disk_id:
        if not s.acr_image or not s.image_digest:
            print("[selftest] set EXEC_DISK_ID, or EXEC_ACR_IMAGE + EXEC_IMAGE_DIGEST")
            return 2
        print(f"[selftest] ensure_disk_image({s.acr_image}, {s.image_digest[:20]}...)")
        disk_id = adapter.ensure_disk_image(s.acr_image, s.image_digest)
    print(f"[selftest] disk image: {disk_id}")

    spec = SandboxSpec(
        role="selftest",
        env={"OPENCLAW_SELFTEST": "1"},
        identity_client_id=s.worker_identity_client_id or None,
        egress_allow_hosts=[],
        egress_default_deny=False,  # don't lock egress for the smoke test
        labels={"purpose": "selftest"},
    )

    print("[selftest] booting sandbox from disk image...")
    handle = adapter.boot_from_disk_image(disk_id, spec)
    print(f"[selftest] sandbox: {handle.sandbox_id}")
    try:
        adapter.specialize(handle, spec)
        # cold boot needs the runtime to settle
        for _ in range(15):
            probe = adapter.exec(handle, ExecRequest(command="true", timeout_s=10))
            if probe.exit_code == 0 and not probe.timed_out:
                break
        res = adapter.exec(
            handle,
            ExecRequest(
                command="echo \"hello from $(hostname)\"; echo \"role=$OPENCLAW_SELFTEST\"; uname -sm",
                timeout_s=30,
            ),
        )
        print("[selftest] --- exec result ---")
        print(f"  exit_code = {res.exit_code}  duration={res.duration_s}s  timed_out={res.timed_out}")
        print("  output:")
        for line in res.stdout.splitlines():
            print(f"    {line}")
        ok = res.exit_code == 0 and "hello from" in res.stdout
        print(f"[selftest] {'PASS' if ok else 'FAIL'}")
        return 0 if ok else 1
    finally:
        print("[selftest] destroying sandbox...")
        adapter.destroy(handle)


if __name__ == "__main__":
    sys.exit(main())
