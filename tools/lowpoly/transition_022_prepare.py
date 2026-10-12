#!/usr/bin/env python3
"""Place authored footing variants at the unchanged 021 anchors and scale."""
from pathlib import Path
import hashlib,json,math,sys
import numpy as np
sys.dont_write_bytecode=True
from layout_021_plan import Planner,ground_basis,direction,normalize,arc,clean
from visual_006_audit import GLB
from density_017_audit import LAND
ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/terrain-transition-022'
TARGETS=('everest','taklamakan_dunes','tigris_meander')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    old_path=ROOT/'docs/design/map-layout-021/placements.json'
    old=json.loads(old_path.read_text());planner=Planner();byid={a['id']:a for a in old['landmarks']}
    radii={a['id']:a['footprint_radius'] for a in old['landmarks']};bounds={};hero_points={}
    for aid in TARGETS:
        mesh=GLB(LIB/f'exports/{aid}.glb');primitives=list(mesh.primitives());v=np.concatenate([p['positions'] for p in primitives]);lo=v.min(axis=0);hi=v.max(axis=0)
        hero_points[aid]=np.unique(np.concatenate([p['positions'] for p in primitives if '_Hero_' in p['name']]),axis=0)
        assert np.isfinite(v).all() and (hi>lo).all(),aid
        bounds[aid]=(lo,hi);radii[aid]=float(np.linalg.norm(np.maximum(np.abs(lo[[0,2]]),np.abs(hi[[0,2]])))*byid[aid]['scale'])
    land=list(GLB(ROOT/'assets/game/lowpoly/planet/terrain.glb').primitives())
    land_colors=np.concatenate([p['color'][p['faces']][:,:,:3] for p in land if p['name']==LAND])
    assert len(land_colors)==len(planner.surface.triangles)
    rows=[]
    for aid in TARGETS:
        a=byid[aid];lo,hi=bounds[aid];n=25;scale=a['scale'];b=ground_basis(a['logical'],a['yaw_deg']);up=direction(a['logical']);old_origin=up*(11+a['ground_height']);height=[];colors=[]
        def hero_clearance(origin):
            values=[]
            for vertex in hero_points[aid]:
                world=origin+b@(vertex*scale);hit=planner.surface.sample(world)
                values.append(float(np.linalg.norm(world)-(hit['radius'] if hit else 11)))
            return min(values)
        old_margin=hero_clearance(old_origin)
        lowering=max(0.,min(.16,old_margin-.014)) if aid!='tigris_meander' else 0.
        ground_height=a['ground_height']-lowering;origin=up*(11+ground_height)
        new_margin=hero_clearance(origin)
        assert lowering==0 or new_margin>=.010,(aid,new_margin)
        for z in np.linspace(lo[2],hi[2],n):
            for x in np.linspace(lo[0],hi[0],n):
                point=origin+b@np.array([x*scale,0,z*scale]);hit=planner.surface.sample(point)
                target=normalize(point)*((hit['radius'] if hit else 11)-.018)
                height.append(float(np.dot(target-origin,b[:,1])/scale))
                colors.append((np.asarray(hit['barycentric'])@land_colors[hit['face']]).tolist() if hit else [.66,.59,.39])
        radius=radii[aid];city,route,_=planner.clearance(a['logical'],radius)
        other=min(arc(a['logical'],p['logical'])-radius-radii[p['id']] for p in old['landmarks'] if p['id']!=aid)
        prop=min(arc(a['logical'],p['logical'])-radius-p['footprint_radius'] for p in old['props'] if p.get('layer')!='cloud')
        rows.append({'id':aid,'logical':a['logical'],'scale':scale,'yaw_deg':a['yaw_deg'],'ground_height':ground_height,'previous_ground_height':a['ground_height'],
            'seating':{'lowering_world':lowering,'minimum_hero_clearance_before':old_margin,'minimum_hero_clearance_after':new_margin,'note':'All authored Hero vertices sampled against the actual continent, including a second check after lowering. Whole Hero retains at least .010 world clearance after lowering. River height unchanged.'},
            'sha256':sha(LIB/f'exports/{aid}.glb'),'bounds':{'min':lo.tolist(),'max':hi.tolist()},'footprint_radius':radius,'previous_footprint_radius':a['footprint_radius'],
            'conservative_clearance_world':{'city':city,'route':route,'other_landmark':other,'prop':prop},
            'conform_grid':{'min':[float(lo[0]),float(lo[2])],'step':[float(hi[0]-lo[0])/(n-1),float(hi[2]-lo[2])/(n-1)],'size':[n,n],'heights':height,'colors_srgb':colors,'blend_height':min(.26,float(hi[1]-lo[1])*.22)}})
    result={'task':'TASK-TERRAIN-TRANSITION-022','source_plan_sha256':sha(old_path),'method':'Blender variants retain original logical anchor, scale and orientation. Everest/dunes seating height calibrated against all Hero vertices; only authored footing weights adapt to sphere. No continent writes. Circle clearances are conservative review prompts, not full mesh intersection tests.','variants':rows}
    (LIB/'variant-placements.json').write_text(json.dumps(clean(result),ensure_ascii=False,indent=2)+'\n')
    print(json.dumps([{'id':r['id'],'clearance':r['conservative_clearance_world']} for r in rows]))
if __name__=='__main__':main()
