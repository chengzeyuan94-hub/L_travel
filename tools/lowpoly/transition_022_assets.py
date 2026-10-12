#!/usr/bin/env python3
"""Author three editable 022 footing revisions from the actual frozen 020 source.

Blender --background --factory-startup --python-exit-code 1 --python
  tools/lowpoly/transition_022_assets.py

No planet/rule/020 asset is written. Original local coordinates and upper faces
are retained. Transition faces replace the original low-foot region; they are
not a second closed platter placed under the old one. Each asset has its own
Blender scene with Hero and Transition collections at the original origin.
"""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import sys
import struct
import shutil
import tempfile
import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'docs/design/landmark-library-020'
OUT = ROOT / 'docs/design/terrain-transition-022'
IDS = {'everest': 'south', 'taklamakan_dunes': 'south', 'tigris_meander': 'west'}
CONFIG = {
    'everest': dict(cutoff=.82, start=.55, expansion=.115, amplitude=.24,
                    color='B7A888', motifs=['three unequal low rock shoulders', 'open valley-mouth fan']),
    'taklamakan_dunes': dict(cutoff=.34, start=.47, expansion=.118, amplitude=.105,
                    color='D6B779', motifs=['three low wind-aligned sand tongues', 'unequal open sand saddles']),
    'tigris_meander': dict(cutoff=.24, start=.56, expansion=.108, amplitude=.050,
                    color='BCAD79', motifs=['unequal upstream/downstream alluvial banks', 'low dry outer floodplain']),
}


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def clamp(x, a=0., b=1.): return min(b, max(a, x))
def smooth(a, b, x):
    t = clamp((x-a)/(b-a)); return t*t*(3-2*t)
def key(p): return tuple(round(float(x), 6) for x in p)
def lerp(a, b, t): return a+(b-a)*t
def linear(x): return x/12.92 if x < .04045 else ((x+.055)/1.055)**2.4
def color_hex(s): return tuple(linear(int(s[i:i+2],16)/255.) for i in (0,2,4))
def angle_lobe(a, center, width):
    d = math.atan2(math.sin(a-center), math.cos(a-center))
    return math.exp(-(d/width)**2)


