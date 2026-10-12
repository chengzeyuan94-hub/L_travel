"""Five independently authored caravan cities for CITY-LIBRARY-019.

The callable contract is builder(Geometry019).  Authoring coordinates are the
legacy Blender frame (Z up); the common exporter preserves each old city's
scale and origin.  Nothing in this module reads or writes production assets.
Open courts, gates, arcades, and alleys are gaps in the actual solids.
"""
import math


def _taper_box(g, x, y, z, w, d, h, top_w=None, top_d=None,
               mat='sandstone', chamfer=.08, angle=0):
    """Closed eight-corner prism: a broad physical edge, not painted bevels."""
    top_w = w if top_w is None else top_w
    top_d = d if top_d is None else top_d
    vertices = []
    for ww, dd, zz in ((w, d, 0), (top_w, top_d, h)):
        c = min(ww, dd) * chamfer
        vertices.extend([(-ww/2+c, -dd/2, zz), (ww/2-c, -dd/2, zz),
                         (ww/2, -dd/2+c, zz), (ww/2, dd/2-c, zz),
                         (ww/2-c, dd/2, zz), (-ww/2+c, dd/2, zz),
                         (-ww/2, dd/2-c, zz), (-ww/2, -dd/2+c, zz)])
    faces = [tuple(range(7, -1, -1)), tuple(range(8, 16))]
    faces += [(i, (i+1)%8, (i+1)%8+8, i+8) for i in range(8)]
    g.mesh(vertices, faces, mat, (x, y, z), angle)


def _base(g, w, d):
    _taper_box(g, 0, 0, 0, w, d, .035, w-.022, d-.022,
               'stone', chamfer=.09)


def _box_local(g, x, y, z, lx, ly, lz, w, d, h, mat, angle=0):
    c, s = math.cos(angle), math.sin(angle)
    g.box(x+lx*c-ly*s, y+lx*s+ly*c, z+lz, w, d, h, mat, angle)


def _beam(g, a, b, width, mat='dark_wood', depth=None):
    """A closed square-section beam between two points, without negative scale."""
    depth = width if depth is None else depth
    axis = tuple(b[i]-a[i] for i in range(3))
    length = math.sqrt(sum(v*v for v in axis))
    axis = tuple(v/length for v in axis)
    ref = (0, 1, 0) if abs(axis[2]) > .95 else (0, 0, 1)
    u = (axis[1]*ref[2]-axis[2]*ref[1],
         axis[2]*ref[0]-axis[0]*ref[2],
         axis[0]*ref[1]-axis[1]*ref[0])
    ul = math.sqrt(sum(v*v for v in u))
    u = tuple(v/ul for v in u)
    v = (axis[1]*u[2]-axis[2]*u[1],
         axis[2]*u[0]-axis[0]*u[2],
         axis[0]*u[1]-axis[1]*u[0])
    vertices = [tuple(p[i]+su*u[i]*width/2+sv*v[i]*depth/2 for i in range(3))
                for p in (a, b) for su, sv in ((-1,-1),(1,-1),(1,1),(-1,1))]
    g.mesh(vertices, [(0,3,2,1),(4,5,6,7),(0,1,5,4),
                      (1,2,6,5),(2,3,7,6),(3,0,4,7)], mat)


def _merlons(g, x, y, z, length, count, mat='cream', angle=0,
             depth=.062, height=.060, fraction=.53):
    for i in range(count):
        local_x = (-.5+(i+.5)/count)*length
        _box_local(g, x, y, z, local_x, 0, 0,
                   length/count*fraction, depth, height, mat, angle)


def _roof_rail(g, x, y, z, w, d, height=.060, mat='cream', thickness=.030):
    g.box(x, y-d/2+thickness/2, z, w, thickness, height, mat)
    g.box(x, y+d/2-thickness/2, z, w, thickness, height, mat)
    g.box(x-w/2+thickness/2, y, z, thickness, d-2*thickness, height, mat)
    g.box(x+w/2-thickness/2, y, z, thickness, d-2*thickness, height, mat)


