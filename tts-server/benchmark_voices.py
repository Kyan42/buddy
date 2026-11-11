"""Benchmark local TTS candidates on this Mac: load time, time-to-first-audio, real-time factor.
Writes one sample WAV per candidate (same 3 sentences) into OUT_DIR."""
import sys, time, os, traceback
try:
    import espeakng_loader
    os.environ["ESPEAK_DATA_PATH"] = espeakng_loader.get_data_path()
    os.environ["PHONEMIZER_ESPEAK_LIBRARY"] = espeakng_loader.get_library_path()
except Exception as e:
    print("espeak setup:", e)
import numpy as np
import soundfile as sf
import mlx.core as mx
from mlx_audio.tts.utils import load_model

OUT_DIR = sys.argv[1]
ONLY = sys.argv[2:]  # optional subset of candidate keys
os.makedirs(OUT_DIR, exist_ok=True)

SENTENCES = [
    "Click the 808 Snare button in the channel rack, right here.",
    "That opens its settings, where you can load a different sample.",
    "The faster way is to drag a new snare from the browser on the left straight onto that button.",
]

CANDIDATES = {
    "kokoro_heart": dict(repo="mlx-community/Kokoro-82M-bf16", kwargs=dict(voice="af_heart", lang_code="a")),
    "kokoro_michael": dict(repo="mlx-community/Kokoro-82M-bf16", kwargs=dict(voice="am_michael", lang_code="a")),
    "phonon_40m": dict(repo="gradium/phonon-40m-en", kwargs=dict(), stream=True),
    "pocket_tts": dict(repo="mlx-community/pocket-tts", kwargs=dict(), stream=True),
    "qwen3_0.6b_ryan": dict(repo="mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16", custom_speaker="ryan", stream=True),
    "qwen3_1.7b_ryan": dict(repo="mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit", custom_speaker="ryan", stream=True),
}

def to_np(audio):
    return np.array(audio.astype(mx.float32) if hasattr(audio, "astype") else audio, dtype=np.float32).reshape(-1)

def synth(model, spec, text):
    """Returns (seconds_to_first_audio_chunk, total_seconds, audio_np, sample_rate)."""
    t0 = time.perf_counter()
    if "custom_speaker" in spec:
        gen = model.generate_custom_voice(text=text, speaker=spec["custom_speaker"], language="English",
                                          stream=spec.get("stream", False), streaming_interval=0.4)
    elif spec.get("stream"):
        gen = model.generate(text=text, stream=True, streaming_interval=0.4, **spec.get("kwargs", {}))
    else:
        gen = model.generate(text=text, **spec.get("kwargs", {}))
    first, chunks, sr = None, [], None
    for result in gen:
        arr = to_np(result.audio)
        if first is None and arr.size:
            first = time.perf_counter() - t0
        chunks.append(arr)
        sr = getattr(result, "sample_rate", None) or getattr(model, "sample_rate", 24000)
    total = time.perf_counter() - t0
    audio = np.concatenate(chunks) if chunks else np.zeros(1, np.float32)
    return first or total, total, audio, sr

results = []
for key, spec in CANDIDATES.items():
    if ONLY and key not in ONLY:
        continue
    print(f"== {key} ({spec['repo']})", flush=True)
    try:
        t = time.perf_counter()
        model = load_model(spec["repo"])
        load_s = time.perf_counter() - t
        synth(model, spec, "Warming up.")  # first call compiles kernels
        firsts, totals, audios, durs, sr = [], [], [], [], 24000
        for sentence in SENTENCES:
            first, total, audio, sr = synth(model, spec, sentence)
            firsts.append(first); totals.append(total); audios.append(audio); durs.append(len(audio) / sr)
        gap = np.zeros(int(sr * 0.25), np.float32)
        sample = np.concatenate([np.concatenate([a, gap]) for a in audios])
        path = os.path.join(OUT_DIR, f"{key}.wav")
        sf.write(path, sample, sr)
        rtf = sum(totals) / sum(durs)
        line = (f"{key:18s} load {load_s:5.1f}s | first audio (sentence 1) {firsts[0]*1000:5.0f} ms | "
                f"median first audio {sorted(firsts)[1]*1000:5.0f} ms | real-time factor {rtf:.2f} | "
                f"peak mem {mx.get_peak_memory()/1e9:.1f} GB")
        print(line, flush=True); results.append(line)
        del model; mx.clear_cache(); mx.reset_peak_memory()
    except Exception as e:
        print(f"   FAILED: {type(e).__name__}: {e}", flush=True)
        traceback.print_exc(limit=2)

print("\nSUMMARY"); [print(r) for r in results]
