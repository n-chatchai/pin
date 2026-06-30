# Watcher Architecture

ปิ่น "เฝ้าติดตาม" หัวข้อที่ผู้ใช้สนใจ → เช็คเป็นรอบ → เด้งเฉพาะตอนมีอะไรใหม่จริง.
เอกสารนี้ = สภาพปัจจุบัน + แผน adaptive polling.

---

## 1. Current architecture

### Data model

**Watch list** — `io.tokens2.watches` (Matrix room state บน pin room, single source ตาม
[rule-no-local-state]). 1 entry/watch:

| field | type | meaning |
|---|---|---|
| `id` | string | ms-epoch ตอนสร้าง (unique) |
| `topic` | string | เรื่องที่เฝ้า เช่น "ราคา BTC" |
| `last_seen` | string | สรุป finding ล่าสุด ('' = ยังไม่เจอ) |
| `last_seen_at` | int | ms-epoch ของ finding ล่าสุด (0 = never) |
| `has_new` | bool | ผู้ใช้ยังไม่อ่าน finding |
| `created` | int | ms-epoch ตอนสร้าง |

**Checker job** — paired agentic reminder, `id == watch id`. เก็บใน `io.tokens2.reminders`
(**room state** — `AgentStore` เป็นแค่ wrapper ที่ load/save ผ่าน room, ไม่ใช่ local):
`{id, text:_watchPrompt, kind:"agentic", ...}` + ฟิลด์ cadence:
- daily ตายตัว: `time:"HH:MM", repeat:"daily"`
- interval (adaptive): `interval_sec, repeat:"interval", at` ← **Phase 1 เพิ่ม**

**Server wake registry** — `scheduler._jobs[id] = {device, next_due, repeat, platform}`.
server ไม่รู้เนื้องาน (E2EE) — เก็บแค่ "ปลุกเครื่องไหน เมื่อไหร่".

### Wake paths (server = WAKER, ทุกงานรันบนเครื่อง — [server-push-trigger-only])

| platform | path | code |
|---|---|---|
| iOS | APNs background push (`content-available:1`) | `scheduler._push` |
| Android | FCM data message → `fcmBackgroundHandler` (closed) / `onMessage` (open) | `scheduler._push_fcm` + `push_service.dart` |
| Android | AlarmManager — on-device, **ไม่ง้อ server/FCM** | `android_job_alarm.dart` |
| ทุก platform | app open/resume → `runDueAgenticJobs` | `agentic_job_service.dart` |

> เมมเก่า [server-push-trigger-only] ว่า "Android FCM = ช่องว่าง" **stale** — FCM v1
> (`_push_fcm`, project `pin-ai-b9d8a`) + AlarmManager มีครบแล้ว.

### Server scheduler loop (`scheduler.py:poller`)
- poll ทุก 30s → `_fire_due(now)`
- job ถึงเวลา (`next_due <= now`) → `_push(device, id, platform)`
- `repeat=="daily"` → `next_due += 86400` (ตายตัว 24 ชม.)
- one-shot → drop

### Job run (on-device, `_watchPrompt` — now_tools.dart:114)
1. `web_search "<topic> ล่าสุด"` — ผลค้นรอบนี้
2. `recall_knowledge "watch <topic>"` — รู้อะไรไปแล้วรอบก่อน
3. LLM **อ่านเทียบเอง** ใหม่/ซ้ำ:
   - ใหม่ → `update_watch(id, finding)` + `save_knowledge` + เด้งแชต
   - ซ้ำ → ตอบว่าง → runner ทิ้ง → **เงียบ**

> "ไม่มี update" = LLM เทียบข้อความ 2 ก้อน ไม่ใช่ ground truth.

### Lifecycle

```
add_watch ─► [CAPTURE]  เขียน watch + paired daily job + arm wake (server+alarm)
              │
              ▼ (daily @ 09:00 หรือ time ที่ตั้ง)
           [POLL]  web_search → recall → LLM compare
              │
        ┌─────┴─────┐
        ▼           ▼
   [NOTIFY]      (silent)   ← ไม่มี state write
  update_watch    จบงาน
  has_new=true
        │
        ▼
   [READ] ผู้ใช้เปิด drawer "ตอนนี้" → markAllSeen → has_new=false
        │
        ▼
remove_watch ─► [CLEANUP] ลบ watch + cancel job + cancel wake + cancel alarm
```

