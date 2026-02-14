import SwiftUI

@main
struct IrisApp: App {
    @StateObject private var documentStore = DocumentStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(documentStore)
        }
    }
}
