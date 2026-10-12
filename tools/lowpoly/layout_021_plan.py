#!/usr/bin/env python3
"""Place immutable 018/019/020 assets against actual terrain and route data.

This produces a layout study; it never changes production or library assets.
The geographic candidate list is curated separately. Numeric checks below are
conservative footprint checks, not proof of screen visibility or performance.
"""
from pathlib import Path
import argparse,hashlib,json,math,sys
from collections import Counter
import numpy as np
sys.dont_write_bytecode=True
from visual_006_audit import GLB,normalize
from density_017_audit import RaySurface
from detail_012_audit import direction,pose,Routes,point_arc_distance

ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/map-layout-021'
EV=Path('/Users/chengzeyuan/SilkRoadEvidence/map-layout-021')
DATA=ROOT/'data/rulesets/lshu_configurable_v1'
LIBRARIES={'terrain':'terrain-library-018','city':'city-library-019','landmark':'landmark-library-020'}
CITY_SCALE=.82
def read(p):return json.loads(Path(p).read_text())
def write(p,x):Path(p).write_text(json.dumps(x,ensure_ascii=False,indent=2)+'\n')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def clean(x):
    if isinstance(x,np.ndarray):return x.tolist()
    if isinstance(x,np.generic):return x.item()
    if isinstance(x,dict):return {k:clean(v) for k,v in x.items()}
    if isinstance(x,(list,tuple)):return [clean(v) for v in x]
    return x
def xy_at(v):
    v=normalize(v);return np.array([2048+math.atan2(v[0],v[2])*6144/math.tau,681.5-math.asin(v[1])*2400/math.pi])
def ground_basis(xy,yaw=0):
    up=direction(xy);lon=(xy[0]-2048)*math.tau/6144
    east=np.array([math.cos(lon),0,-math.sin(lon)]);b=np.column_stack((east,up,np.cross(east,up)))
    a=math.radians(yaw);rot=np.array([[math.cos(a),0,math.sin(a)],[0,1,0],[-math.sin(a),0,math.cos(a)]])
    return b@rot
def arc(a,b):return 11*math.acos(float(np.clip(np.dot(direction(a),direction(b)),-1,1)))

