---
target: site/index.html
total_score: 31
p0_count: 0
p1_count: 2
timestamp: 2026-06-26T09-23-57Z
slug: site-index-html
---
# Critique #2 — ปิ่น Landing (`site/index.html`)

Register: brand (Thai consumer marketing landing). Re-critique after the fixes from run #1.

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of Status | 3 | Tab `.on` + waitlist success clear; no active-section indicator on scroll |
| 2 | Match Real World | 4 | Thai natural, de-jargoned; personas mirror audience |
| 3 | User Control & Freedom | 3 | Waitlist success irreversible (no "แก้อีเมล"); mailto fallback yanks to mail client |
| 4 | Consistency | 3 | "ดาวน์โหลด" / "เริ่มใช้ฟรี" / "รับแจ้งเตือนเปิดตัว" all → same #download waitlist (label mismatch) |
| 5 | Error Prevention | 3 | Email regex-checked; but `novalidate` + silent focus() = no visible error |
| 6 | Recognition > Recall | 4 | Demos carry the load; everything shown |
| 7 | Flexibility & Efficiency | 3 | (was 2) mobile nav now fixed; no sticky CTA on long scroll |
| 8 | Aesthetic & Minimal | 3 | (was 4) hero dense; "สโตร์ความสามารถ" restated 3× (wow-strip/demo/list) |
| 9 | Error Recovery | 2 | (was 3) waitlist invalid-email = silent focus jump, no message; mailto navigates away silently |
| 10 | Help & Docs | 3 | "3 ขั้น" is de-facto help; no FAQ for the privacy skeptic |
| **Total** | | **31/40** | **Good** |

**Score note:** 32 → 31 is within agent-to-agent variance, NOT a regression. The composition: H7 improved +1 (mobile nav fixed); the re-critique applied fresh scrutiny that dinged H8 (wow-strip redundancy) and H9 (waitlist silent errors). The run-#1 P1s are resolved; this run found finer issues + one self-inflicted defect (highlight, below).

## Anti-Patterns Verdict — Partially escaped (~65/100)

Both agents agree: the **content demos escape the genre reflex; the frame does not.** The live per-persona chat thread + the per-pillar mini-demos (store-chips / cipher-wire / persona-tone-toggle) are genuine voice — they *show the product working*, which a templated competitor wouldn't have. But the skeleton (floating phone + bob-cards + 5-icon strip + 3-pillar grid + dark cipher panel) is the consumer-AI-assistant genre default. A fast scan still reads "AI-assistant landing from a kit."

**Detector:** exit 2, 1 warning. `dark-glow` (line 48) = **confirmed false positive** (B re-verified: body bg is cream rgb(250,248,241); the flagged green box-shadow is on isolated green surfaces, not a dark-themed UI). Em-dash warning cleared (12 → 1 since run #1).

## What's Working
1. **Show-don't-tell demos** — live use-case chat + per-pillar mini-screens. The page's real moat.
2. **Honest privacy & pricing** — de-jargoned headline "ไม่มีใคร อ่านแชตคุณได้", the 3-hop "ตัวกลางที่มองไม่เห็น" flow, disabled Premium button (no dark pattern).
3. **Type & token craft** — real Thai type, disciplined palette, text-wrap balance/pretty, AA focus rings, reduced-motion honored.

## Priority Issues

**[P1] Yellow marker misregisters on Thai script (regression, self-inflicted run #1).** `.hl{linear-gradient(transparent 62%,…)}` sits ~38% from bottom; Thai stacks vowels/tone marks high, so the band crosses mid-consonant and leaves an empty highlighted rectangle under trailing " ๆ"/whitespace. The one "signature" gesture currently reads as a misaligned box → *weakens* the differentiator. *Fix:* raise band start to ~78–82% so it hugs the baseline; tighten padding/box-decoration-break; trim the highlighted span to exclude trailing " ๆ". *Command:* typeset.

**[P1] Waitlist ask betrays the "download/free" promise.** 5 above-fold CTAs say "เริ่มใช้ฟรี / ดาวน์โหลด" but all scroll to an email waitlist (#download) — the app isn't downloadable; "กำลังเปิดตัวเร็ว ๆ นี้" is only revealed *at* the form. Expectation violation at the conversion moment, on a trust product. *Fix:* honest pre-launch CTA labels ("จองคิวเปิดตัว / รับสิทธิ์ก่อนใคร") + a "เปิดตัวเร็ว ๆ นี้" badge near the hero CTA; reconcile the 3 labels into 1. *Command:* clarify.

**[P2] Wow-strip flattens momentum + duplicates.** The 5-icon strip sits between two stronger demo-driven sections and restates "สโตร์ความสามารถ" (appears 3×). It's the emotional valley right after the hero peak. *Fix:* cut, or fold into the hero trust row, or make it a thin live-capability ticker. *Command:* distill.

**[P2] Waitlist form has silent error/empty states.** Invalid email = `.focus()` only (no message); `novalidate` kills native hints; input has `aria-label` but no visible `<label>`; mailto fallback navigates away silently. *Fix:* inline error string + aria-live, visible label, clearer success/disabled path. *Command:* harden.

**[P3] Privacy cipher demo is the last cold spot.** `8f3a··b21e··9c47` mono hex inside the now-warm de-jargoned panel = mild tonal contradiction. *Fix:* keep the wire metaphor but soften — lock + "อ่านไม่ออก แม้แต่เรา" over a blurred bubble. *Command:* quieter.

## Cognitive Load — fail 3/8
5 use-case tabs > 4 options (wrap on mobile); privacy paragraph + hero lede are dense single blocks; "สโตร์ความสามารถ" redundancy 3×.

## Persona Red Flags
- **Jordan:** clicks "ดาวน์โหลด", expects install, gets an email field. 5 tabs force self-classification before value.
- **Riley (skeptic):** privacy headline reassures, but raw cipher + unexplained "สมองทำงานบนเครื่อง" with no "how do I know?" expander leaves the anxious unconvinced. No FAQ.
- **Casey (mobile):** mobile facts verified clean (no overflow, hamburger works); but 5 use-case tabs wrap to multiple rows at 390px, and no sticky CTA on the long page.

## Minor
Phone status "▮▮▮" glyphs read tofu-ish; only the default "work" persona tab is statically rendered (verify the other 4 fit `min-height:240px` without jump); `/developers/` footer link on a non-developer page (fine as quiet secondary).

## Questions to Consider
1. Delete the floating phone + bob-cards + cipher panel (every borrowed cliché) and lead full-bleed with only the live persona chat — less convincing, or finally not kit-like?
2. Privacy is repeated 4×. Is privacy the hook a stressed Thai consumer came for, or is "จำคุณได้ / ผู้ช่วยที่รู้จักคุณ" the real emotional draw being buried under a security pitch?
3. The funnel ends at an email waitlist for an unreleased app — is this page's honest job to convert, or to *not lose* the believer? If the latter, why five "ดาวน์โหลด" buttons promising a download you can't deliver?
