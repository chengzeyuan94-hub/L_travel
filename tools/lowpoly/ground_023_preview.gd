extends "res://tools/lowpoly/transition_022_preview.gd"
## Local terrain refinement A/B. Before is the complete 022 candidate.

const GROUND_DIR := "res://docs/design/ground-detail-023"
var _ground_plan: Dictionary = {}
var _ground_specs: Dictionary = {}
var _prop_adjustments: Dictionary = {}
var _ground_pairs: Dictionary = {}
var _ground_prop_pairs: Array[Dictionary] = []
var _ambient_ground_pairs: Array[Dictionary] = []
var _old_ground: Array[Node3D] = []
var _new_ground: Node3D
var _soft_foot_normals := false
var _foot_kind := ""

func _ready() -> void:
	OUTPUT = OS.get_environment("SILKROAD_GROUND_OUTPUT")
	if OUTPUT.is_empty(): OUTPUT = "/Users/chengzeyuan/SilkRoadEvidence/ground-detail-023/interactive"
	_mode = OS.get_environment("SILKROAD_GROUND_MODE")
	if _mode.is_empty(): _mode = "interactive"
	_placements_path = "res://docs/design/map-layout-021/placements.json"
	var old_variants: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TRANSITION_PLACEMENTS))
	for entry: Dictionary in old_variants.get("variants", []): _variant_specs[entry["id"]] = entry
	_ground_plan = JSON.parse_string(FileAccess.get_file_as_string(GROUND_DIR.path_join("placements.json")))
	for entry: Dictionary in _ground_plan.get("landmarks", []): _ground_specs[entry["id"]] = entry
	for entry: Dictionary in _ground_plan.get("props", []): _prop_adjustments[entry["id"]] = entry
	_transition_views = [
		{"id":"overview", "title":"星球总览", "logical":[2048,544], "zoom":1.0},
		{"id":"central", "title":"丝路与高原", "logical":[2210,490], "zoom":1.55},
		{"id":"everest", "title":"珠峰与山麓", "logical":[2470,490], "zoom":3.6},
		{"id":"dunes", "title":"塔克拉玛干沙地", "logical":[2218,407], "zoom":3.6},
		{"id":"city_delhi", "title":"德里与北部平原", "logical":[2117.5,578], "zoom":2.6},
		{"id":"plain", "title":"平原与丘陵近景", "logical":[2305,658], "zoom":3.8},
		{"id":"coast", "title":"样区南缘与海岸", "logical":[2245,845], "zoom":3.2},
		{"id":"city_panti", "title":"盘橐城与区域边缘", "logical":[1921.5,249.5], "zoom":2.6},
		{"id":"everest_oblique", "title":"珠峰山麓斜向检查", "logical":[2470,490], "zoom":3.2, "tilt_deg":30.0},
		{"id":"plain_oblique", "title":"平原坡谷斜向检查", "logical":[2305,658], "zoom":3.2, "tilt_deg":30.0},
	]
	call_deferred("_run")
	if _mode == "capture":
		get_tree().create_timer(300.0, true, false, true).timeout.connect(func():
			push_error("GROUND_023_TIMEOUT")
			get_tree().quit(1))

func _source_hashes() -> Dictionary:
	var hashes := super._source_hashes()
	for path in ["tools/lowpoly/ground_023_preview.gd", "tools/lowpoly/ground_023_prepare.py", "tools/lowpoly/ground_023_assets.py", "tools/lowpoly/planet_detail_012.py", "tools/lowpoly/density_017.py", "tools/lowpoly/layout_021_plan.py", "tools/lowpoly/density_017_audit.py", "tools/lowpoly/visual_006_audit.py", "docs/design/ground-detail-023/placements.json", "docs/design/ground-detail-023/exports/ground.glb"]:
		hashes[path] = FileAccess.get_sha256("res://" + path)
	return hashes

func _load_scene(path: String, linear_colors: bool) -> Node3D:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(ProjectSettings.globalize_path(path), state, 64) != OK:
		_problems.append("023 GLB import failed: " + path)
		return null
	var model := document.generate_scene(state) as Node3D
	if model == null: return null
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if linear_colors and RenderingServer.get_current_rendering_method() == "gl_compatibility":
			_adapt_linear_library_colors(mesh, "ground023/" + path.get_file())
		for surface in mesh.mesh.get_surface_count():
			if mesh.mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR:
				var material := mesh.get_active_material(surface).duplicate() as StandardMaterial3D
				material.vertex_color_use_as_albedo = true
				material.vertex_color_is_srgb = false
				mesh.set_surface_override_material(surface, material)
	_asset_hashes[ProjectSettings.globalize_path(path)] = FileAccess.get_sha256(path)
	return model

