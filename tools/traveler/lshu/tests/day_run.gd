extends SceneTree
## 第四幕「L叔在哪儿」· accelerated day run of the whole act (director + stage + motion + lamp + postcards + UI).
## Hosts scenes/traveler/lshu_main.tscn with the director forced on in a 1920x1080 MSAA 4x SubViewport (as the other
## act-4 harnesses do), on a fresh save in <out>/save, the clock at --scale (600) from --date --start (07:00 local) for
## --hours (24) simulated hours, and saves one frame every --every-min (30) simulated minutes (48 frames) plus an event
## log. The director runs uncapped here (--lshu-fps-cap=off, vsync off) so the frame times measure the work, like the P0
## switch test; the 30 / 10 fps cap itself is checked by test_director.gd and the normal-mode run.
## Once, while he is settled in daylight, it clicks him (a real mouse event through the viewport: bow + photo), and it
## opens and closes the first postcard through the UI (postcard_read -> mark_read + save).
##
##   Godot --path . --script res://tools/traveler/lshu/tests/day_run.gd -- --park=24 --out=/abs/dir
##         [--scale=600] [--date=2026-09-24] [--start=07:00] [--hours=24] [--every-min=30]
## Output: <out>/frames/f_<k>.jpg (960x540), <out>/day_run_report.json, <out>/events.jsonl, <out>/save/ (the save and
## postcards/). Last line: LSHU_DAY_RUN frames=N events=E arrivals=A departures=D road_frames=R lamp_night_frames=L
## night_shown=S postcards=P snaps=S p95_ms=X switch_max_ms=Y failed=F
## Night check (night_lamp_rule, the lamp rule of decision 4): every saved night frame that shows him must have his
## lantern lit, or the lamp's own reason for not setting one (a fire or lamp light of the tile within near_radius_m);
## how many frames actually have the lantern is reported, not gated (it depends on the day's stops).
## Switch timing (repair_r2): the stage's work log (lshu_main.gd mark_work: build slices, the staged plan slices, each
## commit step, the snapshot, bind_tile's main-thread pieces, resolve / light ticks) is taken every frame and put next
## to that frame's interval (the interval measured at frame k covers the work done in frame k-1) with the render
## pipelines compiled while it was drawn. Every switch / staging window prints one LSHU_DAY_SWITCH_WINDOW line (its
## heaviest frame with the work in it, the commit frame, the staging frames) and LSHU_DAY_SWITCH_WORST sums them up;
## the per-frame rows go to <out>/switch_frames.json.

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const CLOCK: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const SAVE: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_save.gd")

var scene: Node3D
var viewport: SubViewport
var director: Node
var out_dir: String = ""
var scale: float = 600.0
var date_s: String = "2026-09-24"
var start_s: String = "07:00"
var hours: float = 24.0
var every_min: float = 30.0
## --plan-check: the stage also works every planned swap out the old way and compares (lshu_main.gd plan_check); a QA
## run, not a timing run.
var plan_check: bool = false
var start_unix: int = 0
var events: Array = []
var frames: Array = []
var switches: Array = []
var postcards: Array = []
var snaps: Array = []
var frame_ms: Array[float] = []
var frame_flags: Array[int] = []
var last_us: int = 0
var recording: bool = false
var capture_frame: bool = false
var busy_until_frame: int = -1
var frame_index: int = 0
var checks: Array = []
var read_state: int = 0   # 0 not tried, 1 running, 2 done
var work_rows: Array = []   # [frame, interval_ms, flags, work [[label, ms], ...], pipelines compiled [canvas, mesh, surface, draw, specialization]]
var pipes_prev: Array[int] = [0, 0, 0, 0, 0]

const PIPES: Array[int] = [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]

const F_SWITCH: int = 1
const F_STAGING: int = 2
const F_CAPTURE: int = 4
const F_RENDER: int = 8

func _initialize() -> void:
	call_deferred("_run")

