import SwiftUI

struct HomeView: View {
    @StateObject private var documentStore = DocumentStore()
    @State private var selectedDocument: Document?
    @State private var showingAddDocument = false

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 18)]

    @State private var syncTimer: Timer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Text("Iris Notes")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Button {
                            showingAddDocument = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(documentStore.documents) { doc in
                                DocumentCard(document: doc)
                                    .onTapGesture {
                                        documentStore.updateLastOpened(doc)
                                        selectedDocument = doc
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            documentStore.deleteDocument(doc)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                    }
                    .refreshable {
                        syncSessionsNow()
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
            .navigationDestination(item: $selectedDocument) { doc in
                CanvasScreen(document: doc)
            }
            .overlay {
                if showingAddDocument {
                    AgentPickerOverlay(
                        documentStore: documentStore,
                        isPresented: $showingAddDocument
                    ) { doc in
                        selectedDocument = doc
                    }
                }
            }
            .onAppear { startSessionSync() }
            .onDisappear { syncTimer?.invalidate() }
        }
        .preferredColorScheme(.dark)
    }

    private func startSessionSync() {
        syncSessionsNow()
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            syncSessionsNow()
        }
    }

    private func syncSessionsNow() {
        guard let urlStr = UserDefaults.standard.string(forKey: "iris_agent_server_url"),
              let url = URL(string: urlStr) else { return }
        documentStore.syncSessions(agentServerURL: url)
    }
}

struct DocumentCard: View {
    let document: Document

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .overlay(
                    Group {
                        if document.preview.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(0..<5, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.gray.opacity(0.18))
                                        .frame(height: 2)
                                }
                            }
                            .padding(20)
                        } else {
                            Text(document.preview)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(.black.opacity(0.55))
                                .lineLimit(7)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(14)
                        }
                    }
                )
                .frame(height: 160)

            Text(document.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(document.modelDisplayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.16))
        )
    }
}

private struct ModelChoice: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let isSessionLinked: Bool
}

