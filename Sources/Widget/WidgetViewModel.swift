import Combine
import Foundation

enum WidgetActivityState: Equatable {
    case idle
    case warming
    case counting
    case waiting
    case wrapping
    case recovering
    case dismissed
}

@MainActor
final class WidgetViewModel: ObservableObject {
    @Published var sessionStartedAt: Date?
    @Published var isSessionActive: Bool = false
    @Published var activityState: WidgetActivityState = .idle
    @Published var totalTokens: Int = 0
    // REMOVE-IN-M5.1: Phase 5 adds currentWPM, averageWPM, paceZone, monologueLevel
}
