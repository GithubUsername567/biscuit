import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Biscuit's fallback eyes: captures the frontmost window and asks Gemini
/// vision about it. Used when the Accessibility tree is empty or when a
/// purely visual judgment is needed. Screenshots leave the Mac, so this is
/// gated behind a Settings toggle and a Gemini key.
enum VisionService {

    static var screenRecordingAllowed: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func look(question: String) async -> String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SettingsKeys.allowScreenshots) as? Bool ?? true else {
            return "Screenshots are disabled in Settings, so I can't look closely. Use see_screen instead."
        }
        let key = defaults.string(forKey: SettingsKeys.geminiAPIKey) ?? ""
        guard !key.isEmpty else {
            return "look_closely needs a Gemini API key (Settings → Voice/Vision). Use see_screen instead."
        }
        guard screenRecordingAllowed else {
            requestScreenRecording()
            return "Screen Recording permission isn't granted yet (System Settings → Privacy → Screen Recording). Use see_screen for now."
        }
        guard let jpeg = await captureFrontmostJPEG() else {
            return "Couldn't capture the screen. Use see_screen instead."
        }
        return await askGemini(question: question, jpeg: jpeg, apiKey: key)
    }

    // MARK: - Capture

    private static func captureFrontmostJPEG() async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

            let window = content.windows.first {
                $0.isOnScreen
                    && $0.frame.height > 120
                    && $0.owningApplication?.processID == frontPID
            } ?? content.windows.first { $0.isOnScreen && $0.frame.height > 200 }

            guard let window else { return nil }

            let config = SCStreamConfiguration()
            // Cap longest side ~1280 to keep the upload small and fast.
            let scale = min(1.0, 1280.0 / max(window.frame.width, window.frame.height))
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return jpeg(from: image)
        } catch {
            NSLog("VisionService capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func jpeg(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    // MARK: - Gemini vision

    private static func askGemini(question: String, jpeg: Data, apiKey: String) async -> String {
        do {
            let model = UserDefaults.standard.string(forKey: SettingsKeys.geminiPlannerModel)
                .flatMap { $0.isEmpty ? nil : $0 } ?? SettingsKeys.defaultPlannerModel
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
                return "Vision error: bad URL."
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let prompt = "You are looking at a screenshot of a macOS app window to help an automation agent. "
                + "Answer concretely and briefly. If asked for a location, give it as x,y fractions from 0 to 1 "
                + "(0,0 top-left, 1,1 bottom-right). Question: \(question)"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "contents": [[
                    "parts": [
                        ["text": prompt],
                        ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ],
                ]],
                "generationConfig": ["temperature": 0.1],
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return "Vision error: HTTP \(code)."
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
                return "Vision returned no answer."
            }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? "Vision returned no answer." : "Looking at the screen: \(text)"
        } catch {
            return "Vision error: \(error.localizedDescription)"
        }
    }
}
