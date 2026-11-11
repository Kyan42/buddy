"""Voice-turn latency test: warm Claude Code CLI session (stream-json), screenshot + question.

Usage: python3 latency.py <model> <screenshot.jpg> [turns]
Times are measured from the moment the user message is written (= "you stopped talking,
transcript ready"). Speech-to-text time is NOT included.
"""
import base64, json, os, re, subprocess, sys, time, threading, queue, statistics

CLAUDE = os.path.expanduser("~/.local/bin/claude")
MODEL, IMG = sys.argv[1], sys.argv[2]
TURNS = int(sys.argv[3]) if len(sys.argv) > 3 else 5

SYSTEM = (
    "you're a voice buddy that can see the user's screen. replies are spoken aloud, so talk "
    "casually, no markdown or lists. start with one short sentence that answers directly, "
    "then add at most two more short sentences."
)
QUESTIONS = [
    "what app am i looking at right now?",
    "how do i add a kick drum on every beat here?",
    "what's the tempo set to?",
    "where would i click to change the snare sound?",
    "give me one tip to make this beat sound better.",
]

# Clean environment: only what a normal login shell would have, so the CLI uses
# the user's own `claude auth login` subscription credentials.
env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "LANG", "TERM", "TMPDIR") if k in os.environ}
env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + os.path.expanduser("~/.local/bin")

cmd = [CLAUDE, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
       "--verbose", "--include-partial-messages", "--model", MODEL,
       "--system-prompt", SYSTEM, "--tools", "", "--setting-sources", "",
       "--strict-mcp-config", "--no-session-persistence"]

img_b64 = base64.b64encode(open(IMG, "rb").read()).decode()

t_spawn = time.perf_counter()
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        env=env, cwd=os.environ.get("TMPDIR", "/tmp"), text=True, bufsize=1)
lines = queue.Queue()
threading.Thread(target=lambda: [lines.put(l) for l in proc.stdout], daemon=True).start()
errs = []
threading.Thread(target=lambda: [errs.append(l) for l in proc.stderr], daemon=True).start()

SENT_END = re.compile(r"[.!?](\s|$)")

def turn(question, with_image=True):
    content = []
    if with_image:
        content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": img_b64}})
    content.append({"type": "text", "text": question})
    msg = {"type": "user", "message": {"role": "user", "content": content}}
    t0 = time.perf_counter()
    proc.stdin.write(json.dumps(msg) + "\n"); proc.stdin.flush()
    text, first_tok, first_sent = "", None, None
    while True:
        try:
            line = lines.get(timeout=120)
        except queue.Empty:
            raise SystemExit("timeout waiting for CLI output; stderr:\n" + "".join(errs[-20:]))
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "stream_event":
            e = ev.get("event", {})
            if e.get("type") == "content_block_delta" and e.get("delta", {}).get("type") == "text_delta":
                now = time.perf_counter() - t0
                if first_tok is None:
                    first_tok = now
                text += e["delta"]["text"]
                if first_sent is None and SENT_END.search(text):
                    first_sent = now
        elif ev.get("type") == "result":
            done = time.perf_counter() - t0
            if ev.get("is_error"):
                raise SystemExit("CLI error: " + json.dumps(ev)[:600])
            return first_tok, first_sent or done, done, text.strip()

def tts_time(sentence):
    out = os.path.join(os.environ.get("TMPDIR", "/tmp"), "lat_tts.aiff")
    t = time.perf_counter()
    subprocess.run(["say", "-o", out, sentence], check=True)
    return time.perf_counter() - t

rows = []
for i, q in enumerate(QUESTIONS[:TURNS]):
    ft, fs, done, text = turn(q)
    first_sentence = SENT_END.split(text, maxsplit=1)[0][:200] or text[:200]
    tts = tts_time(first_sentence)
    label = "cold" if i == 0 else "warm"
    if i == 0:
        print(f"[{MODEL}] process start -> first turn done: {time.perf_counter() - t_spawn:.2f}s (includes CLI startup)")
    print(f"  turn {i+1} ({label}): first word {ft:.2f}s | first sentence {fs:.2f}s | full reply {done:.2f}s "
          f"| local TTS of sentence 1 {tts:.2f}s")
    print(f"     Q: {q}\n     A: {text[:220]}")
    if i > 0:
        rows.append((ft, fs, done, tts))

if rows:
    med = lambda k: statistics.median(r[k] for r in rows)
    print(f"[{MODEL}] WARM MEDIANS: first word {med(0):.2f}s | first sentence {med(1):.2f}s | "
          f"full reply {med(2):.2f}s | local TTS {med(3):.2f}s | est. time-to-first-audio "
          f"{med(1) + med(3):.2f}s (+ speech-to-text finalize)")
proc.stdin.close()
proc.wait(timeout=30)
