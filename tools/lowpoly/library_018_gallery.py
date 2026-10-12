#!/usr/bin/env python3
"""Build a local, dependency-free review gallery from final GLBs and captures."""
import argparse
import hashlib
import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / 'docs/design/terrain-library-018'
FAMILIES = {'trees':'树木','rocks':'岩石','greenery':'绿植','clouds':'云朵',
            'mountains':'山脉','snow-mountains':'雪山','hills':'丘陵'}
DESCRIPTIONS = {
 'tree_spruce':('层冠云杉','逐层收拢的枝冠、下垂枝缘与露出的根干。'),
 'tree_windswept':('风偏松','弯曲主干与错落的伞状树冠，保留枝间空隙。'),
 'tree_oak':('阔冠橡树','低处分叉的主干，托起不对称的厚实树冠。'),
 'palm_curved_a':('弯干棕榈','弯干、分节树皮与沿中肋展开的下垂叶。'),
 'palm_leaning_b':('鳞皮棕榈','更厚的干身、鳞片状树皮与密集叶冠。'),
 'rock_strata_a':('断层长岩','共同岩层被斜裂隙分开，碎石围绕主岩。'),
 'rock_weathered_b':('斜裂巨石','高低不等的岩肩与深裂口，底部留有侧台。'),
 'rock_ledge_c':('悬挑层岩','上层伸出的岩檐、下方凹进与边缘缺口。'),
 'shrub_oval_a':('宽叶灌丛','由内向外展开的宽叶，高低层叠。'),
 'shrub_spreading_b':('分枝灌木','可见枝干承托错落叶簇，轮廓向两侧展开。'),
 'grass_fan_a':('直立草丛','直立长叶与向外弯折的叶尖。'),
 'grass_rosette_b':('放射草丛','低矮根部与放射展开的宽叶。'),
 'cloud_drifter':('扁长浮云','横向舒展，中心厚、两端轻。'),
 'cloud_cumulus':('层叠积云','沿高度堆起的体块与不等大的云肩。'),
 'cloud_bank':('弧形云带','弧线连接的云体，尾部逐渐收细。'),
 'mountain_ridge':('锯齿长岭','连续峰脊、侧向扶壁与切入山体的沟谷。'),
 'mountain_massif':('三峰山块','紧凑的高低峰群与中间峡谷。'),
 'mountain_mesa':('双台地','两块不等高平顶岩台，连接低处坡脚。'),
 'snow_alpine':('裸岩高岭','裸露岩脊穿出积雪，雪线随坡面变化。'),
 'snow_glacier':('冰川山体','宽厚积雪沿谷地下行，形成冰舌。'),
 'snow_twin':('双峰鞍部','两座高峰之间留出深鞍部，雪岩交错。'),
 'hill_rolling':('连绵圆丘','圆润山包通过低鞍相连，坡面连续变化。'),
 'hill_crescent':('马蹄丘','弯曲丘脊围出向前敞开的低地。'),
 'hill_terraced':('层阶丘','绿坡与层阶交替，形成偏向一侧的坡面节奏。'),
}

