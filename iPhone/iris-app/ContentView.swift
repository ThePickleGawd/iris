import SwiftUI
import Foundation
import UIKit
import Combine
import PhotosUI
import AVFoundation

struct SessionSummary: Identifiable, Hashable {
    let id: String
    let createdAt: String
    let updatedAt: String
    let name: String
    let status: String
    let transcriptCount: Int
    let pendingCommandCount: Int
    let latestStatusHeadline: String?
    let latestStatusPhase: String?
    let latestStatusUpdatedAt: String?
}

struct SessionStatusSnapshot: Hashable {
    let phase: String
    let headline: String
    let detail: String
    let updatedAt: String?
    let queuedCount: Int
    let inProgressCount: Int
    let completedCount: Int
    let failedCount: Int
}

struct SessionScreenshot: Identifiable, Hashable {
    let id: String
    let deviceID: String
    let capturedAt: String?
    let createdAt: String?
    let fileURL: String
    let notes: String?
}

struct AgentChatMessage: Identifiable, Hashable {
    let id: String
    let entryType: String
    let role: String
    let text: String
    let eventAt: String
    let createdAt: String?
    let sourceDeviceID: String?
}

@MainActor
final class IrisPhoneState: ObservableObject {
    @Published var backendBaseURL: String
    @Published var deviceID: String

    @Published var sessions: [SessionSummary] = []
    @Published var sessionStatus: [String: SessionStatusSnapshot] = [:]
    @Published var sessionSnapshots: [String: [SessionScreenshot]] = [:]
    @Published var sessionChatMessages: [String: [AgentChatMessage]] = [:]

    @Published var isBusy: Bool = false
    @Published var lastError: String?
    @Published var lastTranscriptID: String?
    @Published var lastScreenshotID: String?

    private let defaults = UserDefaults.standard
    private let backendKey = "iris_phone_backend_base_url"
    private let deviceIDKey = "iris_phone_device_id"

    init() {
        self.backendBaseURL = defaults.string(forKey: backendKey) ?? "http://127.0.0.1:5001"
        self.deviceID = defaults.string(forKey: deviceIDKey) ?? "iPhone"
    }

    func persistConfig() {
        let normalizedBackend = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeviceID = normalizedDeviceID()

        backendBaseURL = normalizedBackend.isEmpty ? "http://127.0.0.1:5001" : normalizedBackend
        deviceID = normalizedDeviceID

        defaults.set(backendBaseURL, forKey: backendKey)
        defaults.set(deviceID, forKey: deviceIDKey)
    }

    func clearError() {
        lastError = nil
    }

    func fetchSessions() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let raw = try await requestJSON(path: "/api/sessions", query: [
                URLQueryItem(name: "status", value: "active"),
                URLQueryItem(name: "limit", value: "100")
            ])
            guard let dict = raw as? [String: Any] else { throw makeError("Unexpected sessions response") }
            let parsed = (dict["items"] as? [[String: Any]] ?? []).compactMap(parseSession)
            self.sessions = parsed
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func createSession(name: String) async -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeviceID = normalizedDeviceID()

        isBusy = true
        defer { isBusy = false }

