#!/usr/bin/env python3
"""Author the presentation-only map; never modifies the formal ruleset."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
cities={
'rome':[-16,-3,'roman',1.05], 'constantinople':[-10,-4.8,'byzantine',1.05],
'baghdad':[-5,-.4,'blue_dome',1.15], 'panti':[.8,-3,'caravanserai',.85],
'yumenguan':[6,-4.8,'gate',.95], 'changan':[11,-.2,'chinese',1.1],
'geumseong':[16,-3,'chinese',.8], 'quanzhou':[13,5,'port_chinese',.95],
'heijokyo':[19,4.5,'chinese',.85], 'delhi':[1.8,2,'indian',.95],
'simhala':[1,8,'tropical',.85], 'jeddah':[-9,4,'arab_port',.85],
'cairo':[-16,4,'blue_dome',.8], 'aden':[-9,10,'arab_port',.75],
'dagon':[6,8,'tropical',.75], 'chenla':[11,10,'indian',.8]}
# These are display anchors, independent of persisted board-node coordinates.
main=[[-19,-6],[-17,-8],[-13,-8.8],[-9,-8],[-5,-10],[0,-10.5],[7,-10],[13,-9],[17,-7],[18,-3],[16,-1],[16,3.5],[15,5.8],[12,6],[10.5,3.5],[9,2],[7.5,3],[7,5],[5,5.5],[4.5,3.5],[3.4,2],[3.3,6.5],[2.6,8.6],[0,9],[-1.3,7],[-.7,3.8],[-2,2.5],[-4,1.5],[-5,3],[-7.5,5],[-10,5.5],[-11.5,3],[-11.5,.5],[-14,-.5],[-15,-1.8],[-18,-1.8],[-19,-3]]
islands=[main,[[-18,1.5],[-16.3,.9],[-14.5,1.8],[-14,3.4],[-14.8,5],[-17,5.4],[-18.4,4]], [[-11,8],[-9.5,7.3],[-7.5,8],[-7.3,10],[-8.8,11.1],[-10.4,10.8]], [[4.3,6.3],[6,5.9],[7.7,6.5],[7.8,8.6],[6,9.3],[4.5,8.3]], [[9.3,8.3],[10.6,7.6],[12.5,8.2],[12.8,9.9],[11.7,11.2],[9.7,10.8]], [[17.3,2],[18.8,1.8],[20.5,2.7],[21,4.5],[19.5,5.8],[17.5,5.4]], [[-20,7],[-19,6.7],[-18.5,7.6],[-19.2,8.2]], [[16.7,9.5],[17.8,9.1],[18.4,10],[17.5,10.8]]]
bends={
'land_rome_constantinople':[[-13,-2.6],[-11.5,-3.2]],
'land_constantinople_baghdad':[[-8,-3.3],[-7,-1]],
'land_baghdad_panti':[[-2.8,-.3],[-.5,-1]],
'land_panti_yumenguan':[[2.4,-2.8],[4.2,-3.3]],
'land_yumenguan_changan':[[7.5,-3.4],[8.2,-1.3]],
'land_changan_geumseong':[[13.6,.1],[15,-1]],
'land_changan_quanzhou':[[10.5,1.8],[11.8,3]],
'land_baghdad_jeddah':[[-6.1,1.3],[-7.8,2.5]],
'land_panti_delhi':[[.2,-.8],[.7,.6]],
'land_delhi_simhala':[[1.7,4.1],[1.1,6]],
'sea_rome_cairo':[[-19,-1],[-19,1.2],[-17.4,3.8]],
'sea_cairo_jeddah':[[-14,5.5],[-12.6,6.4],[-10,5.8]],
'sea_jeddah_aden':[[-7,6],[-6.7,7.5],[-8,9.5]],
'sea_aden_simhala':[[-5.5,11.3],[-2.3,10.6],[0,9.2]],
'sea_simhala_dagon':[[2.7,9.6],[4.1,9.6]],
'sea_dagon_chenla':[[7.8,10.6],[8.6,11.7],[10,11.1]],
'sea_chenla_quanzhou':[[13.8,9.7],[15,8],[14,6.3]],
'sea_quanzhou_geumseong':[[17,5.5],[18,.3],[17,-1.4]],
'sea_quanzhou_heijokyo':[[15.5,6.4],[17.5,6.4],[19.5,5.7]]}
formal=json.loads((ROOT/'data/rulesets/lshu_configurable_v1/map_corridors_v1.json').read_text())
corridors=[{'id':c['id'],'a':c['a'],'b':c['b'],'via':c['via'],'type':c['route_type'],'bends':bends[c['id']]} for c in formal['corridors']]
layout={'version':1,'description':'Silk Road miniature atlas. Presentation-only authored coordinates, formal identity and connectivity are preserved.','cities':{k:{'anchor':[v[0],v[1]],'style':v[2],'scale':v[3]} for k,v in cities.items()},'land_polygons':islands,'corridors':corridors,
'mountain_ranges':[{'center':[-1,-7.2],'length':16,'width':3.8,'height':4.5,'yaw':-.04,'snow':True},{'center':[6.1,-.3],'length':5.8,'width':2.0,'height':2.5,'yaw':.28,'snow':False},{'center':[-10,.1],'length':3.8,'width':1.8,'height':1.6,'yaw':-.2,'snow':False}],
'oases':[[-4.3,-4,1.0],[-3.5,2.2,.65]],
'rivers':[[[8.1,-7.3],[9,-5],[9.1,-3.3],[9,-2],[9.5,.9],[9,2.5],[8.1,3.5],[7.5,4.5]]],
'bridges':[[9,-1.1,0],[9.4,.65,.3]]}
(ROOT/'assets/miniworld/layout.json').write_text(json.dumps(layout,ensure_ascii=False,indent=2)+'\n')
print('Wrote presentation layout:',len(cities),'cities;',len(corridors),'corridors. Formal ruleset untouched.')
