extends Node3D
## 《山河旅人》第四幕「L叔在哪儿」· scene root (scenes/traveler/lshu_main.tscn).
## One floating tile from the pool (data/traveler/lshu/pool.json), the real L叔, one global look
## (data/traveler/lshu/look.json). Everything is a global rule; the only per-tile input is the baked tile data.
##
## Args (after --):
##   --tile=<pool id>                        default: the pool's home tile
##   --light=<morning|day|sunset|night>      default: the tile's baked light
##   --capture=<png>   warm up 120 frames, time 180 frames, save PNG + JSON (lshu.capture.v1), quit
##   --park=<slot>     shrink + park the window at a distinct screen slot (parallel renders never occlude)
##   --motion-freeze   hold all motion at look motion.freeze_time_s
##   --light-blend=<a>,<b>,<t>               continuous light between two presets (overrides --light)
##   --night-lamp=off                        no night lamp (decision 4), e.g. for before / after evidence
##   --lshu-dev                              dev keys (below); with the director also its event lines
##   --lshu-director=<on|off>                force the director on / off (default: see below)
## Director (P1 loop, scripts/traveler/lshu/lshu_director.gd, node "Director" of lshu_main.tscn): runs when this scene is
## the main scene and none of --tile / --light / --light-blend / --capture is given (or director_mode = "on", set by a
## harness before add_child); then the loop clock picks the tile and the light, and the director's own flags apply
## (--lshu-clock-scale=N, --lshu-save-dir=PATH, --lshu-now=UNIX, --lshu-fps-cap=off; tools/traveler/lshu/README.md).
## Otherwise the Director node is removed and this is the P0 single-tile stage, unchanged.
## Dev keys, only with --lshu-dev: F1 next light, F2 freeze / unfreeze motion, F3 / F4 next / previous pool tile
## (with the director: F1 cycles a light override and back to the clock, F3 / F4 preview a pool tile until the next
## switch). L is the travel book (UI, director only).
## Public API for the P1 director and QA: load_tile(id, budget_ms), stage_tile(id, budget_ms) + commit_staged() (build
## hidden, swap later), set_light(name), set_light_blend(a, b, t), set_light_state(clock r.light), set_fire_level(level,
## shape), add_report(key, value), signal tile_ready(id); night_lamp (lshu_night_lamp.gd) is the current tile's lamp
## (set_hold / set_present for the director).
## Swap frame (repair_r2, verify_r2 item 1): stage_tile() also plans the swap for the staged tile while it is hidden
## (_plan: his placement, the seat fit on a worker thread, the camera rule on a planning camera, the night lamp), so
## commit_staged() only re-places him, re-runs the cheap bounds / camera / finish, applies the plan (checked to be
## exactly what the swap frame would compute, else computed there as before), binds and shows the tile.
## show_staged_under_cover() lets the director draw the staged tile once under its cover before the swap.
## QA: work_log + take_frame_work() (per-frame work for the day run), commit_parts / stage_parts, plan_check.

signal tile_ready(id: String)
signal prewarm_done

const LOOK_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_look.gd")
const ASSEMBLER_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_tile_assembler.gd")
const CHARACTER_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_character.gd")
const CAMERA: GDScript = preload("res://scripts/traveler/lshu/lshu_camera.gd")
const SURFACE_DETAIL: GDScript = preload("res://scripts/traveler/lshu/lshu_surface_detail.gd")
const NIGHT_LAMP_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_night_lamp.gd")
## Args and quitting: scripts/traveler/traveler_launch.gd (since 2026-09-27 the title opens this act in the title's own window;
## then the args are the title's and quitting / a data error goes back to the title instead of ending the process)
const Launch: GDScript = preload("res://scripts/traveler/traveler_launch.gd")
const BACKDROP_SHADER: Shader = preload("res://shaders/traveler/lshu/lshu_backdrop.gdshader")
const FLOOR_SHADER: Shader = preload("res://shaders/traveler/lshu/lshu_floor.gdshader")
const POOL_PATH: String = "res://data/traveler/lshu/pool.json"
const LIGHTS: Array[String] = ["morning", "day", "sunset", "night"]
## The shadow-catcher floor lives on its own render layer: unshadowed lights (fill, fires, lamps) must not see it.
const FLOOR_LAYER: int = 1 << 19
const SWITCH_BUDGET_MS: float = 6.0

var tile_id: String = ""
var light_name: String = ""
var capture_path: String = ""
var park_slot: int = -1
var motion_frozen: bool = false
var anim_t: float = 0.0

var look: RefCounted
var pool: Dictionary = {}
var tile_ids: Array[String] = []
var world: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var environment: Environment
var world_env: WorldEnvironment
var camera_attributes: CameraAttributesPractical
var sky_material: ShaderMaterial
var floor_node: MeshInstance3D
var floor_material: ShaderMaterial
var character: Node3D
var tile: Node3D
var loading: bool = false
var render_scope: Dictionary = {}
var report_extra: Dictionary = {}
var swap_ms: float = 0.0
var prewarmed: bool = false
var prewarm_ms: float = 0.0
var notes: Array[String] = []
var light_blend_arg: Array[String] = []
var night_lamp_enabled: bool = true
var night_lamp: Node3D
## "auto" | "on" | "off" (see the header). Harnesses set it, and extra_args, before add_child.
var director_mode: String = "auto"
## Extra user args (a harness hosting the scene); read after the launch args (traveler_launch.gd user_args()).
var extra_args: PackedStringArray = PackedStringArray()
var directed: bool = false
var dev_keys: bool = false
var director: Node
var staged: Node3D
var staged_id: String = ""
## verify_r2 item 1: what the swap frame will need for the staged tile, worked out while it is still hidden (_plan):
## where he stands, the seat fit, the camera the fit gives and the night lamp placed from them. Empty = none.
var staged_plan: Dictionary = {}
## A second camera (never current, same parent and viewport as camera) that the plan fits for the staged tile.
var plan_camera: Camera3D
## QA timing (day run): per-step ms of the last commit (the swap frame) and of the last staging; work_log = true (set
## by a harness) also records every piece of stage / switch work as [label, ms] for take_frame_work(), so a harness can
## put each frame's interval next to the work done in it.
var commit_parts: Dictionary = {}
var stage_parts: Dictionary = {}
var work_log: bool = false
var frame_work: Array = []
## QA (off in the product): every swap that uses a plan also works the fit and the lamp out the old way, on the swap
## frame, and records whether they are exactly the planned ones (plan_checks, one LSHU_PLAN_CHECK line each).
var plan_check: bool = false
var plan_checks: Array = []
var _plan_task: int = -1

