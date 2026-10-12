extends Node
## 第四幕「L叔在哪儿」· L叔's motion on a tile. One global rule set, nothing written for any tile:
##   arrive     fade in at the tile edge on the tile's baked arrival path, walk it (the act-2 walk clip) to his spot,
##              then settle into the kit pose (stand / sit / carry) with a 0.5 s pose blend
##   leave      stand up, turn, walk out along the same path, fade out at the edge
##   wander     optional: walk to the landmark stand point (the path's end), stand, walk back (skipped when blocked)
##   click      turn toward the camera (<= 45 deg) and bow (standing) or nod (seated / carrying), then resume
##   focus      double-click: the camera eases toward him, holds 8 s, returns
##   night      doze (slow head nod); tent_in walks him into the tent when the tile has one (role "shelter"),
##              otherwise he keeps dozing; night_end brings him back
## Every timing runs on the caller's clock t (seconds, any clock scale). The pose at t depends only on t and the
## scheduled actions, so the director can run it at 1x, 60x or scrub it (the harness does).
##
## The act-4 character module (lshu_character.gd) and its pose rigs are used as they are. The standing rig (act-2
## model with idle / walk / bow / turn_180) is the walker for every kit. Standing kit: walk -> idle is a bone blend
## on the same skeleton. Seated / carrying kits are other models, so their 0.5 s pose blend is a cross-fade between
## the standing rig and the kit rig (GeometryInstance3D.transparency, shadows off below half opacity).
## Walk: the root follows the route at a speed profile; the walk clip phase is distance / stance speed (measured from
## the clip's own planted foot), so the planted foot does not slide; the root height puts the planted sole on what is
## drawn under it (downward rays against the tile's static geometry).
## Routes: the baked arrival path from the edge, then an A* connector (AStarGrid2D over a height grid ray-cast from the
## tile's static meshes: water, steps higher than a stride, anything taller than a kerb off the path, trees) to the
## stand point (his spot; the seat front for the seated kit).
##
## Feet: the root follows the planted foot over the lowest ground, a two-bone leg IK lifts any foot that would sink,
## and a swing foot rises onto a step it is about to reach; what is under a foot comes from a height grid of the tile's
## ground parts (cast once per tile on a worker thread, deck gaps bridged), so stairs read as a ramp (no pops, but a sole
## can clip a tread by up to a riser). He slows down on stairs and steep ground.
## Fades are a dither (alpha hash) on copies of the rig's materials; the approved materials are back at full opacity.
##
## Director usage (all times on one clock):
##   var motion: Node = preload("res://scripts/traveler/lshu/lshu_actor_motion.gd").new()
##   add_child(motion); motion.setup(character, look)
##   during the scene prewarm: await motion.prepare()      # ~1 s once: clip / sole data, fade shaders drawn once
##   after each tile swap:      await motion.bind_tile(tile, camera, t, hidden)   # hidden: he is on the road;
##                              takes a few frames (worker thread), never more than a few ms of main thread per frame
##                              (route.main_slice_ms: the collision parts and, since repair_r2, the grid and the
##                              routes are planned in slices of it too)
##   while the next tile is staged (hidden): await motion.prewarm_tile(staged)   # optional: pulls the triangle lists
##                              bind_tile() will read, so the frames around the swap do not read them back
##   ARRIVE motion.arrive(t) · LEAVE motion.leave(t) · ROAD motion.hide_now(t) · catchup motion.settle_now(t)
##   wander_start motion.wander(t, t_end) · night_start motion.night_doze(t) · tent_in motion.tent_in(t)
##   night_end motion.night_end(t) · input motion.handle_input(event, t) (click on him: bow / nod and signal greeted;
##   double click: camera focus, only when dev_focus / --lshu-dev) · every frame motion.tick(t)
## character.tick() calls back into this node (character.motion_hook), so the order of the two ticks does not matter.
## Numbers: data/traveler/lshu/actor_motion.json. QA: tools/traveler/lshu/tests/actor_motion_harness.gd.

signal phase_changed(phase: String, t: float)
## A click was accepted: kind is "bow" or "nod". The director can take its photo here.
signal greeted(kind: String, t: float)

const CONFIG_PATH: String = "res://data/traveler/lshu/actor_motion.json"
const GROUND_INFO: GDScript = preload("res://scripts/traveler/lshu/lshu_ground_info.gd")
const PARK_OFFSET: Vector3 = Vector3(0.0, -1000.0, 0.0)
const RIM_FADE: StringName = &"rim_fade"   # lshu_character_rim.gdshader: the rig opacity on its additive rim pass
const MOVING_ANIMS: Array[String] = ["sway", "boat", "bob"]
const HARD: int = 1
const DILATED: int = 2
const PATH: int = 4
const NEAR: int = 8
const BRIDGE: int = 16


var cfg: Dictionary = {}
var character: Node3D
var look: RefCounted
var tile: Node3D
var camera: Camera3D
var tile_json: Dictionary = {}
var bound: bool = false

var kit_rig: Node3D
var walker: Node3D
var kit_pose: String = ""
var kit_is_walker: bool = false
var base_pos: Vector3 = Vector3.ZERO
var base_yaw: float = 0.0
var base_decal: Vector3 = Vector3.ZERO
var stand_pos: Vector3 = Vector3.ZERO
var stand_yaw: float = 0.0
var landmark_point: Vector3 = Vector3.ZERO

# walker clips (sampled from the Animation resources, never through the AnimationPlayer)
var w_skel: Skeleton3D
var w_bones: PackedInt32Array = PackedInt32Array()
var w_has_pos: PackedByteArray = PackedByteArray()
var w_clips: Dictionary = {}
var w_rest_pos: PackedVector3Array = PackedVector3Array()
var w_rest_rot: Array[Quaternion] = []
var w_rest_scale: PackedVector3Array = PackedVector3Array()
var clip_len: Dictionary = {}
var stance_u_s: float = 0.7
var stance_speed: float = 0.8
var ds_phase: float = 0.0
var idle_offset: float = 0.0
var _pa: PackedVector3Array = PackedVector3Array()
var _ra: Array[Quaternion] = []
var _pb: PackedVector3Array = PackedVector3Array()
var _rb: Array[Quaternion] = []

# walker soles (runtime root height) - subset of the sole vertices, CPU-skinned
var sole: Dictionary = {}

# collision, grid, routes
var colliders: Array = []
## What feet stand on: the tile's own ground parts (terrain surface, steps, decks, landmark structure), not rocks, props
## or the seat, so a foot passing beside a rock does not jump onto its edge.
var ground_colliders: Array = []
var _tm_cache: Dictionary = {}
var grid: Dictionary = {}
var astar: AStarGrid2D
var routes: Dictionary = {}
var plan_report: Dictionary = {}
var water_level: float = -INF

# timeline
var segs: Array[Dictionary] = []
var doze_on: float = INF
var doze_off: float = INF
var focus_seg: Dictionary = {}
## Double click anywhere pushes the camera in (focus()); dev only (--lshu-dev, set by the director)
var dev_focus: bool = false
var _t: float = 0.0
var _anim_t: float = 0.0
var _phase: String = ""
var _kit_dirty: bool = false
var _alpha: Dictionary = {}
var _faded: Dictionary = {}
var _fade_mats: Dictionary = {}
var _fade_ready: Dictionary = {}
var _drawn_ready: Dictionary = {}
var _shadow_orig: Dictionary = {}
var _geoms: Dictionary = {}
var last_frame: Dictionary = {}
## QA timing: work_hook(label, ms) (the scene's work log, set by the director) is told each main-thread piece of
## bind_tile() as it ends.
var work_hook: Callable = Callable()
var _slice_t0: int = 0
var _slice_main_us: int = 0

# ------------------------------------------------------------------ setup
func setup(character_node: Node3D, look_ref: RefCounted) -> void:
	name = "LshuActorMotion"
	character = character_node
	look = look_ref
	cfg = _load_cfg()
	if "motion_hook" in character:
		character.set("motion_hook", Callable(self, "_on_character_tick"))
	var ch: Dictionary = (look.get("cfg") as Dictionary).get("character", {}) if look != null else {}
	idle_offset = float(ch.get("idle_offset_s", 0.0))

## Builds the walker's clip and sole data once (about half a second, the first time only). Call it while the scene
## prewarms so the first bind_tile() does not pay for it. Awaitable.
func prepare() -> void:
	var rigs: Dictionary = character.get("rigs")
	if not rigs.has("standing"):
		await character.call("rig_for", "standing")
	_setup_walker(rigs["standing"] as Node3D)
	var todo: Array[Node3D] = []
	for r: Variant in rigs.values():
		_prewarm_fades(r as Node3D)
		todo.append(r as Node3D)
	await _prewarm_draw(todo)

## Draws the given rigs once with their fade materials, so the fade shaders and pipelines are built now and not on the
## frame a fade starts (measured 0.3-0.4 s the first time). The displayed rig stays in place at 0.998 opacity (a dither
## too fine to see for two frames); parked rigs are drawn shrunk inside the tile's plinth, where the ground hides
## them. Awaitable: two frames.
func _prewarm_draw(rigs_in: Array[Node3D]) -> void:
	var host: Node3D = tile if tile != null and is_instance_valid(tile) else character.get("tile_node") as Node3D
	var active: Node3D = character.get("active") as Node3D
	var saved: Array = []
	for rig: Node3D in rigs_in:
		var key: int = rig.get_instance_id()
		if _drawn_ready.has(key) or not is_instance_valid(rig):
			continue
		_drawn_ready[key] = true
		var ch: Node3D = rig.get("character")
		saved.append([rig, rig.position, ch.transform, _alpha.get(key, 1.0)])
		if rig == active and rig.position.y > PARK_OFFSET.y * 0.5:
			var a0: float = float(_alpha.get(key, 1.0))
			_set_alpha(rig, 0.998 if a0 >= 0.999 else a0)
		else:
			var y: float = -0.6
			if host != null and host.get("tile") is Dictionary:
				var yr: Array = ((host.get("tile") as Dictionary).get("tile", {}) as Dictionary).get("ground_y_range", [-0.5, 0.5])
				y = float(yr[0]) - 0.25
			rig.position = Vector3.ZERO
			ch.global_position = Vector3(0.0, y, 0.0)
			ch.scale = ch.scale * 0.1
			_set_alpha(rig, 0.5)
	if saved.is_empty():
		return
	for _i: int in 2:
		await RenderingServer.frame_post_draw
	for rec: Array in saved:
		var rig2: Node3D = rec[0]
		if not is_instance_valid(rig2):
			continue
		(rig2.get("character") as Node3D).transform = rec[2]
		rig2.position = rec[1]
		_set_alpha(rig2, float(rec[3]))

## Makes the fade copies of a rig's materials ahead of time: a material in a new mode is a new shader, and compiling it
## on the frame a fade starts would stall that frame (measured: 0.3-0.4 s for the seated body).
func _prewarm_fades(rig: Node3D) -> void:
	var key: int = rig.get_instance_id()
	if _fade_ready.has(key):
		return
	_fade_ready[key] = true
	for g: Variant in _rig_geoms(rig):
		var mi: MeshInstance3D = g as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if mi.material_override != null:
			_fade_copy(mi.material_override, key)
		else:
			for sfc: int in mi.mesh.get_surface_count():
				_fade_copy(mi.get_active_material(sfc), key)

static func _defaults() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH)) if FileAccess.file_exists(CONFIG_PATH) else null
	return parsed if parsed is Dictionary else {}

func _load_cfg() -> Dictionary:
	var d: Dictionary = _defaults()
	for sec: String in ["walk", "turn", "route", "click", "focus", "doze", "tent", "wander"]:
		if not d.get(sec) is Dictionary:
			d[sec] = {}
	return d

func _c(sec: String, key: String, fallback: Variant) -> Variant:
	var s: Variant = cfg.get(sec)
	if s is Dictionary and (s as Dictionary).has(key):
		return (s as Dictionary)[key]
	return fallback

func _cf(sec: String, key: String, fallback: float) -> float:
	return float(_c(sec, key, fallback))

# ------------------------------------------------------------------ per tile
## After each tile swap (after the scene's character.finish()), in the same frame. hidden = he is not on the tile
## yet (arrive() follows). Plans the routes once per tile. Returns the plan report. Awaitable (only awaits when the
## standing rig has not been built yet).
func bind_tile(tile_node: Node3D, cam: Camera3D, t: float, hidden: bool = false) -> Dictionary:
	var t_start: int = Time.get_ticks_usec()
	bound = false
	plan_report = {}
	tile = tile_node
	camera = cam
	focus_seg = {}
	kit_rig = character.get("active") as Node3D
	tile_json = character.get("tile_data")
	for r: Variant in (character.get("rigs") as Dictionary).values():
		_set_alpha(r as Node3D, 1.0)
	if hidden and kit_rig != null:
		_set_alpha(kit_rig, 0.0)
	var rigs: Dictionary = character.get("rigs")
	if not rigs.has("standing"):
		await character.call("rig_for", "standing")
		if kit_rig != character.get("active"):
			return {"ok": false, "error": "tile changed while the standing rig was built"}
	_setup_walker(rigs["standing"] as Node3D)
	_prewarm_fades(walker)
	_prewarm_fades(kit_rig)
	var first_draw: Array[Node3D] = []
	for r2: Node3D in [walker, kit_rig]:
		if not _drawn_ready.has(r2.get_instance_id()):
			first_draw.append(r2)
	if not first_draw.is_empty():
		await _prewarm_draw(first_draw)
		if kit_rig != character.get("active"):
			return {"ok": false, "error": "tile changed while the fade shaders were built"}
	kit_pose = str(kit_rig.get("pose"))
	kit_is_walker = kit_rig == walker
	if not kit_is_walker:
		walker.position = PARK_OFFSET
	var kc: Node3D = kit_rig.get("character")
	base_pos = kc.global_position
	base_yaw = kc.rotation.y
	var dec: Decal = kit_rig.get("contact_decal") as Decal
	base_decal = dec.global_position if dec != null else base_pos
	var wl: Variant = (tile_json.get("water", {}) as Dictionary).get("level") if tile_json.get("water") is Dictionary else null
	water_level = float(wl) if wl != null else -INF
	# collision parts: triangle lists gathered on the main thread in small slices; the trees and the height grid
	# (every static solid, and the ground parts alone) are built on a worker thread; the routes are planned when it
	# is done (a few frames later). No step costs the main thread more than a few milliseconds.
	var job: Dictionary = _grid_job()
	_work("bind_start", t_start)
	await _collect_colliders(job)
	if not is_same(character.get("tile_data"), tile_json) or character.get("active") != kit_rig:
		return {"ok": false, "error": "tile changed while the collision parts were gathered"}
	var t_rays: int = Time.get_ticks_usec()
	var task: int = WorkerThreadPool.add_task(_grid_rays.bind(job), true, "lshu actor grid")
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	colliders = job.colliders
	ground_colliders = job.ground
	for k2: Variant in (job.built as Dictionary).keys():
		_tm_cache[k2] = (job.built as Dictionary)[k2]
	plan_report["colliders"] = colliders.size()
	plan_report["grid_rays_thread_ms"] = float(job.get("ms", 0.0))
	plan_report["grid_rays_wall_ms"] = float(Time.get_ticks_usec() - t_rays) / 1000.0
	if not is_same(character.get("tile_data"), tile_json) or character.get("active") != kit_rig:
		return {"ok": false, "error": "tile changed while the grid was cast"}
	# the grid, the stand point and the routes: main thread, in slices of route.main_slice_ms (repair_r2: one piece was
	# 14-28 ms on the frames right after the swap)
	var t_main: int = Time.get_ticks_usec()
	_slice_t0 = t_main
	_slice_main_us = 0
	await _build_grid(job)
	await _plan_yield()
	_find_stand()
	await _plan_yield()
	await _plan_routes()
	_slice_main_us += Time.get_ticks_usec() - _slice_t0
	_work("route_plan", _slice_t0)
	plan_report["main_thread_plan_ms"] = float(_slice_main_us) / 1000.0
	plan_report["plan_wall_ms"] = float(Time.get_ticks_usec() - t_main) / 1000.0
	if not is_same(character.get("tile_data"), tile_json) or character.get("active") != kit_rig:
		return {"ok": false, "error": "tile changed while the routes were planned"}
	t_main = Time.get_ticks_usec()
	segs.clear()
	doze_on = INF
	doze_off = INF
	_kit_dirty = false
	segs.append(_hold(-INF, "hidden" if hidden else "kit"))
	_t = t
	bound = true
	plan_report["bind_ms"] = float(Time.get_ticks_usec() - t_start) / 1000.0
	_apply(_eval(t))
	_work("bind_end", t_main)
	return plan_report

## Route planning time slice: when this frame's piece has used route.main_slice_ms, the rest waits for the next frame
## (the planning itself is unchanged, only spread over frames; bind_tile() is not bound meanwhile). Awaitable.
func _plan_yield() -> void:
	if Time.get_ticks_usec() - _slice_t0 > int(_cf("route", "main_slice_ms", 4.0) * 1000.0):
		_slice_main_us += Time.get_ticks_usec() - _slice_t0
		_work("route_plan", _slice_t0)
		await get_tree().process_frame
		_slice_t0 = Time.get_ticks_usec()

