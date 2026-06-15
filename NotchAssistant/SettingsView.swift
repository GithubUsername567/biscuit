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
    @AppStorage(SettingsKeys.wakeWordEnabled) private var wakeWordEnabled = true
    @AppStorage(SettingsKeys.recipesEnabled) private var recipesEnabled = true
    @AppStorage(SettingsKeys.companionSpecies) private var companionSpecies = CompanionSpecies.shiba.rawValue
    @AppStorage(SettingsKeys.launchAtLogin) private var launchAtLogin = true
    @AppStorage(SettingsKeys.brainMode) private var brainMode = "local"
    @AppStorage(SettingsKeys.geminiPlannerModel) private var plannerModel = ""
    @AppStorage(SettingsKeys.allowScreenshots) private var allowScreenshots = true

    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var customCommands: [CustomCommand] = CustomCommandStore.all()
    @State private var editingCommand: CustomCommand?

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
                Section("Brain") {
                    Picker("Planner", selection: $brainMode) {
                        Text("Private — local model").tag("local")
                        Text("Capable — Gemini").tag("capable")
                    }
                    if brainMode == "capable" {
                        TextField("Gemini model (blank = gemini-2.0-flash)", text: $plannerModel)
                            .autocorrectionDisabled()
                        Text("Capable mode plans multi-step tasks far better and is free, but your prompts and screenshots go to Google. Needs the Gemini key below. Private keeps everything on your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Everything stays on your Mac via Ollama. Best for simple tasks; switch to Capable for reliable multi-step automation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Ollama (local brain)") {
                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled()
                    TextField("Model", text: $modelName)
                        .autocorrectionDisabled()
                }

                Section("Screen Vision") {
                    Toggle("Allow screenshots (look_closely)", isOn: $allowScreenshots)
                    LabeledContent("Screen Recording", value: screenRecordingStatus)
                    Button("Open Screen Recording Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("Lets Biscuit screenshot the front window and ask Gemini vision about it — for apps without accessibility info, or visual checks. Sends an image to Google; turn off to stay fully local. Uses the Gemini key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Voice Engine") {
                    Picker("Engine", selection: $ttsEngine) {
                        Text("Edge — free, no key").tag("edge")
                        Text("Gemini").tag("gemini")
                        Text("ElevenLabs").tag("elevenlabs")
                        Text("System voice").tag("system")
                    }
                    TextField("Edge voice (blank = en-US-AndrewNeural)", text: $edgeVoiceName)
                        .autocorrectionDisabled()
                    Text("Edge uses Microsoft neural voices for free with no account. Try en-US-GuyNeural, en-US-ChristopherNeural, en-US-AriaNeural, en-US-JennyNeural, en-GB-SoniaNeural.")
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

                Section("Fast Commands") {
                    Toggle("Skip the AI for simple commands", isOn: $recipesEnabled)
                    Text("Common commands — volume, opening apps, “go to <site>”, timers — run instantly with no AI call (faster, and free even on a paid brain). Anything else still goes to the assistant. Turn off if a command is being misread.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("My Shortcuts") {
                    if customCommands.isEmpty {
                        Text("Teach Biscuit your own commands. Say “when I say work mode, open Slack then open Visual Studio Code then set volume to 20”, or add one here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(customCommands) { command in
                        Button {
                            editingCommand = command
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.phrase.isEmpty ? "(no phrase)" : command.phrase)
                                        .foregroundStyle(.primary)
                                    Text(command.steps.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        customCommands.remove(atOffsets: offsets)
                        CustomCommandStore.save(customCommands)
                    }
                    Button {
                        let new = CustomCommand(phrase: "", steps: [])
                        editingCommand = new
                    } label: {
                        Label("Add shortcut", systemImage: "plus")
                    }
                }

                Section("Wake Word") {
                    Toggle("Listen for “Biscuit”", isOn: $wakeWordEnabled)
                    Text("Say “Biscuit” any time and the dog pops up listening — no hotkey needed. Detection runs fully on-device; nothing you say leaves this Mac.")
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
                    LabeledContent("Screen control", value: accessibilityStatus)
                    Button("Open Accessibility Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("Accessibility lets Biscuit see and operate app interfaces (click buttons, type in fields) — needed for multi-step tasks like playing an artist on YouTube Music.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Hold-to-talk needs Input Monitoring. Until granted (then relaunch), use ⌃⌥K to toggle listening instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("General") {
                    Toggle("Show companion pet", isOn: $showCompanion)
                    Picker("Companion", selection: $companionSpecies) {
                        ForEach(CompanionSpecies.allCases) { species in
                            Text(species.label).tag(species.rawValue)
                        }
                    }
                    .disabled(!showCompanion)
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
            customCommands = CustomCommandStore.all()
        }
        .sheet(item: $editingCommand) { command in
            CommandEditor(command: command) { saved in
                if let saved {
                    if let i = customCommands.firstIndex(where: { $0.id == saved.id }) {
                        customCommands[i] = saved
                    } else {
                        customCommands.append(saved)
                    }
                    CustomCommandStore.save(customCommands)
                }
                editingCommand = nil
            }
        }
    }

    private var accessibilityStatus: String {
        PerceptionService.hasPermission ? "Granted" : "Not granted"
    }

    private var screenRecordingStatus: String {
        VisionService.screenRecordingAllowed ? "Granted" : "Not granted"
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
        companionSpecies = CompanionSpecies.shiba.rawValue
        wakeWordEnabled = true
        recipesEnabled = true
        launchAtLogin = true
        brainMode = "local"
        plannerModel = ""
        allowScreenshots = true
    }
}

/// Add/edit a single taught shortcut. `onDone` returns the saved command, or
/// nil if cancelled.
private struct CommandEditor: View {
    @State var command: CustomCommand
    var onDone: (CustomCommand?) -> Void

    @State private var stepsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Trigger phrase") {
                    TextField("e.g. work mode", text: $command.phrase)
                        .autocorrectionDisabled()
                    Toggle("Match the whole phrase exactly", isOn: $command.exactMatch)
                    Text("When off, the shortcut fires whenever the phrase appears in what you say.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Steps — one command per line") {
                    TextEditor(text: $stepsText)
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                    Text("Each line is a command Biscuit already understands, e.g. “open Slack”, “go to gmail.com”, “set volume to 20”. Lines that are simple run instantly; anything else uses the assistant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { onDone(nil) }
                Spacer()
                Button("Save") {
                    command.stepsText = stepsText
                    onDone(command)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command.phrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 380, height: 420)
        .onAppear { stepsText = command.stepsText }
    }
}
