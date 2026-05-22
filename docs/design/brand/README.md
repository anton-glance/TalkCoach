# Brand assets

Locto's identity assets — logos, mark, app icon, menu-bar template.

## Files

### `logo/` — the mark and its lockups

| File | Description | Use |
|---|---|---|
| `logo/mark.svg` | The mark on its own. `currentColor` — picks up the color of the surrounding context. | Anywhere the mark needs to inherit color from CSS / SwiftUI |
| `logo/wordmark.svg` | "locto" in Inter 500 with tight tracking, brand teal `#0F6E56` | Marketing, web header, email signatures (text-only mark) |
| `logo/lockup.svg` | Mark + wordmark together | Primary lockup for marketing, web header, presentations |

### `icons/` — the app icon and menu-bar template

| File | Description | Use |
|---|---|---|
| `icons/app-icon.svg` | 1024 × 1024 squircle (radius 229 px) filled brand teal `#0F6E56`, mark in white | Export to PNG and convert to `.icns` for App Store / Xcode asset catalog |
| `icons/menubar.svg` | 22 × 22 monochrome black with alpha | Ship as an AppKit **template** image (`isTemplate = true`); the system handles tint. Provide @1x / @2x / @3x PNG exports |

## Conventions

- All SVGs use simple geometry — two circles for the mark (`r=22, r=5.5`), one path for the wordmark glyphs.
- Default fill on `mark.svg` is `currentColor`. Set the color via the parent element.
- `app-icon.svg` and `menubar.svg` have explicit colors baked in; do not edit.

## Minimum sizes

- **Mark**: 16 px. Below this, use the simplified menu-bar version.
- **Lockup**: 80 px wide.
- **Wordmark alone**: 60 px wide.

## Clear space

Clear space around any mark is equal to the inner dot diameter (about ⅓ of the ring radius) on all sides.

## Color rules

- Mark and wordmark are **brand teal only** (`#0F6E56` / `--brand`).
- Never recolour in state inks (slate-blue / sage-green / warm-coral).
- Inverted use: the mark on a brand-teal squircle uses **white** for the mark (see `app-icon.svg`).

## Don'ts

- Don't stretch, skew, or rotate.
- Don't apply drop shadows, glows, or AI-style gradients.
- Don't recolour in state colors.
- Don't place on busy / low-contrast backgrounds without the squircle bg.

See `guides/06-iconography.md` for the full iconography philosophy.
