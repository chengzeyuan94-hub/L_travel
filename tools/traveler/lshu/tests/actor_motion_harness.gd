extends SceneTree
## 第四幕「L叔在哪儿」· actor motion harness (scripts/traveler/lshu/lshu_actor_motion.gd).
## Hosts scenes/traveler/lshu_main.tscn in a 1920x1080 MSAA 4x SubViewport (as the capture harness does), and for each
## tile: binds the motion hidden, runs arrive -> click (bow / nod) -> leave on one explicit clock, and
##   1. measures at 60 Hz (no rendering needed): the lowest point of each sole (every foot vertex, CPU-skinned) against
##      what is drawn under it (downward ray per vertex on the tile's ground parts; planted gap = the lower foot), and
##      per-step jumps of the figure's key points / opacity / facing (pops);
##   2. renders every frame at --fps and records the mean pixel change inside the figure's crop (a rendered pop shows
##      as a spike), and saves --frames frames per sequence for the sheet (actor_motion_sheet.py);
##   3. extra (not rendered): wander feasibility, night doze, tent in / out, double-click camera focus.
## The scene clock (anim_t) and the motion clock are the same explicit t; the scene's own delta clock is frozen.
##
##   Godot --path . --script res://tools/traveler/lshu/tests/actor_motion_harness.gd -- --park=23 --light=day
##         --tiles=D05,D01,D11,D02 --out=<dir> [--fps=30] [--frames=8] [--scale=1.0]
## Output: <dir>/actor_motion_report.json, <dir>/frames/<tile>_<seq>_<k>.png. Last line:
##   LSHU_ACTOR_MOTION tiles=N errors=E checks=C failed=F max_sole_gap_m=G

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const MOTION_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_actor_motion.gd")
const METRIC_HZ: float = 60.0

