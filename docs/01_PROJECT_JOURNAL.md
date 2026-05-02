# Project Journal — Speech Coach

> Append-only log of every working session. Never edit past entries destructively. New entries go at the **top**.

---

## Session 006 — 2026-05-02 — Architecture Pivot Y: Apple + Parakeet, Russian via Core ML

**Format:** Architecture decision triggered by Spike #6 incidentally discovering Russian is not on macOS 26.4.1's `SpeechTranscriber.supportedLocales`.

### What happened
Began the session running Spike #6 (WPM ground truth). English: 3 clips processed cleanly across all (window, alpha) combinations. Russian: failed with `SFSpeechErrorDomain Code=1 "transcription.ru asset unavailable"`.

After ruling out network, VPN, signing, disk space, the agent's diagnostic discovered the actual cause: `SpeechTranscriber.supportedLocales` on macOS 26.4.1 contains 27 locales, none of them Russian. `AssetInventory.status` returns `.unsupported` for `ru_RU`. The `supportedLocale(equivalentTo: Locale("ru"))` API misleadingly returns `ru_RU` even though it's not in the supported set — the locale is "reservation-only" with no model deliverable.

### Root cause vs assumption
Session 001 chose `SpeechAnalyzer` over legacy `SFSpeechRecognizer` because the user had real-world Russian failures on iOS with the legacy framework. We assumed `SpeechAnalyzer` had Russian. It does not on macOS 26.4.1. We have less Russian coverage than we started with.

This is exactly the failure that Phase 0 spikes are meant to catch — but Spike #3 was scheduled too late (after #6, #7, #4, #2). It should have been Phase 0 step 1 alongside checking `SpeechTranscriber.supportedLocales` for the explicit set of v1 languages. Lesson: when the architecture depends on a specific platform locale being supported, verify the *list* of supported locales before any other spike.

### Decision: Architecture Y
Apple `SpeechAnalyzer` for the 27 locales it actually supports (English, Spanish, French, German, etc.), NVIDIA Parakeet via Core ML for Russian. The user has prior production experience running Parakeet in real time on iOS in a translation app — strong signal it's feasible.

Considered and rejected:
- **Path A — drop Russian from v1:** user is bilingual EN/RU; Russian meetings are weekly; would gut the product's value for them
- **Path X — Parakeet for everything:** wastes Apple's free, OS-integrated path for English; bloats the install with a 600 MB model that adds nothing for English-only users; FM4 (no performance impact) likely violated for English sessions
- **Path C — wait for Apple to add Russian:** indefinite, blocks v1

### Scope impact

**Added:**
- New **Spike #10** — Parakeet feasibility on macOS 26 / Apple Silicon (8–12h). Validates: working Core ML port exists, real-time factor <0.5, Russian WER acceptable, **word-level timestamps** (load-bearing assumption for `SpeakingActivityTracker` from Session 004), cold-start <30s.
- New **`ParakeetTranscriberBackend`** module (M3.5b, 8–12h).
- New routing layer **`TranscriptionEngine`** (replaces `SpeechEngine`; M3.5, 4h).
- Network entitlement flips to `network.client = true` — required for Parakeet model download from CDN. Documented network policy in architecture doc: download only, no telemetry, no transcripts, audio never leaves the device.

**Revised:**
- **Spike #7** scope expanded — now validates Architecture Y power envelope specifically. Two-phase: Apple path baseline (Phase A), Parakeet path under load (Phase B), backend-switching cost (Phase C). Estimate 4h → 6h.
- **Spike #3** marked superseded by Spike #10 in `05_SPIKES.md` rather than left pending. Phantom tasks in the backlog cause confusion later.
- **`02_PRODUCT_SPEC.md`** Languages section rewritten: explicit Apple-vs-Parakeet split per locale; Russian first-use download is ~600 MB one-time with toast (vs ~150 MB for Apple locales).
- **`03_ARCHITECTURE.md`** `SpeechEngine` renamed `TranscriptionEngine` with two backends (`AppleTranscriberBackend`, `ParakeetTranscriberBackend`) and a routing layer. Network entitlement changed. Threading model adds Parakeet inference Task. Data-flow diagram updated to show routing.
- **`04_BACKLOG.md`** Phase 0 totals: 29h → 35–39h. Phase 3 totals: 28–32h → 40–48h. Project total: 169–173h → 192–204h.

