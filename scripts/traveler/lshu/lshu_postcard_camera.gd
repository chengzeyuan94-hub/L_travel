extends Node
## 第四幕「L叔在哪儿」· postcard camera.
## Renders a postcard of the tile on screen with its own Camera3D in a SubViewport that shares the stage's World3D
## (own_world_3d = false): same tile, same light, same moment of motion as the main view. 1500x1000, UPDATE_ONCE,
## RenderingServer.frame_post_draw awaited with a 2 s timeout (macOS stops drawing an occluded window; the process loop
## keeps running, so the timeout still fires). JPG quality 90 at <save dir>/postcards/<id>.jpg, written off the main thread.
##
## Shot rules (numbers: data/traveler/lshu/postcard_camera.json, all starting points). Every input is the tile's baked data
## (camera fit, bounds, landmark, terrain) and L叔's live pose; nothing is per tile.
##   far   the main camera raised and narrowed, tilt-shift depth of field; distance solved so L叔 is 3-5% of the frame height
##   mid   on the extension of landmark -> L叔, 3-5 m behind him, 1.5 m up, looking at him, focus on him
##   back  in his back half-space, as far behind him as still keeps him and the landmark in one frame, looking toward the
##         landmark (straight behind him when he faces it; three-quarter back when the landmark is behind him)
##   snap  the click-him photo: from the main camera's side, close, focus on him
## The rule is the record's `shot` (the loop draws far / mid / back 40 / 40 / 20); a record without one gets it from its seed
## with the same weights. Sub-choices (distance, yaw jitter, side) come from the record seed, so a record always gives the
## same camera. Segments from the camera to five points on L叔 are tested against the terrain and the landmark (TriangleMesh
## on the rendered meshes); when he is occluded the next rule is tried (far -> mid -> back -> far; snap -> mid -> far).
##
## The look's own rules are re-applied to the postcard camera: an Environment copy with the depth fog re-based on its
## focus distance, its own CameraAttributesPractical (DOF), and a copy of the sun whose shadow range follows its distance.
## The copy is on a render layer the main camera does not draw, and for the render frame the real sun sits on a layer the
## postcard camera does not draw, so the main view is unchanged (checked pixel by pixel in the harness).
##
## Waiting for the frame: Godot draws a frame or two whenever a viewport, mesh or texture is created, even while the main
## loop is not drawing (measured with render_loop_enabled = false and with the window minimized), so a postcard whose
## viewport is made inside the render normally gets its frame at once. When no frame comes within timeout_s (2 s), the id
## goes to pending_renders and render_timed_out is emitted; nothing is written, the stage is restored. The harness
## exercises this with a viewport and plan made beforehand (prepare_viewport, plan_shot + render_plan): 2.0 s, then
## retry_pending renders it.
## Main-thread cost per postcard (harness, 14 renders): planning 11-22 ms, texture read-back 14-24 ms, setup < 1 ms;
## the JPG is encoded on a WorkerThreadPool task (10-18 ms).
##
## Director usage (no class_name; preload):
##   const LshuPostcardCamera := preload("res://scripts/traveler/lshu/lshu_postcard_camera.gd")
##   var pc_cam: Node = LshuPostcardCamera.new()
##   stage.add_child(pc_cam)                     # stage = the lshu_main.gd node
##   pc_cam.setup(stage)
##   var rec: Dictionary = LshuSave.find_postcard(save, id)
##   var r: Dictionary = await pc_cam.render_postcard(rec, store.dir)
##   if r.ok: LshuSave.complete_render(save, r.id, r.path)
##   elif r.timed_out: pass                      # id stays in save.pending_renders and pc_cam.pending_renders
##   ... window visible again: for r2 in await pc_cam.retry_pending(save, store.dir): complete_render on each ok
##   var s: Dictionary = await pc_cam.snap(snap_id, store.dir)   # click-him photo (same result shape); call it once he has
##                                               # turned to the player (he faces the main camera side in this shot)
##   plan_shot(record, rule) / render_plan(plan, id, dir): plan now, render later on the same tile (else "stale_plan").
##   A pending record whose tile is no longer on screen is left pending by retry_pending (error tile_not_on_screen): the
##   loop's start-up re-render builds that tile first (loop/README.md).
## Result: {ok, id, path, timed_out, rule, requested, fallback, error, report{...}}. The render is serialised: a second
## call waits for the first.

signal postcard_rendered(id: String, path: String)
signal render_timed_out(id: String)

const LSHU_CAMERA: GDScript = preload("res://scripts/traveler/lshu/lshu_camera.gd")
const LSHU_HASH: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_hash.gd")
const CONFIG_PATH: String = "res://data/traveler/lshu/postcard_camera.json"
const RULES: Array[String] = ["far", "mid", "back"]
const SALT_SHOT: int = 0x50430001
const SALT_SUB: int = 0x50430100
const ALL_LAYERS: int = 0xFFFFF

var cfg: Dictionary = {}
var stage: Node3D
## Ids whose render timed out (window not drawing). The director retries them when the window is visible.
var pending_renders: Array[String] = []
var last_report: Dictionary = {}
var renders: int = 0
var timeouts: int = 0
var _busy: bool = false
var _vp: SubViewport
var _cam: Camera3D


static func load_config(path: String = CONFIG_PATH) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("LSHU postcard_camera.json missing or invalid: " + path)
		return {}
	return parsed


func setup(stage_node: Node3D, config: Dictionary = {}) -> bool:
	stage = stage_node
	cfg = config if not config.is_empty() else load_config()
	return not cfg.is_empty()


func is_busy() -> bool:
	return _busy


## <save dir>/postcards/<id>.jpg (the same path LshuSave.postcard_image_path gives).
static func image_path(save_dir: String, id: String) -> String:
	return save_dir.path_join("postcards").path_join(id + ".jpg")


## Keeps a timed-out id in the save's pending list (the loop put it there; this only guards against it missing).
static func mark_pending(save: Dictionary, id: String) -> void:
	var pending: Array = save.get("pending_renders", []) as Array
	if not pending.has(id):
		pending.append(id)
	save["pending_renders"] = pending


static func record_seed(record: Dictionary) -> int:
	var s: int = int(record.get("line_seed", 0)) & 0xFFFFFFFF
	if s == 0:
		s = LSHU_HASH.str_hash(str(record.get("id", "")))
	return s


