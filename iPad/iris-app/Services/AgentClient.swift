import Foundation
import UIKit

/// Sends user messages to the agents server running on the linked Mac.
enum AgentClient {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 130
        return URLSession(configuration: config)
    }()

    /// Send a message to the agents server and return the response text.
    static func sendMessage(
        _ message: String,
        model: String,
        chatID: String,
        serverURL: URL
    ) async throws -> String {
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

        if let text = parseAgentResponse(data) {
            return text
        }

        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            throw AgentClientError.invalidResponse
        }
        return body
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

    private static func parseAgentResponse(_ data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["text"] as? String, !text.isEmpty {
                return text
            }
            if let text = json["response"] as? String, !text.isEmpty {
                return text
            }
            if let events = json["events"] as? [[String: Any]] {
                var final = ""
                for event in events {
                    if let kind = event["kind"] as? String, kind == "message.delta", let delta = event["delta"] as? String {
                        final += delta
                    } else if let kind = event["kind"] as? String, kind == "message.final", let text = event["text"] as? String {
                        final = text
                    }
                }
                if !final.isEmpty { return final }
            }
        }

        guard let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        var finalText = ""
        for rawLine in raw.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let payload: String
            if trimmed.hasPrefix("data:") {
                payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                payload = trimmed
            }
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let payloadData = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }

            if let kind = obj["kind"] as? String {
                if kind == "message.delta", let delta = obj["delta"] as? String {
                    finalText += delta
                    continue
                }
                if kind == "message.final", let text = obj["text"] as? String {
                    finalText = text
                    continue
                }
            }

            if let chunk = obj["chunk"] as? String {
                finalText += chunk
            } else if let text = obj["text"] as? String {
                finalText = text
            }
        }

        return finalText.isEmpty ? nil : finalText
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
