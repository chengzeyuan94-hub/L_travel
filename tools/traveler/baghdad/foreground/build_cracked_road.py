"""Lay the user-supplied cracked-stone FBX into a continuous Baghdad road.

Execute through Blender MCP. The imported source and all existing scenes remain
intact. Only this script's new scene is exported/saved. Coordinates are Blender
(X,Y,Z) == Baghdad stage (right,away,height); the game drapes each vertex.
"""
from __future__ import annotations

import importlib.util
import json
import math
import random
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


ROOT = Path('/Users/chengzeyuan/Developer/SilkRoad')
SOURCE_DIR = ROOT / 'art-src/baghdad-foreground/cracked-stone-source'
SOURCE_FBX = SOURCE_DIR / 'cracked+stone+block+3d+model.fbx'
SOURCE_IMAGE = SOURCE_DIR / 'cracked+stone+block+3d+model.fbm/cracked+stone+block+3d+model_basecolor.jpg'
SOURCE_SCENE_NAME = 'Baghdad_CrackedStone_Source_20260923'
SOURCE_OBJECT_NAME = 'tripo_node_802799d3-a633-4a5a-a019-aedbcea3dce9'
SCENE_NAME = 'Baghdad_CrackedRoad_20260923'
GLB_PATH = ROOT / 'assets/traveler/baghdad/foreground/cracked_road.glb'
BLEND_PATH = ROOT / 'art-src/baghdad-foreground/cracked_road.blend'
MANIFEST_PATH = ROOT / 'docs/reports/traveler-baghdad-001/storm-stone-20260923/road-manifest.json'
LEGACY_BUILDER = ROOT / 'tools/traveler/baghdad/foreground/build_foreground.py'

SEED = 9232026
Z_START, Z_END = 0.85, 6.80
LOD_TARGETS = {'near': 3000, 'mid': 1500, 'far': 800}
LOD_THRESHOLDS = (2.00, 4.45)
GRASS_CLUMP_COUNT = 46
GRAVEL_COUNT = 100
ROAD_FRAGMENT_COUNT = 16
MAX_TRIANGLES = 350000
UV_LAYER = 'SourceAtlasUV'
BOTTOM = -0.015
EXCLUSIONS = [(-0.47, 2.794, 0.15), (0.43, 3.50, 0.29)]


def load_legacy():
    spec = importlib.util.spec_from_file_location('baghdad_foreground_source_helpers', str(LEGACY_BUILDER))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def road_center(z):
    t = (z - Z_START) / (Z_END - Z_START)
    return -0.028 + 0.105 * math.sin(t * 4.5) - 0.038 * t


def half_width(z):
    return 1.20 - 0.30 * min(1.0, max(0.0, (z - Z_START) / (Z_END - Z_START)))


def outside_reserved(x, z, margin=0.0):
    return all(math.hypot(x - px, z - pz) > r + margin for px, pz, r in EXCLUSIONS)


def rect_circle_clear(stone):
    """Reserve clear circles against complete rotated blocks, not only centers."""
    ca, sa = math.cos(stone['angle']), math.sin(stone['angle'])
    for px, pz, radius in EXCLUSIONS:
        dx, dz = px - stone['x'], pz - stone['z']
        u, v = ca * dx + sa * dz, -sa * dx + ca * dz
        qx = max(abs(u) - stone['width'] * 0.47, 0.0)
        qz = max(abs(v) - stone['depth'] * 0.47, 0.0)
        if math.hypot(qx, qz) < radius:
            return False
    return True


def point_near_stone(x, z, stone, margin=0.0, footprint=0.47):
    ca, sa = math.cos(stone['angle']), math.sin(stone['angle'])
    dx, dz = x - stone['x'], z - stone['z']
    u, v = ca * dx + sa * dz, -sa * dx + ca * dz
    return abs(u) < stone['width'] * footprint + margin and abs(v) < stone['depth'] * footprint + margin


