#!/usr/bin/env python3
"""Read-only exported geometry audit for TASK-PLANET-DETAIL-012.

Never imports a Blender generator or starts Godot. Requires NumPy/Pillow from
the bundled Python. A passing asset report is not a performance or visual pass.
The external baseline manifest is recorded before work, not filled in later.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
from visual_006_audit import GLB, logical, normalize, np, sha
from variation_007_audit import Audit, LandSurface, components, function_snapshot, json_safe

ROOT = Path(__file__).resolve().parents[2]
BASELINE = Path("/Users/chengzeyuan/SilkRoadEvidence/planet-detail-012/baseline")
ALLOWED = {"assets/game/lowpoly/planet/terrain.glb", "assets/game/lowpoly/cities/quanzhou.glb",
           "assets/game/lowpoly/vehicles/ship.glb"}
LAND = "spherical_continents_and_biomes"


def read(path):
    return json.loads(Path(path).read_text())


def triangles(primitives):
    return np.concatenate([p["positions"][p["faces"]] for p in primitives])


def position_keys(points, decimals=6):
    return {tuple(row) for row in np.round(points, decimals)}


def triangle_keys(primitives):
    # Cyclic canonicalization preserves winding, unlike sorting all vertices.
    result = Counter()
    for p in primitives:
        material = p["material"].get("name", "")
        for triangle in p["positions"][p["faces"]]:
            vertices = [tuple(row) for row in np.round(triangle, 7)]
            result[(material, min(tuple(vertices[i:] + vertices[:i]) for i in range(3)))] += 1
    return result


def primitive_fingerprint(glb, node_name, material_name, include_indices=True):
    matches = []
    for node in glb.doc["nodes"]:
        if node.get("name") != node_name or "mesh" not in node:
            continue
        for p in glb.doc["meshes"][node["mesh"]]["primitives"]:
            if glb.doc["materials"][p["material"]].get("name") != material_name:
                continue
            h = hashlib.sha256(json.dumps(GLB.transform(node).tolist()).encode())
            for key, index in sorted(p["attributes"].items()):
                data = glb.accessor(index)
                h.update(key.encode()); h.update(str(data.shape).encode()); h.update(data.tobytes())
            if include_indices:
                h.update(glb.accessor(p["indices"]).tobytes())
            h.update(json.dumps(glb.doc["materials"][p["material"]], sort_keys=True).encode())
            matches.append(h.hexdigest())
    return matches


def geometry_inventory(path, audit, label):
    glb = GLB(path)
    ps = glb.primitives()
    points = np.concatenate([p["positions"] for p in ps])
    ts = triangles(ps)
    areas = np.linalg.norm(np.cross(ts[:, 1] - ts[:, 0], ts[:, 2] - ts[:, 0]), axis=1) / 2
    finite = bool(np.isfinite(points).all())
    colors_finite = all(p["color"] is None or np.isfinite(p["color"]).all() for p in ps)
    attribute_finite = all(np.isfinite(glb.accessor(index)).all() for mesh in glb.doc["meshes"]
                           for primitive in mesh["primitives"] for index in primitive["attributes"].values())
    transforms_positive = all(np.linalg.det(GLB.transform(n)[:3, :3]) > 0 for n in glb.doc["nodes"])
    audit.check(label + "_finite_geometry_and_all_vertex_attributes", finite and colors_finite and attribute_finite)
    audit.check(label + "_no_negative_or_singular_node_transform", transforms_positive)
    audit.check(label + "_no_degenerate_triangles", bool(len(areas)) and np.all(areas > 1e-10),
                minimum_area=float(areas.min()), degenerate_count=int(np.sum(areas <= 1e-10)))
    audit.check(label + "_no_texture_dependencies", not glb.doc.get("textures") and not glb.doc.get("images"))
    return glb, ps, {"sha256": sha(path), "bytes": path.stat().st_size, "triangles": len(ts),
                     "mesh_nodes": len({p["name"] for p in ps}), "surfaces": len(ps),
                     "materials": sorted(m.get("name", "") for m in glb.doc.get("materials", [])),
                     "bounds_min": points.min(axis=0), "bounds_max": points.max(axis=0)}


def direction(xy):
    lon, lat = (xy[0] - 2048) * math.tau / 6144, (681.5 - xy[1]) * math.pi / 2400
    return np.array([math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon)])


def pose(points, xy, height=.08):
    up = direction(xy)
    lon = (xy[0] - 2048) * math.tau / 6144
    east = np.array([math.cos(lon), 0, -math.sin(lon)])
    basis = np.column_stack((east, up, np.cross(east, up)))
    return points @ basis.T + up * (11 + height)


class Routes:
    def __init__(self, edges):
        segments = np.array([(a, b) for e in edges for a, b in zip(e["movement_polyline"], e["movement_polyline"][1:])])
        self.a, self.b = segments.transpose(1, 0, 2)
        self.ab = self.b - self.a
        self.sq = np.maximum(np.sum(self.ab * self.ab, axis=1), 1e-20)
        # Match the renderer's <=16 logical-pixel path subdivision. The radial
        # footprint of each rendered chord is the corresponding minor arc.
        arcs = []
        for a, b in segments:
            steps = max(1, math.ceil(np.linalg.norm(b - a) / 16))
            samples = [direction(a + (b - a) * i / steps) for i in range(steps + 1)]
            arcs.extend((a, b) for a, b in zip(samples, samples[1:]) if np.linalg.norm(a - b) > 1e-12)
        self.arcs = np.asarray(arcs)
        self.centers = normalize(self.arcs.mean(axis=1))
        self.radii = np.arccos(np.clip(np.sum(self.arcs[:, 0] * self.centers, axis=1), -1, 1))

    def distances(self, points):
        result = []
        for point in points:
            difference = point - self.a
            t = np.clip(np.sum(difference * self.ab, axis=1) / self.sq, 0, 1)
            result.append(float(np.min(np.linalg.norm(difference - t[:, None] * self.ab, axis=1))))
        return result


def on_arc(p, a, b, normal):
    return (np.sum(np.cross(a, p) * normal, axis=-1) >= -1e-12) & (np.sum(np.cross(p, b) * normal, axis=-1) >= -1e-12)


def point_arc_distance(p, a, b):
    cross = np.cross(a, b)
    normal = normalize(cross)
    signed = np.sum(p * normal, axis=-1)
    projected = normalize(p - signed[..., None] * normal)
    interior = on_arc(projected, a, b, normal) & (np.linalg.norm(cross, axis=-1) > 1e-12)
    endpoint = np.minimum(np.arccos(np.clip(np.sum(p * a, axis=-1), -1, 1)),
                          np.arccos(np.clip(np.sum(p * b, axis=-1), -1, 1)))
    return np.where(interior, np.arcsin(np.clip(abs(signed), 0, 1)), endpoint)


def arc_distances(a, b, c, d):
    ab = normalize(np.cross(a, b)); cd = normalize(np.cross(c, d))
    cross = np.cross(ab, cd)
    intersection = normalize(cross)
    hits = np.zeros(len(c), dtype=bool)
    for p in (intersection, -intersection):
        hits |= (np.linalg.norm(cross, axis=-1) > 1e-12) & on_arc(p, a, b, ab) & on_arc(p, c, d, cd)
    minimum = np.minimum.reduce([point_arc_distance(a, c, d), point_arc_distance(b, c, d),
                                 point_arc_distance(c, a, b), point_arc_distance(d, a, b)])
    return np.where(hits, 0., minimum)


def footprint_clearance(world_triangles, routes):
    """Continuous radial triangle footprint / rendered route chord separation.

    Radial projection maps straight triangle edges and route chords to minor
    great-circle arcs. Test contained route endpoints, arc intersections and
    exact endpoint-to-arc distances; this includes triangle interiors and edge
    interiors. R=11 understates clearance at the higher rendered road surface.
    """
    minimum = math.pi
    nearest_triangle = None
    for index, triangle in enumerate(normalize(world_triangles)):
        center = normalize(triangle.mean(axis=0))
        extent = np.max(np.arccos(np.clip(triangle @ center, -1, 1)))
        center_distances = np.arccos(np.clip(routes.centers @ center, -1, 1))
        candidates = center_distances - routes.radii - extent <= minimum + 1e-10
        if not candidates.any():
            continue
        c, d = routes.arcs[candidates].transpose(1, 0, 2)
        edges = np.cross(triangle, np.roll(triangle, -1, axis=0))
        orientation = edges @ center
        # A vertical wall may collapse to a line in radial projection. Such a
        # degenerate footprint still has edges, but must not contain half Earth.
        if abs(np.linalg.det(triangle)) > 1e-12:
            inward = edges * np.sign(orientation)[:, None]
            if np.any(np.all(c @ inward.T >= -1e-12, axis=1)) or np.any(np.all(d @ inward.T >= -1e-12, axis=1)):
                return {"minimum_world": 0., "triangle_index": index, "method": "radial spherical footprint intersects route"}
        value = min(float(np.min(arc_distances(a, b, c, d))) for a, b in zip(triangle, np.roll(triangle, -1, axis=0)))
        if value < minimum:
            minimum, nearest_triangle = value, index
        if minimum < 1e-12:
            break
    return {"minimum_world": minimum * 11, "triangle_index": nearest_triangle,
            "method": "continuous minor-arc/triangle separation at conservative R=11"}


def changed_triangles(old_ps, new_ps):
    previous = triangle_keys(old_ps)
    result = []
    for p in new_ps:
        for triangle in p["positions"][p["faces"]]:
            vertices = [tuple(row) for row in np.round(triangle, 7)]
            key = (p["material"].get("name", ""), min(tuple(vertices[i:] + vertices[:i]) for i in range(3)))
            if previous[key] > 0:
                previous[key] -= 1
            else:
                result.append(triangle)
    return np.asarray(result)


def frozen(root, baseline, audit):
    manifest = read(baseline / "manifest.json")
    files = manifest["files"]
    copied = [p for p in files if (baseline / p).is_file()]
    audit.check("available_baseline_copies_match_original_manifest", bool(copied) and all(
        sha(baseline / p) == files[p]["sha256"] for p in copied), copies=len(copied))
    frozen_paths = [p for p in files if p.startswith(("scripts/", "data/")) or p in (
        "project.godot", "tools/lowpoly/visual_006_audit.py", "tools/lowpoly/variation_007_audit.py")]
    bad = [p for p in frozen_paths if not (root / p).is_file() or sha(root / p) != files[p]["sha256"]]
    audit.check("rules_all_runtime_scripts_projection_UI_and_project_config_frozen", not bad,
                files=len(frozen_paths), mismatches=bad)
    glbs = {p for p in files if p.endswith(".glb")}
    current = {p.relative_to(root).as_posix() for p in (root / "assets/game/lowpoly").rglob("*.glb")}
    audit.check("no_added_or_removed_lowpoly_GLB", current == glbs,
                added=sorted(current - glbs), removed=sorted(glbs - current))
    changed = [p for p in sorted(glbs) if not (root / p).exists() or sha(root / p) != files[p]["sha256"]]
    audit.check("only_terrain_quanzhou_ship_GLB_may_change", set(changed) <= ALLOWED, changed=changed)
    audit.check("other_15_cities_camel_and_both_water_assets_exact_bytes", not (set(changed) - ALLOWED))
    old = function_snapshot(baseline / "tools/lowpoly/build_planet.py", "biome_at")
    new = function_snapshot(root / "tools/lowpoly/build_planet.py", "biome_at")
    audit.check("biome_at_source_bytes_and_AST_frozen", old["bytes_sha256"] == new["bytes_sha256"]
                and old["ast_sha256"] == new["ast_sha256"])
    old_stats = read(baseline / "assets/game/lowpoly/planet/planet-stats.json")
    stats = read(root / "assets/game/lowpoly/planet/planet-stats.json")
    for key in ["main_rng_state_sha256", "scenery_direction_sha256", "dune_positions_sha256", "coast_reference_sha256"]:
        audit.check(key + "_frozen", bool(old_stats.get(key)) and old_stats[key] == stats.get(key))
    data = root / "data/rulesets/lshu_configurable_v1"
    nodes, edges = read(data / "board_nodes.json")["items"], read(data / "board_edges.json")["items"]
    audit.check("formal_16_cities_47_nodes_50_edges", len(nodes) == 47 and len(edges) == 50
                and sum(n.get("node_type") == "CITY" for n in nodes) == 16)
    return {"manifest_sha256": sha(baseline / "manifest.json"), "changed_GLB": changed,
            "frozen_files": len(frozen_paths)}, nodes, edges, old_stats, stats


def terrain_detail(old_glb, new_glb, old_ps, new_ps, stats, audit, routes):
    # The two existing stone/snow index streams may lose the old Kunlun body;
    # every other old primitive, including land, oasis data, cliffs and dunes,
    # must retain its actual attributes, indices, local pose and material.
    mutable = {"sphere_scenery_stone0", "sphere_scenery_snow0"}
    mismatches = []
    for p in old_ps:
        if p["name"] in mutable or p["name"] == "radial_coastal_cliffs":
            continue
        key = (p["name"], p["material"].get("name", ""))
        if primitive_fingerprint(old_glb, *key) != primitive_fingerprint(new_glb, *key):
            mismatches.append(key)
    audit.check("original_land_oasis_dune_foliage_primitive_data_exact", not mismatches, mismatches=mismatches,
                note="This implementation refines a local coastal sidewall; original land triangles remain exact. Coastal sidewall changes are verified separately, not hidden behind the reference-image hash.")
    prior_components = components([{**p, "name": "original_rock_and_snow"} for p in old_ps if p["name"] in mutable])
    target = np.mean(next(r for r in stats["ranges"] if r["name"] == "kunlun")["points"], axis=0)
    prior = min(prior_components, key=lambda c: np.linalg.norm(logical(c["points"].mean(axis=0)[None])[0] - target))
    audit.check("baseline_Kunlun_identified_from_actual_connected_38_faces", prior["faces"] == 38)
    # Remove the original component by actual triangle positions/material.
    preserved = []
    for p in old_ps:
        if p["name"] not in mutable:
            continue
        near_component = np.min(np.linalg.norm(p["positions"][:, None] - prior["points"][None, :], axis=2), axis=1) < 3e-6
        keep = [f for f in p["faces"] if not np.all(near_component[f])]
        preserved.append({**p, "faces": np.asarray(keep, dtype=int).reshape((-1, 3))})
    audit.check("other_original_33_peaks_2_ridges_and_stone_snow_faces_frozen",
                triangle_keys(preserved) == triangle_keys([p for p in new_ps if p["name"] in mutable]))
    detail = [p for p in new_ps if p["name"] == "detail_012_kunlun"]
    audit.check("new_Kunlun_mesh_present_with_rock_and_snow", len(detail) == 2 and
                {p["material"].get("name") for p in detail} == {"stone0", "snow0"})
    if not detail:
        return {"ready": False}
    points = np.concatenate([p["positions"] for p in detail])
    welded = components(detail)
    audit.check("new_Kunlun_is_one_welded_body", len(welded) == 1, actual_components=len(welded))
    ground = LandSurface(new_ps)
    old_gaps = ground.clearance(prior["points"])
    base = prior["points"][[g is not None and g < -.01 for g in old_gaps]]
    distances_to_new = np.linalg.norm(base[:, None] - points[None, :], axis=2)
    contact_distance = np.min(distances_to_new, axis=1) if len(base) else np.array([])
    audit.check("fourteen_original_skirt_contacts_preserved", len(base) == 14 and np.all(contact_distance < 3e-6),
                actual_contacts=len(base), maximum_position_error=float(max(contact_distance)) if len(base) else None)
    new_base = points[np.argmin(distances_to_new, axis=1)] if len(base) else base
    gaps = ground.clearance(new_base)
    audit.check("Kunlun_actual_skirt_contacts_embedded_in_exported_land", len(gaps) == 14
                and all(g is not None and -.06 <= g <= .001 for g in gaps), actual_gaps=gaps)
    peaks = []
    config = next(r for r in stats["ranges"] if r["name"] == "kunlun")
    old_xy = logical(prior["points"])
    for xy in config["points"]:
        index = int(np.argmin(np.linalg.norm(old_xy - xy, axis=1)))
        peaks.append(prior["points"][index])
    peak_distances = np.min(np.linalg.norm(np.asarray(peaks)[:, None] - points[None, :], axis=2), axis=1)
    audit.check("three_original_peak_positions_and_heights_preserved", np.all(peak_distances < 3e-6),
                maximum_position_error=float(max(peak_distances)))
    snowline = config["snowline_radius"]
    rock = next(p["positions"] for p in detail if p["material"].get("name") == "stone0")
    snow = next(p["positions"] for p in detail if p["material"].get("name") == "snow0")
    shared = position_keys(rock) & position_keys(snow)
    shared_r = np.linalg.norm(np.asarray(list(shared)), axis=1) if shared else np.array([])
    audit.check("snowline_is_shared_cut_without_overlaid_caps", len(shared) >= 4
                and np.max(abs(shared_r - snowline)) < 3e-5
                and np.max(np.linalg.norm(rock, axis=1)) <= snowline + 3e-5
                and np.min(np.linalg.norm(snow, axis=1)) >= snowline - 3e-5,
                shared_vertices=len(shared), snowline_radius=snowline)
    sample_points = np.concatenate([points, triangles(detail).mean(axis=1)])
    distances = routes.distances(logical(sample_points))
    audit.check("Kunlun_route_clearance_at_vertices_and_face_centers", min(distances) >= 80,
                minimum_logical_pixels=min(distances), threshold=80,
                note="Geometric samples, not a proof for arbitrary interior extrema; unchanged footprint and no route intersection are also required.")
    clearance = footprint_clearance(triangles(detail), routes)
    audit.check("Kunlun_complete_changed_footprint_clearance_at_least_0_160_world", clearance["minimum_world"] >= .160, **clearance)
    return {"triangles": sum(len(p["faces"]) for p in detail), "ground_gaps": gaps,
            "minimum_route_distance": min(distances), "continuous_route_clearance": clearance,
            "bounds_min": points.min(axis=0), "bounds_max": points.max(axis=0)}


def harbor_detail(old_glb, new_glb, old_ps, new_ps, stats, audit, routes):
    old_coast = [p for p in old_ps if p["name"] == "radial_coastal_cliffs"]
    new_coast = [p for p in new_ps if p["name"] == "radial_coastal_cliffs"]
    original = triangle_keys(old_coast)
    current = triangle_keys(new_coast)
    removed = original - current
    added = current - original
    audit.check("only_four_local_original_coastal_sidewall_triangles_replaced", sum(removed.values()) == 4 and not added,
                removed=sum(removed.values()), added=sum(added.values()))
    audit.check("original_coast_vertex_attributes_remain_exact", primitive_fingerprint(old_glb, "radial_coastal_cliffs", "coast0", False)
                == primitive_fingerprint(new_glb, "radial_coastal_cliffs", "coast0", False))
    removed_points = np.asarray([v for (_, triangle) in removed for v in triangle])
    removed_xy = logical(removed_points) if len(removed_points) else np.empty((0, 2))
    audit.check("coast_replacement_stays_inside_authorized_east_Quanzhou_patch", len(removed_points) > 0
                and np.all((removed_xy >= [3340, 450]) & (removed_xy <= [3410, 520])),
                actual_bounds=[removed_xy.min(axis=0), removed_xy.max(axis=0)] if len(removed_xy) else None)
    detail = [p for p in new_ps if p["name"] == "detail_012_quanzhou_harbor"]
    audit.check("one_harbor_surface_reuses_existing_stone_material", len(detail) == 1 and detail[0]["material"].get("name") == "stone0")
    if not detail:
        return {"ready": False}
    points = np.concatenate([p["positions"] for p in detail])
    xy = logical(points)
    audit.check("new_harbor_and_paving_actual_bounds_stay_local", np.all((xy >= [3195, 456]) & (xy <= [3402, 538])),
                actual_min=xy.min(axis=0), actual_max=xy.max(axis=0))
    clearance = footprint_clearance(triangles(detail), routes)
    audit.check("entire_harbor_triangle_footprint_clears_routes_by_0_160_world", clearance["minimum_world"] >= .160, **clearance)
    config = stats.get("detail_012", {}).get("quanzhou_harbor", {})
    contacts = config.get("contacts", [])
    audit.check("harbor_contact_metadata_available", bool(contacts))
    groups = components(detail)
    paving = min(groups, key=lambda c: np.linalg.norm(c["logical"] - [3280, 505]))
    ground = LandSurface(new_ps)
    gaps = ground.clearance(paving["points"])
    bottoms = np.asarray([p for p, g in zip(paving["points"], gaps) if g is not None and g < -.002])
    bottom_gaps = [g for g in gaps if g is not None and g < -.002]
    audit.check("paving_is_connected_and_all_actual_bottoms_contact_land", paving["faces"] >= 100
                and len(bottoms) >= 30 and all(g is not None for g in gaps)
                and all(-.008 <= g <= -.004 for g in bottom_gaps),
                actual_bottom_vertices=len(bottoms), actual_bottom_gaps=bottom_gaps,
                top_maximum_gap=max(gaps) if all(g is not None for g in gaps) else None,
                note="Raised city-end paving is a solid ramp with bottoms embedded in land; upper vertices are not expected to lie on the terrain.")
    recorded_bottoms = np.asarray([c["bottom_world"] for c in contacts if c.get("kind") == "paving"])
    actual_match = len(recorded_bottoms) > 0 and all(np.min(np.linalg.norm(points - v, axis=1)) < 3e-6 for v in recorded_bottoms)
    coverage = len(bottoms) > 0 and len(recorded_bottoms) > 0 and all(np.min(np.linalg.norm(recorded_bottoms - v, axis=1)) < 3e-6 for v in bottoms)
    audit.check("paving_contact_records_resolve_to_actual_vertices_and_cover_bottoms", actual_match and coverage)
    pile_records = [c for c in contacts if c.get("kind") == "pile"]
    pile_evidence = []
    for record in pile_records:
        group = min(groups, key=lambda c: np.linalg.norm(c["logical"] - record["logical"]))
        radii = np.linalg.norm(group["points"], axis=1)
        floor = group["points"][radii <= radii.min() + 3e-6]
        support = ground.clearance(floor)
        on_land = all(v is not None for v in support)
        on_sea = all(v is None for v in support)
        passed = group["faces"] == 12 and len(floor) == 4 and np.linalg.norm(group["logical"] - record["logical"]) < .01
        passed &= (on_land and all(-.022 < v < -.014 for v in support)) or (on_sea and float(radii.min()) < 11.01)
        passed &= float(radii.max()) > float(config["dock_top_radius"])
        pile_evidence.append({"logical": group["logical"], "actual_vertices": len(group["points"]),
                              "bottom_radius": float(radii.min()), "top_radius": float(radii.max()),
                              "actual_land_gaps": support, "submerged_base": on_sea, "passed": bool(passed)})
    audit.check("four_actual_piles_embed_in_land_or_below_water_and_support_deck", len(pile_evidence) == 4 and all(p["passed"] for p in pile_evidence),
                piles=pile_evidence, note="Sea-side base is submerged through the ocean shell; the project has no modeled seabed, so this is not a seabed-contact claim.")
    banks = [c for c in groups if c["faces"] > 20 and np.linalg.norm(c["points"], axis=1).max() < 11.081]
    audit.check("refined_bank_identified_as_connected_low_coastal_body", len(banks) == 1)
    bank = banks[0] if banks else {"points": np.empty((0, 3))}
    top_edges = np.asarray(config.get("coastline_top_world_edges", []))
    top_points = top_edges.reshape((-1, 3)) if top_edges.size else np.empty((0, 3))
    audit.check("refined_bank_keeps_actual_original_coast_top_endpoints", len(top_points) >= 4
                and all(np.min(np.linalg.norm(removed_points - p, axis=1)) < 3e-6 for p in top_points)
                and len(bank["points"]) > 0 and all(np.min(np.linalg.norm(bank["points"] - p, axis=1)) < 3e-6 for p in top_points),
                unique_top_endpoints=len(position_keys(top_points)))
    return {"continuous_route_clearance": clearance, "removed_original_triangles": sum(removed.values()),
            "new_triangles": sum(len(p["faces"]) for p in detail), "actual_logical_min": xy.min(axis=0),
            "actual_logical_max": xy.max(axis=0), "paving_bottom_gaps": bottom_gaps, "piles": pile_evidence}


def city_detail(old_ps, new_ps, nodes, land, audit, routes):
    old = np.concatenate([p["positions"] for p in old_ps])
    new = np.concatenate([p["positions"] for p in new_ps])
    audit.check("Quanzhou_footprint_ground_and_height_bounds_preserved", np.max(abs(old.min(axis=0) - new.min(axis=0))) < 2e-5
                and np.max(abs(old.max(axis=0) - new.max(axis=0))) < 2e-5)
    node = next(n for n in nodes if n.get("id") == "quanzhou")
    xy = np.asarray(node["map_position"]) + [0, -85]
    old_floor = old[abs(old[:, 1] - old[:, 1].min()) < 2e-5]
    floor = new[abs(new[:, 1] - new[:, 1].min()) < 2e-5]
    audit.check("Quanzhou_original_foundation_contact_vertices_preserved", position_keys(old_floor) <= position_keys(floor))
    ground = LandSurface(land)
    def floor_samples(ps, vertices):
        ts = triangles(ps)
        bottom = ts[np.all(abs(ts[:, :, 1] - vertices[:, 1].min()) < 2e-5, axis=1)]
        # Triangle barycenters are points on the actual bottom surface, unlike
        # a guessed AABB center; vertices alone only sample the curved gap rim.
        return np.concatenate((vertices, bottom.mean(axis=1)))
    old_gaps = ground.clearance(pose(floor_samples(old_ps, old_floor), xy))
    gaps = ground.clearance(pose(floor_samples(new_ps, floor), xy))
    supported = all(g is not None for g in gaps)
    audit.check("Quanzhou_actual_foundation_support_not_worse_than_baseline", supported
                and -.01 <= min(gaps) <= .02
                and max(gaps) <= max(old_gaps) + 3e-5, actual_gaps=gaps, baseline_gaps=old_gaps)
    changed = changed_triangles(old_ps, new_ps)
    clearance = footprint_clearance(pose(changed.reshape((-1, 3)), xy).reshape((-1, 3, 3)), routes) if len(changed) else {"minimum_world": None}
    audit.check("Quanzhou_changed_triangle_footprints_clear_routes_by_0_160_world", clearance["minimum_world"] is not None
                and clearance["minimum_world"] >= .160, changed_triangles=len(changed), **clearance)
    return {"city_visual_logical": xy, "actual_foundation_gaps": gaps,
            "route_clearance": clearance, "note": "Flat foundation retains baseline curvature gap; no claim that every foundation edge touches a curved sphere. Only new/changed triangles are subject to the new clearance target."}


def ship_detail(old_ps, new_ps, water_ps, actor_path, audit):
    old = np.concatenate([p["positions"] for p in old_ps])
    new = np.concatenate([p["positions"] for p in new_ps])
    audit.check("ship_fore_aft_ground_and_mast_height_bounds_preserved", np.max(abs(old.min(axis=0)[1:] - new.min(axis=0)[1:])) < 3e-6
                and np.max(abs(old.max(axis=0)[1:] - new.max(axis=0)[1:])) < 3e-6,
                old_min=old.min(axis=0), old_max=old.max(axis=0), new_min=new.min(axis=0), new_max=new.max(axis=0))
    audit.check("ship_width_refinement_does_not_rescale_model", abs(np.ptp(new[:, 0]) / np.ptp(old[:, 0]) - 1) < .001,
                old_width=float(np.ptp(old[:, 0])), new_width=float(np.ptp(new[:, 0])), relative_tolerance=.001)
    audit.check("ship_sail_node_and_player_accent_material_contract", sum(p["name"] == "sail" for p in new_ps) == 1
                and any(p["material"].get("name", "").startswith("player_accent") for p in new_ps))
    # The runtime source is frozen by the manifest. These amplitudes match its
    # full ranges; use independent maxima (more conservative than phase samples).
    source = actor_path.read_text()
    markers = ["const SHIP_Y := 0.035", "0.015 if transport == GameData.Transport.CAMEL else 0.045",
               "sin(clock * 0.71) * 0.006", "sin(clock * 0.58 + 1.0) * 0.012"]
    audit.check("ship_motion_amplitudes_and_root_match_bound_calculation", all(x in source for x in markers))
    honey = np.concatenate([p["positions"] for p in new_ps if p["material"].get("name") == "deck_honey_wood"])
    sea = max(np.linalg.norm(p["positions"], axis=1).max() for p in water_ps)
    # Imported Compatibility meshes have shown small vertex quantization.
    # Reserve 0.0006 world units beyond the GLB sea radius; actual imported-mesh runtime
    # checks and screenshots remain required before declaring final waterline QA.
    water_upper = sea + .0006
    def lower_y(points, pitch, roll):
        x, y, z = points.T
        return y - abs(x) * math.sin(roll) - abs(y) * (1 - math.cos(pitch) * math.cos(roll)) - abs(z) * math.sin(pitch)
    moving = 11.035 + lower_y(honey, 0, .045) - water_upper
    # Idle body lift is max(0, bounds compensation) + .007 + sin(t)*.003 >= .004.
    idle = 11.035 + .004 + lower_y(honey, .006, .012) - water_upper
    audit.check("ship_all_honey_deck_and_trim_vertices_above_water_during_full_motion", min(moving) > 0 and min(idle) > 0,
                moving_min_margin=float(min(moving)), idle_min_margin=float(min(idle)), water_radius_upper=water_upper)
    return {"honey_vertices": len(honey), "moving_minimum_margin": float(min(moving)),
            "idle_minimum_margin": float(min(idle)), "water_GLB_outer_radius": float(sea),
            "import_quantization_reserve": .0006,
            "scope": "Conservative radial deck/trim lower bound for frozen actor's full pitch/roll/heave range; excludes intentional shrink-to-zero transport-switch presentation. Does not replace Godot imported-mesh and visual waterline QA."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/design/planet-v2/validation/detail-012/geometry-audit.json")
    args = parser.parse_args()
    audit = Audit()
    frozen_result, nodes, edges, old_stats, stats = frozen(args.root, args.baseline, audit)
    old_ps, new_ps, old_glb, new_glb, inventories = {}, {}, {}, {}, {}
    for rel in sorted(ALLOWED):
        label = Path(rel).stem
        old_glb[label] = GLB(args.baseline / rel)
        old_ps[label] = old_glb[label].primitives()
        new_glb[label], new_ps[label], inventories[label] = geometry_inventory(args.root / rel, audit, label)
        inventories[label]["baseline_triangles"] = sum(len(p["faces"]) for p in old_ps[label])
        inventories[label]["triangle_delta"] = inventories[label]["triangles"] - inventories[label]["baseline_triangles"]
        if label != "terrain":
            audit.check(label + "_material_and_surface_count_preserved", len(new_ps[label]) == len(old_ps[label])
                        and sorted(p["material"].get("name") for p in new_ps[label]) == sorted(p["material"].get("name") for p in old_ps[label]))
            audit.check(label + "_material_definitions_unchanged", old_glb[label].doc["materials"] == new_glb[label].doc["materials"])
    delta = sum(i["triangle_delta"] for i in inventories.values())
    audit.check("total_added_triangles_at_most_6000", 0 < delta <= 6000, actual_added=delta)
    water = GLB(args.root / "assets/game/lowpoly/planet/water.glb").primitives()
    audit.check("water_exact_sphere_20480_faces_radius_11_03", sum(len(p["faces"]) for p in water) == 20480
                and max(np.max(abs(np.linalg.norm(p["positions"], axis=1) - 11.03)) for p in water) < 2e-6)
    routes = Routes(edges)
    old_names = {p["name"] for p in old_ps["terrain"]}
    new_names = {p["name"] for p in new_ps["terrain"]}
    audit.check("terrain_has_only_the_two_authorized_new_mesh_nodes", new_names - old_names == {"detail_012_kunlun", "detail_012_quanzhou_harbor"}
                and old_names <= new_names, added=sorted(new_names - old_names), removed=sorted(old_names - new_names))
    audit.check("terrain_existing_material_definitions_unchanged", old_glb["terrain"].doc["materials"] == new_glb["terrain"].doc["materials"])
    detail = terrain_detail(old_glb["terrain"], new_glb["terrain"], old_ps["terrain"], new_ps["terrain"], old_stats, audit, routes)
    harbor = harbor_detail(old_glb["terrain"], new_glb["terrain"], old_ps["terrain"], new_ps["terrain"], stats, audit, routes)
    city = city_detail(old_ps["quanzhou"], new_ps["quanzhou"], nodes, new_ps["terrain"], audit, routes)
    ship = ship_detail(old_ps["ship"], new_ps["ship"], water, args.root / "scripts/ui/lowpoly_map_piece_actor.gd", audit)
    report = {"task": "TASK-PLANET-DETAIL-012", "phase": "exported_geometry_only",
              "created_at_utc": datetime.now(timezone.utc).isoformat(), "audit_source_sha256": sha(Path(__file__)),
              "audit_dependency_sha256": {name: sha(Path(__file__).with_name(name)) for name in ("visual_006_audit.py", "variation_007_audit.py")},
              "frozen": frozen_result, "assets": inventories, "total_triangle_delta": delta,
              "Kunlun": detail, "Quanzhou": city, "harbor": harbor, "ship": ship,
              "checks": audit.checks, "passed": sum(c["passed"] for c in audit.checks),
              "failed": sum(not c["passed"] for c in audit.checks),
              "scope_note": "Exported geometry and frozen data only. Performance, real-window input, actual imported mesh waterline, harbor contact QA and visual detail readability require their own evidence."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(json_safe(report), ensure_ascii=False, indent=2))
    print("DETAIL_012_GEOMETRY passed=%d failed=%d" % (report["passed"], report["failed"]))
    for check in audit.checks:
        if not check["passed"]:
            print("FAIL:", check["name"])
    return int(report["failed"] > 0)


if __name__ == "__main__":
    sys.exit(main())
