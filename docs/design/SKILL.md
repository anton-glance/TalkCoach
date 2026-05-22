---
name: locto-design
description: Use this skill to generate well-branded interfaces and assets for Locto, an ambient AI speech coach for Mac. Includes the design system (colors, type, fonts, motion), brand assets (logos, app icon, menu-bar template), the canonical Liquid Glass widget UI kit, and topical guides. Use for production code, prototypes, mocks, slides, or marketing surfaces.
user-invocable: true
---

# Locto design skill

This skill is a self-contained design system. Everything you need to design or build for Locto is in this folder.

## Read first

1. **`README.md`** — repository map and quickstart by goal (1 min).
2. **`guides/01-overview.md`** — what Locto is, what's in scope, what's deferred (2 min).
3. The specific guide for your task (see table below).

## Find what you need

| Task | Files |
|---|---|
| Write copy, name a thing, choose a tone | `guides/02-voice-and-copy.md` |
| Use colors or type | `guides/03-color-and-type.md` + `tokens.css` |
| Pick spacing, radii, motion timing | `guides/04-spacing-radii-motion.md` |
| Recreate or place the widget | `guides/05-widget-design.md` + `components/widget/` |
| Use icons | `guides/06-iconography.md` |
| Use the brand mark / wordmark / app icon | `brand/README.md` + `brand/logo/` + `brand/icons/` |
| Wire up Inter / Inter Display / JetBrains Mono | `fonts/README.md` + `tokens.css` `@font-face` |
| See a visual reference | `preview/<concept>.html` (e.g. `widget-states.html`, `colors-states.html`) |

## How to use the skill

**For visual artifacts** (slides, mocks, prototypes, marketing):
- Copy assets from `brand/` into your output.
- Import `tokens.css` (or copy its CSS variables) for the palette and type ramp.
- Lift the widget from `components/widget/Widget.jsx` if relevant.
- Honour the voice rules in `guides/02-voice-and-copy.md` (sentence case, tabular nums on numbers, no emoji, etc.).

**For production code** (the macOS app):
- The upstream `DesignTokens.swift` is the source of truth for spec values. Mirror, don't redefine.
- `components/widget/tokens.js` is a JS mirror — handy for any non-Swift surface.
- The shipping widget is 144 × 144 pt, corner radius 32 pt, Liquid Glass material — full spec in `guides/05-widget-design.md`.

## When invoked without context

1. Ask what they want to build, target audience, fidelity, constraints.
2. State your assumptions before building (which assets you'll pull, what voice you're targeting).
3. Build, then iterate.

Act as an expert designer on Locto's team. The product is **calm, ambient, peripheral-vision**. Resist anything that raises its voice (no exclamation marks, no flashy colours, no decorative icons, no springs, no bounces). When in doubt: less.
