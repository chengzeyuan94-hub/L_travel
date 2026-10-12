#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Flatten the approved probe look (tools/traveler/lookdev_lshu/variants/m_final.json on baseline.json)
into data/traveler/lshu/look.json: common + 4 light presets + the hard-coded module order.

Same merge semantics as the probe viewer (_load_variant/_merge): dictionaries merge recursively, arrays and
scalars replace. Dropped: variant inheritance, merge logs, descriptions, extra_scripts plumbing and debug
switches (l3 measure / zoom / save_mask). Probe shader paths are mapped to shaders/traveler/lshu/.
Usage: python3 tools/traveler/lshu/bake/make_look.py [--check]
  --check  exit 1 if the committed look.json differs from a fresh flatten
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
PROBE = os.path.join(ROOT, "tools", "traveler", "lookdev_lshu", "variants")
OUT = os.path.join(ROOT, "data", "traveler", "lshu", "look.json")
SHADERS = "res://shaders/traveler/lshu/"
SHADER_MAP = {
    "lshu_surface.gdshader": "lshu_surface_base.gdshader",
    "l2_surface.gdshader": "lshu_surface.gdshader",
    "l2_water.gdshader": "lshu_water.gdshader",
    "l2_scatter.gdshader": "lshu_scatter.gdshader",
    "lshu_overlay.gdshader": "lshu_overlay.gdshader",
}
MODULES = [("l1_atmos.gd", "atmos"), ("l2_edges.gd", "edges"), ("l2_surface_detail.gd", "surface_detail"),
           ("l2_scatter.gd", "scatter"), ("l3_life.gd", "life")]
DEBUG_MODULE_KEYS = {"measure", "zoom_m", "zoom_offset", "save_mask"}
SECTION_RENAME = {"l3": "life"}


def merge(a, b):
    out = json.loads(json.dumps(a))
    for k, v in b.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = merge(out[k], v)
        else:
            out[k] = json.loads(json.dumps(v))
    return out


def load_variant(name, depth=0):
    d = json.load(open(os.path.join(PROBE, name + ".json"), encoding="utf-8"))
    if "base" in d:
        b = load_variant(d["base"], depth + 1)
        child = dict(d); child.pop("base")
        scripts = ([] if child.get("extra_scripts_replace") else list(b.get("extra_scripts", []))) + list(child.get("extra_scripts", []))
        child.pop("extra_scripts", None)
        m = merge(b, child); m["extra_scripts"] = scripts
        return m
    return d


def map_shaders(node):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if isinstance(v, str) and v.endswith(".gdshader"):
                fn = v.rsplit("/", 1)[-1]
                if fn not in SHADER_MAP:
                    raise SystemExit("unmapped shader " + v)
                v = SHADERS + SHADER_MAP[fn]
            out[k] = map_shaders(v)
        return out
    if isinstance(node, list):
        return [map_shaders(x) for x in node]
    return node


def rename_sections(cfg):
    # probe section names -> production names; empty sections (probe placeholders) dropped
    out = {}
    for k, val in cfg.items():
        if isinstance(val, dict) and not val:
            continue
        out[SECTION_RENAME.get(k, k)] = val
    return out