        do {
            var body: [String: Any] = ["source_device_id": normalizedDeviceID]
            if !trimmedName.isEmpty {
                body["name"] = trimmedName
            }

            let raw = try await requestJSON(path: "/api/sessions", method: "POST", body: body)
            if let created = (raw as? [String: Any]).flatMap(parseSession) {
                upsertSession(created)
            }
            await fetchSessions()
            lastError = nil
            return nil
        } catch {
            let message = error.localizedDescription
            lastError = message
            return message
        }
    }

    func sendTranscript(text: String, sessionID: String, source: String = "speech") async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Transcript text is empty."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let body: [String: Any] = [
                "session_id": sessionID,
                "text": trimmed,
                "device_id": deviceID,
                "source": source,
                "captured_at": ISO8601DateFormatter().string(from: Date())
            ]
            let raw = try await requestJSON(path: "/api/transcripts", method: "POST", body: body)
            guard let dict = raw as? [String: Any] else { throw makeError("Unexpected transcript response") }
            self.lastTranscriptID = dict["id"] as? String
            self.lastError = nil
            await fetchSessions()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func uploadScreenshot(imageData: Data, sessionID: String) async -> String? {
        isBusy = true
        defer { isBusy = false }

        do {
            let boundary = "Boundary-\(UUID().uuidString)"
            var request = URLRequest(url: try makeURL(path: "/api/screenshots", query: []))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var body = Data()
            let capturedAt = ISO8601DateFormatter().string(from: Date())
            let normalizedDeviceID = normalizedDeviceID()
            let filename = "camera-\(UUID().uuidString).jpg"

            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"session_id\"\r\n\r\n")
            body.appendUTF8("\(sessionID)\r\n")

            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"device_id\"\r\n\r\n")
            body.appendUTF8("\(normalizedDeviceID)\r\n")

            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"source\"\r\n\r\n")
            body.appendUTF8("camera\r\n")

            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"captured_at\"\r\n\r\n")
            body.appendUTF8("\(capturedAt)\r\n")

            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"screenshot\"; filename=\"\(filename)\"\r\n")
            body.appendUTF8("Content-Type: image/jpeg\r\n\r\n")
            body.append(imageData)
            body.appendUTF8("\r\n")
            body.appendUTF8("--\(boundary)--\r\n")

            request.httpBody = body

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw makeError("No HTTP response")
            }

            let parsed: Any
            if data.isEmpty {
                parsed = [String: Any]()
            } else {
                parsed = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
            }

            guard (200..<300).contains(http.statusCode) else {
                if let dict = parsed as? [String: Any], let message = dict["error"] as? String {
                    throw makeError("\(message) (\(http.statusCode))")
                }
                let fallback = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw makeError(fallback)
            }

            if let dict = parsed as? [String: Any] {
                lastScreenshotID = dict["id"] as? String
            }
            lastError = nil
            await fetchSessions()
            return nil
        } catch {
            let message = error.localizedDescription
            lastError = message
            return message
        }
    }

    func fetchStatus(sessionID: String) async {
        do {
            let raw = try await requestJSON(path: "/api/agent-status", query: [
                URLQueryItem(name: "session_id", value: sessionID)
            ])
            guard let dict = raw as? [String: Any] else { throw makeError("Unexpected status response") }

            let statusDict = dict["status"] as? [String: Any]
            let counts = dict["command_counts"] as? [String: Int] ?? [:]

            let snapshot = SessionStatusSnapshot(
                phase: (statusDict?["phase"] as? String) ?? "idle",
                headline: (statusDict?["headline"] as? String) ?? "No status yet",
                detail: (statusDict?["detail"] as? String) ?? "",
                updatedAt: statusDict?["updated_at"] as? String,
                queuedCount: counts["queued"] ?? 0,
                inProgressCount: counts["in_progress"] ?? 0,
                completedCount: counts["completed"] ?? 0,
                failedCount: counts["failed"] ?? 0
            )

            sessionStatus[sessionID] = snapshot
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func fetchSnapshots(sessionID: String, limit: Int = 200) async {
        do {
            let raw = try await requestJSON(path: "/api/screenshots", query: [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "limit", value: String(limit))
            ])
            guard let dict = raw as? [String: Any] else { throw makeError("Unexpected screenshots response") }
            let parsed = (dict["items"] as? [[String: Any]] ?? []).compactMap(parseSnapshot)
            sessionSnapshots[sessionID] = parsed.sorted { lhs, rhs in
                snapshotSortDate(lhs) > snapshotSortDate(rhs)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func fetchAgentChat(sessionID: String, limit: Int = 200) async {
        do {
            let raw = try await requestJSON(path: "/api/agent-chat", query: [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "limit", value: String(limit))
            ])
            guard let dict = raw as? [String: Any] else { throw makeError("Unexpected agent chat response") }
            let parsed = (dict["items"] as? [[String: Any]] ?? []).compactMap(parseAgentChatMessage)
            sessionChatMessages[sessionID] = parsed.sorted { lhs, rhs in
                chatSortDate(lhs) < chatSortDate(rhs)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func parseSession(dict: [String: Any]) -> SessionSummary? {
        guard let id = dict["id"] as? String else {
            return nil
        }
        let createdAt = dict["created_at"] as? String ?? ""
        let updatedAt = dict["updated_at"] as? String ?? createdAt
        let name = ((dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "Untitled Session"
        let status = (dict["status"] as? String ?? "active").lowercased()

        return SessionSummary(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            name: name,
            status: status,
            transcriptCount: parseInt(dict["transcript_count"]),
            pendingCommandCount: parseInt(dict["pending_command_count"]),
            latestStatusHeadline: dict["latest_status_headline"] as? String,
            latestStatusPhase: dict["latest_status_phase"] as? String,
            latestStatusUpdatedAt: dict["latest_status_updated_at"] as? String
        )
    }

    private func parseSnapshot(dict: [String: Any]) -> SessionScreenshot? {
        guard
            let id = dict["id"] as? String,
            let fileURL = dict["file_url"] as? String
        else {
            return nil
        }

        return SessionScreenshot(
            id: id,
            deviceID: (dict["device_id"] as? String) ?? "Unknown device",
            capturedAt: dict["captured_at"] as? String,
            createdAt: dict["created_at"] as? String,
            fileURL: fileURL,
            notes: dict["notes"] as? String
        )
    }

    private func parseAgentChatMessage(dict: [String: Any]) -> AgentChatMessage? {
        guard
            let id = dict["id"] as? String,
            let entryType = dict["entry_type"] as? String,
            let role = dict["role"] as? String,
            let text = dict["text"] as? String,
            let eventAt = dict["event_ts"] as? String
        else {
            return nil
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return nil
        }

        return AgentChatMessage(
            id: id,
            entryType: entryType,
            role: role,
            text: trimmedText,
            eventAt: eventAt,
            createdAt: dict["created_at"] as? String,
            sourceDeviceID: dict["source_device_id"] as? String
        )
    }

    private func snapshotSortDate(_ snapshot: SessionScreenshot) -> Date {
        if let value = snapshot.capturedAt ?? snapshot.createdAt,
           let parsed = ISO8601DateFormatter().date(from: value) {
            return parsed
        }
        return .distantPast
    }

    private func chatSortDate(_ item: AgentChatMessage) -> Date {
        if let parsed = ISO8601DateFormatter().date(from: item.eventAt) {
            return parsed
        }
        if let value = item.createdAt, let parsed = ISO8601DateFormatter().date(from: value) {
            return parsed
        }
        return .distantPast
    }

    private func upsertSession(_ session: SessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    private func parseInt(_ value: Any?) -> Int {
        if let i = value as? Int {
            return i
        }
        if let n = value as? NSNumber {
            return n.intValue
        }
        if let s = value as? String, let i = Int(s) {
            return i
        }
        return 0
    }

    private func normalizedDeviceID() -> String {
        let trimmed = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "iPhone" : trimmed
    }

    private func requestJSON(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> Any {
        var request = URLRequest(url: try makeURL(path: path, query: query))
        request.httpMethod = method

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeError("No HTTP response")
        }

        let parsed: Any
        if data.isEmpty {
            parsed = [String: Any]()
        } else {
            parsed = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
        }

        guard (200..<300).contains(http.statusCode) else {
            if let dict = parsed as? [String: Any], let message = dict["error"] as? String {
                throw makeError("\(message) (\(http.statusCode))")
            }
            let fallback = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw makeError(fallback)
        }

        return parsed
    }

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        let base = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base), !base.isEmpty else {
            throw makeError("Backend URL is invalid")
        }

        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: baseURL.appendingPathComponent(normalizedPath), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query

        guard let url = components?.url else {
            throw makeError("Could not build request URL")
        }
        return url
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "IrisPhone", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum SessionTab: String, CaseIterable, Identifiable {
    case record = "Record"
    case camera = "Camera"
    case status = "Status"

    var id: String { rawValue }
}

private enum ShutterFeedback {
    case idle
    case success
    case error
}

struct ContentView: View {
    @EnvironmentObject var appState: IrisPhoneState
    @StateObject private var audioService = AudioCaptureService()
    @StateObject private var cameraController = CameraCaptureController()

    let session: SessionSummary

    @State private var selectedTab: SessionTab = .record
    @State private var transcriptText: String = ""
    @State private var didStartTouchRecording = false
    @State private var isMicPressed = false
    @State private var isSendingTranscript = false
    @State private var recordFeedbackStyle: ShutterFeedback = .idle

    @State private var showingPhotoLibraryPicker = false
    @State private var selectedLibraryImages: [UIImage] = []
    @State private var cameraHint: String?
    @State private var cameraUploadError: String?
    @State private var cameraUploadSuccess: String?
    @State private var isUploadingCapture = false
    @State private var cameraFlashOpacity: Double = 0
    @State private var shutterFeedback: ShutterFeedback = .idle
    @State private var shutterPulse: Bool = false
    @State private var statusChatDraft: String = ""
    @State private var isSendingStatusChat: Bool = false
    @State private var shouldScrollStatusChatToBottom: Bool = false
    @FocusState private var isStatusInputFocused: Bool
    private let shutterButtonSize: CGFloat = 92
    private let secondaryActionSize: CGFloat = 52
    private let actionButtonBottomPadding: CGFloat = 40
    private let actionFooterBottomPadding: CGFloat = 4
    private let statusRefreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var actionSubtextBottomPadding: CGFloat {
        actionButtonBottomPadding + shutterButtonSize + 68
    }

    private var statusSnapshot: SessionStatusSnapshot? {
        appState.sessionStatus[session.id]
    }

    private var snapshots: [SessionScreenshot] {
        appState.sessionSnapshots[session.id] ?? []
    }

    private var latestSnapshot: SessionScreenshot? {
        snapshots.first
    }

    private var chatMessages: [AgentChatMessage] {
        appState.sessionChatMessages[session.id] ?? []
    }

    private var pttGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                isMicPressed = true
                guard !didStartTouchRecording else { return }
                didStartTouchRecording = true
                transcriptText = ""
                audioService.liveTranscript = ""
                audioService.startTranscription()
            }
            .onEnded { _ in
                isMicPressed = false
                guard didStartTouchRecording else { return }
                didStartTouchRecording = false
                audioService.stopTranscription(cancelTask: false)
                Task {
                    await sendPushToTalkTranscript()
                }
            }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Picker("Session Tab", selection: $selectedTab) {
                    ForEach(SessionTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                TabView(selection: $selectedTab) {
                    recordTab
                        .tag(SessionTab.record)
                    cameraTab
                        .tag(SessionTab.camera)
                    statusTab
                        .tag(SessionTab.status)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(audioService.$liveTranscript) { partial in
            guard audioService.isRecording else { return }
            transcriptText = partial
        }
        .task {
            async let statusTask: Void = appState.fetchStatus(sessionID: session.id)
            async let chatTask: Void = appState.fetchAgentChat(sessionID: session.id)
            _ = await (statusTask, chatTask)
            cameraController.prepare()
            updateCameraLifecycle(for: selectedTab)
        }
        .fullScreenCover(isPresented: $showingPhotoLibraryPicker) {
            PhotoLibraryPicker(selectedImages: $selectedLibraryImages)
                .ignoresSafeArea()
        }
        .onChange(of: cameraController.capturedImage) { _, image in
            guard let image else { return }
            triggerCameraPreviewFlash()
            Task {
                await uploadCapturedImage(image)
                cameraController.capturedImage = nil
            }
        }
        .onChange(of: cameraController.captureError) { _, message in
            guard let message, !message.isEmpty else { return }
            showCameraFeedback(success: false)
            cameraController.captureError = nil
        }
        .onChange(of: selectedLibraryImages) { _, images in
            guard !images.isEmpty else { return }
            Task {
                await uploadSelectedImages(images)
                selectedLibraryImages = []
            }
        }
        .onChange(of: selectedTab) { _, tab in
            updateCameraLifecycle(for: tab)
            if tab == .status {
                shouldScrollStatusChatToBottom = true
            } else {
                isStatusInputFocused = false
            }
        }
        .onDisappear {
            cameraController.stop()
        }
        .onReceive(statusRefreshTimer) { _ in
            guard selectedTab == .status else { return }
            Task {
                async let statusTask: Void = appState.fetchStatus(sessionID: session.id)
                async let chatTask: Void = appState.fetchAgentChat(sessionID: session.id)
                _ = await (statusTask, chatTask)
            }
        }
    }

    private var recordTab: some View {
        ZStack {
            LiveWaveformView(
                audioLevel: audioService.audioLevel,
                isActive: audioService.isRecording
            )
            .frame(height: 180)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(y: -36)
            .padding(.horizontal, 8)

            ShutterButton(
                size: shutterButtonSize,
                iconName: "mic.fill",
                iconTint: Color.black.opacity(0.78),
                isPressed: isMicPressed
            )
            .overlay {
                if audioService.isRecording || isSendingTranscript {
                    ActivityRing(
                        size: shutterButtonSize + 18,
                        tint: audioService.isRecording ? .red : .blue
                    )
                }
                switch recordFeedbackStyle {
                case .idle:
                    EmptyView()
                case .success:
                    Circle()
                        .stroke(Color.green.opacity(0.92), lineWidth: 4)
                        .frame(width: shutterButtonSize + 20, height: shutterButtonSize + 20)
                case .error:
                    Circle()
                        .stroke(Color.red.opacity(0.92), lineWidth: 4)
                        .frame(width: shutterButtonSize + 20, height: shutterButtonSize + 20)
                }
            }
            .contentShape(Circle())
            .gesture(pttGesture)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, actionButtonBottomPadding)

            Text("Hold to talk. Release to send.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, actionSubtextBottomPadding)

            if let micError = audioService.errorMessage {
                Text(micError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, actionFooterBottomPadding)
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    private var cameraTab: some View {
        ZStack {
            Group {
                if cameraController.isPreviewAvailable {
                    CameraLivePreview(session: cameraController.session)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.title2)
                        Text(cameraController.statusMessage)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white)
                    .opacity(cameraFlashOpacity)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 6)
            .padding(.bottom, actionButtonBottomPadding + shutterButtonSize + 20)

            Button {
                captureInlinePhoto()
            } label: {
                ShutterButton(size: shutterButtonSize)
                    .overlay {
                        if isUploadingCapture {
                            ActivityRing(
                                size: shutterButtonSize + 18,
                                tint: .blue
                            )
                        }
                        switch shutterFeedback {
                        case .idle:
                            EmptyView()
                        case .success:
                            Circle()
                                .stroke(Color.green.opacity(0.92), lineWidth: 4)
                                .frame(width: shutterButtonSize + 20, height: shutterButtonSize + 20)
                        case .error:
                            Circle()
                                .stroke(Color.red.opacity(0.92), lineWidth: 4)
                                .frame(width: shutterButtonSize + 20, height: shutterButtonSize + 20)
                        }
                    }
            }
            .scaleEffect(shutterPulse ? 0.92 : 1.0)
            .animation(.spring(response: 0.26, dampingFraction: 0.56), value: shutterPulse)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, actionButtonBottomPadding)

            Text("Tap shutter to capture and upload.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, actionSubtextBottomPadding)

            if let hint = cameraHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
            }

            ZStack {
                HStack {
                    Button {
                        openPhotoLibrary()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                .frame(width: secondaryActionSize, height: secondaryActionSize)
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 20)
            .padding(.bottom, actionButtonBottomPadding + ((shutterButtonSize - secondaryActionSize) / 2))
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    private var statusTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if chatMessages.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.title3)
                                Text("No agent replies yet.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                        } else {
                            ForEach(chatMessages) { message in
                                HStack {
                                    if message.role == "assistant" {
                                        AgentChatBubble(message: message, relativeTime: relativeTimestamp(message.eventAt))
                                        Spacer(minLength: 36)
                                    } else {
                                        Spacer(minLength: 36)
                                        AgentChatBubble(message: message, relativeTime: relativeTimestamp(message.eventAt))
                                    }
                                }
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("status-chat-bottom")
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    isStatusInputFocused = false
                }
                .onAppear {
                    guard selectedTab == .status else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("status-chat-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: selectedTab) { _, tab in
                    guard tab == .status else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("status-chat-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: chatMessages.count) { _, _ in
                    guard shouldScrollStatusChatToBottom else { return }
                    shouldScrollStatusChatToBottom = false
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("status-chat-bottom", anchor: .bottom)
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message agent", text: $statusChatDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($isStatusInputFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        Task {
                            await sendStatusChatMessage()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    Task {
                        await sendStatusChatMessage()
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle((statusChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingStatusChat) ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .disabled(statusChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingStatusChat)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .refreshable {
            await refreshStatusData()
        }
    }

    private func refreshStatusData() async {
        async let statusTask: Void = appState.fetchStatus(sessionID: session.id)
        async let chatTask: Void = appState.fetchAgentChat(sessionID: session.id)
        _ = await (statusTask, chatTask)
    }

    private func sendStatusChatMessage() async {
        let trimmed = statusChatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSendingStatusChat = true
        defer { isSendingStatusChat = false }

        statusChatDraft = ""
        isStatusInputFocused = false
        shouldScrollStatusChatToBottom = true
        await appState.sendTranscript(text: trimmed, sessionID: session.id, source: "chat")
        await appState.fetchAgentChat(sessionID: session.id)
    }

    private func updateCameraLifecycle(for tab: SessionTab) {
        if tab == .camera {
            cameraController.start()
            cameraHint = nil
            return
        }
        cameraController.stop()
    }

    private func captureInlinePhoto() {
        cameraUploadError = nil
        cameraUploadSuccess = nil
        cameraHint = nil
        cameraController.capturePhoto()
    }

    private func openPhotoLibrary() {
        cameraHint = nil
        cameraUploadError = nil
        cameraUploadSuccess = nil
        showingPhotoLibraryPicker = true
    }

    private func uploadCapturedImage(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            showCameraFeedback(success: false)
            return
        }
        isUploadingCapture = true
        defer { isUploadingCapture = false }

        cameraUploadError = nil
        cameraUploadSuccess = nil

        let error = await appState.uploadScreenshot(
            imageData: data,
            sessionID: session.id
        )
        if let error, !error.isEmpty {
            cameraUploadError = "Upload failed: \(error)"
            showCameraFeedback(success: false)
        } else {
            cameraUploadError = nil
            showCameraFeedback(success: true)
        }
    }

    private func uploadSelectedImages(_ images: [UIImage]) async {
        isUploadingCapture = true
        defer { isUploadingCapture = false }
        cameraUploadError = nil
        cameraUploadSuccess = nil

        var successCount = 0
        var failedCount = 0
        var firstErrorMessage: String?

        for image in images {
            guard let data = image.jpegData(compressionQuality: 0.9) else {
                failedCount += 1
                firstErrorMessage = firstErrorMessage ?? "Could not encode one of the selected images."
                continue
            }

            let error = await appState.uploadScreenshot(
                imageData: data,
                sessionID: session.id
            )
            if let error, !error.isEmpty {
                failedCount += 1
                firstErrorMessage = firstErrorMessage ?? error
            } else {
                successCount += 1
            }
        }

        if failedCount == 0 {
            cameraUploadSuccess = "Uploaded \(successCount) photo\(successCount == 1 ? "" : "s")."
            cameraUploadError = nil
            showCameraFeedback(success: true)
            return
        }

        if successCount > 0 {
            cameraUploadSuccess = "Uploaded \(successCount) photo\(successCount == 1 ? "" : "s"), \(failedCount) failed."
            showCameraFeedback(success: false)
        } else {
            cameraUploadSuccess = nil
            showCameraFeedback(success: false)
        }
        cameraUploadError = firstErrorMessage ?? "Upload failed."
    }

    private func showCameraFeedback(success: Bool) {
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(success ? .success : .error)

        shutterFeedback = success ? .success : .error

        shutterPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            shutterPulse = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                shutterFeedback = .idle
            }
        }
    }

    private func triggerCameraPreviewFlash() {
        guard selectedTab == .camera else { return }
        cameraFlashOpacity = 0.88
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                cameraFlashOpacity = 0.0
            }
        }
    }

    private func sendPushToTalkTranscript() async {
        isSendingTranscript = true
        defer { isSendingTranscript = false }

        try? await Task.sleep(nanoseconds: 150_000_000)
        let liveText = audioService.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = liveText.isEmpty ? fallbackText : liveText
        guard !text.isEmpty else {
            showRecordFeedback(success: false)
            return
        }

        transcriptText = text
        audioService.errorMessage = nil
        await appState.sendTranscript(text: text, sessionID: session.id)
        if appState.lastError != nil {
            showRecordFeedback(success: false)
        } else {
            showRecordFeedback(success: true)
            transcriptText = ""
            audioService.liveTranscript = ""
        }
    }

    private func showRecordFeedback(success: Bool) {
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(success ? .success : .error)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
            recordFeedbackStyle = success ? .success : .error
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.2)) {
                recordFeedbackStyle = .idle
            }
        }
    }

    private func relativeTimestamp(_ raw: String) -> String {
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: raw) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return raw
    }
}

private struct LiveWaveformView: View {
    let audioLevel: Float
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<28, id: \.self) { idx in
                    let seed = Double(idx) * 0.41
                    let oscillation = abs(sin((t * 4.8) + seed))
                    let base = isActive ? CGFloat(max(audioLevel, 0.05)) : 0.04
                    let height = max(8, (base * 115) * (0.28 + CGFloat(oscillation)))

                    Capsule(style: .continuous)
                        .fill(isActive ? Color.red.opacity(0.9) : Color.secondary.opacity(0.35))
                        .frame(width: 4, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 10)
        }
    }
}

private struct ShutterButton: View {
    let size: CGFloat
    var iconName: String? = nil
    var iconTint: Color = .black
    var isPressed: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: isPressed
                            ? [Color(white: 0.88), Color(white: 0.80)]
                            : [Color.white.opacity(0.98), Color.white.opacity(0.9)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Circle()
                .stroke(Color.black.opacity(0.24), lineWidth: 2)
                .padding(7)
            Circle()
                .stroke(Color.white.opacity(0.65), lineWidth: 1)
                .padding(2)

            if let iconName {
                Image(systemName: iconName)
                    .font(.system(size: size * 0.32, weight: .medium))
                    .foregroundStyle(iconTint)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.28), radius: 8, y: 4)
    }
}

private struct ActivityRing: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0.08, to: 0.82)
                .stroke(
                    tint.opacity(0.82),
                    style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                )
                .rotationEffect(.degrees((t * 180).truncatingRemainder(dividingBy: 360)))
                .frame(width: size, height: size)
        }
        .allowsHitTesting(false)
    }
}

private struct AgentChatBubble: View {
    let message: AgentChatMessage
    let relativeTime: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.text)
                .font(.subheadline)
                .multilineTextAlignment(.leading)

            HStack(spacing: 6) {
                Text(senderLabel)
                Text("•")
                Text(relativeTime)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .foregroundStyle(message.role == "assistant" ? Color.primary : Color.white)
        .background(
            message.role == "assistant"
                ? Color(uiColor: .secondarySystemGroupedBackground)
                : Color.blue.opacity(0.88),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(message.role == "assistant" ? 0.16 : 0), lineWidth: 1)
        )
    }

    private var senderLabel: String {
        if message.role == "assistant" {
            return "Agent"
        }
        if let source = message.sourceDeviceID, !source.isEmpty {
            return source
        }
        return "Input"
    }
}

