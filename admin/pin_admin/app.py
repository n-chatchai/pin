"""ปิ่น admin — standalone backoffice (catalog/skills/MCP/subagents + dev portal).

Shares the proxy's SQLite store (the admin-editable source of truth). Auth is
tuwunel (Matrix): owners listed in PIN_ADMIN_OWNERS get the full backoffice,
everyone else the developer portal. Run separately from the LLM proxy.
"""
from __future__ import annotations

import os

from dotenv import load_dotenv
from fastapi import FastAPI
from pin_proxy import store

from . import admin

load_dotenv()

app = FastAPI(title="pin-admin")
app.include_router(admin.router)
app.include_router(admin.dev_router)


@app.on_event("startup")
def _startup() -> None:
    store.init()  # idempotent; shared DB with the proxy


def run() -> None:
    import uvicorn
    uvicorn.run(app, host="0.0.0.0",
                port=int(os.environ.get("PIN_ADMIN_PORT", "8800")))
