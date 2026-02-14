import SwiftUI
import UIKit

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
    @AppStorage("iris_auto_widget_suggest_enabled") private var autoWidgetSuggestEnabled = false
    @AppStorage("iris_auto_widget_suggest_debug") private var autoWidgetSuggestDebugEnabled = true
    @State private var lastAutoSignature: [UInt8]?
    @State private var lastAutoAttemptAt: Date = .distantPast
    @State private var autoSuggestTask: Task<Void, Never>?
    @State private var autoSuggestStatus: String = "Disabled"
    @State private var autoSuggestLastDiff: Double = 0
    @State private var autoSuggestTickCount: Int = 0
    @State private var autoSuggestLastModelPreview: String = ""

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

            autoSuggestToggle
                .zIndex(21)

            if autoWidgetSuggestDebugEnabled {
                autoSuggestDebugPanel
                    .zIndex(21)
            }

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
            autoSuggestTask?.cancel()
            autoSuggestTask = nil
        }
        .onAppear {
            SpeechTranscriber.requestAuthorization { _ in }
            startAutoSuggestLoopIfNeeded()
        }
        .onChange(of: autoWidgetSuggestEnabled) { _, _ in
            startAutoSuggestLoopIfNeeded()
        }
        .onChange(of: autoWidgetSuggestDebugEnabled) { _, _ in
            updateAutoSuggestStatus(autoWidgetSuggestEnabled ? "Enabled" : "Disabled")
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

    private var autoSuggestToggle: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Toggle(isOn: $autoWidgetSuggestEnabled) {
                        Text("Auto Suggest")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .blue))

                    Toggle(isOn: $autoWidgetSuggestDebugEnabled) {
                        Text("Debug")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.top, 62)
            .padding(.trailing, 14)
            Spacer()
        }
    }

    private var autoSuggestDebugPanel: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("AutoSuggest: \(autoSuggestStatus)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(String(format: "ticks=%d diff=%.4f", autoSuggestTickCount, autoSuggestLastDiff))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.82))
                    if !autoSuggestLastModelPreview.isEmpty {
                        Text(autoSuggestLastModelPreview)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.74))
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.62))
                )
            }
            .padding(.top, 108)
            .padding(.trailing, 14)
            Spacer()
        }
    }

    private func startAutoSuggestLoopIfNeeded() {
        autoSuggestTask?.cancel()
        autoSuggestTask = nil

        guard autoWidgetSuggestEnabled else {
            updateAutoSuggestStatus("Disabled")
            return
        }

        updateAutoSuggestStatus("Enabled")

        autoSuggestTask = Task {
            while !Task.isCancelled {
                await runAutoSuggestTick()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    @MainActor
    private func runAutoSuggestTick() async {
        autoSuggestTickCount += 1

        guard autoWidgetSuggestEnabled else {
            updateAutoSuggestStatus("Disabled")
            return
        }
        guard !canvasState.isRecording else {
            updateAutoSuggestStatus("Skip: recording")
            return
        }
        guard !isProcessing else {
            updateAutoSuggestStatus("Skip: busy")
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastAutoAttemptAt) >= 8 else {
            updateAutoSuggestStatus("Skip: cooldown")
            return
        }

        guard let pngData = objectManager.captureViewportPNGData() else {
            updateAutoSuggestStatus("Skip: screenshot failed")
            return
        }
        updateAutoSuggestStatus("Captured screenshot")
        guard let signature = makeScreenshotSignature(from: pngData) else {
            updateAutoSuggestStatus("Skip: signature failed")
            return
        }

        if let previous = lastAutoSignature {
            let difference = signatureDifference(previous, signature)
            autoSuggestLastDiff = difference
            guard difference > 0.075 else {
                updateAutoSuggestStatus(String(format: "Skip: small diff %.4f", difference))
                return
            }
        }

        lastAutoSignature = signature
        lastAutoAttemptAt = now

        guard let backendURL = objectManager.httpServer.backendServerURL() else {
            updateAutoSuggestStatus("Skip: no backend link")
            return
        }
        guard let serverURL = objectManager.httpServer.agentServerURL() else {
            updateAutoSuggestStatus("Skip: no agent link")
            return
        }

        do {
            updateAutoSuggestStatus("Uploading screenshot")
            let screenshotID = try await BackendClient.uploadScreenshot(
                pngData: pngData,
                deviceID: "ipad",
                backendURL: backendURL,
                notes: "auto_widget_suggest"
            )
            updateAutoSuggestStatus("Uploaded \(screenshotID.prefix(8))")

            let prompt = """
            You are a conservative widget-suggestion policy.
            First call read_screenshot for device_id \"ipad\" with screenshot id \(screenshotID).

            Decide if a new widget suggestion is clearly necessary.
            Strong default: DO NOT suggest a widget.
            Only suggest if there is explicit instruction/text in the screenshot that clearly calls for a new structured widget.
            If uncertain, return no suggestion.
            Never suggest duplicates of existing visible widgets.

            Return STRICT JSON only (no markdown):
            {\"add_suggestion\":false}
            OR
            {\"add_suggestion\":true,\"title\":\"...\",\"summary\":\"...\",\"html\":\"...\",\"x\":0,\"y\":0,\"width\":360,\"height\":220}
            """

            updateAutoSuggestStatus("Calling model")
            let response = try await AgentClient.sendMessage(
                prompt,
                agent: document.agent,
                chatID: document.id.uuidString,
                serverURL: serverURL
            )
            autoSuggestLastModelPreview = "Model: " + String(response.prefix(110))

            guard let decision = parseSuggestionDecision(response) else {
                updateAutoSuggestStatus("Skip: invalid JSON")
                return
            }
            guard decision.addSuggestion, let html = decision.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                updateAutoSuggestStatus("No suggestion")
                return
            }

            let center = objectManager.viewportCenter
            let x = CGFloat(decision.x ?? 0)
            let y = CGFloat(decision.y ?? 0)
            let width = CGFloat(decision.width ?? 360)
            let height = CGFloat(decision.height ?? 220)

            let resolvedTitle = ((decision.title?.isEmpty == false) ? decision.title : nil) ?? "Suggested Widget"
            let resolvedSummary = ((decision.summary?.isEmpty == false) ? decision.summary : nil) ?? "Agent suggests a new widget."

            _ = objectManager.addSuggestion(
                title: resolvedTitle,
                summary: resolvedSummary,
                html: html,
                at: CGPoint(x: center.x + x, y: center.y + y),
                size: CGSize(width: max(220, min(700, width)), height: max(150, min(700, height))),
                animateOnPlace: true
            )
            updateAutoSuggestStatus("Suggestion added")
        } catch {
            updateAutoSuggestStatus("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func updateAutoSuggestStatus(_ status: String) {
        autoSuggestStatus = status
    }

    private struct SuggestionDecision {
        var addSuggestion: Bool
        var title: String?
        var summary: String?
        var html: String?
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
    }

    private func parseSuggestionDecision(_ text: String) -> SuggestionDecision? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let jsonText = String(text[start...end])
        guard let data = jsonText.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let add = (obj["add_suggestion"] as? Bool) ?? false
        return SuggestionDecision(
            addSuggestion: add,
            title: obj["title"] as? String,
            summary: obj["summary"] as? String,
            html: obj["html"] as? String,
            x: numericValue(obj["x"]),
            y: numericValue(obj["y"]),
            width: numericValue(obj["width"]),
            height: numericValue(obj["height"])
        )
    }

    private func numericValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let n = any as? Double { return n }
        if let n = any as? Int { return Double(n) }
        return nil
    }

    private func makeScreenshotSignature(from pngData: Data) -> [UInt8]? {
        guard let image = UIImage(data: pngData)?.cgImage else { return nil }
        let size = 24
        let bytesPerRow = size
        var pixels = [UInt8](repeating: 0, count: size * size)

        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels
    }

    private func signatureDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1.0 }
        var total: Double = 0
        for i in 0..<lhs.count {
            total += abs(Double(lhs[i]) - Double(rhs[i]))
        }
        return total / (Double(lhs.count) * 255.0)
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