## Launch args (the command line, or the title's args when the title opened this act) plus a hosting harness's extra_args.
func user_args() -> PackedStringArray:
	var out: PackedStringArray = Launch.call("user_args")
	out.append_array(extra_args)
	return out

func _ready() -> void:
	# 从开场进来时：返回 + 提示 + 载入卡（2026-09-27）。帧率归导演管（前台 30、后台 10），这一层不动；
	# 载入卡等导演掀开开场遮罩（shown）再撤，返回药丸的 3 秒也从那时算（夜测 LSHU-11）
	var act_overlay: Node = preload("res://scripts/traveler/act_exit_button.gd").attach(self, "lshu")
	if act_overlay != null:
		act_overlay.set("manage_fps", false)
	var single_tile: bool = false
	for arg: String in user_args():
		if arg.begins_with("--tile=") or arg.begins_with("--light=") or arg.begins_with("--light-blend=") or arg.begins_with("--capture="):
			single_tile = true
		elif arg == "--lshu-director=on" or arg == "--lshu-director=off":
			director_mode = arg.trim_prefix("--lshu-director=")
		elif arg == "--lshu-dev":
			dev_keys = true
	# the main scene, or the act the title opened in its own window (traveler_host.gd: a child of the root beside the title)
	directed = director_mode == "on" or (director_mode == "auto" and not single_tile and (get_tree().current_scene == self or bool(Launch.call("is_hosted_root", self))))
	director = get_node_or_null("Director")
	if not directed and director != null:
		remove_child(director)
		director.free()
		director = null
	directed = directed and director != null
	if directed:   # 环境声（方案 §3.8）；无界面 / 测试 / 驱动脚本下什么都不建
		load("res://scripts/audio/ambience/lshu_where_ambience.gd").call("attach", self, director)
	if not directed:
		# P0 stage: frame timing without vsync or a frame cap (the director sets its own scene-level cap instead)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	for arg: String in user_args():
		if arg.begins_with("--tile="):
			tile_id = arg.trim_prefix("--tile=")
		elif arg.begins_with("--light="):
			light_name = arg.trim_prefix("--light=")
		elif arg.begins_with("--capture="):
			capture_path = arg.trim_prefix("--capture=")
		elif arg.begins_with("--park="):
			park_slot = int(arg.trim_prefix("--park="))
		elif arg == "--motion-freeze":
			motion_frozen = true
		elif arg.begins_with("--light-blend="):
			for part: String in arg.trim_prefix("--light-blend=").split(","):
				light_blend_arg.append(part)
		elif arg == "--night-lamp=off":
			night_lamp_enabled = false
	# A capture harness grabs the camera right after instantiation: create it before any await.
	camera = Camera3D.new()
	camera.name = "TileCamera"
	add_child(camera)
	camera.make_current()
	if park_slot >= 0:
		_park(park_slot)
	look = LOOK_SCRIPT.new()
	if not look.call("load_look") or not _load_pool():
		Launch.call("finish", get_tree(), 1)
		return
	var boot_light: Dictionary = {}
	if directed:
		var boot: Dictionary = director.call("boot", self)
		if not bool(boot.get("ok", false)):
			push_error("LSHU director boot failed: " + str(boot.get("error", "")))
			Launch.call("finish", get_tree(), 1)
			return
		tile_id = str(boot.get("tile", ""))
		boot_light = boot.get("light", {})
		light_name = str(boot_light.get("preset_a", "day"))
	if tile_id.is_empty():
		tile_id = str(pool.get("home", tile_ids[0] if not tile_ids.is_empty() else ""))
	if not tile_ids.has(tile_id):
		push_error("LSHU tile not in pool.json: " + tile_id)
		Launch.call("finish", get_tree(), 1)
		return
	if light_name.is_empty():
		light_name = str(_pool_entry(tile_id).get("light", "day"))
	if not look.call("set_light", light_name):
		Launch.call("finish", get_tree(), 1)
		return
	if light_blend_arg.size() == 3:
		if not look.call("set_light_blend", light_blend_arg[0], light_blend_arg[1], float(light_blend_arg[2])):
			Launch.call("finish", get_tree(), 1)
			return
		light_name = str(look.get("light_name"))
	if directed:
		var bb: String = str(boot_light.get("preset_b", light_name))
		var bt: float = float(boot_light.get("blend", 0.0))
		if bb != light_name and bt > 0.0 and look.call("set_light_blend", light_name, bb, bt):
			light_name = str(look.get("light_name"))
		director.call("opening", look.get("backdrop_display"))
	if motion_frozen:
		anim_t = float(look.call("cfgv", "motion", "freeze_time_s", 2.5))
	_build_stage()
	render_scope = look.call("apply_render_scope", get_viewport())
	look.call("prewarm_roles")
	character = CHARACTER_SCRIPT.new() as Node3D
	world.add_child(character)
	character.call("setup", look)
	var ok: bool = await load_tile(tile_id, 0.0)
	if not ok:
		Launch.call("finish", get_tree(), 1)
		return
	print("LSHU_READY ", JSON.stringify({"tile": tile_id, "light": light_name, "pose": (character.get("active") as Node3D).get("pose"), "instances": (tile.get("instance_nodes") as Array).size(), "camera": tile.get("camera_fit"), "build_timings_ms": tile.get("timings")}))
	if not capture_path.is_empty():
		await capture(capture_path)
		Launch.call("finish", get_tree(), 0)
		return
	if directed:
		if act_overlay != null:
			director.connect("shown", func() -> void:
				act_overlay.call("mark_ready")
				# 明信片 / 旅行本开着时，底部那行操作提示不出来
				var ui: Node = director.get("ui")
				if ui != null and ui.has_signal("busy_changed"):
					ui.connect("busy_changed", Callable(act_overlay, "set_busy")), CONNECT_ONE_SHOT)
		director.call("start")
	elif act_overlay != null:
		act_overlay.call("mark_ready")
	await _prewarm()

