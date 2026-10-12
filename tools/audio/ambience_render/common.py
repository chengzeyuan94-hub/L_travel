import wave, os, subprocess
import numpy as np

FFMPEG = os.path.expanduser("~/.local/bin/ffmpeg")
import os as _os
# 原始素材目录（Carlos 桌面上的「音效」文件夹）；可用环境变量 LSHU_SFX_SRC 覆盖
SRC = _os.environ.get("LSHU_SFX_SRC", _os.path.expanduser("~/Desktop/音效"))
GAME = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "assets", "audio"))
HERE = os.path.dirname(os.path.abspath(__file__))

NAMES = ["沙沙的微风", "铃铛声", "自然鸟叫", "海浪", "下雨声", "船舶划桨", "马蹄行走",
         "篝火", "风吹树叶", "寺庙钟声", "风吹过空旷地", "风吹树叶哗哗声"]


def read_wav(path):
    """Return float64 array (N, ch) in [-1, 1), sr."""
    if not path.lower().endswith(".wav"):
        tmp = os.path.join(HERE, "_decode_tmp.wav")
        subprocess.run([FFMPEG, "-y", "-v", "error", "-i", path, "-c:a", "pcm_s16le", tmp], check=True)
        path = tmp
    w = wave.open(path, "rb")
    ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = w.readframes(n)
    w.close()
    assert sw == 2, (path, sw)
    a = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    return a.reshape(-1, ch), sr


def write_wav(path, x, sr):
    x = np.asarray(x)
    if x.ndim == 1:
        x = x[:, None]
    y = np.clip(np.round(x * 32767.0), -32768, 32767).astype("<i2")
    w = wave.open(path, "wb")
    w.setnchannels(x.shape[1]); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(y.tobytes()); w.close()


def db(x, floor=1e-12):
    return 20 * np.log10(np.maximum(np.abs(x), floor))


def rms_env(m, sr, win_s=0.05, hop_s=0.05):
    win = int(win_s * sr); hop = int(hop_s * sr)
    n = max(1, (len(m) - win) // hop + 1)
    idx = np.arange(n)[:, None] * hop + np.arange(win)[None, :]
    e = np.sqrt((m[idx] ** 2).mean(axis=1) + 1e-20)
    t = (np.arange(n) * hop + win / 2) / sr
    return t, 20 * np.log10(e)


def stft_mag(m, sr, n_fft=2048, hop=512):
    win = np.hanning(n_fft)
    n = max(1, (len(m) - n_fft) // hop + 1)
    idx = np.arange(n)[:, None] * hop + np.arange(n_fft)[None, :]
    frames = m[idx] * win[None, :]
    S = np.abs(np.fft.rfft(frames, axis=1))
    f = np.fft.rfftfreq(n_fft, 1 / sr)
    t = (np.arange(n) * hop + n_fft / 2) / sr
    return t, f, S


THIRD_OCT = [25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250,
             1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000]


def band_levels(seg, sr, centers=THIRD_OCT):
    """1/3-octave band levels (dB) of a segment (mono)."""
    n = len(seg)
    X = np.abs(np.fft.rfft(seg * np.hanning(n))) ** 2
    f = np.fft.rfftfreq(n, 1 / sr)
    out = []
    for c in centers:
        lo, hi = c / 2 ** (1 / 6), c * 2 ** (1 / 6)
        sel = (f >= lo) & (f < hi)
        out.append(10 * np.log10(X[sel].sum() + 1e-20) if sel.any() else -200.0)
    return np.array(out)


def onset_strength(m, sr, n_fft=1024, hop=256):
    t, f, S = stft_mag(m, sr, n_fft, hop)
    L = np.log1p(1000 * S)
    flux = np.maximum(0, np.diff(L, axis=0)).sum(axis=1)
    flux = np.concatenate([[0], flux])
    return t, flux, sr / hop


def pick_onsets(t, flux, fr, k=3.0, min_gap_s=0.07, med_s=1.0):
    half = max(1, int(med_s * fr / 2))
    n = len(flux)
    med = np.array([np.median(flux[max(0, i - half):i + half + 1]) for i in range(n)])
    mad = np.array([np.median(np.abs(flux[max(0, i - half):i + half + 1] - med[i])) for i in range(n)])
    thr = med + k * (mad + 1e-9) * 1.4826
    peaks = []
    gap = int(min_gap_s * fr)
    for i in range(1, n - 1):
        if flux[i] > thr[i] and flux[i] >= flux[i - 1] and flux[i] >= flux[i + 1]:
            if peaks and i - peaks[-1] < gap:
                if flux[i] > flux[peaks[-1]]:
                    peaks[-1] = i
                continue
            peaks.append(i)
    return np.array(peaks, dtype=int)


def autocorr(x):
    x = x - x.mean()
    n = len(x)
    f = np.fft.rfft(x, n=2 * n)
    ac = np.fft.irfft(f * np.conj(f))[:n]
    return ac / (ac[0] + 1e-20)


def ebur128(path):
    import re
    p = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", path, "-filter_complex",
                        "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True)
    s = p.stderr[p.stderr.rfind("Summary:"):]
    def g(lbl):
        m = re.search(lbl + r"\s*(-?[\d.]+|-inf)", s)
        return None if not m else (float(m.group(1)) if m.group(1) != "-inf" else -120.0)
    return dict(I=g("I:"), LRA=g("LRA:"), TP=g("Peak:"))
