# 旅行L叔 三维图标：Blender 内的建模函数库（通过 bl.py 发进正在运行的 Blender）
import bpy, bmesh, math
from mathutils import Vector, Matrix

ROOT = "LshuIcons"

def root_col():
    c = bpy.data.collections.get(ROOT)
    if c is None:
        c = bpy.data.collections.new(ROOT)
        bpy.context.scene.collection.children.link(c)
    return c

def asset_col(key, clear=True):
    """每件物件一个子集合；重建时先清空。"""
    name = "icon_" + key
    c = bpy.data.collections.get(name)
    if c is None:
        c = bpy.data.collections.new(name)
        root_col().children.link(c)
    elif clear:
        for o in list(c.objects):
            me = o.data if o.type == 'MESH' else None
            bpy.data.objects.remove(o, do_unlink=True)
            if me is not None and me.users == 0:
                bpy.data.meshes.remove(me)
    return c

def mat(name, rgb, rough=0.55, metal=0.0, emit=None, emit_strength=0.0, alpha=1.0):
    m = bpy.data.materials.get("lp_" + name)
    if m is None:
        m = bpy.data.materials.new("lp_" + name)
        m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (*rgb, 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if emit is not None:
        b.inputs["Emission Color"].default_value = (*emit, 1.0)
        b.inputs["Emission Strength"].default_value = emit_strength
    if alpha < 1.0:
        b.inputs["Alpha"].default_value = alpha
        m.surface_render_method = 'BLENDED'
    return m

def hexrgb(h):
    h = h.lstrip('#'); c = [int(h[i:i+2], 16) / 255 for i in (0, 2, 4)]
    return tuple((x / 12.92) if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)

def _obj_from_bm(bm, name, col, m=None, flat=True):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    for p in me.polygons:
        p.use_smooth = not flat
    o = bpy.data.objects.new(name, me)
    col.objects.link(o)
    if m is not None:
        o.data.materials.append(m)
    return o

def lathe(name, col, profile, segs=10, m=None, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), cap_top=True, cap_bottom=True, stagger=False):
    """profile: [(r, z), ...] 自下而上；绕 Z 轴旋转成型，段数少 = 刻面感。
    stagger=True：相邻两圈错开半格，面变成三角形，像宝石切面。"""
    bm = bmesh.new()
    rings = []
    for j, (r, z) in enumerate(profile):
        ring = []
        off = (math.pi / segs) if (stagger and j % 2 == 1) else 0.0
        for i in range(segs):
            a = 2 * math.pi * i / segs + off
            ring.append(bm.verts.new((r * math.cos(a), r * math.sin(a), z)))
        rings.append(ring)
    for j in range(len(rings) - 1):
        for i in range(segs):
            a, b = rings[j][i], rings[j][(i + 1) % segs]
            c, d = rings[j + 1][(i + 1) % segs], rings[j + 1][i]
            if not stagger:
                bm.faces.new((a, b, c, d))
            elif j % 2 == 0:
                bm.faces.new((a, b, d)); bm.faces.new((b, c, d))
            else:
                bm.faces.new((a, b, c)); bm.faces.new((a, c, d))
    if cap_bottom and profile[0][0] > 1e-4:
        bm.faces.new(list(reversed(rings[0])))
    if cap_top and profile[-1][0] > 1e-4:
        bm.faces.new(rings[-1])
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    o = _obj_from_bm(bm, name, col, m)
    o.location = loc; o.rotation_euler = rot; o.scale = scale
    return o

