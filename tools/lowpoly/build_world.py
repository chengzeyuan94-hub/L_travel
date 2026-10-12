"""Build actual low-poly world meshes in Blender, preserving the rule map geometry.

Run: Blender --background --python tools/lowpoly/build_world.py -- --root /path/to/SilkRoad
The old terrain PNG is sampled only to recover the existing coastline/biome layout.
No raster texture is embedded in the exported GLBs: every visible surface is geometry.
"""
import argparse
import colorsys
import hashlib
import json
import math
from pathlib import Path
import random
import sys

import bpy
from mathutils import Vector
from mathutils.kdtree import KDTree

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
ROOT = args.root
OUT = ROOT / 'assets/game/lowpoly/world'
SOURCE = ROOT / 'docs/design/lowpoly-v1/source'
PREVIEW = ROOT / 'docs/design/lowpoly-v1/previews/world'
for p in [OUT, SOURCE, PREVIEW]:
    p.mkdir(parents=True, exist_ok=True)
(SOURCE / '.gdignore').touch()
(ROOT / 'docs/design/lowpoly-v1/previews/.gdignore').touch()
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
rng = random.Random(260907)

data_root = ROOT / 'data/rulesets/lshu_configurable_v1'
nodes = json.loads((data_root / 'board_nodes.json').read_text())['items']
edges = json.loads((data_root / 'board_edges.json').read_text())['items']
city_nodes = [n for n in nodes if n['node_type'] == 'CITY']
land_points, sea_points, all_points = [], [], []
for edge in edges:
    pts = edge['movement_polyline']
    target = land_points if edge['route_type'] == 'LAND' else sea_points
    for a, b in zip(pts, pts[1:]):
        steps = max(1, int(math.dist(a, b) / 10))
        for j in range(steps):
            t = j / steps
            target.append((a[0] * (1-t) + b[0] * t, a[1] * (1-t) + b[1] * t))
    target.append(tuple(pts[-1]))
all_points = land_points + sea_points

def tree(points):
    kd = KDTree(len(points))
    for i, (x, y) in enumerate(points):
        kd.insert((x, y, 0), i)
    kd.balance()
    return kd

land_kd, sea_kd, routes_kd = tree(land_points), tree(sea_points), tree(all_points)
city_kd = tree([n['map_position'] for n in city_nodes] +
               [(n['map_position'][0], n['map_position'][1]-85) for n in city_nodes])

def distance(kd, x, y):
    return kd.find((x, y, 0))[2]

image_path = ROOT / 'assets/game/maps/world/world_map_v2_overscan.png'
terrain_image = bpy.data.images.load(str(image_path), check_existing=True)
w, h = terrain_image.size
pixels = list(terrain_image.pixels)

def sample(x, y):
    # PNG is overscanned 184 logical pixels north; Blender pixels are bottom-up.
    sx = max(0, min(w-1, round(x)))
    sy = max(0, min(h-1, round(y + 184)))
    pos = ((h-1-sy)*w + sx)*4
    return pixels[pos], pixels[pos+1], pixels[pos+2]

def is_land(x, y):
    # Existing city centres get a flat supporting footprint. This is appearance only.
    if distance(city_kd, x, y) < 70:
        return True
    if distance(land_kd, x, y) < 18:
        return True
    r, g, b = sample(x, y)
    hue, sat, val = colorsys.rgb_to_hsv(r, g, b)
    return not (0.43 < hue < 0.68 and sat > 0.21 and b > r * 1.09)

# Gentle source-geographic ridges. Keep the original routes and city pads level.
RIDGES = [(330, 0, 140, 90, .7), (1040, 205, 190, 70, .65),
          (1510, 530, 160, 75, .65), (1860, 415, 130, 100, .95),
          (1960, 110, 175, 90, 1.4), (2210, 30, 230, 90, 1.3),
          (2290, 410, 150, 70, 1.45), (2480, 495, 210, 65, 1.7),
          (2720, 515, 135, 85, 1.1), (2890, 150, 200, 100, .6),
          (810, 880, 100, 150, .5), (1150, 970, 90, 130, .6)]

