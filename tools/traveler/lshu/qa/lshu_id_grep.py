#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· ID grep: tile / composition / asset / place ids may appear ONLY in
data/traveler/lshu/pool.json. Code, shaders and look.json must contain none (card §0, §4).

Vocabulary (the full universe, not just the current pool): the 12 showcase ids (Dnn), all 960 composition ids
(Jnnn), the 140 asset ids of the web manifest and the 40 place ids, read from tools/traveler/lshu/web_src.
Every line is split into tokens [A-Za-z0-9_]+ and a token equal to an id is a hit (so file names such as
baghdad_potato_blossom.gd do not hit, a bare `blossom` identifier does).

  python3 tools/traveler/lshu/qa/lshu_id_grep.py [--json=OUT] [extra paths ...]
Default targets: scripts/traveler/lshu (recursive), shaders/traveler/lshu, data/traveler/lshu/look.json.
Exit 1 when any hit is found.
"""
import json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
WEB = os.path.join(ROOT, "tools", "traveler", "lshu", "web_src")
TARGETS = ["scripts/traveler/lshu", "shaders/traveler/lshu", "data/traveler/lshu/look.json"]
EXTS = (".gd", ".gdshader", ".gdshaderinc", ".json", ".tscn", ".tres", ".cfg")
TOKEN = re.compile(r"[A-Za-z0-9_]+")


def vocabulary():
    vocab = {}
    for s in json.load(open(os.path.join(WEB, "config", "showcases12.json"), encoding="utf-8")):
        vocab[s["id"]] = "showcase"
    j = json.load(open(os.path.join(WEB, "config", "journey960.json"), encoding="utf-8"))
    for r in j["recipes"]:
        vocab[r["composition_id"]] = "composition"
    for p in j["places"]:
        vocab[p["id"]] = "place"
    for a in json.load(open(os.path.join(WEB, "assets", "manifest.json"), encoding="utf-8"))["assets"]:
        vocab[a["id"]] = "asset"
    return vocab


def files(targets):
    for t in targets:
        p = os.path.join(ROOT, t)
        if os.path.isfile(p):
            yield p
        elif os.path.isdir(p):
            for dp, _dn, fns in os.walk(p):
                for f in sorted(fns):
                    if f.endswith(EXTS):
                        yield os.path.join(dp, f)


def main(argv):
    out = None
    extra = []
    for a in argv:
        if a.startswith("--json="):
            out = a.split("=", 1)[1]
        else:
            extra.append(a)
    vocab = vocabulary()
    hits = []
    scanned = 0
    for f in files(TARGETS + extra):
        scanned += 1
        for n, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
            for tok in TOKEN.findall(line):
                if tok in vocab:
                    hits.append({"file": os.path.relpath(f, ROOT), "line": n, "id": tok, "kind": vocab[tok], "text": line.strip()[:160]})
    rep = {"schema": "lshu.id-grep.v1", "targets": TARGETS + extra, "files_scanned": scanned, "vocabulary": len(vocab), "hits": len(hits), "detail": hits}
    if out:
        json.dump(rep, open(out, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    for h in hits:
        print("HIT %s:%d %s (%s)  %s" % (h["file"], h["line"], h["id"], h["kind"], h["text"]))
    print("ID_GREP files=%d vocabulary=%d hits=%d" % (scanned, len(vocab), len(hits)))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
