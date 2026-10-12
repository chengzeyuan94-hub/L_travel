"""Render every recipe: cleanup -> trim/loop -> channels -> LUFS normalise -> WAV master -> Ogg Vorbis q4,
then decode the ogg and verify length, loudness, true peak and loop seam.

Outputs: renders/masters/*.wav, renders/ogg/*.ogg, renders/preview/*_x3.ogg, renders/report.json (next to this script;
the game uses copies of renders/ogg/*.ogg in assets/audio/ambience/, except the *_short_loop and rain_bed_loop alternates)
Usage: python render.py [name_filter]
"""
import json, os, sys, subprocess
import numpy as np
from common import *
from looplib import build_loop, evaluate_loop, seam_ratio_ch
from prefilter import apply_chain, to_mono
from bell_tail import extend_bell
from reseq import reseq, swell_stats

OUT = os.path.join(HERE, "renders")
for d in ("masters", "ogg", "preview"):
    os.makedirs(os.path.join(OUT, d), exist_ok=True)

BREEZE_NOTCH = [("notch", f, 30) for f in (236.5, 349.1, 480.1, 599.8, 719.9, 839.8, 959.9, 1079.8, 1199.0)]

# kind: loop | splice_loop | oneshot | bell_ext
RECIPES = [
    dict(out="breeze_hiss_bed_loop_v1", src="沙沙的微风", kind="reseq", chain=[("hpf", 150)] + BREEZE_NOTCH,
         s=0.03, e=6.07, T=23.0, chunk=(1.4, 2.4), X=0.6, seed=4, ch=1, target=-33.0),
    dict(out="breeze_hiss_bed_short_loop_v1", src="沙沙的微风", kind="loop", chain=[("hpf", 150)] + BREEZE_NOTCH,
         s=0.03, e=6.07, xfade=2.0, ch=1, target=-33.0),
    dict(out="wind_open_bed_loop_v1", src="风吹过空旷地", kind="reseq", chain=[("hpf", 40), ("balance", 1.77)],
         s=0.10, e=6.03, T=29.0, chunk=(1.4, 2.4), X=0.6, seed=2, ch=2, target=-30.0),
    dict(out="wind_open_bed_short_loop_v1", src="风吹过空旷地", kind="loop", chain=[("hpf", 40), ("balance", 1.77)],
         s=0.10, e=6.03, xfade=2.0, ch=2, target=-30.0),
    dict(out="rain_bed_long_loop_v1", src="下雨声", kind="reseq", chain=[("hpf", 110)],
         s=0.03, e=7.28, T=19.0, chunk=(1.4, 2.6), X=0.5, seed=8, ch=2, target=-31.0),
    dict(out="rain_bed_loop_v1", src="下雨声", kind="loop", chain=[("hpf", 110)],
         s=0.03, e=7.28, xfade=1.0, ch=2, target=-31.0),
    dict(out="campfire_bed_loop_v1", src="篝火", kind="loop", chain=[("hpf", 40)],
         s=0.80, e=8.14, xfade=1.0, ch=1, target=-30.0),
    dict(out="wind_leaves_bed_loop_v1", src="风吹树叶哗哗声", kind="loop", chain=[("hpf", 80)],
         s=1.10, e=12.60, xfade=2.0, ch=2, target=-30.0),
    dict(out="wind_leaves_gust_v1", src="风吹树叶哗哗声", kind="oneshot", chain=[("hpf", 80)],
         s=14.00, e=18.45, fade_in=0.05, fade_out=0.30, ch=2, target=-28.0),
    dict(out="waves_shore_bed_loop_v1", src="海浪", kind="loop",
         chain=[("hpf", 40), ("patch", 2.0861, 0.03, 0.2, -0.45), ("patch", 9.8410, 0.03, 0.2, -0.45), ("balance", 2.42)],
         s=0.51, e=18.98, xfade=1.0, ch=2, target=-30.0),
    dict(out="birds_day_bed_loop_v1", src="自然鸟叫", kind="loop",
         chain=[("hpf", 150), ("duck", 22.0, 0.0, 2.05, -10.0, 0.08)],
         s=2.55, e=49.65, xfade=3.0, ch=1, target=-33.0),
    dict(out="rowing_loop_v1", src="船舶划桨", kind="loop", chain=[("hpf", 50)],
         s=0.02, e=27.30, xfade=1.0, ch=1, target=-30.0),
    dict(out="hooves_walk_loop_v1", src="马蹄行走", kind="splice_loop", chain=[("hpf", 60)],
         s=0.367, e=32.142, micro_xfade=0.005, ch=1, target=-31.5),
    dict(out="temple_bell_v1", src="寺庙钟声", kind="bell_ext", chain=[("hpf", 30), ("lpf", 5000)],
         s=0.212, fade_in=0.003, fit=(2.2, 3.15), join=(2.75, 3.15), total=10.0, tail_fade=1.5, ch=1, target=-20.0),
    dict(out="temple_bell_short_v1", src="寺庙钟声", kind="oneshot", chain=[("hpf", 30), ("lpf", 5000)],
         s=0.212, e=3.195, fade_in=0.003, fade_out=1.0, ch=1, target=-20.0),
    dict(out="bell_small_jingle_v1", src="铃铛声", kind="oneshot", chain=[("hpf", 300), ("lpf", 12000, 2)],
         s=0.024, e=2.75, fade_in=0.003, fade_out=0.25, ch=1, target=-20.0),
    dict(out="bell_small_ding_v1", src="铃铛声", kind="oneshot", chain=[("hpf", 300), ("lpf", 12000, 2)],
         s=0.024, e=0.80, fade_in=0.003, fade_out=0.25, ch=1, target=-20.0),
]
# bird call one-shots (from birds.py high-SNR list), pre-roll 40 ms / post-roll 120 ms
for i, (a, b) in enumerate([(2.11, 2.62), (6.71, 7.18), (13.78, 14.23), (17.28, 17.71), (19.51, 20.35), (40.57, 42.46), (21.99, 24.03)]):
    RECIPES.append(dict(out=f"bird_call_v{i + 1}", src="自然鸟叫", kind="oneshot", chain=[("hpf", 150)],
                        s=a - 0.04, e=b + 0.12, fade_in=0.015, fade_out=0.10, ch=1, target=-24.0))


