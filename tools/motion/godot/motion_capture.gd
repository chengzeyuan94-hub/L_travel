extends Node
## Motion-film capture controller (tools/motion/godot/motion_capture.tscn). Driven by tools/motion/godot/capture.py.
##
## Why not plain Movie Maker frames: in this project Movie Maker writes at the project's base size (1280x720,
## whatever --resolution says), and on macOS a fully occluded window stops drawing while Movie Maker keeps
## writing the last image again (silent duplicate frames). So:
##   * the scene is loaded inside a 1920x1080 SubViewport "plate" (own World3D, the root viewport's render
##     settings copied over, the game's 1280x720 UI base kept via size_2d_override + stretch);
##   * the real window is a tiny always-on-top preview (320x180) at a per-slot screen position, so several
##     captures can run side by side and never cover each other;
##   * after each drawn frame (RenderingServer.frame_post_draw) the plate (or the board's own 3D viewport) is
##     read back and written as frame_%05d.png on WorkerThreadPool threads; frames that were not drawn are
##     counted as stalls and fail the capture (capture.py retries);
##   * Movie Maker still runs (tiny frames thrown away) for the fixed 1/fps timestep and the game-audio WAV.
##
## User args (after --), all prefixed --mc- so no act script reacts to them:
##   --mc-shot=<abs json>      the shot file (tools/motion/README.md, "Shot file")
##   --mc-out=<abs dir>        frames go here as frame_00000.png ...
##   --mc-manifest=<abs json>  capture manifest (camera snapshot, points of interest, timings, audio offset)
##   --mc-slot=<n>             preview-window slot (0..5), set by capture.py
##   --mc-debug-counter        print phase / frame counters into the plate (mapping tests only)
##   --mc-sync-test            white flash + 1 kHz beep on every whole second of clean time (A/V sync test)
## Everything else on the command line (e.g. --lshu-act=changan --view=changan --far --dusk) is read by the
## act scripts themselves, exactly as when the game opens that act.

const TARGETS := {
	"changan": {"scene": "res://scenes/traveler/traveler_main.tscn"},
	"panti": {"scene": "res://scenes/traveler/panti_main.tscn"},
	"baghdad": {"scene": "res://scenes/traveler/baghdad_cycle.tscn"},
	"lshu": {"scene": "res://scenes/traveler/lshu_main.tscn"},
	"home": {"script": "res://scripts/lshu_ui/lshu_home_scene.gd"},
	"board": {"scene": "res://tools/merchant_board_claude_play.tscn"},
}
const SIZE := Vector2i(1920, 1080)
const PREVIEW := Vector2i(320, 180)
const MAX_PENDING_SAVES := 40

var shot: Dictionary = {}
var target_id := ""
var out_dir := ""
var manifest_path := ""
var slot := 0
var debug_counter := false
var sync_test := false
var fps := 30
var frames_total := 0
var warmup_frames := 60
var ready_timeout_s := 240.0

var plate: SubViewport
var source_vp: Viewport         # what gets written: the plate, or the board's own 3D SubViewport (clean board feed)
var host: Node                  # the loaded scene root
var overlay: Node               # act_exit_button layer (acts only)
var board_view: Node            # merchant board %BoardView
var home_rig: Control           # 2D camera rig around the home illustration
var cams: Array[Camera3D] = []  # cameras to drive (Baghdad renders two worlds with one shot)
var act_cam: Dictionary = {}    # snapshot of the act's own camera at readiness
var act_basis := Basis.IDENTITY
var act_origin := Vector3.ZERO
var poi: Dictionary = {}
var ui_base := Vector2i(1280, 720)

var phase := "boot"             # boot -> wait_ready -> warmup -> capture -> flush -> done
var phase_frames := 0
var clean_index := 0
var pending_index := -1         # clean frame waiting for its frame_post_draw
var saved := 0
var stalls: Array[int] = []
var save_tasks: Array[int] = []
var events: Array = []
var fired: Array[bool] = []
var counter_label: Label
var flash_rect: ColorRect
var beep: AudioStreamPlayer
var t_boot_ms := 0
var t_ready_ms := 0
var t_capture_ms := 0
var t_done_ms := 0
var readback_us := 0
var ready_wall_deadline := 0
var first_process_frame := -1
var first_drawn := -1
var notes: Array[String] = []
var baghdad_clock := {"start": 0.0, "rate": 1.0}
var window_fixes := 0


