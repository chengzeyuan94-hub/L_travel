#!/usr/bin/env python3
"""Build the city comparison gallery from audited exports and engine captures."""
import html
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/city-library-019'
DETAILS={
 'changan':('中轴城院','三座门楼、低侧廊与抬高的后殿，围出贯通的中央庭院。'),
 'heijokyo':('单塔寺院','五层独塔与主殿错开，深檐、柱廊和围墙形成不同高度。'),
 'geumseong':('观星台与暗瓦院','瓶形石台保留空顶和窗口，浅色石身与暗瓦院落互相衬托。'),
 'chenla':('三塔阶庙','塔身的凸角、凹门和退台连成阶梯，三座塔有清晰高低差。'),
 'quanzhou':('双石塔商港','八角双塔以石色层檐分节，红瓦门楼和廊院连接两侧。'),
 'yumenguan':('边关堡院','墙顶步道、开敞内院与烽燧分出层次，入口穿过真实门洞。'),
 'panti':('商队驿城','土堡后墙、厚布棚与水井围出可见的商队院，保留中央通道。'),
 'baghdad':('圆城与旋塔','圆形城墙围合蓝色穹顶，外突的螺旋坡与门洞形成第二轮廓。'),
 'cairo':('砂白拱院','高低尖塔、浅色穹顶和连续拱廊，围成开敞的方形庭院。'),
 'jeddah':('白塔木窗街','高低白色塔楼之间留出窄巷，木制阳台有凸出深度和支撑。'),
 'rome':('椭圆竞技场','多层外拱包围开放看台，放射通道打断原来的连续同心圆。'),
 'constantinople':('层叠穹顶群','中央穹顶、次级穹顶与扶壁逐级下降，入口廊形成阴影。'),
 'delhi':('赤色分节高塔','塔身的纵向起伏与挑台形成节奏，旁侧留出拱门和庭院。'),
 'aden':('岩崖阶地港','高堡、岩壁、阶梯街道和低处港廊相接，灯塔独立于岩丘。'),
 'simhala':('白色覆钵塔','宽厚绕行平台托起白色半球，正面阶梯和伞盖保持清晰。'),
 'dagon':('金色钟形塔','八角退台向钟形金塔收拢，宽阶梯与低亭衬出高耸轮廓。'),
}
GROUPS={'east':'东亚城院','caravan':'城关与商镇','landmarks':'地标与港城'}


