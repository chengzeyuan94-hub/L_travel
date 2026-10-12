#!/usr/bin/env python3
"""Tiny, deterministic synthesis kit for scores and sound design (numpy + scipy), plus a demo cue.

    uv run -q --offline --with numpy --with scipy python tools/motion/audio/synth.py --demo OUT.wav [--duration 15] [--bpm 84]

Import it from your own cue script (sys.path.insert(0, "tools/motion/audio")):

    from synth import *                     # SR = 48000, all signals are float32 stereo arrays shaped (n, 2)
    mix = track(15.0)                       # silent stereo buffer
    place(mix, bell(midi("E5"), 3.0), at=1.0, gain_db=-12, pan=-0.3)
    place(mix, pad([midi(n) for n in ("A3", "E4", "C#5")], 6.0), at=0.0, gain_db=-18)
    place(mix, whoosh(1.2, rising=True), at=beat(4, bpm=84) - 1.2, gain_db=-14)
    mix = reverb(mix, seconds=2.8, wet=0.25)
    write("cue.wav", master(mix, peak_db=-1.0))

Voices: sine / tri / saw (band-limited-ish via polyBLEP), pad (detuned saws through a low-pass), pluck
(Karplus-Strong: dutar / pipa-ish), bell (inharmonic FM partials: temple / camel bells), drum (pitched body +
click: frame drum / taiko hits), noise-based wind, rain, whoosh (filtered noise sweep), riser, sub-drop,
paper (postcard flip / page turn: short filtered noise bursts), stamp (thump + paper slap).
Utilities: adsr, lowpass / highpass / bandpass (scipy butter, zero-phase), reverb (synthetic decaying-noise IR,
FFT convolution), delay, pan, beat() / bar() timing helpers, place() on a timeline, master() soft-clip + peak.
Loudness: measure / normalise the final mix with tools/motion/comp/mc.py measure|loudnorm (EBU R128).
Existing game audio to layer in: assets/audio/ambience/*.ogg (campfire, rain, wind, temple bell, birds, waves),
assets/audio/sfx/*.wav (camel, dice, cards, trade), assets/audio/title/title_bgm_loop_v1.wav (16.6 s loop,
-18.8 LUFS). tools/audio/ambience_render/common.py has read_wav / write_wav / ebur128 / onset helpers.
"""
import argparse
import math
import wave

import numpy as np
from scipy import signal

SR = 48000
NOTE = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}


def midi(name):
    """'A4' -> 440.0 Hz; accepts sharps / flats ('C#5', 'Eb3') or a MIDI number"""
    if isinstance(name, (int, float)):
        return 440.0 * 2 ** ((name - 69) / 12)
    n, octv = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((NOTE[n] + 12 * (octv + 1) - 69) / 12)


def beat(n, bpm):
    return n * 60.0 / bpm


def bar(n, bpm, per_bar=4):
    return beat(n * per_bar, bpm)


def t_axis(dur):
    return np.arange(int(round(dur * SR))) / SR


def stereo(x, pan=0.0):
    """mono -> (n, 2) with an equal-power pan in [-1, 1]"""
    a = (pan + 1) * math.pi / 4
    return np.stack([x * math.cos(a), x * math.sin(a)], axis=1).astype(np.float32)


def adsr(n, a=0.01, d=0.1, s=0.7, r=0.3):
    a_n, d_n, r_n = int(a * SR), int(d * SR), int(r * SR)
    s_n = max(0, n - a_n - d_n - r_n)
    env = np.concatenate([np.linspace(0, 1, a_n, endpoint=False), np.linspace(1, s, d_n, endpoint=False), np.full(s_n, s), np.linspace(s, 0, r_n)])
    return np.pad(env, (0, max(0, n - len(env))))[:n]


def _blep(t, dt):
    y = np.zeros_like(t)
    m1 = t < dt
    x = t[m1] / dt
    y[m1] = x + x - x * x - 1
    m2 = t > 1 - dt
    x = (t[m2] - 1) / dt
    y[m2] = x * x + x + x + 1
    return y


