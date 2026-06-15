import Foundation

/// Fast paths for common, fully-deterministic commands.
///
/// A recipe recognizes a request by pattern and emits a fixed tool sequence
/// plus a templated confirmation — so volume changes, app launches, timers,
/// and "go to <site>" run with **no LLM round-trip at all**. That's the whole
/// planning loop (system prompt + tool schemas + several streamed rounds)
/// skipped on the commands you say most often.
///
/// Safety: matching is deliberately conservative. Anything ambiguous returns
/// nil and falls through to the model. If a recipe's tool errors mid-run,
/// AppState hands the original request back to the model. A recipe firing
/// wrongly is the cost to avoid, not a missed token saving — so when in doubt,
/// these decline.
struct RecipeMatch {
    let name: String
    let calls: [OllamaToolCall]
    /// Builds the spoken confirmation from the last tool's result. Many
    /// recipes ignore the result and return a fixed sentence.
    let confirm: (String) -> String
}

enum RecipeBook {

    static func match(_ raw: String) -> RecipeMatch? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        // Order matters: a URL ("open spotify.com") must beat the app launcher
        // ("open spotify"), and explicit volume must beat the bare app rule.
        return matchMute(text)
            ?? matchVolume(text)
            ?? matchTimer(text)
            ?? matchOpenURL(text)
            ?? matchOpenApp(text)
    }

    // MARK: - Volume

    private static func matchMute(_ text: String) -> RecipeMatch? {
        guard has(text, #"^\s*(mute|silence|be quiet)\b"#) else { return nil }
        return RecipeMatch(name: "mute", calls: [applescript("set volume output muted true")]) { _ in
            "Muted."
        }
    }

    private static func matchVolume(_ text: String) -> RecipeMatch? {
        guard text.contains("volume") else { return nil }

        // Named levels first.
        if has(text, #"\b(max|maximum|full|all the way up)\b"#) {
            return volumeRecipe(100)
        }
        if has(text, #"\bhalf\b"#) {
            return volumeRecipe(50)
        }
        // "(set) volume (to/at) <number-or-word>"
        if let m = firstGroup(text, #"\bvolume\s+(?:to\s+|at\s+|=\s*)?([a-z0-9 ]{1,12}?)\b(?:\s+percent)?\s*$"#)
            ?? firstGroup(text, #"\bvolume\s+(?:to\s+|at\s+|=\s*)?([a-z0-9]{1,9})\b"#),
           let level = parseLevel(m) {
            return volumeRecipe(level)
        }
        return nil
    }

    private static func volumeRecipe(_ level: Int) -> RecipeMatch {
        let n = min(max(level, 0), 100)
        // Unmute too, or "volume 50" after a mute does nothing audible.
        return RecipeMatch(name: "volume", calls: [
            applescript("set volume output muted false\nset volume output volume \(n)")
        ]) { _ in "Volume set to \(n)." }
    }

    // MARK: - Timer / reminder

    private static func matchTimer(_ text: String) -> RecipeMatch? {
        guard has(text, #"\b(set (a |an )?(timer|alarm|reminder)|remind me)\b"#) else { return nil }
        guard let (amount, unit) = firstTwoGroups(
            text, #"\b([0-9]+|[a-z ]{1,18}?)\s*(seconds?|minutes?|hours?|secs?|mins?|hrs?)\b"#),
              let value = parseLevel(amount), value > 0 else { return nil }

        let minutes: Double
        switch unit.first {
        case "s": minutes = Double(value) / 60.0
        case "h": minutes = Double(value) * 60.0
        default:  minutes = Double(value)
        }

        // "remind me to <thing>" → use <thing> as the body; otherwise a timer.
        let body = firstGroup(text, #"remind me to\s+(.+?)(?:\s+in\b|\s+after\b|$)"#)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Timer done"

        let humanWhen = unit.first == "s" ? "\(value) seconds"
            : unit.first == "h" ? "\(value) hour\(value == 1 ? "" : "s")"
            : "\(value) minute\(value == 1 ? "" : "s")"

        return RecipeMatch(name: "timer", calls: [
            tool("set_reminder", ["text": .string(body), "minutes": .number(minutes)])
        ]) { result in
            result.hasPrefix("Error") ? result : "Okay, I'll remind you in \(humanWhen)."
        }
    }

    // MARK: - Open URL

    private static func matchOpenURL(_ text: String) -> RecipeMatch? {
        guard let host = firstGroup(
            text,
            #"^\s*(?:open|go to|goto|navigate to|visit|launch)\s+(?:the\s+)?(?:https?://)?([a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/\S*)?)\s*$"#
        ) else { return nil }
        // Must have a real TLD-ish tail, not "open my notes".
        guard host.contains(".") else { return nil }
        let url = "https://\(host)"
        return RecipeMatch(name: "open_url", calls: [
            tool("open_url", ["url": .string(url)])
        ]) { result in result.hasPrefix("Error") ? result : "Opened \(host)." }
    }

    // MARK: - Open app

    private static func matchOpenApp(_ text: String) -> RecipeMatch? {
        // Whole utterance must be just "open <name>" — no "and", "then",
        // "play", "in", "on", which signal a multi-step task for the model.
        guard let name = firstGroup(
            text,
            #"^\s*(?:open|launch|start|fire up)\s+(?:the\s+)?([a-z0-9 .&'+-]{2,32}?)(?:\s+app)?\s*$"#
        ) else { return nil }
        // Connective words (padded) signal a multi-step task; content words
        // (bare) signal a different intent rode in on "open".
        let padded = " \(name) "
        let banned = [" and ", " then ", " in ", " on ", "play", "search", "http", "tab", "window", "settings"]
        guard !banned.contains(where: { padded.contains($0) }) else { return nil }
        // Title-case-ish the captured name for `open -a`; macOS match is
        // case-insensitive anyway, so pass it through as spoken.
        return RecipeMatch(name: "open_app", calls: [
            tool("open_app", ["name": .string(name)])
        ]) { result in result }  // tool already says "Opened X." or an error
    }

    // MARK: - Builders

    private static func tool(_ name: String, _ args: [String: JSONValue]) -> OllamaToolCall {
        OllamaToolCall(function: .init(name: name, arguments: .object(args)))
    }

    private static func applescript(_ source: String) -> OllamaToolCall {
        tool("run_applescript", ["script": .string(source)])
    }

    // MARK: - Parsing helpers

    /// Digits or a small set of spoken numbers → Int. nil if unrecognized.
    private static func parseLevel(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(s) { return n }
        let ones = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                    "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
                    "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                    "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
                    "a hundred": 100, "one hundred": 100]
        if let n = ones[s] { return n }
        // "twenty five", "forty five", etc.
        let parts = s.split(separator: " ").map(String.init)
        if parts.count == 2, let tens = ones[parts[0]], let unit = ones[parts[1]],
           tens % 10 == 0, tens >= 20, unit < 10 {
            return tens + unit
        }
        return nil
    }

    /// Case-insensitive regex test.
    private static func has(_ text: String, _ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func firstGroup(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func firstTwoGroups(_ text: String, _ pattern: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 2,
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text) else { return nil }
        return (String(text[r1]), String(text[r2]))
    }
}