func _ready() -> void:
	t_boot_ms = Time.get_ticks_msec()
	process_priority = 100000   # after every scene script: our camera wins the frame
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--mc-shot="):
			var p := a.trim_prefix("--mc-shot=")
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
			if parsed is Dictionary:
				shot = parsed
			else:
				_fail("shot file unreadable: " + p)
				return
		elif a.begins_with("--mc-out="):
			out_dir = a.trim_prefix("--mc-out=")
		elif a.begins_with("--mc-manifest="):
			manifest_path = a.trim_prefix("--mc-manifest=")
		elif a.begins_with("--mc-slot="):
			slot = int(a.trim_prefix("--mc-slot="))
		elif a == "--mc-debug-counter":
			debug_counter = true
		elif a == "--mc-sync-test":
			sync_test = true
	target_id = str(shot.get("target", ""))
	if not TARGETS.has(target_id):
		_fail("unknown target '%s' (one of %s)" % [target_id, ", ".join(TARGETS.keys())])
		return
	if out_dir.is_empty():
		_fail("--mc-out=<dir> is required")
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	fps = int(shot.get("fps", 30))
	frames_total = int(round(float(shot.get("duration", 3.0)) * fps))
	warmup_frames = int(shot.get("warmup_frames", 60))
	ready_timeout_s = float(shot.get("ready_timeout_s", 240.0))
	var ub: Array = shot.get("ui_base", [1280, 720])
	ui_base = Vector2i(int(ub[0]), int(ub[1]))
	if shot.has("seed"):
		seed(int(shot.seed))
	var bc: Dictionary = shot.get("baghdad", {})
	baghdad_clock.start = float(bc.get("start", 0.0))
	baghdad_clock.rate = float(bc.get("rate", 1.0))
	events = shot.get("events", [])
	for e: Variant in events:
		fired.append(false)
	_fix_window()
	_build_plate()
	get_tree().process_frame.connect(_before_scene_process)   # connected first: runs before the acts' own process_frame hooks
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	_load_target.call_deferred()


# ------------------------------------------------------------------ plate
func _build_plate() -> void:
	var root := get_tree().root
	plate = SubViewport.new()
	plate.name = "MotionPlate"
	plate.size = SIZE
	plate.own_world_3d = true
	plate.transparent_bg = bool(shot.get("alpha", false))
	plate.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	plate.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	# the root viewport's render settings (project settings) — a fresh SubViewport would otherwise default to no MSAA etc.
	for p: String in ["msaa_2d", "msaa_3d", "screen_space_aa", "use_taa", "use_debanding", "use_occlusion_culling",
			"mesh_lod_threshold", "scaling_3d_mode", "scaling_3d_scale", "fsr_sharpness", "texture_mipmap_bias",
			"anisotropic_filtering_level", "use_hdr_2d", "positional_shadow_atlas_size", "positional_shadow_atlas_16_bits",
			"positional_shadow_atlas_quad_0", "positional_shadow_atlas_quad_1", "positional_shadow_atlas_quad_2",
			"positional_shadow_atlas_quad_3", "canvas_item_default_texture_filter", "canvas_item_default_texture_repeat",
			"sdf_oversize", "sdf_scale", "snap_2d_transforms_to_pixel", "snap_2d_vertices_to_pixel"]:
		if p in root:
			plate.set(p, root.get(p))
	if ui_base != SIZE:
		# the game's canvas_items stretch: UI laid out at 1280x720 and drawn at full resolution
		plate.size_2d_override = ui_base
		plate.size_2d_override_stretch = true
	add_child(plate)
	source_vp = plate
	# tiny live preview in the real window
	var pv := TextureRect.new()
	pv.name = "PlatePreview"
	pv.texture = plate.get_texture()
	pv.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pv.stretch_mode = TextureRect.STRETCH_SCALE
	pv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child.call_deferred(pv)
	pv.set_anchors_and_offsets_preset.call_deferred(Control.PRESET_FULL_RECT)
	if debug_counter or sync_test:
		var layer := CanvasLayer.new()
		layer.layer = 127
		plate.add_child(layer)
		if sync_test:
			flash_rect = ColorRect.new()
			flash_rect.color = Color.WHITE
			flash_rect.visible = false
			layer.add_child(flash_rect)
			flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			beep = AudioStreamPlayer.new()
			beep.stream = _beep_stream()
			add_child(beep)
		if debug_counter:
			counter_label = Label.new()
			counter_label.position = Vector2(16, 16)
			counter_label.add_theme_font_size_override("font_size", 28)
			counter_label.add_theme_color_override("font_color", Color.YELLOW)
			counter_label.add_theme_color_override("font_outline_color", Color.BLACK)
			counter_label.add_theme_constant_override("outline_size", 8)
			layer.add_child(counter_label)