def saw(freq, dur, phase=0.0):
    t = t_axis(dur)
    dt = freq / SR
    ph = (phase + freq * t) % 1.0
    return (2 * ph - 1 - _blep(ph, dt)).astype(np.float32)


def sine(freq, dur, phase=0.0):
    return np.sin(2 * np.pi * (freq * t_axis(dur) + phase)).astype(np.float32)


def tri(freq, dur):
    return (2 * np.abs(2 * ((freq * t_axis(dur)) % 1.0) - 1) - 1).astype(np.float32)


def lowpass(x, hz, order=4):
    b, a = signal.butter(order, min(hz, SR / 2 * 0.99) / (SR / 2), "low")
    return signal.filtfilt(b, a, x, axis=0).astype(np.float32)


def highpass(x, hz, order=4):
    b, a = signal.butter(order, hz / (SR / 2), "high")
    return signal.filtfilt(b, a, x, axis=0).astype(np.float32)


def bandpass(x, lo, hi, order=3):
    b, a = signal.butter(order, [lo / (SR / 2), min(hi, SR / 2 * 0.99) / (SR / 2)], "band")
    return signal.filtfilt(b, a, x, axis=0).astype(np.float32)


def noise(dur, seed=0):
    return np.random.default_rng(seed).standard_normal(int(round(dur * SR))).astype(np.float32)


# ------------------------------------------------------------------ voices
def pad(freqs, dur, cutoff=1800, detune=0.12, attack=1.5, release=2.0, seed=1):
    """warm detuned-saw pad chord (mono)"""
    rng = np.random.default_rng(seed)
    x = np.zeros(int(round(dur * SR)), np.float32)
    for f in freqs:
        for d in (-detune, 0.0, detune):
            x += saw(f * 2 ** (d / 12), dur, rng.random())
    x = lowpass(x / (3 * len(freqs)), cutoff)
    return x * adsr(len(x), attack, 0.5, 0.85, release)


def pluck(freq, dur, bright=0.5, seed=2):
    """Karplus-Strong plucked string (dutar / pipa colour)"""
    n = int(round(dur * SR))
    p = max(2, int(SR / freq))
    buf = np.random.default_rng(seed).uniform(-1, 1, p).astype(np.float32)
    out = np.zeros(n, np.float32)
    damp = 0.996 - 0.01 * (1 - bright)
    for i in range(n):
        out[i] = buf[i % p]
        buf[i % p] = damp * 0.5 * (buf[i % p] + buf[(i + 1) % p])
    return lowpass(out, 2000 + 6000 * bright)


def bell(freq, dur, bright=1.0):
    """inharmonic bell (temple / camel bell): partial ratios of a struck bar/bell, exponential decays"""
    t = t_axis(dur)
    parts = [(0.5, 1.0, 1.2), (1.0, 0.8, 1.0), (1.19, 0.5, 0.7), (1.56, 0.35, 0.5), (2.0, 0.3, 0.45), (2.51, 0.18, 0.3), (3.01, 0.12 * bright, 0.2)]
    x = sum(a * np.exp(-t / (d * dur * 0.6)) * np.sin(2 * np.pi * freq * r * t + r) for r, a, d in parts)
    return (x / 3.0 * np.minimum(1, t / 0.002)).astype(np.float32)


def drum(freq=70, dur=0.8, click=0.4, seed=3):
    """frame drum / taiko-ish hit: pitch-dropping body + noise click"""
    t = t_axis(dur)
    f = freq * (1 + 1.5 * np.exp(-t / 0.03))
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (dur * 0.35))
    c = bandpass(noise(dur, seed), 800, 5000) * np.exp(-t / 0.015) * click
    return (body + c).astype(np.float32)


