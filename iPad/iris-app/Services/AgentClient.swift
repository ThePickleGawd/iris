import Foundation
import UIKit

/// A widget parsed from an agent response.
struct AgentWidget {
    let id: String
    let html: String
    let width: CGFloat
    let height: CGFloat
}

/// Full result from the agent — text reply plus any widgets.
struct AgentResponse {
    let text: String
    let widgets: [AgentWidget]
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
        serverURL: URL
    ) async throws -> AgentResponse {
        let url = serverURL
            .appendingPathComponent("v1")
            .appendingPathComponent("agent")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let requestID = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
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
            "metadata": [
                "model": model,
                "agent": model
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

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

    /// Register a session with the agents server so it appears on the Mac.
    /// Fire-and-forget — errors are silently ignored.
    static func registerSession(
        id: String,
        name: String,
        model: String,
        serverURL: URL
    ) async {
        let url = serverURL.appendingPathComponent("sessions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        let payload: [String: Any] = [
            "id": id,
            "name": name,
            "model": model,
            "agent": model
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        _ = try? await session.data(for: request)
    }

    /// Fetch pending widgets for a session (for cross-device delivery).
    static func fetchSessionWidgets(
        sessionID: String,
        serverURL: URL
    ) async -> [AgentWidget] {
        let url = serverURL.appendingPathComponent("sessions").appendingPathComponent(sessionID)
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

    private static func parseFullResponse(_ data: Data) -> AgentResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            return AgentResponse(text: raw, widgets: [])
        }

        // Extract text
        let text = (json["text"] as? String) ?? (json["response"] as? String) ?? ""

        // Extract widgets from events
        var widgets: [AgentWidget] = []
        if let events = json["events"] as? [[String: Any]] {
            for event in events {
                guard let kind = event["kind"] as? String, kind == "widget.open" else { continue }
                if let widgetDict = event["widget"] as? [String: Any],
                   let widget = parseWidgetFromEvent(widgetDict) {
                    widgets.append(widget)
                }
            }
        }

        return AgentResponse(text: text, widgets: widgets)
    }

    private static func parseWidgetFromEvent(_ dict: [String: Any]) -> AgentWidget? {
        let payload = dict["payload"] as? [String: Any]
        guard let html = payload?["html"] as? String ?? dict["html"] as? String,
              !html.isEmpty else { return nil }

        let id = (dict["id"] as? String) ?? (dict["widget_id"] as? String) ?? UUID().uuidString
        let width = CGFloat((dict["width"] as? NSNumber)?.doubleValue ?? 320)
        let height = CGFloat((dict["height"] as? NSNumber)?.doubleValue ?? 220)

        return AgentWidget(id: id, html: html, width: width, height: height)
    }

    private static func parseWidgetDict(_ dict: [String: Any]) -> AgentWidget? {
        guard let html = dict["html"] as? String, !html.isEmpty else { return nil }
        let id = (dict["id"] as? String) ?? UUID().uuidString
        let width = CGFloat((dict["width"] as? NSNumber)?.doubleValue ?? 320)
        let height = CGFloat((dict["height"] as? NSNumber)?.doubleValue ?? 220)
        return AgentWidget(id: id, html: html, width: width, height: height)
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
        notes: String? = nil
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
            notes: notes
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
        notes: String?
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
