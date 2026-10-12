extends "res://tools/lowpoly/density_017_capture.gd"
## Evidence-only GameScreen branch. All replacement and deformation is in memory.

const LAYOUT_DIR := "res://docs/design/map-layout-021"
const LIBRARIES := {
	"terrain": "res://docs/design/terrain-library-018",
	"landmark": "res://docs/design/landmark-library-020",
	"city": "res://docs/design/city-library-019",
}

var _placements_path := ""
var _plan: Dictionary = {}
var _templates: Dictionary = {}
var _asset_hashes: Dictionary = {}
var _city_pairs: Dictionary = {}
var _old_scenery: Array[Node3D] = []
var _old_visibility: Dictionary = {}
var _layout_root: Node3D
var _landmarks_root: Node3D
var _props_root: Node3D
var _prop_layer_roots: Dictionary = {}
var _prop_layer_enabled := {"foreground": true, "grove": true, "background": true, "cloud": true}
var _landmark_entries: Array[Dictionary] = []
var _prop_batches: Dictionary = {}
var _toolbar: PanelContainer
var _status: Label
var _phase := "layout"
var _city_scale := 1.0
var _cities_enabled := true
var _landmarks_enabled := true
var _props_enabled := true
var _ready_for_layout := false
var _capture_busy := false
var _problems: Array[String] = []
var _deform_stats: Dictionary = {}
var _color_adapter_stats: Dictionary = {}


func _ready() -> void:
	OUTPUT = OS.get_environment("SILKROAD_LAYOUT_OUTPUT")
	if OUTPUT.is_empty():
		OUTPUT = "/Users/chengzeyuan/SilkRoadEvidence/map-layout-021/runtime"
	_mode = OS.get_environment("SILKROAD_LAYOUT_MODE")
	if _mode.is_empty():
		_mode = "interactive"
	_placements_path = OS.get_environment("SILKROAD_LAYOUT_PLACEMENTS")
	if _placements_path.is_empty():
		_placements_path = LAYOUT_DIR.path_join("placements.json")
	call_deferred("_run")
	if _mode == "capture":
		get_tree().create_timer(420.0, true, false, true).timeout.connect(func():
			push_error("LAYOUT_021_CAPTURE_TIMEOUT")
			get_tree().quit(1))


