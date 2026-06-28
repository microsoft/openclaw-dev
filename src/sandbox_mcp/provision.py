"""Execution-image provisioning (Phase 2).

Builds the execution-environment image into ACR, converts it to a sandbox disk
image (hash-gated on the image digest), and creates the warm snapshot. Emits
the resulting ids as `KEY=VALUE` lines for the azd post-provision hook to
persist, so the MCP server can pick them up via EXEC_* env.

Reuses the validated adapter (`ensure_disk_image`, `create_warm_snapshot`) so
there is exactly one implementation of the preview-sensitive operations.

Run from `src`:  python -m sandbox_mcp.provision
Required env: AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, AZURE_SANDBOX_GROUP_NAME,
AZURE_LOCATION, AZURE_CONTAINER_REGISTRY_NAME.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from .factory import group_config_from_env, make_adapter, settings_from_env
from .interface import SandboxError, WarmupSpec
from .pool import _warmup_commands


def _run(argv: list[str], timeout: int = 1800) -> str:
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise SandboxError(f"{argv[0]} failed ({proc.returncode}): {(proc.stderr or proc.stdout)[:400]}")
    return proc.stdout


def main() -> int:
    az = shutil.which("az") or "az"
    cfg = group_config_from_env()
    s = settings_from_env()

    acr_name = os.environ.get("AZURE_CONTAINER_REGISTRY_NAME")
    if not acr_name:
        print("[provision] AZURE_CONTAINER_REGISTRY_NAME not set", file=sys.stderr)
        return 2
    repo = os.environ.get("EXEC_IMAGE_REPO", "openclaw-exec")
    tag = os.environ.get("EXEC_IMAGE_TAG", f"v{int(time.time())}")
    install_browser = os.environ.get("EXEC_INSTALL_BROWSER", "false")
    src_dir = Path(__file__).resolve().parent.parent  # src/
    dockerfile = src_dir / "execution-env" / "Dockerfile"

    image = f"{repo}:{tag}"
    print(f"[provision] building {image} into {acr_name} (browser={install_browser})...", file=sys.stderr)
    _run([
        az, "acr", "build", "--registry", acr_name, "--image", image,
        "--build-arg", f"INSTALL_BROWSER={install_browser}",
        "--file", str(dockerfile), str(src_dir / "execution-env"),
    ])

    digest = _run([
        az, "acr", "repository", "show", "--name", acr_name,
        "--image", image, "--query", "digest", "-o", "tsv",
    ]).strip()
    if not digest:
        print("[provision] could not resolve image digest", file=sys.stderr)
        return 1
    acr_login = _run([az, "acr", "show", "-n", acr_name, "--query", "loginServer", "-o", "tsv"]).strip()
    image_ref = f"{acr_login}/{image}"
    print(f"[provision] image={image_ref} digest={digest}", file=sys.stderr)

    adapter = make_adapter(cfg, s.driver)
    print("[provision] ensure_disk_image (hash-gated)...", file=sys.stderr)
    disk_id = adapter.ensure_disk_image(image_ref, digest)
    print(f"[provision] disk image: {disk_id}", file=sys.stderr)

    snapshot = ""
    if s.startup == "snapshot":
        print("[provision] create_warm_snapshot...", file=sys.stderr)
        try:
            warm = WarmupSpec(commands=_warmup_commands(s), boot_env={})
            snapshot = adapter.create_warm_snapshot(disk_id, warm)
            print(f"[provision] warm snapshot: {snapshot}", file=sys.stderr)
        except SandboxError as exc:
            print(f"[provision] snapshot unavailable, disk-image fallback: {exc}", file=sys.stderr)

    # Machine-readable outputs for the hook to persist into the azd env.
    print(f"EXEC_ACR_IMAGE={image_ref}")
    print(f"EXEC_IMAGE_DIGEST={digest}")
    print(f"EXEC_DISK_ID={disk_id}")
    print(f"EXEC_SNAPSHOT={snapshot}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
