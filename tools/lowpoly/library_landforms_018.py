#!/usr/bin/env python3
"""Author and export the independent TERRAIN-LIBRARY-018 landforms in Blender.

This tool does not read or write the production planet. The nine builders are
concept-driven; the export contract is one Y-up GLB per asset, grounded at Y=0.
Run with Blender --background --factory-startup --python-exit-code 1 --python
tools/lowpoly/library_landforms_018.py -- [options].
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
EVIDENCE = Path("/Users/chengzeyuan/SilkRoadEvidence/planet-props-018/library/landforms")
ASSETS = {
    "mountain_ridge": "mountains",
    "mountain_massif": "mountains",
    "mountain_mesa": "mountains",
    "snow_alpine": "snow-mountains",
    "snow_glacier": "snow-mountains",
    "snow_twin": "snow-mountains",
    "hill_rolling": "hills",
    "hill_crescent": "hills",
    "hill_terraced": "hills",
}
COLORS = {
    'stone':'A49884', 'stone_light':'B8AA91', 'stone_dark':'8F8678',
    'talus':'B6A58A', 'mesa_sand':'BD9866', 'mesa_cap':'D3AD72',
    'mesa_strata':'9D7C57', 'slate':'76818A', 'slate_dark':'64717D',
    'snow':'EAEDE6', 'ice':'9BC7D2', 'ice_light':'B7DADB',
    'meadow':'8C9B50', 'meadow_light':'A2AE61', 'meadow_dark':'7D8F49',
    'earth':'B5A078',
}


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def linear_channel(value):
    value = int(value, 16) / 255.0
    return value / 12.92 if value < 0.04045 else ((value + .055) / 1.055) ** 2.4


def make_material(name, color):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = tuple(linear_channel(color[i:i+2]) for i in (0, 2, 4)) + (1,)
    mat.use_nodes = True
    mat.use_backface_culling = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = mat.diffuse_color
    shader.inputs["Roughness"].default_value = .87
    shader.inputs["Metallic"].default_value = 0
    if name == 'meadow':
        colors=mat.node_tree.nodes.new('ShaderNodeVertexColor')
        colors.layer_name='landform_color'
        shader.inputs['Base Color'].default_value=(1,1,1,1)
        mat.node_tree.links.new(colors.outputs['Color'],shader.inputs['Base Color'])
    return mat


class Surface:
    """Closed indexed geometry with true coplanar material partitions."""

    def __init__(self, asset_id):
        self.asset_id = asset_id
        self.vertices = []
        self.faces = []
        self.materials = []
        self.features = []
        self.support_boundary = []
        self.landmarks = {}
        self._lookup = {}

    def vertex(self, co):
        # Blender stores float32 positions; canonicalize before edge welding so
        # a bottom polygon returned through mathutils shares the exact rim.
        co = tuple(float(v) for v in Vector(co))
        key = tuple(round(v, 9) for v in co)
        if key not in self._lookup:
            self._lookup[key] = len(self.vertices)
            self.vertices.append(co)
        return self._lookup[key]

    def face(self, coordinates, material):
        indices = [self.vertex(co) for co in coordinates]
        for j in range(1, len(indices) - 1):
            tri = [indices[0], indices[j], indices[j + 1]]
            a, b, c = [Vector(self.vertices[i]) for i in tri]
            if (b - a).cross(c - a).length <= 1e-10:
                continue
            self.faces.append(tri)
            self.materials.append(material)

    def split_face(self, coordinates, signed_distance, lower, upper):
        """Cut one existing planar face at a field's linear vertex crossing.

        The two materials reuse the exact interpolated cut vertices. This
        creates no shell, displacement, or overlapping overlay snow triangles.
        """
        polygons = [[], []]
        for index, co in enumerate(coordinates):
            other = coordinates[(index + 1) % len(coordinates)]
            d0, d1 = signed_distance(co), signed_distance(other)
            for side in (0, 1):
                if (d0 <= 0) if side == 0 else (d0 >= 0):
                    polygons[side].append(co)
                if (d0 < 0 < d1) or (d1 < 0 < d0):
                    t = d0 / (d0 - d1)
                    polygons[side].append(tuple(a + (b - a)*t for a, b in zip(co, other)))
        for polygon, material in zip(polygons, (lower, upper)):
            if len(polygon) >= 3:
                self.face(polygon, material)

    def close_base(self, boundary, material):
        """A model's actual underside, not an added display plinth."""
        self.support_boundary = [tuple(p) for p in boundary]
        from mathutils.geometry import tessellate_polygon
        polygon = [Vector(v) for v in reversed(boundary)]
        for tri in tessellate_polygon([polygon]):
            self.face([polygon[i] if isinstance(i,int) else i for i in tri], material)

    def object(self, collection, palette):
        # Independent assets use their ground-footprint bounding center as
        # origin. This is translation only, never implicit rescaling.
        dx=(min(v[0] for v in self.vertices)+max(v[0] for v in self.vertices))*.5
        dy=(min(v[1] for v in self.vertices)+max(v[1] for v in self.vertices))*.5
        self.vertices=[(x-dx,y-dy,z) for x,y,z in self.vertices]
        if self.asset_id.startswith('hill_'):
            self.materials=['meadow' if name.startswith('meadow') else name for name in self.materials]
        self.support_boundary=[(x-dx,y-dy,z) for x,y,z in self.support_boundary]
        for key,value in self.landmarks.items():
            if 'direction' in key:
                continue
            if isinstance(value,(list,tuple)) and len(value)==3 and isinstance(value[0],(int,float)):
                self.landmarks[key]=(value[0]-dx,value[1]-dy,value[2])
            else:
                self.landmarks[key]=[(x-dx,y-dy,z) for x,y,z in value]
        mesh = bpy.data.meshes.new(self.asset_id + "_geometry")
        mesh.from_pydata(self.vertices, [], self.faces)
        mesh.update()
        names = list(dict.fromkeys(self.materials))
        for name in names:
            mesh.materials.append(palette[name])
        for polygon, name in zip(mesh.polygons, self.materials):
            polygon.material_index = names.index(name)
            polygon.use_smooth = False
        bm = bmesh.new()
        bm.from_mesh(mesh)
        # CDT intersections and snow cuts can create microscopically close
        # vertices. Collapse those vertices topologically, keeping the solid
        # closed rather than deleting tiny faces and leaving a hole.
        bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=2e-5)
        bmesh.ops.dissolve_degenerate(bm, edges=list(bm.edges), dist=1e-7)
        bmesh.ops.triangulate(bm, faces=list(bm.faces))
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        bm.to_mesh(mesh)
        bm.free()
        if self.asset_id.startswith('hill_'):
            meadow_index=names.index('meadow')
            # Earth only appears on a true steep exposed ledge; never on a
            # smooth hillside merely because it crosses a color-band radius.
            for polygon in mesh.polygons:
                if names[polygon.material_index]=='earth' and polygon.normal.z>.82:
                    polygon.material_index=meadow_index
            attribute=mesh.color_attributes.new(name='landform_color',type='FLOAT_COLOR',domain='CORNER')
            mesh.color_attributes.active_color=attribute
            dark=tuple(linear_channel(COLORS['meadow_dark'][i:i+2]) for i in (0,2,4))
            light=tuple(linear_channel(COLORS['meadow_light'][i:i+2]) for i in (0,2,4))
            maximum=max(v.co.z for v in mesh.vertices)
            for polygon in mesh.polygons:
                for loop_index in polygon.loop_indices:
                    v=mesh.vertices[mesh.loops[loop_index].vertex_index].co
                    if names[polygon.material_index]=='meadow':
                        t=clamp(.30+.36*v.z/maximum+.10*math.sin(1.8*v.x+.8*v.y)+.09*math.cos(2*v.y))
                        attribute.data[loop_index].color=tuple(mix(a,b,t) for a,b in zip(dark,light))+(1,)
                    else:
                        attribute.data[loop_index].color=(1,1,1,1)
        obj = bpy.data.objects.new(self.asset_id, mesh)
        collection.objects.link(obj)
        obj["asset_id"] = self.asset_id
        obj["category"] = ASSETS[self.asset_id]
        obj["ground_axis_blender"] = "Z"
        obj["ground_axis_gltf"] = "Y"
        obj["ground_height"] = 0.0
        obj["features"] = json.dumps(self.features)
        return obj


