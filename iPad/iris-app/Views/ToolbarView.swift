import SwiftUI

struct ToolbarView: View {
    @EnvironmentObject var canvasState: CanvasState

    var onBack: (() -> Void)?
    var onAddWidget: (() -> Void)?
    var onSpeak: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                iconButton("chevron.left", action: onBack)
            }

            toolPill

            Spacer(minLength: 8)

            zoomPill

            if let onAddWidget {
                textButton("Widget", icon: "rectangle.on.rectangle", action: onAddWidget)
            }

            if let onSpeak {
                textButton("Speak", icon: "speaker.wave.2.fill", action: onSpeak)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var toolPill: some View {
        HStack(spacing: 6) {
            toolButton("pencil.tip", selected: canvasState.currentTool == .pen) {
                canvasState.currentTool = .pen
            }
            toolButton("highlighter", selected: canvasState.currentTool == .highlighter) {
                canvasState.currentTool = .highlighter
            }
            toolButton("eraser", selected: canvasState.currentTool == .eraser) {
                canvasState.currentTool = .eraser
            }

            ForEach(Array(CanvasState.availableColors.enumerated()), id: \.offset) { _, c in
                Button {
                    canvasState.currentColor = c
                } label: {
                    Circle()
                        .fill(Color(uiColor: c))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().stroke(Color.white, lineWidth: isApproxColor(canvasState.currentColor, c) ? 2 : 0)
                        )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private var zoomPill: some View {
        HStack(spacing: 4) {
            iconButton("minus.magnifyingglass") { onZoomOut?() }
            Button {
                onZoomReset?()
            } label: {
                Text(String(format: "%.2fx", canvasState.currentZoomScale))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(width: 54, height: 30)
                    .background(Color.white.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            iconButton("plus.magnifyingglass") { onZoomIn?() }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private func iconButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func textButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }
    }

    private func toolButton(_ icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(selected ? .white : .primary)
                .frame(width: 30, height: 30)
                .background(selected ? Color.blue : Color.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func isApproxColor(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
        var lr: CGFloat = 0; var lg: CGFloat = 0; var lb: CGFloat = 0; var la: CGFloat = 0
        var rr: CGFloat = 0; var rg: CGFloat = 0; var rb: CGFloat = 0; var ra: CGFloat = 0
        lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        return abs(lr - rr) < 0.02 && abs(lg - rg) < 0.02 && abs(lb - rb) < 0.02 && abs(la - ra) < 0.02
    }
}
