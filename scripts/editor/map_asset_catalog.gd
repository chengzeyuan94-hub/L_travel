class_name MapAssetCatalog
extends RefCounted
## Sample library for the authored map editor. Prefabs are ordinary, fully owned Godot scenes.
## Author an asset by opening its .tscn; regenerate sources only when deliberately rebaking.
const Architecture = preload("res://scripts/world/miniworld_architecture.gd")
const Props = preload("res://scripts/world/miniworld_props.gd")
const PREFAB_DIR := "res://assets/map_editor/prefabs/"
const ASSETS := [
	{"id":"city_blue_dome", "label":"蓝穹顶商都", "category":"city", "radius":1.4},
	{"id":"city_chinese", "label":"中式楼阁", "category":"city", "radius":1.4},
	{"id":"city_caravanserai", "label":"绿洲商旅驿", "category":"city", "radius":1.4},
	{"id":"city_roman", "label":"地中海商馆", "category":"city", "radius":1.4},
	{"id":"city_byzantine", "label":"拜占庭穹顶城", "category":"city", "radius":1.4},
	{"id":"city_gate", "label":"关隘城门", "category":"city", "radius":1.4},
	{"id":"city_indian", "label":"印度阶塔", "category":"city", "radius":1.4},
	{"id":"city_tropical", "label":"南洋高脚商馆", "category":"city", "radius":1.4},
	{"id":"city_port_chinese", "label":"中式港城", "category":"city", "radius":1.4},
	{"id":"city_arab_port", "label":"阿拉伯港馆", "category":"city", "radius":1.4},
	{"id":"mountain_snow", "label":"雪峰山脊", "category":"terrain", "radius":2.5},
	{"id":"mountain_sand", "label":"砂岩山脊", "category":"terrain", "radius":2.5},
	{"id":"coast", "label":"弧形水岸", "category":"terrain", "radius":2.0},
	{"id":"water_patch", "label":"清澈水域", "category":"terrain", "radius":1.8},
	{"id":"grass_patch", "label":"草地地块", "category":"terrain", "radius":1.8},
	{"id":"rock", "label":"散落岩石", "category":"terrain", "radius":0.75},
	{"id":"conifer", "label":"杉树", "category":"plant", "radius":0.42},
	{"id":"broadleaf", "label":"阔叶树", "category":"plant", "radius":0.60},
	{"id":"palm", "label":"棕榈", "category":"plant", "radius":0.95},
	{"id":"blossom", "label":"花树", "category":"plant", "radius":0.60},
	{"id":"bush", "label":"灌木", "category":"plant", "radius":0.40},
	{"id":"dock", "label":"贸易码头", "category":"prop", "radius":1.05},
	{"id":"bridge", "label":"木桥", "category":"prop", "radius":1.10},
	{"id":"ship", "label":"三角帆商船", "category":"prop", "radius":1.00},
	{"id":"junk", "label":"中式帆船", "category":"prop", "radius":1.00},
	{"id":"camel", "label":"驮货骆驼", "category":"prop", "radius":0.68},
	{"id":"market", "label":"织物货摊", "category":"prop", "radius":0.85},
]

static func list_assets() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in ASSETS: result.append(entry.duplicate(true))
	return result

static func create(asset_id: String) -> Node3D:
	var path := PREFAB_DIR + asset_id + ".tscn"
	if ResourceLoader.exists(path):
		var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
		if packed != null: return packed.instantiate() as Node3D
	return build_source(asset_id)