def fade(y, sr, fin, fout):
    n = len(y)
    if fin > 0:
        k = int(fin * sr); w = 0.5 * (1 - np.cos(np.linspace(0, np.pi, k)))
        y[:k] *= w[:, None]
    if fout > 0:
        k = int(fout * sr); w = 0.5 * (1 + np.cos(np.linspace(0, np.pi, k)))
        y[n - k:] *= w[:, None]
    return y


def lufs_of(y, sr, pad_s=0.0):
    """Playback-equivalent loudness: a mono file is measured as dual-mono (Godot sends a mono stream
    to both L and R at full amplitude, so the listener hears +3.01 dB relative to a mono R128 reading)."""
    p = os.path.join(HERE, "tmp", "_meas.wav")
    if y.shape[1] == 1:
        y = np.repeat(y, 2, axis=1)
    if pad_s:
        z = np.zeros((int(pad_s * sr), y.shape[1]))
        y = np.concatenate([z, y, z])
    write_wav(p, y, sr)
    return ebur128(p)


def render(r):
    x, sr = read_wav(f"{SRC}/{r['src']}.wav")
    xf = apply_chain(x, sr, r["chain"])
    info = {}
    if r["kind"] == "loop":
        s, e, L = int(r["s"] * sr), int(r["e"] * sr), int(r["xfade"] * sr)
        y = build_loop(xf, s, e, L)
        ev = evaluate_loop(xf, y, sr, L, (s, e))
        info["loop_eval"] = ev
        info["swells"] = swell_stats(y, sr)
    elif r["kind"] == "reseq":
        y, rinfo = reseq(xf, sr, (r["s"], r["e"]), r["T"], r["chunk"], r["X"], seed=r["seed"])
        info["reseq"] = rinfo
        info["swells"] = swell_stats(y, sr)
    elif r["kind"] == "splice_loop":
        s, e = int(r["s"] * sr), int(r["e"] * sr)
        L = int(r["micro_xfade"] * sr)
        y = build_loop(xf, s, e + L, L)  # tiny crossfade inside the silent gap
    elif r["kind"] == "oneshot":
        y = xf[int(r["s"] * sr):int(r["e"] * sr)].copy()
        y = fade(y, sr, r["fade_in"], r["fade_out"])
    elif r["kind"] == "bell_ext":
        m = xf.mean(axis=1)
        out, binfo = extend_bell(m, sr, r["fit"][0], r["fit"][1], r["join"][0], r["join"][1], r["total"], fade_out_s=r["tail_fade"])
        y = out[int(r["s"] * sr):][:, None]
        y = fade(y, sr, r["fade_in"], 0)
        info["bell_model"] = binfo
    if r["ch"] == 1:
        y = to_mono(y)
    # remove DC introduced by nothing (HPF already) -> skip; normalise
    pad = 0.5 if r["kind"] == "oneshot" and len(y) / sr < 3 else 0.0
    meas = lufs_of(y, sr, pad)
    gain_db = r["target"] - meas["I"]
    y = y * 10 ** (gain_db / 20)
    master = os.path.join(OUT, "masters", r["out"] + ".wav")
    write_wav(master, y, sr)
    ogg = os.path.join(OUT, "ogg", r["out"] + ".ogg")
    subprocess.run([FFMPEG, "-y", "-v", "error", "-i", master, "-c:a", "libvorbis", "-q:a", "4", "-ar", "44100",
                    "-ac", str(r["ch"]), ogg], check=True)
    # verify decoded ogg
    dec, sr2 = read_wav(ogg)
    m_meas = lufs_of(read_wav(master)[0], sr, pad)
    o_meas = lufs_of(dec, sr2, pad)
    info.update(dict(
        out=r["out"] + ".ogg", src=r["src"], kind=r["kind"], ch=r["ch"], sr=sr2,
        samples_master=len(y), samples_ogg=len(dec), length_s=round(len(dec) / sr2, 4),
        gain_db=round(gain_db, 2), lufs_master=m_meas["I"], lufs_ogg=o_meas["I"], tp_ogg=o_meas["TP"],
        sample_peak_ogg=round(float(db(np.abs(dec).max())), 2), lra=o_meas["LRA"],
        size_kb=round(os.path.getsize(ogg) / 1024, 1),
    ))
    if r["kind"] in ("loop", "splice_loop", "reseq"):
        info["seam_ratio_master"] = round(seam_ratio_ch(y), 2)
        info["seam_ratio_ogg"] = round(seam_ratio_ch(dec), 2)
        # edge RMS match (50 ms) on ogg
        mm = dec.mean(axis=1); w = int(0.05 * sr2)
        info["edge_rms_dLR_db"] = round(float(db(np.sqrt((mm[-w:] ** 2).mean())) - db(np.sqrt((mm[:w] ** 2).mean()))), 2)
        # x3 preview for listening
        prev = os.path.join(OUT, "preview", r["out"] + "_x3.ogg")
        tmpw = os.path.join(HERE, "tmp", "_x3.wav")
        write_wav(tmpw, np.concatenate([dec, dec, dec]), sr2)
        subprocess.run([FFMPEG, "-y", "-v", "error", "-i", tmpw, "-c:a", "libvorbis", "-q:a", "4", prev], check=True)
    return info


