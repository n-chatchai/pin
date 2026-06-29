---
target: site/index.html
total_score: 29
p0_count: 1
p1_count: 1
timestamp: 2026-06-26T11-03-22Z
slug: site-index-html
---
# Critique #3 — ปิ่น Landing (`site/index.html`) — Pi.ai redesign

Register: brand (Thai consumer pre-launch). Critiques the new warm-serif Pi.ai-structured rebuild.

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of Status | 3 | Waitlist ok/err states; no submit-loading, no active-nav |
| 2 | Match Real World | 3 | Thai voice excellent; but hero logo is Latin "Pin", not "ปิ่น" |
| 3 | User Control & Freedom | 3 | Anchors/menu fine; waitlist success can't be undone |
| 4 | Consistency | 3 | "รับสิทธิ์ก่อนใคร" ×3 / "ดูวิธีใช้" / "เริ่มต้น" all → #join |
| 5 | Error Prevention | 3 | Email regex + inline error; no double-submit guard |
| 6 | Recognition > Recall | **2** | 5 cards = icon+label only, zero copy → user must guess what ปิ่น does |
| 7 | Flexibility & Efficiency | 3 | Single waitlist path; fine pre-launch |
| 8 | Aesthetic & Minimalist | **4** | Genuinely beautiful, cohesive type+color — strongest dimension |
| 9 | Error Recovery | 3 | One clear Thai error, but same string for any malformed email |
| 10 | Help & Docs | **2** | No FAQ/pricing/privacy page; "อ่านเพิ่ม" → /developers/ (dev page for consumers) |
| **Total** | | **29/40** | **Good — beautiful but under-informative** |

**Trend: 32 → 31 → 29.** The number fell as the design changed: aesthetic rose (H8 4), but the Pi.ai trim deleted the information layer (H6, H10 = 2). Not a craft regression — a *substance* regression.

## Anti-Patterns Verdict — clears first-order, fails second-order

First-order: NO slop. Warm blush + forest Trirong serif + photo cards read crafted, not template. The Thai serif sets correctly (vowels/tone marks clear the loops). Real token discipline.

Second-order: **"a Pi.ai clone with a different logo."** It's not inspired-by Pi — it's Pi's exact skeleton, and the source says so out loud (`/* = Pi's voice/app section */`, `/* = Pi's "Created by Inflection AI" */`). A director who knows hey.pi.ai spots the lift in 3 seconds. Pi earns minimalism by being famous + funded + "less is more" by design; ปิ่น is an unknown pre-launch Thai *privacy* app that must *argue* for itself — borrowing Pi's confidence without Pi's recognition reads as a costume. The warm Thai *copy* voice is ปิ่น's own; the *visual structure + brand identity* is Pi's.

**Detector:** 0 findings, exit 0 (clean — em-dash/dark-glow gone in the rebuild). One measured contrast FAIL below.

## What's Working
1. **Type & color craft** — Trirong Thai serif, forest-on-blush, disciplined tokens + tasteful shadows. Best version of this page yet; not AI-default.
2. **Low cognitive load / clear path** — no menu >4, one CTA repeated, no dark patterns. Never confused about *what to do*.
3. **Warm native Thai voice** — "ตั้งให้แล้วค่ะ", "จำคุณได้ทุกครั้ง", the chat-snippet demo. Human + consistent.

## Priority Issues

**[P0] The privacy differentiator is never actually argued.** ปิ่น's only moat (on-device + E2EE) = one 14.5px trust line + a restated sentence in the creator block. No privacy section, no "how it works," no proof, no contrast vs cloud assistants. Trimming to Pi.ai's structure (whose differentiator is *personality*, not privacy) deleted the one block ปิ่น most needs → a skeptic gets zero reason to believe "เปิดอ่านได้แค่คุณ". *Fix:* add ONE compact privacy block (cards→highlight) — 3 plain-Thai proof points (สมองทำงานบนเครื่อง / เข้ารหัสปลายทาง / ไม่ขายข้อมูล) + one line "ต่างจากแอป AI บนคลาวด์ยังไง". Minimal, but it must *exist*. *Cmd:* clarify → shape.

**[P1] Hero leads with a Latin "Pin" app-icon, not the "ปิ่น" brand.** The hero + nav mark reads "Pin" in Latin; the audience is Thai, the brand is ปิ่น. An app-icon-in-a-box reads as "app screenshot," less premium than a real wordmark, and the first thing the eye hits is the wrong alphabet. *Fix:* hero = icon + a large "ปิ่น" Trirong wordmark (or a proper Thai lockup); make the hero MORE brand-forward than the nav, not less. *Cmd:* typeset → bolder.

**[P2] The 5 photo cards do no informational work.** Image + icon + 1–3-word chip, no benefit copy; every photo is an empty desk/room with plants — no people, no phone, no product. The visual peak persuades nothing ("จัดการงาน" over a stock laptop = any productivity app). *Fix:* one benefit line per card ("จัดการงาน — สรุปอีเมล นัดประชุม ทวงงานให้") or images showing ปิ่น on a screen in-context. At least give each a verb. *Cmd:* clarify.

**[P2] Highlight block overloaded (7 stacked elements).** statement h2 + paragraph + trust-line + label + input + button + fine-print in one column → privacy line buried, waitlist competes with a feature paragraph. *Fix:* let this section be the waitlist climax (statement + form + fine-print); move the feature list + privacy line to earlier blocks. One section, one job. *Cmd:* distill → layout.

**[P2] hero-note fails AA contrast.** "เปิดตัวเร็ว ๆ นี้ · ใช้ฟรี ไม่มีโฆษณา" = `--ink3 #9A8F7E` on blush = **2.77:1** (B-measured), the only objective contrast fail. *Fix:* bump to ink2 (#6E6457, ~5:1) or darker. *Cmd:* colorize.

**[P3] Consumer "learn more" → developer page.** "อ่านเพิ่มเกี่ยวกับเรา" → /developers/; "ใช้ฟรี" claimed with no pricing/why-free backing. Also: waitlist mailto-fallback shows success even when nothing is captured server-side (launch risk). *Fix:* point to a consumer about/privacy page; add a "ฟรีจริงไหม" reassurance; wire a real waitlist endpoint before launch. *Cmd:* harden.

## Cognitive Load — fail ~2/8
Highlight right column = 7 stacked elements (the one overload); cards don't scan into meaning. Otherwise low load (nav 2 links, one CTA).

## Persona Red Flags
- **Riley (skeptic) — worst-served:** came for privacy, gets a 14px line + a dev-page link. Leaves *more* skeptical. The core audience is the one the page fails.
- **Jordan (first-timer):** beautiful but under-informed — 5 photos later still can't say what ปิ่น does or how it differs. Signs up on vibes or bounces.
- **Casey (mobile):** best-served structurally (no overflow, hamburger, card snap-scroll verified). Risk: the 7-element highlight column gets very tall on mobile, pushing the form far down.

## Minor
"Pin" Latin icon used 4× (reinforces the wordmark gap); highlight image is a hand + blank-screen phone (product's UI never shown anywhere); no submit loading/double-submit guard; smooth-scroll + reduced-motion hygiene solid.

## Questions to Consider
1. Strip the green and the word "ปิ่น" — could anyone tell this from hey.pi.ai? If not, is "looks like the famous private-AI brand" an asset or an admission?
2. Your reason to exist is privacy — so why infer it from a 14px line while five plant photos own the middle of the page?
3. Brand is ปิ่น, audience is Thai — why is the first thing every visitor sees a logo that says "Pin" in English?
