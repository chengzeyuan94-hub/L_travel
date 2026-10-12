extends RefCounted
## Source-faithful procedural geometry from supplied src/math.js + src/app.js.
## Vertices use +Y up, +X east, -Z north. Colors are linear; faces are clockwise
## for Godot, with original outward normals retained. No global class registration.

static func _geo() -> Dictionary:
	return {"p": [], "n": [], "c": []}

static func _color(hex: String) -> Color:
	var color := Color(hex)
	# The source fragment shader uses gamma 2.2, rather than piecewise sRGB.
	return Color(pow(color.r, 2.2), pow(color.g, 2.2), pow(color.b, 2.2), 1.0)

static func _tri(g: Dictionary, a: Vector3, b: Vector3, c: Vector3, color: Color = Color.WHITE) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for vertex in [a, c, b]:
		g.p.append(vertex)
		g.n.append(normal)
		g.c.append(color)

static func _quad(g: Dictionary, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color = Color.WHITE) -> void:
	_tri(g, a, b, c, color)
	_tri(g, a, c, d, color)

static func _mesh(g: Dictionary) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(g.p)
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(g.n)
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray(g.c)
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result

static func _append(g: Dictionary, source: Dictionary, position: Vector3 = Vector3.ZERO, scale_value: Vector3 = Vector3.ONE, yaw: float = 0.0, color: Color = Color.WHITE) -> void:
	var rotation := Basis(Vector3.UP, yaw)
	for index in range(source.p.size()):
		g.p.append(position + rotation * (source.p[index] * scale_value))
		g.n.append((rotation * (source.n[index] / scale_value)).normalized())
		g.c.append(source.c[index] * color)

static func _cylinder(top: float = 1.0, bottom: float = 1.0, sides: int = 6) -> Dictionary:
	var g := _geo()
	for index in range(sides):
		var a := index * TAU / sides
		var b := (index + 1) * TAU / sides
		var p := Vector3(sin(a) * bottom, -0.5, cos(a) * bottom)
		var q := Vector3(sin(b) * bottom, -0.5, cos(b) * bottom)
		var r := Vector3(sin(b) * top, 0.5, cos(b) * top)
		var s := Vector3(sin(a) * top, 0.5, cos(a) * top)
		if top == 0.0:
			_tri(g, p, q, Vector3(0, 0.5, 0))
		else:
			_quad(g, p, q, r, s)
			_tri(g, Vector3(0, 0.5, 0), s, r)
		_tri(g, Vector3(0, -0.5, 0), q, p)
	return g

static func _ico() -> Dictionary:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var points := [Vector3(-1,t,0),Vector3(1,t,0),Vector3(-1,-t,0),Vector3(1,-t,0),Vector3(0,-1,t),Vector3(0,1,t),Vector3(0,-1,-t),Vector3(0,1,-t),Vector3(t,0,-1),Vector3(t,0,1),Vector3(-t,0,-1),Vector3(-t,0,1)]
	var faces := [[0,11,5],[0,5,1],[0,1,7],[0,7,10],[0,10,11],[1,5,9],[5,11,4],[11,10,2],[10,7,6],[7,1,8],[3,9,4],[3,4,2],[3,2,6],[3,6,8],[3,8,9],[4,9,5],[2,4,11],[6,2,10],[8,6,7],[9,8,1]]
	var g := _geo()
	for face in faces:
		_tri(g, points[face[0]].normalized(), points[face[1]].normalized(), points[face[2]].normalized())
	return g

