extends SceneTree
## 第四幕「L叔在哪儿」· QA: is anything of L叔 drawn where he is hidden? (verify_r1 finding 1, the rim "ghost")
## Runs the directed scene (scenes/traveler/lshu_main.tscn, director on) in the 1920x1080 MSAA 4x SubViewport of the
## other act-4 harnesses, on a fresh save at --scale (600) from --date --start (07:00 local), and stops at moments of
## these kinds (the first of each):
##   road      the loop is on the road, the tile he left on screen, his rigs at opacity 0
##   tent      night, he is in the tent (motion phase tent), rigs at opacity 0
##   hidden    on a stop, motion bound, both rigs at opacity 0 (before the walk-in / after the walk-out), no switch
##   fading    on a stop, the drawn rig at 0 < opacity < 1 (walk-in / walk-out / cross-fade): reported, not gated
##   shown     night, he is settled and fully drawn: the positive control (the rim must be visible here)
## At each moment the whole tree is paused (every animation holds, the viewport keeps drawing) and three frames are
## read, each once two consecutive frames are identical: A, A again (noise floor, reported), B with every rim
## pass of every rig at rim_strength 0, and C with the rim back. Right after a tile swap the paused frame can still
## drift by 1/255 over the whole tile (A != C); a pixel counts as a rim pixel when |A-B| > |A-C| there. For the
## hidden kinds there must be no rim pixel over the whole frame (and when nothing drifts, A == B exactly); for "shown"
## there must be rim pixels (the probe can see a rim). Also checked once: every rim next_pass on a rig's surfaces is that rig's own rim
## material (so one rig's opacity never fades another's rim).
##   Godot --path . --script res://tools/traveler/lshu/qa/lshu_rim_ghost_check.gd -- --park=26 --out=/abs/dir
##         [--scale=600] [--date=2026-09-24] [--start=07:00] [--hours=24] [--kinds=road,tent,hidden,fading,shown]
## Output: <out>/rim_ghost_report.json, <out>/<kind>_A.png, <out>/<kind>_crop.png (A | B | |A-B| x 16 around him).
## Last line: LSHU_RIM_GHOST checks=C failed=F

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const CLOCK: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const RIM_SHADER_PATH: String = "res://shaders/traveler/lshu/lshu_character_rim.gdshader"
const GATED: Array[String] = ["road", "tent", "hidden"]

var viewport: SubViewport
var scene: Node3D
var director: Node
var out_dir: String = ""
var scale: float = 600.0
var date_s: String = "2026-09-24"
var start_s: String = "07:00"
var hours: float = 24.0
var kinds: Array[String] = ["road", "tent", "hidden", "fading", "shown"]
var done: Dictionary = {}
var checks: Array = []
var probes: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, ok: bool, value: Variant) -> void:
	checks.append({"name": name, "ok": ok, "value": value})
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, JSON.stringify(value).left(400)])

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
		elif arg.begins_with("--kinds="):
			kinds.clear()
			for k: String in arg.trim_prefix("--kinds=").split(","):
				kinds.append(k)
	if out_dir.is_empty():
		push_error("rim_ghost_check: --out is required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	var save_dir: String = out_dir.path_join("save")
	_clear_dir(save_dir)
	DirAccess.make_dir_recursive_absolute(save_dir)
	var d: PackedStringArray = date_s.split("-")
	var hm: PackedStringArray = start_s.split(":")
	var local_unix: int = Time.get_unix_time_from_datetime_dict({"year": int(d[0]), "month": int(d[1]), "day": int(d[2]), "hour": int(hm[0]), "minute": int(hm[1]), "second": 0})
	var start_unix: int = local_unix - int(CLOCK.call("system_tz_offset_s"))
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
		"--lshu-save-dir=" + save_dir, "--lshu-dev"]))
	director = scene.get_node("Director")
	viewport.add_child(scene)
	var waited: int = 0
	while not bool(director.get("started")):
		await process_frame
		waited += 1
		if waited > 6000:
			push_error("rim_ghost_check: the director never started")
			quit(1)
			return
	var owned_checked: bool = false
	var end_logic: float = float(start_unix) + hours * 3600.0
	while float(director.call("logic_now")) < end_logic and done.size() < kinds.size():
		await process_frame
		if not owned_checked and bool(scene.get("prewarmed")):
			owned_checked = true
			_check_rim_ownership()
		var kind: String = _moment()
		if kind != "" and kinds.has(kind) and not done.has(kind):
			done[kind] = true
			await _probe(kind)
	if not owned_checked:
		_check_rim_ownership()
	for k2: String in kinds:
		if not done.has(k2):
			_check("caught_" + k2, not GATED.has(k2), {"note": "no moment of this kind in the run"})
	_finish()

