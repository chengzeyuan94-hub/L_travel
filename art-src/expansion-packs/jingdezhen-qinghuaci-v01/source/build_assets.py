"""Original procedural assets. Python 3 standard library only. Y up, front +Z.
Run from anywhere: python3 build_assets.py. Edit design.json and the named components.
No project or third-party geometry is copied. All face normals are explicit and flat.
"""
import json, math, struct, pathlib, hashlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
DESIGN = json.loads((ROOT/'source/design.json').read_text())
PAL = {k: tuple(int(v[i:i+2],16)/255 for i in (0,2,4)) for k,v in DESIGN['palette'].items()}
def col(name, factor=1): return tuple(min(1,c*factor) for c in PAL[name])
class Model:
    def __init__(self): self.parts=[]
    def start(self,name,rough=.85):
        self.part={'name':name,'rough':rough,'v':[],'n':[],'c':[]}; self.parts.append(self.part)
    def tri(self,a,b,c,color):
        u=[b[i]-a[i] for i in range(3)]; v=[c[i]-a[i] for i in range(3)]
        n=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]]
        l=sum(x*x for x in n)**.5
        if l<1e-9:return
        n=[x/l for x in n]
        for p in (a,b,c): self.part['v'].extend(p); self.part['n'].extend(n); self.part['c'].extend((*color,1))
    def quad(self,a,b,c,d,color):self.tri(a,b,c,color);self.tri(a,c,d,color)
    def box(self,x,y,z,w,h,d,color):
        a=(x-w/2,y,z-d/2);b=(x+w/2,y,z-d/2);c=(x+w/2,y,z+d/2);e=(x-w/2,y,z+d/2)
        t=lambda p:(p[0],p[1]+h,p[2])
        self.quad(a,b,c,e,color);self.quad(t(a),t(e),t(c),t(b),color)
        for p,q in ((a,b),(b,c),(c,e),(e,a)):self.quad(p,t(p),t(q),q,color)
    def lathe(self,x,y,z,profile,color,segments=16,pattern=False):
        for j in range(len(profile)-1):
            h,r=profile[j];hh,rr=profile[j+1]
            for i in range(segments):
                a=2*math.pi*i/segments;b=2*math.pi*(i+1)/segments
                p=(x+r*math.cos(a),y+h,z+r*math.sin(a));q=(x+r*math.cos(b),y+h,z+r*math.sin(b));s=(x+rr*math.cos(b),y+hh,z+rr*math.sin(b));t=(x+rr*math.cos(a),y+hh,z+rr*math.sin(a))
                cc=color
                if pattern and ((j in (1,7,9)) or (j==4 and i%4 in (0,1))):cc=col('cobalt')
                self.quad(p,t,s,q,cc)
    def save(self,path):
        # Canonical horizontal centre and ground anchor for the current AABB city loader.
        allv=[v for p in self.parts for v in p['v']]
        centre=[(min(allv[i::3])+max(allv[i::3]))/2 for i in (0,2)]
        for p in self.parts:
            for j in range(0,len(p['v']),3):p['v'][j]-=centre[0];p['v'][j+2]-=centre[1]
        blob=bytearray();views=[];acc=[];meshes=[];nodes=[];mats=[]
        def accessor(vals,width,kind):
            offset=len(blob);blob.extend(struct.pack('<'+'f'*len(vals),*vals))
            views.append({'buffer':0,'byteOffset':offset,'byteLength':len(vals)*4,'target':34962})
            a={'bufferView':len(views)-1,'componentType':5126,'count':len(vals)//width,'type':kind}
            if kind=='VEC3':a.update(min=[min(vals[i::width]) for i in range(width)],max=[max(vals[i::width]) for i in range(width)])
            acc.append(a);return len(acc)-1
        material_keys={}
        for p in self.parts:
            if not p['v']:continue
            groups={}
            for i in range(0,len(p['v']),9):
                key=tuple(round(x,4) for x in p['c'][i//3*4:i//3*4+3])
                g=groups.setdefault(key,{'v':[],'n':[]})
                g['v'].extend(p['v'][i:i+9]);g['n'].extend(p['n'][i:i+9])
            primitives=[]
            for color,g in groups.items():
                mk=(*color,p['rough'])
                if mk not in material_keys:
                    def linear(c): return c/12.92 if c<=.04045 else ((c+.055)/1.055)**2.4
                    material_keys[mk]=len(mats)
                    mats.append({'name':p['name']+'_palette_'+str(len(mats)), 'pbrMetallicRoughness':{'baseColorFactor':[*[linear(c) for c in color],1],'metallicFactor':0,'roughnessFactor':p['rough']},'doubleSided':False})
                attrs={'POSITION':accessor(g['v'],3,'VEC3'),'NORMAL':accessor(g['n'],3,'VEC3'),'COLOR_0':accessor([1.]*(len(g['v'])//3*4),4,'VEC4')}
                primitives.append({'attributes':attrs,'material':material_keys[mk],'mode':4})
            meshes.append({'name':p['name'],'primitives':primitives})
            nodes.append({'name':p['name'],'mesh':len(meshes)-1})
        doc={'asset':{'version':'2.0','generator':'Original Jingdezhen procedural geometry v01'},'scene':0,'scenes':[{'name':path.stem,'nodes':[0]}],'nodes':[{'name':path.stem,'children':list(range(1,len(nodes)+1))}]+nodes,'meshes':meshes,'materials':mats,'accessors':acc,'bufferViews':views,'buffers':[{'byteLength':len(blob)}]}
        js=json.dumps(doc,separators=(',',':')).encode();js+=b' '*((-len(js))%4)
        binary=struct.pack('<III',0x46546c67,2,12+8+len(js)+8+len(blob))+struct.pack('<II',len(js),0x4e4f534a)+js+struct.pack('<II',len(blob),0x004e4942)+blob
        path.write_bytes(binary)
        points=[p['v'] for p in self.parts];vs=[q for p in points for q in p]
        report={'file':str(path.name),'bytes':len(binary),'sha256':hashlib.sha256(binary).hexdigest(),'triangles':len(vs)//9,'mesh_nodes':len(meshes),'materials':len(mats),'bounds_min':[min(vs[i::3]) for i in range(3)],'bounds_max':[max(vs[i::3]) for i in range(3)],'textures':0,'embedded_vertex_colors':True,'external_dependencies':[]}
        return report

def roof(m,x,z,w,d,y):
    # Curved pitched tiled roof, ridge along X. Tiles have visible seams at board scale.
    m.start('teal_tiles_'+str(x)+'_'+str(z))
    def height(t):return y+.46*(1-t)+.12*t**3
    nx=max(12,int(w/.13));nz=7
    for side in (-1,1):
        # Continuous dark roof beneath tile seams: no holes to sky.
        for j in range(nz):
            t0=j/nz;t1=(j+1)/nz
            p=(x-w/2,height(t0)-.018,z+side*d/2*t0);q=(x+w/2,height(t0)-.018,z+side*d/2*t0)
            ss=(x+w/2,height(t1)-.018,z+side*d/2*t1);tt=(x-w/2,height(t1)-.018,z+side*d/2*t1)
            if side==1:m.quad(p,tt,ss,q,col('roof',.67))
            else:m.quad(p,q,ss,tt,col('roof',.67))
        for i in range(nx):
            a=x-w/2+w*i/nx+.008;b=x-w/2+w*(i+1)/nx-.008
            for j in range(nz):
                t0=j/nz;t1=(j+1)/nz-.012
                p=(a,height(t0),z+side*d/2*t0);q=(b,height(t0),z+side*d/2*t0);s=(b,height(t1),z+side*d/2*t1);t=(a,height(t1),z+side*d/2*t1)
                cc=col('rooflight' if (i+j)%5==0 else 'roof',.92+.04*((i*7+j)%4))
                if side==1:m.quad(p,t,s,q,cc)
                else:m.quad(p,q,s,t,cc)
    m.box(x,y+.43,z,w+.10,.085,.095,col('gold'))
    # Gold-ochre fascia at eaves and gable edges.
    for side in (-1,1):m.box(x,y+.07,z+side*d/2,w+.1,.055,.055,col('wood'))

def workshop(m,x,z,w,d,y=0,height=.95):
    m.start('workshop_walls_'+str(x));m.box(x,y,z,w,height,d,col('ivory'))
    m.box(x,y,z,w+.07,.09,d+.06,col('bricklight'))
    for xx in (x-w/2+.025,x+w/2-.025):
        for zz in (z-d/2-.015,z+d/2+.015):m.box(xx,y+.08,zz,.07,height,.07,col('wood'))
    for xx in (x-w*.28,x+w*.28):
        m.box(xx,y+.33,z+d/2+.008,.27,.33,.025,col('shadow'))
        for k in range(4):m.box(xx-.135+k*.09,y+.32,z+d/2+.026,.018,.36,.025,col('wood'))
        m.box(xx,y+.49,z+d/2+.04,.29,.018,.025,col('gold'))
    m.box(x,y+.09,z+d/2+.019,.27,.60,.035,col('darkwood'))
    m.box(x,y+.06,z+d/2+.15,.44,.07,.20,col('bricklight'))
    roof(m,x,z,w+.30,d+.34,y+height)

def vase(m,x,y,z,s=1,blue=True):
    profile=[(0,.18),(.05,.21),(.10,.23),(.25,.32),(.48,.36),(.67,.30),(.80,.18),(.89,.12),(1.03,.12),(1.07,.16),(1.12,.16),(1.12,.105),(1.02,.105)]
    m.lathe(x,y,z,[(h*s,r*s) for h,r in profile],col('porcelain'),20,blue)
    m.lathe(x,y,z,[(1.02*s,.0),(1.02*s,.105)],col('shadow'),20)

def city():
    m=Model();workshop(m,-.8,-.48,1.55,.82,height=1.03);workshop(m,1.05,-.64,.86,.90,height=.77)
    # Front-large / rear-small half duck-egg kiln, front faces +Z. Not a temple.
    m.start('half_duck_egg_kiln_brick')
    rings=[(-.55,.32,.43),(-.3,.42,.54),(0,.51,.64),(.34,.57,.70),(.70,.58,.71),(.96,.52,.65)]
    cx=.44;cz=.31;levels=12
    for j in range(len(rings)-1):
        za,ra,ha=rings[j];zb,rb,hb=rings[j+1]
        for k in range(levels):
            a=math.pi*k/levels;b=math.pi*(k+1)/levels
            # normals outward, ground is y=0
            p=(cx+ra*math.cos(a),ha*math.sin(a),cz+za);q=(cx+rb*math.cos(a),hb*math.sin(a),cz+zb);s=(cx+rb*math.cos(b),hb*math.sin(b),cz+zb);t=(cx+ra*math.cos(b),ha*math.sin(b),cz+za)
            m.quad(p,t,s,q,col('bricklight' if (j+k)%3==0 else 'brick',.90+.04*(k%3)))
    za,ra,ha=rings[-1]
    for k in range(levels):
        a=math.pi*k/levels;b=math.pi*(k+1)/levels
        m.tri((cx,0,cz+za),(cx+ra*math.cos(a),ha*math.sin(a),cz+za),(cx+ra*math.cos(b),ha*math.sin(b),cz+za),col('brick'))
    # dark arched kiln mouth and individual arch voussoirs, raised slightly from cap
    m.start('kiln_opening_and_arch')
    front=cz+.969;rr=.205
    m.box(cx,0,front,.41,.23,.025,col('shadow'))
    for k in range(12):
        a=math.pi*k/12;b=math.pi*(k+1)/12
        m.tri((cx,.23,front+.016),(cx+rr*math.cos(a),.23+rr*math.sin(a),front+.016),(cx+rr*math.cos(b),.23+rr*math.sin(b),front+.016),col('shadow'))
        pts=[(cx+r*math.cos(t),.23+r*math.sin(t),front+.025) for r,t in ((rr,a),(rr+.085,a),(rr+.085,b),(rr,b))]
        m.quad(*pts,col('bricklight' if k%2 else 'ivory'))
    for sx in (-1,1):m.box(cx+sx*.25,0,front,.09,.24,.075,col('bricklight'))
    m.box(cx,.015,front+.035,.22,.035,.03,(.96,.52,.17))
    # Brick chimney at the kiln's narrow rear, flared lip and open dark mouth.
    m.start('kiln_chimney')
    m.box(.44,.34,-.29,.28,1.21,.30,col('brick'))
    for j in range(8):m.box(.44,.40+j*.14,-.29,.294,.018,.314,col('bricklight'))
    m.box(.44,1.55,-.29,.34,.09,.36,col('bricklight'));m.box(.44,1.641,-.29,.24,.003,.26,col('shadow'))
    # Small independent timber kiln shelter (open side, one slope left exposed).
    m.start('kiln_shelter_timber')
    for xx in (-.24,1.11):
        for zz in (.06,.83):m.box(xx,0,zz,.055,.94,.055,col('wood'))
    roof(m,.44,.44,1.56,.90,.92)
    # Remove front coverage illusion: the mouth projects beyond the shelter and remains visible.
    m.start('drying_rack_timber')
    for xx in (-1.50,-.85):
        for zz in (.49,.91):m.box(xx,0,zz,.045,.66,.045,col('wood'))
    for yy in (.16,.40,.64):
        for k in range(5):m.box(-1.175,yy,.50+k*.10,.75,.035,.045,col('wood'))
    m.start('drying_whiteware',.34)
    for yy in (.195,.435,.675):
        for xx in (-1.41,-1.18,-.95):vase(m,xx,yy,.69,.17,False)
    m.start('ceramic_display',.30)
    m.box(-.55,0,1.22,.58,.19,.34,col('wood'))
    for xx,s in ((-.73,.22),(-.49,.27)):vase(m,xx,.19,1.22,s)
    # Stacked refractory saggars. Open rings rather than anonymous crates.
    m.start('stacked_saggars')
    for x,z,h in ((1.35,.80,.42),(1.43,.45,.28),(1.14,1.13,.30)):
        for j in range(int(h/.07)):
            m.lathe(x,j*.07,z,[(0,.10),(.065,.10),(.065,.077),(.018,.077)],col('bricklight'),12)
    m.start('porcelain_city_marker',.30);vase(m,-1.40,0,1.30,.35)
    m.start('firewood')
    for j in range(5):m.box(.83+j*.07,0,1.43,.045,.07,.21,col('wood',.9+j*.035))
    return m

def icon():
    m=Model();m.start('porcelain_body',.27);vase(m,0,0,0,1,False)
    # Rings and stylized original blossom in blue glaze. Thin geometry follows the body.
    m.start('cobalt_bands',.29)
    for y0,y1,r in ((.055,.082,.224),(.095,.115,.238),(.862,.881,.140),(1.044,1.065,.164),(1.096,1.114,.164)):
        m.lathe(0,0,0,[(y0,r),(y1,r)],col('cobalt'),24)
    def rr(y):
        prof=[(.10,.23),(.25,.32),(.48,.36),(.67,.30),(.80,.18),(.89,.12)]
        for (a,r),(b,s) in zip(prof,prof[1:]):
            if a<=y<=b:return r+(s-r)*(y-a)/(b-a)
        return .13
    def surf(u,y):
        r=rr(y)+.002
        return (r*math.sin(u),y,r*math.cos(u))
    def petal(u,y,wu,hy):
        for i in range(10):
            a=2*math.pi*i/10;b=2*math.pi*(i+1)/10
            m.tri(surf(u,y),surf(u+wu*math.cos(a),y+hy*math.sin(a)),surf(u+wu*math.cos(b),y+hy*math.sin(b)),col('cobalt',.88+.03*(i%4)))
    for center in (0,2.1,4.2):
        for a in range(6):
            t=a*math.pi/3;petal(center+.18*math.cos(t),.46+.067*math.sin(t),.13,.047)
        petal(center,.46,.075,.028)
        for yy in range(7):petal(center+.055*math.sin(yy*.4),.26+yy*.024,.017,.020)
        petal(center-.17,.31,.13,.023);petal(center+.16,.34,.11,.022)
    return m

if __name__=='__main__':
    (ROOT/'models').mkdir(exist_ok=True)
    reports=[city().save(ROOT/'models/jingdezhen.glb'),icon().save(ROOT/'models/qinghuaci-icon-source.glb')]
    (ROOT/'validation/geometry.json').write_text(json.dumps(reports,indent=2))
    print(json.dumps(reports,indent=2))
