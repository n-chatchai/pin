# ปิ่น — Business Model & Technical Solution

> Personal AI assistant (E2EE) ที่เปิดเป็น **marketplace/platform** ให้คนนอกมาขาย
> agent prompts, skills, MCP/function-calling tools และเช่า/ขาย assistants —
> เราเก็บ **commission** จากทุกธุรกรรมบนแพลตฟอร์ม.

---

## 1. Vision

ปิ่นไม่ใช่แค่ assistant ตัวเดียว แต่เป็น **runtime + marketplace** :
ผู้ใช้ได้ผู้ช่วยส่วนตัวที่ต่อ "ความสามารถ" ได้ไม่จำกัด, นักพัฒนา/ครีเอเตอร์ได้ช่องทางขาย
ความสามารถนั้น, เราเป็นตัวกลางที่หักค่าคอม.

เทียบเคียง: **App Store ของ "ความสามารถ AI"** — แต่หน่วยที่ขายคือ prompt / skill /
tool / ตัว assistant ทั้งตัว ไม่ใช่แอป.

---

## 2. Revenue Model

รายได้หลัก = **commission (take-rate)** จาก GMV บนแพลตฟอร์ม. ไม่ใช่ค่าซับสคริปชันเป็นหลัก
(ซับเป็นรายได้รอง/แพลนองค์กร).

### 2.1 สิ่งที่ซื้อขายได้ (catalog units)

| Unit | คืออะไร | โมเดลราคา | Take-rate (ตั้งต้น) |
|------|---------|-----------|---------------------|
| **Prompt / Persona** | ชุด system prompt + บุคลิก + few-shot | one-time / เช่ารายเดือน | 20–30% |
| **Skill** | ชุดคำสั่ง + workflow สำเร็จรูป (เช่น "สรุปบิล", "ตามหนี้") | one-time / sub | 20–30% |
| **MCP / Function tool** | external tool (API, DB, service) ผ่าน MCP/function-calling | per-call / sub | 15–25% + markup ต่อ call |
| **Assistant (เช่า/ขาย)** | assistant ทั้งตัว (prompt+skills+tools bundle) พร้อมใช้ | เช่ารายเดือน / ขายขาด | 25–35% |

### 2.2 รายได้เสริม

- **Usage markup** — บวกส่วนต่างบน token/compute ที่ paid tool เรียกใช้.
- **Featured / ranking** — ครีเอเตอร์จ่ายเพื่อ promote ใน discovery (CPC/CPM).
- **Pro subscription** — ผู้ใช้รายเดือน: limit สูงขึ้น, private tools, team.
- **Enterprise** — private marketplace + SSO + audit (ขาย seat).
- **Verification/cert fee** — ค่าตรวจ + badge "verified safe" ให้ creator.

### 2.3 ทำไม commission ก่อน

- align กับ growth: เราโตเมื่อ creator + user โต.
- เข้าตลาดง่ายกว่า paywall — ผู้ใช้ลองฟรี, จ่ายเมื่อเห็นค่า.
- two-sided network effect: ยิ่ง creator เยอะ → catalog ดี → user เยอะ → creator อยากเข้า.

---

## 3. Two-Sided Marketplace

```
   Creators                Platform (ปิ่น)               Users
 ────────────         ──────────────────────────      ───────────
 prompt/skill   ──►   listing · review · sandbox  ◄──  ค้นหา/ลอง
 mcp tool       ──►   billing · revenue-share     ◄──  ติดตั้ง/เช่า
 assistant      ──►   trust/verify · discovery    ◄──  ใช้ในแชต
        ▲                      │ commission                │
        └────────── payout (after take-rate) ◄────────────┘
```

- **Supply:** dev/creator publish unit → review/sandbox → live.
- **Demand:** user browse/try → install/rent → ใช้ใน DM กับปิ่นได้ทันที.
- **Platform:** หัก commission, จัดการ payout, trust & safety, discovery.

---

## 4. Technical Solution (short)

ต่อยอดจาก stack ปัจจุบัน (ไม่รื้อ): **Flutter app + Matrix E2EE + Python bot (Gemini
function-calling)**. เพิ่ม **marketplace layer** 3 ส่วน: Registry, Runtime/Sandbox, Billing.

### 4.1 Architecture