def elevation(x, y):
    route_dist = distance(routes_kd, x, y)
    city_dist = distance(city_kd, x, y)
    protection = min(max(0, (route_dist-45)/70), max(0, (city_dist-140)/75), 1)
    ridge = max(a * math.exp(-(((x-cx)/rx)**2+((y-cy)/ry)**2))
                for cx, cy, rx, ry, a in RIDGES)
    ripples = .022*(math.sin(x*.021)+math.cos(y*.024))
    return .08 + protection * max(0, ridge + ripples)

def linear(v):
    return v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4

def hex_color(s):
    return tuple(linear(int(s[i:i+2], 16)/255) for i in (0,2,4)) + (1,)

def material(name, color):
    mat=bpy.data.materials.new(name)
    mat.diffuse_color=hex_color(color)
    mat.use_nodes=True
    bsdf=mat.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value=mat.diffuse_color
    bsdf.inputs['Roughness'].default_value=.9
    bsdf.inputs['Metallic'].default_value=0
    return mat

palette = [material('sand_%d'%i, c) for i,c in enumerate(['CFB27E','D1B580','CCB07B','D4B783'])]
palette += [material('grass_%d'%i, c) for i,c in enumerate(['91A074','94A377','8E9E71','97A57A'])]
palette += [material('stone_%d'%i, c) for i,c in enumerate(['9E8D74','B0A18A','C4B599','E9E4D4'])]
shore_mat=material('ochre_coast_cliffs','B49360')
trunk_mat=material('tree_wood','735638')
pine_mat=material('pine_jade','416956')
leaves_mat=material('leaf_olive','64854D')
rock_mat=material('sandstone_boulder','B59C77')
sea_mat=material('open_sea_matte','307D88')
deep_mat=material('board_edge_deep_teal','245968')
water_colors=[material('water_facet_%d'%i,c) for i,c in enumerate(['347C86','367E88','357D87','38808A'])]

def mesh(name, verts, faces, mats, indices=None):
    data=bpy.data.meshes.new(name)
    data.from_pydata(verts, [], faces)
    data.materials.clear()
    for mat in mats:data.materials.append(mat)
    data.update()
    if indices:
        for p, mi in zip(data.polygons, indices):p.material_index=mi
    obj=bpy.data.objects.new(name,data)
    bpy.context.collection.objects.link(obj)
    return obj

def world(x,y,height):
    # Blender +Z-up -> exported glTF +Y-up; Blender -Y -> glTF +Z.
    return ((x-2048)*.01, -(y-681.5)*.01, height)

def biome_material(x,y,z):
    if z > .85:return 11 if z > 1.1 else rng.choice([8,9,10,11])
    # Broad, deliberately arranged biome regions; source shadows must not turn
    # adjacent faces into a noisy checkerboard of unrelated materials.
    eastern_border=2650+65*math.sin(y*.012)
    green=(x>eastern_border and y>150) or (1820<x<2340 and y>690)
    green=green or (x<1050 and y<260) or (x<620 and y>1280)
    return rng.randrange(4,8) if green else rng.randrange(0,4)

step=34
xs=list(range(0,4097,step))
if xs[-1] != 4096:xs.append(4096)
ys=list(range(-170,1531,step))
nx=len(xs)
logical=[]
for row, y in enumerate(ys):
    for col,x in enumerate(xs):
        # Jitter interior points to avoid a square-grid terrain appearance.
        px=x+(rng.uniform(-9,9) if 0<col<len(xs)-1 else 0)
        py=y+(rng.uniform(-9,9) if 0<row<len(ys)-1 else 0)
        logical.append((px,py))
vertices=[world(x,y,elevation(x,y)) for x,y in logical]
faces=[];indices=[]
for row in range(len(ys)-1):
    for col in range(nx-1):
        a=row*nx+col;b=a+1;c=a+nx;d=c+1
        triangles=[(a,c,b),(b,c,d)] if (row+col)%2 else [(a,d,b),(a,c,d)]
        for tri in triangles:
            x=sum(logical[k][0] for k in tri)/3
            y=sum(logical[k][1] for k in tri)/3
            if is_land(x,y):
                faces.append(tri)
                z=sum(vertices[k][2] for k in tri)/3
                indices.append(biome_material(x,y,z))
land=mesh('eurasia_faceted_mainland',vertices,faces,palette,indices)