func _beep_stream() -> AudioStreamWAV:
	var rate := 48000
	var n := int(rate * 0.03)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var v := int(sin(TAU * 1000.0 * i / rate) * 26000.0)
		data.encode_s16(i * 2, v)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w


# ------------------------------------------------------------------ target
func _load_target() -> void:
	var info: Dictionary = TARGETS[target_id]
	if info.has("script"):
		# the title home illustration is a bare Control script (the title screen instantiates it the same way)
		home_rig = Control.new()
		home_rig.name = "HomeCameraRig"
		home_rig.mouse_filter = Control.MOUSE_FILTER_IGNORE
		home_rig.size = Vector2(ui_base)
		plate.add_child(home_rig)
		var c := Control.new()
		c.set_script(load(str(info.script)))
		c.name = "LshuHome"
		home_rig.add_child(c)
		c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		host = c
	else:
		var packed := load(str(info.scene)) as PackedScene
		if packed == null:
			_fail("cannot load " + str(info.scene))
			return
		host = packed.instantiate()
		if target_id == "lshu":
			host.set("director_mode", "on" if bool(shot.get("lshu_director", false)) else "off")
		plate.add_child(host)
		if host.get("act_overlay") is Node:
			overlay = host.get("act_overlay")
			overlay.set("manage_fps", false)   # no 30-fps cap / vsync while capturing
	phase = "wait_ready"
	phase_frames = 0
	ready_wall_deadline = Time.get_ticks_msec() + int(ready_timeout_s * 1000.0)
	print("MC_TARGET_LOADED ", JSON.stringify({"target": target_id, "ms": Time.get_ticks_msec() - t_boot_ms}))


func _is_ready() -> bool:
	match target_id:
		"changan", "panti", "lshu":
			if overlay == null:
				overlay = host.get_node_or_null("ActExitButton")
			if overlay != null:
				return overlay.is_node_ready() and bool(overlay.call("is_act_ready"))
			return phase_frames > 30   # launched without --lshu-act: nothing to wait for but the first frames
		"baghdad":
			if overlay == null:
				overlay = host.get_node_or_null("ActExitButton")
			return bool(host.get("ready_state"))
		"board":
			if board_view == null:
				var screen: Node = host.get("_screen")
				if screen != null:
					board_view = screen.get_node_or_null("%BoardView")
			return board_view != null and bool(board_view.get("_ready_world")) and phase_frames > int(shot.get("board_ready_frames", 20))
		"home":
			return phase_frames > 2
	return true


func _on_ready() -> void:
	t_ready_ms = Time.get_ticks_msec()
	match target_id:
		"changan", "panti", "lshu":
			var c: Variant = host.get("camera")
			if c is Camera3D:
				cams.append(c)
		"baghdad":
			for v: String in ["viewer_a", "viewer_b"]:
				var viewer: Node = host.get(v)
				if viewer != null and viewer.get("camera") is Camera3D:
					cams.append(viewer.get("camera"))
			host.set("clock_paused", true)
		"board":
			var world: Node = board_view.get("world")
			if world != null and world.get("camera") is Camera3D:
				cams.append(world.get("camera"))
			if world != null and not bool(shot.get("board_tilt", true)) and world.get("tilt_rect") is CanvasItem:
				(world.get("tilt_rect") as CanvasItem).visible = false   # the board's miniature tilt-shift pass
			if str(shot.get("board_feed", "clean")) == "clean":
				var bvp: Variant = board_view.get("vp")
				if bvp is SubViewport:
					source_vp = bvp
				_board_clean_insets()
	if not cams.is_empty():
		var c0: Camera3D = cams[0]
		act_basis = c0.global_basis.orthonormalized()
		act_origin = c0.global_position
		act_cam = {"position": _v(c0.global_position), "forward": _v(-c0.global_basis.z), "up": _v(c0.global_basis.y),
			"right": _v(c0.global_basis.x), "fov": c0.fov, "projection": ["perspective", "orthogonal", "frustum"][c0.projection],
			"size": c0.size, "near": c0.near, "far": c0.far, "keep_aspect": c0.keep_aspect, "path": str(c0.get_path())}
	poi = _points_of_interest()
	_hide_overlays()
	print("MC_READY ", JSON.stringify({"target": target_id, "wall_ms": t_ready_ms - t_boot_ms, "camera": act_cam}))