func _run() -> void:
	if DisplayServer.get_name() == "headless" and _mode != "validate":
		push_error("021 rendering requires a window; SILKROAD_LAYOUT_MODE=validate supports headless structural validation.")
		get_tree().quit(2)
		return
	if _mode not in ["interactive", "capture", "validate"]:
		_abort("Unknown preview mode: " + _mode)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_placements_path))
	if not parsed is Dictionary:
		_abort("Missing or invalid layout JSON: " + _placements_path)
		return
	_plan = parsed
	if _plan.has("city_scale"):
		if not _number(_plan["city_scale"]) or float(_plan["city_scale"]) <= 0.0:
			_abort("city_scale must be finite and positive")
			return
		_city_scale = float(_plan["city_scale"])
	for key in ["landmarks", "props", "views"]:
		if not _plan.get(key) is Array:
			_abort("Layout JSON requires array: " + key)
			return
	for view: Variant in _plan["views"]:
		if not view is Dictionary or String(view.get("id", "")).is_empty() or String(view["id"]).get_file() != String(view["id"]):
			_abort("View requires a safe ID")
			return
		if not view.get("logical") is Array or view["logical"].size() != 2 or not _number(view["logical"][0]) or not _number(view["logical"][1]) or not _number(view.get("zoom")):
			_abort("View requires finite logical coordinates and zoom")
			return
	_report = {"task": "TASK-MAP-LAYOUT-021", "mode": _mode, "captures": [], "errors": [],
		"method": "Production GameScreen in a separate evidence process. Only in-memory city children, scenery visibility and additional layout nodes change. No production assets, rules, camera or lighting are written.",
		"placements": ProjectSettings.globalize_path(_placements_path),
		"placements_sha256": FileAccess.get_sha256(_placements_path),
		"script_sha256": FileAccess.get_sha256(get_script().resource_path),
		"source_start_sha256": _source_hashes(),
		"renderer": RenderingServer.get_current_rendering_method(), "godot": Engine.get_version_info()}
	var content := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var configs := [{"display_name": "地图布局样板", "color_id": "red", "controller_type": "LOCAL_HUMAN"},
		{"display_name": "AI", "color_id": "blue", "controller_type": "AI"}]
	var prepared := SetupSystem.prepare_new_game(content, configs, 2026090710, "FORMAL")
	if not prepared.get("success", false) or not SetupSystem.finalize_new_game().get("success", false):
		_abort("Formal game setup failed")
		return
	_screen = (load("res://scenes/game_screen.tscn") as PackedScene).instantiate() as Control
	add_child(_screen)
	_screen.show()
	_screen.call("on_game_started", configs)
	_screen.call("cancel_ai")
	_board = _screen.get_node("%BoardView") as Control
	await _frames(12)
	if not _board.call("is_ready_for_play"):
		_abort("Production board assets are unavailable")
		return
	_layout_root = Node3D.new()
	_layout_root.name = "Layout021"
	(_board.get("_world") as Node3D).add_child(_layout_root)
	_landmarks_root = Node3D.new()
	_landmarks_root.name = "Landmarks"
	_layout_root.add_child(_landmarks_root)
	_props_root = Node3D.new()
	_props_root.name = "NaturalProps"
	_layout_root.add_child(_props_root)
	for layer in _prop_layer_enabled:
		var layer_root := Node3D.new()
		layer_root.name = String(layer)
		_props_root.add_child(layer_root)
		_prop_layer_roots[layer] = layer_root
	_load_city_candidates(content)
	for pattern in ["sphere_scenery_*", "detail_012_kunlun"]:
		for child in (_board.get("_static_root") as Node).find_children(pattern, "MeshInstance3D", true, false):
			_old_scenery.append(child as Node3D)
			_old_visibility[child] = (child as Node3D).visible
	var corridor: Node3D = _board.get("_corridor")
	_old_visibility[corridor] = corridor.visible
	var ids := {}
	for item: Variant in _plan["landmarks"]:
		if _valid_placement(item, "landmark", ids):
			_add_landmark(item)
	for item: Variant in _plan["props"]:
		if _valid_placement(item, "terrain", ids):
			_add_prop(item)
	_finish_prop_batches()
	if not _problems.is_empty():
		_abort("; ".join(_problems))
		return
	_report["asset_sha256"] = _asset_hashes.duplicate()
	_report["layout_counts"] = {"cities": _city_pairs.size(), "landmarks": _landmark_entries.size(),
		"props": (_plan["props"] as Array).size(), "prop_surface_batches": _prop_batches.size()}
	_report["city_scale"] = _city_scale
	_report["hidden_old_meshes_in_layout"] = _old_scenery.map(func(node: Node3D): return String(node.name))
	_report["conform"] = _deform_stats.duplicate(true)
	_report["library_color_adapter"] = _color_adapter_stats.duplicate(true)
	_ready_for_layout = true
	_set_phase("layout")
	if _mode == "validate":
		_report["validation_note"] = "Headless structural load only; not rendered or visually accepted."
		_report["layout_state"] = _layout_evidence()
		_set_phase("baseline")
		_report["baseline_state"] = _layout_evidence()
		_set_phase("layout")
		_write_report("structural-validation.json")
		print("LAYOUT_021_STRUCTURE_VALID ", JSON.stringify(_report["layout_counts"]))
		_screen.call("cancel_ai")
		_board.call("cancel_all_animations")
		AudioManager.silence_all()
		get_tree().quit()
	elif _mode == "capture":
		await _capture_all()
	else:
		_build_toolbar(content)
		_board.call("reset_camera_to_fit")
		print("LAYOUT_021_READY ", JSON.stringify(_report["layout_counts"]))


func _abort(message: String) -> void:
	push_error(message)
	if not _report.has("errors"):
		_report["errors"] = []
	_report["errors"].append(message)
	_write_report("startup-error.json")
	get_tree().quit(1)


