extends "res://tools/lowpoly/layout_021_preview.gd"
## A/B study on top of frozen 021. Before means 021 layout, not the old game map.

const TRANSITION_DIR := "res://docs/design/terrain-transition-022"
const TRANSITION_PLACEMENTS := "res://docs/design/terrain-transition-022/variant-placements.json"
var _variant_pairs: Dictionary = {}
var _variant_specs: Dictionary = {}
var _transition_stats: Dictionary = {}
var _transition_views: Array[Dictionary] = [
	{"id":"overview", "title":"星球总览", "logical":[2048,544], "zoom":1.0},
	{"id":"central", "title":"丝路与高原", "logical":[2210,490], "zoom":1.55},
	{"id":"everest", "title":"珠峰 · 山麓过渡", "logical":[2470,490], "zoom":3.6},
	{"id":"dunes", "title":"沙丘 · 风沙过渡", "logical":[2218,407], "zoom":3.6},
	{"id":"tigris", "title":"河曲 · 河漫滩过渡", "logical":[1598,657], "zoom":3.6},
	{"id":"city_delhi", "title":"德里周边", "logical":[2117.5,578], "zoom":2.6},
	{"id":"city_panti", "title":"盘橐城周边", "logical":[1921.5,249.5], "zoom":2.6},
	{"id":"city_baghdad", "title":"巴格达周边", "logical":[1416.5,473], "zoom":2.6},
]

func _ready() -> void:
	OUTPUT = OS.get_environment("SILKROAD_TRANSITION_OUTPUT")
	if OUTPUT.is_empty(): OUTPUT = "/Users/chengzeyuan/SilkRoadEvidence/terrain-transition-022/runtime"
	_mode = OS.get_environment("SILKROAD_TRANSITION_MODE")
	if _mode.is_empty(): _mode = "interactive"
	_placements_path = "res://docs/design/map-layout-021/placements.json"
	var variants: Variant = JSON.parse_string(FileAccess.get_file_as_string(TRANSITION_PLACEMENTS))
	if variants is Dictionary:
		for entry: Dictionary in variants.get("variants", []): _variant_specs[entry["id"]] = entry
	call_deferred("_run")
	if _mode == "capture":
		get_tree().create_timer(240.0, true, false, true).timeout.connect(func():
			push_error("TRANSITION_022_TIMEOUT")
			get_tree().quit(1))

func _source_hashes() -> Dictionary:
	var hashes := super._source_hashes()
	for path in ["tools/lowpoly/layout_021_preview.gd", "tools/lowpoly/transition_022_preview.gd", "tools/lowpoly/transition_022_assets.py", "tools/lowpoly/transition_022_prepare.py", "docs/design/terrain-transition-022/variant-placements.json", "docs/design/map-layout-021/placements.json"]:
		hashes[path] = FileAccess.get_sha256("res://" + path)
	for id in ["everest", "taklamakan_dunes", "tigris_meander"]:
		var path: String = "docs/design/terrain-transition-022/exports/" + id + "-fit.json"
		hashes[path] = FileAccess.get_sha256("res://" + path)
	return hashes

func _add_landmark(item: Dictionary) -> void:
	super._add_landmark(item)
	var id := String(item["id"])
	if id not in ["everest", "taklamakan_dunes", "tigris_meander"]: return
	if not _variant_specs.has(id):
		_problems.append("Missing 022 variant placement: " + id)
		return
	var path := ProjectSettings.globalize_path(TRANSITION_DIR.path_join("exports").path_join(id + ".glb"))
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(path, state, 64) != OK:
		_problems.append("022 asset import failed: " + id)
		return
	var model := document.generate_scene(state) as Node3D
	if model == null:
		_problems.append("022 asset has no model: " + id)
		return
	model.name = id + "_transition022"
	_landmarks_root.add_child(model)
	model.transform = _placement_transform(_variant_specs[id])
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if RenderingServer.get_current_rendering_method() == "gl_compatibility":
			_adapt_linear_library_colors(mesh, "transition022/" + id)
		for surface in mesh.mesh.get_surface_count():
			if mesh.mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR:
				var original := mesh.get_active_material(surface) as StandardMaterial3D
				if original != null:
					var material := original.duplicate() as StandardMaterial3D
					material.vertex_color_use_as_albedo = true
					material.vertex_color_is_srgb = false
					mesh.set_surface_override_material(surface, material)
	_fit_authored_footing(model, id)
	var entry: Dictionary = _landmark_entries[-1]
	_variant_pairs[id] = {"before":entry["node"], "after":model, "entry":entry, "before_height":item["ground_height"], "after_height":_variant_specs[id]["ground_height"]}
	model.visible = false
	_asset_hashes[path] = FileAccess.get_sha256(path)
	_transition_stats[id] = {"glb":path, "sha256":FileAccess.get_sha256(path), "source":"Blender-authored footing variant", "placement":_variant_specs[id]}

func _vertex_key(point: Vector3) -> Vector3i:
	return Vector3i(roundi(point.x * 100000.0), roundi(point.y * 100000.0), roundi(point.z * 100000.0))

