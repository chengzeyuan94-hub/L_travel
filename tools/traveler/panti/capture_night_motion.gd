extends SceneTree
## Isolated night-motion evidence. The production freeze remains active while
## this tool explicitly samples only the sky composite and fortress light clocks.
## Run with --view=panti --midnight --motion-output=<new absolute directory>.

var viewport: SubViewport
var viewer: Node3D
var night_sky: RefCounted
var composite: ShaderMaterial
var output := ""
var samples: Array = []
var weather_reference := ""
var frozen_world_time := 0.0
var normal_twinkle := 0.18
var normal_meteor_brightness := 1.15

func _initialize() -> void:
	call_deferred("run")

func frame() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--motion-output="):
			output = arg.trim_prefix("--motion-output=")
	if output.is_empty() or not output.is_absolute_path() or DirAccess.dir_exists_absolute(output):
		push_error("Provide --motion-output=<new absolute directory>")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var preview := TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer = load("res://scenes/traveler/panti_main.tscn").instantiate()
	viewport.add_child(viewer)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	while viewer.period_lighting == null:
		await frame()
	viewer.set_lighting_period("midnight")
	for i in 120:
		await frame()
	night_sky = viewer.look_profile.night_sky
	assert(night_sky != null and night_sky.configured, "Midnight sky must be configured")
	assert(viewer.period_transition != null and not viewer.period_transition.active, "Use a settled midnight endpoint")
	composite = night_sky.composite_material
	normal_twinkle = float(night_sky.twinkle.get("twinkle_amplitude", 0.18))
	normal_meteor_brightness = float(night_sky.meteor_params.uniforms.meteor_brightness)
	viewer.set_motion_frozen(true)
	for i in 5:
		await frame()
	frozen_world_time = viewer.weather.anim_t
	weather_reference = JSON.stringify(viewer.weather.evidence())
	# The common scene, particles, fire and character stay frozen in every group.
	# Combined frames are for review; only isolated groups attribute pixel changes.
	for time_s in [0.0, 2.0, 4.0, 6.0]:
		await capture_sample("combined-%02d" % int(time_s), "combined", time_s, time_s,
			time_s, normal_twinkle, normal_meteor_brightness)
	for time_s in [0.0, 2.0, 4.0, 6.0]:
		await capture_sample("stars-%02d" % int(time_s), "stars_only", time_s, 0.0,
			0.0, normal_twinkle, 0.0)
	for time_s in [0.0, 2.0, 4.0, 6.0]:
		await capture_sample("lamps-%02d" % int(time_s), "lamps_only", 0.0, time_s,
			0.0, normal_twinkle, 0.0)
	var meteor_times := [3.6, 8.1, 13.4]
	for index in meteor_times.size():
		var meteor_time: float = meteor_times[index]
		var label := "meteor-%02d" % (index + 1)
		await capture_sample(label + "-baseline", "meteor_baseline", 0.0, 0.0,
			meteor_time, 0.0, 0.0, index)
		await capture_sample(label + "-active", "meteor_only", 0.0, 0.0,
			meteor_time, 0.0, normal_meteor_brightness, index)
	var unchanged: bool = viewer.weather.anim_t == frozen_world_time and JSON.stringify(viewer.weather.evidence()) == weather_reference
	var isolated_period: String = viewer.lighting_period
	# Evaluate isolation before restoring production time for the separate flow test.
	var flow_report: Dictionary = await audit_flow_freeze()
	var report := {
		"schema": "silkroad.panti-isolated-night-motion.v1",
		"image_size": [1920, 1080], "period": isolated_period,
		"output": output, "same_process": true, "settling_frames_per_sample": 5,
		"frozen_world_time_s": frozen_world_time, "background_motion_unchanged": unchanged,
		"samples": samples, "capture_count": samples.size(),
		"flow_freeze": flow_report,
		"isolation": {
			"combined": "Only sky and castle clocks advance; explicit meteor_t equals sample time",
			"stars_only": "Castle time=0; meteors disabled; sky clock=0/2/4/6",
			"lamps_only": "Sky clock=0; meteors disabled; castle clock=0/2/4/6",
			"meteor_only": "Twinkle amplitude=0; sky and castle clocks=0; three explicit meteor times, each paired with brightness=0 baseline",
			"background": "Production weather freeze holds tree wind, character, fire, mist and snow throughout",
		},
		"pixel_verdict": "Not evaluated here. Compare saved PNG pairs to measure actual visible pixels and meteor head locations.",
	}
	FileAccess.open(output + "/night-motion-check.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("PANTI_NIGHT_MOTION_CAPTURE ", JSON.stringify({"output": output, "samples": samples.size(), "background_motion_unchanged": unchanged, "flow_freeze_passed": flow_report.passed}))
	quit(0 if unchanged and bool(flow_report.passed) else 1)

func audit_flow_freeze() -> Dictionary:
	# Restore the two diagnostic uniforms, then let the real weather clock own
	# all animation again. No manual sky/lamp samples occur in this section.
	composite.set_shader_parameter("twinkle_amplitude", normal_twinkle)
	composite.set_shader_parameter("meteor_brightness", normal_meteor_brightness)
	viewer.set_motion_frozen(false)
	night_sky.set_anim_time(viewer.weather.anim_t)
	viewer.castle_lighting.set_anim_time(viewer.weather.anim_t)
	viewer.request_lighting_period("morning")
	var frames_to_half := 0
	while viewer.period_transition.active and viewer.period_transition.weight > 0.5 and frames_to_half < 10000:
		await frame()
		frames_to_half += 1
	var midpoint_reached: bool = viewer.period_transition.active and viewer.period_transition.weight >= 0.45 and viewer.period_transition.weight <= 0.5
	viewer.set_motion_frozen(true)
	var elapsed_before: float = viewer.period_transition.elapsed
	var yaw_before: float = viewer.period_transition.sky_yaw
	var weather_before: float = viewer.weather.anim_t
	var weight_before: float = viewer.period_transition.weight
	var actual_rotation_before: Vector3 = viewer.environment.sky_rotation
	var sky_rotation_before: Vector3 = night_sky.sky_flow_rotation
	for i in 5:
		await frame()
	var frozen_image := viewport.get_texture().get_image()
	assert(frozen_image.get_size() == Vector2i(1920, 1080))
	assert(frozen_image.save_png(output + "/flow-freeze.png") == OK)
	var reference := frozen_image.get_data()
	var equal_pairs := 0
	var elapsed_held := true
	var yaw_held := true
	var weather_held := true
	var actual_rotation_held := true
	for i in 30:
		await frame()
		var current := viewport.get_texture().get_image()
		if current.get_data() == reference:
			equal_pairs += 1
		else:
			assert(current.save_png(output + "/flow-freeze-difference-%02d.png" % i) == OK)
		elapsed_held = elapsed_held and viewer.period_transition.elapsed == elapsed_before
		yaw_held = yaw_held and viewer.period_transition.sky_yaw == yaw_before
		weather_held = weather_held and viewer.weather.anim_t == weather_before
		actual_rotation_held = actual_rotation_held and viewer.environment.sky_rotation == actual_rotation_before and night_sky.sky_flow_rotation == sky_rotation_before
	var frozen_state: Dictionary = viewer.period_transition.evidence()
	viewer.set_motion_frozen(false)
	for i in 10:
		await frame()
	var elapsed_resumed: bool = viewer.period_transition.elapsed > elapsed_before
	var weather_resumed: bool = viewer.weather.anim_t > weather_before
	var yaw_resumed: bool = viewer.period_transition.sky_yaw != yaw_before
	var result := {
		"schema": "silkroad.panti-sky-flow-freeze.v1",
		"image_size": [1920, 1080], "image": output + "/flow-freeze.png",
		"production_clock_restored": true, "frames_to_midpoint": frames_to_half,
		"midpoint_reached": midpoint_reached, "night_weight_at_freeze": weight_before,
		"settling_frames": 5, "compared_pairs": 30, "exactly_equal_pairs": equal_pairs,
		"elapsed_before_s": elapsed_before, "elapsed_unchanged": elapsed_held,
		"sky_yaw_before_rad": yaw_before, "sky_yaw_unchanged": yaw_held,
		"actual_main_and_star_rotations_unchanged": actual_rotation_held,
		"weather_time_before_s": weather_before, "weather_clock_unchanged": weather_held,
		"frozen_transition": frozen_state, "resume_frames": 10,
		"elapsed_continues_after_resume": elapsed_resumed,
		"weather_clock_continues_after_resume": weather_resumed,
		"sky_yaw_continues_after_resume": yaw_resumed,
		"resumed_transition": viewer.period_transition.evidence(),
		"passed": midpoint_reached and equal_pairs == 30 and elapsed_held and yaw_held and weather_held and actual_rotation_held and elapsed_resumed and weather_resumed and yaw_resumed,
	}
	FileAccess.open(output + "/flow-freeze.json", FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	return result

func capture_sample(label: String, kind: String, sky_time: float, lamp_time: float,
		meteor_time: float, twinkle_amplitude: float, meteor_brightness: float,
		meteor_index: int = -1) -> void:
	# This begins its three-frame refresh immediately and clears helper.frozen
	# before its first await. Setting sky time before refresh would be ignored.
	viewer.refresh_frozen_viewport()
	night_sky.set_anim_time(sky_time)
	viewer.castle_lighting.set_anim_time(lamp_time)
	# Explicitly override meteor_t after set_anim_time's normal origin calculation.
	composite.set_shader_parameter("meteor_t", meteor_time)
	composite.set_shader_parameter("twinkle_amplitude", twinkle_amplitude)
	composite.set_shader_parameter("meteor_brightness", meteor_brightness)
	for i in 5:
		await frame()
	assert(viewer.weather.frozen and viewer.weather.anim_t == frozen_world_time,
		"Background motion advanced during an isolated capture")
	var image := viewport.get_texture().get_image()
	assert(image.get_size() == Vector2i(1920, 1080), "Capture must be fixed 1920x1080")
	var png_path := output + "/" + label + ".png"
	assert(image.save_png(png_path) == OK, "Night motion PNG save failed")
	var record := {
		"label": label, "kind": kind, "image": png_path, "image_size": [1920, 1080],
		"manual_times_s": {"sky": sky_time, "castle": lamp_time, "meteor": meteor_time},
		"composite_uniforms": {
			"anim_t": composite.get_shader_parameter("anim_t"),
			"meteor_t": composite.get_shader_parameter("meteor_t"),
			"twinkle_amplitude": composite.get_shader_parameter("twinkle_amplitude"),
			"meteor_brightness": composite.get_shader_parameter("meteor_brightness"),
			"stars_weight": composite.get_shader_parameter("stars_weight"),
		},
		"sky": night_sky.evidence(), "castle_lights": viewer.castle_lighting.evidence(),
		"frozen_world_time_s": frozen_world_time,
		"background_motion_unchanged": JSON.stringify(viewer.weather.evidence()) == weather_reference,
		"main_viewport_update_mode": viewport.render_target_update_mode,
		"meteor_index": meteor_index,
		"meteor_time_note": "composite_uniforms.meteor_t is authoritative; this tool intentionally overrides helper-origin meteor time",
	}
	if meteor_index >= 0:
		var uniforms: Dictionary = night_sky.meteor_params.uniforms
		var start: Array = uniforms["meteor_start_%d_px" % meteor_index]
		var direction_array: Array = uniforms.meteor_direction
		var direction := Vector2(direction_array[0], direction_array[1]).normalized()
		var age := meteor_time - float(uniforms.meteor_start_times_s[meteor_index])
		var nominal_head := Vector2(start[0], start[1]) + direction * float(uniforms.meteor_travel_px[meteor_index]) * age / float(uniforms.meteor_lifetimes_s[meteor_index])
		record["nominal_unoccluded_meteor_head_px"] = [nominal_head.x, nominal_head.y]
		record["meteor_head_note"] = "Analytic shader target only; actual visible head must be measured from active-minus-baseline PNGs"
	FileAccess.open(output + "/" + label + ".json", FileAccess.WRITE).store_string(JSON.stringify(record, "\t"))
	samples.append(record)