func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _valid_placement(value: Variant, library: String, ids: Dictionary) -> bool:
	if not value is Dictionary:
		_problems.append("Placement must be an object")
		return false
	var item: Dictionary = value
	var id := String(item.get("id", ""))
	var asset := String(item.get("asset_id", ""))
	var xy: Variant = item.get("logical")
	if id.is_empty() or ids.has(id) or asset.is_empty() or asset.get_file() != asset:
		_problems.append("Missing, duplicate or invalid placement ID: " + id)
		return false
	ids[id] = true
	if item.get("library") != library or not xy is Array or xy.size() != 2:
		_problems.append(id + ": wrong library or logical coordinate")
		return false
	if not _number(xy[0]) or not _number(xy[1]):
		_problems.append(id + ": non-finite logical coordinate")
		return false
	for key in ["scale", "yaw_deg", "ground_height"]:
		if not _number(item.get(key)):
			_problems.append(id + ": non-finite " + key)
			return false
	if float(item["scale"]) <= 0.0:
		_problems.append(id + ": scale must be positive")
		return false
	return true


func _direct_model(library: String, asset: String) -> Node3D:
	var relative := String(LIBRARIES[library]).path_join("exports").path_join(asset + ".glb")
	var path := ProjectSettings.globalize_path(relative)
	if _templates.has(path):
		return _templates[path]
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(path, state, 64) != OK:
		_problems.append("GLB import failed: " + path)
		return null
	var model := document.generate_scene(state) as Node3D
	if model == null:
		_problems.append("GLB has no scene: " + path)
		return null
	# Library material colors remain their own; never assign the planet water data shader.
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.mesh == null:
			continue
		if RenderingServer.get_current_rendering_method() == "gl_compatibility":
			_adapt_linear_library_colors(mesh, library + "/" + asset)
		for surface in mesh.mesh.get_surface_count():
			if mesh.mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR:
				var original := mesh.get_active_material(surface) as StandardMaterial3D
				if original != null:
					var material := original.duplicate() as StandardMaterial3D
					material.vertex_color_use_as_albedo = true
					material.vertex_color_is_srgb = false
					mesh.set_surface_override_material(surface, material)
	_templates[path] = model
	_asset_hashes[path] = FileAccess.get_sha256(path)
	return model


func _adapt_linear_library_colors(instance: MeshInstance3D, asset_key: String) -> void:
	# glTF COLOR_0 from these libraries is linear. Compatibility's spatial output
	# uses sRGB and BaseMaterial3D's vertex_color_is_srgb flag has no effect there.
	# Convert the copied color attribute once; Forward+/Mobile keep original data.
	# Production terrain is not passed here: its COLOR_0 already is authored sRGB.
	var source := instance.mesh
	var has_colors := false
	for surface in source.get_surface_count():
		has_colors = has_colors or bool(source.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR)
	if not has_colors:
		return
	var adapted := ArrayMesh.new()
	if not _color_adapter_stats.has(asset_key):
		_color_adapter_stats[asset_key] = {"surfaces": 0, "vertices": 0,
			"method": "Copied linear GLTF COLOR_0 converted once to sRGB for Compatibility only; albedo, shading and shadows preserved."}
	for surface in source.get_surface_count():
		var arrays: Array = source.surface_get_arrays(surface).duplicate(true)
		var values: Variant = arrays[Mesh.ARRAY_COLOR]
		if values is PackedColorArray and not values.is_empty():
			var colors: PackedColorArray = values
			var original := colors[0]
			for i in colors.size():
				colors[i] = colors[i].linear_to_srgb()
			arrays[Mesh.ARRAY_COLOR] = colors
			_color_adapter_stats[asset_key]["surfaces"] += 1
			_color_adapter_stats[asset_key]["vertices"] += colors.size()
			_color_adapter_stats[asset_key]["sample_linear"] = [original.r, original.g, original.b]
			_color_adapter_stats[asset_key]["sample_srgb"] = [colors[0].r, colors[0].g, colors[0].b]
		adapted.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays)
		adapted.surface_set_material(surface, source.surface_get_material(surface))
	instance.mesh = adapted