## Director, while the next tile is staged (built hidden, before its swap): the tile's own big meshes bind_tile() reads
## its collision parts from (the merged shadow casters and the ground parts) whose triangles the assembler has not
## already made (faces_for) get Mesh.get_faces() once, one mesh per frame. Godot keeps the triangle mesh it builds for
## get_faces() in the mesh, so bind_tile()'s own call returns the same triangles at once instead of reading them back
## from the GPU on the frames around the swap. Usually nothing is left to do. Awaitable.
func prewarm_tile(tile_node: Node3D) -> void:
	if tile_node == null or not is_instance_valid(tile_node):
		return
	var meshes: Array[MeshInstance3D] = []
	for n: Variant in tile_node.get("shadow_nodes"):
		meshes.append(n as MeshInstance3D)
	var proc_nodes: Dictionary = tile_node.get("proc_nodes")
	for role: String in _c("route", "ground_roles", ["ground", "steps", "structure", "cliff", "water_side"]):
		var pn: MeshInstance3D = proc_nodes.get(role) as MeshInstance3D
		if pn != null:
			meshes.append(pn)
	while tile_node.has_method("faces_ready") and not bool(tile_node.call("faces_ready")):
		await get_tree().process_frame
		if not is_instance_valid(tile_node):
			return
	for mi: MeshInstance3D in meshes:
		if not is_instance_valid(tile_node) or not is_instance_valid(mi) or mi.mesh == null:
			return
		if tile_node.has_method("faces_for") and tile_node.call("faces_for", mi) is PackedVector3Array:
			continue
		await get_tree().process_frame
		if not is_instance_valid(tile_node) or not is_instance_valid(mi) or mi.mesh == null:
			return
		var t0: int = Time.get_ticks_usec()
		mi.mesh.get_faces()
		_work("prewarm_faces", t0)

## QA timing: one main-thread piece of work that started at t0_us (see work_hook).
func _work(label: String, t0_us: int) -> void:
	if work_hook.is_valid():
		work_hook.call(label, float(Time.get_ticks_usec() - t0_us) / 1000.0)

func _hold(t0: float, mode: String) -> Dictionary:
	return {"kind": "hold", "t0": t0, "t1": INF, "mode": mode, "pos": stand_pos, "yaw": stand_yaw}

# ------------------------------------------------------------------ walker clips
func _setup_walker(rig: Node3D) -> void:
	if walker == rig and w_skel != null:
		return
	walker = rig
	var model: Node3D = rig.get("character_model")
	var skels: Array[Node] = model.find_children("*", "Skeleton3D", true, false)
	w_skel = skels[0] as Skeleton3D
	var player: AnimationPlayer = rig.get("player")
	w_bones = PackedInt32Array()
	w_has_pos = PackedByteArray()
	w_clips = {}
	var slot_of: Dictionary = {}
	for clip: String in ["idle", "walk", "bow", "turn_180"]:
		if not player.has_animation(clip):
			continue
		var a: Animation = player.get_animation(clip)
		var tracks: Array[Vector3i] = []
		for ti: int in a.get_track_count():
			var ty: int = a.track_get_type(ti)
			if ty != Animation.TYPE_POSITION_3D and ty != Animation.TYPE_ROTATION_3D:
				continue
			var bone: int = w_skel.find_bone(str(a.track_get_path(ti).get_concatenated_subnames()))
			if bone < 0:
				continue
			if not slot_of.has(bone):
				slot_of[bone] = w_bones.size()
				w_bones.append(bone)
				w_has_pos.append(0)
			var slot: int = int(slot_of[bone])
			if ty == Animation.TYPE_POSITION_3D:
				w_has_pos[slot] = 1
			tracks.append(Vector3i(ti, slot, ty))
		w_clips[clip] = {"anim": a, "tracks": tracks}
		clip_len[clip] = a.length
	w_rest_pos = PackedVector3Array()
	w_rest_rot = []
	w_rest_scale = PackedVector3Array()
	for b: int in w_bones:
		var rest: Transform3D = w_skel.get_bone_rest(b)
		w_rest_pos.append(rest.origin)
		w_rest_rot.append(rest.basis.get_rotation_quaternion())
		w_rest_scale.append(rest.basis.get_scale())
	_pa = w_rest_pos.duplicate()
	_ra = w_rest_rot.duplicate()
	_pb = w_rest_pos.duplicate()
	_rb = w_rest_rot.duplicate()
	_measure_stance()
	_setup_soles()
	_pose_walker("idle", _idle_t(), "idle", 0.0, 0.0)

func _sample(clip: String, time: float, pos: PackedVector3Array, rot: Array[Quaternion]) -> void:
	for i: int in w_bones.size():
		pos[i] = w_rest_pos[i]
		rot[i] = w_rest_rot[i]
	var rec: Dictionary = w_clips.get(clip, {})
	if rec.is_empty():
		return
	var a: Animation = rec.anim
	var tt: float = fposmod(time, a.length) if a.loop_mode != Animation.LOOP_NONE else clampf(time, 0.0, a.length)
	for v: Vector3i in rec.tracks as Array[Vector3i]:
		if v.z == Animation.TYPE_POSITION_3D:
			pos[v.y] = a.position_track_interpolate(v.x, tt)
		else:
			rot[v.y] = a.rotation_track_interpolate(v.x, tt)

## Poses the walker skeleton: clip a at ta mixed toward clip b at tb by w.
func _pose_walker(a: String, ta: float, b: String, tb: float, w: float) -> void:
	_sample(a, ta, _pa, _ra)
	if w > 0.0001:
		_sample(b, tb, _pb, _rb)
	for i: int in w_bones.size():
		var p: Vector3 = _pa[i]
		var q: Quaternion = _ra[i]
		if w > 0.0001:
			p = p.lerp(_pb[i], w)
			q = q.slerp(_rb[i], w)
		# every driven bone gets its whole pose each time (the leg IK writes positions and scales too), so the pose
		# never depends on what was drawn before
		w_skel.set_bone_pose_position(w_bones[i], p)
		w_skel.set_bone_pose_rotation(w_bones[i], q)
		w_skel.set_bone_pose_scale(w_bones[i], w_rest_scale[i])

## Stance speed of the walk clip: the planted toe's backward speed (skeleton units per clip second), and the phase
## where both feet are planted (walk starts / ends there).
func _measure_stance() -> void:
	if not w_clips.has("walk"):
		return
	var lt: int = _bone_suffix(w_skel, "LeftToeBase")
	var rt: int = _bone_suffix(w_skel, "RightToeBase")
	var n: int = 96
	var length: float = float(clip_len["walk"])
	var ly: PackedFloat32Array = PackedFloat32Array()
	var lz: PackedFloat32Array = PackedFloat32Array()
	var ry: PackedFloat32Array = PackedFloat32Array()
	var rz: PackedFloat32Array = PackedFloat32Array()
	for i: int in n:
		_pose_walker("walk", length * float(i) / float(n), "walk", 0.0, 0.0)
		w_skel.force_update_all_bone_transforms()
		var l: Vector3 = w_skel.get_bone_global_pose(lt).origin
		var r: Vector3 = w_skel.get_bone_global_pose(rt).origin
		ly.append(l.y)
		lz.append(l.z)
		ry.append(r.y)
		rz.append(r.z)
	var lmin: float = INF
	var rmin: float = INF
	for i2: int in n:
		lmin = minf(lmin, ly[i2])
		rmin = minf(rmin, ry[i2])
	var band: float = 0.006
	var speeds: Array[float] = []
	var dt: float = length / float(n)
	var best_ds: int = -1
	var best_gap: float = -1.0
	for i3: int in n:
		var i_prev: int = (i3 - 1 + n) % n
		var i_next: int = (i3 + 1) % n
		var l_st: bool = ly[i3] < lmin + band and ly[i_prev] < lmin + band and ly[i_next] < lmin + band
		var r_st: bool = ry[i3] < rmin + band and ry[i_prev] < rmin + band and ry[i_next] < rmin + band
		if l_st:
			speeds.append(-(lz[i_next] - lz[i_prev]) / (2.0 * dt))
		if r_st:
			speeds.append(-(rz[i_next] - rz[i_prev]) / (2.0 * dt))
		if ly[i3] < lmin + band and ry[i3] < rmin + band and absf(lz[i3] - rz[i3]) > best_gap:
			best_gap = absf(lz[i3] - rz[i3])
			best_ds = i3
	speeds.sort()
	if not speeds.is_empty():
		stance_u_s = speeds[speeds.size() / 2]

	ds_phase = length * float(maxi(best_ds, 0)) / float(n)
	stance_speed = stance_u_s * w_skel.global_basis.get_scale().x

static func _bone_suffix(skel: Skeleton3D, suffix: String) -> int:
	var low: String = suffix.to_lower()
	for i: int in skel.get_bone_count():
		if str(skel.get_bone_name(i)).to_lower().ends_with(low):
			return i
	return -1

# ------------------------------------------------------------------ soles (runtime planted-foot height)
func _setup_soles() -> void:
	sole = {}
	var body: MeshInstance3D = walker.get("character_body") as MeshInstance3D
	if body == null or body.mesh == null or body.skin == null:
		return
	var skin: Skin = body.skin
	var bind_bone: PackedInt32Array = PackedInt32Array()
	var bind_side: PackedInt32Array = PackedInt32Array()
	for i: int in skin.get_bind_count():
		var b: int = skin.get_bind_bone(i)
		if b < 0:
			b = w_skel.find_bone(str(skin.get_bind_name(i)))
		bind_bone.append(b)
		var bn: String = str(w_skel.get_bone_name(b)) if b >= 0 else ""
		var foot: bool = bn.ends_with("Foot") or bn.contains("Toe")
		bind_side.append((0 if bn.contains("Left") else 1) if foot else -1)
	var verts: PackedVector3Array = PackedVector3Array()
	var vb: PackedInt32Array = PackedInt32Array()
	var vw: PackedFloat32Array = PackedFloat32Array()
	var vside: PackedInt32Array = PackedInt32Array()
	var per: int = 4
	for s: int in body.mesh.get_surface_count():
		var arrays: Array = body.mesh.surface_get_arrays(s)
		var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if arrays[Mesh.ARRAY_BONES] == null or arrays[Mesh.ARRAY_WEIGHTS] == null or sv.is_empty():
			continue
		var sb: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var sw: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		per = sb.size() / sv.size()
		for vi: int in sv.size():
			var best_w: float = -1.0
			var best_b: int = -1
			for j: int in per:
				if sw[vi * per + j] > best_w:
					best_w = sw[vi * per + j]
					best_b = sb[vi * per + j]
			if best_b < 0 or best_b >= bind_side.size() or bind_side[best_b] < 0:
				continue
			verts.append(sv[vi])
			vside.append(bind_side[best_b])
			for j2: int in per:
				vb.append(sb[vi * per + j2])
				vw.append(sw[vi * per + j2])
	if verts.is_empty():
		return
	sole = {"skin": skin, "bind_bone": bind_bone, "verts": verts, "bones": vb, "weights": vw, "per": per, "side": vside, "body": body}
	# runtime subset: every vertex that is (nearly) the lowest of its foot at some moment of the walk, turn, bow or
	# idle (heel at strike, toe at push-off, the flat sole standing), sampled over the clips
	# candidates: the lower part of each shoe in the idle pose (the sole and its rim)
	_pose_walker("idle", 0.0, "idle", 0.0, 0.0)
	w_skel.force_update_all_bone_transforms()
	var all_pts: PackedVector3Array = _skin_points(sole, PackedInt32Array())
	var low0: Array[float] = [INF, INF]
	for i0: int in all_pts.size():
		low0[vside[i0]] = minf(low0[vside[i0]], all_pts[i0].y)
	var cand: PackedInt32Array = PackedInt32Array()
	for i1: int in all_pts.size():
		if all_pts[i1].y <= low0[vside[i1]] + 0.04:
			cand.append(i1)
	var chosen: Dictionary = {}
	var band: float = 0.004
	for clip: String in ["walk", "turn_180", "bow", "idle"]:
		if not clip_len.has(clip):
			continue
		var steps: int = 16 if clip == "walk" else 4
		for k: int in steps:
			_pose_walker(clip, float(clip_len[clip]) * float(k) / float(steps), clip, 0.0, 0.0)
			w_skel.force_update_all_bone_transforms()
			var pts: PackedVector3Array = _skin_points(sole, cand)
			var lowest: Array[float] = [INF, INF]
			for i2: int in pts.size():
				lowest[vside[cand[i2]]] = minf(lowest[vside[cand[i2]]], pts[i2].y)
			for i3: int in pts.size():
				if pts[i3].y <= lowest[vside[cand[i3]]] + band:
					chosen[cand[i3]] = true
	# one point per 1 cm cell of the idle pose (the shoe's own frame), lowest kept
	var cells: Dictionary = {}
	for key: Variant in chosen.keys():
		var vi: int = int(key)
		var q: Vector3 = all_pts[vi]
		var cell: Vector3i = Vector3i(floori(q.x / 0.01), floori(q.z / 0.01), vside[vi])
		if not cells.has(cell) or all_pts[int(cells[cell])].y > q.y:
			cells[cell] = vi
	var subset: PackedInt32Array = PackedInt32Array()
	for v: Variant in cells.values():
		subset.append(int(v))
	subset.sort()
	sole["subset"] = subset
	# runtime probes: six points under each shoe (heel, toe, the two sides at mid-foot, the ball and the arch), taken
	# from the sole points in the idle pose (model frame: +z forward, x sideways)
	var probes: PackedInt32Array = PackedInt32Array()
	for side2: int in 2:
		var ids: Array[int] = []
		for vi2: int in subset:
			if vside[vi2] == side2:
				ids.append(vi2)
		if ids.is_empty():
			continue
		var zmin: float = INF
		var zmax: float = -INF
		for vi3: int in ids:
			zmin = minf(zmin, all_pts[vi3].z)
			zmax = maxf(zmax, all_pts[vi3].z)
		var picks: Array[int] = []
		var best: Array = [[INF, -1], [-INF, -1], [INF, -1], [-INF, -1], [INF, -1], [INF, -1]]
		for vi4: int in ids:
			var q4: Vector3 = all_pts[vi4]
			var u: float = (q4.z - zmin) / maxf(zmax - zmin, 0.0001)
			if q4.z < float(best[0][0]):
				best[0] = [q4.z, vi4]
			if q4.z > float(best[1][0]):
				best[1] = [q4.z, vi4]
			if absf(u - 0.5) < 0.15:
				if q4.x < float(best[2][0]):
					best[2] = [q4.x, vi4]
				if q4.x > float(best[3][0]):
					best[3] = [q4.x, vi4]
			if absf(u - 0.75) < float(best[4][0]):
				best[4] = [absf(u - 0.75), vi4]
			if absf(u - 0.25) < float(best[5][0]):
				best[5] = [absf(u - 0.25), vi4]
		for b4: Array in best:
			if int(b4[1]) >= 0 and not picks.has(int(b4[1])):
				picks.append(int(b4[1]))
		for pk: int in picks:
			probes.append(pk)
	sole["probes"] = probes

## CPU skinning of sole vertices (all when idx is empty) in the skeleton's space (no global transform).
func _skin_points(s: Dictionary, idx: PackedInt32Array) -> PackedVector3Array:
	var skin: Skin = s.skin
	var bind_bone: PackedInt32Array = s.bind_bone
	var verts: PackedVector3Array = s.verts
	var vb: PackedInt32Array = s.bones
	var vw: PackedFloat32Array = s.weights
	var per: int = int(s.per)
	var mats: Dictionary = {}
	var out: PackedVector3Array = PackedVector3Array()
	var count: int = idx.size() if not idx.is_empty() else verts.size()
	for k: int in count:
		var vi: int = idx[k] if not idx.is_empty() else k
		var acc: Vector3 = Vector3.ZERO
		var wsum: float = 0.0
		for j: int in per:
			var w: float = vw[vi * per + j]
			if w <= 0.0:
				continue
			var bind: int = vb[vi * per + j]
			if not mats.has(bind):
				var bone: int = bind_bone[bind]
				mats[bind] = w_skel.get_bone_global_pose(bone) * skin.get_bind_pose(bind) if bone >= 0 else Transform3D.IDENTITY
			acc += ((mats[bind] as Transform3D) * verts[vi]) * w
			wsum += w
		out.append(acc / maxf(wsum, 1e-6))
	return out

## Per foot: [the sole point closest to (or deepest into) what is under it (world), the support height under that
## point, the clip's own foot height (lowest sole point above his root, before any ground fitting: low = planted),
## the support a little ahead of the toe (-INF for exact)]. Every point gets its own downward ray, so a sole across a
## stair edge or a slope is judged by whichever of its points is closest to the ground.
## Runtime (exact = false): six probe points per shoe (heel, toe, both sides at mid-foot, ball, arch).
## exact = true (QA): the 60 lowest of every foot vertex.
func feet_state(exact: bool = false) -> Array:
	var res: Array = []
	if sole.is_empty() or w_skel == null:
		return res
	var idx: PackedInt32Array = PackedInt32Array() if exact else (sole.get("probes", PackedInt32Array()) as PackedInt32Array)
	var pts: PackedVector3Array = _skin_points(sole, idx)
	var xf: Transform3D = (sole.body as MeshInstance3D).global_transform
	var side: PackedInt32Array = sole.side
	var ch: Node3D = walker.get("character")
	var root_y: float = ch.global_position.y
	var fwd: Vector3 = Vector3(sin(ch.rotation.y), 0.0, cos(ch.rotation.y))
	var world: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
	var lowest: Array[float] = [INF, INF]
	for k: int in pts.size():
		var vi: int = idx[k] if not idx.is_empty() else k
		var w: Vector3 = xf * pts[k]
		var f: int = side[vi]
		var arr: PackedVector3Array = world[f]
		arr.append(w)
		world[f] = arr
		lowest[f] = minf(lowest[f], w.y)
	for f2: int in 2:
		var band: PackedVector3Array = PackedVector3Array()
		for w2: Vector3 in world[f2]:
			if not exact or w2.y <= lowest[f2] + 0.03:
				band.append(w2)
		if band.is_empty():
			res.append([Vector3.ZERO, 0.0, 1.0, 0.0])
			continue
		var best_p: Vector3 = band[0]
		var best_s: float = 0.0
		var best_gap: float = INF
		var ahead_s: float = -INF
		var order: Array = []
		for w3: Vector3 in band:
			order.append(w3)
		if exact:
			order.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.y < b.y)
		for q: int in mini(order.size(), 60):
			var pq: Vector3 = order[q]
			# runtime probes read the smooth ground grid; the QA metric reads one ray per vertex (what is really there)
			var sq: float = support_at(pq.x, pq.z, pq.y, false, not exact)
			if pq.y - sq < best_gap:
				best_gap = pq.y - sq
				best_p = pq
				best_s = sq
		if not exact:
			var toe: Vector3 = band[0]
			for w4: Vector3 in band:
				if w4.dot(fwd) > toe.dot(fwd):
					toe = w4
			var ahead: Vector3 = toe + fwd * _cf("walk", "swing_ahead_m", 0.12)
			ahead_s = support_at(ahead.x, ahead.z, toe.y, false, true)
		# the clip's own foot height (lowest sole point above his root, before any ground fitting): low = planted;
		# and what is under the ground a little ahead of the toe (a swing foot rises onto a step before it gets there)
		res.append([best_p, best_s, lowest[f2] - root_y, ahead_s])
	return res

