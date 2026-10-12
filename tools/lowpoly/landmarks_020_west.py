"""Twelve source-only geographic scenery miniatures for library 020.

Coordinates are Blender Z-up; natural boundaries taper to Z=0.  Deliberate
historical/geographic simplification is documented in the geography plan.
No production world coordinates, exporters, or scene mutations live here.
"""
from math import sin, cos, pi, tau, sqrt, atan2, hypot, exp
from cities_019_landmarks import sector
from library_landforms_018 import inside_polygon


def clamp(t, a=0., b=1.):
    return max(a, min(b, t))


def smooth(a, b, x):
    t = clamp((x-a)/(b-a))
    return t*t*(3-2*t)


def lerp(a, b, t):
    return a+(b-a)*t


def polygon_solid(g, xy, z, thickness, mat):
    """Closed contour; shallow water remains geometrical, not a decal."""
    n = len(xy)
    v = [(x,y,z-thickness) for x,y in xy]+[(x,y,z) for x,y in xy]
    f = [tuple(range(n-1,-1,-1)),tuple(range(n,2*n))]
    f += [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
    g.mesh(v,f,mat)


def wall_segment(g, a, b, bottom_a, bottom_b, height, width, mat='sandstone'):
    dx,dy=b[0]-a[0],b[1]-a[1]
    length=hypot(dx,dy); nx,ny=-dy/length*width/2,dx/length*width/2
    hh=height if isinstance(height,(tuple,list)) else (height,height)
    v=[(p[0]+s*nx,p[1]+s*ny,z+(hh[i] if level else 0)) for level in (0,1)
       for p,z,s,i in ((a,bottom_a,-1,0),(b,bottom_b,-1,1),(b,bottom_b,1,1),(a,bottom_a,1,0))]
    g.mesh(v,[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)],mat)


def crenel_wall(g,a,b,zfn,height=.40,width=.10,mat='sandstone',gate=False):
    """Wall has a terrain-sampled foot and constant height above that foot."""
    length=hypot(b[0]-a[0],b[1]-a[1]); n=max(3,int(length/.105))
    for i in range(n):
        u,v=i/n,(i+1)/n
        p=(lerp(a[0],b[0],u),lerp(a[1],b[1],u))
        q=(lerp(a[0],b[0],v),lerp(a[1],b[1],v))
        if gate and n//2-1 <= i <= n//2+1:
            continue
        wall_segment(g,p,q,zfn(*p)-.012,zfn(*q)-.012,height,width,mat)
        if i%2==0:
            wall_segment(g,p,q,zfn(*p)+height-.016,zfn(*q)+height-.016,.095,width+.014,'cream')
    if gate:
        i=n//2
        u=(i+.5)/n;x,y=lerp(a[0],b[0],u),lerp(a[1],b[1],u)
        opening=3*length/n/1.36
        g.arch(x,y,zfn(x,y)-.012,opening,height-.035,width,mat,atan2(b[1]-a[1],b[0]-a[0]),9)


def shrub(g,x,y,z=.08,r=.10):
    for dx,dy,h,k in [(-.35,0,.54,.75),(.30,.12,.64,.82),(.03,-.15,.8,.8)]:
        g.dome(x+dx*r,y+dy*r,z,r*k,r*h,'foliage',8,3)


def date_palm(g,x,y,z=.12,h=.85,r=.36,phase=0.):
    """Curved trunk, eight connected arching fronds and sparse leaflets."""
    leanx=.055*cos(phase);leany=.055*sin(phase)
    pp=[(x+leanx*(i/4)**1.5,y+leany*(i/4)**1.5,z+h*i/4) for i in range(5)]
    for i in range(4):
        g.beam(pp[i],pp[i+1],.030-i*.003,'dark_wood',8)
    top=pp[-1]
    for j in range(8):
        a=phase+j*tau/8
        rr=r*(.89+.10*sin(j*2.3))
        stations=[0.,.30,.62,1.]
        pts=[(rr*t,0,.13*sin(pi*t)-.10*t) for t in stations]
        v=[]
        for k,(xx,yy,zz) in enumerate(pts):
            ww=.015 if k==0 else (.031 if k<3 else .002)
            v += [(xx,-ww,zz),(xx,ww,zz+.012)]
        g.mesh(v,[(0,2,3,1),(2,4,5,3),(4,6,7,5)],'foliage',top,a)
        for t in (.28,.47,.65,.81):
            xx=rr*t;zz=.13*sin(pi*t)-.10*t;ll=.105*(1-.48*t)
            for sign in (-1,1):
                vv=[(xx-.028,0,zz+.010),(xx+.047,0,zz+.011),
                    (xx+.071,sign*ll,zz-.045),(xx+.025,sign*ll*.77,zz-.026)]
                # A folded paired leaflet has real thickness along its spine.
                vv += [(xx+.025,sign*ll*.35,zz-.004)]
                g.mesh(vv,[(0,1,4),(1,2,4),(2,3,4),(3,0,4)],'foliage',top,a)
    g.dome(*top,.045,.055,'dark_wood',8,3)


def cypress(g,x,y,z,h=.40):
    g.beam((x,y,z),(x+.012,y,z+h*.55),.022,'dark_wood',7)
    g.ring(x,y,z+h*.20,h*.13,h*.53,'foliage',9,top=h*.075)
    g.ring(x,y,z+h*.73,h*.075,h*.27,'foliage',9,top=0)