### Tools (now_tools.dart)
- `add_watch(topic, time?)` — สร้าง. time ดีฟอลต์ 09:00
- `update_watch(id, finding)` — เรียกโดย checker job ตอนเจอใหม่
- `remove_watch(id|topic)` — เลิกเฝ้า

---

## 2. Known issues / limitations (current)

1. ~~ความถี่ตายตัว~~ — **แก้แล้ว Phase 1**: LLM เลือก tier (realtime…idle) ตอนสร้าง.
2. **"ไม่มี update" ไม่แม่น** — LLM เทียบ text → เสี่ยง false-new (เด้งซ้ำ) + false-silent (พลาด). (Phase 3)
3. ~~Silent path ไม่เขียน state~~ — **แก้แล้ว Phase 2**: runner ใช้ `hasReply` ตัดสิน backoff เอง (ไม่ต้องให้ silent path เขียน).
4. ~~Job อยู่ใน local~~ — **ไม่จริง**: reminders ride `io.tokens2.reminders` room state แล้ว.
5. ~~Server รองรับแค่ daily/once~~ — **แก้แล้ว Phase 1**: roll ตาม `interval_sec` ถ้ามี.
6. **Android wake เสี่ยงหน่วง** — Doze/battery-opt เลื่อน AlarmManager; FCM ต้อง `FCM_SA_PATH` ตั้ง + release ผ่าน R8.

---

## 3. TODO — Adaptive polling

### เป้า UX
ผู้ใช้ไม่ตั้งค่าอะไร. ปิ่นจัดจังหวะเอง — เรื่องขยับบ่อยตามใกล้, เรื่องนิ่งถอยห่าง.
ไม่โชว์คำว่า interval/polling ในแชต. คำสั่งผู้ใช้ ("ทุกเช้า"/"ไม่ต้องรีบ") ทับระบบเดาเสมอ.

### Phase 1 — LLM-judged tier ตอนสร้าง ✅ DONE

implement แล้ว (additive `interval_sec`; watch ที่ไม่มี = daily เดิม ไม่กระทบ):
- `add_watch` +param `interval` enum + `_watchTierSec` map [now_tools.dart]
- watch struct +`interval` [now_controllers.dart]; job +`interval_sec`/`repeat:"interval"`
- due/alarm logic +interval branch [job_runner.dart] + lastRun stamp [agentic_job_service.dart]
- server roll ตาม `interval_sec` [scheduler.py] + endpoint [main.py]; `scheduleRegister` +`intervalSec` [proxy_client.dart]
- tests: job_runner_test.dart (interval due/alarm), test_scheduler.py (interval roll) — เขียว

ดีไซน์เดิม:

LLM เลือก tier จากธรรมชาติคำขอ ณ `add_watch` — ไม่มี logic แยก, judge เกิดในหัวโมเดล.

| tier | gap | เหมาะกับ |
|---|---|---|
| `realtime` | ~1-3 ชม. | ราคาเหรียญ/หุ้น, ผลสด, ภัยพิบัติกำลังเกิด |
| `hourly` | ~6 ชม. | ข่าวด่วนร้อน, ดราม่าพีค, ของลดเวลาจำกัด |
| `daily` | 1 วัน | ข่าวทั่วไป, ความเคลื่อนไหววงการ (**default**) |
| `weekly` | 7 วัน | เทรนด์, ของใหม่ยี่ห้อ X, สถานะนาน ๆ ขยับ |
| `idle` | 30 วัน | "ไว้มีอะไรค่อยบอก", เรื่องแทบไม่ขยับ |

สัญญาณให้ LLM ตัดสิน: (1) คำบอกใบ้เวลาในประโยค (แรงสุด) (2) ชนิดหัวข้อ (3) ความเร่งด่วนที่สื่อ.

