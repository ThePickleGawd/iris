import SwiftUI
import Foundation
import UIKit
import Combine

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
    let fileURL: String
    let notes: String?
}

@MainActor
final class IrisPhoneState: ObservableObject {
    @Published var backendBaseURL: String
    @Published var deviceID: String

    @Published var sessions: [SessionSummary] = []
    @Published var sessionStatus: [String: SessionStatusSnapshot] = [:]
    @Published var sessionSnapshots: [String: [SessionScreenshot]] = [:]

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

    func uploadScreenshot(imageData: Data, sessionID: String, notes: String?) async -> String? {
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
            let trimmedNotes = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

            if !trimmedNotes.isEmpty {
                body.appendUTF8("--\(boundary)\r\n")
                body.appendUTF8("Content-Disposition: form-data; name=\"notes\"\r\n\r\n")
                body.appendUTF8("\(trimmedNotes)\r\n")
            }

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

    func fetchSnapshots(sessionID: String, limit: Int = 12) async {
        do {
            let raw = try await requestJSON(path: "/api/screenshots", query: [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "limit", value: String(limit))
            ])
            guard let dict = raw as? [String: Any] else { throw makeError("Unexpected screenshots response") }
            let parsed = (dict["items"] as? [[String: Any]] ?? []).compactMap(parseSnapshot)
            sessionSnapshots[sessionID] = parsed.sorted { ($0.capturedAt ?? "") > ($1.capturedAt ?? "") }
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
            fileURL: fileURL,
            notes: dict["notes"] as? String
        )
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

struct ContentView: View {
    @EnvironmentObject var appState: IrisPhoneState
    @StateObject private var audioService = AudioCaptureService()

    let session: SessionSummary

    @State private var selectedTab: SessionTab = .record
    @State private var transcriptText: String = ""
    @State private var didStartTouchRecording = false
    @State private var isSendingTranscript = false
    @State private var recordFeedback: String?

    @State private var showingCameraPicker = false
    @State private var cameraSource: UIImagePickerController.SourceType = .camera
    @State private var capturedImage: UIImage?
    @State private var screenshotNotes = ""
    @State private var cameraHint: String?
    @State private var cameraUploadError: String?
    @State private var cameraUploadSuccess: String?
    private let statusRefreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var statusSnapshot: SessionStatusSnapshot? {
        appState.sessionStatus[session.id]
    }

    private var snapshots: [SessionScreenshot] {
        appState.sessionSnapshots[session.id] ?? []
    }

    private var latestSnapshot: SessionScreenshot? {
        snapshots.first
    }

    private var pendingActions: Int {
        (statusSnapshot?.queuedCount ?? 0) + (statusSnapshot?.inProgressCount ?? 0)
    }

    private var pttGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !didStartTouchRecording else { return }
                didStartTouchRecording = true
                recordFeedback = nil
                transcriptText = ""
                audioService.liveTranscript = ""
                audioService.startTranscription()
            }
            .onEnded { _ in
                guard didStartTouchRecording else { return }
                didStartTouchRecording = false
                audioService.stopTranscription(cancelTask: false)
                Task {
                    await sendPushToTalkTranscript()
                }
            }
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)