# ------------------------------------------------------------------ collision set
## Every static tile mesh that is drawn solid: the merged shadow casters (the tile's static parts in one mesh) plus
## the shadow-casting meshes that were kept out of the merge (the seat), minus anything that moves.
## Collects the collision parts on the main thread, a few milliseconds per frame (triangle lists only: the
## TriangleMesh trees are built on the worker thread, see _grid_rays). Awaitable. Leaves colliders empty; the worker
## fills job.colliders / job.ground, which bind_tile() takes over.
func _collect_colliders(job: Dictionary) -> void:
	colliders.clear()
	ground_colliders.clear()
	var t0: int = Time.get_ticks_usec()
	var slice_us: int = int(_cf("route", "main_slice_ms", 4.0) * 1000.0)
	var slice_start: int = t0
	var main_us: int = 0
	var moving: Dictionary = {}
	for rec: Variant in tile.get("instance_nodes"):
		var d: Dictionary = (rec as Dictionary).data
		if MOVING_ANIMS.has(str(d.get("anim", ""))):
			for mi: Variant in (rec as Dictionary).meshes:
				moving[mi] = true
	var shadow_nodes: Array = tile.get("shadow_nodes")
	var nodes: Array[MeshInstance3D] = []
	for n: Variant in shadow_nodes:
		nodes.append(n as MeshInstance3D)
	for n2: Node in tile.find_children("*", "MeshInstance3D", true, false):
		var mi2: MeshInstance3D = n2 as MeshInstance3D
		if nodes.has(mi2) or moving.has(mi2) or mi2.skin != null or mi2.mesh == null:
			continue
		if mi2.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON or not mi2.is_visible_in_tree():
			continue
		if str(mi2.name).begins_with("rotor_"):
			continue
		nodes.append(mi2)
	var ground_nodes: Array[MeshInstance3D] = []
	var proc_nodes: Dictionary = tile.get("proc_nodes")
	for role: String in _c("route", "ground_roles", ["ground", "steps", "structure", "cliff", "water_side"]):
		var pn: MeshInstance3D = proc_nodes.get(role) as MeshInstance3D
		if pn != null and pn.mesh != null and pn.is_visible_in_tree():
			ground_nodes.append(pn)
	var part_ms: Array = []
	var parts: Array = []   # [faces or cached TriangleMesh, xf, inv, aabb, "all" / "ground", cache key or null]
	for pass_i: int in 2:
		var list: Array[MeshInstance3D] = nodes if pass_i == 0 else ground_nodes
		for mi3: MeshInstance3D in list:
			var xf: Transform3D = mi3.global_transform
			var key: RID = mi3.mesh.get_rid()
			var cacheable: bool = pass_i == 0 and not shadow_nodes.has(mi3)
			var src: Variant
			var tp: int = Time.get_ticks_usec()
			if cacheable and _tm_cache.has(key):
				src = _tm_cache[key]
			else:
				# the tile's own big meshes: the triangles the assembler already made from its build (= get_faces())
				var pre: Variant = tile.call("faces_for", mi3) if tile.has_method("faces_for") else null
				src = pre if pre is PackedVector3Array else mi3.mesh.get_faces()
			part_ms.append(snappedf(float(Time.get_ticks_usec() - tp) / 1000.0, 0.01))
			parts.append([src, xf, xf.affine_inverse(), xf * mi3.get_aabb(), "all" if pass_i == 0 else "ground", key if cacheable else null])
			if Time.get_ticks_usec() - slice_start > slice_us:
				main_us += Time.get_ticks_usec() - slice_start
				_work("colliders", slice_start)
				await get_tree().process_frame
				slice_start = Time.get_ticks_usec()
	main_us += Time.get_ticks_usec() - slice_start
	_work("colliders", slice_start)
	job["parts"] = parts
	plan_report["collider_parts"] = parts.size()
	plan_report["collider_main_ms"] = float(main_us) / 1000.0
	plan_report["collider_part_ms"] = part_ms

## Worker thread: TriangleMesh trees from the collected triangle lists.
static func _build_trees(job: Dictionary) -> void:
	var cols: Array = []
	var ground: Array = []
	var built: Dictionary = {}
	for part: Array in job.parts:
		var tm: TriangleMesh
		if part[0] is TriangleMesh:
			tm = part[0]
		else:
			tm = TriangleMesh.new()
			if not tm.create_from_faces(part[0] as PackedVector3Array):
				continue
			if part[5] != null:
				built[part[5]] = tm
		var rec: Array = [tm, part[1], part[2], part[3]]
		if str(part[4]) == "all":
			cols.append(rec)
		else:
			ground.append(rec)
	job["colliders"] = cols
	job["ground"] = ground
	job["built"] = built

## Height of the first solid surface straight below (x, y_from, z); -INF when nothing is there. ground_only: the
## tile's ground parts only (what feet stand on).
func _ray_down(x: float, z: float, y_from: float, ground_only: bool = false) -> float:
	return _ray_list(ground_colliders if ground_only and not ground_colliders.is_empty() else colliders, x, z, y_from)

## What a foot at (x, z) near height y_ref stands on.
## Runtime (smooth = true): the ground height grid (the tile's ground parts - terrain surface, steps, decks - cast once per
## tile, deck gaps bridged), read bilinearly, so a sole crossing a stair edge or a board gap moves over a few frames
## instead of jumping; outside the grid, one ray. smooth = false (QA): one ray on the ground parts, what is really
## under that point. everything = true: one ray on every static solid (seat roots, rocks, props). At the tile rim, and
## when no mesh is below, the terrain height.
func support_at(x: float, z: float, y_ref: float, everything: bool = false, smooth: bool = true) -> float:
	var rim: float = _cf("route", "rim_m", 3.96)
	if absf(x) > rim or absf(z) > rim:
		return float(tile.call("terrain_height", clampf(x, -rim, rim), clampf(z, -rim, rim)))
	if everything:
		var ye: float = _ray_down(x, z, y_ref + _cf("route", "ray_step_up_m", 0.35))
		return ye if ye != -INF else float(tile.call("terrain_height", x, z))
	if smooth and grid.has("gtop"):
		var gy: float = _grid_height(x, z)
		if gy > -INF:
			return gy
	var y1: float = _ray_down(x, z, y_ref + _cf("route", "foot_step_up_m", 0.18), true)
	if y1 == -INF:
		y1 = float(tile.call("terrain_height", x, z))
	return y1

## Bilinear read of the ground height grid; -INF outside it.
func _grid_height(x: float, z: float) -> float:
	var lo: Vector2 = grid.lo
	var cell: float = float(grid.gcell)
	var nx: int = int(grid.gnx)
	var nz: int = int(grid.gnz)
	var u: float = (x - lo.x) / cell - 0.5
	var v: float = (z - lo.y) / cell - 0.5
	if u < 0.0 or v < 0.0 or u > float(nx - 1) or v > float(nz - 1):
		return -INF
	var i0: int = mini(int(floor(u)), nx - 2)
	var j0: int = mini(int(floor(v)), nz - 2)
	var fu: float = u - float(i0)
	var fv: float = v - float(j0)
	var g: PackedFloat32Array = grid.gtop
	var a: float = lerpf(g[j0 * nx + i0], g[j0 * nx + i0 + 1], fu)
	var b: float = lerpf(g[(j0 + 1) * nx + i0], g[(j0 + 1) * nx + i0 + 1], fu)
	return lerpf(a, b, fv)

# ------------------------------------------------------------------ stand point
func _find_stand() -> void:
	var kc: Node3D = kit_rig.get("character")
	stand_yaw = kc.rotation.y
	stand_pos = base_pos
	var fwd: Vector3 = Vector3(sin(stand_yaw), 0.0, cos(stand_yaw))
	if kit_pose == "seated":
		var pts: PackedVector3Array = kit_rig.get("sole_points")
		var c: Vector3 = Vector3.ZERO
		if not pts.is_empty():
			for p: Vector3 in pts:
				c += kc.global_transform * p
			c /= float(pts.size())
		else:
			c = base_pos + fwd * 0.3
		stand_pos = Vector3(c.x, 0.0, c.z) + fwd * _cf("route", "seat_front_m", 0.03)
		# he stands up onto open ground: forward until nothing of the seat (roots, rim) is under a standing stance
		var push: float = 0.0
		while push < _cf("route", "stand_push_max_m", 0.45) and not _open_ground(stand_pos + fwd * push, c.y + 0.3):
			push += 0.02
		stand_pos += fwd * push
		stand_pos.y = support_at(stand_pos.x, stand_pos.z, c.y + 0.3) + _cf("walk", "stand_y_offset_m", 0.005)
		plan_report["stand_push_m"] = push
	var path_pts: Array = _path_points()
	if not path_pts.is_empty():
		landmark_point = path_pts[path_pts.size() - 1]
	else:
		landmark_point = stand_pos

## Nothing but ground (terrain, or one flat deck) within a standing stance around p.
func _open_ground(p: Vector3, y_ref: float) -> bool:
	var r: float = _cf("route", "stance_radius_m", 0.18)
	var tol: float = _cf("route", "open_ground_tol_m", 0.03)
	var h0: float = support_at(p.x, p.z, y_ref, true)
	for k: int in 7:
		var q: Vector3 = p if k == 0 else p + Vector3(cos(TAU * float(k) / 6.0), 0.0, sin(TAU * float(k) / 6.0)) * r
		var h: float = support_at(q.x, q.z, y_ref, true)
		var g: float = float(tile.call("terrain_height", q.x, q.z))
		if absf(h - h0) > tol or (h - g > tol and g >= water_level):
			return false
	return true

func _path_points() -> Array:
	var paths: Array = tile_json.get("paths", [])
	if paths.is_empty():
		return []
	var out: Array = []
	var xf: Transform3D = tile.global_transform
	for p: Variant in (paths[0] as Dictionary).get("points", []):
		var a: Array = p
		out.append(xf * Vector3(float(a[0]), float(a[1]), float(a[2])))
	return out

# ------------------------------------------------------------------ grid + routes
func _plan_routes() -> void:
	var t0: int = Time.get_ticks_usec()
	routes = {}
	var path_pts: Array = _path_points()
	var shelter: Dictionary = _shelter()
	# arrival: path from the edge, then the connector to the stand point
	var arr: Dictionary = {}
	if not path_pts.is_empty():
		arr = await _arrival_route(path_pts)
	if arr.is_empty():
		arr = await _edge_route()
	await _plan_yield()
	if not arr.is_empty():
		routes["arrival"] = arr
		routes["leave"] = _reversed(arr)
		if not path_pts.is_empty() and arr.has("join"):
			var out: Dictionary = await _wander_route(path_pts, arr)
			await _plan_yield()
			if not out.is_empty():
				routes["wander_out"] = out
				routes["wander_back"] = _reversed(out)
	if not shelter.is_empty():
		var tr: Dictionary = await _tent_route(shelter)
		if not tr.is_empty():
			routes["tent_in"] = tr
			routes["tent_out"] = _reversed(tr)
	var lens: Dictionary = {}
	for k: String in routes.keys():
		lens[k] = snappedf(float((routes[k] as Dictionary).length), 0.001)
	plan_report.merge({"routes": lens, "kit": kit_pose, "stand": [stand_pos.x, stand_pos.y, stand_pos.z], "stand_yaw_deg": rad_to_deg(stand_yaw),
		"stance_speed_m_s": stance_speed, "stance_u_s": stance_u_s, "walk_clip_s": clip_len.get("walk", 0.0),
		"plan_ms": float(Time.get_ticks_usec() - t0) / 1000.0, "shelter": not shelter.is_empty()}, true)

## Everything the worker thread needs, copied (no node access from the thread).
func _grid_job() -> Dictionary:
	var path_pts: Array = _path_points()
	var lo: Vector2 = Vector2(base_pos.x, base_pos.z)
	var hi: Vector2 = lo
	for p: Variant in path_pts:
		var v: Vector3 = p
		lo = lo.min(Vector2(v.x, v.z))
		hi = hi.max(Vector2(v.x, v.z))
	var shelter: Dictionary = _shelter()
	if not shelter.is_empty():
		var sc: Vector3 = shelter.center
		lo = lo.min(Vector2(sc.x, sc.z))
		hi = hi.max(Vector2(sc.x, sc.z))
	var m: float = _cf("route", "margin_m", 1.2)
	lo = (lo - Vector2.ONE * m).max(Vector2(-4.2, -4.2))
	hi = (hi + Vector2.ONE * m).min(Vector2(4.2, 4.2))
	var cell: float = _cf("route", "cell_m", 0.1)
	return {"lo": lo, "cell": cell, "nx": maxi(2, int(ceil((hi.x - lo.x) / cell))), "nz": maxi(2, int(ceil((hi.y - lo.y) / cell))),
		"water": water_level,
		"hgrid": tile.get("height_grid"), "hn": int(tile.get("terrain_n")), "hstep": float(tile.get("terrain_step")),
		"ground_ray_up": _cf("route", "ground_ray_up_m", 0.6), "path_pts": path_pts,
		"gcell": _cf("route", "ground_cell_m", 0.05), "bridge_min": _cf("route", "bridge_min_m", 0.12),
		"path_w": float(((tile_json.get("paths", []) as Array)[0] as Dictionary).get("width", 0.45)) if not path_pts.is_empty() else 0.45}