## The record's own shot when it names a rule, else one drawn from the record seed with the weights.
static func pick_rule(record: Dictionary, weights: Dictionary) -> String:
	var shot: String = str(record.get("shot", ""))
	if RULES.has(shot) or shot == "snap":
		return shot
	var total: float = 0.0
	for r: String in RULES:
		total += maxf(0.0, float(weights.get(r, 0.0)))
	if total <= 0.0:
		return RULES[0]
	var u: float = LSHU_HASH.unit(record_seed(record), int(record.get("leg", 0)), SALT_SHOT)
	var acc: float = 0.0
	for r: String in RULES:
		acc += maxf(0.0, float(weights.get(r, 0.0))) / total
		if u < acc:
			return r
	return RULES[RULES.size() - 1]


func _order(first: String) -> Array[String]:
	var out: Array[String] = []
	if first == "snap":
		for r: Variant in cfg.get("snap_order", ["snap", "mid", "far"]):
			out.append(str(r))
		return out
	var base: Array[String] = []
	for r: Variant in cfg.get("rule_order", RULES):
		base.append(str(r))
	var i0: int = maxi(0, base.find(first))
	for i: int in base.size():
		out.append(base[(i0 + i) % base.size()])
	return out


static func _u(record: Dictionary, k: int) -> float:
	return LSHU_HASH.unit(record_seed(record), int(record.get("leg", 0)), SALT_SUB + k)


static func _range(v: Variant, t: float, fallback: float) -> float:
	if v is Array and (v as Array).size() >= 2:
		return lerpf(float(v[0]), float(v[1]), t)
	if v is float or v is int:
		return float(v)
	return fallback


static func _v3(v: Variant, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback


static func _arr3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]


# ------------------------------------------------------------------ public: render
## Renders the postcard for a loop record ({id, shot, line_seed, leg, ...}). Awaitable.
func render_postcard(record: Dictionary, save_dir: String, opts: Dictionary = {}) -> Dictionary:
	var id: String = str(record.get("id", ""))
	if id.is_empty():
		push_error("LSHU postcard record without id")
		return {"ok": false, "id": "", "path": "", "timed_out": false, "error": "no_id", "report": {}}
	return await _run(record, pick_rule(record, cfg.get("weights", {})), save_dir, opts)


## The click-him photo. Same result shape as render_postcard.
func snap(id: String, save_dir: String, seed_value: int = 0, opts: Dictionary = {}) -> Dictionary:
	var record: Dictionary = {"id": id, "shot": "snap", "line_seed": seed_value, "leg": 0}
	return await _run(record, "snap", save_dir, opts)


