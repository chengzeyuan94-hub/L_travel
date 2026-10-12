#!/usr/bin/env python3
"""Phase C audio asset step (docs/design/shanhe-luren/sound-20260926/README.md, plan.md §4.4).

1. Movement loops: the two AudioManager movement loops keep their file names (tests and
   AudioManager load them by name) but get new content:
     assets/audio/sfx/camel_walk_loop_v1.wav  <- assets/audio/ambience/hooves_walk_loop_v1.ogg (horse hooves)
     assets/audio/sfx/ship_sail_loop_v1.wav   <- assets/audio/ambience/rowing_loop_v1.ogg (rowing)
   Both are decoded to 44.1 kHz / 16-bit PCM mono WAV (AudioStreamWAV + LOOP_FORWARD, compress/mode=0).
   The ogg loops are already seamless at the file boundary (render.py splice/crossfade), so the
   decoded WAV loops seamlessly from sample 0 to the last sample.
2. Title BGM: assets/audio/title/title_bgm_loop_v1.wav had a true peak of +0.5 dBTP. It is scaled
   down by GAIN_DB (pure gain, so the loop seam and the mix are unchanged) to about -1.1 dBTP; the
   title screen and SoundDirector raise their volume_db by the same amount, so what players hear is
   unchanged. Idempotent: the gain is only applied while the file's true peak is above -1.0 dBTP.

Run from the repo root:  python3 tools/audio/phase_c_assets.py
Needs ~/.local/bin/ffmpeg (decode and true-peak measurement). Pure python otherwise (no numpy).
"""
import array
import os
import re
import subprocess
import sys
import wave

FFMPEG = os.path.expanduser("~/.local/bin/ffmpeg")
GAIN_DB = -1.6
TITLE = "assets/audio/title/title_bgm_loop_v1.wav"
MOVES = [
    ("assets/audio/ambience/hooves_walk_loop_v1.ogg", "assets/audio/sfx/camel_walk_loop_v1.wav"),
    ("assets/audio/ambience/rowing_loop_v1.ogg", "assets/audio/sfx/ship_sail_loop_v1.wav"),
]


def true_peak(path: str) -> float:
    out = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    m = re.findall(r"True peak:\s*\n\s*Peak:\s*(-?[\d.]+|-inf)", out)
    return float(m[-1]) if m else float("nan")


def decode_mono_pcm16(src: str, dst: str) -> None:
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-map_metadata", "-1",
                    "-fflags", "+bitexact", "-flags:a", "+bitexact", "-ac", "1", "-ar", "44100",
                    "-c:a", "pcm_s16le", dst], check=True)
    with wave.open(dst) as w:
        print(f"{dst}: {w.getnframes()} frames, {w.getnframes() / w.getframerate():.3f} s, {w.getnchannels()} ch, "
              f"TP {true_peak(dst):+.1f} dBTP")


def scale_title() -> None:
    tp = true_peak(TITLE)
    if tp <= -1.0:
        print(f"{TITLE}: true peak {tp:+.1f} dBTP already <= -1.0, unchanged")
        return
    with wave.open(TITLE) as w:
        params = w.getparams()
        raw = w.readframes(w.getnframes())
    assert params.sampwidth == 2, "expects 16-bit PCM"
    a = array.array("h")
    a.frombytes(raw)
    if sys.byteorder != "little":
        a.byteswap()
    g = 10.0 ** (GAIN_DB / 20.0)
    b = array.array("h", (max(-32768, min(32767, int(round(s * g)))) for s in a))
    if sys.byteorder != "little":
        b.byteswap()
    with wave.open(TITLE, "wb") as w:
        w.setparams(params)
        w.writeframes(b.tobytes())
    print(f"{TITLE}: {tp:+.1f} dBTP -> {true_peak(TITLE):+.1f} dBTP (gain {GAIN_DB} dB)")


if __name__ == "__main__":
    for src, dst in MOVES:
        decode_mono_pcm16(src, dst)
    scale_title()
