#!/usr/bin/env python3
"""Build a temporary 16-city hover-animation asset pack for Godot.

This is a presentation-only pipeline. It does not create ruleset cities,
routes, trade decks, or geographic coordinates.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

from city_chroma_key import key_magenta_image


FRAME_COUNT = 32
FRAME_SIZE = 256
ATLAS_COLUMNS = 8
ATLAS_ROWS = 4
IDLE_SIZE = 1024
PLAYBACK_FPS = 8.0

CITY_SPECS = [
	("yumenguan", "玉门关", "01-yumen-pass-1024.png"),
	("ancient_rome", "古罗马城", "02-ancient-rome-1024.png"),
	("constantinople", "君士坦丁堡", "03-constantinople-1024.png"),
	("changan", "长安", "04-changan-1024.png"),
	("pantuo", "盘橐城", "05-pantuo-city-v2-1024.png"),
	("baghdad", "巴格达", "06-baghdad-1024.png"),
	("delhi", "德里", "07-delhi-1024.png"),
	("geumseong", "金城", "08-geumseong-1024.png"),
	("chenla", "真腊", "09-chenla-1024.png"),
	("aden", "阿丹国", "10-aden-1024.png"),
	("heijo_kyo", "平城京", "11-heijo-kyo-1024.png"),
	("sri_lanka", "狮子国", "12-sri-lanka-1024.png"),
	("cairo", "开罗", "13-cairo-1024.png"),
	("jeddah", "吉达", "14-jeddah-1024.png"),
	("dagon", "大光", "15-dagon-1024.png"),
	("quanzhou", "泉州", "16-quanzhou-1024.png"),
]


def find_video(directory: Path, display_name: str) -> Path:
	matches = sorted(directory.glob(f"*{display_name}*.mp4"))
	if len(matches) != 1:
		raise RuntimeError(f"{display_name}: expected exactly one video, got {len(matches)}")
	return matches[0]


def extract_frames(swift_tool: Path, video: Path, output: Path) -> list[Path]:
	subprocess.check_call(
		[
			"/usr/bin/swift",
			str(swift_tool),
			str(video),
			str(output),
			str(FRAME_COUNT),
			"0.0",
			"0.9375",
		],
		stdout=subprocess.DEVNULL,
	)
	frames = sorted(output.glob("frame_*.png"))
	if len(frames) != FRAME_COUNT:
		raise RuntimeError(f"{video.name}: expected {FRAME_COUNT} frames, got {len(frames)}")
	return frames


def process_image(path: Path, size: int) -> tuple[Image.Image, dict]:
	source = Image.open(path).convert("RGBA")
	# Keying after the runtime resize is much faster and also cleans the exact
	# edge pixels Godot will display.
	if source.size != (size, size):
		source = source.resize((size, size), Image.Resampling.LANCZOS)
	return key_magenta_image(source, path.name)


def build_city(
	city_id: str,
	display_name: str,
	static_path: Path,
	video_path: Path,
	swift_tool: Path,
	output_root: Path,
) -> dict:
	city_dir = output_root / city_id
	city_dir.mkdir(parents=True, exist_ok=True)
	idle, idle_meta = process_image(static_path, IDLE_SIZE)
	idle_path = city_dir / "idle.png"
	idle.save(idle_path, optimize=True)

	with tempfile.TemporaryDirectory(prefix=f"silkroad_{city_id}_") as tmp:
		frame_paths = extract_frames(swift_tool, video_path, Path(tmp))
		atlas = Image.new(
			"RGBA",
			(FRAME_SIZE * ATLAS_COLUMNS, FRAME_SIZE * ATLAS_ROWS),
			(0, 0, 0, 0),
		)
		frame_meta = []
		for index, frame_path in enumerate(frame_paths):
			frame, meta = process_image(frame_path, FRAME_SIZE)
			atlas.alpha_composite(
				frame,
				(
					(index % ATLAS_COLUMNS) * FRAME_SIZE,
					(index // ATLAS_COLUMNS) * FRAME_SIZE,
				),
			)
			meta["index"] = index
			frame_meta.append(meta)
		atlas_path = city_dir / "hover_32f.png"
	atlas.save(atlas_path, optimize=True)

	entry = {
		"id": city_id,
		"display_name": display_name,
		"idle": f"res://assets/game/cities/world_hover_preview/{city_id}/idle.png",
		"atlas": f"res://assets/game/cities/world_hover_preview/{city_id}/hover_32f.png",
		"frame_count": FRAME_COUNT,
		"columns": ATLAS_COLUMNS,
		"frame_size": [FRAME_SIZE, FRAME_SIZE],
		"fps": PLAYBACK_FPS,
		"idle_meta": idle_meta,
		"frames": frame_meta,
		"source_video_file": video_path.name,
	}
	(city_dir / "manifest.json").write_text(
		json.dumps(entry, ensure_ascii=False, indent=2) + "\n",
		encoding="utf-8",
	)
	return entry


def main() -> None:
	parser = argparse.ArgumentParser()
	parser.add_argument("--video-dir", required=True, type=Path)
	parser.add_argument("--static-dir", required=True, type=Path)
	parser.add_argument("--swift", required=True, type=Path)
	parser.add_argument("--out-dir", required=True, type=Path)
	args = parser.parse_args()

	entries = []
	for index, (city_id, display_name, static_file) in enumerate(CITY_SPECS, 1):
		static_path = args.static_dir / static_file
		if not static_path.is_file():
			raise FileNotFoundError(static_path)
		video_path = find_video(args.video_dir, display_name)
		print(f"[{index:02d}/16] {display_name} ← {video_path.name}", flush=True)
		entries.append(
			build_city(
				city_id,
				display_name,
				static_path,
				video_path,
				args.swift,
				args.out_dir,
			)
		)

	master = {
		"pack_id": "world_hover_preview_v1",
		"presentation_only": True,
		"frame_count": FRAME_COUNT,
		"cities": entries,
	}
	(args.out_dir / "manifest.json").write_text(
		json.dumps(master, ensure_ascii=False, indent=2) + "\n",
		encoding="utf-8",
	)
	print(f"built {len(entries)} city assets → {args.out_dir}")


if __name__ == "__main__":
	main()
