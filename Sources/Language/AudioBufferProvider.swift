import Foundation

nonisolated protocol AudioBufferProvider: Sendable {
    func bufferStream() -> AsyncStream<CapturedAudioBuffer>
}

nonisolated struct AudioPipelineBufferProvider: AudioBufferProvider {
    let pipeline: AudioPipeline

    func bufferStream() -> AsyncStream<CapturedAudioBuffer> {
        pipeline.bufferStream
    }
}
