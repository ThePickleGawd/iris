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
                CanvasScreen(document: doc, documentStore: documentStore)
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

/// A remote session discovered from the backend for Codex linking.
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

// MARK: - Agent Picker Overlay

private struct AgentPickerOverlay: View {
    let documentStore: DocumentStore
    @Binding var isPresented: Bool
    let onCreated: (Document) -> Void

    @State private var phase = Phase.choosing
    @State private var codexSessions: [RemoteSession] = []
    @State private var errorText: String?

    private enum Phase: Equatable {
        case choosing
        case checkingLive
        case loadingCodex
        case codexReady
        case creatingCodex
    }

    private var activeMode: String? {
        switch phase {
        case .choosing: return nil
        case .checkingLive: return "claude_code"
        case .loadingCodex, .codexReady, .creatingCodex: return "codex"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    guard phase == .choosing || phase == .codexReady else { return }
                    withAnimation(.easeOut(duration: 0.18)) { isPresented = false }
                }

            card
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: phase)
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Handle
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 22)

            // Title
            Text("New Note")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .padding(.bottom, 22)

            // Mode cards
            HStack(spacing: 10) {
                modeCard(
                    id: "general",
                    icon: "plus.message.fill",
                    title: "Chat",
                    subtitle: "New conversation",
                    accent: Color(red: 0.38, green: 0.6, blue: 1.0)
                )
                modeCard(
                    id: "claude_code",
                    icon: "terminal.fill",
                    title: "Claude Code",
                    subtitle: "Live session",
                    accent: Color(red: 0.92, green: 0.6, blue: 0.3)
                )
                modeCard(
                    id: "codex",
                    icon: "cube.fill",
                    title: "Codex",
                    subtitle: "Link session",
                    accent: Color(red: 0.6, green: 0.55, blue: 1.0)
                )
            }

            // Expandable detail area
            if phase != .choosing || errorText != nil {
                Divider()
                    .overlay(Color.white.opacity(0.06))
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                detailSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .frame(maxWidth: 480)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .padding(28)
    }

    // MARK: - Mode Card

    private func modeCard(
        id: String,
        icon: String,
        title: String,
        subtitle: String,
        accent: Color
    ) -> some View {
        let isActive = activeMode == id
        let dimmed = activeMode != nil && !isActive

        return Button {
            handleModeTap(id)
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(isActive ? 0.22 : 0.1))
                        .frame(width: 46, height: 46)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isActive ? accent.opacity(0.08) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isActive ? accent.opacity(0.5) : Color.white.opacity(0.06),
                        lineWidth: isActive ? 1.2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(dimmed && phase != .codexReady)
        .opacity(dimmed ? 0.35 : 1.0)
    }

    // MARK: - Detail Section

    @ViewBuilder
    private var detailSection: some View {
        VStack(spacing: 10) {
            switch phase {
            case .choosing:
                EmptyView()

            case .checkingLive:
                statusRow(text: "Connecting to live session...", showSpinner: true)

            case .loadingCodex:
                statusRow(text: "Loading sessions...", showSpinner: true)

            case .creatingCodex:
                statusRow(text: "Starting new session...", showSpinner: true)

            case .codexReady:
                codexSessionsList
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }

            if phase != .choosing {
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            phase = .choosing
                            errorText = nil
                            codexSessions = []
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                            Text("Back")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if phase == .codexReady {
                        Button("New Session") {
                            startNewCodexSession()
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.6, green: 0.55, blue: 1.0))
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func statusRow(text: String, showSpinner: Bool) -> some View {
        HStack(spacing: 10) {
            if showSpinner {
                ProgressView()
                    .tint(.white.opacity(0.6))
                    .scaleEffect(0.8)
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 14)
    }

    private var codexSessionsList: some View {
        VStack(spacing: 6) {
            if codexSessions.isEmpty {
                Text("No sessions found")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(codexSessions.prefix(6)) { session in
                            sessionRow(session)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private func sessionRow(_ session: RemoteSession) -> some View {
        Button {
            selectRemoteSession(session, modelID: "codex")
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    if !session.preview.isEmpty {
                        Text(session.preview)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.18))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func handleModeTap(_ id: String) {
        switch id {
        case "general":
            let doc = documentStore.addDocument(name: "", model: "gpt-5.2-mini")
            isPresented = false
            onCreated(doc)
            registerSessionOnBackend(doc)

        case "claude_code":
            checkClaudeCodeLiveSession()

        case "codex":
            fetchCodexSessionsList()

        default:
            break
        }
    }

    // MARK: - Claude Code

    private func checkClaudeCodeLiveSession() {
        guard let urlStr = UserDefaults.standard.string(forKey: "iris_agent_server_url"),
              let serverURL = URL(string: urlStr) else {
            errorText = "No server URL configured."
            return
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .checkingLive
            errorText = nil
        }

        Task {
            let endpoint = serverURL
                .appendingPathComponent("claude-code")
                .appendingPathComponent("live-status")
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 5

            var isLive = false
            var liveCWD: String?

            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isLive = (json["live"] as? Bool) == true
                liveCWD = json["cwd"] as? String
            }

            await MainActor.run {
                if isLive {
                    let sessionName = liveCWD.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code"
                    let doc = documentStore.addDocument(name: sessionName, model: "claude_code")
                    registerSessionOnBackend(doc)
                    isPresented = false
                    onCreated(doc)
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        phase = .choosing
                        errorText = "No live session. Run claudei on your Mac first."
                    }
                }
            }
        }
    }

    // MARK: - Codex

    private func fetchCodexSessionsList() {
        guard let urlStr = UserDefaults.standard.string(forKey: "iris_agent_server_url"),
              let serverURL = URL(string: urlStr) else {
            errorText = "No server URL configured."
            return
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .loadingCodex
            errorText = nil
        }

        Task {
            let fetched = await Self.fetchLinkedSessions(modelID: "codex", serverURL: serverURL)
            await MainActor.run {
                codexSessions = fetched
                withAnimation(.easeInOut(duration: 0.25)) {
                    phase = .codexReady
                }
            }
        }
    }

    private func startNewCodexSession() {
        guard let urlStr = UserDefaults.standard.string(forKey: "iris_agent_server_url"),
              let serverURL = URL(string: urlStr) else {
            errorText = "No server URL configured."
            return
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .creatingCodex
            errorText = nil
        }

        Task {
            let created = await Self.startLinkedSession(modelID: "codex", serverURL: serverURL)
            await MainActor.run {
                guard let created else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        phase = .codexReady
                        errorText = "Could not start session. Check backend."
                    }
                    return
                }
                selectRemoteSession(created, modelID: "codex")
            }
        }
    }

    // MARK: - Shared

    private func selectRemoteSession(_ session: RemoteSession, modelID: String) {
        let docID = Self.stableDocumentID(from: session.sessionID)

        let linkedDoc = Document(
            id: docID,
            name: session.name,
            model: modelID,
            lastOpened: Date(),
            preview: session.preview,
            backendSessionID: session.sessionID,
            codexConversationID: modelID == "codex"
                ? ((session.conversationID?.isEmpty == false) ? session.conversationID : session.sessionID)
                : nil,
            codexCWD: modelID == "codex" ? session.cwd : nil,
            claudeCodeConversationID: nil,
            claudeCodeCWD: nil
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
        let model = doc.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-5.2-mini" : doc.model
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

    // MARK: - Networking Helpers

    private static func startLinkedSession(modelID: String, serverURL: URL) async -> RemoteSession? {
        let endpoint = serverURL.appendingPathComponent("linked-sessions").appendingPathComponent("start")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = ["provider": modelID, "name": ""]
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
        let conversationID = ((item["conversation_id"] as? String) ?? (metadata["codex_conversation_id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = ((item["cwd"] as? String) ?? (metadata["codex_cwd"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let titleRaw = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleRaw.isEmpty ? "Codex Session" : titleRaw
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
            if !discovered.isEmpty { return discovered }
        }
        return await fetchSessionBackedSessions(modelID: modelID, serverURL: serverURL)
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

    private static func fetchSessionBackedSessions(modelID: String, serverURL: URL) async -> [RemoteSession] {
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

        let metadataKey = "codex_conversation_id"

        let matches: [RemoteSession] = items.compactMap { item -> RemoteSession? in
            let model = (item["model"] as? String ?? "").lowercased()
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            let hasConversationID = {
                if let val = metadata[metadataKey] as? String, !val.trimmingCharacters(in: .whitespaces).isEmpty {
                    return true
                }
                return false
            }()

            guard model == "codex" || hasConversationID else { return nil }

            let id = item["id"] as? String ?? UUID().uuidString
            let rawName = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName.isEmpty ? "Untitled" : rawName
            let updatedAt = item["updated_at"] as? String ?? ""
            let preview = (item["last_message_preview"] as? String) ?? ""
            let conversationID = (metadata[metadataKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = (metadata["codex_cwd"] as? String)?
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

        return matches
            .sorted { sessionTimestamp($0.updatedAt) > sessionTimestamp($1.updatedAt) }
            .prefix(6)
            .map { $0 }
    }

    private static let timestampFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func sessionTimestamp(_ value: String) -> Date {
        timestampFormatterWithFractional.date(from: value)
            ?? timestampFormatter.date(from: value)
            ?? .distantPast
    }

    private static func stableDocumentID(from raw: String) -> UUID {
        if let existing = UUID(uuidString: raw) { return existing }
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
        return UUID(uuidString: "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)") ?? UUID()
    }
}

struct CanvasScreen: View {
    let document: Document
    @ObservedObject var documentStore: DocumentStore
    @StateObject private var canvasState = CanvasState()
    @Environment(\.dismiss) var dismiss

    private var currentDocument: Document {
        documentStore.documents.first(where: { $0.id == document.id }) ?? document
    }

    var body: some View {
        ContentView(document: currentDocument, documentStore: documentStore, onBack: { dismiss() })
            .environmentObject(canvasState)
            .navigationBarBackButtonHidden(true)
    }
}