func _ground_color(grid: Dictionary, point: Vector3) -> Color:
	var dims: Array = grid["size"]
	var start: Array = grid["min"]
	var step: Array = grid["step"]
	var gx := clampf((point.x - float(start[0])) / float(step[0]), 0.0, float(dims[0]) - 1.001)
	var gz := clampf((point.z - float(start[1])) / float(step[1]), 0.0, float(dims[1]) - 1.001)
	var ix := floori(gx)
	var iz := floori(gz)
	var samples: Array = grid["colors_srgb"]
	var values: Array[Color] = []
	for dz in 2:
		for dx in 2:
			var rgb: Array = samples[(iz + dz) * int(dims[0]) + ix + dx]
			values.append(Color(rgb[0], rgb[1], rgb[2], 1.0))
	var color := values[0].lerp(values[1], gx - ix).lerp(values[2].lerp(values[3], gx - ix), gz - iz)
	# The continent explicitly stores sRGB vertex albedo. The authored GLB
	# uses linear COLOR_0, adapted once above for Compatibility.
	return color if RenderingServer.get_current_rendering_method() == "gl_compatibility" else color.srgb_to_linear()

func _fit_authored_footing(model: Node3D, id: String) -> void:
	var path := TRANSITION_DIR.path_join("exports").path_join(id + "-fit.json")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		_problems.append("Missing fit weights: " + id)
		return
	var weights := {}
	for row: Dictionary in parsed["vertices"]:
		var xyz: Array = row["position"]
		weights[_vertex_key(Vector3(xyz[0], xyz[1], xyz[2]))] = float(row["weight"])
	var grid: Dictionary = _variant_specs[id]["conform_grid"]
	var matched := 0
	var moved := 0
	var frozen := 0
	var largest := 0.0
	var supported := 0
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var instance := child as MeshInstance3D
		if not String(instance.name).contains("_Transition_Footing"): continue
		var mesh_to_root := model.global_transform.affine_inverse() * instance.global_transform
		var root_to_mesh := mesh_to_root.affine_inverse()
		var old := instance.mesh
		var mesh := ArrayMesh.new()
		var upper_vertices := {}
		for surface in old.get_surface_count():
			var source_arrays: Array = old.surface_get_arrays(surface)
			var source_points: PackedVector3Array = source_arrays[Mesh.ARRAY_VERTEX]
			var source_normals: PackedVector3Array = source_arrays[Mesh.ARRAY_NORMAL]
			for i in source_points.size():
				if (mesh_to_root.basis * source_normals[i]).y > 0.02:
					upper_vertices[_vertex_key(mesh_to_root * source_points[i])] = true
		for surface in old.get_surface_count():
			var arrays: Array = old.surface_get_arrays(surface).duplicate(true)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			for i in vertices.size():
				var point := mesh_to_root * vertices[i]
				var key := _vertex_key(point)
				var weight := -1.0
				if weights.has(key): weight = weights[key]
				else:
					# Float32 import and the rotated parent transform can cross a
					# quantization boundary. Search one adjacent 1e-5 bucket only.
					for dx in range(-1, 2):
						for dy in range(-1, 2):
							for dz in range(-1, 2):
								var near_key := key + Vector3i(dx, dy, dz)
								if weights.has(near_key): weight = weights[near_key]
				if weight < 0.0:
					_problems.append("Unmatched footing vertex: " + id + " " + str(point))
					continue
				matched += 1
				if weight <= 0.0:
					frozen += 1
					continue
				var ground_y := _grid_delta(grid, point)
				if grid.has("colors_srgb") and colors.size() == vertices.size():
					colors[i] = colors[i].lerp(_ground_color(grid, point), smoothstep(0.60, 0.98, weight))
				var before_y := point.y
				point.y += ground_y * weight
				if upper_vertices.has(key):
					# The interior top must stay above the existing continent.
					# Only the free outer toe is intentionally buried. Position
					# keys keep imported duplicate vertices on the same surface.
					var cover_world := lerpf(0.045, -0.005, smoothstep(0.78, 1.0, weight))
					cover_world *= smoothstep(0.0, 0.18, weight)
					var floor_y := ground_y + cover_world / float(_variant_specs[id]["scale"])
					if point.y < floor_y:
						point.y = floor_y
						supported += 1
				var delta := point.y - before_y
				vertices[i] = root_to_mesh * point
				moved += 1
				largest = maxf(largest, absf(delta))
			arrays[Mesh.ARRAY_VERTEX] = vertices
			arrays[Mesh.ARRAY_COLOR] = colors
			arrays[Mesh.ARRAY_NORMAL] = _deformed_normals(vertices, arrays[Mesh.ARRAY_INDEX], arrays[Mesh.ARRAY_NORMAL])
			mesh.add_surface_from_arrays(old.surface_get_primitive_type(surface), arrays)
			mesh.surface_set_material(surface, old.surface_get_material(surface))
		instance.mesh = mesh
	if matched == 0: _problems.append("No authored footing matched: " + id)
	_deform_stats["transition022/" + id] = {"matched_vertices":matched, "moved_vertices":moved, "frozen_join_vertices":frozen, "max_local_delta":largest, "ground_supported_vertices":supported,
		"method":"Only authored Transition follows fit weights. Hero/water/shared joins rigid. Interior top has a continent support floor; only free outer toes are buried. Outer Transition albedo blends to sampled existing continent color, with source Hero color unchanged. This is placement adaptation, not a new continental mesh."}