def sample_stone(x, z, width, depth, angle, rng, fragment=False):
    return {
        'x': x, 'z': z, 'width': width, 'depth': depth, 'angle': angle,
        'height': rng.uniform(0.014, 0.035) * (0.80 if fragment else 1.0),
        'tilt_x': rng.uniform(-0.0033, 0.0033),
        'tilt_z': rng.uniform(-0.0030, 0.0030),
        # Rotating the same scanned stone in quarter turns avoids identical crack
        # orientation while preserving its original corner UVs exactly.
        'quarter_turn': rng.randrange(4), 'fragment': fragment,
        'brightness': rng.uniform(0.85, 1.10),
        'warmth': rng.uniform(-0.025, 0.035),
    }


def make_road_layout(rng):
    """Short, staggered courses with varied lengths, broken margins and gaps."""
    stones = []
    row = 0
    z = Z_START + 0.15
    while z < Z_END - 0.10:
        t = (z - Z_START) / (Z_END - Z_START)
        nominal_depth = 0.345 - 0.088 * t
        columns = 5 if t < 0.30 and row % 3 == 0 else 6
        width = half_width(z) * 2.0
        pitch = width / columns
        offset = (-0.18 if row % 2 else 0.18) * pitch
        weights = [rng.uniform(0.86, 1.16) for _ in range(columns)]
        total = sum(weights)
        cursor = road_center(z) - width * 0.5 + offset
        for index, weight in enumerate(weights):
            cell = width * weight / total
            cx = cursor + cell * 0.5
            cursor += cell
            # Course edges are chipped and offset instead of a clean rectangle.
            sw = max(0.30, min(0.52, cell * rng.uniform(0.94, 1.025)))
            sd = max(0.25, min(0.40, nominal_depth * rng.uniform(0.92, 1.055)))
            sy = z + rng.uniform(-0.020, 0.020)
            angle = rng.uniform(-0.085, 0.085)
            if index in (0, columns - 1):
                angle += rng.uniform(-0.05, 0.05)
            stone = sample_stone(cx, sy, sw, sd, angle, rng)
            if not rect_circle_clear(stone):
                continue
            # Two modest, intentional losses expose sand and break the paving.
            if (row == 7 and index == 0) or (row == 15 and index == 4):
                continue
            stones.append(stone)
        z += nominal_depth * 0.86 + 0.027
        row += 1

    # Narrow source-derived pieces live at broken margins and in the clearances'
    # outer rims. They read as old repairs and split slabs, never a brick pile.
    fragments = []
    attempts = 0
    while len(fragments) < ROAD_FRAGMENT_COUNT and attempts < 10000:
        attempts += 1
        z = rng.uniform(1.08, 6.55)
        side = rng.choice((-1, 1))
        x = road_center(z) + side * (half_width(z) + rng.uniform(-0.025, 0.090))
        sw, sd = rng.uniform(0.105, 0.205), rng.uniform(0.15, 0.27)
        stone = sample_stone(x, z, sw, sd, rng.uniform(-0.60, 0.60), rng, fragment=True)
        if not rect_circle_clear(stone):
            continue
        if any(point_near_stone(x, z, old, margin=min(sw, sd) * 0.28, footprint=0.43)
               for old in stones + fragments):
            continue
        fragments.append(stone)
    stones.extend(fragments)
    stones.sort(key=lambda s: s['z'])
    if not 115 <= len(stones) <= 155:
        raise RuntimeError(f'Road layout has {len(stones)} slabs/fragments, expected 115..155')
    return stones, row


def find_source():
    scene = bpy.data.scenes.get(SOURCE_SCENE_NAME)
    if scene is not None:
        obj = scene.objects.get(SOURCE_OBJECT_NAME)
        if obj is not None and obj.type == 'MESH':
            return obj
    obj = bpy.data.objects.get(SOURCE_OBJECT_NAME)
    if obj is not None and obj.type == 'MESH':
        return obj
    # The independent source .blend keeps an untouched full-resolution copy,
    # so reopening it is sufficient for a later rebuild without reimporting FBX.
    copies = [obj for obj in bpy.data.objects if obj.type == 'MESH' and obj.get('cracked_road_full_source')]
    if copies:
        return copies[0]
    raise RuntimeError('Import the supplied FBX into ' + SOURCE_SCENE_NAME + ' before running this builder')


