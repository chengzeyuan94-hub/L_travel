#!/usr/bin/env python3
"""Encode uninterrupted or pause-demo footage and verify its recorded clock."""
import argparse
from fractions import Fraction
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_manifest(manifest, requested_mode=None):
    """Validate both new explicit modes and original v1 pause manifests."""
    mode = manifest.get("video_mode", "pause")
    require(mode in ("main", "pause"), "Unknown manifest video_mode")
    require(requested_mode is None or requested_mode == mode,
            "Requested --video-mode does not match the capture manifest")
    require(manifest["frame_count"] == 360 and manifest["fps"] == 30,
            "Expected 360 frames at 30 fps")
    require(manifest["duration_s"] == 12 and manifest["image_size"] == [1920, 1080]
            and manifest["viewport_size"] == [1920, 1080], "Expected 12 s at fixed 1920x1080")
    frames = manifest["frames"]
    require(len(frames) == 360, "Manifest frame records are incomplete")
    initial = manifest["initial_effective_parameters"]["motion"]
    active = manifest.get("active_items", initial["active_items"])
    require(active and len(set(active)) == len(active)
            and set(active) <= {"wind", "clouds", "leaves"}, "Invalid active_items")
    require(initial["active_items"] == active and manifest["final_motion"]["active_items"] == active,
            "Motion scope changed during capture")
    require(abs(initial["anim_t"]) < 1e-6 and initial["enabled"], "Capture must start running at anim_t=0")
    events = manifest["events"]
    if mode == "main":
        require(not events, "Main footage must contain zero pause/resume events")
    else:
        require(len(events) == 2, "Pause footage needs exactly one freeze and one resume")
        for event, index, action in zip(events, (180, 240),
                                       ("set_motion_enabled(false)", "set_motion_enabled(true)")):
            require(event["frame"] == index and event["action"] == action
                    and abs(event["video_time_s"] - index / 30) < 1e-6
                    and abs(event["anim_t"] - 6) < 1e-6, "Pause event does not match the 6..8 s segment")
    for index, frame in enumerate(frames):
        expected_time = index / 30
        if mode == "pause" and index >= 180:
            expected_time = 6.0 if index < 240 else index / 30 - 2
        enabled = mode == "main" or not 180 <= index < 240
        require(frame["frame"] == index and frame["file"] == f"f{index:04d}.png",
                f"Unexpected frame index or file at {index}")
        require(abs(frame["video_time_s"] - index / 30) < 1e-6
                and abs(frame["anim_t"] - expected_time) < 1e-6,
                f"Simulation clock mismatch at frame {index}")
        require(frame["motion_enabled"] is enabled, f"Master switch mismatch at frame {index}")
    require(abs(manifest["final_motion"]["anim_t"] - frames[-1]["anim_t"]) < 1e-6
            and manifest["final_motion"]["enabled"], "Final motion state does not match the footage")
    steps = [frames[i]["anim_t"] - frames[i - 1]["anim_t"] for i in range(1, 360)]
    return mode, {
        "pass_recorded_clock": True,
        "pause_events": sum(e["action"] == "set_motion_enabled(false)" for e in events),
        "resume_events": sum(e["action"] == "set_motion_enabled(true)" for e in events),
        "active_items": active,
        "simulation_step_s": 1 / 30,
        "observed_step_range_s": [min(steps), max(steps)],
        "main_constant_simulation_advance": all(abs(step - 1 / 30) < 1e-6 for step in steps)
        if mode == "main" else None,
        "paused_frame_count": sum(not frame["motion_enabled"] for frame in frames),
    }


