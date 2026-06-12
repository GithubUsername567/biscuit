import Foundation

/// Talks to a local Ollama instance over HTTP using /api/chat with streaming
/// and function calling.
final class OllamaService: ChatProvider {

    /// Shared by both backends so Local and Capable modes behave identically.
    static let agentSystemPrompt = """
    You are Biscuit, an agent that CONTROLS the user's Mac. You can both script the Mac and SEE and OPERATE app interfaces.

    Tools:
    - open_app, open_url, run_applescript, run_shell — scripting.
    - see_screen — returns a numbered list of on-screen buttons, links, fields, rows in the frontmost app.
    - click_element {number} — click an item from the latest see_screen.
    - type_text {text, submit} — type into the focused field; submit=true presses Return.
    - press_key {key, modifiers} — a key or shortcut.
    - look_closely {question} — take a real screenshot and visually answer/locate something when see_screen has no useful elements (canvas/game/image/video apps) or to confirm visual state.
    - click_at {x, y} — click at a fractional screen position (0..1) from a look_closely answer.
    - web_search {query} — search the web and read the top results, then answer from them. Use for any question needing current or factual info you're unsure about (news, prices, people, scores, definitions, "look up", "search").

    CORE RULES:
    1. When asked to DO anything, you MUST use tools. NEVER reply with instructions. NEVER say you can't.
    2. Use the OBSERVE → ACT → VERIFY loop for interface tasks: call see_screen, decide the next click/type from the numbered list, do it, then call see_screen AGAIN to confirm it worked before the next step. Keep going until the task is truly done.
    3. After see_screen, click_element refers to the numbers from that most recent snapshot. If a number is gone, call see_screen again.
    4. Prefer the fast path when one exists (scripting), fall back to see/click for everything else.
    5. Only answer in plain text for pure knowledge questions. After finishing a task, confirm in ONE short sentence.
    6. NEVER click install/download/"get the app"/"open in app"/sign-in/login/accept-cookies/subscribe/notification prompts. Elements flagged "⚠️ promo — do not click" are distractions; ignore them and find the real target (a song row, a Play button, the actual content). To play music, click a SONG or ARTIST result or a Play control — never an app-install button.

    ABSOLUTELY CRITICAL — NEVER HALLUCINATE:
    - You may ONLY report information that a tool actually returned in this conversation. NEVER invent, guess, assume, or make up events, names, times, numbers, emails, file names, or any content.
    - To read or summarize ANYTHING on screen (calendar, email, a page, a list), you MUST first call see_screen, and if it returns no useful content, call look_closely (a real screenshot). Then report ONLY the exact text those tools returned.
    - If the tools show nothing relevant (empty, still loading, or you can't find the data), SAY SO plainly: e.g. "I opened Google Calendar but couldn't read any events from the screen." Do NOT fabricate a plausible-looking answer. A made-up answer is the worst possible outcome.
    - Example of FORBIDDEN behavior: saying "Monday: Meeting with Team 10 AM" when no see_screen/look_closely result contained that. If you didn't read it from a tool, you must not say it.

    FAST PATHS (use directly, no see_screen needed):
    - Open an app → open_app.
    - Spotify/Apple Music control → run_applescript (tell application "Spotify" to play track …, set volume output volume 40).
    - Make a note → run_applescript with Notes.

    PLAYING MUSIC / VIDEO ON YOUTUBE MUSIC (use the loop):
    1. open_url "https://music.youtube.com/search?q=ARTIST" (URL-encode spaces as +).
    2. Wait, then see_screen.
    3. Find the artist's top result or a "Play" / song row in the numbered list, click_element it.
    4. see_screen to confirm something is playing; if not, click the most likely play target and verify again.

    EXAMPLES:
    - "open spotify" → open_app {"name":"Spotify"}
    - "play SZA on youtube music" → open_url music.youtube.com/search?q=SZA, then see_screen, then click the top SZA play target, then see_screen to verify.
    - "set volume to half" → run_applescript {"script":"set volume output volume 50"}
    """

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Cold model loads (7B + 8k ctx) can take well over 30s; a short
        // timeout here made first prompts silently fail.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Streams assistant tokens for the given wire-format conversation.
    /// If the model requests tool calls, they are delivered as a single
    /// `.toolCalls` event once the response finishes.
    func streamChat(messages: [OllamaMessage], model: String, baseURLString: String) -> AsyncThrowingStream<OllamaStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.makeRequest(messages: messages, model: model, baseURLString: baseURLString)

                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await self.session.bytes(for: request)
                    } catch let error as URLError where error.code == .cannotConnectToHost
                        || error.code == .cannotFindHost
                        || error.code == .networkConnectionLost {
                        throw OllamaError.notRunning
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch {
                        throw OllamaError.networkError(error)
                    }

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        // Ollama returns 404 with {"error": "..."} for unknown models.
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        if http.statusCode == 404 || body.lowercased().contains("not found") {
                            throw OllamaError.modelNotFound(model)
                        }
                        throw OllamaError.badResponse(http.statusCode)
                    }

                    var collectedToolCalls: [OllamaToolCall] = []

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
                            continue
                        }
                        if let error = chunk.error {
                            if error.lowercased().contains("not found") {
                                throw OllamaError.modelNotFound(model)
                            }
                            throw OllamaError.serverError(error)
                        }
                        if let calls = chunk.message?.toolCalls, !calls.isEmpty {
                            collectedToolCalls += calls
                        }
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(.token(content))
                        }
                        if chunk.done == true { break }
                    }

                    if !collectedToolCalls.isEmpty {
                        continuation.yield(.toolCalls(collectedToolCalls))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(messages: [OllamaMessage], model: String, baseURLString: String) throws -> URLRequest {
        guard let base = URL(string: baseURLString) else {
            throw OllamaError.networkError(URLError(.badURL))
        }
        let url = base.appendingPathComponent("api/chat")

        let wireMessages = [OllamaMessage(role: ChatRole.system.rawValue, content: Self.agentSystemPrompt)] + messages

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OllamaChatRequest(
                model: model,
                messages: wireMessages,
                stream: true,
                tools: ToolExecutor.tools,
                options: .init(temperature: 0.2, num_ctx: 8192),
                keepAlive: "60m"
            )
        )
        return request
    }

    /// Loads the model into RAM ahead of the first request and pins it for an
    /// hour, so the first prompt of a session isn't stuck behind a 9GB load.
    func warmup() {
        Task.detached(priority: .utility) {
            let defaults = UserDefaults.standard
            let model = defaults.string(forKey: SettingsKeys.modelName) ?? SettingsKeys.defaultModel
            let base = defaults.string(forKey: SettingsKeys.ollamaBaseURL) ?? SettingsKeys.defaultBaseURL
            guard let baseURL = URL(string: base) else { return }
            var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
                "keep_alive": "60m",
            ])
            _ = try? await URLSession.shared.data(for: request)
            NSLog("OllamaService: warmed up \(model)")
        }
    }

    // MARK: - ChatProvider

    func stream(messages: [OllamaMessage]) -> AsyncThrowingStream<OllamaStreamEvent, Error> {
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: SettingsKeys.modelName) ?? SettingsKeys.defaultModel
        let baseURL = defaults.string(forKey: SettingsKeys.ollamaBaseURL) ?? SettingsKeys.defaultBaseURL
        return streamChat(messages: messages, model: model, baseURLString: baseURL)
    }
}