## a clean board plate wants the whole frame: the board otherwise keeps its camera left of the HUD panel
func _board_clean_insets() -> void:
	if board_view == null:
		return
	if float(board_view.get("_right_inset")) != 0.0:
		board_view.call("set_map_safe_right_inset", 0.0)
	board_view.call("set_hud_safe_insets", 0.0, 0.0)


func _hide_overlays() -> void:
	if overlay != null and overlay is CanvasLayer:
		(overlay as CanvasLayer).visible = false
	for n: Variant in shot.get("hide", []):
		var node := plate.find_child(str(n), true, false)
		if node is CanvasItem:
			(node as CanvasItem).visible = false
		elif node is CanvasLayer:
			(node as CanvasLayer).visible = false
		elif node is Node3D:
			(node as Node3D).visible = false


# ------------------------------------------------------------------ frame loop
## process_frame is emitted before any node's _process: set the Baghdad clock here so its own process_frame
## hook (_tick, connected later than us) reads the frame-exact time. Warm-up runs the clock up to "start".
func _before_scene_process() -> void:
	if target_id != "baghdad" or host == null or not bool(host.get("ready_state")):
		return
	var t: float
	# runs before our _process of the same iteration, so counters still hold the previous iteration's values
	if phase == "warmup":
		t = baghdad_clock.start - float(warmup_frames - (phase_frames + 1)) / fps * baghdad_clock.rate
	elif phase == "capture":
		t = baghdad_clock.start + float(clean_index + 1) / fps * baghdad_clock.rate
	else:
		t = baghdad_clock.start - float(warmup_frames) / fps * baghdad_clock.rate
	host.set("clock_paused", true)
	host.set("clock_base", maxf(t, 0.0))


func _process(_delta: float) -> void:
	phase_frames += 1
	Engine.max_fps = 0
	_fix_window()
	if counter_label != null:
		counter_label.text = "%s %d  process %d  drawn %d  clean %d" % [phase, phase_frames, Engine.get_process_frames(), Engine.get_frames_drawn(), clean_index]
	if flash_rect != null:
		flash_rect.visible = false
	match phase:
		"wait_ready":
			if Time.get_ticks_msec() > ready_wall_deadline:
				_fail("scene not ready after %.0f s" % ready_timeout_s)
				return
			if _is_ready():
				_on_ready()
				phase = "warmup"
				phase_frames = 0
				_apply_camera(0.0)
		"warmup":
			_hide_overlays()
			if target_id == "board" and source_vp != plate:
				_board_clean_insets()
			_apply_camera(0.0)
			if phase_frames >= warmup_frames:
				phase = "capture"
				phase_frames = 0
				clean_index = 0
				first_process_frame = Engine.get_process_frames()
				first_drawn = Engine.get_frames_drawn()
				t_capture_ms = Time.get_ticks_msec()
				Engine.time_scale = float(shot.get("time_scale", 1.0))
				_capture_frame()
		"capture":
			if pending_index >= 0:
				stalls.append(pending_index)   # the previous clean frame was never drawn (window occluded?)
				pending_index = -1
			clean_index += 1
			if clean_index >= frames_total:
				_flush()
				return
			_capture_frame()
		"flush":
			_try_finish()


func _capture_frame() -> void:
	var t := float(clean_index) / fps
	_hide_overlays()
	if target_id == "board" and source_vp != plate:
		_board_clean_insets()
	_apply_camera(t)
	for i in events.size():
		var e: Dictionary = events[i]
		if not fired[i] and t + 0.5 / fps >= float(e.get("t", 0.0)):
			fired[i] = true
			_fire(e)
	if sync_test and clean_index % fps == 0:
		flash_rect.visible = true
		beep.play()
	pending_index = clean_index
	if clean_index % 30 == 0:
		print("MC_FRAME ", clean_index, "/", frames_total, " wall_ms=", Time.get_ticks_msec() - t_capture_ms)