### Critical assumption to validate (Spike #10 Phase D)
Session 004's `SpeakingActivityTracker` requires word-level timestamps. If Parakeet's Core ML port emits only phrase-level timestamps (one range per ~5-word phrase), the WPM math degrades for Russian — speaking-duration intersections become coarse, `tokenSilenceTimeout` gap-bridging is meaningless. Spike #10 explicitly tests this with intra-phrase pauses and quotes the result. Fallback plan: proportional estimation within phrases (N words over T seconds → each word `T/N` duration centered in the phrase). Documented in `TranscriptionEngine` caveats.

### Where we left off
- Session 005 closed Spike #6 English: ✅ provisional production constants — window=6, alpha=0.3, tokenSilenceTimeout=1.5 — pending Russian re-validation
- Russian WPM data not yet collected — blocked on Spike #10
- Recommended next session: generate Spike #10 prompt, agent investigates Parakeet Core ML, reports back. After Spike #10 passes, re-run WPM harness with Russian routed through Parakeet to close Spike #6 RU leg.

### Ups
- User caught the platform-locale gap before Phase 1 started — i.e., before any production code was committed. Cost so far: a few hours of misdirected harness runs. Cost if discovered after M3.5 was implemented: a major refactor.
- User had real-world prior experience with Parakeet (mobile, translation app). Anchored the architectural decision instead of speculation.
- Architecture Y is cleaner than alternatives despite adding a backend. The interface (`TranscriptionEngine` emits unified `(token, startTime, endTime, isFinal)` tuples regardless of backend) keeps downstream code unchanged. `SpeakingActivityTracker`, `WPMCalculator`, `FillerDetector` etc. don't care which backend produced the tokens.

### Downs
- Phase 0 spikes were not ordered to surface platform availability first. Spike #3 should have been "verify Apple supports each v1 locale" as a P0 prerequisite instead of "verify quality" as a P0 followup. Lesson: the *availability* check is upstream of the *quality* check; sequence matters.
- The Session 001 framework decision (`SpeechAnalyzer` over `SFSpeechRecognizer`) was made on the strength of "verified to support `ru_RU`" — that verification was based on `supportedLocale(equivalentTo:)` returning a non-nil value, which we now know is misleading. We need a hard rule: when validating platform availability, check the explicit list (`supportedLocales`), never the lookup helper (`supportedLocale(equivalentTo:)`).
- ~22–31h added to v1 effort. Real cost. The product is much stronger for it (Russian works), but the calendar slips by 2–3 weeks at 20h/week pace.
- Network entitlement flipping from `false` to `true` is real — every privacy-conscious user reading the app's entitlements will notice. Mitigation: tight network policy, documented; UI never presents network-related options; consider adding a "network used only for first-run model downloads" disclosure in settings.

### Lesson for the prompt template (carryover from Session 004)
Session 004 added: "Before generating an agent prompt for any module that depends on a sensor, signal source, or environmental input, the architect must explicitly answer: 'How does this work when the user changes [environment / device / context]?'"

Session 006 adds: **Before locking any architectural decision that depends on a platform capability (a specific framework, locale, codec, API), the architect must verify the capability is actually present on the target OS version, by checking the explicit enumeration (e.g., `supportedLocales`, `availableEncoders`, etc.) — not the convenience lookup that may misleadingly succeed.** Add to `00_COLLABORATION_INSTRUCTIONS.md` next session.

### Files updated this session
- `02_PRODUCT_SPEC.md` — Languages at launch section rewritten for Architecture Y
- `03_ARCHITECTURE.md` — `SpeechEngine` → `TranscriptionEngine` with two backends; entitlements; threading; data-flow diagram; open questions table
- `04_BACKLOG.md` — Phase 0 spike list, Phase 3 module table, summary totals, recommended order
- `05_SPIKES.md` — Spike #3 marked superseded; Spike #7 revised for Architecture Y; Spike #10 added
- `01_PROJECT_JOURNAL.md` — this entry

### Next session
- Generate Spike #10 (Parakeet feasibility) prompt for Claude Code
- Agent runs Phase 1 inventory (does a Core ML port exist? how do we get one?), then implementation, then validation
- After Spike #10 closes ✅ or ❌, replan from there