static func build_source(asset_id: String) -> Node3D:
	var source: Node3D
	var found := false
	for entry in ASSETS:
		if entry.id == asset_id: found = true
	if not found:
		push_error("Unknown map asset: " + asset_id)
		return null
	if asset_id.begins_with("city_"):
		source = Architecture.build(asset_id, asset_id.trim_prefix("city_"), 4)
	elif asset_id in ["conifer", "broadleaf", "palm", "blossom", "bush"]:
		source = Props.tree(asset_id, 41)
	elif asset_id == "dock": source = Props.dock(1.8)
	elif asset_id == "bridge": source = Props.bridge(2.0)
	elif asset_id == "ship": source = Props.boat(false)
	elif asset_id == "junk": source = Props.boat(true)
	elif asset_id == "camel": source = Props.camel(14)
	elif asset_id == "market": source = Props.market(9)
	elif asset_id in ["mountain_snow", "mountain_sand"]: source = _ridge(asset_id == "mountain_snow")
	elif asset_id == "coast": source = _coast()
	elif asset_id in ["water_patch", "grass_patch"]: source = _patch(asset_id == "water_patch")
	else: source = _rocks()
	var root := Node3D.new()
	root.name = asset_id.to_pascal_case()
	root.set_meta("asset_id", asset_id)
	root.set_meta("source_script", "res://tools/miniworld/bake_editor_assets.gd")
	root.add_child(source)
	var bounds := _bounds(source, Transform3D.IDENTITY)
	var radius := maxf(Vector2(bounds.position.x, bounds.position.z).length(), Vector2(bounds.end.x, bounds.end.z).length())
	var factor := minf(1.0, 1.4 / maxf(radius, 0.001)) if asset_id.begins_with("city_") else 1.0
	source.scale = Vector3.ONE * factor
	source.position = Vector3(-bounds.get_center().x * factor, -bounds.position.y * factor, -bounds.get_center().z * factor)
	if source.has_meta("entrance"):
		var entrance: Vector3 = source.transform * source.get_meta("entrance")
		root.set_meta("entrance", entrance)
		var lantern := OmniLight3D.new()
		lantern.name = "DoorstepWarmLight"
		lantern.set_meta("night_only", true)
		lantern.position = entrance + Vector3(0, 0.72, 0.04)
		lantern.light_color = Color("ffc27b")
		lantern.light_energy = 0.65
		lantern.omni_range = 2.35
		lantern.omni_attenuation = 1.50
		lantern.shadow_enabled = false
		root.add_child(lantern)
	root.set_meta("ground_origin", true)
	root.set_meta("source_bounds", bounds)
	set_night(root, false)
	return root

static func _bounds(node: Node3D, transform: Transform3D) -> AABB:
	var found := false
	var result := AABB()
	if node is MeshInstance3D and node.mesh != null:
		result = transform * node.get_aabb()
		found = true
	for child in node.get_children():
		if child is Node3D:
			var child_box := _bounds(child, transform * child.transform)
			if child_box.size.length() > 0.0001:
				result = result.merge(child_box) if found else child_box
				found = true
	return result

static func set_night(root: Node, enabled: bool) -> void:
	if root is MeshInstance3D:
		var material: Material = root.material_override
		if material is StandardMaterial3D and material.resource_name == "LanternGlow":
			material.emission_energy_multiplier = 1.45 if enabled else 0.0
	if root is Light3D and root.get_meta("night_only", false): root.visible = enabled
	for child in root.get_children(): set_night(child, enabled)

static func _material(label: String, color: String, roughness: float = 0.88) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.resource_name = label
	material.albedo_color = Color(color)
	material.roughness = roughness
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

static func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (b-a).cross(c-a).normalized()
	for vertex in [a, c, b]:
		surface.set_normal(normal)
		surface.add_vertex(vertex)

static func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_triangle(surface, a, b, c)
	_triangle(surface, a, c, d)

static func _mesh(parent: Node3D, title: String, surface: SurfaceTool, material: Material) -> void:
	var part := MeshInstance3D.new()
	part.name = title
	part.mesh = surface.commit()
	part.material_override = material
	parent.add_child(part)

static func _new_surface() -> SurfaceTool:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	return surface

