import SwiftUI
import PencilKit

struct ContentView: View {
    @EnvironmentObject var canvasState: CanvasState
    @StateObject private var audioService = AudioCaptureService()
    @StateObject private var transcriber = SpeechTranscriber()
    @StateObject private var cursor = AgentCursorController()
    @StateObject private var objectManager = CanvasObjectManager()
    let document: Document
    var onBack: (() -> Void)?

    @State private var isProcessing = false
    @State private var lastResponse: String?
    @State private var sessionRegistered = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                CanvasView(document: document, objectManager: objectManager, cursor: cursor)
                    .environmentObject(canvasState)

                SiriGlowView(isActive: canvasState.isRecording, audioLevel: audioService.audioLevel)

                ToolbarView(
                    onBack: onBack,
                    onAITap: { canvasState.isRecording.toggle() },
                    isRecording: canvasState.isRecording
                )
                .environmentObject(canvasState)
                .allowsHitTesting(true)

                AgentCursorView(controller: cursor)

                // Response toast
                if let response = lastResponse {
                    responseToast(response)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Processing indicator
                if isProcessing {
                    processingIndicator
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .onChange(of: canvasState.isRecording) { _, recording in
            if recording {
                startRecording()
            } else {
                stopRecordingAndSend()
            }
        }
        .onDisappear {
            canvasState.isRecording = false
            audioService.stopCapture()
        }
        .onAppear {
            SpeechTranscriber.requestAuthorization { _ in }
            registerSessionIfNeeded()
        }
    }

    // MARK: - Session Registration

    private func registerSessionIfNeeded() {
        guard !sessionRegistered else { return }
        guard let serverURL = objectManager.httpServer.agentServerURL() else { return }
        sessionRegistered = true
        Task {
            await AgentClient.registerSession(
                id: document.id.uuidString,
                name: document.name,
                agent: document.agent,
                serverURL: serverURL
            )
        }
    }

    // MARK: - Recording Flow

    private func startRecording() {
        lastResponse = nil
        transcriber.startTranscribing()
        audioService.onAudioBuffer = { [weak transcriber] buffer in
            transcriber?.appendBuffer(buffer)
        }
        audioService.startCapture()
    }

    private func stopRecordingAndSend() {
        audioService.stopCapture()
        let transcript = transcriber.stopTranscribing()

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let serverURL = objectManager.httpServer.agentServerURL() else {
            withAnimation { lastResponse = "No linked Mac found — open the iris Mac app first." }
            autoDismissResponse()
            return
        }

        isProcessing = true

        Task {
            do {
                let response = try await AgentClient.sendMessage(
                    transcript,
                    agent: document.agent,
                    chatID: document.id.uuidString,
                    serverURL: serverURL
                )
                await MainActor.run {
                    withAnimation { lastResponse = response }
                    isProcessing = false
                    autoDismissResponse()
                }
            } catch {
                await MainActor.run {
                    withAnimation { lastResponse = "Error: \(error.localizedDescription)" }
                    isProcessing = false
                    autoDismissResponse()
                }
            }
        }
    }

    private func autoDismissResponse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            withAnimation { lastResponse = nil }
        }
    }

    // MARK: - UI Components

    private func responseToast(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .padding(16)
                .frame(maxWidth: 500, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(white: 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
                .onTapGesture {
                    withAnimation { lastResponse = nil }
                }
        }
    }

    private var processingIndicator: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("Thinking...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color(white: 0.12))
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                    )
            )
            .padding(.bottom, 40)
        }
    }
}

#Preview {
    ContentView(document: Document(name: "Preview"))
        .environmentObject(CanvasState())
}
