#!/usr/bin/env python3
"""Audit S6b revision evidence without treating unfinished S9b as delivered."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = args.report.resolve()
    checks = {}
    camera = read(ROOT / 'data/traveler/motion_params.json')['_measured']['traveler_camera']
    initial = read(report / 'input-sha256.json')
    changed = [path for path, digest in initial.items()
               if not (ROOT / path).is_file()
               or hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != digest]
    allowed = {'data/traveler/day_leaves_params.json', 'scripts/traveler/day_leaves.gd',
               'tools/traveler/capture_day_motion_video.gd',
               'tools/traveler/finish_day_motion_video.py'}
    checks['frozen_scene_cloud_grass_master_and_prior_evidence_unchanged'] = set(changed) <= allowed
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    checks['original_branch'] = branch == 'feat/night1-ui-motion'
    accepted_runs = []
    verdict = read(report / 'S6b/motion-verdict-AB.json')
    checks['S6b_independent_AB'] = verdict['pass']
    for mode in ('A', 'B'):
        accepted_runs.append(read(report / f'S6b/{mode}.run.json'))
        samples = read(report / f'S6b/{mode}/samples.json')['samples']
        assert len(samples) == 11
        for sample in samples:
            assert sample['image_size'] == [1920, 1080]
            assert sample['viewport_size'] == [1920, 1080]
            assert sample['frozen_camera'] == camera
            assert sample['look']['preset'] == 'changan/day'
            assert sample['capture_error'] == 0
    checks['S6b_capture_metadata'] = True
    size = read(report / 'S6b/leaf-pixel-measurement.json')
    checks['leaf_height_8_to_22_pixels'] = size['height_gate']['pass']
    performance = {}
    for period in ('day', 'dusk'):
        performance[period] = {}
        for phase in ('before', 'after-leaves'):
            data = read(report / phase / f'{period}.json')
            accepted_runs.append(read(report / phase / f'{period}.run.json'))
            assert data['image_size'] == [1920, 1080] == data['viewport_size']
            assert Image.open(report / phase / f'{period}.png').size == (1920, 1080)
            assert data['look']['preset'] == f'changan/{period}'
            assert data['frozen_camera'] == camera
            assert data['frame_ms']['vsync_disabled'] and data['frame_ms']['engine_max_fps'] == 0
            performance[period][phase] = {
                'draw_calls_global': data['draw_calls'],
                'draw_calls_subviewport': data['viewport_draw_calls'],
                'frame_ms_p50': data['frame_ms']['p50'],
                'frame_ms_p95': data['frame_ms']['p95'],
                'sample_count': data['frame_ms']['sample_count'],
                'meanV_report_only': data['look']['measured']['meanV'],
                'meanS_report_only': data['look']['measured']['meanS'],
            }
        checks[f'{period}_P95_within_33_3_ms'] = performance[period]['after-leaves']['frame_ms_p95'] <= 33.3
    checks['accepted_capture_runs_no_errors_or_preset_fallback'] = all(
        run['exit_code'] == 0 and not run['error_lines'] and not run['warning_lines']
        and '--view=changan' in run['command']
        and not any(arg.startswith('--resolution') for arg in run['command'])
        for run in accepted_runs)
    ignored = subprocess.run(['git', 'check-ignore', str(report / 'README.md'),
                              str(report / 'after-leaves/day.png'), str(report / 'S6b/A/f0000.png')],
                             cwd=ROOT, capture_output=True, text=True)
    checks['evidence_not_ignored'] = ignored.returncode == 1 and not ignored.stdout
    result = {
        'schema': 'traveler.day-motion-revision-leaf-audit.v1',
        'scope': 'S6b captures, pixel height, performance and frozen-input audit; full lifetime trajectory and video have separate reports.',
        'pass_audited_subset': all(checks.values()),
        'full_S6b_S9b_delivery_complete': False,
        'S9b_status': 'Concept and four-view art pending generation; user approval of four views required before Blender modeling.',
        'checks': checks, 'performance': performance, 'AB_verdict': verdict,
        'leaf_size': size['height_gate'], 'leaf_visible_components': size['visible_component_count'],
        'input_hashes': {'count': len(initial), 'changed': changed, 'unexpected_changes': sorted(set(changed) - allowed)},
        'branch': branch, 'accepted_runs': accepted_runs,
        'note': 'No commit, push, staging or branch switch. Earlier evidence is immutable; before/after images still contain the prior birds and are labeled an intermediate leaf revision.',
    }
    (report / 'leaf-delivery-audit.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'pass_audited_subset': result['pass_audited_subset'], 'checks': checks, 'performance': performance}, indent=2))
    if not result['pass_audited_subset']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
