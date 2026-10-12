#!/usr/bin/env python3
"""Read-only measurements of a captured Baghdad composition; writes a review receipt."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument('--capture-prefix', type=Path, required=True)
parser.add_argument('--log', type=Path, required=True)
parser.add_argument('--reference', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=True)
report = json.loads(args.capture_prefix.with_suffix('.json').read_text())
image = Image.open(args.capture_prefix.with_suffix('.png')).convert('RGB')
reference = Image.open(args.reference).convert('RGB')

def stats(im):
    a = np.asarray(im, dtype=float) / 255.0
    maximum, minimum = a.max(axis=2), a.min(axis=2)
    saturation = np.divide(maximum-minimum, maximum, out=np.zeros_like(maximum), where=maximum > 0)
    return {'meanV':float(maximum.mean()), 'meanS':float(saturation.mean())}

actual, target = stats(image), stats(reference)
uv = report['composition']['sun_center_uv']
cx, cy = int(uv[0]*image.width), int(uv[1]*image.height)
a = np.asarray(image)
roi = a[cy-48:cy+49, cx-48:cx+49]
# White-yellow core is separate from the warm halo; fixed threshold documented.
mask = (roi.min(axis=2) >= 210) & (roi.max(axis=2)-roi.min(axis=2) <= 65)
y, x = np.nonzero(mask)
sun_bbox = [int(x.min()+cx-48),int(y.min()+cy-48),int(x.max()+cx-48),int(y.max()+cy-48)] if len(x) else None
sun_radii = [(sun_bbox[2]-sun_bbox[0]+1)/2,(sun_bbox[3]-sun_bbox[1]+1)/2] if sun_bbox else None
log = args.log.read_text()
patterns = {key:len(re.findall(re.escape(key),log)) for key in ['ERROR','SCRIPT ERROR','SHADER ERROR','Parse Error','WARNING']}
root = Path(__file__).resolve().parents[3]
source_paths = [root/'data/traveler/baghdad_scene.json',root/'data/traveler/look_presets.json',root/'scenes/traveler/baghdad_main.tscn']
source_paths += [root/'scripts/traveler/baghdad'/name for name in ['baghdad_viewer.gd','baghdad_look.gd','baghdad_ground.gd','baghdad_supporting_props.gd']]
source_paths += [root/'shaders/traveler/baghdad/baghdad_sunset_sky.gdshader']
receipt = {
    'schema':'silkroad.baghdad-checkpoint-review.v1',
    'capture':str(args.capture_prefix.with_suffix('.png').resolve()),
    'reference':str(args.reference.resolve()),
    'image_size':list(image.size),
    'log':str(args.log.resolve()), 'log_match_counts':patterns,
    'composition':report['composition'],
    'sun_core_pixels':{'threshold':'RGB minimum >= 210 and RGB max-min <=65, 97x97 crop at projected sun center','bbox_xyxy':sun_bbox,'radius_xy_px':sun_radii},
    'hsv':{'current':actual,'reference_measured':target,'delta':{k:actual[k]-target[k] for k in actual},'report_only':True},
    'performance':{'global_draw_calls':report['draw_calls'],'subviewport_draw_calls':report['viewport_draw_calls'],'frame_ms_p50':report['frame_ms']['p50'],'frame_ms_p95':report['frame_ms']['p95'],'vsync_disabled':report['frame_ms']['vsync_disabled'],'max_fps':report['frame_ms']['engine_max_fps'],'warmup_frames':120,'samples':180},
    'gates':{'image_1920x1080':image.size == (1920,1080),'preset_is_baghdad_sunset':report['look']['preset']=='baghdad/sunset','error_and_warning_counts_zero':not any(patterns.values()),'p95_lte_33_3ms':report['frame_ms']['p95']<=33.3,'global_draw_calls_lte_60':report['draw_calls']<=60,'performance_uncapped':report['frame_ms']['vsync_disabled'] and report['frame_ms']['engine_max_fps']==0},
    'effective_outline':{'base_model_u':report['character_style']['settings']['outline']['grow_amount_model_u'],'multiplier':report['layout']['character']['outline_width_multiplier'],'effective_model_u':report['character_style']['settings']['outline']['grow_amount_model_u']*report['layout']['character']['outline_width_multiplier'],'method':'derived from recorded base material and runtime scene multiplier'},
    'unused_legacy_sky_fields':['ground_curve','sky_curve','sun_curve','sun_angle_max_deg'],
    'art_direction_approval':'pending Carlos: this is the first composition checkpoint, not a frozen final scene',
    'source_sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths},
}
(args.out/'checkpoint-validation.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
# A comparison is a reference study, not a same-process A/B or motion verdict.
board = Image.new('RGB',(1920,600),'#17191e')
draw = ImageDraw.Draw(board)
for i,(im,title) in enumerate([(reference,'REFERENCE'),(image,'BAGHDAD / CHECKPOINT 01')]):
    im = im.resize((940,529),Image.Resampling.LANCZOS)
    board.paste(im,(10+i*960,54))
    draw.text((20+i*960,20),title,fill='#f4eee4',font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',22))
board.save(args.out/'reference-comparison.jpg',quality=94)
print(json.dumps({'gates':receipt['gates'],'sun_radii_px':sun_radii,'hsv':receipt['hsv']},ensure_ascii=False,indent=2))
assert all(receipt['gates'].values()), 'Capture verification failed; inspect checkpoint-validation.json'