func _on_frame() -> void:
	var now: int = Time.get_ticks_usec()
	frame_index += 1
	var work: Array = scene.call("take_frame_work") if scene != null and is_instance_valid(scene) else []
	var pipes: Array[int] = []
	for i: int in PIPES.size():
		var v: int = RenderingServer.get_rendering_info(PIPES[i] as RenderingServer.RenderingInfo)
		pipes.append(v - pipes_prev[i])
		pipes_prev[i] = v
	if recording and last_us > 0:
		var flags: int = 0
		if bool(director.get("switching")):
			flags |= F_SWITCH
			busy_until_frame = frame_index + 10
		if bool(director.get("staging")):
			flags |= F_STAGING
			busy_until_frame = frame_index + 10
		if frame_index <= busy_until_frame:
			flags |= F_SWITCH
		if capture_frame:
			flags |= F_CAPTURE
		if bool(director.get("rendering")) or bool(director.get("snapping")):
			flags |= F_RENDER
		frame_ms.append(float(now - last_us) / 1000.0)
		frame_flags.append(flags)
		var iv: float = float(now - last_us) / 1000.0
		if flags & (F_SWITCH | F_STAGING | F_CAPTURE) or not work.is_empty() or iv > 20.0 or pipes.max() > 0:
			work_rows.append([frame_index, snappedf(iv, 0.01), flags, work, pipes])
	capture_frame = false
	last_us = now

func _run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--scale="):
			scale = float(arg.trim_prefix("--scale="))
		elif arg.begins_with("--date="):
			date_s = arg.trim_prefix("--date=")
		elif arg.begins_with("--start="):
			start_s = arg.trim_prefix("--start=")
		elif arg.begins_with("--hours="):
			hours = float(arg.trim_prefix("--hours="))
		elif arg.begins_with("--every-min="):
			every_min = float(arg.trim_prefix("--every-min="))
		elif arg == "--plan-check":
			plan_check = true
	if out_dir.is_empty():
		push_error("day_run: --out is required")
		quit(2)
		return
	var d: PackedStringArray = date_s.split("-")
	var hm: PackedStringArray = start_s.split(":")
	var local_unix: int = Time.get_unix_time_from_datetime_dict({"year": int(d[0]), "month": int(d[1]), "day": int(d[2]), "hour": int(hm[0]), "minute": int(hm[1]), "second": 0})
	start_unix = local_unix - int(CLOCK.call("system_tz_offset_s"))
	var save_dir: String = out_dir.path_join("save")
	_clear_dir(save_dir)
	_clear_dir(out_dir.path_join("frames"))
	DirAccess.make_dir_recursive_absolute(out_dir.path_join("frames"))
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
	scene = (load(SCENE) as PackedScene).instantiate() as Node3D
	scene.set("director_mode", "on")
	scene.set("extra_args", PackedStringArray(["--lshu-clock-scale=%s" % str(scale), "--lshu-now=%d" % start_unix,
		"--lshu-save-dir=" + save_dir, "--lshu-fps-cap=off", "--lshu-dev"]))
	director = scene.get_node("Director")
	director.connect("event_handled", _on_event)
	director.connect("switch_finished", func(info: Dictionary) -> void: switches.append(info))
	director.connect("postcard_finished", func(res: Dictionary) -> void: postcards.append(_pc_row(res)))
	director.connect("snap_finished", func(res: Dictionary) -> void: snaps.append(_pc_row(res)))
	scene.set("work_log", true)
	scene.set("plan_check", plan_check)
	viewport.add_child(scene)
	process_frame.connect(_on_frame)
	var waited: int = 0
	while not bool(director.get("started")):
		await process_frame
		waited += 1
		if waited > 6000:
			push_error("day_run: the director never started")
			quit(1)
			return
	recording = true
	var total: int = int(round(hours * 60.0 / every_min))
	var clicked: bool = false
	var read_done: bool = false
	var end_logic: float = float(start_unix) + hours * 3600.0
	var k: int = 0
	while k < total:
		await process_frame
		var logic: float = float(director.call("logic_now"))
		if not clicked and _click_ok(logic):
			clicked = _click_him()
		if read_state == 0 and _read_ready():
			read_state = 1
			_read_first_postcard()   # runs beside the capture loop (never delays a frame)
		if logic >= float(start_unix) + float(k) * every_min * 60.0:
			await _capture(k)
			k += 1
	while float(director.call("logic_now")) < end_logic:
		await process_frame
	recording = false
	for _i: int in 5:
		await process_frame
	read_done = read_state == 2
	_finish(clicked, read_done)

