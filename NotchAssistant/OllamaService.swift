import Foundation

/// Talks to a local Ollama instance over HTTP using /api/chat with streaming
/// and function calling.
final class OllamaService {

    private let systemPrompt = """
    You are an assistant that CONTROLS the user's Mac with tools: open_app, open_url, run_applescript, run_shell.

    RULES:
    1. When the user asks you to DO anything (open, play, set, create, send, search, close, type, pause, skip...), you MUST call a tool. NEVER reply with instructions. NEVER say you cannot do it.
    2. Chain tools: after each tool result you may call more tools until the task is fully done.
    3. To press keys or click menus, use run_applescript with System Events (keystroke "x", key code 36 for Return).
    4. To play a song/artist/video on YouTube or YouTube Music, use run_shell: open "https://duckduckgo.com/?q=!ducky+ARTIST+SONG+site:youtube.com" — this lands directly on the top video and it plays.
    5. Spotify, Apple Music, and System Events are fully scriptable: tell application "Spotify" to play, set volume output volume 40, etc.
    6. Only answer in plain text for pure knowledge questions. After completing a task, confirm in ONE short sentence.

    EXAMPLES:
    - "open spotify" → open_app {"name": "Spotify"}
    - "play drake on youtube music" → run_shell {"command": "open 'https://duckduckgo.com/?q=!ducky+drake+site:youtube.com'"}
    - "set volume to half" → run_applescript {"script": "set volume output volume 50"}
    - "make a note saying buy milk" → run_applescript {"script": "tell application \\"Notes\\" to make new note with properties {body:\\"buy milk\\"}"}
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

        let wireMessages = [OllamaMessage(role: ChatRole.system.rawValue, content: systemPrompt)] + messages

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OllamaChatRequest(
                model: model,
                messages: wireMessages,
                stream: true,
                tools: ToolExecutor.tools,
                options: .init(temperature: 0.2, num_ctx: 8192)
            )
        )
        return request
    }
}