def _cupola(g, x, y, z, radius, height, mat='cream', sides=24, steps=6):
    """A closed dome with one true apex; there is no near-zero top ring."""
    vertices = []
    for j in range(steps):
        a = j/steps*math.pi/2
        vertices.extend((radius*math.cos(a)*math.cos(i*math.tau/sides),
                         radius*math.cos(a)*math.sin(i*math.tau/sides),
                         height*math.sin(a)) for i in range(sides))
    vertices.append((0,0,height))
    apex = len(vertices)-1
    faces = [tuple(range(sides-1, -1, -1))]
    for j in range(steps-1):
        faces += [(j*sides+i, j*sides+(i+1)%sides,
                   (j+1)*sides+(i+1)%sides, (j+1)*sides+i) for i in range(sides)]
    faces += [((steps-1)*sides+i, (steps-1)*sides+(i+1)%sides, apex)
              for i in range(sides)]
    g.mesh(vertices, faces, mat, (x,y,z))


def _cloth(g, x, y, z, w, d, sag=.060, mat='gold', angle=0,
           x_steps=6, y_steps=4):
    """An actual thick draped canopy, with a continuous closed edge."""
    vertices = []
    for layer in (0, -.018):
        for j in range(y_steps+1):
            v = -1+2*j/y_steps
            for i in range(x_steps+1):
                u = -1+2*i/x_steps
                vertices.append((u*w/2, v*d/2, sag*(u*u+.45*v*v)+layer))
    n = (x_steps+1)*(y_steps+1)
    faces = []
    for j in range(y_steps):
        for i in range(x_steps):
            a = j*(x_steps+1)+i
            quad = (a,a+1,a+x_steps+2,a+x_steps+1)
            faces += [quad, tuple(k+n for k in reversed(quad))]
    edge = (list(range(x_steps+1)) +
            [j*(x_steps+1)+x_steps for j in range(1,y_steps+1)] +
            [y_steps*(x_steps+1)+i for i in range(x_steps-1,-1,-1)] +
            [j*(x_steps+1) for j in range(y_steps-1,0,-1)])
    faces += [(a, edge[(i+1)%len(edge)], edge[(i+1)%len(edge)]+n, a+n)
              for i,a in enumerate(edge)]
    g.mesh(vertices, faces, mat, (x,y,z), angle)


def _crate(g, x, y, z, w=.12, d=.12, h=.12):
    g.box(x,y,z,w,d,h,'dark_wood')
    for dx in (-w*.31,w*.31):
        g.box(x+dx,y,z+h,.015,d+.008,.011,'sandstone')
        g.box(x+dx,y-d/2-.004,z,.015,.010,h,'sandstone')


def _fort_tower(g, x, y, h, w=.235, d=.235):
    _taper_box(g,x,y,.035,w+.028,d+.028,h,w,d,'sandstone')
    g.box(x,y,.035+h,w+.045,d+.045,.035,'cream')
    _roof_rail(g,x,y,.070+h,w+.045,d+.045,.028,'sandstone',.038)
    for yy in (-d/2-.003,d/2+.003):
        _merlons(g,x,y+yy,.098+h,w+.045,2,'cream',depth=.063,height=.060)
    for xx in (-w/2-.003,w/2+.003):
        _merlons(g,x+xx,y,.098+h,d-.075,1,'cream',angle=math.pi/2,
                 depth=.063,height=.060)


