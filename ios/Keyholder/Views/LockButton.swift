import SwiftUI
import UIKit

/// The hero: a circular orange Lock with a soft glow that breathes while idle.
struct LockButton: View {
    var enabled = true
    var size: CGFloat = 176
    let action: () -> Void

    @State private var breathing = false

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            ZStack {
                if enabled {
                    Circle().fill(Theme.orangeGradient)
                    Circle().stroke(.white.opacity(0.35), lineWidth: 1).padding(1)
                } else {
                    Circle().fill(Theme.white08)
                    Circle().stroke(Theme.white15, lineWidth: 1)
                }
                Image(systemName: "lock")
                    .font(.system(size: size * 0.3, weight: .light))
                    .foregroundStyle(enabled ? Color.white : Theme.white40)
            }
            .frame(width: size, height: size)
            .shadow(color: enabled ? Theme.orangeMid.opacity(breathing ? 0.62 : 0.45) : .clear, radius: breathing ? 40 : 28)
            .shadow(color: enabled ? Theme.orangeDeep.opacity(breathing ? 0.36 : 0.28) : .clear, radius: breathing ? 70 : 55)
            .scaleEffect(breathing ? 1.035 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .accessibilityLabel(enabled ? "Lock" : "Lock unavailable")
        .onAppear {
            guard enabled else { return }
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}

/// Locked state: the Lock becomes a thin orange ring around a live session timer.
struct SessionRing: View {
    let seconds: Double
    let label: String
    var labelIsOrange = true
    var dim = false
    var size: CGFloat = 200

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.orangeMid.opacity(0.08), .clear], center: .center,
                                     startRadius: 0, endRadius: size * 0.7))
            Circle()
                .stroke(Theme.orangeGradient, lineWidth: 1.5)
                .opacity(dim ? 0.22 : 0.55)
            VStack(spacing: 6) {
                Text(StreakState.clock(seconds))
                    .font(.system(size: seconds >= 86_400 ? size * 0.17 : size * 0.22, weight: .ultraLight))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                TrackedLabel(text: label, color: labelIsOrange ? Theme.orangeMid : Theme.white40)
            }
            .padding(.horizontal, 14)
            .legibleOnPhoto()
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.orangeMid.opacity(0.14), radius: 30)
    }
}

/// "3h 00m" over a small RECORD label.
struct RecordStat: View {
    let seconds: Double

    var body: some View {
        VStack(spacing: 2) {
            Text(StreakState.format(seconds))
                .font(Theme.stat)
                .monospacedDigit()
                .foregroundStyle(.white)
            TrackedLabel(text: "RECORD")
        }
        .legibleOnPhoto()
    }
}