def category(id):
    return next(value for prefix,value in [('tree_','trees'),('palm_','trees'),('rock_','rocks'),
               ('shrub_','greenery'),('grass_','greenery'),('cloud_','clouds'),
               ('mountain_','mountains'),('snow_','snow-mountains'),('hill_','hills')] if id.startswith(prefix))

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--audit',type=Path,required=True)
    p.add_argument('--partial',action='store_true')
    args=p.parse_args()
    audit=json.loads(args.audit.read_text())
    assert not audit['errors'], audit['errors']
    audited={a['id']:a for a in audit['assets']}
    models=[]
    for path in sorted(LIBRARY.glob('*-catalog.json')):
        for a in json.loads(path.read_text())['assets']:
            if a['id'] not in audited:
                continue
            record={**a,**audited[a['id']]}
            record['category']=category(a['id'])
            record['name'],record['description']=DESCRIPTIONS[a['id']]
            record['previews']={v:f"previews/{a['id']}-{v}.jpg" for v in ['three-quarter','side','top']}
            for key in ['glb','blend','concept']:
                assert (LIBRARY/record[key]).is_file(),record[key]
            assert hashlib.sha256((LIBRARY/record['glb']).read_bytes()).hexdigest()==record['sha256']
            for preview in record['previews'].values():
                assert (LIBRARY/preview).is_file(),preview
            models.append(record)
    if not args.partial:
        assert len(models)==24 and len({m['id'] for m in models})==24
        assert {c:sum(m['category']==c for m in models) for c in FAMILIES} == {
            'trees':5,'rocks':3,'greenery':4,'clouds':3,'mountains':3,'snow-mountains':3,'hills':3}
    models.sort(key=lambda m:(list(FAMILIES).index(m['category']),list(DESCRIPTIONS).index(m['id'])))
    catalog={'task':'TASK-TERRAIN-LIBRARY-018','status':'independent library; not integrated into map',
             'coordinate_system':'glTF Y-up, base Y=0; per-asset root or full-bounds horizontal anchor; Blender source Z-up',
             'families':FAMILIES,'model_count':len(models),'assets':models}
    (LIBRARY/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
    cards=[]
    for m in models:
        esc=html.escape
        cards.append(f'''<article data-family="{m['category']}">
<button class="picture" data-id="{m['id']}" aria-label="查看{m['name']}的大图"><img src="{m['previews']['three-quarter']}" alt="{m['name']} · Godot 实际模型渲染" loading="lazy"></button>
<div class="body"><div class="meta">{FAMILIES[m['category']]} <span>{m['triangles']:,} 三角面</span></div><h2>{m['name']}</h2><p>{m['description']}</p>
<div class="links"><button data-concept="{m['concept']}" data-name="{m['name']}">概念对照 ↗</button><a href="{m['glb']}" download>GLB ↓</a><a href="{m['blend']}" download>Blender ↓</a></div></div></article>''')
    filters='<button class="active" data-filter="all">全部 <small>'+str(len(models))+'</small></button>'
    filters+=''.join(f'<button data-filter="{c}">{name} <small>{sum(m["category"]==c for m in models)}</small></button>' for c,name in FAMILIES.items())
    doc='''<!doctype html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>丝路 · 地形资产库</title><style>
*{box-sizing:border-box}body{margin:0;background:#f4f2ec;color:#27382f;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}a,button{-webkit-tap-highlight-color:transparent}button,a{color:inherit}button{font:inherit;cursor:pointer}button:focus-visible,a:focus-visible{outline:3px solid #b46731;outline-offset:4px}header,main,footer{max-width:1280px;margin:auto;padding:0 36px}header{padding-top:38px;padding-bottom:26px}.eyebrow{letter-spacing:.17em;font-size:12px;color:#687367}.heading{display:flex;align-items:end;justify-content:space-between;gap:30px}h1{font-family:Georgia,"Songti SC",serif;font-weight:500;font-size:clamp(35px,5vw,52px);letter-spacing:-.03em;margin:17px 0 14px}.intro{font-size:16px;line-height:1.9;max-width:680px;color:#647066}.badge{white-space:nowrap;border:1px solid #c9cec1;padding:9px 12px;border-radius:6px;font-size:12px}.reference{font-size:12px;color:#6a746a;line-height:1.9;margin-top:15px}.reference a{text-underline-offset:3px}.toolbar{position:sticky;top:0;z-index:2;background:#f4f2ecf5;backdrop-filter:blur(12px);padding:16px 0;border-top:1px solid #d6dace;border-bottom:1px solid #d6dace;display:flex;justify-content:space-between;flex-wrap:wrap;gap:12px}.filters,.angles{display:flex;gap:5px;flex-wrap:wrap}.filters button,.angles button{background:none;border:0;border-radius:4px;padding:9px 11px;font-size:13px}.filters button.active{background:#344a3b;color:#fff}.filters small{opacity:.65;margin-left:4px;font-variant-numeric:tabular-nums}.angles{border:1px solid #cdd3c7;border-radius:5px}.angles button{font-size:12px;padding:7px 10px}.angles button.active{background:#e0e5d8}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:23px;margin-top:26px}article{background:#faf9f5;border:1px solid #e0e1d8;border-radius:8px;overflow:hidden}article[hidden]{display:none}.picture{display:block;padding:0;width:100%;border:0;background:#dedbd3;overflow:hidden}.picture img{display:block;width:100%;aspect-ratio:1;object-fit:cover;transition:transform .25s}.picture:hover img{transform:scale(1.035)}.body{padding:20px 22px 18px}.meta{font-size:11px;color:#7c847a;display:flex;justify-content:space-between}h2{font-weight:550;letter-spacing:.02em;font-size:20px;margin:10px 0}article p{font-size:13px;line-height:1.8;min-height:46px;color:#6a746a;margin:0}.links{display:flex;gap:15px;border-top:1px solid #e2e4da;margin-top:18px;padding-top:15px;align-items:center}.links a,.links button{font-size:11px;text-decoration:none;border:0;background:none;padding:0}.links button{margin-right:auto}.links a:hover,.links button:hover{text-decoration:underline}footer{padding-top:38px;padding-bottom:48px;font-size:12px;line-height:1.9;color:#7a8277}.footline{border-top:1px solid #d6dace;padding-top:24px;display:flex;justify-content:space-between;gap:30px}dialog{max-width:min(1100px,95vw);max-height:94vh;width:100%;border:0;border-radius:10px;padding:0;background:#f4f2ec;color:#27382f}dialog::backdrop{background:#15281ee0;backdrop-filter:blur(8px)}.dialogbar{padding:16px 22px;display:flex;align-items:center;justify-content:space-between}.dialogbar button{background:none;border:1px solid #c2cabd;border-radius:5px;padding:7px 12px}dialog img{display:block;max-width:100%;max-height:76vh;object-fit:contain;margin:auto}dialog p{font-size:12px;margin:14px 22px;color:#6a746a}@media(max-width:900px){.grid{grid-template-columns:repeat(2,1fr)}header,main,footer{padding-left:22px;padding-right:22px}.heading{display:block}.badge{display:inline-block;margin-bottom:8px}}@media(max-width:560px){.grid{grid-template-columns:1fr}.toolbar{position:static}.footline{display:block}header{padding-top:32px}article p{min-height:0}}@media(prefers-reduced-motion:reduce){.picture img{transition:none}}
</style></head><body><header><div class="eyebrow">SILK ROAD / ASSET STUDIES 018</div><div class="heading"><h1>地形资产库</h1><div class="badge">7 类造型 · 24 款模型</div></div><div class="intro">先把每一棵树、每一块岩石做清楚。<br>从概念设计到 Blender 建模，再以 Godot 实拍核对结构。</div><div class="reference">画面基准：<a href="https://signals.forwardfuture.com/astra-review/demos/little-planet/index.html">Little Planet</a> · <a href="https://signals.forwardfuture.com/astra-review/demos/seven-little-worlds/index.html">Seven Little Worlds</a>　 / 　<a href="reference-benchmark.md">参考拆解与制作标准</a></div></header><main><div class="toolbar"><nav class="filters" aria-label="资产类别">FILTERS</nav><div class="angles" aria-label="模型视角"><button class="active" data-angle="three-quarter">三分之四</button><button data-angle="side">侧面</button><button data-angle="top">顶部</button></div></div><section class="grid" aria-label="模型图库">CARDS</section></main><footer><div class="footline"><div>图中均为最终 GLB 的 Godot Forward+ 摄影棚实拍；点击“概念对照”查看生成图。<br>各模型独立取景，不表示地图中的相对大小。库中模型尚未铺入正式地图。</div><div><a href="README.md">交付说明</a> · <a href="catalog.json">资产目录</a><br>城市造型接在这批基础资产之后。</div></div></footer><dialog><div class="dialogbar"><strong id="dialog-title"></strong><button id="close">关闭 ×</button></div><img id="dialog-image" alt=""><p id="dialog-note"></p></dialog><script>
const assets=ASSETS;let angle='three-quarter';const dialog=document.querySelector('dialog');function show(src,title,note){document.querySelector('#dialog-image').src=src;document.querySelector('#dialog-image').alt=title;document.querySelector('#dialog-title').textContent=title;document.querySelector('#dialog-note').textContent=note;dialog.showModal()}
document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{document.querySelectorAll('[data-filter]').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('article').forEach(a=>a.hidden=b.dataset.filter!=='all'&&a.dataset.family!==b.dataset.filter)});
document.querySelectorAll('[data-angle]').forEach(b=>b.onclick=()=>{angle=b.dataset.angle;document.querySelectorAll('[data-angle]').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('.picture').forEach(p=>p.querySelector('img').src=assets.find(a=>a.id===p.dataset.id).previews[angle])});
document.querySelectorAll('.picture').forEach(b=>b.onclick=()=>{const a=assets.find(a=>a.id===b.dataset.id);show(a.previews[angle],a.name+' · 实际模型','Godot Forward+ 摄影棚导入最终 GLB 渲染；相机按模型尺寸取景，未替换正式地图。')});document.querySelectorAll('[data-concept]').forEach(b=>b.onclick=()=>show(b.dataset.concept,b.dataset.name+' · 概念设计','内置 ImageGen 生成的造型参考。图中每行左侧主视图优先；多个视图并非严格一致的工程正交图。'));
document.querySelector('#close').onclick=()=>dialog.close();dialog.addEventListener('click',e=>{if(e.target===dialog)dialog.close()});
</script></body></html>'''
    doc=doc.replace('FILTERS',filters).replace('CARDS','\n'.join(cards)).replace('ASSETS',json.dumps(models,ensure_ascii=False).replace('</','<\\/'))
    (LIBRARY/'index.html').write_text(doc)
    print(json.dumps({'models':len(models),'gallery':str(LIBRARY/'index.html')},ensure_ascii=False))

if __name__=='__main__': main()
