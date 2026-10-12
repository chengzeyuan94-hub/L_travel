extends SceneTree
## Act 4 「L叔在哪儿」 postcard camera harness (windowed: postcards need a real renderer).
##   /Applications/Godot.app/Contents/MacOS/Godot --path <project> --script res://tools/traveler/lshu/tests/postcard_cam_harness.gd -- --park=21 --motion-freeze
## Runs the real act-4 stage (scenes/traveler/lshu_main.tscn, window parked at the given slot) and, with
## scripts/traveler/lshu/lshu_postcard_camera.gd:
##   1. 12 postcards on 12 different pool tiles (every other tile of pool.json, read at run time; no ids in this file)
##      under the 4 lights (3 each), shots far / mid / back in the loop's 40 / 40 / 20 proportion, plus 2 snaps;
##      each one is checked (file, size, not blank, rule geometry, L叔 visible and in frame, far 3-5% of the frame height)
##      and the main view is compared pixel by pixel with the frame before (the postcard must not change it);
##   2. the timeout path: viewport + plan made first (prepare_viewport, plan_shot), then RenderingServer.render_loop_enabled
##      = false (nothing draws, as when macOS occludes the window) and render_plan -> 2 s timeout, id in pending_renders,
##      stage restored, no file; then retry_pending after drawing resumes. Also reported: the same with the viewport made
##      inside the render (Godot draws a frame when it is created, so it renders anyway);
##   3. the same with the window really minimized: timeout, then rendered by retry_pending once the window is back;
##   4. the save hand-off: LshuSave.complete_render / pending_renders on a save dictionary.
## Writes docs/reports/traveler-lshu-integrate-20260924/postcard_cam/ (postcards/<id>.jpg, per-postcard JSON) and
## postcard_cam_report.json. The contact sheet is made by postcard_cam_sheet.py.
## Last line: LSHU_POSTCARD_CAM_HARNESS errors=N warnings=W checks=C failed=F renders=R timeouts=T; exit 0 only when all 0.

const STAGE_SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const PC_CAM: GDScript = preload("res://scripts/traveler/lshu/lshu_postcard_camera.gd")
const LSHU_SAVE: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const LSHU_HASH: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_hash.gd")
const POOL_PATH: String = "res://data/traveler/lshu/pool.json"
const OUT_DIR: String = "res://docs/reports/traveler-lshu-integrate-20260924"
const LIGHTS: Array[String] = ["morning", "day", "sunset", "night"]
const SHOTS: Array[String] = ["far", "mid", "back", "far", "mid", "far", "mid", "back", "far", "mid", "far", "mid"]
const SNAP_AT: Array[int] = [4, 9]


class HarnessLogger extends Logger:
	var mutex: Mutex = Mutex.new()
	var errors: int = 0
	var warnings: int = 0
	var samples: Array = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mutex.lock()
		if error_type == ERROR_TYPE_WARNING:
			warnings += 1
		else:
			errors += 1
		if samples.size() < 30:
			samples.append("%s %s:%d %s %s" % ["W" if error_type == ERROR_TYPE_WARNING else "E", file, line, code, rationale if rationale != "" else function])
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


var logger: HarnessLogger = HarnessLogger.new()
var stage: Node3D
var pc: Node
var checks: Array = []
var failed: int = 0
var entries: Array = []
var save: Dictionary = {"postcards": [], "pending_renders": []}
var save_dir: String = ""
var out_abs: String = ""


func _initialize() -> void:
	OS.add_logger(logger)
	_run.call_deferred()


func _check(name_value: String, ok: bool, detail: Variant = "") -> void:
	checks.append({"name": name_value, "ok": ok, "detail": detail})
	if not ok:
		failed += 1
		print("FAIL ", name_value, " ", detail)


func _frames(n: int) -> void:
	for _i: int in n:
		await process_frame


func _post_draws(n: int) -> void:
	for _i: int in n:
		await RenderingServer.frame_post_draw