## Retries every pending id whose tile is the one on screen (a pending record for another tile needs that tile built:
## it is left pending and reported as tile_not_on_screen). Returns the results; the director calls complete_render on
## each ok one. Awaitable.
func retry_pending(save: Dictionary, save_dir: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ids: Array[String] = pending_renders.duplicate()
	for v: Variant in save.get("pending_renders", []) as Array:
		if not ids.has(str(v)):
			ids.append(str(v))
	var on_screen: String = _tile_id()
	for id: String in ids:
		var rec: Dictionary = {}
		for pc: Variant in save.get("postcards", []) as Array:
			if str((pc as Dictionary).get("id", "")) == id:
				rec = pc
		if rec.is_empty():
			if id.begins_with("snap"):
				rec = {"id": id, "shot": "snap"}
			else:
				pending_renders.erase(id)
				out.append({"ok": false, "id": id, "path": "", "timed_out": false, "error": "no_record", "report": {}})
				continue
		if rec.has("tile") and str(rec.get("tile", "")) != on_screen:
			out.append({"ok": false, "id": id, "path": "", "timed_out": false, "error": "tile_not_on_screen", "report": {}})
			continue
		var r: Dictionary = await render_postcard(rec, save_dir)
		out.append(r)
		if bool(r.get("timed_out", false)):
			break   # still not drawing: stop, the rest stay pending
	return out


## Renders a plan made earlier by plan_shot() (the director may plan ahead, e.g. to check the rule, and render later
## on the same stage state). Awaitable; same result shape as render_postcard.
func render_plan(plan: Dictionary, id: String, save_dir: String, opts: Dictionary = {}) -> Dictionary:
	while _busy and is_inside_tree():
		await get_tree().process_frame
	_busy = true
	var result: Dictionary
	if not bool(plan.get("ok", false)):
		result = {"ok": false, "id": id, "path": "", "timed_out": false, "error": str(plan.get("error", "plan_failed")), "report": {}}
	elif not _plan_current(plan):
		result = {"ok": false, "id": id, "path": "", "timed_out": false, "error": "stale_plan", "report": {}}
	else:
		result = await _render(plan, id, save_dir, opts)
	_busy = false
	last_report = result.report
	return result


## A plan is only valid on the stage state it was made on (same tile node).
func _plan_current(plan: Dictionary) -> bool:
	var ctx: Dictionary = plan.get("ctx", {})
	var node: Variant = ctx.get("tile_node", null)
	if stage == null or not is_instance_valid(stage) or not is_instance_valid(node):
		return false
	return stage.get("tile") == node


func _tile_id() -> String:
	if stage == null or not is_instance_valid(stage):
		return ""
	return str(stage.get("tile_id"))


func _run(record: Dictionary, first: String, save_dir: String, opts: Dictionary) -> Dictionary:
	var id: String = str(record.get("id", ""))
	while _busy and is_inside_tree():
		await get_tree().process_frame
	_busy = true
	var t0: int = Time.get_ticks_usec()
	var plan: Dictionary = plan_shot(record, first)
	var plan_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var result: Dictionary
	if not bool(plan.get("ok", false)):
		push_error("LSHU postcard plan failed: " + str(plan.get("error", "")))
		result = {"ok": false, "id": id, "path": "", "timed_out": false, "error": str(plan.get("error", "plan_failed")), "report": plan}
	else:
		result = await _render(plan, id, save_dir, opts)
		(result.report as Dictionary)["plan_ms"] = plan_ms
	_busy = false
	last_report = result.report
	return result


# ------------------------------------------------------------------ planning
## The shot for a record without rendering it: {ok, rule, requested, fallback, shot{pos, basis, fov, focus...}, tried[]}.
func plan_shot(record: Dictionary, first: String) -> Dictionary:
	var ctx: Dictionary = _context()
	if not bool(ctx.ok):
		return ctx
	var tried: Array = []
	var best: Dictionary = {}
	var best_vis: float = -1.0
	for rule: String in _order(first):
		var cand: Dictionary
		match rule:
			"far": cand = _rule_far(ctx, record)
			"mid": cand = _rule_mid(ctx, record)
			"back": cand = _rule_back(ctx, record)
			"snap": cand = _rule_snap(ctx, record)
			_: cand = {"ok": false, "reason": "unknown_rule"}
		cand["rule"] = rule
		if bool(cand.get("ok", false)):
			_evaluate(ctx, cand)
		tried.append(_attempt_summary(cand))
		if bool(cand.get("ok", false)) and bool(cand.get("visible", false)):
			return _plan_out(ctx, cand, first, tried, "")
		if bool(cand.get("ok", false)) and float(cand.get("visible_fraction", 0.0)) > best_vis:
			best_vis = float(cand.get("visible_fraction", 0.0))
			best = cand
	if best.is_empty():
		return {"ok": false, "error": "no_valid_camera", "tried": tried}
	return _plan_out(ctx, best, first, tried, "best_visible")


func _plan_out(ctx: Dictionary, cand: Dictionary, first: String, tried: Array, fallback: String) -> Dictionary:
	return {"ok": true, "rule": cand.rule, "requested": first, "fallback": fallback if fallback != "" else ("" if cand.rule == first else "next_rule"),
		"shot": cand, "tried": tried, "ctx": ctx}


static func _attempt_summary(c: Dictionary) -> Dictionary:
	var out: Dictionary = {"rule": c.get("rule", ""), "ok": c.get("ok", false), "reason": c.get("reason", "")}
	if bool(c.get("ok", false)):
		out["visible"] = c.get("visible", false)
		out["visible_fraction"] = c.get("visible_fraction", 0.0)
		out["blocked_by"] = c.get("blocked_by", [])
		out["soft_blockers"] = c.get("soft_blockers", [])
		out["camera"] = _arr3(c.pos)
		out["his_frame_fraction"] = c.get("his_frame_fraction", 0.0)
	return out


## Everything the rules read from the live stage.
func _context() -> Dictionary:
	if stage == null or not is_instance_valid(stage):
		return {"ok": false, "error": "no_stage"}
	var tile_node: Node3D = stage.get("tile") as Node3D
	var main_cam: Camera3D = stage.get("camera") as Camera3D
	var sun: DirectionalLight3D = stage.get("sun") as DirectionalLight3D
	var character: Node3D = stage.get("character") as Node3D
	var look: RefCounted = stage.get("look") as RefCounted
	if tile_node == null or main_cam == null or sun == null or look == null:
		return {"ok": false, "error": "stage_not_ready"}
	var tile_data: Dictionary = tile_node.get("tile")
	var fit: Dictionary = tile_node.get("camera_fit")
	var bounds: AABB = tile_node.get("tile_bounds")
	var half: float = float((tile_data.get("tile", {}) as Dictionary).get("half", 4.0))
	var ctx: Dictionary = {"ok": true, "tile_node": tile_node, "tile": tile_data, "fit": fit, "bounds": bounds, "half": half,
		"main_cam": main_cam, "sun": sun, "look": look, "has_him": false}
	# L叔: posed body (world vertices) and facing
	var rig: Node3D = character.get("active") as Node3D if character != null else null
	if rig != null:
		var body: MeshInstance3D = rig.get("character_body") as MeshInstance3D
		var ch_node: Node3D = rig.get("character") as Node3D
		var posed: Mesh = character.call("posed_geometry") as Mesh
		if body != null and ch_node != null and posed != null and ch_node.is_visible_in_tree():
			var xf: Transform3D = body.global_transform
			var verts: PackedVector3Array = PackedVector3Array()
			for s: int in posed.get_surface_count():
				var sv: PackedVector3Array = posed.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
				for vi: int in range(0, sv.size(), 7):
					verts.append(xf * sv[vi])
			var him: AABB = xf * posed.get_aabb()
			var facing: Vector3 = ch_node.global_basis.z
			facing.y = 0.0
			ctx["has_him"] = true
			ctx["him"] = him
			ctx["him_verts"] = verts
			ctx["facing"] = facing.normalized() if facing.length() > 0.001 else Vector3.BACK
			var c: Vector3 = him.get_center()
			ctx["him_ground"] = Vector3(c.x, him.position.y, c.z)
			ctx["pose"] = str(rig.get("pose"))
	# landmark: instances with a landmark role, else the procedural structure, else the baked hero footprint
	var lcfg: Dictionary = cfg.get("landmark", {})
	var lm: AABB = AABB()
	var has_lm: bool = false
	var lm_source: String = ""
	var inst_roles: Array = lcfg.get("instance_roles", ["landmark"])
	for rec: Dictionary in tile_node.get("instance_nodes"):
		if inst_roles.has(str((rec.data as Dictionary).get("role", ""))):
			for mi: MeshInstance3D in rec.meshes:
				var box: AABB = mi.global_transform * mi.get_aabb()
				lm = box if not has_lm else lm.merge(box)
				has_lm = true
				lm_source = "instance"
	if not has_lm:
		var proc_nodes: Dictionary = tile_node.get("proc_nodes")
		for role: Variant in lcfg.get("proc_roles", ["structure"]):
			if proc_nodes.has(str(role)):
				var pm: MeshInstance3D = proc_nodes[str(role)] as MeshInstance3D
				var pbox: AABB = pm.global_transform * pm.get_aabb()
				lm = pbox if not has_lm else lm.merge(pbox)
				has_lm = true
				lm_source = "procedural"
	if not has_lm:
		var hero: Dictionary = tile_data.get("hero", {})
		if not hero.is_empty():
			var w: float = float(hero.get("width", 2.0))
			var d: float = float(hero.get("depth", 2.0))
			lm = AABB(Vector3(float(hero.get("x", 0.0)) - w * 0.5, float(hero.get("y", 0.0)), float(hero.get("z", 0.0)) - d * 0.5), Vector3(w, float(lcfg.get("fallback_height_m", 1.5)), d))
			has_lm = true
			lm_source = "hero_footprint"
	ctx["has_landmark"] = has_lm
	ctx["landmark_source"] = lm_source
	if has_lm:
		ctx["landmark"] = lm
		var lc: Vector3 = lm.get_center()
		ctx["landmark_point"] = Vector3(lc.x, lm.position.y + lm.size.y * float(lcfg.get("look_height", 0.45)), lc.z)
	# occluders (blocking) and the other placed meshes (reported only, and the camera may not start inside one)
	var ocfg: Dictionary = cfg.get("occlusion", {})
	var occ: Array[Dictionary] = []
	var soft: Array[Dictionary] = []
	var proc_nodes2: Dictionary = tile_node.get("proc_nodes")
	for role: Variant in ocfg.get("proc_roles", []):
		if proc_nodes2.has(str(role)):
			_add_occluder(occ, proc_nodes2[str(role)] as MeshInstance3D, str(role))
	var block_roles: Array = ocfg.get("instance_roles", ["landmark"])
	for rec2: Dictionary in tile_node.get("instance_nodes"):
		var role2: String = str((rec2.data as Dictionary).get("role", ""))
		for mi2: MeshInstance3D in rec2.meshes:
			_add_occluder(occ if block_roles.has(role2) else soft, mi2, role2)
	ctx["occluders"] = occ
	ctx["soft"] = soft
	return ctx


static func _add_occluder(list: Array[Dictionary], mi: MeshInstance3D, kind: String) -> void:
	if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
		return
	var tri: TriangleMesh = mi.mesh.generate_triangle_mesh()
	if tri == null:
		return
	var xf: Transform3D = mi.global_transform
	list.append({"tri": tri, "inv": xf.affine_inverse(), "aabb": xf * mi.get_aabb(), "kind": kind})


# ------------------------------------------------------------------ rules
static func _dof(d: Dictionary) -> Dictionary:
	return d.duplicate(true)


func _rule_far(ctx: Dictionary, record: Dictionary) -> Dictionary:
	var r: Dictionary = cfg.get("far", {})
	var fit: Dictionary = ctx.fit
	var bounds: AABB = ctx.bounds
	var yaw: float = deg_to_rad(float(fit.get("yaw_deg", 40.0)) + (_u(record, 1) * 2.0 - 1.0) * float(r.get("yaw_jitter_deg", 10.0)))
	var pitch: float = deg_to_rad(clampf(float(fit.get("pitch_deg", 38.0)) + float(r.get("raise_deg", 12.0)), 5.0, 80.0))
	var fov: float = float(fit.get("fov_deg", 22.0)) * float(r.get("narrow", 0.75))
	var dir: Vector3 = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)).normalized()
	var target: Vector3 = _v3(fit.get("target", null), bounds.get_center())
	var lim: Array = r.get("fraction_limits", [0.03, 0.05])
	var want: float = clampf(_range(r.get("frame_fraction", [0.035, 0.045]), _u(record, 2), 0.04), float(lim[0]), float(lim[1]))
	var dist: float = float(fit.get("distance", 30.0)) * 2.0
	var size: Vector2 = _size()
	var solve: Array = []
	if bool(ctx.has_him):
		for _i: int in 10:
			var pos_i: Vector3 = target + dir * dist
			var f: float = _his_fraction(ctx, pos_i, _look(pos_i, target), fov, size)
			solve.append([snappedf(dist, 0.01), snappedf(f, 0.00001)])
			if f <= 0.00001 or absf(f - want) < want * 0.004:
				break
			dist = clampf(dist * f / want, 3.0, float(cfg.get("far_plane", 400.0)) * 0.6)
	# the whole tile stays in frame (margin); only ever moves back
	var margin: float = float(r.get("frame_margin", 0.04))
	var pushed: int = 0
	for _j: int in 12:
		var pos_j: Vector3 = target + dir * dist
		if _aabb_in_frame(bounds, pos_j, _look(pos_j, target), fov, size, margin):
			break
		dist *= 1.08
		pushed += 1
	var pos: Vector3 = target + dir * dist
	var focus_point: Vector3 = target
	if bool(ctx.has_him):
		focus_point = _his_point(ctx, 0.6).lerp(bounds.get_center(), float(r.get("focus_to_center", 0.35)))
	return {"ok": true, "pos": pos, "target": target, "fov": fov, "focus_point": focus_point, "dof": _dof(r.get("dof", {})),
		"detail": {"yaw_deg": rad_to_deg(yaw), "pitch_deg": rad_to_deg(pitch), "fov_deg": fov, "distance": dist, "want_fraction": want, "solve": solve, "pushed_back_for_frame": pushed}}


