#!/usr/bin/env python3
"""Layout comparison boards from captured pixels; never alter scene appearance."""
import json
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont,ImageOps
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'docs/design/shanhe-luren/mountain-rework/integration'
FONT='/System/Library/Fonts/Helvetica.ttc'

def board(name,items,columns=2,width=960,height=540):
 rows=(len(items)+columns-1)//columns
 canvas=Image.new('RGB',(columns*width,rows*(height+44)),(20,23,27));draw=ImageDraw.Draw(canvas);font=ImageFont.truetype(FONT,23);sources=[]
 for i,(caption,path) in enumerate(items):
  p=path if isinstance(path,Path) else OUT/(path+'.png');im=Image.open(p).convert('RGB');thumb=ImageOps.contain(im,(width,height));x=(i%columns)*width;y=(i//columns)*(height+44)
  draw.text((x+15,y+10),caption,fill=(238,237,232),font=font)
  canvas.paste(thumb,(x+(width-thumb.width)//2,y+44+(height-thumb.height)//2));sources.append(dict(label=caption,path=str(p.relative_to(ROOT)),image_size=list(im.size)))
 canvas.save(OUT/(name+'.png'))
 (OUT/(name+'.json')).write_text(json.dumps(dict(image_size=list(canvas.size),viewport_size=[1920,1080],kind='comparison layout; source renders are native1920x1080, panels resized to fit',sources=sources),indent=2))

board('before-after', [('BEFORE / dusk','before-dusk-dof'),('AFTER / dusk','after-dusk-dof'),('BEFORE / day','before-day-dof'),('AFTER / day','after-day-dof')])
board('fog-options',[('FOG BEGIN 60 / unchanged preset','after-dusk-nodof'),('FOG BEGIN 45 / review only','fog-45'),('FOG BEGIN 35 / review only','fog-35')],3,640,360)
board('dof-options',[('FAR DOF 19','dof-19'),('FAR DOF 10','dof-10'),('FAR DOF 0','after-dusk-nodof')],3,640,360)
refs=ROOT/'docs/design/shanhe-luren/art-reference'
board('before-after-reference',[('BEFORE / dusk','before-dusk-nodof'),('AFTER / dusk','after-dusk-nodof'),('T7 / approved morphology',refs/'T7-isometric-island-snowcap.jpg'),('BEFORE / day','before-day-nodof'),('AFTER / day','after-day-nodof'),('T5 / lighting reference',refs/'T5-faceted-peak-autumn-forest.jpg')],3,640,496)
