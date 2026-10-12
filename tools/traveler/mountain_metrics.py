#!/usr/bin/env python3
"""Geometry-first mountain audit. Requires numpy, Pillow, scipy and shapely.

All indices reference vertices welded at 1e-5 by the Godot exporter. Per-face
material labels come from the generator, never from thresholding lit pixels.
B-group appearance measurements deliberately have no threshold or verdict.
"""
from __future__ import annotations
import argparse,json,math
from collections import defaultdict,Counter
from pathlib import Path
import numpy as np
from PIL import Image
from scipy.ndimage import label
from shapely.geometry import Polygon,LineString
from shapely.ops import unary_union

ROOT=Path(__file__).resolve().parents[2]

def stats(values):
    a=np.asarray(values,dtype=float)
    return {'min':float(a.min()),'median':float(np.median(a)),'max':float(a.max())} if len(a) else None

def cv(a):
    return float(np.std(a)/np.mean(a)) if len(a) and np.mean(a)>0 else None

def lab(rgb):
    a=np.asarray(rgb,dtype=float)
    linear=np.where(a<=.04045,a/12.92,((a+.055)/1.055)**2.4)
    xyz=linear@np.array([[.4124564,.2126729,.0193339],[.3575761,.7151522,.1191920],[.1804375,.0721750,.9503041]])
    xyz/=np.array([.95047,1,1.08883]);f=np.where(xyz>(6/29)**3,np.cbrt(xyz),xyz/(3*(6/29)**2)+4/29)
    return np.stack([116*f[:,1]-16,500*(f[:,0]-f[:,1]),200*(f[:,1]-f[:,2])],axis=1)

def appearance(path,box):
    image=Image.open(path).convert('RGB');a=np.asarray(image.crop(box),float)/255
    high=a.max(2);low=a.min(2);sat=np.divide(high-low,high,out=np.zeros_like(high),where=high>0)
    q=np.quantile(high,[.05,.5,.95]);full=np.asarray(image,float)/255;v=full.max(2);lo=full.min(2)
    return {'image':str(path.relative_to(ROOT)),'image_size':list(image.size),'crop_xyxy':list(box),
            'V_p05':float(q[0]),'V_p50':float(q[1]),'V_p95':float(q[2]),'V_spread':float(q[2]-q[0]),'S_p50':float(np.median(sat)),
            'meanV':float(v.mean()),'meanS':float(np.divide(v-lo,v,out=np.zeros_like(v),where=v>0).mean()),'method':'continuous HSV on original display RGB, no resampling'}

def silhouette(triangles,axes):
    projected=triangles@axes[:2].T
    polys=[Polygon(t) for t in projected if abs((t[1,0]-t[0,0])*(t[2,1]-t[0,1])-(t[1,1]-t[0,1])*(t[2,0]-t[0,0]))>1e-9]
    outline=unary_union(polys)
    if outline.geom_type=='MultiPolygon':outline=max(outline.geoms,key=lambda p:p.area)
    ring=outline.exterior;step=ring.length*.005
    points=np.array([ring.interpolate(i*step).coords[0] for i in range(200)])
    vectors=np.roll(points,-1,axis=0)-points;vectors/=np.maximum(np.linalg.norm(vectors,axis=1)[:,None],1e-15)
    angles=np.degrees(np.arccos(np.clip(np.sum(vectors*np.roll(vectors,1,axis=0),axis=1),-1,1)))
    return {'turns_ge_15_deg':int((angles>=15).sum()),'perimeter':float(ring.length),'resample_fraction':.005}