static func _ridge(snowy: bool) -> Node3D:
	var root := Node3D.new()
	root.name = "ConnectedMountainRidge"
	var columns := [-2.30, -1.92, -1.49, -1.04, -0.59, -0.11, 0.32, 0.77, 1.18, 1.62, 2.06, 2.36]
	var peak_heights := [0.10, 0.82, 1.41, 0.92, 1.65, 2.43, 1.53, 1.24, 1.91, 1.13, 0.53, 0.10]
	var row_z := [-1.19, -0.84, -0.33, 0.11, 0.65, 1.17]
	var profiles := [0.0, 0.31, 0.73, 1.0, 0.41, 0.0]
	var vertices: Array[PackedVector3Array] = []
	for row in range(row_z.size()):
		var strip := PackedVector3Array()
		for col in range(columns.size()):
			var x: float = columns[col]
			var edge := row == 0 or row == row_z.size()-1 or col == 0 or col == columns.size()-1
			var z: float = row_z[row] + (0.0 if edge else sin(float(col) * 2.3 + float(row)) * 0.13)
			var h: float = peak_heights[col] * profiles[row] * (1.0 if snowy else 0.69)
			if not edge: x += sin(float(col * 3 + row)) * 0.12
			strip.append(Vector3(x, h, z))
		vertices.append(strip)
	var surfaces: Array[SurfaceTool] = []
	var palette: Array[StandardMaterial3D] = []
	for spec in [["Blue slate", "7c8e99"], ["Cool limestone", "9aa6ab"], ["Snow shadow", "c6d4d7"], ["Snow summit", "e3e8df"], ["Warm sandstone", "bf8c61"], ["Ochre face", "aa7351"], ["Sandstone highlight", "d6a675"]]:
		surfaces.append(_new_surface())
		palette.append(_material(spec[0], spec[1]))
	var counts := [0,0,0,0,0,0,0]
	for row in range(row_z.size()-1):
		for col in range(columns.size()-1):
			var a: Vector3 = vertices[row][col]
			var b: Vector3 = vertices[row+1][col]
			var c: Vector3 = vertices[row+1][col+1]
			var d: Vector3 = vertices[row][col+1]
			var triangles := [[a,b,d],[b,c,d]] if (row+col)%2 == 0 else [[a,b,c],[a,c,d]]
			for triangle in triangles:
				var center: Vector3 = (triangle[0]+triangle[1]+triangle[2])/3.0
				var index := (row+col)%2 if snowy else 4+(row+col)%3
				if snowy and center.y > 1.25 + sin(center.x*3.0)*0.13: index = 2+(row+col)%2
				_triangle(surfaces[index],triangle[0],triangle[1],triangle[2])
				counts[index] += 1
	for i in range(surfaces.size()):
		if counts[i] > 0: _mesh(root, palette[i].resource_name, surfaces[i], palette[i])
	# Foot rocks connect the erosion fans to the larger ridge.
	for spec in [Vector3(-1.45,0,0.94), Vector3(0.52,0,1.01), Vector3(1.76,0,-0.82)]:
		var rock := _rock_mesh(Vector3(0.29,0.27,0.23), "a6a89b" if snowy else "ba8c67", 7)
		rock.position = spec
		root.add_child(rock)
	return root

static func _outline(radius: float, seed_value: int, count: int = 18) -> PackedVector3Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var points := PackedVector3Array()
	for i in range(count):
		var angle := TAU * float(i) / float(count)
		var distance := radius * rng.randf_range(0.88, 1.05)
		points.append(Vector3(cos(angle)*distance, 0, sin(angle)*distance*0.78))
	return points

static func _patch(water: bool) -> Node3D:
	var root := Node3D.new()
	root.name = "WaterPatch" if water else "GrassPatch"
	var points := _outline(1.80, 18)
	var top := _new_surface()
	var side := _new_surface()
	var y := 0.055 if water else 0.095
	for i in range(points.size()):
		var a := points[i]
		var b := points[(i+1)%points.size()]
		_triangle(top, Vector3(0,y,0), b+Vector3.UP*y, a+Vector3.UP*y)
		_quad(side,a,b,b+Vector3.UP*y,a+Vector3.UP*y)
	_mesh(root,"Water surface" if water else "Grass top",top,_material("Quiet turquoise water" if water else "Muted jade grass", "4eaba9" if water else "84955d",0.45 if water else 0.96))
	_mesh(root,"Patch edge",side,_material("Water depth" if water else "Soil edge", "367e87" if water else "a58a60"))
	if water:
		var ripple := _new_surface()
		for spec in [Vector3(-0.60,y+0.002,-0.27),Vector3(0.42,y+0.002,0.38),Vector3(0.22,y+0.002,-0.66)]:
			_quad(ripple,spec+Vector3(-0.20,0,-0.018),spec+Vector3(-0.20,0,0.018),spec+Vector3(0.20,0,0.018),spec+Vector3(0.20,0,-0.018))
		_mesh(root,"Quiet water highlights",ripple,_material("Soft wave crests","99cdc0"))
	return root