var scene: Node3D
var viewport: SubViewport
var motion: Node
var out_dir: String = ""
var tiles: Array[String] = []
var extra_tiles: Array[String] = []
var fps: float = 30.0
var sheet_frames: int = 8
var clock_scale: float = 1.0
var checks: Array = []
var errors: Array[String] = []
## Pop threshold per 1/60 s step for any key point: 1.5 x the fastest the clip itself moves a toe at walking speed
## on flat ground (the swing foot), and never below 5 cm.
var pop_step_m: float = 0.05
var ref_swing_step_m: float = 0.0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--tiles="):
			for id: String in arg.trim_prefix("--tiles=").split(",", false):
				tiles.append(id)
		elif arg.begins_with("--extra-tiles="):
			for id2: String in arg.trim_prefix("--extra-tiles=").split(",", false):
				extra_tiles.append(id2)
		elif arg.begins_with("--fps="):
			fps = float(arg.trim_prefix("--fps="))
		elif arg.begins_with("--frames="):
			sheet_frames = int(arg.trim_prefix("--frames="))
		elif arg.begins_with("--scale="):
			clock_scale = float(arg.trim_prefix("--scale="))
	if out_dir.is_empty() or tiles.is_empty():
		push_error("actor_motion_harness: --out and --tiles are required")
		quit(2)
		return
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
	viewport.add_child(scene)
	var waited: int = 0
	while scene.get("tile") == null or bool(scene.get("loading")):
		await process_frame
		waited += 1
		if waited > 3000:
			push_error("actor_motion_harness: first tile never became ready")
			quit(1)
			return
	scene.set("motion_frozen", true)
	motion = MOTION_SCRIPT.new()
	scene.add_child(motion)
	motion.call("setup", scene.get("character"), scene.get("look"))
	var t_prep: int = Time.get_ticks_usec()
	await motion.call("prepare")
	var prepare_ms: float = float(Time.get_ticks_usec() - t_prep) / 1000.0
	var report: Dictionary = {"schema": "lshu.actor_motion_harness.v1", "tiles": {}, "fps": fps, "metric_hz": METRIC_HZ, "clock_scale": clock_scale,
		"screen_usable": str(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(DisplayServer.MAIN_WINDOW_ID)))}
	var first_plan: Dictionary = await motion.call("bind_tile", scene.get("tile"), scene.get("camera"), 0.0, true)
	ref_swing_step_m = _reference_swing_step()
	pop_step_m = maxf(0.05, 1.5 * ref_swing_step_m)
	report["pop_step_m"] = pop_step_m
	report["reference_swing_step_m"] = ref_swing_step_m
	report["first_bind_ms"] = first_plan.get("bind_ms", 0.0)
	report["prepare_ms"] = prepare_ms
	for id: String in tiles:
		if str(scene.get("tile_id")) != id:
			var ok: bool = await scene.call("load_tile", id, 0.0)
			if not ok:
				errors.append("load_tile failed: " + id)
				continue
		for _i: int in 3:
			await process_frame
		(report.tiles as Dictionary)[id] = await _run_tile(id)
	# extra tiles: no rendering, only the night / wander / focus checks (a tile with a tent)
	var extra_rep: Dictionary = {}
	for id3: String in extra_tiles:
		var ok3: bool = await scene.call("load_tile", id3, 0.0)
		if not ok3:
			errors.append("load_tile failed: " + id3)
			continue
		for _j: int in 3:
			await process_frame
		var plan3: Dictionary = await motion.call("bind_tile", scene.get("tile"), scene.get("camera"), 0.0, false)
		var rec3: Dictionary = {"plan": plan3, "pose": str((scene.get("character") as Node3D).get("active").get("pose"))}
		rec3["extra"] = await _extras(id3, 1.0)
		extra_rep[id3] = rec3
	report["extra_tiles"] = extra_rep
	var fails: int = 0
	for c: Variant in checks:
		if not bool((c as Dictionary).ok):
			fails += 1
	report["tile_order"] = tiles
	report["checks"] = checks
	report["errors"] = errors
	var worst_gap: float = 0.0
	for id2: String in (report.tiles as Dictionary).keys():
		worst_gap = maxf(worst_gap, float(((report.tiles as Dictionary)[id2] as Dictionary).get("walk_max_planted_gap_m", 0.0)))
	report["max_planted_sole_gap_m"] = worst_gap
	var f: FileAccess = FileAccess.open(out_dir.path_join("actor_motion_report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, " "))
	f.close()
	print("LSHU_ACTOR_MOTION tiles=%d errors=%d checks=%d failed=%d max_sole_gap_m=%.4f" % [(report.tiles as Dictionary).size(), errors.size(), checks.size(), fails, worst_gap])
	_consume_load_tokens()
	quit(0 if fails == 0 and errors.is_empty() else 1)

## Threaded load requests nobody collected (a scene module that requests paths already in the assembler cache) would
## outlive the scene as leaked load tokens at exit; collect them before quitting.
func _consume_load_tokens() -> void:
	var assembler: GDScript = load("res://scripts/traveler/lshu/lshu_tile_assembler.gd")
	var paths: Array = (assembler.get("_asset_cache") as Dictionary).keys() if assembler.get("_asset_cache") is Dictionary else []
	var lamp_path: String = "res://scripts/traveler/lshu/lshu_night_lamp.gd"
	if ResourceLoader.exists(lamp_path):
		var lamp: GDScript = load(lamp_path)
		if lamp.has_method("pool_assets"):
			for a: Variant in lamp.call("pool_assets"):
				paths.append("res://assets/traveler/lshu/props/%s.glb" % str(a))
	for p: Variant in paths:
		if ResourceLoader.load_threaded_get_status(str(p)) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			ResourceLoader.load_threaded_get(str(p))

func _reference_swing_step() -> float:
	var sk: Skeleton3D = motion.get("w_skel")
	var v: float = float(motion.get("stance_speed"))
	var sc: float = sk.global_basis.get_scale().x
	var toes: Array[int] = []
	for side: String in ["LeftToeBase", "RightToeBase"]:
		for i: int in sk.get_bone_count():
			if str(sk.get_bone_name(i)).ends_with(side):
				toes.append(i)
	var prev: Array = [null, null]
	var best: float = 0.0
	for k: int in 120:
		var t: float = float(k) / METRIC_HZ
		motion.call("_pose_walker", "walk", t, "walk", 0.0, 0.0)
		sk.force_update_all_bone_transforms()
		for f: int in toes.size():
			var p: Vector3 = sk.get_bone_global_pose(toes[f]).origin * sc + Vector3(0.0, 0.0, v * t)
			if prev[f] != null:
				best = maxf(best, p.distance_to(prev[f] as Vector3))
			prev[f] = p
	return best

func _check(name: String, ok: bool, value: Variant) -> void:
	checks.append({"name": name, "ok": ok, "value": value})

# ------------------------------------------------------------------ per tile
func _run_tile(id: String) -> Dictionary:
	var camera: Camera3D = scene.get("camera")
	var t: float = 0.0
	var plan: Dictionary = await motion.call("bind_tile", scene.get("tile"), camera, t, true)
	var res: Dictionary = {"plan": plan, "pose": str((scene.get("character") as Node3D).get("active").get("pose"))}
	print("LSHU_ACTOR_PLAN ", id, " ", JSON.stringify(plan))
	# timeline: arrive at 0.5, click 1.5 s after settling, leave 1.5 s after the greeting ends
	var t_arrive: float = 0.5
	var t_settled: float = float(motion.call("arrive", t_arrive))
	_check(id + ":arrival_route", t_settled < INF and (plan.get("routes", {}) as Dictionary).has("arrival"), plan.get("routes", {}))
	var t_click: float = t_settled + 1.5
	var seqs: Array = []
	seqs.append({"name": "arrive", "t0": 0.0, "t1": t_settled + 1.0})
	# the click and leave are scheduled when their time comes (as the director does)
	var metrics_arrive: Dictionary = await _metrics(id, "arrive", 0.0, t_settled + 1.0)
	var ok_click: bool = bool(motion.call("click", t_click))
	_check(id + ":click_accepted", ok_click, t_click)
	var tl: Array = motion.call("timeline")
	var t_greet_end: float = float((tl[tl.size() - 1] as Dictionary).t0)
	var metrics_bow: Dictionary = await _metrics(id, "bow", t_click - 0.3, t_greet_end + 0.8)
	var t_leave: float = t_greet_end + 1.2
	var t_gone: float = float(motion.call("leave", t_leave))
	_check(id + ":leave_route", t_gone < INF, t_gone - t_leave)
	var metrics_leave: Dictionary = await _metrics(id, "leave", t_leave - 0.3, t_gone + 0.4)
	res["times"] = {"arrive": t_arrive, "settled": t_settled, "click": t_click, "greet_end": t_greet_end, "leave": t_leave, "gone": t_gone}
	res["timeline"] = motion.call("timeline")
	res["metrics"] = {"arrive": metrics_arrive, "bow": metrics_bow, "leave": metrics_leave}
	var gap: float = 0.0
	var pen: float = 0.0
	var over: int = 0
	var frames: int = 0
	for m: Dictionary in [metrics_arrive, metrics_leave]:
		gap = maxf(gap, float(m.walk_max_planted_gap_m))
		pen = minf(pen, float(m.walk_min_foot_gap_m))
		over += int(m.walk_frames_gap_over_3cm)
		frames += int(m.walk_frames)
	res["walk_max_planted_gap_m"] = gap
	res["walk_min_foot_gap_m"] = pen
	res["walk_frames"] = frames
	res["walk_frames_gap_over_3cm"] = over
	_check(id + ":walk_planted_sole_gap<=0.03m", gap <= 0.03, gap)
	_check(id + ":walk_no_sinking>-0.03m", pen >= -0.03, pen)
	for nm: String in ["arrive", "bow", "leave"]:
		var m2: Dictionary = (res.metrics as Dictionary)[nm]
		_check(id + ":" + nm + ":no_pops", int(m2.pops) == 0, m2.pop_list)
	# rendered frames (all at --fps; the sheet keeps --frames per sequence)
	var render: Dictionary = {}
	for rs: Dictionary in [{"name": "arrive", "t0": 0.0, "t1": t_settled + 0.8, "m": metrics_arrive}, {"name": "bow", "t0": t_click - 0.2, "t1": t_greet_end + 0.5, "m": metrics_bow},
			{"name": "leave", "t0": t_leave - 0.2, "t1": t_gone + 0.2, "m": metrics_leave}]:
		render[rs.name] = await _render(id, str(rs.name), float(rs.t0), float(rs.t1), rs.m as Dictionary)
		_check(id + ":" + str(rs.name) + ":render_spikes", float((render[rs.name] as Dictionary).get("spike_ratio", 0.0)) < 4.0, render[rs.name].get("spike_ratio"))
	res["render"] = render
	if id == tiles[0]:
		res["focus_frames"] = await _render_focus(id, t_gone + 0.5)
	res["extra"] = await _extras(id, t_gone + 14.0)
	return res

# ------------------------------------------------------------------ 60 Hz metrics
## One explicit clock for the scene (anim_t, frozen delta clock) and the motion. The motion ticks first and the scene
## ticks the character after it, so the result also proves the character.motion_hook ordering.
func _set_clock(t: float) -> void:
	scene.set("anim_t", t)
	motion.call("tick", t)
	scene.call("_apply_motion", t, 0.0)

func _metrics(id: String, seq: String, t0: float, t1: float) -> Dictionary:
	var dt: float = 1.0 / METRIC_HZ
	var n: int = int(ceil((t1 - t0) / dt)) + 1
	var prev: Dictionary = {}
	var pops: Array = []
	var max_step_m: float = 0.0
	var max_alpha_step: float = 0.0
	var max_yaw_step_deg: float = 0.0
	var walk_gap: float = 0.0
	var walk_min: float = INF
	var walk_frames: int = 0
	var planted_abs: Array[float] = []
	var rects: Array = []
	var phases: Dictionary = {}
	var phase_at: Dictionary = {}
	var tick_us: Array[float] = []
	var gap_series: Array = []
	for i: int in n:
		var t: float = t0 + float(i) * dt
		var us0: int = Time.get_ticks_usec()
		motion.call("tick", t)
		tick_us.append(float(Time.get_ticks_usec() - us0))
		_set_clock(t)
		var fr: Dictionary = motion.get("last_frame")
		phases[str(fr.get("phase", ""))] = true
		phase_at[snappedf(t, 0.0001)] = "%s a=%.2f s=%.3f" % [str(fr.get("phase", "")), float(fr.get("w_alpha", 0.0)), float(fr.get("s", -1.0))]
		var cur: Dictionary = _key_points(fr)
		var r: Rect2 = motion.call("figure_rect")
		if r.size.x > 0.0:
			rects.append([t, r.position.x, r.position.y, r.size.x, r.size.y])
		# pops: any key point of a visible rig moving more than 0.05 m in 1/60 s, opacity or facing jumps
		for k: String in cur.keys():
			if not prev.has(k):
				continue
			var a: Dictionary = cur[k]
			var b: Dictionary = prev[k]
			if float(a.alpha) < 0.02 and float(b.alpha) < 0.02:
				continue
			var pa: Array = a.points
			var pb: Array = b.points
			for pi: int in mini(pa.size(), pb.size()):
				var d: float = (pa[pi] as Vector3).distance_to(pb[pi] as Vector3)
				if float(a.alpha) > 0.02 and float(b.alpha) > 0.02:
					max_step_m = maxf(max_step_m, d)
					if d > pop_step_m:
						pops.append({"t": t, "rig": k, "point": pi, "jump_m": d})
			var da: float = absf(float(a.alpha) - float(b.alpha))
			max_alpha_step = maxf(max_alpha_step, da)
			if da > 0.12:
				pops.append({"t": t, "rig": k, "alpha_jump": da})
			var dyaw: float = rad_to_deg(absf(wrapf(float(a.yaw) - float(b.yaw), -PI, PI)))
			if float(a.alpha) > 0.02:
				max_yaw_step_deg = maxf(max_yaw_step_deg, dyaw)
				if dyaw > 12.0:
					pops.append({"t": t, "rig": k, "yaw_jump_deg": dyaw})
		prev = cur
		# feet while walking (full stride, not the blended ends)
		if str(fr.get("phase", "")) == "walk" and float(fr.get("w_ground", 0.0)) >= 0.999 and float(fr.get("w_alpha", 0.0)) > 0.02:
			var feet: Array = motion.call("feet_state", true)
			if feet.size() == 2:
				var g0: float = (feet[0][0] as Vector3).y - float(feet[0][1])
				var g1: float = (feet[1][0] as Vector3).y - float(feet[1][1])
				var gp: float = minf(g0, g1)
				walk_gap = maxf(walk_gap, absf(gp))
				planted_abs.append(absf(gp))
				walk_min = minf(walk_min, minf(g0, g1))
				walk_frames += 1
				if i % 6 == 0:
					gap_series.append([snappedf(t, 0.001), snappedf(g0, 0.0001), snappedf(g1, 0.0001)])
	pops.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("jump_m", a.get("alpha_jump", a.get("yaw_jump_deg", 0.0)))) > float(b.get("jump_m", b.get("alpha_jump", b.get("yaw_jump_deg", 0.0)))))
	for pp: Dictionary in pops:
		pp["phase"] = str(phase_at.get(snappedf(float(pp.t), 0.0001), ""))
	tick_us.sort()
	planted_abs.sort()
	var over: int = 0
	for v: float in planted_abs:
		if v > 0.03:
			over += 1
	return {"t0": t0, "t1": t1, "steps": n, "phases": phases.keys(), "pops": pops.size(), "pop_list": pops.slice(0, 12),
		"tick_ms_p50": tick_us[tick_us.size() / 2] / 1000.0, "tick_ms_max": tick_us[tick_us.size() - 1] / 1000.0,
		"max_point_step_m": max_step_m, "max_alpha_step": max_alpha_step, "max_yaw_step_deg": max_yaw_step_deg,
		"walk_frames": walk_frames, "walk_max_planted_gap_m": walk_gap, "walk_min_foot_gap_m": walk_min if walk_min < INF else 0.0,
		"walk_planted_gap_p95_m": planted_abs[int(float(planted_abs.size() - 1) * 0.95)] if not planted_abs.is_empty() else 0.0,
		"walk_frames_gap_over_3cm": over, "gap_series_t_left_right": gap_series, "rects": rects}