## after the frame is drawn: read the plate back and hand the PNG encode to a worker thread
func _on_post_draw() -> void:
	if pending_index < 0 or source_vp == null:
		return
	var idx := pending_index
	pending_index = -1
	var t0 := Time.get_ticks_usec()
	var img := source_vp.get_texture().get_image()
	readback_us += Time.get_ticks_usec() - t0
	var path := out_dir.path_join("frame_%05d.png" % idx)
	var keep_alpha := bool(shot.get("alpha", false))
	while save_tasks.size() >= MAX_PENDING_SAVES:
		WorkerThreadPool.wait_for_task_completion(save_tasks.pop_front())
	save_tasks.append(WorkerThreadPool.add_task(_save.bind(img, path, keep_alpha), true, "motion png"))   # high priority: all pool threads
	saved += 1


static func _save(img: Image, path: String, keep_alpha: bool) -> void:
	if img.get_size() != SIZE:
		img.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
	if not keep_alpha and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	img.save_png(path)


func _fire(e: Dictionary) -> void:
	var node: Node = host
	if e.has("node"):
		node = host.get_node_or_null(NodePath(str(e.node)))
		if node == null:
			node = plate.find_child(str(e.node), true, false)
	if node == null:
		notes.append("event node not found: %s" % str(e))
		return
	if e.has("call"):
		node.callv(str(e.call), e.get("args", []))
	if e.has("set"):
		for k: String in (e.set as Dictionary):
			node.set(k, e.set[k])
	print("MC_EVENT ", JSON.stringify(e))


func _flush() -> void:
	phase = "flush"
	t_done_ms = Time.get_ticks_msec()
	Engine.time_scale = 1.0
	_try_finish()


func _try_finish() -> void:
	while not save_tasks.is_empty():
		WorkerThreadPool.wait_for_task_completion(save_tasks.pop_front())
	var t_flushed := Time.get_ticks_msec()
	var capture_s := float(t_done_ms - t_capture_ms) / 1000.0
	var src_size := source_vp.get_texture().get_size()
	var m := {
		"schema": "silkroad.motion.capture-manifest.v2",
		"target": target_id,
		"fps": fps,
		"frames": frames_total,
		"frames_saved": saved,
		"stalls": stalls,
		"warmup_frames": warmup_frames,
		# Movie Maker (tiny preview frames + WAV) writes one frame per main-loop iteration; capture.py turns
		# first_process_frame into the WAV sample offset of clean frame 0 (README "A/V sync")
		"first_process_frame": first_process_frame,
		"first_frames_drawn": first_drawn,
		"source": "board_3d_viewport" if source_vp != plate else "plate",
		"source_size": [src_size.x, src_size.y],
		"ui_base": [ui_base.x, ui_base.y],
		"act_camera": act_cam,
		"poi": poi,
		"wall_s": {"boot_to_ready": float(t_ready_ms - t_boot_ms) / 1000.0, "ready_to_first_clean": float(t_capture_ms - t_ready_ms) / 1000.0,
			"capture": capture_s, "flush": float(t_flushed - t_done_ms) / 1000.0,
			"ms_per_clean_frame": capture_s * 1000.0 / maxf(1.0, frames_total),
			"readback_ms_per_frame": float(readback_us) / 1000.0 / maxf(1.0, saved)},
		"window_fixes": window_fixes,
		"notes": notes,
	}
	if not manifest_path.is_empty():
		var f := FileAccess.open(manifest_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(m, "  "))
		f.close()
	print("MC_DONE ", JSON.stringify({"saved": saved, "stalls": stalls.size(), "wall_s": m.wall_s}))
	phase = "done"
	get_tree().quit(0 if stalls.is_empty() and saved == frames_total else 4)


func _fail(msg: String) -> void:
	push_error("MC_FAIL " + msg)
	print("MC_FAIL ", msg)
	if not manifest_path.is_empty():
		var f := FileAccess.open(manifest_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"schema": "silkroad.motion.capture-manifest.v2", "error": msg, "target": target_id}))
			f.close()
	phase = "done"
	get_tree().quit(3)


