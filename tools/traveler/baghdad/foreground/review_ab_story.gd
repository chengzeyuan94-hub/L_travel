extends SceneTree
## Independent A/B story review. The story owns every scene timeline; this
## harness records the unchanged full-scene camera and an optional inspection view.
const REPORT := "res://docs/reports/traveler-baghdad-001/ab-story-20260923/v1"
const SNAPSHOT := "res://docs/reports/traveler-baghdad-001/rain-20260923/layout-snapshot.json"
const VIEWER_SOURCE := "res://scripts/traveler/baghdad/baghdad_viewer.gd"
const POSE_SOURCE := "res://scripts/traveler/baghdad/baghdad_carrying_pose.gd"
const POSE_ASSET := "res://assets/traveler/baghdad/character/carrying_animated.glb"
const LANDMARK_ASSET := "res://assets/traveler/baghdad/character/carrying_landmarks.json"
const FLOWER_SOURCE := "res://scripts/traveler/baghdad/baghdad_potato_blossom.gd"
const STORY_SOURCE := "res://scripts/traveler/baghdad/baghdad_ab_story.gd"
const RAIN_SOURCE := "res://scripts/traveler/baghdad/baghdad_rain_look.gd"
const SIZE := Vector2i(1920, 1080)
const FPS := 30
const WARMUP_FRAMES := 30
const A_TIME := 0.0
const TRANSITION_TIME := 4.8
const B_TIME := 10.0
const TRANSITION_START := 0.0
const TRANSITION_END := 8.0
const VIDEO_SECONDS := 12.0

