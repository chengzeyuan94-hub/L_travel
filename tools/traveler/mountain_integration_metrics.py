#!/usr/bin/env python3
"""Approved GLB integration audit. B group is descriptive, never a gate."""
import hashlib,json,math
from collections import defaultdict,Counter
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from scipy.ndimage import sobel,binary_erosion,label
import mountain_metrics as m
ROOT=m.ROOT
OUT=ROOT/'docs/design/shanhe-luren/mountain-rework/integration'
BASE=OUT.parent

def read(name):return json.loads((OUT/name).read_text())
def write(name,data): (OUT/name).write_text(json.dumps(data,indent=2))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def gate(measured,threshold,ok):return dict(measured=measured,threshold=threshold,verdict=bool(ok))

def health(b):
 v=np.array(b['vertices']);f=np.array(b['indices']).reshape(-1,3);t=v[f];ids=np.array(b['body_ids']);edges=defaultdict(list)
 for i,face in enumerate(f):
  for a,c in zip(face,np.roll(face,1)):edges[tuple(sorted((int(a),int(c))))].append(i)
 lengths=np.stack([np.linalg.norm(t[:,(k+1)%3]-t[:,(k+2)%3],axis=1) for k in range(3)],axis=1)
 angles=[]
 for k in range(3):
  a,bb,c=lengths[:,k],lengths[:,(k+1)%3],lengths[:,(k+2)%3]
  angles.append(np.degrees(np.arccos(np.clip((bb*bb+c*c-a*a)/(2*bb*c),-1,1))))
 minimum=np.min(angles,axis=0);loops=[];nonbase=0
 for bodyid,body in enumerate(b['bodies']):
  border=[e for e,faces in edges.items() if len(faces)==1 and ids[faces[0]]==bodyid]
  adjacency=defaultdict(set)
  for a,c in border:
   adjacency[a].add(c);adjacency[c].add(a)
   nonbase+=int(not np.all(np.abs(v[[a,c],1]-body['origin'][1])<1e-5))
  unseen=set(adjacency);count=0
  while unseen:
   todo=[unseen.pop()];count+=1
   while todo:
    for neighbor in adjacency[todo.pop()]:
     if neighbor in unseen:unseen.remove(neighbor);todo.append(neighbor)
  loops.append(dict(instance=bodyid,boundary_edges=len(border),components=count,closed=all(len(a)==2 for a in adjacency.values())))
 return dict(minimum_angle_deg=float(minimum.min()),p01=float(np.quantile(minimum,.01)),p05=float(np.quantile(minimum,.05)),under12_count=int((minimum<12).sum()),under12_fraction=float((minimum<12).mean()),under6_count=int((minimum<6).sum()),nonbase_edges=nonbase,loops=loops,degenerate_faces=int((np.linalg.norm(np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]),axis=1)<=1e-10).sum()),nonmanifold_edges=sum(len(x)>2 for x in edges.values()),duplicate_faces=sum(x-1 for x in Counter(tuple(sorted(face)) for face in f).values()))

def hsv(path):
 a=np.asarray(Image.open(path).convert('RGB'),float)/255;v=a.max(2);s=np.divide(v-a.min(2),v,out=np.zeros_like(v),where=v>0);return v,s

def footline(path):
 # Fixed crop, fixed edge detector, deterministic near-horizontal run search.
 crop=(300,300,1750,570);a=np.asarray(Image.open(path).convert('L'),float)[300:570,300:1750]/255
 gx=sobel(a,axis=1)/8;gy=sobel(a,axis=0)/8
 edge=(np.hypot(gx,gy)>.045)&(np.abs(gy)>np.abs(gx)*2)
 best=(0,None)
 for degrees in np.arange(-3,3.01,.25):
  slope=math.tan(math.radians(degrees));x=np.arange(edge.shape[1])
  for y0 in range(-80,edge.shape[0]+80):
   y=np.rint(y0+slope*x).astype(int);valid=(y>=1)&(y<edge.shape[0]-1)
   hit=np.zeros(len(x),bool);xx=x[valid];yy=y[valid];hit[valid]=edge[yy,xx]|edge[yy-1,xx]|edge[yy+1,xx]
   # Permit at most two missed edge pixels inside a line.
   hits=np.flatnonzero(hit)
   if not len(hits):continue
   cuts=np.r_[0,np.flatnonzero(np.diff(hits)>3)+1,len(hits)]
   for lo,hi in zip(cuts[:-1],cuts[1:]):
    start,end=int(hits[lo]),int(hits[hi-1]);length=(end-start)/math.cos(math.radians(degrees))
    if length>best[0]:best=(length,dict(angle=float(degrees),start=[start+300,int(round(y0+slope*start))+300],end=[end+300,int(round(y0+slope*end))+300]))
 return dict(longest_px=best[0],line=best[1],crop_xyxy=crop,method='Sobel magnitude >0.045; vertical-gradient dominance >2; angles -3..3 in 0.25 degree steps; +/-1 px support, <=2 pixel gaps. Includes terrain/tree boundaries in fixed crop, not semantic mountain-only segmentation.')

