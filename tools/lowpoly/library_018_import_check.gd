extends SceneTree
## Read-only GLTFDocument import check, intentionally run in a headless scratch project.
## Required env: SILKROAD_LIBRARY_ROOT, SILKROAD_LIBRARY_AUDIT,
## SILKROAD_LIBRARY_IMPORT_OUTPUT. Optional SILKROAD_LIBRARY_IDS is a comma list.
## This is geometry/material data verification, not a rendering/performance claim.

var library: String
var output: String
var audit_path: String
var expected := {}
var report := {"task": "TASK-TERRAIN-LIBRARY-018", "assets": [], "checks": [], "errors": []}
var stage: Node3D

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, passed: bool, detail: Variant = null) -> void:
	report["checks"].append({"name": name, "passed": passed, "detail": detail})
	if not passed:
		report["errors"].append({"name": name, "detail": detail})

func _v(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _finite(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _run() -> void:
	library = OS.get_environment("SILKROAD_LIBRARY_ROOT")
	audit_path = OS.get_environment("SILKROAD_LIBRARY_AUDIT")
	output = OS.get_environment("SILKROAD_LIBRARY_IMPORT_OUTPUT")
	if library.is_empty() or audit_path.is_empty() or output.is_empty() or DisplayServer.get_name() != "headless":
		push_error("Import check requires explicit external paths and --headless")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var raw_audit := FileAccess.get_file_as_string(audit_path)
	var audit: Variant = JSON.parse_string(raw_audit)
	if not audit is Dictionary or not audit.has("assets"):
		push_error("Readable source-bound geometry-audit.json required")
		quit(2)
		return
	for entry in audit["assets"]:
		expected[str(entry["id"])] = entry
	var script_path: String = get_script().resource_path
	var script_sha := FileAccess.get_sha256(script_path)
	var audit_sha := FileAccess.get_sha256(audit_path)
	var allowed := OS.get_environment("SILKROAD_LIBRARY_IDS").split(",", false)
	var names := DirAccess.get_files_at(library.path_join("exports"))
	names.sort()
	var selected: Array[String] = []
	var inputs_before := {}
	for filename in names:
		if not filename.ends_with(".glb") or filename.contains("-"):
			continue
		var id := filename.get_basename()
		if not allowed.is_empty() and not id in allowed:
			continue
		selected.append(filename)
		inputs_before[id] = FileAccess.get_sha256(library.path_join("exports").path_join(filename))
	report["godot"] = Engine.get_version_info()
	report["display"] = DisplayServer.get_name()
	report["script_sha256"] = script_sha
	report["geometry_audit"] = audit_path
	report["geometry_audit_sha256"] = audit_sha
	report["partial"] = not allowed.is_empty()
	report["method"] = "Fresh GLTFDocument per actual external GLB, flags=64 as the studio capture uses; imported ArrayMesh arrays and scene transforms are inspected. COLOR_0 adapter is tested only in memory. No graphics, frame-time, or visual-equivalence claim."
	_check("selected_independent_count", selected.size() == (24 if allowed.is_empty() else allowed.size()), selected.size())
	stage = Node3D.new()
	root.add_child(stage)
	for filename in selected:
		await _asset(filename.get_basename(), library.path_join("exports").path_join(filename))
	var inputs_after := {}
	for filename in selected:
		inputs_after[filename.get_basename()] = FileAccess.get_sha256(library.path_join("exports").path_join(filename))
	_check("all_inputs_stable_start_to_end", inputs_before == inputs_after, {"start": inputs_before, "end": inputs_after})
	_check("geometry_audit_stable", audit_sha == FileAccess.get_sha256(audit_path), audit_sha)
	_check("checker_stable", script_sha == FileAccess.get_sha256(script_path), script_sha)
	report["asset_count"] = report["assets"].size()
	report["total_triangles"] = 0
	report["total_surfaces"] = 0
	report["color_surfaces_requiring_enablement"] = 0
	for entry in report["assets"]:
		report["total_triangles"] += entry.get("triangles", 0)
		report["total_surfaces"] += entry.get("surfaces", 0)
		report["color_surfaces_requiring_enablement"] += entry.get("color_surfaces_requiring_enablement", 0)
	report["passed"] = report["checks"].size() - report["errors"].size()
	report["total"] = report["checks"].size()
	var file := FileAccess.open(output.path_join("godot-import-report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("LIBRARY_018_IMPORT_CHECK ", report["passed"], "/", report["total"], " assets=", report["asset_count"], " triangles=", report["total_triangles"])
	quit(0 if report["errors"].is_empty() else 1)

func _asset(id: String, path: String) -> void:
	var before := FileAccess.get_sha256(path)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var import_error := doc.append_from_file(path, state, 64)
	_check(id + ":append_from_file", import_error == OK, import_error)
	if import_error != OK:
		return
	var instance := doc.generate_scene(state)
	_check(id + ":generate_scene", instance != null, null)
	if instance == null:
		return
	stage.add_child(instance)
	var points: Array[Vector3] = []
	var mesh_count := 0
	var surfaces := 0
	var triangles := 0
	var color_surfaces := 0
	var needs_color_enablement := 0
	var surface_rows := []
	var queue: Array[Node] = [instance]
	var hierarchy_valid := true
	var arrays_valid := true
	var materials_valid := true
	var minimum_area2 := INF
	var invalid_nodes: Array[String] = []
	while not queue.is_empty():
		var node: Node = queue.pop_back()
		for child in node.get_children():
			queue.append(child)
		if node is Camera3D or node is Light3D:
			hierarchy_valid = false
			invalid_nodes.append(str(node.name))
		if node is Node3D:
			var transform: Transform3D = node.global_transform
			hierarchy_valid = hierarchy_valid and _finite(transform.origin) and _finite(transform.basis.x) and _finite(transform.basis.y) and _finite(transform.basis.z)
			hierarchy_valid = hierarchy_valid and transform.basis.determinant() > 0.0
			for axis in [transform.basis.x, transform.basis.y, transform.basis.z]:
				hierarchy_valid = hierarchy_valid and absf(axis.length() - 1.0) < 0.00001
		if not node is MeshInstance3D:
			continue
		mesh_count += 1
		var mesh: Mesh = node.mesh
		if mesh == null:
			arrays_valid = false
			continue
		for surface in range(mesh.get_surface_count()):
			surfaces += 1
			var arrays: Array = mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var colors: Variant = arrays[Mesh.ARRAY_COLOR]
			arrays_valid = arrays_valid and mesh.surface_get_primitive_type(surface) == Mesh.PRIMITIVE_TRIANGLES and vertices.size() > 0 and normals.size() == vertices.size()
			var world: Array[Vector3] = []
			for i in range(vertices.size()):
				var vertex: Vector3 = node.global_transform * vertices[i]
				world.append(vertex)
				points.append(vertex)
				arrays_valid = arrays_valid and _finite(vertex)
				if i < normals.size():
					arrays_valid = arrays_valid and _finite(normals[i]) and absf(normals[i].length() - 1.0) < 0.015
			var count := indices.size() if not indices.is_empty() else vertices.size()
			arrays_valid = arrays_valid and count % 3 == 0
			var surface_triangles := int(count / 3)
			triangles += surface_triangles
			for triangle in range(surface_triangles):
				var a: int = indices[3 * triangle] if not indices.is_empty() else 3 * triangle
				var b: int = indices[3 * triangle + 1] if not indices.is_empty() else 3 * triangle + 1
				var c: int = indices[3 * triangle + 2] if not indices.is_empty() else 3 * triangle + 2
				if mini(a, mini(b, c)) < 0 or maxi(a, maxi(b, c)) >= world.size():
					arrays_valid = false
					continue
				var area2: float = (world[b] - world[a]).cross(world[c] - world[a]).length()
				minimum_area2 = minf(minimum_area2, area2)
				arrays_valid = arrays_valid and is_finite(area2) and area2 > 0.0000000001
			var row := {"mesh": str(node.name), "surface": surface, "vertices": vertices.size(), "triangles": surface_triangles}
			var material: Material = mesh.surface_get_material(surface)
			row["material_class"] = "null" if material == null else material.get_class()
			row["material_name"] = "" if material == null else material.resource_name
			materials_valid = materials_valid and material is StandardMaterial3D
			var color_count: int = 0 if colors == null else colors.size()
			row["vertex_color_count"] = color_count
			if color_count > 0:
				color_surfaces += 1
				arrays_valid = arrays_valid and color_count == vertices.size()
				var minimum := Color(1, 1, 1, 1)
				var maximum := Color(0, 0, 0, 0)
				for color in colors:
					for channel in range(4):
						arrays_valid = arrays_valid and is_finite(color[channel]) and color[channel] >= 0.0 and color[channel] <= 1.0
						minimum[channel] = minf(minimum[channel], color[channel])
						maximum[channel] = maxf(maximum[channel], color[channel])
				row["color_min"] = [minimum.r, minimum.g, minimum.b, minimum.a]
				row["color_max"] = [maximum.r, maximum.g, maximum.b, maximum.a]
				if material is StandardMaterial3D:
					row["raw_vertex_color_use_as_albedo"] = material.vertex_color_use_as_albedo
					row["raw_vertex_color_is_srgb"] = material.vertex_color_is_srgb
					var needed: bool = not material.vertex_color_use_as_albedo or material.vertex_color_is_srgb
					if needed:
						needs_color_enablement += 1
					var adapted := material.duplicate() as StandardMaterial3D
					adapted.vertex_color_use_as_albedo = true
					adapted.vertex_color_is_srgb = false
					# A headless dummy renderer has no shader RID to bind. Verify the
					# copied material's actual flags; assignment/rendering is covered
					# by the separate real-window studio, not claimed by this check.
					row["in_memory_color_adapter_verified"] = adapted.vertex_color_use_as_albedo and not adapted.vertex_color_is_srgb
					materials_valid = materials_valid and row["in_memory_color_adapter_verified"]
			surface_rows.append(row)
	_check(id + ":hierarchy_finite_positive_scale_no_studio", hierarchy_valid, invalid_nodes)
	_check(id + ":actual_mesh_arrays_finite_valid_triangles_normals_colors", arrays_valid and mesh_count > 0, {"minimum_triangle_area2": minimum_area2})
	_check(id + ":materials_and_color_adapter", materials_valid, {"color_surfaces": color_surfaces, "requiring_enablement": needs_color_enablement})
	var row := {"id": id, "glb": path, "sha256_start": before, "mesh_count": mesh_count, "surfaces": surfaces, "triangles": triangles, "vertex_color_surfaces": color_surfaces, "color_surfaces_requiring_enablement": needs_color_enablement, "surface_data": surface_rows}
	if not points.is_empty():
		var bounds := AABB(points[0], Vector3.ZERO)
		for point in points:
			bounds = bounds.expand(point)
		var low := bounds.position
		var high := bounds.end
		var feet: Array[Vector3] = []
		for point in points:
			if point.y <= low.y + 0.000001:
				feet.append(point)
		var ground_bounds := AABB(feet[0], Vector3.ZERO)
		for point in feet:
			ground_bounds = ground_bounds.expand(point)
		var center := bounds.get_center()
		var ground_center := ground_bounds.get_center()
		var centered := maxf(absf(center.x), absf(center.z)) < 0.00001 or maxf(absf(ground_center.x), absf(ground_center.z)) < 0.00001
		_check(id + ":Y_bottom_and_origin", absf(low.y) < 0.00001 and centered and minf(bounds.size.x, minf(bounds.size.y, bounds.size.z)) > 0.01, {"min": _v(low), "max": _v(high), "ground_center": _v(ground_center)})
		row["bounds"] = {"min": _v(low), "max": _v(high), "size": _v(bounds.size)}
		if expected.has(id):
			var original: Dictionary = expected[id]
			var expected_low: Array = original["bounds"]["min"]
			var expected_high: Array = original["bounds"]["max"]
			var bound_error := 0.0
			for axis in range(3):
				bound_error = maxf(bound_error, absf(low[axis] - float(expected_low[axis])))
				bound_error = maxf(bound_error, absf(high[axis] - float(expected_high[axis])))
			_check(id + ":root_geometry_audit_same_source_and_counts", original["sha256"] == before and int(original["triangles"]) == triangles and int(original["primitives"]) == surfaces and int(original["meshes"]) == mesh_count and bound_error < 0.00005, {"source_hash_matches": original["sha256"] == before, "bounds_error": bound_error, "triangles": triangles, "surfaces": surfaces, "meshes": mesh_count})
		else:
			_check(id + ":root_geometry_audit_entry", false, "missing")
	instance.queue_free()
	await process_frame
	var after := FileAccess.get_sha256(path)
	row["sha256_end"] = after
	_check(id + ":GLB_stable_during_import", before == after, {"start": before, "end": after})
	report["assets"].append(row)
