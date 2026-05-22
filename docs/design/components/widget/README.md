# Widget · component

The canonical Locto widget. 144 × 144 pt floating tile with Liquid Glass material, two colour zones, and a single shared bar.

## Files

| File | Purpose |
|---|---|
| `Widget.jsx` | The React component. Exports `window.LoctoWidget` |
| `tokens.js` | Mirrors `DesignTokens.swift`. Exposes `paceColors(wpm)` + `monoColors(seconds)` + `zoneForWPM` + `spectrumPosition` + `rgba` |
| `demo.html` | Interactive demo with a draggable widget over a macOS-style scene (window, photo, dock) |

## Component API

```jsx
<LoctoWidget
  wpm={152}                   // number · current words per minute
  idle={false}                // bool · true = user stopped speaking
  monologueSeconds={0}        // number · continuous-speech seconds
  onPointerDown={handler}     // optional · for drag handling in demos
/>
```

Renders a 144 × 144 pt tile. All visual state is derived from the three data props — no internal state besides hover.

## Layout

Top → bottom inside the tile:

1. **Top half · pace** — WPM number (Inter Display 26 pt / w300 / tabular) + `wpm` unit (baseline-aligned) + state label (`IDEAL`/`TOO SLOW`/`TOO FAST`)
2. **Down-pointing caret** (above the bar, tracks WPM position 0–1 on slow→fast spectrum)
3. **Single shared bar** — 2 px white at 0.62 alpha, the visual axis of the widget
4. **Up-pointing caret** (below the bar, slides with monologue fill edge 0–1 across 90 s)
5. **Bottom half · monologue** — duration (`M:SS`, same number style; colon nudged `translateY(-0.09em)` to digit optical center) + label (`MONOLOGUE` → `TAKE A PAUSE` at ≥ 90 s)

## Two colour zones

Vertical gradient with a soft 30 % blend in the middle:

- Top zone tints via `paceColors(wpm)` — slate-blue / sage-green / warm-coral
- Bottom zone tints via `monoColors(seconds)` — green (0–60 s) → gold (60–90 s) → coral (90–120 s) → coral sustained

Both tints render at 0.78 alpha so colour reads on any substrate.

## Liquid Glass

- `backdrop-filter: blur(40px) saturate(180%) brightness(1.04)`
- Specular highlight on top edge + faint bottom underglow (composited radial gradients)
- 6-layer shadow stack (inner highlight + rim + inner shadow + three drops)
- 0.5 px outer white border at 0.45 alpha

## Content treatment

Every text/bar/caret is **softened white**: numbers `0.94` · labels `0.68` · `wpm` unit `0.55` · bar `0.62` · carets `0.82`.

## States

| Condition | Effect |
|---|---|
| `wpm < 115` | Top tint slate-blue, WPM caret left |
| `115 ≤ wpm ≤ 175` | Top tint sage-green, caret centre |
| `wpm > 175` | Top tint warm-coral, caret right |
| `monologueSeconds < 60` | Bottom tint green; cluster opacity ramps 0.6 → 0.85 |
| `60 ≤ s < 90` | Tint green → gold; opacity → 1.0 |
| `s ≥ 90` | Tint coral; label flips to `TAKE A PAUSE` (700 weight); opacity pulses 1 ↔ 0.72 over 2.5 s |
| `s ≥ 120` | Pulse range widens to 1 ↔ 0.5 |
| `idle` | Whole widget `opacity: 0.5` over 700 ms easeInOut; WPM → `---`; mono → `-:--`; labels and carets hidden; layout preserved |

## Hover

Only `transform` (lift) and `box-shadow` change. Tint, blur, brightness stay locked — the widget never "wakes up" with a saturation jump.

## Demo (`demo.html`)

- **Pace slider** drives the WPM input
- **Go idle** toggles the idle prop
- **Monologue slider** + ▶ scrub or auto-advance the timer
- **Drag the widget** with the cursor to position it over different scene elements (Notes window edge, vivid photo, dock with app icons, plain wallpaper) and watch the Liquid Glass refract

The scene under the widget is rendered with real `backdrop-filter` so the glass effect is genuine, not faked with screenshots.

## Lifting into other layouts

`Widget.jsx` exports `window.LoctoWidget`. Pass the three data props and (optionally) `onPointerDown`. `tokens.js` exposes `paceColors(wpm)` and `monoColors(seconds)` so any other surface can tint with the live state ink (e.g. marketing pages, App Store screenshots).

## Production parity

The shipping macOS app uses SwiftUI `.glassEffect(.regular.tint(liveTint))` — not reproducible pixel-perfect on the web. This demo approximates with `backdrop-filter`. The numeric / behavioural values match the upstream `DesignTokens.swift` and `01-design-spec.md`.

## See also

- `guides/05-widget-design.md` — full design spec
- `../../tokens.css` — CSS variables consumed by the demo
- `../../guides/04-spacing-radii-motion.md` — motion timings