def yumenguan(g):
    _base(g,1.8,1.25)
    # An empty court enclosed by four walls, not a solid box under a roof.
    g.box(-.13,.02,.035,.97,.76,.009,'sandstone')
    g.box(-.685,0,.035,.11,1.02,.345,'sandstone')
    g.box(.445,0,.035,.11,1.02,.345,'sandstone')
    g.box(-.12,.475,.035,1.13,.11,.345,'sandstone')
    g.box(-.525,-.475,.035,.329,.12,.345,'sandstone')
    g.box(.263,-.475,.035,.361,.12,.345,'sandstone')
    for xx in (-.685,.445):
        g.box(xx,0,.38,.155,1.0,.032,'cream')
        _merlons(g,xx,0,.412,.88,6,angle=math.pi/2)
    g.box(-.12,.475,.38,1.13,.15,.032,'cream')
    _merlons(g,-.12,.49,.412,1.02,7)
    for xx in (-.66,.42):
        _fort_tower(g,xx,-.425,.435)
        _fort_tower(g,xx,.415,.455)
    for xx in (-.752,.512):
        for yy in (-.16,.19):
            _taper_box(g,xx,yy,.035,.075,.11,.285,.045,.075,'sandstone')
    # Both gate faces open onto the same through-passage.
    g.arch(-.13,-.493,.035,.31,.310,.18,'cream',steps=9)
    g.box(-.13,-.475,.405,.465,.225,.038,'sandstone')
    g.box(-.13,-.475,.443,.54,.32,.027,'cream')
    for xx in (-.33,.07):
        for yy in (-.578,-.365):
            g.box(xx,yy,.470,.036,.036,.228,'dark_wood')
    for yy in (-.578,-.365):
        g.box(-.13,yy,.683,.46,.038,.035,'dark_wood')
        g.box(-.13,yy,.526,.46,.025,.022,'dark_wood')
        for xx in (-.23,-.03):
            g.box(xx,yy,.485,.024,.024,.062,'dark_wood')
    for xx in (-.33,.07):
        g.box(xx,-.4715,.683,.036,.248,.035,'dark_wood')
        _beam(g,(xx,-.574,.555),(xx,-.366,.669),.023)
    g.east_roof(-.13,-.475,.718,.605,.386,.115,'roof_red')
    # Broad access stairs reach the left wall walk from inside the courtyard.
    g.steps(-.485,.245,.044,.15,.375,.350,7,'cream')
    # The side beacon is a separate high silhouette, with an open timber crown.
    _taper_box(g,.716,.305,.035,.235,.255,.69,.154,.174,'sandstone')
    for zz,ww,dd in ((.280,.218,.238),(.515,.187,.207)):
        g.box(.716,.305,zz,ww,dd,.029,'cream')
    g.box(.716,.305,.725,.267,.287,.035,'cream')
    for dx in (-.109,0,.109):
        for dy in (-.119,.119):
            g.box(.716+dx,.305+dy,.760,.024,.024,.154,'dark_wood')
    for dy in (-.119,.119):
        for zz in (.806,.897):
            g.box(.716,.305+dy,zz,.258,.024,.021,'dark_wood')
    for dx in (-.109,.109):
        for zz in (.806,.897):
            g.box(.716+dx,.305,zz,.024,.26,.021,'dark_wood')
    g.ring(.716,.305,.917,.079,.035,'stone',12,top=.066)
    g.ring(.716,.305,.952,.045,.095,'terracotta',7,top=0)
    g.ring(.735,.312,.952,.024,.064,'gold',6,top=0)


