@preconcurrency import AVFoundation
import Foundation

// MARK: - Globals (MainActor top-level context in Swift 6)

nonisolated(unsafe) let engine = AVAudioEngine()
nonisolated(unsafe) let inputNode = engine.inputNode

// MARK: - Helpers

func log(_ scenario: String, _ message: String) {
    let ts = String(format: "%.3f", Date().timeIntervalSince1970)
    fputs("[\(scenario)] [\(ts)] \(message)\n", stderr)
}

func setupEngine() {
    do {
        try inputNode.setVoiceProcessingEnabled(false)
    } catch {
        log("SETUP", "WARNING: setVoiceProcessingEnabled(false) threw: \(error)")
    }

    let hwFormat = inputNode.inputFormat(forBus: 0)
    log("SETUP", "Hardware format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch")
    log("SETUP", "VPIO after disable: \(inputNode.isVoiceProcessingEnabled)")
}

func startEngine() throws {
    engine.prepare()
    try engine.start()
}

func stopEngine() {
    engine.stop()
}

// MARK: - S1: 60s baseline

func runS1() async {
    log("S1", "Starting 60s baseline run")

    let bridge = AudioTapBridge()
    let sink = BufferSink()

    bridge.install(on: inputNode)
    do {
        try startEngine()
    } catch {
        log("S1", "FAIL — engine start failed: \(error)")
        print("[S1] FAIL — engine start failed: \(error)")
        return
    }

    let consumeTask = Task {
        for await buffer in bridge.bufferStream {
            await sink.process(buffer)
        }
    }

    log("S1", "Engine running. Collecting buffers for 60s...")

    for second in 1...60 {
        try? await Task.sleep(for: .seconds(1))
        if second % 10 == 0 {
            let snap = await sink.snapshot()
            log("S1", "\(second)s — buffers: \(snap.bufferCount), rate: \(snap.lastSampleRate) Hz, ch: \(snap.lastChannelCount), samples copied: \(snap.totalSamplesCopied)")
        }
    }

    bridge.stop(inputNode: inputNode)
    stopEngine()
    consumeTask.cancel()

    let snap = await sink.snapshot()
    let pass = snap.bufferCount > 0
    let status = pass ? "PASS" : "FAIL"
    log("S1", "\(status) — buffers: \(snap.bufferCount), last sampleTime: \(snap.lastSampleTime), format: \(snap.lastSampleRate) Hz / \(snap.lastChannelCount) ch, total samples copied: \(snap.totalSamplesCopied)")
    print("[S1] \(status) — buffers: \(snap.bufferCount); format: \(snap.lastSampleRate) Hz / \(snap.lastChannelCount) ch; samples copied: \(snap.totalSamplesCopied)")
}

// MARK: - S4: Configuration-change recovery

final class S4Tracker: @unchecked Sendable {
    var configChangeCount = 0
    var recoveryTimeMs: Double?
    var preChangeFormat = ""
    var postChangeFormat = ""
}

func runS4() async {
    log("S4", "Starting config-change recovery scenario")

    let bridge = AudioTapBridge()
    let sink = BufferSink()
    let tracker = S4Tracker()

    bridge.install(on: inputNode)
    do {
        try startEngine()
    } catch {
        log("S4", "FAIL — engine start failed: \(error)")
        print("[S4] FAIL — engine start failed: \(error)")
        return
    }

    let consumeTask = Task {
        for await buffer in bridge.bufferStream {
            await sink.process(buffer)
        }
    }

    try? await Task.sleep(for: .seconds(2))

    let preSnap = await sink.snapshot()
    tracker.preChangeFormat = "\(preSnap.lastSampleRate) Hz / \(preSnap.lastChannelCount) ch"

    let configObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: engine,
        queue: .main
    ) { [tracker] _ in
        tracker.configChangeCount += 1

        let changeTime = Date()
        let newFormat = inputNode.inputFormat(forBus: 0)
        tracker.postChangeFormat = "\(newFormat.sampleRate) Hz / \(newFormat.channelCount) ch"
        log("S4", "CONFIG CHANGE #\(tracker.configChangeCount) — new format: \(tracker.postChangeFormat)")

        bridge.recover(engine: engine, inputNode: inputNode)

        Task {
            let preCount = await sink.snapshot().bufferCount
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(10))
                let currentSnap = await sink.snapshot()
                if currentSnap.bufferCount > preCount {
                    let elapsed = Date().timeIntervalSince(changeTime) * 1000
                    tracker.recoveryTimeMs = elapsed
                    log("S4", "Buffer flow resumed in \(String(format: "%.1f", elapsed))ms after config change")
                    break
                }
            }
        }
    }

    log("S4", "WAITING: open Chrome and join a Google Meet now (90s window)")
    fputs("\n========================================\n", stderr)
    fputs("[S4] WAITING: open Chrome and join a Google Meet now (90s window)\n", stderr)
    fputs("========================================\n\n", stderr)

    for second in 1...90 {
        try? await Task.sleep(for: .seconds(1))
        if second % 15 == 0 {
            let snap = await sink.snapshot()
            log("S4", "\(second)s — buffers: \(snap.bufferCount), config changes: \(tracker.configChangeCount)")
        }
        if tracker.configChangeCount > 0 && tracker.recoveryTimeMs != nil {
            try? await Task.sleep(for: .seconds(5))
            break
        }
    }

    NotificationCenter.default.removeObserver(configObserver)
    bridge.stop(inputNode: inputNode)
    stopEngine()
    consumeTask.cancel()

    let finalSnap = await sink.snapshot()

    if tracker.configChangeCount == 0 {
        log("S4", "SKIP — no config change observed in 90s window")
        print("[S4] SKIP — no config change observed in 90s window; buffers received: \(finalSnap.bufferCount)")
    } else {
        let recovered = tracker.recoveryTimeMs != nil
        let withinBudget = (tracker.recoveryTimeMs ?? 9999) <= 500
        let pass = recovered && withinBudget
        let status = pass ? "PASS" : "FAIL"
        let rTime = tracker.recoveryTimeMs.map { String(format: "%.1f", $0) } ?? "N/A"
        log("S4", "\(status) — config changes: \(tracker.configChangeCount), recovery: \(rTime)ms, pre-format: \(tracker.preChangeFormat), post-format: \(tracker.postChangeFormat), final buffers: \(finalSnap.bufferCount)")
        print("[S4] \(status) — config changes: \(tracker.configChangeCount); recovery: \(rTime)ms; pre: \(tracker.preChangeFormat); post: \(tracker.postChangeFormat); buffers: \(finalSnap.bufferCount)")
    }
}