def terrain(g,rx,ry,zfn,matfn,spacing=.095,phase=.6,features=None,edges=None,base='earth'):
    bound=g.outline(rx,ry,56,phase,.025)
    height=lambda x,y:zfn(x,y)*g.taper(x,y,bound)
    g.land(bound,height,matfn,base,spacing,features,edges)
    return terrain_sampler(g)


def terrain_sampler(g):
    """Capture real authored terrain triangles before adding any vegetation."""
    triangles=[]
    for vertices,faces in g.buckets.values():
        for face in faces:
            for i in range(1,len(face)-1):
                a,b,c=[vertices[j] for j in (face[0],face[i],face[i+1])]
                den=(b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
                if abs(den)>1e-12:triangles.append((a,b,c,den))
    def sample(x,y):
        out=0.
        for a,b,c,den in triangles:
            u=((b[1]-c[1])*(x-c[0])+(c[0]-b[0])*(y-c[1]))/den
            v=((c[1]-a[1])*(x-c[0])+(a[0]-c[0])*(y-c[1]))/den
            if u>=-1e-7 and v>=-1e-7 and u+v<=1.0000001:
                out=max(out,u*a[2]+v*b[2]+(1-u-v)*c[2])
        return out
    return sample


def roman_aqueduct(g):
    def h(x,y):
        return .14+.06*cos(x*1.6)*cos(y*2.0)+.035*sin(x*3+y)
    z=terrain(g,1.70,.73,h,'grass',.085)
    base=.20; pitch=.455; opening=pitch/1.36
    for i in range(6):
        x=(i-2.5)*pitch
        g.arch(x,0,base,opening,1.00,.235,'sandstone',steps=12)
    for i in range(7):
        x=(i-3)*pitch
        zz=z(x,0)
        g.box(x,0,zz-.005,.12,.29,base-zz+.045,'sandstone')
        g.box(x,0,base+.55,.115,.265,.050,'cream')
    # Filled spandrels share the exact exterior arch curvature. No rectangular
    # backing wall seals the open arches below the spring line.
    rr=opening*.68; spring=base+1.-opening/2
    for i in range(6):
        x=(i-2.5)*pitch
        for j in range(12):
            a0=j*pi/12;a1=(j+1)*pi/12
            xa,xb=x+rr*cos(a0),x+rr*cos(a1)
            za,zb=spring+rr*sin(a0),spring+rr*sin(a1)
            wall_segment(g,(xa,0),(xb,0),za-.006,zb-.006,
                         (1.336-za,1.336-zb),.236,'sandstone')
    g.box(0,0,1.322,2.93,.34,.073,'cream')
    g.box(0,0,1.395,2.91,.19,.018,'water_deep')
    for side in (-1,1):
        # Continuous open channel sidewall, three purposeful exposed joints.
        for i in range(4):
            g.box((i-1.5)*.718,side*.139,1.392,.716,.079,.107,'sandstone')
        g.box(0,side*.139,1.493,2.88,.09,.027,'cream')
    for x,y,hh,rr in [(-1.17,-.42,.43,.25),(1.20,.37,.49,.27)]:
        g.tree(x,y,hh,rr,z(x,y))
    for x,y in [(-.6,.39),(.30,-.42),(.75,.41),(-1.35,.12)]:shrub(g,x,y,z(x,y),.095)


def lake_albano(g):
    # Radial constraint rings align the water shore and sharp crater shoulders.
    def radius(x,y):
        a=atan2(y/1.13,x/1.55)
        return hypot(x/1.55,y/1.13)/(1+.04*sin(3*a+.3)),a
    def h(x,y):
        r,a=radius(x,y)
        if r<.57:return .07
        profile=[(.57,.07),(.61,.14),(.68,.29),(.77,.60),(.82,.68),(.88,.49),(1.07,0)]
        for (u,za),(v,zb) in zip(profile,profile[1:]):
            if r<=v:
                out=lerp(za,zb,clamp((r-u)/(v-u)))
                return out*(1+.22*sin(a+.5)+.10*sin(3*a))
        return 0.
    features=[];edges=[]
    for rr in (.57,.61,.68,.77,.82,.88,.95):
        start=len(features)
        for i in range(48):
            a=tau*i/48;f=1+.04*sin(3*a+.3)
            features.append((1.55*rr*f*cos(a),1.13*rr*f*sin(a)))
        edges += [(start+i,start+(i+1)%48) for i in range(48)]
    def color(p):
        rr,_=radius(p[0],p[1])
        if rr<.75:return (lambda q:radius(q[0],q[1])[0]-.67,'grass','rock')
        return (lambda q:radius(q[0],q[1])[0]-.82,'rock','grass')
    z=terrain(g,1.65,1.23,h,color,.09,features=features,edges=edges)
    xy=[(.905*(1+.035*sin(3*a))*cos(a),.66*(1+.025*cos(5*a))*sin(a)) for a in [tau*i/64 for i in range(64)]]
    polygon_solid(g,xy,.125,.020,'water_deep')
    for i,a in enumerate((.15,.68,1.19,1.79,2.24,2.89,3.57,4.28,5.55)):
        x,y=1.31*cos(a),.96*sin(a)
        g.tree(x,y,.27+.065*(i%3),.13+.014*(i%2),z(x,y)-.006)
    for a in (1.1,3.2,4.6):
        x,y=1.38*cos(a),1.00*sin(a);cypress(g,x,y,z(x,y),.34)


def river_sculpt(g,kind='tigris'):
    """Natural perimeter with exact constrained continuous shore contours."""
    bound=g.outline(1.57,1.50,64,.91,.025)
    def water(y):
        t=(y+1.5)/3.0
        if kind=='bosphorus':return .16*sin(t*tau+.5),.30+.07*sin(t*pi)
        if kind=='nile':return -.47+.12*sin(t*tau),.295+.035*cos(t*pi)
        return .43*sin(t*tau-.60),.235+.035*cos(t*2*tau)
    def dist(x,y):
        cx,w=water(y)
        return abs(x-cx)-w
    def height(x,y):
        d=dist(x,y)
        if d<=0:return .088
        if d<.10:return lerp(.088,.127,smooth(0,.10,d))
        if kind=='bosphorus':
            side=1 if x>water(y)[0] else -1
            ridge=.56 if side>0 else .37
            shape=exp(-((d-.47)/.30)**2)
            ribs=1+.13*sin(y*6.5+side)+.08*cos(y*11+x*3)
            return .125+ridge*shape*ribs*smooth(0,.42,1.54-abs(y))
        return .145+.012*cos(x*3+y)
    features=[];edges=[]
    for side in (-1,1):
        for margin in (-.07,0,.10,.30,.52):
            previous=None
            for j in range(65):
                y=-1.51+3.02*j/64;cx,w=water(y)
                pt=(cx+side*(w+margin),y)
                if not inside_polygon(pt,bound):previous=None;continue
                idx=len(features);features.append(pt)
                if previous is not None:edges.append((previous,idx))
                previous=idx
    def appearance(p):
        x,y,z=p;d=dist(x,y)
        if d<-.035:return (lambda q:dist(q[0],q[1])+.070,'water_deep','water_shallow')
        if d<.045:return (lambda q:dist(q[0],q[1]),'water_shallow','sand_light')
        if kind=='bosphorus':
            if d<.17:return (lambda q:dist(q[0],q[1])-.10,'sand_light','rock')
            return (lambda q:dist(q[0],q[1])-.30,'rock','grass')
        if d<.17:return (lambda q:dist(q[0],q[1])-.10,'sand_light','grass')
        return (lambda q:dist(q[0],q[1])-.62+.08*sin(q[1]*3),'grass','sand')
    g.land(bound,lambda x,y:height(x,y)*g.taper(x,y,bound),appearance,'earth',.088,features,edges)
    return terrain_sampler(g)


def bosphorus_strait(g):
    z=river_sculpt(g,'bosphorus')
    for x,y,h,r in [(-1.0,-.65,.35,.18),(-1.10,.64,.32,.16),(.89,-.72,.37,.19),
                     (1.06,.02,.34,.18),(.99,.80,.41,.20),(.65,1.04,.29,.14)]:
        g.tree(x,y,h,r,z(x,y)-.01)
    for x,y in [(-1.11,-.95),(-.97,.92),(1.16,.47),(.76,-1.0)]:cypress(g,x,y,z(x,y)-.01,.35)
    for x,y in [(-.78,-.25),(.74,.48),(.65,-.90),(-.73,.70)]:shrub(g,x,y,z(x,y),.11)


def rumeli_fortress(g):
    def h(x,y):return .16+.42*exp(-((x-.1)**2/.96+(y-.18)**2/.62))+.10*y
    z=terrain(g,1.58,1.15,h,lambda p:'grass' if p[2]>.26 else 'rock',.08)
    towers=[(-.84,-.40,.29,.75),(.86,-.23,.34,.84),(.06,.68,.31,1.12)]
    perimeter=[(-.84,-.40),(-.39,-.71),(.28,-.69),(.86,-.23),(.68,.46),(.06,.68),(-.53,.45)]
    for i,(a,b) in enumerate(zip(perimeter,perimeter[1:]+perimeter[:1])):
        crenel_wall(g,a,b,z,.39,.115,gate=i==1)
    for x,y,r,hgt in towers:
        base=z(x,y)-.07
        g.ring(x,y,base,r,hgt,'sandstone',24,top=r*.95,inner=r*.66)
        g.ring(x,y,base+hgt-.08,r*1.012,.06,'cream',24,inner=r*.66)
        g.ring(x,y,base+hgt-.17,r*.65,.020,'earth',24)
        for i in range(14):
            a=(i+.5)*tau/14
            sector(g,x,y,r*.66,r*.98,base+hgt-.022,base+hgt+.10,a-.065,a+.065,'cream',2)
        # Small slit accents supplement the structural hollow tower/courtyard.
        for a in (-pi/2,-pi/2-.55,-pi/2+.55):
            xx,yy=x+r*.955*cos(a),y+r*.955*sin(a)
            g.box(xx,yy,base+hgt*.48,.042,.010,.15,'dark_wood',a+pi/2)
    for x,y in [(-.58,.08),(.42,.12),(.27,-.30),(-1.08,.17)]:
        cypress(g,x,y,z(x,y)-.005,.39)
    for x,y in [(-1.09,-.66),(.94,.69),(1.12,-.06),(-.26,.86)]:
        shrub(g,x,y,z(x,y)-.006,.17)


def tigris_meander(g):
    z=river_sculpt(g,'tigris')
    for x,y,h in [(-.93,-.30,.63),(1.02,.71,.78),(.93,.94,.61)]:
        date_palm(g,x,y,z(x,y)-.003,h,.26,x+y)
    # A long tapered inner-bend bar with bank-facing asymmetric slope.
    bound=[(.10+.14*cos(a),-.57+.33*sin(a)) for a in [tau*i/28 for i in range(28)]]
    g.land(bound,lambda x,y:.13+.025*cos((y+.57)*5),'sand_light','earth',.065)
    for x,y in [(-.83,.47),(.86,-.64),(-1.12,.84)]:shrub(g,x,y,z(x,y),.10)


def field_patch(g,x,y,w,d,z,mat,angle=0):
    """Low trapezoid crop volume; subtle rills are form, not busy linework."""
    v=[(-w/2,-d/2,0),(w/2,-d/2,0),(w/2,d/2,0),(-w/2,d/2,0),
       (-w*.47,-d*.47,.022),(w*.47,-d*.47,.022),(w*.47,d*.47,.022),(-w*.47,d*.47,.022)]
    g.mesh(v,[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)],mat,(x,y,z),angle)
    for k in range(3):
        g.box(x+(k-1)*w*.23,y,z+.022,w*.075,d*.90,.012,mat,angle)


