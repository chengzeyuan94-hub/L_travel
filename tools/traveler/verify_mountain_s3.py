#!/usr/bin/env python3
"""Compare the S1 export with S3, including the actual runtime material flags."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/design/shanhe-luren/mountain-rework'
before = json.loads((OUT / 'baseline-mesh.json').read_text())
after = json.loads((OUT / 's3-mesh.json').read_text())
metrics = json.loads((OUT / 'mesh-report.json').read_text())
rows = []
for old, new in zip(before['bands'], after['bands']):
    rows.append({
        'band': old['band_index'],
        'vertices_unchanged': old['vertices'] == new['vertices'],
        'indices_unchanged': old['indices'] == new['indices'],
        'materials_unchanged': old['face_material'] == new['face_material'],
        'bodies_unchanged': old['bodies'] == new['bodies'],
        'surface_count': new['surface_count'],
        'material': new['material'],
    })
checks = {
    'three_bands': len(before['bands']) == len(after['bands']) == 3,
    'camera_unchanged': before['camera_transform'] == after['camera_transform']
        and before['frozen_camera'] == after['frozen_camera'],
    'geometry_unchanged': all(all(row[k] for k in (
        'vertices_unchanged', 'indices_unchanged', 'materials_unchanged', 'bodies_unchanged')) for row in rows),
    'unshaded_fog_and_culling': all(row['surface_count'] == 1 and all(
        row['material'][k] for k in ('unshaded', 'cull_back', 'fog_enabled', 'vertex_color_as_albedo')) for row in rows),
    'A1_outward': all(b['normal_orientation']['outward_fraction'] == 1 for b in metrics['bands'])
        and metrics['normal_y']['max'] > .5,
}
for name in ('s3-before-1080p', 's3-after-1080p', 's3-mountain-only-before', 's3-mountain-only-after'):
    capture = json.loads((OUT / 'evidence' / (name + '.json')).read_text())
    checks[name + '_capture'] = capture['image_size'] == capture['viewport_size'] == [1920, 1080] \
        and capture['capture_error'] == 0 and capture['look']['preset'] == 'changan/dusk'
result = {'pass': all(checks.values()), 'checks': checks, 'rows': rows}
(OUT / 's3-isolation-verification.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
raise SystemExit(0 if result['pass'] else 1)
