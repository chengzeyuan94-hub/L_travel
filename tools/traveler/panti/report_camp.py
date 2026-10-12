"""Summarize an existing Panti camp capture; never render or alter its inputs."""
import argparse
import json
from pathlib import Path
from PIL import Image
from make_checkpoint_board import board

ROOT = Path(__file__).resolve().parents[3]
REPORT = ROOT / 'docs/reports/traveler-panti-001'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', required=True)
    args = parser.parse_args()
    dest = REPORT / args.checkpoint
    before = json.loads((REPORT / 'checkpoint-20/sunset.json').read_text())
    after = json.loads((dest / 'sunset.json').read_text())
    unchanged = {
        key: before['layout'][key] == after['layout'][key]
        for key in ['camera_composition', 'fortress', 'trees', 'rocks', 'ground', 'depth_of_field_override']
    }
    unchanged['sunset_effective_params'] = before['look']['effective_params'] == after['look']['effective_params']
    unchanged['fortress_projection'] = before['fortress_projection'] == after['fortress_projection']
    report = {
        'image_size': after['image_size'],
        'frozen_settings_unchanged': unchanged,
        'local_ground_change': 'Small support patches beneath camp props only; rocks there follow the resulting height.',
        'performance': {
            'before': {k: before[k] for k in ['draw_calls', 'viewport_draw_calls', 'frame_ms']},
            'after': {k: after[k] for k in ['draw_calls', 'viewport_draw_calls', 'frame_ms']},
        },
        'character_projection': after['character_projection'],
        'camp': after['camp'],
        'runtime_log_error_lines': [line for line in (REPORT / f'{args.checkpoint}.log').read_text().splitlines() if any(token in line for token in ['ERROR', 'SCRIPT ERROR', 'Parse Error'])],
    }
    (dest / 'checkpoint-summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    Image.open(dest / 'sunset.png').crop((0, 360, 900, 1040)).save(dest / 'camp-detail.png')
    board(
        [REPORT / 'checkpoint-20/sunset.png', dest / 'sunset.png'],
        ['接入前 · 已认可雪地', '接入后 · 左前景营地'],
        '盘橐旅人 / 营地摆放',
        ['帐篷在左后方，人物坐在树桩前沿，篝火在右前方，小灯放在左侧桩面。',
         '相机、城堡、54 棵雪松、石头布局和夕阳沿用前版；营地物件脚下做局部接地。'],
        dest / 'before-after.png', 540,
    )
    print(json.dumps({'image_size': after['image_size'], 'unchanged': unchanged, 'error_lines': report['runtime_log_error_lines']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