var viewport: SubViewport
var viewer: Node3D
var pose: Node3D
var flower: Node3D
var rain: Node3D
var story: Node3D
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
var ready: bool = false
var post_draw_serial: int = 0
var started_usec: int = 0
var live_started_usec: int = 0
var live_elapsed_base: float = 0.0
var live_clock_paused: bool = false
var timeline_seconds: float = 0.0
var replay_count: int = 0
var resume_requested: bool = false
var resume_start_frame: int = 0
var resume_history_start_frame: int = 0
var captures: Array[Dictionary] = []
var frame_records: Array[Dictionary] = []
var story_samples: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	started_usec = Time.get_ticks_usec()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--ab-output="):
			output = arg.trim_prefix("--ab-output=")
	if args.has("--ab-live") and args.has("--ab-video"):
		fail("Choose one of --ab-live or --ab-video")
		return
	if args.has("--ab-live"):
		mode = "live"
	elif args.has("--ab-video"):
		mode = "video"
	resume_requested = args.has("--ab-resume")
	if resume_requested and mode != "video":
		fail("--ab-resume requires --ab-video")
		return
	if not args.has("--view=baghdad"):
		fail("A/B story review requires --view=baghdad")
		return
	if DisplayServer.get_name() == "headless":
		fail("A/B story review requires a real renderer")
		return
	if not output.is_absolute_path() and not output.begins_with("res://"):
		fail("--ab-output must be an absolute path or res:// path")
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output)) != OK:
		fail("Cannot create A/B story output: " + output)
		return
	if not FileAccess.file_exists(SNAPSHOT) or not JSON.parse_string(FileAccess.get_file_as_string(SNAPSHOT)) is Dictionary:
		fail("Missing or invalid frozen rain layout: " + SNAPSHOT)
		return
	if mode == "video":
		var frames_directory: String = output.path_join("frames")
		var directory: DirAccess = DirAccess.open(frames_directory)
		if directory != null and not directory.get_files().is_empty() and not resume_requested:
			fail("A/B story frames directory is occupied; use a new --ab-output directory")
			return
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(frames_directory)) != OK:
			fail("Cannot create A/B story frames directory")
			return
		if resume_requested and not validate_resume_frames(frames_directory):
			return
	root.title = "巴格达 · 先开花再落光 · 空格近景 / R重播"
	root.window_input.connect(_on_window_input)
	root.size = Vector2i(1440, 810)
	viewport = SubViewport.new()
	viewport.name = "ABStoryReviewViewport"
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
		fail("A/B story viewer did not compile")
		return
	viewer = script.new()
	viewport.add_child(viewer)
	var deadline: int = Time.get_ticks_msec() + 60000
	while not bool(viewer.get("ready_for_capture")):
		if Time.get_ticks_msec() > deadline:
			fail("A/B story readiness timeout")
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
		fail("A/B story review requires a valid imported skeletal animation, not a static pose")
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
	var story_script: GDScript = load(STORY_SOURCE) as GDScript
	if story_script == null or not story_script.can_instantiate():
		fail("A/B story layer did not compile: " + STORY_SOURCE)
		return
	story = story_script.new()
	viewer.add_child(story)
	var story_ready: bool = bool(await story.call("configure", viewer, pose, flower, rain))
	if not story_ready or not story.has_method("set_time") or not story.has_method("evidence"):
		fail("A/B story configuration failed; no preview or success evidence was produced")
		return
	story.set_process(false)
	camera = viewer.get("camera") as Camera3D
	camera.make_current()
	original_camera = camera.global_transform
	original_fov = camera.fov
	original_attributes = camera.attributes
	configure_closeup_camera()
	set_scene_time(0.0 if mode == "live" else A_TIME)
	for warmup in WARMUP_FRAMES:
		await draw_frame()
	ready = true
	print("BAGHDAD_AB_REVIEW_READY ", JSON.stringify({"mode":mode, "image_size":[SIZE.x,SIZE.y], "output":output}))
	if mode != "live" and not write_evidence("capture_started"):
		return
	if mode == "live":
		live_started_usec = Time.get_ticks_usec()
		record_story_sample("live_start")
		if not write_evidence("live_ready"):
			return
		print("BAGHDAD_AB_LIVE_PREVIEW_READY ", output)
		return
	if not capture_image("A.png", "A_stable_full_scene"):
		return
	set_scene_time(TRANSITION_TIME)
	for warmup in WARMUP_FRAMES:
		await draw_frame()
	if not capture_image("transition.png", "beam_arriving_before_leaf_glow_full_scene"):
		return
	set_scene_time(B_TIME)
	for warmup in WARMUP_FRAMES:
		await draw_frame()
	if not capture_image("B.png", "B_stable_full_scene"):
		return
	set_closeup(true)
	for warmup in WARMUP_FRAMES:
		await draw_frame()
	if not capture_image("closeup-B.png", "B_character_inspection"):
		return
	set_closeup(false)
	if mode == "video":
		var frame_count: int = int(VIDEO_SECONDS * FPS)
		if resume_start_frame > 0:
			# Reconstruct earlier metadata from the absolute scene clock without
			# replacing a single saved PNG. Mark these samples explicitly.
			for previous in resume_start_frame:
				if previous % FPS == 0 or previous == frame_count - 1:
					set_scene_time(float(previous) / FPS)
					record_story_sample("video_frame_%d" % previous, "resume_reconstructed")
			# Rebuild the preceding volumetric history in sequence at the original
			# camera, including frame N-1, before drawing the first missing frame.
			for history_frame in range(resume_history_start_frame, resume_start_frame):
				set_scene_time(float(history_frame) / FPS)
				await draw_frame()
			print("BAGHDAD_AB_RESUME_READY ", JSON.stringify({"preserved_frames":resume_start_frame, "history_start_frame":resume_history_start_frame}))
		else:
			set_scene_time(0.0)
			for warmup in WARMUP_FRAMES:
				await draw_frame()
		for frame in range(resume_start_frame, frame_count):
			set_scene_time(float(frame) / FPS)
			await draw_frame()
			var filename: String = "frames/f%04d.png" % frame
			if not capture_image(filename, "fixed_full_scene_story", false):
				return
			frame_records.append({"frame":frame, "time_seconds":timeline_seconds, "phase":phase_name(timeline_seconds), "file":filename, "preserved_existing_png":false})
			if frame % FPS == 0 or frame == frame_count - 1:
				record_story_sample("video_frame_%d" % frame)
			if (frame + 1) % 60 == 0:
				print("BAGHDAD_AB_VIDEO_PROGRESS ", frame + 1, "/", frame_count)
	# State probes supplement rendered samples at flower, beam and leaf-glow
	# milestones; they are metadata, not additional captured images.
	for checkpoint in [0.0, 3.0, 4.0, 4.8, 6.2, 8.0, 12.0]:
		set_scene_time(float(checkpoint))
		record_story_sample("state_checkpoint_%.1fs" % float(checkpoint))
	set_scene_time(B_TIME)
	if not write_evidence("complete"):
		return
	if mode == "video":
		print("BAGHDAD_AB_VIDEO_COMPLETE ", JSON.stringify({"frames":frame_records.size(), "fps":FPS, "duration_seconds":VIDEO_SECONDS, "transition_seconds":TRANSITION_END - TRANSITION_START, "output":output}))
	else:
		print("BAGHDAD_AB_STILL_COMPLETE ", output)
	quit(0)

