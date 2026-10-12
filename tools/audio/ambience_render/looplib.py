"""Loop construction + seam metrics.

Loop from segment x[s:e] with crossfade L (samples):
    y = x[s:e-L];  y[:L] = x[s:s+L]*fin + x[e-L:e]*fout     (equal-power: fin=sin, fout=cos)
The wrap y[-1] -> y[0] is x[e-L-1] -> x[e-L]: sample-continuous by construction; the only
place the ear can catch the loop is the crossfade zone y[0:L], where the material morphs from
the end-of-segment (B = x[e-L:e]) to the start-of-segment (A = x[s:s+L]).
"""
import numpy as np
from common import *

BAND_SEL = [i for i, c in enumerate(THIRD_OCT) if 100 <= c <= 10000]


def bands(seg, sr):
    return band_levels(seg, sr)[BAND_SEL]


def seam_ratio(y):
    m = y.mean(axis=1) if y.ndim == 2 else y
    d = np.abs(np.diff(m))
    return float(abs(m[0] - m[-1]) / max(np.percentile(d, 99.9), 1e-12))


def seam_ratio_ch(y):
    if y.ndim == 1:
        return seam_ratio(y)
    return max(seam_ratio(y[:, c]) for c in range(y.shape[1]))


def build_loop(x, s, e, L, law="power"):
    y = x[s:e - L].copy()
    if L > 0:
        t = (np.arange(L) + 0.5) / L
        if law == "power":
            fin, fout = np.sin(t * np.pi / 2), np.cos(t * np.pi / 2)
        else:
            fin, fout = t, 1 - t
        if x.ndim == 2:
            fin, fout = fin[:, None], fout[:, None]
        y[:L] = x[s:s + L] * fin + x[e - L:e] * fout
    return y


def edge_compare(x, sr, ms=200):
    """Compare first vs last `ms` of a (possibly already trimmed) signal, as if it were looped raw."""
    m = x.mean(axis=1) if x.ndim == 2 else x
    n = int(ms / 1000 * sr)
    h, t = m[:n], m[-n:]
    rms_d = float(db(np.sqrt((t ** 2).mean())) - db(np.sqrt((h ** 2).mean())))
    bd = float(np.mean(np.abs(bands(t, sr) - bands(h, sr))))
    return dict(edge_rms_diff_db=round(rms_d, 2), edge_band_dist_db=round(bd, 2), seam_ratio_raw=round(seam_ratio_ch(x), 2))


def natural_band_dist(m, sr, gap, win=1.0, a=None, b=None, step=0.1):
    """Distribution of band distance between a 1 s window and the 1 s window starting `gap` s after its end."""
    a = 0 if a is None else a
    b = len(m) if b is None else b
    W, G = int(win * sr), int(gap * sr)
    out = []
    for t in range(a + W, b - G - W, int(step * sr)):
        out.append(np.mean(np.abs(bands(m[t - W:t], sr) - bands(m[t + G:t + G + W], sr))))
    return np.array(out)


def natural_level_dev(m, sr, L, a=None, b=None, step=0.1):
    """Distribution of (level in an L-long zone) - (level of the 1.5 s either side)."""
    a = 0 if a is None else a
    b = len(m) if b is None else b
    W = int(1.5 * sr)
    out = []
    for t in range(a + W, b - L - W, int(step * sr)):
        z = m[t:t + L]; o = np.concatenate([m[t - W:t], m[t + L:t + L + W]])
        out.append(db(np.sqrt((z ** 2).mean())) - db(np.sqrt((o ** 2).mean())))
    return np.array(out)


