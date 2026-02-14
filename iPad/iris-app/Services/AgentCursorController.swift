import SwiftUI

@MainActor
final class AgentCursorController: ObservableObject {
    @Published var position: CGPoint = .zero
    @Published var isVisible: Bool = false
    @Published var isClicking: Bool = false
    @Published var showLabel: Bool = true

    var collaboratorName: String = "Iris"
    var cursorColor: Color = Color(red: 0.35, green: 0.8, blue: 0.65)

    func appear(at point: CGPoint) {
        position = point
        withAnimation(.easeOut(duration: 0.25)) {
            isVisible = true
        }
    }

    func disappear() {
        withAnimation(.easeIn(duration: 0.2)) {
            isVisible = false
        }
    }

    func moveTo(_ point: CGPoint, duration: TimeInterval = 0.6) {
        withAnimation(.spring(duration: duration, bounce: 0.12)) {
            position = point
        }
    }

    func moveAndClick(at point: CGPoint, moveDuration: TimeInterval = 0.6) {
        moveTo(point, duration: moveDuration)

        DispatchQueue.main.asyncAfter(deadline: .now() + moveDuration * 0.85) {
            self.click()
        }
    }

    func click() {
        withAnimation(.easeOut(duration: 0.08)) {
            isClicking = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.12)) {
                self.isClicking = false
            }
        }
    }

    func moveThrough(_ points: [CGPoint], interval: TimeInterval = 0.7) {
        for (i, point) in points.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                self.moveTo(point, duration: interval * 0.85)
            }
        }
    }
}
