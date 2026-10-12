#!/usr/bin/env python3
"""Promote the verified world-map topology into the formal YF064 rule board.

The presentation topology remains the geometry authority.  This tool performs
only a lossless schema promotion plus the two approved presentation-to-formal
city ID normalizations.  It intentionally does not infer or redraw routes.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import sys
from collections import deque
from pathlib import Path

from map_corridor_contract import EXPECTED_STOPS, EXPECTED_EDGES, validate_topology_corridors


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RULESET_DIR = ROOT / "data/rulesets/lshu_configurable_v1"
DEFAULT_TOPOLOGY = DEFAULT_RULESET_DIR / "presentation/world_map_topology_v1.json"

RULESET_ID = "lshu_configurable_v1"
EDITION_ID = "user_confirmed_v1"
SCHEMA_VERSION = 1
CITY_ID_ALIASES = {
    "ancient_rome": "rome",
    "pantuo": "panti",
}
EXPECTED_INTERCHANGES = {"rome", "jeddah", "simhala", "quanzhou", "geumseong"}
FORMAL_TAGS = ["original_rule", "formal_world_map"]


def _read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _json_text(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _normalize_stop_id(stop_id: str) -> str:
    return CITY_ID_ALIASES.get(stop_id, stop_id)


def _point(value: object, context: str) -> list[float]:
    if not isinstance(value, list) or len(value) != 2:
        raise ValueError(f"{context}: expected [x, y], got {value!r}")
    point = [float(value[0]), float(value[1])]
    if not all(math.isfinite(v) for v in point):
        raise ValueError(f"{context}: non-finite coordinate {value!r}")
    return point


def _distance(a: list[float], b: list[float]) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def _route_anchor(stop: dict, route_type: str, context: str) -> list[float]:
    anchors = stop.get("route_anchors_px", {})
    if not isinstance(anchors, dict) or route_type not in anchors:
        raise ValueError(f"{context}: missing {route_type} route anchor")
    unknown = set(anchors) - {"LAND", "SEA"}
    if unknown:
        raise ValueError(f"{context}: unknown route anchors {sorted(unknown)}")
    return _point(anchors[route_type], f"{context}/{route_type} anchor")


def _edge_key(a: str, b: str, route_type: str) -> tuple[str, str, str]:
    lo, hi = sorted((a, b))
    return route_type, lo, hi


def _edge_id(a: str, b: str, route_type: str) -> str:
    route, lo, hi = _edge_key(a, b, route_type)
    return f"edge_{route.lower()}_{lo}__{hi}"


def _validate_topology(topology: dict, formal_city_ids: set[str]) -> None:
    stops = topology.get("playable_stops", [])
    edges = topology.get("edges", [])
    if len(stops) != EXPECTED_STOPS or len(edges) != EXPECTED_EDGES:
        raise ValueError(
            f"verified topology count drift: stops={len(stops)} edges={len(edges)}; "
            f"expected {EXPECTED_STOPS}/{EXPECTED_EDGES}"
        )
    source_validation = topology.get("source_validation", {})
    if source_validation.get("status") != "PASSED":
        raise ValueError("topology source_validation is not PASSED")
    if int(source_validation.get("playable_stops", -1)) != EXPECTED_STOPS:
        raise ValueError("source_validation playable_stops mismatch")
    if int(source_validation.get("unique_edge_count", -1)) != EXPECTED_EDGES:
        raise ValueError("source_validation unique_edge_count mismatch")
    logic_size = topology.get("logic_size", [])
    if logic_size != [4096, 1363]:
        raise ValueError(f"unexpected logic_size: {logic_size!r}")

    stop_by_id: dict[str, dict] = {}
    normalized_ids: set[str] = set()
    city_ids: set[str] = set()
    for raw in stops:
        source_id = str(raw.get("id", ""))
        if not source_id or source_id in stop_by_id:
            raise ValueError(f"empty or duplicate topology stop id: {source_id!r}")
        normalized = _normalize_stop_id(source_id)
        if normalized in normalized_ids:
            raise ValueError(f"normalization creates duplicate stop id: {normalized}")
        normalized_ids.add(normalized)
        stop_by_id[source_id] = raw
        _point(raw.get("position_px"), f"stop {source_id}")
        allowed = raw.get("allowed_routes", [])
        if not isinstance(allowed, list) or not allowed or any(v not in {"LAND", "SEA"} for v in allowed):
            raise ValueError(f"stop {source_id}: invalid allowed_routes {allowed!r}")
        if bool(raw.get("is_transport_interchange", False)) != (set(allowed) == {"LAND", "SEA"}):
            raise ValueError(f"stop {source_id}: interchange/allowed_routes mismatch")
        anchors = raw.get("route_anchors_px", {})
        if not isinstance(anchors, dict) or set(anchors) != set(allowed):
            raise ValueError(f"stop {source_id}: route_anchors_px/allowed_routes mismatch")
        for route_type in allowed:
            _route_anchor(raw, route_type, f"stop {source_id}")
        kind = str(raw.get("kind", ""))
        if kind == "city":
            city_ids.add(normalized)
        elif kind != "route_point":
            raise ValueError(f"stop {source_id}: unknown kind {kind!r}")
    if city_ids != formal_city_ids:
        raise ValueError(
            f"topology/formal city mismatch: missing={sorted(formal_city_ids - city_ids)} "
            f"extra={sorted(city_ids - formal_city_ids)}"
        )

    interchange_ids = {
        _normalize_stop_id(str(raw["id"]))
        for raw in stops
        if bool(raw.get("is_transport_interchange", False))
    }
    if interchange_ids != EXPECTED_INTERCHANGES:
        raise ValueError(f"interchange set mismatch: {sorted(interchange_ids)}")

    keys: set[tuple[str, str, str]] = set()
    adjacency: dict[str, set[str]] = {stop_id: set() for stop_id in normalized_ids}
    for index, edge in enumerate(edges):
        source_a = str(edge.get("a", ""))
        source_b = str(edge.get("b", ""))
        if source_a not in stop_by_id or source_b not in stop_by_id:
            raise ValueError(f"edge {index}: unknown endpoint {source_a}/{source_b}")
        a = _normalize_stop_id(source_a)
        b = _normalize_stop_id(source_b)
        route_type = str(edge.get("route_type", ""))
        if a == b or route_type not in {"LAND", "SEA"}:
            raise ValueError(f"edge {index}: invalid {a}/{b}/{route_type}")
        key = _edge_key(a, b, route_type)
        if key in keys:
            raise ValueError(f"duplicate normalized edge: {key}")
        keys.add(key)
        if route_type not in stop_by_id[source_a]["allowed_routes"]:
            raise ValueError(f"edge {index}: {source_a} rejects {route_type}")
        if route_type not in stop_by_id[source_b]["allowed_routes"]:
            raise ValueError(f"edge {index}: {source_b} rejects {route_type}")
        movement = edge.get("movement_polyline_px", [])
        if not isinstance(movement, list) or len(movement) < 2:
            raise ValueError(f"edge {index}: movement_polyline_px is missing")
        movement_points = [_point(p, f"edge {index} movement") for p in movement]
        if _distance(movement_points[0], _route_anchor(stop_by_id[source_a], route_type, source_a)) > 1.0:
            raise ValueError(f"edge {index}: movement start does not attach to {source_a}")
        if _distance(movement_points[-1], _route_anchor(stop_by_id[source_b], route_type, source_b)) > 1.0:
            raise ValueError(f"edge {index}: movement end does not attach to {source_b}")
        adjacency[a].add(b)
        adjacency[b].add(a)

    first = next(iter(adjacency))
    seen = {first}
    queue = deque([first])
    while queue:
        current = queue.popleft()
        for other in adjacency[current]:
            if other not in seen:
                seen.add(other)
                queue.append(other)
    if seen != set(adjacency):
        raise ValueError(f"topology is disconnected: missing={sorted(set(adjacency) - seen)}")


def build_documents(topology_path: Path, ruleset_dir: Path) -> tuple[dict, dict, dict, dict]:
    topology = _read_json(topology_path)
    cities_doc = _read_json(ruleset_dir / "cities.json")
    ruleset_doc = _read_json(ruleset_dir / "ruleset.json")
    cities = copy.deepcopy(cities_doc.get("items", []))
    formal_city_ids = {str(city.get("id", "")) for city in cities}
    if "" in formal_city_ids or len(formal_city_ids) != 16:
        raise ValueError(f"formal city ids invalid: {sorted(formal_city_ids)}")
    manifest_path = ruleset_dir / "map_corridors_v1.json"
    validate_topology_corridors(topology, _read_json(manifest_path))
    if topology.get("corridor_manifest_sha256") != _sha256(manifest_path):
        raise ValueError("topology corridor manifest hash mismatch")
    _validate_topology(topology, formal_city_ids)

    topology_hash = _sha256(topology_path)
    source_ref = "data/rulesets/lshu_configurable_v1/presentation/world_map_topology_v1.json"
    stop_by_formal_id: dict[str, dict] = {}
    nodes: list[dict] = []
    for raw in topology["playable_stops"]:
        source_id = str(raw["id"])
        node_id = _normalize_stop_id(source_id)
        is_city = raw["kind"] == "city"
        position = _point(raw["position_px"], f"stop {source_id}")
        node = {
            "id": node_id,
            "node_type": "CITY" if is_city else "ROAD",
            "city_id": node_id if is_city else None,
            "map_position": position,
            "position_px": position,
            "route_anchors": {
                route_type: _point(anchor, f"stop {source_id}/{route_type}")
                for route_type, anchor in raw["route_anchors_px"].items()
            },
            "allowed_routes": list(raw["allowed_routes"]),
            "is_transport_interchange": bool(raw.get("is_transport_interchange", False)),
            "presentation_stop_id": source_id,
            "source_refs": [source_ref, "data/rulesets/lshu_configurable_v1/map_corridors_v1.json"],
            "verification_status": "verified",
            "content_tags": FORMAL_TAGS,
        }
        nodes.append(node)
        stop_by_formal_id[node_id] = node

    edges: list[dict] = []
    for raw in topology["edges"]:
        a = _normalize_stop_id(str(raw["a"]))
        b = _normalize_stop_id(str(raw["b"]))
        route_type = str(raw["route_type"])
        movement = copy.deepcopy(raw["movement_polyline_px"])
        edge = {
            "id": _edge_id(a, b, route_type),
            "a": a,
            "b": b,
            "route_type": route_type,
            "corridor_id": raw["corridor_id"],
            "corridor_step_index": raw["corridor_step_index"],
            # `movement_polyline` is the formal rule-board contract; the *_px
            # alias keeps the presentation/runtime hand-off lossless.
            "movement_polyline": movement,
            "movement_polyline_px": copy.deepcopy(movement),
            "source_polyline_px": copy.deepcopy(raw.get("source_polyline_px", [])),
            "source_path_layers": copy.deepcopy(raw.get("source_path_layers", [])),
            "semantic_verification_status": raw.get("semantic_verification_status", "auto"),
            "movement_verification_status": raw.get("movement_verification_status", "auto_verified"),
            "source_refs": [source_ref],
            "verification_status": "verified",
            "content_tags": FORMAL_TAGS,
        }
        edges.append(edge)
    edges.sort(key=lambda edge: str(edge["id"]))

    city_by_id = {str(city["id"]): city for city in cities}
    for city_id in sorted(formal_city_ids):
        city = city_by_id[city_id]
        node = stop_by_formal_id[city_id]
        city["board_node_id"] = city_id
        city["map_position"] = copy.deepcopy(node["map_position"])

    expected_counts = ruleset_doc.setdefault("expected_counts", {})
    expected_counts["board_nodes"] = EXPECTED_STOPS
    expected_counts["board_edges"] = EXPECTED_EDGES

    common = {
        "ruleset_id": RULESET_ID,
        "edition_id": EDITION_ID,
        "schema_version": SCHEMA_VERSION,
        "logical_size": topology["logic_size"],
        "source_topology": f"res://{source_ref}",
        "source_topology_sha256": topology_hash,
        "source_corridors_sha256": _sha256(manifest_path),
        "id_normalizations": CITY_ID_ALIASES,
    }
    nodes_doc = {**common, "items": nodes}
    edges_doc = {**common, "items": edges}
    cities_doc["items"] = cities
    return nodes_doc, edges_doc, cities_doc, ruleset_doc


def _write_or_check(path: Path, payload: dict, check: bool) -> bool:
    expected = _json_text(payload)
    if check:
        actual = path.read_text(encoding="utf-8") if path.exists() else ""
        if actual != expected:
            print(f"OUT OF DATE: {path.relative_to(ROOT)}", file=sys.stderr)
            return False
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(expected, encoding="utf-8")
    print(f"WROTE: {path.relative_to(ROOT)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--topology", type=Path, default=DEFAULT_TOPOLOGY)
    parser.add_argument("--ruleset-dir", type=Path, default=DEFAULT_RULESET_DIR)
    parser.add_argument("--check", action="store_true", help="fail if generated files differ")
    args = parser.parse_args()
    topology = args.topology.resolve()
    ruleset_dir = args.ruleset_dir.resolve()
    nodes, edges, cities, ruleset = build_documents(topology, ruleset_dir)
    outputs = [
        (ruleset_dir / "board_nodes.json", nodes),
        (ruleset_dir / "board_edges.json", edges),
        (ruleset_dir / "cities.json", cities),
        (ruleset_dir / "ruleset.json", ruleset),
    ]
    ok = all(_write_or_check(path, payload, args.check) for path, payload in outputs)
    if ok:
        print(
            f"FORMAL BOARD OK: nodes={len(nodes['items'])} edges={len(edges['items'])} "
            f"interchanges={len(EXPECTED_INTERCHANGES)}"
        )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