def wind(dur, seed=4, lo=200, hi=1400, gust=0.25):
    x = bandpass(noise(dur, seed), lo, hi)
    t = t_axis(dur)
    g = 0.6 + gust * np.sin(2 * np.pi * 0.11 * t) + gust * 0.6 * np.sin(2 * np.pi * 0.37 * t + 1.3)
    return (x * g / (np.abs(x).max() + 1e-9)).astype(np.float32)


def rain(dur, seed=5, density=900):
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    x = highpass(noise(dur, seed), 1500) * 0.25
    for i in rng.integers(0, n - 400, int(density * dur)):
        x[i:i + 400] += rng.uniform(0.05, 0.3) * np.exp(-np.arange(400) / rng.uniform(20, 90)) * rng.choice([-1, 1])
    return (x / (np.abs(x).max() + 1e-9)).astype(np.float32)


def whoosh(dur, rising=True, seed=6):
    """filtered-noise sweep; rising=True ends on the hit (place it at hit_time - dur)"""
    x = noise(dur, seed)
    n = len(x)
    cut = np.geomspace(300, 6000, n) if rising else np.geomspace(6000, 300, n)
    # time-varying one-pole low-pass
    y = np.zeros(n, np.float32)
    acc = 0.0
    for i in range(0, n, 64):
        a = 1 - math.exp(-2 * math.pi * cut[i] / SR)
        seg = x[i:i + 64]
        for j, v in enumerate(seg):
            acc += a * (v - acc)
            y[i + j] = acc
    env = np.sin(np.linspace(0, math.pi, n)) ** (0.6 if rising else 1.4)
    if rising:
        env = np.linspace(0, 1, n) ** 2.2
    return (y * env / (np.abs(y).max() + 1e-9)).astype(np.float32)


def riser(dur, f0=110, f1=880):
    t = t_axis(dur)
    f = np.geomspace(f0, f1, len(t))
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * 0.5 + saw(f0, dur) * 0.0
    return (x * (t / dur) ** 2).astype(np.float32)


def subdrop(dur=1.5, f0=90, f1=32):
    t = t_axis(dur)
    f = np.geomspace(f0, f1, len(t))
    return (np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (dur * 0.5))).astype(np.float32)


def paper(dur=0.25, seed=7):
    """postcard flip / page turn"""
    t = t_axis(dur)
    x = bandpass(noise(dur, seed), 1200, 9000) * (np.exp(-t / 0.05) + 0.4 * np.exp(-((t - dur * 0.55) / 0.03) ** 2))
    return (x / (np.abs(x).max() + 1e-9)).astype(np.float32)


def stamp(seed=8):
    """rubber stamp: low thump + paper slap"""
    return (drum(95, 0.35, click=0.0) * 0.9 + np.pad(paper(0.12, seed) * 0.5, (0, int(0.23 * SR)))).astype(np.float32)


# ------------------------------------------------------------------ timeline & effects
def track(dur):
    return np.zeros((int(round(dur * SR)), 2), np.float32)


def place(mix, x, at=0.0, gain_db=0.0, pan=0.0):
    """add mono or stereo x into mix at time `at` (clipped to the mix length)"""
    if x.ndim == 1:
        x = stereo(x, pan)
    i = int(round(at * SR))
    if i >= len(mix):
        return mix
    j = min(len(mix), i + len(x))
    s = max(0, -i)
    mix[max(0, i):j] += x[s:j - i] * (10 ** (gain_db / 20))
    return mix


def reverb(x, seconds=2.5, wet=0.25, predelay=0.02, damp_hz=6000, seed=9):
    """synthetic hall: decorrelated decaying noise IR per channel, FFT convolution"""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    out = np.zeros((len(x) + n - 1, 2), np.float32)
    for ch in range(2):
        ir = np.random.default_rng(seed + ch).standard_normal(n) * np.exp(-6.9 * t / seconds)
        ir = lowpass(ir.astype(np.float32), damp_hz)
        ir = np.pad(ir, (int(predelay * SR), 0))[:n]
        ir /= np.sqrt((ir ** 2).sum()) + 1e-9
        out[:, ch] = signal.fftconvolve(x[:, ch], ir)[: len(out)]
    out = out[: len(x)]
    return ((1 - wet) * x + wet * out).astype(np.float32)


