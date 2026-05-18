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
- Widget appears when ANY app activates the system mic AND the speech engine is ready (see Widget lifecycle below for the precise trigger)
- Per-app blocklist in settings (Voice Memos, etc.)
- Widget linger pattern on session end: 3s at full opacity, then 2s fade-out, with hover-pause and hover-reset behavior (see Widget lifecycle)
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

### Widget lifecycle (locked Session 031)

The widget appears, persists, and disappears according to a strict lifecycle tied to engine readiness and session boundaries, NOT to token arrival or speech activity. This is the canonical rule: **the widget is visible for the entire engine-ready portion of a mic-active session, regardless of whether the user is speaking.** Content inside the widget changes based on speech activity (active vs subtle modes); the widget itself does not appear-disappear-reappear mid-session.

**Phase A — Idle.** No mic-on signal from any external process. Widget not visible. Locto sits silently in the menu bar.

**Phase B — Mic-on detected, engine warming.** External app activates the mic (IRS=true on the default input device). Locto starts a session, starts AudioPipeline + SpeechAnalyzer. **Widget NOT yet visible.** Duration: ~5–7s (Apple SpeechAnalyzer cold-start). Tradeoff explicitly accepted: if the user starts a Zoom call and speaks immediately, there is a perceived ~5–7s delay before the widget appears. We do not show the widget before the engine can produce data; showing earlier would mean displaying placeholder content that goes stale.

**Phase C — Engine ready, widget appears.** Trigger: **first audio buffer flowing into SpeechAnalyzer.** This is the load-bearing system signal that "everything is up and running." Widget appears with initial content: timer at 00:00, token count 0, "Listening…" placeholder for metrics that haven't accumulated yet. Widget stays at full opacity from this point forward through Phase E.

**Phase D — Engine running, widget visible, content reflects activity.** The widget itself stays at full opacity. Internal content state transitions based on token-stream activity:
- D1 (active): tokens arriving in the last 2 seconds → widget shows current real-time metrics in active state (WPM, monologue timer running, token count incrementing).
- D2 (subtle): no tokens for ≥2 seconds → widget content shifts to subtle mode (reduced visual emphasis on metrics, monologue timer paused for the silence span). The widget remains visible and at full opacity; the content is subtler to signal "I'm here, waiting." A silence-detection event fires at this transition; future modules (M3.2 SpeakingActivityTracker, M4.1 WPMCalculator monologue reset) subscribe to it.
- D3 (re-activates): tokens resume → content returns to active state, monologue timer logic resumes per its own rules.

The 2-second silence threshold is a v1 starting value. M4.1 may refine to a WPM-aware threshold later. The widget itself never hides during Phases D1/D2/D3.

**Phase E — Mic-off detected, session ends.** Poll returns empty external readers OR the IRS listener fires false. Session data persists to SwiftData (M2.7 path) immediately, before any UI animation. The widget enters the linger sequence (Phase F).

**Phase F — Linger sequence (3s full opacity + 2s fade).**
- F1: 3 seconds at full opacity. Widget remains fully visible. If user hovers anywhere on the widget bounds during F1, the 3-second countdown PAUSES (does not reset; resumes from current position when hover ends).
- F2: 2 seconds fade-out animation. Widget opacity transitions from 100% to 0%. If user hovers during F2, the fade cancels, widget snaps back to 100% opacity, and the countdown returns to the start of F1 (full 3 seconds restart).
- F3: Widget fully hidden, linger complete.

Throughout F1 and F2, a click handler is wired but is a no-op in v1 (logs the click for telemetry). v2 wires the click to open a session-stats view. The linger UI exists in v1 specifically so v2's click affordance composes cleanly without UX rework.

**Phase G — Session switch during linger.** If a new mic-on signal arrives during F1 or F2 (Zoom B starts before Zoom A's linger completes):
- Session B starts in background per Phase B (engine warming).
- Linger animation for session A continues until session B's engine-ready signal fires (or the linger completes naturally, whichever comes first).
- When session B's engine-ready fires: **linger animation cancels in place, widget snaps to 100% opacity (if mid-fade), content switches from session A's "ended" state to session B's "active" state without disappearing.** User perceives a single continuous widget that changed content, not a disappear-reappear.
- If linger completes (F3 reached) before session B is ready: standard Phase B → Phase C transition. Widget hidden during session B's warm-up, appears when ready.

**Manual dismissal.** Per M2.5: the user can manually dismiss the widget via an on-widget close affordance during any of Phases C through F. Dismissal triggers a confirmation prompt: "Are you sure you are not going to speak during this session?" with Yes/No. Dismissal is scoped to the current session only — the widget re-appears on the next mic activation.

**What the widget never does:**
- Never hides automatically due to speech silence within an active session (only content changes)
- Never appears before the engine is ready (Phase B is a deliberate visual silence)
- Never flashes/disappears between two adjacent sessions in the linger window (Phase G handles this with in-place content swap)

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
