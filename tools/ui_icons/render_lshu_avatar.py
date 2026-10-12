# L叔 头像：用站立待机动画的一帧（手臂自然下垂），半身三分之四、透明底。
# 用法：Blender -b --factory-startup -P tools/ui_icons/render_lshu_avatar.py -- <out.png> [frame]
import bpy, sys, math, os
from mathutils import Vector
argv = sys.argv[sys.argv.index("--") + 1:]
out = argv[0]; frame = int(argv[1]) if len(argv) > 1 else 12
bust = len(argv) > 2 and argv[2] == 'bust'
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.abspath("assets/traveler/characters/action2/animations/idle.glb"))
sc = bpy.context.scene; sc.frame_set(frame)
for m in bpy.data.materials:
    if hasattr(m, "surface_render_method"): m.surface_render_method = 'DITHERED'
    if m.use_nodes:
        for n in m.node_tree.nodes:
            if n.type == 'BSDF_PRINCIPLED':
                a = n.inputs.get("Alpha")
                if a is not None:
                    for l in list(a.links): m.node_tree.links.remove(l)
                    a.default_value = 1.0
dg = bpy.context.evaluated_depsgraph_get()
mn = Vector((1e9,) * 3); mx = Vector((-1e9,) * 3)
for o in sc.objects:
    if o.type != 'MESH': continue
    ev = o.evaluated_get(dg); me = ev.to_mesh()
    for v in me.vertices:
        w = ev.matrix_world @ v.co; mn = Vector(map(min, mn, w)); mx = Vector(map(max, mx, w))
    ev.to_mesh_clear()
size = mx - mn
sc.render.engine = 'BLENDER_EEVEE'; sc.render.resolution_x = 1024; sc.render.resolution_y = 1024
sc.render.film_transparent = True; sc.view_settings.view_transform = 'Standard'
w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.95, 0.9, 0.82, 1); w.node_tree.nodes["Background"].inputs[1].default_value = 0.45
for name, rot, e in (("key", (45, 0, -35), 3.0), ("fill", (70, 0, 145), 0.7), ("rim", (112, 0, 205), 1.4)):
    L = bpy.data.lights.new(name, 'SUN'); L.energy = e; ob = bpy.data.objects.new(name, L); sc.collection.objects.link(ob); ob.rotation_euler = [math.radians(a) for a in rot]
cd = bpy.data.cameras.new("cam"); cam = bpy.data.objects.new("cam", cd); sc.collection.objects.link(cam); sc.camera = cam
cd.lens = 85
head = Vector(((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z + size.z * (0.84 if bust else 0.5)))
d = Vector((-0.45, -1.0, 0.12)).normalized()
cam.location = head + d * size.z * (0.9 if bust else 2.2)
cam.rotation_euler = (head - cam.location).to_track_quat('-Z', 'Y').to_euler()
F = bpy.data.lights.new("front", 'SUN'); F.energy = 1.1; fo = bpy.data.objects.new("front", F); sc.collection.objects.link(fo)
fo.rotation_euler = (head - cam.location).to_track_quat('-Z', 'Y').to_euler()
sc.render.filepath = os.path.abspath(out); bpy.ops.render.render(write_still=True)
print("AVATAR", out, tuple(round(x, 3) for x in size))
