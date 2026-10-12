#!/usr/bin/env python3
"""mc.py — compositing, grading, retiming, audio and encoding recipes for the motion films (stdlib + ffmpeg).

Every subcommand prints the exact ffmpeg command it runs (copy it, tweak it). Frame directories hold
frame_00000.png ... (what capture.py and render.mjs write); anything else ffmpeg reads works as input too.

  comp      stack layers on a base: alpha "over" (HTML RGBA frames), or screen / add / multiply / softlight /
            overlay blends (light leaks, glows rendered on black); per-layer opacity and start offset
  grade     look: 3D LUT (.cube) and/or eq / colorbalance / curves, film grain, vignette, light leak, letterbox
  blendto   cross-fade A into B over [at, at+dur] frame-exactly (e.g. graded -> ungraded game plate before handover)
  ramp      speed ramp (time remap by keys out_s:src_s), nearest-frame or frame-blend
  mix       place audio files on a timeline (start, gain, fades) -> one WAV
  loudnorm  two-pass EBU R128 normalisation (default -16 LUFS / -1 dBTP)
  measure   integrated loudness, LRA, true peak (JSON)
  spectrum  spectrogram PNG of an audio file (look at it with the Read tool)
  master    H.264 mp4 (CRF 14, yuv420p bt709, AAC 256k, faststart) + ProRes 422 HQ mov
  ogv       in-game intro: Ogg Theora + Vorbis (.ogv), plus the audio alone as .ogg for the fallback path

Run `python3 tools/motion/comp/mc.py <cmd> -h` for the options of one command. README: tools/motion/README.md.
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys

FFMPEG = os.path.expanduser("~/.local/bin/ffmpeg")
HERE = os.path.dirname(os.path.abspath(__file__))
LUT_DIR = os.path.join(HERE, "luts")


def run(cmd, capture=False):
    print("+ " + " ".join(shlex.quote(c) for c in cmd), flush=True)
    if capture:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if p.returncode != 0:
            print(p.stdout[-3000:], file=sys.stderr)
            sys.exit(p.returncode)
        return p.stdout
    rc = subprocess.call(cmd)
    if rc != 0:
        sys.exit(rc)
    return ""


def src_args(path, fps, start_frame=0):
    """ffmpeg input args for a frame dir / pattern / video / still"""
    if os.path.isdir(path):
        return ["-framerate", str(fps), "-start_number", str(start_frame), "-i", os.path.join(path, "frame_%05d.png")]
    if "%" in path:
        return ["-framerate", str(fps), "-start_number", str(start_frame), "-i", path]
    if path.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
        return ["-loop", "1", "-framerate", str(fps), "-i", path]
    return ["-i", path]


def out_args(out, fps):
    if out.endswith("/") or os.path.isdir(out) or not os.path.splitext(out)[1]:
        os.makedirs(out, exist_ok=True)
        return ["-start_number", "0", "-c:v", "png", "-pix_fmt", "rgb24", os.path.join(out, "frame_%05d.png")]
    if out.endswith(".mov"):   # lossless-enough intermediate: ProRes 4444 (keeps alpha if present)
        return ["-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuva444p10le", "-vendor", "apl0", "-r", str(fps), out]
    return ["-r", str(fps), out]


# ------------------------------------------------------------------ comp
BLENDS = {"screen", "addition", "add", "multiply", "softlight", "overlay", "lighten", "darken", "hardlight", "difference"}


def cmd_comp(a):
    inputs = src_args(a.base, a.fps)
    chains = ["[0:v]format=gbrp,setsar=1[b0]"]
    cur = "b0"
    for k, spec in enumerate(a.layer, start=1):
        # PATH[:mode[:opacity[:start_s]]]
        parts = spec.split(":")
        path, mode = parts[0], (parts[1] if len(parts) > 1 else "over")
        op = float(parts[2]) if len(parts) > 2 else 1.0
        start = float(parts[3]) if len(parts) > 3 else 0.0
        inputs += src_args(path, a.fps)
        lab = "l%d" % k
        shift = ",setpts=PTS+%f/TB" % start if start else ""
        if mode == "over":
            chains.append("[%d:v]format=rgba,scale=%d:%d%s%s[%s]" % (k, a.width, a.height, shift, (",colorchannelmixer=aa=%g" % op) if op < 1 else "", lab))
            chains.append("[%s][%s]overlay=format=auto:eof_action=pass,format=gbrp[b%d]" % (cur, lab, k))
        elif mode in BLENDS:
            m = "addition" if mode == "add" else mode
            chains.append("[%d:v]format=gbrp,scale=%d:%d:flags=bicubic%s[%s]" % (k, a.width, a.height, shift, lab))
            chains.append("[%s][%s]blend=all_mode=%s:all_opacity=%g:eof_action=pass,format=gbrp[b%d]" % (cur, lab, m, op, k))
        else:
            sys.exit("unknown layer mode %s (over or one of %s)" % (mode, sorted(BLENDS)))
        cur = "b%d" % k
    chains.append("[%s]null[out]" % cur)
    frames = ["-frames:v", str(a.frames)] if a.frames else []
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-stats", "-y"] + inputs + ["-filter_complex", ";".join(chains), "-map", "[out]"] + frames + out_args(a.out, a.fps))


# ------------------------------------------------------------------ grade
def ensure_lut(name):
    if os.path.exists(name):
        return name
    p = os.path.join(LUT_DIR, name if name.endswith(".cube") else name + ".cube")
    if not os.path.exists(p):
        run([os.path.expanduser("~/.local/bin/uv"), "run", "-q", "--offline", "--with", "numpy", "python", os.path.join(HERE, "make_luts.py")])
    if not os.path.exists(p):
        sys.exit("no such LUT: %s (see make_luts.py for the built-in looks)" % name)
    return p


def grade_filters(a):
    f = []
    if a.lut:
        f.append("lut3d=file='%s':interp=tetrahedral" % ensure_lut(a.lut).replace("'", r"\'"))
    if a.eq:
        f.append("eq=" + a.eq)                         # e.g. contrast=1.06:saturation=1.1:gamma=0.98
    if a.balance:
        f.append("colorbalance=" + a.balance)          # e.g. rs=.04:bs=-.05:rh=.03:bh=-.04 (shadows/mids/highlights)
    if a.curves:
        f.append("curves=" + a.curves)                 # e.g. preset=medium_contrast or r='0/0 .5/.55 1/1'
    if a.vignette:
        # angle controls the radius: PI/5 is ffmpeg's default; strength via mix with the original
        f.append("vignette=angle=%g:mode=forward" % (0.35 + 0.6 * a.vignette))
    return f


def cmd_grade(a):
    inputs = src_args(a.inp, a.fps)
    # every branch ends in an explicit format=gbrp: vignette (and others) silently switch to YUV, and blend then
    # mixes a YUV input with an RGB one plane by plane (measured: a strong magenta cast)
    g = ["[0:v]format=gbrp,setsar=1" + "".join("," + x for x in grade_filters(a)) + ",format=gbrp[g0]"]
    cur, n = "g0", 1
    if a.leak:
        inputs += src_args(a.leak, a.fps)
        g.append("[%d:v]format=gbrp,scale=%d:%d:flags=bicubic[lk]" % (n, a.width, a.height))
        g.append("[%s][lk]blend=all_mode=screen:all_opacity=%g:eof_action=pass,format=gbrp[g%d]" % (cur, a.leak_opacity, n))
        cur, n = "g%d" % n, n + 1
    if a.grain:
        # monochrome, temporally random grain, softened, laid over with an overlay blend
        g.append("color=c=0x808080:s=%dx%d:r=%s,format=gray,noise=alls=%d:allf=t,gblur=sigma=%g,format=gbrp[gr]" % (a.width, a.height, a.fps, int(60 * a.grain + 10), a.grain_size))
        g.append("[%s][gr]blend=all_mode=overlay:all_opacity=%g:shortest=1,format=gbrp[g%d]" % (cur, min(1.0, 0.35 + a.grain), n))
        cur, n = "g%d" % n, n + 1
    if a.letterbox:
        bar = int(round((a.height - a.width / a.letterbox) / 2))
        g.append("[%s]drawbox=x=0:y=0:w=iw:h=%d:color=black:t=fill,drawbox=x=0:y=ih-%d:w=iw:h=%d:color=black:t=fill[g%d]" % (cur, bar, bar, bar, n))
        cur, n = "g%d" % n, n + 1
    g.append("[%s]null[out]" % cur)
    frames = ["-frames:v", str(a.frames)] if a.frames else []
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-stats", "-y"] + inputs + ["-filter_complex", ";".join(g), "-map", "[out]"] + frames + out_args(a.out, a.fps))


# ------------------------------------------------------------------ blendto
def cmd_blendto(a):
    """frame-aligned A -> B cross-fade over [at, at+dur], e.g. graded -> ungraded game plate before a handover.
    Output = A before `at`, a linear dissolve of the SAME moments of A and B, then B; as long as B.
    Frame dirs are cut at the input (-t / -start_number) so xfade sees clean constant-rate streams
    (trim + fps drops B's last frame — measured). Verified frame-exact: out[i] == A[i] before, == B[i] after."""
    fa, fb = float(a.fps), float(a.fps)
    first_b = int(round(a.at * fb))
    if os.path.isdir(a.a) and os.path.isdir(a.b):
        inputs = ["-framerate", a.fps, "-t", "%g" % (a.at + a.dur), "-i", os.path.join(a.a, "frame_%05d.png"),
                  "-framerate", a.fps, "-start_number", str(first_b), "-i", os.path.join(a.b, "frame_%05d.png")]
        pre_a, pre_b = "", ""
    else:
        inputs = src_args(a.a, a.fps) + src_args(a.b, a.fps)
        pre_a = ",trim=end=%g,setpts=PTS-STARTPTS,fps=%s" % (a.at + a.dur, a.fps)
        pre_b = ",trim=start=%g,setpts=PTS-STARTPTS,fps=%s" % (a.at, a.fps)
    g = ("[0:v]format=gbrp,setsar=1%s[a];[1:v]format=gbrp,setsar=1,scale=%d:%d%s[b];"
         "[a][b]xfade=transition=fade:duration=%g:offset=%g,format=gbrp[out]" % (pre_a, a.width, a.height, pre_b, a.dur, a.at))
    frames = ["-frames:v", str(a.frames)] if a.frames else []
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-stats", "-y"] + inputs + ["-filter_complex", g, "-map", "[out]"] + frames + out_args(a.out, a.fps))


# ------------------------------------------------------------------ ramp
def cmd_ramp(a):
    """keys "out_s:src_s,..." (monotonic). Output time T -> source time S by piecewise-linear interpolation.
    ffmpeg's setpts needs the inverse (source pts -> output pts), which is piecewise linear too."""
    keys = [tuple(float(x) for x in k.split(":")) for k in a.map.split(",")]
    keys.sort()
    expr = None
    for (o0, s0), (o1, s1) in reversed(list(zip(keys, keys[1:]))):
        seg = "(%g+(T-%g)*%g)" % (o0, s0, (o1 - o0) / (s1 - s0) if s1 != s0 else 0.0)
        expr = seg if expr is None else "if(lt(T,%g),%s,%s)" % (s1, seg, expr)
    last_o, last_s = keys[-1]
    expr = "if(gte(T,%g),%g+(T-%g),%s)" % (last_s, last_o, last_s, expr)
    vf = "setpts='(%s)/TB'" % expr
    if a.blend:
        vf += ",framerate=fps=%s:interp_start=0:interp_end=255:scene=100" % a.fps
    else:
        vf += ",fps=%s" % a.fps
    dur = ["-t", str(keys[-1][0])] if not a.tail else []
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-stats", "-y"] + src_args(a.inp, a.fps) + ["-vf", vf] + dur + out_args(a.out, a.fps))


# ------------------------------------------------------------------ audio
def cmd_mix(a):
    """tracks: FILE[@start_s][:gain_db][:fadein_s][:fadeout_s]"""
    inputs, chains, labels = [], [], []
    for k, spec in enumerate(a.track):
        m = re.match(r"^(.*?)(?:@([\d.]+))?(?::(-?[\d.]+))?(?::([\d.]+))?(?::([\d.]+))?$", spec)
        path, start, gain, fi, fo = m.group(1), float(m.group(2) or 0), float(m.group(3) or 0), float(m.group(4) or 0), float(m.group(5) or 0)
        inputs += ["-i", path]
        f = "[%d:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,volume=%gdB" % (k, gain)
        if fi:
            f += ",afade=t=in:d=%g" % fi
        if fo:
            f += ",afade=t=out:st=%g:d=%g" % (max(0.0, duration_of(path) - fo), fo)
        if start:
            f += ",adelay=%d:all=1" % int(round(start * 1000))
        chains.append(f + "[a%d]" % k)
        labels.append("[a%d]" % k)
    chains.append("%samix=inputs=%d:normalize=0:dropout_transition=0,atrim=0:%g,apad=whole_dur=%g[out]" % ("".join(labels), len(labels), a.duration, a.duration))
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + inputs + ["-filter_complex", ";".join(chains), "-map", "[out]", "-c:a", "pcm_s24le", "-ar", "48000", a.out])