## Live window: build every pose rig once and start threaded loads of every pool tile's scenes, so later tile
## switches only assemble (fix #6). Not run for captures.
func _prewarm() -> void:
	var t0: int = Time.get_ticks_usec()
	var paths: Array[String] = ASSEMBLER_SCRIPT.call("prefetch", tile_ids)
	for p: String in NIGHT_LAMP_SCRIPT.call("prefetch"):
		if not paths.has(p):
			paths.append(p)
	var poses: Array[String] = []
	var pose_map: Dictionary = (look.call("sec", "character") as Dictionary).get("pose_map", {})
	for p: Variant in pose_map.values():
		if not poses.has(str(p)):
			poses.append(str(p))
	for pose: String in poses:
		await character.call("rig_for", pose)
		await get_tree().process_frame
	while not ASSEMBLER_SCRIPT.call("collect", paths):
		await get_tree().process_frame
	prewarm_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	prewarmed = true
	prewarm_done.emit()
	print("LSHU_PREWARMED ", JSON.stringify({"poses": poses, "scenes": paths.size(), "ms": prewarm_ms}))

func _exit_tree() -> void:
	if _plan_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_plan_task)
		_plan_task = -1
	if look != null:
		look.call("restore_render_scope")
	# opened from the title in the same window: collect the threaded tile reads still in flight (no load token may outlive
	# the scene; the process does not end here) and drop the tile caches, so the title / a match get the memory back
	if bool(Launch.call("hosting")):
		ASSEMBLER_SCRIPT.call("release_all")

func _load_pool() -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(POOL_PATH))
	if not parsed is Dictionary:
		push_error("LSHU pool.json missing or invalid: " + POOL_PATH)
		return false
	pool = parsed
	var blocked: Array = pool.get("blocklist", [])
	for t: Variant in pool.get("tiles", []):
		var id: String = str((t as Dictionary).get("id", ""))
		if not id.is_empty() and not blocked.has(id):
			tile_ids.append(id)
	return not tile_ids.is_empty()

func _pool_entry(id: String) -> Dictionary:
	for t: Variant in pool.get("tiles", []):
		if str((t as Dictionary).get("id", "")) == id:
			return t
	return {}

# ------------------------------------------------------------------ stage (persistent across tiles)
func _build_stage() -> void:
	world = Node3D.new()
	world.name = "LshuWorld"
	add_child(world)
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky: Sky = Sky.new()
	sky_material = ShaderMaterial.new()
	sky_material.shader = BACKDROP_SHADER
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	world_env = WorldEnvironment.new()
	world_env.name = "Environment"
	world_env.environment = environment
	add_child(world_env)
	camera_attributes = CameraAttributesPractical.new()
	camera.attributes = camera_attributes
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	world.add_child(sun)
	fill = DirectionalLight3D.new()
	fill.name = "Fill"
	world.add_child(fill)
	fill.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER
	floor_node = MeshInstance3D.new()
	floor_node.name = "StageFloor"
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2.ONE * 400.0
	floor_node.mesh = plane
	floor_material = ShaderMaterial.new()
	floor_material.shader = FLOOR_SHADER
	floor_node.material_override = floor_material
	floor_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	floor_node.layers = FLOOR_LAYER
	world.add_child(floor_node)

# ------------------------------------------------------------------ tiles
## Loads a pool tile: read off-thread, assemble hidden in time slices of budget_ms (0 = no slicing), then swap
## in one frame. Returns false on a data error. Awaitable.
func load_tile(id: String, budget_ms: float) -> bool:
	if loading:
		push_error("LSHU load_tile while another tile is loading: " + id)
		return false
	if not tile_ids.has(id):
		push_error("LSHU tile not in pool.json: " + id)
		return false
	loading = true
	if not await _stage(id, budget_ms):
		loading = false
		return false
	if budget_ms > 0.0:
		await get_tree().process_frame
	await _commit()
	loading = false
	tile_ready.emit(id)
	return true

