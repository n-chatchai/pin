# Design

Visual system for the **ปิ่น marketing site** (`site/`). Derived from the app's
canonical brand (`design/pin.html`) so web and app read as one product.

## Theme
Warm, calm, trustworthy — "a private notebook, not a dashboard." Light only
(no dark mode): a cream paper ground with one forest-green accent and soft,
low-contrast shadows. Premium and restrained; warmth comes from the cream paper,
Thai type, and the product mock — never from gradients or ornament.

## Color
Light theme, single committed accent (green) on a warm-neutral paper. Accent
coverage stays ≤ ~15% of surface (restrained strategy).

| Role | Token | Value | Use |
|---|---|---|---|
| Background (paper) | `--cream` | `#FAF8F2` | page ground |
| Surface | `--white` | `#FFFFFF` | cards, nav, mock screen |
| Accent | `--green` | `#34B06A` | primary buttons, active states, marks |
| Accent deep | `--green-d` | `#1C7A48` | hover, headings emphasis, on-green text base |
| Accent tints | `--green-pale` `--green-card` `--green-av` | `#E4EFDE` `#E9F1E6` `#DBEDD7` | icon chips, avatars, soft fills |
| Highlight | `--yellow` | `#F2B829` | the ปิ่น logo tick only (sparingly) |
| Ink (body) | `--ink` | `#2A2A26` | primary text (≈12:1 on cream) |
| Ink 2 | `--ink2` | `#6B6B62` | secondary text (≈5.4:1 — AA body) |
| Ink 3 | `--ink3` | `#A0A096` | meta only (large/non-essential; not AA body) |
| Line | `--line` | `#E6E1D5` | hairline borders, dividers |

Contrast rules: body uses `--ink`/`--ink2` (never `--ink3` for sentences). On the
green privacy panel, text is white / `rgba(255,255,255,.82)` for AA.

## Typography
Two families on a contrast axis (humanist Thai display + workhorse Thai body),
loaded from Google Fonts.

- **Display / UI** — `IBM Plex Sans Thai` (`--nira`), weights 500–700.
  Headings, nav, buttons, kickers, mock UI. Tight tracking on big heads
  (`letter-spacing:-.01 to -.02em`), `text-wrap:balance` on h1–h3.
- **Body** — `Sarabun` (`--sans`), weight 400–500, `line-height:1.62`,
  `text-wrap:pretty`. Body measure capped ~48–60ch.
- Scale: `clamp()`-fluid. h1 `clamp(34→60px)`, section title `clamp(26→40px)`,
  body `15–19px`. Display ceiling well under the shout threshold.

## Components
- **Buttons** — radius 13px, 50px tall. Primary = green fill + soft green shadow,
  hover → `--green-d` + arrow nudge. Secondary = white + `--line` border, hover →
  green border/text. Press = `scale(.98)`. No ripple.
- **Cards** — white, `--line` hairline, radius 18px, `--cardsh` soft shadow;
  hover lift (`translateY(-4px)` + `--liftsh`). No nested cards.
- **Use-case tabs** — pill row; active = green fill; inactive = white + hairline.
  Switching swaps both the copy panel and a live chat mock.
- **Phone mock** — dark bezel, cream screen; green "me" bubbles (right), white
  ปิ่น bubbles (left) with hairline shadow; result cards for tool output.
- **Privacy flow** — three stacked rows (device → blind proxy → model) on the
  green panel; status carried by icon + label, not color alone.
- **Logo mark** — green rounded square, white "ปิ" + yellow tick.

## Layout
- Container `min(1120px, 92vw)`, centered.
- Section rhythm `clamp(54→96px)` vertical; varied, not uniform.
- Responsive grids via `repeat(auto-fit, minmax(260px,1fr))`; hero + use-case
  stage collapse to one column under ~880px.
- Sticky nav with translucent blur; gains a hairline + faint shadow on scroll.
- Generous whitespace; flexbox for 1-D rows, grid for 2-D sections.

## Motion
Intentional and quiet. Reveal-on-scroll (fade + 18px rise, `cubic-bezier(.2,.7,.3,1)`,
IntersectionObserver, un-observe after) — content is visible by default and only
enhanced. Use-case panel swap = short rise. Button/press micro-interactions.
**All motion collapses to instant under `prefers-reduced-motion: reduce`.**
No bounce/elastic, no layout-property animation.

## Bans (carry from the global rules)
No gradient text, no side-stripe accent borders (>1px), no glassmorphism as
default, no eyebrow above every section, no identical icon-card grids as the
whole page, no headline overflow at any breakpoint.
