# Text after a tool result is not streamed in `--output-format stream-json`; it arrives in one burst when the reply is complete

## Summary

In headless stream-json mode with `--include-partial-messages`, a reply with no tool call streams its `text_delta` events steadily. A reply that follows a tool result does not: all of its `text_delta` events arrive within about 10 ms of each other, at the moment the reply finishes. The time to the first word after a tool call therefore grows with the length of the answer.

This makes tool use impractical for anything that speaks or displays output as it streams, such as a voice interface.

## Environment

- Claude Code 2.1.319, macOS 27.2 (Apple silicon)
- Signed in with a Claude subscription (no API key)
- Reproduced with `claude-opus-5-5` and `claude-sonnet-5-5`, `--effort low`

## Steps to reproduce

Run the attached script (`claude_cli_streaming_after_tool_repro.py`, about 100 lines of Python, no dependencies). It creates a three-sentence `note.txt` in a temporary folder and sends one request twice:

- **A. No tool:** the note's text is pasted into the prompt.
- **B. With a tool:** the prompt asks Claude to read `note.txt` first, with only the built-in `Read` tool enabled.

Both ask for about 250 words. The CLI is started with:

```
claude -p --input-format stream-json --output-format stream-json --verbose \
  --include-partial-messages --model <model> --effort low \
  --system-prompt "you are a helpful assistant." \
  --tools <"" or "Read"> --setting-sources "" --strict-mcp-config --no-session-persistence
```

The script records when each `content_block_delta` with a `text_delta` arrives on stdout.

## Expected

In run B, after the tool result, text deltas arrive steadily as the answer is generated, as they do in run A.

## Actual

| Model | Run | Answer length | First text delta | Last text delta | Spread |
|---|---|---|---|---|---|
| claude-opus-5-5 | A. no tool | 1,383 chars, 85 deltas | 1.66 s | 5.88 s | 4.22 s |
| claude-opus-5-5 | B. after `Read` | 1,429 chars, 107 deltas | 8.50 s | 8.51 s | 0.01 s |
| claude-sonnet-5-5 | A. no tool | 1,259 chars, 107 deltas | 1.15 s | 4.92 s | 3.77 s |
| claude-sonnet-5-5 | B. after `Read` | 1,289 chars, 108 deltas | 6.16 s | 6.17 s | 0.01 s |

Times are seconds since the request was written to stdin. In run B the tool result came back at 2.39 s (Opus) and 1.72 s (Sonnet), so the wait from tool result to first text was about 6.1 s and 4.4 s, roughly the time run A took to generate the same amount of text.

## Further observations

- **Same result with an MCP tool.** In a larger setup with an HTTP MCP tool and a longer answer (1,500 to 1,900 characters), the first text arrived 10 to 11 seconds after the request, in one burst, in every run.
- **The burst is present inside the CLI, before stdout.** With `--debug-file`, the `[engine] yield stream_event` lines for the request after the tool result show 4 events in the first 3 seconds, none for about 7 seconds, then 158 events within one second. The preceding request in the same process (text, then the tool call) was logged arriving steadily.
- **On Opus a thinking block spans the wait.** A `thinking` content block opens about 0.6 s after the tool result and its `signature_delta` arrives together with the text burst, while `thinking_tokens` estimates stop growing after about 3 s. On Sonnet the same burst occurred in a run where no thinking block was reported, so the hold does not appear to depend on thinking.
- **Text before the tool call streams normally.**
- **A tool that is offered but not called does not trigger it.**
- **A workaround confirms the answer could stream.** Ending the reply and sending the tool's content as a new user message produces a normal, steadily streamed answer of the same length.

## Settings tried, with no change

`MAX_THINKING_TOKENS=0`, `DISABLE_INTERLEAVED_THINKING=1`, `CLAUDE_CODE_DISABLE_THINKING=1`, `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1`, `--settings '{"alwaysThinkingEnabled": false}'`, `--settings '{"showThinkingSummaries": true}'`, and omitting `--effort`. `CLAUDE_CODE_STREAM_EVENT_HOLD_MS` was not set.

## Questions

1. Is holding the text that follows a tool result intended? If so, is there a way to opt out?
2. If it is not intended, is the hold in the API's stream or in the CLI's client layer?
