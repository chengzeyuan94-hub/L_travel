"""Six independent 019 city miniatures; called by the common library exporter.

Authored in Blender Z-up on the established city plinth.  Every major opening
is empty geometry, not a dark rectangle on a solid facade.  Helpers write into
Geometry019 material buckets; this module has no exporter or production writes.
"""
from __future__ import annotations

import math

TAU = math.tau


def lathe(g, x, y, profile, mat, sides=20, sy=1.0, rotation=0):
    """Closed rotational profile with real single-vertex poles (no tiny caps)."""
    vertices, rings, faces = [], [], []
    for radius, z in profile:
        if radius == 0:
            rings.append([len(vertices)])
            vertices.append((0, 0, z))
        else:
            rings.append(list(range(len(vertices), len(vertices) + sides)))
            vertices.extend((radius * math.cos(rotation + i * TAU / sides),
                             radius * math.sin(rotation + i * TAU / sides) * sy, z)
                            for i in range(sides))
    for lower, upper in zip(rings, rings[1:]):
        for i in range(sides):
            ni = (i + 1) % sides
            if len(lower) == 1:
                faces.append((lower[0], upper[ni], upper[i]))
            elif len(upper) == 1:
                faces.append((lower[i], lower[ni], upper[0]))
            else:
                faces.append((lower[i], lower[ni], upper[ni], upper[i]))
    if len(rings[0]) > 1:
        faces.append(tuple(reversed(rings[0])))
    if len(rings[-1]) > 1:
        faces.append(tuple(rings[-1]))
    g.mesh(vertices, faces, mat, (x, y, 0))


def dome(g, x, y, z, radius, height, mat="cream", sides=24, steps=6):
    profile = [(radius * math.cos(i * math.pi / (steps * 2)),
                z + height * math.sin(i * math.pi / (steps * 2)))
               for i in range(steps)] + [(0, z + height)]
    lathe(g, x, y, profile, mat, sides)


def half_dome(g, x, y, z, radius, height, mat="teal", direction=1, sides=12, steps=5):
    """A solid half-dome on a cut diametric plane, attached to the main nave."""
    vertices = []
    for j in range(steps):
        a = j * math.pi / (2 * steps)
        rr = radius * math.cos(a)
        vertices.extend((rr * math.cos(i * math.pi / sides),
                         direction * rr * math.sin(i * math.pi / sides),
                         height * math.sin(a)) for i in range(sides + 1))
    apex = len(vertices)
    vertices.append((0, 0, height))
    n, faces = sides + 1, []
    for j in range(steps - 1):
        faces.extend((j*n+i, j*n+i+1, (j+1)*n+i+1, (j+1)*n+i)
                     for i in range(sides))
    faces.extend(((steps-1)*n+i, (steps-1)*n+i+1, apex) for i in range(sides))
    faces.append(tuple(reversed(range(n))))
    faces.append(tuple([j*n for j in range(steps)] + [apex] +
                       [j*n+sides for j in range(steps-1, -1, -1)]))
    if direction < 0:
        faces = [tuple(reversed(f)) for f in faces]
    g.mesh(vertices, faces, mat, (x, y, z))


def sector(g, x, y, inner, outer, z0, z1, a0, a1, mat="stone", segments=6, sy=1):
    """Closed annular sector: seating gaps remain genuinely open all the way."""
    n = segments + 1
    angles = [a0 + (a1-a0)*i/segments for i in range(n)]
    vertices = [(r*math.cos(a), r*math.sin(a)*sy, z)
                for r, z in ((inner,z0),(outer,z0),(outer,z1),(inner,z1))
                for a in angles]
    faces = []
    for j in range(4):
        jj = (j+1) % 4
        faces.extend((j*n+i, j*n+i+1, jj*n+i+1, jj*n+i) for i in range(segments))
    faces += [(0,n,2*n,3*n),(n-1,4*n-1,3*n-1,2*n-1)]
    g.mesh(vertices, faces, mat, (x,y,0))


