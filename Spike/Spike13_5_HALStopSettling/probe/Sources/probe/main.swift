import AVFoundation
import CoreAudio
import Foundation

// MARK: - File-scope state

let startTime = Date()

// Dedicated background queue for IRS listener — captures DispatchTime.now() before dispatching to main,
// eliminating main-queue-drain latency from the settling timestamp measurement.
let irsListenerQueue = DispatchQueue(label: "probe.irs-listener", qos: .userInteractive)

// Device state (set once at startup)
nonisolated(unsafe) var currentTargetDeviceID: AudioObjectID = kAudioObjectUnknown
nonisolated(unsafe) var currentTargetDeviceName: String = "unknown"

// Engine state (per-cycle; rebuilt each cycle, nilled after teardown)
nonisolated(unsafe) var audioEngine: AVAudioEngine? = nil
nonisolated(unsafe) var configChangeObserver: (any NSObjectProtocol)? = nil

// Cycle control
nonisolated(unsafe) var cycleNumber: Int = 0

// IRS listener state (persistent; single listener registered at startup, lives all 10 cycles)
nonisolated(unsafe) var irsPropertyAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
nonisolated(unsafe) var irsListenerBlock: AudioObjectPropertyListenerBlock? = nil
nonisolated(unsafe) var irsLastValue: Bool = false
nonisolated(unsafe) var irsListenerEventTotal: Int = 0

// Per-cycle measurement state (reset to nil/false at start of each cycle)
nonisolated(unsafe) var cycleStopRequestedAt: UInt64? = nil
nonisolated(unsafe) var cycleStopReturnedAt: UInt64? = nil
nonisolated(unsafe) var cycleSettledViaListenerAt: UInt64? = nil
nonisolated(unsafe) var cycleSettledViaPollerAt: UInt64? = nil
// cycleSettled gates backup poll timer cancellation (set by whichever source fires first)
nonisolated(unsafe) var cycleSettled: Bool = false
nonisolated(unsafe) var cycleBackupPollTimer: Timer? = nil

// 1Hz polling reference (always-on sanity check)
nonisolated(unsafe) var pollCount: Int = 0
nonisolated(unsafe) var pollLastValue: Bool? = nil
nonisolated(unsafe) var pollTimer: Timer? = nil

// Aggregate state (accumulated across cycles; indexed structures allow per-cycle AGGREGATE output)
nonisolated(unsafe) var settlingResults: [(cycle: Int, nsFromReturn: UInt64, nsFromRequest: UInt64)] = []
// One entry per completed cycle (nil if poller didn't catch the transition in that cycle)
nonisolated(unsafe) var cyclePollerResults: [UInt64?] = []
nonisolated(unsafe) var pollerCatchCount: Int = 0
nonisolated(unsafe) var listenerVsPollerDeltas: [(cycle: Int, deltaNs: Int64)] = []
nonisolated(unsafe) var cyclesWithMissedSettle: Int = 0
nonisolated(unsafe) var missedCycles: [Int] = []

// MARK: - Timestamp helper

func ts() -> String {
    "[t=\(String(format: "%.2f", Date().timeIntervalSince(startTime)))s]"
}

// MARK: - CoreAudio helpers

func getDefaultInputDevice() -> AudioObjectID {
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    return deviceID
}

func getDeviceName(_ deviceID: AudioObjectID) -> String {
    var name: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let _ = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
    }
    return name.map { $0.takeRetainedValue() as String } ?? "<unknown>"
}

func readIsRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
    return value != 0
}

func msString(_ ns: UInt64) -> String {
    String(format: "%.3f", Double(ns) / 1_000_000.0)
}

func percentile95(of sorted: [UInt64]) -> UInt64 {
    guard !sorted.isEmpty else { return 0 }
    let idx = Int(ceil(0.95 * Double(sorted.count))) - 1
    return sorted[max(0, min(idx, sorted.count - 1))]
}

func signedDelta(_ a: UInt64, minus b: UInt64) -> Int64 {
    if a >= b { return Int64(a - b) } else { return -Int64(b - a) }
}

// MARK: - IRS Listener (persistent across all cycles)

