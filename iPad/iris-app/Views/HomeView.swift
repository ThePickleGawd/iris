import SwiftUI

struct HomeView: View {
    @EnvironmentObject var documentStore: DocumentStore
    @State private var showingAddDocument = false
    @State private var showingSettings = false
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

                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 22))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .padding(.trailing, 12)

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
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) {
            IrisSettingsView()
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
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-autoOpenFirst"),
               selectedDocument == nil,
               let doc = documentStore.documents.first {
                selectedDocument = doc
            }
        }
    }
}

// MARK: - Settings View

private struct IrisSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var localIP: String = "..."

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.1)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Network section
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Network", systemImage: "wifi")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)

                            VStack(spacing: 12) {
                                HStack {
                                    Text("This iPad")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.5))
                                    Spacer()
                                    Text("\(localIP):\(String(AgentHTTPServer.defaultPort))")
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                        .textSelection(.enabled)
                                }

                                Rectangle()
                                    .fill(.white.opacity(0.06))
                                    .frame(height: 0.5)

                                HStack {
                                    Text("Port")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.5))
                                    Spacer()
                                    Text("\(String(AgentHTTPServer.defaultPort))")
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )

                            Text("Enter this IP address in the Mac app's Config > Devices section to connect.")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                    .padding(32)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                localIP = Self.getWiFiIPAddress() ?? "No Wi-Fi"
            }
        }
        .preferredColorScheme(.dark)
    }

    static func getWiFiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let sa = ptr.pointee.ifa_addr.pointee
            guard sa.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: hostname)
            }
        }
        return address
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

                HStack(spacing: 6) {
                    Text(document.lastOpened, style: .relative)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))

                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.3))

                    Text(document.agentDisplayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
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

// MARK: - Agent Picker Overlay

private struct AgentInfo: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let icon: String
    let accentTop: Color
    let accentBottom: Color
}

private let agentOptions: [AgentInfo] = [
    AgentInfo(
        id: "iris",
        name: "Iris",
        subtitle: "Visual assistant across your devices",
        icon: "eye.circle.fill",
        accentTop: Color(red: 0.49, green: 0.28, blue: 0.96),
        accentBottom: Color(red: 0.38, green: 0.36, blue: 0.92)
    ),
    AgentInfo(
        id: "codex",
        name: "Codex",
        subtitle: "Autonomous coding agent",
        icon: "terminal.fill",
        accentTop: Color(red: 0.02, green: 0.71, blue: 0.83),
        accentBottom: Color(red: 0.12, green: 0.56, blue: 0.87)
    ),
    AgentInfo(
        id: "claude_code",
        name: "Claude Code",
        subtitle: "Interactive coding assistant",
        icon: "chevron.left.forwardslash.chevron.right",
        accentTop: Color(red: 0.96, green: 0.62, blue: 0.04),
        accentBottom: Color(red: 0.92, green: 0.45, blue: 0.20)
    ),
]

struct AgentPickerOverlay: View {
    @ObservedObject var documentStore: DocumentStore
    @Binding var isPresented: Bool
    var onCreated: (Document) -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Dimmed backdrop
            Color.black.opacity(appeared ? 0.55 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }

            // Centered floating panel
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Text("New Note")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Choose an agent")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.top, 28)
                .padding(.bottom, 24)

                // Divider
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.horizontal, 24)

                // Agent rows
                VStack(spacing: 0) {
                    ForEach(Array(agentOptions.enumerated()), id: \.element.id) { index, agent in
                        AgentRow(agent: agent) {
                            let doc = documentStore.addDocument(name: "Untitled", agent: agent.id)
                            close()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onCreated(doc)
                            }
                        }

                        if index < agentOptions.count - 1 {
                            Rectangle()
                                .fill(.white.opacity(0.05))
                                .frame(height: 0.5)
                                .padding(.leading, 76)
                                .padding(.trailing, 24)
                        }
                    }
                }
                .padding(.vertical, 8)

                // Cancel button
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.horizontal, 24)

                Button { close() } label: {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            }
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.11, blue: 0.13))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 10)
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                appeared = true
            }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isPresented = false
        }
    }
}

private struct AgentRow: View {
    let agent: AgentInfo
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [agent.accentTop, agent.accentBottom],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: agent.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(agent.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.15))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(AgentRowButtonStyle())
    }
}

private struct AgentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.white.opacity(0.06)
                    : Color.clear
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