def support_stairs(g,x,y,z,w,d,h,count,ground):
    for i in range(10):
        ya=y-d/2+d*i/10;yb=y-d/2+d*(i+1)/10
        za=max(0.,min(z-.008,ground(x,ya)-.02));zb=max(0.,min(z-.008,ground(x,yb)-.02))
        wall_segment(g,(x,ya),(x,yb),za,zb,(z-za+.002,z-zb+.002),w,'sandstone')
    g.steps(x,y,z,w,d,h,count,'sandstone')


def ledged_rock(g,x,y,z,rx,ry,h):
    n=11;v=[]
    for j in range(3):
        for i in range(n):
            a=i*tau/n;rr=[.80,1.,.83][j]*(1+.13*sin(3*a+.7)+.07*sin(5*a))
            v.append((x+rx*rr*cos(a),y+ry*rr*sin(a),z+[0,.36,.84][j]*h+.05*h*sin(2*a)))
    v.append((x+rx*.08,y-ry*.11,z+h*.94));apex=len(v)-1
    f=[tuple(range(n-1,-1,-1))]
    for j in range(2):
        f.extend((j*n+i,j*n+(i+1)%n,(j+1)*n+(i+1)%n,(j+1)*n+i) for i in range(n))
    f.extend((2*n+i,2*n+(i+1)%n,apex) for i in range(n))
    g.mesh(v,f,'rock_light')


