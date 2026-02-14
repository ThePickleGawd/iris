import SwiftUI
import PencilKit

struct ToolbarView: View {
    @EnvironmentObject var canvasState: CanvasState
    var onBack: (() -> Void)?
    var onAITap: (() -> Void)?
    var onAITextTap: (() -> Void)?
    var isRecording: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .padding(.leading, 16)
            }

            Spacer().allowsHitTesting(false)

            // Center: Tool palette
            VStack(spacing: 4) {
                HStack(spacing: 2) {
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(white: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer().allowsHitTesting(false)

            if let onAITap {
                AIButton(isRecording: isRecording, action: onAITap, onTextPromptTap: onAITextTap)
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
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 36, height: 30)
                .background(isSelected ? Color.white.opacity(0.2) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct ToolbarColorCircle: View {
    let color: UIColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(uiColor: color))
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
                        .frame(width: 26, height: 26)
                )
        }
    }
}

// MARK: - AI Button

struct AIButton: View {
    let isRecording: Bool
    let action: () -> Void
    var onTextPromptTap: (() -> Void)? = nil

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Button(action: action) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(Color(white: 0.12).opacity(0.85))
                        .background(
                            Circle().fill(.ultraThinMaterial)
                        )
                        .clipShape(Circle())
                )
                .scaleEffect(pulseScale)
        }
        .contextMenu {
            if let onTextPromptTap {
                Button {
                    onTextPromptTap()
                } label: {
                    Label("Send Text Prompt", systemImage: "text.bubble")
                }
            }
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