func _pool_tiles() -> Array[String]:
	var ids: Array[String] = []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(POOL_PATH))
	if not parsed is Dictionary:
		return ids
	var blocked: Array = (parsed as Dictionary).get("blocklist", [])
	for t: Variant in (parsed as Dictionary).get("tiles", []):
		var id: String = str((t as Dictionary).get("id", ""))
		if id != "" and not blocked.has(id):
			ids.append(id)
	return ids


static func _diff_pixels(a: Image, b: Image) -> Dictionary:
	if a == null or b == null or a.get_size() != b.get_size():
		return {"comparable": false}
	var pa: PackedByteArray = a.get_data()
	var pb: PackedByteArray = b.get_data()
	var differ: int = 0
	var max_d: int = 0
	var bpp: int = 4 if a.get_format() == Image.FORMAT_RGBA8 else 3
	var i: int = 0
	while i < pa.size():
		var d: int = 0
		for c: int in 3:
			d = maxi(d, absi(int(pa[i + c]) - int(pb[i + c])))
		if d > 0:
			differ += 1
			max_d = maxi(max_d, d)
		i += bpp
	return {"comparable": true, "pixels": a.get_width() * a.get_height(), "differ": differ, "max": max_d}


static func _luma_std(img: Image) -> float:
	var small: Image = img.duplicate() as Image
	small.resize(150, 100, Image.INTERPOLATE_BILINEAR)
	var n: int = 0
	var s: float = 0.0
	var s2: float = 0.0
	for y: int in small.get_height():
		for x: int in small.get_width():
			var c: Color = small.get_pixel(x, y)
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			s += l
			s2 += l * l
			n += 1
	var m: float = s / float(n)
	return sqrt(maxf(0.0, s2 / float(n) - m * m))


func _main_image() -> Image:
	return stage.get_viewport().get_texture().get_image()


func _stage_state() -> Dictionary:
	var sun: DirectionalLight3D = stage.get("sun") as DirectionalLight3D
	var cam: Camera3D = stage.get("camera") as Camera3D
	var world: Node3D = stage.get("world") as Node3D
	var leftovers: int = 0
	for n: Node in world.get_children():
		if str(n.name).begins_with("LshuPostcardSun"):
			leftovers += 1
	for n2: Node in pc.get_children():
		if str(n2.name).begins_with("LshuPostcardViewport"):
			leftovers += 1
	return {"sun_layers": sun.layers, "camera_cull_mask": cam.cull_mask, "leftover_nodes": leftovers}


func _geometry_checks(tag: String, rep: Dictionary, rule: String) -> void:
	var frac: float = float(rep.get("his_frame_fraction", 0.0))
	_check(tag + "_him_visible", float(rep.get("visible_fraction", 0.0)) >= 0.6 and (rep.get("blocked_by", []) as Array).size() <= 2, {"visible_fraction": rep.get("visible_fraction"), "blocked_by": rep.get("blocked_by")})
	_check(tag + "_him_in_frame", bool(rep.get("his_in_frame", false)), rep.get("his_rect_px"))
	if rule == "far":
		_check(tag + "_far_fraction_3_5pct", frac >= 0.03 - 0.0005 and frac <= 0.05 + 0.0005, frac)
	var cam: Dictionary = rep.get("camera", {})
	var det: Dictionary = cam.get("detail", {})
	if rule == "mid":
		_check(tag + "_mid_back_3_5m_up_1_5m", float(det.get("back_m", 0.0)) >= 3.0 and float(det.get("back_m", 0.0)) <= 5.0 and absf(float(det.get("up_m", 0.0)) - 1.5) < 0.001, det)
	if rule == "back":
		_check(tag + "_back_behind_him", absf(float(det.get("turn_from_straight_behind_deg", 180.0))) <= 90.0, det)


