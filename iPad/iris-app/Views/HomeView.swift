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
                    VStack(spacing: 8) {
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.gray.opacity(0.18))
                                .frame(height: 2)
                        }
                    }
                    .padding(20)
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
}

private let choices: [ModelChoice] = [
    ModelChoice(id: "gpt-5.2", name: "GPT-5.2", subtitle: "OpenAI general-purpose model"),
    ModelChoice(id: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5", subtitle: "Best for screenshot + widget workflows"),
    ModelChoice(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", subtitle: "Fast multimodal model for lightweight tasks"),
    ModelChoice(id: "claude", name: "Claude (Alias)", subtitle: "Routes to default Claude model"),
]

private struct AgentPickerOverlay: View {
    let documentStore: DocumentStore
    @Binding var isPresented: Bool
    let onCreated: (Document) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

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
                            let doc = documentStore.addDocument(
                                name: "",
                                model: choice.id
                            )
                            isPresented = false
                            onCreated(doc)
                            // Register on backend immediately so other devices see it
                            registerSessionOnBackend(doc)
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
        case 0:
            return Color(red: 0.39, green: 0.62, blue: 1.0)
        case 1:
            return Color(red: 0.62, green: 0.64, blue: 1.0)
        default:
            return Color(red: 0.43, green: 0.86, blue: 0.74)
        }
    }

    private func modelSymbol(for index: Int) -> String {
        switch index {
        case 0:
            return "circle.grid.2x2.fill"
        case 1:
            return "bolt.fill"
        default:
            return "square.stack.3d.down.forward.fill"
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
