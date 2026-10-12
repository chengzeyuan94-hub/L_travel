#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· continuous light: run and analyse qa/lshu_light_sweep.gd.

  run      one Godot run per tile (strict error rule: any ERROR / WARNING line, nonzero exit, TIMEOUT)
  analyse  mean luminance (Rec.709 luma of the sRGB frame, 0-255) of every saved frame (480x270 Lanczos of 1920x1080):
             clock  per transition of the simulated day: whole change, largest one-minute step, smoothness
                    (largest step / average step; a smoothstep blend of a linear quantity gives 1.5), per-pixel P99
                    and max of |Δluma| between consecutive minutes; minutes outside transitions must not change
             even   the same per pair for t = k/N
           exact    the full-size exact preset frames reached after blends vs the reference captures made before
                    the change (<ref>/<tile>_<light>.png, lamp off) and first vs last midnight frame
  sheet    light_sweep.png: luminance through each transition per tile, per-minute steps vs the old hard cut,
           and a filmstrip of one tile

  python3 tools/traveler/lshu/qa/lshu_light_sweep.py run --out=DIR --slot=22 --tiles=<id>,<id> [--extra=--hold-lamp,--night-lamp=off]
  uv run --with pillow --with numpy [--with matplotlib] python tools/traveler/lshu/qa/lshu_light_sweep.py analyse --out=DIR
        [--ref=DIR] [--json=PATH]
  uv run --with pillow --with numpy --with matplotlib python tools/traveler/lshu/qa/lshu_light_sweep.py sheet --out=DIR
        --png=PATH [--strip=TILE]
