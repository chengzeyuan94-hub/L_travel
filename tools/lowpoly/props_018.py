#!/usr/bin/env python3
"""Standalone nature library authored from the reviewed Props018 concept sheets.

Blender --background --factory-startup --python-exit-code 1 --python \
  tools/lowpoly/props_018.py -- --output <external/library/ground-props>

Builds nine real Blender meshes, saves ground-props.blend, exports the same
meshes as combined and individual GLBs, and renders studio review images.
No map assets, runtime placements, 017 tools, or old evidence are touched.
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
import numpy as np
from mathutils import Vector, Matrix

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = Path('/Users/chengzeyuan/SilkRoadEvidence/planet-props-018/library/ground-props')
CONCEPTS = ROOT / 'docs/design/terrain-library-018/concepts'
REVISION = 'TERRAIN-LIBRARY-018'
FAMILIES = {
    'rocks': ('rock_strata_a', 'rock_weathered_b', 'rock_ledge_c'),
    'shrubs': ('shrub_oval_a', 'shrub_spreading_b'),
    'grass': ('grass_fan_a', 'grass_rosette_b'),
    'palms': ('palm_curved_a', 'palm_leaning_b'),
}
VARIANTS = tuple(v for group in FAMILIES.values() for v in group)
PALETTE = {
    'cream': 'E8D6A5', 'top': 'F0DDAA', 'ochre': 'CBA462', 'sand': 'D9BE83',
    'taupe': 'A89164', 'lower': 'B9A477', 'cleft': '988662',
    'leaf': '758647', 'leaf_light': 'A2AD60', 'leaf_mid': '879653',
    'leaf_dark': '596D42', 'leaf_back': '667A46',
    'wood': '97784B', 'wood_light': 'B69459', 'wood_dark': '81673F',
    'pod': 'B8924E',
}


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def linear_color(name, multiplier=1.0):
    h = PALETTE.get(name, name)
    c = [int(h[i:i+2], 16)/255 for i in (0, 2, 4)]
    return tuple((v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4)*multiplier for v in c)+(1.0,)


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False)+'\n')


def bezier(points, t):
    a,b,c,d = (Vector(p) for p in points)
    return (1-t)**3*a+3*(1-t)**2*t*b+3*(1-t)*t*t*c+t**3*d


class Model:
    def __init__(self, name):
        self.name=name; self.vertices=[]; self.faces=[]; self.colors=[]; self.part_ranges=[]

    def add(self, vertices, faces, color, part='form', shades=None):
        start=len(self.vertices); first=len(self.faces)
        self.vertices.extend(tuple(v) for v in vertices)
        for i, face in enumerate(faces):
            if len(set(face)) < 3: continue
            xyz=[Vector(vertices[j]) for j in face]
            if sum((xyz[j]-xyz[0]).cross(xyz[j+1]-xyz[0]).length for j in range(1,len(xyz)-1)) < 1e-10: continue
            self.faces.append(tuple(start+j for j in face))
            self.colors.append(linear_color(color, shades[i] if shades else 1.0))
        self.part_ranges.append({'name':part,'vertex_start':start,'vertex_count':len(vertices),'face_start':first,'face_count':len(self.faces)-first})

    def tube(self, points, radii, color='wood', sides=7, part='branch'):
        ps=[Vector(p) for p in points]; verts=[]; faces=[]
        for i,p in enumerate(ps):
            tangent=(ps[min(i+1,len(ps)-1)]-ps[max(0,i-1)]).normalized()
            reference=Vector((1,0,0)) if abs(tangent.x)<.85 else Vector((0,1,0))
            u=(reference-tangent*reference.dot(tangent)).normalized(); v=tangent.cross(u)
            for j in range(sides):
                a=j*math.tau/sides
                q=p+radii[i]*(u*math.cos(a)+v*math.sin(a))
                if i==0 and abs(p.z)<1e-8:q.z=0
                verts.append(q)
        for i in range(len(ps)-1):
            for j in range(sides):
                k=(j+1)%sides; faces.append((i*sides+j,i*sides+k,(i+1)*sides+k,(i+1)*sides+j))
        faces += [tuple(reversed(range(sides))),tuple((len(ps)-1)*sides+j for j in range(sides))]
        self.add(verts,faces,color,part)

    def leaf(self, points, width, color='leaf', part='curved_leaf', segments=7, thickness=.022, fold=.035, oval=False):
        ps=[Vector(p) for p in points]
        direction=ps[-1]-ps[0]; across=Vector((-direction.y,direction.x,0)).normalized()
        if across.length < .1: across=Vector((1,0,0))
        verts=[]; faces=[]; shades=[]
        # Closed curved ribbon with raised midrib and visible broad width.
        for i in range(segments+1):
            t=i/segments; center=bezier(ps,t)
            profile=math.sin(math.pi*(.018+.97*t))**(.63 if oval else .80)
            if i==0:profile=.075
            if i==segments:profile=.025
            w=width*profile
            thick=thickness*math.sin(math.pi*t)**.4
            lift=fold*profile
            for offset,z in ((-w,0),(0,lift),(w,0),(-w,-thick),(0,-thick),(w,-thick)):
                p=center+across*offset+Vector((0,0,z))
                if i==0 and ps[0].z<=.01:p.z=max(0,p.z)
                verts.append(p)
        for i in range(segments):
            a=i*6;b=(i+1)*6
            faces.extend([(a,a+1,b+1,b),(a+1,a+2,b+2,b+1),
                          (a+3,b+3,b+4,a+4),(a+4,b+4,b+5,a+5),
                          (a,b,b+3,a+3),(a+2,a+5,b+5,b+2)])
            shades.extend([1.0,1.06,.78,.81,.86,.90])
        faces += [(0,3,4,5,2,1),tuple(segments*6+j for j in (0,1,2,5,4,3))]
        shades.extend([.80,1.0])
        self.add(verts,faces,color,part,shades)

    def poly_slab(self, polygon, levels, colors, part, bevel=.095, offset=(0,0,0), top_tilt=(0,0), top_color='top'):
        # Explicit irregular polygon; no ico sphere, radial blob or noise remesh.
        outline=[]
        for i,p in enumerate(polygon):
            prev=np.asarray(polygon[i-1]);cur=np.asarray(p);nxt=np.asarray(polygon[(i+1)%len(polygon)])
            outline.extend([tuple(cur*(1-bevel)+prev*bevel),tuple(cur*(1-bevel)+nxt*bevel)])
        center=np.asarray(outline).mean(axis=0); n=len(outline);verts=[]
        for z,scale,dx,dy in levels:
            for x,y in outline:
                xy=center+(np.asarray((x,y))-center)*scale+np.asarray((dx,dy))
                wave=(.040*math.sin(xy[0]*2.6+xy[1]*1.8)+.025*math.cos(xy[1]*4.1-xy[0]*1.3))
                zz=z+top_tilt[0]*xy[0]+top_tilt[1]*xy[1]+wave*min(1,z*3)
                if z==0:zz=0
                verts.append((xy[0]+offset[0],xy[1]+offset[1],zz+offset[2]))
        for layer in range(len(levels)-1):
            faces=[]
            for j in range(n):
                k=(j+1)%n;faces.append((layer*n+j,layer*n+k,(layer+1)*n+k,(layer+1)*n+j))
            self.add(verts,faces,colors[min(layer,len(colors)-1)],part+'_stratum_%d'%layer)
        self.add(verts,[tuple(reversed(range(n)))],colors[0],part+'_base')
        cap=[(len(levels)-1)*n+j for j in range(n)]
        # A few broad, uneven top planes, not a uniformly planar pastry cap.
        center_top=sum((Vector(verts[j]) for j in cap),Vector())/n
        center_top.x-=.09;center_top.y+=.025;center_top.z+=.020
        ci=len(verts);verts.append(center_top)
        self.add(verts,[(cap[j],cap[(j+1)%n],ci) for j in range(n)], top_color,part+'_upper_plane')

    def ellipsoid(self, center, radii, color, part, rings=5, sides=9):
        verts=[];faces=[]
        for i in range(rings+1):
            lat=-math.pi/2+math.pi*i/rings
            for j in range(sides):
                lon=math.tau*j/sides
                verts.append((center[0]+radii[0]*math.cos(lat)*math.cos(lon),center[1]+radii[1]*math.cos(lat)*math.sin(lon),center[2]+radii[2]*math.sin(lat)))
        for i in range(rings):
            for j in range(sides):
                k=(j+1)%sides;faces.append((i*sides+j,i*sides+k,(i+1)*sides+k,(i+1)*sides+j))
        self.add(verts,faces,color,part)

    def object(self, material):
        verts=np.asarray(self.vertices,dtype=float)
        foot=verts[np.abs(verts[:,2])<1e-7]
        center=(foot[:,:2].min(axis=0)+foot[:,:2].max(axis=0))*.5
        verts[:,:2]-=center
        mesh=bpy.data.meshes.new(self.name+'_geometry');mesh.from_pydata(verts.tolist(),[],self.faces);mesh.update()
        obj=bpy.data.objects.new(self.name,mesh);bpy.context.scene.collection.objects.link(obj)
        mesh.materials.append(material)
        col=mesh.color_attributes.new(name='Col',type='FLOAT_COLOR',domain='CORNER');mesh.color_attributes.active_color=col
        tag=mesh.attributes.new(name='part_id',type='INT',domain='FACE')
        for i,part in enumerate(self.part_ranges):
            for fi in range(part['face_start'],part['face_start']+part['face_count']):tag.data[fi].value=i
        for face,color in zip(mesh.polygons,self.colors):
            for li in face.loop_indices:col.data[li].color=color
        # Weld exact authoring seams and orient every closed component outward.
        # This is mesh cleanup, not subdivision or automatic shape generation.
        bm=bmesh.new();bm.from_mesh(mesh)
        bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=1e-7)
        cuts={
            'rock_strata_a':[((.55,-.20,1),1.42),((-.65,.35,1),1.90)],
            'rock_weathered_b':[((-.50,-.65,1),1.55)],
            'rock_ledge_c':[((-.60,-.35,1),1.90),((.95,-.20,1),1.48)],
        }
        for cut_index,(normal,constant) in enumerate(cuts.get(self.name,[])):
            # Localized authored wedge cuts, selected for the concept's broad
            # broken shoulders. No all-corner bevel pass or random noise.
            no=Vector(normal);plane=no*(constant/no.length_squared)
            result=bmesh.ops.bisect_plane(bm,geom=list(bm.verts)+list(bm.edges)+list(bm.faces),
                plane_co=plane,plane_no=no,dist=1e-7,clear_outer=True,clear_inner=False)
            boundary=[edge for edge in result['geom_cut'] if isinstance(edge,bmesh.types.BMEdge) and edge.is_boundary]
            cap=bmesh.ops.holes_fill(bm,edges=boundary,sides=0)['faces'] if boundary else []
            part_index=len(self.part_ranges);self.part_ranges.append({'name':'authored_wedge_cut_%d'%cut_index})
            layer=bm.faces.layers.int.get('part_id');color_layer=bm.loops.layers.float_color.get('Col')
            for face in cap:
                face[layer]=part_index
                for loop in face.loops:loop[color_layer]=linear_color('cream')
        bmesh.ops.triangulate(bm,faces=list(bm.faces),quad_method='BEAUTY',ngon_method='BEAUTY')
        zero_area=[face for face in bm.faces if face.calc_area()<1e-11]
        if zero_area:bmesh.ops.delete(bm,geom=zero_area,context='FACES_ONLY')
        if self.name=='rock_ledge_c':
            # The lower-bench wedge now reaches the actual base; anchor the
            # retained contact geometry after the cut, never the display grid.
            contacts=[v.co for v in bm.verts if v.link_faces and abs(v.co.z)<1e-7]
            center=Vector(((min(v.x for v in contacts)+max(v.x for v in contacts))*.5,
                           (min(v.y for v in contacts)+max(v.y for v in contacts))*.5,0))
            for vertex in bm.verts:vertex.co-=center
        bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(mesh);bm.free();mesh.update()
        part_faces=[[] for _ in self.part_ranges]
        for face,tag_value in zip(mesh.polygons,mesh.attributes['part_id'].data):
            part_faces[tag_value.value].append(face)
        parts=[]
        for part,faces in zip(self.part_ranges,part_faces):
            ids=sorted({v for f in faces for v in f.vertices})
            if ids:
                vg=obj.vertex_groups.new(name=part['name']);vg.add(ids,1.0,'REPLACE')
            if any(term in part['name'] for term in ('leaf','spray','blade')):
                for f in faces:f.use_smooth=True
            parts.append({'name':part['name'],'face_count':len(faces),'vertex_count':len(ids)})
        obj['library_revision']=REVISION;obj['parts']=json.dumps(parts)
        obj['concept_source']='rocks.png' if self.name.startswith('rock') else ('palms.png' if self.name.startswith('palm') else 'groundcover.png')
        obj['modeling_note']='Authored multipart geometry from reviewed concept; no map or placement dependency.'
        return obj


def chip(m, center, width, depth, height, angle=0, part='fallen_chip'):
    poly=[(-.5,-.38),(.21,-.52),(.54,-.12),(.33,.43),(-.32,.48),(-.55,.12)]
    c,s=math.cos(angle),math.sin(angle)
    poly=[(center[0]+c*x*width-s*y*depth,center[1]+s*x*width+c*y*depth) for x,y in poly]
    m.poly_slab(poly,[(0,1,0,0),(height*.35,1.01,0,0),(height,.77,0,0)],['lower','sand'],part,.10)


def bevel_outline(polygon):
    result=[]
    for i,p in enumerate(polygon):
        prev=np.asarray(polygon[i-1]);cur=np.asarray(p);nxt=np.asarray(polygon[(i+1)%len(polygon)])
        cut=(.035,.105,.045,.08,.025,.12,.05,.07,.04,.09)[i%10]
        result.extend([tuple(cur*(1-cut)+prev*cut),tuple(cur*(1-cut)+nxt*cut)])
    return result


def clip_rock_outline(points, slope, intercept, side):
    result=[]
    def signed(p):return side*(p[0]-slope*p[1]-intercept)
    for a,b in zip(points,points[1:]+points[:1]):
        da,db=signed(a),signed(b)
        if da>=0:result.append(a)
        if (da>=0)!=(db>=0):
            t=da/(da-db);result.append(tuple(np.asarray(a)+(np.asarray(b)-a)*t))
    return result


def sediment_half(m, outer, levels, cut, side, name, tilt=(-.04,.065), shoulder=1.0):
    outline=bevel_outline(outer);center=np.asarray(outline).mean(axis=0);rings=[]
    for index,(z,sx,sy,dx,dy) in enumerate(levels):
        # Both halves come from the SAME outer stratum, then an inclined split
        # cuts through it. Their ledges continue across the actual fracture.
        points=[tuple(center+(np.asarray(p)-center)*np.asarray((sx,sy))+np.asarray((dx,dy))) for p in outline]
        intercept=cut[0]+cut[2]*z+side*(.020+.036*math.sin(z*math.pi/levels[-1][0])**2)
        points=clip_rock_outline(points,cut[1],intercept,side)
        ring=[]
        for x,y in points:
            erosion=.030*math.sin(x*2.8+y*1.1)+.020*math.cos(y*3.2-x*.9)
            zz=z if z==0 else (z*shoulder+tilt[0]*x+tilt[1]*y+erosion*min(1,z*2.0))
            ring.append((x,y,max(0,zz)))
        rings.append(ring)
    offsets=[];verts=[];parameters=[]
    for ring in rings:
        offsets.append(len(verts));verts.extend(ring)
        lengths=[math.dist(ring[j][:2],ring[(j+1)%len(ring)][:2]) for j in range(len(ring))]
        parameters.append(np.concatenate(([0.],np.cumsum(lengths)/sum(lengths))))
    bands=(['lower','sand','lower','sand','sand','cream','sand'] if name.startswith('oblique') else ['lower','ochre','taupe','sand','ochre','cream','sand'])
    for layer in range(len(rings)-1):
        na,nb=len(rings[layer]),len(rings[layer+1]);ia=ib=0;faces=[]
        aa,bb=offsets[layer],offsets[layer+1]
        # Zipper unequal clipped contours while retaining their authored corners.
        while ia<na or ib<nb:
            ta=parameters[layer][ia+1] if ia<na else 2
            tb=parameters[layer+1][ib+1] if ib<nb else 2
            if abs(ta-tb)<1e-7:
                faces.append((aa+ia%na,aa+(ia+1)%na,bb+(ib+1)%nb,bb+ib%nb));ia+=1;ib+=1
            elif ta<tb:
                faces.append((aa+ia%na,aa+(ia+1)%na,bb+ib%nb));ia+=1
            else:
                faces.append((aa+ia%na,bb+(ib+1)%nb,bb+ib%nb));ib+=1
        for j,face in enumerate(faces):
            center_face=np.asarray([verts[q] for q in face]).mean(axis=0)
            color=bands[min(layer,len(bands)-1)]
            if layer in (1,4) and center_face[1]>.12:color='sand'
            if abs(center_face[0]-cut[1]*center_face[1]-(cut[0]+cut[2]*center_face[2]))<.15:color='taupe' if layer<4 else 'sand'
            m.add(verts,[face],color,name+'_layer_%d_face_%d'%(layer,j))
    n=len(rings[0]);m.add(verts,[tuple(reversed(range(n)))],'lower',name+'_actual_base')
    n=len(rings[-1]);top_ids=[offsets[-1]+j for j in range(n)]
    c=sum((Vector(verts[j]) for j in top_ids),Vector())/n;c.z+=.035;c.y+=.025
    ci=len(verts);verts.append(c)
    m.add(verts,[(top_ids[j],top_ids[(j+1)%n],ci) for j in range(n)],'top',name+'_broken_upper_planes')


def rocks():
    a=Model('rock_strata_a')
    outer=[(-1.42,-.34),(-.91,-.64),(.32,-.61),(1.14,-.47),(1.48,-.13),(1.40,.36),(.82,.58),(-.28,.57),(-1.26,.43),(-1.47,.06)]
    levels=[(0,1,1,0,0),(.10,.98,1.01,0,0),(.31,.94,.91,-.025,.01),(.38,1.01,.98,-.045,.005),(.61,.99,.96,-.070,.035),(.69,.95,1.005,-.050,.018),(.91,.88,.87,-.105,.060)]
    for side,name in ((-1,'continuous_strata_left'),(1,'continuous_strata_right')):
        sediment_half(a,outer,levels,(-.28,.16,.16),side,name,tilt=(-.055,.085))
    a.poly_slab([(-1.19,.03),(-.66,-.01),(-.23,.22),(-.41,.49),(-1.02,.50),(-1.28,.26)],[(.94,1,0,0),(1.04,.98,-.014,.012),(1.10,.89,-.012,.008)],['sand','cream'],'offset_broken_back_cap',.07,top_tilt=(-.04,.075))
    chip(a,(-.81,-.86),.36,.28,.15,.10,'flat_fallen_chip_a');chip(a,(.45,-.89),.33,.24,.13,-.41,'flat_fallen_chip_b')
    b=Model('rock_weathered_b')
    outer_b=[(-1.02,-.44),(-.62,-.65),(.24,-.61),(.86,-.40),(1.08,.04),(.77,.52),(.07,.67),(-.74,.49),(-1.10,.03)]
    left_levels=[(0,1,1,0,0),(.17,1.02,1.03,0,0),(.36,.98,.99,0,.01),(.53,1.005,.93,-.025,.02),(.85,.90,.88,-.05,.08),(1.12,.67,.72,-.13,.11),(1.37,.39,.54,-.23,.16)]
    right_levels=[(0,1,1,0,0),(.17,1.02,1.03,0,0),(.36,.98,.99,0,.01),(.53,1.005,.93,-.025,.02),(.78,.88,.84,-.005,.07),(1.00,.59,.65,-.015,.09),(1.16,.33,.47,-.01,.10)]
    sediment_half(b,outer_b,left_levels,(-.055,.22,-.105),-1,'oblique_eroded_left',tilt=(-.065,.03))
    sediment_half(b,outer_b,right_levels,(-.055,.22,-.105),1,'oblique_eroded_right',tilt=(-.08,.005))
    b.poly_slab([(.08,-.69),(.58,-.78),(.94,-.56),(1.07,-.24),(.84,-.08),(.14,-.14)],[(0,1,0,0),(.15,1.01,0,0),(.28,.99,0,0),(.38,.88,-.01,.02)],['lower','ochre','cream'],'broken_lower_front_shelf',.07,top_tilt=(-.035,.04))
    chip(b,(1.12,-.79),.46,.37,.29,.28,'weathered_companion')
    c=Model('rock_ledge_c')
    # A continuous broad rock core carries most of the upper slab. Only its
    # front-left edge retreats into a shallow wedge: not a through-floor gap.
    lower=[(-.91,-.56),(-.35,-.68),(.75,-.60),(1.43,-.28),(1.38,.26),(.89,.52),(.04,.57),(-.82,.31)]
    c.poly_slab(lower,[(0,1,0,0),(.17,1.01,0,0),(.34,.96,.01,.025),(.43,.95,0,.015)],['lower','ochre','sand'],'sloping_lower_bench',.065,top_tilt=(.035,-.035))
    core=[(-1.02,-.12),(-.62,-.30),(-.22,-.35),(.29,-.46),(.57,-.16),(.60,.24),(.03,.45),(-.94,.47),(-1.10,.16)]
    c.poly_slab(core,[(.25,1,0,0),(.56,.98,-.01,0),(.70,.98,-.01,0)],['taupe','sand'],'continuous_core_with_local_wedge_recess',.04)
    middle=[(-1.14,-.38),(-.73,-.55),(-.39,-.56),(-.23,-.37),(-.045,-.55),(.27,-.48),(.67,-.17),(.67,.25),(.03,.48),(-.94,.50),(-1.21,.16)]
    c.poly_slab(middle,[(.54,.97,-.05,-.08),(.62,1.015,-.06,-.09),(.79,.99,-.08,-.07),(.88,.90,-.10,-.03)],['taupe','ochre','cream'],'chipped_oblique_overhang',.055,top_tilt=(-.025,.025))
    upper=[(-1.02,-.095),(-.64,-.24),(-.27,-.17),(-.08,.04),(-.19,.28),(-.41,.22),(-.55,.42),(-.92,.40),(-1.10,.20)]
    c.poly_slab(upper,[(.90,1,-.04,-.05),(1.025,.985,-.03,-.04),(1.13,.87,-.06,0)],['ochre','cream'],'uneven_notched_upper_cap',.045,top_tilt=(-.08,-.045))
    chip(c,(-1.35,-.69),.74,.51,.35,-.36,'detached_slant_wedge')
    return [a,b,c]


def shrubs():
    a=Model('shrub_oval_a')
    a.tube([(0,0,0),(.01,0,.24),(.025,.015,.55)],[.13,.11,.052],sides=8,part='short_woody_root')
    for i in range(8):
        angle=i*math.tau/8+.14;d=Vector((math.cos(angle),math.sin(angle),0))
        tip=d*(.33+.035*(i%3))+Vector((0,0,.43+.12*(i%2)))
        a.tube([(0,0,.13),tuple(d*.18+Vector((0,0,.32))),tuple(tip)],[.06,.039,.022],part='fork_%02d'%i)
        for j in range(2):
            aa=angle+(j-.5)*.47;dd=Vector((math.cos(aa),math.sin(aa),0))
            length=.76 if j==0 else .63; rise=.66 if i%3 else .83
            root=tip+Vector((0,0,.015*j))
            ps=[root,root+dd*.14+Vector((0,0,rise*.66)),root+dd*(length*.61)+Vector((0,0,rise)),root+dd*length+Vector((0,0,rise*.32))]
            a.leaf(ps,.20 if j==0 else .18,['leaf','leaf_mid','leaf_dark','leaf_light'][(i+j)%4],part='broad_spray_%02d_%d'%(i,j),oval=True)
    for i,angle in enumerate((.6,2.8,4.6)):
        d=Vector((math.cos(angle),math.sin(angle),0));root=Vector((.02,0,.52))
        a.leaf([root,root+d*.05+Vector((0,0,.54)),root+d*.35+Vector((0,0,.94)),root+d*.50+Vector((0,0,.87))],.21,'leaf_mid' if i else 'leaf_light',part='upright_inner_leaf_%d'%i,oval=True)
    b=Model('shrub_spreading_b')
    stem=[(0,0,0),(-.025,.02,.25),(.015,.04,.58),(-.02,.055,.95),(.02,.06,1.22)]
    b.tube(stem,[.11,.085,.057,.037,.012],sides=8,part='taller_rear_stem')
    sprays=[(-.76,-.15,.23),(.70,-.10,.34),(-.50,.13,.52),(.53,.16,.64),
            (-.24,.10,.84),(.16,.08,1.10),(-.24,-.48,.26),(.25,.46,.35),
            (.40,-.37,.54),(-.35,.37,.64)]
    for i,(x,y,z) in enumerate(sprays):
        root=Vector((.0,.025,z*.43));tip=Vector((x*.64,y*.82,z))
        b.tube([root,root.lerp(tip,.55)+Vector((0,0,.03)),tip],[.047,.030,.013],part='spreading_branch_%d'%i)
        direction=math.atan2(y,x)
        count=3 if i in (4,5) else 4
        for j in range(count):
            angle=direction+(j-(count-1)*.5)*.63;d=Vector((math.cos(angle),math.sin(angle),0))
            high=i in (4,5);length=.36 if high else (.49+.045*(j%2));rise=.23 if high else .20+.06*(j%2)
            start=tip+Vector((0,0,.018*j))
            b.leaf([start,start+d*.10+Vector((0,0,.17)),start+d*(length*.60)+Vector((0,0,rise+.05)),start+d*length+Vector((0,0,rise*.60))],.15 if high else .18,['leaf_dark','leaf_mid','leaf_light'][(i+j)%3],part='oval_leaf_%d_%d'%(i,j),segments=6,oval=True)
    for i,angle in enumerate((-.3,2.8)):
        d=Vector((math.cos(angle),math.sin(angle),0));r=Vector(stem[-1])
        b.leaf([r,r+d*.04+Vector((0,0,.19)),r+d*.19+Vector((0,0,.32)),r+d*.27+Vector((0,0,.29))],.14,'leaf_light' if i else 'leaf',part='rear_tip_leaf_%d'%i,segments=6,oval=True)
    return [a,b]


def grasses():
    a=Model('grass_fan_a')
    specs=[(-.20,-.01,2.90,1.27,.67),(-.12,.02,2.65,1.76,.48),(-.06,.12,1.7,1.35,.47),(0,.03,1.28,2.17,.38),(.11,.04,.34,1.53,.71),(.18,-.03,-.1,1.08,.70),(.08,-.13,-.72,1.33,.63)]
    for i,(x,y,angle,height,reach) in enumerate(specs):
        r=Vector((x,y,0));d=Vector((math.cos(angle),math.sin(angle),0))
        a.leaf([r,r+d*.075+Vector((0,0,height*.48)),r+d*(reach*.52)+Vector((0,0,height*1.16)),r+d*reach+Vector((0,0,height*.79))],.15 if i==3 else .13,['leaf','leaf_mid','leaf_light'][i%3],part='curled_blade_%02d'%i,segments=9,thickness=.027,fold=.045)
    b=Model('grass_rosette_b')
    for i in range(9):
        angle=i*math.tau/9+.17;d=Vector((math.cos(angle),math.sin(angle),0));reach=.83+.15*(i%3);rise=.70+.14*(i%2)
        r=d*.075
        b.leaf([r,r+d*.09+Vector((0,0,rise*.70)),r+d*(reach*.51)+Vector((0,0,rise*1.35)),r+d*reach+Vector((0,0,.20+.10*(i%2)))],.17+.02*(i%2),['leaf_mid','leaf_light','leaf','leaf_dark'][i%4],part='fleshy_rosette_leaf_%02d'%i,segments=8,thickness=.035,fold=.055)
    return [a,b]


def palm_frond(m, root, angle, reach, rise, drop, index, lobes=5):
    d=Vector((math.cos(angle),math.sin(angle),0));side=Vector((-d.y,d.x,0));r=Vector(root)
    ps=[r,r+d*(reach*.25)+Vector((0,0,rise)),r+d*(reach*.67)+Vector((0,0,rise*.75)),r+d*reach+Vector((0,0,-drop))]
    # A single closed lamina: broad uninterrupted center, with four authored
    # outer-edge notches on either side. The cuts stop well short of the rib.
    # The raised rib is part of this mesh and converges into its sealed tip.
    notches=((.25,.43,.63,.81),(.28,.47,.66,.83))
    rows={0.,.07,.13,.95,1.}
    for cuts in notches:
        for t in cuts:rows.update((t-.034,t,t+.018))
    ts=sorted(rows);verts=[];faces=[];shades=[]
    def breadth(t, flank):
        if t in (0.,1.):return .008 if t==0 else 0.
        w=(.35 if flank==0 else .37)*math.sin(math.pi*t)**.66
        for cut in notches[flank]:
            if cut-.034<=t<=cut+.018:
                factor=(1-(t-(cut-.034))/.034*.57 if t<=cut else .43+(t-cut)/.018*.57)
                w*=factor
        return w
    for t in ts:
        center=bezier(ps,t);profile=math.sin(math.pi*t)
        left,right=breadth(t,0),breadth(t,1)
        ridge=.020*profile;thick=.017*profile**.35
        left_edge=-left*.20;right_edge=-right*.20
        for width,z in ((-left,left_edge),(0,ridge),(right,right_edge),
                        (-left,left_edge-thick),(0,-thick),(right,right_edge-thick)):
            verts.append(center+side*width+Vector((0,0,z)))
    for i in range(len(ts)-1):
        a=i*6;b=(i+1)*6
        faces.extend([(a,a+1,b+1,b),(a+1,a+2,b+2,b+1),
                      (a+3,b+3,b+4,a+4),(a+4,b+4,b+5,a+5),
                      (a,b,b+3,a+3),(a+2,a+5,b+5,b+2)])
        shades.extend([1.0,1.055,.77,.80,.86,.89])
    faces.append((0,3,4,5,2,1));shades.append(.82)
    m.add(verts,faces,['leaf','leaf_mid','leaf_light'][index%3],
          part='frond_%02d_continuous_notched_leaf_and_rib'%index,shades=shades)
    return ps


def palm(name, leaning=False):
    m=Model(name)
    def trunk_center(z):
        if leaning:return Vector((.23*(z/2.1)-.09*math.sin(z*2.2),.02*math.sin(z*1.4),z))
        return Vector((-.15*math.sin(z*2.3)+.045*z,.025*math.sin(z*2),z))
    rings=[];radii=[]
    for i in range(13):
        z=i*2.05/12
        r=.24*(1-z/3.2)
        for dz,rr in ((0,r*1.04),(.105,r*.93)):
            rings.append(trunk_center(z+dz));radii.append(rr)
    m.tube(rings,radii,'wood_light',sides=9 if leaning else 8,part='segmented_curved_trunk')
    # Color and raised facets follow the trunk; the ring relief is geometry.
    if leaning:
        for i in range(9):
            z=.29+i*.19;c=trunk_center(z);r=.24*(1-z/3.2)
            for j in range(5):
                angle=j*math.tau/5+(i%2)*math.pi/5
                n=Vector((math.cos(angle),math.sin(angle),0));s=Vector((-n.y,n.x,0));q=c+n*r
                verts=[q+s*.115,q+Vector((0,0,.135)),q-s*.115,q-Vector((0,0,.10)),q+n*.040]
                m.add(verts,[(0,1,4),(1,2,4),(2,3,4),(3,0,4)],'wood' if i%2 else 'wood_light','diamond_bark_%d_%d'%(i,j))
    for i in range(6):
        a=i*math.tau/6;d=Vector((math.cos(a),math.sin(a),0))
        poly=[tuple(d*.13+Vector((-d.y,d.x,0))*.10),tuple(d*.35+Vector((-d.y,d.x,0))*.065),tuple(d*.39-Vector((-d.y,d.x,0))*.06),tuple(d*.14-Vector((-d.y,d.x,0))*.11)]
        # Clockwise/CCW polygon is normalized for predictable outward faces.
        xy=[(p[0],p[1]) for p in poly]
        if sum(xy[k][0]*xy[(k+1)%4][1]-xy[(k+1)%4][0]*xy[k][1] for k in range(4))<0:xy.reverse()
        m.poly_slab(xy,[(0,1,0,0),(.12,.85,-d.x*.015,-d.y*.015),(.23,.48,-d.x*.05,-d.y*.05)],['wood','wood_light'],'flared_root_%d'%i,.10,top_color='wood_light')
    crown=trunk_center(2.10)
    fronds=9 if leaning else 7
    for i in range(fronds):
        angle=i*math.tau/fronds+(.24 if leaning else .08)+.10*math.sin(i*2.1)
        rise=.46+.24*(i%3==0);drop=.49 if i%2 else .30
        reach=1.27+.16*math.sin(i*1.7)
        if leaning and i in (2,5):rise=.91;drop=-.18;reach=1.06
        palm_frond(m,crown+Vector((0,0,.04*(i%2))),angle,reach,rise,drop,i)
    for i in range(3):
        angle=-math.pi/2+(i-1)*.60;d=Vector((math.cos(angle),math.sin(angle),0));p=crown+d*.21+Vector((0,0,-.26-.045*(i%2)))
        m.tube([crown+d*.10,p+Vector((0,0,.12))],[.017,.012],'wood_dark',sides=5,part='seed_pod_stalk_%d'%i)
        m.ellipsoid(p,(.12,.10,.20),'pod','seed_pod_%d'%i)
    return m


def material():
    mat=bpy.data.materials.new('Library_VertexColor_White');mat.use_nodes=True;mat.diffuse_color=(1,1,1,1)
    bsdf=mat.node_tree.nodes.get('Principled BSDF');bsdf.inputs['Base Color'].default_value=(1,1,1,1);bsdf.inputs['Roughness'].default_value=.84
    attr=mat.node_tree.nodes.new('ShaderNodeVertexColor');attr.layer_name='Col';mat.node_tree.links.new(attr.outputs['Color'],bsdf.inputs['Base Color'])
    return mat


def studio(objects, output, render=True):
    scene=bpy.context.scene;scene.render.engine='CYCLES';scene.cycles.samples=40;scene.cycles.use_denoising=True
    scene.render.resolution_x=1536;scene.render.resolution_y=1536;scene.render.resolution_percentage=100
    scene.view_settings.view_transform='Standard';scene.view_settings.look='Medium High Contrast' if 'Medium High Contrast' in [] else 'None'
    scene.view_settings.exposure=0;scene.view_settings.gamma=1
    world=bpy.data.worlds.new('Warm_Gray_Studio');world.use_nodes=True;world.node_tree.nodes['Background'].inputs[0].default_value=(.70,.73,.76,1);world.node_tree.nodes['Background'].inputs[1].default_value=.85;scene.world=world
    floor_mat=bpy.data.materials.new('Studio_Ground');floor_mat.diffuse_color=linear_color('D4D0C6');floor_mat.use_nodes=True
    floor_mat.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=floor_mat.diffuse_color
    floor_mat.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value=1
    bpy.ops.mesh.primitive_plane_add(size=200,location=(0,0,-.015));floor=bpy.context.object;floor.name='Studio_floor';floor.data.materials.append(floor_mat)
    light_data=bpy.data.lights.new('Studio_Key','AREA');light=bpy.data.objects.new('Studio_Key',light_data);scene.collection.objects.link(light);light.location=(-10,-15,24);light_data.energy=5500;light_data.shape='DISK';light_data.size=10
    fill_data=bpy.data.lights.new('Studio_Fill','AREA');fill=bpy.data.objects.new('Studio_Fill',fill_data);scene.collection.objects.link(fill);fill.location=(12,8,18);fill_data.energy=2000;fill_data.size=12
    camera_data=bpy.data.cameras.new('Studio_Camera');camera=bpy.data.objects.new('Studio_Camera',camera_data);scene.collection.objects.link(camera);scene.camera=camera;camera_data.type='ORTHO'
    target=Vector((0,0,.75));camera.location=(7,-11,9);camera.rotation_euler=(target-Vector(camera.location)).to_track_quat('-Z','Y').to_euler();camera_data.ortho_scale=12.6
    right=Vector((11,7,0)).normalized();away=Vector((-7,11,0)).normalized();alt=math.asin((Vector(camera.location)-target).normalized().z)
    for i,obj in enumerate(objects):obj.location=right*((i%3-1)*3.75)+away*((1-i//3)*3.75/math.sin(alt))
    if render:
        scene.render.filepath=str(output/'studio-three-quarter.png');bpy.ops.render.render(write_still=True)
        # Top sheet uses its own rectangular ground grid; geometry never changes.
        for i,obj in enumerate(objects):obj.location=((i%3-1)*3.75,(1-i//3)*3.75,0)
        camera.location=(0,0,20);camera.rotation_euler=(0,0,0);camera.rotation_euler=(Vector((0,0,0))-camera.location).to_track_quat('-Z','Y').to_euler();camera_data.ortho_scale=12
        scene.render.filepath=str(output/'studio-top.png');bpy.ops.render.render(write_still=True)
    # Save the editable source with its tidy top-grid layout and a usable orbit.
    for i,obj in enumerate(objects):obj.location=((i%3-1)*3.75,(1-i//3)*3.75,0)
    camera.location=(9,-13,13);camera.rotation_euler=(Vector((0,0,.5))-camera.location).to_track_quat('-Z','Y').to_euler();camera_data.ortho_scale=16
    return camera


def export(objects, output, name='ground-props.glb'):
    bpy.ops.object.select_all(action='DESELECT');clones=[];renamed=[]
    for obj in objects:
        original=obj.name;obj.name=original+'_source_display';renamed.append((obj,original))
        clone=bpy.data.objects.new(original,obj.data);bpy.context.scene.collection.objects.link(clone);clone.matrix_world=Matrix.Identity(4);clone.select_set(True);clones.append(clone)
    bpy.context.view_layer.objects.active=clones[0]
    bpy.ops.export_scene.gltf(filepath=str(output/name),export_format='GLB',use_selection=True,export_yup=True,
        export_apply=True,export_normals=True,export_materials='EXPORT',export_vertex_color='ACTIVE',
        export_animations=False,export_lights=False,export_cameras=False,export_extras=True)
    for clone in clones:bpy.data.objects.remove(clone,do_unlink=True)
    for obj,name in renamed:obj.name=name


def glb_stats(path):
    import struct
    blob=Path(path).read_bytes();size=struct.unpack_from('<I',blob,12)[0];doc=json.loads(blob[20:20+size]);rows=[]
    for node in doc['nodes']:
        if 'mesh' not in node:continue
        mesh=doc['meshes'][node['mesh']];triangles=sum(doc['accessors'][p['indices']]['count']//3 for p in mesh['primitives'])
        positions=[doc['accessors'][p['attributes']['POSITION']] for p in mesh['primitives']]
        lo=np.min([a['min'] for a in positions],axis=0);hi=np.max([a['max'] for a in positions],axis=0)
        rows.append({'id':node['name'],'triangles':triangles,'surfaces':len(mesh['primitives']),'bounds_godot_xyz':{'min':lo.tolist(),'max':hi.tolist()},'dimensions':(hi-lo).tolist()})
    return {'sha256':sha(path),'bytes':len(blob),'meshes':rows,'total_triangles':sum(r['triangles'] for r in rows)}


def glb_anchor(path):
    import struct
    blob=Path(path).read_bytes();size=struct.unpack_from('<I',blob,12)[0]
    doc=json.loads(blob[20:20+size]);binary=blob[28+size:];arrays=[]
    for mesh in doc['meshes']:
        for primitive in mesh['primitives']:
            accessor=doc['accessors'][primitive['attributes']['POSITION']]
            assert accessor['componentType']==5126 and accessor['type']=='VEC3'
            view=doc['bufferViews'][accessor['bufferView']]
            offset=view.get('byteOffset',0)+accessor.get('byteOffset',0)
            arrays.append(np.ndarray((accessor['count'],3),dtype='<f4',buffer=binary,
                offset=offset,strides=(view.get('byteStride',12),4)).astype(float))
    values=np.concatenate(arrays);feet=values[np.abs(values[:,1])<=1e-6][:,(0,2)]
    lo=feet.min(axis=0);hi=feet.max(axis=0)
    identity=all(node.get('translation',[0,0,0])==[0,0,0] and
        node.get('scale',[1,1,1])==[1,1,1] and node.get('rotation',[0,0,0,1])==[0,0,0,1]
        and node.get('matrix',[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])==[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
        for node in doc['nodes'])
    return {'kind':'actual_base_footprint_aabb_center','coordinate_system':'Godot Y-up',
        'origin':[0,0,0],'base_vertex_selector':'abs(POSITION.y) <= 1e-6',
        'actual_base_xz_aabb':{'min':lo.tolist(),'max':hi.tolist()},
        'actual_base_xz_center':((lo+hi)*.5).tolist(),
        'whole_geometry_aabb_center':((values.min(axis=0)+values.max(axis=0))*.5).tolist(),
        'identity_node_transforms_verified':identity,
        'authoring':'Center the XY AABB of actual Blender Z=0 foot vertices; export identity clones with Y-up conversion.',
        'note':'Whole-model horizontal AABB may be asymmetric due to leaning trunks, uneven crowns, and overhanging rock lips.'}


def render_individual_views(objects, camera, output, preview_ids=None):
    scene=bpy.context.scene;directory=output/'previews';directory.mkdir(exist_ok=True)
    scene.render.resolution_x=768;scene.render.resolution_y=768;scene.cycles.samples=32
    locations={o.name:o.location.copy() for o in objects}
    for obj in objects:obj.hide_render=True
    for obj in objects:
        if preview_ids and obj.name not in preview_ids:continue
        obj.hide_render=False;obj.location=(0,0,0)
        values=np.asarray([v.co[:] for v in obj.data.vertices]);low=values.min(axis=0);high=values.max(axis=0);dims=high-low
        target=Vector(((low[0]+high[0])*.5,(low[1]+high[1])*.5,(low[2]+high[2])*.47))
        for view,direction in [('three-quarter',Vector((6,-9,6))),('top',Vector((0,0,1))),('side',Vector((1,0,0)))]:
            camera.location=target+direction.normalized()*15
            camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
            camera.data.ortho_scale=(max(dims[0],dims[1])*1.22 if view=='top' else max(max(dims[0],dims[1]),dims[2])*1.22)
            scene.render.filepath=str(directory/(obj.name+'-'+view+'.png'))
            bpy.ops.render.render(write_still=True)
        obj.hide_render=True;obj.location=locations[obj.name]
    for obj in objects:obj.hide_render=False
    scene.render.resolution_x=1536;scene.render.resolution_y=1536;scene.cycles.samples=40
    camera.location=(9,-13,13);camera.rotation_euler=(Vector((0,0,.5))-camera.location).to_track_quat('-Z','Y').to_euler();camera.data.ortho_scale=16


FEATURES = {
    'rock_strata_a':['共同长岩层被一道变宽斜裂缝分开','连续但不等厚的沉积层','偏移上盖与两片薄碎岩'],
    'rock_weathered_b':['倾斜且不平行的深断口','左右不对称的侵蚀肩','下部退台与独立伴岩'],
    'rock_ledge_c':['略向左前方偏出的厚岩唇与倾斜底台','宽实岩核承接上层，单侧局部掏出浅楔形阴影口','缺口上唇和脱落斜楔'],
    'shrub_oval_a':['低矮叉枝','十九片宽弯叶的重叠冠层','可见内侧留空与叶片厚度'],
    'shrub_spreading_b':['短后枝与四向低位侧枝','四十片椭圆叶形成前后扇簇','保留高低错落的伸展灌木轮廓'],
    'grass_fan_a':['七片高低不同的卷曲宽叶','连续中折与弯垂叶尖','真实厚度及贴地基根'],
    'grass_rosette_b':['九片宽叶的低矮莲座','弯曲肥厚叶面与中脊','径向但不等长的外轮廓'],
    'palm_curved_a':['S弯分节树干与外展根领','七片连续宽叶与局部深切口，中肋收进封闭叶尖','冠下三颗低调种荚'],
    'palm_leaning_b':['倾斜粗干与错位凸起菱形树皮','九片弯曲连续叶面与封闭尖端','外展根领和三颗种荚'],
}


def catalog(output, report):
    actual={m['id']:m for m in report['meshes']};rows=[]
    for variant in VARIANTS:
        row=actual[variant];category='rocks' if variant.startswith('rock') else ('trees' if variant.startswith('palm') else 'greenery')
        concept='rocks' if category=='rocks' else ('palms' if category=='trees' else 'groundcover')
        rows.append({'id':variant,'category':category,'glb':'exports/'+variant+'.glb',
                     'blend':'source/ground-props.blend','concept':'concepts/'+concept+'.png',
                     'features':FEATURES[variant],'triangles':row['triangles'],'bounds':row['bounds_godot_xyz'],
                     'source_object':variant,'sha256':sha(output/'individual'/(variant+'.glb')),
                     'origin_anchor':glb_anchor(output/'individual'/(variant+'.glb')),
                     'blender_previews':{view:str(output/'previews'/(variant+'-'+view+'.png')) for view in ('three-quarter','top','side')},
                     'candidate_glb':str(output/'individual'/(variant+'.glb'))})
    return {'revision':REVISION,'assets':rows,'source_tool':'tools/lowpoly/props_018.py',
            'candidate_source_blend':str(output/'ground-props.blend'),'combined_glb_is_catalog_asset':False,
            'coordinate_contract':'Godot Y-up; actual base min Y=0; base footprint centered; positive identity node transforms',
            'scope':'standalone asset library; not integrated into production map'}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,default=DEFAULT_OUTPUT);parser.add_argument('--no-render',action='store_true');parser.add_argument('--preview-ids',help='Render selected individual views; combined review sheets are still refreshed.')
    args=parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    out=args.output.resolve()
    if out.is_relative_to(ROOT):raise ValueError('Build candidate outside repository; final library copy is coordinated after visual review.')
    out.mkdir(parents=True,exist_ok=True);(out/'individual').mkdir(exist_ok=True)
    for concept in ('rocks','groundcover','palms'):
        if not (CONCEPTS/(concept+'.png')).is_file():raise ValueError('Actual reviewed concept image is required')
    bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
    models=rocks()+shrubs()+grasses()+[palm('palm_curved_a'),palm('palm_leaning_b',True)]
    assert tuple(m.name for m in models)==VARIANTS
    mat=material();objects=[m.object(mat) for m in models]
    export(objects,out)
    for obj in objects:export([obj],out/'individual',obj.name+'.glb')
    camera=studio(objects,out,not args.no_render)
    if not args.no_render:render_individual_views(objects,camera,out,set(args.preview_ids.split(',')) if args.preview_ids else None)
    bpy.ops.wm.save_as_mainfile(filepath=str(out/'ground-props.blend'))
    report=glb_stats(out/'ground-props.glb');report.update(revision=REVISION,source_blend_sha256=sha(out/'ground-props.blend'),source_tool_sha256=sha(__file__),
        concepts={n:sha(CONCEPTS/(n+'.png')) for n in ('rocks','groundcover','palms')},
        source_display_order=list(VARIANTS),modeling_notes={o.name:json.loads(o['parts']) for o in objects},
        delivery='standalone library; no terrain, runtime config or 017 placement changes')
    write_json(out/'library-report.json',report)
    write_json(out/'ground-props-catalog.json',catalog(out,report))
    print('LIBRARY018_EXPORTED',json.dumps({k:v for k,v in report.items() if k not in ('modeling_notes',)}),flush=True)


if __name__=='__main__':main()
