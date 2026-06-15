# Biscuit — Clean-Room Build Specification

A behavioral specification for independently re-implementing Biscuit: a
local-first, voice-controlled macOS agent represented by a pixel companion.
This document describes *what to build and how it must behave* — interfaces,
algorithms, and hard-won gotchas — not the original source. An implementer
should be able to reproduce the product from this alone.

---

## 1. Product definition

Biscuit is a menu-bar macOS app (no main window) that listens for voice,
performs the requested task by **controlling the Mac** (scripting + reading and
operating app interfaces), and confirms out loud and/or as on-screen text. A
small animated pixel pet lives in a corner as the only persistent UI.

Design priorities, in order: **it does the task** (never explains how), **it's
reliable**, **the voice UX is frictionless**, **it's private** (no telemetry,
local-first), and **it has personality**.

Three ways to invoke: a wake word ("Biscuit"), a hold-to-talk hotkey, and
clicking the pet. Tasks can also be typed in an optional panel.

---

## 2. Platform & stack

- macOS 14+. SwiftUI + AppKit. Swift 5 language mode (avoids strict-concurrency
  churn). Built with Xcode; `LSUIElement = YES` (menu-bar accessory, no Dock
  icon).
- **No sandbox, no entitlements.** Event taps, AppleScript/shell, and
  Accessibility control require it off. This makes the Mac App Store
  impossible — distribute directly (signed/notarized `.dmg`).
- Local LLM via Ollama (`/api/chat`, streaming, tool calling). Optional cloud
  brain via a hosted model API behind the same abstraction.

---

## 3. Architecture

A single `@MainActor` state object (`AppState`) is the source of truth and
orchestrator. Everything else is a service it drives.

```
                ┌───────────────────────────────────────────┐
   wake word ──▶│                AppState                    │
   hotkey ─────▶│  state machine · dispatch · agent loop     │
   pet click ──▶│  caption · capture                         │
   typed text ─▶└──┬───────┬──────────┬──────────┬───────────┘
                   │       │          │          │
            AudioInput  ChatProvider  ToolExecutor  Speech(TTS)
            (STT+VAD)   (Ollama|Cloud) (14 tools)   (Edge|cloud|system)
                   │                      │
            WakeWord(STT)          Perception(AX) · InputSynth(CGEvent)
                                   Vision(screenshot→vision model)
                                   WebSearch · Reminders · Clipboard
        UI: CompanionWindow (pet+bubble) · FloatingPanel (text) · Settings
```

**Request dispatch order** (in `AppState.send(text)`), first match wins:
1. **Save request** ("save that [as <name>]") — if a capture is pending, turn
   the last run into a shortcut. (§12)
2. **Teach request** ("when I say X, do Y") — save a custom command. (§11)
3. **Custom command** match — run a user-taught shortcut. (§11)
4. **Recipe** match — run a deterministic fast path. (§10)
5. **Model loop** — full agentic LLM loop. (§9)

User-taught shortcuts intentionally rank above built-in recipes so users can
override behavior.

---

## 4. State machine

`enum AssistantState { idle, listening, processing, responding, error(String) }`

- `idle` — waiting. Wake word active here only.
- `listening` — capturing mic audio.
- `processing` — running tools / waiting on the model.
- `responding` — speaking / showing the reply.
- `error(message)` — surfaced in the bubble; auto-clears.

Transitions drive the pet's animation and aura color (idle=none,
listening=green, processing=amber/orange, responding=blue, error=red). A state
change to `idle`/`error` schedules an auto-hide of the panel.

---

## 5. Audio input pipeline (STT + endpointing)

`AudioInputService`: `AVAudioEngine` mic tap → Apple `SFSpeechRecognizer`.

Behavior:
- **Fresh recognizer + fresh `AVAudioEngine` per session.** Reusing either is
  the cause of instant `kAFAssistantError 1101` failures and "won't restart
  after TTS" bugs.
- Online recognition (not on-device) for the request recognizer — more
  accurate, reliable `isFinal`, adds punctuation. (Wake word is the opposite;
  see §6.)
