import SwiftUI

// MARK: - Cold-start mark

/// Pulsing Locto mark shown while the engine warms up before the first WPM reading arrives.
/// Drawn from mark.svg geometry: ring r=22, dot r=5.5 on 64-pt viewBox, scaled to 56pt.
/// Correction #2: .id(sessionStartedAt) at the call site forces recreation on each new session,
/// so @State visible resets and .onAppear re-fires the pulse animation.
struct ColdStartMarkView: View {
    let reducedMotion: Bool
    @State private var visible = false

    private let markSize: CGFloat = 56
    private var scale: CGFloat { markSize / 64 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.94), lineWidth: 3 * scale)
                .frame(width: 44 * scale, height: 44 * scale)
            Circle()
                .fill(Color.white.opacity(0.94))
                .frame(width: 11 * scale, height: 11 * scale)
        }
        .opacity(visible ? 0.94 : 0.2)
        .onAppear {
            guard !reducedMotion else {
                visible = true
                return
            }
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                visible = true
            }
        }
    }
}
