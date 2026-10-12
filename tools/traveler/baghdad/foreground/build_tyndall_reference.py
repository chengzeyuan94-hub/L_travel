"""Build the video reference's editable Blender scattering study.

Run in Blender through MCP, or with Blender --python this_file.py. Existing
scenes and data are retained. Only the new scene and its dependencies are
written to the standalone .blend using bpy.data.libraries.write.
"""
from pathlib import Path
import json
import math

import bpy
from mathutils import Matrix, Vector


ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "assets/traveler/baghdad/low-poly+tree+3d+model.fbx"
OUTPUT = ROOT / "art-src/baghdad-foreground/tyndall_reference_study.blend"
REPORT = ROOT / "docs/reports/traveler-baghdad-001/tyndall-reference-20260923"


def bounds(objects):
    points = [obj.matrix_world @ Vector(corner) for obj in objects
              if obj.type == "MESH" for corner in obj.bound_box]
    return (Vector(tuple(min(p[i] for p in points) for i in range(3))),
            Vector(tuple(max(p[i] for p in points) for i in range(3))))


def enum_value(owner, name, wanted):
    values = [item.identifier for item in owner.bl_rna.properties[name].enum_items]
    if wanted not in values:
        raise ValueError(f"{name}: {wanted} unavailable; valid: {values}")
    return wanted


