import AVFoundation
import CryptoKit

/// Speaks assistant replies. Engine is chosen in Settings:
/// Edge (free, no key, default) / Gemini / ElevenLabs / System.
/// Every network engine falls back gracefully on failure.
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {

    static let defaultElevenLabsVoiceID = "21m00Tcm4TlvDq8ikWAM" // Rachel
    static let defaultGeminiVoice = "Kore"
    static let defaultEdgeVoice = "en-US-AndrewNeural"

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var fetchTask: Task<Void, Never>?

    /// Called on the main queue whenever speech finishes or is cancelled.
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking || (player?.isPlaying ?? false) }

    func speak(_ text: String) {
        stop()
        let plain = plainText(from: text)
        guard !plain.isEmpty else {
            DispatchQueue.main.async { self.onFinish?() }
            return
        }

        let defaults = UserDefaults.standard
        let engine = defaults.string(forKey: SettingsKeys.ttsEngine) ?? "edge"
        let geminiKey = defaults.string(forKey: SettingsKeys.geminiAPIKey) ?? ""
        let elevenKey = defaults.string(forKey: SettingsKeys.elevenLabsAPIKey) ?? ""

        switch engine {
        case "gemini" where !geminiKey.isEmpty:
            let voice = defaults.string(forKey: SettingsKeys.geminiVoiceName).flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.defaultGeminiVoice
            speakWithGemini(plain, apiKey: geminiKey, voiceName: voice)
        case "elevenlabs" where !elevenKey.isEmpty:
            let voiceID = defaults.string(forKey: SettingsKeys.elevenLabsVoiceID).flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.defaultElevenLabsVoiceID
            speakWithElevenLabs(plain, apiKey: elevenKey, voiceID: voiceID)
        case "system":
            speakWithSystem(plain)
        default:
            let voice = defaults.string(forKey: SettingsKeys.edgeVoiceName).flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.defaultEdgeVoice
            speakWithEdge(plain, voice: voice)
        }
    }

    // MARK: - Edge TTS (Microsoft neural voices — free, no API key)

    private func speakWithEdge(_ text: String, voice: String) {
        fetchTask = Task { [weak self] in
            do {
                let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
                // Sec-MS-GEC: SHA256 of Windows file-time ticks (floored to 5
                // minutes) + token, uppercase hex.
                var ticks = UInt64((Date().timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
                ticks -= ticks % 3_000_000_000
                let gec = SHA256.hash(data: Data("\(ticks)\(token)".utf8))
                    .map { String(format: "%02X", $0) }.joined()
                let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

                // Sec-MS-GEC-Version must match a current Edge build or the
                // handshake is rejected with HTTP 403. Keep in sync with the
                // edge-tts project if Microsoft tightens validation again.
                let gecVersion = "1-143.0.3650.75"
                guard let url = URL(string:
                    "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1" +
                    "?TrustedClientToken=\(token)&Sec-MS-GEC=\(gec)&Sec-MS-GEC-Version=\(gecVersion)&ConnectionId=\(connectionID)"
                ) else { throw URLError(.badURL) }

                var request = URLRequest(url: url)
                request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
                request.setValue(
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
                    forHTTPHeaderField: "User-Agent"
                )

                let socket = URLSession.shared.webSocketTask(with: request)
                socket.resume()
                defer { socket.cancel(with: .goingAway, reason: nil) }

                let config = "X-Timestamp:\(Date())\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
                    + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
                try await socket.send(.string(config))

                let escaped = text
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
                    + "<voice name='\(voice)'>\(escaped)</voice></speak>"
                try await socket.send(.string(
                    "X-RequestId:\(connectionID)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(Date())\r\nPath:ssml\r\n\r\n\(ssml)"
                ))

                var audio = Data()
                receiving: while true {
                    try Task.checkCancellation()
                    switch try await socket.receive() {
                    case .string(let message):
                        if message.contains("Path:turn.end") { break receiving }
                    case .data(let chunk):
                        // Binary frame: [2-byte BE header length][header][mp3 bytes]
                        guard chunk.count > 2 else { continue }
                        let headerLength = Int(chunk[0]) << 8 | Int(chunk[1])
                        guard chunk.count > 2 + headerLength else { continue }
                        let header = String(data: chunk.subdata(in: 2..<(2 + headerLength)), encoding: .utf8) ?? ""
                        if header.contains("Path:audio") {
                            audio.append(chunk.subdata(in: (2 + headerLength)..<chunk.count))
                        }
                    @unknown default:
                        break
                    }
                }

                guard !audio.isEmpty else { throw URLError(.cannotParseResponse) }
                try Task.checkCancellation()
                await MainActor.run { self?.play(audio, fallbackText: text) }
            } catch is CancellationError {
            } catch {
                NSLog("Edge TTS failed (\(error.localizedDescription)) — falling back")
                guard !Task.isCancelled, let self else { return }
                let geminiKey = UserDefaults.standard.string(forKey: SettingsKeys.geminiAPIKey) ?? ""
                if geminiKey.isEmpty {
                    await MainActor.run { self.speakWithSystem(text) }
                } else {
                    let voice = UserDefaults.standard.string(forKey: SettingsKeys.geminiVoiceName)
                        .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultGeminiVoice
                    self.speakWithGemini(text, apiKey: geminiKey, voiceName: voice)
                }
            }
        }
    }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        if let player, player.isPlaying {
            player.stop()
        }
        player = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Gemini TTS (free tier via AI Studio key)

    private func speakWithGemini(_ text: String, apiKey: String, voiceName: String) {
        fetchTask = Task { [weak self] in
            do {
                guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent?key=\(apiKey)") else {
                    throw URLError(.badURL)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "contents": [["parts": [["text": text]]]],
                    "generationConfig": [
                        "responseModalities": ["AUDIO"],
                        "speechConfig": [
                            "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]],
                        ],
                    ],
                ])

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw NSError(domain: "GeminiTTS", code: code, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP \(code): \(String(data: data.prefix(300), encoding: .utf8) ?? "")",
                    ])
                }

                // Audio may be split across several parts — concatenate them
                // all; playing only the first sounds chopped/glitchy.
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else {
                    throw URLError(.cannotParseResponse)
                }

                var pcm = Data()
                var mime = ""
                for part in parts {
                    guard let inline = part["inlineData"] as? [String: Any],
                          let base64 = inline["data"] as? String,
                          let chunk = Data(base64Encoded: base64) else { continue }
                    pcm.append(chunk)
                    if mime.isEmpty { mime = inline["mimeType"] as? String ?? "" }
                }
                guard !pcm.isEmpty else { throw URLError(.cannotParseResponse) }

                let rate = Self.sampleRate(fromMime: mime)
                let wav = Self.wavData(fromPCM: pcm, sampleRate: rate)

                try Task.checkCancellation()
                await MainActor.run { self?.play(wav, fallbackText: text) }
            } catch is CancellationError {
            } catch {
                NSLog("Gemini TTS failed (\(error.localizedDescription)) — falling back to system voice")
                guard !Task.isCancelled, let self else { return }
                await MainActor.run { self.speakWithSystem(text) }
            }
        }
    }

    /// Gemini returns raw 16-bit mono PCM, e.g. "audio/L16;codec=pcm;rate=24000".
    private static func sampleRate(fromMime mime: String) -> Int {
        guard let range = mime.range(of: "rate=") else { return 24000 }
        let digits = mime[range.upperBound...].prefix(while: \.isNumber)
        return Int(digits) ?? 24000
    }

    private static func wavData(fromPCM pcm: Data, sampleRate: Int) -> Data {
        var header = Data()
        func ascii(_ string: String) { header.append(string.data(using: .ascii)!) }
        func u32(_ value: UInt32) { var v = value.littleEndian; header.append(Data(bytes: &v, count: 4)) }
        func u16(_ value: UInt16) { var v = value.littleEndian; header.append(Data(bytes: &v, count: 2)) }

        ascii("RIFF"); u32(UInt32(36 + pcm.count)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count))
        return header + pcm
    }

    // MARK: - ElevenLabs

    private func speakWithElevenLabs(_ text: String, apiKey: String, voiceID: String) {
        fetchTask = Task { [weak self] in
            do {
                guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
                    throw URLError(.badURL)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "text": text,
                    "model_id": "eleven_turbo_v2_5",
                ])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw NSError(domain: "ElevenLabs", code: code, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP \(code)",
                    ])
                }
                try Task.checkCancellation()
                await MainActor.run { self?.play(data, fallbackText: text) }
            } catch is CancellationError {
            } catch {
                NSLog("ElevenLabs TTS failed (\(error.localizedDescription)) — falling back to system voice")
                guard !Task.isCancelled, let self else { return }
                await MainActor.run { self.speakWithSystem(text) }
            }
        }
    }

    // MARK: - Playback / system voice

    private func play(_ data: Data, fallbackText: String) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            self.player = player
            // Spin the audio unit up before starting; otherwise the first
            // ~100ms gets clipped and sounds glitchy.
            player.prepareToPlay()
            player.play()
        } catch {
            speakWithSystem(fallbackText)
        }
    }

    private func speakWithSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.preUtteranceDelay = 0.15 // avoid clipped first syllable
        let identifier = UserDefaults.standard.string(forKey: SettingsKeys.ttsVoiceIdentifier)
        utterance.voice = Self.resolveVoice(identifier: identifier)
        synthesizer.speak(utterance)
    }

    /// Explicit pick wins; otherwise the highest-quality installed voice for
    /// the system language. Compact/Eloquence voices rank last — they are the
    /// "horrible robot" defaults.
    static func resolveVoice(identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, !identifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language || $0.language.hasPrefix(prefix)
        }
        return candidates.max {
            (qualityRank($0), preferredNameScore($0)) < (qualityRank($1), preferredNameScore($1))
        }
    }

    static func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        if voice.identifier.contains("eloquence") { return 0 }
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// Tie-break within a quality tier toward the least-robotic stock voices.
    private static let preferredNames = ["Ava", "Zoe", "Samantha", "Allison", "Evan", "Nathan", "Tom", "Susan"]

    private static func preferredNameScore(_ voice: AVSpeechSynthesisVoice) -> Int {
        guard let index = preferredNames.firstIndex(where: { voice.name.hasPrefix($0) }) else { return 0 }
        return preferredNames.count - index
    }

    /// Markdown markers sound terrible spoken aloud; strip the common ones.
    private func plainText(from markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Delegates

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onFinish?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onFinish?() }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinish?() }
    }
}
