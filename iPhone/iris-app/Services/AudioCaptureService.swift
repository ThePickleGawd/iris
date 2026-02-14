import AVFoundation
import Accelerate
import Speech

final class AudioCaptureService: NSObject, ObservableObject {
    @Published var liveTranscript: String = ""
    @Published var audioLevel: Float = 0
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func startTranscription() {
        guard !isRecording else { return }

        Task { @MainActor in
            let micGranted = await requestMicrophonePermission()
            guard micGranted else {
                errorMessage = "Microphone permission denied. Enable it in Settings."
                return
            }

            let speechGranted = await requestSpeechPermission()
            guard speechGranted else {
                errorMessage = "Speech recognition permission denied. Enable it in Settings."
                return
            }

            do {
                errorMessage = nil
                try startAudioPipeline()
            } catch {
                errorMessage = "Failed to start transcription: \(error.localizedDescription)"
                stopTranscription(cancelTask: true)
            }
        }
    }

    func stopTranscription(cancelTask: Bool = true) {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest?.endAudio()
        if cancelTask {
            recognitionTask?.cancel()
        }

        recognitionRequest = nil
        if cancelTask {
            recognitionTask = nil
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        DispatchQueue.main.async {
            self.audioLevel = 0
            self.isRecording = false
        }
    }

    private func startAudioPipeline() throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw NSError(domain: "IrisPhone", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let request = self.recognitionRequest else { return }
            request.append(buffer)
            self.updateAudioLevel(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                DispatchQueue.main.async {
                    self.liveTranscript = result.bestTranscription.formattedString
                }

                if result.isFinal {
                    self.stopTranscription(cancelTask: false)
                    self.recognitionTask = nil
                }
            }

            if let error {
                if self.shouldIgnoreSpeechError(error) {
                    DispatchQueue.main.async {
                        self.errorMessage = nil
                    }
                    self.stopTranscription(cancelTask: false)
                    self.recognitionTask = nil
                    return
                }

                DispatchQueue.main.async {
                    self.errorMessage = "Transcription error: \(error.localizedDescription)"
                }
                self.stopTranscription(cancelTask: true)
            }
        }

        DispatchQueue.main.async {
            self.isRecording = true
        }
    }

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = vDSP_Length(buffer.frameLength)
        guard frameLength > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, frameLength)
        let normalized = min(max(rms * 10, 0), 1)

        DispatchQueue.main.async {
            self.audioLevel = normalized
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func shouldIgnoreSpeechError(_ error: Error) -> Bool {
        let description = error.localizedDescription.lowercased()
        if description.contains("no speech detected") {
            return true
        }

        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 {
            return true
        }
        return false
    }
}