func attachIRSListener(deviceID: AudioObjectID) {
    let baseline = readIsRunningSomewhere(deviceID)
    irsLastValue = baseline
    print("\(ts()) IRS_BASELINE value=\(baseline) device=\(deviceID) deviceName=\"\(getDeviceName(deviceID))\"")
    if baseline {
        print("\(ts()) WARN_IRS_PREEXISTING — IRS=true at startup; close all mic-using apps and re-run for clean measurements")
    }

    let block: AudioObjectPropertyListenerBlock = { _, _ in
        // Capture timestamp on listener queue BEFORE dispatching to main — eliminates main-queue-drain latency
        let capturedAt = DispatchTime.now().uptimeNanoseconds
        let newVal = readIsRunningSomewhere(deviceID)
        DispatchQueue.main.async { [capturedAt, newVal] in
            irsListenerEventTotal += 1
            let old = irsLastValue
            irsLastValue = newVal
            print("\(ts()) IRS_LISTENER ts=\(capturedAt) old=\(old) new=\(newVal)")

            // Triple guard: true→false transition, stop already completed, not yet recorded for this cycle.
            // cycleStopReturnedAt is nulled at the 1s deadline to gate stale late-arriving callbacks.
            guard old == true,
                  newVal == false,
                  let returnedAt = cycleStopReturnedAt,
                  let requestedAt = cycleStopRequestedAt,
                  cycleSettledViaListenerAt == nil else { return }

            cycleSettledViaListenerAt = capturedAt
            cycleSettled = true
            cycleBackupPollTimer?.invalidate()
            cycleBackupPollTimer = nil

            let fromReturn = capturedAt >= returnedAt ? capturedAt - returnedAt : 0
            let fromRequest = capturedAt >= requestedAt ? capturedAt - requestedAt : 0
            let n = cycleNumber

            print("\(ts()) CYCLE_SETTLED_VIA_LISTENER cycle=\(n) dispatch_ts=\(capturedAt) ns_from_return=\(fromReturn) ns_from_request=\(fromRequest)")
            settlingResults.append((cycle: n, nsFromReturn: fromReturn, nsFromRequest: fromRequest))
        }
    }
    irsListenerBlock = block
    AudioObjectAddPropertyListenerBlock(deviceID, &irsPropertyAddr, irsListenerQueue, block)
}

func detachIRSListener(deviceID: AudioObjectID) {
    guard let block = irsListenerBlock else { return }
    AudioObjectRemovePropertyListenerBlock(deviceID, &irsPropertyAddr, irsListenerQueue, block)
    irsListenerBlock = nil
}

// MARK: - Aggregate output and exit

func finishAndExit() {
    pollTimer?.invalidate()
    detachIRSListener(deviceID: currentTargetDeviceID)

    let elapsed = Date().timeIntervalSince(startTime)
    let attempted = cyclePollerResults.count

    let listenerNsValues = settlingResults.map { $0.nsFromReturn }
    let sortedListener = listenerNsValues.sorted()
    let minNs = sortedListener.first ?? 0
    let maxNs = sortedListener.last ?? 0
    let meanNs: UInt64 = sortedListener.isEmpty ? 0 :
        sortedListener.reduce(UInt64(0)) { $0 + $1 } / UInt64(sortedListener.count)
    let p95Ns = percentile95(of: sortedListener)

    let listenerByCycle = Dictionary(uniqueKeysWithValues: settlingResults.map { ($0.cycle, $0) })

    print("=== AGGREGATE ===")
    print("Total cycles attempted: \(attempted)")
    print("Cycles with successful settle measurement (listener): \(settlingResults.count)")
    print("Cycles with missed settle: \(cyclesWithMissedSettle)")
    if !missedCycles.isEmpty {
        print("Missed cycle numbers: \(missedCycles.map { String($0) }.joined(separator: ", "))")
    }

    print("Settling measurements (ns, from stop-return to listener-fire):")
    for i in 1...max(attempted, 1) {
        if i > attempted { break }
        if let r = listenerByCycle[i] {
            print("  cycle \(i): \(r.nsFromReturn) (\(msString(r.nsFromReturn)) ms)")
        } else {
            print("  cycle \(i): — (missed or start-failed)")
        }
    }

    print("Settling measurements (ns, from stop-request to listener-fire):")
    for i in 1...max(attempted, 1) {
        if i > attempted { break }
        if let r = listenerByCycle[i] {
            print("  cycle \(i): \(r.nsFromRequest) (\(msString(r.nsFromRequest)) ms)")
        } else {
            print("  cycle \(i): — (missed or start-failed)")
        }
    }

    print("Poller measurements (50ms backup, ns from stop-return; — if listener fired first or settle missed):")
    for (i, ns) in cyclePollerResults.enumerated() {
        if let ns = ns {
            print("  cycle \(i + 1): \(ns) (\(msString(ns)) ms)")
        } else {
            print("  cycle \(i + 1): —")
        }
    }

    if sortedListener.isEmpty {
        print("Min settling time (listener, from return): — (no measurements)")
        print("Max settling time (listener, from return): — (no measurements)")
        print("Mean settling time (listener, from return): — (no measurements)")
    } else {
        print("Min settling time (listener, from return): \(minNs) (\(msString(minNs)) ms)")
        print("Max settling time (listener, from return): \(maxNs) (\(msString(maxNs)) ms)")
        print("Mean settling time (listener, from return): \(meanNs) (\(msString(meanNs)) ms)")
    }

    if listenerVsPollerDeltas.isEmpty {
        print("Listener-vs-poll delta: no cycles where both fired")
    } else {
        print("Listener-vs-poll delta per cycle (listener_ts minus poller_ts, ns; positive=listener-later):")
        for entry in listenerVsPollerDeltas {
            let sign = entry.deltaNs >= 0 ? "listener-later" : "listener-earlier"
            print("  cycle \(entry.cycle): \(entry.deltaNs) ns (\(sign))")
        }
    }

    print("=== SUMMARY ===")
    print("Probe runtime: \(String(format: "%.1f", elapsed))s")
    print("Cycles completed: \(attempted)/10")
    print("Cycles with missed settle: \(cyclesWithMissedSettle)")
    print("IRS listener events total: \(irsListenerEventTotal)")
    print("Polled reads total (1Hz): \(pollCount)")
    print("Backup poll catches (50ms): \(pollerCatchCount)")
    if sortedListener.isEmpty {
        print("Recommended algorithm parameter (P95 from return): — (no measurements)")
        print("Recommended algorithm parameter (max from return): — (no measurements)")
    } else {
        print("Recommended algorithm parameter (P95 from return): \(msString(p95Ns)) ms")
        print("Recommended algorithm parameter (max from return): \(msString(maxNs)) ms")
    }
    print("Probe exit code: 0")
    exit(0)
}

