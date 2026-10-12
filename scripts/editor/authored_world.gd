extends Node3D
## Adapter for authored presentation JSON; never changes GameState content.
const Catalog := preload("res://scripts/editor/map_asset_catalog.gd")
var layout: Dictionary = {}
var anchors: Dictionary = {}
var routes: Dictionary = {}
var cities: Dictionary = {}
var _models: Array[Node3D] = []
var _ground: StandardMaterial3D

func build(content: Dictionary) -> void:
	anchors.clear()
	routes.clear()
	cities.clear()
	var board: Dictionary = layout.get("board", {"width":60.0, "depth":20.0})
	var plane := MeshInstance3D.new()
	plane.name = "EditableBoardSurface"
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := BoxMesh.new()
	mesh.size = Vector3(float(board.width), 0.36, float(board.depth))
	plane.mesh = mesh
	plane.position.y = -0.19
	_ground = _mat(Color("cab58e"))
	plane.material_override = _ground
	add_child(plane)
	for entry in layout.get("cities", []):
		var model: Node3D = Catalog.create(str(entry.asset_id))
		if model == null: continue
		_place(model, entry)
		var entrance: Vector3 = model.transform * model.get_meta("entrance", Vector3(0, 0, 1.22))
		var node_id := str(entry.get("node_id", ""))
		if not node_id.is_empty(): anchors[node_id] = entrance
		var city_id := str(entry.get("city_id", ""))
		if not city_id.is_empty(): cities[city_id] = {"root":model,"bounds":_bounds(model),"anchor":entrance}
	for entry in layout.get("logic_nodes", []):
		var node_id := str(entry.get("node_id", ""))
		if not node_id.is_empty(): anchors[node_id] = _v3(entry.position)
	for entry in layout.get("decorations", []):
		var model: Node3D = Catalog.create(str(entry.asset_id))
		if model != null: _place(model, entry)
	var formal_edges := {}
	for edge in content.get("board_edges", []): formal_edges[str(edge.id)] = edge
	for route in layout.get("routes", []):
		var a := str(route.get("from_node", ""))
		var b := str(route.get("to_node", ""))
		if not anchors.has(a) or not anchors.has(b): continue
		var samples := PackedVector3Array([anchors[a]])
		for point in route.get("points", []): samples.append(_v3(point))
		samples.append(anchors[b])
		var edge_id := str(route.get("edge_id", ""))
		if not edge_id.is_empty():
			# Normalize cache direction; inherited path traversal can reverse this
			# again when a player travels from the formal edge b to edge a.
			if formal_edges.has(edge_id) and a != str(formal_edges[edge_id].a): samples.reverse()
			routes[edge_id] = samples
		_draw_route(samples, str(route.get("type", "land")) == "sea")
	set_night(bool(layout.get("visual_settings", {}).get("night", false)))

func _place(model: Node3D, entry: Dictionary) -> void:
	model.name = str(entry.get("id", "Asset"))
	model.position = _v3(entry.position)
	model.rotation.y = float(entry.get("rotation_y", 0))
	model.scale = Vector3.ONE * float(entry.get("scale", 1))
	add_child(model)
	_models.append(model)

func _bounds(model: Node3D) -> AABB:
	var minimum := Vector3.INF
	var maximum := -Vector3.INF
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = child.get_aabb()
		var tx: Transform3D = model.global_transform.affine_inverse() * child.global_transform
		for index in range(8):
			var point := tx * box.get_endpoint(index)
			minimum = minimum.min(point)
			maximum = maximum.max(point)
	if not minimum.is_finite(): return AABB(Vector3(-0.5,0,-0.5),Vector3.ONE)
	return AABB(minimum, maximum - minimum)

func _draw_route(samples: PackedVector3Array, sea: bool) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(1, samples.size()):
		var a := samples[index - 1] + Vector3.UP * 0.045
		var b := samples[index] + Vector3.UP * 0.045
		var side := Vector3(-(b.z - a.z), 0, b.x - a.x).normalized() * (0.065 if sea else 0.10)
		var count := maxi(1, ceili(a.distance_to(b) / 0.40)) if sea else 1
		for part in range(count):
			var start := a.lerp(b, float(part) / count)
			var finish := a.lerp(b, minf(1.0, (float(part) + (0.6 if sea else 1.0)) / count))
			for point in [start-side, finish-side, start+side, start+side, finish-side, finish+side]:
				st.set_normal(Vector3.UP)
				st.add_vertex(point)
	var instance := MeshInstance3D.new()
	instance.name = "SeaRoute" if sea else "LandRoute"
	instance.mesh = st.commit()
	instance.material_override = _mat(Color("487e9c") if sea else Color("ead7ad"))
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)

func _mat(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _v3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func surface_height(_x: float, _z: float) -> float:
	return 0.0

func set_night(night: bool) -> void:
	for model in _models:
		Catalog.set_night(model, night)
