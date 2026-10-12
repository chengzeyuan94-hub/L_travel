"""Validate exported primitive budgets and exact embedded source texture bytes."""
import hashlib
import json
import pathlib
import struct
from PIL import Image, ImageDraw

ROOT=pathlib.Path(__file__).resolve().parents[3]
REPORT=ROOT/'docs/reports/traveler-panti-001/assets'
source=json.loads((REPORT/'reduction-report.json').read_text())
results={}
for name,row in source['assets'].items():
    raw=(ROOT/row['export']).read_bytes()
    magic,version,total=struct.unpack_from('<III',raw,0)
    assert magic==0x46546C67 and version==2 and total==len(raw)
    length,kind=struct.unpack_from('<II',raw,12)
    assert kind==0x4e4f534a
    doc=json.loads(raw[20:20+length])
    bin_offset=20+length+8
    primitives=[p for m in doc['meshes'] for p in m['primitives']]
    assert len(primitives)==1 and len(doc['materials'])==1 and len(doc['images'])==1
    tris=sum(doc['accessors'][p['indices']]['count']//3 for p in primitives)
    assert tris==row['after']['triangles']
    low,high=(25000,50000) if name=='fortress' else (600,1500)
    assert low<=tris<=high
    image=doc['images'][0]
    view=doc['bufferViews'][image['bufferView']]
    start=bin_offset+view.get('byteOffset',0)
    payload=raw[start:start+view['byteLength']]
    embedded_hash=hashlib.sha256(payload).hexdigest()
    assert embedded_hash==row['basecolor_sha256'],(name,'texture was changed')
    assert all('TEXCOORD_0' in p['attributes'] for p in primitives)
    results[name]={'mesh_count':len(doc['meshes']),'primitive_count':len(primitives),
        'material_count':len(doc['materials']),'image_count':len(doc['images']),
        'triangles':tris,'triangle_budget':[low,high],'in_budget':True,
        'export_vertex_count':doc['accessors'][primitives[0]['attributes']['POSITION']]['count'],
        'embedded_image_mime':image['mimeType'],'embedded_image_sha256':embedded_hash,
        'original_basecolor_byte_identical':True,'uv_retained':True,
        'nodes':doc['nodes']}
    panels=Image.new('RGB',(1800,944),(37,44,52))
    for col,stage in enumerate(('before','after')):
        panels.paste(Image.open(REPORT/f'{name}-{stage}-front.png'),(900*col,44))
    draw=ImageDraw.Draw(panels)
    draw.text((20,15),f"SOURCE: {row['before']['triangles']:,} triangles",fill='white')
    draw.text((920,15),f"REDUCED: {tris:,} triangles | original texture retained",fill='white')
    panels.save(REPORT/f'{name}-comparison.png')
(REPORT/'export-validation.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
