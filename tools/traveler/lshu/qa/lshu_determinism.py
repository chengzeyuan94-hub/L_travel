#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· determinism checks (card §4).

  bake     every pool tile is re-baked twice in memory (bake_recipes.cjs --check: JSON + proc GLB bytes) and the
           precompute is recomputed and compared with the stored bytes (precompute_tiles.gd --check). Then the
           full chain (bake --pool, --import, precompute) is re-run on disk and the SHA-256 of every tile JSON and
           proc GLB must be unchanged.
  capture  the same tile is captured twice with --motion-freeze; mean |diff| must be <= 0.5/255.

  python3 tools/traveler/lshu/qa/lshu_determinism.py bake [--tiles=A,B] [--json=OUT]
  python3 tools/traveler/lshu/qa/lshu_determinism.py capture --out=DIR --tiles=D01,J315 --lights=night,day [--slot=1] [--json=OUT]
The capture comparison needs numpy + pillow (run under ~/.local/bin/uv run -q --with pillow --with numpy python).
"""
import glob, hashlib, json, os, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")
NODE = os.environ.get("NODE_BIN", os.path.expanduser("~/.local/bin/node"))
BAKE = os.path.join(ROOT, "tools", "traveler", "lshu", "bake", "bake_recipes.cjs")


def sh(cmd, timeout=1800):
    pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    return pr.returncode, (pr.stdout or "") + (pr.stderr or "")


def strict(log):
    return [ln for ln in log.splitlines() if "ERROR" in ln or "WARNING" in ln]


def hashes():
    out = {}
    for p in sorted(glob.glob(os.path.join(ROOT, "data", "traveler", "lshu", "tiles", "*.json")) + glob.glob(os.path.join(ROOT, "assets", "traveler", "lshu", "tiles", "proc_*.glb"))):
        out[os.path.relpath(p, ROOT)] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    return out


def bake(tiles):
    sel = ("=" + tiles) if tiles else ""
    rep = {"mode": "bake"}
    rc, log = sh([NODE, BAKE, "--check" + sel])
    rows = [ln for ln in log.splitlines() if ln.startswith("DETERMINISTIC")]
    rep["in_memory_twice"] = {"exit": rc, "tiles": len(rows), "identical": sum(" true " in (r + " ") for r in rows), "vs_disk_same": sum("vs_disk=same" in r for r in rows), "lines": rows}
    rc2, log2 = sh([GODOT, "--headless", "--path", ROOT, "--script", "res://tools/traveler/lshu/bake/precompute_tiles.gd", "--"] + (["--tiles=" + tiles] if tiles else []) + ["--check"])
    rows2 = [ln for ln in log2.splitlines() if ln.startswith("PRECOMPUTE_CHECK")]
    rep["precompute_recomputed"] = {"exit": rc2, "tiles": len(rows2), "identical": sum("same=true" in r for r in rows2), "strict_errors": strict(log2)}
    before = hashes()
    rc3, log3 = sh([NODE, BAKE, "--pool" + sel])
    rc4, log4 = sh([GODOT, "--headless", "--path", ROOT, "--import"])
    rc5, log5 = sh([GODOT, "--headless", "--path", ROOT, "--script", "res://tools/traveler/lshu/bake/precompute_tiles.gd", "--"] + (["--tiles=" + tiles] if tiles else []))
    after = hashes()
    changed = [k for k in sorted(set(before) | set(after)) if before.get(k) != after.get(k)]
    rep["on_disk_rebake"] = {"exits": [rc3, rc4, rc5], "files": len(after), "changed": changed, "precompute_strict_errors": strict(log5)}
    rep["pass"] = (rc == 0 and rep["in_memory_twice"]["identical"] == rep["in_memory_twice"]["tiles"] > 0 and rc2 == 0
                   and rep["precompute_recomputed"]["identical"] == rep["precompute_recomputed"]["tiles"] > 0 and not changed and rc3 == 0 and rc5 == 0)
    return rep


def capture(out, tiles, lights, slot):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import lshu_batch  # noqa: E402
    import numpy as np
    from PIL import Image
    rows = []
    for t in tiles:
        for l in lights:
            a = lshu_batch.run(out, t, l, "freeze", slot, 240, "detA")
            b = lshu_batch.run(out, t, l, "freeze", slot, 240, "detB")
            pa, pb = os.path.join(out, a["stem"] + ".png"), os.path.join(out, b["stem"] + ".png")
            d = np.abs(np.asarray(Image.open(pa).convert("RGB")).astype(np.int16) - np.asarray(Image.open(pb).convert("RGB")).astype(np.int16))
            rows.append({"tile": t, "light": l, "mean": float(d.mean()), "max": int(d.max()), "errors": a["error_count"] + b["error_count"], "pass": float(d.mean()) <= 0.5})
            print(json.dumps(rows[-1]))
    return {"mode": "capture", "limit_mean": 0.5, "rows": rows, "pass": all(r["pass"] and r["errors"] == 0 for r in rows)}


def main(argv):
    mode = argv[0]
    tiles = ""; out = None; lights = ["day"]; slot = 1; jout = None
    for a in argv[1:]:
        if a.startswith("--tiles="): tiles = a.split("=", 1)[1]
        elif a.startswith("--out="): out = a.split("=", 1)[1]
        elif a.startswith("--lights="): lights = a.split("=", 1)[1].split(",")
        elif a.startswith("--slot="): slot = int(a.split("=", 1)[1])
        elif a.startswith("--json="): jout = a.split("=", 1)[1]
    rep = bake(tiles) if mode == "bake" else capture(out, tiles.split(","), lights, slot)
    if jout:
        json.dump(rep, open(jout, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(json.dumps({k: v for k, v in rep.items() if k != "rows"}, ensure_ascii=False)[:2000])
    return 0 if rep["pass"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
