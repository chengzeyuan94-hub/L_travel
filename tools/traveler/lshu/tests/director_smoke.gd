extends SceneTree
## 第四幕「L叔在哪儿」· windowed smoke test of the director paths the day run does not reach. Hosts
## scenes/traveler/lshu_main.tscn with the director on (1920x1080 MSAA 4x SubViewport, fresh save in <out>/save, clock
## --scale 60 from --start-unix, frame cap ON):
##   1. frame cap: Engine.max_fps is 30 focused and unfocused (fps.focused / fps.unfocused, never below 30) and is put back on exit
##   2. L opens / closes the travel book (a real key event through the viewport)
##   3. dev keys (--lshu-dev): F1 cycles a light override and back to the clock, F3 previews another pool tile
##   4. live catch-up: the clock jumps 5 h ahead -> catchup event -> hard sync; the postcards of those hours get their
##      images (rendered under the cover on their own tiles), the away card shows
##   5. restart: the scene is freed (save written, lock released) and started again on the same save 6 h later ->
##      catch-up at launch, the away card, postcards rendered before the cover lifts
##   Godot --path . --script res://tools/traveler/lshu/tests/director_smoke.gd -- --park=24 --out=/abs/dir
## Last line: LSHU_DIRECTOR_SMOKE checks=C failed=F

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const SAVE: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_save.gd")

var viewport: SubViewport
var scene: Node3D
var director: Node
var out_dir: String = ""
var start_unix: int = 1790218800
var checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, ok: bool, value: Variant) -> void:
	checks.append({"name": name, "ok": ok, "value": value})
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, JSON.stringify(value).left(400)])

