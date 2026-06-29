---
target: site/index.html
total_score: 32
p0_count: 0
p1_count: 1
timestamp: 2026-06-28T03-27-53Z
slug: site-index-html
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Chip/online states clear; form submit gives no on-page feedback |
| 2 | Match System / Real World | 4 | Thai-native, ค่ะ voice, LINE OA / ฿ — fluent |
| 3 | User Control and Freedom | 3 | Reselectable chips, anchor nav; fine for a landing |
| 4 | Consistency and Standards | 4 | Tokens, pills, demo mirrors app chat UI |
| 5 | Error Prevention | 3 | required + type=email + custom-required toggle |
| 6 | Recognition Rather Than Recall | 4 | Chips + demo self-explain each use case |
| 7 | Flexibility and Efficiency | 3 | Chips = quick path, dropdown = full list |
| 8 | Aesthetic and Minimalist | 3 | Clean, on-brand; 5-card grid slightly templated |
| 9 | Error Recovery | 2 | Native validation only; mailto dead-ends if no mail client |
| 10 | Help and Documentation | 3 | Privacy link + demo carry it |
| **Total** | | **32/40** | **Good** |

## Anti-Patterns Verdict

**LLM**: Does not read as AI slop. On-brand (cream + single forest-green, Trirong/Sarabun), privacy-as-warmth per PRODUCT.md. The interactive product mock (chip → swapping chat card) is genuine differentiation, not template filler. No eyebrows, no gradient text, no side-stripes, no hero-metric block. Weakest spot is the 5 identical photo+chip+caption cards — borderline "identical card grid", saved by being image-led.

**Deterministic scan**: `detect.mjs --json site/index.html` → `[]`, exit 0. Clean. No tells.

**Visual overlays**: not injected (file:// static review via Playwright screenshots + computed-style audit instead).

## Overall Impression
Solid, honest, on-brand landing that earns trust. The demo panel is the star and does real work. Biggest opportunity: the page's whole job is signup, but the conversion path has friction (silent mailto, chip selection disconnected from the far-down form) and two small a11y misses (one contrast fail, sub-44px chips).

## What's Working
- **Interactive demo panel.** Chip → chat card swap mirrors the real app's tool-result pattern (wcard carousel + toolbadge). Concrete Thai moments, not abstract features. Exactly Design Principle #2.
- **Restrained, coherent palette.** One green accent on cream, generous whitespace, body contrast 5.05:1. Reads calm/trustworthy, matches brand.
- **Honest, Thai-native voice.** ค่ะ, ฿, LINE OA, no hype — Design Principle #3/#4 intact.

## Priority Issues

- **[P1] Signup path dead-ends on mailto.** Form submit builds a `mailto:` and `location.href`s to it. On mobile webviews / users without a configured mail client, nothing visible happens — the page's primary conversion silently fails, with no success or error state.
  - **Why**: The site exists to capture waitlist signups. A submit that produces no on-page confirmation (and may no-op) loses the conversion and the user's trust.
  - **Fix**: Add an on-page success state ("ลงชื่อแล้ว ✓ เดี๋ยวส่งลิงก์ให้ค่ะ") after submit, and ideally POST to a real endpoint; keep mailto only as fallback. At minimum show confirmation regardless.
  - **Command**: `/impeccable harden`

- **[P2] Chip selection is disconnected from the form.** Chips live in the #join split (top); picking one silently sets a dropdown in the #cta section far below (past the trust band). User never sees the sync, and must hunt for the form.
  - **Why**: Breaks the recognition loop — the action (chip) and its effect (dropdown value) aren't co-located, so the "เลือกแล้ว" promise isn't felt.
  - **Fix**: Either move the form adjacent to the chips, or on chip-tap scroll to #cta with the choice visibly reflected.
  - **Command**: `/impeccable layout`

- **[P2] Toolbadge contrast fails AA.** `.toolbadge` text `rgb(154,143,126)` on white = **3.18:1** (needs 4.5:1 for 11.5px).
  - **Why**: PRODUCT.md targets WCAG AA; small "ใช้: …" label is hard to read.
  - **Fix**: Use `--ink2` (5.05:1) or darken toward forest.
  - **Command**: `/impeccable audit`

- **[P2] Chip tap targets sub-44px.** `.ucchip` height ≈ 35px; below the 44×44 mobile minimum (Casey).
  - **Why**: Mis-taps on the primary engagement control on phones — the main audience.
  - **Fix**: Bump vertical padding to reach ≥44px.
  - **Command**: `/impeccable adapt`

- **[P3] Use-case card grid is templated.** Five same-size photo + chip + caption cards read slightly AI-grid; captions are 13px low-emphasis.
  - **Why**: Mild slop signal; weakest section visually.
  - **Fix**: Vary emphasis (feature one), or tighten to 3–4 stronger cards.
  - **Command**: `/impeccable bolder`

## Persona Red Flags

**Casey (Distracted Mobile)**: Chips at 35px tall → mis-taps. Form sits at the very bottom after a long scroll past the trust band. mailto may not open in an in-app browser → signup lost with no feedback. Primary audience is mobile mid-day; this is the riskiest persona.

**Riley (Stress Tester)**: Submitting with no mail client = silent no-op (no error, no success). Custom "อื่น ๆ" empty is caught by `required`. Manually changing the dropdown after a chip tap works, but the chip stays highlighted out of sync if they later pick "อื่น ๆ" — minor.

**Jordan (First-Timer)**: Path is clear and self-teaching via the demo. Only snag: low-contrast `ใช้: เชื่อมต่อ LINE OA` badge is easy to miss; "OA" is mild jargon (acceptable for SME audience).

## Minor Observations
- Default email placeholder uses browser gray `rgb(117,117,117)`; set an explicit ≥4.5:1 placeholder color for consistency.
- Two signup affordances ("เลือกแล้ว ลงชื่อรับสิทธิ์" → #cta vs hero "รับสิทธิ์ก่อนใคร" → #cta) both point to #cta now — good, keep single destination.
- Reveal motion (`.rv`) gates content on a class; observer fires on scroll but element-screenshot/headless renders showed it blank until scrolled. Fine for users, watch for prerender/SEO snapshots.

## Questions to Consider
- What does a visitor see the instant after they hit "รับสิทธิ์ก่อนใคร"? Right now: maybe nothing.
- Should picking a chip carry the visitor toward the form, instead of quietly editing a control they can't see?
- Does the use-case section need five cards, or would three confident ones land harder?
