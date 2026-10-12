extends RefCounted
## Editable miniature props, generated directly from deliberately shaped meshes.
## Ground is y=0. Boats/camels face -Z. Bridges run along X; docks along Z.
## Each returned tree has a repeatable seed; no frame callbacks or external assets.

static var _materials: Dictionary = {}

static func _mat(hex: String, roughness: float = 0.85) -> StandardMaterial3D:
	var key := hex + str(roughness)
	if _materials.has(key):
		return _materials[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(hex)
	m.roughness = roughness
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials[key] = m
	return m

static func _box(p: Node3D, pos: Vector3, size: Vector3, color: String) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	n.mesh = mesh
	n.material_override = _mat(color)
	n.position = pos
	p.add_child(n)
	return n

static func _tube(p: Node3D, a: Vector3, b: Vector3, radius: float, color: String, end_radius: float = -1.0, sides: int = 8) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if end_radius < 0.0 else end_radius
	mesh.height = a.distance_to(b)
	mesh.radial_segments = sides
	n.mesh = mesh
	n.material_override = _mat(color)
	n.position = (a + b) * 0.5
	var up := (b - a).normalized()
	var reference := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.96 else Vector3.RIGHT
	var right := up.cross(reference).normalized()
	n.basis = Basis(right, up, right.cross(up).normalized())
	p.add_child(n)
	return n

static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for v in [a, c, b]:
		st.set_normal(normal)
		st.add_vertex(v)

static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(st, a, b, c)
	_tri(st, a, c, d)

static func _surface(p: Node3D, st: SurfaceTool, color: String) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.mesh = st.commit()
	n.material_override = _mat(color)
	p.add_child(n)
	return n

static func _ellipsoid(p: Node3D, pos: Vector3, size: Vector3, color: String, seed_value: int = 1, sides: int = 9, rows: int = 6, irregular: float = 0.0) -> MeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var rings: Array[PackedVector3Array] = []
	for j in range(rows + 1):
		var ring := PackedVector3Array()
		var theta := PI * float(j) / float(rows)
		for i in range(sides):
			var phi := TAU * float(i) / float(sides) + (0.16 if j % 2 == 1 else 0.0)
			var r := 1.0 + rng.randf_range(-irregular, irregular)
			ring.append(Vector3(sin(theta) * cos(phi) * size.x * r, cos(theta) * size.y, sin(theta) * sin(phi) * size.z * r))
		rings.append(ring)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(rows):
		for i in range(sides):
			var k := (i + 1) % sides
			if j != 0:
				_tri(st, rings[j][i], rings[j][k], rings[j + 1][i])
			if j != rows - 1:
				_tri(st, rings[j][k], rings[j + 1][k], rings[j + 1][i])
	var result := _surface(p, st, color)
	result.position = pos
	return result

static func _crown(p: Node3D, base: Vector3, height: float, radius: float, color: String, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var profile := [Vector2(0.0, 0.54), Vector2(0.11, 1.0), Vector2(0.47, 0.76), Vector2(0.73, 0.43), Vector2(1.0, 0.01)]
	var rings: Array[PackedVector3Array] = []
	var shift := rng.randf_range(0.0, TAU)
	for level: Vector2 in profile:
		var ring := PackedVector3Array()
		for i in range(7):
			var angle := TAU * float(i) / 7.0 + shift
			var r := radius * level.y * rng.randf_range(0.92, 1.08)
			ring.append(base + Vector3(cos(angle) * r, level.x * height, sin(angle) * r))
		rings.append(ring)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(rings.size() - 1):
		for i in range(7):
			var k := (i + 1) % 7
			_quad(st, rings[j][i], rings[j + 1][i], rings[j + 1][k], rings[j][k])
	_surface(p, st, color)

static func tree(kind: String, seed_value: int = 1) -> Node3D:
	var root := Node3D.new()
	root.name = "Tree_" + kind
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var lean := rng.randf_range(-0.07, 0.07)
	if kind == "palm":
		var points := [Vector3.ZERO, Vector3(0.035, 0.48, 0.0), Vector3(0.11, 0.95, lean), Vector3(0.17, 1.47, lean)]
		for i in range(3):
			_tube(root, points[i], points[i + 1], 0.067 - float(i) * 0.009, "99734b", 0.052 - float(i) * 0.008, 7)
		for j in range(9):
			var angle := TAU * float(j) / 9.0 + rng.randf_range(-0.15, 0.15)
			var direction := Vector3(cos(angle), 0.0, sin(angle))
			var side := Vector3(-sin(angle), 0.0, cos(angle))
			var origin: Vector3 = points[3]
			var mid := origin + direction * 0.40 + Vector3.UP * (0.25 if j % 3 else 0.33)
			var tip := origin + direction * rng.randf_range(0.72, 0.85) - Vector3.UP * 0.06
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			_tri(st, origin, mid + side * 0.135, mid + Vector3.UP * 0.048)
			_tri(st, origin, mid + Vector3.UP * 0.048, mid - side * 0.135)
			_tri(st, mid + side * 0.135, tip, mid + Vector3.UP * 0.048)
			_tri(st, mid + Vector3.UP * 0.048, tip, mid - side * 0.135)
			_surface(root, st, ["3f774d", "527f43", "65934a"][j % 3])
		for j in range(3):
			_ellipsoid(root, points[3] + Vector3(0.075 * cos(float(j) * 2.1), -0.065, 0.075 * sin(float(j) * 2.1)), Vector3(0.062, 0.07, 0.062), "765939", seed_value + j, 6, 4)
	elif kind == "conifer" or kind == "pine":
		_tube(root, Vector3.ZERO, Vector3(lean, 1.18, 0.0), 0.065, "755539", 0.024, 7)
		_crown(root, Vector3(0.0, 0.27, 0.0), 0.89, 0.40, "376b54", seed_value)
		_crown(root, Vector3(lean * 0.5, 0.69, 0.0), 0.72, 0.32, "447f59", seed_value + 5)
		_crown(root, Vector3(lean, 1.06, 0.0), 0.59, 0.21, "58915d", seed_value + 11)
	elif kind == "bush":
		for j in range(4):
			var angle := float(j) * 2.3
			_ellipsoid(root, Vector3(cos(angle) * 0.15, 0.20 + float(j % 2) * 0.07, sin(angle) * 0.13), Vector3(0.22, 0.24, 0.23), ["688645", "7b994c", "527b47"][j % 3], seed_value + j, 7, 5, 0.12)
	else:
		var blossom := kind == "blossom"
		_tube(root, Vector3.ZERO, Vector3(lean, 0.92, 0.0), 0.077, "79583c", 0.028, 7)
		for j in range(5):
			var angle := float(j) * 2.4
			var point := Vector3(cos(angle) * 0.25 + lean, 0.89 + float(j % 3) * 0.10, sin(angle) * 0.24)
			_tube(root, Vector3(lean, 0.51, 0.0), point, 0.026, "79583c", 0.016, 5)
			var color: String = ["cc86a0", "e6a6ad", "f0bdb7"][j % 3] if blossom else ["789548", "94a855", "658849"][j % 3]
			_ellipsoid(root, point, Vector3(0.31, 0.34, 0.31) if blossom else Vector3(0.35, 0.38, 0.34), color, seed_value + j, 8, 5, 0.10)
	return root

static func _sail_point(u: float, v: float, junk: bool, small: bool = false) -> Vector3:
	var width := lerpf(0.56, 0.41, v)
	if junk:
		width = lerpf(0.54, 0.30, v)
	var pos := Vector3((u - 0.5) * 2.0 * width, 0.52 + v * 1.01, 0.015 + sin(u * PI) * sin(v * PI) * 0.19)
	if small:
		pos = Vector3(pos.x * 0.61, 0.46 + v * 0.71, -0.51 + (pos.z - 0.015) * 0.7)
	return pos

static func _sail(p: Node3D, junk: bool, small: bool = false) -> void:
	for row in range(6):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for column in range(5):
			var u0 := float(column) / 5.0
			var u1 := float(column + 1) / 5.0
			var v0 := float(row) / 6.0
			var v1 := float(row + 1) / 6.0
			_quad(st, _sail_point(u0, v0, junk, small), _sail_point(u1, v0, junk, small), _sail_point(u1, v1, junk, small), _sail_point(u0, v1, junk, small))
		_surface(p, st, (["be6541", "d27b4c"][row % 2] if junk else ["f5e8c9", "ebdbb5"][row % 2]))
	if junk:
		for row in range(7):
			var v := float(row) / 6.0
			for i in range(4):
				_tube(p, _sail_point(float(i) / 4.0, v, junk, small), _sail_point(float(i + 1) / 4.0, v, junk, small), 0.008, "794f32", -1.0, 5)
	for edge in [0.0, 1.0]:
		for row in range(6):
			_tube(p, _sail_point(edge, float(row) / 6.0, junk, small), _sail_point(edge, float(row + 1) / 6.0, junk, small), 0.007, "96794b", -1.0, 5)

static func boat(junk: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "SilkJunk" if junk else "TradeDhow"
	var stations := [Vector3(0.0, 0.34, -0.97), Vector3(0.17, 0.28, -0.73), Vector3(0.31, 0.25, -0.35), Vector3(0.33, 0.26, 0.19), Vector3(0.27, 0.30, 0.68), Vector3(0.16, 0.35, 0.87)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(stations.size() - 1):
		var a: Vector3 = stations[i]
		var b: Vector3 = stations[i + 1]
		for sign_value in [-1.0, 1.0]:
			_quad(st, Vector3(a.x * sign_value, a.y, a.z), Vector3(b.x * sign_value, b.y, b.z), Vector3(b.x * 0.68 * sign_value, 0.075, b.z), Vector3(a.x * 0.68 * sign_value, 0.075, a.z))
			_quad(st, Vector3(a.x * 0.68 * sign_value, 0.075, a.z), Vector3(b.x * 0.68 * sign_value, 0.075, b.z), Vector3(0.0, 0.015, b.z), Vector3(0.0, 0.015, a.z))
			_tube(root, Vector3(a.x * sign_value, a.y + 0.027, a.z), Vector3(b.x * sign_value, b.y + 0.027, b.z), 0.026, "d2a269", -1.0, 6)
			_tube(root, Vector3(a.x * 0.9 * sign_value, a.y * 0.58, a.z), Vector3(b.x * 0.9 * sign_value, b.y * 0.58, b.z), 0.015, "4d7773" if junk else "714629", -1.0, 5)
	_surface(root, st, "986441")
	var deck := SurfaceTool.new()
	deck.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(stations.size() - 1):
		var a: Vector3 = stations[i]
		var b: Vector3 = stations[i + 1]
		_quad(deck, Vector3(-a.x * 0.91, a.y - 0.038, a.z), Vector3(-b.x * 0.91, b.y - 0.038, b.z), Vector3(b.x * 0.91, b.y - 0.038, b.z), Vector3(a.x * 0.91, a.y - 0.038, a.z))
	_surface(root, deck, "c69b66")
	_box(root, Vector3(0.0, 0.28, 0.40), Vector3(0.49, 0.04, 0.10), "775132")
	_box(root, Vector3(0.0, 0.30, -0.42), Vector3(0.45, 0.05, 0.09), "775132")
	_tube(root, Vector3(0.0, 0.21, 0.02), Vector3(0.0, 1.69, 0.02), 0.027, "725033", 0.016, 7)
	_tube(root, Vector3(-0.47, 1.54, 0.01), Vector3(0.47, 1.54, 0.01), 0.018, "795735", -1.0, 6)
	_sail(root, junk)
	if junk:
		_tube(root, Vector3(0.0, 0.28, -0.51), Vector3(0.0, 1.28, -0.51), 0.02, "725033", 0.013, 6)
		_sail(root, true, true)
	else:
		var fore := SurfaceTool.new()
		fore.begin(Mesh.PRIMITIVE_TRIANGLES)
		_tri(fore, Vector3(0.0, 1.45, 0.0), Vector3(0.0, 0.44, -1.11), Vector3(-0.19, 0.53, -0.11))
		_surface(root, fore, "efe3c6")
	_tube(root, Vector3(0.0, 0.33, -0.8), Vector3(0.0, 0.48, -1.17), 0.02, "795735", 0.011, 6)
	_tube(root, Vector3(0.0, 1.64, 0.02), Vector3(0.0, 0.48, -1.17), 0.005, "6e6248", -1.0, 4)
	for side in [-1.0, 1.0]:
		_tube(root, Vector3(0.0, 1.62, 0.02), Vector3(side * 0.25, 0.32, 0.68), 0.005, "6e6248", -1.0, 4)
	_box(root, Vector3(0.13, 0.35, 0.52), Vector3(0.16, 0.18, 0.20), "a85f3f")
	_box(root, Vector3(-0.09, 0.34, 0.57), Vector3(0.18, 0.15, 0.20), "697f61")
	_box(root, Vector3(0.0, 0.28, 0.91), Vector3(0.05, 0.26, 0.15), "765037")
	return root

static func camel(seed_value: int = 1) -> Node3D:
	var root := Node3D.new()
	root.name = "BactrianCaravanCamel"
	var skin := "bd8955" if seed_value % 2 else "ca9a64"
	var dark := "8e653d"
	_ellipsoid(root, Vector3(0.0, 0.44, 0.06), Vector3(0.18, 0.175, 0.34), skin, seed_value, 10, 7)
	for z in [-0.105, 0.21]:
		_ellipsoid(root, Vector3(0.0, 0.58, z), Vector3(0.125, 0.16, 0.13), skin, seed_value + 2, 8, 5)
	for x in [-0.11, 0.11]:
		for z in [-0.17, 0.27]:
			var step := 0.04 if (x > 0.0) == (z > 0.0) else -0.04
			var hip := Vector3(x, 0.43, z)
			var knee := Vector3(x * 1.08, 0.20, z + step)
			var foot := Vector3(x * 1.15, 0.033, z - step * 0.65)
			_tube(root, hip, knee, 0.044, skin, 0.029, 7)
			_ellipsoid(root, knee, Vector3(0.038, 0.043, 0.038), dark, seed_value, 7, 4)
			_tube(root, knee, foot, 0.025, skin, 0.025, 6)
			_ellipsoid(root, foot + Vector3(0.0, -0.011, -0.015), Vector3(0.043, 0.027, 0.061), dark, seed_value, 7, 4)
	_tube(root, Vector3(0.0, 0.42, -0.21), Vector3(0.0, 0.56, -0.41), 0.095, skin, 0.065, 8)
	_tube(root, Vector3(0.0, 0.55, -0.40), Vector3(0.0, 0.86, -0.46), 0.065, skin, 0.047, 8)
	_ellipsoid(root, Vector3(0.0, 0.86, -0.49), Vector3(0.071, 0.08, 0.117), skin, seed_value, 8, 5)
	_ellipsoid(root, Vector3(0.0, 0.837, -0.58), Vector3(0.064, 0.048, 0.079), "aa794c", seed_value, 8, 4)
	for x in [-0.074, 0.074]:
		var ear := _ellipsoid(root, Vector3(x, 0.92, -0.452), Vector3(0.028, 0.06, 0.034), skin, seed_value, 6, 4)
		ear.rotate_z(-signf(x) * 0.35)
		_ellipsoid(root, Vector3(x * 0.87, 0.886, -0.52), Vector3(0.009, 0.012, 0.012), "302b28", seed_value, 6, 4)
	_tube(root, Vector3(0.0, 0.46, 0.35), Vector3(0.015, 0.20, 0.46), 0.021, skin, 0.012, 6)
	_ellipsoid(root, Vector3(0.015, 0.18, 0.46), Vector3(0.025, 0.05, 0.025), dark, seed_value, 6, 4)
	var rug_color := "437f83" if seed_value % 2 else "ab543d"
	_box(root, Vector3(0.0, 0.574, 0.063), Vector3(0.365, 0.043, 0.22), rug_color)
	for x in [-0.19, 0.19]:
		_box(root, Vector3(x, 0.475, 0.062), Vector3(0.03, 0.20, 0.25), rug_color)
		_box(root, Vector3(x * 1.04, 0.381, 0.062), Vector3(0.035, 0.035, 0.26), "e4c487")
		_box(root, Vector3(x * 1.06, 0.50, 0.063), Vector3(0.16, 0.14, 0.18), "c2a375")
		_box(root, Vector3(x * 1.065, 0.50, 0.063), Vector3(0.165, 0.025, 0.187), "765b3b")
	_tube(root, Vector3(-0.063, 0.85, -0.59), Vector3(0.063, 0.85, -0.59), 0.009, "635540", -1.0, 5)
	return root

static func _jar(p: Node3D, pos: Vector3, radius: float, color: String) -> void:
	_ellipsoid(p, pos + Vector3.UP * radius * 0.9, Vector3(radius, radius * 1.13, radius), color, 17, 9, 6)
	_tube(p, pos + Vector3.UP * radius * 1.7, pos + Vector3.UP * radius * 2.12, radius * 0.43, color, radius * 0.48, 9)
	_tube(p, pos + Vector3.UP * radius * 2.13, pos + Vector3.UP * radius * 2.15, radius * 0.32, "594438", -1.0, 9)

static func _crate(p: Node3D, pos: Vector3, size: Vector3) -> void:
	_box(p, pos + Vector3.UP * size.y * 0.5, size, "b68b55")
	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			_box(p, pos + Vector3(x * size.x * 0.45, size.y * 0.5, z * size.z * 0.45), Vector3(0.025, size.y + 0.01, 0.025), "785735")
	for y in [0.025, size.y - 0.025]:
		_box(p, pos + Vector3(0.0, y, 0.0), Vector3(size.x + 0.015, 0.024, size.z + 0.015), "97703f")

static func market(seed_value: int = 1) -> Node3D:
	var root := Node3D.new()
	root.name = "CaravanMarket"
	var accent := "bc6044" if seed_value % 2 else "477f83"
	for x in [-0.48, 0.48]:
		for z in [-0.32, 0.32]:
			_tube(root, Vector3(x, 0.0, z), Vector3(x, 0.84, z), 0.025, "89653f", 0.02, 6)
		_tube(root, Vector3(x, 0.86, -0.40), Vector3(x, 0.86, 0.40), 0.025, "89653f", -1.0, 6)
	_tube(root, Vector3(-0.58, 1.025, 0.0), Vector3(0.58, 1.025, 0.0), 0.027, "89653f", -1.0, 6)
	for i in range(7):
		var x0 := -0.58 + float(i) * 1.16 / 7.0
		var x1 := -0.58 + float(i + 1) * 1.16 / 7.0
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for side in [-1.0, 1.0]:
			_quad(st, Vector3(x0, 1.02, 0.0), Vector3(x1, 1.02, 0.0), Vector3(x1, 0.85, side * 0.40), Vector3(x0, 0.85, side * 0.40))
			_quad(st, Vector3(x0, 0.85, side * 0.40), Vector3(x1, 0.85, side * 0.40), Vector3(x1, 0.74, side * 0.405), Vector3(x0, 0.74, side * 0.405))
		_surface(root, st, accent if i % 2 == 0 else "efddb7")
	_box(root, Vector3(0.0, 0.20, 0.19), Vector3(0.89, 0.34, 0.25), "b08754")
	_box(root, Vector3(0.0, 0.386, 0.19), Vector3(0.94, 0.025, 0.28), "d4b27a")
	for i in range(4):
		_ellipsoid(root, Vector3(-0.30 + float(i) * 0.19, 0.43, 0.16), Vector3(0.08, 0.04, 0.07), ["e1ad48", "a9523d", "829553", "d1b986"][i], i, 7, 4)
	_jar(root, Vector3(0.65, 0.0, 0.12), 0.11, "b86d49")
	_jar(root, Vector3(0.76, 0.0, -0.10), 0.075, "688c85")
	_crate(root, Vector3(-0.62, 0.0, -0.08), Vector3(0.25, 0.25, 0.25))
	_crate(root, Vector3(-0.64, 0.25, -0.08), Vector3(0.21, 0.18, 0.20))
	_box(root, Vector3(0.04, 0.012, -0.43), Vector3(0.64, 0.017, 0.27), accent)
	for z in [-0.54, -0.32]:
		_box(root, Vector3(0.04, 0.023, z), Vector3(0.63, 0.007, 0.025), "e5c494")
	_tube(root, Vector3(0.31, 0.075, -0.47), Vector3(0.31, 0.075, -0.19), 0.065, "cfb284", -1.0, 9)
	return root

static func bridge(length: float = 2.0) -> Node3D:
	var root := Node3D.new()
	root.name = "ArchedTradeBridge"
	var count := maxi(8, int(length / 0.13))
	for i in range(count):
		var t := (float(i) + 0.5) / float(count)
		var x := (t - 0.5) * length
		var y := 0.08 + sin(t * PI) * 0.19
		var plank := _box(root, Vector3(x, y, 0.0), Vector3(length / float(count) * 0.96, 0.075, 0.72), "b9925b" if i % 3 else "c6a16a")
		plank.rotation.z = atan(cos(t * PI) * PI * 0.19 / length)
	var posts := maxi(4, int(length / 0.40))
	for side in [-1.0, 1.0]:
		for i in range(posts + 1):
			var t := float(i) / float(posts)
			var point := Vector3((t - 0.5) * length, 0.08 + sin(t * PI) * 0.19, side * 0.34)
			_tube(root, point - Vector3.UP * 0.08, point + Vector3.UP * 0.39, 0.032, "886843", 0.027, 6)
			if i < posts:
				var t2 := float(i + 1) / float(posts)
				var point2 := Vector3((t2 - 0.5) * length, 0.08 + sin(t2 * PI) * 0.19, side * 0.34)
				_tube(root, point + Vector3.UP * 0.31, point2 + Vector3.UP * 0.31, 0.023, "a9814e", -1.0, 6)
		for t in [0.17, 0.83]:
			_tube(root, Vector3((t - 0.5) * length, -0.22, side * 0.26), Vector3((t - 0.5) * length, 0.21, side * 0.26), 0.055, "856644", 0.047, 7)
	return root

static func dock(length: float = 2.0) -> Node3D:
	var root := Node3D.new()
	root.name = "TradeLandingDock"
	var count := maxi(8, int(length / 0.14))
	for i in range(count):
		_box(root, Vector3(0.0, 0.15, (float(i) + 0.5) / float(count) * length), Vector3(0.78, 0.065, length / float(count) * 0.94), "b99460" if i % 3 else "c4a270")
	for z in [0.10, length * 0.5, length - 0.07]:
		for x in [-0.33, 0.33]:
			_tube(root, Vector3(x, -0.36, z), Vector3(x, 0.40, z), 0.054, "896841", 0.047, 7)
			_tube(root, Vector3(x, 0.34, z), Vector3(x, 0.37, z), 0.065, "b49b6f", -1.0, 8)
	for x in [-0.27, 0.27]:
		_box(root, Vector3(x, 0.07, length * 0.5), Vector3(0.08, 0.11, length), "88633e")
	_crate(root, Vector3(-0.19, 0.19, length * 0.72), Vector3(0.25, 0.24, 0.25))
	_jar(root, Vector3(0.21, 0.19, length * 0.35), 0.09, "a76447")
	return root
