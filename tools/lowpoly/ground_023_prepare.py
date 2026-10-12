#!/usr/bin/env python3
"""Fit the existing 022 layout to the new 023 ground; do not modify rules/assets."""
from pathlib import Path
import hashlib,json,math,sys
import numpy as np
sys.dont_write_bytecode=True
from layout_021_plan import ground_basis,direction,normalize,clean
from density_017_audit import RaySurface,LAND
from visual_006_audit import GLB
ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/ground-detail-023'
def read(p):return json.loads(Path(p).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
    original=read(ROOT/'docs/design/map-layout-021/placements.json')
    variants={a['id']:a for a in read(ROOT/'docs/design/terrain-transition-022/variant-placements.json')['variants']}
    ground=LIB/'exports/ground.glb';primitives=GLB(ground).primitives()
    old=RaySurface(GLB(ROOT/'assets/game/lowpoly/planet/terrain.glb').primitives())
    new=RaySurface(primitives)
    colors=np.concatenate([p['color'][p['faces']][:,:,:3] for p in primitives if p['name']==LAND])
    def delta(p):
        a=old.sample(p);b=new.sample(p)
        return b['radius']-a['radius'] if a and b else 0.
    landmarks=[]
    for item in original['landmarks']:
        aid=item['id'];base=variants.get(aid,item);basis=ground_basis(base['logical'],base['yaw_deg']);up=direction(base['logical'])
        radius=item['footprint_radius'];probe=[up*11]
        probe += [up*11+basis@np.array([math.cos(t)*radius*.8,0,math.sin(t)*radius*.8]) for t in np.linspace(0,math.tau,12,endpoint=False)]
        ds=[delta(p) for p in probe]
        if max(abs(d) for d in ds)<.0002 and aid not in ('everest','taklamakan_dunes'):continue
        path=(ROOT/'docs/design/terrain-transition-022'/f'exports/{aid}.glb') if aid in variants else ROOT/'docs/design/landmark-library-020'/f'exports/{aid}.glb'
        ps=GLB(path).primitives();v=np.concatenate([p['positions'] for p in ps]);lo=v.min(axis=0);hi=v.max(axis=0);scale=base['scale']
        height=base['ground_height']+max(ds)
        seating={}
        if aid in ('everest','taklamakan_dunes'):
            hero=np.unique(np.concatenate([p['positions'] for p in ps if '_Hero_' in p['name']]),axis=0)
            def clearance(h):
                vv=(hero*scale)@basis.T+up*(11+h)
                return min(float(np.linalg.norm(w)-(new.sample(w) or {'radius':11})['radius']) for w in vv)
            initial=clearance(height)
            for _ in range(4):height+=.014-clearance(height)
            final=clearance(height)
            assert final>.01,(aid,final)
            seating={'hero_minimum_clearance_world':final,'before_adjustment_clearance':initial,'height_change_from_022':height-base['ground_height']}
        origin=up*(11+height);heights=[];cs=[];n=41
        for z in np.linspace(lo[2],hi[2],n):
            for x in np.linspace(lo[0],hi[0],n):
                p=origin+basis@np.array([x*scale,0,z*scale]);hit=new.sample(p)
                target=normalize(p)*((hit['radius'] if hit else 11)-.012)
                heights.append(float(np.dot(target-origin,basis[:,1])/scale))
                cs.append((np.array(hit['barycentric'])@colors[hit['face']]).tolist() if hit else [.66,.59,.39])
        landmarks.append({'id':aid,'logical':base['logical'],'yaw_deg':base['yaw_deg'],'scale':scale,'ground_height':height,
            'previous_ground_height':base['ground_height'],'glb':str(path.relative_to(ROOT)),'sha256':sha(path),'authored_transition':aid in variants,
            'seating':seating,'sampled_ground_delta_minmax':[min(ds),max(ds)],
            'conform_grid':{'min':[lo[0],lo[2]],'step':[(hi[0]-lo[0])/(n-1),(hi[2]-lo[2])/(n-1)],'size':[n,n],
                'heights':heights,'colors_srgb':cs,'blend_height':min(.26,float(hi[1]-lo[1])*.22)}})
    props=[];prop_feet={}
    for item in original['props']:
        if item.get('layer')=='cloud':continue
        up=direction(item['logical']);b=ground_basis(item['logical']);r=item['footprint_radius']*.35
        ds=[delta(up*11)]+[delta(up*11+b@np.array([math.cos(t)*r,0,math.sin(t)*r])) for t in np.linspace(0,math.tau,8,endpoint=False)]
        if max(abs(x) for x in ds)<=.0002:continue
        asset=item['asset_id']
        if asset not in prop_feet:
            path=ROOT/'docs/design/terrain-library-018/exports'/f'{asset}.glb'
            vertices=np.unique(np.concatenate([p['positions'] for p in GLB(path).primitives()]),axis=0)
            prop_feet[asset]=vertices[vertices[:,1]<=vertices[:,1].min()+.006]
        foot=prop_feet[asset];basis=ground_basis(item['logical'],item['yaw_deg'])
        vv=(foot*item['scale'])@basis.T+up*(11+item['ground_height'])
        def foot_gaps(surface,change):
            return [float(np.linalg.norm(p+up*change)-(surface.sample(p+up*change) or {'radius':11})['radius']) for p in vv]
        before_gaps=foot_gaps(old,0);target=min(-.004,max(-.018,min(before_gaps)))
        change=max(ds)
        for _ in range(3):change+=target-min(foot_gaps(new,change))
        gaps=foot_gaps(new,change)
        props.append({'id':item['id'],'logical':item['logical'],'delta_world':change,'sample_range':[min(ds),max(ds)],'foot_vertices':len(foot),'foot_clearance_minmax_after':[min(gaps),max(gaps)],'contact_target':target})
    ambient_source=ROOT/'scripts/ui/ambient/placements.json';ambient=read(ambient_source);ambient_adjustments=[]
    def ambient_row(nodes,index,xy,height,foot,yaw=0.):
        up=direction(xy);basis=ground_basis(xy,math.degrees(yaw));origin=up*(11+height)
        probes=[origin+basis@np.array([x,0,z]) for x,z in foot]
        ds=[delta(p) for p in probes]
        if max(abs(d) for d in ds)<.0002:return
        change=max(ds)
        def clearances(d):
            return [float(np.linalg.norm(p+up*d)-(new.sample(p+up*d) or {'radius':11})['radius']) for p in probes]
        if 'WindmillWindcatcher' in nodes:
            for _ in range(3):change+=-.0004-max(clearances(change))
        gaps=clearances(change)
        ambient_adjustments.append({'nodes':nodes,'index':index,'logical':xy,'delta_world':change,'ground_delta_minmax':[min(ds),max(ds)],'foot_clearance_minmax_after':[min(gaps),max(gaps)],'sample_count':len(probes)})
    ring=[(.3*math.cos(t),.3*math.sin(t)) for t in np.linspace(0,math.tau,7,endpoint=False)]
    footprint=ring+[((ring[i][0]+ring[(i+1)%7][0])/2,(ring[i][1]+ring[(i+1)%7][1])/2) for i in range(7)]+[(0,0)]
    ambient_row(['WindmillWindcatcher','WindmillVerticalRotor'],0,ambient['windmill'],ambient['windmill_ground_height'],footprint)
    for i,xy in enumerate(ambient['sheep']):
        ambient_row(['Sheep3'],i,xy,ambient['sheep_ground_heights'][i],[(x,z) for x in [-.08,.08] for z in [-.125,.125]],ambient['sheep_yaws'][i])
    for i,xy in enumerate(ambient['flags']):
        ambient_row(['WaystationFlags'],i,xy,ambient['flag_ground_heights'][i],[(.035*math.cos(t),.035*math.sin(t)) for t in np.linspace(0,math.tau,6,endpoint=False)])
    result={'task':'TASK-GROUND-DETAIL-023','ground_sha256':sha(ground),'replace_nodes':sorted({p['name'] for p in primitives}),'landmarks':landmarks,'props':props,'ambient':ambient_adjustments,'ambient_placements_sha256':sha(ambient_source),
            'method':'Same logical anchors, scale and yaw as 022. Ground heights sampled from actual 023 triangles; E/D Hero is seated by its lowest clearance; only authored Transition deforms. Affected props seat their actual GLB lowest vertices to slight contact burial. Ambient anchors use actual base/hoof samples and remain rigid.'}
    (LIB/'placements.json').write_text(json.dumps(clean(result),ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'landmarks':[a['id'] for a in landmarks],'props':len(props),'seating':{a['id']:a['seating'] for a in landmarks if a['seating']}}))
if __name__=='__main__':main()
