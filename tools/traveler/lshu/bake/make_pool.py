#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Regenerate / verify data/traveler/lshu/pool.json (the 160-tile default pool).

pool.json is the ONLY place that names tiles, compositions, assets, places or cities; this tool names none. Every
per-tile value below comes from a global rule, a seed stored in pool.json, or the web catalog / rulesets it reads.

Groups (order of the "tiles" array):
  showcase  refreshed from web_src/config/showcases12.json (id Dnn, showcase name + light)
  verifier  the three probe verifier recipes, kept as they are
  random    random.Random(random_pick.seed).sample over the 960 compositions minus the fixed ones (P0 acceptance)
  pool      one tile per (place, kit) slot the 25 fixed tiles leave free, so the pool is 40 places x 4 kits.

Layout rule ("pool_rule" in pool.json, seeded, global):
  The 25 fixed tiles keep their slot. The free slots of each place are filled place by place, places in
  random.Random(pool_rule.seed) order; each place tries every layout assignment of its free kits and takes the
  lexicographic minimum of
    1. layout classes (loop.json planner.layout_classes: left / center / right) the place's 4 tiles miss,
    2. repeated layouts inside the place,
    3. balance: sum of squares of the global class counts + the (kit, class) counts + the layout counts,
    4. a draw from the same generator (tie break).
  The default light of every pool tile is then drawn from that generator, in composition order.

Postcard fields ("postcard_rule" in pool.json, global):
  city_id           cities.json id whose display_name equals the place's city (city places only)
  sub               the web catalog's one-line sub of nature places (city places carry modelling notes: skipped)
  postcard_terrain  only for landforms the line library's terrain_resolve.from_landform does not map: the
                    library's own resolution order [city] + group(landform) + from_biome[biome], with
                    group(landform) = terrain_by_landform["<landform>/<biome>"] or terrain_by_landform["<landform>"].
                    An unmapped landform without a table entry is an error, so a new landform cannot slip through.

Usage: python3 tools/traveler/lshu/bake/make_pool.py [--check] [--out=PATH] [--report=PATH]
  --out     read and write PATH instead of pool.json (stage a pool, bake it, then install it); a missing PATH
            starts from pool.json
  --check   exit 1 when the target file differs from the regenerated text
  --report  JSON with the layout class / layout / light spread and the postcard field counts