## The kind of moment on screen now ("" = none of interest).
func _moment() -> String:
	if bool(director.get("switching")) or bool(director.get("rendering")) or bool(director.get("snapping")):
		return ""
	var motion: Node = director.get("motion")
	if motion == null or not bool(motion.get("bound")):
		return ""
	var ev: Dictionary = director.call("evidence")
	var mf: Dictionary = motion.get("last_frame") as Dictionary
	if mf.is_empty():
		return ""
	var fade_ev: Dictionary = ev.get("fade", {}) as Dictionary
	if float(fade_ev.get("alpha", 0.0)) > 0.0:
		return ""   # the switch cover is on screen
	var a: float = _him_alpha(mf)
	var sub: String = str(ev.substate)
	if sub == "ROAD":
		return "road" if a == 0.0 else ""
	if str(ev.night_phase) == "tent" and str(mf.get("phase", "")) == "tent" and a == 0.0:
		return "tent"
	if a == 0.0:
		return "hidden"
	if a < 1.0:
		return "fading"
	if float(ev.night_weight) >= 1.0 and not bool(mf.get("w_show", false)):
		return "shown"
	return ""

static func _him_alpha(mf: Dictionary) -> float:
	return maxf(float(mf.get("k_alpha", 0.0)), float(mf.get("w_alpha", 0.0)) if bool(mf.get("w_show", false)) else 0.0)

## The rigs that have a rim pass, in one fixed order (their rim materials are _rim_materials()).
func _rim_rigs() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var ch: Node = scene.get("character") as Node
	for r: Variant in (ch.get("rigs") as Dictionary).values():
		if (r as Node3D).get("rim_material") != null:
			out.append(r as Node3D)
	return out

func _rim_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for r: Node3D in _rim_rigs():
		out.append(r.get("rim_material") as ShaderMaterial)
	return out

## Every rim next_pass on a rig's drawn surfaces is that rig's own rim material.
func _check_rim_ownership() -> void:
	var ch: Node = scene.get("character") as Node
	var per_rig: Dictionary = {}
	var foreign: int = 0
	for key: Variant in (ch.get("rigs") as Dictionary).keys():
		var rig: Node3D = (ch.get("rigs") as Dictionary)[key]
		var own: ShaderMaterial = rig.get("rim_material") as ShaderMaterial
		var n_own: int = 0
		for node: Node in rig.find_children("*", "MeshInstance3D", true, false):
			var mi: MeshInstance3D = node as MeshInstance3D
			if mi.mesh == null:
				continue
			for s: int in mi.mesh.get_surface_count():
				var m: Material = mi.get_active_material(s)
				while m != null:
					var sm: ShaderMaterial = m as ShaderMaterial
					if sm != null and sm.shader != null and sm.shader.resource_path == RIM_SHADER_PATH:
						if sm == own:
							n_own += 1
						else:
							foreign += 1
					m = m.next_pass
		per_rig[str(key)] = n_own
	_check("rim_pass_owned_by_its_rig", foreign == 0, {"own_rim_surfaces": per_rig, "foreign": foreign})