def evaluate_loop(x, y, sr, L, region=None):
    """Metrics of loop y (built with crossfade L) against natural variation of source x[region]."""
    my = y.mean(axis=1) if y.ndim == 2 else y
    mx = x.mean(axis=1) if x.ndim == 2 else x
    a, b = region if region else (0, len(mx))
    yy = np.concatenate([my, my, my])
    n = len(my)
    W = int(1.0 * sr)
    r = dict(loop_len_s=round(n / sr, 3), xfade_s=round(L / sr, 2), seam_ratio=round(seam_ratio_ch(y), 2))
    # spectral jump across crossfade zone (1 s before zone vs 1 s after zone)
    z0 = n  # zone [n, n+L) in yy
    d_seam = float(np.mean(np.abs(bands(yy[z0 - W:z0], sr) - bands(yy[z0 + L:z0 + L + W], sr))))
    nat = natural_band_dist(mx, sr, L / sr, 1.0, a, b)
    r["spec_jump_db"] = round(d_seam, 2)
    r["spec_jump_pct"] = round(float((nat < d_seam).mean() * 100), 0) if len(nat) else None
    r["spec_nat_p50_p90"] = (round(float(np.percentile(nat, 50)), 2), round(float(np.percentile(nat, 90)), 2)) if len(nat) else None
    # level deviation inside zone
    Wl = int(1.5 * sr)
    zone = yy[z0:z0 + max(L, int(0.2 * sr))]
    outside = np.concatenate([yy[z0 - Wl:z0], yy[z0 + L:z0 + L + Wl]])
    dev = float(db(np.sqrt((zone ** 2).mean())) - db(np.sqrt((outside ** 2).mean())))
    natl = natural_level_dev(mx, sr, max(L, int(0.2 * sr)), a, b)
    r["zone_level_dev_db"] = round(dev, 2)
    r["zone_level_pct"] = round(float((np.abs(natl) < abs(dev)).mean() * 100), 0) if len(natl) else None
    # min 100 ms envelope inside zone vs loop median (dip detection)
    t, e = rms_env(yy[z0 - Wl:z0 + L + Wl], sr, 0.1, 0.02)
    _, eall = rms_env(my, sr, 0.1, 0.02)
    r["zone_env_min_minus_loop_p10_db"] = round(float(e.min() - np.percentile(eall, 10)), 2)
    return r


def search_xfade(x, sr, L, s_range, e_range, step_s=0.02, w_event=0.5, w_phase=0.0, min_len=None, w_len=0.25):
    """Grid-search start s and end e minimising mismatch between A=x[s:s+L] and B=x[e-L:e].
    cost = band distance + |level diff| + w_event*(event content in A,B above median+6 dB) - w_phase*envelope corr(A,B)."""
    m = x.mean(axis=1) if x.ndim == 2 else x
    st = max(1, int(step_s * sr))
    te, e = rms_env(m, sr, 0.05, 0.01)
    med = np.median(e)
    def env_slice(i0, i1):
        return e[int(i0 / sr * 100): int(i1 / sr * 100)]
    As = []
    for s in range(s_range[0], s_range[1] + 1, st):
        A = m[s:s + L]
        if len(A) == L:
            As.append((s, bands(A, sr), db(np.sqrt((A ** 2).mean())), env_slice(s, s + L)))
    Bs = []
    for en in range(e_range[0], e_range[1] + 1, st):
        B = m[en - L:en]
        if len(B) == L and en - L >= 0:
            Bs.append((en, bands(B, sr), db(np.sqrt((B ** 2).mean())), env_slice(en - L, en)))
    best = None
    for s, bA, lA, eA in As:
        for en, bB, lB, eB in Bs:
            if en - L <= s + L or (min_len and en - L - s < min_len):
                continue
            cost = np.mean(np.abs(bA - bB)) + abs(lA - lB) - w_len * (en - L - s) / sr
            cost += w_event * (max(0, eA.max() - med - 6) + max(0, eB.max() - med - 6))
            k = min(len(eA), len(eB))
            if w_phase and k > 3:
                cost -= w_phase * float(np.corrcoef(eA[:k], eB[:k])[0, 1])
            if best is None or cost < best[0]:
                best = (float(cost), s, en)
    return best