"""
import itertools, json, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
WEB = os.path.join(ROOT, "tools", "traveler", "lshu", "web_src")
POOL = os.path.join(ROOT, "data", "traveler", "lshu", "pool.json")
LOOP = os.path.join(ROOT, "data", "traveler", "lshu", "loop.json")
LINES = os.path.join(ROOT, "data", "traveler", "lshu", "postcard_lines.json")
CITIES = os.path.join(ROOT, "data", "rulesets", "lshu_configurable_v1", "cities.json")
LIGHTS = ["morning", "day", "sunset", "night"]
CLASSES = ["left", "center", "right"]


def load(p):
    return json.load(open(p, encoding="utf-8"))


def fixed_tiles(cur, showcases, names):
    tiles = [{"id": s["id"], "composition_id": s["composition_id"], "light": s["lighting"], "group": "showcase",
              "name": s["name"], "description": s.get("description")} for s in showcases]
    tiles += [{k: v for k, v in dict(t, name=names[t["composition_id"]]).items() if k in ("id", "composition_id", "light", "group", "name")}
              for t in cur["tiles"] if t.get("group") == "verifier"]
    pick = cur["random_pick"]
    used = {t["composition_id"] for t in tiles}
    rng = random.Random(int(pick["seed"]))
    candidates = sorted(c for c in names if c not in used)
    for cid in sorted(rng.sample(candidates, int(pick["count"]))):
        tiles.append({"id": cid, "composition_id": cid, "light": rng.choice(LIGHTS), "group": "random", "name": names[cid]})
    return tiles


def fill_slots(fixed, journey, layout_class, seed):
    """Returns (new pool entries, report). One composition per free (place, kit) slot."""
    recipes = {r["composition_id"]: r for r in journey["recipes"]}
    by_slot = {(r["scene_id"], r["variant"], r["profile"]): r["composition_id"] for r in journey["recipes"]}
    places = [p["id"] for p in sorted(journey["places"], key=lambda p: p["index"])]
    kits = [q["id"] for q in journey["profiles"]]
    layouts = [q["id"] for q in journey["layouts"]]
    cls_n = {c: 0 for c in CLASSES}
    kit_cls = {(k, c): 0 for k in kits for c in CLASSES}
    lay_n = {l: 0 for l in layouts}
    taken = {}      # (place, kit) -> layout
    extras = []     # fixed tiles whose slot another fixed tile already holds
    for t in fixed:
        r = recipes[t["composition_id"]]
        slot = (r["scene_id"], r["profile"])
        if slot in taken:
            extras.append(t["id"])
            continue
        taken[slot] = r["variant"]
        c = layout_class[r["variant"]]
        cls_n[c] += 1; kit_cls[(r["profile"], c)] += 1; lay_n[r["variant"]] += 1
    rng = random.Random(int(seed))
    order = list(places)
    rng.shuffle(order)
    chosen = {}
    for place in order:
        pinned = {k: taken[(place, k)] for k in kits if (place, k) in taken}
        free = [k for k in kits if k not in pinned]
        best = None
        for combo in itertools.product(layouts, repeat=len(free)):
            assign = dict(pinned); assign.update(zip(free, combo))
            missing = len(CLASSES) - len({layout_class[l] for l in assign.values()})
            repeats = len(assign) - len(set(assign.values()))
            cn, kc, ln = dict(cls_n), dict(kit_cls), dict(lay_n)
            for k, l in zip(free, combo):
                c = layout_class[l]; cn[c] += 1; kc[(k, c)] += 1; ln[l] += 1
            balance = sum(v * v for v in cn.values()) + sum(v * v for v in kc.values()) + sum(v * v for v in ln.values())
            key = (missing, repeats, balance, rng.random())
            if best is None or key < best[0]:
                best = (key, combo)
        for k, l in zip(free, best[1]):
            c = layout_class[l]; cls_n[c] += 1; kit_cls[(k, c)] += 1; lay_n[l] += 1
            chosen[(place, k)] = l
    names = {r["composition_id"]: r["name"] for r in journey["recipes"]}
    new = []
    for cid in sorted(by_slot[(p, l, k)] for (p, k), l in chosen.items()):
        new.append({"id": cid, "composition_id": cid, "light": rng.choice(LIGHTS), "group": "pool", "name": names[cid]})
    per_place_missing = 0
    for place in places:
        ls = [taken.get((place, k), chosen.get((place, k))) for k in kits]
        per_place_missing += len(CLASSES) - len({layout_class[l] for l in ls})
    report = {
        "slots": len(taken) + len(chosen), "fixed_in_slots": len(taken), "filled_by_rule": len(chosen), "fixed_extras": extras,
        "class_counts": cls_n, "kit_class_counts": {"%s/%s" % (journey["profiles"][k]["mode"], c): v for (k, c), v in sorted(kit_cls.items())},
        "layout_counts": {str(k): v for k, v in sorted(lay_n.items())}, "places_missing_a_class": per_place_missing,
    }
    return new, report


def postcard_fields(tile, journey, lines, cities, rule):
    recipes = {r["composition_id"]: r for r in journey["recipes"]}
    place = next(p for p in journey["places"] if p["id"] == recipes[tile["composition_id"]]["scene_id"])
    tr = lines["terrain_resolve"]
    groups = lines["terrain_groups"]
    out = {}
    city_id = cities.get(place.get("city") or "", "") if place.get("city") else ""
    if place.get("city") and not city_id:
        raise SystemExit("city place without a cities.json id: %s" % place.get("city"))
    if city_id:
        out["city_id"] = city_id
    elif not place.get("new_city") and place.get("sub"):
        out["sub"] = place["sub"]
    lf, biome = place.get("landform") or "", place.get("theme") or ""
    if lf and lf not in tr["from_landform"]:
        table = rule["terrain_by_landform"]
        g = table.get("%s/%s" % (lf, biome), table.get(lf))
        if g is None:
            raise SystemExit("landform %r is mapped neither by the line library nor by postcard_rule.terrain_by_landform" % lf)
        tags = (["city"] if city_id else []) + [g, tr["from_biome"].get(biome, "")]
        tags = [t for i, t in enumerate(tags) if t and t not in tags[:i]]
        for t in tags:
            if t not in groups:
                raise SystemExit("postcard terrain %r is not a terrain group of the line library" % t)
        out["postcard_terrain"] = tags
    return out


def build(cur):
    showcases = load(os.path.join(WEB, "config", "showcases12.json"))
    journey = load(os.path.join(WEB, "config", "journey960.json"))
    loop = load(LOOP)
    lines = load(LINES)
    cities = {c["display_name"]: c["id"] for c in load(CITIES)["items"]}
    names = {r["composition_id"]: r["name"] for r in journey["recipes"]}
    layout_class = {int(k): v for k, v in loop["planner"]["layout_classes"].items()}
    fixed = fixed_tiles(cur, showcases, names)
    new, report = fill_slots(fixed, journey, layout_class, cur["pool_rule"]["seed"])
    tiles = []
    for t in fixed + new:
        t = {k: v for k, v in t.items() if k not in ("city_id", "sub", "postcard_terrain")}
        t.update(postcard_fields(t, journey, lines, cities, cur["postcard_rule"]))
        tiles.append(t)
    out = dict(cur)
    out["tiles"] = tiles
    recipes = {r["composition_id"]: r for r in journey["recipes"]}
    report["tiles"] = len(tiles)
    report["places"] = len({recipes[t["composition_id"]]["scene_id"] for t in tiles})
    report["lights"] = {l: sum(1 for t in tiles if t["light"] == l) for l in LIGHTS}
    report["postcard"] = {k: sum(1 for t in tiles if k in t) for k in ("city_id", "sub", "postcard_terrain")}
    report["postcard_terrain_values"] = sorted({"+".join(t["postcard_terrain"]) for t in tiles if "postcard_terrain" in t})
    return out, report


def main(argv):
    target = POOL
    report_path = None
    for a in argv:
        if a.startswith("--out="):
            target = os.path.abspath(a.split("=", 1)[1])
        elif a.startswith("--report="):
            report_path = os.path.abspath(a.split("=", 1)[1])
    cur = load(target if os.path.exists(target) else POOL)
    data, report = build(cur)
    text = json.dumps(data, ensure_ascii=False, indent=1) + "\n"
    if report_path:
        json.dump(report, open(report_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("POOL_REPORT", json.dumps(report, ensure_ascii=False))
    if "--check" in argv:
        same = os.path.exists(target) and open(target, encoding="utf-8").read() == text
        print("POOL_CHECK", "same" if same else "DIFFERENT"); sys.exit(0 if same else 1)
    open(target, "w", encoding="utf-8").write(text)
    print("POOL", target, "tiles=%d" % len(data["tiles"]))


if __name__ == "__main__":
    main(sys.argv[1:])