# Coast sidewalls are generated from boundary edges of the land triangulation.
counts={}
for face in faces:
    for a,b in zip(face,face[1:]+face[:1]):
        key=tuple(sorted((a,b)))
        counts[key]=counts.get(key,0)+1
cliff_verts=[];cliff_faces=[]
for (a,b),count in counts.items():
    if count!=1:continue
    va,vb=vertices[a],vertices[b]
    i=len(cliff_verts)
    cliff_verts.extend([va,vb,(vb[0],vb[1],-.16),(va[0],va[1],-.16)])
    cliff_faces.append((i,i+1,i+2,i+3))
cliffs=mesh('coast_facets',cliff_verts,cliff_faces,[shore_mat])

water_vertices=[];water_faces=[];water_indices=[]
for iy in range(25):
    for ix in range(55):water_vertices.append((-22+ix*44/54,-10+iy*20/24,.03))
for iy in range(24):
    for ix in range(54):
        a=iy*55+ix;b=a+1;c=a+55;d=c+1
        water_faces.extend([(a,b,c),(b,d,c)])
        water_indices.extend([rng.randrange(4),rng.randrange(4)])
water=mesh('faceted_indian_ocean',water_vertices,water_faces,water_colors,water_indices)

# Dark board slab, bevelled corners, with a readable physical thickness.
bpy.ops.mesh.primitive_cube_add(size=1,location=(0,0,-.37))
slab=bpy.context.object;slab.name='ocean_board_plinth';slab.dimensions=(44,20,.75)
bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
slab.data.materials.append(deep_mat)
bevel=slab.modifiers.new('small_corner_bevel','BEVEL');bevel.width=.18;bevel.segments=1
bpy.context.view_layer.objects.active=slab;bpy.ops.object.modifier_apply(modifier=bevel.name)

terrain_objects=[land,cliffs]
props=[]

def cone(name, pos, r1,r2,depth,mat,vertices=6):
    bpy.ops.mesh.primitive_cone_add(vertices=vertices,radius1=r1,radius2=r2,depth=depth,location=pos)
    ob=bpy.context.object;ob.name=name;ob.data.materials.append(mat);props.append(ob);return ob

for i in range(650):
    x=rng.uniform(50,4046);y=rng.uniform(-130,1490)
    if not is_land(x,y) or distance(routes_kd,x,y)<48 or distance(city_kd,x,y)<150:continue
    z=elevation(x,y)
    if z>.65:continue
    r,g,b=sample(x,y)
    green=x>2750 or (g>r*.91 and g>b*1.2)
    v=world(x,y,z)
    if green and rng.random()<.7:
        scale=rng.uniform(.6,1.4)
        cone('tree_trunk', (v[0],v[1],z+.16*scale),.022*scale,.015*scale,.32*scale,trunk_mat)
        if y<300:
            cone('conifer_lower',(v[0],v[1],z+.27*scale),.16*scale,.0,.35*scale,pine_mat)
            cone('conifer_upper',(v[0],v[1],z+.43*scale),.115*scale,.0,.3*scale,pine_mat)
        else:
            bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1,radius=.18*scale,location=(v[0],v[1],z+.35*scale))
            ob=bpy.context.object;ob.name='faceted_canopy';ob.scale=(1,1,.85);ob.data.materials.append(leaves_mat);props.append(ob)
    elif rng.random()<.27:
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1,radius=rng.uniform(.07,.16),location=(v[0],v[1],z+.04))
        ob=bpy.context.object;ob.name='sandstone_scatter';ob.scale=(1.3,.9,.65);ob.data.materials.append(rock_mat);props.append(ob)

# Add intentionally placed angular peaks outside all route/city safety corridors.
for cx,cy,rx,ry,amplitude in RIDGES:
    for j in range(6):
        x=cx+rng.uniform(-rx*.7,rx*.7);y=cy+rng.uniform(-ry*.5,ry*.5)
        if not is_land(x,y) or distance(routes_kd,x,y)<85 or distance(city_kd,x,y)<190:continue
        base=elevation(x,y)-.025
        px,py,_=world(x,y,base)
        radius=rng.uniform(.24,.52)
        peak_height=rng.uniform(.38,.95)*amplitude
        ring=[]
        for k in range(7):
            angle=2*math.pi*k/7
            r=radius*rng.uniform(.8,1.2)
            ring.append((px+math.cos(angle)*r,py+math.sin(angle)*r,base))
        top=(px+radius*.2,py-radius*.12,base+peak_height)
        peak=mesh('mountain_rock',ring+[top],[(k,(k+1)%7,7) for k in range(7)],[palette[8 if amplitude<1 else 9]])
        props.append(peak)
        if amplitude>=.95:
            snow_ring=[tuple(top[d]*.62+v[d]*.38 for d in range(3)) for v in ring]
            snow=mesh('mountain_snow',snow_ring+[tuple(top[d]+(.004 if d==2 else 0) for d in range(3))],[(k,(k+1)%7,7) for k in range(7)],[palette[11]])
            props.append(snow)