func _rule_mid(ctx: Dictionary, record: Dictionary) -> Dictionary:
	if not bool(ctx.has_him):
		return {"ok": false, "reason": "no_character"}
	var r: Dictionary = cfg.get("mid", {})
	var ground: Vector3 = ctx.him_ground
	var away: Vector3 = Vector3.ZERO
	var dir_source: String = "landmark"
	if bool(ctx.has_landmark):
		away = ground - (ctx.landmark_point as Vector3)
		away.y = 0.0
	if away.length() < 0.3:
		away = (ctx.main_cam as Camera3D).global_position - ground
		away.y = 0.0
		dir_source = "main_camera"
	away = away.normalized()
	var back: float = _range(r.get("back_m", [3.0, 5.0]), _u(record, 3), 4.0)
	var pos: Vector3 = ground + away * back + Vector3(0.0, float(r.get("up_m", 1.5)), 0.0)
	var him_pt: Vector3 = _his_point(ctx, float(r.get("look_height", 0.55)))
	var target: Vector3 = him_pt
	if bool(ctx.has_landmark):
		target = him_pt.lerp(ctx.landmark_point as Vector3, float(r.get("look_to_landmark", 0.3)))
	return {"ok": true, "pos": pos, "target": target, "fov": float(r.get("fov_deg", 34.0)), "focus_point": him_pt, "dof": _dof(r.get("dof", {})),
		"detail": {"back_m": back, "up_m": float(r.get("up_m", 1.5)), "direction": dir_source}}