// MARK: - Cycle runner

func runCycle(_ n: Int) {
    guard n <= 10 else {
        finishAndExit()
        return
    }

    // Reset per-cycle measurement state
    cycleStopRequestedAt = nil
    cycleStopReturnedAt = nil
    cycleSettledViaListenerAt = nil
    cycleSettledViaPollerAt = nil
    cycleSettled = false
    cycleBackupPollTimer?.invalidate()
    cycleBackupPollTimer = nil
    cycleNumber = n

    // IRS sanity check: should be false at cycle start (engine not running yet)
    let irsAtStart = readIsRunningSomewhere(currentTargetDeviceID)
    if irsAtStart {
        print("\(ts()) WARN_IRS_CARRY_OVER cycle=\(n) irs_at_start=true")
    }

    // Build a fresh AVAudioEngine each cycle — matches production AudioPipeline shape
    let engine = AVAudioEngine()
    audioEngine = engine

    // Minimal tap (empty closure — capture registration only; we measure IRS timing, not audio data)
    engine.inputNode.installTap(onBus: 0, bufferSize: 0, format: nil) { _, _ in }

    // Safety-net config-change observer (not expected to fire with plain AVAudioEngine/default input)
    configChangeObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: engine,
        queue: .main
    ) { _ in
        print("\(ts()) CYCLE_UNEXPECTED_CONFIG_CHANGE cycle=\(cycleNumber)")
    }

    engine.prepare()
    print("\(ts()) CYCLE_START cycle=\(n)")

    do {
        try engine.start()
    } catch {
        print("\(ts()) CYCLE_START_FAILED cycle=\(n) error=\"\(error.localizedDescription)\"")
        engine.inputNode.removeTap(onBus: 0)
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        audioEngine = nil
        cyclePollerResults.append(nil)
        missedCycles.append(n)
        cyclesWithMissedSettle += 1
        print("\(ts()) CYCLE_REST cycle=\(n)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            runCycle(n + 1)
        }
        return
    }

    print("\(ts()) CYCLE_RUNNING cycle=\(n) engineIsRunning=\(engine.isRunning)")

    // 2-second active capture window, then teardown and measure IRS settling
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {

        // Production teardown order: removeTap() FIRST, then stop() — matches AudioPipeline.stop() lines 133-134
        cycleStopRequestedAt = DispatchTime.now().uptimeNanoseconds
        print("\(ts()) CYCLE_STOP_REQUESTED cycle=\(n) dispatch_ts=\(cycleStopRequestedAt!)")

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        cycleStopReturnedAt = DispatchTime.now().uptimeNanoseconds
        let elapsedInStop = cycleStopReturnedAt! - cycleStopRequestedAt!
        print("\(ts()) CYCLE_STOP_RETURNED cycle=\(n) dispatch_ts=\(cycleStopReturnedAt!) elapsed_in_stop_call_ns=\(elapsedInStop) engineIsRunning=\(engine.isRunning)")
        if engine.isRunning {
            print("\(ts()) WARN_ENGINE_STILL_RUNNING cycle=\(n)")
        }

        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        audioEngine = nil

        // 50ms backup poll — active only during 1s settle-wait window, exits as soon as cycleSettled
        let localN = n
        cycleBackupPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            // Self-exit if listener already settled
            guard !cycleSettled, cycleSettledViaPollerAt == nil else {
                cycleBackupPollTimer?.invalidate()
                cycleBackupPollTimer = nil
                return
            }
            let val = readIsRunningSomewhere(currentTargetDeviceID)
            guard !val, let returnedAt = cycleStopReturnedAt else { return }
            let capturedAt = DispatchTime.now().uptimeNanoseconds
            cycleSettledViaPollerAt = capturedAt
            cycleSettled = true
            cycleBackupPollTimer?.invalidate()
            cycleBackupPollTimer = nil
            let fromReturn = capturedAt >= returnedAt ? capturedAt - returnedAt : 0
            print("\(ts()) CYCLE_SETTLED_VIA_POLL cycle=\(localN) dispatch_ts=\(capturedAt) ns_from_return=\(fromReturn)")
        }

        // 1-second deadline — records CYCLE_MISSED_SETTLE if neither source caught the transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            cycleBackupPollTimer?.invalidate()
            cycleBackupPollTimer = nil

            // Capture local values before nulling stop timestamps
            let returnedAt = cycleStopReturnedAt
            let listenerTs = cycleSettledViaListenerAt
            let pollerTs = cycleSettledViaPollerAt
            let wasSettled = cycleSettled

            // Null out stop timestamps — gates stale listener callbacks that arrive after the deadline
            cycleStopReturnedAt = nil
            cycleStopRequestedAt = nil

            // Record poller result for this cycle (one entry per cycle, nil if poller didn't catch)
            if let pollerTs = pollerTs, let returnedAt = returnedAt {
                let fromReturn = pollerTs >= returnedAt ? pollerTs - returnedAt : 0
                cyclePollerResults.append(fromReturn)
                pollerCatchCount += 1
            } else {
                cyclePollerResults.append(nil)
            }

            // Listener-vs-poller delta (only computable when both fired within the 1s window)
            if let lTs = listenerTs, let pTs = pollerTs {
                let delta = signedDelta(lTs, minus: pTs)
                listenerVsPollerDeltas.append((cycle: n, deltaNs: delta))
                let sign = delta >= 0 ? "listener-later" : "listener-earlier"
                print("\(ts()) LISTENER_VS_POLL cycle=\(n) listener_ts=\(lTs) poll_ts=\(pTs) delta_ns=\(delta) (\(sign))")
            }

            // Missed settle check (neither listener nor poller caught the true→false transition)
            if !wasSettled {
                cyclesWithMissedSettle += 1
                missedCycles.append(n)
                print("\(ts()) CYCLE_MISSED_SETTLE cycle=\(n) reason=\"listener+poller both silent after 1s\"")
                if cyclesWithMissedSettle > 1 {
                    print("\(ts()) NO_SKIPPING_TRIGGERED cyclesWithMissedSettle=\(cyclesWithMissedSettle) — stopping and reporting verbatim per NO-SKIPPING rule")
                    finishAndExit()
                    return
                }
            }

            print("\(ts()) CYCLE_REST cycle=\(n)")

            // 1-second rest before next cycle (ensures HAL at rest before next engine.start())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if n < 10 {
                    runCycle(n + 1)
                } else {
                    finishAndExit()
                }
            }
        }
    }
}