def emit_face(surface, points, appearance):
    """Apply one coherent field to a triangle; never random face colors."""
    center = tuple(sum(p[i] for p in points) / len(points) for i in range(3))
    style = appearance(center) if callable(appearance) else appearance
    if isinstance(style, str):
        surface.face(points, style)
    else:
        field, lower, upper = style
        surface.split_face(points, field, lower, upper)


def grid_patch(surface, rows, appearance, base_material):
    """Triangulate a continuous authored surface chart and close its base.

    Rows are ordered along the long axis; columns run across the chart.
    Its perimeter is the actual irregular landform footprint at z=0.
    """
    for i in range(len(rows) - 1):
        for j in range(len(rows[0]) - 1):
            a, b, c, d = rows[i][j], rows[i+1][j], rows[i+1][j+1], rows[i][j+1]
            if (i + j) % 2:
                triangles = [(a,b,d),(b,c,d)]
            else:
                triangles = [(a,b,c),(a,c,d)]
            for tri in triangles:
                emit_face(surface, tri, appearance)
    perimeter = [row[0] for row in rows] + rows[-1][1:]
    perimeter += [row[-1] for row in reversed(rows[:-1])]
    perimeter += list(reversed(rows[0][1:-1]))
    unique = []
    for point in perimeter:
        if not unique or (Vector(point) - Vector(unique[-1])).length > 1e-8:
            unique.append(point)
    if len(unique) > 1 and (Vector(unique[-1]) - Vector(unique[0])).length < 1e-8:
        unique.pop()
    assert max(abs(p[2]) for p in unique) < 1e-8
    surface.close_base(unique, base_material)


def radial_patch(surface, rings, center, appearance, base_material):
    """Triangulate rings with an authored non-circular outline, no pedestal."""
    count = len(rings[0])
    for j in range(count):
        emit_face(surface, [center, rings[0][j], rings[0][(j+1)%count]], appearance)
    for row in range(len(rings) - 1):
        for j in range(count):
            nj = (j+1) % count
            a,b,c,d = rings[row][j],rings[row+1][j],rings[row+1][nj],rings[row][nj]
            if (row+j) % 2:
                triangles = [(a,b,d),(b,c,d)]
            else:
                triangles = [(a,b,c),(a,c,d)]
            for tri in triangles:
                emit_face(surface, tri, appearance)
    assert max(abs(p[2]) for p in rings[-1]) < 1e-8
    surface.close_base(rings[-1], base_material)


def clamp(value, low=0., high=1.):
    return max(low, min(high, value))


def mix(a, b, t):
    return a * (1-t) + b * t


def smoothstep(a, b, value):
    t = clamp((value-a)/(b-a))
    return t*t*(3-2*t)


def profile_at(value, points):
    if value <= points[0][0]:
        return points[0][1]
    for (a,x),(b,y) in zip(points,points[1:]):
        if value <= b:
            return mix(x,y,(value-a)/(b-a))
    return points[-1][1]


def inside_polygon(point, polygon):
    x,y = point
    inside = False
    for (ax,ay),(bx,by) in zip(polygon, polygon[1:]+polygon[:1]):
        if ((ay > y) != (by > y)) and x < (bx-ax)*(y-ay)/(by-ay)+ax:
            inside = not inside
    return inside


def outline(rx, ry, count=64, phase=0., lopsided=0.):
    points=[]
    for i in range(count):
        a=math.tau*i/count
        f=1+.04*math.sin(3*a+phase)+.025*math.sin(7*a+1.3*phase)+lopsided*math.cos(a)
        points.append((rx*f*math.cos(a),ry*f*math.sin(a)))
    return points


