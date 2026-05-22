# Locto · Design System

> An ambient AI speech coach for Mac. *Speak in your sweet spot.*

A complete, self-contained design system for **Locto** — a calm, peripheral-vision macOS app that lives in the menu bar and shows a tiny floating widget while your mic is active. This package contains everything a designer, agent, or engineer needs to build for Locto: brand assets, fonts, design tokens, focused guides, and a canonical UI component kit.

The brand is **Locto**; the codebase, Xcode scheme, and bundle id (`com.talkcoach.app`) keep the working name **TalkCoach** for v1. Any user-visible string says Locto.

---

## Repository map

```
locto-design-system/
├── README.md                 ← this file (index + how to use)
├── SKILL.md                  ← agent skill manifest
├── tokens.css                ← all design tokens + @font-face
│
├── brand/                    ← brand identity assets
│   ├── README.md
│   ├── logo/                 ← mark, wordmark, lockup (SVG)
│   └── icons/                ← app icon, menu-bar template
│
├── fonts/                    ← brand typefaces
│   ├── README.md
│   ├── inter/                ← Inter (UI body) — WOFF2 + variable + desktop OTF
│   ├── inter-display/        ← Inter Display (headlines + hero numbers)
│   └── jetbrains-mono/       ← JetBrains Mono (docs/code only)
│
├── guides/                   ← focused topical guides
│   ├── README.md             ← guide index
│   ├── 01-overview.md        ← what Locto is, scope, what to read next
│   ├── 02-voice-and-copy.md  ← voice, tone, casing, copy patterns
│   ├── 03-color-and-type.md  ← palette + type system (refs tokens.css)
│   ├── 04-spacing-radii-motion.md
│   ├── 05-widget-design.md   ← the canonical Liquid Glass widget spec
│   └── 06-iconography.md     ← icon rules + substitutions
│
├── components/               ← shippable UI components
│   └── widget/
│       ├── README.md         ← widget reference
│       ├── Widget.jsx        ← the 144 pt floating tile
│       ├── tokens.js         ← paceColors + monoColors helpers
│       └── demo.html         ← Liquid Glass demo on a draggable macOS scene
│
└── preview/                  ← Design System tab reference cards (one per concept)
```

---

## Quickstart by goal

| What you want to do | Read this |
|---|---|
| Understand Locto's brand and scope | `guides/01-overview.md` |
| Write any user-facing copy | `guides/02-voice-and-copy.md` |
| Pick the right colors / fonts | `guides/03-color-and-type.md` + `tokens.css` |
| Get spacing, radii, motion right | `guides/04-spacing-radii-motion.md` |
| Build the widget (or anything that uses it) | `guides/05-widget-design.md` + `components/widget/` |
| Use icons | `guides/06-iconography.md` |
| Pull brand assets | `brand/README.md` |
| Wire up the fonts | `fonts/README.md` |
| See visual reference for a concept | `preview/<concept>.html` |

---

## For coding agents

1. **Start at `SKILL.md`** for the agent contract — what this skill is and how to invoke it.
2. **Read `guides/01-overview.md`** for context (1 min).
3. **For any specific task**, jump to the relevant guide in `guides/` (each is focused, ≤ 5 min to skim).
4. **Pull tokens from `tokens.css`** — do not hardcode hex values, font sizes, or radii. The CSS variables are the source of truth.
5. **Lift the widget from `components/widget/Widget.jsx`** rather than rebuilding it. It accepts `wpm`, `idle`, `monologueSeconds`, and `onPointerDown`.
6. **Copy brand assets into your output** — reference paths in `brand/`, do not link to URLs.
7. **For production Swift code**, the upstream `DesignTokens.swift` (in [`anton-glance/TalkCoach`](https://github.com/anton-glance/TalkCoach) at `docs/design/old/Sources/`) is the source of truth.

---

## Source of truth precedence

When in conflict:
1. The upstream `DesignTokens.swift` wins on shipping macOS values.
2. `tokens.css` mirrors those for any non-Swift surface.
3. Guides in `guides/` document intent and rules.
4. Preview cards in `preview/` are visual reference — not authoritative.

If you're unsure, default to "calm, ambient, peripheral-vision" — and make less, not more.
