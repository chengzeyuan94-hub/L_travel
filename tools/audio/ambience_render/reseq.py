"""Re-sequenced extended loop for short beds: shuffle chunks of the clean region with equal-power
crossfades so that swells land at irregular times, and close the loop on a matched join.
Also: 'patch' repair (replace a transient with neighbouring material)."""
import numpy as np
from common import *
from looplib import bands, build_loop


def xfade_concat(chunks, X):
    t = (np.arange(X) + 0.5) / X
    fin, fout = np.sin(t * np.pi / 2)[:, None], np.cos(t * np.pi / 2)[:, None]
    z = chunks[0].copy()
    for c in chunks[1:]:
        head = z[-X:] * fout + c[:X] * fin
        z = np.concatenate([z[:-X], head, c[X:]])
    return z


def reseq(x, sr, region, T, chunk=(1.6, 2.6), X=0.6, seed=1, n_cand=48, min_jump=1.0):
    rng = np.random.default_rng(seed)
    a, b = int(region[0] * sr), int(region[1] * sr)
    m = x.mean(axis=1)
    Xs = int(X * sr)
    def tail_feat(s, e):
        seg = m[e - Xs:e]; return bands(seg, sr), db(np.sqrt((seg ** 2).mean()))
    def head_feat(s):
        seg = m[s:s + Xs]; return bands(seg, sr), db(np.sqrt((seg ** 2).mean()))
    def dist(f1, f2):
        return float(np.mean(np.abs(f1[0] - f2[0])) + abs(f1[1] - f2[1]))
    Ttot = int(T * sr) + Xs  # linear length before closing
    lmin, lmax = int(chunk[0] * sr), int(chunk[1] * sr)
    first_s = a
    l0 = int(rng.integers(lmin, lmax))
    seq = [(first_s, first_s + l0)]
    total = l0
    head0 = head_feat(first_s)
    joins = []
    while True:
        remaining = Ttot - (total - Xs * (len(seq) - 1)) if False else None
        cur_len = total - Xs * (len(seq) - 1)
        need = Ttot - cur_len + Xs  # length of a final chunk that would hit Ttot exactly
        prev_s, prev_e = seq[-1]
        pf = tail_feat(prev_s, prev_e)
        final = lmin <= need <= lmax * 1.6
        best = None
        for _ in range(n_cand):
            l = need if final else int(rng.integers(lmin, lmax))
            if l > b - a - Xs:
                continue
            s = int(rng.integers(a, b - l))
            if abs(s - prev_e) < int(min_jump * sr) or any(abs(s - q[0]) < int(0.5 * sr) for q in seq[-2:]):
                continue
            c = dist(pf, head_feat(s))
            if final:  # its tail must also match chunk 0's head (loop closure)
                c += dist(tail_feat(s, s + l), head0)
            if best is None or c < best[0]:
                best = (c, s, l)
        if best is None:
            continue
        seq.append((best[1], best[1] + best[2]))
        joins.append(round(best[0], 2))
        total += best[2]
        if final:
            break
    chunks = [x[s:e] for s, e in seq]
    z = xfade_concat(chunks, Xs)
    y = build_loop(z, 0, len(z), Xs)
    return y, dict(n_chunks=len(seq), chunk_src_s=[(round(s / sr, 2), round(e / sr, 2)) for s, e in seq], join_costs=joins,
                   loop_len_s=round(len(y) / sr, 3))


def patch(x, sr, t0, pre=0.03, post=0.12, shift=-0.45, X=0.02):
    """Replace x[t0-pre : t0+post] with the same-length segment starting `shift` s earlier, 20 ms crossfades."""
    i0, i1 = int((t0 - pre) * sr), int((t0 + post) * sr)
    j0 = i0 + int(shift * sr)
    Xs = int(X * sr)
    y = x.copy()
    rep = x[j0 - Xs:j0 + (i1 - i0) + Xs].copy()
    t = (np.arange(Xs) + 0.5) / Xs
    fin = np.sin(t * np.pi / 2); fout = np.cos(t * np.pi / 2)
    if x.ndim == 2:
        fin, fout = fin[:, None], fout[:, None]
    y[i0 - Xs:i0] = x[i0 - Xs:i0] * fout + rep[:Xs] * fin
    y[i0:i1] = rep[Xs:Xs + (i1 - i0)]
    y[i1:i1 + Xs] = rep[Xs + (i1 - i0):] * fout + x[i1:i1 + Xs] * fin
    return y


def swell_stats(y, sr, smooth=0.5, prom=4.0):
    from scipy.signal import find_peaks
    m = y.mean(axis=1) if y.ndim == 2 else y
    yy = np.concatenate([m, m, m])
    t, e = rms_env(yy, sr, smooth, 0.05)
    pk, pr = find_peaks(e, prominence=prom)
    n = len(m) / sr
    sel = (t[pk] >= n) & (t[pk] < 2 * n)
    times = t[pk][sel] - n
    iv = np.diff(np.concatenate([times, [times[0] + n]])) if len(times) else np.array([])
    return dict(swells_per_loop=int(sel.sum()), swell_times=[round(float(v), 1) for v in times],
                intervals=[round(float(v), 1) for v in iv],
                interval_cv=round(float(iv.std() / iv.mean()), 2) if len(iv) > 1 else None,
                env_swing_db=round(float(np.percentile(e, 95) - np.percentile(e, 5)), 1))
