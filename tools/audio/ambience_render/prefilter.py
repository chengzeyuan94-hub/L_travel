"""Pre-loop cleanup: high-pass, notches, low-pass, transient ducking, DC. Zero-phase (offline)."""
import numpy as np
from scipy.signal import butter, sosfiltfilt, iirnotch, filtfilt


def hpf(x, sr, fc, order=4):
    sos = butter(order, fc, "high", fs=sr, output="sos")
    return sosfiltfilt(sos, x, axis=0)


def lpf(x, sr, fc, order=4):
    sos = butter(order, fc, "low", fs=sr, output="sos")
    return sosfiltfilt(sos, x, axis=0)


def notch(x, sr, f0, q=30):
    b, a = iirnotch(f0, q, fs=sr)
    return filtfilt(b, a, x, axis=0)


def duck(x, sr, t0, pre=0.005, post=0.08, depth_db=-15.0, ramp=0.015):
    """Gain dip around a transient at t0 (s)."""
    g = np.ones(len(x))
    i0 = int((t0 - pre) * sr); i1 = int((t0 + post) * sr); r = int(ramp * sr)
    depth = 10 ** (depth_db / 20)
    g[i0:i1] = depth
    ramp_dn = np.linspace(1, depth, r); ramp_up = np.linspace(depth, 1, r)
    g[i0 - r:i0] = ramp_dn
    g[i1:i1 + r] = ramp_up
    return x * (g[:, None] if x.ndim == 2 else g)


def to_mono(x):
    return x.mean(axis=1, keepdims=True) if x.ndim == 2 else x[:, None]


def balance(x, l_minus_r_db):
    """Remove an L/R level offset (split evenly)."""
    g = 10 ** (-l_minus_r_db / 40)
    y = x.copy(); y[:, 0] *= g; y[:, 1] /= g
    return y


def apply_chain(x, sr, chain):
    for op in chain:
        k = op[0]
        if k == "hpf":
            x = hpf(x, sr, *op[1:])
        elif k == "lpf":
            x = lpf(x, sr, *op[1:])
        elif k == "notch":
            x = notch(x, sr, *op[1:])
        elif k == "patch":
            from reseq import patch
            x = patch(x, sr, *op[1:])
        elif k == "duck":
            x = duck(x, sr, *op[1:])
        elif k == "balance":
            x = balance(x, op[1])
        elif k == "dc":
            x = x - x.mean(axis=0, keepdims=True)
    return x
