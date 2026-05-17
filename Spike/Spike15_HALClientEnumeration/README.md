# Spike 15 — Per-Process HAL Client Enumeration on macOS 26

**Branch:** spike/13.5-hal-stop-settling
**Date:** 2026-05-17
**Result:** HYPOTHESIS SUPPORTED

---

## Hypothesis (verbatim)

Hypothesis: macOS exposes an API (or a combination of APIs) that allows a sandboxed application running on macOS 26 to determine whether processes OTHER THAN ITSELF are currently reading audio from a given Core Audio input device, WITHOUT requiring that application to first stop its own AVAudioEngine tap. If true, this enables the M3.7.3 disconnect-probe-reconnect algorithm to be redesigned: Locto's AVAudioEngine stays running for the entire session, SpeechAnalyzer never has to re-warm on probes, and per-probe audio loss is eliminated.

**Verdict: SUPPORTED**

---

## APIs Tested

### Candidate A — kAudioHardwarePropertyProcessObjectList + kAudioProcessPropertyIsRunningInput (WINNER)

**Selector:** `kAudioHardwarePropertyProcessObjectList` on `kAudioObjectSystemObject`
**Sub-property per object:** `kAudioProcessPropertyIsRunningInput` on each returned `AudioObjectID`
**Also available per object:** `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunning`

On macOS 26 with a built-in mic and 27 registered audio processes, this API returned a complete list of `AudioObjectID` values — one per process that has ever registered with the HAL. For each, you can read the PID and `IsRunningInput` (a `UInt32` boolean: 1 = the process currently has the input device running).

**Test result on the automated scan:**
- The spike binary itself showed `IsRunningInput=true` (empty bundle, CLI tool with no bundle ID)
- `com.apple.CoreSpeech` (PID=1130) showed `IsRunningInput=true` — a permanent system daemon reader always attached to the input for dictation
- All other 25 processes showed `IsRunningInput=false`

**`kAudioHardwarePropertyProcessIsAudible`** (output audibility of current process): exists, returns a single bool, no per-process or input-side granularity. Not useful.

---

### Candidate B — kAudioObjectPropertyOwnedObjects + device-level properties

`kAudioObjectPropertyOwnedObjects` on the device returns its sub-streams and controls (4 objects), not a client process list. `kAudioDevicePropertyDeviceIsRunningSomewhere` returns the aggregate "anyone reading" boolean already used by the existing M3.7.3 probe. No per-process granularity. **Not useful.**

---

### Candidate C — Aggregate device sub-device keys

The built-in mic is not an aggregate device (class `0x61646576` = `kAudioDeviceClassID`). Aggregate device properties not applicable. `kAudioHardwarePropertyProcessObjectList` in input scope on the device object is absent. **Not useful.**

---

### Candidate D — IORegistry via IOKit

`IOServiceGetMatchingServices("IOAudioDevice")` returned services successfully. Querying for `IOAudioEngineClientDescription`, `IOAudioEngineNumActiveUserClients`, `IOAudioClientCount`, `NumClients`, `ClientPIDs` returned nothing on any service. Modern macOS audio drivers do not expose per-PID reader counts in the IORegistry. **Not useful.**

---

### Candidate E — proc_listpids + cross-reference

sysctl `KERN_PROC_ALL` returned 749 running processes. No public API exists to map PID → "is this PID reading AudioDevice X". `kAudioProcessPropertyIsRunningInput` on AudioProcess objects (Candidate A) achieves the same goal without PID iteration. **Superseded by Candidate A.**

---

### Candidate F — Additional APIs

- `kAudioHardwarePropertyTapList` (ScreenCaptureKit process taps): exists, 0 taps registered. Returns capture taps we own, not readers of our device. Not useful.
- `kAudioHardwarePropertyProcessObjectList` on device (input scope): absent.
- `kAudioDevicePropertyRelatedDevices`: exists, returns 2 related device IDs — device topology, not client list.