def panti(g):
    _base(g,1.85,1.3)
    g.box(0,.01,.035,1.43,1.05,.008,'sandstone')
    # Rear store is a roofed arcade: the front bays have real empty depth.
    g.box(0,.491,.043,1.47,.064,.322,'sandstone')
    for xx in (-.717,.717):
        g.box(xx,.377,.043,.055,.232,.322,'sandstone')
    for xx in (-.45,0,.45):
        g.arch(xx,.259,.043,.245,.265,.085,'cream',steps=8)
    for xx in (-.672,-.225,.225,.672):
        g.box(xx,.26,.043,.100,.085,.324,'sandstone')
    g.box(0,.366,.367,1.50,.323,.048,'cream')
    _roof_rail(g,0,.386,.415,1.49,.265,.065,'sandstone',.042)
    _merlons(g,0,.499,.480,1.37,9,'cream',depth=.062,height=.04)
    # Low side walls leave the caravan court open and asymmetrical.
    _taper_box(g,-.739,-.016,.043,.102,.645,.285,.080,.645,'sandstone')
    _taper_box(g,.739,-.062,.043,.102,.55,.233,.080,.55,'sandstone')
    _merlons(g,-.739,-.046,.328,.56,4,'cream',math.pi/2)
    _merlons(g,.739,-.04,.276,.43,3,'cream',math.pi/2)
    for xx in (-.577,.577):
        g.box(xx,-.463,.043,.289,.12,.24,'sandstone')
        _merlons(g,xx,-.473,.283,.26,2,'cream',height=.06)
    for xx in (-.304,.304):
        _taper_box(g,xx,-.445,.043,.273,.28,.412,.228,.228,'sandstone')
        g.box(xx,-.445,.455,.250,.250,.036,'cream')
        _roof_rail(g,xx,-.445,.491,.25,.25,.060,'sandstone',.047)
        for dx in (-.098,.098):
            for dy in (-.098,.098):
                g.box(xx+dx,-.445+dy,.551,.057,.057,.043,'cream')
    # The 0.335-wide entrance remains empty under substantial timber lintels.
    for yy in (-.51,-.40):
        g.box(0,yy,.399,.430,.055,.063,'dark_wood')
    for xx in (-.184,.184):
        g.box(xx,-.459,.043,.036,.17,.356,'dark_wood')
    # Thick cloth, four structural corner posts, and useful crates underneath.
    canopy_x,canopy_y = -.394,-.005
    for dx in (-.246,.246):
        for dy in (-.207,.207):
            g.box(canopy_x+dx,canopy_y+dy,.043,.029,.029,.442,'dark_wood')
    _cloth(g,canopy_x,canopy_y,.397,.515,.441,.060,'gold')
    _crate(g,-.53,.043,.043,.14,.13,.15)
    _crate(g,-.34,.102,.043,.12,.13,.12)
    _crate(g,-.55,-.124,.043,.13,.12,.105)
    # Open stone well; the dark disk is at its bottom rather than across its rim.
    g.ring(.281,.016,.043,.142,.105,'cream',18,inner=.099)
    g.ring(.281,.016,.148,.153,.026,'sandstone',18,inner=.099)
    g.ring(.281,.016,.046,.091,.009,'deep_shadow',18)
    for xx in (.095,.467):
        g.box(xx,.016,.043,.027,.027,.287,'dark_wood')
    g.box(.281,.016,.330,.417,.035,.032,'dark_wood')
    g.box(.281,.016,.153,.012,.012,.177,'dark_wood')
    g.ring(.281,.016,.104,.040,.054,'dark_wood',10,inner=.029)
    # A rear lookout provides height without roofing over the court.
    _taper_box(g,.584,.365,.415,.223,.221,.229,.202,.202,'sandstone')
    g.box(.584,.365,.644,.24,.24,.029,'cream')
    for dx in (-.085,.085):
        for dy in (-.085,.085):
            g.box(.584+dx,.365+dy,.673,.026,.026,.142,'dark_wood')
    for yy in (-.094,-.047,0,.047,.094):
        g.box(.584,.365+yy,.815,.276,.025,.023,'dark_wood')
    for xx in (-.095,.095):
        g.box(.584+xx,.365,.797,.028,.254,.024,'dark_wood')
    g.steps(.576,.135,.043,.127,.213,.372,6,'sandstone')


def _spiral_strip(g, x, y, z, inner_start, inner_end, outer_start,
                  outer_end, rise, turns, thickness, mat, steps=54,
                  angle=-math.pi/2):
    """One closed helical solid. Width and vertical air gaps stay physical."""
    vertices = []
    for i in range(steps+1):
        t=i/steps
        a=angle+t*turns*math.tau
        ri=inner_start*(1-t)+inner_end*t
        ro=outer_start*(1-t)+outer_end*t
        for r,zz in ((ri,rise*t),(ro,rise*t),
                     (ro,rise*t-thickness),(ri,rise*t-thickness)):
            vertices.append((r*math.cos(a),r*math.sin(a),zz))
    faces=[]
    for i in range(steps):
        for k in range(4):
            faces.append((i*4+k,i*4+(k+1)%4,(i+1)*4+(k+1)%4,(i+1)*4+k))
    faces.extend([(3,2,1,0),(steps*4,steps*4+1,steps*4+2,steps*4+3)])
    g.mesh(vertices,faces,mat,(x,y,z))


