# Biscuit Privacy Policy

*Last updated: June 11, 2026*

Biscuit is designed so your data stays on your Mac.

## What Biscuit collects

Nothing. Biscuit has no accounts, no analytics, no telemetry, and no servers operated by us. We never see your data.

## What stays on your Mac

- **Your voice** — transcribed entirely on-device using Apple's speech recognizer. Audio never leaves your machine.
- **Your prompts and conversations** — processed by Ollama running locally on your Mac. Kept in memory only (last 10 exchanges) and gone when Biscuit quits.
- **Your settings** — stored locally in macOS user defaults, including any API keys you choose to add.

## What leaves your Mac

Only one thing: when speaking a reply with a cloud voice engine, **the assistant's reply text** (never your voice, never your prompt) is sent to the provider you selected in Settings to be turned into audio:

- **Edge** (default) — Microsoft's text-to-speech service
- **Gemini** — Google, using your own API key
- **ElevenLabs** — using your own API key

Each provider handles that text under its own privacy policy. Prefer total offline? Set the voice engine to **System** in Settings — then nothing ever leaves your Mac.

## Permissions Biscuit asks for

- **Microphone & Speech Recognition** — to hear and transcribe you, on-device
- **Input Monitoring** — solely to detect the ⌃+fn hold; keystrokes are never logged or stored
- **Automation** — to perform the actions you ask for (granted per-app by macOS)

## Questions

Open an issue: https://github.com/GithubUsername567/biscuit/issues
