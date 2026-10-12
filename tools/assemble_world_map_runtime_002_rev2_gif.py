#!/usr/bin/env python3
"""Assemble the REV3 evidence GIF from explicit manifest frame paths only.

GIF frame durations are stored in centiseconds.  The tool writes the actual
quantized duration/fps and a content hash back into capture_manifest.json so
reports cannot confuse raw 12 fps sampling with the encoded GIF timing.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

try:
    from PIL import Image, ImageSequence
except ImportError:
    print("FAIL: Pillow required", file=sys.stderr)
    sys.exit(2)


def fail(message: str) -> int:
    print(f"FAIL: {message}", file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: assemble_..._gif.py <capture_manifest.json> <out.gif>", file=sys.stderr)
        return 2

    manifest_path = Path(sys.argv[1]).resolve()
    out_gif = Path(sys.argv[2]).resolve()
    if not manifest_path.is_file():
        return fail(f"missing manifest {manifest_path}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return fail(f"invalid manifest: {exc}")

    request = manifest.get("gif_request", {})
    requested_fps = float(request.get("requested_fps", 12.0))
    if requested_fps <= 0:
        return fail(f"invalid requested fps {requested_fps}")
    duration_cs = max(1, round(100.0 / requested_fps))
    duration_ms = duration_cs * 10

    listed = manifest.get("frame_paths", [])
    if not isinstance(listed, list) or len(listed) < 10:
        return fail(f"too few explicit frame_paths ({len(listed) if isinstance(listed, list) else 'invalid'})")
    paths = [Path(str(path)).resolve() for path in listed]
    if len(set(paths)) != len(paths):
        return fail("duplicate frame path in explicit manifest list")

    frames: list[Image.Image] = []
    expected_size: tuple[int, int] | None = None
    for path in paths:
        if not path.is_file():
            return fail(f"missing listed frame {path}")
        try:
            with Image.open(path) as source:
                frame = source.convert("RGBA")
        except OSError as exc:
            return fail(f"cannot decode listed frame {path}: {exc}")
        if expected_size is None:
            expected_size = frame.size
        elif frame.size != expected_size:
            return fail(f"frame size mismatch {path}: {frame.size} != {expected_size}")
        frames.append(frame)

    quantized = [
        frame.convert("RGB").convert("P", palette=Image.Palette.ADAPTIVE, colors=128)
        for frame in frames
    ]
    try:
        quantized[0].save(
            out_gif,
            save_all=True,
            append_images=quantized[1:],
            duration=[duration_ms] * len(quantized),
            loop=0,
            optimize=False,
            disposal=2,
        )
    except OSError as exc:
        return fail(f"GIF save failed: {exc}")
    if not out_gif.is_file() or out_gif.stat().st_size <= 0:
        return fail(f"GIF output missing or empty: {out_gif}")

    # Re-open the encoded artifact. Pillow reports the quantized millisecond
    # duration stored in each GIF frame, which is the evidence we publish.
    encoded_count = 0
    encoded_duration_ms = 0
    try:
        with Image.open(out_gif) as encoded:
            for frame in ImageSequence.Iterator(encoded):
                encoded_count += 1
                encoded_duration_ms += int(frame.info.get("duration", 0))
    except OSError as exc:
        return fail(f"cannot verify encoded GIF: {exc}")
    # GIF encoders are allowed to coalesce consecutive pixel-identical frames
    # into one frame with the summed delay, even with optimize=False.  That is
    # lossless temporal encoding, not stale-file reuse.  Require exact total
    # duration and quantized delays instead of falsely demanding one GIF image
    # descriptor per source sample.
    expected_duration_ms = len(frames) * duration_ms
    if encoded_count <= 0 or encoded_count > len(frames):
        return fail(f"invalid encoded frame count {encoded_count} for {len(frames)} sources")
    if encoded_duration_ms != expected_duration_ms:
        return fail(
            f"encoded duration {encoded_duration_ms}ms != requested {expected_duration_ms}ms"
        )

    digest = hashlib.sha256(out_gif.read_bytes()).hexdigest()
    encoded_duration_seconds = encoded_duration_ms / 1000.0
    effective_fps = encoded_count / encoded_duration_seconds
    result = {
        "success": True,
        "output_path": str(out_gif),
        "output_bytes": out_gif.stat().st_size,
        "sha256": digest,
        "frame_count": encoded_count,
        "source_frame_count": len(frames),
        "coalesced_identical_frames": len(frames) - encoded_count,
        "requested_fps": requested_fps,
        "requested_frame_interval_ms": 1000.0 / requested_fps,
        "encoded_frame_duration_centiseconds": duration_cs,
        "encoded_frame_duration_ms": duration_ms,
        "encoded_duration_seconds": encoded_duration_seconds,
        "effective_fps": effective_fps,
        "source_manifest_only": True,
    }
    manifest["gif_result"] = result
    try:
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except OSError as exc:
        return fail(f"cannot write verified GIF result to manifest: {exc}")

    print(
        "OK "
        f"gif={out_gif} frames={encoded_count} requested_fps={requested_fps:.6f} "
        f"encoded_frame_cs={duration_cs} effective_fps={effective_fps:.6f} "
        f"encoded_duration_seconds={encoded_duration_seconds:.6f} "
        f"run_id={manifest.get('capture_run_id')} sha256={digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
