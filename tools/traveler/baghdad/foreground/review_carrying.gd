extends SceneTree
## Independent animated Carrying and potato-blossom review. One clock drives
## the real skeletal animation, hand props, blossoms and approved spring rain.
const REPORT := "res://docs/reports/traveler-baghdad-001/carrying-20260923/blossom-final"
const SNAPSHOT := "res://docs/reports/traveler-baghdad-001/rain-20260923/layout-snapshot.json"
const VIEWER_SOURCE := "res://scripts/traveler/baghdad/baghdad_viewer.gd"
const POSE_SOURCE := "res://scripts/traveler/baghdad/baghdad_carrying_pose.gd"
const POSE_ASSET := "res://assets/traveler/baghdad/character/carrying_animated.glb"
const LANDMARK_ASSET := "res://assets/traveler/baghdad/character/carrying_landmarks.json"
const FLOWER_SOURCE := "res://scripts/traveler/baghdad/baghdad_potato_blossom.gd"
const RAIN_SOURCE := "res://scripts/traveler/baghdad/baghdad_rain_look.gd"
const SIZE := Vector2i(1920, 1080)
const FPS := 30
const WARMUP_FRAMES := 30
const MATURE_TIME := 5.5
const BUD_TIME := 0.4
const OPENING_TIME := 2.5
const VIDEO_SECONDS := 8.0

