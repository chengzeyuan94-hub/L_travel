#!/usr/bin/env python3
"""Reconcile the layout study with its final actual GameScreen captures."""
from pathlib import Path
from collections import Counter
import argparse,hashlib,json
ROOT=Path(__file__).resolve().parents[2];LIB=ROOT/'docs/design/map-layout-021'
def read(p):return json.loads(Path(p).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,v):Path(p).write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--capture',type=Path,required=True);args=parser.parse_args()
    ev=Path('/Users/chengzeyuan/SilkRoadEvidence/map-layout-021');p=read(LIB/'placements.json');c=read(args.capture)
    assert len(p['landmarks'])==33 and not p['unresolved']
    assert len({x['asset_id'] for x in p['props']})==24
    assert p['generator_sha256']==sha(ROOT/'tools/lowpoly/layout_021_plan.py')
    assert c['placements_sha256']==sha(LIB/'placements.json') and c['script_sha256']==sha(ROOT/'tools/lowpoly/layout_021_preview.gd')
    assert c['inputs_stable'] and not c['errors'] and not c['capture_view_filter']
    assert len(c['captures'])==2*len(p['views'])
    assert c['layout_counts']['cities']==16 and c['layout_counts']['landmarks']==33 and c['layout_counts']['props']==len(p['props'])
    for f,h in c['asset_sha256'].items():
        path=ROOT/f.removeprefix('res://') if f.startswith('res://') else Path(f)
        assert sha(path)==h,f
    expected={(v['id'],phase) for v in p['views'] for phase in ['baseline','layout']}
    assert {(v['view_id'],v['phase']) for v in c['captures']}==expected
    for v in c['captures']:
        assert sha(v['preview'])==v['sha256'] and sha(v['raw'])==v['raw_sha256']
    baseline=read(ev/'baseline/input-start.json')['source_sha256']
    changed=[f for f,h in baseline.items() if not (ROOT/f).exists() or sha(ROOT/f)!=h]
    assert not changed,changed
    own=[];flags=[]
    for v in c['captures']:
        if v['phase']!='layout' or not v['view_id'].startswith('city_'):continue
        cid=v['view_id'].removeprefix('city_');city=next(x for x in v['cities'] if x['id']==cid)
        own.append({'city_id':cid,'tag_visible':city['tag_visible'],'tag_rect':city['tag_rect'],'image':v['preview']})
        assert city['tag_visible'],cid
        x,y,w,h=city['screen_rect']
        for a in v['landmarks']:
            if not a['hemisphere_visible'] or a['camera_distance']>=city['camera_distance']:continue
            ax,ay,aw,ah=a['screen_rect'];ix=max(0,min(x+w,ax+aw)-max(x,ax));iy=max(0,min(y+h,ay+ah)-max(y,ay))
            if ix*iy/max(w*h,1)>.15:flags.append({'city':cid,'landmark':a['id'],'aabb_overlap_fraction':ix*iy/max(w*h,1),'image':v['preview']})
    reservations=[a for a in p['landmarks'] if a.get('requires_land_extension')]
    summary={'task':'TASK-MAP-LAYOUT-021','status':'reviewable-layout-study','city_count':16,'landmarks':33,'props':len(p['props']),'prop_variants':24,'coast_reservations':[a['id'] for a in reservations],'city_scale':p['city_scale'],'views':len(p['views']),'actual_captures':len(c['captures']),'existing_files_unchanged':len(baseline),'own_city_labels_visible':len(own),'potential_screen_overlap_flags':flags,'production_integrated':False,'note':'AABB flags are review prompts, not per-pixel occlusion verdicts. Four coast adjustments and continuous terrain blending remain explicitly planned.'}
    write(LIB/'validation/summary.json',summary);write(LIB/'validation/focus-label-review.json',{'own_city_labels':own,'potential_overlaps':flags})
    write(LIB/'validation/capture-report.json',c)
    write(LIB/'validation/input-freeze.json',{'baseline':str(ev/'baseline/input-start.json'),'baseline_sha256':sha(ev/'baseline/input-start.json'),'existing_files':len(baseline),'changed':changed})
    catalog=read(LIB/'atlas-catalog.json');bycity={}
    for a in catalog['assets']:bycity.setdefault(a['city'],[]).append(a)
    table='\n'.join('| '+city+' | '+'、'.join(a['name']+('（岸形预留）' if a['reserved'] else '') for a in assets)+' |' for city,assets in bycity.items())
    text=f'''# 丝路星球 · 地图布局草案 021

建议采用“城市入口清楚、地标组成地域、低景物连接过渡”的布局。不是把33个景点均匀围着城市排一圈。已用真实018/019/020模型搭出可查看的GameScreen样板，尚未替换正式地图。

[打开布局图鉴](index.html) · [完整地理依据](geography-placement-notes.md) · [构图准则](composition-notes.md) · [摆放数据](placements.json)

## 当前样板

16座019城市，33件020命名地标，24款018基础造型共{len(p['props'])}个实例。城市统一以原尺寸的82%试排，保留位置和标签；GLB本身未缩放改写。总览、5个区域／外围机位和16个城市z2.6共{len(p['views'])}机位，原图与布局各一张，共{len(c['captures'])}张实际Compatibility渲染器截图。

## 五组地域组织

| 地域 | 布置重点 |
|---|---|
| 地中海—两河—红海 | 罗马拱渠与火口湖留在东南区，近远次序作地图压缩；海峡置城东侧、堡垒在北侧欧洲岸；河曲和枣椰衔接巴格达；金字塔在尼罗河西侧、农田沿南侧上游展开；珊瑚沿吉达以西近海／红海东岸展开；亚丁以火山口和蓄水池构成干旱边缘。 |
| 河西—帕米尔—高原 | 汉长城与雅丹在玉门关外侧；沙丘与慕士塔格分别取喀什东、西南；珠峰单列于德里东北、长安以西的高原区，样板隐藏旧昆仑独立造型并重新分配该视觉山系。 |
| 东亚城市与沿海 | 长安南侧为秦岭、东偏北为华山；泉州用花岗岩山景与平梁桥；庆州山丘与东海礁岸各据一侧；奈良东侧草坡与更远东北富士山需要扩展日本区域的岸形。 |
| 印度平原与南部岛区 | 德里岭与亚穆纳平原取城边不同方位；狮子岩和霍顿平原约束在狮子国显示节点南侧的区域，不能为了找陆脚搬到印度东岸。 |
| 东南亚湿地 | 洞里萨与荔枝山分出开阔洪泛林、砂岩高台；红树林与金石分别代表仰光西南三角洲和东北山地。 |

## 三层疏密

1. **城市入口与商道**：城前、路线节点和陆海双入口保留开口。基础岩石、矮灌木与草丛成组靠两侧，不铺满出入口。
2. **城市与区域之间**：命名地标错开城市主轮廓；低景物和疏林作过渡。天然形体保留宽窄和高低变化，避免所有景物变成等大的小圆盘。
3. **远景与背面**：泛形山丘、极地雪峰和少量云用于轮廓。命名地标仍集中在有商旅路线的区域，背面不接新玩法节点。

## 必须与地形一起处理的4处

- **若草山**：当前奈良东侧9点采样均在海面，按地理留位后需要拓宽本州局部岸形，保留南侧出海口。
- **富士山**：现日本东北区域陆块过窄，需与东北岛链连贯，而不是为找陆面向奈良西侧挪动。
- **霍顿平原**：南部岛区需要足够高地面积，与狮子岩成组，且避开更南侧的海运节点。
- **塔维拉蓄水池**：亚丁山麓需小范围补岸／整平，保留原有航道。

这4件已在图鉴和展开图以“岸形预留”标明。样板只呈现景观自身落脚面，未完成连续海岸重塑；不能把显示出来视作陆地接入验收。其余地标也仍有局部圆台材质边界，下一阶段要做连贯地表与河岸，不应继续靠增加同类摆件掩盖。

## 各城分配

| 节点 | 地标 |
|---|---|
{table}

## 验证与边界

摆放数据把初始方位／距离保留在 `source_proposal_intent`，最终 `display_distance_logical` 和 `display_bearing_degrees` 从已定坐标重新计算；它们是地图显示单位，不是地理公里。罗马湖泊与输水渠只保留同属东南景组，未照搬真实近远顺序。

摆放先核验地理扇区，再按当前实际terrain GLB做径向采样，使用球面圆脚与连续商道小弧计算保守净空；城市采用真实019 AABB外接半径。后续另看实际相机下的屏幕矩形和实拍，二维AABB重叠只是排查提示，不等于真实遮挡。16城自己的z2.6机位标签均可见。

运行时只复制新库mesh。018线性顶点色在Compatibility输出前转换为sRGB，修正棚拍与游戏渲染器之间的暗色差；灯光与原资产颜色均未改写。020低底缘按局部采样网格适配，上部保留刚体造型；这不替代最终的地形接缝制作。

旧零散sphere_scenery、旧昆仑独立模型和109旧走廊道具仅在布局相位隐藏；原地图相位恢复。原城市模型、规则坐标、50条路线、生产地形和三批库文件均保持原字节。{len(baseline):,}份既有输入检查未变。未运行正式全局玩法门禁，不据此声称性能或动态遮挡已达标。

## 后续落地顺序

1. 先做“玉门关—盘橐城—高原”和“泉州—金城—日本”两块样区，把山脚、低景物与陆岸连续接好，比较0.82城市比例。
2. 处理4处岸形预留，检查陆海入口与船舶路径；罗马两地标保持同一东南地域组。
3. 做全16城默认聚焦、近景4.2、选路高亮与载具经过检查，最后才接入正式地图并测动态性能。

## 打开可旋转的实机样板

可双击本目录的 [open-layout.command](open-layout.command)，或运行：

```sh
SILKROAD_LAYOUT_MODE=interactive /Applications/Godot.app/Contents/MacOS/Godot --path /Users/chengzeyuan/Developer/SilkRoad res://tools/lowpoly/layout_021_preview.tscn
```

拖动旋转，滚轮缩放，L切换原图／布局；上方选城市或区域，可分别切换城市、地标、城郊低景物、疏林、背景地形和云层。此工具是布局查看器，不写场景编辑结果。原始PNG和审阅证据在`{ev}`。
'''
    (LIB/'README.md').write_text(text)
    (ROOT/'docs/reports/task-map-layout-021.md').write_text(f'''# TASK-MAP-LAYOUT-021 · 地图布置草案

2026-09-10。承接用户要求，将018地形、019城市、020地标合并考虑地图摆放与布局。

交付[布局图鉴与决策](../design/map-layout-021/README.md)、可旋转的独立Godot样板、33地标逐项位置、24款基础地形{len(p['props'])}实例，以及{len(c['captures'])}张实际原图／布局对照。16城统一82%尺寸为布局试验变量，城市与路线节点不动。

4处地标需要岸形配合：若草山、富士山、霍顿平原、塔维拉。样板明确区分放置预留和连续地形接入完成；圆台材质边界尚需融合。16城z2.6各自标签可见，{len(baseline)}既有文件哈希不变。没有将AABB净空或结构导入当成完整遮挡与性能验收。

后续先完成两块样区的山脚／陆岸融合，再处理4处岸形、全城动态可读性与性能，最后接正式地图。本轮未替换生产、未提交或推送。
''')
    print(json.dumps(summary,ensure_ascii=False))
if __name__=='__main__':main()
