#!/usr/bin/env python3
"""Build a geography-aware gallery of audited scenery and actual Godot captures."""
from pathlib import Path
import html,json
ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/landmark-library-020'
SCOPE={'local':'本地区域','regional':'区域地标','cross-regional':'跨区域地标'}
KIND={'natural':'自然地貌','cultural':'人文遗址','natural-cultural':'地貌与人文'}
DESCRIPTIONS={
 'han_great_wall':'低矮夯土残墙沿戈壁折转，墙身有收分和层理，烽燧独立抬高。',
 'dunhuang_yardangs':'同向延展的风蚀残丘，高低岩肩之间留出开敞风道。',
 'muztagh_ata':'宽厚冰穹向四周冰槽展开，裸岩扶壁与低处冰舌分出层次。',
 'taklamakan_dunes':'弯曲沙脊连接柔缓迎风坡和陡滑落面，连续谷地分开沙丘。',
 'delhi_ridge':'低矮斜向岩脊露出破碎石层，疏林留出干燥岩坡。',
 'yamuna_floodplain':'弯曲河道穿过低平漫滩，沙洲、草滩与河岸树群错开。',
 'sigiriya':'陡直孤岩托起顶台遗址与蓄水池，折返阶梯贴着岩肩上升。',
 'horton_plains':'开敞高地草坡延至陡崖，云雾林点缀边缘和湿润低地。',
 'irrawaddy_mangroves':'分汊潮沟穿过泥滩，树干与多支架根连接，树冠向外铺开。',
 'kyaiktiyo_golden_rock':'不规则金石偏心悬在崖缘，小接触面与顶部小塔保持清晰。',
 'everest':'锐利三面主峰连向侧脊，裸岩、雪舌、冰川谷沿不同坡向展开。',
 'roman_aqueduct':'连续真拱洞支撑顶部凹槽水渠，立柱落在自然草地与岩脚上。',
 'lake_albano':'不规则火口围出低处湖面，环坡、岸肩与疏林形成盆地轮廓。',
 'bosphorus_strait':'两岸高低不一，连续海峡在两端开放，岸边岩肩伸向水面。',
 'rumeli_fortress':'三座不同体量的圆塔由贴坡城墙连接，内部保留开敞院落。',
 'tigris_meander':'宽阔河曲绕过内弯沙洲，两岸平原与零散枣椰分布在外侧。',
 'date_palm_canals':'低处灌溉水渠连接成网，田块与弯干羽叶枣椰林交错。',
 'giza_pyramids':'三座不同体量的金字塔排列在岩台上，局部护面和底缘有缺损。',
 'nile_floodplain':'宽河贴着绿色农田带流过，规则田块在沙漠边缘展开。',
 'red_sea_reef':'浅礁台地与深水沟交错，枝状、桌状与团块珊瑚各有轮廓。',
 'obhur_inlet':'海口向内陆收窄成圆缓湾头，两侧浅色岩岸连续围合。',
 'shamsan_crater':'干燥破口火山环壁高低错落，岩肩与坡裙围出开敞盆底。',
 'tawila_cisterns':'不同标高的真实凹池由明渠串联，侧旁阶梯顺着山坡上行。',
}