def beam(g, a, b, radius, mat="dark_wood", sides=6):
    """Closed tapered architectural/palm beam along an arbitrary vector."""
    dx,dy,dz = (b[i]-a[i] for i in range(3))
    length = math.sqrt(dx*dx+dy*dy+dz*dz)
    ux,uy,uz = dx/length,dy/length,dz/length
    tangent = (-uy,ux,0) if abs(uz) < .95 else (1,0,0)
    norm = math.sqrt(sum(v*v for v in tangent))
    tx,ty,tz = (v/norm for v in tangent)
    bx,by,bz = uy*tz-uz*ty,uz*tx-ux*tz,ux*ty-uy*tx
    verts = []
    for point,r in ((a,radius),(b,radius*.82)):
        for i in range(sides):
            c,s = math.cos(i*TAU/sides), math.sin(i*TAU/sides)
            verts.append((point[0]+r*(tx*c+bx*s),point[1]+r*(ty*c+by*s),
                          point[2]+r*(tz*c+bz*s)))
    faces = [tuple(range(sides-1,-1,-1)),tuple(range(sides,2*sides))]
    faces.extend((i,(i+1)%sides,(i+1)%sides+sides,i+sides) for i in range(sides))
    g.mesh(verts,faces,mat)


def palm(g,x,y,z=.045,h=.52,r=.20):
    points=[(x,y,z),(x+.018,y+.01,z+h*.4),(x+.04,y+.013,z+h*.74),
            (x+.045,y+.012,z+h)]
    for j in range(3):
        beam(g,points[j],points[j+1],.023-j*.003)
    top=points[-1]
    for i in range(7):
        a=i*TAU/7+.21
        verts=[(0,0,0),(.36*r,-.027,.052),(.76*r,-.022,.035),(r,0,-.055),
               (.76*r,.022,.035),(.36*r,.027,.052),(.49*r,0,.071)]
        g.mesh(verts,[(0,1,6),(1,2,6),(2,3,6),(3,4,6),(4,5,6),(5,0,6)],
               "foliage",top,a)


def pavilion(g,x,y,z=.045,w=.32,d=.29,h=.23,roof="roof_red"):
    g.box(x,y,z,w*1.10,d*1.12,.045,"sandstone")
    for xx in (-.38,.38):
        for yy in (-.36,.36):
            g.ring(x+xx*w,y+yy*d,z+.045,.023,h,"cream",8,top=.019)
    g.box(x,y,z+.045+h,w,d,.035,"dark_wood")
    g.east_roof(x,y,z+.08+h,w*1.17,d*1.22,.095,roof)


def umbrella(g,x,y,z,r,mat="gold",sides=16):
    lathe(g,x,y,[(r*.20,z),(r,z+.012),(r*.92,z+.025),(r*.22,z+.043)],mat,sides)


