#!/usr/bin/env python3
"""Day/dusk fixed-camera motion delivery stills and uncapped frame timing."""
import argparse
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--wind-only", action="store_true")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    for period in ("day", "dusk"):
        if (out / f"{period}.png").exists():
            raise RuntimeError("Choose a new output directory; preserve existing evidence")
        cmd = ["/Applications/Godot.app/Contents/MacOS/Godot", "--path", str(ROOT), "--script", "res://tools/traveler/capture_traveler.gd", "--", "--view=changan", f"--{period}", "--far", "--capture-preview", f"--capture={out / (period + '.png')}"]
        if args.wind_only:
            cmd.append("--motion-only=wind")
        started = time.monotonic()
        with (out / f"{period}.log").open("w") as log:
            try:
                code = subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=90).returncode
            except subprocess.TimeoutExpired:
                code = 124
        lines = (out / f"{period}.log").read_text().splitlines()
        execution = {"command": cmd, "exit_code": code, "error_lines": [s for s in lines if "ERROR" in s], "warning_lines": [s for s in lines if "WARNING" in s], "wall_seconds": time.monotonic() - started}
        (out / f"{period}.run.json").write_text(json.dumps(execution, indent=2))
        if code or execution["error_lines"] or execution["warning_lines"]:
            raise RuntimeError(execution)
        data = json.loads((out / f"{period}.json").read_text())
        assert data["image_size"] == [1920, 1080] and data["viewport_size"] == [1920, 1080]
        assert data["look"]["preset"] == f"changan/{period}"
        assert data["frame_ms"]["vsync_disabled"] and data["frame_ms"]["engine_max_fps"] == 0
        print(period, data["draw_calls"], data["viewport_draw_calls"], data["frame_ms"]["p50"], data["frame_ms"]["p95"], flush=True)


if __name__ == "__main__":
    main()