def audit_band(b,axes):
    vertices=np.asarray(b['vertices']);indices=np.asarray(b['indices']).reshape(-1,3);tri=vertices[indices];mid=tri.mean(1)
    normals=np.asarray(b['normals']);cross=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]);areas=np.linalg.norm(cross,axis=1)/2
    calculated=cross/(2*areas[:,None]);rock=np.asarray(b['face_material'])=='rock';ids=np.asarray(b['body_ids'])
    origins=np.array([b['bodies'][i]['origin'] for i in ids]);radial=mid-origins;radial[:,1]=0;radial/=np.maximum(np.linalg.norm(radial,axis=1)[:,None],1e-15)
    dots=np.sum(normals*radial,axis=1);edges=defaultdict(list)
    for fi,face in enumerate(indices):
        for a,c in ((face[0],face[1]),(face[1],face[2]),(face[2],face[0])):edges[tuple(sorted((int(a),int(c))))].append(fi)
    adjacent=[v for v in edges.values() if len(v)==2]
    material_components={}
    for material,mask in [('rock',rock),('snow',~rock)]:
        neighbors=defaultdict(list)
        for a,c in adjacent:
            if mask[a] and mask[c]:neighbors[a].append(c);neighbors[c].append(a)
        unseen=set(np.flatnonzero(mask));components=[]
        while unseen:
            todo=[unseen.pop()];size=0
            while todo:
                current=todo.pop();size+=1
                for neighbor in neighbors[current]:
                    if neighbor in unseen:unseen.remove(neighbor);todo.append(neighbor)
            components.append(size)
        material_components[material]=sorted(components,reverse=True)
    minority='rock' if rock.sum() <= (~rock).sum() else 'snow'
    components=material_components['rock']
    body_reports=[]
    for i,body in enumerate(b['bodies']):
        subset=ids==i;relative=(mid[subset,1]-body['origin'][1])/body['height'];ar=areas[subset];rs=rock[subset]
        five=np.minimum((relative*5).astype(int),4);eight=np.minimum((relative*8).astype(int),7)
        body_reports.append({'body':i,'main':body['main'],'peak_id':body['peak_id'],'faces':int(subset.sum()),
          'rock_fraction_by_height_band':[float(rs[five==k].mean()) if np.any(five==k) else None for k in range(5)],
          'area_cv':cv(ar),'area_cv_by_height_band':[cv(ar[eight==k]) for k in range(8)]})
    silhouettes=[]
    for peak in sorted({x['peak_id'] for x in b['bodies']}):
        body_set=[i for i,x in enumerate(b['bodies']) if x['peak_id']==peak]
        silhouettes.append({'peak_id':peak,**silhouette(tri[np.isin(ids,body_set)],axes)})
    lengths=np.stack([np.linalg.norm(tri[:,1]-tri[:,2],axis=1),np.linalg.norm(tri[:,0]-tri[:,2],axis=1),np.linalg.norm(tri[:,0]-tri[:,1],axis=1)],1)
    angles=[]
    for k in range(3):
        a=lengths[:,k];bb=lengths[:,(k+1)%3];c=lengths[:,(k+2)%3]
        angles.append(np.degrees(np.arccos(np.clip((bb*bb+c*c-a*a)/(2*bb*c),-1,1))))
    boundary=[(edge,faces[0]) for edge,faces in edges.items() if len(faces)==1];base=[];other=[]
    for edge,fi in boundary:
        y0=b['bodies'][ids[fi]]['origin'][1]
        (base if np.all(np.abs(vertices[list(edge),1]-y0)<1e-5) else other).append(edge)
    rgb=np.asarray(b['colors'])
    baked_linear=b.get('material',{}).get('unshaded',False) and not b.get('material',{}).get('vertex_color_is_srgb',True)
    if baked_linear:rgb=np.where(rgb<=.0031308,rgb*12.92,1.055*np.maximum(rgb,0)**(1/2.4)-.055)
    colors=lab(rgb);de=[float(np.linalg.norm(colors[a]-colors[c])) for a,c in adjacent]
    unique_faces=Counter(tuple(sorted(f)) for f in indices)
    return {'band_index':b['band_index'],'triangles':len(indices),'surfaces':b['surface_count'],
       'normal_orientation':{'outward_fraction':float(np.mean(dots>0)),'inward_count':int((dots<0).sum()),'radial_dot':stats(dots),'normal_y':stats(normals[:,1]),'normal_y_ge_022':int((normals[:,1]>=.22).sum()),'supplied_vs_geometric_dot':stats(np.sum(normals*calculated,axis=1))},
       'snow_face_fraction':float((~rock).mean()),'area_cv':cv(areas),'body_reports':body_reports,
       'material_component_sizes':material_components,'minority_material':minority,'minority_component_sizes':material_components[minority],
       'single_face_component_fraction':sum(c.count(1) for c in material_components.values())/len(indices),
       'rock_component_sizes':sorted(components,reverse=True),'isolated_rock_face_fraction':components.count(1)/int(rock.sum()),
       'adjacent_face_delta_e76':stats(de),'vertex_color_lab_input':'linear baked colors encoded to sRGB' if baked_linear else 'legacy authoring RGB','silhouette_turns_per_peak':silhouettes,
       'mesh_health':{'minimum_angle_deg':float(np.min(angles)),'base_boundary_edges':len(base),'other_boundary_edges':len(other),'nonmanifold_edges':sum(len(v)>2 for v in edges.values()),'duplicate_faces':sum(v-1 for v in unique_faces.values() if v>1)}}

