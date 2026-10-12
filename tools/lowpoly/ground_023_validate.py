#!/usr/bin/env python3
"""Bind the actual local terrain study, its unchanged inputs and paired renders."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib, json, math
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'docs/design/ground-detail-023'
EV = Path('/Users/chengzeyuan/SilkRoadEvidence/ground-detail-023')
def read(p): return json.loads(Path(p).read_text())
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def info(p): return {'sha256': sha(p), 'bytes': Path(p).stat().st_size}
def write(p, value): Path(p).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
def equivalent(a, b, tolerance=1e-10):
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(equivalent(a[k], b[k], tolerance) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(equivalent(x, y, tolerance) for x, y in zip(a,b))
    if isinstance(a, (float,int)) and isinstance(b, (float,int)):
        return math.isclose(a, b, rel_tol=1e-12, abs_tol=tolerance)
    return a == b

def main():
    baseline = read(EV / 'input-start.json')['source_sha256']
    changed = [p for p, h in baseline.items() if not (ROOT/p).is_file() or sha(ROOT/p) != h]
    assert not changed, changed
    terrain = read(LIB / 'terrain-report.json')
    for kind in ['glb', 'blend']:
        assert sha(ROOT / terrain[kind]) == terrain[kind + '_sha256']
    for p, h in terrain['dependencies'].items(): assert sha(ROOT/p) == h, p
    reopened = read(LIB / 'validation/source-reopen.json')
    assert not reopened['errors']
    assert reopened['glb_sha256'] == terrain['glb_sha256'] and reopened['blend_sha256'] == terrain['blend_sha256']
    for mesh in reopened['objects']:
        assert mesh['source_runtime_position_color_corner_multiset_equal_1e6'] and not mesh['mesh_validation_would_change']
    geometry = read(LIB / 'validation/geometry-review.json')
    assert not geometry['blocking_findings']
    for path, expected in geometry['inspected_sha256'].items(): assert sha(ROOT/path) == expected, path
    plan = read(LIB / 'placements.json')
    assert plan['ground_sha256'] == terrain['glb_sha256']
    assert set(plan['replace_nodes']) == {'spherical_continents_and_biomes', 'radial_coastal_cliffs'}
    for entry in plan['landmarks']:
        assert sha(ROOT / entry['glb']) == entry['sha256']
        if entry['seating']: assert entry['seating']['hero_minimum_clearance_world'] > .01
    capture_path = EV / 'final/ground-capture-report.json'
    capture = read(capture_path)
    assert capture['task'] == 'TASK-GROUND-DETAIL-023'
    assert capture['inputs_stable'] and not capture['errors']
    assert len(capture['captures']) == len(capture['views']) * 2 == 20
    visual = read(LIB / 'validation/visual-review.json')
    for name, path in [('ground_glb', LIB/'exports/ground.glb'), ('final_capture_report', capture_path)]:
        assert visual['evidence'][name]['sha256'] == sha(path), ('visual review is stale', name)
    for p, h in capture['source_end_sha256'].items(): assert sha(ROOT/p) == h, p
    for p, h in capture['asset_sha256'].items(): assert sha(p) == h, p
    assert equivalent(capture['ground_plan'], plan), 'Godot plan differs beyond JSON float serialization precision'
    raw = []; pairs = {}; perf = []
    for item in capture['captures']:
        assert sha(item['raw']) == item['raw_sha256']
        assert sha(item['preview']) == item['sha256']
        for path in [item['raw'], item['preview']]:
            with Image.open(path) as picture: assert picture.size == (1280, 720)
        raw.append(Path(item['raw']))
        pairs.setdefault(item['view_id'], {})[item['phase']] = item
        if 'static_performance' in item:
            perf.append({'view': item['view_id'], 'phase': item['phase'], 'sample': item['static_performance']})
    for view, pair in pairs.items():
        assert set(pair) == {'before', 'after'}, view
        for field in ['camera_transform', 'camera_fov', 'board_size', 'window_size', 'right_safe_inset']:
            assert pair['before'][field] == pair['after'][field], (view, field)
        assert equivalent(pair['before']['cities'], pair['after']['cities'], .001), (view, 'city projection/labels differ beyond .001 px')
    for view, city in [('city_delhi', 'delhi'), ('city_panti', 'panti')]:
        for phase, item in pairs[view].items():
            assert city in [a['id'] for a in item['visible_city_labels']], (view, phase)
    assert len(perf) == 6 and capture['performance_scope']['enabled']
    soft_dir = EV / 'soft-surface-rejected'
    soft_report = read(soft_dir / 'capture/ground-capture-report.json')
    soft_captures = {c['view_id']:c for c in soft_report['captures'] if c['phase'] == 'after'}
    soft_raw = []
    for view, pair in pairs.items():
        previous = soft_captures[view]
        reference = LIB / 'previews' / (view + '-smooth.jpg')
        assert sha(reference) == previous['sha256']
        original = soft_dir / 'capture/captures' / (view + '-after.png')
        assert sha(original) == previous['raw_sha256']
        soft_raw.append(original)
        for field in ['camera_transform','camera_fov','board_size','window_size','right_safe_inset']:
            assert previous[field] == pair['after'][field], (view, 'smooth-to-faceted', field)
    log = (EV / 'final.log').read_text()
    headless = (EV / 'headless.log').read_text()
    for text in [log, headless]:
        assert not any(token in text for token in ['ERROR:', 'SCRIPT ERROR:', 'WARNING:']), text
    summary = {
        'task': capture['task'], 'pass': True, 'unchanged_existing_inputs': len(baseline),
        'paired_views': len(pairs), 'actual_images': len(raw),
        'source_and_asset_hashes_match': True, 'all_pairs_use_same_camera': True,
        'city_projection_and_labels_match_within_001px': True,
        'counts': capture['layout_counts'], 'ground_triangles': terrain['triangles'],
        'local_cliff_triangles': terrain['cliffs'], 'adapted_landmarks': len(plan['landmarks']),
        'adapted_prop_instances': len(plan['props']), 'static_performance': [{**row, 'sample': {k:v for k,v in row['sample'].items() if k not in ['ambient','camera']}} for row in perf],
        'performance_scope': capture['performance_scope'],
        'gallery_comparison': {'left':'Archived rejected overly smooth version', 'right':'Current sculpted faceted version', 'same_camera_pairs':len(pairs), 'left_report_sha256':sha(soft_dir/'capture/ground-capture-report.json')},
        'capture_report': str(capture_path), 'capture_report_sha256': sha(capture_path),
        'scope': 'Source/render integrity and fixed-view consistency; independent geometry and visual conclusions are separate. No full-game, dynamic occlusion or native manual input claim.',
    }
    write(LIB / 'validation/summary.json', summary)
    local = list(LIB.rglob('*')) + list((ROOT/'tools/lowpoly').glob('ground_023*')) + [
        ROOT/'docs/reports/task-ground-detail-023.md', ROOT/'docs/CURRENT-STATE.md']
    local = sorted({p for p in local if p.is_file() and p.name not in ['manifest.json', '.DS_Store']})
    external = raw + soft_raw + [capture_path, EV/'input-start.json', EV/'headless.log', EV/'final.log', soft_dir/'capture/ground-capture-report.json', soft_dir/'archive.json']
    for path in [EV/'gallery-viewport.png', EV/'gallery-comparison.png', EV/'gallery-browser-qa.json']:
        if path.is_file(): external.append(path)
    for path in [EV/'reopen_check.py', EV/'river-footprint-height-check.json', EV/'free-layout-geometry-check.json', EV/'normal-encoding-probe.json', EV/'independent-audit/audit.py', EV/'independent-audit/contact_probe.py']:
        if path.is_file(): external.append(path)
    write(LIB / 'manifest.json', {
        'task': capture['task'], 'created_at_utc': datetime.now(timezone.utc).isoformat(),
        'status': 'Sculpted faceted local revision. Previous overly smooth version was rejected; see current visual review for limits.',
        'production_integrated': False, 'unchanged_existing_inputs': len(baseline),
        'files': {str(p.relative_to(ROOT)): info(p) for p in local},
        'external_evidence': {str(p): info(p) for p in external},
    })
    print(json.dumps({'pass': True, 'unchanged_inputs': len(baseline), 'pairs': len(pairs), 'static_samples': len(perf)}))

if __name__ == '__main__': main()
