import AppKit

struct ScreenDescription: Equatable, Sendable {
    let localizedName: String
    let visibleFrame: NSRect
    let frame: NSRect
}

protocol ScreenProvider: Sendable {
    @MainActor func mainScreen() -> ScreenDescription?
    @MainActor func allScreens() -> [ScreenDescription]
}

struct SystemScreenProvider: ScreenProvider {
    @MainActor func mainScreen() -> ScreenDescription? {
        NSScreen.main.map {
            ScreenDescription(
                localizedName: $0.localizedName,
                visibleFrame: $0.visibleFrame,
                frame: $0.frame
            )
        }
    }

    @MainActor func allScreens() -> [ScreenDescription] {
        NSScreen.screens.map {
            ScreenDescription(
                localizedName: $0.localizedName,
                visibleFrame: $0.visibleFrame,
                frame: $0.frame
            )
        }
    }
}
