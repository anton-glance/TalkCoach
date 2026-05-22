# 04 · Spacing, radii, motion

## 4 pt grid

Everything is a multiple of 4: `4 · 8 · 12 · 16 · 20 · 24 · 32 · 48 · 64 · 80 · 96`. Variables in `tokens.css`: `--space-1` (4 px) through `--space-24` (96 px).

- **Vertical rhythm:** 12 pt between sibling elements, 24 pt between sections.
- **Card padding:** 24 pt compact / 32 pt default / 48 pt hero.

## Radii

| Token | Px | Use |
|---|---|---|
| `--radius-sm` | 6 | small chips, menu-bar pill |
| `--radius-md` | 8 | swatches, ramp stops, inputs |
| `--radius-lg` | 12 | banners, small cards |
| `--radius-xl` | 16 | default card |
| `--radius-2xl` | 24 | reference widget rendering (320 pt) |
| `--radius-3xl` | 32 | **shipping widget at 144 pt** — proportionally larger so the soft-tile silhouette reads |
| `--radius-pill` | 999 | pills, dropdowns |

## Borders

Hairline. **0.5 px** default (renders at 1 device pixel on @2x). Color is brand teal at low opacity:

```css
--border:        rgba(15, 110, 86, 0.12);
--border-strong: rgba(15, 110, 86, 0.22);
```

Borders define surfaces — they don't decorate them. No coloured borders, no left-accent bars.

## Shadows

The system has **exactly two shadows**, both on the widget:

```css
/* widget resting */
box-shadow:
  inset 0 1px 0 rgba(255,255,255,0.55),
  inset 0 0 0 0.5px rgba(255,255,255,0.18),
  inset 0 -0.5px 0 rgba(0,0,0,0.04),
  0 16px 44px rgba(0,0,0,0.22),
  0 4px 14px rgba(0,0,0,0.10),
  0 1px 2px rgba(0,0,0,0.06);

/* widget hover (only the outer drops change) */
box-shadow:
  inset 0 1px 0 rgba(255,255,255,0.55),
  inset 0 0 0 0.5px rgba(255,255,255,0.18),
  inset 0 -0.5px 0 rgba(0,0,0,0.04),
  0 22px 56px rgba(0,0,0,0.28),
  0 6px 20px rgba(0,0,0,0.12),
  0 1px 3px rgba(0,0,0,0.08);
```

Everywhere else: **no shadow.** Cards use a hairline border on `--surface` over `--bg`. Inner shadows are not used outside the widget. Protection gradients are not used.

## Motion

### Principles

- **Calm over snappy.** Most transitions sit between 200 ms and 600 ms.
- **Easing:** `easeInOut` (`cubic-bezier(0.42, 0, 0.58, 1)`) and `easeOut` (`cubic-bezier(0, 0, 0.2, 1)`) only.
- **No springs.** No bounce, no overshoot, no wobble, no flash, no pulse outside the widget's escalated monologue state.

### Duration tokens

| Token | Duration | Use |
|---|---|---|
| `--dur-fast` | 200 ms | Hover micro-shifts, tooltips |
| `--dur-base` | 350 ms | Show / hide, panel slides |
| `--dur-slow` | 600 ms | State cross-fades, colour transitions |

### Specifics

- **State transitions cross-fade over 600 ms.** Never step-change. Hysteresis (3 consecutive 1-second samples) prevents flicker near band edges.
- **Hero numbers update at 1 Hz**, not 60 Hz. The change animates with fade-out 80 ms / fade-in 120 ms plus a 1 pt vertical drift.
- **Widget hover** affects only `transform` (lift, 280 ms easeOut) and `box-shadow`. Tint, blur, brightness, and colours stay constant.
- **Idle ↔ active** cross-fades the whole widget's `opacity` over 700 ms easeInOut.
- **Monologue escalation** past 1:30 starts a 2.5 s opacity pulse (1 ↔ 0.72). Past 2:00 the pulse widens (1 ↔ 0.5).

### Reduce Motion

Honour `prefers-reduced-motion: reduce` globally. `tokens.css` already includes:

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
  }
}
```

When enabled, replace transitions with instant changes. Honour Reduce Transparency for the Liquid Glass material (fall back to opaque state ink).
