#!/usr/bin/env python3
"""Export the Python reference postcards for test_postcard_rules.gd to compare card by card.

Uses compose() / stamp() / simulate() from postcard_lines_check.py unchanged (imported, not copied).
Two scenarios, 2000 cards each, fixed seeds:
  sim   the context generator of simulate() (seed 20260924): tile stops, 4 slots, 8% home,
        15% overnight, 15% after a long road, 0-59 minutes since arrival.
  edge  seed 7: slot aliases, numeric kit aliases, 10% home, 20% overnight, 30% after a long road,
        0-39 minutes (5% missing), 5% away cards, 12% postcard_terrain overrides.
  tight seed 11, the edge generator on a copy of the library with max_card_chars 30 and
        no_repeat_window_cards 8, so the "too long, draw once more, else main line only" rule and
        the least-recently-used fallback run often (with 50 no pair of current lines is too long).
Every card carries its generated input context, its output and its stamp under blocked_policy
"omit" (the library's value) and "show". No tile, place or asset id is written in this file.

Also 300 sums of 2-5 floats (CPython 3.12 sum() is compensated, not left to right) and 300 raw draws of rnd() (as the two 32-bit halves of rnd * 2^64) to check the random stream.
The output (about 3 MB) goes to the OS temp folder by default; test_postcard_rules.gd runs this
script itself when it is not given --ref=PATH.

Usage:
  python3 -B tools/traveler/lshu/tests/postcard_rules_export.py [--out PATH] [--n 2000]
"""
from __future__ import annotations

import argparse
import copy
import functools
import hashlib
import json
import math
import os
import platform
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import postcard_lines_check as ref  # noqa: E402

DEFAULT_OUT = os.path.join(tempfile.gettempdir(), "lshu_postcard_rules_ref.json")
SIM_SEED = 20260924
EDGE_SEED = 7
TIGHT_SEED = 11
TIGHT_LIMITS = {"max_card_chars": 30, "no_repeat_window_cards": 8}
SLOTS = ["morning", "day", "sunset", "night"]
EDGE_SLOTS = ["morning", "day", "sunset", "night", "dusk", "evening", "noon", "dawn"]
KIT_NUM = {"look": 0, "camp": 1, "tea": 2, "encounter": 3, "bloom": 3}
EDGE_KITS = ["look", "camp", "tea", "encounter", "bloom", 0, 1, 2, 3]
GROUPS = ["snow", "desert", "grass", "harbour", "rock", "city"]
DATE = "9月24日"


def sim_ctx(seed: int, i: int, stops: list[dict]) -> dict:
    """Exactly the per-card context of postcard_lines_check.simulate()."""
    rnd = ref.rnd
    s = stops[int(rnd(seed, "stop", i) * len(stops))]
    ctx = dict(s)
    ctx["slot"] = SLOTS[int(rnd(seed, "slot", i) * 4)]
    ctx["is_home"] = rnd(seed, "home", i) < 0.08
    ctx["is_overnight"] = (not ctx["is_home"]) and rnd(seed, "night", i) < 0.15
    if ctx["is_overnight"]:
        ctx["kit"] = "camp" if rnd(seed, "k", i) < 0.5 else "tea"
    ctx["after_long_road"] = rnd(seed, "long", i) < 0.15
    ctx["minutes_since_arrive"] = int(rnd(seed, "min", i) * 60)
    return ctx


def edge_ctx(seed: int, i: int, stops: list[dict]) -> dict:
    rnd = ref.rnd
    s = stops[int(rnd(seed, "stop", i) * len(stops))]
    ctx = dict(s)
    ctx["slot"] = EDGE_SLOTS[int(rnd(seed, "slot", i) * len(EDGE_SLOTS))]
    kv = rnd(seed, "kitv", i)
    if kv < 0.3:
        ctx["kit"] = KIT_NUM[str(ctx["kit"])] if str(ctx["kit"]) in KIT_NUM else ctx["kit"]
    elif kv < 0.4:
        ctx["kit"] = EDGE_KITS[int(rnd(seed, "kitp", i) * len(EDGE_KITS))]
    ctx["is_home"] = rnd(seed, "home", i) < 0.1
    ctx["is_overnight"] = (not ctx["is_home"]) and rnd(seed, "night", i) < 0.2
    ctx["after_long_road"] = rnd(seed, "long", i) < 0.3
    if rnd(seed, "nomin", i) >= 0.05:
        ctx["minutes_since_arrive"] = int(rnd(seed, "min", i) * 40)
    ctx["away_card"] = rnd(seed, "away", i) < 0.05
    pt = rnd(seed, "pt", i)
    if pt < 0.08:
        ctx["postcard_terrain"] = [GROUPS[int(rnd(seed, "ptg", i) * 6)]]
    elif pt < 0.12:
        ctx["postcard_terrain"] = ["city", GROUPS[int(rnd(seed, "ptg", i) * 5)]]
    return ctx