def triangulated_land(surface, boundary, height, appearance, base_material,
                     spacing=.125, features=None, feature_edges=None):
    """Constrained, irregularly sampled heightfield; all landforms stay solid.

    Feature curves, ledges and summit vertices constrain the triangulation.
    Jitter affects tessellation only, never random height or triangle colors.
    """
    from mathutils.geometry import delaunay_2d_cdt
    points=list(boundary)
    count=len(points)
    edges=[(i,(i+1)%count) for i in range(count)]
    offset=len(points)
    points += features or []
    edges += [(offset+a,offset+b) for a,b in (feature_edges or [])]
    lo=[min(p[i] for p in boundary) for i in (0,1)]
    hi=[max(p[i] for p in boundary) for i in (0,1)]
    nx=math.ceil((hi[0]-lo[0])/spacing)
    ny=math.ceil((hi[1]-lo[1])/spacing)
    for j in range(1,ny):
        for i in range(1,nx):
            x=lo[0]+(i+.2*math.sin(i*3.7+j*1.9))*(hi[0]-lo[0])/nx
            y=lo[1]+(j+.2*math.sin(i*1.3-j*2.8))*(hi[1]-lo[1])/ny
            if inside_polygon((x,y),boundary):
                if min((x-a)**2+(y-b)**2 for a,b in points) > (spacing*.22)**2:
                    points.append((x,y))
    coords,_,faces,orig,_,_=delaunay_2d_cdt([Vector(p) for p in points],edges,[],0,1e-7,True)
    vertices=[]
    boundary_output={}
    for i,(co,sources) in enumerate(zip(coords,orig)):
        edge_sources=[index for index in sources if index<count]
        z=0. if edge_sources else max(.025*taper_to_outline(co.x,co.y,boundary),height(co.x,co.y))
        vertices.append((co.x,co.y,z))
        for source in edge_sources:
            boundary_output[source]=vertices[-1]
    assert len(boundary_output)==count
    for face in faces:
        center=tuple(sum(coords[i][axis] for i in face)/len(face) for axis in (0,1))
        if inside_polygon(center,boundary):
            emit_face(surface,[vertices[i] for i in face],appearance)
    surface.close_base([boundary_output[i] for i in range(count)],base_material)


class Peak:
    """An asymmetrical folded rock volume with structural shoulder ledges."""

    def __init__(self,x,y,h,rx,ry,phase=0.,kind='rock',rotation=0.,ledge=.65):
        self.x,self.y,self.h,self.rx,self.ry=x,y,h,rx,ry
        self.phase,self.kind,self.rotation,self.ledge=phase,kind,rotation,ledge

    def plan(self,r,a):
        rough=.25 if self.kind in ('rock','massif','buttress') else (.10 if self.kind=='mesa' else .025)
        fold=1+rough*math.sin(3*a+self.phase)+rough*.52*math.sin(5*a+1.2+self.phase)
        # A few deliberate buttresses shift with height, rather than cone rings.
        fold += rough*.48*math.sin(2*a-3*r+self.phase)*math.sin(math.pi*r)
        xx=self.rx*r*fold*math.cos(a)
        yy=self.ry*r*fold*math.sin(a)
        if self.kind in ('rock','massif','buttress'):
            xx += self.rx*.22*r*math.cos(self.phase)
            yy += self.ry*.20*r*math.sin(self.phase)
        c,s=math.cos(self.rotation),math.sin(self.rotation)
        return (self.x+c*xx-s*yy,self.y+s*xx+c*yy)

    def radius(self,x,y):
        c,s=math.cos(self.rotation),math.sin(self.rotation)
        dx,dy=x-self.x,y-self.y
        xx=(c*dx+s*dy)/self.rx
        yy=(-s*dx+c*dy)/self.ry
        r=math.hypot(xx,yy)
        rough=.25 if self.kind in ('rock','massif','buttress') else (.10 if self.kind=='mesa' else .025)
        for _ in range(12):
            xxx,yyy=xx,yy
            if self.kind in ('rock','massif','buttress'):
                xxx -= .22*r*math.cos(self.phase)
                yyy -= .20*r*math.sin(self.phase)
            a=math.atan2(yyy,xxx)
            raw=math.hypot(xxx,yyy)
            fold=1+rough*math.sin(3*a+self.phase)+rough*.52*math.sin(5*a+1.2+self.phase)
            fold += rough*.48*math.sin(2*a-3*r+self.phase)*math.sin(math.pi*min(r,1))
            r=mix(r,raw/fold,.55)
        return r,a

    def height(self,x,y):
        r,a=self.radius(x,y)
        if r>=1:
            return 0.
        if self.kind=='mesa':
            p=[(0,1),(.40,.99),(.45,.985),(.475,.80),(.515,.79),(.545,.62),(.61,.59),(.655,.37),(.74,.28),(1,0)]
            z=profile_at(r,p)
            z += .018*math.sin(2*a+.4)*min(r/.3,1)*(1-r)
        elif self.kind=='dome':
            z=max(0,1-r*r)**1.5
        elif self.kind=='hill':
            z=max(0,1-r*r)**2.1
        elif self.kind=='terrace':
            rounded=max(0,1-r*r)**1.85
            terraced=profile_at(r,[(0,1),(.22,.94),(.32,.84),(.43,.79),(.465,.54),(.61,.47),(.65,.28),(.79,.23),(1,0)])
            side=.25+.75*smoothstep(-.3,.6,-math.sin(a))
            z=mix(rounded,terraced,side)
        elif self.kind=='buttress':
            z=profile_at(r,[(0,1),(.22,.96),(.38,.89),(.45,.47),(.62,.32),(1,0)])
            z += .07*math.sin(2*a+self.phase)*r*(1-r)
        else:
            linear=max(0,1-r)**1.25
            if self.kind=='massif':
                linear=profile_at(r,[(0,1),(.10,.985),(.19,.935),(.29,.74),(.46,.54),(.70,.24),(1,0)])
            ledged=profile_at(r,[(0,1),(.16,.80),(.25,.72),(.30,.695),(.345,.50),(.52,.43),(.57,.27),(.76,.14),(1,0)])
            shelf=self.ledge*max(0,-math.sin(a))**2
            z=mix(linear,ledged,shelf)
            # Broad fractured faces and diagonal ribs are actual relief.
            z += .14*math.sin(3*a+2.3*r+self.phase)*r*(1-r)
        return self.h*max(0,z)

    def constraints(self):
        radii={'mesa':[.20,.40,.45,.475,.515,.545,.61,.655,.74,.90],
               'rock':[.12,.25,.30,.345,.52,.57,.76],
               'massif':[.10,.19,.25,.30,.345,.46,.52,.57,.76],
               'buttress':[.22,.38,.45,.62,.82],
               'dome':[.2,.4,.6,.8], 'hill':[.25,.5,.7,.87],
               'terrace':[.24,.43,.465,.61,.65,.79,.9]}[self.kind]
        points=[(self.x,self.y)]
        edges=[]
        n=24 if self.kind=='mesa' else 18
        for r in radii:
            start=len(points)
            points += [self.plan(r,math.tau*i/n) for i in range(n)]
            edges += [(start+i,start+(i+1)%n) for i in range(n)]
        return points,edges