func _load_city_candidates(content: Dictionary) -> void:
	super._load_city_candidates(content)
	for node_name in _ground_plan.get("replace_nodes", ["spherical_continents_and_biomes"]):
		for child in (_board.get("_static_root") as Node).find_children(String(node_name) + "*", "MeshInstance3D", true, false):
			_old_ground.append(child as Node3D)
	if _old_ground.is_empty(): _problems.append("023 original continent not found")
	_new_ground = _load_scene(GROUND_DIR.path_join("exports/ground.glb"), false)
	if _new_ground == null:
		_problems.append("023 ground scene empty")
		return
	_new_ground.name = "Ground023"
	_layout_root.add_child(_new_ground)
	_new_ground.visible = false

func _add_landmark(item: Dictionary) -> void:
	super._add_landmark(item)
	var id := String(item["id"])
	if not _ground_specs.has(id): return
	var entry: Dictionary = _landmark_entries[-1]
	var before: Node3D = _variant_pairs[id]["after"] if _variant_pairs.has(id) else entry["node"]
	var spec: Dictionary = _ground_specs[id]
	var after := _load_scene("res://" + String(spec["glb"]), true)
	if after == null:
		_problems.append("023 landmark empty: " + id)
		return
	_landmarks_root.add_child(after)
	after.name = id + "_ground023"
	after.transform = _placement_transform(spec)
	_soft_foot_normals = true
	_foot_kind = id
	if bool(spec["authored_transition"]):
		var original: Dictionary = _variant_specs[id]
		_variant_specs[id] = spec
		_fit_023_footing(after, id)
		_variant_specs[id] = original
	else:
		_conform_low_edge(after, spec["conform_grid"], "ground023/" + id)
	_soft_foot_normals = false
	_foot_kind = ""
	after.visible = false
	_ground_pairs[id] = {"before":before, "after":after, "entry":entry, "before_height":entry["ground_height"], "after_height":spec["ground_height"]}
	if _variant_pairs.has(id): _ground_pairs[id]["before_height"] = _variant_pairs[id]["after_height"]

func _fit_023_footing(model: Node3D, id: String) -> void:
	var originals: Array[Dictionary] = []
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var node := child as MeshInstance3D
		if String(node.name).contains("_Transition_Footing"):
			originals.append({"node":node,"mesh":node.mesh,"relative":_relative_transform(node, model)})
	_fit_authored_footing(model, id)
	var fit: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TRANSITION_DIR.path_join("exports/" + id + "-fit.json")))
	var weights := {}
	for row: Dictionary in fit["vertices"]:
		var p: Array = row["position"]
		weights[_vertex_key(Vector3(p[0],p[1],p[2]))] = float(row["weight"])
	for original in originals:
		var node: MeshInstance3D = original["node"]
		var source: Mesh = original["mesh"]
		var fitted := node.mesh
		var result := ArrayMesh.new()
		for surface in fitted.get_surface_count():
			var arrays := fitted.surface_get_arrays(surface).duplicate(true)
			var raw := source.surface_get_arrays(surface)
			var points: PackedVector3Array = raw[Mesh.ARRAY_VERTEX]
			var colors: PackedColorArray = raw[Mesh.ARRAY_COLOR].duplicate()
			for i in points.size():
				var point: Vector3 = original["relative"] * points[i]
				var key := _vertex_key(point)
				var weight := float(weights.get(key, -1.0))
				if weight < 0.0:
					for dx in range(-1,2):
						for dy in range(-1,2):
							for dz in range(-1,2):
								var neighbor := key + Vector3i(dx,dy,dz)
								if weights.has(neighbor): weight = float(weights[neighbor])
				if weight > 0.0:
					var earth_mix := smoothstep(0.22, 0.94, weight)
					if id == "everest": earth_mix = smoothstep(0.0, 0.64, weight)
					colors[i] = colors[i].lerp(_ground_color(_variant_specs[id]["conform_grid"], point), earth_mix)
			arrays[Mesh.ARRAY_COLOR] = colors
			result.add_surface_from_arrays(fitted.surface_get_primitive_type(surface), arrays)
			result.surface_set_material(surface, fitted.surface_get_material(surface))
		node.mesh = result

