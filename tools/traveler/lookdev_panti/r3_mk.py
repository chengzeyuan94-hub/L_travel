#!/usr/bin/env python3
# r3 lens (look fidelity) helper: build r3_* test variants from m2_abc_p1 by applying named edits.
# usage: r3_mk.py <out> <edit>[+<edit>...] [src]
import json, sys, os, copy
V = os.path.join(os.path.dirname(os.path.abspath(__file__)), "variants")

def script_cfg(d, suffix):
    for it in d["static"]["extra_scripts"]:
        if it["script"].endswith(suffix) or (suffix == "a_extra_rim.gd" and it["script"].endswith("r3_extra_rim.gd")):
            return it["cfg"]

def light(d, per, name):
    return d[per]["lights"].setdefault(name, {})

E = {}
def edit(f): E[f.__name__] = f; return f

# ---------- diagnostics ----------
@edit
def d_nobounce(d):
    for per in ("morning", "midnight"):
        light(d, per, "C_BounceCamp")["light_energy"] = 0.0
        light(d, per, "C_BounceCastle")["light_energy"] = 0.0
@edit
def d_norimchar(d):
    for per in ("morning", "midnight"):
        d[per]["shaders"]["a_rim_char.gdshader"]["rim_intensity"] = 0.0
        d[per]["shaders"]["a_rim_char.gdshader"]["fire_intensity"] = 0.0
@edit
def d_nocharC(d):
    for l in script_cfg(d, "c_warm_bounce.gd")["lights"]:
        if "char" in l.get("mask", []):
            l["mask"] = [m for m in l["mask"] if m != "char"]
@edit
def d_basesun(d):
    # A line's sun/moon/ambient back to scene defaults (remove keys)
    for per in ("morning", "midnight"):
        d[per].pop("sun", None); d[per].pop("env", None)

@edit
def d_noCground(d):
    for l in script_cfg(d, "c_warm_bounce.gd")["lights"]:
        if l.get("mask") == ["ground"]:
            for per in ("morning","midnight"):
                light(d, per, l["name"])["light_energy"] = 0.0
@edit
def d_noB(d):
    d["static"]["extra_scripts"] = [it for it in d["static"]["extra_scripts"] if not it["script"].endswith("b_snow_extra.gd")]
@edit
def d_noA(d):
    d["static"]["extra_scripts"] = [it for it in d["static"]["extra_scripts"] if not it["script"].endswith("a_extra_rim.gd")]

# ---------- fixes ----------
def sh(d, per, f): return d[per]["shaders"][f]
@edit
def f_bounce(d):
    # C directional bounces: never on the character; morning much gentler; off at midnight
    # (at 0.03 / 0.12 they add almost no diffuse but trigger a full-strength second rim in A's hue-only directional rim passes)
    for l in script_cfg(d, "c_warm_bounce.gd")["lights"]:
        if l["name"] == "C_BounceCamp":
            l["mask"] = [m for m in l["mask"] if m != "char"]
    light(d, "morning", "C_BounceCamp")["light_energy"] = 0.2
    light(d, "morning", "C_BounceCastle")["light_energy"] = 0.05
    light(d, "midnight", "C_BounceCamp")["light_energy"] = 0.0
    light(d, "midnight", "C_BounceCastle")["light_energy"] = 0.0
@edit
def f_firepool(d):
    light(d, "midnight", "C_FirePool").update({"light_energy": 0.7, "omni_range": 1.35})
@edit
def f_charrim(d):
    sh(d, "morning", "a_rim_char.gdshader").update({"rim_intensity": 0.45, "back_floor": 0.15, "rim_lo": 0.72, "rim_hi": 0.95})
    sh(d, "midnight", "a_rim_char.gdshader").update({"rim_intensity": 0.35, "rim_lo": 0.74, "rim_hi": 0.96, "fire_intensity": 1.4, "fire_lo": 0.6})
@edit
def f_treenight(d):
    c = script_cfg(d, "a_extra_rim.gd")
    c["trees"]["gain_night"].update({"G": 0.25, "L": 0.35})
    sh(d, "midnight", "a_rim_edge_tree.gdshader")["up_boost"] = 0.5
@edit
def f_edgenight(d):
    c = script_cfg(d, "a_extra_rim.gd")
    c["castle"]["gain_night"] = 1.3
    c["rocks"]["gain_night"] = 0.35
@edit
def f_sunangle(d):
    d["morning"]["sun"].update({"sunel": -18.0, "sunaz": -58.0})

