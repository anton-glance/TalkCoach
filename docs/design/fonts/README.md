# Fonts

Brand typefaces, vendored locally so the system works offline and doesn't depend on Google Fonts.

## Families

| Family | Use | License |
|---|---|---|
| **Inter** | UI body, labels, captions, settings copy | SIL Open Font License (see `inter/LICENSE.txt`) |
| **Inter Display** | Hero numbers, H1, anywhere ≥ 28 px — same metrics as Inter, optimised for display sizes | SIL OFL (same license as Inter) |
| **JetBrains Mono** | Hex codes, dimensions, code in this documentation only. **Does not appear in product UI.** | SIL OFL (see `jetbrains-mono/OFL.txt`) |

Inter is by Rasmus Andersson. JetBrains Mono is by JetBrains s.r.o.

## File structure

```
fonts/
├── README.md
├── inter/
│   ├── Inter-Light.woff2         ← 300
│   ├── Inter-Regular.woff2       ← 400
│   ├── Inter-Medium.woff2        ← 500
│   ├── Inter-SemiBold.woff2      ← 600
│   ├── InterVariable.ttf         ← variable font for Figma / advanced tooling
│   ├── desktop/                  ← OTF for native macOS apps, Figma desktop
│   │   ├── Inter-Light.otf
│   │   ├── Inter-Regular.otf
│   │   ├── Inter-Medium.otf
│   │   └── Inter-SemiBold.otf
│   └── LICENSE.txt
├── inter-display/
│   ├── InterDisplay-Light.woff2
│   ├── InterDisplay-Medium.woff2
│   ├── InterDisplay-SemiBold.woff2
│   └── desktop/
│       ├── InterDisplay-Light.otf
│       ├── InterDisplay-Medium.otf
│       └── InterDisplay-SemiBold.otf
└── jetbrains-mono/
    ├── JetBrainsMono-Regular.woff2
    ├── JetBrainsMono-Medium.woff2
    ├── JetBrainsMono-SemiBold.woff2
    ├── JetBrainsMono-Variable.ttf
    └── OFL.txt
```

## How they're wired up

`tokens.css` at the repo root declares `@font-face` rules pointing at the WOFF2 files. Any HTML that imports `tokens.css` gets the fonts automatically. No external network requests.

```css
/* tokens.css excerpt */
@font-face {
  font-family: 'Inter';
  font-weight: 400;
  src: url('fonts/inter/Inter-Regular.woff2') format('woff2');
}
@font-face {
  font-family: 'Inter Display';
  font-weight: 500;
  src: url('fonts/inter-display/InterDisplay-Medium.woff2') format('woff2');
}
/* …etc */
```

In code, prefer the CSS-variable fallback stack instead of hard-coding font names:

```css
--font-sans: 'Inter Display', 'Inter', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
--font-mono: 'JetBrains Mono', 'SF Mono', Menlo, monospace;
```

## Type system rules

| Surface | Family |
|---|---|
| Body, labels, settings, microcopy | Inter (400 / 500) |
| Hero numbers in the widget | Inter Display 300 (tabular nums on) |
| H1, large display | Inter Display 500 |
| Hex codes / specs in docs | JetBrains Mono 400 |

Tabular figures (`font-feature-settings: 'tnum'`) are mandatory anywhere a number appears. Inter's `ss01` and `cv11` stylistic sets are on by default in `tokens.css`.

See `guides/03-color-and-type.md` for the full type ramp.

## Licensing notes

- Both Inter and JetBrains Mono are **SIL OFL** licensed — free to use, modify, and redistribute. License files ship in each family's folder.
- Both fonts can be embedded in apps, exported to PDF, and used in commercial work.
- Keep the LICENSE / OFL files in place when distributing.