## Director: builds a pool tile hidden beside the one on screen (read off-thread, assembled in slices of budget_ms per
## frame) without showing it; commit_staged() swaps it in later. A new call replaces a staged tile. Awaitable.
func stage_tile(id: String, budget_ms: float) -> bool:
	if loading:
		push_error("LSHU stage_tile while another tile is loading: " + id)
		return false
	if not tile_ids.has(id):
		push_error("LSHU tile not in pool.json: " + id)
		return false
	loading = true
	var ok: bool = await _stage(id, budget_ms)
	loading = false
	return ok

## QA: one piece of stage / switch work done in the current frame (only while work_log is on).
func mark_work(label: String, ms: float) -> void:
	if work_log and frame_work.size() < 256:
		frame_work.append([label, snappedf(ms, 0.001)])

## QA: the work marked since the last call (a harness calls it once per frame, on process_frame).
func take_frame_work() -> Array:
	var out: Array = frame_work
	frame_work = []
	return out

## Director: swaps the staged tile in (one frame). false when nothing is staged. Awaitable.
func commit_staged() -> bool:
	if loading or staged == null:
		return false
	loading = true
	var id: String = staged_id
	await _commit()
	loading = false
	tile_ready.emit(id)
	return true

## Director, right after a full cover went up and right before commit_staged(): the staged tile is drawn once under the
## cover (both tiles are, for that one frame), so its first draw - pipelines compiled for its surfaces, the first
## shadow passes over it - is not on the same frame as the swap. false when nothing is staged.
func show_staged_under_cover() -> bool:
	if loading or staged == null or not is_instance_valid(staged):
		return false
	staged.visible = true
	return true

func discard_staged() -> void:
	if staged != null and is_instance_valid(staged):
		staged.queue_free()
	staged = null
	staged_id = ""
	staged_plan = {}

func _stage(id: String, budget_ms: float) -> bool:
	var t0: int = Time.get_ticks_usec()
	var f0: int = Engine.get_process_frames()
	discard_staged()
	var next: Node3D = ASSEMBLER_SCRIPT.new() as Node3D
	next.visible = false
	world.add_child(next)
	next.set("slice_hook", Callable(self, "mark_work"))
	next.call("prepare", id)
	var ok: bool = await next.call("build", look, motion_frozen, budget_ms)
	if not ok:
		next.queue_free()
		return false
	# the pose rig is built once per pose; a first use may take a few frames (parked off-stage)
	var tr: int = Time.get_ticks_usec()
	await character.call("rig_for", character.call("pose_for", next.get("tile")))
	mark_work("rig_for", float(Time.get_ticks_usec() - tr) / 1000.0)
	var f_plan: int = Engine.get_process_frames()
	var tp: int = Time.get_ticks_usec()
	var plan: Dictionary = await _plan(next, budget_ms)
	staged = next
	staged_id = id
	staged_plan = plan
	stage_parts = {"tile": id, "wall_ms": float(Time.get_ticks_usec() - t0) / 1000.0, "frames": Engine.get_process_frames() - f0,
		"build_slices_ms": next.get("slices_ms"), "build_timings_ms": next.get("timings"),
		"plan_wall_ms": float(Time.get_ticks_usec() - tp) / 1000.0, "plan_frames": Engine.get_process_frames() - f_plan,
		"plan_ms": plan.get("ms", {})}
	return true

