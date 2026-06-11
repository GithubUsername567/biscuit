import Foundation
import AppKit
import ServiceManagement

// MARK: - Assistant state machine

enum AssistantState: Equatable {
    case idle
    case listening
    case processing
    case responding
    case error(String)
}

// MARK: - Conversation

enum ChatRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ChatRole
    var content: String

    init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Loose JSON value (tool-call arguments and schemas)

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var displayString: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return String(value)
        case .null: return "null"
        case .object, .array:
            return (try? JSONEncoder().encode(self))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "…"
        }
    }
}

// MARK: - Ollama /api/chat wire types

struct OllamaChatRequest: Encodable {
    struct Options: Encodable {
        let temperature: Double
        let num_ctx: Int
    }

    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let tools: [OllamaTool]?
    // Low temperature for reliable tool selection; 8k context so the system
    // prompt and tool schemas never get truncated away (Ollama default 2k did).
    let options: Options?
}

struct OllamaMessage: Codable {
    let role: String
    let content: String
    var toolCalls: [OllamaToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }

    init(role: String, content: String, toolCalls: [OllamaToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolCalls = try container.decodeIfPresent([OllamaToolCall].self, forKey: .toolCalls)
    }
}

struct OllamaToolCall: Codable {
    struct FunctionCall: Codable {
        let name: String
        let arguments: JSONValue?
    }
    let function: FunctionCall

    /// Ollama sends arguments as a JSON object; some models emit a JSON string instead.
    var argumentsDictionary: [String: JSONValue] {
        if case .object(let dict)? = function.arguments { return dict }
        if case .string(let raw)? = function.arguments,
           let data = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(let dict) = parsed {
            return dict
        }
        return [:]
    }

    var compactArguments: String {
        argumentsDictionary
            .map { "\($0.key): \($0.value.displayString.prefix(80))" }
            .sorted()
            .joined(separator: ", ")
    }
}

struct OllamaTool: Encodable {
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
    }
    let type = "function"
    let function: Function
}

struct OllamaChatResponse: Decodable {
    let message: OllamaMessage?
    let done: Bool?
    let error: String?
}

enum OllamaStreamEvent {
    case token(String)
    case toolCalls([OllamaToolCall])
}

enum OllamaError: LocalizedError {
    case notRunning
    case modelNotFound(String)
    case networkError(Error)
    case serverError(String)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Ollama isn't running — start it with: ollama serve"
        case .modelNotFound(let model):
            return "Model \"\(model)\" not found — pull it with: ollama pull \(model)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let message):
            return "Ollama error: \(message)"
        case .badResponse(let code):
            return "Ollama returned an unexpected response (HTTP \(code))."
        }
    }
}

// MARK: - Settings

enum SettingsKeys {
    static let ollamaBaseURL = "ollamaBaseURL"
    static let modelName = "modelName"
    static let ttsEnabled = "ttsEnabled"
    static let ttsVoiceIdentifier = "ttsVoiceIdentifier"
    static let elevenLabsAPIKey = "elevenLabsAPIKey"
    static let elevenLabsVoiceID = "elevenLabsVoiceID"
    static let geminiAPIKey = "geminiAPIKey"
    static let geminiVoiceName = "geminiVoiceName"
    static let ttsEngine = "ttsEngine"
    static let edgeVoiceName = "edgeVoiceName"
    static let showCompanion = "showCompanion"
    static let launchAtLogin = "launchAtLogin"

    static let defaultBaseURL = "http://localhost:11434"
    static let defaultModel = "qwen2.5:7b"
}

// MARK: - Mac action execution

enum ToolExecutor {

    /// Click targets from the most recent `see_screen`, keyed by the [number]
    /// shown to the model.
    @MainActor private static var lastTargets: [Int: PerceptionService.Target] = [:]

    static var tools: [OllamaTool] {
        [
            OllamaTool(function: .init(
                name: "see_screen",
                description: "Look at what is currently on screen. Returns a numbered list of buttons, links, text fields, and rows in the frontmost app. Call this FIRST whenever a task needs interacting with an app's interface, and call it again after any action to verify the result before continuing.",
                parameters: schema(properties: [:], required: [])
            )),
            OllamaTool(function: .init(
                name: "click_element",
                description: "Click an element by the [number] from the most recent see_screen result. Use this to press buttons, follow links, focus text fields, or pick a row.",
                parameters: schema(
                    properties: ["number": property(type: "integer", description: "The element number from see_screen.")],
                    required: ["number"]
                )
            )),
            OllamaTool(function: .init(
                name: "type_text",
                description: "Type text into whatever is currently focused (click a text field first). Set submit=true to press Return after typing, e.g. to run a search.",
                parameters: schema(
                    properties: [
                        "text": property(description: "The text to type."),
                        "submit": property(type: "boolean", description: "Press Return after typing. Default false."),
                    ],
                    required: ["text"]
                )
            )),
            OllamaTool(function: .init(
                name: "press_key",
                description: "Press a single key or shortcut. key is one of: return, tab, escape, space, delete, up, down, left, right, or a letter. Optional modifiers: cmd, shift, option, control.",
                parameters: schema(
                    properties: [
                        "key": property(description: "Key name or single letter."),
                        "modifiers": property(description: "Space-separated modifiers, e.g. 'cmd shift'. Optional."),
                    ],
                    required: ["key"]
                )
            )),
            OllamaTool(function: .init(
                name: "open_app",
                description: "Launch or bring to front a macOS application by name, e.g. Safari, Notes, Spotify, Terminal.",
                parameters: schema(
                    properties: ["name": property(description: "The application name as it appears in /Applications.")],
                    required: ["name"]
                )
            )),
            OllamaTool(function: .init(
                name: "open_url",
                description: "Open a web URL in the user's default browser.",
                parameters: schema(
                    properties: ["url": property(description: "Full http or https URL to open.")],
                    required: ["url"]
                )
            )),
            OllamaTool(function: .init(
                name: "run_applescript",
                description: "Run an AppleScript on this Mac to actually perform an action: control apps, set system volume, create notes or reminders, send messages, press keys via System Events, manipulate windows, and anything else AppleScript can do.",
                parameters: schema(
                    properties: ["script": property(description: "The complete AppleScript source to execute.")],
                    required: ["script"]
                )
            )),
            OllamaTool(function: .init(
                name: "run_shell",
                description: "Run a zsh shell command on this Mac and return its output. Use for anything a terminal can do: open URLs or files, search, curl, list files, manage processes.",
                parameters: schema(
                    properties: ["command": property(description: "The shell command to run.")],
                    required: ["command"]
                )
            )),
        ]
    }

