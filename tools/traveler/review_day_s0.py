#!/usr/bin/env python3
"""Audit current-scene S0 inputs and native PNG evidence without changing the scene."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    report = args.report.resolve()
    expected_camera = json.loads((ROOT / "data/traveler/motion_params.json").read_text())["_measured"]["traveler_camera"]
    result = {"camera": expected_camera, "modes": {}, "before_performance": {}}
    for mode in ("A", "B"):
        folder = report / "S0" / mode
        summary = json.loads((folder / "samples.json").read_text())
        execution = json.loads((report / "S0" / f"{mode}.run.json").read_text())
        records = summary["samples"]
        assert len(records) == 61
        assert summary["vsync"] == 0 and summary["engine_max_fps"] == 0
        assert execution["exit_code"] == 0 and not execution["error_lines"] and not execution["warning_lines"]
        assert "--view=changan" in execution["command"] and "--far" in execution["command"]
        previous = None
        raw_pairs = []
        for index, record in enumerate(records):
            assert abs(record["time_s"] - index) < 1e-6
            assert record["image_size"] == [1920, 1080] and record["viewport_size"] == [1920, 1080]
            assert record["capture_error"] == 0 and record["frozen_camera"] == expected_camera
            assert record["look"]["preset"] == "changan/day"
            assert record["look"]["effective_params"]["dof"] == 19
            assert record["look"]["effective_params"]["dofn"] == 5.5
            current = np.asarray(Image.open(folder / f"f{index:04d}.png").convert("RGB"), dtype=np.int16)
            assert current.shape == (1080, 1920, 3)
            if previous is not None:
                delta = np.abs(current - previous)
                raw_pairs.append({"pair": index - 1, "pixels_ge_6": int((delta.max(axis=2) >= 6).sum()),
                                  "fraction_ge_6": float((delta.max(axis=2) >= 6).mean()),
                                  "mean_abs_rgb_255": float(delta.mean()), "max_abs_rgb_255": int(delta.max())})
            previous = current
        result["modes"][mode] = {"all_metadata_valid": True, "frames": 61, "pairs": raw_pairs,
                                 "exactly_identical_adjacent_frames": sum(p["max_abs_rgb_255"] == 0 for p in raw_pairs),
                                 "command": execution["command"]}
    for period in ("day", "dusk"):
        evidence = json.loads((report / "before" / f"{period}.json").read_text())
        assert evidence["image_size"] == [1920, 1080] and evidence["viewport_size"] == [1920, 1080]
        assert evidence["look"]["preset"] == f"changan/{period}"
        assert evidence["frame_ms"]["vsync_disabled"] and evidence["frame_ms"]["engine_max_fps"] == 0
        result["before_performance"][period] = {"draw_calls_global": evidence["draw_calls"],
                                                "draw_calls_subviewport": evidence["viewport_draw_calls"],
                                                "p50_ms": evidence["frame_ms"]["p50"], "p95_ms": evidence["frame_ms"]["p95"]}
    hashes = json.loads((report / "input-sha256.json").read_text())
    changed = [p for p, digest in hashes.items() if not (ROOT / p).exists() or hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != digest]
    result["input_hashes"] = {"count": len(hashes), "changed": changed}
    ignored = subprocess.run(["git", "check-ignore", str(report / "S0/A/f0000.png"), str(report / "README.md")], cwd=ROOT, capture_output=True, text=True)
    result["evidence_gitignore"] = {"ignored_paths": ignored.stdout.splitlines(), "staged_by_this_task": False}
    result["ab_verdict"] = json.loads((report / "S0/motion-verdict-AB.json").read_text())["pass"]
    (report / "S0/verification.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({"ab_verdict": result["ab_verdict"], "before_performance": result["before_performance"], "input_hashes": result["input_hashes"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