func _rule_back(ctx: Dictionary, record: Dictionary) -> Dictionary:
	if not bool(ctx.has_him):
		return {"ok": false, "reason": "no_character"}
	if not bool(ctx.has_landmark):
		return {"ok": false, "reason": "no_landmark"}
	var r: Dictionary = cfg.get("back", {})
	var ground: Vector3 = ctx.him_ground
	var fwd: Vector3 = ctx.facing
	var him: AABB = ctx.him
	var him_pt: Vector3 = _his_point(ctx, float(r.get("look_height", 0.6)))
	var lm_pt: Vector3 = ctx.landmark_point
	var lm: AABB = ctx.landmark
	var lm_top: Vector3 = Vector3(lm_pt.x, lm.position.y + lm.size.y * 0.9, lm_pt.z)
	var d0: float = _range(r.get("back_m", [2.4, 3.4]), _u(record, 4), 2.9)
	var up: float = float(r.get("up_m", 1.45))
	var max_turn: float = float(r.get("max_turn_deg", 90.0))
	var step: float = maxf(1.0, float(r.get("turn_step_deg", 5.0)))
	var max_sep: float = deg_to_rad(float(r.get("max_separation_deg", 32.0)))
	var fov_lim: Array = r.get("fov_limits_deg", [28.0, 55.0])
	var max_frac: float = float(r.get("max_frame_fraction", 0.45))
	var margin: float = float(r.get("frame_margin", 0.08))
	var growth: Array = r.get("distance_steps", [1.0, 1.35, 1.7, 2.1])
	var side_pref: float = 1.0 if _u(record, 5) < 0.5 else -1.0
	var size: Vector2 = _size()
	var pts: Array[Vector3] = [lm_pt, lm_top]
	for i: int in 8:
		pts.append(him.get_endpoint(i))
	# the camera stays in his back half-space (turn <= 90 deg from straight behind); the first placement, turning out
	# from straight behind and backing off, that holds him and the landmark in one frame is taken
	var turn: float = 0.0
	while turn <= max_turn + 0.001:
		for sgn: float in [side_pref, -side_pref]:
			var u: Vector3 = (-fwd).rotated(Vector3.UP, deg_to_rad(turn) * sgn)
			for g: Variant in growth:
				var dist: float = d0 * float(g)
				var p: Vector3 = ground + u * dist + Vector3(0.0, up, 0.0)
				var s: float = (him_pt - p).angle_to(lm_pt - p)
				if s > max_sep or (lm_pt - p).length() <= (him_pt - p).length() * 0.9:
					continue
				var fit: Dictionary = _frame_points(p, pts, size, margin)
				var fov: float = maxf(float(fit.fov), float(fov_lim[0]))
				if fov > float(fov_lim[1]):
					continue
				var basis: Basis = fit.basis
				var frac: float = _his_fraction(ctx, p, basis, fov, size)
				if frac > max_frac:
					continue
				var focus: Vector3 = him_pt.lerp(lm_pt, float(r.get("focus_to_landmark", 0.5)))
				return {"ok": true, "pos": p, "target": p - basis.z * 5.0, "basis": basis, "fov": fov, "focus_point": focus, "dof": _dof(r.get("dof", {})),
					"detail": {"back_m": dist, "up_m": up, "turn_from_straight_behind_deg": turn * sgn, "him_landmark_separation_deg": rad_to_deg(s), "fitted_fov_deg": float(fit.fov)}}
			if turn == 0.0:
				break
		turn += step
	return {"ok": false, "reason": "landmark_not_behind_reachable"}


## Look direction and vertical fov that hold every point in frame, centred, with a margin (fraction of the frame).
static func _frame_points(pos: Vector3, pts: Array[Vector3], size: Vector2, margin: float) -> Dictionary:
	var c: Vector3 = Vector3.ZERO
	for q: Vector3 in pts:
		c += q
	c /= float(maxi(1, pts.size()))
	var basis: Basis = _look(pos, c)
	var aspect: float = size.x / size.y
	var half: float = 0.0
	for _it: int in 4:
		var mn: Vector2 = Vector2(INF, INF)
		var mx: Vector2 = -mn
		for q2: Vector3 in pts:
			var v: Vector3 = basis.transposed() * (q2 - pos)
			var depth: float = maxf(0.01, -v.z)
			var t: Vector2 = Vector2(v.x / depth, v.y / depth)
			mn = mn.min(t)
			mx = mx.max(t)
		var mid: Vector2 = (mn + mx) * 0.5
		half = maxf((mx.y - mn.y) * 0.5, (mx.x - mn.x) * 0.5 / aspect) / maxf(0.05, 1.0 - 2.0 * margin)
		var dir: Vector3 = (basis * Vector3(mid.x, mid.y, -1.0)).normalized()
		basis = _look(pos, pos + dir)
	return {"basis": basis, "fov": rad_to_deg(2.0 * atan(half))}


func _rule_snap(ctx: Dictionary, _record: Dictionary) -> Dictionary:
	if not bool(ctx.has_him):
		return {"ok": false, "reason": "no_character"}
	var r: Dictionary = cfg.get("snap", {})
	var him_pt: Vector3 = _his_point(ctx, float(r.get("look_height", 0.6)))
	var to_main: Vector3 = (ctx.main_cam as Camera3D).global_position - him_pt
	to_main.y = 0.0
	var yaw_dir: Vector3 = to_main.normalized() if to_main.length() > 0.01 else Vector3.BACK
	var pitch: float = deg_to_rad(float(r.get("pitch_deg", 18.0)))
	var dist: float = float(r.get("distance_m", 3.6))
	var pos: Vector3 = him_pt + (yaw_dir * cos(pitch) + Vector3.UP * sin(pitch)) * dist
	return {"ok": true, "pos": pos, "target": him_pt, "fov": float(r.get("fov_deg", 30.0)), "focus_point": him_pt, "dof": _dof(r.get("dof", {})),
		"detail": {"distance_m": dist, "pitch_deg": float(r.get("pitch_deg", 18.0))}}


func _his_point(ctx: Dictionary, height_frac: float) -> Vector3:
	var him: AABB = ctx.him
	var c: Vector3 = him.get_center()
	return Vector3(c.x, him.position.y + him.size.y * height_frac, c.z)


# ------------------------------------------------------------------ evaluation
func _size() -> Vector2:
	var s: Array = cfg.get("size", [1500, 1000])
	return Vector2(float(s[0]), float(s[1]))


static func _look(pos: Vector3, target: Vector3) -> Basis:
	var d: Vector3 = target - pos
	var up: Vector3 = Vector3.UP if absf(d.normalized().y) < 0.995 else Vector3.BACK
	return Basis.looking_at(d, up)


## Pixel position of a world point for a perspective camera with a vertical fov (Camera3D KEEP_HEIGHT). z > 0 in front.
static func _project(p: Vector3, pos: Vector3, basis: Basis, fov_deg: float, size: Vector2) -> Vector3:
	var v: Vector3 = basis.transposed() * (p - pos)
	var depth: float = -v.z
	if depth <= 0.0001:
		return Vector3(0.0, 0.0, -1.0)
	var t: float = tan(deg_to_rad(fov_deg) * 0.5)
	var aspect: float = size.x / size.y
	var nx: float = v.x / (depth * t * aspect)
	var ny: float = v.y / (depth * t)
	return Vector3((nx * 0.5 + 0.5) * size.x, (0.5 - ny * 0.5) * size.y, depth)


