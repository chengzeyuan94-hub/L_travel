extends RefCounted
## Small, authored silhouettes, combined into a single vertex-colour surface.
## UV.x identifies an articulated part; UV.y is cloth distance from its pole.

class Builder:
	var surface := SurfaceTool.new()
	func _init() -> void:
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	func tri(a: Vector3, b: Vector3, c: Vector3, color: Color, part: float = 0.0) -> void:
		var normal := (b - a).cross(c - a).normalized()
		for point in [a, c, b]:
			surface.set_normal(normal)
			surface.set_color(color)
			surface.set_uv(Vector2(part, maxf(point.x, 0.0)))
			surface.add_vertex(point)
	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color, part: float = 0.0) -> void:
		tri(a, b, c, color, part)
		tri(a, c, d, color, part)
	func box(center: Vector3, size: Vector3, color: Color, part: float = 0.0) -> void:
		var p: Array[Vector3] = []
		for y in [-1, 1]:
			for z in [-1, 1]:
				for x in [-1, 1]:
					p.append(center + Vector3(x, y, z) * size * 0.5)
		for f in [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]:
			quad(p[f[0]], p[f[1]], p[f[2]], p[f[3]], color, part)
	func ico(center: Vector3, radii: Vector3, color: Color, part: float = 0.0) -> void:
		var g := (1.0 + sqrt(5.0)) * 0.5
		var p := [Vector3(-1,g,0),Vector3(1,g,0),Vector3(-1,-g,0),Vector3(1,-g,0),Vector3(0,-1,g),Vector3(0,1,g),Vector3(0,-1,-g),Vector3(0,1,-g),Vector3(g,0,-1),Vector3(g,0,1),Vector3(-g,0,-1),Vector3(-g,0,1)]
		for i in p.size():
			p[i] = center + (p[i] as Vector3).normalized() * radii
		for f in [[0,11,5],[0,5,1],[0,1,7],[0,7,10],[0,10,11],[1,5,9],[5,11,4],[11,10,2],[10,7,6],[7,1,8],[3,9,4],[3,4,2],[3,2,6],[3,6,8],[3,8,9],[4,9,5],[2,4,11],[6,2,10],[8,6,7],[9,8,1]]:
			tri(p[f[0]], p[f[1]], p[f[2]], color, part)
	func cone(center: Vector3, radius: float, height: float, color: Color, sides: int = 6, top: float = 0.0, part: float = 0.0) -> void:
		for i in sides:
			var aa := TAU * i / sides
			var bb := TAU * (i + 1) / sides
			var a := center + Vector3(cos(aa)*radius, 0, sin(aa)*radius)
			var b := center + Vector3(cos(bb)*radius, 0, sin(bb)*radius)
			var c := center + Vector3(cos(bb)*top, height, sin(bb)*top)
			var d := center + Vector3(cos(aa)*top, height, sin(aa)*top)
			quad(a, b, c, d, color, part)
			tri(center, b, a, color, part)
			if top > 0:
				tri(center + Vector3.UP*height, d, c, color, part)
	func finish() -> ArrayMesh:
		return surface.commit()


static func cloud(rain: bool = false) -> ArrayMesh:
	var b := Builder.new()
	var color := Color("b4c8c4") if rain else Color("eef1db")
	b.ico(Vector3(-.35,-.015,0), Vector3(.34,.16,.25), color.darkened(.035))
	b.ico(Vector3(.01,.08,.03), Vector3(.40,.24,.29), color)
	b.ico(Vector3(.40,0,-.02), Vector3(.31,.17,.24), color.darkened(.025))
	b.ico(Vector3(.13,-.03,-.25), Vector3(.34,.14,.24), Color("819fa8") if rain else color.darkened(.08))
	if rain:
		b.ico(Vector3(-.2,-.1,-.12), Vector3(.32,.12,.23), Color("718e9a"))
	return b.finish()