def peak_constraints(peaks,boundary):
    points,edges=[],[]
    for peak in peaks:
        pp,ee=peak.constraints()
        # Every authored peak ring is chosen inside its asset's footprint.
        keep={i:len(points)+j for j,i in enumerate(i for i,p in enumerate(pp) if inside_polygon(p,boundary))}
        points += [p for i,p in enumerate(pp) if i in keep]
        edges += [(keep[a],keep[b]) for a,b in ee if a in keep and b in keep]
    return points,edges


def taper_to_outline(x,y,boundary):
    distance=1e9
    for (ax,ay),(bx,by) in zip(boundary,boundary[1:]+boundary[:1]):
        t=clamp(((x-ax)*(bx-ax)+(y-ay)*(by-ay))/((bx-ax)**2+(by-ay)**2))
        distance=min(distance,math.hypot(x-mix(ax,bx,t),y-mix(ay,by,t)))
    return smoothstep(0,.14,distance)


def rock_style(center):
    x,y,z=center
    if z<.15:
        return 'talus'
    if y>.22+.15*math.sin(2*x) and z<.85:
        return 'stone_dark'
    return 'stone'


def mountain_ridge():
    s=Surface('mountain_ridge')
    boundary=outline(2.25,.90,72,.8)
    peaks=[Peak(-1.50,.04,.83,.60,.68,.2,ledge=.6),
           Peak(-.67,.08,1.70,.79,.86,.9,ledge=.85),
           Peak(.25,-.04,1.08,.59,.66,1.7,ledge=.85),
           Peak(.98,.12,.90,.53,.63,2.6,ledge=.7),
           Peak(1.58,-.04,.62,.47,.55,3.2,ledge=.6)]
    buttresses=[Peak(-.97,-.39,.85,.35,.52,.4,kind='buttress',rotation=-.3),
                Peak(-.31,-.38,.72,.30,.52,1.8,kind='buttress',rotation=.3),
                Peak(.31,-.37,.48,.28,.42,2.4,kind='buttress'),
                Peak(1.12,-.27,.41,.27,.42,1.2,kind='buttress')]
    def height(x,y):
        base=.09*max(0,1-(x/2.25)**2-(y/.9)**2)
        return max(base,*[p.height(x,y) for p in peaks+buttresses])*taper_to_outline(x,y,boundary)
    points,edges=peak_constraints(peaks+buttresses,boundary)
    triangulated_land(s,boundary,height,rock_style,'talus',.14,points,edges)
    s.features=['Five unequal connected summits; highest is second from west.',
                'Long narrow irregular ground-level footprint.',
                'Authored shoulder shelves, diagonal ribs and deep intervening saddles are mesh relief.']
    s.landmarks={'summits':[(p.x,p.y,p.h) for p in peaks]}
    return s


def mountain_massif():
    s=Surface('mountain_massif')
    boundary=outline(1.62,1.42,68,1.9,.03)
    peaks=[Peak(-.63,-.26,1.31,1.05,.99,.45,kind='massif',rotation=-.2,ledge=1.),
           Peak(.04,.47,1.66,.99,.94,1.8,kind='massif',rotation=.35,ledge=.92),
           Peak(.71,-.21,1.09,.91,.86,3.,kind='massif',rotation=-.25,ledge=1.)]
    buttresses=[Peak(-.79,-.62,.66,.45,.53,.6,kind='buttress'),
                Peak(-.21,-.25,.80,.33,.50,1.7,kind='buttress'),
                Peak(.49,-.62,.59,.45,.51,2.2,kind='buttress'),
                Peak(.71,.18,.74,.46,.40,.1,kind='buttress')]
    def height(x,y):
        base=.1*max(0,1-(x/1.62)**2-(y/1.42)**2)
        h=max(base,*[p.height(x,y) for p in peaks+buttresses])
        # Exposed central ravine runs forward from the folded high shoulder.
        gorge=.17*math.exp(-((x-.04-.13*y)/.15)**2)*smoothstep(.55,-.7,y)
        return max(base,h-gorge)*taper_to_outline(x,y,boundary)
    points,edges=peak_constraints(peaks+buttresses,boundary)
    triangulated_land(s,boundary,height,rock_style,'talus',.135,points,edges)
    s.features=['Three broad interlocking asymmetrical summits in a compact body.',
                'Deep front-facing central ravine carved into the continuous surface.',
                'Large folded rock faces with physically projecting shoulder ledges.']
    s.landmarks={'summits':[(p.x,p.y,p.h) for p in peaks], 'ravine_outlet':(.1,-.95,height(.1,-.95))}
    return s


