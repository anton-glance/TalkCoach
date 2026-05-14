import Combine
import Foundation

enum WidgetActivityState: Equatable {
    case waiting
    case counting
    case probing
    case resuming
}

@MainActor
final class WidgetViewModel: ObservableObject {
    @Published var sessionStartedAt: Date?
    @Published var isSessionActive: Bool = false
    @Published var activityState: WidgetActivityState = .waiting
    @Published var totalTokens: Int = 0
    // REMOVE-IN-M5.1: Phase 5 adds currentWPM, averageWPM, paceZone, monologueLevel
}
