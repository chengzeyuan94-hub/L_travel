"""East Asian city library miniatures, authored from east-asian.png.

Called only by cities_019_common.Geometry019. No production export or imports.
The AI sheet's extra pagoda eaves are corrected to the specified five tiers.
Open courts and major architectural volumes take priority over tile engraving.
"""
import math


def roof(g, x, y, z, w, d, h, mat="roof_red", angle=0):
    if angle:
        g.quanzhou_roof(x, y, z, w, d, h, mat, angle)
    else:
        g.east_roof(x, y, z, w, d, h, mat)


def platform(g, x, y, z, w, d, h=.055):
    g.box(x, y, z, w, d, h*.70, "stone")
    g.box(x, y, z+h*.70, w*1.035, d*1.035, h*.30, "cream")


def hall(g, x, y, z, w, d, h, tile="roof_red", bays=3):
    """Solid rear room with a genuinely open front and side porch."""
    platform(g, x, y, z, w*1.02, d*1.05, .045)
    floor=z+.045
    g.box(x, y+d*.13, floor, w*.83, d*.56, h, "cream")
    front=y-d*.43
    for i in range(bays+1):
        xx=x+w*.88*(i/bays-.5)
        g.box(xx, front, floor, .028, .032, h+.014, "terracotta")
        g.box(xx, front, floor-.005, .042, .046, .030, "stone")
        g.box(xx, front, floor+h-.038, .051, .049, .035, "dark_wood")
    for xx in (x-w*.44, x+w*.44):
        for yy in (y+d*.06, y+d*.36):
            g.box(xx, yy, floor, .028, .032, h, "terracotta")
    g.box(x, front, floor+h-.006, w*.94, .045, .030, "terracotta")
    for i in range(bays):
        xx=x+w*.77*((i+.5)/bays-.5)
        g.box(xx, y-d*.154-.006, floor+.035, w*.37/bays, .012, h*.65, "dark_wood")
    roof(g, x, y, floor+h+.014, w*1.16, d*1.21, h*.47, tile)
    return floor+h+.014+h*.47


def gallery(g, x, y, z, w, d, h=.16, tile="teal"):
    g.box(x, y, z, w, d, .026, "stone")
    for xx in (x-w*.34, x+w*.34):
        for yy in (y-d*.40, y, y+d*.40):
            g.box(xx, yy, z+.026, .025, .027, h, "terracotta")
        g.box(xx, y, z+h+.014, .035, d*.89, .028, "dark_wood")
    roof(g, x, y, z+h+.039, w*1.18, d*1.055, .058, tile)


def courtyard_paving(g, x, y, z, w, d, nx=3, ny=3):
    for i in range(nx):
        for j in range(ny):
            g.box(x+w*((i+.5)/nx-.5), y+d*((j+.5)/ny-.5), z,
                  w/nx-.006, d/ny-.006, .008, "cream")


def open_gate(g, x, y, z, w, depth=.17, height=.20, tile="roof_red"):
    """Timber gateway, with no box or door plane blocking the passage."""
    for xx in (x-w*.34, x+w*.34):
        g.box(xx, y, z, w*.14, depth*.62, height, "cream")
        g.box(xx, y-depth*.35, z, .025, .030, height, "terracotta")
    g.box(x, y, z+height-.015, w*.86, depth*.69, .045, "dark_wood")
    roof(g, x, y, z+height+.024, w*1.18, depth*1.18, .077, tile)


def changan(g):
    g.terrace(1.90, 1.45, "stone")
    # The original triple gate is lower, so its court remains visible behind.
    for x in (-.47, 0, .47):
        central=abs(x)<.1
        w=.23 if central else .18
        h=.24 if central else .205
        g.arch(x, -.43, .052, w, h, .15, "sandstone", steps=7)
        deck=.345 if central else .313
        g.box(x, -.43, deck, .37 if central else .29, .205, .037, "cream")
        hall(g, x, -.43, deck+.037, .30 if central else .24, .18,
             .095 if central else .074, "roof_red", 2)
        g.steps(x, -.566, .046, w+.08, .13, .040, 3, "stone")
    for x,w in ((-.765,.14),(-.245,.15),(.245,.15),(.765,.14)):
        g.box(x, -.43, .046, w, .15, .265, "sandstone")
        g.box(x, -.43, .311, w+.012, .17, .025, "cream")
    for x in (-.77,.77):
        g.box(x,.015,.046,.045,.75,.18,"cream")
        gallery(g,x*.87,.045,.05,.20,.60,.145,"teal")
    courtyard_paving(g,0,-.035,.045,1.02,.48,4,3)
    hall(g,0,.405,.155,.95,.40,.205,"teal",4)
    g.box(0,.405,.465,.65,.235,.19,"cream")
    for x in (-.255,-.085,.085,.255):
        g.box(x,.282,.50,.026,.032,.15,"terracotta")
    roof(g,0,.405,.662,.76,.34,.125,"roof_red")
    g.steps(0,.065,.046,.39,.235,.11,5,"cream")
    for x in (-.36,.36):
        g.box(x,.145,.16,.20,.040,.070,"cream")
    g.box(0,.641,.045,1.45,.045,.17,"cream")


