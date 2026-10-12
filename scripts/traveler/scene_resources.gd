extends RefCounted
## Store large geometry and instance buffers as compressed binary resources before
## packing the editable scene. Source GLBs and their import cache remain untouched.

static func externalize(world: Node) -> Dictionary:
	var state := {
		"mesh_cache": {}, "instance_cache": {},
		"mesh_directory": "res://generated/traveler/atlas/meshes",
		"instance_directory": "res://generated/traveler/atlas/instances",
		"report": {"success": true, "meshes_saved": 0, "multimeshes_saved": 0,
			"mesh_nodes": 0, "multimesh_nodes": 0, "mesh_cache_hits": 0,
			"detached_glb_scene_instances": 0,
			"multimesh_cache_hits": 0, "mesh_bytes": 0, "instance_bytes": 0,
			"reload_checks": 0, "errors": [], "storage": "compressed binary .res",
			"source_glbs_modified": false}}
	for path in [state.mesh_directory, state.instance_directory]:
		var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
		if error != OK and error != ERR_ALREADY_EXISTS:
			_fail(state, "Cannot create %s (error %d)" % [path, error])
	if state.report.success:
		_walk(world, state)
	state.report["total_bytes"] = state.report.mesh_bytes + state.report.instance_bytes
	return state.report

static func _fail(state: Dictionary, message: String) -> void:
	state.report.success = false
	state.report.errors.append(message)
	push_error(message)

static func _safe_name(label: String) -> String:
	var result := label.validate_filename().replace(" ", "_").replace(".", "_")
	return result.left(64) if not result.is_empty() else "resource"