func _run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--start-unix="):
			start_unix = int(arg.trim_prefix("--start-unix="))
	if out_dir.is_empty():
		push_error("director_smoke: --out is required")
		quit(2)
		return
	var save_dir: String = out_dir.path_join("save")
	_clear_dir(save_dir)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)
	var preview: TextureRect = TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Engine.max_fps = 77
	await _start_scene(start_unix, save_dir)
	# 1. frame cap
	var ev: Dictionary = director.call("evidence")
	_check("fps_cap_on_start", Engine.max_fps == 30, {"max_fps": Engine.max_fps, "focused": ev.focused})
	# Carlos 2026-09-27: no unfocused throttling (screensaver beside other apps) — 30 focused and unfocused
	director.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	var out_fps: int = Engine.max_fps
	director.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	var in_fps: int = Engine.max_fps
	_check("fps_30_focused_and_unfocused", out_fps == 30 and in_fps == 30, {"focus_out": out_fps, "focus_in": in_fps})
	# 2. L -> travel book
	var ui: CanvasLayer = director.get("ui")
	_key(KEY_L)
	await _frames(40)
	var book_open: bool = bool(ui.call("is_busy"))
	_key(KEY_L)
	await _wait_until(func() -> bool: return not bool(ui.call("is_busy")), 3000)
	_check("L_opens_travel_book", book_open and not bool(ui.call("is_busy")), {"opened": book_open})
	# 3. dev keys
	_key(KEY_F1)
	await _frames(3)
	var o1: String = str(director.get("light_override"))
	for _i: int in 4:
		_key(KEY_F1)
		await _frames(2)
	var o5: String = str(director.get("light_override"))
	_check("F1_light_override_cycle", o1 == "morning" and o5 == "", {"first": o1, "after_5": o5})
	var tile_before: String = str(scene.get("tile_id"))
	_key(KEY_F3)
	await _wait_until(func() -> bool: return bool(director.get("preview")) and not bool(director.get("switching")), 15000)
	_check("F3_preview_tile", str(scene.get("tile_id")) != tile_before and bool(director.get("preview")), {"before": tile_before, "after": scene.get("tile_id")})
	# 4. live catch-up: 5 h later
	var hs0: int = int((director.get("stats") as Dictionary).get("hard_syncs", 0))
	var off0: int = int((director.get("stats") as Dictionary).get("postcards_offscreen", 0))
	director.set("anchor_logic", float(director.get("anchor_logic")) + 5.0 * 3600.0)
	await _wait_until(func() -> bool: return int((director.get("stats") as Dictionary).get("hard_syncs", 0)) > hs0 and not bool(director.get("switching")), 30000)
	await _frames(30)
	var s: Dictionary = director.get("save")
	var st: Dictionary = director.get("stats")
	var away: bool = _away_visible(ui)
	var pending: Array = s.get("pending_renders", []) as Array
	_check("live_catchup_hard_sync", int(st.hard_syncs) > hs0 and int((st.events as Dictionary).get("catchup", 0)) >= 1, {"hard_syncs": st.hard_syncs, "catchup_events": (st.events as Dictionary).get("catchup", 0)})
	_check("live_catchup_away_card", away, ui.call("state"))
	_check("live_catchup_postcards_rendered", pending.is_empty(), {"pending": pending, "offscreen_rendered": int(st.postcards_offscreen) - off0})
	_check("stage_in_sync_after_catchup", str(scene.get("tile_id")) == str((s.current_leg as Dictionary).tile) and not bool(director.get("preview")), {"stage": scene.get("tile_id"), "leg": (s.current_leg as Dictionary).tile})
	var shot1: Image = viewport.get_texture().get_image()
	shot1.save_png(out_dir.path_join("smoke_live_catchup.png"))
	var logic_end: float = float(director.call("logic_now"))
	# 5. restart 6 h later on the same save
	var lock_path: String = save_dir.path_join("save.lock")
	scene.queue_free()
	await _frames(5)
	_check("fps_restored_on_exit", Engine.max_fps == 77, Engine.max_fps)
	_check("lock_released_on_exit", not FileAccess.file_exists(lock_path), lock_path)
	var disk: Variant = JSON.parse_string(FileAccess.get_file_as_string(save_dir.path_join("save.json")))
	_check("save_written_on_exit", disk is Dictionary and float((disk as Dictionary).get("last_seen_unix", 0.0)) >= logic_end - 120.0, {"last_seen": (disk as Dictionary).get("last_seen_unix", 0) if disk is Dictionary else null, "logic_end": logic_end})
	var off1: int = 0
	await _start_scene(int(logic_end + 6.0 * 3600.0), save_dir)
	var st2: Dictionary = director.get("stats")
	var s2: Dictionary = director.get("save")
	await _frames(30)
	var ui2: CanvasLayer = director.get("ui")
	off1 = int(st2.postcards_offscreen)
	_check("restart_catchup_at_launch", int((st2.events as Dictionary).get("catchup", 0)) >= 1, st2.events)
	_check("restart_away_card", _away_visible(ui2), ui2.call("state"))
	_check("restart_postcards_rendered_before_shown", (s2.get("pending_renders", []) as Array).is_empty(), {"pending": s2.get("pending_renders", []), "offscreen": off1})
	var shot2: Image = viewport.get_texture().get_image()
	shot2.save_png(out_dir.path_join("smoke_restart_away.png"))
	var fails: int = 0
	for c: Variant in checks:
		if not bool((c as Dictionary).ok):
			fails += 1
	var f: FileAccess = FileAccess.open(out_dir.path_join("director_smoke_report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema": "lshu.director_smoke.v1", "checks": checks, "stats_first": st, "stats_restart": st2}, " "))
	f.close()
	print("LSHU_DIRECTOR_SMOKE checks=%d failed=%d" % [checks.size(), fails])
	scene.queue_free()
	await _frames(5)
	quit(0 if fails == 0 else 1)

func _start_scene(now_unix: int, save_dir: String) -> void:
	scene = (load(SCENE) as PackedScene).instantiate() as Node3D
	scene.set("director_mode", "on")
	scene.set("extra_args", PackedStringArray(["--lshu-clock-scale=60", "--lshu-now=%d" % now_unix, "--lshu-save-dir=" + save_dir, "--lshu-dev"]))
	director = scene.get_node("Director")
	viewport.add_child(scene)
	await _wait_until(func() -> bool: return bool(director.get("started")), 60000)
	await _frames(20)

func _away_visible(ui: CanvasLayer) -> bool:
	var ac: Control = ui.call("away_control") as Control
	return ac != null and ac.visible and ac.modulate.a > 0.05

func _key(code: Key) -> void:
	var ev: InputEventKey = InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	viewport.push_input(ev)
	var up: InputEventKey = ev.duplicate() as InputEventKey
	up.pressed = false
	viewport.push_input(up)

func _frames(n: int) -> void:
	for _i: int in n:
		await process_frame

func _wait_until(cond: Callable, ms: int) -> void:
	var t0: int = Time.get_ticks_msec()
	while not bool(cond.call()) and Time.get_ticks_msec() - t0 < ms:
		await process_frame

func _clear_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for sub: String in d.get_directories():
		_clear_dir(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))
	for fname: String in d.get_files():
		DirAccess.remove_absolute(path.path_join(fname))
