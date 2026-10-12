extends RefCounted
## Editable presentation only. These documents never replace formal rule JSON.
const DEFAULT_DRAFT_PATH := "user://map_editor/layout.json"
const DEFAULT_GAME_PATH := "user://map_editor/game-layout.json"
const SCHEMA_VERSION := 1

static func blank_layout() -> Dictionary:
	return {"schema_version": SCHEMA_VERSION, "board": {"width": 60.0, "depth": 20.0},
		"cities": [], "logic_nodes": [], "routes": [], "decorations": [],
		"visual_settings": {"night": false, "camera_yaw": -0.1, "camera_pitch": 0.7, "camera_size": 25.0}}

static func load_layout(path: String = DEFAULT_DRAFT_PATH) -> Dictionary:
	if not FileAccess.file_exists(path): return _failure(path, "Layout file does not exist.")
	var parser := JSON.new()
	var error := parser.parse(FileAccess.get_file_as_string(path))
	if error != OK: return _failure(path, "JSON line %d: %s" % [parser.get_error_line(), parser.get_error_message()])
	if not parser.data is Dictionary: return _failure(path, "The layout root must be an object.")
	var check := validate(parser.data)
	return {"ok": check.ok, "data": parser.data, "path": path, "errors": check.errors, "warnings": check.warnings}

static func save_layout(path: String, data: Dictionary) -> Dictionary:
	var check := validate(data)
	if not check.ok: return {"ok": false, "data": data, "path": path, "errors": check.errors, "warnings": check.warnings}
	return _write(path, data, check.warnings)

static func export_for_game(data: Dictionary, path: String = DEFAULT_GAME_PATH) -> Dictionary:
	var check := validate(data, true)
	if not check.ok: return {"ok": false, "data": data, "path": path, "errors": check.errors, "warnings": check.warnings}
	return _write(path, data, check.warnings)

static func _write(path: String, data: Dictionary, warnings: Array) -> Dictionary:
	if path.strip_edges().is_empty(): return _failure(path, "Choose a destination path.")
	var absolute := ProjectSettings.globalize_path(path).simplify_path()
	var rules_root := ProjectSettings.globalize_path("res://data/rulesets/").simplify_path().trim_suffix("/")
	if absolute == rules_root or absolute.begins_with(rules_root + "/"):
		return _failure(path, "Layout files cannot overwrite formal rule data.")
	var error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if error != OK: return _failure(path, "Cannot create destination directory: %s" % error_string(error))
	var temporary := absolute + ".writing"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return _failure(path, "Cannot write layout: %s" % error_string(FileAccess.get_open_error()))
	file.store_string(JSON.stringify(data, "\t", false, true) + "\n")
	file.close()
	error = DirAccess.rename_absolute(temporary, absolute)
	if error != OK: return _failure(path, "Cannot replace layout: %s" % error_string(error))
	return {"ok": true, "data": data.duplicate(true), "path": path, "errors": [], "warnings": warnings}

static func _failure(path: String, message: String) -> Dictionary:
	return {"ok": false, "data": {}, "path": path, "errors": [message], "warnings": []}