def mountain_mesa():
    s=Surface('mountain_mesa')
    boundary=outline(1.95,1.15,72,2.8,.03)
    peaks=[Peak(-.74,.09,1.20,1.18,1.08,.2,kind='mesa'),
           Peak(.94,-.03,.70,.80,.82,2.1,kind='mesa')]
    def height(x,y):
        connection=.17*math.exp(-((x-.1)/.9)**2-(y/.48)**2)
        return max(connection,*[p.height(x,y) for p in peaks])*taper_to_outline(x,y,boundary)
    def appearance(center):
        x,y,z=center
        peak=max(peaks,key=lambda p:p.height(x,y))
        r,a=peak.radius(x,y)
        if z<.13: return 'talus'
        if r<.46: return 'mesa_cap'
        return 'mesa_strata' if .50<r<.55 or .63<r<.69 else 'mesa_sand'
    points,edges=peak_constraints(peaks,boundary)
    triangulated_land(s,boundary,height,appearance,'talus',.14,points,edges)
    s.features=['Two unequal broad flat-topped buttes, not pointed mountain recolors.',
                'Chipped irregular cap outlines and near-vertical geological walls.',
                'Three broad structural strata, eroded talus and a low connecting saddle.']
    s.landmarks={'plateau_centers':[(p.x,p.y,p.h) for p in peaks]}
    return s


def snow_material(peaks, diagonal=.08, base=.55):
    def field(co):
        x,y,z=co
        threshold=base+diagonal*x+.11*math.sin(3*x+1.6*y)+.08*math.sin(5*y-1.3*x)
        # A few continuous dark ribs, not independent white cone overlays.
        p=max(peaks,key=lambda p:p.height(x,y))
        r,a=p.radius(x,y)
        rib=max(0,math.cos(4*a+.7*p.phase)-.35)/.65
        threshold += p.h*.68*rib*smoothstep(.04,.22,r)
        return z-threshold
    return field


def snow_alpine():
    s=Surface('snow_alpine')
    boundary=outline(2.03,1.03,72,.5)
    peaks=[Peak(-1.12,.10,1.90,.80,.85,.4,ledge=.32),
           Peak(-.14,.19,1.36,.69,.79,1.4,ledge=.22),
           Peak(.70,.08,1.08,.67,.80,2.3,ledge=.45),
           Peak(1.34,.18,.77,.53,.67,3.1,ledge=.36)]
    foothills=[Peak(-1.22,-.44,.46,.42,.58,1.7,kind='buttress'),
               Peak(-.36,-.49,.40,.42,.47,.6,kind='buttress'),
               Peak(.85,-.47,.30,.36,.42,2.6,kind='buttress')]
    field=snow_material(peaks,.07,.46)
    spine=[(-1.12,.10,1.90),(-.66,.14,.68),(-.14,.19,1.36),
           (.28,.135,.51),(.70,.08,1.08),(1.03,.13,.39),(1.34,.18,.77)]
    def height(x,y):
        base=.11*max(0,1-(x/2.03)**2-(y/1.03)**2)
        connection=0
        if spine[0][0]<x<spine[-1][0]:
            cy=profile_at(x,[(a,b) for a,b,c in spine])
            h=profile_at(x,[(a,c) for a,b,c in spine])
            connection=h*max(0,1-abs(y-cy)/.62)**1.4
        return max(base,connection,*[p.height(x,y) for p in peaks+foothills])*taper_to_outline(x,y,boundary)
    points,edges=peak_constraints(peaks+foothills,boundary)
    start=len(points)
    points += [(x,y) for x,y,z in spine]
    edges += [(start+i,start+i+1) for i in range(len(spine)-1)]
    triangulated_land(s,boundary,height,lambda c:(field,'slate','snow'),'slate',.14,points,edges)
    s.features=['Four unequal connected alpine peaks with a strongly dominant high summit.',
                'Jagged diagonal snowline follows the actual rock surface.',
                'Exposed slate ribs and small real shoulder ledges interrupt the snow.']
    s.landmarks={'summits':[(p.x,p.y,p.h) for p in peaks]}
    return s


def snow_glacier():
    s=Surface('snow_glacier')
    boundary=outline(1.62,1.54,72,.9)
    dome=Peak(.03,.45,1.48,1.06,.96,.6,kind='dome')
    rocks=[Peak(-.76,.22,.97,.73,.95,.3,ledge=.25),
           Peak(.77,.16,1.03,.69,.89,1.9,ledge=.25),
           Peak(-.57,-.60,.68,.55,.72,2.1,ledge=.15),
           Peak(.63,-.60,.61,.53,.67,2.9,ledge=.15)]
    peaks=[dome]+rocks
    def channel_x(y): return .025+.07*math.sin(2.7*y)
    def channel_width(y): return .30+.12*smoothstep(-1.25,.4,y)
    bank_y=[-1.42,-1.30,-1.15,-.98,-.80,-.63,-.44,-.24,-.04,.15,.33,.46]
    left_bank=[]
    right_bank=[]
    for y in bank_y:
        half=channel_width(y)*.85*smoothstep(-1.42,-1.15,y)
        # Two broad natural indentations, not alternating triangle-sized teeth.
        left=half*(1-.09*math.exp(-((y+.30)/.20)**2))
        right=half*(1-.075*math.exp(-((y+.93)/.17)**2))
        left_bank.append((channel_x(y)-left,y))
        right_bank.append((channel_x(y)+right,y))
    ice_polygon=left_bank+list(reversed(right_bank[1:]))
    def channel_height(y):
        return profile_at(y,[(-1.5,0),(-1.25,.07),(-.85,.26),(-.45,.49),(-.08,.80),(.30,1.08),(.55,1.27)])
    def height(x,y):
        base=.08*max(0,1-(x/1.62)**2-(y/1.54)**2)
        h=max(base,*[p.height(x,y) for p in peaks])
        cx,cw=channel_x(y),channel_width(y)
        lateral=abs(x-cx)/cw
        if -1.48<y<.54 and lateral<1.2:
            bed=channel_height(y)+.10*lateral*lateral
            bed += .028*math.cos((x-cx)*29+1.8*y)*smoothstep(-1.42,-.7,y)
            blend=(1-smoothstep(.78,1.18,lateral))*smoothstep(-1.5,-1.27,y)*(1-smoothstep(.40,.55,y))
            h=mix(h,max(.012,bed),blend)
        return h*taper_to_outline(x,y,boundary)
    def appearance(center):
        x,y,z=center
        snowfield=lambda p:p[2]-(.89+.10*math.sin(2*p[0]+p[1]))
        if inside_polygon((x,y),ice_polygon):
            ice='ice_light' if math.cos((x-channel_x(y))*16+1.3*y)>.45 else 'ice'
            return (snowfield,ice,'snow')
        return (snowfield, 'slate_dark','snow')
    points,edges=peak_constraints(peaks,boundary)
    # Force the actual surface triangulation to honor both continuous banks.
    # The material interior uses this exact same polygon, so a per-face
    # classification cannot create alternating large zigzag edge teeth.
    bank_start=len(points)
    points += ice_polygon
    edges += [(bank_start+i,bank_start+(i+1)%len(ice_polygon)) for i in range(len(ice_polygon))]
    for yy in [-1.4+i*.09 for i in range(22)]:
        points += [(channel_x(yy)+f*channel_width(yy),yy) for f in [-1,-.7,-.35,0,.35,.7,1]]
    triangulated_land(s,boundary,height,appearance,'slate_dark',.125,points,edges)
    s.features=['Broad rounded snow dome contrasts with angular lower rock shoulders.',
                'Wide concave glacial tongue descends between continuous rock banks with a tapering terminus.',
                'Icy-blue longitudinal groove relief is sculpted into the continuous mountain surface.']
    s.landmarks={'dome':(dome.x,dome.y,dome.h),
                 'glacier_centerline':[(channel_x(y),y,height(channel_x(y),y)) for y in [-1.25,-.85,-.45,-.08,.3]]}
    return s


