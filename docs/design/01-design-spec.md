# 01 · Design spec — Locto v1

This is the implementation-facing companion to `docs/design/02-brand-guidelines.html`. The brand doc covers visual identity (colors, type, components in isolation). This doc covers behavior, layout, motion, accessibility, and edge cases — what those components do once they're stitched into the app.

For any visual question (hex value, type size, padding) defer to the brand doc. If the two conflict, the brand doc wins on visual specifics; if either conflicts with `02_PRODUCT_SPEC.md` or `03_ARCHITECTURE.md`, those win on content scope and technical architecture.

> **Naming:** the user-facing product name is **Locto**. The repository, Xcode scheme, and bundle identifier (`com.talkcoach.app`) retain the working name `TalkCoach` for v1. Wherever this doc refers to product behavior the user sees, use Locto. See `02_PRODUCT_SPEC.md` for the full naming policy.

---

## Provenance

This package is adapted from the Locto reference design package (uploaded Session 018) with the following project-specific overrides locked in `03_ARCHITECTURE.md` Design Reference section:

- **Widget size: 144 × 144 pt** (locked Session 014). The Locto reference suggests 320 × 320 pt; we keep the smaller, peripheral-vision-friendly size from Session 014's "Path C" scope reduction.
- **Widget material: Liquid Glass** with hover saturation shift (locked Session 014, reaffirmed Session 018). The Locto reference uses solid pastel gradients; we use the macOS Liquid Glass material tinted with the state ink colors.
- **Persistent visibility + "Listening…" placeholder + dismissal flow** (locked Session 013, reaffirmed Session 018). The widget appears when mic is active and stays for the entire mic-active session, even when no speech is detected. The Locto reference suggests show-on-first-token; we don't, because a widget that disappears on silence creates anxiety ("did it crash?").
- **Monologue indicator** (v1.x feature, M4.5 + M5.6). Extension to the brand component set; not in the Locto reference package.
- **Filler-word components removed.** Filler tracking is deferred to v2.0 (Session 018). The Locto reference includes filler-stroke components and a top-3 filler list on the widget; v1 has neither.

What stays straight from Locto: brand teal `#0F6E56`, full state palette (slate-blue / sage-green / warm-coral inks), Inter type stack, hero number treatment, voice/tone rules, motion principles (calm, 200–600ms, easeInOut/easeOut, no spring), brand mark/wordmark assets.

---

## Information architecture

### Surfaces

| Surface | Type | When shown |
|---|---|---|
| Menu bar icon | NSStatusItem | Always (after launch) |
| Menu bar dropdown | NSMenu attached to status item | On click |
| Ambient widget | Floating NSPanel (utility window) | When mic is active |
| Settings | AppKit `NSWindow` containing SwiftUI `NSHostingController` | On Cmd-, , menu item, or auto-opened on first launch |
| Permission prompts | OS-native dialogs | First time mic / speech access needed |

### Navigation

There is no global tab bar or sidebar. The app has three modes the user moves between:

1. Background (menu bar only present)
2. Active session (widget visible)
3. Configuration (Settings open)

These never coexist as competing primary surfaces. The widget can stay open while Settings is open, but Settings is the primary attention surface in that case.

There is no Dashboard window in v1 (Session 014 scope reduction). The post-session metrics dashboard with rich analysis returns in v2.0 alongside filler tracking and other deferred analytics.

---

## Layout system

- **Grid:** 4 pt base unit. All padding, margins, and gaps are multiples of 4 pt (4, 8, 12, 16, 20, 24, 32, 48, 64, 80, 96).
- **Card padding** (Settings cards if added later): 16 pt compact / 24 pt default.
- **Vertical rhythm:** 12 pt between sibling elements, 24 pt between sections.

---

## Window specifications

### Ambient widget

