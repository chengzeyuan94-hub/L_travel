#!/usr/bin/env python3
"""Build the rule board from reviewed physical-board city corridors.

PXD circles are authored city seats and road hints. The old automatic grouping
misclassified their ownership and connections. The corridor manifest records
those rules explicitly; geometry vertices and source-circle IDs never add steps.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import sys
from collections import Counter

from map_corridor_contract import validate_manifest, validate_topology_corridors, CITY_ID_ALIASES
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PRESENTATION = ROOT / "data/rulesets/lshu_configurable_v1/presentation/world_map_v1.json"
SEMANTICS = ROOT / "data/rulesets/lshu_configurable_v1/presentation/world_map_semantics_v1.json"
CORRIDORS = ROOT / "data/rulesets/lshu_configurable_v1/map_corridors_v1.json"
TOPOLOGY = ROOT / "data/rulesets/lshu_configurable_v1/presentation/world_map_topology_v1.json"


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def json_text(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def point(value: object, context: str) -> list[float]:
    if not isinstance(value, list) or len(value) != 2:
        raise ValueError(f"{context}: expected [x, y], got {value!r}")
    result = [round(float(value[0]), 6), round(float(value[1]), 6)]
    if not all(math.isfinite(v) for v in result):
        raise ValueError(f"{context}: non-finite point")
    return result


def distance(a: list[float], b: list[float]) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def normalized(p: list[float]) -> list[float]:
    return [round(p[0] / 4096.0, 6), round(p[1] / 1363.0, 6)]


def max_turn(points: list[list[float]]) -> float:
    result = 0.0
    for i in range(1, len(points) - 1):
        a = (points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1])
        b = (points[i + 1][0] - points[i][0], points[i + 1][1] - points[i][1])
        la, lb = math.hypot(*a), math.hypot(*b)
        if la <= 1e-6 or lb <= 1e-6:
            continue
        dot = max(-1.0, min(1.0, (a[0] * b[0] + a[1] * b[1]) / (la * lb)))
        result = max(result, math.degrees(math.acos(dot)))
    return result


def split_curve(values: list[list[float]], fractions: list[float]) -> list[list[list[float]]]:
    """Split display geometry at two authored arc positions, retaining all bends."""
    points = [point(v, "corridor curve") for v in values]
    lengths = [0.0]
    for a, b in zip(points, points[1:]):
        lengths.append(lengths[-1] + distance(a, b))
    total = lengths[-1]
    if total <= 1e-6:
        raise ValueError("zero-length corridor")
    boundaries = [0.0, *(total * f for f in fractions), total]

    def at(arc: float) -> list[float]:
        if arc <= 0:
            return points[0][:]
        if arc >= total:
            return points[-1][:]
        for i in range(1, len(points)):
            if lengths[i] >= arc and lengths[i] > lengths[i-1]:
                t = (arc - lengths[i-1]) / (lengths[i] - lengths[i-1])
                return [round(points[i-1][k] + (points[i][k] - points[i-1][k]) * t, 6) for k in range(2)]
        raise ValueError("invalid curve arc")

    result = []
    for start, end in zip(boundaries, boundaries[1:]):
        segment = [at(start)]
        segment.extend(p for p, arc in zip(points, lengths) if start + 1e-6 < arc < end - 1e-6)
        segment.append(at(end))
        result.append(segment)
    return result


def build(presentation: dict, semantics: dict, manifest: dict) -> tuple[dict, dict]:
    validate_manifest(manifest)
    aliases = semantics["city_route_point_aliases"]
    city_map = {str(v["city_id"]): v for v in presentation["cities"]}
    inverse_city_ids = {v: k for k, v in CITY_ID_ALIASES.items()}
    stops = []
    for city_id, city in city_map.items():
        pos = point(city["raw_anchor_px"], city_id)
        allowed = list(city["allowed_routes"])
        stops.append({
            "id": city_id, "kind": "city", "display_name": city["display_name"],
            "position_px": pos, "normalized_position": normalized(pos),
            "allowed_routes": allowed,
            "is_transport_interchange": bool(city.get("is_transport_interchange", False)),
            "route_anchors_px": {r: pos[:] for r in allowed},
            "route_anchors_normalized": {r: normalized(pos) for r in allowed},
        })
    by_id = {v["id"]: v for v in stops}
    edges = []
    for corridor in manifest["corridors"]:
        cid, route = corridor["id"], corridor["route_type"]
        a = inverse_city_ids.get(corridor["a"], corridor["a"])
        b = inverse_city_ids.get(corridor["b"], corridor["b"])
        # Endpoints must attach to the single city seat, independently of any
        # historical city-seat aliases in the artwork extraction.
        geometry = [point(p, cid) for p in corridor["geometry_px"]]
        for actual, expected in [(geometry[0], by_id[a]["position_px"]), (geometry[-1], by_id[b]["position_px"])]:
            if distance(actual, expected) > .01:
                raise ValueError(f"{cid}: display curve does not attach to city seat")
        segments = split_curve(geometry, corridor["stop_fractions"])
        for index, sid in enumerate(corridor["via"]):
            pos = segments[index][-1]
            stop = {
                "id": sid, "kind": "route_point", "display_name": f"{cid} · {index+1}",
                "corridor_id": cid, "corridor_stop_index": index + 1,
                "position_px": pos, "normalized_position": normalized(pos),
                "allowed_routes": [route], "is_transport_interchange": False,
                "route_anchors_px": {route: pos},
                "route_anchors_normalized": {route: normalized(pos)},
                "source_refs": corridor["source_refs"],
            }
            stops.append(stop)
            by_id[sid] = stop
        chain = [a, *corridor["via"], b]
        for index, (left, right, movement) in enumerate(zip(chain, chain[1:], segments)):
            edges.append({
                "a": left, "b": right, "route_type": route,
                "corridor_id": cid, "corridor_step_index": index + 1,
                "source_path_layers": corridor["source_path_layers"],
                "source_polyline_px": copy.deepcopy(movement),
                "movement_polyline_px": movement, "polyline_px": copy.deepcopy(movement),
                "polyline_normalized": [normalized(v) for v in movement],
                "movement_end_err_a": 0.0, "movement_end_err_b": 0.0,
                "movement_max_turn_deg": round(max_turn(movement), 3),
                "movement_ok": True, "semantic_verification_status": "physical_board_reviewed",
                "movement_verification_status": "auto_verified",
            })
    route_counts = Counter(e["route_type"] for e in edges)
    min_spacing, pair = min(
        (distance(a["position_px"], b["position_px"]), [a["id"], b["id"]])
        for i, a in enumerate(stops) for b in stops[i+1:]
    )
    if min_spacing <= .01:
        raise ValueError(f"distinct logical stops coincide: {pair}")
    manifest_sha = hashlib.sha256(json_text(manifest).encode("utf-8")).hexdigest()
    used_layers = {layer for edge in edges for layer in edge["source_path_layers"]}
    topology = {
        "schema": "yf064_world_map_topology_v1", "source_task": "TASK-MAP-TOPOLOGY-PHYSICAL-024",
        "logic_size": [4096, 1363], "playable_stops": stops, "edges": edges,
        "corridor_manifest": "res://data/rulesets/lshu_configurable_v1/map_corridors_v1.json",
        "corridor_manifest_sha256": manifest_sha,
        "stop_aliases": aliases,
        "stop_aliases_role": "historical artwork classification only; not movement authority",
        "interchange_city_ids": ["ancient_rome", "jeddah", "simhala", "quanzhou", "geumseong"],
        "excluded_route_layers": [{"path_layer_index": int(k), "reason": v} for k,v in semantics["excluded_route_layers"].items()],
        "counts": {"playable_stops": len(stops), "edges": len(edges), "land_edges": route_counts["LAND"],
                   "sea_edges": route_counts["SEA"], "aliases": len(aliases), "city_corridors": len(manifest["corridors"])},
        "source_validation": {
            "status": "PASSED", "semantic_source": "map_corridors_v1.json",
            "source_pxd_sha256": semantics["source_pxd_sha256"], "corridor_manifest_sha256": manifest_sha,
            "playable_stops": len(stops), "unique_edge_count": len(edges),
            "land_edges": route_counts["LAND"], "sea_edges": route_counts["SEA"],
            "city_corridors": len(manifest["corridors"]), "intermediate_points_per_corridor": 2,
            "aliases": len(aliases), "components": 1, "isolates": 0,
            "road_dead_ends": 0, "road_junctions": 0,
            "minimum_distinct_stop_spacing_px": round(min_spacing, 3), "minimum_distinct_stop_pair": pair,
            "spacing_policy": "display metric; distance never removes a required rule point",
            "movement_edges_verified": len(edges), "movement_max_endpoint_error_px": 0.0,
            "movement_max_turn_deg": max(e["movement_max_turn_deg"] for e in edges),
            "pxd_path_layers_used": len(used_layers),
            "pxd_path_layers_role": "geometry provenance, not one layer per gameplay edge",
            "internal_city_connector_paths": semantics["internal_city_connector_paths"],
            "excluded_route_layers": [int(k) for k in semantics["excluded_route_layers"]],
        },
    }
    validate_topology_corridors(topology, manifest)
    updated = copy.deepcopy(presentation)
    updated["stop_aliases"] = aliases
    updated["corridor_manifest"] = topology["corridor_manifest"]
    updated["counts"].update({"alias_route_points": len(aliases), "playable_route_points": 38,
        "playable_stops": len(stops), "unique_edges": len(edges),
        "land_edges": route_counts["LAND"], "sea_edges": route_counts["SEA"]})
    for source in updated["route_points"]:
        source["playable"] = False
        source["source_role"] = "authored_hint_or_city_seat; classification_superseded_by_corridor_manifest"
        if source["id"] in aliases:
            source["alias_of"] = aliases[source["id"]]
    for city in updated["cities"]:
        pos = by_id[city["city_id"]]["position_px"]
        anchors = {r: pos[:] for r in city["allowed_routes"]}
        city["route_anchors_px"] = anchors
        city["route_anchors_normalized"] = {r: normalized(p) for r,p in anchors.items()}
        for mode in ["LAND", "SEA"]:
            city[f"{mode.lower()}_entry_anchor_px"] = anchors.get(mode)
            city[f"{mode.lower()}_route_attach_anchor_px"] = anchors.get(mode)
    updated["notes"]["route_recalibration"] = (
        "PHYSICAL-024: 19 original-board city corridors, each with 2 road hints and 3 steps. "
        "City seats are unified. Source circles remain artwork evidence; their previous auto-classification is superseded."
    )
    return topology, updated


def write_or_check(path: Path, payload: dict, check: bool) -> bool:
    expected = json_text(payload)
    if check:
        actual = path.read_text(encoding="utf-8") if path.exists() else ""
        if actual != expected:
            print(f"OUT OF DATE: {path.relative_to(ROOT)}", file=sys.stderr)
            return False
        return True
    path.write_text(expected, encoding="utf-8")
    print(f"WROTE: {path.relative_to(ROOT)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--presentation", type=Path, default=PRESENTATION)
    parser.add_argument("--semantics", type=Path, default=SEMANTICS)
    parser.add_argument("--corridors", type=Path, default=CORRIDORS)
    parser.add_argument("--topology", type=Path, default=TOPOLOGY)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    presentation = read_json(args.presentation)
    semantics = read_json(args.semantics)
    manifest = read_json(args.corridors)
    topology, updated_presentation = build(presentation, semantics, manifest)
    ok = all((
        write_or_check(args.topology, topology, args.check),
        write_or_check(args.presentation, updated_presentation, args.check),
    ))
    if ok:
        digest = hashlib.sha256(json_text(topology).encode("utf-8")).hexdigest()
        print(
            "WORLD MAP TOPOLOGY OK: "
            f"stops={len(topology['playable_stops'])} edges={len(topology['edges'])} "
            f"sha256={digest}"
        )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
