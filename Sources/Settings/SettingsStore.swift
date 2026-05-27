import Combine
import Foundation
import OSLog

private enum Keys {
    static let declaredLocales = "declaredLocales"
    static let coachingEnabled = "coachingEnabled"
    static let hasCompletedSetup = "hasCompletedSetup"
    static let widgetPositionByDisplay = "widgetPositionByDisplay"
    static let widgetLastUsedDisplay = "widgetLastUsedDisplay"
    static let probePollIntervalSeconds = "probePollIntervalSeconds"
    static let wpmRefreshInterval = "wpmRefreshInterval"
    static let wpmPauseThreshold = "wpmPauseThreshold"
    static let wpmEmaAlpha = "wpmEmaAlpha"
    static let monologueLevel1Minutes = "monologueLevel1Minutes"
    static let monologueLevel2Minutes = "monologueLevel2Minutes"
    static let monologueLevel3Minutes = "monologueLevel3Minutes"
    static let monologuePauseThreshold = "monologuePauseThreshold"
    static let waitingOpacity = "waitingOpacity"
    static let lingerFullSeconds = "lingerFullSeconds"
    static let lingerFadeSeconds = "lingerFadeSeconds"
    static let recoveryGraceSeconds = "recoveryGraceSeconds"
}

@MainActor
final class SettingsStore: ObservableObject {

    private let userDefaults: UserDefaults
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?
    private var isSyncing = false

    @Published var declaredLocales: [String] {
        didSet {
            guard !isSyncing else { return }
            userDefaults.set(declaredLocales, forKey: Keys.declaredLocales)
        }
    }

    @Published var coachingEnabled: Bool {
        didSet {
            guard !isSyncing else { return }
            userDefaults.set(coachingEnabled, forKey: Keys.coachingEnabled)
        }
    }

    @Published var hasCompletedSetup: Bool {
        didSet {
            guard !isSyncing else { return }
            userDefaults.set(hasCompletedSetup, forKey: Keys.hasCompletedSetup)
        }
    }

    @Published var widgetPositionByDisplay: [String: CGPoint] {
        didSet {
            guard !isSyncing else { return }
            if let data = Self.encodePositions(widgetPositionByDisplay) {
                userDefaults.set(data, forKey: Keys.widgetPositionByDisplay)
            }
        }
    }

    @Published var widgetLastUsedDisplay: String? {
        didSet {
            guard !isSyncing else { return }
            userDefaults.set(widgetLastUsedDisplay, forKey: Keys.widgetLastUsedDisplay)
        }
    }

