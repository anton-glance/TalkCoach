# 01 · Overview

## What Locto is

**Locto** is a macOS menu-bar app that listens to your speech and, while your mic is active, shows a small floating widget telling you whether you're speaking **too slow / ideal / too fast** (pace) and whether you've been talking continuously too long (monologue). It is calm and ambient — designed for peripheral-vision glance, not focused reading.

**Tagline:** *Speak in your sweet spot.*

**One-liner:** *An ambient AI speech coach for Mac.*

## Surfaces

| Surface | Type | When shown |
|---|---|---|
| Menu bar icon | NSStatusItem | Always after launch |
| Menu bar dropdown | NSMenu | On click |
| Ambient widget | Floating NSPanel (utility window, 144 × 144 pt) | While mic is active |
| Settings | AppKit NSWindow (520 × 600 pt) | On Cmd-, or first launch |

There is no global tab bar, no sidebar, no dashboard. The product has three modes the user moves between (background / active session / configuration), not surfaces that compete for attention.

## Scope (v1) and what's deferred

**In v1:**
- Pace tracking (WPM)
- Monologue tracking (continuous-speech duration)
- The two-zone widget surface (Liquid Glass)
- Menu bar + Settings

**Deferred to v2:**
- Filler-word strokes (the vertical-stroke "|||" counts on the widget)
- Coach notes / dashboard
- Tab bar
- Multi-locale beyond initial set

## Naming

The **user-facing product is Locto**. The repository, Xcode scheme, and bundle id (`com.talkcoach.app`) keep the working name **TalkCoach** for v1. Any user-visible string says Locto; anything inside the build says TalkCoach.

## Source of truth precedence

When in conflict:

1. Upstream `DesignTokens.swift` (in [`anton-glance/TalkCoach`](https://github.com/anton-glance/TalkCoach) at `docs/design/old/Sources/DesignTokens.swift`) wins on shipping macOS values.
2. `tokens.css` mirrors those for non-Swift surfaces.
3. Guides in this folder document intent and rules.
4. Preview cards in `preview/` are visual reference, not authoritative.

If still unsure: default to "calm, ambient, peripheral-vision" — and make less, not more.

## How to use this system

**Visual artifacts (slides, mocks, prototypes, marketing):**
- Copy assets from `brand/` into your output.
- Import `tokens.css` for variables.
- Lift `components/widget/Widget.jsx` rather than rebuilding from screenshots.
- Apply the voice rules from `02-voice-and-copy.md`.

**Production macOS code:**
- Mirror `DesignTokens.swift` values; don't redefine.
- Use `components/widget/tokens.js` if you need the same logic in JS.
- The shipping widget spec is in `05-widget-design.md`.

## What to read next

- Writing copy → `02-voice-and-copy.md`
- Picking colors / fonts → `03-color-and-type.md` + `tokens.css`
- Spacing, radii, motion → `04-spacing-radii-motion.md`
- Building the widget → `05-widget-design.md`
- Using icons → `06-iconography.md`
