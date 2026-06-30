---
target: site/index.html
total_score: 34
p0_count: 0
p1_count: 0
timestamp: 2026-06-29T23-59-14Z
slug: site-index-html
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Nav scroll state, chip selected, form sending/ok/err, aria-live status. |
| 2 | Match System / Real World | 4 | Thai-native, ค่ะ particles, real use-cases + believable mockup. |
| 3 | User Control and Freedom | 3 | Smooth-scroll anchors, mobile menu closes on tap. No back-to-top (short page). |
| 4 | Consistency and Standards | 3 | Tokens everywhere, but nav CTA destination/label drift + missing error color. |
| 5 | Error Prevention | 4 | Required fields, honeypot, custom-input guard, double-submit disable. |
| 6 | Recognition Rather Than Recall | 4 | Labeled chips, icon+text, visible options, no memory load. |
| 7 | Flexibility and Efficiency | 3 | Chip carousel + dropdown both set the use; bridge syncs choice. |
| 8 | Aesthetic and Minimalist Design | 4 | Rich but controlled; real product demo carries it. |
| 9 | Error Recovery | 2 | Submit-fail message renders in muted ink, no error color — reads as normal text. |
| 10 | Help and Documentation | 3 | Privacy link present; landing page, self-explanatory. |
| **Total** | | **34/40** | **Good — upper band, a few sharp fixes from Excellent** |

## Anti-Patterns Verdict

**Does this look AI-generated? — No, clearly hand-shaped.** Committed Trirong/blush/forest identity, Thai-native voice, and a *real interactive product demo* (tap a use-case chip → the iPhone chat mockup swaps to that scenario, with branch-sales carousel + LINE OA reply). That interaction alone puts it well above template. No gradient text, no eyebrow-on-every-section, no identical icon-card grid (the 5 cards are photo+chip, not icon-heading-text slop).

**Deterministic scan:** `detect.mjs` → 1 finding: **dark-glow** at line 98. **False positive.** It matched the `.phone` iPhone-bezel mockup (`#0d0d0d` bezel + `box-shadow rgba(60,40,15,.22)`). That's a warm drop-shadow under a phone render on a *cream* page — the same `rgba(60,40,15)` shadow hue used in `--cardsh`/`--liftsh` site-wide — not "dark UI with colored glow." Dismissed.

**Visual overlays:** Not run — browser routes through gstack `/browse` only; page fully assessed from source.

## Overall Impression
This is the strongest surface in the project. The chip→phone demo is the centerpiece and it earns its space. The gaps are all small and mechanical: an error state that doesn't look like an error, JS-gated reveal that can ship blank, and a "start chatting" CTA that overpromises a pre-launch product. Fix those and it's a 37+.

## What's Working
- **The interactive demo.** `selectUC()` swapping the phone's chat card per use-case is concrete proof-of-product, not a feature list. Best thing on the page.
- **Brand identity.** Trirong serif + blush/forest, Thai voice with ค่ะ, consistent token system. Reads as one product with the app.
- **Responsive craft.** Cards → horizontal snap-carousel, chips → carousel, phone resizes, copy re-centers under 880px. Real breakpoint work, not reflow-and-pray.

## Priority Issues

- **[P2] Reveal animation gates content on JS.** `.rv{opacity:0}` and only `.in` (added by IntersectionObserver) restores it. JS-off, a failed script load, or a crawler that doesn't run IO → the use-case heading, card row, demo, and highlight body stay `opacity:0` = blank mid-page. There's a reduced-motion fallback but **no no-JS fallback.** This is the documented "don't gate visibility on a class-triggered transition" anti-pattern. **Fix:** add `<noscript><style>.rv{opacity:1;transform:none}</style></noscript>`, or start visible and let the observer only *add* motion. **Suggested command:** /impeccable harden
- **[P2] Error state has no error styling.** JS sets `statusEl.className='wl-status err'` on submit failure, but CSS defines only `.wl-status` (muted ink2) and `.wl-status.ok` (green). "ส่งไม่สำเร็จ ลองอีกครั้งนะคะ" therefore renders in the same muted color as neutral hints — a failed signup looks like a normal note. **Fix:** add `.wl-status.err{color:#C0492F;font-weight:600}` (reuse the existing red from `.brc-d.dn`). **Suggested command:** /impeccable polish
- **[P2] "เริ่มคุยกับปิ่น" overpromises + lands on the wrong section.** Nav CTA "เริ่มคุยกับปิ่น" (start chatting) and "เริ่มต้น" both target `#join` — the *demo* (a non-interactive mockup; compose bar is `aria-hidden`). There's no chat to start (pre-launch waitlist), and the real email form is `#cta`, a section further down. The hero already uses the honest "รับสิทธิ์ก่อนใคร". **Fix:** align nav CTA copy to the waitlist reality (e.g. "รับสิทธิ์ก่อนใคร") and/or point it at `#cta`. **Suggested command:** /impeccable clarify
- **[P3] Hero h1 line-height loose for display.** `.h1` is `clamp(40px,8vw,80px)` at `line-height:1.42`. At 80px that's a slack gap between the two balanced lines. Thai needs more than Latin for vowel marks, but 1.42 is past that — ~1.25–1.3 reads tighter and more "display." **Suggested command:** /impeccable typeset
- **[P3] Section statement is a `<p>`, not a heading.** The privacy band's "ไม่มีใคร อ่านแชตคุณได้ — แม้แต่เรา" (`.tb-line`) is a major section message styled as a paragraph — weaker semantics/SEO than an `<h2>`. Also the em-dash here (+ lede + meta) is the cadence just removed from privacy.html; align for cross-page consistency. **Suggested command:** /impeccable polish

## Persona Red Flags

**Jordan (First-Timer):** Taps "เริ่มคุยกับปิ่น" expecting to chat → lands on a mockup they can't type in → confusion about whether the product is live (P2 above). Otherwise the page reads clearly; chips invite exploration.

**Casey (Mobile):** Thumb-friendly — chips are 44px min-height, cards/chips are snap-carousels, phone shrinks. Two snags: on a slow 3G first paint the `.rv` sections are invisible until IO fires (content pop-in, or blank if JS stalls); and form state isn't preserved if interrupted mid-fill.

**Riley (Stress Tester):** JS-off → mid-page sections blank (`.rv` P2). Submit failure → message appears but in neutral color, easy to miss it failed (error-style P2). Double-submit guarded by `disabled`. Honeypot + required hold up.

## Minor Observations
- `.wl-note` / `.hero-note` at 12.5–13.5px ink2 — passes AA (~4.7:1) but is the small-text floor; fine as supplementary.
- No skip-to-content link (single landmark, low cost to add).
- Mobile card/chip carousels hide scrollbars with no affordance hint — discoverable but not signaled.

## Questions to Consider
- Should the nav CTA and hero CTA say the *same* thing? Right now "เริ่มคุยกับปิ่น" and "รับสิทธิ์ก่อนใคร" describe two different mental models of the same action.
- The demo is the strongest asset — should the nav point people *to* it deliberately ("ดูตัวอย่าง") and keep "sign up" language only for the form?
- Is the iPhone-only mockup a constraint? An Android frame (or frameless) would widen the "this is for me" read for the Thai mass market.
