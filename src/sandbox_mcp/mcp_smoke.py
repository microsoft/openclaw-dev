"""MCP client smoke test: launches server.py over stdio, lists tools, and calls
sandbox_run. Validates the full MCP path (the same one the OpenClaw Gateway
uses) end-to-end against a real sandbox.

Requires `mcp` installed and the AZURE_*/EXEC_DISK_ID env set (see selftest.py).
Run from the `src` directory:  python -m sandbox_mcp.mcp_smoke
"""

from __future__ import annotations

import json
import os
import sys

import anyio


async def _main() -> int:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "sandbox_mcp.server"],
        env=dict(os.environ),  # inherit PATH, az config, AZURE_*, EXEC_DISK_ID
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            print("[mcp] tools:", [t.name for t in tools.tools])

            print("[mcp] calling sandbox_run ...")
            res = await session.call_tool(
                "sandbox_run",
                {"command": "echo hi from $(hostname); python3 -c 'print(\"py\", 2+2)'; node -e 'console.log(\"node\", 2+2)'"},
            )
            text = "".join(getattr(c, "text", "") for c in res.content)
            print("[mcp] raw:", text)
            try:
                data = json.loads(text)
                ok = data.get("exit_code") == 0 and "hi from" in data.get("output", "")
                print(f"[mcp] exit_code={data.get('exit_code')} sandbox={data.get('sandbox_id')}")
                print(f"[mcp] {'PASS' if ok else 'FAIL'}")
                return 0 if ok else 1
            except json.JSONDecodeError:
                print("[mcp] FAIL (non-JSON result)")
                return 1


def main() -> int:
    return anyio.run(_main)


if __name__ == "__main__":
    sys.exit(main())
