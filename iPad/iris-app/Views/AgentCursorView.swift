import SwiftUI

struct AgentCursorView: View {
    @ObservedObject var controller: AgentCursorController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if controller.isClicking {
                Circle()
                    .fill(controller.cursorColor.opacity(0.3))
                    .frame(width: 40, height: 40)
                    .offset(x: controller.position.x - 20, y: controller.position.y - 20)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }

            CursorShape(color: controller.cursorColor)
                .scaleEffect(controller.isClicking ? 0.85 : 1.0, anchor: .topLeading)
                .offset(
                    x: controller.position.x + controller.hotspotOffset.x,
                    y: controller.position.y + controller.hotspotOffset.y
                )

            if controller.showLabel {
                CollaboratorLabel(
                    name: controller.collaboratorName,
                    color: controller.cursorColor
                )
                .offset(
                    x: controller.position.x + 14,
                    y: controller.position.y + 24
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            // Outer arrow — solid color with shadow
            let path = Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 26))
                p.addLine(to: CGPoint(x: 7, y: 20))
                p.addLine(to: CGPoint(x: 12, y: 30))
                p.addLine(to: CGPoint(x: 16, y: 28))
                p.addLine(to: CGPoint(x: 11, y: 18))
                p.addLine(to: CGPoint(x: 19, y: 18))
                p.closeSubpath()
            }

            context.drawLayer { shadow in
                shadow.addFilter(.shadow(color: .black.opacity(0.25), radius: 3, x: 0.5, y: 1.5))
                shadow.fill(path, with: .color(color))
            }

            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(.white.opacity(0.92)), lineWidth: 1.1)

            // Subtle inner highlight for depth
            let highlight = Path { p in
                p.move(to: CGPoint(x: 2.5, y: 4))
                p.addLine(to: CGPoint(x: 2.5, y: 21))
                p.addLine(to: CGPoint(x: 7.5, y: 17))
                p.closeSubpath()
            }
            context.fill(highlight, with: .color(.white.opacity(0.18)))
        }
        .frame(width: 24, height: 34)
    }
}

// MARK: - Collaborator Label

private struct CollaboratorLabel: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            // Small triangular tail pointing left toward the cursor
            Canvas { context, size in
                let path = Path { p in
                    p.move(to: CGPoint(x: size.width, y: size.height * 0.3))
                    p.addLine(to: CGPoint(x: 0, y: size.height * 0.5))
                    p.addLine(to: CGPoint(x: size.width, y: size.height * 0.7))
                    p.closeSubpath()
                }
                context.fill(path, with: .color(color))
            }
            .frame(width: 6, height: 24)

            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color)
                )
        }
    }
}
