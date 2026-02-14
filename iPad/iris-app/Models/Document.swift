import Foundation
import PencilKit

struct Document: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var model: String
    var lastOpened: Date
    var preview: String
    var backendSessionID: String?
    var codexConversationID: String?
    var codexCWD: String?
    var claudeCodeConversationID: String?
    var claudeCodeCWD: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case model
        case agent
        case lastOpened
        case preview
        case backendSessionID
        case codexConversationID
        case codexCWD
        case claudeCodeConversationID
        case claudeCodeCWD
    }

    init(
        id: UUID = UUID(),
        name: String,
        model: String = "gpt-5.2",
        lastOpened: Date = Date(),
        preview: String = "",
        backendSessionID: String? = nil,
        codexConversationID: String? = nil,
        codexCWD: String? = nil,
        claudeCodeConversationID: String? = nil,
        claudeCodeCWD: String? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.lastOpened = lastOpened
        self.preview = preview
        self.backendSessionID = backendSessionID
        self.codexConversationID = codexConversationID
        self.codexCWD = codexCWD
        self.claudeCodeConversationID = claudeCodeConversationID
        self.claudeCodeCWD = claudeCodeCWD
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? (try container.decodeIfPresent(String.self, forKey: .agent))
            ?? "gpt-5.2"
        lastOpened = try container.decode(Date.self, forKey: .lastOpened)
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        backendSessionID = try container.decodeIfPresent(String.self, forKey: .backendSessionID)
        codexConversationID = try container.decodeIfPresent(String.self, forKey: .codexConversationID)
        codexCWD = try container.decodeIfPresent(String.self, forKey: .codexCWD)
        claudeCodeConversationID = try container.decodeIfPresent(String.self, forKey: .claudeCodeConversationID)
        claudeCodeCWD = try container.decodeIfPresent(String.self, forKey: .claudeCodeCWD)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(model, forKey: .model)
        // Keep legacy key populated for older readers.
        try container.encode(model, forKey: .agent)
        try container.encode(lastOpened, forKey: .lastOpened)
        try container.encode(preview, forKey: .preview)
        try container.encodeIfPresent(backendSessionID, forKey: .backendSessionID)
        try container.encodeIfPresent(codexConversationID, forKey: .codexConversationID)
        try container.encodeIfPresent(codexCWD, forKey: .codexCWD)
        try container.encodeIfPresent(claudeCodeConversationID, forKey: .claudeCodeConversationID)
        try container.encodeIfPresent(claudeCodeCWD, forKey: .claudeCodeCWD)
    }

    /// Human-readable model display name
    var modelDisplayName: String {
        let lowered = model.lowercased()
        if lowered == "gpt-5.2" { return "GPT-5.2" }
        if lowered == "claude_code" { return "Claude Code" }
        if lowered.hasPrefix("claude") { return "Claude" }
        if lowered.hasPrefix("gemini") { return "Gemini" }
        if lowered == "codex" { return "Codex" }
        return model
    }

    var usesScreenshotWorkflow: Bool {
        model.lowercased().hasPrefix("claude")
    }

    var resolvedModel: String {
        let lowered = model.lowercased()
        if lowered == "iris" || lowered == "claude_code" || lowered == "claude" {
            return "claude-sonnet-4-5-20250929"
        }
        if lowered == "gemini" || lowered == "gemini-flash" {
            return "gemini-2.0-flash"
        }
        if lowered == "codex" {
            return "gpt-5.2"
        }
        return model
    }

    var resolvedSessionID: String {
        let candidate = (backendSessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            return id.uuidString
        }
        return candidate
    }

    // MARK: - Drawing Persistence

    private var drawingFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("\(id.uuidString).drawing")
    }

    func saveDrawing(_ drawing: PKDrawing) {
        let data = drawing.dataRepresentation()
        try? data.write(to: drawingFileURL)
    }

    func loadDrawing() -> PKDrawing {
        guard let data = try? Data(contentsOf: drawingFileURL),
              let drawing = try? PKDrawing(data: data) else {
            return PKDrawing()
        }
        return drawing
    }

    func deleteDrawingFile() {
        try? FileManager.default.removeItem(at: drawingFileURL)
    }
}

class DocumentStore: ObservableObject {
    @Published var documents: [Document] = []

    private let saveKey = "SavedDocuments_v3"
    private let session = URLSession(configuration: .default)

    init() {
        loadDocuments()
        if documents.isEmpty {
            documents.append(Document(name: "Untitled"))
        }
    }

    @discardableResult
    func addDocument(name: String, model: String = "gpt-5.2") -> Document {
        let doc = Document(name: name.isEmpty ? "Untitled" : name, model: model)
        documents.insert(doc, at: 0)
        saveDocuments()
        return doc
    }

