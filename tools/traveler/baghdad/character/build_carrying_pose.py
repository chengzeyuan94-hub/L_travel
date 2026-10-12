"""Bake the supplied Carrying FBX into a static, unit-height Godot pose.

Run in Blender Python, on a private scene containing the imported FBX.
The original rig and animation are preserved alongside the baked mesh.
"""
import bpy
import json
import shutil
from pathlib import Path
from mathutils import Matrix, Vector

ROOT = Path('/Users/chengzeyuan/Developer/SilkRoad')
scene = bpy.data.scenes['Baghdad_Carrying_20260923']
assert bpy.context.scene == scene, 'Select the independent Carrying scene first'
armature = next(obj for obj in scene.objects if obj.type == 'ARMATURE')
source = next(obj for obj in scene.objects if obj.type == 'MESH' and obj.name != 'LUncle_Carrying_Pose')
assert 'LUncle_Carrying_Pose' not in scene.objects, 'Pose already baked'
scene.frame_set(1)
bpy.context.view_layer.update()
depsgraph = bpy.context.evaluated_depsgraph_get()
evaluated = source.evaluated_get(depsgraph)
points = [source.matrix_world @ vertex.co for vertex in evaluated.data.vertices]
minimum = Vector(tuple(min(point[i] for point in points) for i in range(3)))
maximum = Vector(tuple(max(point[i] for point in points) for i in range(3)))
origin = Vector(((minimum.x + maximum.x) / 2, (minimum.y + maximum.y) / 2, minimum.z))
height = maximum.z - minimum.z
normalization = Matrix.Scale(1 / height, 4) @ Matrix.Translation(-origin)
mesh = bpy.data.meshes.new_from_object(evaluated, preserve_all_data_layers=True, depsgraph=depsgraph)
mesh.name = 'LUncle_Carrying_Frame1_Static'
mesh.transform(normalization @ source.matrix_world)
mesh.update()
pose = bpy.data.objects.new('LUncle_Carrying_Pose', mesh)
scene.collection.objects.link(pose)

def godot_point(world):
    point = normalization @ world
    return [point.x, point.z, -point.y]

names = ['LeftHand', 'RightHand', 'LeftHandMiddle1', 'RightHandMiddle1', 'LeftFoot', 'RightFoot']
world_bones = {name: armature.matrix_world @ armature.pose.bones['mixamorig:' + name].head for name in names}
for side in ('Left', 'Right'):
    world_bones[side + 'Palm'] = world_bones[side + 'Hand'].lerp(world_bones[side + 'HandMiddle1'], .65)
metadata = {
    'schema': 'silkroad.carrying-pose.v1',
    'source_file': 'art-src/baghdad-character/Carrying.fbx',
    'source_frame': 1,
    'source_action': armature.animation_data.action.name,
    'source_action_frame_range': list(armature.animation_data.action.frame_range),
    'coordinates': 'Godot: Y up, +Z forward, unit height, feet at y=0, X/Z bounds centered',
    'source_height': height,
    'source_bounds_min': list(minimum),
    'source_bounds_max': list(maximum),
    'bones': {name: godot_point(world) for name, world in world_bones.items()},
    'vertices': len(mesh.vertices),
    'materials': [material.name for material in mesh.materials],
}
asset_dir = ROOT / 'assets/traveler/baghdad/character'
source_dir = ROOT / 'art-src/baghdad-character'
asset_dir.mkdir(parents=True, exist_ok=True)
source_dir.mkdir(parents=True, exist_ok=True)
(asset_dir / 'carrying_landmarks.json').write_text(json.dumps(metadata, indent=2))
shutil.copy2('/Users/chengzeyuan/Desktop/Carrying.fbx', source_dir / 'Carrying.fbx')
source.hide_set(True)
source.hide_render = True
armature.hide_set(True)
armature.hide_render = True
for obj in scene.objects:
    obj.select_set(False)
pose.select_set(True)
bpy.context.view_layer.objects.active = pose
bpy.data.libraries.write(str(source_dir / 'carrying-pose.blend'), {scene}, fake_user=True, compress=True)
print(json.dumps(metadata))
