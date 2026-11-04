"""Kokoro voice lines for the demo video.

Run with the manim-dsa venv, which has kokoro_onnx and the v1.0 model:
    ~/Development/manim-dsa/.venv/bin/python demo/tts.py demo/lines.json demo/audio

lines.json: [{"id": "n01", "voice": "af_heart", "text": "...", "speed": 1.0}, ...]
Writes <id>.wav (24 kHz mono 16-bit, the format Muse Voice Transcribe takes) and durations.json.
"""
import json
import sys
import wave
from pathlib import Path

import numpy as np
from kokoro_onnx import Kokoro

MODELS = Path.home() / "Development/manim-dsa/models/kokoro"


def main(lines_path: str, out_dir: str) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    kokoro = Kokoro(str(MODELS / "kokoro-v1.0.onnx"), str(MODELS / "voices-v1.0.bin"))
    durations = {}
    for line in json.loads(Path(lines_path).read_text()):
        samples, rate = kokoro.create(line["text"], voice=line["voice"], speed=line.get("speed", 1.0), lang="en-us")
        pcm = (np.clip(samples, -1, 1) * 32767).astype(np.int16)
        with wave.open(str(out / f"{line['id']}.wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(pcm.tobytes())
        durations[line["id"]] = round(len(pcm) / rate, 2)
        print(f"{line['id']}: {durations[line['id']]}s  {line['text'][:60]}")
    (out / "durations.json").write_text(json.dumps(durations, indent=2))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
