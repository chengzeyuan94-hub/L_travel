/* Studio v4: deterministic spatial recipes. Coordinates are Y-up, metres. */
const StudioLayout = (() => {
  const VERSION='4.1.0';
  const scenes={
    canyon:{name:'红岩古道',theme:'desert',legacy:'S11',sub:'风穿过峡谷，路向远方弯去。',layouts:['宽谷缓行','双壁夹道','偏侧曲径'],event:'L叔停下，读一眼古道的路标。'},
    cabin:{name:'雪林木屋',theme:'snow',legacy:'S12',sub:'湖边有一盏灯，给晚归的人留着。',layouts:['湖畔围合','林隙弯径','坡脚小屋'],event:'L叔在门前停留，烟囱升起几缕炊烟。'},
    cape:{name:'灯塔海角',theme:'harbor',legacy:'S02',sub:'路接着岸，岸接着海，海接着下一程。',layouts:['西岸回廊','弧湾石径','礁岸转角'],event:'L叔在码头等风，小船缓缓起伏。'}
  };
  const lightNames={day:'奶油日光',sunset:'暖色夕照',night:'蓝夜暖灯',morning:'清冷晨光'};
  const palettes={
    day:{sky:'#eadbcc',sun:'#fff1d4',sunPos:[-8,13,7],sunPower:2.3,ambient:1.0,exposure:1.03},
    sunset:{sky:'#ddaf9b',sun:'#ffb15e',sunPos:[-10,6,4],sunPower:2.55,ambient:.64,exposure:1.02},
    night:{sky:'#192a49',sun:'#91a7ea',sunPos:[-7,10,-7],sunPower:.75,ambient:.50,exposure:1.15},
    morning:{sky:'#c2d4d7',sun:'#f8e6c4',sunPos:[7,8,-5],sunPower:1.85,ambient:1.04,exposure:1.02}
  };
  const clamp=(x,a,b)=>Math.min(b,Math.max(a,x));
  const smooth=(a,b,x)=>{const v=clamp((x-a)/(b-a),0,1);return v*v*(3-2*v);};
  function recipe(scene='canyon',variant=0,seed=260921,lighting='day',id='p0'){
    if(!scenes[scene]||![0,1,2].includes(variant)||!palettes[lighting])throw Error('未知场景、布局或光照');
    return {id,version:4,config_version:VERSION,scene_id:scene,variant,seed:seed>>>0,lighting};
  }
  function check(p){if(!p||typeof p.id!=='string'||!(/^[a-zA-Z0-9]{1,20}$/).test(p.id)||p.version!==4||p.config_version!==VERSION||!scenes[p.scene_id]||![0,1,2].includes(p.variant)||!palettes[p.lighting]||!Number.isInteger(p.seed)||p.seed<0||p.seed>4294967295)throw Error('配方不是有效的 Studio v4.1 格式');return p;}
  function candidates(scene,variant,lighting,seed){let r=seeded(seed),keys=scene==='any'?Object.keys(scenes):[scene],phase=Math.floor(r()*3),lightPhase=Math.floor(r()*4);return Array.from({length:8},(_,i)=>recipe(keys[i%keys.length],variant==='auto'?(Math.floor(i/keys.length)+phase)%3:Number(variant),Math.floor(r()*4294967296),lighting==='auto'?Object.keys(palettes)[(i+lightPhase)%4]:lighting,'p'+i));}
  function spline(points,segments=100){const out=[];for(let i=0;i<=segments;i++){let u=i/segments*(points.length-1),k=Math.min(points.length-2,Math.floor(u)),t=u-k;let a=points[Math.max(0,k-1)],b=points[k],c=points[k+1],d=points[Math.min(points.length-1,k+2)];out.push([0,1].map(n=>.5*((2*b[n])+(-a[n]+c[n])*t+(2*a[n]-5*b[n]+4*c[n]-d[n])*t*t+(-a[n]+3*b[n]-3*c[n]+d[n])*t*t*t)));}return out;}
  function nearest(points,x,z){let best={d:Infinity,t:0,x:0,z:0,index:0};for(let i=0;i<points.length-1;i++){const a=points[i],b=points[i+1],dx=b[0]-a[0],dz=b[1]-a[1],t=clamp(((x-a[0])*dx+(z-a[1])*dz)/(dx*dx+dz*dz||1),0,1),px=a[0]+t*dx,pz=a[1]+t*dz,dist=Math.hypot(x-px,z-pz);if(dist<best.d)best={d:dist,t:(i+t)/(points.length-1),x:px,z:pz,index:i};}return best;}
  function model(p){check(p);const r=seeded(p.seed),v=p.variant,rand=(a,b)=>a+(b-a)*r(),data={p,water:null,pads:[],peaks:[],paths:[],hero:null};
    let base;
    if(p.scene_id==='canyon'){
      let s=(v-1)*.22;
      data.peaks=[[-2.60,-2.10,1.20,3.10],[-.65,-2.90,1.04,4.30],[2.25,-1.72,1.06,3.22],[2.45,1.85,.93,2.55],[-2.65,1.22,.91,2.34]].map((a,i)=>({x:a[0]+rand(-.1,.1),z:a[1]+rand(-.12,.12),radius:a[2]*rand(.96,1.06),height:a[3]*rand(.92,1.06),phase:rand(0,6),seed:p.seed+i*97}));
      const pts=v===1?[[.1,4],[.3,2.65],[-.2,1.0],[.35,-.5],[.25,-2],[.5,-4]]:v===2?[[-1.35,4],[-.6,2.4],[.3,1],[1,-.1],[.85,-2],[1,-4]]:[[-1.2,4],[-.55,2.6],[.2,1.25],[-.1,-.1],[.8,-1.2],[1.15,-4]];
      data.paths.push({id:'ancient_trail',points:spline(pts),width:.62,kind:'dirt',connection:'前侧地块入口 → 谷底 → 后侧出口'});
      for(const a of data.peaks){const q=nearest(data.paths[0].points,a.x,a.z),need=a.radius*1.18+.38;if(q.d<need)a.x+=(a.x<q.x?-1:1)*(need-q.d);a.x=clamp(a.x,-3.90+a.radius*1.18,3.90-a.radius*1.18);}
      base=(x,z)=>.13+.07*Math.sin(x*.8+z*.44)+data.peaks.reduce((h,a)=>h+.5*Math.exp(-((x-a.x)**2+(z-a.z)**2)/(a.radius*1.9)**2),0);
      data.hero={x:0,z:-1};
    } else if(p.scene_id==='cabin'){
      data.hero={x:-.80+(v-1)*.40,z:-1.0-(v===2?.22:0),y:.50,width:2.15,depth:1.82};
      const h=data.hero;data.pads.push({x:h.x,z:h.z,h:h.y,rx:1.22,rz:1.12});
      data.water={level:.06,x:1.65,z:1.48,rx:1.72,rz:1.42};
      data.paths.push({id:'door_path',points:spline([[-2.1,4],[-2.45,2.4],[h.x-.55,1.15],[h.x,.60],[h.x,h.z+1.04]]),width:.55,kind:'snow',connection:'雪地前端 → 门前空地 → 木屋门槛'});
      const w=data.water;
      base=(x,z)=>{const basin=((x-w.x)/w.rx)**2+((z-w.z)/w.rz)**2;let zrise=.85*smooth(.2,4,-z),val=.22+zrise+.055*Math.cos(x*.9)*Math.sin(z*.6);return val-(1-smooth(.50,1.16,basin))*.57;};
    } else {
      data.hero={x:-1.30+(v-1)*.27,z:-1.85,y:1.22};const h=data.hero;
      data.pads.push({x:h.x,z:h.z,h:h.y,rx:1.12,rz:1.02});data.water={level:.08};
      data.paths.push({id:'coastal_path',points:spline([[-3.98,2.0],[-3.18,1.50],[-2.85,.4],[-2.53,-.2],[h.x,-.77]]),width:.58,kind:'stone',connection:'海角西侧入口 → 回廊石径 → 灯塔门前'});
      data.paths.push({id:'pier_link',points:spline([[-2.88,.7],[-2.22,.52],[-1.45,.48],[-.75,.48]],64),width:.47,kind:'stone',connection:'主径岔口 → 下坡石阶 → 码头起点'});
      base=(x,z)=>{let peninsula=1.35*Math.exp(-((x+1.85)**2/6.7+(z+1.7)**2/9.0));let back=.37*smooth(1.8,4,-z);return -.39+peninsula+back;};
    }
    const unpadded=base;
    function raw(x,z){let h=unpadded(x,z);for(const a of data.pads){let dist=Math.max(Math.abs(x-a.x)/a.rx,Math.abs(z-a.z)/a.rz);h=h+(a.h-h)*(1-smooth(1,1.55,dist));}return h;}
    // Reserve graded corridors before producing the terrain mesh, not an overlay at Y=0.
    for(const path of data.paths){let ys=path.points.map(([x,z])=>raw(x,z));const maxGrade=path.kind==='stone'?.48:.32;for(let iter=0;iter<3;iter++){for(let i=1;i<ys.length;i++){let d=Math.hypot(path.points[i][0]-path.points[i-1][0],path.points[i][1]-path.points[i-1][1]);ys[i]=clamp(ys[i],ys[i-1]-maxGrade*d,ys[i-1]+maxGrade*d);}for(let i=ys.length-2;i>=0;i--){let d=Math.hypot(path.points[i][0]-path.points[i+1][0],path.points[i][1]-path.points[i+1][1]);ys[i]=clamp(ys[i],ys[i+1]-maxGrade*d,ys[i+1]+maxGrade*d);}}path.ys=ys;}
    function analytic(x,z){let h=raw(x,z);for(const path of data.paths){let n=nearest(path.points,x,z),w=1-smooth(path.width*.48,path.width*1.8,n.d);let k=n.t*(path.ys.length-1),i=Math.min(path.ys.length-2,Math.floor(k)),y=path.ys[i]*(1-(k-i))+path.ys[i+1]*(k-i);h+=(y-h)*w;}return h;}
    const N=52,step=8/N,heights=Array.from({length:N+1},(_,j)=>Array.from({length:N+1},(_,i)=>analytic(-4+i*step,-4+j*step)));
    // Exact barycentric interpolation for the SAME diagonals as the mesh.
    function height(x,z){x=clamp(x,-4,4);z=clamp(z,-4,4);let ix=Math.min(N-1,Math.floor((x+4)/step)),iz=Math.min(N-1,Math.floor((z+4)/step)),u=(x+4)/step-ix,w=(z+4)/step-iz,a=heights[iz][ix],b=heights[iz][ix+1],c=heights[iz+1][ix+1],d=heights[iz+1][ix];return u+w<=1?a+(b-a)*u+(d-a)*w:b*(1-w)+d*(1-u)+c*(u+w-1);}
    function pathDist(x,z){return Math.min(...data.paths.map(a=>nearest(a.points,x,z).d));}
    return Object.assign(data,{height,heights,N,step,analytic,pathDist,random:r});
  }
  return {VERSION,scenes,lightNames,palettes,recipe,check,candidates,model,spline,nearest,smooth,clamp};
})();
