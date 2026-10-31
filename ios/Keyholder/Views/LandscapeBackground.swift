import SwiftUI

/// Mountains reflected in a still lake at dusk. Layered shapes and gradients in
/// black, grey and the orange accent, with a slow shimmer on the water and a
/// dark gradient at the bottom so white text stays readable.
struct LandscapeBackground: View {
    @State private var shimmer = false

    // Ridge outlines in a 375 x 452 design space (x, y). The horizon is at y = 452.
    private static let far: [CGPoint] = [
        (0, 332), (34, 298), (70, 318), (110, 272), (146, 300), (178, 262), (214, 296),
        (250, 270), (286, 304), (322, 280), (352, 300), (375, 288),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    private static let near: [CGPoint] = [
        (0, 390), (28, 372), (62, 384), (96, 356), (130, 380), (166, 362), (202, 384),
        (236, 368), (270, 388), (306, 372), (340, 386), (375, 374),
    ].map { CGPoint(x: $0.0, y: $0.1) }

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

                // Ridges
                RidgeShape(points: Self.far).fill(Color(hex: 0x2A2A2D)).frame(width: w, height: horizon)
                RidgeShape(points: Self.near).fill(Color(hex: 0x161617)).frame(width: w, height: horizon)

                // Lake
                LinearGradient(colors: [Color(hex: 0x26211D), Color(hex: 0x141313), Theme.ink],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: w, height: h - horizon)
                    .offset(y: horizon)

                // Reflected ridges, fading downward
                ZStack {
                    RidgeShape(points: Self.far).fill(Color(hex: 0x2A2A2D))
                    RidgeShape(points: Self.near).fill(Color(hex: 0x161617))
                }
                .frame(width: w, height: horizon)
                .scaleEffect(x: 1, y: -1, anchor: .bottom)
                .offset(y: horizon)
                .mask(
                    LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(width: w, height: horizon * 0.5)
                        .offset(y: horizon)
                        .frame(width: w, height: h, alignment: .topLeading)
                )

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

/// A ridge line in 375 x 452 design units, scaled to the frame and closed along the bottom.
struct RidgeShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let sx = rect.width / 375, sy = rect.height / 452
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + first.x * sx, y: rect.minY + first.y * sy))
        for p in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + p.x * sx, y: rect.minY + p.y * sy))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