def timber_pagoda(g,x,y,width=.43,dh=.154,floors=5):
    platform(g,x,y,.045,width*1.17,width*1.17,.060)
    for i in range(floors):
        w=width*(1-i*.11);z=.105+i*dh
        g.box(x,y,z,w*.60,w*.60,dh*.75,"cream")
        for xx in (-.30,.30):
            for yy in (-.30,.30):
                g.box(x+xx*w,y+yy*w,z,.022,.023,dh*.77,"terracotta")
        for angle in (0,math.pi/2,math.pi,3*math.pi/2):
            verts=[(-w*.10,-w*.306,dh*.18),(w*.10,-w*.306,dh*.18),
                   (w*.10,-w*.306,dh*.60),(-w*.10,-w*.306,dh*.60)]
            g.mesh(verts,[(0,1,2,3)],"dark_wood",(x,y,z),angle)
        g.box(x,y,z+dh*.68,w*.71,w*.71,.023,"dark_wood")
        roof(g,x,y,z+dh*.76,w,w,dh*.34,"teal")
    top=.105+(floors-1)*dh+dh*1.10
    g.ring(x,y,top,.018,.125,"cream",8,top=.008)
    for i in range(4):
        g.ring(x,y,top+.023+i*.023,.037-i*.006,.009,"cream",8)


def heijokyo(g):
    g.terrace(1.85,1.45,"stone")
    timber_pagoda(g,-.51,.075,.43)
    g.steps(-.51,-.229,.045,.30,.15,.061,4,"cream")
    hall(g,.23,.365,.12,.66,.40,.19,"roof_red",3)
    g.box(.23,.365,.425,.44,.24,.135,"cream")
    for x in (.07,.23,.39):
        g.box(x,.236,.437,.023,.028,.122,"terracotta")
    roof(g,.23,.365,.575,.51,.32,.105,"teal")
    g.steps(.23,.064,.045,.29,.18,.075,4,"cream")
    gallery(g,.688,.045,.045,.17,.61,.145,"roof_red")
    open_gate(g,.16,-.463,.05,.34,.19,.18,"teal")
    for x,w in ((-.37,.70),(.546,.40)):
        g.box(x,-.473,.045,w,.050,.145,"cream")
        g.box(x,-.473,.19,w+.025,.072,.025,"teal")
    courtyard_paving(g,.145,-.128,.045,.59,.40,3,3)
    g.box(.08,.628,.045,1.24,.043,.16,"cream")
    g.steps(.16,-.635,.042,.34,.16,.028,3,"stone")


def observatory(g,x,y):
    platform(g,x,y,.045,.48,.48,.050)
    profile=[(.222,.095),(.218,.19),(.196,.31),(.168,.44),(.149,.565),(.151,.675),(.173,.758)]
    n=16;verts=[]
    for inner in (False,True):
        for radius,z in profile:
            rr=radius-(.036 if inner else 0)
            verts.extend((rr*math.cos(-math.pi/2+i*math.tau/n),
                          rr*math.sin(-math.pi/2+i*math.tau/n),z) for i in range(n))
    offset=len(profile)*n;faces=[]
    # The two front facets are actually open from .31 to .44, with reveals.
    for j in range(len(profile)-1):
        for i in range(n):
            k=(i+1)%n;a=j*n+i;b=j*n+k;c=(j+1)*n+k;d=(j+1)*n+i
            if j==2 and i in (0,15):
                faces.extend([(a,b,b+offset,a+offset),(d,d+offset,c+offset,c)])
                if i==0:faces.append((b,c,c+offset,b+offset))
                if i==15:faces.append((a,a+offset,d+offset,d))
            else:
                faces.extend([(a,b,c,d),(a+offset,d+offset,c+offset,b+offset)])
    for i in range(n):
        k=(i+1)%n;t=(len(profile)-1)*n
        faces.extend([(i,i+offset,k+offset,k),(t+i,t+k,t+k+offset,t+i+offset)])
    g.mesh(verts,faces,"stone",(x,y,0))
    for radius,z in ((.215,.19),(.198,.292),(.158,.512),(.15,.61),(.164,.725)):
        g.ring(x,y,z,radius+.005,.011,"cream",16,inner=radius-.008)
    for xx in (-.147,.147):g.box(x+xx,y,.755,.050,.345,.067,"cream")
    for yy in (-.147,.147):g.box(x,y+yy,.755,.345,.050,.067,"cream")
    g.box(x,y-.189,.312,.114,.012,.014,"cream")
    g.box(x,y-.179,.437,.114,.019,.020,"cream")