## Worker thread: per cell, the top of every static solid (walkability) and the top of the ground parts within
## ground_ray_up_m of the terrain / water (where feet go: terrain, stairs, decks). Pure data in, pure data out.
static func _grid_rays(job: Dictionary) -> void:
	var t0: int = Time.get_ticks_usec()
	_build_trees(job)
	var nx: int = int(job.nx)
	var nz: int = int(job.nz)
	var lo: Vector2 = job.lo
	var cell: float = float(job.cell)
	var cols: Array = job.colliders
	var gcols: Array = job.ground
	var water: float = float(job.water)
	var up: float = float(job.ground_ray_up)
	var top: PackedFloat32Array = PackedFloat32Array()
	var terr: PackedFloat32Array = PackedFloat32Array()
	top.resize(nx * nz)
	terr.resize(nx * nz)
	for cz: int in nz:
		for cx: int in nx:
			var k: int = cz * nx + cx
			var x: float = lo.x + (float(cx) + 0.5) * cell
			var z: float = lo.y + (float(cz) + 0.5) * cell
			terr[k] = GROUND_INFO.height_at(job.hgrid, int(job.hn), float(job.hstep), x, z)
			var h: float = _ray_list(cols, x, z, 12.0)
			top[k] = h if h != -INF else -1000.0
	# the ground height field for feet: its own finer grid over the same region, deck gaps bridged
	var gcell: float = float(job.gcell)
	var gnx: int = maxi(2, int(ceil(float(nx) * cell / gcell)))
	var gnz: int = maxi(2, int(ceil(float(nz) * cell / gcell)))
	var gtop: PackedFloat32Array = PackedFloat32Array()
	gtop.resize(gnx * gnz)
	for gz: int in gnz:
		for gx: int in gnx:
			var x2: float = lo.x + (float(gx) + 0.5) * gcell
			var z2: float = lo.y + (float(gz) + 0.5) * gcell
			var g2: float = GROUND_INFO.height_at(job.hgrid, int(job.hn), float(job.hstep), x2, z2)
			var gh: float = _ray_list(gcols if not gcols.is_empty() else cols, x2, z2, maxf(g2, water) + up)
			gtop[gz * gnx + gx] = gh if gh != -INF else g2
	var bmin: float = float(job.bridge_min)
	var gfilled: PackedFloat32Array = gtop.duplicate()
	for gz2: int in range(2, gnz - 2):
		for gx2: int in range(2, gnx - 2):
			var k2: int = gz2 * gnx + gx2
			# a gap one or two cells wide between two boards at one height: (d1, d2) = cells to each board
			for ax: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				for dd: Vector2i in [Vector2i(1, 1), Vector2i(1, 2), Vector2i(2, 1)]:
					var ka: int = (gz2 - ax.y * dd.x) * gnx + (gx2 - ax.x * dd.x)
					var kb: int = (gz2 + ax.y * dd.y) * gnx + (gx2 + ax.x * dd.y)
					if absf(gtop[ka] - gtop[kb]) < 0.08 and minf(gtop[ka], gtop[kb]) - gtop[k2] > bmin:
						gfilled[k2] = maxf(gfilled[k2], (gtop[ka] + gtop[kb]) * 0.5)
	job["top"] = top
	job["gtop"] = gfilled
	job["gcell"] = gcell
	job["gnx"] = gnx
	job["gnz"] = gnz
	job["terr"] = terr
	job["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0

## First solid surface straight below (x, y_from, z) among the given colliders; -INF when none.
static func _ray_list(list: Array, x: float, z: float, y_from: float) -> float:
	var best: float = -INF
	for c: Array in list:
		var ab: AABB = c[3]
		if x < ab.position.x or x > ab.end.x or z < ab.position.z or z > ab.end.z or ab.position.y > y_from:
			continue
		var inv: Transform3D = c[2]
		var h: Dictionary = (c[0] as TriangleMesh).intersect_ray(inv * Vector3(x, y_from, z), inv.basis * Vector3.DOWN)
		if h.is_empty():
			continue
		var y: float = ((c[1] as Transform3D) * (h.position as Vector3)).y
		if y <= y_from + 0.0001 and y > best:
			best = y
	return best

func _build_grid(job: Dictionary) -> void:
	var lo: Vector2 = job.lo
	var cell: float = float(job.cell)
	var nx: int = int(job.nx)
	var nz: int = int(job.nz)
	var top: PackedFloat32Array = job.top
	var terr: PackedFloat32Array = job.terr
	var path_pts: Array = job.path_pts
	var flags: PackedByteArray = PackedByteArray()
	flags.resize(nx * nz)
	flags.fill(0)
	grid = {"lo": lo, "cell": cell, "nx": nx, "nz": nz, "top": top, "gtop": job.gtop, "gcell": job.gcell, "gnx": job.gnx,
		"gnz": job.gnz, "terr": terr, "flags": flags}
	# path cells
	var half: float = float(job.path_w) * 0.5
	for i: int in range(path_pts.size() - 1):
		var a: Vector3 = path_pts[i]
		var b: Vector3 = path_pts[i + 1]
		var mn: Vector2i = _cell_of(Vector2(minf(a.x, b.x) - half, minf(a.z, b.z) - half))
		var mx: Vector2i = _cell_of(Vector2(maxf(a.x, b.x) + half, maxf(a.z, b.z) + half))
		for cz: int in range(maxi(mn.y, 0), mini(mx.y, nz - 1) + 1):
			for cx: int in range(maxi(mn.x, 0), mini(mx.x, nx - 1) + 1):
				var c: Vector2 = _center(Vector2i(cx, cz))
				if Geometry2D.get_closest_point_to_segment(c, Vector2(a.x, a.z), Vector2(b.x, b.z)).distance_to(c) <= half:
					flags[cz * nx + cx] |= PATH
			await _plan_yield()
	var climb: float = _cf("route", "climb_m", 0.16)
	var edge: float = _cf("route", "edge_limit_m", 3.9)
	var wmargin: float = _cf("route", "water_margin_m", 0.015)
	# a deck of slats: a cell that fell through a gap between two boards reads as the ground below; when the cells on
	# both sides of it (either axis) are deck at about one height, it is deck too
	var bridge_min: float = _cf("route", "bridge_min_m", 0.12)
	var filled: PackedFloat32Array = top.duplicate()
	for cz6: int in range(1, nz - 1):
		for cx6: int in range(1, nx - 1):
			var k6: int = cz6 * nx + cx6
			for ax: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var ka: int = (cz6 - ax.y) * nx + (cx6 - ax.x)
				var kb: int = (cz6 + ax.y) * nx + (cx6 + ax.x)
				if absf(top[ka] - top[kb]) < 0.08 and minf(top[ka], top[kb]) - top[k6] > bridge_min:
					filled[k6] = maxf(filled[k6], (top[ka] + top[kb]) * 0.5)
					flags[k6] |= BRIDGE
		await _plan_yield()
	top = filled
	grid["top"] = top
	var flat_tol: float = _cf("route", "flat_tol_m", 0.05)
	for cz2b: int in nz:
		for cx2b: int in nx:
			var kb2: int = cz2b * nx + cx2b
			var c2b: Vector2 = _center(Vector2i(cx2b, cz2b))
			var h2: float = top[kb2]
			var g2: float = terr[kb2]
			var on_path: bool = (flags[kb2] & PATH) != 0
			var hard: bool = h2 <= -999.0
			if not hard and water_level != -INF and h2 < water_level + wmargin:
				hard = true
			# raised above the terrain on land: walkable only as part of a flat deck (a pier's shore end, a platform);
			# a rock, a prop, a roof slope or a tent side is not flat
			if not hard and not on_path and h2 - g2 > climb and g2 >= water_level - 0.01:
				var rough: float = 0.0
				for o7: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
					var q7: Vector2i = Vector2i(cx2b, cz2b) + o7
					if q7.x < 0 or q7.y < 0 or q7.x >= nx or q7.y >= nz:
						rough = INF
						break
					rough = maxf(rough, absf(top[q7.y * nx + q7.x] - h2))
				if rough > flat_tol:
					hard = true
			if not on_path and (absf(c2b.x) > edge or absf(c2b.y) > edge):
				hard = true
			if hard:
				flags[kb2] |= HARD
		await _plan_yield()
	# placed things he walks around whatever their height (a fire ring or a low crate is not a step), and trees
	# (swaying instances are not in the collision set): their footprint core
	var frac: float = _cf("route", "tree_frac", 0.6)
	var prop_frac: float = _cf("route", "prop_frac", 0.85)
	var prop_roles: Array = _c("route", "obstacle_roles", ["fire", "lamp", "seat", "prop", "shelter", "detail", "dock_prop", "boat", "rock"])
	for rec: Variant in tile.get("instance_nodes"):
		var d: Dictionary = (rec as Dictionary).data
		var is_tree: bool = str(d.get("anim", "")) == "sway"
		if not is_tree and not prop_roles.has(str(d.get("role", ""))):
			continue
		if not is_tree:
			var ab2: AABB = AABB()
			var first2: bool = true
			for mi2: Variant in (rec as Dictionary).meshes:
				var w2: AABB = (mi2 as MeshInstance3D).global_transform * (mi2 as MeshInstance3D).get_aabb()
				ab2 = w2 if first2 else ab2.merge(w2)
				first2 = false
			if not first2:
				_mark_ellipse(Vector2(ab2.get_center().x, ab2.get_center().z), Vector2(ab2.size.x, ab2.size.z) * 0.5 * prop_frac, HARD, true)
			continue
		var ab: AABB = AABB()
		var first: bool = true
		for mi: Variant in (rec as Dictionary).meshes:
			var w: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			ab = w if first else ab.merge(w)
			first = false
		if first:
			continue
		var cc: Vector2 = Vector2(ab.get_center().x, ab.get_center().z)
		var rr: Vector2 = Vector2(ab.size.x, ab.size.z) * 0.5 * frac
		_mark_ellipse(cc, rr, HARD, true)
		await _plan_yield()
	# steps higher than a stride: the lower cell of the pair is blocked (a ledge top stays walkable)
	var max_step: float = _cf("route", "max_step_m", 0.22)
	for cz3: int in nz:
		for cx3: int in nx:
			var k3: int = cz3 * nx + cx3
			for dxy: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var ox: int = cx3 + dxy.x
				var oz: int = cz3 + dxy.y
				if ox >= nx or oz >= nz:
					continue
				var k4: int = oz * nx + ox
				if absf(top[k3] - top[k4]) > max_step:
					var low: int = k3 if top[k3] < top[k4] else k4
					if (flags[low] & PATH) == 0:
						flags[low] |= HARD
		await _plan_yield()
	# body radius and clearance
	var r_body: float = _cf("route", "body_radius_m", 0.12)
	var r_near: float = _cf("route", "clearance_m", 0.3)
	var rn: int = int(ceil(r_near / cell))
	var hard_cells: Array[Vector2i] = []
	for cz4: int in nz:
		for cx4: int in nx:
			if (flags[cz4 * nx + cx4] & HARD) == 0:
				continue
			var inner: bool = true
			for o4: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var q4: Vector2i = Vector2i(cx4, cz4) + o4
				if q4.x >= 0 and q4.y >= 0 and q4.x < nx and q4.y < nz and (flags[q4.y * nx + q4.x] & HARD) == 0:
					inner = false
			if not inner:
				hard_cells.append(Vector2i(cx4, cz4))
		await _plan_yield()
	var hc_i: int = 0
	for hc: Vector2i in hard_cells:
		hc_i += 1
		if hc_i % 32 == 0:
			await _plan_yield()
		for oz2: int in range(-rn, rn + 1):
			for ox2: int in range(-rn, rn + 1):
				var q: Vector2i = hc + Vector2i(ox2, oz2)
				if q.x < 0 or q.y < 0 or q.x >= nx or q.y >= nz:
					continue
				var dist: float = Vector2(ox2, oz2).length() * cell
				var kq: int = q.y * nx + q.x
				if dist <= r_body + 0.0001 and (flags[kq] & PATH) == 0:
					flags[kq] |= DILATED
				elif dist <= r_near:
					flags[kq] |= NEAR
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, nx, nz)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	var off_cost: float = _cf("route", "off_path_cost", 1.7)
	var near_cost: float = _cf("route", "near_cost", 1.5)
	var slope_cost: float = _cf("route", "slope_cost", 1.5)
	var max_grade: float = _cf("route", "max_grade", 0.8)
	var blocked: int = 0
	for cz5: int in nz:
		for cx5: int in nx:
			var f: int = flags[cz5 * nx + cx5]
			var id: Vector2i = Vector2i(cx5, cz5)
			if (f & (HARD | DILATED)) != 0:
				astar.set_point_solid(id, true)
				blocked += 1
				continue
			var wgt: float = 1.0 if (f & PATH) != 0 else off_cost
			if (f & NEAR) != 0:
				wgt *= near_cost
			# steep ground costs more (the walk clip is made for level ground); too steep is blocked off the path
			var grade: float = _grade(cx5, cz5)
			if grade > max_grade and (f & PATH) == 0:
				astar.set_point_solid(id, true)
				blocked += 1
				continue
			wgt *= 1.0 + slope_cost * clampf(grade / 0.3, 0.0, 3.0)
			astar.set_point_weight_scale(id, wgt)
		await _plan_yield()
	grid["flags"] = flags
	plan_report["grid"] = {"nx": nx, "nz": nz, "cell_m": cell, "blocked": blocked, "lo": [lo.x, lo.y]}

## Slope of the ground at cell (cx, cz): the terrain's steepest rise to a 4-neighbour, rise over run. Cells standing
## on a deck or a structure are not ground (their edges are handled as steps), so they read 0.
func _grade(cx: int, cz: int) -> float:
	var top: PackedFloat32Array = grid.top
	var terr: PackedFloat32Array = grid.terr
	var nx: int = int(grid.nx)
	var nz: int = int(grid.nz)
	var k: int = cz * nx + cx
	if absf(top[k] - terr[k]) > 0.03:
		return 0.0
	var g: float = 0.0
	for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var q: Vector2i = Vector2i(cx, cz) + o
		if q.x < 0 or q.y < 0 or q.x >= nx or q.y >= nz:
			continue
		g = maxf(g, absf(terr[q.y * nx + q.x] - terr[k]))
	return g / float(grid.cell)

## Weighted cost of a cell path (what A* minimised), in metres times the cell weights.
func _path_cost(ids: Array[Vector2i]) -> float:
	var cost: float = 0.0
	var cell: float = float(grid.cell)
	for i: int in range(1, ids.size()):
		cost += Vector2(ids[i] - ids[i - 1]).length() * cell * astar.get_point_weight_scale(ids[i])
	return cost

func _mark_ellipse(c: Vector2, r: Vector2, bit: int, respect_path: bool) -> void:
	var flags: PackedByteArray = grid.flags
	var nx: int = int(grid.nx)
	var mn: Vector2i = _cell_of(c - r)
	var mx: Vector2i = _cell_of(c + r)
	for cz: int in range(maxi(mn.y, 0), mini(mx.y, int(grid.nz) - 1) + 1):
		for cx: int in range(maxi(mn.x, 0), mini(mx.x, nx - 1) + 1):
			var p: Vector2 = _center(Vector2i(cx, cz)) - c
			if r.x <= 0.0 or r.y <= 0.0:
				continue
			if (p.x / r.x) * (p.x / r.x) + (p.y / r.y) * (p.y / r.y) <= 1.0:
				if respect_path and (flags[cz * nx + cx] & PATH) != 0:
					continue
				flags[cz * nx + cx] |= bit
	grid["flags"] = flags

func _cell_of(p: Vector2) -> Vector2i:
	var lo: Vector2 = grid.lo
	var cell: float = float(grid.cell)
	return Vector2i(int(floor((p.x - lo.x) / cell)), int(floor((p.y - lo.y) / cell)))

func _center(c: Vector2i) -> Vector2:
	var lo: Vector2 = grid.lo
	var cell: float = float(grid.cell)
	return lo + (Vector2(c) + Vector2(0.5, 0.5)) * cell

