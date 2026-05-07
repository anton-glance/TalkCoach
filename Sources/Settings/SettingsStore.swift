import Combine
import Foundation
import OSLog

@MainActor
final class SettingsStore: ObservableObject {

    private enum Keys {
        static let declaredLocales = "declaredLocales"
        static let wpmTargetMin = "wpmTargetMin"
        static let wpmTargetMax = "wpmTargetMax"
        static let coachingEnabled = "coachingEnabled"
        static let hasCompletedSetup = "hasCompletedSetup"
        static let fillerDict = "fillerDict"
        static let widgetPositionByDisplay = "widgetPositionByDisplay"
        static let widgetLastUsedDisplay = "widgetLastUsedDisplay"
    }

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