def geumseong(g):
    g.terrace(1.90,1.35,"stone")
    observatory(g,-.51,-.04)
    hall(g,.30,.373,.105,.65,.29,.17,"deep_shadow",3)
    for x in (.007,.596):gallery(g,x,.082,.105,.15,.43,.125,"deep_shadow")
    courtyard_paving(g,.301,.05,.103,.38,.36,2,3)
    g.steps(.301,-.251,.045,.25,.16,.061,4,"cream")
    for x in (.025,.57):
        g.box(x,-.184,.05,.19,.055,.10,"stone")
        g.box(x,-.184,.15,.21,.069,.025,"cream")
    g.dome(.66,.47,.045,.18,.115,"foliage",12,4)
    g.ring(.66,.47,.045,.20,.031,"cream",12,inner=.17)


def cross_mass(g,x,y,z,w,d,h,mat="sandstone",top=1):
    outline=[(-.5,-.28),(-.28,-.28),(-.28,-.5),(.28,-.5),(.28,-.28),(.5,-.28),
             (.5,.28),(.28,.28),(.28,.5),(-.28,.5),(-.28,.28),(-.5,.28)]
    verts=[(a*w,b*d,0) for a,b in outline]+[(a*w*top,b*d*top,h) for a,b in outline]
    faces=[tuple(range(11,-1,-1)),tuple(range(12,24))]
    faces.extend((i,(i+1)%12,(i+1)%12+12,i+12) for i in range(12))
    g.mesh(verts,faces,mat,(x,y,z))


def portal(g,x,y,z,w,h,depth,angle=0):
    # Deep dark rear plane, flanking jambs, projecting lintel and stepped crest.
    def box(xx,yy,zz,bw,bd,bh,mat):
        c,s=math.cos(angle),math.sin(angle)
        g.box(x+c*xx-s*yy,y+s*xx+c*yy,z+zz,bw,bd,bh,mat,angle)
    box(0,-.003,h*.05,w*.61,.008,h*.89,"deep_shadow")
    for xx in (-w*.43,w*.43):box(xx,0,0,w*.21,depth,h,"sandstone")
    box(0,0,h,w*1.12,depth,.045,"sandstone")
    box(0,.006,h+.045,w*.90,depth*.88,.034,"sandstone")


def khmer_shoulder(g,x,y,z,w,d,h,top=1,mat="stone"):
    # Broad chamfered masonry, unlike the narrow central cross in a finial.
    outline=[(-.5,-.35),(-.35,-.5),(.35,-.5),(.5,-.35),
             (.5,.35),(.35,.5),(-.35,.5),(-.5,.35)]
    verts=[(a*w,b*d,0) for a,b in outline]+[(a*w*top,b*d*top,h) for a,b in outline]
    faces=[tuple(range(7,-1,-1)),tuple(range(8,16))]
    faces.extend((i,(i+1)%8,(i+1)%8+8,i+8) for i in range(8))
    g.mesh(verts,faces,mat,(x,y,z))


