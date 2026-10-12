"""South/central Asian landscape miniatures for the independent 020 library.

Authored after south-01/02/03 concept boards. Coordinates are Blender Z-up.
No production map data, old asset, runtime placement or export is modified.
Land patches close at an irregular zero-height rim. Snow boundaries split the
actual terrain faces; water channels are part of the continuous land chart.
"""
import math

TAU = math.tau


def clamp(v, a=0., b=1.):
    return max(a, min(b, v))


def mix(a, b, t):
    return a + (b-a)*t


def smooth(a, b, v):
    t = clamp((v-a)/(b-a))
    return t*t*(3-2*t)


def profile(q, points):
    for (a, x), (b, y) in zip(points, points[1:]):
        if q <= b:
            return mix(x, y, clamp((q-a)/(b-a)))
    return points[-1][1]


def segment_distance(x, y, a, b):
    dx, dy = b[0]-a[0], b[1]-a[1]
    t = clamp(((x-a[0])*dx+(y-a[1])*dy)/(dx*dx+dy*dy))
    return math.hypot(x-a[0]-t*dx, y-a[1]-t*dy), t


def path_field(x, y, points, width=.35):
    """Piecewise ridge: height samples in z, falloff across the whole path."""
    values = []
    for a, b in zip(points, points[1:]):
        d, t = segment_distance(x, y, a, b)
        values.append(mix(a[2], b[2], t)*max(0., 1-d/width))
    return max(values, default=0.)


def add_path(points, edges, path):
    start = len(points)
    points.extend((p[0], p[1]) for p in path)
    edges.extend((start+i, start+i+1) for i in range(len(path)-1))


def edge_fade(x, y, boundary, width=.40):
    """Broad natural foot before the final zero rim, avoiding tall rim fans."""
    distance=min(segment_distance(x,y,a,b)[0] for a,b in zip(boundary,boundary[1:]+boundary[:1]))
    return smooth(0.,width,distance)


def split_polygon(points, field):
    """Shared exact crossings for one linearized field on a source face."""
    below,above=[],[]
    for a,b in zip(points,points[1:]+points[:1]):
        fa,fb=field(a),field(b)
        if fa<=0:below.append(a)
        if fa>=0:above.append(a)
        if (fa<0<fb) or (fb<0<fa):
            t=fa/(fa-fb);p=tuple(mix(a[i],b[i],t) for i in range(3))
            below.append(p);above.append(p)
    return below,above


def colored_land(g,border,height,rules,default,base='earth',spacing=.09,features=None,feature_edges=None):
    """Ordered physical material regions, split on the actual terrain faces.

    Each field <=0 wins its material. Unlike face-center classification, this
    cannot paint full long triangles across a bank, snow line or cliff edge.
    """
    raw=g.__class__(g.city_id+'_terrain_chart')
    raw.land(border,height,default,base=base,spacing=spacing,features=features,feature_edges=feature_edges)
    for vertices,faces in raw.buckets.values():
        for indices in faces:
            points=[vertices[i] for i in indices]
            if all(abs(p[2])<1e-9 for p in points):
                g.mesh(points,[tuple(range(len(points)))],base);continue
            for field,mat in rules:
                cut,points=split_polygon(points,field)
                if len(cut)>=3:g.mesh(cut,[tuple(range(len(cut)))],mat)
                if len(points)<3:break
            else:
                g.mesh(points,[tuple(range(len(points)))],default)


def crag(g,x,y,z,rx,ry,h,phase=0.,mat='rock_light'):
    """A fractured, beveled rectangular outcrop rather than a rounded pebble."""
    shape=[(-1,-.60),(-.60,-1),(.28,-.92),(1,-.52),(.86,.22),(.60,.94),(-.26,1),(-.94,.50)]
    verts=[]
    for j,(t,scale) in enumerate([(0,1.05),(.24,1),(.59,.92),(.88,.91),(1,.78)]):
        for i,(xx,yy) in enumerate(shape):
            notch=1-(.12 if i in (2,3) and j==2 else 0)
            verts.append((x+rx*xx*scale*notch+.06*h*t,
                          y+ry*yy*scale+.025*math.sin(phase)*t,
                          z+h*t+(h*.07*math.sin(i*2.1+phase) if j else 0)))
    faces=[tuple(range(7,-1,-1))]
    for j in range(4):
        for i in range(8):
            a=j*8+i;b=j*8+(i+1)%8;c=(j+1)*8+(i+1)%8;d=(j+1)*8+i
            faces.extend([(a,b,c),(a,c,d)])
    faces.append(tuple(32+i for i in range(8)))
    g.mesh(verts,faces,mat)