> tier = **เพดาน** ไม่ใช่นาฬิกา. บนมือถือรันจริงตอน wake/resume; tier บอก "อย่าเช็คถี่กว่านี้".
> realtime/hourly มีความหมายเต็มแค่ iOS APNs; Android อิง FCM+alarm (เสี่ยงหน่วง).

**Changes:**
- `add_watch` +param `interval: realtime|hourly|daily|weekly|idle` (default `daily`). tool desc สอนกฎ judge.
- watch struct +`interval` field (เก็บใน `io.tokens2.watches`).
- map tier → seconds → `next_due` ตอน `scheduleRegister`.
- **server scheduler** — รองรับ roll แปรผัน: เพิ่ม `interval_sec` ใน `_jobs`, เปลี่ยน
  `next_due += 86400` → `next_due += interval_sec` (job ที่ไม่มี = คง 86400, backward-compat).

### Phase 2 — Adaptive backoff ✅ DONE

เจอบ่อย→snap floor, เงียบ→×2 (cap 8×floor). AIMD.

**กุญแจ: runner ตัดสินเอง ไม่พึ่ง LLM.** runner รู้ `hasReply` อยู่แล้ว (เจอ=ตอบ,
เงียบ=ว่าง) → deterministic. ตัด risk "LLM ลืมเรียก tool ตอนเงียบ" ที่กลัวไว้.

implement (device-only — ไม่แตะ server/proxy):
- `nextWatchInterval(currentSec, floorSec, foundNew)` pure fn [job_runner.dart]:
  foundNew→floor; silent→min(×2, floor×8)
- runner หลังรัน interval job: stamp lastRun + set `interval_sec = nextWatchInterval(...)` [agentic_job_service.dart] (`hasReply`→`foundNew`)
- `floor_sec` เก็บบน job ตอนสร้าง [now_tools.dart] = tier base, backoff อิงตัวนี้
- tests: nextWatchInterval (snap/double/cap) — เขียว

**ทำไมไม่ re-register server:** server เป็น waker หยาบ ปลุกที่ floor cadence เสมอ
(Phase 1 ตั้งไว้). พอ device ถอยห่าง → server ปลุกเกินจำเป็น แต่ `dueAgenticJobs`
gate ไว้ → wake เปล่า ไม่รัน. device คือ source of truth ของจังหวะจริง.
ceiling: backed-off ที่ 8× → server ปลุกฟรี 7 ครั้ง/รอบ (silent push ถูก ยอมได้);
ถ้าแพงค่อย re-register ตอน interval โต.

### Phase 3 — แม่นขึ้น ❌ ไม่ทำ (ตัดสินใจ 2026-06-30)

LLM เทียบพอแล้ว; ไม่ลงทุน fingerprint จนกว่า false-new/silent จะกวนจริง.
เก็บไว้เป็น backlog เผื่ออนาคต:
- fingerprint set URL ผลค้น → "ไม่มี update" เป็นของจริง ไม่ต้องให้ LLM เดา.
- published-date เทียบ `last_seen_at` → กรอง false-new.
- watch ชนิด "ตัวเลข" (ราคา/อากาศ) → ดึง API เทียบเลขตรง แทน web_search.

### งานล้าง (ควรทำคู่ adaptive)
- ย้าย checker job ออกจาก AgentStore (local) → room/account-data — ปิด issue #4.
- อัปเดต memory [server-push-trigger-only] + [watch-feature-and-pi-drawer] ให้ตรง (FCM+alarm ทำแล้ว).

---

## File map
| ส่วน | ไฟล์ |
|---|---|
| tools (add/update/remove) + watch prompt | `lib/agent/now_tools.dart` |
| watch struct + drawer state | `lib/agent/now_controllers.dart` |
| job runner (on-device) | `lib/agent/agentic_job_service.dart` |
| push/wake bridge | `lib/services/push_service.dart` |
| Android alarm | `lib/services/android_job_alarm.dart` |
| server scheduler + push | `proxy/pin_proxy/scheduler.py` |
| push register endpoint | `proxy/pin_proxy/main.py` |
| debug/diagnostic | `lib/screens/watcher_debug_screen.dart` |
