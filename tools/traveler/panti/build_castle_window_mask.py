"""Map authored existing-window screen polygons onto the unchanged fortress UVs.

The accepted camera/fortress transforms are read from the checkpoint snapshot.
This only emits a separate emission mask: it never modifies the model or albedo.
"""
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'docs/reports/traveler-panti-001/checkpoint-29/castle-lights'
OUT.mkdir(parents=True, exist_ok=True)
SOURCE = ROOT / 'docs/reports/traveler-panti-001/checkpoint-28/sunset-final.json'
REPORT = json.loads(SOURCE.read_text())
SCENE = REPORT['layout']
WINDOWS = [
    ('keep-front', [(1189.9,579.0),(1192.1,578.4),(1192.1,588.8),(1190.0,589.0)]),
    ('keep-right', [(1253.0,578.3),(1255.0,577.3),(1255.0,587.5),(1253.0,588.0)]),
    ('upper-left', [(1130.0,621.0),(1132.8,620.3),(1132.3,631.0),(1129.7,631.0)]),
    ('inner-front', [(1120.5,662.8),(1124.0,662.2),(1124.0,669.5),(1120.5,670.0)]),
    ('inner-right', [(1261.4,633.5),(1264.0,633.3),(1264.0,644.0),(1261.4,644.0)]),
    ('right-front-tower', [(1306.5,667.0),(1309.4,668.0),(1309.4,679.4),(1306.5,679.0)]),
    ('right-flank-upper', [(1542.0,661.5),(1545.0,661.5),(1545.0,674.0),(1542.0,674.0)]),
    ('right-flank-lower', [(1547.0,701.8),(1549.4,702.0),(1549.4,712.3),(1547.0,712.2)]),
    ('left-flank', [(829.9,700.0),(832.3,699.8),(832.3,710.4),(829.9,710.3)]),
    ('front-wall', [(1254.0,755.4),(1256.8,755.2),(1256.8,769.4),(1254.0,769.4)]),
]


def rotation_y(a):
    return np.array([[np.cos(a),0,np.sin(a)],[0,1,0],[-np.sin(a),0,np.cos(a)]])


raw = (ROOT / 'assets/traveler/panti/processed/fortress.glb').read_bytes()
length, _ = struct.unpack_from('<II', raw, 12)
gltf = json.loads(raw[20:20+length])
blob = raw[28+length:]


def accessor(index):
    a = gltf['accessors'][index]
    b = gltf['bufferViews'][a['bufferView']]
    n = {'SCALAR':1,'VEC2':2,'VEC3':3}[a['type']]
    dtype = {5123:np.uint16,5125:np.uint32,5126:np.float32}[a['componentType']]
    return np.frombuffer(blob,dtype=dtype,count=a['count']*n,
                         offset=b.get('byteOffset',0)+a.get('byteOffset',0)).reshape(a['count'],n)


prim = gltf['meshes'][0]['primitives'][0]
vertices = accessor(prim['attributes']['POSITION']).astype(float)
uv = accessor(prim['attributes']['TEXCOORD_0']).astype(float)
triangles = accessor(prim['indices']).reshape(-1)
triangles = triangles.reshape(-1,3)
az = .62
stage = rotation_y(az)


def stage_point(v):
    return stage @ (np.array(v) * [1,1,-1]) + np.array(SCENE['camera_target'])


