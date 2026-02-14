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
    ModelChoice(id: "claude", name: "Claude (Alias)", subtitle: "Routes to default Claude model"),
]

private struct AgentPickerOverlay: View {
    let documentStore: DocumentStore
    @Binding var isPresented: Bool
    let onCreated: (Document) -> Void

    @State private var name = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 12) {
                Text("New Note")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                TextField("Document name", text: $name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("Choose Model")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.top, 4)

                ForEach(choices) { choice in
                    Button {
                        let doc = documentStore.addDocument(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            model: choice.id
                        )
                        isPresented = false
                        onCreated(doc)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(choice.name)
                                .font(.system(size: 15, weight: .semibold))
                            Text(choice.subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                Button("Cancel") {
                    isPresented = false
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: 430)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.13, blue: 0.16))
            )
            .padding(24)
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