func _his_rect(ctx: Dictionary, pos: Vector3, basis: Basis, fov: float, size: Vector2) -> Rect2:
	var mn: Vector2 = Vector2(INF, INF)
	var mx: Vector2 = -mn
	for w: Vector3 in ctx.him_verts as PackedVector3Array:
		var q: Vector3 = _project(w, pos, basis, fov, size)
		if q.z <= 0.0:
			continue
		mn = mn.min(Vector2(q.x, q.y))
		mx = mx.max(Vector2(q.x, q.y))
	if mn.x == INF:
		return Rect2()
	return Rect2(mn, mx - mn)


func _his_fraction(ctx: Dictionary, pos: Vector3, basis: Basis, fov: float, size: Vector2) -> float:
	return _his_rect(ctx, pos, basis, fov, size).size.y / size.y


static func _aabb_rect(box: AABB, pos: Vector3, basis: Basis, fov: float, size: Vector2) -> Rect2:
	var mn: Vector2 = Vector2(INF, INF)
	var mx: Vector2 = -mn
	for i: int in 8:
		var q: Vector3 = _project(box.get_endpoint(i), pos, basis, fov, size)
		if q.z <= 0.0:
			return Rect2(Vector2(-1e6, -1e6), Vector2(2e6, 2e6))
		mn = mn.min(Vector2(q.x, q.y))
		mx = mx.max(Vector2(q.x, q.y))
	return Rect2(mn, mx - mn)


static func _aabb_in_frame(box: AABB, pos: Vector3, basis: Basis, fov: float, size: Vector2, margin: float) -> bool:
	var rr: Rect2 = _aabb_rect(box, pos, basis, fov, size)
	var inner: Rect2 = Rect2(size * margin, size * (1.0 - 2.0 * margin))
	return inner.encloses(rr)


static func _segment_hit(list: Array[Dictionary], a: Vector3, b: Vector3) -> String:
	for o: Dictionary in list:
		var box: AABB = o.aabb
		if box.grow(0.02).intersects_segment(a, b) == null and not box.has_point(a):
			continue
		var inv: Transform3D = o.inv
		var hit: Dictionary = (o.tri as TriangleMesh).intersect_segment(inv * a, inv * b)
		if not hit.is_empty():
			return str(o.kind)
	return ""


## Camera placement + occlusion + framing evidence, written into cand.
func _evaluate(ctx: Dictionary, cand: Dictionary) -> void:
	var pos: Vector3 = cand.pos
	var basis: Basis = cand.basis if cand.has("basis") else _look(pos, cand.target)
	cand["basis"] = basis
	var size: Vector2 = _size()
	var fov: float = float(cand.fov)
	var ocfg: Dictionary = cfg.get("occlusion", {})
	# camera placement: above the terrain, not inside the landmark or any placed mesh
	var half: float = float(ctx.half)
	var why: String = ""
	var clearance: float = float(ocfg.get("camera_clearance_m", 0.3))
	if absf(pos.x) <= half + 0.05 and absf(pos.z) <= half + 0.05:
		var g: float = float((ctx.tile_node as Node3D).call("terrain_height", pos.x, pos.z))
		if pos.y < g + clearance:
			why = "camera_below_terrain"
	if why == "":
		# inside or under a mesh (a roof, a canopy, an overhang): a vertical segment up from the camera hits it
		var up_end: Vector3 = pos + Vector3(0.0, 60.0, 0.0)
		for o: Dictionary in (ctx.occluders as Array[Dictionary]) + (ctx.soft as Array[Dictionary]):
			var kind: String = str(o.kind)
			if kind == "ground" or kind == "skirt":
				continue
			var one: Array[Dictionary] = [o]
			if _segment_hit(one, pos, up_end) != "":
				why = "camera_under_" + kind
				break
	cand["placement"] = why if why != "" else "ok"
	if not bool(ctx.has_him):
		cand["visible"] = why == ""
		cand["visible_fraction"] = 1.0 if why == "" else 0.0
		cand["his_frame_fraction"] = 0.0
		if why != "":
			cand["reason"] = why
		return
	# occlusion: segments from the camera to points on him
	var him: AABB = ctx.him
	var right: Vector3 = basis.x
	var half_w: float = minf(him.size.x, him.size.z) * 0.5
	var hc: Vector3 = him.get_center()
	var samples: Array = ocfg.get("samples", [[0.0, 0.88], [0.0, 0.62], [0.0, 0.38]])
	var clear: int = 0
	var blocked_by: Array[String] = []
	var soft_by: Array[String] = []
	var head_blocked: bool = false
	var chest_blocked: bool = false
	for s: Variant in samples:
		var sa: Array = s
		var p: Vector3 = Vector3(hc.x, him.position.y + him.size.y * float(sa[1]), hc.z) + right * half_w * float(sa[0])
		var hit: String = _segment_hit(ctx.occluders, pos, p)
		if hit == "":
			clear += 1
		else:
			blocked_by.append(hit)
			if float(sa[0]) == 0.0 and float(sa[1]) >= 0.8:
				head_blocked = true
			elif float(sa[0]) == 0.0 and float(sa[1]) >= 0.5:
				chest_blocked = true
		var soft_hit: String = _segment_hit(ctx.soft, pos, p)
		if soft_hit != "":
			soft_by.append(soft_hit)
	var vis: float = float(clear) / float(maxi(1, samples.size()))
	cand["visible_fraction"] = vis
	cand["blocked_by"] = blocked_by
	cand["soft_blockers"] = soft_by
	var visible: bool = why == "" and vis >= float(ocfg.get("min_visible", 0.6)) and not (head_blocked and chest_blocked)
	cand["visible"] = visible
	if not visible:
		cand["reason"] = why if why != "" else "occluded_by_" + ",".join(blocked_by)
	# framing evidence
	var rect: Rect2 = _his_rect(ctx, pos, basis, fov, size)
	cand["his_rect_px"] = [snappedf(rect.position.x, 0.1), snappedf(rect.position.y, 0.1), snappedf(rect.size.x, 0.1), snappedf(rect.size.y, 0.1)]
	cand["his_frame_fraction"] = snappedf(rect.size.y / size.y, 0.0001)
	cand["his_in_frame"] = Rect2(Vector2.ZERO, size).encloses(rect)
	if bool(ctx.has_landmark):
		var lq: Vector3 = _project(ctx.landmark_point as Vector3, pos, basis, fov, size)
		cand["landmark_point_in_frame"] = lq.z > 0.0 and Rect2(Vector2.ZERO, size).has_point(Vector2(lq.x, lq.y))
		var lrect: Rect2 = _aabb_rect(ctx.landmark as AABB, pos, basis, fov, size)
		var vis_area: float = lrect.intersection(Rect2(Vector2.ZERO, size)).get_area()
		cand["landmark_visible_share"] = snappedf(vis_area / maxf(1.0, lrect.get_area()), 0.001)


