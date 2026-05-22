# 03 · Color and type

All values referenced here live in `tokens.css` as CSS variables. Use the variables, not the hex codes.

## Two palettes, never mixed

| Palette | Use | Variable prefix |
|---|---|---|
| **Brand teal** | Identity (logo, menu-bar icon after monochrome conversion, App Store, marketing web) | `--teal-*`, `--brand`, `--brand-light` |
| **State inks** | In-product feedback inside the widget only | `--slow-*`, `--ideal-*`, `--fast-*` |

The brand color is reserved for identity. State colors are reserved for feedback. Never use a state color for identity, and never use brand teal to imply a pace state.

## Brand teal ramp

```
50  #E1F5EE    light surface, halo
100 #9FE1CB
200 #5DCAA5    ink on dark teal
400 #1D9E75
600 #0F6E56    primary brand     ← --brand
800 #085041
900 #04342C    ink on light surfaces
```

## State palette

Each pace state has a soft `bg-1`, a slightly stronger `bg-2`, and a dark `ink` for text on the fill. The pace gradient interpolates between three "stop" colors (slow → ideal → fast).

| State | bg-1 | bg-2 | ink | stop |
|---|---|---|---|---|
| Too slow (slate blue) | `#AAC3DF` | `#80A5D5` | `#1E3A5F` | `#6E94BD` |
| Ideal (sage green) | `#ACD9C0` | `#86C3A5` | `#1F4A3A` | `#6BA079` |
| Too fast (warm coral) | `#E6AFA2` | `#DC8E7A` | `#5C2C1F` | `#C58968` |

## Pace gradient — the rule for any pace viz

```css
background: linear-gradient(90deg,
  #6E94BD 0%,   /* slow  */
  #6BA079 50%,  /* ideal */
  #C58968 100%  /* fast  */
);
```

Same stops, same direction, every time. Never substitute a different gradient for the pace bar. Variable: `--gradient-pace`.

## Monologue colour stages

The widget's bottom zone uses a separate progression tied to elapsed monologue seconds (see `components/widget/tokens.js → monoColors(seconds)`):

| Time | Tint | Notes |
|---|---|---|
| 0 – 60 s | green (matches ideal) | calm |
| 60 – 90 s | green → gold | warming up |
| 90 – 120 s | gold → coral | urgent |
| 120 s + | coral (sustained) | keep raising |

## Neutrals

```
--bg          #FAF8F2   warm bone — page background
--surface     #FFFFFF   card surface
--surface-2   #F5F3EC   recessed surface, code blocks
--text-primary   #1F2937
--text-secondary #5F5E5A
--text-tertiary  #9C9A93
```

## Type

**One typeface family:** Inter + Inter Display + JetBrains Mono.

| Family | Weights | Use |
|---|---|---|
| **Inter** | 300 / 400 / 500 / 600 | UI body, labels, captions, settings copy |
| **Inter Display** | 300 / 500 / 600 | Hero numbers, H1 (≥ 28 px sizes); same metrics as Inter, tuned for display |
| **JetBrains Mono** | 400 / 500 / 600 | Hex codes, dimensions, code in **this documentation only** — does not appear in product UI |

Tabular figures (`tnum`) are mandatory anywhere a number appears. Inter's stylistic sets `ss01` and `cv11` are on by default.

## Type ramp

| Token | Size | Weight | Tracking | Use |
|---|---|---|---|---|
| `--fs-hero` / `.t-hero` | 88 px (web ref) / 26 px (in widget) / 36 px (mono number) | 300 | -3 px (web), -1.3 px (widget) | The signature: single primary metric |
| `--fs-h1` / `h1` | 40 px | 500 | -1.4 px | Page title, marketing hero |
| `--fs-h2` / `h2` | 24 px | 500 | -0.6 px | Section title |
| `--fs-h3` / `h3` | 19 px | 500 | -0.4 px | Subsection |
| `--fs-body` / `p` | 15 px | 400 | 0 | Body |
| `--fs-caption` / `.t-caption` | 13 px | 400 | 0 | Caption, secondary text |
| `--fs-tab` / `.t-tab` | 11 px | 500 | 0.12em uppercase | Tabular label, eyebrow |
| `--fs-mono` / `.t-mono` | 12 px | 400 | 0 | Code, hex, specs |

## Backgrounds and imagery

- **No imagery** in product UI. No photos, illustrations, stock backgrounds.
- **No full-bleed gradients** outside the widget. Page background is `--bg` (warm bone); surfaces are `--surface` (white).
- The widget uses **Liquid Glass** material — tint at low alpha over backdrop blur, plus specular highlights. See `05-widget-design.md`.
- **No repeating patterns, no textures, no grain.** The brand is calm — texture would be noise.

## Color used outside the widget

- **Marketing / web hero:** brand teal `#0F6E56` on warm-bone `#FAF8F2`. Avoid cool blue casts; never grain or film effects. Imagery feeling: *calm office light, warm-neutral, midday.*
- **Coach notes (v2 only):** sage-green leading dot for positive observations, slate-blue for tells. No reds.
- **Permission banner (warm-coral surface):** `linear-gradient(160deg, #E6AFA2 → #DC8E7A)` with `#5C2C1F` ink and a 0.5 px coral-ink border.

## Accessibility

- Minimum contrast: WCAG AA against widget's tinted Liquid Glass backgrounds.
- Honour Reduce Transparency: fall back from Liquid Glass to a solid state ink at ~0.95 alpha.
- Honour Increase Contrast: boost borders, increase text weight one step (e.g. 400 → 500), darken state inks ~10%.
- Color is never the only signal — pair with text and position. Color-blind users (especially deuteranopia) see slate-blue and sage-green similarly.
