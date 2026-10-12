"""Read-only terrain extraction for Blender authoring and precise runtime replacement."""
import json, numpy as np
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'docs/reports/traveler-near-mountain-001/evidence/source-terrain.json'
p=json.loads(SRC.read_text());triangles=[];borders={};records=[]
for m in p['meshes']:
 if m['tile'][:3] not in ['T25','T37','T49']:continue
 v=np.array(m['vertices']);co=np.array(m['colors']);ids=np.array(m['indices']).reshape(-1,3) if m['indices'] else np.arange(len(v)).reshape(-1,3);selected=[]
 for fi,ix in enumerate(ids):
  t=v[ix];c=t.mean(axis=0)
  # Exclude the flat valley floor and Yumenguan's existing foundation.
  if not (9<c[0]<24.1 and 1.35<c[2]<14.8 and c[1]>1.12):continue
  selected.append(fi);triangles.append({'v':t.tolist(),'colors':co[ix].tolist(),'tile':m['tile'],'source_face':fi})
  for i,j in [(0,1),(1,2),(2,0)]:
   a=tuple(np.round(t[i],5));b=tuple(np.round(t[j],5));key=tuple(sorted([a,b]));borders[key]=borders.get(key,0)+1
 records.append({'tile':m['tile'],'node':m['node'],'surface':m['surface'],'removed_faces':selected,'source_face_count':len(ids)})
boundary=[list(k) for k,n in borders.items() if n==1]
out={'schema':'silkroad.near-mountain-layout.v1','source_dump':str(SRC.relative_to(ROOT)),'triangles':triangles,'boundary_segments':boundary,'replacements':records,'source_selected_faces':len(triangles),'glb_path':'res://assets/traveler/terrain/changan-layered-foothill.glb','concept':'docs/reports/traveler-near-mountain-001/concept/near-mountain-concept.png','four_views':'docs/reports/traveler-near-mountain-001/concept/near-mountain-four-views.png','source_terrain_policy':'Original GLBs unchanged; runtime removes only recorded faces and inserts authored terrain patch.'}
(ROOT/'assets/traveler/terrain/changan-near-patch-layout.json').write_text(json.dumps(out,separators=(',',':')))
print('selected',len(triangles),'boundary',len(boundary),[(r['tile'],len(r['removed_faces'])) for r in records])
