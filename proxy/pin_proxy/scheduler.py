"""Blind push scheduler.

Stores ONLY wake metadata — {device_token, job_id, next_due, repeat} — never the
job's content (the prompt lives on the phone). At due time it sends an APNs
*background* push to wake the app; the on-device agent then runs the job and
delivers via Matrix. We never see what the job does.

APNs creds come from env (.p8 token-based auth); without them the poller logs
"would push" so the scheduling logic is testable before Apple creds exist.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from pathlib import Path

import httpx

log = logging.getLogger("pin-proxy")

_STORE = Path(os.environ.get("PIN_SCHED_STORE", "schedule.json"))
_jobs: dict[str, dict] = {}  # job_id -> {device, next_due, repeat}


def _load() -> None:
    global _jobs
    if _STORE.exists():
        try:
            _jobs = json.loads(_STORE.read_text())
        except Exception:  # noqa: BLE001
            _jobs = {}


def _save() -> None:
    _STORE.write_text(json.dumps(_jobs))


def register(job_id: str, device: str, next_due: float, repeat: str) -> None:
    _jobs[job_id] = {"device": device, "next_due": next_due, "repeat": repeat}
    _save()


def cancel(job_id: str) -> bool:
    ok = _jobs.pop(job_id, None) is not None
    if ok:
        _save()
    return ok


def list_for(device: str) -> list[dict]:
    return [
        {"job_id": jid, **j} for jid, j in _jobs.items() if j["device"] == device
    ]


# --- APNs -------------------------------------------------------------------
def _apns_jwt() -> str | None:
    key_path = os.environ.get("APNS_KEY_PATH")
    key_id = os.environ.get("APNS_KEY_ID")
    team_id = os.environ.get("APNS_TEAM_ID")
    if not (key_path and key_id and team_id and Path(key_path).exists()):
        return None
    import jwt  # PyJWT

    token = jwt.encode(
        {"iss": team_id, "iat": int(time.time())},
        Path(key_path).read_text(),
        algorithm="ES256",
        headers={"kid": key_id},
    )
    return token


async def _push(device: str, job_id: str) -> None:
    jwt_token = _apns_jwt()
    topic = os.environ.get("APNS_TOPIC", "io.tokens2.pin")
    host = (
        "api.sandbox.push.apple.com"
        if os.environ.get("APNS_ENV", "sandbox") == "sandbox"
        else "api.push.apple.com"
    )
    if not jwt_token:
        log.warning("[sched] would push job=%s device=%s (no APNs creds)",
                    job_id, device[:8])
        return
    payload = {"aps": {"content-available": 1}, "pin_job": job_id}
    async with httpx.AsyncClient(http2=True, timeout=10) as c:
        r = await c.post(
            f"https://{host}/3/device/{device}",
            headers={
                "authorization": f"bearer {jwt_token}",
                "apns-topic": topic,
                "apns-push-type": "background",
                "apns-priority": "5",
            },
            json=payload,
        )
    log.info("[sched] pushed job=%s status=%s", job_id, r.status_code)


async def poller() -> None:
    _load()
    log.info("[sched] poller started with %d job(s)", len(_jobs))
    while True:
        now = time.time()
        for jid, j in list(_jobs.items()):
            if j["next_due"] <= now:
                try:
                    await _push(j["device"], jid)
                except Exception:  # noqa: BLE001
                    log.exception("[sched] push failed %s", jid)
                if j["repeat"] == "daily":
                    j["next_due"] += 86400
                else:
                    _jobs.pop(jid, None)
                _save()
        await asyncio.sleep(30)