func _load_city_candidates(content: Dictionary) -> void:
	var visuals: Dictionary = _board.get("_city_visuals")
	for cid_value in content.get("cities", {}):
		var cid := String(cid_value)
		var template := _direct_model("city", cid)
		if template == null:
			continue
		var entry: Dictionary = visuals[cid]
		var city_root: Node3D = entry["root"]
		var candidate := template.duplicate() as Node3D
		candidate.name = "City019Candidate"
		city_root.add_child(candidate)
		candidate.visible = false
		_city_pairs[cid] = {"original": entry["model"], "original_visible": (entry["model"] as Node3D).visible,
			"original_bounds": entry["bounds"], "candidate": candidate,
			"candidate_bounds": _board.call("_model_bounds", candidate), "root": city_root, "original_basis": city_root.basis}


func _placement_transform(item: Dictionary) -> Transform3D:
	var xy := Vector2(float(item["logical"][0]), float(item["logical"][1]))
	var orientation := PlanetGeometry.basis_at(xy) * Basis(Vector3.UP, deg_to_rad(float(item["yaw_deg"])))
	return Transform3D(orientation * Basis.from_scale(Vector3.ONE * float(item["scale"])),
		PlanetGeometry.to_world(xy, float(item["ground_height"])))


func _add_landmark(item: Dictionary) -> void:
	var template := _direct_model("landmark", String(item["asset_id"]))
	if template == null:
		return
	var model := template.duplicate() as Node3D
	model.name = String(item["id"])
	_landmarks_root.add_child(model)
	model.transform = _placement_transform(item)
	if item.has("conform_grid"):
		_conform_low_edge(model, item["conform_grid"], String(item["id"]))
	var bounds: AABB = _board.call("_model_bounds", model)
	_landmark_entries.append({"id": item["id"], "asset_id": item["asset_id"], "node": model,
		"logical": item["logical"], "bounds": bounds, "scale": item["scale"], "yaw_deg": item["yaw_deg"],
		"ground_height": item["ground_height"]})


func _valid_grid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var grid: Dictionary = value
	for key in ["min", "step", "size"]:
		if not grid.get(key) is Array or grid[key].size() != 2:
			return false
		for number: Variant in grid[key]:
			if not _number(number):
				return false
	var count_x := int(grid["size"][0])
	var count_z := int(grid["size"][1])
	if count_x < 2 or count_z < 2 or float(grid["step"][0]) <= 0.0 or float(grid["step"][1]) <= 0.0:
		return false
	if not grid.get("heights") is Array or grid["heights"].size() != count_x * count_z:
		return false
	if not _number(grid.get("blend_height")) or float(grid["blend_height"]) <= 0.0:
		return false
	for height: Variant in grid["heights"]:
		if not _number(height):
			return false
	return true


func _grid_delta(grid: Dictionary, point: Vector3) -> float:
	var nx := int(grid["size"][0])
	var nz := int(grid["size"][1])
	var x := clampf((point.x - float(grid["min"][0])) / float(grid["step"][0]), 0.0, nx - 1.0)
	var z := clampf((point.z - float(grid["min"][1])) / float(grid["step"][1]), 0.0, nz - 1.0)
	var ix := mini(int(floor(x)), nx - 2)
	var iz := mini(int(floor(z)), nz - 2)
	var values: Array = grid["heights"]
	return lerpf(lerpf(float(values[iz * nx + ix]), float(values[iz * nx + ix + 1]), x - ix),
		lerpf(float(values[(iz + 1) * nx + ix]), float(values[(iz + 1) * nx + ix + 1]), x - ix), z - iz)


