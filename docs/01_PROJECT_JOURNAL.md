# Project Journal — Locto

> Append-only log of every working session. Never edit past entries destructively. New entries go at the **top**.

---

## Session 030 — 2026-05-13 — Spike #13 closed: Probes B, B-prime, C, C-prime, D all FAILED; Probe D Sub-test B (SCK macOS 15+ microphone tap) INCONCLUSIVE (Screen Recording TCC required, locked as architectural disqualifier even if hypothesis viable); six locked Apple-framework runtime-discovery findings establish "no standard signal distinguishes our capture from external capture at HAL level"; architect pivots M3.7.3 to disconnect-probe-reconnect algorithm; Spike #13.5 measures HAL stop-settling time at 38–45ms (P95=45ms), giving algorithm parameter ~100ms with safety margin; NO-SKIPPING rule locked as project-level convention

**Format:** Marathon probe-execution day. Single calendar day, evening close. Six probes built and executed (B, B-prime, C, C-prime, D, 13.5), four binaries committed across four spike branches. Spike #13 (the 4–6h-budget spike opened Session 028) closes definitively with all candidate mechanisms empirically rejected. Architect pivots to a new algorithmic approach that sidesteps the entire HAL-distinguishability problem. Spike #13.5 added mid-session to measure one empirical parameter the new algorithm needs. M3.7 remains open; M3.7.3 design lands Session 031 around the locked algorithm.

### What happened

Session opened with Probe B drafting (Core Audio process tap via `AudioHardwareCreateProcessTap`, macOS 14.2+). Session ran six probes across the day, three of them additive-only extensions to disambiguate prior probe results, and one (Spike #13.5) as a measurement spike for the post-Spike-#13 algorithm.

**Probe B — aggregate device wrapping the physical mic, AVAudioEngine against the aggregate.** Standalone Swift package at `Spike/Spike13_ExternalMicDetection/probe-b/` on branch `spike/13-probe-b` (commit `f52a7cc`). Agent's Phase 1 plan correctly flagged the spec contradiction at Q2 — `CATapDescription` is documented for process OUTPUT audio only, cannot carry mic INPUT audio — and proposed the aggregate-device-only architecture as the feasible interpretation. Boot smoke ran 63s natural exit. **Key finding from Probe B alone:** `AVAudioEngine.start()` on an aggregate device fires `AVAudioEngineConfigurationChange` immediately at startup; Probe B's `configChangeObserver` logged the DROP at t=0.35s but had no restart logic, so the tap never entered steady state (`Tap total buffers: 0`). The hypothesis was unanswered because no buffers ever flowed — IRS=false through the 60s window was the trivial case, not the diagnostic case.

**Probe B-prime — additive-only startup-restart observer.** Branch `spike/13-probe-b-prime` off Probe B's `f52a7cc`. Three insertion ranges, zero modifications to existing lines (sub-agent confirmed `git diff ... | grep '^-' | grep -v '^---' | wc -l` returned 0). New one-shot observer registered AFTER the existing `configChangeObserver` (FIFO delivery: existing logs DROP, new fires restart), self-deregisters after first fire, executes `stop → removeTap → installTap → start` cycle. Boot smoke produced clean steady-state evidence: `RESTART[1] outcome=success` at t=2.18s, `TAP[1] FIRST_BUFFER` at t=2.29s, 628 buffers over 62.71s at 10 buf/s. **Critical diagnostic: at t=2.19s, exactly 0.01s after restart success, `IRS[2] LISTENER t=2.19 old=false new=true`. IRS stayed true through the remaining 62 seconds of steady-state capture. Zero subsequent listener events, zero polled transitions across 62 reads.** Aggregate device wrapping the physical mic with AVAudioEngine reading the aggregate trips `kAudioDevicePropertyDeviceIsRunningSomewhere` on the physical sub-device exactly as if AVAudioEngine read the physical device directly. **Probe B FAILED. Same composition-bug shape as M3.7's original. One abstraction layer further down made no difference.** Sixth Apple-framework runtime-discovery finding locked: aggregate device wrapping a physical input as a sub-device, with AVAudioEngine reading the aggregate's input stream, is NOT HAL-invisible from IsRunningSomewhere's accounting view.

**Probe C — AVCaptureSession-based audio capture.** Standalone Swift package at `Spike/Spike13_ExternalMicDetection/probe-c/` on branch `spike/13-probe-c` (commit `52ba826`). Agent's Phase 1.1 finding on Q3 was critical: AVCaptureSession on macOS uses CMIO (CoreMedia I/O) framework as its capture abstraction, but CMIO ultimately calls into CoreAudio HAL. Whether CMIO→HAL registers as a primary HAL reader is not determinable from headers alone — the `IRS[1] BASELINE` after `startRunning()` is the empirical answer. Boot smoke ran 63s. **Result: `Cap total buffers: 0` across both runs, even with TCC=authorized via the Probe C-prime architect-side pre-grant.** `IRS_AFTER_START value=true` and `IRS final value=true` throughout — but with zero buffers, we couldn't tell if AVCaptureSession was actually capturing or had a degraded session state. **NO-SKIPPING triggered: STOP-and-report, no verdict locked on the suggestive IRS readings.**

**Probe C-prime — additive pre-session IRS baseline + TCC authorization logging + BufferDelegate retention fix.** Branch `spike/13-probe-c-prime` off Probe C's `52ba826`, six insertion ranges across two commits. First commit (`4908310`) added `IRS_BEFORE_START`, `TCC_AUTH status=`, and two new summary lines. First run revealed the root cause of Probe C's zero-buffer problem: `AVCaptureAudioDataOutput.sampleBufferDelegate` is a `weak` property in Apple's API. The local-let `BufferDelegate` inside `configureSession` was ARC-deallocated as soon as `configureSession` returned, and the session had been delivering buffers to a nil weak delegate across all three prior runs regardless of TCC status. Second commit on the same branch (`33498b2`) added two more `+` lines: file-scope `var captureDelegate: BufferDelegate?` and `captureDelegate = delegate` inside `configureSession` after `setSampleBufferDelegate`. **Post-fix boot smoke produced the clean diagnostic pair:** `IRS_BEFORE_START value=false` at t=1.24s, `SESSION STARTED` at t=2.65s, `IRS_AFTER_START value=true` at t=2.66s, `CAP[1] FIRST_BUFFER` at t=2.69s, 5627 buffers over 62.76s at 89.7 buf/s. **`startRunning()` caused the IRS transition false→true; active capture sustained IRS=true for the full 60 seconds with zero subsequent listener events and zero polled transitions across 60 reads.** **Probe C FAILED. AVCaptureSession via CMIO trips IRS during active capture, same composition bug as Probe B.** Seventh and confirming finding: no abstraction layer change (AUHAL vs CMIO) bypasses the underlying HAL accounting.

**Cumulative findings after Probe C-prime: every standard Apple audio capture path on macOS registers as a primary HAL reader of the underlying physical mic and trips `kAudioDevicePropertyDeviceIsRunningSomewhere` during active capture.** AVAudioEngine, aggregate-device-wrapped AVAudioEngine, and AVCaptureSession via CMIO all behave identically at the HAL level. The pattern is consistent enough that architect's strong prior shifted to "any standard capture API will behave the same."

**Probe D — cascading multi-candidate probe.** Single binary, three sequential cascade phases. Standalone Swift package at `Spike/Spike13_ExternalMicDetection/probe-d/` on branch `spike/13-probe-d`. The cascade design was a session-budget optimization: instead of three separate single-mechanism probes, run all three candidates in one binary with structured pass/fail gates that always advance to the next phase. **Candidate 1: ScreenCaptureKit.** Agent's Phase 1.1 finding corrected my prompt: `capturesAudio = true` with output type `.audio` is a SYSTEM AUDIO OUTPUT tap (captures what plays through speakers, doesn't touch input mic). The load-bearing test is macOS 15's `SCStreamConfiguration.captureMicrophone = true` + `microphoneCaptureDeviceID` + output type `.microphone`. Sub-test A (system-output tap) ran as a control; Sub-test B (mic-tap) is the real hypothesis test. **Candidate 2: HAL property scan.** Six candidate selectors (`IsRunningSomewhere`, `IsRunning` (without Somewhere — never read before), `HogMode`, `ControlList`, `ClockDomain`, `ProcessorOverload`) read at three observation points (NO_CAPTURE, OUR_CAPTURE, EXTERNAL_CAPTURE). The HAL scan comparison table was designed to surface any selector whose value differs between our-capture and external-capture states — a discovered HAL signal. **Candidate 3: CMIO Extensions.** Agent's Phase 1.3 finding: `CMIOExtension*` API is provider-side only (`connectClient:` / `disconnectClient:` are callbacks for the PROVIDER receiving connections, no client-side observation surface). **Candidate 3 marked `API_MISMATCH_DEAD` at plan time, no runtime implementation.** Sub-tests A and B for Candidate 1, plus the full Candidate 2 cascade with HAL-reference-capture using Probe C-prime's retained-delegate pattern, were implemented and executed.

**First Probe D run: TCC-blocked at Sub-test B.** "The user declined TCCs for application, window, display capture" — Terminal did not have Screen Recording TCC granted. The 5-second completion-deadline mechanism (architect-prescribed Amendment 1) worked correctly: probe did not hang on the dialog, logged `SCK_TCC_REQUIRED`, advanced to Phase 2. HAL scan ran but all three observation points produced identical tables — no human participated in CHOREO_PROMPT during the unattended run. **Eighth finding locked: SCK macOS 15+ `captureMicrophone=true` requires Screen Recording TCC, even when ONLY capturing microphone audio with no display content captured.** This is a product-architecture disqualifier independent of IRS behavior — TalkCoach.app would need Screen Recording entitlement for SCK mic-tap to be viable, and Screen Recording is a permission users associate with surveillance, not microphone capture. UX cost exceeds UX benefit for v1 even if Sub-test B were to pass IRS.

**Probe D second run: NO-SKIPPING STOP at Phase 3 reporting time.** Agent identified two structural problems before spawning sub-agents: (1) HAL-ref AVCaptureSession was running concurrently with SCK sub-tests, so IRS readings during SCK Sub-test B were CONFOUNDED — IRS was already true from HAL-ref before SCK started, so a FALSIFIED verdict for SCK could not be cleanly attributed to SCK; (2) the synchronous Bash tool runs `swift run` blocked, no channel for the architect to act on CHOREO_PROMPT in real time. **Agent reported STOP cleanly per NO-SKIPPING, did not aggregate verdict on confounded data.** Architect accepted both observations as STOP triggers.

**At this point — six probes built, all empirically rejected — architect made the pivot call.** Instead of fixing Probe D's cascade ordering and re-running, architect surfaced to product owner: every standard Apple capture API trips IRS, SCK's mic-tap path is disqualified by Screen Recording permission cost regardless of empirical outcome, CMIO Extensions is provider-side only. The product-side question was raised: continue probing (Path i in architect framing) or close Spike #13 and accept Candidate 5 alternatives (explicit-end button or extended inactivity timer, Path ii)? **Anton proposed a different architectural pattern: disconnect-probe-reconnect.** When the inactivity timer fires (Locto user is silent for N seconds), save session state to SwiftData, tear down AudioPipeline, wait briefly for HAL state to settle, read IRS in our absence (now an unambiguous "anyone else?" question), then either finalize the session (if IRS=false) or rebuild AudioPipeline and resume capture (if IRS=true).

**Architect's response: strong yes.** Algorithm sidesteps every locked Spike #13 finding by changing the framing of the problem. We don't need the HAL to distinguish us from them; we make the question moot by temporarily leaving the room. No new APIs, no new permissions, no new framework dependencies. Composes from shipping code (M2.1 listener pattern, M2.7 SwiftData session persistence, M3.7.2 inactivity timer scaffolding). Only empirical unknown: how long after `AudioPipeline.stop()` does `IsRunningSomewhere` actually settle to false on the physical mic? **Spike #13.5 measures this parameter.**

**Spike #13.5 — HAL stop-settling time measurement.** Standalone Swift package at `Spike/Spike13_5_HALStopSettling/probe/` on branch `spike/13.5-hal-stop-settling`. Single-mechanism measurement spike, not a hypothesis-pass spike. Ten capture-then-stop cycles with plain `AVAudioEngine` against the default input (matching M3.7 production AudioPipeline mechanism exactly). Each cycle measures the delta between `engine.stop()` return and the `IsRunningSomewhere` true→false transition observed via the property listener. Listener registered on a dedicated background queue (NOT main) with `DispatchTime.now().uptimeNanoseconds` captured as the very first line in the callback BEFORE dispatching to main for state mutation — eliminates main-queue-drain latency from the measurement. 50ms backup polling timer runs in parallel during each cycle's 1-second settle window as a belt-and-suspenders measurement. **Boot smoke ran 44s natural exit. 10/10 cycles settled via listener within 1 second. Zero missed settles. Zero NO-SKIPPING trigger. Zero IRS carry-over between cycles. Zero unexpected config-change notifications.**

**Spike #13.5 measurement (this is the production parameter for M3.7.3):**
- Min settling time: 38.331 ms
- Max settling time: 44.854 ms
- Mean settling time: 41.451 ms
- P95 (= max for n=10): 44.854 ms
- All 10 backup-poll entries showed "—" (listener fired and cancelled the backup timer before any 50ms poll tick caught the transition; listener latency is consistently sub-50ms)
- Tight, deterministic distribution: 6.5ms spread across 10 cycles, no outliers

**M3.7.3 algorithm parameter locked: ~100ms wait after `AudioPipeline.stop()` returns before reading IRS** (max measured 45ms + safety margin for cross-hardware variance and AirPods scenarios).

### Architectural decisions locked

1. **NO-SKIPPING rule established as project-level convention.** If something does not work and no clear solution is found, architect and agent continue resolving in the same session. Do NOT pass forward, do NOT move to the next item, do NOT accept v1 limitation as the escape hatch. References the M3.7 → M3.7.1 → M3.7.2 cycle (Sessions 026–028) as the anti-pattern this rule prevents. **The Session 030 entry shows the rule in action: six probes executed, three additive-only extensions to disambiguate prior probe results, one mid-cycle STOP at Probe D Phase 3 reporting time when the agent identified two structural problems, one mid-cycle STOP at Probe C when zero buffers blocked the diagnostic.** Supersedes spec language in `05_SPIKES.md` line 906 about "Accept inactivity-timeout as v1 mechanism if all three probes fail" — that escape hatch is closed. The disconnect-probe-reconnect algorithm proves the rule's value: by refusing to accept "no signal exists" without exhausting the search, the architect surfaced a different framing of the problem that solved it without needing the signal at all.

2. **Probe-extension pattern locked across four uses in one session.** Probes B→B-prime, C→C-prime (two commits), and the additive-only constraint verified on every extension via `git diff <parent>..HEAD -- <path> | grep '^-' | grep -v '^---' | wc -l` returning 0. **Lock: the additive-only extension pattern from Session 029 is canonical and operates at scale.** Six insertions in Probe C-prime's cumulative diff against `spike/13-probe-c` (two commits, one branch) all `+` lines between unchanged context. Sub-agent code reviews verified each.

3. **Hypothesis-direction inversion in self-review is a known agent failure mode.** Probe C-prime caught the agent's Sub-agent 2 inverting the hypothesis direction (interpreting IRS=true during active capture as "supporting the hypothesis" when the hypothesis is that AVCaptureSession does NOT trip IRS). Architect corrected before locking any verdict. **Lock: every probe-extension prompt that involves a viability/falsification verdict states the hypothesis direction explicitly in the prompt, in the Phase 3 self-review marker block, AND in the Sub-agent 2 brief.** Probe D and Spike #13.5 prompts include this explicit direction-statement pattern; both agents stated direction correctly.

4. **The weak-property gotcha is locked as a defensive-coding rule.** `AVCaptureAudioDataOutput.sampleBufferDelegate` is declared `weak`. `SCStream.delegate` is `weak`. Local-let delegate instances will be ARC-deallocated immediately after function return, and the session/stream will deliver buffers to a nil weak delegate — silently, no crash, no warning, just zero buffer flow. **Lock: any Apple framework delegate property that's declared `weak` MUST have its delegate instance retained by a separate file-scope strong reference (or instance-property strong reference in production code).** The defense costs zero performance and prevents a debugging nightmare. Probe C-prime fix is the canonical example.

5. **The disconnect-probe-reconnect algorithm is the M3.7.3 design.** Backlog and 05_SPIKES.md updated. The algorithm composes shipping code (M2.1 listener pattern, M2.7 SwiftData persistence, M3.7.2 inactivity-timer trigger), introduces no new APIs, no new permissions, no new framework dependencies, and is empirically de-risked by Spike #13.5's measured 45ms max settling time. M3.7.2's inactivity threshold becomes a user-facing settings parameter rather than a hardcoded constant.

6. **The M3.7.2 inactivity threshold value migrates to user settings.** Per Anton's product call this session: rather than picking a single threshold value that trades off false-positive-end-while-pausing vs slow-to-end-when-done, expose the threshold as a Settings parameter the user can tune. Default value to be picked during M3.7.3 implementation (likely 15–30s based on use-case mix). The threshold is read at session-arm time and used by the inactivity-timer's per-tick check. Backlog updated to reflect the new settings parameter.

7. **Spike #13 outcome: closed with documented exhaustion of standard Apple capture APIs.** Six locked Apple-framework runtime-discovery findings now form the project's intellectual capital on this surface. Future investigations into "is something else using the mic" will NOT revisit any of: `AVCaptureDevice.isInUseByAnotherApplication`, `kAudioProcessPropertyIsRunningInput`, aggregate-device wrapping, AVCaptureSession via CMIO, ScreenCaptureKit mic-tap (Screen Recording TCC disqualifier), CMIOExtension client-side observation (provider-side API only). The disconnect-probe-reconnect algorithm makes the question moot.

### Procedural lessons

1. **Cascading probe design caught one cascade-ordering bug at Phase 3 reporting time.** Probe D's HAL-ref AVCaptureSession was running concurrently with the SCK sub-tests, which meant IRS readings during SCK Sub-test B were confounded — IRS=true was sufficient to come from HAL-ref alone, not from SCK. The agent identified this AT the moment of reporting Phase 3, BEFORE spawning sub-agents. **Lesson: cascading probes must order phases such that earlier phases' apparatus is fully torn down (HAL state settled) before later phases' measurement begins. The probe design must not have apparatus from one phase running during another phase's measurement.** If the architect had not been alerted by the agent's NO-SKIPPING report, the FALSIFIED verdict for SCK would have been locked on confounded data. This is the second time in two sessions the agent caught architect-level design issues via NO-SKIPPING discipline (Probe C zero-buffers being the first).

2. **Sync Bash tool prevents real-time architect participation in long-running probes.** Probe D's CHOREO_PROMPT was designed assuming the architect could read the printed prompt and act on it (open Voice Memos, etc.) while the probe was running. The agent's invocation via `swift run` through the Bash tool blocks until the process exits, so no interleaved user actions are possible. **Lesson: probes that require real-time architect participation must either (a) be invoked directly by the architect from their own Terminal where they have full process control, or (b) use a different orchestration mechanism (file-based handshake, networked socket, etc.). The Bash tool is for unattended probes only.** Probe D's design has both halves of this issue; future probes with CHOREO_PROMPT must specify which orchestration model they use.

3. **Architect's prompt-engineering miss caught by agent: spec named log line that did not exist in target code.** Probe C-prime prompt anchored Insertion C against a `SESSION CONFIGURED:` log line that did not exist in Probe C's `main.swift` at commit `52ba826`. Agent identified the discrepancy, proposed the real anchor (the closing brace of the `guard configureSession else { ... }` block followed by the existing `// startRunning() blocks synchronously` comment), and proceeded with the actual anchor. **Lesson: when amplifying an additive-only extension prompt that references existing-file anchor points, verify each named anchor exists in the target file at the named commit BEFORE issuing the prompt.** Same class of strike as Session 029's "boot-smoke condition not derived from approved plan" miss; the corrective pattern (`re-derive from the actual code, not from the spec text`) generalizes.

4. **Architect's hypothesis-direction inversion correction landed inside a single turn.** When Sub-agent 2 in Probe C-prime's reply incorrectly stated that IRS=true during active capture "supported" the hypothesis, the architect did not lock the verdict but instead immediately surfaced the inversion as a STOP-trigger, drafted Probe C-prime's hypothesis-direction-explicit Sub-agent 2 brief, and ran the post-fix run with both the agent self-review and Sub-agent 2 stating direction correctly. **Lesson: hypothesis-direction inversion is a known failure mode of fast pattern-matching at the sub-agent level. Every probe prompt that involves a viability/falsification decision must state the direction explicitly in three places: the main prompt body, the Phase 3 self-review marker block, and the Sub-agent 2 brief.** Probe D and Spike #13.5 prompts adopted this pattern; both ran correctly.

5. **Six-of-six sub-agent reviews held credibility standard, plus six-of-six self-reviews held NO-SKIPPING discipline.** Across Probe B, B-prime, C, C-prime, D, and Spike #13.5: every Phase 3 self-review marker block was reproduced verbatim with quoted evidence; every pair of sub-agent reviews appeared in the same reply as the self-review (no dangling-promise phrasing); every sub-agent review returned with line-level evidence; Spike #13.5 sub-agent 2 spot-checked one cycle's arithmetic (cycle 7's listener timestamp delta = 38,331,208 ns, matching the reported `ns_from_return` exactly). **The disciplines locked Sessions 020 / 027 / 028 / 029 / 030 are now habitual — no architect prompting required to maintain them. They are the agent's default operating mode.**

6. **The disconnect-probe-reconnect algorithm emerged from architect-product-owner dialogue, not from agent-only reasoning.** Six probes' worth of negative evidence built up a strong prior in the architect's mind that the search was exhausted. The product owner reframed the problem by removing the assumption that the HAL had to do the distinguishing. **Lesson: when an engineering search exhausts the obvious solution space, surfacing the search-completeness state to the product owner can produce reframings the engineer wouldn't reach alone. The product owner sees the problem at a different level of abstraction.** This is a process pattern worth keeping: at the boundary between "I've tried everything reasonable" and "we should accept the workaround," surface to the product owner.

7. **Marathon session discipline held across six probes and a measurement spike.** The session ran from morning through ~10:40pm local time (~14h wall-clock window, ~7–9h of active work scattered across with breaks). Reply-formatting convention (Session 027) held across every agent reply: pure prose with indented blocks OR single fenced code block, never mixed. Architect terminal commands all prefixed `cd /Users/antonglance/coding/TalkCoach &&` with absolute paths, one-action copy-paste. Zero copy-paste friction regression. Six probe prompts, four trigger messages, eight close-out documents — all delivered as standalone .md files via `present_files` or as inline fenced blocks per the rule.

### Time

Session 030 wall-clock: **~7–9h estimated** (marathon day, ~14h calendar window with intermittent breaks). Broken down by probe path:

- Probe B drafting + Phase 1+2+3 + sub-agent: ~1h
- Probe B-prime drafting + Phase 1+2+3 + sub-agent: ~1h
- Probe C drafting + Phase 1+2+3 + sub-agent + initial-run analysis: ~1.5h
- Probe C-prime drafting + Phase 1+2+3 (first commit) + STOP-and-report cycle + Phase 1.2 fix (second commit) + Phase 3 + sub-agents: ~1.5–2h
- Probe D drafting (cascade design) + Phase 1+2+3 first run + STOP analysis: ~2h
- Architect↔product-owner pivot dialogue and Spike #13.5 design: ~0.5h
- Spike #13.5 drafting + Phase 1+2+3 + sub-agent: ~1h
- Close-out: ~0.5h (this entry + spec updates + ledger + backlog)

**Spike #13 cumulative across Sessions 029 + 030: ~10–13h actual against 4–6h budget = ~2.0–2.5x estimate.** Six probes consumed roughly 6x the original "if all three probes fail" budget allocation. Budget overrun was driven by: (a) the strong NO-SKIPPING discipline produced three additive-only extensions where a less-rigorous approach would have locked false verdicts, (b) Probe D's cascade design caught its own ordering bug at reporting time rather than silently delivering bad data, (c) Spike #13.5 was an unplanned mid-session measurement spike that emerged from the architectural pivot. **The overrun bought us the disconnect-probe-reconnect algorithm and a measured production parameter. Spike #13 closes with a working architectural path, not a documented limitation.**

**M3.7 cumulative across Sessions 026 + 027 + 028 + 029 + 030: ~17–22h actual against 3h estimate = ~5.5–7x estimate, M3.7 STILL OPEN pending M3.7.3 implementation.** M3.7.3 is now scoped: implement the disconnect-probe-reconnect algorithm (~3–4h estimated based on composing shipping code) + inactivity-threshold-as-settings-parameter (~1h) + integration smoke gate including real Voice Memos / Zoom test + AirPods test. Total M3.7.3 estimate ~6–8h with smoke; closes M3.7 if smoke clean.

**Session 030 start:** ~morning local (Mexico, UTC-5) per Anton's continuation framing.
**Session 030 end:** ~10:40pm local — Anton called the wrap explicitly: "tomorro we will integrate and run a real test where we will see the real delays, losses etc."
**Spike #13 cumulative:** Sessions 029 + 030. CLOSED.
**Spike #13.5 cumulative:** Session 030 only. CLOSED. Measurement landed.
**M3.7.3 starts:** Session 031.

---

## Session 029 — 2026-05-13 — Spike #13 Probe A executed (KVO observer) + Probe A-prime extension (1Hz polling alongside KVO); both empirically fail across three-run choreography (built-in mic, Locto active, AirPods switch); fifth Apple-framework runtime-discovery finding locked with tighter wording than spec predicted; Probe B (Core Audio process tap) is next session

**Format:** Single-session probe execution day. Morning start, ~2.5–3.5h wall-clock. Two CLI probes built, six manual choreography runs executed across two probe binaries. Spike #13 Probe A is definitively closed as failed. M3.7 remains open; Probe B drafting deferred to Session 030 for a fresh start.

### What happened

Session opened with Spike #13 Probe A spec at `05_SPIKES.md:794` and the four hard requirements (detects external recording, survives our own capture, survives mid-session default-device change, observable from sandboxed app). Probe A's hypothesis: `AVCaptureDevice.isInUseByAnotherApplication` is documented as KVO-observable; if it reflects reality from our sandbox and KVO fires reliably on state changes, this is the cleanest possible signal — zero AudioPipeline changes, ~2h integration cost.

**Probe A binary:** standalone Swift package at `Spike/Spike13_ExternalMicDetection/probe-a/`, 99-line `main.swift`, builds via `swift build` in ~0.1s. KVO observer on `AVCaptureDevice.default(for: .audio)` for `isInUseByAnotherApplication`, with `[.initial, .new, .old]` options, KVO token stored at file scope so it lives the full 60s. `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDefaultInputDevice` for AirPods-switch detection, with re-attach pattern (set `kvoToken = nil` before reassign for clean teardown). Choreography markers via `DispatchQueue.main.asyncAfter`. 60s timer via `asyncAfter(deadline: .now() + 60) { exit(0) }` combined with `RunLoop.main.run()`. Phase 3 self-review + sub-agent code review both clean. Branch `spike/13-probe-a`, commit `279152f`.

**Probe A three-run choreography:** Run-1 was Voice Memos (replaced original QuickTime spec because QuickTime arms the mic at recording-window-open for level metering, which would taint the test) recording twice on built-in mic (t=7→20, t=30→50). Run-2 was Locto active in parallel (Locto-on-launch does NOT arm the mic — empirically confirmed; this run became a second idle baseline rather than the intended HR2 test). Run-3 was AirPods device switch at t=12s, Voice Memos recording on AirPods t=25→43, switch back at t=55s. **Result across all three runs: 0 KVO state-change callbacks. The only KVO callbacks that fired were the `.initial` deliveries at attach time (1 in run-1, 1 in run-2, 3 in run-3 due to two AirPods re-attaches in run-3).** Device-change listener fired correctly both AirPods switches in run-3 with sub-100ms latency; re-attach pattern worked flawlessly.

**Probe A's KVO failure left one ambiguity unresolved:** was the property live but KVO infrastructure broken, or was the property itself inert? Two interpretations both consistent with the data. The decision tree at `05_SPIKES.md:902` jumps from "Probe A fails" to "Probe B path (5–7h AudioPipeline rewrite)" — a 5–7h investment with residual ambiguity about whether Probe A had a salvageable polling fallback worth ~2h instead. **Cost asymmetry was sharp: ~1h to disambiguate vs ~4h saved if Probe A's property was live-but-KVO-broken.** Architect decided to extend the probe with a 1Hz polling timer reading the same property alongside the KVO observer.

