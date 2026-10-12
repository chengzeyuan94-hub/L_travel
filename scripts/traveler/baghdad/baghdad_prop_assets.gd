extends RefCounted
## Static Baghdad props: retain every imported mesh, surface and material.
## Position uses the viewer's stage coordinates; yaw follows its asset convention.

var _viewer: Node3D
var _stage_to_world := Transform3D.IDENTITY
var _sources: Dictionary = {}
var _placements: Array[Dictionary] = []

func configure(viewer: Node3D) -> void:
	_viewer = viewer
	var origin: Vector3 = viewer.stage_point(Vector3.ZERO)
	_stage_to_world = Transform3D(Basis(
		viewer.stage_point(Vector3.RIGHT) - origin,
		viewer.stage_point(Vector3.UP) - origin,
		viewer.stage_point(Vector3.BACK) - origin), origin)

func place(entry: Dictionary, parent: Node3D) -> Node3D:
	var path := str(entry.get("asset", ""))
	var resource := _source(path)
	if resource.is_empty():
		return null
	var bounds: AABB = resource.bounds
	var scale_value := 1.0
	if entry.has("height_u"):
		scale_value = float(entry.height_u) / maxf(bounds.size.y, 0.000001)
	elif entry.has("width_u"):
		scale_value = float(entry.width_u) / maxf(bounds.size.x, 0.000001)
	if scale_value <= 0.0:
		push_error("Baghdad prop scale must be positive: " + path)
		return null
	var pivot_name := str(entry.get("pivot", "bottom"))
	var pivot := bounds.get_center()
	if pivot_name == "bottom":
		pivot.y = bounds.position.y
	elif pivot_name != "center":
		push_error("Baghdad prop pivot must be bottom or center: " + path)
		return null
	var stage_position := _vector(entry.get("position", [0.0, 0.0, 0.0]))
	var anchor := _vector(entry.get("anchor_world", Vector3.ZERO))
	var has_anchor := entry.has("anchor_world")
	var position_world := _stage_to_world * stage_position
	if has_anchor:
		# An anchored prop's authored position is an offset, not another origin.
		position_world = anchor + _stage_to_world.basis * stage_position
	var ground_snap := bool(entry.get("ground_snap", not has_anchor))
	var surface: Object = _viewer.get("ground_surface")
	var contact_stage := _stage_to_world.affine_inverse() * position_world
	var contact_height := 0.0
	if ground_snap and surface != null and surface.has_method("height_at"):
		contact_height = float(surface.height_at(Vector2(contact_stage.x, contact_stage.z)))
		position_world.y += contact_height
	position_world.y -= float(entry.get("bury_u", 0.0))
	var root := Node3D.new()
	root.name = str(entry.get("id", entry.get("name", "ImportedProp")))
	var yaw := float(entry.get("yaw_deg", 0.0))
	var desired := Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)).scaled(Vector3.ONE * scale_value), position_world)
	# Parent can still be detached while supporting_props builds its root.
	root.transform = _accumulated_transform(parent).affine_inverse() * desired
	parent.add_child(root)
	var shadows := bool(entry.get("shadow", false))
	var mesh_index := 0
	for component: Dictionary in resource.components:
		var node := MeshInstance3D.new()
		node.name = "OriginalMesh_%02d_%s" % [mesh_index, str(component.name)]
		node.mesh = component.mesh
		node.transform = Transform3D(Basis.IDENTITY, -pivot) * component.transform
		node.material_override = component.material_override
		node.material_overlay = component.material_overlay
		node.visible = bool(component.visible)
		for surface_index in node.mesh.get_surface_count():
			var override_material: Material = component.surface_overrides[surface_index]
			if override_material != null:
				node.set_surface_override_material(surface_index, override_material)
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(node)
		mesh_index += 1
	root.set_meta("scaled_bounds", AABB((bounds.position - pivot) * scale_value, bounds.size * scale_value))
	root.set_meta("prop_asset_placement", {
		"source": path, "height_u": bounds.size.y * scale_value,
		"width_u": bounds.size.x * scale_value, "uniform_scale": scale_value,
		"world_position": position_world, "pivot": pivot_name
	})
	_placements.append({
		"node": root, "source": path, "entry": entry.duplicate(true),
		"uniform_scale": scale_value, "pivot_source_u": _array(pivot),
		"height_u": bounds.size.y * scale_value,
		"width_u": bounds.size.x * scale_value,
		"depth_u": bounds.size.z * scale_value,
		"ground_snap": ground_snap, "ground_contact_height_u": contact_height,
		"shadow": shadows,
		"normalized_bounds": AABB(bounds.position - pivot, bounds.size)
	})
	return root

