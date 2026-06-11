import SwiftUI
import AppKit
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKeys.ollamaBaseURL) private var baseURL = SettingsKeys.defaultBaseURL
    @AppStorage(SettingsKeys.modelName) private var modelName = SettingsKeys.defaultModel
    @AppStorage(SettingsKeys.ttsEnabled) private var ttsEnabled = true
    @AppStorage(SettingsKeys.ttsVoiceIdentifier) private var voiceIdentifier = ""
    @AppStorage(SettingsKeys.elevenLabsAPIKey) private var elevenLabsKey = ""
    @AppStorage(SettingsKeys.elevenLabsVoiceID) private var elevenLabsVoiceID = ""
    @AppStorage(SettingsKeys.geminiAPIKey) private var geminiKey = ""
    @AppStorage(SettingsKeys.geminiVoiceName) private var geminiVoiceName = ""
    @AppStorage(SettingsKeys.ttsEngine) private var ttsEngine = "edge"
    @AppStorage(SettingsKeys.edgeVoiceName) private var edgeVoiceName = ""
    @AppStorage(SettingsKeys.showCompanion) private var showCompanion = true
    @AppStorage(SettingsKeys.launchAtLogin) private var launchAtLogin = true

    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            let left = SpeechService.qualityRank($0)
            let right = SpeechService.qualityRank($1)
            return left == right ? $0.name < $1.name : left > right
        }
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = switch voice.quality {
        case .premium: " — Premium"
        case .enhanced: " — Enhanced"
        default: ""
        }
        return "\(voice.name) (\(voice.language))\(quality)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Ollama") {
                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled()
                    TextField("Model", text: $modelName)
                        .autocorrectionDisabled()
                }

                Section("Voice Engine") {
                    Picker("Engine", selection: $ttsEngine) {
                        Text("Edge — free, no key").tag("edge")
                        Text("Gemini").tag("gemini")
                        Text("ElevenLabs").tag("elevenlabs")
                        Text("System voice").tag("system")
                    }
                    TextField("Edge voice (blank = en-US-AriaNeural)", text: $edgeVoiceName)
                        .autocorrectionDisabled()
                    Text("Edge uses Microsoft neural voices for free with no account. Try en-US-GuyNeural, en-US-JennyNeural, en-US-ChristopherNeural, en-GB-SoniaNeural.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Realistic Voice — Gemini (free)") {
                    SecureField("Gemini API Key", text: $geminiKey)
                    TextField("Voice name (blank = Kore)", text: $geminiVoiceName)
                        .autocorrectionDisabled()
                    Text("Free key at aistudio.google.com/apikey. Voices: Kore, Puck, Zephyr, Charon, Fenrir, Aoede… Gemini is used first when set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Realistic Voice (ElevenLabs)") {
                    SecureField("API Key", text: $elevenLabsKey)
                    TextField("Voice ID (blank = Rachel)", text: $elevenLabsVoiceID)
                        .autocorrectionDisabled()
                    Text("Paste a free API key from elevenlabs.io (10k characters/month free). When set, responses use ElevenLabs instead of the system voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Speech") {
                    Toggle("Speak responses", isOn: $ttsEnabled)
                    Picker("Voice", selection: $voiceIdentifier) {
                        Text("Best Available (auto)").tag("")
                        ForEach(voices, id: \.identifier) { voice in
                            Text(voiceLabel(voice)).tag(voice.identifier)
                        }
                    }
                    .disabled(!ttsEnabled)
                    Text("For natural voices, download an Enhanced or Premium voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Permissions & Hotkey") {
                    LabeledContent("Microphone", value: micStatusText)
                    Button("Open Microphone Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    LabeledContent("Hotkey", value: "Hold ⌃+Fn (release to send)")
                    Button("Open Input Monitoring Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("Hold-to-talk needs Input Monitoring. Until granted (then relaunch), use ⌃⌥K to toggle listening instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("General") {
                    Toggle("Show companion dog", isOn: $showCompanion)
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            LaunchAtLogin.set(enabled: newValue)
                        }
                    Button("Clear conversation") {
                        appState.clearConversation()
                    }
                    Button("Reset to defaults", role: .destructive) {
                        resetDefaults()
                    }
                    Button("Quit Biscuit", role: .destructive) {
                        NSApp.terminate(nil)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 540)
        .onAppear {
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private var micStatusText: String {
        switch micStatus {
        case .authorized: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested yet"
        @unknown default: "Unknown"
        }
    }

    private func resetDefaults() {
        baseURL = SettingsKeys.defaultBaseURL
        modelName = SettingsKeys.defaultModel
        ttsEnabled = true
        voiceIdentifier = ""
        ttsEngine = "edge"
        edgeVoiceName = ""
        geminiVoiceName = ""
        elevenLabsVoiceID = ""
        showCompanion = true
        launchAtLogin = true
    }
}
