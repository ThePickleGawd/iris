import Foundation
import PencilKit

struct Document: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var agent: String
    var lastOpened: Date

    init(id: UUID = UUID(), name: String, agent: String = "iris", lastOpened: Date = Date()) {
        self.id = id
        self.name = name
        self.agent = agent
        self.lastOpened = lastOpened
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? "iris"
        lastOpened = try container.decode(Date.self, forKey: .lastOpened)
    }

    /// Human-readable agent display name
    var agentDisplayName: String {
        switch agent {
        case "codex": return "Codex"
        case "claude_code": return "Claude Code"
        default: return "Iris"
        }
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
    func addDocument(name: String, agent: String = "iris") -> Document {
        let doc = Document(name: name.isEmpty ? "Untitled" : name, agent: agent)
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
                let agent = (item["agent"] as? String) ?? "iris"
                return Document(id: docID, name: name, agent: agent, lastOpened: Date.distantPast)
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
            // Migrate from v2 — agent defaults to "iris" via Codable
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