def date_palm_canals(g):
    boundary=g.outline(1.64,1.30,56,.5,.035)
    # Main trunk and branches are lowered in terrain itself before water is laid.
    channels=[(-.17,-1.34,-.17,1.31,.17),(-1.48,-.46,-.17,-.46,.095),
              (-.17,.26,1.49,.26,.105),(-1.44,.79,-.17,.79,.075)]
    def chdist(x,y,c):
        ax,ay,bx,by,w=c;dx,dy=bx-ax,by-ay
        t=clamp(((x-ax)*dx+(y-ay)*dy)/(dx*dx+dy*dy))
        return hypot(x-ax-t*dx,y-ay-t*dy)-w/2
    def h(x,y):
        dd=min(chdist(x,y,c) for c in channels)
        return lerp(.06,.145,smooth(0,.055,dd))*g.taper(x,y,boundary)
    g.land(boundary,h,lambda p:'sand_dark' if p[2]<.10 else 'earth','earth',.085)
    # Irrigation branches end within the fields, before the natural ground rim.
    # Endpoints retain >= .17 full-width clearance from the actual outline;
    # their .041 lower water surface sits inside the triangulated canal bed.
    water_channels=[(-.17,-1.18,-.17,1.06,.17),(-1.22,-.46,-.17,-.46,.095),
                    (-.17,.26,1.49,.26,.105),(-.97,.79,-.17,.79,.075)]
    for ax,ay,bx,by,width in water_channels:
        if abs(ax-bx)<1e-9:
            xy=[(ax-width/2,ay),(ax+width/2,ay),(bx+width/2,by),(bx-width/2,by)]
        else:
            xy=[(ax,ay-width/2),(bx,by-width/2),(bx,by+width/2),(ax,ay+width/2)]
        polygon_solid(g,xy,.081,.040,'water_shallow')
    for i,(x,y,w,d) in enumerate([(-.89,-.90,.82,.53),(.70,-.84,.89,.63),
        (-.89,.18,.78,.87),(.65,-.17,.92,.55),(.71,.78,.92,.63),(-.83,1.00,.73,.24)]):
        x*=.86;y*=.82;w*=.80;d*=.80
        field_patch(g,x,y,w,d,h(x,y)-.012,'grass' if i%2 else 'grass_light')
    for i,(x,y,hh) in enumerate([(-1.2,-.71,.91),(-.71,-.68,1.02),(-.94,.14,.88),
                               (-.62,.45,.96),(.39,-.82,.89),(1.09,-.40,1.03),
                               (.64,.59,.92),(1.13,.96,.83)]):
        date_palm(g,x,y,h(x,y)-.008,hh,.31,i*.63)


