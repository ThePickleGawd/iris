import SwiftUI

@MainActor
final class AgentCursorController: ObservableObject {
    @Published var position: CGPoint = .zero
    @Published var isVisible: Bool = false
    @Published var isClicking: Bool = false

    var collaboratorName: String = "Iris"
    var cursorColor: Color = Color(red: 0.15, green: 0.64, blue: 0.90)

    func appear(at point: CGPoint) {
        position = point
        withAnimation(.easeOut(duration: 0.18)) { isVisible = true }
    }

    func disappear() {
        withAnimation(.easeIn(duration: 0.14)) { isVisible = false }
    }

    func moveTo(_ point: CGPoint, duration: TimeInterval = 0.28) {
        withAnimation(.easeInOut(duration: duration)) { position = point }
    }

    func click() {
        withAnimation(.easeOut(duration: 0.08)) { isClicking = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.12)) { self.isClicking = false }
        }
    }
}
