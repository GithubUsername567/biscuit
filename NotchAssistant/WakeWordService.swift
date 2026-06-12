import AVFoundation
import Speech

/// Always-on "Biscuit" wake word detector.
///
/// Runs its own AVAudioEngine tap + SFSpeechRecognizer while the assistant is
/// idle and fires `onWake` when the wake word shows up in a partial
/// transcript. Recognition is strictly on-device — if the Mac doesn't support
/// it the service simply stays off, so ambient room audio is never streamed
/// anywhere.
///
/// AppState starts/stops this around its own state machine; the service never
/// runs while the assistant is capturing a request or speaking a reply (which
/// also stops it from waking on its own TTS saying "Biscuit").
@MainActor
final class WakeWordService {

    var onWake: (() -> Void)?

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var recycleTimer: Timer?

    /// Desired state: restarts and recycles only continue while true.
    private var shouldRun = false
    /// Stale-callback guard: recycling cancels the old task, which then emits
    /// a cancellation error that must not trigger another restart.
    private var generation = 0

    private let wakeWord = "biscuit"
    /// On-device sessions accumulate transcript forever, so matching gets
    /// slowly more expensive; recycling once a minute keeps it cheap. A
    /// recycle landing mid-"Biscuit" is rare and just means saying it again.
    private let sessionLifetime: TimeInterval = 55

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        startSession()
    }

    func stop() {
        guard shouldRun else { return }
        shouldRun = false
        teardownSession()
    }

    private func startSession() {
        guard shouldRun else { return }
        teardownSession()
        generation += 1
        let gen = generation

        // Never prompt from here — permissions are requested by the normal
        // listening flow. Until granted, the wake word just stays dormant.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // 0 Hz / 0 channels happens during audio-device transitions (see
        // AudioInputService) — wait one beat and try again.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            scheduleRestart(after: 2, generation: gen)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = ["Biscuit"]
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.shouldRun, self.generation == gen else { return }
                if let result,
                   result.bestTranscription.formattedString.lowercased().contains(self.wakeWord) {
                    self.teardownSession()
                    self.onWake?()
                    return
                }
                if error != nil {
                    // On-device tasks die routinely after long silences —
                    // that's normal churn, not a failure. Re-arm quietly.
                    self.scheduleRestart(after: 0.5, generation: gen)
                }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            scheduleRestart(after: 2, generation: gen)
            return
        }

        let timer = Timer(timeInterval: sessionLifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startSession() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recycleTimer = timer
    }

    private func scheduleRestart(after seconds: TimeInterval, generation gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.shouldRun, self.generation == gen else { return }
            self.startSession()
        }
    }

    private func teardownSession() {
        recycleTimer?.invalidate()
        recycleTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        // Same HAL-deadlock guard as AudioInputService: don't touch inputNode
        // unless a capture session actually exists.
        guard tapInstalled || audioEngine.isRunning else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }
}
