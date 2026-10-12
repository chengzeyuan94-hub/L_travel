/* WarmMini: math / basic geometry adapted from the approved autumn-camp baseline. */
'use strict';
const Camp = {};
(() => {
  const TAU = Math.PI * 2;
  let seed = 260916;
  const rand = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
  const rr = (a,b) => a + rand() * (b-a);
  const choose = a => a[Math.floor(rand()*a.length)];
  const V = {
    add:(a,b)=>a.map((v,i)=>v+b[i]), sub:(a,b)=>a.map((v,i)=>v-b[i]),
    mul:(a,s)=>a.map(v=>v*s), dot:(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0),
    cross:(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]],
    norm:a=> { const l=Math.hypot(...a)||1; return a.map(v=>v/l); },
  };
  const M = {
    identity:()=>new Float32Array([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]),
    multiply:(a,b)=> { const r=new Float32Array(16); for(let c=0;c<4;c++) for(let i=0;i<4;i++) for(let k=0;k<4;k++)r[c*4+i]+=a[k*4+i]*b[c*4+k]; return r; },
    compose:(p,r,s)=> {
      const [x,y,z]=r, a=Math.cos(x),b=Math.sin(x),c=Math.cos(y),d=Math.sin(y),e=Math.cos(z),f=Math.sin(z);
      return new Float32Array([c*e*s[0],(a*f+b*e*d)*s[0],(b*f-a*e*d)*s[0],0,
        -c*f*s[1],(a*e-b*f*d)*s[1],(b*e+a*f*d)*s[1],0,
        d*s[2],-b*c*s[2],a*c*s[2],0,...p,1]);
    },
    lookAt:(eye,target,up=[0,1,0])=> {
      const z=V.norm(V.sub(eye,target)), x=V.norm(V.cross(up,z)), y=V.cross(z,x);
      return new Float32Array([x[0],y[0],z[0],0,x[1],y[1],z[1],0,x[2],y[2],z[2],0,-V.dot(x,eye),-V.dot(y,eye),-V.dot(z,eye),1]);
    },
    perspective:(fov,aspect,near,far,offset=0)=> { const f=1/Math.tan(fov/2),nf=1/(near-far);return new Float32Array([f/aspect,0,0,0,0,f,0,0,offset,0,(far+near)*nf,-1,0,0,2*far*near*nf,0]); },
    ortho:(l,r,b,t,n,f)=>new Float32Array([2/(r-l),0,0,0,0,2/(t-b),0,0,0,0,-2/(f-n),0,-(r+l)/(r-l),-(t+b)/(t-b),-(f+n)/(f-n),1]),
    point:(m,p)=>[m[0]*p[0]+m[4]*p[1]+m[8]*p[2]+m[12],m[1]*p[0]+m[5]*p[1]+m[9]*p[2]+m[13],m[2]*p[0]+m[6]*p[1]+m[10]*p[2]+m[14]],
  };
  function geo(){ return {p:[],n:[],c:[]}; }
  function tri(g,a,b,c,col=[1,1,1]) { const n=V.norm(V.cross(V.sub(b,a),V.sub(c,a))); g.p.push(...a,...b,...c);g.n.push(...n,...n,...n);g.c.push(...col,...col,...col);return g; }
  function quad(g,a,b,c,d,col){tri(g,a,b,c,col);tri(g,a,c,d,col);return g;}
  function box(){ const g=geo();const a=.5;quad(g,[-a,-a,a],[a,-a,a],[a,a,a],[-a,a,a]);quad(g,[a,-a,-a],[-a,-a,-a],[-a,a,-a],[a,a,-a]);quad(g,[a,-a,a],[a,-a,-a],[a,a,-a],[a,a,a]);quad(g,[-a,-a,-a],[-a,-a,a],[-a,a,a],[-a,a,-a]);quad(g,[-a,a,a],[a,a,a],[a,a,-a],[-a,a,-a]);quad(g,[-a,-a,-a],[a,-a,-a],[a,-a,a],[-a,-a,a]);return g; }
  function cylinder(top=1, bot=1, sides=8, caps=true) {
    const g=geo();for(let i=0;i<sides;i++){let a=i*TAU/sides,b=(i+1)*TAU/sides;
      let p=[Math.sin(a)*bot,-.5,Math.cos(a)*bot],q=[Math.sin(b)*bot,-.5,Math.cos(b)*bot],r=[Math.sin(b)*top,.5,Math.cos(b)*top],s=[Math.sin(a)*top,.5,Math.cos(a)*top];
      if(top===0)tri(g,p,q,[0,.5,0]);else quad(g,p,q,r,s);
      if(caps){if(top)tri(g,[0,.5,0],s,r);tri(g,[0,-.5,0],q,p);}
    }return g;
  }
  function ico(detail=0) {
    const t=(1+Math.sqrt(5))/2, pts=[[-1,t,0],[1,t,0],[-1,-t,0],[1,-t,0],[0,-1,t],[0,1,t],[0,-1,-t],[0,1,-t],[t,0,-1],[t,0,1],[-t,0,-1],[-t,0,1]].map(V.norm);
    const faces=[[0,11,5],[0,5,1],[0,1,7],[0,7,10],[0,10,11],[1,5,9],[5,11,4],[11,10,2],[10,7,6],[7,1,8],[3,9,4],[3,4,2],[3,2,6],[3,6,8],[3,8,9],[4,9,5],[2,4,11],[6,2,10],[8,6,7],[9,8,1]];
    const g=geo();function subdiv(a,b,c,d){if(!d){tri(g,a,b,c);return;} const ab=V.norm(V.add(a,b)),bc=V.norm(V.add(b,c)),ca=V.norm(V.add(c,a));subdiv(a,ab,ca,d-1);subdiv(ab,b,bc,d-1);subdiv(ca,bc,c,d-1);subdiv(ab,bc,ca,d-1);}for(const f of faces)subdiv(...f.map(i=>pts[i]),detail);return g;
  }
  // A chamfered, eight-corner display plinth, not a floating terrain island.
  function slab(w,d,h,bevel=.13) {
    const g=geo();const ring=(y,b)=>[[-w/2+b,y,-d/2],[w/2-b,y,-d/2],[w/2,y,-d/2+b],[w/2,y,d/2-b],[w/2-b,y,d/2],[-w/2+b,y,d/2],[-w/2,y,d/2-b],[-w/2,y,-d/2+b]];
    const top=ring(h/2,bevel),bottom=ring(-h/2,bevel);
    for(let i=0;i<8;i++){const j=(i+1)%8;tri(g,[0,h/2,0],top[j],top[i]);tri(g,[0,-h/2,0],bottom[i],bottom[j]);quad(g,bottom[i],top[i],top[j],bottom[j]);}return g;
  }
  function lineGeo(points, radius=.015, sides=5){
    const g=geo();for(let i=0;i<points.length-1;i++){
      const a=points[i],b=points[i+1],dir=V.norm(V.sub(b,a)),u=V.norm(V.cross(dir,Math.abs(dir[1])>.98?[1,0,0]:[0,1,0])),v=V.cross(dir,u);
      for(let j=0;j<sides;j++){
        const ring=(p,k)=>V.add(p,V.mul(V.add(V.mul(u,Math.cos(k*TAU/sides)),V.mul(v,Math.sin(k*TAU/sides))),radius));
        quad(g,ring(a,j),ring(a,j+1),ring(b,j+1),ring(b,j));
      }
    }return g;
  }
  function append(g,src,m,color=[1,1,1]){
    for(let i=0;i<src.p.length;i+=3){const a=M.point(m,src.p.slice(i,i+3));g.p.push(...a);const n=V.norm([m[0]*src.n[i]+m[4]*src.n[i+1]+m[8]*src.n[i+2],m[1]*src.n[i]+m[5]*src.n[i+1]+m[9]*src.n[i+2],m[2]*src.n[i]+m[6]*src.n[i+1]+m[10]*src.n[i+2]]);g.n.push(...n);g.c.push(...color);}
  }
  const rgb=hex=> {const s=hex.replace('#','');return [0,2,4].map(i=>parseInt(s.substring(i,i+2),16)/255);};
  const material=(color,extra={})=>({color:rgb(color),emission:0,opacity:1,kind:0,metal:0,...extra});
  const geos={box:box(),cone6:cylinder(0,1,6),cone7:cylinder(0,1,7),cone8:cylinder(0,1,8),cyl:cylinder(1,1,8),cyl6:cylinder(1,1,6),ico:ico(0),ico1:ico(1)};
  const world=[], roots=[];
  function node(parent=null,p=[0,0,0],r=[0,0,0],s=[1,1,1]){const n={p:[...p],r:[...r],s:[...s],world:M.identity(),children:[],parent};if(parent)parent.children.push(n);else roots.push(n);return n;}
  function mesh(g,mat,p=[0,0,0],s=[1,1,1],r=[0,0,0],parent=null,opts={}){const n=node(parent,p,r,s);Object.assign(n,{g,mat,cast:true,receive:true},opts);world.push(n);return n;}
  const mkbox=(mat,p,s,r=[0,0,0],parent=null,opts={})=>mesh(geos.box,mat,p,s,r,parent,opts);
  function tube(points,radius,mat,parent=null,opts={}){return mesh(lineGeo(points,radius),mat,[0,0,0],[1,1,1],[0,0,0],parent,opts);}

  function update(n,parent=M.identity()){n.world=M.multiply(parent,M.compose(n.p,n.r,n.s));for(const child of n.children)update(child,n.world);}
  Object.assign(Camp,{V,M,world,roots,mesh,node,material,mkbox,geo,tri,quad,geos,slab,update:()=>roots.forEach(n=>update(n)),cylinder,lineGeo,ico,rgb,lanternPositions:[[0,1,1],[0,1,1]],entry:[0,.8,.8]});
})();