- **Voice-activity endpointing (VAD):** per-buffer RMS energy; above a
  threshold (~0.012) marks speech and bumps `lastVoiceTime`. A 0.1s repeating
  timer ends the session 1.4s after sound stops (`silenceToEnd`), with a 7s
  no-speech timeout and a 25s hard cap. Transcript activity also counts as
  voice (keeps alive while speaking even if energy estimate is conservative).
- **Hold-to-talk** mode disables auto-endpointing (`autoEndpoint:false`) — ends
  only on key release.
- `stopAndFinalize()` ends audio, then a ~0.35s fallback `DispatchWorkItem`
  delivers the last partial transcript if `isFinal` never fires (on-device/edge
  cases drop it).

Hard-won gotchas (each is a real bug an implementer will hit):
- Touching `inputNode` before mic permission is granted **deadlocks the main
  thread** on the CoreAudio HAL mutex. Guard all teardown with a
  `tapInstalled` flag; never touch `inputNode` unless capture actually started.
- During audio-device transitions (Bluetooth profile switches after TTS) the
  input format briefly reports **0 Hz / 0 channels** — engine start throws.
  Detect and retry with backoff `[0, 250, 600, 1200]ms`.
- **Dead input stream:** when the input device disappears mid-session (e.g.
  AirPods disconnect), the engine keeps running and feeds **pure silence with
  no error**. Detect: after 2s with peak RMS < 0.001 and empty transcript,
  abort with a distinct error so the caller rebuilds. Also observe
  `.AVAudioEngineConfigurationChange` and rebuild on it (deliver any partial
  transcript rather than dropping it).