func _set_phase(phase: String) -> void:
	# Both sides retain the complete 021 city/landmark/prop layout.
	super._set_phase("layout")
	_phase = phase
	for pair: Dictionary in _variant_pairs.values():
		var enabled := phase in ["layout", "after"]
		(pair["before"] as Node3D).visible = not enabled
		(pair["after"] as Node3D).visible = enabled
		pair["entry"]["node"] = pair["after"] if enabled else pair["before"]
		pair["entry"]["ground_height"] = pair["after_height"] if enabled else pair["before_height"]
	for entry: Dictionary in _landmark_entries:
		entry["bounds"] = _board.call("_model_bounds", entry["node"])
	if _status != null:
		_status.text = "过渡样板" if phase in ["layout", "after"] else "原布局021"

func _build_toolbar(_content: Dictionary) -> void:
	_toolbar = PanelContainer.new()
	_toolbar.position = Vector2(12, get_viewport().get_visible_rect().size.y - 62)
	_toolbar.z_index = 100
	add_child(_toolbar)
	var row := HBoxContainer.new()
	_toolbar.add_child(row)
	_status = Label.new()
	_status.text = "过渡样板"
	row.add_child(_status)
	for phase in ["before", "after"]:
		var button := Button.new()
		button.text = "原布局021" if phase == "before" else "过渡样板022"
		button.pressed.connect(func(): _set_phase(phase))
		row.add_child(button)
	var views := OptionButton.new()
	for view: Dictionary in _transition_views: views.add_item(view["title"])
	views.item_selected.connect(func(i: int): _focus_view(_transition_views[i]))
	row.add_child(views)
	var hint := Label.new()
	hint.text = "拖动旋转 · 滚轮缩放 · L 对照"
	row.add_child(hint)

func _capture_all() -> void:
	_capture_busy = true
	DirAccess.make_dir_recursive_absolute(OUTPUT.path_join("captures"))
	var previews := ProjectSettings.globalize_path(TRANSITION_DIR.path_join("previews"))
	DirAccess.make_dir_recursive_absolute(previews)
	_freeze_detail_stills()
	for actor in (_board.get("_pieces") as Dictionary).values():
		(actor as Node).process_mode = Node.PROCESS_MODE_DISABLED
	var filter := OS.get_environment("SILKROAD_TRANSITION_VIEW_IDS").split(",", false)
	for phase in ["before", "after"]:
		_set_phase(phase)
		for view: Dictionary in _transition_views:
			if not filter.is_empty() and String(view["id"]) not in filter: continue
			_focus_view(view)
			await _frames(12)
			await RenderingServer.frame_post_draw
			var picture := get_viewport().get_texture().get_image()
			var filename: String = view["id"] + "-" + phase
			var raw := OUTPUT.path_join("captures").path_join(filename + ".png")
			var preview := previews.path_join(filename + ".jpg")
			if picture.save_png(raw) != OK or picture.save_jpg(preview, 0.94) != OK:
				_report["errors"].append(filename + ": capture write failed")
			var record := _layout_evidence()
			record.merge({"view_id":view["id"], "title":view["title"], "zoom":view["zoom"],
				"raw":raw, "raw_sha256":FileAccess.get_sha256(raw), "preview":preview, "sha256":FileAccess.get_sha256(preview)})
			_report["captures"].append(record)
			print("TRANSITION_022_CAPTURED ", filename)
	_report["source_end_sha256"] = _source_hashes()
	_report["inputs_stable"] = _report["source_start_sha256"] == _report["source_end_sha256"]
	for path in _asset_hashes:
		if FileAccess.get_sha256(path) != _asset_hashes[path]: _report["inputs_stable"] = false
	_report["capture_view_filter"] = Array(filter)
	_write_report("transition-capture-report.json")
	_screen.call("cancel_ai")
	_board.call("cancel_all_animations")
	AudioManager.silence_all()
	print("TRANSITION_022_COMPLETE ", _report["captures"].size(), " errors=", _report["errors"].size())
	get_tree().quit(0 if _report["errors"].is_empty() and _report["inputs_stable"] else 1)

func _write_report(filename: String) -> void:
	_report["task"] = "TASK-TERRAIN-TRANSITION-022"
	_report["transition"] = _transition_stats
	_report["method"] = "Independent 022 study: frozen 021 layout on both sides; 3 Blender-authored landmark/footing variants swapped. Only low edge ground conformance at runtime, no continental mesh changes."
	_report["views"] = _transition_views
	super._write_report(filename)
