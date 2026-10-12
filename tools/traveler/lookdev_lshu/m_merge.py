#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L叔在哪儿 · merger: builds variants/m_final.json from the three look lines (l1_final, l2_final, l3_final).

  python3 tools/traveler/lookdev_lshu/m_merge.py            # writes variants/m_final.json, prints the collision log

Rules
  * m_final is flattened on top of "baseline" (the builder's pipeline root); it does NOT inherit from the line
    variants, so later edits to l1_final / l2_final / l3_final never change the merged look silently.
  * Section merge order: L1 -> L2 -> L3 (a later line wins a colliding key), then the merger's explicit
    resolutions (MERGER_OVERRIDES) are applied last and every one of them is asserted/logged.
  * extra_scripts order (load order matters, see README_PROBE.md §6):
        1. l1_atmos.gd          - must be first: its build() swaps the floor shader and calls host.set_light(),
                                  which would re-fire any light callback registered before it.
        2. l2_edges.gd          - replaces MeshInstance3D.mesh (crease barycentrics); must precede any module that
                                  keeps mesh references.
        3. l2_surface_detail.gd - binds ground maps / water level / sun dir (light callback).
        4. l2_scatter.gd        - MultiMesh scatter; reads footprints from the (edge-rebuilt) meshes.
        5. l3_life.gd           - character layer / rim / contact decal / cup / blossom / camp fire / smoke / lanterns;
                                  only touches the character, its own fx nodes and the viewer's lamp energies.
  * Nothing may be keyed by tile id: the script fails if any key or string value looks like a recipe id.
"""
import copy, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
VDIR = os.path.join(HERE, "variants")
LINES = ["l1_final", "l2_final", "l3_final"]          # merge order
OUT = os.path.join(VDIR, "m_final.json")
TILE_ID = re.compile(r"^(D(0[1-9]|1[0-2])|J\d{3})$|\b(D(0[1-9]|1[0-2])|J\d{3})\b")

# L3 raised motion.wind_strength 0.015 -> 0.04 for the trees. l2_scatter.gdshader bends grass by
# h^2 * l2_sway * wind_strength and L2 tuned l2_sway = 160 at 0.015, so keep L2's grass bend: 160 * 0.015 / 0.04.
SCATTER_SWAY = round(160.0 * 0.015 / 0.04, 3)

MERGER_OVERRIDES = [
    # (path, value, why)
    (("lights", "morning", "surface", "roles", "glow", "emission_strength"), 0.08,
     "L1 0.15 vs L2 0.08: morning windows read as glass (L2 glass pass), L1 agreed"),
    (("lights", "day", "surface", "roles", "glow", "emission_strength"), 0.03,
     "L1 0.10 vs L2 0.03: day windows read as glass (L2 glass pass), L1 agreed"),
    (("lights", "sunset", "surface", "roles", "glow", "emission_strength"), 0.8,
     "L1 only (L2 unset): warm windows at sunset"),
    (("lights", "night", "surface", "roles", "glow", "emission_strength"), 2.4,
     "L1 only (L2 unset): lit windows at night, glow threshold 1.3"),
    (("common", "surface", "roles", "scatter", "l2_sway"), SCATTER_SWAY,
     "implicit L2xL3 conflict: L3 wind 0.04 (trees) would bend L2 grass 2.67x; l2_sway 160 -> %s keeps L2's bend" % SCATTER_SWAY),
    (("lights", "night", "surface", "roles", "water", "saturation"), 0.6,
     "implicit L1xL2 residual: night water clipped to R=0 (sat 0.95 vs web 0.66); one night-preset rule for all water"),
    (("lights", "night", "sun", "angular_distance_deg"), 0.8,
     "L1 residual: night PCSS at 1.5 deg leaves lit-pixel stipple in thin blockers' shadows (D01 chimney on roof, "
     "roof HF 30.2 vs baseline 7.3); 0.8 -> 10.5; sunset/day at 1.5 show none, so only the night preset changes"),
]


def load(name):
    with open(os.path.join(VDIR, name + ".json"), encoding="utf-8") as f:
        return json.load(f)


def flat(d, p=()):
    out = {}
    for k, v in d.items():
        if isinstance(v, dict):
            out.update(flat(v, p + (k,)))
        else:
            out[p + (k,)] = v
    return out


def merge(a, b):
    out = copy.deepcopy(a)
    for k, v in b.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def set_path(d, path, value):
    for k in path[:-1]:
        d = d.setdefault(k, {})
    old = d.get(path[-1], None)
    d[path[-1]] = value
    return old


def scan_tile_ids(node, where=""):
    hits = []
    if isinstance(node, dict):
        for k, v in node.items():
            if TILE_ID.search(str(k)):
                hits.append(where + "/" + str(k))
            hits += scan_tile_ids(v, where + "/" + str(k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            hits += scan_tile_ids(v, "%s[%d]" % (where, i))
    elif isinstance(node, str) and TILE_ID.search(node) and not node.startswith("res://"):
        hits.append("%s=%s" % (where, node))
    return hits


def main():
    lines = {n: load(n) for n in LINES}
    for n, v in lines.items():
        assert v.get("base") == "baseline", "%s must sit directly on baseline (got %r)" % (n, v.get("base"))
    body = {"common": {}, "lights": {}}
    owner = {}
    log = []
    for n in LINES:
        part = {"common": lines[n].get("common", {}), "lights": lines[n].get("lights", {})}
        for k, val in flat(part).items():
            if k in owner and flat(body).get(k) != val:
                log.append("COLLISION %s: %s=%r overridden by %s=%r" % (".".join(k), owner[k], flat(body)[k], n, val))
            owner[k] = n
        body = merge(body, part)
    for path, value, why in MERGER_OVERRIDES:
        old = set_path(body, path, value)
        log.append("RESOLVE %s: %r -> %r (%s)" % (".".join(path), old, value, why))
    scripts = []
    for n in LINES:
        scripts += copy.deepcopy(lines[n].get("extra_scripts", []))
    order = [os.path.basename(s["script"]) for s in scripts]
    assert order == ["l1_atmos.gd", "l2_edges.gd", "l2_surface_detail.gd", "l2_scatter.gd", "l3_life.gd"], order
    for s in scripts:
        if s["script"].endswith("l3_life.gd"):
            s["cfg"] = {"measure": True}   # findability probe: runs inside the 120-frame warm-up, restores state
    out = {
        "base": "baseline",
        "schema": "lshu.variant.v1",
        "description": ("Merged final look (L1 lighting & atmosphere + L2 surface detail + L3 L叔 integration & life), "
                        "flattened on baseline by m_merge.py. Section order L1 -> L2 -> L3, then merger resolutions. "
                        "Module order: l1_atmos -> l2_edges -> l2_surface_detail -> l2_scatter -> l3_life. "
                        "Only light-preset / theme / role / ground-class keys; nothing per tile."),
        "merge": {
            "sources": LINES,
            "section_order": "l1_final -> l2_final -> l3_final -> merger resolutions",
            "module_order": order,
            "module_order_why": {
                "l1_atmos.gd": "first: build() swaps the floor shader and calls host.set_light()",
                "l2_edges.gd": "before anything that keeps mesh references (it replaces mi.mesh)",
                "l2_surface_detail.gd": "ground maps, water level, per-light sun dir",
                "l2_scatter.gd": "after edges: footprints from the rebuilt meshes",
                "l3_life.gd": "last: character, own fx nodes, lamp energy on top of lamps.light_energy",
            },
            "resolutions": [{"key": ".".join(p), "value": v, "why": w} for p, v, w in MERGER_OVERRIDES],
            "log": log,
        },
        "common": body["common"],
        "lights": body["lights"],
        "extra_scripts": scripts,
    }
    hits = scan_tile_ids({"common": out["common"], "lights": out["lights"], "extra_scripts": out["extra_scripts"]})
    if hits:
        raise SystemExit("per-tile keys/values found: %s" % hits)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    for ln in log:
        print(ln)
    print("WROTE", OUT, "modules:", " -> ".join(order), "per_tile_hits: 0")


if __name__ == "__main__":
    main()