func _conform_low_edge(model: Node3D, value: Variant, id: String) -> void:
	if not _valid_grid(value):
		_problems.append(id + ": invalid conform_grid")
		return
	var grid: Dictionary = value
	var changed := 0
	var largest_delta := 0.0
	var foundation_surfaces: Array[Dictionary] = []
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var instance := child as MeshInstance3D
		var old_mesh := instance.mesh
		var new_mesh := ArrayMesh.new()
		var mesh_to_root := model.global_transform.affine_inverse() * instance.global_transform
		var root_to_mesh := mesh_to_root.affine_inverse()
		for surface in old_mesh.get_surface_count():
			var arrays: Array = old_mesh.surface_get_arrays(surface).duplicate(true)
			var material := old_mesh.surface_get_material(surface)
			var material_name := material.resource_name.to_lower() if material != null else ""
			var natural_foundation := material_name == "earth" or material_name == "mud" or material_name.begins_with("grass") or material_name.begins_with("sand") and not material_name.begins_with("sandstone")
			# Fill low natural skirts completely before fading. Keep rock/bridge,
			# water, buildings and vegetation on their previous deformation curve.
			# Shallow scenes retain their original upper cutoff with a short fade.
			var full_weight_y := (0.12 if float(grid["blend_height"]) > 0.12 else float(grid["blend_height"]) * 0.8) if natural_foundation else 0.0
			if natural_foundation:
				foundation_surfaces.append({"material": material_name, "full_weight_through_local_y": full_weight_y})
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var old_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var surface_changed := false
			for i in vertices.size():
				var point := mesh_to_root * vertices[i]
				var weight := 1.0 - smoothstep(full_weight_y, float(grid["blend_height"]), point.y)
				if weight <= 0.0:
					continue
				# Authored GLB local XZ. Grid heights already are local-Y deltas,
				# including sphere curvature, selected ground height and buried skirt.
				var delta := _grid_delta(grid, point) * weight
				if absf(delta) < 0.0000001:
					continue
				point.y += delta
				vertices[i] = root_to_mesh * point
				changed += 1
				largest_delta = maxf(largest_delta, absf(delta))
				surface_changed = true
			arrays[Mesh.ARRAY_VERTEX] = vertices
			if surface_changed:
				arrays[Mesh.ARRAY_NORMAL] = _deformed_normals(vertices, indices, old_normals)
			new_mesh.add_surface_from_arrays(old_mesh.surface_get_primitive_type(surface), arrays)
			new_mesh.surface_set_material(surface, old_mesh.surface_get_material(surface))
		instance.mesh = new_mesh
	_deform_stats[id] = {"changed_vertices": changed, "maximum_local_y_delta": largest_delta,
		"blend_height": grid["blend_height"], "grid_size": grid["size"],
		"natural_foundation_surfaces": foundation_surfaces,
		"method": "Low local-Y grid deltas only. Natural earth/mud/grass/sand skirts have a full-weight low plateau, capped to retain the original upper cutoff; rock, water and structures keep the earlier curve. Source GLB and upper body unchanged."}


