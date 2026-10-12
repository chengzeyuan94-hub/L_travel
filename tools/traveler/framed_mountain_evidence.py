#!/usr/bin/env python3
"""Compose the frozen-view comparison and verify the latest capture receipts."""
import hashlib,json
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'docs/design/shanhe-luren/mountain-rework'
OUT=BASE/'framed-merge'
font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',25)
records=[]
for name in ['source-only-day','merged-only-day','source-only-dusk','merged-only-dusk','day-clear','dusk-clear','day-dof','dusk-dof']:
 r=json.loads((OUT/(name+'.run.json')).read_text());d=json.loads((OUT/(name+'.json')).read_text())
 assert r['exit_code']==r['error_lines']==r['script_error_lines']==0,name
 assert d['image_size']==d['viewport_size']==[1920,1080]
 assert d['frame_ms']['engine_max_fps']==0 and d['frame_ms']['vsync_disabled']
 records.append(dict(name=name,exit_code=0,ERROR=0,SCRIPT_ERROR=0,sha256=hashlib.sha256((OUT/(name+'.png')).read_bytes()).hexdigest()))
(OUT/'capture-verification.json').write_text(json.dumps(records,indent=2))
for kind in ['clear','dof']:
 canvas=Image.new('RGB',(1920,1168),(20,23,27));draw=ImageDraw.Draw(canvas);sources=[]
 for row,mode in enumerate(['day','dusk']):
  for col,variant in enumerate(['before','after']):
   p=BASE/'color-followup'/f'{mode}-{kind}.png' if variant=='before' else OUT/f'{mode}-{kind}.png'
   im=Image.open(p).convert('RGB');canvas.paste(im.resize((960,540),Image.Resampling.LANCZOS),(col*960,row*584+44))
   draw.text((col*960+18,row*584+10),f'{variant.upper()} / {mode} / {kind}',font=font,fill='white');sources.append(str(p))
 canvas.save(OUT/f'comparison-{kind}.png')
 (OUT/f'comparison-{kind}.json').write_text(json.dumps(dict(image_size=list(canvas.size),viewport_size=[1920,1080],source_images=sources,kind='comparison board; measurements use native source renders'),indent=2))
