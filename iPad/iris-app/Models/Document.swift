import Foundation
import PencilKit

struct Document: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var model: String
    var lastOpened: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case model
        case agent
        case lastOpened
    }

    init(id: UUID = UUID(), name: String, model: String = "gpt-5.2", lastOpened: Date = Date()) {
        self.id = id
        self.name = name
        self.model = model
        self.lastOpened = lastOpened
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? (try container.decodeIfPresent(String.self, forKey: .agent))
            ?? "gpt-5.2"
        lastOpened = try container.decode(Date.self, forKey: .lastOpened)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(model, forKey: .model)
        // Keep legacy key populated for older readers.
        try container.encode(model, forKey: .agent)
        try container.encode(lastOpened, forKey: .lastOpened)
    }

    /// Human-readable model display name
    var modelDisplayName: String {
        let lowered = model.lowercased()
        if lowered == "gpt-5.2" { return "GPT-5.2" }
        if lowered.hasPrefix("claude") { return "Claude" }
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
        if lowered == "codex" {
            return "gpt-5.2"
        }
        return model
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

    /// Fetch sessions from the agent server and merge remote-only sessions into the local list.
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

            let localIDs = Set(documents.map { $0.id.uuidString.lowercased() })
            let remoteDocs: [Document] = items.compactMap { item in
                guard let idStr = item["id"] as? String else { return nil }
                if localIDs.contains(idStr.lowercased()) { return nil }

                let docID: UUID
                if let parsed = UUID(uuidString: idStr) {
                    docID = parsed
                } else {
                    docID = UUID(uuidString: stableUUID(from: idStr)) ?? UUID()
                }

                if localIDs.contains(docID.uuidString.lowercased()) { return nil }

                let name = (item["name"] as? String) ?? "Remote Chat"
                let model = (item["model"] as? String) ?? (item["agent"] as? String) ?? "gpt-5.2"
                return Document(id: docID, name: name, model: model, lastOpened: Date.distantPast)
            }

            guard !remoteDocs.isEmpty else { return }

            await MainActor.run {
                let existingIDs = Set(documents.map { $0.id })
                let toAdd = remoteDocs.filter { !existingIDs.contains($0.id) }
                if !toAdd.isEmpty {
                    documents.append(contentsOf: toAdd)
                    saveDocuments()
                }
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
