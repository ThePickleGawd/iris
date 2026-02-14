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
    @State private var processedProactiveScreenshotIDs: Set<String> = []
    @State private var lastProactiveTaskSignature: String?
    @State private var proactiveTaskPersistenceTicks = 0
    @State private var proactiveStrokeIdleTask: Task<Void, Never>?
    @State private var proactiveIdleCycleID = 0
    @State private var proactiveCapturedIdleCycleID: Int?

    private let proactiveIntervalSeconds: TimeInterval = 5
    private let proactiveStrokePauseSeconds: TimeInterval = 0.75
    private let proactiveMaxSuggestionsPerTick = 3
    private let proactiveTestSingleSuggestionPerScreenshot = true
    private let proactiveAlwaysSaveScreenshots = false
    private let proactiveForceSuggestAfterTicks = 4
    private let proactiveTriageModel = "gemini-2.0-flash"
    private let proactiveWidgetModel = "gemini-2.0-flash"

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
        .onChange(of: canvasState.lastStrokeActivityAt) { _, strokeAt in
            guard strokeAt != nil else { return }
            proactiveIdleCycleID += 1
            proactiveCapturedIdleCycleID = nil
            scheduleProactiveCaptureAfterStrokePause()
        }
        .onDisappear {
            canvasState.isRecording = false
            audioService.stopCapture()
            widgetSyncTimer?.invalidate()
            proactiveMonitorTimer?.invalidate()
            proactiveStrokeIdleTask?.cancel()
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
                var uploadedScreenshotBackendURL: URL?
                if let backendURL = objectManager.httpServer.backendServerURL() {
                    uploadedScreenshotBackendURL = backendURL
                    // Non-blocking transcript ingestion keeps voice->agent latency low.
                    Task(priority: .utility) {
                        try? await BackendClient.ingestTranscript(
                            text: prompt,
                            sessionID: document.id.uuidString,
                            deviceID: "ipad",
                            backendURL: backendURL
                        )
                    }

                    // Always attach current canvas screenshot for voice prompts.
                    do {
                        screenshotID = try await uploadCanvasScreenshot(
                            note: "Voice command: \(prompt.prefix(180))",
                            backendURL: backendURL
                        )
                    } catch {
                        screenshotUploadWarning = "Screenshot upload warning: \(error.localizedDescription)"
                    }
                }

                if let screenshotID {
                    if !screenshotID.isEmpty {
                        message = """
                        User voice command:
                        \(prompt)

                        I uploaded an iPad canvas screenshot with device_id "ipad" and screenshot id \(screenshotID).
                        First call read_screenshot for device "ipad" to inspect what is on screen.
                        If the request asks for a widget, create and push an iPad widget grounded in that screenshot.
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
                if let sid = screenshotID,
                   !sid.isEmpty,
                   let backendURL = uploadedScreenshotBackendURL {
                    Task(priority: .utility) {
                        _ = try? await BackendClient.describeProactiveScreenshot(
                            screenshotID: sid,
                            coordinateSnapshot: coordinateSnapshot,
                            backendURL: backendURL,
                            previousDescription: nil
                        )
                    }
                }
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
        let coordinateSnapshot = currentCoordinateSnapshotDict()

        return try await BackendClient.uploadScreenshot(
            pngData: pngData,
            deviceID: "ipad",
            backendURL: backendURL,
            sessionID: document.id.uuidString,
            notes: note,
            coordinateSnapshot: coordinateSnapshot
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

    private func scheduleProactiveCaptureAfterStrokePause() {
        proactiveStrokeIdleTask?.cancel()
        proactiveStrokeIdleTask = Task { @MainActor in
            let ns = UInt64(proactiveStrokePauseSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await proactiveMonitorTick()
        }
    }

    @MainActor
    private func proactiveMonitorTick() async {
        guard !proactiveRunInFlight else { return }
        guard !canvasState.isRecording else { return }
        guard !isProcessing else { return }
        if let lastStrokeAt = canvasState.lastStrokeActivityAt {
            let elapsed = Date().timeIntervalSince(lastStrokeAt)
            if elapsed < proactiveStrokePauseSeconds {
                return
            }
            if proactiveCapturedIdleCycleID == proactiveIdleCycleID {
                return
            }
        }
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
        var uploadedScreenshotID: String?

        do {
            let coordinateSnapshot = currentCoordinateSnapshotDict()
            let screenshotID = try await BackendClient.uploadScreenshot(
                pngData: pngData,
                deviceID: "ipad",
                backendURL: backendURL,
                sessionID: document.id.uuidString,
                notes: "Proactive monitor capture",
                coordinateSnapshot: coordinateSnapshot
            )
            uploadedScreenshotID = screenshotID
            proactiveCapturedIdleCycleID = proactiveIdleCycleID

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
            let suggestionLimit = proactiveTestSingleSuggestionPerScreenshot ? 1 : proactiveMaxSuggestionsPerTick
            let keepScreenshot = shouldKeepProactiveScreenshot(
                descriptionResult.description,
                previousDescription: previousDescription
            )
            lastProactiveDescription = descriptionResult.description
            let forceSuggestionRequired = proactiveTestSingleSuggestionPerScreenshot
                || shouldForceProactiveSuggestion(descriptionResult.description)

            if processedProactiveScreenshotIDs.contains(screenshotID) {
                if !keepScreenshot {
                    try? await BackendClient.deleteScreenshot(screenshotID: screenshotID, backendURL: backendURL)
                }
                return
            }

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
            - suggestions max \(suggestionLimit)
            - x_norm and y_norm must be in [0, 1]
            - if should_suggest is false, suggestions must be []
            \(forceSuggestionRequired ? "- The same clear task has persisted too long; you must set should_suggest=true and provide at least 1 suggestion." : "")

            Description JSON:
            \(descriptionResult.descriptionJSON)
            """

            let widgetPrompt = """
            Build proactive suggestion widgets from this screenshot description:
            \(descriptionResult.descriptionJSON)

            Requirements:
            - Use description.problem_to_solve and description.task_objective as the core objective.
            - Create at most \(suggestionLimit) concise Apple-style widgets.
            - If possible, align placement with description.suggestion_candidates anchor_norm.
            - Every widget_id must start with "proactive-suggestion-\(screenshotID)-".
            - Use coordinate_space=document_axis and anchor=top_left.
            \(forceSuggestionRequired ? "- This task has persisted too long. You must output at least one push_widget suggestion." : "")
            """

            async let triageResponseTask = AgentClient.sendMessage(
                triagePrompt,
                model: proactiveTriageModel,
                chatID: document.id.uuidString,
                coordinateSnapshot: coordinateSnapshot,
                serverURL: serverURL
            )
            async let widgetResponseTask = AgentClient.sendMessage(
                widgetPrompt,
                model: proactiveWidgetModel,
                chatID: document.id.uuidString,
                ephemeral: true,
                coordinateSnapshot: coordinateSnapshot,
                serverURL: serverURL
            )

            let (triageResponse, widgetResponse) = try await (triageResponseTask, widgetResponseTask)

            var triage = parseProactiveDecision(triageResponse.text) ?? ProactiveDecision(
                shouldSuggest: true,
                reason: "",
                suggestions: []
            )
            if forceSuggestionRequired && (!triage.shouldSuggest || triage.suggestions.isEmpty) {
                let fallback = fallbackSuggestionsFromDescription(descriptionResult.description)
                triage = ProactiveDecision(
                    shouldSuggest: true,
                    reason: triage.reason.isEmpty ? "Persistent task detected; proactive suggestion required." : triage.reason,
                    suggestions: fallback.isEmpty ? triage.suggestions : fallback
                )
            }
            if !keepScreenshot {
                try? await BackendClient.deleteScreenshot(screenshotID: screenshotID, backendURL: backendURL)
            }

            // Every saved proactive screenshot must produce a suggestion.
            // If triage fails to propose one, synthesize from the screenshot description.
            var selected = Array(triage.suggestions.prefix(suggestionLimit))
            if selected.isEmpty {
                selected = fallbackSuggestionsFromDescription(descriptionResult.description)
            }
            if selected.isEmpty {
                let problem = ((descriptionResult.description["problem_to_solve"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let objective = ((descriptionResult.description["task_objective"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = objective.isEmpty
                    ? ((((descriptionResult.description["scene_summary"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty
                        ? "Tap to place an AI-generated helper widget."
                        : (((descriptionResult.description["scene_summary"] as? String) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)))
                    : objective
                selected = [
                    ProactiveSuggestionDecision(
                        title: problem.isEmpty ? "Suggested Next Step" : problem,
                        summary: summary,
                        xNorm: 0.6,
                        yNorm: 0.35,
                        priority: 1
                    )
                ]
            }
            selected = Array(selected.prefix(suggestionLimit))
            processedProactiveScreenshotIDs.insert(screenshotID)

            let chips = Array(widgetResponse.widgets.prefix(suggestionLimit))
            if chips.isEmpty {
                for meta in selected {
                    let fallbackSize = CGSize(width: 290, height: 150)
                    let origin = mappedProactiveOrigin(
                        from: meta,
                        description: descriptionResult.description,
                        coordinateSnapshot: coordinateSnapshot,
                        widgetSize: fallbackSize
                    ) ?? objectManager.viewportCenter
                    _ = objectManager.addSuggestion(
                        title: meta.title,
                        summary: meta.summary,
                        html: fallbackSuggestionHTML(title: meta.title, summary: meta.summary),
                        at: origin,
                        size: fallbackSize,
                        animateOnPlace: true
                    )
                }
                return
            }

            for (index, widget) in chips.enumerated() {
                let signature = "\(widget.html)|\(Int(widget.width))x\(Int(widget.height))"
                guard !renderedSuggestionSignatures.contains(signature) else { continue }
                renderedWidgetIDs.insert(widget.id)

                let meta = index < selected.count ? selected[index] : nil
                let fallbackOrigin = widgetOrigin(for: widget)
                let baseOrigin = mappedProactiveOrigin(
                    from: meta,
                    description: descriptionResult.description,
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
            if let screenshotID = uploadedScreenshotID {
                try? await BackendClient.deleteScreenshot(screenshotID: screenshotID, backendURL: backendURL)
            }
            print("Proactive monitor failed: \(error.localizedDescription)")
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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.black.opacity(0.8))
                            .lineLimit(1)

                        Button {
                            Task { @MainActor in
                                _ = await objectManager.approveSuggestion(
                                    id: suggestion.id,
                                    preferredScreenCenter: CGPoint(x: x, y: y)
                                )
                            }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.green.opacity(0.9))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            _ = objectManager.rejectSuggestion(id: suggestion.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.red.opacity(0.9))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 160, alignment: .leading)
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

    private func shouldForceProactiveSuggestion(_ description: [String: Any]) -> Bool {
        let signature = proactiveTaskSignature(from: description)
        guard let signature else {
            lastProactiveTaskSignature = nil
            proactiveTaskPersistenceTicks = 0
            return false
        }

        if signature == lastProactiveTaskSignature {
            proactiveTaskPersistenceTicks += 1
        } else {
            lastProactiveTaskSignature = signature
            proactiveTaskPersistenceTicks = 1
        }
        return proactiveTaskPersistenceTicks >= proactiveForceSuggestAfterTicks
    }

    private func proactiveTaskSignature(from description: [String: Any]) -> String? {
        let problem = ((description["problem_to_solve"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = ((description["task_objective"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = "\(problem)|\(objective)".trimmingCharacters(in: .whitespacesAndNewlines)
        if merged.replacingOccurrences(of: "|", with: "").isEmpty {
            return nil
        }
        return merged.lowercased()
    }

    private func fallbackSuggestionsFromDescription(_ description: [String: Any]) -> [ProactiveSuggestionDecision] {
        let candidates = (description["suggestion_candidates"] as? [[String: Any]]) ?? []
        var out: [ProactiveSuggestionDecision] = []
        for (idx, row) in candidates.enumerated() {
            let title = ((row["title"] as? String) ?? "Suggestion").trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = ((row["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let anchor = (row["anchor_norm"] as? [String: Any]) ?? [:]
            let xNorm = min(max((anchor["x"] as? NSNumber)?.doubleValue ?? 0.5, 0), 1)
            let yNorm = min(max((anchor["y"] as? NSNumber)?.doubleValue ?? 0.5, 0), 1)
            let confidence = (row["confidence"] as? NSNumber)?.doubleValue ?? 0.5
            let priority = max(1, min(5, Int(round((1.0 - confidence) * 4.0)) + 1))
            out.append(
                ProactiveSuggestionDecision(
                    title: title.isEmpty ? "Suggestion" : title,
                    summary: summary,
                    xNorm: xNorm,
                    yNorm: yNorm,
                    priority: priority
                )
            )
            if out.count >= proactiveMaxSuggestionsPerTick { break }
            if idx >= 7 { break }
        }

        if !out.isEmpty {
            return out
        }

        let problem = ((description["problem_to_solve"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = ((description["task_objective"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !problem.isEmpty || !objective.isEmpty {
            return [
                ProactiveSuggestionDecision(
                    title: problem.isEmpty ? "Next Step" : problem,
                    summary: objective,
                    xNorm: 0.6,
                    yNorm: 0.35,
                    priority: 1
                )
            ]
        }
        return []
    }

    private func canonicalJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func mappedProactiveOrigin(
        from suggestion: ProactiveSuggestionDecision?,
        description: [String: Any],
        coordinateSnapshot: [String: Any],
        widgetSize: CGSize
    ) -> CGPoint? {
        let anchorNorm = suggestion.map { (x: $0.xNorm, y: $0.yNorm) }
            ?? inferredAnchorFromMostRecentStroke(coordinateSnapshot)
            ?? inferredWritingAnchor(from: description)
        guard let anchorNorm else { return nil }
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

        let axisX = topLeftX + (anchorNorm.x * viewportW)
        let axisY = topLeftY + (anchorNorm.y * viewportH)
        let canvas = objectManager.canvasPoint(
            forAxisPoint: CGPoint(x: axisX, y: axisY)
        )
        return CGPoint(
            x: canvas.x + 10,
            y: canvas.y - min(8, widgetSize.height * 0.05)
        )
    }

    private func inferredWritingAnchor(from description: [String: Any]) -> (x: Double, y: Double)? {
        let regions = (description["regions"] as? [[String: Any]]) ?? []
        var bestScore = -1.0
        var bestAnchor: (x: Double, y: Double)?

        for region in regions {
            let kind = ((region["kind"] as? String) ?? "unknown").lowercased()
            let kindWeight: Double = {
                switch kind {
                case "text", "equation", "list", "table":
                    return 1.0
                case "diagram":
                    return 0.9
                default:
                    return 0.6
                }
            }()
            let salience = (region["salience"] as? NSNumber)?.doubleValue ?? 0
            let bbox = (region["bbox_norm"] as? [String: Any]) ?? [:]
            let x = min(max((bbox["x"] as? NSNumber)?.doubleValue ?? 0.5, 0), 1)
            let y = min(max((bbox["y"] as? NSNumber)?.doubleValue ?? 0.5, 0), 1)
            let w = min(max((bbox["w"] as? NSNumber)?.doubleValue ?? 0.2, 0), 1)
            let h = min(max((bbox["h"] as? NSNumber)?.doubleValue ?? 0.15, 0), 1)

            let score = (salience * 0.8) + (kindWeight * 0.2)
            if score <= bestScore {
                continue
            }

            // Place chip just to the right of the written region; clamp inside viewport.
            let anchorX = min(max(x + w + 0.03, 0.08), 0.92)
            let anchorY = min(max(y + (h * 0.25), 0.08), 0.92)
            bestScore = score
            bestAnchor = (anchorX, anchorY)
        }

        return bestAnchor
    }

    private func inferredAnchorFromMostRecentStroke(_ coordinateSnapshot: [String: Any]) -> (x: Double, y: Double)? {
        guard
            let center = coordinateSnapshot["mostRecentStrokeCenterAxis"] as? [String: Any],
            let topLeftAxis = coordinateSnapshot["viewportTopLeftAxis"] as? [String: Any],
            let viewportSize = coordinateSnapshot["viewportSizeCanvas"] as? [String: Any],
            let strokeX = (center["x"] as? NSNumber)?.doubleValue,
            let strokeY = (center["y"] as? NSNumber)?.doubleValue,
            let viewportMinX = (topLeftAxis["x"] as? NSNumber)?.doubleValue,
            let viewportMinY = (topLeftAxis["y"] as? NSNumber)?.doubleValue,
            let viewportW = (viewportSize["width"] as? NSNumber)?.doubleValue,
            let viewportH = (viewportSize["height"] as? NSNumber)?.doubleValue,
            viewportW > 1, viewportH > 1
        else {
            return nil
        }

        let xNorm = min(max((strokeX - viewportMinX) / viewportW, 0), 1)
        let yNorm = min(max((strokeY - viewportMinY) / viewportH, 0), 1)
        return (xNorm, yNorm)
    }

    private func fallbackSuggestionHTML(title: String, summary: String) -> String {
        let safeTitle = title.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let safeSummary = summary.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#fff;border:1px solid #E5E7EB;border-radius:12px;padding:12px;color:#111827;">
          <div style="font-size:12px;font-weight:700;line-height:1.3;">\(safeTitle)</div>
          <div style="font-size:11px;color:#4B5563;margin-top:6px;line-height:1.35;">\(safeSummary)</div>
        </div>
        """
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
