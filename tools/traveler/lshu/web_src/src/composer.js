/* Closed, reproducible scene recipes with real asset IDs. No model call here. */
const THEMES={snow:{name:'雪地旅途',title:'在雪松间，歇一歇',sub:'雪落得很轻，茶还是热的。'},autumn:{name:'林野山地',title:'风把秋天带过来',sub:'不赶路的时候，也在旅行。'},desert:{name:'沙漠古道',title:'沙海里的一点绿',sub:'一株新芽，和远方一样大。'},harbor:{name:'海岸停泊',title:'等一阵出发的风',sub:'帆还未远去，故事已经开始。'}};
const TIMES={day:'晴朗白昼',sunset:'温暖夕照',night:'静谧蓝夜'};
const LAYOUTS={clearing:'后高前低，营地在前',edge:'偏侧围合，中央留白',path:'沿浅径错落展开'};
function seeded(seed){let a=seed>>>0;return()=>{a+=0x6D2B79F5;let t=a;t=Math.imul(t^(t>>>15),t|1);t^=t+Math.imul(t^(t>>>7),t|61);return((t^(t>>>14))>>>0)/4294967296;};}
function randomSeed(){const x=new Uint32Array(1);crypto.getRandomValues(x);return x[0];}
let CATALOG=null,ASSETS={};
function setCatalog(c){CATALOG=c;ASSETS=Object.fromEntries(c.assets.map(a=>[a.id,a]));}
function terrainHeight(theme,v,x,z){const h=(xx,zz)=>theme==='harbor'?.88+.02*Math.sin(xx*1.5+zz*.8+v):.88+.035*Math.sin(xx*.9+v)*Math.cos(zz*.6)+.18*Math.exp(-((xx+1.9-v*.8)**2/2.6+(zz+2)**2/2));
 // Match the mesh's diagonal and barycentric interpolation, not just the analytic surface.
 if(theme==='harbor'&&z<-2.5)return 1.02-.88;
 const step=8/12,ix=Math.min(11,Math.max(0,Math.floor((x+4)/step))),iz=Math.min(11,Math.max(0,Math.floor((z+4)/step))),x0=-4+ix*step,z0=-4+iz*step,u=(x-x0)/step,w=(z-z0)/step;
 const a=h(x0,z0),b=h(x0+step,z0),c=h(x0+step,z0+step),d=h(x0,z0+step);
 return (u+w<=1?a*(1-u-w)+b*u+d*w:b*(1-w)+d*(1-u)+c*(u+w-1))-.88;
}
function makeLegacyRecipe(theme,time,seed,id='p0',layout=null){
 if(!CATALOG)throw Error('素材目录尚未载入');
 const r=seeded(seed),pick=a=>a[Math.floor(r()*a.length)],rr=(a,b)=>a+(b-a)*r();
 const pool=(role)=>CATALOG.assets.filter(a=>a.themes.includes(theme)&&a.role===role);
 const selectedBase=pick(pool('base')),v=selectedBase.variant;layout=layout||pick(Object.keys(LAYOUTS));
 const p={id,version:2,seed,theme,time,layout,density:'sparse',action:theme==='harbor'?'look':theme==='desert'?'bloom':r()<.7?'tea':'look',detailVariant:v,placements:[],character:null};
 const occupied=[];const gh=(x,z)=>terrainHeight(theme,v,x,z);
 function rect(a,x,z,s,rot){return {x,z,hx:(Math.abs(Math.cos(rot))*a.size[0]+Math.abs(Math.sin(rot))*a.size[2])*s*.5,hz:(Math.abs(Math.sin(rot))*a.size[0]+Math.abs(Math.cos(rot))*a.size[2])*s*.5};}
 function free(a,x,z,s,rot){let b=rect(a,x,z,s,rot);return Math.abs(x)+b.hx<3.92&&Math.abs(z)+b.hz<3.92&&occupied.every(o=>Math.abs(o.x-x)>o.hx+b.hx+.10||Math.abs(o.z-z)>o.hz+b.hz+.10);}
 function put(a,x,z,s=1,rot=0,y=null,solid=true){const q={id:a.id,position:[x,y===null?gh(x,z)-.012:y,z].map(n=>+n.toFixed(4)),scale:s,rotationY:+rot.toFixed(4),role:a.role};p.placements.push(q);if(solid)occupied.push(rect(a,x,z,s,rot));return q;}
 function scattered(role,points,s=.75){for(const pos of points){let a=pick(pool(role));for(let t=0;t<18;t++){let x=pos[0]+rr(-.30,.30),z=pos[1]+rr(-.23,.23),rot=rr(-.6,.6),scale=s*rr(.9,1.1);if(free(a,x,z,scale,rot)){put(a,x,z,scale,rot);break;}}}}
 put(selectedBase,0,0,1,0,-.88,false);
 if(theme==='harbor'){
  const dock=pick(pool('dock')),x=layout==='edge'?.65:0;let d=put(dock,x,-.15,1,0,-.28,true);
  p.character={position:[x,d.position[1]+dock.sockets.stand[1],.35],yaw:.3,scale:.72,action:'look',support:dock.id};
  put(pick(pool('boat')),-2.15,.45,1,rr(-.23,.20),gh(-2.15,.45)-.02,true);
  if(r()<.5)put(pick(pool('boat')),2.5,1.95,.85,rr(-.22,.15),gh(2.5,1.95)-.02,true);
  scattered('backdrop',[[-2.7,-3.25],[1.3,-3.3]],.72);
  scattered('rock',[[-3.2,2.5],[3,-3.1],[2.8,-1.1]],.55);
  put(pick(pool('dock_prop')),x-.3,-.9,.65,0,d.position[1]+dock.sockets.stand[1],false);
  put(pick(pool('lamp')),x+.4,.38,1,0,d.position[1]+dock.sockets.stand[1],false);
 }else{
  if(theme==='desert'){
   const hx=layout==='edge'?-1.35:layout==='path'?.35:0;put(pick(pool('hero')),hx,-1.65,1,rr(-.28,.28));
   if(layout!=='edge'&&r()<.55)put(ASSETS.P08,2.62,-1.25,.70,rr(-.15,.15));else scattered('backdrop',[[2.6,-2.5]],.8);
  }else{
   const tx=layout==='edge'?-1.50:layout==='path'?-.90:-1.15,tz=layout==='edge'?-1.00:-.65;
   put(pick(pool('shelter')),tx,tz,.90,rr(-.1,.3));
   const spots=layout==='path'?[[-2.6,-2.75],[.1,-2.7],[2.6,-2.1]]:[[-2.8,-2.60],[-.15,-2.85],[2.5,-2.4]];
   scattered('backdrop',spots,.78);
  }
  const cx=layout==='edge'?-.55:-.70,cz=1.15;
  if(p.action==='tea'){
   const seat=pick(pool('seat')),sp=put(seat,cx,cz,.86,0);const seatY=sp.position[1]+seat.sockets.seat[1]*sp.scale;
   p.character={position:[cx,+(seatY-.54*.74).toFixed(4),cz],yaw:.22,scale:.74,action:'tea',support:seat.id};
  }else{p.character={position:[cx,gh(cx,cz)-.006,cz],yaw:p.action==='bloom'?-.15:.3,scale:.78,action:p.action,support:'ground'};occupied.push({x:cx,z:cz,hx:.4,hz:.4});}
  put(pick(pool('fire')),1.05,1.50,1,rr(-.3,.3));
  put(pick(pool('lamp')),-1.7,1.20,1,0);
  scattered('rock',[[-3.02,-.1],[2.85,.10],[-2.2,2.85],[2.85,2.80]],.65);
  if(r()<.80){let a=pick(pool('prop'));if(free(a,2.65,-.65,1,0))put(a,2.65,-.65,1,.1);}
 }
 // A few small accents, not a carpet of noise. Harbor accents stay on the rear beach.
 scattered('detail',theme==='harbor'?[[-1.8,-3.05],[2.4,-3.1]]:[[-2.85,1.75],[2.3,2.8],[1.85,-.7]],.85);
 p.asset_ids=[...new Set(p.placements.map(o=>o.id))];return p;
}
function makeLegacyCandidates(theme='any',time='auto',seed=randomSeed()){
 const r=seeded(seed),keys=theme==='any'?Object.keys(THEMES):[theme];return Array.from({length:8},(_,i)=>makeLegacyRecipe(keys[i%keys.length],time==='auto'?Object.keys(TIMES)[Math.floor(r()*3)]:time,Math.floor(r()*4294967295),'p'+i));
}
function describeLegacyRecipe(p){return `${THEMES[p.theme].name} · ${TIMES[p.time]} · ${LAYOUTS[p.layout]} · ${p.action==='tea'?'坐着喝茶':p.action==='bloom'?'手捧土豆花':'远望'} · ${p.placements.length}件素材`;}
function checkLegacyRecipe(p){
 if(!p||p.version!==2||!THEMES[p.theme]||!TIMES[p.time]||!LAYOUTS[p.layout]||!Array.isArray(p.placements)||p.placements.length>26)throw Error('无效配方');
 if(!p.character||p.character.action!==p.action)throw Error('人物动作不一致');
 for(const v of p.placements){if(!ASSETS[v.id]||!ASSETS[v.id].themes.includes(p.theme))throw Error('素材与主题不兼容');if(v.position.length!==3||v.position.some(x=>!Number.isFinite(x))||!Number.isFinite(v.scale)||v.scale<=0||v.scale>2)throw Error('变换参数无效');}
 return p;
}