def rome(g):
    g.terrace(1.85,1.35,"stone")
    x,y,rx,ry,n=-.13,.07,.595,.43,16
    sy=ry/rx
    # The exterior is two independent open structural stories. No inner box.
    for level in range(2):
        z=.045 if level==0 else .342
        arch_height=.257 if level==0 else .235
        for i in range(n):
            a=(i+.5)*TAU/n
            speed=math.hypot(rx*math.sin(a),ry*math.cos(a))
            pitch=2*speed*math.sin(math.pi/n)
            tangent=math.atan2(ry*math.cos(a),-rx*math.sin(a))
            g.arch(x+rx*math.cos(a),y+ry*math.sin(a),z,pitch/1.36,
                   arch_height,.088,"sandstone" if level==0 else "cream",tangent,6)
        # Belt begins below the lowest voussoir crown (h + 0.18 * opening).
        # This is a real overlap, not a ring suspended over tangent arches.
        belt_z=.316 if level==0 else .591
        g.ring(x,y,belt_z,rx+.047,.036,"cream",36,inner=rx-.055,scale_y=sy)
    # Light upper parapet and outside pilasters give story belts real depth.
    g.ring(x,y,.625,rx+.035,.082,"sandstone",36,inner=rx-.048,scale_y=sy)
    g.ring(x,y,.703,rx+.047,.027,"cream",36,inner=rx-.055,scale_y=sy)
    for i in range(n):
        a=i*TAU/n
        tangent=math.atan2(ry*math.cos(a),-rx*math.sin(a))
        for z,h in ((.045,.270),(.343,.247)):
            g.box(x+(rx+.049)*math.cos(a),y+(ry+.033)*math.sin(a),z,
                  .031,.025,h,"cream",tangent)
    # Five rising rows in four wedges, with four broad radial stair aisles.
    for row in range(5):
        inner=.292+row*.051
        outer=inner+.051
        top=.14+row*.086
        for q in range(4):
            mid=q*math.pi/2
            sector(g,x,y,inner,outer,.045,top,mid+.095,mid+math.pi/2-.095,
                   "stone",5,sy)
        for q in range(4):
            mid=q*math.pi/2
            for half in range(2):
                r0=inner+half*.0255
                sector(g,x,y,r0,r0+.0255,.045,top-.043+half*.043,
                       mid-.067,mid+.067,"cream",1,sy)
    g.ring(x,y,.045,.292,.018,"sandstone",36,scale_y=sy)
    # An open columned temple stays subordinate to the amphitheatre.
    g.box(.61,-.30,.047,.36,.35,.055,"sandstone")
    g.steps(.61,-.514,.045,.31,.12,.055,3,"cream")
    for xx in (.49,.61,.73):
        for yy in (-.40,-.21):
            g.ring(xx,yy,.102,.022,.235,"cream",8,top=.019)
            g.box(xx,yy,.315,.052,.052,.025,"sandstone")
    g.box(.61,-.30,.340,.37,.34,.035,"cream")
    g.gable(.61,-.30,.375,.42,.38,.105,"roof_red",math.pi/2)
    g.house(.60,.44,.28,.23,.19,"roof_red")


def constantinople(g):
    g.terrace(1.8,1.45,"sandstone")
    # Recessed cruciform support mass; half-domes step down continuously.
    g.box(0,.12,.047,.69,.65,.435,"cream")
    g.box(0,.12,.46,.74,.69,.045,"brick")
    for yy,direction in ((-.10,-1),(.35,1)):
        g.box(0,yy+direction*.10,.047,.54,.29,.293,"cream")
        g.box(0,yy+direction*.10,.325,.59,.32,.035,"brick")
        half_dome(g,0,yy,.36,.293,.235,"teal",direction)
    for xx in (-.41,.41):
        g.box(xx,.13,.047,.18,.66,.253,"sandstone")
        g.gable(xx,.13,.30,.22,.69,.065,"roof_red")
        for yy in (-.13,.38):
            g.box(xx,yy,.047,.255,.24,.275,"cream")
            g.ring(xx,yy,.322,.133,.033,"brick",16)
            dome(g,xx,yy,.355,.142,.132,"teal",16,4)
        # Outward-sloping masonry buttresses carry the high central drum.
        sign=1 if xx>0 else -1
        for yy in (-.02,.22):
            verts=[(sign*.34,yy-.045,.10),(sign*.59,yy-.045,.10),
                   (sign*.59,yy+.045,.10),(sign*.34,yy+.045,.10),
                   (sign*.34,yy-.045,.52),(sign*.43,yy-.045,.40),
                   (sign*.43,yy+.045,.40),(sign*.34,yy+.045,.52)]
            faces=[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),
                   (2,3,7,6),(3,0,4,7)]
            if sign < 0:
                faces=[tuple(reversed(f)) for f in faces]
            g.mesh(verts,faces,"sandstone")
    # Open window drum beneath the main dome, with no opaque cylinder behind.
    for i in range(16):
        a=(i+.5)*TAU/16
        g.arch(.297*math.cos(a),.12+.297*math.sin(a),.501,.081,.115,.048,
               "sandstone",a+math.pi/2,5)
    g.ring(0,.12,.627,.332,.030,"cream",32,inner=.271)
    dome(g,0,.12,.657,.350,.263,"teal",24,6)
    lathe(g,0,.12,[(.025,.910),(.025,.937),(0,.977)],"gold",8)
    # Front three-bay porch is open through to a shallow sheltered entry.
    for xx in (-.255,0,.255):
        g.arch(xx,-.465,.071,.163,.237,.12,"sandstone",steps=6)
    g.box(0,-.465,.341,.79,.19,.037,"cream")
    g.steps(0,-.602,.045,.67,.17,.049,4,"cream")
    # Twin narrow rear towers remain secondary to the broad dome.
    for xx in (-.70,.70):
        g.box(xx,.37,.045,.16,.18,.36,"brick")
        g.box(xx,.37,.405,.19,.21,.040,"cream")
        lathe(g,xx,.37,[(.065,.445),(.060,.70),(.051,.78)],"cream",12)
        g.ring(xx,.37,.746,.087,.035,"sandstone",12,inner=.048)
        for j in range(4):
            a=j*math.pi/2+math.pi/4
            g.ring(xx+.039*math.cos(a),.37+.039*math.sin(a),.78,.012,.085,"cream",6)
        lathe(g,xx,.37,[(.08,.865),(.061,.878),(0,1.032)],"teal",12)