def ico_sphere(subdivisions=2):
    """Pure geometry icosphere, avoiding latitude belts on irregular boulders."""
    t=(1+math.sqrt(5))/2
    vv=[(-1,t,0),(1,t,0),(-1,-t,0),(1,-t,0),(0,-1,t),(0,1,t),(0,-1,-t),(0,1,-t),(t,0,-1),(t,0,1),(-t,0,-1),(-t,0,1)]
    vv=[tuple(c/math.sqrt(sum(q*q for q in p)) for c in p) for p in vv]
    ff=[(0,11,5),(0,5,1),(0,1,7),(0,7,10),(0,10,11),(1,5,9),(5,11,4),(11,10,2),(10,7,6),(7,1,8),(3,9,4),(3,4,2),(3,2,6),(3,6,8),(3,8,9),(4,9,5),(2,4,11),(6,2,10),(8,6,7),(9,8,1)]
    for _ in range(subdivisions):
        cache={};new=[]
        def mid(a,b):
            key=tuple(sorted((a,b)))
            if key not in cache:
                p=tuple((vv[a][i]+vv[b][i])/2 for i in range(3));r=math.sqrt(sum(c*c for c in p))
                cache[key]=len(vv);vv.append(tuple(c/r for c in p))
            return cache[key]
        for a,b,c in ff:
            ab,bc,ca=mid(a,b),mid(b,c),mid(c,a)
            new.extend([(a,ab,ca),(b,bc,ab),(c,ca,bc),(ab,bc,ca)])
        ff=new
    return vv,ff


def cliff_stairs(g, x0, x1, y, z0, z1, width=.19, count=13):
    """Closed stair run along X, with a thin underside embedded in a rock face."""
    sign=1 if x1>x0 else -1
    points=[(x0,z0-.055),(x1,z1-.055),(x1,z1)]
    for i in range(count-1,-1,-1):
        xx=mix(x0,x1,i/count);zz=mix(z0,z1,(i+1)/count)
        points.append((xx,zz))
        if i:points.append((xx,mix(z0,z1,i/count)))
    n=len(points)
    verts=[(x,y+side*width/2,z) for side in (-1,1) for x,z in points]
    faces=[tuple(range(n-1,-1,-1)),tuple(range(n,2*n))]
    faces.extend((i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n))
    g.mesh(verts,faces,'sandstone')


def boulder(g, x, y, z, rx, ry, h, mat='rock', phase=0., sides=14,
            levels=5, lean=(0., 0.)):
    """Closed irregular block with a real small foot and one top pole.

    Ridges use the same angular samples through height; shallow fractures are
    geometric cuts, not alternating colored triangles or separate rock rings.
    """
    verts, faces = [], []
    for j in range(levels):
        t = j/(levels-1)
        radius = profile(t, [(0,.63),(.18,.96),(.47,1.0),(.78,.82),(1,.37)])
        for i in range(sides):
            a = TAU*i/sides
            rough = 1+.11*math.sin(3*a+phase)+.055*math.sin(7*a+.7)
            cut = 1-.12*max(0., math.cos(5*a+phase))**12*math.sin(math.pi*t)
            zz = h*t + (h*.035*math.sin(3*a+phase) if 0 < j < levels-1 else 0.)
            verts.append((x+lean[0]*t+rx*radius*rough*cut*math.cos(a),
                          y+lean[1]*t+ry*radius*rough*cut*math.sin(a), z+zz))
    faces.append(tuple(range(sides-1, -1, -1)))
    for j in range(levels-1):
        for i in range(sides):
            n = (i+1)%sides
            a,b,c,d = j*sides+i,j*sides+n,(j+1)*sides+n,(j+1)*sides+i
            faces.extend([(a,b,c),(a,c,d)])
    tip = len(verts)
    verts.append((x+lean[0], y+lean[1], z+h*1.035))
    faces.extend(((levels-1)*sides+i, (levels-1)*sides+(i+1)%sides, tip) for i in range(sides))
    g.mesh(verts, faces, mat)


def gravel(g, height, entries, mat='rock_light'):
    for i, (x,y,r) in enumerate(entries):
        boulder(g,x,y,max(.008,height(x,y)-.022),r,r*.72,r*.85,mat,i*.73,8,3)


def broadleaf(g, x, y, z, h=.72, r=.30, lean=.045, mat='foliage'):
    """An airy broadleaf crown with connected branches and full undersides."""
    trunk_top=(x+lean,y+.015,z+h*.65)
    g.beam((x,y,z-.012),trunk_top,.036,'dark_wood',7)
    for dx,dy,t,s in [(-.66,-.12,.64,.69),(.65,.05,.72,.71),(.01,.41,.87,.78)]:
        end=(x+lean+dx*r,y+dy*r,z+h*t)
        g.beam((x+lean*.5,y,z+h*.39),end,.021,'dark_wood',6)
        # Flattened lobes have volume; their skirts overlap the crown bottom.
        boulder(g,end[0],end[1],end[2]-r*.33,r*s,r*s*.88,r*.93,mat,
                phase=dx+dy+1.1,sides=10,levels=5,lean=(r*.07,0))


def reeds(g, x, y, z, radius=.10, h=.22):
    """Solid folded blades, not alpha cards."""
    for i in range(5):
        a=i*2.399
        xx=x+radius*.46*math.cos(a); yy=y+radius*.46*math.sin(a)
        hh=h*(.72+.07*i)
        dx,dy=math.cos(a)*radius*.65,math.sin(a)*radius*.65
        w=.025
        verts=[(xx-w*math.sin(a),yy+w*math.cos(a),z),
               (xx+w*math.sin(a),yy-w*math.cos(a),z),
               (xx+dx,yy+dy,z+hh),
               (xx+dx*.4,yy+dy*.4,z+hh*.53)]
        g.mesh(verts,[(0,1,2),(0,3,1),(0,2,3),(1,3,2)],'reed')


