import SwiftUI

/// Controls an AI collaborator cursor overlay.
///
/// Usage:
/// ```swift
/// let cursor = AgentCursorController()
/// cursor.appear(at: CGPoint(x: 100, y: 100))
/// cursor.moveTo(CGPoint(x: 400, y: 300))
/// cursor.click()
/// cursor.disappear()
/// ```
@MainActor
class AgentCursorController: ObservableObject {
    @Published var position: CGPoint = .zero
    @Published var isVisible: Bool = false
    @Published var isClicking: Bool = false
    @Published var showLabel: Bool = true

    var collaboratorName: String = "Iris"
    var cursorColor: Color = Color(red: 0.35, green: 0.8, blue: 0.65)

    // MARK: - Public API

    /// Show the cursor at a position.
    func appear(at point: CGPoint) {
        position = point
        withAnimation(.easeOut(duration: 0.25)) {
            isVisible = true
        }
    }

    /// Hide the cursor.
    func disappear() {
        withAnimation(.easeIn(duration: 0.2)) {
            isVisible = false
        }
    }

    /// Smoothly animate the cursor to a point.
    func moveTo(_ point: CGPoint, duration: TimeInterval = 0.6) {
        withAnimation(.spring(duration: duration, bounce: 0.12)) {
            position = point
        }
    }

    /// Move to a point, then perform a click animation.
    func moveAndClick(at point: CGPoint, moveDuration: TimeInterval = 0.6) {
        moveTo(point, duration: moveDuration)

        DispatchQueue.main.asyncAfter(deadline: .now() + moveDuration * 0.85) {
            self.click()
        }
    }

    /// Click at the current position.
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

    /// Sequence of moves — animates through each point in order.
    func moveThrough(_ points: [CGPoint], interval: TimeInterval = 0.7) {
        for (i, point) in points.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                self.moveTo(point, duration: interval * 0.85)
            }
        }
    }
}