def baghdad(g):
    _base(g,1.85,1.5)
    g.ring(0,.015,.035,.684,.009,'sandstone',32)
    g.open_round_wall(0,.015,.044,.705,.603,.261,.290,'brick')
    g.open_round_wall(0,.015,.305,.721,.592,.033,.290,'cream')
    for i in range(23):
        a=-math.pi/2+.35+i*(math.tau-.70)/22
        g.box(.690*math.cos(a),.015+.690*math.sin(a),.338,
              .075,.065,.063,'cream',a+math.pi/2)
    for a in (-.76,.20,1.05,2.05,2.94,3.80):
        _taper_box(g,.710*math.cos(a),.015+.710*math.sin(a),.044,
                   .066,.077,.231,.05,.052,'brick',angle=a)
    # The front arch sits in the omitted circular-wall segment.
    g.arch(0,-.659,.034,.290,.328,.15,'cream',steps=10)
    for xx in (-.222,.222):
        _taper_box(g,xx,-.661,.034,.108,.154,.372,.098,.140,'brick')
        g.box(xx,-.661,.406,.126,.176,.028,'cream')
    g.box(0,-.659,.419,.528,.185,.035,'sandstone')
    _merlons(g,0,-.714,.454,.53,4,'cream',height=.062)
    # Rear pavilion: three walls, a real portal, and a blue crown above it.
    for xx in (-.094,.414):
        g.box(xx,.272,.044,.054,.323,.393,'sandstone')
    g.box(.16,.421,.044,.51,.052,.393,'sandstone')
    g.arch(.16,.116,.044,.326,.334,.090,'cream',steps=10)
    g.box(.16,.275,.437,.586,.414,.037,'cream')
    g.ring(.16,.275,.474,.249,.081,'cream',24,inner=.205)
    _cupola(g,.16,.275,.555,.277,.255,'teal',24,6)
    g.ring(.16,.275,.810,.022,.045,'gold',8,top=0)
    # External ramp has a substantial 0.12..0.087 width. Its inner edge meets
    # the core; no loose ribbon or spiral slabs are hidden inside the tower.
    tx,ty=-.405,-.018
    g.ring(tx,ty,.044,.135,.731,'sandstone',16,top=.070)
    _spiral_strip(g,tx,ty,.066,.122,.064,.246,.151,
                  .709,1.65,.022,'cream')
    _spiral_strip(g,tx,ty,.101,.232,.137,.246,.151,
                  .709,1.65,.035,'cream')
    g.ring(tx,ty,.755,.107,.023,'cream',16)
    for i in range(6):
        a=i*math.tau/6
        g.box(tx+.058*math.cos(a),ty+.058*math.sin(a),.778,
              .023,.023,.143,'sandstone',a)
    g.ring(tx,ty,.921,.094,.024,'cream',16)
    _cupola(g,tx,ty,.945,.094,.088,'teal',16,4)
    g.ring(tx,ty,1.033,.016,.037,'gold',7,top=0)
    # Inner arcades are open at front and back; the wall behind is separated.
    for a in (.36,1.05,2.13,2.84):
        xx,yy=.532*math.cos(a),.015+.532*math.sin(a)
        g.arch(xx,yy,.044,.158,.216,.067,'cream',a+math.pi/2,steps=7)


def _minaret(g,x,y,height):
    s=height/1.060
    # Every height scales together, preserving readable balconies and lantern.
    _taper_box(g,x,y,.035,.204*s,.204*s,.181*s,
               .176*s,.176*s,'sandstone')
    g.ring(x,y,.035+.181*s,.093*s,.309*s,'cream',8,top=.073*s,
           rotation=math.pi/8)
    g.ring(x,y,.035+.490*s,.074*s,.061*s,'sandstone',12,top=.130*s)
    g.ring(x,y,.035+.551*s,.136*s,.027*s,'dark_wood',12,inner=.067*s)
    g.ring(x,y,.035+.578*s,.067*s,.214*s,'cream',8,top=.047*s,
           rotation=math.pi/8)
    for i in range(10):
        a=i*math.tau/10
        g.box(x+.118*s*math.cos(a),y+.118*s*math.sin(a),.035+.578*s,
              .017*s,.017*s,.067*s,'dark_wood',a)
    g.ring(x,y,.035+.635*s,.135*s,.017*s,'dark_wood',12,inner=.117*s)
    g.ring(x,y,.035+.792*s,.050*s,.031*s,'sandstone',12,top=.078*s)
    for i in range(6):
        a=i*math.tau/6
        g.box(x+.049*s*math.cos(a),y+.049*s*math.sin(a),.035+.823*s,
              .022*s,.022*s,.100*s,'cream',a)
    g.ring(x,y,.035+.923*s,.075*s,.020*s,'sandstone',12)
    g.ring(x,y,.035+.943*s,.073*s,.095*s,'teal',8,top=0)
    g.ring(x,y,.035+1.038*s,.016*s,.022*s,'gold',6,top=0)