def face_relief(g,x,y,z,scale,angle):
    """One shallow contiguous stone field, broad brow/cheeks/nose/jaw."""
    # The backing follows the taper of the same masonry face. Projection is
    # at most .034 before scale, not a detached box or sharp floating nose.
    rows=[(.014,.071,(.004,.010,.012,.010,.004)),
          (.046,.102,(.004,.016,.017,.016,.004)),
          (.071,.120,(.003,.018,.012,.018,.003)),
          (.113,.120,(.003,.019,.034,.019,.003)),
          (.157,.111,(.003,.027,.029,.027,.003)),
          (.191,.095,(.003,.014,.017,.014,.003))]
    verts=[]
    for zz,width,depths in rows:
        for f,depth in zip((-1,-.5,0,.5,1),depths):
            verts.append((f*width*scale,(-.198+zz*.060-depth)*scale,zz*scale))
    front_count=len(verts)
    for zz,width,depths in rows:
        for f in (-1,-.5,0,.5,1):verts.append((f*width*scale,(-.198+zz*.060+.001)*scale,zz*scale))
    polys=[]
    for j in range(len(rows)-1):
        for i in range(4):
            a=j*5+i;b=a+1;c=a+6;d=a+5
            polys.extend([(a,b,c,d),(a+front_count,d+front_count,c+front_count,b+front_count)])
    outline=list(range(5))+[j*5+4 for j in range(1,len(rows))]+list(range(28,24,-1))+[j*5 for j in range(len(rows)-2,0,-1)]
    for a,b in zip(outline,outline[1:]+outline[:1]):polys.append((a,b,b+front_count,a+front_count))
    g.mesh(verts,polys,"stone",(x,y,z),angle)


def khmer_tower(g,x,y,z,scale=1,faces=False):
    s=scale
    cross_mass(g,x,y,z,.55*s,.53*s,.052*s,"stone")
    khmer_shoulder(g,x,y,z+.052*s,.51*s,.49*s,.081*s,.95)
    khmer_shoulder(g,x,y,z+.133*s,.465*s,.455*s,.304*s,.94)
    # Corner buttresses read as substantial stone returns at all four corners.
    for xx in (-.178,.178):
        for yy in (-.173,.173):
            g.box(x+xx*s,y+yy*s,z+.135*s,.069*s,.067*s,.293*s,"stone")
    for angle in (0,math.pi/2,math.pi,3*math.pi/2):
        dx,dy=math.sin(angle)*.234*s,-math.cos(angle)*.234*s
        portal(g,x+dx,y+dy,z+.135*s,.166*s,.229*s,.044*s,angle)
    khmer_shoulder(g,x,y,z+.437*s,.461*s,.451*s,.078*s,.88)
    level=z+.515*s
    if faces:
        # Shoulders, head drum and crown are one steadily receding envelope.
        khmer_shoulder(g,x,y,level,.406*s,.402*s,.035*s,.98)
        khmer_shoulder(g,x,y,level+.035*s,.398*s,.394*s,.205*s,.94)
        for a in (0,math.pi/2,math.pi,3*math.pi/2):
            face_relief(g,x,y,level+.035*s,s,a)
        level+=.240*s
    for i in range(4):
        w=(.40-i*.074)*s
        cross_mass(g,x,y,level+i*.056*s,w,w,.021*s,"stone")
        khmer_shoulder(g,x,y,level+(.021+i*.056)*s,w*.94,w*.94,.038*s,.81,"stone")
    g.ring(x,y,level+.229*s,.038*s,.045*s,"stone",8,top=.012*s)


def chenla(g):
    g.terrace(1.80,1.45,"stone")
    g.box(0,.13,.045,.66,.64,.085,"stone")
    g.box(0,.13,.130,.60,.59,.060,"sandstone")
    khmer_tower(g,0,.145,.19,.80,True)
    for x,y,s in ((-.47,-.15,.70),(.47,-.12,.73)):
        khmer_tower(g,x,y,.045,s)
        g.steps(x,y-.276,.045,.205,.14,.068,4,"cream")
    g.steps(0,-.348,.045,.305,.356,.145,7,"cream")
    for x in (-.203,.203):
        g.box(x,-.345,.045,.068,.36,.13,"sandstone")
        g.box(x,-.345,.175,.079,.36,.024,"cream")
    for x in (-.71,.71):
        g.box(x,.19,.045,.10,.47,.078,"stone")