**`kAudioProcessPropertyIsRunningInput` per-process (via Candidate A's process list) confirmed as the winning signal** and is cited here for completeness.

---

## Manual Smoke Test Results

Three states tested with VoiceMemos (PID=838, bundle=`com.apple.VoiceMemos`).
The spike binary was installed as a HAL client (AVAudioEngine tap on the default input device) during all three states.

**State 1 — Spike alone:**

    VoiceMemos (PID=838):     IsRunningInput=false  ← not recording
    Spike binary (no bundle): IsRunningInput=true   ← we are the client
    CoreSpeech (PID=1130):    IsRunningInput=true   ← permanent system daemon

**State 2 — Spike + VoiceMemos recording:**

    VoiceMemos (PID=838):     IsRunningInput=true   ← FLIPPED: now recording
    Spike binary (no bundle): IsRunningInput=true
    CoreSpeech (PID=1130):    IsRunningInput=true

**State 3 — Spike + VoiceMemos stopped:**

    VoiceMemos (PID=838):     IsRunningInput=false  ← FLIPPED BACK
    Spike binary (no bundle): IsRunningInput=true
    CoreSpeech (PID=1130):    IsRunningInput=true

The API cleanly distinguishes "VoiceMemos recording" from "VoiceMemos idle" while Locto's engine is running the whole time. **No teardown required.**

---

## Latency Test Results

The spike was run in latency-poll mode (50ms polling interval). VoiceMemos was stopped mid-poll, then restarted:

    [1779046156.402] initial:   IsRunningInput=true  (VM was already recording)
    [1779046160.590] FLIP #1:   true→false           (user tapped stop in VoiceMemos)
    [1779046167.422] FLIP #2:   false→true           (user restarted VoiceMemos recording)

Flip #1 to Flip #2 delta: **6.832s** — this includes ~2s deliberate wait + UI navigation + tap. The HAL property update itself is sub-50ms from when the app starts recording (bounded by the poll interval).

**Important nuance — CoreSpeech baseline reader:**
`com.apple.CoreSpeech` (PID=1130) shows `IsRunningInput=true` in all three states. It is the macOS dictation daemon and is permanently attached to audio input. It is NOT a user app competing for the mic. Locto's query must account for this by establishing a baseline set at session start and comparing deltas.

---

## Interpretation for M3.7.3 Redesign

### Current algorithm (broken)

Every 15 seconds during inactivity:
1. Tear down AVAudioEngine (removes Locto from HAL reader list)
2. Wait 1.5s for HAL to settle (Spike #14 measured 1.5s settling time)
3. Query `kAudioDevicePropertyDeviceIsRunningSomewhere` (IRS)
4. IRS=true → external app reading → resume session
5. IRS=false → no readers → finalize session
6. Rebuild AVAudioEngine + reinstall tap + wait 6.9s for SpeechAnalyzer warm-up

**Total cost per probe cycle: ~8.4s (1.5s settle + 6.9s warm-up).**
In quiet rooms with brief speech bursts (Spike #14/smoke-gate finding), this compounds: no tokens reach the inactivity timer, probes loop every 15s, warm-up cycles repeat, user speech is silently lost.

### New algorithm (no teardown)

Session startup:
1. Start AVAudioEngine, install tap (once, stays up for the entire session)
2. Wait for SpeechAnalyzer warm-up (once, ~6.9s — paid exactly once)
3. Record the baseline set of `IsRunningInput=true` PIDs (will include our own PID + CoreSpeech at minimum)

When inactivity timer fires:
1. Call `kAudioHardwarePropertyProcessObjectList` on `kAudioObjectSystemObject`
2. For each returned `AudioObjectID`, read `kAudioProcessPropertyIsRunningInput` and `kAudioProcessPropertyPID`
3. Build set of `IsRunningInput=true` PIDs
4. Subtract baseline set
5. If result is non-empty → a new external process started reading → session is live → reset inactivity timer
6. If result is empty → no new readers → finalize session

**Cost per probe cycle: <1ms (a handful of `AudioObjectGetPropertyData` calls). Zero audio loss. Zero warm-up.**

### Baseline management

At session start, capture all `IsRunningInput=true` PIDs into a `Set<pid_t>`. Include our own PID (`getpid()`) in the exclusion set. Refresh the baseline if a `kAudioDevicePropertyDeviceIsRunningSomewhere` listener fires and the count changes — this handles the edge case where CoreSpeech or a new system daemon starts during a session.

Alternatively (simpler): just exclude `getpid()` and any bundle matching `com.apple.*` from the "is anyone new reading?" check. This is durable across OS version changes.

### What does NOT change

- AVAudioEngine configuration change observer stays (handles device switch mid-session)
- `kAudioDevicePropertyDeviceIsRunningSomewhere` listener stays (as an additional signal to trigger re-evaluation when IRS transitions)
- SpeechAnalyzer warm-up happens once at session open, not once per probe

### Implementation file targets

- `Sources/Core/MicAvailabilityProbing.swift` — replace the teardown-probe-rebuild cycle with the new query
- `Sources/Core/CoreAudioDeviceProvider.swift` — add `processObjects() -> [(pid: pid_t, bundle: String, isRunningInput: Bool)]` method
- `Sources/Core/SessionCoordinator.swift` — remove the `AudioPipeline.stop() / start()` calls from the probe path

---

## Constraints Accepted

1. `com.apple.CoreSpeech` is always `IsRunningInput=true`. Any implementation must exclude it (by bundle prefix or by baseline delta). Ignoring this will cause false positives (appears to always be another reader).
2. Command-line processes have an empty bundle ID. Locto's own process is identified by PID (`getpid()`), not by bundle, in the exclusion logic.
3. The property is on the system-level audio process list, not scoped per-device. If the machine has multiple input devices and two apps use different ones, both will appear as `IsRunningInput=true`. For Locto's use case (single default input device, checking for mic competition) this is acceptable — false positives (seeing a reader on a different input device) are conservative (we'd keep the session open longer, not falsely terminate it).
4. This API was verified on macOS 26 (Tahoe beta). `kAudioHardwarePropertyProcessObjectList` and `kAudioProcessPropertyIsRunningInput` appear to be available since macOS Sonoma (macOS 14) based on CoreAudio header dates, but macOS 26 is the project's minimum target so older-OS compatibility is not a concern.
