import SwiftUI
import UIKit

/// The eight generated nature scenes in the asset catalog. A different one is
/// shown on every launch, in order, starting from a random point.
enum BackgroundLibrary {
    static let names: [String] = (1...8).map { String(format: "bg-%02d", $0) }

    /// Chosen once per process, so it stays put while the app is open and
    /// changes the next time the app is launched.
    static let current: String = {
        let key = "backgroundIndex"
        let defaults = UserDefaults.standard
        let next: Int
        if let last = defaults.object(forKey: key) as? Int {
            next = (last + 1) % names.count
        } else {
            next = Int.random(in: 0..<names.count)
        }
        defaults.set(next, forKey: key)
        return names[next]
    }()
}

/// Full-bleed nature photo with legibility gradients. Falls back to a drawn
/// dusk-over-water gradient if the image is missing from the bundle.
struct LandscapeBackground: View {
    var imageName: String = BackgroundLibrary.current

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = UIImage(named: imageName) {
                    // 1. The scene, full-bleed.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    // 2. The same scene blurred, faded in over the lower half, so the
                    //    record and actions sit on frosted scenery, not busy detail.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 26)
                        .saturation(1.15)
                        .scaleEffect(1.12)
                        .clipped()
                        .mask(
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0.46),
                                .init(color: .black, location: 0.70),
                            ], startPoint: .top, endPoint: .bottom)
                        )
                    // 3. One continuous tonal gradient: deeper at the top for the
                    //    header and headline, lightest around the Lock, deep at the bottom.
                    LinearGradient(stops: [
                        .init(color: Theme.ink.opacity(0.58), location: 0.00),
                        .init(color: Theme.ink.opacity(0.42), location: 0.18),
                        .init(color: Theme.ink.opacity(0.28), location: 0.34),
                        .init(color: Theme.ink.opacity(0.14), location: 0.46),
                        .init(color: Theme.ink.opacity(0.14), location: 0.54),
                        .init(color: Theme.ink.opacity(0.36), location: 0.66),
                        .init(color: Theme.ink.opacity(0.72), location: 0.84),
                        .init(color: Theme.ink.opacity(0.88), location: 1.00),
                    ], startPoint: .top, endPoint: .bottom)
                } else {
                    GradientDusk()
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Drawn fallback: dusk sky, warm glow, still water, shimmer.
struct GradientDusk: View {
    @State private var shimmer = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let horizon = h * (452.0 / 812.0)

            ZStack(alignment: .topLeading) {
                Theme.ink

                LinearGradient(colors: [Theme.ink, Color(hex: 0x19191A), Color(hex: 0x332B26)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: w, height: horizon)

                RadialGradient(colors: [Theme.orangeMid.opacity(0.62), Theme.orangeMid.opacity(0.2), .clear],
                               center: .bottom, startRadius: 0, endRadius: w * 0.7)
                    .frame(width: w, height: horizon * 0.62)
                    .offset(y: horizon * 0.38)

                LinearGradient(colors: [Color(hex: 0x26211D), Color(hex: 0x141313), Theme.ink],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: w, height: h - horizon)
                    .offset(y: horizon)

                Rectangle().fill(.white.opacity(0.14)).frame(width: w, height: 1).offset(y: horizon)

                Ellipse()
                    .fill(Theme.orangeMid.opacity(0.28))
                    .frame(width: w * 0.8, height: 60)
                    .blur(radius: 16)
                    .position(x: w / 2, y: horizon + 18)

                VStack(spacing: 17) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(LinearGradient(colors: [.clear, .white.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(width: w * (0.68 - CGFloat(i) * 0.15), height: 1)
                    }
                }
                .frame(width: w)
                .offset(x: shimmer ? 8 : -8, y: horizon + 22)
                .opacity(shimmer ? 1 : 0.55)

                LinearGradient(stops: [
                    .init(color: Theme.ink.opacity(0), location: 0),
                    .init(color: Theme.ink.opacity(0.86), location: 0.5),
                    .init(color: Theme.ink.opacity(0.98), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(width: w, height: h - horizon - 48)
                .offset(y: horizon + 48)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { shimmer = true }
        }
    }
}

/// The current scene, heavily blurred and darkened: a calm backdrop for flows
/// full of text and controls, such as Lock.
struct BlurredLandscape: View {
    var imageName: String = BackgroundLibrary.current

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = UIImage(named: imageName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 32)
                        .saturation(1.15)
                        .scaleEffect(1.15)
                        .clipped()
                } else {
                    Theme.ink
                }
                LinearGradient(stops: [
                    .init(color: Theme.ink.opacity(0.50), location: 0.0),
                    .init(color: Theme.ink.opacity(0.58), location: 0.5),
                    .init(color: Theme.ink.opacity(0.86), location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}