def build():
    v = load_variant("m_final")
    scripts = v.get("extra_scripts", [])
    names = [s["script"].rsplit("/", 1)[-1] for s in scripts]
    if names != [m[0] for m in MODULES]:
        raise SystemExit("unexpected module order in m_final: %s" % names)
    modules = {"order": [m[1] for m in MODULES]}
    for s, (_, key) in zip(scripts, MODULES):
        if s.get("lights"):
            raise SystemExit("module %s is light-limited; not supported" % key)
        modules[key] = {k: val for k, val in s.get("cfg", {}).items() if k not in DEBUG_MODULE_KEYS}
    # Parity pin: the probe created the scatter material after its last light application, so motion.wind_strength
    # never reached it and the approved stills / live windows show unbent, still grass. Made explicit here (set a
    # value > 0 to let the grass sway with the wind; l2_sway is already tuned for wind_strength 0.04).
    common = v.setdefault("common", {})
    scatter_role = common.setdefault("surface", {}).setdefault("roles", {}).setdefault("scatter", {})
    if "wind_strength" in scatter_role:
        raise SystemExit("m_final already sets roles.scatter.wind_strength; review the parity pin")
    scatter_role["wind_strength"] = 0.0
    # P0 fix #3: landmark-embedded water (pool tops carry shoreline distance from bake/landmark_water.cjs); global
    # starting values for lshu_water.gdshader, appended to the water role.
    water_role = common["surface"]["roles"].setdefault("water", {})
    if any(k.startswith("l2_pool_") for k in water_role):
        raise SystemExit("m_final already sets l2_pool_* on the water role; review fix #3")
    water_role.update({"l2_pool_slope": 0.8, "l2_pool_depth_mix": 0.75, "l2_pool_foam": 0.45, "l2_pool_bands": 0.0,
                       "l2_pool_foam_frac": 0.15, "l2_pool_ripple": 0.12})
    # P0 fix #4 (smoke): chimney puffs readable instead of invisible (they are one MultiMesh draw now).
    chimney = common.get("l3", {}).get("smoke", {}).get("chimney", {})
    if chimney.get("alpha") != 0.36 or chimney.get("size_end_m") != 0.46:
        raise SystemExit("m_final chimney smoke changed; review fix #4")
    chimney.update({"alpha": 0.6, "size_end_m": 0.6})
    night = v.get("lights", {}).get("night", {})
    night_chimney = night.get("l3", {}).get("smoke", {}).get("chimney", {})
    if night_chimney.get("alpha") != 0.42:
        raise SystemExit("m_final night chimney smoke changed; review fix #4")
    night_chimney["alpha"] = 0.7
    # P0 fix #5 (desert night): sand keeps part of its day chroma at night (lshu_surface.gdshader l2_sand_counter /
    # l2_sand_cast; neutral by default, active in the night preset).
    ground_role = common["surface"]["roles"].setdefault("ground", {})
    night_ground = night.setdefault("surface", {}).setdefault("roles", {}).setdefault("ground", {})
    if any(k.startswith("l2_sand_c") for k in list(ground_role) + list(night_ground)):
        raise SystemExit("m_final already sets l2_sand_counter / l2_sand_cast; review fix #5")
    ground_role.update({"l2_sand_counter": 0.0, "l2_sand_cast": "#ffffff"})
    night_ground.update({"l2_sand_counter": 0.45, "l2_sand_cast": "#a8bff8"})
    # P0 draw-call rule: omni shadows of fires / lamps as dual paraboloid (2 shadow passes instead of 6).
    for section in ("fires", "lamps"):
        if "shadow_mode" in common.get(section, {}):
            raise SystemExit("m_final already sets %s.shadow_mode; review the draw-call rule" % section)
        common.setdefault(section, {})["shadow_mode"] = "dual_paraboloid"
    # "blossom" is also a place id; the potato-flower settings are renamed so no id token appears in look.json
    life_char = common.get("l3", {}).get("character", {})
    if "blossom" in life_char:
        life_char["flowers"] = life_char.pop("blossom")
    for lv in v.get("lights", {}).values():
        lc = lv.get("l3", {}).get("character", {})
        if "blossom" in lc:
            lc["flowers"] = lc.pop("blossom")
    look = {
        "schema": "lshu.look.v1",
        "note": "Approved act-4 look (probe m_final flattened on baseline). Effective config = merge(common, lights.<light>). Colours are sRGB. Global rules only.",
        "modules": modules,
        "common": rename_sections(map_shaders(v.get("common", {}))),
        "lights": {k: rename_sections(val) for k, val in map_shaders(v.get("lights", {})).items()},
    }
    normalise_for_blend(look)
    if "night_lamp" in look["common"]:
        raise SystemExit("m_final already has a night_lamp section; review decision 4")
    look["common"]["night_lamp"] = json.loads(json.dumps(NIGHT_LAMP))
    return look