/* V3: one primary landmark anchors every new composition. Old v2 recipes still load. */
function makeRecipe(theme,time,seed,id='p0',layout=null,landmarkId=null){
 if(!CATALOG)throw Error('素材目录尚未载入');
 const r=seeded(seed),pick=a=>a[Math.floor(r()*a.length)],rr=(a,b)=>a+(b-a)*r();
 let heroes=CATALOG.assets.filter(a=>a.role==='landmark'&&a.themes.includes(theme));
 let hero=landmarkId?ASSETS[landmarkId]:pick(heroes);
 if(!hero||hero.role!=='landmark'||!hero.themes.includes(theme))throw Error('主景与环境不兼容');
 const pool=role=>CATALOG.assets.filter(a=>a.role===role&&a.themes.includes(theme));
 const base=pick(pool('base')),v=base.variant;
 layout=layout||pick(Object.keys(LAYOUTS));
 const p={id,version:3,seed:seed>>>0,theme,time,layout,density:'sparse',action:theme==='desert'?'bloom':hero.access==='socket'?'look':(hero.composition==='camp'&&r()<.68?'tea':'look'),detailVariant:v,landmark_id:hero.id,surface_mode:theme==='harbor'?'original':'flat_land',placements:[],character:null};
 const occupied=[];const gh=(x,z)=>theme==='harbor'?terrainHeight(theme,v,x,z):0;
 const rect=(a,x,z,s,rot)=>({x,z,hx:(Math.abs(Math.cos(rot))*a.size[0]+Math.abs(Math.sin(rot))*a.size[2])*s*.5,hz:(Math.abs(Math.sin(rot))*a.size[0]+Math.abs(Math.cos(rot))*a.size[2])*s*.5});
 function free(a,x,z,s,rot,margin=.10){const q=rect(a,x,z,s,rot);return Math.abs(x)+q.hx<3.94&&Math.abs(z)+q.hz<3.94&&occupied.every(o=>Math.abs(x-o.x)>o.hx+q.hx+margin||Math.abs(z-o.z)>o.hz+q.hz+margin);}
 function put(a,x,z,s=1,rot=0,y=null,solid=true){const q={id:a.id,position:[x,y===null?gh(x,z)-.008:y,z].map(x=>+x.toFixed(5)),scale:+s.toFixed(5),rotationY:+rot.toFixed(5),role:a.role};p.placements.push(q);if(solid)occupied.push(rect(a,x,z,s,rot));return q;}
 function scatter(role,points,s){const options=pool(role).filter(a=>role!=='rock'||a.size[1]<a.size[0]*1.12);if(!options.length)return;for(const [px,pz]of points){let done=false;for(let i=0;i<15&&!done;i++){let a=pick(options),x=px+rr(-.12,.12),z=pz+rr(-.13,.13),sc=s*rr(.9,1.07),rot=rr(-.6,.6);if(free(a,x,z,sc,rot)){put(a,x,z,sc,rot);done=true;}}}}
 put(base,0,0,1,0,-.88,false);
 const hs=rr(.95,1.02),hx=layout==='edge'?-.30:layout==='path'?.24:0,hz=-1.25,hy=theme==='harbor'?-.028:-.018,hr=rr(-.045,.045);
 const subject=put(hero,hx,hz,hs,hr,hy);p.landmark_placement=1;
 if(hero.access==='socket'){
  const [x,y,z]=hero.sockets.stand,co=Math.cos(hr),si=Math.sin(hr);
  p.character={position:[hx+(x*co+z*si)*hs,hy+y*hs,hz+(-x*si+z*co)*hs].map(x=>+x.toFixed(5)),yaw:.28,scale:.74,action:'look',support:hero.id,support_socket:'stand'};
  scatter('boat',[[-2.35,2.10]],.91);
  scatter('rock',[[2.95,2.40],[-3.12,.40],[3.15,-2.95]],.48);
  // A small boat is optional on the right. Landing and support are built into the landmark.
  if(r()<.3)scatter('boat',[[1.98,2.67]],.58);
  scatter('detail',[[3.1,-3.16],[-3.1,-3.10]],.65);
 }else{
  const cx=layout==='edge'?.35:-.83,cz=hero.id==='S01'?2.47:2.25;
  if(p.action==='tea'){
   const seat=pick(pool('seat')),sp=put(seat,cx,cz,.84,0);const y=sp.position[1]+seat.sockets.seat[1]*sp.scale;
   p.character={position:[cx,+(y-.54*.74).toFixed(5),cz],yaw:.30,scale:.74,action:'tea',support:seat.id};
  }else{p.character={position:[cx,0,cz],yaw:.24,scale:.78,action:p.action,support:'ground'};occupied.push({x:cx,z:cz,hx:.43,hz:.44});}
  if(hero.composition==='camp'||r()<.52){const fire=pick(pool('fire')),fx=1.16,fz=2.32;if(free(fire,fx,fz,.90,.15))put(fire,fx,fz,.90,.15);}
  if(hero.id==='S01'){
   const tent=ASSETS.C02;for(let x of [-1.35,-1.62,1.54]){if(free(tent,x,1.17,.77,0)){put(tent,x,1.17,.77,0);break;}}
  }
  let lamp=pick(pool('lamp'));if(free(lamp,-1.78,2.48,.94,0))put(lamp,-1.78,2.48,.94,0);
  scatter('rock',[[-3.17,-2.90],[3.15,-2.50],[-3.15,.32],[3.16,.35],[-2.40,2.89]],.48);
  scatter('backdrop',[[-3.05,-.95],[2.92,-2.9]],.49);
  scatter('detail',[[-3.25,1.4],[2.95,1.6],[-2.9,-1.1]],.65);
  if(r()<.4){const a=ASSETS.P01;if(free(a,2.98,-.56,.68,0))put(a,2.98,-.56,.68,.12);}
 }
 if(theme!=='harbor')p.path_points=[[cxPath(p)+.15,0,3.94],[cxPath(p)+.38,0,3.25],[.15,0,1.48],[hx+.08,0,Math.max(.30,hz+hero.size[2]*hs*.46)]];
 p.asset_ids=[...new Set(p.placements.map(v=>v.id))];return checkRecipe(p);
}
function cxPath(p){return p.character.position[0];}
function makeCandidates(theme='any',time='auto',seed=randomSeed(),landmarkId=null){
 const r=seeded(seed);let heroes=CATALOG.assets.filter(a=>a.role==='landmark'&&(theme==='any'||a.themes.includes(theme))&&(!landmarkId||a.id===landmarkId));
 if(!heroes.length)throw Error('此环境没有选中的主体风景');
 // Shuffle once, so 8 candidates favour different main subjects rather than trivial rotations.
 for(let i=heroes.length-1;i>0;i--){let j=Math.floor(r()*(i+1));[heroes[i],heroes[j]]=[heroes[j],heroes[i]];}
 return Array.from({length:8},(_,i)=>{let h=heroes[i%heroes.length],th=theme==='any'?h.themes[Math.floor(r()*h.themes.length)]:theme;return makeRecipe(th,time==='auto'?Object.keys(TIMES)[Math.floor(r()*3)]:time,Math.floor(r()*4294967295),'p'+i,null,h.id);});
}
function describeRecipe(p){if(p.version===2)return describeLegacyRecipe(p);return `${ASSETS[p.landmark_id].name} · ${THEMES[p.theme].name} · ${TIMES[p.time]} · ${p.placements.length} 件素材 · 一个主景，少量配景`;}
function checkRecipe(p){
 if(p?.version===2)return checkLegacyRecipe(p);
 if(!p||p.version!==3||!THEMES[p.theme]||!TIMES[p.time]||!LAYOUTS[p.layout]||!['original','flat_land'].includes(p.surface_mode)||!Array.isArray(p.placements)||p.placements.length<5||p.placements.length>26)throw Error('无效主景配方');
 const hero=ASSETS[p.landmark_id];if(!hero||hero.role!=='landmark'||!hero.themes.includes(p.theme))throw Error('主景编号无效');
 if(p.placements.filter(q=>q.role==='landmark').length!==1||p.placements.filter(q=>q.role==='base').length!==1)throw Error('每张地块需要且仅需要一个底座与一个主景');
 if(!p.placements.some(q=>q.id===p.landmark_id)||!p.character||p.character.action!==p.action)throw Error('人物或主景不一致');
 for(const q of p.placements){const a=ASSETS[q.id];if(!a||!a.themes.includes(p.theme)||q.role!==a.role)throw Error('素材与环境不兼容');if(q.position.length!==3||q.position.some(v=>!Number.isFinite(v)||Math.abs(v)>8)||!Number.isFinite(q.scale)||q.scale<.1||q.scale>2||!Number.isFinite(q.rotationY)||Math.abs(q.rotationY)>6.3)throw Error('变换无效');
  if(a.role!=='base'){let hx=(Math.abs(Math.cos(q.rotationY))*a.size[0]+Math.abs(Math.sin(q.rotationY))*a.size[2])*q.scale*.5,hz=(Math.abs(Math.sin(q.rotationY))*a.size[0]+Math.abs(Math.cos(q.rotationY))*a.size[2])*q.scale*.5;if(Math.abs(q.position[0])+hx>3.97||Math.abs(q.position[2])+hz>3.97)throw Error('素材越出地块边界 '+a.id);}
 }
 const c=p.character;if(c.position.some(v=>!Number.isFinite(v)))throw Error('人物坐标无效');
 if(c.support!=='ground'&&!p.asset_ids.includes(c.support))throw Error('人物没有支撑');
 return p;
}
