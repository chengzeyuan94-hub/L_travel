#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· summary of a batch directory (lshu_batch.py output): errors, frame cost, draw calls,
seated feet gap. Reads every <tile>_<light>[_live].json next to runs*.jsonl.

  python3 tools/traveler/lshu/qa/lshu_summary.py DIR [--json=OUT]
"""
import glob, json, os, statistics, sys


def main(argv):
    d = argv[0]
    jout = next((a.split("=", 1)[1] for a in argv[1:] if a.startswith("--json=")), None)
    runs = []
    for f in sorted(glob.glob(os.path.join(d, "runs*.jsonl"))):
        for ln in open(f, encoding="utf-8"):
            if ln.strip():
                runs.append(json.loads(ln))
    last = {}
    for r in runs:
        last[r["stem"]] = r   # a re-run replaces the earlier row of the same stem
    rows = list(last.values())
    frozen = [r for r in rows if r.get("mode") == "freeze"]
    live = [r for r in rows if r.get("mode") == "live"]
    p95 = [r["p95"] for r in rows if r.get("p95")]
    p50 = [r["p50"] for r in rows if r.get("p50")]
    seated = {}
    for r in rows:
        if r.get("pose") == "seated" and r.get("sole_gap_m") is not None:
            seated.setdefault(r["tile"], r["sole_gap_m"])
    rep = {
        "captures": len(rows), "frozen": len(frozen), "live": len(live), "png": sum(1 for r in rows if r.get("png")),
        "errors": sum(r.get("error_count", 0) for r in rows), "error_rows": [r["stem"] for r in rows if r.get("error_count")],
        "p95_ms": {"max": max(p95) if p95 else None, "median": statistics.median(p95) if p95 else None, "over_33_3": [r["stem"] for r in rows if (r.get("p95") or 0) > 33.3]},
        "p50_ms": {"median": statistics.median(p50) if p50 else None, "max": max(p50) if p50 else None},
        "draw_calls": {"max": max((r.get("dc") or 0) for r in rows) if rows else None},
        "seated_sole_gap_m": seated,
        "note": "p95 over 180 frames after 120 warm-up frames, 1920x1080 MSAA 4x SubViewport; strict error rule (ERROR / WARNING lines, exit code, capture_error)",
    }
    if jout:
        json.dump(rep, open(jout, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(json.dumps(rep, ensure_ascii=False, indent=1))
    return 1 if rep["errors"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
