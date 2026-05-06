# docs/design — Locto visual + brand reference

This folder is the visual and brand reference for the Locto v1 widget and Settings surfaces. Adopted Session 018 (see `01_PROJECT_JOURNAL.md`).

## Files

- **`01-design-spec.md`** — behavior, IA, motion, accessibility, edge-case treatments. Implementation-facing companion to the brand guidelines HTML. Read this when implementing the widget, Settings, or any user-facing surface.
- **`02-brand-guidelines.html`** — visual identity (colors, type, components in isolation). Open in any browser. Visual source of truth for hex values, type ramp, and brand component specs.
- **Brand SVG assets** — `locto-mark.svg`, `locto-menubar.svg`, `locto-app-icon.svg`, `locto-wordmark.svg`, `locto-lockup.svg`. Vector sources; export to PNG/PDF/ICNS as needed for production use.

## Naming

The user-facing product name is **Locto**. The repository, Xcode scheme, and bundle identifier (`com.talkcoach.app`) retain the working name `TalkCoach` for v1; renaming the codebase is deferred until after v1 launch. Any user-visible string (App name in About, Info.plist usage descriptions, menu items, Settings titles, marketing copy) uses Locto. Any internal reference (build settings, source code identifiers, signing identity) uses TalkCoach.

## Precedence (locked Session 018)

When this folder's content conflicts with another project doc, resolve as follows:

1. `02_PRODUCT_SPEC.md` wins on **content scope** — what features ship in v1, what's deferred. This folder includes Locto reference components for fillers, coach notes, dashboard tabs, etc.; those are deferred to v2.0 per the spec and are NOT in v1 scope. Each is annotated in `02-brand-guidelines.html` with a "deferred to v2.0" banner.
2. `03_ARCHITECTURE.md` wins on **technical architecture** — modules, data flow, persistence, transcription. This folder may reference architectural choices (e.g., SQLite/GRDB) carried over from the source Locto package; those are overridden by our Architecture Y (SwiftData, Apple SpeechAnalyzer + Parakeet via Core ML).
3. `01-design-spec.md` and `02-brand-guidelines.html` win on **visual and brand specifics** — palette ink colors, type ramp, motion timings, voice/tone for user-facing copy, brand component visual rules.

## What's superseded

The earlier `design/` directory at the project root (referenced in `03_ARCHITECTURE.md` before Session 018) is superseded by this folder for visual specifics. The visual decisions that survive from Session 014 and remain authoritative are kept in `03_ARCHITECTURE.md` §8 (FloatingPanel) and §Design Reference:

- **Widget size: 144 × 144 pt** (NOT the 320 × 320 pt the Locto reference suggests)
- **Widget material: Liquid Glass with state ink tint and hover saturation shift** (NOT solid pastel gradients)
- **Widget visibility: persistent during mic-active session with "Listening…" placeholder** (NOT show-on-first-token / hide-on-mic-off)
- **Monologue indicator** (v1.x feature — extension to the brand component set, not in the Locto reference)

Anything else from the prior `design/` directory is superseded by the Locto-derived design tokens (palette ink colors, Inter type stack, motion principles, voice rules) in `02-brand-guidelines.html`.

## Adoption history

- **Session 014** — Aggressive scope reduction. Widget shell decisions (144pt size, Liquid Glass material, hover saturation) locked.
- **Session 013** — Persistent visibility + "Listening…" + dismissal flow locked. Widget stays visible for the entire mic-active session.
- **Session 018** — Locto brand package adopted as visual reference (this folder). Filler tracking and repeated-phrase detection deferred to v2.0. Locto used as user-facing product name.

## Source

The source Locto package was produced by an external design effort and uploaded to this project in Session 018 as visual + brand reference. Files in this folder are adapted versions, with project-specific overrides surfaced inline (see the "Scope & precedence" section at the top of `02-brand-guidelines.html`).
