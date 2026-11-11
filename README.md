# Buddy

A voice assistant that lives in the macOS menu bar. Hold a shortcut, ask a question out loud, and Buddy looks at your screen, answers in a natural voice, and draws on the screen or on a whiteboard while it talks.

Buddy runs Claude through the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI on your own Claude subscription. Speech recognition and the voice both run on your Mac. There are no API keys to set up, no server, and no analytics.

This is a personal project, based on [Clicky](https://github.com/farzaa/clicky) by Farza (MIT). See [Credits](#credits).

## What it does

- **Push to talk.** Hold Control + Option anywhere on your Mac and speak. Release to send. Press it again to interrupt Buddy mid-answer.
- **Sees your screen.** Each question is sent with a screenshot of every connected display.
- **Answers out loud while it thinks.** The reply is spoken sentence by sentence as it streams, with a local neural voice.
- **Draws on your screen.** While speaking, Buddy can point at, circle, underline, highlight or draw an arrow to things on screen, timed to the words it is saying.
- **Teaches on a whiteboard.** When a picture helps, Buddy opens a floating board and draws diagrams, plots and equations in a hand-drawn style as it explains.
- **Reads your Claude Code sessions.** If your question is about work you did in Claude Code, Buddy can read that session for context.
- **Remembers.** Buddy keeps a short plain-text notes file about you and how you like it to behave. You can open and edit it at any time.

## How it works

```
Hold Control + Option
  → microphone audio → Parakeet (on device) → transcript
  → transcript + screenshots → Claude Code CLI (kept running in the background)
  → reply streams back → Pocket TTS (on device) → speech
                       → inline tags in the reply → pen marks, board drawings, memory notes
```

- **Claude.** A long-lived `claude` process in stream-json mode, so there is no start-up cost per question. Opus 5.5 by default, Sonnet 5.5 optional.
- **Speech to text.** [Parakeet TDT 0.6B v2](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2) through MLX, with Apple Speech as the live preview and fallback.
- **Text to speech.** [Pocket TTS](https://huggingface.co/mlx-community/pocket-tts) through MLX, with Apple's built-in voices as the fallback.
- **Drawing.** Claude writes small tags inside its reply, such as a circle with screenshot coordinates. The app strips them out before speech and fires each one when the voice reaches that word.
- **Whiteboard.** A floating window that runs short drawing snippets written by Claude, using rough.js and KaTeX.

The full technical description is in [AGENTS.md](AGENTS.md).

## Requirements

- A Mac with Apple silicon, running macOS 14.2 or later
- A recent Xcode (built with Xcode 27)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed at `~/.local/bin/claude` and signed in with `claude auth login`
- Python 3.12 for the local voice server

## Setup

1. Clone the repo.

   ```bash
   git clone https://github.com/Kyan42/buddy.git
   ```

2. Set up the local voice server. This creates a Python environment in `tts-server/.venv` and downloads the voice (about 100 MB) and the speech recognition model (about 600 MB).

   ```bash
   tts-server/setup.sh
   ```

   The script expects Python at `/opt/homebrew/bin/python3.12`. To use another one, set `PYTHON_FOR_VENV` to its path.

3. Open the project in Xcode.

   ```bash
   open leanring-buddy.xcodeproj
   ```

4. Select the `leanring-buddy` scheme, set your signing team under Signing & Capabilities, and press Cmd + R.

5. Buddy appears in the menu bar, not the Dock. Click its icon and grant the permissions it asks for.

If you skip step 2, Buddy still works: it uses Apple's speech recognition and built-in voices instead.

Build from Xcode, not with `xcodebuild` in a terminal. A terminal build makes macOS forget the permissions you granted.

### Permissions

| Permission | Used for |
|---|---|
| Microphone | Hearing you while the shortcut is held |
| Speech Recognition | The live preview of what you are saying |
| Accessibility | Detecting the shortcut while other apps are in front |
| Screen Recording | Taking the screenshots sent with each question |

## Privacy

- Your question and the screenshots go to Claude through the Claude Code CLI, under your own account. Nothing else leaves your Mac.
- Audio is transcribed and spoken on device.
- Buddy keeps a diagnostic log, with the screenshots from the last 7 days, in `~/Library/Logs/Clicky/`. It is never uploaded.
- Memory notes are in `~/.claude/buddy-memory/MEMORY.md`.
- A Claude Code session is read only when Buddy decides a question needs it, and only its conversation text is sent.

## Status

I built this for my own daily use, and so far it has only been set up on my own Mac. Expect rough edges. In the code, the app is still called Clicky in many places (the built app is `Clicky.app`), and the project folder keeps the original `leanring-buddy` spelling.

## Project layout

```
leanring-buddy/            Swift source for the app
  CompanionManager.swift     Central state machine for a question and its answer
  ClaudeCLIVoiceSession.swift  The background Claude Code process
  StreamingSentenceSpeaker.swift  Speaks the streamed reply sentence by sentence
  ClickyInlineMarkParser.swift  Splits a reply into speech and tags
  ClickyBoard/               The whiteboard page (rough.js, KaTeX)
  ClickyMemoryStore.swift    The notes file
tts-server/                Local voice server (Pocket TTS and Parakeet through MLX)
tools/                     Standalone tests and measurement scripts
reports/                   Design research and write-ups
worker/                    The original project's Cloudflare Worker (not used by Buddy)
AGENTS.md                  Full architecture notes, also read by coding agents
```

## Credits

Buddy started from [Clicky](https://github.com/farzaa/clicky), the open-source project by Farza, released under the MIT licence. The menu bar app, the cursor overlay, the push-to-talk shortcut and the dictation pipeline come from that project. The official product that grew out of it is HeyClicky; Buddy is not affiliated with it.

What this project adds: running on the Claude Code CLI instead of API keys, on-device speech recognition and voice, drawing on the screen in time with speech, the whiteboard, reading Claude Code sessions, and memory.

Also used:

- [Pocket TTS](https://huggingface.co/mlx-community/pocket-tts) and [Parakeet TDT 0.6B v2](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2), downloaded at setup under their own licences
- [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- [rough.js](https://roughjs.com), [KaTeX](https://katex.org) and the Caveat font, bundled with the whiteboard. Their licences are in `leanring-buddy/ClickyBoard/ClickyBoard-THIRD-PARTY-LICENSES.txt`.

## Licence

MIT. See [LICENSE](LICENSE).
