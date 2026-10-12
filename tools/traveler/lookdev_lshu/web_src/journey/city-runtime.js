/* Only new city assets have these material regions. Keeps V4.1 renderers unchanged. */
const CityRuntime=(()=>{
 function add(g,a,parent){
  const ranges=(a.material_regions||[]).filter(p=>p.triangle_count>0), buckets=new Map();
  for(let i=0;i<g.p.length/9;i++){
   const role=ranges.find(p=>i>=p.start_triangle&&i<p.start_triangle+p.triangle_count)?.role||'matte';
   if(!buckets.has(role))buckets.set(role,Camp.geo());const q=buckets.get(role);
   for(const k of ['p','n','c'])q[k].push(...g[k].slice(i*9,i*9+9));
  }
  for(const[role,q]of buckets){
   const m=Camp.material('#ffffff',{roughness:role==='water'?.25:role==='metal'?.48:.87,kind:role==='water'?3:0,metal:role==='metal'?.6:0,emission:role==='glow'?.30:0});
   const n=Camp.mesh(q,m,[0,0,0],[1,1,1],[0,0,0],parent,{doubleSide:true,cast:role!=='glow'&&role!=='water'});n.name=a.id+'_'+role;if(role==='glow')n.isGlow=true;
  }
 }
 return {add};
})();
