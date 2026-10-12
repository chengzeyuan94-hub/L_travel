# 渲染一件图标物件：透明底 3/4 图标 + 四个正交核对视图 + 导出 GLB。
# 发送前在代码最前面加一行 KEY = "xxx"; OUT_ICON / OUT_DOC / OUT_GLB 同理（见 run_asset.sh）。
import bpy, math, os
from mathutils import Vector
sc = bpy.data.scenes["LshuIconStudio"]
bpy.context.window.scene = sc
root = bpy.data.collections["LshuIcons"]
for c in root.children:
    c.hide_render = (c.name != "icon_" + KEY)
    c.hide_viewport = (c.name != "icon_" + KEY)
col = bpy.data.collections["icon_" + KEY]
objs = [o for o in col.all_objects if o.type == 'MESH']
bpy.context.view_layer.update()
mn = Vector((1e9, 1e9, 1e9)); mx = Vector((-1e9, -1e9, -1e9))
for o in objs:
    for v in o.bound_box:
        w = o.matrix_world @ Vector(v)
        mn = Vector(map(min, mn, w)); mx = Vector(map(max, mx, w))
ctr = (mn + mx) / 2; size = mx - mn; big = max(size)
# 图标：透明底、三分之四俯视、长焦
cam = bpy.data.objects["icon_cam"]; cam.data.type = 'PERSP'; cam.data.lens = 70
d = Vector((-0.62, -1.0, 0.62)).normalized()
# 集合上可设 icon_dist 覆盖机位距离倍数（骰子这种方正物件需要退远一点，免得裁边）
cam.location = ctr + d * big * float(col.get("icon_dist", 2.55))
cam.rotation_euler = (ctr - cam.location).to_track_quat('-Z', 'Y').to_euler()
sc.camera = cam
sc.render.film_transparent = True
sc.render.resolution_x = 1024; sc.render.resolution_y = 1024
os.makedirs(os.path.dirname(OUT_ICON), exist_ok=True)
sc.render.filepath = OUT_ICON
bpy.ops.render.render(write_still=True)
# 四个正交视图（灰底）拼成一行
oc = bpy.data.objects["ortho_cam"]; oc.data.type = 'ORTHO'; oc.data.ortho_scale = big * 1.25
sc.camera = oc; sc.render.film_transparent = False
sc.render.resolution_x = 512; sc.render.resolution_y = 512
views = [("front", (0, -1, 0)), ("right", (1, 0, 0)), ("back", (0, 1, 0)), ("left", (-1, 0, 0))]
os.makedirs(OUT_DOC, exist_ok=True)
paths = []
for name, dv in views:
    dv = Vector(dv); oc.location = ctr + dv * big * 4
    oc.rotation_euler = (ctr - oc.location).to_track_quat('-Z', 'Y').to_euler()
    p = os.path.join(OUT_DOC, f"_ortho_{name}.png"); sc.render.filepath = p
    bpy.ops.render.render(write_still=True); paths.append(p)
# 拼接
imgs = [bpy.data.images.load(p, check_existing=False) for p in paths]
W = 512; strip = bpy.data.images.new("strip_" + KEY, W * 4, W)
px = [0.0] * (W * 4 * W * 4)
for i, im in enumerate(imgs):
    src = list(im.pixels)
    for y in range(W):
        row = src[y * W * 4:(y + 1) * W * 4]
        px[(y * W * 4 + i * W) * 4:(y * W * 4 + i * W) * 4 + W * 4] = row
strip.pixels = px
strip.filepath_raw = os.path.join(OUT_DOC, "04-ortho-check.png"); strip.file_format = 'PNG'; strip.save()
for im in imgs: bpy.data.images.remove(im)
bpy.data.images.remove(strip)
for p in paths: os.remove(p)
# 导出 GLB（只导这一件）
for s_ in bpy.data.scenes:
    for vl in s_.view_layers:
        for o in s_.objects:
            try: o.select_set(False, view_layer=vl)
            except Exception: pass
for o in objs: o.select_set(True)
bpy.context.view_layer.objects.active = objs[0]
os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
bpy.ops.export_scene.gltf(filepath=OUT_GLB, use_selection=True, export_format='GLB', export_apply=True)
print({"key": KEY, "size": [round(x, 3) for x in size], "objects": len(objs), "tris": sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs)})
