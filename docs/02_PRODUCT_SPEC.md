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

### FM3 — Minimal setup
First launch must be ≤2 user actions total.
- **One question at first launch:** "Which 1–2 languages do you speak in meetings?" Default: system locale, single selection. User can change in Settings later. Counts as one user action.
- **Mic permission grant** at first session start (point-of-use, system dialog). Counts as the second user action.
- No further setup required. No "tutorial," no "tour," no "configure your preferences."
- Models silent-download on first use of each declared language: Apple-served languages (~150 MB) silently via `AssetInventory`; Parakeet-served languages (~1.2 GB) one-time CDN download with widget toast "Preparing [language] model…"
- Sensible defaults for everything else (WPM band, widget position, filler dictionary, hotkey)

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
- **Monologue indicator:** appears at 60s of uninterrupted speaking (soft cue), strengthens at 90s (warning) and 150s (urgent). Visual treatment per FM1: gradual color/intensity transitions over 600ms, no flash, no pulse. Disappears when monologue clock resets (user yields ≥2.5s or genuinely stops).
- Liquid Glass translucent material, draggable per-display memory

### Persistent / no-speech behavior (locked Session 013)
- Widget stays visible for the entire mic-active session, even when no speech is detected. State shows "Listening…" or equivalent low-attention placeholder; metrics show no values rather than zeroed values (zeros would imply "you're at 0 WPM" — misleading).
- The user can manually dismiss the widget via an on-widget close affordance. Dismissal triggers a confirmation prompt: "Are you sure you are not going to speak during this session?" with Yes/No.
- Dismissal is scoped to the **current session only**. The widget re-appears on the next mic activation. There is no per-session "remember dismissal" persistence.
- Rationale: a widget that disappears on silence creates anxiety (did it crash?); a widget that auto-hides for known no-speech meetings (45-min webinars) is the listen-only edge case M2.4 blocklist already covers via the per-app blocklist for known offenders.

### Speaking metrics (real-time + logged)
- WPM (rolling window + session average)
- Filler-word counts per language
- Repeated phrases ("I think, I think")
- **Monologue events:** start time, duration, peak warning level reached. A "monologue" is uninterrupted speaking for 60s+ where pauses ≤2.5s do not break the streak (breath, "uh… so" bridges, thinking pauses are part of the same monologue). Algorithm and validation in `03_ARCHITECTURE.md` and `05_SPIKES.md` Spike #11.

### Filler-word dictionary (v1: seeded + manually editable)
- Bundled seed lists for high-priority languages (EN, RU, ES at minimum, plus any others we have native-speaker seed contributions for at launch). For declared languages without a bundled seed dictionary, the user starts with an empty list and adds fillers via settings as they notice them.
- User can add/remove words via settings, per language
- *Auto-learning is NOT in v1 — parked for v1.x*

