"""Minimal reproduction: in stream-json mode, the text that follows a tool result
arrives in one burst when the reply is finished, while a reply with no tool call
streams normally.

Run:  python3 tools/claude_cli_streaming_after_tool_repro.py [model]

It runs the same request twice in a temporary folder, using only the built-in
Read tool and a file it creates there:

  A. no tool:   the note's text is pasted into the prompt.
  B. with tool: the prompt asks Claude to read the note file first.

For each run it prints when the text deltas arrived. No personal data is used.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

CLAUDE_PATH = os.path.expanduser('~/.local/bin/claude')
MODEL = sys.argv[1] if len(sys.argv) > 1 else 'claude-opus-5-5'
NOTE_TEXT = (
    'The lighthouse at Marrow Point was built in 1887 from local granite. '
    'Its lamp burned whale oil until 1902, then kerosene, and was electrified in 1931. '
    'The last keeper, Edda Thorne, left in 1968 when the light was automated.'
)
TASK = 'write about 250 words, in plain sentences, retelling the history in this note for a child.'


def run_once(label, prompt, allowed_tools, working_folder):
    arguments = [
        CLAUDE_PATH, '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose',
        '--include-partial-messages', '--model', MODEL, '--effort', 'low',
        '--system-prompt', 'you are a helpful assistant.',
        '--tools', allowed_tools, '--setting-sources', '', '--strict-mcp-config', '--no-session-persistence',
    ]
    if allowed_tools:
        arguments += ['--allowedTools', allowed_tools]
    cli_process = subprocess.Popen(
        arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        cwd=working_folder, text=True, bufsize=1,
    )
    sent_at = time.time()
    user_message = {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': prompt}]}}
    cli_process.stdin.write(json.dumps(user_message) + '\n')
    cli_process.stdin.flush()

    tool_result_at = None
    thinking_opened_at = []
    text_delta_times_before_tool = []
    text_delta_times_after_tool = []
    text_characters_after_tool = 0
    finished_at = None
    for line in cli_process.stdout:
        seconds = time.time() - sent_at
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get('type') == 'user':
            tool_result_at = seconds
        elif event.get('type') == 'result':
            finished_at = seconds
            break
        elif event.get('type') == 'stream_event':
            stream_event = event.get('event') or {}
            if stream_event.get('type') == 'content_block_start' and (stream_event.get('content_block') or {}).get('type') == 'thinking':
                thinking_opened_at.append(round(seconds, 2))
            delta = stream_event.get('delta') or {}
            if stream_event.get('type') == 'content_block_delta' and delta.get('type') == 'text_delta':
                if tool_result_at is None and allowed_tools:
                    text_delta_times_before_tool.append(seconds)
                else:
                    text_delta_times_after_tool.append(seconds)
                    text_characters_after_tool += len(delta.get('text', ''))
    cli_process.stdin.close()
    cli_process.wait(timeout=30)

    print(f'--- {label}')
    if allowed_tools:
        print(f'    tool result returned at: {tool_result_at and round(tool_result_at, 2)} s')
    print(f'    thinking blocks opened at: {thinking_opened_at} s')
    if text_delta_times_after_tool:
        first_text, last_text = text_delta_times_after_tool[0], text_delta_times_after_tool[-1]
        print(f'    answer text: {text_characters_after_tool} characters in {len(text_delta_times_after_tool)} deltas')
        print(f'    first text delta at {first_text:.2f} s, last at {last_text:.2f} s  ->  spread {last_text - first_text:.2f} s')
    else:
        print('    no answer text received')
    print(f'    reply finished at: {finished_at and round(finished_at, 2)} s')


if __name__ == '__main__':
    version = subprocess.run([CLAUDE_PATH, '--version'], capture_output=True, text=True).stdout.strip()
    print(f'claude {version}, model {MODEL}')
    with tempfile.TemporaryDirectory() as working_folder:
        with open(os.path.join(working_folder, 'note.txt'), 'w') as note_file:
            note_file.write(NOTE_TEXT)
        run_once('A. no tool call', f'here is a note:\n\n{NOTE_TEXT}\n\n{TASK}', '', working_folder)
        run_once('B. after a Read tool call', f'read the file note.txt in the current folder, then {TASK}', 'Read', working_folder)
