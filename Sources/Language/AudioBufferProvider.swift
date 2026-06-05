import Foundation

nonisolated protocol AudioBufferProvider: Sendable {
    func bufferStream() -> AsyncStream<CapturedAudioBuffer>
}

nonisolated struct AudioPipelineBufferProvider: AudioBufferProvider {
    let pipeline: AudioPipeline

    func bufferStream() -> AsyncStream<CapturedAudioBuffer> {
        pipeline.mediumStream
    }
}

/// Wraps a pre-vended `AsyncStream<CapturedAudioBuffer>` (e.g. one produced by
/// `AudioBufferBroadcaster.makeStream()`) behind the `AudioBufferProvider` protocol.
nonisolated struct StreamAudioBufferProvider: AudioBufferProvider {
    private let stream: AsyncStream<CapturedAudioBuffer>

    init(stream: AsyncStream<CapturedAudioBuffer>) {
        self.stream = stream
    }

    func bufferStream() -> AsyncStream<CapturedAudioBuffer> {
        stream
    }
}
