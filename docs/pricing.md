# ปิ่น — Pricing Design (v2)

Status: design. Two tiers — **Free (by cap)** and **Premium (a bundle of the
costly/advanced services)**. Numbers are grounded in real unit cost (below);
final caps + the Premium price get tuned against a week of live usage.
Payment: web (PromptPay/LINE Pay) first, Apple/Google IAP later — entitlement is
server-side either way.

---

## 1. Real unit cost (the basis)

Model is **`gemini-flash-lite-latest`** everywhere on the free path (`/infer`,
`/transcribe`, `web_search`). FX ≈ ฿35/$.

| item | provider / price | **cost to us** |
|---|---|---|
| chat, 1 message (~6k in + 0.6k out incl. tool round-trip) | Gemini flash-lite $0.10/$0.40 per 1M | **฿0.03** |
| **web_search** — TODAY (Gemini Google-Search *grounding*) | **$35 / 1k requests** | **฿1.2** ← expensive |
| web_search — Brave Search API (planned) | ~$3–5 / 1k | **฿0.15** |
| web_search — Gemini 3.x grounding (alt) | $14/1k + 5k/mo free | ฿0.5 |
| transcribe, per minute audio | flash-lite tokens | ฿0.01 |
| image analyze, per image | ~1.3k tokens | ฿0.01 |
| **image gen (Pollinations, basic)** | free, no key | **฿0** |
| file summarize | tokens | ฿0.03 |
| embeddings | **on-device** | **฿0** |
| better photo (Flux/Imagen — premium, planned) | ~$0.003–0.01/img | ฿0.1–0.4 |
| **video generation (planned)** | ~$0.1–0.5/sec | **฿10–50/clip** ← priciest |
| big-file RAG (server embed, planned) | compute/tokens | moderate, by size |

**Key facts:**
- Chat, basic image gen, transcribe, embeddings, image-analyze = **pennies to
  free**. Free tier costs us almost nothing.
- The only costly things are **web_search** (fixable: Brave → 8× cheaper) and the
  **planned premium media** (better photo, video gen, big-file RAG).
- So the tier line = cheap-basics (free) vs costly/advanced-services (premium).

---

## 2. Two tiers

### Free — "by cap"
Generous on the cheap stuff, just capped to stop abuse. Costs us ~฿5–20/mo per
active user.

| | Free cap (per day) |
|---|---|
| chat (flash-lite) | ~30 |
| image gen (Pollinations, basic) | 3 |
| image analyze | 5 |
| transcribe (min) | 5 |
| file summarize (small files) | 3 |
| web_search | **off** (or 1–2/day taster) |
| BYOK · better photo · video · big-file RAG | ✗ |

### Premium — the premium-services bundle
Unlocks the costly/advanced services + lifts caps. Bundles Pin-hosted premium
capabilities (partner connectors stay à-la-carte).

| premium service | included | cost to us | built? |
|---|---|---|---|
| **web_search** | generous (e.g. 20/day) | ฿0.15 (Brave) | ✅ exists (swap grounding→Brave) |
| **BYOK** (choose any model) | unlimited | ฿0 (user's key) | ✅ exists |
| **better photo** (Flux/Imagen) | monthly quota | ฿0.1–0.4/img | ❌ build |
| **video generation** | **small quota** (+ top-up) | ฿10–50/clip | ❌ build |
| **big-file embedding / RAG** | by size/pages | moderate | ❌ build (on-device today = small files) |
| higher caps on all Free items | — | cheap | ✅ |
| premium connectors (Pin-hosted) | bundled | varies | partial |

**The cost driver in Premium = video gen.** It can't be unlimited at any sane
price → small included quota + **top-up** for heavy use. Everything else is cheap
(search via Brave, BYOK free, photo/RAG moderate).

---

## 3. Pricing

- **Free** — ฿0. Costs us ~฿5–20/mo/user (no search, no premium media).
- **Premium — ฿149–199/เดือน** (฿1,490–1,990/ปี). Anchored by the included
  video/photo quota (the real cost), not chat. Realistic premium cost to us
  ~฿80–150/mo → margin holds.
- **BYOK** is a Premium feature here (model choice), and it *also* takes the
  user's chat off our bill — a double win.
- Settle the exact number once `better photo` + `video` providers are picked
  (their per-unit price sets the included quota and the floor price).

### Top-up (one-time, THB) — for caps/quota overage
| pack | adds |
|---|---|
| +video N คลิป | ฿ (set to ~1.5× our clip cost) |
| +better-photo 20 รูป | ฿29 |
| +web_search 100 | ฿15 |
| +50 หน้าไฟล์ (RAG) | ฿19 |
| +100 ข้อความ | ฿15 |

Top-ups are the on-ramp ("topped up 3× → Premium is cheaper").

### Connector / capability subscriptions (already exists)
Each capability row carries `pricing_json {tier, amount THB, period}`, admin-
editable. Partner (MCP) connectors are à-la-carte even for Premium; partner gets
`revenue_share`. Pin-hosted premium capabilities are bundled into Premium.

---

## 4. How it's enforced (build)

At the **proxy** (already authenticates each request as a matrix user).

```
usage(user_id, day, kind, count)         -- kind ∈ chat|search|imagegen|photo|video|transcribe|file|rag
entitlement(user_id) -> {tier, caps, credits, capSubs}
credits(user_id, kind, remaining)        -- top-ups, consumed after the daily cap
subscriptions(user_id, plan, status, expires_at, source)
```

Per metered request: resolve `user_id` + `kind` → `used = usage[…]`,
`cap = tier_cap(kind) + credits` → if over, **429 `{error:"cap", kind, resetAt,
topup, byok}`**; else proceed + `usage++`. The app's 429 sheet offers
**[อัปเกรด] / [เติม] / [ใช้คีย์ตัวเอง]**. Entitlement is always read from the proxy
(`GET /me/entitlement`), never decided on-device.

---

## 5. Payment + entitlement

- **Phase A — web (PromptPay / LINE Pay).** Hosted checkout on the site →
  webhook writes `subscriptions`/`credits`/`cap_subs` for the matrix `user_id`.
  No store cut. iOS app can *show* status + "manage on web" but (per Apple) can't
  deep-link the purchase; selling happens on the website.
- **Phase B — Apple/Google IAP.** In-app purchase for Premium + top-up SKUs,
  receipt-validated server-side → same entitlement tables. 30% cut, unlocks
  in-app buying.

---

## 6. Roadmap
1. **Cut web_search cost**: swap Gemini grounding → **Brave Search API** (8×
   cheaper). Unblocks pricing.
2. **Spec final caps + Premium price** once `better photo` + `video` providers
   are chosen.
3. **Metering engine**: `usage` table + per-kind cap + 429.
4. **Entitlement**: `subscriptions`/`credits`/`cap_subs` + `GET /me/entitlement`;
   app reads tier + the BYOK/top-up escape on 429.
5. **Build the premium services**: better photo (Flux/Imagen), video gen, big-
   file embedding/RAG. Each adds a `kind` to the meter.
6. **Web checkout** (PromptPay/LINE) → webhook → entitlement.
7. **IAP** when the app ships to the stores.

## 7. Open decisions
- `better photo` + `video` + RAG providers (sets per-unit cost → quota + price).
- Final Premium price (฿149 vs ฿199) — driven by included video/photo quota.
- Credit consumption order (proposal: after the daily free cap).
- Partner revenue-share %.
- Launch promo / annual discount depth.