func _deformed_normals(vertices: PackedVector3Array, indices: PackedInt32Array, previous: PackedVector3Array) -> PackedVector3Array:
	if not _soft_foot_normals: return super._deformed_normals(vertices, indices, previous)
	var face_normals := super._deformed_normals(vertices, indices, previous)
	var upper := {}
	var order := indices
	if order.is_empty():
		for i in vertices.size(): order.append(i)
	for t in range(0, order.size(), 3):
		var a := order[t]
		var b := order[t + 1]
		var c := order[t + 2]
		var area_normal := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		if area_normal.dot(previous[a] + previous[b] + previous[c]) < 0.0: area_normal = -area_normal
		for i in [a, b, c]:
			if previous[i].y > 0.02:
				var key := _vertex_key(vertices[i])
				if not upper.has(key): upper[key] = []
				(upper[key] as Array).append(area_normal)
	var result := face_normals.duplicate()
	for i in vertices.size():
		# Exclude underside and vertical material walls from the smoothing fan.
		if previous[i].y > 0.02:
			var key := _vertex_key(vertices[i])
			var shared := Vector3.ZERO
			for neighbor: Vector3 in upper[key]:
				if neighbor.normalized().dot(face_normals[i]) > 0.78: shared += neighbor
			if shared.length_squared() > 0.000001:
				result[i] = face_normals[i].lerp(shared.normalized(), 0.40 if _foot_kind == "everest" else 0.76).normalized()
	return result

func _focus_view(view: Dictionary) -> void:
	super._focus_view(view)
	if not view.has("tilt_deg"): return
	var camera: Camera3D = _board.get("_camera")
	var xy: Array = view["logical"]
	var pivot := PlanetGeometry.to_world(Vector2(xy[0], xy[1]), 0.2)
	var turn := Basis(camera.global_basis.x.normalized(), deg_to_rad(float(view["tilt_deg"])))
	camera.global_transform = Transform3D(turn * camera.global_basis, pivot + turn * (camera.global_position - pivot))
	_board.call("_update_projected_labels")
	_board.call("_update_space_backdrop")

func _finish_prop_batches() -> void:
	super._finish_prop_batches()
	for key in _prop_batches:
		var entry: Dictionary = _prop_batches[key]
		var ids: Array = entry["ids"]
		var affected := false
		for id in ids: affected = affected or _prop_adjustments.has(id)
		if not affected: continue
		var before: MultiMeshInstance3D = entry["node"]
		var after := MultiMeshInstance3D.new()
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = before.multimesh.mesh
		multi.instance_count = before.multimesh.instance_count
		after.multimesh = multi
		before.get_parent().add_child(after)
		after.name = before.name + "_ground023"
		for i in ids.size():
			after.multimesh.set_instance_transform(i, before.multimesh.get_instance_transform(i))
			if not _prop_adjustments.has(ids[i]): continue
			var adjustment: Dictionary = _prop_adjustments[ids[i]]
			var xy: Array = adjustment["logical"]
			var transform := after.multimesh.get_instance_transform(i)
			transform.origin += PlanetGeometry.normal_at(Vector2(xy[0], xy[1])) * float(adjustment["delta_world"])
			after.multimesh.set_instance_transform(i, transform)
		after.visible = false
		_ground_prop_pairs.append({"before":before, "after":after})
	var ambient: Node3D = _board.get("_ambient")
	for item: Dictionary in _ground_plan.get("ambient", []):
		for label in item["nodes"]:
			var node := ambient.get_node_or_null(String(label)) as MultiMeshInstance3D
			if node == null:
				_problems.append("023 ambient node missing: " + String(label))
				continue
			var index := int(item["index"])
			var before := node.multimesh.get_instance_transform(index)
			var after := before
			var xy: Array = item["logical"]
			after.origin += PlanetGeometry.normal_at(Vector2(xy[0], xy[1])) * float(item["delta_world"])
			_ambient_ground_pairs.append({"node":node,"index":index,"before":before,"after":after})

func _set_phase(phase: String) -> void:
	super._set_phase("after")
	var upgraded := phase in ["after", "layout"]
	_phase = phase
	for node in _old_ground: node.visible = not upgraded
	if _new_ground != null: _new_ground.visible = upgraded
	for pair: Dictionary in _ground_pairs.values():
		(pair["before"] as Node3D).visible = not upgraded
		(pair["after"] as Node3D).visible = upgraded
		pair["entry"]["node"] = pair["after"] if upgraded else pair["before"]
		pair["entry"]["ground_height"] = pair["after_height"] if upgraded else pair["before_height"]
		pair["entry"]["bounds"] = _board.call("_model_bounds", pair["entry"]["node"])
	for pair: Dictionary in _ground_prop_pairs:
		(pair["before"] as Node3D).visible = not upgraded
		(pair["after"] as Node3D).visible = upgraded
	for pair: Dictionary in _ambient_ground_pairs:
		(pair["node"] as MultiMeshInstance3D).multimesh.set_instance_transform(int(pair["index"]), pair["after"] if upgraded else pair["before"])
	if _status != null: _status.text = "新地表" if upgraded else "原地表"

