import Foundation

/// Sends user messages to the agents server running on the linked Mac.
enum AgentClient {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 130
        return URLSession(configuration: config)
    }()

    /// Send a message to an agent and return the response text.
    static func sendMessage(
        _ message: String,
        agent: String,
        chatID: String,
        serverURL: URL
    ) async throws -> String {
        let url = serverURL.appendingPathComponent("chat")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "agent": agent,
            "chat_id": chatID,
            "message": message
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw AgentClientError.invalidResponse
        }

        return text
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