# ------------------------------------------------------------------ camera
## camera block of the shot: {"mode": "hold"} (the act's own camera, untouched) or
## {"mode": "keys", "space": "world"|"act", "interp": "catmull"|"linear", "keys": [{t, pos, look, fov, roll, ease}]}
## "act" space: pos / look are units in the act camera's own frame at readiness (x right, y up, z back, origin at
## the act camera), so {"pos":[0,0,0],"look":[0,0,-10]} is exactly the act's framing. "look_space" (default =
## "space") lets the look-at points use the other space, e.g. move in act space while aiming at a world POI.
## Home (2D): keys {t, zoom, center:[x,y] in 1920x1080 output px, roll (deg)}.
func _apply_camera(t: float) -> void:
	var cam: Dictionary = shot.get("camera", {"mode": "hold"})
	if target_id == "home":
		host.set("_parallax", Vector2.ZERO)   # mouse parallax off: a capture never depends on the OS cursor
	if str(cam.get("mode", "hold")) != "keys":
		return
	var keys: Array = cam.get("keys", [])
	if keys.is_empty():
		return
	if target_id == "home":
		_apply_2d(keys, t)
		return
	if cams.is_empty():
		return
	var s := _sample(keys, t, str(cam.get("interp", "catmull")))
	var act_space := str(cam.get("space", "world")) == "act"
	var look_act := str(cam.get("look_space", cam.get("space", "world"))) == "act"
	var pos: Vector3 = s.get("pos", Vector3.ZERO if act_space else act_origin)
	var look: Vector3 = s.get("look", Vector3(0, 0, -10) if look_act else act_origin - act_basis.z * 10.0)
	if act_space:
		pos = act_origin + act_basis * pos
	if look_act:
		look = act_origin + act_basis * look
	var up := act_basis.y if act_space else Vector3.UP
	for c: Camera3D in cams:
		if str(cam.get("projection", "perspective")) == "perspective":
			c.projection = Camera3D.PROJECTION_PERSPECTIVE
		elif str(cam.projection) == "orthogonal":
			c.projection = Camera3D.PROJECTION_ORTHOGONAL
		if s.has("fov"):
			c.fov = float(s.fov)
		if s.has("size"):
			c.size = float(s.size)
		if cam.has("near"):
			c.near = float(cam.near)
		if cam.has("far"):
			c.far = float(cam.far)
		var xf := Transform3D(Basis.IDENTITY, pos).looking_at(look, up) if not pos.is_equal_approx(look) else Transform3D(act_basis, pos)
		if s.has("roll"):
			xf.basis = xf.basis * Basis(Vector3.BACK, deg_to_rad(float(s.roll)))
		c.global_transform = xf
		if cam.has("dof_focus"):
			var attrs := c.attributes as CameraAttributesPractical
			if attrs != null:
				var fd := (look - pos).length()
				var df: Dictionary = cam.dof_focus
				attrs.dof_blur_far_distance = fd + float(df.get("far_offset", 5.0))
				attrs.dof_blur_near_distance = maxf(0.05, fd - float(df.get("near_offset", 3.0)))


func _apply_2d(keys: Array, t: float) -> void:
	var s := _sample(keys, t, "linear")
	var k := float(ui_base.x) / float(SIZE.x)   # output px -> plate canvas units
	var z := float(s.get("zoom", 1.0))
	var center: Vector2 = s.get("center2", Vector2(SIZE) * 0.5) * k
	var scr := Vector2(ui_base) * 0.5
	home_rig.pivot_offset = center
	home_rig.scale = Vector2(z, z)
	home_rig.rotation = deg_to_rad(float(s.get("roll", 0.0)))
	home_rig.position = scr - center