def make_stone_material(legacy, source):
    material = bpy.data.materials.new('Baghdad_CrackedRoad_SourceAtlas')
    material.use_nodes = True
    material.use_backface_culling = True
    material.diffuse_color = (0.74, 0.69, 0.59, 1.0)
    nodes, links = material.node_tree.nodes, material.node_tree.links
    bsdf = next(node for node in nodes if node.type == 'BSDF_PRINCIPLED')
    bsdf.inputs['Metallic'].default_value = 0.0
    bsdf.inputs['Roughness'].default_value = 0.80
    bsdf.inputs['Specular IOR Level'].default_value = 0.25
    if SOURCE_IMAGE.is_file():
        image = bpy.data.images.load(str(SOURCE_IMAGE), check_existing=False)
    else:
        source_images = [node.image for mat in source.data.materials if mat and mat.use_nodes
                         for node in mat.node_tree.nodes if node.type == 'TEX_IMAGE' and node.image]
        if not source_images:
            raise RuntimeError('Source atlas is missing and no packed source image is available')
        image = source_images[0].copy()
    image.colorspace_settings.name = legacy.enum_value(image.colorspace_settings.bl_rna, 'name', 'sRGB')
    image.pack()
    uv = nodes.new('ShaderNodeUVMap')
    uv.uv_map = UV_LAYER
    texture = nodes.new('ShaderNodeTexImage')
    texture.image = image
    texture.label = 'Original supplied cracked-stone atlas; original UVs'
    texture.extension = legacy.enum_value(texture.bl_rna, 'extension', 'REPEAT')
    texture.interpolation = legacy.enum_value(texture.bl_rna, 'interpolation', 'Linear')
    colors = nodes.new('ShaderNodeVertexColor')
    colors.layer_name = 'Color'
    multiplication = nodes.new('ShaderNodeMixRGB')
    multiplication.blend_type = legacy.enum_value(multiplication.bl_rna, 'blend_type', 'MULTIPLY')
    multiplication.inputs['Fac'].default_value = 1.0
    links.new(uv.outputs['UV'], texture.inputs['Vector'])
    links.new(texture.outputs['Color'], multiplication.inputs['Color1'])
    links.new(colors.outputs['Color'], multiplication.inputs['Color2'])
    links.new(multiplication.outputs['Color'], bsdf.inputs['Base Color'])
    material['source_atlas'] = str(SOURCE_IMAGE)
    material['normal_map'] = 'None: original atlas UVs are not compatible with a generic tile normal map'
    return material, image


def copy_full_source(source, collection, material):
    mesh = source.data.copy()
    mesh.name = 'CrackedRoad_FullSource_Geometry'
    mesh.transform(source.matrix_world)
    mesh.update()
    if len(mesh.uv_layers) == 0:
        raise RuntimeError('Supplied stone has no source UV layer')
    mesh.uv_layers.active.name = UV_LAYER
    mesh.materials.clear()
    mesh.materials.append(material)
    obj = bpy.data.objects.new('CrackedRoad_FullSource', mesh)
    collection.objects.link(obj)
    obj['cracked_road_full_source'] = True
    obj['source_fbx'] = str(SOURCE_FBX)
    obj.hide_render = True
    obj.hide_set(True)
    bounds = [[min(vertex.co[axis] for vertex in mesh.vertices),
               max(vertex.co[axis] for vertex in mesh.vertices)] for axis in range(3)]
    mesh.calc_loop_triangles()
    return obj, bounds, len(mesh.loop_triangles)


