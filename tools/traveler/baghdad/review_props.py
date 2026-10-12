#!/usr/bin/env python3
"""Verify the same-process Baghdad prop-placement receipt and build its comparison board."""
import argparse, hashlib, json, re
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
p=argparse.ArgumentParser();p.add_argument('--report',type=Path,required=True);args=p.parse_args()
root=Path(__file__).resolve().parents[3];out=args.report
before=json.loads((out/'comparison/before.json').read_text());after=json.loads((out/'comparison/after.json').read_text())
original=json.loads((out/'preserved-composition.json').read_text())
current=json.loads((root/'data/traveler/baghdad_scene.json').read_text())
# Compare canonical JSON numbers to avoid float serialization differences.
def same(a,b):
 if isinstance(a,dict):return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
 if isinstance(a,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
 if isinstance(a,(float,int)) and isinstance(b,(float,int)):return abs(a-b)<1e-10
 return a==b
frozen={k:same(v,current[k]) and same(v,after['layout'][k]) for k,v in original['scene'].items()}
preset_hash=hashlib.sha256((root/'data/traveler/look_presets.json').read_bytes()).hexdigest()
manifest=json.loads((out/'assets/source-manifest.json').read_text())
asset_hashes=[]
for asset in manifest['assets']:
 path=root/asset['path'];expected=asset.get('copied_sha256',asset.get('sha256'))
 asset_hashes.append({'path':str(path),'unchanged':hashlib.sha256(path.read_bytes()).hexdigest()==expected})
log_files=[out/'assets/import.log',out/'assets/catalog-run.log',out/'comparison/runtime.log']
logs={str(path.relative_to(out)):{key:len(re.findall(re.escape(key),path.read_text())) for key in ['ERROR','SCRIPT ERROR','SHADER ERROR','Parse Error','WARNING']} for path in log_files}
images=[Image.open(out/'comparison'/name).convert('RGB') for name in ['before.png','after.png']]
performance={label:{'draw_calls_global':x['draw_calls'],'draw_calls_subviewport':x['viewport_draw_calls'],'p50_ms':x['frame_ms']['p50'],'p95_ms':x['frame_ms']['p95'],'uncapped':x['frame_ms']['vsync_disabled'] and x['frame_ms']['engine_max_fps']==0} for label,x in [('before',before),('after',after)]}
imported=after['supporting_props']['imported_assets']
positions=[{'id':v['entry']['id'],'source':v['source'],'height_u':v['height_u'],'width_u':v['width_u'],'height_px':v['projected']['height_px'],'bounds_px':v['projected']['bounds_px'],'stage_position':v['stage_position_effective'],'ground_snap':v['ground_snap'],'bury_u':v['entry'].get('bury_u',0)} for v in imported['placements']]
receipt={'schema':'silkroad.baghdad-props-review.v1','same_process':json.loads((out/'comparison/comparison.json').read_text())['same_process'],'image_sizes':[list(im.size) for im in images],'unchanged_composition':frozen,'look_presets_unchanged':preset_hash==original['look_presets_sha256'],'source_file_checks':asset_hashes,'log_counts':logs,'performance':performance,'imported_sources':imported['source_count']+1,'imported_instances':imported['instance_count']+1,'props_triangles':imported['triangles_all_instances']+after['supporting_props']['triangles']['SuppliedCampfireLogs'],'placements':positions,'all_main_projection_values_unchanged':same(before['composition'],after['composition']),'scope':'static prop placement only; source geometry and materials unchanged; procedural flames remain static'}
receipt['gates']={'fixed_1920x1080':all(im.size==(1920,1080) for im in images),'composition_preserved':all(frozen.values()) and receipt['look_presets_unchanged'] and receipt['all_main_projection_values_unchanged'],'source_hashes_unchanged':all(x['unchanged'] for x in asset_hashes),'logs_clean':all(not any(x.values()) for x in logs.values()),'same_process':receipt['same_process'],'p95_within_33_3ms':performance['after']['p95_ms']<=33.3,'draw_calls_within_60':performance['after']['draw_calls_global']<=60,'uncapped':all(x['uncapped'] for x in performance.values())}
(out/'placement-validation.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
board=Image.new('RGB',(1920,600),'#17191e');draw=ImageDraw.Draw(board);font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',22)
for i,(im,label) in enumerate(zip(images,['BEFORE / PLACEHOLDERS','AFTER / SUPPLIED MODELS'])):
 board.paste(im.resize((940,529),Image.Resampling.LANCZOS),(10+i*960,54));draw.text((20+i*960,20),label,fill='#f4eee4',font=font)
board.save(out/'before-after.jpg',quality=94)
print(json.dumps({'gates':receipt['gates'],'performance':performance,'imported_sources':receipt['imported_sources'],'imported_instances':receipt['imported_instances'],'props_triangles':receipt['props_triangles']},indent=2))
assert all(receipt['gates'].values()),'Inspect placement-validation.json'