    func deleteDocument(_ document: Document) {
        document.deleteDrawingFile()
        documents.removeAll { $0.id == document.id }
        saveDocuments()
    }

    func updateLastOpened(_ document: Document) {
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index].lastOpened = Date()
            saveDocuments()
        }
    }

    /// Fetch sessions from the agent server and mirror them locally (upsert + prune).
    func syncSessions(agentServerURL: URL) {
        let url = agentServerURL.appendingPathComponent("sessions")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        Task {
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                return
            }

            var seenIDs = Set<UUID>()
            let remoteDocs: [Document] = items.compactMap { item in
                guard let idStr = item["id"] as? String else { return nil }
                let docID = UUID(uuidString: idStr) ?? UUID(uuidString: stableUUID(from: idStr)) ?? UUID()
                guard seenIDs.insert(docID).inserted else { return nil }

                let rawName = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = rawName.isEmpty ? "Untitled" : rawName
                let model = (item["model"] as? String) ?? (item["agent"] as? String) ?? "gpt-5.2"
                let preview = (item["last_message_preview"] as? String) ?? ""
                let metadata = item["metadata"] as? [String: Any] ?? [:]
                let codexConversationID = (metadata["codex_conversation_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let codexCWD = (metadata["codex_cwd"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let claudeCodeConversationID = (metadata["claude_code_conversation_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let claudeCodeCWD = (metadata["claude_code_cwd"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return Document(
                    id: docID,
                    name: name,
                    model: model,
                    lastOpened: Date.distantPast,
                    preview: preview,
                    backendSessionID: idStr,
                    codexConversationID: codexConversationID?.isEmpty == false ? codexConversationID : nil,
                    codexCWD: codexCWD?.isEmpty == false ? codexCWD : nil,
                    claudeCodeConversationID: claudeCodeConversationID?.isEmpty == false ? claudeCodeConversationID : nil,
                    claudeCodeCWD: claudeCodeCWD?.isEmpty == false ? claudeCodeCWD : nil
                )
            }

            await MainActor.run {
                let oldDocuments = documents
                let existingByID = Dictionary(uniqueKeysWithValues: oldDocuments.map { ($0.id, $0) })
                let remoteIDs = Set(remoteDocs.map(\.id))

                let merged: [Document] = remoteDocs.map { remote in
                    guard let existing = existingByID[remote.id] else { return remote }
                    return Document(
                        id: remote.id,
                        name: remote.name,
                        model: remote.model,
                        lastOpened: existing.lastOpened,
                        preview: remote.preview,
                        backendSessionID: remote.backendSessionID ?? existing.backendSessionID,
                        codexConversationID: remote.codexConversationID ?? existing.codexConversationID,
                        codexCWD: remote.codexCWD ?? existing.codexCWD,
                        claudeCodeConversationID: remote.claudeCodeConversationID ?? existing.claudeCodeConversationID,
                        claudeCodeCWD: remote.claudeCodeCWD ?? existing.claudeCodeCWD
                    )
                }

                guard merged != oldDocuments else { return }

                let removed = oldDocuments.filter { !remoteIDs.contains($0.id) }
                for doc in removed {
                    doc.deleteDrawingFile()
                }

                documents = merged
                saveDocuments()
            }
        }
    }

    private func saveDocuments() {
        if let data = try? JSONEncoder().encode(documents) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func loadDocuments() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([Document].self, from: data) {
            documents = decoded
        } else if let oldData = UserDefaults.standard.data(forKey: "SavedDocuments_v2"),
                  let decoded = try? JSONDecoder().decode([Document].self, from: oldData) {
            // Migrate from v2/v3 — model decodes from either "model" or legacy "agent"
            documents = decoded
            saveDocuments()
        }
    }
}

/// Derive a deterministic UUID v5-style string from an arbitrary session ID string.
private func stableUUID(from string: String) -> String {
    // Simple hash-based approach: use the string's UTF-8 bytes to fill UUID fields
    var bytes = [UInt8](repeating: 0, count: 16)
    let utf8 = Array(string.utf8)
    for (i, byte) in utf8.enumerated() {
        bytes[i % 16] ^= byte
    }
    // Set version 4 and variant bits for a valid UUID
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let idx = hex.index(hex.startIndex, offsetBy: 8)
    let idx2 = hex.index(idx, offsetBy: 4)
    let idx3 = hex.index(idx2, offsetBy: 4)
    let idx4 = hex.index(idx3, offsetBy: 4)
    return "\(hex[hex.startIndex..<idx])-\(hex[idx..<idx2])-\(hex[idx2..<idx3])-\(hex[idx3..<idx4])-\(hex[idx4...])"
}