def snapshot_lod(full_source, collection, target, label, legacy):
    """Decimate only a private copy. Existing source mesh/UVs stay untouched."""
    working = bpy.data.objects.new('CrackedRoad_Source_' + label, full_source.data.copy())
    collection.objects.link(working)
    working.data.calc_loop_triangles()
    source_count = len(working.data.loop_triangles)
    factory = working.modifiers.bl_rna.functions['new']
    modifier = working.modifiers.new('Private source reduction',
                                     type=legacy.parameter_enum(factory, 'type', 'DECIMATE'))
    modifier.decimate_type = legacy.enum_value(modifier.bl_rna, 'decimate_type', 'COLLAPSE')
    modifier.ratio = min(1.0, target / max(1, source_count))
    modifier.use_collapse_triangulate = True
    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = working.evaluated_get(depsgraph)
    result = bpy.data.meshes.new_from_object(evaluated, preserve_all_data_layers=True, depsgraph=depsgraph)
    result.name = 'CrackedRoad_LOD_' + label
    working.modifiers.clear()
    working.data = result
    working.hide_render = True
    working.hide_set(True)
    working['triangle_target'] = target
    if not result.uv_layers:
        raise RuntimeError('Decimation lost source UVs for ' + label)
    result.uv_layers.active.name = UV_LAYER
    result.calc_loop_triangles()
    uv = result.uv_layers.active.data
    triangles = []
    for tri in result.loop_triangles:
        triangles.append({
            'vertices': tuple(tri.vertices),
            'uvs': [tuple(uv[index].uv) for index in tri.loops],
            'smooth': bool(result.polygons[tri.polygon_index].use_smooth),
        })
    return {'vertices': [tuple(v.co) for v in result.vertices], 'triangles': triangles,
            'count': len(triangles), 'object': working.name, 'mesh': result.name,
            'target': target}


class RoadBatch:
    def __init__(self, name):
        self.name = name
        self.vertices, self.faces, self.uvs, self.colors, self.smooth = [], [], [], [], []
        self.pieces = 0
        self.lod_counts = {key: 0 for key in LOD_TARGETS}

    def add(self, lod, bounds, stone, lod_name):
        xmid = (bounds[0][0] + bounds[0][1]) * 0.5
        zmid = (bounds[2][0] + bounds[2][1]) * 0.5
        xspan = bounds[0][1] - bounds[0][0]
        yspan = bounds[1][1] - bounds[1][0]
        zspan = bounds[2][1] - bounds[2][0]
        start = len(self.vertices)
        angle = stone['angle']
        ca, sa = math.cos(angle), math.sin(angle)
        qt = stone['quarter_turn']
        for sx, sy, sz in lod['vertices']:
            # Original -Y face becomes +Z surface; original +Z becomes road +Y.
            u, v = (sx - xmid) / xspan, (sz - zmid) / zspan
            if qt == 1:
                u, v = -v, u
            elif qt == 2:
                u, v = -u, -v
            elif qt == 3:
                u, v = v, -u
            normalized_h = (bounds[1][1] - sy) / yspan
            px, py = u * stone['width'], v * stone['depth']
            h = BOTTOM + normalized_h * (stone['height'] - BOTTOM)
            h += stone['tilt_x'] * u + stone['tilt_z'] * v
            self.vertices.append((stone['x'] + ca * px - sa * py,
                                  stone['z'] + sa * px + ca * py, h))
        # glTF COLOR_0 is a linear multiplier in [0,1]. The requested brightness
        # range is measured around a 0.90 neutral level, leaving room to brighten.
        brightness = 0.90 * stone['brightness']
        warmth = stone['warmth']
        color = (min(1.0, brightness * (1.0 + warmth)),
                 min(1.0, brightness * (1.0 + warmth * 0.25)),
                 min(1.0, brightness * (1.0 - warmth)), 1.0)
        for tri in lod['triangles']:
            self.faces.append(tuple(start + i for i in tri['vertices']))
            self.uvs.extend(tri['uvs'])
            self.colors.extend((color, color, color))
            self.smooth.append(tri['smooth'])
        self.pieces += 1
        self.lod_counts[lod_name] += 1

    def create(self, collection, material, legacy):
        mesh = bpy.data.meshes.new(self.name + '_CrackedSourceGeometry')
        mesh.from_pydata(self.vertices, [], self.faces)
        mesh.update()
        uv = mesh.uv_layers.new(name=UV_LAYER)
        uv.active_render = True
        uv.data.foreach_set('uv', [value for pair in self.uvs for value in pair])
        factory = mesh.color_attributes.bl_rna.functions['new']
        color = mesh.color_attributes.new(name='Color',
                type=legacy.parameter_enum(factory, 'type', 'FLOAT_COLOR'),
                domain=legacy.parameter_enum(factory, 'domain', 'CORNER'))
        color.data.foreach_set('color', [value for rgba in self.colors for value in rgba])
        mesh.color_attributes.active_color_index = 0
        mesh.color_attributes.render_color_index = 0
        for polygon, smooth in zip(mesh.polygons, self.smooth):
            polygon.use_smooth = smooth
        mesh.materials.append(material)
        obj = bpy.data.objects.new(self.name, mesh)
        collection.objects.link(obj)
        obj['baghdad_foreground'] = True
        obj['foreground_role'] = self.name
        obj['source_geometry'] = str(SOURCE_FBX)
        obj['stage_axis_mapping'] = 'Blender X=stage X; Blender Y=stage Z; Blender Z=height'
        obj['generated_pieces'] = self.pieces
        return obj