                Text("Session ID: \(session.id)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Picker("Session Tab", selection: $selectedTab) {
                ForEach(SessionTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            Group {
                switch selectedTab {
                case .record:
                    recordTab
                case .camera:
                    cameraTab
                case .status:
                    statusTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(audioService.$liveTranscript) { partial in
            guard audioService.isRecording else { return }
            transcriptText = partial
        }
        .task {
            async let statusTask: Void = appState.fetchStatus(sessionID: session.id)
            async let snapshotTask: Void = appState.fetchSnapshots(sessionID: session.id)
            _ = await (statusTask, snapshotTask)
        }
        .fullScreenCover(isPresented: $showingCameraPicker) {
            CameraPicker(sourceType: cameraSource, selectedImage: $capturedImage)
                .ignoresSafeArea()
        }
        .onReceive(statusRefreshTimer) { _ in
            guard selectedTab == .status else { return }
            Task {
                async let statusTask: Void = appState.fetchStatus(sessionID: session.id)
                async let snapshotTask: Void = appState.fetchSnapshots(sessionID: session.id)
                _ = await (statusTask, snapshotTask)
            }
        }
    }

    private var recordTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Push To Talk", systemImage: "mic.fill")
                    .font(.title3.weight(.semibold))

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(audioService.isRecording ? Color.red : Color.blue)
                        .frame(height: 180)

                    VStack(spacing: 10) {
                        Image(systemName: audioService.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 48, weight: .bold))
                        Text(audioService.isRecording ? "Release To Send" : "Hold To Talk")
                            .font(.title3.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                }
                .contentShape(RoundedRectangle(cornerRadius: 20))
                .gesture(pttGesture)

                Text(transcriptText.isEmpty ? "Transcript will appear here while you talk." : transcriptText)
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if audioService.isRecording || isSendingTranscript {
                    ProgressView(audioService.isRecording ? "Listening..." : "Sending...")
                }

                ProgressView(value: Double(min(max(audioService.audioLevel * 20, 0), 1)))
                    .opacity(audioService.isRecording ? 1 : 0)
                    .tint(.red)

                if let micError = audioService.errorMessage {
                    Text(micError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let recordFeedback {
                    Text(recordFeedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let lastTranscriptID = appState.lastTranscriptID {
                    Text("Last transcript ID: \(lastTranscriptID)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        }
    }

    private var cameraTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Camera Capture", systemImage: "camera.fill")
                    .font(.title3.weight(.semibold))

                Text("Capture a photo or screenshot and attach it to this session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("If simulator camera appears gray, use Simulator > Features > Camera, or test on a physical iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Group {
                    if let capturedImage {
                        Image(uiImage: capturedImage)
                            .resizable()
                            .scaledToFit()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.title2)
                            Text("No image selected yet")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                }
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                TextField("Optional notes", text: $screenshotNotes)
                    .textInputAutocapitalization(.sentences)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 12) {
                    Button {
                        openCamera()
                    } label: {
                        Label("Open Camera", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button {
                        openPhotoLibrary()
                    } label: {
                        Label("Photo Library", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    Task { await uploadCapturedImage() }
                } label: {
                    Label("Upload", systemImage: "icloud.and.arrow.up.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(capturedImage == nil || appState.isBusy)

                if let hint = cameraHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let cameraUploadError {
                    Text(cameraUploadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let cameraUploadSuccess {
                    Text(cameraUploadSuccess)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
            .padding(16)
        }
    }

    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Monitoring", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        Task {
                            async let statusTask: Void = appState.fetchStatus(sessionID: session.id)
                            async let snapshotTask: Void = appState.fetchSnapshots(sessionID: session.id)
                            _ = await (statusTask, snapshotTask)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(statusSnapshot?.headline ?? "No agent update yet.")
                        .font(.title3.weight(.semibold))

                    if let updatedAt = statusSnapshot?.updatedAt {
                        Text("Updated \(shortTimestamp(updatedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Pending: \(pendingActions)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        let failures = statusSnapshot?.failedCount ?? 0
                        if failures > 0 {
                            Text("Failed: \(failures)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(12)
                .background(Color(uiColor: .tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Latest Device Screen")
                            .font(.headline)
                        Spacer()
                        Text("\(snapshots.count) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let snapshot = latestSnapshot, let url = URL(string: snapshot.fileURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure(_):
                                Color.gray.opacity(0.2)
                            case .empty:
                                ProgressView()
                            @unknown default:
                                Color.gray.opacity(0.2)
                            }
                        }
                        .frame(height: 210)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Text("\(snapshot.deviceID) · \(snapshot.capturedAt.map(shortTimestamp) ?? "Unknown time")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No screenshots received yet from your devices.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            cameraSource = .camera
            cameraHint = nil
        } else {
            cameraSource = .photoLibrary
            cameraHint = "Camera is unavailable here, so the photo library was opened instead."
        }
        cameraUploadError = nil
        cameraUploadSuccess = nil
        showingCameraPicker = true
    }

    private func openPhotoLibrary() {
        cameraSource = .photoLibrary
        cameraHint = nil
        cameraUploadError = nil
        cameraUploadSuccess = nil
        showingCameraPicker = true
    }

    private func uploadCapturedImage() async {
        guard let image = capturedImage else {
            cameraUploadError = "Capture an image first."
            cameraUploadSuccess = nil
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            cameraUploadError = "Could not encode image."
            cameraUploadSuccess = nil
            return
        }

        cameraUploadError = nil
        cameraUploadSuccess = nil

        let error = await appState.uploadScreenshot(
            imageData: data,
            sessionID: session.id,
            notes: screenshotNotes
        )
        if let error, !error.isEmpty {
            cameraUploadError = "Upload failed: \(error)"
            cameraUploadSuccess = nil
        } else {
            cameraUploadError = nil
            cameraUploadSuccess = "Uploaded to this session."
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
            recordFeedback = "No speech detected."
            return
        }

        transcriptText = text
        audioService.errorMessage = nil
        await appState.sendTranscript(text: text, sessionID: session.id)
        if let error = appState.lastError {
            recordFeedback = "Send failed: \(error)"
        } else {
            recordFeedback = "Sent."
            transcriptText = ""
            audioService.liveTranscript = ""
        }
    }

    private func shortTimestamp(_ raw: String) -> String {
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: raw) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return raw
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    @Binding var selectedImage: UIImage?
    @Environment(\.dismiss) private var dismiss

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.selectedImage = image
            }
            parent.dismiss()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = sourceType
        picker.mediaTypes = ["public.image"]
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
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
