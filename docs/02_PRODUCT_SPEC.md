# Product Spec — Speech Coach (v1)

> **Locked.** Changes to this document require an explicit decision logged in `01_PROJECT_JOURNAL.md`.

---

## What it is

A macOS menu bar app that runs silently in the background and shows a translucent floating widget whenever your microphone activates. The widget gives real-time, glanceable feedback on speaking pace and filler words. After each session, metrics are logged locally for long-term progress tracking.

**Tagline:** A silent coach in every meeting.

---

## Who it's for

You first. Public release (App Store or direct) is a future goal once v1 has been used for a few weeks and the failure modes have been validated.

Target user profile: bilingual professionals (English + Russian + Spanish) who care about how they come across in meetings and want passive, no-effort feedback rather than recording-and-review tools.

---

## Goals (in priority order)

1. **Real-time coaching feedback** — useful while you speak
2. **Long-term progress tracking** — see if you're improving over weeks
3. **Privacy / fully local** — no cloud, no telemetry, no transcripts persisted
4. **Polished UI/UX** — important but not blocking; functional polish first

---

## Failure modes (the "if these are wrong, the app is dead" criteria)

These drive every priority decision.

### FM1 — Destructive UI
Anything that pulls the eye when nothing actionable changed = failure.
- No flashing or pulsing on filler detection
- No animated reordering of the filler list
- Smooth color interpolation, not step transitions
- Glanceable in <500ms peripheral vision while talking
- Works at low brightness, color-blind safe, high-contrast OK

### FM2 — Unreliable data
If felt experience and displayed data disagree, trust collapses.
- WPM must reflect speed-up/slow-down within ~3 seconds of the user changing pace
- Pauses for breath must NOT crash the WPM number
- Filler counts must be obvious-case correct (catching "so", "um", "ну", "это")
- Calibration validated on real recordings before shipping

### FM3 — No setup
First launch must be ≤2 user actions.
- No dedicated onboarding screen
- Permissions requested at point of use
- English model pre-bundled (or silent-downloaded with no UI)
- Russian/Spanish models silent-download on first detected use
- Sensible defaults for everything (WPM band, widget position, filler dictionary)

### FM4 — No performance impact
Invisible cost during 1hr Zoom calls on battery.
- <5% sustained CPU on Apple Silicon during active session
- No mic dropouts in other apps (Zoom, Meet, FaceTime)
- No measurable battery delta when idle (mic off)
- Memory under 150MB resident

---

## Features (v1 — locked)

### Auto-activation
- Widget appears when ANY app activates the system mic
- Per-app blocklist in settings (Voice Memos, etc.)
- Widget stays 5 seconds after mic deactivates, then fades out
- Each mic-on → mic-off cycle = one logged session

### Real-time widget display
- Large WPM number (current short-window value)
- Smaller session-average WPM underneath
- Color band: green (in target range), yellow (drifting out), red (well outside)
- Arrow icon: ↑ when too fast, ↓ when too slow, hidden when on-pace
- Filler word list below (growing): word + count, e.g., "so 15"
- Volume/shouting icon appears when triggered
- Liquid Glass translucent material, draggable per-display memory

### Speaking metrics (real-time + logged)
- WPM (rolling window + session average)
- Filler-word counts per language
- Repeated phrases ("I think, I think")
- Volume/shouting events

### Filler-word dictionary (v1: seeded + manually editable)
- Per-language seed lists for EN, RU, ES
- User can add/remove words via settings
- *Auto-learning is NOT in v1 — parked for v1.x*

### Language handling
- Auto-detect per session (mechanism TBD via Spike #2)
- Manual override always one click away in menu bar
- Models download silently on first use of each language
- Initial set: en-US, ru-RU, es-ES (more locales available via `SpeechTranscriber.supportedLocales`)

### Session storage (local only, metrics-only schema)
```
Session {
  id, startedAt, endedAt, language, userLabel?
  totalWords, averageWPM, peakWPM, wpmStandardDeviation
  shoutingEvents, effectiveSpeakingDuration
  wpmSamples: [{timestamp, wpm}]   // every 3s
  fillerCounts: [{word, count, language}]
  repeatedPhrases: [{phrase, count}]
}
```

No transcripts persisted. No app names persisted. No timestamps within day except session boundaries.

### Expanded stats window
- Session list (timestamp + language + duration)
- WPM trend chart (line, time-series)
- Filler frequency chart (per language, top fillers over time)
- Per-session detail view
- Manual relabel ("Q3 client meeting")

---

## Non-goals (explicitly NOT in v1)

- Acoustic non-word detection ("hmm", "ahh") — v1.x
- Auto-learn fillers — v1.x
- Pitch / tone analysis — v1.x or v2
- Long-pause tracking as user-visible metric — never
- Speaker diarization (mixed-room your-voice-only) — v2
- Cloud LLM analysis — v2+
- iCloud sync — never planned
- Live transcript display on widget — never
- Per-app preset languages — v1.x or v2
- Custom widget themes — never (Liquid Glass only)
- Recording/playback of sessions — never (privacy)

---

## UX defaults (no setup required)

| Setting | Default |
|---|---|
| WPM target band | 130–170 (single global, language-agnostic in v1) |
| Widget position | Top-right of main display |
| Auto-detect language | On |
| Per-app blocklist | Empty |
| Filler dictionary | Built-in seeded for EN, RU, ES |
| Session retention | Forever (metrics are tiny) |
| Menu bar icon | Visible (user can hide via 3rd-party tools if desired) |
| Hotkey | Cmd+Shift+M to toggle coaching on/off (override auto) |

All settings are accessible but no setting is required to start using the app.

---

## Languages at launch

- **en-US** — primary, model pre-bundled or silent-downloaded
- **ru-RU** — silent download on first Russian session
- **es-ES, es-MX, es-US** — silent download on first Spanish session (which Spanish locale auto-detected from speech or system locale)

Other locales available later via `SpeechTranscriber.supportedLocales` — out of scope for v1 polish.

---

## Distribution

**Decision: deferred.** App Store vs direct download decision happens after v1 is built and used personally for 2+ weeks. Architecture stays App-Store-compatible (sandbox, hardened runtime, no private APIs) so direct → App Store is a packaging change, not an architecture change.

---

## Success metric for v1

After 2 weeks of personal use, the user can answer "yes" to all four:

1. *I forgot the app was running, but my filler use went down.*
2. *I trust the WPM number — when I felt I was rushing, the widget agreed.*
3. *My Zoom calls didn't degrade.*
4. *Setup was zero effort — it just worked.*

If any of these are "no," the corresponding failure mode is the v1.x priority.