def delhi(g):
    g.terrace(1.75,1.5,"sandstone")
    x,y=-.33,.16
    g.ring(x,y,.048,.247,.059,"cream",16)
    # Alternating broad flutes are part of the actual tower cross section.
    for level in range(5):
        z=.107+level*.177
        radius=.190-level*.025
        sides=32
        verts=[]
        for zz,rr in ((z,radius),(z+.154,radius-.021)):
            verts.extend((x+rr*(1 if i%2==0 else .905)*math.cos(i*TAU/sides),
                          y+rr*(1 if i%2==0 else .905)*math.sin(i*TAU/sides),zz)
                         for i in range(sides))
        faces=[tuple(range(sides-1,-1,-1)),tuple(range(sides,2*sides))]
        faces.extend((i,(i+1)%sides,(i+1)%sides+sides,i+sides) for i in range(sides))
        g.mesh(verts,faces,"terracotta" if level<3 else "sandstone")
        r=radius+.015
        lathe(g,x,y,[(radius-.012,z+.131),(r+.025,z+.155),
                     (r+.025,z+.173),(r+.009,z+.184)],"cream",24)
        # Stout corbels and a low open parapet produce a readable balcony edge.
        for j in range(12):
            a=j*TAU/12
            g.box(x+(radius-.009)*math.cos(a),y+(radius-.009)*math.sin(a),
                  z+.104,.029,.030,.048,"sandstone",a)
            if level<4:
                g.box(x+(r+.008)*math.cos(a),y+(r+.008)*math.sin(a),
                      z+.181,.027,.027,.035,"cream",a)
    lathe(g,x,y,[(.076,.998),(.072,1.026),(.042,1.043),(0,1.095)],"roof_red",12)
    # Low L-shaped cloister frames a real courtyard rather than filling it.
    for xx in (-.58,-.30,-.02,.26):
        g.arch(xx,-.385,.054,.177,.259,.106,"terracotta",steps=6)
    g.box(-.16,-.385,.347,1.155,.145,.04,"cream")
    for yy in (-.17,.09,.35):
        g.arch(.58,yy,.054,.163,.245,.095,"terracotta",math.pi/2,6)
    g.box(.58,.09,.332,.13,.77,.035,"cream")
    # Tall open gateway on the rear axis, accessible from the court.
    g.arch(.17,.435,.054,.272,.451,.165,"terracotta",steps=8)
    for xx in (-.025,.365):
        g.box(xx,.435,.054,.065,.205,.523,"sandstone")
        g.box(xx,.435,.58,.092,.235,.035,"cream")
    g.box(.17,.435,.536,.48,.205,.055,"terracotta")
    g.box(.17,.435,.591,.53,.235,.032,"cream")
    g.box(.13,-.07,.048,.41,.43,.018,"cream")
    # Small domed pavilion: visible columns, no room box under the roof.
    for xx in (.38,.64):
        for yy in (-.41,-.18):
            g.ring(xx,yy,.06,.022,.24,"cream",8,top=.018)
    g.box(.51,-.295,.30,.35,.33,.035,"sandstone")
    dome(g,.51,-.295,.335,.192,.168,"cream",20,5)
    lathe(g,.51,-.295,[(.017,.494),(.017,.525),(0,.56)],"roof_red",8)


