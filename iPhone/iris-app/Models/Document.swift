import Foundation
import PencilKit

struct Document: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var lastOpened: Date

    init(id: UUID = UUID(), name: String, lastOpened: Date = Date()) {
        self.id = id
        self.name = name
        self.lastOpened = lastOpened
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

    private let saveKey = "SavedDocuments_v2"

    init() {
        loadDocuments()
        if documents.isEmpty {
            documents.append(Document(name: "Untitled"))
        }
    }

    func addDocument(name: String) {
        let doc = Document(name: name.isEmpty ? "Untitled" : name)
        documents.insert(doc, at: 0)
        saveDocuments()
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
        }
    }
}