---

## Session 005 — 2026-05-02 — Spike #6 harness rewritten to Approach D

**Format:** Claude Code agent execution, fully verified.

### What was done
Rewrote WPMSpike Swift Package to match the Session 004 architecture pivot. Energy-based VAD removed entirely; speaking duration now derived from `SpeechAnalyzer` token-arrival timestamps via a new `SpeakingActivityTracker` type.

### Commits
- `b88a274` — refactor: remove energy VAD and calibration step
- `ebb85cd` — test: add SpeakingActivityTracker tests (red phase)
- `8bf9c27` — test: adapt WPMCalculator tests to token-derived speaking duration
- `d025c45` — implementation (all green)

### Files removed
- `Sources/WPMSpikeCLI/SimpleEnergyVAD.swift`
- `Sources/WPMSpikeCLI/NoiseFloorMeasurer.swift`
- `VADEvent` struct from `Models.swift`
- `--measure-noise-floor` and `--vad-threshold` CLI flags
- "Step 0 — Calibrate VAD threshold" section of `recordings/README.md`
- `<vad-threshold>` argument from `recordings/process_all.sh`
- `updateSessionAccumulators()`, `totalWords` accumulator, and stored `totalSpeakingDuration` from `WPMCalculator` (single source of truth now lives in the tracker)

### Files added
- `Sources/WPMCalculatorLib/SpeakingActivityTracker.swift` — `speakingDuration(in:)` via clip-then-merge with `tokenSilenceTimeout` gap-bridging; `isCurrentlySpeaking(asOf:)` via `[startTime, endTime + tokenSilenceTimeout]` containment check
- `Tests/WPMCalculatorTests/SpeakingActivityTrackerTests.swift` — 6 tests covering empty tokens, full containment, partial containment with clipping, gap-bridging at different timeouts, and `isCurrentlySpeaking` recent/old cases
- `TimeRange` struct in `Models.swift`

### CLI / CSV changes
- New flag: `--token-silence-timeout <seconds>` (default 1.5)
- New CSV columns: `token_silence_timeout_s` (column 9, between alpha and recognized columns), `total_speaking_duration_s` (column 14, appended at end)
- `process_all.sh` now takes no positional arguments; `TOKEN_SILENCE_TIMEOUT` env var optional

### Test count
14 total: 5 `WPMCalculatorTests` + 3 `EMASmoothingTests` + 6 `SpeakingActivityTrackerTests`. All green on `d025c45`.

### Test 1 expected value derivation
The Risk 1 mitigation from the planning round: instead of widening tolerance, recomputed `evenlySpacedWords_yieldsExpectedWPM`'s expected WPM under token-derived speaking duration. 60 words over 30s, 0.5s spacing, 0.4s token duration (0.1s gaps, all bridged < 1.5s timeout). Window 8s at t=25 → tokens 34–49 in window (16 words), speaking duration 17.0 → 24.9 = 7.9s. Raw WPM = 16/7.9 × 60 = 121.5. Tolerance kept at ±1%.

### Sub-agent verdict
Read `03_ARCHITECTURE.md` `SpeakingActivityTracker` section + the implementation file fresh. Reported no discrepancies. Specifically validated: clip-then-merge order (prevents cross-window gap-bridging), `isCurrentlySpeaking` semantics (timestamp inside `[startTime, endTime + timeout]`), edge cases (empty tokens, window before/after all tokens, single-token clip), Sendable conformance, default timeout value.

### Where we left off
- Spike #6 harness ready for real recordings
- No audio recorded yet — that's the next step
- After recording: run harness, sweep `(window, alpha, tokenSilenceTimeout)`, tabulate error %, lock production constants
- Spike #6 still in 🔬 in-progress status (harness done, validation against ground truth not started)

### Ups
- Agent executed cleanly. No mid-flight scope creep. Reported deviations honestly (none in this case).
- The "test count by suite" plan-time inventory caught a miscount in the prompt's acceptance criterion — the criterion said "8 original tests" but the actual count is 5 + 3. The agent reported the truth instead of fudging to match the prompt. Good signal.
- Sub-agent review caught nothing because the implementation matched the spec, not because the sub-agent was lazy — its report named specific properties it verified.
- TDD discipline held: failing tests committed before implementation; implementation didn't touch test files.

