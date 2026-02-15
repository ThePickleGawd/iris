import Foundation
import UIKit

/// A widget parsed from an agent response.
struct AgentWidget {
    let id: String
    let html: String
    let width: CGFloat
    let height: CGFloat
    let x: CGFloat
    let y: CGFloat
    let coordinateSpace: String
    let anchor: String
}

/// Full result from the agent — text reply plus any widgets.
struct AgentResponse {
    let text: String
    let widgets: [AgentWidget]
    var sessionName: String? = nil
}

struct ProactiveDescriptionResult {
    let model: String
    let description: [String: Any]
    let descriptionJSON: String
}

/// Sends user messages to the agents server running on the linked Mac.
enum AgentClient {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 130
        return URLSession(configuration: config)
    }()

    /// Send a message to the agents server and return the full response (text + widgets).
    static func sendMessage(
        _ message: String,
        model: String,
        chatID: String,
        ephemeral: Bool = false,
        coordinateSnapshot: [String: Any]? = nil,
        codexConversationID: String? = nil,
        codexCWD: String? = nil,
        claudeCodeConversationID: String? = nil,
        claudeCodeCWD: String? = nil,
        serverURL: URL
    ) async throws -> AgentResponse {
        let request = try makeAgentRequest(
            message: message,
            model: model,
            chatID: chatID,
            ephemeral: ephemeral,
            coordinateSnapshot: coordinateSnapshot,
            codexConversationID: codexConversationID,
            codexCWD: codexCWD,
            claudeCodeConversationID: claudeCodeConversationID,
            claudeCodeCWD: claudeCodeCWD,
            serverURL: serverURL,
            stream: false
        )

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AgentClientError.serverError(statusCode: http.statusCode, body: body)
        }

        return parseFullResponse(data)
    }

    /// Send a message and stream response deltas over SSE/chunked transfer.
    static func sendMessageStreaming(
        _ message: String,
        model: String,
        chatID: String,
        ephemeral: Bool = false,
        coordinateSnapshot: [String: Any]? = nil,
        codexConversationID: String? = nil,
        codexCWD: String? = nil,
        claudeCodeConversationID: String? = nil,
        claudeCodeCWD: String? = nil,
        serverURL: URL,
        onDelta: ((String) async -> Void)? = nil
    ) async throws -> AgentResponse {
        let request = try makeAgentRequest(
            message: message,
            model: model,
            chatID: chatID,
            ephemeral: ephemeral,
            coordinateSnapshot: coordinateSnapshot,
            codexConversationID: codexConversationID,
            codexCWD: codexCWD,
            claudeCodeConversationID: claudeCodeConversationID,
            claudeCodeCWD: claudeCodeCWD,
            serverURL: serverURL,
            stream: true
        )

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }

        if !(200...299).contains(http.statusCode) {
            var body = ""
            var seen = 0
            for try await line in bytes.lines {
                body += line + "\n"
                seen += 1
                if seen >= 20 { break }
            }
            throw AgentClientError.serverError(
                statusCode: http.statusCode,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        var eventName = ""
        var dataLines: [String] = []
        var finalResponse: AgentResponse?
        var fallbackText = ""

        for try await rawLine in bytes.lines {
            let line = String(rawLine)
            if line.hasPrefix("event:") {
                eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("data:") {
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                dataLines.append(payload)
                continue
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if dataLines.isEmpty {
                    eventName = ""
                    continue
                }
                let payload = dataLines.joined(separator: "\n")
                dataLines.removeAll(keepingCapacity: true)

                switch eventName {
                case "delta":
                    if let data = payload.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let chunk = obj["text"] as? String,
                       !chunk.isEmpty {
                        fallbackText += chunk
                        if let onDelta {
                            await onDelta(chunk)
                        }
                    }
                case "final":
                    if let data = payload.data(using: .utf8) {
                        finalResponse = parseFullResponse(data)
                    }
                case "error":
                    throw AgentClientError.serverError(statusCode: 502, body: payload)
                default:
                    break
                }

                eventName = ""
            }
        }

        if let finalResponse {
            return finalResponse
        }
        return AgentResponse(text: fallbackText, widgets: [], sessionName: nil)
    }

    /// Register a session with the agents server so it appears on the Mac.
    /// Fire-and-forget — errors are silently ignored.
    static func registerSession(
        id: String,
        name: String,
        model: String,
        metadata: [String: Any]? = nil,
        serverURL: URL
    ) async {
        let url = serverURL.appendingPathComponent("sessions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        var payload: [String: Any] = [
            "id": id,
            "name": name,
            "model": model,
            "agent": model
        ]
        if let metadata, !metadata.isEmpty {
            payload["metadata"] = metadata
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        _ = try? await session.data(for: request)
    }

    /// Delete a widget from the backend session so it doesn't reappear on sync.
    static func deleteSessionWidget(
        sessionID: String,
        widgetID: String,
        serverURL: URL
    ) async {
        let url = serverURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("widgets")
            .appendingPathComponent(widgetID)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
    }

    /// Fetch pending widgets for a session (for cross-device delivery).
    static func fetchSessionWidgets(
        sessionID: String,
        serverURL: URL
    ) async -> [AgentWidget] {
        var components = URLComponents(
            url: serverURL.appendingPathComponent("sessions").appendingPathComponent(sessionID),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "target", value: "ipad")]
        let url = components.url!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let widgets = json["widgets"] as? [[String: Any]] else {
            return []
        }

        return widgets.compactMap { parseWidgetDict($0) }
    }

    // MARK: - Parsing

    private static func makeAgentRequest(
        message: String,
        model: String,
        chatID: String,
        ephemeral: Bool,
        coordinateSnapshot: [String: Any]?,
        codexConversationID: String?,
        codexCWD: String?,
        claudeCodeConversationID: String?,
        claudeCodeCWD: String?,
        serverURL: URL,
        stream: Bool
    ) throws -> URLRequest {
        var endpoint = serverURL
            .appendingPathComponent("v1")
            .appendingPathComponent("agent")
        if stream, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "stream", value: "1"))
            components.queryItems = items
            if let streamURL = components.url {
                endpoint = streamURL
            }
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")

        let requestID = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        var metadata: [String: Any] = [
            "model": model,
            "agent": model,
            "ephemeral": ephemeral,
            "coordinate_snapshot": coordinateSnapshot ?? [:]
        ]
        if let codexConversationID {
            let value = codexConversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                metadata["codex_conversation_id"] = value
            }
        }
        if let codexCWD {
            let value = codexCWD.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                metadata["codex_cwd"] = value
            }
        }
        if let claudeCodeConversationID {
            let value = claudeCodeConversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                metadata["claude_code_conversation_id"] = value
            }
        }
        if let claudeCodeCWD {
            let value = claudeCodeCWD.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                metadata["claude_code_cwd"] = value
            }
        }

        let payload: [String: Any] = [
            "protocol_version": "1.0",
            "kind": "agent.request",
            "request_id": requestID,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "workspace_id": chatID,
            "session_id": chatID,
            "device": [
                "id": getOrCreateDeviceID(),
                "name": UIDevice.current.name,
                "platform": "iPadOS",
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
            ],
            "input": [
                "type": "text",
                "text": message
            ],
            "context": [
                "recent_messages": []
            ],
            "model": model,
            "metadata": metadata,
            "stream": stream
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func parseFullResponse(_ data: Data) -> AgentResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            return AgentResponse(text: raw, widgets: [], sessionName: nil)
        }

        // Extract text
        let text = (json["text"] as? String) ?? (json["response"] as? String) ?? ""

        // Extract session name (auto-generated on first prompt)
        let sessionName: String? = {
            guard let name = json["session_name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name != "Untitled" else { return nil }
            return name
        }()

        // Extract widgets from events
        var widgets: [AgentWidget] = []
        if let events = json["events"] as? [[String: Any]] {
            for event in events {
                guard let kind = event["kind"] as? String, kind == "widget.open" else { continue }
                if let widgetDict = event["widget"] as? [String: Any] {
                    let target = (widgetDict["target"] as? String ?? "mac").lowercased()
                    guard target == "ipad" else { continue }
                    if let widget = parseWidgetFromEvent(widgetDict) {
                        widgets.append(widget)
                    }
                }
            }
        }

        return AgentResponse(text: text, widgets: widgets, sessionName: sessionName)
    }

    private static func parseWidgetFromEvent(_ dict: [String: Any]) -> AgentWidget? {
        let payload = dict["payload"] as? [String: Any]
        guard let html = payload?["html"] as? String ?? dict["html"] as? String,
              !html.isEmpty else { return nil }

        let id = (dict["id"] as? String) ?? (dict["widget_id"] as? String) ?? UUID().uuidString
        let width = CGFloat((dict["width"] as? NSNumber)?.doubleValue ?? 320)
        let height = CGFloat((dict["height"] as? NSNumber)?.doubleValue ?? 220)
        let x = CGFloat((dict["x"] as? NSNumber)?.doubleValue ?? 0)
        let y = CGFloat((dict["y"] as? NSNumber)?.doubleValue ?? 0)
        let coordinateSpace = (dict["coordinate_space"] as? String) ?? "viewport_offset"
        let anchor = (dict["anchor"] as? String) ?? "top_left"

        return AgentWidget(
            id: id,
            html: html,
            width: width,
            height: height,
            x: x,
            y: y,
            coordinateSpace: coordinateSpace,
            anchor: anchor
        )
    }

    private static func parseWidgetDict(_ dict: [String: Any]) -> AgentWidget? {
        guard let html = dict["html"] as? String, !html.isEmpty else { return nil }
        let id = (dict["id"] as? String) ?? UUID().uuidString
        let width = CGFloat((dict["width"] as? NSNumber)?.doubleValue ?? 320)
        let height = CGFloat((dict["height"] as? NSNumber)?.doubleValue ?? 220)
        let x = CGFloat((dict["x"] as? NSNumber)?.doubleValue ?? 0)
        let y = CGFloat((dict["y"] as? NSNumber)?.doubleValue ?? 0)
        let coordinateSpace = (dict["coordinate_space"] as? String) ?? "viewport_offset"
        let anchor = (dict["anchor"] as? String) ?? "top_left"
        return AgentWidget(
            id: id,
            html: html,
            width: width,
            height: height,
            x: x,
            y: y,
            coordinateSpace: coordinateSpace,
            anchor: anchor
        )
    }

    private static func getOrCreateDeviceID() -> String {
        let key = "iris_device_id"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

enum AgentClientError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from agent server"
        case .serverError(let code, let body):
            return "Agent server error \(code): \(body)"
        }
    }
}

