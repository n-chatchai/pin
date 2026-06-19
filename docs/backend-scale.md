# ปิ่น Backend — Scale Architecture (PostgreSQL + Redis/RQ)

แทน in-process JSON + asyncio scheduler → **Postgres** (state) + **Redis/RQ**
(durable job queue). รองรับ user หลายคน, durable, catch-up, scale แนวนอน.

---

## 1. แยกหน้าที่ 3 process

```
┌──────────────────┐   Matrix E2EE (sync/send)   ┌──────────┐
│  pin-bot (I/O)   │◄───────────────────────────►│  users   │
│  - Matrix client │                             └──────────┘
│  - E2EE olm/keys │  เขียน state / อ่าน
│  - consume       │────────────┐
│    "outbound" q  │            ▼
└────────┬─────────┘     ┌──────────────┐
         │ enqueue       │  PostgreSQL  │  rooms/facts/knowledge(pgvector)
 outbound│ (text→send)   │  + pgvector  │  tasks/events/history/jobs
         ▼               └──────▲───────┘
   ┌───────────┐  เขียน state   │  อ่าน/เขียน
   │   Redis   │◄───────────────┤
   │  - RQ q   │         ┌──────┴────────┐
   │  - outbnd │◄────────│  rq worker(s) │  รัน scheduled jobs:
   └───────────┘ enqueue │  + scheduler  │  - reminder → outbound text
                  result │               │  - agentic  → Brain(prompt)→outbound
                         └───────────────┘
```

**กุญแจสำคัญ — E2EE อยู่ที่ bot เท่านั้น:** worker เป็นคนละ process แชร์ olm/megolm
ไม่ได้. ดังนั้น worker ทำแต่ **compute** (LLM + DB) แล้ว **enqueue ข้อความ outbound**
กลับเข้า Redis; **bot** มี consumer ดึง outbound → encrypt+send ด้วย E2EE client ตัวเดียว.
→ 1 Matrix device, แยก compute/IO สะอาด, scale worker ได้.

---

## 2. PostgreSQL schema (per-room rows)

```sql
CREATE EXTENSION IF NOT EXISTS vector;          -- pgvector

CREATE TABLE rooms (
  room_id   TEXT PRIMARY KEY,
  prefs     JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE facts (
  id BIGSERIAL PRIMARY KEY,
  room_id TEXT REFERENCES rooms ON DELETE CASCADE,
  text TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX ON facts(room_id);

CREATE TABLE knowledge (
  id BIGSERIAL PRIMARY KEY,
  room_id TEXT REFERENCES rooms ON DELETE CASCADE,
  title TEXT, summary TEXT, content TEXT, source TEXT,
  embedding vector(256),                        -- gemini-embedding-001 256d
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX ON knowledge(room_id);
CREATE INDEX ON knowledge USING hnsw (embedding vector_cosine_ops);  -- ค้นในDB

CREATE TABLE tasks (
  id TEXT PRIMARY KEY, room_id TEXT REFERENCES rooms ON DELETE CASCADE,
  grp TEXT, text TEXT, due TEXT, done BOOL DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX ON tasks(room_id) WHERE NOT done;

CREATE TABLE events (                            -- section "วันนี้"
  id TEXT PRIMARY KEY, room_id TEXT REFERENCES rooms ON DELETE CASCADE,
  day DATE, time TEXT, title TEXT, remind BOOL DEFAULT false
);
CREATE INDEX ON events(room_id, day);

CREATE TABLE history (                           -- rolling chat transcript
  id BIGSERIAL PRIMARY KEY, room_id TEXT REFERENCES rooms ON DELETE CASCADE,
  role TEXT, parts JSONB, created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX ON history(room_id, id);            -- keep last N per room

CREATE TABLE jobs (                              -- section "ตั้งเวลา" + reminders
  id TEXT PRIMARY KEY, room_id TEXT REFERENCES rooms ON DELETE CASCADE,
  kind TEXT,                                     -- 'reminder' | 'agentic'
  time_spec TEXT, repeat TEXT,                   -- 'HH:MM' / 'cron' ; 'once'|'daily'
  payload TEXT,                                  -- reminder text OR agentic prompt
  next_due TIMESTAMPTZ, last_fired TIMESTAMPTZ,
  rq_job_id TEXT
);
CREATE INDEX ON jobs(room_id);
```

