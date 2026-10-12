"""Build equal-height review boards from existing Panti renders, never recapture.

Example:
  python3 make_checkpoint_board.py --checkpoint checkpoint-04 --height 720
Requires Pillow. Original PNG / JSON files are read-only inputs.
"""
import argparse
import json
import math
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3]
REPORT = ROOT / 'docs/reports/traveler-panti-001'
BG = '#17212b'
TEXT = '#edf4f8'
MUTED = '#becbd5'
ACCENT = '#e1c995'
FONT_CANDIDATES = [
    Path('/System/Library/Fonts/Supplemental/Arial Unicode.ttf'),
    Path('/System/Library/Fonts/STHeiti Medium.ttc'),
]


def font(size):
    path = next((p for p in FONT_CANDIDATES if p.exists()), None)
    if path is None:
        raise RuntimeError('A CJK font is required; update FONT_CANDIDATES for this host.')
    return ImageFont.truetype(str(path), size)


def resized(path, height):
    image = Image.open(path).convert('RGB')
    return image.resize((round(image.width * height / image.height), height), Image.Resampling.LANCZOS)


def board(images, labels, title, footer_lines, output, height):
    padding, gap = 24, 24
    title_h, label_h, footer_h = 70, 48, 42 + len(footer_lines) * 38
    panels = [resized(path, height) for path in images]
    width = sum(im.width for im in panels) + 2 * padding + gap * (len(panels) - 1)
    canvas = Image.new('RGB', (width, title_h + label_h + height + footer_h), BG)
    draw = ImageDraw.Draw(canvas)
    draw.text((padding, 17), title, font=font(30), fill=TEXT)
    x = padding
    for panel, label in zip(panels, labels):
        draw.text((x, title_h + 6), label, font=font(25), fill=ACCENT)
        canvas.paste(panel, (x, title_h + label_h))
        x += panel.width + gap
    y = title_h + label_h + height + 21
    for index, line in enumerate(footer_lines):
        draw.text((padding, y + 38 * index), line, font=font(23), fill=TEXT if index == 0 else MUTED)
    canvas.save(output, optimize=True)