func _probe(kind: String) -> void:
	var motion: Node = director.get("motion")
	var ev: Dictionary = director.call("evidence")
	var mf: Dictionary = (motion.get("last_frame") as Dictionary).duplicate()
	paused = true
	await _frames(4)
	var sa: Array = await _settled()
	var ia: Image = sa[0]
	await _frames(2)
	var ia2: Image = await _grab()
	var mats: Array[ShaderMaterial] = _rim_materials()
	var saved: Array = []
	var fades: Array = []
	for rm: ShaderMaterial in mats:
		saved.append(rm.get_shader_parameter("rim_strength"))
		fades.append(rm.get_shader_parameter("rim_fade"))
		rm.set_shader_parameter("rim_strength", 0.0)
	await _frames(3)
	var sb: Array = await _settled()
	var ib: Image = sb[0]
	for i: int in mats.size():
		mats[i].set_shader_parameter("rim_strength", saved[i] if saved[i] != null else 0.0)
	await _frames(3)
	var sc: Array = await _settled()
	var ic: Image = sc[0]
	# sensitivity control for the hidden kinds: the pre-fix behaviour (rim_fade forced back to 1 on every rig) must
	# show up as rim pixels wherever a rim is lit, so a 0 above is not a blind probe
	var id_img: Image = null
	if GATED.has(kind):
		for rm2: ShaderMaterial in mats:
			rm2.set_shader_parameter("rim_fade", 1.0)
		await _frames(3)
		id_img = (await _settled())[0]
		for j: int in mats.size():
			mats[j].set_shader_parameter("rim_fade", fades[j] if fades[j] != null else 1.0)
		await _frames(2)
	var crop: Rect2i = _crop_rect(motion)
	var whole: Rect2i = Rect2i(0, 0, ia.get_width(), ia.get_height())
	var noise: Dictionary = _diff(ia, ia2, whole)
	var drift: Dictionary = _diff(ia, ic, whole)
	var full: Dictionary = _diff(ia, ib, whole, ic)
	var near: Dictionary = _diff(ia, ib, crop, ic)
	ia.save_png(out_dir.path_join(kind + "_A.png"))
	_save_crop_strip(ia, ib, crop, out_dir.path_join(kind + "_crop.png"))
	var row: Dictionary = {"kind": kind, "local": ev.local, "substate": ev.substate, "night_phase": ev.night_phase, "motion_phase": mf.get("phase", ""),
		"stage_name": ev.stage_name, "night_weight": ev.night_weight, "him_alpha": _him_alpha(mf), "k_alpha": mf.get("k_alpha", 0.0),
		"w_show": mf.get("w_show", false), "w_alpha": mf.get("w_alpha", 0.0), "rim_strength": saved, "rim_fade": fades,
		"settle_frames": [sa[1], sb[1], sc[1]], "noise_floor": noise, "drift_a_to_c": drift, "rim_off_full_frame": full, "rim_off_near_him": near, "crop": [crop.position.x, crop.position.y, crop.size.x, crop.size.y]}
	probes.append(row)
	if id_img != null:
		var ghost: Dictionary = _diff(id_img, ib, whole)
		row["pre_fix_ghost_vs_rim_off"] = ghost
		_save_crop_strip(id_img, ib, crop, out_dir.path_join(kind + "_pre_fix_crop.png"))
		# a hidden rig on the stage (not parked under it) with a lit rim: the verify_r1 ghost must show up to this probe
		var lit2: bool = false
		var rigs: Array[Node3D] = _rim_rigs()
		for j2: int in rigs.size():
			var on_stage: bool = rigs[j2].position.y > -100.0
			var faded: bool = fades[j2] != null and float(fades[j2]) < 1.0
			if on_stage and faded and saved[j2] != null and float(saved[j2]) > 0.0:
				lit2 = true
		row["pre_fix_ghost_expected"] = lit2
		_check("probe_sees_pre_fix_ghost_" + kind, (not lit2) or int(ghost.max_255) > int(drift.max_255), {"expected": lit2, "rim_strength": saved, "rim_fade": fades, "pre_fix_ghost": ghost})
	if GATED.has(kind):
		_check("no_rim_when_hidden_" + kind, int(full.rim_px) == 0 and int(near.rim_px) == 0, {"local": ev.local, "stage": ev.stage_name,
			"motion_phase": mf.get("phase", ""), "him_alpha": _him_alpha(mf), "rim_fade": fades, "full_frame": full, "near_him": near, "drift_a_to_c": drift})
	elif kind == "shown":
		var lit: bool = false
		for v: Variant in saved:
			if v != null and float(v) > 0.0:
				lit = true
		_check("rim_visible_when_shown", (not lit) or (int(near.rim_px) > 0 and int(near.rim_max_255) > int(noise.max_255)), {"local": ev.local, "stage": ev.stage_name,
			"rim_strength": saved, "rim_fade": fades, "near_him": near, "noise_floor": noise})
	else:
		print("INFO fading %s" % JSON.stringify({"him_alpha": _him_alpha(mf), "rim_fade": fades, "near_him": near}))
	paused = false
	await _frames(2)

func _crop_rect(motion: Node) -> Rect2i:
	var cam: Camera3D = scene.get("camera") as Camera3D
	var hm: float = float((scene.get("character") as Node).get("height_m"))
	var pts: Array[Vector3] = [motion.get("base_pos") as Vector3]
	var walker: Node3D = motion.get("walker") as Node3D
	if walker != null and walker.position.y > -100.0:
		pts.append(((walker.get("character") as Node3D).global_position))
	var mn: Vector2 = Vector2(INF, INF)
	var mx: Vector2 = -mn
	for p: Vector3 in pts:
		for q: Vector3 in [p, p + Vector3.UP * hm]:
			if cam.is_position_behind(q):
				continue
			var s: Vector2 = cam.unproject_position(q)
			mn = mn.min(s)
			mx = mx.max(s)
	if mn.x == INF:
		return Rect2i(0, 0, 1920, 1080)
	var h: float = maxf(mx.y - mn.y, 40.0)
	var r: Rect2 = Rect2(mn, mx - mn).grow_individual(h * 0.6 + 30.0, h * 0.3 + 30.0, h * 0.6 + 30.0, h * 0.3 + 30.0)
	return Rect2i(r).intersection(Rect2i(0, 0, 1920, 1080))