## Key points per visible rig: head, hips, both toes (world), with the rig's opacity and facing.
func _key_points(fr: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var walker: Node3D = motion.get("walker")
	var kit: Node3D = motion.get("kit_rig")
	if bool(fr.get("w_show", false)):
		out["walker"] = _rig_points(walker, float(fr.get("w_alpha", 1.0)))
	if kit != walker or not bool(fr.get("w_show", false)):
		out["kit"] = _rig_points(kit, float(fr.get("k_alpha", 1.0)))
	return out

func _rig_points(rig: Node3D, alpha: float) -> Dictionary:
	var ch: Node3D = rig.get("character")
	var sk: Skeleton3D = null
	for n: Node in rig.find_children("*", "Skeleton3D", true, false):
		if (n as Skeleton3D).is_visible_in_tree():
			sk = n as Skeleton3D
	var pts: Array = [ch.global_position]
	if sk != null:
		sk.force_update_all_bone_transforms()
		for suffix: String in ["Head", "Hips", "LeftToeBase", "RightToeBase", "LeftHand", "RightHand", "HeadTop_End"]:
			var b: int = -1
			for i: int in sk.get_bone_count():
				if str(sk.get_bone_name(i)).ends_with(suffix):
					b = i
					break
			if b >= 0:
				pts.append(sk.global_transform * sk.get_bone_global_pose(b).origin)
	return {"alpha": alpha, "yaw": ch.rotation.y, "points": pts}

# ------------------------------------------------------------------ rendering
func _crop(m: Dictionary) -> Rect2i:
	var rects: Array = m.get("rects", [])
	var lo: Vector2 = Vector2(INF, INF)
	var hi: Vector2 = -lo
	for r: Variant in rects:
		var a: Array = r
		lo = lo.min(Vector2(float(a[1]), float(a[2])))
		hi = hi.max(Vector2(float(a[1]) + float(a[3]), float(a[2]) + float(a[4])))
	if lo.x == INF:
		return Rect2i(0, 0, 1920, 1080)
	var c: Vector2 = (lo + hi) * 0.5
	var h: float = maxf((hi.y - lo.y) * 1.3, 240.0)
	var w: float = maxf((hi.x - lo.x) * 1.3, h * 1.5)
	h = maxf(h, w / 1.5)
	w = h * 1.5
	var x0: float = clampf(c.x - w * 0.5, 0.0, maxf(0.0, 1920.0 - w))
	var y0: float = clampf(c.y - h * 0.5, 0.0, maxf(0.0, 1080.0 - h))
	return Rect2i(int(x0), int(y0), int(minf(w, 1920.0)), int(minf(h, 1080.0)))

func _render(id: String, seq: String, t0: float, t1: float, m: Dictionary) -> Dictionary:
	var crop: Rect2i = _crop(m)
	var n: int = int(ceil((t1 - t0) * fps)) + 1
	var keep: Array[int] = []
	for k: int in sheet_frames:
		keep.append(int(round(float(k) / float(maxi(sheet_frames - 1, 1)) * float(n - 1))))
	var prev: Image = null
	var diffs: Array[float] = []
	var saved: Array = []
	var frame_ms: Array[float] = []
	for i: int in n:
		var t: float = t0 + float(i) / fps
		_set_clock(t)
		var t_a: int = Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		frame_ms.append(float(Time.get_ticks_usec() - t_a) / 1000.0)
		var img: Image = viewport.get_texture().get_image()
		var sub: Image = img.get_region(crop)
		if keep.has(i):
			var path: String = out_dir.path_join("frames/%s_%s_%d.png" % [id, seq, keep.find(i)])
			var err: int = sub.save_png(path)
			if err != OK:
				errors.append("save failed " + path)
			saved.append({"k": keep.find(i), "t": t, "png": path, "phase": str((motion.get("last_frame") as Dictionary).get("phase", ""))})
		var small: Image = sub.duplicate() as Image
		small.resize(maxi(1, crop.size.x / 4), maxi(1, crop.size.y / 4), Image.INTERPOLATE_BILINEAR)
		if prev != null:
			diffs.append(_mean_abs_diff(prev, small))
		prev = small
	var sorted: Array[float] = diffs.duplicate()
	sorted.sort()
	var p95: float = sorted[int(float(sorted.size() - 1) * 0.95)] if not sorted.is_empty() else 0.0
	var med: float = sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0
	var mx: float = sorted[sorted.size() - 1] if not sorted.is_empty() else 0.0
	var fsorted: Array[float] = frame_ms.duplicate()
	fsorted.sort()
	return {"crop": [crop.position.x, crop.position.y, crop.size.x, crop.size.y], "frames": n, "saved": saved,
		"diff_median": med, "diff_p95": p95, "diff_max": mx, "spike_ratio": mx / maxf(p95, 0.25),
		"diff_series": diffs, "frame_wait_ms_p50": fsorted[fsorted.size() / 2] if not fsorted.is_empty() else 0.0}

## Double-click focus, rendered: settled, eased in, holding, back (full frames, the camera moves).
func _render_focus(id: String, t: float) -> Array:
	motion.call("settle_now", t)
	_set_clock(t)
	var out: Array = []
	motion.call("focus", t + 0.2)
	var k: int = 0
	for dt: float in [0.0, 0.9, 5.0, 11.4]:
		_set_clock(t + 0.2 + dt)
		await RenderingServer.frame_post_draw
		var img: Image = viewport.get_texture().get_image()
		var path: String = out_dir.path_join("frames/%s_focus_%d.png" % [id, k])
		img.save_png(path)
		out.append({"k": k, "t": t + 0.2 + dt, "png": path})
		k += 1
	_set_clock(t + 12.0)
	return out

static func _mean_abs_diff(a: Image, b: Image) -> float:
	var da: PackedByteArray = a.get_data()
	var db: PackedByteArray = b.get_data()
	var n: int = mini(da.size(), db.size())
	var s: int = 0
	var step: int = 1
	for i: int in range(0, n, step):
		s += absi(int(da[i]) - int(db[i]))
	return float(s) / float(maxi(n / step, 1))

# ------------------------------------------------------------------ extras (no rendering)
func _extras(id: String, t_start: float) -> Dictionary:
	var out: Dictionary = {}
	var camera: Camera3D = scene.get("camera")
	var t: float = t_start
	# determinism / clock independence: the same arrival replayed on a fresh timeline, reached by a 60 Hz walk from
	# its start or by one jump, gives the same pose (any clock scale is only a different stepping of t)
	var t_probe: Array[float] = []
	motion.call("hide_now", t)
	var t_set: float = float(motion.call("arrive", t + 0.2))
	for frac: float in [0.2, 0.5, 0.8, 0.97]:
		t_probe.append(t + 0.2 + (t_set - t - 0.2) * frac)
	var direct: Array = []
	for tp: float in t_probe:
		_set_clock(tp)
		direct.append(_key_points(motion.get("last_frame")))
	var stepped: Array = []
	var k: int = 0
	var tt: float = t
	while k < t_probe.size():
		tt = minf(tt + 1.0 / 7.0, t_probe[k])
		_set_clock(tt)
		if is_equal_approx(tt, t_probe[k]):
			stepped.append(_key_points(motion.get("last_frame")))
			k += 1
	var worst: float = 0.0
	var worst_at: Array = []
	for i: int in direct.size():
		var a: Dictionary = direct[i]
		var b: Dictionary = stepped[i]
		for rk: String in a.keys():
			if not b.has(rk):
				worst = INF
				continue
			var pa: Array = (a[rk] as Dictionary).points
			var pb: Array = (b[rk] as Dictionary).points
			for pi: int in mini(pa.size(), pb.size()):
				var dd: float = (pa[pi] as Vector3).distance_to(pb[pi] as Vector3)
				if dd > worst:
					worst = dd
					worst_at = [t_probe[i], rk, pi]
	out["determinism_max_m"] = worst
	out["determinism_worst_at"] = worst_at
	_check(id + ":same_pose_any_stepping", worst < 1e-4, worst)
	t = t_set + 1.0
	# settle again, then wander (a 3-minute window)
	motion.call("settle_now", t)
	_set_clock(t)
	var ok_w: bool = bool(motion.call("wander", t + 0.5, t + 180.0))
	out["wander_scheduled"] = ok_w
	if ok_w:
		var mw: Dictionary = await _metrics(id, "wander", t + 0.4, t + 181.0)
		out["wander"] = {"pops": mw.pops, "pop_list": mw.pop_list, "walk_max_planted_gap_m": mw.walk_max_planted_gap_m, "walk_min_foot_gap_m": mw.walk_min_foot_gap_m, "phases": mw.phases,
			"max_point_step_m": mw.max_point_step_m, "gap_series_t_left_right": mw.gap_series_t_left_right}
		_check(id + ":wander:no_pops", int(mw.pops) == 0, mw.pop_list)
		t += 182.0
	# night: doze for 20 s, tent in, night end
	motion.call("settle_now", t)
	motion.call("night_doze", t)
	var md: Dictionary = await _metrics(id, "doze", t, t + 16.0)
	out["doze"] = {"pops": md.pops, "phases": md.phases}
	_check(id + ":doze:no_pops", int(md.pops) == 0, md.pop_list)
	var fr: Dictionary = motion.get("last_frame")
	out["doze_head_pitch_deg"] = rad_to_deg(float(fr.get("head_pitch", 0.0)))
	t += 16.0
	var tent: bool = bool(motion.call("tent_in", t))
	out["tent_in"] = tent
	if tent:
		var mt: Dictionary = await _metrics(id, "tent", t, t + 20.0)
		var fr2: Dictionary = motion.get("last_frame")
		out["tent_hidden"] = str(fr2.get("phase", "")) == "tent"
		_check(id + ":tent_in_hides", bool(out.tent_hidden), fr2.get("phase"))
		var t_back: float = float(motion.call("night_end", t + 20.0))
		var mt2: Dictionary = await _metrics(id, "tent_out", t + 20.0, t_back + 1.0)
		out["tent"] = {"pops": int(mt.pops) + int(mt2.pops), "back_s": t_back - (t + 20.0), "pop_list": (mt.pop_list as Array) + (mt2.pop_list as Array)}
		_check(id + ":tent:no_pops", int(mt.pops) + int(mt2.pops) == 0, out.tent)
		t = t_back + 1.0
	else:
		motion.call("night_end", t)
		t += 3.0
	# double-click focus: ease in, hold, return exactly
	motion.call("settle_now", t)
	_set_clock(t)
	var xf0: Transform3D = camera.global_transform
	var ok_f: bool = bool(motion.call("focus", t))
	_set_clock(t + 1.4 + 4.0)
	var xf_mid: Transform3D = camera.global_transform
	var rect_mid: Rect2 = motion.call("figure_rect")
	_set_clock(t + 1.4 + 8.0 + 1.6 + 0.1)
	var xf1: Transform3D = camera.global_transform
	out["focus"] = {"accepted": ok_f, "moved_m": xf0.origin.distance_to(xf_mid.origin), "restored_err_m": xf0.origin.distance_to(xf1.origin),
		"figure_height_px_hold": rect_mid.size.y}
	_check(id + ":focus_returns", ok_f and xf0.origin.distance_to(xf1.origin) < 1e-4 and xf0.origin.distance_to(xf_mid.origin) > 1.0, out.focus)
	# hit test on the settled figure
	var r: Rect2 = motion.call("figure_rect")
	var ev: InputEventMouseButton = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = r.get_center()
	var t_hit: float = t + 12.0
	_set_clock(t_hit)
	var hit: bool = bool(motion.call("handle_input", ev, t_hit))
	out["click_hit_test"] = {"rect": [r.position.x, r.position.y, r.size.x, r.size.y], "handled": hit}
	_check(id + ":click_on_figure_handled", hit, out.click_hit_test)
	ev.position = Vector2(5, 5)
	var miss: bool = bool(motion.call("handle_input", ev, t_hit + 10.0))
	_check(id + ":click_off_figure_ignored", not miss, miss)
	motion.call("settle_now", t_hit + 20.0)
	_set_clock(t_hit + 20.0)
	# Carlos 2026-09-27: a player's double click anywhere leaves the camera on its framing (the push-in is --lshu-dev only)
	motion.set("dev_focus", false)
	var xf_dc0: Transform3D = camera.global_transform
	var dc: InputEventMouseButton = InputEventMouseButton.new()
	dc.button_index = MOUSE_BUTTON_LEFT
	dc.pressed = true
	dc.double_click = true
	dc.position = Vector2(40, 40)
	var t_dc: float = t_hit + 21.0
	_set_clock(t_dc)
	var dc_handled: bool = bool(motion.call("handle_input", dc, t_dc))
	_set_clock(t_dc + 1.4 + 4.0)
	var xf_dc1: Transform3D = camera.global_transform
	out["double_click"] = {"handled": dc_handled, "moved_m": xf_dc0.origin.distance_to(xf_dc1.origin), "focus_seg": not (motion.get("focus_seg") as Dictionary).is_empty()}
	_check(id + ":double_click_keeps_framing", not dc_handled and xf_dc0.origin.distance_to(xf_dc1.origin) < 1e-4 and (motion.get("focus_seg") as Dictionary).is_empty(), out.double_click)
	motion.call("settle_now", t_dc + 10.0)
	_set_clock(t_dc + 10.0)
	out["evidence"] = motion.call("evidence")
	return out
