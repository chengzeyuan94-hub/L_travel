#!/usr/bin/env python3
"""Build transparent, cropped 6 FPS map FX atlases from source videos.

The preferred decoder is ffmpeg/ffprobe. On macOS this tool falls back to the
project's AVFoundation Swift extractor so the asset build remains reproducible
on machines without a working ffmpeg installation.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


FPS = 8.0
MAX_FRAME_WIDTH = 480
PAD = 20

SPECS = {
    # Product-confirmed formal cloud-shadow source. The earlier eae16433 marker
    # referred to a file that was never delivered; 7324 is the approved take.
    "cloud_shadow": {"needle": "7324", "background": "white", "loop": "ping_pong", "noise_floor": 8.0},
    "fine_snow": {"needle": "3695", "background": "black", "loop": "crossfade", "noise_floor": 28.0},
    "valley_mist": {"needle": "4399", "background": "black", "loop": "crossfade", "noise_floor": 24.0},
    "desert_dust": {"needle": "5268", "background": "black", "loop": "crossfade", "noise_floor": 4.0},
    "sea_glints": {"needle": "6007", "background": "black", "loop": "ping_pong", "noise_floor": 4.0},
}


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=check, text=True, capture_output=True)


def find_executable(name: str) -> str | None:
    explicit = os.environ.get(name.upper())
    if explicit and Path(explicit).is_file():
        return explicit
    return shutil.which(name)


def probe_duration(video: Path, ffprobe: str | None) -> float:
    if ffprobe:
        result = run([
            ffprobe, "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", str(video),
        ])
        return float(result.stdout.strip())
    if sys.platform == "darwin":
        result = run(["mdls", "-raw", "-name", "kMDItemDurationSeconds", str(video)])
        value = result.stdout.strip()
        if value not in {"", "(null)"}:
            return float(value)
        # Newly copied files may not be indexed by Spotlight yet.
        audio_info = run(["afinfo", str(video)])
        for line in audio_info.stdout.splitlines():
            if "estimated duration:" in line:
                return float(line.split("estimated duration:", 1)[1].split("sec", 1)[0].strip())
    raise RuntimeError("ffprobe is unavailable and no platform metadata fallback exists")


def ffmpeg_is_usable(ffmpeg: str | None) -> bool:
    if not ffmpeg:
        return False
    try:
        result = run([ffmpeg, "-version"], check=False)
        return result.returncode == 0
    except OSError:
        return False


def extract_frames(video: Path, output: Path, count: int, duration: float,
                   ffmpeg: str | None, swift_extractor: Path) -> str:
    output.mkdir(parents=True, exist_ok=True)
    usable_end = min(0.995, max(0.0, (count - 1) / (FPS * duration)))
    if ffmpeg_is_usable(ffmpeg):
        # Complete decode check first. A corrupt tail is never silently included.
        checked = run([ffmpeg, "-v", "error", "-i", str(video), "-f", "null", "-"], check=False)
        if checked.returncode != 0:
            raise RuntimeError(f"decode check failed for {video.name}: {checked.stderr[-500:]}")
        pattern = str(output / "frame_%04d.png")
        run([
            ffmpeg, "-v", "error", "-i", str(video), "-vf", f"fps={FPS:g}",
            "-frames:v", str(count), pattern,
        ])
        return "ffmpeg"
    if sys.platform != "darwin" or not swift_extractor.is_file():
        raise RuntimeError("No usable ffmpeg and AVFoundation fallback is unavailable")
    run([
        "swift", str(swift_extractor), str(video), str(output), str(count),
        "0.0", f"{usable_end:.8f}",
    ])
    return "avfoundation"


def edge_background(rgb: np.ndarray) -> np.ndarray:
    border = max(4, min(rgb.shape[0], rgb.shape[1]) // 100)
    samples = np.concatenate([
        rgb[:border].reshape(-1, 3), rgb[-border:].reshape(-1, 3),
        rgb[:, :border].reshape(-1, 3), rgb[:, -border:].reshape(-1, 3),
    ])
    return np.median(samples, axis=0)


def alpha_metrics(frames: list[np.ndarray], background: str) -> tuple[float, float]:
    edge_values: list[np.ndarray] = []
    all_values: list[np.ndarray] = []
    for rgb in frames:
        bg = edge_background(rgb)
        if background == "black":
            strength = np.max(np.maximum(rgb - bg, 0.0), axis=2)
        else:
            strength = np.maximum(np.mean(bg) - np.mean(rgb, axis=2), 0.0)
        border = max(4, min(rgb.shape[0], rgb.shape[1]) // 100)
        edge_values.extend([
            strength[:border].ravel(), strength[-border:].ravel(),
            strength[:, :border].ravel(), strength[:, -border:].ravel(),
        ])
        all_values.append(strength.ravel())
    edge = np.concatenate(edge_values)
    values = np.concatenate(all_values)
    # Edge samples can contain legitimate snow/glints. A high percentile would
    # mistake those sparse particles for the codec background and erase them.
    edge_median = float(np.median(edge))
    edge_mad = float(np.median(np.abs(edge - edge_median)))
    noise = max(4.0, edge_median + edge_mad * 6.0 + 1.5)
    peak = max(noise + 8.0, float(np.percentile(values, 99.85)))
    return noise, peak


def make_rgba(rgb: np.ndarray, background: str, noise: float, peak: float) -> np.ndarray:
    bg = edge_background(rgb)
    if background == "black":
        residual = np.maximum(rgb - bg, 0.0)
        strength = np.max(residual, axis=2)
        alpha = np.clip((strength - noise) / (peak - noise), 0.0, 1.0) ** 0.78
        # Correct black-premultiplied fringes while avoiding amplification of noise.
        foreground = np.clip(residual / np.maximum(alpha[..., None], 0.10), 0.0, 255.0)
    else:
        strength = np.maximum(np.mean(bg) - np.mean(rgb, axis=2), 0.0)
        alpha = np.clip((strength - noise) / (peak - noise), 0.0, 1.0) ** 0.90
        cool_gray = np.array([92.0, 104.0, 112.0], dtype=np.float32)
        foreground = np.broadcast_to(cool_gray, rgb.shape).copy()
    alpha[strength <= noise] = 0.0
    result = np.empty((*rgb.shape[:2], 4), dtype=np.uint8)
    result[..., :3] = foreground.astype(np.uint8)
    result[..., 3] = np.round(alpha * 255.0).astype(np.uint8)
    return result


def union_crop(frames: list[np.ndarray]) -> tuple[int, int, int, int]:
    xs: list[np.ndarray] = []
    ys: list[np.ndarray] = []
    for frame in frames:
        y, x = np.nonzero(frame[..., 3] > 2)
        if x.size:
            xs.append(x)
            ys.append(y)
    if not xs:
        raise RuntimeError("all generated frames are transparent")
    all_x, all_y = np.concatenate(xs), np.concatenate(ys)
    height, width = frames[0].shape[:2]
    left = max(0, int(all_x.min()) - PAD)
    top = max(0, int(all_y.min()) - PAD)
    right = min(width, int(all_x.max()) + PAD + 1)
    bottom = min(height, int(all_y.max()) + PAD + 1)
    return left, top, right, bottom


def resize_frames(frames: list[Image.Image]) -> tuple[list[Image.Image], tuple[int, int]]:
    width, height = frames[0].size
    scale = min(1.0, MAX_FRAME_WIDTH / width)
    size = (max(1, round(width * scale)), max(1, round(height * scale)))
    if size == (width, height):
        return frames, size
    return [frame.resize(size, Image.Resampling.LANCZOS) for frame in frames], size


def pack_atlas(frames: list[Image.Image]) -> tuple[Image.Image, int, int]:
    frame_w, frame_h = frames[0].size
    max_cols = max(1, 4096 // frame_w)
    columns = min(len(frames), max_cols)
    rows = math.ceil(len(frames) / columns)
    if rows * frame_h > 4096:
        raise RuntimeError(f"atlas exceeds 4096px ({columns}x{rows} cells of {frame_w}x{frame_h})")
    atlas = Image.new("RGBA", (columns * frame_w, rows * frame_h), (0, 0, 0, 0))
    for index, frame in enumerate(frames):
        atlas.alpha_composite(frame, ((index % columns) * frame_w, (index // columns) * frame_h))
    return atlas, columns, rows


def make_preview(frame: Image.Image, map_image: Path | None, output: Path) -> None:
    panel_size = (480, 270)
    canvas = Image.new("RGB", (panel_size[0] * 3, panel_size[1]), (0, 0, 0))
    backgrounds = [Image.new("RGB", panel_size, (18, 53, 78)), Image.new("RGB", panel_size, (205, 205, 198))]
    if map_image and map_image.is_file():
        bg = Image.open(map_image).convert("RGB")
        bg.thumbnail(panel_size, Image.Resampling.LANCZOS)
        map_bg = Image.new("RGB", panel_size, (65, 62, 45))
        map_bg.paste(bg, ((panel_size[0] - bg.width) // 2, (panel_size[1] - bg.height) // 2))
        backgrounds.append(map_bg)
    else:
        backgrounds.append(Image.new("RGB", panel_size, (90, 115, 74)))
    overlay = frame.copy()
    overlay.thumbnail((430, 230), Image.Resampling.LANCZOS)
    for index, background in enumerate(backgrounds):
        layer = Image.new("RGBA", panel_size, (0, 0, 0, 0))
        layer.alpha_composite(overlay, ((panel_size[0] - overlay.width) // 2, (panel_size[1] - overlay.height) // 2))
        background.paste(layer, (0, 0), layer)
        canvas.paste(background, (index * panel_size[0], 0))
    ImageDraw.Draw(canvas).text((8, 8), "deep blue / light gray / map", fill=(255, 255, 255))
    canvas.save(output, quality=92)


def build_effect(name: str, spec: dict[str, str], video: Path, out_root: Path,
                 ffmpeg: str | None, ffprobe: str | None, swift_extractor: Path,
                 map_image: Path | None) -> dict[str, object]:
    duration = probe_duration(video, ffprobe)
    count = max(1, int(math.floor(duration * FPS)))
    effect_dir = out_root / name
    effect_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"map_fx_{name}_") as temp:
        temp_dir = Path(temp)
        decoder = extract_frames(video, temp_dir, count, duration, ffmpeg, swift_extractor)
        raw_paths = sorted(temp_dir.glob("frame_*.png"))
        if len(raw_paths) != count:
            raise RuntimeError(f"{name}: expected {count} frames, decoded {len(raw_paths)}")
        raw = [np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) for path in raw_paths]
        noise, peak = alpha_metrics(raw, spec["background"])
        noise = max(noise, float(spec.get("noise_floor", 4.0)))
        rgba = [make_rgba(frame, spec["background"], noise, peak) for frame in raw]
        crop = union_crop(rgba)
        cropped = [Image.fromarray(frame[crop[1]:crop[3], crop[0]:crop[2]], "RGBA") for frame in rgba]
        cropped, frame_size = resize_frames(cropped)
        atlas, columns, rows = pack_atlas(cropped)
        atlas_path = effect_dir / f"{name}_atlas.png"
        atlas.save(atlas_path, optimize=True)
        make_preview(cropped[len(cropped) // 2], map_image, effect_dir / f"{name}_alpha_check.jpg")
    manifest: dict[str, object] = {
        "id": name,
        "source": f"incoming_map_fx/{video.name}",
        "source_duration_seconds": round(duration, 4),
        "decoder": decoder,
        "background_mode": spec["background"],
        "fps": FPS,
        "frame_count": count,
        "frame_size": list(frame_size),
        "columns": columns,
        "rows": rows,
        "atlas": f"res://assets/map_fx/generated/{name}/{name}_atlas.png",
        "crop_source_pixels": [crop[0], crop[1], crop[2] - crop[0], crop[3] - crop[1]],
        "alpha_noise_threshold": round(noise, 3),
        "alpha_peak": round(peak, 3),
        "loop_mode": spec["loop"],
    }
    (effect_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return manifest


def locate_sources(source_dir: Path) -> tuple[dict[str, Path], list[str]]:
    videos = list(source_dir.glob("*.mp4"))
    selected: dict[str, Path] = {}
    missing: list[str] = []
    for name, spec in SPECS.items():
        matches = [path for path in videos if spec["needle"].lower() in path.name.lower()]
        if name == "sea_glints":
            matches.sort(key=lambda path: ("(1)" not in path.name, path.name))
        if matches:
            selected[name] = matches[0]
        else:
            missing.append(name)
    return selected, missing


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, default=Path("incoming_map_fx"))
    parser.add_argument("--output-dir", type=Path, default=Path("assets/map_fx/generated"))
    parser.add_argument("--map", type=Path, default=Path("assets/game/map/map_cn_7city_unmarked_v1.png"))
    parser.add_argument("--strict", action="store_true", help="fail when any adopted source is missing")
    args = parser.parse_args()

    source_dir = args.source_dir.resolve()
    out_root = args.output_dir.resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    selected, missing = locate_sources(source_dir)
    if missing:
        print("MISSING adopted sources: " + ", ".join(missing), file=sys.stderr)
        if args.strict:
            return 2
    ffmpeg, ffprobe = find_executable("ffmpeg"), find_executable("ffprobe")
    swift_extractor = Path(__file__).with_name("extract_video_frames.swift")
    manifests = []
    for name, video in selected.items():
        print(f"BUILD {name}: {video.name}")
        manifests.append(build_effect(
            name, SPECS[name], video, out_root, ffmpeg, ffprobe,
            swift_extractor, args.map.resolve() if args.map else None,
        ))
    combined = {
        "format": 1,
        "reference_map_size": [2048, 1153],
        "generated_effects": [manifest["id"] for manifest in manifests],
        "missing_effects": missing,
        "effects": {manifest["id"]: manifest for manifest in manifests},
    }
    (out_root / "map_fx_manifest.json").write_text(json.dumps(combined, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(combined, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
