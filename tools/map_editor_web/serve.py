#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""旅人场景地图摆放器 · 本地服务端

双击 tools/map_editor_web/打开地图编辑器.command 即可，不用命令行。
默认打开巴格达；右上角可切换场景。

它只做三件事：
  1. 把编辑器页面和项目里的资产喂给浏览器；
  2. 读场景 JSON 与 scenes.py 里的描述表，一起发给页面；
  3. 保存时**只改描述表声明的那几个键**，其余一字不动。

第 3 条是这份文件存在的唯一理由，也是唯一不能出错的地方：
场景 JSON 是手写的（巴格达 17 个顶层键、盘橐 17 个，含大量记着 Carlos 原话的
authorization 与散文说明），而且 **data/traveler 下的文件一个都没有被 git 跟踪**
（git ls-files data/traveler 返回 0 行，也没有被 ignore，就是从来没 add 过）。
一次全量序列化就能静默删掉整块（盘橐实测：weather 块 79 个数值叶子），
而且没有任何 git 历史可以找回。
所以这里**永远是"读出来、原地改叶子、写回去"**，绝不重建这个字典。

实测过的安全性（盘橐，改一棵树 + 一个坡块 + 城堡朝向，并故意塞不存在的 id 与越界索引）：
  顶层键 17→17   叶子 1303→1303   丢失 0   新增 0
  改动叶子恰好 12（全是要求改的）   不存在的 id / 越界索引：跳过并记账
