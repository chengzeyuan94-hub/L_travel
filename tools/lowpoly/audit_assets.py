#!/usr/bin/env python3
"""Validate the shipped low-poly GLBs and write a reproducible asset inventory."""
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets/game/lowpoly"
DATA = ROOT / "data/rulesets/lshu_configurable_v1"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect(path):
    blob = path.read_bytes()
    magic, version, length = struct.unpack_from("<4sII", blob)
    assert magic == b"glTF" and version == 2 and length == len(blob), path
    json_length, kind = struct.unpack_from("<I4s", blob, 12)
    assert kind == b"JSON", path
    model = json.loads(blob[20:20 + json_length])
    assert not model.get("images") and not model.get("textures"), path
    assert not model.get("cameras"), path
    assert not model.get("extensions", {}).get("KHR_lights_punctual"), path
    triangles = 0
    surfaces = 0
    for mesh in model["meshes"]:
        for primitive in mesh["primitives"]:
            assert primitive.get("mode", 4) == 4, path
            accessor = model["accessors"][primitive.get("indices", primitive["attributes"]["POSITION"])]
            assert accessor["count"] % 3 == 0, path
            triangles += accessor["count"] // 3
            surfaces += 1
    return {"path": str(path.relative_to(ROOT)), "bytes": len(blob),
            "sha256": digest(path), "triangles": triangles,
            "meshes": len(model["meshes"]), "surfaces": surfaces,
            "materials": len(model.get("materials", [])), "textures": 0}


def main():
    city_document = json.loads((DATA / "cities.json").read_text())
    city_rows = city_document.get("items", city_document.get("cities", city_document)) if isinstance(city_document, dict) else city_document
    city_ids = set(city_rows) if isinstance(city_rows, dict) else {row["id"] for row in city_rows}
    assert len(city_ids) == 16, city_ids
    expected = {"cities/" + city_id + ".glb" for city_id in city_ids}
    expected |= {"vehicles/camel.glb", "vehicles/ship.glb", "world/terrain.glb", "world/water.glb"}
    expected |= {"planet/terrain.glb", "planet/water.glb"}
    actual = {str(path.relative_to(ASSETS)) for path in ASSETS.rglob("*.glb")}
    assert actual == expected, {"missing": sorted(expected - actual), "unexpected": sorted(actual - expected)}
    assets = [inspect(ASSETS / name) for name in sorted(actual)]
    assert len({a["sha256"] for a in assets}) == 22, "Models must be distinct."
    active = [a for a in assets if "/world/" not in a["path"]]
    manifest = {"schema_version": 2, "asset_count": len(assets),
                "total_glb_bytes": sum(a["bytes"] for a in assets),
                "total_triangles": sum(a["triangles"] for a in assets),
                "active_world": "planet-v2", "active_asset_count": len(active),
                "active_glb_bytes": sum(a["bytes"] for a in active),
                "active_triangles": sum(a["triangles"] for a in active),
                "active_asset_paths": [a["path"] for a in active],
                "coordinate_system": "glTF Y-up; vehicles face -Z; feet/waterline at Y=0",
                "source": "docs/design/lowpoly-v1/source/", "assets": assets,
                "rule_source_sha256": {name: digest(DATA / name) for name in
                                       ("cities.json", "board_nodes.json", "board_edges.json")}}
    (ASSETS / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print("LOWPOLY_ASSET_AUDIT: passed=%d failed=0 active=%d active_triangles=%d active_bytes=%d textures=0" %
          (len(assets), len(active), manifest["active_triangles"], manifest["active_glb_bytes"]))


if __name__ == "__main__":
    main()