def layered_cliff(g,outline,z0,z1,center):
    """Continuous ledged cliff with authored fractures, not a cone of rocks.

    Repeated XY vertices around the nonradial footprint define connected V
    fissures. Each ledge is an actual horizontal-ish shelf with a near vertical
    wall below; the upper cap is planar to support the inhabited terrace.
    """
    levels=((0,1),(.255,1.02),(.30,.985),(.315,.90),
            (.57,.92),(.61,.95),(.625,.865),(.925,.88),(1,.89))
    n=len(outline)
    verts=[]
    for j,(height,scale) in enumerate(levels):
        for i,(x,y) in enumerate(outline):
            # Slightly uneven seams, with solid side faces joining every ring.
            dz=0 if j in (0,len(levels)-1) else .012*math.sin(i*1.17+.4)*(z1-z0)
            verts.append((center[0]+(x-center[0])*scale,
                          center[1]+(y-center[1])*scale,z0+(z1-z0)*height+dz))
    faces=[tuple(range(n-1,-1,-1)),tuple(range((len(levels)-1)*n,len(levels)*n))]
    for j in range(len(levels)-1):
        faces.extend((j*n+i,j*n+(i+1)%n,(j+1)*n+(i+1)%n,(j+1)*n+i)
                     for i in range(n))
    g.mesh(verts,faces,"brick")


def roof_house(g,x,y,z,w,d,h,mat="cream"):
    g.box(x,y,z,w,d,h,mat)
    g.box(x,y,z+h,w*1.06,d*1.06,.034,"cream")
    for xx in (-.47,.47):
        g.box(x+xx*w,y,z+h+.025,.025,d,.051,mat)
    g.box(x,y+d*.46,z+h+.025,w,.025,.051,mat)
    g.box(x,y-d/2-.004,z+.02,w*.23,.014,h*.50,"dark_wood")
    for xx in (-.29,.29):
        g.box(x+xx*w,y-d/2-.006,z+h*.59,w*.16,.015,h*.22,"dark_wood")