```
┌──────────────┐   E2EE (Matrix)   ┌─────────────────────────────┐
│ Flutter app  │◄─────────────────►│ ปิ่น Bot Runtime (per user) │
│ (client)     │                   │  Gemini + function-calling  │
└──────────────┘                   │  loads installed units ─────┼──┐
        │ browse/install                                          │  │
        ▼                                                         ▼  │
┌─────────────────────────┐   ┌──────────────────┐   ┌──────────────▼─┐
│ Marketplace API         │   │ Unit Registry    │   │ Tool Sandbox   │
│ search·listing·reviews  │◄─►│ versioned pkgs   │   │ MCP exec (iso) │
└─────────────────────────┘   │ signed manifests │   │ rate-limit·log │
        │                     └──────────────────┘   └────────────────┘
        ▼
┌─────────────────────────┐   ┌──────────────────┐
│ Billing & Revenue-share │◄─►│ Payments (Stripe)│  payout − take-rate
│ usage metering·ledger   │   │ + payout (KYC)   │
└─────────────────────────┘   └──────────────────┘
```

### 4.2 Unit package format

ทุก unit = manifest + payload, **versioned + signed**:

```jsonc
{
  "id": "salesdee.invoice-summarize",
  "type": "skill",            // prompt | skill | tool | assistant
  "version": "1.2.0",
  "price": { "model": "sub", "amount": 99, "currency": "THB", "period": "month" },
  "permissions": ["net:api.salesdee.com", "read:invoices"],
  "entry": "prompt.md | mcp://endpoint | function-schema.json",
  "creator": "did:pin:abc123",
  "signature": "..."          // ป้องกัน tamper, verify ก่อน run
}
```

- **prompt/skill** = data (md + few-shot) → inject เข้า system/context.
- **tool** = MCP server URL หรือ function-call schema → bot โหลดเป็น tool declaration.
- **assistant** = bundle (prompt + skills + tools) อ้างถึง unit อื่น.

### 4.3 Runtime / isolation

- bot runtime ต่อ user โหลดเฉพาะ unit ที่ user "ติดตั้ง/เช่า".
- **paid tool run ใน sandbox** (network egress allow-list ตาม `permissions`, time/CPU/rate cap, ทุก call log เพื่อ metering + audit).
- function-calling: paid units = แค่ tool declarations เพิ่มเข้า Gemini config — เข้ากับสถาปัตยกรรม `_run_tool` ที่มีอยู่.
- **privacy:** prompt/skill เป็น metadata, ประมวลฝั่ง bot ที่ user trust; external tool เห็นเฉพาะ payload ที่จำเป็น (ผู้ใช้ consent ต่อ permission).

### 4.4 Billing & revenue-share

- **metering:** ทุก install/rent/per-call เขียน ledger (append-only).
- **commission:** หัก take-rate ตอน settle → payout creator ผ่าน Stripe Connect (KYC).
- **entitlement check:** ก่อนโหลด unit → ตรวจ subscription/credit ยังactive.

### 4.5 Trust & Safety

- review + automated scan (prompt-injection, data-exfil, malicious egress) ก่อน publish.
- signed manifest + permission prompt ฝั่ง user.
- rating/report + kill-switch ถอน unit ได้ทันที.
- "verified" badge (เสียค่า cert) สำหรับ creator ที่ผ่านตรวจเข้ม.

---

## 5. Roadmap

| Phase | ส่ง | เป้า |
|-------|-----|------|
| **0 — core (done/now)** | app + E2EE + bot + function-calling | assistant ใช้ได้จริง |
| **1 — installable units** | ติดตั้ง prompt/skill จาก catalog ภายใน | supply seed (เราทำ unit เอง) |
| **2 — marketplace** | publish flow + review + billing + payout | เปิดให้ creator นอก |
| **3 — paid tools (MCP)** | sandbox + per-call metering + markup | รายได้ usage |
| **4 — rent/sell assistants** | bundle + entitlement + featured | GMV scale + ads |

---

## 6. KPIs

- **GMV** (มูลค่าธุรกรรมรวม) → ฐานคิด commission.
- **Take-rate realized %** (หลัง discount/payout).
- **Active units · active creators** (supply health).
- **Install→paid conversion**, **retention** (demand health).
- **Rev per active user (ARPU)** = sub + usage markup + commission.