def duration_of(path):
    p = subprocess.run([FFMPEG, "-hide_banner", "-i", path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", p.stdout)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else 0.0


def measure(path):
    out = run([FFMPEG, "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"], capture=True)
    s = out[out.rfind("Summary:"):]
    g = lambda k: float(re.search(k + r":\s+(-?[\d.]+|-inf)", s).group(1).replace("-inf", "-999"))
    return {"integrated_lufs": g("I"), "lra_lu": g("LRA"), "true_peak_dbtp": g("Peak")}


def cmd_measure(a):
    for p in a.inp:
        print(json.dumps({"file": p, **measure(p)}))


def cmd_loudnorm(a):
    target = "I=%g:TP=%g:LRA=%g" % (a.I, a.TP, a.LRA)
    out = run([FFMPEG, "-hide_banner", "-nostats", "-i", a.inp, "-af", "loudnorm=%s:print_format=json" % target, "-f", "null", "-"], capture=True)
    j = json.loads(out[out.rfind("{"):out.rfind("}") + 1])
    second = ("loudnorm=%s:measured_I=%s:measured_TP=%s:measured_LRA=%s:measured_thresh=%s:offset=%s:linear=true:print_format=summary"
              % (target, j["input_i"], j["input_tp"], j["input_lra"], j["input_thresh"], j["target_offset"]))
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", a.inp, "-af", second + ",aresample=48000", "-c:a", "pcm_s24le", "-ar", "48000", a.out])
    print(json.dumps({"pass1": j, "result": measure(a.out)}, indent=1))


def cmd_spectrum(a):
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", a.inp, "-lavfi",
         "showspectrumpic=s=%s:legend=1:scale=log:fscale=log:color=intensity" % a.size, a.out])
    print(a.out)


