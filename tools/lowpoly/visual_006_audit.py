#!/usr/bin/env python3
"""Independent, read-only asset/pixel audit for TASK-PLANET-VISUAL-006.

Requires NumPy and Pillow (available in the bundled Codex Python runtime).
Reads exported GLB bytes; never imports the Blender generator or starts Godot.

Baseline:
  python visual_006_audit.py --snapshot-root <baseline>/files --allow-legacy-colors \
    --output <validation>/baseline-audit.json
New assets and captures:
  python visual_006_audit.py --capture-dir <new-captures> \
    --detail-dir <detail-captures> --output <validation>/audit.json

Exit 1 = a structural/frozen-data contract failed; exit 2 = invalid input/runtime.
Pixel measurements and visual judgments are intentionally separate. No automatic
HSV/HSL target is inferred from the inconsistent review. No image is resized.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from collections import Counter, defaultdict, deque
from datetime import datetime, timezone
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError as exc:
    raise SystemExit("NumPy and Pillow are required; use the bundled Codex Python. " + str(exc))

ROOT = Path(__file__).resolve().parents[2]
VALIDATION = ROOT / "docs/design/planet-v2/validation/visual-006"
DATA = Path("data/rulesets/lshu_configurable_v1")
PLANET = Path("assets/game/lowpoly/planet")
LON_PERIOD = 6144.0
LON_SCALE = math.tau / LON_PERIOD
LAT_SCALE = math.pi / 2400.0
WATER_RADIUS = 11.03
INTERCHANGES = {"rome", "geumseong", "simhala", "jeddah", "quanzhou"}
LAKE_BOXES = {  # Review candidates, not claims about real-world hydrology.
    "black_sea": (812, 1189, 206, 357), "caspian": (1386, 1552, 165, 423),
    "persian_gulf": (1358, 1525, 639, 801), "aral": (1673, 1787, 157, 251),
    "aegean": (411, 598, 228, 380),
}
DEFAULT_REGIONS = [
    {"name": "overview_open_land_context", "image": "00-planet-overview.png", "rect": [430, 430, 480, 470],
     "reference_size": [1440, 900], "note": "Paired original/new overview: open land above Delhi; visually check geometry remains in this rectangle."},
    {"name": "overview_south_ocean_context", "image": "00-planet-overview.png", "rect": [610, 720, 650, 740],
     "reference_size": [1440, 900], "note": "Paired lower sea patch; includes lighting/fresnel, not a raw material color."},
    {"name": "overview_background_context", "image": "00-planet-overview.png", "rect": [920, 420, 960, 460],
     "reference_size": [1440, 900], "note": "Exposed background; a new star may enter this fixed region."},
    {"name": "overview_top_ice_and_atmosphere", "image": "00-planet-overview.png", "rect": [500, 178, 550, 205],
     "reference_size": [1440, 900], "note": "Intentionally mixed ice/rim/background; use to monitor bright cap clipping, not biome average."},
    {"name": "camel_focus_open_land_context", "image": "01-camel-focus.png", "rect": [650, 500, 710, 540],
     "reference_size": [1440, 900], "note": "Fixed local-land comparison beside the player; camera/state still need visual confirmation."},
    {"name": "camel_rotated_open_land_context", "image": "02-camel-rotated-close.png", "rect": [700, 500, 745, 540],
     "reference_size": [1440, 900], "note": "Fixed close-view land region away from the original plaques."},
    {"name": "camel_rotated_inland_water_context", "image": "02-camel-rotated-close.png", "rect": [465, 650, 490, 675],
     "reference_size": [1440, 900], "note": "Fixed inland-water context; geometry/shore changes may legitimately change its composition."},
    {"name": "report_world_desert", "image": "playable-world-view.png", "rect": [400, 320, 460, 360],
     "reference_size": [1280, 720], "note": "Original review ROI includes a city plaque; raw statistics are not pure sand."},
    {"name": "report_world_ocean", "image": "playable-world-view.png", "rect": [420, 530, 470, 560],
     "reference_size": [1280, 720], "note": "Mixed shallow/deep sea; not a single material swatch."},
    {"name": "report_desert_point_neighborhood", "image": "playable-world-view.png", "rect": [327, 297, 334, 304],
     "reference_size": [1280, 720], "note": "7x7 neighborhood around the report's (330,300), not one pixel."},
    {"name": "report_grass_point_neighborhood", "image": "playable-world-view.png", "rect": [597, 427, 604, 434],
     "reference_size": [1280, 720], "note": "May include vegetation/shadow; hue is reported only for chromatic pixels."},
    {"name": "report_forest_point_neighborhood", "image": "playable-world-view.png", "rect": [637, 217, 644, 224],
     "reference_size": [1280, 720], "note": "7x7 neighborhood around the original report coordinate."},
    {"name": "report_camel_shadow", "image": "01-camel-focus.png", "rect": [230, 590, 280, 620],
     "reference_size": [1280, 720], "note": "Review prescribes 1280x720; original file is 1440x900. Do not silently scale or call this a verified shadow ROI."},
]
METHOD_NOTES = [
    "HSV S/V and HSL S/L are distinct fields, all reported in percent. Hue uses a circular mean excluding HSV S<10% pixels.",
    "clipped_R means R==255, not any-channel clipping; near-clipping and all-channel-white are separate metrics.",
    "RGB metrics use decoded 8-bit PNG values without resizing or ICC conversion; image metadata/profile hashes are recorded.",
    "Identical image size and ROI do not prove identical camera, rule state, animation time or occluders. Camera equivalence requires capture evidence.",
    "Fixed baseline parchment-color mask excludes exact/near legacy plaque pixels at identical coordinates only; it is not a semantic terrain mask and does not locate new plaques.",
    "Components come from actual GLB water-sphere topology minus direction-matched continent triangles, not from generator land_at().",
    "Sea-route proximity uses exact point-to-segment distance in original logical coordinates; named lake boxes are review labels only.",
    "Longitude wraps at 6144, not 4096. Logical x range of a complete sphere is [-1024,5120].",
]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentiles(a):
    a = np.asarray(a, dtype=float)
    return {"min": float(np.min(a)), "p10": float(np.percentile(a, 10)), "median": float(np.median(a)),
            "mean": float(np.mean(a)), "p90": float(np.percentile(a, 90)), "max": float(np.max(a))} if a.size else None


class GLB:
    """Small GLB reader: honors accessor strides, normalized COLOR and node TRS."""
    def __init__(self, path):
        blob = Path(path).read_bytes()
        magic, version, length = struct.unpack_from("<4sII", blob)
        if magic != b"glTF" or version != 2 or length != len(blob):
            raise ValueError(f"Invalid GLB header: {path}")
        self.path, self.binary, self.doc = Path(path), None, None
        offset = 12
        while offset < len(blob):
            size, kind = struct.unpack_from("<II", blob, offset)
            chunk = blob[offset + 8:offset + 8 + size]
            if kind == 0x4E4F534A:
                self.doc = json.loads(chunk)
            elif kind == 0x004E4942:
                self.binary = chunk
            offset += 8 + size
        if self.doc is None or self.binary is None:
            raise ValueError(f"Missing JSON/BIN chunk: {path}")

    def accessor(self, index):
        a = self.doc["accessors"][index]
        if "sparse" in a:
            raise ValueError("Sparse accessors are not supported by this audit; do not silently skip them.")
        v = self.doc["bufferViews"][a["bufferView"]]
        if v.get("buffer", 0) != 0:
            raise ValueError("External buffers are not supported.")
        dtype = np.dtype({5120: "i1", 5121: "u1", 5122: "<i2", 5123: "<u2", 5125: "<u4", 5126: "<f4"}[a["componentType"]])
        width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
        start = v.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = v.get("byteStride", dtype.itemsize * width)
        arr = np.ndarray((a["count"], width), dtype=dtype, buffer=self.binary, offset=start,
                         strides=(stride, dtype.itemsize)).copy()
        if a.get("normalized"):
            info = np.iinfo(dtype)
            arr = arr.astype(float) / info.max
            if info.min < 0:
                arr = np.maximum(-1, arr)
        return arr

    @staticmethod
    def transform(node):
        if "matrix" in node:
            return np.asarray(node["matrix"], float).reshape((4, 4), order="F")
        x, y, z, w = node.get("rotation", [0, 0, 0, 1])
        mat = np.eye(4)
        mat[:3, :3] = np.asarray([
            [1 - 2*y*y - 2*z*z, 2*x*y - 2*z*w, 2*x*z + 2*y*w],
            [2*x*y + 2*z*w, 1 - 2*x*x - 2*z*z, 2*y*z - 2*x*w],
            [2*x*z - 2*y*w, 2*y*z + 2*x*w, 1 - 2*x*x - 2*y*y]]) @ np.diag(node.get("scale", [1, 1, 1]))
        mat[:3, 3] = node.get("translation", [0, 0, 0])
        return mat

    def primitives(self):
        nodes = self.doc.get("nodes", [])
        scene = self.doc.get("scenes", [{}])[self.doc.get("scene", 0)]
        roots = scene.get("nodes", [i for i in range(len(nodes)) if all(i not in n.get("children", []) for n in nodes)])
        result = []
        def visit(index, parent, seen):
            if index in seen:
                raise ValueError("Cycle in GLB hierarchy")
            node = nodes[index]
            matrix = parent @ self.transform(node)
            if "mesh" in node:
                mesh = self.doc["meshes"][node["mesh"]]
                for i, p in enumerate(mesh["primitives"]):
                    if p.get("mode", 4) != 4:
                        raise ValueError("Only triangle primitives are supported")
                    positions = self.accessor(p["attributes"]["POSITION"]).astype(float)
                    positions = np.c_[positions, np.ones(len(positions))] @ matrix.T
                    positions = positions[:, :3] / positions[:, 3, None]
                    indices = self.accessor(p["indices"]).ravel().astype(int) if "indices" in p else np.arange(len(positions))
                    if len(indices) % 3 or np.any(indices >= len(positions)):
                        raise ValueError("Invalid triangle indices")
                    material = self.doc.get("materials", [])[p["material"]] if "material" in p else {}
                    result.append({"name": node.get("name", mesh.get("name", str(index))), "primitive": i,
                                   "positions": positions, "faces": indices.reshape((-1, 3)),
                                   "color": self.accessor(p["attributes"]["COLOR_0"]) if "COLOR_0" in p["attributes"] else None,
                                   "attributes": list(p["attributes"]), "material": material})
            for child in node.get("children", []):
                visit(child, matrix, seen | {index})
        for root in roots:
            visit(root, np.eye(4), set())
        return result


def color_summary(primitives, water_data=False):
    result = []
    for p in primitives:
        c = p["color"]
        item = {"node": p["name"], "primitive": p["primitive"], "vertices": len(p["positions"]),
                "attributes": p["attributes"], "has_COLOR_0": c is not None,
                "material": p["material"].get("name", ""),
                "base_color_factor": p["material"].get("pbrMetallicRoughness", {}).get("baseColorFactor", [1, 1, 1, 1])}
        if c is not None:
            item.update(finite=bool(np.isfinite(c).all()), in_unit_range=bool(((c >= -1e-5) & (c <= 1.00001)).all()),
                        channel_count=c.shape[1], channels=[percentiles(c[:, i]) for i in range(c.shape[1])])
            if c.shape[1] >= 3:
                spread = np.ptp(c[p["faces"], 2], axis=1)
                item["blue_constant_per_triangle_percent"] = float(np.mean(spread < 1e-5) * 100)
                if water_data:
                    item["foam_nonzero_percent"] = float(np.mean(c[:, 1] > 1e-5) * 100)
        result.append(item)
    return result


def normalize(a):
    return a / np.maximum(np.linalg.norm(a, axis=-1, keepdims=True), 1e-20)


def logical(a):
    n = normalize(np.asarray(a))
    return np.stack((2048 + np.arctan2(n[:, 0], n[:, 2]) / LON_SCALE,
                     681.5 - np.arcsin(np.clip(n[:, 1], -1, 1)) / LAT_SCALE), axis=1)


def direction_mesh(primitives):
    lookup, directions, triangles = {}, [], []
    for p in primitives:
        ids = []
        for d in normalize(p["positions"]):
            # Matching a shared base ico direction across float32 radial heights.
            key = tuple(np.rint(d * 10000).astype(int))
            if key not in lookup:
                lookup[key] = len(directions)
                directions.append(d)
            ids.append(lookup[key])
        triangles.extend(np.asarray(ids)[p["faces"]].tolist())
    return lookup, np.asarray(directions), np.asarray(triangles, dtype=int)


def segment_distances(points, edges):
    segments = [(a, b) for e in edges if e["route_type"] == "SEA"
                for a, b in zip(e["movement_polyline"], e["movement_polyline"][1:])]
    if not segments:
        return np.full(len(points), np.inf)
    a, b = np.asarray(segments, float).transpose((1, 0, 2))
    ab = b - a
    denom = np.maximum(np.sum(ab * ab, axis=1), 1e-20)
    result = []
    for start in range(0, len(points), 128):
        p = points[start:start + 128]
        best = np.full(len(p), np.inf)
        for wrap in (-LON_PERIOD, 0, LON_PERIOD):
            delta = p[:, None, :] + np.array([wrap, 0]) - a
            t = np.clip(np.sum(delta * ab, axis=2) / denom, 0, 1)
            dist = np.sqrt(np.sum((delta - t[:, :, None] * ab) ** 2, axis=2))
            best = np.minimum(best, np.min(dist, axis=1))
        result.extend(best.tolist())
    return np.asarray(result)


def geometry_summary(snapshot_root, add_check, legacy):
    water = GLB(snapshot_root / PLANET / "water.glb").primitives()
    terrain = GLB(snapshot_root / PLANET / "terrain.glb").primitives()
    points = np.concatenate([p["positions"] for p in water])
    radii = np.linalg.norm(points, axis=1)
    add_check("water_radius_11_03", bool(np.isfinite(points).all() and np.max(np.abs(radii - WATER_RADIUS)) <= .002))
    lo, hi = np.min(points, axis=0), np.max(points, axis=0)
    add_check("water_spans_complete_globe", bool(np.all(np.abs(lo + WATER_RADIUS) < .002) and np.all(np.abs(hi - WATER_RADIUS) < .002)))
    w_lookup, directions, faces = direction_mesh(water)
    incidence = defaultdict(list)
    degenerate = 0
    for i, face in enumerate(faces):
        degenerate += len(set(face)) != 3
        for a, b in zip(face, np.roll(face, -1)):
            incidence[tuple(sorted((int(a), int(b))))].append(i)
    euler = len(directions) - len(incidence) + len(faces)
    add_check("water_closed_two_face_edges", all(len(v) == 2 for v in incidence.values()) and degenerate == 0)
    add_check("water_euler_two", euler == 2)
    colors = {"terrain": color_summary(terrain), "water": color_summary(water, water_data=True)}
    for name, summaries in colors.items():
        add_check(name + "_COLOR_0_present", all(s["has_COLOR_0"] for s in summaries), "warning" if legacy else "error")
        for s in summaries:
            if s["has_COLOR_0"]:
                add_check(f"{name}_{s['node']}_{s['primitive']}_COLOR_0_valid", s["finite"] and s["in_unit_range"])
    available = [p["color"] for p in water if p["color"] is not None]
    if available:
        c = np.concatenate(available)
        add_check("water_data_R_has_shallow_and_deep_range", bool(np.ptp(c[:, 0]) > .2))
        add_check("water_data_G_has_foam_and_nonfoam", bool(np.any(c[:, 1] > .01) and np.any(c[:, 1] < .01)))
        add_check("water_data_B_is_constant_within_each_face", all(s.get("blue_constant_per_triangle_percent", 0) > 99.99 for s in colors["water"]))
    land = [p for p in terrain if p["name"].startswith("spherical_continents_and_biomes")]
    if not land:
        raise ValueError("Cannot identify continent surface node 'spherical_continents_and_biomes'; do not count props as land.")
    face_keys = {tuple(sorted(face)): i for i, face in enumerate(faces)}
    land_indices, unmatched, direction_fallbacks = set(), 0, 0
    for p in land:
        vertex_ids = []
        for direction in normalize(p["positions"]):
            key = tuple(np.rint(direction * 10000).astype(int))
            index = w_lookup.get(key)
            if index is None:
                # Float32 positions at different radii can straddle a rounding
                # bin. Verify the nearest angular direction, not just its bin.
                candidate = int(np.argmax(directions @ direction))
                if np.linalg.norm(directions[candidate] - direction) < 1e-5:
                    index = candidate
                    direction_fallbacks += 1
            vertex_ids.append(index if index is not None else -1)
        for face in p["faces"]:
            ids = [vertex_ids[v] for v in face]
            found = face_keys.get(tuple(sorted(ids)))
            if found is None:
                unmatched += 1
            else:
                land_indices.add(found)
    add_check("continent_faces_match_water_base_mesh", unmatched == 0)
    adjacency = [[] for _ in faces]
    for linked in incidence.values():
        for a in linked:
            adjacency[a].extend(b for b in linked if b != a)
    centers = normalize(directions[faces].sum(axis=1))
    coords = logical(centers)
    edges = json.loads((snapshot_root / DATA / "board_edges.json").read_text())["items"]
    sea_distance = segment_distances(coords, edges)
    unseen = set(range(len(faces))) - land_indices
    components = []
    while unseen:
        first = min(unseen)
        unseen.remove(first)
        queue, members = deque([first]), []
        while queue:
            f = queue.popleft()
            members.append(f)
            for neighbor in adjacency[f]:
                if neighbor in unseen:
                    unseen.remove(neighbor)
                    queue.append(neighbor)
        xy = coords[members]
        median = np.median(xy, axis=0)
        labels = [name for name, (x0, x1, y0, y1) in LAKE_BOXES.items() if x0 <= median[0] <= x1 and y0 <= median[1] <= y1]
        seed_count = int(np.sum(sea_distance[members] < 16))
        components.append({"faces": len(members), "median_logical": median.tolist(),
                           "bbox_logical": [xy.min(axis=0).tolist(), xy.max(axis=0).tolist()],
                           "crosses_longitude_seam": bool(np.ptp(xy[:, 0]) > LON_PERIOD / 2),
                           "sea_route_supported_face_count": seed_count, "review_whitelist_candidate_labels": labels})
    components.sort(key=lambda c: (-c["faces"], c["median_logical"][0]))
    registered = set()
    for component in components:
        labels = [name for name in component["review_whitelist_candidate_labels"] if name not in registered]
        component["primary_lake_labels"] = labels
        registered.update(labels)
        component["unseeded_unlisted_small_fragment"] = bool(component["faces"] <= 6 and not component["sea_route_supported_face_count"] and not labels)
    small = [c for c in components if c["unseeded_unlisted_small_fragment"]]
    cliffs = [p for p in terrain if p["name"].startswith("radial_coastal_cliffs")]
    cliff_heights = np.concatenate([np.linalg.norm(p["positions"], axis=1) - WATER_RADIUS for p in cliffs]) if cliffs else np.array([])
    return {"water_sha256": sha(snapshot_root / PLANET / "water.glb"), "terrain_sha256": sha(snapshot_root / PLANET / "terrain.glb"),
            "water_radius": percentiles(radii), "water_bbox": [lo.tolist(), hi.tolist()],
            "water_topology": {"vertices_direction_welded": len(directions), "edges": len(incidence), "faces": len(faces),
                               "euler": euler, "edge_incidence_histogram": dict(Counter(map(len, incidence.values()))), "degenerate_faces": int(degenerate)},
            "colors": colors, "land_face_count": len(land_indices), "unmatched_land_faces": unmatched,
            "float32_direction_matching_fallback_count": direction_fallbacks,
            "water_component_count": len(components), "unseeded_unlisted_small_component_count": len(small),
            "unseeded_unlisted_small_face_count": sum(c["faces"] for c in small), "components": components,
            "small_components_preserved_with_sea_route_support": [c for c in components if c["faces"] <= 6 and c["sea_route_supported_face_count"]],
            "primary_lake_face_counts": {name: c["faces"] for c in components for name in c["primary_lake_labels"]},
            "coastal_cliff_vertices_above_water": percentiles(cliff_heights[cliff_heights > 0]),
            "cliff_note": "Counts actual exported vertices incl. triangulation duplicates; positive subset is a descriptive height distribution, not deduplicated cliff tops."}


def pixel_metrics(rgb):
    rgb = np.asarray(rgb).reshape((-1, 3))
    if not len(rgb):
        return {"pixels": 0}
    values = rgb.astype(float) / 255
    high, low = values.max(axis=1), values.min(axis=1)
    delta = high - low
    sat_v = np.divide(delta, high, out=np.zeros_like(high), where=high > 0)
    lightness = (high + low) / 2
    denom = 1 - np.abs(2 * lightness - 1)
    sat_l = np.divide(delta, denom, out=np.zeros_like(high), where=denom > 1e-10)
    hue = np.zeros(len(values))
    maximum = values.argmax(axis=1)
    nonzero = delta > 1e-10
    for channel, other_a, other_b, offset in [(0, 1, 2, 0), (1, 2, 0, 2), (2, 0, 1, 4)]:
        mask = nonzero & (maximum == channel)
        hue[mask] = ((values[mask, other_a] - values[mask, other_b]) / delta[mask] + offset) * 60
    hue %= 360
    chromatic = sat_v >= .1
    angle = np.deg2rad(hue[chromatic])
    circular = float(np.rad2deg(np.arctan2(np.sin(angle).mean(), np.cos(angle).mean())) % 360) if len(angle) else None
    linear = np.where(values <= .04045, values / 12.92, ((values + .055) / 1.055) ** 2.4)
    result = {"pixels": len(rgb), "mean_rgb_8bit": rgb.mean(axis=0).tolist(),
              "HSV_S_percent": percentiles(sat_v * 100), "HSV_V_percent": percentiles(high * 100),
              "HSL_S_percent": percentiles(sat_l * 100), "HSL_L_percent": percentiles(lightness * 100),
              "hue_circular_mean_degrees": circular, "hue_chromatic_pixel_percent": float(chromatic.mean() * 100),
              "mean_rgb_brightness_0_255": float(rgb.mean()),
              "linear_rec709_luminance_0_1": percentiles(linear @ np.array([.2126, .7152, .0722])),
              "clipped_R_percent": float(np.mean(rgb[:, 0] == 255) * 100),
              "clipped_G_percent": float(np.mean(rgb[:, 1] == 255) * 100),
              "clipped_B_percent": float(np.mean(rgb[:, 2] == 255) * 100),
              "clipped_any_channel_percent": float(np.mean(np.any(rgb == 255, axis=1)) * 100),
              "clipped_all_channels_percent": float(np.mean(np.all(rgb == 255, axis=1)) * 100),
              "near_clip_any_channel_ge250_percent": float(np.mean(np.any(rgb >= 250, axis=1)) * 100)}
    average = result["mean_rgb_8bit"]
    result["B_over_R_of_mean_rgb"] = average[2] / average[0] if average[0] else None
    return result


def image_info(path):
    with Image.open(path) as im:
        info = {"size": list(im.size), "mode": im.mode, "sha256": sha(path),
                "icc_profile_sha256": hashlib.sha256(im.info["icc_profile"]).hexdigest() if im.info.get("icc_profile") else None,
                "png_gamma": im.info.get("gamma"), "png_srgb_intent": im.info.get("srgb")}
        return np.asarray(im.convert("RGB")), info


def screenshot_summary(capture_dir, baseline, regions, add_check):
    base_dir = baseline / "files/docs/design/planet-v2/runtime-captures"
    files, images = {}, {}
    for old in sorted(base_dir.glob("*.png")):
        new = capture_dir / old.name
        if not new.is_file():
            files[old.name] = {"status": "missing_new_capture"}
            continue
        before, old_info = image_info(old)
        after, new_info = image_info(new)
        equal_size = old_info["size"] == new_info["size"]
        add_check("capture_dimensions_" + old.name, equal_size)
        files[old.name] = {"baseline": old_info, "current": new_info, "same_dimensions": equal_size,
                          "identical_bytes": old_info["sha256"] == new_info["sha256"],
                          "camera_equivalence": "not_established_by_pixel_audit"}
        images[old.name] = (before, after)
    measurements = []
    for spec in regions:
        name = spec["image"]
        item = dict(spec)
        if name not in images:
            item["status"] = "capture_missing"
            measurements.append(item)
            continue
        before, after = images[name]
        x0, y0, x1, y1 = spec["rect"]
        if min(x0, y0) < 0 or x1 <= x0 or y1 <= y0 or any(x1 > a.shape[1] or y1 > a.shape[0] for a in (before, after)):
            item["status"] = "roi_outside_image_no_clamping"
            measurements.append(item)
            continue
        b, a = before[y0:y1, x0:x1], after[y0:y1, x0:x1]
        calibrated = spec.get("reference_size") == list(reversed(before.shape[:2]))
        item.update(status="measured", reference_canvas_matches_baseline=calibrated,
                    paired_same_size=before.shape == after.shape, baseline_raw=pixel_metrics(b), current_raw=pixel_metrics(a))
        # A fixed baseline mask is applied to both samples; never select only the
        # pixels that look successful in the new image.
        paper = np.max(np.abs(b.astype(int) - np.array([244, 229, 195])), axis=2) <= 2
        keep = ~paper
        for box in spec.get("exclude_rects", []):
            ex0, ey0, ex1, ey1 = box
            keep[max(0, ey0-y0):max(0, min(y1, ey1)-y0), max(0, ex0-x0):max(0, min(x1, ex1)-x0)] = False
        item["baseline_parchment_like_percent"] = float(paper.mean() * 100)
        item["fixed_mask_excluded_percent"] = float((~keep).mean() * 100)
        item["baseline_fixed_mask"] = pixel_metrics(b[keep])
        item["current_fixed_mask"] = pixel_metrics(a[keep])
        item["delta_raw_mean_rgb"] = (a.mean(axis=(0, 1)) - b.mean(axis=(0, 1))).tolist()
        item["new_occluder_equivalence"] = "unverified; current label sizes/positions may differ"
        item["automatic_visual_acceptance"] = "none; color spaces/ROI/camera must be reviewed explicitly"
        measurements.append(item)
    camera_evidence = {"status": "capture_report_missing"}
    old_report = baseline / "files/docs/design/planet-v2/validation/window-gui-report.json"
    new_report = next((p for p in [capture_dir / "report.json", capture_dir / "window-gui-report.json"] if p.is_file()), None)
    if old_report.is_file() and new_report:
        old, new = json.loads(old_report.read_text()), json.loads(new_report.read_text())
        camera_evidence = {"baseline_report_sha256": sha(old_report), "current_report_sha256": sha(new_report),
                           "status": "compared_report_camera_snapshots_only_not_every_image",
                           "camel_camera_exact_match": old.get("camel_camera") == new.get("camel_camera"),
                           "initial_camera_exact_match": old.get("map_initial", {}).get("camera") == new.get("map_initial", {}).get("camera"),
                           "current_report_test_count": len(new.get("checks", [])),
                           "current_report_failures": new.get("failure_count")}
    return {"captures": files, "regions": measurements, "camera_evidence": camera_evidence}


def frozen_summary(snapshot_root, baseline, add_check):
    manifest = json.loads((baseline / "baseline-manifest.json").read_text())
    changed, failed, missing = [], [], []
    for rel, old in manifest["files"].items():
        copied = baseline / old["copy"]
        intact = copied.is_file() and sha(copied) == old["sha256"]
        add_check("baseline_copy_integrity_" + rel, intact)
        p = snapshot_root / rel
        if not p.is_file():
            missing.append(rel)
        elif sha(p) != old["sha256"]:
            changed.append(rel)
        if old["freeze"] and (not p.is_file() or sha(p) != old["sha256"]):
            failed.append(rel)
    add_check("frozen_formal_data_and_rule_code", not failed)
    nodes = json.loads((snapshot_root / DATA / "board_nodes.json").read_text())["items"]
    edges = json.loads((snapshot_root / DATA / "board_edges.json").read_text())["items"]
    cities = json.loads((snapshot_root / DATA / "cities.json").read_text())["items"]
    actual = {c["id"] for c in cities if c["is_transport_interchange"]}
    dual = {n["id"]: n["route_anchors"] for n in nodes if len(n.get("route_anchors", {})) == 2}
    add_check("formal_16_cities_47_nodes_50_edges", (len(cities), len(nodes), len(edges)) == (16, 47, 50))
    add_check("five_contract_interchanges", actual == INTERCHANGES and set(dual) == INTERCHANGES)
    add_check("ten_distinct_land_sea_anchors", all(set(a) == {"LAND", "SEA"} and a["LAND"] != a["SEA"] for a in dual.values()))
    return {"captured_at_utc": manifest["captured_at_utc"], "baseline_manifest_sha256": sha(baseline / "baseline-manifest.json"),
            "frozen_violations": failed, "changed_files": changed, "missing_files": missing,
            "city_count": len(cities), "node_count": len(nodes), "edge_count": len(edges), "dual_anchors": dual,
            "visual_spot_checks_are_not_interchange_contract": ["constantinople", "baghdad", "jeddah", "cairo", "rome"]}


def dynamic_water_summary(detail_dir, add_check):
    """Measure a supplied fixed-camera pair, without calling mixed land/water a swatch."""
    if detail_dir is None:
        return {"status": "not_requested"}
    paths = [detail_dir / "water-t0.png", detail_dir / "water-t2.png"]
    if not all(p.is_file() for p in paths):
        return {"status": "pair_missing", "directory": str(detail_dir.resolve())}
    before, info0 = image_info(paths[0])
    after, info2 = image_info(paths[1])
    same = before.shape == after.shape
    add_check("water_time_pair_same_dimensions", same)
    result = {"status": "measured" if same else "dimension_mismatch", "t0": info0, "t2": info2,
              "nominal_time_separation_seconds": 2,
              "timing_note": "Filename/capture-script interval, not an independently timed GPU timestamp.",
              "camera_note": "Capture script makes no camera call between frames; static region agreement is supporting evidence, not a recovered camera matrix.",
              "regions": []}
    if not same or info0["size"] != [1280, 720]:
        result["status"] = "unsupported_canvas_no_resizing"
        return result
    specs = [
        ("open_water_specular", [390, 250, 460, 320], "Visually checked water-only patch, includes specular lighting; no city/shore/route."),
        ("open_water_dark", [510, 250, 570, 305], "Visually checked water-only patch away from the bright glint; no city/shore/route."),
        ("static_space_control", [100, 300, 180, 420], "Space outside the globe: should not change for this fixed capture pair."),
        ("static_land_context", [420, 470, 510, 535], "Land/trees context, used for temporal stability only, never water color."),
    ]
    for name, box, note in specs:
        x0, y0, x1, y1 = box
        b, a = before[y0:y1, x0:x1], after[y0:y1, x0:x1]
        delta = np.abs(a.astype(int) - b.astype(int))
        result["regions"].append({"name": name, "rect": box, "note": note,
            "t0": pixel_metrics(b), "t2": pixel_metrics(a),
            "mean_absolute_rgb_delta_8bit": float(delta.mean()),
            "changed_pixel_percent": float(np.any(delta > 0, axis=2).mean() * 100),
            "pixel_delta_gt2_percent": float(np.any(delta > 2, axis=2).mean() * 100),
            "max_absolute_channel_delta": int(delta.max())})
    report_path = detail_dir / "report.json"
    if report_path.is_file():
        report = json.loads(report_path.read_text())
        result["capture_report_sha256"] = sha(report_path)
        result["reported_performance"] = report.get("performance")
    result["interpretation_limit"] = "Pixel changes support rendered animation, not perceptual quality, physical waves or performance on other hardware. Static two-frame data cannot establish an animation's full temporal behavior."
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot-root", type=Path, default=ROOT, help="Repository or baseline/files tree to read")
    parser.add_argument("--baseline", type=Path, default=VALIDATION / "baseline")
    parser.add_argument("--capture-dir", type=Path, help="New screenshots; originals are never overwritten")
    parser.add_argument("--detail-dir", type=Path, help="Optional fixed-camera water-t0/t2 pair and local performance report")
    parser.add_argument("--roi-config", type=Path, help="JSON list of explicit image/rect/reference_size definitions")
    parser.add_argument("--allow-legacy-colors", action="store_true", help="Missing COLOR_0 is a warning when measuring the old baseline")
    parser.add_argument("--output", type=Path, default=VALIDATION / "audit.json")
    args = parser.parse_args()
    checks = []
    def add_check(name, passed, severity="error"):
        checks.append({"name": name, "passed": bool(passed), "severity": severity})
    regions = json.loads(args.roi_config.read_text()) if args.roi_config else DEFAULT_REGIONS
    captures = args.capture_dir or args.snapshot_root / "docs/design/planet-v2/runtime-captures"
    report = {"schema": "silkroad.visual006.audit.v1", "created_at_utc": datetime.now(timezone.utc).isoformat(),
              "auditor_sha256": sha(Path(__file__)), "snapshot_root": str(args.snapshot_root.resolve()),
              "capture_dir": str(captures.resolve()), "method_notes": METHOD_NOTES,
              "legacy_color_mode": args.allow_legacy_colors}
    report["frozen"] = frozen_summary(args.snapshot_root, args.baseline, add_check)
    report["geometry"] = geometry_summary(args.snapshot_root, add_check, args.allow_legacy_colors)
    report["pixels"] = screenshot_summary(captures, args.baseline, regions, add_check)
    report["water_time_pair"] = dynamic_water_summary(args.detail_dir, add_check)
    report["checks"] = checks
    report["error_count"] = sum(not c["passed"] and c["severity"] == "error" for c in checks)
    report["warning_count"] = sum(not c["passed"] and c["severity"] == "warning" for c in checks)
    report["structural_passed"] = report["error_count"] == 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"output": str(args.output), "structural_passed": report["structural_passed"],
                      "errors": report["error_count"], "warnings": report["warning_count"],
                      "water_components": report["geometry"]["water_component_count"],
                      "unseeded_small_components": report["geometry"]["unseeded_unlisted_small_component_count"]}, ensure_ascii=False))
    return 1 if report["error_count"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, struct.error) as exc:
        print("VISUAL_006_AUDIT_INPUT_ERROR: " + str(exc), file=sys.stderr)
        sys.exit(2)
