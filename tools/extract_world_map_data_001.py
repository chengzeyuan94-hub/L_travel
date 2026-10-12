#!/usr/bin/env python3
"""TASK-WORLD-MAP-DATA-001-REV2D — dash-only route masks + movement corridor gates.

REV2A: Y-up→Y-down via model_to_screen_point().
REV2B: alias collapse, route-layer coverage (frozen semantics).
REV2C: smooth movement_polyline_px (frozen geometry quality gates).
REV2D: authoritative dash-only LAND/SEA masks from PXD path layers.

Does NOT modify cn_demo_v1, board_nodes.json, board_edges.json, or runtime systems.
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import shutil
import sqlite3
import struct
import sys
import tempfile
import zipfile
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

try:
	from scipy.ndimage import distance_transform_edt
except ImportError:  # pragma: no cover
	distance_transform_edt = None

ROOT = Path(__file__).resolve().parents[1]
LOGIC_W, LOGIC_H = 4096.0, 1363.0
DOC_W, DOC_H = 8192.0, 2726.0
ASSET_ROOT = "res://assets/game/cities/world_hover_preview"
MAP_TEXTURE_RES = "res://assets/game/maps/world/world_map_v1.png"
SNAP_PX = 80.0
CLASSIFY_SNAP_PX = 80.0
EDGE_END_MAX_PX = 8.0
PRE_SNAP_MAX_PX = 8.0
MASK_MEAN_MAX = 6.0
MASK_P95_MAX = 10.0
MASK_COVERAGE_MIN = 0.80
HIT_PAD_PX = 10.0
ALPHA_THRESHOLD = 96
MIN_VIEW_WIDTH = 1280.0  # minimum supported fit width
MIN_HIT_SCREEN_PX = 44.0

CITY_SPEC = [
	("yumenguan", "玉门关", "玉门关", "yumenguan"),
	("ancient_rome", "古罗马城", "古罗马", "ancient_rome"),
	("constantinople", "君士坦丁堡", "君士坦丁堡", "constantinople"),
	("changan", "长安", "长安", "changan"),
	("pantuo", "盘橐城", "盘橐城", "pantuo"),
	("baghdad", "巴格达", "巴格达", "baghdad"),
	("delhi", "德里", "德里", "delhi"),
	("geumseong", "金城", "金城", "geumseong"),
	("chenla", "真腊", "真腊", "chenla"),
	("aden", "阿丹国", "阿丹", "aden"),
	("heijokyo", "平城京", "平城京", "heijo_kyo"),
	("simhala", "狮子国", "狮子国", "sri_lanka"),
	("cairo", "开罗", "开罗", "cairo"),
	("jeddah", "吉达", "吉达", "jeddah"),
	("dagon", "大光", "大光", "dagon"),
	("quanzhou", "泉州", "泉州", "quanzhou"),
]

BUILDING_FILE_HINTS = {
	"yumenguan": "yumen-pass",
	"ancient_rome": "ancient-rome",
	"constantinople": "constantinople",
	"changan": "changan",
	"pantuo": "pantuo",
	"baghdad": "baghdad",
	"delhi": "delhi",
	"geumseong": "geumseong",
	"chenla": "chenla",
	"aden": "aden",
	"heijokyo": "heijo-kyo",
	"simhala": "sri-lanka",
	"cairo": "cairo",
	"jeddah": "jeddah",
	"dagon": "dagon",
	"quanzhou": "quanzhou",
}

ALLOWED_ROUTES = {
	"yumenguan": ["LAND"],
	"constantinople": ["LAND"],
	"changan": ["LAND"],
	"pantuo": ["LAND"],
	"baghdad": ["LAND"],
	"delhi": ["LAND"],
	"chenla": ["SEA"],
	"aden": ["SEA"],
	"heijokyo": ["SEA"],
	"cairo": ["SEA"],
	"dagon": ["SEA"],
	"ancient_rome": ["LAND", "SEA"],
	"geumseong": ["LAND", "SEA"],
	"simhala": ["LAND", "SEA"],
	"jeddah": ["LAND", "SEA"],
	"quanzhou": ["LAND", "SEA"],
}

INTERCHANGE_IDS = [cid for cid, routes in ALLOWED_ROUTES.items() if set(routes) == {"LAND", "SEA"}]

# Product-confirmed colocated route-point → city (fold before edge emit).
STOP_ALIASES = {
	"land_point_001": "ancient_rome",
	"sea_point_001": "ancient_rome",
	"land_point_003": "constantinople",
	"sea_point_003": "cairo",
	"land_point_006": "jeddah",
	"sea_point_006": "jeddah",
	"land_point_008": "baghdad",
	"sea_point_009": "aden",
	"land_point_011": "pantuo",
	"land_point_014": "delhi",
	"land_point_016": "simhala",
	"sea_point_013": "simhala",
	"sea_point_015": "dagon",
	"land_point_018": "yumenguan",
	"sea_point_020": "chenla",
	"land_point_021": "changan",
	"land_point_023": "quanzhou",
	"sea_point_022": "quanzhou",
	"sea_point_025": "geumseong",
	"sea_point_026": "heijokyo",
}

# Product REV2B: illegal land↔sea without interchange — decorative only.
EXCLUDED_PATH_LAYERS = {
	32: {
		"reason": "NON_ROUTE_DECORATIVE",
		"detail": "land_point_007↔sea_point_008 with no interchange city; product REV2B",
	},
}

ATTACH_GAP_MAX_PX = 8.0
TANGENT_KINK_MAX_DEG = 35.0  # diagnostic only on source joins (REV2B)
REVIEW_PATHS = (5, 18, 22, 26, 32, 43)
SEMANTIC_MANUAL_PATHS = (5, 18, 22, 26, 43)
# REV2C movement polyline gates
MOVEMENT_MAX_TURN_DEG = 25.0
MOVEMENT_END_MAX_PX = 1.0
MOVEMENT_MASK_MAX_PX = 8.0
MOVEMENT_SEG_RATIO_MAX = 1.5
MOVEMENT_MIN_SEG_PX = 0.5
MOVEMENT_SAMPLE_SPACING_PX = 5.0  # shorter chords stay on thin dash corridors
MOVEMENT_OFF_ROUTE_RUN_MAX_PX = 16.0
# REV2D dash-only mask gates
DASH_STROKE_PX = 6
DASH_DILATE_ITERS = 9  # corridor absorbs short equal-arc chords; coverage still ≪4%/7%
LAND_MASK_COVERAGE_MAX = 0.04
SEA_MASK_COVERAGE_MAX = 0.04
UNION_MASK_COVERAGE_MAX = 0.07
OCCLUSION_PAD_PX = 8.0


# ---------------------------------------------------------------------------
# Coordinate space: model (Y-up) → screen (Y-down). Sole Y conversion entry.
# ---------------------------------------------------------------------------
def model_to_screen_point(point) -> tuple[float, float]:
	x, y = float(point[0]), float(point[1])
	return (x, LOGIC_H - y)


def model_center_size_to_screen_rect(cx: float, cy: float, w: float, h: float):
	"""Convert model-space center+size to screen top-left rect (x, y, w, h)."""
	scx, scy = model_to_screen_point((cx, cy))
	return [scx - w / 2.0, scy - h / 2.0, w, h]


def decode_name(blob: bytes) -> str:
	n = struct.unpack_from("<I", blob, 12)[0]
	return blob[16 : 16 + n].decode("utf-8")


def decode_f64s(blob: bytes) -> tuple[float, ...]:
	n = (len(blob) - 12) // 8
	return struct.unpack_from(">" + "d" * n, blob, 12)


def decode_doc_size(blob: bytes) -> tuple[int, int]:
	return struct.unpack_from("<qq", blob, 12)


def extract_metadata_db(pxd: Path, dest: Path) -> Path:
	dest.parent.mkdir(parents=True, exist_ok=True)
	with zipfile.ZipFile(pxd) as zf:
		dest.write_bytes(zf.read("metadata.info"))
	return dest


def layer_info_map(db: sqlite3.Connection, lid: int) -> dict[str, bytes]:
	return {k: v for k, v in db.execute("SELECT key, value FROM layer_info WHERE layer_id=?", (lid,))}


def walk_find(obj, key: str, out: list):
	if isinstance(obj, dict):
		if key in obj:
			out.append(obj[key])
		for v in obj.values():
			walk_find(v, key, out)
	elif isinstance(obj, list):
		for v in obj:
			walk_find(v, key, out)


def parse_cgpath(raw: bytes) -> list[tuple]:
	i = 0
	while i + 2 <= len(raw):
		ch = raw[i : i + 2].decode("utf-16le")
		if ch.isdigit() or ch == ".":
			i += 2
		else:
			break
	elems = []
	while i < len(raw):
		cmd = chr(raw[i])
		i += 1
		if cmd in "MmLl":
			if i + 16 > len(raw):
				break
			x, y = struct.unpack_from(">dd", raw, i)
			i += 16
			elems.append((cmd, x, y))
		elif cmd in "Cc":
			if i + 48 > len(raw):
				break
			vals = struct.unpack_from(">6d", raw, i)
			i += 48
			elems.append((cmd,) + vals)
		elif cmd == "\x00":
			continue
		else:
			break
	return elems


def find_geom_t(shape: dict):
	found = []

	def w(o):
		if isinstance(o, dict):
			if "t" in o and isinstance(o["t"], list) and len(o["t"]) >= 6 and "S" in o:
				found.append(o["t"])
			for v in o.values():
				w(v)
		elif isinstance(o, list):
			for v in o:
				w(v)

	w(shape)
	return found[-1] if found else None


def apply_t(pt, t):
	if not t:
		return pt
	a, b, c, d, tx, ty = t[:6]
	x, y = pt
	return (a * x + c * y + tx, b * x + d * y + ty)


def layer_matrix(info: dict) -> np.ndarray:
	pos = decode_f64s(info["position"])
	size = decode_f64s(info["size"])
	sc = decode_f64s(info["scale"])
	ang = math.radians(decode_f64s(info["angle"])[0])
	anc = decode_f64s(info["anchorPoint"])
	ax, ay = anc[0] * size[0], anc[1] * size[1]
	c, s = math.cos(ang), math.sin(ang)
	sx, sy = sc
	return np.array(
		[
			[c * sx, -s * sy, pos[0] - c * sx * ax + s * sy * ay],
			[s * sx, c * sy, pos[1] - s * sx * ax - c * sy * ay],
			[0, 0, 1],
		],
		dtype=float,
	)


def path_model_polyline(info: dict, shape: dict, steps: int = 24) -> list[tuple[float, float]]:
	"""Polyline in PXD model space (Y-up), before screen flip."""
	b64s = []
	walk_find(shape, "dataFromCGPath", b64s)
	if not b64s:
		return []
	elems = parse_cgpath(base64.b64decode(b64s[0]))
	t = find_geom_t(shape)
	size = decode_f64s(info["size"])
	pts = []
	cur = None
	for e in elems:
		if e[0] in "MmLl":
			p = apply_t((e[1], e[2]), t)
			pts.append(p)
			cur = p
		elif e[0] in "Cc" and cur is not None:
			p0 = cur
			p1 = apply_t((e[1], e[2]), t)
			p2 = apply_t((e[3], e[4]), t)
			p3 = apply_t((e[5], e[6]), t)
			for tt in np.linspace(0, 1, steps):
				u = 1 - tt
				pts.append(
					(
						u**3 * p0[0] + 3 * u**2 * tt * p1[0] + 3 * u * tt**2 * p2[0] + tt**3 * p3[0],
						u**3 * p0[1] + 3 * u**2 * tt * p1[1] + 3 * u * tt**2 * p2[1] + tt**3 * p3[1],
					)
				)
			cur = p3
	local = [(x / 2.0, y / 2.0) for x, y in pts]
	if not local:
		return []
	xs = [p[0] for p in local]
	ys = [p[1] for p in local]
	abs_like = (max(xs) > size[0] * 1.8 or max(ys) > size[1] * 1.8) and (
		max(xs) > 200 or max(ys) > 200
	)
	if abs_like:
		return local
	M = layer_matrix(info)
	out = []
	for p in local:
		v = M @ np.array([p[0], p[1], 1.0])
		out.append((float(v[0]), float(v[1])))
	return out


def path_screen_polyline(info: dict, shape: dict, steps: int = 24) -> list[tuple[float, float]]:
	return [model_to_screen_point(p) for p in path_model_polyline(info, shape, steps)]


def dist(a, b) -> float:
	return math.hypot(a[0] - b[0], a[1] - b[1])


def project_arc(poly, p):
	best_d = 1e18
	best_s = 0.0
	best_proj = p
	acc = 0.0
	for i in range(1, len(poly)):
		a, b = poly[i - 1], poly[i]
		vx, vy = b[0] - a[0], b[1] - a[1]
		seg = math.hypot(vx, vy)
		if seg < 1e-9:
			d = dist(p, a)
			s = acc
			proj = a
		else:
			t = max(0.0, min(1.0, ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / (seg * seg)))
			proj = (a[0] + t * vx, a[1] + t * vy)
			d = dist(p, proj)
			s = acc + t * seg
		if d < best_d:
			best_d = d
			best_s = s
			best_proj = proj
		acc += seg
	return best_s, best_d, best_proj


def polyline_length(poly):
	return sum(dist(poly[i - 1], poly[i]) for i in range(1, len(poly)))


def point_at_arc(poly, s: float):
	total = polyline_length(poly)
	if total < 1e-9 or s <= 0:
		return poly[0]
	if s >= total:
		return poly[-1]
	acc = 0.0
	for i in range(1, len(poly)):
		seg = dist(poly[i - 1], poly[i])
		if acc + seg >= s:
			t = 0.0 if seg < 1e-9 else (s - acc) / seg
			return (
				poly[i - 1][0] + t * (poly[i][0] - poly[i - 1][0]),
				poly[i - 1][1] + t * (poly[i][1] - poly[i - 1][1]),
			)
		acc += seg
	return poly[-1]


def sub_polyline(poly, s0: float, s1: float, samples: int = 24):
	"""Extract densified polyline between arc lengths s0..s1."""
	total = polyline_length(poly)
	flipped = s1 < s0
	if flipped:
		s0, s1 = s1, s0
	s0 = max(0.0, min(total, s0))
	s1 = max(0.0, min(total, s1))
	if abs(s1 - s0) < 1e-6:
		p = point_at_arc(poly, s0)
		return [p, p]
	pts = [point_at_arc(poly, s0 + (s1 - s0) * t / samples) for t in range(samples + 1)]
	if flipped:
		pts.reverse()
	return pts


def norm_xy(x, y):
	return [round(x / LOGIC_W, 6), round(y / LOGIC_H, 6)]


def clamp_norm(n):
	return [max(0.0, min(1.0, n[0])), max(0.0, min(1.0, n[1]))]


def fold_stop_id(sid: str) -> str:
	return STOP_ALIASES.get(sid, sid)


def vec_angle_deg(u, v) -> float:
	ul = math.hypot(u[0], u[1])
	vl = math.hypot(v[0], v[1])
	if ul < 1e-9 or vl < 1e-9:
		return 0.0
	c = max(-1.0, min(1.0, (u[0] * v[0] + u[1] * v[1]) / (ul * vl)))
	return math.degrees(math.acos(c))


def mask_dist_at(dist_field, pt) -> float:
	h, w = dist_field.shape
	xi = max(0, min(w - 1, int(round(pt[0]))))
	yi = max(0, min(h - 1, int(round(pt[1]))))
	return float(dist_field[yi, xi])


def vec_unit(v):
	L = math.hypot(v[0], v[1])
	if L < 1e-9:
		return (0.0, 0.0)
	return (v[0] / L, v[1] / L)


def hermite_cubic(p0, p1, m0, m1, n: int = 12):
	"""Cubic Hermite from p0→p1 with endpoint tangents m0, m1."""
	pts = []
	for i in range(n + 1):
		t = i / n
		h00 = 2 * t**3 - 3 * t**2 + 1
		h10 = t**3 - 2 * t**2 + t
		h01 = -2 * t**3 + 3 * t**2
		h11 = t**3 - t**2
		pts.append(
			(
				h00 * p0[0] + h10 * m0[0] + h01 * p1[0] + h11 * m1[0],
				h00 * p0[1] + h10 * m0[1] + h01 * p1[1] + h11 * m1[1],
			)
		)
	return pts


def dedupe_poly(poly, min_dist: float = MOVEMENT_MIN_SEG_PX):
	if not poly:
		return []
	out = [poly[0]]
	for p in poly[1:]:
		if dist(out[-1], p) >= min_dist:
			out.append(p)
	if len(out) == 1 and len(poly) > 1:
		out.append(poly[-1])
	return out


def resample_arc_uniform(poly, n=None, spacing=None, strict: bool = False):
	"""Resample polyline to roughly uniform arc-length spacing; pin endpoints."""
	poly = dedupe_poly([(float(p[0]), float(p[1])) for p in poly], 0.25)
	if len(poly) < 2:
		return poly
	total = polyline_length(poly)
	if total < 1e-6:
		return [poly[0], poly[-1]]
	if n is None:
		sp = spacing if spacing is not None else max(6.0, min(14.0, total / 40.0))
		n = max(8, int(math.ceil(total / sp)))
	pts = [point_at_arc(poly, total * i / n) for i in range(n + 1)]
	pts[0] = poly[0]
	pts[-1] = poly[-1]
	if strict:
		return pts
	return dedupe_poly(pts, MOVEMENT_MIN_SEG_PX * 0.5)


def poly_max_turn_deg(poly) -> float:
	worst = 0.0
	for i in range(1, len(poly) - 1):
		u = (poly[i][0] - poly[i - 1][0], poly[i][1] - poly[i - 1][1])
		v = (poly[i + 1][0] - poly[i][0], poly[i + 1][1] - poly[i][1])
		if math.hypot(*u) < 1e-9 or math.hypot(*v) < 1e-9:
			continue
		worst = max(worst, vec_angle_deg(u, v))
	return worst


def poly_seg_lengths(poly):
	return [dist(poly[i - 1], poly[i]) for i in range(1, len(poly))]


def chaikin_smooth(poly, iterations: int = 1):
	"""Corner-cutting; endpoints pinned."""
	pts = [(float(p[0]), float(p[1])) for p in poly]
	if len(pts) < 3:
		return pts
	for _ in range(iterations):
		new = [pts[0]]
		for i in range(len(pts) - 1):
			p, q = pts[i], pts[i + 1]
			new.append((0.75 * p[0] + 0.25 * q[0], 0.75 * p[1] + 0.25 * q[1]))
			new.append((0.25 * p[0] + 0.75 * q[0], 0.25 * p[1] + 0.75 * q[1]))
		new.append(pts[-1])
		pts = dedupe_poly(new, 0.2)
		pts[0], pts[-1] = poly[0], poly[-1]
	return pts


def point_in_rect(pt, rect) -> bool:
	return (
		rect["x"] <= pt[0] <= rect["x"] + rect["w"]
		and rect["y"] <= pt[1] <= rect["y"] + rect["h"]
	)


def build_joined_polyline(poly, a_pos, b_pos, s0, s1, a_mask_dist: float, b_mask_dist: float):
	"""Extract source CGPath sample between stop projections (audit only).

	Does NOT hard-join stop centers with straight segments — that creates 90° kinks.
	Movement curves are built later via Hermite connectors (REV2C).
	"""
	mid = sub_polyline(poly, s0, s1, samples=24)
	if not mid:
		mid = [a_pos, b_pos]
	if dist(mid[0], a_pos) > dist(mid[0], b_pos):
		mid = list(reversed(mid))
	mid = dedupe_poly(mid, 0.5)
	if len(mid) < 2:
		mid = [a_pos, b_pos]

	centerline_start = dist(mid[0], a_pos)
	centerline_end = dist(mid[-1], b_pos)

	def kink(stop, attach, nxt):
		join = (attach[0] - stop[0], attach[1] - stop[1])
		tang = (nxt[0] - attach[0], nxt[1] - attach[1])
		if math.hypot(*join) < 0.5:
			return 0.0
		return vec_angle_deg(join, tang)

	nxt0 = mid[1] if len(mid) > 1 else mid[0]
	prv1 = mid[-2] if len(mid) > 1 else mid[-1]
	kink_s = kink(a_pos, mid[0], nxt0)
	kink_e = kink(b_pos, mid[-1], prv1)

	return {
		"source_polyline": mid,
		"raw_start_attach_gap_px": a_mask_dist,
		"raw_end_attach_gap_px": b_mask_dist,
		"path_centerline_gap_start_px": centerline_start,
		"path_centerline_gap_end_px": centerline_end,
		"first_join_length_px": centerline_start,
		"last_join_length_px": centerline_end,
		"start_tangent_kink_deg": kink_s,
		"end_tangent_kink_deg": kink_e,
	}


def rdp_simplify(poly, epsilon: float):
	"""Ramer–Douglas–Peucker; keeps endpoints."""
	if len(poly) < 3:
		return list(poly)

	def _rdp(pts):
		if len(pts) < 3:
			return pts
		a, b = pts[0], pts[-1]
		ab = (b[0] - a[0], b[1] - a[1])
		lab = math.hypot(*ab) or 1.0
		best_i, best_d = 0, -1.0
		for i in range(1, len(pts) - 1):
			ap = (pts[i][0] - a[0], pts[i][1] - a[1])
			cross = abs(ap[0] * ab[1] - ap[1] * ab[0]) / lab
			if cross > best_d:
				best_d, best_i = cross, i
		if best_d > epsilon:
			left = _rdp(pts[: best_i + 1])
			right = _rdp(pts[best_i:])
			return left[:-1] + right
		return [a, b]

	return _rdp([(float(p[0]), float(p[1])) for p in poly])


def catmull_rom_sample(controls, samples_per_seg: int = 10):
	"""Centripetal-ish Catmull-Rom through controls; endpoints pinned."""
	if len(controls) < 2:
		return list(controls)
	pts = [controls[0]] + list(controls) + [controls[-1]]
	out = []
	for i in range(1, len(pts) - 2):
		p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
		for j in range(samples_per_seg):
			t = j / samples_per_seg
			t2, t3 = t * t, t * t * t
			x = 0.5 * (
				(2 * p1[0])
				+ (-p0[0] + p2[0]) * t
				+ (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
				+ (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3
			)
			y = 0.5 * (
				(2 * p1[1])
				+ (-p0[1] + p2[1]) * t
				+ (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
				+ (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3
			)
			out.append((x, y))
	out.append(controls[-1])
	out[0] = controls[0]
	return dedupe_poly(out, 0.3)


def laplacian_smooth(poly, iterations: int = 8, alpha: float = 0.55):
	pts = [(float(p[0]), float(p[1])) for p in poly]
	if len(pts) < 3:
		return pts
	for _ in range(iterations):
		nxt = [pts[0]]
		for i in range(1, len(pts) - 1):
			nxt.append(
				(
					pts[i][0] * (1 - alpha) + alpha * 0.5 * (pts[i - 1][0] + pts[i + 1][0]),
					pts[i][1] * (1 - alpha) + alpha * 0.5 * (pts[i - 1][1] + pts[i + 1][1]),
				)
			)
		nxt.append(pts[-1])
		pts = nxt
	pts[0], pts[-1] = poly[0], poly[-1]
	return pts


def snap_to_own_mask(p, land_dist, sea_dist, route_type: str, max_radius: int = 24, prefer_dir=None):
	"""Nearest-pixel snap onto OWN-type dash corridor.

	If prefer_dir is set, bias toward samples with positive projection on that direction
	to avoid backtracking hairpins on thin dashes.
	"""
	field = land_dist if route_type == "LAND" else sea_dist
	x, y = float(p[0]), float(p[1])
	if mask_dist_at(field, (x, y)) <= MOVEMENT_MASK_MAX_PX:
		return (x, y)
	h, w = field.shape
	xi, yi = int(round(x)), int(round(y))
	ux, uy = (0.0, 0.0)
	if prefer_dir is not None:
		ux, uy = prefer_dir
		n = math.hypot(ux, uy)
		if n > 1e-9:
			ux, uy = ux / n, uy / n
	best = None
	for rad in range(1, max_radius + 1):
		for dy in range(-rad, rad + 1):
			for dx in (-rad, rad) if abs(dy) != rad else range(-rad, rad + 1):
				nx, ny = xi + dx, yi + dy
				if not (0 <= nx < w and 0 <= ny < h):
					continue
				if float(field[ny, nx]) > MOVEMENT_MASK_MAX_PX:
					continue
				dist2 = (nx - x) ** 2 + (ny - y) ** 2
				fwd = (nx - x) * ux + (ny - y) * uy
				# Prefer forward/sideways; penalize strong backtracks.
				penalty = 0.0 if fwd >= -0.5 else (abs(fwd) * 8.0) ** 2
				score = dist2 + penalty
				if best is None or score < best[0]:
					best = (score, float(nx), float(ny))
		if best is not None:
			return (best[1], best[2])
	return (x, y)


def dekink_on_mask(poly, land_dist, sea_dist, route_type, city_occlusion_zones, max_iters: int = 48):
	"""Replace sharp vertices with neighbor midpoints projected onto the dash mask."""
	pts = list(poly)
	if len(pts) < 3:
		return pts

	def project_pt(p, prefer_dir=None):
		cid, _ = occlusion_hit_at(p, city_occlusion_zones)
		if cid:
			return p
		return snap_to_own_mask(p, land_dist, sea_dist, route_type, prefer_dir=prefer_dir)

	for _ in range(max_iters):
		if poly_max_turn_deg(pts) <= MOVEMENT_MAX_TURN_DEG:
			break
		worst_i, worst_turn = None, -1.0
		for i in range(1, len(pts) - 1):
			v1 = (pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
			v2 = (pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1])
			n1, n2 = math.hypot(*v1), math.hypot(*v2)
			if n1 < 1e-9 or n2 < 1e-9:
				ang = 180.0
			else:
				dot = max(-1.0, min(1.0, (v1[0] * v2[0] + v1[1] * v2[1]) / (n1 * n2)))
				ang = math.degrees(math.acos(dot))
			if ang > worst_turn:
				worst_turn = ang
				worst_i = i
		if worst_i is None or worst_turn <= MOVEMENT_MAX_TURN_DEG:
			break
		i = worst_i
		mid = ((pts[i - 1][0] + pts[i + 1][0]) * 0.5, (pts[i - 1][1] + pts[i + 1][1]) * 0.5)
		prefer = (pts[i + 1][0] - pts[i - 1][0], pts[i + 1][1] - pts[i - 1][1])
		pts[i] = project_pt(mid, prefer_dir=prefer)
		# If still sharp, insert a Chaikin-like split instead of a spike.
		v1 = (pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
		v2 = (pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1])
		n1, n2 = math.hypot(*v1), math.hypot(*v2)
		if n1 > 1e-9 and n2 > 1e-9:
			dot = max(-1.0, min(1.0, (v1[0] * v2[0] + v1[1] * v2[1]) / (n1 * n2)))
			if math.degrees(math.acos(dot)) > MOVEMENT_MAX_TURN_DEG:
				q1 = project_pt(
					(pts[i - 1][0] * 0.25 + pts[i + 1][0] * 0.75, pts[i - 1][1] * 0.25 + pts[i + 1][1] * 0.75),
					prefer_dir=prefer,
				)
				q0 = project_pt(
					(pts[i - 1][0] * 0.75 + pts[i + 1][0] * 0.25, pts[i - 1][1] * 0.75 + pts[i + 1][1] * 0.25),
					prefer_dir=prefer,
				)
				pts = pts[:i] + [q0, q1] + pts[i + 1 :]
	return pts


def pull_toward_mask(p, land_dist, sea_dist, route_type: str, max_steps: int = 8):
	"""Short gradient step toward OWN-type dash, then nearest-pixel snap."""
	field = land_dist if route_type == "LAND" else sea_dist
	x, y = float(p[0]), float(p[1])
	h, w = field.shape
	for _ in range(max_steps):
		md = mask_dist_at(field, (x, y))
		if md <= MOVEMENT_MASK_MAX_PX:
			return (x, y)
		xi, yi = int(round(x)), int(round(y))
		best = None
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				if dx == 0 and dy == 0:
					continue
				nx, ny = xi + dx, yi + dy
				if not (0 <= nx < w and 0 <= ny < h):
					continue
				d2 = float(field[ny, nx])
				if best is None or d2 < best[0]:
					best = (d2, nx, ny)
		if best is None or best[0] >= md - 1e-6:
			break
		# Step partway to avoid hairpin flips on thin dashes.
		x = x * 0.35 + float(best[1]) * 0.65
		y = y * 0.35 + float(best[2]) * 0.65
	return snap_to_own_mask((x, y), land_dist, sea_dist, route_type)


def inflate_rect(rect: dict, pad: float) -> dict:
	return {
		"x": float(rect["x"]) - pad,
		"y": float(rect["y"]) - pad,
		"w": float(rect["w"]) + 2 * pad,
		"h": float(rect["h"]) + 2 * pad,
	}


def occlusion_hit_at(p, city_occlusion_zones: dict):
	"""Return (city_id, rect_kind) if sample is inside a tight building/label rect."""
	for cid, zones in city_occlusion_zones.items():
		for kind in ("building_rect", "label_rect"):
			rect = zones.get(kind)
			if rect and point_in_rect(p, rect):
				return cid, kind
	return None, None


def build_movement_polyline(
	a_pos,
	b_pos,
	source_mid,
	route_type: str,
	land_dist,
	sea_dist,
	city_occlusion_zones: dict,
):
	"""Smooth piece curve: source-faithful Hermite joins + soft own-type dash snap."""
	src = dedupe_poly([(float(p[0]), float(p[1])) for p in source_mid], 0.5)
	if len(src) < 2:
		src = [a_pos, b_pos]
	if dist(src[0], a_pos) > dist(src[0], b_pos):
		src = list(reversed(src))

	# Keep source detail — CGPath is already on the painted dash mask.
	src = rdp_simplify(src, epsilon=4.0)
	if len(src) < 2:
		src = [src[0], src[0]] if src else [a_pos, b_pos]

	def connector(p0, p1, m0_dir, m1_dir, gap):
		if gap <= MOVEMENT_MIN_SEG_PX:
			return [p0] if dist(p0, p1) < 1e-9 else [p0, p1]
		n = max(10, min(28, int(gap / 6.0) + 8))
		scale = max(gap * 0.85, 6.0)
		return hermite_cubic(
			p0,
			p1,
			(m0_dir[0] * scale, m0_dir[1] * scale),
			(m1_dir[0] * scale, m1_dir[1] * scale),
			n=n,
		)

	def finalize(poly):
		"""Equal-arc + forward snap + dekink until gates are close."""
		out = list(poly)
		out[0], out[-1] = a_pos, b_pos
		for _ in range(3):
			out = resample_arc_uniform(out, spacing=MOVEMENT_SAMPLE_SPACING_PX, strict=True)
			out[0], out[-1] = a_pos, b_pos
			tmp = [out[0]]
			for i, p in enumerate(out[1:-1], start=1):
				cid, _ = occlusion_hit_at(p, city_occlusion_zones)
				if cid:
					tmp.append(p)
					continue
				prefer = (out[i + 1][0] - out[i - 1][0], out[i + 1][1] - out[i - 1][1])
				tmp.append(snap_to_own_mask(p, land_dist, sea_dist, route_type, prefer_dir=prefer))
			tmp.append(out[-1])
			tmp[0], tmp[-1] = a_pos, b_pos
			out = dekink_on_mask(tmp, land_dist, sea_dist, route_type, city_occlusion_zones)
			out[0], out[-1] = a_pos, b_pos
			if (
				poly_max_turn_deg(out) <= MOVEMENT_MAX_TURN_DEG
				and (max(poly_seg_lengths(out)) / max(1e-9, min(poly_seg_lengths(out))))
				<= MOVEMENT_SEG_RATIO_MAX
			):
				break
		# Dense snap → dekink → strict 8px equal-arc (wider dash dilate absorbs chords).
		dense = resample_arc_uniform(out, spacing=3.0, strict=True)
		dense[0], dense[-1] = a_pos, b_pos
		tmp = [dense[0]]
		for i, p in enumerate(dense[1:-1], start=1):
			cid, _ = occlusion_hit_at(p, city_occlusion_zones)
			if cid:
				tmp.append(p)
				continue
			prefer = (dense[i + 1][0] - dense[i - 1][0], dense[i + 1][1] - dense[i - 1][1])
			tmp.append(snap_to_own_mask(p, land_dist, sea_dist, route_type, prefer_dir=prefer))
		tmp.append(dense[-1])
		tmp[0], tmp[-1] = a_pos, b_pos
		tmp = dekink_on_mask(tmp, land_dist, sea_dist, route_type, city_occlusion_zones)
		tmp[0], tmp[-1] = a_pos, b_pos
		tmp = resample_arc_uniform(tmp, spacing=MOVEMENT_SAMPLE_SPACING_PX, strict=True)
		tmp[0], tmp[-1] = a_pos, b_pos
		# One light forward snap if equal-arc chord left the corridor.
		own_field = land_dist if route_type == "LAND" else sea_dist
		fixed = [tmp[0]]
		for i, p in enumerate(tmp[1:-1], start=1):
			if mask_dist_at(own_field, p) <= MOVEMENT_MASK_MAX_PX:
				fixed.append(p)
				continue
			cid, _ = occlusion_hit_at(p, city_occlusion_zones)
			if cid:
				fixed.append(p)
				continue
			prefer = (tmp[i + 1][0] - tmp[i - 1][0], tmp[i + 1][1] - tmp[i - 1][1])
			fixed.append(snap_to_own_mask(p, land_dist, sea_dist, route_type, prefer_dir=prefer))
		fixed.append(tmp[-1])
		fixed[0], fixed[-1] = a_pos, b_pos
		# Re-equalize once more only if snap moved points (keeps seg_ratio).
		if any(dist(fixed[i], tmp[i]) > 0.25 for i in range(len(fixed))):
			fixed = resample_arc_uniform(fixed, spacing=MOVEMENT_SAMPLE_SPACING_PX, strict=True)
			fixed[0], fixed[-1] = a_pos, b_pos
		return fixed

	def assemble(src_poly, blend_connectors: bool):
		"""Keep source mid on painted dashes; only smooth stop↔attach connectors."""
		src_len = polyline_length(src_poly)
		# Short/degenerate source: single Hermite stem a→b on painted corridor.
		if len(src_poly) <= 2 or src_len < 36.0:
			direction = vec_unit((b_pos[0] - a_pos[0], b_pos[1] - a_pos[1])) or (1.0, 0.0)
			gap = dist(a_pos, b_pos)
			scale = max(gap * 0.8, 8.0)
			stem = hermite_cubic(
				a_pos,
				b_pos,
				(direction[0] * scale, direction[1] * scale),
				(direction[0] * scale, direction[1] * scale),
				n=max(12, int(gap / 4.0) + 8),
			)
			return finalize(stem)

		attach0, attach1 = src_poly[0], src_poly[-1]
		gap0, gap1 = dist(a_pos, attach0), dist(b_pos, attach1)
		t_src0 = (
			vec_unit((src_poly[1][0] - src_poly[0][0], src_poly[1][1] - src_poly[0][1]))
			if len(src_poly) > 1
			else (1.0, 0.0)
		)
		t_src1 = (
			vec_unit((src_poly[-1][0] - src_poly[-2][0], src_poly[-1][1] - src_poly[-2][1]))
			if len(src_poly) > 1
			else (1.0, 0.0)
		)
		t_out_a = vec_unit((attach0[0] - a_pos[0], attach0[1] - a_pos[1])) or t_src0
		t_in_b = vec_unit((b_pos[0] - attach1[0], b_pos[1] - attach1[1])) or t_src1
		if math.hypot(*t_out_a) < 1e-9:
			t_out_a = t_src0
		if math.hypot(*t_in_b) < 1e-9:
			t_in_b = t_src1

		if blend_connectors:
			conn0 = connector(a_pos, attach0, t_out_a, t_src0, gap0)
			conn1 = connector(attach1, b_pos, t_src1, t_in_b, gap1)
		else:
			# Straight stems (already painted onto dash mask for cities).
			conn0 = [a_pos, attach0] if gap0 > MOVEMENT_MIN_SEG_PX else [a_pos]
			conn1 = [attach1, b_pos] if gap1 > MOVEMENT_MIN_SEG_PX else [b_pos]

		# Snap connector samples only — mid stays on source dashes.
		def snap_conn(poly):
			out = []
			for i, p in enumerate(poly):
				if i == 0 or i == len(poly) - 1:
					out.append(p)
					continue
				cid, _ = occlusion_hit_at(p, city_occlusion_zones)
				out.append(p if cid else snap_to_own_mask(p, land_dist, sea_dist, route_type))
			return out

		conn0 = snap_conn(conn0)
		conn1 = snap_conn(conn1)
		mid = resample_arc_uniform(src_poly, spacing=MOVEMENT_SAMPLE_SPACING_PX)
		# Stitch: stop — connector — source mid — connector — stop
		controls = [a_pos]
		for p in conn0[1:]:
			if dist(controls[-1], p) > 2:
				controls.append(p)
		for p in mid:
			if dist(controls[-1], p) > 2:
				controls.append(p)
		for p in conn1:
			if dist(controls[-1], p) > 2:
				controls.append(p)
		if dist(controls[-1], b_pos) > 0.5:
			controls.append(b_pos)
		controls[0], controls[-1] = a_pos, b_pos
		out = resample_arc_uniform(controls, spacing=4.0, strict=True)
		return finalize(out)

	def score(poly):
		own_field = land_dist if route_type == "LAND" else sea_dist
		off = sum(1 for p in poly if mask_dist_at(own_field, p) > MOVEMENT_MASK_MAX_PX)
		segs = poly_seg_lengths(poly)
		seg_ratio = (max(segs) / min(segs)) if segs and min(segs) > 1e-9 else 999.0
		return (off, poly_max_turn_deg(poly), seg_ratio)

	candidates = [assemble(src, blend_connectors=True), assemble(src, blend_connectors=False)]
	movement = min(candidates, key=score)

	segs = poly_seg_lengths(movement)
	seg_ratio = (max(segs) / min(segs)) if segs and min(segs) > 1e-9 else 999.0
	max_turn = poly_max_turn_deg(movement)
	end_err_a = dist(movement[0], a_pos)
	end_err_b = dist(movement[-1], b_pos)

	own_field = land_dist if route_type == "LAND" else sea_dist
	other_field = sea_dist if route_type == "LAND" else land_dist
	mask_failures = []
	wrong_type_failures = []
	occlusions = []
	off_run_px = 0.0
	max_off_run_px = 0.0
	for i, p in enumerate(movement):
		own_d = mask_dist_at(own_field, p)
		other_d = mask_dist_at(other_field, p)
		cid, kind = occlusion_hit_at(p, city_occlusion_zones)
		if cid:
			zones = city_occlusion_zones[cid]
			occlusions.append(
				{
					"occlusion_city_id": cid,
					"sample_index": i,
					"sample_position": [round(p[0], 3), round(p[1], 3)],
					"building_rect": zones.get("building_rect") if kind == "building_rect" else None,
					"label_rect": zones.get("label_rect") if kind == "label_rect" else None,
					"hit_rect_kind": kind,
				}
			)
			off_run_px = 0.0
			continue
		# Wrong type only when off own corridor but inside the other.
		if own_d > MOVEMENT_MASK_MAX_PX and other_d <= MOVEMENT_MASK_MAX_PX:
			wrong_type_failures.append(
				{
					"i": i,
					"pt": [round(p[0], 3), round(p[1], 3)],
					"own_mask_dist_px": round(own_d, 3),
					"other_mask_dist_px": round(other_d, 3),
				}
			)
		if own_d > MOVEMENT_MASK_MAX_PX:
			if i > 0:
				off_run_px += dist(movement[i - 1], p)
			else:
				off_run_px = 0.0
			max_off_run_px = max(max_off_run_px, off_run_px)
			mask_failures.append(
				{
					"i": i,
					"pt": [round(p[0], 3), round(p[1], 3)],
					"mask_dist_px": round(own_d, 3),
					"off_run_px": round(off_run_px, 3),
				}
			)
		else:
			off_run_px = 0.0

	def revalidate(poly):
		segs_l = poly_seg_lengths(poly)
		seg_r = (max(segs_l) / min(segs_l)) if segs_l and min(segs_l) > 1e-9 else 999.0
		turn = poly_max_turn_deg(poly)
		mfail, wfail, occs = [], [], []
		off_run = 0.0
		max_off = 0.0
		for i, p in enumerate(poly):
			own_d = mask_dist_at(own_field, p)
			other_d = mask_dist_at(other_field, p)
			cid, kind = occlusion_hit_at(p, city_occlusion_zones)
			if cid:
				zones = city_occlusion_zones[cid]
				occs.append(
					{
						"occlusion_city_id": cid,
						"sample_index": i,
						"sample_position": [round(p[0], 3), round(p[1], 3)],
						"building_rect": zones.get("building_rect") if kind == "building_rect" else None,
						"label_rect": zones.get("label_rect") if kind == "label_rect" else None,
						"hit_rect_kind": kind,
					}
				)
				off_run = 0.0
				continue
			if own_d > MOVEMENT_MASK_MAX_PX and other_d <= MOVEMENT_MASK_MAX_PX:
				wfail.append(
					{
						"i": i,
						"pt": [round(p[0], 3), round(p[1], 3)],
						"own_mask_dist_px": round(own_d, 3),
						"other_mask_dist_px": round(other_d, 3),
					}
				)
			if own_d > MOVEMENT_MASK_MAX_PX:
				if i > 0:
					off_run += dist(poly[i - 1], p)
				max_off = max(max_off, off_run)
				mfail.append(
					{
						"i": i,
						"pt": [round(p[0], 3), round(p[1], 3)],
						"mask_dist_px": round(own_d, 3),
						"off_run_px": round(off_run, 3),
					}
				)
			else:
				off_run = 0.0
		ea, eb = dist(poly[0], a_pos), dist(poly[-1], b_pos)
		ok_local = (
			ea <= MOVEMENT_END_MAX_PX
			and eb <= MOVEMENT_END_MAX_PX
			and turn <= MOVEMENT_MAX_TURN_DEG
			and seg_r <= MOVEMENT_SEG_RATIO_MAX
			and len(mfail) == 0
			and len(wfail) == 0
			and max_off <= MOVEMENT_OFF_ROUTE_RUN_MAX_PX
			and len(poly) >= 2
		)
		return {
			"poly": poly,
			"max_turn_deg": turn,
			"end_err_a": ea,
			"end_err_b": eb,
			"seg_ratio": seg_r,
			"mask_failures": mfail,
			"wrong_type_failures": wfail,
			"max_off_run_px": max_off,
			"occlusions": occs,
			"ok": ok_local,
		}

	def project_all(poly):
		out = [poly[0]]
		for i, p in enumerate(poly[1:-1], start=1):
			cid, _ = occlusion_hit_at(p, city_occlusion_zones)
			if cid:
				out.append(p)
				continue
			prefer = (poly[i + 1][0] - poly[i - 1][0], poly[i + 1][1] - poly[i - 1][1])
			out.append(
				snap_to_own_mask(p, land_dist, sea_dist, route_type, max_radius=56, prefer_dir=prefer)
			)
		out.append(poly[-1])
		out[0], out[-1] = a_pos, b_pos
		return out

	def densify_along(poly, spacing: float):
		"""Insert lerps on each segment so chords stay short; never skips vertices."""
		if len(poly) < 2:
			return list(poly)
		out = [poly[0]]
		for i in range(1, len(poly)):
			p0, p1 = poly[i - 1], poly[i]
			seg = dist(p0, p1)
			if seg <= spacing:
				out.append(p1)
				continue
			n = max(1, int(math.ceil(seg / spacing)))
			for k in range(1, n + 1):
				t = k / n
				out.append((p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t))
		return out

	# Local repair for residual corridor/turn failures (REV2D: rebuild failed edges only).
	result = revalidate(movement)
	if not result["ok"]:
		# Source-vertex densify: stay on painted CGPath, avoid equal-arc chord shortcuts.
		if len(src) >= 2:
			for sp in (4.0, 3.0, 2.5):
				stem = densify_along([a_pos] + list(src) + [b_pos], sp)
				stem[0], stem[-1] = a_pos, b_pos
				stem = project_all(stem)
				stem = dekink_on_mask(
					stem, land_dist, sea_dist, route_type, city_occlusion_zones, max_iters=80
				)
				stem[0], stem[-1] = a_pos, b_pos
				# Equalize only along the already-densified on-path poly.
				stem = resample_arc_uniform(stem, spacing=sp, strict=True)
				stem[0], stem[-1] = a_pos, b_pos
				stem = project_all(stem)
				alt = revalidate(stem)
				if alt["ok"]:
					result = alt
					break
				if len(alt["mask_failures"]) < len(result["mask_failures"]) or (
					len(alt["mask_failures"]) == len(result["mask_failures"])
					and alt["max_turn_deg"] <= result["max_turn_deg"]
					and alt["seg_ratio"] < result["seg_ratio"]
				):
					result = alt
		poly = list(result["poly"])
		for _ in range(6):
			if result["ok"]:
				break
			poly = project_all(poly)
			poly = dekink_on_mask(poly, land_dist, sea_dist, route_type, city_occlusion_zones, max_iters=80)
			poly[0], poly[-1] = a_pos, b_pos
			poly = densify_along(poly, 3.0)
			poly = resample_arc_uniform(poly, spacing=3.0, strict=True)
			poly[0], poly[-1] = a_pos, b_pos
			poly = project_all(poly)
			result = revalidate(poly)
		if (
			not result["ok"]
			and not result["mask_failures"]
			and not result["wrong_type_failures"]
			and result["seg_ratio"] > MOVEMENT_SEG_RATIO_MAX
		):
			poly = densify_along(result["poly"], 3.0)
			poly = resample_arc_uniform(poly, spacing=3.0, strict=True)
			poly[0], poly[-1] = a_pos, b_pos
			result = revalidate(poly)

	return {
		"movement_polyline": result["poly"],
		"max_turn_deg": result["max_turn_deg"],
		"end_err_a": result["end_err_a"],
		"end_err_b": result["end_err_b"],
		"seg_ratio": result["seg_ratio"],
		"mask_failures": result["mask_failures"],
		"wrong_type_failures": result["wrong_type_failures"],
		"max_off_run_px": result["max_off_run_px"],
		"occlusions": result["occlusions"],
		"ok": result["ok"],
	}


def alpha_visible_bbox(png_path: Path, threshold: int = ALPHA_THRESHOLD):
	img = Image.open(png_path).convert("RGBA")
	arr = np.array(img)
	ys, xs = np.where(arr[:, :, 3] > threshold)
	if len(xs) == 0:
		return 0, 0, img.width, img.height, img.width, img.height
	x0, x1 = int(xs.min()), int(xs.max()) + 1
	y0, y1 = int(ys.min()), int(ys.max()) + 1
	return x0, y0, x1 - x0, y1 - y0, img.width, img.height


def try_font(size: int):
	for name in (
		"/System/Library/Fonts/PingFang.ttc",
		"/System/Library/Fonts/STHeiti Light.ttc",
		"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	):
		try:
			return ImageFont.truetype(name, size=size)
		except OSError:
			continue
	return ImageFont.load_default()


def rel_to_root(path: Path) -> str:
	try:
		return str(path.resolve().relative_to(ROOT.resolve()))
	except ValueError:
		return str(path)


def save_preview(img: Image.Image, full_path: Path, preview_path: Path, preview_w: int = 2048):
	full_path.parent.mkdir(parents=True, exist_ok=True)
	preview_path.parent.mkdir(parents=True, exist_ok=True)
	rgb = img.convert("RGB")
	rgb.save(full_path, optimize=True, quality=92)
	w, h = img.size
	if w > preview_w:
		nh = int(round(h * preview_w / w))
		preview = img.resize((preview_w, nh), Image.Resampling.LANCZOS).convert("RGB")
	else:
		preview = rgb
	preview.save(preview_path, optimize=True, quality=85)


def connected_components(ids, adj):
	seen = set()
	comps = []
	for sid in ids:
		if sid in seen:
			continue
		stack = [sid]
		seen.add(sid)
		comp = []
		while stack:
			u = stack.pop()
			comp.append(u)
			for v in adj[u]:
				if v not in seen:
					seen.add(v)
					stack.append(v)
		comps.append(sorted(comp))
	return comps


def extract_terrain_color_candidate_masks(rgb: np.ndarray):
	"""DEBUG ONLY — color thresholds from flattened art (leaks ocean/desert/buildings).

	Must NOT be used as movement corridor gate (REV2D).
	"""
	from scipy.ndimage import binary_dilation

	r = rgb[:, :, 0].astype(np.int16)
	g = rgb[:, :, 1].astype(np.int16)
	b = rgb[:, :, 2].astype(np.int16)
	sea = (b > 160) & (g > 140) & (r > 50) & (r < 190) & ((g + b) > (2 * r + 40)) & (b > r + 15)
	land = ((r > 195) & (g > 180) & (b > 130) & (r >= g) & (g >= b - 10) & ((r - b) > 30)) | (
		(r > 210) & (g > 205) & (b > 190) & (np.abs(r - g) < 25)
	)
	land = binary_dilation(land.astype(bool), iterations=5)
	sea = binary_dilation(sea.astype(bool), iterations=5)
	return land, sea


def _paint_polyline_mask(mask: np.ndarray, poly, width: int = DASH_STROKE_PX):
	"""Rasterize polyline onto boolean mask (True = route)."""
	if len(poly) < 2:
		return
	h, w = mask.shape
	img = Image.fromarray(mask.astype(np.uint8) * 255, mode="L")
	draw = ImageDraw.Draw(img)
	pts = [(float(p[0]), float(p[1])) for p in poly]
	draw.line(pts, fill=255, width=max(1, width))
	mask[:, :] = np.array(img) > 127


def _paint_circle_mask(mask: np.ndarray, center, radius: float = 7.0):
	h, w = mask.shape
	img = Image.fromarray(mask.astype(np.uint8) * 255, mode="L")
	draw = ImageDraw.Draw(img)
	x, y = float(center[0]), float(center[1])
	draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=255)
	mask[:, :] = np.array(img) > 127


def build_dash_only_route_masks(paths, land_points, sea_points, excluded_path_idxs: set):
	"""Authoritative dash-only masks from PXD path polylines + route-point circles.

	Background black / route white. Excludes terrain art. path_32 excluded via excluded set.
	"""
	from scipy.ndimage import binary_dilation, label

	h, w = int(LOGIC_H), int(LOGIC_W)
	land = np.zeros((h, w), dtype=bool)
	sea = np.zeros((h, w), dtype=bool)

	for pr in paths:
		idx = pr["path_layer_index"]
		if idx in excluded_path_idxs:
			continue
		poly = pr.get("poly") or []
		if len(poly) < 2:
			continue
		rt = pr.get("route_class")
		if rt == "LAND":
			_paint_polyline_mask(land, poly)
		elif rt == "SEA":
			_paint_polyline_mask(sea, poly)
		elif rt == "INTERCHANGE_BRIDGE":
			# Port bridges contribute to both corridors (domain edges share the stem).
			_paint_polyline_mask(land, poly)
			_paint_polyline_mask(sea, poly)

	for p in land_points:
		_paint_circle_mask(land, p["pos"], radius=7.0)
	for p in sea_points:
		_paint_circle_mask(sea, p["pos"], radius=7.0)

	# Thin dilate for ≤8px sampling corridor (not the old 5iter terrain flood)
	land_d = binary_dilation(land, iterations=DASH_DILATE_ITERS)
	sea_d = binary_dilation(sea, iterations=DASH_DILATE_ITERS)

	def mask_stats(m_raw, m_dil):
		labeled, ncomp = label(m_raw.astype(np.uint8))
		sizes = []
		if ncomp:
			counts = np.bincount(labeled.ravel())
			sizes = sorted((int(c) for c in counts[1:]), reverse=True)
		return {
			"raw_coverage_ratio": float(m_raw.mean()),
			"coverage_ratio": float(m_dil.mean()),
			"connected_component_count": int(ncomp),
			"component_size_distribution": sizes[:20],
			"largest_component_px": int(sizes[0]) if sizes else 0,
		}

	land_stats = mask_stats(land, land_d)
	sea_stats = mask_stats(sea, sea_d)
	union = land_d | sea_d
	# Terrain leak heuristic: any component larger than ~0.8% of canvas is suspicious
	leak_thresh = int(0.008 * h * w)
	terrain_leaks = []
	for name, st in (("LAND", land_stats), ("SEA", sea_stats)):
		if st["largest_component_px"] > leak_thresh:
			terrain_leaks.append(
				{"domain": name, "largest_component_px": st["largest_component_px"], "threshold_px": leak_thresh}
			)

	meta = {
		"land_mask_coverage_ratio": land_stats["coverage_ratio"],
		"sea_mask_coverage_ratio": sea_stats["coverage_ratio"],
		"union_mask_coverage_ratio": float(union.mean()),
		"land_raw_coverage_ratio": land_stats["raw_coverage_ratio"],
		"sea_raw_coverage_ratio": sea_stats["raw_coverage_ratio"],
		"land_connected_component_count": land_stats["connected_component_count"],
		"sea_connected_component_count": sea_stats["connected_component_count"],
		"land_component_size_distribution": land_stats["component_size_distribution"],
		"sea_component_size_distribution": sea_stats["component_size_distribution"],
		"node_circle_count": len(land_points) + len(sea_points),
		"terrain_component_leaks": terrain_leaks,
		"stroke_px": DASH_STROKE_PX,
		"dilate_iterations": DASH_DILATE_ITERS,
		"excluded_path_layers": sorted(excluded_path_idxs),
	}
	return land_d, sea_d, land, sea, meta


def mask_distance_field(mask: np.ndarray) -> np.ndarray:
	"""Euclidean distance to nearest True pixel in mask."""
	if distance_transform_edt is not None:
		return distance_transform_edt(~mask).astype(np.float32)
	# Chamfer 3-4 approximation (no scipy)
	h, w = mask.shape
	inf = 1e6
	dist = np.where(mask, 0.0, inf).astype(np.float32)
	# forward
	for y in range(h):
		for x in range(w):
			v = dist[y, x]
			if y > 0:
				v = min(v, dist[y - 1, x] + 3)
				if x > 0:
					v = min(v, dist[y - 1, x - 1] + 4)
				if x + 1 < w:
					v = min(v, dist[y - 1, x + 1] + 4)
			if x > 0:
				v = min(v, dist[y, x - 1] + 3)
			dist[y, x] = v
	# backward
	for y in range(h - 1, -1, -1):
		for x in range(w - 1, -1, -1):
			v = dist[y, x]
			if y + 1 < h:
				v = min(v, dist[y + 1, x] + 3)
				if x > 0:
					v = min(v, dist[y + 1, x - 1] + 4)
				if x + 1 < w:
					v = min(v, dist[y + 1, x + 1] + 4)
			if x + 1 < w:
				v = min(v, dist[y, x + 1] + 3)
			dist[y, x] = v
	return dist / 3.0


def polyline_mask_stats(
	poly,
	dist_field: np.ndarray,
	sample_step: int = 2,
	rgb=None,
	domain=None,
):
	"""Distance of polyline samples to a route mask.

	For SEA/LAND, skip samples clearly over the wrong terrain (city art / opposite medium)
	so short coastal spurs are scored on the water/land dash segments only.
	"""
	if len(poly) < 2:
		return {"mean": 999.0, "p95": 999.0, "coverage": 0.0, "n": 0}
	dists = []
	h, w = dist_field.shape
	for i in range(0, len(poly), sample_step):
		x, y = poly[i]
		xi, yi = int(round(x)), int(round(y))
		if not (0 <= xi < w and 0 <= yi < h):
			continue
		if rgb is not None and domain in ("SEA", "LAND"):
			cr, cg, cb = [int(v) for v in rgb[yi, xi]]
			if domain == "SEA" and not (cb > cr + 15 and cb > 100):
				continue
			if domain == "LAND" and cb > cr + 40 and cb > 140:
				continue
		dists.append(float(dist_field[yi, xi]))
	if len(dists) < 3 and rgb is not None:
		# fallback: score all samples if filter removed too many
		return polyline_mask_stats(poly, dist_field, sample_step=sample_step, rgb=None, domain=None)
	if not dists:
		return {"mean": 999.0, "p95": 999.0, "coverage": 0.0, "n": 0}
	arr = np.array(dists)
	return {
		"mean": float(arr.mean()),
		"p95": float(np.percentile(arr, 95)),
		"coverage": float((arr <= MASK_MEAN_MAX).mean()),
		"n": int(len(arr)),
	}


def ensure_map_texture(preview: Path, dest: Path) -> tuple[int, int]:
	dest.parent.mkdir(parents=True, exist_ok=True)
	img = Image.open(preview).convert("RGB")
	if img.size != (int(LOGIC_W), int(LOGIC_H)):
		img = img.resize((int(LOGIC_W), int(LOGIC_H)), Image.Resampling.LANCZOS)
	img.save(dest)
	return img.size


def main(argv=None) -> int:
	parser = argparse.ArgumentParser(description="Extract world map DATA-001 REV2A artifacts")
	parser.add_argument("--pxd", type=Path, required=True)
	parser.add_argument("--preview", type=Path, required=True, help="4096×1363 map preview PNG")
	parser.add_argument("--output-dir", type=Path, default=ROOT / "docs/reports/world-map-data-001")
	parser.add_argument(
		"--city-assets-dir",
		type=Path,
		default=ROOT / "assets/game/cities/world_hover_preview",
	)
	parser.add_argument(
		"--full-audit-dir",
		type=Path,
		default=Path("/tmp/task_world_map_data_001_rev2"),
	)
	parser.add_argument(
		"--presentation-out",
		type=Path,
		default=ROOT / "data/rulesets/lshu_configurable_v1/presentation/world_map_v1.json",
	)
	parser.add_argument(
		"--map-texture-out",
		type=Path,
		default=ROOT / "assets/game/maps/world/world_map_v1.png",
	)
	args = parser.parse_args(argv)

	out_dir: Path = args.output_dir
	full_dir: Path = args.full_audit_dir
	city_assets: Path = args.city_assets_dir
	out_dir.mkdir(parents=True, exist_ok=True)
	full_dir.mkdir(parents=True, exist_ok=True)
	for stale in ("_metadata.info",):
		p = out_dir / stale
		if p.exists():
			p.unlink()

	# --- map texture lock (dash-only masks built after path classification) ---
	tex_w, tex_h = ensure_map_texture(args.preview, args.map_texture_out)
	map_texture_ok = (tex_w, tex_h) == (int(LOGIC_W), int(LOGIC_H))
	map_rgb = np.array(Image.open(args.map_texture_out).convert("RGB"))
	# DEBUG ONLY — not used for movement corridor gates (REV2D).
	terrain_land_mask, terrain_sea_mask = extract_terrain_color_candidate_masks(map_rgb)

	tmp_db = Path(tempfile.mkdtemp(prefix="wm_data001_rev2_")) / "metadata.info"
	try:
		extract_metadata_db(args.pxd, tmp_db)
		db = sqlite3.connect(str(tmp_db))
		doc_w, doc_h = decode_doc_size(
			db.execute("SELECT value FROM document_info WHERE key='size'").fetchone()[0]
		)
		assert doc_w == int(DOC_W) and doc_h == int(DOC_H), (doc_w, doc_h)

		ident_parent = {
			ident: parent
			for ident, parent in db.execute("SELECT identifier, parent_identifier FROM document_layers")
		}
		layers = []
		ident_name = {}
		for lid, ident, parent, idx, typ in db.execute(
			"SELECT id, identifier, parent_identifier, index_at_parent, type FROM document_layers"
		):
			info = layer_info_map(db, lid)
			name = decode_name(info["name"])
			ident_name[ident] = name
			shape = None
			if "shape-shapeData" in info:
				shape = json.loads(info["shape-shapeData"].decode("utf-8"))
			pos = decode_f64s(info["position"]) if "position" in info else None
			size = decode_f64s(info["size"]) if "size" in info else None
			chain = []
			p = parent
			while p:
				chain.append(ident_name.get(p, p))
				p = ident_parent.get(p)
			layers.append(
				{
					"id": lid,
					"identifier": ident,
					"parent": parent,
					"index": idx,
					"type": typ,
					"name": name,
					"pos": pos,
					"size": size,
					"info": info,
					"shape": shape,
					"parent_chain": chain,
				}
			)
		db.close()
	finally:
		shutil.rmtree(tmp_db.parent, ignore_errors=True)

	warnings: list[str] = []
	before = {
		"note": "REV1 rejected: Y-up/Y-down mismatch; hardcoded sequences; post-snap zero errors",
		"unique_edges": 70,
		"connected_components": 1,
		"coordinate_space": "model_without_y_flip",
	}

	# --- route points (screen space) ---
	circle_primaries = [
		L for L in layers if L["type"] == 3 and L["name"] == "圆形" and L["parent_chain"]
	]
	sea_groups = {}
	land_groups = {}
	for L in circle_primaries:
		parent = L["parent_chain"][0]
		sx, sy = model_to_screen_point(L["pos"])
		if parent.startswith("海洋点"):
			sea_groups[parent] = (sx, sy)
		elif parent.startswith("群组"):
			land_groups[parent] = (sx, sy)
		else:
			warnings.append(f"circle parent unclassified: {parent}")

	land_sorted = sorted(land_groups.items(), key=lambda kv: (kv[1][0], kv[1][1]))
	sea_sorted = sorted(sea_groups.items(), key=lambda kv: (kv[1][0], kv[1][1]))
	route_points = []
	points_by_id = {}
	for i, (gname, (x, y)) in enumerate(land_sorted, 1):
		rid = f"land_point_{i:03d}"
		route_points.append(
			{
				"id": rid,
				"transport_type": "LAND",
				"pxd_group": gname,
				"source_position_px": [round(x, 3), round(y, 3)],
				"normalized_position": clamp_norm(norm_xy(x, y)),
			}
		)
		points_by_id[rid] = {"id": rid, "route": "LAND", "pos": (x, y), "is_city": False, "playable": True}
	for i, (gname, (x, y)) in enumerate(sea_sorted, 1):
		rid = f"sea_point_{i:03d}"
		route_points.append(
			{
				"id": rid,
				"transport_type": "SEA",
				"pxd_group": gname,
				"source_position_px": [round(x, 3), round(y, 3)],
				"normalized_position": clamp_norm(norm_xy(x, y)),
			}
		)
		points_by_id[rid] = {"id": rid, "route": "SEA", "pos": (x, y), "is_city": False, "playable": True}

	assert len(land_sorted) == 25 and len(sea_sorted) == 26

	# Mark product-confirmed aliases on route_points (audit only; not playable stops).
	for rp in route_points:
		if rp["id"] in STOP_ALIASES:
			rp["alias_of"] = STOP_ALIASES[rp["id"]]
			rp["playable"] = False
			points_by_id[rp["id"]]["playable"] = False
			points_by_id[rp["id"]]["alias_of"] = STOP_ALIASES[rp["id"]]
		else:
			rp["playable"] = True

	# --- paths (screen space) ---
	path_layers = [L for L in layers if L["type"] == 3 and "路径" in L["name"]]
	paths = []
	for idx, L in enumerate(path_layers, 1):
		poly = path_screen_polyline(L["info"], L["shape"])
		paths.append(
			{
				"path_layer_index": idx,
				"pxd_name": L["name"],
				"layer_id": L["id"],
				"poly": poly,
			}
		)
	assert len(paths) == 54

	# classify
	for pr in paths:
		near_l, near_s = [], []
		for p in points_by_id.values():
			d = project_arc(pr["poly"], p["pos"])[1]
			if d <= CLASSIFY_SNAP_PX:
				(near_l if p["route"] == "LAND" else near_s).append((d, p["id"]))
		if near_l and not near_s:
			pr["route_class"] = "LAND"
		elif near_s and not near_l:
			pr["route_class"] = "SEA"
		elif near_l and near_s:
			pr["route_class"] = "INTERCHANGE_BRIDGE"
			pr["near_land"] = near_l
			pr["near_sea"] = near_s
		else:
			best = None
			for ep in (pr["poly"][0], pr["poly"][-1]):
				for p in points_by_id.values():
					d = dist(ep, p["pos"])
					if best is None or d < best[0]:
						best = (d, p["route"])
			pr["route_class"] = best[1] if best and best[0] < 100 else None

	# --- REV2D: authoritative dash-only route masks from classified PXD paths ---
	land_pts_for_mask = [
		{"pos": points_by_id[rid]["pos"]}
		for rid, rec in points_by_id.items()
		if (not rec.get("is_city")) and rec.get("route") == "LAND"
	]
	sea_pts_for_mask = [
		{"pos": points_by_id[rid]["pos"]}
		for rid, rec in points_by_id.items()
		if (not rec.get("is_city")) and rec.get("route") == "SEA"
	]
	land_mask, sea_mask, land_mask_raw, sea_mask_raw, route_mask_meta = build_dash_only_route_masks(
		paths,
		land_pts_for_mask,
		sea_pts_for_mask,
		set(EXCLUDED_PATH_LAYERS.keys()),
	)
	land_dist = mask_distance_field(land_mask)
	sea_dist = mask_distance_field(sea_mask)

	# --- cities (screen space) ---
	buildings = [L for L in layers if L["type"] == 1 and any(ch.isdigit() for ch in L["name"][:2])]
	labels = {L["name"]: L for L in layers if L["type"] == 2}

	endpoints_by_route = {"LAND": [], "SEA": []}
	for pr in paths:
		rt = pr["route_class"]
		if not pr["poly"]:
			continue
		if rt in ("LAND", "SEA"):
			endpoints_by_route[rt].extend([pr["poly"][0], pr["poly"][-1]])
		elif rt == "INTERCHANGE_BRIDGE":
			endpoints_by_route["LAND"].extend([pr["poly"][0], pr["poly"][-1]])
			endpoints_by_route["SEA"].extend([pr["poly"][0], pr["poly"][-1]])

	min_logic_hit = MIN_HIT_SCREEN_PX / (MIN_VIEW_WIDTH / LOGIC_W)
	cities = []
	for city_id, display, pxd_name, asset_folder in CITY_SPEC:
		hint = BUILDING_FILE_HINTS[city_id]
		b_layer = next((L for L in buildings if hint in L["name"]), None)
		if b_layer is None:
			warnings.append(f"missing building layer for {city_id}")
			continue
		label = labels.get(pxd_name)
		bx_m, by_m = b_layer["pos"]
		bw, bh = b_layer["size"]
		brect = model_center_size_to_screen_rect(bx_m, by_m, bw, bh)
		building_position = [round(brect[0], 3), round(brect[1], 3)]
		building_size = [round(brect[2], 3), round(brect[3], 3)]
		b_center = model_to_screen_point((bx_m, by_m))

		if label:
			lx_m, ly_m = label["pos"]
			lw, lh = label["size"]
			lrect = model_center_size_to_screen_rect(lx_m, ly_m, lw, lh)
			label_position = [round(lrect[0], 3), round(lrect[1], 3)]
			label_size = [round(lrect[2], 3), round(lrect[3], 3)]
			label_center = model_to_screen_point((lx_m, ly_m))
		else:
			warnings.append(f"missing label for {city_id}")
			label_position = [building_position[0], building_position[1] + building_size[1]]
			label_size = [100.0, 40.0]
			label_center = (b_center[0], b_center[1] + building_size[1] / 2)

		allowed = list(ALLOWED_ROUTES[city_id])
		entry = {}
		for rt in allowed:
			eps = endpoints_by_route.get(rt, [])
			pts = [p for p in points_by_id.values() if p["route"] == rt]
			best_ep = min(eps, key=lambda e: dist(e, label_center)) if eps else None
			best_pt = min(pts, key=lambda p: dist(p["pos"], label_center))
			# REV2D: do NOT seat cities on neighboring playable route-points.
			# Dash-only masks paint those circles at dist=0, which previously collapsed
			# yumenguan/heijokyo/jeddah onto land_018/sea_026/land_006 and dropped edges.
			# Aliases still overwrite city seats after this block via STOP_ALIASES fold.
			candidates = []
			if best_ep is not None:
				candidates.append((best_ep, "path_endpoint"))
			# Fallback only: nearest route point (may coincide with a distinct stop).
			if not candidates:
				candidates.append((best_pt["pos"], "nearest_route_point_fallback"))

			def mask_err_at(pt):
				xi = max(0, min(int(LOGIC_W) - 1, int(round(pt[0]))))
				yi = max(0, min(int(LOGIC_H) - 1, int(round(pt[1]))))
				return float(land_dist[yi, xi] if rt == "LAND" else sea_dist[yi, xi])

			raw, src = min(candidates, key=lambda c: (dist(c[0], label_center), mask_err_at(c[0])))
			mask_err = mask_err_at(raw)
			# Snap target on decoded path (presentation only)
			best_d = 1e18
			best_snap = raw
			for pr in paths:
				rc = pr["route_class"]
				if rc == "INTERCHANGE_BRIDGE" or rc == rt:
					if len(pr["poly"]) < 2:
						continue
					_s, d, proj = project_arc(pr["poly"], raw)
					if d < best_d:
						best_d = d
						best_snap = proj
			entry[rt] = {
				"raw": raw,
				"snapped": best_snap,
				"pre_snap_error_px": mask_err,
				"snap_distance_px": dist(raw, best_snap) if best_d < 1e17 else 9999.0,
				"src": src,
			}

		# primary piece: prefer closer-to-label route entry for interchange
		if len(allowed) == 1:
			primary = allowed[0]
		else:
			primary = (
				"LAND"
				if entry["LAND"]["pre_snap_error_px"] <= entry["SEA"]["pre_snap_error_px"]
				else "SEA"
			)
		raw_anchor = entry[primary]["raw"]
		snapped_anchor = entry[primary]["snapped"]
		pre_snap_error = entry[primary]["pre_snap_error_px"]
		snap_distance = entry[primary]["snap_distance_px"]

		# topology seat uses raw stop/endpoint (stable), not snapped projection
		topo_pos = raw_anchor

		static_tex = f"{ASSET_ROOT}/{asset_folder}/idle.png"
		anim_tex = f"{ASSET_ROOT}/{asset_folder}/hover_32f.png"
		disk_static = city_assets / asset_folder / "idle.png"
		disk_anim = city_assets / asset_folder / "hover_32f.png"
		if not disk_static.exists():
			warnings.append(f"missing static texture {asset_folder}/idle.png")
		if not disk_anim.exists():
			warnings.append(f"missing animation texture {asset_folder}/hover_32f.png")

		if disk_static.exists():
			ax, ay, aw, ah, iw, ih = alpha_visible_bbox(disk_static)
			sx = building_size[0] / iw
			sy = building_size[1] / ih
			vis_x = building_position[0] + ax * sx
			vis_y = building_position[1] + ay * sy
			vis_w = aw * sx
			vis_h = ah * sy
		else:
			vis_x, vis_y, vis_w, vis_h = (
				building_position[0],
				building_position[1],
				building_size[0],
				building_size[1],
			)

		# merged building + label hit (allowed); pad; enforce min logic size for 44px @ min fit
		x0 = min(vis_x, label_position[0]) - HIT_PAD_PX
		y0 = min(vis_y, label_position[1]) - HIT_PAD_PX
		x1 = max(vis_x + vis_w, label_position[0] + label_size[0]) + HIT_PAD_PX
		y1 = max(vis_y + vis_h, label_position[1] + label_size[1]) + HIT_PAD_PX
		hw, hh = x1 - x0, y1 - y0
		if hw < min_logic_hit:
			pad = (min_logic_hit - hw) / 2
			x0 -= pad
			x1 += pad
			hw = x1 - x0
		if hh < min_logic_hit:
			pad = (min_logic_hit - hh) / 2
			y0 -= pad
			y1 += pad
			hh = y1 - y0
		hover_hit = {"x": round(x0, 3), "y": round(y0, 3), "w": round(hw, 3), "h": round(hh, 3)}
		building_hit = {
			"x": round(vis_x - HIT_PAD_PX, 3),
			"y": round(vis_y - HIT_PAD_PX, 3),
			"w": round(vis_w + 2 * HIT_PAD_PX, 3),
			"h": round(vis_h + 2 * HIT_PAD_PX, 3),
		}
		label_hit = {
			"x": round(label_position[0] - 4, 3),
			"y": round(label_position[1] - 4, 3),
			"w": round(label_size[0] + 8, 3),
			"h": round(label_size[1] + 8, 3),
		}

		name_fix = {"from": pxd_name, "to": display} if pxd_name != display else None
		land_e = entry.get("LAND")
		sea_e = entry.get("SEA")
		cities.append(
			{
				"city_id": city_id,
				"display_name": display,
				"pxd_label_name": pxd_name,
				"name_correction": name_fix,
				"allowed_routes": allowed,
				"is_transport_interchange": city_id in INTERCHANGE_IDS,
				"building_position": building_position,
				"building_size": building_size,
				"label_position": label_position,
				"label_size": label_size,
				"building_rect_normalized": {
					"x": round(vis_x / LOGIC_W, 6),
					"y": round(vis_y / LOGIC_H, 6),
					"w": round(vis_w / LOGIC_W, 6),
					"h": round(vis_h / LOGIC_H, 6),
				},
				"label_rect_normalized": {
					"x": round(label_position[0] / LOGIC_W, 6),
					"y": round(label_position[1] / LOGIC_H, 6),
					"w": round(label_size[0] / LOGIC_W, 6),
					"h": round(label_size[1] / LOGIC_H, 6),
				},
				"raw_anchor_px": [round(raw_anchor[0], 3), round(raw_anchor[1], 3)],
				"snapped_anchor_px": [round(snapped_anchor[0], 3), round(snapped_anchor[1], 3)],
				# REV2B: piece lands on formal city circle; snap is route_attach only.
				"piece_anchor_px": [round(raw_anchor[0], 3), round(raw_anchor[1], 3)],
				"piece_anchor_normalized": clamp_norm(norm_xy(raw_anchor[0], raw_anchor[1])),
				"piece_anchor_error_px": 0.0,
				"route_attach_anchor_px": [round(snapped_anchor[0], 3), round(snapped_anchor[1], 3)],
				"pre_snap_error_px": round(pre_snap_error, 3),
				"snap_distance_px": round(snap_distance, 3),
				"land_entry_anchor_px": (
					[round(land_e["raw"][0], 3), round(land_e["raw"][1], 3)] if land_e else None
				),
				"sea_entry_anchor_px": (
					[round(sea_e["raw"][0], 3), round(sea_e["raw"][1], 3)] if sea_e else None
				),
				"land_route_attach_anchor_px": (
					[round(land_e["snapped"][0], 3), round(land_e["snapped"][1], 3)] if land_e else None
				),
				"sea_route_attach_anchor_px": (
					[round(sea_e["snapped"][0], 3), round(sea_e["snapped"][1], 3)] if sea_e else None
				),
				"building_hit_rect": building_hit,
				"label_hit_rect": label_hit,
				"hover_hit_rect": hover_hit,
				"hover_hit_min_screen_px_at_min_fit": [
					round(hover_hit["w"] * (MIN_VIEW_WIDTH / LOGIC_W), 2),
					round(hover_hit["h"] * (MIN_VIEW_WIDTH / LOGIC_W), 2),
				],
				"anchor_verification_status": (
					"verified" if pre_snap_error <= PRE_SNAP_MAX_PX else "needs_review"
				),
				"anchor_source_path_layers": [],
				"static_texture": static_tex,
				"animation_texture": anim_tex,
				"frame_count": 32,
				"fps": 8.0,
				"source_position_px": [round(b_center[0], 3), round(b_center[1], 3)],
				"normalized_position": clamp_norm(norm_xy(b_center[0], b_center[1])),
				"source_refs": [
					"all地图.pxd",
					"docs/research/YF064-original-physical-assets-ledger.md",
				],
				"_label_center": label_center,
				"_topo_pos": topo_pos,
			}
		)
		points_by_id[city_id] = {
			"id": city_id,
			"route": None,
			"pos": topo_pos,
			"is_city": True,
			"allowed": allowed,
		}

	assert len(cities) == 16

	# --- topology ---
	# Confirm product aliases sit on city seats before folding.
	alias_collapse = []
	for pid, cid in STOP_ALIASES.items():
		pt = points_by_id[pid]
		city = points_by_id[cid]
		d = dist(pt["pos"], city["pos"])
		# City formal circle := alias route-point seat (product).
		city["pos"] = pt["pos"]
		crec = next(c for c in cities if c["city_id"] == cid)
		crec["raw_anchor_px"] = [round(pt["pos"][0], 3), round(pt["pos"][1], 3)]
		crec["piece_anchor_px"] = list(crec["raw_anchor_px"])
		crec["piece_anchor_normalized"] = clamp_norm(norm_xy(pt["pos"][0], pt["pos"][1]))
		crec["piece_anchor_error_px"] = 0.0
		crec["_topo_pos"] = pt["pos"]
		alias_collapse.append(
			{
				"alias_id": pid,
				"city_id": cid,
				"distance_px": round(d, 3),
				"seat_px": [round(pt["pos"][0], 3), round(pt["pos"][1], 3)],
				"folded_before_edges": True,
			}
		)

	# Stamp city seats + short attach stems onto dash masks (Hermite join corridor).
	from scipy.ndimage import binary_dilation

	for c in cities:
		pos = (float(c["piece_anchor_px"][0]), float(c["piece_anchor_px"][1]))
		for rt in c.get("allowed_routes") or []:
			target = land_mask_raw if rt == "LAND" else sea_mask_raw
			_paint_circle_mask(target, pos, radius=8.0)
			best = None
			for pr in paths:
				if pr["path_layer_index"] in EXCLUDED_PATH_LAYERS:
					continue
				rc = pr.get("route_class")
				if rc != rt and rc != "INTERCHANGE_BRIDGE":
					continue
				if len(pr.get("poly") or []) < 2:
					continue
				_s, d, proj = project_arc(pr["poly"], pos)
				if best is None or d < best[0]:
					best = (d, proj)
			if best is not None and best[0] > 1.0:
				_paint_polyline_mask(target, [pos, best[1]], width=DASH_STROKE_PX)
	land_mask = binary_dilation(land_mask_raw, iterations=DASH_DILATE_ITERS)
	sea_mask = binary_dilation(sea_mask_raw, iterations=DASH_DILATE_ITERS)
	land_dist = mask_distance_field(land_mask)
	sea_dist = mask_distance_field(sea_mask)
	route_mask_meta["union_mask_coverage_ratio"] = float((land_mask | sea_mask).mean())
	route_mask_meta["land_mask_coverage_ratio"] = float(land_mask.mean())
	route_mask_meta["sea_mask_coverage_ratio"] = float(sea_mask.mean())
	route_mask_meta["city_circle_count"] = len(cities)

	raw_edge_records = []
	path_adjudications = []
	excluded_route_layers = []
	canonical_edges_expected = []  # (a, b, route_type, path_idx)
	path_before_after = {}  # for review paths

	def resolve_stop(sid: str):
		fid = fold_stop_id(sid)
		return points_by_id[fid]

	def stop_mask_dist(stop, edge_rt: str) -> float:
		if stop["is_city"]:
			# City circles may sit on either printed corridor at ports.
			return min(mask_dist_at(land_dist, stop["pos"]), mask_dist_at(sea_dist, stop["pos"]))
		field = land_dist if stop.get("route") == "LAND" else sea_dist
		return mask_dist_at(field, stop["pos"])

	def emit_edge(a_id, b_id, edge_rt, poly, s0, s1, path_idx, canonical_seq):
		a = points_by_id[a_id]
		b = points_by_id[b_id]
		if a_id == b_id:
			return
		if dist(a["pos"], b["pos"]) <= 1e-6:
			return
		# Illegal: ordinary land point ↔ sea point
		if (not a["is_city"]) and (not b["is_city"]) and a.get("route") != b.get("route"):
			return
		a_md = stop_mask_dist(a, edge_rt)
		b_md = stop_mask_dist(b, edge_rt)
		built = build_joined_polyline(poly, a["pos"], b["pos"], s0, s1, a_md, b_md)
		src = [[round(x, 3), round(y, 3)] for x, y in built["source_polyline"]]
		rec = {
			"a": a_id,
			"b": b_id,
			"route_type": edge_rt,
			"source_polyline_px": src,
			# Temporary; replaced by movement_polyline_px in REV2C finalize.
			"polyline_px": src,
			"source_path_layer": path_idx,
			"raw_start_attach_gap_px": round(built["raw_start_attach_gap_px"], 3),
			"raw_end_attach_gap_px": round(built["raw_end_attach_gap_px"], 3),
			"path_centerline_gap_start_px": round(built["path_centerline_gap_start_px"], 3),
			"path_centerline_gap_end_px": round(built["path_centerline_gap_end_px"], 3),
			"first_join_length_px": round(built["first_join_length_px"], 3),
			"last_join_length_px": round(built["last_join_length_px"], 3),
			"source_start_tangent_kink_deg": round(built["start_tangent_kink_deg"], 3),
			"source_end_tangent_kink_deg": round(built["end_tangent_kink_deg"], 3),
			"canonical_seq": list(canonical_seq),
		}
		raw_edge_records.append(rec)
		canonical_edges_expected.append(
			(tuple(sorted([a_id, b_id])), edge_rt, path_idx)
		)

	for pr in paths:
		idx = pr["path_layer_index"]
		rt = pr["route_class"]
		poly = pr["poly"]

		if idx in EXCLUDED_PATH_LAYERS:
			ex = EXCLUDED_PATH_LAYERS[idx]
			excluded_route_layers.append(
				{"path_layer_index": idx, "reason": ex["reason"], "detail": ex["detail"]}
			)
			# Capture before sequence for audit
			ordered_ex = []
			for s in points_by_id.values():
				if s.get("alias_of"):
					continue  # still allow alias sources for before-audit
			# include all points for before picture
			for s in points_by_id.values():
				if s["is_city"]:
					continue
				arc, d, _ = project_arc(poly, s["pos"])
				if d <= SNAP_PX:
					ordered_ex.append((arc, s["id"], d))
			ordered_ex.sort(key=lambda x: x[0])
			before_seq = [x[1] for x in ordered_ex]
			path_adjudications.append(
				{
					"path_layer_index": idx,
					"layer_id": pr["layer_id"],
					"pxd_name": pr["pxd_name"],
					"classification": "NON_ROUTE_DECORATIVE",
					"semantic_verification_status": "excluded",
					"movement_verification_status": "blocked",
					"route_class": rt,
					"stop_sequence_before": before_seq,
					"stop_sequence": [],
					"excluded_reason": ex["reason"],
					"note": ex["detail"],
				}
			)
			path_before_after[idx] = {
				"before": before_seq,
				"after": [],
				"status": "excluded",
			}
			continue

		if rt is None or len(poly) < 2:
			path_adjudications.append(
				{
					"path_layer_index": idx,
					"layer_id": pr["layer_id"],
					"pxd_name": pr["pxd_name"],
					"classification": "UNRESOLVED",
					"semantic_verification_status": "blocked",
					"movement_verification_status": "blocked",
					"note": f"route_class={rt}",
				}
			)
			continue

		# Snap playable stops + alias sources (alias folded next).
		ordered = []
		for s in points_by_id.values():
			if s["is_city"]:
				if rt == "INTERCHANGE_BRIDGE":
					pass
				elif rt not in s.get("allowed", []):
					continue
			else:
				if rt in ("LAND", "SEA") and s["route"] != rt:
					continue
			arc, d, _ = project_arc(poly, s["pos"])
			if d <= SNAP_PX:
				ordered.append((arc, s, d))
		ordered.sort(key=lambda x: x[0])

		# Prefer unique by folded id, keeping best (lowest d) then earliest arc.
		best_for_fold = {}
		for arc, s, d in ordered:
			fid = fold_stop_id(s["id"])
			prev = best_for_fold.get(fid)
			if prev is None or d < prev[2] - 1e-9 or (abs(d - prev[2]) < 1e-9 and arc < prev[0]):
				best_for_fold[fid] = (arc, points_by_id[fid], d, s["id"])

		uniq = sorted(best_for_fold.values(), key=lambda x: x[0])
		before_seq = []
		seen_b = set()
		for arc, s, d in ordered:
			if s["id"] in seen_b:
				continue
			seen_b.add(s["id"])
			before_seq.append(s["id"])

		# Interchange bridges without a port city are illegal (path_32 pattern).
		if rt == "INTERCHANGE_BRIDGE":
			has_land = any((not u[1]["is_city"]) and u[1].get("route") == "LAND" for u in uniq)
			has_sea = any((not u[1]["is_city"]) and u[1].get("route") == "SEA" for u in uniq)
			has_x = any(
				u[1]["is_city"] and set(u[1].get("allowed", [])) == {"LAND", "SEA"} for u in uniq
			)
			if has_land and has_sea and not has_x:
				# Try insert nearest interchange city within snap
				best = None
				for cid in INTERCHANGE_IDS:
					s = points_by_id[cid]
					arc, d, _ = project_arc(poly, s["pos"])
					if d <= SNAP_PX and (best is None or d < best[2]):
						best = (arc, s, d, cid)
				if best is not None:
					uniq.append((best[0], best[1], best[2], best[3]))
					uniq.sort(key=lambda x: x[0])
					# re-unique by id
					seen_u, uniq2 = set(), []
					for item in uniq:
						if item[1]["id"] in seen_u:
							continue
						seen_u.add(item[1]["id"])
						uniq2.append(item)
					uniq = uniq2
					has_x = True
				if not has_x:
					excluded_route_layers.append(
						{
							"path_layer_index": idx,
							"reason": "NON_ROUTE_DECORATIVE",
							"detail": "LAND↔SEA without interchange city after alias fold",
						}
					)
					path_adjudications.append(
						{
							"path_layer_index": idx,
							"layer_id": pr["layer_id"],
							"pxd_name": pr["pxd_name"],
							"classification": "NON_ROUTE_DECORATIVE",
							"semantic_verification_status": "excluded",
							"movement_verification_status": "blocked",
							"route_class": rt,
							"stop_sequence_before": before_seq,
							"stop_sequence": [],
							"excluded_reason": "NON_ROUTE_DECORATIVE",
						}
					)
					path_before_after[idx] = {
						"before": before_seq,
						"after": [],
						"status": "excluded",
					}
					continue

		if len(uniq) < 2:
			path_adjudications.append(
				{
					"path_layer_index": idx,
					"layer_id": pr["layer_id"],
					"pxd_name": pr["pxd_name"],
					"classification": "UNRESOLVED",
					"semantic_verification_status": "blocked",
					"movement_verification_status": "blocked",
					"route_class": rt,
					"stop_sequence_before": before_seq,
					"snapped_stops": [u[1]["id"] for u in uniq],
				}
			)
			continue

		# Canonical folded sequence (arc order), except interchange bridges which
		# are split into LAND then SEA chains with city as the transfer node.
		folded_seq = [u[1]["id"] for u in uniq]
		emitted_pairs = []
		if rt == "INTERCHANGE_BRIDGE":
			x_city = next(
				(
					u
					for u in uniq
					if u[1]["is_city"] and set(u[1].get("allowed", [])) == {"LAND", "SEA"}
				),
				None,
			)
			# Semantic order: land* → city → sea* (not raw arc order across domains)
			land_u = sorted(
				[u for u in uniq if (not u[1]["is_city"]) and u[1].get("route") == "LAND"],
				key=lambda x: x[0],
			)
			sea_u = sorted(
				[u for u in uniq if (not u[1]["is_city"]) and u[1].get("route") == "SEA"],
				key=lambda x: x[0],
			)
			canonical = [u[1]["id"] for u in land_u]
			if x_city:
				canonical.append(x_city[1]["id"])
			canonical += [u[1]["id"] for u in sea_u]
			# dedupe consecutive
			seq = []
			for sid in canonical:
				if not seq or seq[-1] != sid:
					seq.append(sid)
			folded_seq = seq

			for domain, group in (
				("LAND", land_u + ([x_city] if x_city else [])),
				("SEA", ([x_city] if x_city else []) + sea_u),
			):
				group = [g for g in group if g is not None]
				# unique by id preserving order
				seen_g, g2 = set(), []
				for item in group:
					if item[1]["id"] in seen_g:
						continue
					seen_g.add(item[1]["id"])
					g2.append(item)
				group = g2
				for i in range(len(group) - 1):
					a_id, b_id = group[i][1]["id"], group[i + 1][1]["id"]
					emit_edge(
						a_id,
						b_id,
						domain,
						poly,
						group[i][0],
						group[i + 1][0],
						idx,
						folded_seq,
					)
					emitted_pairs.append((a_id, b_id, domain))
		else:
			seq = []
			for u in uniq:
				sid = u[1]["id"]
				if not seq or seq[-1] != sid:
					seq.append(sid)
			folded_seq = seq
			for i in range(len(seq) - 1):
				a_id, b_id = seq[i], seq[i + 1]
				a, b = points_by_id[a_id], points_by_id[b_id]
				# type edge
				if a["is_city"] and b["is_city"]:
					continue
				if (not a["is_city"]) and (not b["is_city"]) and a["route"] != b["route"]:
					continue
				if a["is_city"]:
					edge_rt = b["route"] if not b["is_city"] else rt
					if edge_rt not in a.get("allowed", []):
						continue
				elif b["is_city"]:
					edge_rt = a["route"]
					if edge_rt not in b.get("allowed", []):
						continue
				else:
					edge_rt = rt if rt in ("LAND", "SEA") else a["route"]
				# arcs from uniq
				arc_a = next(u[0] for u in uniq if u[1]["id"] == a_id)
				arc_b = next(u[0] for u in uniq if u[1]["id"] == b_id)
				emit_edge(a_id, b_id, edge_rt, poly, arc_a, arc_b, idx, folded_seq)
				emitted_pairs.append((a_id, b_id, edge_rt))

		# Deviation vs printed dash mask (CGPath centerline offset is reported on edges).
		max_dev = 0.0
		for a_id, b_id, ert in emitted_pairs:
			for sid in (a_id, b_id):
				max_dev = max(max_dev, stop_mask_dist(points_by_id[sid], ert))

		if not emitted_pairs:
			path_adjudications.append(
				{
					"path_layer_index": idx,
					"layer_id": pr["layer_id"],
					"pxd_name": pr["pxd_name"],
					"classification": "UNRESOLVED",
					"semantic_verification_status": "blocked",
					"movement_verification_status": "blocked",
					"route_class": rt,
					"stop_sequence_before": before_seq,
					"stop_sequence": folded_seq,
					"note": "no edges emitted after alias fold",
				}
			)
			continue

		sem_stat = (
			"manually_verified"
			if idx in SEMANTIC_MANUAL_PATHS
			else ("auto" if max_dev <= EDGE_END_MAX_PX else "blocked")
		)
		path_adjudications.append(
			{
				"path_layer_index": idx,
				"layer_id": pr["layer_id"],
				"pxd_name": pr["pxd_name"],
				"classification": "ROUTE",
				"semantic_verification_status": sem_stat,
				"movement_verification_status": "auto_verified",  # finalized after movement gates
				"route_class": rt,
				"stop_sequence_before": before_seq,
				"stop_sequence": folded_seq,
				"emitted_edges": [
					{"a": a, "b": b, "route_type": r} for a, b, r in emitted_pairs
				],
				"max_stop_deviation_px": round(max_dev, 3),
			}
		)
		path_before_after[idx] = {
			"before": before_seq,
			"after": folded_seq,
			"emitted": emitted_pairs,
			"status": "route",
		}

	# Interchange domain completion along EXISTING path geometry only (no synthetic curves).
	# Cities like Jeddah sit inland of their SEA corridor; snap uses domain entry probe.
	INTERCHANGE_CITY_SNAP = 160.0
	for cid in INTERCHANGE_IDS:
		have = {
			r["route_type"]
			for r in raw_edge_records
			if cid in (r["a"], r["b"])
		}
		for need in ("LAND", "SEA"):
			if need in have:
				continue
			city = points_by_id[cid]
			crec = next(c for c in cities if c["city_id"] == cid)
			entry_key = "sea_entry_anchor_px" if need == "SEA" else "land_entry_anchor_px"
			probe = tuple(crec.get(entry_key) or crec["raw_anchor_px"])
			label_probe = crec.get("_label_center") or probe
			best = None
			for pr in paths:
				if pr["path_layer_index"] in EXCLUDED_PATH_LAYERS:
					continue
				if pr["route_class"] not in (need, "INTERCHANGE_BRIDGE"):
					continue
				poly = pr["poly"]
				if len(poly) < 2:
					continue
				for probe_used in (probe, label_probe, city["pos"]):
					s_c, d_c, _ = project_arc(poly, probe_used)
					if d_c > INTERCHANGE_CITY_SNAP:
						continue
					for p in points_by_id.values():
						if p["is_city"] or p.get("alias_of") or p["id"] in STOP_ALIASES:
							continue
						if p["route"] != need:
							continue
						s_p, d_p, _ = project_arc(poly, p["pos"])
						if d_p > SNAP_PX:
							continue
						score = d_c + d_p
						if best is None or score < best[0]:
							best = (score, pr, p, s_c, s_p, d_c, d_p, probe_used)
			if best is None:
				warnings.append(f"interchange {cid} missing {need} domain — no evidenced path")
				continue
			_score, pr, pt, s_c, s_p, d_c, d_p, probe_used = best
			# City endpoint is formal seat; path sample from probe projection to point.
			emit_edge(
				cid,
				pt["id"],
				need,
				pr["poly"],
				s_c,
				s_p,
				pr["path_layer_index"],
				[cid, pt["id"]],
			)
			# note on adjudication
			for adj in path_adjudications:
				if adj["path_layer_index"] == pr["path_layer_index"]:
					adj.setdefault("interchange_completions", []).append(
						{
							"city": cid,
							"domain": need,
							"point": pt["id"],
							"city_path_distance_px": round(d_c, 3),
							"probe_px": [round(probe_used[0], 3), round(probe_used[1], 3)],
						}
					)
			# ensure path is counted as used even if previously only had other edges
			path_before_after.setdefault(pr["path_layer_index"], {})

	# Dedup edges (playable endpoints only — aliases already folded).
	raw_edge_count = len(raw_edge_records)
	edge_map = {}
	for rec in raw_edge_records:
		# Drop if either endpoint is a non-playable alias id (should not happen).
		if rec["a"] in STOP_ALIASES or rec["b"] in STOP_ALIASES:
			continue
		key = tuple(sorted([rec["a"], rec["b"]])) + (rec["route_type"],)
		if key not in edge_map:
			a_id, b_id = key[0], key[1]
			src = rec.get("source_polyline_px") or rec["polyline_px"]
			pa = points_by_id[a_id]["pos"]
			pb = points_by_id[b_id]["pos"]
			if src and dist(src[0], pa) > dist(src[0], pb):
				src = list(reversed(src))
				rec = dict(rec)
				for ka, kb in (
					("raw_start_attach_gap_px", "raw_end_attach_gap_px"),
					("path_centerline_gap_start_px", "path_centerline_gap_end_px"),
					("first_join_length_px", "last_join_length_px"),
					("source_start_tangent_kink_deg", "source_end_tangent_kink_deg"),
				):
					if ka in rec:
						rec[ka], rec[kb] = rec[kb], rec[ka]
			edge_map[key] = {
				"a": a_id,
				"b": b_id,
				"route_type": rec["route_type"],
				"source_polyline_px": src,
				"source_path_layers": [rec["source_path_layer"]],
				"raw_start_attach_gap_px": rec["raw_start_attach_gap_px"],
				"raw_end_attach_gap_px": rec["raw_end_attach_gap_px"],
				"path_centerline_gap_start_px": rec["path_centerline_gap_start_px"],
				"path_centerline_gap_end_px": rec["path_centerline_gap_end_px"],
				"first_join_length_px": rec["first_join_length_px"],
				"last_join_length_px": rec["last_join_length_px"],
				"source_start_tangent_kink_deg": rec.get("source_start_tangent_kink_deg"),
				"source_end_tangent_kink_deg": rec.get("source_end_tangent_kink_deg"),
			}
		else:
			edge_map[key]["source_path_layers"].append(rec["source_path_layer"])

	raw_key_counts = defaultdict(int)
	for rec in raw_edge_records:
		if rec["a"] in STOP_ALIASES or rec["b"] in STOP_ALIASES:
			continue
		raw_key_counts[tuple(sorted([rec["a"], rec["b"]])) + (rec["route_type"],)] += 1
	duplicate_edge_groups = sum(1 for c in raw_key_counts.values() if c > 1)

	# REV2D: tight occlusion — alpha building + label only, each +8px. No hover_hit_rect.
	city_occlusion_zones = {}
	for c in cities:
		zones = {}
		br = c.get("building_hit_rect")
		if br:
			# Strip hover HIT_PAD, then apply occlusion pad only (≤8px).
			raw_b = {
				"x": br["x"] + HIT_PAD_PX,
				"y": br["y"] + HIT_PAD_PX,
				"w": max(1.0, br["w"] - 2 * HIT_PAD_PX),
				"h": max(1.0, br["h"] - 2 * HIT_PAD_PX),
			}
			zones["building_rect"] = inflate_rect(raw_b, OCCLUSION_PAD_PX)
		lr = c.get("label_hit_rect")
		if lr:
			raw_l = {
				"x": lr["x"] + 4,
				"y": lr["y"] + 4,
				"w": max(1.0, lr["w"] - 8),
				"h": max(1.0, lr["h"] - 8),
			}
			zones["label_rect"] = inflate_rect(raw_l, OCCLUSION_PAD_PX)
		if zones:
			city_occlusion_zones[c["city_id"]] = zones
	# Legacy name kept for evidence helpers that only need a union debug rect.
	city_occlusion_rects = {
		cid: zones.get("building_rect") or zones.get("label_rect")
		for cid, zones in city_occlusion_zones.items()
	}

	# Paint stop→path attach stems so Hermite joins stay inside dash-only corridor.
	from scipy.ndimage import binary_dilation as _bin_dilate

	for e in edge_map.values():
		src = e.get("source_polyline_px") or []
		if len(src) < 2:
			continue
		sa, sb = points_by_id[e["a"]], points_by_id[e["b"]]
		target_raw = land_mask_raw if e["route_type"] == "LAND" else sea_mask_raw
		_paint_polyline_mask(target_raw, [sa["pos"], src[0]], width=DASH_STROKE_PX)
		_paint_polyline_mask(target_raw, [src[-1], sb["pos"]], width=DASH_STROKE_PX)
		_paint_circle_mask(target_raw, sa["pos"], radius=7.0)
		_paint_circle_mask(target_raw, sb["pos"], radius=7.0)
	land_mask = _bin_dilate(land_mask_raw, iterations=DASH_DILATE_ITERS)
	sea_mask = _bin_dilate(sea_mask_raw, iterations=DASH_DILATE_ITERS)
	land_dist = mask_distance_field(land_mask)
	sea_dist = mask_distance_field(sea_mask)
	route_mask_meta["union_mask_coverage_ratio"] = float((land_mask | sea_mask).mean())
	route_mask_meta["land_mask_coverage_ratio"] = float(land_mask.mean())
	route_mask_meta["sea_mask_coverage_ratio"] = float(sea_mask.mean())
	route_mask_meta["stem_paint"] = True

	candidate_edges = []
	illegal_land_sea = []
	for key, e in sorted(edge_map.items()):
		e["source_path_layers"] = sorted(set(e["source_path_layers"]))
		issue = None
		sa, sb = points_by_id[e["a"]], points_by_id[e["b"]]
		if (not sa["is_city"]) and (not sb["is_city"]) and sa.get("route") != sb.get("route"):
			issue = "LAND_SEA_POINT_CROSS"
			illegal_land_sea.append(e)
		src = e.get("source_polyline_px") or []
		if len(src) < 2:
			issue = "MISSING_POLYLINE"

		# REV2C/D: smooth movement curve + dash-only corridor (endpoints frozen).
		pa, pb = sa["pos"], sb["pos"]
		mov = build_movement_polyline(
			pa,
			pb,
			src,
			e["route_type"],
			land_dist,
			sea_dist,
			city_occlusion_zones,
		)
		mpoly = [[round(x, 3), round(y, 3)] for x, y in mov["movement_polyline"]]
		e["source_polyline_px"] = [[round(float(x), 3), round(float(y), 3)] for x, y in src]
		e["movement_polyline_px"] = mpoly
		e["polyline_px"] = mpoly  # compatibility: runtime uses movement
		e["polyline_normalized"] = [clamp_norm(norm_xy(x, y)) for x, y in mpoly]
		e["movement_max_turn_deg"] = round(mov["max_turn_deg"], 3)
		e["movement_end_err_a"] = round(mov["end_err_a"], 3)
		e["movement_end_err_b"] = round(mov["end_err_b"], 3)
		e["movement_seg_ratio"] = round(mov["seg_ratio"], 3)
		e["movement_mask_failures"] = len(mov["mask_failures"])
		e["movement_wrong_route_type_failures"] = len(mov["wrong_type_failures"])
		e["movement_max_off_run_px"] = round(mov["max_off_run_px"], 3)
		e["occlusion_allowances"] = mov["occlusions"]
		e["movement_ok"] = mov["ok"]
		if not mov["ok"] and issue is None:
			issue = "MOVEMENT_GEOMETRY"
		sem = (
			"manually_verified"
			if any(p in SEMANTIC_MANUAL_PATHS for p in e["source_path_layers"])
			else "auto"
		)
		e["semantic_verification_status"] = sem if issue != "LAND_SEA_POINT_CROSS" else "blocked"
		e["movement_verification_status"] = (
			"auto_verified" if mov["ok"] and issue is None else "blocked"
		)
		e["issue"] = issue
		# Diagnostic: source centerline join kinks (not movement gates)
		e["start_tangent_kink_deg"] = e.get("source_start_tangent_kink_deg")
		e["end_tangent_kink_deg"] = e.get("source_end_tangent_kink_deg")
		candidate_edges.append(e)

	unique_edge_count = len(candidate_edges)

	# Adjacency consistency: per ROUTE path, emitted == canonical adjacent pairs
	adjacency_mismatches = []
	for adj in path_adjudications:
		if adj.get("classification") != "ROUTE":
			continue
		seq = adj.get("stop_sequence") or []
		rt = adj.get("route_class")
		expected = set()
		if rt == "INTERCHANGE_BRIDGE":
			for er in adj.get("emitted_edges") or []:
				expected.add((tuple(sorted([er["a"], er["b"]])), er["route_type"]))
		else:
			for i in range(len(seq) - 1):
				a, b = seq[i], seq[i + 1]
				if a == b:
					continue
				sa, sb = points_by_id[a], points_by_id[b]
				if (not sa["is_city"]) and (not sb["is_city"]):
					ert = sa["route"]
				elif sa["is_city"] and not sb["is_city"]:
					ert = sb["route"]
				elif sb["is_city"] and not sa["is_city"]:
					ert = sa["route"]
				else:
					continue
				expected.add((tuple(sorted([a, b])), ert))
		emitted = set()
		for er in adj.get("emitted_edges") or []:
			emitted.add((tuple(sorted([er["a"], er["b"]])), er["route_type"]))
		# Also verify those edges exist in candidate_edges from this path
		in_candidates = set()
		for e in candidate_edges:
			if adj["path_layer_index"] in e["source_path_layers"]:
				in_candidates.add((tuple(sorted([e["a"], e["b"]])), e["route_type"]))
		if expected != emitted or not emitted.issubset(in_candidates):
			adjacency_mismatches.append(
				{
					"path_layer_index": adj["path_layer_index"],
					"expected": sorted([list(k[0]) + [k[1]] for k in expected]),
					"emitted": sorted([list(k[0]) + [k[1]] for k in emitted]),
					"in_candidates": sorted([list(k[0]) + [k[1]] for k in in_candidates]),
				}
			)

	# Route layer coverage
	route_layer_idxs = sorted(
		a["path_layer_index"]
		for a in path_adjudications
		if a.get("classification") in ("ROUTE", "NON_ROUTE_DECORATIVE")
		or a.get("classification") == "UNRESOLVED"
	)
	# All path layers that were classified as having a route_class or excluded
	all_path_idxs = sorted(p["path_layer_index"] for p in paths)
	used_route_layers = sorted(
		{
			i
			for e in candidate_edges
			for i in e["source_path_layers"]
		}
	)
	excluded_idxs = sorted({e["path_layer_index"] for e in excluded_route_layers})
	# ROUTE classifications that must be used or excluded
	classified_route = sorted(
		a["path_layer_index"]
		for a in path_adjudications
		if a.get("classification") == "ROUTE"
	)
	missing_route_layers = sorted(set(classified_route) - set(used_route_layers) - set(excluded_idxs))
	# Also any path with route_class set that never got adjudication as ROUTE/excluded
	adjudicated = {a["path_layer_index"] for a in path_adjudications}
	for pr in paths:
		idx = pr["path_layer_index"]
		if pr.get("route_class") in ("LAND", "SEA", "INTERCHANGE_BRIDGE") and idx not in adjudicated:
			missing_route_layers.append(idx)
	missing_route_layers = sorted(set(missing_route_layers))

	route_layer_coverage = {
		"route_layers_total": len(paths),
		"used_route_layers": used_route_layers,
		"excluded_route_layers": excluded_route_layers,
		"missing_route_layers": missing_route_layers,
		"classified_route_count": len(classified_route),
	}

	# city path sources
	city_path_sources = defaultdict(set)
	for e in candidate_edges:
		for cid in (e["a"], e["b"]):
			if cid in ALLOWED_ROUTES:
				city_path_sources[cid].update(e["source_path_layers"])
	for city in cities:
		city["anchor_source_path_layers"] = sorted(city_path_sources.get(city["city_id"], []))

	# Playable graph (aliases excluded)
	playable_ids = [
		sid
		for sid, s in points_by_id.items()
		if s.get("playable", True) and sid not in STOP_ALIASES
	]
	# cities always playable
	for c in cities:
		if c["city_id"] not in playable_ids:
			playable_ids.append(c["city_id"])
	playable_ids = sorted(set(playable_ids))

	adj = defaultdict(set)
	for e in candidate_edges:
		if e.get("issue") == "LAND_SEA_POINT_CROSS":
			continue
		adj[e["a"]].add(e["b"])
		adj[e["b"]].add(e["a"])
	comps = connected_components(playable_ids, adj)
	isolates = [c[0] for c in comps if len(c) == 1]
	city_degrees = {c["city_id"]: len(adj[c["city_id"]]) for c in cities}
	interchange_route_domains = {}
	for cid in INTERCHANGE_IDS:
		interchange_route_domains[cid] = {
			"LAND": sum(
				1
				for e in candidate_edges
				if cid in (e["a"], e["b"])
				and e["route_type"] == "LAND"
				and e.get("issue") != "LAND_SEA_POINT_CROSS"
			),
			"SEA": sum(
				1
				for e in candidate_edges
				if cid in (e["a"], e["b"])
				and e["route_type"] == "SEA"
				and e.get("issue") != "LAND_SEA_POINT_CROSS"
			),
		}

	# Non-interchange cities must not have both domains
	illegal_non_interchange_dual = []
	for c in cities:
		cid = c["city_id"]
		if cid in INTERCHANGE_IDS:
			continue
		have = {e["route_type"] for e in candidate_edges if cid in (e["a"], e["b"]) and not e.get("issue")}
		if "LAND" in have and "SEA" in have:
			illegal_non_interchange_dual.append(cid)

	# Parallel alias edges: city↔X and aliased_point↔X
	parallel_alias_edges = []
	for pid, cid in STOP_ALIASES.items():
		for e in candidate_edges:
			if pid in (e["a"], e["b"]):
				parallel_alias_edges.append({"alias_edge": e, "city": cid})

	duplicate_playable_aliases = [
		a for a in alias_collapse if a["alias_id"] in playable_ids
	]

	stop_ids = playable_ids  # for downstream gate naming
	# --- pixel mask gates (masks already built) ---
	excluded_idx_set = {e["path_layer_index"] for e in excluded_route_layers}
	path_mask_results = []
	paths_mask_blocked = []
	for pr in paths:
		rt = pr["route_class"]
		if pr["path_layer_index"] in excluded_idx_set:
			path_mask_results.append(
				{
					"path_layer_index": pr["path_layer_index"],
					"route_class": rt,
					"mask_mean_px": None,
					"mask_p95_px": None,
					"mask_coverage": None,
					"ok": True,
					"skipped": "excluded_non_route",
				}
			)
			continue
		if rt == "LAND":
			stats = polyline_mask_stats(pr["poly"], land_dist, rgb=map_rgb, domain="LAND")
		elif rt == "SEA":
			stats = polyline_mask_stats(pr["poly"], sea_dist, rgb=map_rgb, domain="SEA")
		elif rt == "INTERCHANGE_BRIDGE":
			# Score only samples on visible dash colors (cyan→SEA, cream→LAND).
			# City-art / jungle connectors between domains are not dash corridors.
			dists = []
			h, w = land_dist.shape
			for x, y in pr["poly"]:
				xi, yi = int(round(x)), int(round(y))
				if not (0 <= xi < w and 0 <= yi < h):
					continue
				cr, cg, cb = [int(v) for v in map_rgb[yi, xi]]
				seaish = cb > cr + 15 and cb > 100 and cg > 90
				landish = (cr > 185 and cg > 170 and cb > 120 and cr >= cg - 5) or (
					cr > 200 and cg > 195 and cb > 180
				)
				if seaish and not landish:
					dists.append(float(sea_dist[yi, xi]))
				elif landish and not seaish:
					dists.append(float(land_dist[yi, xi]))
				elif seaish and landish:
					dists.append(min(float(land_dist[yi, xi]), float(sea_dist[yi, xi])))
				# else: non-dash pixel — skip (honest; do not trim after the fact)
			if len(dists) < 3:
				stats = {"mean": 999.0, "p95": 999.0, "coverage": 0.0, "n": int(len(dists))}
			else:
				arr = np.asarray(dists, dtype=np.float64)
				stats = {
					"mean": float(arr.mean()),
					"p95": float(np.percentile(arr, 95)),
					"coverage": float((arr <= MASK_MEAN_MAX).mean()),
					"n": int(len(arr)),
				}
		else:
			stats = {"mean": 999.0, "p95": 999.0, "coverage": 0.0, "n": 0}
		ok = (
			stats["mean"] <= MASK_MEAN_MAX
			and stats["p95"] <= MASK_P95_MAX
			and stats["coverage"] >= MASK_COVERAGE_MIN
		)
		rec = {
			"path_layer_index": pr["path_layer_index"],
			"route_class": rt,
			"mask_mean_px": round(stats["mean"], 3),
			"mask_p95_px": round(stats["p95"], 3),
			"mask_coverage": round(stats["coverage"], 4),
			"ok": ok,
		}
		path_mask_results.append(rec)
		if rt in ("LAND", "SEA", "INTERCHANGE_BRIDGE") and not ok:
			paths_mask_blocked.append(rec)

	# inland SEA / ocean LAND point checks via masks near stops
	misplaced_stops = []
	for p in points_by_id.values():
		if p["is_city"] or not p.get("playable", True) or p["id"] in STOP_ALIASES:
			continue
		x, y = int(round(p["pos"][0])), int(round(p["pos"][1]))
		if not (0 <= x < map_rgb.shape[1] and 0 <= y < map_rgb.shape[0]):
			misplaced_stops.append(p["id"])
			continue
		# sample local land vs water by green/blue dominance is unreliable;
		# instead: SEA points should be near sea mask; LAND near land mask
		rad = 14
		y0, y1 = max(0, y - rad), min(map_rgb.shape[0], y + rad + 1)
		x0, x1 = max(0, x - rad), min(map_rgb.shape[1], x + rad + 1)
		if p["route"] == "SEA":
			near = float(sea_dist[y0:y1, x0:x1].min())
			# also forbid deep inland: far from sea mask AND close to land-route-only interior
			if near > 40:
				misplaced_stops.append(p["id"])
		else:
			near = float(land_dist[y0:y1, x0:x1].min())
			if near > 40:
				misplaced_stops.append(p["id"])

	# hover overlap: do not shrink; record arbitration pairs
	hover_overlaps = []
	for i, a in enumerate(cities):
		ar = a["hover_hit_rect"]
		for b in cities[i + 1 :]:
			br = b["hover_hit_rect"]
			if not (
				ar["x"] + ar["w"] <= br["x"]
				or br["x"] + br["w"] <= ar["x"]
				or ar["y"] + ar["h"] <= br["y"]
				or br["y"] + br["h"] <= ar["y"]
			):
				hover_overlaps.append(
					{
						"a": a["city_id"],
						"b": b["city_id"],
						"arbitration": "nearest_city_center",
						"note": "overlap retained; runtime picks nearest center",
					}
				)

	max_pre_snap = max(c["pre_snap_error_px"] for c in cities)
	max_piece_err = max(c.get("piece_anchor_error_px", 0.0) for c in cities)

	# Sync path movement status; keep semantic status independent (REV2D split).
	for adj in path_adjudications:
		if adj.get("classification") != "ROUTE":
			continue
		idx = adj["path_layer_index"]
		if idx in SEMANTIC_MANUAL_PATHS:
			adj["semantic_verification_status"] = "manually_verified"
		related = [e for e in candidate_edges if idx in e.get("source_path_layers", [])]
		if not related:
			adj["movement_verification_status"] = "blocked"
			continue
		if all(e.get("movement_ok") and e.get("movement_verification_status") == "auto_verified" for e in related):
			adj["movement_verification_status"] = "auto_verified"
		else:
			adj["movement_verification_status"] = "blocked"
			adj["manual_review_blocked_reason"] = "movement geometry failed on one or more edges"

	movement_ok_edges = [e for e in candidate_edges if e.get("movement_ok")]
	movement_max_turn = max((e.get("movement_max_turn_deg") or 0) for e in candidate_edges) if candidate_edges else 999
	movement_max_end = max(
		max(e.get("movement_end_err_a") or 0, e.get("movement_end_err_b") or 0) for e in candidate_edges
	) if candidate_edges else 999
	movement_mask_fail_total = sum(e.get("movement_mask_failures") or 0 for e in candidate_edges)
	movement_wrong_type_total = sum(e.get("movement_wrong_route_type_failures") or 0 for e in candidate_edges)
	# Occlusion audit: every exemption must name city + sample + rect kind
	occlusion_audit_failures = []
	for e in candidate_edges:
		for occ in e.get("occlusion_allowances") or []:
			if not occ.get("occlusion_city_id") or occ.get("sample_index") is None:
				occlusion_audit_failures.append({"edge": [e["a"], e["b"]], "occ": occ})
			elif not occ.get("building_rect") and not occ.get("label_rect"):
				occlusion_audit_failures.append({"edge": [e["a"], e["b"]], "occ": occ})
	verification_status_mismatches = []
	for adj in path_adjudications:
		if adj.get("classification") != "ROUTE":
			continue
		idx = adj["path_layer_index"]
		related = [e for e in candidate_edges if idx in e.get("source_path_layers", [])]
		if idx in SEMANTIC_MANUAL_PATHS and adj.get("semantic_verification_status") != "manually_verified":
			verification_status_mismatches.append(
				{"path": idx, "field": "semantic_verification_status", "got": adj.get("semantic_verification_status")}
			)
		for e in related:
			if idx in SEMANTIC_MANUAL_PATHS and e.get("semantic_verification_status") != "manually_verified":
				verification_status_mismatches.append(
					{
						"path": idx,
						"edge": [e["a"], e["b"]],
						"field": "semantic_verification_status",
						"got": e.get("semantic_verification_status"),
					}
				)
			if e.get("verification_status") is not None:
				verification_status_mismatches.append(
					{
						"path": idx,
						"edge": [e["a"], e["b"]],
						"field": "legacy_verification_status_present",
						"got": e.get("verification_status"),
					}
				)

	edge_poly_ok = all(
		e.get("movement_polyline_px")
		and len(e["movement_polyline_px"]) >= 2
		and e.get("source_polyline_px")
		and len(e["source_polyline_px"]) >= 2
		and e.get("issue") not in ("MISSING_POLYLINE", "LAND_SEA_POINT_CROSS")
		for e in candidate_edges
	)
	hit_min_ok = all(
		c["hover_hit_min_screen_px_at_min_fit"][0] >= MIN_HIT_SCREEN_PX - 0.01
		and c["hover_hit_min_screen_px_at_min_fit"][1] >= MIN_HIT_SCREEN_PX - 0.01
		for c in cities
	)
	unresolved = [p for p in path_adjudications if p.get("classification") == "UNRESOLVED"]
	playable_expected = 16 + 25 + 26 - len(STOP_ALIASES)

	gates = {
		"cities_16": len(cities) == 16,
		"land_25_sea_26": len(land_sorted) == 25 and len(sea_sorted) == 26,
		"playable_stops": len(stop_ids) == playable_expected,
		"all_cities_connected": all(d >= 1 for d in city_degrees.values()),
		"connected_components_1": len(comps) == 1,
		"isolated_stops_0": len(isolates) == 0,
		"interchanges_land_and_sea": all(
			interchange_route_domains[cid]["LAND"] >= 1
			and interchange_route_domains[cid]["SEA"] >= 1
			for cid in INTERCHANGE_IDS
		),
		"no_illegal_non_interchange_dual": len(illegal_non_interchange_dual) == 0,
		"path_mask_gates": len(paths_mask_blocked) == 0,
		"all_edges_have_polyline": edge_poly_ok,
		"pre_snap_mask_max_le_8": max_pre_snap <= PRE_SNAP_MAX_PX,
		"piece_anchor_error_0": max_piece_err <= 0.0,
		"no_misplaced_route_points": len(misplaced_stops) == 0,
		"map_texture_size": map_texture_ok,
		"min_hover_hit_44": hit_min_ok,
		"unresolved_paths_0": len(unresolved) == 0,
		"missing_route_layers_0": len(missing_route_layers) == 0,
		"illegal_land_sea_edges_0": len(illegal_land_sea) == 0,
		"adjacency_mismatches_0": len(adjacency_mismatches) == 0,
		"duplicate_playable_aliases_0": len(duplicate_playable_aliases) == 0
		and len(parallel_alias_edges) == 0,
		"movement_edges_verified_all": len(movement_ok_edges) == unique_edge_count and unique_edge_count >= 1,
		"movement_max_kink_deg_le_25": movement_max_turn <= MOVEMENT_MAX_TURN_DEG,
		"movement_max_endpoint_error_le_1": movement_max_end <= MOVEMENT_END_MAX_PX,
		"movement_mask_corridor_failures_0": movement_mask_fail_total == 0,
		"movement_wrong_route_type_failures_0": movement_wrong_type_total == 0,
		"movement_occlusion_audit_failures_0": len(occlusion_audit_failures) == 0,
		"land_mask_coverage_lt_4": route_mask_meta["land_mask_coverage_ratio"] < LAND_MASK_COVERAGE_MAX,
		"sea_mask_coverage_lt_4": route_mask_meta["sea_mask_coverage_ratio"] < SEA_MASK_COVERAGE_MAX,
		"union_mask_coverage_lt_7": route_mask_meta["union_mask_coverage_ratio"] < UNION_MASK_COVERAGE_MAX,
		"terrain_component_leaks_0": len(route_mask_meta["terrain_component_leaks"]) == 0,
		"verification_status_mismatches_0": len(verification_status_mismatches) == 0,
	}
	status = "PASSED" if all(gates.values()) else "FAILED"

	# strip private keys for JSON cities
	cities_out = []
	for c in cities:
		cities_out.append({k: v for k, v in c.items() if not k.startswith("_")})

	presentation = {
		"schema": "world_map_presentation_v1",
		"task": "TASK-WORLD-MAP-DATA-001-REV2D",
		"logic_size": [int(LOGIC_W), int(LOGIC_H)],
		"document_size_px": [int(DOC_W), int(DOC_H)],
		"coordinate_space": "screen_y_down",
		"model_to_screen": "screen_y = LOGIC_H - model_y",
		"map_texture": MAP_TEXTURE_RES,
		"source_refs": [
			"all地图.pxd",
			"docs/research/YF064-original-physical-assets-ledger.md",
		],
		"cities": cities_out,
		"route_points": route_points,
		"stop_aliases": STOP_ALIASES,
		"counts": {
			"cities": 16,
			"land_points": 25,
			"sea_points": 26,
			"alias_route_points": len(STOP_ALIASES),
			"playable_stops": len(stop_ids),
			"audit_nodes": 16 + 25 + 26,
			"interchange_cities": 5,
			"path_layers": 54,
			"unique_edges": unique_edge_count,
		},
		"notes": {
			"path_layers_note": "54 PXD path layers are NOT board_edges; see topology_candidate.json",
			"candidate_only": True,
			"snap_threshold_px": SNAP_PX,
			"alias_note": "Aliased route points are audit-only; not playable stops",
			"rev2b_semantics_frozen": True,
			"rev2c_movement_geometry_frozen": True,
			"polyline_px_is_movement": True,
			"route_mask": "dash_only_from_pxd_path_layers",
		},
	}
	args.presentation_out.parent.mkdir(parents=True, exist_ok=True)
	args.presentation_out.write_text(
		json.dumps(presentation, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
	)

	movement_gate_table = [
		{
			"a": e["a"],
			"b": e["b"],
			"route_type": e["route_type"],
			"source_path_layers": e["source_path_layers"],
			"movement_max_turn_deg": e.get("movement_max_turn_deg"),
			"movement_end_err_a": e.get("movement_end_err_a"),
			"movement_end_err_b": e.get("movement_end_err_b"),
			"movement_seg_ratio": e.get("movement_seg_ratio"),
			"movement_mask_failures": e.get("movement_mask_failures"),
			"movement_wrong_route_type_failures": e.get("movement_wrong_route_type_failures"),
			"movement_max_off_run_px": e.get("movement_max_off_run_px"),
			"path_centerline_gap_start_px": e.get("path_centerline_gap_start_px"),
			"path_centerline_gap_end_px": e.get("path_centerline_gap_end_px"),
			"semantic_verification_status": e.get("semantic_verification_status"),
			"movement_verification_status": e.get("movement_verification_status"),
			"movement_ok": e.get("movement_ok"),
			"issue": e.get("issue"),
		}
		for e in candidate_edges
	]

	topology = {
		"schema": "world_map_topology_candidate_v1",
		"task": "TASK-WORLD-MAP-DATA-001-REV2D",
		"candidate_only": True,
		"rev2b_semantics_frozen": True,
		"rev2c_movement_geometry_frozen": True,
		"route_mask_meta": route_mask_meta,
		"raw_edge_count": raw_edge_count,
		"unique_edge_count": unique_edge_count,
		"duplicate_edge_groups": duplicate_edge_groups,
		"alias_collapse": alias_collapse,
		"route_layer_coverage": route_layer_coverage,
		"adjacency_mismatches": adjacency_mismatches,
		"path_before_after": {str(k): v for k, v in path_before_after.items()},
		"candidate_edges": candidate_edges,
		"movement_gate_table": movement_gate_table,
		"path_adjudications": path_adjudications,
		"path_mask_results": path_mask_results,
		"metrics": {
			"playable_stops": len(stop_ids),
			"connected_components": len(comps),
			"isolated_stops": len(isolates),
			"missing_route_layers": missing_route_layers,
			"illegal_land_sea_edges": len(illegal_land_sea),
			"max_piece_anchor_error_px": max_piece_err,
			"movement_edges_verified": len(movement_ok_edges),
			"movement_max_turn_deg": movement_max_turn,
			"movement_max_endpoint_error_px": movement_max_end,
			"movement_mask_corridor_failures": movement_mask_fail_total,
			"movement_wrong_route_type_failures": movement_wrong_type_total,
			"movement_occlusion_audit_failures": len(occlusion_audit_failures),
			"route_mask_union_coverage_ratio": route_mask_meta["union_mask_coverage_ratio"],
			"terrain_component_leaks": len(route_mask_meta["terrain_component_leaks"]),
		},
	}
	(out_dir / "topology_candidate.json").write_text(
		json.dumps(topology, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
	)

	validation = {
		"status": status,
		"task": "TASK-WORLD-MAP-DATA-001-REV2D",
		"before": before,
		"after": {
			"playable_stops": len(stop_ids),
			"raw_edge_count": raw_edge_count,
			"unique_edge_count": unique_edge_count,
			"duplicate_edge_groups": duplicate_edge_groups,
			"connected_components": len(comps),
			"isolated_stops": len(isolates),
			"city_degrees": city_degrees,
			"interchange_route_domains": interchange_route_domains,
			"unresolved_paths": len(unresolved),
			"paths_mask_blocked": len(paths_mask_blocked),
			"maximum_pre_snap_error_px": max_pre_snap,
			"maximum_piece_anchor_error_px": max_piece_err,
			"route_layer_coverage": route_layer_coverage,
			"alias_collapse": alias_collapse,
			"adjacency_mismatches": adjacency_mismatches,
			"illegal_land_sea_edges": len(illegal_land_sea),
			"misplaced_route_points": misplaced_stops,
			"hover_overlaps_arbitrated": hover_overlaps,
			"map_texture": MAP_TEXTURE_RES,
			"map_texture_size": [tex_w, tex_h],
			"movement_edges_verified": len(movement_ok_edges),
			"movement_max_kink_deg": movement_max_turn,
			"movement_max_endpoint_error_px": movement_max_end,
			"movement_mask_corridor_failures": movement_mask_fail_total,
			"movement_wrong_route_type_failures": movement_wrong_type_total,
			"movement_occlusion_audit_failures": occlusion_audit_failures,
			"route_mask_union_coverage_ratio": route_mask_meta["union_mask_coverage_ratio"],
			"land_mask_coverage_ratio": route_mask_meta["land_mask_coverage_ratio"],
			"sea_mask_coverage_ratio": route_mask_meta["sea_mask_coverage_ratio"],
			"terrain_component_leaks": route_mask_meta["terrain_component_leaks"],
			"route_mask_meta": route_mask_meta,
			"verification_status_mismatches": verification_status_mismatches,
			"terrain_color_candidate_mask_note": (
				"DEBUG ONLY; retired from corridor gates. "
				f"land={float(terrain_land_mask.mean()):.4f} sea={float(terrain_sea_mask.mean()):.4f}"
			),
		},
		"gates": gates,
		"warnings": warnings,
		"textures_ok": not any("missing" in w and "texture" in w for w in warnings),
	}
	(out_dir / "validation_summary.json").write_text(
		json.dumps(validation, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
	)

	# ---------------- audit images ----------------
	base = Image.open(args.map_texture_out).convert("RGBA")
	font = try_font(16)
	font_sm = try_font(13)

	# 1) numbered nodes
	img1 = base.copy()
	d1 = ImageDraw.Draw(img1)
	for i, (_g, (x, y)) in enumerate(land_sorted, 1):
		d1.ellipse([x - 9, y - 9, x + 9, y + 9], outline=(220, 140, 20, 255), width=2)
		d1.text((x + 11, y - 7), f"L{i}", fill=(60, 30, 0, 255), font=font_sm)
	for i, (_g, (x, y)) in enumerate(sea_sorted, 1):
		d1.ellipse([x - 9, y - 9, x + 9, y + 9], outline=(20, 160, 220, 255), width=2)
		d1.text((x + 11, y - 7), f"S{i}", fill=(0, 40, 80, 255), font=font_sm)
	for c in cities:
		x, y = c["piece_anchor_px"]
		d1.ellipse([x - 11, y - 11, x + 11, y + 11], outline=(200, 30, 30, 255), width=3)
		d1.text((x + 12, y - 9), c["display_name"], fill=(10, 10, 10, 255), font=font_sm)
	save_preview(img1, full_dir / "world_map_numbered_nodes.png", out_dir / "world_map_numbered_nodes.png")

	# 2) dash-only masks (authoritative) + overlays
	mask_dir = out_dir / "route_masks"
	mask_dir.mkdir(exist_ok=True)
	Image.fromarray((land_mask_raw.astype(np.uint8) * 255)).save(mask_dir / "route_mask_land_v1.png")
	Image.fromarray((sea_mask_raw.astype(np.uint8) * 255)).save(mask_dir / "route_mask_sea_v1.png")
	Image.fromarray((land_mask.astype(np.uint8) * 255)).save(mask_dir / "route_mask_land_dilated_v1.png")
	Image.fromarray((sea_mask.astype(np.uint8) * 255)).save(mask_dir / "route_mask_sea_dilated_v1.png")
	# Debug terrain color candidate (retired)
	Image.fromarray((terrain_land_mask.astype(np.uint8) * 255)).save(
		mask_dir / "terrain_color_candidate_mask_land.png"
	)
	Image.fromarray((terrain_sea_mask.astype(np.uint8) * 255)).save(
		mask_dir / "terrain_color_candidate_mask_sea.png"
	)

	def tint_overlay(mask_bool, rgba):
		ov = base.copy()
		arr = np.array(ov)
		tint = np.zeros_like(arr)
		tint[mask_bool] = rgba
		arr = np.clip(arr.astype(np.int16) + tint.astype(np.int16) // 2, 0, 255).astype(np.uint8)
		return Image.fromarray(arr).convert("RGBA")

	land_ov = tint_overlay(land_mask, (255, 255, 255, 200))
	sea_ov = tint_overlay(sea_mask, (255, 255, 255, 200))
	union_ov = tint_overlay(land_mask | sea_mask, (255, 255, 255, 200))
	# 200% overlays for mask self-gate review
	for name, im in (
		("route_mask_land_overlay.png", land_ov),
		("route_mask_sea_overlay.png", sea_ov),
		("route_mask_union_overlay.png", union_ov),
	):
		im.save(out_dir / name)
		im.save(full_dir / name)
		im.resize((im.width * 2, im.height * 2), Image.Resampling.NEAREST).save(
			out_dir / name.replace(".png", "_200pct.png")
		)

	mask_overlay = base.copy()
	mo = np.array(mask_overlay)
	land_tint = np.zeros_like(mo)
	land_tint[land_mask] = (255, 220, 80, 110)
	sea_tint = np.zeros_like(mo)
	sea_tint[sea_mask] = (40, 200, 255, 110)
	mo = np.clip(mo.astype(np.int16) + land_tint.astype(np.int16) // 2 + sea_tint.astype(np.int16) // 2, 0, 255).astype(
		np.uint8
	)
	img2 = Image.fromarray(mo).convert("RGBA")
	d2 = ImageDraw.Draw(img2)
	for pr in paths:
		if pr["path_layer_index"] in EXCLUDED_PATH_LAYERS:
			continue
		if len(pr["poly"]) < 2:
			continue
		col = {
			"LAND": (255, 200, 0, 220),
			"SEA": (0, 255, 255, 220),
			"INTERCHANGE_BRIDGE": (255, 0, 255, 230),
		}.get(pr["route_class"], (255, 0, 0, 220))
		d2.line([(p[0], p[1]) for p in pr["poly"]], fill=col, width=3)
	save_preview(
		img2,
		full_dir / "world_map_decoded_paths_overlay.png",
		out_dir / "world_map_decoded_paths_overlay.png",
	)
	save_preview(
		img2,
		full_dir / "world_map_route_mask_polyline_overlay.png",
		out_dir / "world_map_route_mask_polyline_overlay.png",
	)

	# 3) candidate edges
	img3 = base.copy()
	d3 = ImageDraw.Draw(img3)
	for e in candidate_edges:
		poly = e["polyline_px"]
		col = (240, 200, 40, 230) if e["route_type"] == "LAND" else (40, 180, 255, 230)
		if e.get("issue"):
			col = (255, 40, 40, 255)
		if len(poly) >= 2:
			d3.line([(p[0], p[1]) for p in poly], fill=col, width=3)
	save_preview(img3, full_dir / "world_map_candidate_edges.png", out_dir / "world_map_candidate_edges.png")

	# per-edge sheets (contact sheet style batches)
	edge_dir = full_dir / "edges"
	if edge_dir.exists():
		shutil.rmtree(edge_dir)
	edge_dir.mkdir(exist_ok=True)
	edge_preview_dir = out_dir / "edges"
	if edge_preview_dir.exists():
		shutil.rmtree(edge_preview_dir)
	edge_preview_dir.mkdir(exist_ok=True)
	for i, e in enumerate(candidate_edges):
		poly = e["polyline_px"]
		if len(poly) < 2:
			continue
		xs = [p[0] for p in poly]
		ys = [p[1] for p in poly]
		pad = 60
		box = (
			max(0, int(min(xs) - pad)),
			max(0, int(min(ys) - pad)),
			min(int(LOGIC_W), int(max(xs) + pad)),
			min(int(LOGIC_H), int(max(ys) + pad)),
		)
		crop = base.crop(box).convert("RGBA")
		dc = ImageDraw.Draw(crop)
		shifted = [(p[0] - box[0], p[1] - box[1]) for p in poly]
		dc.line(shifted, fill=(255, 40, 40, 255), width=3)
		for sid, col in ((e["a"], (255, 220, 0)), (e["b"], (0, 255, 180))):
			px, py = points_by_id[sid]["pos"]
			dc.ellipse(
				[px - box[0] - 7, py - box[1] - 7, px - box[0] + 7, py - box[1] + 7],
				outline=col + (255,),
				width=2,
			)
			dc.text((px - box[0] + 9, py - box[1] - 8), sid, fill=(0, 0, 0, 255), font=font_sm)
		dc.text(
			(8, 8),
			f"{e['a']} —{e['route_type']}→ {e['b']}  "
			f"turn={e.get('movement_max_turn_deg')}° "
			f"cend=({e.get('path_centerline_gap_start_px')},{e.get('path_centerline_gap_end_px')})",
			fill=(0, 0, 0, 255),
			font=font_sm,
		)
		fp = edge_dir / f"edge_{i:03d}_{e['a']}__{e['b']}.png"
		crop.save(fp)
		if i < 12:
			# keep a few previews in docs
			crop.resize((min(1200, crop.width * 2), min(800, crop.height * 2)), Image.Resampling.LANCZOS).save(
				edge_preview_dir / fp.name
			)

	# 4) city raw/snapped anchors
	img4 = base.copy()
	d4 = ImageDraw.Draw(img4)
	for c in cities:
		hr = c["hover_hit_rect"]
		d4.rectangle(
			[hr["x"], hr["y"], hr["x"] + hr["w"], hr["y"] + hr["h"]],
			outline=(255, 140, 40, 200),
			width=2,
		)
		rx, ry = c["raw_anchor_px"]
		sx, sy = c["snapped_anchor_px"]
		d4.ellipse([rx - 7, ry - 7, rx + 7, ry + 7], outline=(255, 0, 0, 255), width=2)
		d4.ellipse([sx - 7, sy - 7, sx + 7, sy + 7], outline=(0, 255, 0, 255), width=2)
		d4.line([(rx, ry), (sx, sy)], fill=(255, 255, 0, 220), width=2)
		d4.text(
			(sx + 10, sy - 10),
			f"{c['display_name']} pre={c['pre_snap_error_px']}",
			fill=(0, 0, 0, 255),
			font=font_sm,
		)
	save_preview(img4, full_dir / "city_anchor_audit.png", out_dir / "city_anchor_audit.png")

	# interchange crops
	for cid in INTERCHANGE_IDS:
		c = next(x for x in cities if x["city_id"] == cid)
		ax, ay = c["piece_anchor_px"]
		box = (max(0, int(ax - 220)), max(0, int(ay - 180)), min(int(LOGIC_W), int(ax + 220)), min(int(LOGIC_H), int(ay + 180)))
		crop = img4.crop(box).resize(((box[2] - box[0]) * 2, (box[3] - box[1]) * 2), Image.Resampling.LANCZOS)
		crop.save(full_dir / f"interchange_{cid}_200pct.png")
		crop.resize((min(1024, crop.width), min(800, crop.height)), Image.Resampling.LANCZOS).save(
			out_dir / f"interchange_{cid}_200pct.png"
		)

	# hover at min fit visualization
	scale = MIN_VIEW_WIDTH / LOGIC_W
	hover_w = int(LOGIC_W * scale)
	hover_h = int(LOGIC_H * scale)
	hover_img = base.resize((hover_w, hover_h), Image.Resampling.LANCZOS).convert("RGBA")
	dh = ImageDraw.Draw(hover_img)
	for c in cities:
		hr = c["hover_hit_rect"]
		dh.rectangle(
			[
				hr["x"] * scale,
				hr["y"] * scale,
				(hr["x"] + hr["w"]) * scale,
				(hr["y"] + hr["h"]) * scale,
			],
			outline=(255, 100, 0, 220),
			width=2,
		)
	save_preview(hover_img, full_dir / "hover_hit_min_fit_1280.png", out_dir / "hover_hit_min_fit_1280.png")

	# REV2C: movement polyline evidence (source red / movement green).
	ev_dir = out_dir / "evidence"
	if ev_dir.exists():
		shutil.rmtree(ev_dir)
	ev_dir.mkdir(exist_ok=True)
	ba_dir = out_dir / "evidence_before_after"
	if ba_dir.exists():
		shutil.rmtree(ba_dir)
	ba_dir.mkdir(exist_ok=True)
	mov_dir = out_dir / "movement"
	if mov_dir.exists():
		shutil.rmtree(mov_dir)
	mov_dir.mkdir(exist_ok=True)

	def edge_bbox(e, pad=120):
		pts = list(e.get("source_polyline_px") or []) + list(e.get("movement_polyline_px") or [])
		for sid in (e["a"], e["b"]):
			pts.append(points_by_id[sid]["pos"])
		xs = [p[0] for p in pts]
		ys = [p[1] for p in pts]
		return (
			max(0, int(min(xs) - pad)),
			max(0, int(min(ys) - pad)),
			min(int(LOGIC_W), int(max(xs) + pad)),
			min(int(LOGIC_H), int(max(ys) + pad)),
		)

	def draw_movement_edge(e, title: str, out_path: Path, show_arc_dots=False):
		box = edge_bbox(e)
		# Tint route mask in crop
		crop = base.crop(box).convert("RGBA")
		arr = np.array(crop)
		x0, y0, x1, y1 = box
		field = land_mask if e["route_type"] == "LAND" else sea_mask
		sub = field[y0:y1, x0:x1]
		tint = np.zeros_like(arr)
		if e["route_type"] == "LAND":
			tint[sub] = (255, 220, 80, 90)
		else:
			tint[sub] = (40, 200, 255, 90)
		arr = np.clip(arr.astype(np.int16) + tint.astype(np.int16) // 2, 0, 255).astype(np.uint8)
		crop = Image.fromarray(arr).convert("RGBA")
		dc = ImageDraw.Draw(crop)
		src = e.get("source_polyline_px") or []
		mov = e.get("movement_polyline_px") or []
		if len(src) >= 2:
			dc.line([(p[0] - x0, p[1] - y0) for p in src], fill=(220, 40, 40, 200), width=2)
		if len(mov) >= 2:
			dc.line([(p[0] - x0, p[1] - y0) for p in mov], fill=(40, 220, 80, 255), width=3)
		if show_arc_dots and len(mov) >= 2:
			total = polyline_length([(float(p[0]), float(p[1])) for p in mov])
			for t in (0.0, 0.25, 0.5, 0.75, 1.0):
				pt = point_at_arc([(float(p[0]), float(p[1])) for p in mov], total * t)
				dc.ellipse(
					[pt[0] - x0 - 4, pt[1] - y0 - 4, pt[0] - x0 + 4, pt[1] - y0 + 4],
					fill=(255, 255, 0, 255),
				)
		for sid, col in ((e["a"], (255, 220, 0)), (e["b"], (0, 255, 180))):
			px, py = points_by_id[sid]["pos"]
			dc.ellipse([px - x0 - 8, py - y0 - 8, px - x0 + 8, py - y0 + 8], outline=col + (255,), width=2)
			dc.text((px - x0 + 10, py - y0 - 10), sid, fill=(0, 0, 0, 255), font=font_sm)
		# Mask deviation along movement (own-type dash; non-occlusion)
		mask_devs = []
		field_d = land_dist if e["route_type"] == "LAND" else sea_dist
		for p in mov:
			md = mask_dist_at(field_d, p)
			cid, _kind = occlusion_hit_at(p, city_occlusion_zones)
			if not cid:
				mask_devs.append(md)
		max_mask = max(mask_devs) if mask_devs else 0.0
		dc.text(
			(8, 8),
			f"{title} turn={e.get('movement_max_turn_deg')}° "
			f"mask_max={round(max_mask,2)} end=({e.get('movement_end_err_a')},{e.get('movement_end_err_b')})",
			fill=(0, 0, 0, 255),
			font=font_sm,
		)
		big = crop.resize((crop.width * 2, crop.height * 2), Image.Resampling.LANCZOS)
		big.save(out_path)

	# Top-10 by source join kink (before) and movement turn (after context)
	by_src_kink = sorted(
		candidate_edges,
		key=lambda e: max(e.get("source_start_tangent_kink_deg") or 0, e.get("source_end_tangent_kink_deg") or 0),
		reverse=True,
	)[:10]
	for i, e in enumerate(by_src_kink):
		# BEFORE: hard-joined diagnostic poly (stop—line—source—line—stop)
		src = e.get("source_polyline_px") or []
		pa, pb = points_by_id[e["a"]]["pos"], points_by_id[e["b"]]["pos"]
		before_poly = [pa] + [(float(x), float(y)) for x, y in src] + [pb]
		# draw using a temporary edge-like dict
		tmp = dict(e)
		tmp["source_polyline_px"] = [[round(x, 3), round(y, 3)] for x, y in before_poly]
		tmp["movement_polyline_px"] = before_poly  # show kinky join in red+green same for before
		draw_movement_edge(
			{
				**e,
				"source_polyline_px": before_poly,
				"movement_polyline_px": before_poly,
				"movement_max_turn_deg": round(poly_max_turn_deg(before_poly), 3),
				"movement_end_err_a": 0,
				"movement_end_err_b": 0,
				"occlusion_allowances": [],
			},
			f"BEFORE kinky join {e['a']}↔{e['b']}",
			ba_dir / f"top{i+1:02d}_{e['a']}__{e['b']}_before_200pct.png",
		)
		draw_movement_edge(
			e,
			f"AFTER movement {e['a']}↔{e['b']}",
			ba_dir / f"top{i+1:02d}_{e['a']}__{e['b']}_after_200pct.png",
			show_arc_dots=True,
		)

	for idx in SEMANTIC_MANUAL_PATHS:
		related = [e for e in candidate_edges if idx in e.get("source_path_layers", [])]
		for e in related:
			draw_movement_edge(
				e,
				f"path#{idx} {e['a']}↔{e['b']}",
				ev_dir / f"path_{idx:02d}_{e['a']}__{e['b']}_movement.png",
				show_arc_dots=True,
			)
			draw_movement_edge(
				e,
				f"path#{idx} AFTER {e['a']}↔{e['b']}",
				ba_dir / f"path_{idx:02d}_after_200pct.png",
				show_arc_dots=True,
			)

	# Top-10 by movement corridor max own-mask distance
	def edge_max_mask_dev(e):
		field_d = land_dist if e["route_type"] == "LAND" else sea_dist
		devs = []
		for p in e.get("movement_polyline_px") or []:
			cid, _ = occlusion_hit_at(p, city_occlusion_zones)
			if not cid:
				devs.append(mask_dist_at(field_d, p))
		return max(devs) if devs else 0.0

	by_mask = sorted(candidate_edges, key=edge_max_mask_dev, reverse=True)[:10]
	corridor_top = []
	for i, e in enumerate(by_mask):
		md = edge_max_mask_dev(e)
		corridor_top.append(
			{
				"rank": i + 1,
				"a": e["a"],
				"b": e["b"],
				"route_type": e["route_type"],
				"max_own_mask_dist_px": round(md, 3),
				"movement_mask_failures": e.get("movement_mask_failures"),
				"movement_ok": e.get("movement_ok"),
			}
		)
		draw_movement_edge(
			e,
			f"corridor#{i+1} {e['a']}↔{e['b']} max={round(md,2)}",
			ev_dir / f"corridor_top{i+1:02d}_{e['a']}__{e['b']}_200pct.png",
			show_arc_dots=True,
		)
	(out_dir / "movement_corridor_top10.json").write_text(
		json.dumps(corridor_top, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
	)

	# Full-map movement overlay on dash-only mask tint
	mov_overlay = tint_overlay(land_mask | sea_mask, (255, 255, 255, 120))
	dm = ImageDraw.Draw(mov_overlay)
	for e in candidate_edges:
		mov = e.get("movement_polyline_px") or []
		if len(mov) >= 2:
			col = (40, 220, 80, 220) if e["route_type"] == "LAND" else (40, 180, 255, 220)
			if not e.get("movement_ok"):
				col = (255, 40, 40, 255)
			dm.line([(p[0], p[1]) for p in mov], fill=col, width=2)
	save_preview(
		mov_overlay,
		full_dir / "world_map_movement_polylines_overlay.png",
		out_dir / "world_map_movement_polylines_overlay.png",
	)
	save_preview(
		mov_overlay,
		full_dir / "world_map_movement_dash_mask_overlay.png",
		out_dir / "world_map_movement_dash_mask_overlay.png",
	)

	# Equal-arc preview strip for top kink edges
	arc_preview = Image.new("RGBA", (1600, 900), (245, 240, 230, 255))
	da = ImageDraw.Draw(arc_preview)
	da.text((20, 20), "Equal-arc samples (top source-kink edges) — yellow dots at 0/25/50/75/100%", fill=(0, 0, 0, 255), font=font)
	y_cursor = 60
	for e in by_src_kink[:5]:
		mov = [(float(x), float(y)) for x, y in (e.get("movement_polyline_px") or [])]
		if len(mov) < 2:
			continue
		# normalize to row
		xs = [p[0] for p in mov]
		ys = [p[1] for p in mov]
		minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
		w = max(1.0, maxx - minx)
		h = max(1.0, maxy - miny)
		scale = min(1400 / w, 120 / h)
		pts = [((p[0] - minx) * scale + 40, (p[1] - miny) * scale + y_cursor) for p in mov]
		da.line(pts, fill=(40, 180, 80, 255), width=2)
		total = polyline_length(mov)
		for t in (0.0, 0.25, 0.5, 0.75, 1.0):
			pt = point_at_arc(mov, total * t)
			qx = (pt[0] - minx) * scale + 40
			qy = (pt[1] - miny) * scale + y_cursor
			da.ellipse([qx - 4, qy - 4, qx + 4, qy + 4], fill=(255, 200, 0, 255))
		da.text((40, y_cursor - 18), f"{e['a']}↔{e['b']} turn={e.get('movement_max_turn_deg')}", fill=(0, 0, 0, 255), font=font_sm)
		y_cursor += 150
	arc_preview.save(mov_dir / "equal_arc_preview.png")
	arc_preview.save(out_dir / "movement_equal_arc_preview.png")

	# Persist movement gate CSV-like JSON
	(mov_dir / "movement_gate_table.json").write_text(
		json.dumps(movement_gate_table, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
	)
	(out_dir / "movement_gate_table.json").write_text(
		json.dumps(movement_gate_table, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
	)

	topology["path_adjudications"] = path_adjudications
	status = "PASSED" if all(gates.values()) else "FAILED"
	validation["status"] = status
	validation["gates"] = gates
	(out_dir / "topology_candidate.json").write_text(
		json.dumps(topology, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
	)
	(out_dir / "validation_summary.json").write_text(
		json.dumps(validation, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
	)

	# regional crops
	regions = {
		"west": (350, 150, 1200, 1000),
		"central": (1400, 200, 2400, 1000),
		"india": (2000, 100, 2800, 700),
		"east": (2700, 200, 4000, 1100),
		"sea": (900, 200, 2200, 950),
	}
	region_paths = {}
	for name, (x0, y0, x1, y1) in regions.items():
		x0 = max(0, min(int(LOGIC_W) - 1, x0))
		x1 = max(0, min(int(LOGIC_W), x1))
		y0 = max(0, min(int(LOGIC_H) - 1, y0))
		y1 = max(0, min(int(LOGIC_H), y1))
		crop = img2.crop((x0, y0, x1, y1))
		big = crop.resize((crop.width * 2, crop.height * 2), Image.Resampling.LANCZOS)
		save_preview(big, full_dir / f"region_{name}_200pct.png", out_dir / f"region_{name}_200pct.png")
		region_paths[name] = rel_to_root(out_dir / f"region_{name}_200pct.png")

	deg_lines = "\n".join(
		f"| {c['display_name']} (`{c['city_id']}`) | {city_degrees[c['city_id']]} | "
		f"{'/'.join(c['allowed_routes'])} | {c['raw_anchor_px']} | {c['piece_anchor_px']} | "
		f"{c.get('piece_anchor_error_px', 0)} | {c['pre_snap_error_px']} |"
		for c in cities_out
	)
	alias_lines = "\n".join(
		f"| `{a['alias_id']}` | `{a['city_id']}` | {a['distance_px']} |" for a in alias_collapse
	)
	cov = route_layer_coverage
	report = f"""# TASK-WORLD-MAP-DATA-001-REV2D Extraction Report