var viewport: SubViewport
var viewer: Node3D
var pose: Node3D
var flower: Node3D
var rain: Node3D
var camera: Camera3D
var output: String = REPORT
var mode: String = "still"
var original_camera: Transform3D = Transform3D.IDENTITY
var original_fov: float = 40.0
var closeup_camera: Transform3D = Transform3D.IDENTITY
var closeup_fov: float = 35.0
var original_attributes: CameraAttributes
var closeup_fill: OmniLight3D
var closeup: bool = false
var space_down: bool = false
var replay_down: bool = false
var ready: bool = false
var post_draw_serial: int = 0
var started_usec: int = 0
var live_started_usec: int = 0
var timeline_seconds: float = 0.0
var replay_count: int = 0
var captures: Array[Dictionary] = []
var frame_records: Array[Dictionary] = []
var animation_samples: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	started_usec = Time.get_ticks_usec()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--carrying-output="):
			output = arg.trim_prefix("--carrying-output=")
	if args.has("--carrying-live") and args.has("--carrying-video"):
		fail("Choose one of --carrying-live or --carrying-video")
		return
	if args.has("--carrying-live"):
		mode = "live"
	elif args.has("--carrying-video"):
		mode = "video"
	if not args.has("--view=baghdad"):
		fail("Carrying review requires --view=baghdad")
		return
	if DisplayServer.get_name() == "headless":
		fail("Carrying review requires a real renderer")
		return
	if not output.is_absolute_path() and not output.begins_with("res://"):
		fail("--carrying-output must be an absolute path or res:// path")
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output)) != OK:
		fail("Cannot create carrying output: " + output)
		return
	if not FileAccess.file_exists(SNAPSHOT) or not JSON.parse_string(FileAccess.get_file_as_string(SNAPSHOT)) is Dictionary:
		fail("Missing or invalid frozen rain layout: " + SNAPSHOT)
		return
	if mode == "video":
		var frames_directory: String = output.path_join("frames")
		var directory: DirAccess = DirAccess.open(frames_directory)
		if directory != null and not directory.get_files().is_empty():
			fail("Carrying frames directory is occupied; use a new --carrying-output directory")
			return
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(frames_directory)) != OK:
			fail("Cannot create Carrying frames directory")
			return
	root.title = "巴格达 · Carrying 土豆开花 · 空格近景 / R 重播"
	root.size = Vector2i(1440, 810)
	viewport = SubViewport.new()
	viewport.name = "CarryingReviewViewport"
	viewport.size = SIZE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.use_taa = false
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	root.add_child(viewport)
	var preview: TextureRect = TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	Engine.max_fps = FPS
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var timer: Timer = Timer.new()
	timer.wait_time = 1.0 / FPS
	timer.timeout.connect(background_draw)
	root.add_child(timer)
	timer.start()
	var source: String = FileAccess.get_file_as_string(VIEWER_SOURCE)
	source = source.replace("res://data/traveler/baghdad_scene.json", SNAPSHOT)
	var script: GDScript = GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		fail("Carrying review viewer did not compile")
		return
	viewer = script.new()
	viewport.add_child(viewer)
	var deadline: int = Time.get_ticks_msec() + 60000
	while not bool(viewer.get("ready_for_capture")):
		if Time.get_ticks_msec() > deadline:
			fail("Carrying review readiness timeout")
			return
		await process_frame
	var pose_script: GDScript = load(POSE_SOURCE) as GDScript
	if pose_script == null or not pose_script.can_instantiate():
		fail("Carrying pose layer did not compile: " + POSE_SOURCE)
		return
	pose = pose_script.new()
	viewer.add_child(pose)
	var pose_ready: bool = bool(await pose.call("configure", viewer))
	if not pose_ready:
		fail("Carrying pose configuration failed; no preview or success evidence was produced")
		return
	if not pose.has_method("set_time"):
		fail("Carrying pose must expose animated set_time(seconds)")
		return
	var animation_setup: Dictionary = pose.call("evidence") if pose.has_method("evidence") else {}
	if not bool(animation_setup.get("animated", false)) or float(animation_setup.get("animation_length_seconds", 0.0)) <= 0.0:
		fail("Carrying review requires a valid imported skeletal animation, not a static pose")
		return
	pose.set_process(false)
	var flower_script: GDScript = load(FLOWER_SOURCE) as GDScript
	if flower_script == null or not flower_script.can_instantiate():
		fail("Potato blossom layer did not compile: " + FLOWER_SOURCE)
		return
	flower = flower_script.new()
	flower.set("autoplay", false)
	viewer.add_child(flower)
	var flower_ready: bool = bool(await flower.call("configure", pose))
	if not flower_ready or not flower.has_method("set_time"):
		fail("Potato blossom configuration failed; no preview or success evidence was produced")
		return
	flower.set("autoplay", false)
	flower.set_process(false)
	var rain_script: GDScript = load(RAIN_SOURCE) as GDScript
	if rain_script == null or not rain_script.can_instantiate():
		fail("Rain layer did not compile: " + RAIN_SOURCE)
		return
	rain = rain_script.new()
	viewer.add_child(rain)
	rain.call("configure", viewer)
	rain.set_process(false)
	camera = viewer.get("camera") as Camera3D
	camera.make_current()
	original_camera = camera.global_transform
	original_fov = camera.fov
	original_attributes = camera.attributes
	configure_closeup_camera()
	set_scene_time(0.0 if mode == "live" else MATURE_TIME)
	for warmup in WARMUP_FRAMES:
		await draw_frame()
	ready = true
	print("BAGHDAD_CARRYING_REVIEW_READY ", JSON.stringify({"mode":mode, "image_size":[SIZE.x,SIZE.y], "output":output}))
	if mode == "live":
		live_started_usec = Time.get_ticks_usec()
		record_animation_sample("live_start")
		if not write_evidence("live_ready"):
			return
		print("BAGHDAD_CARRYING_LIVE_PREVIEW_READY ", output)
		return
	if not capture_image("scene.png", "composition_mature_blossoms"):
		return
	set_closeup(true)
	for warmup in WARMUP_FRAMES:
		await draw_frame()
	if not capture_image("closeup.png", "character_front_three_quarter_mature_blossoms"):
		return
	set_scene_time(BUD_TIME)
	for warmup in WARMUP_FRAMES:
		await draw_frame()
	if not capture_image("closeup-bud.png", "character_front_three_quarter_bud"):
		return
	set_scene_time(OPENING_TIME)
	for warmup in WARMUP_FRAMES:
		await draw_frame()
	if not capture_image("closeup-opening.png", "character_front_three_quarter_opening"):
		return
	if mode == "video":
		set_scene_time(0.0)
		for warmup in WARMUP_FRAMES:
			await draw_frame()
		var frame_count: int = int(VIDEO_SECONDS * FPS)
		for frame in frame_count:
			set_scene_time(float(frame) / FPS)
			await draw_frame()
			var filename: String = "frames/f%04d.png" % frame
			if not capture_image(filename, "character_front_three_quarter_animation", false):
				return
			frame_records.append({"frame":frame, "time_seconds":timeline_seconds, "file":filename})
			if frame % FPS == 0 or frame == frame_count - 1:
				record_animation_sample("video_frame_%d" % frame)
			if (frame + 1) % 60 == 0:
				print("BAGHDAD_CARRYING_VIDEO_PROGRESS ", frame + 1, "/", frame_count)
	set_scene_time(MATURE_TIME)
	set_closeup(false)
	if not write_evidence("complete"):
		return
	if mode == "video":
		print("BAGHDAD_CARRYING_VIDEO_COMPLETE ", JSON.stringify({"frames":frame_records.size(), "fps":FPS, "duration_seconds":VIDEO_SECONDS, "output":output}))
	else:
		print("BAGHDAD_CARRYING_STILL_COMPLETE ", output)
	quit(0)