### Downs
- The acceptance criterion said "all original 8 tests" when the actual count was 5 + 3. Lesson for future prompts: when the prompt's acceptance criterion contains a count, sample size, or other hard number, require Phase 1 inventory to verify the number before approval. The Spike #6 redo prompt did this for "current test count" — and the agent caught it. Make this a permanent rule.

### Next session
- User records 6 audio clips per revised Spike #6 method
- User runs harness, generates CSV outputs across the parameter sweep
- Claude analyzes CSV, decides whether pass criteria are met, locks production constants

---

## Session 004 — 2026-05-02 — Architecture Pivot: Token-Arrival Speaking Duration (Approach D + A)

**Format:** Architecture decision triggered by user concern during Spike #6 recording prep.

### Trigger
User raised the question while preparing to record the `silence.caf` calibration clip for Spike #6: *"I'm afraid the mic will re-adjust sensitivity if there is no voice input and it will capture background noise. It's important to mention that I can be on different environments and use different headphones. how the app will adapt to that?"*

This exposed a real architecture gap, not a recording-day problem. The original design used energy-based VAD with a fixed dBFS threshold — broken for two reasons the user correctly identified:

1. **Mic AGC during silence:** macOS Core Audio + most consumer mics apply automatic gain control. When no voice input, the mic *increases* sensitivity, recording an *amplified* noise floor that doesn't match the floor during actual speech. A `silence.caf` calibration would tell us threshold = -30 dBFS, but during real speech the floor is -50 dBFS. VAD using -30 would classify quiet speech as silence, breaking WPM math.
2. **Multi-environment / multi-mic usage:** user works in coffee shops, home, hotels, with built-in mic, AirPods, USB headsets. A one-time calibration is wrong for every environment after the first. Violates FM3 (no setup).

### Decision
Combined **Approach D + Approach A**:

- **Approach D — derive speaking duration from `SpeechAnalyzer` token-arrival timestamps.** No audio energy involved. `SpeechAnalyzer` already does ML-based speech/non-speech classification internally; piggyback on it instead of reinventing energy VAD. New module: `SpeakingActivityTracker`.
- **Approach A — adaptive noise-floor for the only remaining audio-energy feature: `ShoutingDetector`.** Maintain a rolling 5s buffer of RMS samples; current noise floor = 10th percentile; shouting threshold = floor + 25 dB. Recomputed every 100ms. Works in any environment without calibration.

### Why this is better
- Removes the entire energy-VAD module. One less thing to build, debug, and tune.
- Removes the calibration step from Spike #6 and from production setup. FM3 satisfied.
- WPM math now uses Apple's robust ML-based speech detection instead of a hand-rolled energy threshold.
- ShoutingDetector becomes environment-adaptive in ~30 lines of additional code.
- Enables a clean Spike #8 to validate cross-environment robustness.

### What changed in docs

#### `03_ARCHITECTURE.md`
- `AudioPipeline` no longer fans out to a VAD module. Just buffers (to SpeechEngine) + RMS samples (to ShoutingDetector).
- New `SpeakingActivityTracker` sub-component in `Analyzer`: consumes token stream, provides `speakingDuration(in:)` and `isCurrentlySpeaking(asOf:)`.
- `ShoutingDetector` rewritten with adaptive noise-floor logic.
- Removed standalone `SpeakingDurationTracker` — its job is now done by `SpeakingActivityTracker` accumulator (`EffectiveSpeakingDuration`).
- Data flow diagram updated: token stream → SpeakingActivityTracker; RMS → ShoutingDetector (no VAD branch).

#### `05_SPIKES.md`
- Spike #6 method revised: no `silence.caf` calibration step, no `--measure-noise-floor` CLI flag, speaking duration derived from token interval lengths. Pass criteria add: "no environment-specific calibration required."
- New Spike #8: cross-environment/cross-mic robustness test. Records same script on built-in/AirPods × quiet/noisy. Validates that Approach D produces consistent WPM (<5% variance).
- New Spike #9: adaptive noise-floor validation for ShoutingDetector. Records normal/shouting in quiet/noisy. Validates that adaptive threshold catches real shouting without false positives in noisy environments.
- Spike #5 (acoustic non-words) stays deferred to v1.x.

