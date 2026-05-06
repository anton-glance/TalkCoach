# Release Plan — Locto v1

> **Purpose:** Maps every backlog phase to what's testable, what feedback you can give, and what risk it surfaces. Read this at the start of every new conversation so the architect (this conversation) and you (product owner) share the same picture of where we are and what comes next.
>
> **Owner:** Architect (this conversation), updated at session end if the plan moves.
>
> **Companion docs:** `04_BACKLOG.md` (modules, estimates, dependencies) · `02_PRODUCT_SPEC.md` (success criteria, failure modes) · `01_PROJECT_JOURNAL.md` (decisions log) · `docs/design/` (visual + brand spec).

---

## TL;DR

- **First useful product feedback:** end of Phase 5 (real-time widget displays live metrics in a real meeting). Cumulative ~92–98h after Session 018 scope reduction.
- **Two earlier checkpoints baked in:** dynamic placeholder at Phase 2 end, debug HUD with live transcription overlay at Phase 3 end. Each is throwaway dev surface, removed in Phase 6 polish. (The Phase 4 post-session notification checkpoint is dropped after Session 018 — with fillers gone, the only Phase 4 metric is WPM, which is easier to spot-check from the SwiftData store than to wrap in a notification.)
- **Highest risk before Phase 5:** Russian transcription quality on Parakeet in real meeting audio. Validated at the Phase 3 checkpoint before sinking another ~30h into analyzer + widget work.
- **Calendar:** at 20h/week, Phase 5 lands week 5; at 8h/week, Phase 5 lands month 3.

---

## Definition of "user testable"

A phase is *user testable* when the product owner can sit down for ≥30 minutes with the built app and answer a meaningful question about whether v1 is on track. Not "the unit tests pass" — that's the agent's job. *User testable* means: real meeting, real audio, real eyes on the screen, and the question being asked has a yes/no answer that changes what gets built next.

By that bar, only Phase 5 onward is genuinely user testable in the v1 sense (FM1 destructive UI, FM2 unreliable data, FM3 minimal setup, FM4 no perf impact). Phases 1–4 produce scaffolding the user can poke at but can't judge against the failure modes. The two checkpoints below address the "flying blind" problem without pretending earlier phases test the product.

---

## Phase-by-phase: what you get and when

### Phase 1 — Foundation (~14h cumulative)

**What works.** App launches as a menu-bar-only app. Settings window opens automatically on first launch. You pick 1–2 languages from the ~50-locale picker. Pause/Resume Coaching and Quit work from the menu. Permissions request flow runs at point-of-use.

**What does not work.** No mic monitoring. No widget. No audio capture. No transcription. No metrics. No download flow (model size labels are shown in Settings but no actual fetch).

**Useful feedback at this point.** Settings UX only — clarity of the language picker, copy of the size labels, the pre-checked system locale, the menu items. Five minutes of clicking. Not real-world testing.

**Why you cannot test the product yet.** No audio path exists. The app cannot tell whether the mic is on, let alone what's being said.

**Exit gate.** The Phase 1 acceptance criteria in `04_BACKLOG.md`: app builds, runs, menu present, Settings auto-opens on first launch with language picker, requests permissions when needed, exits cleanly.

---

### Phase 2 — Mic detection and session lifecycle (~28h cumulative, +14h)

**What works.** Open Zoom, FaceTime, browser Meet, or any other mic-using app → the placeholder widget appears in your chosen position with a session timer + "Listening…" caption → it stays visible for the entire mic-active session → close the app → 5s hold, then fade-out. The widget can be manually dismissed mid-session via an on-widget close affordance with a confirmation alert; dismissal is scoped to the current session only. Sessions persist with empty metrics (timestamps only — language is M3.4 in Phase 3). Per-display widget position memory works.

**What does not work.** No transcription. No real metric numbers. The widget shows a placeholder, not the design-package mockup.

**Useful feedback at this point.** Mic-detection edge cases. Does the widget show up reliably? Does it pick the right position when you have multiple monitors? Does it disappear cleanly on mic-off? Does Voice Memos / iOS Mirroring / system dictation accidentally trigger it? (These are real concerns — Voice Memos triggering the widget is a known v2 deferral that we live with in v1.)

