# 骰子 v2（2026-09-26）：奶油色粘土玩具骰，圆润倒角 + 凹坑巧克力釉点 + 事件面「眼镜 + 土豆花」徽章。
# 依据：art-src/dice-v2/01_concept.png（概念）与 02_fourview.png（六面正交图，面契约见同目录 02_fourview_prompt.txt）。
# 前面会先拼上 lib_lowpoly.py 与 KEY = 'dice'（见 run_asset.sh）。
#
# 面契约（Blender Z 朝上；glTF 导出 (x,y,z)->(x,z,-y) 后即 Godot 的 Dice3DView.FACE_NORMALS）：
#   1 = +Z, EVENT = -Z, 2 = -Y, 5 = +Y, 3 = +X, 4 = -X
# 每面的 (右 s, 上 t) 与 Godot 的 _face_texture_up 一致，2、3 的斜线从左上到右下，徽章朝 t 方向立正。
# 模型：棱长 1.0、中心在原点、一个合并网格、顶点色 "Col"（不需要贴图）、三个材质槽：
#   lp_dice_clay（哑光粘土）/ lp_dice_gloss（点与眼镜的釉面）/ lp_dice_glow（土豆花微光）。
# 渲图标时整颗骰子绕 X 转 -90°（2 在上、事件面朝前、4 在左）；游戏用的 GLB 由 export_dice_game.py 按单位姿态导出。
import math
import bpy, bmesh
from mathutils import Vector, Matrix, Quaternion

studio = bpy.data.scenes.get("LshuIconStudio")
if studio is not None and bpy.context.window is not None:
    bpy.context.window.scene = studio

c = asset_col(KEY)
c["icon_dist"] = 3.3
# 上一次别的图标出图会把本集合设为视口/渲染隐藏；布尔求值需要它在视口深度图里
c.hide_viewport = False; c.hide_render = False
def _unexclude(lc):
    for ch in lc.children:
        if ch.collection == c:
            ch.exclude = False; ch.hide_viewport = False
        _unexclude(ch)
_unexclude(bpy.context.view_layer.layer_collection)
for o in list(bpy.data.objects):
    if o.name.startswith("dice_") and not o.users_collection:
        bpy.data.objects.remove(o, do_unlink=True)

def srgb(h):
    h = h.lstrip('#'); return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))

CREAM = srgb("#FBF3E4"); CREAM_EDGE = srgb("#F4E8D1"); FLOOR = srgb("#F3E4C6"); WALL = srgb("#EADBC0")
INK = srgb("#3A2A22"); OLIVE = srgb("#8A8B5A"); STITCH = srgb("#F1E6C4"); LEAF = srgb("#7DBF6A")
PETAL = srgb("#FFFDF4"); POLLEN = srgb("#F6C945")

EDGE = 1.0; H = EDGE / 2; BEVEL = 0.15; BEVEL_SEGS = 3
A = 0.215                     # 点中心离面中心（按 02_fourview.png 量）
PIP_R, PIP_D = 0.10, 0.030    # 凹坑半径 / 深度
PIP1_R, PIP1_D = 0.15, 0.038  # 1 点更大
FILL_K = 0.90                 # 釉面半径 / 凹坑半径
MED_R, MED_D = 0.33, 0.022    # 事件徽章凹槽半径 / 深度

FACES = {  # face: (n, s, t)
    1: ((0, 0, 1), (1, 0, 0), (0, 1, 0)),
    "EVENT": ((0, 0, -1), (1, 0, 0), (0, -1, 0)),
    2: ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
    5: ((0, 1, 0), (-1, 0, 0), (0, 0, 1)),
    3: ((1, 0, 0), (0, 1, 0), (0, 0, 1)),
    4: ((-1, 0, 0), (0, -1, 0), (0, 0, 1)),
}
PIPS = {1: [(0, 0)], 2: [(-A, A), (A, -A)], 3: [(-A, A), (0, 0), (A, -A)],
        4: [(-A, A), (A, A), (-A, -A), (A, -A)], 5: [(-A, A), (A, A), (-A, -A), (A, -A), (0, 0)]}