static func validate(data: Dictionary, for_game: bool = false) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if not _finite_number(data.get("schema_version")) or float(data.schema_version) != float(SCHEMA_VERSION): errors.append("Unsupported layout schema_version; expected 1.")
	var board: Variant = data.get("board", {})
	if not board is Dictionary or not _positive_number(board.get("width", 0)) or not _positive_number(board.get("depth", 0)):
		errors.append("Board width and depth must be finite positive numbers.")
	elif float(board.width) != 60.0 or float(board.depth) != 20.0:
		errors.append("Layout schema v1 supports a fixed 60 × 20 canvas (3:1); board dimensions must be width=60 and depth=20.")
	for key in ["cities", "logic_nodes", "routes", "decorations"]:
		if not data.get(key) is Array: errors.append("%s must be an array." % key)
	if not errors.is_empty(): return {"ok": false, "errors": errors, "warnings": warnings, "counts": {}}
	var formal := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var formal_nodes: Dictionary = formal.get("board_nodes", {})
	var formal_edges := {}
	for edge in formal.get("board_edges", []): formal_edges[str(edge.id)] = edge
	var node_ids := {}
	var city_ids := {}
	var placement_ids := {}
	var edge_ids := {}
	var assets := _asset_ids()
	for category in ["cities", "logic_nodes", "decorations"]:
		for index in data[category].size():
			var item: Variant = data[category][index]
			var label := "%s[%d]" % [category, index]
			if not item is Dictionary:
				errors.append(label + " must be an object.")
				continue
			_check_id(item, label, placement_ids, errors)
			if not _point(item.get("position")): errors.append(label + " has invalid position; expected three finite numbers.")
			if not _finite_number(item.get("rotation_y", 0)): errors.append(label + " has invalid rotation_y.")
			if not _positive_number(item.get("scale", 1)): errors.append(label + " scale must be positive.")
			if category != "logic_nodes":
				var asset_id := str(item.get("asset_id", ""))
				if asset_id.is_empty() or (not assets.is_empty() and not assets.has(asset_id)):
					_issue(label + " has unknown asset_id: " + asset_id, for_game, errors, warnings)
				elif category == "cities" and assets.has(asset_id) and str(assets[asset_id]) != "city":
					_issue(label + " requires an asset from the city category.", for_game, errors, warnings)
			if category == "decorations" and (item.has("node_id") or item.has("city_id")):
				_issue(label + " is decoration only; remove node_id and city_id before production export.", for_game, errors, warnings)
			if category in ["cities", "logic_nodes"]:
				var node_id := str(item.get("node_id", ""))
				if node_id.is_empty(): _issue(label + " needs a logical node_id.", for_game, errors, warnings)
				elif node_ids.has(node_id): errors.append("Duplicate logical node_id: " + node_id)
				else: node_ids[node_id] = item
				if not node_id.is_empty() and not formal_nodes.has(node_id): _issue("Unknown formal node_id: " + node_id, for_game, errors, warnings)
				if category == "cities":
					var city_id := str(item.get("city_id", ""))
					if not city_id.is_empty():
						if city_ids.has(city_id): errors.append("Duplicate city_id: " + city_id)
						city_ids[city_id] = item
					if city_id != node_id: _issue(label + " city_id and node_id must identify the same formal city.", for_game, errors, warnings)
					if not formal_nodes.has(city_id) or str(formal_nodes.get(city_id, {}).get("node_type", "")) != "CITY":
						_issue("Unknown formal city_id: " + city_id, for_game, errors, warnings)
				elif formal_nodes.has(node_id) and str(formal_nodes[node_id].get("node_type", "")) == "CITY":
					_issue("Formal city must be placed in cities: " + node_id, for_game, errors, warnings)
	for index in data.routes.size():
		var route: Variant = data.routes[index]
		var label := "routes[%d]" % index
		if not route is Dictionary:
			errors.append(label + " must be an object.")
			continue
		_check_id(route, label, placement_ids, errors)
		var route_type := str(route.get("type", ""))
		if route_type not in ["land", "sea"]: errors.append(label + " type must be land or sea.")
		var a := str(route.get("from_node", ""))
		var b := str(route.get("to_node", ""))
		if a.is_empty() or b.is_empty() or a == b: errors.append(label + " needs two distinct endpoint node IDs.")
		for endpoint in [a, b]:
			if not node_ids.has(endpoint): _issue(label + " endpoint is not placed: " + endpoint, for_game, errors, warnings)
		var points: Variant = route.get("points", [])
		if not points is Array: errors.append(label + " points must be an array of intermediate positions.")
		else:
			for point in points:
				if not _point(point): errors.append(label + " has invalid route control point.")
		var edge_id := str(route.get("edge_id", ""))
		if edge_id.is_empty(): _issue(label + " has no formal edge_id; draft route only.", for_game, errors, warnings)
		elif edge_ids.has(edge_id): errors.append("Duplicate edge_id: " + edge_id)
		else: edge_ids[edge_id] = route
		if not edge_id.is_empty():
			if not formal_edges.has(edge_id): _issue("Unknown formal edge_id: " + edge_id, for_game, errors, warnings)
			else:
				var edge: Dictionary = formal_edges[edge_id]
				var matches := (a == str(edge.a) and b == str(edge.b)) or (a == str(edge.b) and b == str(edge.a))
				if not matches or route_type.to_upper() != str(edge.route_type):
					_issue("Formal edge endpoints/type do not match: " + edge_id, for_game, errors, warnings)
	var settings: Variant = data.get("visual_settings", {})
	if not settings is Dictionary: errors.append("visual_settings must be an object.")
	else:
		for key in ["camera_yaw", "camera_pitch", "camera_size"]:
			if settings.has(key) and not _finite_number(settings[key]): errors.append("Invalid visual_settings." + key)
		if settings.has("camera_size") and not _positive_number(settings.camera_size): errors.append("camera_size must be positive.")
		if settings.has("camera_target") and not _point(settings.camera_target): errors.append("camera_target must contain exactly three finite numbers.")
		if settings.has("night") and not settings.night is bool: errors.append("visual_settings.night must be a boolean.")
		if settings.has("camera_pitch") and _finite_number(settings.camera_pitch):
			if float(settings.camera_pitch) < deg_to_rad(25.0) or float(settings.camera_pitch) > deg_to_rad(85.0):
				errors.append("camera_pitch must be between 25 and 85 degrees, stored in radians.")
	if for_game:
		for id in formal_nodes:
			if not node_ids.has(str(id)): errors.append("Missing formal node: " + str(id))
		for id in formal_edges:
			if not edge_ids.has(str(id)): errors.append("Missing formal edge: " + str(id))
		if node_ids.size() != 54 or edge_ids.size() != 57 or city_ids.size() != 16:
			errors.append("Production requires exactly 54 nodes, 57 routes and 16 cities.")
	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings,
		"counts": {"nodes": node_ids.size(), "cities": city_ids.size(), "routes": data.routes.size(), "decorations": data.decorations.size()}}

