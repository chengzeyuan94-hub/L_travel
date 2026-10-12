#!/usr/bin/env python3
"""Shared magenta-screen removal for city idle and hover assets."""

from __future__ import annotations

from collections import deque

import numpy as np
from PIL import Image


def estimate_magenta(rgb: np.ndarray) -> np.ndarray:
	h, w, _ = rgb.shape
	band = max(2, min(h, w) // 100)
	edge = np.concatenate(
		[
			rgb[:band].reshape(-1, 3),
			rgb[-band:].reshape(-1, 3),
			rgb[:, :band].reshape(-1, 3),
			rgb[:, -band:].reshape(-1, 3),
		],
		axis=0,
	).astype(np.float32)
	r, g, b = edge[:, 0], edge[:, 1], edge[:, 2]
	magenta_like = (r > 150) & (b > 140) & (g < np.minimum(r, b) - 20)
	if magenta_like.sum() >= 32:
		edge = edge[magenta_like]
	return np.median(edge, axis=0)


def border_connected(mask: np.ndarray) -> np.ndarray:
	h, w = mask.shape
	seen = np.zeros((h, w), dtype=bool)
	queue: deque[tuple[int, int]] = deque()
	for x in range(w):
		if mask[0, x]:
			queue.append((0, x))
		if mask[h - 1, x]:
			queue.append((h - 1, x))
	for y in range(h):
		if mask[y, 0]:
			queue.append((y, 0))
		if mask[y, w - 1]:
			queue.append((y, w - 1))
	while queue:
		y, x = queue.popleft()
		if y < 0 or y >= h or x < 0 or x >= w or seen[y, x] or not mask[y, x]:
			continue
		seen[y, x] = True
		queue.append((y - 1, x))
		queue.append((y + 1, x))
		queue.append((y, x - 1))
		queue.append((y, x + 1))
	return seen


def key_magenta_image(image: Image.Image, source_file: str) -> tuple[Image.Image, dict]:
	image = image.convert("RGBA")
	rgba = np.asarray(image).copy()
	rgb = rgba[:, :, :3].astype(np.float32)
	key = estimate_magenta(rgb)
	distance = np.linalg.norm(rgb - key[None, None, :], axis=2)
	r, g, b = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
	magenta_like = (r > 145) & (b > 135) & (g < np.minimum(r, b) - 14)
	candidate = (distance <= 82.0) | (magenta_like & (distance <= 125.0))
	background = border_connected(candidate)
	rgba[background | magenta_like, 3] = 0

	purple_spill = (
		(r > 70)
		& (b > 70)
		& (g < np.minimum(r, b) - 30)
		& (np.abs(r - b) < 90)
	)
	for _ in range(4):
		opaque = rgba[:, :, 3] > 0
		transparent = ~opaque
		near_transparent = np.zeros_like(opaque)
		near_transparent[1:] |= transparent[:-1]
		near_transparent[:-1] |= transparent[1:]
		near_transparent[:, 1:] |= transparent[:, :-1]
		near_transparent[:, :-1] |= transparent[:, 1:]
		rgba[opaque & near_transparent & purple_spill, 3] = 0

	alpha = rgba[:, :, 3]
	ys, xs = np.where(alpha > 32)
	bbox = [0, 0, 0, 0]
	if len(xs):
		bbox = [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]
	visible = max(1, int((alpha > 32).sum()))
	residue = int(
		(
			(rgba[:, :, 0] > 180)
			& (rgba[:, :, 2] > 170)
			& (rgba[:, :, 1] < 90)
			& (alpha > 32)
		).sum()
	)
	return Image.fromarray(rgba, "RGBA"), {
		"source_file": source_file,
		"key_rgb": [round(float(v), 2) for v in key],
		"bbox": bbox,
		"magenta_residue_ratio": round(residue / visible, 8),
	}
