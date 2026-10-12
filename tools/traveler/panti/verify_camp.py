"""Validate camping GLBs and make same-view reduction comparison boards."""
import hashlib
import json
import pathlib
import struct
from PIL import Image, ImageDraw, ImageFont

ROOT=pathlib.Path(__file__).resolve().parents[3]
REPORT=ROOT/'docs/reports/traveler-panti-001/assets/camp'
source=json.loads((REPORT/'reduction-report.json').read_text())
manifest=json.loads((REPORT/'source-manifest.json').read_text())
font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',20)
small=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',16)
results={}
overview=Image.new('RGB',(2000,870),(34,42,51));overview_draw=ImageDraw.Draw(overview)

for col,(name,row) in enumerate(source['assets'].items()):
    raw=(ROOT/row['export']).read_bytes()
    magic,version,total=struct.unpack_from('<III',raw,0)
    assert magic==0x46546C67 and version==2 and total==len(raw)
    length,kind=struct.unpack_from('<II',raw,12)
    assert kind==0x4e4f534a
    doc=json.loads(raw[20:20+length]);bin_offset=20+length+8
    primitives=[p for m in doc['meshes'] for p in m['primitives']]
    assert len(doc['meshes'])==1 and len(primitives)==1
    assert len(doc['materials'])==1 and len(doc['images'])==1
    primitive=primitives[0];assert primitive.get('mode',4)==4
    triangles=doc['accessors'][primitive['indices']]['count']//3
    assert triangles==row['after']['triangles']
    assert row['triangle_target']*.97<=triangles<=row['triangle_target']*1.03
    assert all(k in primitive['attributes'] for k in ('POSITION','NORMAL','TEXCOORD_0'))
    image=doc['images'][0];view=doc['bufferViews'][image['bufferView']]
    start=bin_offset+view.get('byteOffset',0)
    embedded_hash=hashlib.sha256(raw[start:start+view['byteLength']]).hexdigest()
    assert embedded_hash==row['basecolor_sha256']
    assert hashlib.sha256((ROOT/row['source']).read_bytes()).hexdigest()==row['source_sha256']
    assert hashlib.sha256((ROOT/row['basecolor']).read_bytes()).hexdigest()==row['basecolor_sha256']
    for file in manifest[name]['files']:
        assert hashlib.sha256((ROOT/file['extracted']).read_bytes()).hexdigest()==file['sha256']
    assert hashlib.sha256(pathlib.Path(manifest[name]['archive']).read_bytes()).hexdigest()==manifest[name]['archive_sha256']
    pos=doc['accessors'][primitive['attributes']['POSITION']]
    assert abs(pos['min'][1])<1e-7
    for node in doc['nodes']:
        assert node.get('translation',[0,0,0])==[0,0,0]
        assert node.get('rotation',[0,0,0,1])==[0,0,0,1]
        assert node.get('scale',[1,1,1])==[1,1,1]
        assert 'matrix' not in node
    results[name]={'mesh_count':1,'primitive_count':1,'material_count':1,'image_count':1,
        'triangles':triangles,'triangle_target':row['triangle_target'],'within_target_3_percent':True,
        'export_vertices_with_split_flat_normals':pos['count'],
        'dimensions_godot_xyz':[pos['max'][i]-pos['min'][i] for i in range(3)],
        'bounds_godot_xyz':[pos['min'],pos['max']],
        'bounds_bottom_center':[(pos['max'][0]+pos['min'][0])/2,pos['min'][1],(pos['max'][2]+pos['min'][2])/2],
        'bottom_y':pos['min'][1],'identity_node_transforms':True,'uv_retained':True,
        'original_basecolor_byte_identical':True,'embedded_image_sha256':embedded_hash,
        'source_archive_fbx_texture_unchanged':True,'source_orientation':row['orientation'],
        'material_double_sided':doc['materials'][0].get('doubleSided',False),
        'emissive_factor':doc['materials'][0].get('emissiveFactor',[0,0,0]),'nodes':doc['nodes']}
    for view_name in ('front','rear','left','right'):
        board=Image.new('RGB',(1600,864),(34,42,51));draw=ImageDraw.Draw(board)
        for i,stage in enumerate(('source','reduced')):
            board.paste(Image.open(REPORT/f'{name}-{stage}-{view_name}.png').convert('RGB'),(800*i,40))
            count=row['before']['triangles'] if stage=='source' else triangles
            draw.text((800*i+16,9),f'{name.upper()} {stage.upper()} / {count:,} triangles',font=font,fill='white')
        draw.text((16,840),'Same camera and lighting. Original JPEG bytes and UVs retained; reduced mesh uses flat face normals.',font=small,fill='white')
        board.save(REPORT/f'{name}-comparison-{view_name}.png')
    for i,stage in enumerate(('source','reduced')):
        im=Image.open(REPORT/f'{name}-{stage}-front.png').convert('RGB').resize((400,400))
        overview.paste(im,(400*col,435*i+28))
        count=row['before']['triangles'] if stage=='source' else triangles
        overview_draw.text((400*col+10,435*i+6),f'{name} / {stage} / {count:,} tris',font=small,fill='white')

overview.save(REPORT/'reduction-overview.png')
(REPORT/'export-validation.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