def earthen_wall(g, path, height, width=.17):
    """Continuous battered, eroded wall with actual shallow tamped layers."""
    verts, faces = [], []
    layers=[(0,1.15),(.20,1.10),(.24,.93),(.44,.92),(.48,.78),(.69,.79),(.73,.62),(1.,.55)]
    for j,(x,y,hh) in enumerate(path):
        a=path[max(0,j-1)];b=path[min(len(path)-1,j+1)]
        dx,dy=b[0]-a[0],b[1]-a[1];l=math.hypot(dx,dy)
        nx,ny=-dy/l,dx/l
        ground=height(x,y)-.018
        for k,(t,scale) in enumerate(layers):
            for side in (-1,1):
                ripple=.009*math.sin(j*1.7+k*.8)
                w=width*.5*scale+ripple
                verts.append((x+side*nx*w,y+side*ny*w,ground+hh*t))
    section=len(layers)*2
    for j in range(len(path)-1):
        for k in range(len(layers)-1):
            for side in range(2):
                a=j*section+2*k+side;b=(j+1)*section+2*k+side
                faces.append((a,b,b+2,a+2))
        faces.append((j*section,(j+1)*section,(j+1)*section+1,j*section+1))
        a=j*section+section-2;b=(j+1)*section+section-2
        faces.append((a,a+1,b+1,b))
    order=[2*k for k in range(len(layers))]+[2*k+1 for k in range(len(layers)-1,-1,-1)]
    faces.extend([tuple(reversed(order)),tuple((len(path)-1)*section+i for i in order)])
    g.mesh(verts,faces,'sand_dark')


def han_great_wall(g):
    border=g.outline(1.70,1.07,54,.8)
    def height(x,y):
        return (.095+.055*math.cos(1.9*x+.7*y)+.04*math.sin(3*y))*g.taper(x,y,border)
    g.land(border,height,'sand',base='sand_dark',spacing=.080)
    path=[]
    for i in range(24):
        t=i/23;x=mix(-1.46,1.08,t);y=.15+.17*math.sin(t*4.2)
        hh=.43+.10*math.sin(t*4.8)+.035*math.cos(i*1.4)
        if i in (6,7):hh=.15+.01*(i-6)
        if i==15:hh=.12
        if i==16:hh=.22
        path.append((x,y,hh))
    earthen_wall(g,path,height,.29)
    # One coherent tapered beacon, including genuine inner walls and an open
    # ruined crown. Its footprint narrows by a third over the full height.
    x,y=1.11,.03;z=height(x,y)-.020
    shape=[(-1,-1),(-.35,-1),(.40,-1),(1,-1),(1,-.25),(1,.43),(1,1),(.2,1),(-.45,1),(-1,1),(-1,.31),(-1,-.4)]
    layers=[(0,.33,.22),(.20,.312,.206),(.43,.282,.18),(.65,.261,.157),(1,.220,.122)]
    vv=[];n=len(shape)
    for inner in (False,True):
        for j,(t,outer,inside) in enumerate(layers):
            r=inside if inner else outer
            for i,(xx,yy) in enumerate(shape):
                notch=(-.085 if i in (1,7) else .015*math.sin(i*1.7)) if j==len(layers)-1 else 0
                vv.append((x+xx*r,y+yy*r,z+1.13*t+notch))
    ff=[];offset=len(layers)*n
    for inner in range(2):
        for j in range(len(layers)-1):
            for i in range(n):
                a=inner*offset+j*n+i;b=inner*offset+j*n+(i+1)%n
                ff.append((a,b,b+n,a+n))
    for i in range(n):
        ni=(i+1)%n;top=(len(layers)-1)*n
        ff.extend([(i,offset+i,offset+ni,ni),(top+i,top+ni,offset+top+ni,offset+top+i)])
    g.mesh(vv,ff,'sand_dark')
    gravel(g,height,[(-1.28,-.4,.09),(-.85,.58,.10),(-.28,-.53,.08),(.40,-.37,.09),(.65,.69,.08),(1.25,-.53,.11),(-.55,-.67,.055),(.17,.64,.06)])


def dunhuang_yardangs(g):
    border=g.outline(1.72,1.26,58,.25)
    def height(x,y):return .080*edge_fade(x,y,border,.25)
    g.land(border,height,'sand',base='sand_dark',spacing=.107)
    for index,(cx,cy,rx,ry,h) in enumerate([(-.10,.64,1.37,.27,1.13),(.0,.01,1.43,.25,.85),(-.35,-.59,1.04,.245,.62)]):
        vv=[];cross=[-1,-.90,-.81,-.75,-.70,-.51,0,.51,.70,.75,.81,.90,1]
        rows=27;cols=len(cross)
        for j in range(rows):
            t=mix(-1,1,j/(rows-1))
            end=profile(abs(t),[(0,1),(.60,1),(.78,.91),(.90,.64),(1,0)])
            flute=1+.07*math.sin(16*t+index)+.035*math.sin(27*t+1.3)
            for q in cross:
                side=profile(abs(q),[(0,1),(.51,.98),(.70,.88),(.75,.58),(.81,.33),(.90,.12),(1,0)])
                xx=cx+rx*t;yy=cy+ry*q*flute+.047*math.sin(t*2.4+index*.4)
                zz=.065+h*end*side*(.96+.04*math.cos(4*t+index))
                vv.append((xx,yy,zz))
        buckets={'rock_light':[],'sand_dark':[]}
        for j in range(rows-1):
            for k in range(cols-1):
                a=j*cols+k;b=(j+1)*cols+k;c=b+1;d=a+1
                # Coherent physically modeled intermediate stratum, never
                # isolated center-colored triangles spanning the escarpment.
                mat='sand_dark' if k in (2,9) else 'rock_light'
                buckets[mat].extend([(a,b,c),(a,c,d)])
        perimeter=[j*cols for j in range(rows)]+[(rows-1)*cols+k for k in range(1,cols)]
        perimeter += [j*cols+cols-1 for j in range(rows-2,-1,-1)]+list(range(cols-2,0,-1))
        buckets['rock_light'].append(tuple(reversed(perimeter)))
        for mat,ff in buckets.items():g.mesh(vv,ff,mat)
    crag(g,1.15,-.67,.06,.28,.22,.44,.8,'rock_light')


