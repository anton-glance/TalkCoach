# Project Journal — Speech Coach

> Append-only log of every working session. Never edit past entries destructively. New entries go at the **top**.

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
