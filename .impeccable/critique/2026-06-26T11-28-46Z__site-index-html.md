---
target: site/index.html
total_score: 33
p0_count: 0
p1_count: 2
timestamp: 2026-06-26T11-28-46Z
slug: site-index-html
---
# Critique #4 — ปิ่น Landing (`site/index.html` + linked `privacy.html`)

Register: brand (Thai consumer pre-launch). 4th pass. Trend 32 → 31 → 29 → **33**.

## Design Health Score

| # | Heuristic | Score | Note |
|---|-----------|-------|------|
| 1 | Visibility of Status | 3 | Waitlist success, nav scrolled, reveal-on-scroll |
| 2 | Match Real World | 4 | Thai voice excellent; real Thai personas |
| 3 | User Control | 3 | Anchors; no back-to-top; mailto = silent context switch |
| 4 | Consistency | 2 | Hero h1 Thai inter-line is tight (breaks own type standard) |
| 5 | Error Prevention | 3 | Email regex + Thai error + novalidate |
| 6 | Recognition > Recall | 4 | Chips + captions + icons; nothing to memorize |
| 7 | Flexibility | 3 | One waitlist path (fine pre-launch) |
| 8 | Aesthetic & Minimal | 4 | Disciplined, calm, Pi-grade restraint — the strength |
| 9 | Error Recovery | 3 | Inline aria-live error region |
| 10 | Help & Docs | 4 | privacy.html + /developers/ cover "why trust" |
| **Total** | | **33/40** | **Good — ship-class with one type fix** |

The right things moved since 29: H2/H6/H8/H10 climbed on wordmark + captions + privacy page. H4 is the lone soft spot.

## Resolution of #3 issues — all genuinely fixed
- [P0] privacy not argued → **RESOLVED**: privacy.html is a real, confident argument (4 plain-Thai blocks: E2EE/on-device/blind-proxy/no-ads + a ปิ่น-vs-cloud comparison + forest/yellow CTA). Split-page choice works.
- [P1] bare Latin icon → **RESOLVED**: brandmark lockup = app icon + 92px Trirong "ปิ่น" wordmark. Biggest identity win — reads Thai brand, not app shell.
- [P2] cards no copy → **RESOLVED**: 5 concrete benefit captions.
- [P2] hero-note contrast → **RESOLVED** (ink2).
- [P2] highlight overloaded → **RESOLVED** (image + statement + trust-link + waitlist).

## Anti-Patterns — no longer a "Pi.ai clone"
Crossed into own identity (~75%). Structural DNA still Pi.ai (the borrowed IA is the last 25% of the slop-smell), but ปิ่น Trirong wordmark + sage-green photography + Thai voice + green/cream now supply enough surface identity that the reflex doesn't fire on a normal visitor. "Pi.ai's IA, ปิ่น's skin" — defensible for a pre-launch Thai product. **Detector: 0 findings on BOTH pages, exit 0.** All text ≥ AA (B-measured; lowest text = trust-line .more link 4.97:1). Only sub-4.5 value = privacy comparison amber-X icon 3.09:1, a non-text graphic that passes its 3:1 bar.

## What's Working
1. **ปิ่น wordmark lockup** — solves identity decisively; warm, premium, Thai.
2. **privacy.html is portfolio-grade** — the comparison + forest/yellow CTA is the best-resolved screen in the property.
3. **Disciplined restraint** — palette, Trirong/Sarabun, photography, whitespace cohere; nothing shouts.

## Priority Issues

**[P1→fixing] Hero h1 Thai leading too tight.** At top clamp (82px, line-height 1.26) the line-1 descender "ผู้" sits very close to line-2 tone marks "ที่รู้" — borderline, not a hard overlap (A called collision, B called clean; my zoom = tight-but-not-touching). Still under-leaded for a premium serif. *Fix:* h1 line-height → ~1.38–1.45 for Thai. *Cmd:* harden/typeset.

**[P1] Privacy is told, not felt, on the home.** The differentiator = one quiet 14.5px trust-line + a creator paragraph; the *felt* payload ("ไม่มีใคร อ่านแชตคุณได้ — แม้แต่เรา") lives entirely behind a click. A visitor who never clicks privacy.html leaves without the one feeling that sells the product. Riley (skeptic) = highest risk. *Fix:* one felt privacy moment on-page — a small 3-icon trust strip (lock / on-device / no-ads) or a one-line band before the creator block, deep-linking to privacy.html. Don't rebuild the argument; make the feeling land once. *Cmd:* clarify/bolder.

**[P2] Creator-block ending is flat (peak-end).** Home ends on "สร้างโดย tokens2.io" + paragraph + link — a credits roll, no CTA crescendo. *Fix:* move the waitlist below the creator block as the true closer, or add a final soft CTA echo. *Cmd:* layout.

**[P3] Mailto fallback is a silent surprise.** With `WAITLIST_ENDPOINT=''`, submit fires a mailto AND shows success — a desktop user with no mail client believes they signed up but nothing was captured. *Fix:* wire a real endpoint before launch, or don't show success on the mailto path. *Cmd:* harden.

## privacy.html — best surface, minor issues
Strong hero line, 4 clear blocks, persuasive comparison, confident CTA. Minors: (a) long single-column read, no in-page anchors for skimmers; (b) "ข้อมูลอาจถูกใช้เทรนต่อ" — the lone soft "อาจ" hedge in an otherwise assertive comparison; (c) dead CSS on `.blk .ic` (double `background` declaration); (d) amber-X 3.09:1 (passes 3:1 graphic, could darken to clear 4.5).

## Persona Red Flags
- **Riley (skeptic) — highest:** home answers "prove privacy" with one quiet link; might click through (fully satisfied) or bounce unconvinced. P1 fix targets this.
- **Jordan:** lands fine (wordmark + tagline + cards); the tight h1 may register as vague "something's off."
- **Casey (mobile):** cards snap-scroll all 5, hamburger works, comparison stacks. Good. Re-check h1 leading on-device after fix.

## Questions to Consider
1. If you deleted the home's trust-line + creator privacy paragraph, would conversion drop? If "no, the people who care click through anyway" → the home isn't doing privacy's job (P1 mandatory).
2. You inherited Pi.ai's section *order*. What if the privacy differentiator dictated the layout instead? (the borrowed IA is the last slop-smell.)
3. The h1 tightened the moment real Thai descenders met tone marks at scale — has any clamp/line-height been tested with worst-case stacked-mark Thai, or only with friendly strings?