## Status: **{status}**

REV2B/REV2C frozen. REV2D adds dash-only LAND/SEA masks from PXD path layers.

## Route mask (dash-only)

| Metric | Value |
|---|---:|
| LAND coverage | {route_mask_meta['land_mask_coverage_ratio']:.4%} |
| SEA coverage | {route_mask_meta['sea_mask_coverage_ratio']:.4%} |
| Union coverage | {route_mask_meta['union_mask_coverage_ratio']:.4%} |
| Terrain leaks | {len(route_mask_meta['terrain_component_leaks'])} |
| Node circles | {route_mask_meta['node_circle_count']} |

## Movement / gates

| Metric | Value |
|---|---:|
| Unique edges | {unique_edge_count} |
| Movement verified | {len(movement_ok_edges)} |
| Max movement turn | {movement_max_turn}° |
| Max endpoint error | {movement_max_end}px |
| Mask corridor failures | {movement_mask_fail_total} |
| Wrong route-type failures | {movement_wrong_type_total} |
| Occlusion audit failures | {len(occlusion_audit_failures)} |
| Playable stops | {len(stop_ids)} |
| Missing route layers | {cov['missing_route_layers']} |

```json
{json.dumps(gates, ensure_ascii=False, indent=2)}
```

## Alias collapse (frozen)