def pyramid(g,x,y,base,w,h,cap=False):
    # Four planar sides are interrupted only by localized eroded lower casing.
    # Face-boundary points are deliberate chips, not concentric step-pyramid bands.
    corners=[(-1,-1),(1,-1),(1,1),(-1,1)]
    for i in range(4):
        a=corners[i];b=corners[(i+1)%4]
        levels=[0.,.075,.16,.84,1.]
        vv=[]
        for j,t in enumerate(levels[:-1]):
            for k in range(9):
                s=k/8
                xx=lerp(a[0],b[0],s)*w/2*(1-t)
                yy=lerp(a[1],b[1],s)*w/2*(1-t)
                chip=.045*sin(k*1.8+i) if j in (1,2) else 0
                if i in (0,1) and k in (3,4,5):
                    xx*=1-chip;yy*=1-chip
                vv.append((x+xx,y+yy,base+h*t))
        vv.append((x,y,base+h));apex=len(vv)-1
        for j in range(3):
            faces=[(j*9+k,j*9+k+1,(j+1)*9+k+1,(j+1)*9+k) for k in range(8)]
            g.mesh(vv,faces,'sandstone')
        g.mesh(vv,[(27+k,27+k+1,apex) for k in range(8)],'cream' if cap else 'sandstone')
    g.mesh([(x+xx*w/2,y+yy*w/2,base) for xx,yy in corners],[(3,2,1,0)],'sandstone')


def giza_pyramids(g):
    def h(x,y):
        natural=.10+.11*exp(-((x+.18)**2+(y-.08)**2)/2)+.018*sin(3*x+y)
        return natural
    z=terrain(g,1.71,1.36,h,'sand_light',.075,base='sand')
    for x,y,w,hh,cap in [(-.57,-.30,1.05,1.03,False),(.16,.49,.94,.97,True),(.85,.72,.49,.53,False)]:
        base=min(z(x+dx*w/2,y+dy*w/2) for dx in (-1,1) for dy in (-1,1))-.01
        pyramid(g,x,y,base,w,hh,cap)
    # Exposed ledged rock shelf in the front right, with one shallow eroded notch.
    for i,(xx,yy,rx,ry,zz) in enumerate([(.86,-.74,.40,.24,.11),(1.18,-.32,.26,.30,.09),(-.96,.59,.24,.27,.08)]):
        ledged_rock(g,xx,yy,z(xx,yy)-.035,rx,ry,zz+.07)
    for i in range(5):
        x=.29+i*.16
        g.box(x,-1.00,z(x,-1.00)-.015,.159,.11,.09+(i%2)*.035,'sandstone')


def nile_floodplain(g):
    z=river_sculpt(g,'nile')
    for i,(x,y,w,d) in enumerate([(.31,-1.03,.54,.47),(.99,-1.02,.56,.48),
        (.38,-.38,.57,.54),(1.04,-.32,.54,.72),(.26,.34,.52,.61),(.97,.47,.67,.67),
        (.38,1.00,.67,.43),(1.07,1.00,.47,.42),(-1.11,.59,.29,.69),(-1.11,-.56,.29,.54)]):
        # Boundary parcels shrink toward the natural scene perimeter.
        x*=.89;y*=.84;w*=.77;d*=.80
        field_patch(g,x,y,w,d,z(x,y)-.014,'grass_light' if i%3 else 'grass')
    for i,(x,y,h) in enumerate([(.08,-.64,.65),(.16,.66,.72),(1.23,.08,.67),(-1.11,.09,.63)]):
        date_palm(g,x,y,z(x,y)-.008,h,.25,i)


def coral_branch(g,x,y,z,h=.34,phase=0.):
    """Low colony with six basal fans and two orders of short forklets."""
    for i in range(6):
        a=phase+i*tau/6
        root=(x+.06*cos(a),y+.06*sin(a),z-.012)
        joint=(x+.10*cos(a),y+.10*sin(a),z+h*.30)
        g.beam(root,joint,.032,'coral',7)
        for j in (-1,1):
            aa=a+j*.49
            fork=(x+.205*cos(aa),y+.205*sin(aa),z+h*(.68+.035*i))
            g.beam(joint,fork,.022,'coral',6)
            for k in (-1,1):
                az=aa+k*.37
                tip=(fork[0]+.060*cos(az),fork[1]+.060*sin(az),fork[2]+h*(.21+.06*j))
                g.beam(fork,tip,.015,'coral_light',6)


