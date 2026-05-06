# 02 · Design spec

This is the implementation-facing companion to `brand/locto-brand-guidelines.html`. The brand doc covers visual identity (colors, type, components in isolation). This doc covers behavior, layout, motion, accessibility, and edge cases — what those components do once they're stitched into the app.

For any visual question (hex value, type size, padding) defer to the brand doc. If the two conflict, the brand doc wins.

## Information architecture

### Surfaces

| Surface | Type | When shown |
|---|---|---|
| Menu bar icon | NSStatusItem | Always (after launch) |
| Menu bar dropdown | NSMenu attached to status item | On click |
| Ambient widget | Floating NSPanel (utility window) | When mic is active and speech detected |
| Dashboard | Standard NSWindow | On click of widget or menu bar item |
| Settings | Sheet attached to dashboard, or standalone preferences window | On Cmd-, or menu item |
| Onboarding | Modal full-window flow | First launch only, until completed |
| Permission prompts | OS-native dialogs | First time mic / accessibility access needed |

### Navigation

There is no global tab bar or sidebar. The app has three modes the user moves between:

1. Background (menu bar only present)
2. Active session (widget visible)
3. Reflection (dashboard open)

These never coexist as competing primary surfaces. The widget can stay open while the dashboard is open, but the dashboard is the primary attention surface in that case.

## Layout system