func configure_closeup_camera() -> void:
	var character: Node3D = viewer.get("character") as Node3D
	var settings: Dictionary = viewer.get("settings")
	var cfg: Dictionary = settings.get("character", {})
	var height: float = float(cfg.get("height_u", 0.6375))
	var feet: Vector3 = character.global_position
	var body: MeshInstance3D = viewer.get("character_body") as MeshInstance3D
	var geometry: Mesh = viewer.get("character_geometry") as Mesh
	if is_instance_valid(body) and geometry != null:
		var local_bounds: AABB = geometry.get_aabb()
		var world_bounds: AABB = AABB(body.global_transform * local_bounds.get_endpoint(0), Vector3.ZERO)
		for corner in range(1, 8):
			world_bounds = world_bounds.expand(body.global_transform * local_bounds.get_endpoint(corner))
		if world_bounds.size.y > 0.01:
			height = world_bounds.size.y
			feet = Vector3(world_bounds.get_center().x, world_bounds.position.y, world_bounds.get_center().z)
	var front: Vector3 = character.global_basis.z.normalized()
	var right: Vector3 = character.global_basis.x.normalized()
	front.y = 0.0
	right.y = 0.0
	var diagonal: Vector3 = (front.normalized() + right.normalized()).normalized()
	var position: Vector3 = feet + diagonal * height * 2.0 + Vector3.UP * height * 0.6
	var target: Vector3 = feet + Vector3.UP * height * 0.50
	closeup_camera = Transform3D(Basis.IDENTITY, position).looking_at(target, Vector3.UP)
	closeup_fill = OmniLight3D.new()
	closeup_fill.name = "CarryingInspectionSoftFill"
	closeup_fill.light_color = Color(1.0, 0.94, 0.84)
	closeup_fill.light_energy = 0.65
	closeup_fill.light_volumetric_fog_energy = 0.0
	closeup_fill.light_indirect_energy = 0.0
	closeup_fill.light_size = height * 0.35
	closeup_fill.omni_range = height * 3.0
	closeup_fill.omni_attenuation = 0.7
	closeup_fill.shadow_enabled = false
	closeup_fill.visible = false
	viewer.add_child(closeup_fill)
	closeup_fill.global_position = feet + diagonal * height * 1.2 + right.normalized() * height * 0.35 + Vector3.UP * height * 1.25