def muztagh_ata(g):
    border=g.outline(1.72,1.34,60,.40)
    def radial(x,y):
        xx=x/1.65;yy=(y-.14)/1.35
        return math.hypot(xx,yy),math.atan2(yy,xx)
    def height(x,y):
        q,a=radial(x,y)
        dome=2.13*profile(q,[(0,1),(.20,.998),(.36,.97),(.49,.81),(.65,.51),(.85,.18),(1.14,0)])
        gullies=(.08+.22*math.sin(6*a+.3)**2)*smooth(.28,.57,q)*(1-smooth(.90,1.12,q))
        buttress=.27*max(0.,math.cos(6*a+.3))**3*smooth(.38,.58,q)*(1-smooth(.82,1.1,q))
        return max(.075,dome-gullies+buttress)*g.taper(x,y,border)
    points,edges=[],[]
    for i in range(12):
        a=TAU*i/12+.05
        add_path(points,edges,[(1.65*q*math.cos(a),.14+1.35*q*math.sin(a)) for q in (.23,.38,.54,.72,.89)])
    points.append((0,.14))
    def snowfield(p):
        q,a=radial(p[0],p[1]);tongue=max(0.,math.sin(6*a+.3))**4
        return p[2]-(1.13-.86*tongue)
    colored_land(g,border,height,[(lambda p:p[2]-.18,'rock'),(snowfield,'slate'),(lambda p:p[2]-1.02,'ice')],
        'snow',base='earth',spacing=.075,features=points,feature_edges=edges)


def taklamakan_dunes(g):
    border=g.outline(1.73,1.26,60,.7)
    ridges=[(-.78,.37),(-.02,.56),(.78,.43)]
    def crest(y,base):return base+.19*math.sin(2.0*y+.3)+.065*y*y
    def dune(x,y,base,h):
        d=x-crest(y,base)
        # Windward ramp is much wider than the leeward slipface.
        q=abs(d)/(1.03 if d<0 else .51)
        shape=(max(0.,1-q)**1.36 if d<0 else max(0.,1-q))
        return h*shape*profile(abs(y),[(0,1),(.48,.97),(.75,.75),(.99,.31),(1.19,0)])
    def height(x,y):
        return (.055+max(dune(x,y,b,h) for b,h in ridges))*g.taper(x,y,border)
    points,edges=[],[]
    for b,h in ridges:
        add_path(points,edges,[(crest(y,b),y) for y in [-1.05,-.80,-.55,-.30,0,.30,.60,.88,1.07]])
    def appearance(p):
        b,h=max(ridges,key=lambda bh:dune(p[0],p[1],*bh))
        return 'sand'
    g.land(border,height,appearance,base='sand_dark',spacing=.063,features=points,feature_edges=edges)


def delhi_ridge(g):
    border=g.outline(1.70,1.29,56,.4)
    spine=[(-1.15,-.62,.26),(-.68,-.25,.40),(-.13,.07,.49),(.40,.39,.58),(.85,.66,.71)]
    def height(x,y):
        return (.07+path_field(x,y,spine,.47)*.57+.04*math.sin(2*x+1.6*y)**2)*g.taper(x,y,border)
    colored_land(g,border,height,[(lambda p:.12-path_field(p[0],p[1],spine,.32),'rock')],
        'grass',base='earth',spacing=.105)
    for i,(x,y,h) in enumerate(spine):
        crag(g,x,y,max(.03,height(x,y)-.15),.26,.22,.42+i*.035,i*.75)
        xx,yy=x+.13,y-.23
        crag(g,xx,yy,max(.03,height(xx,yy)-.10),.19,.15,.24+i*.024,i*.6+1.8)
    for x,y,h,r in [(-1.13,.13,.65,.28),(-.71,.71,.70,.29),(.19,-.67,.76,.31),(.89,-.32,.71,.28),(1.13,.43,.57,.26),(-.72,-.85,.59,.25)]:
        broadleaf(g,x,y,height(x,y)-.008,h,r)
    gravel(g,height,[(-1.25,-.75,.085),(-.35,.63,.075),(.57,-.52,.08),(1.12,-.50,.10)])