# ------------------------------------------------------------------ encode
BT709 = ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"]


def cmd_master(a):
    base = a.out[:-4] if a.out.endswith((".mp4", ".mov")) else a.out
    os.makedirs(os.path.dirname(os.path.abspath(base)) or ".", exist_ok=True)
    inputs = src_args(a.inp, a.fps)
    amap = []
    if a.audio:
        inputs += ["-i", a.audio]
        amap = ["-map", "1:a:0"]
    frames = ["-frames:v", str(a.frames)] if a.frames else []
    vf = "scale=out_color_matrix=bt709:out_range=tv:flags=lanczos+accurate_rnd+full_chroma_int"
    tag = ",setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"   # PNG frames carry an sRGB trc tag that would win over -color_trc
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-stats", "-y"] + inputs + ["-map", "0:v:0"] + amap + frames + [
        "-vf", vf + ",format=yuv420p" + tag, "-c:v", "libx264", "-preset", a.preset, "-crf", str(a.crf), "-profile:v", "high", "-level", "4.2",
        "-x264-params", "keyint=%d:min-keyint=%d" % (int(a.fps) * 2, int(a.fps)), "-r", str(a.fps)] + BT709 +
        (["-c:a", "aac", "-b:a", "320k", "-ar", "48000"] if a.audio else []) + ["-shortest", "-movflags", "+faststart", base + ".mp4"])
    if not a.no_prores:
        run([FFMPEG, "-hide_banner", "-loglevel", "error", "-stats", "-y"] + inputs + ["-map", "0:v:0"] + amap + frames + [
            "-vf", vf + ",format=yuv422p10le" + tag, "-c:v", "prores_ks", "-profile:v", "3", "-vendor", "apl0", "-r", str(a.fps)] + BT709 +
            (["-c:a", "pcm_s24le", "-ar", "48000"] if a.audio else []) + ["-shortest", base + ".mov"])
    for f in [base + ".mp4"] + ([] if a.no_prores else [base + ".mov"]):
        print("%s  %.1f MB" % (f, os.path.getsize(f) / 1e6))


