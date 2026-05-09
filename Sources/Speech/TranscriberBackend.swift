import Foundation

// MARK: - TranscribedToken

struct TranscribedToken: Sendable, Equatable {
    let token: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let isFinal: Bool
}

// MARK: - TranscriberBackendError

nonisolated enum TranscriberBackendError: Error, Sendable {
    case modelUnavailable
    case unsupportedLocale(Locale)
    case engineFailure(underlying: Error)
}

// MARK: - TranscriberBackend

nonisolated protocol TranscriberBackend: Sendable {
    func start(locale: Locale) async throws
    func stop() async
    var tokenStream: AsyncStream<TranscribedToken> { get }
}
