# 06 · Iconography

Locto has **almost no icons** by design. The product's visual interest comes from state colours and the data signature (the hero number, the pace bar), not iconography. Resist adding decorative icons anywhere.

## Brand mark

The Locto mark is a single ring with a centered dot. Two SVG sources ship:

| File | Use | Notes |
|---|---|---|
| `brand/logo/mark.svg` | The mark in `currentColor` | For inline use; pick the colour via CSS / SwiftUI |
| `brand/icons/menubar.svg` | 22 × 22 monochrome black, AppKit template image | Ship as `template` so AppKit handles tint |

The mark and the product UI are deliberately two visual languages: **the mark is brand, the UI is function**.

## No decorative icons

- Settings, the widget, marketing — none get a "gear" or "mic" or "play" icon as decoration.
- The widget shows colours and numbers, not symbols.
- Marketing surfaces use brand teal on warm-bone backgrounds; no illustration, no infographic glyphs.

## System icons (only where unavoidable)

- **macOS Settings** uses **SF Symbols** (`gear`, `lock`, `mic`, `xmark`, `chevron.right`) where they are functionally necessary. Match weight and size to surrounding type.
- **Outside macOS** (web, this design system preview, slides, marketing) substitute **Lucide** at 1.5 px stroke / 24 px viewBox — same line-icon discipline, same hairline feel. Approximate mappings:

| SF Symbol | Lucide equivalent |
|---|---|
| `gear` | `settings` |
| `lock` | `lock` |
| `mic` | `mic` |
| `xmark` | `x` |
| `chevron.right` | `chevron-right` |

Flag the substitution in a comment if pixel-perfect SF rendering is required.

## No emoji, no unicode-as-icons

- **No emoji.** Ever.
- The few unicode characters used (`·`, `…`, `—`, `→`) are **typography**, not iconography. The `→` in `Open System Settings →` is a link affordance, not an icon.

## Logo files

| File | Purpose | Source |
|---|---|---|
| `brand/logo/mark.svg` | Mark in `currentColor` | Vector |
| `brand/logo/wordmark.svg` | `locto` wordmark in teal-600, Inter 500 tight | Vector |
| `brand/logo/lockup.svg` | Mark + wordmark together | Vector |
| `brand/icons/app-icon.svg` | 1024 × 1024 squircle on teal-600, mark in white | Export PNG/ICNS for App Store |
| `brand/icons/menubar.svg` | 22 × 22 monochrome black template | Ship @1x / @2x / @3x for AppKit |

## Clear space and minimum sizes

- Minimum mark size: **16 px** (use the menu-bar simplified version below this — no inner ring detail).
- Clear space around the mark: equal to the mark's inner dot diameter on all sides.

## Don'ts

- Don't stretch, skew, or rotate the mark — proportions are fixed.
- Don't apply drop shadows, glows, or AI-style gradients to the mark.
- Don't recolour the mark in state colors (blue / green / coral). Brand only.
- Don't place the mark on busy or low-contrast backgrounds without the squircle app-icon container.
