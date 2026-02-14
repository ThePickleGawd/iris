import SwiftUI

struct ToolbarView: View {
    @EnvironmentObject var canvasState: CanvasState

    var onBack: (() -> Void)?
    var onAITap: (() -> Void)?
    var isRecording: Bool = false

    // Compatibility hooks from newer call sites.
    var onAddWidget: (() -> Void)?
    var onSpeak: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(red: 0.03, green: 0.04, blue: 0.09).opacity(0.95))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.75)
                                )
                        )
                }
                .padding(.leading, 16)
            }

            Spacer().allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ToolbarToolButton(icon: "pencil.tip", isSelected: canvasState.currentTool == .pen) {
                        canvasState.currentTool = .pen
                    }
                    ToolbarToolButton(icon: "highlighter", isSelected: canvasState.currentTool == .highlighter) {
                        canvasState.currentTool = .highlighter
                    }
                    ToolbarToolButton(icon: "eraser", isSelected: canvasState.currentTool == .eraser) {
                        canvasState.currentTool = .eraser
                    }
                    ToolbarToolButton(icon: "lasso", isSelected: canvasState.currentTool == .lasso) {
                        canvasState.currentTool = .lasso
                    }

                    Rectangle()
                        .fill(.white.opacity(0.22))
                        .frame(width: 0.5, height: 16)
                        .padding(.horizontal, 1)

                    ToolbarPassiveButton(icon: "hand.draw")
                    ToolbarPassiveButton(icon: "chevron.right")
                }
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.white.opacity(0.16))
                        .frame(height: 0.5)
                        .padding(.horizontal, 2)
                }

                HStack(spacing: 6) {
                    ForEach(Array(CanvasState.availableColors.enumerated()), id: \.offset) { _, color in
                        ToolbarColorCircle(
                            color: color,
                            isSelected: color.isApproximatelyEqual(to: canvasState.currentColor)
                        ) {
                            canvasState.currentColor = color
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 7)
            }
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(red: 0.02, green: 0.03, blue: 0.08).opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 0.75)
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

            Spacer().allowsHitTesting(false)

            if let tap = onAITap ?? onSpeak {
                AIButton(isRecording: isRecording, action: tap)
                    .padding(.trailing, 16)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Toolbar Subviews

struct ToolbarToolButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isSelected ? .white : .white.opacity(0.78))
                .frame(width: 23, height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.17) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.white.opacity(isSelected ? 0.25 : 0), lineWidth: 0.75)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

struct ToolbarPassiveButton: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.72))
            .frame(width: 20, height: 21)
    }
}

struct ToolbarColorCircle: View {
    let color: UIColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: color))
                    .frame(width: 17, height: 17)

                Circle()
                    .stroke(Color.black.opacity(0.35), lineWidth: 0.75)
                    .frame(width: 17, height: 17)

                if isSelected {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AI Button

struct AIButton: View {
    let isRecording: Bool
    let action: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Button(action: action) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 36, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.03, green: 0.04, blue: 0.09).opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.75)
                        )
                )
                .scaleEffect(pulseScale)
        }
        .onChange(of: isRecording) { _, active in
            if active {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulseScale = 1.05
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    pulseScale = 1.0
                }
            }
        }
    }
}

#Preview {
    ZStack {
        Color.white
        VStack {
            ToolbarView()
                .environmentObject(CanvasState())
            Spacer()
        }
    }
}
