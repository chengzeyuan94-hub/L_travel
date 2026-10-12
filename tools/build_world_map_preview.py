#!/usr/bin/env python3
"""Downsample the approved full-resolution world map for a Godot preview."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def main() -> None:
	parser = argparse.ArgumentParser()
	parser.add_argument("--source", required=True, type=Path)
	parser.add_argument("--output", required=True, type=Path)
	parser.add_argument("--width", type=int, default=4096)
	args = parser.parse_args()

	Image.MAX_IMAGE_PIXELS = None
	image = Image.open(args.source).convert("RGB")
	height = round(image.height * args.width / image.width)
	preview = image.resize((args.width, height), Image.Resampling.LANCZOS)
	args.output.parent.mkdir(parents=True, exist_ok=True)
	preview.save(args.output, optimize=True)
	print(f"{image.width}x{image.height} → {preview.width}x{preview.height}: {args.output}")


if __name__ == "__main__":
	main()
