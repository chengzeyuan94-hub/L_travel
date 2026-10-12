# 骰子 v2：在 Blender 里导出游戏用 GLB、六面正交核对图和 2D 兜底用的骰面 atlas。
# 先跑 run_asset.sh dice（建模 + 图标），再：python3 tools/ui_icons/bl.py tools/ui_icons/export_dice_game.py
# 可在最前面加 OUT_ROOT = "/some/dir" 把产物写到别处（核对用）；默认写回仓库。
import bpy, math, os
import numpy as np
from mathutils import Vector, Matrix

REPO = "/Users/chengzeyuan/Developer/SilkRoad"
try:
    OUT_ROOT
except NameError:
    OUT_ROOT = None
OUT_GLB = (OUT_ROOT or REPO + "/assets/game/dice") + "/dice_lshu_v2.glb"
OUT_ATLAS = (OUT_ROOT or REPO + "/assets/game/dice") + "/dice_face_atlas_v2.png"
OUT_CHECK = (OUT_ROOT or REPO + "/art-src/dice-v2") + "/04_ortho_check.png"
OUT_FACES_DIR = os.path.join(bpy.app.tempdir or "/tmp", "dice_v2_faces")  # 中间单面渲染，不进仓库

sc = bpy.data.scenes["LshuIconStudio"]
prev_scene = bpy.context.window.scene
bpy.context.window.scene = sc
col = bpy.data.collections["icon_dice"]
ob = bpy.data.objects["dice_lshu"]
icon_rot = tuple(ob.rotation_euler)

# 面契约（Blender）：face -> (n, s=右, t=上)
FACES = {
    1: ((0, 0, 1), (1, 0, 0), (0, 1, 0)),
    "EVENT": ((0, 0, -1), (1, 0, 0), (0, -1, 0)),
    2: ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
    5: ((0, 1, 0), (-1, 0, 0), (0, 0, 1)),
    3: ((1, 0, 0), (0, 1, 0), (0, 0, 1)),
    4: ((-1, 0, 0), (0, -1, 0), (0, 0, 1)),
}
ATLAS_CELLS = {1: (0, 0), 2: (1, 0), 3: (2, 0), 4: (0, 1), 5: (1, 1), "EVENT": (2, 1)}


def present(face):
    """把某一面转到正对相机（相机在 -Y 看 +Y，上 = +Z），面的“上”朝上。"""
    n, s, t = (Vector(v) for v in FACES[face])
    src = Matrix((s, t, n)).transposed()
    dst = Matrix(((1, 0, 0), (0, 0, 1), (0, -1, 0))).transposed()
    ob.matrix_world = (dst @ src.transposed()).to_4x4()


# 只显示骰子集合
vis_state = {c.name: (c.hide_render, c.hide_viewport) for c in bpy.data.collections["LshuIcons"].children}
for c in bpy.data.collections["LshuIcons"].children:
    c.hide_render = (c.name != "icon_dice")
cam = bpy.data.objects["ortho_cam"]; cam.data.type = 'ORTHO'
cam.location = (0, -4, 0); cam.rotation_euler = (math.pi / 2, 0, 0)
sc.camera = cam
os.makedirs(OUT_FACES_DIR, exist_ok=True)
res_state = (sc.render.resolution_x, sc.render.resolution_y, sc.render.film_transparent, sc.render.filepath)


def render_face(face, path, ortho, transparent, px):
    present(face)
    cam.data.ortho_scale = ortho
    sc.render.film_transparent = transparent
    sc.render.resolution_x = px; sc.render.resolution_y = px
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def load_px(path):
    im = bpy.data.images.load(path, check_existing=False)
    w, h = im.size
    px = np.array(im.pixels[:], dtype=np.float32).reshape(h, w, 4)[::-1]  # 行 0 在上
    bpy.data.images.remove(im)
    return px


def compose(cells, W, H, out, bg=(0.0, 0.0, 0.0, 0.0)):
    """cells: [(path, x, y)]，x/y 是左上角像素；按 alpha 叠在底色上。"""
    buf = np.empty((H, W, 4), np.float32); buf[:] = bg
    for path, x, y in cells:
        px = load_px(path); h, w = px.shape[:2]
        dst = buf[y:y + h, x:x + w]
        a = px[..., 3:4]
        dst[..., :3] = px[..., :3] * a + dst[..., :3] * (1 - a)
        dst[..., 3:4] = a + dst[..., 3:4] * (1 - a)
    img = bpy.data.images.new("dice_compose", W, H, alpha=True)
    img.pixels = buf[::-1].ravel()
    img.filepath_raw = out; img.file_format = 'PNG'; img.save()
    bpy.data.images.remove(img)


# 1) atlas：3×2，每格 512，正好框住整面（棱长 1.0），透明底
atlas_cells = []
for face, (cx, cy) in ATLAS_CELLS.items():
    p = os.path.join(OUT_FACES_DIR, f"atlas_{face}.png")
    render_face(face, p, 1.0, True, 512)
    atlas_cells.append((p, cx * 512, cy * 512))
compose(atlas_cells, 1536, 1024, OUT_ATLAS)

# 2) 正交核对：上排 FRONT=2 RIGHT=3 BACK=5 LEFT=4，下排居中 TOP=1 BOTTOM=EVENT（与 02_fourview.png 同排布）
check_cells = []
for i, face in enumerate((2, 3, 5, 4)):
    p = os.path.join(OUT_FACES_DIR, f"check_{face}.png")
    render_face(face, p, 1.15, True, 512)
    check_cells.append((p, i * 512, 0))
for i, face in enumerate((1, "EVENT")):
    p = os.path.join(OUT_FACES_DIR, f"check_{face}.png")
    render_face(face, p, 1.15, True, 512)
    check_cells.append((p, 512 + i * 512, 512))
bg = (0.969, 0.933, 0.867, 1.0)  # 暖奶油底 #F7EEDD（与 02_fourview.png 一致）
compose(check_cells, 2048, 1024, OUT_CHECK, bg=bg)

# 3) GLB：单位姿态，只选骰子
ob.matrix_world = Matrix.Identity(4)
for s_ in bpy.data.scenes:
    for vl in s_.view_layers:
        for o in s_.objects:
            try: o.select_set(False, view_layer=vl)
            except Exception: pass
ob.select_set(True)
bpy.context.view_layer.objects.active = ob
os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
kw = dict(filepath=OUT_GLB, use_selection=True, export_format='GLB', export_apply=True, export_yup=True,
          export_texcoords=False, export_normals=True, export_materials='EXPORT', export_animations=False)
try:
    bpy.ops.export_scene.gltf(export_vertex_color='ACTIVE', **kw)
except TypeError:
    bpy.ops.export_scene.gltf(export_colors=True, **kw)
ob.select_set(False)

# 还原：图标姿态、集合可见性、渲染设置、窗口场景
ob.rotation_mode = 'XYZ'; ob.rotation_euler = icon_rot
for name, (hr, hv) in vis_state.items():
    c = bpy.data.collections[name]; c.hide_render = hr; c.hide_viewport = hv
sc.render.resolution_x, sc.render.resolution_y, sc.render.film_transparent, sc.render.filepath = res_state
bpy.context.window.scene = prev_scene
print({"glb": OUT_GLB, "atlas": OUT_ATLAS, "check": OUT_CHECK, "tris": sum(len(p.vertices) - 2 for p in ob.data.polygons)})