def validate_decoded_frames(decoded_text):
    timebase_match = re.search(r"^#tb\s+0:\s*(\d+/\d+)", decoded_text, re.MULTILINE)
    require(timebase_match is not None, "Missing decoded video timebase")
    require(re.search(r"^#dimensions\s+0:\s*1920x1080\s*$", decoded_text, re.MULTILINE),
            "Decoded video is not 1920x1080")
    timebase = Fraction(timebase_match.group(1))
    rows = [s for s in decoded_text.splitlines() if s and not s.startswith("#")]
    require(len(rows) == 360, "Decoded frame count is not 360")
    for index, row in enumerate(rows):
        values = [v.strip() for v in row.split(",")]
        require(int(values[0]) == 0 and int(values[2]) * timebase == Fraction(index, 30)
                and int(values[3]) * timebase == Fraction(1, 30),
                f"Decoded video timing mismatch at frame {index}")
    return len(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--video-mode", choices=("main", "pause"),
                        help="Require matching capture mode; explicit mode also gives each video's proof files unique names")
    parser.add_argument("--prune-raw", action="store_true")
    args = parser.parse_args()
    raw, video = args.raw.resolve(), args.video.resolve()
    manifest_path = raw / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    mode, clock = validate_manifest(manifest, args.video_mode)
    # Existing commands retain their artifact paths; explicit modes can coexist
    # in one parent directory without either video's proofs overwriting the other.
    prefix = video.stem + "-" if args.video_mode is not None else ""
    decode_path = video.parent / (prefix + "decode-verification.txt")
    proof_path = video.parent / (prefix + "video-verification.json")
    keyframes = video.parent / (prefix + "keyframes")
    for target in (video, decode_path, proof_path, keyframes):
        require(not target.exists() and not target.is_symlink(), f"Refusing existing output: {target}")
    expected_names = {f"f{i:04d}.png" for i in range(360)}
    source_frames = sorted(raw.glob("f[0-9][0-9][0-9][0-9].png"))
    require({p.name for p in source_frames} == expected_names, "Raw sequence must contain exactly frames 0000..0359")
    hashes = {}
    for path in source_frames:
        with Image.open(path) as image:
            require(image.size == (1920, 1080), f"Wrong PNG dimensions: {path}")
            image.verify()
        hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    pairs = []
    if mode == "pause":
        previous = None
        for index in range(180, 240):
            with Image.open(raw / f"f{index:04d}.png") as image:
                current = np.asarray(image.convert("RGB"), dtype=np.int16)
            if previous is not None:
                difference = np.abs(current - previous)
                moved = difference.max(axis=2) >= 6
                pairs.append({"a": index - 1, "b": index, "pixels_ge_6": int(moved.sum()),
                              "moved_fraction": float(moved.mean()), "max_channel_difference_255": int(difference.max()),
                              "mean_abs_rgb_255": float(difference.mean())})
            previous = current
        require(all(pair["pixels_ge_6"] == 0 for pair in pairs), "Pause frames violate the unchanged freeze metric")
    encoder = shutil.which("ffmpeg")
    require(encoder is not None, "ffmpeg is required")
    video.parent.mkdir(parents=True, exist_ok=True)
    command = [encoder, "-hide_banner", "-loglevel", "error", "-n", "-framerate", "30", "-i",
               str(raw / "f%04d.png"), "-frames:v", "360", "-c:v", "libx264", "-preset", "medium",
               "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(video)]
    subprocess.run(command, check=True)
    decoded = subprocess.run([encoder, "-hide_banner", "-loglevel", "error", "-i", str(video),
                              "-map", "0:v:0", "-f", "framemd5", "-"],
                             capture_output=True, text=True, check=True)
    decoded_frames = validate_decoded_frames(decoded.stdout)
    with decode_path.open("x") as stream:
        stream.write(decoded.stdout)
    result = {
        "video_mode": mode,
        "motion_scope": manifest.get("motion_scope", ",".join(clock["active_items"])),
        **clock,
        "pass_required_freeze_metric": all(p["pixels_ge_6"] == 0 for p in pairs) if mode == "pause" else None,
        "thresholds": {"pixel": 6, "grid": [12, 7], "cell_fraction": 0.004, "B_live": 0, "B_moved_max": 0.0005},
        "frozen_frames": [180, 239] if mode == "pause" else [],
        "frozen_adjacent_pairs": pairs,
        "exact_bitwise_pixel_freeze": all(p["max_channel_difference_255"] == 0 for p in pairs) if mode == "pause" else None,
        "note": ("Separate pause demonstration: the master switch freezes at anim_t6 and resumes at8s video time. "
                 "Actual per-pair pixel differences are reported; this supplements the full60s B test.") if mode == "pause" else
                "Uninterrupted main footage: zero pause/resume events, master switch enabled for every frame, anim_t advances exactly1/30s per frame.",
        "video": str(video), "decoded_frames": decoded_frames, "image_size": [1920, 1080], "fps": 30, "duration_s": 12,
        "capture_manifest": str(manifest_path), "capture_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "encode_command": command, "video_sha256": hashlib.sha256(video.read_bytes()).hexdigest(), "raw_frame_sha256": hashes,
    }
    retained = [0, 90, 179, 180, 181, 182, 239, 240, 241, 299, 359]
    keyframes.mkdir()
    for index in retained:
        shutil.copy2(raw / f"f{index:04d}.png", keyframes / f"f{index:04d}.png")
    result["retained_original_keyframes"] = retained
    result["keyframes_directory"] = str(keyframes)
    result["decode_verification"] = str(decode_path)
    result["raw_pngs_pruned_after_verified_encoding"] = args.prune_raw
    with proof_path.open("x") as stream:
        stream.write(json.dumps(result, indent=2))
    if args.prune_raw:
        for name in hashes:
            (raw / name).unlink()
    print(json.dumps({k: result[k] for k in ("video_mode", "pass_recorded_clock", "pause_events", "resume_events",
                                           "main_constant_simulation_advance", "pass_required_freeze_metric",
                                           "exact_bitwise_pixel_freeze", "decoded_frames", "image_size", "fps",
                                           "duration_s", "video")}, indent=2))


if __name__ == "__main__":
    main()