def grass_layout(stones, rng):
    anchors = [(-0.60, 1.28), (0.62, 1.34), (-1.06, 2.00), (1.06, 2.03),
               (-1.27, 2.55), (1.28, 2.64), (-1.34, 3.14), (1.21, 3.53)]
    locations = []
    for x, z in anchors:
        if outside_reserved(x, z, 0.04):
            locations.append((x, z, rng.uniform(0.065, 0.12)))
    attempts = 0
    while len(locations) < GRASS_CLUMP_COUNT and attempts < 20000:
        attempts += 1
        z = rng.uniform(1.05, 6.65)
        if len(locations) < 32:
            x = road_center(z) + rng.choice((-1, 1)) * (half_width(z) + rng.uniform(-0.04, 0.24))
        else:
            # Small seam tufts sit between stones, not through their top faces.
            x = road_center(z) + rng.uniform(-0.88, 0.88) * half_width(z)
        if not outside_reserved(x, z, 0.055):
            continue
        if any(math.hypot(x - ox, z - oz) < 0.195 for ox, oz, _ in locations):
            continue
        if any(point_near_stone(x, z, stone, footprint=0.425) for stone in stones):
            continue
        height = rng.uniform(0.058, 0.135) * (0.66 if abs(x - road_center(z)) < 0.72 else 1.0)
        locations.append((x, z, height))
    if len(locations) != GRASS_CLUMP_COUNT:
        raise RuntimeError('Not enough gaps for grass tufts')
    return locations


def gravel_layout(stones, rng):
    gravel = []
    attempts = 0
    while len(gravel) < GRAVEL_COUNT and attempts < 20000:
        attempts += 1
        if len(gravel) < 18:
            # A small halo of chips edges the clear standing/fire patches.
            px, pz, radius = EXCLUSIONS[len(gravel) % len(EXCLUSIONS)]
            a = rng.uniform(0.0, math.tau)
            r = radius + rng.uniform(0.045, 0.135)
            x, z = px + math.cos(a) * r, pz + math.sin(a) * r
        else:
            z = rng.uniform(0.98, 6.75)
            x = road_center(z) + rng.uniform(-1.0, 1.0) * (half_width(z) + 0.24)
        sw = rng.uniform(0.025, 0.070)
        sd = sw * rng.uniform(0.52, 1.24)
        if not outside_reserved(x, z, max(sw, sd) * 0.6):
            continue
        if any(point_near_stone(x, z, stone, margin=min(sw, sd) * 0.15, footprint=0.43) for stone in stones):
            continue
        if any(math.hypot(x - old['x'], z - old['z']) < 0.065 for old in gravel):
            continue
        grain = sample_stone(x, z, sw, sd, rng.uniform(-math.pi, math.pi), rng, fragment=True)
        grain['height'] = rng.uniform(0.004, 0.018)
        grain['tilt_x'] *= 0.3
        grain['tilt_z'] *= 0.3
        gravel.append(grain)
    if len(gravel) != GRAVEL_COUNT:
        raise RuntimeError('Not enough ground gaps for fine gravel')
    return gravel


