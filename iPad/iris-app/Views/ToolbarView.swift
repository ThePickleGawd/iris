import SwiftUI

private let generalModelChoices: [(id: String, name: String)] = [
    ("gpt-5.2-mini", "GPT-5.2 Mini"),
    ("gpt-5.2", "GPT-5.2"),
    ("gemini-3-flash", "Gemini 3 Flash"),
    ("claude-opus-4-5", "Claude Opus 4.5"),
    ("claude-sonnet-4-5", "Claude Sonnet 4.5"),
]

struct ToolbarView: View {
    @EnvironmentObject var canvasState: CanvasState

    var onBack: (() -> Void)?
    var onAITap: (() -> Void)?
    var isRecording: Bool = false

    // Model selector
    var document: Document?
    var documentStore: DocumentStore?

    // Compatibility hooks from newer call sites.
    var onAddWidget: (() -> Void)?
    var onSpeak: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?
    var showAIButton: Bool = true

    @State private var showModelPicker = false

    var body: some View {
        HStack(spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(red: 0.03, green: 0.04, blue: 0.09).opacity(0.95))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.75)
                                )
                        )
                }
                .padding(.leading, 18)
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
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
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
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
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

            if let doc = document, doc.isGeneralChat {
                ModelSelectorButton(
                    modelName: doc.modelDisplayName,
                    showPicker: $showModelPicker
                )
                .popover(isPresented: $showModelPicker, arrowEdge: .top) {
                    ModelPickerPopover(
                        currentModelID: doc.model,
                        onSelect: { newModel in
                            showModelPicker = false
                            documentStore?.updateModel(doc, to: newModel)
                        }
                    )
                }
                .padding(.trailing, showAIButton ? 8 : 18)
            }

            if showAIButton, let tap = onAITap ?? onSpeak {
                AIButton(isRecording: isRecording, action: tap)
                    .padding(.trailing, 18)
            }
        }
        .padding(.top, 10)
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
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isSelected ? .white : .white.opacity(0.78))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.17) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
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
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(.white.opacity(0.72))
            .frame(width: 26, height: 26)
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

// MARK: - Model Selector

struct ModelSelectorButton: View {
    let modelName: String
    @Binding var showPicker: Bool

    var body: some View {
        Button { showPicker.toggle() } label: {
            HStack(spacing: 6) {
                Text(modelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.03, green: 0.04, blue: 0.09).opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct ModelPickerPopover: View {
    let currentModelID: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(generalModelChoices, id: \.id) { choice in
                let isSelected = choice.id.lowercased() == currentModelID.lowercased()
                Button {
                    onSelect(choice.id)
                } label: {
                    HStack(spacing: 8) {
                        Text(choice.name)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .white : .white.opacity(0.8))
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 220)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - AI Button

struct AIButton: View {
    let isRecording: Bool
    var isAvailable: Bool = true
    let action: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Button(action: action) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(isAvailable ? 0.9 : 0.3))
                .frame(width: 44, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.03, green: 0.04, blue: 0.09).opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(isAvailable ? 0.15 : 0.08), lineWidth: 0.75)
                        )
                )
                .scaleEffect(pulseScale)
        }
        .disabled(!isAvailable)
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
