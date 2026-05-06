# 01 · Product spec

## What Locto is

Locto is an ambient AI speech coach for Mac. It auto-appears whenever the Mac's microphone becomes active and gives real-time feedback on speaking pace and filler-word usage. Audio never leaves the device.

The product addresses a specific frustration: most speech-coaching tools require you to open them, hit record, do a fake practice session, and review afterward. Locto coaches you during the actual conversations you're already having — Zoom, Google Meet, podcast recordings, sales calls, interviews — without any per-session setup.

## Target users (initial hypotheses)

In rough priority order:

1. Public speakers and content creators (podcasters, YouTubers, conference speakers)
2. Startup founders rehearsing pitches
3. Sales reps doing call practice
4. Job seekers prepping for interviews

These are hypotheses, not commitments. The widget design is general enough to serve all four; segment-specific features (interview-question prompts, sales-script playback) are deliberately out of MVP. Validation of which segment converts cheapest is part of the GTM work, not the product spec.

## The two surfaces

### Surface 1 — the ambient widget

A small floating window (~320 × 320 pt at 1× scale) that appears in the top-right corner of the active screen the moment the Mac's microphone becomes active. Closes automatically when the mic deactivates. Frameless, draggable, non-modal.

Contents:

- **Hero pace number.** Current rolling-window words-per-minute, prominent. Hero-number type treatment from brand guidelines.
- **State label.** "Too slow" / "Ideal" / "Too fast" with the user's recent average shown as reference (`· avg 142`).
- **Pace bar.** Horizontal gradient bar with a triangular indicator showing where current pace falls along the slow→ideal→fast spectrum.
- **Top filler words.** Three most-used filler words this session, with vertical-stroke counts.

Background gradient changes based on state (slate-blue / sage-green / warm-coral). Exact treatments are in `brand/locto-brand-guidelines.html`.

### Surface 2 — the dashboard

A standard macOS window opened from the menu bar icon. Tabs across the top filter by time range: Last session · Today · This week · Last week · This month · Last month · All time.

Cards below:

- **Delivery quality.** Pace average, filler-word rate, longest solo run, vs.-baseline trend indicator.
- **This session.** Duration, key stats summary.
- **Pace over time.** Line chart with min/max/avg reference lines, time-in-zone breakdown on the right.
- **Filler words.** Vertical-stroke chart with counts.
- **Coach.** 2-3 plain-English notes derived from the session, with state-colored leading dots.

## Core features (MVP scope)

In:

- Auto-detection of microphone activation across any application
- Real-time on-device speech-to-text (English first)
- Real-time pace calculation (rolling-window wpm)
- Real-time filler-word detection (configurable list, English defaults)
- Three-state widget with color-coded states
- Persistent session storage (local SQLite or Core Data)
- Dashboard with last-session view and basic time-range filters
- Mac App Store sandbox compliance
- Light mode (dark mode in Phase 1.1 — see `04-build-phases.md`)

Out of MVP (future phases — see `04-build-phases.md`):

- Multilingual transcription beyond English
- Custom filler-word lists per user
- Sales-script / interview-question coaching modes
- Goal setting / streaks / gamification
- Social/sharing features
- iOS companion app
- Audio file import for non-realtime analysis
- Speaker diarization (separating user voice from other meeting attendees)

## Primary user flow

1. User opens Zoom / Meet / browser / podcast tool — anything that activates the mic.
2. Locto's menu bar icon was already in the menu bar (running in the background since launch).
3. The widget fades in within 200-400 ms of mic activation, top-right corner of the active screen.
4. As the user speaks, the widget updates: pace number ticks at 1 Hz, state label updates as state crosses thresholds, pace-bar indicator slides smoothly, filler-word counts increment as detected.
5. When the mic deactivates, widget fades out within 1-2 s.
6. Later, user clicks menu bar icon → dashboard opens with full session history.

## Detailed interactions

### Widget

- **Drag** to reposition. Position persists across sessions.
- **Click anywhere on the widget** → opens the dashboard.
- **Right-click** → context menu: "Hide for this session," "Open dashboard," "Settings…"
- **Cmd-W** when widget focused → close widget for this session only (will reappear next mic activation).

### Menu bar icon

- **Click** → dropdown menu: today's quick stats, "Open dashboard", "Settings…", "Quit Locto".
- **Right-click** = same as left-click for consistency with macOS conventions.
- Icon is monochrome template (system handles tint).

### Dashboard

- Tabs at top filter by time range. Active tab persists across launches.
- All cards refresh when tab changes.
- Right-click a session in any list → "Delete session…" with confirmation.
- Cmd-N → start a manual session (for users who want to test without an active mic source).
- Cmd-, → settings.

## Edge cases

- **Briefly-on mic** (less than ~5 seconds of speech): suppress widget; don't create a session record.
- **Multiple mic-active apps simultaneously** (rare but possible): single session, no duplicate widget.
- **No speech detected during mic-active period** (mic on but user silent / playing music): widget shows "listening…" placeholder for up to 30 s; if no speech detected, no session created.
- **Permissions denied** (microphone, accessibility): show non-intrusive sheet with "Open System Settings" link; don't repeatedly nag — dismiss for this session and re-show on next launch.
- **Background music / podcast playing during conversation:** filter via voice-activity detection; ignore non-speech audio. False-positive control is critical here — better to under-detect than to create garbage sessions.
- **Multiple displays:** widget appears on the screen where the mic-using app has focus.
- **System sleep / lid close mid-session:** finalize the session at the moment of sleep, persist, and resume cleanly on wake.
- **Disk full / write failure:** session lost (acceptable failure mode for v1); show non-blocking warning in dashboard on next open.
- **macOS version not supported:** check at launch, show clear alert with required minimum (TBD — see `05-open-questions.md`).

## Privacy boundary (summarized — full detail in `03-data-model.md`)

- Audio buffers never persist to disk. They live in memory for the duration of transcription only.
- Transcripts persist locally in encrypted SQLite (or Core Data with file-protection).
- Per-session deletion is one-click from the dashboard.
- Bulk delete and export are exposed from settings.
- No background uploads. No telemetry containing session content. Crash reports may include stack traces only, no user data.
