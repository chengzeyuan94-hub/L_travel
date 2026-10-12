"""Physical-board city corridors; drawing vertices never determine move count."""
from __future__ import annotations

import math

CITY_ID_ALIASES = {"ancient_rome": "rome", "pantuo": "panti"}
EXPECTED_CORRIDORS = {
    "LAND": [
        ("rome", "constantinople"), ("constantinople", "baghdad"),
        ("baghdad", "jeddah"), ("baghdad", "panti"),
        ("panti", "yumenguan"), ("panti", "delhi"),
        ("delhi", "simhala"), ("yumenguan", "changan"),
        ("changan", "quanzhou"), ("changan", "geumseong"),
    ],
    "SEA": [
        ("rome", "cairo"), ("cairo", "jeddah"), ("jeddah", "aden"),
        ("aden", "simhala"), ("simhala", "dagon"), ("dagon", "chenla"),
        ("chenla", "quanzhou"), ("quanzhou", "geumseong"),
        ("quanzhou", "heijokyo"),
    ],
}
EXPECTED_STOPS = 54
EXPECTED_EDGES = 57


def edge_key(a: str, b: str, route: str) -> tuple[str, str, str]:
    return (route, *sorted((a, b)))


def validate_manifest(manifest: dict) -> None:
    if manifest.get("schema") != "yf064_map_corridors_v1":
        raise ValueError("missing physical-board corridor schema")
    if manifest.get("intermediate_points_per_corridor") != 2:
        raise ValueError("each city corridor must have exactly two intermediate points")
    if manifest.get("city_anchor_policy") != "one_logical_city_seat":
        raise ValueError("each city must use one shared logical seat")
    expected = {
        f"{route.lower()}_{a}_{b}": (a, b, route)
        for route, pairs in EXPECTED_CORRIDORS.items() for a, b in pairs
    }
    found = set()
    for corridor in manifest.get("corridors", []):
        cid = corridor["id"]
        if cid in found or cid not in expected:
            raise ValueError(f"duplicate or unknown city corridor: {cid}")
        found.add(cid)
        if (corridor["a"], corridor["b"], corridor["route_type"]) != expected[cid]:
            raise ValueError(f"city/transport connection differs from physical board: {cid}")
        if corridor.get("via") != [f"{cid}_01", f"{cid}_02"]:
            raise ValueError(f"{cid}: exactly two exclusive intermediate point IDs required")
        fractions = corridor.get("stop_fractions", [])
        if len(fractions) != 2 or not (0 < fractions[0] < fractions[1] < 1):
            raise ValueError(f"{cid}: two ordered interior display positions required")
        geometry = corridor.get("geometry_px", [])
        if len(geometry) < 2:
            raise ValueError(f"{cid}: missing display geometry")
        for p in geometry:
            if not isinstance(p, list) or len(p) != 2 or not all(
                isinstance(v, (int, float)) and math.isfinite(v) for v in p
            ):
                raise ValueError(f"{cid}: invalid display point {p!r}")
        if sum(math.dist(a, b) for a, b in zip(geometry, geometry[1:])) <= 1e-6:
            raise ValueError(f"{cid}: zero-length display geometry")
    if found != set(expected):
        raise ValueError(f"missing physical-board corridors: {sorted(set(expected) - found)}")


def validate_topology_corridors(topology: dict, manifest: dict) -> None:
    """Validate structure independently of saved count or verification flags."""
    validate_manifest(manifest)
    normalize = lambda sid: CITY_ID_ALIASES.get(sid, sid)
    expected_nodes = {}
    expected_edges = set()
    for c in manifest["corridors"]:
        route = c["route_type"]
        for sid in (c["a"], c["b"]):
            expected_nodes.setdefault(sid, ("city", set()))[1].add(route)
        for sid in c["via"]:
            expected_nodes[sid] = ("route_point", {route})
        chain = [c["a"], *c["via"], c["b"]]
        expected_edges.update(edge_key(a, b, route) for a, b in zip(chain, chain[1:]))
    seen = set()
    for stop in topology.get("playable_stops", []):
        sid = normalize(stop["id"])
        if sid in seen or sid not in expected_nodes:
            raise ValueError(f"unexpected/duplicate playable stop: {sid}")
        seen.add(sid)
        kind, routes = expected_nodes[sid]
        if stop.get("kind") != kind or set(stop.get("allowed_routes", [])) != routes:
            raise ValueError(f"{sid}: wrong city/road role or transport eligibility")
        position = stop.get("position_px", [])
        if len(position) != 2 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in position):
            raise ValueError(f"{sid}: invalid stop position")
        anchors = stop.get("route_anchors_px", {})
        if set(anchors) != routes:
            raise ValueError(f"{sid}: wrong route anchors")
        for anchor in anchors.values():
            if len(anchor) != 2 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in anchor):
                raise ValueError(f"{sid}: invalid route anchor")
            if math.dist(anchor, position) > .01:
                raise ValueError(f"{sid}: route anchors must share the logical stop position")
    if seen != set(expected_nodes):
        raise ValueError("physical-board stop set mismatch")
    actual_edges = [edge_key(normalize(e["a"]), normalize(e["b"]), e["route_type"])
                    for e in topology.get("edges", [])]
    if len(actual_edges) != len(expected_edges) or set(actual_edges) != expected_edges:
        raise ValueError("physical-board edge mismatch: every corridor requires exactly three steps")
    # Exact edges also guarantee degree 2 for every ordinary stop: no dead ends,
    # shared sea junctions, extra shortcuts or cross-corridor transitions.
