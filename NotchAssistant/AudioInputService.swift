import AVFoundation
import Speech

/// Captures microphone audio with AVAudioEngine and transcribes it on-device
/// using Apple's Speech framework.
///
/// TODO: Swap in WhisperKitTranscriber once WhisperKit is integrated.
final class AudioInputService: NSObject {

    enum AudioInputError: LocalizedError {
        case permissionDenied
        case recognizerUnavailable
        case noInputDevice
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone or speech recognition access was denied. Enable both in System Settings → Privacy & Security."
            case .recognizerUnavailable:
                return "Speech recognition is unavailable on this Mac."
            case .noInputDevice:
                return "No audio input device found."
            case .noSpeech:
                return "Didn't catch any speech."
            }
        }
    }

    private var audioEngine = AVAudioEngine()
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var completion: ((Result<String, Error>) -> Void)?
    private var tapInstalled = false
    private var finalizeFallback: DispatchWorkItem?

    private(set) var isListening = false

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestPermissions() async -> Bool {
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return micGranted && speechStatus == .authorized
    }

    /// Starts capturing and transcribing. Partial transcripts stream through
    /// `onPartial`; the final transcript (or error) arrives via `onCompletion`
    /// exactly once after `stopAndFinalize()` or a recognizer-side stop.
    func startListening(onPartial: @escaping (String) -> Void,
                        onCompletion: @escaping (Result<String, Error>) -> Void) throws {
        cancelListening()

        // Fresh recognizer per session — reusing one is the known cause of
        // instant kAFAssistantError 1101 failures on the next session.
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw AudioInputError.recognizerUnavailable
        }

        // Fresh engine per session: a reused engine sometimes refuses to
        // restart after a capture + TTS playback cycle ("couldn't start
        // listening" on the second request).
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // Both checks matter: during output-device transitions (e.g. AirPods
        // flipping between music and mic profiles after TTS) the format
        // briefly reports 0 Hz or 0 channels and engine start would throw.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioInputError.noInputDevice
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device recognition: no network dependency, so it never throws the
        // intermittent "operation couldn't be completed (kAFAssistantError…)"
        // failures that online recognition does. The dropped-final problem it
        // used to have is handled by the finalize fallback in stopAndFinalize().
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request
        latestTranscript = ""
        completion = onCompletion

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latestTranscript = result.bestTranscription.formattedString
                if result.isFinal {
                    self.finish(.success(self.latestTranscript))
                    return
                }
                onPartial(self.latestTranscript)
            }
            if let error {
                // "No speech detected" style errors still count if we heard something.
                if self.latestTranscript.isEmpty {
                    self.finish(.failure(error))
                } else {
                    self.finish(.success(self.latestTranscript))
                }
            }
        }

        // nil format = "whatever the node's format is at tap time", which
        // survives sample-rate changes between our query above and the tap.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }

    /// Stops capturing and lets the recognizer deliver its final transcript.
    func stopAndFinalize() {
        guard isListening else { return }
        stopEngine()
        recognitionRequest?.endAudio()
        // On-device recognition often never fires `isFinal` after endAudio —
        // it just stops. Without a fallback the captured words are silently
        // dropped. So if no final result lands quickly, deliver whatever we
        // already heard.
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            if self.latestTranscript.isEmpty {
                self.finish(.failure(AudioInputError.noSpeech))
            } else {
                self.finish(.success(self.latestTranscript))
            }
        }
        finalizeFallback = fallback
        // 0.35s: a real final result lands well under that when it comes at
        // all; waiting longer just added dead air before every request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: fallback)
    }

    /// Tears everything down without delivering a transcript.
    func cancelListening() {
        completion = nil
        finalizeFallback?.cancel()
        finalizeFallback = nil
        stopEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        latestTranscript = ""
        isListening = false
    }

    private func stopEngine() {
        // Touching `inputNode` lazily instantiates the HAL input unit via a
        // dispatch_sync that deadlocks the main thread when no capture
        // session exists yet (e.g. mic permission still undetermined), so
        // bail unless we actually started capturing.
        guard tapInstalled || audioEngine.isRunning else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let completion else { return }
        self.completion = nil
        finalizeFallback?.cancel()
        finalizeFallback = nil
        stopEngine()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
        completion(result)
    }
}