def aden(g):
    g.terrace(1.9,1.4,"stone")
    # Authored angular outlines create horizontal strata and nonuniform fracture
    # notches across a continuous rock volume. No scatter-stone camouflage.
    layered_cliff(g,[(-.18,.01),(.06,-.08),(.36,-.06),(.48,-.005),
        (.59,-.02),(.74,.075),(.72,.14),(.76,.19),(.71,.23),(.765,.32),
        (.735,.46),(.64,.51),(.64,.60),(.45,.665),(.34,.632),(.25,.681),
        (.095,.64),(-.075,.62),(-.205,.46),(-.19,.34),(-.245,.26),(-.20,.13)],
        .044,.430,(.24,.30))
    layered_cliff(g,[(-.78,-.15),(-.66,-.25),(-.40,-.27),(-.25,-.16),
        (-.08,-.11),(-.075,.32),(-.20,.45),(-.49,.48),(-.68,.37),(-.77,.20)],
        .044,.250,(-.40,.13))
    layered_cliff(g,[(.18,-.40),(.51,-.43),(.65,-.31),(.70,-.13),
        (.65,.02),(.48,.09),(.20,.04),(.08,-.15)],.044,.160,(.40,-.16))
    g.box(.22,.28,.43,.67,.45,.045,"sandstone")
    g.box(-.32,.19,.25,.50,.48,.028,"sandstone")
    g.box(.28,-.18,.16,.53,.22,.03,"sandstone")
    g.box(.54,-.12,.158,.29,.25,.032,"sandstone")
    # An L of broad stairs links waterfront, middle landing and fort forecourt.
    g.steps(.39,-.395,.045,.30,.31,.145,6,"cream")
    g.steps(-.01,-.105,.19,.21,.36,.275,8,"sandstone")
    # Landings and stair flights have retaining masonry all the way to ground.
    g.box(.015,-.295,.044,.56,.14,.133,"brick")
    g.box(.015,-.295,.177,.56,.14,.021,"cream")
    g.box(-.01,-.105,.044,.21,.36,.148,"brick")
    # High fort has true gate depth between wall piers; front court remains open.
    g.arch(.22,.25,.475,.19,.255,.13,"cream",steps=7)
    g.box(.22,.40,.475,.56,.09,.21,"sandstone")
    for xx in (-.065,.50):
        g.box(xx,.31,.475,.14,.25,.342,"sandstone")
        g.box(xx,.31,.817,.155,.26,.036,"cream")
        for yy in (.205,.31,.415):
            g.box(xx,yy,.853,.12,.044,.064,"sandstone")
    g.box(.22,.28,.735,.42,.15,.045,"sandstone")
    for xx in (.055,.165,.275,.385):
        g.box(xx,.29,.780,.057,.13,.055,"cream")
    roof_house(g,-.39,.29,.278,.24,.23,.27,"sandstone")
    roof_house(g,-.60,.02,.12,.23,.22,.235,"cream")
    roof_house(g,-.29,-.145,.12,.25,.23,.18,"cream")
    roof_house(g,.56,-.11,.19,.22,.19,.205,"sandstone")
    # Waterfront three-arch shelter and open roof terrace, not a facade sticker.
    for xx in (-.61,-.385,-.16):
        g.arch(xx,-.455,.055,.139,.225,.145,"cream",steps=6)
    g.box(-.385,-.455,.306,.71,.20,.035,"sandstone")
    g.box(-.385,-.372,.341,.71,.025,.050,"cream")
    for xx in (-.727,-.043):
        g.box(xx,-.455,.341,.025,.19,.050,"cream")
    # Lantern is a genuinely open cage above the tapered beacon shaft.
    lx,ly=.66,-.36
    lathe(g,lx,ly,[(.108,.049),(.108,.11),(.084,.13),(.067,.49)],"cream",12)
    lathe(g,lx,ly,[(.064,.465),(.116,.49),(.116,.525),(.090,.535)],"sandstone",12)
    for i in range(6):
        a=i*TAU/6
        g.ring(lx+.065*math.cos(a),ly+.065*math.sin(a),.535,.013,.115,"dark_wood",6)
    lathe(g,lx,ly,[(.12,.650),(.12,.674),(0,.78)],"roof_red",12)
    g.ring(lx,ly,.57,.104,.026,"cream",12,inner=.092)
    g.box(.265,-.579,.043,.43,.135,.038,"dark_wood")
    for xx in (.095,.265,.435):
        g.ring(xx,-.626,.016,.023,.12,"dark_wood",6)
    # Open cistern reinforces the low harbor court without adding sea geometry.
    g.ring(-.10,.13,.275,.105,.056,"stone",16,inner=.075)
    g.ring(-.10,.13,.304,.073,.009,"teal",16)
    palm(g,-.68,.35,.045,.47,.16)


