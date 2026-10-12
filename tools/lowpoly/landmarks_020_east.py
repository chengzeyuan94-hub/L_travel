"""Ten independent geographic scenery models based on east-01/02/03 concepts.

Only Geometry020 is mutated. This module never reads/writes the live map.
Authored coordinates use Blender Z-up. Reduced scenes are geographic motifs,
not surveyed reconstructions; source/scope metadata lives in geography-plan.
"""
from math import sin, cos, pi, tau, sqrt, exp, hypot, atan2


def clamp(x,a=0.,b=1.):return min(b,max(a,x))
def smooth(a,b,x):
    t=clamp((x-a)/(b-a));return t*t*(3-2*t)
def bump(x,y,cx,cy,rx,ry,h,p=1.4):
    return h*max(0.,1-((x-cx)/rx)**2-((y-cy)/ry)**2)**p

def sample_ground(g):
    """Vertical barycentric query of the authored triangles, not analytic guess."""
    triangles=[]
    for vv,ff in g.buckets.values():
        for f in ff:
            for k in range(1,len(f)-1):
                a,b,c=(vv[f[i]] for i in (0,k,k+1))
                det=(b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
                if abs(det)>1e-10:triangles.append((a,b,c,det))
    def height(x,y):
        best=0.
        for a,b,c,det in triangles:
            u=((b[1]-c[1])*(x-c[0])+(c[0]-b[0])*(y-c[1]))/det
            v=((c[1]-a[1])*(x-c[0])+(a[0]-c[0])*(y-c[1]))/det
            if u>=-1e-7 and v>=-1e-7 and u+v<=1.0000001:
                best=max(best,u*a[2]+v*b[2]+(1-u-v)*c[2])
        return best
    return height


def ribbon(g,points,width,mat,thickness=.006):
    """Thin closed solid along a surface; width can vary per cross-section."""
    vv=[]
    for i,p in enumerate(points):
        a,b=points[max(0,i-1)],points[min(len(points)-1,i+1)]
        dx,dy=b[0]-a[0],b[1]-a[1];ln=max(1e-8,hypot(dx,dy))
        w=width[i] if isinstance(width,(list,tuple)) else width
        ox,oy=-dy/ln*w*.5,dx/ln*w*.5
        for dz in (-thickness,0):vv.extend([(p[0]+ox,p[1]+oy,p[2]+dz),(p[0]-ox,p[1]-oy,p[2]+dz)])
    ff=[(0,2,3,1)]
    for i in range(len(points)-1):
        a=i*4;b=a+4
        ff += [(a,b,b+1,a+1),(a+2,a+3,b+3,b+2),(a,a+2,b+2,b),(a+1,b+1,b+3,a+3)]
    a=(len(points)-1)*4;ff.append((a,a+1,a+3,a+2));g.mesh(vv,ff,mat)


def rock(g,x,y,z,rx,ry,h,phase=0,mat='granite',lean=.08):
    """Weathered directional shoulder volume; no sphere primitives/no noise."""
    n=9;levels=[(0,.78),(.16,1),(.63,.97),(.9,.77),(1,.45)]
    vv=[]
    for j,(t,r) in enumerate(levels):
        for i in range(n):
            a=tau*i/n+phase;f=1+.09*sin(3*a+.7)+.04*cos(2*a-1)
            vv.append((x+rx*(r*f*cos(a)+lean*t),y+ry*(r*f*sin(a)-.09*t),z+h*(t+(.055*sin(a+.4)+.025*cos(2*a))*sin(pi*t))))
    ff=[tuple(range(n-1,-1,-1)),tuple(range((len(levels)-1)*n,len(levels)*n))]
    ff += [(j*n+i,j*n+(i+1)%n,(j+1)*n+(i+1)%n,(j+1)*n+i) for j in range(len(levels)-1) for i in range(n)]
    g.mesh(vv,ff,mat)


def pine(g,x,y,z,h=.38,r=.16,phase=0):
    g.beam((x,y,z),(x+.045*h,y,z+h*.86),.019*h/.4,'dark_wood',6)
    for j,(az,t,reach) in enumerate([(phase,.57,1.),(phase+2.7,.74,.84),(phase+4.5,.91,.62)]):
        xx=x+r*.50*cos(az);yy=y+r*.50*sin(az);zz=z+h*t
        g.beam((x,y,z+h*(t-.18)),(xx,yy,zz),.014*h/.4,'dark_wood',5)
        # Full connected canopy lenses, broad enough to read as pine pads.
        g.dome(xx,yy,zz,r*reach,.10*h/.4,'foliage',8,2)
        g.ring(xx,yy,zz-.035*h/.4,r*reach*.64,.035*h/.4,'foliage',8,top=r*reach)


def broadleaf(g,x,y,z,h=.40,r=.19,phase=0,wet=False):
    trunk=.025 if not wet else .033
    g.beam((x,y,z),(x+.04,y-.012,z+h*.70),trunk,'dark_wood',7)
    if wet:
        # Buttress-like flared roots, not a mangrove species assertion.
        for i in range(5):
            a=phase+tau*i/5;foot=(x+r*.60*cos(a),y+r*.60*sin(a),z)
            g.beam(foot,(x+.016,y,z+h*.29),.014,'dark_wood',5)
    for i,(t,s) in enumerate([(.69,.92),(.79,.90),(.93,.70)]):
        a=phase+tau*i/3;xx=x+r*.40*cos(a);yy=y+r*.4*sin(a);zz=z+h*t
        g.beam((x+.025,y,z+h*.46),(xx,yy,zz),trunk*.56,'dark_wood',5)
        g.dome(xx,yy,zz-r*.3,r*s,r*.72,'foliage',8,2)
        g.ring(xx,yy,zz-r*.50,r*s*.62,r*.20,'foliage',8,top=r*s)


def trees(g,positions,pine_style=False):
    ground=sample_ground(g)
    for i,p in enumerate(positions):
        x,y,h,r=p
        (pine if pine_style else broadleaf)(g,x,y,ground(x,y)-.018,h,r,i*.83)


def pebbles(g,positions,mat='granite'):
    ground=sample_ground(g)
    for i,(x,y,r,h) in enumerate(positions):rock(g,x,y,ground(x,y)-.025,r,r*.76,h,i*.71,mat)


def water(g,rx,ry,phase=0,height=.075,mat='water_deep',spacing=.12):
    boundary=g.outline(rx,ry,48,phase)
    g.land(boundary,lambda x,y:height*smooth(0,.20,g.taper(x,y,boundary)),mat,base=mat,spacing=spacing)
    return boundary


def edge_distance(x,y,boundary):
    result=1e9
    for a,b in zip(boundary,boundary[1:]+boundary[:1]):
        dx,dy=b[0]-a[0],b[1]-a[1]
        t=clamp(((x-a[0])*dx+(y-a[1])*dy)/(dx*dx+dy*dy))
        result=min(result,hypot(x-a[0]-dx*t,y-a[1]-dy*t))
    return result


def ridge_height(x,y,spine,width):
    value=0.
    for a,b in zip(spine,spine[1:]):
        dx,dy=b[0]-a[0],b[1]-a[1]
        t=clamp(((x-a[0])*dx+(y-a[1])*dy)/(dx*dx+dy*dy))
        d=hypot(x-a[0]-t*dx,y-a[1]-t*dy)
        h=a[2]+(b[2]-a[2])*t
        value=max(value,h*max(0,1-(d/width)**2)**1.2)
    return value


def geologic_mass(g,cx,cy,outline,sections,ground,mat='granite',phase=0,cap_rise=.04):
    """Explicit rock strata/shoulders. Each contour has authored width,
    eccentric offset and height; grooved outline corners track the cliff.
    Only the lowest rim samples the actual terrain, keeping its foot buried.
    """
    n=len(outline);vv=[];base=ground(cx,cy)-.035
    for j,(z,sx,sy,dx,dy) in enumerate(sections):
        for i,(xx,yy) in enumerate(outline):
            x=cx+xx*sx+dx;y=cy+yy*sy+dy
            a=atan2(yy,xx)
            zz=ground(x,y)-.025 if j==0 else base+z+.035*sin(2*a+phase)*min(1,z/.3)
            vv.append((x,y,max(.008,zz)))
    ff=[tuple(range(n-1,-1,-1))]
    for j in range(len(sections)-1):
        ff += [(j*n+i,j*n+(i+1)%n,(j+1)*n+(i+1)%n,(j+1)*n+i) for i in range(n)]
    # Inclined top wedges meet one interior crest, never a flat capped cylinder.
    top=vv[-n:];center=(sum(v[0] for v in top)/n,sum(v[1] for v in top)/n,sum(v[2] for v in top)/n+cap_rise)
    vv.append(center);ff += [((len(sections)-1)*n+i,(len(sections)-1)*n+(i+1)%n,len(vv)-1) for i in range(n)]
    g.mesh(vv,ff,mat)


def forest_tree(g,x,y,z,h=.30,r=.13,phase=0):
    # Two offset, unequal full canopies on branched stems; economical enough
    # for grouped forest cover while keeping the landform itself visible.
    g.beam((x,y,z),(x+.025,y,z+h*.77),.014,'dark_wood',5)
    for i,(t,scale) in enumerate([(.66,1.),(.88,.77)]):
        a=phase+i*2.7;xx=x+.38*r*cos(a);yy=y+.38*r*sin(a)
        g.beam((x,y,z+h*.45),(xx,yy,z+h*t),.010,'dark_wood',5)
        g.dome(xx,yy,z+h*t-r*.17,r*scale,r*.83,'foliage',7,2)
        g.ring(xx,yy,z+h*t-r*.35,r*scale*.65,r*.18,'foliage',7,top=r*scale)


def qinling_ridge(g):
    boundary=g.outline(1.76,1.39,58,.3)
    spines=[
        ([(-1.22,-.75,.30),(-.83,-.44,.62),(-.67,.04,1.00),(-.94,.48,1.17),(-.53,.91,.90),(-.10,1.11,.55)],.48),
        ([(1.07,-.84,.32),(.69,-.45,.69),(.87,.06,.94),(.53,.53,.80),(.89,.93,.65)],.46),
        ([(-.80,-.06,.83),(-1.22,.03,.51),(-1.45,.39,.18)],.35),
        ([(.74,.08,.87),(1.20,.35,.50),(1.44,.61,.20)],.35),
        ([(-.71,-.34,.55),(-.35,-.69,.32),(-.34,-1.10,.13)],.27),
        ([(-.59,.83,.75),(-.04,.96,.52),(.63,.88,.52)],.32)]
    def height(x,y):
        relief=max(ridge_height(x,y,line,w) for line,w in spines)
        return (.10+.06*smooth(-1,1,y)+relief)*smooth(0,.33,edge_distance(x,y,boundary))
    def app(p):
        x,y,z=p
        if z>.85 and -.87<x<-.52 and y<.20:return 'rock_light'
        if abs(x-(.04+.13*sin(1.8*y)))<.20:return 'grass_light'
        return 'grass_dark' if x<-.45 else 'grass'
    features=[(x,y) for line,w in spines for x,y,z in line]
    g.land(boundary,height,app,spacing=.11,features=features)
    ground=sample_ground(g)
    points=[(.04+.13*sin(1.8*y),y,ground(.04+.13*sin(1.8*y),y)+.01) for y in [-1.15+i*2.23/36 for i in range(37)]]
    ribbon(g,points,.042,'water_shallow')
    groups=[(-1.14,-.45),(-1.12,.24),(-.83,.77),(-.52,.37),(-.67,-.61),
            (.83,-.52),(1.10,.09),(.59,.47),(.90,.79),(-.28,1.02)]
    for j,(cx,cy) in enumerate(groups):
        for k,(dx,dy) in enumerate([(-.12,-.09),(.11,-.05),(.01,.13),(.18,.16)]):
            x=cx+dx;y=cy+dy
            if edge_distance(x,y,boundary)<.18:continue
            h=.24+.08*((j+k)%3)/2;r=.115+.018*(k%2)
            forest_tree(g,x,y,ground(x,y)-.02,h,r,j*.71+k)

def huashan_peaks(g):
    boundary=g.outline(1.55,1.25,52,.8)
    def height(x,y):
        return (.12+bump(x,y,-.02,.17,1.32,.70,.29,.8)+bump(x,y,-.55,-.42,.74,.60,.16))*smooth(0,.30,edge_distance(x,y,boundary))
    g.land(boundary,height,lambda p:'grass_dark' if p[2]<.21 else 'rock',spacing=.108)
    ground=sample_ground(g)
    # Concave facade corners are deep longitudinal flutes. The three unequal
    # shoulder setbacks are geometric, not extra subdivisions of a cone.
    outline=[(-.59,-.28),(-.32,-.44),(-.14,-.37),(-.04,-.22),(.05,-.40),(.25,-.42),(.40,-.24),(.51,-.10),(.40,.05),(.49,.25),(.20,.38),(.04,.30),(-.10,.41),(-.34,.29),(-.43,.10)]
    main=[(0,1.03,1.04,0,0),(.30,.94,.91,-.01,.01),(.83,.72,.79,.01,.02),(.96,.77,.75,.015,.015),(1.48,.59,.59,-.04,.015),(1.57,.65,.55,-.025,.005),(1.96,.35,.41,-.06,.035),(2.10,.25,.31,-.04,.04)]
    geologic_mass(g,-.52,.27,outline,main,ground,phase=.4,cap_rise=.05)
    right=[(0,.91,.88,0,0),(.33,.87,.83,.0,-.03),(.67,.64,.67,-.015,-.01),(.79,.71,.68,-.015,0),(1.21,.46,.54,-.04,.01),(1.33,.52,.52,-.04,.02),(1.63,.25,.30,-.07,.025),(1.72,.22,.20,-.05,.01)]
    geologic_mass(g,.63,.18,outline,right,ground,'rock_light',1.3,.035)
    # Asymmetric flank buttress continues the rock family without equal spikes.
    flank=[(0,.64,.61,0,0),(.28,.57,.54,.025,.02),(.65,.38,.44,.01,.04),(.76,.42,.42,.01,.04),(.97,.20,.24,-.025,.05)]
    geologic_mass(g,-1.05,-.31,outline,flank,ground,'granite',2.5,.035)
    geologic_mass(g,1.01,.59,outline,[(z*.79,sx*.64,sy*.69,dx,dy) for z,sx,sy,dx,dy in flank],ground,'granite',.7,.025)
    # A broad saddle/slanted splitter joins the principal rocks at lower level.
    saddle=[(-.30,-.25),(.38,-.27),(.45,.04),(.30,.25),(-.31,.30),(-.44,.09)]
    geologic_mass(g,.09,.26,saddle,[(0,1,1,0,0),(.46,.87,.89,0,0),(.71,.71,.64,-.04,.04),(.76,.36,.45,-.035,.03)],ground,'rock',1.0,.08)
    trees(g,[(-1.17,-.55,.26,.15),(-.66,-.67,.26,.15),(-1.14,.76,.23,.13),(.52,-.46,.26,.14),(1.20,.26,.23,.13),(.14,-.88,.25,.15),(-.92,.39,.22,.13),(1.05,.15,.18,.12)],True)
    pebbles(g,[(-.79,-.83,.17,.16),(.77,-.66,.20,.17),(.19,.83,.17,.18)],'rock_light')

def qingyuan_granite(g):
    boundary=g.outline(1.51,1.19,52,.4)
    def height(x,y):return (.07+bump(x,y,-.08,.15,1.35,1.12,.52,1.15))*smooth(0,.29,edge_distance(x,y,boundary))
    g.land(boundary,height,lambda p:'grass_light' if p[0]>.3 else 'grass',spacing=.108)
    ground=sample_ground(g)
    # Three short, offset broken shoulders, each nested at one tor's foot.
    # No common front bar bridges the two crevices: exposed ground between
    # these unequal chunks lets both deep diagonal cracks continue downward.
    shoulders=[
      (-.61,-.035,[(-.28,-.13),(-.10,-.22),(.19,-.12),(.22,.11),(.04,.18),(-.20,.14)],.16,.4),
      (-.04,-.09,[(-.19,-.10),(.02,-.17),(.20,-.05),(.13,.15),(-.14,.13)],.10,1.7),
      (.63,.015,[(-.18,-.15),(.05,-.23),(.21,-.08),(.17,.18),(-.11,.19),(-.22,.03)],.19,2.8)]
    for x,y,poly,h,phase in shoulders:
        geologic_mass(g,x,y,poly,[(0,1,1,0,0),(h*.62,.95,.91,.008,.015),(h,.72,.74,.02,.01)],ground,'rock',phase,.015)
    slabs=[
      (-.61,.24,[(-.30,-.25),(-.02,-.31),(.15,-.17),(.21,.11),(.11,.36),(-.16,.33),(-.33,.10)],[(0,1.15,1.08,0,0),(.24,1.03,1.03,.01,0),(.55,.97,.92,.04,.02),(.69,.75,.77,.08,.02),(.87,.57,.52,.065,.05)],'granite'),
      (-.07,.23,[(-.20,-.34),(.12,-.29),(.30,-.10),(.18,.32),(-.09,.38),(-.21,.12)],[(0,1.08,1.05,0,0),(.27,1.03,.94,0,.03),(.52,.92,.83,.025,.055),(.65,.66,.74,.00,.02)],'rock_light'),
      (.62,.33,[(-.20,-.37),(.20,-.27),(.30,-.02),(.22,.33),(-.17,.30),(-.29,.06)],[(0,1.16,1.10,0,0),(.24,1.02,1.00,-.015,0),(.45,.98,.90,-.045,.025),(.67,.61,.75,-.09,.025),(.73,.43,.50,-.085,.015)],'granite')]
    # Main tor feet still use the unchanged actual terrain sample, so the
    # small foreground shoulder edit cannot move or raise the three rocks.
    for i,(x,y,poly,sections,mat) in enumerate(slabs):geologic_mass(g,x,y,poly,sections,ground,mat,i*.9,.05)
    # Fallen long wedge at front is a different silhouette, not a mini cylinder.
    wedge=[(-.43,-.15),(.31,-.22),(.43,-.04),(.24,.24),(-.28,.18)]
    geologic_mass(g,-.68,-.47,wedge,[(0,1,1,0,0),(.16,.97,.87,.03,0),(.29,.67,.60,.06,.025)],ground,'rock_light',1.8,.025)
    pebbles(g,[(.66,-.40,.22,.23),(.26,-.66,.16,.15),(-.98,-.34,.13,.13),(-.28,-.64,.12,.13),(.86,.67,.15,.17),(.49,-.72,.10,.10)],'granite')
    trees(g,[(-1.16,-.24,.35,.20),(-1.01,.47,.40,.21),(-.63,.88,.29,.18),(.01,.94,.27,.17),(.93,.48,.35,.20),(1.12,-.08,.35,.20),(.75,-.68,.28,.17),(-.35,-.89,.29,.19),(-.94,-.66,.27,.17)],False)

def boat_pier(g,x,z,h,width=.18,length=.74,mat='rock'):
    shape=[(-width*.50,-length*.24),(0,-length*.60),(width*.50,-length*.24),(width*.50,length*.40),(-width*.50,length*.40)]
    vv=[]
    for t,scale in [(0,1.20),(.12,1.14),(.83,.82),(1,.84)]:
        vv += [(x+xx*scale,yy*scale,z+h*t) for xx,yy in shape]
    ff=[tuple(range(4,-1,-1)),tuple(range(15,20))]
    ff += [(j*5+i,j*5+(i+1)%5,(j+1)*5+(i+1)%5,(j+1)*5+i) for j in range(3) for i in range(5)]
    g.mesh(vv,ff,mat)


def luoyang_bridge(g):
    water(g,1.78,1.10,.2,spacing=.10,mat='water_shallow')
    # Asymmetrical natural tidal shores, not architectural plinths.
    for sign in (-1,1):
        boundary=[(sign*x,y) for x,y in [(1.78,-.63),(1.55,-.82),(1.24,-.76),(1.34,-.39),(1.21,.22),(1.43,.63),(1.73,.61)]]
        if sign<0:boundary.reverse()
        g.land(boundary,lambda x,y:.18*smooth(0,.19,g.taper(x,y,boundary)),'sand',base='sand',spacing=.095)
    for i in range(8):
        x=-1.37+i*2.74/7
        boat_pier(g,x,.022,.13,.27,.85,'rock_dark') # broad stone raft, partly below tidal surface
        boat_pier(g,x,.11,.39,.17,.66,'rock')
        g.box(x,.0,.485,.28,.50,.064,'rock_light')
    # Eight supports, seven representative flat beam spans; no hidden arches.
    for i in range(7):
        x=-1.37+(i+.5)*2.74/7
        for j in range(3):g.box(x,(j-1)*.14,.541,.3914,.137,.060,'rock_light')
    for sign in (-1,1):
        for i in range(25):
            x=-1.50+i*.125;g.box(x,sign*.235,.547,.033,.033,.182,'rock_light')
            if i<24:g.box(x+.0625,sign*.235,.665,.126,.026,.031,'rock_light')
        g.box(sign*1.5,0,.177,.32,.48,.365,'rock')
    for i in range(12):
        x=-1.28+(i%6)*.47;y=-.72+(i//6)*1.31
        pts=[(x+.055*j,y+.025*sin(j*.6+i),.081) for j in range(5)]
        ribbon(g,pts,.010,'water_light',.003)
    pebbles(g,[(-1.49,-.63,.12,.12),(1.52,.40,.12,.11),(-1.53,.30,.10,.10),(1.45,-.62,.13,.10)],'rock')


def namsan_hills(g):
    boundary=g.outline(1.47,1.20,48,.8)
    def height(x,y):
        left=bump(x,y,-.52,.37,.65,.70,1.08,1.22)
        right=bump(x,y,.66,.34,.55,.67,.76,1.18)
        return (.10+max(left,right)+bump(x,y,0,-.48,1.31,.63,.22))*smooth(0,.29,g.taper(x,y,boundary))
    g.land(boundary,height,lambda p:'grass' if p[2]<.45 else 'granite',spacing=.11,features=[(-.52,.37),(.66,.34)])
    pebbles(g,[(-.73,-.36,.36,.21),(.78,-.22,.29,.29),(-.88,.60,.21,.30),(.12,-.68,.25,.18)],'granite')
    ground=sample_ground(g)
    pts=[(.13+.16*sin(y*3),y,ground(.13+.16*sin(y*3),y)+.012) for y in [-.93+i*.045 for i in range(32)]]
    ribbon(g,pts,.068,'sand',.006)
    trees(g,[(-1.04,-.26,.36,.18),(-.86,.20,.32,.18),(-.64,.85,.29,.16),(-.25,.64,.33,.17),(.34,.65,.33,.17),(.95,.64,.31,.16),(1.04,-.12,.31,.17),(.64,-.53,.32,.18),(-.36,-.79,.29,.17),(.23,-.31,.28,.17),(-.97,-.63,.29,.15)],True)


def munmu_coast(g):
    water(g,1.55,1.23,.8,.082,'water_deep',spacing=.085)
    # Hand-drawn eroded lobes have bays/slots and sloping low backs. There is
    # no radius-based plateau and no repeated rock sitting atop each lobe.
    outlines=[
      [(-1.28,.08),(-1.14,-.10),(-.83,-.04),(-.68,.03),(-.58,-.08),(-.32,-.06),(-.27,.19),(-.43,.26),(-.26,.38),(-.34,.64),(-.66,.80),(-1.00,.71),(-1.22,.51),(-1.13,.31)],
      [(.22,.27),(.44,.25),(.52,.35),(.69,.23),(1.12,.30),(1.30,.54),(1.11,.71),(.98,.61),(.83,.85),(.49,.85),(.24,.62)],
      [(-1.06,-.67),(-.96,-.89),(-.61,-.95),(-.46,-.77),(-.26,-.72),(-.17,-.49),(-.35,-.35),(-.57,-.36),(-.69,-.25),(-.84,-.38),(-1.16,-.44)],
      [(.24,-.73),(.56,-.83),(.73,-.71),(1.09,-.70),(1.28,-.53),(1.15,-.31),(.89,-.24),(.76,-.39),(.63,-.27),(.44,-.30),(.34,-.47),(.17,-.46)]]
    configs=[(-.79,.41,.31,-.11),(.74,.55,.23,.06),(-.70,-.57,.22,.08),(.75,-.49,.18,-.05)]
    for i,(boundary,(cx,cy,h,tilt)) in enumerate(zip(outlines,configs)):
        def height(x,y,boundary=boundary,cx=cx,cy=cy,h=h,tilt=tilt,i=i):
            shell=max(.075,h+.09*sin((x-cx)*2.2)+tilt*(y-cy))
            # Actual negative channels: incision crosses a shoulder and opens
            # through one edge. Different orientations keep the islets unequal.
            groove=abs((x-cx)*.55+(y-cy)*(1 if i%2 else -1)-.045)
            incision=.17*exp(-(groove/.052)**2)
            shoulder=.055*sin((x-cx)*5+(y-cy)*2)
            return max(.024,(shell+shoulder-incision))*smooth(0,.22,edge_distance(x,y,boundary))
        g.land(boundary,height,lambda p:'rock_dark' if p[2]<.115 else ('rock_light' if p[0]>.4 else 'granite'),base='rock_dark',spacing=.053)
    for i in range(13):
        a=tau*i/13+.12;x=1.25*cos(a);y=1.0*sin(a)
        pts=[(x+.09*cos(a+pi/2)*j,y+.09*sin(a+pi/2)*j,.086) for j in (-1,0,1)]
        ribbon(g,pts,.012,'water_light',.003)

def wakakusa_hill(g):
    boundary=g.outline(1.50,1.34,50,.5)
    # Three overlapping smooth slopes, each with its own brow/shoulder.
    hills=[(-.11,-.64,1.23,.63,.47),(.12,-.04,1.15,.67,.78),(-.15,.58,.91,.69,1.03)]
    def height(x,y):return (.065+max(bump(x,y,cx,cy,rx,ry,h,.75) for cx,cy,rx,ry,h in hills))*smooth(0,.26,g.taper(x,y,boundary))
    features=[(cx,cy) for cx,cy,*_ in hills]
    g.land(boundary,height,lambda p:'grass_light' if p[1]<-.32 else 'grass',spacing=.09,features=features)
    ground=sample_ground(g)
    points=[]
    for i in range(57):
        y=-1.06+i*2.04/56;x=.32*sin(5*y+.3)
        points.append((x,y,ground(x,y)+.012))
    ribbon(g,points,.047,'sand',.007)
    trees(g,[(-1.20,-.52,.25,.14),(-1.21,.03,.28,.14),(-1.06,.51,.31,.17),(-.75,.97,.26,.14),(.37,1.00,.23,.13),(.98,.43,.28,.15),(1.19,-.18,.26,.14),(.94,-.76,.23,.13)],False)


def mount_fuji(g):
    boundary=g.outline(1.66,1.43,56,.2)
    def radius(x,y):return hypot(x/1.64,y/1.41)
    def height(x,y):
        r=radius(x,y);a=atan2(y/1.41,x/1.64)
        if r<.125:return 1.51+.32*(r/.125)**1.6 # actual bowl below rim
        t=clamp((r-.125)/.875)
        profile=1.83*(1-t)**1.56
        folds=.070*sin(10*a+.4)*sin(pi*t)*(1-t)+.034*sin(17*a)*sin(pi*t)**2
        return max(0,profile+folds)*smooth(0,.09,g.taper(x,y,boundary))
    def snowfield(p):
        x,y,z=p;a=atan2(y/1.41,x/1.64)
        return z-(1.16+.12*sin(5*a)+.055*sin(9*a+.6))
    def app(p):
        if p[2]<.27:return 'grass_dark'
        if radius(p[0],p[1])<.115:return 'slate'
        return (snowfield,'slate','snow')
    features=[(0,0)]
    for r in (.05,.125,.20,.35,.57,.79):
        for i in range(40):
            a=tau*i/40;features.append((1.64*r*cos(a),1.41*r*sin(a)))
    g.land(boundary,height,app,base='earth',spacing=.105,features=features)
    positions=[]
    for i in range(12):
        a=tau*i/12+.14;positions.append((1.40*cos(a),1.17*sin(a),.19+.025*sin(i),.095))
    trees(g,positions,True)


def reeds(g,x,y,z,phase=0):
    for i in range(5):
        a=phase+i*2.4;dx=.028*cos(a);dy=.028*sin(a);h=.09+.025*(i%3)
        g.beam((x+dx,y+dy,z),(x+dx*2.8,y+dy*2.8,z+h),.006,'reed',4)


def tonle_sap_floodforest(g):
    water(g,1.50,1.33,.9,.132,'water_shallow',spacing=.12)
    for sign in (-1,1):
        boundary=[(sign*x,y) for x,y in [(.39,-1.06),(.75,-1.17),(1.26,-.84),(1.48,-.26),(1.29,.58),(.96,1.06),(.51,.89),(.40,.51),(.58,.06),(.38,-.41)]]
        if sign<0:boundary.reverse()
        # Most ground is drowned; occasional mud shoulders remain at edges.
        g.land(boundary,lambda x,y:.144*smooth(0,.30,edge_distance(x,y,boundary)),'mud',base='mud',spacing=.11)
    positions=[(-.87,-.80,.75,.28),(-1.06,-.24,.86,.30),(-.75,.40,.88,.32),(-.85,.91,.72,.27),(.84,-.69,.78,.30),(1.13,-.19,.90,.29),(.73,.30,.84,.30),(.80,.88,.74,.27)]
    for i,(x,y,h,r) in enumerate(positions):
        # Plain trunks enter water. Roots are a submerged basal flare only;
        # the old visible five-legged prop-root scaffold is entirely removed.
        broadleaf(g,x,y,.055,h,r,i*.7,False)
        g.ring(x,y,.045,.047,.068,'dark_wood',7,top=.029)
    ground=sample_ground(g)
    for i in range(16):
        sign=-1 if i%2 else 1;y=-.97+(i//2)*.255;x=sign*(.43+.08*sin(i))
        reeds(g,x,y,.122,i)
    for i in range(12):
        x=.23*sin(i*1.7);y=-.91+i*.16
        g.ring(x,y,.135,.025,.003,'reed',7,scale_y=.65,rotation=i*.7)
    for i in range(5):
        y=-.82+i*.39;ribbon(g,[(-.21,y,.137),(0,y+.018,.137),(.16,y+.012,.137)],.012,'water_light',.003)

def phnom_kulen_waterfall(g):
    water(g,1.55,1.34,.3,.085,'water_shallow',spacing=.105)
    # Two explicit sandstone volumes with mid-height strata and offset lips.
    # These are closed rock bodies, so no top-to-ground heightfield fan teeth.
    ground=sample_ground(g)
    lower=[(-1.43,-.58),(-1.18,-.80),(-.73,-.72),(-.42,-.81),(.06,-.70),(.53,-.79),(.99,-.61),(1.41,-.40),(1.45,.31),(1.16,.91),(.41,1.10),(-.51,1.03),(-1.26,.75)]
    geologic_mass(g,0,0,lower,[(0,1,1,0,0),(.13,.98,.98,0,.025),(.25,.93,.95,.025,.045),(.37,.94,.94,.015,.08),(.50,.84,.87,.005,.12),(.56,.85,.86,.00,.14)],ground,'rock',.3,.015)
    upper=[(-1.18,-.04),(-.91,-.22),(-.51,-.14),(-.18,-.22),(.18,-.16),(.58,-.24),(.92,-.07),(1.22,.10),(1.21,.66),(.79,1.12),(.10,1.18),(-.72,1.04),(-1.19,.59)]
    # Start inside the lower tier and terminate on a broad irregular top plane.
    support=lambda x,y:.30
    geologic_mass(g,0,0,upper,[(0,.98,.99,0,0),(.18,.98,.98,0,.015),(.32,.94,.94,.025,.02),(.46,.96,.92,.01,.035),(.65,.90,.90,.0,.05),(.73,.91,.88,-.01,.06)],support,'rock_light',.9,.025)
    stone=sample_ground(g)
    # Attach a calm upstream creek and an exposed intermediate bed. Water paths
    # sample the actual top facets; two short falls replace the tall curtain.
    def stream(points,w):
        p=[(x,y,stone(x,y)+.018) for x,y in points];ribbon(g,p,w,'water_shallow',.008);return p
    upper_path=stream([(.04+.025*sin((y+.09914)*3),y) for y in [1.03-i*1.12914/24 for i in range(25)]],.24)
    middle_path=stream([(.04,-.29),(.02,-.35),(.03,-.41),(.025,-.46803)],.33)
    def fall(start,end,width):
        n=11;m=10;rows=[]
        for j in range(n):
            t=j/(n-1);x=start[0]*(1-t)+end[0]*t;y=start[1]*(1-t)+end[1]*t-.035*sin(pi*t);z=start[2]*(1-t)+end[2]*t
            row=[]
            for k in range(m+1):
                px=x+(k/m-.5)*width*(1+.16*t)
                py=y-.012*sin(k*1.5)*sin(pi*t)
                # Follow each actual ledge across the width before free fall;
                # asymmetric lips must not bury a flat water cross-section.
                row.append((px,py,max(z,stone(px,py)+.025)))
            rows.append(row)
        # Single continuous curtain volume with different material strips.
        for k in range(m):
            vv=[]
            for row in rows:vv += [row[k],row[k+1],(row[k][0],row[k][1]+.008,row[k][2]),(row[k+1][0],row[k+1][1]+.008,row[k+1][2])]
            ff=[(0,1,3,2)]
            for j in range(n-1):
                a=j*4;b=a+4;ff += [(a,b,b+1,a+1),(a+2,a+3,b+3,b+2),(a,a+2,b+2,b),(a+1,b+1,b+3,a+3)]
            a=(n-1)*4;ff.append((a,a+2,a+3,a+1));g.mesh(vv,ff,'water_light' if k%3 else 'water_shallow')
    fall(upper_path[-1],middle_path[0],.28)
    fall(middle_path[-1],(.025,-.90,.09),.36)
    for i in range(4):
        y=-.96-i*.065;ribbon(g,[(-.33,y,.092),(-.12,y-.022,.092),(.13,y-.028,.092),(.29,y,.092)],.010,'water_light',.003)
    pebbles(g,[(-.82,-.79,.20,.21),(.83,-.69,.22,.20),(-1.17,-.21,.16,.19),(1.20,.04,.15,.19)],'rock_light')
    trees(g,[(-.95,.45,.38,.23),(-.68,.86,.37,.22),(-.18,.97,.31,.19),(.54,.86,.38,.23),(.96,.40,.37,.22),(-1.14,-.45,.31,.17),(.91,-.47,.30,.18)],False)

BUILDERS={
    'qinling_ridge':qinling_ridge,'huashan_peaks':huashan_peaks,
    'qingyuan_granite':qingyuan_granite,'luoyang_bridge':luoyang_bridge,
    'namsan_hills':namsan_hills,'munmu_coast':munmu_coast,
    'wakakusa_hill':wakakusa_hill,'mount_fuji':mount_fuji,
    'tonle_sap_floodforest':tonle_sap_floodforest,'phnom_kulen_waterfall':phnom_kulen_waterfall}
FEATURES={
    'qinling_ridge':['终南山代表段：连续双侧森林山脊','开敞弯曲林谷与细溪','侧坡松冠与裸岩肩部'],
    'huashan_peaks':['不等高陡峭花岗岩峰','细鞍相连且峰肩分叉','少量岩缝松树；无雪'],
    'qingyuan_granite':['低林山中的圆浑花岗岩巨石','成对峰肩间有裂隙','石块嵌入山体而非浮置'],
    'luoyang_bridge':['七跨代表性平石梁桥，非拱桥','八座船形石墩及水下宽筏基','潮汐水面与不对称低岸'],
    'namsan_hills':['两个圆缓低峰与自然岩坡','前向开敞曲谷','不规则松林，不重复城内瞻星台'],
    'munmu_coast':['四组低矮近岸岩礁','十字方向水道通向中央静水穴','低岩肩与浅色碎浪，无墓碑'],
    'wakakusa_hill':['三级重叠圆缓草坡','连续弯曲登山小径','树木只点缀坡侧，保留开敞草面'],
    'mount_fuji':['宽底连续火山锥与内凹顶口','雪线直接切分山面，不另罩悬浮雪壳','季节性不齐雪缘及低山脚林带'],
    'tonle_sap_floodforest':['淡水洪泛林的中央开水道','淹水直立树干、沉水低根张与层叠阔叶冠','泥滩、芦苇与零散水面叶片'],
    'phnom_kulen_waterfall':['上游溪流连至砂岩崖唇','两级砂岩崖肩和连续短落水及下方潭面','连续砂岩高台、局部退台与林冠']}