def export_glb(scene, objects, legacy):
    rna = bpy.ops.export_scene.gltf.get_rna_type()
    properties = rna.properties
    kwargs = {'filepath': str(GLB_PATH),
              'export_format': legacy.enum_value(rna, 'export_format', 'GLB'),
              'export_materials': legacy.enum_value(rna, 'export_materials', 'EXPORT'),
              'export_vertex_color': legacy.enum_value(rna, 'export_vertex_color', 'ACTIVE')}
    for name in ('use_selection', 'export_yup', 'export_texcoords', 'export_normals', 'export_tangents'):
        if name not in properties or properties[name].type != 'BOOLEAN':
            raise RuntimeError('Exporter missing required boolean ' + name)
        kwargs[name] = True
    optional = {'use_active_scene': True, 'export_cameras': False, 'export_lights': False,
                'export_animations': False, 'export_extras': True, 'export_apply': True,
                'export_all_vertex_colors': False,
                'export_active_vertex_color_when_no_material': True}
    for name, value in optional.items():
        if name in properties and properties[name].type == 'BOOLEAN':
            kwargs[name] = value
    layer = scene.view_layers[0]
    for obj in scene.objects:
        obj.select_set(False, view_layer=layer)
    for obj in objects:
        obj.select_set(True, view_layer=layer)
    layer.objects.active = objects[0]
    override = dict(scene=scene, view_layer=layer, object=objects[0], active_object=objects[0],
                    selected_objects=objects, selected_editable_objects=objects)
    if bpy.context.window:
        override['window'] = bpy.context.window
    with bpy.context.temp_override(**override):
        result = bpy.ops.export_scene.gltf(**kwargs)
    if 'FINISHED' not in result or not GLB_PATH.is_file():
        raise RuntimeError('Cracked road export failed: ' + repr(result))
    return kwargs


def rectangle_coverage_estimate(stones):
    """Review metric only: estimates footprints, not photometric visible area."""
    step = 0.025
    occupied = 0
    total = 0
    z = Z_START + step * 0.5
    while z < Z_END:
        x = road_center(z) - half_width(z) + step * 0.5
        while x < road_center(z) + half_width(z):
            total += 1
            if any(point_near_stone(x, z, stone, footprint=0.45) for stone in stones):
                occupied += 1
            x += step
        z += step
    return occupied / max(1, total)