# ------------------------------------------------------------------ render
func _render(plan: Dictionary, id: String, save_dir: String, opts: Dictionary) -> Dictionary:
	var t_start: int = Time.get_ticks_usec()
	var ctx: Dictionary = plan.ctx
	var shot: Dictionary = plan.shot
	var look: RefCounted = ctx.look
	var size_v: Vector2 = _size()
	var size: Vector2i = Vector2i(int(size_v.x), int(size_v.y))
	var main_vp: Viewport = stage.get_viewport()
	var lay: Dictionary = cfg.get("layers", {})
	var main_bit: int = 1 << int(lay.get("main_sun_bit", 16))
	var pc_bit: int = 1 << int(lay.get("postcard_sun_bit", 17))
	var pos: Vector3 = shot.pos
	var basis: Basis = shot.basis
	var forward: Vector3 = -basis.z
	var bounds: AABB = ctx.bounds
	# viewport + camera (shares the stage world); a viewport made by prepare_viewport() is used when there is one
	var prepared: bool = _vp != null and is_instance_valid(_vp)
	if not prepared:
		prepare_viewport()
	var vp: SubViewport = _vp
	var cam: Camera3D = _cam
	_vp = null
	_cam = null
	cam.fov = float(shot.fov)
	cam.near = float(cfg.get("near", 0.05))
	cam.far = float(cfg.get("far_plane", 400.0))
	cam.cull_mask = ALL_LAYERS & ~main_bit
	cam.global_transform = Transform3D(basis, pos)
	cam.make_current()
	# DOF: focus on the rule's focus point
	var focus: float = maxf(0.2, ((shot.focus_point as Vector3) - pos).dot(forward))
	var main_attr: CameraAttributesPractical = stage.get("camera_attributes") as CameraAttributesPractical
	var attr: CameraAttributesPractical = main_attr.duplicate() as CameraAttributesPractical if main_attr != null else CameraAttributesPractical.new()
	var dof: Dictionary = shot.dof
	attr.dof_blur_far_enabled = bool(dof.get("far_enabled", true))
	attr.dof_blur_far_distance = focus + float(dof.get("far_offset", 2.0))
	attr.dof_blur_far_transition = float(dof.get("far_transition", 4.0))
	attr.dof_blur_near_enabled = bool(dof.get("near_enabled", true))
	attr.dof_blur_near_distance = maxf(0.05, focus - float(dof.get("near_offset", 1.0)))
	attr.dof_blur_near_transition = float(dof.get("near_transition", 1.0))
	attr.dof_blur_amount = float(dof.get("amount", 0.12))
	cam.attributes = attr
	# environment: the look's depth fog rule re-based on this camera (fog follows the tile-centre distance, as in the look)
	var fog_focus: float = maxf(0.5, (bounds.get_center() - pos).dot(forward))
	var world_env: WorldEnvironment = stage.get("world_env") as WorldEnvironment
	var env_src: Environment = world_env.environment if world_env != null else null
	var env_rep: Dictionary = {}
	if env_src != null:
		var env: Environment = env_src.duplicate() as Environment
		var fog: Dictionary = ((look.get("cfg") as Dictionary).get("atmos", {}) as Dictionary).get("fog", {})
		if env.fog_enabled and env.fog_mode == Environment.FOG_MODE_DEPTH:
			env.fog_depth_begin = maxf(0.0, fog_focus + float(fog.get("depth_begin_offset", 0.0)))
			env.fog_depth_end = maxf(env.fog_depth_begin + 0.1, fog_focus + float(fog.get("depth_end_offset", 40.0)))
		cam.environment = env
		env_rep = {"fog_enabled": env.fog_enabled, "fog_depth_begin": env.fog_depth_begin, "fog_depth_end": env.fog_depth_end}
	# the sun copy: the look's shadow range rule, measured from this camera
	var sun: DirectionalLight3D = ctx.sun
	var sun_copy: DirectionalLight3D = sun.duplicate() as DirectionalLight3D
	sun_copy.name = "LshuPostcardSun"
	var s_cfg: Dictionary = (look.get("cfg") as Dictionary).get("sun", {})
	var cam_dist: float = (bounds.get_center() - pos).length()
	var tile_radius: float = bounds.size.length() * 0.5
	sun_copy.directional_shadow_max_distance = cam_dist + tile_radius + float(s_cfg.get("shadow_extra_distance", 20.0))
	var split_1: Variant = s_cfg.get("shadow_split_1", "auto")
	if str(split_1) == "auto":
		sun_copy.directional_shadow_split_1 = clampf((cam_dist + tile_radius) / sun_copy.directional_shadow_max_distance, 0.05, 0.95)
	sun_copy.layers = pc_bit
	sun.get_parent().add_child(sun_copy)
	sun_copy.global_transform = sun.global_transform
	var main_cam: Camera3D = ctx.main_cam
	var saved_sun_layers: int = sun.layers
	var main_had_pc_bit: bool = (main_cam.cull_mask & pc_bit) != 0
	sun.layers = main_bit
	main_cam.cull_mask = main_cam.cull_mask & ~pc_bit
	var setup_ms: float = float(Time.get_ticks_usec() - t_start) / 1000.0
	# one render
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var t_wait: int = Time.get_ticks_usec()
	var wait: Dictionary = await _wait_post_draw(float(cfg.get("timeout_s", 2.0)))
	var wait_ms: float = float(Time.get_ticks_usec() - t_wait) / 1000.0
	var drawn: bool = bool(wait.drawn)
	var t_read: int = Time.get_ticks_usec()
	var image: Image = null
	var main_image: Image = null
	if drawn:
		image = vp.get_texture().get_image()
		if bool(opts.get("capture_main", false)):
			main_image = main_vp.get_texture().get_image()
	var read_ms: float = float(Time.get_ticks_usec() - t_read) / 1000.0
	# restore the stage before anything else can draw
	if is_instance_valid(sun):
		sun.layers = saved_sun_layers
	if is_instance_valid(main_cam) and main_had_pc_bit:
		main_cam.cull_mask = main_cam.cull_mask | pc_bit
	sun_copy.queue_free()
	vp.queue_free()
	var report: Dictionary = {
		"schema": "lshu.postcard_render.v1", "id": id, "tile": _tile_id(), "light": str(stage.get("light_name")),
		"rule": plan.rule, "requested": plan.requested, "fallback": plan.fallback, "tried": plan.tried,
		"camera": {"position": _arr3(pos), "target": _arr3(shot.target), "fov_deg": float(shot.fov), "forward": _arr3(forward),
			"focus_distance": focus, "dof": dof, "detail": shot.get("detail", {})},
		"his_frame_fraction": shot.get("his_frame_fraction", 0.0), "his_rect_px": shot.get("his_rect_px", []), "his_in_frame": shot.get("his_in_frame", false),
		"visible_fraction": shot.get("visible_fraction", 0.0), "blocked_by": shot.get("blocked_by", []), "soft_blockers": shot.get("soft_blockers", []),
		"landmark_source": ctx.get("landmark_source", ""), "landmark_point_in_frame": shot.get("landmark_point_in_frame", false),
		"landmark_visible_share": shot.get("landmark_visible_share", 0.0), "pose": ctx.get("pose", ""),
		"environment": env_rep, "sun_copy": {"shadow_max_distance": sun_copy.directional_shadow_max_distance, "split_1": sun_copy.directional_shadow_split_1},
		"size": [size.x, size.y], "timed_out": not drawn, "viewport_prepared_before": prepared,
		"timing_ms": {"setup": setup_ms, "wait": wait_ms, "read": read_ms, "process_frames_waited": int(wait.frames)},
	}
	if not drawn:
		timeouts += 1
		if not pending_renders.has(id):
			pending_renders.append(id)
		render_timed_out.emit(id)
		return {"ok": false, "id": id, "path": "", "timed_out": true, "rule": plan.rule, "requested": plan.requested, "fallback": plan.fallback, "error": "timeout", "report": report}
	var path: String = image_path(save_dir, id)
	var t_save: int = Time.get_ticks_usec()
	var err: int = await _save_jpg(image, path, float(cfg.get("jpg_quality", 0.9)))
	report["timing_ms"]["save_thread"] = float(Time.get_ticks_usec() - t_save) / 1000.0
	report["timing_ms"]["total"] = float(Time.get_ticks_usec() - t_start) / 1000.0
	report["image_size"] = [image.get_width(), image.get_height()]
	report["path"] = path
	var out: Dictionary = {"ok": err == OK, "id": id, "path": path if err == OK else "", "timed_out": false, "rule": plan.rule, "requested": plan.requested,
		"fallback": plan.fallback, "error": "" if err == OK else "save_failed:%d" % err, "report": report}
	if main_image != null:
		out["main_image"] = main_image
	if err != OK:
		push_error("LSHU postcard save failed (%d): %s" % [err, path])
		return out
	pending_renders.erase(id)
	renders += 1
	postcard_rendered.emit(id, path)
	return out


