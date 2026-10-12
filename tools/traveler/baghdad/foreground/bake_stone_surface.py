"""Bake a periodic sandstone PBR surface through Blender MCP, without image edits.

The user's material-board image is a visual reference, not a source PBR map.
All channels below come from the same editable Blender shader. Run setup(), then
bake_channel('albedo'/'roughness'/'normal') separately through MCP.
"""
import bpy
import json
import math
from pathlib import Path

ROOT = Path('/Users/chengzeyuan/Developer/SilkRoad')
DEST = ROOT / 'assets/traveler/baghdad/foreground/textures'
REPORT = ROOT / 'docs/reports/traveler-baghdad-001/foreground-texture-20260922'
SIZE = 2048
TILE_METERS = 0.72


def enum(obj, prop, value):
    valid = [x.identifier for x in obj.bl_rna.properties[prop].enum_items]
    if value not in valid:
        raise RuntimeError((prop, value, valid))
    setattr(obj, prop, value)


def setup():
    global scene, plane, mat, target, output, bsdf, emission, albedo, roughness
    DEST.mkdir(parents=True, exist_ok=True)
    REPORT.mkdir(parents=True, exist_ok=True)
    scene = bpy.data.scenes.new('Baghdad_Stone_Texture_Bake')
    bpy.context.window.scene = scene
    # Render engines are registered dynamically, unlike ordinary RNA enums.
    try:
        scene.render.engine = 'CYCLES'
    except TypeError as exc:
        raise RuntimeError('Cycles is needed for shader baking: ' + str(exc))
    enum(scene.cycles, 'device', 'CPU')
    scene.cycles.samples = 8
    scene.render.bake.margin = 0
    enum(scene.render.bake, 'normal_space', 'TANGENT')
    mesh = bpy.data.meshes.new('Sandstone_Bake_Plane')
    mesh.from_pydata([(0,0,0),(TILE_METERS,0,0),(TILE_METERS,TILE_METERS,0),(0,TILE_METERS,0)], [], [(0,1,2,3)])
    uv = mesh.uv_layers.new(name='SurfaceUV')
    for i, co in enumerate([(0,0),(1,0),(1,1),(0,1)]):
        uv.data[i].uv = co
    plane = bpy.data.objects.new('Sandstone_Bake_Plane', mesh)
    scene.collection.objects.link(plane)
    plane.select_set(True)
    bpy.context.view_layer.objects.active = plane
    mat = bpy.data.materials.new('Baghdad_Sandstone_Procedural_Master')
    mat.use_nodes = True
    mesh.materials.append(mat)
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = next(n for n in nodes if n.type == 'BSDF_PRINCIPLED')
    output = next(n for n in nodes if n.type == 'OUTPUT_MATERIAL')
    bsdf.inputs['Roughness'].default_value = 0.90
    bsdf.inputs['Specular IOR Level'].default_value = 0.18

    def node(kind, label):
        n = nodes.new(kind)
        n.label = label
        n.location = (-1000 + (len(nodes) % 9) * 205, -len(nodes) // 9 * 220)
        return n

    def connect(value, socket):
        if isinstance(value, (float, int)):
            socket.default_value = value
        else:
            links.new(value, socket)

    def mathnode(operation, a, b=0.0):
        n = node('ShaderNodeMath', operation)
        enum(n, 'operation', operation)
        connect(a, n.inputs[0]); connect(b, n.inputs[1])
        return n.outputs[0]

    def ramp(value, stops, label):
        n = node('ShaderNodeValToRGB', label)
        enum(n.color_ramp, 'interpolation', 'LINEAR')
        for i, (position, color) in enumerate(stops):
            e = n.color_ramp.elements[i] if i < 2 else n.color_ramp.elements.new(position)
            e.position = position
            e.color = (color, color, color, 1) if isinstance(color, (int, float)) else color
        links.new(value, n.inputs[0])
        return n.outputs[0]

    # Four-dimensional torus coordinates repeat perfectly in U and V; every
    # channel is continuous across the texture boundary without border blending.
    coord = node('ShaderNodeTexCoord', 'UV surface coordinates')
    split = node('ShaderNodeSeparateXYZ', 'Tile U and V')
    links.new(coord.outputs['UV'], split.inputs[0])
    u = mathnode('MULTIPLY', split.outputs['X'], math.tau)
    v = mathnode('MULTIPLY', split.outputs['Y'], math.tau)
    vector = node('ShaderNodeCombineXYZ', 'Periodic 4D XYZ')
    for axis, value in zip(('X','Y','Z'), [mathnode('COSINE',u),mathnode('SINE',u),mathnode('COSINE',v)]):
        links.new(value, vector.inputs[axis])
    w = mathnode('SINE', v)

    def noise(scale, detail, label):
        n = node('ShaderNodeTexNoise', label)
        enum(n, 'noise_dimensions', '4D'); enum(n, 'noise_type', 'FBM')
        n.normalize = True
        links.new(vector.outputs[0], n.inputs['Vector']); links.new(w, n.inputs['W'])
        n.inputs['Scale'].default_value = scale
        n.inputs['Detail'].default_value = detail
        n.inputs['Roughness'].default_value = 0.7
        return n.outputs[0]

    broad = noise(1.2, 3.0, 'Faded mineral clouding')
    flakes = noise(6.0, 3.5, 'Weathered flaky surface')
    grains = noise(42.0, 2.0, 'Visible sand grains')
    micro = noise(115.0, 1.5, 'Fine sandstone pores')
    patina = ramp(broad, [(0.28,0.76),(0.73,0.99)], 'Subtle worn stone variation')
    chip = ramp(flakes, [(0.32,0.38),(0.405,0.68),(0.45,0.98),(0.68,1.0)], 'Small chipped mineral patches')
    pits = ramp(grains, [(0.30,0.43),(0.39,0.81),(0.47,1.0)], 'Dark pinholes and aggregate')
    detail = ramp(micro, [(0.25,0.78),(0.75,1.0)], 'Dry fine grain')

    cracks = node('ShaderNodeTexVoronoi', 'Sparse hairline stone fractures')
    enum(cracks,'voronoi_dimensions','4D'); enum(cracks,'feature','DISTANCE_TO_EDGE')
    links.new(vector.outputs[0],cracks.inputs['Vector']); links.new(w,cracks.inputs['W'])
    cracks.inputs['Scale'].default_value = 1.5
    line = ramp(cracks.outputs['Distance'],[(0.0,1.0),(0.012,0.6),(0.025,0.0)], 'Hairline width')
    mask = ramp(broad, [(0.50,0.0),(0.57,1.0)], 'Keep fractures local')
    fissure = mathnode('MULTIPLY',line,mask)
    fissure_color = mathnode('SUBTRACT',1.0,mathnode('MULTIPLY',fissure,0.46))
    albedo = mathnode('MULTIPLY',mathnode('MULTIPLY',patina,chip),mathnode('MULTIPLY',pits,detail))
    albedo = mathnode('MULTIPLY', albedo, fissure_color)
    # Lift mineral cavities so the game's low ambient light keeps dusty stone
    # readable without turning the fine grain into black pepper speckles.
    albedo = mathnode('ADD',0.40,mathnode('MULTIPLY',albedo,0.60))
    roughness = mathnode('ADD',0.78,mathnode('MULTIPLY',mathnode('SUBTRACT',1.0,chip),0.27))
    roughness = mathnode('ADD',roughness,mathnode('MULTIPLY',micro,0.10))
    height = mathnode('ADD',mathnode('MULTIPLY',flakes,0.55),mathnode('MULTIPLY',grains,0.22))
    height = mathnode('ADD',height,mathnode('MULTIPLY',micro,0.07))
    height = mathnode('SUBTRACT',height,mathnode('MULTIPLY',fissure,0.22))
    bump = node('ShaderNodeBump','Shallow worn sandstone relief')
    bump.inputs['Strength'].default_value = 0.48
    bump.inputs['Distance'].default_value = 0.0022
    links.new(height,bump.inputs['Height'])
    links.new(bump.outputs['Normal'],bsdf.inputs['Normal'])
    links.new(albedo,bsdf.inputs['Base Color']); links.new(roughness,bsdf.inputs['Roughness'])
    emission = node('ShaderNodeEmission','Unlit channel bake')
    target = node('ShaderNodeTexImage','Active bake destination')
    nodes.active = target
    for n in nodes: n.select = n == target
    print('BAGHDAD_TEXTURE_SETUP',scene.name)


def bake_channel(channel):
    if channel not in ('albedo','roughness','normal'):
        raise ValueError(channel)
    bpy.context.window.scene = scene
    image = bpy.data.images.new('Baghdad_Stone_Surface_' + channel, width=SIZE,height=SIZE,alpha=False)
    enum(image.colorspace_settings,'name','sRGB' if channel == 'albedo' else 'Non-Color')
    enum(image,'file_format','PNG')
    image.filepath_raw = str(DEST / ('stone_surface_' + channel + '.png'))
    target.image = image
    mat.node_tree.nodes.active = target
    links = mat.node_tree.links
    if channel == 'normal':
        links.new(bsdf.outputs['BSDF'],output.inputs['Surface'])
        bake_type = 'NORMAL'
    else:
        links.new(albedo if channel == 'albedo' else roughness,emission.inputs['Color'])
        links.new(emission.outputs[0],output.inputs['Surface'])
        bake_type = 'EMIT'
    valid = [i.identifier for i in bpy.ops.object.bake.get_rna_type().properties['type'].enum_items]
    assert bake_type in valid
    bpy.ops.object.bake(type=bake_type)
    image.save()
    image.pack()
    (REPORT / ('baked-' + channel + '.json')).write_text(json.dumps({'channel':channel,'path':image.filepath_raw,'size':[SIZE,SIZE],'bytes':Path(image.filepath_raw).stat().st_size}))
    print('BAGHDAD_TEXTURE_BAKED',channel,image.filepath_raw)


def save_master():
    mat.node_tree.links.new(bsdf.outputs['BSDF'],output.inputs['Surface'])
    path = ROOT / 'art-src/baghdad-foreground/stone_surface_master.blend'
    bpy.data.libraries.write(str(path),{scene},fake_user=True,compress=True)
    print('BAGHDAD_TEXTURE_MASTER',str(path))


if __name__ == '__main__':
    setup()
