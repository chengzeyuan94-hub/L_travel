"""Read exported GLBs and verify rock budgets, UVs and exact source textures."""
import hashlib
import json
import pathlib
import struct
from PIL import Image, ImageDraw, ImageFont

ROOT=pathlib.Path(__file__).resolve().parents[3]
REPORT=ROOT/'docs/reports/traveler-panti-001/assets/rocks'
source=json.loads((REPORT/'reduction-report.json').read_text())
results={}
font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',22)

def board(path,panels,footer):
    image=Image.new('RGB',(900*len(panels),984),(34,42,51))
    draw=ImageDraw.Draw(image)
    for i,(picture,label) in enumerate(panels):
        image.paste(Image.open(REPORT/picture).convert('RGB'),(900*i,48))
        draw.text((900*i+20,12),label,font=font,fill='white')
    draw.text((20,955),footer,font=font,fill='white')
    image.save(REPORT/path)

for name,row in source['assets'].items():
    raw=(ROOT/row['export']).read_bytes()
    magic,version,total=struct.unpack_from('<III',raw,0)
    assert magic==0x46546C67 and version==2 and total==len(raw)
    length,kind=struct.unpack_from('<II',raw,12)
    assert kind==0x4e4f534a
    doc=json.loads(raw[20:20+length]);bin_offset=20+length+8
    primitives=[p for m in doc['meshes'] for p in m['primitives']]
    assert len(doc['meshes'])==1 and len(primitives)==1
    assert len(doc['materials'])==1 and len(doc['images'])==1
    primitive=primitives[0]
    assert primitive.get('mode',4)==4
    triangles=doc['accessors'][primitive['indices']]['count']//3
    assert 150<=triangles<=400 and triangles==row['after']['triangles']
    assert all(k in primitive['attributes'] for k in ('POSITION','NORMAL','TEXCOORD_0'))
    image=doc['images'][0];view=doc['bufferViews'][image['bufferView']]
    start=bin_offset+view.get('byteOffset',0)
    embedded_hash=hashlib.sha256(raw[start:start+view['byteLength']]).hexdigest()
    assert embedded_hash==row['basecolor_sha256']
    assert hashlib.sha256((ROOT/row['source']).read_bytes()).hexdigest()==row['source_sha256']
    assert hashlib.sha256((ROOT/row['basecolor']).read_bytes()).hexdigest()==row['basecolor_sha256']
    pos=doc['accessors'][primitive['attributes']['POSITION']]
    bottom=pos['min'][1]
    assert abs(bottom)<1e-7
    for node in doc['nodes']:
        assert node.get('translation',[0,0,0])==[0,0,0]
        assert node.get('rotation',[0,0,0,1])==[0,0,0,1]
        assert node.get('scale',[1,1,1])==[1,1,1]
        assert 'matrix' not in node
    results[name]={'mesh_count':1,'primitive_count':1,'material_count':1,'image_count':1,
        'triangles':triangles,'triangle_budget':[150,400],'in_budget':True,
        'export_vertices_with_split_flat_normals':pos['count'],
        'dimensions_godot_xyz':[pos['max'][i]-pos['min'][i] for i in range(3)],
        'bottom_y':bottom,'identity_node_transforms':True,
        'uv_retained':True,'original_basecolor_byte_identical':True,
        'basecolor_size':row['basecolor_size'],'embedded_image_sha256':embedded_hash,
        'source_fbx_and_texture_unchanged':True,'nodes':doc['nodes']}
    for view_name in ('front','rear'):
        board(f'{name}-reduction-{view_name}.png',[
              (f'{name}-cleaned-grounded-{view_name}.png',f"BEFORE REDUCTION: {row['pre_reduction']['triangles']:,} triangles"),
              (f'{name}-reduced-{view_name}.png',f"AFTER: {triangles} triangles | flat face normals")],
              'Same camera and lighting. Original texture bytes retained; UVs retained by collapse decimation.')

removed=source['assets']['rock02']['deletion']
assert removed['removed_triangles']==1968 and removed['removed_islands']==2
for view_name in ('front','rear'):
    board(f'rock02-plinth-removal-{view_name}.png',[
          (f'rock02-source-{view_name}.png','SOURCE: detached lettered plinth below main rock'),
          (f'rock02-cleaned-unshifted-{view_name}.png','DELETED: 2 lower islands / 1,968 triangles')],
          'Main rock has not moved in this comparison. The plinth is removed from geometry, not buried.')

(REPORT/'export-validation.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