"""

import base64
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
sys.path.insert(0, HERE)
from scenes import SCENES, DEFAULT_VIEW          # noqa: E402

BACKUP_DIR = os.path.expanduser("~/SilkRoad-data-backup")
ASSET_ROOTS = ("assets/traveler", "assets/game", "scenes/traveler",
               "docs/reports/traveler-panti-001/references",
               "docs/reports/traveler-baghdad-001")

MIME = {
    ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8", ".json": "application/json; charset=utf-8",
    ".glb": "model/gltf-binary", ".gltf": "model/gltf+json",
    ".fbx": "application/octet-stream", ".png": "image/png",
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".svg": "image/svg+xml",
}


def _num(v, fallback=0.0):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return float(fallback)
    if f != f or f in (float("inf"), float("-inf")):
        return float(fallback)
    return f


def _vecn(v, fallback, n):
    if not isinstance(v, (list, tuple)) or len(v) < n:
        return list(fallback)
    return [_num(v[i]) for i in range(n)]


def _dig(doc, path):
    """按路径取容器；取不到返回 None。不创建任何键。"""
    cur = doc
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


# ============================================================ 合并保存

def _new_id(arr, id_key, prefix):
    """给新条目取一个不与现有冲突的 id。"""
    used = set()
    for e in arr:
        if isinstance(e, dict) and id_key in e:
            used.add(str(e[id_key]))
    i = 1
    while "%s_%02d" % (prefix, i) in used:
        i += 1
    return "%s_%02d" % (prefix, i)


def apply_deletes(doc, spec, deletes):
    """真删数组条目。**按身份匹配、从高下标往低删**，避免下标漂移。
    single 类不允许删（拱门/生命树/营火/L 叔是场景骨架）。"""
    removed = []
    notes = []
    by_key = {g["key"]: g for g in spec["groups"]}
    for gkey, items in (deletes or {}).items():
        g = by_key.get(gkey)
        if g is None:
            continue
        if g.get("kind") == "single":
            notes.append("拒绝删除 %s：它是场景骨架里的单体，不是数组条目" % gkey)
            continue
        arr = _dig(doc, g["path"])
        if not isinstance(arr, list):
            notes.append("跳过删除 %s：路径不是数组" % gkey)
            continue
        id_key = g.get("id_key")
        targets = []
        for it in items:
            n = None
            if id_key and it.get("id") is not None:
                for k, e in enumerate(arr):
                    if isinstance(e, dict) and str(e.get(id_key)) == str(it["id"]):
                        n = k
                        break
            if n is None:
                try:
                    cand = int(it.get("index", -1))
                except (TypeError, ValueError):
                    cand = -1
                if 0 <= cand < len(arr):
                    n = cand
            if n is None:
                notes.append("跳过删除 %s/%s：找不到这个条目" % (gkey, it.get("id", it.get("index"))))
                continue
            # 无 id 的类别（草丛、沙丘块）只能按下标匹配，而 Codex 随时在写同一个文件。
            # 所以要求页面回传该条目的关键值快照，不一致就拒绝删——宁可不删，不能删错。
            exp = it.get("expect")
            if exp is not None:
                cur = arr[n]
                same = True
                if isinstance(exp, dict) and isinstance(cur, dict):
                    for k, v in exp.items():
                        cv = cur.get(k)
                        if isinstance(v, list) and isinstance(cv, list) and len(v) == len(cv):
                            if any(abs(_num(v[i]) - _num(cv[i])) > 1e-6 for i in range(len(v))):
                                same = False
                        elif isinstance(v, (int, float)) and isinstance(cv, (int, float)):
                            if abs(_num(v) - _num(cv)) > 1e-6:
                                same = False
                        elif v != cv:
                            same = False
                else:
                    same = False
                if not same:
                    notes.append("拒绝删除 %s #%d：该条目已被别处改动（可能是 Codex 刚写过），"
                                 "请刷新页面重新读一次再删" % (gkey, n))
                    continue
            targets.append(n)
        for n in sorted(set(targets), reverse=True):
            gone = arr.pop(n)
            removed.append({"group": gkey, "index": n,
                            "id": gone.get(g.get("id_key") or "id") if isinstance(gone, dict) else None})
    return removed, notes


def apply_adds(doc, spec, adds):
    """把导入的模型追加到目标数组，键名照描述表写，让游戏侧不改代码就能读。"""
    added = []
    notes = []
    by_key = {g["key"]: g for g in spec["groups"]}
    for gkey, items in (adds or {}).items():
        g = by_key.get(gkey)
        if g is None or g.get("kind") != "list":
            notes.append("跳过新增 %s：只能往数组类追加" % gkey)
            continue
        if not g.get("asset_key"):
            notes.append("跳过新增 %s：这一类的条目不带自己的 asset 路径（整类共用一个资产），"
                         "请选石头/棕榈/地面物件/远山之一" % gkey)
            continue
        arr = _dig(doc, g["path"])
        if not isinstance(arr, list):
            notes.append("跳过新增 %s：路径不是数组" % gkey)
            continue
        template = None
        for e in arr:
            if isinstance(e, dict):
                template = e
                break
        for it in items:
            asset = str(it.get("asset") or "")
            if not asset:
                notes.append("跳过一个新增：没有 asset 路径")
                continue
            entry = {}
            id_key = g.get("id_key") or "id"
            entry[id_key] = _new_id(arr, id_key, "editor")
            entry[g["asset_key"]] = asset
            entry[g["pos_key"]] = _vecn(it.get("pos"), [0, 0, 0], 3)
            if g.get("size_key"):
                entry[g["size_key"]] = max(1e-4, _num(it.get("size"), 0.3))
            if g.get("yaw_key"):
                entry[g["yaw_key"]] = _num(it.get("yaw"), 0.0)
            # 沿用同类现有条目里那些"结构性"键的默认值，免得游戏侧读不到必需字段
            if isinstance(template, dict):
                for k, v in template.items():
                    if k in entry:
                        continue
                    if isinstance(v, bool) or isinstance(v, (int, float)):
                        entry.setdefault(k, v)
            entry["added_by"] = "map_editor"
            arr.append(entry)
            added.append({"group": gkey, "id": entry[id_key], "asset": asset})
    return added, notes


HIDDEN_KEY = "editor_hidden"


def apply_hides(doc, spec, hides):
    """**隐藏 = 把条目从数组移进 editor_hidden 块，不是删除。**

    为什么这么做：引擎不认 hidden / enabled 这类键，加了也不生效；
    而它遍历的是 group 的数组，所以把条目移出数组，游戏里自然就不出现，
    **且引擎代码零改动**。原条目连同它原来的下标一起存着，一键可放回。
    editor_hidden 是编辑器自己的顶层键，引擎忽略未知键。
    """
    moved = []
    notes = []
    by_key = {g["key"]: g for g in spec["groups"]}
    if not hides:
        return moved, notes            # 没有要隐藏的就不要凭空建键（否则留下空壳，Codex 读到会困惑）
    store = doc.setdefault(HIDDEN_KEY, {})
    if not isinstance(store, dict):
        notes.append("editor_hidden 不是对象，跳过所有隐藏操作")
        return moved, notes
    for gkey, items in (hides or {}).items():
        g = by_key.get(gkey)
        if g is None:
            continue
        if g.get("kind") != "list":
            notes.append("拒绝隐藏 %s：它不是数组条目（单体/起伏块请用位置挪出画外）" % gkey)
            continue
        arr = _dig(doc, g["path"])
        if not isinstance(arr, list):
            notes.append("跳过隐藏 %s：路径不是数组" % gkey)
            continue
        id_key = g.get("id_key")
        picked = []
        for it in items:
            n = None
            if id_key and it.get("id") is not None:
                for k, e in enumerate(arr):
                    if isinstance(e, dict) and str(e.get(id_key)) == str(it["id"]):
                        n = k
                        break
            if n is None:
                try:
                    cand = int(it.get("index", -1))
                except (TypeError, ValueError):
                    cand = -1
                if 0 <= cand < len(arr):
                    n = cand
            if n is None:
                notes.append("跳过隐藏 %s/%s：找不到这个条目" % (gkey, it.get("id", it.get("index"))))
                continue
            picked.append(n)
        bucket = store.setdefault(gkey, [])
        if not isinstance(bucket, list):
            notes.append("editor_hidden/%s 不是数组，跳过" % gkey)
            continue
        for n in sorted(set(picked), reverse=True):
            entry = arr.pop(n)
            bucket.append({"index": n, "entry": entry})
            moved.append({"group": gkey, "index": n,
                          "id": entry.get(id_key or "id") if isinstance(entry, dict) else None})
    return moved, notes


def apply_unhides(doc, spec, unhides):
    """把 editor_hidden 里的条目按原下标放回数组。"""
    back = []
    notes = []
    by_key = {g["key"]: g for g in spec["groups"]}
    store = doc.get(HIDDEN_KEY)
    if not isinstance(store, dict):
        return back, notes
    for gkey, items in (unhides or {}).items():
        g = by_key.get(gkey)
        bucket = store.get(gkey)
        if g is None or not isinstance(bucket, list):
            continue
        arr = _dig(doc, g["path"])
        if not isinstance(arr, list):
            notes.append("跳过恢复 %s：路径不是数组" % gkey)
            continue
        id_key = g.get("id_key") or "id"
        for it in items:
            want = str(it.get("id", ""))
            pos = None
            for k, rec in enumerate(bucket):
                e = rec.get("entry") if isinstance(rec, dict) else None
                if isinstance(e, dict) and str(e.get(id_key, "")) == want:
                    pos = k
                    break
            if pos is None:
                try:
                    hidx = int(it.get("hidden_index", -1))
                except (TypeError, ValueError):
                    hidx = -1
                if 0 <= hidx < len(bucket):
                    pos = hidx
            if pos is None:
                notes.append("跳过恢复 %s/%s：隐藏区里找不到" % (gkey, want or it.get("hidden_index")))
                continue
            rec = bucket.pop(pos)
            entry = rec.get("entry") if isinstance(rec, dict) else rec
            at = rec.get("index") if isinstance(rec, dict) else None
            try:
                at = int(at)
            except (TypeError, ValueError):
                at = len(arr)
            at = max(0, min(at, len(arr)))
            arr.insert(at, entry)
            back.append({"group": gkey, "index": at,
                         "id": entry.get(id_key) if isinstance(entry, dict) else None})
        if not bucket:
            store.pop(gkey, None)
    if not store:
        doc.pop(HIDDEN_KEY, None)
    return back, notes


def prune_hidden(doc):
    """收尾：隐藏区空了就把这个键整个移除，不给 Codex 留空壳。"""
    st = doc.get(HIDDEN_KEY)
    if isinstance(st, dict):
        for k in [k for k, v in st.items() if not v]:
            st.pop(k, None)
        if not st:
            doc.pop(HIDDEN_KEY, None)


def merge_edits(doc, spec, edits):
    """把页面传回来的编辑**原地**写进 doc。返回 (改动叶子数, 说明列表)。

    规则：
      - 只按 id / 下标匹配**已有**条目，匹配不到就跳过并记一条，绝不新建。
      - 只覆盖描述表声明的键（pos/yaw/size/extra），locked 里的键一律不写。
      - 不删除任何键、不改变任何顶层结构。
    """
    changed = 0
    notes = []

    def set_leaf(container, key, value):
        nonlocal changed
        if not isinstance(container, dict) or key not in container:
            notes.append("跳过（原文件没有这个键）: %s" % key)
            return
        if container[key] != value:
            container[key] = value
            changed += 1

    by_key = {g["key"]: g for g in spec["groups"]}

    for gkey, items in (edits or {}).items():
        g = by_key.get(gkey)
        if g is None or not isinstance(items, list):
            continue
        target_container = _dig(doc, g["path"])
        if target_container is None:
            notes.append("跳过 %s：原文件里没有 %s" % (gkey, "/".join(map(str, g["path"]))))
            continue

        kind = g.get("kind", "list")
        locked = set(g.get("locked", []))

        # ---- 椭圆起伏块：center[x,z] / radius[rx,rz] / height_u / angle_deg
        if kind == "ridges":
            if not isinstance(target_container, list):
                notes.append("跳过 %s：不是数组" % gkey)
                continue
            for it in items:
                try:
                    i = int(it.get("index", -1))
                except (TypeError, ValueError):
                    i = -1
                if i < 0 or i >= len(target_container) or not isinstance(target_container[i], dict):
                    notes.append("跳过 %s #%s：下标越界" % (gkey, it.get("index")))
                    continue
                r = target_container[i]
                if "center" in it:
                    set_leaf(r, "center", _vecn(it["center"], r.get("center", [0, 0]), 2))
                if "radius" in it:
                    rad = _vecn(it["radius"], r.get("radius", [1, 1]), 2)
                    set_leaf(r, "radius", [max(0.05, rad[0]), max(0.05, rad[1])])
                for f in ("height_u", "angle_deg"):
                    if f in it:
                        set_leaf(r, f, _num(it[f], r.get(f, 0.0)))
            continue

        # ---- 单体：路径本身就是对象
        if kind == "single":
            if not isinstance(target_container, dict) or not items:
                continue
            it = items[0]
            _apply_one(target_container, g, it, locked, set_leaf, notes)
            continue

        # ---- 数组
        if not isinstance(target_container, list):
            notes.append("跳过 %s：不是数组" % gkey)
            continue
        id_key = g.get("id_key")
        index_of = {}
        if id_key:
            for n, e in enumerate(target_container):
                if isinstance(e, dict) and id_key in e:
                    index_of[str(e[id_key])] = n
        for it in items:
            n = None
            if id_key and it.get("id") is not None and str(it["id"]) in index_of:
                n = index_of[str(it["id"])]
            else:
                try:
                    cand = int(it.get("index", -1))
                except (TypeError, ValueError):
                    cand = -1
                if 0 <= cand < len(target_container):
                    n = cand
            if n is None or not isinstance(target_container[n], dict):
                notes.append("跳过 %s/%s：原文件里没有这个条目" % (gkey, it.get("id", it.get("index"))))
                continue
            _apply_one(target_container[n], g, it, locked, set_leaf, notes)

    return changed, notes


def _apply_one(target, g, it, locked, set_leaf, notes):
    pos_key = g.get("pos_key")
    if pos_key and pos_key not in locked and "pos" in it:
        cur = target.get(pos_key, [0, 0, 0])
        set_leaf(target, pos_key, _vecn(it["pos"], cur, 3))
    yaw_key = g.get("yaw_key")
    if yaw_key and yaw_key not in locked and "yaw" in it:
        set_leaf(target, yaw_key, _num(it["yaw"], target.get(yaw_key, 0.0)))
    size_key = g.get("size_key")
    if size_key and size_key not in locked and "size" in it:
        set_leaf(target, size_key, max(1e-4, _num(it["size"], target.get(size_key, 1.0))))
    for extra in g.get("extra_keys", []):
        if extra in locked:
            continue
        if extra in it:
            set_leaf(target, extra, _num(it[extra], target.get(extra, 0.0)))


def do_save(payload):
    view = str(payload.get("view") or DEFAULT_VIEW)
    spec = SCENES.get(view)
    if spec is None:
        raise RuntimeError("未知场景: %s" % view)
    scene_path = os.path.join(ROOT, spec["file"])

    # 基底：写副本时以**副本**为基底（若存在），这样上一次的删除/新增不会被线上值冲掉；
    # 写线上时当然以线上为基底。
    overwrite_flag = bool(payload.get("overwrite"))
    base_path = scene_path
    if not overwrite_flag:
        cand = os.path.join(ROOT, spec["safe_copy"])
        if os.path.exists(cand) and payload.get("base") != "live":
            base_path = cand
    with open(base_path, "r", encoding="utf-8") as f:
        raw = f.read()
    doc = json.loads(raw)                      # dict 保序，写回时键顺序不变
    top_before = len(doc)
    top_keys_before = list(doc.keys())
    leaves_before = raw.count(":")

    changed, notes = merge_edits(doc, spec, payload.get("edits") or {})
    # 顺序要紧：先改值（下标还没动），再新增，最后删除（从高下标往低）
    # 顺序要紧：先改值（下标还没动），再恢复隐藏，再新增，再隐藏，最后删除
    unhidden, n1 = apply_unhides(doc, spec, payload.get("unhides") or {})
    added, n2 = apply_adds(doc, spec, payload.get("adds") or {})
    hidden, n4 = apply_hides(doc, spec, payload.get("hides") or {})
    removed, n3 = apply_deletes(doc, spec, payload.get("deletes") or {})
    for nn in (n1, n2, n4, n3):
        notes.extend(nn)
    prune_hidden(doc)

    overwrite = overwrite_flag
    target = scene_path if overwrite else os.path.join(ROOT, spec["safe_copy"])
    if overwrite:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(scene_path, os.path.join(
            BACKUP_DIR, "%s.%s.json" % (os.path.basename(scene_path).rsplit(".", 1)[0], stamp)))

    out = json.dumps(doc, ensure_ascii=False, indent=2)
    # 兜底自检：**原文件的顶层键一个都不能少**。
    # 编辑器自己的键（editor_hidden / custom_props）允许新增，所以按"原有键是否都还在"来判，
    # 不是按数量相等——数量相等那版把隐藏功能整个拦掉了（2026-09-22 实测）。
    # 编辑器自己的键（editor_hidden / custom_props）**增删都自由**；
    # 场景本身的键一个都不能丢，也不能凭空多出来。
    # 这里踩过两次：先是要求数量相等（把隐藏功能整个拦掉），
    # 再是只豁免了"新增"而没豁免"移除"（把恢复功能拦掉）。
    EDITOR_OWNED = {HIDDEN_KEY, "custom_props"}
    after = json.loads(out)
    lost = [k for k in top_keys_before if k not in after and k not in EDITOR_OWNED]
    extra = [k for k in after if k not in top_keys_before and k not in EDITOR_OWNED]
    if lost:
        raise RuntimeError("自检失败：顶层键丢了 %s，已放弃写入" % lost)
    if extra:
        raise RuntimeError("自检失败：凭空多了顶层键 %s，已放弃写入" % extra)
    # **写副本之前先自动留一份带时间戳的备份。**
    # 2026-09-22 这一天，编辑器两次把用户已保存的副本用线上内容覆盖掉
    # （一次是空编辑的渲染请求，一次是以线上为基底的保存）。根因都修了，
    # 但根因修了不等于不会再有新的写入路径，所以这里做无条件兜底：
    # 任何一次内容发生变化的写入，都先把旧版本存到 ~/SilkRoad-data-backup/editor/。
    if os.path.exists(target):
        try:
            with open(target, "r", encoding="utf-8") as f:
                old_text = f.read()
            if old_text.strip() != out.strip():
                bdir = os.path.join(BACKUP_DIR, "editor")
                os.makedirs(bdir, exist_ok=True)
                stamp = time.strftime("%Y%m%d-%H%M%S")
                base_name = os.path.basename(target).rsplit(".", 1)[0]
                with open(os.path.join(bdir, "%s.%s.json" % (base_name, stamp)),
                          "w", encoding="utf-8") as f:
                    f.write(old_text)
        except OSError:
            pass
    tmp = target + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out + "\n")
    os.replace(tmp, target)

    return {"ok": True, "view": view, "changed": changed,
            "base": os.path.relpath(base_path, ROOT),
            "added": added, "removed": removed,
            "hidden": hidden, "unhidden": unhidden,
            "wrote": os.path.relpath(target, ROOT), "overwrote_live_file": overwrite,
            "top_level_keys": top_before, "leaves_before": leaves_before,
            "leaves_after": out.count(":"), "notes": notes}


# ============================================================ 实机渲染

GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")

# 导入后处理脚本：把带顶点色表面的材质 vertex_color_use_as_albedo 打开。
# Godot 4.7.1 的 glTF 导入器对第一种材质不开这个开关（baghdad.glb 实测 surf0 关、surf1/2 开），
# 纯顶点色模型的主体会渲成白模。脚本只在导入时跑，结果进 .godot/imported，不碰场景脚本。
POST_IMPORT_SCRIPT = "res://tools/map_editor_web/post_import_vertex_color.gd"


def _run_godot_import():
    return subprocess.run([GODOT, "--headless", "--path", ROOT, "--import"],
                         cwd=ROOT, capture_output=True, text=True, timeout=240)


def _attach_post_import(import_abs):
    """在 .import 里挂上顶点色后处理脚本；改了文件返回 True，已挂/非场景返回 False。"""
    try:
        with open(import_abs, encoding="utf-8") as f:
            txt = f.read()
    except OSError:
        return False
    if 'importer="scene"' not in txt or POST_IMPORT_SCRIPT in txt:
        return False
    new = re.sub(r'^import_script/path=""', 'import_script/path="%s"' % POST_IMPORT_SCRIPT,
                 txt, count=1, flags=re.M)
    if new == txt:
        return False
    with open(import_abs, "w", encoding="utf-8") as f:
        f.write(new)
    return True
PREVIEW_DIR = os.path.join(ROOT, "tools", "traveler", "_preview")
RENDER_LOCK = threading.Lock()
JOBS = {}
JOB_SEQ = [0]
RENDER_TIMEOUT_S = 300


def build_preview_clone(spec):
    """从 Codex **当前**的 viewer 脚本克隆一份，只把数据路径换成副本。
    他的文件零写入；每次渲染都重新克隆，所以他改了 viewer 也不会漂移。"""
    src = os.path.join(ROOT, spec["viewer_script"])
    with open(src, "r", encoding="utf-8") as f:
        code = f.read()
    needle = spec["data_res_path"]
    if needle not in code:
        raise RuntimeError("在 %s 里找不到数据路径 %s —— Codex 可能改了读取方式，"
                           "实机渲染需要重新适配" % (spec["viewer_script"], needle))
    n = code.count(needle)
    code = code.replace(needle, spec["safe_res_path"])
    banner = ("# 自动生成，不要手改。由 tools/map_editor_web/serve.py 在每次实机渲染前\n"
              "# 从 %s 克隆，只把数据路径替换为编辑器副本。\n"
              "# 目的：让编辑器能渲出你的改动，而**不写入** Codex 正在用的场景文件。\n"
              % spec["viewer_script"])
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    stem = "preview_" + spec["view_key"]
    gd = os.path.join(PREVIEW_DIR, stem + ".gd")
    with open(gd, "w", encoding="utf-8") as f:
        f.write(banner + code)
    tscn = os.path.join(PREVIEW_DIR, stem + ".tscn")
    with open(tscn, "w", encoding="utf-8") as f:
        f.write('[gd_scene load_steps=2 format=3]\n\n'
                '[ext_resource type="Script" path="res://tools/traveler/_preview/%s.gd" id="1"]\n\n'
                '[node name="PreviewRoot" type="Node3D"]\n'
                'script = ExtResource("1")\n' % stem)
    return {"scene_res": "res://tools/traveler/_preview/%s.tscn" % stem,
            "script_rel": os.path.relpath(gd, ROOT), "replacements": n}


def _run_render(job_id, spec, flags):
    job = JOBS[job_id]
    out_png = os.path.join(PREVIEW_DIR, "render_%s.png" % job_id)
    out_json = out_png[:-4] + ".json"
    for p in (out_png, out_json):
        if os.path.exists(p):
            os.remove(p)
    try:
        with RENDER_LOCK:
            job["state"] = "cloning"
            clone = build_preview_clone(spec)
            job["clone"] = clone
            live = os.path.join(ROOT, spec["file"])
            sha_before = _sha(live)
            job["state"] = "rendering"
            cmd = [GODOT, "--path", ROOT, "--script",
                   "res://tools/traveler/capture_traveler.gd", "--",
                   "--capture-scene=" + clone["scene_res"],
                   "--view=" + spec["view_key"],
                   "--capture=" + out_png] + list(flags)
            job["cmd"] = " ".join(cmd)
            t0 = time.time()
            pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                                timeout=RENDER_TIMEOUT_S)
            job["seconds"] = round(time.time() - t0, 1)
            log = (pr.stdout or "") + "\n" + (pr.stderr or "")
            bad = [ln for ln in log.splitlines()
                   if ("ERROR" in ln or "SCRIPT ERROR" in ln or "SHADER ERROR" in ln
                       or "Parse Error" in ln)]
            job["log_errors"] = bad[:12]
            job["log_tail"] = log.strip().splitlines()[-6:]
            # Codex 是否在渲染期间写过线上文件
            sha_after = _sha(live)
            job["live_file_untouched"] = (sha_before == sha_after)
            if not job["live_file_untouched"]:
                job["log_errors"].append(
                    "注意：渲染期间 %s 被改动过（可能是 Codex）。本次渲染用的是你的副本，"
                    "结果仍然有效；但线上文件已经前进了。" % spec["file"])
            if not os.path.exists(out_png):
                job["state"] = "failed"
                job["error"] = "没有产出图片；看 log_errors / log_tail"
                return
            rep = {}
            if os.path.exists(out_json):
                try:
                    with open(out_json, "r", encoding="utf-8") as f:
                        rep = json.load(f)
                except Exception:
                    rep = {}
            job["report"] = _digest(rep)
            job["png"] = out_png
            job["state"] = "done"
    except subprocess.TimeoutExpired:
        job["state"] = "failed"
        job["error"] = "渲染超时（%d 秒）" % RENDER_TIMEOUT_S
    except Exception as e:
        job["state"] = "failed"
        job["error"] = "%s: %s" % (type(e).__name__, e)


def _sha(path):
    import hashlib
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def _digest(rep):
    """从 capture 报告里挑出构图与性能的关键数字。"""
    out = {}
    comp = rep.get("composition") or {}
    for k in ("arch", "tree", "character", "fortress"):
        if isinstance(comp.get(k), dict):
            e = comp[k]
            out[k] = {"height_fraction": e.get("height_fraction"),
                      "bounds_px": e.get("bounds_px"),
                      "depth_u": e.get("camera_depth_range_u")}
    for k in ("horizon_y_uv", "sun_center_uv", "camera_elevation_deg"):
        if k in comp:
            out[k] = comp[k]
    out["draw_calls"] = rep.get("draw_calls")
    out["viewport_draw_calls"] = rep.get("viewport_draw_calls")
    fm = rep.get("frame_ms") or {}
    out["p50"] = fm.get("p50") if isinstance(fm, dict) else rep.get("p50")
    out["p95"] = fm.get("p95") if isinstance(fm, dict) else rep.get("p95")
    out["image_size"] = rep.get("image_size")
    return out


def start_render(payload):
    view = str(payload.get("view") or DEFAULT_VIEW)
    spec = SCENES.get(view)
    if spec is None:
        raise RuntimeError("未知场景 %s" % view)
    if not spec.get("viewer_script"):
        raise RuntimeError("场景 %s 没有配置 viewer_script，不能实机渲染" % view)
    spec = dict(spec)
    spec["view_key"] = view
    # 先把当前编辑写进副本（渲染读的就是副本）。
    # **只有在真的带了编辑内容时才写**。曾经这里无条件调用 do_save，
    # 而 do_save 是「读线上文件 → 套用改动 → 写副本」，所以一次空编辑的渲染请求
    # 会把线上文件原样写进副本，**把用户已保存的副本整份覆盖掉**（2026-09-22 实际发生过）。
    # 五种改动都算：edits / adds / deletes / hides / unhides。
    # 2026-09-22 这里曾漏掉 hides、unhides：页面明明把「隐藏」随渲染请求发来了，
    # 服务端却只认前三种，隐藏没写进副本，渲出来旧城还在 —— Carlos 当场发现。
    PAYLOAD_KEYS = ("edits", "adds", "deletes", "hides", "unhides")
    has_payload = any(bool(payload.get(k)) for k in PAYLOAD_KEYS)
    safe_abs = os.path.join(ROOT, spec["safe_copy"])
    if has_payload:
        saved = do_save({"view": view, "overwrite": False,
                         **{k: (payload.get(k) or {}) for k in PAYLOAD_KEYS}})
    elif os.path.exists(safe_abs):
        saved = {"ok": True, "wrote": spec["safe_copy"], "changed": 0,
                 "note": "没有带编辑内容，直接渲现有副本，副本未被改写"}
    else:
        shutil.copy2(os.path.join(ROOT, spec["file"]), safe_abs)
        saved = {"ok": True, "wrote": spec["safe_copy"], "changed": 0,
                 "note": "副本不存在，已从线上文件初始化一份"}
    flags = payload.get("flags") or []
    if not isinstance(flags, list):
        flags = []
    flags = [f for f in flags if isinstance(f, str) and f.startswith("--")][:4]
    JOB_SEQ[0] += 1
    job_id = "%d_%s" % (JOB_SEQ[0], time.strftime("%H%M%S"))
    JOBS[job_id] = {"id": job_id, "view": view, "state": "queued",
                    "saved": saved, "flags": flags}
    threading.Thread(target=_run_render, args=(job_id, spec, flags), daemon=True).start()
    return {"ok": True, "job": job_id, "saved": saved,
            "busy": RENDER_LOCK.locked()}


# ============================================================ HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "TravelerMapEditor/2.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            self._send(404, {"error": "找不到 %s" % path})
            return
        self.send_response(200)
        self.send_header("Content-Type", MIME.get(os.path.splitext(path)[1].lower(),
                                                  "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        route = u.path
        q = urllib.parse.parse_qs(u.query)

        if route in ("/", "/index.html"):
            self._send_file(os.path.join(HERE, "index.html"))
            return
        if route == "/app.js":
            self._send_file(os.path.join(HERE, "app.js"))
            return
        if route == "/render/status":
            jid = (q.get("job") or [""])[0]
            j = JOBS.get(jid)
            if j is None:
                self._send(404, {"error": "没有这个任务"})
                return
            self._send(200, {k: v for k, v in j.items() if k != "png"})
            return
        if route == "/render/image":
            jid = (q.get("job") or [""])[0]
            j = JOBS.get(jid)
            if j is None or not j.get("png") or not os.path.exists(j["png"]):
                self._send(404, {"error": "还没有图"})
                return
            self._send_file(j["png"])
            return
        if route == "/scenes":
            self._send(200, {"default": DEFAULT_VIEW,
                             "scenes": [{"view": k, "title": v["title"], "file": v["file"],
                                         "capture_flags": v.get("capture_flags", []),
                                         "can_render": bool(v.get("viewer_script"))}
                                        for k, v in SCENES.items()]})
            return
        if route == "/scene":
            view = (q.get("view") or [DEFAULT_VIEW])[0]
            spec = SCENES.get(view)
            if spec is None:
                self._send(404, {"error": "未知场景 %s" % view})
                return
            live = os.path.join(ROOT, spec["file"])
            copy = os.path.join(ROOT, spec["safe_copy"])
            want = (q.get("source") or [""])[0]
            # **默认优先读副本。** 页面若总是读线上文件，刷新之后就看不到自己存过的改动，
            # 而下一次保存/渲染又会把线上值写回副本，把改动吃掉（2026-09-22 踩过两次）。
            if want == "live":
                p, src = live, "live"
            elif want == "copy":
                p, src = copy, "copy"
            elif os.path.exists(copy):
                p, src = copy, "copy"
            else:
                p, src = live, "live"
            if not os.path.exists(p):
                self._send(404, {"error": "文件不存在: %s" % os.path.relpath(p, ROOT)})
                return
            with open(p, "r", encoding="utf-8") as f:
                doc = json.load(f)
            live_mtime = os.path.getmtime(live) if os.path.exists(live) else 0
            self._send(200, {"view": view, "title": spec["title"], "file": spec["file"],
                             "loaded_from": src,
                             "loaded_path": os.path.relpath(p, ROOT),
                             "copy_exists": os.path.exists(copy),
                             "live_newer_than_copy": bool(
                                 os.path.exists(copy) and live_mtime > os.path.getmtime(copy)),
                             "stage_note": spec.get("stage_note", ""),
                             "camera": spec.get("camera"),
                             "groups": spec["groups"], "doc": doc,
                             "hidden": doc.get(HIDDEN_KEY) or {},
                             "mtime": os.path.getmtime(p)})
            return
        if route.startswith("/file/"):
            rel = urllib.parse.unquote(route[len("/file/"):]).replace("res://", "")
            full = os.path.abspath(os.path.join(ROOT, rel))
            if not full.startswith(ROOT + os.sep):
                self._send(403, {"error": "越界路径"})
                return
            relnorm = os.path.relpath(full, ROOT)
            if not any(relnorm.startswith(a) for a in ASSET_ROOTS):
                self._send(403, {"error": "只允许读 %s" % ", ".join(ASSET_ROOTS)})
                return
            self._send_file(full)
            return
        self._send(404, {"error": "no route %s" % route})

    def _do_upload(self, payload):
        view = str(payload.get("view") or DEFAULT_VIEW)
        if view not in SCENES:
            raise RuntimeError("未知场景 %s" % view)
        raw_name = str(payload.get("name") or "")
        ext = os.path.splitext(raw_name)[1].lower()
        if ext not in (".glb", ".gltf", ".fbx"):
            raise RuntimeError("只接受 .glb / .gltf / .fbx，收到 %s" % (ext or "无扩展名"))
        # 文件名消毒：去掉路径分隔符与奇怪字符，保留扩展名
        stem = os.path.splitext(os.path.basename(raw_name))[0]
        stem = re.sub(r"[^0-9A-Za-z\u4e00-\u9fff._+()\- ]", "_", stem)[:80] or "imported"
        dest_dir = os.path.join(ROOT, "assets", "traveler", view, "props")
        os.makedirs(dest_dir, exist_ok=True)
        name = stem + ext
        n = 1
        while os.path.exists(os.path.join(dest_dir, name)):
            name = "%s_%d%s" % (stem, n, ext)
            n += 1
        data = base64.b64decode(payload.get("data_b64") or "")
        if not data:
            raise RuntimeError("空文件")
        with open(os.path.join(dest_dir, name), "wb") as f:
            f.write(data)
        rel = os.path.relpath(os.path.join(dest_dir, name), ROOT)
        res_path = "res://" + rel.replace(os.sep, "/")
        # **落盘之后必须跑一次 Godot 导入**，否则引擎 load() 拿不到资源，
        # 场景会**静默跳过**这个条目——日志里连错都不报。
        # 2026-09-22 实际发生：用户导入 baghdad.glb 摆进远山，渲染报告 layer_count 仍是 5。
        imported = False
        import_err = ""
        post_import = False
        try:
            pr = _run_godot_import()
            import_abs = os.path.join(ROOT, rel + ".import")
            imported = os.path.exists(import_abs)
            if not imported:
                tail = ((pr.stdout or "") + (pr.stderr or "")).strip().splitlines()[-4:]
                import_err = " / ".join(tail)
            elif _attach_post_import(import_abs):
                # 第二遍：Godot 第一遍生成 .import 时 import_script 是空的，
                # 挂上顶点色后处理脚本后必须再导一次，否则纯顶点色模型是白模。
                _run_godot_import()
                with open(import_abs, encoding="utf-8") as f:
                    post_import = POST_IMPORT_SCRIPT in f.read()
        except Exception as e:
            import_err = "%s: %s" % (type(e).__name__, e)
        return {"ok": True, "res_path": res_path,
                "bytes": len(data), "saved_to": rel,
                "godot_imported": imported, "import_error": import_err,
                "post_import_vertex_color": post_import,
                "note": ".fbx 若贴图是外链，浏览器拖进来时带不上 .fbm 目录，游戏里会是白模；"
                        "自带贴图的 .glb 最稳。"}

    def do_POST(self):
        route = urllib.parse.urlparse(self.path).path
        if route not in ("/save", "/upload", "/render"):
            self._send(404, {"error": "no route"})
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
        except Exception as e:
            self._send(400, {"error": "请求体解析失败: %s" % e})
            return
        try:
            if route == "/upload":
                self._send(200, self._do_upload(payload))
            elif route == "/render":
                self._send(200, start_render(payload))
            else:
                self._send(200, do_save(payload))
        except Exception as e:
            self._send(500, {"error": "%s: %s" % (type(e).__name__, e)})


def main():
    port = int(os.environ.get("PORT", "8791"))
    missing = [v["file"] for v in SCENES.values()
               if not os.path.exists(os.path.join(ROOT, v["file"]))]
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("旅人场景地图摆放器  →  http://127.0.0.1:%d" % port)
    for k, v in SCENES.items():
        mark = "缺" if v["file"] in missing else "OK"
        print("  [%s] %-9s %s" % (mark, k, v["file"]))
    print("  默认保存到副本（*.edited.json），不动线上文件")
    print("  按 Ctrl+C 结束")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已结束。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