private struct CameraLivePreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

final class CameraCaptureController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()

    @Published var isPreviewAvailable = false
    @Published var statusMessage = "Preparing camera..."
    @Published var capturedImage: UIImage?
    @Published var captureError: String?

    private let sessionQueue = DispatchQueue(label: "IrisPhone.CameraSession")
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private var wantsRunning = false
    private var isConfiguring = false

    func prepare() {
        sessionQueue.async { [weak self] in
            self?.configureIfNeeded()
        }
    }

    func start() {
        wantsRunning = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            guard self.isConfigured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        wantsRunning = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured else {
                DispatchQueue.main.async {
                    self.captureError = "Camera is not ready yet."
                }
                return
            }

            var settings = AVCapturePhotoSettings()
            if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured, !isConfiguring else { return }
        isConfiguring = true
        defer { isConfiguring = false }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.sessionQueue.async {
                    if granted {
                        self.configureSession()
                    } else {
                        DispatchQueue.main.async {
                            self.isPreviewAvailable = false
                            self.statusMessage = "Camera access denied. Enable it in Settings."
                        }
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.isPreviewAvailable = false
                self.statusMessage = "Camera access denied. Enable it in Settings."
            }
        @unknown default:
            DispatchQueue.main.async {
                self.isPreviewAvailable = false
                self.statusMessage = "Camera unavailable."
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        defer {
            session.commitConfiguration()
        }

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        else {
            DispatchQueue.main.async {
                self.isPreviewAvailable = false
                self.statusMessage = "No camera device found."
            }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                DispatchQueue.main.async {
                    self.isPreviewAvailable = false
                    self.statusMessage = "Could not initialize camera input."
                }
                return
            }
        } catch {
            DispatchQueue.main.async {
                self.isPreviewAvailable = false
                self.statusMessage = "Camera setup failed: \(error.localizedDescription)"
            }
            return
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.isHighResolutionCaptureEnabled = true
        } else {
            DispatchQueue.main.async {
                self.isPreviewAvailable = false
                self.statusMessage = "Could not initialize camera output."
            }
            return
        }

        isConfigured = true
        DispatchQueue.main.async {
            self.isPreviewAvailable = true
            self.statusMessage = "Camera ready"
        }

        if wantsRunning, !session.isRunning {
            session.startRunning()
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async {
                self.captureError = "Capture failed: \(error.localizedDescription)"
            }
            return
        }

        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            DispatchQueue.main.async {
                self.captureError = "Could not process captured image."
            }
            return
        }

        DispatchQueue.main.async {
            self.capturedImage = image
        }
    }
}

private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    @Binding var selectedImages: [UIImage]
    @Environment(\.dismiss) private var dismiss

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPicker

        init(parent: PhotoLibraryPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }

            var images: [UIImage] = []
            let lock = NSLock()
            let group = DispatchGroup()

            for result in results {
                guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }
                group.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    guard let image = object as? UIImage else { return }
                    lock.lock()
                    images.append(image)
                    lock.unlock()
                }
            }

            group.notify(queue: .main) {
                self.parent.selectedImages = images
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        if let data = value.data(using: .utf8) {
            append(data)
        }
    }
}

#Preview {
    NavigationStack {
        ContentView(
            session: SessionSummary(
                id: "s1",
                createdAt: "",
                updatedAt: "",
                name: "Demo Session",
                status: "active",
                transcriptCount: 3,
                pendingCommandCount: 1,
                latestStatusHeadline: "Running",
                latestStatusPhase: "executing",
                latestStatusUpdatedAt: nil
            )
        )
        .environmentObject(IrisPhoneState())
    }
}