def yamuna_floodplain(g):
    border=g.outline(1.73,1.34,60,.2)
    def river(y):return .48*math.sin(2.25*y+.15)
    def dist(x,y):return abs(x-river(y))
    def bar(x,y):
        return math.hypot((x-river(y)-.015)/.14,(y+.08)/.46)
    def height(x,y):
        bank=.085+.16*smooth(.30,.56,dist(x,y))+.027*math.sin(2.2*x+y)**2
        if dist(x,y)<.30:bank=.085
        island=.19*(1-smooth(.45,1.0,bar(x,y)))
        return max(bank,.085+island)*g.taper(x,y,border)
    def wet(p):return max(dist(p[0],p[1])-.30,1-bar(p[0],p[1]))
    points,edges=[],[]
    for off in (-.56,-.30,.30,.56):
        add_path(points,edges,[(river(y)+off,y) for y in [-1.05,-.84,-.63,-.42,-.21,0,.21,.42,.63,.84,1.05]])
    ring=[]
    for i in range(24):
        a=i*TAU/24;yy=-.08+.46*math.sin(a)
        ring.append((river(yy)+.015+.14*math.cos(a),yy))
    add_path(points,edges,ring+[ring[0]])
    colored_land(g,border,height,[(lambda p:bar(p[0],p[1])-.63,'grass_light'),
        (wet,'water_shallow'),(lambda p:min(dist(p[0],p[1])-.49,bar(p[0],p[1])-1.15),'sand')],
        'grass',base='earth',spacing=.081,features=points,feature_edges=edges)
    for x,y,h,r in [(-1.18,-.49,.55,.24),(-1.04,.59,.69,.28),(1.10,.47,.67,.28),(1.05,-.61,.49,.22)]:
        broadleaf(g,x,y,height(x,y)-.012,h,r)
    for x,y in [(-.67,-.48),(.47,-.53),(-.24,.83),(.80,.39),(.09,-.04)]:
        reeds(g,x,y,height(x,y)-.009,.09,.19)


def sigiriya(g):
    border=g.outline(1.61,1.30,58,.6)
    def height(x,y):
        return (.10+.09*math.exp(-((x/.92)**2+(y/.77)**2)))*g.taper(x,y,border)
    g.land(border,height,'grass',base='earth',spacing=.091)
    # A broad summit above fluted, nearly vertical walls; no cone topology.
    sides=56;levels=[(0,1.07),(.17,1.17),(.39,1.01),(.64,1.025),(.84,.97),(1,.95)]
    verts=[]
    for j,(t,scale) in enumerate(levels):
        for i in range(sides):
            a=TAU*i/sides
            shape=1+.065*math.cos(3*a+.2)+.035*math.sin(7*a)
            flute=1-.11*max(0,math.cos(12*a+.5))**4*math.sin(math.pi*t)
            def angular_distance(b):return abs((a-b+math.pi)%TAU-math.pi)
            bay=.20*math.exp(-(angular_distance(-2.55)/.27)**2)+.17*math.exp(-(angular_distance(.08)/.25)**2)
            shape*=1-bay*(.58+.42*math.sin(math.pi*t))
            c,s=math.cos(a),math.sin(a)
            xx=.74*scale*shape*flute*math.copysign(abs(c)**.74,c)+.043*t
            yy=.58*scale*shape*flute*math.copysign(abs(s)**.79,s)+.018*t
            zz=.155+t*1.68+(.014*math.sin(4*a) if 0<j<len(levels)-1 else 0)
            verts.append((xx,yy,zz))
    faces=[tuple(range(sides-1,-1,-1))]
    for j in range(len(levels)-1):
        for i in range(sides):
            n=(i+1)%sides;a=j*sides+i;b=j*sides+n;c=(j+1)*sides+n;d=(j+1)*sides+i
            faces.extend([(a,b,c),(a,c,d)])
    faces.append(tuple((len(levels)-1)*sides+i for i in range(sides)))
    g.mesh(verts,faces,'terracotta')
    # Broad lower rock shoulders and actual recessed bays break the silhouette
    # on two sides. They remain below the one dominant archaeological summit.
    crag(g,-.58,-.25,.15,.22,.25,.72,.6,'terracotta')
    crag(g,.61,.15,.15,.22,.24,.97,1.8,'terracotta')
    # Low foundations and an open water cistern leave the summit readable.
    z=1.835
    g.box(-.16,.15,z,.63,.39,.028,'sandstone')
    for xx,yy,w,d in [(-.44,.14,.045,.42),(.14,.14,.045,.42),(-.15,.335,.59,.042),(-.15,-.045,.59,.042),(-.14,.15,.035,.35)]:
        g.box(xx,yy,z+.024,w,d,.085,'brick')
    for xx,yy,w,d in [(.26,-.045,.36,.039),(.26,-.295,.36,.039),(.10,-.17,.039,.27),(.42,-.17,.039,.27)]:
        g.box(xx,yy,z,w,d,.063,'sandstone')
    g.box(.26,-.17,z+.002,.29,.205,.010,'water_deep')
    # Three switchbacks rise along the rock wall. Their rear half is embedded
    # in the monolith, and successive runs share a real level landing.
    for x0,x1,yy,zz,top in [(-.33,.33,-.56,.20,.74),(.33,-.33,-.55,.74,1.28),(-.33,.28,-.50,1.28,1.850)]:
        cliff_stairs(g,x0,x1,yy,zz,top,.22,13)
    # Rock shoulders support the two turn landings rather than leaving a stair
    # suspended away from the summit wall.
    crag(g,.32,-.48,.61,.11,.18,.14,.8,'terracotta')
    crag(g,-.32,-.45,1.16,.11,.16,.14,1.6,'terracotta')
    for x,y,h,r in [(-1.00,-.53,.49,.25),(-1.02,.49,.65,.27),(.98,.48,.63,.27),(.86,-.76,.48,.24),(-.28,1.0,.43,.24)]:
        broadleaf(g,x,y,height(x,y)-.01,h,r)