    @Published var probePollIntervalSeconds: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.05, min(5.0, probePollIntervalSeconds))
            if clamped != probePollIntervalSeconds { probePollIntervalSeconds = clamped; return }
            userDefaults.set(probePollIntervalSeconds, forKey: Keys.probePollIntervalSeconds)
        }
    }

    @Published var wpmRefreshInterval: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(1.0, min(10.0, wpmRefreshInterval))
            if clamped != wpmRefreshInterval { wpmRefreshInterval = clamped; return }
            userDefaults.set(wpmRefreshInterval, forKey: Keys.wpmRefreshInterval)
        }
    }

    @Published var wpmPauseThreshold: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.5, min(10.0, wpmPauseThreshold))
            if clamped != wpmPauseThreshold { wpmPauseThreshold = clamped; return }
            userDefaults.set(wpmPauseThreshold, forKey: Keys.wpmPauseThreshold)
        }
    }

    @Published var wpmEmaAlpha: Double {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.1, min(1.0, wpmEmaAlpha))
            if clamped != wpmEmaAlpha { wpmEmaAlpha = clamped; return }
            userDefaults.set(wpmEmaAlpha, forKey: Keys.wpmEmaAlpha)
        }
    }

    @Published var monologueLevel1Minutes: Double {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.25, min(30.0, monologueLevel1Minutes))
            if clamped != monologueLevel1Minutes { monologueLevel1Minutes = clamped; return }
            userDefaults.set(monologueLevel1Minutes, forKey: Keys.monologueLevel1Minutes)
        }
    }

    @Published var monologueLevel2Minutes: Double {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.25, min(30.0, monologueLevel2Minutes))
            if clamped != monologueLevel2Minutes { monologueLevel2Minutes = clamped; return }
            userDefaults.set(monologueLevel2Minutes, forKey: Keys.monologueLevel2Minutes)
        }
    }

    @Published var monologueLevel3Minutes: Double {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.25, min(30.0, monologueLevel3Minutes))
            if clamped != monologueLevel3Minutes { monologueLevel3Minutes = clamped; return }
            userDefaults.set(monologueLevel3Minutes, forKey: Keys.monologueLevel3Minutes)
        }
    }

    @Published var monologuePauseThreshold: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.5, min(10.0, monologuePauseThreshold))
            if clamped != monologuePauseThreshold { monologuePauseThreshold = clamped; return }
            userDefaults.set(monologuePauseThreshold, forKey: Keys.monologuePauseThreshold)
        }
    }

    /// Panel alpha while widget is in .waiting state (silence hold active). Clamped 0.1…1.0.
    @Published var waitingOpacity: Double {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.1, min(1.0, waitingOpacity))
            if clamped != waitingOpacity { waitingOpacity = clamped; return }
            userDefaults.set(waitingOpacity, forKey: Keys.waitingOpacity)
        }
    }

    /// Full-opacity hold duration after session ends before fade begins. Clamped 1.0…10.0s.
    @Published var lingerFullSeconds: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(1.0, min(10.0, lingerFullSeconds))
            if clamped != lingerFullSeconds { lingerFullSeconds = clamped; return }
            userDefaults.set(lingerFullSeconds, forKey: Keys.lingerFullSeconds)
        }
    }

    /// Fade-out animation duration + hide-after-fade delay. Clamped 0.5…5.0s.
    @Published var lingerFadeSeconds: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.5, min(5.0, lingerFadeSeconds))
            if clamped != lingerFadeSeconds { lingerFadeSeconds = clamped; return }
            userDefaults.set(lingerFadeSeconds, forKey: Keys.lingerFadeSeconds)
        }
    }

    /// Grace window after audio recovery for a token to restore .counting. Clamped 0.5…5.0s.
    @Published var recoveryGraceSeconds: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.5, min(5.0, recoveryGraceSeconds))
            if clamped != recoveryGraceSeconds { recoveryGraceSeconds = clamped; return }
            userDefaults.set(recoveryGraceSeconds, forKey: Keys.recoveryGraceSeconds)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        self.declaredLocales = userDefaults.object(forKey: Keys.declaredLocales) as? [String] ?? []
        self.coachingEnabled = userDefaults.object(forKey: Keys.coachingEnabled) as? Bool ?? true
        self.hasCompletedSetup = userDefaults.object(forKey: Keys.hasCompletedSetup) as? Bool ?? false

        if let data = userDefaults.data(forKey: Keys.widgetPositionByDisplay) {
            if let decoded = Self.decodePositions(data) {
                self.widgetPositionByDisplay = decoded
            } else {
                Logger.settings.warning("Corrupt widgetPositionByDisplay data — resetting to empty")
                self.widgetPositionByDisplay = [:]
            }
        } else {
            self.widgetPositionByDisplay = [:]
        }

        self.widgetLastUsedDisplay = userDefaults.string(forKey: Keys.widgetLastUsedDisplay)

        let rawPollInterval = userDefaults.object(forKey: Keys.probePollIntervalSeconds) as? Double ?? 1.0
        self.probePollIntervalSeconds = max(0.05, min(5.0, rawPollInterval))

        let rawRefreshInterval = userDefaults.object(forKey: Keys.wpmRefreshInterval) as? Double ?? 3.0
        self.wpmRefreshInterval = max(1.0, min(10.0, rawRefreshInterval))
        let rawPauseThreshold = userDefaults.object(forKey: Keys.wpmPauseThreshold) as? Double ?? 2.0
        self.wpmPauseThreshold = max(0.5, min(10.0, rawPauseThreshold))
        let rawEmaAlpha = userDefaults.object(forKey: Keys.wpmEmaAlpha) as? Double ?? 0.70
        self.wpmEmaAlpha = max(0.1, min(1.0, rawEmaAlpha))

        let rawL1 = userDefaults.object(forKey: Keys.monologueLevel1Minutes) as? Double ?? 1.0
        self.monologueLevel1Minutes = max(0.25, min(30.0, rawL1))
        let rawL2 = userDefaults.object(forKey: Keys.monologueLevel2Minutes) as? Double ?? 1.5
        self.monologueLevel2Minutes = max(0.25, min(30.0, rawL2))
        let rawL3 = userDefaults.object(forKey: Keys.monologueLevel3Minutes) as? Double ?? 2.5
        self.monologueLevel3Minutes = max(0.25, min(30.0, rawL3))
        let rawMonoPause = userDefaults.object(forKey: Keys.monologuePauseThreshold) as? Double ?? 2.5
        self.monologuePauseThreshold = max(0.5, min(10.0, rawMonoPause))

        let rawWaitingOpacity = userDefaults.object(forKey: Keys.waitingOpacity) as? Double ?? 0.5
        self.waitingOpacity = max(0.1, min(1.0, rawWaitingOpacity))
        let rawLingerFull = userDefaults.object(forKey: Keys.lingerFullSeconds) as? Double ?? 3.0
        self.lingerFullSeconds = max(1.0, min(10.0, rawLingerFull))
        let rawLingerFade = userDefaults.object(forKey: Keys.lingerFadeSeconds) as? Double ?? 2.0
        self.lingerFadeSeconds = max(0.5, min(5.0, rawLingerFade))
        let rawRecoveryGrace = userDefaults.object(forKey: Keys.recoveryGraceSeconds) as? Double ?? 2.0
        self.recoveryGraceSeconds = max(0.5, min(5.0, rawRecoveryGrace))

        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: userDefaults,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.syncFromDefaults()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Widget position

    func position(for screenName: String) -> CGPoint? {
        widgetPositionByDisplay[screenName]
    }

    func setPosition(_ point: CGPoint, for screenName: String) {
        widgetPositionByDisplay[screenName] = point
    }

    // MARK: - Last-used display

    func lastUsedDisplay() -> String? { widgetLastUsedDisplay }

    func setLastUsedDisplay(_ name: String?) { widgetLastUsedDisplay = name }

    // MARK: - Locale management

    func toggleLocale(_ identifier: String) {
        if let index = declaredLocales.firstIndex(of: identifier) {
            declaredLocales.remove(at: index)
        } else {
            guard declaredLocales.count < 2 else { return }
            declaredLocales.append(identifier)
            if !hasCompletedSetup {
                hasCompletedSetup = true
            }
        }
    }

    func commitSystemLocaleIfApplicable(systemLocaleIdentifier: String) {
        guard !hasCompletedSetup, declaredLocales.isEmpty else { return }
        let normalized = systemLocaleIdentifier.replacingOccurrences(of: "-", with: "_")
        guard LocaleRegistry.allLocales.contains(where: { $0.identifier == normalized }) else {
            return
        }
        declaredLocales = [normalized]
        hasCompletedSetup = true
    }

}

