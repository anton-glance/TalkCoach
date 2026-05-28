// swiftlint:disable file_length
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
    static let workingOpacity = "workingOpacity"
    static let lingerFullSeconds = "lingerFullSeconds"
    static let lingerFadeSeconds = "lingerFadeSeconds"
    static let recoveryGraceSeconds = "recoveryGraceSeconds"
}

@MainActor
// swiftlint:disable:next type_body_length
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

    /// Panel alpha while widget is actively counting (user is speaking). Clamped 0.1…1.0.
    @Published var workingOpacity: Double {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.1, min(1.0, workingOpacity))
            if clamped != workingOpacity { workingOpacity = clamped; return }
            userDefaults.set(workingOpacity, forKey: Keys.workingOpacity)
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

        // v1 locale lock: on first launch (no stored declaredLocales key), write en_US and mark
        // setup complete into UserDefaults before applicationDidFinishLaunching reads them.
        let rawLocales = userDefaults.object(forKey: Keys.declaredLocales) as? [String]
        if rawLocales == nil {
            userDefaults.set(["en_US"], forKey: Keys.declaredLocales)
            userDefaults.set(true, forKey: Keys.hasCompletedSetup)
        }
        self.declaredLocales = rawLocales ?? ["en_US"]
        self.coachingEnabled = userDefaults.object(forKey: Keys.coachingEnabled) as? Bool ?? true
        self.hasCompletedSetup = userDefaults.object(forKey: Keys.hasCompletedSetup) as? Bool ?? true

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

        let nums = Self.loadNumericSettings(from: userDefaults)
        self.probePollIntervalSeconds = nums.probePollIntervalSeconds
        self.wpmRefreshInterval = nums.wpmRefreshInterval
        self.wpmPauseThreshold = nums.wpmPauseThreshold
        self.wpmEmaAlpha = nums.wpmEmaAlpha
        self.monologueLevel1Minutes = nums.monologueLevel1Minutes
        self.monologueLevel2Minutes = nums.monologueLevel2Minutes
        self.monologueLevel3Minutes = nums.monologueLevel3Minutes
        self.monologuePauseThreshold = nums.monologuePauseThreshold
        self.waitingOpacity = nums.waitingOpacity
        self.workingOpacity = nums.workingOpacity
        self.lingerFullSeconds = nums.lingerFullSeconds
        self.lingerFadeSeconds = nums.lingerFadeSeconds
        self.recoveryGraceSeconds = nums.recoveryGraceSeconds

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

    // MARK: - Numeric settings loader (extracted to keep init body under SwiftLint limit)

    private struct NumericSettings {
        let probePollIntervalSeconds: Double
        let wpmRefreshInterval: Double
        let wpmPauseThreshold: Double
        let wpmEmaAlpha: Double
        let monologueLevel1Minutes: Double
        let monologueLevel2Minutes: Double
        let monologueLevel3Minutes: Double
        let monologuePauseThreshold: Double
        let waitingOpacity: Double
        let workingOpacity: Double
        let lingerFullSeconds: Double
        let lingerFadeSeconds: Double
        let recoveryGraceSeconds: Double
    }

    private static func loadNumericSettings(from defaults: UserDefaults) -> NumericSettings {
        func field(_ key: String, fallback: Double, lower: Double, upper: Double) -> Double {
            max(lower, min(upper, defaults.object(forKey: key) as? Double ?? fallback))
        }
        return NumericSettings(
            probePollIntervalSeconds: field(Keys.probePollIntervalSeconds, fallback: 1.0, lower: 0.05, upper: 5.0),
            wpmRefreshInterval: field(Keys.wpmRefreshInterval, fallback: 3.0, lower: 1.0, upper: 10.0),
            wpmPauseThreshold: field(Keys.wpmPauseThreshold, fallback: 2.0, lower: 0.5, upper: 10.0),
            wpmEmaAlpha: field(Keys.wpmEmaAlpha, fallback: 0.70, lower: 0.1, upper: 1.0),
            monologueLevel1Minutes: field(Keys.monologueLevel1Minutes, fallback: 1.0, lower: 0.25, upper: 30.0),
            monologueLevel2Minutes: field(Keys.monologueLevel2Minutes, fallback: 1.5, lower: 0.25, upper: 30.0),
            monologueLevel3Minutes: field(Keys.monologueLevel3Minutes, fallback: 2.5, lower: 0.25, upper: 30.0),
            monologuePauseThreshold: field(Keys.monologuePauseThreshold, fallback: 2.5, lower: 0.5, upper: 10.0),
            waitingOpacity: field(Keys.waitingOpacity, fallback: 0.5, lower: 0.1, upper: 1.0),
            workingOpacity: field(Keys.workingOpacity, fallback: 0.90, lower: 0.1, upper: 1.0),
            lingerFullSeconds: field(Keys.lingerFullSeconds, fallback: 3.0, lower: 1.0, upper: 10.0),
            lingerFadeSeconds: field(Keys.lingerFadeSeconds, fallback: 2.0, lower: 0.5, upper: 5.0),
            recoveryGraceSeconds: field(Keys.recoveryGraceSeconds, fallback: 2.0, lower: 0.5, upper: 5.0)
        )
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

        let newDeclaredLocales = userDefaults.object(forKey: Keys.declaredLocales) as? [String] ?? ["en_US"]
        if newDeclaredLocales != declaredLocales { declaredLocales = newDeclaredLocales }

        let newCoaching = userDefaults.object(forKey: Keys.coachingEnabled) as? Bool ?? true
        if newCoaching != coachingEnabled { coachingEnabled = newCoaching }

        let newSetup = userDefaults.object(forKey: Keys.hasCompletedSetup) as? Bool ?? true
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
        let newWorkingOpacity = max(0.1, min(1.0, userDefaults.object(forKey: Keys.workingOpacity) as? Double ?? 0.90))
        if newWorkingOpacity != workingOpacity { workingOpacity = newWorkingOpacity }
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
