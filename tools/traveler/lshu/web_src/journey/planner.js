/* 480 structural recipes; no network, no embedded credentials. Y-up; metres. */
const Journey480 = (() => {
 'use strict';
 const C=JourneyCatalog, places=Object.fromEntries(C.places.map(x=>[x.id,x])), entries=C.recipes,
 byID=Object.fromEntries(entries.map(x=>[x.composition_id,x])), version=C.recipe_version;
 const original={check:StudioLayout.check,model:StudioLayout.model,recipe:StudioLayout.recipe};
 const {clamp,smooth,spline,nearest}=StudioLayout;
 const historyKey='lshu_travel480_history_v1';let history=[];
 try{const a=JSON.parse(localStorage.getItem(historyKey)||'[]');if(Array.isArray(a))history=a.filter(id=>typeof id==='string'&&byID[id]).slice(-1200);}catch{}
 function isNew(p){return p?.config_version===version||p?.config_version==='4.2.0';}
 function check(p){
  if(!isNew(p))return original.check(p);
  const e=byID[p.composition_id];
  if(!e||(p.config_version==='4.2.0'&&Number(p.composition_id.slice(1))>480)||p.version!==4||!(/^[a-zA-Z0-9]{1,20}$/).test(p.id||'')||p.scene_id!==e.scene_id||p.variant!==e.variant||p.profile!==e.profile||!Number.isInteger(p.seed)||p.seed<0||p.seed>4294967295||!StudioLayout.palettes[p.lighting])throw Error('无效旅行配方：编号、主景、布局和搭配必须匹配目录。');
  return p;
 }
 function recipe(cid,lighting='day',seed=null,id='p0'){
  const e=byID[cid];if(!e)throw Error('找不到旅行编号 '+cid);
  return check({id,version:4,config_version:version,composition_id:cid,scene_id:e.scene_id,variant:e.variant,profile:e.profile,seed:seed===null?e.seed:seed>>>0,lighting});
 }
 function markVisited(p){if(!isNew(p))return;if(history[history.length-1]!==p.composition_id)history.push(p.composition_id);history=history.slice(-1200);try{localStorage.setItem(historyKey,JSON.stringify(history));}catch{}}
 function historyInfo(){return {visited:new Set(history).size,total:C.count,recent:history.slice(-40),last_places:history.slice(-4).map(id=>byID[id].scene_id)};}
 function importHistory(a){if(!Array.isArray(a)||a.length>2000||a.some(x=>!byID[x]))throw Error('旅行记录格式无效');history=a.slice(-1200);try{localStorage.setItem(historyKey,JSON.stringify(history));}catch{}return historyInfo();}
 // Unseen recipes have priority; recency is relaxed only within the user's filter.
 function candidates(filter='any',lighting='auto',seed=1,count=8,variant='auto',profile='auto'){
  if(!['any','new','nature'].includes(filter)&&!places[filter])throw Error('未知地点筛选');
  let pool=entries.filter(e=>(filter==='any'||(filter==='new'&&places[e.scene_id].new_city)||(filter==='nature'&&!places[e.scene_id].new_city)||e.scene_id===filter)&&(variant==='auto'||e.variant===Number(variant))&&(profile==='auto'||e.profile===Number(profile)));
  const random=seeded(seed),lastPlaces=history.slice(-4).map(id=>byID[id].scene_id),seen=new Set(history),out=[];
  // Random rank is computed once, not inside a sort comparator.
  const ranks=new Map(pool.map(e=>[e.composition_id,random()]));
  while(out.length<Math.min(count,pool.length)){
   let remaining=pool.filter(e=>!out.some(p=>p.composition_id===e.composition_id));
   const unseen=remaining.filter(e=>!seen.has(e.composition_id));if(unseen.length)remaining=unseen;
   let fresh=remaining.filter(e=>!lastPlaces.includes(e.scene_id));if(fresh.length)remaining=fresh;
   let diverse=remaining.filter(e=>!out.some(p=>p.scene_id===e.scene_id));if(diverse.length)remaining=diverse;
   remaining.sort((a,b)=>ranks.get(a.composition_id)-ranks.get(b.composition_id));
   const chosen=remaining[0];let l=lighting==='auto'?Object.keys(StudioLayout.palettes)[Math.floor(random()*4)]:lighting;
   out.push(recipe(chosen.composition_id,l,null,'p'+out.length));
  }
  return out;
 }
 function describe(p){const e=byID[p.composition_id],d=places[p.scene_id];return {name:d.name,terrain:d.landform,layout:C.layouts[p.variant].name,activity:C.profiles[p.profile].name,asset:d.asset,composition_id:e.composition_id,lighting:p.lighting};}
 // Grid A* only finds a path to the OUTER arrival point. It never claims to solve
 // navigation through an opaque GLB. Harbor short segments may become boardwalks.
 function route(start,end,height,blocked,waterLevel=null){
  const N=40,step=8/N,key=(x,z)=>z*(N+1)+x,point=k=>[-4+(k%(N+1))*step,-4+Math.floor(k/(N+1))*step],
   cell=p=>[Math.round((clamp(p[0],-4,4)+4)/step),Math.round((clamp(p[1],-4,4)+4)/step)];
  const s=cell(start),t=cell(end),S=key(...s),T=key(...t),open=[S],g=new Map([[S,0]]),previous=new Map(),closed=new Set();let iterations=0;
  while(open.length&&iterations++<7000){
   let best=0,bestScore=Infinity;for(let i=0;i<open.length;i++){const p=point(open[i]),score=g.get(open[i])+Math.hypot(p[0]-end[0],p[1]-end[1]);if(score<bestScore){bestScore=score;best=i;}}
   const k=open.splice(best,1)[0];if(k===T){let path=[end],cur=k;while(cur!==S){path.push(point(cur));cur=previous.get(cur);if(cur===undefined)throw Error('路线回溯失败');}path.push(start);return path.reverse();}
   if(closed.has(k))continue;closed.add(k);const x=k%(N+1),z=Math.floor(k/(N+1)),p=point(k);
   for(const [dx,dz] of [[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,-1],[1,-1],[-1,1]]){
    const xx=x+dx,zz=z+dz;if(xx<0||zz<0||xx>N||zz>N)continue;const nk=key(xx,zz);if(closed.has(nk))continue;const q=point(nk);
    if(nk!==T&&nk!==S&&blocked(q[0],q[1]))continue;
    // No corner cutting across reserved footprints.
    if(dx&&dz&&(blocked(q[0],p[1])||blocked(p[0],q[1])))continue;
    const dist=Math.hypot(dx,dz)*step,dh=Math.abs(height(...q)-height(...p)),wet=waterLevel!==null&&height(...q)<waterLevel+.02;
    const cost=g.get(k)+dist+dh*3+(wet?.12:0);
    if(cost<(g.get(nk)??Infinity)){g.set(nk,cost);previous.set(nk,k);if(!open.includes(nk))open.push(nk);}
   }
  }
  throw Error('当前地形没有合理通路：'+start+' → '+end);
 }
 function resample(points,spacing=.075){const out=[points[0]];for(let i=1;i<points.length;i++){const a=points[i-1],b=points[i],n=Math.max(1,Math.ceil(Math.hypot(b[0]-a[0],b[1]-a[1])/spacing));for(let j=1;j<=n;j++)out.push([a[0]+(b[0]-a[0])*j/n,a[1]+(b[1]-a[1])*j/n]);}return out;}
 function model(p){
  if(!isNew(p))return original.model(p);check(p);
  const place=places[p.scene_id],form=C.layouts[p.variant],profile=C.profiles[p.profile],r=seeded(p.seed),R=(a,b)=>a+(b-a)*r(),
   data={p,catalog:true,place,profile,form,water:null,pads:[],peaks:[],paths:[],reserves:[],placements:[],surface_theme:place.theme==='snow'?'cabin':place.theme==='desert'?'canyon':place.theme==='harbor'?'cape':'autumn'};
  // Four travel kits affect the land and objects, not just the sky or colors.
  const lift=profile.terrain_delta,asset=ASSETS[place.asset];let scale=place.hero_scale??(place.enhanced?1:.70);
  if(['S01','S05','S06','S19'].includes(place.asset))scale=.75;
  let rx=place.enhanced?(place.id==='cabin'?1.16:.92):asset.size[0]*scale*.5,
   rz=place.enhanced?(place.id==='cabin'?1.0:.85):asset.size[2]*scale*.5;
  let hx=clamp(form.anchor[0],-3.65-rx*-1,3.65-rx),hz=clamp(form.anchor[1],-3.65+rz,1.0),hy=.24+form.rise*.48+lift*.4;
  if(place.theme==='harbor')hy=place.id==='cape'?1.22:.12;
  data.hero={x:hx,z:hz,y:hy,rx,rz,scale,yaw:0,width:rx*2,depth:rz*2,asset:place.asset};
  if(place.id!=='canyon')data.pads.push({x:hx,z:hz,h:hy,rx:rx+.08,rz:rz+.06,kind:'hero'});
  let campCandidates=[[-2.15,2.70],[2.05,2.65],[-2.55,1.4],[2.6,1.5],[0,2.95]];
  if(p.variant%2)campCandidates.reverse();
  const frontEnd=[hx,hz+rz+.20];
  let camp=campCandidates.find(([x,z])=>Math.abs(x-hx)>rx+1.18||Math.abs(z-hz)>rz+1.1)||[0,2.95];
  data.camp={x:camp[0],z:camp[1],rx:1.06,rz:.92,y:.23+lift*.45};
  if(place.theme==='harbor')data.camp.y=.28;
  data.pads.push({x:camp[0],z:camp[1],h:data.camp.y,rx:1.07,rz:.90,kind:'camp'});
  // One continuous landform. Large forms dominate; micro undulation stays restrained.
  let rawBase;
  if(place.id==='canyon'){
   const pts=[
    [[-1.25,4],[-.25,2.3],[.30,.8],[-.05,-1],[1.1,-4]],
    [[2,4],[1.5,2.2],[.5,.4],[.9,-1.7],[1.6,-4]],
    [[-2.1,4],[-1.1,2.6],[-.7,.3],[-1.3,-2],[-.6,-4]],
    [[3.9,2.2],[1.6,1.6],[.7,.1],[-.1,-1.8],[-1.65,-4]],
    [[-.4,4],[-1.15,2.3],[.55,.8],[.45,-1.3],[.25,-4]],
    [[-3.9,1.9],[-1.35,1.1],[.2,.6],[1.05,-1.4],[1.3,-4]]][p.variant];
   data.paths=[{id:'ancient_trail',points:spline(pts,100),width:.61+(p.profile===0?.04:0),kind:'dirt',connection:'前侧古道入口 → 岩壁谷底 → 另一侧出口'}];
   const rocksets=[
    [[-2.6,-2.2,1.06,3.2],[-.65,-2.95,.94,4.15],[2.65,-1.2,.90,3.12],[2.6,2.1,.80,2.4],[-2.6,.8,.8,2.34]],
    [[-2.65,-2.3,1.12,4],[-2.15,.15,1.06,3.25],[2.7,-2.75,.73,2.90],[-.5,-3.0,.90,3.45]],
    [[2.35,-1.5,1.08,4.0],[2.6,1.0,.90,2.75],[-2.6,-2.65,.77,3.22],[.2,-3.0,.95,3.3]],
    [[-2.5,1,1.0,2.45],[1.15,-2.7,1.1,4.15],[2.7,-.25,.80,3.2],[-2.35,-2.7,.9,3.0]],
    [[-2.5,-1.5,1.05,3.0],[2.5,-1.45,.99,3.75],[-.4,-3.0,.92,4.05],[2.6,1.35,.75,2.10]],
    [[-.25,-2.8,1.02,3.6],[2.8,-2.4,.8,4],[-2.6,-1.25,.90,3.4],[2.4,1.7,.9,2.85]]][p.variant];
   data.peaks=rocksets.map((a,i)=>({x:a[0],z:a[1],radius:a[2]*(1+p.profile*.025),height:a[3]*(1+lift*.35),phase:.65+i*.57,seed:p.seed+i*29}));
   for(const a of data.peaks){const n=nearest(data.paths[0].points,a.x,a.z),need=a.radius*1.18+.42;if(n.d<need){a.x+=(a.x<n.x?-1:1)*(need-n.d);}a.x=clamp(a.x,-3.82+a.radius*1.19,3.82-a.radius*1.19);}
   rawBase=(x,z)=>.12+.038*Math.sin(x*.65+z*.7)+data.peaks.reduce((v,a)=>v+(.35+lift*.3)*Math.exp(-((x-a.x)**2+(z-a.z)**2)/(a.radius*1.6)**2),0);
   // Put activity to a valid side of the corridor; keep the primary through-road.
   data.pads=data.pads.filter(a=>a.kind!=='hero');
  }else if(place.theme==='harbor'){
   data.water={level:.08};
   const side=p.variant===2||p.variant===3?1:-1;
   rawBase=(x,z)=>{const ax=camp[0],az=camp[1],dx=hx-ax,dz=hz-az,t=clamp(((x-ax)*dx+(z-az)*dz)/(dx*dx+dz*dz),0,1),D=Math.hypot(x-ax-t*dx,z-az-t*dz);return -.40+(.70+form.rise*.72)*Math.exp(-((x-hx)**2/(3.1+p.profile*.22)+(z-hz)**2/5.9))+.46*smooth(.6,4,-z)+.72*Math.exp(-((D/(1.06+p.profile*.035))**2));};
  }else{
   const type=place.landform;
   rawBase=(x,z)=>{
    let h=.13+.026*Math.sin(x*.85+z*.48);
    if(form.shape==='back_slope')h+=form.rise*smooth(.1,4,-z);
    if(form.shape==='left_terrace')h+=form.rise*.65*smooth(-1.5,3.8,-x);
    if(form.shape==='right_bank')h+=form.rise*.68*smooth(-1.5,3.8,x);
    if(form.shape==='diagonal')h+=form.rise*.72*smooth(-2,4,(-x-z)*.60);
    if(form.shape==='enclosed')h+=.35*(Math.exp(-((x+3.4)**2+(z+1)**2)/2.2)+Math.exp(-((x-3.3)**2+(z+.8)**2)/2.0));
    if(form.shape==='terraced_bend')h+=form.rise*(.40*smooth(.1,1.1,-z)+.45*smooth(1.9,2.65,-z));
    h+=lift*Math.exp(-((x-(p.profile%2?2.4:-2.4))**2+(z+.4)**2)/5);
    if(['ridge','hill','terrace'].includes(type))h+=.20*Math.exp(-((x-hx)**2+(z-hz)**2)/5.8);
    if(type==='dune'||type==='oasis')h+=.17*Math.exp(-((x-2.3)**2/2.8+(z+2)**2/5));
    return h;
   };
   if(place.id==='cabin'){
    const wx=p.variant%2===0?1.75:-1.75,wz=p.variant>=3?1.35:1.75;
    data.water={level:.06,x:wx,z:wz,rx:p.profile===1?1.25:1.48,rz:1.12};
    // Camp stays on the opposite bank; no flat pad in the center of the lake.
    data.camp.x=-Math.sign(wx)*2.2;data.camp.z=2.5;
    Object.assign(data.pads.find(a=>a.kind==='camp'),{x:data.camp.x,z:data.camp.z});
    const previous=rawBase,w=data.water;
    rawBase=(x,z)=>previous(x,z)-.63*(1-smooth(.50,1.35,((x-w.x)/w.rx)**2+((z-w.z)/w.rz)**2));
   }
  }
  const padded=(x,z)=>{let h=rawBase(x,z);for(const pad of data.pads){const dist=pad.kind==='camp'?((Math.abs(x-pad.x)/pad.rx)**4+(Math.abs(z-pad.z)/pad.rz)**4)**.25:Math.max(Math.abs(x-pad.x)/pad.rx,Math.abs(z-pad.z)/pad.rz);h+=(pad.h-h)*(1-smooth(1,1.42,dist));}return h;};
  const h=data.hero,cp=data.camp;
  // A fresh ground arrival point is OUTSIDE the visible landmark footprint.
  data.arrival=[h.x,h.z+h.rz+.24];
  if(place.id!=='canyon'){
   let start=form.entry.map(x=>clamp(x,-3.98,3.98));const end=data.arrival;
   if(place.theme==='harbor'&&padded(...start)<data.water.level+.06){
    const edges=[];for(let k=0;k<=40;k++){const n=-3.98+k*7.96/40;for(const q of [[n,-3.98],[n,3.98],[-3.98,n],[3.98,n]])if(padded(...q)>data.water.level+.12)edges.push(q);}
    if(edges.length){edges.sort((a,b)=>Math.hypot(a[0]-start[0],a[1]-start[1])-Math.hypot(b[0]-start[0],b[1]-start[1]));start=edges[0];}
   }
   const block=(x,z)=>Math.abs(x-h.x)<h.rx+.07&&Math.abs(z-h.z)<h.rz+.04||Math.abs(x-cp.x)<cp.rx+.15&&Math.abs(z-cp.z)<cp.rz+.15;
   const pts=route(start,end,padded,block,data.water?.level??null);
   data.paths.push({id:'arrival_path',points:resample(pts),width:place.theme==='snow'?.48:.53,kind:place.theme==='snow'?'snow':['ridge','terrace','hill'].includes(place.landform)||place.theme==='harbor'?'stone':'dirt',connection:'地块入口 → 地貌缓坡 → 主景外缘抵达点（不代表GLB内部导航）'});
  }
  for(const path of data.paths){let ys=path.points.map(p=>padded(...p)),maxGrade=path.kind==='stone'?.45:.32;
   for(let pass=0;pass<3;pass++){for(let i=1;i<ys.length;i++){const d=Math.hypot(path.points[i][0]-path.points[i-1][0],path.points[i][1]-path.points[i-1][1]);ys[i]=clamp(ys[i],ys[i-1]-maxGrade*d,ys[i-1]+maxGrade*d);}for(let i=ys.length-2;i>=0;i--){const d=Math.hypot(path.points[i][0]-path.points[i+1][0],path.points[i][1]-path.points[i+1][1]);ys[i]=clamp(ys[i],ys[i+1]-maxGrade*d,ys[i+1]+maxGrade*d);}}
   path.ys=ys;
  }
  const analytic=(x,z)=>{let h=padded(x,z);for(const path of data.paths){const n=nearest(path.points,x,z),idx=n.index,a=path.points[idx],b=path.points[idx+1],t=clamp(Math.hypot(n.x-a[0],n.z-a[1])/(Math.hypot(b[0]-a[0],b[1]-a[1])||1),0,1),y=path.ys[idx]*(1-t)+path.ys[idx+1]*t;h+=(y-h)*(1-smooth(path.width*.50,path.width*1.45,n.d));}return h;};
  const N=52,step=8/N,heights=Array.from({length:N+1},(_,j)=>Array.from({length:N+1},(_,i)=>analytic(-4+i*step,-4+j*step)));
  const height=(x,z)=>{x=clamp(x,-4,4);z=clamp(z,-4,4);let ix=Math.min(N-1,Math.floor((x+4)/step)),iz=Math.min(N-1,Math.floor((z+4)/step)),u=(x+4)/step-ix,w=(z+4)/step-iz,a=heights[iz][ix],b=heights[iz][ix+1],c=heights[iz+1][ix+1],d=heights[iz+1][ix];return u+w<=1?a+(b-a)*u+(d-a)*w:b*(1-w)+d*(1-u)+c*(u+w-1);};
  return Object.assign(data,{height,heights,N,step,analytic,pathDist:(x,z)=>Math.min(...data.paths.map(a=>nearest(a.points,x,z).d)),random:r});
 }
 for(const d of C.places)if(!StudioLayout.scenes[d.id])StudioLayout.scenes[d.id]={name:d.name,theme:d.theme,legacy:d.asset,sub:d.sub,layouts:C.layouts.map(x=>x.name),event:'主景外歇脚、扎营、喝茶或整理行装'};
 StudioLayout.check=check;StudioLayout.model=model;
 return {version,isNew,check,recipe,model,candidates,describe,markVisited,historyInfo,importHistory,getHistory:()=>history.slice(),places,entries,byID,C,original,resample};
})();