static func low_tree(type: String) -> ArrayMesh:
	var g := _geo()
	var trunk := _color("#68513C")
	_append(g, _cylinder(), Vector3(0,0.48,0), Vector3(0.044,0.96,0.044), 0.0, trunk)
	var palettes := {
		"gold": ["#CFA852", "#B59343", "#DDC06F"],
		"copper": ["#B25B3C", "#C87546", "#D8965F"],
		"olive": ["#6C7850", "#849265", "#96A276"],
		"tropic": ["#436E4D", "#5F8553", "#7A985C"],
		"cypress": ["#345C47", "#446B4C", "#527850"],
		"sage": ["#75846E", "#91A184", "#A0AD8D"],
		"dry": ["#A6734D", "#BA945C", "#7F7551"]}
	var palette: Array = palettes.get(type, palettes.olive)
	if type == "cypress":
		for index in range(4):
			_append(g, _cylinder(0.0,1.0,7), Vector3(0,0.4+index*0.3,0), Vector3(0.36-index*0.055,0.72,0.36-index*0.055), 0.0, _color(palette[index % 3]))
	elif type == "palm":
		g = _geo()
		_append(g, _cylinder(), Vector3(0,0.80,0), Vector3(0.047,1.6,0.047), 0.03, trunk)
		for index in range(9):
			var a := index * 6.283 / 9.0
			var p := Vector3(0,1.62,0)
			var q := Vector3(cos(a)*0.47,1.78,sin(a)*0.47)
			var r := Vector3(cos(a)*0.82,1.52,sin(a)*0.82)
			var d := Vector3(-sin(a)*0.13,0,cos(a)*0.13)
			_tri(g, p, q+d, r, _color("#819553" if index % 2 else "#5F7C49"))
			_tri(g, p, r, q-d, _color("#A1AC65"))
	elif type == "dry" or type == "sage":
		g = _geo()
		for index in range(3):
			_append(g, _ico(), Vector3(sin(index*2.4)*0.22,0.17,cos(index*2.4)*0.18), Vector3(0.25,0.23,0.22), float(index), _color(palette[index]))
	else:
		for index in range(5):
			var a := index * 2.4
			_append(g, _ico(), Vector3(cos(a)*0.34,1.15+0.17*sin(index*1.7),sin(a)*0.31), Vector3(0.43,0.34,0.40), a, _color(palette[index % 3]))
		_append(g, _ico(), Vector3(0,1.5,0), Vector3(0.36,0.26,0.33), 0.5, _color(palette[2]))
	return _mesh(g)

static func rock_mesh(karst: bool = false) -> ArrayMesh:
	var g := _geo()
	_append(g, _ico(), Vector3(0,1.4 if karst else 0.21,0), Vector3(1,3.0 if karst else 0.65,0.8), 0.0, _color("#819086" if karst else "#9D9989"))
	return _mesh(g)

static func grass_mesh() -> ArrayMesh:
	var g := _geo()
	for index in range(7):
		var a := index * 2.4
		var dx := sin(a) * 0.14
		var dz := cos(a) * 0.14
		_tri(g, Vector3(dx-0.04,0,dz), Vector3(dx+0.04,0,dz), Vector3(dx+0.1,0.72+sin(index)*0.2,dz+0.1), _color("#C5B885"))
	return _mesh(g)

static func _slab_ring(width: float, depth: float, y: float, bevel: float) -> Array:
	return [Vector3(-width/2+bevel,y,-depth/2),Vector3(width/2-bevel,y,-depth/2),Vector3(width/2,y,-depth/2+bevel),Vector3(width/2,y,depth/2-bevel),Vector3(width/2-bevel,y,depth/2),Vector3(-width/2+bevel,y,depth/2),Vector3(-width/2,y,depth/2-bevel),Vector3(-width/2,y,-depth/2+bevel)]

static func slab(width: float, depth: float, height: float, bevel: float = 0.13) -> ArrayMesh:
	var g := _geo()
	var top := _slab_ring(width,depth,height/2,bevel)
	var bottom := _slab_ring(width,depth,-height/2,bevel)
	for index in range(8):
		var next := (index + 1) % 8
		_tri(g, Vector3(0,height/2,0), top[next], top[index])
		_tri(g, Vector3(0,-height/2,0), bottom[index], bottom[next])
		_quad(g, bottom[index], top[index], top[next], bottom[next])
	return _mesh(g)

static func boat_mesh() -> ArrayMesh:
	var g := _geo()
	_append(g, _ico(), Vector3(0,0.11,0), Vector3(0.55,0.18,0.20), 0.0, _color("#84613D"))
	_append(g, _cylinder(), Vector3(0,0.58,0), Vector3(0.022,0.94,0.022), 0.0, _color("#7B6243"))
	_tri(g, Vector3(0,0.25,0), Vector3(0,1.06,0), Vector3(0.48,0.39,0), _color("#F0E2B7"))
	_tri(g, Vector3(0,0.29,0), Vector3(-0.37,0.48,0), Vector3(0,0.94,0), _color("#DACA9C"))
	_tri(g, Vector3(0,1.03,0), Vector3(0.18,1.02,0), Vector3(0,1.14,0), _color("#AE6249"))
	return _mesh(g)