#### `04_BACKLOG.md`
- Phase 0 spikes total: 24h → 29h (added S8 + S9, 5h).
- Phase 3 M3.2: was "VAD on audio buffers (3h)" → "SpeakingActivityTracker derive speaking duration from token timestamps (2h)". Net: 1h saved, simpler module.
- Phase 4 M4.5: `ShoutingDetector` 2h → 3h (added adaptive noise-floor logic).
- Phase 4 M4.6: `SpeakingDurationTracker` (1h) → `EffectiveSpeakingDuration: accumulate from SpeakingActivityTracker` (1h). Same effort, different source.

#### Spike #6 harness code
The agent will need to update the Spike #6 harness to match the new architecture:
- Remove `SimpleEnergyVAD.swift`
- Remove `--measure-noise-floor` CLI flag and `NoiseFloorMeasurer.swift`
- Remove `silence.caf` calibration step from `recordings/README.md`
- Replace `[VADEvent]` input to `WPMCalculator` with token-derived speaking-duration computation
- Tests become simpler: instead of constructing both `[TimestampedWord]` AND `[VADEvent]`, tests construct only `[TimestampedWord]` (with their start/end times encoding speaking activity directly)

This is a meaningful rewrite of `WPMCalculator.swift` and ~half the tests. Estimated 2-3h agent work.

### Why this is the right time to do this
- Recording any data with the current spike would test the wrong VAD model. Wasted effort, plus tuned constants would be wrong.
- The agent already wrote clean code; rewriting now (before user has invested 90 min in recording) is much cheaper than after.
- Sets up Spike #8 cleanly — once Approach D harness exists, validating it across mics is a 1-hour exercise.

### Where we left off
- Spike #6 harness exists but uses the old (energy VAD) architecture. Will be rewritten in next session.
- No recordings have been made yet. Good — recording with the new architecture will be simpler (no `silence.caf` step, fewer JSON fields).
- All planning docs updated to reflect Approach D + A.
- Next session: Claude generates a "Spike #6 redo" prompt for Claude Code to rewrite the harness. Then user records.

### Ups
- User caught a real architecture gap before spending hours on recordings. Excellent product instinct — "how does this work in different environments" is exactly the question to ask, and we should have asked it during Session 001.
- The fix is simpler than the original design, not more complex. Removed a module instead of adding one.
- Adaptive techniques (token-derived VAD, percentile-based noise floor) are robust by construction; the architecture no longer has a calibration concept anywhere.

### Downs
- Original architecture had a blind spot we didn't catch until recording day. The Session 001 docs glossed VAD as "simple energy-based or `SoundAnalysis`" without forcing the choice. Lesson: every "or" in an architecture spec is a deferred decision that needs to be resolved before the dependent spike runs, not during.
- 5h added to Phase 0 (S8 + S9). But since 1h was saved on M3.2 and the alternative was finding the problem in production, this is a rounding error.
- Some agent work to throw away (the `SimpleEnergyVAD.swift`, the `--measure-noise-floor` flag, parts of the README). Lesson re-stated: architecture decisions should be locked before agent code, not adjusted after.

### Lesson for the prompt template
Session 002 added "verification-first prompts." Session 004 suggests another rule: **Before generating an agent prompt for any module that depends on a sensor, signal source, or environmental input, the architect must explicitly answer: 'How does this work when the user changes [environment / device / context]?' If the answer is unclear, run a spike to resolve it before the dependent module's prompt.**

Will add to `00_COLLABORATION_INSTRUCTIONS.md` in next session.

---

## Session 003 — 2026-05-01 — Project Identifier Renamed to TalkCoach

**Format:** Naming decision during environment setup, no code written.

### What changed
- GitHub repo: `talk_coach`
- Local folder: `/Users/antonglance/coding/talk_coach`
- Xcode product / target / scheme / bundle base / app class: **`TalkCoach`** (was `SpeechCoach` in earlier docs)

### What did NOT change
- The user-facing product name "Speech Coach" (with space) — that's the marketing name and remains
- Anything in product spec, architecture decisions, or backlog content beyond identifier strings

### Why
User chose `talk_coach` for the repo name and `TalkCoach` for Xcode product to align identifiers with the GitHub URL. Updated all 14 technical references across 5 docs (collaboration instructions, architecture, backlog, CLAUDE.md, example prompt). Search confirms zero remaining `SpeechCoach` references.