static func _coast() -> Node3D:
	var root := Node3D.new()
	root.name = "SculptedCoast"
	var land := _new_surface()
	var shore := _new_surface()
	var shallow := _new_surface()
	var water := _new_surface()
	var beach := [Vector3(-1.9,0.22,-0.12),Vector3(-1.25,0.22,0.12),Vector3(-0.68,0.22,-0.05),Vector3(0,0.22,-0.33),Vector3(0.59,0.22,-0.15),Vector3(1.26,0.22,0.20),Vector3(1.9,0.22,0.38)]
	for i in range(beach.size()-1):
		var a:Vector3=beach[i]
		var b:Vector3=beach[i+1]
		var sa:=a+Vector3(0,-0.17,0.28)
		var sb:=b+Vector3(0,-0.17,0.28)
		var wa:=a+Vector3(0,-0.185,0.53)
		var wb:=b+Vector3(0,-0.185,0.53)
		_quad(land,Vector3(a.x,0.22,-1.2),a,b,Vector3(b.x,0.22,-1.2))
		_quad(shore,a,sa,sb,b)
		_quad(shallow,sa,wa,wb,sb)
		_quad(water,wa,Vector3(a.x,0.035,1.28),Vector3(b.x,0.035,1.28),wb)
	_mesh(root,"Warm raised shore",land,_material("Dry coastal sand","c8b588"))
	_mesh(root,"Bevelled water bank",shore,_material("Wet ivory sand","ded0aa"))
	_mesh(root,"Clear turquoise shallows",shallow,_material("Shallow water","79bdb3",0.54))
	_mesh(root,"Deeper water",water,_material("Harbour water","489b9f",0.48))
	for spec in [Vector3(-1.3,0.22,-0.4),Vector3(1.18,0.22,-0.08)]:
		var stone:=_rock_mesh(Vector3(0.20,0.17,0.15),"b4b4a0",11)
		stone.position=spec
		root.add_child(stone)
	return root

static func _rock_mesh(size: Vector3, color: String, seed_value: int) -> Node3D:
	var root := Node3D.new()
	root.name = "WeatheredRock"
	var surface := _new_surface()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var rings: Array[PackedVector3Array] = []
	for level in range(3):
		var ring:=PackedVector3Array()
		for i in range(7):
			var angle:=TAU*float(i)/7.0+float(level)*0.13
			var radius:float=[0.89,1.0,0.56][level]*rng.randf_range(0.90,1.1)
			ring.append(Vector3(cos(angle)*size.x*radius,float(level)*size.y*0.46,sin(angle)*size.z*radius))
		rings.append(ring)
	for i in range(7):
		for level in range(2):
			_quad(surface,rings[level][i],rings[level+1][i],rings[level+1][(i+1)%7],rings[level][(i+1)%7])
		_triangle(surface,Vector3(0,size.y,0),rings[2][(i+1)%7],rings[2][i])
	_mesh(root,"Faceted rock",surface,_material("Weathered stone",color))
	return root

static func _rocks() -> Node3D:
	var root:=Node3D.new()
	root.name="RockOutcrop"
	var main:=_rock_mesh(Vector3(0.49,0.67,0.41),"a69b80",16)
	main.position=Vector3(-0.12,0,-0.07)
	root.add_child(main)
	var small:=_rock_mesh(Vector3(0.27,0.35,0.29),"b9ae8d",21)
	small.position=Vector3(0.34,0,0.25)
	root.add_child(small)
	return root
