import Foundation

// MARK: - TokenConsumer

/// Stateful, reference-type recipient of transcribed tokens and session lifecycle events.
/// Class-bound (AnyObject) for identity semantics: SessionCoordinator holds a stable
/// reference, and state accumulated across calls must not be silently copied.
/// Serial fan-out: consumers must be fast; slow work should be dispatched internally.
nonisolated protocol TokenConsumer: AnyObject, Sendable {
    func consume(_ token: TranscribedToken) async
    func sessionEnded() async
}
