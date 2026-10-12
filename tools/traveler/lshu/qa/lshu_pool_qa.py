#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· pool QA: one tile per place at a seeded light + N random tiles in all 4 lights.

Selection (random.Random(--seed), everything else read from pool.json and the tile JSONs, no ids in this file):
  per place (places in sorted order): rng.choice(the place's tiles), rng.choice(4 lights)
  then rng.sample(the tiles not picked above, N), each in morning / day / sunset / night
Every capture goes through lshu_batch.run() (strict rule: any ERROR / WARNING line, nonzero exit, missing PNG/JSON,
TIMEOUT or capture_error counts), frozen motion, 1920x1080 MSAA 4x, p95 over 180 frames after 120 warm-up frames.

  ~/.local/bin/uv run -q --with pillow --with numpy python tools/traveler/lshu/qa/lshu_pool_qa.py \
      --out=DIR --slot=20 [--seed=20260924] [--random=10] [--sheet=OUT.png] [--only-sheet | --retry-failed]
  --retry-failed  run again only the captures whose latest row in runs.jsonl failed or is missing (every attempt
                  stays in runs.jsonl; the summary counts the latest row of each capture and lists the retried ones)
Writes DIR/<tile>_<light>.png/.json/.log, DIR/runs.jsonl, DIR/selection.json, DIR/pool_qa_summary.json and the
contact sheet (top: one frame per place; bottom: the random tiles, 4 lights each).
"""
import json, os, random, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lshu_batch  # noqa: E402

ROOT = lshu_batch.ROOT
LIGHTS = lshu_batch.LIGHTS
TILES = os.path.join(ROOT, "data", "traveler", "lshu", "tiles")
P95_LIMIT = 33.3


def tile_meta(tid):
    d = json.load(open(os.path.join(TILES, tid + ".json"), encoding="utf-8"))
    return {"place": d["place"]["id"], "place_name": d["place"]["name"], "layout": d["layout"]["id"], "kit": d["kit"]["mode"]}


def select(seed, n_random):
    ids = sorted(t["id"] for t in lshu_batch.pool()["tiles"])
    meta = {t: tile_meta(t) for t in ids}
    by_place = {}
    for t in ids:
        by_place.setdefault(meta[t]["place"], []).append(t)
    rng = random.Random(seed)
    per_place = []
    for place in sorted(by_place):
        per_place.append({"tile": rng.choice(by_place[place]), "light": rng.choice(LIGHTS), "place": place})
    picked = {r["tile"] for r in per_place}
    rest = [t for t in ids if t not in picked]
    rand = sorted(rng.sample(rest, n_random))
    return {"seed": seed, "pool_tiles": len(ids), "places": len(by_place), "per_place": per_place, "random": rand}, meta


def sheet(out_png, d, sel, meta, rows_by_stem, w=384):
    from PIL import Image, ImageDraw, ImageFont
    font = big = None
    for f in ("/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc",
              "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"):   # first CJK font present
        if os.path.exists(f):
            font, big = ImageFont.truetype(f, 17), ImageFont.truetype(f, 30)
            break
    if font is None:
        font = big = ImageFont.load_default()
    h = w * 9 // 16
    cols = 8
    head = 48
    top_rows = (len(sel["per_place"]) + cols - 1) // cols
    half = (len(sel["random"]) + 1) // 2
    W = w * cols
    H = head + top_rows * h + head + half * h
    im = Image.new("RGB", (W, H), (18, 18, 20))
    dr = ImageDraw.Draw(im)

    def cell(stem, x, y, text):
        p = os.path.join(d, stem + ".png")
        if os.path.exists(p):
            im.paste(Image.open(p).convert("RGB").resize((w, h), Image.LANCZOS), (x, y))
        else:
            dr.rectangle((x, y, x + w - 1, y + h - 1), outline=(200, 40, 40), width=3)
        r = rows_by_stem.get(stem, {})
        bad = r.get("error_count", 1) != 0
        dr.rectangle((x, y, x + w, y + 24), fill=(120, 20, 20) if bad else (0, 0, 0))
        dr.text((x + 5, y + 2), "%s  p95 %.1f" % (text, r.get("p95") or 0), fill=(255, 255, 255), font=font)

    per = sel["per_place"]
    dr.text((10, 8), "40 个地点各一块（种子光照）· 严格判定错误 %d · p95 最大 %.1f ms" % (
        sum(rows_by_stem.get("%s_%s" % (r["tile"], r["light"]), {}).get("error_count", 1) for r in per),
        max([rows_by_stem.get("%s_%s" % (r["tile"], r["light"]), {}).get("p95") or 0 for r in per] or [0])), fill=(235, 235, 235), font=big)
    for i, r in enumerate(per):
        m = meta[r["tile"]]
        cell("%s_%s" % (r["tile"], r["light"]), (i % cols) * w, head + (i // cols) * h, "%s %s %s" % (r["tile"], m["place_name"][:9], r["light"]))
    y0 = head + top_rows * h
    rstems = ["%s_%s" % (t, l) for t in sel["random"] for l in LIGHTS]
    dr.text((10, y0 + 8), "随机 %d 块 × 晨 昼 昏 夜 · 严格判定错误 %d · p95 最大 %.1f ms" % (
        len(sel["random"]), sum(rows_by_stem.get(s, {}).get("error_count", 1) for s in rstems),
        max([rows_by_stem.get(s, {}).get("p95") or 0 for s in rstems] or [0])), fill=(235, 235, 235), font=big)
    for i, t in enumerate(sel["random"]):
        bx = 0 if i < half else 4 * w
        by = y0 + head + (i % half) * h
        for c, l in enumerate(LIGHTS):
            cell("%s_%s" % (t, l), bx + c * w, by, "%s %s %s" % (t, meta[t]["place_name"][:7], l))
    im.save(out_png)
    return out_png


def main(argv):
    out = None; slot = 20; seed = 20260924; n_random = 10; sheet_png = None; only_sheet = False; timeout = 300; retry = False
    for a in argv:
        if a.startswith("--out="): out = os.path.abspath(a.split("=", 1)[1])
        elif a.startswith("--slot="): slot = int(a.split("=", 1)[1])
        elif a.startswith("--seed="): seed = int(a.split("=", 1)[1])
        elif a.startswith("--random="): n_random = int(a.split("=", 1)[1])
        elif a.startswith("--sheet="): sheet_png = os.path.abspath(a.split("=", 1)[1])
        elif a.startswith("--timeout="): timeout = int(a.split("=", 1)[1])
        elif a == "--only-sheet": only_sheet = True
        elif a == "--retry-failed": retry = True
    if not out:
        raise SystemExit(__doc__)
    os.makedirs(out, exist_ok=True)
    sel, meta = select(seed, n_random)
    json.dump(sel, open(os.path.join(out, "selection.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    jobs = [(r["tile"], r["light"]) for r in sel["per_place"]] + [(t, l) for t in sel["random"] for l in LIGHTS]
    runs = os.path.join(out, "runs.jsonl")

    def latest():
        rows = {}
        attempts = {}
        if os.path.exists(runs):
            for ln in open(runs, encoding="utf-8"):
                if ln.strip():
                    r = json.loads(ln)
                    rows[r["stem"]] = r   # a re-run replaces the earlier row
                    attempts.setdefault(r["stem"], []).append(r)
        return rows, attempts

    if not only_sheet:
        todo = jobs
        if retry:
            prev, _ = latest()
            todo = [(t, l) for t, l in jobs if prev.get("%s_%s" % (t, l), {}).get("error_count", 1) != 0]
            print("RETRY", len(todo), ["%s_%s" % j for j in todo], flush=True)
            for t, l in todo:   # keep the failed attempt's log next to the retry
                log = os.path.join(out, "%s_%s.log" % (t, l))
                n = 1
                while os.path.exists(log) and os.path.exists(log[:-4] + ".fail%d.log" % n):
                    n += 1
                if os.path.exists(log):
                    os.replace(log, log[:-4] + ".fail%d.log" % n)
        for i, (t, l) in enumerate(todo):
            s = lshu_batch.run(out, t, l, "freeze", slot, timeout, "")
            open(runs, "a", encoding="utf-8").write(json.dumps(s, ensure_ascii=False) + "\n")
            print("%3d/%d %-16s %5ss p50=%s p95=%s max=%s dc=%s pose=%s err=%d" % (
                i + 1, len(todo), s["stem"], s["sec"], s.get("p50"), s.get("p95"), s.get("max"), s.get("dc"), s.get("pose"), s["error_count"]), flush=True)
            for e in s["errors"][:6]:
                print("     ! " + e[:240], flush=True)
    rows_by_stem, attempts = latest()
    want = ["%s_%s" % j for j in jobs]
    rows = [rows_by_stem[s] for s in want if s in rows_by_stem]
    p95 = [r["p95"] for r in rows if r.get("p95")]
    p50 = [r["p50"] for r in rows if r.get("p50")]
    rep = {
        "schema": "lshu.pool-qa.v1", "seed": seed, "slot": slot, "pool_tiles": sel["pool_tiles"], "places": sel["places"],
        "captures_planned": len(jobs), "captures_done": len(rows), "png": sum(1 for r in rows if r.get("png")),
        "errors": sum(r.get("error_count", 0) for r in rows) + (len(jobs) - len(rows)),
        "error_rows": [r["stem"] for r in rows if r.get("error_count")] + [s for s in want if s not in rows_by_stem],
        "p95_ms": {"max": max(p95) if p95 else None, "median": statistics.median(p95) if p95 else None,
                   "over_limit": [r["stem"] for r in rows if (r.get("p95") or 0) > P95_LIMIT], "limit": P95_LIMIT},
        "p50_ms": {"median": statistics.median(p50) if p50 else None, "max": max(p50) if p50 else None},
        "draw_calls": {"max": max((r.get("dc") or 0) for r in rows) if rows else None,
                       "median": statistics.median([r.get("dc") or 0 for r in rows]) if rows else None},
        "poses": {p: sum(1 for r in rows if r.get("pose") == p) for p in sorted({r.get("pose") for r in rows if r.get("pose")})},
        "places_rendered": len({meta[r["tile"]]["place"] for r in rows}),
        "retried": {s: {"attempts": len(attempts[s]), "errors_per_attempt": [a.get("error_count", 0) for a in attempts[s]],
                        "failed_attempt_errors": [a.get("errors", []) for a in attempts[s] if a.get("error_count", 0)],
                        "failed_attempt_logs": sorted(f for f in os.listdir(out) if f.startswith(s + ".fail"))}
                    for s in want if len(attempts.get(s, [])) > 1},
        "note": "frozen motion, 1920x1080 MSAA 4x SubViewport, p95 over 180 frames after 120 warm-up frames; strict error rule",
    }
    rep["pass"] = rep["errors"] == 0 and not rep["p95_ms"]["over_limit"] and rep["captures_done"] == len(jobs)
    json.dump(rep, open(os.path.join(out, "pool_qa_summary.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    if sheet_png:
        print("SHEET", sheet(sheet_png, out, sel, meta, rows_by_stem))
    print("POOL_QA", json.dumps({k: rep[k] for k in ("captures_done", "png", "errors", "p95_ms", "draw_calls", "places_rendered", "pass")}, ensure_ascii=False))
    return 0 if rep["pass"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