def stone_tower_body(g,x,y,z,r,h):
    n=8;rotation=math.pi/8
    ring=[(r*math.cos(rotation+i*math.tau/n),r*math.sin(rotation+i*math.tau/n)) for i in range(n)]
    cap=[(a,b,zz) for zz in (0,h) for a,b in ring]
    g.mesh(cap,[tuple(range(7,-1,-1)),tuple(range(8,16))],"cream",(x,y,z))
    for i in range(n):
        a=ring[i];b=ring[(i+1)%n];mx,my=(a[0]+b[0])*.5,(a[1]+b[1])*.5
        length=math.dist(a,b);tx,ty=(b[0]-a[0])/length,(b[1]-a[1])/length
        rr=math.hypot(mx,my);nx,ny=mx/rr,my/rr
        def point(u,v,depth=0):return (x+mx+tx*u+nx*depth,y+my+ty*u+ny*depth,z+v)
        if i%2:
            g.mesh([point(-length/2,0),point(length/2,0),point(length/2,h),point(-length/2,h)],[(0,1,2,3)],"cream")
            continue
        half=length/2;aw=length*.22;zl=h*.15;zt=h*.79;cut=h*.12
        outer=[(-half,0),(half,0),(half,h*.78),(half,h),(-half,h),(-half,h*.78)]
        opening=[(-aw,zl),(aw,zl),(aw,zt-cut),(aw*.72,zt),(-aw*.72,zt),(-aw,zt-cut)]
        verts=[point(u,v) for u,v in outer]+[point(u,v) for u,v in opening]+[point(u,v,-.016) for u,v in opening]
        frame=[(k,(k+1)%6,(k+1)%6+6,k+6) for k in range(6)]
        reveal=[(k+6,(k+1)%6+6,(k+1)%6+12,k+12) for k in range(6)]
        g.mesh(verts,frame,"cream");g.mesh(verts,reveal,"sandstone")
        g.mesh(verts,[tuple(range(12,18))],"deep_shadow")


def stone_eave(g,x,y,z,r,h):
    n=16;verts=[]
    for layer in range(4):
        for i in range(n):
            angle=math.pi/8+i*math.tau/n;corner=i%2==0
            if layer<2:
                radius=r if corner else r*math.cos(math.pi/8)
                zz=(h*.24 if corner else 0)-(.013 if layer==0 else 0)
            else:
                radius=r*(.70 if layer==2 else .40)
                zz=h*(.38 if layer==2 else 1)
            verts.append((radius*math.cos(angle),radius*math.sin(angle),zz))
    edges=[tuple(range(15,-1,-1))]+[(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
    faces=[tuple(range(48,64))]
    for layer in (1,2):faces.extend((layer*n+i,layer*n+(i+1)%n,(layer+1)*n+(i+1)%n,(layer+1)*n+i) for i in range(n))
    g.mesh(verts,edges,"sandstone",(x,y,z));g.mesh(verts,faces,"stone",(x,y,z))


def stone_pagoda(g,x,y,scale=1):
    g.ring(x,y,.045,.252,.025,"stone",8,rotation=math.pi/8)
    g.ring(x,y,.070,.220,.035,"cream",8,rotation=math.pi/8)
    for i in range(5):
        r=(.169-i*.014)*scale;z=.105+i*.166*scale
        stone_tower_body(g,x,y,z,r,.115*scale)
        g.ring(x,y,z+.104*scale,r*1.11,.025*scale,"sandstone",8,rotation=math.pi/8)
        stone_eave(g,x,y,z+.131*scale,r*1.32,.052*scale)
    z=.105+4*.166*scale+.184*scale
    for i in range(3):g.ring(x,y,z+i*.028,.037*(1-i*.25),.022,"cream",8,top=.027*(1-i*.25))
    g.ring(x,y,z+.078,.015,.035,"cream",8,top=0)


def quanzhou(g):
    g.terrace(1.90,1.50,"stone")
    stone_pagoda(g,-.47,.195,1.0)
    stone_pagoda(g,.47,.195,.91)
    hall(g,0,.415,.08,.39,.29,.155,"roof_red",2)
    g.steps(0,.157,.045,.235,.16,.050,3,"cream")
    # 012 already had thick eaves, side walks, niches and a three-arch gate.
    # This library recasts the towers in stone and opens the axis between them.
    for xx in (-.18,0,.18):g.arch(xx,-.479,.045,.112,.125,.14,"cream",steps=5)
    g.box(0,-.479,.195,.65,.20,.033,"stone")
    hall(g,0,-.479,.228,.51,.19,.10,"roof_red",3)
    for x in (-.62,.62):
        hall(g,x,-.36,.045,.245,.24,.13,"roof_red",2)
        gallery(g,x,-.047,.045,.19,.315,.13,"teal")
    courtyard_paving(g,0,-.115,.045,.64,.48,3,4)
    g.box(0,-.657,.045,.29,.14,.010,"cream")
    g.box(0,.663,.045,1.33,.035,.13,"cream")


BUILDERS={"changan":changan,"heijokyo":heijokyo,"geumseong":geumseong,"chenla":chenla,"quanzhou":quanzhou}