def look_at(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def add_mesh(scene, name, vertices, faces):
    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(obj)
    return obj


def build():
    original_scene = bpy.context.scene
    old_scenes = {s.name: len(s.objects) for s in bpy.data.scenes}
    old_objects = set(bpy.data.objects)
    old_images = set(bpy.data.images)
    scene = bpy.data.scenes.new("Baghdad_TyndallReference_20260923")
    bpy.context.window.scene = scene
    try:
        scene.render.engine = "BLENDER_EEVEE"
    except TypeError:
        scene.render.engine = original_scene.render.engine
    # Preserve the already validated scene's color-management enums.
    scene.view_settings.view_transform = original_scene.view_settings.view_transform
    scene.view_settings.look = original_scene.view_settings.look
    scene.view_settings.exposure = 0.6
    scene.render.resolution_x = 1440
    scene.render.resolution_y = 1080
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = enum_value(scene.render.image_settings, "file_format", "PNG")

    bpy.ops.import_scene.fbx(filepath=str(SOURCE), use_anim=False,
                             mtl_name_collision_mode="MAKE_UNIQUE")
    imported = [obj for obj in scene.objects if obj not in old_objects]
    meshes = [obj for obj in imported if obj.type == "MESH"]
    bpy.context.view_layer.update()
    low, high = bounds(meshes)
    factor = 7.65 / max(high.z - low.z, 0.001)
    center = Vector(((low.x + high.x) * 0.5, (low.y + high.y) * 0.5, low.z))
    normalize = Matrix.Diagonal((factor, factor, factor, 1.0)) @ Matrix.Translation(-center)
    # Only imported roots receive normalization; their children inherit it.
    for obj in imported:
        if obj.parent not in imported:
            obj.matrix_world = normalize @ obj.matrix_world
    bpy.context.view_layer.update()
    low, high = bounds(meshes)
    tree_width, tree_depth = high.x - low.x, high.y - low.y
    for obj in imported:
        obj["source_asset"] = str(SOURCE.relative_to(ROOT))
        obj["source_materials_unchanged"] = True
    for image in set(bpy.data.images) - old_images:
        if image.has_data and image.packed_file is None:
            image.pack()

    world = bpy.data.worlds.new("TyndallReference_DarkBlueWorld")
    world.use_nodes = True
    background = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    background.inputs["Color"].default_value = (0.075, 0.095, 0.13, 1.0)
    background.inputs["Strength"].default_value = 0.18
    scene.world = world

    ground = add_mesh(scene, "TyndallReference_Ground",
                      [(-20, -20, -0.04), (20, -20, -0.04),
                       (20, 20, -0.04), (-20, 20, -0.04)], [(0, 1, 2, 3)])
    ground_mat = bpy.data.materials.new("TyndallReference_GroundMaterial")
    ground_mat.use_nodes = True
    bsdf = next(n for n in ground_mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = (0.18, 0.19, 0.19, 1)
    bsdf.inputs["Roughness"].default_value = 0.91
    ground.data.materials.append(ground_mat)

    volume = add_mesh(scene, "TyndallReference_VolumeBox_Density003",
                      [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                       (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)],
                      [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4),
                       (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)])
    volume.location = (-1.0, 0.0, 7.95)
    volume.scale = (10.0, max(7.0, tree_depth), 8.0)
    volume.display_type = enum_value(volume, "display_type", "WIRE")
    material = bpy.data.materials.new("TyndallReference_VolumeScatter_003")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    nodes.clear()
    scatter = nodes.new("ShaderNodeVolumeScatter")
    scatter.location = (-300, 60)
    scatter.label = "Video reference: Density 0.03 / Anisotropy 0"
    scatter.inputs["Color"].default_value = (1.0, 1.0, 1.0, 1.0)
    scatter.inputs["Density"].default_value = 0.03
    scatter.inputs["Anisotropy"].default_value = 0.0
    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (100, 60)
    material.node_tree.links.new(scatter.outputs["Volume"], output.inputs["Volume"])
    volume.data.materials.append(material)
    volume["reference"] = "Volume Scatter -> Material Output.Volume; Surface unconnected"

    light_data = bpy.data.lights.new("TyndallReference_CloudbreakSpot", type="SPOT")
    light = bpy.data.objects.new("TyndallReference_CloudbreakSpot", light_data)
    scene.collection.objects.link(light)
    light.location = (-7.0, -4.5, 13.5)
    target = Vector((-tree_width * 0.21, -tree_depth * 0.10, 5.1))
    look_at(light, target)
    light_data.energy = 6500.0
    light_data.color = (1.0, 0.91, 0.74)
    light_data.spot_size = 2.0 * math.atan((tree_width * 0.31) / (light.location - target).length)
    light_data.spot_blend = 0.26
    light_data.shadow_soft_size = 0.12
    light_data.use_shadow = True
    light["coverage_target"] = "Approximately left half of the tree crown"

    camera_data = bpy.data.cameras.new("TyndallReference_Camera")
    camera = bpy.data.objects.new("TyndallReference_Camera", camera_data)
    scene.collection.objects.link(camera)
    camera.location = (0.0, -21.0, 6.5)
    look_at(camera, (-0.7, 0.0, 5.2))
    camera_data.lens = 41.0
    scene.camera = camera

    notes = bpy.data.texts.new("TyndallReference_Readme")
    notes.write("Editable reference study of the supplied Blender tutorial.\n"
                "Exact reference shader: white Volume Scatter; density 0.03; anisotropy 0.\n"
                "Volume output connected to Material Output.Volume; Surface unconnected.\n"
                "One spotlight; original imported tree materials preserved.\n"
                "Lighting position, energy and cone angle are scene-specific artistic settings.\n")
    scene["reference_readme"] = notes.name
    scene["source_materials_unchanged"] = True
    scene["reference_density"] = 0.03
    scene["reference_anisotropy"] = 0.0

    for obj in bpy.context.selected_objects:
        obj.select_set(False)
    volume.select_set(True)
    bpy.context.view_layer.objects.active = volume
    for screen in [bpy.context.window.screen]:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                space = area.spaces.active
                space.region_3d.view_perspective = enum_value(space.region_3d, "view_perspective", "CAMERA")
                space.shading.type = enum_value(space.shading, "type", "RENDERED")
                space.overlay.show_overlays = False

    assert not output.inputs["Surface"].is_linked
    assert output.inputs["Volume"].is_linked
    assert len([o for o in scene.objects if o.type == "LIGHT"]) == 1
    assert all(len(bpy.data.scenes[name].objects) == count for name, count in old_scenes.items())
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.mkdir(parents=True, exist_ok=True)
    result = {"scene": scene.name, "output": str(OUTPUT),
              "volume_density": float(scatter.inputs["Density"].default_value),
              "volume_anisotropy": float(scatter.inputs["Anisotropy"].default_value),
              "surface_unconnected": not output.inputs["Surface"].is_linked,
              "spot_angle_degrees": math.degrees(light_data.spot_size),
              "spot_energy_watts": light_data.energy,
              "tree_bounds": [list(low), list(high)],
              "imported_meshes": len(meshes), "preserved_scenes": old_scenes}
    scene["build_evidence"] = json.dumps(result, ensure_ascii=False)
    # Library write is deliberately isolated: no existing scene is saved or changed.
    bpy.data.libraries.write(str(OUTPUT), {scene, notes}, fake_user=True, compress=True)
    print(json.dumps(result, ensure_ascii=False))
    return result


if __name__ == "__main__":
    build()