func set_closeup(enabled: bool) -> void:
	closeup = enabled
	if is_instance_valid(closeup_fill):
		closeup_fill.visible = closeup
	if closeup:
		camera.global_transform = closeup_camera
		camera.fov = closeup_fov
		# The scene focus belongs to the distant tree. Disable camera-only blur
		# during inspection so the full character and potato can be evaluated.
		if original_attributes is CameraAttributesPractical:
			var attributes: CameraAttributesPractical = original_attributes.duplicate() as CameraAttributesPractical
			attributes.dof_blur_far_enabled = false
			attributes.dof_blur_near_enabled = false
			camera.attributes = attributes
	else:
		camera.global_transform = original_camera
		camera.fov = original_fov
		camera.attributes = original_attributes

func _process(_delta: float) -> bool:
	var pressed: bool = Input.is_physical_key_pressed(KEY_SPACE)
	var replay_pressed: bool = Input.is_physical_key_pressed(KEY_R)
	if ready and mode == "live" and pressed and not space_down:
		set_closeup(not closeup)
	if ready and mode == "live" and replay_pressed and not replay_down:
		live_started_usec = Time.get_ticks_usec()
		replay_count += 1
		set_scene_time(0.0)
		record_animation_sample("live_replay_%d" % replay_count)
		write_evidence("live_restarted")
		print("BAGHDAD_CARRYING_REPLAY ", replay_count)
	space_down = pressed
	replay_down = replay_pressed
	return false

func _on_frame_post_draw() -> void:
	post_draw_serial += 1

func draw_frame() -> void:
	await process_frame
	var target_serial: int = post_draw_serial + 1
	RenderingServer.force_draw(false)
	if post_draw_serial < target_serial:
		await RenderingServer.frame_post_draw

func background_draw() -> void:
	if ready and mode == "live" and is_instance_valid(rain):
		var seconds: float = float(Time.get_ticks_usec() - live_started_usec) / 1000000.0
		set_scene_time(seconds)
	RenderingServer.force_draw(false)

func set_scene_time(seconds: float) -> void:
	timeline_seconds = maxf(seconds, 0.0)
	# Pose runs first: the blossom root is parented to the moving potato bundle.
	pose.call("set_time", timeline_seconds)
	flower.call("set_time", timeline_seconds)
	rain.call("set_time", timeline_seconds)

func record_animation_sample(label: String) -> void:
	animation_samples.append({"label":label, "time_seconds":timeline_seconds,
		"carrying_pose":pose.call("evidence") if pose.has_method("evidence") else {},
		"flower":flower.call("evidence") if flower.has_method("evidence") else {}})

func capture_image(filename: String, view_name: String, record_capture: bool = true) -> bool:
	var image: Image = viewport.get_texture().get_image()
	var path: String = output.path_join(filename)
	if image == null or image.get_size() != SIZE:
		fail("Invalid carrying capture: " + path)
		return false
	if image.save_png(path) != OK:
		fail("Cannot save carrying capture: " + path)
		return false
	if record_capture:
		captures.append({"file":filename, "view":view_name,
			"camera_transform":str(camera.global_transform), "fov_vertical_deg":camera.fov,
			"time_seconds":timeline_seconds, "rain_time_seconds":timeline_seconds,
			"inspection_depth_of_field_disabled":closeup,
			"additional_lights":true, "blossom_light_layer_present":true,
			"additional_inspection_lights":closeup, "inspection_fill":inspection_fill_evidence()})
		record_animation_sample(view_name)
	return true

func inspection_fill_evidence() -> Dictionary:
	if not is_instance_valid(closeup_fill):
		return {}
	return {"name":str(closeup_fill.name), "enabled":closeup_fill.visible,
		"type":"OmniLight3D", "energy":closeup_fill.light_energy,
		"color":[closeup_fill.light_color.r, closeup_fill.light_color.g, closeup_fill.light_color.b],
		"range":closeup_fill.omni_range, "attenuation":closeup_fill.omni_attenuation,
		"size":closeup_fill.light_size, "position":str(closeup_fill.global_position),
		"shadows":closeup_fill.shadow_enabled, "volumetric_energy":closeup_fill.light_volumetric_fog_energy,
		"indirect_energy":closeup_fill.light_indirect_energy, "scope":"character inspection closeup only"}