## piecewise: segment i runs keys[i].t .. keys[i+1].t with keys[i].ease
func _sample(keys: Array, t: float, interp: String) -> Dictionary:
	var n := keys.size()
	var i := 0
	while i < n - 1 and t >= float(keys[i + 1].get("t", 0.0)):
		i += 1
	var k0: Dictionary = keys[i]
	var k1: Dictionary = keys[mini(i + 1, n - 1)]
	var t0 := float(k0.get("t", 0.0))
	var t1 := float(k1.get("t", t0))
	var u := 0.0 if t1 <= t0 else clampf((t - t0) / (t1 - t0), 0.0, 1.0)
	if i == n - 1:
		u = 0.0
	u = _ease(str(k0.get("ease", "inOutSine")), u)
	var out := {}
	var km: Dictionary = keys[maxi(i - 1, 0)]
	var kp: Dictionary = keys[mini(i + 2, n - 1)]
	for field: String in ["pos", "look"]:
		if k0.has(field):
			var p1 := _v3(k0[field])
			var p2 := _v3(k1.get(field, k0[field]))
			if interp == "catmull" and n > 2 and not p1.is_equal_approx(p2):
				# time-aware Catmull-Rom (cardinal Hermite with tangents per second), so unevenly spaced keys keep a
				# continuous velocity; a neighbouring hold (two equal keys) gets a zero tangent, a hold segment stays put
				var ta := float(km.get("t", t0))
				var td := float(kp.get("t", t1))
				var p0 := _v3(km.get(field, k0[field]))
				var p3 := _v3(kp.get(field, k1.get(field, k0[field])))
				var dt := maxf(t1 - t0, 0.0001)
				var m1 := (p2 - p1) / dt if i == 0 else (p2 - p0) / maxf(t1 - ta, 0.0001)
				var m2 := (p2 - p1) / dt if i + 2 > n - 1 else (p3 - p1) / maxf(td - t0, 0.0001)
				if i > 0 and p0.is_equal_approx(p1):
					m1 = Vector3.ZERO
				if i + 2 <= n - 1 and p3.is_equal_approx(p2):
					m2 = Vector3.ZERO
				out[field] = _hermite(p1, p2, m1 * dt, m2 * dt, u)
			else:
				out[field] = p1.lerp(p2, u)
	for field: String in ["fov", "size", "roll", "zoom"]:
		if k0.has(field):
			out[field] = lerpf(float(k0[field]), float(k1.get(field, k0[field])), u)
	if k0.has("center"):
		var c0 := Vector2(float(k0.center[0]), float(k0.center[1]))
		var c1v: Array = k1.get("center", k0.center)
		out["center2"] = c0.lerp(Vector2(float(c1v[0]), float(c1v[1])), u)
	return out


static func _hermite(p1: Vector3, p2: Vector3, m1: Vector3, m2: Vector3, u: float) -> Vector3:
	var u2 := u * u
	var u3 := u2 * u
	return (2.0 * u3 - 3.0 * u2 + 1.0) * p1 + (u3 - 2.0 * u2 + u) * m1 + (-2.0 * u3 + 3.0 * u2) * p2 + (u3 - u2) * m2


static func _ease(name: String, u: float) -> float:
	match name:
		"linear":
			return u
		"hold", "step":
			return 0.0
		"inSine":
			return 1.0 - cos(u * PI * 0.5)
		"outSine":
			return sin(u * PI * 0.5)
		"inOutSine":
			return 0.5 - 0.5 * cos(u * PI)
		"inQuad":
			return u * u
		"outQuad":
			return 1.0 - (1.0 - u) * (1.0 - u)
		"inOutQuad":
			return 2.0 * u * u if u < 0.5 else 1.0 - pow(-2.0 * u + 2.0, 2.0) * 0.5
		"inCubic":
			return u * u * u
		"outCubic":
			return 1.0 - pow(1.0 - u, 3.0)
		"inOutCubic":
			return 4.0 * u * u * u if u < 0.5 else 1.0 - pow(-2.0 * u + 2.0, 3.0) * 0.5
		"outQuart":
			return 1.0 - pow(1.0 - u, 4.0)
		"inOutQuart":
			return 8.0 * pow(u, 4.0) if u < 0.5 else 1.0 - pow(-2.0 * u + 2.0, 4.0) * 0.5
		"outExpo":
			return 1.0 if u >= 1.0 else 1.0 - pow(2.0, -10.0 * u)
		"inOutExpo":
			if u <= 0.0 or u >= 1.0:
				return u
			return pow(2.0, 20.0 * u - 10.0) * 0.5 if u < 0.5 else (2.0 - pow(2.0, -20.0 * u + 10.0)) * 0.5
		"outBack":
			var c1 := 1.70158
			return 1.0 + (c1 + 1.0) * pow(u - 1.0, 3.0) + c1 * pow(u - 1.0, 2.0)
		"smooth", "smoothstep":
			return u * u * (3.0 - 2.0 * u)
	return 0.5 - 0.5 * cos(u * PI)


