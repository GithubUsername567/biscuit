import Foundation

/// Tries a primary brain (e.g. Gemini) and silently falls back to a secondary
/// (local Ollama) if the primary fails before producing anything — so a
/// Gemini quota/network error doesn't dead-end; the local model takes over.
struct FallbackChatProvider: ChatProvider {
    let primary: ChatProvider
    let secondary: ChatProvider

    func stream(messages: [OllamaMessage]) -> AsyncThrowingStream<OllamaStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var emitted = false
                do {
                    for try await event in primary.stream(messages: messages) {
                        emitted = true
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    // Only fall back if the primary produced nothing yet;
                    // mid-stream failures can't be cleanly restarted.
                    guard !emitted else {
                        continuation.finish(throwing: error)
                        return
                    }
                    NSLog("Primary brain failed (\(error.localizedDescription)) — falling back to local model")
                    do {
                        for try await event in secondary.stream(messages: messages) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Cloud "brain": Gemini with function calling, used in Capable mode.
/// Mirrors OllamaService by emitting the same OllamaStreamEvent values so the
/// agent loop in AppState is identical regardless of backend.
final class GeminiService: ChatProvider {

    private let systemPrompt: String

    init(systemPrompt: String) {
        self.systemPrompt = systemPrompt
    }

    func stream(messages: [OllamaMessage]) -> AsyncThrowingStream<OllamaStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let defaults = UserDefaults.standard
                    let key = defaults.string(forKey: SettingsKeys.geminiAPIKey) ?? ""
                    guard !key.isEmpty else {
                        throw OllamaError.serverError("Capable mode needs a Gemini API key (Settings).")
                    }
                    let model = defaults.string(forKey: SettingsKeys.geminiPlannerModel)
                        .flatMap { $0.isEmpty ? nil : $0 } ?? SettingsKeys.defaultPlannerModel

                    let request = try self.makeRequest(messages: messages, model: model, apiKey: key)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw OllamaError.serverError("Gemini HTTP \(http.statusCode): \(body.prefix(200))")
                    }

                    var toolCalls: [OllamaToolCall] = []
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
                            continue
                        }
                        for part in parts {
                            if let text = part["text"] as? String, !text.isEmpty {
                                continuation.yield(.token(text))
                            }
                            if let call = part["functionCall"] as? [String: Any],
                               let name = call["name"] as? String {
                                let argsObject = call["args"] as? [String: Any] ?? [:]
                                toolCalls.append(Self.toolCall(name: name, args: argsObject))
                            }
                        }
                    }

                    if !toolCalls.isEmpty {
                        continuation.yield(.toolCalls(toolCalls))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request building

    private func makeRequest(messages: [OllamaMessage], model: String, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)") else {
            throw OllamaError.networkError(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": Self.contents(from: messages),
            "tools": [["function_declarations": Self.functionDeclarations()]],
            "generationConfig": ["temperature": 0.2],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Maps our wire messages to Gemini's content list. System messages are
    /// handled via system_instruction and skipped here.
    private static func contents(from messages: [OllamaMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case "system":
                continue
            case "user":
                out.append(["role": "user", "parts": [["text": message.content]]])
            case "assistant":
                var parts: [[String: Any]] = []
                if !message.content.isEmpty { parts.append(["text": message.content]) }
                for call in message.toolCalls ?? [] {
                    parts.append(["functionCall": [
                        "name": call.function.name,
                        "args": jsonObject(call.argumentsDictionary),
                    ]])
                }
                if parts.isEmpty { parts = [["text": ""]] }
                out.append(["role": "model", "parts": parts])
            case "tool":
                out.append(["role": "user", "parts": [[
                    "functionResponse": [
                        "name": message.name ?? "tool",
                        "response": ["result": message.content],
                    ],
                ]]])
            default:
                continue
            }
        }
        return out
    }

    private static func functionDeclarations() -> [[String: Any]] {
        ToolExecutor.tools.map { tool in
            [
                "name": tool.function.name,
                "description": tool.function.description,
                "parameters": jsonValueToAny(tool.function.parameters),
            ]
        }
    }

    // MARK: - JSONValue <-> Foundation bridging

    private static func toolCall(name: String, args: [String: Any]) -> OllamaToolCall {
        let converted = args.mapValues { anyToJSONValue($0) }
        return OllamaToolCall(function: .init(name: name, arguments: .object(converted)))
    }

    private static func jsonObject(_ dict: [String: JSONValue]) -> [String: Any] {
        dict.mapValues { jsonValueToAny($0) }
    }

    private static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map { jsonValueToAny($0) }
        case .object(let o): return o.mapValues { jsonValueToAny($0) }
        }
    }

    private static func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let n as NSNumber:
            // NSNumber bridges bools too; the Bool case above catches those.
            return .number(n.doubleValue)
        case let a as [Any]: return .array(a.map { anyToJSONValue($0) })
        case let o as [String: Any]: return .object(o.mapValues { anyToJSONValue($0) })
        default: return .null
        }
    }
}
