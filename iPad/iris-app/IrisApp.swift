import SwiftUI

@main
struct IrisApp: App {
    @StateObject private var canvasState = CanvasState()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(canvasState)
        }
    }
}