def coral_table(g,x,y,z,r=.28,phase=0.):
    """Lobed shallow plate supported by three low, spreading Y branches."""
    for i in range(3):
        a=phase+i*tau/3
        foot=(x+.060*cos(a),y+.060*sin(a),z-.008)
        joint=(x+.093*cos(a),y+.093*sin(a),z+.09)
        g.beam(foot,joint,.027,'coral',7)
        for side in (-1,1):
            aa=a+side*.48
            tip=(x+r*.62*cos(aa),y+r*.52*sin(aa),z+.165)
            g.beam(joint,tip,.021,'coral',6)
    n=30;v=[(x,y,z+.145)]
    # A flattened rear and broader front make each outline fan-like, with
    # distinct coarse lobes rather than a rotationally symmetric mushroom cap.
    for radius,zz in ((.70,.155),(1.,.198),(1.,.224),(.52,.193)):
        for i in range(n):
            a=i*tau/n
            shape=1+.11*sin(5*a+phase)+.055*cos(9*a+.5)
            rr=r*radius*shape
            xx=rr*cos(a)*1.16;yy=rr*sin(a)*(.78+.11*cos(a))
            ca,sa=cos(phase),sin(phase)
            v.append((x+ca*xx-sa*yy,y+sa*xx+ca*yy,z+zz+.011*sin(3*a+phase)*radius))
    top=len(v);v.append((x-.025*cos(phase),y-.025*sin(phase),z+.188))
    f=[(0,1+(i+1)%n,1+i) for i in range(n)]
    for row in range(3):
        f.extend((1+row*n+i,1+row*n+(i+1)%n,1+(row+1)*n+(i+1)%n,1+(row+1)*n+i) for i in range(n))
    f.extend((1+3*n+i,1+3*n+(i+1)%n,top) for i in range(n))
    g.mesh(v,f,'coral_light')


def coral_mound(g,x,y,z,rx=.205,ry=.17,h=.18,phase=0.):
    """Connected low, knobbly colony with three deliberately visible crown lobes."""
    sides=18;steps=6;v=[]
    for j in range(steps):
        phi=(j/steps)*pi/2
        for i in range(sides):
            a=i*tau/sides
            bulge=1+.12*sin(5*a+phase)*sin(phi*2)+.065*cos(8*a-.3)*sin(phi)
            rr=cos(phi)*bulge
            v.append((x+rx*rr*cos(a),y+ry*rr*sin(a),z+h*sin(phi)*(1+.09*cos(3*a+phase)*cos(phi))))
    top=len(v);v.append((x,y,z+h))
    f=[tuple(range(sides-1,-1,-1))]
    for j in range(steps-1):
        f.extend((j*sides+i,j*sides+(i+1)%sides,(j+1)*sides+(i+1)%sides,(j+1)*sides+i) for i in range(sides))
    f.extend(((steps-1)*sides+i,(steps-1)*sides+(i+1)%sides,top) for i in range(sides))
    g.mesh(v,f,'coral')
    for dx,dy,rr in [(-.065,-.024,.081),(.067,.035,.073),(.009,-.067,.065)]:
        g.dome(x+dx,y+dy,z+h*.84,rr,rr*.69,'coral_light',9,3)


def red_sea_reef(g):
    bound=g.outline(1.52,1.35,60,.7,.02)
    # Reef shelves are real relief above a deep meandering trench. Exposed
    # cutaway-like miniature convention lets coral geometry remain readable.
    shelves=[(-.89,-.64,.42,.36),(-.89,.34,.47,.43),(-.62,1.00,.34,.23),
             (.70,-.80,.46,.31),(.91,.00,.41,.45),(.76,.82,.38,.32)]
    def relief(x,y):
        out=.052
        for xx,yy,rx,ry in shelves:
            ax,ay=(x-xx)/rx,(y-yy)/ry
            a=atan2(ay,ax)
            r=hypot(ax,ay)/(1+.15*sin(3*a+xx)+.07*cos(5*a+yy))
            out=max(out,.21*(1-smooth(.70,1.35,r))+.05)
        return out*g.taper(x,y,bound)
    def appearance(p):
        if p[2]<.145:return (lambda q:q[2]-.10,'water_deep','water_shallow')
        return (lambda q:q[2]-.19,'water_shallow','rock_light')
    g.land(bound,relief,appearance,'water_deep',.093)
    for i,(x,y,rx,ry) in enumerate(shelves):
        if i in (0,2,4):
            coral_branch(g,x,y,relief(x,y)-.018,.29 if i==0 else .27,i*.72)
        else:
            dx,dy={1:(-.11,.09),3:(-.12,-.10),5:(.10,.07)}[i]
            tx,ty=x+dx,y+dy
            coral_table(g,tx,ty,relief(tx,ty)-.010,.27 if i==1 else .255,i*.51)
    for i,(x,y,rx,ry,h) in enumerate([(-.64,.18,.205,.17,.19),(.97,-.63,.20,.17,.18),(.50,.64,.17,.15,.15)]):
        coral_mound(g,x,y,relief(x,y)-.025,rx,ry,h,i*.8)