static func _v3(a: Variant) -> Vector3:
	if a is Vector3:
		return a
	var arr: Array = a
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


static func _v(p: Vector3) -> Array:
	return [snappedf(p.x, 0.0001), snappedf(p.y, 0.0001), snappedf(p.z, 0.0001)]


# ------------------------------------------------------------------ points of interest (for shot authoring)
func _points_of_interest() -> Dictionary:
	var out := {}
	match target_id:
		"changan":
			for c: Dictionary in host.get("cities"):
				if str(c.id) == "changan":
					out["gate"] = _v(Vector3(c.x, float(c.base) + float(c.scale) * 0.65, c.z))
					out["city_base"] = _v(Vector3(c.x, float(c.base), c.z))
					out["city_scale_u"] = float(c.scale)
			out["act_target"] = _v(host.get("target"))
			var ch: Variant = host.get("character_controller")
			if ch is Node3D and is_instance_valid(ch):
				var ev: Dictionary = (ch as Node).call("evidence") if (ch as Node).has_method("evidence") else {}
				out["character_world_position"] = str(ev.get("world_position", ""))
		"panti":
			var camp: Variant = host.get("camp")
			if camp is Node and (camp as Node).get("fire") is Node3D:
				out["fire"] = _v(((camp as Node).get("fire") as Node3D).global_position)
			for key: String in ["character", "castle"]:
				var n: Variant = host.get(key)
				if n is Node3D:
					out[key] = _v((n as Node3D).global_position)
			var settings: Dictionary = host.get("settings")
			if settings.has("camera_composition"):
				out["look_at_world"] = _v(host.call("stage_point", _v3(settings.camera_composition.look_at_stage)))
		"baghdad":
			var viewer: Node = host.get("viewer_a")
			if viewer != null and viewer.get("character") is Node3D:
				out["character"] = _v((viewer.get("character") as Node3D).global_position)
			var pose: Node = host.get("pose_a")
			if pose != null and pose.get("potato_bundle") is Node3D:
				out["potato_bundle"] = _v((pose.get("potato_bundle") as Node3D).global_position)
			out["cycle_seconds"] = host.call("_cycle_length")
		"lshu":
			var ch2: Variant = host.get("character")
			if ch2 is Node3D:
				out["character"] = _v((ch2 as Node3D).global_position)
			var tile: Variant = host.get("tile")
			if tile is Node3D and (tile as Node3D).get("camera_fit") is Dictionary:
				out["camera_fit"] = (tile as Node3D).get("camera_fit")
			out["tile"] = host.get("tile_id")
			out["light"] = host.get("light_name")
		"board":
			var world: Node = board_view.get("world")
			if world != null:
				var lay: Dictionary = world.get("layout")
				out["board_bounds"] = lay.get("board", {})
				var cities := {}
				for c: Variant in lay.get("cities", []):
					if c is Dictionary and (c as Dictionary).has("id"):
						cities[str(c.id)] = [c.get("x", 0), c.get("y", 0), c.get("z", 0)]
				if not cities.is_empty():
					out["cities"] = cities
	return out


# ------------------------------------------------------------------ window
## the real window is only a preview: tiny, borderless, always on top, at its slot (top-right, right to left).
## The board and the acts resize / maximise the window when they start; this puts it back every frame.
func _fix_window() -> void:
	var w := get_window()
	var changed := false
	if w.mode != Window.MODE_WINDOWED:
		w.mode = Window.MODE_WINDOWED
		changed = true
	if not w.borderless:
		w.borderless = true
		changed = true
	if not w.always_on_top:
		w.always_on_top = true
		changed = true
	if w.size != PREVIEW:
		w.size = PREVIEW
		changed = true
	var usable := DisplayServer.screen_get_usable_rect(w.current_screen)
	var pos := Vector2i(usable.position.x + usable.size.x - (PREVIEW.x + 8) * (slot + 1), usable.position.y + 8)
	if w.position != pos:
		w.position = pos
		changed = true
	if changed:
		window_fixes += 1
