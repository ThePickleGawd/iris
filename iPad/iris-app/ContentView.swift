import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var canvasState: CanvasState

    let document: Document
    @ObservedObject var documentStore: DocumentStore
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
    @State private var expandedSuggestionIDs: Set<UUID> = []
    @State private var connectionMonitorTimer: Timer?
    @State private var isConnectionCheckInFlight = false
    @State private var macConnectionStatus: MacConnectionStatus = .checking
    @State private var awaitingPlacementTap = false
    @State private var placementTapPrompt = "Tap where the response should start."
    @State private var placementTapContinuation: CheckedContinuation<CGPoint, Never>?

    /// Live binding to the document in the store so UI updates when name/model changes.
    private var liveDocument: Document {
        documentStore.documents.first(where: { $0.id == document.id }) ?? document
    }

    private let proactiveEnabled = false
    private let proactiveIntervalSeconds: TimeInterval = 5
    private let proactiveStrokePauseSeconds: TimeInterval = 0.75
    private let connectionCheckIntervalSeconds: TimeInterval = 4
    private let proactiveMaxSuggestionsPerTick = 3
    private let proactiveTestSingleSuggestionPerScreenshot = false
    private let proactiveAlwaysSaveScreenshots = false
    private let proactiveForceSuggestAfterTicks = 4
    private let screenshotAIProcessingEnabled = false
    private let aiOutputInkEnabled = true
    private let proactiveTriageModel = "gemini-2.0-flash"
    private let proactiveWidgetModel = "gemini-2.0-flash"
    private var sessionID: String { liveDocument.resolvedSessionID }
    private var linkedSessionMetadata: [String: Any] {
        let doc = liveDocument
        var metadata: [String: Any] = [:]
        if let codexConversationID = doc.codexConversationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexConversationID.isEmpty {
            metadata["codex_conversation_id"] = codexConversationID
        }
        if let codexCWD = doc.codexCWD?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexCWD.isEmpty {
            metadata["codex_cwd"] = codexCWD
        }
        if let claudeCodeConversationID = doc.claudeCodeConversationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !claudeCodeConversationID.isEmpty {
            metadata["claude_code_conversation_id"] = claudeCodeConversationID
        }
        if let claudeCodeCWD = doc.claudeCodeCWD?.trimmingCharacters(in: .whitespacesAndNewlines),
           !claudeCodeCWD.isEmpty {
            metadata["claude_code_cwd"] = claudeCodeCWD
        }
        return metadata
    }

    var body: some View {
        ZStack(alignment: .top) {
            CanvasView(document: document, objectManager: objectManager, cursor: cursor)
                .environmentObject(canvasState)

            SiriGlowView(isActive: canvasState.isRecording, audioLevel: audioService.audioLevel)

            ToolbarView(
                onBack: onBack,
                onAITap: { canvasState.isRecording.toggle() },
                isRecording: canvasState.isRecording,
                document: liveDocument,
                documentStore: documentStore,
                onZoomIn: { objectManager.zoom(by: 0.06) },
                onZoomOut: { objectManager.zoom(by: -0.06) },
                onZoomReset: { objectManager.setZoomScale(1.0) },
                showAIButton: false
            )
            .environmentObject(canvasState)
            .zIndex(20)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    AIButton(isRecording: canvasState.isRecording, isAvailable: isSpeechAvailable) {
                        canvasState.isRecording.toggle()
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 28)
                }
            }
            .zIndex(21)

            AgentCursorView(controller: cursor)
                .zIndex(50)

            if awaitingPlacementTap {
                placementTapOverlay
            }

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
        .onChange(of: canvasState.lastPencilDoubleTapAt) { _, tappedAt in
            guard tappedAt != nil else { return }
            Task { await handlePencilDoubleTapExplicitAnswer() }
        }
        .onDisappear {
            canvasState.isRecording = false
            audioService.stopCapture()
            widgetSyncTimer?.invalidate()
            proactiveMonitorTimer?.invalidate()
            proactiveStrokeIdleTask?.cancel()
            connectionMonitorTimer?.invalidate()
            if let continuation = placementTapContinuation {
                continuation.resume(returning: objectManager.viewportCenter)
                placementTapContinuation = nil
                awaitingPlacementTap = false
            }
        }
        .onAppear {
            SpeechTranscriber.requestAuthorization { _ in }
            setupWidgetRemovalSync()
            startWidgetSync()
            startProactiveMonitor()
            startConnectionMonitor()
        }
    }

    private var isSpeechAvailable: Bool {
        switch macConnectionStatus {
        case .connected, .degraded, .checking:
            return true
        case .unlinked, .disconnected:
            return false
        }
    }

    private var placementTapOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            resolvePlacementTap(at: value.location)
                        }
                )

            VStack(spacing: 8) {
                Text("Place Response")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(placementTapPrompt)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.09, blue: 0.16).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .padding(.top, 90)
        }
        .zIndex(60)
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
                let placementAnchor = await waitForPlacementTap(
                    prompt: "Tap where the answer should start."
                )
                var message = prompt
                var screenshotID: String?
                var screenshotUploadWarning: String?
                var uploadedScreenshotBackendURL: URL?
                let shouldUploadVoiceScreenshot = (!proactiveEnabled) || screenshotAIProcessingEnabled
                if shouldUploadVoiceScreenshot,
                   let backendURL = objectManager.httpServer.backendServerURL() {
                    uploadedScreenshotBackendURL = backendURL
                    // Non-blocking transcript ingestion keeps voice->agent latency low.
                    Task(priority: .utility) {
                        try? await BackendClient.ingestTranscript(
                            text: prompt,
                            sessionID: sessionID,
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
                        If the request is a direct question that can be answered immediately, answer it directly in text and do not create a follow-up-question widget.
                        """
                    }
                }

                // Session registration is best-effort and should not delay first-token latency.
                let currentDoc = liveDocument
                Task(priority: .utility) {
                    await AgentClient.registerSession(
                        id: sessionID,
                        name: currentDoc.name,
                        model: currentDoc.model,
                        metadata: linkedSessionMetadata,
                        serverURL: serverURL
                    )
                }

                let coordinateSnapshot = currentCoordinateSnapshotDict()
                if screenshotAIProcessingEnabled, proactiveEnabled,
                   let sid = screenshotID,
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
                    model: currentDoc.resolvedModel,
                    chatID: sessionID,
                    coordinateSnapshot: coordinateSnapshot,
                    codexConversationID: currentDoc.codexConversationID,
                    codexCWD: currentDoc.codexCWD,
                    claudeCodeConversationID: currentDoc.claudeCodeConversationID,
                    claudeCodeCWD: currentDoc.claudeCodeCWD,
                    serverURL: serverURL
                )

                if let newName = agentResponse.sessionName {
                    await MainActor.run {
                        documentStore.renameDocument(document, to: newName)
                    }
                }

            if aiOutputInkEnabled {
                let widgetInkAnchors = Dictionary(
                    uniqueKeysWithValues: agentResponse.widgets.enumerated().map { idx, widget in
                        let origin = (idx == 0)
                            ? preferredWidgetOrigin(for: widget, anchorCanvas: placementAnchor)
                            : widgetOrigin(for: widget)
                        return (widget.id, origin)
                    }
                )
                await renderAgentOutputAsHandwriting(
                    response: agentResponse,
                    prefix: screenshotUploadWarning,
                    startAnchor: placementAnchor,
                    widgetAnchors: widgetInkAnchors
                )
                await MainActor.run {
                    lastResponse = screenshotUploadWarning
                        isProcessing = false
                        if screenshotUploadWarning != nil {
                            autoDismissResponse()
                        }
                    }
                } else {
                    // Place widgets on the canvas and track them
                    for (idx, widget) in agentResponse.widgets.enumerated() {
                        let pos = (idx == 0)
                            ? preferredWidgetOrigin(for: widget, anchorCanvas: placementAnchor)
                            : widgetOrigin(for: widget)
                        await objectManager.place(
                            html: widget.html,
                            at: pos,
                            size: CGSize(width: widget.width, height: widget.height),
                            backendWidgetID: widget.id
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
    private func handlePencilDoubleTapExplicitAnswer() async {
        guard !isProcessing else { return }
        await runExplicitScreenAnswer(
            userIntent: "Analyze the current iPad screen and answer the most concrete visible question or task directly."
        )
    }

    @MainActor
    private func handleSuggestionAccepted(_ suggestion: CanvasSuggestion) async {
        guard !isProcessing else { return }
        _ = objectManager.rejectSuggestion(id: suggestion.id)
        expandedSuggestionIDs.remove(suggestion.id)
        let intent = "\(suggestion.title). \(suggestion.summary)".trimmingCharacters(in: .whitespacesAndNewlines)
        await runExplicitScreenAnswer(userIntent: intent)
    }

    @MainActor
    private func runExplicitScreenAnswer(userIntent: String) async {
        guard let serverURL = objectManager.httpServer.agentServerURL() else {
            withAnimation { lastResponse = "No linked Mac found. Open the Iris Mac app first." }
            autoDismissResponse()
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        do {
            let placementAnchor = await waitForPlacementTap(
                prompt: "Tap where the explicit answer should start."
            )
            var message = userIntent
            if let backendURL = objectManager.httpServer.backendServerURL(),
               let screenshotID = try await uploadCanvasScreenshot(
                note: "Explicit pencil request: \(userIntent.prefix(180))",
                backendURL: backendURL
               ),
               !screenshotID.isEmpty {
                message = """
                Explicit user request triggered by Apple Pencil double tap.
                User intent:
                \(userIntent)

                I uploaded an iPad canvas screenshot with device_id "ipad" and screenshot id \(screenshotID).
                First call read_screenshot for device "ipad".
                Then provide a direct answer to the most concrete task/question visible.
                Do not return follow-up-question suggestions in place of the answer.
                If useful, create one concise iPad widget that directly contains the answer.
                """
            }

            let coordinateSnapshot = currentCoordinateSnapshotDict()
            let agentResponse = try await AgentClient.sendMessage(
                message,
                model: liveDocument.resolvedModel,
                chatID: document.id.uuidString,
                coordinateSnapshot: coordinateSnapshot,
                serverURL: serverURL
            )

            if aiOutputInkEnabled {
                let widgetInkAnchors = Dictionary(
                    uniqueKeysWithValues: agentResponse.widgets.enumerated().map { idx, widget in
                        let origin = (idx == 0)
                            ? preferredWidgetOrigin(for: widget, anchorCanvas: placementAnchor)
                            : widgetOrigin(for: widget)
                        return (widget.id, origin)
                    }
                )
                await renderAgentOutputAsHandwriting(
                    response: agentResponse,
                    startAnchor: placementAnchor,
                    widgetAnchors: widgetInkAnchors
                )
                withAnimation { lastResponse = nil }
            } else {
                for (idx, widget) in agentResponse.widgets.enumerated() {
                    let pos = (idx == 0)
                        ? preferredWidgetOrigin(for: widget, anchorCanvas: placementAnchor)
                        : widgetOrigin(for: widget)
                    await objectManager.place(
                        html: widget.html,
                        at: pos,
                        size: CGSize(width: widget.width, height: widget.height),
                        backendWidgetID: widget.id
                    )
                    renderedWidgetIDs.insert(widget.id)
                }

                withAnimation { lastResponse = agentResponse.text }
                autoDismissResponse()
            }
        } catch {
            withAnimation { lastResponse = "Error: \(error.localizedDescription)" }
            autoDismissResponse()
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
            sessionID: sessionID,
            notes: note,
            coordinateSnapshot: coordinateSnapshot
        )
    }

    private func setupWidgetRemovalSync() {
        objectManager.onWidgetRemoved = { [weak objectManager] backendWidgetID in
            guard let serverURL = objectManager?.httpServer.agentServerURL() else { return }
            let sid = sessionID
            Task {
                await AgentClient.deleteSessionWidget(
                    sessionID: sid,
                    widgetID: backendWidgetID,
                    serverURL: serverURL
                )
            }
        }
    }

    private func startWidgetSync() {
        widgetSyncTimer?.invalidate()
        widgetSyncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { await syncWidgets() }
        }
    }

    private func startProactiveMonitor() {
        guard proactiveEnabled else { return }
        proactiveMonitorTimer?.invalidate()
        proactiveMonitorTimer = Timer.scheduledTimer(withTimeInterval: proactiveIntervalSeconds, repeats: true) { _ in
            Task { await proactiveMonitorTick() }
        }
    }

    private func scheduleProactiveCaptureAfterStrokePause() {
        guard proactiveEnabled else { return }
        proactiveStrokeIdleTask?.cancel()
        proactiveStrokeIdleTask = Task { @MainActor in
            let ns = UInt64(proactiveStrokePauseSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await proactiveMonitorTick()
        }
    }

    @MainActor
    private func startConnectionMonitor() {
        connectionMonitorTimer?.invalidate()
        connectionMonitorTimer = Timer.scheduledTimer(withTimeInterval: connectionCheckIntervalSeconds, repeats: true) { _ in
            Task { @MainActor in
                await refreshConnectionStatus()
            }
        }
        Task { @MainActor in
            await refreshConnectionStatus()
        }
    }

    @MainActor
    private func refreshConnectionStatus() async {
        guard !isConnectionCheckInFlight else { return }
        isConnectionCheckInFlight = true
        defer { isConnectionCheckInFlight = false }

        guard let agentURL = objectManager.httpServer.agentServerURL() else {
            macConnectionStatus = .unlinked
            return
        }

        let agentHealthURL = agentURL.appendingPathComponent("health")
        if let backendURL = objectManager.httpServer.backendServerURL() {
            async let isAgentHealthy = pingHealth(at: agentHealthURL)
            async let isBackendHealthy = pingHealth(at: backendURL.appendingPathComponent("health"))
            let (agentHealthy, backendHealthy) = await (isAgentHealthy, isBackendHealthy)
            if agentHealthy && backendHealthy {
                macConnectionStatus = .connected
            } else if agentHealthy || backendHealthy {
                macConnectionStatus = .degraded
            } else {
                macConnectionStatus = .disconnected
            }
        } else {
            let agentHealthy = await pingHealth(at: agentHealthURL)
            macConnectionStatus = agentHealthy ? .connected : .disconnected
        }
    }

    private func pingHealth(at url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
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

        do {
            let coordinateSnapshot = currentCoordinateSnapshotDict()
            let screenshotID = try await BackendClient.uploadScreenshot(
                pngData: pngData,
                deviceID: "ipad",
                backendURL: backendURL,
                sessionID: sessionID,
                notes: "Proactive monitor capture",
                coordinateSnapshot: coordinateSnapshot
            )
            proactiveCapturedIdleCycleID = proactiveIdleCycleID

            let monitorDoc = liveDocument
            await AgentClient.registerSession(
                id: sessionID,
                name: monitorDoc.name,
                model: monitorDoc.model,
                metadata: linkedSessionMetadata,
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
            _ = shouldKeepProactiveScreenshot(
                descriptionResult.description,
                previousDescription: previousDescription
            )
            lastProactiveDescription = descriptionResult.description
            if processedProactiveScreenshotIDs.contains(screenshotID) {
                return
            }
            guard shouldAllowProactiveSuggestion(for: descriptionResult.description) else {
                processedProactiveScreenshotIDs.insert(screenshotID)
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
            - If canvas_state.is_blank is true, should_suggest must be false.
            - Only set should_suggest=true when there is a concrete, specific task/question to complete now.
            - Do not suggest for vague brainstorming, empty notes, or ambiguous intent.
            - Phrase suggestion titles as short optional nudges (for example: "Add diagram?" or "Provide hint for problem?").

            Description JSON:
            \(descriptionResult.descriptionJSON)
            """

            async let triageResponseTask: AgentResponse? = try? await AgentClient.sendMessage(
                triagePrompt,
                model: proactiveTriageModel,
                chatID: sessionID,
                coordinateSnapshot: coordinateSnapshot,
                serverURL: serverURL
            )

            let triageResponse = await triageResponseTask

            if triageResponse == nil {
                print("Proactive triage agent call failed; using local fallback suggestions.")
            }

            let triage = parseProactiveDecision(triageResponse?.text ?? "") ?? ProactiveDecision(
                shouldSuggest: false,
                reason: "",
                suggestions: []
            )
            guard triage.shouldSuggest else {
                processedProactiveScreenshotIDs.insert(screenshotID)
                return
            }

            // Proactive mode is suggestion-only: suggest lightweight actions, not full answers.
            var selected = Array(triage.suggestions.prefix(suggestionLimit))
            if selected.isEmpty {
                selected = fallbackSuggestionsFromDescription(descriptionResult.description)
            }
            selected = selected.filter { textLooksConcreteTask($0.title) || textLooksConcreteTask($0.summary) }
            selected = Array(selected.prefix(suggestionLimit))
            guard !selected.isEmpty else {
                processedProactiveScreenshotIDs.insert(screenshotID)
                return
            }
            processedProactiveScreenshotIDs.insert(screenshotID)

            for meta in selected {
                let fallbackSize = CGSize(width: 300, height: 160)
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
                    animateOnPlace: false
                )
            }
        } catch {
            print("Proactive monitor failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func syncWidgets() async {
        guard let serverURL = objectManager.httpServer.agentServerURL() else { return }

        let widgets = await AgentClient.fetchSessionWidgets(
            sessionID: sessionID,
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
            if aiOutputInkEnabled {
                await renderAgentOutputAsHandwriting(
                    response: AgentResponse(text: "", widgets: [widget], sessionName: nil),
                    prefix: nil,
                    widgetAnchors: [widget.id: widgetOrigin(for: widget)]
                )
            } else {
                let pos = widgetOrigin(for: widget)
                await objectManager.place(
                    html: widget.html,
                    at: pos,
                    size: CGSize(width: widget.width, height: widget.height),
                    backendWidgetID: widget.id
                )
            }
            renderedWidgetIDs.insert(widget.id)
        }
    }

    private func autoDismissResponse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            withAnimation { lastResponse = nil }
        }
    }

    @MainActor
    private func renderAgentOutputAsHandwriting(
        response: AgentResponse,
        prefix: String? = nil,
        startAnchor: CGPoint? = nil,
        widgetAnchors: [String: CGPoint] = [:]
    ) async {
        var textBlocks: [String] = []
        if let prefix {
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                textBlocks.append(trimmed)
            }
        }

        let mainText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mainText.isEmpty {
            textBlocks.append(mainText)
        }

        var widgetBlocks: [(text: String, anchor: CGPoint)] = []
        for widget in response.widgets {
            let extracted = extractPlainText(fromHTML: widget.html)
            let text = extracted.isEmpty ? "Widget output" : extracted
            let anchor = widgetAnchors[widget.id] ?? preferredAIInkAnchor(maxWidthHint: widget.width)
            widgetBlocks.append((text: text, anchor: anchor))
            renderedWidgetIDs.insert(widget.id)
        }

        guard !textBlocks.isEmpty || !widgetBlocks.isEmpty else { return }
        if let startAnchor {
            let viewport = objectManager.viewportCanvasRect()
            let maxWidth = min(520, max(240, viewport.width * 0.45))
            var anchor = startAnchor
            anchor.x = min(max(anchor.x, viewport.minX + 16), viewport.maxX - maxWidth - 16)
            anchor.y = max(anchor.y, viewport.minY + 16)

            var flowBlocks: [String] = []
            flowBlocks.append(contentsOf: textBlocks)
            flowBlocks.append(contentsOf: widgetBlocks.map(\.text))

            for block in flowBlocks where !block.isEmpty {
                let clipped = String(block.prefix(900))
                let drawn = await objectManager.drawHandwrittenText(
                    clipped,
                    at: anchor,
                    maxWidth: maxWidth
                )
                anchor.y += max(40, drawn.height + 18)
            }
            return
        }

        if !textBlocks.isEmpty {
            var anchor = preferredAIInkAnchor(maxWidthHint: 420)
            let viewport = objectManager.viewportCanvasRect()
            let maxWidth = min(520, max(240, viewport.width * 0.45))
            anchor.x = min(max(anchor.x, viewport.minX + 16), viewport.maxX - maxWidth - 16)
            anchor.y = max(anchor.y, viewport.minY + 16)

            for block in textBlocks {
                let clipped = String(block.prefix(900))
                let drawn = await objectManager.drawHandwrittenText(
                    clipped,
                    at: anchor,
                    maxWidth: maxWidth
                )
                anchor.y += max(48, drawn.height + 24)
            }
        }

        for widget in widgetBlocks {
            let clipped = String(widget.text.prefix(900))
            _ = await objectManager.drawHandwrittenText(
                clipped,
                at: widget.anchor,
                maxWidth: 420
            )
        }
    }

    private func preferredAIInkAnchor(maxWidthHint: CGFloat) -> CGPoint {
        let snapshot = objectManager.makeCoordinateSnapshot(documentID: document.id)
        if let bounds = snapshot.mostRecentStrokeBoundsAxis {
            let axisAnchor = CGPoint(
                x: bounds.x + bounds.width + 28,
                y: bounds.y - 8
            )
            return objectManager.canvasPoint(forAxisPoint: axisAnchor)
        }

        let viewport = objectManager.viewportCanvasRect()
        return CGPoint(
            x: viewport.midX - (maxWidthHint * 0.5),
            y: viewport.midY - 64
        )
    }

    private func extractPlainText(fromHTML html: String) -> String {
        let withBreaks = html.replacingOccurrences(
            of: "(?i)<br\\s*/?>",
            with: "\n",
            options: .regularExpression
        )
        guard let data = withBreaks.data(using: .utf8) else { return "" }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else {
            return ""
        }

        let lines = attributed.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
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
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(objectManager.suggestions.values.sorted(by: { $0.createdAt < $1.createdAt })) { suggestion in
                let expanded = expandedSuggestionIDs.contains(suggestion.id)

                VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
                    Button {
                        if expanded {
                            expandedSuggestionIDs.remove(suggestion.id)
                        } else {
                            expandedSuggestionIDs.insert(suggestion.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(suggestion.title.isEmpty ? "Suggestion" : suggestion.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.black.opacity(0.82))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.black.opacity(0.45))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        Text(suggestion.summary.isEmpty ? "Would you like Iris to do this?" : suggestion.summary)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.black.opacity(0.66))
                            .lineLimit(3)
                            .padding(.horizontal, 10)

                        HStack(spacing: 8) {
                            Button {
                                Task { @MainActor in
                                    await handleSuggestionAccepted(suggestion)
                                }
                            } label: {
                                Text("Accept")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.green.opacity(0.95))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.green.opacity(0.12))
                            )

                            Button {
                                _ = objectManager.rejectSuggestion(id: suggestion.id)
                                expandedSuggestionIDs.remove(suggestion.id)
                            } label: {
                                Text("Reject")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.red.opacity(0.95))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.red.opacity(0.11))
                            )
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                }
                .frame(width: 240, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.95))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
            }
        }
        .padding(.top, 16)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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

    private func shouldAllowProactiveSuggestion(for description: [String: Any]) -> Bool {
        if isBlankCanvasDescription(description) {
            return false
        }
        return hasConcreteTaskDescription(description)
    }

    private func isBlankCanvasDescription(_ description: [String: Any]) -> Bool {
        let canvasState = (description["canvas_state"] as? [String: Any]) ?? [:]
        if (canvasState["is_blank"] as? Bool) == true {
            return true
        }
        let regions = (description["regions"] as? [[String: Any]]) ?? []
        let candidates = (description["suggestion_candidates"] as? [[String: Any]]) ?? []
        let problem = ((description["problem_to_solve"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = ((description["task_objective"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return regions.isEmpty && candidates.isEmpty && problem.isEmpty && objective.isEmpty
    }

    private func hasConcreteTaskDescription(_ description: [String: Any]) -> Bool {
        let problem = ((description["problem_to_solve"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = ((description["task_objective"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = ((description["scene_summary"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = (description["suggestion_candidates"] as? [[String: Any]]) ?? []

        let hasStrongCandidate = candidates.contains { row in
            let title = ((row["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = ((row["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let confidence = (row["confidence"] as? NSNumber)?.doubleValue ?? 0
            return confidence >= 0.7 && (textLooksConcreteTask(title) || textLooksConcreteTask(summary))
        }

        return textLooksConcreteTask(problem)
            || textLooksConcreteTask(objective)
            || hasStrongCandidate
            || scene.contains("?")
    }

    private func textLooksConcreteTask(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let words = t.split(whereSeparator: \.isWhitespace)
        guard words.count >= 4 else { return false }

        let genericPhrases = [
            "brainstorm",
            "ideas",
            "random notes",
            "scratch work",
            "doodle",
            "maybe",
            "something",
            "anything"
        ]
        if genericPhrases.contains(where: { t.contains($0) }) {
            return false
        }

        if t.contains("?") {
            return true
        }
        if t.rangeOfCharacter(from: .decimalDigits) != nil {
            return true
        }

        let actionVerbs = [
            "solve", "calculate", "compute", "prove", "simplify", "derive",
            "find", "determine", "write", "draft", "fix", "compare",
            "summarize", "explain", "complete", "finish", "answer"
        ]
        return actionVerbs.contains(where: { t.contains($0) })
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
                    title: "Provide hint for problem?",
                    summary: objective.isEmpty ? "I can generate a concise hint for the current task." : objective,
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
        let hasExplicitCoords = abs(widget.x) > 0.5 || abs(widget.y) > 0.5
        let writingAnchorCanvas = mostRecentWritingAnchorCanvasPoint()

        let anchorOffset: CGPoint = {
            if widget.anchor.lowercased() == "center" {
                return CGPoint(x: w / 2, y: h / 2)
            }
            return .zero
        }()

        let base: CGPoint
        switch widget.coordinateSpace.lowercased() {
        case "canvas_absolute":
            if hasExplicitCoords {
                base = CGPoint(x: widget.x, y: widget.y)
            } else if let writingAnchorCanvas {
                base = CGPoint(x: writingAnchorCanvas.x + 14, y: writingAnchorCanvas.y + 6)
            } else {
                base = objectManager.viewportCenter
            }
        case "document_axis":
            if hasExplicitCoords {
                base = objectManager.canvasPoint(
                    forAxisPoint: CGPoint(x: widget.x, y: widget.y)
                )
            } else if let writingAnchorCanvas {
                base = CGPoint(x: writingAnchorCanvas.x + 14, y: writingAnchorCanvas.y + 6)
            } else {
                base = objectManager.viewportCenter
            }
        case "viewport_local", "viewport_top_left", "viewport_topleft":
            let viewportRect = objectManager.viewportCanvasRect()
            base = CGPoint(x: viewportRect.minX + widget.x, y: viewportRect.minY + widget.y)
        default:
            if hasExplicitCoords {
                let viewport = objectManager.viewportCenter
                base = CGPoint(x: viewport.x + widget.x, y: viewport.y + widget.y)
            } else if let writingAnchorCanvas {
                base = CGPoint(x: writingAnchorCanvas.x + 14, y: writingAnchorCanvas.y + 6)
            } else {
                base = objectManager.viewportCenter
            }
        }

        return CGPoint(x: base.x - anchorOffset.x, y: base.y - anchorOffset.y)
    }

    @MainActor
    private func waitForPlacementTap(prompt: String) async -> CGPoint {
        placementTapPrompt = prompt
        awaitingPlacementTap = true
        return await withCheckedContinuation { continuation in
            placementTapContinuation = continuation
        }
    }

    @MainActor
    private func resolvePlacementTap(at location: CGPoint) {
        guard awaitingPlacementTap else { return }
        awaitingPlacementTap = false
        let canvasPoint = objectManager.canvasPoint(forScreenPoint: location)
        placementTapContinuation?.resume(returning: canvasPoint)
        placementTapContinuation = nil
    }

    private func preferredWidgetOrigin(for widget: AgentWidget, anchorCanvas: CGPoint) -> CGPoint {
        let w = max(100, widget.width)
        let h = max(100, widget.height)
        let anchorOffset: CGPoint = {
            if widget.anchor.lowercased() == "center" {
                return CGPoint(x: w / 2, y: h / 2)
            }
            return .zero
        }()
        return CGPoint(x: anchorCanvas.x - anchorOffset.x, y: anchorCanvas.y - anchorOffset.y)
    }

    private func mostRecentWritingAnchorCanvasPoint() -> CGPoint? {
        let snapshot = currentCoordinateSnapshotDict()
        guard
            let center = snapshot["mostRecentStrokeCenterAxis"] as? [String: Any],
            let axisX = (center["x"] as? NSNumber)?.doubleValue,
            let axisY = (center["y"] as? NSNumber)?.doubleValue
        else {
            return nil
        }
        return objectManager.canvasPoint(forAxisPoint: CGPoint(x: axisX, y: axisY))
    }
}

private enum MacConnectionStatus {
    case unlinked
    case connected
    case degraded
    case disconnected
    case checking

    var indicatorColor: Color {
        switch self {
        case .connected:
            return Color(red: 0.33, green: 0.78, blue: 0.44)
        case .degraded:
            return Color(red: 0.95, green: 0.72, blue: 0.24)
        case .disconnected:
            return Color(red: 0.89, green: 0.35, blue: 0.35)
        case .unlinked, .checking:
            return Color.white.opacity(0.55)
        }
    }

    var compactLabel: String {
        switch self {
        case .connected:
            return "Mac"
        case .degraded:
            return "Mac!"
        case .disconnected:
            return "Mac?"
        case .unlinked:
            return "Link"
        case .checking:
            return "Mac..."
        }
    }

    var accessibilityValue: String {
        switch self {
        case .connected:
            return "connected"
        case .degraded:
            return "partially connected"
        case .disconnected:
            return "not reachable"
        case .unlinked:
            return "not linked"
        case .checking:
            return "checking"
        }
    }
}