static func _check_id(item: Dictionary, label: String, ids: Dictionary, errors: Array[String]) -> void:
	var id := str(item.get("id", ""))
	if id.is_empty(): errors.append(label + " needs a placement id.")
	elif ids.has(id): errors.append("Duplicate placement id: " + id)
	else: ids[id] = true

static func _issue(message: String, strict: bool, errors: Array[String], warnings: Array[String]) -> void:
	if strict: errors.append(message)
	else: warnings.append(message)

static func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func _positive_number(value: Variant) -> bool:
	return _finite_number(value) and float(value) > 0

static func _point(value: Variant) -> bool:
	return value is Array and value.size() == 3 and _finite_number(value[0]) and _finite_number(value[1]) and _finite_number(value[2])

static func _asset_ids() -> Dictionary:
	var result := {}
	var path := "res://scripts/editor/map_asset_catalog.gd"
	if not ResourceLoader.exists(path): return result
	var catalog = load(path)
	for descriptor in catalog.list_assets(): result[str(descriptor.id)] = str(descriptor.get("category", ""))
	return result

static func seed_from_formal() -> Dictionary:
	var data := blank_layout()
	var formal := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var mapping := {"baghdad": "city_blue_dome", "constantinople": "city_byzantine", "rome": "city_roman",
		"cairo": "city_arab_port", "jeddah": "city_arab_port", "aden": "city_arab_port", "panti": "city_caravanserai",
		"delhi": "city_indian", "simhala": "city_tropical", "dagon": "city_tropical", "chenla": "city_tropical",
		"yumenguan": "city_gate", "changan": "city_chinese", "quanzhou": "city_port_chinese",
		"geumseong": "city_chinese", "heijokyo": "city_chinese"}
	for node_id in formal.board_nodes:
		var node: Dictionary = formal.board_nodes[node_id]
		var position := _formal_position(node.map_position)
		if str(node.node_type) == "CITY":
			data.cities.append({"id": "city_" + str(node_id), "city_id": str(node_id), "node_id": str(node_id),
				"asset_id": mapping.get(str(node_id), "city_blue_dome"), "position": position, "rotation_y": 0.0, "scale": 1.0})
		else: data.logic_nodes.append({"id": "node_" + str(node_id), "node_id": str(node_id), "position": position})
	for edge in formal.board_edges:
		var points: Array = []
		var source: Array = edge.get("movement_polyline", edge.get("movement_polyline_px", []))
		for index in range(1, source.size() - 1): points.append(_formal_position(source[index]))
		data.routes.append({"id": "route_" + str(edge.id), "edge_id": str(edge.id), "from_node": str(edge.a), "to_node": str(edge.b),
			"type": str(edge.route_type).to_lower(), "points": points})
	return data

static func _formal_position(value: Variant) -> Array:
	var point := Vector2.ZERO
	if value is Vector2: point = value
	elif value is Array and value.size() >= 2: point = Vector2(float(value[0]), float(value[1]))
	return [(point.x - 2048.0) * 0.012, 0.0, (point.y - 681.5) * 0.012]