// MARK: - Defaults sync (extracted to keep class body under SwiftLint type_body_length limit)

private extension SettingsStore {
    // swiftlint:disable:next cyclomatic_complexity
    func syncFromDefaults() {
        isSyncing = true
        defer { isSyncing = false }

        let newDeclaredLocales = userDefaults.object(forKey: Keys.declaredLocales) as? [String] ?? []
        if newDeclaredLocales != declaredLocales { declaredLocales = newDeclaredLocales }

        let newCoaching = userDefaults.object(forKey: Keys.coachingEnabled) as? Bool ?? true
        if newCoaching != coachingEnabled { coachingEnabled = newCoaching }

        let newSetup = userDefaults.object(forKey: Keys.hasCompletedSetup) as? Bool ?? false
        if newSetup != hasCompletedSetup { hasCompletedSetup = newSetup }

        let newLastUsed = userDefaults.string(forKey: Keys.widgetLastUsedDisplay)
        if newLastUsed != widgetLastUsedDisplay { widgetLastUsedDisplay = newLastUsed }

        let newPollInterval = max(0.05, min(5.0, userDefaults.object(forKey: Keys.probePollIntervalSeconds) as? Double ?? 1.0))
        if newPollInterval != probePollIntervalSeconds { probePollIntervalSeconds = newPollInterval }

        let newRefreshInterval = max(1.0, min(10.0, userDefaults.object(forKey: Keys.wpmRefreshInterval) as? Double ?? 3.0))
        if newRefreshInterval != wpmRefreshInterval { wpmRefreshInterval = newRefreshInterval }
        let newPauseThreshold = max(0.5, min(10.0, userDefaults.object(forKey: Keys.wpmPauseThreshold) as? Double ?? 2.0))
        if newPauseThreshold != wpmPauseThreshold { wpmPauseThreshold = newPauseThreshold }
        let newEmaAlpha = max(0.1, min(1.0, userDefaults.object(forKey: Keys.wpmEmaAlpha) as? Double ?? 0.70))
        if newEmaAlpha != wpmEmaAlpha { wpmEmaAlpha = newEmaAlpha }

        let newL1 = max(0.25, min(30.0, userDefaults.object(forKey: Keys.monologueLevel1Minutes) as? Double ?? 1.0))
        if newL1 != monologueLevel1Minutes { monologueLevel1Minutes = newL1 }
        let newL2 = max(0.25, min(30.0, userDefaults.object(forKey: Keys.monologueLevel2Minutes) as? Double ?? 1.5))
        if newL2 != monologueLevel2Minutes { monologueLevel2Minutes = newL2 }
        let newL3 = max(0.25, min(30.0, userDefaults.object(forKey: Keys.monologueLevel3Minutes) as? Double ?? 2.5))
        if newL3 != monologueLevel3Minutes { monologueLevel3Minutes = newL3 }
        let newMonoPause = max(0.5, min(10.0, userDefaults.object(forKey: Keys.monologuePauseThreshold) as? Double ?? 2.5))
        if newMonoPause != monologuePauseThreshold { monologuePauseThreshold = newMonoPause }

        let newWaitingOpacity = max(0.1, min(1.0, userDefaults.object(forKey: Keys.waitingOpacity) as? Double ?? 0.5))
        if newWaitingOpacity != waitingOpacity { waitingOpacity = newWaitingOpacity }
        let newLingerFull = max(1.0, min(10.0, userDefaults.object(forKey: Keys.lingerFullSeconds) as? Double ?? 3.0))
        if newLingerFull != lingerFullSeconds { lingerFullSeconds = newLingerFull }
        let newLingerFade = max(0.5, min(5.0, userDefaults.object(forKey: Keys.lingerFadeSeconds) as? Double ?? 2.0))
        if newLingerFade != lingerFadeSeconds { lingerFadeSeconds = newLingerFade }
        let newRecoveryGrace = max(0.5, min(5.0, userDefaults.object(forKey: Keys.recoveryGraceSeconds) as? Double ?? 2.0))
        if newRecoveryGrace != recoveryGraceSeconds { recoveryGraceSeconds = newRecoveryGrace }

        syncPositionsFromDefaults()
    }

    func syncPositionsFromDefaults() {
        guard let data = userDefaults.data(forKey: Keys.widgetPositionByDisplay) else {
            if !widgetPositionByDisplay.isEmpty { widgetPositionByDisplay = [:] }
            return
        }
        guard let newPositions = Self.decodePositions(data) else {
            Logger.settings.warning("Corrupt widgetPositionByDisplay data during sync — resetting to empty")
            if !widgetPositionByDisplay.isEmpty { widgetPositionByDisplay = [:] }
            return
        }
        if newPositions != widgetPositionByDisplay { widgetPositionByDisplay = newPositions }
    }

    nonisolated static func encodePositions(_ positions: [String: CGPoint]) -> Data? {
        let raw = positions.mapValues { [$0.x, $0.y] }
        return try? JSONEncoder().encode(raw)
    }

    nonisolated static func decodePositions(_ data: Data) -> [String: CGPoint]? {
        guard let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else {
            return nil
        }
        return raw.compactMapValues { arr in
            guard arr.count == 2 else { return nil }
            return CGPoint(x: arr[0], y: arr[1])
        }
    }
}
