import AppKit

final class CoachingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var onDragEnd: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
    }

    override func mouseDown(with event: NSEvent) {
        let originBefore = frame.origin
        super.mouseDown(with: event)
        if frame.origin != originBefore {
            onDragEnd?()
        }
    }
}