/// Uploads iPad canvas screenshots to the Iris backend.
enum BackendClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    static func uploadScreenshot(
        pngData: Data,
        deviceID: String,
        backendURL: URL,
        sessionID: String? = nil,
        notes: String? = nil,
        coordinateSnapshot: [String: Any]? = nil
    ) async throws -> String {
        let endpoint = backendURL.appendingPathComponent("api/screenshots")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = makeMultipartBody(
            pngData: pngData,
            boundary: boundary,
            deviceID: deviceID,
            sessionID: sessionID,
            notes: notes,
            coordinateSnapshot: coordinateSnapshot
        )
        request.httpBody = body
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw BackendClientError.serverError(statusCode: http.statusCode, body: text)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let screenshotID = json["id"] as? String
        else {
            throw BackendClientError.invalidResponse
        }

        return screenshotID
    }

    private static func makeMultipartBody(
        pngData: Data,
        boundary: String,
        deviceID: String,
        sessionID: String?,
        notes: String?,
        coordinateSnapshot: [String: Any]?
    ) -> Data {
        var body = Data()

        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"device_id\"\r\n\r\n")
        append("\(deviceID)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"source\"\r\n\r\n")
        append("ipad-canvas\r\n")

        if let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"session_id\"\r\n\r\n")
            append("\(sessionID)\r\n")
        }

        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"notes\"\r\n\r\n")
            append("\(notes)\r\n")
        }
        if let coordinateSnapshot,
           let snapshotData = try? JSONSerialization.data(withJSONObject: coordinateSnapshot),
           let snapshotJSON = String(data: snapshotData, encoding: .utf8),
           !snapshotJSON.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"coordinate_snapshot\"\r\n\r\n")
            append("\(snapshotJSON)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"screenshot\"; filename=\"canvas.png\"\r\n")
        append("Content-Type: image/png\r\n\r\n")
        body.append(pngData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        return body
    }

    static func ingestTranscript(
        text: String,
        sessionID: String,
        deviceID: String,
        backendURL: URL,
        source: String = "speech"
    ) async throws {
        let endpoint = backendURL.appendingPathComponent("api/transcripts")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "session_id": sessionID,
            "text": text,
            "device_id": deviceID,
            "source": source,
            "captured_at": ISO8601DateFormatter().string(from: Date())
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BackendClientError.serverError(statusCode: http.statusCode, body: body)
        }
    }

    static func describeProactiveScreenshot(
        screenshotID: String,
        coordinateSnapshot: [String: Any],
        backendURL: URL,
        previousDescription: [String: Any]? = nil
    ) async throws -> ProactiveDescriptionResult {
        let endpoint = backendURL
            .appendingPathComponent("api")
            .appendingPathComponent("proactive")
            .appendingPathComponent("describe")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "screenshot_id": screenshotID,
            "coordinate_snapshot": coordinateSnapshot
        ]
        if let previousDescription {
            payload["previous_description"] = previousDescription
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BackendClientError.serverError(statusCode: http.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendClientError.invalidResponse
        }
        guard let description = json["description"] as? [String: Any] else {
            throw BackendClientError.invalidResponse
        }
        let model = (json["model"] as? String) ?? "gemini-2.0-flash"
        let descriptionData = try JSONSerialization.data(withJSONObject: description, options: [.sortedKeys])
        let descriptionJSON = String(data: descriptionData, encoding: .utf8) ?? "{}"
        return ProactiveDescriptionResult(
            model: model,
            description: description,
            descriptionJSON: descriptionJSON
        )
    }

    static func deleteScreenshot(
        screenshotID: String,
        backendURL: URL
    ) async throws {
        let endpoint = backendURL
            .appendingPathComponent("api")
            .appendingPathComponent("screenshots")
            .appendingPathComponent(screenshotID)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BackendClientError.serverError(statusCode: http.statusCode, body: body)
        }
    }
}

enum BackendClientError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from backend"
        case .serverError(let statusCode, let body):
            return "Backend error \(statusCode): \(body)"
        }
    }
}
