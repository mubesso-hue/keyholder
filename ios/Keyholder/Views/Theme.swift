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

    /// Break Glass only. The one place red appears.
    static let breakRed = Color(hex: 0xE5484D)
    static let breakRedDeep = Color(hex: 0xC4262C)

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
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, compact ? 8 : 14)
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

/// The main answer on a card: orange, with dark type for contrast.
struct OrangePillStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 15)
            .padding(.horizontal, 22)
            .background(Capsule().fill(Theme.orangeGradient))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A quiet destructive action, such as ending someone's block.
struct DangerOutlinePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(hex: 0xFF9A9C))
            .padding(.vertical, 14)
            .padding(.horizontal, 28)
            .background {
                Capsule().fill(Theme.breakRed.opacity(0.14))
                    .overlay(Capsule().stroke(Theme.breakRed.opacity(0.55), lineWidth: 1))
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Something waiting for your answer: glass tinted orange.
struct AttentionCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.orangeMid.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.orangeLight.opacity(0.45), lineWidth: 1))
            }
    }
}

extension View {
    func attentionCard() -> some View { modifier(AttentionCard()) }
}

/// Break Glass: a solid red pill, so the way out is always in plain sight.
struct BreakGlassPillStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, 22)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [Theme.breakRed, Theme.breakRedDeep],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: Theme.breakRedDeep.opacity(0.35), radius: 14, y: 6)
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
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