### Language handling
- User declares 1 or 2 languages at first-launch onboarding. Editable anytime in Settings.
- Available choices: any locale in the union of Apple `SpeechTranscriber.supportedLocales` (27) ∪ Parakeet v3 supported locales (25) ≈ 50 distinct languages.
- Single combined alphabetized list at the picker; backend (Apple vs Parakeet) is invisible to the user. App decides routing internally.
- When N=1: no auto-detect runs; the declared locale is used for every session.
- When N=2: auto-detect chooses between the two declared locales per session (mechanism TBD via Spike #2).
- Manual override always one click away in menu bar (toggle between the two declared languages).
- Filler dictionaries, model downloads, and per-language assets are seeded only for the user's declared languages — users who pick only English never see "Preparing Russian model…" or pay the Parakeet download cost.

### Session storage (local only, metrics-only schema)
```
Session {
  id, startedAt, endedAt, language, userLabel?
  totalWords, averageWPM, peakWPM, wpmStandardDeviation
  effectiveSpeakingDuration
  wpmSamples: [{timestamp, wpm}]   // every 3s
  fillerCounts: [{word, count, language}]
  repeatedPhrases: [{phrase, count}]
  monologueEvents: [{startedAt, durationSeconds, peakWarningLevel}]
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
- **Trail-off / vocal-cliff detector — v2.** A "vocal cliff" is voice fading at the end of a phrase; the v2 widget would briefly flash an edge cue. Algorithm preserved in `05_SPIKES.md` Spike #12 (parked) so we don't re-derive in v2. Headline: maintain rolling RMS over 200ms windows and a 5-min adaptive baseline; fire an event when (a) recent RMS drops ≥6 dB below the prior 1.5s AND (b) a SPEAKING→PAUSED transition fires within 300ms — the conjunction is what distinguishes a trail-off from a mid-sentence dip. Rate-limit to one event per 10s. Reasons for v1 deferral: (1) shares S9's risk shape (per-user-tunable dB threshold violates FM3); (2) v1 doesn't currently capture RMS — we removed it in Session 013 with S9; (3) the conjunction ("drop AND silence") makes it more defensible than S9 was, but still needs a validation spike before commit. v2-blocking work: Spike #12 (parked, 2h) — prove the 6dB-then-silence rule generalizes across at least 2 voice samples.
- **Shouting / aggressive-tone detection — v2.** Originally scoped for v1 (Session 004 architecture decision). Spike #9 (Session 013) invalidated the planned algorithm: an RMS-based adaptive noise floor with a +25 dB threshold cannot distinguish shouting from (a) normal speech-after-pause in quiet rooms (the floor calibrates to silence between sentences, so any speech triggers), or (b) Lombard-effect raised voice in noisy rooms (genuine shouting fails to clear floor+25 dB because ambient floor is already high). Both failure modes are a violation of FM1. v2 will explore an intelligent voice-analysis approach (likely a multi-signal model: pitch/F0 elevation, spectral tilt, sudden vs gradual onset). Full diagnosis in `05_SPIKES.md` Spike #9.
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
| Declared languages | System locale, single (user can change to any pair at onboarding or later in Settings) |
| Auto-detect language | Active only when user has declared 2 languages (otherwise no-op) |
| Per-app blocklist | Empty |
| Filler dictionary | Built-in seeded for EN/RU/ES + any others bundled at launch; empty for other declared languages until user adds entries |
| Session retention | Forever (metrics are tiny) |
| Menu bar icon | Visible (user can hide via 3rd-party tools if desired) |
| Hotkey | Cmd+Shift+M to toggle coaching on/off (override auto) |

All settings are accessible. The only required first-launch step is the language picker (1 question) plus the mic permission grant on first session.

---

## Languages at launch

The user picks 1 or 2 languages at first-launch onboarding from a single combined alphabetized list. The list contains the union of:
- Apple `SpeechTranscriber.supportedLocales` on macOS 26 (currently 27 locales, including English variants, Spanish variants, French, German, Italian, Portuguese, Korean, Japanese, several Chinese variants)
- Parakeet v3 supported locales (25 European languages, including Russian and most Apple locales — overlap is fine; Apple is preferred when both cover a locale)

Total ≈ 50 distinct languages available at launch.

**Routing is invisible to the user.** The picker shows just language names. Internally:
- If the chosen locale is in Apple's list → routed to `AppleTranscriberBackend`. Model silent-downloads via `AssetInventory` on first session, ~150 MB. No toast.
- If only Parakeet covers the locale (e.g., Russian) → routed to `ParakeetTranscriberBackend`. Model one-time CDN download on first session with widget toast "Preparing [language] model…", ~1.2 GB.

**A user who picks only English** never downloads Parakeet, never sees a Russian-related anything. The app stays small and Apple-native for that user.

**A user who picks English + Russian** (the bilingual case the architecture was designed around) downloads both: Apple's English model on first English session (no toast), Parakeet's multilingual model on first Russian session (toast).

Adding a new locale post-launch is a one-line registry update — no architecture change required.

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
