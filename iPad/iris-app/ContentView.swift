import SwiftUI
import PencilKit

struct ContentView: View {
    @EnvironmentObject var canvasState: CanvasState
    @StateObject private var audioService = AudioCaptureService()
    let document: Document
    var onBack: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            CanvasView(document: document)
                .environmentObject(canvasState)

            SiriGlowView(isActive: canvasState.isRecording, audioLevel: audioService.audioLevel)

            ToolbarView(
                onBack: onBack,
                onAITap: { canvasState.isRecording.toggle() },
                isRecording: canvasState.isRecording
            )
            .environmentObject(canvasState)
            .allowsHitTesting(true)
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .onChange(of: canvasState.isRecording) { _, recording in
            if recording {
                audioService.startCapture()
            } else {
                audioService.stopCapture()
            }
        }
    }
}

#Preview {
    ContentView(document: Document(name: "Preview"))
        .environmentObject(CanvasState())
}
