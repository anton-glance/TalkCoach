import Combine
import Foundation

@MainActor
final class WidgetViewModel: ObservableObject {
    @Published var sessionStartedAt: Date?
    @Published var isSessionActive: Bool = false
    // REMOVE-IN-M5.1: Phase 5 adds currentWPM, averageWPM, paceZone, monologueLevel
}
