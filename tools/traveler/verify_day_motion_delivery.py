#!/usr/bin/env python3
"""Cross-check accepted motion evidence, runtime parameters and protected inputs."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    out = args.report.resolve()
    checks, verdicts, logs, metadata = {}, {}, [], {}
    camera = read(ROOT / "data/traveler/motion_params.json")["_measured"]["traveler_camera"]
    for stage, count in (("S0", 61), ("S4", 11), ("S6", 11), ("S9", 11), ("combined", 61)):
        verdict = read(out / stage / "motion-verdict-AB.json")
        checks[f"{stage}_AB"] = verdict["pass"]
        verdicts[stage] = verdict
        for mode in ("A", "B"):
            log = read(out / stage / f"{mode}.run.json")
            logs.append({"path": str(out / stage / f"{mode}.run.json"), **log})
            samples = read(out / stage / mode / "samples.json")["samples"]
            assert len(samples) == count
            for index, sample in enumerate(samples):
                assert sample["image_size"] == [1920, 1080] and sample["viewport_size"] == [1920, 1080]
                assert sample["capture_error"] == 0 and sample["look"]["preset"] == "changan/day"
                assert sample["frozen_camera"] == camera and sample["camera_fov"] == 36
                assert Image.open(out / stage / mode / f"f{index:04d}.png").size == (1920, 1080)
            metadata[f"{stage}/{mode}"] = {"images_checked": len(samples), "resolution": [1920, 1080], "preset": "changan/day", "frozen_camera": camera}
    checks["sample_metadata"] = True
    performance = {}
    for period in ("day", "dusk"):
        performance[period] = {}
        for stage in ("before", "after-final"):
            d = read(out / stage / f"{period}.json")
            logs.append({"path": str(out / stage / f"{period}.run.json"), **read(out / stage / f"{period}.run.json")})
            assert d["image_size"] == [1920, 1080] and d["viewport_size"] == [1920, 1080]
            assert d["look"]["preset"] == f"changan/{period}" and d["frozen_camera"] == camera
            assert d["frame_ms"]["vsync_disabled"] and d["frame_ms"]["engine_max_fps"] == 0
            performance[period][stage] = {"draw_calls_global": d["draw_calls"], "draw_calls_subviewport": d["viewport_draw_calls"], "frame_ms_p50": d["frame_ms"]["p50"], "frame_ms_p95": d["frame_ms"]["p95"], "samples": d["frame_ms"]["sample_count"], "meanV_report_only": d["look"]["measured"]["meanV"], "meanS_report_only": d["look"]["measured"]["meanS"]}
        checks[f"{period}_frame_budget"] = performance[period]["after-final"]["frame_ms_p95"] <= 33.3
    grass = read(out / "S0/grass/grass-audit.json")
    checks["grass_wiring"] = grass["material_registered"] and grass["use_custom_data"] and grass["wind_amp"] == 0.1
    leaf = read(out / "S6/leaf-pixel-measurement.json")
    checks["leaf_height"] = leaf["height_gate"]["pass"]
    layers = read(out / "combined/A/f0003.json")["motion"]
    checks["nine_original_clouds"] = layers["clouds"]["cloud_count"] == 9 and not layers["clouds"]["errors"]
    bird = layers["birds"]
    checks["birds_in_front_of_mountains"] = bird["mountain_occlusion"]["all_birds_in_front_of_every_mountain_vertex"]
    checks["birds_single_multimesh_long_cycle"] = bird["multimesh_instance_nodes"] == 1 and bird["cycle_s"] == 96
    for relative in ("S0/grass.run.json", "S6/masks.run.json"):
        logs.append({"path": str(out / relative), **read(out / relative)})
    video = read(out / "video/video-verification.json")
    checks["midflight_master_freeze"] = video["pass_required_freeze_metric"]
    checks["review_video"] = video["decoded_frames"] == 360 and video["image_size"] == [1920, 1080] and video["fps"] == 30
    logs.append({"path": str(out / "video/capture.run.json"), **read(out / "video/capture.run.json")})
    checks["accepted_runs_no_error_or_fallback"] = all(x["exit_code"] == 0 and not x["error_lines"] and not x["warning_lines"] for x in logs)
    start = read(out / "input-sha256.json")
    changed = [p for p, digest in start.items() if not (ROOT / p).exists() or hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != digest]
    permitted = {"scripts/traveler/atlas_viewer.gd", "scripts/traveler/motion_director.gd", "scripts/traveler/motion_gate_runner.gd"}
    checks["protected_inputs_unchanged"] = set(changed) == permitted
    branch = subprocess.check_output(["git", "branch", "--show-current"], cwd=ROOT, text=True).strip()
    checks["original_branch"] = branch == "feat/night1-ui-motion"
    ignored = subprocess.run(["git", "check-ignore", str(out / "README.md"), str(out / "after-final/day.png"), str(out / "combined/A/f0000.png")], cwd=ROOT, capture_output=True, text=True)
    checks["evidence_not_ignored"] = ignored.returncode == 1 and not ignored.stdout
    result = {"pass": all(checks.values()), "checks": checks, "performance": performance, "AB_verdicts": verdicts,
              "metadata": metadata, "accepted_executions": logs, "input_hashes": {"count": len(start), "unchanged": len(start)-len(changed), "changed": changed},
              "branch": branch, "leaf_size": leaf["height_gate"], "leaf_count": leaf["visible_component_count"], "bird_layer": bird["mountain_occlusion"],
              "known_failed_diagnostics_excluded": {"smoke/A.log": "Initial typed-array runner error, corrected before accepted captures", "after/day.log": "Teardown crash after saving image; fixed director lifecycle before accepted after-final captures"},
              "scope": "Day motion only; existing frozen scenery/camera/lighting/water unchanged. No commit, push, branch change or staging performed."}
    (out / "delivery-verification.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({"pass": result["pass"], "checks": checks, "performance": performance}, ensure_ascii=False, indent=2))
    if not result["pass"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