def simhala(g):
    g.terrace(1.85,1.5,"sandstone")
    x,y=-.015,.10
    # Broad clear walking platform around the dominant white hemisphere.
    lathe(g,x,y,[(.650,.046),(.650,.095),(.608,.105),(.608,.167)],"stone",32)
    g.ring(x,y,.167,.594,.025,"cream",32)
    g.ring(x,y,.192,.444,.033,"sandstone",32)
    g.ring(x,y,.225,.417,.030,"cream",32)
    dome(g,x,y,.255,.398,.385,"cream",32,8)
    # Circumambulatory parapet: broad front opening and actual upright posts.
    sector(g,x,y,.611,.638,.192,.226,-math.pi/2+.28,math.pi*1.5-.28,"cream",30)
    for i in range(24):
        a=i*TAU/24
        if abs((a+math.pi/2+math.pi)%TAU-math.pi)<.30:
            continue
        g.box(x+.624*math.cos(a),y+.624*math.sin(a),.222,.027,.027,.057,"cream",a)
    sector(g,x,y,.610,.639,.278,.300,-math.pi/2+.28,math.pi*1.5-.28,"sandstone",30)
    g.steps(x,-.492,.045,.355,.31,.151,7,"cream")
    g.box(x,y,.632,.145,.145,.070,"sandstone")
    for xx in (-.067,.067):
        g.box(x+xx,y,.702,.021,.154,.041,"cream")
    for yy in (-.067,.067):
        g.box(x,y+yy,.702,.114,.021,.041,"cream")
    lathe(g,x,y,[(.032,.700),(.026,.965),(0,1.027)],"gold",12)
    for i in range(5):
        umbrella(g,x,y,.754+i*.043,.082-i*.012,"gold",16)
    # Subordinate entry niche has empty arch behind the small seated form.
    g.arch(x,-.303,.233,.12,.164,.075,"sandstone",steps=6)
    g.ring(x,-.305,.241,.027,.050,"gold",8,top=.022)
    dome(g,x,-.305,.291,.023,.028,"gold",8,3)
    pavilion(g,-.64,-.25,.046,.29,.26,.20)
    palm(g,-.69,.32,.045,.53,.19)
    palm(g,.64,.23,.045,.46,.19)


def small_stupa(g,x,y,z,r=.082,h=.25):
    profile=[(r,z),(r,z+h*.12),(r*.76,z+h*.17),(r*.74,z+h*.33),
             (r*.49,z+h*.51),(r*.30,z+h*.61),(r*.22,z+h*.84),(0,z+h)]
    lathe(g,x,y,profile,"gold",12)


def dagon(g):
    g.terrace(1.8,1.5,"stone")
    x,y=0,.115
    # Four broad octagonal setbacks, with enough ledge to read as separate tiers.
    for r,z,h,mat in ((.63,.045,.055,"sandstone"),(.575,.10,.055,"cream"),
                      (.505,.155,.063,"sandstone"),(.413,.218,.068,"gold")):
        g.ring(x,y,z,r,h,mat,8,rotation=math.pi/8)
    lathe(g,x,y,[(.333,.286),(.333,.322),(.285,.337),(.286,.383),
                 (.264,.427),(.233,.457),(.200,.527),(.167,.618),
                 (.117,.669),(.108,.697)],"gold",24)
    g.ring(x,y,.686,.123,.033,"gold",24)
    # Ringed narrow spire is visibly separated from the bulging bell shoulder.
    lathe(g,x,y,[(.079,.717),(.056,.876),(.031,.986),(0,1.107)],"gold",16)
    for i in range(6):
        umbrella(g,x,y,.723+i*.043,.103-i*.013,"gold",16)
    g.steps(0,-.477,.045,.315,.405,.241,9,"cream")
    # Side cheeks ground the stair and lead to the upper plinth, without blocking it.
    for xx in (-.19,.19):
        g.steps(xx,-.477,.045,.049,.405,.262,9,"sandstone")
    for xx,yy in ((-.40,-.15),(.40,-.15),(-.40,.38),(.40,.38)):
        g.ring(xx,yy,.155,.09,.035,"cream",8)
        small_stupa(g,xx,yy,.19,.074,.238)
    pavilion(g,-.64,-.26,.045,.29,.27,.22)
    pavilion(g,.64,-.26,.045,.29,.27,.22)
    # Low processional rail at the rear leaves the frontal approach fully open.
    sector(g,x,y,.605,.626,.102,.139,0,math.pi,"cream",16)
    for i in range(9):
        a=i*math.pi/8
        g.box(x+.615*math.cos(a),y+.615*math.sin(a),.139,.030,.030,.067,"sandstone",a)
    sector(g,x,y,.604,.628,.206,.228,0,math.pi,"cream",16)


BUILDERS = {
    "rome": rome,
    "constantinople": constantinople,
    "delhi": delhi,
    "aden": aden,
    "simhala": simhala,
    "dagon": dagon,
}