# P1 continuous light (scripts/traveler/lshu/lshu_look.gd set_light_blend): a blend between two presets must never
# meet a key only one side has, so every key a light preset overrides gets an explicit common value. Each value is
# the fallback the code / shader used when the key was absent, so every preset renders exactly as before.
BLEND_FALLBACKS = {
    "atmos/floor/stars_density": 0.004,               # lshu_look.gd _apply_atmosphere (stars_amount is 0 by day)
    "life/character/rim/local_key_radius_m": 0.0,     # lshu_character.gd on_light
    "life/character/rim/local_key_color": "#ffa060",  # lshu_character.gd on_light (unused while the radius is 0)
    "life/smoke/chimney/self_lit": 0.0,               # lshu_life.gd _push_smoke_uniforms
    "life/smoke/fire/self_lit": 0.0,
    "life/smoke/steam/self_lit": 0.0,
    "surface/roles/water/saturation": 1.0,            # lshu_water.gdshader default
}


def normalise_for_blend(look):
    def leaves(node, path=()):
        for k, val in node.items():
            if isinstance(val, dict):
                yield from leaves(val, path + (k,))
            else:
                yield path + (k,)
    def has(node, path):
        for k in path:
            if not isinstance(node, dict) or k not in node:
                return False
            node = node[k]
        return True
    common = look["common"]
    for light in look["lights"].values():
        for path in leaves(light):
            if has(common, path) or all(has(other, path) for other in look["lights"].values()):
                continue
            key = "/".join(path)
            if key not in BLEND_FALLBACKS:
                raise SystemExit("light preset key %s has no common value; add its fallback to BLEND_FALLBACKS" % key)
            node = common
            for k in path[:-1]:
                node = node.setdefault(k, {})
            node[path[-1]] = BLEND_FALLBACKS[key]


# Decision 4 (recommended default, scripts/traveler/lshu/lshu_night_lamp.gd): at night L叔 always has a camp lantern
# near him. Global starting values; the lantern props themselves are listed in pool.json night_lamp.assets.
NIGHT_LAMP = {
    "enabled": True,
    "near_radius_m": 1.5,
    "front_max_deg": 75.0,
    "prop_scale": 0.85,
    "ring_m": [0.6, 0.72, 0.5, 0.86, 1.0],
    "angles_deg": [55, -55, 70, -70, 40, -40, 85, -85, 100, -100, 30, -30, 120, -120],
    "angle_pref_deg": 55.0,
    "angle_cost_deg": 15.0,
    "ring_pref_m": 0.6,
    "ring_cost_m": 0.12,
    "edge_margin_m": 0.3,
    "path_margin_m": 0.08,
    "clearance_m": 0.06,
    "fire_clearance_m": 0.45,
    "feet_clearance_m": 0.12,
    "max_step_m": 0.06,
    "water_margin_m": 0.03,
    "max_screen_overlap": 0.12,
    "max_prop_cover": 0.3,
    "light_color": "#ffa24a",
    "light_energy": 0.5,
    "light_range": 1.8,
    "light_attenuation": 1.4,
    "character_energy": 0.6,
    "character_range": 2.0,
    "character_attenuation": 1.2,
    "key_ground_radius_m": 0.3,
    "light_height_frac": 0.6,
    "flicker": 0.05,
    "halo_size_m": 0.55,
}


def main(argv):
    look = build()
    text = json.dumps(look, ensure_ascii=False, indent=1, sort_keys=False) + "\n"
    if "--check" in argv:
        cur = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        print("LOOK_CHECK", "same" if cur == text else "DIFFERENT")
        sys.exit(0 if cur == text else 1)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "w", encoding="utf-8").write(text)
    print("LOOK", OUT, len(text), "bytes")


if __name__ == "__main__":
    main(sys.argv[1:])
