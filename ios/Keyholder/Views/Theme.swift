import SwiftUI

/// The whole palette: black, white at three opacities, and one orange gradient.
enum Theme {
    static let ink = Color(hex: 0x0A0A0A)
    /// Secondary type. Over the photo backgrounds 60% white washes out on bright
    /// skies, so this sits at 90% and the label tone at 72%.
    static let white60 = Color.white.opacity(0.9)
    static let white40 = Color.white.opacity(0.72)
    static let white15 = Color.white.opacity(0.15)
    static let white08 = Color.white.opacity(0.08)

    static let orangeLight = Color(hex: 0xFFB347)
    static let orangeMid = Color(hex: 0xFF7A00)
    static let orangeDeep = Color(hex: 0xFF4D00)

    static var orangeGradient: LinearGradient {
        LinearGradient(colors: [orangeLight, orangeMid, orangeDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func headline(_ size: CGFloat = 46) -> Font {
        .system(size: size, weight: .bold)
    }

    static let sub = Font.system(size: 17, weight: .medium)
    static let helper = Font.system(size: 14, weight: .medium)
    static let label = Font.system(size: 11, weight: .semibold)
    static let stat = Font.system(size: 30, weight: .light)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Small label with wide tracking: "RECORD", "LOCKED", "KEYS YOU HOLD". Callers pass the casing.
struct TrackedLabel: View {
    let text: String
    var color: Color = Theme.white40

    var body: some View {
        Text(text)
            .font(Theme.label)
            .tracking(2)
            .foregroundStyle(color)
    }
}

/// Frosted glass: blur, white at 8%, 1pt border at 15%.
struct Glass: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.white08))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Theme.white15, lineWidth: 1))
            }
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 18) -> some View { modifier(Glass(cornerRadius: cornerRadius)) }
}

/// Secondary action: a frosted pill.
struct GlassPillStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 15, weight: .medium))
            .foregroundStyle(.white)
            .padding(.vertical, compact ? 8 : 12)
            .padding(.horizontal, compact ? 12 : 22)
            .background {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Theme.white08))
                    .overlay(Capsule().stroke(Theme.white15, lineWidth: 1))
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Hairline shadow so white type holds on the lighter parts of a scene.
    func legibleOnPhoto() -> some View {
        self
            .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
    }
}

/// Shrinks slightly while pressed. Used by the hero Lock button.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
