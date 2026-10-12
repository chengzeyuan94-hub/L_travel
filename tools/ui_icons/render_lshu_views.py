# 从游戏正式模型渲 L叔 的正面 / 右侧 / 背面正交视图和头像（Blender 后台运行）
# 用法：Blender -b --factory-startup -P tools/ui_icons/render_lshu_views.py -- <out_dir>
import bpy, sys, math, os
from mathutils import Vector
argv = sys.argv[sys.argv.index("--") + 1:]
out = argv[0]
os.makedirs(out, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.abspath("assets/traveler/characters/action2/model/stylized_character.glb"))
meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
# 模型材质带 alpha 混合，Eevee 会把头发排到脸前面：统一改成不透明
for m in bpy.data.materials:
    if hasattr(m, "surface_render_method"):
        m.surface_render_method = 'DITHERED'
    if hasattr(m, "blend_method"):
        m.blend_method = 'OPAQUE'
    if m.use_nodes:
        for n in m.node_tree.nodes:
            if n.type == 'BSDF_PRINCIPLED':
                a = n.inputs.get("Alpha")
                if a is not None:
                    for l in list(a.links):
                        m.node_tree.links.remove(l)
                    a.default_value = 1.0
# 包围盒
mn = Vector((1e9, 1e9, 1e9)); mx = Vector((-1e9, -1e9, -1e9))
dg = bpy.context.evaluated_depsgraph_get()
for o in meshes:
    for c in o.bound_box:
        w = o.matrix_world @ Vector(c)
        mn = Vector((min(mn.x, w.x), min(mn.y, w.y), min(mn.z, w.z))); mx = Vector((max(mx.x, w.x), max(mx.y, w.y), max(mx.z, w.z)))
ctr = (mn + mx) / 2; size = mx - mn
print("BOUNDS", tuple(mn), tuple(mx))
sc = bpy.context.scene
sc.render.engine = 'BLENDER_EEVEE'
sc.render.resolution_x = 1024; sc.render.resolution_y = 1024
sc.render.film_transparent = False
sc.view_settings.view_transform = 'Standard'
world = bpy.data.worlds.new("W"); sc.world = world; world.use_nodes = True
bg = world.node_tree.nodes["Background"]; bg.inputs[0].default_value = (0.78, 0.8, 0.83, 1); bg.inputs[1].default_value = 0.9
def light(name, typ, rot, energy, size=None):
    L = bpy.data.lights.new(name, typ); L.energy = energy
    if size: L.size = size
    ob = bpy.data.objects.new(name, L); sc.collection.objects.link(ob); ob.rotation_euler = [math.radians(a) for a in rot]
    return ob
light("key", 'SUN', (50, 0, 35), 3.2); light("fill", 'SUN', (65, 0, -140), 1.1); light("rim", 'SUN', (110, 0, 180), 1.4)
cam_d = bpy.data.cameras.new("cam"); cam = bpy.data.objects.new("cam", cam_d); sc.collection.objects.link(cam); sc.camera = cam
cam_d.type = 'ORTHO'; cam_d.ortho_scale = max(size.x, size.z) * 1.15
# glTF 导入后前方是 -Y（Blender），正面相机放在 -Y 方向看向 +Y
views = {"front": (0, -1, 0), "right": (1, 0, 0), "back": (0, 1, 0), "left": (-1, 0, 0)}
for name, d in views.items():
    dv = Vector(d); cam.location = ctr + dv * (max(size) * 3)
    cam.rotation_euler = (ctr - cam.location).to_track_quat('-Z', 'Y').to_euler()
    sc.render.filepath = os.path.join(out, f"lshu_{name}.png"); bpy.ops.render.render(write_still=True)
# 头像：半身、略俯视 3/4
cam_d.type = 'PERSP'; cam_d.lens = 85
head = Vector((ctr.x, ctr.y, mn.z + size.z * 0.78))
cam.location = head + Vector((-0.55, -1.0, 0.25)).normalized() * size.z * 1.45
cam.rotation_euler = (head - cam.location).to_track_quat('-Z', 'Y').to_euler()
sc.render.film_transparent = True
sc.render.filepath = os.path.join(out, "lshu_avatar.png"); bpy.ops.render.render(write_still=True)
print("DONE")
