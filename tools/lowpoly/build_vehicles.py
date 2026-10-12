"""Build original low-poly Silk Road vehicles with Blender's Python API.

Run: Blender --background --python tools/lowpoly/build_vehicles.py
Meshes are generated in a modelling frame facing -Y, then baked to Blender +Y
so the exported glTF actors face Godot -Z. Units are metres; Z=0 is the camel's
feet / the ship's waterline. No external models, textures, or add-ons required.
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import struct
import sys
from pathlib import Path

import bpy
import bmesh
from mathutils import Matrix, Quaternion, Vector

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets/game/lowpoly/vehicles"
SOURCE = ROOT / "docs/design/lowpoly-v1/source/vehicles.blend"
PREVIEW = ROOT / "docs/design/lowpoly-v1/previews/vehicles"
TAU = math.tau
ASSET = None
ROOT_OBJECT = None
MATERIALS = {}


def material(name, hex_color, roughness=0.86):
    if name in MATERIALS:
        return MATERIALS[name]
    h = hex_color.lstrip("#")
    srgb = [int(h[i:i+2], 16) / 255 for i in (0, 2, 4)]
    rgb = [c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4 for c in srgb]
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*rgb, 1)
    m.use_nodes = True
    p = m.node_tree.nodes.get("Principled BSDF")
    p.inputs["Base Color"].default_value = (*rgb, 1)
    p.inputs["Roughness"].default_value = roughness
    p.inputs["Metallic"].default_value = 0
    m.use_backface_culling = name not in {"sail", "player_accent"}
    MATERIALS[name] = m
    return m


def mesh(name, vertices, faces, mat):
    data = bpy.data.meshes.new(name + "_geometry")
    data.from_pydata(vertices, [], faces)
    data.validate(verbose=True)
    data.materials.append(mat)
    bm = bmesh.new()
    bm.from_mesh(data)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(data)
    bm.free()
    data.update()
    obj = bpy.data.objects.new(name, data)
    ASSET.objects.link(obj)
    obj.parent = ROOT_OBJECT
    return obj


def move_to_asset(obj, name, mat):
    obj.name = name
    for c in list(obj.users_collection):
        c.objects.unlink(obj)
    ASSET.objects.link(obj)
    obj.parent = ROOT_OBJECT
    obj.data.materials.append(mat)
    return obj


def bevel_box(name, center, size, mat, bevel=.015, rotation=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=center, rotation=rotation)
    o = move_to_asset(bpy.context.object, name, mat)
    o.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel:
        mod = o.modifiers.new("cut_corner_geometry", "BEVEL")
        mod.width = bevel
        mod.segments = 1
        bpy.ops.object.modifier_apply(modifier=mod.name)
    return o


def tube(name, points, radii, mat, sides=7):
    """Faceted tapered sweep, with rings perpendicular to a curved centerline."""
    ps = [Vector(p) for p in points]
    vs = []
    for i, p in enumerate(ps):
        tangent = (ps[min(i+1, len(ps)-1)] - ps[max(i-1, 0)]).normalized()
        ref = Vector((1, 0, 0))
        if abs(ref.dot(tangent)) > .9:
            ref = Vector((0, 1, 0))
        a = tangent.cross(ref).normalized()
        b = tangent.cross(a).normalized()
        rx, ry = radii[i] if isinstance(radii[i], tuple) else (radii[i], radii[i])
        vs.extend(p + a * math.cos(j*TAU/sides) * rx + b * math.sin(j*TAU/sides) * ry for j in range(sides))
    fs = [tuple(reversed(range(sides)))]
    for i in range(len(ps)-1):
        for j in range(sides):
            a = i*sides+j
            b = i*sides+(j+1)%sides
            fs.append((a, b, b+sides, a+sides))
    fs.append(tuple((len(ps)-1)*sides+j for j in range(sides)))
    return mesh(name, vs, fs, mat)


def longitudinal_loft(name, sections, mat, sides=10):
    """sections = (Y, half-width X, centre Z, half-height Z)."""
    vs = [(math.cos(j*TAU/sides)*w, y, z + math.sin(j*TAU/sides)*h)
          for y, w, z, h in sections for j in range(sides)]
    fs = [tuple(reversed(range(sides)))]
    for i in range(len(sections)-1):
        for j in range(sides):
            a = i*sides+j
            b = i*sides+(j+1)%sides
            fs.append((a, a+sides, b+sides, b))
    fs.append(tuple((len(sections)-1)*sides+j for j in range(sides)))
    return mesh(name, vs, fs, mat)


def hump(name, y, mat):
    rows = [(.515, .100, .105), (.572, .092, .090), (.637, .058, .056), (.682, .020, .023)]
    vs = [(math.cos(j*TAU/9)*rx, y+math.sin(j*TAU/9)*ry, z)
          for z, rx, ry in rows for j in range(9)]
    fs = [tuple(reversed(range(9)))]
    for i in range(len(rows)-1):
        for j in range(9):
            a=i*9+j; b=i*9+(j+1)%9
            fs.append((a,b,b+9,a+9))
    fs.append(tuple(27+j for j in range(9)))
    return mesh(name, vs, fs, mat)


def join_objects(objects, name, origin=None):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    o = bpy.context.object
    o.name = name
    if origin is not None:
        bpy.context.scene.cursor.location = origin
        bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
    return o


def begin_asset(name):
    global ASSET, ROOT_OBJECT
    ASSET = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(ASSET)
    ROOT_OBJECT = bpy.data.objects.new(name, None)
    ASSET.objects.link(ROOT_OBJECT)
    ROOT_OBJECT["forward_axis"] = "Godot -Z / Blender +Y"
    ROOT_OBJECT["ground_plane"] = "Godot Y=0 / Blender Z=0"
    ROOT_OBJECT["original_geometry"] = "Generated by tools/lowpoly/build_vehicles.py"
    return ASSET


def build_camel():
    begin_asset("camel")
    tan=material("camel_sand", "8C5E33")
    light=material("camel_highlight", "D1AB76")
    dark=material("leather_wood", "725035")
    accent=material("player_accent", "B84B39")
    cream=material("canvas_cargo", "DECAA0")
    ink=material("eyes_ink", "292C26")
    longitudinal_loft("camel_shaped_torso", [
        (-.285,.055,.463,.065),(-.225,.111,.470,.098),
        (-.105,.145,.475,.101),(.06,.150,.470,.097),
        (.20,.125,.462,.090),(.28,.069,.454,.063),(.305,.027,.462,.029)], tan)
    hump("camel_front_hump", -.115, tan)
    hump("camel_rear_hump", .150, tan)
    tube("camel_curved_neck", [(0,-.231,.465),(0,-.304,.431),(0,-.377,.453),
        (0,-.424,.515),(0,-.438,.595),(0,-.456,.690)],
        [(.076,.065),(.069,.058),(.057,.049),(.043,.042),(.035,.037),(.037,.041)], tan, 9)
    longitudinal_loft("camel_head_and_muzzle", [(-.429,.022,.710,.030),
        (-.468,.040,.711,.041),(-.508,.037,.698,.032),
        (-.561,.029,.678,.024),(-.598,.026,.674,.020),(-.613,.017,.675,.017)], light, 8)
    for x in [-1,1]:
        # Raised leaf-shaped ears; the head and muzzle are a continuous loft.
        mesh("camel_ear", [(x*.026,-.449,.729),(x*.060,-.432,.740),
            (x*.083,-.451,.750),(x*.037,-.461,.746),(x*.041,-.447,.744)],
            [(0,1,4),(1,2,4),(2,3,4),(3,0,4),(3,2,1,0)], tan)
        bevel_box("camel_eye", (x*.038,-.479,.722),(.006,.012,.012),ink,.002)
        bevel_box("camel_nostril", (x*.026,-.588,.683),(.003,.010,.006),dark,.001)
    tube("camel_lower_lip", [(-.019,-.605,.662),(.019,-.605,.662)], [.004,.004], dark, 5)
    tube("camel_tail", [(0,.279,.481),(0,.322,.454),(.018,.345,.389),(.027,.348,.353)], [.014,.013,.010,.012], tan, 6)
    tube("camel_tail_tuft", [(.027,.348,.366),(.028,.350,.331)], [.018,.009], dark, 6)
    # Four articulated meshes; each origin is at its hip for procedural gait.
    for x in [-1,1]:
        for front in [True,False]:
            y=-.194 if front else .204
            xx=x*(.093 if front else .103)
            hip=(xx,y,.446)
            knee=(xx*1.035,y+(.015 if front else -.011),.252)
            ankle=(xx*1.07,y+(-.010 if front else .050),.032)
            foot=(xx*1.07,ankle[1]-.015,.020)
            pieces=[tube("leg_segments",[hip,(xx,y,.36),knee,ankle],[.041,.034,.025,.017],tan,7),
                tube("leg_knee",[(knee[0],knee[1],.269),(knee[0],knee[1],.236)],[.025,.025],light,7),
                bevel_box("cloven_hoof",foot,(.051,.075,.040),dark,.009)]
            side="left" if x>0 else "right"
            leg=join_objects(pieces,"leg_"+("front" if front else "back")+"_"+side,hip)
            leg["procedural_pivot"]="hip; rotate local X for gait"
    # Blanket side panels follow the body and end in cut triangular tassels.
    for sign in [-1,1]:
        vs=[(sign*.139,-.182,.530),(sign*.151,.217,.526),
            (sign*.183,.226,.356),(sign*.187,-.181,.357)]
        mesh("saddle_blanket",vs,[(0,1,2,3)],accent)
        tube("blanket_gold_border",[vs[3],vs[2]],[.009,.009],cream,5)
        for y in [-.155,-.073,.008,.089,.171]:
            mesh("blanket_tassel",[(sign*.187,y-.014,.358),(sign*.187,y+.014,.358),
                (sign*.188,y,.329)],[(0,1,2)],accent)
        bevel_box("packed_canvas_pannier",(sign*.192,.075,.421),(.115,.190,.163),accent,.027)
        for y in [.014,.132]:
            bevel_box("pannier_lashing",(sign*.252,y,.421),(.007,.017,.157),dark,.003)
        bevel_box("pannier_flap",(sign*.195,.075,.502),(.110,.174,.019),accent,.008)
        tube("rolled_silk",[(sign*.164,.148,.541),(sign*.164,.285,.541)],[.041,.041],cream,9)
        for y in [.172,.263]:
            tube("roll_binding",[(sign*.164,y-.005,.541),(sign*.164,y+.005,.541)],[.043,.043],accent,9)
    bevel_box("saddle_center",(0,.012,.558),(.212,.096,.042),accent,.013)
    for x in [-.089,.089]:
        tube("saddle_bow",[(x,-.032,.573),(x,0,.592),(x,.045,.568)],[.011,.011,.011],dark,6)
    tube("halter_band",[(-.030,-.541,.707),(0,-.552,.717),(.030,-.541,.707)],[.006]*3,accent,5)
    for sign in [-1,1]:
        tube("halter_rein",[(sign*.031,-.540,.700),(sign*.050,-.390,.552),(sign*.066,-.187,.547)],[.004]*3,dark,5)
    return ASSET


def build_ship():
    begin_asset("ship")
    wood=material("hull_warm_wood","6E4A2E")
    light=material("deck_honey_wood","BE9465")
    dark=material("leather_wood","725035")
    accent=material("player_accent","B84B39")
    sail=material("sail","EDDCB1",.93)
    cream=material("canvas_cargo","DECAA0")
    # Boat cross-sections: pointed raised bow, full bilge, narrowed high stern.
    # DETAIL-012: shaped stations at bow shoulders and stern, rather than
    # subdividing existing planes. Endpoints and the authored waterline stay fixed.
    sections=[(-.675,.015,.125),(-.637,.053,.102),(-.598,.105,.070),
        (-.520,.151,.043),(-.425,.196,.022),(-.310,.217,.007),
        (-.190,.226,0),(-.040,.226,.002),(.105,.225,.008),
        (.230,.215,.019),(.345,.196,.040),(.450,.172,.064),
        (.535,.144,.095),(.610,.095,.135)]
    rings=[]
    for y,w,rise in sections:
        rings.append([(-w,y,.155+rise),(-w*.98,y,.099+rise*.9),
            (-w*.90,y,.040+rise*.8),(-w*.60,y,-.069+rise*1.25),
            (0,y,-.118+rise*1.55),(w*.60,y,-.069+rise*1.25),
            (w*.90,y,.040+rise*.8),(w*.98,y,.099+rise*.9),(w,y,.155+rise)])
    vs=[p for ring in rings for p in ring]
    ring_size=len(rings[0])
    for band in range(ring_size-1):
        fs=[(i*ring_size+band,(i+1)*ring_size+band,
             (i+1)*ring_size+band+1,i*ring_size+band+1) for i in range(len(rings)-1)]
        mesh("hull_curved_strake",vs,fs,wood if band in [0,7,3,4] else dark)
    mesh("hull_stem_caps",vs,[tuple(range(ring_size-1,-1,-1)),
        tuple((len(rings)-1)*ring_size+j for j in range(ring_size))],wood)
    deck_vertices=[]
    for y,w,rise in sections:
        deck_vertices.extend([(-w*.91,y,.145+rise),(w*.91,y,.145+rise)])
    deck_faces=[(i*2,i*2+1,i*2+3,i*2+2) for i in range(len(sections)-1)]
    mesh("continuous_deck",deck_vertices,deck_faces,light)
    for side in [-1,1]:
        rim=[(side*w,y,.172+rise) for y,w,rise in sections]
        tube("raised_gunwale",rim,[.017]*len(rim),dark,6)
        tube("upper_hull_trim",[(side*w*.965,y,.075+rise*.50) for y,w,rise in sections],[.007]*len(rim),light,5)
    for i in range(15):
        y=-.49+i*.068
        s0,s1=next((a,b) for a,b in zip(sections[:-1],sections[1:]) if a[0]<=y<=b[0])
        t=(y-s0[0])/(s1[0]-s0[0]);w=(s0[1]*(1-t)+s1[1]*t)*.89;z=.147+s0[2]*(1-t)+s1[2]*t
        tube("deck_plank_seam",[(-w,y,z),(w,y,z)],[.0019,.0019],dark,4)
    tube("raised_bow_stem",[(0,-.63,.158),(0,-.676,.253),(0,-.706,.298)],[.025,.020,.014],dark,7)
    tube("sternpost",[(0,.59,.162),(0,.621,.292),(0,.641,.333)],[.024,.021,.018],dark,7)
    # Small cabin leaves the rigging and working deck visible.
    bevel_box("stern_cabin",(0,.411,.284),(.245,.219,.190),wood,.014)
    roof_profile=[(-.150,.358),(-.136,.384),(-.102,.417),(0,.432),
                  (.102,.417),(.136,.384),(.150,.358)]
    roof=[(x,y,z+rise-thickness) for thickness in (0,.012)
          for y,rise in ((.279,0),(.548,.018)) for x,z in roof_profile]
    n=len(roof_profile)
    roof_faces=[(i,i+n,i+n+1,i+1) for i in range(n-1)]
    roof_faces += [(2*n+i,2*n+i+1,3*n+i+1,3*n+i) for i in range(n-1)]
    outline=list(range(n))+list(range(2*n-1,n-1,-1))
    roof_faces += [(a,b,b+2*n,a+2*n) for a,b in zip(outline,outline[1:]+outline[:1])]
    mesh("curved_cabin_roof",roof,roof_faces,accent)
    bevel_box("cabin_door",(0,.295,.272),(.070,.007,.115),dark,.005)
    for side in [-1,1]:
        bevel_box("cabin_window",(side*.125,.415,.303),(.007,.079,.060),dark,.004)
        tube("window_crossbar",[(side*.130,.376,.302),(side*.130,.454,.302)],[.004,.004],light,4)
    # Segmented, cambered junk sails, with actual bamboo battens.
    for idx,(y,bottom,top,width) in enumerate([(-.310,.307,.780,.390),(.112,.365,.926,.505)]):
        tube("mast",[(0,y,.131),(0,y,top+.045)],[.017,.011],dark,9)
        rows=7 if idx==1 else 6
        columns=6
        angle=math.radians(-48)
        def rig_point(x, yy, z):
            return (math.cos(angle)*x-math.sin(angle)*(yy-y),
                    y+math.sin(angle)*x+math.cos(angle)*(yy-y),z)
        sail_v=[];edges=[]
        for row in range(rows):
            t=row/(rows-1);z=bottom+(top-bottom)*t
            left=-width*(.45-.13*t);right=width*(.55-.16*t)
            if row==rows-1:right-=width*.16
            rowpoints=[]
            for c in range(columns):
                q=c/(columns-1);x=left+(right-left)*q
                # A fuller, asymmetric wind belly reads from the globe's
                # overhead camera; the luff and leech retain their old positions.
                belly=.095 if idx==0 else .118
                yy=y-.018-belly*math.sin(q*math.pi)*math.sin((.15+t*.75)*math.pi)
                zz=z+q*.018
                point=rig_point(x,yy,zz)
                rowpoints.append(point);sail_v.append(point)
            edges.append(rowpoints)
            tube("sail_batten",rowpoints,[.0065]*columns,dark,5)
        sail_f=[]
        for row in range(rows-1):
            for c in range(columns-1):
                a=row*columns+c;sail_f.append((a,a+1,a+columns+1,a+columns))
        panel=mesh("sail_panels_"+str(idx+1),sail_v,sail_f,sail)
        tube("sail_luff",[r[0] for r in edges],[.0045]*rows,cream,5)
        tube("sail_leech",[r[-1] for r in edges],[.0045]*rows,cream,5)
        for side in [-1,1]:
            tube("mast_stay",[(0,y,top+.019),(side*.173,y+.13,.175)],[.0035,.0035],cream,4)
        # Double the pennant's dimensions around a slightly lower attachment;
        # its highest point stays fixed, preserving the existing ship scale.
        flag_z=top+.031
        mesh("player_pennant",[rig_point(0,y,flag_z),rig_point(.278,y-.042,flag_z+.024),
            rig_point(.206,y-.020,flag_z-.054),rig_point(0,y,flag_z-.082)],[(0,1,2,3)],accent)
    for x,y,w,h in [(-.12,-.020,.104,.094),(.10,-.025,.110,.092),(-.11,.113,.086,.078)]:
        z=.163+h/2
        bevel_box("deck_cargo_box",(x,y,z),(w,.098,h),light,.008)
        for dx in [-w*.30,w*.30]:
            bevel_box("cargo_box_band",(x+dx,y,z+h/2+.002),(.009,.096,.005),dark,.001)
    tube("bundled_deck_goods",[(.113,.098,.206),(.113,.213,.206)],[.035,.035],cream,8)
    for y in [.12,.19]:
        tube("cargo_roll_band",[(.113,y-.005,.206),(.113,y+.005,.206)],[.037,.037],accent,8)
    tube("stern_steering_oar",[(.084,.477,.242),(.087,.692,.041)],[.011,.009],dark,6)
    bevel_box("steering_oar_blade",(.089,.707,.012),(.065,.022,.110),wood,.006,rotation=(.72,0,0))
    return ASSET


def batch_and_orient(collection):
    groups={}
    for o in list(collection.objects):
        if o.type != "MESH" or o.name.startswith("leg_"):
            continue
        key=o.data.materials[0].name
        groups.setdefault(key,[]).append(o)
    for name,objects in groups.items():
        join_objects(objects,name)
    # Bake front +Y into Blender coordinates, which glTF Y_UP exports as -Z.
    rot=Matrix.Rotation(math.pi,4,"Z")
    points=[o.matrix_world@v.co for o in collection.objects if o.type=="MESH" for v in o.data.vertices]
    size_y=max(p.y for p in points)-min(p.y for p in points)
    size_z=max(p.z for p in points)-min(p.z for p in points)
    scale=Matrix.Diagonal((1,1 if collection.name=="camel" else 1.38/size_y,
        .75/max(p.z for p in points) if collection.name=="camel" else 1.0/size_z,1))
    for o in collection.objects:
        if o.type=="MESH":
            o.matrix_world=scale@rot@o.matrix_world
            bpy.ops.object.select_all(action="DESELECT")
            o.select_set(True);bpy.context.view_layer.objects.active=o
            bpy.ops.object.transform_apply(location=False,rotation=True,scale=True)


def stats(collection):
    verts=[];triangles=0;mats=set();meshes=[]
    for o in collection.objects:
        if o.type!="MESH":continue
        o.data.calc_loop_triangles();triangles+=len(o.data.loop_triangles)
        verts.extend(o.matrix_world@v.co for v in o.data.vertices)
        mats.update(m.name for m in o.data.materials)
        meshes.append({"name":o.name,"triangles":len(o.data.loop_triangles),"origin_blender":list(o.location)})
    lo=[min(v[i] for v in verts) for i in range(3)];hi=[max(v[i] for v in verts) for i in range(3)]
    return {"triangles":triangles,"materials":sorted(mats),"material_count":len(mats),"mesh_count":len(meshes),
        "bbox_blender":{"min":lo,"max":hi,"size":[hi[i]-lo[i] for i in range(3)]},
        "bbox_gltf":{"min":[lo[0],lo[2],-hi[1]],"max":[hi[0],hi[2],-lo[1]],"size":[hi[0]-lo[0],hi[2]-lo[2],hi[1]-lo[1]]},
        "forward":"-Z","ground_or_waterline_y":0,"meshes":meshes}


def clean_ship_triangles(collection):
    """Drop zero-area cap triangles without changing the visible ship surface.

    The long, bent battens contained degenerate triangulations in the earlier
    export. Triangulate explicitly so the editable source and GLB agree.
    Camel geometry and its four articulated pivots are intentionally untouched.
    """
    removed = 0
    for obj in collection.objects:
        if obj.type != "MESH":
            continue
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        bmesh.ops.triangulate(bm, faces=list(bm.faces))
        empty = [face for face in bm.faces if face.calc_area() < 1e-10]
        removed += len(empty)
        if empty:
            bmesh.ops.delete(bm, geom=empty, context='FACES_ONLY')
        bm.to_mesh(obj.data)
        bm.free()
        obj.data.update()
    return removed


def export(collection):
    bpy.ops.object.select_all(action="DESELECT")
    for o in collection.objects:o.select_set(True)
    bpy.context.view_layer.objects.active=next(o for o in collection.objects if o.type=="EMPTY")
    bpy.ops.export_scene.gltf(filepath=str(OUT/(collection.name+".glb")),export_format="GLB",
        use_selection=True,export_yup=True,export_apply=True,export_animations=False,
        export_cameras=False,export_lights=False,export_extras=True)


def validate_glb(name):
    """Inspect actual glTF node transforms, material slots and exported bounds."""
    blob=(OUT/(name+".glb")).read_bytes()
    length,_=struct.unpack_from("<II",blob,12)
    data=json.loads(blob[20:20+length])
    points=[];legs=[];triangles=0
    def visit(index,parent):
        nonlocal triangles
        node=data["nodes"][index]
        if "matrix" in node:
            local=Matrix([node["matrix"][j*4:j*4+4] for j in range(4)]).transposed()
        else:
            x,y,z,w=node.get("rotation",[0,0,0,1])
            local=(Matrix.Translation(node.get("translation",[0,0,0])) @
                Quaternion((w,x,y,z)).to_matrix().to_4x4() @
                Matrix.Diagonal((*node.get("scale",[1,1,1]),1)))
        world=parent@local
        if node.get("name","").startswith("leg_"):
            legs.append({"name":node["name"],"origin":list(world.translation)})
        if "mesh" in node:
            for primitive in data["meshes"][node["mesh"]]["primitives"]:
                position=data["accessors"][primitive["attributes"]["POSITION"]]
                for p in itertools.product(*zip(position["min"],position["max"])):
                    points.append(world@Vector(p))
                count=data["accessors"][primitive["indices"]]["count"] if "indices" in primitive else position["count"]
                triangles+=count//3
        for child in node.get("children",[]):visit(child,world)
    for index in data["scenes"][data.get("scene",0)]["nodes"]:
        visit(index,Matrix.Identity(4))
    lo=[min(p[i] for p in points) for i in range(3)]
    hi=[max(p[i] for p in points) for i in range(3)]
    mats=[m["name"] for m in data["materials"]]
    assert "player_accent" in mats
    if name=="camel":
        assert len(legs)==4 and abs(lo[1])<1e-5
        assert all(l["origin"][2]<0 for l in legs if "front" in l["name"])
        assert all(l["origin"][2]>0 for l in legs if "back" in l["name"])
    else:
        assert "sail" in mats and lo[1]<0<hi[1]
    return {"bytes":len(blob),"triangles":triangles,"materials":mats,
        "mesh_count":len(data["meshes"]),"bbox_min":lo,"bbox_max":hi,
        "size":[hi[i]-lo[i] for i in range(3)],"leg_pivots":legs,
        "animations":len(data.get("animations",[])),"contract_valid":True}


def add_studio():
    studio=bpy.data.collections.new("_render_studio")
    bpy.context.scene.collection.children.link(studio)
    def link(o):
        for c in list(o.users_collection):c.objects.unlink(o)
        studio.objects.link(o)
    bpy.ops.mesh.primitive_plane_add(size=200,location=(0,0,-.004))
    ground=bpy.context.object;ground.name="_studio_ground";link(ground)
    ground.data.materials.append(material("_studio_sand","D8D2B9",.94))
    for name,loc,power,size,col in [("_key",(-3,-4,6),500,4,(1,.84,.66)),("_fill",(4,1,3),250,4,(.71,.86,1)),("_rim",(-1,4,5),350,3,(1,.95,.81))]:
        data=bpy.data.lights.new(name,"AREA");data.energy=power;data.shape="DISK";data.size=size;data.color=col
        obj=bpy.data.objects.new(name,data);studio.objects.link(obj);obj.location=loc
        obj.rotation_euler=(Vector((0,0,.35))-obj.location).to_track_quat("-Z","Y").to_euler()
    data=bpy.data.cameras.new("_preview_camera");camera=bpy.data.objects.new("_preview_camera",data);studio.objects.link(camera)
    data.type="ORTHO";data.ortho_scale=1.68
    bpy.context.scene.camera=camera
    return studio,ground,camera


def render_previews(collections,studio,ground,camera,only=None):
    scene=bpy.context.scene
    scene.render.engine="CYCLES";scene.cycles.samples=40;scene.cycles.use_denoising=True
    scene.render.resolution_x=1024;scene.render.resolution_y=1024;scene.render.resolution_percentage=100
    scene.world.color=(.18,.18,.18)
    scene.view_settings.view_transform="AgX"
    scene.render.image_settings.file_format="PNG"
    for asset in collections:
        if only and asset.name != only:
            continue
        for c in collections:c.hide_render=c!=asset
        ground.location.z=-.125 if asset.name=="ship" else -.003
        center=Vector((0,0,.39 if asset.name=="camel" else .42))
        for name,direction in [("hero",(2.5,3.5,2.1)),("side",(4,0,1.7)),("front",(0,4,1.35)),("rear",(-2.4,-3.5,1.9))]:
            camera.location=center+Vector(direction)
            camera.rotation_euler=(center-camera.location).to_track_quat("-Z","Y").to_euler()
            scene.render.filepath=str(PREVIEW/(asset.name+"-"+name+".png"))
            bpy.ops.render.render(write_still=True)
    for c in collections:c.hide_render=False


def main():
    global OUT, SOURCE, PREVIEW
    argv=sys.argv[sys.argv.index("--")+1:] if "--" in sys.argv else []
    parser=argparse.ArgumentParser();parser.add_argument("--no-render",action="store_true")
    parser.add_argument("--render-asset",choices=["camel","ship"])
    parser.add_argument("--export-asset",choices=["camel","ship"],
                        help="Export one GLB while retaining both editable source collections.")
    parser.add_argument("--out",type=Path,default=OUT)
    parser.add_argument("--source",type=Path,default=SOURCE)
    parser.add_argument("--preview-dir",type=Path,default=PREVIEW)
    args=parser.parse_args(argv)
    OUT, SOURCE, PREVIEW = args.out, args.source, args.preview_dir
    for p in [OUT,SOURCE.parent,PREVIEW]:p.mkdir(parents=True,exist_ok=True)
    bpy.context.preferences.filepaths.save_version=0
    bpy.ops.object.select_all(action="SELECT");bpy.ops.object.delete(use_global=False)
    for c in list(bpy.data.collections):
        if c.name!="Collection":bpy.data.collections.remove(c)
    collections=[build_camel(),build_ship()]
    results={};export_checks={}
    for c in collections:
        batch_and_orient(c)
        removed = clean_ship_triangles(c) if c.name == "ship" else 0
        results[c.name]=stats(c)
        results[c.name]["removed_degenerate_triangles"] = removed
        if args.export_asset is None or c.name == args.export_asset:
            export(c)
            export_checks[c.name]=validate_glb(c.name)
    studio,ground,camera=add_studio()
    render_previews(collections,studio,ground,camera,"__skip__" if args.no_render else args.render_asset)
    # Open the editable source on a usable camel camera view. Both assets remain
    # separate collections; enable the ship collection to inspect that model.
    collections[1].hide_viewport=True
    collections[1].hide_render=True
    ground.location.z=-.003
    center=Vector((0,0,.39))
    camera.location=center+Vector((2.5,3.5,2.1))
    camera.rotation_euler=(center-camera.location).to_track_quat("-Z","Y").to_euler()
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE))
    (PREVIEW/"vehicle-stats.json").write_text(json.dumps(results,indent=2)+"\n")
    (PREVIEW/"gltf-export-check.json").write_text(json.dumps(export_checks,indent=2)+"\n")
    print("VEHICLE_BUILD_COMPLETE "+json.dumps(results))


if __name__=="__main__":main()
