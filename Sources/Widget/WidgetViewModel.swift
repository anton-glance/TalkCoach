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
    @Published var currentWPMVoiced: Int?
    @Published var monologueLevel: Int = 0
    @Published var streakSeconds: Double = 0
    /// True after the first non-nil currentWPMVoiced arrives this session. Drives cold-start mark visibility.
    @Published var hasReceivedWPM: Bool = false
    /// True while the widget is frozen at last-known values during the linger/wrapping phase.
    @Published var isFrozen: Bool = false

    // Thresholds — live-synced from SettingsStore so the view always uses current values
    @Published var monoL1Seconds: Double
    @Published var monoL2Seconds: Double
    @Published var monoL3Seconds: Double
    @Published var monoPauseSeconds: Double

    // isIdle = true when the widget must show dashes instead of live numbers.
    // Two independent conditions are both required to suppress idle:
    //   (1) activityState must be .counting — warming/waiting/etc. have no live data
    //   (2) currentWPMVoiced must be non-nil — calculator fires every 3s; the first
    //       window after engine-ready the value is still nil even while counting
    var isIdle: Bool { activityState != .counting || currentWPMVoiced == nil }

    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(settings: SettingsStore())
    }

    init(settings: SettingsStore) {
        monoL1Seconds = settings.monologueLevel1Minutes * 60
        monoL2Seconds = settings.monologueLevel2Minutes * 60
        monoL3Seconds = settings.monologueLevel3Minutes * 60
        monoPauseSeconds = settings.wpmPauseThreshold

        // Set hasReceivedWPM on the first non-nil WPM per session.
        // Cannot use didSet on @Published directly; a Combine sink is the correct pattern.
        $currentWPMVoiced
            .sink { [weak self] wpm in
                guard let self, !self.hasReceivedWPM, wpm != nil else { return }
                self.hasReceivedWPM = true
            }
            .store(in: &cancellables)

        settings.$monologueLevel1Minutes
            .dropFirst()
            .sink { [weak self] in self?.monoL1Seconds = $0 * 60 }
            .store(in: &cancellables)

        settings.$monologueLevel2Minutes
            .dropFirst()
            .sink { [weak self] in self?.monoL2Seconds = $0 * 60 }
            .store(in: &cancellables)

        settings.$monologueLevel3Minutes
            .dropFirst()
            .sink { [weak self] in self?.monoL3Seconds = $0 * 60 }
            .store(in: &cancellables)

        settings.$wpmPauseThreshold
            .dropFirst()
            .sink { [weak self] in self?.monoPauseSeconds = $0 }
            .store(in: &cancellables)
    }
}