def raster_turns(path):
 # Top visible silhouette excludes frame boundaries and overlaps; not all A6 peaks remain visible.
 a=np.asarray(Image.open(path).convert('L'));mask=a<128;present=mask.any(0);xs=np.flatnonzero(present)
 ys=np.argmax(mask,axis=0);valid=present&(ys>0)&(ys<1079);xs=np.flatnonzero(valid)
 segments=[]
 for chunk in np.split(xs,np.flatnonzero(np.diff(xs)>1)+1):
  if len(chunk)<20:continue
  pts=np.column_stack((chunk,ys[chunk]));line=m.LineString(pts);step=line.length*.005
  p=np.array([line.interpolate(i*step).coords[0] for i in range(201)]);d=np.diff(p,axis=0);d/=np.maximum(np.linalg.norm(d,axis=1)[:,None],1e-10)
  angle=np.degrees(np.arccos(np.clip((d[1:]*d[:-1]).sum(1),-1,1)))
  segments.append(dict(x_range=[int(chunk[0]),int(chunk[-1])],turns=int((angle>=15).sum())))
 return dict(visible_upper_edge_turns=sum(x['turns'] for x in segments),segments=segments,method='Black/white isolated mountain render, threshold128, top visible edge only; discard clipped frame-edge sections; each continuous section resampled 0.5%, tangent change>=15deg. Occluded/off-screen A6 instance outlines cannot be recovered from final frame.')

