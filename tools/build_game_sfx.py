#!/usr/bin/env python3
"""Build the first-pass Silk Road gameplay SFX pack.

Procedural UI/card/dice sounds are deterministic. Camel and ship loops are derived
from the motion-video source audio supplied by the product owner so the piece
movement keeps the same physical character as its source footage.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import wave

import numpy as np

SR = 44_100
RNG = np.random.default_rng(20260723)


def envelope(n: int, attack: float = 0.02, release: float = 0.12) -> np.ndarray:
    env = np.ones(n, dtype=np.float64)
    a = min(n, int(SR * attack))
    r = min(n, int(SR * release))
    if a:
        env[:a] = np.linspace(0.0, 1.0, a, endpoint=False)
    if r:
        env[-r:] *= np.linspace(1.0, 0.0, r)
    return env


def tone(freq: float, seconds: float, amp: float, decay: float = 8.0) -> np.ndarray:
    t = np.arange(int(SR * seconds)) / SR
    return amp * np.sin(2.0 * np.pi * freq * t) * np.exp(-decay * t)


def band_noise(seconds: float, lo: float, hi: float, amp: float) -> np.ndarray:
    n = int(SR * seconds)
    noise = RNG.normal(0.0, 1.0, n)
    spectrum = np.fft.rfft(noise)
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    # Soft 10% transition avoids the metallic ringing of a brick-wall filter.
    width = max((hi - lo) * 0.10, 30.0)
    low_ramp = np.clip((freqs - (lo - width)) / width, 0.0, 1.0)
    high_ramp = np.clip(((hi + width) - freqs) / width, 0.0, 1.0)
    return np.fft.irfft(spectrum * low_ramp * high_ramp, n=n) * amp


def place(dst: np.ndarray, src: np.ndarray, start_s: float) -> None:
    start = int(start_s * SR)
    end = min(len(dst), start + len(src))
    if end > start:
        dst[start:end] += src[: end - start]


def mix(*parts: np.ndarray) -> np.ndarray:
    out = np.zeros(max(len(part) for part in parts))
    for part in parts:
        out[: len(part)] += part
    return out


def normalize(x: np.ndarray, peak: float = 0.82) -> np.ndarray:
    x = np.nan_to_num(x.astype(np.float64))
    max_abs = float(np.max(np.abs(x))) if len(x) else 0.0
    return x if max_abs < 1e-8 else x * (peak / max_abs)


def write(path: Path, x: np.ndarray, peak: float = 0.82) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    y = np.clip(normalize(x, peak), -1.0, 1.0)
    pcm = (y * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(pcm.tobytes())


def ui_hover() -> np.ndarray:
    x = mix(tone(920, 0.075, 0.24, 28), tone(1380, 0.075, 0.08, 34))
    return x * envelope(len(x), 0.003, 0.055)


def ui_click() -> np.ndarray:
    x = mix(tone(380, 0.13, 0.32, 25), tone(760, 0.09, 0.11, 32))
    x[: len(x)] += band_noise(len(x) / SR, 500, 2400, 0.035)
    return x * envelope(len(x), 0.002, 0.10)


def dice_roll() -> np.ndarray:
    out = np.zeros(int(0.72 * SR))
    for i, at in enumerate([0.00, 0.09, 0.17, 0.255, 0.345, 0.44, 0.535]):
        f = 205 + i * 17 + RNG.uniform(-12, 12)
        clack = mix(
            tone(f, 0.12, 0.36 - i * 0.018, 27),
            band_noise(0.12, 650, 4200, 0.055),
        )
        place(out, clack * envelope(len(clack), 0.001, 0.10), at)
    return out


def dice_land() -> np.ndarray:
    out = np.zeros(int(0.30 * SR))
    place(out, mix(tone(164, 0.23, 0.48, 18), band_noise(0.23, 380, 3000, 0.07)), 0.0)
    place(out, tone(286, 0.13, 0.18, 25), 0.055)
    return out * envelope(len(out), 0.001, 0.20)


def card_deal() -> np.ndarray:
    n = int(0.23 * SR)
    t = np.arange(n) / SR
    noise = band_noise(0.23, 300, 6800, 0.22)
    sweep = np.sin(2 * np.pi * (280 * t + 1400 * t * t)) * 0.035
    return (noise + sweep) * envelope(n, 0.006, 0.15)


def card_flip() -> np.ndarray:
    n = int(0.30 * SR)
    noise = band_noise(0.30, 450, 7600, 0.23)
    shape = np.sin(np.linspace(0, np.pi, n)) ** 1.6
    snap = np.zeros(n)
    place(snap, tone(620, 0.075, 0.18, 31), 0.13)
    return noise * shape + snap


def trade_success() -> np.ndarray:
    out = np.zeros(int(0.62 * SR))
    for at, freq, amp in [(0.0, 740, 0.22), (0.12, 988, 0.24), (0.25, 1480, 0.17)]:
        chime = mix(tone(freq, 0.36, amp, 6.5), tone(freq * 2.01, 0.30, amp * 0.18, 8))
        place(out, chime, at)
    return out * envelope(len(out), 0.003, 0.24)


def arrival() -> np.ndarray:
    out = np.zeros(int(0.46 * SR))
    place(out, tone(220, 0.20, 0.32, 18), 0.0)
    place(out, tone(660, 0.28, 0.18, 9), 0.08)
    return out * envelope(len(out), 0.002, 0.25)


def read_mono(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as wf:
        sr = wf.getframerate()
        channels = wf.getnchannels()
        width = wf.getsampwidth()
        frames = wf.readframes(wf.getnframes())
    if sr != SR or width != 2:
        raise ValueError(f"expected mono/stereo 16-bit {SR}Hz source: {path}")
    x = np.frombuffer(frames, dtype="<i2").astype(np.float64) / 32768.0
    if channels > 1:
        x = x.reshape(-1, channels).mean(axis=1)
    return x


def seamless_source_loop(path: Path, start: float, end: float, crossfade: float, peak: float) -> np.ndarray:
    x = read_mono(path)
    lo = max(0, int(start * SR))
    hi = min(len(x), int(end * SR))
    y = x[lo:hi].copy()
    y -= np.mean(y)
    fade = min(int(crossfade * SR), len(y) // 3)
    if fade:
        ramp = np.linspace(0.0, 1.0, fade)
        blended = y[:fade] * ramp + y[-fade:] * (1.0 - ramp)
        y[:fade] = blended
        y[-fade:] = blended
    return normalize(y, peak)


def ship_loop(path: Path) -> np.ndarray:
    y = seamless_source_loop(path, 0.10, 4.00, 0.42, 0.56)
    # Source water is very quiet; add sparse low wooden hull creaks without masking it.
    for at, freq in [(0.72, 92), (2.45, 108), (3.34, 84)]:
        creak = mix(tone(freq, 0.42, 0.055, 7), band_noise(0.30, 90, 520, 0.012))
        place(y, creak, at)
    return normalize(y, 0.62)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--camel-source", type=Path, required=True)
    parser.add_argument("--ship-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("assets/audio/sfx"))
    args = parser.parse_args()

    generated = {
        "ui_hover_v1.wav": ui_hover(),
        "ui_click_v1.wav": ui_click(),
        "dice_roll_v1.wav": dice_roll(),
        "dice_land_v1.wav": dice_land(),
        "card_deal_v1.wav": card_deal(),
        "card_flip_v1.wav": card_flip(),
        "trade_success_v1.wav": trade_success(),
        "piece_arrive_v1.wav": arrival(),
        "camel_walk_loop_v1.wav": seamless_source_loop(args.camel_source, 0.10, 4.00, 0.16, 0.72),
        "ship_sail_loop_v1.wav": ship_loop(args.ship_source),
    }
    for name, audio in generated.items():
        write(args.output / name, audio, 0.84 if "loop" not in name else 0.72)
        print(f"built {name}: {len(audio) / SR:.3f}s")


if __name__ == "__main__":
    main()
