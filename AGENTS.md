# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it on-device with Apple Speech, and sends the transcript + a screenshot of the user's screen to a warm Claude Code CLI process running on the user's own Claude subscription (`claude auth login`). The reply is spoken sentence-by-sentence with Apple's on-device voices while it streams. Claude calls a local `point` tool mid-reply to make the blue cursor fly to UI elements on any connected monitor.

The app shows and calls itself **Buddy** (menu panel, permission prompts, welcome message, board title, and the name in the voice prompts). Code names, the built `Clicky.app`, the bundle identifier and the log folder keep "Clicky", and the `Buddy*` dictation files are unrelated upstream names.

This is a personal fork: no API keys, no Cloudflare Worker, analytics disabled, and the Sparkle update feed removed.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude Code CLI (`~/.local/bin/claude`) in stream-json mode, kept warm as a long-lived process (`ClaudeCLIVoiceSession`). Opus 5.5 default, Sonnet 5.5 optional. Rotated to a fresh process every 8 turns (screenshots accumulate in context), carrying over text history.
- **Speech-to-Text**: Parakeet TDT 0.6B v2 (NVIDIA, English, on-device via MLX) through the local voice server's `/transcribe` endpoint, selected by `VoiceTranscriptionProvider = parakeet` in Info.plist (`ParakeetTranscriptionProvider`). Apple Speech runs alongside every push-to-talk for the live partial text and as the fallback when the server isn't ready, isn't set up, or fails (4s timeout). `apple` selects Apple Speech only. AssemblyAI/OpenAI providers remain but need the old Worker.
- **Text-to-Speech**: `StreamingSentenceSpeaker` splits the streamed reply into sentences. Preferred voice: **Pocket TTS** (local neural voice, MLX) from `tts-server/pocket_tts_server.py`, launched and supervised by `LocalVoiceServer` (loopback HTTP with a per-launch secret token, ready in ~1s, ~50ms to first audio, PCM16 24kHz streamed into an `AVAudioPlayerNode`). The voice is chosen per reply; if the server isn't ready or fails mid-reply, Apple's best installed voice (AVSpeechSynthesizer) takes over and the server restarts in the background (max 3 restarts / 10 min).
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Pace**: `ClickySpeechPace` (Slow/Normal/Fast, panel picker, persisted in UserDefaults `selectedSpeechPace`). Sets voice speed (Pocket: `AVAudioUnitTimePitch` between player and mixer, 0.82x/1.0x/1.15x, pitch preserved; Apple: utterance rate), pauses between sentences (0.45s/0.15s/0s, scheduled as mark-free silence so marks still land on the first word), and a goal-style pacing note in the system prompt (changing pace restarts the warm CLI session).
- **Pen (talk-and-draw)**: Claude writes inline mark tags in its reply (`<point>`, `<circle>`, `<underline>`, `<highlight>`, `<arrow>`, `<clear/>`, screenshot-pixel coordinates). `ClickyInlineMarkParser` strips them from the stream before speech; `StreamingSentenceSpeaker` pins each mark to a character position in a sentence and fires it when playback reaches it (Apple voice: `willSpeakRangeOfSpeechString`; Pocket TTS: `.dataPlayedBack` buffer completions as the clock, ~0.1s granularity). `CompanionManager.handleMarkReachedInSpeech` maps coordinates to the right display, adds the mark to `screenMarksBeingShown` (drawn by `ClickyScreenMarksLayer` with a pen-stroke animation) and sends the blue cursor there via `cursorPenFlightRequest` (fast 0.25-0.5s hops; holds while speaking, flies home ~1s after). Pen marks are ink on the screen under the board: `ClickyScreenMarksLayer` masks them out wherever the board window is (`boardWindowFrameOnScreen`, kept current by `ClickyBoardPanelManager.onBoardWindowFrameChanged`), and the cursor does not fly to a spot the board covers. The exception is a mark Claude aimed at the board itself (the board was in that turn's screenshot at the same frame and has not been wiped since), which is drawn on top of it. The old MCP `point` tool is no longer given to the voice session (tool calls stalled replies 0.5-7s); `ClickyLocalToolServer` stays for future tools. The voice session runs with `--effort low` by default; a panel Effort picker (Low/Medium, UserDefaults `selectedClaudeEffortLevel`, restarts the warm CLI session) switches to medium. `interaction_summary.effort` records which one answered. The onboarding demo still uses a `[POINT:...]` text tag.
- **Board (teaching visuals)**: a floating whiteboard window (`ClickyBoardPanelManager`: non-activating `NSPanel`, draggable SwiftUI title bar, corner resize grip, frame autosaved as `ClickyBoardWindow`, default right side of the cursor's screen) hosting a `WKWebView` that loads `ClickyBoard/clicky-board.html` from the bundle (rough.js for the hand-drawn look, KaTeX for equations, Caveat handwriting font; CSP blocks all network). Claude writes `<board title="..."/>` (fresh board) and `<draw>...</draw>` (a JavaScript snippet against the board API in `clicky-board.js`, 1000x625 board units) inline in its reply; they are marks like the pen's, fired when the voice reaches them. Each snippet's strokes are revealed over the time the voice takes to say the rest of that sentence (`revealDurationSecondsForDrawMark`: characters until the sentence ends × 0.063s ÷ pace, clamped 0.8-6s). Snippets share a scope per board (names assigned without let/const persist). The board stays open between turns: its snippets are appended to the next turn's text (`boardStateDescriptionForClaude`), and the board window is kept in screenshots (`ownWindowNumbersToKeepVisible`). Pops up whenever Claude decides a picture helps (goal-style prompt section). The bundled folder is a synchronized group, so its files are copied flat into Resources (KaTeX CSS font URLs were rewritten to match). Test the page in a browser: `python3 -m http.server` in `leanring-buddy/ClickyBoard`, open `clicky-board.html`, call `clickyBoard.runStep(code, seconds)`.
- **Claude Code sessions (context beyond the screenshot)**: `ClickyClaudeCodeSessionReader` reads the user's local Claude Code sessions (`~/.claude/projects/<folder>/<session-id>.jsonl`, plus `~/.claude/sessions/<pid>.json` for which are open). Every question carries a short list of the 10 most recent sessions (title, folder, last active, open or not, 8-character id), refreshed when the hotkey goes down and once at launch. Claude asks for one by writing `<read_session id="..."/>` after a spoken lead-in and ending its reply; `CompanionManager.handleSessionReadRequest` acts on the tag the moment it is parsed (it is a parser output of its own, not a mark pinned to speech), speaks the lead-in (`speakBufferedTextWithoutFinishingReply`; the app says "let me get some context real quick." if Claude said nothing), drops anything Claude writes after the tag, and when that CLI turn ends sends the session's digest as the next user message (`continueReplyBySendingRequestedSession`). The answer streams into the same spoken reply, so one reply can span two CLI turns and only `finishReplyAfterItsLastCLITurn` ends it (never rotate the CLI process in between). The digest is the session's latest compaction summary plus the typed conversation since (no tool output, thinking or injected reminders), capped at 40,000 characters. Up to 2 reads per reply. It is an inline tag and not a tool call on purpose: after a tool result the CLI delivers the rest of the reply in one piece when it is fully written (about 10 s of silence for a long answer, measured), while the answer to a new message streams normally. The session file format is internal to Claude Code and may change, so the reader fails softly (empty list or a "could not read" message). The follow-up counts toward the 8-turn rotation, and rotation drops the digest from context. Test the reader on real files with `tools/claude_code_session_reader_test.swift`.
- **Long-term memory**: one plain-text notes file, `~/.claude/buddy-memory/MEMORY.md` (`ClickyMemoryStore`), one fact per line under three headings (About the user, How the user wants you to behave, Ongoing work); each line is `- [date] [said] m-0001 text`. Loading: `makeVoiceSystemPrompt` appends the file's text (first 200 lines or 25KB) to the system prompt each time a CLI process starts, so using a note costs no tool call. The app loads it on purpose, not the CLI's `autoMemoryDirectory` setting (which also works but adds Claude Code's own memory instructions and background features). Writing: Claude writes `<remember section="user|behavior|work">text</remember>`, `<remember replaces="m-0012">text</remember>` or `<forget id="m-0012"/>` inline; the parser reports them the moment they are parsed (their own output case, like `<read_session/>`) and `CompanionManager.handleMemoryWriteRequest` applies them as single-line edits off the main thread. Replaced and forgotten lines go to `archive.md`, every request is recorded in `memory-log.jsonl`, and ids are never reused. Limits enforced in code: one line per note (240 characters), 3 writes per reply, no writes in a reply that read a session (notes may only come from what the user said), unknown ids rejected. A reply that is nothing but a tag gets a spoken "okay, i've updated my notes." so a change is never silent. A rejected write is reported back to Buddy with the next question. Because the running process only saw the notes at its start, changes made since then are appended to each question (`memoryChangesSinceNotesWereLoaded`), which is what lets Buddy correct a note it saved a moment ago. The user can edit the file by hand (panel row "Memory > Open notes"); edits are line by line and unrecognised lines are kept as they are. Not built yet: the tidy-up run for a long file (a `memory_file_long` event is logged at 120 notes), and any link to Claude Code's or the Claude account's memory. Design and sources: `reports/Agent memory design for Buddy.md`. Tests: `tools/memory_store_test.swift`, and the memory cases in `tools/inline_mark_parser_split_test.swift` (which now also compiles `ClickyMemoryStore.swift`).
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: Disabled. `ClickyAnalytics.swift` keeps the function names as no-ops (upstream sent transcripts to the original author's PostHog).

### API Proxy (Cloudflare Worker) — legacy, unused by the voice pipeline

Upstream routed all API calls through this Worker. This fork no longer uses it for Claude or TTS. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Local Voice Server (tts-server/)

- `tts-server/setup.sh` creates `tts-server/.venv` (Python 3.12, `requirements.txt`, pins `mlx-audio==0.6.4`) and downloads `mlx-community/pocket-tts` into the Hugging Face cache. `.venv/` and `voice-samples/` are git-ignored.
- The app finds the server via Info.plist `LocalVoiceServerDirectory` (`$(PROJECT_DIR)/tts-server`), falling back to `~/dev/my-clicky/tts-server`.
- The server runs with `HF_HUB_OFFLINE=1` (an online version check made startup ~35s instead of <1s) and exits when its stdin closes, so it never outlives Clicky.
- Test by hand: `CLICKY_VOICE_SERVER_TOKEN=test tts-server/.venv/bin/python -I tts-server/pocket_tts_server.py`, then `curl -H 'X-Clicky-Token: test' -X POST 127.0.0.1:<port>/speak -d '{"text":"hi"}' > out.pcm`.
- `tts-server/benchmark_voices.py` compares local voices (Kokoro, Pocket TTS, Qwen3-TTS) and writes samples into `voice-samples/`.
- `/transcribe` takes raw PCM16 mono 16 kHz and returns `{"text", "msToTranscribe"}` (~50ms for a 5s clip once warm). The Parakeet model loads on a background thread after the ready line (~4s); until then it answers 503. Both models share one lock. `transcript_final` logs `transcriber` (`parakeet`, or `apple-speech (parakeet: reason)`) and `msParakeetRequest`.
- Log events: `voice_server_launching`, `voice_server_ready`, `voice_server_exited`, `voice_server_not_set_up`, `voice_sentence_first_audio`, `voice_fell_back_to_apple`, `voice_audio_engine_configuration_changed`. The `interaction_summary.voice` field says which backend spoke each reply (`pocket-tts` or `apple-speech: ...`).

## Local Diagnostic Logs (read these when the user reports what Clicky did)

Clicky writes a local-only log of every push-to-talk interaction to `~/Library/Logs/Clicky/` (never uploaded):

- `events-YYYY-MM-DD.jsonl`: one JSON object per line. Each push-to-talk has an `interaction` ID (e.g. `20261108-114502-3fa1`) and events carry `msSinceHotkeyPressed`. Event sequence: `hotkey_pressed` → `hotkey_released` → `transcript_final` (what it heard) → `screenshots_captured` (per-screen sizes, display frames, saved file paths) → `turn_sent_to_claude` → `first_text_from_claude` → `point_tool_called` (screenshot pixel coords, screen, mapped global coords) → `first_audio` → `reply_completed` (full spoken text) → `speech_finished` → `interaction_summary` (outcome + latencies like `msReleaseToFirstAudio`). Also `app_launched`, `cli_session_started`, `cli_session_exited` (with stderr), `cli_turn_error`, `turn_failed`. Pen: `mark_parsed` (raw tag, offset in spoken text), `mark_fired` (clockSource, msSinceFirstAudio, cursor destination), `mark_dropped` (reason). Board: `board_shown` (title), `draw_step_fired` (snippet, revealDurationSeconds, spokenCharactersPacedBy, itemsDrawn), `draw_step_error` (snippet + JavaScript error), `board_snapshot_saved` (`interactions/<id>/board.png`, the finished board ~2s after the voice ends), `board_closed_by_user`. `reply_completed` has both `reply` (spoken) and `replyWithMarks` (raw). Session reads: `session_read_requested` (raw tag, whether the session was found, its title, `leadInSpokenBy` claude or app), `session_digest_sent` (outcome, digest size, never its content), `first_text_after_session_read`, `session_read_ignored` (past the per-reply limit), `session_read_abandoned`. `turn_sent_to_claude` has `claudeCodeSessionsListed`, `reply_completed` has `sessionsRead`, and `interaction_summary` has `msTurnSentToSessionReadRequested` and `msSessionReadRequestedToAnswerText`. In a reply that read a session, `first_audio` is the lead-in. Memory: `memory_saved`, `memory_replaced`, `memory_forgotten` (note id, the line, total notes), `memory_write_rejected` (unknown id, empty note), `memory_write_dropped` (reply read a session, or too many writes), `memory_file_long`; `reply_completed` has `memoryWrites`. Latency debugging: `cli_stream_timeline` (when each text/tool block arrived from the CLI, measured off the main thread), `voice_sentence_queued` (when each sentence was handed to the voice), `voice_audio_engine_started` (engine start cost), and `main_thread_stall` (main thread unresponsive for 250ms or more). Event timestamps are taken on the main thread, so compare against `cli_stream_timeline` and `main_thread_stall` before blaming Claude or the voice.
- `interactions/<interactionID>/screenN.jpg`: the exact screenshots Claude saw for that turn. `board.png`: the board at the end of the reply, when Claude drew on it. Combine with `point_tool_called` coordinates to check pointing accuracy.
- Retention: screenshots 7 days, events 30 days (cleaned at launch).

Quick look at the latest interactions: `tail -n 40 ~/Library/Logs/Clicky/events-$(date +%F).jsonl`

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~2390 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~900 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the Core cursor (`ClickyCoreBuddyCursorView`) and its speech bubbles. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `ClickyCoreBuddyCursorView.swift` | ~230 | Clicky's cursor, "Core": a navy orb with a cyan rim and cyan pill eyes. One view for every state with expressions (idle blinks, listening ring that swells with your voice, thinking HUD ring, happy eyes + equalizer mouth while speaking, eyes that look along the flight path and at the target). Colors `DS.Colors.overlayCoreBuddyBody` / `overlayCoreBuddyCyan`. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `ParakeetTranscriptionProvider.swift` | ~300 | Push-to-talk transcription with Parakeet through the local voice server, with an Apple Speech session running alongside for live text and fallback. `ClickyLastTranscriptReport` tells the log which engine answered. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeCLIVoiceSession.swift` | ~450 | Warm Claude Code CLI process (stream-json). Clean env so it uses the user's `claude auth login`, drains stderr, interrupts turns via `control_request`, joins text across tool calls, maps CLI errors to spoken reasons, `claude auth status` check. |
| `ClickyLocalToolServer.swift` | ~270 | Minimal MCP server over HTTP (Network.framework) on loopback with a secret path. Exposes the `point` tool; answers immediately and forwards calls to the main thread. |
| `StreamingSentenceSpeaker.swift` | ~920 | Speaks streamed text sentence by sentence: Pocket TTS audio streamed from the local voice server into AVAudioEngine (odd-byte-safe PCM16 decoding, engine restart on device changes, barge-in cancels the in-flight request), with Apple AVSpeechSynthesizer as per-reply fallback. |
| `LocalVoiceServer.swift` | ~270 | Launches/supervises `tts-server/pocket_tts_server.py` (`LocalVoiceServer.shared`, used for speaking and transcribing): clean env + secret token, reads the JSON ready line (port, sample rate), drains stderr, logs exits, rate-limited restarts. |
| `ClickyInlineMarkParser.swift` | ~470 | Streaming parser that splits Claude's reply into speakable text, pen/board marks, `<read_session/>` requests and memory writes (`<remember>`, `<forget>`); only `<` + a known mark name starts a tag; `<draw>` bodies are read until `</draw>`; drops malformed/overlong tags. Tested by `tools/inline_mark_parser_split_test.swift`. |
| `ClickyClaudeCodeSessionReader.swift` | ~370 | Lists the user's recent Claude Code sessions and builds a readable digest of one (latest summary plus the typed conversation since) from the local session files. Off the main thread, cached per file by size and modification date, fails softly. Tested by `tools/claude_code_session_reader_test.swift`. |
| `ClickyMemoryStore.swift` | ~410 | Buddy's long-term memory on disk: loads the notes for the prompt and applies remember/replace/forget as single-line edits to `~/.claude/buddy-memory/MEMORY.md`, with an archive and a write log. Tolerates hand edits. Tested by `tools/memory_store_test.swift`. |
| `ClickyBoardPanelManager.swift` | ~500 | The board window: NSPanel + WKWebView, title bar, resize grip, runs draw snippets (`callAsyncJavaScript`), board state note for Claude, PNG snapshot for the log. |
| `ClickyBoard/clicky-board.js` | ~920 | The board's drawing API (text, math, shapes, polygon sides, angles, braces, connect, highlight, tables, axes/plot/shade) and the stroke-reveal timing. Lives next to `clicky-board.html`/`.css`, rough.js, KaTeX and its fonts, and `ClickyBoard-THIRD-PARTY-LICENSES.txt`. |
| `ClickyScreenMarksOverlay.swift` | ~300 | Mark/flight models and the SwiftUI pen-stroke views (seeded hand-drawn loop, underline, highlighter sweep, arrow). |
| `ClickyLocalTelemetry.swift` | ~170 | Local-only JSONL event log + per-interaction screenshots in `~/Library/Logs/Clicky/`, with retention cleanup. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
