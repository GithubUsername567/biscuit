# Biscuit — Brand Kit

**Biscuit** is the pixel pup that runs your Mac. Hold a key, say the thing, and Biscuit does it — opens apps, plays music, sets volume, takes notes — then trots back to his corner.

## The name

A biscuit is what a good dog earns for doing the task. Warm, small, familiar, a little nostalgic — exactly like a 16×16 shiba living in the corner of your screen. Short, ownable, easy to say out loud (you'll be talking to him a lot).

Formerly: NotchAssistant (working title).

## Taglines

- **Primary:** The pixel pup that runs your Mac.
- Say it. Done. *(short-form)*
- A very good assistant. *(playful)*
- Does things. Doesn't explain them. *(product truth)*

## Voice & tone

Friendly, brief, capable. Biscuit speaks in one-sentence confirmations, never lectures. Copy rules: short sentences, no jargon, dog jokes allowed but max one per screen. Never cutesy at the cost of clarity.

## Logo

`logo.svg` — the 16×16 pixel shiba, the same sprite rendered live in the app. Never smooth, never anti-aliased: crisp pixels are the brand. Minimum size 32px. Clear space: one ear-height around all sides.

- `icon.svg` — app icon: dog on warm charcoal, rounded 1024.
- `wordmark.svg` — dog + "Biscuit" in pixel type.

## Color

| Name | Hex | Use |
|---|---|---|
| Biscuit | `#C98A4B` | Primary brand, fur, CTAs |
| Cocoa | `#4A2E19` | Outlines, dark accents |
| Cream | `#F2E4D0` | Text on dark, fur highlights |
| Charcoal | `#15110C` | Backgrounds |
| Listen Green | `#4ADE80` | Listening state |
| Think Amber | `#F59E0B` | Working state |
| Speak Blue | `#60A5FA` | Speaking state |
| Oops Red | `#F87171` | Errors |

State colors always pair with the dog's glow — they are functional, not decorative.

## Typography

- **Display / logo:** Press Start 2P (Google Fonts) — pixel, used sparingly: logo, H1, buttons.
- **Body / UI:** Space Grotesk (Google Fonts) — modern, warm, highly legible.
- Code/snippets: system monospace.

## Iconography & illustration

Everything pixel-grid (multiples of 16). The dog has five moods: idle (tail wag), listening (ears up, green glow), working (bounce, amber), speaking (tongue, blue), oops (ears down, red). Use sprite frames from the app source (`CompanionWindow.swift`) — single source of truth.

## Don'ts

- Don't blur, round, or smooth the dog.
- Don't recolor the fur off-palette.
- Don't make Biscuit talk in paragraphs.
- Don't use the notch — Biscuit lives in the corner, not the camera housing.
