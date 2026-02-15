import SwiftUI

// MARK: - Provider Logos (inline paths)

private enum ModelProvider {
    case openai
    case google
    case anthropic
    case unknown

    var color: Color {
        switch self {
        case .openai:    return .white
        case .google:    return Color(red: 0.52, green: 0.67, blue: 0.98) // Google blue
        case .anthropic: return Color(red: 0.85, green: 0.65, blue: 0.47) // Anthropic tan
        case .unknown:   return Color.white.opacity(0.6)
        }
    }
}

private func providerFor(_ modelID: String) -> ModelProvider {
    let l = modelID.lowercased()
    if l.hasPrefix("gpt") || l.hasPrefix("o1") || l.hasPrefix("o3") || l.hasPrefix("o4") { return .openai }
    if l.hasPrefix("gemini") { return .google }
    if l.hasPrefix("claude") { return .anthropic }
    return .unknown
}

/// OpenAI hexagon logo — simplified path at 12×12
private struct OpenAILogo: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX, cy = rect.midY
        var p = Path()
        // Outer hexagon
        for i in 0..<6 {
            let angle = Angle.degrees(Double(i) * 60 - 90)
            let x = cx + cos(angle.radians) * s * 0.48
            let y = cy + sin(angle.radians) * s * 0.48
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        // Inner spokes (3 lines from center toward alternating vertices)
        for i in stride(from: 0, to: 6, by: 2) {
            let angle = Angle.degrees(Double(i) * 60 - 90)
            p.move(to: CGPoint(x: cx, y: cy))
            p.addLine(to: CGPoint(
                x: cx + cos(angle.radians) * s * 0.32,
                y: cy + sin(angle.radians) * s * 0.32
            ))
        }
        return p
    }
}

/// Google four-color "G" — simplified as four arc segments
private struct GoogleLogo: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX, cy = rect.midY
        let r = s * 0.42
        var p = Path()
        // Full circle
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        // Horizontal bar (the dash of the G)
        p.move(to: CGPoint(x: cx, y: cy))
        p.addLine(to: CGPoint(x: cx + r, y: cy))
        return p
    }
}

/// Anthropic — stylized "A" spark
private struct AnthropicLogo: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let ox = rect.minX, oy = rect.minY
        var p = Path()
        // Upward triangle "A" shape
        p.move(to: CGPoint(x: ox + w * 0.5, y: oy + h * 0.08))
        p.addLine(to: CGPoint(x: ox + w * 0.15, y: oy + h * 0.92))
        p.addLine(to: CGPoint(x: ox + w * 0.35, y: oy + h * 0.92))
        p.addLine(to: CGPoint(x: ox + w * 0.5, y: oy + h * 0.52))
        p.addLine(to: CGPoint(x: ox + w * 0.65, y: oy + h * 0.92))
        p.addLine(to: CGPoint(x: ox + w * 0.85, y: oy + h * 0.92))
        p.closeSubpath()
        return p
    }
}

private struct ProviderIcon: View {
    let provider: ModelProvider
    let size: CGFloat

    var body: some View {
        Group {
            switch provider {
            case .openai:
                OpenAILogo()
                    .stroke(provider.color, lineWidth: 1.2)
                    .frame(width: size, height: size)
            case .google:
                GoogleLogo()
                    .stroke(provider.color, lineWidth: 1.4)
                    .frame(width: size, height: size)
            case .anthropic:
                AnthropicLogo()
                    .fill(provider.color)
                    .frame(width: size, height: size)
            case .unknown:
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: size * 0.75))
                    .foregroundColor(provider.color)
            }
        }
    }
}

// MARK: - Model Choices

private struct ModelChoice: Identifiable {
    let id: String
    let name: String
    let provider: ModelProvider
}

private let generalModelChoices: [ModelChoice] = [
    ModelChoice(id: "gpt-5.2-mini", name: "GPT-5.2 Mini", provider: .openai),
    ModelChoice(id: "gpt-5.2", name: "GPT-5.2", provider: .openai),
    ModelChoice(id: "gemini-3-flash", name: "Gemini 3 Flash", provider: .google),
    ModelChoice(id: "claude-opus-4-5", name: "Claude Opus 4.5", provider: .anthropic),
    ModelChoice(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", provider: .anthropic),
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
        let provider = providerFor(modelID)
        Button { showPicker.toggle() } label: {
            HStack(spacing: 7) {
                ProviderIcon(provider: provider, size: 13)
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
                                .fill(choice.provider.color.opacity(isSelected ? 0.22 : 0.12))
                                .frame(width: 28, height: 28)
                            ProviderIcon(provider: choice.provider, size: 14)
                        }

                        Text(choice.name)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .white : .white.opacity(0.8))

                        Spacer()

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(choice.provider.color)
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
