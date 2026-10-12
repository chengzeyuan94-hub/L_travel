#!/usr/bin/env python3
"""Judge first-round motion using the unchanged reference metric and numeric contract."""
from __future__ import annotations
import argparse, importlib.util, json
from pathlib import Path
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('reference',Path(__file__).with_name('motion_gate.py'))
reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('report',type=Path);args=parser.parse_args();p=args.report
    contract=json.loads((ROOT/'data/traveler/motion_params.json').read_text());metric=contract['gate']['metric'];t=contract['gate']['thresholds'];gates={}
    def gate(name,measured,threshold,verdict):gates[name]={'measured':measured,'threshold':threshold,'verdict':bool(verdict)}
    for mode in ('A','B'):
        raw=json.loads((p/f'motion-gate-{mode}.json').read_text());pairs=raw['pairs'];live=[r['live_cells_non_adjacent'] for r in pairs];moved=[r['moved_pixel_fraction'] for r in pairs]
        assert raw['grid']==metric['grid'] and raw['pix_threshold']==metric['pixel_threshold'] and raw['cell_fraction']==metric['cell_fraction']
        gate(mode+'_sample_pairs',len(pairs),60,len(pairs)==60)
        if mode=='A':
            union={tuple(c[:2]) for pair in pairs for c in pair['cells']}
            gate('A_live_cells',{'min':min(live),'max':max(live)}, {'every_pair_min':t['A_live_cells_per_pair_min']},min(live)>=t['A_live_cells_per_pair_min'])
            gate('A_union',len(union),{'min':t['A_union_coverage_min_cells'],'total_cells':84},len(union)>=t['A_union_coverage_min_cells'])
            lo,hi=t['A_moved_pixel_fraction_range'];gate('A_moved_fraction',{'min':min(moved),'max':max(moved)},[lo,hi],all(lo<=v<=hi for v in moved))
        else:
            gate('B_live_cells',{'min':min(live),'max':max(live),'nonzero_pairs':sum(v!=0 for v in live)}, {'every_pair':0},all(v==0 for v in live))
            gate('B_moved_fraction',{'min':min(moved),'max':max(moved)},{'max':t['B_moved_pixel_fraction_max']},max(moved)<=t['B_moved_pixel_fraction_max'])
    a=np.asarray(Image.open(p/'A/f0000.png').convert('RGB'));b=np.asarray(Image.open(p/'B/f0000.png').convert('RGB'))
    mean=float(np.abs(a.astype(float)-b).mean());gate('AB_frame0_mean_abs_diff_255',mean,t['A_vs_B_frame0_mean_abs_diff_max'],mean<=t['A_vs_B_frame0_mean_abs_diff_max'])
    # Director's 88.342 / 88.336 baseline uses mean display-RGB, not luma weights.
    a_luma=float(a.mean());b_luma=float(b.mean())
    difference=abs(a_luma-b_luma)
    gate('AB_mean_luminance_difference_255',{'A':a_luma,'B':b_luma,'absolute_difference':difference,'method':'mean display RGB, 0..255'}, {'max':0.5,'source':'TASK-MOTION-002 director ruling, replacing unstable k-means'},difference<=0.5)
    result={'pass':all(g['verdict'] for g in gates.values()),'scope':'S11 A/B separation only; amplitude/continuity and CP1 reported separately','gates':gates}
    (p/'motion-verdict-AB.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps({k:{**v,'measured':v['measured']} for k,v in gates.items()},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
