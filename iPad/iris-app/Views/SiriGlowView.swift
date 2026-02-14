import SwiftUI

struct SiriGlowView: View {
    let isActive: Bool
    var audioLevel: Float = 0

    @State private var stops: [Gradient.Stop] = Self.generateStops()
    @State private var visible = false

    private var boost: CGFloat { CGFloat(min(audioLevel * 6, 1.0)) }

    private static let palette: [Color] = [
        Color(red: 0.74, green: 0.51, blue: 0.95),
        Color(red: 0.96, green: 0.73, blue: 0.92),
        Color(red: 0.55, green: 0.62, blue: 1.00),
        Color(red: 1.00, green: 0.40, blue: 0.47),
        Color(red: 1.00, green: 0.73, blue: 0.44),
        Color(red: 0.78, green: 0.53, blue: 1.00),
    ]

    private static func generateStops() -> [Gradient.Stop] {
        palette
            .map { Gradient.Stop(color: $0, location: Double.random(in: 0...1)) }
            .sorted { $0.location < $1.location }
    }

    var body: some View {
        let b = boost
        let gradient = AngularGradient(
            gradient: Gradient(stops: stops),
            center: .center
        )

        ZStack {
            glowRing(gradient: gradient, width: 16 + b * 22, blur: 20 + b * 12, opacity: 0.45 + Double(b) * 0.25)
                .animation(.easeInOut(duration: 1.0), value: stops)
            glowRing(gradient: gradient, width: 10 + b * 14, blur: 10 + b * 5, opacity: 0.6)
                .animation(.easeInOut(duration: 0.7), value: stops)
            glowRing(gradient: gradient, width: 7 + b * 6, blur: 3, opacity: 0.8)
                .animation(.easeInOut(duration: 0.5), value: stops)
            glowRing(gradient: gradient, width: 4, blur: 0.5, opacity: 0.95)
                .animation(.easeInOut(duration: 0.35), value: stops)
        }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.96)
        .onChange(of: isActive) { _, active in
            if active {
                withAnimation(.easeOut(duration: 0.1)) { visible = true }
            } else {
                withAnimation(.easeIn(duration: 0.08)) { visible = false }
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                stops = Self.generateStops()
                try? await Task.sleep(for: .seconds(0.28))
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func glowRing(gradient: AngularGradient, width: CGFloat, blur: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 26)
            .strokeBorder(gradient, lineWidth: width)
            .blur(radius: blur)
            .opacity(opacity)
    }
}