static func gull() -> ArrayMesh:
	var b := Builder.new()
	var white := Color("eee9d5")
	b.ico(Vector3(0,.02,0), Vector3(.04,.045,.115), white)
	# Two tapered, bent wings, with dark primary feathers at the tips.
	for side in [-1.0, 1.0]:
		var part := 1.0 if side < 0 else 2.0
		b.tri(Vector3(side*.025,.025,-.055), Vector3(side*.21,.07,.01), Vector3(side*.07,.025,.06), white, part)
		b.tri(Vector3(side*.21,.07,.01), Vector3(side*.34,.015,.09), Vector3(side*.17,.045,.075), Color("65747b"), part)
		b.tri(Vector3(0,.025,.09),Vector3(side*.055,.015,.17),Vector3(0,.005,.14),white)
	b.tri(Vector3(-.018,.015,-.105),Vector3(0,.015,-.17),Vector3(.018,.015,-.105),Color("c89a55"))
	return b.finish()


static func sheep() -> ArrayMesh:
	var b := Builder.new()
	var wool := Color("e5dfc9")
	b.ico(Vector3(0,.18,0), Vector3(.14,.13,.23), wool)
	for p in [Vector3(-.065,.27,-.085),Vector3(.060,.275,-.035),Vector3(-.035,.275,.075),Vector3(.050,.26,.145)]:
		b.ico(p,Vector3(.073,.064,.078),wool.lightened(.025))
	b.ico(Vector3(0,.205,-.23), Vector3(.068,.075,.09), Color("655b4a"), 1)
	for x in [-.08,.08]:
		for z in [-.125,.125]:
			var p := Vector3(x,.12,z)
			b.tri(p+Vector3(-.025,0,-.02),p+Vector3(.025,0,-.02),p+Vector3(0,-.12,0),Color("594e42"))
			b.tri(p+Vector3(.025,0,-.02),p+Vector3(0,0,.025),p+Vector3(0,-.12,0),Color("594e42"))
			b.tri(p+Vector3(0,0,.025),p+Vector3(-.025,0,-.02),p+Vector3(0,-.12,0),Color("594e42"))
	for side in [-1.0,1.0]:
		b.tri(Vector3(side*.04,.235,-.22),Vector3(side*.12,.255,-.19),Vector3(side*.075,.20,-.225),wool,1)
	return b.finish()


static func whale() -> ArrayMesh:
	var b := Builder.new()
	var blue := Color("528fa9")
	b.ico(Vector3(0,.025,-.07),Vector3(.19,.14,.47),blue)
	# Pale, wider lower flanks remain legible beside the blue back at map scale.
	b.ico(Vector3(0,-.012,-.12),Vector3(.198,.080,.36),Color("bad9db"))
	for side in [-1.0,1.0]:
		b.tri(Vector3(side*.13,.015,-.1),Vector3(side*.36,-.01,.14),Vector3(side*.12,-.03,.1),blue.darkened(.12))
		b.tri(Vector3(0,.015,.36),Vector3(side*.28,.02,.52),Vector3(side*.15,.055,.63),blue,1)
		b.tri(Vector3(0,.015,.36),Vector3(side*.15,.055,.63),Vector3(0,.055,.53),blue,1)
	b.tri(Vector3(0,.11,-.01),Vector3(0,.27,.17),Vector3(0,.10,.21),blue.darkened(.1))
	return b.finish()