def obhur_inlet(g):
    bound=g.outline(1.50,1.54,64,.4,.025)
    axis=[(.10*sin(t*pi*1.5),-1.70+2.67*t,.62*(1-t)+.20) for t in [i/64 for i in range(65)]]
    def distance(x,y):
        return min(hypot(x-cx,y-cy)-r for cx,cy,r in axis)
    def h(x,y):
        d=distance(x,y)
        if d<=0:return .085
        return .085+.13*smooth(0,.17,d)+.08*smooth(.22,.48,d)*(1+.25*sin(x*7+y*4))
    def appearance(p):
        d=distance(p[0],p[1])
        if d<-.04:return (lambda q:distance(q[0],q[1])+.09,'water_deep','water_shallow')
        if d<.08:return (lambda q:distance(q[0],q[1]),'water_shallow','sand_light')
        return (lambda q:distance(q[0],q[1])-.18,'sand_light','rock_light')
    features=[];edges=[]
    for margin in (0.,.15,.30):
        curves=[]
        for sign in (-1,1):
            curves.append([(x+sign*(r+margin),y) for x,y,r in axis])
        x,y,r=axis[-1]
        curves.append([(x+(r+margin)*cos(a),y+(r+margin)*sin(a)) for a in [i*pi/32 for i in range(33)]])
        for curve in curves:
            prev=None
            for pt in curve:
                if not inside_polygon(pt,bound):prev=None;continue
                index=len(features);features.append(pt)
                if prev is not None:edges.append((prev,index))
                prev=index
    g.land(bound,lambda x,y:h(x,y)*g.taper(x,y,bound),appearance,'sand',.078,features,edges)
    ground=terrain_sampler(g)
    for i,(x,y) in enumerate([(-1.0,-.75),(-1.01,-.16),(-.80,.76),(.98,-.77),(1.12,.12),(.95,.89)]):
        shrub(g,x,y,ground(x,y)-.012,.16 if i%2 else .19)


def shamsan_crater(g):
    """An explicit continuous layered radial section with a wide dry breach.

    The last three rings are a broad diminishing apron; no high vertex is
    connected straight to the footprint boundary.
    """
    profile=[(.16,.068),(.36,.075),(.50,.10),(.60,.18),(.67,.28),
             (.73,.43),(.77,.45),(.81,.42),(.86,.67),(.91,.73),
             (.96,.85),(1.0,1.0),(1.09,.79),(1.20,.43),(1.32,.17)]
    n=96;vertices=[(0,0,.063)]
    for q,level in profile:
        for i in range(n):
            a=tau*i/n;rim=.64+.045*sin(3*a+.5)+.026*sin(7*a)
            radius=q*rim*(1+.06*sin(9*a+q*.35))
            open_factor=smooth(-.86,-.27,sin(a))
            height=(.88+.25*cos(2*a-.25)+.075*sin(3*a))*open_factor
            # Coherent shallow angular ribs have the same phase on adjacent levels.
            rib=(.075*sin(9*a+.6)+.035*sin(17*a+.4))*sin(pi*clamp(q/1.4))*open_factor*smooth(.45,.78,q)
            z=.055+.035*smooth(.25,.6,q) if q<=.50 else .045+level*height+rib
            vertices.append((1.68*radius*cos(a),1.27*radius*sin(a),z))
    vertices += [(1.68*(1+.018*sin(5*a))*cos(a),1.27*(1+.018*sin(5*a))*sin(a),0)
                 for a in [tau*i/n for i in range(n)]]
    g.mesh(vertices,[(0,1+i,1+(i+1)%n) for i in range(n)],'sand_dark')
    for j in range(len(profile)):
        mat='sand_dark' if j<3 or j==len(profile)-1 else ('lava' if j in (5,6,9) else 'lava_light')
        f=[]
        for i in range(n):
            ni=(i+1)%n;a=1+j*n+i;b=1+j*n+ni;c=1+(j+1)*n+ni;d=1+(j+1)*n+i
            f += [(a,d,c),(a,c,b)]
        g.mesh(vertices,f,mat)
    outer=1+len(profile)*n
    g.mesh(vertices,[tuple(range(outer+n-1,outer-1,-1))],'sand_dark')


def cistern(g,xy,zbase,wallheight,thickness=.11,waterdepth=.12,notches=None):
    """True open cavity with thick inset walls, recessed floor and water."""
    cx=sum(x for x,y in xy)/len(xy);cy=sum(y for x,y in xy)/len(xy)
    inner=[]
    for x,y in xy:
        dd=hypot(x-cx,y-cy);r=max(.1,1-thickness/dd)
        inner.append((cx+(x-cx)*r,cy+(y-cy)*r))
    n=len(xy);notches=notches or {}
    for i in range(n):
        a,b=xy[i],xy[(i+1)%n];ia,ib=inner[i],inner[(i+1)%n]
        splits=[(0.,1.,zbase+wallheight)]
        if i in notches:
            xx,width,depth=notches[i]
            t=(xx-a[0])/(b[0]-a[0]);half=width/(2*abs(b[0]-a[0]))
            lo,hi=clamp(t-half,.02,.98),clamp(t+half,.02,.98)
            splits=[(0.,lo,zbase+wallheight),(lo,hi,zbase+wallheight-depth),(hi,1.,zbase+wallheight)]
        for u,v,top in splits:
            aa=(lerp(a[0],b[0],u),lerp(a[1],b[1],u));bb=(lerp(a[0],b[0],v),lerp(a[1],b[1],v))
            ai=(lerp(ia[0],ib[0],u),lerp(ia[1],ib[1],u));bi=(lerp(ia[0],ib[0],v),lerp(ia[1],ib[1],v))
            vv=[(*aa,zbase),(*bb,zbase),(*bb,top),(*aa,top),(*bi,top),(*ai,top),(*ai,zbase+.04),(*bi,zbase+.04)]
            g.mesh(vv,[(0,1,2,3),(5,4,7,6),(0,6,7,1)],'sandstone')
            g.mesh(vv,[(3,2,4,5)],'cream')
        if i in notches:
            for t in (lo,hi):
                aa=(lerp(a[0],b[0],t),lerp(a[1],b[1],t));bb=(lerp(ia[0],ib[0],t),lerp(ia[1],ib[1],t))
                g.mesh([(*aa,zbase+wallheight-depth),(*bb,zbase+wallheight-depth),(*bb,zbase+wallheight),(*aa,zbase+wallheight)],[(0,1,2,3)],'sandstone')
    g.mesh([(*p,zbase+.04) for p in inner],[tuple(range(n))],'sandstone')
    polygon_solid(g,inner,zbase+wallheight-waterdepth,.015,'water_deep')