- **Grid:** 4 pt base unit. All padding, margins, and gaps are multiples of 4 pt (4, 8, 12, 16, 20, 24, 32, 48, 64, 80, 96).
- **Card padding:** 24 pt compact / 32 pt default / 48 pt hero.
- **Vertical rhythm:** 16 pt between sibling cards, 32 pt between sections, 64 pt between major regions.
- **Window content max-width:** dashboard content area should max out at ~1100 pt and center horizontally on wider displays (Macs go up to 6K — content shouldn't span the full width).

## Window specifications

### Ambient widget

- **Size:** 320 × 320 pt at 1× scale. Resizing disabled.
- **Window style:** borderless `NSPanel` with `.nonactivatingPanel`, `.utilityWindow` style mask. Floating at `.floating` window level so it stays above ordinary app windows.
- **Position:** top-right corner of the active screen by default. Inset 16 pt from screen edges. Position persists per-display once dragged.
- **Background:** rounded rectangle, 24 pt corner radius, the state-specific 160° linear gradient from the brand palette.
- **Padding:** 24 pt all sides.
- **Shadow:** subtle, system-default for floating panels (do not add custom drop shadows that fight the OS).
- **Click-through:** clickable everywhere; no specific drag handle, the whole surface is draggable.
- **Show:** fade in over 240 ms with a slight (4 pt) downward translate from above. Easing: `easeOut`.
- **Hide:** fade out over 320 ms, no translate. Easing: `easeIn`.

### Dashboard

- **Default size:** 1100 × 760 pt. Resizable. Minimum 880 × 560 pt.
- **Window style:** standard NSWindow with title bar hidden (`titlebarAppearsTransparent = true`, `titleVisibility = .hidden`). Traffic-light buttons visible in top-left.
- **Background:** brand `#FAF8F2` (cream).
- **Tab bar:** 56 pt tall, centered horizontally, sits at top of window content. Tabs use the brand tab-bar component.
- **Card region:** centered horizontally, max 1024 pt wide, 24 pt outer padding from window edges.

### Settings

- **Format:** sheet attached to dashboard preferred over standalone window. 480 × auto pt sized to content.
- **Sections:** General · Permissions · Filler words · Privacy · About.

### Onboarding (first launch)

- **Format:** standalone window, 720 × 480 pt, non-resizable.
- **Steps:**
  1. Welcome — what Locto is in 2 sentences. CTA: "Get started."
  2. Permissions — request microphone access with explainer. CTA: "Grant access" → triggers OS prompt. After granted: "Continue."
  3. Detection mode — explain auto-trigger, ask for accessibility permission if needed. CTA: "Grant access."
  4. Test — open any app with mic, see the widget appear. CTA: "Try it" with live preview, then "Continue."
  5. Done — single screen, "You're set up." CTA: "Open Locto."

## Component specs (behavior, not visuals)

For visual specs of every component below, see `brand/locto-brand-guidelines.html`. Below are the behaviors and states the brand doc doesn't cover.

### Hero number block

- Updates at 1 Hz (not 60 Hz). Number ticking at 60 Hz looks twitchy and is hard to read. 1 Hz feels intentional.
- Animation when number changes: fade-out 80 ms, fade-in 120 ms with a 1-pt vertical drift. Easing: `easeInOut`.
- Tabular figures (`tnum`) are mandatory — without them the digits jitter laterally as values change.
- When pace data is unavailable (first 3 seconds of session, or after a long pause): show `--` in the same hero treatment, no animation.

### Pace bar

- Indicator triangle position interpolates over 400 ms when pace changes, with `easeOut` easing.
- Indicator left/right anchors: at 0% (slowest), `transform: translateX(0)`; at 100% (fastest), `transform: translateX(-100%)`. Center positions translate to `-50%`. (Prevents the triangle from overhanging the track edges.)
- Pace-to-position mapping: linear. 80 wpm → 0%, 200 wpm → 100%. Clamp outside this range.
- Triangle color is the active state's ink color from the brand palette.

### Filler-word strokes

- Increment animation: when a stroke is added, fade-in 200 ms from opacity 0 with a 2-pt rightward translate.
- Maximum strokes per row before truncation: 12. Beyond that, show `||||||| 12+` with the count.
- Reordering: top three filler words shown in widget. If a different word becomes top-three mid-session, animate the row swap over 400 ms with `easeInOut`.
- Font: monospace (`JetBrains Mono` or system mono fallback), 18 pt, weight 600, letter-spacing -1.

### Coach notes

- Generated once at session end, not in real time.
- Each note: state-colored leading dot (sage for positive observations, slate-blue for tells/issues), 14 pt medium-weight title, 13 pt secondary body.
- Maximum 3 notes per session. If the underlying analysis produces more candidates, rank by salience and truncate.
- Notes wrap to 2 lines max in the dashboard view; full text accessible on hover (NSToolTip).

### Widget state transitions

- State boundaries (default, configurable in settings later):
  - Too slow: < 110 wpm
  - Ideal: 110–180 wpm
  - Too fast: > 180 wpm
- Hysteresis: don't flip state on a single sample crossing the boundary. Require 3 consecutive 1-second samples on the new side before transitioning. Prevents flicker.
- Background gradient cross-fade: 600 ms `easeInOut` between states.

## Motion principles

- **Calm over snappy.** This is an ambient app — motion should fade, not pop. Most transitions sit between 200 ms and 600 ms.
- **Easing:** prefer `easeInOut` and `easeOut`. Avoid spring curves (they imply playfulness; Locto is calm).
- **Reduced Motion:** honor `accessibilityReduceMotion`. When enabled, replace all transitions with instant changes (`.animation(nil)`).
- **No bounce, no overshoot, no wobble.** Sub-200 ms transitions are unnecessary; sub-100 ms transitions look like jank.

## Accessibility

- **VoiceOver labels** on every meaningful element. The widget should announce on appearance: "Locto: pace 152 words per minute, ideal range." On state change: "Pace too fast" / "Pace too slow" / "Pace in ideal range."
- **Keyboard shortcuts:** all primary actions accessible via keyboard. See user-flow doc.
- **Color is never the only signal.** State is conveyed by color *and* the text label *and* the indicator position. Don't rely on color alone — color-blind users (especially deuteranopia) will see slate-blue and sage-green similarly.
- **Minimum contrast:** WCAG AA against the widget's gradient backgrounds. Verify in `brand/locto-brand-guidelines.html` — the documented ink colors meet AA against their stated backgrounds.
- **Touch targets:** any clickable area in the dashboard ≥ 32 × 32 pt. Right-click menu items ≥ 24 pt tall.
- **Focus rings:** visible, 2 pt, brand teal. Honor system "Increase contrast" setting.

## Light / dark mode

- **MVP is light-only.** See `04-build-phases.md` — dark mode lands in v1.1.
- The menu bar icon is monochrome template (works in both modes immediately).
- Dashboard, widget, settings: light mode only at MVP. Surface in onboarding "Dark mode coming in v1.1."
- When dark mode lands: state-color backgrounds invert to darker variants of the same hue family (slate ramp 800, sage 800, coral 800), ink colors shift to the lighter end of each ramp. Specifics are part of the v1.1 design spec, not this doc.

## Microcopy

The voice section of the brand doc covers tone. Specific strings the app needs:

### Widget

- State labels: `Too slow` · `Ideal` · `Too fast`
- Avg reference: `· avg <N>` (lowercase "avg")
- Listening placeholder: `Listening…` (when mic active but no speech yet)

### Dashboard tabs

- `Last session` · `Today` · `This week` · `Last week` · `This month` · `Last month` · `All time`

### Empty states

- No sessions yet: "Your first session will show up here. Open Zoom, Meet, or any app with a microphone."
- No data for selected range: "Nothing happened in this range. Try a wider window."
- Permissions missing: "Locto needs microphone access to listen to your speech. **Open System Settings →**"

### Coach note titles (templates — fill from analysis output)

Positive:
- "Pace was on point."
- "You stayed steady."
- "Filler words were rare."

Tells:
- `"<word>" is your tell.`
- "Pace ran ahead of you."
- "You drifted into a slow stretch."

### System

- App name: `Locto`
- Tagline (for App Store, marketing): "Speak in your sweet spot."
- Description (one-liner): "An ambient AI speech coach for Mac."

## Edge case visuals

- **Permission denied banner:** light coral surface (`#FCEBEB`), dark coral text (`#A32D2D`), 0.5 pt border, 12 pt radius, 16 pt padding, "Open System Settings →" link in primary text color.
- **Loading state:** subtle 1-second pulse on the affected card; no spinner.
- **Error state:** inline message in card, no modal alerts unless data loss is at risk.
- **Empty session list:** centered illustration (the mark, 64 pt, at 30% opacity) with empty-state copy below.

## Iconography

The app uses very few icons. Where icons appear:

- Menu bar: the Locto mark (template image)
- Tab bar: text-only, no icons
- Settings: SF Symbols where appropriate (gear, lock, mic, trash). Match weight and size to surrounding type.
- Coach notes: state-colored dot is the only "icon" — no SF Symbols inside the note.

Do not introduce decorative icons. The product's visual interest comes from the state colors and the data signature (vertical strokes, gradient pace bar), not iconography.
