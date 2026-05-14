import AppKit
import OSLog
import SwiftData
import SwiftUI

nonisolated func pauseResumeMenuTitle(coachingEnabled: Bool) -> String {
    coachingEnabled ? "Pause Coaching" : "Resume Coaching"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var current: AppDelegate?

    let settingsStore = SettingsStore()
    let permissionManager = PermissionManager()
    private(set) var sessionCoordinator: SessionCoordinator!
    private(set) var floatingPanelController: FloatingPanelController!
    private(set) var sessionStore: SessionStore?
    private(set) var settingsWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.current = self

        let micMonitor = MicMonitor()
        sessionCoordinator = SessionCoordinator(
            micMonitor: micMonitor,
            settingsStore: settingsStore,
            micProber: SystemMicAvailabilityProber(),
            systemEventObserver: SystemEventObserver()
        )
        floatingPanelController = FloatingPanelController(
            sessionCoordinator: sessionCoordinator,
            settingsStore: settingsStore
        )

        do {
            let container = try SessionContainerFactory.makeContainer()
            sessionStore = SessionStore(modelContainer: container)
        } catch {
            Logger.session.error("Failed to create SessionStore: \(error)")
        }
    }

    // swiftlint:disable:next function_body_length
    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let wasSetupCompletedBefore = defaults.bool(forKey: "hasCompletedSetup")

        if !wasSetupCompletedBefore {
            let declaredLocales = defaults.object(forKey: "declaredLocales") as? [String] ?? []
            if declaredLocales.isEmpty {
                let sysLocale = Locale.current.identifier
                    .replacingOccurrences(of: "-", with: "_")
                if LocaleRegistry.allLocales.contains(where: { $0.identifier == sysLocale }) {
                    defaults.set([sysLocale], forKey: "declaredLocales")
                    defaults.set(true, forKey: "hasCompletedSetup")
                    Logger.app.info("Silent-committed system locale: \(sysLocale)")
                }
            }
            DispatchQueue.main.async {
                self.openSettings()
            }
        }

        sessionCoordinator.start()

        let audioPipeline = AudioPipeline()
        let declaredLocales = settingsStore.declaredLocales.map { Locale(identifier: $0) }
        let bufferProvider = AudioPipelineBufferProvider(pipeline: audioPipeline)
        let languageDetector = LanguageDetector(
            declaredLocales: declaredLocales,
            partialTranscriptProvider: StubPartialTranscriptProvider(),
            whisperLIDProvider: StubWhisperLIDProvider(),
            audioBufferProvider: bufferProvider
        )
        sessionCoordinator.wiring = SessionWiring(
            audioPipeline: audioPipeline,
            languageDetector: languageDetector,
            appleBackendFactory: SystemAppleBackendFactory(),
            parakeetBackendFactory: PlaceholderParakeetBackendFactory(supportedLocaleIdentifiers: []),
            supportedLocalesProvider: SystemSupportedLocalesProvider(),
            resumePipelineProvider: SystemAudioEngineProvider()
        )

        floatingPanelController.start()

        if let store = sessionStore {
            sessionCoordinator.onSessionEnded { ended in
                let record = SessionRecord.placeholder(from: ended)
                Task {
                    do {
                        try await store.save(record)
                        Logger.session.info("Persisted session \(ended.id)")
                    } catch {
                        Logger.session.error("Failed to persist session \(ended.id): \(error)")
                    }
                }
            }

            #if DEBUG
            // REMOVE-IN-M5.x: startup session count for smoke testing
            Task {
                do {
                    let count = try await store.fetchAll().count
                    Logger.session.info("Startup session count: \(count)")
                } catch {
                    Logger.session.error("Failed to fetch session count: \(error)")
                }
            }
            #endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        floatingPanelController.stop()
        sessionCoordinator.stop()
    }

    func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingController(
            rootView: SettingsView()
                .environmentObject(settingsStore)
        )

        let window = NSWindow(contentViewController: hostingView)
        window.title = "TalkCoach Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TalkCoachApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("TalkCoach", systemImage: "waveform.badge.mic") {
            MenuBarContent()
                .environmentObject(delegate.settingsStore)
        }
    }
}

struct MenuBarContent: View {
    @AppStorage("coachingEnabled") private var coachingEnabled = true
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    var body: some View {
        Button("About TalkCoach") {
            NSApplication.shared.activate()
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }

        Button(pauseResumeMenuTitle(coachingEnabled: coachingEnabled)) {
            coachingEnabled.toggle()
        }

        Button("Settings\u{2026}") {
            AppDelegate.current?.openSettings()
        }

        #if DEBUG
        // MARK: M1.6 debug scaffolding — remove when permission flow is triggered automatically
        Button("Check Permissions") {
            Task {
                guard let manager = AppDelegate.current?.permissionManager else { return }
                let outcome = await manager.requestAll()
                if outcome != .allAuthorized {
                    manager.showDeniedAlert(for: outcome)
                }
            }
        }
        #endif

        Divider()

        Button("Quit TalkCoach") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