"""
import json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")


def strict_errors(log):
    return [ln.strip() for ln in log.splitlines() if "ERROR" in ln or "WARNING" in ln or ln.strip() == "TIMEOUT"]


def cmd_run(a):
    out = os.path.abspath(a["out"]); os.makedirs(out, exist_ok=True)
    extra = [x for x in a.get("extra", "").split(",") if x]
    errs_total = 0
    for tile in a["tiles"].split(","):
        cmd = [GODOT, "--path", ROOT, "--script", "res://tools/traveler/lshu/qa/lshu_light_sweep.gd", "--", "--tile=" + tile, "--light=night",
               "--motion-freeze", "--park=%s" % a.get("slot", "22"), "--out=" + out, "--mode=" + a.get("mode", "both"), "--steps=" + a.get("steps", "20"),
               "--settle=" + a.get("settle", "12")] + extra
        t0 = time.time(); rc = None
        try:
            pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=int(a.get("timeout", 900)))
            log = pr.stdout + pr.stderr; rc = pr.returncode
        except subprocess.TimeoutExpired as e:
            log = (e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")) + "\nTIMEOUT"
        os.makedirs(os.path.join(out, tile), exist_ok=True)
        open(os.path.join(out, tile, "run.log"), "w", encoding="utf-8").write(" ".join(cmd) + "\n\n" + log)
        errs = strict_errors(log) + ([] if rc == 0 else ["EXIT %s" % rc])
        errs_total += len(errs)
        print("%-6s %6.1fs rc=%s errors=%d" % (tile, time.time() - t0, rc, len(errs)), flush=True)
        for e in errs[:5]:
            print("   ! " + e[:200], flush=True)
    print("SWEEP_RUN_DONE errors=%d" % errs_total)
    return 1 if errs_total else 0


def luma(arr):
    return 0.2126 * arr[..., 0] + 0.7152 * arr[..., 1] + 0.0722 * arr[..., 2]


def load(path):
    import numpy as np
    from PIL import Image
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)


def analyse_tile(d, ref):
    import numpy as np
    res = {"tile": os.path.basename(d)}
    for mode in ("clock", "even"):
        p = os.path.join(d, "sweep_%s.json" % mode)
        if not os.path.exists(p):
            continue
        sw = json.load(open(p, encoding="utf-8"))
        rows = sw["samples"]
        ys, frames = [], []
        for r in rows:
            img = load(os.path.join(d, r["file"]))
            y = luma(img)
            frames.append(y); ys.append(float(y.mean()))
        steps = []
        for i in range(1, len(rows)):
            dy = frames[i] - frames[i - 1]
            steps.append({"from": i - 1, "to": i, "d_mean": ys[i] - ys[i - 1], "p99": float(np.percentile(np.abs(dy), 99)), "max": float(np.abs(dy).max())})
        groups = []
        if mode == "clock":
            # consecutive minutes form runs; a run = one transition with its exact ends
            cur = [0]
            for i in range(1, len(rows)):
                if rows[i]["minute"] == rows[i - 1]["minute"] + 1:
                    cur.append(i)
                else:
                    groups.append(cur); cur = [i]
            groups.append(cur)
            gaps = []
            for g in range(1, len(groups)):
                a_i, b_i = groups[g - 1][-1], groups[g][0]
                gaps.append({"from_minute": rows[a_i]["minute"], "to_minute": rows[b_i]["minute"], "d_mean": ys[b_i] - ys[a_i],
                             "max_px": float(np.abs(frames[b_i] - frames[a_i]).max())})
            res["clock_constant_gaps"] = gaps
        else:
            n = sw["samples"][-1]["k"] if rows else 0
            for pair in dict.fromkeys(r["pair"] for r in rows):
                groups.append([i for i, r in enumerate(rows) if r["pair"] == pair])
        trans = []
        for g in groups:
            if len(g) < 2:
                continue
            gs = [s for s in steps if s["from"] in g and s["to"] in g]
            total = ys[g[-1]] - ys[g[0]]
            mx = max(gs, key=lambda s: abs(s["d_mean"]))
            avg = abs(total) / max(len(gs), 1)
            la, lb = rows[g[1]]["light"], rows[g[-2]]["light"]
            name = "%s>%s" % (la["preset_a"], la["preset_b"])
            t = {"transition": name, "samples": len(g), "steps": len(gs), "luma_start": ys[g[0]], "luma_end": ys[g[-1]], "hard_cut": abs(total),
                 "max_step": abs(mx["d_mean"]), "avg_step": avg, "smoothness": abs(mx["d_mean"]) / avg if avg > 1e-9 else None,
                 "max_step_p99_px": max(s["p99"] for s in gs), "max_step_max_px": max(s["max"] for s in gs),
                 "curve": [ys[i] for i in g]}
            if mode == "clock":
                t["minutes"] = [rows[g[0]]["hhmm"], rows[g[-1]]["hhmm"]]
                t["worst_minute"] = rows[mx["to"]]["hhmm"]
            trans.append(t)
        res[mode] = {"frames": len(rows), "max_step": max((abs(s["d_mean"]) for s in steps), default=0.0), "transitions": trans,
                     "max_step_p99_px": max((s["p99"] for s in steps), default=0.0)}
        if mode == "clock":
            ex = []
            fulls = [r for r in rows if r.get("full")]
            for r in fulls:
                e = {"minute": r["hhmm"], "light": r["light_name"], "file": r["full"]}
                if ref:
                    rp = os.path.join(ref, "%s_%s.png" % (res["tile"], r["light_name"]))
                    if os.path.exists(rp):
                        a_img = load(os.path.join(d, r["full"])); b_img = load(rp)
                        diff = np.abs(a_img - b_img)
                        e.update(ref=os.path.relpath(rp, ROOT), mean_abs_diff=float(diff.mean()), max_abs_diff=float(diff.max()), pixels_differing=int((diff.max(axis=2) > 0).sum()))
                ex.append(e)
            if len(fulls) >= 2:
                a_img = load(os.path.join(d, fulls[0]["full"])); b_img = load(os.path.join(d, fulls[-1]["full"]))
                res["midnight_first_vs_last"] = {"first": fulls[0]["hhmm"], "last": fulls[-1]["hhmm"], "max_abs_diff": float(np.abs(a_img - b_img).max())}
            res["exact"] = ex
    return res


def cmd_analyse(a):
    out = a["out"]; ref = a.get("ref")
    tiles = sorted(t for t in os.listdir(out) if os.path.isdir(os.path.join(out, t)) and os.path.exists(os.path.join(out, t, "sweep_clock.json")))
    all_res = [analyse_tile(os.path.join(out, t), ref) for t in tiles]
    summ = {"schema": "lshu.light_sweep_summary.v1", "tiles": tiles, "units": "mean Rec.709 luma of the sRGB frame, 0-255",
            "clock_max_minute_step": max((r["clock"]["max_step"] for r in all_res if "clock" in r), default=None),
            "clock_max_hard_cut": max((t["hard_cut"] for r in all_res for t in r.get("clock", {}).get("transitions", [])), default=None),
            "clock_worst_smoothness": max((t["smoothness"] or 0 for r in all_res for t in r.get("clock", {}).get("transitions", [])), default=None),
            "even_max_step": max((r["even"]["max_step"] for r in all_res if "even" in r), default=None),
            "constant_minutes_max_change": max((abs(g["d_mean"]) for r in all_res for g in r.get("clock_constant_gaps", [])), default=None),
            "constant_minutes_max_px": max((g["max_px"] for r in all_res for g in r.get("clock_constant_gaps", [])), default=None),
            "exact_vs_ref_max_abs": max((e.get("max_abs_diff", -1) for r in all_res for e in r.get("exact", [])), default=None),
            "exact_vs_ref_compared": sum(1 for r in all_res for e in r.get("exact", []) if "max_abs_diff" in e),
            "midnight_first_vs_last_max": max((r.get("midnight_first_vs_last", {}).get("max_abs_diff", -1) for r in all_res), default=None),
            "per_tile": all_res}
    text = json.dumps(summ, ensure_ascii=False, indent=1)
    if a.get("json"):
        open(a["json"], "w", encoding="utf-8").write(text + "\n")
    print(json.dumps({k: v for k, v in summ.items() if k != "per_tile"}, ensure_ascii=False))
    for r in all_res:
        for t in r.get("clock", {}).get("transitions", []):
            print("%-6s %-15s %s-%s  %2d min  luma %6.1f -> %6.1f  hard cut %5.2f  max 1-min step %4.2f (at %s)  smooth %.2f  p99px %.1f" % (
                r["tile"], t["transition"], t["minutes"][0], t["minutes"][1], t["steps"], t["luma_start"], t["luma_end"], t["hard_cut"], t["max_step"],
                t["worst_minute"], t["smoothness"] or 0, t["max_step_p99_px"]))
    return 0


def cmd_sheet(a):
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    from PIL import Image
    for fp in ("/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Light.ttc", "/Library/Fonts/Arial Unicode.ttf"):
        if os.path.exists(fp):
            font_manager.fontManager.addfont(fp)
            plt.rcParams["font.family"] = font_manager.FontProperties(fname=fp).get_name()
            break
    out = a["out"]
    summ = json.load(open(a["summary"], encoding="utf-8")) if a.get("summary") else None
    if summ is None:
        tiles = sorted(t for t in os.listdir(out) if os.path.exists(os.path.join(out, t, "sweep_clock.json")))
        per = [analyse_tile(os.path.join(out, t), None) for t in tiles]
    else:
        per = summ["per_tile"]
    names = {"night>morning": "夜 → 晨 05:10–05:50", "morning>day": "晨 → 昼 07:45–08:15", "day>sunset": "昼 → 昏 16:45–17:15", "sunset>night": "昏 → 夜 19:10–19:50"}
    order = ["night>morning", "morning>day", "day>sunset", "sunset>night"]
    fig = plt.figure(figsize=(20, 13), dpi=100, facecolor="#1b1d21")
    colors = ["#7fb3ff", "#ffb35c", "#8fe39a", "#ff7f9a", "#c9a8ff", "#f5e06b", "#66d9d9", "#e0e0e0"]
    for k, name in enumerate(order):
        ax = fig.add_axes([0.04 + k * 0.24, 0.58, 0.21, 0.33], facecolor="#24272d")
        ax2 = fig.add_axes([0.04 + k * 0.24, 0.36, 0.21, 0.16], facecolor="#24272d")
        hard = 0.0; mx = 0.0
        for j, r in enumerate(per):
            for t in r.get("clock", {}).get("transitions", []):
                if t["transition"] != name:
                    continue
                c = t["curve"]; x = list(range(len(c)))
                ax.plot(x, c, "-o", ms=2.5, lw=1.4, color=colors[j % len(colors)], label=r["tile"])
                steps = [abs(c[i] - c[i - 1]) for i in range(1, len(c))]
                ax2.plot(range(1, len(c)), steps, "-", lw=1.2, color=colors[j % len(colors)])
                hard = max(hard, t["hard_cut"]); mx = max(mx, t["max_step"])
        ax.set_title(names[name], color="#eeeeee", fontsize=14)
        ax.set_ylabel("画面平均亮度（0–255）" if k == 0 else "", color="#cccccc")
        ax2.set_ylabel("每分钟变化" if k == 0 else "", color="#cccccc")
        ax2.set_xlabel("分钟", color="#cccccc")
        ax2.axhline(hard, color="#ff5c5c", ls="--", lw=1)
        ax2.text(0.5, hard, " 旧的四档硬切：一次跳 %.1f" % hard, color="#ff8080", fontsize=10, va="bottom")
        ax2.set_ylim(0, hard * 1.25 if hard > 0 else 1)
        ax2.text(0.98, 0.55, "最大 %.2f / 分钟" % mx, color="#ffffff", fontsize=11, ha="right", transform=ax2.transAxes)
        for axx in (ax, ax2):
            axx.tick_params(colors="#bbbbbb"); [s.set_color("#555555") for s in axx.spines.values()]
        if k == 0:
            ax.legend(fontsize=9, facecolor="#24272d", labelcolor="#dddddd", edgecolor="#444444", loc="best")
    head = "光照跟着时钟连续过渡 · 模拟 24 小时、每分钟一帧 · %d 块地" % len(per)
    if summ:
        head += " · 最大每分钟变化 %.2f/255（硬切最大 %.1f/255）· 过渡两端与原四档逐像素差 %s" % (summ["clock_max_minute_step"], summ["clock_max_hard_cut"],
                                                                      ("%.0f" % summ["exact_vs_ref_max_abs"]) if summ.get("exact_vs_ref_compared") else "未比")
    fig.text(0.04, 0.955, head, color="#ffffff", fontsize=17)
    # filmstrip
    strip = a.get("strip") or per[0]["tile"]
    sw = json.load(open(os.path.join(out, strip, "sweep_clock.json"), encoding="utf-8"))
    rows = sw["samples"]
    picks = []
    for name in order:
        idx = [i for i, r in enumerate(rows) if "%s>%s" % (r["light"]["preset_a"], r["light"]["preset_b"]) == name]
        if idx:
            first = max(idx[0] - 1, 0); last = min(idx[-1] + 1, len(rows) - 1)
            for q in (0.0, 0.25, 0.5, 0.75, 1.0):
                picks.append(first + int(round(q * (last - first))))
    zh = {"morning": "晨", "day": "昼", "sunset": "昏", "night": "夜"}
    per_row = 10
    w = 0.92 / per_row
    for i, pi in enumerate(picks):
        row, col = divmod(i, per_row)
        ax = fig.add_axes([0.04 + col * w, 0.155 - row * 0.145, w * 0.97, 0.125])
        ax.imshow(np.asarray(Image.open(os.path.join(out, strip, rows[pi]["file"])).convert("RGB")))
        ax.set_axis_off()
        lt = rows[pi]["light"]
        if float(lt["blend"]) <= 0.0 or lt["preset_a"] == lt["preset_b"]:
            label = "%s %s" % (rows[pi]["hhmm"], zh.get(lt["preset_a"], lt["preset_a"]))
        else:
            label = "%s %s→%s %.2f" % (rows[pi]["hhmm"], zh.get(lt["preset_a"], ""), zh.get(lt["preset_b"], ""), float(lt["blend"]))
        ax.set_title(label, color="#dddddd", fontsize=10)
    fig.text(0.04, 0.305, "%s（带营灯）：每段过渡取 5 帧（过渡前、1/4、1/2、3/4、过渡后），数字是过渡进度" % strip, color="#dddddd", fontsize=12)
    fig.savefig(a["png"], facecolor=fig.get_facecolor())
    print("SHEET", a["png"])
    return 0


def main(argv):
    if not argv:
        print(__doc__); return 2
    a = {}
    for x in argv[1:]:
        if x.startswith("--") and "=" in x:
            k, v = x[2:].split("=", 1); a[k] = v
    return {"run": cmd_run, "analyse": cmd_analyse, "sheet": cmd_sheet}[argv[0]](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
