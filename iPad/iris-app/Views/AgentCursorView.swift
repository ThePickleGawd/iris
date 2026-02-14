import SwiftUI

struct AgentCursorView: View {
    @ObservedObject var controller: AgentCursorController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if controller.isClicking {
                Circle()
                    .fill(controller.cursorColor.opacity(0.28))
                    .frame(width: 34, height: 34)
                    .offset(x: controller.position.x - 17, y: controller.position.y - 17)
            }

            cursor
                .offset(x: controller.position.x, y: controller.position.y)
        }
        .opacity(controller.isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var cursor: some View {
        Canvas { context, _ in
            let path = Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 24))
                p.addLine(to: CGPoint(x: 7, y: 18))
                p.addLine(to: CGPoint(x: 11, y: 28))
                p.addLine(to: CGPoint(x: 14, y: 26.5))
                p.addLine(to: CGPoint(x: 10, y: 17.2))
                p.addLine(to: CGPoint(x: 17.5, y: 16.8))
                p.closeSubpath()
            }
            context.fill(path, with: .color(.white))

            let inset = Path { p in
                p.move(to: CGPoint(x: 2.5, y: 4))
                p.addLine(to: CGPoint(x: 2.5, y: 20))
                p.addLine(to: CGPoint(x: 7, y: 16.8))
                p.addLine(to: CGPoint(x: 11, y: 24.8))
                p.addLine(to: CGPoint(x: 12.4, y: 24.2))
                p.addLine(to: CGPoint(x: 8.5, y: 15.8))
                p.addLine(to: CGPoint(x: 13.7, y: 15.3))
                p.closeSubpath()
            }
            context.fill(inset, with: .color(controller.cursorColor))
        }
        .frame(width: 20, height: 30)
    }
}
