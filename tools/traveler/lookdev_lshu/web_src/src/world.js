/* Instances of the exported GLBs plus the previous demo's glasses-and-jacket character stand-in. */
const Builder=(()=>{
 const {mesh,node,material,mkbox:B,geos,cylinder,lineGeo}=Camp;
 let anim=[],r=seeded(1);const R=(a,b)=>a+r()*(b-a),mat=(hex,extra={})=>material(hex,extra);
 const flat=(g,c,p,s=[1,1,1],rot=[0,0,0],parent=null,opts={})=>mesh(g,typeof c==='string'?mat(c):c,p,s,rot,parent,opts);
 const cube=(c,p,s,rot=[0,0,0],parent=null)=>B(typeof c==='string'?mat(c):c,p,s,rot,parent);
 function branch(a,b,width,c,parent){flat(lineGeo([a,b],width,6),c,[0,0,0],[1,1,1],[0,0,0],parent);}
 const groundHeight=()=>0;
 function mug(parent,p){flat(geos.cyl, '#f7e2bd',p,[.07,.11,.07],[0,0,0],parent);branch([p[0]+.04,p[1]+.03,p[2]],[p[0]+.11,p[1]+.03,p[2]],.015,'#f5debb',parent);branch([p[0]+.11,p[1]+.03,p[2]],[p[0]+.11,p[1]-.04,p[2]],.015,'#f5debb',parent);}
 function person(x,z,action,y=null,yaw=.25){const base=y===null?groundHeight(x,z):y,n=node(null,[x,base,z],[0,yaw,0]),sit=action==='tea';
  // Compact stand-in retaining glasses, dark hair, ochre jacket and blue trousers.
  let hip=sit?.72:.44,head=sit?1.35:1.19;
  cube('#bd843f',[0,hip+.20,0],[.43,.43,.29],[0,0,0],n);flat(geos.ico1,'#eac29c',[0,head,0],[.31,.32,.26],[0,0,0],n);flat(geos.ico1,'#473d36',[0,head+.16,-.045],[.325,.24,.26],[0,0,0],n);flat(geos.ico,'#40362f',[.02,head+.37,-.04],[.075,.15,.065],[0,0,-.4],n);
  flat(geos.ico,'#eac29c',[-.31,head,0],[.066,.09,.045],[0,0,0],n);flat(geos.ico,'#eac29c',[.31,head,0],[.066,.09,.045],[0,0,0],n);
  for(const a of [-1,1]){
   const xx=a*.15;if(sit){cube('#526977',[xx,.64,.15],[.17,.2,.37],[0,0,0],n);cube('#526977',[xx,.44,.29],[.17,.34,.16],[0,0,0],n);cube('#755343',[xx,.25,.35],[.20,.14,.28],[0,0,0],n);}else{cube('#526977',[xx,.25,0],[.17,.42,.18],[0,0,0],n);cube('#755343',[xx,.06,.04],[.21,.13,.29],[0,0,0],n);}
   // Rectangular glasses, not a hat silhouette.
   const cx=a*.135,cy=head+.005,Z=.241;for(const dy of [-.075,.075])cube('#302d2c',[cx,cy+dy,Z],[.225,.028,.035],[0,0,0],n);for(const dx of [-.108,.108])cube('#302d2c',[cx+dx,cy,Z],[.025,.17,.035],[0,0,0],n);cube('#322d28',[cx,cy-.012,.258],[.035,.055,.018],[0,0,0],n);
   branch([a*.245,hip+.34,0],[a*.20,hip+.11,.27],.077,'#b9803b',n);flat(geos.ico1,'#edc299',[a*.18,hip+.13,.29],[.075,.07,.07],[0,0,0],n);
  }
  cube('#302d2c',[0,head+.04,.243],[.08,.02,.035],[0,0,0],n);cube('#916140',[0,hip+.24,-.23],[.36,.38,.17],[0,0,0],n);cube('#d4a15e',[0,hip+.46,-.23],[.38,.1,.15],[0,0,0],n);flat(cylinder(1,1,7),'#6b7959',[0,hip+.45,.01],[.25,.11,.18],[0,0,0],n);
  if(action==='tea')mug(n,[.0,hip+.19,.35]);
  if(action==='bloom'){
   const bunch=node(n,[0,hip+.16,.38]);for(let i=0;i<3;i++)flat(geos.ico1,'#b88b4c',[(i-1)*.09,0,i%2*.04],[.105,.09,.08],[0,0,i*.3],bunch);
   for(let i=0;i<3;i++){const plant=node(bunch,[(i-1)*.11,.03,0]);const h=.23+i*.065;branch([0,0,0],[.02,h,0],.011,'#76994b',plant);flat(geos.ico,'#8fa74e',[.055,h*.5,0],[.067,.022,.023],[0,0,.4],plant);flat(geos.ico,'#deb84c',[.02,h,.005],[.035,.035,.025],[0,0,0],plant);for(let j=0;j<5;j++){const a=j*1.256;flat(geos.ico,'#fff1cf',[.02+Math.sin(a)*.06,h+Math.cos(a)*.06,.004],[.042,.044,.018],[0,0,-a],plant);}anim.push({type:'bloom',node:plant,phase:i*.7});}
  }
  anim.push({type:'person',node:n,base,phase:R(0,6)});return n;
 }

 function flatTerrain(g,color=null){
  // Keep the old GLB untouched. A v3 recipe uses a planar contact surface under its
  // integrated landscape; the landmark itself supplies all the relief.
  const q={p:g.p.slice(),n:[],c:g.c.slice()};
  for(let i=1;i<q.p.length;i+=3)if(q.p[i]>.76){q.p[i]=.88;if(color){const rgb=Camp.rgb(color);q.c[i-1]=rgb[0];q.c[i]=rgb[1];q.c[i+1]=rgb[2];}}
  for(let i=0;i<q.p.length;i+=9){const a=q.p.slice(i,i+3),b=q.p.slice(i+3,i+6),c=q.p.slice(i+6,i+9),N=Camp.V.norm(Camp.V.cross(Camp.V.sub(b,a),Camp.V.sub(c,a)));q.n.push(...N,...N,...N);}
  return q;
 }
 function addLandmarkGeometry(g,a,parent){
  const parts=a.runtime_parts||[];
  if(!parts.length){flat(g,'#ffffff',[0,0,0],[1,1,1],[0,0,0],parent,{doubleSide:true});return;}
  const fixed={p:[],n:[],c:[]};
  for(let i=0;i<g.p.length/9;i++)if(!parts.some(p=>i>=p.start_triangle&&i<p.start_triangle+p.triangle_count))for(let k of ['p','n','c'])fixed[k].push(...g[k].slice(i*9,i*9+9));
  flat(fixed,'#ffffff',[0,0,0],[1,1,1],[0,0,0],parent,{doubleSide:true});
  for(const part of parts){const lo=part.start_triangle*9,hi=lo+part.triangle_count*9,q={p:g.p.slice(lo,hi),n:g.n.slice(lo,hi),c:g.c.slice(lo,hi)};for(let i=0;i<q.p.length;i++)q.p[i]-=part.pivot[i%3];const pivot=node(parent,part.pivot);flat(q,'#ffffff',[0,0,0],[1,1,1],[0,0,0],pivot,{doubleSide:true});anim.push({type:'rotor',node:pivot,axis:part.axis,speed:part.speed_rad_s});}
 }
 function extraEffects(a,parent){for(const e of a.effect_points||[]){if(e.type==='flame'){const pivot=node(parent,e.position);for(let i=0;i<3;i++){let f=flat(geos.ico,mat(['#ed8739','#f8c45c','#fff0b2'][i],{emission:1.25}),[(i-1)*.06,.10+i*.035,0],[.13-i*.022,.24-i*.035,.10-i*.014],[0,0,0],pivot,{cast:false});anim.push({type:'flame',node:f,scale:[...f.s],phase:i*2});}}}}
 function walkingPath(p){
  if(!p.path_points?.length)return;const pts=p.path_points,g=Camp.geo();const color=Camp.rgb(p.theme==='snow'?'#d9e4df':p.theme==='desert'?'#efd09a':'#d5c79e');
  for(let i=0;i<pts.length-1;i++){const a=pts[i],z=pts[i+1],dx=z[0]-a[0],dz=z[2]-a[2],L=Math.hypot(dx,dz),nx=-dz/L,nz=dx/L,w=.29;const A=[a[0]+nx*w,.006,a[2]+nz*w],B=[z[0]+nx*w,.006,z[2]+nz*w],C=[z[0]-nx*w,.006,z[2]-nz*w],D=[a[0]-nx*w,.006,a[2]-nz*w];for(const v of [A,B,C,D]){v[0]=Math.max(-3.97,Math.min(3.97,v[0]));v[2]=Math.max(-3.97,Math.min(3.97,v[2]));}Camp.quad(g,A,B,C,D,color);}
  flat(g,'#ffffff',[0,0,0],[1,1,1],[0,0,0],null,{doubleSide:true,cast:false});
 }
 async function build(p){checkRecipe(p);const loaded=await Promise.all(p.asset_ids.map(id=>AssetLoader.load(id))),by=Object.fromEntries(p.asset_ids.map((id,i)=>[id,loaded[i]]));
  // Replace the scene only after every required file has loaded successfully.
  Camp.world.length=0;Camp.roots.length=0;Camp.previewBounds=null;anim=[];r=seeded(p.seed);Camp.fireEnabled=false;Camp.entry=[100,-100,100];Camp.lanternPositions=[[100,-100,100],[100,-100,100]];Camp.contactPoints=[];
  for(const q of p.placements){const a=ASSETS[q.id],n=node(null,q.position,[0,q.rotationY,0],[q.scale,q.scale,q.scale]);let geometry=by[q.id];if(a.role==='base'&&p.surface_mode==='flat_land')geometry=flatTerrain(geometry,p.theme==='autumn'?'#b3b582':null);addLandmarkGeometry(geometry,a,n);extraEffects(a,n);
   if(a.group!=='terrain')Camp.contactPoints.push({x:q.position[0],z:q.position[2],r:Math.min(a.size[0],a.size[2])*.4*q.scale});
   if(a.motion==='gentle_sway')anim.push({type:'tree',node:n,base:0,phase:R(0,6),amount:.006});
   if(a.motion==='bob')anim.push({type:'boat',node:n,base:q.position[1],phase:R(0,6)});
   if(a.role==='fire'){for(let i=0;i<3;i++){let f=flat(geos.ico,mat(['#ed792d','#ffc34c','#fff0a8'][i],{emission:1.5}),[(i-1)*.085,.39+i*.03,0],[.16-i*.03,.30-i*.045,.14-i*.025],[0,0,0],n,{cast:false});anim.push({type:'flame',node:f,scale:[...f.s],phase:i*2});}Camp.entry=[q.position[0],q.position[1]+.55,q.position[2]];Camp.fireEnabled=true;}
   if(a.role==='lamp')Camp.lanternPositions[0]=[q.position[0],q.position[1]+a.size[1]*.4*q.scale,q.position[2]];
  }
  walkingPath(p);
  const c=p.character,n=person(c.position[0],c.position[2],c.action,c.position[1],c.yaw);n.s.fill(c.scale);
  cube('#eae3d6',[0,-.95,0],[200,.1,200]);let floor=Camp.world[Camp.world.length-1];floor.isFloor=true;floor.cast=false;
  Camp.update();return {recipe:p,objects:Camp.world.length,triangles:Camp.world.reduce((s,n)=>s+n.g.p.length/9,0),assets:p.asset_ids,items:{trees:p.placements.filter(q=>ASSETS[q.id].group==='tree').length}};
 }
 async function inspectAsset(id){let g=await AssetLoader.load(id);Camp.world.length=0;Camp.roots.length=0;anim=[];Camp.fireEnabled=false;Camp.lanternPositions=[[100,-100,100],[100,-100,100]];Camp.contactPoints=[];Camp.previewBounds=ASSETS[id].size;flat(g,'#ffffff',[0,0,0],[1,1,1],[0,0,0],null,{doubleSide:true});cube('#eae3d6',[0,-.06,0],[200,.1,200]);let floor=Camp.world[Camp.world.length-1];floor.isFloor=true;floor.cast=false;Camp.update();return ASSETS[id];}
 function tick(t){for(const a of anim){if(a.type==='rotor')for(let k=0;k<3;k++)a.node.r[k]=a.axis[k]*t*a.speed;if(a.type==='tree')a.node.r[2]=a.base+Math.sin(t*.6+a.phase)*a.amount;if(a.type==='person')a.node.p[1]=a.base+Math.sin(t*1.5+a.phase)*.004;if(a.type==='flame'){a.node.s[1]=a.scale[1]*(.94+.12*Math.sin(t*8+a.phase));a.node.r[2]=Math.sin(t*4+a.phase)*.08;}if(a.type==='boat'){a.node.p[1]=a.base+Math.sin(t*1.1+a.phase)*.018;a.node.r[2]=Math.sin(t*.8+a.phase)*.018;}if(a.type==='bloom'){const s=Math.max(.015,Math.min(1,(t-a.phase)/3));a.node.s=[s,s,s];}}Camp.update();}
 return {build,tick,inspectAsset,person,addLandmarkGeometry,extraEffects,resetAnimations:()=>{anim=[];r=seeded(1);},animationState:()=>anim.map(a=>({type:a.type,rotation:[...a.node.r]}))};
})();