func _on_event(e: Dictionary, info: Dictionary) -> void:
	var row: Dictionary = {"type": e.get("type", ""), "at": int(e.get("at", 0)), "local": _local(float(e.get("at", 0))), "leg": int(e.get("leg", -1)),
		"tile": e.get("tile", ""), "name": e.get("name", ""), "kit": e.get("kit", ""), "home": e.get("home", false), "night": e.get("night", false),
		"action": info.get("action", ""), "stage_tile": info.get("stage_tile", ""), "stage_leg": info.get("stage_leg", -1),
		"logic_when_handled": float(director.call("logic_now")), "real_ms": Time.get_ticks_msec()}
	if e.has("postcard"):
		row["postcard"] = e.get("postcard")
	events.append(row)

func _pc_row(res: Dictionary) -> Dictionary:
	var rep: Dictionary = res.get("report", {}) as Dictionary
	return {"id": res.get("id", ""), "ok": res.get("ok", false), "timed_out": res.get("timed_out", false), "path": res.get("path", ""),
		"rule": res.get("rule", ""), "error": res.get("error", ""), "offscreen": res.get("offscreen", false), "tile": rep.get("tile", ""),
		"light": rep.get("light", ""), "his_frame_fraction": rep.get("his_frame_fraction", 0.0), "timing_ms": rep.get("timing_ms", {}),
		"logic": float(director.call("logic_now")), "local": _local(float(director.call("logic_now")))}

func _local(unix: float) -> String:
	var c: Dictionary = CLOCK.call("compile_config", CLOCK.call("load_config"))
	return str((CLOCK.call("local_info", unix, c) as Dictionary).get("time_label", ""))

## Click him once in daylight while he is settled on a travel stop (not while a switch or a render runs).
func _click_ok(logic: float) -> bool:
	if logic < float(start_unix) + 3.0 * 3600.0:
		return false
	var ev: Dictionary = director.call("evidence")
	return str(ev.get("substate", "")) == "STAY" and str(ev.get("motion_phase", "")) == "kit" and not bool(ev.get("switching", true)) \
		and not bool(director.get("rendering")) and float(ev.get("night_weight", 1.0)) <= 0.0

func _click_him() -> bool:
	var motion: Node = director.get("motion")
	var rect: Rect2 = motion.call("figure_rect")
	if rect.size.x <= 0.0:
		return false
	var ev: InputEventMouseButton = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = rect.get_center()
	ev.global_position = rect.get_center()
	viewport.push_input(ev)
	var up: InputEventMouseButton = ev.duplicate() as InputEventMouseButton
	up.pressed = false
	viewport.push_input(up)
	print("LSHU_DAY_CLICK ", JSON.stringify({"at": _local(float(director.call("logic_now"))), "pos": [ev.position.x, ev.position.y]}))
	return true

func _read_ready() -> bool:
	return not (SAVE.call("unread", director.get("save")) as Array).is_empty() and not bool(director.get("switching"))

## Opens the first rendered postcard in the UI and closes it: the director must mark it read and write the save.
func _read_first_postcard() -> void:
	var s: Dictionary = director.get("save")
	var unread: Array = SAVE.call("unread", s)
	var rec: Dictionary = unread[0]
	var ui: CanvasLayer = director.get("ui")
	var got: Array[String] = []
	var cb: Callable = func(id: String) -> void: got.append(id)
	ui.connect("postcard_read", cb)
	ui.call("open_postcard", rec)
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 700:
		await process_frame
	ui.call("close_postcard")
	t0 = Time.get_ticks_msec()
	while got.is_empty() and Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	for _i2: int in 3:
		await process_frame
	ui.disconnect("postcard_read", cb)
	var s2: Dictionary = director.get("save")
	var rec2: Dictionary = SAVE.call("find_postcard", s2, str(rec.id))
	var disk: Dictionary = {}
	var f: String = str((director.get("store") as RefCounted).get("dir")).path_join("save.json")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(f))
	if parsed is Dictionary:
		disk = SAVE.call("find_postcard", parsed, str(rec.id))
	_check("postcard_read_marked", bool(rec2.get("read", false)) and bool(disk.get("read", false)), {"id": rec.id, "signal": got, "memory": rec2.get("read", false), "disk": disk.get("read", false)})
	read_state = 2

