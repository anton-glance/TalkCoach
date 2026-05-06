# Product Spec — Locto (v1)

> **Locked.** Changes to this document require an explicit decision logged in `01_PROJECT_JOURNAL.md`.
>
> **Naming note:** The user-facing product name is **Locto**. The repository, Xcode scheme, bundle identifier (`com.talkcoach.app`), and source code retain the working name `TalkCoach` for v1; renaming the codebase is a non-trivial change deferred until after v1 launch. Wherever this spec refers to product behavior the user sees ("the menu bar shows About Locto"), use Locto. Wherever it refers to internal artifacts (build target, repo, signing identifier), TalkCoach is correct.

---

## What it is

A macOS menu bar app that runs silently in the background and shows a translucent floating widget whenever your microphone activates. The widget gives real-time, glanceable feedback on speaking pace, with a monologue indicator that surfaces when you've been speaking too long without yielding. After each session, metrics are logged locally for long-term progress tracking.

**Tagline:** Speak in your sweet spot.

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
- No flashing or pulsing on metric changes (state transitions, monologue level escalation)
- Smooth color interpolation, not step transitions
- Glanceable in <500ms peripheral vision while talking
- Works at low brightness, color-blind safe, high-contrast OK

### FM2 — Unreliable data
If felt experience and displayed data disagree, trust collapses.
- WPM must reflect speed-up/slow-down within ~3 seconds of the user changing pace
- Pauses for breath must NOT crash the WPM number
- Monologue indicator must fire on genuine 60s+ uninterrupted speaking and not fire on conversational back-and-forth
- Calibration validated on real recordings before shipping

### FM3 — Minimal setup
First launch must be ≤2 user actions total.
- **One question at first launch:** "Which 1–2 languages do you speak in meetings?" Default: system locale, single selection. User can change in Settings later. Counts as one user action.
- **Mic permission grant** at first session start (point-of-use, system dialog). Counts as the second user action.
- No further setup required. No "tutorial," no "tour," no "configure your preferences."
- Models silent-download on first use of each declared language: Apple-served languages (~150 MB) silently via `AssetInventory`; Parakeet-served languages (~1.2 GB) one-time CDN download with widget toast "Preparing [language] model…"
- Sensible defaults for everything else (WPM band, widget position, hotkey)

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
- State indicator and color signal: slate-blue (too slow) / sage-green (ideal) / warm-coral (too fast). State labels per the design doc: "Too slow" / "Ideal" / "Too fast".
- Pace bar with positional indicator (caret) showing where current pace sits along the slow→ideal→fast spectrum
- **Monologue indicator:** appears at 60s of uninterrupted speaking (soft cue), strengthens at 90s (warning) and 150s (urgent). Visual treatment per FM1: gradual color/intensity transitions over 600ms, no flash, no pulse. Disappears when monologue clock resets (user yields ≥2.5s or genuinely stops). Specific visual treatment in `docs/design/01-design-spec.md`.
- Liquid Glass translucent material, draggable per-display memory
- Hover state: alpha shifts more saturated (per `docs/design/01-design-spec.md`) — the only intentional attention-grab in the widget surface
- Visual specifics (size, palette ink colors, type ramp, motion timings) are in `docs/design/01-design-spec.md` and `docs/design/02-brand-guidelines.html`

### Persistent / no-speech behavior (locked Session 013)
- Widget stays visible for the entire mic-active session, even when no speech is detected. State shows "Listening…" or equivalent low-attention placeholder; metrics show no values rather than zeroed values (zeros would imply "you're at 0 WPM" — misleading).
- The user can manually dismiss the widget via an on-widget close affordance. Dismissal triggers a confirmation prompt: "Are you sure you are not going to speak during this session?" with Yes/No.
- Dismissal is scoped to the **current session only**. The widget re-appears on the next mic activation. There is no per-session "remember dismissal" persistence.
- Rationale: a widget that disappears on silence creates anxiety (did it crash?); a widget that auto-hides for known no-speech meetings (45-min webinars) is the listen-only edge case M2.4 blocklist already covers via the per-app blocklist for known offenders.

