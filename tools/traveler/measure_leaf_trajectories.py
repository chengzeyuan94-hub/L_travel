#!/usr/bin/env python3
"""S6b evidence reducer for GPU identity atlas + visible-ID mask frames."""
import argparse, json, math
from pathlib import Path
from collections import defaultdict
import numpy as np
from PIL import Image


def seg_cycles(samples):
    by_slot = defaultdict(list)
    for sample in samples:
        for p in sample['particles']:
            if p['active']:
                by_slot[p['slot']].append((float(sample['time_s']), p))
    cycles = []
    incomplete = 0
    for slot in sorted(by_slot):
        rows = by_slot[slot]
        groups=[]
        for t,p in rows:
            if not groups or p['normalized_age'] < groups[-1][-1][1]['normalized_age'] - 0.20:
                groups.append([(t,p)])
            else:
                groups[-1].append((t,p))
        for group in groups:
            start_age=group[0][1]['normalized_age']; end_age=group[-1][1]['normalized_age']
            complete=start_age <= 0.12 and end_age >= 0.90
            if complete:
                x0=group[0][1]['screen_x_px']; x1=group[-1][1]['screen_x_px']
                y0=group[0][1]['screen_y_px']; y1=group[-1][1]['screen_y_px']
                cycles.append({'slot':slot,'start_time_s':group[0][0],'end_time_s':group[-1][0],
                               'sample_count':len(group),'start_age':start_age,'end_age':end_age,
                               'start_screen_px':[x0,y0],'end_screen_px':[x1,y1],
                               'net_dx_px':abs(x1-x0),'net_dy_px':y1-y0,
                               'down_angle_deg':math.degrees(math.atan2(abs(y1-y0),abs(x1-x0))) if abs(x1-x0)>1e-6 else 90.0,
                               'camera_depth_start_u':group[0][1]['camera_depth_u'],
                               'camera_depth_end_u':group[-1][1]['camera_depth_u'],
                               'samples':group})
            else:
                incomplete += 1
    return cycles, incomplete


def id_from_mask(rgb):
    # The diagnostic shader emits [7*(id+1),192,255] with coverage/MSAA/DOF.
    r=rgb[:,:,0].astype(float); g=rgb[:,:,1].astype(float); b=rgb[:,:,2].astype(float)
    valid=(b>=48)&(g>=32)&(r>=2)
    slot=np.rint((r/(np.maximum(g,1e-3))*192.0/7.0)-1.0).astype(np.int32)
    valid &= (slot>=0)&(slot<64)
    # Reject blurred scene remnants by requiring the expected color ratio within a soft tolerance.
    expected=(slot+1)*7.0/192.0
    valid &= np.abs(r/np.maximum(g,1e-3)-expected) <= 0.16
    slot[~valid]=-1
    return slot,valid


