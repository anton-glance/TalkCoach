import Foundation

nonisolated protocol PartialTranscriptProvider: Sendable {
    func partialTranscriptStream() -> AsyncStream<String>
}

nonisolated struct StubPartialTranscriptProvider: PartialTranscriptProvider {
    func partialTranscriptStream() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}
