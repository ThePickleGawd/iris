import SwiftUI

@MainActor
final class AgentCursorController: ObservableObject {
    @Published var position: CGPoint = .zero
    @Published var isVisible: Bool = false
    @Published var isClicking: Bool = false
    @Published var showLabel: Bool = true

    var collaboratorName: String = "Iris"
    var cursorColor: Color = Color(red: 0.69, green: 0.32, blue: 0.87)
    // Small calibration so the visible arrow tip sits on the stroke path.
    var hotspotOffset: CGPoint = CGPoint(x: 0.0, y: 10.0)
    // 5x duration = 1/5 movement speed.
    private let movementDurationScale: TimeInterval = 5.0

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
        let adjusted = max(0.01, duration * movementDurationScale)
        withAnimation(.spring(duration: adjusted, bounce: 0.12)) {
            position = point
        }
    }

    func moveAndClick(at point: CGPoint, moveDuration: TimeInterval = 0.6) {
        let adjusted = max(0.01, moveDuration * movementDurationScale)
        moveTo(point, duration: moveDuration)

        DispatchQueue.main.asyncAfter(deadline: .now() + adjusted * 0.85) {
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
        let adjustedInterval = max(0.01, interval * movementDurationScale)
        for (i, point) in points.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + adjustedInterval * Double(i)) {
                self.moveTo(point, duration: interval * 0.85)
            }
        }
    }
}
