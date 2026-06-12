import Foundation

/// No-key web search via DuckDuckGo's HTML endpoint. Returns the top result
/// titles + snippets as plain text for the model to answer from.
enum WebSearchService {

    static func search(_ query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Error: empty search query." }

        guard let url = URL(string: "https://html.duckduckgo.com/html/") else {
            return "Error: bad search URL."
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
        request.httpBody = "q=\(encoded)".data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = String(data: data, encoding: .utf8) else {
                return "Web search failed (couldn't reach DuckDuckGo)."
            }
            let results = parse(body)
            guard !results.isEmpty else {
                return "No web results found for \"\(trimmed)\"."
            }
            let lines = results.prefix(5).enumerated().map { index, result in
                "\(index + 1). \(result.title)\n   \(result.snippet)"
            }
            return "Web results for \"\(trimmed)\":\n" + lines.joined(separator: "\n")
        } catch {
            return "Web search error: \(error.localizedDescription)"
        }
    }

    private struct Result { let title: String; let snippet: String }

    private static func parse(_ htmlBody: String) -> [Result] {
        let titles = matches(in: htmlBody, pattern: "class=\"result__a\"[^>]*>(.*?)</a>")
        let snippets = matches(in: htmlBody, pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>")
        var out: [Result] = []
        for index in 0..<max(titles.count, snippets.count) {
            let title = index < titles.count ? strip(titles[index]) : ""
            let snippet = index < snippets.count ? strip(snippets[index]) : ""
            if !title.isEmpty || !snippet.isEmpty {
                out.append(Result(title: title, snippet: String(snippet.prefix(300))))
            }
        }
        return out
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Strip HTML tags and decode the few entities DuckDuckGo emits.
    private static func strip(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#x27;": "'", "&#39;": "'", "&nbsp;": " ", "&#x2F;": "/"]
        for (entity, char) in entities {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