static func boat() -> ArrayMesh:
	var b := Builder.new()
	# Curved six-station hull: raised bow/stern, open gunwale, pale small sail.
	var stations := [[-.34,.012,.07],[-.23,.095,.0],[0.0,.12,-.012],[.23,.09,.0],[.33,.014,.075]]
	for i in range(stations.size()-1):
		var a: Array = stations[i]
		var c: Array = stations[i+1]
		for side in [-1.0,1.0]:
			b.quad(Vector3(side*a[1],a[2],a[0]),Vector3(0,-.085,a[0]),Vector3(0,-.085,c[0]),Vector3(side*c[1],c[2],c[0]),Color("946f43"))
			b.quad(Vector3(side*a[1],a[2],a[0]),Vector3(side*c[1],c[2],c[0]),Vector3(side*c[1]*.86,c[2]-.027,c[0]),Vector3(side*a[1]*.86,a[2]-.027,a[0]),Color("d0a66e"))
	b.box(Vector3(0,-.014,.02),Vector3(.16,.025,.41),Color("755838"))
	b.cone(Vector3(0,-.01,-.02),.011,.48,Color("65513a"),5,.008)
	for z in [-.18,.16]:
		b.box(Vector3(0,.02,z),Vector3(.19,.02,.035),Color("b2915d"))
	# A triangular lateen sail with a bent leech; neutral, unlike player vessels.
	b.tri(Vector3(0,.45,-.04),Vector3(.022,.105,-.25),Vector3(.048,.18,.17),Color("d9d0ae"),1)
	b.tri(Vector3(0,.45,-.04),Vector3(.048,.18,.17),Vector3(0,.14,.23),Color("eee4c8"),1)
	b.box(Vector3(-.045,.022,.095),Vector3(.05,.045,.07),Color("ac9871"))
	return b.finish()


static func ice() -> ArrayMesh:
	var b := Builder.new()
	var points: Array[Vector3] = []
	for i in 6:
		var a := i*TAU/6
		points.append(Vector3(cos(a)*(.34 if i%2==0 else .27), .035 + .013*sin(i*2.0), sin(a)*.24))
	for i in 6:
		var j := (i+1)%6
		b.tri(Vector3(0,.042,0),points[i],points[j],Color("d8e7df"))
		b.quad(points[i],Vector3(points[i].x,-.012,points[i].z),Vector3(points[j].x,-.012,points[j].z),points[j],Color("8bbcc6"))
	return b.finish()


static func flag() -> ArrayMesh:
	var b := Builder.new()
	b.cone(Vector3.ZERO,.035,.07,Color("b3a27d"),6,.024)
	b.cone(Vector3(0,.04,0),.013,.64,Color("695238"),5,.008)
	b.ico(Vector3(0,.70,0),Vector3(.025,.03,.025),Color("c0a46b"))
	for i in 4:
		var x0 := .015+i*.062
		var x1 := x0+.062
		var drop := .025 if i==3 else 0.0
		b.quad(Vector3(x0,.62,0),Vector3(x0,.41,0),Vector3(x1,.41+drop,0),Vector3(x1,.62,0),Color("b69458") if i==0 else Color("766759"),1)
	return b.finish()


static func windmill(rotor: bool) -> ArrayMesh:
	var b := Builder.new()
	if rotor:
		b.cone(Vector3(0,0,0),.021,.48,Color("65513c"),6,.018)
		for i in 4:
			var angle := i*PI*.5
			var dir := Vector3(cos(angle),0,sin(angle))
			var across := Vector3(-sin(angle),0,cos(angle))
			var c := dir*.16
			b.quad(c-across*.12,c+across*.12,c+across*.12+Vector3.UP*.43,c-across*.12+Vector3.UP*.43,Color("c2aa7d"))
	else:
		b.cone(Vector3.ZERO,.30,.11,Color("a38a62"),7,.27)
		# Two earthen wind-catching walls frame a visible vertical rotor.
		b.box(Vector3(-.25,.31,.02),Vector3(.13,.50,.49),Color("bca376"))
		b.box(Vector3(.25,.31,.02),Vector3(.13,.50,.49),Color("cdb488"))
		b.box(Vector3(0,.12,.20),Vector3(.53,.11,.10),Color("9a8159"))
		b.box(Vector3(0,.63,.02),Vector3(.64,.07,.14),Color("7b6142"))
		for x in [-.25,.25]:
			b.box(Vector3(x,.56,-.2),Vector3(.15,.12,.1),Color("d4bd90"))
	return b.finish()
