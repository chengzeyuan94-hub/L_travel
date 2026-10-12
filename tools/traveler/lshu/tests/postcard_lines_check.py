#!/usr/bin/env python3
"""Validate data/traveler/lshu/postcard_lines.json and show sample postcards.

This is also the reference implementation of the `compose` rules written in the
JSON. The GDScript director does not have to match it bit for bit; it only has to
follow the same rules deterministically for (seed, leg, card).

Usage:
  python3 tools/traveler/lshu/tests/postcard_lines_check.py            # checks + 10 samples
  python3 tools/traveler/lshu/tests/postcard_lines_check.py --sim 5000 # longer simulation

No tile, place or asset IDs are written in this file. Sample stops are chosen by
attributes (biome, kit, city) from whatever tile JSONs exist.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import sys
from typing import Any

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
LIB_PATH = os.path.join(ROOT, "data/traveler/lshu/postcard_lines.json")
POOL_PATH = os.path.join(ROOT, "data/traveler/lshu/pool.json")
TILES_DIR = os.path.join(ROOT, "data/traveler/lshu/tiles")
CITIES_PATH = os.path.join(ROOT, "data/rulesets/lshu_configurable_v1/cities.json")
LORE_PATH = os.path.join(ROOT, "data/rulesets/lshu_configurable_v1/presentation/city_lore_v1.json")
WEB_JOURNEY = os.path.join(ROOT, "tools/traveler/lshu/web_src/config/journey960.json")

EXPECTED = {
    "time": {"morning": 6, "day": 6, "sunset": 6, "night": 6},
    "kit": {"look": 6, "camp": 6, "tea": 6, "bloom": 6},
    "terrain": {"snow": 6, "desert": 6, "grass": 6, "harbour": 6, "rock": 6, "city": 6},
    "road": 10,
    "home": 8,
}
SLOT_WORDS = ["早上", "清早", "天刚亮", "中午", "日头", "傍晚", "日落", "夜里", "夜深", "天黑", "星星", "月亮", "太阳"]
TERRAIN_WORDS = ["雪", "沙", "海", "浪", "岸", "草", "岩", "城", "帐篷", "茶", "火"]
KIT_WORDS_IN_TERRAIN = ["茶", "花"]
ID_PATTERN = re.compile(r"(?<![A-Za-z0-9])[JDSPC]\d{2,3}(?![0-9])")
EMOJI_PATTERN = re.compile("[\U0001F000-\U0001FFFF\u2600-\u27BF\uFE0F]")


def load(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------- rng
def rnd(*parts: Any) -> float:
    digest = hashlib.sha256("|".join(str(p) for p in parts).encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") / float(1 << 64)


def pick_weighted(weights: dict[str, float], r: float) -> str:
    total = sum(weights.values())
    acc = 0.0
    for key, w in weights.items():
        acc += w / total
        if r < acc:
            return key
    return list(weights.keys())[-1]


# ---------------------------------------------------------------- context
def alias_map(lib: dict) -> dict[str, str]:
    out: dict[str, str] = {}
    for key, spec in lib["kits"].items():
        for a in spec["aliases"]:
            out[str(a)] = key
    return out


def terrain_tags(lib: dict, ctx: dict) -> list[str]:
    if ctx.get("postcard_terrain"):
        return list(ctx["postcard_terrain"])
    tr = lib["terrain_resolve"]
    tags: list[str] = []
    if ctx.get("city_id"):
        tags.append("city")
    lf = tr["from_landform"].get(ctx.get("landform") or "")
    if lf and lf not in tags:
        tags.append(lf)
    bi = tr["from_biome"].get(ctx.get("biome") or "")
    if bi and bi not in tags:
        tags.append(bi)
    if not tags:
        tags.append(tr["fallback"])
    return tags


def pick_terrain(lib: dict, tags: list[str], r1: float, r2: float) -> str:
    natural = [t for t in tags if t != "city"]
    if "city" in tags and (not natural or r1 < lib["terrain_resolve"]["pick"]["city_weight"]):
        return "city"
    return natural[min(int(r2 * len(natural)), len(natural) - 1)]


# ---------------------------------------------------------------- compose
def pool_for(lib: dict, cat: str, ctx: dict, group: str) -> list[dict]:
    lines = lib["lines"]
    if cat == "time":
        return lines["time"][ctx["slot"]]
    if cat == "kit":
        return lines["kit"][ctx["kit"]]
    if cat == "terrain":
        return lines["terrain"][group]
    return lines[cat]


def avoided(line: dict, ctx: dict) -> bool:
    for token in line.get("avoid", []):
        kind, _, value = token.partition(":")
        if kind == "slot" and ctx["slot"] == value:
            return True
        if kind == "kit" and ctx["kit"] == value:
            return True
        if kind == "terrain" and value in ctx["terrain_tags"]:
            return True
    return False


def choose(lib: dict, cands: list[dict], ctx: dict, history: list[list[str]], taken: list[dict], r: float,
           strict_motif: bool) -> tuple[dict | None, bool]:
    window = lib["limits"]["no_repeat_window_cards"]
    recent = {i for card in history[-window:] for i in card}
    used_motifs = {m for line in taken for m in line.get("motifs", [])}

    def ok(line: dict, check_motif: bool) -> bool:
        if avoided(line, ctx):
            return False
        if check_motif and used_motifs.intersection(line.get("motifs", [])):
            return False
        return True

    fresh = [l for l in cands if l["id"] not in recent and ok(l, True)]
    if fresh:
        return fresh[min(int(r * len(fresh)), len(fresh) - 1)], False
    # fallback: least recently used, still honouring avoid and motifs
    last_use: dict[str, int] = {}
    for idx, card in enumerate(history):
        for i in card:
            last_use[i] = idx
    for check_motif in ([True, False] if not strict_motif else [True]):
        pool = [l for l in cands if ok(l, check_motif)]
        if pool:
            pool.sort(key=lambda l: (last_use.get(l["id"], -1), l["id"]))
            return pool[0], True
    return None, True


def compose(lib: dict, raw_ctx: dict, history: list[list[str]], key: tuple) -> dict:
    kits = alias_map(lib)
    slot_alias = lib["input_contract"]["slot"]["aliases"]
    ctx = dict(raw_ctx)
    ctx["slot"] = slot_alias.get(ctx["slot"], ctx["slot"])
    ctx["kit"] = kits[str(ctx["kit"])]
    ctx["terrain_tags"] = terrain_tags(lib, ctx)
    comp = lib["compose"]
    step = iter(range(100))

    def r() -> float:
        return rnd(*key, next(step))

    # step 2: primary category
    prim = comp["primary"]
    if ctx.get("away_card"):
        primary = "road"
    elif ctx.get("is_home"):
        primary = "home"
    else:
        primary = ""
        m = ctx.get("minutes_since_arrive", 999)
        r_long, r_fresh = r(), r()
        if ctx.get("after_long_road") and m <= prim["road_after_long_road"]["max_minutes_since_arrive"] \
                and r_long < prim["road_after_long_road"]["p"]:
            primary = "road"
        elif m <= prim["road_fresh_arrival"]["max_minutes_since_arrive"] and r_fresh < prim["road_fresh_arrival"]["p"]:
            primary = "road"
        if not primary:
            weights = prim["weights_overnight"] if ctx.get("is_overnight") else prim["weights"]
            primary = pick_weighted(weights, r())
    group = pick_terrain(lib, ctx["terrain_tags"], r(), r())
    taken: list[dict] = []
    fallbacks = 0
    first, fb = choose(lib, pool_for(lib, primary, ctx, group), ctx, history, taken, r(), strict_motif=False)
    fallbacks += int(fb)
    taken.append(first)
    cats = [primary]

    # step 4: optional second line
    sl = comp["second_line"]
    p_second = 0.0 if ctx.get("away_card") else (sl["p_home"] if primary == "home" else sl["p"])
    if r() < p_second:
        weights = {k: v for k, v in sl["weights_by_primary"][primary].items() if k != primary}
        second_cat = pick_weighted(weights, r())
        for attempt in range(2):
            line, fb = choose(lib, pool_for(lib, second_cat, ctx, group), ctx, history, taken, r(), strict_motif=True)
            if line is None:
                break
            if len(first["text"]) + len(line["text"]) <= lib["limits"]["max_card_chars"]:
                fallbacks += int(fb)
                taken.append(line)
                cats.append(second_cat)
                break
    order = comp["card_order"]
    pairs = sorted(zip(cats, taken), key=lambda p: order.index(p[0]))
    return {
        "categories": [c for c, _ in pairs],
        "terrain_group": group if "terrain" in cats else "",
        "line_ids": [l["id"] for _, l in pairs],
        "text": comp["joiner"].join(l["text"] for _, l in pairs),
        "fallbacks": fallbacks,
        "ctx": ctx,
    }


# ---------------------------------------------------------------- stamp
def city_index() -> tuple[dict[str, str], dict[str, dict]]:
    by_name = {c["display_name"]: c["id"] for c in load(CITIES_PATH)["items"]}
    lore = {it["city_id"]: it for it in load(LORE_PATH)["items"]}
    return by_name, lore


def stamp(lib: dict, ctx: dict, lore: dict[str, dict], subs: dict[str, str]) -> str:
    st = lib["stamp"]
    title = ctx["place_name"]
    caption = ""
    if ctx.get("city_id"):
        item = lore.get(ctx["city_id"])
        cl = st["city_lookup"]
        if item and not (item.get("verification_status") == cl["blocked_status"] and cl["blocked_policy"] == "omit"):
            caption = item.get("epithet", "")
    else:
        caption = subs.get(ctx.get("place_key", ""), "")
    label = st["slot_labels"][ctx["slot"]]
    home = ("  " + st["home_mark"]) if ctx.get("is_home") else ""
    return f"[{title}{home}｜9月24日 {label}]" + (f"  {caption}" if caption else "")


# ---------------------------------------------------------------- checks
def check_library(lib: dict) -> list[str]:
    errs: list[str] = []
    lines = lib["lines"]
    ids: list[str] = []
    all_lines: list[tuple[str, dict]] = []
    for cat in ("time", "kit", "terrain"):
        for key, n in EXPECTED[cat].items():
            got = lines[cat].get(key, [])
            if len(got) != n:
                errs.append(f"{cat}.{key}: {len(got)} lines, expected {n}")
            all_lines += [(f"{cat}.{key}", l) for l in got]
    for cat in ("road", "home"):
        if len(lines[cat]) != EXPECTED[cat]:
            errs.append(f"{cat}: {len(lines[cat])} lines, expected {EXPECTED[cat]}")
        all_lines += [(cat, l) for l in lines[cat]]
    names_to_block: list[str] = []
    by_name, lore = city_index()
    names_to_block += list(by_name.keys())
    if os.path.exists(WEB_JOURNEY):
        for p in load(WEB_JOURNEY)["places"]:
            names_to_block.append(p["name"])
            names_to_block += [s.strip() for s in p["name"].split("·")]
    for tile in glob.glob(os.path.join(TILES_DIR, "*.json")):
        place = load(tile).get("place", {})
        if place.get("name"):
            names_to_block += [s.strip() for s in place["name"].split("·")]
    names_to_block = sorted({n for n in names_to_block if len(n) >= 2})
    max_len = lib["limits"]["max_line_chars"]
    for where, l in all_lines:
        t = l["text"]
        ids.append(l["id"])
        if len(t) > max_len:
            errs.append(f"{l['id']}: {len(t)} chars > {max_len}")
        if not t.endswith("。"):
            errs.append(f"{l['id']}: does not end with 。")
        if re.search(r"[A-Za-z0-9]", t):
            errs.append(f"{l['id']}: ASCII letter or digit")
        if EMOJI_PATTERN.search(t):
            errs.append(f"{l['id']}: emoji")
        if "L叔" in t:
            errs.append(f"{l['id']}: contains signature")
        for n in names_to_block:
            if n in t:
                errs.append(f"{l['id']}: place name {n}")
        if where.startswith("time."):
            for w in TERRAIN_WORDS:
                if w in t:
                    errs.append(f"{l['id']}: time line mentions terrain/kit word {w}")
        else:
            for w in SLOT_WORDS:
                if w in t:
                    errs.append(f"{l['id']}: non-time line mentions slot word {w}")
        if where.startswith("terrain."):
            for w in KIT_WORDS_IN_TERRAIN:
                if w in t:
                    errs.append(f"{l['id']}: terrain line mentions kit word {w}")
        for token in l.get("avoid", []):
            kind, _, value = token.partition(":")
            valid = {"slot": EXPECTED["time"], "kit": EXPECTED["kit"], "terrain": EXPECTED["terrain"]}.get(kind)
            if valid is None or value not in valid:
                errs.append(f"{l['id']}: bad avoid token {token}")
    if len(ids) != len(set(ids)):
        errs.append("duplicate line ids")
    text = json.dumps(lib, ensure_ascii=False)
    if ID_PATTERN.search(text):
        errs.append(f"ID-like token in library: {ID_PATTERN.search(text).group(0)}")
    slugs: set[str] = set()
    if os.path.exists(WEB_JOURNEY):
        slugs |= {p["id"] for p in load(WEB_JOURNEY)["places"]}
    for tile in glob.glob(os.path.join(TILES_DIR, "*.json")):
        slugs.add(str(load(tile).get("place", {}).get("id", "")))
    slugs.discard("")
    for token in iter_strings(lib):
        if token in slugs:
            errs.append(f"place slug used as a key or value in library: {token}")
    return errs


def iter_strings(node: Any):
    if isinstance(node, dict):
        for k, v in node.items():
            yield k
            yield from iter_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from iter_strings(v)
    elif isinstance(node, str):
        yield node


def tile_contexts(pool: dict) -> tuple[list[dict], dict | None]:
    by_name, _ = city_index()
    home_id = pool.get("home", "")
    stops: list[dict] = []
    home: dict | None = None
    for tile in sorted(glob.glob(os.path.join(TILES_DIR, "*.json"))):
        d = load(tile)
        place, kit = d.get("place", {}), d.get("kit", {})
        ctx = {
            "place_key": place.get("id", ""),
            "place_name": place.get("name", ""),
            "biome": place.get("theme", ""),
            "landform": place.get("landform", ""),
            "city_id": by_name.get(place.get("city") or "", ""),
            "kit": kit.get("mode", kit.get("id", 0)),
        }
        if d.get("id") == home_id:
            home = ctx
        stops.append(ctx)
    return stops, home


def simulate(lib: dict, stops: list[dict], n: int, seed: int) -> dict:
    history: list[list[str]] = []
    stats = {"cards": 0, "two_line": 0, "fallbacks": 0, "repeat_in_window": 0, "motif_clash": 0,
             "over_len": 0, "same_cat": 0, "avoid_hit": 0, "cats": {}}
    lines_by_id = {}
    for cat, spec in lib["lines"].items():
        groups = spec.values() if isinstance(spec, dict) else [spec]
        for g in groups:
            for l in g:
                lines_by_id[l["id"]] = l
    slots = ["morning", "day", "sunset", "night"]
    outputs = []
    for i in range(n):
        s = stops[int(rnd(seed, "stop", i) * len(stops))]
        ctx = dict(s)
        ctx["slot"] = slots[int(rnd(seed, "slot", i) * 4)]
        ctx["is_home"] = rnd(seed, "home", i) < 0.08
        ctx["is_overnight"] = (not ctx["is_home"]) and rnd(seed, "night", i) < 0.15
        if ctx["is_overnight"]:
            ctx["kit"] = "camp" if rnd(seed, "k", i) < 0.5 else "tea"
        ctx["after_long_road"] = rnd(seed, "long", i) < 0.15
        ctx["minutes_since_arrive"] = int(rnd(seed, "min", i) * 60)
        card = compose(lib, ctx, history, (seed, i, 0))
        window = lib["limits"]["no_repeat_window_cards"]
        recent = {x for c in history[-window:] for x in c}
        if card["fallbacks"] == 0 and recent.intersection(card["line_ids"]):
            stats["repeat_in_window"] += 1
        ls = [lines_by_id[x] for x in card["line_ids"]]
        if len(ls) == 2:
            stats["two_line"] += 1
            if set(ls[0].get("motifs", [])) & set(ls[1].get("motifs", [])):
                stats["motif_clash"] += 1
            if card["categories"][0] == card["categories"][1]:
                stats["same_cat"] += 1
        for l in ls:
            if avoided(l, card["ctx"]):
                stats["avoid_hit"] += 1
        if sum(len(l["text"]) for l in ls) > lib["limits"]["max_card_chars"]:
            stats["over_len"] += 1
        stats["fallbacks"] += card["fallbacks"]
        for c in card["categories"]:
            stats["cats"][c] = stats["cats"].get(c, 0) + 1
        history.append(card["line_ids"])
        outputs.append(card["text"])
        stats["cards"] += 1
    stats["digest"] = hashlib.sha256("\n".join(outputs).encode("utf-8")).hexdigest()[:16]
    return stats


def samples(lib: dict, stops: list[dict], home: dict | None, seed: int) -> list[str]:
    _, lore = city_index()
    subs: dict[str, str] = {}
    if os.path.exists(WEB_JOURNEY):
        subs = {p["id"]: p["sub"] for p in load(WEB_JOURNEY)["places"] if not p.get("city")}
    blocked = {k for k, v in lore.items() if v.get("verification_status") == "CONTENT_BLOCKED"}

    def find(pred) -> dict | None:
        for s in stops:
            if pred(s):
                return dict(s)
        return None

    specs = [
        ("回家那晚", lambda s: home is not None and s is home, dict(slot="night", is_home=True, kit="tea")),
        ("在家的早上", lambda s: home is not None and s is home, dict(slot="morning", is_home=True, kit="tea")),
        ("雪地过夜站", lambda s: s["biome"] == "snow" and s is not home, dict(slot="night", is_overnight=True, kit="camp", minutes_since_arrive=200)),
        ("沙漠远望，傍晚", lambda s: s["biome"] == "desert" and not s["city_id"] and str(s["kit"]) == "look", dict(slot="sunset", minutes_since_arrive=30)),
        ("城市，白天远望", lambda s: s["city_id"] and s["city_id"] not in blocked and str(s["kit"]) == "look", dict(slot="day", minutes_since_arrive=25)),
        ("称号待裁决的城市，扎营", lambda s: s["city_id"] in blocked, dict(slot="sunset", kit="camp", minutes_since_arrive=40)),
        ("水岸，早上", lambda s: s["biome"] == "harbor" and not s["city_id"], dict(slot="morning", minutes_since_arrive=35)),
        ("山石地，走完远路刚到", lambda s: s["landform"] in ("ridge", "ruin") and not s["city_id"], dict(slot="day", after_long_road=True, minutes_since_arrive=3)),
        ("草木地，喝茶", lambda s: s["biome"] == "autumn" and not s["city_id"] and str(s["kit"]) == "tea", dict(slot="day", minutes_since_arrive=20)),
        ("拾花", lambda s: str(s["kit"]) in ("encounter", "3") and not s["city_id"], dict(slot="day", minutes_since_arrive=15)),
    ]
    out: list[str] = []
    history: list[list[str]] = []
    for idx, (label, pred, extra) in enumerate(specs):
        s = find(pred)
        if s is None:
            out.append(f"{idx + 1:02d} {label}: 没有匹配的地块，跳过")
            continue
        ctx = dict(s)
        ctx.update({"is_home": False, "is_overnight": False, "after_long_road": False, "minutes_since_arrive": 30})
        ctx.update(extra)
        card = compose(lib, ctx, history, (seed, idx, 0))
        history.append(card["line_ids"])
        head = stamp(lib, card["ctx"], lore, subs)
        body = card["text"].replace("\n", " / ")
        out.append(f"{idx + 1:02d} {label}  {head}\n    {body}    ({'+'.join(card['categories'])}; {', '.join(card['line_ids'])})")
    away = compose(lib, {"slot": "day", "kit": "look", "biome": "", "away_card": True, "place_name": ""}, history, (seed, "away", 0))
    out.append(f"11 「你不在的时候」小卡的一句: {away['text']}    ({', '.join(away['line_ids'])})")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=20260924)
    args = ap.parse_args()
    lib = load(LIB_PATH)
    errs = check_library(lib)
    n_lines = sum(len(v) for g in ("time", "kit", "terrain") for v in lib["lines"][g].values()) \
        + len(lib["lines"]["road"]) + len(lib["lines"]["home"])
    print(f"lines: {n_lines}")
    print(f"static errors: {len(errs)}")
    for e in errs:
        print("  ERROR", e)
    pool = load(POOL_PATH) if os.path.exists(POOL_PATH) else {}
    stops, home = tile_contexts(pool)
    if not stops:
        print("no tile JSON found; skipped simulation and samples")
        return 1 if errs else 0
    s1 = simulate(lib, stops, args.sim, args.seed)
    s2 = simulate(lib, stops, args.sim, args.seed)
    print(f"simulation: {json.dumps(s1, ensure_ascii=False)}")
    print(f"deterministic: {s1['digest'] == s2['digest']}")
    sim_errs = s1["repeat_in_window"] + s1["motif_clash"] + s1["over_len"] + s1["same_cat"] + s1["avoid_hit"]
    print(f"simulation violations: {sim_errs}")
    print("--- samples ---")
    for line in samples(lib, stops, home, args.seed):
        print(line)
    return 1 if (errs or sim_errs or s1["digest"] != s2["digest"]) else 0


if __name__ == "__main__":
    sys.exit(main())
