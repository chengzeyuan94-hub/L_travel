#!/usr/bin/env python3
"""Recompute the CPU-skinned mesh for every sampled Godot pose; requires numpy.

Input comes from audit_action2_rig.gd. This checks rendered mesh bounds and
triangle edges, including all 12 directed clip transitions at 0 and .2s blend.
"""
from __future__ import annotations
import argparse, hashlib, json, math
from pathlib import Path
import numpy as np

p=argparse.ArgumentParser();p.add_argument('--input',type=Path,required=True);p.add_argument('--out',type=Path,required=True);args=p.parse_args()
data=json.loads(args.input.read_text())
position=np.asarray(data['vertex_positions'],dtype=np.float64)
count=len(position)
weights=np.asarray(data['skin_weights'],dtype=np.float64).reshape(count,-1)
bones=np.asarray(data['skin_bones'],dtype=np.int64).reshape(count,-1)
triangles=np.asarray(data['indices'],dtype=np.int64).reshape(-1,3)
edges=np.unique(np.sort(np.concatenate([triangles[:,[0,1]],triangles[:,[1,2]],triangles[:,[2,0]]]),axis=1),axis=0)
homogeneous=np.c_[position,np.ones(count)]
rest_height=float(np.ptp(position,axis=0)[1])
rest_edges=np.linalg.norm(position[edges[:,0]]-position[edges[:,1]],axis=1)
finite_weights=bool(np.isfinite(weights).all() and (weights>=0).all())
valid_indices=bool((bones>=0).all() and (bones<len(data['bind_mapping'])).all())
rows=[];groups={};single_max_edge=0.;mixed_max_edge=0.;single_max_diag=0.;mixed_max_diag=0.
for sample in data['samples']:
    matrices=np.asarray(sample['skin_matrices'],dtype=np.float64).reshape(-1,3,4)
    # Godot's named Skin binds were mapped to Skeleton3D indices in the sampler.
    skinned=np.einsum('vwij,vj,vw->vi',matrices[bones],homogeneous,weights)
    low=skinned.min(axis=0);high=skinned.max(axis=0);size=high-low
    lengths=np.linalg.norm(skinned[edges[:,0]]-skinned[edges[:,1]],axis=1)
    longest=float(lengths.max());diag=float(np.linalg.norm(size));finite=bool(np.isfinite(skinned).all())
    label=sample['kind']+':'+sample['clip'];group=groups.setdefault(label,{'samples':0,'all_vertices_finite':True,'size_min':[float('inf')]*3,'size_max':[0.]*3,'max_edge_u':0.,'max_aabb_diagonal_u':0.})
    group['samples']+=1;group['all_vertices_finite'] &= finite
    group['size_min']=np.minimum(group['size_min'],size).tolist();group['size_max']=np.maximum(group['size_max'],size).tolist()
    group['max_edge_u']=max(group['max_edge_u'],longest);group['max_aabb_diagonal_u']=max(group['max_aabb_diagonal_u'],diag)
    if sample['kind']=='clip':single_max_edge=max(single_max_edge,longest);single_max_diag=max(single_max_diag,diag)
    else:mixed_max_edge=max(mixed_max_edge,longest);mixed_max_diag=max(mixed_max_diag,diag)
    rows.append({'clip':sample['clip'],'time_s':sample['time_s'],'kind':sample['kind'],'aabb_min':low.tolist(),'aabb_max':high.tolist(),'max_triangle_edge_u':longest,'all_vertices_finite':finite})
feet=[]
walk=[s for s in data['samples'] if s['kind']=='clip' and s['clip']=='walk']
times=np.asarray([s['time_s'] for s in walk]);foot_speeds={}
for side in ('left','right'):
    xyz=np.asarray([s['feet'][side] for s in walk]);velocity=np.gradient(xyz[:,2],times)
    contact=(xyz[:,1]<xyz[:,1].min()+.008)&(velocity<0)
    values=-velocity[contact];feet.extend(values.tolist());foot_speeds[side]=float(np.median(values))
turn=[s for s in data['samples'] if s['kind']=='clip' and s['clip']=='turn_180']
root_yaw=np.unwrap([s['hips_yaw_rad'] for s in turn])
# A transition can blend valid poses and modestly exceed either source pose,
# but a new spike must not create a much longer edge or double body envelope.
thresholds={'mixed_edge_over_isolated_max':1.25,'aabb_axis_over_rest_height':1.5,'weight_sum_error_max':0.0001}
ratio=mixed_max_edge/single_max_edge
axis_max=np.max([g['size_max'] for g in groups.values()],axis=0)
checks={'all_vertices_finite':all(r['all_vertices_finite'] for r in rows),'finite_nonnegative_weights':finite_weights,'valid_skin_bind_indices':valid_indices,'weight_sums_within_tolerance':bool(np.max(np.abs(weights.sum(axis=1)-1.))<=thresholds['weight_sum_error_max']),'no_transition_edge_spike':ratio<=thresholds['mixed_edge_over_isolated_max'],'deformation_within_body_envelope':bool((axis_max<=rest_height*thresholds['aabb_axis_over_rest_height']).all())}
result={'schema':'silkroad.action2-rig-audit.v1','source':str(args.input.resolve()),'source_sha256':hashlib.sha256(args.input.read_bytes()).hexdigest(),'method':'CPU linear blend skinning from actual Godot AnimationPlayer poses, Skeleton3D global poses and Skin bind matrices; every vertex and every unique triangle edge recomputed for each sample. This validates deformation; visual scene integration is separate.','sample_hz':60,'pose_samples':len(rows),'directed_transition_runs':data['directed_transition_runs'],'vertices':count,'triangles':len(triangles),'unique_triangle_edges':len(edges),'influences_per_vertex':weights.shape[1],'weight_sum_min':float(weights.sum(axis=1).min()),'weight_sum_max':float(weights.sum(axis=1).max()),'rest_height_u':rest_height,'rest_max_triangle_edge_u':float(rest_edges.max()),'isolated_clip_max_edge_u':single_max_edge,'mixed_transition_max_edge_u':mixed_max_edge,'mixed_over_isolated_max_edge_ratio':ratio,'isolated_clip_max_aabb_diagonal_u':single_max_diag,'mixed_transition_max_aabb_diagonal_u':mixed_max_diag,'global_max_aabb_size':axis_max.tolist(),'turn_yaw_after_normalization_max_abs_deg':float(np.max(np.abs(root_yaw))*180/math.pi),'walk_stance_speed_u_s':{'left':foot_speeds['left'],'right':foot_speeds['right'],'median_both':float(np.median(feet)),'method':'Backward local-Z velocity while Foot bone lies within 0.008u of its lowest position; multiply by actor scale and playback speed.'},'thresholds':thresholds,'checks':checks,'pass':all(checks.values()),'groups':groups,'samples':rows}
args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ('groups','samples')},ensure_ascii=False,indent=2))
