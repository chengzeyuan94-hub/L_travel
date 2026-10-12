class_name MiniworldArchitecture
extends RefCounted
## Editable miniature architecture. Dimensions are metres, with the entrance toward +Z.
## The generated hierarchy is deliberate: main landmark, secondary volumes, a doorstep,
## then a few trade props. Game identity and coordinates stay outside this resource.

static func build(city_id: String, style: String, seed_value: int = 1) -> Node3D:
	var root := Node3D.new()
	root.name = "Architecture_" + city_id
	var palette := _palette(seed_value)
	root.set_meta("light_materials", [palette.glow])
	root.set_meta("city_id", city_id)
	root.set_meta("architecture_style", style)
	root.set_meta("entrance", Vector3(0, 0.10, 1.15))
	match style:
		"blue_dome": _blue_dome(root, palette, seed_value)
		"byzantine": _byzantine(root, palette)
		"roman": _roman(root, palette)
		"chinese", "port_chinese": _chinese(root, palette, style == "port_chinese", seed_value)
		"gate": _gate(root, palette)
		"indian": _indian(root, palette)
		"tropical": _tropical(root, palette)
		"arab_port": _arab_port(root, palette)
		_: _caravanserai(root, palette, seed_value)
	return root

static func _palette(seed_value: int) -> Dictionary:
	var warmth := float(posmod(seed_value, 5)) * 0.012
	return {
		"stone": _material("Warm limestone", Color(0.79, 0.70 + warmth, 0.56 + warmth)),
		"light": _material("Carved ivory stone", Color("dfd1b1")),
		"shadow": _material("Sandstone joints", Color("b39b78")),
		"plinth": _material("Worn doorstep", Color("c1b390")),
		"blue": _material("Lapis blue glazed dome", Color("27859c")),
		"blue_dark": _material("Turquoise tile border", Color("326c7b")),
		"red": _material("Cinnabar painted timber", Color("994f3f")),
		"roof": _material("Terracotta roof", Color("a96249")),
		"teal": _material("Deep jade glazed roof", Color("356563")),
		"wood": _material("Oiled cedar", Color("73513a")),
		"wood_light": _material("Worn cedar planks", Color("b28351")),
		"gold": _material("Aged brass", Color("cbb06e")),
		"dark": _material("Deep recessed shadow", Color("374946")),
		"sail": _material("Linen awning", Color("dfd3b8")),
		"textile": _material("Indigo woven textile", Color("527980")),
		"glow": _window_material(),
	}

