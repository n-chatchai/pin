# ปิ่น — E2EE Mobile Agent Architecture

ย้าย agent จาก server-side bot → **on-device (Dart) brain**. tokens2 หยุดเป็น
Matrix device ที่ถือ plaintext history. server เหลือบทบาท **blind**: LLM proxy
(เฉพาะ free), tool APIs (ข้อมูลขั้นต่ำ), push wake. privacy แบ่ง tier.

---

## 1. หลักการ (north star)

> **tool API + (free) LLM proxy ได้รับเฉพาะข้อมูลขั้นต่ำที่จำเป็น —
> ห้ามส่ง identity, raw conversation, หรือ preferences ออกจากเครื่อง.**

state ทั้งหมด (history/facts/knowledge/prefs) อยู่ **on-device, encrypted**.
phone เป็นเจ้าของ orchestration + memory; server แค่ทำงานไร้บริบท.

---

## 2. ส่วนประกอบ + ที่อยู่

```
┌─ Phone (Dart brain) ───────────────────────────────────┐
│ • on-device state (sqlite + vector, E2EE at rest)       │
│ • orchestration loop + subagents + tool dispatch        │
│ • Matrix client (decrypt/encrypt — เหมือนเดิม)          │
│                                                          │
│   prompt (มี context) ─┐         tool args (ขั้นต่ำ) ─┐  │
└────────────────────────┼──────────────────────────────┼──┘
                         ▼                               ▼
        ┌─ LLM proxy ─────────────┐      ┌─ Tool APIs (we host) ─────┐
        │ FREE: ของเรา → Gemini   │      │ stateless, ข้อมูลขั้นต่ำ:   │
        │   (เราเห็น prompt)       │      │  web_search(query)        │
        │ PAID: OpenRouter/BYO    │      │  get_weather(place)       │
        │   (เราตาบอด)            │      │  get_currency(base,quote) │
        │ key อยู่ server ไม่ในแอป │      │  (ไม่มี PII/convo/prefs)   │
        └─────────────────────────┘      └───────────────────────────┘

        ┌─ Push/scheduler (blind) ─┐
        │ เก็บ {device, job_id,    │  ถึงเวลา → APNs ปลุก phone
        │  time} ไม่มี content      │  → Dart brain รัน job → ส่ง Matrix
        └──────────────────────────┘
```

---

## 3. Privacy ต่อ tier

| | Free | Paid |
|---|---|---|
| **LLM** | proxy ของเรา → Gemini (เราเห็น prompt) | **OpenRouter / BYO** (เราตาบอด, ลูกค้าเชื่อ third-party กลาง) |
| **Tool APIs** | ของเรา, args ขั้นต่ำ (ไม่มี PII) | เหมือนกัน |
| **State/memory** | on-device E2EE | on-device E2EE |
| **tokens2 เห็นอะไร** | prompt ตอน infer (ชั่วขณะ ไม่ store) | แทบไม่เห็นเลย |

LLM proxy = pluggable provider: `{free: gemini-via-us, paid: openrouter}`. key
อยู่ server เสมอ → ไม่ฝังในแอป.

---

## 4. Tool placement (PII gate)

| Tool | ที่อยู่ | เหตุผล |
|---|---|---|
| render_html, show_card | **on-device** | output ล้วน |
| tasks / events / jobs (add/list/complete) | **on-device** | แตะ state ผู้ใช้ |
| remember_fact / recall_knowledge / save_knowledge | **on-device** (sqlite+vector, E2EE) | memory = PII |
| request_location | **on-device** | ขอ GPS |
| **web_search** | **remote API** | arg = query เท่านั้น |
| **get_weather** | **remote API** | arg = place |
| **get_currency** | **remote API** | arg = base/quote |
| subagent (researcher) | **on-device orchestration** (เรียก LLM proxy + tool API) | task อาจมีบริบท → คุมบนเครื่อง |

กฎ: tool ที่ต้องเห็น state/PII = อยู่บนเครื่อง. tool ที่รับ arg ไม่ระบุตัวตน =
remote API ของเราได้.

---

## 5. Scheduler / agentic jobs (push-wake)

- phone register job → server เก็บ **metadata เปล่า** {device token, job_id, next_due, repeat} (ไม่มี prompt/content)
- ถึงเวลา → server ส่ง **APNs silent/notif push** ปลุก phone
- phone wake → Dart brain โหลด job context (on-device) → รัน (LLM proxy + tools) → ส่งผลผ่าน Matrix E2EE
- **ข้อจำกัด iOS background ~30s**: job เบาทำได้; job ซับซ้อน → fallback เด้ง noti ให้เปิดแอป
- ไม่มี content บน server → ตรงข้ามกับ RQ-worker เดิมที่รัน Brain server-side

---

## 6. Reuse vs ใหม่ (จากของที่ทำแล้ว)

| ของเดิม (Python, server) | ชะตา |
|---|---|
| modular `tools/builtin` (network tools: web/weather/currency) | → **wrap เป็น HTTP API** (stateless) reuse logic |
| modular `tools/builtin` (state tools: tasks/facts/knowledge) | → **reimplement Dart on-device** |
| `subagents/` runner | → reimplement Dart orchestration |
| Postgres+pgvector (memory) | → **on-device sqlite + vector** (server เลิกถือ memory) |
| RQ worker (server agentic) | → **push-wake on-device** |
| bot.py Matrix device | → **เลิก** (phone เป็น client เดียว); server ไม่ join/decrypt |
| Brain reply loop | → **port เป็น Dart** |
| LLM call | → **LLM proxy service (ใหม่)** + provider plug (gemini/openrouter) |

ส่วน server-side ที่เพิ่งทำ (Postgres/RQ/bot device) ถูกแทนเป็นใหญ่ — แต่ tool
logic + การออกแบบ contract (Reply, ToolSpec, registry) ยังเป็นแม่แบบให้ Dart.

---

## 7. ลำดับสร้าง (slices)

| Slice | ทำ | ทดสอบได้ |
|---|---|---|
| **1. LLM proxy** | service: phone→/infer (auth)→provider (gemini free / openrouter paid). key server-side. ไม่ store | curl /infer |
| **2. Dart brain MVP** | reply loop ใน Dart เรียก proxy; tool dispatch (เริ่ม local tools) | คุยในแอปไม่พึ่ง bot |
| **3. On-device state** | sqlite + vector (facts/knowledge/history/prefs) E2EE | memory ข้าม session |
| **4. Tool APIs** | host web_search/weather/currency (minimal-arg) | Dart เรียก |
| **5. Push scheduler** | server blind metadata + APNs wake → Dart job | 8โมงรายงานข่าว |
| **6. ปลด server bot** | เลิก Matrix bot device + RQ + Postgres memory | server ตาบอดจริง |

---

## 8. ข้อควรระวัง

- **prompt ตอน free tier มี context** (history/prefs) → proxy เราเห็น. ยอมรับสำหรับ free; paid → openrouter blind.
- **tool args ต้อง sanitize**: Dart brain ห้ามใส่ชื่อ/บริบท/prefs ลง args ที่ส่ง tool API. ตรวจที่ชั้น dispatch.
- **OpenRouter key**: paid = ลูกค้าใส่เอง (BYO) หรือเราออก sub-key ต่อ user.
- **iOS background**: push-woken job มีงบเวลาจำกัด — ออกแบบ job ให้ atomic/สั้น.
- **on-device vector**: sqlite-vss หรือ objectbox/local cosine — เลือกตาม Flutter support.
- ของเดิม (server bot, Postgres, RQ) ยังรันได้ระหว่าง migrate — ปลดทีหลัง (slice 6).