def cmd_ogv(a):
    base = a.out[:-4] if a.out.endswith(".ogv") else a.out
    os.makedirs(os.path.dirname(os.path.abspath(base)) or ".", exist_ok=True)
    inputs = src_args(a.inp, a.fps)
    amap = []
    if a.audio:
        inputs += ["-i", a.audio]
        amap = ["-map", "1:a:0"]
    frames = ["-frames:v", str(a.frames)] if a.frames else []
    # BT.601 on purpose: Godot 4.7.1's Theora player converts YUV->RGB with BT.601 whatever the stream says (measured on
    # its own decoded texture by all four intro reviews: a BT.709 encode plays back up to 4 levels off and the dissolve
    # into the live act changes colour). Series finishing pass, art-src/motion/series/README.md.
    vf = ("scale=%d:%d:out_color_matrix=bt601:out_range=tv:flags=lanczos+accurate_rnd,format=yuv420p,"
          "setparams=color_primaries=bt709:color_trc=bt709:colorspace=smpte170m:range=tv" % (a.width, a.height))
    vq = ["-b:v", a.vbitrate] if a.vbitrate else ["-q:v", str(a.vq)]
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-stats", "-y"] + inputs + ["-map", "0:v:0"] + amap + frames + [
        "-vf", vf, "-c:v", "libtheora"] + vq + ["-g", str(a.keyint), "-r", str(a.fps)] +
        (["-c:a", "libvorbis", "-q:a", str(a.aq), "-ar", "48000", "-ac", "2"] if a.audio else []) + ["-shortest", base + ".ogv"])
    if a.audio:
        run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", a.audio, "-c:a", "libvorbis", "-q:a", str(a.aq), "-ar", "48000", "-ac", "2", base + ".ogg"])
    for f in [base + ".ogv"] + ([base + ".ogg"] if a.audio else []):
        print("%s  %.2f MB" % (f, os.path.getsize(f) / 1e6))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)

    def common(p, frames=True):
        p.add_argument("--fps", default="30")
        p.add_argument("--width", type=int, default=1920)
        p.add_argument("--height", type=int, default=1080)
        if frames:
            p.add_argument("--frames", type=int, default=0, help="limit output frames")

    p = sp.add_parser("comp", help="stack layers on a base")
    p.add_argument("--base", required=True)
    p.add_argument("--layer", action="append", default=[], help="PATH[:over|screen|add|multiply|softlight|overlay[:opacity[:start_s]]]")
    p.add_argument("--out", required=True, help="frame dir, .mov (ProRes 4444) or any ffmpeg output")
    common(p)
    p.set_defaults(fn=cmd_comp)

    p = sp.add_parser("grade", help="LUT / eq / balance / curves, grain, vignette, light leak, letterbox")
    p.add_argument("inp")
    p.add_argument("--out", required=True)
    p.add_argument("--lut", help="a .cube file or a built-in look: " + ", ".join(["lshu_dusk", "lshu_night", "lshu_parchment", "lshu_morning", "lshu_bleach"]))
    p.add_argument("--eq")
    p.add_argument("--balance")
    p.add_argument("--curves")
    p.add_argument("--vignette", type=float, default=0.0, help="0..1")
    p.add_argument("--grain", type=float, default=0.0, help="0..1 (0.15 subtle, 0.35 filmic)")
    p.add_argument("--grain-size", type=float, default=0.7)
    p.add_argument("--leak", help="light-leak frames (black background), screen-blended")
    p.add_argument("--leak-opacity", type=float, default=0.6)
    p.add_argument("--letterbox", type=float, default=0.0, help="aspect, e.g. 2.39")
    common(p)
    p.set_defaults(fn=cmd_grade)

    p = sp.add_parser("blendto", help="cross-fade sequence A into B over [at, at+dur]")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--at", type=float, required=True)
    p.add_argument("--dur", type=float, default=1.5)
    p.add_argument("--out", required=True)
    common(p)
    p.set_defaults(fn=cmd_blendto)

    p = sp.add_parser("ramp", help="speed ramp by time-remap keys")
    p.add_argument("inp")
    p.add_argument("--out", required=True)
    p.add_argument("--map", required=True, help='"out_s:src_s,..." e.g. "0:0,1:1,3:1.6,4:3" (slow-mo 1..3 s, then fast)')
    p.add_argument("--blend", action="store_true", help="blend neighbouring frames instead of nearest")
    p.add_argument("--tail", action="store_true", help="keep the source after the last key")
    common(p, frames=False)
    p.set_defaults(fn=cmd_ramp)

    p = sp.add_parser("mix", help="audio tracks on a timeline -> WAV")
    p.add_argument("--track", action="append", required=True, help="FILE[@start_s][:gain_db][:fadein_s][:fadeout_s]")
    p.add_argument("--duration", type=float, required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(fn=cmd_mix)

    p = sp.add_parser("loudnorm", help="two-pass EBU R128")
    p.add_argument("inp")
    p.add_argument("--out", required=True)
    p.add_argument("--I", type=float, default=-16.0)
    p.add_argument("--TP", type=float, default=-1.0)
    p.add_argument("--LRA", type=float, default=11.0)
    p.set_defaults(fn=cmd_loudnorm)

    p = sp.add_parser("measure", help="loudness / true peak")
    p.add_argument("inp", nargs="+")
    p.set_defaults(fn=cmd_measure)

    p = sp.add_parser("spectrum", help="spectrogram PNG")
    p.add_argument("inp")
    p.add_argument("--out", required=True)
    p.add_argument("--size", default="1600x600")
    p.set_defaults(fn=cmd_spectrum)

    p = sp.add_parser("master", help="H.264 mp4 + ProRes 422 HQ mov")
    p.add_argument("inp")
    p.add_argument("--audio")
    p.add_argument("--out", required=True, help="path without extension (or .mp4)")
    p.add_argument("--crf", type=int, default=14)
    p.add_argument("--preset", default="slow")
    p.add_argument("--no-prores", action="store_true")
    common(p)
    p.set_defaults(fn=cmd_master)

    p = sp.add_parser("ogv", help="in-game intro: Theora + Vorbis")
    p.add_argument("inp")
    p.add_argument("--audio")
    p.add_argument("--out", required=True)
    p.add_argument("--vq", type=int, default=8, help="Theora quality 0..10 (ignored with --vbitrate)")
    p.add_argument("--vbitrate", help="e.g. 7M for a size target (not recommended: one-pass ABR starves hard moments)")
    p.add_argument("--aq", type=int, default=5, help="Vorbis quality 0..10 (5 ~ 160 kbps)")
    p.add_argument("--keyint", type=int, default=60)
    common(p)
    p.set_defaults(fn=cmd_ogv)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