**pgvector win:** `recall_knowledge` cosine search ทำใน DB (`ORDER BY embedding <=>
$q LIMIT k`) แทน Python loop → เร็ว + ไม่โหลด knowledge ทุก row เข้า RAM.

**Encrypted-at-rest (ภายหลัง):** เก็บ text/summary/content เป็น ciphertext column;
embedding ยัง plaintext (เพื่อ search) — search ได้บน vector, decrypt text ตอน return.

---

## 3. Redis / RQ — durable scheduler

- **queues:** `default` (agentic+reminder jobs), `outbound` (text→Matrix send)
- **schedule one-shot:** `queue.enqueue_at(next_due, run_job, job_id)`
- **daily/recurring:** RQ 2.5 `Repeat` หรือ `rq cron` config; หรือ on-complete re-enqueue
  รอบถัดไป (เขียน `next_due` กลับ Postgres)
- **catch-up:** Redis ScheduledJobRegistry ยิง job ที่ due ผ่านไปแล้วตอน worker start
  → ไม่พลาดช่วง down (ต่างจาก asyncio เดิม)
- **retry:** `Retry(max=3)` ต่อ job
- **run:** `rq worker-pool -n 4 --with-scheduler` (systemd/tmux)

### worker job ตัวอย่าง
```python
def run_job(job_id):
    j = db.get_job(job_id)              # Postgres
    if j.kind == "reminder":
        text = f"⏰ {j.payload}"
    else:                               # agentic
        text = Brain(db).reply(j.room_id, j.payload)   # LLM + DB state
    redis.rpush("outbound", json.dumps({"room": j.room_id, "text": text}))
    db.mark_fired(job_id)               # last_fired, compute next_due if daily
```
bot process: `BRPOP outbound` → `client.room_send(room, text)` (E2EE).

---

## 4. Infra (VPS, root ครั้งเดียว)

```bash
# root
apt install -y postgresql redis-server
sudo -u postgres psql -c "CREATE DATABASE pin; CREATE USER pin ...;"
# pgvector: apt install postgresql-NN-pgvector  (หรือ build)
```
Python deps: `psycopg[binary]` + `sqlalchemy` (หรือ raw), `redis`, `rq`, `pgvector`.

---

## 5. Migration phases

| Phase | ทำ | ผล |
|---|---|---|
| **0** | ติดตั้ง Postgres+pgvector+Redis บน VPS (root) | infra พร้อม |
| **1** | `db.py` (Postgres layer) — rooms/facts/knowledge/tasks/events/history; พอร์ต `Brain` อ่าน/เขียน DB แทน JSON dict; pgvector search | state durable + concurrent-safe |
| **2** | one-time migrate JSON (`brain_state/tasks/events`) → Postgres | ไม่เสียข้อมูลเดิม |
| **3** | RQ: `jobs` table + worker + outbound queue; พอร์ต reminders → RQ; bot consume outbound | scheduler durable + catch-up |
| **4** | tools `add_event` / `schedule_job` (agentic) + app sections "วันนี้" / "ตั้งเวลา" | feature ที่ขอ |
| **5** | encrypted-at-rest columns; multi-worker; Matrix shard/AS เมื่อ user ทะลุพัน | scale จริง |

---

## 6. ข้อควรระวัง

- **E2EE = bot เท่านั้น.** worker ห้ามถือ Matrix device แยก → ผ่าน outbound queue
- **history ordering:** Gemini ต้อง valid sequence — เก็บ role/parts ใน Postgres, heal ตอนอ่าน (logic เดิม `_valid_for_gemini`)
- **idempotency:** job อาจรันซ้ำ (worker crash) → ใช้ `last_fired` กันยิงซ้ำในนาทีเดียว
- **TZ:** เก็บ `next_due` เป็น UTC (TIMESTAMPTZ), แปลง Asia/Bangkok ตอนแสดง/คำนวณ
- **secrets:** DB/Redis creds ใน `.env` (ไม่ commit), ไม่ทับ .env บน VPS
```