def main():
    audit=json.loads((LIB/'validation/geometry-audit.json').read_text())
    assert not audit['errors'] and audit['model_count']==33 and not audit['partial']
    lookup={a['id']:a for a in audit['assets']}
    metadata=json.loads((LIB/'geography-plan.json').read_text())
    features={a['id']:a for group in ['east','south','west'] for a in json.loads((LIB/f'{group}-catalog.json').read_text())['assets']}
    assets=[]
    for m in metadata['assets']:
        a={**features[m['id']],**lookup[m['id']]}
        a['previews']={v:f"previews/{a['id']}-{v}.jpg" for v in ['three-quarter','side','top']}
        a['scope_label']=SCOPE[a['scope']];a['kind_label']=KIND[a['kind']]
        a['search_aliases']={'everest':'珠峰 Everest Qomolangma Sagarmatha 喜马拉雅',
                             'kyaiktiyo_golden_rock':'金石 仰光 Golden Rock',
                             'sigiriya':'锡吉里耶 狮子岩 Sri Lanka',
                             'han_great_wall':'Great Wall 长城 烽火台',
                             'mount_fuji':'Fuji 富士',
                             'muztagh_ata':'慕士塔格 Muztagh Ata 喀什'}.get(a['id'],'')
        for rel in [a['glb'],a['blend'],a['concept'],*a['previews'].values()]:assert (LIB/rel).is_file(),rel
        assets.append(a)
    catalog={'task':metadata['task'],'model_count':33,'city_nodes':16,'additional_cross_regional':1,'production_integrated':False,'assets':assets}
    esc=html.escape
    cards=[]
    for a in assets:
        feats=a.get('features',[])
        if isinstance(feats,dict):desc='；'.join(str(v) for v in list(feats.values())[:3])
        else:desc='；'.join(feats[:3]) if isinstance(feats,list) else str(feats)
        desc=DESCRIPTIONS.get(a['id'],desc)
        a['description']=desc
        cards.append(f'''<article data-city="{a['city_id']}" data-group="{a['group']}" data-id="{a['id']}">
<button class="picture" data-open="{a['id']}" aria-label="查看{esc(a['name'])}模型"><img src="{a['previews']['three-quarter']}" alt="{esc(a['name'])} · Godot模型斜视" loading="lazy"><span class="stamp">模型实拍 / 斜视</span></button>
<div class="body"><div class="meta"><span>{esc(a['city'])} · {a['kind_label']}</span><span class="scope {a['scope']}">{a['scope_label']}</span></div><h2>{esc(a['name'])}</h2><p class="detail">{esc(desc)}</p><p class="place">{esc(a['direction_note'])}</p><div class="links"><button data-geography="{a['id']}">地理与概念 ↗</button><a href="{a['glb']}" download>GLB</a><a href="{a['blend']}" download>Blender</a></div></div></article>''')
    (LIB/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
    cities=dict((a['city_id'],a['city']) for a in assets)
    options=''.join(f'<option value="{c}">{esc(n)}</option>' for c,n in cities.items())
    doc='''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>丝路商旅 · 地理景观图鉴 020</title><style>
:root{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Noto Sans SC",sans-serif;color:#303d35;background:#f5f2eb;color-scheme:light;font-synthesis:none}*{box-sizing:border-box}body{margin:0}button,input,select,a{font:inherit;color:inherit}button{cursor:pointer;touch-action:manipulation}button:focus-visible,a:focus-visible,select:focus-visible,input:focus-visible{outline:3px solid #ad754c;outline-offset:3px}header,main,footer{max-width:1370px;margin:auto;padding:0 40px}header{padding-top:52px;padding-bottom:30px}.eyebrow{font-size:11px;letter-spacing:.16em;color:#8b7960}h1{font-size:clamp(29px,4vw,45px);font-weight:550;letter-spacing:.03em;margin:17px 0}.intro{font-size:14px;line-height:1.9;color:#6f796c;max-width:750px}.stats{display:flex;gap:30px;margin-top:23px;font-size:12px;color:#73816f}.stats b{font-size:20px;font-weight:500;color:#3d5342;margin-right:6px}.toolbar{border-top:1px solid #d9d9cc;border-bottom:1px solid #d9d9cc;padding:15px 0;display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}.filters{display:flex;gap:10px;flex-wrap:wrap;align-items:center}select,input{border:1px solid #cdd2c1;background:#faf9f3;border-radius:5px;padding:10px 12px;font-size:12px;max-width:100%}input{width:180px}.views{display:flex;gap:3px;border:1px solid #cdd2c1;border-radius:5px;padding:2px}.views button,.dialogviews button{border:0;border-radius:4px;background:none;padding:9px 11px;font-size:12px}.views button.active,.dialogviews button.active{background:#dde4d6;color:#314b37}.status{display:flex;justify-content:space-between;gap:20px;padding:17px 0 0;font-size:12px;line-height:1.8;color:#7a8172}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:24px;margin-top:19px}article{border:1px solid #dfdfd3;border-radius:8px;overflow:hidden;background:#fbfaf5}article[hidden]{display:none}.picture{display:block;position:relative;border:0;padding:0;width:100%;background:#e1ddd4}.picture img{display:block;width:100%;aspect-ratio:1;object-fit:cover}.stamp{position:absolute;left:13px;top:13px;background:#f7f5eddf;padding:6px 8px;border-radius:4px;font-size:10px;color:#5a6754}.body{padding:19px 20px 16px}.meta{display:flex;justify-content:space-between;align-items:center;gap:7px;font-size:10px;color:#7c8673}.scope{border-radius:4px;padding:4px 5px;background:#e9eddf;white-space:nowrap}.scope.regional,.scope.cross-regional{background:#f0e5d2;color:#866238}h2{font-size:21px;font-weight:550;margin:11px 0 9px}.detail{font-size:12px;line-height:1.8;color:#6d7867;min-height:44px;margin:0}.place{font-size:11px;line-height:1.75;color:#8b897a;margin:12px 0 0;min-height:38px}.links{display:flex;align-items:center;gap:17px;border-top:1px solid #e1e3d5;padding-top:14px;margin-top:15px;font-size:11px}.links button{margin-right:auto;border:0;background:none;padding:0}.links a{text-decoration:none}.links a:hover,.links button:hover{text-decoration:underline}footer{padding-top:32px;padding-bottom:44px;color:#7a8171;font-size:12px;line-height:1.9}.footline{padding-top:23px;border-top:1px solid #d8dbcc;display:flex;justify-content:space-between;gap:26px}footer a{text-underline-offset:3px}dialog{border:0;border-radius:9px;background:#f5f2eb;color:#303d35;width:min(1160px,95vw);max-height:94vh;padding:0}dialog::backdrop{background:#17281fdc;backdrop-filter:blur(6px)}.dialogbar{padding:17px 22px;display:flex;gap:15px;justify-content:space-between;align-items:center}.dialogbar button{border:1px solid #c7cdbe;background:none;border-radius:4px;padding:7px 11px}.dialogmain{display:grid;grid-template-columns:minmax(0,1.25fr) minmax(0,1fr);gap:25px;padding:0 22px 23px}.model img{display:block;width:100%;max-height:69vh;object-fit:contain;background:#e1ddd4;border-radius:5px}.dialogviews{display:flex;justify-content:center;gap:7px;padding:8px 0}.info{font-size:13px;line-height:1.9}.info p{margin:0 0 14px}.info h3{font-size:13px;font-weight:600;margin:18px 0 7px}.info ul{padding-left:19px;font-size:12px}.info a{text-underline-offset:3px;overflow-wrap:anywhere}.info .concept{width:100%;display:block;border-radius:4px}.caption{font-size:11px;color:#828875;line-height:1.7;margin-top:8px}.empty{padding:45px;color:#6b7e65;text-align:center}.hidden{display:none!important}@media(max-width:990px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}header,main,footer{padding-left:24px;padding-right:24px}.dialogmain{gap:18px}}@media(max-width:610px){header{padding-top:31px}.grid{grid-template-columns:1fr}.stats{gap:17px}.status,.footline{display:block}.status>span{display:block}.status>span+span{margin-top:6px}.dialogmain{grid-template-columns:1fr}.model img{max-height:52vh}.dialogbar{padding:14px 17px}.dialogmain{padding:0 17px 20px}.filters{width:100%}input{flex:1;min-width:100px}.views{width:100%;justify-content:center}h2{font-size:22px}}
</style></head><body><header><div class="eyebrow">SILK ROAD / GEOGRAPHIC SCENERY 020</div><h1>让沿途风景，也有自己的名字</h1><div class="intro">从汉长城的夯土墙到喜马拉雅的冰川谷，从古罗马输水渠到红海浅礁。<br>为 16 个国家／城市节点各做 2 件典型景观，另加跨区域的珠穆朗玛峰。</div><div class="stats"><span><b>33</b>独立模型</span><span><b>9</b>概念设计页</span><span><b>99</b>引擎三视图</span></div></header><main><div class="toolbar"><div class="filters"><label for="city" class="hidden">国家或城市</label><select id="city" aria-label="国家或城市"><option value="all">全部国家／城市</option>OPTIONS</select><input id="search" type="search" placeholder="搜索景观或地区" aria-label="搜索景观或地区"></div><nav class="views" aria-label="模型查看角度"><button class="active" data-view="three-quarter" aria-pressed="true">斜视</button><button data-view="side" aria-pressed="false">侧面</button><button data-view="top" aria-pressed="false">俯视</button></nav></div><div class="status"><span id="count" aria-live="polite">33 件景观</span><span>画面来自实际 GLB · 统一灯光，逐件取景 · 点击看概念与地理依据</span></div><section class="grid" aria-label="地理景观模型">CARDS</section><p class="empty hidden">没有匹配的景观。试试其他名称，或切回全部国家／城市。</p></main><footer><div class="footline"><div>「区域地标」不等于城市近郊：富士山、慕士塔格等保留明确区域标注。<br>珠峰属于中尼边界景观，单列展示。模型为微缩地理意象，此库尚未铺入正式地图。</div><div><a href="geography-plan.md">完整地理清单与来源</a> · <a href="README.md">制作说明</a><br><a href="../city-library-019/index.html">城市精修库</a> · <a href="../terrain-library-018/index.html">基础地形库</a></div></div></footer><dialog><div class="dialogbar"><strong id="dialog-title"></strong><button id="close">关闭 ×</button></div><div class="dialogmain"><div class="model"><img id="model-image" alt=""><div class="dialogviews"><button data-dview="three-quarter">斜视</button><button data-dview="side">侧面</button><button data-dview="top">俯视</button></div><div class="caption" id="model-caption"></div></div><div class="info"><p id="dialog-place"></p><p id="dialog-geography"></p><h3>地理依据</h3><ul id="sources"></ul><h3>概念参考</h3><a id="concept-link" target="_blank" rel="noopener"><img class="concept" alt=""></a><div class="caption">ImageGen 造型参考，可点击放大。模型提炼轮廓与实体结构；图中的细密纹理没有逐一建模。地理说明以官方来源为准。</div></div></div></dialog><script>
const assets=ASSETS;const byId=id=>assets.find(a=>a.id===id);const viewNames={'three-quarter':'斜视',side:'侧面',top:'俯视'};let view='three-quarter',opened=null;const dialog=document.querySelector('dialog');
function filter(){const city=document.querySelector('#city').value,q=document.querySelector('#search').value.trim().toLowerCase();let n=0;document.querySelectorAll('article').forEach(card=>{const a=byId(card.dataset.id);const text=[a.name,a.city,a.region,a.id,a.direction_note,a.search_aliases].join(' ').toLowerCase();const show=(city==='all'||a.city_id===city)&&(!q||text.includes(q));card.hidden=!show;if(show)n++});document.querySelector('#count').textContent=n+' 件景观';document.querySelector('.empty').classList.toggle('hidden',n!==0)}
function refresh(){document.querySelectorAll('article').forEach(card=>{const a=byId(card.dataset.id);card.querySelector('img').src=a.previews[view];card.querySelector('img').alt=a.name+' · Godot模型'+viewNames[view];card.querySelector('.stamp').textContent='模型实拍 / '+viewNames[view]})}
function detailView(v){const a=byId(opened);const img=document.querySelector('#model-image');img.src=a.previews[v];img.alt=a.name+'实际GLB · '+viewNames[v];document.querySelectorAll('[data-dview]').forEach(b=>{b.classList.toggle('active',b.dataset.dview===v);b.setAttribute('aria-pressed',b.dataset.dview===v)});document.querySelector('#model-caption').textContent='Godot 实拍 · '+viewNames[v]+' · '+a.triangles.toLocaleString()+' 三角 / '+a.primitives+' 材质表面。逐件取景，不代表真实地理比例。'}
function openAsset(id){opened=id;const a=byId(id);document.querySelector('#dialog-title').textContent=a.name+' · '+a.city;document.querySelector('#dialog-place').textContent=a.scope_label+'｜'+a.direction_note;document.querySelector('#dialog-geography').textContent=a.geography_note;const ul=document.querySelector('#sources');ul.replaceChildren();a.sources.forEach(s=>{const li=document.createElement('li'),link=document.createElement('a');link.href=s.url;link.target='_blank';link.rel='noopener';link.textContent=s.title;li.appendChild(link);ul.appendChild(li)});const concept=document.querySelector('.concept');concept.src=a.concept;concept.alt=a.name+'所属概念组';document.querySelector('#concept-link').href=a.concept;detailView(view);dialog.showModal()}
document.querySelector('#city').onchange=filter;document.querySelector('#search').oninput=filter;document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>{view=b.dataset.view;document.querySelectorAll('[data-view]').forEach(x=>{x.classList.toggle('active',x===b);x.setAttribute('aria-pressed',x===b)});refresh()});document.querySelectorAll('[data-open]').forEach(b=>b.onclick=()=>openAsset(b.dataset.open));document.querySelectorAll('[data-geography]').forEach(b=>b.onclick=()=>openAsset(b.dataset.geography));document.querySelectorAll('[data-dview]').forEach(b=>b.onclick=()=>detailView(b.dataset.dview));document.querySelector('#close').onclick=()=>dialog.close();dialog.addEventListener('click',e=>{if(e.target===dialog)dialog.close()});
</script></body></html>'''
    doc=doc.replace('OPTIONS',options).replace('CARDS','\n'.join(cards)).replace('ASSETS',json.dumps(assets,ensure_ascii=False).replace('</','<\\/'))
    (LIB/'index.html').write_text(doc)
    print(json.dumps({'gallery':str(LIB/'index.html'),'models':len(assets)},ensure_ascii=False))
if __name__=='__main__':main()