def face_point(face, s, t, depth=0.0):
    n, sv, tv = (Vector(v) for v in FACES[face])
    return n * (H - depth) + sv * s + tv * t


def dice_mat(name, rough, gloss_coat=0.0, glow=0.0):
    m = bpy.data.materials.get("lp_" + name) or bpy.data.materials.new("lp_" + name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes.get("Principled BSDF")
    attr = nt.nodes.get("dice_col") or nt.nodes.new("ShaderNodeVertexColor")
    attr.name = "dice_col"; attr.layer_name = "Col"; attr.location = (-400, 200)
    nt.links.new(attr.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = 0.0
    b.inputs["Specular IOR Level"].default_value = 0.18 if rough < 0.5 else 0.5
    b.inputs["Coat Weight"].default_value = gloss_coat
    b.inputs["Coat Roughness"].default_value = 0.12
    if glow > 0:
        nt.links.new(attr.outputs["Color"], b.inputs["Emission Color"])
        b.inputs["Emission Strength"].default_value = glow
    else:
        b.inputs["Emission Strength"].default_value = 0.0
    return m

M_CLAY = dice_mat("dice_clay", 0.62)
M_GLOSS = dice_mat("dice_gloss", 0.48, gloss_coat=0.0)
M_GLOW = dice_mat("dice_glow", 0.45, glow=0.35)


def paint(o, rgb, alpha=1.0, per_face=None):
    """写入 Col（面角域），per_face(poly) -> rgb 可逐面改色。"""
    me = o.data
    attr = me.color_attributes.get("Col") or me.color_attributes.new("Col", 'FLOAT_COLOR', 'CORNER')
    for p in me.polygons:
        col = per_face(p) if per_face else rgb
        for li in p.loop_indices:
            attr.data[li].color_srgb = (*col, alpha)
    me.color_attributes.active_color = attr
    me.color_attributes.render_color_index = me.color_attributes.find("Col")


def set_mat(o, m):
    o.data.materials.clear(); o.data.materials.append(m)


def orient(o, n, loc):
    o.rotation_mode = 'QUATERNION'
    o.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(Vector(n))
    o.location = loc


def smooth(o, flag=True):
    for p in o.data.polygons:
        p.use_smooth = flag


def cap_depth(rc, d, rho):
    """球面凹坑在半径 rho 处离面的深度。"""
    R = (rc * rc + d * d) / (2 * d)
    return d - (R - math.sqrt(max(R * R - rho * rho, 0.0)))


def uv_sphere(name, radius, segs=20, rings=14):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=radius)
    return _obj_from_bm(bm, name, c, None, flat=False)


def closed_tube(name, pts, n, w, h, segs=8, m=None):
    """沿闭合折线扫出椭圆截面的管子：面内半宽 w、法向半高 h（眼镜框）。"""
    n = Vector(n).normalized()
    bm = bmesh.new(); rings = []
    k = len(pts)
    for i in range(k):
        p = Vector(pts[i]); tng = (Vector(pts[(i + 1) % k]) - Vector(pts[i - 1])).normalized()
        side = tng.cross(n).normalized()
        rings.append([bm.verts.new(p + side * w * math.cos(2 * math.pi * j / segs) + n * h * math.sin(2 * math.pi * j / segs)) for j in range(segs)])
    for i in range(k):
        a, b = rings[i], rings[(i + 1) % k]
        for j in range(segs):
            bm.faces.new((a[j], a[(j + 1) % segs], b[(j + 1) % segs], b[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _obj_from_bm(bm, name, c, m, flat=False)


# ---------- 1. 骰体：圆润倒角立方体（3 段平面倒角 = 低多边形刻面） ----------
bm = bmesh.new()
bmesh.ops.create_cube(bm, size=EDGE)
bmesh.ops.bevel(bm, geom=list(bm.edges), offset=BEVEL, segments=BEVEL_SEGS, affect='EDGES', profile=0.5, clamp_overlap=False)
body = _obj_from_bm(bm, "dice_body", c, None, flat=True)

# ---------- 2. 切割体：点的球面凹坑 + 事件面浅圆槽 ----------
cutters = []
for face, pts in PIPS.items():
    rc, d = (PIP1_R, PIP1_D) if face == 1 else (PIP_R, PIP_D)
    R = (rc * rc + d * d) / (2 * d)
    n = Vector(FACES[face][0])
    for i, (s, t) in enumerate(pts):
        sp = uv_sphere(f"dice_cut_{face}_{i}", R, segs=24 if face == 1 else 20, rings=16)
        orient(sp, n, face_point(face, s, t) + n * (R - d))
        cutters.append(sp)
bm = bmesh.new()
bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=56, radius1=MED_R, radius2=MED_R, depth=0.3)
med_cut = _obj_from_bm(bm, "dice_cut_medallion", c, None, flat=True)
orient(med_cut, (0, 0, -1), face_point("EVENT", 0, 0, MED_D) + Vector((0, 0, -0.15)))
cutters.append(med_cut)
bpy.context.view_layer.update()
# 合并切割体为一个物体后做一次布尔（EXACT）
cut_bm = bmesh.new()
for o in cutters:
    me = o.data.copy(); me.transform(o.matrix_world); cut_bm.from_mesh(me); bpy.data.meshes.remove(me)
cut_me = bpy.data.meshes.new("dice_cutters"); cut_bm.to_mesh(cut_me); cut_bm.free()
cut_obj = bpy.data.objects.new("dice_cutters", cut_me); c.objects.link(cut_obj)
for o in cutters:
    me = o.data; bpy.data.objects.remove(o, do_unlink=True); bpy.data.meshes.remove(me)
mod = body.modifiers.new("cut", 'BOOLEAN'); mod.operation = 'DIFFERENCE'; mod.solver = 'EXACT'; mod.object = cut_obj
cut_obj.hide_render = True; cut_obj.display_type = 'WIRE'
bpy.context.view_layer.update()
dg = bpy.context.evaluated_depsgraph_get()
new_me = bpy.data.meshes.new_from_object(body.evaluated_get(dg))
old_me = body.data; body.modifiers.clear(); body.data = new_me; bpy.data.meshes.remove(old_me)
new_me.name = "dice_body"
me = cut_obj.data; bpy.data.objects.remove(cut_obj, do_unlink=True); bpy.data.meshes.remove(me)

# 刻面：平面与倒角保持平直；凹坑内部用平滑着色，边缘自然成硬棱
def is_pip_face(p):
    nrm = p.normal; ctr = p.center
    ax = max(range(3), key=lambda i: abs(nrm[i]))
    # 与所在大面法线不共线、又在大面平面附近以内的面 = 凹坑内壁
    return abs(nrm[ax]) < 0.9999 and abs(ctr[ax]) < H - 0.001 and abs(ctr[ax]) > H - 0.06 and all(abs(ctr[i]) < H - BEVEL + 0.001 for i in range(3) if i != ax)

for p in body.data.polygons:
    ctr = p.center
    in_med = ctr.z < -H + MED_D + 0.002 and math.hypot(ctr.x, ctr.y) < MED_R + 0.002
    p.use_smooth = is_pip_face(p) and not in_med

def body_color(p):
    ctr = p.center; nrm = p.normal
    r = math.hypot(ctr.x, ctr.y)
    if ctr.z < -H + MED_D + 0.002 and r < MED_R + 0.002:
        return FLOOR if nrm.z < -0.99 else WALL
    if max(abs(nrm.x), abs(nrm.y), abs(nrm.z)) < 0.999:
        return CREAM_EDGE if not is_pip_face(p) else CREAM
    return CREAM
paint(body, CREAM, per_face=body_color)
set_mat(body, M_CLAY)
parts = [body]

# ---------- 3. 点：凹坑里的巧克力釉面（微微隆起，低于表面） ----------
for face, pts in PIPS.items():
    rc, d = (PIP1_R, PIP1_D) if face == 1 else (PIP_R, PIP_D)
    rf = rc * FILL_K
    rim = cap_depth(rc, d, rf)
    top = rim * 0.32
    prof = [(1e-5, -d + 0.004), (rf + 0.004, -d + 0.004), (rf + 0.004, -rim - 0.001),
            (rf * 0.85, -(top + (rim - top) * 0.72)), (rf * 0.6, -(top + (rim - top) * 0.36)),
            (rf * 0.3, -(top + (rim - top) * 0.09)), (1e-5, -top)]
    n = Vector(FACES[face][0])
    for i, (s, t) in enumerate(pts):
        o = lathe(f"dice_pip_{face}_{i}", c, prof, segs=24 if face == 1 else 20, m=None, cap_top=False, cap_bottom=False)
        orient(o, n, face_point(face, s, t))
        # 只有圆顶平滑；侧壁保持平直，否则平滑法线会把圆顶边缘掰斜、反出一圈银光
        for poly in o.data.polygons:
            poly.use_smooth = poly.normal.z > 0.5
        paint(o, INK); set_mat(o, M_GLOSS); parts.append(o)

# ---------- 4. 事件徽章（-Z 面；s=+X，t=-Y 为“上”） ----------
EN = Vector((0, 0, -1))
def ev(s, t, depth):
    return face_point("EVENT", s, t, depth)

# 橄榄绿凸环（紧贴凹槽壁）
ring_prof = [(0.262, -0.034), (0.262, -0.016), (0.268, -0.010), (0.282, -0.0068), (0.310, -0.0068), (0.324, -0.010), (MED_R + 0.004, -0.016), (MED_R + 0.004, -0.034)]
ring = lathe("dice_med_ring", c, ring_prof, segs=64, cap_top=False, cap_bottom=False)
orient(ring, EN, ev(0, 0, 0)); smooth(ring); paint(ring, OLIVE); set_mat(ring, M_CLAY); parts.append(ring)
# 缝线虚线
for i in range(22):
    a = 2 * math.pi * i / 22
    bm = bmesh.new(); bmesh.ops.create_cube(bm, size=1.0)
    o = _obj_from_bm(bm, f"dice_med_stitch_{i}", c, None, flat=True)
    o.scale = (0.020, 0.0055, 0.004)
    o.rotation_mode = 'QUATERNION'
    o.rotation_quaternion = Quaternion((0, 0, 1), a + math.pi / 2)
    o.location = ev(0.296 * math.cos(a), -0.296 * math.sin(a), 0.0066)  # 世界角 a（t = -Y）
    paint(o, STITCH); set_mat(o, M_CLAY); parts.append(o)

# 眼镜：两只方圆镜框 + 鼻梁 + 两截镜腿
GL_Y = -0.052; GL_X = 0.110; LA, LB, P = 0.080, 0.068, 4.0
GL_W, GL_H = 0.022, 0.015
GL_DEPTH = MED_D - 0.004
for side in (-1, 1):
    pts = []
    for k in range(44):
        th = 2 * math.pi * k / 44
        cx, cy = math.cos(th), math.sin(th)
        x = LA * math.copysign(abs(cx) ** (2 / P), cx); y = LB * math.copysign(abs(cy) ** (2 / P), cy)
        pts.append(ev(side * GL_X + x, GL_Y + y, GL_DEPTH))
    o = closed_tube(f"dice_glasses_lens_{'l' if side < 0 else 'r'}", pts, EN, GL_W, GL_H, segs=8)
    paint(o, INK); set_mat(o, M_GLOSS); parts.append(o)
bridge_pts = [ev(x, GL_Y + 0.036 + 0.010 * (1 - (x / 0.034) ** 2), GL_DEPTH) for x in (-0.036, -0.018, 0.0, 0.018, 0.036)]
o = sweep("dice_glasses_bridge", c, bridge_pts, [0.016] * 5, segs=8)
paint(o, INK); set_mat(o, M_GLOSS); smooth(o); parts.append(o)
for side in (-1, 1):
    o = sweep(f"dice_glasses_temple_{side}", c, [ev(side * 0.186, GL_Y + 0.046, GL_DEPTH), ev(side * 0.222, GL_Y + 0.054, GL_DEPTH)], [0.015, 0.014], segs=8)
    paint(o, INK); set_mat(o, M_GLOSS); smooth(o); parts.append(o)

# 土豆花嫩芽：茎 + 两片叶 + 五瓣白花（微光）+ 黄花心
SP_DEPTH = MED_D - 0.006
o = sweep("dice_sprout_stem", c, [ev(0, -0.004, SP_DEPTH), ev(0.003, 0.035, SP_DEPTH), ev(0, 0.075, SP_DEPTH)], [0.010, 0.0095, 0.009], segs=6)
paint(o, LEAF); set_mat(o, M_CLAY); smooth(o); parts.append(o)
for side in (-1, 1):
    o = ico(f"dice_sprout_leaf_{side}", c, radius=1.0, subdiv=2)
    o.scale = (0.052, 0.024, 0.010)
    o.rotation_mode = 'QUATERNION'
    # 叶子长轴在面内斜向上（t 为上 = -Y）
    ang = math.radians(16 if side > 0 else 180 - 16)
    o.rotation_quaternion = Quaternion((0, 0, 1), -ang)
    o.location = ev(side * 0.090, 0.090, SP_DEPTH - 0.002)
    smooth(o); paint(o, LEAF); set_mat(o, M_CLAY); parts.append(o)
FL = (0.0, 0.118)
for k in range(5):
    a = math.pi / 2 + 2 * math.pi * k / 5
    o = ico(f"dice_flower_petal_{k}", c, radius=1.0, subdiv=2)
    o.scale = (0.036, 0.027, 0.010)
    o.rotation_mode = 'QUATERNION'
    o.rotation_quaternion = Quaternion((0, 0, 1), -a)
    o.location = ev(FL[0] + 0.034 * math.cos(a), FL[1] + 0.034 * math.sin(a), SP_DEPTH - 0.004)
    smooth(o); paint(o, PETAL); set_mat(o, M_GLOW); parts.append(o)
o = ico("dice_flower_heart", c, radius=1.0, subdiv=2)
o.scale = (0.019, 0.019, 0.008); o.location = ev(FL[0], FL[1], SP_DEPTH - 0.003)
smooth(o); paint(o, POLLEN); set_mat(o, M_GLOW); parts.append(o)

# ---------- 5. 合并为一个网格 dice_lshu（单位姿态） ----------
bpy.context.view_layer.update()
for s_ in bpy.data.scenes:
    for vl in s_.view_layers:
        for ob in s_.objects:
            try: ob.select_set(False, view_layer=vl)
            except Exception: pass
for o in parts:
    o.select_set(True)
with bpy.context.temp_override(active_object=body, object=body, selected_objects=parts, selected_editable_objects=parts):
    bpy.ops.object.join()
body.name = "dice_lshu"; body.data.name = "dice_lshu"
# 把变换烘进顶点，物体本身保持单位变换
body.data.transform(body.matrix_world); body.matrix_world = Matrix.Identity(4)
for s_ in bpy.data.scenes:
    for vl in s_.view_layers:
        for ob in s_.objects:
            try: ob.select_set(False, view_layer=vl)
            except Exception: pass
# 图标姿态：2 在上、事件面朝前（-Y）、4 在左
body.rotation_mode = 'XYZ'
body.rotation_euler = (-math.pi / 2, 0, 0)
print({"key": KEY, "tris": sum(len(p.vertices) - 2 for p in body.data.polygons), "verts": len(body.data.vertices),
       "mats": [m.name for m in body.data.materials], "objects": len(c.objects)})
