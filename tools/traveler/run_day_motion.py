#!/usr/bin/env python3
"""Serial real-GPU captures and unchanged stable A/B metric for daytime layers."""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"


def judge(out, scope, length):
    gates = {}
    for mode in ("A", "B"):
        cmd = [sys.executable, str(ROOT / "tools/traveler/motion_gate.py"), str(out / mode), "--grid", "12x7", "--pix", "6", "--cell", "0.004", "--json", str(out / f"motion-gate-{mode}.json")]
        with (out / f"{mode}-metric.log").open("w") as log:
            subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, check=True)
        gates[mode] = json.loads((out / f"motion-gate-{mode}.json").read_text())
    if scope in ("all", "wind") and length == 60:
        subprocess.run([sys.executable, str(ROOT / "tools/traveler/motion_verdict.py"), str(out)], check=True)
        return json.loads((out / "motion-verdict-AB.json").read_text())
    rows = [0, 1, 2] if scope == "clouds" else list(range(7))
    ap, bp = gates["A"]["pairs"], gates["B"]["pairs"]
    expected = [sum(c[0] in rows for c in p["cells"]) for p in ap]
    a = np.asarray(Image.open(out / "A/f0000.png").convert("RGB"), dtype=float)
    b = np.asarray(Image.open(out / "B/f0000.png").convert("RGB"), dtype=float)
    mean = float(np.abs(a - b).mean())
    brightness = float(abs(a.mean() - b.mean()))
    checks = {"sample_pairs": len(ap) == length and len(bp) == length,
              "A_at_least_one_live_cell_in_expected_region": max(expected) >= 1,
              "B_every_pair_zero_live_cells": all(p["live_cells_non_adjacent"] == 0 for p in bp),
              "B_moved_fraction_max": max(p["moved_pixel_fraction"] for p in bp) <= 0.0005,
              "AB_frame0_mean_abs_diff": mean <= 3,
              "AB_frame0_mean_brightness_difference": brightness <= 0.5}
    result = {"pass": all(checks.values()), "scope": scope, "length_s": length, "checks": checks,
              "criterion_source": "motion_params.json gate.per_item_rule: each item alone, 10 s, >=1 live cell in its expected region; B and initial-frame thresholds unchanged",
              "expected_rows_zero_based": rows, "A_expected_region_live_cells_per_pair": expected,
              "A_live_range": [gates["A"]["min_live_cells"], gates["A"]["max_live_cells"]],
              "B_live_range": [gates["B"]["min_live_cells"], gates["B"]["max_live_cells"]],
              "B_nonzero_pairs": sum(p["live_cells_non_adjacent"] != 0 for p in bp),
              "A_moved_fraction_range": [min(p["moved_pixel_fraction"] for p in ap), max(p["moved_pixel_fraction"] for p in ap)],
              "B_moved_fraction_max": max(p["moved_pixel_fraction"] for p in bp),
              "AB_frame0_mean_abs_diff_255": mean, "AB_frame0_mean_brightness_difference_255": brightness,
              "thresholds": {"pixel": 6, "cell_fraction": 0.004, "A_region_live_min": 1, "B_live": 0,
                             "B_moved_max": 0.0005, "AB_initial_mean_abs_max_255": 3, "AB_brightness_max_255": 0.5}}
    (out / "motion-verdict-AB.json").write_text(json.dumps(result, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--scope", choices=("all", "wind", "clouds", "leaves", "fire", "sparks"), default="all")
    parser.add_argument("--length", type=int, default=60)
    parser.add_argument("--modes", nargs="+", choices=("A", "B"), default=["A", "B"])
    parser.add_argument("--period", choices=("day", "dusk"), default="day")
    parser.add_argument("--judge-only", action="store_true")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if not args.judge_only:
        for mode in args.modes:
            if (out / f"{mode}.run.json").exists():
                raise RuntimeError(f"Existing evidence: choose a new --out, do not overwrite {out}")
            script = "res://scripts/traveler/motion_gate_runner.gd" if args.scope == "wind" else "res://tools/traveler/day_motion_runner.gd"
            if args.scope == "wind" and args.length != 60:
                raise ValueError("The unchanged S0 wind runner records exactly60 seconds")
            cmd = [GODOT, "--path", str(ROOT), "--fixed-fps", "30", "--script", script, "--", "--view=changan", f"--{args.period}", "--far", f"--motion-mode={mode}", f"--motion-scope={args.scope}", f"--motion-length={args.length}", f"--motion-output={out / mode}"]
            start = time.monotonic()
            with (out / f"{mode}.log").open("w") as log:
                try:
                    code = subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=max(40, args.length * 3)).returncode
                except subprocess.TimeoutExpired:
                    code = 124
            lines = (out / f"{mode}.log").read_text().splitlines()
            execution = {"command": cmd, "exit_code": code, "error_lines": [s for s in lines if "ERROR" in s],
                         "warning_lines": [s for s in lines if "WARNING" in s], "wall_seconds": time.monotonic() - start}
            (out / f"{mode}.run.json").write_text(json.dumps(execution, indent=2))
            if code or execution["error_lines"] or execution["warning_lines"]:
                raise RuntimeError(execution)
            samples = json.loads((out / mode / "samples.json").read_text())
            assert samples["sample_count"] == args.length + 1
            assert samples["engine_max_fps"] == 0 and samples["vsync"] == 0
            for sample in samples["samples"]:
                assert sample["image_size"] == [1920, 1080] and sample["viewport_size"] == [1920, 1080]
                assert sample["look"]["preset"] == f"changan/{args.period}"
            print(args.scope, mode, "captured", samples["sample_count"], flush=True)
    if all((out / mode / "samples.json").exists() for mode in ("A", "B")):
        result = judge(out, args.scope, args.length)
        print(json.dumps(result, indent=2), flush=True)
        if not result["pass"]:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