func _capture(k: int) -> void:
	await RenderingServer.frame_post_draw
	capture_frame = true
	var ev: Dictionary = director.call("evidence")
	var img: Image = viewport.get_texture().get_image()
	img.resize(960, 540, Image.INTERPOLATE_BILINEAR)
	var file: String = "frames/f_%02d.jpg" % k
	img.save_jpg(out_dir.path_join(file), 0.88)
	var lamp: Dictionary = ev.get("lamp", {}) as Dictionary
	var lamp_lit: bool = str(lamp.get("mode", "none")) != "none" and bool(lamp.get("present", false)) and float(lamp.get("night_weight", 0.0)) > 0.0
	# the lamp rule's own "not needed" case: a fire or a lamp light of the tile within near_radius_m of him
	var near: Dictionary = lamp.get("nearest_light", {}) as Dictionary
	var near_r: float = float(lamp.get("near_radius_m", -1.0))
	var near_light: bool = str(lamp.get("mode", "none")) == "none" and not near.is_empty() and near_r >= 0.0 and float(near.get("dist_m", INF)) <= near_r
	# is he drawn on the tile (kit rig or walker with any opacity, motion bound to the stage, not on the road)
	var motion: Node = director.get("motion")
	var mf: Dictionary = motion.get("last_frame") as Dictionary if motion != null else {}
	var him_alpha: float = 0.0
	if motion != null and bool(motion.get("bound")) and str(ev.substate) != "ROAD" and not mf.is_empty():
		him_alpha = maxf(float(mf.get("k_alpha", 0.0)), float(mf.get("w_alpha", 0.0)) if bool(mf.get("w_show", false)) else 0.0)
	var fr: Dictionary = {"k": k, "him_alpha": him_alpha, "lamp_reason": lamp.get("reason", ""), "lamp_near_light": near_light,
		"lamp_nearest": near, "lamp_near_radius_m": near_r, "file": file, "logic": float(ev.logic), "target_local": _local(float(start_unix) + float(k) * every_min * 60.0),
		"local": ev.local, "substate": ev.substate, "night_phase": ev.night_phase, "leg": ev.leg, "leg_name": ev.leg_name, "stage_tile": ev.stage_tile,
		"stage_leg": ev.stage_leg, "stage_name": ev.stage_name, "in_sync": int(ev.leg) == int(ev.stage_leg), "motion_phase": ev.motion_phase,
		"fire_level": ev.fire_level, "night_weight": ev.night_weight, "lamp_mode": lamp.get("mode", "none"), "lamp_present": lamp.get("present", false),
		"lamp_hold": lamp.get("hold", false), "lamp_lit": lamp_lit, "lamp_energy": lamp.get("light_energy", 0.0), "light": ev.light,
		"switching": ev.switching, "unread": (SAVE.call("unread", director.get("save")) as Array).size(),
		"static_mem_mb": float(OS.get_static_memory_usage()) / 1000000.0,
		"video_mem_mb": float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1000000.0,
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)), "nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))}
	frames.append(fr)
	print("LSHU_DAY_FRAME ", JSON.stringify({"k": k, "local": fr.local, "substate": fr.substate, "name": fr.stage_name, "phase": fr.motion_phase, "lamp": fr.lamp_lit, "fire": snappedf(float(fr.fire_level), 0.01)}))

func _check(name: String, ok: bool, value: Variant) -> void:
	checks.append({"name": name, "ok": ok, "value": value})

