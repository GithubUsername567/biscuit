# Biscuit 🐕

[![build](https://github.com/GithubUsername567/biscuit/actions/workflows/build.yml/badge.svg)](https://github.com/GithubUsername567/biscuit/actions)
[![license: MIT](https://img.shields.io/badge/license-MIT-C98A4B.svg)](LICENSE)

**The pixel pup that runs your Mac.** Hold a key, say the thing, Biscuit does it — opens apps, plays music, sets volume, writes notes — confirms out loud, then goes back to his corner.

Local-first voice agent for macOS 14+: SwiftUI + AppKit, Ollama for the brain, on-device speech recognition, free neural TTS. No accounts, no telemetry.

Brand kit + website: [`branding/`](branding/) · Site: `branding/website/index.html`

## Install

```sh
# 1. The brain (free, local)
brew install ollama
ollama pull qwen2.5:7b
ollama serve

# 2. The dog
git clone https://github.com/GithubUsername567/biscuit.git
cd biscuit
open NotchAssistant.xcodeproj   # then ⌘R in Xcode
```

Builds with ad-hoc signing out of the box; set your team in *Signing & Capabilities* if you prefer.

## Usage

| Action | How |
|---|---|
| Talk to Biscuit | **Hold ⌃ control + fn**, speak, release |
| Talk (no permission yet) | **⌃⌥K** toggles listening |
| Click-to-talk | Click the dog |
| Move the dog | Drag him, or right-click → corners / 30-min nap |
| Pet the dog | Hover 🐶♥ |
| Text input / history | Click the menu bar waveform icon |
| Settings | Panel gear icon |
| Quit | Right-click menu bar icon |

Biscuit auto-sends when you stop talking, performs the task with real tools (apps, AppleScript, shell), speaks one short confirmation, and the bubble fades.

## Permissions

- **Microphone + Speech Recognition** — prompted on first voice use; transcription is on-device.
- **Input Monitoring** — needed for the hold ⌃+fn hotkey (fn is a modifier; detecting it requires an event tap). Grant in System Settings → Privacy & Security; Biscuit picks it up within ~10s, no relaunch. Until then ⌃⌥K works.
- **Automation** — macOS asks per-app the first time Biscuit scripts something. Allow once each.

## Voice engines (Settings → Voice Engine)

| Engine | Cost | Notes |
|---|---|---|
| **Edge** (default) | Free, no key | Microsoft neural voices (AriaNeural etc.) |
| Gemini | Free key | aistudio.google.com/apikey, voices Kore/Puck/Zephyr… |
| ElevenLabs | Free tier key | Best quality, 10k chars/mo free |
| System | Free, offline | Fallback for all of the above |

## Architecture

```
NotchAssistantApp.swift        app entry, menu bar, hotkey wiring
AppState.swift                 state machine + agent loop (tool calling)
CompanionWindow.swift          the pixel dog (sprite, bubble, drag, petting)
FloatingWindowController.swift optional text panel
AssistantPanelView.swift       panel UI
SettingsView.swift             settings sheet
HotkeyManager.swift            ⌃+fn hold via event tap, ⌃⌥K Carbon fallback
AudioInputService.swift        AVAudioEngine + Speech framework STT
OllamaService.swift            streaming /api/chat client with tools
SpeechService.swift            Edge / Gemini / ElevenLabs / system TTS
Models.swift                   shared types + ToolExecutor (app/url/script/shell)
```

Conversation history is in-memory only (last 10 exchanges). Stubs marked TODO: WhisperKit, ScreenCaptureKit.

## License & privacy

MIT — see [LICENSE](LICENSE). Biscuit collects nothing; see [PRIVACY.md](PRIVACY.md).
