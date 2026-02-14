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
    let sessionID: String
    let name: String
    let model: String
    let updatedAt: String
    let preview: String
    let conversationID: String?
    let cwd: String?
}

private struct AgentPickerOverlay: View {
    let documentStore: DocumentStore
    @Binding var isPresented: Bool
    let onCreated: (Document) -> Void

    @State private var showSessionPicker = false
    @State private var sessionPickerModelID: String = ""
    @State private var remoteSessions: [RemoteSession] = []
    @State private var loadingSessions = false
    @State private var creatingLinkedSession = false
    @State private var sessionPickerError: String?

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
                List {
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
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220, maxHeight: 340)
            }

            if creatingLinkedSession {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Starting new \(sessionPickerModelID == "claude_code" ? "Claude Code" : "Codex") session...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                }
            }

            if let sessionPickerError, !sessionPickerError.isEmpty {
                Text(sessionPickerError)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(red: 1.0, green: 0.62, blue: 0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                Button("Back") {
                    showSessionPicker = false
                    remoteSessions = []
                    sessionPickerError = nil
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .disabled(creatingLinkedSession)

                Spacer()

                Button(creatingLinkedSession ? "Starting..." : "New Session") {
                    startNewLinkedSession()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(creatingLinkedSession ? 0.4 : 0.9))
                .disabled(creatingLinkedSession || loadingSessions)
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
        sessionPickerError = nil
        creatingLinkedSession = false
        showSessionPicker = true

        Task {
            let fetched = await Self.fetchLinkedSessions(modelID: modelID, serverURL: serverURL)
            await MainActor.run {
                remoteSessions = fetched
                loadingSessions = false
            }
        }
    }

    private func startNewLinkedSession() {
        guard sessionPickerModelID == "codex" || sessionPickerModelID == "claude_code" else { return }
        guard let urlStr = UserDefaults.standard.string(forKey: "iris_agent_server_url"),
              let serverURL = URL(string: urlStr) else {
            sessionPickerError = "No linked server URL found."
            return
        }

        creatingLinkedSession = true
        sessionPickerError = nil

        Task {
            let created = await Self.startLinkedSession(modelID: sessionPickerModelID, serverURL: serverURL)
            await MainActor.run {
                creatingLinkedSession = false
                guard let created else {
                    sessionPickerError = "Could not start a new session. Check backend/CLI auth and try again."
                    return
                }
                selectRemoteSession(created)
            }
        }
    }

    private static func startLinkedSession(modelID: String, serverURL: URL) async -> RemoteSession? {
        let endpoint = serverURL.appendingPathComponent("linked-sessions").appendingPathComponent("start")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "provider": modelID,
            "name": ""
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let sessionID = ((item["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        let conversationIDKey = modelID == "claude_code" ? "claude_code_conversation_id" : "codex_conversation_id"
        let cwdKey = modelID == "claude_code" ? "claude_code_cwd" : "codex_cwd"
        let conversationID = ((item["conversation_id"] as? String) ?? (metadata[conversationIDKey] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = ((item["cwd"] as? String) ?? (metadata[cwdKey] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let titleRaw = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleRaw.isEmpty ? (modelID == "claude_code" ? "Claude Code Session" : "Codex Session") : titleRaw
        let updatedAt = ((item["updated_at"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = ((item["last_message_preview"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return RemoteSession(
            id: "\(sessionID)::\(conversationID)",
            sessionID: sessionID,
            name: title,
            model: modelID,
            updatedAt: updatedAt,
            preview: preview,
            conversationID: conversationID.isEmpty ? nil : conversationID,
            cwd: cwd.isEmpty ? nil : cwd
        )
    }

    private static func fetchLinkedSessions(modelID: String, serverURL: URL) async -> [RemoteSession] {
        if modelID == "codex" {
            let discovered = await fetchCodexSessions(serverURL: serverURL)
            if !discovered.isEmpty {
                return discovered
            }
        }

        return await fetchSessionBackedLinkedSessions(modelID: modelID, serverURL: serverURL)
    }

    private static func fetchCodexSessions(serverURL: URL) async -> [RemoteSession] {
        let endpoint = serverURL.appendingPathComponent("codex").appendingPathComponent("sessions")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            let conversationID = (item["conversation_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedConversationID = (conversationID?.isEmpty == false) ? conversationID! : (
                ((item["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !resolvedConversationID.isEmpty else { return nil }

            let candidateSessionID = ((item["session_id"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionID = candidateSessionID.isEmpty ? resolvedConversationID : candidateSessionID
            let titleRaw = ((item["title"] as? String) ?? (item["name"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = titleRaw.isEmpty ? "Codex Session" : titleRaw
            let updatedAt = ((item["updated_at"] as? String) ?? (item["timestamp"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = ((item["last_message_preview"] as? String) ?? (item["preview"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = (item["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            return RemoteSession(
                id: "\(sessionID)::\(resolvedConversationID)",
                sessionID: sessionID,
                name: title,
                model: "codex",
                updatedAt: updatedAt,
                preview: preview,
                conversationID: resolvedConversationID,
                cwd: cwd?.isEmpty == false ? cwd : nil
            )
        }
    }

    private static func fetchSessionBackedLinkedSessions(modelID: String, serverURL: URL) async -> [RemoteSession] {
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
            let conversationID = (metadata[metadataKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cwdKey = isClaudeCode ? "claude_code_cwd" : "codex_cwd"
            let cwd = (metadata[cwdKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return RemoteSession(
                id: id,
                sessionID: id,
                name: name,
                model: model,
                updatedAt: updatedAt,
                preview: preview,
                conversationID: conversationID?.isEmpty == false ? conversationID : nil,
                cwd: cwd?.isEmpty == false ? cwd : nil
            )
        }
    }

    private func selectRemoteSession(_ session: RemoteSession) {
        // Keep local document IDs deterministic even when backend session IDs are not UUIDs.
        let docID = Self.stableDocumentID(from: session.sessionID)
        let isCodex = sessionPickerModelID == "codex"
        let isClaudeCode = sessionPickerModelID == "claude_code"

        let linkedDoc = Document(
            id: docID,
            name: session.name,
            model: sessionPickerModelID,
            lastOpened: Date(),
            preview: session.preview,
            backendSessionID: session.sessionID,
            codexConversationID: isCodex
                ? ((session.conversationID?.isEmpty == false) ? session.conversationID : session.sessionID)
                : nil,
            codexCWD: isCodex ? session.cwd : nil,
            claudeCodeConversationID: isClaudeCode
                ? ((session.conversationID?.isEmpty == false) ? session.conversationID : session.sessionID)
                : nil,
            claudeCodeCWD: isClaudeCode ? session.cwd : nil
        )

        if let index = documentStore.documents.firstIndex(where: { $0.id == docID }) {
            documentStore.documents[index] = linkedDoc
            documentStore.updateLastOpened(linkedDoc)
        } else {
            documentStore.documents.insert(linkedDoc, at: 0)
            documentStore.updateLastOpened(linkedDoc)
        }
        registerSessionOnBackend(linkedDoc)
        isPresented = false
        onCreated(linkedDoc)
    }

    private func registerSessionOnBackend(_ doc: Document) {
        guard let urlStr = UserDefaults.standard.string(forKey: "iris_agent_server_url"),
              let serverURL = URL(string: urlStr) else { return }
        let model = doc.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-5.2" : doc.model
        var metadata: [String: Any] = [:]
        if let codexConversationID = doc.codexConversationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexConversationID.isEmpty {
            metadata["codex_conversation_id"] = codexConversationID
        }
        if let codexCWD = doc.codexCWD?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexCWD.isEmpty {
            metadata["codex_cwd"] = codexCWD
        }
        if let claudeCodeConversationID = doc.claudeCodeConversationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !claudeCodeConversationID.isEmpty {
            metadata["claude_code_conversation_id"] = claudeCodeConversationID
        }
        if let claudeCodeCWD = doc.claudeCodeCWD?.trimmingCharacters(in: .whitespacesAndNewlines),
           !claudeCodeCWD.isEmpty {
            metadata["claude_code_cwd"] = claudeCodeCWD
        }
        Task {
            await AgentClient.registerSession(
                id: doc.resolvedSessionID,
                name: doc.name.isEmpty ? "Untitled" : doc.name,
                model: model,
                metadata: metadata,
                serverURL: serverURL
            )
        }
    }

    private static func stableDocumentID(from raw: String) -> UUID {
        if let existing = UUID(uuidString: raw) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in Array(raw.utf8).enumerated() {
            bytes[index % 16] ^= byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let p1 = String(hex.prefix(8))
        let p2 = String(hex.dropFirst(8).prefix(4))
        let p3 = String(hex.dropFirst(12).prefix(4))
        let p4 = String(hex.dropFirst(16).prefix(4))
        let p5 = String(hex.dropFirst(20).prefix(12))
        let uuidString = "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
        return UUID(uuidString: uuidString) ?? UUID()
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