def appearance(mat):
    if mat.use_nodes:
        bsdf = next((n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
        if bsdf: return tuple(bsdf.inputs['Base Color'].default_value)
    return tuple(mat.diffuse_color)


def append_source(aid, group):
    source = SOURCE / f'source/{group}.blend'
    with bpy.data.libraries.load(str(source), link=False) as (old, new):
        new.objects = [n for n in old.objects if n.startswith(aid+'_')]
    objects = [o for o in new.objects if o and o.type == 'MESH']
    assert objects, aid
    # 020 .blend has a documented gallery translation only. Mesh coordinates
    # already have the exact centering shift applied to the exported geometry.
    for obj in objects:
        assert tuple(obj.scale) == (1.,1.,1.) and all(abs(a)<1e-9 for a in obj.rotation_euler)
        obj.location = (0,0,0)
    return objects


def extract(objects):
    triangles = []
    for obj in objects:
        mesh = obj.data
        assert not mesh.validate(verbose=False), (obj.name, 'invalid frozen source')
        mesh.calc_loop_triangles()
        for tri in mesh.loop_triangles:
            mat = mesh.materials[tri.material_index]
            triangles.append({'p':[tuple(mesh.vertices[i].co) for i in tri.vertices], 'mat':mat,
                              'original_object':obj.name})
    return triangles


def natural(mat, aid):
    name = mat.name.split('.')[0].lower()
    return name in ({'rock','rock_dark','rock_light','slate'} if aid == 'everest' else
                    {'sand','sand_dark','sand_light'} if aid == 'taklamakan_dunes' else
                    {'earth','grass','sand','sand_light','mud'})


def bounds(triangles):
    pp = [p for t in triangles for p in t['p']]
    return {'min':[min(p[i] for p in pp) for i in range(3)],
            'max':[max(p[i] for p in pp) for i in range(3)]}


def triangle_fingerprint(triangles):
    records = []
    for t in triangles:
        # Keep winding while allowing a different first corner.
        p = [key(x) for x in t['p']]
        cycles = [tuple(p[i:]+p[:i]) for i in range(3)]
        records.append((t['mat'].name.split('.')[0], min(cycles)))
    return hashlib.sha256(repr(sorted(records)).encode()).hexdigest()


def outline_radius(p, extents):
    return math.hypot(p[0]/extents[0], p[1]/extents[1])


def weight(p, cfg, extents):
    r = outline_radius(p, extents)
    return smooth(cfg['start'], .89, r) * (1-smooth(cfg['cutoff']*.52, cfg['cutoff'], p[2]))


def split_transition(triangles, protected_edges):
    """Conforming longest-edge split, including matching edges in both faces.

    Original Hero/Transition edges are never split. Every other marked edge has
    exactly one common midpoint, so subdivision cannot introduce T-junctions.
    """
    marks = {}
    for t in triangles:
        for i in range(3):
            a,b = t['p'][i], t['p'][(i+1)%3]
            ek = tuple(sorted((key(a), key(b))))
            if ek not in protected_edges and math.dist(a,b) > .14:
                marks[ek] = tuple((a[j]+b[j])*.5 for j in range(3))
    out = []
    for t in triangles:
        a,b,c = t['p']; pp=[a,b,c]
        midpoint = [marks.get(tuple(sorted((key(pp[i]),key(pp[(i+1)%3]))))) for i in range(3)]
        n = sum(x is not None for x in midpoint)
        if n == 0: faces = [[a,b,c]]
        elif n == 3:
            ab,bc,ca=midpoint; faces=[[a,ab,ca],[ab,b,bc],[ca,bc,c],[ab,bc,ca]]
        elif n == 1:
            i=next(i for i,v in enumerate(midpoint) if v is not None)
            x,y,z=pp[i],pp[(i+1)%3],pp[(i+2)%3]; m=midpoint[i]
            faces=[[x,m,z],[m,y,z]]
        else:
            # Two adjacent marked edges, rotate shared corner into y.
            i=next(i for i in range(3) if midpoint[i] is not None and midpoint[(i+1)%3] is not None)
            x,y,z=pp[i],pp[(i+1)%3],pp[(i+2)%3]; m,nm=midpoint[i],midpoint[(i+1)%3]
            faces=[[x,m,z],[m,nm,z],[m,y,nm]]
        out += [{**t,'p':f} for f in faces]
    return out, len(marks)


def profile(aid, p, cfg, extents):
    x,y,z = p; r=outline_radius(p,extents); a=math.atan2(y/extents[1],x/extents[0])
    if aid == 'everest':
        lobes=max(angle_lobe(a,-2.68,.33), .89*angle_lobe(a,-.70,.38),
                  .66*angle_lobe(a,.16,.30), .72*angle_lobe(a,-1.52,.46))
        shoulder=max(math.exp(-((y+.52+.28*x)/.19)**2)*smooth(.45,1.15,abs(x)),
                     .78*math.exp(-((y+.97-.13*x)/.27)**2),
                     .58*math.exp(-((y-.28+.12*x)/.20)**2)*smooth(.55,1.3,x))
        # The central valley remains lower than either side shoulder.
        shoulder *= 1-.70*math.exp(-((x-.03)/.35)**2)*smooth(.3,1.,-y)
    elif aid == 'taklamakan_dunes':
        lobes=max(angle_lobe(a,-.33,.34), .82*angle_lobe(a,.43,.31),
                  .74*angle_lobe(a,2.74,.35), .91*angle_lobe(a,-2.71,.35))
        shoulder=max(math.exp(-((y+.68-.09*x)/.19)**2),
                     .82*math.exp(-((y-.04+.06*x)/.20)**2),
                     .70*math.exp(-((y-.68-.10*x)/.22)**2))
        shoulder *= .72+.28*smooth(-1.,1.,x)
    else:
        lobes=max(angle_lobe(a,1.25,.28), .76*angle_lobe(a,-1.90,.33),
                  .30*angle_lobe(a,.10,.45))
        shoulder=max(math.exp(-((x-.67+.14*y)/.28)**2)*smooth(.3,1.,y),
                     .69*math.exp(-((x+.74+.12*y)/.38)**2)*smooth(.3,1.,-y))
    # Most sides do not expand: scalloped recesses separate the few tongues.
    radial = cfg['expansion']*lobes - .030*(1-lobes)
    toe = smooth(.62,1.0,r)
    t = clamp((r-cfg['start'])/(1.01-cfg['start']))
    relief = 4*t*(1-t) * cfg['amplitude'] * shoulder
    new_z = max(0., z*(1-.52*smooth(.62,.98,r)) + relief)
    # Boundary vertices and the underside stay at exactly zero local height.
    if abs(z) < 2e-7: new_z=0.
    return (x*(1+radial*toe),y*(1+radial*toe),new_z), lobes


def footing_field(foot, joint_keys, aid, cfg, extents):
    """Positive-weight harmonic field over the actual upper footing triangles.

    Joining vertices are Dirichlet zero and free zero-height toes are one.
    Underside edges never become shortcuts across the field: their weights
    are interpolated vertically from the upper surface, or zero under Hero.
    """
    points={};adjacency=defaultdict(dict);upper=[]
    for t in foot:
        p=t['p'];normal=(Vector(p[1])-Vector(p[0])).cross(Vector(p[2])-Vector(p[0]))
        if normal.z <= 1e-10:continue
        upper.append(t)
        for v in p:points[key(v)]=v
        for i in range(3):
            a,b=key(p[i]),key(p[(i+1)%3])
            d=math.hypot(p[i][0]-p[(i+1)%3][0],p[i][1]-p[(i+1)%3][1])
            if a!=b and d>1e-9:
                adjacency[a][b]=1/max(.003,d);adjacency[b][a]=adjacency[a][b]
    assert upper
    toes={k for k,p in points.items() if abs(p[2])<2e-7 and k not in joint_keys}
    fixed={k:0. for k in joint_keys if k in points};fixed.update({k:1. for k in toes})
    field={k:fixed.get(k,smooth(cfg['start'],.95,outline_radius(p,extents))) for k,p in points.items()}
    neighbors={k:(tuple(adjacency[k].items()),sum(adjacency[k].values())) for k in points}
    for iterations in range(600):
        next_field=field.copy();change=0.
        for k in points:
            if k in fixed:continue
            nn,total=neighbors[k]
            if total==0:continue
            value=sum(field[j]*w for j,w in nn)/total
            next_field[k]=value;change=max(change,abs(value-field[k]))
        field=next_field
        if change<2e-7:break
    # Screened Laplacian keeps the broad authored shoulders/tongues while
    # removing pointwise near-joint peaks and irregular triangulation noise.
    guide={k:lerp(p[2],profile(aid,p,cfg,extents)[0][2],field[k]) for k,p in points.items()}
    height=guide.copy()
    for _ in range(72):
        updated=height.copy()
        for k,p in points.items():
            if k in joint_keys or k in toes:updated[k]=p[2];continue
            nn,total=neighbors[k]
            if total>0:updated[k]=.16*guide[k]+.84*sum(height[j]*w for j,w in nn)/total
        height=updated
    from mathutils.bvhtree import BVHTree
    verts=[];faces=[];keys=[]
    for t in upper:
        i=len(verts);verts.extend(Vector(p) for p in t['p']);keys.extend(key(p) for p in t['p']);faces.append((i,i+1,i+2))
    bvh=BVHTree.FromPolygons(verts,faces,all_triangles=True)
    def sample(p):
        k=key(p)
        if k in field:return field[k],height[k]
        if k in joint_keys:return 0.,p[2]
        hit,_,index,_=bvh.ray_cast(Vector((p[0],p[1],10)),Vector((0,0,-1)),20)
        if hit is None:return 0.,p[2]
        ii=faces[index];a,b,c=[verts[j] for j in ii]
        den=(b.y-c.y)*(a.x-c.x)+(c.x-b.x)*(a.y-c.y)
        if abs(den)<1e-14:return 0.,p[2]
        aa=((b.y-c.y)*(p[0]-c.x)+(c.x-b.x)*(p[1]-c.y))/den
        bb=((c.y-a.y)*(p[0]-c.x)+(a.x-c.x)*(p[1]-c.y))/den
        value=sum(field[keys[j]]*w for j,w in zip(ii,(aa,bb,1-aa-bb)))
        return clamp(value),p[2]  # Keep the real underside flat in source.
    return sample,{'method':'positive inverse-edge-length harmonic field on upper transition mesh; joins 0 / free toes 1',
                  'iterations':iterations+1,'top_vertices':len(points),'free_toe_vertices':len(toes),
                  'fixed_join_vertices':len(set(points)&joint_keys),'height_smoothing_steps':72}


def emit(collection, name, triangles, material=None, colors=None):
    if not triangles: return None
    vv=[]; ff=[]
    for t in triangles:
        i=len(vv); vv.extend(t['p']); ff.append((i,i+1,i+2))
    mesh=bpy.data.meshes.new(name); mesh.from_pydata(vv,[],ff)
    mesh.materials.append(material or triangles[0]['mat']); mesh.update()
    assert not mesh.validate(verbose=False), (name, 'new invalid mesh')
    for p in mesh.polygons:p.use_smooth=False
    if colors is not None:
        layer=mesh.color_attributes.new(name='Color',type='FLOAT_COLOR',domain='CORNER')
        for i,col in enumerate(colors):layer.data[i].color=col
        mesh.color_attributes.active_color=layer
    obj=bpy.data.objects.new(name,mesh);collection.objects.link(obj)
    obj['asset_kind']='silkroad_transition_022';obj['coordinate_contract']='020 original local anchor; unit scale; no recenter'
    return obj


def transition_material(aid):
    mat=bpy.data.materials.new(f'{aid}_TransitionVertexColor')
    mat.diffuse_color=(1,1,1,1);mat.use_nodes=True;mat.use_backface_culling=True
    bsdf=mat.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value=(1,1,1,1);bsdf.inputs['Roughness'].default_value=.9
    color=mat.node_tree.nodes.new('ShaderNodeVertexColor');color.layer_name='Color'
    mat.node_tree.links.new(color.outputs['Color'],bsdf.inputs['Base Color'])
    return mat


def build_asset(aid, group, output):
    source_objects=append_source(aid,group);original=extract(source_objects)
    original_bounds=bounds(original)
    cfg=CONFIG[aid]
    extents=[max(abs(original_bounds['min'][i]),abs(original_bounds['max'][i])) for i in range(2)]
    hero=[];foot=[]
    for t in original:
        eligible=natural(t['mat'],aid) and max(p[2] for p in t['p'])<cfg['cutoff']
        active=eligible and any(weight(p,cfg,extents)>.015 for p in t['p'])
        (foot if active else hero).append(t)
    hero_points={key(p):p for t in hero for p in t['p']}
    foot_keys={key(p) for t in foot for p in t['p']}
    joint_keys=set(hero_points)&foot_keys
    protected_edges=set()
    for t in hero:
        for i in range(3):
            protected_edges.add(tuple(sorted((key(t['p'][i]),key(t['p'][(i+1)%3])))))
    original_foot_count=len(foot)
    foot,refined_edges=split_transition(foot,protected_edges)
    sample_field,field_info=footing_field(foot,joint_keys,aid,cfg,extents)
    moved={};weights={};originals={};max_motion=0.;changed=0;target=color_hex(cfg['color'])
    for t in foot:
        for p in t['p']:
            k=key(p)
            if k in moved:continue
            originals[k]=p
            w,height=sample_field(p)
            if k in joint_keys:w=0.;height=p[2]
            q,_=profile(aid,p,cfg,extents)
            moved[k]=(lerp(p[0],q[0],w),lerp(p[1],q[1],w),height)
            weights[k]=w
        t['old_p']=t['p']
    # One common amplitude for the entire footprint: never pinch individual
    # vertices to repair a triangle, as this made the first candidate noisy.
    proposed=moved.copy();xy_amplitude=1.;safety_passes=0
    for safety_passes in range(40):
        bad=False
        for t in foot:
            old=t['old_p'];new=[moved[key(p)] for p in old]
            oa=(old[1][0]-old[0][0])*(old[2][1]-old[0][1])-(old[1][1]-old[0][1])*(old[2][0]-old[0][0])
            na=(new[1][0]-new[0][0])*(new[2][1]-new[0][1])-(new[1][1]-new[0][1])*(new[2][0]-new[0][0])
            if abs(oa)>1e-10 and na*oa < -1e-12:bad=True;break
        if not bad:break
        xy_amplitude*=.75
        for k,q in proposed.items():
            p=originals[k];moved[k]=(lerp(p[0],q[0],xy_amplitude),lerp(p[1],q[1],xy_amplitude),q[2])
    for t in foot:t['p']=[moved[key(p)] for p in t['old_p']]
    for k,q in moved.items():
        d=math.dist(originals[k],q);max_motion=max(max_motion,d);changed+=int(d>1e-8)
    scene=bpy.data.scenes.new(aid)
    asset=bpy.data.collections.new(aid);scene.collection.children.link(asset)
    hero_collection=bpy.data.collections.new('Hero_'+aid);asset.children.link(hero_collection)
    transition_collection=bpy.data.collections.new('Transition_'+aid);asset.children.link(transition_collection)
    objects=[]
    by_mat=defaultdict(list)
    for t in hero:by_mat[t['mat']].append(t)
    for mat,triangles in by_mat.items():
        objects.append(emit(hero_collection,f'{aid}_Hero_{mat.name}',triangles,mat))
    colors=[]
    for t in foot:
        original_color=appearance(t['mat'])
        for old in t['old_p']:
            r=outline_radius(old,extents)
            fade=weights[key(old)]*smooth(.65,.99,r)*.72
            colors.append(tuple(lerp(original_color[i],target[i],fade) for i in range(3))+(1.,))
    objects.append(emit(transition_collection,f'{aid}_Transition_Footing',foot,transition_material(aid),colors))
    for obj in objects:obj['asset_id']=aid
    # Bind fitting metadata to exported float32 coordinates, not pre-export
    # Python doubles. Runtime lookup survives normal/material vertex splits.
    transition_obj=objects[-1]
    by_new={key(struct.unpack('<3f',struct.pack('<3f',*moved[k]))):k for k in moved}
    fit=[]
    seen=set()
    for v in transition_obj.data.vertices:
        p=tuple(v.co);pk=key(p)
        if pk in seen:continue
        seen.add(pk)
        original_key=by_new[pk]
        w=weights[original_key]
        # Use the same continuous field as the authoring geometry. No
        # nearest-point distance wells at individual fixed junction vertices.
        fit_w=0. if original_key in joint_keys else weights[original_key]
        fit.append({'position':[p[0],p[2],-p[1]],'weight':fit_w})
    fit_payload={'asset_id':aid,'coordinate_system':'Godot local Y-up; exact exported float32 positions',
                 'mesh_name':transition_obj.name,'key_precision_world':0.00001,
                 'vertices':fit,'hero_join_positions':[[p[0],p[2],-p[1]] for p in (hero_points[k] for k in sorted(joint_keys))],
                 'rule':'Only Transition vertices may fit; all Hero vertices and all exact shared joins remain rigid.',
                 'outer_toe_note':'Free outer toes approach weight 1; joins touching frozen water/hero stay 0 even at perimeter.'}
    fit_path=output/f'exports/{aid}-fit.json'
    fit_path.write_text(json.dumps(fit_payload,ensure_ascii=False,separators=(',',':'))+'\n')
    all_faces=hero+foot
    new_bounds=bounds(all_faces)
    ratios=[(new_bounds['max'][i]-new_bounds['min'][i])/(original_bounds['max'][i]-original_bounds['min'][i]) for i in range(2)]
    assert max(ratios)<=1.121,(aid,'footprint exceeded 12%',ratios)
    assert abs(new_bounds['max'][2]-original_bounds['max'][2])<1e-7
    # Every Hero face keeps its input material and original winding/coordinates.
    original_hero_hash=triangle_fingerprint(hero)
    hero_output=extract([o for o in objects if '_Hero_' in o.name])
    assert triangle_fingerprint(hero_output)==original_hero_hash,(aid,'hero changed during mesh reconstruction')
    # Manifold counts are diagnostic: all original objects can include open
    # palm leaves. We explicitly verify the Hero/Transition shared junction.
    inverted=[]
    for i,t in enumerate(foot):
        old=t['old_p'];new=t['p']
        old_normal=(Vector(old[1])-Vector(old[0])).cross(Vector(old[2])-Vector(old[0]))
        new_normal=(Vector(new[1])-Vector(new[0])).cross(Vector(new[2])-Vector(new[0]))
        if abs(old_normal.z)>1e-10 and new_normal.z*old_normal.z < -1e-12:inverted.append(i)
    assert not inverted,(aid,'deformation reversed faces',len(inverted))
    changed_joint=[k for k in joint_keys if math.dist(moved[k],hero_points[k])>2e-6]
    assert not changed_joint,(aid,'shared joint moved')
    record={'id':aid,'source_asset':str((SOURCE/f'exports/{aid}.glb').relative_to(ROOT)),
            'source_glb_sha256':sha(SOURCE/f'exports/{aid}.glb'),
            'source_blend':str((SOURCE/f'source/{group}.blend').relative_to(ROOT)),
            'source_blend_sha256':sha(SOURCE/f'source/{group}.blend'),
            'triangles_before':len(original),'triangles':len(all_faces),'triangle_delta':len(all_faces)-len(original),
            'hero_triangles':len(hero),'original_foot_triangles_replaced':original_foot_count,
            'transition_triangles':len(foot),'refined_shared_edges':refined_edges,
            'changed_unique_foot_vertices':changed,'maximum_local_vertex_motion':max_motion,
            'xy_uniform_amplitude':xy_amplitude,'xy_safety_passes':safety_passes,'continuous_field':field_info,
            'original_bounds_blender_xyz':original_bounds,'bounds_blender_xyz':new_bounds,
            'horizontal_span_ratios':ratios,'local_anchor':[0,0,0],'scale':[1,1,1],
            'hero_face_sha256':original_hero_hash,'hero_unchanged':True,
            'joint_vertices':len(joint_keys),'maximum_joint_gap':0.,'inverted_transition_faces':len(inverted),
            'fit_json':str(fit_path.relative_to(output)),'fit_sha256':sha(fit_path),'fit_vertex_count':len(fit),
            'meshes':len(objects),'materials':len({o.data.materials[0].name for o in objects}),
            'motifs':cfg['motifs'],'transition_material':'white albedo; COLOR_0 linear RGB includes original material color',
            'bounds_godot':{'min':[new_bounds['min'][0],new_bounds['min'][2],-new_bounds['max'][1]],
                            'max':[new_bounds['max'][0],new_bounds['max'][2],-new_bounds['min'][1]]},
            'config':cfg,'glb':f'exports/{aid}.glb','blend':'source/transition-models.blend',
            'scene':aid,'authoring_note':'Hero/Transition partition replaces old low foot; no second closed pedestal. Original anchor preserved.'}
    for obj in source_objects:bpy.data.objects.remove(obj,do_unlink=True)
    return scene,objects,record


def _inside_polygon(p, polygon):
    inside=False;x,y=p
    for a,b in zip(polygon,polygon[1:]+polygon[:1]):
        if (a[1]>y)!=(b[1]>y) and x<(b[0]-a[0])*(y-a[1])/(b[1]-a[1])+a[0]:inside=not inside
    return inside


def _wide_outline(aid, extents):
    controls=([(-1.30,-.65),(-1.35,-.10),(-1.05,.50),(-.58,1.12),(.05,1.28),(.65,1.20),
               (1.14,.71),(1.40,.18),(1.20,-.43),(.78,-1.10),(.13,-1.38),(-.40,-1.12),(-.90,-1.25)]
              if aid=='everest' else
              [(-1.32,-.98),(-1.35,-.25),(-1.13,.10),(-1.39,.60),(-1.12,1.20),(-.42,1.15),
               (.10,1.02),(.74,1.15),(1.32,1.12),(1.16,.47),(1.42,.12),(1.20,-.47),(.95,-1.20),
               (.33,-1.12),(-.30,-1.03),(-.92,-1.20)])
    points=[];n=len(controls)
    for i in range(n):
        pp=[controls[(i+k)%n] for k in (-1,0,1,2)]
        for j in range(6):
            t=j/6
            points.append(tuple(.5*((2*pp[1][d])+(-pp[0][d]+pp[2][d])*t+
                (2*pp[0][d]-5*pp[1][d]+4*pp[2][d]-pp[3][d])*t*t+
                (-pp[0][d]+3*pp[1][d]-3*pp[2][d]+pp[3][d])*t*t*t) for d in range(2)))
    targets=(1.35,1.30) if aid=='everest' else (1.37,1.28)
    scales=[2*extents[i]*targets[i]/(max(p[i] for p in points)-min(p[i] for p in points)) for i in range(2)]
    points=[tuple(p[i]*scales[i] for i in range(2)) for p in points]
    area=sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(points,points[1:]+points[:1]))
    if area<0:points.reverse()
    return points


def _triangulated_wide_foot(hero, original, aid, cfg, extents):
    from mathutils.bvhtree import BVHTree
    from mathutils.geometry import delaunay_2d_cdt
    points_by_key={};counter=Counter()
    for t in hero:
        for p in t['p']:points_by_key[key(p)]=p
        for i in range(3):counter[tuple(sorted((key(t['p'][i]),key(t['p'][(i+1)%3]))))]+=1
    border_edges=[edge for edge,count in counter.items() if count==1]
    joint_keys={k for edge in border_edges for k in edge}
    hv=[];hf=[]
    for t in hero:
        i=len(hv);hv.extend(Vector(p) for p in t['p']);hf.append((i,i+1,i+2))
    hbvh=BVHTree.FromPolygons(hv,hf,all_triangles=True)
    def on_hero(p):return hbvh.ray_cast(Vector((p[0],p[1],10)),Vector((0,0,-1)),20)[0] is not None
    outline=_wide_outline(aid,extents)
    points=list(outline);edges=[(i,(i+1)%len(outline)) for i in range(len(outline))]
    join_input={};key_indices={}
    for k in sorted(joint_keys):
        index=len(points);points.append(points_by_key[k][:2]);join_input[index]=points_by_key[k];key_indices[k]=index
    edges += [(key_indices[a],key_indices[b]) for a,b in border_edges]
    lo=[min(p[i] for p in outline) for i in range(2)];hi=[max(p[i] for p in outline) for i in range(2)]
    spacing=.13 if aid=='everest' else .12
    nx=math.ceil((hi[0]-lo[0])/spacing);ny=math.ceil((hi[1]-lo[1])/spacing)
    from mathutils.kdtree import KDTree
    kt=KDTree(len(points))
    for i,p in enumerate(points):kt.insert(Vector((p[0],p[1],0)),i)
    kt.balance()
    for j in range(1,ny):
        for i in range(1,nx):
            x=lo[0]+(i+.10*math.sin(i*2.1+j*1.4))*(hi[0]-lo[0])/nx
            y=lo[1]+(j+.10*math.sin(i*1.3-j*2.3))*(hi[1]-lo[1])/ny
            if _inside_polygon((x,y),outline) and not on_hero((x,y)):
                if kt.find(Vector((x,y,0)))[2]>.035:points.append((x,y))
    coords,_,faces,origins,_,_=delaunay_2d_cdt([Vector(p) for p in points],edges,[],0,1e-7,True)
    coords=[tuple(p) for p in coords]
    joins={};toes=set()
    for i,sources in enumerate(origins):
        inputs=[j for j in sources if j in join_input]
        if inputs:
            p=join_input[inputs[0]];coords[i]=p[:2];joins[i]=p[2]
        if any(j<len(outline) for j in sources):toes.add(i)
    top_faces=[];all_faces=[]
    for f in faces:
        assert len(f)==3
        pp=[coords[i] for i in f];center=tuple(sum(p[k] for p in pp)/3 for k in range(2))
        if not _inside_polygon(center,outline):continue
        area=(pp[1][0]-pp[0][0])*(pp[2][1]-pp[0][1])-(pp[1][1]-pp[0][1])*(pp[2][0]-pp[0][0])
        face=tuple(f) if area>0 else (f[0],f[2],f[1]);all_faces.append(face)
        if not on_hero(center):top_faces.append(face)
    used={i for f in top_faces for i in f}
    adjacency=defaultdict(dict)
    for f in top_faces:
        for a,b in zip(f,f[1:]+f[:1]):
            d=math.dist(coords[a],coords[b]);adjacency[a][b]=1/max(.015,d);adjacency[b][a]=adjacency[a][b]
    neighbors={i:(tuple(adjacency[i].items()),sum(adjacency[i].values())) for i in used}
    fixed_w={i:0. for i in joins if i in used};fixed_w.update({i:1. for i in toes if i in used})
    fixed_h={i:h for i,h in joins.items() if i in used};fixed_h.update({i:0. for i in toes if i in used})
    weights={i:fixed_w.get(i,.5) for i in used};heights={i:fixed_h.get(i,.12) for i in used}
    for iteration in range(1200):
        ww=weights.copy();hh=heights.copy();change=0.
        for i in used:
            if i in fixed_w:continue
            nn,total=neighbors[i]
            if total==0:continue
            ww[i]=sum(weights[j]*w for j,w in nn)/total;hh[i]=sum(heights[j]*w for j,w in nn)/total
            change=max(change,abs(ww[i]-weights[i]),abs(hh[i]-heights[i]))
        weights=ww;heights=hh
        if change<2e-7:break
    # Add only broad directional relief to the new free area, vanishing at
    # both fixed interfaces. Peaks and all original Hero geometry stay rigid.
    for i in used:
        if i in fixed_h:continue
        x,y=coords[i];w=weights[i];window=4*w*(1-w)
        if aid=='everest':
            shoulders=max(.18*math.exp(-((y+.64+.31*x)/.35)**2)*smooth(.65,1.8,abs(x)),
                          .13*math.exp(-((y-.29+.10*x)/.34)**2)*smooth(.8,1.8,x))
            fan=.065*math.exp(-((x+.07)/1.1)**2-((y+1.32)/.65)**2)
            relief=shoulders+fan
        else:
            relief=max(.075*math.exp(-((y+.73-.09*x)/.25)**2),
                       .058*math.exp(-((y-.03+.055*x)/.24)**2),
                       .043*math.exp(-((y-.71-.075*x)/.27)**2))*smooth(.5,1.3,abs(x))
        heights[i]+=window*relief
    mat=next(t['mat'] for t in original if t['mat'].name.split('.')[0]==('slate' if aid=='everest' else 'sand'))
    foot=[]
    for f in top_faces:
        foot.append({'p':[(coords[i][0],coords[i][1],heights[i]) for i in f], 'mat':mat,
                     'weights':[weights[i] for i in f],'surface_role':'top'})
    # One new continuous underside replaces the complete old underside.
    # Its per-XY fitting values match the visible surface wherever present.
    for f in all_faces:
        f=(f[0],f[2],f[1])
        foot.append({'p':[(coords[i][0],coords[i][1],0.) for i in f], 'mat':mat,
                     'weights':[weights.get(i,0.) for i in f],'surface_role':'underside'})
    info={'method':'new constrained triangulation between exact original Hero border and directional wide toe; original low foot and underside removed',
          'outer_vertices':len(outline),'top_triangles':len(top_faces),'underside_triangles':len(all_faces),
          'fixed_join_vertices':len(joins),'harmonic_iterations':iteration+1,'harmonic_final_step':change,
          'grid_spacing':spacing,'source_upper_join_points':[points_by_key[k] for k in sorted(joint_keys)]}
    return foot,info


def build_wide_asset(aid, group, output):
    source_objects=append_source(aid,group);original=extract(source_objects);bb=bounds(original)
    extents=[max(abs(bb['min'][i]),abs(bb['max'][i])) for i in range(2)]
    cfg={**CONFIG[aid],'authoring_revision':'wide-footing-3','requested_span':([1.35,1.30] if aid=='everest' else [1.37,1.28])}
    hero=[];demoted=[]
    for t in original:
        p=t['p'];n=(Vector(p[1])-Vector(p[0])).cross(Vector(p[2])-Vector(p[0]))
        mat=t['mat'].name.split('.')[0]
        preserve=n.z>1e-10 and ((mat in ['ice','snow'] or max(v[2] for v in p)>=.82) if aid=='everest' else max(v[2] for v in p)>=.235)
        (hero if preserve else demoted).append(t)
    foot,info=_triangulated_wide_foot(hero,original,aid,cfg,extents)
    scene=bpy.data.scenes.new(aid);asset=bpy.data.collections.new(aid);scene.collection.children.link(asset)
    hc=bpy.data.collections.new('Hero_'+aid);asset.children.link(hc)
    tc=bpy.data.collections.new('Transition_'+aid);asset.children.link(tc)
    objects=[];by_mat=defaultdict(list)
    for t in hero:by_mat[t['mat']].append(t)
    for mat,tris in by_mat.items():objects.append(emit(hc,f'{aid}_Hero_{mat.name}',tris,mat))
    colors=[];target=color_hex(cfg['color']);base=appearance(foot[0]['mat'])
    for t in foot:
        for w in t['weights']:
            fade=smooth(.05,1.,w)*.87
            colors.append(tuple(lerp(base[i],target[i],fade) for i in range(3))+(1.,))
    obj=emit(tc,f'{aid}_Transition_Footing',foot,transition_material(aid),colors);objects.append(obj)
    # Use actual exported float32 vertex coordinates for the contact adapter.
    raw_weights={}
    for t in foot:
        for p,w in zip(t['p'],t['weights']):
            kk=key(struct.unpack('<3f',struct.pack('<3f',*p)))
            if kk in raw_weights:assert abs(raw_weights[kk]-w)<2e-6,(aid,'split toe fit differs')
            raw_weights[kk]=w
    fit=[];seen=set()
    for v in obj.data.vertices:
        p=tuple(v.co);kk=key(p)
        if kk in seen:continue
        seen.add(kk);fit.append({'position':[p[0],p[2],-p[1]],'weight':raw_weights[kk]})
    join_positions=info.pop('source_upper_join_points')
    fit_path=output/f'exports/{aid}-fit.json'
    fit_payload={'asset_id':aid,'coordinate_system':'Godot local Y-up; exact exported float32 positions','mesh_name':obj.name,
                 'key_precision_world':.00001,'vertices':fit,'hero_join_positions':[[p[0],p[2],-p[1]] for p in join_positions],
                 'rule':'Only Transition fits: exact original Hero join=0, directional free toe=1; one newly triangulated foot replaces old low foot.'}
    fit_path.write_text(json.dumps(fit_payload,separators=(',',':'))+'\n')
    nb=bounds(hero+foot);ratios=[(nb['max'][i]-nb['min'][i])/(bb['max'][i]-bb['min'][i]) for i in range(2)]
    assert all(1.25<=r<=1.401 for r in ratios),(aid,ratios)
    assert abs(nb['max'][2]-bb['max'][2])<1e-7
    assert triangle_fingerprint(extract(objects[:-1]))==triangle_fingerprint(hero)
    record={'id':aid,'source_asset':str((SOURCE/f'exports/{aid}.glb').relative_to(ROOT)),'source_glb_sha256':sha(SOURCE/f'exports/{aid}.glb'),
            'source_blend':str((SOURCE/f'source/{group}.blend').relative_to(ROOT)),'source_blend_sha256':sha(SOURCE/f'source/{group}.blend'),
            'triangles_before':len(original),'triangles':len(hero)+len(foot),'triangle_delta':len(hero)+len(foot)-len(original),
            'hero_triangles':len(hero),'original_foot_triangles_replaced':len(demoted),'transition_triangles':len(foot),
            'original_bounds_blender_xyz':bb,'bounds_blender_xyz':nb,'horizontal_span_ratios':ratios,'local_anchor':[0,0,0],'scale':[1,1,1],
            'hero_face_sha256':triangle_fingerprint(hero),'hero_unchanged':True,'hero_protection_scope':('all original ice/snow and top rock triangles reaching localZ .82; old lower rock and underside rebuilt' if aid=='everest' else 'original upper dune faces reaching localZ .235; old low windward/toe faces and entire underside rebuilt'),
            'protection_changed_from_pass2':True,'joint_vertices':len(join_positions),'maximum_joint_gap':0.,'fit_json':str(fit_path.relative_to(output)),
            'fit_sha256':sha(fit_path),'fit_vertex_count':len(fit),'meshes':len(objects),'materials':len(objects),'motifs':cfg['motifs'],
            'transition_material':'white albedo; COLOR_0 linear RGB includes original material color',
            'bounds_godot':{'min':[nb['min'][0],nb['min'][2],-nb['max'][1]],'max':[nb['max'][0],nb['max'][2],-nb['min'][1]]},
            'config':cfg,'glb':f'exports/{aid}.glb','blend':'source/transition-models.blend','scene':aid,'wide_geometry':info,
            'authoring_note':'Real directional wide low terrain replaces old closed low foot. One welded heightfield body; original Hero and local anchor unchanged.'}
    for ob in source_objects:bpy.data.objects.remove(ob,do_unlink=True)
    return scene,objects,record


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,default=OUT);parser.add_argument('--ids',default=','.join(IDS))
    opt=parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    out=opt.output; (out/'source').mkdir(parents=True,exist_ok=True);(out/'exports').mkdir(exist_ok=True)
    bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
    selected=opt.ids.split(',');assert set(selected)<=set(IDS)
    prior=json.loads((out/'asset-catalog.json').read_text()) if (out/'asset-catalog.json').exists() else {'assets':[]}
    preserved={a['id']:a for a in prior['assets'] if a['id'] not in selected}
    records=[]
    for aid,group in IDS.items():
        if aid not in selected:continue
        scene,objects,record=(build_wide_asset if aid in ['everest','taklamakan_dunes'] else build_asset)(aid,group,out)
        bpy.context.window.scene=scene
        bpy.ops.object.select_all(action='DESELECT')
        for obj in objects:obj.select_set(True)
        bpy.context.view_layer.objects.active=objects[0]
        path=out/record['glb']
        bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_apply=True,
            export_yup=True,export_animations=False,export_materials='EXPORT',export_cameras=False,
            export_lights=False,export_extras=True,export_all_vertex_colors=True)
        assert sum(len(o.data.polygons) for o in objects)==record['triangles']
        record.update(sha256=sha(path),bytes=path.stat().st_size)
        records.append(record);print('TRANSITION_022_EXPORTED',aid,record['triangles'],record['horizontal_span_ratios'],flush=True)
    if preserved:
        with tempfile.TemporaryDirectory(prefix='transition_022_preserve_') as tmp:
            retained=Path(tmp)/'retained.blend';shutil.copy2(out/'source/transition-models.blend',retained)
            with bpy.data.libraries.load(str(retained),link=False) as (_,loaded):loaded.scenes=list(preserved)
        records += list(preserved.values())
    records.sort(key=lambda a:list(IDS).index(a['id']))
    bpy.context.window.scene=bpy.data.scenes['everest']
    for scene in bpy.data.scenes:
        scene['task']='TASK-TERRAIN-TRANSITION-022'
        scene['contract']='Each asset scene is at the frozen 020 origin. Hero is unchanged. Transition replaces original low foot.'
    bpy.context.preferences.filepaths.save_version=0
    source=out/'source/transition-models.blend'
    bpy.ops.wm.save_as_mainfile(filepath=str(source),compress=True)
    report={'task':'TASK-TERRAIN-TRANSITION-022','kind':'editable asset footing candidates; not production-integrated',
            'blender':bpy.app.version_string,'source_sha256':{str(Path(__file__).relative_to(ROOT)):sha(__file__)},
            'blend_sha256':sha(source),'assets':records,
            'limitations':['Runtime terrain-contact and route/neighbor footprint verification are separate acceptance steps.',
                           'Local source keeps zero-height toes; source modeling does not sculpt the production planet.',
                           'COLOR_0 is linear; Compatibility preview must adapt vertex colors once, with white material albedo.']}
    (out/'asset-catalog.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print('TRANSITION_022_COMPLETE',len(records),flush=True)


if __name__=='__main__':main()
