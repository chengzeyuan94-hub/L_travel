#!/usr/bin/env python3
"""Sequential fixed-camera, fixed-SubViewport mountain evidence; no preset edits."""
import argparse
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/design/shanhe-luren/mountain-rework/integration'
GODOT = '/Applications/Godot.app/Contents/MacOS/Godot'
NODOF = ['--set=dof:0', '--set=dofn:0']
VIEWS = [
    ('after-dusk-nodof', '--dusk', NODOF + ['--dump-massif=res://' + str((OUT/'asset-bands.json').relative_to(ROOT))]),
    ('asset-only-dusk', '--dusk', NODOF + ['--no-mountain-foot']),
    ('after-dusk-dof', '--dusk', []),
    ('after-day-nodof', '--day', NODOF),
    ('after-day-dof', '--day', []),
    ('no-mountain-dusk', '--dusk', ['--no-mountain']),
    ('no-mountain-day', '--day', ['--no-mountain']),
    ('no-mountain-dusk-nodof', '--dusk', NODOF + ['--no-mountain']),
    ('no-mountain-day-nodof', '--day', NODOF + ['--no-mountain']),
    ('fog-45', '--dusk', NODOF + ['--set=fogb:45']),
    ('fog-35', '--dusk', NODOF + ['--set=fogb:35']),
    ('dof-10', '--dusk', ['--set=dof:10', '--set=dofn:0']),
    ('dof-19', '--dusk', ['--set=dof:19', '--set=dofn:0']),
    ('mountain-only', '--dusk', NODOF + ['--mountain-only']),
    ('silhouette-0', '--dusk', NODOF + ['--mountain-only', '--mountain-silhouette', '--no-mountain-foot']),
    ('silhouette-10', '--dusk', ['--set=dof:10', '--set=dofn:0', '--mountain-only', '--mountain-silhouette', '--no-mountain-foot']),
    ('silhouette-19', '--dusk', ['--set=dof:19', '--set=dofn:0', '--mountain-only', '--mountain-silhouette', '--no-mountain-foot']),
]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--views", nargs="*", help="Optional names from VIEWS to capture")
    selected = parser.parse_args().views
    if OUT == ROOT / "docs/design/shanhe-luren/mountain-rework/integration":
        settings = json.loads((ROOT / "data/traveler/mountain_params.json").read_text())
        if settings.get("runtime_mode", "asset") != "asset":
            raise RuntimeError("Historical asset capture requires runtime_mode=asset; current user-selected reference massifs must use a separate output directory.")
    OUT.mkdir(parents=True, exist_ok=True)
    for name, mode, extra in VIEWS:
        if selected and name not in selected:
            continue
        image = OUT / (name + '.png')
        command = [GODOT, '--path', str(ROOT), '--script', 'res://tools/traveler/capture_traveler.gd', '--', '--view=changan', mode, '--far', *extra, '--capture=res://' + str(image.relative_to(ROOT))]
        started = time.monotonic()
        with (OUT/(name+'.log')).open('w') as log:
            try:
                code = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=90).returncode
            except subprocess.TimeoutExpired:
                code = 124
        lines = (OUT/(name+'.log')).read_text().splitlines()
        result = dict(command=command, exit_code=code, error_lines=sum('ERROR' in x for x in lines), script_error_lines=sum('SCRIPT ERROR' in x for x in lines), seconds=time.monotonic()-started)
        (OUT/(name+'.run.json')).write_text(json.dumps(result, indent=2))
        if code or result['error_lines'] or result['script_error_lines']:
            raise RuntimeError(result)
        evidence = json.loads(image.with_suffix('.json').read_text())
        assert evidence['image_size'] == [1920,1080] and evidence['capture_error'] == 0
        print(name, evidence['draw_calls'], evidence['frame_ms']['p50'], evidence['frame_ms']['p95'], flush=True)

if __name__ == '__main__':
    main()
