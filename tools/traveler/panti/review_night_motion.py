"""Review independently captured star twinkle, lamp breathing and three meteors."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument("checkpoint", type=Path)
args = parser.parse_args()
folder = args.checkpoint / "night-isolation"

def pixels(name):
    return np.asarray(Image.open(folder / (name + ".png")).convert("RGB")).astype(np.int16)

report = {"threshold_note": "Changes over 1/255 exclude numerical rounding; raw maxima and means also reported.", "stars": [], "lamps": [], "meteors": []}
for kind, rect in [("stars", (730, 0, 1150, 210)), ("lamps", (800, 530, 1600, 835))]:
    x0, y0, x1, y1 = rect
    for first, second in [(0, 2), (2, 4), (4, 6)]:
        a, b = pixels(f"{kind}-{first:02d}"), pixels(f"{kind}-{second:02d}")
        delta = np.abs(a - b)[y0:y1, x0:x1]
        report[kind].append({"times_s": [first, second], "rect": rect,
            "changed_pixels_gt1": int((delta.max(axis=2) > 1).sum()),
            "max_difference_255": int(delta.max()), "mean_difference_255": float(delta.mean())})
for index in range(1, 4):
    base, active = pixels(f"meteor-{index:02d}-baseline"), pixels(f"meteor-{index:02d}-active")
    delta = np.maximum(active - base, 0)
    # Measure the authored sky opening; separately report any rerender residue
    # elsewhere instead of including isolated wall-seam pixels in trail bounds.
    x0, y0, x1, y1 = 700, 0, 1250, 260
    sky_delta = delta[y0:y1, x0:x1]
    ys, xs = np.where(sky_delta.max(axis=2) > 5)
    ys, xs = ys + y0, xs + x0
    y, x = np.unravel_index(sky_delta.sum(axis=2).argmax(), sky_delta.shape[:2])
    y, x = y + y0, x + x0
    report["meteors"].append({"index": index, "changed_pixels_gt5": int(len(xs)),
        "measured_sky_region": [x0, y0, x1, y1],
        "outside_region_changed_pixels_gt5": int((delta.max(axis=2) > 5).sum()) - len(xs),
        "visible_bounds_px": [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())] if len(xs) else [],
        "measured_brightest_head_px": [int(x), int(y)], "max_difference_255": int(delta.max())})
report["all_three_meteors_visible"] = all(m["changed_pixels_gt5"] > 0 for m in report["meteors"])
(folder / "night-motion-metrics.json").write_text(json.dumps(report, indent=2) + "\n")
source = args.checkpoint / "transition-final"
board = Image.new("RGB", (1920, 400), "#121b2e")
draw = ImageDraw.Draw(board)
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
for i, (filename, label) in enumerate([("morning.png", "0 s"), ("frame-0120.png", "4 s"), ("frame-0240.png", "8 s")]):
    board.paste(Image.open(source / filename).convert("RGB").resize((640, 360), Image.Resampling.LANCZOS), (i * 640, 40))
    draw.text((i * 640 + 15, 7), label, fill="white", font=font)
board.save(source / "transition-filmstrip.jpg", quality=94)
print(json.dumps(report, indent=2))
