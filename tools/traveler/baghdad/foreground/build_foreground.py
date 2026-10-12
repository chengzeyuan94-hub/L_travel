"""Build the Baghdad foreground dressing in an isolated Blender scene.

Run this file through Blender MCP's execute_blender_code.  Nothing in an existing
scene is changed or deleted.  The generated GLB contains four meshes with vertex
colors; all placement coordinates are in the Baghdad *stage* frame:
Blender (X, Y, Z) == stage (right, away, height).

The game importer must drape every vertex onto terrain before rotating the
imported root PI around Godot Y.  Do not use this asset as a replacement terrain.
"""

from __future__ import annotations

import json
import math
import random
from pathlib import Path

import bpy
from mathutils import Vector


ROOT = Path('/Users/chengzeyuan/Developer/SilkRoad')
GLB_PATH = ROOT / 'assets/traveler/baghdad/foreground/foreground_detail.glb'
BLEND_PATH = ROOT / 'art-src/baghdad-foreground/foreground_detail.blend'
MANIFEST_PATH = ROOT / 'docs/reports/traveler-baghdad-001/foreground-20260922/asset-manifest.json'
TEXTURE_DIR = ROOT / 'assets/traveler/baghdad/foreground/textures'
STONE_TEXTURES = {
    'albedo': TEXTURE_DIR / 'stone_surface_albedo.png',
    'roughness': TEXTURE_DIR / 'stone_surface_roughness.png',
    'normal': TEXTURE_DIR / 'stone_surface_normal.png',
}
STONE_UV_LAYER = 'StoneSurfaceUV'
STONE_UV_SCALE = 0.72
STONE_NORMAL_STRENGTH = 0.65

# These constants are the intended controls for subsequent art-direction passes.
SEED = 9222026
SCENE_NAME = 'Baghdad_Foreground_20260922'
STONE_COUNT = 78
GRASS_CLUMP_COUNT = 31
GRAVEL_COUNT = 78
STONE_Z_RANGE = (1.02, 5.82)
GRASS_Z_RANGE = (1.05, 5.30)
MAX_TRIANGLES = 20000
EXCLUSION_ZONES = [(-0.47, 2.794, 0.225), (0.43, 3.50, 0.335), (-0.47, 1.75, 0.15)]

# Muted sandstone, limestone and dusty, straw-colored vegetation. These are sRGB
# colors converted to linear values before entering Blender vertex attributes.
STONE_PALETTE = [
    (0.66, 0.579, 0.445), (0.70, 0.617, 0.490),
    (0.61, 0.541, 0.432), (0.74, 0.655, 0.520),
    (0.67, 0.603, 0.490), (0.64, 0.571, 0.459),
]
GRASS_ROOT = (0.43, 0.379, 0.222)
GRASS_TIP = (0.73, 0.645, 0.390)
GRAVEL_PALETTE = [(0.64, 0.537, 0.402), (0.68, 0.578, 0.443), (0.56, 0.495, 0.397)]
CRACK_COLOR = (0.37, 0.326, 0.255)


def enum_value(rna, property_name, wanted):
    """Never assign a guessed Blender enum without checking the live RNA."""
    prop = rna.properties.get(property_name)
    if prop is None:
        raise RuntimeError('Missing RNA property: ' + property_name)
    valid = {item.identifier for item in prop.enum_items}
    if not valid and property_name == 'export_format':
        # Blender 5.2 computes these items through a callback, so static RNA
        # returns an empty list. Query the installed exporter's live callback.
        import io_scene_gltf2
        valid = {item[0] for item in io_scene_gltf2.get_format_items(None, bpy.context)}
    if wanted not in valid:
        raise RuntimeError(f'{property_name}: {wanted!r} not in {sorted(valid)}')
    return wanted


def parameter_enum(function, parameter_name, wanted):
    parameter = function.parameters.get(parameter_name)
    if parameter is None:
        raise RuntimeError('Missing RNA function parameter: ' + parameter_name)
    valid = {item.identifier for item in parameter.enum_items}
    if wanted not in valid:
        raise RuntimeError(f'{parameter_name}: {wanted!r} not in {sorted(valid)}')
    return wanted


def srgb_channel(value):
    value = min(1.0, max(0.0, value))
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def linear_color(rgb):
    return tuple(srgb_channel(channel) for channel in rgb) + (1.0,)


