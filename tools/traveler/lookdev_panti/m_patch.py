#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导演修正：在合并 variant 上打补丁生成新 variant。用法：m_patch.py <源> <输出> <补丁名>"""
import json, sys, os
V = os.path.join(os.path.dirname(os.path.abspath(__file__)), "variants")

def rim_cfg(d):
    for it in d["static"]["extra_scripts"]:
        if it["script"].endswith("a_extra_rim.gd"):
            return it["cfg"]

PATCHES = {}
def patch(f): PATCHES[f.__name__] = f; return f

@patch
def p1(d):
    # 人物：边光减半、篝火暖边减弱；深夜前景树月光边减弱去饱和；清晨城堡反弹光 0.22→0.15
    d["morning"]["shaders"]["a_rim_char.gdshader"]["rim_intensity"] = 0.9
    d["midnight"]["shaders"]["a_rim_char.gdshader"]["rim_intensity"] = 0.75
    d["midnight"]["shaders"]["a_rim_char.gdshader"]["fire_intensity"] = 2.0
    c = rim_cfg(d)
    c["trees"]["gain_night"].update({"G": 0.5, "L": 0.5, "M": 0.65, "F": 0.45})
    for k in ("a_rim_edge_tree.gdshader", "a_rim_edge.gdshader"):
        d["midnight"]["shaders"][k]["rim_tint"] = [0.62, 0.78, 1.0]
    d["morning"]["lights"]["C_BounceCastle"]["light_energy"] = 0.15

def c_cfg(d):
    for it in d["static"]["extra_scripts"]:
        if it["script"].endswith("c_warm_bounce.gd"):
            return it["cfg"]

@patch
def nochar_c(d):
    # 诊断：C 线的灯都不照人物
    for l in c_cfg(d)["lights"]:
        if "char" in l.get("mask", []):
            l["mask"] = [m for m in l["mask"] if m != "char"]

@patch
def norim_char(d):
    # 诊断：A 线人物边光关掉
    for per in ("morning", "midnight"):
        d[per]["shaders"]["a_rim_char.gdshader"]["rim_intensity"] = 0.0
        d[per]["shaders"]["a_rim_char.gdshader"]["fire_intensity"] = 0.0

@patch
def p2(d):
    # 验收残留收尾：人物边光不再压描边；深夜火前雪面去粉白；城堡边光过渡中段不闪；深夜旗子 / 帐篷收一点
    for per in ("morning", "midnight"):
        d[per]["shaders"]["r1_rim_char.gdshader"]["depth_push"] = 0.0
    d["midnight"]["lights"]["C_FirePool"]["light_energy"] = 0.30
    d["midnight"]["shaders"]["b_snow_surface.gdshader"]["vr_strength"] = 1.4
    d["midnight"]["shaders"]["b_snow_surface.gdshader"]["vr_color"] = [1.0, 0.42, 0.12]
    d["midnight"]["lights"]["C_FireReach"]["light_energy"] = 0.08
    d["morning"]["lights"]["C_BounceCamp"]["light_energy"] = 0.06
    for it in d["static"]["extra_scripts"]:
        if it["script"].endswith("r1_extra_rim.gd"):
            it["cfg"]["props"]["gain_night"] = 0.2
    ex = d["static"]["extra_scripts"]
    i = [k for k, it in enumerate(ex) if it["script"].endswith("r2_rim_curve.gd")][0]
    ex[i] = {"script": ex[i]["script"], "cfg": {"targets": ["r1_rim_edge_tree.gdshader"], "dip": 0.1}}
    ex.insert(i + 1, {"script": ex[i]["script"], "cfg": {"targets": ["r1_rim_edge.gdshader"], "dip": 0.35}})

def main(src, out, name):
    d = json.load(open(os.path.join(V, src + ".json"), encoding="utf-8"))
    for n in name.split("+"):
        PATCHES[n](d)
    d["_patched"] = d.get("_patched", []) + [name]
    json.dump(d, open(os.path.join(V, out + ".json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("wrote", out)

if __name__ == "__main__":
    main(*sys.argv[1:4])
