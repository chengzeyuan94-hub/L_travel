#!/usr/bin/env python3
"""Verify provenance and image coverage; visual acceptance is recorded separately."""
from pathlib import Path
import argparse,hashlib,json
ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/terrain-transition-022'
EV=Path('/Users/chengzeyuan/SilkRoadEvidence/terrain-transition-022')
def read(p):return json.loads(Path(p).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,v):Path(p).write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def resolve(p):return ROOT/p.removeprefix('res://') if p.startswith('res://') else Path(p) if p.startswith('/') else ROOT/p
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--capture',type=Path,required=True);a=parser.parse_args()
    c=read(a.capture);assert c['task']=='TASK-TERRAIN-TRANSITION-022'
    assert c['inputs_stable'] and not c['errors'] and not c.get('capture_view_filter')
    expected={(v['id'],phase) for v in c['views'] for phase in ('before','after')}
    assert len(c['captures'])==16 and {(x['view_id'],x['phase']) for x in c['captures']}==expected
    for field in ('source_start_sha256','source_end_sha256','asset_sha256'):
        for p,h in c[field].items():assert sha(resolve(p))==h,p
    for x in c['captures']:
        assert sha(x['preview'])==x['sha256'] and sha(x['raw'])==x['raw_sha256']
    frozen=read(EV/'input-start.json')['source_sha256']
    changed=[p for p,h in frozen.items() if not (ROOT/p).is_file() or sha(ROOT/p)!=h]
    assert not changed,changed
    own=[]
    for x in c['captures']:
        if x['view_id'].startswith('city_'):
            cid=x['view_id'][5:];row=next(r for r in x['cities'] if r['id']==cid)
            own.append({'city':cid,'phase':x['phase'],'tag_visible':row['tag_visible']})
    assert all(x['tag_visible'] for x in own)
    summary={'task':c['task'],'status':'three-location-transition-study','captures':16,'views':8,'targets':['everest','taklamakan_dunes','tigris_meander'],'unchanged_existing_inputs':len(frozen),'capture_report':str(a.capture),'capture_report_sha256':sha(a.capture),'source_stable':True,'own_city_label_checks':own,'geometry':c.get('transition',{}),'production_integrated':False,'scope_note':'Provenance and static image coverage only. Visual judgment, terrain contact and river continuity require separate inspection; no full game or performance pass.'}
    write(LIB/'validation/summary.json',summary)
    write(LIB/'validation/capture-report.json',c)
    print(json.dumps({'captures':16,'unchanged_inputs':len(frozen),'city_label_checks':len(own),'report_sha256':sha(a.capture)}))
if __name__=='__main__':main()