def horton_plains(g):
    border=g.outline(1.70,1.27,60,.8)
    def cliff(x):return -.46+.085*math.sin(2.8*x+.1)+.034*math.sin(10*x)+.016*math.sin(19*x+.6)
    def height(x,y):
        rear=.93+.12*math.sin(1.7*x+.6)+.055*math.cos(3*y-x)
        rise=smooth(cliff(x)-.26,cliff(x)+.025,y)
        return (.075+rise*rear)*edge_fade(x,y,border,.43)
    points,edges=[],[]
    for off in (-.26,0,.10):
        add_path(points,edges,[(x,cliff(x)+off) for x in [-1.28,-1.03,-.77,-.51,-.25,0,.25,.51,.77,1.03,1.28]])
    colored_land(g,border,height,[(lambda p:max(p[1]-cliff(p[0])-.02,.145-p[2]),'rock_dark')],
        'grass',base='earth',spacing=.087,features=points,feature_edges=edges)
    for i,(x,hh,rx) in enumerate([(-.92,.52,.13),(-.38,.74,.15),(.28,.42,.17),(.86,.61,.12)]):
        yy=cliff(x)-.21
        crag(g,x,yy,.040,rx,.17,hh,i*.8,'rock_dark')
    for x,y,h,r in [(-1.13,.23,.43,.23),(-.60,.73,.42,.22),(.39,.78,.47,.25),(1.02,.36,.41,.23),(-.85,-.76,.45,.24)]:
        broadleaf(g,x,y,height(x,y)-.012,h,r,lean=.075)
    # A shallow irregular wet hollow sits on the actual upper slope.
    # Small closed geometry follows the terrain chart instead of a flat hovering lake.
    pts=[(-.31+.15*math.cos(i*TAU/20),.28+.25*math.sin(i*TAU/20)) for i in range(20)]
    vv=[(x,y,height(x,y)+.006) for x,y in pts]
    center=(-.31,.28,height(-.31,.28)+.006);vv.append(center)
    faces=[(20,i,(i+1)%20) for i in range(20)]
    # A thin skirt closes the inset patch; top is an illustrative wet hollow.
    vv.extend((x,y,z-.012) for x,y,z in vv[:20])
    faces.extend((i,21+i,21+(i+1)%20,(i+1)%20) for i in range(20))
    faces.append(tuple(21+i for i in range(19,-1,-1)))
    g.mesh(vv,faces,'water_shallow')


def mangrove(g,x,y,z,h=.89,r=.37,phase=0,ground=None):
    lean=(.07*math.cos(phase),.05*math.sin(phase))
    top=(x+lean[0],y+lean[1],z+h*.66)
    g.beam((x,y,z+.07),top,.050,'dark_wood',8)
    # Visible arched prop roots attach above water and reach individual mud feet.
    for i in range(6):
        a=phase+TAU*i/6
        ex,ey=x+.27*math.cos(a),y+.27*math.sin(a)
        end=(ex,ey,ground(ex,ey)-.015 if ground else z-.012)
        elbow=(x+.22*math.cos(a),y+.22*math.sin(a),z+.22)
        upper=(x+.07*math.cos(a),y+.07*math.sin(a),z+.42)
        for aa,bb,rr in [(upper,elbow,.025),(elbow,end,.019)]:
            g.beam(aa,bb,rr,'dark_wood',6)
    for dx,dy,t,scale in [(-.51,-.12,.66,.80),(.47,-.15,.73,.86),(.07,.36,.88,.84),(.05,-.27,.89,.62)]:
        end=(top[0]+dx*r,top[1]+dy*r,z+h*t)
        g.beam((x+lean[0]*.5,y+lean[1]*.5,z+h*.48),end,.025,'dark_wood',6)
        boulder(g,end[0],end[1],end[2]-r*.28,r*scale,r*scale*.91,r*.82,'foliage',phase+dx,10,4)


def irrawaddy_mangroves(g):
    border=g.outline(1.72,1.34,58,.9)
    def center(y):return .26*math.sin(2.6*y-.4)
    def channel(x,y):
        return min(abs(x-center(y)),abs(y-.45-.33*x)*.92 if x>.0 else 8.)
    def height(x,y):
        return (.065+.10*smooth(.18,.36,channel(x,y)))*g.taper(x,y,border)
    points,edges=[],[]
    for off in (-.18,.18,-.34,.34):
        add_path(points,edges,[(center(y)+off,y) for y in [-1.06,-.82,-.58,-.34,-.10,.14,.38,.62,.86,1.06]])
    def appearance(p):return (lambda v:channel(v[0],v[1])-.19,'water_shallow','mud')
    g.land(border,height,appearance,base='mud',spacing=.088,features=points,feature_edges=edges)
    for i,(x,y,h,r) in enumerate([(-.90,-.65,.81,.34),(-.89,.05,1.01,.40),(-.77,.70,.90,.37),(.72,-.63,1.02,.39),(.93,.04,.87,.34),(.55,.78,.76,.31)]):
        # Their circular root bases fit the broad mud banks; feet are buried.
        mangrove(g,x,y,height(x,y)-.011,h,r,i*.7,height)
    for x,y in [(-.48,-.85),(.51,-1.0),(1.19,.62),(-1.19,.43)]:
        reeds(g,x,y,height(x,y)-.01,.08,.15)