func evidence() -> Dictionary:
	var sources: Array[Dictionary] = []
	for path in _sources:
		sources.append(_sources[path].stats.duplicate(true))
	var records: Array[Dictionary] = []
	var triangles := 0
	var surfaces := 0
	for placement in _placements:
		var node: Node3D = placement.node
		if not is_instance_valid(node):
			continue
		var record: Dictionary = placement.duplicate(true)
		record.erase("node")
		record.erase("normalized_bounds")
		var config: Dictionary = record.entry
		if config.has("anchor_world"):
			config.anchor_world = _array(_vector(config.anchor_world))
		record["world_position"] = _array(_accumulated_transform(node).origin)
		record["stage_position_effective"] = _array(_stage_to_world.affine_inverse() * _accumulated_transform(node).origin)
		var stats: Dictionary = _sources[placement.source].stats
		record["mesh_count"] = stats.mesh_count
		record["surface_count"] = stats.surface_count
		record["triangles"] = stats.triangles
		triangles += int(stats.triangles)
		surfaces += int(stats.surface_count)
		if node.is_inside_tree() and _viewer.has_method("projected_bounds"):
			record["projected"] = _viewer.projected_bounds(node)
		record["ground_footprint"] = _ground_footprint(node, placement.normalized_bounds)
		records.append(record)
	return {
		"original_geometry_preserved": true, "source_materials_preserved": true,
		"all_source_meshes_and_surfaces_preserved": true,
		"source_count": sources.size(), "instance_count": records.size(),
		"triangles_all_instances": triangles, "surfaces_all_instances": surfaces,
		"sources": sources, "placements": records,
		"note": "Static imported props. No decimation, texture edits, particle motion or added lights."
	}

func _source(path: String) -> Dictionary:
	if _sources.has(path):
		return _sources[path]
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("Missing Baghdad prop asset: " + path)
		return {}
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("Baghdad prop must be an imported scene: " + path)
		return {}
	var scene := packed.instantiate()
	var components: Array[Dictionary] = []
	_collect_meshes(scene, Transform3D.IDENTITY, true, components)
	if components.is_empty():
		scene.free()
		push_error("Baghdad prop contains no meshes: " + path)
		return {}
	var bounds: AABB = components[0].transform * components[0].mesh.get_aabb()
	var meshes: Array[Dictionary] = []
	var triangles := 0
	var surface_count := 0
	for component: Dictionary in components:
		var mesh: Mesh = component.mesh
		bounds = bounds.merge(component.transform * mesh.get_aabb())
		var surface_stats: Array[Dictionary] = []
		for index in mesh.get_surface_count():
			var indices: int = mesh.surface_get_array_index_len(index)
			var vertices: int = mesh.surface_get_array_len(index)
			var count: int = indices if indices > 0 else vertices
			var primitive: int = mesh.surface_get_primitive_type(index)
			var triangle_count := 0
			if primitive == Mesh.PRIMITIVE_TRIANGLES:
				triangle_count = int(count / 3)
			elif primitive == Mesh.PRIMITIVE_TRIANGLE_STRIP:
				triangle_count = maxi(count - 2, 0)
			triangles += triangle_count
			var material: Material = component.active_materials[index]
			surface_stats.append({"surface": index, "vertices": vertices,
				"indices": indices, "triangles": triangle_count,
				"primitive": primitive, "material": _material_evidence(material)})
		meshes.append({"name": component.name, "surface_count": mesh.get_surface_count(),
			"source_transform": _transform_evidence(component.transform), "surfaces": surface_stats,
			"visible": component.visible})
		surface_count += mesh.get_surface_count()
	var stats := {"source": path, "mesh_count": components.size(),
		"surface_count": surface_count, "triangles": triangles,
		"bounds_source": {"position": _array(bounds.position), "size": _array(bounds.size)},
		"meshes": meshes}
	var result := {"components": components, "bounds": bounds, "stats": stats}
	_sources[path] = result
	scene.free()
	return result

