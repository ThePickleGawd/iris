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