func validate_resume_frames(frames_directory: String) -> bool:
	var directory: DirAccess = DirAccess.open(frames_directory)
	if directory == null:
		fail("Cannot read A/B resume frames directory")
		return false
	var filenames: PackedStringArray = directory.get_files()
	filenames.sort()
	var expected_count: int = int(VIDEO_SECONDS * FPS)
	if filenames.size() > expected_count:
		fail("A/B resume has more files than the %d-frame recording" % expected_count)
		return false
	var png_signature: PackedByteArray = PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])
	var png_end: PackedByteArray = PackedByteArray([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])
	for frame in filenames.size():
		var filename: String = "f%04d.png" % frame
		if filenames[frame] != filename:
			fail("A/B resume requires consecutive f0000.png..fNNNN.png; expected " + filename + ", found " + filenames[frame])
			return false
		var path: String = frames_directory.path_join(filename)
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null or file.get_length() < 45:
			fail("Unreadable or incomplete A/B resume PNG: " + path)
			return false
		file.big_endian = true
		if file.get_buffer(8) != png_signature or file.get_32() != 13 or file.get_buffer(4).get_string_from_ascii() != "IHDR":
			fail("Invalid A/B resume PNG header: " + path)
			return false
		var size: Vector2i = Vector2i(file.get_32(), file.get_32())
		file.seek(file.get_length() - 12)
		var complete: bool = file.get_buffer(12) == png_end
		file.close()
		if size != SIZE or not complete:
			fail("A/B resume PNG must be complete and 1920 x 1080: " + path)
			return false
		var seconds: float = float(frame) / FPS
		frame_records.append({"frame":frame, "time_seconds":seconds, "phase":phase_name(seconds),
			"file":"frames/" + filename, "preserved_existing_png":true})
	resume_start_frame = filenames.size()
	resume_history_start_frame = maxi(resume_start_frame - WARMUP_FRAMES, 0)
	return true

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
	closeup_fill.name = "ABStoryInspectionSoftFill"
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
		set_scene_time(timeline_seconds)

func _on_window_input(event: InputEvent) -> void:
	if not ready or mode != "live" or not event is InputEventKey:
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	# Window input events retain short press/release pairs between render frames.
	# Ignore key-repeat events; no polling path remains to trigger an action twice.
	var key: Key = key_event.physical_keycode if key_event.physical_keycode != KEY_NONE else key_event.keycode
	match key:
		KEY_SPACE:
			set_closeup(not closeup)
			print("BAGHDAD_AB_VIEW ", "closeup" if closeup else "full_scene")
		KEY_R:
			restart_story()
		KEY_P:
			toggle_story_pause()
		_:
			return
	root.set_input_as_handled()

func restart_story() -> void:
	if not ready or mode != "live":
		return
	live_elapsed_base = 0.0
	live_started_usec = Time.get_ticks_usec()
	live_clock_paused = false
	replay_count += 1
	set_scene_time(0.0)
	record_story_sample("live_replay_%d" % replay_count)
	write_evidence("live_restarted")
	print("BAGHDAD_AB_REPLAY ", replay_count)

func live_clock_seconds() -> float:
	if live_clock_paused:
		return live_elapsed_base
	return live_elapsed_base + float(Time.get_ticks_usec() - live_started_usec) / 1000000.0

func toggle_story_pause() -> void:
	if not ready or mode != "live":
		return
	live_elapsed_base = live_clock_seconds()
	live_started_usec = Time.get_ticks_usec()
	live_clock_paused = not live_clock_paused
	set_scene_time(live_elapsed_base)
	var status: String = "live_paused" if live_clock_paused else "live_resumed"
	record_story_sample(status)
	write_evidence(status)
	print("BAGHDAD_AB_CLOCK ", JSON.stringify({"paused":live_clock_paused, "time_seconds":live_elapsed_base}))

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
		set_scene_time(live_clock_seconds())
	RenderingServer.force_draw(false)

func set_scene_time(seconds: float) -> void:
	timeline_seconds = maxf(seconds, 0.0)
	# Only the story controller drives scene state and all animated layers.
	story.call("set_time", timeline_seconds)
	if closeup and camera.attributes is CameraAttributesPractical:
		# A controller may reattach its main-camera attributes while updating the
		# stage. Keep inspection blur changes on a separate resource in that case.
		if camera.attributes == original_attributes:
			camera.attributes = original_attributes.duplicate() as CameraAttributesPractical
		var attributes: CameraAttributesPractical = camera.attributes as CameraAttributesPractical
		attributes.dof_blur_far_enabled = false
		attributes.dof_blur_near_enabled = false

func phase_name(seconds: float) -> String:
	if seconds <= TRANSITION_START:
		return "A"
	if seconds < TRANSITION_END:
		return "A_to_B"
	return "B"

func record_story_sample(label: String, sample_source: String = "current_state") -> void:
	story_samples.append({"label":label, "time_seconds":timeline_seconds,
		"phase":phase_name(timeline_seconds), "sample_source":sample_source, "story":story.call("evidence")})