**Why this is not yet a product test.** Without transcription and metrics, the widget has nothing to coach you with. You're testing whether the lifecycle plumbing is correct, not whether the product helps you speak better.

**Checkpoint #1: Dynamic placeholder.** *Baked into M2.5.* The placeholder widget shows a session timer (`00:42`) and a "Listening…" caption — the locked persistent-visibility model (Session 013, reaffirmed Session 018) provides the lifecycle test the checkpoint was originally designed to expose: the widget appears on mic-active, stays visible during the entire session, and hides 5s after mic-off. ~30 minutes of dev cost, removed in Phase 6 polish (the timer-and-caption skeleton is replaced by the real `WidgetViewModel` in M5.1, then the real WPM display in M5.2). M2.5 does not touch audio: the only `AVAudioEngine` in v1 is owned by `AudioPipeline` (M3.1), and there is no value in spinning up a parallel ad-hoc engine just for an in-session "speaking detected" indicator when the persistent + Listening… model already exposes whether the mic-on/mic-off lifecycle is correctly wired.

**Exit gate.** Open Zoom → widget appears immediately on mic-on with timer ticking and "Listening…" caption → widget stays visible the entire session → close Zoom → 5s hold, then fade-out → session record exists in the SwiftData store with start/end timestamps.

---

### Phase 3 — Audio pipeline and transcription engine (~65–71h cumulative, +37–43h)

**What works.** While a session is active, audio captures, gets routed to the right backend by language, and tokens flow. English speech goes to `AppleTranscriberBackend`. Russian (and other Apple-unsupported locales) goes to `ParakeetTranscriberBackend`. First-time use of a Parakeet language triggers the in-Settings download confirmation prompt with the ~1.2 GB size warning. Mid-session language re-detection works for N=2 declared.

**What does not work.** No WPM math. No monologue detection. The widget still shows the dynamic placeholder from Phase 2, not real data.

**Useful feedback at this point.** Russian transcription quality in real meeting audio. This is the highest-risk piece of v1. The S10 spike validated Parakeet on clean test recordings, but real meeting audio has cross-talk, mic placement variance, and accent variation the spike didn't cover. If accuracy is materially worse than S10 suggested, we need to know in week 3, not week 6 after sinking another ~40h into analyzer + widget work assuming the tokens are reliable.

Also useful: the Settings download flow. Does the confirmation prompt feel reasonable? Is the progress UI clear when 1.2 GB is fetching? Does cancellation work? Does the app behave correctly if the user denies the download (graceful "language unavailable" state vs crash)?

**Why this is still not a product test.** No coaching feedback exists yet. You're validating that the foundation under the analyzer is sound.

**Checkpoint #2: Debug HUD overlay on widget.** *Baked into M3.7.* The widget's placeholder is replaced (during dev only) by a debug HUD showing: live token stream from the active backend, detected language label, backend identifier ("Apple" or "Parakeet"), and a confidence indicator if the backend exposes one. ~1h of dev cost. Removed in Phase 6 polish before ship. **This is the most important of the two checkpoints** — it's the validation gate before committing to Phase 4.

**Exit gate.** Speak English in a real Zoom call → HUD shows English tokens flowing from Apple backend. Speak Russian in a real Zoom call → HUD shows Russian tokens flowing from Parakeet backend, first-time use prompted for download in Settings. Token stream survives a 30-minute call without dropouts.

**If RU quality fails this gate.** Stop. Open a v1.x decision: either (a) accept the limitation and ship English-only v1, RU as v1.x once a better model arrives, or (b) re-spike Parakeet config (chunk size, normalization, mic-input format) to find the gap between spike conditions and meeting conditions. Don't proceed to Phase 4 with degraded RU tokens — every analyzer metric inherits the underlying noise.

---

### Phase 4 — Analyzer (~72–78h cumulative, +7h)

**What works.** Tokens turn into metrics. WPM (sliding window + session average + standard deviation + peak), effective speaking duration. Final session aggregation runs at session end and persists to `SessionStore`.

**What does not work.** **The widget still shows the Phase 3 debug HUD or the Phase 2 placeholder, not the real WPM display.** The product looks the same to the user — only the data layer underneath changes.

