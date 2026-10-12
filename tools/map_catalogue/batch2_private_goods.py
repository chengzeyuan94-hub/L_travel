"""Batch2 private-use local procedural vector masters; stdlib only, no external pack/API.
SVG paths/polygons are authored here for the existing stable goods IDs. Colors, facets,
shadow and sparse contours remain readable at 48/96px. Godot renders the SVG masters
and writes 128/256px PNG assets. No public copyright license is asserted.
"""
from pathlib import Path
import math,json,hashlib
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'tools/map_catalogue/batch2_goods_source'
OUT.mkdir(exist_ok=True)
def path(d,c,stroke=None,w=3):return f'<path d="{d}" fill="{c}"'+(f' stroke="{stroke}" stroke-width="{w}" stroke-linejoin="round"' if stroke else '')+'/>'
def poly(points,c):return f'<polygon points="{points}" fill="{c}"/>'
def ellipse(x,y,rx,ry,c):return f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="{ry}" fill="{c}"/>'
def line(x,y,a,b,c,w=3):return f'<path d="M{x} {y} L{a} {b}" fill="none" stroke="{c}" stroke-width="{w}" stroke-linecap="round"/>'
def leaf(x,y,c='#6f9e45'):return path(f'M{x} {y} q-22 -26 10 -35 q24 19 -10 35',c)
def grain(x,y,c):return poly(f'{x},{y-8} {x+7},{y-3} {x+5},{y+5} {x},{y+8} {x-5},{y+3} {x-5},{y-3}',c)
def bowl():return path('M39 149 Q128 170 217 149 L203 193 Q128 226 54 191 Z','#a87546')+path('M39 149 Q128 124 217 149 Q128 177 39 149','#d5ab76')+poly('43,156 66,190 126,211 124,177','#bd915d')
art={}
# Barley: tied golden stalks, swollen faceted seed heads and long awns.
s=''
for n,(x,y) in enumerate([(67,65),(101,41),(133,51),(161,67),(186,95)]):
 s+=line(x,y+10,118+n*5,207,'#a77c38',5)
 for i in range(6):
  yy=y+i*10;xx=x+(i%2)*3
  s+=grain(xx-7,yy,'#e5b54b' if i%2 else '#f6d079')+grain(xx+6,yy+4,'#ce9533')+line(xx-9,yy-3,xx-18,yy-19,'#d5a246',2)+line(xx+9,yy,xx+19,yy-16,'#d5a246',2)
s+=poly('108,169 150,172 148,184 109,181','#b85e37');art['highland_barley']=s
# Raisins: visibly dried, wrinkled brown-purple fruit in a shallow wooden bowl.
s=bowl()
for n,(x,y) in enumerate([(70,133),(93,130),(120,125),(148,130),(177,136),(85,149),(112,147),(142,147),(167,151),(105,164),(135,167)]):
 s+=path(f'M{x-10} {y-6} l7 -6 13 4 5 11 -8 10 -13 -3 -5 -9 Z',['#694737','#76513b','#583d36'][n%3])+path(f'M{x-5} {y-5} l5 4 -1 7 6 1','#a07251')
art['raisins']=s
# Sugar cane: angular green/purple stalks with pale joints, cut ends and leaves.
s=''
for i,x in enumerate([75,112,151]):
 s+=poly(f'{x},50 {x+24},46 {x+28},203 {x+6},210','#739550' if i!=1 else '#866344')+poly(f'{x+6},50 {x+15},47 {x+17},205 {x+8},207','#a8bd6a')
 for y in [79,112,146,179]:s+=poly(f'{x+1},{y} {x+26},{y-2} {x+26},{y+6} {x+2},{y+8}','#d9cd92')
 s+=ellipse(x+12,49,13,6,'#e5d9a1')