// MARK: - Entry point

let deviceID = getDefaultInputDevice()
guard deviceID != kAudioObjectUnknown else {
    print("\(ts()) FATAL: No default audio input device found")
    exit(1)
}
currentTargetDeviceID = deviceID
currentTargetDeviceName = getDeviceName(deviceID)

print("\(ts()) PROBE_13_5 INIT: device=\(deviceID) name=\"\(currentTargetDeviceName)\"")
print("\(ts()) PROBE_13_5 PURPOSE: measure HAL stop-settling time — IRS true→false delay after engine.stop()")
print("\(ts()) PROBE_13_5 PLAN: 10 cycles x (2s capture + 1s settle-window + 1s rest) ~= 40-50s total")

// Attach persistent IRS listener (logs baseline; warns if pre-existing external capture)
attachIRSListener(deviceID: deviceID)

// Start 1Hz polling reference (sanity check; always-on; not the load-bearing measurement)
pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    pollCount += 1
    let val = readIsRunningSomewhere(currentTargetDeviceID)
    if pollLastValue == nil {
        pollLastValue = val
        print("\(ts()) POLL[1] BASELINE value=\(val) device=\"\(currentTargetDeviceName)\"")
    } else if val != pollLastValue {
        pollLastValue = val
        print("\(ts()) POLL[\(pollCount)] TRANSITION old=\(!val) new=\(val)")
    }
}

// Brief startup grace before first cycle (listener and poll timer warm up)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    runCycle(1)
}

RunLoop.main.run()