**Useful feedback at this point.** Are the metrics correct *after the call*? Is WPM in the right ballpark for how you felt the call went? Anything obviously wrong with `effectiveSpeakingDuration` for sessions that had long silent stretches?

**Why this is still not a product test.** The metrics are correct in the data store but invisible during the call. Real-time coaching is the entire product hypothesis. Phase 4 just builds the brain that Phase 5 will surface.

**No checkpoint at this phase end (Session 018).** Earlier plan included a post-session `UNUserNotificationCenter` notification with metric summary as Checkpoint #3. With fillers and repeated-phrase detection deferred to v2.0, the only Phase 4 metric is WPM, which is straightforward to spot-check by querying the SwiftData store directly. The notification surface added complexity without a proportional risk-reduction signal at the new scope.

**Exit gate.** End a session → query `SessionStore` (via Xcode debug or a small dev script) → metrics match a manual stopwatch on a real recording within ~5% (calibration was done in spike S6 for English; this re-validates on the production code path).

---

### Phase 5 — Widget UI (~92–98h cumulative, +20h)

**THIS IS YOUR FIRST REAL USER TEST.**

**What works.** The placeholder is replaced by the real widget per `docs/design/` (Session 018 — superseded the earlier `design/` package): 144×144pt Liquid Glass tile, hero WPM number (Inter weight 300, tabular figures), state row ("Too slow" / "Ideal" / "Too fast" + session avg), pace bar with caret indicator, smooth color interpolation across the slate-blue / sage-green / warm-coral state inks, drag-to-move with snap, fade in/out animations, hover saturation shift, accessibility (Reduce Motion, Reduce Transparency, Increase Contrast, VoiceOver). The widget updates as you speak.

**What does not work.** No notarization yet, no DMG. The build runs from Xcode on your machine. No final perf re-pass. No accessibility audit beyond the per-module checks in Phase 5. No monologue indicator — that's v1.x (M4.5 + M5.6).

**Useful feedback at this point — the actual product test.** Two-week self-validation begins. Real Zoom calls, real meetings, real audio. The four v1 success questions from `02_PRODUCT_SPEC.md` become answerable:

1. *I forgot the app was running, but I noticed when I drifted into a monologue.* (Will only be testable when v1.x lands; for v1 proper, substitute "I forgot the app was running" alone.)
2. *I trust the WPM number — when I felt I was rushing, the widget agreed.*
3. *My Zoom calls didn't degrade.*
4. *Setup was zero effort — it just worked.*

If any answer is "no," that's the v1.x priority.

**FM1 / FM2 testable here.** Watch for destructive UI (anything that pulls the eye when nothing actionable changed) — flashing, jumpy state changes, color steps. Watch for unreliable data — WPM crashing on a breath pause, state oscillating around the band edge. The `docs/design/01-design-spec.md` testing checklist applies directly.

**Exit gate.** 30-minute Zoom call ended → you came out of it not annoyed by the widget AND able to recall whether you sped up at any point AND the displayed numbers agreed with your felt experience. Repeat for at least 3 real calls before declaring Phase 5 done.

---

### Phase 6 — Polish and ship-readiness (~110–116h cumulative, +18h)

**What works.** Manual language override in menu bar (read-only display + dropdown). Settings sheet polish (WPM band slider). Accessibility audit (VoiceOver labels, keyboard navigation in Settings). Dark/light verification. Performance re-pass (S7 conditional pass re-validated on real build). Notarization. DMG creation script. **The two feedback checkpoints from Phases 2 and 3 are removed.**

**Useful feedback at this point.** Edge cases that surfaced during the 2-week self-validation in Phase 5. Performance under sustained load. Anything broken on dark or light specifically. Anything weird with VoiceOver.

**Exit gate.** Signed, notarized DMG exists. App passes all four v1 success criteria after 2 weeks of personal use.

---

## Cumulative effort and calendar