def rnd_samples(n: int) -> list[dict]:
    words = ["stop", "slot", "home", "明信片|邮戳", "", "away"]
    out = []
    for j in range(n):
        parts = [SIM_SEED + j % 3, words[j % len(words)], j, (j * 7919) % 1000003]
        x = int(ref.rnd(*parts) * 2 ** 64)
        out.append({"parts": parts, "hi": x >> 32, "lo": x & 0xFFFFFFFF})
    return out


def sum_samples(n: int) -> list[dict]:
    out = []
    for j in range(n):
        ints = [int(ref.rnd("sum", j, q) * 3000) + 1 for q in range(2 + j % 4)]
        xs = [v / 1000 for v in ints]
        total = sum(xs)
        m, e = math.frexp(total)
        out.append({"ints": ints, "mant": int(m * 2 ** 53), "exp": e,
                    "naive_same": functools.reduce(lambda a, b: a + b, xs) == total})
    return out


def run(lib: dict, lib_show: dict, stops: list[dict], gen, seed: int, n: int, lore: dict, subs: dict) -> dict:
    history: list[list[str]] = []
    cards = []
    outputs = []
    for i in range(n):
        ctx = gen(seed, i, stops)
        card = ref.compose(lib, ctx, history, (seed, i, 0))
        cards.append({
            "i": i,
            "in": ctx,
            "categories": card["categories"],
            "terrain_group": card["terrain_group"],
            "line_ids": card["line_ids"],
            "text": card["text"],
            "fallbacks": card["fallbacks"],
            "slot": card["ctx"]["slot"],
            "kit": card["ctx"]["kit"],
            "terrain_tags": card["ctx"]["terrain_tags"],
            "stamp_omit": ref.stamp(lib, card["ctx"], lore, subs),
            "stamp_show": ref.stamp(lib_show, card["ctx"], lore, subs),
        })
        history.append(card["line_ids"])
        outputs.append(card["text"])
    return {
        "seed": seed, "n": n, "cards": cards,
        "digest": hashlib.sha256("\n".join(outputs).encode("utf-8")).hexdigest()[:16],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--n", type=int, default=2000)
    args = ap.parse_args()
    lib = ref.load(ref.LIB_PATH)
    lib_show = copy.deepcopy(lib)
    lib_show["stamp"]["city_lookup"]["blocked_policy"] = "show"
    pool = ref.load(ref.POOL_PATH) if os.path.exists(ref.POOL_PATH) else {}
    stops, _home = ref.tile_contexts(pool)
    if not stops:
        print("no tile JSON found", file=sys.stderr)
        return 1
    _by_name, lore = ref.city_index()
    subs: dict[str, str] = {}
    if os.path.exists(ref.WEB_JOURNEY):
        subs = {p["id"]: p["sub"] for p in ref.load(ref.WEB_JOURNEY)["places"] if not p.get("city")}
    sim = run(lib, lib_show, stops, sim_ctx, SIM_SEED, args.n, lore, subs)
    sim_stats = ref.simulate(lib, stops, args.n, SIM_SEED)
    edge = run(lib, lib_show, stops, edge_ctx, EDGE_SEED, args.n, lore, subs)
    lib_tight = copy.deepcopy(lib)
    lib_tight["limits"].update(TIGHT_LIMITS)
    lib_tight_show = copy.deepcopy(lib_tight)
    lib_tight_show["stamp"]["city_lookup"]["blocked_policy"] = "show"
    tight = run(lib_tight, lib_tight_show, stops, edge_ctx, TIGHT_SEED, args.n, lore, subs)
    out = {
        "schema": "lshu.postcard_rules_ref.v1",
        "python": platform.python_version(),
        "library_version": lib.get("version", ""),
        "date_text": DATE,
        "stops": stops,
        "scenarios": {"sim": sim, "edge": edge, "tight": tight},
        "tight_limits": TIGHT_LIMITS,
        "simulate_stats": sim_stats,
        "static_errors": ref.check_library(lib),
        "rnd_samples": rnd_samples(300),
        "sum_samples": sum_samples(300),
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=0)
    print(f"POSTCARD_RULES_REF out={args.out} python={out['python']} stops={len(stops)} "
          f"sim={len(sim['cards'])} digest={sim['digest']} simulate_digest={sim_stats['digest']} "
          f"edge={len(edge['cards'])} digest={edge['digest']} tight={len(tight['cards'])} digest={tight['digest']} static_errors={len(out['static_errors'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
