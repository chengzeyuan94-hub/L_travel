extends SceneTree
## 第四幕「L叔在哪儿」· tile-switch hitch test (fix #6 acceptance: main-thread max frame <= 50 ms).
## Hosts scenes/traveler/lshu_main.tscn in a 1920x1080 MSAA 4x SubViewport (same as the capture harness), waits
## for the first tile and the live prewarm, then switches N times through the pool with the scene's public
## load_tile(id, budget_ms). Every frame interval (process_frame to process_frame, wall clock) is recorded;
## a switch window runs from the load_tile call to 10 frames after it returned.
##
##   Godot --path . --script res://tools/traveler/lshu/qa/lshu_switch_test.gd -- --park=1 --switches=20
##         --out=docs/reports/traveler-lshu-p0-20260923/switch/switch_test.json [--budget-ms=6] [--light=day]

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"

var frame_ms: Array[float] = []
var process_ms: Array[float] = []
var last_us: int = 0
var recording: bool = false

func _initialize() -> void:
	call_deferred("_run")

func _on_frame() -> void:
	var now: int = Time.get_ticks_usec()
	if recording and last_us > 0:
		frame_ms.append(float(now - last_us) / 1000.0)
		process_ms.append(float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0)
	last_us = now

func _run() -> void:
	var switches: int = 20
	var budget_ms: float = 6.0
	var out_path: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--switches="):
			switches = int(arg.trim_prefix("--switches="))
		elif arg.begins_with("--budget-ms="):
			budget_ms = float(arg.trim_prefix("--budget-ms="))
		elif arg.begins_with("--out="):
			out_path = arg.trim_prefix("--out=")
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	var viewport: SubViewport = SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)
	# a displayed texture keeps the macOS drawable active
	var preview: TextureRect = TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scene: Node3D = (load(SCENE) as PackedScene).instantiate() as Node3D
	viewport.add_child(scene)
	process_frame.connect(_on_frame)
	var waited: int = 0
	while scene.get("tile") == null or scene.get("loading"):
		await process_frame
		waited += 1
		if waited > 3000:
			push_error("LSHU switch test: first tile never became ready")
			quit(1)
			return
	if not bool(scene.get("prewarmed")):
		await scene.prewarm_done
	for _i: int in 90:
		await process_frame
	var ids: Array[String] = scene.get("tile_ids")
	var start: int = ids.find(str(scene.get("tile_id")))
	var rows: Array = []
	var overall_max: float = 0.0
	var overall_proc_max: float = 0.0
	var baseline_ms: Array[float] = []
	recording = true
	for _i: int in 60:
		await process_frame
	baseline_ms = frame_ms.duplicate()
	for s: int in switches:
		var id: String = ids[(start + 1 + s) % ids.size()]
		frame_ms.clear()
		process_ms.clear()
		var t0: int = Time.get_ticks_usec()
		var ok: bool = await scene.call("load_tile", id, budget_ms)
		var load_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
		for _k: int in 10:
			await process_frame
		var worst: float = 0.0
		for v: float in frame_ms:
			worst = maxf(worst, v)
		var worst_proc: float = 0.0
		for v2: float in process_ms:
			worst_proc = maxf(worst_proc, v2)
		overall_max = maxf(overall_max, worst)
		overall_proc_max = maxf(overall_proc_max, worst_proc)
		var tile: Node3D = scene.get("tile")
		rows.append({"switch": s + 1, "tile": id, "ok": ok, "pose": (scene.get("character") as Node3D).get("active").get("pose"), "frames": frame_ms.size(), "load_wall_ms": load_ms,
			"max_frame_ms": worst, "max_process_ms": worst_proc, "swap_ms": scene.get("swap_ms"), "build_timings_ms": tile.get("timings"), "frame_ms": frame_ms.duplicate()})
		print("LSHU_SWITCH ", JSON.stringify({"switch": s + 1, "tile": id, "ok": ok, "frames": frame_ms.size(), "max_frame_ms": worst, "max_process_ms": worst_proc, "swap_ms": scene.get("swap_ms"), "load_wall_ms": load_ms}))
	recording = false
	var base_sorted: Array[float] = baseline_ms.duplicate()
	base_sorted.sort()
	var report: Dictionary = {"schema": "lshu.switch-test.v1", "switches": switches, "budget_ms": budget_ms, "limit_ms": 50.0,
		"max_frame_ms": overall_max, "max_process_ms": overall_proc_max, "pass": overall_max <= 50.0,
		"prewarm_ms": scene.get("prewarm_ms"), "idle_frame_ms": {"p50": base_sorted[base_sorted.size() / 2] if not base_sorted.is_empty() else 0.0, "max": base_sorted.back() if not base_sorted.is_empty() else 0.0},
		"definition": "wall-clock interval between consecutive SceneTree.process_frame signals (main-thread frame, includes render submission); window = load_tile() call .. 10 frames after it returned; 1920x1080 MSAA 4x SubViewport",
		"rows": rows}
	if not out_path.is_empty():
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var f: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(report, " "))
		f.close()
	print("LSHU_SWITCH_DONE ", JSON.stringify({"switches": switches, "max_frame_ms": overall_max, "max_process_ms": overall_proc_max, "pass": overall_max <= 50.0}))
	quit(0)