def tawila_cisterns(g):
    def h(x,y):
        return .15+.78*smooth(-1.06,1.05,y)+.15*(abs(x)/1.4)**1.6+.04*sin(4*x+2*y)
    z=terrain(g,1.50,1.64,h,'rock_light',.072,base='earth')
    # Plateau floors are built into the hillside and tanks do not sit on posts.
    front=[(-.84,-.63),(-.83,-1.06),(-.65,-1.30),(-.25,-1.42),(.22,-1.42),(.65,-1.27),(.82,-1.02),(.81,-.63)]
    middle=[(-.66,-.20),(.66,-.20),(.66,.56),(-.66,.56)]
    top=[(-.44,.79),(.38,.77),(.52,1.03),(.27,1.38),(-.28,1.39),(-.52,1.12)]
    cistern(g,front,.185,.47,.12,.16,{7:(-.24,.19,.14)})
    cistern(g,middle,.60,.42,.115,.14,{0:(-.24,.19,.25)})
    cistern(g,top,.99,.35,.10,.13,{0:(.23,.19,.25)})
    # Two open side channels follow descending invert elevations; the small
    # spill lips point into the lower cavity rather than ending outside a wall.
    for a,b,za,zb in [((.23,.85),(.23,.43),1.17,.93),((-.24,-.04),(-.24,-.80),.84,.50)]:
        wall_segment(g,a,b,za-.05,zb-.05,.035,.12,'sandstone')
        wall_segment(g,a,b,za-.010,zb-.010,.012,.061,'water_shallow')
        for dx in (-.071,.071):
            wall_segment(g,(a[0]+dx,a[1]),(b[0]+dx,b[1]),za-.012,zb-.012,.070,.028,'cream')
    # Connected outer stairs climb beside, not through, the three water volumes.
    support_stairs(g,1.03,-.94,.065,.23,.67,.57,9,z)
    support_stairs(g,.96,-.10,.59,.23,.87,.43,8,z)
    support_stairs(g,.77,.83,1.00,.22,.70,.34,7,z)
    for x,y in [(-1.12,-.13),(1.16,.46),(-.84,.92),(.84,1.27)]:
        shrub(g,x,y,z(x,y)-.01,.13)


BUILDERS={
    'roman_aqueduct':roman_aqueduct,'lake_albano':lake_albano,
    'bosphorus_strait':bosphorus_strait,'rumeli_fortress':rumeli_fortress,
    'tigris_meander':tigris_meander,'date_palm_canals':date_palm_canals,
    'giza_pyramids':giza_pyramids,'nile_floodplain':nile_floodplain,
    'red_sea_reef':red_sea_reef,'obhur_inlet':obhur_inlet,
    'shamsan_crater':shamsan_crater,'tawila_cisterns':tawila_cisterns,
}

FEATURES={
 'roman_aqueduct':['six genuinely open arches','continuous recessed U-shaped water trough','grounded piers on a natural grass apron'],
 'lake_albano':['closed irregular crater basin','lower planar lake surface','constraint-aligned shoulder rings and separate sparse trees'],
 'bosphorus_strait':['two unequal continuous banks','shared shore/water vertices','marine passage open at both ends','no modern bridge'],
 'rumeli_fortress':['1452 geographic impression','three unequal hollow round towers','terrain-grounded wall segments','open courtyard and gate'],
 'tigris_meander':['broad alluvial S bend','shared water-bank vertices','low inner-bend sandbar','sparse feather-frond date palms'],
 'date_palm_canals':['lowered connected irrigation channels','six field parcels','eight curved trunks with separated frond leaflets'],
 'giza_pyramids':['three different square pyramid volumes','localized lower casing chips','light cap on middle pyramid','exposed rock shelf'],
 'nile_floodplain':['broad river with connected shore','ten raised field parcels','green agricultural strip at desert margin','four feather-frond date palms'],
 'red_sea_reef':['six shallow reef shelves above deep trench','short multi-fork coral colonies, lobed fan plates on split supports, three knobbly mounds','cutaway-readable water convention'],
 'obhur_inlet':['single broad marine mouth','rounded narrowing inland head','continuous pale rocky shore shelves'],
 'shamsan_crater':['irregular dry horseshoe crater','low breached foreground','two unequal high shoulders','actual radial relief and ledges'],
 'tawila_cisterns':['three genuine recessed water cavities at different elevations','round/rectangle/polygon tank plans','open connecting water channels','connected side stairs and hillside support'],
}