## verify_r2 item 1: the swap frame's heavy work for the staged tile, done here while it is hidden, in pieces: a piece
## that would take a frame past budget_ms (counted from the start of this frame's staging work) waits for the next
## frame, and the seat fit, the heavy one, runs on a worker thread:
##   P1  he is put on the staged tile's spot (character.place_built) just long enough to copy what the seat fit
##       reads (fit_inputs), then put back (save_placement / restore_placement: same frame, nothing is drawn between)
##       - the fit itself (fit_compute, pure data) runs on a worker thread
##   P2  placed again with the fit applied: tile bounds, the camera rule on plan_camera, finish(), and the lamp rule's
##       view of him (subject_of); put back
##   P3  the night lamp decided and built under the hidden tile from that subject and plan_camera
## The swap frame then re-places him (cheap and exactly the same result), applies the planned fit when he stands
## exactly where P1 saw him, re-runs the cheap bounds / camera / finish, and keeps the planned lamp when the subject,
## the camera and the lamp settings are exactly the ones planned; anything else is done there as before. budget_ms <= 0
## (captures): all in one go, same order. Returns {} when nothing could be planned.
func _plan(next: Node3D, budget_ms: float) -> Dictionary:
	var sliced: bool = budget_ms > 0.0
	var td: Dictionary = next.get("tile")
	var ms: Dictionary = {}
	if plan_camera == null:
		plan_camera = Camera3D.new()
		plan_camera.name = "PlanCamera"
		add_child(plan_camera)
		plan_camera.current = false
	# Every piece runs in code resumed on process_frame (the build's and these awaits), so the scene's _process - the
	# character's own tick, which re-poses a rig that is on screen - always follows a put-back before anything is drawn.
	var frame_t0: int = int(next.get("_frame_start_us"))
	frame_t0 = await _plan_slice(sliced, budget_ms, frame_t0, 1.0)
	# P1
	var t1: int = Time.get_ticks_usec()
	var saved: Dictionary = character.call("save_placement")
	var rig: Node3D = character.call("place_built", td)
	if rig == null:
		character.call("restore_placement", saved)
		return {}
	var xf_place: Transform3D = (rig.get("character") as Node3D).global_transform
	var seat_cfg: Dictionary = character.call("_seat_cfg")
	var inputs: Dictionary = character.call("fit_inputs", next)
	character.call("restore_placement", saved)
	ms["inputs"] = _plan_mark("plan:inputs", t1)
	var tf: int = Time.get_ticks_usec()
	var res: Dictionary = {}
	if sliced and inputs.has("grid_src"):
		var box: Dictionary = {}
		_plan_task = WorkerThreadPool.add_task(func() -> void: box["res"] = CHARACTER_SCRIPT.call("fit_compute", inputs), false, "lshu seat fit")
		while not WorkerThreadPool.is_task_completed(_plan_task):
			await get_tree().process_frame
			frame_t0 = Time.get_ticks_usec()
		WorkerThreadPool.wait_for_task_completion(_plan_task)
		_plan_task = -1
		res = box.get("res", {})
	else:
		res = CHARACTER_SCRIPT.call("fit_compute", inputs)
	ms["fit_wall"] = float(Time.get_ticks_usec() - tf) / 1000.0
	if res.has("out"):
		(res.out as Dictionary)["fit_ms"] = ms.fit_wall
		(res.out as Dictionary)["planned"] = true
	# P2
	frame_t0 = await _plan_slice(sliced, budget_ms, frame_t0, 1.0)
	var t2: int = Time.get_ticks_usec()
	saved = character.call("save_placement")
	rig = character.call("place_built", td)
	character.call("fit_apply", inputs, res)
	var posed: Mesh = character.call("bounds_geometry")
	next.call("compute_bounds", rig.get("character_body") as MeshInstance3D, posed)
	CAMERA.fit(plan_camera, next.get("tile_bounds"), look.call("sec", "camera"), rig.get("character") as Node3D)
	character.call("finish", plan_camera, next, Callable(next, "terrain_height"), true)
	var subject: Dictionary = NIGHT_LAMP_SCRIPT.call("subject_of", character)
	character.call("restore_placement", saved)
	ms["place"] = _plan_mark("plan:place", t2)
	# P3
	frame_t0 = await _plan_slice(sliced, budget_ms, frame_t0, 2.0)
	var t3: int = Time.get_ticks_usec()
	var lamp: Node3D = NIGHT_LAMP_SCRIPT.new() as Node3D
	next.add_child(lamp)
	lamp.call("setup", look, next, character, plan_camera, night_lamp_enabled, subject)
	ms["lamp"] = _plan_mark("plan:lamp", t3)
	return {"xf_place": xf_place, "seat_cfg": seat_cfg, "inputs": inputs, "fit": res, "subject": subject, "camera": _camera_state(plan_camera),
		"lamp": lamp, "lamp_cfg": (look.call("sec", "night_lamp") as Dictionary).duplicate(true), "lamp_enabled": night_lamp_enabled, "ms": ms}

## Waits for the next frame when this frame's staging work since frame_t0 plus the next piece (about next_ms) would pass
## budget_ms. Returns the start of the frame the next piece runs in.
func _plan_slice(sliced: bool, budget_ms: float, frame_t0: int, next_ms: float) -> int:
	if sliced and float(Time.get_ticks_usec() - frame_t0) / 1000.0 + next_ms > budget_ms:
		await get_tree().process_frame
		return Time.get_ticks_usec()
	return frame_t0

func _plan_mark(label: String, t0: int) -> float:
	var v: float = float(Time.get_ticks_usec() - t0) / 1000.0
	mark_work(label, v)
	return snappedf(v, 0.001)

## Everything of a camera the camera rule sets and the lamp rule reads (projection of points, frustum).
static func _camera_state(cam: Camera3D) -> Dictionary:
	return {"xf": cam.global_transform, "projection": cam.projection, "fov": cam.fov, "size": cam.size, "near": cam.near, "far": cam.far,
		"keep_aspect": cam.keep_aspect, "h_offset": cam.h_offset, "v_offset": cam.v_offset, "frustum_offset": cam.frustum_offset,
		"viewport": cam.get_viewport().get_visible_rect().size}

func _commit() -> void:
	var next: Node3D = staged
	var id: String = staged_id
	var plan: Dictionary = staged_plan
	staged = null
	staged_id = ""
	staged_plan = {}
	await _swap(next, plan)
	tile_id = id

## Director: how much the tile's camp fire still burns (1 = the approved look; see lshu_life.gd set_fire_level).
func set_fire_level(level: float, shape: Dictionary = {}) -> void:
	if tile == null:
		return
	var life: Node3D = tile.get("life")
	if life != null:
		life.call("set_fire_level", level, shape)