def main():
    audit=json.loads((LIB/'validation/geometry-audit.json').read_text())
    assert not audit['errors'] and audit['model_count']==16
    lookup={a['id']:a for a in audit['assets']}
    assets=[]
    for cid,(motif,detail) in DETAILS.items():
        a=lookup[cid];a.update(motif=motif,description=detail)
        a['previews']={v:{'before':f'previews/before/{cid}-{v}.jpg','after':f'previews/{cid}-{v}.jpg'} for v in ['three-quarter','side','top']}
        for zoom in [26,42]:
            a['previews'][f'z{zoom}']={p:f'previews/map/{cid}-z{zoom}-{p}.jpg' for p in ['before','after']}
        for views in a['previews'].values():
            for path in views.values(): assert (LIB/path).is_file(),path
        for key in ['glb','blend','concept']: assert (LIB/a[key]).is_file(),a[key]
        assets.append(a)
    catalog={'task':'TASK-CITY-LIBRARY-019','status':'Independent city library; candidate models previewed in game only within evidence process, production assets unchanged.',
        'model_count':16,'assets':assets,'groups':GROUPS}
    (LIB/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
    esc=html.escape
    cards=[]
    for a in assets:
        cards.append(f'''<article data-group="{a['group']}" data-id="{a['id']}">
<button class="picture" data-open="{a['id']}" aria-label="比较{a['name']}的原版与精修版"><img src="{a['previews']['three-quarter']['after']}" alt="{a['name']}精修模型" loading="lazy"><span class="stamp">精修模型</span></button>
<div class="body"><div class="cardmeta"><span>{esc(a['motif'])}</span><span>{a['id'].upper()}</span></div><h2>{a['name']}</h2><p>{esc(a['description'])}</p><div class="links"><button data-concept="{a['id']}">概念设计 ↗</button><a href="{a['glb']}" download>模型 GLB</a><a href="{a['blend']}" download>Blender 源文件</a></div></div></article>''')
    doc='''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>丝路商旅 · 城市辨识度</title><style>
:root{color-scheme:light;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Noto Sans SC",sans-serif;color:#303c34;background:#f5f2eb;font-synthesis:none}*{box-sizing:border-box}body{margin:0}button,a{font:inherit;color:inherit}button{cursor:pointer}button:focus-visible,a:focus-visible{outline:3px solid #af714c;outline-offset:4px}button{touch-action:manipulation}header,main,footer{max-width:1320px;margin:auto;padding:0 42px}header{padding-top:54px;padding-bottom:32px}.eyebrow{font-size:11px;letter-spacing:.18em;color:#8a765f}.heading{display:flex;align-items:center;justify-content:space-between;gap:20px}h1{font-weight:550;font-size:clamp(30px,4vw,46px);line-height:1.3;letter-spacing:.03em;margin:18px 0 16px}.badge{font-size:12px;border:1px solid #d5cbbc;border-radius:5px;padding:10px 13px;white-space:nowrap}.intro{font-size:14px;line-height:1.9;color:#71776b;max-width:730px}.stats{display:flex;gap:32px;padding-top:22px;color:#748071;font-size:12px}.stats b{color:#3e5242;font-size:19px;font-weight:500;margin-right:6px}.toolbar{position:sticky;top:0;z-index:2;background:#f5f2ebf7;backdrop-filter:blur(12px);padding:15px 0;border-top:1px solid #dbd9cc;border-bottom:1px solid #dbd9cc;display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between}.filters,.views,.revisions{display:flex;gap:3px;flex-wrap:wrap}.filters button,.views button,.revisions button{border:0;background:none;border-radius:4px;padding:9px 10px;font-size:12px}.filters button.active{background:#3e5143;color:white}.filters small{opacity:.7;margin-left:5px}.views{border:1px solid #d6d7c9;border-radius:5px;padding:2px}.views button.active{background:#e0e5d8}.switchrow{display:flex;justify-content:space-between;align-items:center;padding-top:18px;gap:14px;flex-wrap:wrap}.switchrow p{font-size:12px;color:#7c8074;line-height:1.7;margin:0}.revisions{border-bottom:1px solid #d9d7ca}.revisions button{border-radius:0}.revisions button.active{border-bottom:2px solid #5d705c;color:#334a37}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:24px;margin-top:20px}article{border:1px solid #dfded3;border-radius:8px;overflow:hidden;background:#fbfaf5}article[hidden]{display:none}.picture{display:block;position:relative;width:100%;border:0;padding:0;background:#e1ddd4}.picture img{display:block;width:100%;aspect-ratio:1;object-fit:cover}.stamp{position:absolute;top:14px;left:14px;font-size:10px;background:#f7f5eddf;color:#53624f;padding:6px 8px;border-radius:4px}.body{padding:20px 21px 18px}.cardmeta{display:flex;justify-content:space-between;gap:10px;font-size:10px;color:#89907e}.cardmeta span:last-child{letter-spacing:.06em;font-size:9px}h2{margin:10px 0 8px;font-weight:550;font-size:21px}article p{font-size:12px;line-height:1.85;color:#73796b;min-height:45px;margin:0}.links{display:flex;gap:14px;align-items:center;border-top:1px solid #e2e3d7;padding-top:15px;margin-top:18px;font-size:10px}.links a{text-decoration:none}.links button{padding:0;background:none;border:0;font-size:11px;margin-right:auto}.links a:hover,.links button:hover{text-decoration:underline}footer{padding-top:34px;padding-bottom:46px;font-size:12px;color:#7e8376;line-height:1.9}.footline{border-top:1px solid #d9d9cd;padding-top:24px;display:flex;gap:30px;justify-content:space-between}footer a{text-underline-offset:3px}dialog{border:0;border-radius:9px;padding:0;background:#f5f2eb;color:#303c34;width:min(1160px,95vw);max-height:94vh}dialog::backdrop{background:#18291ede;backdrop-filter:blur(7px)}.dialogbar{display:flex;justify-content:space-between;align-items:center;padding:17px 22px;gap:18px}.dialogbar button{background:none;border:1px solid #c4cbbb;border-radius:4px;padding:7px 12px}.compare{display:grid;grid-template-columns:1fr 1fr;gap:2px;background:#d4d6c8}.compare figure{margin:0;min-width:0;background:#e1ddd4}.compare img{display:block;width:100%;max-height:69vh;object-fit:contain}.compare figcaption{padding:12px 18px;font-size:12px;background:#f5f2eb}.concept{display:block;margin:auto;max-width:100%;max-height:76vh;object-fit:contain}.note{font-size:12px;line-height:1.8;margin:16px 22px;color:#737c6b}.hidden{display:none!important}@media(max-width:950px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}header,main,footer{padding-left:24px;padding-right:24px}.heading{display:block}.badge{display:inline-block;margin-bottom:14px}.toolbar{position:static}}@media(max-width:560px){.grid{grid-template-columns:1fr}.stats{gap:17px}.footline{display:block}.compare{grid-template-columns:1fr}.compare img{max-height:45vh}header{padding-top:30px}.views{gap:0}.views button{padding:8px}}
</style></head><body><header><div class="eyebrow">SILK ROAD / CITY STUDIES 019</div><div class="heading"><h1>让每座城都有自己的轮廓</h1><span class="badge">16 座城市 · 精细化模型库</span></div><div class="intro">从门洞、庭院到塔檐和街巷，把地标的结构做清楚。<br>点击城市并排比较原模型与精修版，也可以切到地图视角，查看实际缩放下的区别。</div><div class="stats"><span><b>16</b>独立模型</span><span><b>3</b>概念设计组</span><span><b>2</b>地图缩放档位</span></div></header><main><div class="toolbar"><nav class="filters" aria-label="城市类别"><button class="active" data-filter="all">全部<small>16</small></button><button data-filter="east">东亚城院<small>5</small></button><button data-filter="caravan">城关与商镇<small>5</small></button><button data-filter="landmarks">地标与港城<small>6</small></button></nav><nav class="views" aria-label="查看角度"><button class="active" data-view="three-quarter">斜视</button><button data-view="side">侧面</button><button data-view="top">俯视</button><button data-view="z26">地图 2.6×</button><button data-view="z42">地图 4.2×</button></nav></div><div class="switchrow"><p id="view-note">统一尺度与灯光的模型实拍；点击图片查看前后对照。</p><div class="revisions" aria-label="模型版本"><button class="active" data-revision="after">精修版</button><button data-revision="before">原模型</button></div></div><section class="grid" aria-label="城市模型">CARDS</section></main><footer><div class="footline"><div>模型图均来自实际导出的 GLB；概念图单独展示。<br>地图对照保持原灯光、相机与尺寸，在验收进程中临时换入候选模型。此模型库尚未替换正式地图。</div><div><a href="README.md">制作与交付说明</a> · <a href="catalog.json">资产目录</a><br><a href="../terrain-library-018/index.html">上一批：地形资产库 ↗</a></div></div></footer><dialog><div class="dialogbar"><strong id="dialog-title"></strong><button id="close">关闭 ×</button></div><div class="compare"><figure><img id="old" alt=""><figcaption>原模型 · 同机位</figcaption></figure><figure><img id="new" alt=""><figcaption>精修模型 · 同机位</figcaption></figure></div><img class="concept hidden" alt=""><p class="note"></p></dialog><script>
const assets=ASSETS;let view='three-quarter',revision='after';const dialog=document.querySelector('dialog');const byId=id=>assets.find(a=>a.id===id);const viewNames={'three-quarter':'斜视',side:'侧面',top:'俯视',z26:'地图 2.6×',z42:'地图 4.2×'};
function refresh(){document.querySelectorAll('article').forEach(card=>{const a=byId(card.dataset.id);card.querySelector('img').src=a.previews[view][revision];card.querySelector('img').alt=a.name+(revision==='after'?'精修':'原版')+viewNames[view];card.querySelector('.stamp').textContent=(revision==='after'?'精修模型':'原模型')+' / '+viewNames[view]});document.querySelector('#view-note').textContent=view.startsWith('z')?'正式地图原相机与原光照，384 像素裁切；点击查看同位置对照。':'统一尺度与灯光的模型实拍；点击图片查看前后对照。'}
document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{document.querySelectorAll('[data-filter]').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('article').forEach(x=>x.hidden=b.dataset.filter!=='all'&&x.dataset.group!==b.dataset.filter)});
document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>{view=b.dataset.view;document.querySelectorAll('[data-view]').forEach(x=>x.classList.toggle('active',x===b));refresh()});document.querySelectorAll('[data-revision]').forEach(b=>b.onclick=()=>{revision=b.dataset.revision;document.querySelectorAll('[data-revision]').forEach(x=>x.classList.toggle('active',x===b));refresh()});
document.querySelectorAll('[data-open]').forEach(b=>b.onclick=()=>{const a=byId(b.dataset.open);document.querySelector('#dialog-title').textContent=a.name+' · '+viewNames[view]+'对照';document.querySelector('.compare').classList.remove('hidden');document.querySelector('.concept').classList.add('hidden');for(const [id,phase] of [['old','before'],['new','after']]){const i=document.querySelector('#'+id);i.src=a.previews[view][phase];i.alt=a.name+(phase==='before'?'原模型':'精修模型')}document.querySelector('.note').textContent=a.description+(view.startsWith('z')?' 图中动态粒子在两侧同时隐藏，尚未验证烟雾锚点。':' 摄影棚为统一 Forward+ 光照，地图视角使用项目原 Compatibility 渲染。');dialog.showModal()});
document.querySelectorAll('[data-concept]').forEach(b=>b.onclick=()=>{const a=byId(b.dataset.concept);document.querySelector('#dialog-title').textContent=a.name+' · 概念设计';document.querySelector('.compare').classList.add('hidden');const i=document.querySelector('.concept');i.classList.remove('hidden');i.src=a.concept;i.alt=a.name+'所属概念设计组';document.querySelector('.note').textContent='ImageGen 生成的造型参考。模型提取轮廓、层次与负空间；图中的细密石缝、瓦纹和装饰并非全部建成几何，也不作为历史复原依据。';dialog.showModal()});document.querySelector('#close').onclick=()=>dialog.close();dialog.addEventListener('click',e=>{if(e.target===dialog)dialog.close()});
</script></body></html>'''
    doc=doc.replace('CARDS','\n'.join(cards)).replace('ASSETS',json.dumps(assets,ensure_ascii=False).replace('</','<\\/'))
    (LIB/'index.html').write_text(doc)
    print(json.dumps({'gallery':str(LIB/'index.html'),'models':len(assets)},ensure_ascii=False))

if __name__=='__main__': main()
