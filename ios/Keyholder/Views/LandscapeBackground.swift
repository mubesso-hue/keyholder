import SwiftUI

/// Dusk over still water. Gradients in black, grey and the orange accent, a slow
/// shimmer on the water and a dark gradient at the bottom so white text stays readable.
struct LandscapeBackground: View {
    @State private var shimmer = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let horizon = h * (452.0 / 812.0)

            ZStack(alignment: .topLeading) {
                Theme.ink

                // Sky
                LinearGradient(colors: [Theme.ink, Color(hex: 0x19191A), Color(hex: 0x332B26)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: w, height: horizon)

                // Warm glow sitting on the horizon
                RadialGradient(colors: [Theme.orangeMid.opacity(0.62), Theme.orangeMid.opacity(0.2), .clear],
                               center: .bottom, startRadius: 0, endRadius: w * 0.7)
                    .frame(width: w, height: horizon * 0.62)
                    .offset(y: horizon * 0.38)

                // Lake
                LinearGradient(colors: [Color(hex: 0x26211D), Color(hex: 0x141313), Theme.ink],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: w, height: h - horizon)
                    .offset(y: horizon)

                // Horizon line
                Rectangle().fill(.white.opacity(0.14)).frame(width: w, height: 1).offset(y: horizon)

                // Pool of light on the water
                Ellipse()
                    .fill(Theme.orangeMid.opacity(0.28))
                    .frame(width: w * 0.8, height: 60)
                    .blur(radius: 16)
                    .position(x: w / 2, y: horizon + 18)

                // Shimmer
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

                // Legibility overlay
                LinearGradient(stops: [
                    .init(color: Theme.ink.opacity(0), location: 0),
                    .init(color: Theme.ink.opacity(0.86), location: 0.5),
                    .init(color: Theme.ink.opacity(0.98), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(width: w, height: h - horizon - 48)
                .offset(y: horizon + 48)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { shimmer = true }
        }
    }
}