- Recognizer dying instantly (<1.5s, e.g. TTS hasn't released the route) →
  retry up to 3× with a 250ms settle.
- After 3 rebuilds still silent → report loudly ("getting silence from the
  microphone…"), don't vanish.

---

## 6. Wake word

`WakeWordService`: an always-on, **strictly on-device** `SFSpeechRecognizer` +
its own `AVAudioEngine` tap, running only while `state == idle` and the toggle
is on. Scans partial transcripts for the substring "biscuit" (case-insensitive;
`contextualStrings = ["Biscuit"]` as a hint). On match → fire `onWake` → play a
soft chime → start a normal listening session (no panel; the bubble is the only
feedback, exactly like the hotkey).

Critical properties:
- **On-device only.** If `supportsOnDeviceRecognition` is false, stay dormant —
  never stream ambient room audio anywhere. This is the privacy guarantee.
- Runs **only when idle** so it can't wake on the app's own TTS saying
  "Biscuit", and releases the mic before the request engine starts.
- **Recycle the session every ~55s** — on-device transcripts accumulate
  forever, making matching steadily more expensive.
- **Restart storm guard:** sessions that die instantly (Bluetooth flaps,
  recognizer churn) must NOT be retried on a flat short timer — that spawns
  2–3 sessions/sec and hogs the mic. Use exponential backoff
  (0.5s → cap 60s), reset on any session that survives ≥2s or wakes.
- Permission/recognizer not ready → retry on a 30s heartbeat (don't go
  permanently dormant; that was a bug requiring relaunch).
- Observe `.AVAudioEngineConfigurationChange` and rebuild on device switch.

---

## 7. Hotkey

Hold-to-talk: hold **⌃ control + fn**, release to send. `fn` is a modifier, so
detection needs a `CGEvent` `flagsChanged` event tap (requires **Input
Monitoring** permission). Fallback while not granted: a Carbon
`RegisterEventHotKey` toggle (⌃⌥K). Self-heal: retry installing the event tap
every 10s after Input Monitoring is granted, so no relaunch is needed.

---

## 8. The brain abstraction

```
protocol ChatProvider {
    func stream(messages: [WireMessage]) -> AsyncThrowingStream<StreamEvent, Error>
}
enum StreamEvent { case token(String); case toolCalls([ToolCall]) }
```

- `OllamaService` (local) and a cloud `ChatProvider` both conform.
- A `FallbackChatProvider(primary, secondary)` tries the cloud model and falls
  to local if the primary errors **before emitting any event** (quota, network).
- Wire format mirrors Ollama `/api/chat`: messages with `role`/`content`,
  optional `tool_calls` on assistant turns, and `name` on tool-result turns.
  Options: low temperature (~0.2) and a large context window (≥8192) — the
  default 2k truncates the system prompt + tool schemas and the model then
  ignores instructions. `keep_alive: 60m` + a launch warmup keeps the local
  model resident (cold 9GB reloads were most of the perceived slowness).
- Request timeout ≥120s (cold model loads exceed 30s).

---

## 9. Tool set & agent loop

### Tools (14)

Each tool = name + description + JSON-schema params. The executor returns a
string result fed back to the model.

| Tool | Params | Effect |
|---|---|---|
| `open_app` | name | `open -a <name>` |
| `open_url` | url | open http(s) URL in default browser (reject non-web) |
| `run_applescript` | script | `osascript -e` (off main thread) |
| `run_shell` | command | run a shell command |
| `see_screen` | — | flatten frontmost app's **accessibility tree** into a numbered list of actionable elements (buttons/links/fields/rows/text); cache the targets |
| `click_element` | number | click the element from the latest `see_screen` snapshot (post a `CGEvent` click at its point) |
| `type_text` | text, submit | synth-type Unicode into the focused field; optionally press Return |
| `press_key` | key, modifiers | post a key / shortcut |
| `look_closely` | question | screenshot the front window (ScreenCaptureKit) → send to a **vision model** to read/locate; gated by a screenshots toggle + Screen Recording permission |
| `click_at` | x, y | click at fractional screen coords (0..1), from a `look_closely` answer |
| `web_search` | query | scrape a no-key search endpoint (e.g. DuckDuckGo HTML), return top ~5 results |
| `set_reminder` | text, minutes | schedule a local `UserNotifications` notification |
| `read_clipboard` | — | return clipboard text |
| `write_clipboard` | text | replace clipboard text |

All subprocess work (osascript/open/shell) runs off the main thread.

### System prompt (behavioral contract)

The prompt must enforce:
1. **Do, don't explain.** Any actionable request → use tools, never reply with
   instructions, never say "I can't".
2. **OBSERVE → ACT → VERIFY loop** for UI tasks: `see_screen`, decide the next
   click/type from the numbered list, do it, `see_screen` again to confirm,
   repeat until done. After a `see_screen`, element numbers refer to that
   latest snapshot.
3. **Fast paths** when scripting suffices (open app, AppleScript volume/Notes).
4. **Anti-hallucination (critical):** only report what a tool actually
   returned. To read anything on screen, call `see_screen` (then `look_closely`
   if needed) and report only that text. If nothing readable, say so plainly.
   Never fabricate events/names/times/numbers.
5. **Promo avoidance:** never click install / sign-in / cookie / subscribe
   prompts; find the real target (a song row, a Play control, the content).
6. **Clipboard:** for "what I copied"/"this text", call `read_clipboard` first.
7. **Stay on target:** decide the goal once; before every tool call check
   whether the latest screen already shows the goal achieved or the exact
   element to click next. Never `web_search` mid-on-screen-task. Click the
   result whose label most exactly matches the requested name.

### Agent loop

Stream the conversation to the `ChatProvider`. While streaming, accumulate
assistant text (show it live) and collect any tool calls. Per round:
- No tool calls + non-empty text → that's the final answer; speak/show it.
- Tool calls → append assistant turn (with calls), execute each tool, append
  each result as a tool turn, loop.
- Cap at ~12 rounds (UI loops need many); error out past the cap.

Keep ~10 exchanges of history in memory; trim older.

---

## 10. Recipes (deterministic fast paths)

A `RecipeBook` matches the request against high-confidence patterns and emits a
fixed tool sequence + a **templated confirmation**, running with **zero LLM
calls** (the whole planning loop — system prompt + tool schemas + rounds — is
skipped). This is the primary token/latency saver for everyday commands.

Cover at least:
- **Volume**: "set volume to N", "volume N", "N percent", number-words
  ("fifty"→50), "half"→50, "max/full"→100 → AppleScript `set volume output
  volume N` (unmute first). **Mute**: "mute"/"be quiet" → `set volume output
  muted true`.
- **Open app**: whole-utterance "open/launch <name>" — reject if it contains
  connective/multi-step words (" and ", " then ", "play", "search", "http",
  "tab", "window") so multi-step tasks fall through.
- **Open URL**: "go to/open/visit <host.tld[/path]>" → `https://…` (require a
  real dot-TLD, so "open my notes" doesn't match).
- **Timer/reminder**: "set a timer for N <unit>", "remind me to X in N
  minutes" → `set_reminder` (parse number-words; convert sec/hr to minutes).

**Safety is the whole game:** matching is conservative; anything ambiguous,
multi-step, or needing reasoning (music, web search, clipboard) returns nil and
falls through to the model. If a recipe's tool errors mid-run, hand the
original request to the model. A wrong fire is worse than a missed saving.
Provide a settings toggle to disable. Verify with a match/decline test harness.

---

## 11. Custom commands (teachable shortcuts)

`CustomCommand { id, phrase, steps:[String], exactMatch:Bool,
capturedCalls:[ToolCall]? }`. Persisted as JSON in app preferences.

**Match:** word-bounded contains (or exact if flagged), longest phrase wins.

**Run:**
- If `capturedCalls` present → replay them directly (token-free). (§12)
- Else if **every** step is recipe-able → run them all token-free, speak a
  combined confirmation.
- Else → rejoin steps ("…, then …") and hand to the model as one instruction.

**Author two ways:**
- **By voice:** "when I say X, <actions>" / "…X do <actions>" / "teach a
  shortcut called X that does <actions>". Split actions into steps on explicit
  separators only (`;`, " then ", " and then ") — never bare " and " (leave
  "open slack and discord" as one step the model resolves). Save and confirm,
  no model call.
- **In Settings:** a list with add/edit/delete; editor = phrase field + one
  step per line + exact-match toggle.

---

## 12. "Watch me do it" capture

After a successful **model** run that performed at least one non-perception
action, keep `(originalRequest, executedToolCalls)` as a pending capture and
nudge in the caption: *"say 'save that' to keep it."*

On **"save that [as <name>]"** (only valid while a capture is pending):
- Phrase = given name, else the original request text.
- If the run had **no** `click_element`/`click_at` and includes replayable
  tools (`open_app`, `open_url`, `run_applescript`, `run_shell`,
  `set_reminder`, `type_text`, `press_key`, `write_clipboard`) → save those
  literal calls as `capturedCalls` for **token-free, instant replay**.
- Otherwise (the run clicked on screen) → save as a model macro
  (`steps = [originalRequest]`), since clicks can't replay against a different
  live screen.

Clear the pending capture on the next unrelated request. This gives zero-effort
shortcut authoring: do it once, say "save that".

---

## 13. Captions

Every reply funnels through one `presentReply(text, captureHint)`:
- Append to history; set `caption = text` (plus the save-nudge if hinted) when
  the captions toggle is on.
- If TTS on → state `responding`, speak.
- If muted → state `idle`, auto-hide after `clamp(len/12, 4, 12)` seconds so a
  muted user can read it.

The pet bubble shows the caption during `responding` and lingering `idle`, so
Biscuit is fully usable with sound off. Toggle in Settings (default on).

---

## 14. TTS

`SpeechService` with engine priority and graceful fallback. Engines:
- **Edge neural** (default, free, no key): POST SSML to Microsoft's readaloud
  WSS endpoint with a `Sec-MS-GEC` token; **must send a current
  `Sec-MS-GEC-Version` + matching `Edg/<v>` user-agent** or it 403s (track the
  edge-tts project's constants when it breaks). Default a male voice
  (`en-US-AndrewNeural`); validate any voice against the readaloud voice list.
- **Cloud TTS** (optional key): model TTS → raw PCM wrapped in a WAV header.
- **ElevenLabs** (optional key).
- **System** `AVSpeechSynthesizer` fallback (note: premium voices aren't
  installed by default; system voice is robotic).

`onFinish` returns state to idle and schedules auto-hide.

---

## 15. Companion UI

- **CompanionWindow:** a tiny borderless, non-activating, always-on-top
  `NSPanel` in a screen corner. Hosts a `Canvas`-drawn 16×16 pixel pet
  animated on a ~0.45s timeline (2 frames per state), with an aura glow and a
  speech bubble (caption / live transcript / "Working…" / errors). Click =
  toggle listening. Drag to move (anchor to screen-space mouse, not window
  space, or you get a feedback loop). Right-click menu: move to corner / nap
  30m / hide. Hover = pet reacts (ears up + hearts).
- **Species:** a palette+sprite system. Dog breeds (shiba/husky/golden) are
  palette swaps over one geometry; cat and parrot (and seal, penguin) are their
  own 16×16 maps. Each defines frames for idle/alert(listening)/speaking/error.
  Picker in Settings. (QA sprites by rendering the char-maps to a PNG sheet and
  eyeballing before shipping.)
- **FloatingPanel:** optional spotlight-style text-input panel near top-center
  (menu-bar icon toggles it). Auto-hides on click-away / Escape / ~1s after a
  spoken answer.
- **Status item:** menu-bar icon; left-click toggles panel, right-click menu.

---

## 16. Settings (preference keys)

Brain mode (local|capable), Ollama base URL + model, cloud API keys + planner
model, TTS engine + per-engine voice, speak-responses toggle, captions toggle,
wake-word toggle, recipes toggle, custom commands (JSON), companion species,
show-companion toggle, launch-at-login, allow-screenshots, hotkey/permission
status readouts. All in standard app preferences.

---

## 17. Permissions & code signing (the stability trick)

Permissions needed: Microphone, Speech Recognition, Accessibility (read/operate
UIs), Input Monitoring (hotkey), Screen Recording (vision), Notifications.
Request at launch; show status + deep-links in Settings.

**The non-obvious essential:** macOS TCC ties permission grants to the app's
**code-signing identity**. Ad-hoc signing changes identity every build, so
every rebuild silently **revokes** Accessibility / Screen Recording / Input
Monitoring. Fix: create a **stable self-signed certificate**, import it into the
login keychain so `codesign` uses it promptlessly, and re-sign the installed
app with a fixed `--identifier` after every install. Then the designated
requirement (identifier + cert leaf hash) is stable and grants persist across
rebuilds. Renaming the bundle identifier also resets all grants (new TCC
identity) and orphans preferences — migrate prefs and warn the user.

For distribution: an Apple Developer ID + notarization removes Gatekeeper
warnings and stabilizes the signature (also fixes Input Monitoring resets). MAS
is not an option (sandbox).

---

## 18. Build & ops

- Project uses modern `objectVersion` with file-system-synchronized groups (no
  per-file refs). App-icon asset catalog rendered from the sprite at 16–1024.
- CI: GitHub Actions on macOS, `CODE_SIGNING_ALLOWED=NO`.
- Install flow: build Release → copy to `/Applications` → run the stable-cert
  re-sign script → launch.
- A readable file log (events/counts only, never speech content) is invaluable
  for field-debugging audio/wake issues — the unified log redacts your
  `NSLog` content as `<private>`.

---

## 19. MVP scope — build order

Ship these, in order, each independently useful:

1. **Menu-bar app + pet window + state machine.** No brain yet; click toggles a
   stub.
2. **Audio capture + Apple STT + VAD endpointing** with all §5 gotchas. This is
   the hardest, most bug-prone part — get it solid first.
3. **Ollama `ChatProvider` + agent loop + the core scripting tools**
   (`open_app`, `open_url`, `run_applescript`, `run_shell`) + the system
   prompt. Now it does real tasks by voice.
4. **TTS** (Edge default) + **captions**. Now it talks/shows replies.
5. **Accessibility tools** (`see_screen`, `click_element`, `type_text`,
   `press_key`) + the observe→act→verify prompt. Now it operates app UIs.
6. **Hotkey** (hold ⌃+fn) and **wake word** (on-device, with the storm guard).
7. **Recipes** — the token/latency win on everyday commands.
8. **Custom commands** + **watch-me-do-it capture** — user extensibility.
9. **Stable-cert signing** so permissions survive rebuilds (do this early in
   practice — it saves re-granting on every dev cycle).

Defer: vision (`look_closely`/`click_at`), web search, reminders, clipboard,
multiple pet species, cloud brain + fallback. All are additive.

**The bar for "it works":** say a wake word, give a multi-step UI command, go
silent, and watch it complete the task and confirm — reliably, across audio
device changes, without re-granting permissions after a rebuild.
