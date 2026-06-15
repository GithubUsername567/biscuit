import AppKit
import Foundation
import SwiftUI

/// Single source of truth for the assistant: state machine, conversation
/// history, and orchestration of audio, Ollama, and speech services.
@MainActor
final class AppState: ObservableObject {

    @Published var state: AssistantState = .idle {
        didSet { syncWakeWord() }
    }
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var showSettings = false
    /// Last spoken reply, shown as a caption so the dog is useful on mute.
    @Published var caption: String?

    /// The request + tool calls of the last successful model run, kept so the
    /// user can say "save that" to turn it into a shortcut. Cleared on the
    /// next unrelated request.
    private var pendingCapture: (request: String, calls: [OllamaToolCall])?

    /// Set by the app delegate so views can ask the floating panel to close.
    var onRequestHide: (@MainActor () -> Void)?

    private let ollama = OllamaService()
    private let audio = AudioInputService()
    private let speech = SpeechService()
    private let wakeWord = WakeWordService()
    private var generationTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?
    /// Set when finishListening is called before the async startListening has
    /// actually begun capturing (quick hotkey taps) — applied once it starts.
    private var pendingFinalize = false
    private var listenStartedAt = Date.distantPast
    private var listenRetries = 0
    /// Remembered so dead-input retries keep the same endpointing mode.
    private var lastHoldMode = false

    /// Keep the last 10 user/assistant exchanges in memory.
    private let maxMessages = 20