def tint(rgb, factor):
    return tuple(min(0.98, max(0.025, channel * factor)) for channel in rgb)


def mix(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def outside_reserved(x, y, margin=0.0):
    return all(math.hypot(x - px, y - py) > radius + margin
               for px, py, radius in EXCLUSION_ZONES)


def road_center(y):
    return 0.062 * math.sin((y - 1.0) * 1.48) + 0.013


def road_half_width(y):
    return 1.13 - 0.078 * (y - 1.0)


def add_stone_surface_uv(mesh):
    """World-planar mapping per face; vertical edges use a non-degenerate plane."""
    uv_layer = mesh.uv_layers.new(name=STONE_UV_LAYER)
    uv_layer.active_render = True
    for polygon in mesh.polygons:
        axis = max(range(3), key=lambda index: abs(polygon.normal[index]))
        sign = 1.0 if polygon.normal[axis] >= 0.0 else -1.0
        for loop_index in polygon.loop_indices:
            x, y, z = mesh.vertices[mesh.loops[loop_index].vertex_index].co
            if axis == 2:
                # Upward stone faces use the scene XY plane at 0.72 units/tile.
                u, v = x, y * sign
            elif axis == 0:
                u, v = y * sign, z
            else:
                u, v = -x * sign, z
            uv_layer.data[loop_index].uv = (u / STONE_UV_SCALE, v / STONE_UV_SCALE)
    return uv_layer


class MeshBatch:
    """Explicit triangle geometry and corner colors, with one draw material."""

    def __init__(self, name):
        self.name = name
        self.vertices = []
        self.faces = []
        self.corner_colors = []
        self.pieces = 0

    def vertex(self, position):
        self.vertices.append(tuple(position))
        return len(self.vertices) - 1

    def tri(self, a, b, c, rgb):
        self.faces.append((a, b, c))
        colors = rgb if len(rgb) == 3 and isinstance(rgb[0], (tuple, list)) else (rgb, rgb, rgb)
        self.corner_colors.extend(linear_color(color) for color in colors)

    def quad(self, a, b, c, d, rgb):
        self.tri(a, b, c, rgb)
        self.tri(a, c, d, rgb)

    def create(self, collection, material):
        mesh = bpy.data.meshes.new(self.name + '_Geometry')
        mesh.from_pydata(self.vertices, [], self.faces)
        mesh.update()
        if self.name in ('StonePaving', 'FineGravel'):
            add_stone_surface_uv(mesh)
        new_attribute = mesh.color_attributes.bl_rna.functions['new']
        attribute = mesh.color_attributes.new(
            name='Color',
            type=parameter_enum(new_attribute, 'type', 'FLOAT_COLOR'),
            domain=parameter_enum(new_attribute, 'domain', 'CORNER'),
        )
        if len(attribute.data) != len(self.corner_colors):
            raise RuntimeError('Unexpected corner color count in ' + self.name)
        attribute.data.foreach_set('color', [v for color in self.corner_colors for v in color])
        mesh.color_attributes.active_color_index = 0
        mesh.materials.append(material)
        obj = bpy.data.objects.new(self.name, mesh)
        collection.objects.link(obj)
        obj['baghdad_foreground'] = True
        obj['stage_axis_mapping'] = 'Blender X=stage X; Blender Y=stage Z; Blender Z=height'
        obj['generated_pieces'] = self.pieces
        for polygon in mesh.polygons:
            polygon.use_smooth = False
        return obj


def make_material(name, roughness=0.94, double_sided=False, stone_surface=False):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = (0.5, 0.45, 0.35, 1.0)
    material.use_backface_culling = not double_sided
    # Node type, rather than its possibly localized/display name, identifies BSDF.
    bsdf = next(node for node in material.node_tree.nodes if node.type == 'BSDF_PRINCIPLED')
    required = ('Base Color', 'Metallic', 'Roughness')
    for socket_name in required:
        if bsdf.inputs.get(socket_name) is None:
            raise RuntimeError('Principled BSDF missing socket: ' + socket_name)
    bsdf.inputs['Metallic'].default_value = 0.0
    bsdf.inputs['Roughness'].default_value = roughness
    specular = bsdf.inputs.get('Specular IOR Level')
    if specular is not None:
        specular.default_value = 0.18
    vertex_color = material.node_tree.nodes.new('ShaderNodeVertexColor')
    vertex_color.layer_name = 'Color'
    vertex_color.label = 'Hand-varied stone and leaf colors'
    material.node_tree.links.new(vertex_color.outputs['Color'], bsdf.inputs['Base Color'])
    material['stone_surface_textures_enabled'] = False
    if stone_surface and all(path.is_file() for path in STONE_TEXTURES.values()):
        nodes, links = material.node_tree.nodes, material.node_tree.links
        uv = nodes.new('ShaderNodeUVMap')
        uv.uv_map = STONE_UV_LAYER
        textures = {}
        for role, path in STONE_TEXTURES.items():
            image = bpy.data.images.load(str(path), check_existing=False)
            color_space = 'sRGB' if role == 'albedo' else 'Non-Color'
            image.colorspace_settings.name = enum_value(image.colorspace_settings.bl_rna, 'name', color_space)
            # Keep this standalone source .blend usable when moved or archived.
            image.pack()
            texture = nodes.new('ShaderNodeTexImage')
            texture.label = 'Stone surface ' + role
            texture.image = image
            texture.extension = enum_value(texture.bl_rna, 'extension', 'REPEAT')
            texture.interpolation = enum_value(texture.bl_rna, 'interpolation', 'Linear')
            links.new(uv.outputs['UV'], texture.inputs['Vector'])
            textures[role] = texture
        modulation = nodes.new('ShaderNodeMixRGB')
        modulation.label = 'Neutral stone texture × existing vertex colors'
        modulation.blend_type = enum_value(modulation.bl_rna, 'blend_type', 'MULTIPLY')
        modulation.inputs['Fac'].default_value = 1.0
        links.new(vertex_color.outputs['Color'], modulation.inputs['Color1'])
        links.new(textures['albedo'].outputs['Color'], modulation.inputs['Color2'])
        links.new(modulation.outputs['Color'], bsdf.inputs['Base Color'])
        links.new(textures['roughness'].outputs['Color'], bsdf.inputs['Roughness'])
        normal_map = nodes.new('ShaderNodeNormalMap')
        normal_map.space = enum_value(normal_map.bl_rna, 'space', 'TANGENT')
        if 'convention' in normal_map.bl_rna.properties:
            normal_map.convention = enum_value(normal_map.bl_rna, 'convention', 'OPENGL')
        normal_map.uv_map = STONE_UV_LAYER
        normal_map.inputs['Strength'].default_value = STONE_NORMAL_STRENGTH
        links.new(textures['normal'].outputs['Color'], normal_map.inputs['Color'])
        links.new(normal_map.outputs['Normal'], bsdf.inputs['Normal'])
        material['stone_surface_textures_enabled'] = True
    return material


def stone_layout(rng):
    """Blue-noise-like irregular flagging, never a rectangular tile grid."""
    stones = []
    attempts = 0
    while len(stones) < STONE_COUNT and attempts < 18000:
        attempts += 1
        y = STONE_Z_RANGE[0] + rng.random() ** 1.10 * (STONE_Z_RANGE[1] - STONE_Z_RANGE[0])
        x = road_center(y) + rng.uniform(-1.0, 1.0) * road_half_width(y)
        # Occasional uncovered sand pockets make the edge and center discontinuous.
        if (0.58 < x < 0.85 and 2.70 < y < 3.13) or (-0.22 < x < 0.20 and 4.48 < y < 4.76):
            continue
        width = rng.uniform(0.205, 0.425)
        depth = rng.uniform(0.145, 0.295)
        if y > 4.5:
            width *= 0.85
            depth *= 0.88
        if not outside_reserved(x, y, min(width, depth) * 0.30 - 0.08):
            continue
        if any(((x - old['x']) / ((width + old['width']) * 0.515)) ** 2 +
               ((y - old['y']) / ((depth + old['depth']) * 0.56)) ** 2 < 1.0
               for old in stones):
            continue
        stones.append(dict(x=x, y=y, width=width, depth=depth,
                           angle=rng.uniform(-0.45, 0.45),
                           height=rng.uniform(0.0025, 0.0090) * (0.72 if y > 4.5 else 1.0),
                           tilt_x=rng.uniform(-0.0060, 0.0060),
                           tilt_y=rng.uniform(-0.0060, 0.0060)))
    if len(stones) != STONE_COUNT:
        raise RuntimeError(f'Could only place {len(stones)} of {STONE_COUNT} stones')
    return sorted(stones, key=lambda stone: stone['y'])


def transform_xy(stone, u, v, height):
    ca, sa = math.cos(stone['angle']), math.sin(stone['angle'])
    return (stone['x'] + ca * u - sa * v,
            stone['y'] + sa * u + ca * v, height)


def slab_height(stone, u, v):
    return stone['height'] + stone['tilt_x'] * u / stone['width'] + stone['tilt_y'] * v / stone['depth']


def make_stone(batch, stone, rng):
    width, depth = stone['width'], stone['depth']
    cuts = [rng.uniform(0.11, 0.28) for _ in range(4)]
    outline = [(-0.5 + cuts[0], -0.5), (0.5 - cuts[1], -0.5),
               (0.5, -0.5 + cuts[1]), (0.5, 0.5 - cuts[2]),
               (0.5 - cuts[2], 0.5), (-0.5 + cuts[3], 0.5),
               (-0.5, 0.5 - cuts[3]), (-0.5, -0.5 + cuts[0])]
    outline = [(u + rng.uniform(-0.046, 0.046), v + rng.uniform(-0.041, 0.041)) for u, v in outline]
    # A few edge nicks, using a shallow concavity, read as missing old stone chips.
    if rng.random() < 0.38:
        edge = rng.choice([0, 2, 4, 6])
        p, q = outline[edge], outline[(edge + 1) % len(outline)]
        mid = ((p[0] + q[0]) * 0.45, (p[1] + q[1]) * 0.45)
        outline.insert(edge + 1, mid)
    bottom, shoulder, top = [], [], []
    for u, v in outline:
        u, v = u * width, v * depth
        edge_height = slab_height(stone, u, v)
        bottom.append(batch.vertex(transform_xy(stone, u * 1.015, v * 1.015, -0.009)))
        shoulder.append(batch.vertex(transform_xy(stone, u, v, edge_height - 0.0020)))
        top.append(batch.vertex(transform_xy(stone, u * 0.946, v * 0.934, slab_height(stone, u * 0.946, v * 0.934))))
    center = batch.vertex(transform_xy(stone, 0, 0, stone['height']))
    bottom_center = batch.vertex(transform_xy(stone, 0, 0, -0.009))
    base = rng.choice(STONE_PALETTE)
    for i in range(len(top)):
        j = (i + 1) % len(top)
        batch.tri(center, top[i], top[j], tint(base, rng.uniform(0.97, 1.028)))
        batch.quad(top[i], shoulder[i], shoulder[j], top[j], tint(base, rng.uniform(0.91, 1.005)))
        batch.quad(shoulder[i], bottom[i], bottom[j], shoulder[j], tint(base, rng.uniform(0.76, 0.90)))
        batch.tri(bottom_center, bottom[j], bottom[i], tint(base, 0.75))
    batch.pieces += 1


def crack_ribbon(batch, stone, points, width):
    """Hairline seams ride just above the tilted slab plane, with no depth fight."""
    for (u0, v0), (u1, v1) in zip(points, points[1:]):
        dx, dy = u1 - u0, v1 - v0
        length = math.hypot(dx, dy)
        if length < 1e-7:
            continue
        nx, ny = -dy / length * width * 0.5, dx / length * width * 0.5
        vertices = []
        for u, v in ((u0 - nx, v0 - ny), (u1 - nx, v1 - ny),
                     (u1 + nx, v1 + ny), (u0 + nx, v0 + ny)):
            vertices.append(batch.vertex(transform_xy(stone, u, v, slab_height(stone, u, v) + 0.00030)))
        batch.quad(*vertices, CRACK_COLOR)
    batch.pieces += 1


def make_cracks(batch, stones, rng):
    eligible = [stone for stone in stones if stone['y'] < 3.50 and stone['width'] > 0.26]
    for stone in rng.sample(eligible, min(11, len(eligible))):
        w, d = stone['width'], stone['depth']
        points = [(-w * 0.36, -d * 0.07), (-w * 0.12, d * 0.03),
                  (w * 0.035, -d * 0.05), (w * 0.29, d * 0.09)]
        crack_ribbon(batch, stone, points, rng.uniform(0.00105, 0.0018))
        if rng.random() < 0.42:
            crack_ribbon(batch, stone, [points[2], (w * 0.11, -d * 0.19),
                                       (w * 0.06, -d * 0.35)], 0.00085)


def grass_layout(stones, rng):
    locations = []
    # Intentional anchors place tufts against the two arch bases and foreground
    # margins; other tufts are irregular, and only a few interrupt the route.
    anchors = [(-0.60, 1.30), (0.63, 1.39), (-1.02, 2.01), (1.07, 2.19),
               (-1.41, 2.84), (1.46, 2.85), (-1.22, 3.41), (1.32, 3.52),
               (-0.92, 4.14), (1.10, 4.56), (-0.81, 4.97)]
    for x, y in anchors:
        if outside_reserved(x, y, 0.045):
            locations.append((x, y, rng.uniform(0.095, 0.155)))
    attempts = 0
    while len(locations) < GRASS_CLUMP_COUNT and attempts < 8000:
        attempts += 1
        y = rng.uniform(*GRASS_Z_RANGE)
        if len(locations) < GRASS_CLUMP_COUNT - 6:
            sign = rng.choice((-1, 1))
            x = road_center(y) + sign * rng.uniform(road_half_width(y) * 0.88, min(1.66, road_half_width(y) + 0.50))
        else:
            x = road_center(y) + rng.uniform(-0.68, 0.68)
        if not outside_reserved(x, y, 0.065):
            continue
        if any(math.hypot(x - ox, y - oy) < 0.205 for ox, oy, _ in locations):
            continue
        if any(((x - stone['x']) / (stone['width'] * 0.50)) ** 2 +
               ((y - stone['y']) / (stone['depth'] * 0.53)) ** 2 < 1.0
               for stone in stones):
            continue
        height = rng.uniform(0.055, 0.124)
        if abs(x) < 0.70:
            height *= 0.72
        locations.append((x, y, height))
    if len(locations) != GRASS_CLUMP_COUNT:
        raise RuntimeError('Grass placement exhausted')
    return locations


def make_grass_clump(batch, x, y, height, rng):
    blade_count = rng.randint(23, 32)
    for blade_index in range(blade_count):
        angle = rng.uniform(0, math.tau)
        radial_offset = rng.uniform(0.001, 0.027)
        bx = x + math.cos(angle) * radial_offset
        by = y + math.sin(angle) * radial_offset
        leaf_height = height * rng.uniform(0.48, 1.12)
        lean = rng.uniform(0.28, 0.69) * leaf_height
        width = rng.uniform(0.0035, 0.0080)
        sideways = Vector((-math.sin(angle), math.cos(angle), 0))
        direction = Vector((math.cos(angle), math.sin(angle), 0))
        root = Vector((bx, by, -0.005))
        rings = []
        variance = rng.uniform(0.88, 1.13)
        for t, width_factor in ((0.0, 0.65), (0.36, 1.0), (0.74, 0.59)):
            center = root + direction * (lean * (t ** 1.65))
            center.z += leaf_height * t
            half_width = width * width_factor * 0.5
            # The ridge gives a leaf two angular planes, not a conical spike.
            ridge = center + Vector((0, 0, half_width * 0.32))
            indices = (batch.vertex(center - sideways * half_width),
                       batch.vertex(ridge), batch.vertex(center + sideways * half_width))
            rings.append((indices, tint(mix(GRASS_ROOT, GRASS_TIP, t), variance)))
        tip = root + direction * lean
        tip.z += leaf_height
        tip_index = batch.vertex(tip)
        for (lower, color0), (upper, color1) in zip(rings, rings[1:]):
            for segment in (0, 1):
                left_factor = 0.92 if segment == 0 else 1.045
                c0, c1 = tint(color0, left_factor), tint(color1, left_factor)
                batch.tri(lower[segment], upper[segment], upper[segment + 1], (c0, c1, c1))
                batch.tri(lower[segment], upper[segment + 1], lower[segment + 1], (c0, c1, c0))
        last_ring, last_color = rings[-1]
        tip_color = tint(GRASS_TIP, variance)
        batch.tri(last_ring[0], tip_index, last_ring[1], (tint(last_color, 0.92), tip_color, tint(last_color, 0.92)))
        batch.tri(last_ring[1], tip_index, last_ring[2], (tint(last_color, 1.045), tip_color, tint(last_color, 1.045)))
    batch.pieces += 1
    return blade_count


def make_gravel(batch, stones, rng):
    positions = []
    attempts = 0
    while len(positions) < GRAVEL_COUNT and attempts < 10000:
        attempts += 1
        y = rng.uniform(1.08, 5.50)
        x = rng.uniform(-1.70, 1.70)
        if abs(x) < 0.52 and rng.random() < 0.74:
            continue
        radius = rng.uniform(0.010, 0.026)
        if not outside_reserved(x, y, radius + 0.035):
            continue
        if any(((x - stone['x']) / (stone['width'] * 0.48 + radius)) ** 2 +
               ((y - stone['y']) / (stone['depth'] * 0.51 + radius)) ** 2 < 1.0
               for stone in stones):
            continue
        if any(math.hypot(x - ox, y - oy) < radius + old_radius + 0.025
               for ox, oy, old_radius in positions):
            continue
        positions.append((x, y, radius))
        n = rng.choice((5, 6))
        base_color = rng.choice(GRAVEL_PALETTE)
        height = radius * rng.uniform(0.53, 0.96)
        angle = rng.uniform(0, math.tau)
        middle, top = [], []
        for i in range(n):
            a = angle + i * math.tau / n
            r = radius * rng.uniform(0.84, 1.17)
            middle.append(batch.vertex((x + math.cos(a) * r, y + math.sin(a) * r * 0.77, 0.0)))
            top.append(batch.vertex((x + math.cos(a) * r * 0.56, y + math.sin(a) * r * 0.43, height * rng.uniform(0.71, 0.93))))
        apex = batch.vertex((x - radius * 0.10, y + radius * 0.08, height))
        bottom = batch.vertex((x, y, -0.006))
        for i in range(n):
            j = (i + 1) % n
            batch.tri(apex, top[i], top[j], tint(base_color, rng.uniform(0.95, 1.10)))
            batch.quad(top[i], middle[i], middle[j], top[j], tint(base_color, rng.uniform(0.79, 1.02)))
            batch.tri(bottom, middle[j], middle[i], tint(base_color, 0.79))
        batch.pieces += 1
    if len(positions) != GRAVEL_COUNT:
        raise RuntimeError('Gravel placement exhausted')
    return positions


def create_preview_rig(scene, collection):
    """A private rig is saved in the source scene, never in the game GLB."""
    camera_data = bpy.data.cameras.new('Baghdad_FG_ReviewCamera_Data')
    camera_data.lens = 42
    camera_data.clip_start = 0.01
    camera_obj = bpy.data.objects.new('Baghdad_FG_ReviewCamera', camera_data)
    collection.objects.link(camera_obj)
    camera_obj.location = (0.13, -2.15, 2.10)
    target = Vector((0, 3.06, 0.015))
    camera_obj.rotation_euler = (target - camera_obj.location).to_track_quat('-Z', 'Y').to_euler()
    scene.camera = camera_obj
    for name, location, energy, size, color in [
        ('Baghdad_FG_WarmKey', (-3.8, 2.4, 6.0), 550, 4.0, (1.0, 0.76, 0.50)),
        ('Baghdad_FG_SoftFill', (4.0, 0.0, 4.5), 210, 5.0, (0.72, 0.80, 1.0)),
    ]:
        # Light type is validated through the live factory function's enum.
        light_factory = bpy.data.lights.bl_rna.functions['new']
        light_data = bpy.data.lights.new(name + '_Data', type=parameter_enum(light_factory, 'type', 'AREA'))
        light_data.energy = energy
        light_data.size = size
        light_data.color = color
        obj = bpy.data.objects.new(name, light_data)
        collection.objects.link(obj)
        obj.location = location
        obj.rotation_euler = (target - obj.location).to_track_quat('-Z', 'Y').to_euler()
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 1000
    scene.render.resolution_percentage = 100
    world = bpy.data.worlds.new('Baghdad_FG_ReviewWorld')
    world.use_nodes = True
    background = next(node for node in world.node_tree.nodes if node.type == 'BACKGROUND')
    background.inputs['Color'].default_value = (0.17, 0.145, 0.10, 1.0)
    background.inputs['Strength'].default_value = 0.55
    scene.world = world


def export_glb(scene, objects):
    operator_rna = bpy.ops.export_scene.gltf.get_rna_type()
    properties = operator_rna.properties
    kwargs = {'filepath': str(GLB_PATH)}
    if 'export_format' not in properties:
        raise RuntimeError('glTF exporter missing export_format')
    kwargs['export_format'] = enum_value(operator_rna, 'export_format', 'GLB')
    for required in ('use_selection', 'export_yup', 'export_texcoords', 'export_tangents'):
        if required not in properties:
            raise RuntimeError('glTF exporter missing isolation property: ' + required)
        kwargs[required] = True
    options = dict(use_active_scene=True, export_normals=True,
                   export_cameras=False, export_lights=False, export_extras=True,
                   export_animations=False, export_apply=True,
                   export_all_vertex_colors=True, export_active_vertex_color_when_no_material=True)
    for name, value in options.items():
        if name in properties and properties[name].type == 'BOOLEAN':
            kwargs[name] = value
    if 'export_materials' in properties:
        kwargs['export_materials'] = enum_value(operator_rna, 'export_materials', 'EXPORT')
    if 'export_vertex_color' in properties:
        valid = {item.identifier for item in properties['export_vertex_color'].enum_items}
        # Explicit active colours keep COLOR_0 intact even when exporter shader
        # traversal does not recognize a texture × vertex-colour multiply node.
        preferred = next((value for value in ('ACTIVE', 'MATERIAL', 'NAME') if value in valid), None)
        if preferred is not None:
            kwargs['export_vertex_color'] = enum_value(operator_rna, 'export_vertex_color', preferred)
    elif 'export_colors' in properties:
        kwargs['export_colors'] = True
    # Selection is changed in the new view layer only; no old scene is touched.
    view_layer = scene.view_layers[0]
    for obj in scene.objects:
        obj.select_set(False, view_layer=view_layer)
    for obj in objects:
        obj.select_set(True, view_layer=view_layer)
    view_layer.objects.active = objects[0]
    override = dict(scene=scene, view_layer=view_layer, active_object=objects[0],
                    object=objects[0], selected_objects=objects,
                    selected_editable_objects=objects)
    if bpy.context.window is not None:
        override['window'] = bpy.context.window
    with bpy.context.temp_override(**override):
        result = bpy.ops.export_scene.gltf(**kwargs)
    if 'FINISHED' not in result or not GLB_PATH.exists():
        raise RuntimeError('Foreground GLB export failed: ' + repr(result))
    return kwargs


def main():
    rng = random.Random(SEED)
    original_scene_name = bpy.context.scene.name if bpy.context.scene else None
    scene = bpy.data.scenes.new(SCENE_NAME)
    collection = bpy.data.collections.new('Baghdad_Foreground_Asset')
    scene.collection.children.link(collection)
    rig_collection = bpy.data.collections.new('Baghdad_Foreground_ReviewRig')
    scene.collection.children.link(rig_collection)
    if bpy.context.window is not None:
        bpy.context.window.scene = scene

    batches = {name: MeshBatch(name) for name in ('StonePaving', 'DryGrass', 'FineGravel', 'StoneCracks')}
    stones = stone_layout(rng)
    for stone in stones:
        make_stone(batches['StonePaving'], stone, rng)
    make_cracks(batches['StoneCracks'], stones, rng)
    grass_positions = grass_layout(stones, rng)
    blade_count = 0
    for x, y, height in grass_positions:
        blade_count += make_grass_clump(batches['DryGrass'], x, y, height, rng)
    gravel_positions = make_gravel(batches['FineGravel'], stones, rng)
    triangle_count = sum(len(batch.faces) for batch in batches.values())
    if triangle_count > MAX_TRIANGLES:
        raise RuntimeError(f'Triangle budget exceeded: {triangle_count} > {MAX_TRIANGLES}')

    stone_material = make_material('Baghdad_FG_Stone_VertexColor', stone_surface=True)
    grass_material = make_material('Baghdad_FG_Straw_VertexColor', 0.98, double_sided=True)
    crack_material = make_material('Baghdad_FG_Crack_VertexColor', 1.0)
    materials = {'StonePaving': stone_material, 'DryGrass': grass_material,
                 'FineGravel': stone_material, 'StoneCracks': crack_material}
    objects = [batch.create(collection, materials[name]) for name, batch in batches.items()]
    create_preview_rig(scene, rig_collection)
    for path in (GLB_PATH, BLEND_PATH, MANIFEST_PATH):
        path.parent.mkdir(parents=True, exist_ok=True)
    export_options = export_glb(scene, objects)
    # A library write serializes this new scene and its dependencies only. It
    # neither saves the user's active .blend nor brings in pre-existing scenes.
    bpy.data.libraries.write(str(BLEND_PATH), {scene}, fake_user=True, compress=True)

    manifest = {
        'asset': 'Baghdad foreground: weathered flagstone, seam grass, fine gravel',
        'version': '2026-09-22', 'seed': SEED,
        'concept_reference': '/Users/chengzeyuan/Desktop/巴格达旅人/参考图.png',
        'scene': scene.name, 'previous_scene_preserved': original_scene_name,
        'glb': str(GLB_PATH.relative_to(ROOT)),
        'blend': str(BLEND_PATH.relative_to(ROOT)),
        'builder': 'tools/traveler/baghdad/foreground/build_foreground.py',
        'coordinate_system': {
            'modeling': 'Blender (X,Y,Z) = stage (right,away,height)',
            'gltf': 'Godot imported (x,y,z) = (stageX,height,-stageZ)',
            'integration': 'Drape every vertex to terrain; rotate root PI around Y to world (-stageX,height,stageZ)',
            'ground_height': 0.0,
        },
        'design': [
            'Irregular clipped and nicked slabs with narrow bevels, shallow burial and muted warm facet colors.',
            'A lightly winding route with bare sand pockets, tapering broken paving into the distance.',
            'Folded, bent two-sided grass ribbons concentrated along edges; low tufts interrupt a few seams.',
            'Fine gravel avoids the two character/fire clearances; cracks are limited to eleven near slabs.',
        ],
        'counts': {'stone_slabs': len(stones), 'grass_clumps': len(grass_positions),
                   'grass_blades': blade_count, 'gravel': len(gravel_positions),
                   'triangles': triangle_count, 'meshes': len(objects), 'materials': 3},
        'stone_surface_textures': {
            'enabled': bool(stone_material.get('stone_surface_textures_enabled', False)),
            'applies_to': ['StonePaving', 'FineGravel'],
            'files': {role: str(path.relative_to(ROOT)) for role, path in STONE_TEXTURES.items()},
            'color_spaces': {'albedo': 'sRGB', 'roughness': 'Non-Color', 'normal': 'Non-Color'},
            'base_color': 'Neutral albedo modulation multiplied by the existing vertex colors',
            'normal_convention': 'Tangent OpenGL', 'normal_strength': STONE_NORMAL_STRENGTH,
            'uv_layer': STONE_UV_LAYER, 'units_per_tile': STONE_UV_SCALE,
            'projection': 'World XY on upward faces; dominant-normal side projection with oriented UV axes',
            'filter': 'Linear', 'wrap': 'REPEAT',
            'source_blend_images_packed': bool(stone_material.get('stone_surface_textures_enabled', False)),
            'fallback': 'Vertex-color material retained unless all three source images exist',
        },
        'meshes': [{
            'name': obj.name, 'role': name,
            'vertices': len(batch.vertices), 'triangles': len(batch.faces),
            'pieces': batch.pieces, 'material': materials[name].name,
            'uv_layer': STONE_UV_LAYER if name in ('StonePaving', 'FineGravel') else None,
            'stage_bounds': {
                'minimum': [min(v[axis] for v in batch.vertices) for axis in range(3)],
                'maximum': [max(v[axis] for v in batch.vertices) for axis in range(3)],
            },
        } for obj, (name, batch) in zip(objects, batches.items())],
        'exclusion_zones': [{'stage_x': x, 'stage_z': y, 'radius': radius}
                            for x, y, radius in EXCLUSION_ZONES],
        'stone_centers': [{'stage_x': s['x'], 'stage_z': s['y'], 'width': s['width'],
                           'depth': s['depth'], 'height': s['height']} for s in stones],
        'grass_centers': [{'stage_x': x, 'stage_z': y, 'nominal_height': h}
                          for x, y, h in grass_positions],
        'export_options': export_options,
        'notes': ('Review rig excluded from GLB. Stone and gravel include explicit planar UVs; '
                  'all three surface maps are applied together when available and packed into the source blend. '
                  'Grass and crack materials remain vertex-colored. Existing scene data left intact.'),
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    result = {'scene': scene.name, 'glb': str(GLB_PATH), 'blend': str(BLEND_PATH),
              'manifest': str(MANIFEST_PATH), **manifest['counts']}
    print('BAGHDAD_FOREGROUND_RESULT ' + json.dumps(result, ensure_ascii=False))
    return result


if __name__ == '__main__':
    BAGHDAD_FOREGROUND_RESULT = main()
