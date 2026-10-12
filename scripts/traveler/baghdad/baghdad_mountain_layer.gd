extends RefCounted
## Static desert mountain bands for the Baghdad composition.
##
## The supplied GLB geometry and textures are kept intact.  Each source is
## normalized around its bottom centre, then placed in authored stage space;
## only the optional far-band tint is a material duplicate that preserves the
## original albedo texture.  The terrain builder supplies the contact height
## so the mountain foot does not float above the dune surface.

var _viewer: Node3D
var _root: Node3D
var _sources: Dictionary = {}
var _placements: Array[Dictionary] = []

func configure(viewer: Node3D) -> void:
	_viewer = viewer

func build() -> Node3D:
	_root = Node3D.new()
	_root.name = "BaghdadMountainBands"
	var config: Dictionary = _viewer.settings.get("mountains", {})
	for item in config.get("layers", []):
		if item is Dictionary:
			_place(item)
	return _root

func _place(entry: Dictionary) -> void:
	var path := str(entry.get("asset", ""))
	var source: Dictionary = _source(path)
	if source.is_empty():
		return
	var bounds: AABB = source.bounds
	var height_u := maxf(float(entry.get("height_u", 8.0)), 0.01)
	var scale_value := height_u / maxf(bounds.size.y, 0.000001)
	var stage_position := _vector(entry.get("stage_position", [0.0, 0.0, 80.0]))
	var surface: Object = _viewer.get("ground_surface")
	var terrain_height := 0.0
	if surface != null and surface.has_method("height_at"):
		terrain_height = float(surface.height_at(Vector2(stage_position.x, stage_position.z)))
	# bury_u follows the same convention as supporting props: positive values
	# sink the foot slightly into the sampled dune instead of lifting it.
	stage_position.y = terrain_height - float(entry.get("bury_u", 0.0))

	var layer := Node3D.new()
	layer.name = str(entry.get("id", "MountainBand"))
	layer.position = _viewer.stage_point(stage_position)
	layer.rotation.y = deg_to_rad(float(entry.get("yaw_deg", 0.0)))
	layer.scale = Vector3.ONE * scale_value
	_root.add_child(layer)
	var pivot := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
	var fog_mix := clampf(float(entry.get("far_tint_mix", 0.0)), 0.0, 1.0)
	var fog_tint := _color(entry.get("far_tint", [0.78, 0.73, 0.72]))
	for component: Dictionary in source.components:
		var mesh_node := MeshInstance3D.new()
		mesh_node.name = "OriginalMesh_%02d" % int(component.index)
		mesh_node.mesh = component.mesh
		mesh_node.transform = Transform3D(Basis.IDENTITY, -pivot) * component.transform
		var original: Material = component.material
		if fog_mix > 0.0 and original is BaseMaterial3D:
			var material := (original as BaseMaterial3D).duplicate() as BaseMaterial3D
			# Keep the source texture and material type; this only eases contrast on
			# the farthest bands before the scene's depth fog is applied.
			material.albedo_color = material.albedo_color.lerp(fog_tint, fog_mix)
			mesh_node.material_override = material
		else:
			mesh_node.material_override = original
		mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		layer.add_child(mesh_node)
	var placement := {
		"id": layer.name,
		"asset": path,
		"stage_position": [stage_position.x, stage_position.y, stage_position.z],
		"yaw_deg": float(entry.get("yaw_deg", 0.0)),
		"height_u": bounds.size.y * scale_value,
		"width_u": bounds.size.x * scale_value,
		"depth_u": bounds.size.z * scale_value,
		"terrain_contact_height_u": terrain_height,
		"far_tint_mix": fog_mix,
		"source_triangles": int(source.triangles),
		"original_geometry_preserved": true,
		"source_materials_preserved": true
	}
	layer.set_meta("mountain_placement", placement)
	_placements.append(placement)

func _source(path: String) -> Dictionary:
	if _sources.has(path):
		return _sources[path]
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("Missing Baghdad mountain asset: " + path)
		return {}
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("Baghdad mountain must be an imported scene: " + path)
		return {}
	var scene := packed.instantiate()
	var components: Array[Dictionary] = []
	_collect_meshes(scene, Transform3D.IDENTITY, components)
	if components.is_empty():
		scene.free()
		push_error("Baghdad mountain contains no meshes: " + path)
		return {}
	var bounds: AABB
	var first := true
	var triangles := 0
	for component: Dictionary in components:
		var box: AABB = component.transform * component.mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
		for surface in component.mesh.get_surface_count():
			var index_count: int = component.mesh.surface_get_array_index_len(surface)
			if index_count == 0:
				index_count = component.mesh.surface_get_array_len(surface)
			triangles += int(index_count / 3)
	for i in components.size():
		components[i]["index"] = i
	scene.free()
	var result := {"components": components, "bounds": bounds, "triangles": triangles}
	_sources[path] = result
	return result

func _collect_meshes(node: Node, parent_transform: Transform3D, result: Array[Dictionary]) -> void:
	var current := parent_transform
	if node is Node3D:
		current = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var source := node as MeshInstance3D
		if source.mesh != null:
			result.append({"mesh": source.mesh, "transform": current, "material": source.get_active_material(0)})
	for child in node.get_children():
		_collect_meshes(child, current, result)

func evidence() -> Dictionary:
	return {
		"layer_count": _placements.size(),
		"source_count": _sources.size(),
		"placements": _placements.duplicate(true),
		"depth_order": "mountain bands are behind TreeOfLife and Baghdad skyline; stage z increases away from camera",
		"contact_method": "ground_surface.height_at(stage x,z), root y placed at sampled dune height",
		"material_method": "source mesh and albedo textures retained; optional far_tint_mix duplicates BaseMaterial3D without changing texture",
		"shadow_casting": false
	}

func _vector(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _color(value: Variant) -> Color:
	if value is Color:
		return value
	return Color(float(value[0]), float(value[1]), float(value[2]))
