"""Measure the same-phase star isolation capture; writes review artifacts beside it."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument("capture_dir", type=Path)
args = parser.parse_args()
folder = args.capture_dir
night = np.asarray(Image.open(folder / "midnight.png").convert("RGB")).astype(np.int16)
base = np.asarray(Image.open(folder / "midnight-no-stars.png").convert("RGB")).astype(np.int16)
difference = np.max(np.abs(night - base), axis=2)
regions = {
    "snow_foreground": [0, 1000, 1920, 1080],
    "character_face": [535, 680, 596, 713],
    "castle_wall": [1310, 747, 1420, 775],
    "near_cedar_solid": [310, 70, 380, 360],
    "open_sky": [740, 0, 1050, 85],
}
report = {}
for name, (x0, y0, x1, y1) in regions.items():
    values = difference[y0:y1, x0:x1]
    report[name] = {
        "rect": regions[name],
        "max_difference_255": int(values.max()),
        "changed_pixels_gt1": int((values > 1).sum()),
        "pixels": int(values.size),
    }
morning = np.asarray(Image.open(folder / "morning.png").convert("RGB")).astype(np.int16)
returned = np.asarray(Image.open(folder / "morning-return.png").convert("RGB")).astype(np.int16)
roundtrip = np.max(np.abs(morning - returned), axis=2)
report["morning_roundtrip"] = {
    "changed_pixels": int((roundtrip > 0).sum()),
    "max_difference_255": int(roundtrip.max()),
}
report["interpretation"] = "Opaque interior samples should receive no stars. Open sky should change. These samples accompany full-image visual review; they do not prove all pixels. Differences up to 1/255 are reported, not silently discarded."
(folder / "star-occlusion-review.json").write_text(json.dumps(report, indent=2) + "\n")
Image.fromarray(np.repeat(np.minimum(difference * 6, 255).astype(np.uint8)[..., None], 3, axis=2)).save(folder / "stars-isolation-difference.png")
comparison = Image.new("RGB", (1920, 580), "#151e31")
draw = ImageDraw.Draw(comparison)
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
for i, (filename, label) in enumerate([("morning.png", "MORNING"), ("midnight.png", "MIDNIGHT")]):
    comparison.paste(Image.open(folder / filename).convert("RGB").resize((960, 540), Image.Resampling.LANCZOS), (i * 960, 40))
    draw.text((i * 960 + 22, 7), label, fill="white", font=font)
comparison.save(folder / "morning-midnight-comparison.jpg", quality=94)
print(json.dumps(report, indent=2))
