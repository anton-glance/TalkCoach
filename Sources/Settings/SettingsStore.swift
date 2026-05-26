import Combine
import Foundation
import OSLog

private enum Keys {
    static let declaredLocales = "declaredLocales"
    static let wpmTargetMin = "wpmTargetMin"
    static let wpmTargetMax = "wpmTargetMax"
    static let coachingEnabled = "coachingEnabled"
    static let hasCompletedSetup = "hasCompletedSetup"
    static let fillerDict = "fillerDict"
    static let widgetPositionByDisplay = "widgetPositionByDisplay"
    static let widgetLastUsedDisplay = "widgetLastUsedDisplay"
    static let inactivityThresholdSeconds = "inactivityThresholdSeconds"
    static let widgetHideDelaySeconds = "widgetHideDelaySeconds"
    static let probePollIntervalSeconds = "probePollIntervalSeconds"
    static let wpmRefreshInterval = "wpmRefreshInterval"
    static let wpmPauseThreshold = "wpmPauseThreshold"
    static let wpmMedianWindowHops = "wpmMedianWindowHops"
    static let wpmEmaAlpha = "wpmEmaAlpha"
    static let monologueLevel1Minutes = "monologueLevel1Minutes"
    static let monologueLevel2Minutes = "monologueLevel2Minutes"
    static let monologueLevel3Minutes = "monologueLevel3Minutes"
    static let monologuePauseThreshold = "monologuePauseThreshold"
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

    @Published var wpmTargetMin: Int {
        didSet {
            guard !isSyncing else { return }
            userDefaults.set(wpmTargetMin, forKey: Keys.wpmTargetMin)
        }
    }

