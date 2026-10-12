#!/usr/bin/env python3
"""Produce source-linked delivery notes after final asset verification."""
from pathlib import Path
import argparse,hashlib,json
ROOT=Path(__file__).resolve().parents[2];LIB=ROOT/'docs/design/landmark-library-020'
def read(p):return json.loads(Path(p).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,j):Path(p).write_text(json.dumps(j,ensure_ascii=False,indent=2)+'\n')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--evidence',type=Path,required=True);args=parser.parse_args();ev=args.evidence
    s=read(LIB/'validation/summary.json');catalog=read(LIB/'catalog.json');a=catalog['assets']
    concepts=[]
    westp=read(LIB/'concepts/west-prompts.json')['prompts'];westsrc={x['id']:x for x in read(LIB/'concepts/west-provenance.json')['images']}
    for group in ['east','south','west']:
        for n in range(1,4):
            cid=f'{group}-{n:02}';img=LIB/f'concepts/{cid}.png'
            if group=='east':
                p=LIB/f'concepts/{cid}.json';j=read(p);prompt=j['prompt'];source=j['source_path']
            elif group=='south':
                p=LIB/f'concepts/{cid}.provenance.json';j=read(p);prompt=(LIB/'concepts'/j['prompt']).read_text();source=j['original'];assert sha(img)==j['sha256']
            else:
                p=LIB/'concepts/west-prompts.json';j=westsrc[cid];prompt=westp[cid];source=j['source_image'];assert sha(img)==j['sha256']
            assert sha(img)==sha(source)
            concepts.append({'id':cid,'image':str(img.relative_to(LIB)),'sha256':sha(img),'source_image':source,'prompt':prompt,'prompt_record':str(p.relative_to(LIB)),'prompt_record_sha256':sha(p),'tool':'builtin image_gen.imagegen','model':'not exposed by builtin tool'})
    write(LIB/'concepts/index.json',{'task':s['task'],'sheets':concepts,'note':'Model selection is not exposed; no claim of image-2.5. AI concept sheets precede Blender modeling, and are not photos or final engine captures.'})
    bycity={}
    for x in a:bycity.setdefault(x['city'],[]).append(x)
    table='\n'.join(f"| {city} | {'、'.join(x['name'] for x in models)} |" for city,models in bycity.items())
    geom='\n'.join(f"| {x['name']} | {x['triangles']:,} | {x['primitives']} |" for x in a)
    text=f'''# 地理景观图鉴 · 020

为游戏的16个国家／城市节点各做2件景观，另加珠穆朗玛峰，共33件。沿用018基础地形、019城市精修的独立资产库顺序；此批尚未铺入正式地图。

[打开图鉴](index.html) · [完整地理清单与官方来源](geography-plan.md) · [模型目录](catalog.json) · [概念提示词与出处](concepts/index.json)

## 成品

- 9张 ImageGen 概念页，每页3–4件，全部保存原图及完整提示词。
- 33个独立GLB，3份可编辑Blender源文件，按资产ID分Collection。
- 99张实际Godot模型实拍，包含斜视、侧面、俯视，可按城市筛选、搜索或对照概念。
- 最终GLB共 **{s['triangles']:,}三角 / {s['surfaces']}材质表面 / {s['glb_bytes']:,}字节**。每件按材质合并；表面数不等同于游戏draw call，也不是整图帧率结论。

## 分配清单

| 游戏节点 | 两件景观（珠峰额外单列） |
|---|---|
{table}

“国家”在游戏中包含多个同国城市节点，因此长安、泉州、玉门关、盘橐城各配不同地域意象。local是该历史城市或当地地域，regional是明确标注的区域地标。富士山不是奈良近郊；慕士塔格属于喀什方向的帕米尔区域；真腊两景以暹粒—吴哥地区为参照。珠峰位于中尼边界，单列且不占德里的两个名额。各项官方依据、地理归纳方位和使用限制均保存在地理清单。

## 精修如何落到形体

山体采用不同主轮廓和侧脊：珠峰锐利、慕士塔格宽厚、富士山有顶口，秦岭是串联森林山脊。岩石的裂隙和肩部、砂岩崖台、沙丘迎风坡与滑落面都由几何表达。

河道和海岸保留连通关系：海峡两端开放、奥卜胡尔一端开海一端湾头，河曲有内弯沙洲，淡水洪泛林与潮汐红树林使用不同树干/根部造型。红海礁采用低水位的剖示式表达，方便读出珊瑚体；它不是真实水下透明度的物理模拟。

人文地标保留建造逻辑：汉长城取玉门关夯土遗存；洛阳桥是船形墩上的平石梁；罗马输水渠有拱洞与凹槽；塔维拉各级蓄水池有真实凹腔、连渠和阶梯。造型压缩了真实跨度、山系尺度和遗址数量，不是测绘复原，也不声称这些建筑处于同一历史年份。

概念图用来确定轮廓、空间层次与可见结构。生成图里的细密岩纹、砖缝和每片树叶没有逐一建成几何。出图使用内置ImageGen；接口未提供模型选择参数，不能据此称使用了指定“image-2.5”。

## 验证范围

最终GLB二进制逐三角读取，检查非退化、有限坐标、法线、正单位变换、底部Y=0与水平居中、材质合批和资源独立性。Godot实际导入 **{s['import_checks']['passed']}/{s['import_checks']['total']}**；三份Blender源实际重开后，33件mesh数量和三角数与导出相符。已有 **{s['unchanged_existing_inputs']:,}项执行输入未变化**，包括旧生产资产及018/019工具。

棚拍使用Godot4.7.1 Forward+ / Metal，768×768、MSAA4×与TAA、统一材质和灯光，逐件按边界取景。太阳角距0.8°、阴影距离25、相机far30；较宽4°半影在大块倾斜地形出现采样纹，因此收窄。显示大小不是模型之间的真实地理比例。侧视与俯视都是实际重新渲染，概念图不计入引擎实拍。

这是独立景观资产验收，不包含整图布局、球面贴地、城市/路线净距、遮挡点击、动态天气或跨设备性能。本轮未重跑正式全局门禁，不引用旧门禁数字冒充本轮结果。下一步接入地图时，应先按地理方位布置样区并核验标签和商道可读性。

## 编辑与复现

`source/east.blend`、`source/south.blend`、`source/west.blend`将资产排成便于编辑的阵列。展位平移仅存在源文件，导出GLB底部居中；手动导出须清除展位平移。推荐使用生成器，它只写本库，不覆盖生产：

```sh
/Users/chengzeyuan/Applications/Blender-5.2.1.app/Contents/MacOS/Blender --background --python-exit-code 1 --python tools/lowpoly/landmarks_020_common.py -- --group all
/Users/chengzeyuan/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 tools/lowpoly/landmarks_020_audit.py
/Users/chengzeyuan/Applications/Blender-5.2.1.app/Contents/MacOS/Blender --background --python-exit-code 1 --python tools/lowpoly/landmarks_020_source_check.py
```

几何生成器依赖Blender内置Python及既有018/019只读造型助手。独立审计需要NumPy。引擎导入与棚拍脚本为`tools/lowpoly/landmarks_020_import_check.gd`和`landmarks_020_capture.gd`；在外部scratch项目运行，按文件头传入库和输出路径。原始PNG、试验与日志位于`{ev}`，库中仅保留压缩JPEG预览；证据与文件哈希见`validation/evidence-manifest.json`。

## 各件几何

| 景观 | 三角面 | 材质表面 |
|---|---:|---:|
{geom}
'''
    (LIB/'README.md').write_text(text)
    report=f'''# TASK-LANDMARK-LIBRARY-020 · 地理景观精修

2026-09-10，承接用户“各国附近至少1–2件，先罗列后按019精度生成”的请求。33件独立景观已按16节点×2＋跨区域珠峰1完成，尚未铺入正式地图。

完整图鉴与文件说明：[020独立库](../design/landmark-library-020/README.md)。官方地理来源：[逐项清单](../design/landmark-library-020/geography-plan.md)。

交付9张概念、33GLB、3份Blender源、99张Godot三视图。最终{s['triangles']:,}三角、{s['surfaces']}材质表面，几何二进制审计与Godot实际导入{s['import_checks']['passed']}/{s['import_checks']['total']}通过，3份源实际重开核对，{s['unchanged_existing_inputs']:,}项原有执行输入不变。

地理规则：按游戏国家／城市节点配景，不虚构16个现代国家；区域地标保留regional标记；珠峰中尼边界单列，德里使用本地岩脊和亚穆纳河；长城采用玉门关汉代夯土语汇。真实比例、年代、跨数都作有说明的艺术压缩。

模型检查中修正了规则岩柱、尖锥峰体、圆台礁岩、断崖长扇齿和岸线不连续等形体问题。微纹理没有逐一复现；没有用概念图充当模型实拍，也不声称玩家无标签识别率或全地图性能。尚待地图集成时单独验证球面摆放、商道/城市净距、标签点击和动态性能。

证据目录：`{ev}`。本库使用`.gdignore`隔离，无生产替换，未提交或推送。
'''
    (ROOT/'docs/reports/task-landmark-library-020.md').write_text(report)
    print('020 delivery notes and 9 concept provenance records written')

if __name__=='__main__':main()