def camera_geometry(data):
    if 'camera_geometry' in data:
        return data['camera_geometry']['height_above_ground_u'], data['camera_geometry']['optical_axis_elevation_deg']
    transform = data['camera_transform']
    origin = [float(x) for x in re.search(r'O: \(([^)]+)\)', transform).group(1).split(',')]
    z_axis = [float(x) for x in re.search(r'Z: \(([^)]+)\)', transform).group(1).split(',')]
    ground_y = data['layout']['stage_elevation_u'] + data['layout']['ground']['center_stage'][1]
    return origin[1] - ground_y, math.degrees(math.asin(-z_axis[1]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', default='checkpoint-04')
    parser.add_argument('--image', default='day', help='Input capture filename stem, e.g. day or sunset.')
    parser.add_argument('--height', type=int, default=720)
    parser.add_argument('--before', help='Optional earlier checkpoint for a layout before/after board.')
    parser.add_argument('--before-image', default='day', help='Earlier capture filename stem.')
    parser.add_argument('--reference', help='Single reference filename under the report references directory.')
    parser.add_argument('--comparison-topic', choices=['layout', 'pan-dof', 'character-sunset', 'composition'], default='layout')
    args = parser.parse_args()
    dest = REPORT / args.checkpoint
    data = json.loads((dest / f'{args.image}.json').read_text())
    capture_image = dest / f'{args.image}.png'
    sunset = data.get('lighting_period', args.image) == 'sunset'
    assert data['image_size'] == [1920, 1080]
    outputs = ['reference-comparison.png' if args.reference else 'concept-comparison.png']
    width_pct = data['fortress_projection']['width_fraction'] * 100
    char_height = data['character_projection']['height_px']
    tree_ranges = []
    tier_order = list(dict.fromkeys(t['tier'] for t in data['trees']))
    for tier in tier_order:
        heights = [t['height_px'] for t in data['trees'] if t['tier'] == tier]
        assert heights
        tree_ranges.append(f'{tier}×{len(heights)} {min(heights):.0f}–{max(heights):.0f} px')
    tree_label = '雪松投影全高：' + '  /  '.join(tree_ranges)
    stats = f'当前实渲：城堡屏宽 {width_pct:.1f}%（{data["fortress_projection"]["width_px"]:.1f} px）  ·  小人屏高 {char_height:.1f} px'
    eye, up = camera_geometry(data)
    camera_label = f'透视 FOV {data["camera"]["fov_vertical_deg"]:g}° · 实际仰角 {up:.2f}° · 眼高 {eye:.3f} u；角色世界缩放保持 0.6375。'
    if args.reference:
        board(
            [REPORT / 'references' / args.reference, capture_image],
            ['用户新参考 · 含锚点建议', '当前实渲 · 夕阳' if sunset else '当前实渲 · 白天'],
            '盘橐旅人  /  新构图参考与当前画面',
            ['本轮仅人物 / 城堡 / 树木，无营地；夕阳沿用用户新要求。',
             stats, camera_label, tree_label,
             '参考米数是构图建议；5 棵主巨树先校核，额外 19 棵树来自附图估读，用户坐标 JSON 未附。',
             '城堡保持等比：现资产宽深近 1:1，比参考宽 42 / 深 20 的城市更紧凑；未声称全部锚点吻合。',
             '像素值按 1920×1080 原图计；树高是投影全高，包含出框及被遮挡部分。'],
            dest / 'reference-comparison.png', args.height,
        )
    else:
        board(
            [REPORT / 'references/concept-1.png', REPORT / 'references/concept-2.png', capture_image],
            ['概念 1 · 场景层次', '概念 2 · 城体细节', '当前实渲 · 夕阳' if sunset else '当前实渲 · 明亮雪天'],
            f'盘橐旅人  /  构图检查点 {args.checkpoint.rsplit("-", 1)[-1]}  /  ' + ('参考为白天；当前按 Carlos 改夕阳' if sunset else '概念与实渲'),
            [stats, tree_label, '数值来自同名 JSON，均按 1920×1080 原图计；树高为投影全高，包含可能出框或被遮挡的部分。', camera_label],
            dest / 'concept-comparison.png', args.height,
        )
    # An absent capture is not replaced with a duplicate or a synthetic image.
    if (dest / f'{args.image}-smooth.json').exists() and (dest / f'{args.image}-smooth.png').exists():
        smooth = json.loads((dest / f'{args.image}-smooth.json').read_text())
        assert data['face_normals'] is True and smooth['face_normals'] is False
        assert data['normal_comparison_same_process'] and smooth['normal_comparison_same_process']
        for key in ['camera', 'layout', 'fortress_projection', 'character_projection']:
            assert data[key] == smooth[key], f'Normal comparison changed {key}'
        board(
            [dest / f'{args.image}-smooth.png', capture_image],
            ['原平滑法线', '逐面法线 · 当前'],
            '盘橐旅人  /  同进程、同机位法线对照',
            ['纹理、几何、红幡颜色、光照与构图保持一致；本对照仅切换网格法线。', stats],
            dest / 'normal-comparison.png', args.height,
        )
        outputs.append('normal-comparison.png')
    if (dest / f'{args.image}-no-dof.json').exists() and (dest / f'{args.image}-no-dof.png').exists():
        no_dof = json.loads((dest / f'{args.image}-no-dof.json').read_text())
        dof = data['depth_of_field']
        assert dof['far_enabled'] and not no_dof['depth_of_field']['far_enabled']
        assert dof['comparison_same_process'] and no_dof['depth_of_field']['comparison_same_process']
        for key in ['camera_transform', 'layout', 'fortress_projection', 'character_projection']:
            assert data[key] == no_dof[key], f'Depth-of-field comparison changed {key}'
        castle_depth = data['fortress_projection']['camera_depth_range_u']
        char_depth = data['character_projection']['camera_depth_range_u']
        board(
            [dest / f'{args.image}-no-dof.png', capture_image],
            ['远端景深关闭', '远端景深开启 · 当前'],
            '盘橐旅人  /  同进程、同机位远端景深对照',
            [f'远端虚化从 {dof["far_distance_u"]:g} u 开始，过渡 {dof["far_transition_u"]:.1f} u，模糊量 {dof["blur_amount"]:.2f}；近端景深关闭。',
             f'城堡实际顶点轴深 {castle_depth[0]:.2f}–{castle_depth[1]:.2f} u；角色 {char_depth[0]:.2f}–{char_depth[1]:.2f} u，均在清晰带内。',
             '两图使用相同相机、光照、材质、几何与角色姿势，仅开关远端景深。'],
            dest / 'dof-comparison.png', args.height,
        )
        outputs.append('dof-comparison.png')
    if (dest / f'{args.image}-day-control.json').exists() and (dest / f'{args.image}-day-control.png').exists():
        control = json.loads((dest / f'{args.image}-day-control.json').read_text())
        assert data['period_comparison_same_process'] and control['period_comparison_same_process']
        assert data['lighting_period'] == 'sunset' and control['lighting_period'] == 'day'
        for key in ['camera_transform', 'layout', 'fortress_projection', 'character_projection', 'character_style']:
            assert data[key] == control[key], f'Lighting comparison changed {key}'
        board(
            [dest / f'{args.image}-day-control.png', capture_image],
            ['同机位白天对照', '夕阳 · 当前'],
            '盘橐旅人  /  同进程、同机位白天与夕阳对照',
            ['同一进程、相同相机、角色位置与姿势、树木排布、材质和几何；仅切换盘橐光照预设。',
             f'当前夕阳太阳高度 {abs(data["look"]["effective_params"]["sunel"]):g}°；角色屏高 {char_height:.1f} px，世界缩放仍为 0.6375。'],
            dest / 'lighting-comparison.png', args.height,
        )
        outputs.append('lighting-comparison.png')
    if args.before:
        earlier = REPORT / args.before
        previous = json.loads((earlier / f'{args.before_image}.json').read_text())
        previous_multiplier = previous['layout']['trees'].get('height_multiplier')
        multiplier = data['layout']['trees'].get('height_multiplier')
        old_eye, old_up = camera_geometry(previous)
        new_eye, new_up = camera_geometry(data)
        old_width = previous['fortress_projection']['width_fraction'] * 100
        old_char = previous['character_projection']['height_px']
        comparison_title = '盘橐旅人  /  前后构图对照'
        comparison_lines = [
            f'镜头离雪面 {old_eye:.2f} → {new_eye:.2f} u；光轴仰角 {old_up:.1f}° → {new_up:.1f}°；FOV {previous["camera"]["fov_vertical_deg"]:g}° → {data["camera"]["fov_vertical_deg"]:g}°。',
            f'城堡屏宽 {old_width:.1f}% → {width_pct:.1f}%；小人屏高 {old_char:.1f} → {char_height:.1f} px（1920×1080 原图投影值）。',
        ]
        if previous_multiplier is not None and multiplier is not None:
            comparison_lines.insert(0, f'雪松较初始 {previous_multiplier:g}× → {multiplier:g}×（本轮再增大 {(multiplier / previous_multiplier - 1) * 100:.1f}%）；角色世界尺寸保持不变。')
        if args.comparison_topic == 'pan-dof':
            old_bounds = previous['fortress_projection']['bounds_px']
            new_bounds = data['fortress_projection']['bounds_px']
            shift = (new_bounds[0] + new_bounds[2] - old_bounds[0] - old_bounds[2]) / 2
            requested = abs(data['camera_pan']['settings']['horizontal_frame_fraction']) * 100
            dof = data['depth_of_field']
            comparison_title = '盘橐旅人  /  取景向左平移 · 后方巨树虚化'
            comparison_lines = [
                f'取景向左平移 {requested:g}%（参考城堡正面深度），城堡中心实测向右移动 {shift:.1f} px，约画幅 {shift / data["image_size"][0] * 100:.1f}%。',
                f'远端景深：起点 {dof["far_distance_u"]:g} u / 过渡 {dof["far_transition_u"]:.1f} u / 模糊量 {dof["blur_amount"]:.2f}；城堡与角色保持清晰。',
                f'机位高度、仰角、距离及树木尺寸保持不变；城堡屏宽 {old_width:.1f}% → {width_pct:.1f}%，角色屏高 {char_height:.1f} px。',
            ]
        if args.comparison_topic == 'character-sunset':
            foot_uv = data['layout']['character']['placement_reference']['foot_uv']
            comparison_title = '盘橐旅人  /  旅人移近左前景 · 再略仰视 · 夕阳光线'
            comparison_lines = [
                f'角色真实移近：目标落脚点 ({foot_uv[0]:.2f}, {foot_uv[1]:.2f})，屏高 {old_char:.1f} → {char_height:.1f} px；世界缩放仍为 0.6375。',
                f'光轴仰角 {old_up:.2f}° → {new_up:.2f}°；太阳高度改为 {abs(data["look"]["effective_params"]["sunel"]):g}°，盘橐采用夕阳预设。',
                f'角色材质、动作、树木尺寸与排布保持不变；当前城堡屏宽 {width_pct:.1f}%。',
            ]
        if args.comparison_topic == 'composition':
            foot_uv = data['layout']['character']['placement_reference']['foot_uv']
            comparison_title = '盘橐旅人  /  新参考构图：近处旅人 · 中景城堡 · 巨树分层'
            comparison_lines = [
                f'仅调整现有人物 / 城堡 / 树木，无营地；当前夕阳沿用用户要求。角色缩放仍为 0.6375，屏高 {old_char:.1f} → {char_height:.1f} px。',
                f'当前人物目标脚点 ({foot_uv[0]:.2f}, {foot_uv[1]:.2f})；FOV {data["camera"]["fov_vertical_deg"]:g}°，实际仰角 {new_up:.2f}°。',
                f'城堡保持等比，高 {data["layout"]["fortress"]["height_u"]:g} u，轻转 {data["layout"]["fortress"]["yaw_relative_camera_deg"]:g}°，屏宽 {old_width:.1f}% → {width_pct:.1f}%。',
                f'树木 {len(previous["trees"])} → {len(data["trees"])} 棵：先校核 5 棵主树，额外 19 棵按附图估读；参考米数为建议，坐标 JSON 未附。',
                '现城堡资产宽深近 1:1，保留等比后比参考宽 42 / 深 20 的城市紧凑；未声称所有锚点吻合。',
            ]
        board(
            [earlier / f'{args.before_image}.png', capture_image],
            [f'{args.before} · 修改前', f'{args.checkpoint} · 当前'],
            comparison_title,
            comparison_lines,
            dest / 'before-after.png', args.height,
        )
        outputs.append('before-after.png')
    print(stats)
    print(tree_label)
    for name in outputs:
        path = dest / name
        print(f'{path}: {Image.open(path).size}')


if __name__ == '__main__':
    main()