func _in_grid(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < int(grid.nx) and c.y < int(grid.nz)

func _free(c: Vector2i) -> bool:
	return _in_grid(c) and not astar.is_point_solid(c)

func _nearest_free(p: Vector2, radius: float) -> Vector2i:
	var c: Vector2i = _cell_of(p)
	if _free(c):
		return c
	var cell: float = float(grid.cell)
	var rn: int = int(ceil(radius / cell))
	var best: Vector2i = Vector2i(-1, -1)
	var best_d: float = INF
	for oz: int in range(-rn, rn + 1):
		for ox: int in range(-rn, rn + 1):
			var q: Vector2i = c + Vector2i(ox, oz)
			if not _free(q):
				continue
			var d: float = _center(q).distance_to(p)
			if d <= radius and d < best_d:
				best_d = d
				best = q
	return best

## Straight segment a-b stays on free cells and never steps more than a stride.
func _clear(a: Vector2, b: Vector2) -> bool:
	var cell: float = float(grid.cell)
	var n: int = maxi(1, int(ceil(a.distance_to(b) / (cell * 0.4))))
	var top: PackedFloat32Array = grid.top
	var nx: int = int(grid.nx)
	var max_step: float = _cf("route", "max_step_m", 0.22)
	var prev_h: float = NAN
	for i: int in n + 1:
		var p: Vector2 = a.lerp(b, float(i) / float(n))
		var c: Vector2i = _cell_of(p)
		if not _free(c):
			return false
		var h: float = top[c.y * nx + c.x]
		if not is_nan(prev_h) and absf(h - prev_h) > max_step:
			return false
		prev_h = h
	return true

func _astar(from: Vector2i, to: Vector2i) -> PackedVector2Array:
	if not _free(from) or not _free(to):
		return PackedVector2Array()
	var ids: Array[Vector2i] = astar.get_id_path(from, to)
	var out: PackedVector2Array = PackedVector2Array()
	for id: Vector2i in ids:
		out.append(_center(id))
	return out

static func _poly_len(p: PackedVector2Array) -> float:
	var l: float = 0.0
	for i: int in range(p.size() - 1):
		l += p[i].distance_to(p[i + 1])
	return l

## Greedy line-of-sight simplification.
func _simplify(p: PackedVector2Array) -> PackedVector2Array:
	if p.size() <= 2:
		return p
	var out: PackedVector2Array = PackedVector2Array([p[0]])
	var i: int = 0
	while i < p.size() - 1:
		var k: int = p.size() - 1
		while k > i + 1 and not _clear(p[i], p[k]):
			k -= 1
		out.append(p[k])
		i = k
	return out

## Chaikin corner cutting; the first `keep` points (the baked path) stay as they are; a pass is kept only when every
## cut segment stays clear.
func _smooth(p: PackedVector2Array, passes: int, keep: int) -> PackedVector2Array:
	var cur: PackedVector2Array = p
	for _pass: int in passes:
		if cur.size() < 3:
			break
		var k: int = clampi(keep, 1, cur.size() - 1)
		var nxt: PackedVector2Array = PackedVector2Array()
		for i: int in k:
			nxt.append(cur[i])
		for i2: int in range(k - 1, cur.size() - 1):
			nxt.append(cur[i2].lerp(cur[i2 + 1], 0.25))
			nxt.append(cur[i2].lerp(cur[i2 + 1], 0.75))
		nxt.append(cur[cur.size() - 1])
		var ok: bool = true
		for j: int in range(k - 1, nxt.size() - 1):
			if not _clear(nxt[j], nxt[j + 1]):
				ok = false
				break
		if not ok:
			break
		cur = nxt
	return cur

## Resampled route with support heights: {pts: PackedVector3Array, ds, length, ...}.
func _make_route(poly: PackedVector2Array, y_start: float, extra: Dictionary) -> Dictionary:
	var clean: PackedVector2Array = PackedVector2Array()
	for p: Vector2 in poly:
		if clean.is_empty() or clean[clean.size() - 1].distance_to(p) > 0.001:
			clean.append(p)
	var total: float = _poly_len(clean)
	if clean.size() < 2 or total < 0.05:
		return {}
	var step: float = _cf("route", "resample_m", 0.04)
	var n: int = maxi(2, int(ceil(total / step)) + 1)
	var ds: float = total / float(n - 1)
	var pts: PackedVector3Array = PackedVector3Array()
	var seg: int = 0
	var seg_start: float = 0.0
	var y_prev: float = y_start
	for i: int in n:
		var s: float = minf(ds * float(i), total)
		while seg < clean.size() - 2 and seg_start + clean[seg].distance_to(clean[seg + 1]) < s:
			seg_start += clean[seg].distance_to(clean[seg + 1])
			seg += 1
		var sl: float = clean[seg].distance_to(clean[seg + 1])
		var p: Vector2 = clean[seg].lerp(clean[seg + 1], clampf((s - seg_start) / maxf(sl, 1e-6), 0.0, 1.0))
		var y: float = support_at(p.x, p.y, y_prev)
		pts.append(Vector3(p.x, y, p.y))
		y_prev = y
		if i % 8 == 7:
			await _plan_yield()
	# the root's base height is the support smoothed along the route (steps and kerbs are taken by the feet, not by
	# jumps of the whole body); the last point keeps its own height (where he stops)
	var half_n: int = maxi(1, int(round(_cf("route", "height_smooth_m", 0.25) / ds)))
	var raw: PackedFloat32Array = PackedFloat32Array()
	for q: Vector3 in pts:
		raw.append(q.y)
	for i2: int in range(0, n - 1):
		var acc: float = 0.0
		var cnt: int = 0
		for j: int in range(maxi(0, i2 - half_n), mini(n - 1, i2 + half_n) + 1):
			acc += raw[j]
			cnt += 1
		pts[i2].y = acc / float(cnt)
	# he slows down where the going is hard: steep ground, and stairs (where what is really under him departs from
	# the smoothed ground). Walking speed follows f (1 = normal); the clip phase stays tied to distance.
	var k_slow: float = _cf("walk", "slow_k", 0.8)
	var d0: float = _cf("walk", "slow_from_grade", 0.2)
	var f_min: float = _cf("walk", "slow_min", 0.55)
	var diff: PackedFloat32Array = PackedFloat32Array()
	for i3: int in n:
		var a3: float = raw[maxi(i3 - 1, 0)]
		var b3: float = raw[mini(i3 + 1, n - 1)]
		var grade: float = absf(b3 - a3) / (ds * float(mini(i3 + 1, n - 1) - maxi(i3 - 1, 0)))
		var ex: float = support_at(pts[i3].x, pts[i3].z, raw[i3], false, false)
		diff.append(maxf(grade, absf(ex - raw[i3]) / 0.05))
		if i3 % 8 == 7:
			await _plan_yield()
	var span: int = maxi(1, int(round(_cf("walk", "slow_span_m", 0.3) / ds)))
	var f: PackedFloat32Array = PackedFloat32Array()
	for i4: int in n:
		var worst: float = 0.0
		for j4: int in range(maxi(0, i4 - span), mini(n - 1, i4 + span) + 1):
			worst = maxf(worst, diff[j4])
		f.append(clampf(1.0 - k_slow * maxf(0.0, worst - d0), f_min, 1.0))
	var r: Dictionary = {"pts": pts, "ds": ds, "length": total, "f": f}
	r.merge(extra, true)
	_warp(r)
	return r

## Cumulative "effort distance" u along a route (distance over speed factor): the speed profile runs in u.
func _warp(r: Dictionary) -> void:
	var f: PackedFloat32Array = r.get("f", PackedFloat32Array())
	var pts: PackedVector3Array = r.pts
	var ds: float = float(r.ds)
	var u: PackedFloat32Array = PackedFloat32Array([0.0])
	for i: int in range(1, pts.size()):
		var fa: float = f[i - 1] if f.size() == pts.size() else 1.0
		var fb: float = f[i] if f.size() == pts.size() else 1.0
		u.append(u[i - 1] + ds / maxf((fa + fb) * 0.5, 0.05))
	r["u"] = u
	r["u_total"] = u[u.size() - 1]

## Distance along the route at effort distance uu.
static func _u_to_s(r: Dictionary, uu: float) -> float:
	var u: PackedFloat32Array = r.u
	var ds: float = float(r.ds)
	if uu <= 0.0:
		return 0.0
	if uu >= u[u.size() - 1]:
		return float(r.length)
	var i: int = u.bsearch(uu, true) - 1
	i = clampi(i, 0, u.size() - 2)
	return minf(ds * (float(i) + (uu - u[i]) / maxf(u[i + 1] - u[i], 1e-6)), float(r.length))

func _reversed(r: Dictionary) -> Dictionary:
	var pts: PackedVector3Array = (r.pts as PackedVector3Array).duplicate()
	pts.reverse()
	var out: Dictionary = r.duplicate()
	out["pts"] = pts
	if r.has("f"):
		var f: PackedFloat32Array = (r.f as PackedFloat32Array).duplicate()
		f.reverse()
		out["f"] = f
	_warp(out)
	return out

func _arrival_route(path_pts: Array) -> Dictionary:
	var goal: Vector2 = Vector2(stand_pos.x, stand_pos.z)
	var goal_c: Vector2i = _nearest_free(goal, _cf("route", "goal_search_m", 0.6))
	if goal_c.x < 0 and kit_pose == "seated":
		# push the seat-front stand point forward until it is free
		var fwd: Vector2 = Vector2(sin(stand_yaw), cos(stand_yaw))
		var push: float = 0.0
		while push < _cf("route", "stand_push_max_m", 0.45) and goal_c.x < 0:
			push += float(grid.cell) * 0.5
			goal_c = _nearest_free(goal + fwd * push, _cf("route", "goal_search_m", 0.6))
		if goal_c.x >= 0:
			goal += fwd * push
			stand_pos = Vector3(goal.x, support_at(goal.x, goal.y, stand_pos.y) + _cf("walk", "stand_y_offset_m", 0.005), goal.y)
	if goal_c.x < 0:
		plan_report["arrival_error"] = "stand point blocked"
		return {}
	# candidate departure points along the path (cumulative length s_j)
	var cum: Array[float] = [0.0]
	for i: int in range(1, path_pts.size()):
		cum.append(cum[i - 1] + (path_pts[i] as Vector3).distance_to(path_pts[i - 1] as Vector3))
	var spacing: float = _cf("route", "candidate_spacing_m", 0.25)
	var cands: Array = []
	var last_s: float = -INF
	for j: int in path_pts.size():
		if cum[j] - last_s < spacing and j != path_pts.size() - 1:
			continue
		last_s = cum[j]
		var pj: Vector3 = path_pts[j]
		var c: Vector2i = _cell_of(Vector2(pj.x, pj.z))
		if not _free(c):
			continue
		cands.append([cum[j] + 1.7 * Vector2(pj.x, pj.z).distance_to(goal), j])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var best: Dictionary = {}
	var best_cost: float = INF
	for ci: int in mini(cands.size(), int(_c("route", "candidates", 6))):
		var j2: int = int((cands[ci] as Array)[1])
		var pj2: Vector3 = path_pts[j2]
		var c_from: Vector2i = _cell_of(Vector2(pj2.x, pj2.z))
		if not _free(c_from):
			continue
		var ids: Array[Vector2i] = astar.get_id_path(c_from, goal_c)
		if ids.is_empty():
			continue
		var conn: PackedVector2Array = PackedVector2Array()
		for id2: Vector2i in ids:
			conn.append(_center(id2))
		conn[0] = Vector2(pj2.x, pj2.z)
		conn.append(goal)
		var cost: float = cum[j2] + _path_cost(ids)
		if cost < best_cost:
			best_cost = cost
			best = {"j": j2, "conn": conn}
		await _plan_yield()
	if best.is_empty():
		plan_report["arrival_error"] = "no connector from the path"
		return {}
	var j3: int = int(best.j)
	var poly: PackedVector2Array = PackedVector2Array()
	for i2: int in j3 + 1:
		var pp: Vector3 = path_pts[i2]
		poly.append(Vector2(pp.x, pp.z))
	var conn2: PackedVector2Array = _simplify(best.conn as PackedVector2Array)
	await _plan_yield()
	for k: int in range(1, conn2.size()):
		poly.append(conn2[k])
	var smooth_keep: int = maxi(j3 - 3, 0)
	poly = _smooth(poly, int(_c("route", "smooth_passes", 2)), smooth_keep)
	await _plan_yield()
	var r: Dictionary = await _make_route(poly, (path_pts[0] as Vector3).y, {"join": j3, "join_s": cum[j3], "path_len": cum[cum.size() - 1], "connector_m": _poly_len(conn2)})
	return r

## No usable path: come in from the nearest free border cell of the grid.
func _edge_route() -> Dictionary:
	var goal: Vector2 = Vector2(stand_pos.x, stand_pos.z)
	var goal_c: Vector2i = _nearest_free(goal, _cf("route", "goal_search_m", 0.6))
	if goal_c.x < 0:
		return {}
	var nx: int = int(grid.nx)
	var nz: int = int(grid.nz)
	var border: Array = []
	for cz: int in nz:
		for cx: int in nx:
			if cx != 0 and cz != 0 and cx != nx - 1 and cz != nz - 1:
				continue
			var c: Vector2i = Vector2i(cx, cz)
			if _free(c):
				border.append([_center(c).distance_to(goal), c])
	border.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var best: PackedVector2Array = PackedVector2Array()
	var best_l: float = INF
	for i: int in mini(border.size(), 8):
		var p: PackedVector2Array = _astar(border[i][1] as Vector2i, goal_c)
		if p.is_empty():
			continue
		var l: float = _poly_len(p)
		if l < best_l:
			best_l = l
			best = p
		await _plan_yield()
	if best.is_empty():
		return {}
	best.append(goal)
	var poly: PackedVector2Array = _smooth(_simplify(best), int(_c("route", "smooth_passes", 2)), 0)
	await _plan_yield()
	return await _make_route(poly, stand_pos.y, {"edge_fallback": true})

func _wander_route(path_pts: Array, arr: Dictionary) -> Dictionary:
	var j: int = int(arr.join)
	if j >= path_pts.size() - 2:
		plan_report["wander_error"] = "stand point is at the path end"
		return {}
	var goal: Vector2 = Vector2(landmark_point.x, landmark_point.z)
	var goal_c: Vector2i = _cell_of(goal)
	var flags: PackedByteArray = grid.flags
	if not _in_grid(goal_c) or (flags[goal_c.y * int(grid.nx) + goal_c.x] & HARD) != 0:
		plan_report["wander_error"] = "landmark stand point blocked"
		return {}
	# stand -> back along the connector to the path -> the path to its end
	var arr_pts: PackedVector3Array = arr.pts
	var poly: PackedVector2Array = PackedVector2Array()
	var js: float = float(arr.get("join_s", 0.0))
	for i: int in range(arr_pts.size() - 1, -1, -1):
		var s: float = float(arr.ds) * float(i)
		if s < js:
			break
		poly.append(Vector2(arr_pts[i].x, arr_pts[i].z))
	var n_conn: int = poly.size()
	for k: int in range(j, path_pts.size()):
		var pk: Vector3 = path_pts[k]
		poly.append(Vector2(pk.x, pk.z))
	# the connector part is the arrival route (already checked); the baked path must not cross anything solid or step
	# more than a stride (an overhang, water). Blocked just before its end: stop at the last clear point.
	var remain: float = 0.0
	for i3: int in range(n_conn, poly.size() - 1):
		remain += poly[i3].distance_to(poly[i3 + 1])
	var walked: float = 0.0
	for i2: int in range(maxi(n_conn - 1, 0), poly.size() - 1):
		if not _path_clear(poly[i2], poly[i2 + 1]):
			if remain - walked <= _cf("wander", "stop_short_max_m", 0.8) and i2 > n_conn:
				poly.resize(i2 + 1)
				plan_report["wander_stopped_short_m"] = remain - walked
				break
			plan_report["wander_error"] = "path blocked near %s" % str(poly[i2])
			return {}
		if i2 >= n_conn:
			walked += poly[i2].distance_to(poly[i2 + 1])
	# he stops at the foot of steps / a porch on the path (no stair climbing): the first point whose support stands
	# clear of the terrain ends the walk, unless that leaves less than wander.min_m
	var step_stop: float = _cf("wander", "step_stop_m", 0.05)
	var along: float = 0.0
	for i4: int in range(n_conn, poly.size()):
		if i4 > n_conn:
			along += poly[i4 - 1].distance_to(poly[i4])
		var q4: Vector2 = poly[i4]
		if absf(q4.x) > 3.9 or absf(q4.y) > 3.9:
			continue
		# the centre line and a foot's width to each side
		var side4: Vector2 = Vector2.ZERO
		if i4 + 1 < poly.size():
			var d4: Vector2 = (poly[i4 + 1] - q4).normalized()
			side4 = Vector2(-d4.y, d4.x) * _cf("wander", "side_check_m", 0.18)
		var raised: bool = false
		for o4: Vector2 in [Vector2.ZERO, side4, -side4]:
			var q5: Vector2 = q4 + o4
			var g5: float = float(tile.call("terrain_height", q5.x, q5.y))
			if support_at(q5.x, q5.y, g5 + 0.3, false, false) - g5 > step_stop:
				raised = true
		if raised:
			if along < _cf("wander", "min_m", 1.0):
				plan_report["wander_error"] = "structure right after the join"
				return {}
			# back off so his feet (half a stride ahead) stay clear of it too
			var back: float = _cf("wander", "stop_back_m", 0.4)
			var keep_n: int = i4
			var backed: float = 0.0
			while keep_n > n_conn + 1 and backed < back:
				backed += poly[keep_n - 1].distance_to(poly[keep_n])
				keep_n -= 1
			poly.resize(maxi(keep_n, n_conn + 1))
			plan_report["wander_stopped_at_structure"] = true
			break
	var end_p: Vector2 = poly[poly.size() - 1]
	landmark_point = Vector3(end_p.x, landmark_point.y, end_p.y)
	await _plan_yield()
	return await _make_route(poly, stand_pos.y, {"landmark": [landmark_point.x, landmark_point.y, landmark_point.z]})

## Like _clear, but only hard blocks count (the body-radius margin is ignored on the baked path).
func _path_clear(a: Vector2, b: Vector2) -> bool:
	var cell: float = float(grid.cell)
	var n: int = maxi(1, int(ceil(a.distance_to(b) / (cell * 0.4))))
	var top: PackedFloat32Array = grid.top
	var flags: PackedByteArray = grid.flags
	var nx: int = int(grid.nx)
	var max_step: float = _cf("route", "max_step_m", 0.22)
	var prev_h: float = NAN
	var edge: float = _cf("route", "edge_limit_m", 3.9)
	for i: int in n + 1:
		var q: Vector2 = a.lerp(b, float(i) / float(n))
		if absf(q.x) > edge or absf(q.y) > edge:
			continue   # the path's first metres run out to the tile edge, where rays may miss the rim
		var c: Vector2i = _cell_of(q)
		if not _in_grid(c) or (flags[c.y * nx + c.x] & HARD) != 0:
			return false
		var h: float = top[c.y * nx + c.x]
		if not is_nan(prev_h) and absf(h - prev_h) > max_step:
			return false
		prev_h = h
	return true

func _shelter() -> Dictionary:
	for rec: Variant in tile.get("instance_nodes"):
		var d: Dictionary = (rec as Dictionary).data
		if str(d.get("role", "")) != "shelter":
			continue
		var ab: AABB = AABB()
		var first: bool = true
		for mi: Variant in (rec as Dictionary).meshes:
			var w: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			ab = w if first else ab.merge(w)
			first = false
		if first:
			continue
		return {"center": ab.get_center(), "radius": maxf(ab.size.x, ab.size.z) * 0.5}
	return {}

func _tent_route(shelter: Dictionary) -> Dictionary:
	var c: Vector3 = shelter.center
	var dir: Vector2 = Vector2(stand_pos.x - c.x, stand_pos.z - c.z)
	if dir.length() < 0.01:
		return {}
	dir = dir.normalized()
	var target: Vector2 = Vector2(c.x, c.z) + dir * (float(shelter.radius) + _cf("route", "tent_gap_m", 0.12))
	var tc: Vector2i = _nearest_free(target, _cf("route", "goal_search_m", 0.6))
	var sc: Vector2i = _nearest_free(Vector2(stand_pos.x, stand_pos.z), _cf("route", "goal_search_m", 0.6))
	if tc.x < 0 or sc.x < 0:
		return {}
	var p: PackedVector2Array = _astar(sc, tc)
	if p.is_empty():
		return {}
	p[0] = Vector2(stand_pos.x, stand_pos.z)
	var poly: PackedVector2Array = _smooth(_simplify(p), int(_c("route", "smooth_passes", 2)), 0)
	await _plan_yield()
	return await _make_route(poly, stand_pos.y, {"shelter": [c.x, c.y, c.z]})

# ------------------------------------------------------------------ route sampling
func _route_at(r: Dictionary, s: float) -> Vector3:
	var pts: PackedVector3Array = r.pts
	var ds: float = float(r.ds)
	var f: float = clampf(s, 0.0, float(r.length)) / ds
	var i: int = mini(int(floor(f)), pts.size() - 2)
	return pts[i].lerp(pts[i + 1], clampf(f - float(i), 0.0, 1.0))

func _heading_at(r: Dictionary, s: float) -> float:
	var a: Vector3 = _route_at(r, s - _cf("walk", "heading_back_m", 0.12))
	var b: Vector3 = _route_at(r, s + _cf("walk", "heading_ahead_m", 0.2))
	var d: Vector2 = Vector2(b.x - a.x, b.z - a.z)
	if d.length_squared() < 1e-8:
		var pts: PackedVector3Array = r.pts
		d = Vector2(pts[pts.size() - 1].x - pts[0].x, pts[pts.size() - 1].z - pts[0].z)
	return atan2(d.x, d.y)

# ------------------------------------------------------------------ speed profile
func _profile(length: float, from_rest: bool, to_rest: bool) -> Dictionary:
	var v: float = stance_speed * _cf("walk", "speed_scale", 1.0)
	var ta: float = _cf("walk", "accel_s", 0.45) if from_rest else 0.0
	var td: float = _cf("walk", "decel_s", 0.6) if to_rest else 0.0
	var da: float = 0.5 * v * ta
	var dd: float = 0.5 * v * td
	if da + dd > length and da + dd > 0.0:
		var k: float = sqrt(length / (da + dd))
		v *= k
		ta *= k
		td *= k
		da = 0.5 * v * ta
		dd = 0.5 * v * td
	var cruise: float = maxf(0.0, (length - da - dd) / maxf(v, 1e-4))
	return {"v": v, "ta": ta, "td": td, "da": da, "dd": dd, "cruise": cruise, "T": ta + cruise + td, "L": length}

static func _prof_s(p: Dictionary, tau: float) -> float:
	var v: float = float(p.v)
	var ta: float = float(p.ta)
	var td: float = float(p.td)
	var cr: float = float(p.cruise)
	var T: float = float(p.T)
	var L: float = float(p.L)
	if tau <= 0.0:
		return 0.0
	if tau < ta:
		return 0.5 * v / ta * tau * tau
	if tau < ta + cr:
		return float(p.da) + v * (tau - ta)
	if tau < T:
		var u: float = T - tau
		return L - (0.5 * v / td * u * u if td > 0.0 else 0.0)
	return L

# ------------------------------------------------------------------ scheduling
## Where the chain of moves running at t ends: {mode, t, pos, yaw}.
func _chain_end(t: float) -> Dictionary:
	var i: int = _seg_index(t)
	while i < segs.size() and str(segs[i].kind) != "hold":
		i += 1
	if i >= segs.size():
		var last: Dictionary = segs[segs.size() - 1]
		return {"mode": str(last.get("mode", "kit")), "t": float(last.t1), "pos": last.get("pos", stand_pos), "yaw": float(last.get("yaw", stand_yaw))}
	var h: Dictionary = segs[i]
	return {"mode": str(h.mode), "t": maxf(float(h.t0), t), "pos": h.get("pos", stand_pos), "yaw": float(h.get("yaw", stand_yaw))}

func _seg_index(t: float) -> int:
	for i: int in range(segs.size() - 1, -1, -1):
		if float(segs[i].t0) <= t:
			return i
	return 0

## Drops everything from t on and returns the start time.
func _truncate(t: float) -> void:
	var keep: Array[Dictionary] = []
	for s: Dictionary in segs:
		if float(s.t0) < t:
			keep.append(s)
	if keep.is_empty():
		keep.append(_hold(-INF, "kit"))
	var last: Dictionary = keep[keep.size() - 1]
	last["t1"] = t
	segs = keep

func _push(s: Dictionary) -> float:
	segs.append(s)
	return float(s.t1)

func _walk_seg(t0: float, route: Dictionary, from_rest: bool, to_rest: bool, fade_in_m: float, fade_out_m: float, yaw_end: float, y_end: float) -> Dictionary:
	var prof: Dictionary = _profile(float(route.get("u_total", route.length)), from_rest, to_rest)
	return {"kind": "walk", "t0": t0, "t1": t0 + float(prof.T), "route": route, "prof": prof, "from_rest": from_rest, "to_rest": to_rest,
		"fade_in": fade_in_m, "fade_out": fade_out_m, "yaw_end": yaw_end, "y_end": y_end, "phase0": ds_phase}

func _turn_seg(t0: float, pos: Vector3, yaw0: float, yaw1: float) -> Dictionary:
	var d: float = absf(wrapf(yaw1 - yaw0, -PI, PI))
	var anim: bool = rad_to_deg(d) > _cf("turn", "step_anim_deg", 45.0) and w_clips.has("turn_180")
	var dur: float
	if anim:
		dur = float(clip_len["turn_180"]) * clampf(d / PI, _cf("turn", "anim_min_frac", 0.6), 1.0)
	else:
		dur = maxf(_cf("turn", "min_s", 0.45), d * _cf("turn", "idle_s_per_rad", 0.35))
	return {"kind": "turn", "t0": t0, "t1": t0 + dur, "pos": pos, "yaw0": yaw0, "yaw1": yaw0 + wrapf(yaw1 - yaw0, -PI, PI), "anim": anim}

func _needs_turn(yaw0: float, yaw1: float) -> bool:
	return rad_to_deg(absf(wrapf(yaw1 - yaw0, -PI, PI))) > _cf("turn", "small_deg", 12.0)

func _stand_y() -> float:
	return base_pos.y if kit_is_walker else stand_pos.y

## Walk in and settle. Returns the time he is settled (INF when he cannot be placed).
func arrive(t0: float) -> float:
	if not bound:
		return INF
	_truncate(t0)
	doze_off = minf(doze_off, t0)
	if not routes.has("arrival"):
		var tf: float = _push({"kind": "fade", "t0": t0, "t1": t0 + 1.0, "a0": 0.0, "a1": 1.0})
		segs.append(_hold(tf, "kit"))
		return tf
	var r: Dictionary = routes["arrival"]
	var align: bool = rad_to_deg(absf(wrapf(stand_yaw - _heading_at(r, float(r.length)), -PI, PI))) <= _cf("walk", "align_max_deg", 50.0)
	var t: float = _push(_walk_seg(t0, r, false, true, _cf("walk", "fade_in_m", 0.7), 0.0, stand_yaw if align else NAN, _stand_y()))
	var end_yaw: float = stand_yaw if align else _heading_at(r, float(r.length))
	if not align:
		t = _push(_turn_seg(t, stand_pos, end_yaw, stand_yaw))
	if not kit_is_walker:
		t = _push({"kind": "xfade", "t0": t, "t1": t + float(cfg.get("pose_blend_s", 0.5)), "to_kit": true, "pos": stand_pos, "yaw": stand_yaw})
	segs.append(_hold(t, "kit"))
	return t

## Stand up, turn, walk out, fade at the edge. Returns the time he is gone.
func leave(t_req: float) -> float:
	if not bound:
		return INF
	var st: Dictionary = _chain_end(t_req)
	var t0: float = float(st.t)
	_truncate(t0)
	if str(st.mode) == "hidden" or str(st.mode) == "tent":
		segs.append(_hold(t0, "hidden"))
		return t0
	var from_pos: Vector3 = st.pos if str(st.mode) == "stand" else stand_pos
	var from_yaw: float = float(st.yaw) if str(st.mode) == "stand" else stand_yaw
	var t: float = t0
	if str(st.mode) == "kit" and not kit_is_walker:
		t = _push({"kind": "xfade", "t0": t, "t1": t + float(cfg.get("pose_blend_s", 0.5)), "to_kit": false, "pos": stand_pos, "yaw": stand_yaw})
	if not routes.has("leave") or str(st.mode) == "stand":
		# no route (or standing away from the spot): fade out where he stands
		t = _push({"kind": "fade", "t0": t, "t1": t + 1.0, "a0": 1.0, "a1": 0.0, "pos": from_pos, "yaw": from_yaw, "walker": true})
		segs.append(_hold(t, "hidden"))
		return t
	var r: Dictionary = routes["leave"]
	var h0: float = _heading_at(r, 0.0)
	if _needs_turn(from_yaw, h0):
		t = _push(_turn_seg(t, from_pos, from_yaw, h0))
	t = _push(_walk_seg(t, r, true, false, 0.0, _cf("walk", "fade_out_m", 0.7), NAN, NAN))
	segs.append(_hold(t, "hidden"))
	return t

## Walk to the landmark stand point at t_req, stand, and be settled again by t_back_by. false = skipped.
func wander(t_req: float, t_back_by: float) -> bool:
	if not bound or not routes.has("wander_out"):
		return false
	var st: Dictionary = _chain_end(t_req)
	if str(st.mode) != "kit":
		return false
	var t0: float = float(st.t)
	var out_r: Dictionary = routes["wander_out"]
	var back_r: Dictionary = routes["wander_back"]
	var blend: float = 0.0 if kit_is_walker else float(cfg.get("pose_blend_s", 0.5))
	var face: float = _heading_at(out_r, float(out_r.length))
	if bool(_c("wander", "face_landmark", true)):
		var hero: Dictionary = tile_json.get("hero", {})
		if hero.has("x"):
			var hp: Vector3 = tile.global_transform * Vector3(float(hero.x), 0.0, float(hero.z))
			face = atan2(hp.x - landmark_point.x, hp.z - landmark_point.z)
	# durations of the fixed parts (worst case with turns)
	var p_out: Dictionary = _profile(float(out_r.get("u_total", out_r.length)), true, true)
	var p_back: Dictionary = _profile(float(back_r.get("u_total", back_r.length)), true, true)
	var turn_max: float = float(clip_len.get("turn_180", 1.3))
	var back_need: float = float(p_back.T) + 2.0 * turn_max + blend
	var out_need: float = blend + turn_max + float(p_out.T) + turn_max
	if t_back_by - t0 < out_need + back_need + _cf("wander", "hold_min_s", 8.0):
		return false
	_truncate(t0)
	var t: float = t0
	if not kit_is_walker:
		t = _push({"kind": "xfade", "t0": t, "t1": t + blend, "to_kit": false, "pos": stand_pos, "yaw": stand_yaw})
	var h0: float = _heading_at(out_r, 0.0)
	if _needs_turn(stand_yaw, h0):
		t = _push(_turn_seg(t, stand_pos, stand_yaw, h0))
	var lp: Vector3 = _route_at(out_r, float(out_r.length))
	lp.y += _cf("walk", "stand_y_offset_m", 0.005)
	var end_h: float = _heading_at(out_r, float(out_r.length))
	t = _push(_walk_seg(t, out_r, true, true, 0.0, 0.0, NAN, lp.y))
	if _needs_turn(end_h, face):
		t = _push(_turn_seg(t, lp, end_h, face))
	# the walk back starts so that he is settled at t_back_by
	var back_h0: float = _heading_at(back_r, 0.0)
	var turn_a: float = float(_turn_seg(0.0, lp, face, back_h0).t1) if _needs_turn(face, back_h0) else 0.0
	var bh_end: float = _heading_at(back_r, float(back_r.length))
	var align: bool = rad_to_deg(absf(wrapf(stand_yaw - bh_end, -PI, PI))) <= _cf("walk", "align_max_deg", 50.0)
	var turn_b: float = 0.0 if align else float(_turn_seg(0.0, stand_pos, bh_end, stand_yaw).t1)
	var t_walk_back: float = t_back_by - blend - turn_b - float(p_back.T) - turn_a
	segs.append({"kind": "hold", "t0": t, "t1": t_walk_back, "mode": "stand", "pos": lp, "yaw": face})
	t = t_walk_back
	if turn_a > 0.0:
		t = _push(_turn_seg(t, lp, face, back_h0))
	t = _push(_walk_seg(t, back_r, true, true, 0.0, 0.0, stand_yaw if align else NAN, _stand_y()))
	if not align:
		t = _push(_turn_seg(t, stand_pos, bh_end, stand_yaw))
	if not kit_is_walker:
		t = _push({"kind": "xfade", "t0": t, "t1": t + blend, "to_kit": true, "pos": stand_pos, "yaw": stand_yaw})
	segs.append(_hold(t, "kit"))
	return true

## Bow (standing) or nod (seated / carrying) toward the camera. Only when he is settled or standing still.
func click(t: float) -> bool:
	if not bound:
		return false
	var i: int = _seg_index(t)
	var s: Dictionary = segs[i]
	if str(s.kind) != "hold" or not (str(s.mode) == "kit" or str(s.mode) == "stand"):
		return false
	var standing: bool = str(s.mode) == "stand" or kit_is_walker
	var pos: Vector3 = s.pos if str(s.mode) == "stand" else (base_pos if kit_is_walker else stand_pos)
	var yaw: float = float(s.yaw) if str(s.mode) == "stand" else (base_yaw if kit_is_walker else stand_yaw)
	var to_cam: Vector3 = camera.global_position - pos if camera != null else Vector3(0, 0, 1)
	var cam_yaw: float = atan2(to_cam.x, to_cam.z)
	var lim: float = deg_to_rad(_cf("click", "turn_max_deg", 45.0))
	var mode: String = str(s.mode)
	var t1_old: float = float(s.t1)
	_truncate(t)
	var t_end: float
	if standing:
		var face: float = yaw + clampf(wrapf(cam_yaw - yaw, -PI, PI), -lim, lim)
		var turn_s: float = _cf("click", "turn_s", 0.45)
		var dur: float = turn_s * 2.0 + float(clip_len.get("bow", 3.0))
		t_end = _push({"kind": "bow", "t0": t, "t1": t + dur, "pos": pos, "yaw0": yaw, "yaw1": face, "mode": mode})
		greeted.emit("bow", t)
	else:
		var hy: float = clampf(wrapf(cam_yaw - yaw, -PI, PI), -lim, lim)
		var ht: float = _cf("click", "head_turn_s", 0.5)
		var nods: float = float(_c("click", "nod_count", 2)) * _cf("click", "nod_cycle_s", 0.75)
		var dur2: float = ht * 2.0 + nods + _cf("click", "nod_hold_s", 0.25) * 2.0
		t_end = _push({"kind": "nod", "t0": t, "t1": t + dur2, "head_yaw": hy})
		greeted.emit("nod", t)
	var h: Dictionary = _hold(t_end, mode)
	if mode == "stand":
		h["pos"] = pos
		h["yaw"] = yaw
		h["t1"] = t1_old
		segs.append(h)
		# the rest of a wander (walk back) was cut by the truncate: re-queue it from its old start
		if t1_old < INF:
			_requeue_wander_back(t1_old)
	else:
		segs.append(h)
	return true

func _requeue_wander_back(t_walk_back: float) -> void:
	var back_r: Dictionary = routes.get("wander_back", {})
	if back_r.is_empty():
		return
	var last: Dictionary = segs[segs.size() - 1]
	var lp: Vector3 = last.pos
	var face: float = float(last.yaw)
	var t: float = maxf(t_walk_back, float(last.t0))
	last["t1"] = t
	var back_h0: float = _heading_at(back_r, 0.0)
	if _needs_turn(face, back_h0):
		t = _push(_turn_seg(t, lp, face, back_h0))
	var bh_end: float = _heading_at(back_r, float(back_r.length))
	var align: bool = rad_to_deg(absf(wrapf(stand_yaw - bh_end, -PI, PI))) <= _cf("walk", "align_max_deg", 50.0)
	t = _push(_walk_seg(t, back_r, true, true, 0.0, 0.0, stand_yaw if align else NAN, _stand_y()))
	if not align:
		t = _push(_turn_seg(t, stand_pos, bh_end, stand_yaw))
	if not kit_is_walker:
		t = _push({"kind": "xfade", "t0": t, "t1": t + float(cfg.get("pose_blend_s", 0.5)), "to_kit": true, "pos": stand_pos, "yaw": stand_yaw})
	segs.append(_hold(t, "kit"))

## The tile stays empty (he is on the road).
func hide_now(t: float) -> void:
	if not bound:
		return
	_truncate(t)
	segs.append(_hold(t, "hidden"))

## Jump straight to the settled kit pose (catch-up, first launch).
func settle_now(t: float) -> void:
	if not bound:
		return
	_truncate(t)
	segs.append(_hold(t, "kit"))

func night_doze(t: float) -> void:
	doze_on = t
	doze_off = INF

## Walks into the tent (role "shelter") and hides; false when the tile has no reachable tent (he keeps dozing).
func tent_in(t_req: float) -> bool:
	if not bound or not routes.has("tent_in"):
		return false
	var st: Dictionary = _chain_end(t_req)
	if str(st.mode) != "kit":
		return false
	var t: float = float(st.t)
	_truncate(t)
	var r: Dictionary = routes["tent_in"]
	if not kit_is_walker:
		t = _push({"kind": "xfade", "t0": t, "t1": t + float(cfg.get("pose_blend_s", 0.5)), "to_kit": false, "pos": stand_pos, "yaw": stand_yaw})
	var h0: float = _heading_at(r, 0.0)
	if _needs_turn(stand_yaw, h0):
		t = _push(_turn_seg(t, stand_pos, stand_yaw, h0))
	t = _push(_walk_seg(t, r, true, true, 0.0, _cf("tent", "fade_out_m", 0.45), NAN, NAN))
	segs.append(_hold(t, "tent"))
	return true

## Morning: out of the tent and back to the spot, or just awake.
func night_end(t_req: float) -> float:
	doze_off = t_req
	if not bound:
		return t_req
	var st: Dictionary = _chain_end(t_req)
	if str(st.mode) != "tent" or not routes.has("tent_out"):
		return t_req
	var t: float = float(st.t)
	_truncate(t)
	var r: Dictionary = routes["tent_out"]
	t = _push(_walk_seg(t, r, true, true, _cf("tent", "fade_in_m", 0.45), 0.0, NAN, _stand_y()))
	var eh: float = _heading_at(r, float(r.length))
	if _needs_turn(eh, stand_yaw):
		t = _push(_turn_seg(t, stand_pos, eh, stand_yaw))
	if not kit_is_walker:
		t = _push({"kind": "xfade", "t0": t, "t1": t + float(cfg.get("pose_blend_s", 0.5)), "to_kit": true, "pos": stand_pos, "yaw": stand_yaw})
	segs.append(_hold(t, "kit"))
	return t

## Double-click: the camera eases toward him, holds, returns. false while a focus is running.
func focus(t: float) -> bool:
	if not bound or camera == null:
		return false
	if not focus_seg.is_empty() and t < float(focus_seg.t_end):
		return false
	var ei: float = _cf("focus", "ease_in_s", 1.4)
	var hold: float = _cf("focus", "hold_s", 8.0)
	var eo: float = _cf("focus", "ease_out_s", 1.6)
	var attrs: CameraAttributesPractical = camera.attributes as CameraAttributesPractical
	var fit: Dictionary = tile.get("camera_fit")
	focus_seg = {"t0": t, "t_hold": t + ei, "t_out": t + ei + hold, "t_end": t + ei + hold + eo, "xf": camera.global_transform,
		"focus": float(fit.get("focus_distance", 25.0))}
	if attrs != null:
		focus_seg["dof"] = [attrs.dof_blur_far_distance, attrs.dof_blur_far_transition, attrs.dof_blur_near_distance, attrs.dof_blur_near_transition]
	return true

func cancel_focus() -> void:
	if focus_seg.is_empty():
		return
	_camera_restore()
	focus_seg = {}

## Arrival duration from now (for a director that wants him settled at a given time).
func arrive_duration() -> float:
	if not routes.has("arrival"):
		return 1.0
	var r: Dictionary = routes["arrival"]
	var d: float = float(_profile(float(r.get("u_total", r.length)), false, true).T)
	if not kit_is_walker:
		d += float(cfg.get("pose_blend_s", 0.5))
	return d

# ------------------------------------------------------------------ input
## Screen-space hit on the figure currently shown.
func hit_test(screen_pos: Vector2) -> bool:
	var r: Rect2 = figure_rect()
	return r.size.x > 0.0 and r.has_point(screen_pos)

func figure_rect() -> Rect2:
	if not bound or camera == null or last_frame.is_empty():
		return Rect2()
	var rig: Node3D = _shown_rig()
	if rig == null:
		return Rect2()
	var pts: PackedVector3Array = _figure_points(rig)
	if pts.is_empty():
		return Rect2()
	var mn: Vector2 = Vector2(INF, INF)
	var mx: Vector2 = -mn
	for w: Vector3 in pts:
		if camera.is_position_behind(w):
			return Rect2()
		var p: Vector2 = camera.unproject_position(w)
		mn = mn.min(p)
		mx = mx.max(p)
	# joints sit inside the body: widen by a share of the height, plus the click margin
	var grow: float = (mx.y - mn.y) * 0.12 + _cf("click", "pad_px", 10.0)
	return Rect2(mn - Vector2.ONE * grow, mx - mn + Vector2.ONE * grow * 2.0)

func _shown_rig() -> Node3D:
	if bool(last_frame.get("w_show", false)) and float(last_frame.get("w_alpha", 0.0)) > 0.3:
		return walker
	if float(last_frame.get("k_alpha", 0.0)) > 0.3:
		return kit_rig
	return null

## World positions of the joints that outline him (head top, hands, feet, hips) on the rig's drawn skeleton.
func _figure_points(rig: Node3D) -> PackedVector3Array:
	var sk: Skeleton3D = _rig_skeleton(rig)
	var out: PackedVector3Array = PackedVector3Array()
	if sk == null:
		return out
	for suffix: String in ["HeadTop_End", "Head", "Hips", "LeftHand", "RightHand", "LeftToe_End", "RightToe_End", "LeftFoot", "RightFoot", "LeftShoulder", "RightShoulder"]:
		var b: int = _bone_suffix(sk, suffix)
		if b >= 0:
			out.append(sk.global_transform * sk.get_bone_global_pose(b).origin)
	return out

func _rig_skeleton(rig: Node3D) -> Skeleton3D:
	if rig == walker:
		return w_skel
	var sa: Variant = rig.get("seated_actor")
	if sa != null:
		return (sa as RefCounted).get("skeleton") as Skeleton3D
	var cp: Node3D = rig.get("carrying_pose") as Node3D
	if cp != null:
		# the carrying model hangs under his character node (pose_model), not under the pose module
		var pm: Node3D = cp.get("pose_model") as Node3D
		if pm != null:
			var sks: Array[Node] = pm.find_children("*", "Skeleton3D", true, false)
			if not sks.is_empty():
				return sks[0] as Skeleton3D
	for n: Node in rig.find_children("*", "Skeleton3D", true, false):
		if (n as Skeleton3D).is_visible_in_tree():
			return n as Skeleton3D
	return null

## Left click on him: bow / nod. Double click anywhere: camera focus, only with dev_focus (the director sets it with
## --lshu-dev; Carlos 2026-09-27: players' double clicks must not push the camera in — kids click fast, and the act is a
## screensaver). Without it a double click is two clicks: the second one on him is ignored while he bows.
## Returns true when handled.
func handle_input(event: InputEvent, t: float) -> bool:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return false
	if mb.double_click and dev_focus:
		return focus(t)
	if hit_test(mb.position):
		return click(t)
	return false

# ------------------------------------------------------------------ evaluation
func _doze_w(t: float) -> float:
	if doze_on == INF:
		return 0.0
	var b: float = _cf("doze", "blend_s", 2.0)
	var w: float = smoothstep(doze_on, doze_on + b, t)
	if doze_off != INF:
		w *= 1.0 - smoothstep(doze_off, doze_off + b, t)
	return w

## Head droop of the doze at t (0 when he is not dozing).
func _doze(t: float) -> float:
	var w: float = _doze_w(t)
	return w * _doze_pitch(t) if w > 0.0 else 0.0

func _doze_pitch(t: float) -> float:
	var period: float = _cf("doze", "period_s", 7.0)
	var lift: float = _cf("doze", "lift_frac", 0.15)
	var u: float = fposmod(t - doze_on, period) / period
	var droop: float
	if u < 1.0 - lift:
		droop = smoothstep(0.0, 1.0, u / (1.0 - lift))
	else:
		droop = 1.0 - smoothstep(0.0, 1.0, (u - (1.0 - lift)) / lift)
	return deg_to_rad(lerpf(_cf("doze", "rest_deg", 4.0), _cf("doze", "droop_deg", 22.0), droop))

func _frame() -> Dictionary:
	return {"phase": "", "w_show": false, "w_alpha": 1.0, "w_pos": Vector3.ZERO, "w_yaw": 0.0, "w_ground": 0.0,
		"w_a": "idle", "w_ta": 0.0, "w_b": "idle", "w_tb": 0.0, "w_mix": 0.0, "k_alpha": 1.0, "head_yaw": 0.0, "head_pitch": 0.0}

func _idle_t() -> float:
	return _anim_t + idle_offset

func _eval(t: float) -> Dictionary:
	var fr: Dictionary = _frame()
	if segs.is_empty():
		return fr
	var s: Dictionary = segs[_seg_index(t)]
	var kind: String = str(s.kind)
	fr.phase = kind
	var u: float = clampf((t - float(s.t0)) / maxf(float(s.t1) - float(s.t0), 1e-6), 0.0, 1.0) if float(s.t1) < INF and float(s.t0) > -INF else 0.0
	match kind:
		"hold":
			var mode: String = str(s.mode)
			fr.phase = mode
			if mode == "kit":
				fr.k_alpha = 1.0
				fr.head_pitch = _doze(t)
				if fr.head_pitch > 0.0:
					fr.phase = "doze"
			elif mode == "stand":
				fr.k_alpha = 0.0
				fr.w_show = true
				fr.w_pos = s.pos
				fr.w_yaw = float(s.yaw)
				fr.w_a = "idle"
				fr.w_ta = _idle_t()
			else:
				fr.k_alpha = 0.0
		"walk":
			_eval_walk(s, t, fr)
		"turn":
			fr.k_alpha = 0.0
			fr.w_show = true
			fr.w_pos = s.pos
			fr.w_pos.y = _stand_y() if (s.pos as Vector3).distance_to(stand_pos) < 0.01 else (s.pos as Vector3).y
			var e: float = smoothstep(0.0, 1.0, u)
			fr.w_yaw = lerp_angle(float(s.yaw0), float(s.yaw1), e)
			if bool(s.anim):
				var dur: float = float(s.t1) - float(s.t0)
				var len180: float = float(clip_len["turn_180"])
				fr.w_a = "turn_180"
				fr.w_ta = u * len180
				fr.w_b = "idle"
				fr.w_tb = _idle_t()
				var bl: float = _cf("turn", "anim_blend_s", 0.12)
				var tt: float = t - float(s.t0)
				fr.w_mix = 1.0 - minf(smoothstep(0.0, bl, tt), smoothstep(0.0, bl, dur - tt))
			else:
				fr.w_a = "idle"
				fr.w_ta = _idle_t()
		"xfade":
			var w: float = smoothstep(0.0, 1.0, u)
			var to_kit: bool = bool(s.to_kit)
			fr.k_alpha = w if to_kit else 1.0 - w
			fr.w_show = true
			fr.w_alpha = 1.0 - fr.k_alpha
			fr.w_pos = s.pos
			fr.w_yaw = float(s.yaw)
			fr.w_a = "idle"
			fr.w_ta = _idle_t()
		"fade":
			var a: float = lerpf(float(s.a0), float(s.a1), smoothstep(0.0, 1.0, u))
			if bool(s.get("walker", false)) and not kit_is_walker:
				fr.k_alpha = 0.0
				fr.w_show = true
				fr.w_alpha = a
				fr.w_pos = s.pos
				fr.w_yaw = float(s.yaw)
				fr.w_ta = _idle_t()
			else:
				fr.k_alpha = a
		"bow":
			fr.k_alpha = 0.0
			fr.w_show = true
			fr.w_pos = s.pos
			fr.w_pos.y = _stand_y() if str(s.mode) == "kit" else (s.pos as Vector3).y
			var turn_s: float = _cf("click", "turn_s", 0.45)
			var bow_len: float = float(clip_len.get("bow", 3.0))
			var tt2: float = t - float(s.t0)
			if tt2 < turn_s:
				fr.w_yaw = lerp_angle(float(s.yaw0), float(s.yaw1), smoothstep(0.0, turn_s, tt2))
				fr.w_a = "idle"
				fr.w_ta = _idle_t()
			elif tt2 < turn_s + bow_len:
				var bt: float = tt2 - turn_s
				fr.w_yaw = float(s.yaw1)
				fr.w_a = "idle"
				fr.w_ta = _idle_t()
				fr.w_b = "bow"
				fr.w_tb = bt
				fr.w_mix = minf(smoothstep(0.0, _cf("click", "bow_blend_in_s", 0.25), bt), 1.0 - smoothstep(bow_len - _cf("click", "bow_blend_out_s", 0.35), bow_len, bt))
			else:
				fr.w_yaw = lerp_angle(float(s.yaw1), float(s.yaw0), smoothstep(turn_s + bow_len, 2.0 * turn_s + bow_len, tt2))
				fr.w_a = "idle"
				fr.w_ta = _idle_t()
			if str(s.mode) == "stand":
				fr.k_alpha = 0.0
		"nod":
			fr.k_alpha = 1.0
			var ht: float = _cf("click", "head_turn_s", 0.5)
			var hold: float = _cf("click", "nod_hold_s", 0.25)
			var cyc: float = _cf("click", "nod_cycle_s", 0.75)
			var n: int = int(_c("click", "nod_count", 2))
			var tt3: float = t - float(s.t0)
			var dur3: float = float(s.t1) - float(s.t0)
			var turn_w: float = minf(smoothstep(0.0, ht, tt3), 1.0 - smoothstep(dur3 - ht, dur3, tt3))
			fr.head_yaw = float(s.head_yaw) * turn_w
			var nt: float = tt3 - ht - hold
			if nt > 0.0 and nt < cyc * float(n):
				var ph: float = nt / cyc
				fr.head_pitch = deg_to_rad(_cf("click", "nod_deg", 16.0)) * pow(sin(PI * ph), 2.0)
			fr.head_pitch += _doze(t) * (1.0 - turn_w)
	return fr

func _eval_walk(s: Dictionary, t: float, fr: Dictionary) -> void:
	var r: Dictionary = s.route
	var prof: Dictionary = s.prof
	var tau: float = t - float(s.t0)
	var sd: float = _u_to_s(r, _prof_s(prof, tau)) if r.has("u") else _prof_s(prof, tau)
	var L: float = float(r.length)
	var p: Vector3 = _route_at(r, sd)
	fr.k_alpha = 0.0
	fr.w_show = true
	fr.w_pos = p
	var yaw: float = _heading_at(r, sd)
	var ye: float = float(s.yaw_end)
	if not is_nan(ye):
		yaw = lerp_angle(yaw, ye, smoothstep(L - _cf("walk", "align_m", 0.55), L, sd))
	fr.w_yaw = yaw
	var a: float = 1.0
	# a fade never runs longer than the route (a short walk into the tent still starts fully visible)
	if float(s.fade_in) > 0.0:
		a *= smoothstep(0.0, minf(float(s.fade_in), L), sd)
	if float(s.fade_out) > 0.0:
		a *= smoothstep(0.0, minf(float(s.fade_out), L), L - sd)
	fr.w_alpha = a
	fr.w_a = "walk"
	fr.w_ta = float(s.phase0) + sd / maxf(stance_speed, 1e-4)
	# idle blends at the ends
	var T: float = float(prof.T)
	var mix: float = 0.0
	if bool(s.from_rest):
		mix = maxf(mix, 1.0 - smoothstep(0.0, _cf("walk", "blend_in_s", 0.35), tau))
	if bool(s.to_rest):
		mix = maxf(mix, smoothstep(T - _cf("walk", "blend_out_s", 0.45), T, tau))
	fr.w_b = "idle"
	fr.w_tb = _idle_t()
	fr.w_mix = mix
	# root height: planted sole on the support (w_ground 1) or a fixed standing height at the ends
	var off: float = _cf("walk", "stand_y_offset_m", 0.005)
	fr.w_ground = 1.0
	fr["w_yfix"] = p.y + off
	if bool(s.from_rest):
		fr.w_ground = minf(fr.w_ground, smoothstep(0.0, _cf("walk", "blend_in_s", 0.35), tau))
	if bool(s.to_rest) and not is_nan(float(s.y_end)):
		var e: float = smoothstep(T - _cf("walk", "blend_out_s", 0.45), T, tau)
		fr.w_ground = minf(fr.w_ground, 1.0 - e)
		fr["w_yfix"] = lerpf(p.y + off, float(s.y_end), e)
	fr["s"] = sd

# ------------------------------------------------------------------ apply
func _on_character_tick(anim_t: float) -> void:
	_anim_t = anim_t
	if not bound or not is_same(character.get("tile_data"), tile_json) or character.get("active") != kit_rig:
		return
	_apply(_eval(_t))

## Every frame, with the caller's clock.
func tick(t: float) -> void:
	_t = t
	if not bound:
		return
	if not is_same(character.get("tile_data"), tile_json) or character.get("active") != kit_rig:
		return
	var fr: Dictionary = _eval(t)
	_apply(fr)
	_apply_camera(t)
	if str(fr.phase) != _phase:
		_phase = str(fr.phase)
		phase_changed.emit(_phase, t)

func _apply(fr: Dictionary) -> void:
	last_frame = fr
	var head: bool = absf(float(fr.head_yaw)) > 1e-5 or absf(float(fr.head_pitch)) > 1e-5
	if kit_is_walker:
		if bool(fr.w_show):
			_kit_dirty = true
			_drive_walker(fr)
		else:
			if _kit_dirty:
				_restore_kit()
			_set_alpha(kit_rig, float(fr.k_alpha))
			if head:
				_pose_walker("idle", _idle_t(), "idle", 0.0, 0.0)
				_head_overlay(w_skel, kit_rig.get("character") as Node3D, float(fr.head_yaw), float(fr.head_pitch))
		return
	_set_alpha(kit_rig, float(fr.k_alpha))
	if head and float(fr.k_alpha) > 0.0:
		var kskel: Skeleton3D = _kit_reset_pose()
		if kskel != null:
			_head_overlay(kskel, kit_rig.get("character") as Node3D, float(fr.head_yaw), float(fr.head_pitch))
	if bool(fr.w_show):
		walker.position = Vector3.ZERO
		_drive_walker(fr)
	else:
		walker.position = PARK_OFFSET

func _restore_kit() -> void:
	_kit_dirty = false
	var kc: Node3D = kit_rig.get("character")
	kc.global_position = base_pos
	kc.rotation.y = base_yaw
	var dec: Decal = kit_rig.get("contact_decal") as Decal
	if dec != null:
		dec.global_position = base_decal

## Re-samples the kit rig's own idle at the scene clock (so overlays never accumulate) and returns its skeleton.
func _kit_reset_pose() -> Skeleton3D:
	var sa: Variant = kit_rig.get("seated_actor")
	if sa != null:
		(sa as RefCounted).call("set_time", _anim_t)
		return (sa as RefCounted).get("skeleton") as Skeleton3D
	var cp: Node3D = kit_rig.get("carrying_pose") as Node3D
	if cp != null:
		cp.call("set_time", _anim_t)
		return _rig_skeleton(kit_rig)
	return null

func _drive_walker(fr: Dictionary) -> void:
	var ch: Node3D = walker.get("character")
	_pose_walker(str(fr.w_a), float(fr.w_ta), str(fr.w_b), float(fr.w_tb), float(fr.w_mix))
	var p: Vector3 = fr.w_pos
	ch.global_position = p
	ch.rotation.y = float(fr.w_yaw)
	if float(fr.w_ground) > 0.0 and not sole.is_empty():
		_ground_feet(ch, p, fr)
	if absf(float(fr.head_yaw)) > 1e-5 or absf(float(fr.head_pitch)) > 1e-5:
		_head_overlay(w_skel, ch, float(fr.head_yaw), float(fr.head_pitch))
	_set_alpha(walker, float(fr.w_alpha))
	var dec: Decal = walker.get("contact_decal") as Decal
	if dec != null:
		var gp: Vector3 = ch.global_position
		var gy: float = support_at(gp.x, gp.z, gp.y + 0.1)
		dec.global_position = Vector3(gp.x, gy + dec.size.y * 0.3, gp.z)
	if not kit_is_walker:
		_copy_light_state()

## Feet on what is drawn under them (the act-1 footing rule, per frame, no state): the root follows the planted foot
## over the lowest support (the other planted foot then only ever needs to come up), and a two-bone leg IK raises any
## foot that would sink (the uphill foot on a slope, a swing foot over a bump). Planted = low in the clip itself.
func _ground_feet(ch: Node3D, p: Vector3, fr: Dictionary) -> void:
	w_skel.force_update_all_bone_transforms()
	var feet: Array = feet_state(false)
	if feet.size() != 2:
		return
	var wg: float = float(fr.w_ground)
	var lo: float = _cf("walk", "contact_lo_m", 0.012)
	var hi: float = _cf("walk", "contact_hi_m", 0.04)
	var lim: float = _cf("walk", "ground_adjust_max_m", 0.15)
	var g: Array[float] = []
	var c: Array[float] = []
	for f: int in 2:
		var rec: Array = feet[f]
		var gap: float = (rec[0] as Vector3).y - float(rec[1])
		# a support far off what the route says is under him (a hole, a roof edge) is not ground to stand on
		var trust: float = 1.0 - smoothstep(lim * 1.5, lim * 2.5, absf(gap - float(rec[2])))
		g.append(clampf(gap, -lim * 2.0, lim * 2.0))
		c.append((1.0 - smoothstep(lo, hi, float(rec[2]))) * trust)
	var gmin: float = minf(g[0], g[1])
	var root_gap: float = clampf(maxf(c[0] * g[0] + (1.0 - c[0]) * gmin, c[1] * g[1] + (1.0 - c[1]) * gmin), -lim, lim)
	var y_fix: float = float(fr.get("w_yfix", p.y))
	var y_ground: float = p.y - root_gap
	var y: float = lerpf(y_fix, y_ground, wg)
	ch.global_position.y = y
	fr["ground"] = {"route_y": p.y, "root_gap": root_gap, "g": [g[0], g[1]], "c": [c[0], c[1]], "y": y,
		"feet": [(feet[0] as Array)[0], (feet[1] as Array)[0]], "support": [(feet[0] as Array)[1], (feet[1] as Array)[1]]}
	if not bool(_c("walk", "leg_ik", true)):
		return
	for f2: int in 2:
		var resid: float = g[f2] + (y - p.y)     # this foot's gap with the root where it is now
		var rec2: Array = feet[f2]
		if float(rec2[3]) > -INF and c[f2] < 1.0:
			# a swing foot already clears a step it is about to reach (continuous as the foot plants: c -> 1)
			var ahead_gap: float = float(rec2[2]) + y - float(rec2[3])
			resid = minf(resid, lerpf(resid, ahead_gap, 1.0 - c[f2]))
		if resid < -0.0005:
			_leg_ik(f2, minf(-resid, _cf("walk", "ik_lift_max_m", 0.3)) * wg)

var _legs: Array = []

func _leg_ik(side: int, lift_world: float) -> void:
	if _legs.is_empty():
		for nm: String in ["Left", "Right"]:
			_legs.append([_bone_suffix(w_skel, nm + "UpLeg"), _bone_suffix(w_skel, nm + "Leg"), _bone_suffix(w_skel, nm + "Foot")])
	var leg: Array = _legs[side]
	var b_up: int = leg[0]
	var b_knee: int = leg[1]
	var b_foot: int = leg[2]
	if b_up < 0 or b_knee < 0 or b_foot < 0:
		return
	var sk: Skeleton3D = w_skel
	var hip: Transform3D = sk.get_bone_global_pose(b_up)
	var knee: Transform3D = sk.get_bone_global_pose(b_knee)
	var ankle: Transform3D = sk.get_bone_global_pose(b_foot)
	var target: Vector3 = ankle.origin + sk.global_basis.inverse() * Vector3(0.0, lift_world, 0.0)
	var a: float = hip.origin.distance_to(knee.origin)
	var b: float = knee.origin.distance_to(ankle.origin)
	var line: Vector3 = target - hip.origin
	if line.length() < 0.0001 or a < 0.0001 or b < 0.0001:
		return
	var dist: float = clampf(line.length(), absf(a - b) + 0.0001, a + b - 0.0001)
	var dir: Vector3 = line.normalized()
	var bend: Vector3 = (knee.origin - hip.origin) - dir * (knee.origin - hip.origin).dot(dir)
	if bend.length() < 0.0001:
		bend = hip.basis.z - dir * hip.basis.z.dot(dir)
	bend = bend.normalized()
	var along: float = (a * a - b * b + dist * dist) / (2.0 * dist)
	var height: float = sqrt(maxf(a * a - along * along, 0.0))
	var knee_target: Vector3 = hip.origin + dir * along + bend * height
	var r1: Quaternion = Quaternion((knee.origin - hip.origin).normalized(), (knee_target - hip.origin).normalized())
	hip.basis = Basis(r1) * hip.basis
	sk.set_bone_global_pose(b_up, hip)
	sk.force_update_all_bone_transforms()
	var pk: Transform3D = sk.get_bone_global_pose(b_knee)
	var pa: Transform3D = sk.get_bone_global_pose(b_foot)
	var r2: Quaternion = Quaternion((pa.origin - pk.origin).normalized(), (target - pk.origin).normalized())
	pk.basis = Basis(r2) * pk.basis
	sk.set_bone_global_pose(b_knee, pk)
	sk.force_update_all_bone_transforms()
	pa = sk.get_bone_global_pose(b_foot)
	pa.basis = ankle.basis
	sk.set_bone_global_pose(b_foot, pa)
	sk.force_update_all_bone_transforms()

func _copy_light_state() -> void:
	var km: ShaderMaterial = kit_rig.get("rim_material") as ShaderMaterial
	var wm: ShaderMaterial = walker.get("rim_material") as ShaderMaterial
	if km != null and wm != null and km.shader != null:
		for u: Dictionary in km.shader.get_shader_uniform_list():
			var nm: StringName = StringName(str(u.get("name", "")))
			if nm == RIM_FADE:
				continue   # each rig's own opacity (_set_alpha), not light state
			wm.set_shader_parameter(nm, km.get_shader_parameter(nm))
	var kf: OmniLight3D = kit_rig.get("fill") as OmniLight3D
	var wf: OmniLight3D = walker.get("fill") as OmniLight3D
	if kf != null and wf != null:
		wf.visible = kf.visible
		wf.light_energy = kf.light_energy
		wf.light_color = kf.light_color
		var kc: Node3D = kit_rig.get("character")
		var wc: Node3D = walker.get("character")
		wf.global_position = wc.global_position + (kf.global_position - kc.global_position)

## Additive head / neck / upper-spine rotation: yaw about up (toward the camera), pitch about his right axis (nod).
func _head_overlay(skel: Skeleton3D, char_node: Node3D, yaw: float, pitch: float) -> void:
	skel.force_update_all_bone_transforms()
	var sk_inv: Basis = skel.global_basis.orthonormalized().inverse()
	var up_s: Vector3 = (sk_inv * Vector3.UP).normalized()
	var right_s: Vector3 = (sk_inv * char_node.global_basis.x.normalized()).normalized()
	var ys: Dictionary = _c("click", "yaw_split", {"Spine2": 0.2, "Neck": 0.35, "Head": 0.45})
	var ps: Dictionary = _c("click", "pitch_split", {"Neck": 0.4, "Head": 0.6})
	var chain: Array = []
	for nm: String in ["Spine2", "Neck", "Head"]:
		var b: int = _bone_suffix(skel, nm)
		if b < 0:
			continue
		var parent: int = skel.get_bone_parent(b)
		var pb: Basis = skel.get_bone_global_pose(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
		chain.append([b, pb, float(ys.get(nm, 0.0)), float(ps.get(nm, 0.0))])
	for rec: Array in chain:
		var b2: int = rec[0]
		var pb2: Basis = rec[1]
		var rot: Basis = Basis(up_s, yaw * float(rec[2])) * Basis(right_s, pitch * float(rec[3]))
		var local_r: Basis = (pb2.inverse() * rot * pb2).orthonormalized()
		skel.set_bone_pose_rotation(b2, (Quaternion(local_r) * skel.get_bone_pose_rotation(b2)).normalized())

# ------------------------------------------------------------------ opacity
func _rig_geoms(rig: Node3D) -> Array:
	var key: int = rig.get_instance_id()
	if not _geoms.has(key):
		var arr: Array = []
		for n: Node in rig.find_children("*", "GeometryInstance3D", true, false):
			arr.append(n)
		_geoms[key] = arr
	return _geoms[key]

## Opacity of a whole rig, as a dither (alpha hash) fade: while 0 < a < 1 every standard material of the rig is swapped
## for a copy in alpha-hash mode with albedo alpha a (depth and shadows stay correct, the outline shell and the body
## fade together, no see-through of back faces); at a = 1 the rig's own materials come back untouched, so the settled
## look is exactly the approved one. Materials that are not standard ones (the flower petals) use the instance
## transparency. The contact shadow is scaled with a, and so is the rig's rim pass (rim_fade): the fade copies keep
## the rim next_pass, an additive pass the dither does not discard, so at a = 0 it drew his outline alone.
func _set_alpha(rig: Node3D, a: float) -> void:
	if rig == null:
		return
	a = clampf(a, 0.0, 1.0)
	var key: int = rig.get_instance_id()
	var dec: Decal = rig.get("contact_decal") as Decal
	if dec != null:
		var base: float = float(character.call("_g", ["character", "contact", "strength"], 0.5))
		dec.modulate = Color(1, 1, 1, base * a)
	var rm: ShaderMaterial = rig.get("rim_material") as ShaderMaterial
	if rm != null:
		var rf: float = 1.0 if a >= 0.999 else a   # solid: exactly the approved rim, like the materials below
		var cur: Variant = rm.get_shader_parameter(RIM_FADE)
		if (1.0 if cur == null else float(cur)) != rf:
			rm.set_shader_parameter(RIM_FADE, rf)
	if _alpha.has(key) and absf(float(_alpha[key]) - a) < 0.0005:
		return
	_alpha[key] = a
	var solid: bool = a >= 0.999
	for g: Variant in _rig_geoms(rig):
		var gi: GeometryInstance3D = g as GeometryInstance3D
		if not is_instance_valid(gi):
			continue
		var gk: int = gi.get_instance_id()
		if solid:
			_fade_restore(gi)
			gi.transparency = 0.0
			continue
		if not _fade_swap(gi, key):
			# not a standard material: instance transparency, no shadow below half opacity
			if not _shadow_orig.has(gk):
				_shadow_orig[gk] = gi.cast_shadow
			gi.transparency = 1.0 - a
			gi.cast_shadow = _shadow_orig[gk] if a >= 0.5 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for m: Variant in _fade_mats.keys():
		var rec: Array = _fade_mats[m]
		if int(rec[1]) == key:
			var d: BaseMaterial3D = rec[0]
			d.albedo_color.a = float(rec[2]) * a

## Swaps a geometry's materials for their fade copies (once). false when it has a non-standard material.
func _fade_swap(gi: GeometryInstance3D, rig_key: int) -> bool:
	var gk: int = gi.get_instance_id()
	if _faded.has(gk):
		return bool((_faded[gk] as Dictionary).get("ok", false))
	var mi: MeshInstance3D = gi as MeshInstance3D
	if mi == null or mi.mesh == null:
		_faded[gk] = {"ok": false, "gi": gi}
		return false
	var rec: Dictionary = {"ok": true, "gi": gi, "override": mi.material_override, "surfaces": []}
	if mi.material_override != null:
		var d0: Material = _fade_copy(mi.material_override, rig_key)
		if d0 == null:
			_faded[gk] = {"ok": false, "gi": gi}
			return false
		mi.material_override = d0
	else:
		var saved: Array = []
		var copies: Array = []
		for sfc: int in mi.mesh.get_surface_count():
			saved.append(mi.get_surface_override_material(sfc))
			var d1: Material = _fade_copy(mi.get_active_material(sfc), rig_key)
			if d1 == null:
				_faded[gk] = {"ok": false, "gi": gi}
				return false
			copies.append(d1)
		for sfc2: int in copies.size():
			mi.set_surface_override_material(sfc2, copies[sfc2])
		rec["surfaces"] = saved
	_faded[gk] = rec
	return true

func _fade_restore(gi: GeometryInstance3D) -> void:
	var gk: int = gi.get_instance_id()
	if not _faded.has(gk):
		return
	var rec: Dictionary = _faded[gk]
	_faded.erase(gk)
	if _shadow_orig.has(gk):
		gi.cast_shadow = _shadow_orig[gk]
	if not bool(rec.get("ok", false)):
		return
	var mi: MeshInstance3D = gi as MeshInstance3D
	if rec.get("override") != null:
		mi.material_override = rec.override
	else:
		var saved: Array = rec.surfaces
		for sfc: int in saved.size():
			mi.set_surface_override_material(sfc, saved[sfc] as Material)

func _fade_copy(m: Material, rig_key: int) -> Material:
	if not m is BaseMaterial3D:
		return null
	var k: String = "%d:%d" % [rig_key, m.get_instance_id()]
	if _fade_mats.has(k):
		return (_fade_mats[k] as Array)[0]
	var d: BaseMaterial3D = (m as BaseMaterial3D).duplicate() as BaseMaterial3D
	d.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	d.alpha_hash_scale = _cf("walk", "fade_hash_scale", 1.0)
	# with MSAA the dither is spread over the pixel's samples (a finer grain)
	d.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE if bool(_c("walk", "fade_alpha_to_coverage", true)) else BaseMaterial3D.ALPHA_ANTIALIASING_OFF
	_fade_mats[k] = [d, rig_key, (m as BaseMaterial3D).albedo_color.a]
	return d

# ------------------------------------------------------------------ camera focus
func _figure_center() -> Vector3:
	var rig: Node3D = walker if bool(last_frame.get("w_show", false)) else kit_rig
	var pts: PackedVector3Array = _figure_points(rig)
	if pts.is_empty():
		var hm: float = float(character.get("height_m"))
		return (rig.get("character") as Node3D).global_position + Vector3.UP * hm * _cf("focus", "chest_frac", 0.55)
	var lo: Vector3 = pts[0]
	var hi: Vector3 = pts[0]
	for w: Vector3 in pts:
		lo = lo.min(w)
		hi = hi.max(w)
	return (lo + hi) * 0.5

func _apply_camera(t: float) -> void:
	if focus_seg.is_empty() or camera == null:
		return
	if t >= float(focus_seg.t_end) or t < float(focus_seg.t0):
		_camera_restore()
		if t >= float(focus_seg.t_end):
			focus_seg = {}
		return
	var e: float
	if t < float(focus_seg.t_hold):
		e = smoothstep(float(focus_seg.t0), float(focus_seg.t_hold), t)
	elif t < float(focus_seg.t_out):
		e = 1.0
	else:
		e = 1.0 - smoothstep(float(focus_seg.t_out), float(focus_seg.t_end), t)
	var xf: Transform3D = focus_seg.xf
	var back: Vector3 = xf.basis.z.normalized()
	var chest: Vector3 = _figure_center()
	var d_base: float = (chest - xf.origin).dot(-back)
	var target: Vector3 = chest + back * d_base * _cf("focus", "zoom", 0.42)
	var eye: Vector3 = xf.origin.lerp(target, e)
	camera.global_transform = Transform3D(xf.basis, eye)
	var attrs: CameraAttributesPractical = camera.attributes as CameraAttributesPractical
	if attrs != null and focus_seg.has("dof"):
		var dof: Array = focus_seg.dof
		var f0: float = float(focus_seg.focus)
		var fd: float = (chest - target).dot(-back)
		var k: float = fd / maxf(f0, 0.01)
		attrs.dof_blur_far_distance = lerpf(float(dof[0]), fd + (float(dof[0]) - f0) * k, e)
		attrs.dof_blur_far_transition = lerpf(float(dof[1]), float(dof[1]) * k, e)
		attrs.dof_blur_near_distance = maxf(0.05, lerpf(float(dof[2]), fd - (f0 - float(dof[2])) * k, e))
		attrs.dof_blur_near_transition = lerpf(float(dof[3]), float(dof[3]) * k, e)

func _camera_restore() -> void:
	if focus_seg.is_empty() or camera == null:
		return
	camera.global_transform = focus_seg.xf
	var attrs: CameraAttributesPractical = camera.attributes as CameraAttributesPractical
	if attrs != null and focus_seg.has("dof"):
		var dof: Array = focus_seg.dof
		attrs.dof_blur_far_distance = float(dof[0])
		attrs.dof_blur_far_transition = float(dof[1])
		attrs.dof_blur_near_distance = float(dof[2])
		attrs.dof_blur_near_transition = float(dof[3])

# ------------------------------------------------------------------ QA
func timeline() -> Array:
	var out: Array = []
	for s: Dictionary in segs:
		out.append({"kind": s.kind, "t0": s.t0, "t1": s.t1, "mode": s.get("mode", "")})
	return out

func evidence() -> Dictionary:
	var ev: Dictionary = plan_report.duplicate(true)
	ev["timeline"] = timeline()
	ev["phase"] = _phase
	ev["kit_is_walker"] = kit_is_walker
	ev["ds_phase"] = ds_phase
	ev["sole_points"] = (sole.get("subset", PackedInt32Array()) as PackedInt32Array).size()
	ev["sole_vertices"] = (sole.get("verts", PackedVector3Array()) as PackedVector3Array).size()
	return ev

func _exit_tree() -> void:
	if character != null and is_instance_valid(character) and "motion_hook" in character:
		var hk: Callable = character.get("motion_hook")
		if hk.is_valid() and hk.get_object() == self:
			character.set("motion_hook", Callable())
