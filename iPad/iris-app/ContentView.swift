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
    @State private var widgetSyncTimer: Timer?
    @State private var proactiveMonitorTimer: Timer?
    @State private var renderedWidgetIDs: Set<String> = []
    @State private var renderedSuggestionSignatures: Set<String> = []
    @State private var lastMonitorFingerprint: [UInt8]?
    @State private var proactiveRunInFlight = false
    @State private var lastProactiveDescription: [String: Any]?

    private let proactiveIntervalSeconds: TimeInterval = 5
    private let proactiveMaxSuggestionsPerTick = 3
    private let proactiveAlwaysSaveScreenshots = false
    private let proactiveTriageModel = "gemini-2.0-flash"
    private let proactiveWidgetModel = "claude-sonnet-4-5-20250929"

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

            proactiveSuggestionChips
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
            widgetSyncTimer?.invalidate()
            proactiveMonitorTimer?.invalidate()
        }
        .onAppear {
            SpeechTranscriber.requestAuthorization { _ in }
            startWidgetSync()
            startProactiveMonitor()
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
                    // Non-blocking transcript ingestion keeps voice->agent latency low.
                    Task(priority: .utility) {
                        try? await BackendClient.ingestTranscript(
                            text: prompt,
                            sessionID: document.id.uuidString,
                            deviceID: "ipad",
                            backendURL: backendURL
                        )
                    }

                    // Screenshot upload is only required for screenshot-guided workflows.
                    if document.usesScreenshotWorkflow {
                        do {
                            screenshotID = try await uploadCanvasScreenshot(
                                note: "Voice command: \(prompt.prefix(180))",
                                backendURL: backendURL
                            )
                        } catch {
                            screenshotUploadWarning = "Screenshot upload warning: \(error.localizedDescription)"
                        }
                    }
                }

                if document.usesScreenshotWorkflow, let screenshotID {
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

                // Session registration is best-effort and should not delay first-token latency.
                Task(priority: .utility) {
                    await AgentClient.registerSession(
                        id: document.id.uuidString,
                        name: document.name,
                        model: document.resolvedModel,
                        serverURL: serverURL
                    )
                }

                let coordinateSnapshot = currentCoordinateSnapshotDict()
                let agentResponse = try await AgentClient.sendMessage(
                    message,
                    model: document.resolvedModel,
                    chatID: document.id.uuidString,
                    coordinateSnapshot: coordinateSnapshot,
                    serverURL: serverURL
                )

                // Place widgets on the canvas and track them
                for widget in agentResponse.widgets {
                    let pos = widgetOrigin(for: widget)
                    await objectManager.place(
                        html: widget.html,
                        at: pos,
                        size: CGSize(width: widget.width, height: widget.height)
                    )
                    renderedWidgetIDs.insert(widget.id)
                }

                await MainActor.run {
                    let text = agentResponse.text
                    if let screenshotUploadWarning {
                        withAnimation { lastResponse = "\(screenshotUploadWarning)\n\n\(text)" }
                    } else {
                        withAnimation { lastResponse = text }
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
    private func uploadCanvasScreenshot(note: String, backendURL: URL) async throws -> String? {
        guard let pngData = objectManager.captureViewportPNGData() else {
            return nil
        }

        return try await BackendClient.uploadScreenshot(
            pngData: pngData,
            deviceID: "ipad",
            backendURL: backendURL,
            sessionID: document.id.uuidString,
            notes: note
        )
    }

    private func startWidgetSync() {
        widgetSyncTimer?.invalidate()
        widgetSyncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { await syncWidgets() }
        }
    }

    private func startProactiveMonitor() {
        proactiveMonitorTimer?.invalidate()
        proactiveMonitorTimer = Timer.scheduledTimer(withTimeInterval: proactiveIntervalSeconds, repeats: true) { _ in
            Task { await proactiveMonitorTick() }
        }
    }

    @MainActor
    private func proactiveMonitorTick() async {
        guard !proactiveRunInFlight else { return }
        guard !canvasState.isRecording else { return }
        guard !isProcessing else { return }
        guard let backendURL = objectManager.httpServer.backendServerURL() else { return }
        guard let serverURL = objectManager.httpServer.agentServerURL() else { return }
        guard let pngData = objectManager.captureViewportPNGData() else { return }

        let currentFingerprint = imageFingerprint(from: pngData)
        if !proactiveAlwaysSaveScreenshots, let previousFingerprint = lastMonitorFingerprint {
            if previousFingerprint == currentFingerprint {
                return
            }
        }
        lastMonitorFingerprint = currentFingerprint

        proactiveRunInFlight = true
        defer { proactiveRunInFlight = false }

        do {
            let coordinateSnapshot = currentCoordinateSnapshotDict()
            let screenshotID = try await BackendClient.uploadScreenshot(
                pngData: pngData,
                deviceID: "ipad",
                backendURL: backendURL,
                sessionID: document.id.uuidString,
                notes: "Proactive monitor capture"
            )

            await AgentClient.registerSession(
                id: document.id.uuidString,
                name: document.name,
                model: document.resolvedModel,
                serverURL: serverURL
            )

            let previousDescription = lastProactiveDescription
            let descriptionResult = try await BackendClient.describeProactiveScreenshot(
                screenshotID: screenshotID,
                coordinateSnapshot: coordinateSnapshot,
                backendURL: backendURL,
                previousDescription: previousDescription
            )
            var keepScreenshot = shouldKeepProactiveScreenshot(
                descriptionResult.description,
                previousDescription: previousDescription
            )
            lastProactiveDescription = descriptionResult.description

            let triagePrompt = """
            You are the proactive triage model. Use only the screenshot description JSON below.
            Decide whether we should propose proactive suggestion chips now.
            Return strict JSON only:
            {
              "should_suggest": boolean,
              "reason": "string",
              "suggestions": [
                {"title":"string","summary":"string","x_norm":0.0,"y_norm":0.0,"priority":1}
              ]
            }
            Rules:
            - suggestions max \(proactiveMaxSuggestionsPerTick)
            - x_norm and y_norm must be in [0, 1]
            - if should_suggest is false, suggestions must be []

            Description JSON:
            \(descriptionResult.descriptionJSON)
            """

            let triageResponse = try await AgentClient.sendMessage(
                triagePrompt,
                model: proactiveTriageModel,
                chatID: document.id.uuidString,
                coordinateSnapshot: coordinateSnapshot,
                serverURL: serverURL
            )

            guard let triage = parseProactiveDecision(triageResponse.text) else {
                if !keepScreenshot { try? await BackendClient.deleteScreenshot(screenshotID: screenshotID, backendURL: backendURL) }
                return
            }
            keepScreenshot = keepScreenshot || triage.shouldSuggest
            if !keepScreenshot {
                try? await BackendClient.deleteScreenshot(screenshotID: screenshotID, backendURL: backendURL)
            }
            guard triage.shouldSuggest, !triage.suggestions.isEmpty else { return }

            let selected = Array(triage.suggestions.prefix(proactiveMaxSuggestionsPerTick))
            let selectedJSON = proactiveSuggestionsJSON(selected)
            let widgetPrompt = """
            Build widget suggestions from this screenshot description:
            \(descriptionResult.descriptionJSON)

            Candidate suggestions:
            \(selectedJSON)

            Requirements:
            - Treat description.problem_to_solve and description.task_objective as the primary goal.
            - Make each widget directly help accomplish that goal.
            - For each candidate, call push_widget once.
            - Use widget_id values that start with "proactive-suggestion-".
            - Produce concise Apple-style widgets.
            - Use x/y placement near the provided suggestion coordinates.
            - Use coordinate_space=document_axis and anchor=top_left.
            """

            let widgetResponse = try await AgentClient.sendMessage(
                widgetPrompt,
                model: proactiveWidgetModel,
                chatID: document.id.uuidString,
                coordinateSnapshot: coordinateSnapshot,
                serverURL: serverURL
            )

            let chips = widgetResponse.widgets.prefix(proactiveMaxSuggestionsPerTick)
            guard !chips.isEmpty else { return }

            for (index, widget) in chips.enumerated() {
                let signature = "\(widget.html)|\(Int(widget.width))x\(Int(widget.height))"
                guard !renderedSuggestionSignatures.contains(signature) else { continue }
                renderedWidgetIDs.insert(widget.id)

                let meta = index < selected.count ? selected[index] : nil
                let fallbackOrigin = widgetOrigin(for: widget)
                let baseOrigin = mappedProactiveOrigin(
                    from: meta,
                    coordinateSnapshot: coordinateSnapshot,
                    widgetSize: CGSize(width: widget.width, height: widget.height)
                ) ?? fallbackOrigin
                _ = objectManager.addSuggestion(
                    title: meta?.title ?? "Suggestion",
                    summary: meta?.summary ?? triage.reason,
                    html: widget.html,
                    at: baseOrigin,
                    size: CGSize(width: widget.width, height: widget.height),
                    animateOnPlace: true
                )
                renderedSuggestionSignatures.insert(signature)
            }
        } catch {
            // Proactive loop is best-effort.
        }
    }

    @MainActor
    private func syncWidgets() async {
        guard let serverURL = objectManager.httpServer.agentServerURL() else { return }

        let widgets = await AgentClient.fetchSessionWidgets(
            sessionID: document.id.uuidString,
            serverURL: serverURL
        )

        for widget in widgets where !renderedWidgetIDs.contains(widget.id) {
            let signature = "\(widget.html)|\(Int(widget.width))x\(Int(widget.height))"
            if widget.id.hasPrefix("proactive-suggestion-") {
                if !renderedSuggestionSignatures.contains(signature) {
                    let origin = widgetOrigin(for: widget)
                    _ = objectManager.addSuggestion(
                        title: "Proactive Suggestion",
                        summary: "Suggested from recent canvas changes.",
                        html: widget.html,
                        at: origin,
                        size: CGSize(width: widget.width, height: widget.height),
                        animateOnPlace: true
                    )
                    renderedSuggestionSignatures.insert(signature)
                }
                renderedWidgetIDs.insert(widget.id)
                continue
            }
            if renderedSuggestionSignatures.contains(signature) {
                // Proactive widgets should stay as suggestion chips until user approves.
                renderedWidgetIDs.insert(widget.id)
                continue
            }
            let pos = widgetOrigin(for: widget)
            await objectManager.place(
                html: widget.html,
                at: pos,
                size: CGSize(width: widget.width, height: widget.height)
            )
            renderedWidgetIDs.insert(widget.id)
        }
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

    private var proactiveSuggestionChips: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(objectManager.suggestions.values.sorted(by: { $0.createdAt < $1.createdAt })) { suggestion in
                    let anchor = objectManager.screenPoint(forCanvasPoint: suggestion.position)
                    let x = min(max(anchor.x + 72, 74), geo.size.width - 74)
                    let y = min(max(anchor.y - 14, 20), geo.size.height - 20)

                    HStack(spacing: 6) {
                        Text(suggestion.title.isEmpty ? "Suggest" : suggestion.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.black.opacity(0.8))
                            .lineLimit(1)

                        Button {
                            Task { @MainActor in
                                _ = await objectManager.approveSuggestion(id: suggestion.id)
                            }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.green.opacity(0.9))
                        }

                        Button {
                            _ = objectManager.rejectSuggestion(id: suggestion.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.red.opacity(0.9))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: 150, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
                    .position(x: x, y: y)
                }
            }
        }
        .zIndex(40)
    }

    private struct ProactiveSuggestionDecision {
        let title: String
        let summary: String
        let xNorm: Double
        let yNorm: Double
        let priority: Int
    }

    private struct ProactiveDecision {
        let shouldSuggest: Bool
        let reason: String
        let suggestions: [ProactiveSuggestionDecision]
    }

    private func parseProactiveDecision(_ text: String) -> ProactiveDecision? {
        guard let obj = parseJSONObject(text) else { return nil }
        let shouldSuggest = (obj["should_suggest"] as? Bool) ?? false
        let reason = (obj["reason"] as? String) ?? ""
        let rows = (obj["suggestions"] as? [[String: Any]]) ?? []

        var suggestions: [ProactiveSuggestionDecision] = []
        for row in rows {
            let title = ((row["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = ((row["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let xNorm = min(max((row["x_norm"] as? NSNumber)?.doubleValue ?? 0.5, 0), 1)
            let yNorm = min(max((row["y_norm"] as? NSNumber)?.doubleValue ?? 0.5, 0), 1)
            let priority = max(1, min(5, (row["priority"] as? NSNumber)?.intValue ?? 3))
            if title.isEmpty && summary.isEmpty { continue }
            suggestions.append(
                ProactiveSuggestionDecision(
                    title: title.isEmpty ? "Suggestion" : title,
                    summary: summary,
                    xNorm: xNorm,
                    yNorm: yNorm,
                    priority: priority
                )
            )
        }

        suggestions.sort { $0.priority < $1.priority }
        return ProactiveDecision(
            shouldSuggest: shouldSuggest,
            reason: reason,
            suggestions: suggestions
        )
    }

    private func proactiveSuggestionsJSON(_ suggestions: [ProactiveSuggestionDecision]) -> String {
        let payload: [[String: Any]] = suggestions.map { s in
            [
                "title": s.title,
                "summary": s.summary,
                "x_norm": s.xNorm,
                "y_norm": s.yNorm,
                "priority": s.priority
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return nil
        }
        let span = String(trimmed[start...end])
        guard let data = span.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func shouldKeepProactiveScreenshot(_ description: [String: Any]) -> Bool {
        shouldKeepProactiveScreenshot(description, previousDescription: nil)
    }

    private func shouldKeepProactiveScreenshot(
        _ description: [String: Any],
        previousDescription: [String: Any]?
    ) -> Bool {
        guard let previousDescription else { return true }
        let currentJSON = canonicalJSON(description)
        let previousJSON = canonicalJSON(previousDescription)
        return currentJSON != previousJSON
    }

    private func canonicalJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func mappedProactiveOrigin(
        from suggestion: ProactiveSuggestionDecision?,
        coordinateSnapshot: [String: Any],
        widgetSize: CGSize
    ) -> CGPoint? {
        guard let suggestion else { return nil }
        guard
            let topLeftAxis = coordinateSnapshot["viewportTopLeftAxis"] as? [String: Any],
            let viewportSize = coordinateSnapshot["viewportSizeCanvas"] as? [String: Any],
            let topLeftX = (topLeftAxis["x"] as? NSNumber)?.doubleValue,
            let topLeftY = (topLeftAxis["y"] as? NSNumber)?.doubleValue,
            let viewportW = (viewportSize["width"] as? NSNumber)?.doubleValue,
            let viewportH = (viewportSize["height"] as? NSNumber)?.doubleValue
        else {
            return nil
        }

        let axisX = topLeftX + (suggestion.xNorm * viewportW)
        let axisY = topLeftY + (suggestion.yNorm * viewportH)
        let canvas = objectManager.canvasPoint(
            forAxisPoint: CGPoint(x: axisX, y: axisY)
        )
        return CGPoint(
            x: canvas.x - (widgetSize.width * 0.15),
            y: canvas.y - (widgetSize.height * 0.1)
        )
    }

    private func imageFingerprint(from pngData: Data, targetSize: Int = 32) -> [UInt8] {
        guard
            let image = UIImage(data: pngData),
            let cg = image.cgImage
        else {
            return []
        }

        let width = targetSize
        let height = targetSize
        var buffer = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard
            let context = CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return []
        }

        context.interpolationQuality = .low
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func currentCoordinateSnapshotDict() -> [String: Any] {
        let snapshot = objectManager.makeCoordinateSnapshot(documentID: document.id)
        guard let data = try? JSONEncoder().encode(snapshot) else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func widgetOrigin(for widget: AgentWidget) -> CGPoint {
        let w = max(100, widget.width)
        let h = max(100, widget.height)

        let anchorOffset: CGPoint = {
            if widget.anchor.lowercased() == "center" {
                return CGPoint(x: w / 2, y: h / 2)
            }
            return .zero
        }()

        let base: CGPoint
        switch widget.coordinateSpace.lowercased() {
        case "canvas_absolute":
            base = CGPoint(x: widget.x, y: widget.y)
        case "document_axis":
            base = objectManager.canvasPoint(
                forAxisPoint: CGPoint(x: widget.x, y: widget.y)
            )
        default:
            let viewport = objectManager.viewportCenter
            base = CGPoint(x: viewport.x + widget.x, y: viewport.y + widget.y)
        }

        return CGPoint(x: base.x - anchorOffset.x, y: base.y - anchorOffset.y)
    }
}
