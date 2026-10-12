#!/usr/bin/env python3
"""第四幕「L叔在哪儿」· acts 1-3 control snapshots (read-only use of their existing capture paths).

Usage: lshu_acts_snapshot.py <out_dir> <tag> [--slot=N] [--only=name,...]
       lshu_acts_snapshot.py compare <before_dir> <after_dir> [--json=OUT]   (numpy + pillow)
Runs each act's normal capture path (tools/traveler/capture_traveler.gd, fixed 1920x1080
SubViewport, MSAA 4x) with a parked 400x225 window, writes <name>_<tag>.png/.json/.log and
prints a strict error count (any line containing ERROR or WARNING, nonzero exit, capture_error).
Determinism: Godot's --fixed-fps 60 makes every delta-driven clock identical run to run;
Panti additionally uses its own --motion-freeze.
"""
import json, os, subprocess, sys, time

ROOT = "/Users/chengzeyuan/Developer/SilkRoad"
GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"
ACTS = {
    "changan_day": ["--view=changan", "--day", "--far"],
    "panti_morning": ["--capture-scene=res://scenes/traveler/panti_main.tscn", "--view=panti", "--morning", "--motion-freeze"],
    "panti_midnight": ["--capture-scene=res://scenes/traveler/panti_main.tscn", "--view=panti", "--midnight", "--motion-freeze"],
    "baghdad": ["--capture-scene=res://scenes/traveler/baghdad_main.tscn", "--view=baghdad"],
}


def park_args(slot):
    # Same slot geometry as the lshu viewer (--park): 400x225 px from the bottom-right of the
    # usable rect (0,60)+(3840,1922) on this Mac.
    ux, uy, uw, uh = 0, 60, 3840, 1922
    w, h = 400, 225
    x = ux + uw - (slot % 4 + 1) * (w + 8)
    y = uy + uh - (slot // 4 + 1) * (h + 36)
    return ["--position", "%d,%d" % (x, y), "--resolution", "%dx%d" % (w, h)]


def strict_errors(log):
    return [ln for ln in log.splitlines() if "ERROR" in ln or "WARNING" in ln]


def run(name, out_dir, tag, slot, timeout=420):
    png = os.path.join(out_dir, "%s_%s.png" % (name, tag))
    for p in (png, png[:-4] + ".json"):
        if os.path.exists(p):
            os.remove(p)
    cmd = [GODOT, "--path", ROOT, "--fixed-fps", "60"] + park_args(slot) + [
        "--script", "res://tools/traveler/capture_traveler.gd", "--"] + ACTS[name] + [
        "--capture=" + png, "--capture-preview"]
    t0 = time.time()
    code = None
    try:
        pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        log = (pr.stdout or "") + (pr.stderr or ""); code = pr.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        log = out + "\nTIMEOUT"
    open(png[:-4] + ".log", "w", encoding="utf-8").write(" ".join(cmd) + "\n\n" + log)
    errs = strict_errors(log)
    cap_err = None
    j = png[:-4] + ".json"
    if os.path.exists(j):
        try:
            cap_err = json.load(open(j)).get("capture_error")
        except Exception:
            cap_err = "json-unreadable"
    ok = code == 0 and not errs and os.path.exists(png) and cap_err in (0, None) and "TIMEOUT" not in log
    return {"name": name, "tag": tag, "png": png, "exit": code, "errors": len(errs), "error_lines": errs[:6],
            "capture_error": cap_err, "seconds": round(time.time() - t0, 1), "ok": ok}


def main(argv):
    out_dir = argv[0]; tag = argv[1]; slot = 1; only = list(ACTS)
    for a in argv[2:]:
        if a.startswith("--slot="): slot = int(a.split("=", 1)[1])
        if a.startswith("--only="): only = a.split("=", 1)[1].split(",")
    os.makedirs(out_dir, exist_ok=True)
    results = [run(n, out_dir, tag, slot) for n in only]
    for r in results:
        print(json.dumps(r, ensure_ascii=False))
    json.dump(results, open(os.path.join(out_dir, "run_%s.json" % tag), "w"), indent=1, ensure_ascii=False)


def _entry(argv):
    if argv and argv[0] == "compare":
        jout = next((a.split("=", 1)[1] for a in argv if a.startswith("--json=")), None)
        return compare(argv[1], argv[2], jout)
    main(argv)
    return 0


# ---------------------------------------------------------------------------------------------- compare
COMPARE_DOC = """compare mode (needs numpy + pillow):
  lshu_acts_snapshot.py compare <before_dir> <after_dir> [--json=OUT]
Each after_<name>_<tag>.png is compared with every before_<name>_*.png. Unchanged means: identical to one before
capture, or inside the before run-to-run noise envelope (max |diff| <= the envelope's max and differing pixels
<= 2x the envelope's count). The envelope is measured from the before captures of the same act."""


def compare(before, after, jout=None):
    import glob as _g
    import numpy as np
    from PIL import Image
    load = lambda p: np.asarray(Image.open(p).convert("RGB")).astype(np.int16)
    rows = []
    for name in ACTS:
        bs = sorted(_g.glob(os.path.join(before, name + "_*.png")))
        as_ = sorted(_g.glob(os.path.join(after, name + "_*.png")))
        if not bs or not as_:
            rows.append({"act": name, "missing": True, "pass": False})
            continue
        env_max, env_px = 0, 0
        for i in range(len(bs)):
            for j in range(i + 1, len(bs)):
                d = np.abs(load(bs[i]) - load(bs[j]))
                env_max = max(env_max, int(d.max())); env_px = max(env_px, int((d.max(axis=2) > 0).sum()))
        for a in as_:
            A = load(a)
            best = None
            for b in bs:
                d = np.abs(A - load(b))
                r = {"after": os.path.basename(a), "before": os.path.basename(b), "identical": bool((d == 0).all()), "mean": float(d.mean()), "max": int(d.max()), "px_diff": int((d.max(axis=2) > 0).sum())}
                if best is None or (r["px_diff"], r["max"]) < (best["px_diff"], best["max"]):
                    best = r
            ok = best["identical"] or (best["max"] <= max(env_max, 0) and best["px_diff"] <= 2 * env_px and env_max > 0)
            rows.append(dict(act=name, envelope={"max": env_max, "px_diff": env_px, "before_runs": len(bs)}, pass_=ok, **best))
    for r in rows:
        r["pass"] = r.pop("pass_", r.get("pass", False))
        print(json.dumps(r, ensure_ascii=False))
    rep = {"schema": "lshu.acts-unchanged.v1", "rows": rows, "pass": all(r["pass"] for r in rows)}
    if jout:
        json.dump(rep, open(jout, "w"), indent=1, ensure_ascii=False)
    print("ACTS_UNCHANGED", rep["pass"])
    return 0 if rep["pass"] else 1


if __name__ == "__main__":
    sys.exit(_entry(sys.argv[1:]))
