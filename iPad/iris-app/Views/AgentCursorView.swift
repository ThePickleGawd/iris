import SwiftUI

struct AgentCursorView: View {
    @ObservedObject var controller: AgentCursorController

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Click ripple
            if controller.isClicking {
                Circle()
                    .fill(controller.cursorColor.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .offset(x: controller.position.x - 18, y: controller.position.y - 18)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }

            // Cursor + label group
            CursorShape(color: controller.cursorColor)
                .scaleEffect(controller.isClicking ? 0.85 : 1.0, anchor: .topLeading)
                .offset(x: controller.position.x, y: controller.position.y)

            // Collaborator label
            if controller.showLabel {
                CollaboratorLabel(
                    name: controller.collaboratorName,
                    color: controller.cursorColor
                )
                .offset(
                    x: controller.position.x + 20,
                    y: controller.position.y + 28
                )
            }
        }
        .opacity(controller.isVisible ? 1 : 0)
        .scaleEffect(controller.isVisible ? 1 : 0.6, anchor: .topLeading)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - Cursor Shape

private struct CursorShape: View {
    let color: Color

    var body: some View {
        Canvas { context, _ in
            // Classic pointer arrow
            let path = Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 24))
                p.addLine(to: CGPoint(x: 6.5, y: 19))
                p.addLine(to: CGPoint(x: 11, y: 28))
                p.addLine(to: CGPoint(x: 14.5, y: 26.5))
                p.addLine(to: CGPoint(x: 10, y: 17.5))
                p.addLine(to: CGPoint(x: 17, y: 17))
                p.closeSubpath()
            }

            // Shadow
            context.drawLayer { shadow in
                shadow.addFilter(.shadow(color: .black.opacity(0.35), radius: 2, x: 0.5, y: 1))
                shadow.fill(path, with: .color(.white))
            }

            // White outline
            context.fill(path, with: .color(.white))

            // Color fill (inset)
            let insetPath = Path { p in
                p.move(to: CGPoint(x: 2.5, y: 4))
                p.addLine(to: CGPoint(x: 2.5, y: 20.5))
                p.addLine(to: CGPoint(x: 7, y: 17))
                p.addLine(to: CGPoint(x: 11.2, y: 25.5))
                p.addLine(to: CGPoint(x: 12.8, y: 24.8))
                p.addLine(to: CGPoint(x: 8.5, y: 16))
                p.addLine(to: CGPoint(x: 14, y: 15.5))
                p.closeSubpath()
            }
            context.fill(insetPath, with: .color(color))
        }
        .frame(width: 20, height: 30)
    }
}

// MARK: - Collaborator Label

private struct CollaboratorLabel: View {
    let name: String
    let color: Color

    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(color)
            )
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(white: 0.2).ignoresSafeArea()

        AgentCursorView(controller: {
            let c = AgentCursorController()
            c.position = CGPoint(x: 200, y: 300)
            c.isVisible = true
            return c
        }())
    }
}
