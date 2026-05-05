import Combine
import Foundation

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

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        self.declaredLocales = userDefaults.object(forKey: Keys.declaredLocales) as? [String] ?? []
        self.wpmTargetMin = userDefaults.object(forKey: Keys.wpmTargetMin) as? Int ?? 130
        self.wpmTargetMax = userDefaults.object(forKey: Keys.wpmTargetMax) as? Int ?? 170
        self.coachingEnabled = userDefaults.object(forKey: Keys.coachingEnabled) as? Bool ?? true
        self.hasCompletedSetup = userDefaults.object(forKey: Keys.hasCompletedSetup) as? Bool ?? false
        self.fillerDict = userDefaults.object(forKey: Keys.fillerDict) as? [String: [String]] ?? [:]

        if let data = userDefaults.data(forKey: Keys.widgetPositionByDisplay) {
            self.widgetPositionByDisplay = Self.decodePositions(data)
        } else {
            self.widgetPositionByDisplay = [:]
        }

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

        if let data = userDefaults.data(forKey: Keys.widgetPositionByDisplay) {
            let newPositions = Self.decodePositions(data)
            if newPositions != widgetPositionByDisplay { widgetPositionByDisplay = newPositions }
        } else if !widgetPositionByDisplay.isEmpty {
            widgetPositionByDisplay = [:]
        }
    }

    private nonisolated static func encodePositions(_ positions: [String: CGPoint]) -> Data? {
        let raw = positions.mapValues { [$0.x, $0.y] }
        return try? JSONEncoder().encode(raw)
    }

    private nonisolated static func decodePositions(_ data: Data) -> [String: CGPoint] {
        guard let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else {
            return [:]
        }
        return raw.compactMapValues { arr in
            guard arr.count == 2 else { return nil }
            return CGPoint(x: arr[0], y: arr[1])
        }
    }
}