### Where we left off
- Phase A of Xcode setup complete: Xcode 26.4.1, macOS 26.4.1, SwiftLint 0.63.2, Apple Silicon, dev account presumed signed in
- Empty GitHub repo created, awaiting Phase B (folder structure + git init + docs in place)
- Next: Phase B walk-through customized for actual paths

---

## Session 002 — 2026-05-01 — Collaboration Instructions Revised + CLAUDE.md Added

**Format:** Best-practices research, no code written.

**Goal:** Make every Claude Code prompt produce shippable, fully-verified output without requiring user testing of mediocre intermediate results.

### What changed

#### Researched current Claude Code best practices (April–May 2026)
Web searched for current guidance from Anthropic docs, community guides, and verified-author writeups (DataCamp, dbreunig.com, builder.io, claudefa.st, official `code.claude.com/docs`). Key findings:

1. **Verification is the single highest-leverage practice.** Per official Claude Code docs: *"Claude performs dramatically better when it can verify its own work. Without clear success criteria, it might produce something that looks right but actually doesn't work."* This directly addresses the user's stated goal of removing the need to test mediocre results.

2. **TDD is the strongest pattern for agentic coding.** Tests written first, committed as a checkpoint, then implementation that's not allowed to modify the tests. Closes the "agent modifies tests to make them pass" failure mode.

3. **Plan mode + "don't implement yet" guard phrase.** Without the explicit "don't implement yet" instruction, Claude Code skips revision and starts coding immediately.

4. **CLAUDE.md is per-project, gets loaded every session, must be lean.** Long CLAUDE.md files cause Claude to ignore half of them. Reference richer docs by `@path` syntax.

5. **Hooks are deterministic, CLAUDE.md is advisory.** For things that must happen every time (lint, format, tests), hooks > CLAUDE.md instructions.

6. **Writer-reviewer sub-agent pattern catches ~92% of errors before production** for high-risk modules.

7. **Two-strike rule:** if correcting the same issue twice doesn't fix it, polluted context is the problem; clean session + refined prompt fixes 89% of the time.

#### Rewrote `00_COLLABORATION_INSTRUCTIONS.md`
- Added the 5 non-negotiables every prompt must include (verification, TDD, no-modify-tests, iterate-until-green, self-review)
- Replaced the simple prompt template with a **3-phase template**: Plan (read-only, no code) → Implement (with TDD) → Self-review (mandatory checklist)
- Added explicit "Always do / Never do" rules for prompt construction
- Documented when to use sub-agents (high-risk modules) vs standard prompts
- Documented the two-strike rule and the "no state C — looks done, please test it" principle
- Added unambiguous "shippable from each prompt" definition: A) demonstrably done, B) demonstrably blocked. No middle state.