def screen_snow(mesh):
    # Exact native pixel centers, perspective-correct inverse-depth z buffer.
    width,height=1920,1080;cam=np.asarray(mesh['camera_transform']);f=height/(2*math.tan(math.radians(mesh['camera_fov'])/2))
    depth=np.zeros((height,width));snow=np.zeros((height,width),bool);visible_band=np.full((height,width),-1,dtype=np.int16)
    for b in mesh['bands']:
        vertices=np.asarray(b['vertices']);camera=(vertices-cam[3])@cam[:3].T;z=-camera[:,2]
        projected=np.column_stack((width/2+camera[:,0]*f/z,height/2-camera[:,1]*f/z));faces=np.asarray(b['indices']).reshape(-1,3)
        for face,material in zip(faces,b['face_material']):
            if np.any(z[face]<=0):continue
            p=projected[face];xmin=max(0,int(np.floor(p[:,0].min())));xmax=min(width,int(np.ceil(p[:,0].max())))
            ymin=max(0,int(np.floor(p[:,1].min())));ymax=min(height,int(np.ceil(p[:,1].max())))
            if xmin>=xmax or ymin>=ymax:continue
            a,bb,c=p;den=(bb[1]-c[1])*(a[0]-c[0])+(c[0]-bb[0])*(a[1]-c[1])
            if abs(den)<1e-9:continue
            yy,xx=np.mgrid[ymin:ymax,xmin:xmax];xx=xx+.5;yy=yy+.5
            w0=((bb[1]-c[1])*(xx-c[0])+(c[0]-bb[0])*(yy-c[1]))/den
            w1=((c[1]-a[1])*(xx-c[0])+(a[0]-c[0])*(yy-c[1]))/den;w2=1-w0-w1
            inv=w0/z[face[0]]+w1/z[face[1]]+w2/z[face[2]];old=depth[ymin:ymax,xmin:xmax]
            hit=(w0>=0)&(w1>=0)&(w2>=0)&(inv>old);old[hit]=inv[hit]
            snow[ymin:ymax,xmin:xmax][hit]=material=='snow';visible_band[ymin:ymax,xmin:xmax][hit]=b['band_index']
    results={}
    for neighbors,structure in [(4,np.array([[0,1,0],[1,1,1],[0,1,0]])),(8,np.ones((3,3)))]:
        labels,n=label(snow,structure);sizes=np.bincount(labels.ravel())[1:]
        results[str(neighbors)+'_neighbors']={'components':n,'at_least_2000_pixels':int((sizes>=2000).sum()),'under_100_pixels':int((sizes<100).sum()),'sizes':sorted(sizes.tolist(),reverse=True)}
    return results,snow,visible_band

