import Foundation

/// Starts and supervises a local Ollama server so the user never has to run
/// `ollama serve` by hand. Prefers a copy of the `ollama` binary bundled inside
/// the app (Contents/Resources/ollama) so a fresh Mac needs no Homebrew; falls
/// back to any `ollama` already on PATH.
actor OllamaLauncher {
    static let shared = OllamaLauncher()

    /// Retained so the spawned `ollama serve` process isn't torn down when the
    /// launch scope exits.
    private var serverProcess: Process?

    private var baseURLString: String {
        UserDefaults.standard.string(forKey: SettingsKeys.ollamaBaseURL) ?? SettingsKeys.defaultBaseURL
    }

    private var tagsURL: URL? {
        URL(string: baseURLString)?.appendingPathComponent("api/tags")
    }

    // MARK: - Binary discovery

    /// The `ollama` executable: bundled copy first, then the usual install
    /// locations (Homebrew arm64/Intel, manual installs, PATH lookups).
    private func locateBinary() -> URL? {
        if let bundled = Bundle.main.url(forResource: "ollama", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/usr/bin/ollama",
            "\(NSHomeDirectory())/.ollama/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Health

    /// True when the server answers `/api/tags` within a short window.
    func isServerRunning() async -> Bool {
        guard let url = tagsURL else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Ensures a server is reachable, spawning `ollama serve` if needed and
    /// polling until it comes up. Returns false only when there is no binary to
    /// run or the server never became reachable.
    @discardableResult
    func ensureServerRunning() async -> Bool {
        if await isServerRunning() { return true }

        guard let binary = locateBinary() else {
            BLog.log("OllamaLauncher: no ollama binary found (not bundled, not on PATH)")
            return false
        }

        // Don't stack servers if one is already booting.
        if serverProcess?.isRunning != true {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["serve"]
            // Inherit the environment (HOME → ~/.ollama models) and force the
            // host to match the configured base URL.
            var env = ProcessInfo.processInfo.environment
            if let host = URL(string: baseURLString)?.host, let port = URL(string: baseURLString)?.port {
                env["OLLAMA_HOST"] = "\(host):\(port)"
            }
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                serverProcess = process
                BLog.log("OllamaLauncher: launched \(binary.path) serve")
            } catch {
                BLog.log("OllamaLauncher: failed to launch serve — \(error.localizedDescription)")
                return false
            }
        }

        // Poll for readiness — cold boot is typically 1–3s.
        for _ in 0..<40 {
            if await isServerRunning() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        BLog.log("OllamaLauncher: server did not become reachable in time")
        return false
    }

    // MARK: - Models

    /// True when `model` is already present locally.
    func hasModel(_ model: String) async -> Bool {
        guard let url = tagsURL,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return false
        }
        let names = models.compactMap { $0["name"] as? String }
        // Match with or without an explicit :latest tag.
        return names.contains(model)
            || names.contains("\(model):latest")
            || names.contains { $0.hasPrefix("\(model):") }
    }

    /// Pulls `model`, reporting human-readable progress (e.g. "pulling 42%").
    /// Assumes the server is already running. Returns true on success.
    @discardableResult
    func pullModel(_ model: String, progress: @escaping (String) -> Void) async -> Bool {
        guard let base = URL(string: baseURLString) else { return false }
        var request = URLRequest(url: base.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": model, "stream": true])

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let error = obj["error"] as? String {
                    BLog.log("OllamaLauncher: pull error — \(error)")
                    return false
                }
                let status = obj["status"] as? String ?? "downloading"
                if let completed = obj["completed"] as? Double, let total = obj["total"] as? Double, total > 0 {
                    progress("Downloading model \(Int(completed / total * 100))%")
                } else {
                    progress(status)
                }
                if status == "success" { return true }
            }
            return await hasModel(model)
        } catch {
            BLog.log("OllamaLauncher: pull failed — \(error.localizedDescription)")
            return false
        }
    }
}
