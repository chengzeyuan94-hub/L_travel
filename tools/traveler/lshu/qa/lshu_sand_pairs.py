#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· fix #5 evidence: before / after pairs from the same code and look.json.
For each tile: "before" = qa/lshu_ground_class_capture.gd with --sand-counter=0 (QA-only override of the ground role's
l2_sand_counter), "after" = the same harness with look.json as is. Strict error rule as qa/lshu_batch.py.
Writes docs/reports/traveler-lshu-p0-20260923/fix5_desert_night/pairs/<tile>_<light>_{before,after}.png/.json/.log
and runs_<light>.jsonl.
  python3 tools/traveler/lshu/qa/lshu_sand_pairs.py <tile,tile,...> [light=night]
"""
import json, os, subprocess, sys, time
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
GODOT='/Applications/Godot.app/Contents/MacOS/Godot'
OUT=ROOT+'/docs/reports/traveler-lshu-p0-20260923/fix5_desert_night/pairs'
os.makedirs(OUT, exist_ok=True)
tiles=sys.argv[1].split(','); light=sys.argv[2] if len(sys.argv)>2 else 'night'
rows=[]
for t in tiles:
    for tag, extra in (('before', ['--sand-counter=0']), ('after', [])):
        png='%s/%s_%s_%s.png'%(OUT,t,light,tag)
        cmd=[GODOT,'--path',ROOT,'--script','res://tools/traveler/lshu/qa/lshu_ground_class_capture.gd','--','--tile='+t,'--light='+light,
             '--motion-freeze','--park=5','--capture='+png]+extra
        t0=time.time()
        try:
            pr=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=200); log=pr.stdout+pr.stderr; rc=pr.returncode
        except subprocess.TimeoutExpired:
            log='TIMEOUT'; rc=None
        open(png[:-4]+'.log','w').write(' '.join(cmd)+'\n\n'+log)
        errs=[l for l in log.splitlines() if 'ERROR' in l or 'WARNING' in l or l.strip()=='TIMEOUT']
        if rc!=0: errs.append('EXIT %s'%rc)
        r={'tile':t,'light':light,'tag':tag,'sec':round(time.time()-t0,1),'rc':rc,'errors':errs}
        j=png[:-4]+'.json'
        if os.path.exists(j):
            d=json.load(open(j)); f=d['frame_ms']
            if d.get('capture_error',0): errs.append('capture_error')
            r.update(p50=round(f['p50'],2),p95=round(f['p95'],2),dc=d['draw_calls'],override=d.get('extra',{}).get('qa_override'))
        else: errs.append('NO JSON')
        rows.append(r); print(json.dumps(r,ensure_ascii=False)[:300],flush=True)
open(OUT+'/runs_%s.jsonl'%light,'a').write(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
print('SUMMARY runs=%d errors=%d worst_p95=%s'%(len(rows),sum(len(r['errors']) for r in rows),max(r.get('p95',0) for r in rows)))
