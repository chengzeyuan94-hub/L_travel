"""Read recorded screen-space gait telemetry and decoded freeze hashes."""
import argparse, json, math, statistics, subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--report',required=True);p.add_argument('--ffmpeg',default='ffmpeg');a=p.parse_args();root=Path(a.report)
def measure(folder):
 f=json.loads((root/folder/'telemetry.json').read_text());out={}
 for state in ('walk','run'):
  rates=[];signed=[];absolute=[]
  for x,y in zip(f,f[1:]):
   if x['state']!=state or y['state']!=state or x['current_speed_px_s']<40:continue
   rates.append(x['animation_rate']);k=min(x['feet'],key=lambda k:x['feet'][k]['local'][1]);u=x['feet'][k];v=y['feet'][k]
   if v['local'][2]>=u['local'][2]:continue
   body=[y['screen_position_px'][i]-x['screen_position_px'][i] for i in (0,1)];toe=[v['pixel'][i]-u['pixel'][i] for i in (0,1)]
   signed.append(sum(toe[i]*body[i] for i in (0,1))/max(sum(z*z for z in body),.001));absolute.append(math.hypot(*toe)*30)
  out[state]={'samples':len(signed),'median_cadence_multiplier':statistics.median(rates),'median_signed_stance_slip_fraction':statistics.median(signed),'median_toe_screen_speed_px_s':statistics.median(absolute)}
 out['arrivals']=[{'frame':y['frame'],'speed':y['current_speed_px_s'],'state':y['state']} for x,y in zip(f,f[1:]) if x['waypoints_remaining'] and not y['waypoints_remaining']]
 return out
result={'method':'At 30fps choose lower toe while moving backwards in rig Z. Project toe delta along body screen delta. Includes slopes, turns, contact/flight transitions; diagnostic, not a rigid foot-lock certification. Intermediate is first calibrated pass, not original user baseline.','intermediate':measure('main-frames'),'final':measure('gait-final-frames')}
raw=subprocess.check_output([a.ffmpeg,'-nostdin','-hide_banner','-loglevel','error','-framerate','30','-i',str(root/'frozen-frames/f%04d.png'),'-f','framemd5','-'],text=True)
h=[r.split(',')[-1].strip() for r in raw.splitlines() if r and not r.startswith('#')]
result['freeze']={'frames':len(h),'pairs':len(h)-1,'unique_decoded_hashes':len(set(h)),'all_pixels_identical':len(h)==61 and len(set(h))==1,'duration_s':len(h)/30}
(root/'motion-review.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