static func _bytes(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_length() if file else 0

static func _same_bounds(a: AABB, b: AABB) -> bool:
	return a.position.is_equal_approx(b.position) and a.size.is_equal_approx(b.size)

static func _save_mesh(mesh: Mesh, label: String, state: Dictionary) -> Mesh:
	var resource_id := mesh.get_instance_id()
	if state.mesh_cache.has(resource_id):
		state.report.mesh_cache_hits += 1
		return state.mesh_cache[resource_id]
	var filename := "%s/%04d_%s.res" % [state.mesh_directory, state.report.meshes_saved, _safe_name(label)]
	var error := ResourceSaver.save(mesh, filename, ResourceSaver.FLAG_COMPRESS)
	if error != OK:
		_fail(state, "Cannot save mesh %s (error %d)" % [filename, error])
		return mesh
	# IGNORE forces a disk read. Merely returning the in-memory resource would not
	# establish that the binary file can be reopened or that the scene references it.
	var restored := ResourceLoader.load(filename, "Mesh", ResourceLoader.CACHE_MODE_IGNORE) as Mesh
	if restored == null:
		_fail(state, "Cannot reopen mesh " + filename)
		return mesh
	if restored.get_surface_count() != mesh.get_surface_count() or not _same_bounds(restored.get_aabb(), mesh.get_aabb()):
		_fail(state, "Mesh metadata changed after binary round trip: " + filename)
		return mesh
	for index in range(mesh.get_surface_count()):
		var counts_match: bool
		if mesh is ArrayMesh and restored is ArrayMesh:
			counts_match = restored.surface_get_array_len(index) == mesh.surface_get_array_len(index) and restored.surface_get_array_index_len(index) == mesh.surface_get_array_index_len(index)
		else:
			# Procedural PrimitiveMesh resources (e.g. rule-node cylinders) expose
			# arrays through Mesh, but not ArrayMesh's length-only methods.
			var before := mesh.surface_get_arrays(index)
			var after := restored.surface_get_arrays(index)
			counts_match = before[Mesh.ARRAY_VERTEX].size() == after[Mesh.ARRAY_VERTEX].size()
			var before_indices: int = before[Mesh.ARRAY_INDEX].size() if before[Mesh.ARRAY_INDEX] != null else 0
			var after_indices: int = after[Mesh.ARRAY_INDEX].size() if after[Mesh.ARRAY_INDEX] != null else 0
			counts_match = counts_match and before_indices == after_indices
		if not counts_match:
			_fail(state, "Mesh vertex/index count changed after binary round trip: " + filename)
			return mesh
	if restored.resource_path != filename:
		_fail(state, "Reopened mesh does not have external resource path: " + filename)
		return mesh
	state.mesh_cache[resource_id] = restored
	# A shared mesh may be encountered again after its owner has already switched
	# to the reloaded object. Both identities should resolve to the same file.
	state.mesh_cache[restored.get_instance_id()] = restored
	state.report.meshes_saved += 1
	state.report.mesh_bytes += _bytes(filename)
	state.report.reload_checks += 1
	return restored

static func _save_multimesh(multimesh: MultiMesh, label: String, state: Dictionary) -> MultiMesh:
	var resource_id := multimesh.get_instance_id()
	if state.instance_cache.has(resource_id):
		state.report.multimesh_cache_hits += 1
		return state.instance_cache[resource_id]
	# The dummy headless renderer can report instance_count while dropping the
	# actual instance stream. Comparing two empty readbacks would falsely pass.
	var stream: PackedFloat32Array = multimesh.buffer
	var stride: int = 12 if multimesh.transform_format == MultiMesh.TRANSFORM_3D else 8
	if multimesh.use_colors:
		stride += 4
	if multimesh.use_custom_data:
		stride += 4
	if stream.size() != multimesh.instance_count * stride:
		_fail(state, "MultiMesh instance buffer is missing/incomplete for %s: got %d floats, expected %d. Build with a real rendering backend and wait for a rendered frame." % [label, stream.size(), multimesh.instance_count * stride])
		return multimesh
	if multimesh.mesh:
		multimesh.mesh = _save_mesh(multimesh.mesh, label + "_mesh", state)
	var filename := "%s/%04d_%s.res" % [state.instance_directory, state.report.multimeshes_saved, _safe_name(label)]
	var error := ResourceSaver.save(multimesh, filename, ResourceSaver.FLAG_COMPRESS)
	if error != OK:
		_fail(state, "Cannot save MultiMesh %s (error %d)" % [filename, error])
		return multimesh
	var restored := ResourceLoader.load(filename, "MultiMesh", ResourceLoader.CACHE_MODE_IGNORE) as MultiMesh
	if restored == null:
		_fail(state, "Cannot reopen MultiMesh " + filename)
		return multimesh
	if restored.instance_count != multimesh.instance_count or restored.transform_format != multimesh.transform_format or restored.use_colors != multimesh.use_colors or restored.use_custom_data != multimesh.use_custom_data:
		_fail(state, "MultiMesh format changed after binary round trip: " + filename)
		return multimesh
	var reopened_stream: PackedFloat32Array = restored.buffer
	if reopened_stream.size() != stream.size() or reopened_stream != stream:
		_fail(state, "MultiMesh instance buffer changed after binary round trip: " + filename)
		return multimesh
	if multimesh.mesh and (not restored.mesh or restored.mesh.resource_path != multimesh.mesh.resource_path):
		_fail(state, "MultiMesh lost its external mesh reference: " + filename)
		return multimesh
	if multimesh.instance_count > 0:
		for index in [0, int(multimesh.instance_count / 2), multimesh.instance_count - 1]:
			if multimesh.transform_format == MultiMesh.TRANSFORM_3D and not restored.get_instance_transform(index).is_equal_approx(multimesh.get_instance_transform(index)):
				_fail(state, "MultiMesh transform changed after binary round trip: " + filename)
				return multimesh
			if multimesh.use_colors and not restored.get_instance_color(index).is_equal_approx(multimesh.get_instance_color(index)):
				_fail(state, "MultiMesh color changed after binary round trip: " + filename)
				return multimesh
	if restored.resource_path != filename:
		_fail(state, "Reopened MultiMesh does not have external resource path: " + filename)
		return multimesh
	state.instance_cache[resource_id] = restored
	state.instance_cache[restored.get_instance_id()] = restored
	state.report.multimeshes_saved += 1
	state.report.instance_bytes += _bytes(filename)
	state.report.reload_checks += 1
	return restored

static func _walk(node: Node, state: Dictionary) -> void:
	if node.scene_file_path.get_extension().to_lower() in ["glb", "gltf"]:
		# Every imported descendant is assigned to the assembled world's owner.
		# Keeping its inherited PackedScene at the same time makes Godot recreate
		# the original mesh child AND our newly owned same-name child on reload.
		# The displaced original becomes an unreachable orphan (81 in this map).
		# Make the imported hierarchy local before pack; retain provenance metadata
		# and unchanged GLBs so future source reimport remains reproducible.
		node.set_meta("source_glb_scene", node.scene_file_path)
		node.scene_file_path = ""
		state.report.detached_glb_scene_instances += 1
	if node is MeshInstance3D and node.mesh:
		state.report.mesh_nodes += 1
		node.mesh = _save_mesh(node.mesh, str(node.name), state)
	elif node is MultiMeshInstance3D and node.multimesh:
		state.report.multimesh_nodes += 1
		node.multimesh = _save_multimesh(node.multimesh, str(node.name), state)
	for child in node.get_children():
		_walk(child, state)
