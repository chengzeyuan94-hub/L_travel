#!/usr/bin/env python3
"""Author an isolated tree/cloud library; never changes production map assets.

Blender 5.2.1 --background --factory-startup --python-exit-code 1 --python
tools/lowpoly/library_trees_clouds_018.py -- --renders <external evidence dir>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import bpy
import bmesh
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "docs/design/terrain-library-018"
IDS = ("tree_spruce", "tree_windswept", "tree_oak",
       "cloud_drifter", "cloud_cumulus", "cloud_bank")
CURRENT = None
MATERIALS = {}


def linear(hex_color):
    values = [int(hex_color[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(v / 12.92 if v < .04045 else ((v + .055) / 1.055) ** 2.4 for v in values)


def material(name, hex_color, vertex_color=False):
    if name in MATERIALS:
        return MATERIALS[name]
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*linear(hex_color), 1)
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = mat.diffuse_color
    shader.inputs["Roughness"].default_value = .86
    if vertex_color:
        attr = mat.node_tree.nodes.new("ShaderNodeVertexColor")
        attr.layer_name = "Color"
        mat.node_tree.links.new(attr.outputs["Color"], shader.inputs["Base Color"])
    MATERIALS[name] = mat
    return mat


def move_to_collection(obj, collection=None):
    target = collection or CURRENT
    for old in list(obj.users_collection):
        old.objects.unlink(obj)
    target.objects.link(obj)


def mesh(name, vertices, faces, mat, smooth=False):
    data = bpy.data.meshes.new(name + "_geometry")
    data.from_pydata(vertices, [], faces)
    data.update()
    obj = bpy.data.objects.new(name, data)
    CURRENT.objects.link(obj)
    obj.data.materials.append(mat)
    for p in data.polygons:
        p.use_smooth = smooth
    return obj


def tube(name, points, radii, mat, sides=9, phase=0):
    """Connected tapered branch with a transported local frame, closed ends."""
    vertices, faces = [], []
    pts = [Vector(p) for p in points]
    for j, point in enumerate(pts):
        direction = (pts[min(j + 1, len(pts)-1)] - pts[max(0, j-1)]).normalized()
        guide = Vector((0, 1, 0)) if abs(direction.y) < .9 else Vector((1, 0, 0))
        side = direction.cross(guide).normalized()
        other = direction.cross(side).normalized()
        for i in range(sides):
            angle = phase + i * math.tau / sides
            vertices.append(point + radii[j] * (math.cos(angle)*side + math.sin(angle)*other))
        if j:
            for i in range(sides):
                k = (i+1) % sides
                faces.append(((j-1)*sides+i, (j-1)*sides+k, j*sides+k, j*sides+i))
    faces.extend((tuple(reversed(range(sides))), tuple((len(pts)-1)*sides+i for i in range(sides))))
    return mesh(name, vertices, faces, mat)


def vertex_shade(obj, lower_hex, upper_hex, strength=.8):
    """Coherent vertical color field; deliberately no random triangle colors."""
    data = obj.data
    zs = [v.co.z for v in data.vertices]
    low, high = min(zs), max(zs)
    a, b = linear(lower_hex), linear(upper_hex)
    attr = data.color_attributes.new(name="Color", type='FLOAT_COLOR', domain='CORNER')
    for poly in data.polygons:
        for li in poly.loop_indices:
            z = data.vertices[data.loops[li].vertex_index].co.z
            f = (z - low) / max(.0001, high-low)
            f = f*f*(3-2*f)
            f = .5 + (f-.5)*strength
            color = tuple(a[k]*(1-f)+b[k]*f for k in range(3))
            attr.data[li].color = (*color, 1)


def foliage_volume(name, center, scale, mat, phase=0, sides=18, rings=10,
                   angular_lobes=5, lobe_strength=.075, tilt=(0, 0)):
    """Authored soft volume with coherent lobes, neither an ico nor noise cloud."""
    vertices = []
    cx, cy, cz = center
    sx, sy, sz = scale
    vertices.append((cx, cy, cz-sz))
    for j in range(1, rings):
        elevation = -math.pi/2 + j*math.pi/rings
        radial = math.cos(elevation)
        z = math.sin(elevation)
        for i in range(sides):
            a = phase + i*math.tau/sides + .11*math.sin(j*1.7+phase)
            shape = 1 + lobe_strength*math.sin(a*angular_lobes+phase) * (radial**.6)
            shape += .035*math.cos(a*3+elevation*2+phase)
            vertices.append((cx + sx*radial*math.cos(a)*shape + tilt[0]*z,
                             cy + sy*radial*math.sin(a)*shape + tilt[1]*z,
                             cz + sz*z + sz*radial*(.075*math.cos(a*3+phase)+.025*math.sin(a*7+j*.9))))
    vertices.append((cx+tilt[0], cy+tilt[1], cz+sz))
    faces = [(0, 1+(i+1)%sides, 1+i) for i in range(sides)]
    for j in range(rings-2):
        lower, upper = 1+j*sides, 1+(j+1)*sides
        for i in range(sides):
            k = (i+1)%sides
            if (j+i)%2:
                faces.extend(((lower+i, lower+k, upper+i),(lower+k,upper+k,upper+i)))
            else:
                faces.extend(((lower+i,lower+k,upper+k),(lower+i,upper+k,upper+i)))
    cap = len(vertices)-1
    faces.extend((cap, 1+(rings-2)*sides+i, 1+(rings-2)*sides+(i+1)%sides) for i in range(sides))
    obj = mesh(name, vertices, faces, mat)
    if lobe_strength > .05:
        decimate = obj.modifiers.new('Irregular foliage planes','DECIMATE')
        decimate.ratio = .76
        decimate.use_collapse_triangulate = True
        apply_modifier(obj,decimate)
    return obj


def merged_cloud(name, lobes, mat, voxel=.05, target_faces=1100):
    """Union lobes into one connected sculptable surface, then soften/decimate."""
    components = []
    for i, (center, scale) in enumerate(lobes):
        component = foliage_volume(name+f'_construction_{i}', center, scale, mat,
                                   phase=i*.67, sides=20, rings=14,
                                   angular_lobes=3, lobe_strength=.015)
        components.append(component)
    bpy.ops.object.select_all(action='DESELECT')
    for obj in components:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = components[0]
    bpy.ops.object.join()
    obj = bpy.context.object
    obj.name = name
    remesh = obj.modifiers.new('Seamless cloud volume', 'REMESH')
    remesh.mode = 'VOXEL'
    remesh.voxel_size = voxel
    remesh.use_smooth_shade = False
    apply_modifier(obj, remesh)
    soften = obj.modifiers.new('Broad soft transitions', 'SMOOTH')
    soften.factor = 1.35
    soften.iterations = 4
    apply_modifier(obj, soften)
    obj.data.calc_loop_triangles()
    tri_count = len(obj.data.loop_triangles)
    decimate = obj.modifiers.new('Intentional low-poly planes', 'DECIMATE')
    decimate.ratio = min(1, target_faces/max(1, tri_count))
    decimate.use_collapse_triangulate = True
    apply_modifier(obj, decimate)
    for poly in obj.data.polygons:
        poly.use_smooth = False
    return obj


def apply_modifier(obj, modifier):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    obj.select_set(False)


def asset_bounds(objects):
    points = [o.matrix_world @ v.co for o in objects if o.type == 'MESH' for v in o.data.vertices]
    return [min(p[i] for p in points) for i in range(3)], [max(p[i] for p in points) for i in range(3)]


def normalize_asset(objects):
    bpy.context.view_layer.update()
    a, b = asset_bounds(objects)
    offset = Vector((-(a[0]+b[0])/2, -(a[1]+b[1])/2, -a[2]))
    for obj in objects:
        if obj.type != 'MESH':
            continue
        transform = obj.matrix_world.copy()
        for v in obj.data.vertices:
            v.co = transform @ v.co + offset
        obj.matrix_world.identity()
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        bm.to_mesh(obj.data)
        bm.free()
        obj.data.update()
    bpy.context.view_layer.update()


def gltf_bounds(objects):
    a, b = asset_bounds(objects)
    return {"min": [a[0], a[2], -b[1]], "max": [b[0], b[2], -a[1]],
            "size": [b[0]-a[0], b[2]-a[2], b[1]-a[1]]}


def stats(objects):
    triangles = 0
    for o in objects:
        if o.type == 'MESH':
            o.data.calc_loop_triangles()
            triangles += len(o.data.loop_triangles)
    return {"triangles": triangles, "mesh_count": sum(o.type=='MESH' for o in objects),
            "materials": sorted({m.name for o in objects if o.type=='MESH' for m in o.data.materials}),
            "bounds": gltf_bounds(objects)}


def studio(collection):
    world = bpy.data.worlds.new("LibraryStudioWorld")
    world.use_nodes = True
    world.node_tree.nodes['Background'].inputs['Color'].default_value = (*linear('C5D2DB'), 1)
    world.node_tree.nodes['Background'].inputs['Strength'].default_value = .55
    bpy.context.scene.world = world
    for name, pos, power, size in (("SoftKey", (4,-5,7), 650, 5),
                                   ("SoftFill", (-4,-1,4), 240, 4),
                                   ("Rim", (2,4,6), 420, 4)):
        data = bpy.data.lights.new(name, 'AREA')
        data.energy, data.shape, data.size = power, 'DISK', size
        obj = bpy.data.objects.new(name, data)
        collection.objects.link(obj)
        obj.location = pos
        obj.rotation_euler = (Vector((0,0,1))-obj.location).to_track_quat('-Z','Y').to_euler()
    data = bpy.data.cameras.new("StudioCamera")
    cam = bpy.data.objects.new("StudioCamera", data)
    collection.objects.link(cam)
    data.type = 'ORTHO'
    bpy.context.scene.camera = cam
    bpy.ops.mesh.primitive_plane_add(size=200)
    floor = bpy.context.object
    floor.name = "STUDIO_ONLY_floor"
    move_to_collection(floor, collection)
    floor.location.z = -.025
    floor.data.materials.append(material("StudioFloor", "B4C2CD"))
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 32
    scene.cycles.use_denoising = True
    scene.render.resolution_x = scene.render.resolution_y = 900
    scene.render.resolution_percentage = 100
    scene.view_settings.view_transform = 'AgX'
    scene.render.image_settings.file_format = 'PNG'
    return cam


def render_views(asset_id, objects, cam, output):
    a, b = asset_bounds(objects)
    center = Vector(((a[0]+b[0])/2, (a[1]+b[1])/2, (a[2]+b[2])/2))
    extent = max(b[i]-a[i] for i in range(3))
    for label, vector in (("three-quarter", (5,-7,3.7)), ("side", (7,0,2.0)), ("top", (0,-.001,9))):
        direction = Vector(vector).normalized()
        cam.location = center + direction*extent*4
        cam.rotation_euler = (center-cam.location).to_track_quat('-Z','Y').to_euler()
        cam.data.ortho_scale = extent*1.35
        bpy.context.scene.render.filepath = str(output / f"{asset_id}-{label}.png")
        bpy.ops.render.render(write_still=True)


def roots_and_trunk(name, points, radii, roots=5):
    bark = material('TreeBark', '916635')
    main = tube(name+'_trunk', points, radii, bark, sides=10, phase=.15)
    for v in list(main.data.vertices)[:10]:
        v.co.z = 0
    for i in range(roots):
        a = i*math.tau/roots + .23
        length = .36 + .065*math.sin(i*2.3)
        d, t = Vector((math.cos(a),math.sin(a),0)), Vector((-math.sin(a),math.cos(a),0))
        vertices, faces = [], []
        for j,(distance,width,height) in enumerate(((.055,.09,.29),(length*.57,.063,.095),(length,.018,.012))):
            c = d*distance
            vertices.extend((c-t*width,c+t*width,c+t*width+Vector((0,0,height)),c-t*width+Vector((0,0,height))))
            if j:
                for k in range(4):
                    faces.append(((j-1)*4+k,(j-1)*4+(k+1)%4,j*4+(k+1)%4,j*4+k))
        faces.extend(((3,2,1,0),(8,9,10,11)))
        mesh(name+f'_root_{i}',vertices,faces,bark)
    return bark, main


def spruce_tier(name, center, radius, height, phase, colors):
    """Scalloped bough volume: drooping tips, lifted shoulders, off-axis leader."""
    cx, cy, cz = center
    sides, lobes = 32, 8
    vertices, faces = [], []
    # A shallow underside connects each flared branch rim into a closed crown.
    rings = ((.11,.13), (1,0), (.77,.25), (.49,.56), (.18,.87))
    for j, (radial, z) in enumerate(rings):
        for i in range(sides):
            a = i*math.tau/sides + phase
            lobe = math.cos((a-phase)*lobes)
            asym = 1 + .065*math.sin(a*3+.8) + .06*math.cos(a+phase)
            scallop = (1 + .17*lobe) if j==1 else (1+(.09 if j==2 else .045)*lobe)
            rr = radial*radius*asym*scallop
            zz = cz+height*z
            if j == 1:
                zz += height*(.035-.10*lobe+.07*math.sin(a*3+phase))
            elif j in (2,3):
                zz += (.085 if j==2 else .06)*height*math.sin(a*lobes+phase)
            vertices.append((cx+rr*math.cos(a)+.06*z, cy+rr*math.sin(a)*.94, zz))
        if j:
            for i in range(sides):
                k = (i+1)%sides
                faces.extend((((j-1)*sides+i,(j-1)*sides+k,j*sides+i),
                              ((j-1)*sides+k,j*sides+k,j*sides+i)))
    faces.append(tuple(reversed(range(sides))))
    tip = len(vertices)
    vertices.append((cx+.11,cy-.018,cz+height))
    for i in range(sides):
        faces.append((4*sides+i,4*sides+(i+1)%sides,tip))
    obj = mesh(name, vertices, faces, material('SpruceFoliage', 'FFFFFF', True))
    vertex_shade(obj, *colors, strength=.85)
    return obj


def build_spruce():
    roots_and_trunk('spruce', [(0,0,0),(.01,.015,.24),(.005,0,.72),(.025,.01,1.4),(.05,0,2.23)],
                    [.19,.145,.12,.078,.025], roots=5)
    for i, (center,radius,height,phase,colors) in enumerate((
        ((0,0,.68),.97,1.07,.08,('254B39','4D7049')),
        ((.025,.012,1.22),.75,.97,.28,('2B513B','5B7B4D')),
        ((.03,.015,1.78),.52,.86,.03,('375B40','6F8B54')),
        ((.045,.00,2.26),.285,.77,.25,('436746','91A66A')))):
        spruce_tier(f'spruce_bough_tier_{i+1}',center,radius,height,phase,colors)
    return ['Four unequal scalloped, drooping bough tiers with offset branch tips',
            'Visible tapered trunk and five flared roots',
            'Tilted narrow leader; dark lower boughs and restrained sage tip']


def umbrella(name, center, scale, shade, phase):
    obj = foliage_volume(name,center,scale,material('PineFoliage','FFFFFF',True),
                         phase=phase,sides=19,rings=9,angular_lobes=5,lobe_strength=.09)
    vertex_shade(obj, shade[0], shade[1], strength=.8)
    return obj


def build_windswept():
    bark, _ = roots_and_trunk('windswept',
        [(0,0,0),(.03,0,.26),(.15,.015,.61),(.53,.03,.96),(.62,.015,1.2),
         (.45,.03,1.49),(.13,.02,1.68),(-.03,.06,1.97)],
        [.195,.165,.14,.13,.11,.082,.058,.02])
    # Unequal branch lengths preserve the strong lateral, open silhouette.
    for name, points, radii in (
        ('left_low',[(.45,.02,1.01),(.02,-.12,1.23),(-.43,-.37,1.21),(-.83,-.57,1.42)], [.09,.068,.048,.018]),
        ('right_low',[(.35,.02,.91),(.84,-.23,.84),(1.08,-.55,1.03)], [.077,.049,.016]),
        ('right_high',[(.54,.02,1.34),(.95,.26,1.42),(1.16,.46,1.65)], [.067,.041,.014]),
        ('crown_left',[(.28,.04,1.61),(-.36,.20,1.82),(-.68,.30,2.05)], [.072,.047,.015]),
        ('crown_mid',[(-.01,.06,1.81),(.03,.35,2.18)], [.045,.012])):
        tube('windswept_branch_'+name,points,radii,bark,sides=8)
    data = [
        ('high_left',(-.67,.30,2.18),(.73,.48,.34),('3F613B','91A55B'),.3),
        ('high_mid',(.02,.35,2.24),(.48,.4,.29),('496B3A','A1AE63'),1.3),
        ('mid_right',(1.16,.46,1.81),(.5,.37,.23),('3E613A','8FA759'),2.3),
        ('low_left',(-.85,-.57,1.56),(.49,.36,.225),('42673C','90A660'),.9),
        ('low_right',(1.08,-.55,1.18),(.46,.33,.21),('3C6038','8CA258'),1.7)]
    for name, center, scale, colors, phase in data:
        umbrella('windswept_crown_'+name,center,scale,colors,phase)
    return ['S-curved forked trunk with exposed angular horizontal branches',
            'Five unequal flattened umbrella crowns, tall crown leaning left',
            'Large negative spaces between crown levels and five flared roots']


def build_oak():
    bark, _ = roots_and_trunk('oak',[(0,0,0),(.01,0,.25),(.025,0,.71),(.05,.03,1.10),(-.03,.05,1.48)],
                             [.23,.185,.155,.125,.053],roots=6)
    branches = [
        ('left',[(.02,0,.69),(-.26,-.025,1.14),(-.58,-.12,1.52),(-.66,-.18,1.8)],[.13,.105,.068,.02]),
        ('left_inner',[(-.27,-.025,1.13),(-.33,-.15,1.51),(-.24,-.12,1.84)],[.064,.038,.015]),
        ('right',[(.03,.02,.83),(.35,.05,1.11),(.64,.11,1.45),(.86,.12,1.72)],[.122,.091,.051,.018]),
        ('right_inner',[(.34,.05,1.11),(.28,-.16,1.43),(.46,-.38,1.63)],[.06,.039,.014]),
        ('leader',[(.02,.02,1.02),(.08,.07,1.54),(-.05,.1,2.22)],[.09,.062,.018]),
        ('leader_fork',[(.07,.08,1.64),(-.23,.24,1.94),(-.38,.32,2.15)],[.041,.027,.012])]
    for name, points, radii in branches:
        tube('oak_branch_'+name,points,radii,bark,sides=9)
    for i, (center,scale,phase,colors) in enumerate((
        ((-.79,-.14,1.96),(.57,.47,.53),.3,('3F6135','98A64C')),
        ((-.56,.39,2.10),(.5,.43,.46),1.4,('466333','8D9D48')),
        ((-.02,.15,2.43),(.61,.51,.53),2.1,('486330','9CAA49')),
        ((.81,.16,2.02),(.59,.51,.54),.8,('425D2D','97A345')),
        ((.66,-.30,1.83),(.39,.36,.37),1.7,('3D592D','909D43')))):
        obj = foliage_volume(f'oak_crown_mass_{i+1}',center,scale,
                              material('OakFoliage','FFFFFF',True),phase=phase,
                              sides=19,rings=10,angular_lobes=5,lobe_strength=.095,
                              tilt=(.025*math.sin(i),.02*math.cos(i)))
        vertex_shade(obj,*colors,strength=.9)
    return ['Low sturdy branching Y trunk with visible inner secondary forks',
            'Five interlocking asymmetric olive and moss foliage masses',
            'Uneven crown outline and six grounded flared roots']


def cloud_asset(name, lobes, count, description, target):
    obj = merged_cloud(name,lobes,material('CloudIvory','FFFFFF',True),voxel=.037,target_faces=target)
    vertex_shade(obj,'CFDBE3','FFF9EA',strength=.5)
    obj['construction_lobes'] = json.dumps(lobes)
    obj['concept_major_lobes'] = count
    return [description, 'One seamless connected mesh; broad soft facets and clean fused joins',
            'Restrained ivory top / pale blue-gray underside; no transparency or painted shadow texture']


def build_drifter():
    return cloud_asset('cloud_drifter',[
        ((-1.2,0,.34),(.37,.34,.255)),
        ((-.65,-.1,.50),(.67,.56,.425)),
        ((0,.07,.76),(.76,.65,.69)),
        ((.76,.04,.56),(.61,.5,.48)),
        ((1.30,-.01,.32),(.29,.28,.235))],5,
        'Broad low five-lobe fair-weather cloud, largest offset central puff and small trailing ends',1200)


def build_cumulus():
    return cloud_asset('cloud_cumulus',[
        ((-.43,-.10,.42),(.55,.51,.39)),
        ((.0,-.1,.49),(.66,.58,.47)),
        ((.47,.11,.38),(.44,.43,.34)),
        ((.18,.10,1.01),(.51,.47,.55)),
        ((-.13,.17,1.50),(.45,.44,.55)),
        ((.03,.18,1.94),(.30,.33,.38)),
        ((-.53,.06,.84),(.31,.32,.34))],7,
        'Three stepped vertical main lobes, broad bottom puff and four unequal shoulder/base lobes',1350)


def build_bank():
    return cloud_asset('cloud_bank',[
        ((-1.43,.01,.52),(.67,.61,.51)),
        ((-.85,.30,.69),(.61,.54,.57)),
        ((-.22,.44,.60),(.51,.45,.49)),
        ((.34,.37,.47),(.43,.37,.39)),
        ((.85,.21,.32),(.35,.29,.28)),
        ((1.27,.06,.19),(.27,.21,.17)),
        ((1.61,-.06,.115),(.24,.145,.105))],7,
        'Seven-puff arcing bank with a broad leading end and progressively tapering solid wisp',1300)


BUILDERS = dict(zip(IDS,(build_spruce,build_windswept,build_oak,build_drifter,build_cumulus,build_bank)))


def main():
    global CURRENT
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=LIBRARY)
    parser.add_argument('--renders', type=Path, default=Path('/Users/chengzeyuan/SilkRoadEvidence/planet-props-018/library/trees-clouds'))
    parser.add_argument('--no-render', action='store_true')
    args = parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    if set(BUILDERS) != set(IDS):
        raise RuntimeError('Concept-approved builders have not been authored yet.')
    for category in ('trees', 'clouds'):
        if not (LIBRARY / 'concepts' / f'{category}.png').is_file():
            raise RuntimeError(f'Missing inspected concept image: {category}.png')
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for folder in (args.out/'exports', args.out/'source', args.renders):
        folder.mkdir(parents=True, exist_ok=True)
    collections, catalog = [], []
    for asset_id in IDS:
        CURRENT = bpy.data.collections.new(asset_id)
        bpy.context.scene.collection.children.link(CURRENT)
        collections.append(CURRENT)
        features = BUILDERS[asset_id]()
        objects = list(CURRENT.objects)
        normalize_asset(objects)
        bpy.ops.object.select_all(action='DESELECT')
        for obj in objects:
            obj.select_set(True)
        glb = args.out/'exports'/f'{asset_id}.glb'
        bpy.ops.export_scene.gltf(filepath=str(glb), export_format='GLB', use_selection=True,
                                  export_yup=True, export_apply=True, export_animations=False,
                                  export_cameras=False, export_lights=False)
        catalog.append({'id': asset_id, 'category': 'tree' if asset_id.startswith('tree') else 'cloud',
                        'glb': str(glb.relative_to(args.out)), 'blend': 'source/trees-clouds.blend',
                        'concept': 'concepts/trees.png' if asset_id.startswith('tree') else 'concepts/clouds.png',
                        'features': features, **stats(objects),
                        'origin': 'Horizontal bounds center; lowest geometric point at glTF Y=0.',
                        'sha256': hashlib.sha256(glb.read_bytes()).hexdigest(), 'bytes': glb.stat().st_size})
        CURRENT.hide_render = True
    stage = bpy.data.collections.new('STUDIO_ONLY_NOT_EXPORTED')
    bpy.context.scene.collection.children.link(stage)
    cam = studio(stage)
    if not args.no_render:
        for col in collections:
            col.hide_render = False
            render_views(col.name, list(col.objects), cam, args.renders)
            col.hide_render = True
    for i, col in enumerate(collections):
        col.hide_render = i != 0
        col.hide_viewport = i != 0
    a,b = asset_bounds(list(collections[0].objects))
    center = Vector(((a[0]+b[0])/2,(a[1]+b[1])/2,(a[2]+b[2])/2))
    extent = max(b[i]-a[i] for i in range(3))
    cam.location = center+Vector((5,-7,3.7)).normalized()*extent*4
    cam.rotation_euler = (center-cam.location).to_track_quat('-Z','Y').to_euler()
    cam.data.ortho_scale = extent*1.35
    bpy.ops.wm.save_as_mainfile(filepath=str(args.out/'source/trees-clouds.blend'))
    result = {'schema': 1, 'coordinate_system': 'glTF right-handed Y-up; Blender +Y maps to glTF -Z',
              'purpose': 'Independent library; not integrated into production map.', 'assets': catalog}
    (args.out/'trees-clouds-catalog.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    print('LIBRARY_TREES_CLOUDS_018 '+json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