| Milestone | Cumulative effort | What you can give feedback on | Calendar at 20h/week | Calendar at 8h/week |
|---|---|---|---|---|
| End of Phase 1 | ~14h | Settings UX only (5 min) | Week 1 | Week 2 |
| End of Phase 2 | ~28h | Widget lifecycle (30 min in real meetings) | Week 2 | Week 4 |
| End of Phase 3 | ~65–71h | **Russian transcription quality (real meetings)** | Week 4 | Week 8–9 |
| End of Phase 4 | ~72–78h | Metrics correctness post-call (WPM only) | Week 4–5 | Week 9–10 |
| **End of Phase 5** | **~92–98h** | **Real-time coaching, the product** | **Week 5** | **Month 3** |
| End of Phase 6 | ~110–116h | Polish, edge cases, ship-readiness | Week 6 | Month 3.5 |

Multiplier of 1.3–1.5× applies if macOS-specific debugging eats more time than the focused-effort estimate assumes. The calendar above does not include that multiplier — apply it to your planning.

---

## The two feedback checkpoints in one place

These are dev-only surfaces, lock-stepped to the prompts in Phase 2 / 3. Each is removed in Phase 6 polish before ship.

| # | Phase exit | What it is | Cost | Lives in prompt | Removed in |
|---|---|---|---|---|---|
| 1 | End of Phase 2 | Dynamic placeholder widget: session timer + "Listening…" caption (persistent-visibility model per Sessions 013/018; no audio in M2.5) | ~30 min | M2.5 (FloatingPanel) | M5.1 (replaced by real `WidgetViewModel`) |
| 2 | End of Phase 3 | Debug HUD overlay: live token stream + detected language + backend identifier | ~1h | M3.7 (token wiring) | M5.2 (replaced by real WPM display) |

Total checkpoint cost: ~1.5h. None of these change v1 scope or affect the locked architecture.

**Why these two and not others.** They're chosen against two risks:

- Checkpoint 1 de-risks **lifecycle plumbing** before transcription is built on top of it. If the widget shows up at the wrong moment on a multi-monitor setup, fixing it before audio code lands is cheaper than fixing it after.
- Checkpoint 2 de-risks **Russian transcription quality**, which is the single highest external risk in v1 (the Parakeet path's spike validated clean-recording quality; meeting-audio quality is unknown until proven).

**Why not a Phase 4 checkpoint (changed Session 018).** Earlier plan had a post-session `UNUserNotificationCenter` notification with metric summary (Session count, WPM avg, filler count) at the end of Phase 4. With fillers and repeated-phrase detection deferred to v2.0, the only Phase 4 metric is WPM, which is straightforward to spot-check by querying the SwiftData store directly. The notification surface added complexity without a proportional risk-reduction signal at the new scope.

**Why not more checkpoints.** Phase 1 has nothing meaningful to expose. Phase 5 IS the user test. Phase 6 polish doesn't need a checkpoint — it's the final round itself.

---

## How this doc gets used

- **Architect (this conversation):** at the start of every new conversation, reads this doc as part of the standard reading order in `00_COLLABORATION_INSTRUCTIONS.md`. Knows which phase we're in, what the next exit gate is, and what the next checkpoint adds.
- **User (product owner):** consults when planning calendar time, when deciding whether to start a v1.x conversation parallel to v1, or when judging whether a piece of feedback is "now" or "wait until Phase X."
- **Updates:** the architect updates this doc when (a) a phase exit gate is reached, (b) a checkpoint is implemented or removed, (c) the v1 scope changes per a journaled decision. Updates land in the same session that updates the journal.

---

## Anti-patterns to avoid

- **Don't start "real user testing" before Phase 5.** Real-time visual feedback is the entire product. Judging the app earlier is judging scaffolding.
- **Don't treat checkpoint output as v1 product UI.** The checkpoints are dev surface. They look rough on purpose. The widget at Phase 2 end is supposed to be a placeholder; the HUD at Phase 3 end is supposed to look like a debug overlay. Spending Phase-5-quality polish on them is wasted work.
- **Don't skip a checkpoint to save the ~30 min.** Each one buys you a risk-reduction signal that's worth far more than the dev cost. The Phase 3 Russian-transcription HUD especially.
- **Don't evaluate FM1 (destructive UI) before Phase 5.** The placeholder and HUD are deliberately attention-grabbing for debug purposes. FM1 is a production-widget-only criterion.
