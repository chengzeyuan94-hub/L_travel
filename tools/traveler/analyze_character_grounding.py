#!/usr/bin/env python3
"""Summarize recorded grounding probes and decode frozen PNGs without image deps."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        parser.error('--out must be a new file')
    report = args.report.resolve()
    read = lambda name: json.loads((report / name).read_text())
    probes = {'enabled': read('footing-check.json'), 'disabled': read('footing-disabled-check.json')}
    states = {}
    for state in ('idle', 'walk', 'run'):
        states[state] = {}
        for mode, probe in probes.items():
            samples = [s for s in probe['samples'] if s['state'] == state]
            clearances = [min(v['clearance_u'] for name, v in s['feet'].items() if name.endswith('ToeBase')) for s in samples]
            assert clearances and all(v > -900 for v in clearances), 'Missing ground ray hit'
            states[state][mode] = {
                'samples': len(samples),
                'minimum_toe_clearance_u': min(clearances),
                'median_toe_clearance_u': statistics.median(clearances),
                'frames_below_minus_0_005_u': sum(v < -0.005 for v in clearances),
            }
    freeze_cmd = [args.ffmpeg, '-nostdin', '-v', 'error', '-framerate', '30', '-i', str(report / 'freeze-frames/f%04d.png'), '-pix_fmt', 'rgb24', '-f', 'framemd5', '-']
    decoded = subprocess.run(freeze_cmd, capture_output=True, text=True, check=True).stdout
    hashes = [line.split(',')[-1].strip() for line in decoded.splitlines() if line and not line.startswith('#')]
    frozen = read('freeze-frames/telemetry.json')
    transition = read('transition-frames/telemetry.json')
    main = read('transition-frames/manifest.json')
    gait = read('open-path-frames/telemetry.json')
    stills = {}
    for period in ('day', 'dusk'):
        data = read(period + '.json')
        header = (report / (period + '.png')).read_bytes()[:24]
        assert header[:8] == b'\x89PNG\r\n\x1a\n'
        size = list(struct.unpack('>II', header[16:24]))
        assert size == data['image_size'] == data['viewport_size'] == [1920, 1080]
        assert data['view'] == 'changan' and data['look']['preset'] == 'changan/' + period
        stills[period] = {'image_size': size, 'height_px': data['checks']['measured_pose_height_px'], 'checks': data['checks'], 'draw_calls': data['draw_calls'], 'viewport_draw_calls': data['viewport_draw_calls'], 'frame_ms': data['frame_ms'], 'camera': data['frozen_camera']}
    logs = {}
    for name in ('day-runtime.log', 'dusk-runtime.log', 'transition-runtime.log', 'freeze-runtime.log'):
        logs[name] = [line for line in (report / name).read_text().splitlines() if 'ERROR' in line or 'Parse Error' in line]
    cloud = json.loads((report.parent / 'polished/cloud-continuity.json').read_text())
    result = {
        'measurement_scope': 'Same 330-tick route; toggle only foot correction. Toe joint ray clearance, not a full skinned sole collision measurement. -0.005 u is diagnostic, not an art acceptance threshold.',
        'footing': states,
        'probe_checks': probes['enabled']['checks'],
        'freeze': {'frames': len(hashes), 'adjacent_pairs': len(hashes)-1, 'duration_s': len(hashes)/30, 'unique_pixel_hashes': len(set(hashes)), 'pixels_identical': len(hashes)==61 and len(set(hashes))==1, 'mid_walk': frozen[0]['state']=='walk', 'feet_unchanged': all(s['feet']==frozen[0]['feet'] for s in frozen), 'scope': '2.033 s regression, not 60 s S0', 'command': freeze_cmd},
        'transition': {'manifest': main, 'frames': len(transition), 'peak_cloud_speed_multiplier': max(s['cloud_speed'] for s in transition), 'cloud_phase_never_reverses': all(b['cloud_phase']>=a['cloud_phase'] for a,b in zip(transition,transition[1:])), 'period_at_frame': {str(i): transition[i]['period'] for i in (0,60,180,300,360,480,600,659)}},
        'turn_samples': [{k:gait[i][k] for k in ('frame','state','heading_error_rad','current_speed_px_s','animation_rate')} for i in (270,275,280,420,425,430)],
        'stills': stills,
        'runtime_errors': logs,
        'cloud_continuity': cloud,
    }
    result['checks_pass'] = all(probes['enabled']['checks'].values()) and result['freeze']['pixels_identical'] and not any(logs.values()) and result['transition']['cloud_phase_never_reverses'] and all(d['frame_ms']['p95']<33.3 for d in stills.values())
    args.out.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'out':str(args.out),'checks_pass':result['checks_pass'],'freeze':result['freeze'],'footing':states},indent=2))
    if not result['checks_pass']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