### Speaking metrics (real-time + logged)
- WPM (rolling window + session average)
- **Monologue events:** start time, duration, peak warning level reached. A "monologue" is uninterrupted speaking for 60s+ where pauses ≤2.5s do not break the streak (breath, "uh… so" bridges, thinking pauses are part of the same monologue). Algorithm and validation in `03_ARCHITECTURE.md` and `05_SPIKES.md` Spike #11.

### ~~Filler-word dictionary~~ (deferred to v2.0 — Session 018)

Filler-word tracking and the per-language dictionary are deferred to v2.0. Market discovery surfaced monologue detection as the higher-priority feedback signal; filler tracking returns alongside the v2.0 dashboard with rich post-session analysis and recommendations. The seeded dictionary work (EN/RU/ES bundled lists, per-language editor in Settings, `FillerDetector` module, repeated-phrase detector) is removed from v1 scope. The data-model fields `fillerCounts` and `repeatedPhrases` are not persisted in v1; v2.0 adds them via a SwiftData schema migration.

### Language handling
- User declares 1 or 2 languages at first-launch onboarding. Editable anytime in Settings.
- Available choices: any locale in the union of Apple `SpeechTranscriber.supportedLocales` (27) ∪ Parakeet v3 supported locales (25) ≈ 50 distinct languages.
- Single combined alphabetized list at the picker; backend (Apple vs Parakeet) is invisible to the user. App decides routing internally.
- When N=1: no auto-detect runs; the declared locale is used for every session.
- When N=2: auto-detect chooses between the two declared locales per session (mechanism TBD via Spike #2).
- Manual override always one click away in menu bar (toggle between the two declared languages).
- Model downloads and per-language assets are seeded only for the user's declared languages — users who pick only English never see "Preparing Russian model…" or pay the Parakeet download cost.

### Session storage (local only, metrics-only schema)
```
Session {
  id, startedAt, endedAt, language, userLabel?
  totalWords, averageWPM, peakWPM, wpmStandardDeviation
  effectiveSpeakingDuration
  wpmSamples: [{timestamp, wpm}]   // every 3s
  monologueEvents: [{startedAt, durationSeconds, peakWarningLevel}]
}
```

No transcripts persisted. No app names persisted. No timestamps within day except session boundaries. v1.x and v2.0 schema additions (e.g., filler counts in v2.0) attach via SwiftData `MigrationPlanV2` and forward; the v1 schema is locked.

### Expanded stats window
- Session list (timestamp + language + duration)
- WPM trend chart (line, time-series)
- Monologue event timeline per session (when in the session each monologue fired and its peak level)
- Per-session detail view
- Manual relabel ("Q3 client meeting")

---

## Non-goals (explicitly NOT in v1)

- **Filler-word tracking — v2.0 (deferred Session 018).** Counting "so", "um", "ну", "это" etc. as a per-session metric, with seeded dictionaries per language and a Settings editor. Deferred alongside repeated-phrase detection and the rich post-session dashboard. Market discovery surfaced monologue detection as the higher-priority feedback signal — fillers return as part of the v2.0 dashboard with explanations and recommendations rather than as a raw count on the widget.
- **Repeated-phrase detection ("I think, I think") — v2.0.** Sibling of filler tracking, same rationale. Both are verbal-pattern critiques most useful in post-session reflection rather than in-session glance.
- Acoustic non-word detection ("hmm", "ahh") — v2.0 (paired with filler tracking)
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

1. *I forgot the app was running, but I noticed when I drifted into a monologue.*
2. *I trust the WPM number — when I felt I was rushing, the widget agreed.*
3. *My Zoom calls didn't degrade.*
4. *Setup was zero effort — it just worked.*

If any of these are "no," the corresponding failure mode is the v1.x priority.