## Creates the postcard SubViewport + Camera3D ahead of the render (UPDATE_DISABLED). Optional: render_postcard makes
## one when there is none. Creating or resizing a viewport makes Godot draw a couple of frames even when the main loop
## is not drawing (measured: also with the window minimized), so a viewport made inside the render usually gets its
## frame anyway; one made ahead waits for a normal frame, which is how the harness exercises the timeout. The render
## frees the viewport afterwards either way (no GPU memory is held between postcards).
func prepare_viewport() -> void:
	if _vp != null and is_instance_valid(_vp):
		return
	var main_vp: Viewport = stage.get_viewport()
	var size_v: Vector2 = _size()
	var vp: SubViewport = SubViewport.new()
	vp.name = "LshuPostcardViewport"
	vp.size = Vector2i(int(size_v.x), int(size_v.y))
	vp.own_world_3d = false
	vp.world_3d = main_vp.find_world_3d()
	vp.transparent_bg = false
	vp.gui_disable_input = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.msaa_3d = main_vp.msaa_3d
	vp.screen_space_aa = main_vp.screen_space_aa
	vp.use_taa = main_vp.use_taa
	vp.use_debanding = main_vp.use_debanding
	vp.positional_shadow_atlas_size = main_vp.positional_shadow_atlas_size
	vp.positional_shadow_atlas_16_bits = main_vp.positional_shadow_atlas_16_bits
	for q: int in 4:
		vp.set_positional_shadow_atlas_quadrant_subdiv(q, main_vp.get_positional_shadow_atlas_quadrant_subdiv(q))
	vp.mesh_lod_threshold = main_vp.mesh_lod_threshold
	vp.anisotropic_filtering_level = main_vp.anisotropic_filtering_level
	add_child(vp)
	var cam: Camera3D = Camera3D.new()
	cam.name = "LshuPostcardCamera"
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	vp.add_child(cam)
	cam.make_current()
	_vp = vp
	_cam = cam


## Waits for the next frame_post_draw, or timeout_s of wall time (the process loop keeps running while macOS is not
## drawing the window). {drawn, frames}.
func _wait_post_draw(timeout_s: float) -> Dictionary:
	var flag: Array[bool] = [false]
	var cb: Callable = func() -> void:
		flag[0] = true
	RenderingServer.frame_post_draw.connect(cb, CONNECT_ONE_SHOT)
	var t0: int = Time.get_ticks_msec()
	var frames: int = 0
	var limit: int = int(timeout_s * 1000.0)
	while not flag[0] and Time.get_ticks_msec() - t0 < limit and is_inside_tree():
		await get_tree().process_frame
		frames += 1
	if RenderingServer.frame_post_draw.is_connected(cb):
		RenderingServer.frame_post_draw.disconnect(cb)
	return {"drawn": flag[0], "frames": frames}


## JPG on a worker thread (tmp file, then rename over the final name). Awaitable; returns an Error code.
func _save_jpg(image: Image, path: String, quality: float) -> int:
	var dir_err: int = DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if dir_err != OK and not DirAccess.dir_exists_absolute(path.get_base_dir()):
		return dir_err
	var tmp: String = path + ".tmp"
	var holder: Array[int] = [FAILED]
	var task: int = WorkerThreadPool.add_task(_encode.bind(image, tmp, quality, holder), false, "lshu_postcard_jpg")
	while not WorkerThreadPool.is_task_completed(task) and is_inside_tree():
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if holder[0] != OK:
		DirAccess.remove_absolute(tmp)
		return holder[0]
	var ren: int = DirAccess.rename_absolute(tmp, path)
	if ren != OK:
		DirAccess.remove_absolute(path)
		ren = DirAccess.rename_absolute(tmp, path)
	return ren


static func _encode(image: Image, tmp: String, quality: float, holder: Array[int]) -> void:
	if image.get_format() != Image.FORMAT_RGB8:
		image.convert(Image.FORMAT_RGB8)
	holder[0] = image.save_jpg(tmp, quality)