def snow_twin():
    s=Surface('snow_twin')
    boundary=outline(1.66,1.16,68,2.5)
    peaks=[Peak(-.59,.18,1.78,.72,.74,.2,ledge=.20),
           Peak(.64,.18,1.40,.63,.70,2.1,ledge=.26)]
    buttresses=[Peak(-1.09,-.35,.43,.47,.61,1.3,ledge=.3),
                Peak(1.02,-.31,.40,.43,.55,3.,ledge=.2)]
    def height(x,y):
        saddle=.36*math.exp(-((x-.01)/.72)**4-((y-.12)/.66)**2)
        base=.08*max(0,1-(x/1.66)**2-(y/1.16)**2)
        return max(base,saddle,*[p.height(x,y) for p in peaks+buttresses])*taper_to_outline(x,y,boundary)
    field=snow_material(peaks,.06,.52)
    def snowfield(p):
        x,y,z=p
        if abs(x)<.31 and -.4<y<.48:
            return z-.23-.09*math.sin(4*y)
        return field(p)
    points,edges=peak_constraints(peaks+buttresses,boundary)
    points += [(x,.12) for x in [-.4,-.3,-.2,-.1,0,.1,.2,.3,.4]]
    triangulated_land(s,boundary,height,lambda c:(snowfield,'slate','snow'),'slate',.13,points,edges)
    s.features=['Two unequal slender high peaks dominate a broad low footprint.',
                'Pronounced U-shaped snowy saddle and short subordinate rock buttresses.',
                'Asymmetrical patchy caps are cut directly into the rock surface.']
    s.landmarks={'summits':[(p.x,p.y,p.h) for p in peaks], 'saddle':(0,.12,height(0,.12))}
    return s


def meadow_style(center):
    x,y,z=center
    if z>.40 and y<.3+.15*math.sin(2.2*x): return 'meadow_light'
    if y>.45-.2*x: return 'meadow_dark'
    return 'meadow'


def hill_rolling():
    s=Surface('hill_rolling')
    boundary=outline(1.62,1.20,66,.2,.03)
    peaks=[Peak(-.55,.37,.67,1.10,.91,.2,kind='hill'),
           Peak(.78,.11,.48,.91,.77,2.2,kind='hill'),
           Peak(-.38,-.67,.34,.91,.75,1.4,kind='hill')]
    def height(x,y):
        heights=[p.height(x,y) for p in peaks]
        base=.09*max(0,1-(x/1.62)**2-(y/1.20)**2)
        return max(base,sum(h**4 for h in heights)**.25)*taper_to_outline(x,y,boundary)
    points,edges=peak_constraints(peaks,boundary)
    triangulated_land(s,boundary,height,meadow_style,'meadow',.14,points,edges)
    s.features=['Three unequal broad rounded humps arranged diagonally.',
                'Gentle continuous traversable saddles rather than stacked spheres.',
                'Irregular oval meadow footprint with broad coherent green fields.']
    s.landmarks={'humps':[(p.x,p.y,height(p.x,p.y)) for p in peaks]}
    return s


def hill_crescent():
    s=Surface('hill_crescent')
    begin,end=-.16*math.pi,1.16*math.pi
    boundary=[]
    for i in range(43):
        u=i/42
        a=mix(begin,end,u)
        r=1.22+.69*math.sin(math.pi*u)**.55
        boundary.append((r*math.cos(a),.83*r*math.sin(a)))
    left,right=boundary[-1],boundary[0]
    # A low shallow bowl fills the center. Its front edge remains open and
    # gently indented, instead of cutting a hole down to the studio floor.
    boundary += [(mix(left[0],right[0],t),mix(left[1],right[1],t)+.18*math.sin(math.pi*t))
                 for t in [i/12 for i in range(1,12)]]
    def height(x,y):
        a=math.atan2(y/.83,x)
        if a<begin: a+=math.tau
        u=clamp((a-begin)/(end-begin))
        radius=math.hypot(x,y/.83)
        ridge_radius=1.22+.055*math.sin(2.8*a)
        # The high western end is deliberately much taller and blunter than
        # the low eastern tail; they no longer form a uniform U-shaped tube.
        high=.13+.73*math.exp(-((u-.71)/.235)**2)
        high*=smoothstep(0,.13,u)*(1-smoothstep(.91,1.,u))
        ridge=high*math.exp(-((radius-ridge_radius)/.40)**2)
        basin=.065+.035*(radius/1.25)**2
        return max(basin,ridge)*taper_to_outline(x,y,boundary)
    points=[]
    edges=[]
    for radius in [.28,.55,.78,1.,1.22,1.42,1.60]:
        last=None
        for i in range(29):
            a=mix(begin+.08,end-.08,i/28)
            p=(radius*math.cos(a),.83*radius*math.sin(a))
            if inside_polygon(p,boundary):
                current=len(points);points.append(p)
                if last is not None: edges.append((last,current))
                last=current
    points.append((0,0))
    def style(center):
        x,y,z=center
        if y>.25 and .34<z<.62 and x<-.25: return 'earth'
        return meadow_style(center)
    triangulated_land(s,boundary,height,style,'meadow',.12,points,edges)
    s.features=['Crescent ridge wraps around a modeled shallow grassy inner bowl, with a low front outlet.',
                'High blunt western end contrasts with the substantially lower eastern tail.',
                'Continuous inner slope reaches the bowl floor; no hole exposing the studio floor.']
    s.landmarks={'opening_direction_blender':(0,-1,0),
                 'bowl_floor':(0,0,height(0,0)),
                 'high_end':(-.90,.68,height(-.90,.68)),
                 'low_end':(1.10,.18,height(1.10,.18))}
    return s


