import SwiftUI

struct HomeView: View {
    @EnvironmentObject var documentStore: DocumentStore
    @State private var showingAddDocument = false
    @State private var selectedDocument: Document?

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 24)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.1)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Text("Notes")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)

                        Spacer()

                        Button { showingAddDocument = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(documentStore.documents) { document in
                                DocumentCard(document: document)
                                    .onTapGesture {
                                        documentStore.updateLastOpened(document)
                                        selectedDocument = document
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            documentStore.deleteDocument(document)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationDestination(item: $selectedDocument) { document in
                CanvasScreen(document: document)
            }
            .sheet(isPresented: $showingAddDocument) {
                AddDocumentSheet(documentStore: documentStore)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Document Card

struct DocumentCard: View {
    let document: Document

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)

                VStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.gray.opacity(0.15))
                            .frame(height: 2)
                    }
                }
                .padding(20)
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(document.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(document.lastOpened, style: .relative)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.15))
        )
    }
}

// MARK: - Add Document Sheet

struct AddDocumentSheet: View {
    @ObservedObject var documentStore: DocumentStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Document Name") {
                    TextField("My Notes", text: $name)
                }
            }
            .navigationTitle("New Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        documentStore.addDocument(name: name)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Canvas Screen

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

#Preview {
    HomeView()
        .environmentObject(DocumentStore())
}