func _stats(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"n": 0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var s: Array[float] = values.duplicate()
	s.sort()
	var n: int = s.size()
	return {"n": n, "p50": s[n / 2], "p95": s[mini(n - 1, int(n * 0.95))], "p99": s[mini(n - 1, int(n * 0.99))], "max": s[n - 1]}

func _finish(clicked: bool, read_done: bool) -> void:
	var st: Dictionary = (director.get("stats") as Dictionary).duplicate(true)
	var all_ms: Array[float] = []
	var steady_ms: Array[float] = []
	var switch_ms: Array[float] = []
	var render_ms: Array[float] = []
	for i: int in frame_ms.size():
		var f: int = frame_flags[i]
		if f & F_CAPTURE:
			continue
		all_ms.append(frame_ms[i])
		if f & F_RENDER:
			render_ms.append(frame_ms[i])
		elif f & (F_SWITCH | F_STAGING):
			switch_ms.append(frame_ms[i])
		else:
			steady_ms.append(frame_ms[i])
	var counts: Dictionary = {}
	for e: Variant in events:
		var ty: String = str((e as Dictionary).type)
		counts[ty] = int(counts.get(ty, 0)) + 1
	var arrivals: int = 0
	var departures: int = 0
	for e2: Variant in events:
		var ed: Dictionary = e2
		if (str(ed.type) == "arrive" or str(ed.type) == "home_arrive") and str(ed.action) == "switch":
			arrivals += 1
		if (str(ed.type) == "leave" or str(ed.type) == "home_leave") and str(ed.action) == "leave":
			departures += 1
	var road_frames: int = 0
	var lamp_frames: int = 0
	var night_frames: int = 0
	var night_shown: int = 0
	var night_near_light: int = 0
	var night_unlit: Array = []
	var in_sync: int = 0
	for fr: Variant in frames:
		var fd: Dictionary = fr
		if str(fd.substate) == "ROAD":
			road_frames += 1
		if float(fd.night_weight) > 0.0:
			night_frames += 1
			if bool(fd.lamp_lit):
				lamp_frames += 1
			# the lamp rule (decision 4): every night frame that shows him has his lantern lit, or a fire / lamp light
			# of the tile within near_radius_m (the rule's own reason for not setting one down)
			if float(fd.him_alpha) > 0.0:
				night_shown += 1
				if bool(fd.lamp_near_light) and not bool(fd.lamp_lit):
					night_near_light += 1
				elif not bool(fd.lamp_lit):
					night_unlit.append({"k": fd.k, "local": fd.local, "name": fd.stage_name, "phase": fd.motion_phase, "lamp_mode": fd.lamp_mode,
						"reason": fd.lamp_reason, "nearest": fd.lamp_nearest})
		if bool(fd.in_sync):
			in_sync += 1
	var save_dir: String = out_dir.path_join("save")
	var files: Array[String] = []
	var pcdir: DirAccess = DirAccess.open(save_dir.path_join("postcards"))
	if pcdir != null:
		for fname: String in pcdir.get_files():
			if fname.ends_with(".jpg"):
				files.append(fname)
	var s: Dictionary = director.get("save")
	var rendered_records: int = 0
	var snap_records: int = 0
	for v: Variant in s.get("postcards", []) as Array:
		var pc: Dictionary = v
		if str(pc.get("file", "")) != "" and FileAccess.file_exists(str(pc.file)):
			rendered_records += 1
		if str(pc.get("type", "")) == "snap":
			snap_records += 1
	var steady: Dictionary = _stats(steady_ms)
	var sw: Dictionary = _stats(switch_ms)
	var everything: Dictionary = _stats(all_ms)
	var windows: Array = _switch_windows()
	_check("frames_48", frames.size() == int(round(hours * 60.0 / every_min)), frames.size())
	_check("arrival", arrivals >= 1, arrivals)
	_check("departure", departures >= 1, departures)
	_check("road_phase_frame", road_frames >= 1 or int(counts.get("road_start", 0)) >= 1, {"frames": road_frames, "road_start_events": counts.get("road_start", 0)})
	_check("night_lamp_rule", night_frames >= 1 and night_shown >= 1 and night_unlit.is_empty(), {"night_frames": night_frames, "night_frames_showing_him": night_shown,
		"lamp_lit": lamp_frames, "fire_or_lamp_within_near_radius": night_near_light, "uncovered": night_unlit})
	_check("postcards_on_disk", files.size() >= 1 and rendered_records >= 1, {"jpg": files.size(), "records_with_file": rendered_records})
	_check("snap_clicked", clicked and snap_records >= 1 and not snaps.is_empty() and bool((snaps[0] as Dictionary).ok), {"clicked": clicked, "snap_records": snap_records, "snaps": snaps})
	_check("postcard_read", read_done, read_done)
	_check("save_written", FileAccess.file_exists(save_dir.path_join("save.json")) and int(st.get("write_failures", 0)) == 0, {"writes": st.get("writes", 0), "failures": st.get("write_failures", 0)})
	_check("frame_p95_le_33ms", float(everything.p95) <= 33.3, everything)
	_check("switch_max_le_50ms", float(sw.max) <= 50.0, sw)
	if plan_check:
		var pc: Array = scene.get("plan_checks")
		var bad: Array = []
		for v: Variant in pc:
			var row: Dictionary = v
			if not bool(row.fit_planned) or not bool(row.lamp_planned) or not bool((row.fit_check as Dictionary).get("equal", false)) \
					or not bool((row.lamp_check as Dictionary).get("equal", false)):
				bad.append(row)
		_check("plan_equals_swap_frame", not pc.is_empty() and bad.is_empty(), {"swaps": pc.size(), "not_equal": bad})
	var failed: int = 0
	for c: Variant in checks:
		if not bool((c as Dictionary).ok):
			failed += 1
	var mem: Dictionary = {}
	if not frames.is_empty():
		var f0: Dictionary = frames[0]
		var f1: Dictionary = frames[frames.size() - 1]
		mem = {"static_mb_first": f0.static_mem_mb, "static_mb_last": f1.static_mem_mb, "video_mb_first": f0.video_mem_mb, "video_mb_last": f1.video_mem_mb,
			"nodes_first": f0.nodes, "nodes_last": f1.nodes, "objects_first": f0.objects, "objects_last": f1.objects}
	var report: Dictionary = {"schema": "lshu.day_run.v1", "memory": mem, "scale": scale, "date": date_s, "start": start_s, "start_unix": start_unix, "hours": hours,
		"every_min": every_min, "frames": frames, "switches": switches, "postcards": postcards, "snaps": snaps, "event_counts": counts,
		"arrivals": arrivals, "departures": departures, "road_frames": road_frames, "night_frames": night_frames, "lamp_frames": lamp_frames,
		"night_frames_showing_him": night_shown, "night_near_light_frames": night_near_light,
		"frames_in_sync": in_sync, "postcard_files": files, "records_with_file": rendered_records, "snap_records": snap_records,
		"frame_ms": {"all_but_captures": everything, "steady": steady, "switch_and_staging": sw, "postcard_render": _stats(render_ms),
			"definition": "wall-clock interval between consecutive SceneTree.process_frame signals (main thread, includes render submission), 1920x1080 MSAA 4x SubViewport, director uncapped (--lshu-fps-cap=off); switch window = a switch or a tile staging in progress plus 10 frames; the 48 frame-capture frames are excluded"},
		"switch_windows": windows,
		"director_stats": st, "checks": checks, "failed": failed, "save_dir": save_dir,
		"screen_usable": str(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(DisplayServer.MAIN_WINDOW_ID)))}
	var f: FileAccess = FileAccess.open(out_dir.path_join("day_run_report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, " "))
	f.close()
	var fw: FileAccess = FileAccess.open(out_dir.path_join("switch_frames.json"), FileAccess.WRITE)
	fw.store_string(JSON.stringify({"rows_schema": "[frame, interval_ms (covers the work of the frame before), flags (1 switch window, 2 staging, 4 capture, 8 postcard), work [[label, ms]], pipelines compiled while drawn [canvas, mesh, surface, draw, specialization]]",
		"rows": work_rows}))
	fw.close()
	var fe: FileAccess = FileAccess.open(out_dir.path_join("events.jsonl"), FileAccess.WRITE)
	for e3: Variant in events:
		fe.store_line(JSON.stringify(e3))
	fe.close()
	for c2: Variant in checks:
		var cd: Dictionary = c2
		print("%s %s %s" % ["PASS" if bool(cd.ok) else "FAIL", cd.name, JSON.stringify(cd.value).left(300)])
	print("LSHU_DAY_RUN frames=%d events=%d arrivals=%d departures=%d road_frames=%d lamp_night_frames=%d night_shown=%d postcards=%d snaps=%d p95_ms=%.2f switch_max_ms=%.2f failed=%d" % [
		frames.size(), events.size(), arrivals, departures, road_frames, lamp_frames, night_shown, files.size(), snap_records, float(everything.p95), float(sw.max), failed])
	scene.queue_free()
	for _i: int in 3:
		await process_frame
	quit(0 if failed == 0 else 1)

## The switch / staging windows of the run (consecutive frames flagged F_SWITCH or F_STAGING, capture frames left out as
## in the switch_max check): each window's heaviest frame with the work in it, the commit frame, the staging frames.
func _switch_windows() -> Array:
	var out: Array = []
	var cur: Array = []
	var last_f: int = -10
	for row: Variant in work_rows:
		var r: Array = row
		var fl: int = int(r[2])
		if not (fl & (F_SWITCH | F_STAGING)):
			continue
		if int(r[0]) != last_f + 1 and not cur.is_empty():
			out.append(_window(cur))
			cur = []
		cur.append(r)
		last_f = int(r[0])
	if not cur.is_empty():
		out.append(_window(cur))
	var worst: Dictionary = {}
	for wi: int in out.size():
		var wd: Dictionary = out[wi]
		wd["i"] = wi
		print("LSHU_DAY_SWITCH_WINDOW ", JSON.stringify({"i": wi, "kind": wd.kind, "frames": wd.frames, "max_ms": wd.max_ms, "max_frame_work": wd.max_frame_work,
			"max_frame_pipes": wd.max_frame_pipes, "commit_frame_ms": wd.commit_frame_ms, "commit_work": wd.commit_work, "commit_pipes": wd.commit_pipes,
			"stage_frames": wd.stage_frames, "plan_frames": wd.plan_frames, "stage_frame_work_max_ms": wd.stage_frame_work_max_ms,
			"stage_work_sum_ms": wd.stage_work_sum_ms, "stage_frame_interval_max_ms": wd.stage_frame_interval_max_ms}))
		if worst.is_empty() or float(wd.max_ms) > float(worst.max_ms):
			worst = wd
	var maxes: Array[float] = []
	for w2: Variant in out:
		maxes.append(float((w2 as Dictionary).max_ms))
	maxes.sort()
	print("LSHU_DAY_SWITCH_WORST ", JSON.stringify({"windows": out.size(), "max_ms": worst.get("max_ms", 0.0), "window": worst.get("i", -1),
		"max_frame_work": worst.get("max_frame_work", []), "max_frame_pipes": worst.get("max_frame_pipes", []),
		"window_max_ms_sorted": maxes}))
	return out

func _window(rows: Array) -> Dictionary:
	var best: Array = []
	var commit: Array = []
	var stage_frames: int = 0
	var stage_work_max: float = 0.0
	var stage_work_sum: float = 0.0
	var stage_iv_max: float = 0.0
	var plan_frames: int = 0
	var sorted_rows: Array = []
	for row: Variant in rows:
		var r: Array = row
		if int(r[2]) & F_CAPTURE:
			continue
		sorted_rows.append(r)
		if best.is_empty() or float(r[1]) > float(best[1]):
			best = r
		var labels: Dictionary = {}
		var total: float = 0.0
		for wv: Variant in r[3] as Array:
			var w: Array = wv
			labels[str(w[0])] = true
			total += float(w[1])
		var is_commit: bool = false
		var is_stage: bool = labels.has("build") or labels.has("rig_for")
		for k: Variant in labels.keys():
			if str(k).begins_with("commit:"):
				is_commit = true
			if str(k).begins_with("plan:"):
				is_stage = true
				plan_frames += 1
		if is_commit:
			commit = r
		elif is_stage:
			stage_frames += 1
			stage_work_max = maxf(stage_work_max, total)
			stage_work_sum += total
			stage_iv_max = maxf(stage_iv_max, float(r[1]))
	sorted_rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[1]) > float(b[1]))
	var top: Array = []
	for i: int in mini(3, sorted_rows.size()):
		var tr: Array = sorted_rows[i]
		top.append([tr[0], tr[1], tr[3], tr[4]])
	var d: Dictionary = {"i": -1, "kind": "switch" if not commit.is_empty() else ("stage" if stage_frames > 0 else "other"),
		"first_frame": int((rows[0] as Array)[0]), "frames": rows.size(), "max_ms": float(best[1]) if not best.is_empty() else 0.0,
		"max_frame": int(best[0]) if not best.is_empty() else -1, "max_frame_work": best[3] if not best.is_empty() else [],
		"max_frame_pipes": best[4] if not best.is_empty() else [], "commit_frame_ms": float(commit[1]) if not commit.is_empty() else -1.0,
		"commit_work": commit[3] if not commit.is_empty() else [], "commit_pipes": commit[4] if not commit.is_empty() else [],
		"stage_frames": stage_frames, "plan_frames": plan_frames, "stage_frame_work_max_ms": snappedf(stage_work_max, 0.001),
		"stage_work_sum_ms": snappedf(stage_work_sum, 0.001), "stage_frame_interval_max_ms": stage_iv_max, "top3": top}
	return d

func _clear_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for sub: String in d.get_directories():
		_clear_dir(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))
	for fname: String in d.get_files():
		DirAccess.remove_absolute(path.path_join(fname))