def cairo(g):
    _base(g,1.8,1.45)
    g.box(0,-.011,.035,1.425,1.13,.010,'sandstone')
    # The rectangular central court remains empty above its paving.
    g.box(0,-.045,.045,.930,.663,.007,'cream')
    for xx in (-.702,.702):
        g.box(xx,-.012,.045,.058,.791,.327,'sandstone')
    for xx in (-.588,.588):
        for yy in (-.175,.088):
            g.arch(xx,yy,.045,.191,.299,.085,'cream',math.pi/2,steps=8)
        g.box(xx,-.0435,.379,.216,.73,.033,'cream')
        _merlons(g,xx+(-.068 if xx<0 else .068),-.038,.412,
                 .67,5,'sandstone',math.pi/2,depth=.045,height=.041)
    # Three rear rooms share an open arcade and a low roof behind the court.
    g.box(0,.503,.045,1.337,.058,.352,'sandstone')
    for xx in (-.642,.642):
        g.box(xx,.410,.045,.055,.207,.352,'sandstone')
    for xx in (-.408,.408):
        g.arch(xx,.307,.045,.248,.314,.089,'cream',steps=8)
    g.arch(0,.303,.045,.316,.367,.092,'cream',steps=10)
    for xx in (-.614,-.224,.224,.614):
        g.box(xx,.308,.045,.073,.092,.351,'sandstone')
    for xx in (-.445,.445):
        g.box(xx,.416,.408,.45,.276,.040,'cream')
    g.box(0,.503,.397,.454,.058,.073,'sandstone')
    # Raised central roof only covers the rear prayer room, never the courtyard.
    g.box(0,.410,.470,.454,.291,.035,'sandstone')
    g.ring(0,.415,.505,.177,.048,'cream',20)
    _cupola(g,0,.415,.553,.187,.154,'cream',20,5)
    g.ring(0,.415,.707,.017,.035,'gold',7,top=0)
    # Street edge: two lower arcades and a taller, genuinely open middle gate.
    for xx in (-.437,.437):
        g.arch(xx,-.470,.045,.231,.274,.12,'cream',steps=9)
        g.box(xx,-.470,.363,.359,.176,.030,'sandstone')
        _merlons(g,xx,-.494,.393,.35,3,'cream',height=.040)
    g.arch(0,-.470,.045,.301,.354,.153,'cream',steps=11)
    for xx in (-.223,.223):
        g.box(xx,-.47,.045,.037,.153,.401,'sandstone')
    g.box(0,-.470,.455,.485,.190,.039,'sandstone')
    _merlons(g,0,-.50,.494,.46,4,'cream',height=.047)
    # Contrasting unequal pointed towers; no large teal dome as in Baghdad.
    _minaret(g,-.631,.315,1.060)
    _minaret(g,.640,-.254,.826)
    # Inside the court a low raised basin has an actual empty center.
    g.ring(.035,-.042,.052,.117,.048,'sandstone',12,inner=.082)
    g.ring(.035,-.042,.055,.076,.004,'stone',12)


def _balcony(g,x,y,z,width=.246,projection=.114,angle=0):
    """Projecting open timber bay, with side depth, supports and thick roof."""
    def box(lx,ly,lz,w,d,h,mat='dark_wood'):
        _box_local(g,x,y,z,lx,ly,lz,w,d,h,mat,angle)
    box(0,-projection/2,0,width,projection,.025)
    box(0,-.005,.025,width*.74,.010,.133,'deep_shadow')
    for xx in (-width/2+.012,width/2-.012):
        for yy in (-projection+.012,-.018):
            box(xx,yy,.025,.024,.024,.141)
        box(xx,-projection/2,.070,.022,projection,.022)
    box(0,-projection+.012,.071,width,.024,.023)
    box(0,-projection+.012,.152,width,.026,.023)
    for xx in (-width*.17,width*.17):
        box(xx,-projection+.009,.093,.018,.022,.060)
    box(0,-projection*.49,.175,width+.044,projection+.055,.023)
    # Three stout roof battens make the upper surface read as timber as well.
    for xx in (-width*.29,0,width*.29):
        box(xx,-projection*.49,.198,.021,projection+.052,.012,'sandstone')
    c,s=math.cos(angle),math.sin(angle)
    def point(xx,yy,zz):
        return (x+xx*c-yy*s,y+xx*s+yy*c,z+zz)
    for xx in (-width*.31,width*.31):
        _beam(g,point(xx,-.014,-.077),point(xx,-projection*.82,-.006),.027)


