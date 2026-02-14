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
