#!/usr/bin/env python3
"""One-time horizontal frame alignment for the map-piece walk sheets.

Camel sheets are modified in-place after their originals are copied to
``assets/game/pieces/camel/_orig``.  Ship sheets are metrics-only by design.
The metric deliberately uses the torso band instead of the full silhouette so
leg motion and head sway cannot pull the alignment reference around.
"""

from __future__ import annotations

import argparse
import shutil
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path

from PIL import Image


FRAME_SIZE = 256
FRAME_COUNT = 8
TORSO_Y_MIN = 60
TORSO_Y_MAX = 170
ALPHA_THRESHOLD = 32


@dataclass(frozen=True)
class SheetMetrics:
    path: Path
    centroids: tuple[float, ...]
    median_x: float
    max_jump: float
    shifts: tuple[int, ...]
    max_trim: int


def torso_centroid_x(frame: Image.Image) -> float:
    """Return the alpha-weighted torso-band x centroid for a 256² RGBA frame."""
    rgba = frame.convert("RGBA")
    pixels = rgba.load()
    weighted_x = 0
    alpha_total = 0
    for y in range(TORSO_Y_MIN, TORSO_Y_MAX + 1):
        for x in range(FRAME_SIZE):
            alpha = pixels[x, y][3]
            if alpha > ALPHA_THRESHOLD:
                weighted_x += x * alpha
                alpha_total += alpha
    if alpha_total == 0:
        raise ValueError("torso band has no alpha>32 pixels")
    return weighted_x / alpha_total


def split_frames(sheet: Image.Image) -> list[Image.Image]:
    if sheet.size != (FRAME_SIZE * FRAME_COUNT, FRAME_SIZE):
        raise ValueError("expected 2048x256, got %dx%d" % sheet.size)
    return [sheet.crop((i * FRAME_SIZE, 0, (i + 1) * FRAME_SIZE, FRAME_SIZE)) for i in range(FRAME_COUNT)]


def max_cyclic_jump(values: list[float]) -> float:
    return max(abs(values[(i + 1) % len(values)] - values[i]) for i in range(len(values)))


def shift_frame_horizontally(frame: Image.Image, offset_x: int) -> tuple[Image.Image, int]:
    """Translate without wrapping. Return the new frame and cropped occupied width."""
    alpha = frame.getchannel("A")
    cropped_width = 0
    if offset_x > 0:
        # Source pixels beyond the right edge are discarded.
        for x in range(FRAME_SIZE - offset_x, FRAME_SIZE):
            if alpha.crop((x, 0, x + 1, FRAME_SIZE)).getbbox() is not None:
                cropped_width += 1
    elif offset_x < 0:
        for x in range(0, -offset_x):
            if alpha.crop((x, 0, x + 1, FRAME_SIZE)).getbbox() is not None:
                cropped_width += 1
    output = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    output.alpha_composite(frame, (offset_x, 0))
    return output, cropped_width


def analyse_sheet(path: Path) -> SheetMetrics:
    with Image.open(path) as opened:
        sheet = opened.convert("RGBA")
    frames = split_frames(sheet)
    centroids = [torso_centroid_x(frame) for frame in frames]
    med = statistics.median(centroids)
    shifts = [round(med - value) for value in centroids]
    return SheetMetrics(
        path=path,
        centroids=tuple(centroids),
        median_x=med,
        max_jump=max_cyclic_jump(centroids),
        shifts=tuple(shifts),
        max_trim=0,
    )


def realign_camel_sheet(path: Path, backup_dir: Path, dry_run: bool) -> tuple[SheetMetrics, SheetMetrics]:
    before = analyse_sheet(path)
    if dry_run:
        return before, before
    backup_dir.mkdir(parents=True, exist_ok=True)
    ignore = backup_dir / ".gdignore"
    if not ignore.exists():
        ignore.write_text("# Original camel walk sheets; intentionally ignored by Godot.\n", encoding="utf-8")
    backup = backup_dir / path.name
    if not backup.exists():
        shutil.copy2(path, backup)

    with Image.open(path) as opened:
        sheet = opened.convert("RGBA")
    frames = split_frames(sheet)
    aligned = []
    max_trim = 0
    # Keep Python 3.9 compatibility in the local Godot toolchain.
    for frame, shift in zip(frames, before.shifts):
        shifted, trim = shift_frame_horizontally(frame, shift)
        aligned.append(shifted)
        max_trim = max(max_trim, trim)
    output = Image.new("RGBA", sheet.size, (0, 0, 0, 0))
    for i, frame in enumerate(aligned):
        output.alpha_composite(frame, (i * FRAME_SIZE, 0))
    output.save(path)

    after = analyse_sheet(path)
    after = SheetMetrics(
        path=after.path,
        centroids=after.centroids,
        median_x=after.median_x,
        max_jump=after.max_jump,
        shifts=before.shifts,
        max_trim=max_trim,
    )
    return before, after


def direction_from_path(path: Path) -> str:
    # camel_ne_walk_8f.png -> ne
    return path.name.removeprefix("camel_").removesuffix("_walk_8f.png")


def print_row(unit: str, direction: str, before: SheetMetrics, after: SheetMetrics | None) -> None:
    if after is None:
        print(
            "%s %-2s | before=%5.2fpx | ship metrics only" % (unit, direction, before.max_jump)
        )
        return
    print(
        "%s %-2s | before=%5.2fpx | after=%5.2fpx | shifts=%s | cropped_occupied_width=%dpx"
        % (unit, direction, before.max_jump, after.max_jump, list(before.shifts), after.max_trim)
    )
    if after.max_trim > 8:
        print("WARNING: %s cropped occupied width %dpx (>8px); inspect manually." % (direction, after.max_trim))
    if after.max_jump > 8.0:
        print("WARNING: %s alignment remains above 8px threshold." % direction)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="measure camel sheets without writing or backing up")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root: Path = args.root.resolve()
    camel_dir = root / "assets/game/pieces/camel"
    ship_dir = root / "assets/game/pieces/ship"
    backup_dir = camel_dir / "_orig"

    print("=== camel (torso alpha-weighted centroid, y=60..170, alpha>32) ===")
    failed = False
    for path in sorted(camel_dir.glob("camel_*_walk_8f.png")):
        before, after = realign_camel_sheet(path, backup_dir, args.dry_run)
        print_row("camel", direction_from_path(path), before, after)
        failed = failed or (not args.dry_run and after.max_jump > 8.0)

    print("=== ship (metrics only; no files modified) ===")
    for path in sorted(ship_dir.glob("ship_*_sail_8f.png")):
        before = analyse_sheet(path)
        direction = path.name.removeprefix("ship_").removesuffix("_sail_8f.png")
        print_row("ship", direction, before, None)
        if before.max_jump > 12.0:
            print("WARNING: ship %s exceeds 12px threshold; product decision required." % direction)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