def kyaiktiyo_golden_rock(g):
    border=g.outline(1.57,1.28,56,.3)
    def ledge(x):return -.25+.07*math.sin(3*x)
    def height(x,y):
        crown=1.13-.23*x*x-.18*(y-.12)**2
        front=smooth(ledge(x)-.17,ledge(x)+.03,y)
        return max(.065,crown*front)*edge_fade(x,y,border,.44)
    points,edges=[],[]
    for off in (-.16,.025,.19):
        add_path(points,edges,[(x,ledge(x)+off) for x in [-1.12,-.83,-.55,-.28,0,.28,.55,.83,1.12]])
    colored_land(g,border,height,[(lambda p:max(p[1]-ledge(p[0])-.13,.12-p[2]),'rock')],
        'grass',base='earth',spacing=.087,features=points,feature_edges=edges)
    for i,(xx,yy,rx,ry,hh) in enumerate([(-.72,-.36,.29,.22,.62),(.62,-.37,.25,.25,.71),(-.23,-.65,.26,.18,.40),(.91,.14,.23,.25,.57)]):
        crag(g,xx,yy,max(.03,height(xx,yy)-hh*.56),rx,ry,hh,i*.6,'rock')
    # The foot is offset from the boulder's mass. The outer belly overhangs the
    # actual cliff, leaving a readable air wedge, not a sphere on a column.
    x,y=.0,-.20;contact=height(x,y)-.009
    sphere,faces=ico_sphere(3);verts=[]
    for nx,ny,nz in sphere:
        t=(nz+1)/2;a=math.atan2(ny,nx)
        rough=1+.09*math.sin(3*a+.4)+.045*math.cos(5*a+1.3)
        dx=-.17*math.sin(math.pi*t)+.045*t
        dy=-.40*smooth(.0,.55,t)+.08*smooth(.70,1.,t)
        zz=.97*smooth(.015,.94,t)
        # Flat small contact and summit patches are carved from an oblique
        # irregular polyhedron, with no cylindrical section rings.
        verts.append((x+.69*nx*rough+dx,y+.53*ny*rough+dy,contact+zz))
    g.mesh(verts,faces,'gold')
    z=contact+.97
    # Authentic small pagoda is subordinate to the irregular gold boulder.
    g.box(.045,y-.32,z,.235,.235,.030,'gold')
    g.ring(.045,y-.32,z+.030,.110,.028,'gold',16,top=.094)
    g.dome(.045,y-.32,z+.058,.091,.102,'gold',16,4)
    g.ring(.045,y-.32,z+.148,.044,.095,'gold',12,top=.012)
    g.ring(.045,y-.32,z+.243,.012,.055,'gold',8,top=0)
    for x,y,h,r in [(-.99,.07,.50,.25),(.77,.64,.60,.26),(1.12,.03,.44,.22),(-.70,-.76,.51,.27),(.58,-.86,.45,.24)]:
        broadleaf(g,x,y,height(x,y)-.01,h,r)


def pyramid(x,y,apex,base):
    """Three plane faces meet at a single summit; barycentric radial profile."""
    ax,ay,hh=apex
    # The ray from apex intersects the triangular footprint. Barycentric edge
    # half-planes provide the exact planar face height without a round cone.
    vals=[]
    for a,b in zip(base,base[1:]+base[:1]):
        nx,ny=-(b[1]-a[1]),b[0]-a[0]
        den=(ax-a[0])*nx+(ay-a[1])*ny
        if abs(den)>1e-9:vals.append(((x-a[0])*nx+(y-a[1])*ny)/den)
    return hh*max(0.,min(vals))