## The swap frame (plan: _plan() of this tile, {} = none): he is placed, the tile shown, the old one freed.
func _swap(next: Node3D, plan: Dictionary = {}) -> void:
	var t0: int = Time.get_ticks_usec()
	var parts: Dictionary = {}
	var tp: int = t0
	var rig: Node3D = await character.call("place", next.get("tile"))
	tp = _part(parts, "place", tp)
	# fix #1: seated feet on the ground (seat slide + height), before the bounds; planned when he stands where the plan saw him
	var fit_planned: bool = not plan.is_empty() and (rig.get("character") as Node3D).global_transform == (plan.xf_place as Transform3D) \
		and (character.call("_seat_cfg") as Dictionary) == (plan.seat_cfg as Dictionary)
	if fit_planned:
		var fit_check: Dictionary = _check_fit(next, plan) if plan_check else {}
		character.call("fit_apply", plan.inputs, plan.fit)
		if plan_check:
			parts["fit_check"] = fit_check
	else:
		var inputs: Dictionary = plan.get("inputs", {}) as Dictionary
		if inputs.has("holder") and is_instance_valid(inputs.holder):
			(inputs.holder as Node3D).scale = Vector3.ONE * float(inputs.base_scale)   # the plan scaled the seat: back first
		character.call("fit_support", next)
	parts["fit_planned"] = fit_planned
	tp = _part(parts, "fit", tp)
	var posed: Mesh = character.call("bounds_geometry")
	next.call("compute_bounds", rig.get("character_body") as MeshInstance3D, posed)
	tp = _part(parts, "bounds", tp)
	next.set("camera_fit", CAMERA.fit(camera, next.get("tile_bounds"), look.call("sec", "camera"), rig.get("character") as Node3D))
	tp = _part(parts, "camera", tp)
	character.call("finish", camera, next, Callable(next, "terrain_height"))
	tp = _part(parts, "finish", tp)
	# decision 4: the night lamp belongs to the tile (goes away with it), placed by the global rule; the planned one
	# when the swap frame sees exactly the subject, camera and settings it was planned with
	var planned_lamp: Node3D = plan.get("lamp") as Node3D if plan.get("lamp") is Node3D and is_instance_valid(plan.get("lamp")) else null
	var lamp_planned: bool = planned_lamp != null and (NIGHT_LAMP_SCRIPT.call("subject_of", character) as Dictionary) == (plan.subject as Dictionary) \
		and _camera_state(camera) == (plan.camera as Dictionary) and (look.call("sec", "night_lamp") as Dictionary) == (plan.lamp_cfg as Dictionary) \
		and night_lamp_enabled == bool(plan.lamp_enabled)
	if lamp_planned:
		if plan_check:
			parts["lamp_check"] = _check_lamp(next, planned_lamp)
		night_lamp = planned_lamp
	else:
		if planned_lamp != null:
			next.remove_child(planned_lamp)
			planned_lamp.free()
		night_lamp = NIGHT_LAMP_SCRIPT.new() as Node3D
		next.add_child(night_lamp)
		night_lamp.call("setup", look, next, character, camera, night_lamp_enabled)
	parts["lamp_planned"] = lamp_planned
	tp = _part(parts, "lamp", tp)
	next.call("bind")
	tp = _part(parts, "bind", tp)
	var old: Node3D = tile
	tile = next
	_apply_light()
	tp = _part(parts, "light", tp)
	tile.visible = true
	if old != null:
		old.visible = false
		old.queue_free()
	tp = _part(parts, "show", tp)
	_apply_motion(anim_t, 0.0)
	tp = _part(parts, "motion", tp)
	swap_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	parts["total"] = swap_ms
	commit_parts = parts
	if plan_check:
		var row: Dictionary = {"tile": next.get("tile_id"), "fit_planned": fit_planned, "lamp_planned": lamp_planned,
			"fit_check": parts.get("fit_check", {}), "lamp_check": parts.get("lamp_check", {})}
		plan_checks.append(row)
		print("LSHU_PLAN_CHECK ", JSON.stringify(row))
	character.call("refresh_after_place")

## plan_check: the seat fit worked out now, the swap-frame way (seat back at its own scale first), against the plan.
func _check_fit(next: Node3D, plan: Dictionary) -> Dictionary:
	var inputs: Dictionary = plan.inputs
	if not inputs.has("holder"):
		var now_inputs: Dictionary = character.call("fit_inputs", next)
		return {"seated": false, "equal": (CHARACTER_SCRIPT.call("fit_compute", now_inputs) as Dictionary).is_empty() == (plan.fit as Dictionary).is_empty()}
	var holder: Node3D = inputs.holder
	var planned_scale: Vector3 = holder.scale
	holder.scale = Vector3.ONE * float(inputs.base_scale)
	var ref: Dictionary = CHARACTER_SCRIPT.call("fit_compute", character.call("fit_inputs", next))
	holder.scale = planned_scale
	var pf: Dictionary = plan.fit
	var drop_keys: Array[String] = ["fit_ms", "seat_grid_ms", "planned", "ms"]
	var same_out: bool = _strip(ref.get("out", {}), drop_keys) == _strip(pf.get("out", {}), drop_keys)
	return {"seated": true, "equal": same_out and ref.get("delta") == pf.get("delta") and ref.get("scale") == pf.get("scale"),
		"delta_equal": ref.get("delta") == pf.get("delta"), "scale_equal": ref.get("scale") == pf.get("scale"), "report_equal": same_out}

## plan_check: the night lamp decided now, the swap-frame way (a throwaway node), against the planned one.
func _check_lamp(next: Node3D, planned: Node3D) -> Dictionary:
	var ref: Node3D = NIGHT_LAMP_SCRIPT.new() as Node3D
	next.add_child(ref)
	ref.call("setup", look, next, character, camera, night_lamp_enabled)
	var drop_keys: Array[String] = ["ms"]
	var a: Dictionary = _strip(ref.get("report"), drop_keys)
	var b: Dictionary = _strip(planned.get("report"), drop_keys)
	var out: Dictionary = {"equal": a == b and ref.get("light_point") == planned.get("light_point") and str(ref.get("mode")) == str(planned.get("mode")),
		"mode": str(planned.get("mode"))}
	next.remove_child(ref)
	ref.free()
	return out

static func _strip(d: Dictionary, keys: Array[String]) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in d.keys():
		if keys.has(str(k)):
			continue
		var v: Variant = d[k]
		out[k] = _strip(v as Dictionary, keys) if v is Dictionary else v
	return out

## QA: records the ms since t_prev under key (and in the work log as "commit:<key>"); returns now.
func _part(parts: Dictionary, key: String, t_prev: int) -> int:
	var now: int = Time.get_ticks_usec()
	var ms: float = float(now - t_prev) / 1000.0
	parts[key] = snappedf(ms, 0.001)
	mark_work("commit:" + key, ms)
	return now