## Frames until two consecutive ones are identical (a paused scene can still converge for a few frames right after a
## tile swap); returns [the settled image, frames it took] (at most 180).
func _settled() -> Array:
	var prev: Image = await _grab()
	for i: int in 180:
		var cur: Image = await _grab()
		if cur.get_data() == prev.get_data():
			return [cur, i + 1]
		prev = cur
	return [prev, -1]

func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var img: Image = viewport.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img

## Max channel difference of a and b over r. With c (the frame after the rim came back): rim_px / rim_max_255 count
## only the pixels where a and b differ by more than a and c do (more than whatever still settles in the paused
## scene), i.e. the rim toggle.
func _diff(a: Image, b: Image, r: Rect2i, c: Image = null) -> Dictionary:
	var da: PackedByteArray = a.get_data()
	var db: PackedByteArray = b.get_data()
	if da == db:
		return {"px": 0, "max_255": 0, "rim_px": 0, "rim_max_255": 0, "area": r.size.x * r.size.y}
	var dc: PackedByteArray = c.get_data() if c != null else da
	var w: int = a.get_width()
	var px: int = 0
	var mx: int = 0
	var rpx: int = 0
	var rmx: int = 0
	for y: int in range(r.position.y, r.position.y + r.size.y):
		var row: int = y * w * 3
		for x: int in range(r.position.x, r.position.x + r.size.x):
			var i: int = row + x * 3
			var m: int = maxi(absi(da[i] - db[i]), maxi(absi(da[i + 1] - db[i + 1]), absi(da[i + 2] - db[i + 2])))
			if m > 0:
				px += 1
				mx = maxi(mx, m)
				var mc: int = maxi(absi(da[i] - dc[i]), maxi(absi(da[i + 1] - dc[i + 1]), absi(da[i + 2] - dc[i + 2])))
				if m > mc:
					rpx += 1
					rmx = maxi(rmx, m)
	return {"px": px, "max_255": mx, "rim_px": rpx, "rim_max_255": rmx, "area": r.size.x * r.size.y}

func _save_crop_strip(a: Image, b: Image, r: Rect2i, path: String) -> void:
	if r.size.x < 4 or r.size.y < 4:
		return
	var ca: Image = a.get_region(r)
	var cb: Image = b.get_region(r)
	var cd: Image = Image.create(r.size.x, r.size.y, false, Image.FORMAT_RGB8)
	for y: int in r.size.y:
		for x: int in r.size.x:
			var p: Color = ca.get_pixel(x, y)
			var q: Color = cb.get_pixel(x, y)
			cd.set_pixel(x, y, Color(minf(absf(p.r - q.r) * 16.0, 1.0), minf(absf(p.g - q.g) * 16.0, 1.0), minf(absf(p.b - q.b) * 16.0, 1.0)))
	var strip: Image = Image.create(r.size.x * 3 + 8, r.size.y, false, Image.FORMAT_RGB8)
	strip.fill(Color(1, 1, 1))
	strip.blit_rect(ca, Rect2i(Vector2i.ZERO, r.size), Vector2i(0, 0))
	strip.blit_rect(cb, Rect2i(Vector2i.ZERO, r.size), Vector2i(r.size.x + 4, 0))
	strip.blit_rect(cd, Rect2i(Vector2i.ZERO, r.size), Vector2i(r.size.x * 2 + 8, 0))
	strip.save_png(path)

func _frames(n: int) -> void:
	for _i: int in n:
		await process_frame

func _finish() -> void:
	var failed: int = 0
	for c: Variant in checks:
		if not bool((c as Dictionary).ok):
			failed += 1
	var f: FileAccess = FileAccess.open(out_dir.path_join("rim_ghost_report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema": "lshu.rim_ghost.v1", "scale": scale, "date": date_s, "start": start_s, "probes": probes, "checks": checks, "failed": failed,
		"definition": "tree paused at the moment; A = as drawn, A2 = A again (noise floor), B = every rig rim pass at rim_strength 0; diff = max channel |A-B| (0-255) over the 1920x1080 frame and over a crop around where he stands"}, " "))
	f.close()
	print("LSHU_RIM_GHOST checks=%d failed=%d" % [checks.size(), failed])
	scene.queue_free()
	for _i: int in 3:
		await process_frame
	quit(0 if failed == 0 else 1)

func _clear_dir(path: String) -> void:
	var dd: DirAccess = DirAccess.open(path)
	if dd == null:
		return
	for sub: String in dd.get_directories():
		_clear_dir(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))
	for fname: String in dd.get_files():
		DirAccess.remove_absolute(path.path_join(fname))
