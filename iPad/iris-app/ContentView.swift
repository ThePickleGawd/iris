import SwiftUI

struct ContentView: View {
    @EnvironmentObject var canvasState: CanvasState

    let document: Document
    var onBack: (() -> Void)?

    @StateObject private var objectManager = CanvasObjectManager()
    @StateObject private var cursor = AgentCursorController()
    @StateObject private var audioService = AudioCaptureService()
    @StateObject private var transcriber = SpeechTranscriber()

    @State private var isProcessing = false
    @State private var lastResponse: String?

    var body: some View {
        ZStack(alignment: .top) {
            CanvasView(document: document, objectManager: objectManager, cursor: cursor)
                .environmentObject(canvasState)

            SiriGlowView(isActive: canvasState.isRecording, audioLevel: audioService.audioLevel)

            ToolbarView(
                onBack: onBack,
                onAITap: { canvasState.isRecording.toggle() },
                isRecording: canvasState.isRecording,
                onZoomIn: { objectManager.zoom(by: 0.06) },
                onZoomOut: { objectManager.zoom(by: -0.06) },
                onZoomReset: { objectManager.setZoomScale(1.0) }
            )
            .environmentObject(canvasState)
            .zIndex(20)

            AgentCursorView(controller: cursor)
                .zIndex(50)

            if isProcessing {
                processingIndicator
            }

            if let response = lastResponse {
                responseToast(response)
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
        }
    }

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
        let transcript = transcriber.stopTranscribing().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        sendPromptToAgent(transcript)
    }

    private func sendPromptToAgent(_ prompt: String) {
        guard let serverURL = objectManager.httpServer.agentServerURL() else {
            withAnimation { lastResponse = "No linked Mac found. Open the Iris Mac app first." }
            autoDismissResponse()
            return
        }

        isProcessing = true

        Task {
            do {
                var message = prompt
                var screenshotID: String?
                var screenshotUploadWarning: String?
                if let backendURL = objectManager.httpServer.backendServerURL() {
                    do {
                        screenshotID = try await uploadCurrentCanvasScreenshot(prompt: prompt, backendURL: backendURL)
                    } catch {
                        screenshotUploadWarning = error.localizedDescription
                    }
                }

                if document.agent == "iris", let screenshotID {
                    if !screenshotID.isEmpty {
                        message = """
                        User voice command:
                        \(prompt)

                        I uploaded an iPad canvas screenshot with device_id "ipad" and screenshot id \(screenshotID).
                        First call read_screenshot for device "ipad" to inspect the drawing.
                        Then create and push iPad widgets matching the drawing.
                        """
                    }
                }

                let response = try await AgentClient.sendMessage(
                    message,
                    agent: document.agent,
                    chatID: document.id.uuidString,
                    serverURL: serverURL
                )
                await MainActor.run {
                    if let screenshotUploadWarning {
                        withAnimation { lastResponse = "Screenshot upload warning: \(screenshotUploadWarning)\n\n\(response)" }
                    } else {
                        withAnimation { lastResponse = response }
                    }
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

    @MainActor
    private func uploadCurrentCanvasScreenshot(prompt: String, backendURL: URL) async throws -> String? {
        guard let pngData = objectManager.captureViewportPNGData() else {
            return nil
        }

        return try await BackendClient.uploadScreenshot(
            pngData: pngData,
            deviceID: "ipad",
            backendURL: backendURL,
            notes: "Voice command: \(prompt.prefix(180))"
        )
    }

    private func autoDismissResponse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            withAnimation { lastResponse = nil }
        }
    }

    private func responseToast(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .padding(16)
                .frame(maxWidth: 560, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(white: 0.12))
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .onTapGesture {
                    withAnimation { lastResponse = nil }
                }
        }
        .zIndex(30)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var processingIndicator: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Thinking...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(white: 0.12)))
            .padding(.bottom, 30)
        }
        .zIndex(25)
    }
}