fortress = SCENE['fortress']
scale = fortress['height_u'] / np.ptp(vertices[:,1])
castle_basis = rotation_y(az + np.radians(fortress['yaw_relative_camera_deg']))
world = (vertices * scale) @ castle_basis.T + stage_point(fortress['stage_position'])
conf = SCENE['camera_composition']
eye = stage_point(conf['position_stage'])
forward = stage_point(conf['look_at_stage']) - eye
forward /= np.linalg.norm(forward)
right = np.cross(forward,[0,1,0]); right /= np.linalg.norm(right)
up = np.cross(right,forward)
view = np.column_stack((right,up,forward))
camera_vertices = (world - eye) @ view
depth = camera_vertices[:,2]
focal = 540 / np.tan(np.radians(conf['fov_vertical_deg']/2))
screen = camera_vertices[:,:2] / depth[:,None] * [focal,-focal] + [960,540]
tris = screen[triangles]
tri_min = tris.min(1); tri_max = tris.max(1)
texture_size = 4096
mask = np.zeros((texture_size,texture_size),dtype=np.uint8)
overlay = Image.open(SOURCE.with_suffix('.png')).convert('RGB')
draw = ImageDraw.Draw(overlay)
records = []
for name, polygon in WINDOWS:
    bounds = np.array(polygon)
    lo = bounds.min(0); hi = bounds.max(0)
    xs, ys = np.meshgrid(np.arange(lo[0],hi[0],.125),np.arange(lo[1],hi[1],.125))
    samples = np.column_stack((xs.ravel(),ys.ravel()))
    # Convex four-corner point inclusion.
    cross = []
    for a,b in zip(bounds,np.roll(bounds,-1,axis=0)):
        edge = b-a; rel = samples-a
        cross.append(edge[0]*rel[:,1]-edge[1]*rel[:,0])
    cross = np.array(cross)
    samples = samples[np.all(cross>=0,axis=0)|np.all(cross<=0,axis=0)]
    nearest = np.full(len(samples),np.inf)
    hit_uv = np.zeros((len(samples),2)); hit_xyz = np.zeros((len(samples),3))
    candidates = np.flatnonzero(np.all(tri_max>=lo,axis=1)&np.all(tri_min<=hi,axis=1))
    for ti in candidates:
        ids = triangles[ti]
        a,b,c = tris[ti]
        denom = (b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
        if abs(denom)<1e-9: continue
        p = samples-c
        w0 = ((b[1]-c[1])*p[:,0]+(c[0]-b[0])*p[:,1])/denom
        w1 = ((c[1]-a[1])*p[:,0]+(a[0]-c[0])*p[:,1])/denom
        w = np.column_stack((w0,w1,1-w0-w1))
        inv_z = (w/depth[ids]).sum(1)
        z = 1/inv_z
        good = np.all(w>=-1e-7,axis=1)&(z<nearest)
        if not np.any(good): continue
        corrected = w[good]/depth[ids]/inv_z[good,None]
        nearest[good] = z[good]
        hit_uv[good] = corrected @ uv[ids]
        hit_xyz[good] = corrected @ vertices[ids]
    valid = np.isfinite(nearest)
    assert valid.all(), f'{name}: unmatched projected samples'
    texels = np.floor(hit_uv*texture_size).astype(int).clip(0,texture_size-1)
    mask[texels[:,1],texels[:,0]]=255
    records.append({'id':name,'screen_polygon_1920x1080':polygon,
                    'castle_local_centroid':hit_xyz.mean(0).tolist(),
                    'mapped_samples':len(samples),'unique_uv_texels':len(np.unique(texels,axis=0))})
    draw.polygon(polygon,fill=(255,180,60))
    draw.text((lo[0]-8,lo[1]-15),name,fill=(255,215,90))

light_anchors = []
for name, point, energy, radius in [
    ('gate-interior', [1037,805], 1.33, 1.45),
    ('left-market', [867,816], .735, 1.05),
    ('front-market', [1191,817], .77, 1.2),
    ('right-market', [1459,815], .595, 1.0),
    ('upper-gallery', [1194,678], .525, .9),
]:
    candidates = np.flatnonzero(np.all(tri_max>=point,axis=1)&np.all(tri_min<=point,axis=1))
    nearest = float('inf'); local = None
    for ti in candidates:
        ids=triangles[ti];a,b,c=tris[ti];p=np.array(point)-c
        denom=(b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
        if abs(denom)<1e-9:continue
        w0=((b[1]-c[1])*p[0]+(c[0]-b[0])*p[1])/denom
        w1=((c[1]-a[1])*p[0]+(a[0]-c[0])*p[1])/denom
        w=np.array([w0,w1,1-w0-w1])
        if np.any(w<0):continue
        iz=(w/depth[ids]).sum();z=1/iz
        if z>=nearest:continue
        nearest=z;local=(w/depth[ids]/iz)@vertices[ids]
    assert local is not None
    light_anchors.append({'id':name,'castle_local_position':local.tolist(),
                          'camera_offset_u':.18,'energy':energy,'range_u':radius,
                          'screen_anchor_1920x1080':point})

out_mask = ROOT/'assets/traveler/panti/processed/fortress-window-emission.png'
# A single texel closing fills sampling holes without changing window placement.
Image.fromarray(mask).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3)).save(out_mask)
overlay.save(OUT/'window-placement-overlay.png')
(OUT/'window-uv-mapping.json').write_text(json.dumps({
    'source_camera_snapshot':str(SOURCE),'source_model':fortress['asset'],
    'method':'Perspective-correct frontmost-triangle screen-to-UV mapping; existing slit interiors only',
    'texture_size':[4096,4096],'castle_local_to_world_scale':scale,'windows':records,
    'light_anchors':light_anchors,
    'original_albedo_and_mesh_modified':False,'mask':str(out_mask)},indent=2)+'\n')
print(json.dumps({'mask':str(out_mask),'windows':len(records),'texels':int(np.count_nonzero(mask))}))