def main():
    legacy = load_legacy()
    source = find_source()
    source_name, source_scene = source.name, [s.name for s in bpy.data.scenes if source.name in s.objects]
    previous_scene = bpy.context.scene.name
    rng = random.Random(SEED)
    stones, row_count = make_road_layout(rng)
    grass = grass_layout(stones, rng)
    gravel = gravel_layout(stones, rng)
    coverage = rectangle_coverage_estimate(stones)

    scene = bpy.data.scenes.new(SCENE_NAME)
    collection = bpy.data.collections.new('Baghdad_CrackedRoad_Asset')
    sources = bpy.data.collections.new('Baghdad_CrackedRoad_PrivateSources')
    rig = bpy.data.collections.new('Baghdad_CrackedRoad_ReviewRig')
    for item in (collection, sources, rig):
        scene.collection.children.link(item)
    if bpy.context.window:
        bpy.context.window.scene = scene
    material, image = make_stone_material(legacy, source)
    full, bounds, source_triangles = copy_full_source(source, sources, material)
    lods = {name: snapshot_lod(full, sources, target, name, legacy)
            for name, target in LOD_TARGETS.items()}

    paving, grains = RoadBatch('StonePaving'), RoadBatch('FineGravel')
    for stone in stones:
        lod_name = 'near' if stone['z'] < LOD_THRESHOLDS[0] else ('mid' if stone['z'] < LOD_THRESHOLDS[1] else 'far')
        if stone['fragment']:
            lod_name = 'far'
        paving.add(lods[lod_name], bounds, stone, lod_name)
    for grain in gravel:
        grains.add(lods['far'], bounds, grain, 'far')
    grass_batch = legacy.MeshBatch('DryGrass')
    blades = sum(legacy.make_grass_clump(grass_batch, x, z, h, rng) for x, z, h in grass)
    triangles = len(paving.faces) + len(grains.faces) + len(grass_batch.faces)
    if triangles >= MAX_TRIANGLES:
        raise RuntimeError(f'Triangle budget exceeded: {triangles} >= {MAX_TRIANGLES}')
    grass_material = legacy.make_material('Baghdad_CrackedRoad_DryGrass', 0.98, double_sided=True)
    objects = [paving.create(collection, material, legacy), grains.create(collection, material, legacy),
               grass_batch.create(collection, grass_material)]
    legacy.create_preview_rig(scene, rig)
    for path in (GLB_PATH, BLEND_PATH, MANIFEST_PATH):
        path.parent.mkdir(parents=True, exist_ok=True)
    export_options = export_glb(scene, objects, legacy)
    bpy.data.libraries.write(str(BLEND_PATH), {scene}, fake_user=True, compress=True)

    manifest = {
        'asset': 'Baghdad continuous road made from supplied cracked stone block',
        'version': '2026-09-23', 'seed': SEED, 'scene': scene.name,
        'source_fbx': str(SOURCE_FBX.relative_to(ROOT)), 'source_object': source_name,
        'source_scenes_preserved': source_scene, 'previous_scene_preserved': previous_scene,
        'source_triangles': source_triangles, 'source_world_bounds_xyz': bounds,
        'source_atlas': str(SOURCE_IMAGE.relative_to(ROOT)), 'source_atlas_dimensions': list(image.size),
        'atlas_packed': bool(image.packed_file),
        'source_mapping': 'Stage (right,away,height) = (sourceworld X, sourceworld Z, -sourceworld Y), normalized per instance',
        'glb': str(GLB_PATH.relative_to(ROOT)), 'blend': str(BLEND_PATH.relative_to(ROOT)),
        'builder': 'tools/traveler/baghdad/foreground/build_cracked_road.py',
        'integration': 'Keep stage coordinates; imported Godot (stageX,height,-stageZ); drape every vertex; rotate root PI around Y',
        'material': {'base_color': 'Original supplied sRGB atlas multiplied by per-stone linear Color',
                     'roughness': 0.80, 'specular_ior_level': 0.25,
                     'normal_map': None, 'uv': 'Original source atlas UVs, retained through decimation',
                     'vertex_color_export': 'ACTIVE', 'brightness_variation': [0.85, 1.10],
                     'brightness_neutral_multiplier': 0.90},
        'lods': {name: {key: value for key, value in data.items() if key not in ('vertices', 'triangles')}
                 for name, data in lods.items()},
        'counts': {'paving_blocks_and_fragments': len(stones), 'road_fragments': sum(s['fragment'] for s in stones),
                   'courses': row_count, 'grass_clumps': len(grass), 'grass_blades': blades,
                   'fine_gravel': len(gravel), 'triangles': triangles, 'meshes': 3, 'materials': 2},
        'coverage_estimate': {'fraction': coverage, 'method': '0.025-unit grid over road envelope; 90% inset bounding rectangles',
                              'limitation': 'Approximate planning metric; source chipped silhouettes and true cracks remain visible'},
        'mesh_roles': [{'name': obj.name, 'role': role, 'triangles': count}
                       for obj, role, count in zip(objects, ('StonePaving', 'FineGravel', 'DryGrass'),
                                                  (len(paving.faces), len(grains.faces), len(grass_batch.faces)))],
        'paving_lod_distribution': paving.lod_counts,
        'exclusions': [{'stage_x': x, 'stage_z': z, 'radius': r} for x, z, r in EXCLUSIONS],
        'stone_instances': stones, 'grass_instances': [{'x': x, 'z': z, 'height': h} for x, z, h in grass],
        'export_options': export_options,
        'notes': ['Source object, mesh, material and scenes were not modified.',
                  'The source blend includes a private full-resolution source and three reduced source variants.',
                  'Only three combined game meshes are exported; sources and review rig are excluded.',
                  'Real source cracks, original UV atlas, varied rotation/size, shallow burial and seam tufts create the road detail.',
                  'No generic tile normal map is attached to the source atlas.'],
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    result = {'scene': scene.name, 'glb': str(GLB_PATH), 'blend': str(BLEND_PATH),
              'manifest': str(MANIFEST_PATH), 'coverage_estimate': coverage, **manifest['counts']}
    print('BAGHDAD_CRACKED_ROAD_RESULT ' + json.dumps(result, ensure_ascii=False))
    return result


if __name__ == '__main__':
    BAGHDAD_CRACKED_ROAD_RESULT = main()
