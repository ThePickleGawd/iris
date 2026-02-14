import AVFoundation
import Accelerate

class AudioCaptureService: ObservableObject {
    @Published var audioLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var isCapturing = false
    private var smoothedLevel: Float = 0

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    func startCapture() {
        guard !isCapturing else { return }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            beginCapture()
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.beginCapture() }
                }
            }
        case .denied:
            print("Microphone permission denied")
        @unknown default:
            break
        }
    }

    private func beginCapture() {
        guard !isCapturing else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
            self?.onAudioBuffer?(buffer)
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            audioEngine = engine
            isCapturing = true
        } catch {
            print("Audio capture failed: \(error)")
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isCapturing = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        DispatchQueue.main.async {
            self.audioLevel = 0
            self.smoothedLevel = 0
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = UInt(buffer.frameLength)

        var rms: Float = 0
        vDSP_measqv(channelData, 1, &rms, frames)
        rms = sqrtf(rms)

        let attack: Float = 0.6
        let decay: Float = 0.15
        let alpha = rms > smoothedLevel ? attack : decay
        smoothedLevel = alpha * rms + (1 - alpha) * smoothedLevel

        DispatchQueue.main.async {
            self.audioLevel = self.smoothedLevel
        }
    }
}