if __name__ == "__main__":
    flt = sys.argv[1] if len(sys.argv) > 1 else None
    rep_path = os.path.join(OUT, "report.json")
    rep = json.load(open(rep_path)) if os.path.exists(rep_path) else {}
    for r in RECIPES:
        if flt and flt not in r["out"] and flt != r["src"]:
            continue
        info = render(r)
        info["recipe"] = {k: v for k, v in r.items() if k not in ("out",)}
        rep[r["out"]] = info
        le = info.get("loop_eval", {})
        print(f"{info['out']:32s} {info['length_s']:7.3f}s ch{info['ch']} gain {info['gain_db']:+6.1f} -> I {info['lufs_ogg']} LUFS TP {info['tp_ogg']} "
              f"LRA {info['lra']} {info['size_kb']}KB samples m/o {info['samples_master']}/{info['samples_ogg']}"
              + (f" seam m/o {info['seam_ratio_master']}/{info['seam_ratio_ogg']} edge {info['edge_rms_dLR_db']}" if 'seam_ratio_ogg' in info else "")
              + (f" | spec {le.get('spec_jump_pct')}pct lvl {le.get('zone_level_dev_db')}dB/{le.get('zone_level_pct')}pct" if le else "")
              + (f" | bell fitSNR {info['bell_model']['fit_snr_db']}" if 'bell_model' in info else ""))
    json.dump(rep, open(rep_path, "w"), ensure_ascii=False, indent=1, default=str)
