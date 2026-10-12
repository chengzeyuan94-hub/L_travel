# 在正在运行的 Blender 里搭图标摄影棚：一个新场景 LshuIconStudio，统一灯光与相机。
import bpy, math
from mathutils import Vector
sc = bpy.data.scenes.get("LshuIconStudio") or bpy.data.scenes.new("LshuIconStudio")
bpy.context.window.scene = sc
sc.render.engine = 'BLENDER_EEVEE'
sc.render.resolution_x = 1024; sc.render.resolution_y = 1024
sc.view_settings.view_transform = 'Standard'
sc.view_settings.look = 'None'
w = bpy.data.worlds.get("LshuIconWorld") or bpy.data.worlds.new("LshuIconWorld")
sc.world = w; w.use_nodes = True
bg = w.node_tree.nodes["Background"]; bg.inputs[0].default_value = (0.95, 0.9, 0.82, 1); bg.inputs[1].default_value = 0.32
def ensure_light(name, typ, rot, energy, color=(1, 1, 1), size=1.0):
    ob = bpy.data.objects.get(name)
    if ob is None:
        L = bpy.data.lights.new(name, typ); ob = bpy.data.objects.new(name, L); sc.collection.objects.link(ob)
    ob.data.energy = energy; ob.data.color = color
    if typ == 'SUN': ob.data.angle = math.radians(size)
    ob.rotation_euler = [math.radians(a) for a in rot]
    return ob
ensure_light("icon_key", 'SUN', (45, 0, -35), 3.4, (1.0, 0.95, 0.86), 6)
ensure_light("icon_fill", 'SUN', (70, 0, 145), 0.55, (0.82, 0.88, 1.0), 20)
ensure_light("icon_rim", 'SUN', (112, 0, 205), 1.3, (1.0, 0.9, 0.75), 6)
def ensure_cam(name, ortho):
    ob = bpy.data.objects.get(name)
    if ob is None:
        cd = bpy.data.cameras.new(name); ob = bpy.data.objects.new(name, cd); sc.collection.objects.link(ob)
    ob.data.type = 'ORTHO' if ortho else 'PERSP'
    return ob
ensure_cam("icon_cam", False); ensure_cam("ortho_cam", True)
# 把图标集合挂进这个场景
root = bpy.data.collections.get("LshuIcons") or bpy.data.collections.new("LshuIcons")
if root.name not in [c.name for c in sc.collection.children]:
    sc.collection.children.link(root)
print("studio ready", sc.name)