@edit
def f_v2(d):
    cl = script_cfg(d, "c_warm_bounce.gd")["lights"]
    for l in cl:
        if l["name"] == "C_FireBounce":
            l["mask"] = ["camp"]
        if l["name"] == "C_BounceCamp":
            l["mask"] = ["camp"]
    light(d, "morning", "C_FireBounce")["light_energy"] = 0.05
    light(d, "midnight", "C_FireBounce")["light_energy"] = 0.08
    light(d, "midnight", "C_FireReach")["light_energy"] = 0.18
    light(d, "morning", "C_BounceCamp")["light_energy"] = 0.15
    c = script_cfg(d, "a_extra_rim.gd")
    c["trees"]["gain"]["G"] = 0.55
    c["trees"]["gain_night"]["G"] = 0.12
    sh(d, "midnight", "a_rim_edge_tree.gdshader")["up_boost"] = 0.3
    c["rocks"]["gain_night"] = 0.25
    for per in ("morning", "midnight"):
        d[per]["materials"]["SnowRocks_*"] = {"roughness": 0.8, "metallic_specular": 0.6}

@edit
def f_v3(d):
    d["midnight"]["sun"]["light_energy"] = 0.58
    for n, e in (("C_WallGlowL", 0.65), ("C_WallGlowLG", 0.65), ("C_WallGlowGF", 0.65), ("C_WallGlowT", 0.35), ("C_WallGlowR", 0.35)):
        light(d, "midnight", n)["light_energy"] = e
    light(d, "midnight", "C_FirePool").update({"light_energy": 0.5, "omni_range": 1.2})
    for per in ("morning", "midnight"):
        light(d, per, "C_FireBounce")["light_energy"] = 0.0
    light(d, "midnight", "C_FireReach")["light_energy"] = 0.12
    light(d, "morning", "C_BounceCamp")["light_energy"] = 0.08

@edit
def d_nopropmat(d):
    for per in ("morning", "midnight"):
        for k in ("Stump", "Tent", "Firepit"):
            d[per]["materials"].pop(k, None)
@edit
def d_norockmat(d):
    for per in ("morning", "midnight"):
        d[per]["materials"].pop("SnowRocks_*", None)
    script_cfg(d, "c_warm_bounce.gd")["rock_override"] = False

@edit
def f_errfix(d):
    # A's prop rim (surface-override next_pass) + watcher material_override copies of Stump/Tent -> engine "material is null" at teardown
    for per in ("morning", "midnight"):
        for k in ("Stump", "Tent"):
            d[per]["materials"].pop(k, None)
@edit
def d_nomornbounce(d):
    light(d, "morning", "C_BounceCamp")["light_energy"] = 0.0
    light(d, "morning", "C_BounceCastle")["light_energy"] = 0.0

@edit
def f_gate(d):
    for it in d["static"]["extra_scripts"]:
        if it["script"].endswith("a_extra_rim.gd"):
            it["script"] = "res://tools/traveler/lookdev_panti/r3_extra_rim.gd"
    for per in ("morning", "midnight"):
        d[per]["shaders"]["r3_rim_edge.gdshader"] = d[per]["shaders"].pop("a_rim_edge.gdshader")

@edit
def f_v6(d):
    light(d, "morning", "C_BounceCastle")["light_energy"] = 0.0
    c = script_cfg(d, "a_extra_rim.gd")
    c["trees"]["gain_night"].update({"M": 0.8, "L": 0.4})
    sh(d, "midnight", "a_rim_edge_tree.gdshader")["up_boost"] = 0.0

@edit
def f_v7(d):
    # keep p1's midground frost sparkle (L/M gains, up_boost 1.0); only the foreground G tier is cut
    c = script_cfg(d, "a_extra_rim.gd")
    c["trees"]["gain_night"].update({"G": 0.12, "L": 0.5, "M": 0.65})
    sh(d, "midnight", "a_rim_edge_tree.gdshader")["up_boost"] = 1.0

@edit
def f_v8(d):
    script_cfg(d, "a_extra_rim.gd")["trees"]["gain"]["G"] = 0.3

@edit
def f_v9(d):
    sh(d, "midnight", "b_snow_surface.gdshader")["vr_strength"] = 2.0

def main(out, edits, src="m2_abc_p1"):
    d = json.load(open(os.path.join(V, src + ".json"), encoding="utf-8"))
    d = copy.deepcopy(d)
    for n in edits.split("+"):
        E[n](d)
    d["_r3_from"] = src; d["_r3_edits"] = edits
    json.dump(d, open(os.path.join(V, out + ".json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("wrote", out)

if __name__ == "__main__":
    main(*sys.argv[1:])