def component_stats(mask):
    ys,xs=np.nonzero(mask)
    remaining=set(zip(xs.tolist(),ys.tolist()));out=[]
    while remaining:
        first=remaining.pop();stack=[first];pts=[]
        while stack:
            x,y=stack.pop();pts.append((x,y))
            for dx,dy in ((-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)):
                q=(x+dx,y+dy)
                if q in remaining:remaining.remove(q);stack.append(q)
        xx=[p[0] for p in pts]; yy=[p[1] for p in pts]
        out.append({'bbox_xywh':[min(xx),min(yy),max(xx)-min(xx)+1,max(yy)-min(yy)+1], 'area_px':len(pts)})
    return out


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--trajectories',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);args=ap.parse_args()
    data=json.loads(args.trajectories.read_text());samples=data['samples'];cycles,incomplete=seg_cycles(samples)
    masks=[];heights=[];visible_by_slot=defaultdict(list)
    for sample in samples:
        path=args.trajectories.parent/Path(sample['image']).name
        if not path.exists():
            # Godot path may be res://; manifest path is enough to resolve basename in output dir.
            path=args.trajectories.parent/f"f{round(float(sample['time_s'])*10):04d}.png"
        if not path.exists(): continue
        im=np.asarray(Image.open(path).convert('RGB'));slot,valid=id_from_mask(im)
        frame_visible=[]
        for s in np.unique(slot[valid]):
            s=int(s)
            ys,xs=np.nonzero(slot==s)
            if len(xs)==0:continue
            stats=component_stats(slot==s);kept=[x for x in stats if x['area_px']>=3]
            if kept:
                h=max(x['bbox_xywh'][3] for x in kept); heights.append(h)
                frame_visible.append(s)
                visible_by_slot[s].append({'time_s':float(sample['time_s']),'centroid_px':[float(xs.mean()),float(ys.mean())], 'area_px':int(len(xs)), 'components':kept, 'height_px':h})
        masks.append({'time_s':float(sample['time_s']),'visible_slots':frame_visible,'valid_mask_pixels':int(valid.sum())})
    for c in cycles:
        rows=visible_by_slot.get(c['slot'],[])
        inside=[r for r in rows if c['start_time_s']-.101<=r['time_s']<=c['end_time_s']+.101]
        if inside:
            c['visible_start_time_s']=inside[0]['time_s'];c['visible_end_time_s']=inside[-1]['time_s'];c['visible_duration_s']=inside[-1]['time_s']-inside[0]['time_s']
            c['visible_start_screen_px']=inside[0]['centroid_px'];c['visible_end_screen_px']=inside[-1]['centroid_px'];c['visible_net_dx_px']=abs(inside[-1]['centroid_px'][0]-inside[0]['centroid_px'][0])
            c['visible_observations']=len(inside)
        else:
            c['visible_start_time_s']=None;c['visible_end_time_s']=None;c['visible_duration_s']=0.0;c['visible_net_dx_px']=None;c['visible_observations']=0
    dx=np.asarray([c['net_dx_px'] for c in cycles],dtype=float);ratios=dx/1920.0
    angles=np.asarray([c['down_angle_deg'] for c in cycles],dtype=float)
    vdx=np.asarray([c['visible_net_dx_px'] for c in cycles if c['visible_net_dx_px'] is not None],dtype=float)
    params=data['original_leaf_evidence']['parameters']
    result={'schema':'traveler.s6b.leaf-trajectory-measurement.v1','source':str(args.trajectories.resolve()),'image_size':[1920,1080],
      'identity_method':'GPU draw atlas: actual INSTANCE_ID, MODEL_MATRIX origin projected by VIEW/PROJECTION, INSTANCE_CUSTOM age/lifetime; 24-bit RGB field readback. Separate depth-tested ID silhouette frames retain original DOF.',
      'sample_count':len(samples),'sample_interval_s':data['sample_interval_s'],'simulation_step_s':data['simulation_step_s'],
      'cycles':cycles,'complete_lifetime_count':len(cycles),'incomplete_segment_count':incomplete,
      'full_lifetime_net_horizontal_px':{'min':float(dx.min()) if len(dx) else None,'p50':float(np.median(dx)) if len(dx) else None,'max':float(dx.max()) if len(dx) else None,'ratio_to_1920':{'min':float(ratios.min()) if len(dx) else None,'p50':float(np.median(ratios)) if len(dx) else None,'max':float(ratios.max()) if len(dx) else None},'target':0.60,'pass_min':bool(len(dx) and ratios.min()>=0.60)},
      'full_lifetime_down_angle_deg':{'min':float(angles.min()) if len(angles) else None,'p50':float(np.median(angles)) if len(angles) else None,'max':float(angles.max()) if len(angles) else None,'target_min':33.0,'pass_min':bool(len(angles) and angles.min()>=33.0)},
      'visible_net_horizontal_px':{'min':float(vdx.min()) if len(vdx) else None,'p50':float(np.median(vdx)) if len(vdx) else None,'max':float(vdx.max()) if len(vdx) else None,'ratio_to_1920':{'min':float((vdx/1920).min()) if len(vdx) else None,'p50':float(np.median(vdx/1920)) if len(vdx) else None,'max':float((vdx/1920).max()) if len(vdx) else None},'note':'Visibility is depth/clear-band/viewport limited; this is reported separately from full lifetime as requested.'},
      'visible_duration_s':{'min':float(min((c['visible_duration_s'] for c in cycles),default=0)),'p50':float(np.median([c['visible_duration_s'] for c in cycles])) if cycles else None,'max':float(max((c['visible_duration_s'] for c in cycles),default=0))},
      'pixel_height':{'component_count':len(heights),'median_px':float(np.median(heights)) if heights else None,'min_px':int(min(heights)) if heights else None,'max_px':int(max(heights)) if heights else None,'target_inclusive':params['mesh']['pixel_height_median_target'],'pass':bool(heights and params['mesh']['pixel_height_median_target'][0]<=np.median(heights)<=params['mesh']['pixel_height_median_target'][1]),'method':'Per-frame ID mask components; components under 3 pixels omitted from height statistics but frame data retains only kept components.'},
      'visible_masks':masks,'depth_contract':{'clear_clip_u':params['render']['clear_depth_clip_u'],'emission_depth_range_u':data.get('emission_depth_range_u'),'per_particle_gpu_depth_available':True},
      'limitations':['Full lifetime endpoint travel is measured from GPU state even when outside viewport; visible span is separately depth/occlusion/edge limited.','Identity slot cycles are segmented on active state and age reset; initial preprocessed fragments without age<=0.12 or unfinished tails are excluded from complete distribution.','ID silhouette is a diagnostic pass with black occluders and original DOF; it is not the beauty render.']}
    args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'output':str(args.out.resolve()),'complete_lifetime_count':len(cycles),'full_ratio':result['full_lifetime_net_horizontal_px'],'visible_ratio':result['visible_net_horizontal_px'],'height':result['pixel_height']},indent=2))
if __name__=='__main__':main()
