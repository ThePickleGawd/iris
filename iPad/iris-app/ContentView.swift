import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var canvasState: CanvasState

    let document: Document?
    var onBack: (() -> Void)?

    @StateObject private var objectManager = CanvasObjectManager()
    @StateObject private var cursor = AgentCursorController()

    @State private var speakText: String = ""

    private let speaker = AVSpeechSynthesizer()

    init(document: Document? = nil, onBack: (() -> Void)? = nil) {
        self.document = document
        self.onBack = onBack
    }
    @State private var sessionRegistered = false

    var body: some View {
        ZStack(alignment: .top) {
            CanvasView(document: document, objectManager: objectManager, cursor: cursor)
                .environmentObject(canvasState)

            ToolbarView(
                onBack: onBack,
                onAddWidget: addQuickWidget,
                onSpeak: speakCurrentText,
                onZoomIn: { objectManager.zoom(by: 0.06) },
                onZoomOut: { objectManager.zoom(by: -0.06) },
                onZoomReset: { objectManager.setZoomScale(1.0) }
            )
            .environmentObject(canvasState)
            .zIndex(20)

            AgentCursorView(controller: cursor)
                .zIndex(50)

            VStack {
                Spacer()
                HStack(spacing: 8) {
                    TextField("Type text for voice output and optional widget content", text: $speakText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button("Speak") { speakCurrentText() }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button("Widget") { addQuickWidget() }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.90))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .zIndex(30)
        }
        .ignoresSafeArea(.all, edges: .bottom)
    }

    private func speakCurrentText() {
        let raw = speakText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: raw)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        speaker.speak(utterance)
    }

    private func addQuickWidget() {
        let text = speakText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.isEmpty ? "New widget" : text
        let html = """
        <div class=\"card\">
            <h3>Widget</h3>
            <p>\(body.replacingOccurrences(of: "<", with: "&lt;"))</p>
        </div>
        """

        Task {
            _ = await objectManager.place(
                html: html,
                at: objectManager.viewportCenter,
                size: CGSize(width: 360, height: 210),
                animated: true
            )
        }
    }

}