    init() {
        speech.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .responding else { return }
                self.state = .idle
                self.scheduleAutoHide(after: 1.0)
            }
        }
        wakeWord.onWake = { [weak self] in self?.handleWake() }
    }

    // MARK: - Settings (UserDefaults-backed; SettingsView writes via @AppStorage)

    var baseURL: String {
        UserDefaults.standard.string(forKey: SettingsKeys.ollamaBaseURL) ?? SettingsKeys.defaultBaseURL
    }

    var model: String {
        UserDefaults.standard.string(forKey: SettingsKeys.modelName) ?? SettingsKeys.defaultModel
    }

    var ttsEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.ttsEnabled) as? Bool ?? true
    }

    var ttsVoiceIdentifier: String? {
        UserDefaults.standard.string(forKey: SettingsKeys.ttsVoiceIdentifier)
    }

    var elevenLabsKey: String {
        UserDefaults.standard.string(forKey: SettingsKeys.elevenLabsAPIKey) ?? ""
    }

    var elevenLabsVoiceID: String {
        UserDefaults.standard.string(forKey: SettingsKeys.elevenLabsVoiceID) ?? ""
    }

    // MARK: - Text input

    func sendCurrentInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        send(text)
    }

    var recipesEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.recipesEnabled) as? Bool ?? true
    }

    var captionsEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.captionsEnabled) as? Bool ?? true
    }

    func send(_ text: String) {
        // "Save that" turns the last successful run into a shortcut. Read the
        // pending capture before interruptActivity clears it.
        if CustomCommandStore.parseSaveRequest(text) != nil, let capture = pendingCapture {
            let name = CustomCommandStore.parseSaveRequest(text)?.name
            interruptActivity()
            cancelAutoHide()
            messages.append(ChatMessage(role: .user, content: text))
            state = .processing
            saveCapture(capture, name: name)
            return
        }

        interruptActivity()
        cancelAutoHide()
        messages.append(ChatMessage(role: .user, content: text))
        trimHistory()
        state = .processing

        // Teaching: "when I say X, do Y" saves a shortcut, no model needed.
        if let taught = CustomCommandStore.parseTeachRequest(text) {
            CustomCommandStore.add(taught)
            BLog.log("CustomCommand: learned \"\(taught.phrase)\" (\(taught.steps.count) steps)")
            finishWithReply("Learned “\(taught.phrase).” Say it any time.")
            return
        }

        // User-taught shortcuts win over built-ins so they can override.
        if let command = CustomCommandStore.match(text) {
            runCustomCommand(command)
            return
        }

        // Fast path: a deterministic recipe answers common commands with no
        // model round-trip at all. Falls through to the model on no match or
        // a mid-recipe tool error.
        if recipesEnabled, let recipe = RecipeBook.match(text) {
            runRecipe(recipe)
            return
        }
        runModelLoop()
    }

    /// Runs a taught shortcut. If every step is recipe-able, the whole macro
    /// runs token-free; otherwise the steps are rejoined and handed to the
    /// model as one instruction.
    private func runCustomCommand(_ command: CustomCommand) {
        // Captured ("watch me do it") shortcuts replay their literal tool
        // calls directly — token-free, no planning.
        if let calls = command.capturedCalls, !calls.isEmpty {
            BLog.log("CustomCommand: \"\(command.phrase)\" — replaying \(calls.count) captured calls")
            generationTask = Task { [weak self] in
                guard let self else { return }
                for call in calls {
                    self.messages.append(ChatMessage(role: .tool, content: self.friendlyToolLabel(call)))
                    _ = await ToolExecutor.execute(call)
                    if Task.isCancelled { return }
                }
                self.presentReply("Done.")
            }
            return
        }

        let recipes = command.steps.map { RecipeBook.match($0) }
        guard recipes.allSatisfy({ $0 != nil }) else {
            BLog.log("CustomCommand: \"\(command.phrase)\" has a model step — running via model")
            // Replace the trigger turn with the explicit steps for the model.
            messages[messages.count - 1].content = command.steps.joined(separator: ", then ")
            runModelLoop()
            return
        }

        BLog.log("CustomCommand: \"\(command.phrase)\" — \(command.steps.count) steps, no model")
        generationTask = Task { [weak self] in
            guard let self else { return }
            var confirmations: [String] = []
            for recipe in recipes.compactMap({ $0 }) {
                var last = ""
                for call in recipe.calls {
                    self.messages.append(ChatMessage(role: .tool, content: self.friendlyToolLabel(call)))
                    last = await ToolExecutor.execute(call)
                    if Task.isCancelled { return }
                    if last.hasPrefix("Error") || last.hasPrefix("Refused") {
                        BLog.log("CustomCommand: step failed (\(last.prefix(60)))")
                        break
                    }
                }
                confirmations.append(recipe.confirm(last))
            }
            self.presentReply(confirmations.joined(separator: " "))
        }
    }

    /// Saves the last successful run as a shortcut. Pure-scripting runs store
    /// their literal tool calls for token-free replay; runs that involved
    /// on-screen clicks are saved as a model macro (the original request),
    /// since clicks can't be replayed against a different live screen.
    private func saveCapture(_ capture: (request: String, calls: [OllamaToolCall]), name: String?) {
        let phrase = (name ?? capture.request).trimmingCharacters(in: .whitespaces)
        let hadClicks = capture.calls.contains { ["click_element", "click_at"].contains($0.function.name) }
        let replayable = capture.calls.filter { CustomCommandStore.replayableTools.contains($0.function.name) }

        let command: CustomCommand
        if !hadClicks, !replayable.isEmpty {
            command = CustomCommand(phrase: phrase, steps: [capture.request], capturedCalls: replayable)
            BLog.log("Capture: saved \"\(phrase)\" — \(replayable.count) replayable calls")
        } else {
            command = CustomCommand(phrase: phrase, steps: [capture.request])
            BLog.log("Capture: saved \"\(phrase)\" — model macro (had clicks)")
        }
        pendingCapture = nil
        CustomCommandStore.add(command)
        presentReply("Saved as “\(phrase).” Say it any time.")
    }

    /// Speaks a canned reply with no model involvement (teaching ack, macro
    /// confirmation). Appends it to history and handles TTS / auto-hide.
    private func finishWithReply(_ reply: String) {
        generationTask = Task { [weak self] in self?.presentReply(reply) }
    }

    /// Final delivery for every reply path: records it, shows a caption (so
    /// the dog is useful on mute), speaks it if TTS is on, otherwise lingers
    /// long enough to read. `captureHint` appends the "save that" nudge.
    private func presentReply(_ reply: String, captureHint: Bool = false) {
        messages.append(ChatMessage(role: .assistant, content: reply))
        if captionsEnabled {
            caption = captureHint ? reply + "\n— say “save that” to keep it" : reply
        } else {
            caption = nil
        }
        if ttsEnabled {
            state = .responding
            speech.speak(reply)
        } else {
            state = .idle
            // ~1s per 12 chars so a muted user can actually read it.
            scheduleAutoHide(after: min(max(Double(reply.count) / 12.0, 4), 12))
        }
    }

    /// Runs a matched recipe's tool sequence directly, then speaks its
    /// templated confirmation — zero model tokens. If any tool reports an
    /// error, hands the conversation (user message already appended) to the
    /// model instead.
    private func runRecipe(_ recipe: RecipeMatch) {
        BLog.log("Recipe: matched \"\(recipe.name)\" — skipping model")
        generationTask = Task { [weak self] in
            guard let self else { return }
            var lastResult = ""
            for call in recipe.calls {
                self.messages.append(ChatMessage(role: .tool, content: self.friendlyToolLabel(call)))
                lastResult = await ToolExecutor.execute(call)
                if Task.isCancelled { return }
                if lastResult.hasPrefix("Error") || lastResult.hasPrefix("Refused") {
                    BLog.log("Recipe: \"\(recipe.name)\" tool failed — falling back to model")
                    self.runModelLoop()
                    return
                }
            }
            self.presentReply(recipe.confirm(lastResult))
        }
    }

    /// The full agentic model loop. Assumes the user message is already in
    /// `messages`.
    private func runModelLoop() {
        let maxToolRounds = 12 // see→act→verify loops need more rounds
        let provider = self.makeProvider()
        let requestText = messages.last(where: { $0.role == .user })?.content ?? ""

        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                var wire = self.wireHistory()
                var finalText = ""
                var rounds = 0
                var executedCalls: [OllamaToolCall] = []

                while true {
                    var assistantText = ""
                    var assistantIndex: Int?
                    var pendingCalls: [OllamaToolCall] = []

                    for try await event in provider.stream(messages: wire) {
                        switch event {
                        case .token(let token):
                            assistantText += token
                            if let index = assistantIndex {
                                self.messages[index].content = assistantText
                            } else {
                                self.state = .responding
                                self.messages.append(ChatMessage(role: .assistant, content: assistantText))
                                assistantIndex = self.messages.count - 1
                            }
                        case .toolCalls(let calls):
                            pendingCalls = calls
                        }
                    }
                    if Task.isCancelled { return }

                    if pendingCalls.isEmpty {
                        guard !assistantText.isEmpty else {
                            // Tool-only turns can legitimately end without prose.
                            if rounds > 0 {
                                self.state = .idle
                                self.scheduleAutoHide(after: 2)
                            } else {
                                self.reportError("No response from model.")
                            }
                            return
                        }
                        finalText = assistantText
                        break
                    }

                    // Execute the requested tools and loop for the final answer.
                    self.state = .processing
                    wire.append(OllamaMessage(role: ChatRole.assistant.rawValue, content: assistantText, toolCalls: pendingCalls))
                    for call in pendingCalls {
                        self.messages.append(ChatMessage(
                            role: .tool,
                            content: friendlyToolLabel(call)
                        ))
                        let result = await ToolExecutor.execute(call)
                        executedCalls.append(call)
                        wire.append(OllamaMessage(role: ChatRole.tool.rawValue, content: result, name: call.function.name))
                    }

                    rounds += 1
                    if rounds >= maxToolRounds {
                        self.reportError("Stopped after \(maxToolRounds) tool rounds without a final answer.")
                        return
                    }
                }

                // Offer "save that" when the run actually did something
                // (ignoring pure perception calls).
                let actionCalls = executedCalls.filter {
                    $0.function.name != "see_screen" && $0.function.name != "look_closely"
                }
                if !actionCalls.isEmpty {
                    self.pendingCapture = (request: requestText, calls: executedCalls)
                }
                self.presentReply(finalText, captureHint: !actionCalls.isEmpty)
            } catch is CancellationError {
                // cancel() already reset state
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.reportError(message)
            }
        }
    }

    /// Chooses the brain: Gemini in Capable mode (when a key is set),
    /// otherwise local Ollama.
    private func makeProvider() -> ChatProvider {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: SettingsKeys.brainMode) ?? "local"
        let geminiKey = defaults.string(forKey: SettingsKeys.geminiAPIKey) ?? ""
        if mode == "capable", !geminiKey.isEmpty {
            // Gemini first; if it errors (e.g. quota), the local model takes over.
            return FallbackChatProvider(
                primary: GeminiService(systemPrompt: OllamaService.agentSystemPrompt),
                secondary: ollama
            )
        }
        return ollama
    }

    private func friendlyToolLabel(_ call: OllamaToolCall) -> String {
        let args = call.argumentsDictionary
        switch call.function.name {
        case "see_screen": return "👀 looking at the screen"
        case "click_element": return "🖱️ clicking [\(args["number"]?.displayString ?? "?")]"
        case "type_text": return "⌨️ typing “\(args["text"]?.displayString.prefix(40) ?? "")”"
        case "press_key": return "⌨️ pressing \(args["key"]?.displayString ?? "")"
        case "open_app": return "📂 opening \(args["name"]?.displayString ?? "app")"
        case "open_url": return "🌐 opening a link"
        case "look_closely": return "🔍 looking closely"
        case "click_at": return "🖱️ clicking"
        case "web_search": return "🌐 searching the web"
        case "set_reminder": return "⏰ setting a reminder"
        case "read_clipboard": return "📋 reading clipboard"
        case "write_clipboard": return "📋 copying to clipboard"
        default: return "⚙️ \(call.function.name)"
        }
    }

    /// UI history → wire format. Tool-activity notes are display-only;
    /// loop-internal tool results are appended separately in send().
    private func wireHistory() -> [OllamaMessage] {
        messages.compactMap { message in
            switch message.role {
            case .user, .assistant:
                return OllamaMessage(role: message.role.rawValue, content: message.content)
            case .system, .tool:
                return nil
            }
        }
    }

    // MARK: - Wake word

    var wakeWordEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.wakeWordEnabled) as? Bool ?? true
    }

    /// Keeps the wake listener running exactly when the assistant is idle.
    /// Called on every state change and when settings change.
    func syncWakeWord() {
        if wakeWordEnabled, state == .idle {
            wakeWord.start()
        } else {
            wakeWord.stop()
        }
    }

    private func handleWake() {
        guard state == .idle else { return }
        BLog.log("WakeWord: wake handled — starting capture")
        // Background flow like the hotkey: the chime + dog bubble are the
        // only feedback, no panel — it steals focus from whatever the user
        // is doing.
        NSSound(named: "Pop")?.play()
        startListening()
    }

    // MARK: - Voice input

    /// Hotkey / mic button behavior: idle starts listening, listening
    /// finalizes and sends, busy states cancel and start a fresh capture.
    func toggleVoice() {
        switch state {
        case .listening:
            finishListening()
        case .processing, .responding:
            cancel()
            startListening()
        default:
            startListening()
        }
    }

    func startListening(isRetry: Bool = false, holdMode: Bool = false) {
        // A live wake engine means the input device (often Bluetooth) is
        // being handed off right now — give it a beat to settle, or the
        // capture engine starts cleanly but receives a dead, silent stream.
        let wakeWasActive = wakeWord.isRunning
        interruptActivity()
        cancelAutoHide()
        pendingFinalize = false
        if !isRetry { listenRetries = 0 }
        lastHoldMode = holdMode
        listenStartedAt = Date()
        Task {
            guard await audio.requestPermissions() else {
                state = .error(AudioInputService.AudioInputError.permissionDenied.errorDescription ?? "Permission denied.")
                return
            }
            if wakeWasActive {
                try? await Task.sleep(for: .milliseconds(350))
            }
            inputText = ""
            state = .listening
            let beginCapture = { [weak self] in
                // Auto-endpoint (VAD) for click/tap; hold-to-talk ends only on
                // key release, so it never cuts off while held.
                try self?.audio.startListening(autoEndpoint: !holdMode, onPartial: { text in
                    Task { @MainActor in self?.inputText = text }
                }, onCompletion: { result in
                    Task { @MainActor in self?.handleTranscription(result) }
                })
            }
            // Engine start loses to audio-device transitions (AirPods swap
            // profiles for ~1s after TTS playback) — retry with backoff
            // instead of giving up after one quick attempt.
            var lastError: Error?
            for delayMs in [0, 250, 600, 1200] {
                if delayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard state == .listening else { return } // user cancelled meanwhile
                }
                do {
                    try beginCapture()
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    NSLog("startListening attempt failed: \(error.localizedDescription)")
                }
            }

            if lastError == nil {
                // A release that beat the async start: finalize now.
                if pendingFinalize {
                    pendingFinalize = false
                    finishListening()
                }
            } else {
                // Avoid surfacing raw "(com.apple…)" NSError text; show our
                // own messages, fall back to a clean generic line.
                let message = (lastError as? AudioInputService.AudioInputError)?.errorDescription
                    ?? "Couldn't start listening. Try again."
                state = .error(message)
            }
        }
    }


    func finishListening() {
        // Released before capture actually began — remember to finalize once
        // startListening reaches the engine.
        guard audio.isListening else {
            pendingFinalize = true
            return
        }
        audio.stopAndFinalize()
    }

    private func handleTranscription(_ result: Result<String, Error>) {
        switch result {
        case .success(let text) where !text.trimmingCharacters(in: .whitespaces).isEmpty:
            BLog.log("AppState: auto-sending transcription (\(text.count) chars)")
            inputText = ""
            send(text)
        case .success:
            // Heard nothing — just slip away.
            state = .idle
            hidePanel()
        case .failure(let error):
            // Dead input stream (Bluetooth handoff): rebuild the whole
            // capture engine — the session "worked", it just heard a corpse.
            if case AudioInputService.AudioInputError.deadInput = error {
                guard listenRetries < 3 else {
                    // Three rebuilds, still silence: stop pretending. Say it.
                    BLog.log("AppState: dead input persisted after 3 rebuilds — giving up loudly")
                    notify("I'm getting silence from the microphone. If you just switched audio devices, try again in a second — otherwise check System Settings → Sound → Input.")
                    return
                }
                listenRetries += 1
                BLog.log("AppState: dead input — rebuilding capture (retry \(listenRetries)/3, holdMode=\(lastHoldMode))")
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self, self.state == .listening else { return }
                    self.startListening(isRetry: true, holdMode: self.lastHoldMode)
                }
                return
            }
            // Recognizer sessions sometimes die the moment they start
            // (kAFAssistantError 1101), usually because TTS hasn't released
            // the audio route yet — that's the "listening flashes then
            // vanishes" glitch. Retry a few times with a brief settle.
            if Date().timeIntervalSince(listenStartedAt) < 1.5, listenRetries < 3 {
                listenRetries += 1
                BLog.log("AppState: recognizer died instantly (\(error.localizedDescription)) — retry \(listenRetries)/3")
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    // The user may have cancelled or started something else
                    // meanwhile — never spawn a session behind their back.
                    guard let self, self.state == .listening else { return }
                    self.startListening(isRetry: true, holdMode: self.lastHoldMode)
                }
                return
            }
            // If the mic isn't actually granted, say so rather than vanishing.
            if AudioInputService.microphoneStatus != .authorized {
                notify("I can't hear you — enable the microphone in System Settings → Privacy → Microphone.")
                return
            }
            // Otherwise: almost always "no speech detected" from a too-quick
            // tap. Spoken errors here feel like the prompt "didn't go
            // through" — just log and slip away instead.
            NSLog("Speech recognition ended without transcript: \(error.localizedDescription)")
            state = .idle
            hidePanel()
        }
    }

    // MARK: - Cancel / cleanup

    /// Stops recording, inference, or speech — whatever is in flight.
    func cancel() {
        interruptActivity()
        state = .idle
    }

    func dismissError() {
        if case .error = state { state = .idle }
    }

    /// Silent on-screen notice via the dog bubble (no speech).
    func notify(_ message: String) {
        state = .error(message)
        scheduleAutoHide(after: 10)
    }

    /// Errors must be audible now that work happens without the panel.
    private func reportError(_ message: String) {
        state = .error(message)
        if ttsEnabled {
            speech.speak(String(message.prefix(140)))
        }
        scheduleAutoHide(after: 8)
    }

    func clearConversation() {
        interruptActivity()
        messages = []
        state = .idle
    }

    func hidePanel() {
        cancelAutoHide()
        onRequestHide?()
    }

    /// Pre-load the local model so the first request answers fast.
    func warmUpModel() {
        ollama.warmup()
    }

    // MARK: - Auto-hide (HUD behavior: pop up, answer, go away)

    func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.showSettings else { return }
            switch self.state {
            case .idle, .error:
                self.state = .idle
                self.caption = nil
                self.onRequestHide?()
            default:
                break
            }
        }
    }

    private func interruptActivity() {
        generationTask?.cancel()
        generationTask = nil
        caption = nil
        pendingCapture = nil
        // Release the wake engine before the capture engine starts; state
        // didSet would stop it anyway, but only after the async start races.
        wakeWord.stop()
        audio.cancelListening()
        speech.stop()
    }

    private func trimHistory() {
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }
}