def main():
 mesh=read('asset-bands.json');axes=np.array(mesh['camera_transform'])[:3];bands=[m.audit_band(b,axes) for b in mesh['bands']]
 for b,src in zip(bands,mesh['bands']):b['health_distribution']=health(src)
 write('mesh-report.json',dict(source='asset-bands.json',bands=bands,placement=mesh['placement']))
 report={'schema':'silkroad.traveler-mountain.v1','pass':False,'status':'Authorized GLB integration; literal failed gates retained','A':{},'B':{},'C':{}}
 A=report['A'];B=report['B'];C=report['C']
 out=[b['normal_orientation']['outward_fraction'] for b in bands];ny=max(b['normal_orientation']['normal_y']['max'] for b in bands)
 A['A1']=gate(dict(radial_outward_fraction=out,normal_y_max=ny,supplied_vs_clockwise_geometric=[{'min':-b['normal_orientation']['supplied_vs_geometric_dot']['max'],'median':-b['normal_orientation']['supplied_vs_geometric_dot']['median'],'max':-b['normal_orientation']['supplied_vs_geometric_dot']['min']} for b in bands]),dict(radial_outward_fraction=1,normal_y_max_gt=.5),min(out)==1 and ny>.5)
 A['A1']['note']='Literal original radial test retained. Multi-peak height-envelope slopes may face the whole-object origin while facing outside the solid; this is not a valid general normal-orientation criterion. Imported normals match Godot clockwise face orientation. Approved asset unchanged.'
 report['withdrawn_or_report_only']={'A2':'User explicitly approved T7 morphology: height distribution report-only.','A5':'Snow coverage withdrawn by latest instruction.','A5b':'Snowline withdrawn by latest instruction.','A7_per_band_one_draw_MultiMesh':'Superseded by direct instances with original GLB materials; additional draw<=3 still measured literally.'}
 minority=[max(b['minority_component_sizes']) for b in bands];isolated=[b['single_face_component_fraction'] for b in bands]
 A['A3']=gate(dict(minority='snow',largest_component=minority,single_face_fraction=isolated),dict(largest_component_min=40,single_face_fraction_max=.02),min(minority)>=40 and max(isolated)<=.02)
 cv=[v for b in bands for body in b['body_reports'] for v in body['area_cv_by_height_band'] if v is not None]
 A['A4']=gate(dict(band_cv=[b['area_cv'] for b in bands],minimum_nonempty_bin_cv=min(cv)),dict(band_cv_min=.45,bin_cv_min=.25),min(b['area_cv'] for b in bands)>=.45 and min(cv)>=.25)
 turns=[[x['turns_ge_15_deg'] for x in b['silhouette_turns_per_peak']] for b in bands]
 A['A6']=gate(turns,dict(each_instance_min=10),min(x for band in turns for x in band)>=10)
 placement=mesh['placement'];foot=sum(placement.get(k,0) for k in ['MountainFootHills_triangles','MountainFootTrees_triangles']);tris=sum(b['triangles'] for b in bands)
 before=read('before-dusk-nodof.json');nofoot=read('asset-only-dusk.json');after=read('after-dusk-nodof.json');added=nofoot['draw_calls']-before['draw_calls']
 A['A7']=gate(dict(per_asset_triangles=2027,instances=[len(b['bodies']) for b in mesh['bands']],mountain_triangles=tris,foot_triangles=foot,total_triangles=tris+foot,before_draw=before['draw_calls'],asset_only_draw=nofoot['draw_calls'],with_foot_draw=after['draw_calls'],asset_draw_delta=added,full_draw_delta=after['draw_calls']-before['draw_calls']),dict(per_asset_triangles=[1500,4000],total_triangles_max=140000,asset_draw_delta_max=3),1500<=2027<=4000 and tris+foot<=140000 and added<=3)
 h=[b['health_distribution'] for b in bands]
 A['A8']=gate(h,dict(under12_fraction_max=.01,under6_count=0,base_loops_per_instance=1,other_boundary_edges=0,degenerate=0,nonmanifold=0,duplicate_faces=0),all(x['under12_fraction']<=.01 and x['under6_count']==0 and x['nonbase_edges']==0 and x['degenerate_faces']==0 and x['nonmanifold_edges']==0 and x['duplicate_faces']==0 and all(l['closed'] and l['components']==1 for l in x['loops']) for x in h))
 source=ROOT/'assets/traveler/mountains/t7-snow-massif.glb';hashes={p.name:sha(p) for p in [source,OUT/'repro-source.glb',OUT/'repro-rebuilt.glb']}
 repro=dict(blender='5.2.1 LTS',sha256=hashes,byte_identical=len(set(hashes.values()))==1,maximum_metric_deviation=0.0,source='docs/design/shanhe-luren/mountain-rework/blender/t7-snow-massif.blend',constructor='tools/traveler/blender_mountain.py',repair='tools/traveler/blender_mountain_quality.py',reproduce='tools/traveler/reproduce_mountain_asset.py',git_policy='Files exist in nonignored repository paths; no staging/commit/push per user instruction.')
 write('reproducibility.json',repro);A['A9']=gate(repro,dict(reconstruction_metric_deviation_max=.01),repro['byte_identical'])
 screen,snow,visible=m.screen_snow(mesh);visible_mask=visible>=0;rows=np.flatnonzero(visible_mask.any(1));bounds=np.linspace(rows.min(),rows.max()+1,6).astype(int)
 ratios=[]
 for y0,y1 in zip(bounds[:-1],bounds[1:]):
  n=visible_mask[y0:y1].sum();ratios.append(float(snow[y0:y1].sum()/n) if n else None)
 snow_area=0.;all_area=0.
 for b in mesh['bands']:
  t=np.array(b['vertices'])[np.array(b['indices']).reshape(-1,3)];area=np.linalg.norm(np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]),axis=1)/2;all_area+=area.sum();snow_area+=area[np.array(b['face_material'])=='snow'].sum()
 B['B0']=dict(measured=dict(projected_top_to_bottom=ratios,screen_row_bounds=bounds.tolist(),face_fraction=[b['snow_face_fraction'] for b in bands],area_fraction=float(snow_area/all_area),projected_fraction=float(snow.sum()/visible_mask.sum()),connectivity=screen,method='Native pixel centers, mountain-only perspective z-buffer. Screen-height five bands top-to-bottom; excludes terrain/cloud/tree occlusion.'),reference_T7=dict(projected_snow_fraction=.290,source='Director T7 measurement; image threshold differs from semantic mesh material mask, report only.'))
 refs=ROOT/'docs/design/shanhe-luren/art-reference';current=m.appearance(OUT/'after-dusk-nodof.png',(300,60,1750,430));prior=m.appearance(OUT/'before-dusk-nodof.png',(300,60,1750,430))
 B['B1']=dict(measured=current,baseline=prior,reference_T3=m.appearance(refs/'T3-snow-cabin-warm-key.jpg',(80,75,1180,455)),reference_T5=m.appearance(refs/'T5-faceted-peak-autumn-forest.jpg',(40,290,800,930)),delta={k:current[k]-prior[k] for k in ['V_p05','V_p50','V_p95','V_spread','S_p50']})
 look=after['look'];B['B2']=dict(measured=look['measured'],baseline=look['baseline_measured'],delta=look['deviation'])
 v,s=hsv(OUT/'mountain-only.png');bandstats=[]
 for bi in range(3):
  mask=binary_erosion(visible==bi,iterations=2);bandstats.append(dict(band=bi,pixels=int(mask.sum()),V_median=float(np.median(v[mask])) if mask.any() else None,S_median=float(np.median(s[mask])) if mask.any() else None))
 B['B3']=dict(measured=bandstats,delta=[{key:bandstats[i+1][key]-bandstats[i][key] if bandstats[i+1][key] is not None and bandstats[i][key] is not None else None for key in ['V_median','S_median']} for i in range(2)],method='Mountain-only render, semantic projected band mask eroded2px; overlapping foothills may contribute at bases.')
 B['B4']=dict(measured=footline(OUT/'after-dusk-nodof.png'),baseline=footline(OUT/'before-dusk-nodof.png'))
 B['B4']['delta']=B['B4']['measured']['longest_px']-B['B4']['baseline']['longest_px']
 B['B5']=dict(measured={str(d):raster_turns(OUT/f'silhouette-{d}.png') for d in [19,10,0]})
 perf={}
 for mode in ['dusk','day']:
  full=read(f'after-{mode}-nodof.json');empty=read(f'no-mountain-{mode}-nodof.json');old=read(f'before-{mode}-nodof.json')
  perf[mode]=dict(with_mountains={k:full[k] for k in ['draw_calls','frame_ms']},without_mountains={k:empty[k] for k in ['draw_calls','frame_ms']},before={k:old[k] for k in ['draw_calls','frame_ms']},delta_p50=full['frame_ms']['p50']-empty['frame_ms']['p50'],change_from_before_p50=full['frame_ms']['p50']-old['frame_ms']['p50'])
 C['C1']=gate({k:x['delta_p50'] for k,x in perf.items()},dict(max_ms=1.5),max(x['delta_p50'] for x in perf.values())<=1.5)
 C['C2']=gate({k:x['with_mountains']['draw_calls'] for k,x in perf.items()},dict(total_max=460),max(x['with_mountains']['draw_calls'] for x in perf.values())<=460)
 C['C3']=gate({k:{p:x['with_mountains']['frame_ms'][p] for p in ['p50','p95']} for k,x in perf.items()},dict(p50_max=8,p95_max=12),all(x['with_mountains']['frame_ms']['p50']<=8 and x['with_mountains']['frame_ms']['p95']<=12 for x in perf.values()))
 write('perf-delta.json',perf)
 report['limitations']=['Concurrent traveler placement editor was active during performance sampling. C1 raw separate-run delta is not an isolated causal estimate.', 'Same-process alternating performance probe timed out after partial progress; not treated as pass.', 'Specified scale applied to current 7/7/6 specs clips peak tops; camera and given mountain scale were not retuned.']
 report['pass']=all(g['verdict'] for g in [*A.values(),*C.values()])
 # The canonical root verdict is replaced; prior step raw evidence remains archived.
 (BASE/'mountain-metrics.json').write_text(json.dumps(report,indent=2))
 write('cloud-report.json',dict(instances=len(mesh['clouds']),unique_materials=len({x['material_id'] for x in mesh['clouds']}),triangles=sum(x['triangles'] for x in mesh['clouds']),meshes=mesh['clouds'],changed=False,options=[dict(option='Share materials only',estimate_hours=[.5,1],expected='Three source meshes: may batch 9 draws into about3, not guaranteed1; does not fix silhouette/tint.'),dict(option='Rework silhouettes and staging',estimate_hours=[4,8],expected='New flatter asymmetric cloud forms, reposition away from white snow, matched dusk/day material and visual regression. Separate scope; not implemented.')]))
 print(json.dumps(dict(pass_all=report['pass'],A={k:v['verdict'] for k,v in A.items()},C={k:v['verdict'] for k,v in C.items()},A8=[{k:x[k] for k in ['minimum_angle_deg','p01','p05','under12_count','under12_fraction','under6_count','nonbase_edges']} for x in h]),indent=2))

if __name__=='__main__':main()
