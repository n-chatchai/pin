"""MCP at the proxy — front external MCP servers as blind, minimal-arg tools.

The device never speaks MCP and never holds the server's keys: it sees an
ordinary remote tool in the catalog and calls `/tool/{name}` with only the
declared args. We translate that to an MCP `tools/call` over Streamable HTTP.

Config (env `PIN_MCP_SERVERS`, JSON) — tools are *declared* here, not
auto-enumerated, so each one's `argKeys` allowlist is pinned on purpose (the
audit step). Example:

    [{"name":"notion","url":"https://notion.mcp.host/mcp",
      "headers":{"Authorization":"Bearer ..."},
      "tools":[{"name":"notion_search","description":"ค้นใน Notion",
                "parameters":{"type":"object","properties":{"query":{"type":"string"}}},
                "argKeys":["query"]}]}]

With no config, everything here no-ops (empty catalog, 404 on call).
"""

from __future__ import annotations

import json

import httpx

from . import store


def is_mcp(name: str) -> bool:
    return name in store.mcp_index()


async def call(name: str, args: dict) -> dict:
    """Run an MCP tool via Streamable HTTP JSON-RPC. Returns {"text": ...}."""
    entry = store.mcp_index().get(name)
    if entry is None:
        return {"text": f"ไม่พบเครื่องมือ MCP '{name}'"}
    srv = entry["server"]
    url = srv["url"]
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        **(srv.get("headers") or {}),
    }
    try:
        async with httpx.AsyncClient(timeout=30) as c:
            # 1) initialize → capture the session id the server may require.
            init = await _rpc(c, url, headers, 1, "initialize", {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "pin-proxy", "version": "1"},
            })
            sid = init["session"]
            if sid:
                headers["Mcp-Session-Id"] = sid
            # 2) tools/call (the actual invocation).
            res = await _rpc(c, url, headers, 2, "tools/call",
                             {"name": name, "arguments": args})
        result = res["data"].get("result", {})
        parts = result.get("content", [])
        text = "".join(p.get("text", "") for p in parts if p.get("type") == "text")
        return {"text": text.strip() or "(ไม่มีผลลัพธ์)"}
    except Exception as e:  # noqa: BLE001
        return {"text": f"เครื่องมือ MCP มีปัญหา: {e}"}


async def _rpc(c, url, headers, rid, method, params) -> dict:
    """One JSON-RPC call; returns {"data": parsed, "session": id|None}. Handles
    both a plain JSON body and an SSE (text/event-stream) response."""
    r = await c.post(url, headers=headers,
                     json={"jsonrpc": "2.0", "id": rid, "method": method,
                           "params": params})
    r.raise_for_status()
    session = r.headers.get("mcp-session-id")
    ctype = r.headers.get("content-type", "")
    if "text/event-stream" in ctype:
        data = {}
        for line in r.text.splitlines():
            if line.startswith("data:"):
                data = json.loads(line[5:].strip())
                break
    else:
        data = r.json()
    return {"data": data, "session": session}
