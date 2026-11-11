"""
Clicky's local voice server: Pocket TTS on Apple Silicon (MLX), loopback only.

Clicky launches this script at startup and keeps it running. It loads the model
once, warms it up, then prints a single JSON "ready" line on stdout:

    {"ready": true, "port": 52811, "sampleRate": 24000, "model": "...", "msToReady": 1234}

API (only on 127.0.0.1, and every request must carry the secret token Clicky
passes in the CLICKY_VOICE_SERVER_TOKEN environment variable):

    POST /speak   body: {"text": "one sentence"}
                  header: X-Clicky-Token: <token>
                  response: raw little-endian 16-bit mono PCM at `sampleRate`,
                  streamed as it's generated, connection closed at the end.

    POST /transcribe  body: raw little-endian 16-bit mono PCM at 16 kHz
                      (what the microphone heard during push-to-talk)
                      header: X-Clicky-Token: <token>
                      response: {"text": "...", "msToTranscribe": 123}
                      503 while the speech-to-text model is still loading.
                  Speech-to-text is Parakeet TDT 0.6B v2 (NVIDIA, English),
                  loaded in the background after the ready line so the voice
                  is never held up by it.

    GET /health   -> {"ok": true, "transcriberReady": true|false}

Requests are served one at a time (there's a single model). Clicky sends
sentences in order, so that's what it wants anyway.

Run by hand for testing:
    CLICKY_VOICE_SERVER_TOKEN=test .venv/bin/python -I pocket_tts_server.py
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

import numpy as np
import mlx.core as mx
from huggingface_hub import snapshot_download
from mlx_audio.tts.utils import load_model

MODEL_REPO = os.environ.get("CLICKY_VOICE_MODEL", "mlx-community/pocket-tts")
TRANSCRIBER_MODEL_REPO = os.environ.get("CLICKY_TRANSCRIBER_MODEL", "mlx-community/parakeet-tdt-0.6b-v2")
TRANSCRIBER_SAMPLE_RATE = 16000
# Very long recordings are transcribed in overlapping pieces so memory stays flat.
TRANSCRIBER_CHUNK_SECONDS_FOR_LONG_AUDIO = 60.0
SECRET_TOKEN = os.environ.get("CLICKY_VOICE_SERVER_TOKEN", "")
# Smaller interval = the first audio arrives sooner. 0.25s of audio per chunk
# is ~6k samples, small enough to start fast and big enough to stay efficient.
STREAMING_INTERVAL_SECONDS = 0.25

startup_began = time.perf_counter()

# Load from the local Hugging Face cache without touching the network: an online
# "is there a newer version?" check made startup take ~35s instead of ~0.6s.
# Only download if the model isn't cached yet (first run).
try:
    local_model_path = snapshot_download(MODEL_REPO, local_files_only=True)
except Exception:
    local_model_path = snapshot_download(MODEL_REPO)
voice_model = load_model(local_model_path)
sample_rate = int(getattr(voice_model, "sample_rate", 24000))
# One lock for both models: MLX shares the GPU, and Clicky never needs to
# speak and transcribe at the same moment (it stops talking when you press
# push-to-talk), so taking turns costs nothing and avoids surprises.
model_lock = threading.Lock()

# The speech-to-text model loads on a background thread after the server is
# ready. Until then /transcribe answers 503 and Clicky uses Apple Speech.
transcriber_model = None


def load_transcriber_in_background():
    global transcriber_model
    try:
        from mlx_audio.stt import load as load_speech_to_text_model
        try:
            snapshot_download(TRANSCRIBER_MODEL_REPO, local_files_only=True)
        except Exception:
            # Not downloaded yet (setup.sh downloads it). Don't fetch ~600 MB
            # silently from inside Clicky; it just keeps using Apple Speech.
            print(f"transcriber model {TRANSCRIBER_MODEL_REPO} is not downloaded; run setup.sh", file=sys.stderr, flush=True)
            return
        # Loaded by name, not by cache path: mlx-audio works out the model type
        # from the name ("parakeet"), and the cache folder is just a hash.
        # Clicky runs us with HF_HUB_OFFLINE=1, so this reads the local cache.
        loaded_model = load_speech_to_text_model(TRANSCRIBER_MODEL_REPO)
        # Warm-up compiles the MLX kernels so the first real push-to-talk is fast.
        with model_lock:
            loaded_model.generate(mx.zeros((TRANSCRIBER_SAMPLE_RATE,), dtype=mx.float32))
        transcriber_model = loaded_model
    except Exception as loading_error:
        print(f"transcriber failed to load: {loading_error!r}", file=sys.stderr, flush=True)


def float_audio_to_pcm16_bytes(audio_chunk) -> bytes:
    samples = np.array(audio_chunk.astype(mx.float32), dtype=np.float32).reshape(-1)
    samples = np.clip(samples, -1.0, 1.0)
    return (samples * 32767.0).astype("<i2").tobytes()


# Warm-up compiles the MLX kernels so the first real sentence is fast.
for _ in voice_model.generate(text="Warming up.", stream=True, streaming_interval=STREAMING_INTERVAL_SECONDS):
    pass


class VoiceRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # body ends when the connection closes

    def log_message(self, format, *args):
        pass  # keep stdout clean; Clicky only reads the ready line

    def _is_authorized(self) -> bool:
        return bool(SECRET_TOKEN) and self.headers.get("X-Clicky-Token") == SECRET_TOKEN

    def do_GET(self):
        if self.path != "/health" or not self._is_authorized():
            self.send_error(404)
            return
        body = json.dumps({"ok": True, "transcriberReady": transcriber_model is not None}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self._is_authorized() or self.path not in ("/speak", "/transcribe"):
            self.send_error(404)
            return
        if self.path == "/transcribe":
            self._handle_transcribe()
            return
        try:
            request_body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            text_to_speak = str(json.loads(request_body or b"{}").get("text", "")).strip()
        except (ValueError, TypeError):
            self.send_error(400)
            return
        if not text_to_speak:
            self.send_error(400)
            return

        self.send_response(200)
        self.send_header("Content-Type", "audio/L16")
        self.send_header("X-Sample-Rate", str(sample_rate))
        self.end_headers()

        with model_lock:
            try:
                for generated_chunk in voice_model.generate(
                    text=text_to_speak, stream=True, streaming_interval=STREAMING_INTERVAL_SECONDS
                ):
                    self.wfile.write(float_audio_to_pcm16_bytes(generated_chunk.audio))
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                # Clicky hung up (the user talked over it). Stop generating.
                pass


    def _handle_transcribe(self):
        if transcriber_model is None:
            self.send_error(503)
            return
        try:
            pcm16_audio_bytes = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        except ValueError:
            self.send_error(400)
            return
        # An odd trailing byte can't be a sample; drop it rather than fail.
        pcm16_audio_bytes = pcm16_audio_bytes[: len(pcm16_audio_bytes) - (len(pcm16_audio_bytes) % 2)]
        transcription_began = time.perf_counter()
        transcript_text = ""
        if pcm16_audio_bytes:
            audio_samples = np.frombuffer(pcm16_audio_bytes, dtype="<i2").astype(np.float32) / 32768.0
            audio_seconds = len(audio_samples) / TRANSCRIBER_SAMPLE_RATE
            with model_lock:
                try:
                    transcription_result = transcriber_model.generate(
                        mx.array(audio_samples),
                        chunk_duration=TRANSCRIBER_CHUNK_SECONDS_FOR_LONG_AUDIO if audio_seconds > TRANSCRIBER_CHUNK_SECONDS_FOR_LONG_AUDIO else None,
                    )
                    transcript_text = str(getattr(transcription_result, "text", "")).strip()
                except Exception as transcription_error:
                    print(f"transcribe failed: {transcription_error!r}", file=sys.stderr, flush=True)
                    self.send_error(500)
                    return
        body = json.dumps({
            "text": transcript_text,
            "msToTranscribe": int((time.perf_counter() - transcription_began) * 1000),
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", 0), VoiceRequestHandler)
ready_line = {
    "ready": True,
    "port": server.server_address[1],
    "sampleRate": sample_rate,
    "model": MODEL_REPO,
    "msToReady": int((time.perf_counter() - startup_began) * 1000),
}
print(json.dumps(ready_line), flush=True)

# Exit when Clicky goes away: our stdin is Clicky's pipe, which closes when it quits.
def exit_when_parent_closes_stdin():
    sys.stdin.read()
    os._exit(0)

threading.Thread(target=exit_when_parent_closes_stdin, daemon=True).start()
threading.Thread(target=load_transcriber_in_background, daemon=True).start()
server.serve_forever()
