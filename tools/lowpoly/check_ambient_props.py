#!/usr/bin/env python3
"""Read-only placement check against formal routes and the exported planet mesh.

No Blender or Godot process is launched. Uses NumPy and the existing GLB reader.
Checks actual triangle occupancy and radial height, rather than trusting the
plan's city coordinates or running the production generator to validate itself.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import re
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("visual_reader", Path(__file__).with_name("visual_006_audit.py"))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def direction(xy):
    lon, lat = (xy[0] - 2048) * math.tau / 6144, (681.5 - xy[1]) * math.pi / 2400
    return np.array([math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon)])


def lon_lat(ll):
    return [2048 + ll[0] / 360 * 6144, 681.5 - ll[1] / 180 * 2400]


def logical_from_direction(q):
    q = q / np.linalg.norm(q)
    return [2048 + math.atan2(q[0], q[2]) * 6144 / math.tau,
            681.5 - math.asin(q[1]) * 2400 / math.pi]


def contact_samples(surface, xy, root_height, local_feet, yaw=0):
    """Measure the authored contact points after their actual spherical pose."""
    q = direction(xy)
    lon = (xy[0] - 2048) * math.tau / 6144
    east = np.array([math.cos(lon), 0, -math.sin(lon)])
    basis = np.column_stack([east, q, np.cross(east, q)])
    rotation = np.array([[math.cos(yaw), 0, math.sin(yaw)], [0, 1, 0],
                         [-math.sin(yaw), 0, math.cos(yaw)]])
    rows = []
    for local in local_feet:
        world = q * (11 + root_height) + basis @ rotation @ local
        logical = logical_from_direction(world)
        actual = surface.sample(logical)
        rows.append({"logical": logical, "land": actual["land"],
                     "surface_height": actual["height"],
                     "gap_world": float(np.linalg.norm(world) - 11 - actual["height"])})
    return rows


class Surface:
    def __init__(self):
        planet = ROOT / "assets/game/lowpoly/planet"
        water = reader.GLB(planet / "water.glb").primitives()
        terrain = reader.GLB(planet / "terrain.glb").primitives()
        lookup, dirs, faces = reader.direction_mesh(water)
        self.triangles = dirs[faces]
        self.centers = reader.normalize(self.triangles.mean(axis=1))
        self.face_angular_radius = np.max(np.arccos(np.clip(np.sum(self.triangles * self.centers[:, None, :], axis=2), -1, 1)), axis=1)
        self.land = {}
        face_lookup = {tuple(sorted(f)): i for i, f in enumerate(faces)}
        for p in terrain:
            if p["name"] != "spherical_continents_and_biomes":
                continue
            ids = []
            for d in reader.normalize(p["positions"]):
                index = lookup.get(tuple(np.rint(d * 10000).astype(int)))
                if index is None:
                    index = int(np.argmax(dirs @ d))
                    if np.linalg.norm(dirs[index] - d) > 1e-5:
                        raise ValueError("Terrain direction does not match base sphere")
                ids.append(index)
            for f in p["faces"]:
                self.land[face_lookup[tuple(sorted(ids[v] for v in f))]] = p["positions"][f]

    def sample(self, xy):
        q = direction(xy)
        choices = np.argpartition(self.centers @ q, -8)[-8:]
        found = []
        for face in choices:
            tri = self.triangles[face]
            edges = np.cross(tri, np.roll(tri, -1, axis=0))
            signed = (edges @ q) * np.sign(edges @ self.centers[face])
            if np.min(signed) >= -1e-10:
                found.append(face)
        if not found:
            raise ValueError("No spherical triangle contains " + str(xy))
        face = max(found, key=lambda f: self.centers[f] @ q)
        land = face in self.land
        height = .03
        if land:
            tri = self.land[face]
            normal = np.cross(tri[1] - tri[0], tri[2] - tri[0])
            height = float(tri[0] @ normal / (q @ normal) - 11)
        return {"land": land, "height": height, "base_face_id": int(face)}

    def water_envelope(self, xy, radius_world):
        # A conservative cap covers the complete body plus orbit, not only a
        # selected animation frame or a ring that could miss a small island.
        distance = np.arccos(np.clip(self.centers @ direction(xy), -1, 1))
        faces = np.flatnonzero(distance <= math.atan(radius_world / 11.03) + self.face_angular_radius)
        land_faces = [int(f) for f in faces if f in self.land]
        return {"radius_world": radius_world, "covered_base_faces": len(faces),
                "intersecting_land_faces": land_faces, "all_water": not land_faces}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/design/planet-v2/validation/variation-007/ambient-placement-audit.json")
    args = parser.parse_args()
    path = ROOT / "scripts/ui/ambient/placements.json"
    placements = json.loads(path.read_text())
    data = ROOT / "data/rulesets/lshu_configurable_v1"
    nodes = json.loads((data / "board_nodes.json").read_text())["items"]
    edges = json.loads((data / "board_edges.json").read_text())["items"]
    cities = [n for n in nodes if n.get("node_type") == "CITY"]
    segments = np.array([(a, b) for e in edges for a, b in zip(e["movement_polyline"], e["movement_polyline"][1:])])
    a, b = segments.transpose(1, 0, 2)
    ab = b - a
    surface = Surface()
    rows, checks = [], []

    def check(name, passed):
        checks.append({"name": name, "passed": bool(passed)})

    # The public constant is used by runtime camera/clearance checks; this file
    # also supplies offline placement data, so detect divergence explicitly.
    layer_source = (ROOT / "scripts/ui/planet_ambient_layer.gd").read_text()
    rain_match = re.search(r"RAIN_LOGICAL_POSITION\s*:=\s*Vector2\(([\d.]+),\s*([\d.]+)\)", layer_source)
    check("runtime_rain_anchor_matches_offline_placement", rain_match is not None and
          [float(v) for v in rain_match.groups()] == placements["rain_cloud"])

    def sample(label, kind, xy):
        xy = np.asarray(xy, float)
        distances = [np.linalg.norm(xy - n["map_position"]) for n in cities]
        visual_distances = [np.linalg.norm(xy - np.asarray(n["map_position"]) - [0,-85]) for n in cities]
        route = float(np.min(np.linalg.norm(xy-a-np.clip(np.sum((xy-a)*ab, axis=1)/np.sum(ab*ab, axis=1), 0, 1)[:, None]*ab, axis=1)))
        row = {"id": label, "category": kind, "logical": xy.tolist(), **surface.sample(xy),
               "route_distance_logical": route, "city_distance_logical": float(min(distances)),
               "city_visual_distance_logical": float(min(visual_distances)),
               "nearest_city_id": cities[int(np.argmin(distances))]["id"]}
        rows.append(row)
        return row

    for i, point in enumerate(placements["sheep"]):
        r = sample(f"sheep_{i}", "sheep", point)
        check(r["id"]+"_flat_city_protection", r["land"] and 93 < r["city_visual_distance_logical"] < 120 and abs(r["height"]-.08) < .008)
        check(r["id"]+"_route_clearance", r["route_distance_logical"] > 65)
        # All four actual hoof offsets, not only the centre of the sheep.
        feet = [[x,0,z] for x in [-.08,.08] for z in [-.125,.125]]
        r["root_height"] = placements["sheep_ground_heights"][i]
        r["yaw_radians"] = placements["sheep_yaws"][i]
        r["hoof_contacts"] = contact_samples(surface, point, r["root_height"], feet, r["yaw_radians"])
        check(r["id"]+"_four_hooves_grounded", all(v["land"] and -.004 < v["gap_world"] <= .001 for v in r["hoof_contacts"]))

    for i, point in enumerate(placements["moored_boats"]):
        r = sample(f"moored_boat_{i}", "moored_boat", point)
        check(r["id"]+"_water_and_clearance", not r["land"] and r["city_distance_logical"] > 93 and r["route_distance_logical"] > 40)
        # Four sides of the 0.66 x 0.24 hull in the local tangent plane.
        wet = [not surface.sample(np.asarray(point)+[dx, dy])["land"] for dx, dy in [(0,-26),(0,26),(-11,0),(11,0)]]
        r["hull_water_samples"] = wet
        check(r["id"]+"_hull_on_water", all(wet))

    for i, point in enumerate(placements["flags"]):
        r = sample(f"flag_{i}", "flag", point)
        check(r["id"]+"_ground_and_clearance", r["land"] and r["city_visual_distance_logical"] > 93 and r["route_distance_logical"] > 60)
        footprint = [[.035*math.cos(a),0,.035*math.sin(a)] for a in np.linspace(0,math.tau,6,endpoint=False)]
        r["base_contacts"] = contact_samples(surface, point, placements["flag_ground_heights"][i], footprint)
        check(r["id"]+"_base_grounded", all(v["land"] and -.004 < v["gap_world"] <= .001 for v in r["base_contacts"]))
    r = sample("windmill", "windmill", placements["windmill"])
    check("windmill_ground_and_clearance", r["land"] and r["route_distance_logical"] > 60 and r["city_distance_logical"] > 93)
    footprint = [[.3*math.cos(a),0,.3*math.sin(a)] for a in np.linspace(0,math.tau,7,endpoint=False)]
    r["root_height"] = placements["windmill_ground_height"]
    r["foundation_contacts"] = contact_samples(surface, placements["windmill"], r["root_height"], footprint)
    check("windmill_foundation_grounded", all(v["land"] and -.05 < v["gap_world"] <= .001 for v in r["foundation_contacts"]))
    r = sample("rain_cloud", "rain_cloud", placements["rain_cloud"])
    check("rain_cloud_ground_and_clearance", r["land"] and r["route_distance_logical"] > 130 and r["city_distance_logical"] > 130)
    for i, point in enumerate(placements["gull_groups"]):
        r = sample(f"gull_group_{i}", "gull_group", point)
        check(r["id"]+"_offshore", not r["land"] and r["city_distance_logical"] > 100)
    r = sample("whale", "whale", lon_lat(placements["whale_lon_lat"]))
    check("whale_open_water", not r["land"] and r["route_distance_logical"] > 100)
    r["whole_motion_water_envelope"] = surface.water_envelope(r["logical"],1.06*1.15)
    check("whale_body_and_full_orbit_on_water", r["whole_motion_water_envelope"]["all_water"])
    r["motion_plus_shore_margin"] = surface.water_envelope(r["logical"],1.06*1.15+.40)
    r["shore_margin_world"] = .40
    check("whale_full_orbit_plus_shore_margin", r["motion_plus_shore_margin"]["all_water"])
    for i, point in enumerate(placements["ice_lon_lat"]):
        r = sample(f"ice_{i}", "ice_floe", lon_lat(point))
        check(r["id"]+"_water", not r["land"])
    report = {"schema": "silkroad.ambient-placement-audit.v1", "created_at_utc": datetime.now(timezone.utc).isoformat(),
              "method": "Actual GLB spherical-triangle occupancy and radial ray/triangle height; exact distance to formal movement segments. No runtime or production-generator execution.",
              "placement_sha256": sha(path), "terrain_sha256": sha(ROOT/"assets/game/lowpoly/planet/terrain.glb"),
              "rules_sha256": {name: sha(data/name) for name in ["board_nodes.json", "board_edges.json", "cities.json"]},
              "rows": rows, "checks": checks, "failures": sum(not c["passed"] for c in checks)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
    print(json.dumps({"output": str(args.output), "checks": len(checks), "failures": report["failures"]}))
    for c in checks:
        if not c["passed"]:
            print("FAILED", c["name"])
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
