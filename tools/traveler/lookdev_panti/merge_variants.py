#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把几条设计线的 variant 深度合并成一个（先解开各自的 base 继承）。

用法：python3 tools/traveler/lookdev_panti/merge_variants.py <输出名> <variantA> <variantB> [...]
  static.extra_scripts 按顺序拼接；day_sky 与 morning/midnight 各节（sun/env/lights/shaders/materials）逐键合并，
  后面的 variant 覆盖前面同名键并在 stderr 报出冲突。
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
VDIR = os.path.join(HERE, "variants")


def resolve(name):
    d = json.load(open(os.path.join(VDIR, name + ".json"), encoding="utf-8"))
    if "base" in d:
        b = resolve(d["base"])
        for k, v in d.items():
            if k != "base":
                b[k] = v
        d = b
    return d


def deep(dst, src, path, who):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            deep(dst[k], v, path + [k], who)
        else:
            if k in dst and dst[k] != v:
                sys.stderr.write("冲突 %s: %s 覆盖为 %s 的值\n" % (".".join(path + [k]), json.dumps(dst[k])[:60], who))
            dst[k] = v


def main(out, names):
    merged = {"static": {"extra_scripts": []}, "morning": {}, "midnight": {}, "_merged_from": names}
    for n in names:
        d = resolve(n)
        st = d.get("static", {})
        merged["static"]["extra_scripts"] += st.get("extra_scripts", [])
        for k, v in st.items():
            if k != "extra_scripts":
                deep(merged["static"].setdefault(k, {}), v, ["static", k], n)
        for per in ("morning", "midnight"):
            deep(merged[per], d.get(per, {}), [per], n)
    json.dump(merged, open(os.path.join(VDIR, out + ".json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("wrote variants/%s.json from %s (%d extra scripts)" % (out, ", ".join(names), len(merged["static"]["extra_scripts"])))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
