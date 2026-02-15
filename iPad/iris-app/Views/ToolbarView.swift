import SwiftUI

private struct ModelChoice: Identifiable {
    let id: String
    let name: String
    let icon: String
    let accentColor: Color
}

private let generalModelChoices: [ModelChoice] = [
    ModelChoice(id: "gpt-5.2-mini", name: "GPT-5.2 Mini", icon: "bolt.fill", accentColor: Color(red: 0.39, green: 0.72, blue: 0.54)),
    ModelChoice(id: "gpt-5.2", name: "GPT-5.2", icon: "bolt.circle.fill", accentColor: Color(red: 0.39, green: 0.72, blue: 0.54)),
    ModelChoice(id: "gemini-3-flash", name: "Gemini 3 Flash", icon: "sparkle", accentColor: Color(red: 0.43, green: 0.68, blue: 0.95)),
    ModelChoice(id: "claude-opus-4-5", name: "Claude Opus 4.5", icon: "brain.head.profile.fill", accentColor: Color(red: 0.87, green: 0.58, blue: 0.38)),
    ModelChoice(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", icon: "brain.fill", accentColor: Color(red: 0.87, green: 0.58, blue: 0.38)),
]

private func modelMeta(for id: String) -> (icon: String, color: Color) {
    let lowered = id.lowercased()
    if let match = generalModelChoices.first(where: { $0.id.lowercased() == lowered }) {
        return (match.icon, match.accentColor)
    }
    if lowered.hasPrefix("gpt") { return ("bolt.fill", Color(red: 0.39, green: 0.72, blue: 0.54)) }
    if lowered.hasPrefix("gemini") { return ("sparkle", Color(red: 0.43, green: 0.68, blue: 0.95)) }
    if lowered.hasPrefix("claude") { return ("brain.fill", Color(red: 0.87, green: 0.58, blue: 0.38)) }
    return ("circle.grid.2x2.fill", Color.white.opacity(0.6))
}

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
                    modelID: doc.model,
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
    let modelID: String
    @Binding var showPicker: Bool

    var body: some View {
        let meta = modelMeta(for: modelID)
        Button { showPicker.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: meta.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(meta.color)
                Text(modelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
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
            ForEach(generalModelChoices) { choice in
                let isSelected = choice.id.lowercased() == currentModelID.lowercased()
                Button {
                    onSelect(choice.id)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(choice.accentColor.opacity(isSelected ? 0.22 : 0.12))
                                .frame(width: 28, height: 28)
                            Image(systemName: choice.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(choice.accentColor)
                        }

                        Text(choice.name)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .white : .white.opacity(0.8))

                        Spacer()

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(choice.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.07) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 240)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
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