def delay(x, seconds=0.375, feedback=0.35, wet=0.3):
    d = int(seconds * SR)
    y = x.copy()
    for k in range(1, 6):
        g = feedback ** k
        if g < 0.01 or d * k >= len(x):
            break
        y[d * k:] += x[: len(x) - d * k] * g * wet
    return y


def master(x, peak_db=-1.0, drive=1.2):
    """gentle tanh soft-clip, then peak-normalise (true-peak safety: leave >= 1 dB headroom; loudnorm after)"""
    y = np.tanh(x * drive) / np.tanh(drive)
    p = np.abs(y).max() + 1e-9
    return (y / p * 10 ** (peak_db / 20)).astype(np.float32)


def write(path, x):
    x = np.clip(x, -1, 1)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype("<i2").tobytes())


def read(path):
    """any WAV -> float32 stereo at 48 kHz (resampled with scipy if needed)"""
    with wave.open(path, "rb") as w:
        sr, ch, sw, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    dt = {2: "<i2", 4: "<i4"}[sw]
    x = np.frombuffer(raw, dt).astype(np.float32) / float(2 ** (8 * sw - 1))
    x = x.reshape(-1, ch)
    if ch == 1:
        x = np.repeat(x, 2, axis=1)
    if sr != SR:
        x = signal.resample_poly(x, SR, sr, axis=0).astype(np.float32)
    return x


def demo(out, dur=15.0, bpm=84):
    """a 15 s entrance cue sketch: pad swell, dutar plucks on the beat, bells on the downbeats, a whoosh into a
    stamp hit at bar 4, sub-drop, and a soft tail — shows timing on a beat grid (hits land exactly on frames)."""
    mix = track(dur)
    chord = [midi(n) for n in ("D3", "A3", "E4", "F#4")]
    place(mix, pad(chord, dur, cutoff=1400, attack=3.0, release=3.0), 0.0, -16)
    scale = [midi(n) for n in ("D4", "E4", "F#4", "A4", "B4", "D5")]
    rng = np.random.default_rng(11)
    for k in range(int(dur / beat(1, bpm)) - 2):
        if k % 4 == 3:
            continue
        place(mix, pluck(scale[rng.integers(0, len(scale))], 1.2, 0.55, seed=k), beat(k, bpm) + 0.5, -20 + (3 if k % 4 == 0 else 0), pan=rng.uniform(-0.5, 0.5))
    for b in range(0, 5):
        place(mix, bell(midi("D6") if b % 2 else midi("A5"), 3.5), bar(b, bpm) + 0.5, -24, pan=0.35 if b % 2 else -0.35)
    hit = bar(4, bpm) + 0.5
    place(mix, whoosh(1.4, rising=True), hit - 1.4, -15)
    place(mix, stamp(), hit, -8)
    place(mix, subdrop(2.0), hit, -10)
    place(mix, wind(dur, lo=250, hi=1100) * np.linspace(0.3, 1, int(dur * SR)), 0.0, -30)
    mix = reverb(mix, 3.2, 0.28)
    fade = np.ones(len(mix), np.float32)
    fade[-int(1.5 * SR):] = np.linspace(1, 0, int(1.5 * SR))
    mix *= fade[:, None]
    write(out, master(mix, -1.5))
    return {"out": out, "bpm": bpm, "hit_s": hit, "hit_frame_30fps": hit * 30}


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--demo", required=True, help="output WAV")
    ap.add_argument("--duration", type=float, default=15.0)
    ap.add_argument("--bpm", type=float, default=84)
    a = ap.parse_args()
    print(demo(a.demo, a.duration, a.bpm))
