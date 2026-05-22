# 05 · Widget design

The widget is Locto's only ambient surface. It's a 144 × 144 pt Liquid Glass tile that floats above other windows whenever the mic is active.

> Reference implementation: `components/widget/Widget.jsx`
> Helpers: `components/widget/tokens.js`
> Interactive demo: `components/widget/demo.html`

---

## Shell

| Property | Value |
|---|---|
| Size | 144 × 144 pt |
| Corner radius | 32 pt (proportionally large at this scale so the soft-tile silhouette reads) |
| Padding | 10 px vertical, 14 px horizontal |
| Position | Top-right of active screen, inset 16 pt; persists per-display once dragged |
| Window | Borderless NSPanel · `.nonactivatingPanel` · `.fullSizeContentView` · `level: .floating` · `canBecomeKey = false` |
| Material | Liquid Glass (see below) |

## Layout — two symmetric halves with one shared bar

```
TOP HALF · pace
  WPM number + small `wpm` unit (baseline-aligned)
  state label (IDEAL / TOO SLOW / TOO FAST)
  ▼  ← caret pointing down at the bar
─────────────────────  single shared bar
  ▲  ← caret pointing up, slides with mono fill edge
  monologue duration (M:SS, colon nudged up to digit optical center)
  mono label (monologue → take a pause at ≥ 1:30)
BOTTOM HALF · monologue
```

Both numbers share the same 26 pt / weight 300 / tabular treatment so they read as equal-weight signals. The shared bar is the visual axis.

## Two colour zones

The shell uses a vertical gradient that blends through the middle 30 %:

```css
background: linear-gradient(180deg,
  rgba(wpmTint)  0%,
  rgba(wpmTint) 32%,
  rgba(monoTint) 68%,
  rgba(monoTint) 100%
);
```

- **Top zone** tint reflects pace state via `paceColors(wpm)`:
  - WPM ≤ 115 → slate-blue (slow)
  - 115 < WPM < 175 → sage-green (ideal)
  - WPM ≥ 175 → warm-coral (fast)
- **Bottom zone** tint reflects monologue time via `monoColors(seconds)`:
  - 0 – 60 s: green (calm)
  - 60 – 90 s: green → gold (warming)
  - 90 – 120 s: gold → coral (urgent)
  - 120 s +: coral (sustained)

State tint alpha is **0.78** — the colour reads consistently regardless of substrate (white window, vivid photo, dark area).

## Liquid Glass material

```css
backdrop-filter: blur(40px) saturate(180%) brightness(1.04);
border: 0.5px solid rgba(255, 255, 255, 0.45);

/* Specular highlights composited above the tint */
background:
  radial-gradient(140% 60% at 50% -10%,
    rgba(255,255,255,0.24) 0%, rgba(255,255,255,0) 55%),
  radial-gradient(120% 50% at 50% 110%,
    rgba(255,255,255,0.08) 0%, rgba(255,255,255,0) 60%),
  /* …then the zone tint gradient above */;

/* 6-layer shadow */
box-shadow:
  inset 0 1px 0 rgba(255,255,255,0.55),
  inset 0 0 0 0.5px rgba(255,255,255,0.18),
  inset 0 -0.5px 0 rgba(0,0,0,0.04),
  0 16px 44px rgba(0,0,0,0.22),
  0 4px 14px rgba(0,0,0,0.10),
  0 1px 2px rgba(0,0,0,0.06);
```

The shipping macOS app uses SwiftUI `.glassEffect(.regular.tint(liveTint))`. The web demo approximates with `backdrop-filter`.

## Content treatment — softened white

Every text/bar/caret element is **softened white** so it reads on any substrate:

| Element | Color |
|---|---|
| Numbers (WPM, monologue) | `rgba(255, 255, 255, 0.94)` |
| Labels (IDEAL / MONOLOGUE) | `rgba(255, 255, 255, 0.68)` |
| `wpm` unit | `rgba(255, 255, 255, 0.55)` |
| Shared bar | `rgba(255, 255, 255, 0.62)` |
| Carets | `rgba(255, 255, 255, 0.82)` |

The colon in `M:SS` is rendered as a separate span with `translateY(-0.09em)` so it sits at the digit optical center rather than the typographic baseline.

## States

| State | Trigger | Visual |
|---|---|---|
| **Pace · Too slow** | WPM < 115 | Top tint slate-blue; WPM caret left of bar |
| **Pace · Ideal** | 115 ≤ WPM ≤ 175 | Top tint sage-green; WPM caret center |
| **Pace · Too fast** | WPM > 175 | Top tint warm-coral; WPM caret right |
| **Mono · quiet** | 0 – 60 s | Bottom green; cluster opacity 0.6 → 0.85 |
| **Mono · warming** | 60 – 90 s | Tint green → gold; opacity → 1.0 |
| **Mono · pulsing** | ≥ 90 s | Tint coral; label flips to `take a pause` (700 weight); opacity pulses 1 ↔ 0.72 over 2.5 s `easeInOut` |
| **Mono · escalated** | ≥ 120 s | Pulse widens to 1 ↔ 0.5 |
| **Idle** | user stops speaking | Whole widget `opacity: 0.5` over 700 ms `easeInOut`; WPM → `---`; mono → `-:--`; labels and carets hidden (layout preserved) |

## Hover

Hover affects **only** `transform` (lift) and `box-shadow`. Tint alpha, border alpha, blur, and brightness are constant. The widget never visually "wakes up" with a saturation jump.

```js
transform: 'translateY(-3px) scale(1.025)';
```

## Behaviour rules

- **Hysteresis:** require 3 consecutive 1-second samples on a new pace side before transitioning. Prevents flicker.
- **Hero number updates at 1 Hz.** Number change animates: fade-out 80 ms, fade-in 120 ms, 1 pt vertical drift.
- **Pace caret** interpolates over 400 ms `easeOut`.
- **Monologue clock resets** when the user yields ≥ 2.5 s.
- **Position persists per display** once the user has dragged the widget. Default top-right inset 16 pt.

## Accessibility

- VoiceOver label on appearance: `Locto: pace 152 words per minute, ideal range.`
- On state change: `Pace too fast` / `Pace too slow` / `Pace in ideal range.`
- On mono escalation: `Monologue: 90 seconds, warning level.`
- Widget is non-key (`canBecomeKey = false`); all primary actions through the menu bar dropdown.
- **Reduce Motion:** all transitions become instant.
- **Reduce Transparency:** fall back from Liquid Glass to opaque state ink at ~0.95 alpha.
- **Increase Contrast:** strengthen borders, bump body weight one step, darken state inks ~10%.
- WCAG AA contrast against tinted backgrounds. Color is never the only signal — pair with text and caret position.

## v1 omissions (deferred to v2)

- The `· avg 142` annotation (removed)
- The divider line (removed — bars are the axis)
- Filler-word strokes (deferred)
- Coach notes (deferred)