def write_reports(result, mesh, output_dir, calibrate_baseline=False):
    bands=result['bands'];checks=[]
    def compare(name,actual,expected):
        aa=np.atleast_1d(actual);ee=np.atleast_1d(expected)
        ok=bool(np.all(np.abs(aa-ee)<=np.maximum(.02*np.abs(ee),1e-7)))
        checks.append({'name':name,'measured':actual,'expected':expected,'relative_tolerance':.02,'verdict':ok})
    compare('triangle_counts',[b['triangles'] for b in bands],[6286,4088,2532])
    compare('outward_normal_fraction',[b['normal_orientation']['outward_fraction'] for b in bands],[0,0,0])
    compare('normal_y_min_median_max',[result['normal_y'][k] for k in ['min','median','max']],[-.969,-.640,-.115])
    compare('normal_y_ge_022',[b['normal_orientation']['normal_y_ge_022'] for b in bands],[0,0,0])
    compare('snow_fraction',[b['snow_face_fraction'] for b in bands],[.196,.187,.169])
    for key,expected in [('current',[.698,.494,.574]),('T3',[.980,.604,.240]),('T5',[.914,.600,.211])]:
        compare(key+'_V95_spread_S50',[result['appearance'][key][k] for k in ['V_p95','V_spread','S_p50']],expected)
    compare('screen_snow_4_connected',[result['screen_snow_components']['4_neighbors'][k] for k in ['components','at_least_2000_pixels']],[89,10])
    compare('screen_snow_8_connected',[result['screen_snow_components']['8_neighbors'][k] for k in ['components','at_least_2000_pixels']],[45,9])
    a3_fails=any(max(b['minority_component_sizes'],default=0)<40 or b['single_face_component_fraction']>.02 for b in bands)
    compare('revised_A3_fails_on_baseline',int(a3_fails),1)
    formula=all(sum(i==idx for i in b['body_ids'])==body['n_ang']*(2*body['n_ring']-3) for b in mesh['bands'] for idx,body in enumerate(b['bodies']))
    calibration={'pass':all(c['verdict'] for c in checks),'geometry_formula_matches_all_bodies':formula,'checks':checks,
      'notes':['Revised dispatch accepts the originally selected fixed T3/T5 crops and both 4/8 connectivity definitions.',
               'Normals: first corner of each of all 12906 faces, transformed by world basis and normalized.']}
    if calibrate_baseline:(output_dir/'baseline-calibration.json').write_text(json.dumps(calibration,indent=2))
    gates={}
    def gate(name,measured,threshold,verdict):gates[name]={'measured':measured,'threshold':threshold,'verdict':bool(verdict)}
    outward=[b['normal_orientation']['outward_fraction'] for b in bands];nymax=result['normal_y']['max']
    gate('A1_normal_orientation',{'outward_fraction':outward,'normal_y_max':nymax},{'outward_fraction':1,'normal_y_max_gt':.5},all(v==1 for v in outward) and nymax>.5)
    fractions=[v for b in bands for body in b['body_reports'] for v in body['rock_fraction_by_height_band']]
    present=[v for v in fractions if v is not None]
    gate('A2_rock_by_height',{'min':min(present),'max':max(present),'empty_bins':fractions.count(None)},{'each_bin_range':[.08,.60]},None not in fractions and all(.08<=v<=.60 for v in present))
    components=[max(b['minority_component_sizes'],default=0) for b in bands];isolated=[b['single_face_component_fraction'] for b in bands]
    gate('A3_minority_connectivity',{'minority_material':[b['minority_material'] for b in bands],'maximum_components':components,'single_face_component_fractions':isolated},{'max_component_min':40,'single_face_fraction_max':.02},min(components)>=40 and max(isolated)<=.02)
    cvs=[v for b in bands for body in b['body_reports'] for v in body['area_cv_by_height_band']];present_cv=[v for v in cvs if v is not None]
    gate('A4_irregular_area',{'band_cv':[b['area_cv'] for b in bands],'min_nonempty_body_bin_cv':min(present_cv),'empty_body_bins':cvs.count(None)},{'whole_cv_min':.45,'each_height_bin_cv_min':.25},all(b['area_cv']>=.45 for b in bands) and min(present_cv)>=.25)
    snow=[b['snow_face_fraction'] for b in bands];gate('A5_snow_default',snow,{'min':.55},min(snow)>=.55)
    turns=[min(p['turns_ge_15_deg'] for p in b['silhouette_turns_per_peak']) for b in bands];gate('A6_silhouette',turns,{'each_peak_min':10},min(turns)>=10)
    count=result['triangles'];surfaces=sum(b['surfaces'] for b in bands)
    gate('A7_triangles_surfaces',{'triangles':count,'surfaces':surfaces,'additional_draw_calls':None},{'triangles':[60000,140000],'surfaces':3,'additional_draw_calls_max':3},60000<=count<=140000 and surfaces==3)
    angle=min(b['mesh_health']['minimum_angle_deg'] for b in bands);boundary=sum(b['mesh_health']['other_boundary_edges'] for b in bands);duplicates=sum(b['mesh_health']['duplicate_faces'] for b in bands)
    gate('A8_health',{'min_angle_deg':angle,'non_base_boundary_edges':boundary,'duplicate_faces':duplicates},{'min_angle_deg':12,'non_base_boundary_edges':0,'duplicate_faces':0},angle>=12 and boundary==0 and duplicates==0)
    gates['A9_robustness']={'measured':None,'threshold':{'seeds_all_pass':5},'verdict':False,'status':'not_run; planned for S7'}
    report={'schema':'silkroad.traveler-mountain.v1','pass':False,'status':'S1 baseline' if calibrate_baseline else 'S3 only; S4-S8 not implemented or validated','A':gates,
      'B':{'B1':{'measured':result['appearance']['current'],'baseline':{'V_p95':.698,'V_spread':.494,'S_p50':.574},'reference_T3':result['appearance']['T3'],'reference_T5':result['appearance']['T5'],
                 'delta':{k:result['appearance']['current'][k]-v for k,v in {'V_p95':.698,'V_spread':.494,'S_p50':.574}.items()}}},
      'C':{'measured':None,'verdict':False,'status':'not_run; planned for S8'}}
    look=result.get('look_evidence',{})
    if look:report['B']['B2']={'measured':look['measured'],'baseline':look['baseline_measured'],'delta':look['deviation']}
    report['pass']=all(g['verdict'] for g in gates.values()) and report['C']['verdict']
    (output_dir/'mountain-metrics.json').write_text(json.dumps(report,indent=2))

