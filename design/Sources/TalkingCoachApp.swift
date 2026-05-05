//
//  TalkingCoachApp.swift
//  TalkingCoach
//
//  App entry. Headless menu-bar agent (LSUIElement = true) that drives a
//  floating non-activating panel hosting the SwiftUI widget.
//
//  Wiring:
//      • Bootstrap permissions on launch.
//      • When mic + speech are authorized, start the SpeechAnalyzer pipeline.
//      • Show / hide the FloatingPanel based on `widgetState.isMicActive`.
//

import SwiftUI
import AppKit

@main
struct TalkingCoachApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Empty scene — the panel is managed manually by AppDelegate.
        Settings { EmptyView() }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let speech = SpeechAnalyzerService()
    private let panel = FloatingPanelController()
    private var observation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await speech.bootstrap()
            guard speech.authState == .authorized else { return }
            await speech.startListening()
        }
        startObservingState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        speech.stopListening()
        observation?.cancel()
    }

    // MARK: - State observation

    private func startObservingState() {
        observation = Task { [weak self] in
            guard let self else { return }
            // Re-render the panel whenever the published state changes.
            for await state in self.speech.$widgetState.values {
                let view = TalkingCoachWidget(state: state)
                if state.isMicActive {
                    self.panel.show(rootView: view)
                    self.panel.update(rootView: view)
                } else {
                    self.panel.hide()
                }
            }
        }
    }
}