- **Size:** 144 × 144 pt at 1× scale. Resizing disabled. Locked Session 014 — smaller than Locto's reference 320pt because Locto's larger size is a marketing-screenshot consideration; v1's widget is for peripheral-vision glance during a call, not a feature display.
- **Window style:** borderless `NSPanel` with `.nonactivatingPanel`, `.utilityWindow`-equivalent style mask plus `.fullSizeContentView`. `level: .floating` so it stays above ordinary app windows. `collectionBehavior: [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`. `canBecomeKey = false`, `canBecomeMain = false`.
- **Position:** top-right corner of the active screen by default. Inset 16 pt from screen edges. Position persists per-display once dragged (M2.6).
- **Background:** Liquid Glass material with state-specific tint applied. Tint colors are the brand state inks (slate-blue / sage-green / warm-coral) at low alpha; the Liquid Glass material provides the depth and translucency. NOT solid pastel gradients (departure from Locto reference).
- **Corner radius:** 32 pt. Locto's reference is 24pt; we use 32pt because at our smaller 144pt size the radius needs to be proportionally larger to read as the "soft tile" silhouette the brand wants.
- **Padding:** 16 pt all sides (proportional to size — Locto's 24pt at 320pt scales down).
- **Shadow:** subtle, system-default for floating panels. SwiftUI draws it; the NSPanel itself has `hasShadow = false`.
- **Click-through:** clickable everywhere; no specific drag handle, the whole surface is draggable via `isMovableByWindowBackground = true`.
- **Show:** fade in over 0.35s with a 4 pt y-offset. Easing: `easeInOut`. Clamp to instant when Reduce Motion is on.
- **Hide:** fade out over 0.35s, no translate. Easing: `easeInOut`. Triggered 5 seconds after mic deactivates per `02_PRODUCT_SPEC.md`.
- **Hover state:** alpha 0.42 → 0.62, border 0.55 → 0.78, scale 1.025, translateY -3pt. The only intentional attention-grab in the widget surface — locked Session 018: more saturated on hover, intentionally inviting interaction.

### Settings

- **Format:** standalone AppKit `NSWindow` (not SwiftUI `Window` scene — see `03_ARCHITECTURE.md` §10 for the LSUIElement rationale). 520 × 600 pt, `styleMask: [.titled, .closable, .resizable]`.
- **Sections (v1):**
  - **Languages** — locale picker (50 locales, max 2 selection, system locale silent-commit on first launch)
  - **Speaking Pace** — placeholder in v1; M6.2 adds the WPM band slider
  - ~~Filler Words~~ — removed Session 018; returns in v2.0

### Onboarding

There is no full onboarding flow in v1 (Session 014 scope reduction). First-launch experience is: app launches → Settings auto-opens with the language picker → user picks 1–2 languages → user dismisses Settings → on next mic activation, system prompts for mic + speech recognition permission (point-of-use, not pre-emptive). Total user actions: 1 (language pick) + 2 (permission grants) = 3, with the language step counting as the FM3 "one question" and the two permission grants counting as FM3's "mic permission grant at first session start".

---

## Component specs (behavior, not visuals)

For visual specs of every component below, see `docs/design/02-brand-guidelines.html`. Below are the behaviors and states the brand doc doesn't cover.

### Hero number block

- Updates at 1 Hz on the widget (not 60 Hz). Number ticking at 60 Hz looks twitchy and is hard to read. 1 Hz feels intentional and is consistent with the "calm" motion principle.
- Animation when number changes: fade-out 80 ms, fade-in 120 ms with a 1-pt vertical drift. Easing: `easeInOut`.
- Tabular figures (`tnum`) are mandatory — without them the digits jitter laterally as values change.
- When pace data is unavailable (first 3 seconds of session, or after a long pause): show `--` in the same hero treatment, no animation.
- Listening state (mic active, no speech yet): show `--` plus a "Listening…" caption below the number in the brand secondary text color (FM2 — never show "0 wpm" because zeros imply you're at 0 WPM, which is misleading).

### Pace bar

- Indicator triangle position interpolates over 400 ms when pace changes, with `easeOut` easing.
- Indicator left/right anchors: at 0% (slowest), `transform: translateX(0)`; at 100% (fastest), `transform: translateX(-100%)`. Center positions translate to `-50%`. Prevents the triangle from overhanging the track edges.
- Pace-to-position mapping: linear. WPM band is configurable in Settings; defaults are 130 wpm (lower) and 170 wpm (upper). The bar visually extends from 80 wpm at 0% to 200 wpm at 100% so the user can see how far above/below their band they're sitting. Clamp outside this range.
- Triangle color is the active state's ink color from the brand palette.

### State indicator (text label)

- State labels (sentence case): `Too slow` · `Ideal` · `Too fast`. NOT all-caps — Locto's reference uses sentence case to feel calm rather than commanding.
- State boundaries (default, configurable in Settings):
  - Too slow: < `wpmTargetMin` (default 130 wpm)
  - Ideal: `wpmTargetMin` ≤ wpm ≤ `wpmTargetMax` (default 130–170)
  - Too fast: > `wpmTargetMax` (default 170 wpm)
- Hysteresis: don't flip state on a single sample crossing the boundary. Require 3 consecutive 1-second samples on the new side before transitioning. Prevents flicker (FM1 — destructive UI).
- Background tint cross-fade: 600 ms `easeInOut` between states, applied as a state ink color tint over the Liquid Glass material.
- Average reference suffix: `· avg <N>` in the brand tertiary text color, lowercase "avg".

### Monologue indicator (v1.x — M4.5 + M5.6, design preview)

- Appears at 60s of uninterrupted speaking (soft cue), strengthens at 90s (warning) and 150s (urgent).
- Visual treatment per FM1: gradual color/intensity transitions over 600ms, no flash, no pulse.
- Disappears when monologue clock resets (user yields ≥2.5s or genuinely stops).
- Treatment options under exploration (locked at M5.6): subtle border color shift, a small bar that grows along an edge of the widget, or an icon-mark beside the state label. Final choice based on FM1 testing — the constraint is "must be ignorable while you continue speaking, must be discoverable when you next glance at the widget."
- Text-only fallback for accessibility / Reduce Transparency: a string in the secondary text area like `2 min monologue` that's announced by VoiceOver.

### Coach notes (deferred to v2.0)

Locto reference includes coach notes as a primary dashboard component (state-colored leading dot, 14 pt medium-weight title, 13 pt secondary body, max 3 per session). v1 has no dashboard surface and no coach notes; the component spec is preserved here for v2.0.

### Filler-word strokes (deferred to v2.0)

Locto reference includes vertical-stroke filler counts as the data signature on both widget and dashboard. v1 has no filler tracking (Session 018). The component spec is preserved in `02-brand-guidelines.html` for v2.0 implementation; any v1 production code that imports it should be flagged in review.

### Tab bar (no v1 surface needs it)

The Locto reference's tab bar is a dashboard component. v1 has no dashboard. Spec preserved in `02-brand-guidelines.html` for v2.0.

---

## Motion principles

- **Calm over snappy.** This is an ambient app — motion should fade, not pop. Most transitions sit between 200 ms and 600 ms.
- **Easing:** prefer `easeInOut` and `easeOut`. Avoid spring curves (they imply playfulness; Locto is calm).
- **Reduced Motion:** honor `accessibilityReduceMotion`. When enabled, replace all transitions with instant changes (`.animation(nil)`).
- **No bounce, no overshoot, no wobble.** Sub-200 ms transitions are unnecessary; sub-100 ms transitions look like jank.

---

## Accessibility

- **VoiceOver labels** on every meaningful element. The widget should announce on appearance: "Locto: pace 152 words per minute, ideal range." On state change: "Pace too fast" / "Pace too slow" / "Pace in ideal range." On monologue level escalation (v1.x): "Monologue: 90 seconds, warning level."
- **Keyboard shortcuts:** the widget is non-key (`canBecomeKey = false`); all primary actions are accessible via the menu bar dropdown.
- **Color is never the only signal.** State is conveyed by color *and* the text label *and* the indicator position. Don't rely on color alone — color-blind users (especially deuteranopia) will see slate-blue and sage-green similarly.
- **Minimum contrast:** WCAG AA against the widget's tinted Liquid Glass backgrounds. Verify per state in `02-brand-guidelines.html` swatches.
- **Reduce Transparency:** when enabled, fall back from Liquid Glass to a solid color in the state ink at high opacity (e.g. 0.95). The Liquid Glass material is the medium, not the message — losing it shouldn't lose the state signal.
- **Increase Contrast:** boost border opacity, increase text weight one step (e.g., body 400 → 500), darken state ink colors by ~10%.
- **Touch targets:** any clickable area ≥ 32 × 32 pt. Right-click menu items ≥ 24 pt tall.
- **Focus rings:** N/A on the widget (non-key window). On Settings, visible 2 pt brand teal focus rings; honor system "Increase contrast" setting.

---

## Light / dark mode

- **MVP is light-only.** Dark mode is v1.x or v2 (per `04_BACKLOG.md`'s deferred features list).
- The menu bar icon is monochrome template (works in both modes immediately — system handles tint).
- Widget and Settings: light mode only at MVP. Liquid Glass material naturally adapts to system appearance somewhat, but state ink colors are calibrated for light only in v1.

---

## Microcopy

The voice section of the brand doc covers tone. Specific strings the v1 app needs:

### Widget

- State labels: `Too slow` · `Ideal` · `Too fast`
- Avg reference: `· avg <N>` (lowercase "avg")
- Listening placeholder: `Listening…` (when mic active but no speech yet, or after a long pause)
- Monologue indicator (v1.x): `<N> min monologue` for the text-only fallback; visual treatment otherwise

### Menu bar

- App name in About: `Locto`
- Menu items: `About Locto`, `Pause Coaching` / `Resume Coaching`, `Check Permissions`, `Settings…`, `Quit Locto`

### Settings

- Window title: `Locto Settings`
- Languages section: `Languages`
- Speaking Pace section: `Speaking Pace`
- Permission missing banner: "Locto needs microphone access to listen to your speech. **Open System Settings →**"

### System / About

- App name: `Locto`
- Tagline (for App Store, marketing): `Speak in your sweet spot.`
- Description (one-liner): `An ambient AI speech coach for Mac.`

---

## Edge case visuals

- **Permission denied banner:** light coral surface, dark coral text, 0.5 pt border, 12 pt radius, 16 pt padding, "Open System Settings →" link in primary text color. (Hex values per `02-brand-guidelines.html` state palette ramp.)
- **Loading state:** subtle 1-second pulse on the affected card; no spinner.
- **Error state:** inline message in card, no modal alerts unless data loss is at risk.
- **Empty session list (v2.0 dashboard):** centered illustration (the mark, 64 pt, at 30% opacity) with empty-state copy below.

---

## Iconography

The app uses very few icons. Where icons appear:

- Menu bar: the Locto mark (template image, 22×22 pt)
- Settings: SF Symbols where appropriate (gear, lock, mic). Match weight and size to surrounding type.

Do not introduce decorative icons. The product's visual interest comes from the state colors and the data signature (the hero number, the pace bar), not iconography.

---

## Testing checklist (v1 widget)

Self-test against this list before declaring Phase 5 complete (per `07_RELEASE_PLAN.md`):

- [ ] Widget appears in correct corner of correct screen on mic activation
- [ ] Widget stays visible for the entire mic-active session, including silent stretches
- [ ] "Listening…" placeholder shows when no speech detected; no zeros-as-values
- [ ] Hero number updates at 1 Hz, tabular figures, no lateral jitter
- [ ] Pace bar caret slides smoothly (400 ms easeOut), never overhangs the track
- [ ] State transitions cross-fade over 600 ms, no step changes, no flashing
- [ ] Hysteresis prevents flicker around band edges (3-sample requirement)
- [ ] Hover state: more saturated, slight scale/translate, fully reversible
- [ ] Drag-to-move works; position persists per-display
- [ ] Dismiss confirmation prompt appears on close affordance click
- [ ] Dismissal scoped to current session (re-appears next mic activation)
- [ ] 5-second hold after mic deactivates, then 0.35s fade-out
- [ ] Reduce Motion: all transitions become instant
- [ ] Reduce Transparency: Liquid Glass falls back to high-opacity state ink
- [ ] Increase Contrast: borders strengthen, ink darkens
- [ ] VoiceOver announces state changes correctly
- [ ] FM1: nothing on the widget pulls peripheral attention when nothing actionable changed during a 30-min real call