    /// Executes a model-requested tool call and returns a textual result that
    /// gets fed back to the model. Runs subprocesses off the main thread so
    /// the UI never blocks, even for scripts containing delays.
    static func execute(_ call: OllamaToolCall) async -> String {
        let args = call.argumentsDictionary
        switch call.function.name {

        case "see_screen":
            return await MainActor.run {
                let snap = PerceptionService.snapshot()
                lastTargets = snap.targets
                return snap.text
            }

        case "click_element":
            guard let number = intArg(args["number"]) else { return "Error: missing element number." }
            let target = await MainActor.run { lastTargets[number] }
            guard let target else {
                return "Error: no element [\(number)] — call see_screen again first."
            }
            if target.isPromo {
                return "Refused: [\(number)] (\"\(target.label)\") is an install/sign-in/cookie promo, not the task target. Pick a song row, an artist result, or a Play button instead."
            }
            await InputSynthesizer.click(at: target.point)
            try? await Task.sleep(for: .milliseconds(600))
            return "Clicked element [\(number)]. Call see_screen to verify the result."

        case "type_text":
            guard let text = args["text"]?.stringValue, !text.isEmpty else { return "Error: missing text." }
            let submit = boolArg(args["submit"])
            await InputSynthesizer.type(text)
            if submit {
                try? await Task.sleep(for: .milliseconds(150))
                await InputSynthesizer.pressKey(keyCode: 36, modifiers: []) // Return
            }
            try? await Task.sleep(for: .milliseconds(600))
            return submit ? "Typed and submitted. Call see_screen to verify." : "Typed the text."

        case "press_key":
            guard let key = args["key"]?.stringValue, !key.isEmpty else { return "Error: missing key." }
            guard let code = InputSynthesizer.keyCode(for: key) else { return "Error: unknown key \"\(key)\"." }
            let mods = InputSynthesizer.modifiers(from: args["modifiers"]?.stringValue ?? "")
            await InputSynthesizer.pressKey(keyCode: code, modifiers: mods)
            try? await Task.sleep(for: .milliseconds(400))
            return "Pressed \(key)."

        case "open_app":
            guard let name = args["name"]?.stringValue, !name.isEmpty else {
                return "Error: missing app name."
            }
            let result = await runProcess("/usr/bin/open", ["-a", name], timeout: 15)
            return result.hasPrefix("Error") ? "Error: no application named \"\(name)\" found." : "Opened \(name)."

        case "open_url":
            guard let raw = args["url"]?.stringValue,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return "Error: invalid or non-web URL."
            }
            _ = await runProcess("/usr/bin/open", [url.absoluteString], timeout: 15)
            return "Opened \(raw) in the default browser."

        case "run_applescript":
            guard let source = args["script"]?.stringValue, !source.isEmpty else {
                return "Error: missing script."
            }
            return await runProcess("/usr/bin/osascript", ["-e", source], timeout: 60)

        case "run_shell":
            guard let command = args["command"]?.stringValue, !command.isEmpty else {
                return "Error: missing command."
            }
            return await runProcess("/bin/zsh", ["-lc", command], timeout: 30)

        default:
            return "Error: unknown tool \"\(call.function.name)\"."
        }
    }

    private static func runProcess(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "Error: \(error.localizedDescription)")
                    return
                }

                let killTimer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killTimer)

                // Read to EOF before waiting so a full pipe can't deadlock the child.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killTimer.cancel()

                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let truncated = String(output.prefix(2000))
                if process.terminationStatus == 0 {
                    continuation.resume(returning: truncated.isEmpty ? "Done." : truncated)
                } else {
                    continuation.resume(returning: "Error (exit \(process.terminationStatus)): \(truncated.isEmpty ? "no output" : truncated)")
                }
            }
        }
    }

    private static func intArg(_ value: JSONValue?) -> Int? {
        switch value {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private static func boolArg(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let b): return b
        case .string(let s): return s.lowercased() == "true"
        case .number(let n): return n != 0
        default: return false
        }
    }

    private static func schema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    private static func property(type: String = "string", description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }
}

// MARK: - Stubs (intentionally not integrated in this build)

enum WhisperKitTranscriber {
    // TODO: Integrate WhisperKit for higher-quality offline transcription.
    static func transcribe(audioURL: URL) -> String {
        NSLog("WhisperKit not integrated")
        return ""
    }
}

enum ScreenContextProvider {
    // TODO: Integrate ScreenCaptureKit to capture on-screen context for prompts.
    static func captureContext() -> String? {
        NSLog("ScreenCaptureKit not integrated")
        return nil
    }
}

enum LaunchAtLogin {
    static func set(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin: \(error.localizedDescription)")
        }
    }
}
