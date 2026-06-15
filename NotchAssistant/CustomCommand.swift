import Foundation

/// A user-taught shortcut: a trigger phrase that expands into one or more
/// ordinary commands. Steps that are recipe-able (open an app, set volume,
/// open a site) run with no model call; if a step needs reasoning the whole
/// command is handed to the model as a single instruction.
struct CustomCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var phrase: String
    var steps: [String]
    /// When true the whole utterance must equal the phrase; otherwise the
    /// phrase need only appear (word-bounded) in what the user said.
    var exactMatch: Bool = false
    /// Set by "watch me do it" capture: the literal tool calls a successful
    /// run executed. When present these replay directly (token-free) and
    /// `steps` is just the human-readable description.
    var capturedCalls: [OllamaToolCall]? = nil

    static func == (lhs: CustomCommand, rhs: CustomCommand) -> Bool { lhs.id == rhs.id }

    var stepsText: String {
        get { steps.joined(separator: "\n") }
        set {
            steps = newValue
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}

/// Persistence + matching for user-taught commands. Stored as JSON in
/// UserDefaults so it rides the same migration/backup path as other settings.
enum CustomCommandStore {

    static func all() -> [CustomCommand] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.customCommands),
              let list = try? JSONDecoder().decode([CustomCommand].self, from: data) else {
            return []
        }
        return list
    }

    static func save(_ commands: [CustomCommand]) {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: SettingsKeys.customCommands)
        }
    }

    static func add(_ command: CustomCommand) {
        var list = all()
        list.append(command)
        save(list)
    }

    /// The first command whose trigger matches the request. Longer phrases win
    /// so a specific "work mode away" beats a generic "work mode".
    static func match(_ raw: String) -> CustomCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        return all()
            .filter { !$0.phrase.isEmpty && !$0.steps.isEmpty }
            .sorted { $0.phrase.count > $1.phrase.count }
            .first { matches(text, $0) }
    }

    private static func matches(_ text: String, _ command: CustomCommand) -> Bool {
        let phrase = command.phrase.trimmingCharacters(in: .whitespaces).lowercased()
        guard !phrase.isEmpty else { return false }
        if command.exactMatch {
            return text == phrase
        }
        // Word-bounded contains, so "nap" doesn't fire inside "napkin".
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "\\b\(escaped)\\b"
        return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Teaching by voice

    /// Parses "when I say X, do Y" style requests into a new command.
    /// Returns nil if the request isn't a teach instruction.
    static func parseTeachRequest(_ raw: String) -> CustomCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // "when I say <trigger>, <actions>"  /  "...<trigger> do <actions>"
        let patterns = [
            #"(?i)^\s*(?:when|whenever)\s+i\s+say\s+(.+?)\s*[,:]\s*(.+)$"#,
            #"(?i)^\s*(?:when|whenever)\s+i\s+say\s+(.+?)\s+(?:do|run)\s+(.+)$"#,
            #"(?i)^\s*(?:teach|learn|make|create)\s+(?:a\s+)?(?:shortcut|command|recipe)\s+(?:called\s+|named\s+)?(.+?)\s*[,:]?\s*(?:that\s+)?(?:does|to|=)\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 2,
                  let tr = Range(m.range(at: 1), in: text),
                  let ar = Range(m.range(at: 2), in: text) else { continue }
            let trigger = cleanTrigger(String(text[tr]))
            let steps = splitSteps(String(text[ar]))
            guard !trigger.isEmpty, !steps.isEmpty else { continue }
            return CustomCommand(phrase: trigger, steps: steps)
        }
        return nil
    }

    // MARK: - "Watch me do it" capture

    /// Tool calls whose effect is the same on replay. Perception calls
    /// (see_screen, look_closely) and session-specific clicks (click_element,
    /// click_at) are excluded — their result depends on the live screen.
    static let replayableTools: Set<String> = [
        "open_app", "open_url", "run_applescript", "run_shell",
        "set_reminder", "type_text", "press_key", "write_clipboard",
    ]

    /// Parses "save that [as <name>]" / "remember that [as <name>]".
    /// Returns (name?) when it's a save request, else nil.
    static func parseSaveRequest(_ raw: String) -> (matched: Bool, name: String?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)^\s*(?:save|remember|keep)\s+(?:that|this|it)(?:\s+as\s+(?:a\s+)?(?:shortcut\s+)?(?:called\s+|named\s+)?(.+))?\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        var name: String?
        if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) {
            let n = cleanTrigger(String(text[r]))
            name = n.isEmpty ? nil : n
        }
        return (true, name)
    }

    private static func cleanTrigger(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”.,"))
    }

    /// Splits a multi-action instruction into steps on explicit separators
    /// only — leaving "open slack and discord" as one step the model resolves,
    /// rather than guessing that "discord" is its own command.
    static func splitSteps(_ s: String) -> [String] {
        s.replacingOccurrences(of: " and then ", with: ";")
            .replacingOccurrences(of: ", then ", with: ";")
            .replacingOccurrences(of: " then ", with: ";")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .,")) }
            .filter { !$0.isEmpty }
    }
}