def final_geography_metadata(result, candidates):
    """Keep proposal intent separate from the final display-space measurements."""
    originals={a.get('asset_id',a.get('id')):a for a in candidates}
    for a in result['landmarks']:
        if 'source_proposal_intent' not in a:
            a['source_proposal_intent']={k:a.pop(k) for k in ('direction','display_distance_logical','display_distance_band','status') if k in a}
        if a.get('city_visual_logical') is not None:
            delta=np.array(a['logical'])-np.array(a['city_visual_logical'])
            bearing=math.degrees(math.atan2(delta[0],-delta[1]))%360
            a['display_distance_logical']=round(float(np.linalg.norm(delta)),3)
            a['display_bearing_degrees']=round(bearing,3)
            a['display_direction']=['N','NE','E','SE','S','SW','W','NW'][int((bearing+22.5)//45)%8]
        else:
            a['display_distance_logical']=None
            a['display_bearing_degrees']=None
            a['display_direction']='independent-region'
        a['status']='coast-reservation' if a.get('requires_land_extension') else 'layout-placement-pending-terrain-blend'
        if 'geographic_adjustment_px' in a:
            a['solver_preferred_adjustment_logical']=a.pop('geographic_adjustment_px')
        original=originals[a['asset_id']]['preferred_logical']
        a['original_candidate_logical']=original
        a['original_candidate_adjustment_logical']=round(float(np.linalg.norm(np.array(a['logical'])-np.array(original))),3)
        if a['asset_id']=='lake_albano':
            a['source_proposal_intent'].setdefault('orientation_intent',a['orientation_intent'])
            a['orientation_intent']='低盆沿朝西北罗马；与输水渠同属东南景组，近远次序为地图压缩试排。'
    return result

class Planner:
    def __init__(self):
        self.nodes=read(DATA/'board_nodes.json')['items'];self.edges=read(DATA/'board_edges.json')['items']
        self.cities={n['id']:np.array(n['map_position'])+np.array([0,-85]) for n in self.nodes if n['node_type']=='CITY'}
        self.catalogs={k:{a['id']:a for a in read(ROOT/'docs/design'/d/'catalog.json')['assets']} for k,d in LIBRARIES.items()}
        self.surface=RaySurface(GLB(ROOT/'assets/game/lowpoly/planet/terrain.glb').primitives())
        # Preserve the visual corridor between city and its separate route anchors.
        paths=list(self.edges)
        presentation={c['city_id']:c for c in read(DATA/'presentation/world_map_v1.json')['cities']}
        for n in self.nodes:
            if n['node_type']!='CITY':continue
            positions=[self.cities[n['id']].tolist(),n['map_position']]
            for key in ('land_route_attach_anchor_px','sea_route_attach_anchor_px'):
                shown=presentation.get({'rome':'ancient_rome','panti':'pantuo'}.get(n['id'],n['id']),{})
                if shown.get(key):positions.append(shown[key])
            paths.extend({'movement_polyline':[positions[0],p]} for p in positions[1:])
        self.routes=Routes(paths)
        self.city_radii={k:float(np.linalg.norm(np.array(self.catalogs['city'][k]['bounds']['size'])[[0,2]])*.5*CITY_SCALE) for k in self.cities}
        self.placed=[]
    def radius(self,xy):
        hit=self.surface.sample(direction(xy));return (hit['radius'],True) if hit else (11.0,False)
    def sample_patch(self,xy,radius):
        b=ground_basis(xy);u=direction(xy);rs=[];land=[]
        for a in [None,*np.linspace(0,math.tau,8,endpoint=False)]:
            v=u*11 if a is None else u*11+b@np.array([math.cos(a)*radius,0,math.sin(a)*radius])
            hit=self.surface.sample(v);rs.append(hit['radius'] if hit else 11.0);land.append(bool(hit))
        return {'land_fraction':sum(land)/len(land),'min_height':min(rs)-11,'max_height':max(rs)-11,'height_range':max(rs)-min(rs),'center_height':rs[0]-11}
    def clearance(self,xy,r):
        city=min(arc(xy,p)-self.city_radii[c]-r for c,p in self.cities.items())
        route=float(np.min(point_arc_distance(direction(xy),self.routes.arcs[:,0],self.routes.arcs[:,1])))*11-r
        other=min((arc(xy,p['logical'])-p['footprint_radius']-r for p in self.placed),default=100)
        return city,route,other
    def fit(self,c):
        aid=c['asset_id'];cat=self.catalogs[c.get('library','landmark')][aid]
        size=np.array(cat['bounds']['size']);pref=np.array(c['preferred_logical'],float)
        width=float(c['target_width']);base_width=max(size[0],size[2]);yaw=c.get('yaw_deg',0)
        domain=c.get('surface_type','land');host=self.cities.get(c.get('city_id',''))
        options=[]
        # Near proposals are checked first; geography deviations remain recorded.
        for factor in [1.,.90,.80,.70,.60]:
            scale=width*factor/base_width;r=float(np.linalg.norm(size[[0,2]])*.5*scale)
            for distance in [0,40,80,120,160,210,260]:
                for angle in ([0] if distance==0 else np.linspace(0,math.tau,20,endpoint=False)):
                    xy=pref+distance*np.array([math.cos(angle),math.sin(angle)])
                    if c.get('layer')=='background':
                        if not (-450<=xy[1]<=1780):continue
                    elif not (-240<=xy[1]<=1400 and 70<=xy[0]<=4330):continue
                    if c.get('allowed_box'):
                        xmin,xmax,ymin,ymax=c['allowed_box']
                        if not (xmin<=xy[0]<=xmax and ymin<=xy[1]<=ymax):continue
                    if host is not None:
                        desired=pref-host;actual=xy-host
                        # Keep within a 60-degree geographic sector from the city.
                        cos=float(np.dot(desired,actual)/max(np.linalg.norm(desired)*np.linalg.norm(actual),1e-9))
                        if cos<.5:continue
                    city,route,other=self.clearance(xy,r)
                    if min(city-.08,route-.22,other-.12)<0:continue
                    patch=self.sample_patch(xy,r*.82)
                    if domain=='land' and patch['land_fraction']<.88:continue
                    if domain=='water' and patch['land_fraction']>.34:continue
                    if domain=='mixed' and not (.1<=patch['land_fraction']<=.9):continue
                    if domain!='water' and patch['height_range']>.45:continue
                    score=distance+180*(1-factor)+patch['height_range']*80
                    if domain=='mixed':score+=abs(patch['land_fraction']-.5)*70
                    options.append((score,xy,scale,r,patch,city,route,other))
            if options:break
        if not options:
            return None
        _,xy,scale,r,patch,city,route,other=min(options,key=lambda o:o[0])
        row={**c,'id':c.get('id',aid),'logical':xy.tolist(),'scale':scale,'yaw_deg':yaw,'footprint_radius':r,
             'actual_width':base_width*scale,'actual_height':size[1]*scale,'ground_height':patch['max_height']-.018,
             'asset_sha256':cat['sha256'],'geographic_adjustment_px':float(np.linalg.norm(xy-pref)),
             'patch':patch,'clearance':{'city_world':city,'route_world_conservative':route,'other_world':other}}
        if c.get('requires_land_extension'):
            row['ground_height']=max(row['ground_height'],.065)
        # Base-only conformation grid: transformed local XZ sample -> actual surface.
        # Heights are in the rigid object's LOCAL Y coordinate before applying scale.
        lo=np.array(cat['bounds']['min']);hi=np.array(cat['bounds']['max']);n=13
        b=ground_basis(xy,yaw);origin=direction(xy)*(11+row['ground_height']);heights=[]
        for z in np.linspace(lo[2],hi[2],n):
            for x in np.linspace(lo[0],hi[0],n):
                v=origin+b@np.array([x*scale,0,z*scale]);hit=self.surface.sample(v)
                radius_at_point=hit['radius'] if hit else 11.0
                if c.get('requires_land_extension'):radius_at_point=max(radius_at_point,11.08)
                target=normalize(v)*(radius_at_point-.018)
                heights.append(float(np.dot(target-origin,b[:,1])/scale))
        row['conform_grid']={'min':[lo[0],lo[2]],'step':[(hi[0]-lo[0])/(n-1),(hi[2]-lo[2])/(n-1)],'size':[n,n],'heights':heights,'blend_height':min(.26,float(size[1])*.22)}
        self.placed.append(row);return row

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--candidates',type=Path,default=EV/'geography-candidates.json');parser.add_argument('--refresh-metadata',action='store_true');args=parser.parse_args()
    data=read(args.candidates);raw=data.get('assets',data.get('candidates',[]))
    if args.refresh_metadata:
        path=LIB/'placements.json';result=read(path)
        assert result['geography_candidates_sha256']==sha(args.candidates)
        def geometry(r):
            fields=('id','asset_id','library','logical','scale','yaw_deg','ground_height','footprint_radius','conform_grid','requires_land_extension')
            return {'city_scale':r['city_scale'],'landmarks':[{k:a.get(k) for k in fields} for a in r['landmarks']], 'props':r['props'],'views':r['views']}
        before=geometry(result);before_sha=sha(path)
        final_geography_metadata(result,raw);result['generator_sha256']=sha(Path(__file__))
        assert geometry(result)==before,'metadata refresh changed render geometry'
        write(path,clean(result))
        write(LIB/'validation/metadata-refresh.json',{'before_sha256':before_sha,'after_sha256':sha(path),'render_geometry_unchanged':True,'geometry_sha256':hashlib.sha256(json.dumps(before,sort_keys=True).encode()).hexdigest(),'note':'Proposal direction/distance retained under source_proposal_intent; final display coordinates measured separately. No position, geometry, prop, camera or scale change.'})
        print('021 geographic metadata refreshed; render geometry unchanged');return
    p=Planner()
    assert len(raw)==33,len(raw)
    candidates=[]
    for c in raw:
        c=dict(c);c['asset_id']=c.get('asset_id',c.get('id'));c.setdefault('library','landmark');candidates.append(c)
        if c['asset_id'] in ('yamuna_floodplain','tigris_meander','nile_floodplain','tonle_sap_floodforest'):
            c['surface_type']='land'
            c['layout_note']='内陆河湖以模型内水道表达，落在陆地；不强制占用既有海岸。'
    boxes={'huashan_peaks':[2960,3190,330,480],'namsan_hills':[3370,3610,350,525],
        'roman_aqueduct':[420,650,205,380],'lake_albano':[510,710,280,470],
        'mount_fuji':[3890,4290,70,310],'wakakusa_hill':[3850,4100,340,520],
        'phnom_kulen_waterfall':[3170,3400,490,690],'sigiriya':[2180,2390,1030,1150],
        'horton_plains':[2040,2250,1080,1250],'tawila_cisterns':[1360,1530,950,1080]}
    for c in candidates:
        if c['asset_id'] in boxes:c['allowed_box']=boxes[c['asset_id']]
        overrides={'sigiriya':([2300,1080],1.2),'horton_plains':([2120,1130],1.2),
                   'roman_aqueduct':([500,285],1.08),'lake_albano':([625,380],1.1),
                   'mount_fuji':([4220,220],2.1),'phnom_kulen_waterfall':([3290,610],1.25)}
        if c['asset_id'] in overrides:c['preferred_logical'],c['target_width']=overrides[c['asset_id']]
    # Tight coastal sectors get priority. Large free inland mountains follow.
    candidates.sort(key=lambda c:(0 if c['asset_id'] in ('huashan_peaks','namsan_hills') else 1,
        0 if c.get('surface_type') in ('mixed','water') else 1,0 if c.get('city_id') in ('rome','constantinople','quanzhou','jeddah','heijokyo') else 1))
    landmarks=[];unresolved=[]
    for c in candidates:
        row=p.fit(c)
        if row:landmarks.append(row);print('PLACED',c['asset_id'],[round(x) for x in row['logical']],round(row['actual_width'],2),flush=True)
        else:unresolved.append(c);print('UNRESOLVED',c['asset_id'],flush=True)
    # Explicit design reservations: geographic placement takes precedence over
    # the old procedural coast. The preview shows the asset's local land apron;
    # continuous coastline surgery is a clearly marked subsequent integration.
    for c in list(unresolved):
        if c['asset_id'] not in ('wakakusa_hill','mount_fuji','horton_plains','tawila_cisterns'):continue
        reserved={**c,'surface_type':'land-extension','requires_land_extension':True,
            'layout_note':'地理优先的岸形调整预留：样板仅显示景观自身落脚面；接回连续陆岸须在地图集成时重塑并复核航道。'}
        row=p.fit(reserved)
        if row:landmarks.append(row);unresolved.remove(c);print('COAST_RESERVATION',c['asset_id'],row['logical'],flush=True)
    # Reuse proven travel-area distribution, with stronger individual 018 forms.
    old=read(ROOT/'scripts/ui/ambient/corridor_017_placements.json');props=[];used=Counter()
    choices={'sandstone_cluster':['rock_strata_a','rock_weathered_b','rock_ledge_c'],
             'broad_bushes':['shrub_oval_a','shrub_spreading_b'],
             'folded_grass':['grass_fan_a','grass_rosette_b'],
             'short_palm':['palm_curved_a','palm_leaning_b']}
    for group in old['groups']:
        for i,a in enumerate(group['instances']):
            pool=choices[group['id']];aid=pool[i%len(pool)];cat=p.catalogs['terrain'][aid];size=np.array(cat['bounds']['size'])
            width=.34 if group['id']=='sandstone_cluster' else .28 if group['id']=='short_palm' else .22
            scale=width/max(size[0],size[2]);r=float(np.linalg.norm(size[[0,2]])*.5*scale);xy=a['logical']
            if min(p.clearance(xy,r))<.08:continue
            h,land=p.radius(xy)
            if not land:continue
            row={'id':'detail_'+a['id'],'asset_id':aid,'library':'terrain','logical':xy,'scale':scale,'yaw_deg':(i*137.508)%360,'ground_height':h-11-.008,'footprint_radius':r,'asset_sha256':cat['sha256'],'layer':'foreground','biome':a['biome']}
            props.append(row);p.placed.append(row);used[aid]+=1
    # Nine broad landform silhouettes reserve non-city background zones.
    backgrounds=[('mountain_ridge',[-325,65],1.7),('mountain_massif',[4730,245],1.7),
        ('mountain_mesa',[820,1200],1.65),('snow_alpine',[1720,-365],1.8),
        ('snow_glacier',[4250,-375],1.65),('snow_twin',[3300,1730],1.7),
        ('hill_rolling',[-640,1200],1.8),('hill_crescent',[-865,990],1.65),('hill_terraced',[4900,1120],1.6)]
    for aid,xy,width in backgrounds:
        row=p.fit({'asset_id':aid,'id':'background_'+aid,'library':'terrain','layer':'background',
                   'preferred_logical':xy,'target_width':width,'surface_type':'land','yaw_deg':25})
        if row:props.append(row);used[aid]+=1
    # Small, uneven groves support the principal routes; no forest on desert nodes.
    groves=[('tree_spruce',[1970,70]),('tree_spruce',[2520,40]),('tree_windswept',[3030,130]),
            ('tree_windswept',[3300,140]),('tree_oak',[2700,760]),('tree_oak',[3470,720]),
            ('tree_oak',[520,40]),('tree_windswept',[850,50]),('tree_spruce',[2250,20])]
    for group,(aid,center) in enumerate(groves):
        cat=p.catalogs['terrain'][aid];size=np.array(cat['bounds']['size'])
        for i in range(64):
            a=i*2.39996;radius=25+13*math.sqrt(i);xy=(np.array(center)+[math.cos(a)*radius,math.sin(a)*radius]).tolist()
            scale=(.35+(i%3)*.045)/max(size[0],size[2]);r=float(np.linalg.norm(size[[0,2]])*.5*scale)
            if min(p.clearance(xy,r))<.12:continue
            h,land=p.radius(xy)
            if not land:continue
            row={'id':f'grove_{group}_{i}','asset_id':aid,'library':'terrain','logical':xy,'scale':scale,'yaw_deg':i*137.508%360,
                 'ground_height':h-11-.014,'footprint_radius':r,'asset_sha256':cat['sha256'],'layer':'grove'}
            props.append(row);p.placed.append(row);used[aid]+=1
    # Irregular low belts bridge each city into its biome without hiding façades.
    for ci,(cid,center) in enumerate(p.cities.items()):
        arid=cid in ('yumenguan','panti','baghdad','cairo','jeddah','aden','delhi')
        pool=['rock_weathered_b','grass_rosette_b','rock_strata_a'] if arid else ['shrub_oval_a','grass_fan_a','shrub_spreading_b']
        for i in range(32):
            a=i*2.39996+ci*.2;radius=115+(i%6)*15;xy=(center+[math.cos(a)*radius,math.sin(a)*radius]).tolist()
            aid=pool[i%len(pool)];cat=p.catalogs['terrain'][aid];size=np.array(cat['bounds']['size'])
            scale=(.28+(i%3)*.035)/max(size[0],size[2]);r=float(np.linalg.norm(size[[0,2]])*.5*scale)
            if min(p.clearance(xy,r))<.10:continue
            h,land=p.radius(xy)
            if not land:continue
            row={'id':f'citybelt_{cid}_{i}','asset_id':aid,'library':'terrain','logical':xy,'scale':scale,'yaw_deg':i*117%360,
                 'ground_height':h-11-.01,'footprint_radius':r,'asset_sha256':cat['sha256'],'layer':'foreground','city_id':cid}
            props.append(row);p.placed.append(row);used[aid]+=1
    # Clouds remain offshore and below the height of the principal mountains.
    for i,(aid,xy) in enumerate([('cloud_drifter',[3300,1160]),('cloud_bank',[1670,1330]),('cloud_cumulus',[3840,960]),
                               ('cloud_bank',[780,1400]),('cloud_drifter',[-740,680]),('cloud_cumulus',[4440,800])]):
        cat=p.catalogs['terrain'][aid];size=np.array(cat['bounds']['size']);scale=1.05/max(size[0],size[2])
        row={'id':f'cloud_{i}','asset_id':aid,'library':'terrain','logical':xy,'scale':scale,'yaw_deg':25+i*30,
             'ground_height':.85,'footprint_radius':.7,'asset_sha256':cat['sha256'],'layer':'cloud'}
        props.append(row);used[aid]+=1
    views=[{'id':'overview','title':'星球总览','logical':[2048,544],'zoom':1.0},
           {'id':'west','title':'地中海—红海','logical':[880,490],'zoom':1.5},
           {'id':'central','title':'丝路荒漠—喜马拉雅','logical':[2210,490],'zoom':1.55},
           {'id':'east','title':'东亚沿海—日本','logical':[3350,470],'zoom':1.55},
           {'id':'south','title':'印度洋—东南亚','logical':[2490,960],'zoom':1.6},
           {'id':'rear','title':'背面与极地留白','logical':[-670,710],'zoom':1.0}]
    for cid,xy in p.cities.items():views.append({'id':'city_'+cid,'title':p.catalogs['city'][cid]['name'],'logical':xy.tolist(),'zoom':2.6,'city_id':cid})
    LIB.mkdir(exist_ok=True);(LIB/'validation').mkdir(exist_ok=True);(LIB/'previews').mkdir(exist_ok=True);(LIB/'.gdignore').touch()
    result={'task':'TASK-MAP-LAYOUT-021','status':'layout-study','city_scale':CITY_SCALE,'geography_candidates_sha256':sha(args.candidates),'generator_sha256':sha(Path(__file__)),'terrain_sha256':sha(ROOT/'assets/game/lowpoly/planet/terrain.glb'),'landmarks':landmarks,'props':props,'unresolved':unresolved,'views':views,'note':'Curated geography first; sector-constrained conservative footprint fitting. Screen occlusion and contacts require actual Godot review. No production writes.'}
    final_geography_metadata(result,raw)
    write(LIB/'placements.json',clean(result));write(LIB/'validation/placement-diagnostics.json',clean({'landmarks':len(landmarks),'unresolved':[c['asset_id'] for c in unresolved],'detail_instances':len(props),'used_018_variants':dict(used)}))
    print('LAYOUT',len(landmarks),'landmarks',len(props),'props',len(unresolved),'unresolved')

if __name__=='__main__':main()