def _tower_house(g,x,y,w,d,height,balcony_levels,side_balcony=False):
    # A small entry chamber is real: the lower body is not a filled box.
    clear=.140
    outer=clear*1.36
    side_width=(w-outer)/2
    for sign in (-1,1):
        g.box(x+sign*(outer/2+side_width/2),y,.035,
              side_width,d,.235,'cream')
    g.box(x,y+d/2-.021,.035,w,.042,.235,'cream')
    g.arch(x,y-d/2+.020,.035,clear,.201,.045,'sandstone',steps=8)
    g.box(x,y,.270,w,d,height-.235,'cream')
    g.box(x,y,.035+height,w+.027,d+.027,.025,'sandstone')
    _roof_rail(g,x,y,.060+height,w+.019,d+.019,.064,'cream',.030)
    for dx in (-w/2+.008,w/2-.008):
        for dy in (-d/2+.008,d/2-.008):
            g.box(x+dx,y+dy,.124+height,.051,.051,.031,'cream')
    for zz in balcony_levels:
        _balcony(g,x,y-d/2-.006,zz,w*.72,.119)
    if side_balcony:
        _balcony(g,x+w/2+.006,y,balcony_levels[-1],d*.69,.111,math.pi/2)
    # Broad single shutters sit between bays; no dense grids of tiny windows.
    for dx in (-w*.37,w*.37):
        g.box(x+dx,y-d/2-.007,.34,.039,.013,.111,'teal')


def jeddah(g):
    _base(g,1.8,1.4)
    # The winding empty alley narrows to 0.259 between the rear houses.
    g.box(-.025,-.05,.035,.202,1.08,.008,'sandstone')
    g.box(0,-.101,.035,1.21,.096,.008,'sandstone')
    _tower_house(g,-.448,.283,.418,.374,.816,(.324,.591),False)
    _tower_house(g,.208,.344,.376,.324,.930,(.321,.558,.797),True)
    _tower_house(g,-.474,-.337,.359,.327,.480,(.319,),False)
    _tower_house(g,.421,-.277,.383,.394,.646,(.324,.554),True)
    # A rooftop shade on the lower left house stays clear of the alley below.
    for dx in (-.137,.137):
        for dy in (-.112,.112):
            g.box(-.474+dx,-.337+dy,.540,.019,.019,.152,'dark_wood')
    _cloth(g,-.474,-.337,.673,.310,.260,.021,'cream',x_steps=4,y_steps=3)
    # Broad street steps preserve the main center passage rather than filling it.
    g.steps(-.475,-.556,.035,.147,.073,.017,2,'sandstone')
    g.steps(.421,-.509,.035,.149,.062,.017,2,'sandstone')


BUILDERS = {
    'yumenguan': yumenguan,
    'panti': panti,
    'baghdad': baghdad,
    'cairo': cairo,
    'jeddah': jeddah,
}

FEATURES = {
    'yumenguan': ['open perimeter-wall fortress court','true arched gate',
                  'open timber gatehouse with thick red eaves','side signal beacon',
                  'broad interior wall-walk stairs'],
    'panti': ['open caravan yard','roofed rear storage arcade','twin battered gate towers',
              'thick sagging cloth canopy','open well and timber lifting frame'],
    'baghdad': ['open circular enclosure','open rear blue-dome pavilion',
                'continuous external helical ramp attached to tapering core',
                'air-separated turns and open crown','real front city gate'],
    'cairo': ['open rectangular arcade court','unequal pointed minarets',
              'projecting timber balconies and open lanterns','small ivory rear dome',
              'tall open front gate'],
    'jeddah': ['four unequal white tower houses','deep supported timber bays',
               'empty winding alleys','open roof terraces','real entrance chambers'],
}
