"""Scheduler store + due logic. No APNs creds → _push is a logged no-op, so this
runs offline. `pytest proxy/tests/test_scheduler.py`."""
import asyncio
import importlib

import pytest


@pytest.fixture()
def sched(tmp_path, monkeypatch):
    # Point the store at a temp file BEFORE import so module-level _STORE picks
    # it up, then reload to get a clean _jobs each test.
    monkeypatch.setenv("PIN_SCHED_STORE", str(tmp_path / "schedule.json"))
    from pin_proxy import scheduler as s
    importlib.reload(s)
    return s


def test_register_list_cancel_roundtrip(sched):
    sched.register("j1", "devA", 1000.0, "once")
    sched.register("j2", "devB", 2000.0, "daily")
    assert {j["job_id"] for j in sched.list_for("devA")} == {"j1"}
    assert sched.cancel("j1") is True
    assert sched.cancel("j1") is False  # already gone
    assert sched.list_for("devA") == []


def test_persistence_survives_reload(sched):
    sched.register("j1", "devA", 1000.0, "daily")
    sched._jobs.clear()  # simulate a fresh process
    sched._load()
    assert sched._jobs["j1"]["device"] == "devA"


def test_fire_due_pushes_and_rolls(sched, monkeypatch):
    pushed = []

    async def fake_push(device, jid, platform="apns"):
        pushed.append((device, jid))

    monkeypatch.setattr(sched, "_push", fake_push)
    sched.register("once", "devA", 100.0, "once")
    sched.register("daily", "devB", 100.0, "daily")
    sched.register("future", "devC", 10_000.0, "once")

    asyncio.run(sched._fire_due(now=1000.0))

    assert set(pushed) == {("devA", "once"), ("devB", "daily")}  # future not pushed
    assert "once" not in sched._jobs  # one-shot removed
    assert sched._jobs["daily"]["next_due"] == 100.0 + 86400  # daily rolled +24h
    assert sched._jobs["future"]["next_due"] == 10_000.0  # untouched


def test_fire_due_interval_rolls_by_its_cadence(sched, monkeypatch):
    pushed = []

    async def fake_push(device, jid, platform="apns"):
        pushed.append(jid)

    monkeypatch.setattr(sched, "_push", fake_push)
    sched.register("w", "devA", 100.0, "interval", interval_sec=7200.0)
    asyncio.run(sched._fire_due(now=1000.0))
    assert pushed == ["w"]
    assert sched._jobs["w"]["next_due"] == 100.0 + 7200  # rolled by interval, not 24h


def test_fire_due_daily_not_repushed_same_pass(sched, monkeypatch):
    pushed = []

    async def fake_push(device, jid, platform="apns"):
        pushed.append(jid)

    monkeypatch.setattr(sched, "_push", fake_push)
    sched.register("daily", "devB", 100.0, "daily")
    asyncio.run(sched._fire_due(now=1000.0))
    # After rolling +86400 it's no longer due at the same `now`.
    asyncio.run(sched._fire_due(now=1000.0))
    assert pushed == ["daily"]


async def _async_none():
    return None
