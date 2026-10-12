/* Content expansion only. Reuses V4.1 geometry, character and rendering materials. */
const JourneyAssembly = (()=>{
 const {geo,tri,quad,geos,node,mesh,material}=Camp;
 const terrainColor={desert:'#b36c4b',autumn:'#8e9c72',snow:'#c8d7d9',harbor:'#789184'};
 function preloadIds(p){const d=Journey480.places[p.scene_id],
  trees=d.theme==='snow'?['T01','T02','T04','T05','T06']:d.theme==='desert'?['T16','T17','T18']:d.theme==='harbor'?['T19','T20','T23','T24']:['T07','T08','T09','T10','T12'];
  return [...new Set([d.asset,...trees,'R01','R03','R05','R07','R09','R11','R13','R15','C01','C02','C03','C04','C05','C06','C07','C08','C09','C10','C11','C12','C13','C14','C15','C16','P01','P02','P03','P04','P05','P06','P07','V01','V02','V03','V04','V05','V06','V07','V08','V11','H05','H06','H08','H09','H10','H11'])];
 }
 async function build(m,H){
  const p=m.p,d=m.place,profile=m.profile,h=m.hero,camp=m.camp,
   r=seeded(p.seed^0x91ea53),R=(a,b)=>a+(b-a)*r(),choose=a=>a[Math.floor(r()*a.length)],
   {asset,emit,box,beam,shadow,cliff,cabin,lighthouse,animate,mat,record}=H,
   reservations=[{x:camp.x,z:camp.z,rx:camp.rx+.1,rz:camp.rz+.1,kind:'activity'}];
  if(d.id!=='canyon')reservations.push({x:h.x,z:h.z,rx:h.rx+.08,rz:h.rz+.08,kind:'landmark'});
  let cp=null;
  function placed(id,x,z,s,y=null,rot=0,contact=true){return asset(id,x,z,s,rot,y,contact);}
  function flame(x,z,y,scale=.6){
   const root=node(null,[x,y,z]);root.keepNode=true;
   for(let i=0;i<3;i++){const n=emit(geos.ico,mat(['#ed792d','#ffc34c','#fff0a8'][i],{emission:1.5}),[(i-1)*.07*scale,(.3+i*.04)*scale,0],[(.17-i*.026)*scale,(.34-i*.055)*scale,(.14-i*.025)*scale],[0,0,0],root,{cast:false});animate({type:'flame480',node:n,scale:[...n.s],phase:i*2});}
   Camp.entry=[x,y+.45*scale,z];Camp.fireEnabled=true;
  }
  async function compound(){
   const groundOffset=d.new_city?(ASSETS[d.asset].ground_offset_m||0)*h.scale:0;const g=await AssetLoader.load(d.asset),n=node(null,[h.x,h.y-groundOffset-.015,h.z],[0,h.yaw,0],[h.scale,h.scale,h.scale]);
   if(ASSETS[d.asset].runtime_parts?.length||ASSETS[d.asset].effect_points?.length)n.keepNode=true;
   if(d.new_city&&typeof CityRuntime!=='undefined')CityRuntime.add(g,ASSETS[d.asset],n);else Builder.addLandmarkGeometry(g,ASSETS[d.asset],n);Builder.extraEffects(ASSETS[d.asset],n);
   record(d.asset,[h.x,h.y-groundOffset-.015,h.z],h.scale,h.yaw,'landmark');
   for(const e of ASSETS[d.asset].effect_points||[]){if(e.type==='lamp')Camp.lanternPositions[0]=[h.x+e.position[0]*h.scale,h.y+e.position[1]*h.scale,h.z+e.position[2]*h.scale];}
   shadow(h.x,h.y-.005,h.z,h.rx*.82,h.rz*.82,.15);
   return n;
  }
  if(d.id==='canyon')for(const a of m.peaks)cliff(a,m);
  else if(d.id==='cabin')cabin(m);
  else if(d.id==='cape')lighthouse(m);
  else await compound();
  // Shoreline and the small deck remain anchored in the same continuous ground.
  let pierEnd=null;
  if(d.id==='cape'){
   const x=h.x+.18;let shore=3.15;for(let z=h.z+h.rz+.15;z<3.15;z+=.06)if(m.height(x,z)<.24){shore=z;break;}
   const start=shore-.18,end=Math.min(3.65,shore+1.28),N=Math.ceil((end-start)/.21),y0=Math.max(.29,m.height(x,start)+.10),y1=.30;
   for(let i=0;i<=N;i++){const z=start+(end-start)*i/N,y=y0+(y1-y0)*i/N;box(i%2?'#967347':'#a38254',[x,y,z],[.77,.10,.19]);if(i%3===0)for(const dx of [-.28,.28])beam([x+dx,m.height(x+dx,z)-.08,z],[x+dx,y+.17,z],.048,'#705338');}
   pierEnd={x,z:end-.2,y:y1+.05,expected:y1+.05};
   reservations.push({x,z:(start+end)/2,rx:.49,rz:(end-start)/2+.14,kind:'pier'});
   let bx=x+1.1,bz=end-.30;if(bx>3.25)bx=x-1.1;if(m.height(bx,bz)<m.water.level-.07){const n=await placed(profile.id===3?'H06':'H05',bx,bz,.62,m.water.level+.025,-.20,false);animate({type:'boat',node:n,base:n.p[1],phase:.7});}
  }
  if(d.id==='cabin'){
   const w=m.water,x=w.x,z=w.z-.1,y=.22;
   for(let i=0;i<6;i++){let zz=z+i*.17;box(i%2?'#8c7358':'#a28763',[x,y,zz],[.70,.09,.16]);if(i===0||i===5)for(const dx of [-.25,.25])beam([x+dx,m.height(x+dx,zz),zz],[x+dx,y+.08,zz],.045,'#826849');}
   reservations.push({x,z:z+.4,rx:.5,rz:.65,kind:'small_lake_deck'});
  }
  // Explicitly different foreground travel ensembles, not color-only variants.
  let xx=camp.x,zz=camp.z,cy=m.height(xx,zz),sc=.72;
  if(profile.id===0){
   if(pierEnd){cp={...pierEnd,action:'look',support:'pier',yaw:-.35};}
   else cp={x:xx+.22,z:zz-.10,y:m.height(xx+.22,zz-.10)+.005,action:'look',support:'ground',yaw:.65};
   await placed('P01',xx-.65,zz-.33,.55);await placed('P07',xx+.62,zz+.36,.43);
  }else if(profile.id===1){
   if(d.theme==='harbor'){
    await placed('H10',xx-.42,zz-.2,.95);await placed('H09',xx+.55,zz+.15,.74);await placed('P02',xx-.70,zz-.49,.70);await placed('C13',xx-.60,zz+.43,.85);
    cp={x:xx+.22,z:zz-.20,y:m.height(xx+.22,zz-.20)+.005,action:'look',support:'ground',yaw:.50};
   }else{
    const tent=d.theme==='snow'?'C02':d.theme==='desert'?'C04':p.variant%2?'C01':'C03';
    await placed(tent,xx-.46,zz-.25,.48,null,.08);
    const fx=xx+.58,fz=zz+.42,fy=m.height(fx,fz);await placed('C09',fx,fz,.58,fy);flame(fx,fz,fy,.75);
    await placed('P04',xx-.68,zz+.50,.65);
    cp={x:xx+.42,z:zz-.43,y:m.height(xx+.42,zz-.43)+.005,action:'look',support:'ground',yaw:.60};
   }
  }else if(profile.id===2){
   const seat=p.variant%2?'C07':'C05',sy=m.height(xx,zz),seatScale=.83,seatTop=sy+ASSETS[seat].size[1]*seatScale;
   await placed(seat,xx,zz,seatScale,sy);
   cp={x:xx,z:zz+.015,y:seatTop-.72*sc,expected:seatTop-.72*sc,seat_top:seatTop,action:'tea',support:seat,yaw:.28};
   await placed('P06',xx-.65,zz+.37,.56);await placed('C14',xx+.62,zz+.20,.86);
   Camp.lanternPositions[1]=[xx+.62,m.height(xx+.62,zz+.2)+.30,zz+.2];
   if(d.theme!=='harbor'){const fx=xx+.65,fz=zz-.48,fy=m.height(fx,fz);await placed('C10',fx,fz,.44,fy);flame(fx,fz,fy,.55);}
  }else{
   cp={x:xx,z:zz-.1,y:m.height(xx,zz-.1)+.005,action:d.theme==='desert'||d.id==='blossom'?'bloom':'look',support:'ground',yaw:.50};
   await placed('P03',xx-.55,zz+.24,.9);await placed(d.theme==='harbor'?'H11':'P05',xx+.67,zz+.12,.8);await placed('P02',xx-.70,zz-.50,.68);
   if(d.theme!=='snow'){await placed('V07',xx+.5,zz-.48,.70);await placed('V08',xx-.24,zz+.55,.60);}
   else await placed('C16',xx+.52,zz-.44,.78);
  }
  // Main feature boundary and path remain clear. Foliage is clustered, not an even grid.
  const treeIDs=d.theme==='snow'?['T01','T02','T04','T05','T06']:d.theme==='desert'?['T16','T17','T18']:d.theme==='harbor'?['T19','T20','T23','T24']:['T07','T08','T09','T10','T12'];
  const treeCount=d.theme==='desert'?2:profile.id===2?8:profile.id===0?4:6;
  const phase=p.variant%3;
  const centers=phase===0?[[-3.12,-2.9],[3.05,-2.25]]:phase===1?[[-3.1,-2.6],[-3.06,-.4]]:[[3.12,-2.65],[3.03,-.50]];
  function reserveOK(x,z,rx,rz,avoidPath=true){
   if(Math.abs(x)+rx>3.94||Math.abs(z)+rz>3.94)return false;
   if(m.water&&m.height(x,z)<m.water.level+.09)return false;
   if(avoidPath&&m.pathDist(x,z)<Math.max(rx,rz)+.29)return false;
   if(reservations.some(a=>Math.abs(x-a.x)<rx+a.rx&&Math.abs(z-a.z)<rz+a.rz))return false;
   if(m.peaks.some(a=>Math.hypot(x-a.x,z-a.z)<a.radius*1.2+rx))return false;
   const samples=[[x-rx,z],[x+rx,z],[x,z-rz],[x,z+rz]].map(a=>m.height(...a));
   if(Math.max(...samples)-Math.min(...samples)>.38)return false;
   return true;
  }
  let treeActual=0;
  for(let i=0;i<90&&treeActual<treeCount;i++){
   const center=centers[i%centers.length],x=center[0]+R(-.6,.6),z=center[1]+R(-.75,.75),id=choose(treeIDs),size=.55+R(0,.24),a=ASSETS[id],rx=a.size[0]*size*.48,rz=a.size[2]*size*.48;
   if(!reserveOK(x,z,rx,rz))continue;
   const n=await placed(id,x,z,size,null,R(-.5,.5));n.keepNode=true;animate({type:'sway480',node:n,phase:R(0,6),amplitude:.005});reservations.push({x,z,rx:rx*.68,rz:rz*.68,kind:'tree'});treeActual++;
  }
  // Enough supporting rocks to ground the feature; never a second large hero.
  const rocks=d.theme==='desert'?['R05','R07']:d.theme==='harbor'?['R13','R15']:d.theme==='snow'?['R01','R03']:['R09','R11'];let rockCount=0;
  for(let i=0;i<40&&rockCount<4;i++){
   const x=R(-3.5,3.5),z=R(-3.25,3.5),id=choose(rocks),size=R(.38,.68),a=ASSETS[id],rx=a.size[0]*size*.5,rz=a.size[2]*size*.5;
   if(!reserveOK(x,z,rx,rz))continue;
   await placed(id,x,z,size,null,R(0,6));reservations.push({x,z,rx,rz,kind:'rock'});rockCount++;
  }
  let grassCount=0;
  for(let i=0;i<42;i++){
   const x=R(-3.75,3.75),z=R(-3.65,3.7);if(!reserveOK(x,z,.10,.10))continue;
   H.grass(x,z,d.theme==='snow'?'#778d86':d.theme==='desert'?'#8d914d':'#798f4e',R(.11,.17));grassCount++;
  }
  cp.scale=sc;cp.expected=cp.expected??(m.height(cp.x,cp.z)+.005);
  m.assembly={trees:treeActual,rocks:rockCount,grass:grassCount,activity:profile.mode,reservations};
  return cp;
 }
 return {preloadIds,build};
})();