def hill_terraced():
    s=Surface('hill_terraced')
    boundary=outline(1.65,1.16,68,1.5,.025)
    peaks=[Peak(-.65,.16,.65,1.15,.96,.3,kind='terrace'),
           Peak(.82,.02,.42,.94,.90,2.1,kind='terrace')]
    def height(x,y):
        base=.09*max(0,1-(x/1.65)**2-(y/1.16)**2)
        # A winding shallow depression stays open between the two knolls.
        h=max(base,*[p.height(x,y) for p in peaks])
        dip=.035*math.exp(-((x-.08-.18*math.sin(3*y))/.20)**2)
        return max(base,h-dip)*taper_to_outline(x,y,boundary)
    def appearance(center):
        x,y,z=center
        p=max(peaks,key=lambda p:p.height(x,y))
        r,a=p.radius(x,y)
        if math.sin(a)<.25 and (.425<r<.49 or .60<r<.68): return 'earth'
        return meadow_style(center)
    points,edges=peak_constraints(peaks,boundary)
    triangulated_land(s,boundary,height,appearance,'meadow',.14,points,edges)
    s.features=['Two unequal low knolls with a winding shallow depression.',
                'Broad eroded earthen ledges physically interrupt one flank.',
                'Rounded tops and lopsided connected footprint; no stacked disk meshes.']
    s.landmarks={'knolls':[(p.x,p.y,height(p.x,p.y)) for p in peaks]}
    return s


BUILDERS={name:globals()[name] for name in ASSETS}


def geometry_stats(obj):
    mesh = obj.data
    mesh.calc_loop_triangles()
    vertices = [v.co for v in mesh.vertices]
    bounds_blender = {
        "min": [min(v[i] for v in vertices) for i in range(3)],
        "max": [max(v[i] for v in vertices) for i in range(3)],
    }
    # Blender (x,y,z) -> glTF (x,z,-y).
    lo, hi = bounds_blender["min"], bounds_blender["max"]
    bounds = {"min": [lo[0], lo[2], -hi[1]], "max": [hi[0], hi[2], -lo[1]]}
    areas = []
    for tri in mesh.loop_triangles:
        a, b, c = [vertices[i] for i in tri.vertices]
        areas.append((b - a).cross(c - a).length * .5)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    boundary_edges = sum(1 for edge in bm.edges if edge.is_boundary)
    nonmanifold_edges = sum(1 for edge in bm.edges if not edge.is_manifold)
    remaining=set(bm.verts)
    components=0
    while remaining:
        components+=1
        queue=[remaining.pop()]
        while queue:
            vertex=queue.pop()
            for edge in vertex.link_edges:
                other=edge.other_vert(vertex)
                if other in remaining:
                    remaining.remove(other)
                    queue.append(other)
    volume = bm.calc_volume(signed=True)
    bm.free()
    assert all(math.isfinite(float(a)) for v in vertices for a in v)
    assert min(areas) > 1e-10, (obj.name, min(areas))
    assert abs(lo[2]) < 1e-7, (obj.name, lo[2])
    assert all(abs(s - 1) < 1e-7 for s in obj.scale)
    assert not nonmanifold_edges, (obj.name, boundary_edges, nonmanifold_edges)
    assert volume > 0, (obj.name, volume)
    assert components==1, (obj.name,components)
    return {
        "triangles": len(mesh.loop_triangles), "vertices": len(vertices),
        "surfaces": len(mesh.materials), "materials": [m.name for m in mesh.materials],
        "bounds": bounds, "minimum_triangle_area": min(areas),
        "boundary_edges": boundary_edges, "nonmanifold_edges": nonmanifold_edges,
        "signed_volume": volume,
        "connected_components":components,
        "topological_weld_tolerance":.00002,
    }


def point_camera(obj, point):
    obj.rotation_euler = (Vector(point) - obj.location).to_track_quat('-Z', 'Y').to_euler()


def setup_preview(evidence):
    """Preview-only objects are explicitly excluded from every GLB export."""
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 32
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 720
    scene.render.resolution_y = 640
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.film_transparent = False
    scene.world.use_nodes = True
    scene.world.node_tree.nodes.get('Background').inputs['Color'].default_value = (.78, .81, .84, 1)
    scene.world.node_tree.nodes.get('Background').inputs['Strength'].default_value = .30
    scene.view_settings.view_transform = 'AgX'
    ground_mat = make_material("preview_only_warm_ground", "DAD7CC")
    bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, -.009))
    floor = bpy.context.object
    floor.name = "PREVIEW_ONLY_FLOOR"
    floor.data.materials.append(ground_mat)
    bpy.ops.object.light_add(type='AREA', location=(-3, -4, 7))
    light = bpy.context.object
    light.name = "PREVIEW_ONLY_KEY"
    light.data.energy = 850
    light.data.shape = 'DISK'
    light.data.size = 3.8
    point_camera(light, (0, 0, .3))
    bpy.ops.object.light_add(type='AREA', location=(4, 2, 5))
    fill = bpy.context.object
    fill.name = "PREVIEW_ONLY_FILL"
    fill.data.energy = 180
    fill.data.size = 6
    point_camera(fill, (0, 0, .4))
    bpy.ops.object.camera_add(location=(4, -6, 4))
    camera = bpy.context.object
    camera.name = "PREVIEW_ONLY_CAMERA"
    camera.data.type = 'ORTHO'
    scene.camera = camera
    evidence.mkdir(parents=True, exist_ok=True)
    return camera


