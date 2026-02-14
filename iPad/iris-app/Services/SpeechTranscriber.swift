import Speech
import AVFoundation

/// On-device speech-to-text using SFSpeechRecognizer.
/// Feed audio buffers from AudioCaptureService via `appendBuffer(_:)`,
/// then call `stopTranscribing()` to get the final transcript.
class SpeechTranscriber: ObservableObject {

    @Published var partialTranscript: String = ""

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finalTranscript: String = ""

    /// Request speech recognition authorization. Call once at app launch or before first use.
    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    /// Begin a new recognition session. Audio buffers should be fed via `appendBuffer(_:)`.
    func startTranscribing() {
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil
        finalTranscript = ""
        partialTranscript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // Use on-device recognition when available
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.partialTranscript = text
                }
                if result.isFinal {
                    self.finalTranscript = text
                }
            }

            if error != nil {
                self.recognitionRequest = nil
                self.recognitionTask = nil
            }
        }
    }

    /// Feed an audio buffer from the microphone tap.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    /// Stop recognition and return the final transcript.
    func stopTranscribing() -> String {
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Give a brief moment for final result, but use what we have
        let transcript = finalTranscript.isEmpty ? partialTranscript : finalTranscript

        recognitionTask?.cancel()
        recognitionTask = nil

        DispatchQueue.main.async {
            self.partialTranscript = ""
        }

        return transcript
    }
}