def main():
    p=argparse.ArgumentParser();p.add_argument('--mesh',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--image',type=Path,required=True);p.add_argument('--calibrate-baseline',action='store_true');p.add_argument('--report',action='store_true');a=p.parse_args()
    mesh=json.loads(a.mesh.read_text());axes=np.asarray(mesh['camera_transform'])[:3];bands=[audit_band(b,axes) for b in mesh['bands']]
    screen,mask,visible=screen_snow(mesh)
    refs=ROOT/'docs/design/shanhe-luren/art-reference'
    appearance_report={'current':appearance(a.image.resolve(),(300,60,1750,430)),
      'T3':appearance(refs/'T3-snow-cabin-warm-key.jpg',(80,75,1180,455)),
      'T5':appearance(refs/'T5-faceted-peak-autumn-forest.jpg',(40,290,800,930)),
      'reference_crop_note':'Fixed Codex crop set, now accepted in revised card. Chosen before reference target values were supplied; unchanged on reruns.'}
    ns=np.concatenate([np.array(b['normals'])[:,1] for b in mesh['bands']])
    result={'schema':'silkroad.massif-baseline.v1','triangles':sum(b['triangles'] for b in bands),'normal_y':stats(ns),'bands':bands,'screen_snow_components':screen,'appearance':appearance_report,
      'screen_mask_method':'Only mountain geometry, native 1920x1080 pixel centers, perspective inverse-depth z buffer; both 4 and 8 connectivity reported. No terrain/tree/cloud occluders.'}
    sidecar=a.image.with_suffix('.json')
    if sidecar.exists():result['look_evidence']=json.loads(sidecar.read_text()).get('look',{})
    a.output.write_text(json.dumps(result,indent=2));
    if a.calibrate_baseline or a.report:write_reports(result,mesh,a.output.parent,a.calibrate_baseline)
    mask_path=a.output.with_name(a.output.stem+'-snow-mask.png');Image.fromarray(mask.astype(np.uint8)*255).save(mask_path)
    mask_path.with_suffix('.json').write_text(json.dumps({'image_size':[1920,1080],'viewport_size':[1920,1080],'source_mesh':str(a.mesh),'method':result['screen_mask_method']},indent=2))
    print(json.dumps({'triangles':result['triangles'],'normal_y':result['normal_y'],'bands':[{'band':b['band_index'],'triangles':b['triangles'],'outward':b['normal_orientation']['outward_fraction'],'snow':b['snow_face_fraction'],'area_cv':b['area_cv'],'minimum_angle':b['mesh_health']['minimum_angle_deg'],'isolated_rock_fraction':b['isolated_rock_face_fraction']} for b in bands],'screen_components':{k:{kk:vv for kk,vv in v.items() if kk!='sizes'} for k,v in screen.items()},'appearance':appearance_report},indent=2))
if __name__=='__main__':main()