## Switch the light preset (keys, P1 clock). Rebuilds the effective config and re-applies it.
func set_light(name_value: String) -> void:
	if not LIGHTS.has(name_value) or tile == null:
		return
	light_name = name_value
	look.call("set_light", light_name)
	_apply_light()

## Continuous light (P1): a blend of two presets, t in 0..1 (t = 0 / 1 is exactly set_light(a) / set_light(b)).
func set_light_blend(preset_a: String, preset_b: String, t: float) -> bool:
	if tile == null or not look.call("set_light_blend", preset_a, preset_b, t):
		return false
	light_name = str(look.get("light_name"))
	_apply_light()
	return true

## The loop clock's light output r.light = {preset_a, preset_b, blend, ...}. Re-applies only when it changed.
func set_light_state(light: Dictionary) -> bool:
	var a: String = str(light.get("preset_a", light_name))
	var b: String = str(light.get("preset_b", a))
	var t: float = float(light.get("blend", 0.0))
	if a.is_empty():
		return false
	var bl: Dictionary = look.get("blend")
	var same: bool = (a == b or t <= 0.0) and bl.is_empty() and a == light_name
	if not bl.is_empty():
		same = str(bl.a) == a and str(bl.b) == b and is_equal_approx(float(bl.t), clampf(t, 0.0, 1.0))
	if same:
		return true
	return set_light_blend(a, b if not b.is_empty() else a, t)

func _apply_light() -> void:
	look.call("apply", self, tile)
	SURFACE_DETAIL.on_light(look, sun, tile)
	var life: Node3D = tile.get("life")
	var keys: Array[Vector3] = []
	if life != null:
		life.call("on_light")
		keys = life.call("camp_fire_keys")
	if night_lamp != null and is_instance_valid(night_lamp):
		night_lamp.call("set_night_weight", float(look.call("weight", "night")))
		keys.append_array(night_lamp.call("key_points"))
	character.call("on_light", sun, keys)

# ------------------------------------------------------------------ motion
func _process(delta: float) -> void:
	if tile == null:
		return
	if not motion_frozen:
		anim_t += delta
	_apply_motion(anim_t, delta)

func _apply_motion(t: float, _delta: float) -> void:
	var materials: Dictionary = look.get("materials")
	for role: String in materials.keys():
		(materials[role] as ShaderMaterial).set_shader_parameter("anim_time", t)
	floor_material.set_shader_parameter("anim_time", t)
	character.call("tick", t, motion_frozen)
	tile.call("tick", t, motion_frozen)
	if night_lamp != null and is_instance_valid(night_lamp):
		night_lamp.call("tick", t)

## 手柄（act_exit_button.gd 先问这里；scripts/pad/pad_input.gd）：
##   A：没开界面时跟 L叔 打招呼；旅行本里 = 打开框着的明信片；明信片上 = 翻面
##   X：邮票（打开最新一张没看过的明信片，没有就开旅行本）   Y：开 / 合旅行本（= L）
##   B：先收明信片，再收旅行本（都没开时交回去：叫出「返回」）
##   十字键 / LB / RB：旅行本里在明信片缩略图之间挪框
var _pad_thumb: Control

func act_pad(a: String) -> bool:
	if not directed or director == null:
		return false
	var ui: Node = director.get("ui")
	if ui == null:
		return false
	var view: Control = ui.call("viewer_control")
	var book: Control = ui.call("book_control")
	var view_open: bool = bool(view.call("is_open"))
	var book_open: bool = bool(book.call("is_open"))
	ui.call("notify_activity")
	match a:
		"back":
			if view_open:
				view.call("close", "key")
				return true
			if book_open:
				ui.call("close_book")
				return true
			return false
		"accept":
			if view_open:
				if not bool(view.call("is_animating")):
					ui.call("flip_postcard")
				return true
			if book_open:
				var th: Control = _pad_book_thumb(book, "")
				if th != null:
					ui.call("open_postcard", th.get("record"), th.get_global_rect())
				return true
			director.call("pad_greet")
			return true
		"x":
			if not view_open:
				ui.call("_on_stamp_pressed")
			return true
		"y":
			if view_open:
				view.call("close", "key")
			else:
				ui.call("toggle_book")
			return true
		"up", "down", "left", "right", "lb", "rb":
			if book_open and not view_open:
				_pad_book_thumb(book, a)
			return true
	return false

## 旅行本里框着的缩略图；dir 非空时往那个方向挪一格（第一下框最新的那张），框到的滚到看得见
func _pad_book_thumb(book: Control, dir: String) -> Control:
	var thumbs: Array = book.call("thumbs")
	if thumbs.is_empty():
		_pad_thumb = null
		return null
	var cur: int = thumbs.find(_pad_thumb) if _pad_thumb != null and is_instance_valid(_pad_thumb) else -1
	if cur < 0:
		cur = 0
	elif dir != "":
		if dir == "lb" or dir == "rb":
			cur = clampi(cur + (1 if dir == "rb" else -1), 0, thumbs.size() - 1)
		else:
			var d: Vector2 = {"up": Vector2.UP, "down": Vector2.DOWN, "left": Vector2.LEFT, "right": Vector2.RIGHT}[dir]
			var pad_lib: Variant = load("res://scripts/pad/pad_input.gd")
			cur = int(pad_lib.nav_controls(thumbs, cur, d, 0))
	_pad_thumb = thumbs[cur] as Control
	var sc: ScrollContainer = book.call("scroll_container")
	if sc != null:
		sc.ensure_control_visible(_pad_thumb)
	return _pad_thumb

