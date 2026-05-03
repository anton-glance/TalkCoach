@preconcurrency import AVFoundation
import Foundation

final class MicState: @unchecked Sendable {
    private let lock = NSLock()
    private var _totalFrames: Int = 0
    private var _framesThisSecond: Int = 0
    private var _gaps: Int = 0
    private var _configChanges: Int = 0
    private var _lastSampleRate: Double = 0
    private var _lastChannels: UInt32 = 0

    func recordBuffer(frameCount: Int, sampleRate: Double, channels: UInt32) {
        lock.lock()
        _totalFrames += frameCount
        _framesThisSecond += frameCount
        _lastSampleRate = sampleRate
        _lastChannels = channels
        lock.unlock()
    }

    func incrementConfigChanges() {
        lock.lock()
        _configChanges += 1
        lock.unlock()
    }

    func tickSecond() -> (framesThisSecond: Int, totalFrames: Int, gaps: Int, configChanges: Int, sampleRate: Double, channels: UInt32) {
        lock.lock()
        let f1s = _framesThisSecond
        let ft = _totalFrames
        let g = _gaps
        let cc = _configChanges
        let sr = _lastSampleRate
        let ch = _lastChannels
        if _framesThisSecond == 0 {
            _gaps += 1
        }
        _framesThisSecond = 0
        lock.unlock()
        return (f1s, ft, g, cc, sr, ch)
    }

    func summary() -> (totalFrames: Int, gaps: Int, configChanges: Int, sampleRate: Double, channels: UInt32) {
        lock.lock()
        let ft = _totalFrames
        let g = _gaps
        let cc = _configChanges
        let sr = _lastSampleRate
        let ch = _lastChannels
        lock.unlock()
        return (ft, g, cc, sr, ch)
    }
}

let state = MicState()
nonisolated(unsafe) let engine = AVAudioEngine()
nonisolated(unsafe) let inputNode = engine.inputNode

let vpioBeforeSetup = inputNode.isVoiceProcessingEnabled
fputs("VPIO initial: \(vpioBeforeSetup)\n", stderr)

do {
    try inputNode.setVoiceProcessingEnabled(false)
} catch {
    fputs(
        "WARNING: setVoiceProcessingEnabled(false) threw: \(error)\n",
        stderr
    )
}

let hwFormat = inputNode.inputFormat(forBus: 0)
fputs(
    "Input device format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch\n",
    stderr
)

let initialSampleRate = hwFormat.sampleRate
let initialChannels = hwFormat.channelCount

inputNode.installTap(
    onBus: 0,
    bufferSize: 4096,
    format: nil,
    block: makeTapHandler(state: state)
)

let vpioAfterTap = inputNode.isVoiceProcessingEnabled
fputs(
    "VPIO after tap install: \(vpioAfterTap) (expected false)\n",
    stderr
)

let configObserver = NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange,
    object: engine,
    queue: .main
) { _ in
    let newFormat = inputNode.inputFormat(forBus: 0)
    fputs(
        "[CONFIG CHANGE] New format: \(newFormat.sampleRate) Hz, \(newFormat.channelCount) ch\n",
        stderr
    )
    state.incrementConfigChanges()
}

engine.prepare()

do {
    try engine.start()
} catch {
    fputs("ENGINE START FAILED: \(error)\n", stderr)
    _exit(1)
}

let vpioAfterStart = inputNode.isVoiceProcessingEnabled
fputs(
    "VPIO after engine.start(): \(vpioAfterStart) (expected false)\n",
    stderr
)
if vpioAfterStart {
    fputs("WARNING: macOS overrode VPIO to true!\n", stderr)
}

fputs("Engine running. Press Ctrl-C to stop.\n", stderr)
fputs(
    "elapsed_s,frames_1s,total_frames,gaps,config_changes,engine_running,sample_rate,channels\n",
    stderr
)

let startDate = Date()

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
timer.setEventHandler {
    let tick = state.tickSecond()
    let elapsed = Date().timeIntervalSince(startDate)
    fputs(
        "\(String(format: "%.1f", elapsed)),\(tick.framesThisSecond),\(tick.totalFrames),\(tick.gaps),\(tick.configChanges),\(engine.isRunning),\(String(format: "%.0f", tick.sampleRate)),\(tick.channels)\n",
        stderr
    )
}
timer.resume()

let sigintSource = DispatchSource.makeSignalSource(
    signal: SIGINT, queue: .main
)
signal(SIGINT, SIG_IGN)
sigintSource.setEventHandler {
    timer.cancel()
    sigintSource.cancel()

    engine.stop()
    inputNode.removeTap(onBus: 0)
    NotificationCenter.default.removeObserver(configObserver)

    let s = state.summary()
    let runtime = Date().timeIntervalSince(startDate)
    let meanFPS = runtime > 0
        ? Double(s.totalFrames) / runtime
        : 0

    fputs("\n--- SUMMARY ---\n", stderr)
    fputs("Runtime: \(String(format: "%.1f", runtime))s\n", stderr)
    fputs("Total frames: \(s.totalFrames)\n", stderr)
    fputs("Mean frames/sec: \(String(format: "%.0f", meanFPS))\n", stderr)
    fputs("Gaps (1s windows with 0 frames): \(s.gaps)\n", stderr)
    fputs("Config changes: \(s.configChanges)\n", stderr)
    fputs(
        "Initial format: \(String(format: "%.0f", initialSampleRate)) Hz, \(initialChannels) ch\n",
        stderr
    )
    fputs(
        "Final format: \(String(format: "%.0f", s.sampleRate)) Hz, \(s.channels) ch\n",
        stderr
    )
    fputs("Engine running at exit: \(engine.isRunning)\n", stderr)

    _exit(0)
}
sigintSource.resume()

dispatchMain()
