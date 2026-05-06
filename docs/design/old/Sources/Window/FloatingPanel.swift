//
//  FloatingPanel.swift
//  TalkingCoach
//
//  NSPanel subclass that hosts the SwiftUI widget on top of all windows
//  without stealing focus. Spec: §10 of the design package README.
//
//  Apple references:
//      • NSPanel.StyleMask.nonactivatingPanel
//      • https://developer.apple.com/documentation/appkit/nspanel
//

import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: DesignTokens.Layout.size,
                height: DesignTokens.Layout.size
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        self.isMovableByWindowBackground = true
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false   // SwiftUI draws the shadow

        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        // Animate alpha changes ourselves with NSAnimationContext.
        self.animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

@MainActor
final class FloatingPanelController {

    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<AnyView>?
    private let positionDefaultsKeyPrefix = "talking-coach.position."

    /// Shows the panel with the given SwiftUI root view, animating in.
    func show<Root: View>(rootView: Root) {
        if panel == nil { build(rootView: AnyView(rootView)) }
        guard let panel else { return }
        positionInDefaultLocation(panel: panel)
        panel.alphaValue = 0
        panel.orderFront(nil)
        animateAlpha(to: 1)
    }

    /// Updates the SwiftUI root view in-place. Call when state changes.
    func update<Root: View>(rootView: Root) {
        hostingView?.rootView = AnyView(rootView)
    }

    /// Hides the panel, animating out.
    func hide() {
        guard let panel else { return }
        animateAlpha(to: 0) { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    // MARK: - Building

    private func build(rootView: AnyView) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: DesignTokens.Layout.size,
            height: DesignTokens.Layout.size
        )
        let panel = FloatingPanel(contentView: hosting)
        self.hostingView = hosting
        self.panel = panel
    }

    // MARK: - Positioning

    private func positionInDefaultLocation(panel: FloatingPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        // Try to restore last user-dragged position for this display.
        if let stored = restorePosition(forScreen: screen) {
            panel.setFrameOrigin(stored)
            return
        }

        // Default: top-right with edge inset.
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - panel.frame.width - DesignTokens.Window.defaultEdgeInset,
            y: visible.maxY - panel.frame.height - DesignTokens.Window.defaultEdgeInset
        )
        panel.setFrameOrigin(origin)
    }

    private func savePosition(_ point: NSPoint, forScreen screen: NSScreen) {
        let key = positionDefaultsKeyPrefix + (screen.localizedName)
        UserDefaults.standard.set(["x": point.x, "y": point.y], forKey: key)
    }

    private func restorePosition(forScreen screen: NSScreen) -> NSPoint? {
        let key = positionDefaultsKeyPrefix + (screen.localizedName)
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let x = dict["x"] as? CGFloat,
              let y = dict["y"] as? CGFloat
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    // MARK: - Animation

    private func animateAlpha(to target: CGFloat, completion: (() -> Void)? = nil) {
        guard let panel else { completion?(); return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            panel.alphaValue = target
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Animation.showHideDuration
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = target
        }, completionHandler: completion)
    }
}