func act_pad_focus() -> Variant:
	if not directed or director == null or director.get("ui") == null:
		return null
	var ui: Node = director.get("ui")
	var book: Control = ui.call("book_control")
	if bool(book.call("is_open")) and not bool((ui.call("viewer_control") as Control).call("is_open")):
		return _pad_book_thumb(book, "")
	return null

## Dev keys, only with --lshu-dev (the P0 L / F / N / B keys moved here; L is the travel book now).
func _unhandled_key_input(event: InputEvent) -> void:
	var k: InputEventKey = event as InputEventKey
	if not dev_keys or k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_F2:
		motion_frozen = not motion_frozen
		print("LSHU_FREEZE ", motion_frozen)
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_F1 or k.keycode == KEY_F3 or k.keycode == KEY_F4:
		get_viewport().set_input_as_handled()
		if directed:
			director.call("dev_key", k.keycode)
		elif k.keycode == KEY_F1:
			set_light(LIGHTS[(LIGHTS.find(light_name) + 1) % LIGHTS.size()])
			print("LSHU_LIGHT ", light_name)
		elif not loading:
			var step: int = 1 if k.keycode == KEY_F3 else -1
			var next_id: String = tile_ids[(tile_ids.find(tile_id) + step + tile_ids.size()) % tile_ids.size()]
			await load_tile(next_id, SWITCH_BUDGET_MS)
			print("LSHU_TILE ", next_id)

## QA / harness hook: extra evidence written into the capture JSON under "extra".
func add_report(key: String, value: Variant) -> void:
	report_extra[key] = value

# ------------------------------------------------------------------ window parking / capture
func _park(slot: int) -> void:
	var wid: int = DisplayServer.MAIN_WINDOW_ID
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(wid))
	var size: Vector2i = Vector2i(400, 225)
	DisplayServer.window_set_size(size, wid)
	DisplayServer.window_set_position(usable.position + usable.size - Vector2i((slot % 4 + 1) * (size.x + 8), (slot / 4 + 1) * (size.y + 36)), wid)

func capture(output_path: String) -> void:
	for _i: int in 120:
		await RenderingServer.frame_post_draw
	var samples: Array[float] = []
	var previous: int = Time.get_ticks_usec()
	for _i: int in 180:
		await RenderingServer.frame_post_draw
		var now: int = Time.get_ticks_usec()
		samples.append(float(now - previous) / 1000.0)
		previous = now
	var global_draws: int = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var viewport_draws: int = get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var shadow_draws: int = get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var primitives: int = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var image: Image = get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var error: int = image.save_png(output_path)
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	var corner: Color = image.get_pixel(12, 12)
	var backdrop_display: Color = look.get("backdrop_display")
	var tile_data: Dictionary = tile.get("tile")
	var tile_ev: Dictionary = tile.call("evidence")
	var report: Dictionary = {
		"schema": "lshu.capture.v1", "tile": tile_id, "composition_id": tile_data.get("composition_id"), "name": tile_data.get("name"),
		"place": tile_data.get("place"), "kit": tile_data.get("kit"), "light": light_name, "look": "res://data/traveler/lshu/look.json",
		"image_size": [image.get_width(), image.get_height()], "viewport_size": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"capture_error": error, "draw_calls": global_draws, "viewport_draw_calls": viewport_draws, "shadow_draw_calls": shadow_draws, "rendered_primitives": primitives,
		"frame_ms": {"p50": sorted[89], "p95": sorted[170], "max": sorted[179], "samples": samples, "sample_count": 180, "warmup_frames": 120, "vsync_disabled": DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED, "engine_max_fps": Engine.max_fps},
		"motion_frozen": motion_frozen, "anim_t": anim_t,
		"camera": tile.get("camera_fit"), "camera_transform": str(camera.global_transform),
		"character": character.call("evidence", camera),
		"backdrop": {"target_srgb": [backdrop_display.r, backdrop_display.g, backdrop_display.b], "measured_corner_srgb": [corner.r, corner.g, corner.b], "error_max": maxf(absf(corner.r - backdrop_display.r), maxf(absf(corner.g - backdrop_display.g), absf(corner.b - backdrop_display.b)))},
		"roles": tile_ev.get("roles"), "proc_roles": tile_ev.get("proc_roles"), "instances": tile_ev.get("instances"), "fires": tile_ev.get("fires"), "lamps": tile_ev.get("lamps"), "rotors": tile_ev.get("rotors"),
		"modules": {"order": (look.get("modules") as Dictionary).get("order", []), "atmos": {"renderer": render_scope, "light": look.get("atmos_report")}, "edges": tile_ev.get("edges"), "surface_detail": tile_ev.get("surface_detail"), "scatter": tile_ev.get("scatter"), "life": tile_ev.get("life")},
		"build_timings_ms": tile_ev.get("build_timings_ms"), "swap_ms": swap_ms,
		"light_blend": look.get("blend_report"), "night_lamp": night_lamp.call("evidence") if night_lamp != null and is_instance_valid(night_lamp) else {},
		"extra": report_extra, "notes": notes, "config": look.get("cfg"),
	}
	var f: FileAccess = FileAccess.open(output_path.get_basename() + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify(report, " "))
	f.close()
	var proj: Dictionary = (report.character as Dictionary).get("projection", {})
	print("LSHU_CAPTURE ", JSON.stringify({"png": output_path, "error": error, "p50": sorted[89], "p95": sorted[170], "draw_calls": global_draws, "character_px": proj.get("height_px", 0.0), "backdrop_err": report.backdrop.error_max}))
	if error != OK:
		push_error("LSHU capture save failed: " + output_path)