def everest(g):
    border=g.outline(2.15,1.57,68,.7)
    # The main three-faced summit occupies the rear third. The foreground is
    # authored valley space and connected folded ridges, not one giant pyramid.
    summit=(.18,.56,2.43)
    base=[(-.70,-.23),(1.18,-.13),(.18,1.31)]
    shoulder=(-.91,.51,1.85)
    sb=[(-1.55,.10),(-.33,-.05),(-.90,1.18)]
    ridges=[
        [summit,(-.32,.13,1.83),(-.75,-.07,1.40),(-1.07,-.51,1.20),(-1.54,-.87,.45)],
        [summit,(.58,.04,1.80),(1.10,-.21,1.41),(1.32,-.71,1.08),(1.69,-1.03,.24)],
        [shoulder,(-.34,.36,1.71),summit],
        [shoulder,(-1.40,.24,1.27),(-1.72,-.13,.68),(-1.89,-.61,.15)],
        [(.50,.89,1.82),(1.12,.83,1.21),(1.72,.45,.71),(1.99,.05,.13)],
        [(-.75,-.07,1.40),(-.96,-.39,1.23),(-.72,-.74,.87),(-1.11,-1.13,.54),(-1.64,-1.18,.18)],
        [(1.10,-.21,1.41),(.86,-.62,.90),(1.10,-.92,.72),(1.57,-1.27,.13)],
        [(-.96,-.39,1.23),(-1.38,-.35,.95),(-1.64,-.73,.56),(-1.88,-.88,.08)],
    ]
    def height(x,y):
        primary=pyramid(x,y,summit,base)
        secondary=pyramid(x,y,shoulder,sb)
        erosion=.16*max(0,math.cos(9*x+2.1*y))**4*smooth(.18,.65,primary)*(1-smooth(1.70,2.40,primary))
        primary=max(0,primary-erosion)
        relief=max(primary,secondary,*[path_field(x,y,path,.66 if i<5 else .49) for i,path in enumerate(ridges)])
        # Four genuine ravines split broad rock shoulders into uneven ribs.
        ravines=(.21*math.exp(-((x-1.12+.15*y)/.095)**2)
                 +.17*math.exp(-((x-.63+.27*y)/.085)**2)
                 +.18*math.exp(-((y+.13-.39*x)/.095)**2)
                 +.15*math.exp(-((y+.52+.18*x)/.08)**2))
        relief-=ravines*smooth(.16,.50,relief)*(1-smooth(1.72,2.30,relief))
        # The glacier bed descends continuously into the wide foreground. Its
        # irregular ice surface is actual geometry bounded by the side ridges.
        bed=(.14+.62*smooth(-1.25,.30,y))*(1-smooth(.65,1.45,abs(x)))
        icefold=.047*math.sin(12*y+1.8*x)*math.exp(-((x-.03)/.46)**2)*(1-smooth(.50,1.0,y))
        ribs=.09*max(0,math.sin(7*x+1.8*y))**2*max(0,1-(x/2.1)**2-(y/1.5)**2)
        return max(.045,bed+icefold,relief+ribs*(1-smooth(1.3,2.2,relief)))*edge_fade(x,y,border,.24)
    points,edges=[],[]
    for path in ridges:add_path(points,edges,path)
    for corner in base:add_path(points,edges,[(summit[0],summit[1]),corner])
    points.extend([(shoulder[0],shoulder[1]),(.18,.56)])
    for offset in (-.32,0,.32):
        add_path(points,edges,[(.02+.16*math.sin(y*2)+offset,y) for y in [-1.27,-1.04,-.82,-.60,-.38,-.16,.06,.22]])
    def snowfield(p):
        x,y,z=p
        # Snow descends into two sheltered real valleys. Steep sunny faces keep
        # broad bare patches; the line is split on the terrain triangles.
        valley1=math.exp(-((x-.02-.16*math.sin(y*2))/.40)**4)
        valley2=math.exp(-((x+.53+.29*y)/.20)**2)
        threshold=1.94-1.85*valley1-1.55*valley2+.10*math.sin(2*x-y)
        return z-threshold
    colored_land(g,border,height,[(lambda p:p[2]-.095,'rock'),(snowfield,'slate'),(lambda p:p[2]-1.03,'ice')],
        'snow',base='rock_dark',spacing=.062,features=points,feature_edges=edges)


BUILDERS={
    'han_great_wall':han_great_wall,'dunhuang_yardangs':dunhuang_yardangs,
    'muztagh_ata':muztagh_ata,'taklamakan_dunes':taklamakan_dunes,
    'delhi_ridge':delhi_ridge,'yamuna_floodplain':yamuna_floodplain,
    'sigiriya':sigiriya,'horton_plains':horton_plains,
    'irrawaddy_mangroves':irrawaddy_mangroves,
    'kyaiktiyo_golden_rock':kyaiktiyo_golden_rock,'everest':everest,
}

FEATURES={
    'han_great_wall':['Long low eroded Han rammed-earth wall with battered layered flanks','Single open-topped earthen beacon; no Ming masonry or intact city','Irregular stony Gobi ground with small embedded rubble'],
    'dunhuang_yardangs':['Three aligned elongated wind-eroded ridges and isolated residual castle','Real steep fluted escarpments and stepped shoulders','Open wind corridors, bare fine-grained desert ground'],
    'muztagh_ata':['Broad blunt common ice dome, clearly different from Everest pyramid','Radial carved glacier grooves and exposed lower buttresses','Snow and lower ice tongues share the real terrain faces'],
    'taklamakan_dunes':['Three curving linked wind-shaped dune crests','Wide convex windward slopes and narrow steep slipfaces','Broad sand-plane colors with no rocky mesa or decorative ripple noise'],
    'delhi_ridge':['Low diagonal fractured rock ridge with layered exposed blocks','Six airy broadleaf trees in dry open woodland','Delhi-local Aravalli extension rather than Himalayan relief'],
    'yamuna_floodplain':['Winding S river reach cut into low silty floodplain banks','Tapered central sand/grass bar and separated riparian tree clusters','Continuous bank-water terrain chart with solid reeds'],
    'sigiriya':['Broad near-vertical isolated fluted rock, not a cone','Summit archaeological foundations and genuine open cistern','Ascending shoulder stairs and low surrounding forest'],
    'horton_plains':['Broad rolling grass plateau above a long exposed southern escarpment','Wind-shaped cloud-forest edge and open upland meadow','Small terrain-following wet hollow; no snow or tea terraces'],
    'irrawaddy_mangroves':['Two branching tide channels through low irregular mud banks','Six spreading full-volume mangrove crowns','Visible branching prop roots joined to trunks and buried in mud'],
    'kyaiktiyo_golden_rock':['Irregular eccentric gold boulder overhanging the true cliff edge','Small offset rock contact with air beneath the projecting belly','Subordinate authentic pagoda crown and naturally spreading forested hill foot'],
    'everest':['Single sharp three-faced pyramidal summit with directional connecting ridges','Subordinate high shoulder, connected folded foothills and real valleys','Bare slate faces and coplanar snow tongues; China–Nepal extra cross-regional asset'],
}