static func _material(label: String, color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.resource_name = label
	material.albedo_color = color
	material.roughness = 0.86
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

static func _window_material() -> StandardMaterial3D:
	var material := _material("LanternGlow", Color("b68e52"))
	material.emission_enabled = true
	material.emission = Color("ffae54")
	material.emission_energy_multiplier = 0.08
	return material

static func _part(parent: Node3D, label: String, mesh: Mesh, at: Vector3, mat: Material) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = label
	part.mesh = mesh
	part.material_override = mat
	part.position = at
	parent.add_child(part)
	return part

static func _box(parent: Node3D, label: String, at: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _part(parent, label, mesh, at, mat)

static func _cylinder(parent: Node3D, label: String, at: Vector3, radius: float, height: float, mat: Material, sides: int = 12, top_radius: float = -1.0) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top_radius < 0.0 else top_radius
	mesh.height = height
	mesh.radial_segments = sides
	mesh.rings = 1
	return _part(parent, label, mesh, at, mat)

static func _beam(parent: Node3D, label: String, a: Vector3, b: Vector3, radius: float, mat: Material) -> void:
	var part := _cylinder(parent, label, (a + b) * 0.5, radius, a.distance_to(b), mat, 6)
	part.quaternion = Quaternion(Vector3.UP, (b - a).normalized())

static func _tri(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(c)
	surface.add_vertex(b)

static func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(surface, a, b, c)
	_tri(surface, a, c, d)

static func _surface_part(parent: Node3D, label: String, surface: SurfaceTool, at: Vector3, mat: Material) -> MeshInstance3D:
	surface.generate_normals()
	return _part(parent, label, surface.commit(), at, mat)

static func _lathe(parent: Node3D, label: String, at: Vector3, profile: Array[Vector2], mat: Material, segments: int = 16) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(profile.size() - 1):
		for k in range(segments):
			var a := TAU * float(k) / float(segments)
			var b := TAU * float(k + 1) / float(segments)
			var p := profile[j]
			var q := profile[j + 1]
			_quad(surface, Vector3(cos(a) * p.x, p.y, sin(a) * p.x), Vector3(cos(a) * q.x, q.y, sin(a) * q.x), Vector3(cos(b) * q.x, q.y, sin(b) * q.x), Vector3(cos(b) * p.x, p.y, sin(b) * p.x))
	_surface_part(parent, label, surface, at, mat)

static func _dome(parent: Node3D, at: Vector3, radius: float, height: float, mat: Material, gold: Material, onion: bool = true) -> void:
	var profile: Array[Vector2] = []
	if onion:
		profile = [Vector2(radius * 0.84, 0), Vector2(radius * 0.99, height * 0.15), Vector2(radius, height * 0.32), Vector2(radius * 0.84, height * 0.57), Vector2(radius * 0.51, height * 0.80), Vector2(radius * 0.18, height * 0.96), Vector2(0, height * 1.09)]
	else:
		profile = [Vector2(radius, 0), Vector2(radius * 0.97, height * 0.25), Vector2(radius * 0.80, height * 0.60), Vector2(radius * 0.52, height * 0.84), Vector2(0, height)]
	_lathe(parent, "Glazed dome facets", at, profile, mat, 20)
	_cylinder(parent, "Dome tile cornice", at + Vector3(0, 0.025, 0), radius * 0.90, 0.085, mat, 20)
	_cylinder(parent, "Finial", at + Vector3(0, height * 1.10 + 0.09, 0), 0.024, 0.24, gold, 8, 0.006)
	_cylinder(parent, "Finial bead", at + Vector3(0, height * 1.10 + 0.04, 0), 0.055, 0.058, gold, 8, 0.033)

## Arch has real open space: masonry is built as two piers and an annular barrel.
## recessed=true adds a dark inset; false creates a gate through which the ground is visible.
static func _arch(parent: Node3D, at: Vector3, width: float, height: float, depth: float, frame: Material, inset: Material = null, thickness: float = 0.075) -> void:
	var radius := width * 0.5
	var spring := height - radius
	_box(parent, "Arch left pier", at + Vector3(-radius - thickness * 0.5, spring * 0.5, 0), Vector3(thickness, spring, depth), frame)
	_box(parent, "Arch right pier", at + Vector3(radius + thickness * 0.5, spring * 0.5, 0), Vector3(thickness, spring, depth), frame)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(10):
		var a := PI * float(i) / 10.0
		var b := PI * float(i + 1) / 10.0
		var ia := Vector2(cos(a) * radius, sin(a) * radius + spring)
		var ib := Vector2(cos(b) * radius, sin(b) * radius + spring)
		var oa := Vector2(cos(a) * (radius + thickness), sin(a) * (radius + thickness) + spring)
		var ob := Vector2(cos(b) * (radius + thickness), sin(b) * (radius + thickness) + spring)
		for z in [-depth * 0.5, depth * 0.5]:
			_quad(surface, Vector3(ia.x, ia.y, z), Vector3(oa.x, oa.y, z), Vector3(ob.x, ob.y, z), Vector3(ib.x, ib.y, z))
		_quad(surface, Vector3(ia.x, ia.y, -depth * 0.5), Vector3(ib.x, ib.y, -depth * 0.5), Vector3(ib.x, ib.y, depth * 0.5), Vector3(ia.x, ia.y, depth * 0.5))
		_quad(surface, Vector3(oa.x, oa.y, -depth * 0.5), Vector3(ob.x, ob.y, -depth * 0.5), Vector3(ob.x, ob.y, depth * 0.5), Vector3(oa.x, oa.y, depth * 0.5))
	_surface_part(parent, "Carved arch voussoirs", surface, at, frame)
	if inset != null:
		var dark := SurfaceTool.new()
		dark.begin(Mesh.PRIMITIVE_TRIANGLES)
		_quad(dark, Vector3(-radius, 0, 0), Vector3(radius, 0, 0), Vector3(radius, spring, 0), Vector3(-radius, spring, 0))
		for i in range(10):
			var a := PI * float(i) / 10.0
			var b := PI * float(i + 1) / 10.0
			_tri(dark, Vector3(0, spring, 0), Vector3(cos(a) * radius, sin(a) * radius + spring, 0), Vector3(cos(b) * radius, sin(b) * radius + spring, 0))
		_surface_part(parent, "Recessed arched opening", dark, at + Vector3(0, 0, -depth * 0.08), inset)

static func _window(parent: Node3D, at: Vector3, width: float, height: float, p: Dictionary, rotation: float = 0.0, glowing: bool = true) -> void:
	var pivot := Node3D.new()
	pivot.name = "Arched window"
	pivot.position = at
	pivot.rotation.y = rotation
	parent.add_child(pivot)
	_arch(pivot, Vector3.ZERO, width, height, 0.028, p.light, p.glow if glowing else p.dark, 0.028)
	_box(pivot, "Window mullion", Vector3(0, height * 0.42, 0.024), Vector3(0.017, height * 0.72, 0.018), p.wood)

static func _steps(parent: Node3D, at: Vector3, width: float, p: Dictionary, count: int = 3) -> void:
	for i in range(count):
		_box(parent, "Entrance step", at + Vector3(0, 0.032 + float(i) * 0.025, -float(i) * 0.105), Vector3(width, 0.065 + float(i) * 0.05, 0.15), p.plinth)

static func _plinth(parent: Node3D, at: Vector3, width: float, depth: float, p: Dictionary) -> void:
	_box(parent, "Chamfered lower course", at + Vector3(0, 0.055, 0), Vector3(width, 0.11, depth), p.shadow)
	_box(parent, "Raised stone sill", at + Vector3(0, 0.125, 0), Vector3(width - 0.07, 0.065, depth - 0.05), p.light)

static func _hip_roof(parent: Node3D, at: Vector3, width: float, depth: float, height: float, mat: Material, trim: Material, curved: bool = true) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ratios := [0.04, 0.30, 0.73, 1.0]
	var elevations := [1.0, 0.70, 0.10, 0.18] if curved else [1.0, 0.74, 0.26, 0.0]
	# Eight points in each ring retain upturned corners without spherical smoothing.
	var ring := [Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), Vector2(-1, 1), Vector2(-1, 0)]
	for level in range(3):
		for k in range(8):
			var verts: Array[Vector3] = []
			for spec in [Vector2i(level, k), Vector2i(level + 1, k), Vector2i(level + 1, (k + 1) % 8), Vector2i(level, (k + 1) % 8)]:
				var uv: Vector2 = ring[spec.y]
				var r: float = ratios[spec.x]
				var y: float = elevations[spec.x] * height
				if curved and spec.x >= 2 and spec.y % 2 == 0: y += height * 0.20 * r
				var x_ratio := (0.40 + r * 0.60) if curved else r
				verts.append(Vector3(uv.x * width * x_ratio * 0.5, y, uv.y * depth * r * 0.5))
			_quad(surface, verts[0], verts[3], verts[2], verts[1])
	_surface_part(parent, "Sweeping roof planes", surface, at, mat)
	for k in range(8):
		var a: Vector2 = ring[k]
		var b: Vector2 = ring[(k + 1) % 8]
		var ya: float = height * (0.18 + (0.20 if k % 2 == 0 else 0.0)) if curved else 0.0
		var yb: float = height * (0.18 + (0.20 if (k + 1) % 8 % 2 == 0 else 0.0)) if curved else 0.0
		_beam(parent, "Roof eave fascia", at + Vector3(a.x * width * 0.5, ya, a.y * depth * 0.5), at + Vector3(b.x * width * 0.5, yb, b.y * depth * 0.5), 0.025, trim)
	_beam(parent, "Decorated roof ridge", at + Vector3(-width * 0.23, height, 0), at + Vector3(width * 0.23, height, 0), 0.036, trim)
	if curved:
		for side in [-1.0, 1.0]:
			_beam(parent, "Ridge finial", at + Vector3(side * width * 0.23, height, 0), at + Vector3(side * width * 0.30, height + 0.12, 0), 0.035, trim)

static func _gable_roof(parent: Node3D, at: Vector3, width: float, depth: float, height: float, p: Dictionary) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(-width * 0.5, 0, -depth * 0.5)
	var b := Vector3(width * 0.5, 0, -depth * 0.5)
	var c := Vector3(width * 0.5, 0, depth * 0.5)
	var d := Vector3(-width * 0.5, 0, depth * 0.5)
	var r1 := Vector3(0, height, -depth * 0.5)
	var r2 := Vector3(0, height, depth * 0.5)
	_quad(surface, a, d, r2, r1)
	_quad(surface, r1, r2, c, b)
	_tri(surface, a, r1, b)
	_tri(surface, d, c, r2)
	_surface_part(parent, "Terracotta pitched roof", surface, at, p.roof)
	_beam(parent, "Terracotta ridge cap", at + r1, at + r2, 0.039, p.roof)
	for side in [-1.0, 1.0]:
		_beam(parent, "Roof carved fascia", at + Vector3(side * width * 0.5, 0, -depth * 0.5), at + Vector3(side * width * 0.5, 0, depth * 0.5), 0.027, p.wood)

static func _parapet(parent: Node3D, at: Vector3, width: float, depth: float, p: Dictionary, crenels: bool = false) -> void:
	_box(parent, "Cornice front", at + Vector3(0, 0, depth * 0.5), Vector3(width + 0.10, 0.11, 0.10), p.light)
	_box(parent, "Cornice back", at + Vector3(0, 0, -depth * 0.5), Vector3(width + 0.10, 0.11, 0.10), p.light)
	for side in [-1.0, 1.0]:
		_box(parent, "Cornice side", at + Vector3(side * width * 0.5, 0, 0), Vector3(0.10, 0.11, depth), p.light)
	if crenels:
		for i in range(5):
			for z in [-depth * 0.5, depth * 0.5]:
				_box(parent, "Parapet merlon", at + Vector3((float(i) / 4.0 - 0.5) * width, 0.11, z), Vector3(0.13, 0.15, 0.12), p.stone)

static func _minaret(parent: Node3D, at: Vector3, height: float, p: Dictionary) -> void:
	_plinth(parent, at, 0.45, 0.45, p)
	_cylinder(parent, "Minaret octagonal base", at + Vector3(0, 0.46, 0), 0.22, 0.64, p.stone, 8, 0.18)
	_cylinder(parent, "Minaret tapered shaft", at + Vector3(0, height * 0.51, 0), 0.16, height * 0.68, p.light, 12, 0.105)
	for h in [height * 0.42, height * 0.71]:
		_cylinder(parent, "Balcony carved corbel", at + Vector3(0, h - 0.04, 0), 0.16, 0.12, p.shadow, 12, 0.24)
		_cylinder(parent, "Minaret balcony", at + Vector3(0, h + 0.015, 0), 0.255, 0.065, p.light, 12)
		for i in range(12):
			var theta := float(i) * TAU / 12.0
			_cylinder(parent, "Balcony baluster", at + Vector3(cos(theta) * 0.223, h + 0.12, sin(theta) * 0.223), 0.018, 0.19, p.light, 5)
		_cylinder(parent, "Balcony rail", at + Vector3(0, h + 0.22, 0), 0.247, 0.035, p.light, 12)
	_cylinder(parent, "Minaret lantern chamber", at + Vector3(0, height * 0.85, 0), 0.127, height * 0.24, p.stone, 12)
	for theta in [0.0, PI * 0.5, PI, PI * 1.5]:
		_window(parent, at + Vector3(sin(theta) * 0.12, height * 0.80, cos(theta) * 0.12), 0.060, 0.20, p, theta)
	_dome(parent, at + Vector3(0, height * 0.98, 0), 0.16, 0.26, p.blue, p.gold)

static func _blue_dome(parent: Node3D, p: Dictionary, seed_value: int) -> void:
	_plinth(parent, Vector3(0, 0, -0.04), 1.83, 1.70, p)
	_box(parent, "Main prayer hall", Vector3(0.10, 0.71, -0.18), Vector3(1.38, 1.13, 1.17), p.stone)
	_parapet(parent, Vector3(0.10, 1.26, -0.18), 1.38, 1.17, p)
	_cylinder(parent, "Octagonal dome drum", Vector3(0.10, 1.51, -0.18), 0.64, 0.51, p.light, 12)
	_cylinder(parent, "Turquoise drum ribbon", Vector3(0.10, 1.73, -0.18), 0.661, 0.075, p.blue_dark, 12)
	for i in range(12):
		var theta := TAU * float(i) / 12.0
		_window(parent, Vector3(0.10 + sin(theta) * 0.623, 1.36, -0.18 + cos(theta) * 0.623), 0.16, 0.27, p, theta)
	_dome(parent, Vector3(0.10, 1.77, -0.18), 0.73, 0.88, p.blue, p.gold)
	_box(parent, "Deep entrance porch roof", Vector3(0.10, 0.92, 0.64), Vector3(1.60, 0.15, 0.63), p.stone)
	for x in [-0.45, 0.10, 0.65]:
		_arch(parent, Vector3(x, 0.17, 0.91), 0.38, 0.63, 0.14, p.light)
	_arch(parent, Vector3(0.10, 0.17, 0.416), 0.48, 0.67, 0.04, p.light, p.dark, 0.065)
	_box(parent, "Side annex", Vector3(0.88, 0.48, -0.34), Vector3(0.54, 0.69, 0.96), p.stone)
	_parapet(parent, Vector3(0.88, 0.83, -0.34), 0.54, 0.96, p)
	_dome(parent, Vector3(0.88, 0.91, -0.39), 0.28, 0.30, p.blue_dark, p.gold)
	_window(parent, Vector3(0.88, 0.31, 0.153), 0.17, 0.31, p)
	_minaret(parent, Vector3(-0.90, 0, -0.53), 2.83 if posmod(seed_value, 2) == 0 else 2.55, p)
	_steps(parent, Vector3(0.10, 0, 1.14), 0.93, p)
	_trade_props(parent, Vector3(1.03, 0.16, 0.66), p, 0)

static func _byzantine(parent: Node3D, p: Dictionary) -> void:
	_plinth(parent, Vector3(0, 0, 0), 2.0, 1.85, p)
	_box(parent, "Basilica nave", Vector3(0, 0.76, -0.12), Vector3(1.23, 1.25, 1.37), p.stone)
	_box(parent, "Crossing transept", Vector3(0, 0.66, -0.22), Vector3(1.90, 1.05, 0.76), p.light)
	for x in [-0.75, 0.75]:
		_dome(parent, Vector3(x, 1.17, -0.22), 0.40, 0.34, p.roof, p.gold, false)
	_cylinder(parent, "Clerestory drum", Vector3(0, 1.63, -0.15), 0.58, 0.53, p.light, 16)
	for i in range(12):
		var theta := TAU * float(i) / 12.0
		_window(parent, Vector3(sin(theta) * 0.58, 1.47, -0.15 + cos(theta) * 0.58), 0.12, 0.28, p, theta)
	_dome(parent, Vector3(0, 1.94, -0.15), 0.74, 0.66, p.roof, p.gold, false)
	_box(parent, "Entrance portico roof", Vector3(0, 0.95, 0.68), Vector3(1.54, 0.16, 0.52), p.light)
	for x in [-0.5, 0.0, 0.5]:
		_arch(parent, Vector3(x, 0.17, 0.88), 0.33, 0.69, 0.13, p.light)
	_arch(parent, Vector3(0, 0.17, 0.575), 0.38, 0.7, 0.05, p.light, p.dark)
	_steps(parent, Vector3(0, 0, 1.14), 1.15, p)
	_flag(parent, Vector3(-0.91, 1.5, -0.65), p.red, p.gold)

static func _roman(parent: Node3D, p: Dictionary) -> void:
	_plinth(parent, Vector3(0, 0, 0), 2.11, 1.7, p)
	_box(parent, "Merchant palazzo", Vector3(0.28, 0.86, -0.04), Vector3(1.31, 1.44, 1.24), p.light)
	_box(parent, "Palazzo belt course", Vector3(0.28, 0.85, -0.04), Vector3(1.37, 0.065, 1.30), p.shadow)
	_gable_roof(parent, Vector3(0.28, 1.61, -0.04), 1.49, 1.41, 0.54, p)
	for x in [-0.08, 0.32, 0.71]:
		_window(parent, Vector3(x, 1.04, 0.59), 0.18, 0.35, p)
		_arch(parent, Vector3(x, 0.16, 0.60), 0.23, 0.55, 0.07, p.stone, p.dark, 0.045)
	for z in [-0.45, 0.02, 0.43]:
		_window(parent, Vector3(0.943, 1.02, z), 0.18, 0.36, p, PI * 0.5)
	_box(parent, "Bell tower", Vector3(-0.71, 1.29, -0.43), Vector3(0.61, 2.28, 0.61), p.stone)
	for h in [0.61, 1.20, 1.81, 2.39]:
		_box(parent, "Tower stone belt", Vector3(-0.71, h, -0.43), Vector3(0.68, 0.065, 0.68), p.light)
	for theta in [0.0, PI * 0.5, PI, PI * 1.5]:
		_window(parent, Vector3(-0.71 + sin(theta) * 0.31, 1.95, -0.43 + cos(theta) * 0.31), 0.24, 0.36, p, theta, false)
	_hip_roof(parent, Vector3(-0.71, 2.46, -0.43), 0.89, 0.89, 0.56, p.roof, p.wood, false)
	_steps(parent, Vector3(0.26, 0, 1.08), 1.03, p)
	_awning(parent, Vector3(0.20, 0.72, 0.86), 0.91, 0.45, p)
	_trade_props(parent, Vector3(-0.70, 0.15, 0.73), p, 1)

static func _chinese(parent: Node3D, p: Dictionary, port: bool, seed_value: int) -> void:
	var roof_mat: Material = p.teal if port or posmod(seed_value, 2) == 0 else p.roof
	_plinth(parent, Vector3(0, 0, -0.14), 2.06, 1.69, p)
	_box(parent, "Great hall lime walls", Vector3(0, 0.66, -0.14), Vector3(1.65, 0.96, 1.19), p.light)
	_box(parent, "Hall lower timber", Vector3(0, 0.24, -0.14), Vector3(1.72, 0.15, 1.28), p.red)
	for x in [-0.76, -0.39, 0.0, 0.39, 0.76]:
		_cylinder(parent, "Front vermilion column", Vector3(x, 0.70, 0.63), 0.046, 1.02, p.red, 8)
		_box(parent, "Column capital", Vector3(x, 1.14, 0.63), Vector3(0.13, 0.09, 0.15), p.wood_light)
		if abs(x) > 0.1:
			_box(parent, "Amber lattice window", Vector3(x, 0.70, 0.465), Vector3(0.25, 0.46, 0.027), p.glow)
			for bar in [-0.073, 0.0, 0.073]:
				_box(parent, "Lattice vertical", Vector3(x + bar, 0.70, 0.486), Vector3(0.013, 0.46, 0.023), p.red)
			for h in [0.57, 0.72, 0.87]:
				_box(parent, "Lattice horizontal", Vector3(x, h, 0.49), Vector3(0.25, 0.016, 0.023), p.red)
	_box(parent, "Open central doors", Vector3(0, 0.56, 0.464), Vector3(0.28, 0.76, 0.03), p.dark)
	_box(parent, "Long decorated architrave", Vector3(0, 1.16, 0.62), Vector3(1.89, 0.14, 0.17), p.red)
	_box(parent, "Golden plaque", Vector3(0, 1.20, 0.72), Vector3(0.38, 0.11, 0.022), p.gold)
	_hip_roof(parent, Vector3(0, 1.17, -0.10), 2.40, 1.98, 0.57, roof_mat, p.wood, true)
	_box(parent, "Upper pavilion chamber", Vector3(0, 1.84, -0.16), Vector3(0.95, 0.47, 0.73), p.light)
	for x in [-0.45, 0.0, 0.45]:
		_cylinder(parent, "Upper pavilion column", Vector3(x, 1.87, 0.23), 0.035, 0.55, p.red, 8)
	_box(parent, "Upper pavilion amber window", Vector3(0, 1.85, 0.22), Vector3(0.70, 0.27, 0.025), p.glow)
	for x in [-0.25, -0.08, 0.08, 0.25]:
		_box(parent, "Upper lattice", Vector3(x, 1.86, 0.242), Vector3(0.025, 0.32, 0.025), p.red)
	_hip_roof(parent, Vector3(0, 2.09, -0.16), 1.62, 1.34, 0.51, roof_mat, p.wood, true)
	_steps(parent, Vector3(0, 0, 1.15), 1.00, p)
	for x in [-0.70, 0.70]:
		_lantern(parent, Vector3(x, 0.97, 0.72), p)
	if port:
		_trade_props(parent, Vector3(1.07, 0.07, 0.63), p, 2)
	else:
		_flag(parent, Vector3(0.94, 0.25, -0.75), p.red, p.wood)

static func _gate(parent: Node3D, p: Dictionary) -> void:
	for x in [-0.80, 0.80]:
		_plinth(parent, Vector3(x, 0, -0.03), 0.71, 0.91, p)
		_box(parent, "Gate battered watchtower", Vector3(x, 0.95, -0.03), Vector3(0.60, 1.65, 0.75), p.stone)
		_box(parent, "Tower cap band", Vector3(x, 1.74, -0.03), Vector3(0.71, 0.13, 0.86), p.light)
		for xoff in [-0.19, 0.0, 0.19]:
			_box(parent, "Battlement", Vector3(x + xoff, 1.92, 0.33), Vector3(0.12, 0.26, 0.12), p.stone)
		_window(parent, Vector3(x, 1.16, 0.359), 0.12, 0.34, p, 0, false)
		_hip_roof(parent, Vector3(x, 2.06, -0.03), 0.94, 1.07, 0.42, p.roof, p.wood, true)
		_flag(parent, Vector3(x, 2.49, -0.03), p.red, p.wood, 0.38)
	_arch(parent, Vector3(0, 0.12, -0.01), 0.90, 1.27, 0.64, p.light, null, 0.14)
	_box(parent, "Upper gate chamber", Vector3(0, 1.64, -0.01), Vector3(1.09, 0.58, 0.62), p.stone)
	_hip_roof(parent, Vector3(0, 1.94, -0.01), 1.34, 0.93, 0.36, p.roof, p.wood, true)
	_box(parent, "Gate open left leaf", Vector3(-0.435, 0.60, 0.16), Vector3(0.055, 0.90, 0.33), p.wood)
	_box(parent, "Gate open right leaf", Vector3(0.435, 0.60, 0.16), Vector3(0.055, 0.90, 0.33), p.wood)
	_box(parent, "Road through arch", Vector3(0, 0.04, 0.36), Vector3(0.90, 0.07, 1.63), p.plinth)
	_trade_props(parent, Vector3(1.12, 0.03, 0.56), p, 0)

static func _caravanserai(parent: Node3D, p: Dictionary, seed_value: int) -> void:
	_plinth(parent, Vector3(0, 0, -0.11), 1.88, 1.65, p)
	_box(parent, "Caravanserai main hall", Vector3(0, 0.70, -0.17), Vector3(1.72, 1.11, 1.25), p.stone)
	_parapet(parent, Vector3(0, 1.29, -0.17), 1.72, 1.25, p, true)
	# A substantial tiled iwan marks the entrance; narrow side rooms frame it.
	_box(parent, "Iwan left pier", Vector3(-0.43, 0.88, 0.55), Vector3(0.22, 1.48, 0.39), p.light)
	_box(parent, "Iwan right pier", Vector3(0.43, 0.88, 0.55), Vector3(0.22, 1.48, 0.39), p.light)
	_box(parent, "Iwan upper panel", Vector3(0, 1.56, 0.55), Vector3(1.10, 0.22, 0.39), p.light)
	_arch(parent, Vector3(0, 0.15, 0.768), 0.62, 1.28, 0.07, p.blue_dark, p.dark, 0.075)
	for x in [-0.70, 0.70]:
		_window(parent, Vector3(x, 0.56, 0.47), 0.16, 0.36, p)
	_dome(parent, Vector3(0, 1.42, -0.25), 0.58, 0.61, p.blue if posmod(seed_value, 2) == 0 else p.light, p.gold)
	for x in [-0.86, 0.86]:
		_cylinder(parent, "Caravanserai corner tower", Vector3(x, 0.86, -0.69), 0.21, 1.55, p.stone, 8, 0.17)
		_cylinder(parent, "Corner crown", Vector3(x, 1.64, -0.69), 0.24, 0.13, p.light, 8)
	_steps(parent, Vector3(0, 0, 1.15), 0.87, p)
	_awning(parent, Vector3(-0.91, 0.68, 0.66), 0.60, 0.55, p)
	_trade_props(parent, Vector3(0.89, 0.15, 0.77), p, 1)

static func _indian(parent: Node3D, p: Dictionary) -> void:
	_plinth(parent, Vector3.ZERO, 2.10, 1.78, p)
	_box(parent, "Temple sanctuary", Vector3(0, 0.67, -0.20), Vector3(1.20, 1.03, 1.08), p.stone)
	for y in [0.28, 0.75, 1.15]:
		_box(parent, "Temple carved band", Vector3(0, y, -0.20), Vector3(1.34, 0.10, 1.18), p.light)
	# Stacked stepped profiles form a recognisable curving shikhara silhouette.
	for i in range(7):
		var t := float(i) / 7.0
		var width := 1.13 * pow(1.0 - t, 0.60)
		var y := 1.24 + float(i) * 0.18
		_box(parent, "Shikhara carved tier", Vector3(0, y, -0.20), Vector3(width, 0.20, width * 0.82), p.stone)
		_box(parent, "Shikhara projecting course", Vector3(0, y + 0.09, -0.20), Vector3(width + 0.085, 0.055, width * 0.82 + 0.085), p.light)
	_cylinder(parent, "Amalaka crown", Vector3(0, 2.56, -0.20), 0.20, 0.13, p.gold, 12)
	_dome(parent, Vector3(0, 2.60, -0.20), 0.14, 0.25, p.gold, p.gold)
	for x in [-0.72, 0.72]:
		for z in [0.24, 0.76]:
			_cylinder(parent, "Mandapa column", Vector3(x, 0.56, z), 0.075, 0.81, p.light, 8)
			_box(parent, "Carved column capital", Vector3(x, 0.97, z), Vector3(0.22, 0.11, 0.22), p.light)
	_hip_roof(parent, Vector3(0, 1.02, 0.49), 1.91, 0.95, 0.39, p.roof, p.gold, false)
	_arch(parent, Vector3(0, 0.15, 0.353), 0.42, 0.70, 0.07, p.light, p.dark)
	_steps(parent, Vector3(0, 0, 1.14), 1.10, p)
	for x in [-0.64, 0.64]: _lantern(parent, Vector3(x, 0.76, 0.83), p)

static func _tropical(parent: Node3D, p: Dictionary) -> void:
	_plinth(parent, Vector3(0, 0, -0.11), 1.82, 1.48, p)
	for x in [-0.71, 0.71]:
		for z in [-0.59, 0.52]:
			_cylinder(parent, "Raised teak stilt", Vector3(x, 0.39, z), 0.071, 0.66, p.wood, 8)
	_box(parent, "Raised timber floor", Vector3(0, 0.60, -0.06), Vector3(1.73, 0.15, 1.39), p.wood_light)
	_box(parent, "Spice trading hall", Vector3(0, 1.04, -0.18), Vector3(1.30, 0.80, 0.97), p.stone)
	for x in [-0.64, -0.21, 0.21, 0.64]:
		_cylinder(parent, "Veranda post", Vector3(x, 1.06, 0.61), 0.04, 0.90, p.wood, 8)
	for x in [-0.39, 0.39]:
		_box(parent, "Open teak shutters", Vector3(x, 1.10, 0.32), Vector3(0.23, 0.32, 0.025), p.dark)
	_hip_roof(parent, Vector3(0, 1.42, -0.10), 2.18, 1.78, 0.72, p.roof, p.wood, true)
	_box(parent, "Upper shrine", Vector3(0, 2.15, -0.10), Vector3(0.34, 0.33, 0.34), p.gold)
	_hip_roof(parent, Vector3(0, 2.28, -0.10), 0.70, 0.62, 0.41, p.teal, p.gold, true)
	for i in range(6):
		_box(parent, "Veranda stair", Vector3(0, float(i + 1) * 0.056, 1.18 - float(i) * 0.103), Vector3(0.69, float(i + 1) * 0.112, 0.15), p.wood_light)
	_trade_props(parent, Vector3(-0.92, 0.15, 0.44), p, 2)

static func _arab_port(parent: Node3D, p: Dictionary) -> void:
	_plinth(parent, Vector3.ZERO, 2.12, 1.76, p)
	_box(parent, "Harbour merchant house", Vector3(-0.13, 0.83, -0.13), Vector3(1.27, 1.36, 1.19), p.light)
	_parapet(parent, Vector3(-0.13, 1.51, -0.13), 1.27, 1.19, p, true)
	_box(parent, "Flat roof terrace", Vector3(-0.13, 1.45, -0.13), Vector3(1.12, 0.08, 1.02), p.stone)
	for x in [-0.48, 0.16]:
		_window(parent, Vector3(x, 0.98, 0.48), 0.22, 0.35, p)
		_arch(parent, Vector3(x, 0.17, 0.48), 0.29, 0.60, 0.07, p.stone, p.dark)
	_box(parent, "Harbour wind tower", Vector3(0.74, 1.24, -0.49), Vector3(0.60, 2.15, 0.59), p.stone)
	for y in [1.64, 2.30]:
		_box(parent, "Wind tower cornice", Vector3(0.74, y, -0.49), Vector3(0.75, 0.09, 0.73), p.light)
	for x in [0.60, 0.86]:
		_box(parent, "Wind tower cooling vents", Vector3(x, 2.04, -0.181), Vector3(0.095, 0.40, 0.024), p.dark)
	_dome(parent, Vector3(0.74, 2.36, -0.49), 0.37, 0.45, p.blue, p.gold)
	_awning(parent, Vector3(-0.11, 0.94, 0.80), 1.57, 0.57, p)
	_steps(parent, Vector3(0, 0, 1.13), 0.75, p)
	_trade_props(parent, Vector3(0.91, 0.15, 0.65), p, 2)

static func _awning(parent: Node3D, at: Vector3, width: float, depth: float, p: Dictionary) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	_quad(surface, Vector3(-width * 0.5, 0.05, -depth * 0.5), Vector3(-width * 0.5, -0.06, depth * 0.5), Vector3(width * 0.5, -0.06, depth * 0.5), Vector3(width * 0.5, 0.05, -depth * 0.5))
	_surface_part(parent, "Linen market awning", surface, at, p.sail)
	for x in [-width * 0.5, width * 0.5]:
		_cylinder(parent, "Awning cedar post", Vector3(at.x + x, at.y * 0.5, at.z + depth * 0.5), 0.022, at.y, p.wood, 6)
	for x in [-width * 0.32, 0.0, width * 0.32]:
		_box(parent, "Awning hanging valance", at + Vector3(x, -0.10, depth * 0.5), Vector3(width * 0.20, 0.11, 0.025), p.roof)

static func _lantern(parent: Node3D, at: Vector3, p: Dictionary) -> void:
	_cylinder(parent, "Lantern brass hanger", at + Vector3(0, 0.08, 0), 0.014, 0.19, p.wood, 6)
	_cylinder(parent, "LanternGlow", at, 0.068, 0.105, p.glow, 8, 0.058)
	_cylinder(parent, "Lantern cap", at + Vector3(0, 0.065, 0), 0.077, 0.038, p.red, 8)
	_cylinder(parent, "Lantern base", at + Vector3(0, -0.065, 0), 0.058, 0.032, p.red, 8)

static func _flag(parent: Node3D, at: Vector3, mat: Material, pole: Material, height: float = 0.70) -> void:
	_cylinder(parent, "Pennant pole", at + Vector3(0, height * 0.5, 0), 0.017, height, pole, 6)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tri(surface, Vector3(0, height * 0.96, 0), Vector3(0.31, height * 0.83, 0.035), Vector3(0, height * 0.65, 0))
	_surface_part(parent, "Trade pennant", surface, at, mat)

static func _trade_props(parent: Node3D, at: Vector3, p: Dictionary, kind: int) -> void:
	var props := Node3D.new()
	props.name = "Goods at the doorstep"
	props.position = at
	parent.add_child(props)
	for i in range(2):
		var pos := Vector3(float(i) * 0.20 - 0.07, 0.095, float(i) * -0.14)
		_box(props, "Trade chest", pos, Vector3(0.19, 0.19, 0.20), p.wood_light)
		for side in [-0.065, 0.065]:
			_box(props, "Chest iron hoop", pos + Vector3(side, 0, 0), Vector3(0.018, 0.20, 0.213), p.wood)
	if kind == 0:
		_lathe(props, "Glazed water jar", Vector3(-0.18, 0, 0.16), [Vector2(0.06, 0), Vector2(0.095, 0.07), Vector2(0.085, 0.19), Vector2(0.040, 0.23), Vector2(0.045, 0.25)], p.blue_dark, 10)
	elif kind == 1:
		_box(props, "Folded trading carpet", Vector3(0.035, 0.23, -0.07), Vector3(0.27, 0.055, 0.23), p.textile)
		_box(props, "Golden silk bolt", Vector3(0.035, 0.28, -0.07), Vector3(0.25, 0.045, 0.21), p.gold)
	else:
		_cylinder(props, "Spice barrel", Vector3(-0.18, 0.13, 0.18), 0.105, 0.26, p.wood, 10)
		for h in [0.055, 0.20]:
			_cylinder(props, "Barrel binding", Vector3(-0.18, h, 0.18), 0.11, 0.025, p.gold, 10)
