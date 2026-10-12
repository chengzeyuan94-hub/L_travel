/* Connected terrain + authored hero structures; keeps original 120 GLBs unchanged. */
const StudioWorld=(()=>{
 const {geo,tri,quad,geos,mesh,node,material,M,V}=Camp;
 let anim=[],model=null,rng,used=[],contacts=[],last=null;
 const rgb=Camp.rgb, rand=(a,b)=>a+(b-a)*rng();
 const mat=(hex,extra={})=>material(hex,{roughness:.86,...extra});
 const emit=(g,c,p=[0,0,0],s=[1,1,1],rot=[0,0,0],parent=null,opts={})=>mesh(g,typeof c==='string'?mat(c):c,p,s,rot,parent,opts);
 const box=(c,p,s,rot=[0,0,0],parent=null)=>emit(geos.box,c,p,s,rot,parent);
 function beam(a,b,r,c,parent=null){return emit(Camp.lineGeo([a,b],r,6),c,[0,0,0],[1,1,1],[0,0,0],parent);}
 function variation(hex,k){return rgb(hex).map(v=>Math.max(0,Math.min(1,v*k)));}
 function shadow(x,y,z,rx,rz,opacity=.18){const g=geo();quad(g,[-.5,0,.5],[.5,0,.5],[.5,0,-.5],[-.5,0,-.5]);const n=emit(g,mat('#373133',{kind:1,opacity}),[x,y+.012,z],[rx*2,1,rz*2],[0,0,0],null,{cast:false,receive:false,doubleSide:true});n.isContact=true;contacts.push(n);}
 function ground(m,theme){
  const g=geo(),basecol=theme==='canyon'?'#c59a70':theme==='cabin'?'#e4eeed':theme==='autumn'?'#a3ae7b':'#839768';
  const {N,step,heights}=m;
  for(let j=0;j<N;j++)for(let i=0;i<N;i++){
   let x=-4+i*step,z=-4+j*step,a=[x,heights[j][i],z],b=[x+step,heights[j][i+1],z],c=[x+step,heights[j+1][i+1],z+step],d=[x,heights[j+1][i],z+step];
   for(const vs of [[a,d,b],[b,d,c]]){let H=vs.reduce((s,p)=>s+p[1],0)/3,col=basecol;
    if(theme==='cape')col=H<.05?'#617e82':H<.28?'#d6c69b':H<.63?'#a4ad75':'#839768';
    if(theme==='cabin'&&H<.05)col='#8facb7';
    const k=.977+.018*Math.sin(x*1.9+z*1.7)+rand(-.015,.015);let ci=g.c.length;tri(g,...vs,variation(col,k));
    const pathcol=rgb(theme==='canyon'?'#876d51':theme==='cabin'?'#a9c0c8':'#b7a586');
    for(let vi=0;vi<3;vi++){let pt=vs[vi],amount=0;for(const path of m.paths){const n=StudioLayout.nearest(path.points,pt[0],pt[2]);amount=Math.max(amount,1-StudioLayout.smooth(path.width*.43,path.width*.70,n.d));}for(let channel=0;channel<3;channel++){let idx=ci+vi*3+channel;g.c[idx]=g.c[idx]*(1-amount)+pathcol[channel]*amount;}}
   }
  }
  const n=emit(g,mat('#ffffff',{roughness:.98}));n.name='SharedGround';
  const side=geo();const loop=[];
  for(let i=0;i<=N;i++)loop.push([-4+i*step,-4]);for(let j=1;j<=N;j++)loop.push([4,-4+j*step]);for(let i=N-1;i>=0;i--)loop.push([-4+i*step,4]);for(let j=N-1;j>0;j--)loop.push([-4,-4+j*step]);
  for(let i=0;i<loop.length;i++){let a=loop[i],b=loop[(i+1)%loop.length];quad(side,[a[0],-.54,a[1]],[a[0],m.height(...a),a[1]],[b[0],m.height(...b),b[1]],[b[0],-.54,b[1]],variation(theme==='cabin'?'#768797':theme==='cape'?'#6f7165':'#b98266',1));}
  emit(side,'#ffffff');box(theme==='cabin'?'#546473':theme==='cape'?'#555a57':'#84584f',[0,-.65,0],[8,.22,8]);box(theme==='cabin'?'#a1adb1':'#c5a587',[0,-.79,0],[8,.075,8]);
  return n;
 }
 function paths(m){
  // Road colour lives in SharedGround. Only a steep stone route gets real treads.
  for(const path of m.paths){if(path.kind!=='stone')continue;let lastY=null;
   for(let i=3;i<path.points.length-3;i++){const a=path.points[i],b=path.points[i+1],dy=m.height(...b)-m.height(...a),L=Math.hypot(b[0]-a[0],b[1]-a[1]);if(Math.abs(dy)/(L||1)<.36)continue;const y=m.height(...a);if(lastY!==null&&Math.abs(y-lastY)<.09)continue;lastY=y;const yaw=-Math.atan2(b[1]-a[1],b[0]-a[0]);box('#bfb19a',[a[0],y+.036,a[1]],[.21,.10,path.width*.96],[0,yaw,0]);}
  }
 }
 function water(m){if(!m.water)return;const w=m.water,top=w.level,g=geo(),foam=geo(),N=m.N,s=m.step;
  function cut(vs){let out=[];for(let i=0;i<vs.length;i++){let a=vs[i],b=vs[(i+1)%vs.length],A=a[1]<top,B=b[1]<top;if(A)out.push(a);if(A!==B){let t=(top-a[1])/(b[1]-a[1]);out.push([a[0]+(b[0]-a[0])*t,top,a[2]+(b[2]-a[2])*t]);}}return out;}
  for(let j=0;j<N;j++)for(let i=0;i<N;i++){let x=-4+i*s,z=-4+j*s;for(let v of [[[x,m.heights[j][i],z],[x,m.heights[j+1][i],z+s],[x+s,m.heights[j][i+1],z]],[[x+s,m.heights[j][i+1],z],[x,m.heights[j+1][i],z+s],[x+s,m.heights[j+1][i+1],z+s]]]){
   const c=cut(v);if(c.length<3)continue;let dep=top-c.reduce((a,v)=>a+v[1],0)/c.length;let col=dep>.24?'#388996':dep>.09?'#53aab3':'#8fcdca';
   for(let k=1;k<c.length-1;k++)tri(g,[c[0][0],top,c[0][2]],[c[k][0],top,c[k][2]],[c[k+1][0],top,c[k+1][2]],rgb(col));
   const edge=c.filter(v=>Math.abs(v[1]-top)<1e-6);if(edge.length===2&&rand(0,1)<.60){let a=edge[0],b=edge[1];let nx=b[2]-a[2],nz=a[0]-b[0],len=Math.hypot(nx,nz)||1;nx=nx/len*.028;nz=nz/len*.028;quad(foam,[a[0]-nx,top+.009,a[2]-nz],[b[0]-nx,top+.009,b[2]-nz],[b[0]+nx,top+.009,b[2]+nz],[a[0]+nx,top+.009,a[2]+nz],rgb('#ceeee1'));}
  }}
  const sides=geo();let boundary=[];for(let i=0;i<=N;i++)boundary.push([-4+i*s,-4]);for(let i=1;i<=N;i++)boundary.push([4,-4+i*s]);for(let i=N-1;i>=0;i--)boundary.push([-4+i*s,4]);for(let i=N-1;i>0;i--)boundary.push([-4,-4+i*s]);
  for(let i=0;i<boundary.length;i++){let a=boundary[i],b=boundary[(i+1)%boundary.length],ha=m.height(...a),hb=m.height(...b);if(ha>=top&&hb>=top)continue;if(ha>=top||hb>=top){let t=(top-ha)/(hb-ha);let c=[a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t];if(ha>=top)a=c;else b=c;}quad(sides,[a[0],m.height(...a),a[1]],[a[0],top,a[1]],[b[0],top,b[1]],[b[0],m.height(...b),b[1]],rgb('#508e98'));}
  emit(sides,mat('#ffffff',{roughness:.32}),[0,0,0],[1,1,1],[0,0,0],null,{doubleSide:true});
  emit(g,mat('#ffffff',{kind:3,roughness:.23,metal:0}),[0,0,0],[1,1,1],[0,0,0],null,{cast:false,doubleSide:true}).name='WaterSurface';
  emit(foam,'#ffffff',[0,0,0],[1,1,1],[0,0,0],null,{cast:false,doubleSide:true}).name='ShoreFoam';
  // Broad graphic wave crests, sparse and calm; no fluid simulation.
  for(let i=0;i<22;i++){let x=rand(-3.8,3.8),z=rand(-3.8,3.8),len=rand(.14,.45);if(m.height(x,z)>top-.10||m.height(x+len,z)>top-.04)continue;let n=beam([x,top+.017,z],[Math.min(3.94,x+len),top+.017,z-.025],.006,mat('#c6eeeb',{opacity:.5}));n.cast=false;anim.push({type:'ripple',node:n,base:n.p[1],phase:rand(0,6)});}
 }
 function cliff(a,m,theme='canyon'){
  const g=geo(),sides=12,L=7,phase=a.phase||0,random=seeded(a.seed||22),cx=a.x,cz=a.z;
  let ring=[];const profiles=Array.from({length:sides},(_,i)=>.89+.14*random()+.13*Math.sin(i*1.6+phase));const baseH=m.height(cx,cz)-.22;
  for(let j=0;j<=L;j++){let t=j/L,scale=[1.16,1.02,.91,.89,.85,.70,.69,.66][j],twist=.035*Math.sin(t*8+phase);ring[j]=[];for(let i=0;i<sides;i++){let angle=i/sides*Math.PI*2+phase+twist,ir=profiles[i]+.015*Math.sin(j*1.75+i);let x=cx+Math.cos(angle)*a.radius*scale*ir,z=cz+Math.sin(angle)*a.radius*scale*.75*ir;let y=baseH+t*a.height;if(j===0)y=m.height(x,z)-.11;if(j===L)y+=a.height*.006*Math.sin(angle*3+phase);ring[j].push([x,y,z]);}}
  const colors=theme==='canyon'?['#b86748','#b2583d','#ac4e3c','#b5573e','#c56745','#d9764f','#cc664b']:['#637b80','#708689','#82989a','#829194','#8e9b98','#a3abaa','#b5bfb7'];
  for(let j=0;j<L;j++)for(let i=0;i<sides;i++){let k=(i+1)%sides,col=variation(colors[j],.94+random()*.09);quad(g,ring[j][i],ring[j+1][i],ring[j+1][k],ring[j][k],col);}
  let top=[cx,baseH+a.height,cz];for(let i=0;i<sides;i++)tri(g,top,ring[L][(i+1)%sides],ring[L][i],rgb(theme==='canyon'?'#db7751':'#94a078'));
  emit(g,'#ffffff',[0,0,0],[1,1,1],[0,0,0],null,{doubleSide:true}).name='TerrainCliff';
 }
 async function asset(id,x,z,s=.7,rot=0,y=null,contact=true){let g=await AssetLoader.load(id);let n=emit(g,mat('#ffffff'),[x,y===null?model.height(x,z)-.018:y,z],[s,s,s],[0,rot,0],null,{doubleSide:true});n.name=id;used.push({id,position:[...n.p],scale:s,yaw:rot});if(contact){const a=ASSETS[id];shadow(x,n.p[1],z,a.size[0]*s*.37,a.size[2]*s*.37,.13);}return n;}
 function emitWindow(parent,p,size){let n=box(mat('#ffcd73',{emission:1,roughness:.4}),p,size,[0,0,0],parent);n.isGlow=true;n.cast=false;return n;}
 function cabin(m){const h=m.hero,y=h.y+.065,n=node(null,[h.x,y,h.z]),wood='#805036',dark='#513d32',snow='#edf3ef',roof='#394c61';
  box('#696e70',[0,-.03,0],[2.35,.18,2.05],[0,0,0],n);
  box(wood,[0,.64,0],[2.06,1.28,1.80],[0,0,0],n);
  for(let j=0;j<9;j++){box(j%2?'#916244':'#96694b',[0,.08+j*.142,.918],[2.11,.09,.035],[0,0,0],n);box('#745038',[-1.047,.08+j*.142,0],[.035,.09,1.88],[0,0,0],n);box('#986948',[1.047,.08+j*.142,0],[.035,.09,1.88],[0,0,0],n);}
  // Gable as actual triangles; pitched boards, not a flat roof slab.
  const g=geo();tri(g,[-1.08,1.28,.90],[1.08,1.28,.90],[0,2.25,.90]);tri(g,[1.08,1.28,-.90],[-1.08,1.28,-.90],[0,2.25,-.90]);emit(g,wood,[0,0,0],[1,1,1],[0,0,0],n,{doubleSide:true});
  for(const sign of [-1,1]){const r=geo(),x0=sign*1.22;quad(r,[0,2.3,-1.07],[x0,1.20,-1.07],[x0,1.20,1.10],[0,2.3,1.10]);emit(r,roof,[0,0,0],[1,1,1],[0,0,0],n,{doubleSide:true});const q=geo();quad(q,[0,2.38,-1.09],[x0,1.29,-1.09],[x0,1.29,1.12],[0,2.38,1.12]);emit(q,snow,[0,0,0],[1,1,1],[0,0,0],n,{doubleSide:true});}
  beam([-1.18,1.22,1.11],[0,2.31,1.11],.06,dark,n);beam([0,2.31,1.11],[1.18,1.22,1.11],.06,dark,n);
  box('#473c35',[0,.43,.939],[.47,.85,.08],[0,0,0],n);box('#c19259',[.15,.43,.992],[.045,.045,.025],[0,0,0],n);
  for(const x of [-.67,.67]){box(dark,[x,.75,.96],[.43,.48,.055],[0,0,0],n);emitWindow(n,[x,.75,.995],[.34,.37,.025]);box(dark,[x,.75,1.013],[.035,.40,.025],[0,0,0],n);box(dark,[x,.75,1.013],[.36,.036,.025],[0,0,0],n);}
  // side window lets warm light remain visible from the 3/4 camera
  box(dark,[1.055,.74,0],[.045,.49,.49],[0,0,0],n);emitWindow(n,[1.081,.74,0],[.025,.37,.37]);box(dark,[1.10,.74,0],[.035,.40,.035],[0,0,0],n);box(dark,[1.10,.74,0],[.035,.035,.40],[0,0,0],n);
  for(let i=0;i<3;i++){let z=h.z+1.04+i*.18,H=y-.055-i*.048;box('#b1aaa0',[h.x,H-.035,z],[.78,.07,.22]);}
  box('#7b5850',[.57,2.09,-.43],[.28,1.14,.31],[0,0,0],n);box('#564338',[.57,2.66,-.43],[.38,.09,.39],[0,0,0],n);
  for(let i=0;i<7;i++){let s=.09+i*.018,q=emit(geos.ico1,mat('#d3d9d3',{opacity:.52}),[h.x+.57,y+2.74+i*.17,h.z-.43],[s,s,s],[0,0,0],null,{cast:false});anim.push({type:'smoke',node:q,base:[...q.p],phase:i*.8});}
  shadow(h.x,y-.08,h.z,1.17,.98,.18);Camp.lanternPositions=[[h.x-.64,y+.72,h.z+1.27],[h.x+1.3,y+.77,h.z]];
  return n;
 }
 function lighthouse(m){let h=m.hero,y=h.y,n=node(null,[h.x,y,h.z]);let wall='#eddfb7';
  box('#c6b394',[0,.075,0],[1.42,.15,1.40],[0,0,0],n);
  for(let i=0;i<5;i++)emit(Camp.cylinder(.61-i*.048,.66-i*.048,10),i===1||i===3?'#bd6049':wall,[0,.41+i*.53,0],[1,.55,1],[0,0,0],n);
  box('#4b5457',[0,.39,.66],[.27,.61,.07],[0,0,0],n);
  emit(Camp.cylinder(1,1,10),'#645b4b',[0,2.91,0],[.7,.13,.7],[0,0,0],n);
  emit(Camp.cylinder(1,1,8),mat('#ffdb88',{emission:1.0}),[0,3.22,0],[.39,.49,.39],[0,0,0],n).isGlow=true;
  for(let i=0;i<8;i++){let a=i*Math.PI/4,x=Math.cos(a)*.45,z=Math.sin(a)*.45;box('#5c635e',[x,3.23,z],[.045,.57,.045],[0,0,0],n);beam([Math.cos(a)*.65,3.06,Math.sin(a)*.65],[Math.cos(a+.7854)*.65,3.06,Math.sin(a+.7854)*.65],.023,'#67675a',n);beam([Math.cos(a)*.65,2.96,Math.sin(a)*.65],[Math.cos(a)*.65,3.19,Math.sin(a)*.65],.021,'#67675a',n);}
  emit(Camp.cylinder(0,1,8),'#bd644c',[0,3.66,0],[.61,.52,.61],[0,0,0],n);beam([0,3.90,0],[0,4.13,0],.025,'#826347',n);
  for(let i=0;i<3;i++)box('#c3b8a1',[h.x,h.y+.04-i*.075,h.z+.83+i*.18],[.55,.08,.23]);
  // small connected keeper shed, no extra mini-plinth
  box('#d8cbae',[-.85,.47,-.12],[.78,.9,1.0],[0,0,0],n);for(const s of [-1,1])box('#a85647',[-.85+s*.23,1.04,-.12],[.61,.10,1.14],[0,0,s*-.50],n);
  Camp.lanternPositions=[[h.x,h.y+3.23,h.z],[h.x-.85,h.y+.60,h.z+.7]];
  shadow(h.x,h.y,h.z,.87,.80,.17);
 }
 async function dock(m){const cape=m.p.scene_id==='cape',x=cape?-.8:1.02,z=cape?.48:1.72,y=cape?.28:.25;
  if(cape){for(let i=0;i<12;i++)box(i%2?'#967347':'#a38254',[x+i*.23,y,z],[.215,.10,.75]);for(const xx of [x+.12,x+1.14,x+2.46])for(const zz of [z-.29,z+.29]){emit(Camp.cylinder(.06,.07,7),'#705338',[xx,-.11,zz],[1,.95,1]);box('#c3a175',[xx,.45,zz],[.15,.1,.15]);}}
  else {for(let i=0;i<9;i++)box(i%2?'#8c7358':'#a28763',[x,y,z-i*.22],[.85,.09,.20]);for(let zz of [z,z-1.72])for(let xx of [x-.32,x+.32])emit(Camp.cylinder(.065,.08,7),'#826849',[xx,-.06,zz],[1,.75,1]);}
  if(cape){let n=await asset('H05',1.8,1.45,.72,-.22,m.water.level+.025,false);anim.push({type:'boat',node:n,base:n.p[1],phase:.7});}
  return {x:cape?x+1.26:x,z:cape?z:z-.62,y:y+.06};
 }
 function grass(x,z,color='#7d925c',s=.14){const y=model.height(x,z),g=geo();for(let i=0;i<3;i++){let a=i*2.094,dx=Math.cos(a)*s*.6,dz=Math.sin(a)*s*.6;tri(g,[x-dx*.4,y,z-dz*.4],[x+dx*.4,y,z+dz*.4],[x+dx,y+s*(.8+i*.15),z+dz],rgb(color));}emit(g,'#ffffff',[0,0,0],[1,1,1],[0,0,0],null,{doubleSide:true});}
 async function trees(m){let positions=m.p.scene_id==='cabin'?[[-3.05,-2.50],[-2.10,-3.04],[.3,-3.17],[2.0,-2.95],[2.95,-1.4],[3.25,-2.96],[-3.3,-.92],[.6,-2.90]]:[[-3.28,-2.5],[.7,-3.08],[2.25,-3.25]];
  for(let i=0;i<positions.length;i++){let [x,z]=positions[i];x+=rand(-.10,.10);z+=rand(-.11,.11);let id=m.p.scene_id==='cabin'?'T0'+(i%4+1):'T'+String(20+i%4+1).padStart(2,'0'),sc=m.p.scene_id==='cabin'?rand(.59,.77):.52;if(m.water&&m.height(x,z)<m.water.level+.20){for(let k=0;k<12&&m.height(x,z)<m.water.level+.20;k++){x-=.14;z-=.035;}}let a=ASSETS[id];sc=Math.min(sc,2.50/a.size[1]);await asset(id,x,z,sc,rand(-.5,.5));}
 }
 async function props(m){const theme=m.p.scene_id;
  for(let i=0;i<(theme==='canyon'?22:13);i++){let x=rand(-3.65,3.65),z=rand(-3.65,3.65);if(m.pathDist(x,z)<.63||m.water&&m.height(x,z)<m.water.level+.02||m.pads.some(a=>Math.abs(x-a.x)<a.rx+.15&&Math.abs(z-a.z)<a.rz+.15)||m.peaks.some(a=>Math.hypot(x-a.x,z-a.z)<a.radius*1.4))continue;grass(x,z,theme==='canyon'?'#777f48':theme==='cabin'?'#778d86':'#6b8746',rand(.11,.18));if(i%5===0)await asset(theme==='canyon'?'R08':theme==='cabin'?'R02':'R13',x,z,rand(.15,.26),rand(0,6));}
  if(theme==='canyon'){for(const [x,z]of [[-3.42,.11],[3.20,-.52],[-1.03,-2.35],[3.35,2.9]]){if(m.pathDist(x,z)>.8)await asset('P07',x,z,.48,rand(0,6));}await asset('P01',-2.12,2.57,.60,.20);}
  if(theme==='cabin'){await asset('P01',-3.12,2.03,.60,0);await asset('C13',m.hero.x-1.19,.54,.9,0);}
 }
 function optimize(){// Batch only immutable opaque geometry by material, retaining exported names.
  Camp.update();let groups=new Map();let kept=[];const dynamicNodes=new Set(anim.map(a=>a.node));
  function dynamic(n){while(n){if(dynamicNodes.has(n)||n.keepNode)return true;n=n.parent;}return false;}
  for(const n of Camp.world){if(!n.g.p.length)continue;if(n.isFloor||n.isContact||n.mat.opacity<.99||dynamic(n)){kept.push(n);continue;}let key=JSON.stringify([n.mat,n.cast,n.receive,n.doubleSide,n.isGlow]);if(!groups.has(key))groups.set(key,{g:geo(),n,count:0});const {g}=groups.get(key);groups.get(key).count++;
   for(let i=0;i<n.g.p.length;i+=9){let a=M.point(n.world,n.g.p.slice(i,i+3)),b=M.point(n.world,n.g.p.slice(i+3,i+6)),c=M.point(n.world,n.g.p.slice(i+6,i+9)),N=V.norm(V.cross(V.sub(b,a),V.sub(c,a)));g.p.push(...a,...b,...c);g.n.push(...N,...N,...N);g.c.push(...n.g.c.slice(i,i+9));}
  }
  Camp.world.length=0;Camp.world.push(...kept);for(const {g,n,count}of groups.values()){let q=emit(g,n.mat,[0,0,0],[1,1,1],[0,0,0],null,{cast:n.cast,receive:n.receive,doubleSide:n.doubleSide});q.name='Batched_'+(n.name||'Surface')+'_'+count;if(n.isGlow)q.isGlow=true;}Camp.update();
 }
 async function build(p,comparison='full'){
  StudioLayout.check(p);if(typeof Journey480!=='undefined'&&Journey480.isNew(p))await Promise.all(JourneyAssembly.preloadIds(p).map(id=>AssetLoader.load(id)));model=StudioLayout.model(p);rng=seeded(p.seed^98352);anim=[];used=[];contacts=[];
  if(comparison==='legacy'||comparison==='light'){
   let d=StudioLayout.scenes[p.scene_id],t=p.lighting==='morning'?'day':p.lighting;
   let old=makeRecipe(d.theme,t,p.seed,'p0',null,d.legacy);await Builder.build(old);Camp.world.forEach(n=>{if(n.mat.roughness===undefined)n.mat.roughness=.92;});last={recipe:p,comparison,legacyRecipe:old,triangles:Camp.world.reduce((s,n)=>s+n.g.p.length/9,0),used:old.placements,model:null,checks:{mode:'original_v3'}};return last;
  }
  Camp.world.length=0;Camp.roots.length=0;Builder.resetAnimations();Camp.fireEnabled=false;Camp.entry=[100,-100,100];Camp.lanternPositions=[[100,-100,100],[100,-100,100]];Camp.contactPoints=[];Camp.previewBounds=null;
  ground(model,model.surface_theme||p.scene_id);paths(model);water(model);
  let cp;
  if(model.catalog){cp=await JourneyAssembly.build(model,{asset,emit,box,beam,shadow,cliff,cabin,lighthouse,grass,mat,animate:a=>anim.push(a),record:(id,position,scale,yaw,role)=>used.push({id,position,scale,yaw,role})});}
  else if(p.scene_id==='canyon'){
   for(const a of model.peaks)cliff(a,model);
   let pt=model.paths[0].points[15];cp={x:pt[0],z:pt[1],y:model.height(...pt)+.025};
  }else if(p.scene_id==='cabin'){
   cabin(model);await trees(model);await dock(model);let a=model.paths[0].points[31];cp={x:a[0]-.22,z:a[1],y:model.height(a[0]-.22,a[1])};
  }else{
   lighthouse(model);cp=await dock(model);await trees(model);
   for(let a of [{x:-.3,z:2.9,radius:.48,height:.8,phase:.7},{x:2.65,z:2.64,radius:.36,height:.68,phase:2},{x:2.42,z:-.72,radius:.40,height:1.04,phase:1}])cliff(a,model,'cape');
  }
  if(!model.catalog)await props(model);
  const person=Builder.person(cp.x,cp.z,cp.action||'look',cp.y,cp.yaw??.42);person.s=[cp.scale||.72,cp.scale||.72,cp.scale||.72];person.keepNode=true;shadow(cp.x,cp.y,cp.z,.23,.18,.20);
  box(mat('#f0e5d4',{roughness:1}),[0,-.92,0],[200,.12,200]);let floor=Camp.world[Camp.world.length-1];floor.isFloor=true;floor.cast=false;
  optimize();
  const contactError=Math.abs(cp.y-(model.catalog?cp.expected:p.scene_id==='cape'?.34:model.height(cp.x,cp.z)+(p.scene_id==='canyon'?.025:0)));
  const roads=model.paths.map(path=>{let maxGrade=0;for(let i=1;i<path.points.length;i++){let a=path.points[i-1],b=path.points[i],d=Math.hypot(b[0]-a[0],b[1]-a[1]);maxGrade=Math.max(maxGrade,Math.abs(model.height(...a)-model.height(...b))/(d||1));}return {id:path.id,connection:path.connection,samples:path.points.length,max_grade:+maxGrade.toFixed(4),width:path.width};});
  last={recipe:p,comparison,model,used,character:cp,checks:{contact_error:+contactError.toFixed(6),activity:model.catalog?model.profile.mode:null,assembly:model.assembly||null,roads,height_range:[Math.min(...model.heights.flat()),Math.max(...model.heights.flat())]},triangles:Camp.world.reduce((s,n)=>s+n.g.p.length/9,0)};return last;
 }
 function tick(t,lighting,quality='standard'){
  Builder.tick(t);for(const a of anim){if(a.type==='smoke'){let s=(t*.17+a.phase*.12)%1;a.node.p=[a.base[0]+s*.28,a.base[1]+s*.28,a.base[2]+Math.sin(t*.7+a.phase)*.055];a.node.mat.opacity=.28*(1-s*.55);}
   if(a.type==='sway480')a.node.r[2]=Math.sin(t*.6+a.phase)*a.amplitude;
   if(a.type==='flame480'){a.node.s[1]=a.scale[1]*(.94+.12*Math.sin(t*8+a.phase));a.node.r[2]=Math.sin(t*4+a.phase)*.08;}
   if(a.type==='boat'){a.node.p[1]=a.base+Math.sin(t*1.0+a.phase)*.016;a.node.r[2]=Math.sin(t*.78+a.phase)*.02;}
   if(a.type==='ripple')a.node.p[1]=a.base+Math.sin(t*.8+a.phase)*.002;
  }
  for(const n of Camp.world){if(n.isContact)n.mat.opacity=quality==='lite'?0:.14;if(n.isGlow)n.mat.emission=lighting==='night'?1.7:lighting==='sunset'?.50:.13;}
  Camp.update();
 }
 function snapshot(){return {version:4,config_version:last.recipe.config_version,recipe:last.recipe,comparison:last.comparison,used_assets:last.used,character:last.character,checks:last.checks,geometry_snapshot:Camp.world.filter(n=>!n.isFloor&&!n.isContact).map(n=>({name:n.name||'part',matrix:Array.from(n.world),material:n.mat,geometry:n.g})),note:'Geometry is a static snapshot. Store recipe+config version to regenerate motions; no API key stored.'};}
 return {build,tick,snapshot,get last(){return last;}};
})();
