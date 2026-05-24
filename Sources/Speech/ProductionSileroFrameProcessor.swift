import CParakeetBridge
import OSLog

/// Production `VADFrameProcessor` backed by the Rust Silero VAD v5 ORT bridge.
///
/// Wraps `SlEngine *` from `sl_engine_create`. `processFrame` and `reset` are
/// `nonisolated` to satisfy the protocol; actual calls happen only from within
/// `SileroVADGate`'s actor serial executor, so no concurrent access occurs.
final class ProductionSileroFrameProcessor: VADFrameProcessor, @unchecked Sendable {
    // nonisolated(unsafe): written once in init, read only from SileroVADGate actor executor.
    nonisolated(unsafe) private let engine: OpaquePointer?

    /// Returns nil if the model cannot be loaded (path invalid or ORT init error).
    init?(modelPath: String) {
        let eng: OpaquePointer? = modelPath.withCString { sl_engine_create($0) }
        guard let eng else {
            Logger.speech.error("ProductionSileroFrameProcessor: sl_engine_create returned null for path \(modelPath)")
            return nil
        }
        engine = eng
        Logger.speech.info("ProductionSileroFrameProcessor: loaded from \(modelPath)")
    }

    deinit {
        if let eng = engine {
            sl_engine_destroy(eng)
        }
    }

    nonisolated func processFrame(_ samples: [Float]) -> Float {
        guard let eng = engine else { return 0.0 }
        return samples.withUnsafeBufferPointer { ptr in
            sl_process_frame(eng, ptr.baseAddress!, ptr.count)
        }
    }

    nonisolated func reset() {
        guard let eng = engine else { return }
        sl_engine_reset(eng)
    }
}