def render_asset(obj, camera, path, view="three-quarter"):
    lo = [min(v.co[i] for v in obj.data.vertices) for i in range(3)]
    hi = [max(v.co[i] for v in obj.data.vertices) for i in range(3)]
    center = Vector(((lo[0]+hi[0])/2, (lo[1]+hi[1])/2, (lo[2]+hi[2])/2))
    extent = max(hi[0]-lo[0], hi[1]-lo[1], (hi[2]-lo[2])*1.5)
    camera.data.ortho_scale = extent * 1.36
    direction = {"three-quarter": (4, -6, 3.8), "side": (1, -7, 1.8), "top": (0, -.001, 8)}[view]
    camera.location = center + Vector(direction)
    point_camera(camera, center)
    bpy.context.scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-root', type=Path, default=LIBRARY)
    parser.add_argument('--evidence', type=Path, default=EVIDENCE)
    parser.add_argument('--asset', choices=list(ASSETS), action='append')
    parser.add_argument('--render', action='store_true')
    parser.add_argument('--views', nargs='+', default=['three-quarter'], choices=['three-quarter','side','top'])
    args = parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    requested = args.asset or list(ASSETS)
    missing = [name for name in requested if name not in BUILDERS]
    if missing:
        raise RuntimeError('Final concept-driven builders not authored yet: ' + ', '.join(missing))
    concepts = {category: LIBRARY / 'concepts' / (category + '.png')
                for category in set(ASSETS[name] for name in requested)}
    for path in concepts.values():
        if not path.is_file():
            raise RuntimeError('Required inspected concept image is missing: ' + str(path))
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for name in ('source', 'exports'):
        (args.output_root / name).mkdir(parents=True, exist_ok=True)
    args.evidence.mkdir(parents=True, exist_ok=True)
    palette = {name: make_material(name, color) for name, color in COLORS.items()}
    rows, objects = [], []
    for asset_id in requested:
        surface = BUILDERS[asset_id]()
        collection = bpy.data.collections.new(asset_id)
        bpy.context.scene.collection.children.link(collection)
        obj = surface.object(collection, palette)
        stats = geometry_stats(obj)
        row = {
            'id': asset_id, 'category': ASSETS[asset_id],
            'glb': 'exports/' + asset_id + '.glb', 'blend': 'source/landforms.blend',
            'concept': 'concepts/' + ASSETS[asset_id] + '.png',
            'concept_sha256': sha256(concepts[ASSETS[asset_id]]),
            'features': surface.features, **stats,
            'support_boundary_blender': surface.support_boundary,
            'landmarks_blender': surface.landmarks,
            'coordinates': {'blender_up':'Z', 'gltf_up':'Y', 'ground':0,
                            'origin':'horizontal footprint AABB center on ground', 'transform_scale':[1,1,1]},
        }
        rows.append(row)
        objects.append(obj)
    # Validate every model before deploying any of the requested GLBs.
    for obj, row in zip(objects, rows):
        bpy.ops.object.select_all(action='DESELECT')
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        target = args.output_root / row['glb']
        bpy.ops.export_scene.gltf(filepath=str(target), export_format='GLB', use_selection=True,
                                  export_apply=True, export_yup=True, export_animations=False,
                                  export_materials='EXPORT', export_cameras=False,
                                  export_lights=False, export_extras=True)
        row['glb_sha256'] = sha256(target)
        row['glb_bytes'] = target.stat().st_size
        print('LANDFORM_EXPORTED', row['id'], row['triangles'], row['surfaces'], flush=True)
    camera = setup_preview(args.evidence)
    for index, obj in enumerate(objects):
        obj.location = ((index % 3 - 1) * 4.5, (index // 3 - 1) * 4.0, 0)
    camera.location = (9, -14, 15)
    camera.data.ortho_scale = 17
    point_camera(camera, (0, 0, .4))
    bpy.ops.object.select_all(action='DESELECT')
    source = args.output_root / 'source' / 'landforms.blend'
    bpy.ops.wm.save_as_mainfile(filepath=str(source),compress=True)
    catalog = {
        'schema':'silkroad.terrain-library-018.landforms.v1',
        'status':'independent library; not deployed on production map',
        'generator':'tools/lowpoly/library_landforms_018.py',
        'generator_sha256':sha256(__file__), 'source_blend_sha256':sha256(source),
        'concept_prompts_sha256':sha256(LIBRARY/'concepts'/'landscape-prompts.json'),
        'assets':rows, 'total_triangles':sum(row['triangles'] for row in rows),
        'total_surfaces':sum(row['surfaces'] for row in rows),
        'notes':['No display floor, lights or camera in GLBs.',
                 'Triangles are asset geometry counts, not runtime submission estimates.',
                 'No map-placement or runtime performance claims are made by this library export.'],
    }
    catalog_path = args.output_root / 'landforms-catalog.json'
    catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2)+'\n')
    if args.render:
        for obj in objects:
            obj.hide_render = True
            obj.location = (0, 0, 0)
        for obj in objects:
            obj.hide_render = False
            for view in args.views:
                render_asset(obj, camera, args.evidence / (obj.name+'-'+view+'.png'), view)
            obj.hide_render = True
    print('LANDFORMS_COMPLETE', len(rows), catalog['total_triangles'], str(catalog_path), flush=True)


if __name__ == '__main__':
    main()