s+=path('M87 102 Q27 47 38 33 Q88 58 99 106','#588140')+path('M165 123 Q191 37 222 35 Q205 89 165 123','#789b4d');art['sugarcane']=s
# Xuan paper: cream stacked handmade sheets and a paper scroll, distinct from papyrus plant.
s=poly('42,128 139,76 223,123 128,181','#bfa47b')+poly('42,119 139,67 223,114 128,172','#e4d4b7')+poly('42,110 139,58 223,105 128,163','#fff6dc')+poly('128,163 223,105 223,119 128,177','#d6c2a2')
s+=path('M47 79 L150 45 Q175 35 184 51 L194 79 Q191 88 180 88 L73 125 Q48 129 47 107 Z','#e7d7b9')+ellipse(62,102,17,24,'#c2a27a')+ellipse(62,102,11,17,'#fff6dc')+ellipse(62,102,4,6,'#c3a883')+poly('72,84 166,51 179,64 83,99','#fff9e4');s+=line(43,119,128,172,'#b39b78',2)+line(129,172,222,115,'#b39b78',2)+line(43,128,128,181,'#b39b78',2)+path('M47 107 Q46 125 73 125','#00000000','#ac9372',2)
art['xuan_paper']=s
# Cotton: three soft faceted white bolls on a brown-green branch.
s=line(125,201,130,76,'#8b6641',8)+line(129,160,69,119,'#8b6641',6)+line(130,151,189,102,'#8b6641',6)
for x,y in [(73,112),(137,74),(184,113)]:
 s+=leaf(x+3,y+20)+poly(f'{x-22},{y-2} {x-11},{y-22} {x+8},{y-26} {x+25},{y-9} {x+23},{y+12} {x+3},{y+24} {x-22},{y+15}','#eee8d6')+poly(f'{x-22},{y-2} {x-3},{y-18} {x+15},{y-15} {x+3},{y+4} {x-18},{y+10}','#fffdf1')+poly(f'{x+3},{y+4} {x+25},{y-9} {x+23},{y+12} {x+3},{y+24}','#aba68f')
for x,y in [(73,112),(137,74),(184,113)]:
 s+=poly(f'{x-16},{y+20} {x-8},{y+17} {x},{y+28} {x+8},{y+17} {x+17},{y+19} {x+7},{y+29} {x-5},{y+29}','#96744f')+path(f'M{x-7} {y+27} q-27 7 -31 -13 q20 -7 31 13','#6f9149')
art['cotton']=s
# Folding fan: radial pleated indigo paper on visible bamboo ribs, unlike the orange umbrella.
s=path('M38 88 Q129 23 221 88 L129 208 Z','#315574')
for i in range(9):
 t=i/8;x=38+183*t;y=88-130*t*(1-t)
 s+=line(129,208,round(x,1),round(y,1),'#d6b77a',3)
s+=path('M48 94 Q129 48 211 94 L199 109 Q127 71 59 109 Z','#648c9e')+ellipse(129,206,6,6,'#b27c43');art['folding_fan']=s
# Pomegranate: ruby whole fruit + cut half containing multiple visible seeds.
s=path('M57 79 Q52 49 92 45 Q141 51 149 103 Q149 153 110 172 Q59 174 48 134 Z','#b94238')+poly('61,81 81,62 113,69 108,111 72,129','#d76048')+poly('87,45 78,27 92,33 105,24 110,44','#8f382f')
s+=ellipse(165,145,53,55,'#ab352e')+ellipse(165,145,46,47,'#f4d5a4')
for y,xs in [(115,[149,171,185]),(137,[137,155,175,194]),(158,[143,163,184]),(175,[153,174])]:
 for x in xs:s+=grain(x,y,'#b73434')+ellipse(x-2,y-3,2,2,'#e97a62')