func _collect_meshes(node: Node, parent_transform: Transform3D, parent_visible: bool, result: Array[Dictionary]) -> void:
	var current := parent_transform
	var visible := parent_visible
	if node is Node3D:
		current = parent_transform * (node as Node3D).transform
		visible = parent_visible and (node as Node3D).visible
	if node is MeshInstance3D:
		var source := node as MeshInstance3D
		if source.mesh != null:
			var surface_overrides: Array[Material] = []
			var active_materials: Array[Material] = []
			for index in source.mesh.get_surface_count():
				surface_overrides.append(source.get_surface_override_material(index))
				active_materials.append(source.get_active_material(index))
			result.append({"name": str(source.name), "mesh": source.mesh,
				"transform": current, "visible": visible,
				"material_override": source.material_override,
				"material_overlay": source.material_overlay,
				"surface_overrides": surface_overrides, "active_materials": active_materials})
	for child in node.get_children():
		_collect_meshes(child, current, visible, result)

func _ground_footprint(node: Node3D, normalized_bounds: AABB) -> Dictionary:
	var world_bounds: AABB = _accumulated_transform(node) * normalized_bounds
	var stage_bounds: AABB = _stage_to_world.affine_inverse() * world_bounds
	var report := {
		"stage_x_range_u": [stage_bounds.position.x, stage_bounds.end.x],
		"stage_z_range_u": [stage_bounds.position.z, stage_bounds.end.z],
		"world_y_range_u": [world_bounds.position.y, world_bounds.end.y],
		"method": "Conservative transformed source AABB; terrain sampled on a 5 by 5 footprint grid."
	}
	var surface: Object = _viewer.get("ground_surface")
	if surface == null or not surface.has_method("height_at"):
		return report
	var minimum := INF
	var maximum := -INF
	for row in 5:
		for column in 5:
			var point := Vector2(
				lerpf(stage_bounds.position.x, stage_bounds.end.x, float(column) / 4.0),
				lerpf(stage_bounds.position.z, stage_bounds.end.z, float(row) / 4.0))
			var height := float(surface.height_at(point))
			minimum = minf(minimum, height)
			maximum = maxf(maximum, height)
	report["terrain_height_range_u"] = [minimum, maximum]
	report["bottom_minus_terrain_range_u"] = [world_bounds.position.y - maximum, world_bounds.position.y - minimum]
	report["terrain_samples"] = 25
	return report

func _material_evidence(material: Material) -> Dictionary:
	if material == null:
		return {"present": false}
	var report := {"present": true, "type": material.get_class(), "resource_path": material.resource_path}
	if material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		report["basecolor_texture"] = base.albedo_texture.resource_path if base.albedo_texture != null else ""
		report["normal_texture"] = base.normal_texture.resource_path if base.normal_texture != null else ""
		report["normal_enabled"] = base.normal_enabled
		report["roughness"] = base.roughness
		report["metallic"] = base.metallic
	return report

func _accumulated_transform(node: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result

func _vector(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _transform_evidence(value: Transform3D) -> Dictionary:
	return {"origin": _array(value.origin), "basis": [_array(value.basis.x), _array(value.basis.y), _array(value.basis.z)]}
