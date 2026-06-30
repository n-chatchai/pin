# Critique ignore list

Findings recorded here are dropped silently on future `/impeccable critique` runs.

- **dark-glow on `site/index.html` (~line 98).** False positive. The match is the
  `.phone` iPhone-bezel mockup: a `#0d0d0d` bezel with a warm `rgba(60,40,15)`
  drop-shadow on a *cream* page. That shadow hue is the brand's standard warm
  shadow (`--cardsh`/`--liftsh`), not a dark-mode colored glow. The page is light.