    @Published var wpmTargetMax: Int {
        didSet {
            guard !isSyncing else { return }
            userDefaults.set(wpmTargetMax, forKey: Keys.wpmTargetMax)
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

    @Published var fillerDict: [String: [String]] {
        didSet {
            guard !isSyncing else { return }
            userDefaults.set(fillerDict, forKey: Keys.fillerDict)
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

    @Published var inactivityThresholdSeconds: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(5, min(120, inactivityThresholdSeconds))
            if clamped != inactivityThresholdSeconds { inactivityThresholdSeconds = clamped; return }
            userDefaults.set(inactivityThresholdSeconds, forKey: Keys.inactivityThresholdSeconds)
        }
    }

    @Published var widgetHideDelaySeconds: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(1, min(30, widgetHideDelaySeconds))
            if clamped != widgetHideDelaySeconds { widgetHideDelaySeconds = clamped; return }
            userDefaults.set(widgetHideDelaySeconds, forKey: Keys.widgetHideDelaySeconds)
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
    /// Stored for M4.3; not used in M4.1 WPM math.
    @Published var wpmPauseThreshold: TimeInterval {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.5, min(10.0, wpmPauseThreshold))
            if clamped != wpmPauseThreshold { wpmPauseThreshold = clamped; return }
            userDefaults.set(wpmPauseThreshold, forKey: Keys.wpmPauseThreshold)
        }
    }
    /// Row A: number of recent raw per-hop WPM values to median over. Clamped 1…10.
    @Published var wpmMedianWindowHops: Int {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(1, min(10, wpmMedianWindowHops))
            if clamped != wpmMedianWindowHops { wpmMedianWindowHops = clamped; return }
            userDefaults.set(wpmMedianWindowHops, forKey: Keys.wpmMedianWindowHops)
        }
    }
    /// Row B: EMA smoothing factor. Clamped 0.1…1.0. Default 0.70 (bake-off result).
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
            let clamped = max(0.05, min(30.0, monologueLevel1Minutes))
            if clamped != monologueLevel1Minutes { monologueLevel1Minutes = clamped; return }
            userDefaults.set(monologueLevel1Minutes, forKey: Keys.monologueLevel1Minutes)
        }
    }

    @Published var monologueLevel2Minutes: Double {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.05, min(30.0, monologueLevel2Minutes))
            if clamped != monologueLevel2Minutes { monologueLevel2Minutes = clamped; return }
            userDefaults.set(monologueLevel2Minutes, forKey: Keys.monologueLevel2Minutes)
        }
    }

    @Published var monologueLevel3Minutes: Double {
        didSet {
            guard !isSyncing else { return }
            let clamped = max(0.05, min(30.0, monologueLevel3Minutes))
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

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        self.declaredLocales = userDefaults.object(forKey: Keys.declaredLocales) as? [String] ?? []
        self.wpmTargetMin = userDefaults.object(forKey: Keys.wpmTargetMin) as? Int ?? 130
        self.wpmTargetMax = userDefaults.object(forKey: Keys.wpmTargetMax) as? Int ?? 170
        self.coachingEnabled = userDefaults.object(forKey: Keys.coachingEnabled) as? Bool ?? true
        self.hasCompletedSetup = userDefaults.object(forKey: Keys.hasCompletedSetup) as? Bool ?? false
        self.fillerDict = userDefaults.object(forKey: Keys.fillerDict) as? [String: [String]] ?? [:]

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
        let rawThreshold = userDefaults.object(forKey: Keys.inactivityThresholdSeconds) as? Double ?? 15.0
        self.inactivityThresholdSeconds = max(5, min(120, rawThreshold))
        let rawHideDelay = userDefaults.object(forKey: Keys.widgetHideDelaySeconds) as? Double ?? 4.0
        self.widgetHideDelaySeconds = max(1, min(30, rawHideDelay))
        let rawPollInterval = userDefaults.object(forKey: Keys.probePollIntervalSeconds) as? Double ?? 1.0
        self.probePollIntervalSeconds = max(0.05, min(5.0, rawPollInterval))

        let rawRefreshInterval = userDefaults.object(forKey: Keys.wpmRefreshInterval) as? Double ?? 3.0
        self.wpmRefreshInterval = max(1.0, min(10.0, rawRefreshInterval))
        let rawPauseThreshold = userDefaults.object(forKey: Keys.wpmPauseThreshold) as? Double ?? 2.0
        self.wpmPauseThreshold = max(0.5, min(10.0, rawPauseThreshold))
        let rawMedianN = userDefaults.object(forKey: Keys.wpmMedianWindowHops) as? Int ?? 3
        self.wpmMedianWindowHops = max(1, min(10, rawMedianN))
        let rawEmaAlpha = userDefaults.object(forKey: Keys.wpmEmaAlpha) as? Double ?? 0.70
        self.wpmEmaAlpha = max(0.1, min(1.0, rawEmaAlpha))

        let rawL1 = userDefaults.object(forKey: Keys.monologueLevel1Minutes) as? Double ?? 0.1667  // DEV default; production 60s — revert before ship
        self.monologueLevel1Minutes = max(0.05, min(30.0, rawL1))
        let rawL2 = userDefaults.object(forKey: Keys.monologueLevel2Minutes) as? Double ?? 0.3333  // DEV default; production 90s — revert before ship
        self.monologueLevel2Minutes = max(0.05, min(30.0, rawL2))
        let rawL3 = userDefaults.object(forKey: Keys.monologueLevel3Minutes) as? Double ?? 0.5     // DEV default; production 150s — revert before ship
        self.monologueLevel3Minutes = max(0.05, min(30.0, rawL3))
        let rawMonoPause = userDefaults.object(forKey: Keys.monologuePauseThreshold) as? Double ?? 2.5
        self.monologuePauseThreshold = max(0.5, min(10.0, rawMonoPause))

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

    // swiftlint:disable:next cyclomatic_complexity
    private func syncFromDefaults() {
        isSyncing = true
        defer { isSyncing = false }

        let newDeclaredLocales = userDefaults.object(forKey: Keys.declaredLocales) as? [String] ?? []
        if newDeclaredLocales != declaredLocales { declaredLocales = newDeclaredLocales }

        let newWpmMin = userDefaults.object(forKey: Keys.wpmTargetMin) as? Int ?? 130
        if newWpmMin != wpmTargetMin { wpmTargetMin = newWpmMin }

        let newWpmMax = userDefaults.object(forKey: Keys.wpmTargetMax) as? Int ?? 170
        if newWpmMax != wpmTargetMax { wpmTargetMax = newWpmMax }

        let newCoaching = userDefaults.object(forKey: Keys.coachingEnabled) as? Bool ?? true
        if newCoaching != coachingEnabled { coachingEnabled = newCoaching }

        let newSetup = userDefaults.object(forKey: Keys.hasCompletedSetup) as? Bool ?? false
        if newSetup != hasCompletedSetup { hasCompletedSetup = newSetup }

        let newFillers = userDefaults.object(forKey: Keys.fillerDict) as? [String: [String]] ?? [:]
        if newFillers != fillerDict { fillerDict = newFillers }
        let newLastUsed = userDefaults.string(forKey: Keys.widgetLastUsedDisplay)
        if newLastUsed != widgetLastUsedDisplay { widgetLastUsedDisplay = newLastUsed }
        let newThreshold = max(5, min(120, userDefaults.object(forKey: Keys.inactivityThresholdSeconds) as? Double ?? 15.0))
        if newThreshold != inactivityThresholdSeconds { inactivityThresholdSeconds = newThreshold }

        let newHideDelay = max(1, min(30, userDefaults.object(forKey: Keys.widgetHideDelaySeconds) as? Double ?? 4.0))
        if newHideDelay != widgetHideDelaySeconds { widgetHideDelaySeconds = newHideDelay }

        let newPollInterval = max(0.05, min(5.0, userDefaults.object(forKey: Keys.probePollIntervalSeconds) as? Double ?? 1.0))
        if newPollInterval != probePollIntervalSeconds { probePollIntervalSeconds = newPollInterval }

        let newRefreshInterval = max(1.0, min(10.0, userDefaults.object(forKey: Keys.wpmRefreshInterval) as? Double ?? 3.0))
        if newRefreshInterval != wpmRefreshInterval { wpmRefreshInterval = newRefreshInterval }
        let newPauseThreshold = max(0.5, min(10.0, userDefaults.object(forKey: Keys.wpmPauseThreshold) as? Double ?? 2.0))
        if newPauseThreshold != wpmPauseThreshold { wpmPauseThreshold = newPauseThreshold }
        let newMedianN = max(1, min(10, userDefaults.object(forKey: Keys.wpmMedianWindowHops) as? Int ?? 3))
        if newMedianN != wpmMedianWindowHops { wpmMedianWindowHops = newMedianN }
        let newEmaAlpha = max(0.1, min(1.0, userDefaults.object(forKey: Keys.wpmEmaAlpha) as? Double ?? 0.70))
        if newEmaAlpha != wpmEmaAlpha { wpmEmaAlpha = newEmaAlpha }

        let newL1 = max(0.05, min(30.0, userDefaults.object(forKey: Keys.monologueLevel1Minutes) as? Double ?? 0.1667))  // DEV default; production 60s — revert before ship
        if newL1 != monologueLevel1Minutes { monologueLevel1Minutes = newL1 }
        let newL2 = max(0.05, min(30.0, userDefaults.object(forKey: Keys.monologueLevel2Minutes) as? Double ?? 0.3333))  // DEV default; production 90s — revert before ship
        if newL2 != monologueLevel2Minutes { monologueLevel2Minutes = newL2 }
        let newL3 = max(0.05, min(30.0, userDefaults.object(forKey: Keys.monologueLevel3Minutes) as? Double ?? 0.5))     // DEV default; production 150s — revert before ship
        if newL3 != monologueLevel3Minutes { monologueLevel3Minutes = newL3 }
        let newMonoPause = max(0.5, min(10.0, userDefaults.object(forKey: Keys.monologuePauseThreshold) as? Double ?? 2.5))
        if newMonoPause != monologuePauseThreshold { monologuePauseThreshold = newMonoPause }

        syncPositionsFromDefaults()
    }

    private func syncPositionsFromDefaults() {
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

    private nonisolated static func encodePositions(_ positions: [String: CGPoint]) -> Data? {
        let raw = positions.mapValues { [$0.x, $0.y] }
        return try? JSONEncoder().encode(raw)
    }

    private nonisolated static func decodePositions(_ data: Data) -> [String: CGPoint]? {
        guard let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else {
            return nil
        }
        return raw.compactMapValues { arr in
            guard arr.count == 2 else { return nil }
            return CGPoint(x: arr[0], y: arr[1])
        }
    }
}