# Merge static vegetation and ridge details by material.
for mat in [trunk_mat,pine_mat,leaves_mat,rock_mat,palette[8],palette[9],palette[11]]:
    group=[o for o in props if o and o.name in bpy.data.objects and o.data.materials[0]==mat]
    if not group:continue
    bpy.ops.object.select_all(action='DESELECT')
    for o in group:o.select_set(True)
    bpy.context.view_layer.objects.active=group[0]
    bpy.ops.object.join()
    joined=bpy.context.object;joined.name='scatter_'+mat.name
    terrain_objects.append(joined)
    # Joining invalidates all but the active Blender object handles.
    props=[o for o in bpy.context.scene.objects if o.type=='MESH' and o.name.startswith(('tree_', 'conifer_', 'faceted_canopy', 'sandstone_scatter','mountain_'))]

def export(objects,path):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_yup=True,
                              export_apply=True,export_materials='EXPORT',export_cameras=False,export_lights=False)

export(terrain_objects,OUT/'terrain.glb')
export([water,slab],OUT/'water.glb')

# A real Blender render is retained alongside the editable scene.
scene=bpy.context.scene
scene.render.engine='CYCLES'
scene.cycles.samples=24
scene.render.resolution_x=1800;scene.render.resolution_y=1100;scene.render.resolution_percentage=100
scene.world.color=(.16,.20,.26)
scene.world.use_nodes=True
scene.world.node_tree.nodes['Background'].inputs[0].default_value=(.14,.18,.25,1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value=.45
bpy.ops.object.light_add(type='AREA',location=(-12,-6,20))
key=bpy.context.object;key.name='warm_key';key.data.energy=4500;key.data.shape='DISK';key.data.size=13;key.data.color=(1,.86,.68)
key.rotation_euler=(Vector((0,0,0))-key.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.object.light_add(type='AREA',location=(16,8,12))
fill=bpy.context.object;fill.name='cool_fill';fill.data.energy=1700;fill.data.size=16;fill.data.color=(.62,.78,1)
fill.rotation_euler=(-fill.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.object.camera_add(location=(4,-30,34))
camera=bpy.context.object;camera.name='world_preview_camera';camera.data.type='ORTHO';camera.data.ortho_scale=49
camera.rotation_euler=(Vector((0,0,0))-camera.location).to_track_quat('-Z','Y').to_euler();scene.camera=camera
scene.view_settings.view_transform='AgX'
scene.render.image_settings.file_format='PNG'
scene.render.filepath=str(PREVIEW/'world-terrain.png')
stats={
    'source':'real Blender mesh geometry; no texture planes',
    'coastline_layout_reference_sha256':hashlib.sha256(image_path.read_bytes()).hexdigest(),
    'projection':{'scale':.01,'center':[2048,681.5],'land_y':.08,'water_y':.03},
    'rules_geometry_unchanged':True,
    'terrain_objects':len(terrain_objects),
    'terrain_triangles':sum(sum(len(p.vertices)-2 for p in o.data.polygons) for o in terrain_objects),
    'water_triangles':sum(sum(len(p.vertices)-2 for p in o.data.polygons) for o in [water,slab]),
    'material_count':len({o.data.materials[p.material_index].name
                         for o in terrain_objects + [water, slab]
                         for p in o.data.polygons}),
}
(OUT/'world-stats.json').write_text(json.dumps(stats,indent=2)+'\n')
bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE/'world.blend'))
bpy.ops.render.render(write_still=True)
print('LOWPOLY_WORLD_COMPLETE',json.dumps(stats))