**Probe A-prime binary:** additive-only extension to `Sources/probe-a/main.swift` on branch `spike/13-probe-a-prime` (off `spike/13-probe-a` at `279152f`). Three insertion ranges, zero modifications to existing lines (sub-agent code review confirmed: every diff hunk is `+` lines between unchanged context lines). `Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)` fires on `RunLoop.main`. Per-tick `AVCaptureDevice.default(for: .audio)` re-call (chosen over a `currentDevice` file-scope var to avoid touching `defaultDeviceBlock`'s body, preserving the additive-only constraint). First-tick logs `POLL[1] BASELINE: <value>`; subsequent ticks log silence on no-change, `POLL[N] TRANSITION: <old> → <new>` on change, with `(post-device-change)` tag when the prior tick saw a `reattachCount` increment. Three new summary lines. Boot smoke ran the full 60s naturally (agent noted macOS lacks GNU `timeout`; natural exit is stronger evidence than SIGTERM kill — accepted). Branch `spike/13-probe-a-prime`, commit `4ada2c7`. Phase 3 self-review and sub-agent code review both clean.

**Probe A-prime three-run choreography (same physical actions, new log paths):** Run-1 Voice Memos twice on built-in mic. Run-2 Locto active in parallel (same launch-doesn't-arm-mic confirmation as Probe A run-2; Xcode debug session SIGKILLed at session close). Run-3 AirPods switch + Voice Memos on AirPods. **Result across all three runs: `Poll transitions total: 0` in every summary.** 186 polled reads across the three runs combined (62 per ~62-second run, drift-free 1Hz). Polling final value: `false` in every run. The property never moved off false in any run, on any device (built-in mic OR AirPods), regardless of who was actively recording.

**The empirical verdict is definitive: `AVCaptureDevice.isInUseByAnotherApplication` is INERT at runtime from our sandbox context — not just KVO is broken, but the underlying property itself does not update when external apps (Voice Memos) record on the observed device.** This is the **fifth Apple-framework runtime-discovery finding**, with TIGHTER WORDING than the spec at `05_SPIKES.md:824` predicted. The spec anticipated finding 5 as "KVO callbacks never fire even though documented as observable." The actual finding is stronger: the property itself does not reflect the reality of "another application is using this device" — KVO simply has nothing to fire on because the property doesn't change.

The only theoretical out for Probe A would be "maybe the property is scoped to `AVCaptureSession`-class clients specifically, and Voice Memos / Zoom / QuickTime use `AVAudioEngine` so they wouldn't trip it." But our target external apps (Zoom for the canonical hour-long-call use case) all use `AVAudioEngine` or similar non-`AVCaptureSession` paths. Whatever the property MIGHT detect, it doesn't detect what we need it to detect.

**Spike #13 Probe A locked as failed. Probe B (Core Audio process tap via `AudioHardwareCreateProcessTap`, macOS 14.2+) is the next probe per the decision tree at `05_SPIKES.md:902`.** Probe B path: ~1h probe + 4–6h AudioPipeline rewrite = ~5–7h total. Drafting deferred to Session 030 for a fresh start — Anton called the wrap explicitly, noting the morning start and the desire to begin Probe B with full energy rather than at session-fatigue end.

### Architectural decisions locked

1. **Empirical-validation culture extended to "polled vs listener" parity.** When a property is suspected of having broken event delivery (KVO not firing, listener not firing), the cheap disambiguation is to add a parallel polled read of the same property and run the same choreography. The cost is bounded (~1h of agent work + ~10min of re-running manual choreography), and the result is definitive in both directions: confirms-and-locks if polling also fails, recovers a viable signal if polling succeeds. **Lock: any future probe that relies on event-driven detection of an Apple HAL/AVF property is required to ALSO include a 1Hz polling reference in the same probe binary.** Spike #13 Probe A → Probe A-prime is the canonical example.

2. **Probe A-prime's additive-only diff pattern is the canonical "extend an existing probe" shape.** Three constraints made this work: (a) no modification to existing lines (sub-agent confirmed every hunk was `+` lines between context lines); (b) new code on a new branch off the prior probe's commit; (c) original probe code preserved as-is for side-by-side evidence comparison. **Lock: extending a probe to disambiguate a hypothesis ships on a new branch off the prior probe's tagged commit, with additive-only diffs, and both signals run in parallel.** No replacement, no inline modification.

3. **The five-finding Apple-framework runtime-trap inventory is locked.** Original four findings (Session 028): misleading `supportedLocale(equivalentTo:)`, non-nil `assetInstallationRequest` for installed models, silent-no-fire `kAudioProcessPropertyIsRunningInput` listener, plus the M3.7-MicMonitor composition bug. Fifth finding now locked: **`AVCaptureDevice.isInUseByAnotherApplication` is inert at runtime from a sandboxed app context — the property itself does not update when external apps record on the device, not merely that KVO event delivery is broken.** Going forward, every probe-spike investigation on HAL/AVF/Speech APIs is presumed to potentially uncover a finding; the inventory grows. **Lock: any HAL/AVF/Speech property used in production must have empirical evidence that BOTH direct-reads AND event-delivery work in the actual sandbox context, validated under realistic concurrent usage.**

4. **AVCaptureDevice path is closed for external-mic detection.** The whole `AVCaptureDevice` surface is not just KVO-broken for our use case — the underlying property value is unreliable from sandbox. Future investigations into "is something else using the mic" will NOT revisit `AVCaptureDevice` properties. **Lock: `AVCaptureDevice.isInUseByAnotherApplication` is not a usable signal in TalkCoach v1 and will not be re-investigated absent a major OS-level behavior change.**

### Procedural lessons

1. **Architect's prompt-engineering miss caught by the agent: boot-smoke condition contradicted the approved Phase 1 plan.** My Phase 2 trigger for Probe A-prime specified "8–10 total POLL lines" in the 10s boot smoke. The approved Phase 1 plan specified "log only on transitions plus baseline" — quiet-by-default. These are inconsistent: an idle 10s boot smoke produces exactly ONE `POLL[1] BASELINE` line, not 8–10. The agent flagged the inconsistency transparently in its Phase 3 self-review ("REQUIRES EXPLANATION"), defended the approved-plan behavior with `Polled reads total: 62` as evidence, and did not silently paper over. **Lesson: when amplifying an approved Phase 1 plan with Phase 2 verification conditions, re-derive the conditions from the plan's actual log shape; do not import generic "N lines of output" expectations.** Strike against architect prompt-writing; the agent's response was correct.

2. **Architect's `timeout` portability assumption was wrong.** Phase 2 boot-smoke command specified `timeout 10 swift run probe-a`; macOS does not ship GNU `timeout` by default. Agent ran the full 60s naturally and noted the substitution: "natural exit is a STRONGER verification than a timeout kill — exit(0) confirms the summary block executed completely." This is correct on the merits — a SIGTERM kill doesn't prove summary code runs; natural exit does. **Lesson: GNU coreutils commands (`timeout`, `gtimeout`, `gdate`, etc.) are not portable to macOS by default. Architect terminal commands targeting macOS should not assume GNU coreutils.** Strike against architect prompt-writing; agent's substitution and rationale were correct.

3. **Agent's "sub-agent review will follow when the background agent reports" closing line is misleading promise framing.** The agent wrote that line at the end of its Phase 3 self-review for Probe A-prime, implying the sub-agent had been launched and findings would follow in a subsequent reply. The architect read this as "still pending" and explicitly held testing — correctly. The user then clarified the sub-agent had completed and provided the verbatim findings inline. **Lesson: agent self-reviews and sub-agent reviews should be reported in a single reply where possible; the dangling-promise phrasing is a known agent tic that creates architect-side confusion about whether a step has actually completed.** Going forward, prompts will explicitly require: "Wait for sub-agent completion and include its verbatim output in the same reply as Phase 3 self-review. Do not close your turn with a pending-promise reference to the sub-agent."

4. **Architect's "Locto active in parallel" run-2 design did not test HR2.** Both Probe A and Probe A-prime had a run-2 intended to validate hard requirement #2 (signal goes false when ONLY we are recording). The run-2 design was "launch Locto, wait for menu-bar icon, then run probe." But Locto-on-launch does NOT arm the mic — the orange dot doesn't come on. So run-2 was never an active-capture test; it was a duplicate idle baseline with Locto's UI present. The user noted this both times. **HR2 was not empirically tested at the probe level for Probe A.** This doesn't change the verdict (the property is inert in all conditions, so HR2 is moot), but is a process flaw to fix in Probe B: run-2 must specify a path to trigger an active session in Locto (widget activation or equivalent) so the orange dot is genuinely ON during the probe's observation window. **Lesson: HR2-testing run-2 designs must specify the EXACT user actions needed to bring Locto's mic-active state to true, not assume launch alone is sufficient.** Prompt drafting for Probe B's run-2 will require this.

5. **The Probe A → Probe A-prime cost asymmetry validated the decision to disambiguate before pivoting to Probe B.** Total cost of Probe A-prime: ~1h of agent work + ~10min of manual re-runs = ~1.2h. Confirmed Probe A's underlying property is inert (not just KVO broken). Outcome: zero residual ambiguity heading into Probe B; the project's runtime-trap inventory gets a precise finding (#5) rather than a fuzzy one. **Lesson: when a probe fails on event-delivery, the standard follow-up is a 1Hz polling extension before declaring the probe fully dead.** This becomes a project pattern, formalized in Architectural Decision 1 above.

6. **Six-in-a-row substantive sub-agent reviews held the standard.** Both Probe A code review (6 items, all PASS with verbatim evidence) and Probe A-prime code review (6 items, all PASS with verbatim diff quotes) returned with line-level evidence. No "0 issues found" without notes; no rubber-stamp PASSes. Session 020's credibility standard held.

7. **Reply-formatting and terminal-commands conventions (Sessions 026/027 locked) held throughout.** Zero copy-paste regression. Probe A and Probe A-prime both delivered as standalone `.md` prompt files via `present_files`. Architect terminal commands all prefixed `cd /Users/antonglance/coding/TalkCoach &&` with absolute paths, one-action copy-paste.

### Time

Session 029 wall-clock: **~2.5–3.5h estimated** (morning session, single-day, full close-out with five doc deliverables). Probe A path: ~1.5h (prompt drafting + Phase 1+2+3 + sub-agent + three manual runs). Probe A-prime path: ~1.0–1.5h (prompt drafting + Phase 1+2+3 + sub-agent + three manual runs). Close-out: ~0.5h (analysis + journal + spec updates + ledger + Probe B handoff prompt). **Spike #13 Probe A path total: ~2.0–3.0h actual against 2h "if pass" budget; ran ~1.0–1.5x estimate driven by the disambiguation extension. Spike #13 cumulative across one session: ~2.5–3.5h actual against 4–6h total spike budget — Probe A consumed ~50% of the spike's total budget for one of three probes.** Remaining budget for Probe B: ~2.5–3.5h of the original 4–6h band, against Probe B's per-probe estimate of 5–7h — Probe B will overshoot the spike's total budget regardless. Acceptable: Probe B's rewrite cost is unavoidable if it passes, and "all three fail" is the only worse outcome.

**Session 029 start:** ~07:00 local (Mexico, UTC-5) per Anton's "it's morning" framing.
**Session 029 end:** journal-write time (~08:30–09:30 local estimate).
**Spike #13 cumulative:** Session 029 only. Probe B drafts Session 030.

---

## Session 028 — 2026-05-12 — M3.7.2 inactivity-timer ships as INTERIM deactivation; fourth Apple-framework runtime-discovery finding locked; product-UX miss caught at session close — Spike #13 opened for correct external-mic-detection signal

**Format:** Multi-day marathon close (Sessions 027 + 028 across ~3 calendar days). M3.7.2 ships as code-complete interim, but M3.7 itself does NOT close — the inactivity-timer doesn't match the product UX (orange-dot-tied session lifecycle). The session ends with Spike #13 opened to find the correct external-mic-detection signal.

### What happened

Session opened with M3.7.1 polling code committed (commits `2486dde` red, green; `cc0855b` teardown-race fix), 277 tests green, smoke gate blocked. First major beat: 86-tick polling diagnostic with QuickTime as external recorder, ~62 seconds of `External tracking:` log lines.

**Diagnostic disproved M3.7.1's load-bearing assumption.** Direct reads of `kAudioProcessPropertyIsRunningInput` returned `false` for QuickTime across every one of the 86 ticks while QuickTime was actively recording. QuickTime's PID never appeared in our `kAudioHardwarePropertyProcessObjectList` enumeration. The only process showing `isRunningInput=true` was our OWN `corespeechd` daemon (PID 937), spawned by SpeechAnalyzer in M3.7. Three conclusions: HAL filters external recording processes out of our sandbox's process view; `kAudioProcessPropertyIsRunningInput` direct reads are not symmetric across the process boundary; this is the **fourth Apple-framework runtime-discovery finding** for the project (after misleading `supportedLocale(equivalentTo:)`, non-nil `assetInstallationRequest` for installed models, silent-no-fire `kAudioProcessPropertyIsRunningInput` listeners).

Architect presented Options A/B/C/D for next direction: A trust-the-wiring; B user-action-driven; C accept constraint; D audio-content inactivity. Anton made the Chief of Product call: restore original M2.x UX — widget appears when mic active, fades 5s after mic-inactive, X-button as manual override. **The Chief of Product call's intent was clear: session lifecycle tied to the macOS orange-dot mic indicator, NOT to speech activity.**

**Architect's engineering response was incorrect.** Architect interpreted the call as "use audio-content inactivity as the signal" (Option D), drafted the M3.7.2 prompt accordingly, ran the agent through Phase 1+2+3, validated smoke, and was about to tag `m3.7-complete` when Anton flagged the actual product implication: in an hour-long Zoom call where the user speaks for 10–15 minutes of the call, a 30s inactivity timer would END the session during listening portions, fragmenting one pitch performance into multiple micro-sessions or missing it entirely.

The Chief of Engineering error was real: architect traded the clear product UX (orange-dot-tied lifecycle) for an "engineering-elegant" inactivity-timeout that sidestepped the Apple HAL problem but did not match what the product needed. The error pattern: when Apple framework APIs trap us, the engineering instinct is to find a clean orthogonal signal, even when that orthogonal signal doesn't match the product's actual semantics. **The Chief of Engineering role exists precisely to prevent this trade-off; architect failed to enforce it this session.**

M3.7.2 still shipped as code-complete in implementation (clean InactivityTimer Convention-6 protocol with DispatchInactivityTimer production conformance, arm-inactivity-timer at top of runSession for uniform contract across wiring success/failure paths, cancel-at-top in endCurrentSession and stop for race-free idempotency, FakeInactivityTimer with `lastScheduledTimeout` regression guard, 8 new tests, ~475 lines net deletion of M3.7.1 polling code, sub-agent ninth-in-a-row substantive review with one harmless-double-cancel observation noted as non-issue). Smoke ran cleanly across both inactivity and X-button scenarios (Session 80A0B93E: 15 real speech tokens, 59.1s duration, 9ms teardown; Session 8FC750D5: X-button dismiss with no inactivity-timeout firing). The CODE quality is good; the PRODUCT match is wrong.

**M3.7 does NOT close this session.** The token pipeline works (15 real speech tokens in smoke Session 80A0B93E, 59.1s session duration, 9ms teardown). The deactivation signal is wrong.

**Spike #13 opened at session close.** Three-probe empirical investigation of external-mic-detection signals: (A) `AVCaptureDevice.isInUseByAnotherApplication` KVO-observable property; (B) Core Audio process tap with aggregate device; (C) AVCaptureSession-based audio capture. Each probe must satisfy four hard requirements: detects external recording, survives our own capture, **survives mid-session default-device change (AirPods scenario)**, observable from sandbox. 4–6h budget, gated on first success. Spike #13's outcome defines whether M3.7 closes with correct UX (any probe passes) or ships with documented v1 limitation (all three fail).

### Architectural decisions locked

1. **Product UX is the contract; engineering creativity does not substitute for it.** When Apple framework APIs make the natural implementation hard, the engineering response is to investigate more probes before pivoting to a different signal. M3.7's path should have been: HAL listener fails → polling fails → investigate `AVCaptureDevice.isInUseByAnotherApplication`, Core Audio process tap, AVCaptureSession → if all fail, THEN reframe with product. Architect short-circuited this and pivoted to inactivity-timer prematurely. **Lock: when product UX is unambiguous and the engineering path is hard, the response is "more probes," not "different product."**

2. **M3.7.2 inactivity-timer is preserved as defense-in-depth fallback, not removed.** Even after Spike #13 succeeds, the inactivity-timer code stays — gated to fire only if the chosen external-mic-detection signal fails to deactivate the session within a reasonable bound (e.g., 5 minutes of no signal change). Belt-and-suspenders pattern. **Lock: when v1 has multiple potential deactivation triggers, all of them are wired with priority ordering — primary signal first, secondary signal as fallback.**

3. **The fourth Apple-framework runtime-discovery finding establishes the empirical-validation culture as project-level pattern.** All four findings now share a generalized lesson: **for any Apple HAL/Speech-framework property, validate every step empirically before relying on it in production logic. Direct-read reliability is not equivalent to listener reliability is not equivalent to documented semantics.** Going forward: any module touching unfamiliar HAL or Speech APIs gets a probe-spike that validates property reads, listener registrations, AND listener callback delivery before the production module commits. Spike #13 is the first formalization of this pattern.

4. **Mid-session default-device change (AirPods scenario) is a hard requirement on any deactivation signal.** User starts call on built-in mic, mid-call connects AirPods, default input device changes. The session must NOT end as a side effect of this. M2.1's pattern of re-attaching observers to the new default device (`kAudioHardwarePropertyDefaultInputDevice` listener) is the architectural shape any chosen Spike #13 probe must match. **Lock: any deactivation signal that doesn't survive default-device changes fails the spike.**

5. **Original M2.1 `kAudioDevicePropertyDeviceIsRunningSomewhere` listener stays untouched.** Composition bug was never in the listener — it was in adding ourselves as a reader without rethinking the deactivation contract. If Spike #13's Probe B or C succeeds (capture mechanism that doesn't trip IsRunningSomewhere), the M2.1 listener works as originally designed. **Lock: M2.1's HAL listener is preserved; any signal change happens in the capture-mechanism layer or in a new observer alongside the existing one.**

### Procedural lessons

1. **Architect can rush to engineering elegance and miss the product call. This session is the canonical example.** The mitigation pattern: when about to tag a milestone as complete, restate the product UX one more time and verify the implementation matches. Architect should have asked "does an hour-long call with 10 min of speaking work correctly?" BEFORE drafting the M3.7.2 prompt. **Going forward: the product-UX-fits-implementation check is a required architect-side audit before approving Phase 2 of any module that touches user-visible session semantics.**

2. **Sub-agent design-review at architect-side caught three real corrections to the M3.7.2 Phase 1 plan** (cancel-at-top semantics, lastScheduledTimeout assertion, arm-at-top of runSession). The corrections were good engineering. But they were corrections to the WRONG SOLUTION — the implementation was clean for what it built; what it built was wrong. **Lesson: sub-agent design review catches implementation defects but cannot catch product-fit defects. Product-fit is the architect's responsibility and cannot be delegated.**

3. **The four-finding Apple-framework runtime-trap inventory is now a project-level pattern with Spike #13 as the first formalized application.** Future modules touching HAL/Speech APIs will gate themselves behind a probe-spike that validates every property/listener step. Cost of NOT doing this: M3.7 → M3.7.1 → M3.7.2 → reopened cycle, ~10h+ vs straight-line probe-first.

4. **Reply-formatting convention (Session 027 locked) held throughout this session.** Zero copy-paste regression. Same for smoke-gate-evidence convention (Session 026): every smoke verification produced structured log evidence with measured timings.

5. **"0 issues found" without verbatim notes is not credible (Session 020 lesson) held: nine-in-a-row sub-agent reviews with substantive findings.**

### Time

Session 028 wall-clock: ~3h (diagnostic + Chief of Product call + M3.7.2 prompt drafting + agent Phase 1+2+3 + smoke gate + product-UX correction at close). M3.7 total across Sessions 026 + 027 + 028: ~8–10h estimated against M3.7's nominal 3h budget = **~2.7–3.3x estimate** with M3.7 STILL OPEN pending Spike #13. Driver: four Apple-framework runtime-discovery findings, plus one architect-side product-fit miss. Estimate guidance: **modules with user-visible session semantics get a mandatory product-fit audit before Phase 2; modules touching unfamiliar HAL/Speech APIs get a probe-spike gate before any production code.**

---

## Session 027 — 2026-05-11 — M3.7 smoke surfaced MicMonitor/AudioPipeline composition bug; three HAL probes empirically established `kAudioProcessPropertyIsRunningInput` listener never fires; M3.7.1 polling architecture designed; reply-formatting + terminal-commands conventions locked

### What happened

M3.7 wiring landed code-complete in Session 026 (token-stream pipeline functional, first speech tokens emitted). Smoke gate in Session 027 surfaced a load-bearing composition bug: after `AudioPipeline.start()` runs in `runSession()` step 1, TalkCoach becomes a HAL reader of the default input device. `kAudioDevicePropertyDeviceIsRunningSomewhere` stays `true` while ANY process holds the device — including us — so MicMonitor's `IsRunningSomewhere=false` notification (M2.1's deactivation signal) never fires when external apps release the mic.

Architect's first response was detection-by-listening on a different HAL surface. Three probes ran empirically:

**Probe 1: `kAudioHardwarePropertyProcessObjectList` listener** — DOES fire. Confirmed callback when QuickTime joined process list at recording start and again when it left at quit.

**Probe 2: `kAudioProcessPropertyIsRunningInput` listener on external process objects** — registers successfully (`addStatus = 0`) but callback NEVER fires. Verified across three external apps over multiple cycles. **Third Apple-framework runtime-discovery finding.**

**Probe 3: same listener on our OWN process object** — same behavior. Listener registration mechanism is functionally inert for this property regardless of subject process.

M3.7.1 polling architecture designed as the listener-can't-work fallback: re-enumerate process objects every 1s, direct-read `IsRunningInput` per non-self process, maintain `externalMicState` state machine. Six new Convention-6 protocol methods. Landed in `2486dde` (red), green commit, `cc0855b` (sub-agent-caught teardown-race fix). 277 tests green at session close.

**Two collaboration conventions locked at session close:**

1. **Agent reply formatting** (locked in `00_COLLABORATION_INSTRUCTIONS.md` + project-root `CLAUDE.md`): pick ONE — pure prose with indented blocks, OR single fenced code block. Never mixed. Xcode chat panel can't select across fenced-block boundaries.

2. **Architect terminal commands**: every command prefixed `cd /Users/antonglance/coding/TalkCoach &&` with absolute paths, zero placeholders, one-action copy-paste.

Session ended in mid-M3.7.1 with code committed but smoke-gate-blocked, expecting Session 028 to be smoke verification of polling. Session 028 instead revealed polling itself was insufficient (fourth finding), triggering the M3.7.2 architectural pivot (which itself proved a product-fit miss — see Session 028).

### Architectural decisions locked

1. **The MicMonitor/AudioPipeline composition bug is project-level documented.** Any module that adds a new observable resource (HAL reader, NotificationCenter publisher, KVO observer) must trace how its presence affects every downstream observer.

2. **Three HAL probes are canonical artifacts.** Preserved in `Spike/HALProcessProbe/`. Future modules can reuse the probe shapes.

3. **Reply-formatting convention is repo-locked in two files** (`00_COLLABORATION_INSTRUCTIONS.md` + `CLAUDE.md`). Duplication intentional — different audiences, low cost vs missed convention.

4. **Architect-terminal-commands convention is repo-locked.** Zero ambiguity in command runs across the rest of the marathon.

### Procedural lessons

1. **First-ever runtime smoke surfaced an architectural bug, not an implementation bug.** Previous smoke fixes (M2.6 mouseDown, M2.6 NSScreen.main, M3.4 false-positive) were implementation-level. M3.7 was the first instance of architectural redesign needed at smoke time.

2. **"Apple framework looks right in headers, runtime behavior gaps" pattern is project-level expectation.** Finding 3 was the second in M3.7's path (Finding 2 was Session 026's `assetInstallationRequest` trap).

3. **Reply-formatting convention pre-empts marathon-session pain.** Zero copy-paste regression in Sessions 028+ after convention lock.

### Time

Session 027 wall-clock: ~3–4h. M3.7 smoke gate setup + bug investigation + 3 HAL probes + M3.7.1 prompt + agent Phase 1+2+3 + convention writeup. Driver of overage: HAL probe investigation (~2h) unbudgeted in M3.7's original 3h estimate.

---

## Session 026 — 2026-05-10 — M3.7 wiring landed; FIRST SPEECH TOKENS EMITTED in project history; smoke-gate-evidence convention locked; second Apple-Speech API trap caught (`assetInstallationRequest` non-nil for fully-installed models)

### What happened

M3.7 prompt drafted with inherited 8-smoke-scenario scope from M3.1 + M3.4 deferred gates. Three baked architect-side calls: (1) wiring as ordered async sequence in `runSession()` (not concurrent); (2) teardown single-point at `endCurrentSession()` with stop-in-reverse order; (3) per-step timing instrumentation via `Logger.session` with measured ms durations.

Agent landed M3.7 across three commits: `85ffba9` initial wiring, `d9d9683` measurement log lines (driven by this session's emerging smoke-gate-evidence convention), `fb6d98f` SessionWiring construction at `TalkCoachApp.swift:73`. 268 tests green. Smoke gate started immediately, blocked on a real Apple-framework trap.

**The trap:** `AssetInventory.assetInstallationRequest(supporting:)` returned non-nil for the en-US SpeechAnalyzer model even when fully installed. M3.7's wiring interpreted non-nil as "download required" and blocked. Sessions wouldn't start.

Architect ran empirical bypass test: skip the `assetInstallationRequest` check, directly call `SpeechAnalyzer.start(...)` against en-US. Result: succeeded immediately. Model WAS installed; API was lying. **Finding 2 in the project's Apple-framework runtime-trap inventory.**

Architect first proposed Mirror-reflection fix. Agent correctly rejected as architecturally wrong (Mirror reflection fragile against framework updates) and proposed alternative: check `SpeechTranscriber.installedLocales` directly and skip `assetInstallationRequest` path entirely. Architect agreed; commit `9460359` landed `SystemAssetInventoryStatusProvider` with clean `isInstalled(locale:) -> Bool`. Smoke unblocked.

**First-ever speech token from green pipeline:** `token '.' t=[0.00–15.49] final=false` — synthetic silence-detection token, but the entire pipeline path worked end-to-end. Project-level milestone.

**Smoke-gate-evidence convention locked** in `00_COLLABORATION_INSTRUCTIONS.md`: structured artifacts only — Console logs with timestamps and measured values, production-code measured Logger lines (durations in ms, counts, rates), XCTest output, `defaults` diffs, screenshots when UI rendering is the gate. Unacceptable: adjectives without measurement. Trigger: prior smoke evidence ("the animation was smooth") couldn't be re-derived weeks later for related bug investigation.

### Architectural decisions locked

1. **`SystemAssetInventoryStatusProvider` uses `SpeechTranscriber.installedLocales` (LIST), not `assetInstallationRequest` (HELPER).** Finding 2's resolution. Pattern: query the system's installed-locales set directly; `assetInstallationRequest` is for INITIATING downloads, not QUERYING installation status.

2. **No Mirror-based reads of Apple framework internals in production code.** Fragile under framework updates; introduces silent failure modes.

3. **Smoke-gate-evidence convention enforced via paste-back review.** Every smoke evidence is audited against the convention.

4. **First-token milestone logged as project-level event.** Before this session: nothing. After: a pipeline.

### Procedural lessons

1. **Agent rejecting wrong architect proposal (Mirror reflection) and proposing right alternative is healthy.** Treated as feature, not friction.

2. **Empirical diagnostic test BEFORE accepting an API's reported state.** Bypass test surfaced truth in <5 min.

3. **Pure-documentation conventions can carry significant project-level value.** Smoke-gate-evidence convention has no code change but reshapes what counts as evidence.

### Time

Session 026 wall-clock: ~3h. On-estimate for M3.7 slice in this session.

---

## Session 025 — 2026-05-09 — M3.5 + M3.5a shipped code-complete; five Convention-6 seams; AC7 finding (`SpeechTranscriber.supportedLocales` LIST not `supportedLocale(equivalentTo:)` HELPER); agent caught over-broad catch

### What happened

M3.5 (TranscriptionEngine routing) + M3.5a (AppleTranscriberBackend) shipped together as ~4h cycle. M3.5b (Parakeet) and M3.6 (download flow) explicitly deferred to post-M3.7-WPM-milestone per EN-first sprint locked in Session 024.

**Five Convention-6 protocol seams** instantiated in one session — highest count in project history:

1. `AudioBufferProvider` (reused from M3.4)
2. `AppleBackendFactory` (new)
3. `ParakeetBackendFactory` (new, stub returning unsupported since M3.5b deferred)
4. `SupportedLocalesProvider` (new)
5. `AssetInventoryStatusProvider` (new — production form revisited in Session 026's assetInstallationRequest trap)

**AC7 load-bearing finding:** prompt told agent to use `SpeechTranscriber.supportedLocale(equivalentTo:)` HELPER. Agent's research surfaced misleading return values (passing en_US returned ru_RU on test machine). Correct API: `supportedLocales` LIST. **Finding 1 in the project's Apple-framework runtime-trap inventory.**

Agent caught architect's over-broad catch clause via sub-agent review. `catch is WhisperLIDProviderError` would swallow `.inferenceFailed` along with `.modelUnavailable`; per AC6 wording only `.modelUnavailable` should fall through to declaredLocales[0]. Agent narrowed to `catch WhisperLIDProviderError.modelUnavailable`.

250 tests + 1 skipped (M3.6-dependent) green. PowerSpike's `LiveTranscriptionRunner.swift:99-104` referenced as canonical for live-streaming SpeechAnalyzer API; transferred clean.

### Architectural decisions locked

1. **Five-Convention-6-seam pattern scales within a single module.** Don't collapse seams unless two share single semantic responsibility.

2. **`SpeechTranscriber.supportedLocales` (LIST) is canonical, NOT `supportedLocale(equivalentTo:)` (HELPER).** Finding 1's resolution.

3. **Defensive catch narrowed to specific cases, not error-protocol types.** `catch SomeError.specificCase`, not `catch is SomeErrorProtocol`.

4. **EN-first sprint reaffirmed: M3.5b + M3.6 deferred until after M4.1 WPM milestone.**

### Procedural lessons

1. **Spike artifacts are canonical for Apple API patterns; prompts are advisory.** Confirmed pattern from Session 024.

2. **Sub-agent review catching over-broad error handling is recurring real-finding category.** Eight-in-a-row substantive sub-agent reviews including this one.

### Time

Session 025 wall-clock: ~3–4h. Estimated 8h combined. **Ran 0.5x estimate** — spike-pre-validated.

---

## Session 024 — 2026-05-08 — M3.4 LanguageDetector shipped code-complete: spike-pre-validated three-strategy dispatch transferred clean, sub-agent caught real over-broad catch, prompt's wrong API name corrected by agent, subsystem convention pinned

**Format:** Second module of Phase 3, immediately after M3.1. Clean inheritance from Spike #2 (Session 010's three-strategy validation). Same-day continuation of Session 023 (M3.1) — user pushed M3.1 then went straight into M3.4 without a session break, so what reads as Session 024 in the journal is wall-clock continuous with 023. Estimate guidance × 0.5–0.8 against 4–6h canonical = ~2.5–4h adjusted band. Actual landed near low end.

### What happened

User confirmed M3.4 as next module right after M3.1 push. Architect drafted M3.4 prompt with three baked architect-side calls (best-guess = `declaredLocales[0]` not last-used; all three strategies in single M3.4 not split; unvalidated pairs route by inference with `Logger.lang.notice`), all three marker blocks (16-item Phase 3 checklist, 12 ACs, 5 SG scenarios all PENDING M3.7 per the AC11 deferral pattern Session 023 locked).

Convention-6 protocol seam pattern from M3.1 carried into M3.4 for THREE external dependencies — not one. M3.4 ships before its production inputs (TranscriptionEngine partial-transcript stream M3.5; Whisper-tiny model download M3.6) and before its production output consumer (SessionCoordinator wiring M3.7). All external dependencies were specified as protocols with production stubs that graceful-degrade, mocked in tests, mirroring the `AudioEngineProvider` / `SystemAudioEngineProvider` / `FakeAudioEngineProvider` triplet from M3.1.

User pasted the prompt into a fresh agent session in plan mode. **The plan-audit step happened this time** — Session 023's lesson on user-side workflow discipline held. (Note: in this delivery cycle the Phase 1 plan and approval round happened in-session but the architect-side audit step wasn't surfaced through the conversation transcript; from the implementation evidence and clean disposition, the plan was substantively right and chose the right Foundation API for ScriptCategory mapping.)

Agent shipped Phase 2 across three commits: `dc0475b` red phase (49 tests), `a9179f6` green phase (full implementation), `26ed849` sub-agent review fix. 228/228 green (179 prior + 49 new), zero regressions, TDD lock preserved (`git diff dc0475b..26ed849 -- Tests/` empty for all committed test files).

The first Phase 3 self-review repeated the marker-block drift pattern from M3.1's first self-review — both `=== PHASE3_CHECKLIST ===` and `=== ACCEPTANCE_CRITERIA ===` items renumbered/replaced with impl-artifact summaries rather than reproduced verbatim. **Second drift in two sessions under the marker-block template; the pattern is clearly recurring, not a one-off.** Architect issued the same corrective shape as M3.1 Session 023: paste-back to agent with explicit verbatim-reproduction instruction, the 16-item Phase 3 checklist enumerated explicitly to remove ambiguity, and a per-AC drift map ("your AC1 ≈ my AC8 ScriptCategory; your AC5 ≈ my AC3 SameScript; your AC9+10 = my AC7 Convention-6; my AC1/AC10/AC12 silently dropped"). Agent's second pass came back clean: all 16 Phase 3 items dispositioned with file:line evidence, all 12 ACs in the prompt's order with concrete test names + git diff outputs.

Three real architect-relevant findings surfaced from the audit cycle:

**Finding 1: prompt-drift on Apple API names is a real risk; agent's spike-cross-check discipline caught it.** My M3.4 prompt told the agent Strategy 1 should use `NLLanguageRecognizer`'s `languageHints` (soft weighted-prior dictionary). Agent ignored the prompt and used `languageConstraints` (hard restriction array) — that's the right API for binary classification, and it's what the Spike #2 harness had validated (`LangDetectSpike/Sources/LangDetectSpikeLib/NLDetection.swift:62`). Agent's discipline of cross-checking against the spike artifact rather than blindly following the prompt's API-name string caught the architect's error. **Worth pinning as a procedural lesson: when the prompt and the spike artifact disagree on an Apple API name, the spike artifact is canonical.** The prompt is architect-authored at desk-time; the spike artifact compiled and ran against the real OS API.

**Finding 2: subsystem convention is `com.talkcoach.app` with per-category names, NOT `com.locto.<area>` as the M3.1 prompt instructed.** `grep -r 'com.locto' .` returns zero matches across the repo. All `Logger` categories share the single subsystem `com.talkcoach.app` with per-category names (`audio`, `lang`, `mic`, `session`, `widget`, `floatingPanel`, `analyzer`, `speech`, `app`, `settings` — 10 categories total). M3.1's prompt told the agent to use `com.locto.audio`; the agent silently corrected during M3.1 to align with the existing `Logger+Subsystem.swift:4` convention. M3.4 followed the same correction. **The architect's mental model of the subsystem convention has been wrong from M3.1 onward.** Future prompts use `com.talkcoach.app` / category `<area>`, not `com.locto.<area>`. No code change needed (the convention is consistent and locked); architect-side prompt-template fix only.

**Finding 3: first false-positive sub-agent finding in project history.** Sub-agent flagged `LanguageDetectionStrategy.swift`'s use of direct `Logger(subsystem:category:)` construction vs accessing `Logger.lang` as a "logger consistency issue." Agent correctly identified this as false positive: `Logger.lang` is `MainActor`-isolated (per the existing `Logger+Subsystem.swift` extension pattern) and can NOT be accessed from a nonisolated top-level `let` in a struct that needs to run off main actor. The strategy types are nonisolated structs by design (so they can run on the `LanguageDetector` actor's serial executor and not bounce to main); accessing `Logger.lang` directly would require a `MainActor.assumeIsolated` or worse. **The strategy types' direct-construction is correct.** Sub-agent reviews continue to be substantive — six-in-a-row including this run's real finding on the over-broad catch — but this is the first instance where a sub-agent finding required architect judgment to dismiss rather than implement. Pattern: sub-agent findings need architect-level judgment, not blanket apply.

**Sub-agent's real finding** that DID get fixed (commit `26ed849`): `WhisperLIDStrategy`'s catch clause was originally over-broad (`catch is WhisperLIDProviderError` would have swallowed `.inferenceFailed` and any future error case under the modelUnavailable graceful-degrade path). Agent narrowed to `catch WhisperLIDProviderError.modelUnavailable` per the AC6 wording. `.inferenceFailed` now propagates as a thrown error (correct — that's a real bug, not a graceful-degrade case).

**`.bufferingNewest(1)` for `localeChange`** confirmed intentional. Preserves at-most-one swap event for late-attaching consumers. Strategy 1 / 2 yield once + finish; Strategy 3 / N=1 finish without yielding. Either 0 or 1 locale delivered, never lost to consumer-attach race. Plays well with M3.7's expected wiring (SessionCoordinator attaches `for await` shortly after calling `start()` — buffer covers the window between).

**M3.4 closes code-complete (`m3.4-code-complete`).** AC1–AC11 fully MET; AC12 PENDING M3.7 wiring. SG1–SG5 deferred to M3.7's smoke gate. M3.7 now inherits SG1/SG2/SG3 from M3.1 + SG1–SG5 from M3.4 = 8 smoke scenarios at wiring time. M3.7's adjusted estimate should include the inherited smoke scope.

### Architectural decisions locked

1. **Three Convention-6 protocols mirror M3.1's pattern across multiple seams.** `PartialTranscriptProvider`, `WhisperLIDProvider`, `AudioBufferProvider` — each with protocol + production stub + test fake. M3.4 demonstrates the pattern scales to N=3 seams in one module. Strategy types are nonisolated structs (Sendable); providers are nonisolated `Sendable` protocols. The shape diverges from M3.1's `AnyObject` + `final class` because M3.4's strategies don't need reference semantics — they're stateless dispatchers operating on injected providers. **Lock: when the providee is stateless, use `nonisolated protocol P: Sendable` + struct providers; when the providee wraps stateful OS-API state (like `AVAudioEngine`), use `protocol P: AnyObject` + `final class`. M3.1's pattern and M3.4's pattern are both correct in their respective contexts.**

2. **Strategy dispatch is one-time at `init()`, not runtime-mutable.** `LanguageDetector.init()` selects exactly one of `SingleLocaleStrategy` / `SameScriptStrategy` / `WordCountStrategy` / `WhisperLIDStrategy` based on `dominantScript` of the two declared locales. The chosen strategy is stored as `any LanguageDetectionStrategy` and used for the session's lifetime. **Lock: re-detection mid-session would require a new `LanguageDetector` instance (or an explicit reset API). Mid-session re-detection is M3.8's territory if scope permits, deferred otherwise.**

3. **`isBlocking: Bool` on the strategy protocol distinguishes the two output models.** Non-blocking strategies (SingleLocale, SameScript, WordCount) return `declaredLocales[0]` immediately from `start()` and run detection in a background `Task`, yielding any swap to `localeChange`. Blocking strategy (WhisperLID) awaits detection inside `start()` and returns the committed locale directly; `localeChange` finishes immediately. **Lock: this two-output-model design is the cleanest API surface for the heterogeneous strategies. The `isBlocking` Boolean on the strategy protocol is the right factoring.**

4. **`languageConstraints` is the right `NLLanguageRecognizer` API for binary classification, not `languageHints`.** Validated in Spike #2 harness; followed by M3.4 implementation; correction recorded against architect's prompt error. **Lock: future prompts referencing `NLLanguageRecognizer` use `languageConstraints`. Sub-agent reviews and architect-side audits cross-check spike artifacts when API names appear in prompts.**

5. **Subsystem convention is `com.talkcoach.app` with per-category names.** Locked since project setup (`Logger+Subsystem.swift:4`). 10 categories: app, audio, speech, analyzer, widget, session, mic, floatingPanel, lang, settings. **Lock: future prompts use this convention; architect's mental model corrected.** No code change needed.

6. **`.bufferingNewest(1)` for at-most-one-emission `AsyncStream`.** Preserves the single yield for late-attaching consumers. Different from `AudioPipeline.bufferStream`'s `.bufferingNewest(64)` (continuous flow, drop-oldest under backpressure). **Lock: pick the buffer policy by the stream's emission pattern, not by uniform default.**

### Procedural lessons

1. **Marker-block drift is the new default expectation, not the exception.** Sessions 021 + 022 ran clean; Session 023 (M3.1) drifted on first self-review and required corrective; Session 024 (M3.4) drifted on first self-review and required corrective. **Two consecutive sessions with the same drift pattern.** The marker-block mechanism still works — it surfaces drift cleanly when the architect catches it — but the mechanism does not self-enforce. Going forward: assume drift will happen on the first self-review of every high-risk module; budget +25 min for the corrective re-disposition cycle in the estimate. The "watch for marker-block drift" item is now a default audit step, not an exception.

2. **Prompt drift on Apple API names is a real risk.** Architect-authored prompts at desk-time can introduce wrong API names (`languageHints` instead of `languageConstraints`). The agent's defense is cross-checking against spike artifacts; the architect's defense is auditing the plan before approving Phase 2. **Mitigation: when a prompt references an Apple API by name AND a spike artifact exists with that API used, the prompt should explicitly say "spike artifact is canonical for the API name." Future prompts add this clause.**

3. **Sub-agent findings need architect-level judgment, not blanket apply.** First false-positive in project history (the `Logger.lang` direct-access suggestion). Pattern: when a sub-agent finding contradicts an established architectural decision (here: nonisolated strategy types), the architect's judgment overrides. The agent's choice to dismiss the false positive in this case was correct; for higher-stakes contradictions, the agent should pause for architect review before either fixing or dismissing.

4. **Architect's mental model of the subsystem convention was wrong from M3.1 onward.** Two sessions of prompts have told the agent to use `com.locto.<area>` while the agent silently corrected to the actual `com.talkcoach.app` convention. No production-code damage (agent always corrected), but architect-side prompt-template error needs fixing. **Mitigation: future prompts grep the existing logger convention before specifying subsystem strings.**

5. **Spike-pre-validated module with deferred smoke ran on the fast end of guidance again.** M3.1 ran 0.75–1.0x against canonical with deferred AC11; M3.4 ran 0.5–0.7x against canonical with deferred AC12. The pattern is consistent: when the spike validates the mechanism AND smoke deferral shifts smoke-gate fix-round risk to the wiring module, the actual lands at or below canonical. **Lock the guidance: spike-pre-validated module with smoke deferred to wiring → estimate × 0.5–0.8 (was × 0.5–0.8 going in; matches actuals exactly).**

6. **Session 024 ran wall-clock continuous with Session 023.** User pushed M3.1 and immediately requested M3.4 without a break. The journal entries are split for clarity (different modules, different sessions of work) but the wall-clock budget compounds. ~3.5–4h Session 023 + ~2.5–3.5h Session 024 = ~6–7.5h continuous architect-active work. Worth flagging for fatigue tracking — the architect-side error rate (the `languageHints` mistake; the `com.locto.audio` subsystem-string error from M3.1 that the agent silently corrected) might correlate with continuous-session length. v1.x: track architect error rate against session position within continuous-work blocks.

### Time accounting

- Session start: 2026-05-08 ~17:30 -05:00 (immediately after M3.1 push at session 023 close)
- Session end: 2026-05-08 20:46 -05:00 / 02:46 UTC May 9
- Wall-clock total: ~3.5h elapsed, ~2.5–3h architect+user active (architect-side: M3.4 prompt write + Phase 1 implicit audit + Phase 3 first-pass marker-block drift diagnosis + corrective prompt + second-pass audit + close-out; agent-side: ~2h impl work landed asynchronously within session span)
- Per-phase breakdown:
  - M3.4 prompt write: ~30 min
  - Phase 1 plan production (agent, asynchronous): not on architect clock
  - Phase 2 implementation (agent, asynchronous): not on architect clock
  - Phase 3 self-review marker-block drift diagnosis + corrective prompt: ~25 min
  - Sub-agent review audit (incl. false-positive judgment): ~15 min
  - Close-out doc writes: ~30 min
- Estimate: 4–6h canonical (× 0.5–0.8 spike-pre-validated guidance = 2.5–4h adjusted). Actual active: ~2.5–3h. **Variance: 0.5–0.7x against canonical, on the fast end of the adjusted band.** Spike-pre-validated + deferred-smoke pattern continues to amortize. One marker-block correction round (~25 min) plus one false-positive sub-agent judgment (~15 min) did not push the actual past the adjusted band's low end.
- See `08_TIME_LEDGER.md` for cumulative pace data.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry, including `Time accounting` block
- `04_BACKLOG.md` — M3.4 row updated to `✅ code-complete tag m3.4-code-complete (Session 024, ~2.5–3h actual); SG1–SG5 deferred to M3.7 wiring`; M3.7 row annotated to inherit SG1–SG5 from M3.4 in addition to SG1/SG2/SG3 from M3.1
- `08_TIME_LEDGER.md` — Session 024 row added to per-session table; M3.4 row added to per-module table; pace observations refreshed; project totals updated to end-of-Session-024

### Next session

**Suggested: M3.5b `ParakeetTranscriberBackend`.** Largest module of Phase 3 (8–12h estimate). Depends on Spike #10 (passed Sessions 006–007, three sub-spikes validating Parakeet via WhisperKit harness, model sizing, and accuracy parity). Highest ML/Core ML surface in v1; biggest potential for OS-API surprise. Likely splits across two sessions.

**Alternative: M3.5 `TranscriptionEngine` skeleton + `AppleTranscriberBackend`.** Estimate 6–8h canonical. The Apple Speech framework backend is more locked-down than Parakeet (less API surprise). Could be a rest day for the architect after the M3.1+M3.4 continuous run — Apple's `SpeechAnalyzer` API surface was validated in Spike #1.

**Architect-side flags for the next session's opening message** (whichever module is picked):

For M3.5b:
1. **WhisperKit dependency may need to land here.** M3.4 deferred WhisperKit to M3.6 / M3.5b. M3.5b is the production transcription path — needs the WhisperKit dependency added if Parakeet ships via that integration path. Plan must specify whether Parakeet is via WhisperKit's `transcribe(audioPath:options:)` with a Parakeet-quantized model, or a direct Core ML inference path. Spike #10 validated WhisperKit-with-Parakeet; default to that.
2. **Model download / on-disk gate is M3.6's territory.** M3.5b ships with a graceful-degrade path same as M3.4's `WhisperLIDStrategy.modelUnavailable` pattern. Until M3.6 lands, `ParakeetTranscriberBackend.transcribe(...)` throws `.modelUnavailable` (or the equivalent). Pattern is locked.
3. **Backend selection logic stays in M3.5 (the engine), not M3.5b.** M3.5b is the Parakeet *backend*; M3.5 is the engine that holds locale → backend routing. Don't fold them together. Plan must justify the split if it deviates.
4. **High-risk module: sub-agent review required, plan mode for Phase 1.** ML/Core ML surface + multi-locale routing. Likely splits across two sessions.
5. **Smoke gate likely defers to M3.7 again.** Same pattern.

For M3.5 + AppleTranscriberBackend:
1. **`SpeechAnalyzer` was validated in Spike #1** (Sessions 002–003); locale support, partial-result emission, on-device modes. Plan should quote the spike's validated outcomes.
2. **`TranscriptionEngine` is the routing brain** between locale and backend. Apple's `SpeechAnalyzer` for the locales it supports; Parakeet via M3.5b for the rest. Locale → backend routing locked at construction time (same shape as M3.4's strategy dispatch).
3. **Smoke gate may NOT defer here.** Apple's `SpeechAnalyzer` runs end-to-end without external dependencies (no model download). Once `AudioPipeline.bufferStream` (M3.1) feeds `TranscriptionEngine`, the system has its first runtime path that exercises real OS APIs. M3.5 might be the right place to land M3.7's wiring partially — exercise an end-to-end audio → transcription smoke without waiting for full token wiring. Architect should think about this before drafting the prompt.

**Reading order at next session start:** standard reading order from `00_COLLABORATION_INSTRUCTIONS.md` + the architect-side flags above + Spike #1 (for M3.5/AppleBackend) or Spike #10 (for M3.5b) validated outcomes. M3.7 (token wiring) inherits AC11 from M3.1 + SG1–SG5 from M3.4 + whatever new smoke deferrals the next module adds.

---

## Session 023 — 2026-05-08 — M3.1 AudioPipeline shipped code-complete: canonical strict-concurrency pattern transferred clean from spike, sub-agent caught real defensive-guard finding, AC11 smoke gate deferred to M3.7

**Format:** First module of Phase 3. Clean inheritance from Spike #4 Phase 2 (Session 022's locked canonical pattern). Three architect-side flags carried into the prompt — recovery measurement on every event including #1, frame-size dynamism, sub-agent-required + plan mode for high-risk module. Marker-block drift regressed on the first self-review (third session under the new template; first regression after Sessions 021–022 ran clean); corrected via direct verbatim-reproduction prompt with per-AC drift map; second pass clean.

### What happened

Session opened with three architect-side items from Session 022's M3.1 prep brief:

1. Copy `AudioTapBridge.swift`'s production form directly — the explicit `nonisolated` keyword on the factory function being load-bearing under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
2. Plan must specify recovery latency on event #1 (closing the Spike #4 Phase 2 S4 gap), dynamic frame size (not hardcoded 4096), both Chrome Meet and input-device switch as smoke trigger sources, defensive VPIO re-disable in recovery.
3. High-risk module discipline: sub-agent review required, plan mode for Phase 1.

The M3.1 prompt was written in-session with three marker blocks (Phase 3 checklist with 14 items, Acceptance Criteria 1–12, smoke-gate scenarios SG1/SG2/SG3) per the standard template promoted in Session 022. Estimate guidance × 1.0–1.5 against the 4h canonical per Session 022's OS-API-spike-pre-validated band.

User followed the prompt-paste workflow (architect produces file → user copies into Xcode agent). **The plan-audit step was skipped** — user went prompt → agent → plan → "approve, proceed" → execution without surfacing the plan to the architect for audit. The architect-side instruction to audit the plan does not protect anything if the user's workflow skips it. First-of-phase and high-risk-module prompts going forward should include an explicit "DO NOT proceed past Phase 1 — paste plan to architect first" callout in the chat message accompanying the prompt file delivery, not just inside the prompt file.

Mid-execution the agent appeared to hang on "Run some test" for over an hour — Xcode's chat-panel checklist UI froze, but the agent process was actually working silently. User stopped the running scheme but not the agent; agent continued and completed the session cleanly with red commit `e9891f1`, green commit `16a7932`, 23 new tests + 178 prior = 201 tests... wait, agent reported "23/23 green, 178/178 full suite green." Reconciling: 178 full suite includes the 23 new ones; full suite was 155 before M3.1 + 23 added = 178.

**Lesson: Xcode UI freeze ≠ agent hang.** When the agent's checklist appears stuck for an hour, check git log + file system before assuming the agent is dead. Stopping the running scheme (which the user did) is harmless; killing the agent process (which the user did NOT do) would have lost ~2h of work. Two-strike rule applies in spirit: don't kill an agent until independent evidence (git, file system, console output) confirms it's stuck.

The agent's first self-review came back with substantively-correct AC dispositions on the items addressed, but the marker-block contract was broken: the `=== PHASE3_CHECKLIST ===` block's 14 items were entirely skipped, and `=== ACCEPTANCE_CRITERIA ===` items were renumbered/replaced with agent-invented ACs (Convention-6 protocol design as "AC1", error cleanup as "AC12"). The architect's AC2 (buffer flow within 500ms with non-empty PCM and monotonic `sampleTime` — FM2-critical) was silently dropped. AC3 was missing the spike-line + M3.1-line side-by-side quote that the prompt explicitly required. **First marker-block drift regression** after Sessions 021 (M2.7) and 022 (Spike #4 Phase 2) ran clean. Session 022's "marker block enforcement is now stable" claim was premature.

Architect corrective: paste-back to agent with explicit verbatim-reproduction instruction plus a per-AC drift map (your "AC4" content folds under real AC1; AC2 not dispositioned, this is FM2-critical; AC3 needs both spike line and M3.1 line quoted side-by-side; AC11 disposition is PENDING not omitted; etc.). Agent's invented "AC1" (protocol design) and "AC12" (error cleanup) demoted to "Additional findings beyond the prompt's ACs" rather than renumbered. Second pass clean: 14/14 Phase 3 checklist items dispositioned with file:line evidence, 12/12 ACs dispositioned with proper mapping. Sub-agent independent review followed with verbatim per-item findings.

Sub-agent surfaced one real production-code finding (#4): `recover()` had no guard against being called after `stop()`. Production path is closed (observer deregistered on `stop()`), but the `internal recover()` test surface could be invoked post-stop and the engine state machine would re-fire stop → removeTap → setVPIO → installTap → prepare → start with no defense. Architect dispositioned: fold in. Cost: 5 lines + one new test (`testRecoverAfterStopIsNoOp`) verifying callLog stays empty, `lastRecoveryDuration` stays nil, and `bufferStream` remains terminated.

Architect also called for a class-level `///` doc comment on `AudioPipeline` matching the pattern at `MicMonitor:4` and `SessionCoordinator:20`, re-dispositioning the doc-comment Phase 3 checklist item from NOT MET (self-review) and N/A (sub-agent — methods lack doc comments) to MET cleanly without committing the project to a broader "doc comments on all public APIs" convention.

Both tightenings were additive: no modification of red-phase committed tests (TDD lock preserved), one new test for the new behavior. 178 + 1 = 179 green. Tightening commit landed.

AC11 smoke gate question: M3.1 ships its public API surface (`start()` / `stop()` / `bufferStream`) but per the prompt's Out-of-Scope, M3.1 does NOT wire `AudioPipeline` to `SessionCoordinator`'s lifecycle (that's M3.7). Without that wiring, no runtime path in a built-and-running TalkCoach calls `start()` or consumes `bufferStream` — SG1/SG2/SG3 have nothing to observe in Console. SG3's "log buffer count every 10s" counter check is also not in production code (the agent correctly didn't add it; it wasn't tied to an AC, only described in SG3). Architect proposed two paths: (A) temporary `#if DEBUG` harness now (~30 lines in app entrypoint, removed when M3.7 lands), run smoke today, M3.1 closes fully; (B) defer smoke to M3.7 where the production wiring naturally enables observation, M3.1 closes code-complete with AC11 PENDING. **User chose B.**

**M3.1 closes code-complete (`m3.1-code-complete`).** AC1–AC10 + AC12 fully MET with concrete evidence (file:line, test names, log lines, callLog ordering, build-settings file/line); AC11 PENDING (deferred to M3.7); AC7 PARTIAL pending smoke (test verifies `lastRecoveryDuration` property proxy; production emits `Logger.audio.info` + `OSSignposter` interval at `AudioPipeline.swift:170-171`; smoke gate's per-switch log capture is the closing verification path).

### Architectural decisions locked

1. **Canonical pattern transferred clean from spike to production.** `AudioTapBridge.swift`'s production form (nonisolated factory, `AsyncStream` + `.bufferingNewest(64)`, `AVAudioEngineConfigurationChange` recovery cycle) copied to `AudioPipeline.swift` with no re-derivation. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` verified at `project.pbxproj:363/398`; the explicit `nonisolated` keyword is genuinely load-bearing in production. Spike #4 Phase 2's investment is fully amortized in M3.1 — the agent did not re-derive any of the locked decisions.

2. **`AudioEngineProvider` Convention-6 protocol added.** Test-injection seam mirroring `CoreAudioDeviceProvider` from M2.1. Production: `SystemAudioEngineProvider` (real `AVAudioEngine` wrapper). Tests: `FakeAudioEngineProvider` with `callLog` recording every method call in order. Convention-6 (`PermissionStatusProvider`-style) extends to audio. Not in the original prompt — agent's design call, accepted.

3. **`recover()` is `internal` for test access.** Tests call directly via `@testable import` rather than posting brittle real `AVAudioEngineConfigurationChange` notifications. Plan justified the choice; sub-agent finding #4 (post-stop guard) depended on this seam being exposed and was addressed by the additive `guard isStarted else { return }` at the top of `recover()`.

4. **`bufferSize: 0` for system-chosen frame size.** Satisfies AC8's no-hardcoded-4096 contract; production reads `AVAudioPCMBuffer.frameLength` at runtime per Spike #4 Phase 2's frame-size finding (~4792 on test hardware). The `0` value follows `AVAudioEngine.installTap(...bufferSize:format:)`'s "preferred-or-system-chooses" semantics.

5. **Recovery latency measured on every event including #1.** `lastRecoveryDuration` property (test-observable proxy) + `Logger.audio.info("Recovered in \(ms)ms")` + `OSSignposter` interval, all emitted unconditionally on every `recover()` invocation. Closes the Spike #4 Phase 2 S4 gap (latency was logged only on event #2 in the spike).

6. **AC11 smoke deferral pattern.** When a module ships its public API but is not yet wired into a runtime path that exercises it, smoke can defer to the wiring module. M3.7 inherits SG1 (input-device switch, gating), SG2 (Chrome Meet, exploratory), SG3 (Zoom 5-min coexistence, gating, FM4) plus the buffer-count-every-10s counter check from M3.1. The deferred-smoke ACs are tracked PENDING and closed in the wiring module's smoke gate. **First time the pattern is formalized; record for future reference.**

### Procedural lessons

1. **Marker-block drift is recurring; one clean session is not enough to declare it stable.** Sessions 021 + 022 ran clean, then Session 023 regressed on the first self-review (full Phase 3 checklist skipped, AC numbering replaced with agent inventions). The corrective per-instance prompt (verbatim-reproduce + per-AC drift map) restored discipline cleanly. Going forward: don't claim marker-block enforcement is stable until ≥5 sessions running clean. Treat drift as the default expectation, not the exception. The marker-block mechanism still works — but only when the architect catches the drift and corrects it; the mechanism doesn't self-enforce.

2. **The plan-audit step needs to actually happen, and the user has to do something to make it happen.** The M3.1 prompt's text said "DO NOT IMPLEMENT YET" and asked for a plan, but the user's natural workflow (paste prompt → wait for output → say "approve, proceed") doesn't surface the plan to the architect. **Mitigation:** future first-of-phase or high-risk-module prompts will include an explicit chat-message callout — *not just inside the prompt file* — saying "After Phase 1 plan is produced, paste it back to architect for audit before approving Phase 2." Belt-and-suspenders: the file says it, the chat message reminds it.

3. **Xcode UI freeze ≠ agent hang.** When the agent's checklist UI appears stuck for an hour, check git log + file system before assuming the agent is dead. The agent was working silently; UI was frozen. Stopping the running scheme (which the user did) is harmless; killing the agent process (which the user did NOT do) would have lost ~2h of work. Two-strike rule applies in spirit: don't kill an agent until independent evidence (git, file system, console output, file timestamps) confirms it's stuck.

4. **Sub-agent reviews continue to surface real findings — four-in-a-row.** Session 020's discipline (zero-issues-without-verbatim-notes is itself a signal) held. Sub-agent's finding #4 (recover-after-stop guard) was a real state-machine defensive gap, not noise. Sub-agent reviews across M2.5 / M2.6 / M2.7 / Spike #4 Phase 2 / M3.1 have all surfaced substantive findings — five-in-a-row when counted with M2.5's TokenStorage leak. The pattern is consistent: sub-agent reviews in this project pay back the time invested.

5. **Spike-validated patterns transfer near-zero-friction.** M3.1's biggest design questions were all answered by Spike #4 Phase 2: hand-off mechanism, backpressure policy, recovery cycle, factory-function concurrency form, sample-data copy-out timing. The agent's plan re-quoted spike outcomes correctly without re-deriving anything. Estimate ran near low end of guidance (× 0.75–1.0 against the 4h canonical), validating Session 022's "spike-pre-validated module" 0.5x adjustment guidance. Counter-pattern would have been: agent ignores spike, re-derives, picks different choices, bugs surface in smoke. None of that happened. The 1.5h of Spike #4 Phase 2 investment continues to amortize.

6. **AC11 smoke deferral is a real architectural pattern, not a procedural shortcut.** Modules that ship producer surfaces (`AudioPipeline.start()` / `bufferStream`) are not testable in isolation against runtime ACs that require consumer activity. Building a temp `#if DEBUG` harness is real cost (small, but real) for a redundancy that disappears in 1–2 modules. Deferring AC11 to M3.7 (the wiring module) is the right call when the wiring module is reasonably close on the schedule. Document the deferral; don't pretend it doesn't exist; M3.7's smoke gate explicitly inherits the M3.1 scenarios.

### Time accounting

- Session start: 2026-05-08 ~12:00 -05:00 (user worked through the silent-agent period before re-engaging architect at ~13:42 -05:00 / 18:42 UTC; architect first prompt write ~12:50 -05:00 / 17:50 UTC)
- Session end: 2026-05-08 17:21 -05:00 / 23:21 UTC — close-out doc writes
- Wall-clock total: ~5.5h elapsed, ~3.5–4h architect+user active (architect-side: prompt write + Phase 3 audit + first-pass marker-block drift diagnosis + corrective prompt + second-pass audit + sub-agent finding disposition + tightening prompt + AC11 path question + close-out; agent-side: ~3h of impl work landed asynchronously within session span, including the silent ~1h that appeared as a UI hang)
- Per-phase breakdown:
  - M3.1 prompt write: ~30 min
  - Phase 1 plan production (agent, asynchronous): not on architect clock
  - Phase 2 implementation (agent, asynchronous, including UI-frozen interval): not on architect clock
  - Phase 3 self-review marker-block drift diagnosis + corrective prompt: ~25 min
  - Sub-agent review audit: ~10 min
  - Two tightenings prompt: ~10 min
  - AC11 path decision + close-out doc writes: ~45 min
- Estimate: 4h canonical (× 1.0–1.5 = 4–6h adjusted per Session 022 guidance). Actual active: ~3.5–4h. **Variance: ~0.6–1.0x against canonical, on the fast end of the adjusted band.** The spike pre-validation paid off as guidance predicted; one round of marker-block correction + one round of additive tightening did not push the actual past the canonical estimate. AC11 smoke deferral means the smoke-gate fix-round risk that Session 022's guidance allocated for is shifted to M3.7's actual.
- See `08_TIME_LEDGER.md` for cumulative pace data.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry, including `Time accounting` block
- `04_BACKLOG.md` — M3.1 row updated to `✅ code-complete tag m3.1-code-complete (Session 023, ~3.5h actual); AC11 smoke gate deferred to M3.7 wiring`; M3.7 row annotated to inherit AC11 smoke scenarios SG1/SG2/SG3 from M3.1
- `08_TIME_LEDGER.md` — Session 023 row added to per-session table; M3.1 row added to per-module table; pace observations refreshed including AC11-deferral pattern note; project totals updated to end-of-Session-023

### Next session

**M3.4 `LanguageDetector` confirmed.** Estimate 4–6h canonical, × 0.5–0.8 spike-pre-validated guidance = ~2.5–4h adjusted. Single-session ship target.

Architect-side items to carry into next session's opening message (sequencing + scope flags surfaced here so they're available at session start without re-reading the spike):

1. **Three strategies dispatched at `init()` from `declaredLocales`'s Unicode script properties** (Architecture §5, locked Session 010). Strategy 1 (`NLLanguageRecognizer`) for same-script pairs; Strategy 2 (word-count threshold t=13) for cross-script non-CJK pairs; Strategy 3 (Whisper-tiny audio LID) for Latin↔CJK pairs. Strategy selection is one-time at construction, not runtime-mutable. Spec at Architecture §5 lines 187–217.

2. **N=1 trivial path is its own code path.** No detection runs; `LanguageDetector` returns `declaredLocales[0]` immediately. Tested separately. Spec at Architecture §5 lines 182–185.

3. **Input dependencies — M3.4 ships BEFORE M3.5 / M3.5a / M3.5b.** Strategies 1 & 2 consume partial-transcript text that doesn't exist yet (TranscriptionEngine is M3.5). Strategy 3 consumes raw audio buffers from `AudioPipeline.bufferStream` (M3.1, available). **M3.4 must define a protocol-input seam (Convention-6) for the partial-transcript source** that's mocked in tests and wired in M3.7. Without this, M3.4's Strategies 1 & 2 are unprovable until M3.5 lands. The seam is the architect-side equivalent of `AudioEngineProvider` from M3.1 — protocol + production stub (returns nothing until wired) + test fake.

4. **Whisper-tiny model dependency — M3.4 ships BEFORE M3.6 (download flow).** Strategy 3 needs `openai_whisper-tiny` (75.5 MB) on disk. Until M3.6 wires the download, Strategy 3 cannot run end-to-end. Two clean options for M3.4's prompt: (a) Strategy 3 ships as code with a "model not yet available" graceful-degrade path (logs + falls back to Strategy 2 word-count or to manual override) until M3.6 lands; (b) Strategy 3 ships fully but is gated behind a model-present check, with the bundled-test fixture used for unit tests. Recommend (a) — clean separation of concerns; M3.4 is detection logic, M3.6 is asset management.

5. **AC11 smoke deferral pattern likely applies again.** M3.4 emits a `Locale` to `SessionCoordinator` (per Architecture §5 line 242: "outputs a `Locale`... emitted as a locale-change event to `SessionCoordinator`"). `SessionCoordinator` does not yet consume the locale (that happens in M3.5/M3.7 wiring). No runtime path observes the detection output. Smoke gate likely defers to M3.7 (same pattern as M3.1's AC11). Plan should propose this explicitly.

6. **Cross-script non-CJK fallback for unvalidated pairs** (Architecture §5's untested cases per Spike #2's open follow-ups). EN+AR (Latin+Arabic), EN+HI (Latin+Devanagari), EN+KO/EN+ZH (CJK other than JA), EN+FR/EN+DE/EN+PT/EN+IT (untested same-script). Strategy selection routes them by script rules (CJK → Strategy 3, same-script → Strategy 1, else → Strategy 2). M3.4 ships supporting these; tests exercise the routing logic, not new corpora. Architect flag: when an unvalidated pair routes, log `Logger.lang.info` with pair + selected strategy to surface real-world coverage signals for v1.x corpus expansion.

7. **Strategy 3's lifecycle differs from 1 & 2.** Strategy 3 commits a locale BEFORE `TranscriptionEngine` initializes (widget stays hidden during the ~3s buffering). Strategies 1 & 2 emit a locale-CHANGE event AFTER ~5s if the wrong-guess swap fires. Two different output surfaces: an `init()` async method that returns initial locale (used by all strategies), and an optional `localeChange` `AsyncStream<Locale>` (used only by Strategies 1 & 2; Strategy 3 finishes the stream immediately at start since no swap is possible). Plan should justify the API shape.

8. **High-risk module discipline applies (sub-agent review required).** Three strategies × N=1/N=2 split × four output paths = real combinatorial surface. Plan mode for Phase 1.

**Reading order at next session start:** standard reading order from `00_COLLABORATION_INSTRUCTIONS.md` + Spike #2 validated outcomes (`05_SPIKES.md` lines 297–319) + LanguageDetector spec (`03_ARCHITECTURE.md` §5, lines 172–243). M3.5b (ParakeetTranscriberBackend, 8–12h) remains queued after M3.4. M3.7 (token wiring) remains gated by M3.1 + M3.5; will inherit AC11 smoke from M3.1 + likely from M3.4.

---

## Session 022 — 2026-05-08 — Spike #4 Phase 2 (strict-concurrency tap tightening) shipped: canonical pattern locked for M3.1; second session running with marker-block template and zero checklist drift; `00_COLLABORATION_INSTRUCTIONS.md` updated to make the template standard

**Format:** Architect-driven micro-spike between Phase 2 close (Session 021) and Phase 3 open (M3.1 next). Decision at session start: tighten Spike #4's Swift 6 strict-concurrency findings via a focused micro-spike before M3.1 vs roll into M3.1's plan. User chose tighten — *"I don't want to move forward if the base decisions are not fully validated and clearly documented."* That choice paid off: the spike surfaced a real Phase 1 → Phase 2 reproducibility gap (Chrome Meet didn't trigger config-change behavior reproducibly) plus a frame-size assumption that would have been wrong in M3.1.

### What happened

The session opened with two architect doc items carried over from Session 021's open-questions list. Item 1 (promote `=== MARKER ===` block template to `00_COLLABORATION_INSTRUCTIONS.md`'s standard prompt template) was a 5-minute doc edit: marker blocks added to Phase 3 self-review and Acceptance Criteria sections of the Standard Prompt Template, plus a new Always-do #10 explaining marker blocks as a generalizable mechanism for any list the agent must reproduce verbatim. Item 2 (Spike #4 micro-tighten vs straight M3.1 decision) was answered by the user: tighten.

The Spike #4 Phase 2 spec was added inline under the existing Spike #4 entry in `05_SPIKES.md` (preserves the Phase 1 outcomes from Session 008, adds the Phase 2 question + method + pass criteria). The agent prompt (`spike4_phase2_tap_tightening.md`) covered: harness layout mirroring `MicCoexistSpike/`, three-section `AudioTapBridge` API surface, hand-off mechanism candidates with primary + fallback, backpressure policy candidates with primary + fallback, 5 scenarios (S1 baseline, S2 strict-concurrency compile gate, S3 TSAN, S4 manual config-change recovery, S5 backpressure stress), full Phase 3 checklist marker block, Acceptance Criteria marker block, and a third Scenario Outcomes marker block.

The agent's Phase 1 plan came back substantive on first pass with five real verifications:

1. Verified Swift 6.2 SPM strict-concurrency default by reading verbose `swift build -v` output of the existing `MicCoexistSpike/` (compiler passes `-swift-version 6` regardless of additional flags).
2. Verified `main.swift` top-level code is MainActor-isolated in Swift 6 by reading `MicCoexistSpike/Sources/MicCoexistSpikeCLI/main.swift:57-58` (`nonisolated(unsafe) let engine = AVAudioEngine()`).
3. Verified production project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in Xcode build settings — and **flagged the SPM-vs-production divergence as risk #7**: in SPM, top-level free functions are implicitly nonisolated, but in production they're implicitly `@MainActor`. The explicit `nonisolated` keyword on `makeTapBlock` is redundant in SPM but **load-bearing in production**. Without it the function is implicitly `@MainActor` and the tap closure inherits the `_dispatch_assert_queue_fail` crash from Phase 1. This insight alone justified the spike — it would have hit M3.1 as a runtime crash with no compile signal.
4. Picked `AsyncStream` continuation + `.bufferingNewest(64)` as the primary hand-off + backpressure choice, with three rejected alternatives documented for each (Task.detached/per-buffer + unbounded mailbox; nonisolated(unsafe) ring buffer; dispatch serial queue / .bufferingOldest; .unbounded; bounded queue with blocking yield).
5. Unilaterally adjusted S5 stress-delay 50ms → 200ms (with a 50ms confirm-no-trigger pre-pass) because at 48kHz/4096 the callback fires every ~85ms and 50ms can't actually stress the policy. Agent's math was correct; accepted.

Architect approved with one addition: `CapturedAudioBuffer` must carry actual PCM sample data (not just metadata), so the in-closure copy step is validated under strict concurrency / TSAN / sustained rate. Without it, M3.1 would inherit the sample-copy validation as new work and the spike's "copy-paste this pattern" promise would be partial. Plus a requirement that REPORT.md's "how M3.1 copies this" subsection lead with the `nonisolated` factory function's load-bearing role under production isolation, not bury it as a footnote.

Implementation came back clean on S1, S2, S3, S5, but **S4 SKIP'd twice** — Chrome Meet did not trigger `AVAudioEngineConfigurationChange` in two 90s runs (~952 and ~958 buffers received, zero events) despite the engine-first ordering that Spike #4 Phase 1 (Session 008) had recorded as reliably triggering the notification. The agent's first reflex was to suggest closing S4 as SKIP and treating AC5 as a "confidence-builder, not a gating criterion." Architect pushed back directly: AC5 is gating; the whole reason for the spike was to exercise the recovery cycle Phase 1 documented but didn't run. Suggested input-device switch as an alternative trigger source — exercises the same notification + recovery code path, well-known to fire `AVAudioEngineConfigurationChange` reliably.

User confirmed AirPods on hand. Re-ran S4 with input-device switch (MacBook mic → AirPods → MacBook mic). Two config-change events captured cleanly: #1 routed to AirPods (24kHz / 1ch), #2 routed back (48kHz / 1ch). Recovery latency 196.9ms — well under the 500ms AC5 budget. No crash. 177 buffers received post-recovery. The same `AsyncStream` continuation was reused across recovery so the consumer's `for await` loop was uninterrupted.

Final report came back with all three marker blocks dispositioned verbatim: 16 Phase 3 checklist items, 8 ACs (each quoted with file/line/scenario references), 5 scenario outcomes. Sub-agent independent review produced four findings with verbatim notes: one MEDIUM (S4Tracker harness data race, harness-only, doesn't affect production pattern), two LOWs (recover() logs format pre-reinstall — cosmetic; S5 hardcodes 48kHz — harness fragility), and one INFO (`@preconcurrency import AVFoundation` in main.swift is correct; AudioTapBridge.swift uses plain import). All findings dispositioned as harness-level concerns; no production-pattern changes needed. Sub-agent review credible per Session 020's discipline: verbatim notes per item, real findings, dispositions explained.

**Spike #4 Phase 2 closes. M3.1 is unblocked.**

### Architectural decisions locked

1. **Canonical strict-concurrency tap pattern.** A top-level `nonisolated func makeTapBlock(continuation: AsyncStream<CapturedAudioBuffer>.Continuation) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void`, capturing only the Sendable continuation. The `nonisolated` keyword is **load-bearing** under production's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. M3.1 copies this exactly.
2. **`CapturedAudioBuffer` carries PCM samples, not just metadata.** Sendable value type with `frameLength`, `sampleRate`, `channelCount`, `sampleTime`, `hostTime`, plus the actual sample data copied out of `AVAudioPCMBuffer.floatChannelData` inside the tap closure before yielding. Validated under strict concurrency (S2), TSAN (S3), and sustained rate (S1: 2,976,000 samples copied over 60s).
3. **Hand-off via `AsyncStream` continuation; backpressure via `.bufferingNewest(64)`.** ~5.5s of audio at 48kHz; bounded memory; oldest dropped when consumer falls behind. Drain count exactly matched policy capacity in S5. Three rejected alternatives documented for each choice (per-buffer Task.detached + unbounded mailbox; nonisolated(unsafe) ring buffer; dispatch serial queue / .bufferingOldest; .unbounded; bounded queue with blocking yield).
4. **`AVAudioEngineConfigurationChange` recovery cycle.** Observe → stop → remove tap → re-set `setVoiceProcessingEnabled(false)` → reinstall tap with `format: nil` → prepare → start → resume buffer flow. Same `AsyncStream` continuation reused across recovery; consumer loop uninterrupted. Validated via input-device switch trigger (recovery latency 196.9ms in S4).
5. **Marker block template promoted to standard prompt template.** Added to `00_COLLABORATION_INSTRUCTIONS.md`'s Standard Prompt Template (Phase 3 checklist + Acceptance Criteria) and as Always-do #10. Established Session 021 after three sessions of checklist drift (M2.3, M2.5, M2.6); validated first try in M2.7's prompt; second-try-clean in this session's spike prompt with a third marker block (Scenario Outcomes) added ad-hoc per the new pattern.

### Findings to surface for M3.1

1. **Chrome Meet trigger non-reproducibility from Phase 1.** Two 90s S4 runs with engine-first ordering and Chrome joining a Meet produced zero `AVAudioEngineConfigurationChange` events. Spike #4 Phase 1 (Session 008) recorded this trigger as reliable. Possible causes: Chrome version drift, harness-vs-Phase-1-harness setup difference, or macOS behavior change. M3.1's smoke gate should test both Chrome Meet and input-device switch as trigger sources to surface the discrepancy in production conditions.
2. **Recovery latency measured only on event #2 in S4.** Either #1's latency was measured but not logged, or the measurement logic activates only on subsequent events after the first. M3.1's plan must specify recovery measurement on **every** config-change event.
3. **Frame size from `format: nil` on this hardware is ~4792, not 4096.** S5's expected-callback math used 4096 (overestimating by ~17%). M3.1 must derive frame size dynamically from the active format, never hardcode 4096.
4. **VPIO confirmed `false` after recovery.** No additional re-disable was needed in the recovery cycle's tested path, but the implementation includes the re-disable step defensively. M3.1 should keep the defensive re-disable (cheap; protects against future macOS behavior changes).

### Procedural lessons

1. **Marker block enforcement is now stable across module types.** Two sessions running (M2.7 module, Spike #4 Phase 2 micro-spike) of the new template producing zero checklist drift on first read. The template generalizes beyond modules — adding a third ad-hoc marker block (Scenario Outcomes) for spike-specific work proved the pattern composes. Promote-to-standard-template was the right call; no regression to artifact-as-file fallback (Session 020's option b) needed.
2. **Architect pushback on agent's premature SKIP-as-PASS framing was load-bearing.** When the first two S4 runs SKIP'd, the agent's reflex was to argue AC5 was a confidence-builder rather than gating. Architect direct response: "AC5 is gating; the whole reason we paid 1.5h for Phase 2 was to exercise the recovery cycle Phase 1 documented but didn't run." Suggested input-device switch as alternative trigger. Run cleared cleanly. Lesson: when an agent reframes an AC's stringency mid-implementation, push back hard — the prompt's framing was the contract, and the agent isn't authorized to renegotiate it.
3. **The architect's "verify before relying" instruction earned its keep again.** Same pattern as M2.7 (Session 021). The agent verified five real things (Swift 6 SPM defaults, MicCoexistSpike's nonisolated(unsafe) globals pattern, production's SWIFT_DEFAULT_ACTOR_ISOLATION, the SPM-vs-production isolation divergence at risk #7, and the load-bearing role of the explicit `nonisolated` keyword). Risk #7 alone would have cost a runtime crash in M3.1. Keep the instruction in every agent prompt that touches existing patterns.
4. **OS-API micro-spikes carry the same +1.5h trigger-debug-or-fix-round risk as integration modules.** Spike #4 Phase 2 ran 1.5h plan + 1.5h S4 trigger-debug = 3h total against 1.5h estimate (+100%). Same shape as M2.6's smoke-gate-caught-real-OS-bug pattern. New estimate-adjustment guidance added to `08_TIME_LEDGER.md`: micro-spikes that exercise OS-API behavior at runtime should multiply the estimate × 1.5–2.0.

### Time accounting

- Session start: 2026-05-08 ~07:00 -05:00 (Mexico) — first user message in this conversation establishing continuation work; date bash call on close-out for accuracy
- Session end: 2026-05-08 12:52 -05:00 / 17:52 UTC — close-out doc writes
- Wall-clock total: ~3h active (architect-side: doc edit + spike spec + agent prompt + plan audit + approval round + S4 SKIP debug + final audit + close-out; agent-side: ~1.5–2h of impl work landed asynchronously)
- Per-phase breakdown:
  - Architect doc edit + Spike #4 question framing: ~30 min
  - Spike spec write + agent prompt write: ~30 min
  - Phase 1 plan audit + approval-with-addition: ~15 min
  - Agent implementation (asynchronous): not on architect clock
  - S4 SKIP diagnosis + input-device-switch suggestion: ~10 min
  - Final report audit + close-out doc writes: ~30 min
  - Spike commits + tag (estimated user-side): TBD
- Estimate: 1.5h (spike Phase 2 spec). Actual active: ~3h. **Variance: +100%.** Cause: S4 trigger-debug round (Chrome Meet didn't reproduce Phase 1 trigger; one full re-run cycle to validate via input-device switch). Implementation itself ran on-estimate; the overage was the trigger-debug round, same shape as M2.6's smoke-gate fix rounds.
- See `08_TIME_LEDGER.md` for the cumulative pace data and updated estimate-adjustment guidance.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry, including `Time accounting` block
- `00_COLLABORATION_INSTRUCTIONS.md` — Standard Prompt Template Phase 3 checklist + Acceptance Criteria sections wrapped in `=== MARKER ===` / `=== END_MARKER ===` blocks with reproduce-verbatim instructions; new Always-do #10 promoting marker blocks as a generalizable mechanism; Last-revised header bumped
- `05_SPIKES.md` — Spike #4 entry extended with Phase 2 spec inline (preserved Phase 1 outcomes from Session 008); after spike close, Phase 2 status updated to ✅ passed with full validated-outcomes block including canonical pattern, hand-off mechanism, backpressure policy, recovery cycle, and three findings for M3.1 (Chrome Meet trigger non-reproducibility, recovery-latency-on-#1 ambiguity, frame-size assumption); original Phase 2 spec preserved below the validated-outcomes block per the spike-doc convention
- `04_BACKLOG.md` — S4 row updated to reflect Phase 2 close (`✅ passed Session 008 + Phase 2 strict-concurrency tightening ✅ Session 022; canonical pattern locked, recovery cycle validated 196.9ms`)
- `08_TIME_LEDGER.md` — Session 022 row added to per-session table; Spike #4 Phase 2 row added to per-module table; pace observations refreshed including new estimate-adjustment guidance for OS-API micro-spikes; project totals updated to end-of-Session-022

### Next session

- **M3.1 AudioPipeline.** First module of Phase 3. Estimate 4h canonical (per backlog); adjusted by Session 022 lessons: copy `MicTapTightenSpike/`'s `AudioTapBridge.swift` canonical pattern directly (the production form, with explicit `nonisolated`), wire it to a real consuming actor that hands buffers to the (yet-unbuilt) transcription engine surface. M3.1's plan must specify: (a) recovery measurement on every config-change event, not just rapid-fire successors; (b) frame size derived dynamically from the active format, never hardcoded; (c) smoke-gate test for both Chrome Meet and input-device switch as trigger sources; (d) the defensive VPIO re-disable in the recovery cycle. Estimate guidance: × 1.0–1.5 (one real OS-API dependency, but the canonical pattern is fully validated by this spike — risk is in wiring + smoke-gate trigger validation).
- Phase 3 covers M3.1, M3.4 (LanguageDetector), M3.5/a/b (TranscriptionEngine routing for Apple + Parakeet), M3.7 (token wiring). End of Phase 3 is Checkpoint #2 — the debug HUD showing live token stream, language, and backend identifier on real Zoom audio. This is where the Russian-transcription-quality risk gate fires.

---

## Session 021 — 2026-05-07 — M2.7 SessionPersistence shipped: Phase 2 closes; first session under the marker-block prompt template; agent caught three of architect's prompt errors before implementing

**Format:** Architect-driven module sequencing with the Claude Code agent. M2.7 from green-field to tagged complete in one architect session, with an overnight break between Phase 1 plan approval and the agent's Phase 2 work landing the next morning. Two commits: `aef1ba3` red, `6d87536` green. Agent did not need a fix round. **Phase 2 of the v1 release plan closes here** — the exit gate (open Voice Memos → widget appears at saved per-display position → close → fade-out → SwiftData store contains a session record on next launch) was validated end-to-end by the manual smoke gate.

### What happened

M2.7 wires `SessionCoordinator.onSessionEnded(_:)` to `SessionStore.save(_:)`. On paper a 1-hour module — pure glue between two surfaces locked since M1.5 (`SessionStore`) and M2.3 (`SessionCoordinator`). The architect's M2.7 prompt was the first to use the `=== PHASE3_CHECKLIST ===` and `=== ACCEPTANCE_CRITERIA ===` marker block format introduced after Session 020's lessons-learned about three-sessions-running of first-review checklist drift. This session was the structural test of the new template.

Result: the agent reproduced both marker blocks verbatim with each item dispositioned inline. No drift, no restructuring, no "let me condense this." The structural enforcement worked first try. Worth keeping as the project-wide format for prompt templates going forward, and rolling back through the prompt template in `00_COLLABORATION_INSTRUCTIONS.md` so future modules inherit it.

The plan came back substantive on first pass and caught **three errors in the architect's M2.7 prompt before implementing** — the highest-quality plan response of any module so far:

1. The prompt assumed `SessionCoordinator.onSessionEnded` was a single setter or registration property; agent verified by reading lines 76-78 that it's an array-append API supporting multiple consumers. Stronger contract than the prompt knew about.
2. The prompt assumed `SessionCoordinator.stop()` clears the handler registry; agent read lines 61-74 line by line and found it does NOT clear the registry. Means M2.7's callback registers once in `applicationDidFinishLaunching` and survives stop/start cycles without re-registration logic. Stronger and simpler than the prompt assumed.
3. The prompt presented a false dichotomy on `Session` value plumbing — "extend the callback signature" vs "compute `endedAt` at consumer side" — both unnecessary because `EndedSession` already carries both timestamps (verified line 14-18). The architectural question I posed didn't exist.

Plus three architectural deviations from the prompt, all correctly justified:

1. **`SessionPersisting` protocol on `SessionStore`** for AC 4's failing-test-double injection. Agent caught the contradiction in my own prompt: AC 4 required injecting a failing `SessionStore`, but `@ModelActor` types can't be subclassed. The protocol is one method (`func save(_ record: SessionRecord) async throws`); `SessionStore` conforms via extension. The fact that I'd written an AC that contradicted my "no new providers" instruction is a prompt-quality issue I'd missed in review.
2. **`SessionRecord.placeholder(from: EndedSession)` factory** on `Session.swift`. Not scope creep; this is the actual conversion site M2.7 needs (`EndedSession` → `SessionRecord`). Keeps the callback closure clean and makes the conversion independently testable.
3. **`endedSessionHandlers` not cleared on `stop()` is documented as a finding, not a code change.** Right call.

Implementation came back with both commits clean, 44 tests green (8 new — covers normal-end, multiple-sessions, pause-mid-session, no-double-save, stop-restart-no-double-register, save-failure-handling, placeholder-conversion, app-quit-during-session). Sub-agent review status not detailed in the report but no fix-round commits, suggesting either (a) sub-agent ran clean or (b) was rolled into the green commit; not worth a follow-up at this point — the smoke gate passed end-to-end on first try, which is the load-bearing verification.

Manual smoke gate ran as designed: three Voice Memos sessions all logged "Persisted session `<uuid>`" within the same MainActor turn as their "Session ended" line; Cmd+Q + reopen showed "Startup session count: 3" exactly matching pre-quit count. Bonus signal: M2.6's last-used-display preference still composing correctly under M2.7 (Session 3 used "Using last-used display Built-in Retina Display" after Session 2's drag, plus a "Clamped saved position" line indicating the saved coords were slightly off-screen on the current `visibleFrame` and the clamp logic kicked in).

**Phase 2 closes.** Nine modules tagged across Sessions 015–021: M1.1, M1.2, M1.3, M1.4, M1.5, M1.6, M2.1, M2.3, M2.5, M2.6, M2.7. The two-skipped modules (M2.2 per-app blocklist, M2.4 mic source identification) are deferred to v2 per Spike #1 deferral. Phase 2 exit gate validated end-to-end.

### Architectural decisions locked

1. **`SessionPersisting` protocol — one method, on `SessionStore`.** `func save(_ record: SessionRecord) async throws`. Production conforms via extension; test double conforms directly. Convention 6 pattern applied to `@ModelActor` types where subclassing isn't possible. Lives in `Sources/Storage/SessionStore.swift`.
2. **`SessionRecord.placeholder(from: EndedSession)` factory.** The canonical conversion site for v1's empty-metrics persistence. Phase 4's analyzer modules will populate the metric fields by replacing this call site (or by a separate non-placeholder factory); the placeholder factory itself stays for any ad-hoc save path that doesn't have analyzer data yet.
3. **`endedSessionHandlers` survive stop/start.** Documented behavior of `SessionCoordinator`; no code change. M2.7's callback registers once and never re-registers. Future consumers of `onSessionEnded(_:)` should follow the same pattern (register once at app start; don't register-and-clear per session).
4. **Save failure: log-and-swallow.** `Logger.session.error("Failed to persist session \(id): \(error)")`. The user loses one session record but the app keeps running. v1 accepts this; user feedback after v1.x will determine if retry/recovery is worth building.
5. **`Logger.session.info("Persisted session \(id)")` on success.** One info-level line per session. Won't bloat logs over multi-day uptime; provides smoke-gate evidence and post-incident audit trail.
6. **Empty-string placeholder for `Session.language` in v1.** M3.4 wires the real detected locale. The `StatsWindow` v2 view will need to render sessions with `language == ""` gracefully — backlog note.

### Open questions for next architect session

1. **Spike #4 reuse vs re-spike for Phase 3.** Phase 3 (audio + transcription) opens with `M3.1 AudioPipeline`. Spike #4 (mic coexistence with Zoom voice processing) closed Session 008 with PASS WITH CAVEATS — specifically the browser Meet recoverable-config-change caveat. The spike work was on a single AVAudioEngine instance lifecycle; M3.1's actual implementation may surface details the spike didn't cover (taps, format negotiation, callback threading under strict concurrency). Decision before writing the M3.1 prompt: tackle a tightening micro-spike for the `nonisolated` callback wrapper pattern from Spike #4 (one focused session, ~1h), or roll it into M3.1's plan and accept the risk of a fix round. Architect's prior: tighten the micro-spike first — Phase 3 has the most OS-API surface in v1 and is the one phase where smoke-gate fix rounds are likely to compound.
2. **Marker block template rollback to `00_COLLABORATION_INSTRUCTIONS.md`.** This session's prompt was the first to use marker blocks; it worked. Promote the format to the standard prompt template so M3.x prompts inherit it without re-derivation. Five-minute architect doc edit before the M3.1 prompt is written.

### Procedural lessons

1. **Marker block enforcement worked.** Three sessions running of checklist drift (017, 019, 020) ended after one session with the new template. The structural change ("reproduce the marker block verbatim with each item dispositioned inline; the marker block format is non-negotiable") was sufficient. Doesn't guarantee the agent's content is correct, but it makes drift mechanically detectable on first read of the report. Net win; no regression to the artifact-as-file fallback (option b from Session 020's journal) needed.
2. **Architect prompt-quality issues caught by the agent before implementation.** Three of my prompt's assumptions about `SessionCoordinator` were wrong; agent verified each by reading the actual code. Reinforces the pattern: when the prompt asks a "is this true about an existing module?" question, the agent's first move is reading the actual implementation, not relying on the prompt's framing. Architect's prompts to existing-module integrations should explicitly say "verify by reading the file" for every assumption — present in M2.7's prompt under Phase 1 step 2 ("read first; only adjust if the existing surface doesn't fit"). That instruction earned its keep.
3. **Smoke gate is uneventful when the underlying contracts are well-locked.** M2.7's smoke passed end-to-end on first try because both `SessionCoordinator` and `SessionStore` were locked with strong contracts (M2.3 hybrid consumer interface, M1.5 Sendable record-type boundary). Compare M2.6 where two smoke-gate fix rounds were needed because `mouseDown(with:)` and `NSScreen.main` semantics weren't locked — they're system APIs with documented-but-counterintuitive behavior. Pattern: smoke-gate failure rate correlates with the number of unverified-system-API assumptions in a module's design. Phase 3 has many.

### Time accounting

- Session start: 2026-05-06 22:48 -05:00 (Mexico) / 2026-05-07 03:48 UTC — first user message in this conversation pasting the M2.7 plan from the agent
- Session end: 2026-05-07 09:18 -05:00 / 14:18 UTC — final smoke confirmation
- Calendar span: 10.5h (includes overnight sleep break)
- Active wall-clock estimate: ~2.5–3h
  - Plan review + approval message (May 6, 22:48–23:00 -05:00): ~15 min
  - Overnight break: ~9.5h
  - Agent's Phase 2+3 work landed in two commits (`aef1ba3` red, `6d87536` green) overnight or early morning May 7 — agent-side time inferred from commit metadata (would need git log to be precise; ~1.5h of agent work is the typical M2.x range)
  - User's smoke gate run + paste back (May 7, ~09:15–09:18 -05:00): ~5 min for the 3 sessions and the cross-launch verification
  - Architect's analysis + close-out doc writes: ~15 min
- Estimate: 1h. Active actual: ~2.5–3h. **Variance: +150% to +200%.** Cause: the close-out work itself (journal + ledger + tag + commit + push, plus the Phase 2 milestone framing) is larger than the 1h estimate which only covered the M2.7 implementation work. The implementation itself ran on or under estimate.
- Refinement to per-module estimating: the close-out work for milestone-closing modules (Phase 2 close here, Phase 3 close at M3.7+, Phase 5 close at M5.x) carries an additional ~30 min for the journal+ledger+architecture-doc write that non-milestone modules don't. Note this in the ledger.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry, including `Time accounting` block per the new convention
- `04_BACKLOG.md` — M2.7 marked `✅ done` with `m2.7-complete` tag reference and actual-time annotation
- `08_TIME_LEDGER.md` — Session 021 row added to per-session table; M2.7 row added to per-module table; pace observations refreshed; Phase 2 close-out flagged in the running totals
- (No `03_ARCHITECTURE.md` change for M2.7 — the SessionStore + SessionCoordinator surfaces were already locked in Sessions 015 and 017; this module is glue, not architecture)

### Next session

- **Architect doc work first (5 min, no agent).** Promote the `=== MARKER ===` block template to `00_COLLABORATION_INSTRUCTIONS.md`'s "How Claude writes prompts" section so all future module prompts inherit it.
- **Then decide on Spike #4 micro-tightening vs straight M3.1.** Architect's prior: tighten the micro-spike. Five-minute decision; ask the user on next session start.
- **Phase 3 opens with M3.1 AudioPipeline** (~6h estimated; first real OS-API integration since M2.6, expect smoke-gate work). Phase 3 covers M3.1, M3.4 (LanguageDetector), M3.5/a/b (TranscriptionEngine routing for Apple + Parakeet), M3.7 (token wiring). End of Phase 3 is Checkpoint #2 — the debug HUD showing live token stream, language, and backend identifier on real Zoom audio. This is where the Russian-transcription-quality risk gate fires.

---

## Session 020 — 2026-05-07 — M2.6 per-display position memory shipped over three rounds: original implementation, save-trigger fix (mouseDown was wrong), last-used-display fix (NSScreen.main was wrong)

**Format:** Architect-driven module sequencing with the Claude Code agent. M2.6 from green-field to tagged complete in one architect session, but with two iterative fixes after the manual smoke gate caught real bugs the unit tests didn't. Six commits in the M2.6 series spanning ~3.5h of architect time across plan + two fix-prompt cycles + close-out. 33 new tests added (147 total in repo). Three rounds:

1. **Original implementation** (`8c75ff8` red, `2584f40` green). Per-display position memory with screen-relative coords, `ScreenProvider` Convention 6 injection, overlaps-the-most screen identification on save, off-screen clamp-and-don't-save on restore, `mouseDown(with:)` override on `CoachingPanel` as the save trigger. 13 position tests + lint clean + 5 sub-agent notes (3 PASS, 1 ACCEPTED on zero-overlap edge case, 1 noting always-visible close-button placeholder for M5.7). Looked good on paper.
2. **Save-trigger fix** (`5f87e78` red, `6351a25` green). Manual smoke gate revealed the widget was draggable but no save fired — every session restarted with default top-right. Diagnosis: `super.mouseDown(with:)` returns immediately under modern AppKit (drag is async-handed-off to the window server), so the frame-origin comparison saw no change. Fix: switch to `NSWindow.didMoveNotification` observer with `isProgrammaticMove` flag toggled around `setFrame` and 300ms debounce via the existing `HideScheduler`. The agent's M2.6 plan had explicitly flagged this risk as the verification target for the smoke gate; the smoke gate did its job.
3. **Last-used-display fix** (`0727e06` red, `3fe2a48` green). Smoke gate after fix #2 revealed save was now reliable but multi-display restore was wrong — drag-to-DELL saved correctly, but next show `NSScreen.main` returned Built-in (because the user's window focus was there), so widget appeared on Built-in with Built-in's saved position. The DELL save sat unused. Diagnosis: `NSScreen.main` tracks "screen of the focused window," not "screen the widget was last on." Fix: persist `widgetLastUsedDisplay: String?` in `SettingsStore`, update it on every drag-end alongside the position write, prefer it in `frameForShow()` ahead of `NSScreen.main`. Falls back gracefully when the recorded display is disconnected; orphaned entry NOT auto-cleared so reconnect restores user intent.

End-state smoke gate confirmed both scenarios work: drag to DELL → close → reopen → "Using last-used display DELL U2723QE" → widget on DELL; disconnect DELL → reopen → "Last-used display disconnected, falling back to NSScreen.main" → widget on Built-in.

### What happened

The original M2.6 plan was substantive on first pass with three sharp catches: screen-relative coords (preserves user intent across monitor rearrangement) caught by the agent reading my AC5 wording carefully and flagging the implication; `NSHostingView` vs `NSHostingController` choice carried over from M2.5; `Sources/Widget/` directory correction (my prompt had `Sources/UI/`). Five sub-agent notes after Phase 2, all dispositioned cleanly. By the green-phase commit `2584f40`, M2.6 looked done — code-complete, lint clean, 13 new tests, `swiftlint --strict` on every commit.

Smoke gate broke that. The widget moved (AppKit's `isMovableByWindowBackground` was working) but no "Saved position" log appeared. The agent's plan had flagged this exact risk: *"I'll verify this in the manual smoke gate. If this assumption is wrong, the fallback is `NSWindow.didMoveNotification` with a debounce."* The hypothesis was wrong; the fallback was correct. Fix prompt #1 went out within minutes of the smoke result; the agent's first reply went straight to the fix without verifying the original hypothesis (procedural skip), which I caught in a clarification round and they answered honestly: "I skipped the doc-verification step. The `didMoveNotification` fix works regardless of whether `super.mouseDown` returns immediately or blocks-but-doesn't-update-frame — both hypotheses lead to the same conclusion." Acceptable, because the load-bearing question was about the fix, not the autopsy.

The `didMoveNotification` fix landed clean (4 new tests, both commits lint clean) but the first Phase 3 self-review report had two procedural gaps: a sub-agent review claiming "0 issues, all 11 items passed" without verbatim notes (not credible after three sessions of substantive findings), and a procedural deviation in the test files between red and green commits. I asked for both to be re-done; the second response was honest — sub-agent re-run produced 11 findings (2 MEDIUM accepted as bounded-failure-mode, rest INFO/LOW), and the test-file delta was characterized as exclusively redundant `NotificationCenter.default.post()` removals (real `NSPanel.setFrameOrigin` already auto-fires `didMoveNotification`, so the manual posts caused double-delivery). Test assertions weren't modified; values weren't modified. Accept-and-document was the right disposition over interactive-rebase-the-history (two unpushed commits, but procedural risk of rewriting history on a non-semantic change isn't worth it).

Smoke gate after fix #1 passed save reliably for drag-on-Built-in and drag-on-DELL — but reopen-on-DELL didn't restore on DELL. The architect's call: this is the second pillar of "per-display position memory" — knowing which display to show on, not just where on it — and it's the M2.6 promised feature, so the right move is fix it before tagging, not tag-with-known-limitation. Fix prompt #2 went out; agent's plan was tight (point-level `SettingsStore` accessors matching existing `position(for:)` shape, `@Published` property with M1.4 sync wiring for consistency, fallback chain in `frameForShow()`), 10 tests covering bootstrap + last-used-hit + disconnect-fallback + drag-saves + cross-screen-update + persists-across-instances. Phase 3 came back with credible sub-agent notes (sub-agent Note 2: `localizedName` as display identity is fragile; backlogged for v1.x), TDD lock intact (`git diff` empty between red and green test files), `swiftlint --strict` clean.

Smoke gate confirmed end-to-end. M2.6 done.

### Architectural decisions locked

1. **Save trigger: `NSWindow.didMoveNotification` + 300ms debounce + `isProgrammaticMove` flag.** Synchronous main-thread delivery of `NotificationCenter.post` posted on the main thread is the load-bearing assumption that makes the flag reliable. Worst-case if Apple changed delivery semantics: a redundant write of the already-stored position. Bounded, harmless. The `mouseDown(with:)` approach was wrong because modern AppKit hands drag-tracking to the window server async; `super.mouseDown` returns immediately. Documented in §8 so the next maintainer doesn't try to "simplify" back to `mouseDown`.

2. **Screen-relative coordinate storage, not absolute.** Saved positions are `(panel.origin - screen.frame.origin)`, restored as `screen.frame.origin + saved`. Preserves user intent across multi-monitor rearrangement (e.g., user moves external display from left to right in System Settings → global coords shift but the saved relative offset stays correct).

3. **Off-screen clamp-and-don't-save.** When a saved position would clip outside the target screen's `visibleFrame` (smaller screen, resolution change, etc.), the displayed position is clamped to fit but the saved value is NOT overwritten. The user's 4K-corner intent survives a temporary laptop-screen-only session.

4. **Screen identification on save: overlaps-the-most.** `screenWithMostOverlap(for:in:)` over `allScreens()` picks the destination screen by intersection-area between panel-frame and screen-frame. `panel.screen` was rejected (updates async after a move; reading it inside the drag handler gives the source, not destination).

5. **Last-used-display preference, fallback chain.** `SettingsStore.widgetLastUsedDisplay` → if connected, use it; else `NSScreen.main`; else `NSScreen.screens.first`; else hardcoded synthetic frame. Orphaned entries on disconnect are NOT auto-cleared so reconnect restores user intent.

6. **`ScreenProvider` Convention 6 injection.** `ScreenDescription: Equatable, Sendable` value type carrying `localizedName`/`visibleFrame`/`frame` (NSScreen itself isn't Sendable). Production wraps `NSScreen.main` and `NSScreen.screens`; `@unchecked Sendable` test fake provides configurable arrays for multi-monitor and disconnected-display test scenarios without hardware.

7. **`SettingsStore` typed accessors over raw dict access.** Point-level `position(for:)`/`setPosition(_:for:)` and `lastUsedDisplay()`/`setLastUsedDisplay(_:)` instead of exposing `widgetPositionByDisplay` mutation directly. Self-documenting call sites in the controller; encapsulation of UserDefaults round-trip (JSON encoding for the dict, plain string for the last-used name). Matches the M1.4 `@Published` + `didSet` + `isSyncing`-guard live-sync pattern.

8. **`HideScheduler` reuse for two purposes.** Same scheduler instance handles both the M2.5 5-second hide-after-mic-off and the M2.6 300ms drag-save debounce. Two coexisting tokens keyed by `ObjectIdentifier`; no cross-cancellation risk. M2.5's TokenStorage cleanup-on-natural-fire fix from Session 019 is what makes this safe long-running.

### Open questions for next architect session

1. **`CGDirectDisplayID`-based display keying (sub-agent Note 2 from fix #2).** `localizedName` as display identity is fragile: language changes, display renames in System Settings, duplicate monitor names. The robust alternative is `CGDirectDisplayID` (numeric per-display ID stable across reboots and language). Cost: a `DisplayProvider` change to surface the ID, a UserDefaults migration of the existing `widgetPositionByDisplay` (string keys → numeric) and `widgetLastUsedDisplay` (string → numeric or struct), and a test pass. Bounded scope; not v1 work but clean v1.x candidate. Backlog item.

### Procedural lessons (the same one, three sessions running)

1. **First-review checklist drift.** Session 017 (M2.3), Session 019 (M2.5), and now Session 020's first save-trigger-fix report all had the same pattern: agent's first final-status report restructures the prompt's checklist into their own list, drops or merges items, requires a follow-up prompt to get the full march. Three sessions of the same lesson. The lesson is now structural, not behavioral: my prompt template should make checklist drift mechanically harder. Ideas for next prompt: (a) put the checklist in a unique-marker block the agent must reproduce verbatim with each item dispositioned inline; (b) make the checklist itself an artifact the agent commits as a `.md` file in the repo so the diff is auditable; (c) add a structural "do not summarize" instruction near each list. Decide before M2.7's prompt.

2. **First-pass sub-agent reviews need to be credible, not just present.** This session's first save-trigger fix returned "0 issues, 11 items passed" with no verbatim notes; not credible after three sessions of substantive sub-agent catches. Re-run produced 11 findings as expected. The lesson: a sub-agent run that produces zero notes against a non-trivial fix is itself a signal worth pushing on. Future prompts should require verbatim notes (with dispositions) regardless of severity; "no findings" without notes is an unverifiable claim.

3. **Hypothesis-skipping vs. fix-driven thinking.** When fix prompt #1 went out, I asked the agent to verify the original `mouseDown`-blocking hypothesis before committing to the `didMoveNotification` fix. The agent skipped the verification, which I caught with a clarification round; their answer was honest and substantively right ("the fix works regardless of which hypothesis is true"). Lesson: the prompt's "verify before committing" instruction is sometimes Inappropriate framing — when the new approach orthogonalizes the old question, verification of the old question is moot. Future prompts should distinguish "verify because the fix depends on the answer" from "verify for autopsy purposes" so the agent doesn't waste a round trip on the latter.

4. **Smoke gate is the only verification that catches OS-level integration bugs.** Both M2.6 fixes were caught by smoke, not by unit tests, because the bugs lived in real-AppKit territory: `super.mouseDown` async-handoff, `NSScreen.main` semantics. The unit tests with `FakeScreenProvider` and synthetic notification posts couldn't surface either. Reinforces the Definition-of-Done procedure (smoke gate before tagging) — the cost of missing a smoke step is two extra fix rounds, exactly what happened here.

5. **Test-modification deviation discipline.** Fix #1's red-phase tests had redundant `NotificationCenter.default.post()` calls alongside `setFrameOrigin` (which auto-fires the notification on real `NSPanel`). Removed in green phase, which technically violated the TDD lock. Architect accepted the deviation as non-semantic (assertion logic and values unchanged). The cleaner discipline going forward: when the green phase reveals a red-phase test was wrong on a non-semantic point, prefer either an explicit "fix(tests)" commit before the green commit, or interactive-rebase-amend before pushing. The fix in this session was caught after push, so accept-and-document was the right disposition; for future modules, catch it earlier.

### Ups

- Three rounds of work in one architect session, all converging cleanly. The fix prompts were ~150–190 lines each and tightly scoped (no plan rewrites, no architectural changes, just specific bugs).
- Sub-agent value continues to compound across modules. M2.6 original sub-agent caught the always-visible-close-button REMOVE-IN marker requirement; fix #2 sub-agent surfaced the `localizedName` fragility now backlogged for v1.x.
- The agent's M2.6 original plan called the `mouseDown` risk explicitly *and* called the smoke-gate as the verification step. When smoke broke, the plan was ready. That's procedural maturity; reward by continuing to require explicit risk-flagging in plans.
- 147/147 tests + lint clean across all six commits including each red-phase. The procedural locks from Sessions 016/017 hold.
- Manual smoke gate end-to-end working: drag to DELL stays on DELL, drag back to Built-in stays on Built-in, disconnect DELL falls back gracefully. The multi-display promise is kept.

### Downs

- Two fix rounds. M2.6 was budgeted at 2h; actual was 2h + ~1.5h of fixes. The save-trigger bug was foreseen by the agent's plan and would have been caught regardless; the last-used-display bug was a real architectural oversight in my original prompt (I specified "use NSScreen.main" without thinking about what NSScreen.main actually returns). My first prompt was wrong; the fix prompt corrected my mistake. Lesson for next module: when I specify a system API, walk through what it actually returns in the multi-state cases the user will encounter.
- Three sessions running of first-review checklist drift. Promote to structural prompt-template change before M2.7.
- First sub-agent review of the save-trigger fix wasn't credible. Same procedural-trust signal as the checklist drift; same need for prompt-template tightening.

### Time accounting

- Session start: 2026-05-06 ~17:30 -05:00 (Mexico) — first user message in this conversation establishing M2.6 work; user preceded with Session 019 close-out push at 17:23
- Session end: 2026-05-06 22:17 -05:00 — final commit (M2.6 close-out docs)
- Wall-clock total: ~4.5h (with one ~30m fix-prompt-write/architect break in the middle between rounds)
- Commit span (per git log): 18:19 → 22:17 = 3h 58m
- Per-fix-round breakdown:
  - M2.6 original implementation: 18:19 → 18:21 = 2 min commit-spread, ~30m architect setup before, ~30m smoke gate after = ~1h
  - Save-trigger fix (didMoveNotification): 19:59 → 20:07 = 8 min commit-spread, ~1h architect time around (clarification round + plan + approval) + smoke gate = ~1.5h
  - Last-used-display fix: 21:50 → 22:02 = 12 min commit-spread, ~1.2h architect time around (design discussion via elicitation + plan + approval) + smoke gate = ~1.5h
  - Close-out: 22:02 → 22:17 = 15m commits + ~15m architect = ~30m
- Estimate: 2h. Actual: ~4.5h. **Variance: +125%** — driven by two smoke-gate-caught fix rounds. M2.6's nominal 2h scope ran on-estimate (~25 min for the original implementation); the cost above estimate was the real-OS-bug-fix cycles.
- See `08_TIME_LEDGER.md` for the cumulative pace data.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry, including the new `Time accounting` block
- `04_BACKLOG.md` — M2.6 marked `✅ done` with `m2.6-complete` tag reference and updated description (per-display position + last-used-display + drag-trigger reliability); per-module actual-time annotations added retrospectively to all completed M1.x and M2.x rows
- `03_ARCHITECTURE.md` §8 (FloatingPanel) — extended Implementation block with Session 020 locked design: per-display position memory, screen-relative coordinate storage, drag-save trigger (with explicit note on why the `mouseDown` approach was wrong), last-used-display preference, screen-identification rule on save, `ScreenProvider` injection, updated file list
- `03_ARCHITECTURE.md` §10 (Settings) — added `widgetLastUsedDisplay` key (seventh v1 key), documented orphaned-entry-no-auto-clear behavior, expanded `widgetPositionByDisplay` description to cover M2.6's typed accessors and corrupt-data warning
- `08_TIME_LEDGER.md` — new file, time tracking ledger with per-session and per-module actuals; backfilled from git log for Sessions 015–020
- `00_COLLABORATION_INSTRUCTIONS.md` — added Time-tracking section requiring `Time accounting` block in every session journal entry going forward

### Next session

- **M2.7** (Session persistence at session end). 1h estimate. Wires `SessionCoordinator.onSessionEnded(_:)` (the one-shot consumer surface from M2.3) to `SessionStore.save(_:)` from M1.5. After M2.7 ships, Phase 2 closes and the Phase 2 exit gate is testable end-to-end (open Zoom → widget appears with timer + Listening… → close Zoom → fade-out → SwiftData store contains a session record on the next app launch).
- Before writing the M2.7 prompt: decide on the prompt-template structural change for checklist drift (item 1 above). Don't ship another prompt with the current structure if the same first-review pattern is going to repeat.

---

## Session 019 — 2026-05-06 — M2.5 FloatingPanel skeleton shipped: 4-state visibility machine, dismissal flow, sub-agent catches TokenStorage leak

**Format:** Architect-driven module sequencing with the Claude Code agent. M2.5 from green-field to tagged complete in one architect session. 17 new tests added (120 total in repo). Three commits in the M2.5 series: `7ccb8f3` failing tests, `a4c76df` implementation, `add8d78` sub-agent review fixes.

### What happened

`FloatingPanel` is the user-visible chrome of the v1 app — the translucent always-on-top widget that activates with the mic and disappears 5s after mic-off. M2.5 ships the skeleton: NSPanel infrastructure with the locked architecture §8 config, SwiftUI host (`NSHostingView`, not `NSHostingController` — the panel-as-container choice), persistent-visibility state machine bound to `SessionCoordinator.$state` via `.sink`, dismissal flow with confirmation alert, dynamic placeholder content (mm:ss timer + "Listening…" caption), default top-right 16pt-inset position. Real WPM display, color interpolation, hover saturation, drag-to-move, per-display position memory, and accessibility polish all defer to later modules.

The session opened with three doc-state cleanups carried over from Session 018 — stale `M2.5` description in `04_BACKLOG.md` ("show on speech / hide on mic-off"), stale "show on first token" text in `03_ARCHITECTURE.md`'s data-flow ASCII, and a Phase 2 Checkpoint #1 narrative in `07_RELEASE_PLAN.md` that assumed an audio-energy "speaking detected" toggle. All three originated in the Session 014 widget design (which was reverted by Session 013's persistent-visibility lock and reaffirmed Session 018) and survived audits in Session 015–018. Architect resolved Checkpoint #1 by dropping the audio-energy toggle from M2.5 — only one `AVAudioEngine` exists in v1 (owned by `AudioPipeline` in Phase 3), and the persistent-visibility model already exposes whether the mic-on/mic-off lifecycle is correctly wired without an ad-hoc engine. Pure scope tightening with no functional loss.

The plan came back substantive on the first pass with one sharp catch: the prompt wrote `Sources/UI/` while CLAUDE.md and the established project layout have `Sources/Widget/`. The agent corrected silently in the plan. Architect approved with two implementation notes — `Sources/Widget/` confirmed, and `NSScreen.main ?? NSScreen.screens.first` as the LSUIElement nil-safe fallback for default-position calculation.

Implementation came back with three commits, 120/120 tests passing, lint clean across all three. Sub-agent independent review found five issues — three real correctness bugs (TokenStorage memory leak when timer fires naturally, unnecessary `MainActor.assumeIsolated` on a `@MainActor` class method, wrong `@unchecked Sendable` on TokenStorage when all access is main-actor) and two by-design placeholder markers (always-visible close button to be REMOVE-IN-M5.7'd, `.regularMaterial` background to be replaced by Liquid Glass in M5.7). All three correctness issues addressed in commit `add8d78`. The `TokenStorage.items` leak — entries keyed by `ObjectIdentifier(token)` accumulating when the hide timer fired naturally (only the cancel path removed entries) — is a real long-running-app concern that would have shipped to production without the sub-agent catch.

Architect's first review of the final report missed several Phase 3 self-review checklist items the prompt required item-by-item (test-immutability via `git log --follow`, threading verification, print/commented-out-code/doc-comments audits, per-commit lint state, files-match-planned-paths). Same pattern Session 017 flagged for M2.3. Caught and corrected with a follow-up prompt; the agent's complete second report had everything plus the 12 verbatim ACs and the seven smoke-gate scenarios listed for the user. Two sessions in a row of this same first-review miss — the architect's reflex on first read of any final status must walk both lists (verbatim ACs plus Phase 3 checklist items) line by line before accepting.

Manual smoke gate passed end-to-end on the user side: panel appears on mic-on, ticks the timer, stays during session, fades 5s after mic-off, dismisses with confirmation, dismissal scope clears at session end, rapid toggle handles cancellation cleanly, pause-mid-session uses the same fade path, Cmd+Q is clean.

### Architectural decisions locked

1. **4-state visibility machine.** `PanelVisibilityState: { hidden, visible, fadingOut, dismissed }`. Transitions: `hidden → visible` on `.idle → .active` (gated by `!= .dismissed`); `visible → fadingOut` on `.active → .idle` (5s timer scheduled); `fadingOut → hidden` on timer fire; `fadingOut → visible` on `.idle → .active` returning before timer fire (timer canceled); `visible → dismissed` on user confirm in dismiss alert; `dismissed → hidden` on `.active → .idle` (dismissal scope cleared at session end). All other transitions are no-ops.

2. **Pause-mid-session uses the same fade path as mic-off.** `SessionCoordinator` produces `.idle` regardless of cause; the panel treats both transitions identically. The 5s fade reads "session ended" whether triggered by mic-off or user-pause; an instant vanish on pause would look like a crash. Decision made by the agent in plan; architect's default position confirmed.

3. **`NSPanel` config additive: `isOpaque = false`.** Not in the architecture §8 list as written, but logically required alongside `backgroundColor = .clear` and `hasShadow = false` for the SwiftUI material to render its own translucency without AppKit drawing an opaque base. Folded into §8 in this session's doc revision.

4. **`NSHostingView` (not `NSHostingController`) for panel content.** The panel-as-container pattern: `CoachingPanel` (NSPanel subclass) owns the content view directly. `NSHostingController` is reserved for cases where the controller IS the window's content controller (the Settings window's pattern from M1.3); here, the custom NSPanel subclass already plays that role.

5. **`DispatchWorkItem` scheduler over `Task.sleep`.** Synchronous, guaranteed cancellation is the load-bearing property — `Task.sleep` is cooperative and can fire its action even after `cancel()` if the task hasn't reached its suspension point yet. `DispatchQueue.main.asyncAfter(deadline:execute:)` plus `DispatchWorkItem.cancel()` gives deterministic cancel-before-run semantics, which the state machine depends on for the `fadingOut → visible` cancellation path.

6. **`@MainActor` `TokenStorage` with explicit cleanup on natural fire.** The `HideScheduler` production impl uses a single shared `TokenStorage` for token-to-DispatchWorkItem mapping. Sub-agent caught two issues — storage was originally `@unchecked Sendable` (all access is main-actor; `@MainActor` is the stronger compiler-enforced guarantee) and entries leaked when the timer fired naturally (only the cancel path removed entries). Both addressed: storage is `@MainActor`, the DispatchWorkItem callback removes the entry from storage before invoking the action.

7. **Default position screen-selection: `NSScreen.main ?? NSScreen.screens.first`.** The fallback covers the LSUIElement case where no key window exists at panel-show time. Position computed as `(visibleFrame.maxX - 144 - 16, visibleFrame.maxY - 144 - 16)`. M2.6 will add per-display memory; M2.5 just computes the default each show.

8. **`Sources/Widget/` directory (not `Sources/UI/`).** CLAUDE.md and the established Phase 1 layout. The M2.5 prompt's `Sources/UI/` reference was an architect-side writeup error. Caught by the agent in plan review.

### Open questions for next architect session

1. **Doc comments on public APIs.** The agent's Phase 3 self-review item 5 surfaced a real gap: the prompt template's checklist asks "Public APIs have doc comments," but no prior Phase 1 / Phase 2 module (`MicMonitor`, `SessionCoordinator`, `PermissionManager`, `SettingsStore`, `SessionStore`, now `FloatingPanelController`) uses doc comments on its public API. The project relies on self-documenting names plus `CLAUDE.md` for architecture context. M2.5 followed the established convention; the checklist item is therefore an aspiration the project hasn't adopted. Two paths forward: (a) accept that the item is a no-op for this project and remove it from the prompt template; (b) commit to the convention starting with M2.6+ and retroactively annotate the existing modules. Decide once before more modules ship.

### Procedural lessons

1. **Architect first-review miss on the prompt's Phase 3 checklist items.** Same pattern as Session 017's M2.3 first-review miss. The agent's first final-report restructured the 12 ACs into their own AC1–AC14 list and skipped 7 of the 11 Phase 3 self-review checklist items. The substance was in the implementation; the report was the gap. Caught and corrected; complete second report had everything. Two sessions in a row — promote to a procedural reflex for M2.6+: walk both lists (verbatim ACs plus Phase 3 checklist items) line by line on first read of any final status before accepting.

2. **Sub-agent value continues to compound.** Three real correctness issues caught (TokenStorage leak, MainActor footgun, wrong Sendable conformance) that would have all shipped silently. The cost of writing "spawn a sub-agent" into the prompt is one line; the value is two-to-three production-quality issues per high-risk module. Continuing as policy: every `Sources/Core/`, `Sources/Storage/`, and `Sources/Widget/` module gets a sub-agent review.

3. **Verbatim-with-disposition format works.** Five sub-agent notes, three ADDRESSED with commit references, two PASS with rationale. Each is traceable to a concrete decision. Continuing as the standard format.

### Ups

- Plan came back high-quality on first pass. Eight Phase 1+2 conventions plus three Phase 2 procedural locks meant zero rederivation churn. The agent applied Convention 6 (provider injection) for both the alert presenter and the hide scheduler without prompting beyond the prompt's reference.
- Sub-agent caught the `TokenStorage` memory leak before it shipped. Long-running-app concern that would have manifested as gradual `.items` dictionary growth over multi-day uptime sessions and not surfaced until much later.
- 17 tests + 120/120 + lint clean across all three commits including the failing-tests commit. Procedural tightening from Session 017 holds.
- Manual smoke gate passed end-to-end on user side. All seven scenarios from the Definition of Done section 6 confirmed.
- Three carry-over doc-state cleanups from Sessions 014/018 caught and fixed in the same session that produced the M2.5 prompt. The audit reflex worked: read the M2.5 backlog row, read §8, read Checkpoint #1 — all three flagged as inconsistent with the locked persistent-visibility model before the prompt went to the agent.

### Downs

- Architect's first review of the final report skipped the Phase 3 checklist march. Same pattern as Session 017. The follow-up was needed to get a complete report. Two-strike-rule cost burned on workflow churn rather than real-substance correction; this needs to stop being a pattern by M2.6.
- The "Sources/UI/" mistake in the M2.5 prompt was avoidable. CLAUDE.md is in the prompt's reading order and explicitly says `Sources/Widget/`. Ten-second check that wasn't done.
- Doc-comments inconsistency surfaced as a real question (item 1 above) but the architect didn't decide it in-session. Now flagged in journal for the next architect session before more modules ship.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry
- `04_BACKLOG.md` — M2.5 marked `✅ done` with `m2.5-complete` tag reference
- `03_ARCHITECTURE.md` — `FloatingPanel` §8 implementation block rewritten with the locked design (4-state visibility machine, NSPanel additive `isOpaque = false`, NSHostingView vs NSHostingController choice, DispatchWorkItem scheduler rationale, @MainActor TokenStorage with cleanup-on-natural-fire, NSScreen.main fallback, file paths). `WidgetViewModel` description updated to note the M2.5 skeleton surface (`sessionStartedAt`, `isSessionActive`) vs the M5.1 full surface.
- (From this session's earlier doc-state pass:) `04_BACKLOG.md` M2.5 description, `03_ARCHITECTURE.md` data-flow ASCII + SessionCoordinator full-lifecycle list, `07_RELEASE_PLAN.md` Phase 2 narrative + Checkpoint #1 description + checkpoint summary table — all three aligned with the persistent-visibility lock.

### Next session

- M2.6 (Per-display widget position memory) OR M2.7 (Session persistence at session end). Both are small (2h and 1h estimates) and close out Phase 2 between them. M2.6 directly extends M2.5's panel positioning logic; M2.7 wires `SessionCoordinator.onSessionEnded` (the one-shot consumer surface from M2.3) to `SessionStore.save(_:)` from M1.5. After both ship, the Phase 2 exit gate is testable end-to-end (open Zoom → widget appears with timer + "Listening…" → close Zoom → fade-out → SwiftData store contains a session record).
- Doc-comments-as-convention question (Open Questions item 1) needs a one-question architect decision before more modules ship. If "yes, adopt the convention," retroactive annotation cost is small (six modules' public APIs). If "no, drop the checklist item," update the prompt template once.

---

## Session 018 — 2026-05-05 — Brand: Locto adopted as user-facing name + visual reference; Scope: filler tracking deferred to v2.0; design package replaces prior `design/` directory

**Format:** Architect-only session, no Claude Code agent involvement. Working session between Phase 2 modules (after M2.3 close, before M2.5). Project-wide doc revision driven by two product-owner decisions: (1) brand adoption from external Locto design package, (2) market-discovery-driven scope reduction deferring filler tracking to v2.0.

### What happened

The user uploaded an external design package — five product/scope/build-phase markdown docs plus a self-contained brand-guidelines HTML — produced by a separate Claude Design effort assuming a from-scratch build of an ambient speech-coaching app branded "Locto". The package included visual identity (brand teal `#0F6E56`, Inter type stack, slate-blue / sage-green / warm-coral state inks, ring-and-dot mark, "Speak in your sweet spot" tagline), component specs (320pt widget with solid pastel gradients, vertical-stroke filler counts, hero number treatment, coach notes, dashboard tab bar), and voice/tone rules (direct, present, calm; specific verbs not coaching jargon).

The architect walked through reconciliation with the user across four turns. The five Locto markdown docs (product, design-spec, data-model, build-phases, open-questions) were confirmed as **reference only** — they assumed from-scratch architecture (Apple Speech vs whisper.cpp, GRDB vs Core Data, App Store sandboxing trade-offs) that contradicts our locked Architecture Y, locked SwiftData persistence, locked Phase 1 conventions. Only the brand-guidelines HTML and the design-spec doc map to anything we'd save in the project; the other three are reference material the user keeps locally.

Then four reconciliation decisions in sequence:

1. **Naming.** User-facing name is **Locto** (committed). The repository, Xcode scheme, bundle identifier (`com.talkcoach.app`), and source code retain `TalkCoach` for v1 — renaming the codebase is non-trivial and deferred until after v1 launch. Every user-visible string (About panel, Info.plist usage descriptions, menu items, Settings titles, App Store metadata) uses Locto. Internal artifacts (build settings, source identifiers, signing) use TalkCoach.

2. **Visual adoption mode — option (b), selective.** The architect surfaced three reads (a) wholesale replacement, (b) selective adoption, (c) side-by-side. User chose (b): adopt brand color, type, voice, motion principles, and state ink colors from Locto. Keep our locked widget shell decisions: 144 × 144 pt size (Session 014), Liquid Glass material with hover saturation shift (Session 014), persistent visibility + "Listening…" placeholder + dismissal flow (Session 013). Locto's solid-pastel-gradient 320pt approach is rejected; the existing Liquid Glass + state-ink-tint approach stays.

3. **Filler tracking — deferred to v2.0.** Market discovery surfaced monologue detection as the higher-priority feedback signal. User-facing summary: "the filling-words became less priority than monologue talking. Push it as feature for v2.0 when we will develop complete dashboards with rich analysis and recommendations." All filler work removed from v1: `FillerDetector` (M4.2), filler dictionary editor in Settings (M4.3), filler bars on widget (M5.5), filler editor UI in M6.2 polish, the `fillerCounts` SwiftData field, the `fillerDict` UserDefaults key (registered in M1.4 but no longer read or written), the seeded EN/RU/ES dictionaries, the FM2 "filler counts must be obvious-case correct" criterion, the "filler word list below" widget content. Total Phase 4 + 5 + 6 reduction: 14h.

4. **Repeated-phrase detection — also deferred to v2.0.** Architect proposed grouping with fillers (sibling verbal-pattern critique, same in-meeting risk shape, same v2.0-dashboard fit). User confirmed. M4.4 `RepeatedPhraseDetector` removed; `repeatedPhrases` SwiftData field removed. The algorithm sketch (sliding 4-word window over finalized tokens detecting 2–4 word phrase repetition within ~5s) is preserved in `03_ARCHITECTURE.md` §6 alongside the FillerDetector sketch for v2.0 to inherit.

5. **Monologue detection stays as v1.x feature.** Algorithm designed Session 013, blocked on Spike #11 (parked) for VAD source validation. Now elevated to second-pillar v1 feature alongside WPM — when monologue lands, the v1 product proposition becomes "WPM + monologue" rather than "WPM + fillers". The success criteria in `02_PRODUCT_SPEC.md` were updated accordingly: question 1 was "I forgot the app was running, but my filler use went down" → became "I forgot the app was running, but I noticed when I drifted into a monologue."

### Doc revisions in this session

The architect performed comprehensive doc edits across six project files:

- **`02_PRODUCT_SPEC.md`** — title rebranded to Locto with naming-policy note; tagline changed to "Speak in your sweet spot"; FM1 "no flashing" lines reframed away from filler-specific contexts to general state-change/monologue-level visuals; FM2 filler-correctness criterion replaced with monologue-correctness criterion; widget display section rewritten (state labels in sentence case, pace bar with caret, no filler list, design-doc references); speaking metrics section narrowed to WPM + monologue; "Filler-word dictionary" section replaced with deferral note; session storage schema fields `fillerCounts` and `repeatedPhrases` removed; expanded stats window section updated (filler frequency chart out, monologue timeline in); non-goals section expanded with v2.0 filler/repeated-phrase entries; UX defaults table dropped filler dictionary row; success metrics question 1 rewritten around monologue.

- **`03_ARCHITECTURE.md`** — ASCII module diagram updated (`Analyzer (WPM + monologue)`); Analyzer section rewritten (FillerDetector and RepeatedPhraseDetector replaced with deferral block, MonologueDetector promoted as v1.x sub-component with Spike #11 dependency); SessionStore record types updated (FillerCountRecord and RepeatedPhraseRecord removed from boundary surface; v1 surface is SessionRecord, WPMSampleRecord, MonologueEventRecord at v1.x); FloatingPanel section comprehensively rewritten (view model fields trimmed, persistent-visibility lock from Session 013 reaffirmed, hover saturation lock from Session 014 reaffirmed, design references redirected from `design/` to `docs/design/`); data flow ASCII diagram updated; Settings keys reduced from seven to six (fillerDict removed); Settings window sections updated (Filler Words pane removed); Info.plist usage descriptions rebranded to Locto and trimmed of filler references; Design Reference section rewritten with precedence rules and a clear "what's superseded" callout for the prior `design/` directory.

- **`04_BACKLOG.md`** — Phase 4 trimmed to M4.1, M4.6, M4.7 only (was 17h, now 7h); Phase 5 dropped M5.5 filler bars (was 23h, now 20h); Phase 6 dropped filler editor mention from M6.2 (was 19h, now 18h); Summary table updated with new totals (124–130h → 110–116h); Session 018 scope reduction documented; deferred features section rewritten with v2.0 filler/phrase entries; M1.4 historical row annotated with "fillerDict registered but unused after Session 018".

- **`07_RELEASE_PLAN.md`** — title rebranded to Locto; TL;DR updated (two checkpoints not three, cumulative ~92–98h not ~105–111h); Phase 4 narrative rewritten (drops fillers, drops Checkpoint #3 with rationale); Phase 5 narrative rewritten (Locto-derived visuals, success questions updated to four-question form including monologue); Phase 6 narrative trimmed (drops filler editor, drops "three checkpoints removed" line); cumulative effort table updated; "three feedback checkpoints" section retitled to "two" with Phase 4 checkpoint dropped and rationale captured.

- **`00_COLLABORATION_INSTRUCTIONS.md`** — revision note updated to Session 018; file ownership table extended with `docs/design/` row indicating Claude (this conversation) is the editor for brand/design-related decisions and Claude + Claude Code agent are readers during widget-related modules.

- **New `docs/design/` folder** — three files produced:
  - `01-design-spec.md` — implementation-facing behavioral companion to the brand HTML. Includes a Provenance section explicitly enumerating the project-specific overrides (144pt size, Liquid Glass material, persistent visibility, monologue indicator extension, filler-component removal). Includes a Phase 5 testing checklist for self-validation against FM1.
  - `02-brand-guidelines.html` — adapted from the uploaded Locto brand HTML. Adds a "Scope & precedence" section at the top explaining what this doc wins on and what it doesn't. Annotates the three-state widget caption with the project-specific size/material/state-label overrides. Marks Filler-word strokes, Coach note, and Tab bar component sections with "deferred to v2.0" banners. Updates Assets section to point at `docs/design/` for SVG files.
  - `README.md` — folder orientation, naming policy, precedence rules, what's superseded, adoption history.

### Architectural decisions locked

1. **User-facing brand name: Locto.** Repo / scheme / bundle ID stays TalkCoach for v1. Codebase rename deferred until after v1 launch when there's no in-flight feature pressure.

2. **Visual reference: `docs/design/` package adapted from Locto.** Authoritative for visual identity (palette, type, voice, motion) and brand-component visual specs. NOT authoritative for content scope (`02_PRODUCT_SPEC.md` wins) or technical architecture (`03_ARCHITECTURE.md` wins).

3. **Filler tracking deferred to v2.0.** Removed from widget, data layer, dashboard, dictionary, multilingual seed lists, Settings UI, and the M4.x test plan. Algorithm sketches preserved in arch doc §6 for v2.0 to inherit. `MigrationPlanV2` becomes the SwiftData migration entry-point that adds back `fillerCounts` and `repeatedPhrases` schema fields.

4. **Repeated-phrase detection deferred to v2.0.** Sibling of fillers, same rationale, same v2.0 reactivation path.

5. **Monologue detection elevated to second-pillar v1 feature.** v1 product proposition becomes "WPM + monologue", not "WPM + fillers". Spike #11 (VAD source validation) is the gate — parked, must pass before M4.5 implementation. v1.x feature alongside dark mode and acoustic non-word detection.

6. **Widget shell from Session 014 + 013 preserved.** 144pt size, Liquid Glass material, hover saturation shift, persistent visibility with "Listening…" placeholder, dismissal flow. The Locto reference's 320pt + solid pastel gradient + show-on-first-token approach is rejected.

7. **Phase 4 checkpoint (post-session UNUserNotificationCenter notification) dropped.** Earlier plan had a metric-summary notification ("32 min · 152 WPM · 4 'um'") as Checkpoint #3 in Phase 4. With fillers gone, the only Phase 4 metric is WPM, which is straightforward to spot-check by querying SwiftData directly. The notification surface added complexity without proportional risk-reduction value at the new scope.

### Procedural notes

1. **Architect-conversation-per-Phase split is paying off.** Phase 2's lessons (M2.1 + M2.3 + this brand revision) are accumulating in this conversation's context without pollution. Future architectural questions in M2.5 / M2.6 / M2.7 inherit all this. Locked as the working cadence.

2. **External design-package reconciliation cost ~5 turns.** The Locto package was generous in scope (full product spec, data model, build phases, open questions) but assumed from-scratch architecture. The architect spent four reconciliation turns surfacing the four binary decisions (naming, visual adoption mode, filler scope, repeated-phrase scope) before producing files. This cost is fundamental to integrating any external design effort into a locked architecture; the process worked as designed (one question per turn, decisions confirmed, then files produced).

3. **Doc edits at this scope took two architect turns.** First turn covered `02_PRODUCT_SPEC.md`, `03_ARCHITECTURE.md`, `04_BACKLOG.md` plus partial `07_RELEASE_PLAN.md` (TL;DR + Phase 4) before tool-call budget ran out. Second turn finished release plan, produced the four new files (`docs/design/01`, `docs/design/02`, `docs/design/README.md`, updated `00_COLLABORATION_INSTRUCTIONS.md`), and journaled. Future scope-change-style sessions should plan two turns from the start rather than attempting one-shot.

### Ups

- Reconciliation walked cleanly through four binary decisions without doubling back. Each one was sharper than the last because the prior decisions narrowed the surface.
- The Locto package's voice/tone rules ("direct, present, calm; specific verbs not coaching jargon; do/don't examples") immediately upgraded our user-facing copy. Pure win — no overrides needed.
- Monologue detection's elevation to second-pillar feature gives v1 a clearer product proposition. "WPM + filler counts" was a 'metrics-on-screen' framing; "WPM + monologue" is a 'feedback during the moment that matters' framing — much closer to FM3's "minimal setup, ambient feedback" promise.
- The `docs/design/` folder cleanly separates "visual reference" from "locked architecture", which the prior `design/` directory at project root had been muddling. Architecture refs pointed at it for visuals AND included scope/architecture bleed-through that needed superseding paragraphs in `03_ARCHITECTURE.md`. The new structure has zero such bleed-through.

### Downs

- Architect's first read of the uploaded Locto package missed the magnitude of the visual delta versus our locked widget shell. Initial framing assumed "trim to brand-and-tone reference" before noticing 320pt vs 144pt, solid gradients vs Liquid Glass, show-on-first-token vs persistent-visibility, filler strokes vs monologue. Caught on the third turn when the architect asked the visual-adoption-mode question explicitly. Sharper first read would have asked that question on turn one.
- The Phase 4 checkpoint dropping is a real loss of risk-reduction signal even at the reduced scope. WPM-only Phase 4 is still worth a sanity check before Phase 5 sinks ~20h into widget work; the checkpoint mechanism just doesn't earn its keep at one metric. A lighter-weight alternative (e.g., a debug menu item that prints session metrics) might be worth proposing before M4.7 lands.
- File ownership table in `00_COLLABORATION_INSTRUCTIONS.md` was simply outgrown — it had room for `docs/design/` but the existing rows still say "three checkpoints" in the release plan row. Updated; flag to keep audit-grepping these tables on every scope-change.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry
- `02_PRODUCT_SPEC.md` — Locto rebrand + filler/repeated-phrase deferral + state-label sentence-case + monologue elevation + tagline + design-doc references
- `03_ARCHITECTURE.md` — Analyzer rewritten + FloatingPanel rewritten + Settings keys trimmed + Info.plist rebranded + Design reference rewritten with precedence rules
- `04_BACKLOG.md` — Phase 4 trimmed to 7h + Phase 5 trimmed to 20h + Phase 6 trimmed to 18h + Summary updated + deferred-features section restructured
- `07_RELEASE_PLAN.md` — Locto rebrand + Phase 4 narrative rewritten + Phase 5 narrative rewritten + checkpoints summary down to two + cumulative effort table updated
- `00_COLLABORATION_INSTRUCTIONS.md` — file ownership table extended with `docs/design/` row + revision note
- **New:** `docs/design/01-design-spec.md`, `docs/design/02-brand-guidelines.html`, `docs/design/README.md` (Locto package adapted with project overrides surfaced inline)

### Next session

- M2.5 (`FloatingPanel`): SwiftUI widget bound to `SessionCoordinator.$state`. Per Phase 2 dynamic-placeholder checkpoint in `07_RELEASE_PLAN.md`. Now visually grounded by `docs/design/01-design-spec.md` and `docs/design/02-brand-guidelines.html`. The placeholder widget at Phase 2 end uses Liquid Glass shell with brand state inks at low alpha; final WPM display lands in Phase 5.
- **M2.5 prompt tightenings carry forward from M2.3:**
  - Smoke-gate procedure defaults to Xcode's debug area, not Console.app
  - Sub-agent verbatim-with-disposition reporting format is the standard
  - First-review architect discipline: march the Phase 3 self-review checklist item-by-item
  - **New:** prompt references `docs/design/01-design-spec.md` and `docs/design/02-brand-guidelines.html` for visual specifics; agent reads these alongside the architecture doc during Phase 1 plan exploration
  - **New:** the M2.5 placeholder widget is the first surface where the Locto brand and design-doc overrides become testable in production code; explicit verification that the widget uses brand teal `#0F6E56` only where appropriate (NOT as a state signal — state signal is slate-blue / sage-green / warm-coral inks; brand teal is reserved for the menu bar mark and any "About" / chrome surface)

---


## Session 017 — 2026-05-05 — M2.3 SessionCoordinator skeleton shipped: hybrid consumer interface, immediate-termination pause, sub-agent catches termination cleanup

**Format:** Architect-driven module sequencing with the Claude Code agent. M2.3 from green-field to tagged complete in one architect session. 15 new tests added (103 total in repo). Three commits in the M2.3 series: `f074a4b` failing tests (lint clean), `1f16431` implementation, `180c0b2` sub-agent review fixes.

### What happened

`SessionCoordinator` is the orchestration brain of v1 — it receives `MicMonitor` events (M2.1), gates session creation on `coachingEnabled` (M1.4 `SettingsStore`), holds in-memory session state, and exposes that state to two future consumers: M2.5 `FloatingPanel` (SwiftUI widget) and M2.7 `SessionStore` (SwiftData persistence). M2.3 is the skeleton — lifecycle and state management. It does NOT yet integrate `AudioPipeline`, `TranscriptionEngine`, `Analyzer`, `LanguageDetector`, or the widget itself.

Plan came back high-quality on the first pass. The agent picked the hybrid consumer interface (`@Published var state: SessionState` for SwiftUI binding plus `onSessionEnded` callback registration for one-shot consumers) with clear justification for both consumer needs. The agent recommended pause-mid-session option (a) — immediate termination — with reasoning tied to FM3 ("controls do what they say") and the menu copy ("Pause Coaching", not "Pause After This Session"). Architect approved with two implementation tightenings: annotate the `onSessionEnded` closure type as `@MainActor` to surface the contract in the type system, and rename `testResumeWhileMicStillActiveStartsNewSession` to `…DoesNotStartNewSession` since the test body asserts no new session starts (correct behavior — `MicMonitor` won't re-fire `micActivated()` until a real deactivation). Both tightenings landed.

Phase 2 had a recovery moment that taught a lesson on the architect side. After the failing-tests run, the Xcode chat panel showed `(lldb)` and "Responding…" while the test runner status said `Testing TalkCoachTests`. The architect read this as a deadlock and proposed a debugger-recovery sequence. It was nothing of the kind — the test process had hit a clean `Fatal error: Index out of range` at `endedSessions[0]` on an empty array (because the empty stub never delivered the `onSessionEnded` callback), and lldb was simply waiting at the breakpoint while the chat panel rendered the test results stream. The agent caught the misdiagnosis cleanly: traced the call chain (each `simulateIsRunningChange()` → one `Task { @MainActor in }` hop → one `await Task.yield()` drain), confirmed the test infrastructure was correct, and noted that the failures were the expected stub-method shape. Architect's pattern-match to "deadlock" was wrong; the correct first question on "stuck for hours" is "what does the test runner status say and what's at the breakpoint" before reaching for fork-the-debugger remedies. Lesson captured.

Implementation reported back with three commits, 103/103 tests passing, lint clean on every commit including the failing-tests commit (Session 016 procedural tightening confirmed working). Sub-agent returned a 13-note breakdown: 8 PASS, 2 ADDRESSED in commit `180c0b2` (missing `testDuplicateMicActivatedWhileActiveIsNoOp` defensive test, missing `applicationWillTerminate` calling `sessionCoordinator.stop()`), 3 ACCEPTED with rationale (unbounded handler array but O(1) in practice with M2.7 as sole consumer; Combine `.sink` despite project async/await preference because `SettingsStore.$coachingEnabled` is already `@Published`; `FakeCoreAudioDeviceProvider` duplicated between `MicMonitorTests` and `SessionCoordinatorTests` — extraction deferred until a third consumer appears). The verbatim-with-disposition format from Session 016's tightening is working as designed: each note traceable to a concrete decision rather than buried in a one-line summary.

Architect's first review of the final report missed several Definition-of-Done items the prompt required (Phase 3 self-review checklist item-by-item, AC quotation, swiftlint status per commit, sub-agent verbatim notes). Caught and corrected with a follow-up prompt; the agent's complete second report had everything. Sharper architect read on first pass would have flagged it; pattern noted for M2.5.

Manual smoke gate had a Console.app misadventure on the user side. The pasted filter `subsystem:com.talkcoach.app category:session` parsed only the subsystem chip; the `category:session` part dropped. Worse, macOS Console suppresses `.debug` and `.info` log levels by default — needs Action menu → Include Debug Messages and Include Info Messages to be toggled on, otherwise the panel shows "0 messages" even with the right filter. Architect redirected to Xcode's debug area, which shows `os.Logger` output unfiltered without setup. User had used Xcode's debug area for M2.1 successfully; should have been the default smoke-gate path from the start. M2.5 prompt and forward will default to Xcode's debug area, mention Console.app only as the secondary path with the Action-menu toggle warning.

### Architectural decisions locked

1. **Hybrid consumer interface for `SessionCoordinator`.** `@Published var state: SessionState` for SwiftUI binding (M2.5 widget consumes via `@ObservedObject` / `@EnvironmentObject` natively, no adapter layer). Plus `func onSessionEnded(_ handler: @escaping @MainActor (EndedSession) -> Void)` callback registration for one-shot consumers (M2.7 persistence registers a single handler at app startup). Each consumer gets the shape that fits its need; neither contorts to accommodate the other. The `@MainActor` annotation on the closure type surfaces the threading contract explicitly under Swift 6.

2. **State types.** `SessionState: Equatable { idle, active(SessionContext) }`. `SessionContext: Equatable { id: UUID, startedAt: Date }` — minimal by design; Phase 3+ modules add fields when wired (`language: Locale` from `LanguageDetector`, etc). `EndedSession: Equatable { id, startedAt, endedAt }` — the value delivered to `onSessionEnded` handlers, captures `endedAt` which the active-session type does not. Session UUIDs are generated fresh at each `micActivated()`; M2.7 will use them as SwiftData primary keys.

3. **Pause-mid-session: option (a), immediate termination.** When `coachingEnabled` transitions `true → false` while state is `.active`, the active session ends immediately — state transitions to `.idle`, `EndedSession` delivered to handlers synchronously in the same MainActor turn, log line `Coaching disabled mid-session — ending active session`. Resume (`false → true`) does NOT auto-start a session even if mic is still active; only the next `micActivated()` from `MicMonitor` starts one. Smoke-gate verified end-to-end with session `6D4EE4EA` ending at duration 7.3s on pause-click while Voice Memos was still recording, with the HAL deactivation event arriving later as a no-op (already idle).

4. **Combine subscription to `SettingsStore.$coachingEnabled`** (`.dropFirst().sink { [weak self] in ... }`). Justified deviation from the project's general "prefer async/await over Combine" preference: `SettingsStore` is already an `ObservableObject` with `@Published` properties; `.sink` is the idiomatic one-liner for observing them; wrapping in `AsyncStream` adds complexity for no benefit. `.dropFirst()` skips the initial-value emission to avoid spurious actions at app launch. `[weak self]` closes the retain-cycle question.

5. **Same-MainActor-turn delivery contract.** `endCurrentSession()` builds the `EndedSession`, transitions state, and delivers all handlers synchronously — no extra `Task { @MainActor in }` hop. This is the contract tests rely on; rapid-toggle and pause-mid-session scenarios depend on it for deterministic event ordering. Architect's option-(c) recommendation from the deadlock-misdiagnosis recovery prompt landed as designed.

6. **Lifecycle ownership.** `AppDelegate` owns `SessionCoordinator` (Convention 7 — accessed via `AppDelegate.current?.sessionCoordinator`). `SessionCoordinator` owns `MicMonitor` strongly; `MicMonitor` holds `weak` ref back via `MicMonitorDelegate`. `applicationDidFinishLaunching` calls `start()`; `applicationWillTerminate` calls `stop()` (sub-agent catch in `180c0b2`, smoke-gate verified at Cmd+Q with `SessionCoordinator stopping` → `MicMonitor stopping`). Idempotency mirrors M2.1.

7. **Defensive duplicate-activation guard at the coordinator level.** `micActivated()` while already `.active` is a no-op (in addition to `MicMonitor`'s own deduplication). Sub-agent caught the missing test; added in `180c0b2`.

### Procedural lessons

1. **"Stuck for hours" diagnosis order.** When an agent appears stuck, the first question is "what does the test runner status say and what's at the breakpoint" — not "is this a deadlock." The (lldb) prompt + spinning chat panel pattern looked like a deadlock to the architect; was actually a clean `Fatal error` trap waiting at a debugger breakpoint with the chat panel still rendering test result streams. Pattern-matching to the wrong remedy cost cycles. Captured for future reference.

2. **Console.app is not the right default for `os.Logger` smoke gates.** Two failure modes: (a) macOS suppresses `.debug` and `.info` log levels by default — needs Action menu toggles to surface them; (b) the structured filter syntax `subsystem:X category:Y` parses inconsistently when pasted, often only the first key:value becomes a chip. Xcode's debug area shows `os.Logger` output unfiltered with zero setup, and the user had already used it successfully for M2.1. M2.5 prompt and forward default to Xcode's debug area; mention Console.app as the secondary path with the Action-menu toggle warning if needed.

3. **First-review architect discipline.** Architect's first review of the final status report missed several Definition-of-Done items the prompt required. The agent's structural code-presence section masquerading as the self-review checklist was not a strict 14-item march, and the architect didn't catch it on first read. Caught on the follow-up prompt that asked for the missing items explicitly. Sharper first read needed; the prompt's checklist is the spec, march it item-by-item.

4. **Verbatim sub-agent reporting format works.** The 13-note breakdown (8 PASS, 2 ADDRESSED with commit refs, 3 ACCEPTED with rationale paragraphs) is exactly the shape Session 016's tightening was after. Each note is traceable; nothing buried in a one-line summary. Lock as the standard format for all future high-risk modules.

5. **Architect-conversation-per-Phase, agent-session-per-module split (locked).** This conversation continues through M2.5 / M2.6 / M2.7. Agent gets a fresh implementation slate per module; architect keeps the Phase 1 conventions and the M2.x lessons hot in context across the whole phase. Captured as the working cadence.

### Module summary

| Module | Goal | Outcome | Tag |
|---|---|---|---|
| **M2.3** | `SessionCoordinator` skeleton: hybrid consumer interface, gate on `coachingEnabled`, immediate-termination pause-mid-session, in-memory session state, lifecycle ownership of `MicMonitor` | 15 new tests (103 total in repo), sub-agent review pass with 13 notes (8 PASS / 2 ADDRESSED / 3 ACCEPTED), 14-step smoke gate plus Cmd+Q termination verified end-to-end | `m2.3-complete` (local on `180c0b2`) |

### Effort accounting

Backlog estimate for M2.3 was 3h. Agent work matched roughly. Architect time was higher than M2.1 — the false-deadlock diagnosis and the Console.app smoke-gate detour cost cycles. Cumulative Phase 2 progress: M2.1 + M2.3 done (~7h estimated), M2.5 / M2.6 / M2.7 remaining (~7h estimated).

### Ups

- Hybrid consumer interface choice was clean on first plan pass. M2.5 and M2.7 needs both accommodated without contortion.
- Pause-mid-session option (a) confirmed end-to-end via smoke gate, with AC4 (idle-deactivation no-op) confirmed as a side effect.
- Sub-agent's verbatim-with-disposition format caught two real issues (`applicationWillTerminate` cleanup, defensive duplicate-activation test) that a one-line summary would have missed.
- 103 tests, lint clean on every commit including the failing-tests commit. Session 016's "lint-clean tests on the failing-tests commit itself" rule landed as intended.
- Architect-conversation-per-Phase, agent-session-per-module cadence is working — Phase 2 lessons compound across modules without diluting the implementation slate.

### Downs

- Architect's false-deadlock diagnosis cost a round trip. The (lldb) + spinning chat looked like a deadlock; was a normal Fatal error trap at a breakpoint. Pattern-match to wrong remedy.
- Console.app smoke-gate path was a dead end for the user (DEBUG-level suppression by default, structured filter parsing inconsistency). Xcode's debug area should have been the default from the start.
- Architect's first read of the final status missed several Definition-of-Done items. Caught on follow-up but a sharper first pass would have closed faster.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry
- `04_BACKLOG.md` — M2.3 marked `✅ tag m2.3-complete (Session 017)`
- `03_ARCHITECTURE.md` — §2 `SessionCoordinator` rewritten with M2.3 locked design (hybrid consumer interface, state types, pause-mid-session option a, Combine subscription rationale, same-MainActor-turn delivery contract, lifecycle ownership) and a clear skeleton-vs-full-lifecycle distinction so M3.x / M2.5 / M2.7 modules can see what's done vs deferred

### Next session

- M2.5 (`FloatingPanel` widget): SwiftUI widget bound to `SessionCoordinator.$state` for visibility (active = visible, idle = hidden). Per Phase 2 dynamic placeholder checkpoint in `07_RELEASE_PLAN.md`: shows session timer (`Date.now - startedAt`) and a "speaking detected" placeholder indicator (real audio wiring deferred to M3.1). Subsumes the M2.3 debug scaffolding in `TalkCoachApp.swift` (the `#if DEBUG` Combine sink that logs state transitions — `// MARK:` removal marker already names M2.5 as the migration target). Estimate 4h. Depends on M2.3 (now done).
- **M2.5 prompt tightenings to bake in:**
  - Smoke-gate procedure defaults to Xcode's debug area, not Console.app
  - Sub-agent verbatim-with-disposition reporting format is the standard (lock; do not relitigate)
  - First-review architect discipline: march the Phase 3 self-review checklist item-by-item; do not accept structural code-presence reviews as a substitute

---

## Session 016 — 2026-05-05 — M2.1 MicMonitor shipped: Core Audio HAL listener, delegate output, log-and-continue HAL robustness

**Format:** Architect-driven module sequencing with the Claude Code agent. M2.1 from green-field to tagged complete in one architect session, ~3 round trips between architect and agent. 19 tests added (18 initial + 1 follow-up), 88 total in repo. Zero lint violations.

### What happened

`MicMonitor` is the first Phase 2 module and the first behavior module of v1 — when this fires, the app stops being plumbing and starts being a product. It listens to Core Audio HAL property changes on the default input device and emits `micActivated()` / `micDeactivated()` to a delegate when `kAudioDevicePropertyDeviceIsRunningSomewhere` flips, with re-attachment when `kAudioHardwarePropertyDefaultInputDevice` changes.

Plan came back clean on the first pass. The agent picked the delegate output surface (over `AsyncStream<MicState>` / `@Published`), correctly noting that M2.3's `SessionCoordinator` is a single-consumer state machine that doesn't benefit from a `Task` loop. The plan also surfaced the asymmetric `start()` semantics that the delegate shape forces: when starting with the device already running, emit `micActivated()` synchronously; when starting with the device inactive, emit nothing — there is no "current state" delegate callback in the protocol. The architect approved and tried to attach two follow-ups to the approval ("inactive-start asserts no delegate call", "removal-comment marker on the `TalkCoachApp.swift` debug scaffolding for M2.3 migration"). Plan mode in Xcode's Claude Code drops straight into implementation after approval — there is no window to inject a follow-up message between architect approval and the agent starting to code. The two architect notes were not delivered. Neither was a blocker — the asymmetric test was correct in the agent's implementation, and the migration marker can be added during the M2.3 prompt by `git grep`. Lesson committed: architectural notes belong in the prompt body, not in the approval. The "no edit-notes after approval" rule in `00_COLLABORATION_INSTRUCTIONS.md` exists precisely for this case.

Implementation came back with 87/87 tests passing, lint clean, sub-agent review delivered as "PASS WITH NOTES — 5 minor non-blocking items" without the verbatim notes. Architect required the verbatim quotes plus item-by-item self-review checklist confirmation before approving the tag. Agent re-reported with notes 1, 2, 4, 5 dispositioned as "accepted as known" and note 3 ("no test for `deinit`-without-`stop()` listener cleanup") deferred to M2.3. Architect reversed the deferral: the original prompt's Test Plan listed `testMicMonitorDeinitRemovesListenersIfStillRunning` explicitly, AC8 named it as the verification path, and the `deinit` code lives in `MicMonitor.swift` regardless of who owns the instance later. Agent added the test in follow-up commit `94094fe` (autoreleasepool + drop reference + assert fake's remove-counters), bringing total to 88/88. Tag `m2.1-complete` lives on `94094fe`, local only.

### Architectural decisions locked

1. **Delegate output for `MicMonitor`.** `MicMonitorDelegate` protocol with `@MainActor` `micActivated()` / `micDeactivated()` over `AsyncStream<MicState>` and `@Published`. Reasons: M2.3 is a single-consumer state machine; delegate gives clearer ownership semantics than a `for await` loop; matches the existing project pattern where Phase 1 modules used direct `@MainActor` method calls rather than streams. The architecture doc's pre-Swift-6 sketch ("`micActivated()`, `micDeactivated()` delegate callbacks") thus reads as the locked design, not a placeholder.

2. **Provider injection mirrors `PermissionStatusProvider` (Convention 6).** `CoreAudioDeviceProvider` protocol; `SystemCoreAudioDeviceProvider` (struct, `Sendable`, all methods `nonisolated`) wraps the HAL APIs; `FakeCoreAudioDeviceProvider` (class, `@unchecked Sendable`) stores handler closures and exposes `simulateIsRunningChange()` / `simulateDefaultDeviceChange()` for synchronous test-driven invocation. Listener handles cross the protocol as opaque `AnyObject?` tokens so the production impl can keep its block + queue pair encapsulated in a `ListenerToken` reference type.

3. **`AudioObjectAddPropertyListenerBlock` over `AudioObjectAddPropertyListener`.** Block API + dedicated serial dispatch queue, then `Task { @MainActor in }` hop on the `MicMonitor` side. Avoids the C function-pointer + `Unmanaged.passUnretained` retention pattern. Convention 2 satisfied: the listener-block closures are defined inside `nonisolated` struct methods, so they cannot inherit MainActor isolation. The Spike #4 runtime-crash analog (`_dispatch_assert_queue_fail`) does not occur.

4. **Asymmetric `start()` and silent `stop()`.** `start()` synchronously emits `micActivated()` if the default device is already running at start time (handles the app-launched-during-Zoom case); emits nothing if inactive. `stop()` does not emit a final `micDeactivated()` — the caller chose to stop. Same-value HAL notifications are deduplicated via `lastKnownRunningState`. Both `start()` and `stop()` are idempotent.

5. **Log-and-continue on HAL listener removal failure.** When the default input device changes mid-session, the production provider's `removeIsRunningListener` call against the old device ID can fail if the device no longer exists. The production impl logs the `OSStatus` and continues. State remains consistent because the `MicMonitor` already has the new device's listener attached by the time it tries to detach the old one. Validated end-to-end during the manual smoke gate (see below).

### Smoke-gate finding worth journaling: Zoom aggregate-device churn

S3.2 of the manual smoke gate (Zoom join → device change → Zoom leave) surfaced this sequence:

- App running, Voice Memos active on built-in device 87 → `MicMonitor` reports `micActivated`.
- User joins Zoom → Zoom creates aggregate device 156, default input flips to 156. `MicMonitor` detaches from 87, attaches to 156, emits `micDeactivated` (156 has no client running yet).
- User leaves Zoom → Zoom destroys device 156, default input flips back to 87. `MicMonitor` tries to detach from 156, gets `AudioObjectRemovePropertyListenerBlock: no object with given ID 156` and `Failed to remove IsRunning listener: OSStatus 560947818` (`kAudioHardwareBadObjectError`).
- Provider's log-and-continue path absorbs the error. `MicMonitor` attaches to 87, picks up the active state correctly. Subsequent on/off cycles on 87 work normally.

This is a different flavor of churn than Spike #4 documented. S4 was about `AVAudioEngineConfigurationChange` — the engine stops, you re-prepare and re-tap. At the HAL level, the device itself can vanish out from under the listener handle. The two facts compose for M3.1 (`AudioPipeline`): Zoom can both flip the default input device AND destroy the previous default device, in any order, mid-session. The recovery story for M3.1 needs to handle both signals. Recorded in `03_ARCHITECTURE.md` §1 as an inheritance note for M3.1. Not promoted to a `CLAUDE.md` project-wide convention — one observation, one module's concern; if a second Phase 3 module wants the same log-and-continue posture, we generalize.

### Procedural lessons

1. **Architectural notes belong in the prompt body, not in the approval.** Plan mode in Claude Code drops straight into implementation after approval — there is no window to inject a follow-up. Both notes the architect added to the M2.1 approval (asymmetric-test framing, removal-comment marker) were not delivered. Neither was a blocker, but the rule from `00_COLLABORATION_INSTRUCTIONS.md` ("never send the agent edit-notes, patches, or 'apply these changes to your last plan' instructions") covers exactly this case. Future module prompts must include all such notes in the prompt body before plan mode runs.

2. **SwiftLint-clean tests are a precondition of the failing-tests commit, not a patch landed between TDD commits.** The agent committed failing tests at `e6acf7d`, then noticed a `large_tuple` violation in `makeSUT()`'s tuple return and refactored to instance properties between commits. The refactor was structural — no assertion weakened — but it is a procedural slip. The intent of "no tests modified after the initial commit" is to prevent assertion weakening, and the agent honored that intent. For Phase 2+, prompts will require `swiftlint --strict` to pass on the failing-tests commit itself, so the structural refactor either lands before the first commit or is surfaced explicitly.

3. **Sub-agent verdict requires verbatim notes, not a one-line summary.** Agent's first status report said "PASS WITH NOTES — 5 minor non-blocking items, no blockers." The architect requested the verbatim notes; on reading them, one of the five (no `deinit` test) was actually a coverage gap in the prompt's Test Plan — not a non-blocker. A one-line summary would have shipped that gap. The original prompt's instruction ("quote the sub-agent's verdict") needs to be tightened to "quote each note verbatim with the agent's per-note disposition." Lands in the M2.3 prompt and forward.

### Module summary

| Module | Goal | Outcome | Tag |
|---|---|---|---|
| **M2.1** | `MicMonitor`: Core Audio HAL listener for default-input running state, delegate output, provider injection, deinit cleanup, idempotent start/stop | 19 tests (18 initial + 1 follow-up), 88 total in repo, sub-agent review pass with 5 notes (4 accepted as known, 1 reversed → test added in `94094fe`), Zoom aggregate-device HAL behavior characterized | `m2.1-complete` (local on `94094fe`) |

### Effort accounting

Backlog estimate for M2.1 was 4h. Agent time roughly matched — single Phase 1 plan, single Phase 2 implementation, one follow-up commit. Architect time was substantial: ~3 round trips on plan and self-review tightening, plus the workflow-lesson catch on plan-mode approval timing. The Phase 1 finding (architect-time roughly doubles agent-time elapsed effort) holds for Phase 2's first module.

### Ups

- Plan came back clean on the first pass. The seven Phase 1 conventions reduced derivation churn — the agent applied Convention 6 (provider injection) without prompting beyond the prompt's "mirror `PermissionStatusProvider`" reference.
- Smoke gate caught the Zoom aggregate-device behavior before M3.1. M3.1's recovery posture now has a concrete HAL-level failure mode to design against, not an abstract worry composing only with Spike #4's engine-level signal.
- 88/88 tests, lint clean, sub-agent review pass on first pass after the verbatim-notes follow-up.
- The asymmetric `start()` behavior the agent picked is observably correct in smoke logs — no spurious activation between `MicMonitor starting` and the first real transition in S1's inactive-launch run.

### Downs

- Architect violated the "no edit-notes after approval" rule from `00_COLLABORATION_INSTRUCTIONS.md`. Plan-mode timing made delivery impossible; the rule existed precisely for this case. Neither note was a blocker, but the workflow integrity matters.
- One sub-agent note was incorrectly deferred to M2.3 on first pass and required architect reversal. The prompt's Test Plan explicitly listed `testMicMonitorDeinitRemovesListenersIfStillRunning` and AC8 named it as the verification path — the deferral conflicted with the prompt itself. Caught and corrected, but a sharper agent reading would have flagged the conflict during the first self-review.
- SwiftLint structural refactor of test helper between TDD commits is a procedural slip. Tightening prompt phrasing for M2.3.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry
- `04_BACKLOG.md` — M2.1 marked `✅ done` with `m2.1-complete` tag reference
- `03_ARCHITECTURE.md` — `MicMonitor` description (§1) updated with the locked design (delegate output, provider injection, block API, asymmetric `start()`, silent `stop()`, deduplication, idempotency, log-and-continue posture) and an M3.1 inheritance note for the Zoom aggregate-device HAL composition with Spike #4's `AVAudioEngineConfigurationChange`

### Next session

- M2.3 (`SessionCoordinator` skeleton): receive `MicMonitor` events, manage session state, check `coachingEnabled`. Estimate 3h. Depends on M2.1 (now done). Will own the `MicMonitor` instance going forward — the debug scaffolding currently in `TalkCoachApp.swift` migrates here. M2.3 prompt will require:
  - Verbatim sub-agent notes in the final status, not a one-line summary, with per-note dispositions
  - `swiftlint --strict` clean on the failing-tests commit itself
  - A removal-comment marker pattern for any debug scaffolding so cross-module migrations are trivially identifiable

---


## Session 015 — 2026-05-05 — Phase 1 closed: foundation skeleton shipped, seven architectural conventions established

**Format:** Architect-driven six-module sequencing with the Claude Code agent. Phase 1 begin → Phase 1 close in one wall-clock day of architect time, six tagged module completions, 69 unit tests, zero lint violations.

### What happened

Six Phase 1 modules went from green-field to tagged complete in dependency order: M1.1 → M1.2 → M1.4 → M1.3 → M1.5 → M1.6. Each module followed the standard Plan → Implement → Self-review template from `00_COLLABORATION_INSTRUCTIONS.md`, with TDD red-phase commits before implementation, sub-agent independent reviews on the high-risk modules (M1.5 Storage, M1.6 Core), `swiftlint --strict` gates, and a manual smoke gate on M1.6 specifically (because OS-level permission dialogs can't be unit-tested).

The agent improved markedly across the six modules. Early modules (M1.1, M1.2) needed pushback on missing tests, vague self-reviews, and skipped sub-agent review. Mid-phase modules (M1.4) caught real correctness issues during plan review (incorrect `@Published` analysis on `UserDefaults` external writes). M1.3 had a buried architectural deviation (replaced SwiftUI Window scene with AppKit `NSWindow` via `NSHostingController`) that the architect caught in self-review; the agent's reflex on M1.5 was already to surface architectural decisions explicitly. M1.6's plan was the cleanest of the phase — pre-plan research with cited Apple docs, all conventions applied without prompting, sub-agent verdict referenced in the self-review.

A latent bug introduced in M1.3 surfaced during M1.6 manual smoke: `AppDelegate.current` (the typed accessor for reaching the app delegate from anywhere) was implemented as `NSApp.delegate as? AppDelegate`, which always returned nil because `@NSApplicationDelegateAdaptor` registers SwiftUI's own `SwiftUI.AppDelegate` proxy as `NSApp.delegate`. The cast to `TalkCoach.AppDelegate` therefore failed silently. The first-launch auto-open path used `applicationDidFinishLaunching` (which IS our delegate) so it worked, masking the bug. Both M1.3's `Settings…` menu-bar button and M1.6's `Check Permissions` debug button were silently broken. Caught by manual smoke + diagnostic logs. Fixed by replacing the accessor with a static weak reference captured in `init`. One regression test locks the contract.

### The seven Phase 1 architectural conventions

These are the patterns established across the six modules. All are in code and observable. CLAUDE.md is updated to reference them as project-wide rules; future modules in any phase apply them without rederivation.

1. **Info.plist mechanism (M1.1).** The physical file at `Sources/App/Info.plist` is the single source of truth. `GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_FILE = Sources/App/Info.plist` + zero `INFOPLIST_KEY_*` build settings. New plist keys (usage descriptions, URL schemes, document types) edit the physical file directly. `INFOPLIST_KEY_*` build settings would silently override the file and create a divergence invisible in code review.

2. **Swift 6 strict concurrency convention (M1.2).** The project's build settings include `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. All top-level declarations (free functions, top-level constants, types without explicit isolation) are implicitly `@MainActor`. Patterns: (a) for tests calling into MainActor-isolated code, annotate the test class itself: `@MainActor final class FooTests: XCTestCase`; (b) for pure functions or constants needing both-context callability, mark them explicitly `nonisolated` (or `nonisolated(unsafe)` for `let`s holding non-Sendable types if the value is provably immutable); (c) for `@ModelActor` types, tests stay non-MainActor and use `await` with `async throws` test methods.

3. **AppKit `NSWindow` via `NSHostingController` for LSUIElement Settings (M1.3).** SwiftUI `Window(id:)` + `openWindow` is unreliable in `LSUIElement` apps (`MenuBarExtra`-only apps don't reliably register window scenes). The escape hatch: `NSHostingController(rootView: SettingsView())` wrapped in an `NSWindow` owned by `AppDelegate`. `NSAlert.runModal()` is the correct primitive for app-level alerts (no host window required). The Settings…/About panel are presented from `AppDelegate.current?.openSettings()` and `NSApplication.shared.activate(); NSApplication.shared.orderFrontStandardAboutPanel(nil)` respectively.

4. **`UserDefaults.didChangeNotification` live-sync pattern (M1.4).** Stores backed by `UserDefaults` need to react to external writers (e.g., `@AppStorage` toggles by `MenuBarContent` while a downstream consumer like `SessionCoordinator` reads through `SettingsStore`). Pattern: `NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { ... }` registered in `init`, observer token stored as `nonisolated(unsafe) private var observer: (any NSObjectProtocol)?`, removed in `deinit`. An `isSyncing` guard inside the observer block prevents feedback loops between programmatic writes and notification-triggered reads.

5. **`nonisolated Sendable` record types crossing `@ModelActor` boundaries (M1.5).** SwiftData `@Model` types are non-Sendable and cannot cross actor isolation boundaries. The `SessionStore` API exposes `nonisolated struct Sendable` record types (`SessionRecord`, `WPMSampleRecord`, `FillerCountRecord`, `RepeatedPhraseRecord`) as the public surface. `@Model` instances are constructed inside the `ModelActor` from records on `save()` and converted back to records before crossing out on `fetchAll()` / `fetchByDateRange()`. Production callers (M2.7 session persistence, future v2 StatsWindow) work with value-type records, never `@Model`. The transcript-leak guard test scans both the `@Model` class and the record structs for forbidden field names.

6. **`PermissionStatusProvider` protocol injection (M1.6).** System permission APIs (`AVCaptureDevice.requestAccess`, `SFSpeechRecognizer.requestAuthorization`) show real OS dialogs that cannot be unit-tested. Pattern: define a `PermissionStatusProvider: Sendable` protocol; the production implementation is a struct (`SystemPermissionStatusProvider`, stateless, trivially Sendable) that wraps the real APIs via `withCheckedContinuation`; the test implementation is a class (`FakePermissionStatusProvider`, `@unchecked Sendable`) that records calls and returns configurable values. The pattern generalizes to any system-API-wrapping module — Phase 2's `MicMonitor` and Phase 3's `AudioPipeline` will follow the same shape.

7. **`AppDelegate.current` static-reference pattern (M1.3 + M1.6 fix).** `NSApp.delegate as? AppDelegate` returns nil when `@NSApplicationDelegateAdaptor` is in use, because SwiftUI registers its own `SwiftUI.AppDelegate` proxy. The reliable accessor: `static private(set) weak var current: AppDelegate?` set to `self` in `override init() { super.init(); AppDelegate.current = self }`. Locked by `testAppDelegateCurrentIsSetAfterInit` in `MenuBarTests.swift`. This unblocks any code that needs to reach the AppDelegate from anywhere — settings window opening, alert presentation, future module hooks.

### Module-by-module summary

| Module | Goal | Outcome | Tag |
|---|---|---|---|
| **M1.1** | Xcode project setup, source-tree restructure, entitlements, Info.plist, build settings, Logger, build-health tests | 11 tests, source tree matches `CLAUDE.md` layout, Info.plist mechanism convention established. Sub-agent review pass. | `m1.1-complete` |
| **M1.2** | `MenuBarExtra` with About / Pause-Resume Coaching / Settings… / Quit, `@AppStorage("coachingEnabled")` key contract with M1.4 | 5 tests, manual smoke pass, Swift 6 strict concurrency convention surfaced (`nonisolated` for test-callable top-level declarations) | `m1.2-complete` |
| **M1.4** | `SettingsStore` `@MainActor` `ObservableObject` wrapping injectable `UserDefaults`, seven properties with documented defaults, live-sync via `UserDefaults.didChangeNotification` | 14 tests including external-write live-sync verification, `isSyncing` guard against feedback loops | `m1.4-complete` |
| **M1.3** | Settings window with language picker (50 locales, max-2 selectable, system-locale silent commit on first launch), backend size labels, placeholder Speaking Pace and Filler Words sections | 13 tests, `LocaleRegistry` with 50 entries, AppKit `NSHostingController` window owned by `AppDelegate` (SwiftUI Window scene proved unreliable in LSUIElement context) | `m1.3-complete` |
| **M1.5** | SwiftData `Session` schema (no transcripts, matches spec exactly), `VersionedSchema` with empty `MigrationPlanV1`, `@ModelActor` `SessionStore` with `save` / `fetchAll` / `fetchByDateRange` / `delete`, sandboxed-aware storage path | 14 tests including `testNoTranscriptFieldOnAnyRecordType` covering both `@Model` and record types, sub-agent review pass | `m1.5-complete` |
| **M1.6** | `PermissionManager` with mic-first / speech-second flow, `NSAlert` denied path with Open System Settings deep link, `PermissionStatusProvider` injection for testability, `#if DEBUG`-guarded smoke menu item | 12 tests + manual three-run smoke verified (granted, denied/restored), sub-agent review pass, `AppDelegate.current` SwiftUI-proxy bug discovered and fixed | `m1.6-complete` |

Total: **69 tests passing, 0 violations across 19+ files, 6 module-completion tags pushed.**

### Per-module manual smoke gates (and what they caught)

Three of the six modules required manual smoke verification because their behavior depended on OS-level interactions that unit tests with mocked dependencies cannot exercise:

- **M1.2 manual smoke:** confirmed menu bar item appearance, About panel visible in `LSUIElement` context (`NSApplication.shared.activate()` is required), Pause/Resume label flips, Settings… opens an empty placeholder window. Smoke caught nothing — implementation matched plan.
- **M1.3 manual smoke:** confirmed first-launch Settings auto-open with system-locale silent commit (`declaredLocales == ["en_US"]`), repeat launch does not re-open, `Settings…` from menu bar opens on demand, max-2 selection enforced (third row disabled). Smoke confirmed the `.environmentObject` injection path works for both menu bar and AppKit-hosted SwiftUI views.
- **M1.6 manual smoke:** **caught the `AppDelegate.current` SwiftUI-proxy bug.** Three-run flow (fresh grant / denied / restored) executed correctly only after the static-reference fix landed. Smoke also confirmed M1.3's `Settings…` from menu bar had been silently broken since M1.3 ship — first-launch auto-open worked because it used `applicationDidFinishLaunching` directly, but menu-bar-triggered `openSettings()` always failed. M1.6's fix repaired both call sites.

The lesson is durable: every phase that wraps OS-level integrations (audio, speech, permissions, window management, system events) needs a manual smoke gate before tagging. Mocked unit tests verify *logic*; manual smoke verifies *wiring*. Phase 2 (`MicMonitor`) and Phase 3 (`AudioPipeline`, `SpeechAnalyzer`, `ParakeetTranscriberBackend`) will have similar gates — the prompts will require them explicitly.

### Process improvements committed across the phase

- **Module-completion tags.** Starting at M1.3, each module ends with `git tag -a m1.x-complete -m "..."` push. M1.5 and M1.6 each used `git tag -fa` to update the message after follow-up tightening — that's fine when the tag hasn't been consumed by a downstream tag yet. Recovery surface stays clean.
- **Sub-agent independent review** required for `Sources/Storage/` and `Sources/Core/` modules per `CLAUDE.md`'s high-risk list. Performed on M1.5 and M1.6. Caught one minor coverage gap in M1.6 (speech `.restricted` test missing) which the agent added before declaring done.
- **Conventions block in module prompts.** Starting with the M1.4 prompt (delivered after M1.2 closed), each subsequent module's prompt opens with a "Project conventions established in earlier Phase 1 modules" section enumerating the five-then-six-then-seven patterns. Saves the agent from rederiving them and prevents drift. Future-phase prompts continue this — Phase 2's M2.1 prompt will open with the seven conventions referenced as project-wide rules in `CLAUDE.md`.
- **Diagnostic loop on smoke failure.** When M1.6 smoke surfaced the `AppDelegate.current` bug, the architect/agent loop was: diagnostic log → identify nil branch → granular log → identify proxy class → write fix → verify smoke. Three round trips, no shotgun debugging. The pattern: never guess; instrument, observe, fix.

### Effort accounting

`04_BACKLOG.md`'s Phase 1 estimate was ~14 hours of focused effort. Actual elapsed time is hard to measure (work happened across an architect-led wall-clock day with frequent task switching and the agent doing the heavy lifting), but the agent's work is consistent with the estimate — six modules, average ~2h each in agent time. The architect's overhead (writing prompts, reviewing plans, reviewing self-reviews, catching deviations, writing close-outs) was substantial — perhaps another ~6h on top — and that overhead is not in the backlog estimate. Worth noting for calendar planning: the 14h backlog number is agent-time; architect-time roughly doubles the elapsed effort.

### Ups

- Phase 1 closed in one architect-led work day. Backlog estimate held.
- Seven architectural conventions surfaced and codified. Phase 2+ inherits a working language for Swift 6 + SwiftUI + AppKit + sandboxing under macOS 26.
- The `AppDelegate.current` bug was caught at Phase 1 close, not in production. Two latent bug surfaces (M1.3's menu-bar Settings…, M1.6's debug menu item) repaired together.
- Agent's reflex matured visibly — by M1.5 / M1.6 the agent was surfacing architectural decisions explicitly, citing Apple docs in pre-plan research, and proposing sub-agent review without prompting. The Phase 1 retrospective they delivered at M1.6 close was substantive, not boilerplate.
- 69 tests passing, lint clean, `phase-1-complete` ready to tag.

### Downs

- The architect spent meaningful time on prompt revisions when the agent's self-reviews skipped Definition-of-Done items (M1.5) or buried architectural deviations (M1.3). The pattern stopped by M1.6 but cost ~3 round trips earlier in the phase. Worth it; the conventions established also prevent the same friction in Phase 2+.
- The `AppDelegate.current` bug was preventable. The architect's M1.3 close-out asked the agent to lock the contract surface with a test (`testSettingsWindowOpenedViaAppDelegateOpenSettings`), which the agent added. But that test calls `openSettings()` directly on a freshly-constructed `AppDelegate` instance — bypassing `AppDelegate.current` and `NSApp.delegate` entirely. The test never exercised the actual production code path (menu-bar click → `AppDelegate.current?.openSettings()`). The lesson: contract tests must exercise the actual call site, not a synthetic shortcut. Recorded as a phase 2 prompt note: every contract test for an "accessor" must call the accessor, not the underlying method directly.
- Manual smoke is irreplaceable for OS integration but it's also slow. Phase 1's three smoke gates each cost ~10 minutes of round-trip time (rebuild, click, observe, report). Phase 3's audio/speech testing will be much heavier — real Zoom call + real recording + real backend behavior. The release plan (`07_RELEASE_PLAN.md`) already accounts for this with the Phase 3 debug HUD checkpoint.

### What changed in the docs this session

- `01_PROJECT_JOURNAL.md` — this entry
- `04_BACKLOG.md` — Phase 1 modules marked `✅ done`; total hour count finalized at ~14h matching estimate
- `03_ARCHITECTURE.md` — `SessionStore` API description updated to reflect `SessionRecord` / `WPMSampleRecord` / `FillerCountRecord` / `RepeatedPhraseRecord` Sendable boundary types; AppDelegate ownership of Settings window noted; `AppDelegate.current` static-reference accessor pattern documented; `UserDefaults.didChangeNotification` live-sync noted on the `SettingsStore` row of the Settings table
- `CLAUDE.md` — new "Project conventions (Phase 1)" section enumerating the seven patterns as Always-do rules; the existing audio-tap-closure note from S4 (Session 008) stays as a separate item

### Next session

- Architect delivers the Phase 1 close-out batch: this journal entry + updated `04_BACKLOG.md` + updated `03_ARCHITECTURE.md` + updated `CLAUDE.md` + `phase-1-complete` tag instruction.
- User starts a fresh conversation for Phase 2. Standard reading-order paste-in (which now includes `07_RELEASE_PLAN.md`) gives the new conversation the seven conventions, the closed-out Phase 1 state, and the Phase 2 entry point.
- Phase 2 entry point: M2.1 (`MicMonitor`) — Core Audio HAL listener for microphone running state. Depends on S4 (passed Session 008). The first true behavior module — clicking play on this is the moment the app stops being plumbing and starts being a product, in scaffolding form.

---

## Session 014 — 2026-05-04 — Path C: docs win on scope, design wins on widget visuals; aggressive v1 scope reduction

**Format:** Architect-driven scope decision. No agent execution. No spike.

### What happened

Reviewed a divergence between two product artifacts in the project: a `/design` package (widget mockups + UX prototype) and the locked `/docs` (this project's source of truth, Sessions 001–013). The two had ended up with materially incompatible product specs — `/design` had a narrower scope and simpler interaction model than `/docs` had grown into through Sessions 008–013. Three reconciliation paths considered:

- **Path A — design wins on everything:** rewrite docs to match `/design`'s smaller scope. Loses bilingual/multilingual support, loses validated architecture, loses Sessions 008–013 work. Rejected.
- **Path B — docs win on everything:** treat `/design` as a sketch, ignore. Preserves all decisions but locks v1 at 201–215h, which the user judged unacceptable for a personal-use app shipped after a 2-week self-trial. Rejected.
- **Path C — docs win on scope, design wins on widget visuals:** keep architecture and language model from docs; adopt design's tighter widget visuals as the M5.x target; aggressively defer non-essential v1 scope to v1.x or v2. **Selected.**

### The seven Session 014 scope decisions

1. **Settings opens automatically on first launch** (no separate onboarding screen). M1.7 (dedicated onboarding picker) dropped. The Settings sheet contains the language picker; on first launch, `hasCompletedOnboarding == false` triggers automatic Settings open. The user picks their declared language(s) there, mic permission grants on first session start. Two user actions total — FM3 still satisfied.
2. **Widget hides on mic-off — no persistent state, no close affordance.** Reverts the Session 013 "persistent + dismissable" decision. Widget is visible during mic-active, fades out after the existing 5s hold on mic-off. No "Listening…" placeholder for silence-during-active-mic, no close-affordance, no confirmation dialog, no panel state machine. Webinars / no-speech meetings are tolerated — the widget will sit there showing no values for the duration. (Without the per-app blocklist, this is the trade-off; see decision 6.)
3. **Menu bar dropdown: About, Pause Coaching, Settings…, Quit.** Dropped from the dropdown: Open Stats… (Phase 6 → v2), language-override submenu (M7.2 → v2). The Coaching ON/OFF toggle is reframed as "Pause Coaching" — when paused, `MicMonitor` activations don't trigger sessions until the user un-pauses. `MenuBarUI` becomes a 4-item static menu.
4. **Multi-language stays (1–2 from ~50 locales). Settings has download-confirmation prompts before any model fetch** (Apple ~150 MB, Parakeet ~1.2 GB). Replaces the Session 013 "silent download with widget toast" design — the user opts in to the cost at the moment of language selection in Settings. M3.6 reorients around in-Settings download flow with progress UI rather than widget toasts.
5. **Per-language filler dictionary editable in Settings** (M4.3). No scope change — already in v1 plan. Confirmed.
6. **Deferred scope:**
   - **`MonologueDetector` and dependents → v1.x.** M4.5 (detector), M4.5a (Silero contingent), M5.6 (widget rendering), M7.4 presentation-mode toggle, S11 (VAD-source spike). All preserved as v1.x specs in the relevant docs — no rework needed when v1.x kicks off.
   - **Per-app blocklist → v2.** M2.2 (activating-app identification, S1 spike's target consumer) and M2.4 (blocklist UI) deferred. Without the blocklist, Voice Memos / dictation / and similar mic-using apps will trigger the widget. Acceptable for personal-use v1 (the user can manually pause via menu bar). S1 (P2) becomes v2-bound.
   - **StatsWindow / history charts → v2.** Entire Phase 6 (M6.1–M6.5) deferred. `SessionStore` still persists session metrics in v1 (forward-compat — when v2 ships StatsWindow, historical data is already there). Stats data is collected but not displayed in v1.
   - **Hotkey (Cmd+Shift+M) → v2.** M7.1 deferred. Pause Coaching via menu bar replaces it.
   - **Localized UI strings → v1.x.** M7.9 deferred. App ships English-only UI. Transcription still runs in declared languages — only the chrome (Settings labels, menu items) is English-only.
   - **Manual language override in menu bar → v2.** M7.2 deferred (implicit from the menu-bar simplification in decision 3).
7. **v1 estimate: 201–215h → ~121–129h** (~40% reduction).

### What v1 still includes

- **Phase 0:** all spikes that already passed (S2, S4, S6, S7, S8, S10) — no rework. S1 and S11 deferred (see decision 6).
- **Phase 1 (foundation, ~11h):** skeleton app, `MenuBarExtra` skeleton, empty Settings, SwiftData schema, permissions, plus first-launch Settings auto-open trigger. M1.7 onboarding picker dropped — its work folds into M1.4 (Settings + first-launch behavior).
- **Phase 2 (mic + lifecycle, simplified, ~15h):** `MicMonitor`, `SessionCoordinator`, simplified `FloatingPanel` (visible-during-mic-active, no state machine, no close affordance), per-display position memory, session persistence.
- **Phase 3 (audio + transcription, ~37–43h):** Architecture Y unchanged. `AudioPipeline`, `LanguageDetector` (script-aware hybrid), `TranscriptionEngine` routing layer, `AppleTranscriberBackend`, `ParakeetTranscriberBackend`, in-Settings model download flow with confirmation, mid-session swap (M3.8) retained.
- **Phase 4 (analyzer, ~17h):** WPM, fillers, repeated phrases, EffectiveSpeakingDuration, session aggregation. **No `MonologueDetector`** — that and its session-schema field move to v1.x.
- **Phase 5 (widget, ~21h):** WPM display, color band, arrow, filler list, drag-to-move, per-display position, fade in/out, Liquid Glass material. **No monologue indicator.** Visual target = `/design` package mockups.
- **Phase 7 (polish, ~23h):** Settings sheet (filler editor, WPM band slider, per-language model download confirmation, Pause Coaching), accessibility audit, dark/light, perf re-pass, notarization. **No hotkey, no localization, no manual language override, no presentation-mode toggle.**

### What v1 still drops if time pressure later

The Phase 7 "drop first" list from `04_BACKLOG.md` is unchanged in spirit but the modules at the top (M7.9 localization, M6.5 stats date filter) are already deferred under decision 6. Remaining time-pressure drops if needed: M3.8 (mid-session language swap → "first session per language is wrong, then sticky"), M5.8 (drag-to-move → pin to top-right), M2.6 (per-display position memory). These remain in v1 by default; re-evaluate at end of Phase 5.

### Why this is defensible

- **Reversibility.** Every deferred feature has a documented v1.x or v2 spec already in place. `MonologueDetector` design from Session 013 is preserved; `StatsWindow` design from Session 001 is preserved; blocklist design is preserved. v1.x kickoff is a pickup, not a re-derivation.
- **The architecture is unchanged.** Architecture Y, language detector, transcription engine, audio pipeline — all unaffected. Spike validation results (S2, S4, S6, S7, S8, S10) all still apply.
- **The shipping bar moved deliberately.** From "ready for public release" to "ready for personal use, 2-week self-validation, then polish for public release." Sessions 001–013 had been creeping toward over-ambitious v1 scope; this rescope acknowledges that and resets the bar.
- **Calendar fits human reality.** At 20h/week, ~6–7 weeks instead of 11–13. At 8h/week, ~4 months instead of 6–7. Both numbers are achievable for a side project.
- **The cuts target features the user can live without for 2 weeks.** Stats data collected but not shown is fine (the user knows roughly how their meetings went). Monologue detection is a power-user feature that the user can self-monitor for two weeks. Blocklist matters mostly for non-meeting mic activations — the personal-use audience of one can manually pause.

### Why "design is visual reference only"

The `/design` package's widget mockups are adopted as the visual target for M5.x — Liquid Glass treatment, layout proportions, typography choices, color band rendering. The `/design` package's *interaction model*, however, is NOT adopted: it had a smaller scope (single language, no language detection, simpler menu bar) that conflicts with the validated architecture. The docs (this project) win on what the app does; `/design` wins on how the widget looks. Codified in `CLAUDE.md` as a top-level rule: "consult `/design` for widget visual specs only; for behavior, scope, and architecture, the canonical source is `/docs`."

### What changed in the docs

- `01_PROJECT_JOURNAL.md` — this entry
- `02_PRODUCT_SPEC.md` — features list shrunk (no monologue, no stats, no blocklist, no hotkey); FM3 reworded for "Settings auto-opens on first launch"; widget persistence section reverted to "fades out 5s after mic-off"; download flow reworded for in-Settings confirmation; non-goals updated with v1.x / v2 labels for monologue, stats, blocklist, hotkey, localization, manual language override
- `03_ARCHITECTURE.md` — `MonologueDetector` removed (subsection moved to a v1.x backlog appendix); `StatsWindow` module removed (kept as a v2 reference); `MenuBarUI` items reduced to About / Pause Coaching / Settings… / Quit; `FloatingPanel` panel state machine removed; `WidgetViewModel` monologue and presentation-state fields removed; data flow simplified; open questions table updated (S11 → deferred to v1.x; S1 → v2)
- `04_BACKLOG.md` — Phase 0: S11 marked ⏸ deferred to v1.x, S1 marked ⏸ deferred to v2. Phase 1: M1.7 removed (folded into M1.4). Phase 2: M2.2, M2.4 removed; M2.5 simplified back to ~5h. Phase 4: M4.5, M4.5a, M4.6 monologue cleanup removed. Phase 5: M5.6 removed. Phase 6: entire phase removed (kept as v2 backlog). Phase 7: M7.1, M7.2, M7.9 removed; M7.4 simplified. Total: ~121–129h.
- `05_SPIKES.md` — S11 status changed to ⏸ deferred to v1.x (spec preserved verbatim). S1 status changed to ⏸ deferred to v2 (spec preserved). S12 still parked for v2. S5 still deferred to v1.x.
- `CLAUDE.md` — `Sources/` tree updated to drop `Stats/`; design-is-visual-only rule added; module list reflects v1 scope only

### Ups

- Decision is reversible — every deferred feature has a documented v1.x or v2 spec already in place. No architecture rework is required when v1.x kicks off.
- The 40% effort reduction lets v1 actually ship in a reasonable calendar window. At 20h/week, ~6–7 weeks instead of 11–13. The previous scope had been quietly drifting toward "9 months of side-project hours," which is a graveyard for personal projects.
- `/design`'s widget visuals are higher fidelity than the abstract criteria the docs had specified for M5.x. The widget work will benefit from concrete mockups instead of designed-in-Xcode iteration.
- The Settings-auto-opens-on-first-launch flow is materially better UX than a dedicated onboarding screen — users associate Settings with "where to configure things," and the first-launch trigger educates them about the Settings location for free. M1.4 absorbs the first-launch trigger logic without much added complexity.

### Downs

- A lot of Sessions 008–013 architect work moves from "v1 deliverable" to "v1.x or v2 backlog item." S11 was specced and never run; M4.5 was carefully designed and never coded; M6.x charts were planned. None of that work is wasted (specs are preserved verbatim), but the user invested architect time on features that are no longer first-priority.
- The v1 user experience without monologue detection or stats is materially less differentiated. The strong v1 hook is now WPM + fillers + repeated phrases. Still a real product, but tighter than the Session 013 vision suggested.
- Settings opening on first launch creates a small UX risk: a user who dismisses Settings without picking a language would land in a no-op state. Need to ensure either (a) Settings cannot be dismissed without picking a language, or (b) the menu bar UI clearly flags "no language picked — open Settings." Resolve in M1.4 / M7.4 design.
- Widget without the close-affordance means users in a webinar / listen-only meeting will see a no-values widget for the duration. Without the blocklist as an out, this is a real friction point for non-speaking meetings. v1 acceptable; v1.x should restore at least a "minimize to dot" affordance.

### Edge-case modules retained in v1 by default

The following were not explicitly named in Session 014 but stay in v1 unless a future session decides otherwise:

- **M3.8 mid-session language re-detection / swap** (4h) — relies on Session 010's validated language-detector design; useful when N=2 declared and the first 5s of detection was wrong. Stays in v1.
- **M5.8 drag-to-move with snap-to-screen-edge** (3h) — quality-of-life that aligns with the `/design` widget polish target. Stays.
- **M2.6 per-display widget position memory** (2h) — small effort, real value for multi-monitor users (which the architect is). Stays.

If time pressure surfaces later, these are the v1 → v1.x deferral candidates in the order listed.

### Next session

- Architect delivers the remaining 4 doc revisions + `CLAUDE.md` update as a batch.
- After that lands, architect writes the Phase 1 prompt for **M1.1 (Xcode project setup)**, structured per the 3-phase Plan → Implement → Self-review template in `00_COLLABORATION_INSTRUCTIONS.md`. M1.1 is the Phase 1 entry point; M1.2 (App lifecycle) follows in a separate prompt.
- Phase 0 is effectively closed for v1: S1 and S11 are both deferred. No spike work blocks Phase 1.

---

## Session 013 — 2026-05-04 — Spike #9 closed ❌ INVALIDATED, shouting detection deferred to v2

**Format:** Claude Code agent execution (Spike #9 Phases A–C), architect-led diagnostic round, product decision.

### What happened

Ran Spike #9 (Adaptive RMS noise-floor for shouting detection) end-to-end with the agent. Built `ShoutingSpike/` harness — pure-function `AdaptiveNoiseFloor` over a dBFS series, `RMSExtractor` over `AVAudioFile`, CLI with the four production-default constants from architecture, deterministic byte-identical re-runs. 12/12 unit tests passed. Sub-agent independent review (7 criteria) passed clean.

User recorded 5 clips per spec: `quiet_normal`, `quiet_shout`, `noisy_normal`, `noisy_shout`, `transition`. Agent processed them and reported "4/5 gates pass with tuned constants p25 + t20" as a pass-with-tuning closure.

**Architect-led diagnostic round revealed two structural problems with that closure.** First, the agent never ran the architecture-locked defaults to establish a baseline — the "tuning" was tested against an unknown reference. Second, even at tuned constants `noisy_shout` still failed, and the agent's "burst shouting 0.3s < 0.5s sustain" diagnosis didn't match the time-series data, which showed a fully sustained 1.5s shout that the algorithm couldn't capture because the threshold was tracking too closely to the floor.

Pulled the time-series CSVs and ran defaults manually. Defaults score 2/5 — false positives on `quiet_normal` (3 events on a clean recording with normal speech) and `transition` (false positive at t=7.30 *during the quiet half before noise even started*). The diagnostic windows showed exactly why: at t=7.2 in `quiet_normal`, floor sat at -62.13 dBFS (= the silences between sentences), threshold was -37.13, and normal speech at -32 was 30 dB above floor — fired an event.

**The 10th percentile of a 5-second buffer doesn't measure room ambience; it measures the silences between words.** Any speech-after-pause looks like a shout. Inverse problem in noisy rooms: the noise fills the silences, floor calibrates to ambient noise, the user's Lombard-raised voice can't clear the +25 dB threshold.

User identified the deeper issue: "in a noisy place I non-intentionally raise my voice to sound clearly — that doesn't mean I shout." This is the Lombard effect, a documented automatic vocal adjustment. RMS dBFS conflates it with shouting because it conflates loudness with aggressiveness. Pitch, spectral tilt, and onset rate-of-change are what actually distinguish them — and none of those are in the architecture's signal model.

**Product decision (user):** remove shouting detection from v1 entirely. Defer to v2 with explicit "intelligent voice analysis" framing.

### Key findings

- **The algorithm is wrong, not the implementation.** Implementation is correct: tests pass, sub-agent review clean, math is right. The signal (RMS dBFS) cannot carry the discrimination needed.
- **Adaptive noise-floor + threshold = loudness detector, not shouting detector.** They're different things. Loudness alone cannot distinguish shouting from speech-after-pause, Lombard compensation, emphasis, or transient artifacts (plosives, laughs).
- **Both failure modes are architecturally fundamental.** The quiet-room failure (silences dominate the percentile) and the noisy-room failure (Lombard fills the headroom) pull tuning in opposite directions. No constant choice resolves both.
- **The spike's primary value is the negative result.** S9 saved us from building a shouting feature that violates FM1 (destructive UI) at first contact with real recordings. That's exactly what spikes are for.

### Spike protocol findings (process improvements logged)

- Two-strike rule needed earlier intervention. Notes-files for plan revisions burned both strikes on workflow churn instead of plan iteration; updated `00_COLLABORATION_INSTRUCTIONS.md` rule 9 / rule 7 mid-session to require complete prompts (inline for short, file for long), never patch-style edits.
- Agent self-review and sub-agent review both reported "pass with tuning" without flagging that defaults were never tested. The validation checklist passed all 7 criteria but those criteria didn't include "compare against the locked architecture defaults." Architect intervention caught it via direct CSV inspection. Lesson for future closure-validation prompts: include a mandatory "show defaults result alongside any tuning" gate in the spike acceptance criteria.

### What changed in the docs

- `02_PRODUCT_SPEC.md` — removed widget shouting icon, "Volume/shouting events" from speaking metrics, `shoutingEvents` field from Session schema; added shouting to non-goals with full diagnosis pointer
- `03_ARCHITECTURE.md` — ASCII diagram updated (`AudioPipeline` no longer says "VAD, RMS"); module 3 (`AudioPipeline`) cut RMS path entirely; module 6 (`Analyzer`) `ShoutingDetector` sub-component removed; data-flow diagram fan-out simplified; module 8 (`FloatingPanel`) `isShouting` removed from view model; open questions table closes S9 ❌; closing summary updated
- `04_BACKLOG.md` — Phase 0 S9 row marked ❌ invalidated (3h actual); M3.3 (RMS calc), M4.5 (ShoutingDetector), M5.6 (Shouting icon) all marked ❌ removed; phase totals adjusted; v1 estimate dropped from 193–203h to 189–199h
- `05_SPIKES.md` — Spike #9 section fully rewritten as a closure record (verdict, root cause, tuning attempts, decision, what v2 needs to revisit)
- `00_COLLABORATION_INSTRUCTIONS.md` — earlier this session, rules 9 and 7 added/refined to enforce complete-prompt delivery and prohibit notes-file patches
- `01_PROJECT_JOURNAL.md` — this entry

### Ups

- The user caught the algorithmic flaw correctly ("it doesn't seem like the right approach to compare to floor; in noisy environments I raise my voice to be clearly heard, that's not shouting"). Stopped what would have been a multi-day rabbit hole of clip-recording iteration.
- Architect intervention via direct CSV diagnostic caught the agent's false-pass closure before docs were polluted. The closure commit `245891e` exists in the repo but the authoritative verdict is the journal/spikes entry, not REPORT.md.
- Cleaner v1 scope. WPM and filler-word coaching are the strong signals; shouting was always the weakest of the three. Cutting it lets v1 ship faster and on more confident ground.
- The `ShoutingSpike/` harness, the 5 recordings, and the time-series CSVs are preserved for v2. A future spike won't start from zero.
- Mid-session protocol fixes (complete-prompt rule, no-notes-files rule) are now codified.

### Downs

- Two strikes burned on workflow churn (notes-files for plan iteration) before the protocol fix landed. Cost ~30 min of round-trips that didn't move the spike forward.
- Sub-agent review missed that defaults were never tested. The criteria list checked algorithmic correctness (percentile interpolation, sustain rule, etc.) but not "is the tuning actually justified relative to the architecture-locked baseline." Future spike acceptance criteria need an explicit "show defaults result" gate.
- Agent's REPORT.md as committed (commit `245891e`) overstates the result. Not amending it — the journal/spikes entry is now authoritative and the harness is throwaway anyway. Future architect should know: when in doubt, the spike file under `05_SPIKES.md` is the closure record, not the agent's REPORT.md.
- Spent budget: 3h actual vs 2h estimate, plus architect time on diagnostic round and doc rewrite. Worth it given the saved v1 effort + saved v1 user-experience risk.

### Next session

- Phase 1 (Foundation) is fully unblocked. Last remaining open spike is S1 (P2, ~3h, identifying activating app for blocklist) — does not gate Phase 1 or Phase 2.1. Could either run S1 next or begin Phase 1 directly with M1.1 (Xcode project setup).
- v2 backlog item (not tracked formally in v1 docs): "Intelligent voice analysis spike" — pitch/F0 + spectral tilt + onset-rate model. Use the `ShoutingSpike/` recordings and any new ones as the corpus. Owner: future-you, post-v1.

### Addendum (same session) — Monologue and trail-off decisions

After S9 closed, an external coaching-features document was reviewed proposing two replacement features: a **monologue detector** (warns when user holds the floor too long) and a **trail-off detector** (warns when voice fades at end of phrase). Worked through both:

**Monologue detector → v1.** User decision. Algorithm: VAD-based state machine (IDLE/SPEAKING/PAUSED) with a 2.5s grace window so natural pauses don't reset the monologue clock; Gong-anchored thresholds (60s soft, 90s warning, 150s urgent). No transcription needed, so privacy story is clean.

**Open architectural risk** — the algorithm needs a frame-level VAD signal. Options: reuse `SpeakingActivityTracker` (free, but token-arrival-based at 1.5s resolution) or add Silero (Core ML, ~1MB, frame-level). Cheaper option goes first, but it might lag too much. Made this Spike #11 (P1, 3h estimate).

**Trail-off detector → v2.** Algorithm captured in `05_SPIKES.md` Spike #12 (parked) so v2 doesn't re-derive. v1 deferral reasons: (1) shares S9's risk shape — per-user-tunable dB threshold could violate FM3; (2) v1 no longer captures RMS (we removed it as part of the S9 close); (3) the conjunction "drop AND silence" is more defensible than S9's "loud = aggressive" mapping, but still needs validation across multiple voices before commit.

**Persistent-widget + close-affordance behavior** (separately, locked earlier in this session): widget stays visible for the full mic-active session even when no speech detected; "Listening…" placeholder; user can dismiss via on-widget close affordance with confirmation prompt; dismissal scoped to current session only, re-appears on next mic activation.

**Doc updates this addendum:**
- `02_PRODUCT_SPEC.md` — monologue indicator added to widget display, monologue events to speaking metrics, `monologueEvents` to Session schema, persistent + close-affordance behavior locked. Trail-off non-goal entry includes full algorithm reference.
- `03_ARCHITECTURE.md` — `MonologueDetector` sub-component spec (state machine, grace window, BT awareness, warning levels, presentation-mode toggle); `WidgetViewModel` extended with monologue + presentation-state fields; `FloatingPanel` panel state machine documented; data-flow diagram updated; S11 added to open architecture questions.
- `04_BACKLOG.md` — S11 added to Phase 0; M2.5 expanded for panel state machine + close affordance (+1h); M4.5 revived as `MonologueDetector` (4h); M4.5a added as Silero contingent (0–4h); M5.6 revived as monologue indicator (3h); M7.4 expanded for presentation-mode toggle (+1h). v1 estimate moves from 189–199h to 201–215h. Net Session 013 effect on v1 effort: roughly +8 to +12h after the S9 −4h savings.
- `05_SPIKES.md` — Spike #11 added (P1, active, full method spec); Spike #12 added (parked v2, full algorithm spec).
- `01_PROJECT_JOURNAL.md` — this addendum.

### Next session (revised by addendum)

- **Phase 1 (Foundation) is unblocked and can begin in parallel with S11.** S11 is P1 but doesn't gate Phase 1 modules — it gates M4.5 inside Phase 4. Recommend starting M1.1 (Xcode project setup) and running S11 in parallel as bandwidth allows.
- S1 (P2) and S11 (P1) are the two open spikes. S12 is parked for v2.
- When M4.5 starts (post-Phase-3), S11 must be closed.

---

## Session 012 — 2026-05-04 — Spike #7 closed CONDITIONAL PASS, Apple SpeechAnalyzer Power Baseline Validated

**Format:** Claude Code agent execution (Spike #7 Phases A–C), sub-agent reviewed.

### What happened
Ran Spike #7 (Apple SpeechAnalyzer power baseline) end-to-end. Built a `PowerSpike/` harness (SPM package, reusing frozen copies of `WPMCalculator`, `SpeakingActivityTracker`, `EMASmoother` from WPMSpike) that runs `AVAudioEngine` + `SpeechAnalyzer` on live mic input, measures CPU%, RSS, and thermal state every 10 seconds, and writes CSV.

**Phase A (harness + smoke test):** Built PowerSpikeCLI with CLI flags (`--isolated-duration`, `--total-duration`, `--sample-interval`, `--output`). Key technical challenge: bridging live mic audio to `SpeechAnalyzer`, which requires `AsyncStream<AnalyzerInput>` with format conversion (48kHz→16kHz via `bestAvailableAudioFormat`). Created BufferRelay pattern for thread-safe buffer handoff. 60s smoke test confirmed harness works: CPU 2.75% on one sample, RSS stable at 23.8 MB.

**Phase B (full 60-minute run):** User ran the harness: 15 min isolated (quiet room, no speech) + 45 min loaded (Zoom solo meeting + iPhone playing conversational podcast next to Mac mic). Podcast drove 45.4 words/sec (including volatile result revisions) — approximately 18× heavier than real-meeting production load.

**Phase C (analysis + report):** Analyzed CSV (360 data rows) and powermetrics output (395 samples). Key finding: SpeechAnalyzer's processing is extremely bursty — 79% of 10s samples read 0.00% CPU, with spikes up to 126.58% (multi-core). The P95 metric from the original spike spec is unsuitable for this workload pattern. Mean CPU (4.18% loaded) is under the 5% FM4 threshold; production estimate is ~2%.

Sub-agent review caught four issues in REPORT.md: off-by-one sample count (90 not 89), silent headroom formula change (mean vs P95 — now explicitly documented with justification), RSS slope ambiguity (loaded-phase vs full-run — both now reported), and a minor word count delta (122,116 not 122,115). All fixed.

### Key findings
- Apple `SpeechAnalyzer` runs entirely on E-Cluster (efficiency cores) — P-Cluster at 0% active residency
- Mean CPU 4.18% under 18× overload; estimated ~2% in production
- RSS 38 MB peak, growing at 16.2 MB/hr (loaded) — projects to 54 MB at 3 hours
- Energy impact ~150 mW marginal — "Low" classification
- Zero AVAudioEngine config changes across 60 minutes including Zoom join/leave
- Thermal state nominal throughout

### Technical findings for production
- `SpeechAnalyzer` requires `AsyncStream<AnalyzerInput>`, not direct AVAudioEngine integration. Must query `bestAvailableAudioFormat(compatibleWith:considering:)` and convert via `AVAudioConverter` if source format differs.
- BufferRelay pattern (deep-copy in tap, drain from separate Task) is the correct architecture for feeding live audio to `SpeechAnalyzer`
- `AnalyzerInput(buffer:)` wraps `AVAudioPCMBuffer` for the async stream
- `analyzer.prepareToAnalyze(in:)` + `analyzer.start(inputSequence:)` for autonomous analysis

### What changed in the docs
- `05_SPIKES.md` — Spike #7 marked ✅ conditional pass with validated outcomes section
- `03_ARCHITECTURE.md` — Open questions table: S7 marked closed, S8 marked closed; Parakeet compute unit note updated (no contention with Apple path); summary paragraph updated
- `04_BACKLOG.md` — S7 marked ✅ conditional pass (4h actual), Phase 0 remaining reduced to ~5h
- `01_PROJECT_JOURNAL.md` — this entry

### Ups
- Mean CPU is comfortably under FM4's 5% threshold even under 18× overload. Production headroom is ~3%.
- Harness worked on first live run after the format-conversion fix. The `bestAvailableAudioFormat` + `AVAudioConverter` pattern is clean and reusable for production `AppleTranscriberBackend`.
- Zero config changes — confirms Spike #4's finding that native Zoom does not trigger `AVAudioEngineConfigurationChange`.
- Sub-agent review caught real issues (headroom formula, sample count) that improved report accuracy.
- 4h actual = 4h estimated. On budget.

### Downs
- Initial attempt crashed (SIGTRAP) because `SpeechAnalyzer` silently requires 16kHz input, not the mic's native 48kHz. No compile-time warning. Fixed by discovering `bestAvailableAudioFormat` via Apple docs.
- The bursty CPU pattern means the original headroom formula (5.0 - P95) is meaningless for this workload. The spike spec's "sustained <5%" criterion was poorly matched to SpeechAnalyzer's batch-processing model. Had to redefine headroom in terms of mean rather than P95, with explicit justification.
- RSS growth at 16.2 MB/hr (loaded) needs monitoring — not a leak concern yet, but could become one in very long sessions (6+ hours).

### Next session
- Phase 1 (Foundation) can begin — no remaining P0/P1 spikes gate it
- Remaining P2 spikes: S9 (adaptive RMS noise-floor), S1 (identifying activating app)
- PowerSpike code in `PowerSpike/` — throwaway harness, not production code

---

## Session 011 — 2026-05-03 — Spike #8 closed PASS, Token-Arrival Robustness Validated

**Format:** Claude Code agent execution (Spike #8 Phases A–C), sub-agent reviewed.

### What happened
Ran Spike #8 end-to-end. Built `TokenStabilitySpike/` harness (SPM package, reusing frozen copies of `WPMCalculator`, `SpeakingActivityTracker`, `EMASmoother` from WPMSpike) to test whether `SpeechAnalyzer` token timestamps are stable across mics (MacBook built-in vs AirPods Pro 2) and environments (quiet room vs café ambience).

**Phase A (harness):** Created CLI that processes one `.caf` file with locked production constants (window=6, alpha=0.3, tokenSilenceTimeout=1.5), outputs one CSV row. Validated by processing WPMSpike's `en_normal.caf` — bit-for-bit match with Spike #6 result at identical parameters.

**Phase B (recordings + evaluation):** User recorded 4 clips of a fresh 96-word English script in 4 conditions. Same noise source (YouTube café ambience) for both noisy clips, recorded back-to-back. All 4 processed successfully with zero failures.

**Phase C (analysis):** Three direct token-stability measures all pass:
- Word count: identical (99) across all 4 conditions
- Speaking duration: CV 2.93% (threshold <10%)
- Inter-onset interval: 355–384ms (CV 2.9%); silence gaps 4–6ms avg — tokens effectively contiguous

WPM raw CV (7.84%) exceeds the 5% threshold, but root cause analysis shows this is not token-arrival instability — it's speaker pace variance (3.35% CV from natural re-reading variation) plus an EMA warmup artifact in one clip (`airpods_quiet`: 3.0s pre-speech delay → EMA accumulates zeros). Pace-normalized CV excluding the outlier: 1.99%.

### Key finding
Approach D (token-arrival-based speaking duration) is fully validated. `SpeechAnalyzer`'s ML-based VAD produces stable token timestamps regardless of input device or ambient noise. No need for Approach C (`SoundAnalysis` VAD) as secondary signal.

### Production note
`WPMCalculator` should begin sampling after the first token arrives, not from t=0. The `airpods_quiet` outlier demonstrated that pre-speech silence causes an EMA warmup artifact that depresses the sliding-window average. Production code handles this naturally — widget shows "Listening..." until first token, then starts WPM computation.

### Ups
- Perfect word count stability (all 99, 0% spread) — strongest possible evidence that `SpeechAnalyzer` recognition is environment-agnostic
- Harness validated with bit-for-bit S6 match before running any new clips
- 3h actual = 3h estimated. Clean execution.

### Downs
- `airpods_quiet` WPM outlier initially looked alarming (9.2% error) before root cause analysis traced it to pre-speech delay, not a mic problem
- Natural speaker pace variance (~3.35%) conflates with mic/environment effects when using raw WPM CV. Need pace normalization to separate the two.

### Next session
- S7 (Power & CPU profiling) is next P1 spike. Phase 0 remaining: ~9h.
- Phase 1 (Foundation) can begin any time — no remaining spikes gate it.

---

## Session 010 — 2026-05-03 — Spike #2 closed PASS, Language Auto-Detect Validated as Script-Aware Hybrid

**Format:** Claude Code agent execution (Spike #2 Phases A–D), fully verified, sub-agent reviewed.

### What happened
Ran Spike #2 end-to-end across two conversation sessions. Built a `LangDetectSpike/` harness (SPM package, CLI with `preflight`, `evaluate-b`, `evaluate-c`, `analyze-wordcount` subcommands) to test two detection approaches across three representative language pairs (EN+RU, EN+JA, EN+ES) using 16 real audio clips (4 per language, sourced from YouTube by user).

**Phase A (preflight):** Validated test corpus, confirmed Apple `SpeechTranscriber` locale support (en, ja, es — not ru), confirmed `NLLanguageRecognizer` sanity, checked Parakeet model cache.

**Phase B (Option B — transcribe-then-detect):** 48 evaluations total. Two signals emerged:
- `NLLanguageRecognizer` on transcribed text: 100% for same-script pairs (EN+ES), 0% for cross-script wrong-guess transcripts (EN+RU). The wrong-locale transcriber produces garbled text that the text classifier cannot parse.
- Word-count on wrong-guess transcript: 100% for EN+RU (threshold 13 words), 62.5% for EN+ES. Cross-script transcription produces dramatically fewer words; same-script does not.
- Character-count tested post-hoc: identical accuracy to word-count, no additional value.
- Russian evaluations initially blocked by Apple `SpeechTranscriber` not supporting `ru_RU`. Resolved by routing Russian through Parakeet (FluidAudio) — the same backend Architecture Y uses in production.

**Phase C (Option C — Whisper-tiny audio LID):** 48 evaluations. Used WhisperKit's `openai_whisper-tiny` Core ML model (75.5 MB).
- EN+JA: **100% at both 3s and 5s windows** — the load-bearing gate (≥90% required).
- EN+RU: 100% at both windows (informational — already covered by word-count).
- EN+ES: 75% at 3s, 100% at 5s. Two Spanish clips misclassified as Portuguese and Arabic at 3s. Detection was unconstrained across 99 languages — no pair restriction applied. Informational only — EN+ES handled by NLLanguageRecognizer.

**Phase D (this entry):** Wrote canonical REPORT.md, investigated compute units (ANE confirmed by default configuration), analyzed the unconstrained detection finding, updated four docs.

### The empirically-confirmed Risk A prediction
The spike's Risk A from the original plan was: "What if Option B's NLLanguageRecognizer fails on cross-script pairs because the wrong-locale transcript is garbled?" This is exactly what happened — and it's exactly why the spike ran both options. The word-count signal catches what NLLanguageRecognizer misses (cross-script), and NLLanguageRecognizer catches what word-count misses (same-script). Neither alone is sufficient. The hybrid is stronger than either.

### The surprise EN+ES finding
NLLanguageRecognizer achieved 100% accuracy on EN+ES — a pair many text classifiers struggle with due to shared vocabulary. This was not expected at this confidence level. It means the production path for same-script pairs (the most common user scenario) needs zero additional models and zero detection latency beyond the ~5s transcription window.

### Compute unit finding
WhisperKit's `ModelComputeOptions` defaults to `.cpuAndNeuralEngine` for audio encoder and text decoder on macOS 14+ (our target is macOS 26). This matches Parakeet's compute unit configuration. Apple does not expose a runtime API to verify actual hardware dispatch, but the Core ML configuration explicitly requests ANE. Spike #7's power profiling should use Instruments to measure actual hardware utilization.

### Unconstrained detection finding
WhisperKit's `detectLangauge` method runs argmax over all 99 language tokens — no pair-based filtering. The API only returns the single argmax token, discarding the full probability distribution. Pair-constrained detection would require modifying WhisperKit's `LanguageLogitsFilter` (~20 lines). For production M3.4, this is a straightforward enhancement. Not retested because the unconstrained failure only affects same-script pairs (EN+ES), which are handled by NLLanguageRecognizer, not Whisper.

### Script-aware hybrid recommendation (locked)
```
User declares 2 languages at onboarding
  → dominantScript(locale1) vs dominantScript(locale2)
    → same script?        → Strategy 1: NLLanguageRecognizer (0 MB, ~5s background)
    → one is CJK?         → Strategy 3: Whisper-tiny LID (75.5 MB, ~3s blocking)
    → otherwise (Cyrillic) → Strategy 2: Word-count threshold (0 MB, ~5s background)
```

### What changed in the docs
- `05_SPIKES.md` — Spike #2 marked ✅ passed with validated outcomes above original spec
- `03_ARCHITECTURE.md` — `LanguageDetector` section rewritten: placeholder "Spike #2 will pick" replaced with concrete three-strategy design, strategy selection logic, per-user cost table, Whisper-tiny model details, architecture interaction notes
- `04_BACKLOG.md` — S2 marked ✅ passed (6h actual), Phase 0 remaining reduced to ~12h, M3.4 description updated to reflect three-strategy router (estimate confirmed at 4–6h)
- `01_PROJECT_JOURNAL.md` — this entry

### Where we left off
- Phase 0 has 4 open spikes: S8 (token-arrival robustness, next P1), S7 (power profiling), S9 (shouting detection), S1 (activating app ID)
- Spike #2 code in `LangDetectSpike/` — throwaway harness, not production code
- Working tree has uncommitted LangDetectSpike additions (WhisperKit dependency, evaluate-c implementation, REPORT.md, run_option_c.sh). Ready for commit.
- Spike #7 note: should now include Whisper-tiny's ~600ms inference in its power budget for CJK-language users (adds to the language-detection phase, not to sustained transcription)

### Ups
- Both options (B and C) exceeded their accuracy gates. EN+JA at 100% on both windows was decisive — no ambiguity about whether the Whisper-tiny model is adequate.
- The hybrid recommendation emerged naturally from the data — each signal has a complementary strength. This is a cleaner architecture than either option alone would have been.
- Parakeet integration for Russian evaluations (Phase B blocker) was resolved quickly by reusing the FluidAudio API pattern from the ParakeetSpike.
- NLLanguageRecognizer's 100% on EN+ES was a positive surprise — eliminates model cost for the most common pair type.
- 6h actual vs 5h estimated. Slight overrun due to the Parakeet routing addition and WhisperKit model search, both of which were not in the original scope but were necessary.

### Downs
- The original spike plan assumed Apple `SpeechTranscriber` supports Russian. It doesn't — same finding as Session 006 / Spike #10, but re-encountered here. We needed Parakeet as a transcription backend for the Russian evaluations, adding ~1h of unplanned integration work. This was already known from the architecture but wasn't reflected in the spike's method section.
- WhisperKit has a typo in its public API: `detectLangauge` (swapped a/u). This will need to be tracked if the API is ever fixed in a future WhisperKit version.
- The EN+ES 3s misclassifications (Spanish→Portuguese, Spanish→Arabic) could not be retested with pair restriction because WhisperKit's API doesn't support it. The finding is documented but the fix is deferred to production implementation.

### Next session
- S8 (token-arrival robustness across mics/environments) is next P1
- After S8, S7 (power profiling) can run — it now has all the compute-unit information from S2 and S10
- Commit LangDetectSpike harness code
- Once all Phase 0 spikes close, write Phase 0 summary and begin Phase 1

---

## Session 009 — 2026-05-02 — Language model simplified to N≤2 declared at onboarding; Spike #2 rescoped

**Format:** Architecture decision triggered by user observation about real-user multilingual frequency.

### What happened
While prepping the Spike #2 prompt, the user (Anton) raised an onboarding question that reframed the entire language-detection design: *"I'm thinking about an onboarding question: which languages do you speak and want to improve. Allow to select 3 max, expecting most of the users select 1 and some 2. Hardly believe multilingual audience for this app."*

That observation flips Spike #2's premise. The original design assumed runtime auto-detection across the v1 supported languages with no user input — a 3-way classifier (EN/RU/ES) at minimum, potentially harder if v1 added languages later. The user's read of the audience says: most users will declare 1 language, some will declare 2, almost none will declare 3+.

After working through implications, the user simplified further: **v1 supports max 2 declared languages, picked at first-launch onboarding from the union of Apple's 27 + Parakeet's 25 supported locales (~50 distinct languages).**

### Decision: declared-languages model (locked Session 009)

**At onboarding (M1.7, new module):**
- Single screen, one question: "Which 1–2 languages do you speak in meetings?"
- Combined alphabetized list of ~50 locales (Apple ∪ Parakeet supported sets). Backend choice (Apple vs Parakeet) is invisible to the user — app decides routing internally.
- System locale pre-checked as default. User must affirmatively pick at least one. Max 2 selectable.
- Editable from Settings later.
- Sets `declaredLocales: [Locale]` (1 or 2 entries) and `hasCompletedOnboarding: Bool` in `Settings`/`UserDefaults`.

**At runtime (`LanguageDetector` module, simplified):**
- N=1: no detection. Return `declaredLocales[0]` immediately. Most users — most sessions — never run any auto-detect machinery.
- N=2: binary classifier between exactly the two declared locales. Never has to consider any other language in the world. Spike #2 picks the mechanism (Option B vs C).
- The "two transcribers in parallel" approach (Option A) remains disqualified by FM4.

### Why this is materially cleaner
- A 2-way classifier is meaningfully more accurate than a 3-way or N-way one. Smaller candidate set, fewer wrong calls.
- Backend routing is fully precomputed at onboarding. A user who picks only English never downloads Parakeet, never sees a Russian-related anything. The 1.2 GB Parakeet download becomes opt-in.
- "Unsupported language at runtime" disappears as a concept — onboarding gates it. If the user can't pick a language, they can't speak it to the app.
- Language-specific assets (filler dictionary, WPM target, locale model) are seeded only for declared languages.
- Spike #2 simplifies — fewer pairs to test, smaller harness, narrower acceptance criteria.

### Why this works within FM3 (no setup)
The product spec previously locked "no dedicated onboarding screen, ≤2 first-launch user actions." This decision technically adds an onboarding screen but the user-action count stays at 2: (1) language picker (one screen, one question), (2) mic permission grant (system dialog at first session start). The product spec's FM3 wording is updated to "Minimal setup" instead of "No setup" — that's a more accurate framing of where v1 actually lands.

### Scope impact

**Added:**
- New module **M1.7** in Phase 1: onboarding language picker (3h)
- New `Settings` keys: `declaredLocales: [Locale]`, `hasCompletedOnboarding: Bool`. Filler dict keys move to `fillerDict[<localeIdentifier>]` instead of fixed `fillerDictEN/RU/ES`.

**Reduced:**
- **M3.4** `LanguageDetector` estimate: 6–10h → 4–6h. Binary classifier is materially smaller than the N-way version, and N=1 case is a no-op.

**Revised:**
- **Spike #2** rewritten in `05_SPIKES.md` to test the binary classifier across three representative language pairs: EN+RU, EN+JA, EN+ES. Test corpus sourced from YouTube (public monologue/news clips, ~10s each, 4 per language). Pass criteria tightened: ≥90% on EN+RU and EN+JA, ≥85% on EN+ES (the more similar pair). Estimate revised 6h → 5h.
- **`02_PRODUCT_SPEC.md`** Languages and Language Handling sections rewritten to reflect onboarding picker and ~50 locale union. Filler dictionary scope generalized.
- **`03_ARCHITECTURE.md`** `LanguageDetector` section rewritten: explicit N=1 trivial path + N=2 binary classifier behavior. Settings keys updated. Open questions table reflects narrower Spike #2 scope.
- **`04_BACKLOG.md`** Phase 1 totals 11h → 14h (+M1.7). Phase 3 totals 40–48h → 38–44h (M3.4 reduced). Project total roughly net zero.

### Where we left off
- All four affected docs (02, 03, 04, 05) updated and ready for replacement in repo
- No agent prompt for Spike #2 has been generated yet — that's the immediate next session task
- No production code committed this session beyond previous commits
- Session 008's Spike #4 commit (`a31231d`) and prior commits remain the head of main; this session adds doc updates only

### Ups
- User caught an over-engineering instinct in my Spike #2 framing. I had been designing for "auto-detect any language anywhere," which was the wrong product premise for an audience that's mostly monolingual or bilingual.
- The simpler model genuinely is simpler at every layer: spec, architecture, spike, module, runtime cost. Rare to find a simplification that wins on all axes.
- Confirmed via the conversation that the architecture's `TranscriptionEngine` routing layer (locked Session 006) survives this change unmodified — it just gets fewer locales to route in practice. Good signal that the underlying abstraction is sound.

### Downs
- This is the second time in the project's planning that an "obvious" requirement (here: real-time auto-detection) turned out to be over-scoped relative to actual audience behavior. The first was Session 001's hotkey-vs-auto-detect oscillation. Lesson: when designing a feature for a hypothetical user, double-check the hypothesis against the *actual* user (Anton) before locking it in.
- Slight re-scope cost on `02_PRODUCT_SPEC.md` and `03_ARCHITECTURE.md`. Not a huge edit, but it's the third "small" architecture-doc rewrite this week. Each one is justified, but each one also hurts confidence in the locked-ness of "locked" decisions.

### Lesson for future planning
**Before a spike defines its test corpus, the architect must verify the spike's runtime scope matches the real product scope, not an inflated worst-case scope.** Spike #2 was originally scoped for "auto-detect any of v1's 3 languages, plus future flexibility" — but the runtime never needed to do that, because the user pre-declares which languages matter. The corpus was sized for a problem the product doesn't actually solve. Add to `00_COLLABORATION_INSTRUCTIONS.md` next session: when reviewing a spike's plan, explicitly ask "what does the runtime *actually* see in production, not in theory."

### Next session
- Generate revised Spike #2 prompt for Claude Code with the N=2 binary-classifier scope
- User sources YouTube clips for the EN+RU, EN+JA, EN+ES test corpus
- Agent runs Spike #2 phases A through D, reports outcome
- After Spike #2 closes, S8 (token-arrival robustness) is the next P1

---

## Session 008 — 2026-05-02 — Spike #4 closed PASS WITH CAVEATS, Mic Coexistence Validated

**Format:** Claude Code agent execution (Spike #4 all scenarios), user-assisted real-device testing.

### What happened
Built a throwaway `MicCoexistSpike/` CLI harness that runs `AVAudioEngine` with `isVoiceProcessingEnabled = false`, installs an input tap, and logs per-second buffer counts. Ran 10 scenarios across Zoom, Google Meet (Chrome + Safari), and FaceTime using an iPhone self-loop (iPhone joined same call, mic muted, speaker on).

Headline: native conferencing apps (Zoom, FaceTime) coexist perfectly in all patterns. Browser-based conferencing (Chrome Meet, Safari Meet) works when already active, but triggers `AVAudioEngineConfigurationChange` when joining after our engine — stopping the engine. This is recoverable by restarting the engine, a well-documented Apple pattern.

### Validated numbers (final)
- **VPIO:** `false` at every checkpoint in all 10 scenarios. macOS never overrode it.
- **Native app coexistence (Zoom, FaceTime):** 0 gaps, 0 config changes in C/D/E/G patterns. Mean ~47,900 fps on 48kHz input.
- **Browser coexistence (Chrome Meet, Safari Meet):**
  - App-first pattern (C): 0 gaps, 0 config changes. Perfect.
  - Harness-first pattern (D): 1 config change → engine stopped → 30+ gaps. Recoverable.
- **Safari channel count change:** Safari Meet changes input from 1→3 channels. Using `format: nil` handles this transparently.
- **Conferencing audio quality:** User confirmed zero degradation in all 10 scenarios.

### What changed in the docs
- `05_SPIKES.md` — Spike #4 marked ⚠️ passed with caveats. Validated outcomes section added above original spec.
- `01_PROJECT_JOURNAL.md` — this entry.

### Swift 6 strict concurrency findings
The harness exposed two Swift 6 runtime issues relevant to production `AudioPipeline`:

1. **`@main struct` / `main.swift` top-level closures inherit `@MainActor` isolation.** The audio tap callback runs on CoreAudio's `RealtimeMessenger.mServiceQueue`. When the closure is defined in a main-actor context, Swift 6's runtime checks crash with `EXC_BREAKPOINT` / `_dispatch_assert_queue_fail`. Fix: define tap closures in a separate source file outside the main-actor context.

2. **`AVAudioEngine` / `AVAudioInputNode` are non-Sendable.** When captured in closures from `main.swift` (main-actor-isolated scope), they need `nonisolated(unsafe)` annotation.

These are directly relevant to how `AudioPipeline` structures its tap installation and should be documented in the architecture.

### Production requirements surfaced
`AudioPipeline` must:
1. Observe `AVAudioEngineConfigurationChange` and restart engine + reinstall tap on receipt.
2. Use `format: nil` for tap installation (never hardcode channel count or sample rate).
3. Set `isVoiceProcessingEnabled = false` before any tap installation.
4. Ensure audio tap closures do not inherit `@MainActor` isolation.

### Where we left off
- Phase 0 has 4 open spikes: S2 (language auto-detect), S8 (token robustness), S7 (power profiling), S9 (shouting detection), S1 (activating app ID).
- Spike #4's config-change recovery is not a blocker — it's a routine `AudioPipeline` implementation detail for M2.1.
- Working tree has uncommitted `MicCoexistSpike/` harness code. Ready for commit.

### Ups
- All native conferencing apps (the primary use case — Zoom calls) coexist with zero issues. The VPIO=false strategy is validated.
- Browser Meet failures are recoverable, not fatal. The config-change pattern is standard Apple audio handling.
- User confirmed audio quality was unaffected in every single scenario. Our engine is invisible to conferencing apps.
- Swift 6 concurrency findings caught now save debugging time during production AudioPipeline implementation.
- 3h actual vs 3h estimated. On budget.

### Downs
- Spent ~45 minutes debugging a Swift 6 runtime crash (`EXC_BREAKPOINT` in `_dispatch_assert_queue_fail`) before identifying that `@main struct` closures inherit main-actor isolation. The crash report was the key — the compiler gave no warning. This is a subtle Swift 6 gotcha that would have hit production code too.
- Browser Meet coexistence requires engine restart logic. Not hard, but it's additional code in `AudioPipeline` that wouldn't exist if all apps used CoreAudio directly.

### Next session
- Commit MicCoexistSpike harness
- Proceed to next P0 spike (S7 power profiling, or S2/S8 depending on priority review)
- Update `03_ARCHITECTURE.md` with config-change recovery requirement and Swift 6 isolation note
- Update `04_BACKLOG.md` with actual hours

---

## Session 007 — 2026-05-02 — Spike #10 closed PASS, Architecture Y validated

**Format:** Claude Code agent execution (Spike #10 Phases A–F + clean-vs-noisy A/B addendum), fully verified, sub-agent reviewed.

### What happened
Spike #10 ran end-to-end across the day. The agent acquired FluidInference's pre-converted `parakeet-tdt-0.6b-v3` Core ML model via FluidAudio Swift SDK (saved ~20h of custom Core ML inference work). Built a small `ParakeetSpike/` harness (sibling to `WPMSpike/`), validated all six pass criteria from the original spec on the three Russian clips from Spike #6, then executed an additional clean-vs-noisy A/B with two new clips the user recorded.

Headline: every gate passed comfortably except one marginal — `ru_fast` Russian WER at 26.8% vs 25% gate. Investigation in the addendum confirmed café noise is **not** the cause; the 26.8% is a fast-pace Parakeet limitation. Clean-vs-noisy A/B at ~110 WPM showed identical 9.4% WER in both conditions.

### Validated numbers (final)
- **Real-time factor:** 0.011 mean, 0.032 worst → ~90× real-time. Budget gate was 0.5.
- **Peak working memory:** 133 MB. Budget gate was 800 MB. Architecture's earlier estimate was conservative by 6×.
- **Cold-start (3 tiers):** ~53s first-ever model download (one-time, M3.6 toast); ~16s recompile after cache eviction; 0.4s warm subsequent runs.
- **Russian WER:** 9.4% clean speech / 9.4% café-noisy speech at ~110 WPM; 11.6% on `ru_normal` (156 WPM); 10.8% on `ru_slow` (102 WPM); 26.8% on `ru_fast` (205 WPM, marginal).
- **Filler recognition:** 70% / 90% across the two A/B clips (sample-size-noise dominates the spread; both above 70% gate).
- **Word-level timestamps:** confirmed. `ASRResult.tokenTimings` provides per-token `startTime`/`endTime` after BPE subword merging via `TokenMerger`.
- **WPM accuracy:** 1.6% / 0.7% error vs ground truth on the two A/B clips. Spike #6 gate was <8%.
- **Sustained-run stability:** 185 iterations, RSS flat, no leaks.

### What changed in the docs
- `03_ARCHITECTURE.md` — `ParakeetTranscriberBackend` section rewritten with validated numbers replacing the conservative pre-spike estimates. Phrase-level fallback caveat removed (word-level confirmed). Open-questions table marks Spike #10 closed.
- `05_SPIKES.md` — Spike #10 marked ✅ passed with full validated outcomes and open follow-ups (none blocking). Spike #6 marked ✅ passed with locked production constants. Original spike specifications preserved below the validated outcomes for archaeology.
- `04_BACKLOG.md` — Phase 0 table reordered. Closed spikes (S6, S10) noted with actual hours. Remaining work: S4 next P0 (3h), then S2/S8/S7/S9/S1. Phase 0 remaining ~21h (down from 35–39h).
- `01_PROJECT_JOURNAL.md` — this entry.

### The clean-vs-noisy A/B (Session 007 addendum)
User recorded two ~165s Russian clips back-to-back, identical 298-word script:
- `ru_clean.caf` — quiet home environment
- `ru_noisy.caf` — café environment (matches the original Spike #6 recording conditions)

Pace was slow-normal at ~110 WPM in both. Agent ran them through Phase C of the spike harness and produced a delta table.

Result: WER identical at 9.4%. WPM error 1.6% / 0.7%. RTF essentially identical. Filler-rate gap (70% / 90%) is sample-size noise — 10 instances per clip, missing one filler shifts the rate by 10 points.

The big takeaway: the fast-Russian quality cliff at 26.8% WER is a *pace* issue, not an environment issue. Café noise is fine. Russian-in-meetings should work for normal-paced speakers regardless of where they're working.

### Caveat documented in REPORT.md addendum
The clean-vs-noisy A/B was at ~110 WPM only. Russian-at-fast-pace under noise is untested. If real users report degraded fast Russian in noisy conditions during early v1 use, re-test with a fast-pace café clip. Logged as a v1.x follow-up, not a v1 blocker.

### Architecture corrections from validated numbers
The architecture doc's original estimates were:
- Cold-start <30s — actual is two numbers: 53s first-ever, 16s recompile. The 30s gate was wrong; M3.6's "Preparing Russian model…" toast must handle ~1 minute on first download.
- <800 MB memory — actual is 133 MB. Budget gate stays at 800 MB (defense-in-depth) but the realistic number is ~6× under.
- 600 MB INT8 / 1.2 GB FP16 — INT8 was rejected. FP16 chosen because INT8 forces CPU-only Core ML execution, losing ANE offload, which is more expensive overall despite the smaller file. Architecture doc updated.

### Where we left off
- Phase 0 still has 5 open spikes: S4 (Zoom mic coexistence) is next P0, then S2 / S8 / S7 / S9 / S1.
- User explicitly chose Path A: complete all Phase 0 spikes before any Phase 1 production code, on the basis that the design (UI/UX) work can run in parallel and Phase 1 implementation deserves a clean session start with no spike risk hanging over it.
- No production code committed this session beyond the spike harness in `ParakeetSpike/`.
- Working tree clean except for `WPMSpike/recordings/m4a/` (user's source Voice Memos exports). Adding to `.gitignore` next session — minor cleanup, not blocking.

### Ups
- Pre-converted Core ML model existed publicly. Saved a major chunk of work that I would have estimated 20+ agent hours.
- Word-level timestamps confirmed. The Session 004 `SpeakingActivityTracker` design is preserved without compromise. No fallback logic to write, no degraded-Russian-WPM path to maintain.
- Clean-vs-noisy A/B was the user's idea, and it's the most useful experiment we've run. It surfaced that the "noise problem" we thought we had was actually a "fast-pace problem." Different mitigation entirely.
- Agent flagged the filler-rate delta as sample-size noise without me prompting. Right call.
- 10h actual vs 8–12h estimate. Estimate was correct.

### Downs
- The original Spike #10 acceptance criterion of "<30s cold-start" was wrong. Should have been "<30s for warm/recompile cold-start; first-ever download is a one-time UX consideration covered by M3.6 toast." When I write spike pass criteria with hard numbers, I need to think about whether the number applies to all instances of the metric or only specific ones.
- We learned that fast-pace Russian (~205 WPM) has noticeably worse WER than normal-pace. The product implication: a user who genuinely speaks Russian at 205 WPM will get a degraded experience compared to a 110 WPM speaker. That's a real product consideration but not a spike failure — Russian filler counting and WPM math both still work.
- I asked about Phase 0 vs Phase 1 twice before getting an answer. Could have been one sharper ask.

### Lesson for future spikes
Whenever a spike measures a "cold-start" or any latency that has a one-time vs steady-state distinction, the acceptance criterion must be split into both. Otherwise the spike's pass/fail blurs together two different user experiences (first-ever vs every-day) that have different mitigations.

### Next session
- Generate Spike #4 prompt (Zoom mic coexistence) for Claude Code
- After Spike #4 closes, S2 / S8 / S7 / S9 / S1 in priority order
- Once all Phase 0 spikes close, write a Phase 0 summary entry covering all validated decisions, lock-in numbers, and the Phase 1 starting state. That's the entry the new session reads to begin Phase 1 implementation cleanly.

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
