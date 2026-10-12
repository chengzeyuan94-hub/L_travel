#!/usr/bin/env python3
"""Read-only exported-asset/evidence audit for TASK-PLANET-VARIATION-007.

Requires NumPy/Pillow. Imports only the existing read-only GLB reader; never
imports, evaluates or executes build_planet.py. Default assets phase does not
claim visual/performance acceptance. --phase full also requires measured
performance and motion evidence. Use --motion-regions for reviewed image ROIs.
Exit 0: requested phase passed; 1: contract failed; 2: invalid inputs/runtime.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import itertools
import json
import math
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
from visual_006_audit import GLB, logical, normalize, np, Image, sha

ROOT = Path(__file__).resolve().parents[2]
VALIDATION = ROOT / "docs/design/planet-v2/validation/variation-007"
PLANET = Path("assets/game/lowpoly/planet")
GENERATOR = Path("tools/lowpoly/build_planet.py")
DATA = Path("data/rulesets/lshu_configurable_v1")
LAND_NAME = "spherical_continents_and_biomes"
CAPTURE_SOURCES = (
    "assets/game/lowpoly/planet/terrain.glb", "assets/game/lowpoly/planet/water.glb",
    "scripts/ui/lowpoly_board_view.gd", "scripts/ui/lowpoly_map_piece_actor.gd", "scripts/ui/planet_ambient_layer.gd",
    "scripts/ui/ambient/ambient_meshes.gd", "scripts/ui/ambient/ambient_motion.gdshader", "scripts/ui/ambient/placements.json",
    "scripts/ui/shaders/planet_water.gdshader", "tools/lowpoly/variation_007_capture.gd",
)


def read_json(path):
    return json.loads(Path(path).read_text())


def function_snapshot(path, name):
    text = Path(path).read_bytes().decode("utf-8")
    tree = ast.parse(text, filename=str(path))
    functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == name]
    if len(functions) != 1:
        raise ValueError(f"Expected exactly one {name} function in {path}")
    node = functions[0]
    raw = "".join(text.splitlines(keepends=True)[node.lineno - 1:node.end_lineno])
    semantic = ast.dump(node, include_attributes=False)
    return {"line": node.lineno, "end_line": node.end_lineno,
            "bytes_sha256": hashlib.sha256(raw.encode()).hexdigest(),
            "ast_sha256": hashlib.sha256(semantic.encode()).hexdigest()}


def static_configs(path, name):
    """Decode literal lists/dict(...) calls, without executing Python expressions."""
    def literal(node):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "dict" and not node.args:
            if any(k.arg is None for k in node.keywords):
                raise ValueError("Unpacking is not a static configuration")
            return {k.arg: literal(k.value) for k in node.keywords}
        if isinstance(node, (ast.List, ast.Tuple)):
            return [literal(n) for n in node.elts]
        return ast.literal_eval(node)
    for node in ast.parse(Path(path).read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return literal(node.value)
    raise ValueError(f"Missing literal {name} configuration")


class Audit:
    def __init__(self):
        self.checks = []

    def check(self, name, result, **evidence):
        self.checks.append({"name": name, "passed": bool(result), **evidence})
        return bool(result)


def frozen_report(root, baseline, audit):
    manifest = read_json(baseline / "root-baseline.json")
    inventory = read_json(baseline / "terrain-baseline-inventory.json")
    hashes = dict(manifest["files"])
    hashes.update({item["path"]: item["sha256"] for item in inventory})
    integrity = {rel: (baseline / "files" / rel).exists() and sha(baseline / "files" / rel) == expected
                 for rel, expected in hashes.items()}
    audit.check("baseline_snapshots_match_recorded_hashes", all(integrity.values()),
                mismatches=[p for p, valid in integrity.items() if not valid])
    frozen = {rel: expected for rel, expected in manifest["files"].items()
              if rel.startswith(str(DATA) + "/") or rel in ("scripts/ui/planet_geometry.gd", "tools/lowpoly/visual_006_audit.py")}
    results = {rel: (root / rel).exists() and sha(root / rel) == expected for rel, expected in frozen.items()}
    audit.check("frozen_rules_projection_and_existing_auditor_unchanged", all(results.values()),
                files=len(results), mismatches=[p for p, valid in results.items() if not valid])
    old = function_snapshot(baseline / "files" / GENERATOR, "biome_at")
    new = function_snapshot(root / GENERATOR, "biome_at")
    audit.check("biome_at_exact_source_bytes_unchanged", old["bytes_sha256"] == new["bytes_sha256"])
    audit.check("biome_at_ast_unchanged", old["ast_sha256"] == new["ast_sha256"])
    old_stats = read_json(baseline / "files" / PLANET / "planet-stats.json")
    new_stats = read_json(root / PLANET / "planet-stats.json")
    fingerprints = {}
    for key in ["scenery_direction_sha256", "dune_positions_sha256", "coast_reference_sha256"]:
        fingerprints[key] = {"baseline": old_stats.get(key), "current": new_stats.get(key)}
        audit.check(key + "_record_unchanged", bool(old_stats.get(key)) and old_stats.get(key) == new_stats.get(key))
    coast = root / "assets/game/maps/world/world_map_v2_overscan.png"
    audit.check("actual_coast_reference_bytes_match_baseline_fingerprint", coast.exists() and sha(coast) == old_stats["coast_reference_sha256"])
    for key, value in [("scenery_clusters", 218), ("sculpted_dunes", 16), ("water_triangles", 20480)]:
        audit.check("stats_" + key, new_stats.get(key) == old_stats.get(key) == value)
    return {"baseline_manifest_sha256": sha(baseline / "root-baseline.json"), "frozen": results,
            "biome_at": {"baseline": old, "current": new}, "recorded_fingerprints": fingerprints,
            "note": "Generator fingerprints are recorded metadata; exported scenery locations are independently checked below."}


class Directions:
    """Canonical sphere direction IDs, independent of surface/vertex ordering."""
    def __init__(self, primitives):
        self.directions = []
        self.bins = defaultdict(list)
        for p in primitives:
            for point in p["positions"]:
                self.index(point, add=True)
        self.directions = np.asarray(self.directions)

    def index(self, point, add=False):
        normal = normalize(np.asarray(point))
        key = tuple(np.rint(normal * 10000).astype(int))
        for offset in itertools.product((-1, 0, 1), repeat=3):
            candidate_key = tuple(k + d for k, d in zip(key, offset))
            for candidate in self.bins.get(candidate_key, []):
                if np.linalg.norm(self.directions[candidate] - normal) <= 2e-6:
                    return candidate
        if not add:
            raise ValueError(f"Exported land vertex is not an original sphere direction: {normal.tolist()}")
        result = len(self.directions)
        self.directions.append(normal)
        self.bins[key].append(result)
        return result

    def mesh(self, primitives):
        faces, heights = [], defaultdict(list)
        for p in primitives:
            ids = [self.index(v) for v in p["positions"]]
            for index, point in zip(ids, p["positions"]):
                heights[index].append(float(np.linalg.norm(point)))
            for face in p["faces"]:
                a, b, c = (ids[int(i)] for i in face)
                faces.append(min((a, b, c), (b, c, a), (c, a, b)))
        return Counter(faces), heights


def components(primitives):
    """Weld positions, then recover actual triangle-connected components."""
    result = []
    # Material batching may create several primitives in one node.
    groups = defaultdict(list)
    for p in primitives:
        groups[p["name"]].append(p)
    for name, group in groups.items():
        vertex_map, vertices, faces, face_sources = defaultdict(list), [], [], []
        for p in group:
            ids = []
            for point in p["positions"]:
                key = tuple(np.rint(point * 100000).astype(int))
                # Exported material batches can differ by a few float32 ULPs;
                # checking adjacent bins prevents a quantization boundary from
                # falsely disconnecting one shared stone/snow cut edge.
                index = next((i for i in vertex_map.get(key, []) if np.linalg.norm(vertices[i] - point) < 3e-6), None)
                if index is None:
                    for offset in itertools.product((-1, 0, 1), repeat=3):
                        adjacent = tuple(k + d for k, d in zip(key, offset))
                        index = next((i for i in vertex_map.get(adjacent, []) if np.linalg.norm(vertices[i] - point) < 3e-6), None)
                        if index is not None:
                            break
                if index is None:
                    index = len(vertices)
                    vertex_map[key].append(index)
                    vertices.append(point)
                ids.append(index)
            faces.extend(np.asarray(ids)[p["faces"]].tolist())
            face_sources.extend([p.get("source_name", p["name"])] * len(p["faces"]))
        parent = list(range(len(vertices)))
        def find(a):
            while parent[a] != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a
        for face in faces:
            for b in face[1:]:
                parent[find(b)] = find(face[0])
        by_root = defaultdict(list)
        for index, face in enumerate(faces):
            by_root[find(face[0])].append(index)
        for face_ids in by_root.values():
            fs = [faces[i] for i in face_ids]
            ids = sorted({v for face in fs for v in face})
            points = np.asarray(vertices)[ids]
            center = points.mean(axis=0)
            source_points = {}
            for source in {face_sources[i] for i in face_ids}:
                indices = {v for i in face_ids if face_sources[i] == source for v in faces[i]}
                source_points[source] = np.asarray(vertices)[sorted(indices)]
            result.append({"node": name, "points": points, "faces": len(fs), "vertices": len(ids),
                           "triangles": np.asarray(vertices)[np.asarray(fs)],
                           "center": center, "normal": normalize(center), "logical": logical([center])[0],
                           "source_faces": dict(Counter(face_sources[i] for i in face_ids)),
                           "source_points": source_points})
    return result


def match_components(old, new, tolerance):
    unmatched = set(range(len(new)))
    distances = []
    for a in old:
        candidates = [(float(np.linalg.norm(a["normal"] - new[i]["normal"])), i) for i in unmatched
                      if a["faces"] == new[i]["faces"]]
        if not candidates:
            return False, distances
        distance, index = min(candidates)
        distances.append(distance)
        if distance > tolerance:
            return False, distances
        unmatched.remove(index)
    return True, distances


def partition_surface(original, partition):
    """Verify each new face lies inside one original face, with equal per-face area.

    This rejects floating snow overlays, shape changes and missing/extra surface
    area while permitting a material split and a different triangulation order.
    """
    a = original[:, 0]
    u, v = original[:, 1] - a, original[:, 2] - a
    normal = np.cross(u, v)
    original_area = np.linalg.norm(normal, axis=1) * .5
    unit = normal / (original_area[:, None] * 2)
    uu, uv, vv = (np.einsum("ij,ij->i", x, y) for x, y in ((u, u), (u, v), (v, v)))
    denominator = uu * vv - uv * uv
    assigned = np.zeros(len(original))
    matched, plane_errors = 0, []
    for face in partition:
        relative = face[None, :, :] - a[:, None, :]
        pu = np.einsum("ijk,ik->ij", relative, u)
        pv = np.einsum("ijk,ik->ij", relative, v)
        b = (pu * vv[:, None] - pv * uv[:, None]) / denominator[:, None]
        c = (pv * uu[:, None] - pu * uv[:, None]) / denominator[:, None]
        errors = abs(np.einsum("ijk,ik->ij", relative, unit)).max(axis=1)
        inside = (b >= -3e-5).all(axis=1) & (c >= -3e-5).all(axis=1) & (b + c <= 1.00003).all(axis=1)
        cross = np.cross(face[1] - face[0], face[2] - face[0])
        candidates = np.flatnonzero(inside & (errors < 3e-5) & ((normal @ cross) > 0))
        if not len(candidates):
            continue
        index = candidates[np.argmin(errors[candidates])]
        assigned[index] += np.linalg.norm(cross) * .5
        matched += 1
        plane_errors.append(float(errors[index]))
    error = float(abs(assigned - original_area).max())
    return {"passed": matched == len(partition) and error < 2e-5,
            "original_triangles": len(original), "partition_triangles": len(partition),
            "matched_partition_triangles": matched, "original_area": float(original_area.sum()),
            "partition_area": float(assigned.sum()), "maximum_original_face_area_error": error,
            "maximum_plane_error": max(plane_errors, default=None)}


def sampled_distances(points, samples):
    values = []
    for start in range(0, len(points), 128):
        delta = points[start:start + 128, None, :] - samples[None, :, :]
        values.extend(np.sqrt(np.sum(delta * delta, axis=2).min(axis=1)).tolist())
    return np.asarray(values)


class LandSurface:
    """Ray/triangle intersection against actual exported land, not elevation()."""
    def __init__(self, primitives):
        triangles = np.concatenate([p["positions"][p["faces"]] for p in primitives if p["name"].startswith(LAND_NAME)])
        self.a = triangles[:, 0]
        self.e1, self.e2 = triangles[:, 1] - self.a, triangles[:, 2] - self.a
        self.q = np.cross(-self.a, self.e1)
        self.numerator = np.einsum("ij,ij->i", self.e2, self.q)

    def clearance(self, points):
        result = []
        for point in points:
            normal = normalize(point)
            p = np.cross(normal, self.e2)
            det = np.einsum("ij,ij->i", self.e1, p)
            with np.errstate(divide="ignore", invalid="ignore"):
                u = np.einsum("ij,ij->i", -self.a, p) / det
                v = (self.q @ normal) / det
                radius = self.numerator / det
            valid = (abs(det) > 1e-10) & (u >= -1e-6) & (v >= -1e-6) & (u + v <= 1.000001) & (radius > 0)
            result.append(float(np.linalg.norm(point) - radius[valid].max()) if valid.any() else None)
        return result


class ColorSurface:
    """Sample interpolated exported COLOR_0 at a logical ray/mesh intersection."""
    def __init__(self, primitives):
        triangles = np.concatenate([p["positions"][p["faces"]] for p in primitives])
        self.colors = np.concatenate([p["color"][p["faces"]] for p in primitives])
        self.a = triangles[:, 0]
        self.e1, self.e2 = triangles[:, 1] - self.a, triangles[:, 2] - self.a
        self.q = np.cross(-self.a, self.e1)
        self.numerator = np.einsum("ij,ij->i", self.e2, self.q)

    def sample(self, xy):
        lon, lat = (xy[0] - 2048) * math.tau / 6144, (681.5 - xy[1]) * math.pi / 2400
        normal = np.asarray([math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon)])
        cross = np.cross(normal, self.e2)
        det = np.einsum("ij,ij->i", self.e1, cross)
        with np.errstate(divide="ignore", invalid="ignore"):
            u = np.einsum("ij,ij->i", -self.a, cross) / det
            v = (self.q @ normal) / det
            radius = self.numerator / det
        valid = np.flatnonzero((abs(det) > 1e-10) & (u >= -1e-6) & (v >= -1e-6) & (u + v <= 1.000001) & (radius > 0))
        if not len(valid):
            return None
        i = valid[np.argmax(radius[valid])]
        return self.colors[i, 0] * (1 - u[i] - v[i]) + self.colors[i, 1] * u[i] + self.colors[i, 2] * v[i]


def json_safe(value):
    if isinstance(value, np.generic):
        return json_safe(value.item())
    if isinstance(value, np.ndarray):
        return json_safe(value.tolist())
    if isinstance(value, dict):
        return {k: json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(v) for v in value]
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value


def protected_directions(root, directions, old_heights):
    edges = read_json(root / DATA / "board_edges.json")["items"]
    nodes = read_json(root / DATA / "board_nodes.json")["items"]
    route = []
    for edge in edges:
        for a, b in zip(edge["movement_polyline"], edge["movement_polyline"][1:]):
            steps = max(1, math.ceil(math.dist(a, b) / 10))
            route.extend((np.asarray(a) + (np.asarray(b) - a) * t / steps).tolist() for t in range(steps + 1))
    cities = np.asarray([(n["map_position"][0], n["map_position"][1] - 85) for n in nodes if n["node_type"] == "CITY"])
    candidates = [i for i, radii in old_heights.items() if max(abs(r - 11.08) for r in radii) < 2e-5]
    xy = logical(directions[np.asarray(candidates)])
    route_d = sampled_distances(xy, np.asarray(route))
    city_d = sampled_distances(xy, cities)
    return [i for i, rd, cd in zip(candidates, route_d, city_d) if rd < 38.001 or cd < 120.001], len(candidates)


def asset_report(root, baseline, audit):
    old_terrain = GLB(baseline / "files" / PLANET / "terrain.glb")
    terrain = GLB(root / PLANET / "terrain.glb")
    water = GLB(root / PLANET / "water.glb")
    old, new, sea = old_terrain.primitives(), terrain.primitives(), water.primitives()
    points = np.concatenate([p["positions"] for p in sea])
    audit.check("water_glb_bytes_unchanged", sha(root / PLANET / "water.glb") == sha(baseline / "files" / PLANET / "water.glb"))
    audit.check("actual_water_radius_and_full_globe", np.isfinite(points).all()
                and np.max(abs(np.linalg.norm(points, axis=1) - 11.03)) < 2e-5
                and np.max(abs(points.min(axis=0) + 11.03)) < 2e-5 and np.max(abs(points.max(axis=0) - 11.03)) < 2e-5)
    water_triangles = sum(len(p["faces"]) for p in sea)
    audit.check("actual_water_has_20480_triangles", water_triangles == 20480)
    audit.check("terrain_has_no_images_or_textures", not terrain.doc.get("images") and not terrain.doc.get("textures"))
    audit.check("terrain_has_finite_positions_and_color0_on_every_surface", all(
        np.isfinite(p["positions"]).all() and p["color"] is not None and np.isfinite(p["color"]).all()
        and p["color"].shape[0] == len(p["positions"]) and (p["color"] >= -1e-5).all() and (p["color"] <= 1.00001).all() for p in new))
    audit.check("terrain_has_no_negative_or_degenerate_node_scale", all(
        np.linalg.det(GLB.transform(n)[:3, :3]) > 0 and all(s > 0 for s in n.get("scale", [1, 1, 1]))
        for n in terrain.doc.get("nodes", [])))
    canonical = Directions(sea)
    old_faces, old_heights = canonical.mesh([p for p in old if p["name"].startswith(LAND_NAME)])
    new_faces, new_heights = canonical.mesh([p for p in new if p["name"].startswith(LAND_NAME)])
    audit.check("actual_land_face_count_and_oriented_direction_topology_unchanged", bool(old_faces) and old_faces == new_faces,
                baseline_faces=sum(old_faces.values()), current_faces=sum(new_faces.values()))
    protected, flat_candidates = protected_directions(root, canonical.directions, old_heights)
    max_protected_delta = max((max(abs(r - 11.08) for r in new_heights.get(i, [math.inf])) for i in protected), default=math.inf)
    audit.check("original_route_city_protection_vertices_remain_at_11_08", len(protected) > 100 and max_protected_delta < 2e-5,
                protected_unique_directions=len(protected), maximum_radius_error=max_protected_delta)
    old_components, new_components = components(old), components(new)
    original_scenery = [c for c in old_components if c["node"].startswith("sphere_scenery_wood") or
                        (c["node"].startswith("sphere_scenery_stone") and c["faces"] == 20)]
    current_scenery = [c for c in new_components if c["node"].startswith("sphere_scenery_wood") or
                       (c["node"].startswith("sphere_scenery_stone") and c["faces"] == 20)]
    matched, errors = match_components(original_scenery, current_scenery, 2e-5)
    audit.check("actual_218_original_tree_rock_directions_preserved", len(original_scenery) == 218 and matched,
                matched_count=len(errors), maximum_direction_error=max(errors, default=None))
    original_dunes = [c for c in old_components if c["node"].startswith("sphere_scenery_desert1")]
    current_dunes = [c for c in new_components if c["node"].startswith("sphere_scenery_desert1")]
    matched, errors = match_components(original_dunes, current_dunes, 0.002)
    audit.check("actual_16_dunes_keep_footprint_neighborhoods", len(original_dunes) == len(current_dunes) == 16 and matched,
                maximum_center_direction_error=max(errors, default=None), tolerance_radians_approx=0.002,
                note="Radial re-grounding changes mesh centroid slightly; exact anchor fingerprint is checked separately.")
    stats = read_json(root / PLANET / "planet-stats.json")
    surface = LandSurface(new)
    triangles = sum(len(p["faces"]) for p in new)
    old_triangles = sum(len(p["faces"]) for p in old)
    objects = len({p["name"] for p in new})
    audit.check("actual_terrain_triangle_increase_within_2000", 0 < triangles - old_triangles <= 2000,
                baseline=old_triangles, current=triangles, delta=triangles - old_triangles)
    audit.check("terrain_stats_match_exported_triangles_and_nodes", stats.get("terrain_triangles") == triangles and stats.get("terrain_objects") == objects)
    pools = [p for p in new if p["name"].startswith("oasis_pool")]
    pool_colors = ColorSurface(pools) if pools else None
    pool_components = components(pools)
    audit.check("actual_three_disconnected_oasis_pools_exist", len(pool_components) == 3 and all(c["faces"] >= 7 for c in pool_components))
    audit.check("oasis_pools_have_shallow_water_data_color0", bool(pools) and all(
        p["color"] is not None and np.max(abs(p["color"][:, 0])) < 0.002
        and np.ptp(p["color"][:, 1]) > .99 and np.ptp(p["color"][:, 2]) > .99
        and np.max(abs(p["color"][:, 2] * 4 - np.rint(p["color"][:, 2] * 4))) < .002
        and np.max(np.ptp(p["color"][p["faces"], 2], axis=1)) < 0.002 for p in pools))
    oasis_configs = static_configs(root / GENERATOR, "OASES")
    range_configs = static_configs(root / GENERATOR, "RANGES")
    audit.check("literal_configs_describe_three_distinct_oases_and_ranges", len(oasis_configs) == len(range_configs) == 3
                and len({o["name"] for o in oasis_configs}) == 3 and len({r["name"] for r in range_configs}) == 3)
    oasis_evidence = []
    for config in oasis_configs:
        nearest = min(pool_components, key=lambda c: np.linalg.norm(c["logical"] - [config["x"], config["y"]])) if pool_components else None
        distance = float(np.linalg.norm(nearest["logical"] - [config["x"], config["y"]])) if nearest else math.inf
        record = next((o for o in stats.get("oases", []) if o.get("name") == config["name"]), {})
        valid = distance < config["water_radius"] * .5 and record.get("x") == config["x"] and record.get("y") == config["y"]
        local_colors = [p["color"][np.linalg.norm(logical(p["positions"]) - [config["x"], config["y"]], axis=1)
                                        <= config["water_radius"] * 1.5] for p in pools if p["color"] is not None]
        local_colors = np.concatenate(local_colors) if local_colors else np.empty((0, 4))
        # B is a per-face phase code: a small pool need not contain every code.
        # G does need both quiet water and a foaming shore, otherwise a clipped
        # polygon with only rim vertices interpolates foam across the whole pool.
        data_present = len(local_colors) > 0 and np.ptp(local_colors[:, 1]) > .99 and np.ptp(local_colors[:, 2]) > .1
        valid = valid and data_present
        center_color = pool_colors.sample([config["x"], config["y"]]) if pool_colors else None
        outer_samples = [pool_colors.sample([config["x"] + math.cos(i * math.tau / 9) * config["water_radius"] * .97,
                                             config["y"] + math.sin(i * math.tau / 9) * config["water_radius"] * .97])
                         for i in range(9)] if pool_colors else []
        outer_g = [float(c[1]) for c in outer_samples if c is not None]
        audit.check("actual_pool_center_is_quiet_and_outer_bank_foams_" + config["name"], center_color is not None
                    and center_color[1] < .05 and len(outer_g) == 9 and min(outer_g) > .8,
                    interpolated_center_color=center_color.tolist() if center_color is not None else None,
                    interpolated_outer_bank_green=outer_g)
        clearance = surface.clearance(nearest["points"]) if nearest else []
        if nearest:
            valid = valid and np.linalg.norm(nearest["points"], axis=1).min() > 11.03 and record.get("pool_triangles") == nearest["faces"]
        audit.check("oasis_geometry_and_stats_" + config["name"], valid, centroid_distance_logical=distance,
                    actual_foam_and_face_data_present=data_present,
                    actual_color_min=local_colors.min(axis=0).tolist() if len(local_colors) else None,
                    actual_color_max=local_colors.max(axis=0).tolist() if len(local_colors) else None)
        audit.check("oasis_is_above_actual_exported_land_" + config["name"], bool(clearance)
                    and all(c is not None and abs(c - .018) < .0002 for c in clearance),
                    measured_ground_clearance_min=min((c for c in clearance if c is not None), default=None),
                    measured_ground_clearance_max=max((c for c in clearance if c is not None), default=None))
        oasis_evidence.append({"name": config["name"], "expected": [config["x"], config["y"]],
                               "actual_centroid": nearest["logical"].tolist() if nearest else None,
                               "triangles": nearest["faces"] if nearest else 0, "stats": record})
    # Snowline clipping partitions one continuous body across two materials.
    # Weld both before connectivity/peak tests; material boundaries are not
    # disconnected mountain bodies and do not need the old 26-face layout.
    ridge_primitives = [{**p, "name": "stone_and_snow_union", "source_name": p["name"]}
                        for p in new if p["name"].startswith(("sphere_scenery_stone", "sphere_scenery_snow"))]
    stone_snow_union = components(ridge_primitives)
    ridges = [c for c in stone_snow_union if any(
        all(np.linalg.norm(logical(c["points"]) - peak, axis=1).min() < 8 for peak in config["points"])
        for config in range_configs)]
    audit.check("actual_three_connected_ridge_bodies_exist", len(ridges) == 3 and all(c["faces"] >= 26 for c in ridges))
    ridge_before_path = root / "docs/design/planet-v2/validation/variation-007/snowline-pass/before" / PLANET / "terrain.glb"
    mountain_before_path = root / "docs/design/planet-v2/validation/variation-007/original-snow-pass/before/files" / PLANET / "terrain.glb"
    ridge_before = [c for c in components(GLB(ridge_before_path).primitives())
                    if c["node"].startswith("sphere_scenery_stone") and c["faces"] == 26] if ridge_before_path.exists() else []
    range_evidence = []
    for config in range_configs:
        target = np.asarray(config["points"], dtype=float).mean(axis=0)
        nearest = min(ridges, key=lambda c: np.linalg.norm(c["logical"] - target)) if ridges else None
        distance = float(np.linalg.norm(nearest["logical"] - target)) if nearest else math.inf
        record = next((r for r in stats.get("ranges", []) if r.get("name") == config["name"]), {})
        peaks = []
        relative_peaks = []
        skirts = []
        actual_total_triangles = nearest["faces"] if nearest else 0
        snowline_evidence = {}
        if nearest:
            xy = logical(nearest["points"])
            heights = np.linalg.norm(nearest["points"], axis=1) - 11
            clearances = surface.clearance(nearest["points"])
            skirts = [c for c in clearances if c is not None and c < 0]
            for peak in config["points"]:
                candidates = np.flatnonzero(np.linalg.norm(xy - peak, axis=1) < 8)
                index = int(candidates[np.argmax(heights[candidates])]) if len(candidates) else None
                peaks.append(float(heights[index]) if index is not None else None)
                relative_peaks.append(clearances[index] if index is not None else None)
            rock = np.concatenate([ps for name, ps in nearest["source_points"].items() if name.startswith("sphere_scenery_stone")])
            snow_arrays = [ps for name, ps in nearest["source_points"].items() if name.startswith("sphere_scenery_snow")]
            snow = np.concatenate(snow_arrays) if snow_arrays else np.empty((0, 3))
            rock_keys = {tuple(np.rint(p * 100000).astype(int)) for p in rock}
            shared = np.asarray([p for p in snow if tuple(np.rint(p * 100000).astype(int)) in rock_keys])
            snowline = record.get("snowline_radius", math.nan)
            rock_faces = sum(n for source, n in nearest["source_faces"].items() if source.startswith("sphere_scenery_stone"))
            snow_faces = sum(n for source, n in nearest["source_faces"].items() if source.startswith("sphere_scenery_snow"))
            snowline_valid = len(shared) >= 3 and len(snow) > 0 and math.isfinite(snowline)
            snowline_valid = snowline_valid and max(abs(np.linalg.norm(shared, axis=1) - snowline)) < 2e-5
            snowline_valid = snowline_valid and np.linalg.norm(rock, axis=1).max() <= snowline + 2e-5
            snowline_valid = snowline_valid and np.linalg.norm(snow, axis=1).min() >= snowline - 2e-5
            snowline_valid = snowline_valid and record.get("rock_triangles") == rock_faces and record.get("snow_triangles") == snow_faces
            snowline_valid = snowline_valid and record.get("snowline_shared_vertices") == len(shared)
            snowline_evidence = {"shared_vertices": len(shared), "snowline_radius": snowline,
                                 "actual_rock_triangles": rock_faces, "actual_snow_triangles": snow_faces}
        else:
            snowline_valid = False
        valid = distance < 70 and len(peaks) == 3 and all(p is not None and p > .35 for p in peaks)
        valid = valid and all(p is not None and abs(p - h) < .0002 for p, h in zip(relative_peaks, config["heights"]))
        valid = valid and record.get("points") == config["points"] and record.get("triangles") == actual_total_triangles
        audit.check("connected_three_peak_geometry_and_stats_" + config["name"], valid, peak_heights=peaks)
        audit.check("ridge_14_base_vertices_embedded_in_actual_land_" + config["name"], len(skirts) == 14
                    and all(abs(c + .025) < .0002 for c in skirts), measured_base_clearances=skirts)
        audit.check("ridge_rock_and_snow_share_one_radial_snowline_" + config["name"], snowline_valid, **snowline_evidence)
        prior = min(ridge_before, key=lambda c: np.linalg.norm(c["logical"] - target)) if ridge_before else None
        surface_evidence = partition_surface(prior["triangles"], nearest["triangles"]) if prior and nearest else {"passed": False}
        audit.check("ridge_snow_partition_preserves_each_original_rock_face_" + config["name"], surface_evidence["passed"],
                    evidence={k: v for k, v in surface_evidence.items() if k != "passed"})
        range_evidence.append({"name": config["name"], "actual_centroid": nearest["logical"].tolist() if nearest else None,
                               "body_and_snow_triangles": actual_total_triangles, "snowline": snowline_evidence,
                               "partition_of_original_surface": surface_evidence,
                               "peak_heights": peaks, "peak_heights_above_actual_land": relative_peaks, "stats": record})
    mountain_evidence = []
    mountain_before = [c for c in components(GLB(mountain_before_path).primitives())
                       if c["node"].startswith("sphere_scenery_stone") and c["faces"] == 12] if mountain_before_path.exists() else []
    for prior in mountain_before:
        peak = prior["points"][np.argmax(np.linalg.norm(prior["points"], axis=1))]
        candidates = [c for c in stone_snow_union if np.linalg.norm(c["points"] - peak, axis=1).min() < 3e-5]
        evidence = partition_surface(prior["triangles"], candidates[0]["triangles"]) if len(candidates) == 1 else {"passed": False}
        mountain_evidence.append({"original_centroid": prior["logical"].tolist(), "original_peak": peak.tolist(),
                                  "peak_matched_components": len(candidates), **evidence})
    audit.check("all_33_original_mountains_preserve_peak_and_each_original_rock_face", len(mountain_evidence) == 33
                and all(e["passed"] for e in mountain_evidence), actual_original_mountains=len(mountain_evidence),
                maximum_plane_error=max((e.get("maximum_plane_error", math.inf) for e in mountain_evidence), default=None),
                maximum_face_area_error=max((e.get("maximum_original_face_area_error", math.inf) for e in mountain_evidence), default=None))
    return {"terrain_sha256": sha(root / PLANET / "terrain.glb"), "water_sha256": sha(root / PLANET / "water.glb"),
            "terrain_triangles": triangles, "terrain_objects": objects, "water_triangles": water_triangles,
            "old_flat_radius_candidates": flat_candidates, "protected_directions": len(protected),
            "original_scenery": len(original_scenery), "current_scenery_including_oases": len(current_scenery),
            "oases": oasis_evidence, "ranges": range_evidence, "original_mountains": mountain_evidence,
            "snow_partition_reference_hashes": {str(p.relative_to(root)): sha(p) for p in (ridge_before_path, mountain_before_path) if p.exists()},
            "component_inventory": dict(Counter((c["node"] + ":" + str(c["faces"])) for c in new_components))}


def runtime_report(directory, regions_path, audit, root=ROOT):
    performance_path = directory / "performance-report.json"
    vsync_path = directory / "vsync-performance-report.json"
    motion_path = directory / "motion-report.json"
    result = {"visual_judgment": "not inferred from diagnostic state fields", "performance": {}, "motion": {}}
    if any(not p.exists() for p in (performance_path, vsync_path, motion_path)):
        audit.check("runtime_reports_available", False, missing=[str(p) for p in (performance_path, vsync_path, motion_path) if not p.exists()])
        return result
    performance, vsync, motion = read_json(performance_path), read_json(vsync_path), read_json(motion_path)
    for label, document in (("uncapped_performance", performance), ("default_vsync_performance", vsync), ("motion", motion)):
        recorded = document.get("environment", {}).get("source_sha256", {})
        mismatches = [p for p in CAPTURE_SOURCES if not (root / p).exists() or recorded.get(p) != sha(root / p)]
        audit.check(label + "_recording_matches_current_source_and_asset_bytes", not mismatches,
                    required_source_files=len(CAPTURE_SOURCES), mismatches=mismatches)
    samples = performance.get("performance", [])
    default_samples = vsync.get("performance", [])
    audit.check("performance_measured_in_four_views_without_capture_io", performance.get("mode") == "performance" and len(samples) >= 4
                and all(s.get("frames", 0) >= 60 for s in samples))
    audit.check("measured_draw_call_budget_540", bool(samples) and all(s.get("draw_calls_max", math.inf) <= 540 for s in samples))
    audit.check("uncapped_frame_interval_budget", performance.get("environment", {}).get("window_vsync_mode") == 0
                and bool(samples) and all(s.get("median_ms", math.inf) <= 7.5 and s.get("p95_ms", math.inf) <= 15 for s in samples),
                note="Uncapped process_frame wall intervals measure whole-frame throughput, not isolated GPU render time.")
    audit.check("default_vsync_four_views_have_p95_below_15ms", vsync.get("environment", {}).get("window_vsync_mode") == 1
                and len(default_samples) >= 4 and all(s.get("frames", 0) >= 60 and s.get("p95_ms", math.inf) <= 15 for s in default_samples))
    audit.check("default_vsync_draw_call_budget_540", bool(default_samples)
                and all(s.get("draw_calls_max", math.inf) <= 540 for s in default_samples))
    audit.check("whole_world_particle_capacity_below_150", bool(samples) and all(
        0 < s.get("particle_budget", {}).get("whole_world_capacity", math.inf) < 150
        and s.get("particle_budget", {}).get("systems_casting_shadows") == 0 for s in samples + default_samples),
        evidence="Whole-world CPUParticles enumeration; includes actor systems and records reserved capacity, not a visual claim.")
    result["performance"] = {"uncapped": {"report_sha256": sha(performance_path), "environment": performance.get("environment"), "samples": samples},
                             "default_vsync": {"report_sha256": sha(vsync_path), "environment": vsync.get("environment"), "samples": default_samples},
                             "comparison_note": "VSync and uncapped runs use different scheduling settings. Do not present their medians as an identical-setting speedup."}
    roi_configs = read_json(regions_path) if regions_path else {}
    sequence_results = []
    for sequence_id in ("front", "back"):
        entry = next((s for s in motion.get("sequences", []) if s.get("id") == sequence_id), {})
        frame_dir = Path(entry.get("directory", "/path-not-specified"))
        frames = sorted(frame_dir.glob("[0-9][0-9][0-9][0-9].png"))
        audit.check(sequence_id + "_has_continuous_rendered_frames", len(frames) >= 60 and len(frames) == entry.get("frame_count")
                    and all(p.name == f"{i:04}.png" for i, p in enumerate(frames)), actual_frames=len(frames))
        audit.check(sequence_id + "_capture_camera_remained_fixed", bool(entry.get("camera"))
                    and entry.get("camera") == entry.get("end", {}).get("camera"))
        audit.check(sequence_id + "_capture_elapsed_at_least_two_seconds", entry.get("ended_usec", 0) - entry.get("started_usec", 0) >= 2000000)
        rois = roi_configs.get(sequence_id, [])
        measured = []
        if frames and rois:
            # Decode each original frame once, without rescaling or rewriting it.
            decoded = [np.asarray(Image.open(p).convert("RGB")) for p in frames]
            first = decoded[0]
            if any(im.shape != first.shape for im in decoded):
                raise ValueError("Motion frame dimensions changed; do not resize evidence")
            for roi in rois:
                x0, y0, x1, y1 = roi["rect"]
                if not (0 <= x0 < x1 <= first.shape[1] and 0 <= y0 < y1 <= first.shape[0]):
                    raise ValueError("Motion ROI outside original image: " + str(roi))
                base = first[y0:y1, x0:x1].astype(np.int16)
                differences = []
                for current in decoded[1:]:
                    differences.append(float(np.abs(current[y0:y1, x0:x1].astype(np.int16) - base).mean()))
                measured.append({**roi, "maximum_mean_absolute_rgb_difference": max(differences, default=0),
                                 "first_frame_sha256": sha(frames[0]), "last_frame_sha256": sha(frames[-1])})
        changed = [m for m in measured if m["maximum_mean_absolute_rgb_difference"] > 2.0]
        # ROIs must be explicitly reviewed, non-overlapping and assigned to
        # distinct environmental objects. Anchors/timers alone never pass this.
        overlaps = any(max(a["rect"][0], b["rect"][0]) < min(a["rect"][2], b["rect"][2]) and
                       max(a["rect"][1], b["rect"][1]) < min(a["rect"][3], b["rect"][3])
                       for a, b in itertools.combinations(changed, 2))
        object_ids = {r.get("object_id") for r in changed if r.get("object_id")}
        audit.check(sequence_id + "_three_distinct_reviewed_regions_show_pixel_motion", len(object_ids) >= 3 and not overlaps,
                    changed_regions=len(changed), note="Provide --motion-regions; ROI attribution remains a visual review responsibility.")
        sequence_results.append({"id": sequence_id, "frames": len(frames), "regions": measured,
                                 "source_frame_sha256": {p.name: sha(p) for p in frames},
                                 "camera_before": entry.get("camera"), "camera_after": entry.get("end", {}).get("camera")})
    hidden = motion.get("hidden", {})
    hashes = hidden.get("hashes", [])
    audit.check("hidden_31_recorded_pixel_hashes_identical", len(hashes) >= 31 and len(set(hashes)) == 1)
    actual_hashes = []
    for name in ("hidden-0.png", "hidden-30.png"):
        path = directory / "captures" / name
        if path.exists():
            image = Image.open(path)
            actual_hashes.append(hashlib.sha256(image.tobytes()).hexdigest())
    audit.check("hidden_saved_images_confirm_recorded_pixel_hashes", len(actual_hashes) == 2 and bool(hashes) and all(h == hashes[0] for h in actual_hashes))
    before, after = hidden.get("before", {}), hidden.get("after", {})
    audit.check("hidden_ambient_clock_is_actually_unchanged", "clock" in before and before.get("clock") == after.get("clock")
                and hidden.get("viewport_update_disabled") is True)
    result["motion"] = {"report_sha256": sha(motion_path), "sequences": sequence_results,
                        "hidden_decoded_pixel_hashes": actual_hashes, "hidden_clock_before": before.get("clock"), "hidden_clock_after": after.get("clock")}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot-root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=VALIDATION / "baseline")
    parser.add_argument("--phase", choices=("assets", "full"), default="assets")
    parser.add_argument("--runtime-dir", type=Path, default=VALIDATION)
    parser.add_argument("--motion-regions", type=Path, help='JSON {"front":[{"object_id":"...","rect":[x0,y0,x1,y1]}],"back":[...]}')
    parser.add_argument("--output", type=Path, default=VALIDATION / "independent-audit.json")
    args = parser.parse_args()
    audit = Audit()
    report = {"task": "TASK-PLANET-VARIATION-007", "phase": args.phase,
              "generated_at_utc": datetime.now(timezone.utc).isoformat(),
              "method": "Read exported GLB, source AST/literal configuration, frozen baseline and optional raw screenshots. Never execute/import Blender generator.",
              "script_sha256": sha(Path(__file__)), "checks": audit.checks}
    try:
        report["frozen"] = frozen_report(args.snapshot_root, args.baseline, audit)
        report["assets"] = asset_report(args.snapshot_root, args.baseline, audit)
        report["runtime"] = runtime_report(args.runtime_dir, args.motion_regions, audit, args.snapshot_root) if args.phase == "full" else {
            "status": "not_audited_in_asset_phase", "visual_pass": None, "performance_pass": None}
    except Exception as exc:
        report["input_error"] = f"{type(exc).__name__}: {exc}"
    report["passed"] = sum(c["passed"] for c in audit.checks)
    report["failed"] = sum(not c["passed"] for c in audit.checks)
    report["requested_phase_passed"] = report["failed"] == 0 and "input_error" not in report
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(json_safe(report), ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    print(json.dumps({k: report.get(k) for k in ["phase", "passed", "failed", "requested_phase_passed", "input_error"]}, ensure_ascii=False))
    for item in audit.checks:
        if not item["passed"]:
            print("FAIL:", item["name"])
    return 2 if "input_error" in report else (0 if report["requested_phase_passed"] else 1)


if __name__ == "__main__":
    raise SystemExit(main())