def box(name, col, size=(1, 1, 1), bevel=0.08, segs=1, m=None, loc=(0, 0, 0), rot=(0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
    if bevel > 0:
        bmesh.ops.bevel(bm, geom=list(bm.edges), offset=bevel, segments=segs, affect='EDGES', profile=0.5)
    o = _obj_from_bm(bm, name, col, m)
    o.location = loc; o.rotation_euler = rot
    return o

def ico(name, col, radius=0.5, subdiv=1, m=None, loc=(0, 0, 0), scale=(1, 1, 1), rot=(0, 0, 0), jitter=0.0, seed=1):
    import random
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=radius)
    if jitter > 0:
        rnd = random.Random(seed)
        for v in bm.verts:
            v.co *= 1.0 + rnd.uniform(-jitter, jitter)
    o = _obj_from_bm(bm, name, col, m)
    o.location = loc; o.scale = scale; o.rotation_euler = rot
    return o

def cyl(name, col, r=0.5, h=1.0, segs=8, m=None, loc=(0, 0, 0), rot=(0, 0, 0), r_top=None):
    rt = r if r_top is None else r_top
    return lathe(name, col, [(r, 0), (rt, h)], segs=segs, m=m, loc=loc, rot=rot)

def torus(name, col, R=0.5, r=0.12, segs=10, rsegs=6, m=None, loc=(0, 0, 0), rot=(0, 0, 0)):
    bm = bmesh.new()
    rings = []
    for i in range(segs):
        a = 2 * math.pi * i / segs
        ring = []
        for j in range(rsegs):
            b = 2 * math.pi * j / rsegs
            x = (R + r * math.cos(b)) * math.cos(a); y = (R + r * math.cos(b)) * math.sin(a); z = r * math.sin(b)
            ring.append(bm.verts.new((x, y, z)))
        rings.append(ring)
    for i in range(segs):
        for j in range(rsegs):
            a = rings[i][j]; b = rings[(i + 1) % segs][j]; c = rings[(i + 1) % segs][(j + 1) % rsegs]; d = rings[i][(j + 1) % rsegs]
            bm.faces.new((a, b, c, d))
    o = _obj_from_bm(bm, name, col, m)
    o.location = loc; o.rotation_euler = rot
    return o

def finish(key):
    """把物件放到地面中心（最低点 z=0），返回尺寸。"""
    c = bpy.data.collections["icon_" + key]
    objs = [o for o in c.objects if o.type == 'MESH']
    bpy.context.view_layer.update()
    mn = Vector((1e9, 1e9, 1e9)); mx = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        for v in o.bound_box:
            w = o.matrix_world @ Vector(v)
            mn = Vector(map(min, mn, w)); mx = Vector(map(max, mx, w))
    off = Vector(((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z))
    for o in objs:
        if o.parent is None:
            o.location -= off
    size = mx - mn
    return {"key": key, "size": [round(size.x, 3), round(size.y, 3), round(size.z, 3)], "objects": len(objs), "tris": sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs)}

def wobble(o, amt=0.02, seed=1, keep_bottom=True):
    """随机挪动顶点，做出手工低多边形的不规整感；keep_bottom 时底面保持平。"""
    import random
    rnd = random.Random(seed)
    zmin = min(v.co.z for v in o.data.vertices)
    for v in o.data.vertices:
        if keep_bottom and abs(v.co.z - zmin) < 1e-4:
            continue
        v.co.x += rnd.uniform(-amt, amt); v.co.y += rnd.uniform(-amt, amt); v.co.z += rnd.uniform(-amt, amt) * 0.6
    return o

def decal(name, col, m, center, normal, size=(0.06, 0.06), thick=0.015, subdiv=1):
    """贴在表面上的扁平小片（花纹、点、斑）。normal 为朝外方向。"""
    n = Vector(normal).normalized()
    o = ico(name, col, radius=1.0, subdiv=subdiv, m=m, loc=Vector(center) + n * thick * 0.3)
    q = Vector((1, 0, 0)).rotation_difference(n)
    o.rotation_mode = 'QUATERNION'; o.rotation_quaternion = q
    o.scale = (thick, size[0], size[1])
    return o

def pile(prefix, col, m, n, center, radius, height, r_item=0.05, scale=(1, 1, 1), seed=3, subdiv=1):
    """在一个半球形范围里堆一堆小颗粒（胡椒、乳香、枣……）。"""
    import random
    rnd = random.Random(seed)
    out = []
    for i in range(n):
        a = rnd.uniform(0, 2 * math.pi); rr = radius * math.sqrt(rnd.uniform(0, 1))
        h = height * math.sqrt(max(0.0, 1 - (rr / radius) ** 2)) * rnd.uniform(0.6, 1.0)
        p = (center[0] + rr * math.cos(a), center[1] + rr * math.sin(a), center[2] + h)
        s = rnd.uniform(0.85, 1.15)
        o = ico(f"{prefix}_{i}", col, radius=r_item, subdiv=subdiv, m=m, loc=p, scale=(scale[0] * s, scale[1] * s, scale[2] * s),
                rot=(rnd.uniform(0, 3.14), rnd.uniform(0, 3.14), rnd.uniform(0, 3.14)), jitter=0.12, seed=seed + i)
        out.append(o)
    return out

def sweep(name, col, pts, radii, segs=8, m=None, cap=True):
    """沿一条折线扫出管子（象牙、根须、茎），每个点一个半径。"""
    bm = bmesh.new()
    pts = [Vector(p) for p in pts]
    rings = []
    for i, p in enumerate(pts):
        t = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        up = Vector((0, 0, 1)) if abs(t.z) < 0.9 else Vector((1, 0, 0))
        u = t.cross(up).normalized(); v = t.cross(u).normalized()
        ring = [bm.verts.new(p + (u * math.cos(2 * math.pi * k / segs) + v * math.sin(2 * math.pi * k / segs)) * radii[i]) for k in range(segs)]
        rings.append(ring)
    for j in range(len(rings) - 1):
        for k in range(segs):
            bm.faces.new((rings[j][k], rings[j][(k + 1) % segs], rings[j + 1][(k + 1) % segs], rings[j + 1][k]))
    if cap:
        if radii[0] > 1e-4: bm.faces.new(list(reversed(rings[0])))
        if radii[-1] > 1e-4: bm.faces.new(rings[-1])
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _obj_from_bm(bm, name, col, m)

def surface_path(prefix, col, m, uv_pts, a0, radius_at, bead=0.028):
    """在旋转体表面画一条凸起的线：uv_pts 是 (弧长偏移, 高度) 序列，a0 是朝向角。"""
    out = []
    prev = None
    k = 0
    for (u, z) in uv_pts:
        r = radius_at(z)
        a = a0 + u / max(r, 1e-3)
        p = Vector((r * math.cos(a), r * math.sin(a), z))
        if prev is not None:
            n = max(1, int((p - prev).length / (bead * 0.7)))
            for s in range(1, n + 1):
                q = prev.lerp(p, s / n)
                out.append(ico(f"{prefix}_{k}", col, radius=bead, subdiv=1, m=m, loc=q)); k += 1
        prev = p
    return out