func _run() -> void:
	out_abs = ProjectSettings.globalize_path(OUT_DIR)
	save_dir = out_abs.path_join("postcard_cam")
	DirAccess.make_dir_recursive_absolute(save_dir.path_join("postcards"))
	# old images of a previous run would pass the "file exists" checks: start clean
	var d: DirAccess = DirAccess.open(save_dir.path_join("postcards"))
	if d != null:
		for f: String in d.get_files():
			d.remove(f)
	var tiles: Array[String] = _pool_tiles()
	_check("pool_has_24_tiles", tiles.size() >= 24, tiles.size())
	stage = (load(STAGE_SCENE) as PackedScene).instantiate() as Node3D
	root.add_child(stage)
	await stage.prewarm_done
	pc = PC_CAM.new()
	pc.name = "PostcardCamera"
	stage.add_child(pc)
	_check("setup", bool(pc.call("setup", stage)))
	var base_state: Dictionary = _stage_state()
	# ---------------------------------------------------------------- 12 postcards
	var chosen: Array[String] = []
	for i: int in 12:
		chosen.append(tiles[mini(i * 2, tiles.size() - 1)])
	for i: int in 12:
		var tile_id: String = chosen[i]
		var light: String = LIGHTS[i % 4]
		var ok_load: bool = await stage.call("load_tile", tile_id, 0.0)
		stage.call("set_light", light)
		await _frames(12)
		await _post_draws(3)
		var main_before: Image = _main_image()
		await _post_draws(1)
		var main_next: Image = _main_image()
		var rec: Dictionary = {"id": "pc_harness_%02d" % i, "leg": i, "trip": 1, "tile": tile_id, "shot": SHOTS[i],
			"line_seed": LSHU_HASH.hash3(20260924, i, 7), "file": "", "read": false}
		(save.postcards as Array).append(rec)
		(save.pending_renders as Array).append(rec.id)
		var r: Dictionary = await pc.call("render_postcard", rec, save_dir, {"capture_main": true})
		var rep: Dictionary = r.get("report", {})
		var tag: String = "pc%02d" % i
		_check(tag + "_load", ok_load, tile_id)
		_check(tag + "_ok", bool(r.get("ok", false)), r.get("error", ""))
		var entry: Dictionary = {"index": i, "tile": tile_id, "light": light, "requested": SHOTS[i], "kind": "postcard", "result": {"ok": r.get("ok"), "id": r.get("id"), "path": r.get("path"), "rule": r.get("rule"), "fallback": r.get("fallback"), "timed_out": r.get("timed_out")}, "report": rep}
		if bool(r.get("ok", false)):
			var img: Image = Image.load_from_file(str(r.path))
			_check(tag + "_jpg_1500x1000", img != null and img.get_width() == 1500 and img.get_height() == 1000, [img.get_width() if img != null else 0, img.get_height() if img != null else 0])
			var std: float = _luma_std(img) if img != null else 0.0
			entry["luma_std"] = std
			_check(tag + "_not_blank", std > 0.02, std)
			_check(tag + "_complete_render", bool(LSHU_SAVE.complete_render(save, str(rec.id), str(r.path))) and not (save.pending_renders as Array).has(rec.id) and str(rec.get("file", "")) == str(r.path))
			_geometry_checks(tag, rep, str(r.get("rule", "")))
			var base_diff: Dictionary = _diff_pixels(main_before, main_next)
			var pc_diff: Dictionary = _diff_pixels(main_before, r.get("main_image", null) as Image)
			entry["main_view_diff"] = {"frame_to_frame": base_diff, "postcard_frame": pc_diff}
			_check(tag + "_main_view_unchanged", bool(pc_diff.get("comparable", false)) and (int(pc_diff.get("differ", 1)) == 0 or int(pc_diff.get("differ", 1)) <= int(base_diff.get("differ", 0))), entry.main_view_diff)
			var f: FileAccess = FileAccess.open(save_dir.path_join("postcards").path_join(str(rec.id) + ".json"), FileAccess.WRITE)
			f.store_string(JSON.stringify(rep, " "))
			f.close()
		await _frames(1)   # the postcard viewport and sun copy are queue_freed
		_check(tag + "_stage_restored", _stage_state() == base_state, _stage_state())
		entries.append(entry)
		print("LSHU_PC ", JSON.stringify({"i": i, "tile": tile_id, "light": light, "requested": SHOTS[i], "rule": r.get("rule"), "fallback": r.get("fallback"), "frac": rep.get("his_frame_fraction"), "vis": rep.get("visible_fraction"), "ms": (rep.get("timing_ms", {}) as Dictionary)}))
		if SNAP_AT.has(i):
			var sid: String = "snap_harness_%02d" % i
			var sr: Dictionary = await pc.call("snap", sid, save_dir, LSHU_HASH.hash3(20260924, i, 9))
			var srep: Dictionary = sr.get("report", {})
			_check("snap%02d_ok" % i, bool(sr.get("ok", false)) and FileAccess.file_exists(str(sr.get("path", ""))), sr.get("error", ""))
			if bool(sr.get("ok", false)):
				_geometry_checks("snap%02d" % i, srep, str(sr.get("rule", "")))
				var fs: FileAccess = FileAccess.open(save_dir.path_join("postcards").path_join(sid + ".json"), FileAccess.WRITE)
				fs.store_string(JSON.stringify(srep, " "))
				fs.close()
			entries.append({"index": i, "tile": tile_id, "light": light, "requested": "snap", "kind": "snap", "result": {"ok": sr.get("ok"), "id": sid, "path": sr.get("path"), "rule": sr.get("rule"), "fallback": sr.get("fallback")}, "report": srep})
	# determinism: the same record on the same stage state plans the same camera
	var last_rec: Dictionary = (save.postcards as Array)[11]
	var p1: Dictionary = pc.call("plan_shot", last_rec, str(last_rec.shot))
	var p2: Dictionary = pc.call("plan_shot", last_rec, str(last_rec.shot))
	_check("plan_deterministic", bool(p1.ok) and bool(p2.ok) and (p1.shot.pos as Vector3) == (p2.shot.pos as Vector3) and str(p1.rule) == str(p2.rule))
	# a plan made on one tile is refused after a tile switch
	var stale_plan: Dictionary = pc.call("plan_shot", last_rec, str(last_rec.shot))
	await stage.call("load_tile", chosen[0], 0.0)
	await _frames(4)
	var sr2: Dictionary = await pc.call("render_plan", stale_plan, "pc_harness_stale", save_dir)
	_check("stale_plan_refused", not bool(sr2.get("ok", true)) and str(sr2.get("error", "")) == "stale_plan" and not FileAccess.file_exists(PC_CAM.image_path(save_dir, "pc_harness_stale")), sr2.get("error", ""))
	# ---------------------------------------------------------------- timeout path: nothing draws
	# A main loop that draws nothing (render_loop_enabled = false, what macOS does to an occluded window): the render must
	# give up after 2 s, list the id as pending, leave no file and restore the stage; retry_pending after drawing resumes
	# must render it.
	var timeout_report: Dictionary = {}
	var t_rec: Dictionary = _extra_record("pc_harness_timeout", 100, "mid")
	# Godot draws a frame or two whenever a viewport, mesh or texture is created, even with the loop off. So the viewport
	# is made and the shot planned (his posed mesh is baked) first; the loop goes off once those frames are drawn.
	pc.call("prepare_viewport")
	var t_plan: Dictionary = pc.call("plan_shot", t_rec, str(t_rec.shot))
	await _frames(8)
	RenderingServer.render_loop_enabled = false
	var t0: int = Time.get_ticks_msec()
	var tr: Dictionary = await pc.call("render_plan", t_plan, str(t_rec.id), save_dir)
	var waited: int = Time.get_ticks_msec() - t0
	RenderingServer.render_loop_enabled = true
	if not bool(tr.get("ok", false)):
		PC_CAM.mark_pending(save, str(t_rec.id))
	var trep: Dictionary = tr.get("report", {})
	var frames_waited: int = int((trep.get("timing_ms", {}) as Dictionary).get("process_frames_waited", 0))
	timeout_report["render_loop_off"] = {"result_ok": tr.get("ok"), "timed_out": tr.get("timed_out"), "error": tr.get("error"), "waited_ms": waited, "process_frames_during_wait": frames_waited,
		"viewport_prepared_before": trep.get("viewport_prepared_before"), "pending_in_camera": (pc.get("pending_renders") as Array).duplicate(), "pending_in_save": (save.pending_renders as Array).duplicate(),
		"file_exists": FileAccess.file_exists(PC_CAM.image_path(save_dir, str(t_rec.id)))}
	_check("timeout_flagged", not bool(tr.get("ok", true)) and bool(tr.get("timed_out", false)), timeout_report.render_loop_off)
	_check("timeout_about_2s", waited >= 1950 and waited <= 3000, waited)
	_check("timeout_loop_kept_running", frames_waited >= 10, frames_waited)
	_check("timeout_pending_listed", (pc.get("pending_renders") as Array).has(t_rec.id) and (save.pending_renders as Array).has(t_rec.id))
	_check("timeout_no_file", not FileAccess.file_exists(PC_CAM.image_path(save_dir, str(t_rec.id))))
	await _frames(2)
	_check("timeout_stage_restored", _stage_state() == base_state, _stage_state())
	await _post_draws(3)
	var retry: Array = await pc.call("retry_pending", save, save_dir)
	timeout_report["retry"] = _retry_summary(retry)
	var retry_ok: bool = retry.size() == 1 and bool((retry[0] as Dictionary).get("ok", false))
	if retry_ok:
		LSHU_SAVE.complete_render(save, str(t_rec.id), str((retry[0] as Dictionary).path))
		_write_json(str(t_rec.id), (retry[0] as Dictionary).get("report", {}))
	_check("retry_after_timeout_ok", retry_ok and FileAccess.file_exists(PC_CAM.image_path(save_dir, str(t_rec.id))), timeout_report.retry)
	_check("retry_cleared_pending", not (pc.get("pending_renders") as Array).has(t_rec.id) and not (save.pending_renders as Array).has(t_rec.id))
	# the default path (viewport made inside the render) with the loop off: reported. Godot draws a couple of frames
	# when a viewport is created, so the postcard usually still gets its frame.
	var f_rec: Dictionary = _extra_record("pc_harness_loopoff_fresh", 101, "far")
	RenderingServer.render_loop_enabled = false
	var t2: int = Time.get_ticks_msec()
	var fr: Dictionary = await pc.call("render_postcard", f_rec, save_dir)
	var waited2: int = Time.get_ticks_msec() - t2
	RenderingServer.render_loop_enabled = true
	timeout_report["render_loop_off_fresh_viewport"] = {"result_ok": fr.get("ok"), "timed_out": fr.get("timed_out"), "waited_ms": waited2}
	await _settle(fr, f_rec)
	# the real OS path: the window minimized, viewport and plan made beforehand (reported: macOS may keep drawing)
	var m_rec: Dictionary = _extra_record("pc_harness_minimized", 102, "far")
	pc.call("prepare_viewport")
	var m_plan: Dictionary = pc.call("plan_shot", m_rec, str(m_rec.shot))
	await _frames(8)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	var tm: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - tm < 1500:
		await process_frame
	var mode_seen: int = DisplayServer.window_get_mode()
	var t1: int = Time.get_ticks_msec()
	var mr: Dictionary = await pc.call("render_plan", m_plan, str(m_rec.id), save_dir)
	var m_waited: int = Time.get_ticks_msec() - t1
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	var tw: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - tw < 1500:
		await process_frame
	stage.call("_park", int(stage.get("park_slot")))
	await _frames(10)
	timeout_report["minimized"] = {"window_mode_seen": mode_seen, "result_ok": mr.get("ok"), "timed_out": mr.get("timed_out"), "waited_ms": m_waited}
	if bool(mr.get("timed_out", false)):
		_check("minimized_timed_out_about_2s", m_waited >= 1950 and m_waited <= 3000, timeout_report.minimized)
	await _settle(mr, m_rec)
	timeout_report["minimized"]["final_ok"] = FileAccess.file_exists(PC_CAM.image_path(save_dir, str(m_rec.id)))
	_check("minimized_rendered_or_retried", bool(timeout_report.minimized.final_ok) and not (save.pending_renders as Array).has(m_rec.id), timeout_report.minimized)
	_check("final_stage_restored", _stage_state() == base_state, _stage_state())
	_check("final_nothing_pending", (pc.get("pending_renders") as Array).is_empty() and (save.pending_renders as Array).is_empty(), [pc.get("pending_renders"), save.pending_renders])
	# ---------------------------------------------------------------- report
	var counts: Dictionary = {}
	for e: Variant in entries:
		var rule: String = str(((e as Dictionary).result as Dictionary).get("rule", ""))
		counts[rule] = int(counts.get(rule, 0)) + 1
	var report: Dictionary = {"schema": "lshu.postcard_cam_harness.v1", "date": Time.get_datetime_string_from_system(), "park_slot": stage.get("park_slot"),
		"motion_frozen": stage.get("motion_frozen"), "save_dir": save_dir, "entries": entries, "rules_used": counts, "timeout": timeout_report,
		"camera_counters": {"renders": pc.get("renders"), "timeouts": pc.get("timeouts")}, "checks": checks, "failed": failed,
		"errors": logger.errors, "warnings": logger.warnings, "error_samples": logger.samples}
	var out: FileAccess = FileAccess.open(out_abs.path_join("postcard_cam_report.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(report, " "))
	out.close()
	var renders: int = int(pc.get("renders"))
	var timeouts: int = int(pc.get("timeouts"))
	stage.queue_free()
	await _frames(3)
	print("LSHU_POSTCARD_CAM_HARNESS errors=%d warnings=%d checks=%d failed=%d renders=%d timeouts=%d" % [logger.errors, logger.warnings, checks.size(), failed, renders, timeouts])
	OS.remove_logger(logger)
	quit(0 if failed == 0 and logger.errors == 0 and logger.warnings == 0 else 1)


func _extra_record(id: String, leg: int, shot: String) -> Dictionary:
	var rec: Dictionary = {"id": id, "leg": leg, "trip": 1, "tile": str(stage.get("tile_id")), "shot": shot, "line_seed": LSHU_HASH.hash3(20260924, leg, 7), "file": "", "read": false}
	(save.postcards as Array).append(rec)
	(save.pending_renders as Array).append(rec.id)
	return rec


static func _retry_summary(retry: Array) -> Dictionary:
	var out: Array = []
	for x: Variant in retry:
		var d: Dictionary = x
		out.append({"ok": d.get("ok"), "id": d.get("id"), "path": d.get("path"), "error": d.get("error")})
	return {"results": out}


## Hands a result to the save (complete_render + the per-postcard JSON); a timed-out one is retried once drawing is back.
func _settle(r: Dictionary, rec: Dictionary) -> void:
	var res: Dictionary = r
	if bool(res.get("timed_out", false)):
		PC_CAM.mark_pending(save, str(rec.id))
		await _post_draws(3)
		var again: Array = await pc.call("retry_pending", save, save_dir)
		for x: Variant in again:
			if str((x as Dictionary).get("id", "")) == str(rec.id):
				res = x
	if bool(res.get("ok", false)):
		LSHU_SAVE.complete_render(save, str(rec.id), str(res.path))
		_write_json(str(rec.id), res.get("report", {}))


func _write_json(id: String, rep: Dictionary) -> void:
	var f: FileAccess = FileAccess.open(save_dir.path_join("postcards").path_join(id + ".json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rep, " "))
	f.close()