func _build_toolbar(content: Dictionary) -> void:
	super._build_toolbar(content)
	for child in _toolbar.find_children("*", "Button", true, false):
		var button := child as Button
		if button.text.begins_with("原布局"): button.text = "原地表"
		elif button.text.begins_with("过渡样板"): button.text = "新地表"
	_set_phase("after")

func _unhandled_input(event: InputEvent) -> void:
	if _ready_for_layout and _mode == "interactive" and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_L:
		_set_phase("before" if _phase in ["after", "layout"] else "after")
		get_viewport().set_input_as_handled()

func _capture_all() -> void:
	_capture_busy = true
	DirAccess.make_dir_recursive_absolute(OUTPUT.path_join("captures"))
	var previews := ProjectSettings.globalize_path(GROUND_DIR.path_join("previews"))
	DirAccess.make_dir_recursive_absolute(previews)
	_freeze_detail_stills()
	for actor in (_board.get("_pieces") as Dictionary).values(): (actor as Node).process_mode = Node.PROCESS_MODE_DISABLED
	var measure := OS.get_environment("SILKROAD_GROUND_PERF") == "1"
	if measure:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	_report["performance_scope"] = {"enabled":measure, "device":RenderingServer.get_video_adapter_name(), "vsync":DisplayServer.window_get_vsync_mode(), "max_fps":Engine.max_fps, "note":"Three-second static fixture samples at overview/dunes/Delhi before screenshot I/O. Not full-game or moving/selected-route performance."}
	var filter := OS.get_environment("SILKROAD_GROUND_VIEW_IDS").split(",", false)
	for phase in ["before", "after"]:
		_set_phase(phase)
		for view: Dictionary in _transition_views:
			if not filter.is_empty() and String(view["id"]) not in filter: continue
			_focus_view(view)
			await _frames(20)
			var performance := {}
			if measure and String(view["id"]) in ["overview", "dunes", "city_delhi"]: performance = await _sample_performance()
			await RenderingServer.frame_post_draw
			var picture := get_viewport().get_texture().get_image()
			var filename: String = view["id"] + "-" + phase
			var raw := OUTPUT.path_join("captures").path_join(filename + ".png")
			var preview := previews.path_join(filename + ".jpg")
			if picture.save_png(raw) != OK or picture.save_jpg(preview, 0.94) != OK: _report["errors"].append(filename + ": capture failed")
			var record := _layout_evidence()
			record.merge({"view_id":view["id"], "title":view["title"], "zoom":view["zoom"], "raw":raw, "raw_sha256":FileAccess.get_sha256(raw), "preview":preview, "sha256":FileAccess.get_sha256(preview)})
			if not performance.is_empty(): record["static_performance"] = performance
			_report["captures"].append(record)
			print("GROUND_023_CAPTURED ", filename)
	_report["source_end_sha256"] = _source_hashes()
	_report["inputs_stable"] = _report["source_start_sha256"] == _report["source_end_sha256"]
	for path in _asset_hashes:
		if FileAccess.get_sha256(path) != _asset_hashes[path]: _report["inputs_stable"] = false
	_report["capture_view_filter"] = Array(filter)
	_write_report("ground-capture-report.json")
	_screen.call("cancel_ai")
	_board.call("cancel_all_animations")
	AudioManager.silence_all()
	print("GROUND_023_COMPLETE ", _report["captures"].size(), " errors=", _report["errors"].size())
	get_tree().quit(0 if _report["errors"].is_empty() and _report["inputs_stable"] else 1)

func _write_report(filename: String) -> void:
	_report["task"] = "TASK-GROUND-DETAIL-023"
	_report["views"] = _transition_views
	_report["ground_plan"] = _ground_plan
	_report["conform"] = _deform_stats.duplicate(true)
	_report["method"] = "Before: full 022 layout. After: same city/landmark assets and logical anchors with localized refined continental geometry, normals/colors and ground-fitting props/landmarks. No camera, lighting or rule changes."
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	var file := FileAccess.open(OUTPUT.path_join(filename), FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(_report, "\t"))