func _deformed_normals(vertices: PackedVector3Array, indices: PackedInt32Array, previous: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.resize(vertices.size())
	var order := indices
	if order.is_empty():
		for i in vertices.size():
			order.append(i)
	for t in range(0, order.size(), 3):
		var a := order[t]
		var b := order[t + 1]
		var c := order[t + 2]
		var normal := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		# Preserve actual imported winding/normal convention after the GLTF import.
		if previous.size() == vertices.size() and normal.dot(previous[a] + previous[b] + previous[c]) < 0.0:
			normal = -normal
		result[a] += normal
		result[b] += normal
		result[c] += normal
	for i in result.size():
		result[i] = result[i].normalized() if result[i].length_squared() > 0.000000000001 else (previous[i] if previous.size() > i else Vector3.UP)
	return result


func _relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var result := node.transform
	var parent := node.get_parent()
	while parent != null and parent != ancestor:
		if parent is Node3D:
			result = (parent as Node3D).transform * result
		parent = parent.get_parent()
	return result


func _add_prop(item: Dictionary) -> void:
	var asset := String(item["asset_id"])
	var layer := String(item.get("layer", "foreground"))
	if not _prop_layer_roots.has(layer):
		_problems.append(String(item["id"]) + ": unknown prop layer " + layer)
		return
	var template := _direct_model("terrain", asset)
	if template == null:
		return
	var transform := _placement_transform(item)
	for child in template.find_children("*", "MeshInstance3D", true, false):
		var instance := child as MeshInstance3D
		var relative := _relative_transform(instance, template)
		for surface in instance.mesh.get_surface_count():
			var key := layer + "/" + asset + "/" + String(template.get_path_to(instance)) + "/" + str(surface)
			if not _prop_batches.has(key):
				var mesh := ArrayMesh.new()
				mesh.add_surface_from_arrays(instance.mesh.surface_get_primitive_type(surface), instance.mesh.surface_get_arrays(surface))
				mesh.surface_set_material(0, instance.get_active_material(surface))
				_prop_batches[key] = {"mesh": mesh, "transforms": [], "ids": [], "asset_id": asset, "layer": layer}
			_prop_batches[key]["transforms"].append(transform * relative)
			_prop_batches[key]["ids"].append(item["id"])


func _finish_prop_batches() -> void:
	for key in _prop_batches:
		var entry: Dictionary = _prop_batches[key]
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = entry["mesh"]
		multi.instance_count = entry["transforms"].size()
		for i in multi.instance_count:
			multi.set_instance_transform(i, entry["transforms"][i])
		var batch := MultiMeshInstance3D.new()
		batch.name = String(key).replace("/", "_")
		batch.multimesh = multi
		(_prop_layer_roots[entry["layer"]] as Node3D).add_child(batch)
		entry["node"] = batch


func _set_phase(phase: String) -> void:
	_phase = phase
	var layout := phase == "layout"
	var visuals: Dictionary = _board.get("_city_visuals")
	for cid in _city_pairs:
		var pair: Dictionary = _city_pairs[cid]
		var candidate_visible := layout and _cities_enabled
		(pair["root"] as Node3D).basis = pair["original_basis"] * Basis.from_scale(Vector3.ONE * (_city_scale if candidate_visible else 1.0))
		(pair["original"] as Node3D).visible = bool(pair["original_visible"]) and not candidate_visible
		(pair["candidate"] as Node3D).visible = candidate_visible
		visuals[cid]["model"] = pair["candidate"] if candidate_visible else pair["original"]
		visuals[cid]["bounds"] = pair["candidate_bounds"] if candidate_visible else pair["original_bounds"]
	for old in _old_scenery:
		old.visible = bool(_old_visibility[old]) and not layout
	var corridor: Node3D = _board.get("_corridor")
	corridor.visible = bool(_old_visibility[corridor]) and not layout
	_landmarks_root.visible = layout and _landmarks_enabled
	_props_root.visible = layout and _props_enabled
	for layer in _prop_layer_roots:
		(_prop_layer_roots[layer] as Node3D).visible = bool(_prop_layer_enabled[layer])
	_board.call("_update_projected_labels")
	if _status != null:
		_status.text = "新布局" if layout else "原地图"


func _build_toolbar(content: Dictionary) -> void:
	_toolbar = PanelContainer.new()
	_toolbar.name = "LayoutPreviewControls"
	_toolbar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_toolbar.position = Vector2(12, get_viewport().get_visible_rect().size.y - 90)
	_toolbar.z_index = 100
	add_child(_toolbar)
	var rows := VBoxContainer.new()
	_toolbar.add_child(rows)
	var actions := HBoxContainer.new()
	rows.add_child(actions)
	_status = Label.new()
	_status.text = "新布局"
	actions.add_child(_status)
	for phase in ["baseline", "layout"]:
		var button := Button.new()
		button.text = "原地图" if phase == "baseline" else "新布局"
		button.pressed.connect(_set_phase.bind(phase))
		actions.add_child(button)
	for label in ["城市", "地标"]:
		var toggle := CheckButton.new()
		toggle.text = label
		toggle.button_pressed = true
		toggle.toggled.connect(func(enabled: bool):
			match label:
				"城市": _cities_enabled = enabled
				"地标": _landmarks_enabled = enabled
			_set_phase(_phase))
		actions.add_child(toggle)
	var layer_labels := {"foreground": "近景", "grove": "树林", "background": "远景", "cloud": "云"}
	for layer in layer_labels:
		var toggle := CheckButton.new()
		toggle.text = layer_labels[layer]
		toggle.button_pressed = true
		toggle.toggled.connect(func(enabled: bool):
			_prop_layer_enabled[layer] = enabled
			_set_phase(_phase))
		actions.add_child(toggle)
	var focus_row := HBoxContainer.new()
	rows.add_child(focus_row)
	var cities := OptionButton.new()
	cities.add_item("聚焦城市…")
	var city_ids: Array = content.get("cities", {}).keys()
	city_ids.sort()
	for cid in city_ids:
		cities.add_item(GameData.get_node_display_name(content, String(cid)))
	cities.item_selected.connect(func(index: int):
		if index > 0:
			var point: Vector2 = _board.call("_node_pos", String(city_ids[index - 1]))
			_board.call("focus_logical_point", point + Vector2(0, -85), 2.6))
	focus_row.add_child(cities)
	var views := OptionButton.new()
	views.add_item("查看片区…")
	for view: Dictionary in _plan["views"]:
		views.add_item(String(view.get("title", view["id"])))
	views.item_selected.connect(func(index: int):
		if index > 0:
			_focus_view(_plan["views"][index - 1]))
	focus_row.add_child(views)
	var reset := Button.new()
	reset.text = "整颗星球"
	reset.pressed.connect(func(): _board.call("reset_camera_to_fit"))
	focus_row.add_child(reset)
	var hint := Label.new()
	hint.text = "拖动旋转 · 滚轮缩放 · L 对照"
	focus_row.add_child(hint)


func _unhandled_input(event: InputEvent) -> void:
	if _ready_for_layout and _mode == "interactive" and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_L:
		_set_phase("baseline" if _phase == "layout" else "layout")
		get_viewport().set_input_as_handled()


func _focus_view(view: Dictionary) -> void:
	var point: Array = view["logical"]
	_board.call("focus_logical_point", Vector2(float(point[0]), float(point[1])), float(view["zoom"]))


func _rect_values(rect: Rect2) -> Array:
	return [rect.position.x, rect.position.y, rect.size.x, rect.size.y]


func _layout_evidence() -> Dictionary:
	var debug: Dictionary = _board.call("get_map_debug_state")
	var labels: Array = []
	var city_rows: Array = []
	var camera: Camera3D = _board.get("_camera")
	for cid in debug["cities"]:
		var city: Dictionary = debug["cities"][cid]
		var root: Node3D = (_board.get("_city_visuals") as Dictionary)[cid]["root"]
		var ground: Vector2 = _board.call("_project", root.global_position)
		ground += _board.global_position
		var building: Rect2 = city["building_screen_rect"]
		building.position += _board.global_position
		city_rows.append({"id": cid, "screen_rect": _rect_values(building),
			"tag_rect": _rect_values(city["plaque_global"]), "tag_visible": city["label_visible"],
			"projected_ground_pixel": [ground.x, ground.y], "hemisphere_visible": city["front_facing"],
			"camera_distance": camera.global_position.distance_to(root.global_position)})
		if city["label_visible"]:
			labels.append({"id": cid, "plaque_global": _rect_values(city["plaque_global"]),
				"building_board_rect": _rect_values(city["building_screen_rect"])})
	var landmarks: Array = []
	for item in _landmark_entries:
		var model: Node3D = item["node"]
		var bounds: AABB = item["bounds"]
		var rect := Rect2()
		var finite := true
		for i in 8:
			var pixel: Vector2 = _board.call("_project", model.global_transform * bounds.get_endpoint(i))
			pixel += _board.global_position
			finite = finite and pixel.is_finite()
			rect = Rect2(pixel, Vector2.ZERO) if i == 0 else rect.expand(pixel)
		var hemisphere: bool = _board.call("_surface_point_visible", model.global_position)
		var ground: Vector2 = _board.call("_project", model.global_position)
		ground += _board.global_position
		landmarks.append({"id": item["id"], "asset_id": item["asset_id"], "logical": item["logical"],
			"scale": item["scale"], "yaw_deg": item["yaw_deg"], "ground_height": item["ground_height"],
			"layer_visible": model.is_visible_in_tree(), "front_hemisphere": hemisphere,
			"screen_rect": _rect_values(rect) if finite else [],
			"projected_ground_pixel": [ground.x, ground.y], "hemisphere_visible": hemisphere,
			"camera_distance": camera.global_position.distance_to(model.global_position),
			"intersects_window": finite and rect.intersects(get_viewport().get_visible_rect()),
			"bounds_method": "Projected transformed AABB; hemisphere is anchor-based, not an occlusion query."})
	return {"phase": _phase, "camera": debug["camera"], "camera_transform": str(camera.transform),
		"camera_fov": camera.fov, "board_size": str(_board.size),
		"board_viewport_size": str((_board.get("_viewport") as SubViewport).size),
		"window_size": str(get_viewport().get_visible_rect().size), "right_safe_inset": debug["right_safe_inset"],
		"visible_city_labels": labels, "cities": city_rows, "landmarks": landmarks,
		"note": "Visibility flags do not prove that landmarks, labels and routes are mutually unoccluded."}


func _capture_all() -> void:
	_capture_busy = true
	DirAccess.make_dir_recursive_absolute(OUTPUT.path_join("captures"))
	var previews := ProjectSettings.globalize_path(LAYOUT_DIR.path_join("previews"))
	DirAccess.make_dir_recursive_absolute(previews)
	_freeze_detail_stills()
	for actor in (_board.get("_pieces") as Dictionary).values():
		(actor as Node).process_mode = Node.PROCESS_MODE_DISABLED
	var view_ids := OS.get_environment("SILKROAD_LAYOUT_VIEW_IDS").split(",", false)
	var capture_views: Array[Dictionary] = []
	for view: Dictionary in _plan["views"]:
		if view_ids.is_empty() or String(view["id"]) in view_ids:
			capture_views.append(view)
	if capture_views.is_empty():
		_abort("SILKROAD_LAYOUT_VIEW_IDS matched no layout views")
		return
	_report["capture_view_filter"] = Array(view_ids)
	for phase in ["baseline", "layout"]:
		_set_phase(phase)
		for view: Dictionary in capture_views:
			_focus_view(view)
			await _frames(12)
			await RenderingServer.frame_post_draw
			var picture := get_viewport().get_texture().get_image()
			var filename: String = String(view["id"]) + "-" + phase
			var raw := OUTPUT.path_join("captures").path_join(filename + ".png")
			var preview := previews.path_join(filename + ".jpg")
			var raw_result := picture.save_png(raw)
			var preview_result := picture.save_jpg(preview, 0.94)
			if raw_result != OK or preview_result != OK:
				_report["errors"].append(filename + ": capture write failed")
			var record := _layout_evidence()
			record.merge({"view_id": view["id"], "title": view.get("title", view["id"]),
				"raw": raw, "raw_sha256": FileAccess.get_sha256(raw),
				"preview": preview, "sha256": FileAccess.get_sha256(preview)})
			_report["captures"].append(record)
			print("LAYOUT_021_CAPTURED ", filename)
	_report["source_end_sha256"] = _source_hashes()
	_report["inputs_stable"] = _report["source_start_sha256"] == _report["source_end_sha256"] and FileAccess.get_sha256(_placements_path) == _report["placements_sha256"]
	_report["inputs_stable"] = _report["inputs_stable"] and FileAccess.get_sha256(get_script().resource_path) == _report["script_sha256"]
	for path in _asset_hashes:
		if FileAccess.get_sha256(path) != _asset_hashes[path]:
			_report["inputs_stable"] = false
			_report["errors"].append("GLB changed during capture: " + path)
	_write_report("layout-capture-report.json")
	_screen.call("cancel_ai")
	_board.call("cancel_all_animations")
	AudioManager.silence_all()
	print("LAYOUT_021_COMPLETE ", _report["captures"].size(), " errors=", _report["errors"].size())
	get_tree().quit(0 if _report["errors"].is_empty() and _report["inputs_stable"] else 1)


func _write_report(filename: String) -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	var file := FileAccess.open(OUTPUT.path_join(filename), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_report, "\t"))
		file.close()


func _exit_tree() -> void:
	for model in _templates.values():
		if is_instance_valid(model):
			(model as Node).free()