art['pomegranate']=s
# Copper jug: faceted metal vessel with tall narrow neck and large loop handle; no olive twig.
s=path('M156 86 C221 64 220 160 159 165 L153 152 C194 151 194 103 157 103 Z','#94502c')+path('M149 91 C204 72 209 158 158 158 L158 148 C194 143 186 100 155 103 Z','#df9251')
s+=path('M91 58 L134 58 L138 108 Q166 126 163 174 Q149 204 103 202 Q63 194 64 162 Q66 125 91 109 Z','#bb713f')+poly('93,63 111,65 109,121 83,148 76,175 65,161 75,129 92,106','#edb66f')+poly('119,111 138,108 160,141 163,174 139,196 119,177','#9a552f')+ellipse(111,58,25,9,'#dc9d59')+ellipse(111,58,15,5,'#74462d');art['copper_jug']=s
# Carpet: patterned rolled wool rug with woven border/fringe.
s=poly('42,80 154,49 212,178 99,213','#a44642')+poly('55,87 148,61 196,174 101,201','#d29460')+poly('67,98 145,76 184,167 107,188','#3a6d7b')
for x,y in [(106,115),(123,149),(141,173)]:s+=poly(f'{x},{y-13} {x+15},{y} {x},{y+13} {x-15},{y}','#efc286')
for i in range(9):s+=line(99+i*12,211-i*3,101+i*12,223-i*3,'#d3b98c',4)
s+=path('M36 82 Q21 68 42 59 L145 30 Q165 30 169 48 L174 65 L56 99 Z','#b76050')+ellipse(46,79,18,23,'#914039')+ellipse(46,79,10,15,'#d5a175');art['carpet']=s
# Fig: purple pear-like whole fruit and pink seeded cut, distinctly not pomegranate.
s=path('M80 55 Q85 81 65 107 Q35 151 69 187 Q110 212 139 181 Q165 148 123 102 Q103 81 105 55 Z','#75516a')+poly('80,74 91,91 77,126 77,174 58,159 57,130','#aa7891')+line(94,59,105,36,'#8c7650',7)+leaf(114,67)
s+=path('M175 91 Q200 119 211 157 Q211 191 178 205 Q144 201 139 174 Q140 132 161 107 Z','#55455e')+path('M173 106 Q193 131 198 159 Q197 187 178 193 Q154 187 151 168 Q153 133 166 114 Z','#df9b92')
for x,y in [(172,128),(181,143),(164,148),(175,162),(188,167),(166,175),(178,183)]:s+=ellipse(x,y,2.5,3.5,'#f6d3a2')
art['fig']=s
# Papyrus: green fan-shaped reed umbel and tied raw stalks, not finished white paper.
s=''
for x,y in [(85,65),(133,38),(172,85)]:
 s+=line(x,y+15,122+(x-125)*.3,214,'#70834a',5)
 for i in range(9):
  ang=math.radians(190+20*i);xx=x+39*math.cos(ang);yy=y+39*math.sin(ang)
  s+=line(x,y+10,round(xx,1),round(yy,1),'#819b50',3)+ellipse(round(xx,1),round(yy,1),4,5,'#b7bb63')
s+=poly('90,154 160,153 159,166 91,167','#bf8d53');art['papyrus']=s
# Honey: amber-filled pot, honey dipper, droplet and obvious hexagonal honeycomb.
s=path('M59 99 L155 99 L169 137 L164 191 Q112 222 60 189 L49 133 Z','#c78b3c')+poly('59,108 93,106 91,190 69,192 55,168','#e2ad52')+poly('111,114 153,107 163,139 161,185 126,202','#a96c2f')+ellipse(108,100,50,14,'#e6b65d')+ellipse(108,100,38,8,'#ad7330')
s+=line(147,102,191,41,'#96724c',9)
for k in range(4):s+=path(f'M{171+k*5} {59-k*7} l23 17 -7 9 -23 -17 Z','#c7a070')
s+=path('M164 91 Q153 104 165 117 Q177 104 164 91','#e6a835')
for x,y in [(186,157),(207,169),(186,181)]:s+=poly(f'{x-11},{y-7} {x},{y-13} {x+11},{y-7} {x+11},{y+7} {x},{y+13} {x-11},{y+7}','#eebf60')+poly(f'{x-6},{y-4} {x},{y-7} {x+6},{y-4} {x+6},{y+4} {x},{y+7} {x-6},{y+4}','#ac7633')
art['honey']=s
records=[]
for key,shapes in art.items():
 svg='<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">'+ellipse(128,219,88,11,'#bba885') .replace('/>',' opacity="0.25"/>')+shapes+'</svg>'
 p=OUT/(key+'.svg');p.write_text(svg)
 records.append({'goods_id':key,'source':str(p.relative_to(ROOT)),'source_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'source_kind':'local_procedural_vector','scope':'private household play; no separate public license asserted','parameters':{'viewbox':[0,0,256,256],'palette':'warm faceted physical goods','generator':str(Path(__file__).relative_to(ROOT))}})
(OUT/'source-manifest.json').write_text(json.dumps({'records':records,'generator_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()},ensure_ascii=False,indent=2)+'\n')
print('masters',len(records))