func write_evidence(status: String) -> bool:
	var storm: Node = viewer.get("storm_look") as Node
	var pose_evidence: Dictionary = pose.call("evidence") if pose.has_method("evidence") else {}
	var evidence: Dictionary = {
		"schema":"silkroad.baghdad-carrying-review.v2", "status":status, "mode":mode,
		"image_size":[SIZE.x,SIZE.y], "msaa":"4x", "warmup_frames_per_camera":WARMUP_FRAMES,
		"fps":FPS, "duration_seconds":VIDEO_SECONDS if mode == "video" else 0.0,
		"frame_count":frame_records.size(), "frames":frame_records,
		"video_camera":"character_front_three_quarter", "fixed_video_camera":true,
		"simulation_step_seconds":1.0 / FPS, "time_seconds":timeline_seconds,
		"unified_timeline":["carrying_skeletal_animation", "hand_held_potatoes", "potato_blossoms", "rain"],
		"live_controls":{"space":"toggle character closeup", "R":"restart the shared animation clock"},
		"live_replay_count":replay_count,
		"captures":captures, "scene_camera_transform":str(original_camera),
		"scene_fov_vertical_deg":original_fov, "closeup_camera_transform":str(closeup_camera),
		"closeup_fov_vertical_deg":closeup_fov, "layout_snapshot":SNAPSHOT,
		"inspection_fill":inspection_fill_evidence(),
		"layout_sha256":FileAccess.get_sha256(SNAPSHOT),
		"viewer_source_sha256":FileAccess.get_sha256(VIEWER_SOURCE),
		"pose_source_sha256":FileAccess.get_sha256(POSE_SOURCE),
		"pose_asset":POSE_ASSET, "pose_asset_sha256":FileAccess.get_sha256(POSE_ASSET),
		"landmark_asset":LANDMARK_ASSET, "landmark_asset_sha256":FileAccess.get_sha256(LANDMARK_ASSET),
		"flower_source_sha256":FileAccess.get_sha256(FLOWER_SOURCE),
		"rain_source_sha256":FileAccess.get_sha256(RAIN_SOURCE),
		"carrying_pose":pose_evidence,
		"flower":flower.call("evidence") if flower.has_method("evidence") else {},
		"animation_statistics":{"animated":pose_evidence.get("animated"),
			"animation_name":pose_evidence.get("animation_name"),
			"animation_length_seconds":pose_evidence.get("animation_length_seconds"),
			"animation_time_seconds":pose_evidence.get("animation_time_seconds"),
			"bone_count":pose_evidence.get("bone_count"),
			"bone_following":pose_evidence.get("bone_following"),
			"sample_count":animation_samples.size(), "samples":animation_samples},
		"rain":rain.call("evidence") if rain.has_method("evidence") else {},
		"storm":storm.call("evidence") if is_instance_valid(storm) and storm.has_method("evidence") else {},
		"rendering_method":RenderingServer.get_current_rendering_method(),
		"rendering_driver":RenderingServer.get_current_rendering_driver_name(),
		"executable":OS.get_executable_path(), "arguments":OS.get_cmdline_args(),
		"user_arguments":OS.get_cmdline_user_args(),
		"wall_seconds":float(Time.get_ticks_usec() - started_usec) / 1000000.0,
		"note":"Actual Godot SubViewport images with frozen rain layout. The composition preserves the storm lighting and adds the requested potato-blossom emission and local flower light. One clock drives the imported Carrying skeletal animation, its hand-following potatoes, blossoms and rain. Closeup changes camera transform, field of view and depth of field, and enables a separate inspection soft fill hidden again in the full scene. Video uses the same fixed closeup for all 240 frames. No image overlays or post grading; capture wall time is not a performance benchmark."
	}
	var file: FileAccess = FileAccess.open(output.path_join("evidence.json"), FileAccess.WRITE)
	if file == null:
		fail("Cannot write carrying evidence")
		return false
	file.store_string(JSON.stringify(evidence, "\t"))
	file.close()
	return true

func fail(message: String) -> void:
	push_error(message)
	quit(1)
