import SwiftUI

struct HomeView: View {
    @StateObject private var appState = IrisPhoneState()
    @State private var showingCreateSession = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                if appState.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions Yet",
                        systemImage: "rectangle.stack.badge.plus",
                        description: Text("Create a session to start multi-device work.")
                    )
                } else {
                    ForEach(appState.sessions) { session in
                        NavigationLink {
                            ContentView(session: session)
                                .environmentObject(appState)
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreateSession = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable {
                await appState.fetchSessions()
            }
            .task {
                await appState.fetchSessions()
            }
            .sheet(isPresented: $showingCreateSession) {
                CreateSessionSheet { name in
                    await appState.createSession(name: name)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(appState)
            }
            .safeAreaInset(edge: .bottom) {
                if let error = appState.lastError {
                    ErrorBanner(message: error) {
                        appState.clearError()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .padding(.top, 2)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.white)
                .lineLimit(3)

            Spacer(minLength: 8)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                Text(relativeTime(from: session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(session.status.uppercased())
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(minWidth: 60, minHeight: 24)
                .background(session.status == "active" ? Color.green.opacity(0.15) : Color.gray.opacity(0.2))
                .foregroundStyle(session.status == "active" ? .green : .gray)
                .clipShape(Capsule())
        }
        .padding(.vertical, 6)
    }

    private func relativeTime(from raw: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: raw) else { return "Updated just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

private struct CreateSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var isCreating = false
    @State private var localError: String?

    let onCreate: (String) async -> String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Session name", text: $name)

                if let localError, !localError.isEmpty {
                    Text(localError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("New Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            isCreating = true
                            localError = nil
                            let error = await onCreate(name)
                            isCreating = false

                            if let error, !error.isEmpty {
                                localError = "Could not create session: \(error)"
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isCreating)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SettingsView: View {
    @EnvironmentObject var appState: IrisPhoneState
    @Environment(\.dismiss) private var dismiss

    @State private var backendURL = ""
    @State private var deviceID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    TextField("http://<mac-lan-ip>:5001", text: $backendURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Use your Mac LAN IP when running on physical iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Identity") {
                    TextField("Device ID", text: $deviceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        appState.backendBaseURL = backendURL
                        appState.deviceID = deviceID
                        appState.persistConfig()
                        dismiss()
                    }
                }
            }
            .onAppear {
                backendURL = appState.backendBaseURL
                deviceID = appState.deviceID
            }
        }
    }
}

#Preview {
    HomeView()
}
