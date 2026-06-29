---
target: site/privacy.html
total_score: 31
p0_count: 0
p1_count: 0
timestamp: 2026-06-29T23-37-13Z
slug: site-privacy-html
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Static page; no scroll-position cue in nav, no active state. |
| 2 | Match System / Real World | 4 | Thai-native, plain, warm. No jargon barrier (E2EE glossed inline). |
| 3 | User Control and Freedom | 3 | Two "กลับหน้าแรก" exits + smooth scroll. Fine for a leaf page. |
| 4 | Consistency and Standards | 4 | Tokens/nav/footer match index.html exactly (blush/forest/Trirong). |
| 5 | Error Prevention | 3 | No forms; nothing to mis-submit. |
| 6 | Recognition Rather Than Recall | 3 | Labeled sections; decorative icon chips carry no aria. |
| 7 | Flexibility and Efficiency | 3 | Single linear read — correct for legal content. |
| 8 | Aesthetic and Minimalist Design | 3 | Clean and restrained; minor content dup (blocks≈policy) + dead CSS comment. |
| 9 | Error Recovery | 2 | Contact link `href="#join"` is dead on this page if JS fails (no #join anchor). |
| 10 | Help and Documentation | 3 | This *is* the policy; contact path present. |
| **Total** | | **31/40** | **Good — solid foundation, address weak areas** |

## Anti-Patterns Verdict

**Does this look AI-generated? — Low.** Committed Trirong/blush/forest identity, Thai-native voice ending in care not fear, restrained green accent. Reads as a real brand, not a template.

**LLM assessment:** The one tell is the 4-row icon+heading+text block — structurally the "identical card grid" reflex, though softened (divider rows, not cards; no nested cards). Closest slop edge. Everything else is committed: serif display, single accent, no gradient text, no eyebrow-on-every-section, no side-stripes.

**Deterministic scan:** `detect.mjs` → 1 finding: **em-dash-overuse** (warning) — 5 em-dashes in body (lines 111×2, 120, 143, 181; +1 in meta). AI cadence tell, and `—` is not a native Thai punctuation convention. Confirmed real, not a false positive.

**Visual overlays:** Not run — browser automation routed through gstack `/browse` only; page is static and fully assessed from source. No user-visible overlay this run.

## Overall Impression
A calm, trustworthy legal page that actually delivers on the brand's "privacy as warmth" principle. The hero ("ไม่มีใคร อ่านแชตคุณได้ — แม้แต่เรา") is a strong reassuring peak; the closing promise is a clean end. Biggest opportunity: kill the em-dash cadence and harden the contact link's no-JS fallback. Nothing here is broken-broken.

## What's Working
- **Identity discipline.** Pixel-consistent with the redesigned index.html — same tokens, nav, footer. Web reads as one product.
- **Voice.** Plain Thai, technical terms (E2EE, blind proxy) glossed in human language inline. Match-real-world = 4.
- **Emotional arc.** Reassurance peak in hero → formal policy → warm promise close. Peak-end handled.

## Priority Issues

- **[P2] Dead contact link without JS.** `<a id="polMail" href="#join">` relies on inline JS to swap to `mailto:`. `#join` exists on index.html, not here — JS-off or CSP-blocked, clicking "ทีมปิ่น" jumps nowhere. **Fix:** fallback `href="mailto:..."` defeats the scrape-obfuscation goal, so instead point the no-JS href at `index.html#join` (a real anchor) or render a plain-text address. **Suggested command:** /impeccable harden
- **[P2] Em-dash cadence (detector).** 5 `—` in body; un-Thai punctuation + AI tell. **Fix:** swap for วงเล็บ / comma / colon. e.g. line 111 `ซึ่งไม่มีใคร—แม้แต่เรา—เปิดอ่านได้` → `ซึ่งไม่มีใคร (แม้แต่เรา) เปิดอ่านได้`. **Suggested command:** /impeccable clarify
- **[P2] Decorative icons unlabeled for SR.** Phosphor `<i>` (lock, device, eye-slash, hand-heart, chips) have no `aria-hidden="true"`; a screen reader may announce ligature junk. **Fix:** add `aria-hidden="true"` to every decorative `<i>`. **Suggested command:** /impeccable harden
- **[P3] Content duplication.** The 4 hero blocks restate the policy items almost 1:1 (E2EE / on-device / blind proxy / no-ads). Intentional summary-then-detail, but tighten so the formal policy adds specifics the blocks don't. **Suggested command:** /impeccable distill
- **[P3] Dead CSS.** `/* comparison */` comment (line 55) marks a removed section; the `.cl-*`/closing styles read fine but the orphan comment is leftover scaffolding. **Suggested command:** /impeccable polish

## Persona Red Flags

**Jordan (First-Timer):** Lands on a privacy page and immediately groks it — plain Thai, no legalese wall. No red flags on comprehension. Only snag: if they tap "ทีมปิ่น" to ask a question and JS didn't run, nothing happens (P2 above).

**Sam (Accessibility):** Body `--ink2 #6E6457` on `--blush #F7EEE3` ≈ 4.7:1 — passes AA but thin at 15px; the policy `<p>` at 15px is the floor. Decorative icons lack `aria-hidden`. Focus-visible ring is defined (good). Keyboard: all-links, fully navigable.

**Riley (Stress Tester):** JS-off → contact link dead (P2). Long-press / no-JS otherwise fine (static). No empty/error states to break. Meta `href="#policy"` etc. resolve.

## Minor Observations
- Hero lede caps at 44ch, policy `<p>` at 64ch — good measure control.
- `.blk p` 15.5px vs `.pol-item p` 15px — trivial inconsistency, harmless.
- No `<link rel="canonical">` / OG tags (SEO/share polish, not UX).

## Questions to Consider
- Should the 4 hero blocks and the 7 policy items be one layer instead of two? The page says everything twice.
- The blind-proxy claim is the brand's strongest differentiator — does it deserve a small diagram rather than sharing a plain row with the other three?
- If a Thai reader has never seen "end-to-end encryption," does the inline gloss land, or does it need one concrete sentence ("เหมือนจดหมายที่ปิดผนึก...")?
