#!/usr/bin/env python3
"""把静态角色 GLB 变成带骨架与循环动画的 GLB —— 纯 Python，不经过 Blender。

为什么不走 Blender：总监这台机器上没有 Blender（mdfind 搜不到、PATH 上没有、
Godot 的 import/blender/enabled=false），也没有 Blender MCP 工具。而这个角色在
冻结机位下只有约 128 px 高，包络权重在腋下/肩部的瑕疵在这个尺寸上看不见，
所以「程序化骨架 + 包络蒙皮」是成立的，且完全可复现、可脚本化。

用法：
    python3 tools/traveler/rig_character.py \
        --in assets/traveler/characters/chibi-raw.glb \
        --out assets/traveler/characters/chibi-rigged.glb \
        [--report path.json]

输入假定：单 mesh、单 primitive、单位节点变换、y 向上、模型高度归一化到 1。
脚本自己求身体中轴并重定心，不依赖模型已经居中。
"""

import argparse
import json
import math
import struct
import sys

import numpy as np

# ---------------------------------------------------------------- GLB 读写

COMP = {5120: ("i1", 1), 5121: ("u1", 1), 5122: ("i2", 2),
        5123: ("u2", 2), 5125: ("u4", 4), 5126: ("f4", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_glb(path):
    data = open(path, "rb").read()
    if data[:4] != b"glTF":
        raise SystemExit(f"{path} 不是 GLB")
    off, js, bin_chunk = 12, None, b""
    while off < len(data):
        ln, ty = struct.unpack_from("<II", data, off)
        off += 8
        chunk = data[off:off + ln]
        off += ln
        if ty == 0x4E4F534A:
            js = json.loads(chunk)
        elif ty == 0x004E4942:
            bin_chunk = chunk
    return js, bin_chunk


def read_accessor(js, bin_chunk, index):
    a = js["accessors"][index]
    bv = js["bufferViews"][a["bufferView"]]
    dt, size = COMP[a["componentType"]]
    n = NCOMP[a["type"]]
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride") or size * n
    if stride == size * n:
        arr = np.frombuffer(bin_chunk, dtype=np.dtype(dt), count=a["count"] * n, offset=base)
        return arr.reshape(a["count"], n) if n > 1 else arr.copy()
    out = np.empty((a["count"], n), dtype=dt)
    for k in range(a["count"]):
        out[k] = np.frombuffer(bin_chunk, dtype=np.dtype(dt), count=n, offset=base + k * stride)
    return out


class BinWriter:
    """累积 bufferView / accessor，最后吐出一个 BIN chunk。"""

    def __init__(self):
        self.blob = bytearray()
        self.views = []
        self.accessors = []

    def _pad(self, align=4):
        while len(self.blob) % align:
            self.blob.append(0)

    def add(self, array, comp_type, gltf_type, target=None, minmax=False, normalized=False):
        dt, size = COMP[comp_type]
        n = NCOMP[gltf_type]
        arr = np.ascontiguousarray(array, dtype=np.dtype(dt))
        self._pad()
        offset = len(self.blob)
        self.blob.extend(arr.tobytes())
        view = {"buffer": 0, "byteOffset": offset, "byteLength": arr.nbytes}
        if target is not None:
            view["target"] = target
        self.views.append(view)
        acc = {"bufferView": len(self.views) - 1, "componentType": comp_type,
               "count": int(arr.size // n), "type": gltf_type}
        if normalized:
            acc["normalized"] = True
        if minmax:
            flat = arr.reshape(-1, n).astype(np.float64)
            acc["min"] = [float(v) for v in flat.min(axis=0)]
            acc["max"] = [float(v) for v in flat.max(axis=0)]
        self.accessors.append(acc)
        return len(self.accessors) - 1


def write_glb(path, js, bin_chunk):
    js_bytes = json.dumps(js, separators=(",", ":")).encode("utf-8")
    js_bytes += b" " * ((4 - len(js_bytes) % 4) % 4)
    bin_bytes = bytes(bin_chunk)
    bin_bytes += b"\0" * ((4 - len(bin_bytes) % 4) % 4)
    total = 12 + 8 + len(js_bytes) + 8 + len(bin_bytes)
    with open(path, "wb") as f:
        f.write(b"glTF")
        f.write(struct.pack("<II", 2, total))
        f.write(struct.pack("<II", len(js_bytes), 0x4E4F534A))
        f.write(js_bytes)
        f.write(struct.pack("<II", len(bin_bytes), 0x004E4942))
        f.write(bin_bytes)
    return total


# ---------------------------------------------------------------- 骨架

# 名称, 父级, 位置(y 向上, 面朝 +z, 已重定心), 包络半径, 影响衰减指数
# 位置由 --in 模型的实测地标定出：头 y0.56-1.00、颈 0.52-0.56、髋 y0.28、
# 腿间距 x±0.07、臂 x±0.12、手 y≈0.28。
def build_skeleton(h=1.0):
    s = lambda v: v * h
    bones = [
        # 名称, 父级, 位置, 触及距离 reach(权重归零处), 衰减指数
        # reach 是绝对距离，不再是「半径 × 统一倍率」。上一版用 2.5×半径，
        # 头骨 0.26 半径 => 0.65 触及，而角色全高才 1.0，于是头骨吞掉了 69% 的顶点
        # （实测 head 主导 140,268 / 202,481，手臂类只剩 7.16%，胸骨 0.12%）。
        ("hips",        None,         (0.000, s(0.280), 0.000), s(0.175), 2.0),
        ("spine",       "hips",       (0.000, s(0.390), 0.000), s(0.185), 2.0),
        ("chest",       "spine",      (0.000, s(0.480), 0.000), s(0.200), 1.8),
        ("neck",        "chest",      (0.000, s(0.535), 0.000), s(0.080), 2.5),
        ("head",        "neck",       (0.000, s(0.575), 0.000), s(0.250), 2.6),
        # 披风：孤立顶点若逐个绑到「最近骨」，会被胸/上臂/头三根骨撕扯（实测帧间皱成一团）。
        # 给它一根自己的骨，整片随躯干刚性移动——128 px 下这就够了。
        ("cape",        "chest",      (0.000, s(0.470), -s(0.060)), s(0.300), 1.4),
        ("shoulder_L",  "chest",      (+s(0.060), s(0.500), 0.000), s(0.085), 2.5),
        ("upperarm_L",  "shoulder_L", (+s(0.112), s(0.470), 0.000), s(0.105), 2.0),
        ("forearm_L",   "upperarm_L", (+s(0.125), s(0.380), 0.000), s(0.095), 2.0),
        ("hand_L",      "forearm_L",  (+s(0.130), s(0.300), 0.000), s(0.150), 1.6),
        ("shoulder_R",  "chest",      (-s(0.060), s(0.500), 0.000), s(0.085), 2.5),
        ("upperarm_R",  "shoulder_R", (-s(0.112), s(0.470), 0.000), s(0.105), 2.0),
        ("forearm_R",   "upperarm_R", (-s(0.125), s(0.380), 0.000), s(0.095), 2.0),
        ("hand_R",      "forearm_R",  (-s(0.130), s(0.300), 0.000), s(0.150), 1.6),
        ("thigh_L",     "hips",       (+s(0.068), s(0.265), 0.000), s(0.120), 2.0),
        ("shin_L",      "thigh_L",    (+s(0.072), s(0.150), 0.000), s(0.105), 2.0),
        ("foot_L",      "shin_L",     (+s(0.075), s(0.030), s(0.010)), s(0.115), 1.8),
        ("thigh_R",     "hips",       (-s(0.068), s(0.265), 0.000), s(0.120), 2.0),
        ("shin_R",      "thigh_R",    (-s(0.072), s(0.150), 0.000), s(0.105), 2.0),
        ("foot_R",      "shin_R",     (-s(0.075), s(0.030), s(0.010)), s(0.115), 1.8),
    ]
    names = [b[0] for b in bones]
    index = {n: i for i, n in enumerate(names)}
    parents = [(-1 if b[1] is None else index[b[1]]) for b in bones]
    heads = np.array([b[2] for b in bones], dtype=np.float64)
    reach = np.array([b[3] for b in bones], dtype=np.float64)
    falloff = np.array([b[4] for b in bones], dtype=np.float64)
    # 每根骨的「段」：从自身指向第一个子级；叶子骨沿父级方向延伸。
    tails = heads.copy()
    for i in range(len(bones)):
        kids = [j for j in range(len(bones)) if parents[j] == i]
        if kids:
            tails[i] = heads[kids].mean(axis=0)
        else:
            p = parents[i]
            tails[i] = heads[i] + (heads[i] - heads[p]) * 0.8 if p >= 0 else heads[i] + np.array([0, s(0.1), 0])
    # 头骨的段要覆盖整个大脑袋
    tails[index["head"]] = np.array([0.0, s(0.95), 0.0])
    # 披风骨的段沿实测的披风走向（y0.40-0.48、z 中位 -0.18、最远 -0.52）往后下方伸
    tails[index["cape"]] = np.array([0.0, s(0.360), -s(0.400)])
    return names, index, parents, heads, tails, reach, falloff


def segment_distance(points, a, b):
    ab = b - a
    denom = float(ab @ ab)
    if denom < 1e-12:
        return np.linalg.norm(points - a, axis=1)
    t = np.clip(((points - a) @ ab) / denom, 0.0, 1.0)
    proj = a[None, :] + t[:, None] * ab[None, :]
    return np.linalg.norm(points - proj, axis=1)


def compute_weights(P, heads, tails, reach, falloff, max_influences=4):
    nv, nb = len(P), len(heads)
    raw = np.zeros((nv, nb), dtype=np.float64)
    for i in range(nb):
        d = segment_distance(P, heads[i], tails[i])
        # 平滑包络：段上为 1，到 reach 处归零，中间按幂次衰减。
        w = np.clip(1.0 - (d / reach[i]), 0.0, 1.0) ** falloff[i]
        raw[:, i] = w
    # 每个顶点取最强的 max_influences 根
    order = np.argsort(-raw, axis=1)[:, :max_influences]
    joints = order.astype(np.uint16)
    weights = np.take_along_axis(raw, order, axis=1)
    total = weights.sum(axis=1, keepdims=True)
    orphan = (total[:, 0] <= 1e-9)
    if orphan.any():
        # 落在所有包络外的顶点（披风边缘、挂件等）：绑到最近的骨上
        nearest = np.zeros(nv, dtype=np.int64)
        best = np.full(nv, np.inf)
        for i in range(nb):
            d = segment_distance(P, heads[i], tails[i])
            better = d < best
            best = np.where(better, d, best)
            nearest = np.where(better, i, nearest)
        joints[orphan, 0] = nearest[orphan].astype(np.uint16)
        joints[orphan, 1:] = 0
        weights[orphan, 0] = 1.0
        weights[orphan, 1:] = 0.0
        total = weights.sum(axis=1, keepdims=True)
    weights = weights / np.maximum(total, 1e-12)
    return joints, weights.astype(np.float32), int(orphan.sum())


# ---------------------------------------------------------------- 动画

def quat_axis(axis, angle):
    """轴角 -> glTF 四元数 (x,y,z,w)。"""
    a = np.asarray(axis, dtype=np.float64)
    a = a / max(np.linalg.norm(a), 1e-12)
    s = math.sin(angle * 0.5)
    return np.array([a[0] * s, a[1] * s, a[2] * s, math.cos(angle * 0.5)])


def quat_mul(q1, q2):
    x1, y1, z1, w1 = q1
    x2, y2, z2, w2 = q2
    return np.array([
        w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
        w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
        w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
        w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
    ])


def cycle(name, index, frames, period, curves, extra_translation=None):
    """curves: {骨名: 函数(phase 0..1) -> (轴, 角度)}。返回 (时间数组, {节点: 四元数序列}, {节点: 位移序列})。"""
    t = np.linspace(0.0, period, frames, endpoint=True)
    rot = {}
    for bone, fn in curves.items():
        j = index[bone]
        q = np.zeros((frames, 4))
        for k in range(frames):
            phase = (t[k] / period) % 1.0
            axis, angle = fn(phase)
            q[k] = quat_axis(axis, angle)
        rot[j] = q
    trans = {}
    if extra_translation:
        for bone, fn in extra_translation.items():
            j = index[bone]
            arr = np.zeros((frames, 3))
            for k in range(frames):
                arr[k] = fn((t[k] / period) % 1.0)
            trans[j] = arr
    return t, rot, trans


def walk_curves(swing_deg, arm_deg, h):
    two_pi = 2.0 * math.pi
    sw = math.radians(swing_deg)
    ar = math.radians(arm_deg)
    return {
        "thigh_L": lambda p: ((1, 0, 0), sw * math.sin(two_pi * p)),
        "thigh_R": lambda p: ((1, 0, 0), sw * math.sin(two_pi * p + math.pi)),
        "shin_L": lambda p: ((1, 0, 0), -abs(sw) * 0.9 * max(0.0, math.sin(two_pi * p - 0.6))),
        "shin_R": lambda p: ((1, 0, 0), -abs(sw) * 0.9 * max(0.0, math.sin(two_pi * p + math.pi - 0.6))),
        "upperarm_L": lambda p: ((1, 0, 0), ar * math.sin(two_pi * p + math.pi)),
        "upperarm_R": lambda p: ((1, 0, 0), ar * math.sin(two_pi * p)),
        "forearm_L": lambda p: ((1, 0, 0), -abs(ar) * 0.45 * (0.5 + 0.5 * math.sin(two_pi * p + math.pi))),
        "forearm_R": lambda p: ((1, 0, 0), -abs(ar) * 0.45 * (0.5 + 0.5 * math.sin(two_pi * p))),
        "spine": lambda p: ((0, 1, 0), math.radians(4.0) * math.sin(two_pi * p)),
        "chest": lambda p: ((0, 1, 0), math.radians(-6.0) * math.sin(two_pi * p)),
        "head": lambda p: ((0, 1, 0), math.radians(3.0) * math.sin(two_pi * p + 0.8)),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", required=True)
    ap.add_argument("--report", default="")
    ap.add_argument("--frames", type=int, default=24)
    args = ap.parse_args()

    js, bin_chunk = read_glb(args.src)
    if len(js.get("meshes", [])) != 1 or len(js["meshes"][0]["primitives"]) != 1:
        raise SystemExit("目前只支持单 mesh 单 primitive")
    prim = js["meshes"][0]["primitives"][0]

    pos = read_accessor(js, bin_chunk, prim["attributes"]["POSITION"]).astype(np.float64)
    nrm = read_accessor(js, bin_chunk, prim["attributes"]["NORMAL"]).astype(np.float32) \
        if "NORMAL" in prim["attributes"] else None
    uv = read_accessor(js, bin_chunk, prim["attributes"]["TEXCOORD_0"]).astype(np.float32) \
        if "TEXCOORD_0" in prim["attributes"] else None
    idx = read_accessor(js, bin_chunk, prim["indices"]).astype(np.uint32).reshape(-1)

    # 求身体中轴并重定心；脚底落到 y=0
    top = pos[pos[:, 1] > pos[:, 1].max() - 0.07]
    bot = pos[pos[:, 1] < pos[:, 1].min() + 0.04]
    cx = float(np.median(np.r_[top[:, 0], bot[:, 0]]))
    cz = float(np.median(np.r_[top[:, 2], bot[:, 2]]))
    P = pos - np.array([cx, pos[:, 1].min(), cz])
    height = float(P[:, 1].max())

    names, index, parents, heads, tails, reach, falloff = build_skeleton(height)
    joints, weights, orphans = compute_weights(P, heads, tails, reach, falloff)

    # ---- 组装新的 glTF ----
    out = {"asset": {"version": "2.0", "generator": "silkroad rig_character.py"}}
    for key in ("materials", "images", "samplers", "textures"):
        if key in js:
            out[key] = json.loads(json.dumps(js[key]))
    # 不继承 extensionsUsed：源里的 KHR_materials_volume / FB_ngon_encoding 对应的数据
    # 我们没有搬运，声明了反而误导解析器。材质的 extensions 字段也一并剥掉。
    for m in out.get("materials", []):
        m.pop("extensions", None)

    w = BinWriter()
    a_pos = w.add(P.astype(np.float32), 5126, "VEC3", target=34962, minmax=True)
    attrs = {"POSITION": a_pos}
    if nrm is not None:
        attrs["NORMAL"] = w.add(nrm, 5126, "VEC3", target=34962)
    if uv is not None:
        attrs["TEXCOORD_0"] = w.add(uv, 5126, "VEC2", target=34962)
    attrs["JOINTS_0"] = w.add(joints, 5123, "VEC4", target=34962)
    attrs["WEIGHTS_0"] = w.add(weights, 5126, "VEC4", target=34962)
    a_idx = w.add(idx, 5125, "SCALAR", target=34963)

    new_prim = {"attributes": attrs, "indices": a_idx, "mode": prim.get("mode", 4)}
    if "material" in prim:
        new_prim["material"] = prim["material"]
    out["meshes"] = [{"name": "character", "primitives": [new_prim]}]

    # 关节节点：索引 1..n（0 留给带 mesh 的节点）
    nodes = [{"name": "Character", "mesh": 0, "skin": 0}]
    joint_node_ids = []
    for i, name in enumerate(names):
        p = parents[i]
        local = heads[i] - (heads[p] if p >= 0 else np.zeros(3))
        nodes.append({"name": name, "translation": [float(v) for v in local]})
        joint_node_ids.append(i + 1)
    for i in range(len(names)):
        kids = [joint_node_ids[j] for j in range(len(names)) if parents[j] == i]
        if kids:
            nodes[joint_node_ids[i]]["children"] = kids
    roots = [joint_node_ids[i] for i in range(len(names)) if parents[i] < 0]
    out["nodes"] = nodes
    out["scenes"] = [{"nodes": [0] + roots}]
    out["scene"] = 0

    ibm = np.zeros((len(names), 16), dtype=np.float32)
    for i in range(len(names)):
        m = np.eye(4)
        m[:3, 3] = -heads[i]
        ibm[i] = m.T.reshape(-1)          # glTF 是列主序
    a_ibm = w.add(ibm, 5126, "MAT4")
    out["skins"] = [{"name": "rig", "joints": joint_node_ids,
                     "inverseBindMatrices": a_ibm, "skeleton": roots[0]}]

    # ---- 动画 ----
    animations = []
    specs = [
        ("idle", 3.2, {
            "spine": lambda p: ((1, 0, 0), math.radians(1.6) * math.sin(2 * math.pi * p)),
            "chest": lambda p: ((1, 0, 0), math.radians(1.2) * math.sin(2 * math.pi * p + 0.5)),
            "head": lambda p: ((0, 1, 0), math.radians(5.0) * math.sin(2 * math.pi * p * 0.5)),
            "upperarm_L": lambda p: ((0, 0, 1), math.radians(-2.5) * (1 + math.sin(2 * math.pi * p))),
            "upperarm_R": lambda p: ((0, 0, 1), math.radians(2.5) * (1 + math.sin(2 * math.pi * p))),
        }, {"hips": lambda p: (0.0, 0.006 * height * math.sin(4 * math.pi * p), 0.0)}),
        ("walk", 1.05, walk_curves(24.0, 17.0, height),
         {"hips": lambda p: (0.0, 0.013 * height * abs(math.sin(2 * math.pi * p)), 0.0)}),
        ("run", 0.62, walk_curves(42.0, 34.0, height),
         {"hips": lambda p: (0.0, 0.030 * height * abs(math.sin(2 * math.pi * p)) - 0.012 * height, 0.0)}),
    ]
    for name, period, curves, trans_fn in specs:
        t, rot, trans = cycle(name, index, args.frames, period, curves, trans_fn)
        a_time = w.add(t.astype(np.float32), 5126, "SCALAR", minmax=True)
        channels, samplers = [], []
        for node_i, q in rot.items():
            a_out = w.add(q.astype(np.float32), 5126, "VEC4")
            samplers.append({"input": a_time, "output": a_out, "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers) - 1,
                             "target": {"node": node_i + 1, "path": "rotation"}})
        for node_i, tr in trans.items():
            base = np.array(nodes[node_i + 1]["translation"])
            a_out = w.add((base[None, :] + tr).astype(np.float32), 5126, "VEC3")
            samplers.append({"input": a_time, "output": a_out, "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers) - 1,
                             "target": {"node": node_i + 1, "path": "translation"}})
        animations.append({"name": name, "channels": channels, "samplers": samplers})
    out["animations"] = animations

    # 贴图数据在源文件的 BIN 里，必须一并搬过来并重写 bufferView 索引，
    # 否则 images[].bufferView 会指向新 BIN 的错误偏移（实测 Godot 报 PNG parse error）。
    if "images" in out:
        images = []
        for img in out["images"]:
            entry = dict(img)
            if "bufferView" in img:
                src_view = js["bufferViews"][img["bufferView"]]
                start = src_view.get("byteOffset", 0)
                blob = bin_chunk[start:start + src_view["byteLength"]]
                w._pad()
                offset = len(w.blob)
                w.blob.extend(blob)
                w.views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(blob)})
                entry["bufferView"] = len(w.views) - 1
            images.append(entry)
        out["images"] = images

    out["bufferViews"] = w.views
    out["accessors"] = w.accessors
    out["buffers"] = [{"byteLength": len(w.blob)}]

    total = write_glb(args.dst, out, w.blob)

    influences = (weights > 1e-6).sum(axis=1)
    report = {
        "source": args.src,
        "output": args.dst,
        "bytes": total,
        "vertices": int(len(P)),
        "triangles": int(len(idx) // 3),
        "height_local": height,
        "recentre": {"x": cx, "z": cz},
        "bones": len(names),
        "bone_names": names,
        "animations": [{"name": s[0], "period_s": s[1], "frames": args.frames} for s in specs],
        "weights": {
            "orphan_vertices_snapped_to_nearest_bone": orphans,
            "influences_mean": float(influences.mean()),
            "influences_max": int(influences.max()),
            "weight_sum_min": float(weights.sum(axis=1).min()),
            "weight_sum_max": float(weights.sum(axis=1).max()),
        },
        "note": "程序化包络蒙皮；角色在冻结机位下约 128 px 高，包络瑕疵在该尺寸不可见。",
    }
    if args.report:
        with open(args.report, "w") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