private let choices: [ModelChoice] = [
    ModelChoice(id: "gpt-5.2", name: "GPT-5.2", subtitle: "OpenAI general-purpose model", isSessionLinked: false),
    ModelChoice(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", subtitle: "Fast multimodal model for lightweight tasks", isSessionLinked: false),
    ModelChoice(id: "claude_code", name: "Claude Code", subtitle: "Link to a Claude Code conversation", isSessionLinked: true),
    ModelChoice(id: "codex", name: "Codex", subtitle: "Link to a Codex conversation", isSessionLinked: true),
]

/// A remote session discovered from the backend for Claude Code / Codex linking.
private struct RemoteSession: Identifiable {
    let id: String
    let name: String
    let model: String
    let updatedAt: String
    let preview: String
}

private struct AgentPickerOverlay: View {
    let documentStore: DocumentStore
    @Binding var isPresented: Bool
    let onCreated: (Document) -> Void

    @State private var showSessionPicker = false
    @State private var sessionPickerModelID: String = ""
    @State private var remoteSessions: [RemoteSession] = []
    @State private var loadingSessions = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            if showSessionPicker {
                sessionPickerCard
            } else {
                modelPickerCard
            }
        }
    }

    // MARK: - Model Picker

    private var modelPickerCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            Text("New Note")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            Text("Choose a model to start. The note title will be Untitled.")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    Button {
                        if choice.isSessionLinked {
                            sessionPickerModelID = choice.id
                            fetchRemoteSessions(for: choice.id)
                        } else {
                            let doc = documentStore.addDocument(
                                name: "",
                                model: choice.id
                            )
                            isPresented = false
                            onCreated(doc)
                            registerSessionOnBackend(doc)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(modelAccent(for: index).opacity(0.18))
                                    .frame(width: 34, height: 34)
                                Image(systemName: modelSymbol(for: index))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(modelAccent(for: index))
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(choice.subtitle)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(.white.opacity(0.66))
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.32))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Cancel") {
                isPresented = false
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
        }
        .padding(22)
        .frame(maxWidth: 430)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 22, x: 0, y: 12)
        .padding(24)
    }

    // MARK: - Session Picker

    private var sessionPickerTitle: String {
        sessionPickerModelID == "claude_code" ? "Claude Code Sessions" : "Codex Sessions"
    }

    private var sessionPickerCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            Text(sessionPickerTitle)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            Text("Select a session to link to this note.")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            if loadingSessions {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(.white)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if remoteSessions.isEmpty {
                Text("No sessions found. Start a session on your Mac first.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(remoteSessions) { session in
                            Button {
                                selectRemoteSession(session)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        if !session.preview.isEmpty {
                                            Text(session.preview)
                                                .font(.system(size: 12))
                                                .foregroundColor(.white.opacity(0.5))
                                                .lineLimit(2)
                                        }
                                    }

                                    Spacer(minLength: 0)

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.32))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            HStack(spacing: 16) {
                Button("Back") {
                    showSessionPicker = false
                    remoteSessions = []
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            }
            .padding(.top, 2)
        }
        .padding(22)
        .frame(maxWidth: 430)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 22, x: 0, y: 12)
        .padding(24)
    }

    // MARK: - Networking

    private func fetchRemoteSessions(for modelID: String) {
        guard let urlStr = UserDefaults.standard.string(forKey: "iris_agent_server_url"),
              let serverURL = URL(string: urlStr) else {
            showSessionPicker = true
            return
        }

        loadingSessions = true
        showSessionPicker = true

        Task {
            let fetched = await Self.fetchLinkedSessions(modelID: modelID, serverURL: serverURL)
            await MainActor.run {
                remoteSessions = fetched
                loadingSessions = false
            }
        }
    }

    private static func fetchLinkedSessions(modelID: String, serverURL: URL) async -> [RemoteSession] {
        let url = serverURL.appendingPathComponent("sessions")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }

        let isClaudeCode = modelID == "claude_code"
        let metadataKey = isClaudeCode ? "claude_code_conversation_id" : "codex_conversation_id"

        return items.compactMap { item in
            let model = (item["model"] as? String ?? "").lowercased()
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            let hasConversationID = {
                if let val = metadata[metadataKey] as? String, !val.trimmingCharacters(in: .whitespaces).isEmpty {
                    return true
                }
                return false
            }()

            let matches: Bool
            if isClaudeCode {
                matches = model == "claude_code" || hasConversationID
            } else {
                matches = model == "codex" || hasConversationID
            }
            guard matches else { return nil }

            let id = item["id"] as? String ?? UUID().uuidString
            let rawName = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName.isEmpty ? "Untitled" : rawName
            let updatedAt = item["updated_at"] as? String ?? ""
            let preview = (item["last_message_preview"] as? String) ?? ""

            return RemoteSession(id: id, name: name, model: model, updatedAt: updatedAt, preview: preview)
        }
    }

    private func selectRemoteSession(_ session: RemoteSession) {
        // Find or create a local document pointing to this backend session
        let docID = UUID(uuidString: session.id) ?? UUID()
        if let existing = documentStore.documents.first(where: { $0.id == docID }) {
            documentStore.updateLastOpened(existing)
            isPresented = false
            onCreated(existing)
        } else {
            let doc = Document(
                id: docID,
                name: session.name,
                model: sessionPickerModelID,
                lastOpened: Date()
            )
            documentStore.documents.insert(doc, at: 0)
            isPresented = false
            onCreated(doc)
        }
    }

    private func registerSessionOnBackend(_ doc: Document) {
        guard let urlStr = UserDefaults.standard.string(forKey: "iris_agent_server_url"),
              let serverURL = URL(string: urlStr) else { return }
        Task {
            await AgentClient.registerSession(
                id: doc.id.uuidString,
                name: doc.name.isEmpty ? "Untitled" : doc.name,
                model: doc.resolvedModel,
                serverURL: serverURL
            )
        }
    }

    private func modelAccent(for index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.39, green: 0.62, blue: 1.0)    // GPT - blue
        case 1: return Color(red: 0.43, green: 0.86, blue: 0.74)    // Gemini - green
        case 2: return Color(red: 0.85, green: 0.55, blue: 0.35)    // Claude Code - orange
        case 3: return Color(red: 0.62, green: 0.64, blue: 1.0)     // Codex - purple
        default: return Color(red: 0.43, green: 0.86, blue: 0.74)
        }
    }

    private func modelSymbol(for index: Int) -> String {
        switch index {
        case 0: return "circle.grid.2x2.fill"         // GPT
        case 1: return "bolt.fill"                     // Gemini
        case 2: return "terminal.fill"                 // Claude Code
        case 3: return "square.stack.3d.down.forward.fill"  // Codex
        default: return "square.stack.3d.down.forward.fill"
        }
    }
}

struct CanvasScreen: View {
    let document: Document
    @StateObject private var canvasState = CanvasState()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ContentView(document: document, onBack: { dismiss() })
            .environmentObject(canvasState)
            .navigationBarBackButtonHidden(true)
    }
}