#### Created `CLAUDE.md` (new file)
Lives in repo root. Read at every Claude Code session start. Contents:
- What the project is + pointers to richer docs
- The four failure modes (FM1–FM4) restated as hard requirements
- "Always do" / "Never do" lists tuned to this project's specific traps:
  - Never enable Voice Processing IO (Spike #4 outcome)
  - Never use legacy `SFSpeechRecognizer` (use `SpeechAnalyzer`)
  - Never write transcripts to disk
  - Never use the network (sandbox entitlement is `network.client = false`)
- Project layout (file tree)
- Tech stack
- Verification commands the agent should run
- Apple documentation references the agent should consult per module
- When to use sub-agents
- "When you're stuck" protocol — try 3 approaches, then stop and report

### Why this matters
The user's concern was: *"the produced result of each prompt must be potentially shippable product fully tested and validated on test cases."* The previous prompt template was clearer than nothing but didn't enforce verification — it relied on the agent to "do the right thing." The revised template makes verification mandatory and provides the agent with the structure to self-correct.

This is also the difference between using Claude Code at ~33% success rate (unguided) and ~80%+ success rate (with structured planning + TDD + verification loops + sub-agent review).

### Decisions
- Adopted: Plan / Implement / Self-review three-phase prompt template
- Adopted: TDD as default (tests first, committed, frozen)
- Adopted: Writer-reviewer sub-agent pattern for high-risk modules (`Audio/`, `Speech/`, `Analyzer/`, `Core/`)
- Adopted: Per-module verification command (`xcodebuild test`) that agent runs in a loop
- Added: `CLAUDE.md` in repo root as the per-project context file

### Where we left off
- All planning docs finalized including verification-first prompt template
- Ready to begin actual work — recommendation remains: start with Spike #6 (WPM ground truth)
- Next session: Claude generates the first real prompt for Spike #6 using the new template; user runs it in Xcode

### Ups
- Best practices research was specific and recent — we're using current (April–May 2026) guidance, not 2024-era patterns
- The user's stated requirement ("remove need to test mediocre result") maps cleanly to the verification-first principle from official docs

### Downs
- The new prompt template is significantly longer than the previous one; risk: prompts become bureaucratic and slow to write. Mitigation: keep `CLAUDE.md` lean so the prompt itself can reference rather than repeat context.
- Hooks (deterministic enforcement) are mentioned but not yet set up. The user should configure `.claude/settings.json` with PostToolUse hooks for `xcodebuild` after edits, once the project exists. Add to backlog.

---

## Session 001 — 2026-05-01 — Planning & Architecture Lock

**Format:** Architect interview with user, no code written.

**Goal:** Establish full v1 scope, architecture, backlog, and spike list.

### What was decided

#### Product scope (v1)
- macOS menu bar app, no Dock icon (`LSUIElement = true`)
- Translucent floating widget appears automatically when ANY app activates the mic, with a per-app blocklist
- Counts only the user's mic input (not remote Zoom participants)
- WPM display: short rolling window (5–8s, EMA smoothed) + session average
- Filler-word counts (seeded dictionary, editable per language)
- Repeated phrase detection (n-grams)
- Volume / shouting detection (real-time icon)
- Auto-detect language per session — three options to be evaluated in spike
- Session metrics saved locally only; no transcripts persisted
- Two charts in expanded stats window: WPM trend, filler frequency trend per language
- No iCloud sync, no cloud anything
- Languages at launch: English, Russian, Spanish

#### Failure modes (the "if this is wrong, the app is dead to me" criteria)
1. **Destructive UI** — anything that pulls eyes when nothing actionable changed = failure. No flashing, no jitter, smooth color transitions, fixed visual layout.
2. **Unreliable data** — if the user feels fast and the widget says "good pace," trust is broken. WPM must match felt experience.
3. **No setup** — first-launch must be ≤2 actions; defaults must work out of the box.
4. **No performance impact** — invisible CPU/battery cost during 1hr Zoom calls; mic never drops out of other apps.

#### What was parked (NOT in v1)
- Acoustic non-word detection ("hmm", "ahh") — deferred to v1.x
- Auto-learn fillers / smart dictionary — deferred to v1.x (needs session data first)
- Pitch monotony — deferred to v1.x or v2 (research task disguised as a feature)
- Long pauses as a tracked metric — explicitly dropped (but VAD runs internally for accurate WPM)
- Speaker diarization (your-voice-only in mixed mic environments) — v2
- iCloud sync — never (or v3 if multi-device demand emerges)
- Cloud LLM analysis — v2+, optional
- Live transcript display on widget — explicitly dropped (lag would break trust)

#### Locked technical decisions
- **Framework:** `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+), NOT legacy `SFSpeechRecognizer`. Russian and Spanish are first-class supported in `SpeechTranscriber.supportedLocales`.
- **Mic detection:** Core Audio `kAudioDevicePropertyDeviceIsRunningSomewhere` listener — fires when any process on the system pulls audio from the input device.
- **Mic coexistence:** Disable Voice Processing IO in `AVAudioEngine` setup so we don't fight Zoom's echo cancellation; reading raw input alongside Zoom is supported by macOS HAL.
- **WPM math:** Short EMA-smoothed rolling window (5–8s), with internal VAD excluding silence from the denominator. Session average computed separately.
- **Storage:** SwiftData (macOS 14+), local only. Schema saves metrics only, no transcripts.
- **Widget:** `NSPanel` with `.nonactivatingPanel` + `.hudWindow` style mask, hosted SwiftUI view, `.canJoinAllSpaces` collection behavior. Liquid Glass material on macOS 26.
- **Language auto-detect:** TBD in Spike #2 — disqualified the "two transcribers in parallel" option due to power budget. Will be Option B (best-guess + swap) or Option C (small audio language-ID model).

### Decisions reversed during the session
- **First proposal:** Hotkey-activated v1, auto-detect deferred. **Reversed to:** Auto-detect mandatory in v1, after user pushed back that "extra steps = forgotten = missed data = bad UX."
- **First proposal:** Use `SFSpeechRecognizer`. **Reversed to:** `SpeechAnalyzer` after user reported real-world Russian failure on iOS (verified via search — `SFSpeechRecognizer` Russian on-device quality is poor; `SpeechAnalyzer` is the modern replacement with proper Russian support).
- **First proposal:** 15–20s rolling window for WPM. **Reversed to:** 5–8s EMA-smoothed window, after user named "unreliable data" as a failure mode (long window = lag = mismatch with felt experience).
- **First proposal:** Capture activating app name in session metadata for future use. **Reversed to:** Don't capture, fully anonymous sessions. (Blocklist still works at runtime without persisting.)
- **First proposal:** Standard onboarding flow with permissions, language model picker, target WPM picker. **Reversed to:** No dedicated onboarding. Permissions inline at point-of-use. Defaults pre-baked. English model bundled or silent-downloaded; RU/ES download silently on first detected use.

### Tensions worth remembering
- **"No app capture" vs "blocklist"** — blocklist needs to know which app activated the mic at runtime. Resolved cleanly: read-and-decide at activation time, never persist. But Spike #1 still needs to confirm we *can* identify the app.
- **"Don't track pauses" vs "internal VAD for accurate metrics"** — user said no pause tracking; FM2 (unreliable data) forced VAD back in for the math. Resolved: VAD runs internally, no UI surface, no pause stats, only used to make WPM trustworthy and `effectiveSpeakingDuration` accurate.
- **"Auto-detect language" vs "no setup" vs "no performance impact"** — pure auto-detect every session was user's preference; can't run two transcribers in parallel due to power budget. Pushed to Spike #2 with constraint that the chosen method must be cheap.
- **"Public release" vs "1–2 week sprint" vs "macOS new to user"** — flagged as unrealistic. User reframed: drop calendar timeline, plan by modules with effort estimates, decide pace later.

### Spike list (final, ordered by failure-mode risk)
1. **Spike #6** — WPM ground truth on real EN/RU recordings (FM2 risk)
2. **Spike #7** — Power & CPU profiling during 1hr session (FM3 risk)
3. **Spike #3** — Russian transcription quality on `SpeechAnalyzer` (architecture risk)
4. **Spike #4** — Coexistence with Zoom voice processing (FM3 risk)
5. **Spike #2** — Language auto-detect mechanism (architecture, constrained by Spike #7)
6. **Spike #1** — Identifying activating app for blocklist (deferred until needed by module)

Detailed spec for each spike: see `05_SPIKES.md`.

### Ups
- User has clear instincts and pushed back on weak proposals (correctly). Good signal-to-noise.
- Failure modes were specific and actionable — they directly drove three architectural changes (EMA window, no parallel transcribers, no onboarding).
- Scope discipline held — multiple "while we're at it" features successfully parked to v1.x.

### Downs
- Initial architecture proposal underestimated the auto-detect requirement and over-recommended hotkey activation. User correction was right.
- Initial framework recommendation (`SFSpeechRecognizer`) would have wasted a week of work; user's iOS experience caught it before any code was written.
- Timeline reality check (1–2 weeks insufficient for stated public-release ambition + macOS new + un-de-risked spikes) was uncomfortable but necessary.

### Open questions for next session
- Distribution path (App Store vs direct vs both) is "decide later" — affects Spike #1 priority and notarization workflow
- WPM target band defaults — currently set to 130–170, no language differentiation; may need per-language defaults after Spike #6 reveals natural Russian/English speech rate differences
- Liquid Glass material on macOS 26 — examples and best practices still emerging; first widget implementation will likely need iteration

### Where we left off
- Planning session complete
- All v1 scope, architecture, schema, and failure modes locked
- Next session should start with **the spikes** (#6, #7, #3, #4 in priority order) before any production code
- User will receive: this journal, the product spec, the architecture doc, the backlog, the spike doc, and the collaboration instructions

---
