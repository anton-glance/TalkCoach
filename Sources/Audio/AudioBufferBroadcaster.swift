import OSLog

/// Fan-out broadcaster: reads one `AsyncStream<CapturedAudioBuffer>` and delivers
/// each buffer to all registered consumer streams.
///
/// SE-0314 single-consumer constraint means `AudioPipeline.bufferStream` can only
/// be iterated once. This actor bridges that to multiple consumers (VAD gate, backend).
///
/// Back-pressure: each consumer stream uses `.bufferingNewest(64)`. A stalled consumer
/// drops its oldest buffered frames silently rather than blocking the pipeline.
actor AudioBufferBroadcaster {
    private var continuations: [UUID: AsyncStream<CapturedAudioBuffer>.Continuation] = [:]
    private var driveTask: Task<Void, Never>?

    /// Returns a new `AsyncStream` that will receive every buffer yielded by `drive(from:)`.
    /// Call before `drive(from:)` — consumers registered after `drive` starts are accepted
    /// but may miss buffers yielded before registration.
    func makeStream() -> AsyncStream<CapturedAudioBuffer> {
        let id = UUID()
        var cont: AsyncStream<CapturedAudioBuffer>.Continuation!
        let stream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        continuations[id] = cont
        return stream
    }

    /// Begin consuming `source` and fanning each buffer out to all registered streams.
    /// Capture the continuation snapshot at call time — consumers registered later
    /// receive a `.finish()` when `stop()` is called but may miss in-flight buffers.
    func drive(from source: AsyncStream<CapturedAudioBuffer>) {
        let snapshot = continuations
        driveTask = Task { [snapshot] in
            for await buffer in source {
                for cont in snapshot.values {
                    cont.yield(buffer)
                }
            }
            for cont in snapshot.values {
                cont.finish()
            }
            Logger.audio.info("AudioBufferBroadcaster: source stream finished — all consumer streams finished")
        }
    }

    /// Cancel the drive task, await its completion, then finish any streams not
    /// already finished by source exhaustion. Safe to call multiple times.
    func stop() async {
        driveTask?.cancel()
        await driveTask?.value
        driveTask = nil
        for cont in continuations.values {
            cont.finish()
        }
        Logger.audio.info("AudioBufferBroadcaster: stopped")
    }
}