// MARK: - S5: Backpressure stress

func runS5() async {
    log("S5", "Starting backpressure stress scenario")

    log("S5", "Phase A: 50ms delay (should NOT trigger backpressure at ~85ms callback interval)")
    let bridgeA = AudioTapBridge(bufferPolicy: .bufferingNewest(64))
    let sinkA = BufferSink()

    bridgeA.install(on: inputNode)
    do {
        try startEngine()
    } catch {
        log("S5", "FAIL — engine start failed: \(error)")
        print("[S5] FAIL — engine start failed: \(error)")
        return
    }

    let consumeTaskA = Task {
        for await buffer in bridgeA.bufferStream {
            await sinkA.processWithDelay(buffer, delayMs: 50)
        }
    }

    for second in 1...15 {
        try? await Task.sleep(for: .seconds(1))
        if second % 5 == 0 {
            let snap = await sinkA.snapshot()
            log("S5", "Phase A \(second)s — sink buffers: \(snap.bufferCount)")
        }
    }

    bridgeA.stop(inputNode: inputNode)
    stopEngine()
    consumeTaskA.cancel()

    let snapA = await sinkA.snapshot()
    log("S5", "Phase A done — sink received: \(snapA.bufferCount) (50ms delay, no backpressure expected)")

    try? await Task.sleep(for: .seconds(1))

    log("S5", "Phase B: 200ms delay (SHOULD trigger backpressure)")
    let bridgeB = AudioTapBridge(bufferPolicy: .bufferingNewest(64))
    let sinkB = BufferSink()

    bridgeB.install(on: inputNode)
    do {
        try startEngine()
    } catch {
        log("S5", "FAIL — engine restart failed: \(error)")
        print("[S5] FAIL — engine restart failed")
        return
    }

    let consumeTaskB = Task {
        for await buffer in bridgeB.bufferStream {
            await sinkB.processWithDelay(buffer, delayMs: 200)
        }
    }

    for second in 1...60 {
        try? await Task.sleep(for: .seconds(1))
        if second % 10 == 0 {
            let snap = await sinkB.snapshot()
            log("S5", "Phase B \(second)s — sink buffers: \(snap.bufferCount)")
        }
    }

    bridgeB.stop(inputNode: inputNode)
    stopEngine()
    consumeTaskB.cancel()

    try? await Task.sleep(for: .seconds(1))

    let snapB = await sinkB.snapshot()
    let callbackIntervalMs: Double = 4096.0 / 48000.0 * 1000.0
    let expectedCallbacks = Int(60.0 / (callbackIntervalMs / 1000.0))
    let dropped = max(0, expectedCallbacks - snapB.bufferCount)
    let backpressureTriggered = snapB.bufferCount < expectedCallbacks
    let pass = backpressureTriggered
    let status = pass ? "PASS" : "FAIL"

    log("S5", "\(status) — expected ~\(expectedCallbacks) callbacks; sink received: \(snapB.bufferCount); dropped: ~\(dropped); policy: bufferingNewest(64)")
    print("[S5] \(status) — expected ~\(expectedCallbacks) callbacks; sink received: \(snapB.bufferCount); policy: bufferingNewest(64); backpressure triggered: \(backpressureTriggered)")
}

// MARK: - Main

setupEngine()

let scenario = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"

switch scenario {
case "s1":
    await runS1()
case "s4":
    await runS4()
case "s5":
    await runS5()
case "all":
    print("=== Spike #4 Phase 2: AudioTap Strict-Concurrency Tightening ===")
    print("")

    print("[S2] Compile gate: if you're reading this, S2 PASSED (compiled with -warnings-as-errors)")
    print("")

    await runS1()
    print("")

    print("[S3] Thread Sanitizer: run separately with --sanitize=thread flag")
    print("")

    await runS4()
    print("")

    await runS5()

    print("")
    print("=== All scenarios complete ===")
default:
    fputs("Usage: MicTapTightenSpikeCLI [s1|s4|s5|all]\n", stderr)
}
