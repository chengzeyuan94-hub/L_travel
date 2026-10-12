"""Modal tail extension for a truncated bell: fit decaying partials just before the cut,
synthesize the continuation, crossfade (linear: the two signals are coherent)."""
import numpy as np
from scipy.signal import find_peaks
from common import *


def extend_bell(m, sr, fit_t0, fit_t1, join_t0, join_t1, total_s, n_partials=16, fade_out_s=1.5):
    seg = m[int(fit_t0 * sr):int(fit_t1 * sr)]
    n = len(seg)
    nf = 1 << 18
    X = np.abs(np.fft.rfft(seg * np.hanning(n), nf))
    f = np.fft.rfftfreq(nf, 1 / sr)
    Xd = 20 * np.log10(X + 1e-12)
    pk, _ = find_peaks(Xd, prominence=10, distance=int(8 / (f[1] - f[0])))
    pk = pk[(f[pk] > 60) & (f[pk] < 8000)]
    pk = pk[np.argsort(Xd[pk])[::-1][:n_partials]]
    freqs = np.sort(f[pk])
    # per-partial decay rate from STFT tracks across a longer window
    t, fs, S = stft_mag(m, sr, 8192, 1024)
    alphas = []
    for fr in freqs:
        b = np.argmin(np.abs(fs - fr))
        tr = 20 * np.log10(S[:, b - 1:b + 2].max(axis=1) + 1e-12)
        sel = (t > fit_t0 - 1.0) & (t < fit_t1 - 0.1)
        slope = np.polyfit(t[sel], tr[sel], 1)[0] if sel.sum() > 3 else -6.0
        slope = min(slope, -1.0)  # never grow
        alphas.append(-slope / 20 * np.log(10))  # neper/s
    alphas = np.array(alphas)
    # least squares amplitudes/phases over the fit window
    tt = np.arange(int(fit_t0 * sr), int(fit_t1 * sr)) / sr
    cols = []
    for fr, al in zip(freqs, alphas):
        env = np.exp(-al * (tt - fit_t1))
        cols += [env * np.cos(2 * np.pi * fr * tt), env * np.sin(2 * np.pi * fr * tt)]
    A = np.stack(cols, axis=1)
    coef, *_ = np.linalg.lstsq(A, seg, rcond=None)
    fit = A @ coef
    fit_snr = 10 * np.log10((seg ** 2).sum() / ((seg - fit) ** 2).sum())
    # synthesize from join_t0 to total_s
    N = int(total_s * sr)
    ts = np.arange(int(join_t0 * sr), N) / sr
    syn = np.zeros(len(ts))
    for k, (fr, al) in enumerate(zip(freqs, alphas)):
        env = np.exp(-al * (ts - fit_t1))
        syn += env * (coef[2 * k] * np.cos(2 * np.pi * fr * ts) + coef[2 * k + 1] * np.sin(2 * np.pi * fr * ts))
    out = np.zeros(N)
    j0 = int(join_t0 * sr); j1 = int(join_t1 * sr)
    out[:j1] = m[:j1]
    w = np.linspace(0, 1, j1 - j0)
    out[j0:j1] = m[j0:j1] * (1 - w) + syn[:j1 - j0] * w
    out[j1:] = syn[j1 - j0:]
    # final fade
    F = int(fade_out_s * sr)
    out[-F:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, F)))
    info = dict(partials_hz=[round(float(v), 1) for v in freqs], T60_s=[round(float(3 * np.log(10) / a), 2) for a in alphas],
                fit_snr_db=round(float(fit_snr), 1))
    return out, info