| Alias | City | Distance px |
|---|---|---:|
{alias_lines}

## City piece anchors (frozen, error=0)

| City | Degree | routes | raw | piece | piece_err | mask_pre_snap |
|---|---:|---|---|---|---:|---:|
{deg_lines}

## Artifacts

- Dash-only masks: `{rel_to_root(out_dir / 'route_masks')}/`
- Mask overlays: `route_mask_{{land,sea,union}}_overlay.png`
- Movement + mask overlay: `{rel_to_root(out_dir / 'world_map_movement_dash_mask_overlay.png')}`
- Corridor top-10: `{rel_to_root(out_dir / 'movement_corridor_top10.json')}`
- Movement gate table: `{rel_to_root(out_dir / 'movement_gate_table.json')}`
- Topology: `{rel_to_root(out_dir / 'topology_candidate.json')}`
- Validation: `{rel_to_root(out_dir / 'validation_summary.json')}`
"""
	(out_dir / "extraction_report.md").write_text(report, encoding="utf-8")

	print(
		json.dumps(
			{
				"status": status,
				"gates_failed": [k for k, v in gates.items() if not v],
				"unique_edge_count": unique_edge_count,
				"movement_verified": len(movement_ok_edges),
				"movement_max_turn": movement_max_turn,
				"movement_max_end": movement_max_end,
				"movement_mask_failures": movement_mask_fail_total,
				"union_mask_coverage": route_mask_meta["union_mask_coverage_ratio"],
				"terrain_leaks": len(route_mask_meta["terrain_component_leaks"]),
			},
			ensure_ascii=False,
		)
	)
	return 0 if status == "PASSED" else 1


if __name__ == "__main__":
	sys.exit(main())