func capture_image(filename: String, view_name: String, record_capture: bool = true) -> bool:
	var image: Image = viewport.get_texture().get_image()
	var path: String = output.path_join(filename)
	if image == null or image.get_size() != SIZE:
		fail("Invalid A/B story capture: " + path)
		return false
	if image.save_png(path) != OK:
		fail("Cannot save A/B story capture: " + path)
		return false
	if record_capture:
		captures.append({"file":filename, "view":view_name,
			"camera_transform":str(camera.global_transform), "fov_vertical_deg":camera.fov,
			"time_seconds":timeline_seconds, "phase":phase_name(timeline_seconds),
			"inspection_depth_of_field_disabled":closeup,
			"story_lighting":story.call("evidence"),
			"additional_inspection_lights":closeup, "inspection_fill":inspection_fill_evidence()})
		record_story_sample(view_name)
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
	var evidence: Dictionary = {
		"schema":"silkroad.baghdad-ab-story-review.v1", "status":status, "mode":mode,
		"image_size":[SIZE.x,SIZE.y], "msaa":"4x", "warmup_frames_per_camera_or_phase":WARMUP_FRAMES,
		"fps":FPS, "duration_seconds":VIDEO_SECONDS if mode == "video" else 0.0,
		"frame_count":frame_records.size(), "frames":frame_records,
		"resume_requested":resume_requested, "resume_start_frame":resume_start_frame,
		"existing_frames_preserved":resume_start_frame,
		"resume_history_start_frame":resume_history_start_frame,
		"resume_history_frames":resume_start_frame - resume_history_start_frame,
		"resume_validation":"Consecutive filenames, PNG signature/IHDR dimensions and complete IEND; existing PNG bytes are never rewritten",
		"video_camera":"original_full_scene", "fixed_video_camera":true,
		"video_inspection_fill_enabled":false,
		"simulation_step_seconds":1.0 / FPS, "time_seconds":timeline_seconds,
		"phase_schedule":{"initial_state_seconds":0.0, "A_to_B":[TRANSITION_START,TRANSITION_END],
			"flower_growth_seconds":[0.0,4.0], "beam_reveal_seconds":[3.0,8.0],
			"beam_propagation_seconds":[3.0,6.0], "beam_energy_rise_seconds":[3.0,3.8],
			"leaf_glow_and_bounce_seconds":[6.2,8.0], "city_lights_seconds":[4.0,8.0],
			"transition_duration_seconds":TRANSITION_END - TRANSITION_START, "B_stable_video":[TRANSITION_END,VIDEO_SECONDS],
			"live_after_video_end":"Keep B while character, fire, tree and rain continue moving"},
		"timeline_owner":STORY_SOURCE,
		"live_controls":{"space":"toggle character inspection closeup", "R":"restart and play the story from zero", "P":"pause or resume the shared story clock"},
		"live_input":"Window.window_input pressed key events; repeated-key echo ignored; no frame polling",
		"live_clock_paused":live_clock_paused,
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
		"story_source_sha256":FileAccess.get_sha256(STORY_SOURCE),
		"story":story.call("evidence"),
		"story_sample_count":story_samples.size(), "story_samples":story_samples,
		"carrying_pose":pose.call("evidence") if pose.has_method("evidence") else {},
		"flower":flower.call("evidence") if flower.has_method("evidence") else {},
		"rain":rain.call("evidence") if rain.has_method("evidence") else {},
		"storm":storm.call("evidence") if is_instance_valid(storm) and storm.has_method("evidence") else {},
		"rendering_method":RenderingServer.get_current_rendering_method(),
		"rendering_driver":RenderingServer.get_current_rendering_driver_name(),
		"executable":OS.get_executable_path(), "arguments":OS.get_cmdline_args(),
		"user_arguments":OS.get_cmdline_user_args(),
		"wall_seconds":float(Time.get_ticks_usec() - started_usec) / 1000000.0,
		"note":"Actual Godot SubViewport images and frames from the frozen rainy composition. Potatoes sprout and flower during t=0–4. The diagonal beam begins at t=3, travels to the tree by t=6, then leaf emission and warm bounce rise during t=6.2–8; city lights rise during t=4–8. B holds after t=8 while ambient motion continues. Stills inspect t=0, t=4.8 before leaf glow, and t=10. The optional recording lasts twelve seconds at thirty frames per second. The story controller alone drives scene timing. Video uses the unchanged full-scene camera with no inspection fill. Only closeup-B and live inspection enable temporary fill and disable camera depth of field. No image overlays or post grading; capture wall time is not a performance benchmark."
	}
	var file: FileAccess = FileAccess.open(output.path_join("evidence.json"), FileAccess.WRITE)
	if file == null:
		fail("Cannot write A/B story evidence")
		return false
	file.store_string(JSON.stringify(evidence, "\t"))
	file.close()
	return true

func fail(message: String) -> void:
	push_error(message)
	quit(1)
