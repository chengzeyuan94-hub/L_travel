extends "res://tools/lowpoly/density_017_capture.gd"
## Compare all sixteen city GLBs inside the unchanged production game renderer.
## Candidate replacement is in this evidence process only; no production writes.

var candidates := {}
var originals := {}
var city_library := ""

func _run() -> void:
	OUTPUT = OS.get_environment("SILKROAD_CITY_OUTPUT")
	city_library = OS.get_environment("SILKROAD_CITY_LIBRARY")
	if OUTPUT.is_empty() or city_library.is_empty() or DisplayServer.get_name() == "headless":
		push_error("019 city capture requires paths and a rendered window")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(OUTPUT.path_join("captures"))
	DirAccess.make_dir_recursive_absolute(city_library.path_join("previews/map"))
	Engine.max_fps = 60
	var content := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var configs := [{"display_name":"城市造型验收", "color_id":"red", "controller_type":"LOCAL_HUMAN"},
		{"display_name":"AI", "color_id":"blue", "controller_type":"AI"}]
	var prepared := SetupSystem.prepare_new_game(content, configs, 2026090710, "FORMAL")
	if not prepared.get("success",false) or not SetupSystem.finalize_new_game().get("success",false):
		get_tree().quit(1)
		return
	_screen = (load("res://scenes/game_screen.tscn") as PackedScene).instantiate() as Control
	add_child(_screen)
	_screen.show()
	_screen.call("on_game_started", configs)
	_screen.call("cancel_ai")
	_board = _screen.get_node("%BoardView") as Control
	await _frames(12)
	_freeze_detail_stills()
	for actor in (_board.get("_pieces") as Dictionary).values():
		(actor as Node).process_mode = Node.PROCESS_MODE_DISABLED
	_report = {"task":"TASK-CITY-LIBRARY-019", "captures":[], "models":{}, "errors":[],
		"method":"Production GameScreen, Compatibility renderer, unchanged light/camera/terrain/routes/HUD. Only in-memory city nodes switch. Water/ambient fixed at 8s and stochastic particles hidden and actor idle motion frozen on both revisions. Fixed 384px crops at the same projected anchor, no resizing or retouching. Smoke-anchor correctness and motion are not covered by these stills.",
		"renderer":RenderingServer.get_current_rendering_method(), "godot":Engine.get_version_info(),
		"source_start_sha256":_source_hashes(),
		"script_sha256":FileAccess.get_sha256(get_script().resource_path)}
	var ids: Array = content.get("cities",{}).keys()
	ids.sort()
	for cid_value in ids:
		var cid := String(cid_value)
		var city_root: Node3D = (_board.get("_static_root") as Node).get_node("City_"+cid)
		originals[cid] = city_root.get_child(0)
		var path := city_library.path_join("exports").path_join(cid+".glb")
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path,state,64) != OK:
			push_error("Candidate import failed: "+cid)
			get_tree().quit(1)
			return
		var candidate := doc.generate_scene(state) as Node3D
		city_root.add_child(candidate)
		candidate.visible = false
		candidates[cid] = candidate
		_report["models"][cid] = {"before_sha256":FileAccess.get_sha256("res://assets/game/lowpoly/cities/"+cid+".glb"),
			"after_sha256":FileAccess.get_sha256(path), "parent_transform":str(city_root.transform)}
	for phase in ["before","after"]:
		for cid in ids:
			(originals[cid] as Node3D).visible = phase == "before"
			(candidates[cid] as Node3D).visible = phase == "after"
		for cid_value in ids:
			var cid := String(cid_value)
			var point: Vector2 = _board.call("_node_pos", cid)
			point += Vector2(0,-85)
			for zoom in [2.6,4.2]:
				_board.focus_logical_point(point,zoom)
				await _frames(12)
				await RenderingServer.frame_post_draw
				var picture := get_viewport().get_texture().get_image()
				var camera: Camera3D = _board.get("_camera")
				var anchor := PlanetGeometry.to_world(point,0.08)
				var pixel: Vector2 = _board.call("_project",anchor)
				pixel += _board.global_position
				var crop := Rect2i(Vector2i(pixel)-Vector2i(192,192),Vector2i(384,384))
				crop.position.x = clampi(crop.position.x,0,picture.get_width()-384)
				crop.position.y = clampi(crop.position.y,0,picture.get_height()-384)
				var filename: String = cid+"-z"+str(roundi(zoom*10))+"-"+phase
				var raw := OUTPUT.path_join("captures").path_join(filename+".png")
				var preview := city_library.path_join("previews/map").path_join(filename+".jpg")
				var err := picture.save_png(raw)
				var err_preview := picture.get_region(crop).save_jpg(preview,0.94)
				if err != OK or err_preview != OK:
					_report["errors"].append(filename+": save failed")
				_report["captures"].append({"id":cid,"phase":phase,"zoom":zoom,"raw":raw,"preview":preview,
					"sha256":FileAccess.get_sha256(preview),"crop":[crop.position.x,crop.position.y,384,384],
					"camera":_board.get_map_debug_state()["camera"],"camera_transform":str(camera.transform),
					"camera_fov":camera.fov,"root_size":str(get_viewport().get_visible_rect().size),"board_viewport_size":str((_board.get("_viewport") as SubViewport).size)})
			print("CITY_019_MAP_CAPTURED ",phase," ",cid)
	for cid in ids:
		var after := FileAccess.get_sha256(city_library.path_join("exports").path_join(cid+".glb"))
		if after != _report["models"][cid]["after_sha256"]:
			_report["errors"].append(str(cid)+": GLB changed during capture")
	_report["source_end_sha256"] = _source_hashes()
	_report["inputs_stable"] = _report["source_start_sha256"] == _report["source_end_sha256"]
	var file := FileAccess.open(OUTPUT.path_join("map-capture-report.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(_report,"\t"))
	file.close()
	_screen.call("cancel_ai")
	_board.cancel_all_animations()
	AudioManager.silence_all()
	print("CITY_019_MAP_COMPLETE ",_report["captures"].size()," errors=",_report["errors"].size())
	get_tree().quit(0 if _report["errors"].is_empty() and _report["inputs_stable"] else 1)
