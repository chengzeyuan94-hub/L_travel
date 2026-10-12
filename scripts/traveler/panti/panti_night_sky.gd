extends RefCounted
## Installs the static Panti night sky. Safe to configure again on a period change.
## Keeps the opaque scene and its DOF intact; adds sharp stars through a soft sky mask.

const SHADER_PATH := "res://shaders/traveler/panti/panti_night_sky.gdshader"
const COMPOSITE_SHADER_PATH := "res://shaders/traveler/panti/panti_night_composite.gdshader"
const PARAMS_PATH := "res://data/traveler/panti_night_sky.json"
const METEOR_PARAMS_PATH := "res://data/traveler/panti_meteors.json"
const COLOR_KEYS := ["zenith_color", "horizon_color", "ground_color", "galaxy_color"]
const DIRECTION_KEYS := ["galaxy_azimuth_relative_camera_deg", "galaxy_azimuth_deg", "galaxy_elevation_deg", "galaxy_tilt_deg"]

var params: Dictionary = {}
var sky: Sky
var material: ShaderMaterial
var mask_viewport: SubViewport
var stars_viewport: SubViewport
var composite_layer: CanvasLayer
var composite_material: ShaderMaterial
var mask_camera: Camera3D
var mask_environment: Environment
var stars_environment: Environment
var sky_flow_rotation := Vector3.ZERO
var sky_flow_active := false
var stars_redraw_pending := true
var night_weight := 1.0
var anim_t := 0.0
var meteor_origin_t := 0.0
var meteor_started := false
var twinkle: Dictionary = {}
var twinkle_transition_active := false
var twinkle_effective_amplitude := 0.18
var day_sky_source: Sky
var meteor_params: Dictionary = {}
var frozen := false
var galaxy_center := Vector3.FORWARD
var galaxy_tangent := Vector3.RIGHT
var galaxy_normal := Vector3.UP
var camera_azimuth_deg := 0.0
var galaxy_azimuth_deg := 0.0
var configured := false

func configure(viewer: Node3D, overrides: Dictionary = {}) -> Sky:
	clear()
	var recipe: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
	params = recipe.parameters.duplicate(true)
	twinkle = recipe.get("twinkle", {}).duplicate(true)
	meteor_params = JSON.parse_string(FileAccess.get_file_as_string(METEOR_PARAMS_PATH))
	for key in overrides:
		params[key] = overrides[key]
	var camera := viewer.get("camera") as Camera3D
	var environment := viewer.get("environment") as Environment
	if camera == null or environment == null:
		push_error("Panti night sky requires the existing camera and Environment")
		return null
	var forward: Vector3 = -camera.global_basis.z.normalized()
	camera_azimuth_deg = rad_to_deg(atan2(forward.x, -forward.z))
	galaxy_azimuth_deg = float(params.get("galaxy_azimuth_deg", camera_azimuth_deg + float(params.galaxy_azimuth_relative_camera_deg)))
	var azimuth := deg_to_rad(galaxy_azimuth_deg)
	var elevation := deg_to_rad(float(params.galaxy_elevation_deg))
	var tilt := deg_to_rad(float(params.galaxy_tilt_deg))
	galaxy_center = Vector3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation)).normalized()
	var sky_right := Vector3(cos(azimuth), 0.0, sin(azimuth)).normalized()
	var sky_up: Vector3 = sky_right.cross(galaxy_center).normalized()
	galaxy_tangent = (sky_right * cos(tilt) + sky_up * sin(tilt)).normalized()
	galaxy_normal = galaxy_center.cross(galaxy_tangent).normalized()
	material = ShaderMaterial.new()
	material.shader = load(SHADER_PATH) as Shader
	if material.shader == null:
		push_error("Missing Panti night sky shader: " + SHADER_PATH)
		return null
	for key in params:
		if key in DIRECTION_KEYS:
			continue
		if key in COLOR_KEYS:
			var rgb: Array = params[key]
			material.set_shader_parameter(key, Color(float(rgb[0]), float(rgb[1]), float(rgb[2])))
		else:
			material.set_shader_parameter(key, params[key])
	material.set_shader_parameter("star_strength", 0.0)
	material.set_shader_parameter("galaxy_center", galaxy_center)
	material.set_shader_parameter("galaxy_tangent", galaxy_tangent)
	material.set_shader_parameter("galaxy_normal", galaxy_normal)
	sky = Sky.new()
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.sky_material = material
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	environment.sky_custom_fov = 0.0
	environment.sky_rotation = Vector3.ZERO
	_install_star_composite(viewer, camera, environment)
	set_night_weight(1.0)
	configured = true
	return sky

func _make_viewport(viewer: Node3D, name_value: String, main: Viewport, share_world: bool) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = name_value
	viewport.size = Vector2i(main.get_visible_rect().size)
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.msaa_3d = main.msaa_3d
	viewport.screen_space_aa = main.screen_space_aa
	viewport.use_taa = main.use_taa
	viewport.use_debanding = main.use_debanding
	viewport.scaling_3d_mode = main.scaling_3d_mode
	viewport.scaling_3d_scale = main.scaling_3d_scale
	viewport.positional_shadow_atlas_size = main.positional_shadow_atlas_size
	viewport.positional_shadow_atlas_16_bits = main.positional_shadow_atlas_16_bits
	if share_world:
		viewport.own_world_3d = false
		viewport.world_3d = viewer.get_world_3d()
	else:
		viewport.own_world_3d = true
	viewer.add_child(viewport)
	return viewport

func _make_camera(viewport: SubViewport, original: Camera3D, environment: Environment, with_dof: bool) -> Camera3D:
	var copy := Camera3D.new()
	copy.name = "MatchingCamera"
	copy.projection = original.projection
	copy.keep_aspect = original.keep_aspect
	copy.fov = original.fov
	copy.near = original.near
	copy.far = original.far
	copy.size = original.size
	copy.frustum_offset = original.frustum_offset
	copy.h_offset = original.h_offset
	copy.v_offset = original.v_offset
	copy.cull_mask = original.cull_mask
	copy.environment = environment
	viewport.add_child(copy)
	copy.global_transform = original.global_transform
	if original.attributes != null:
		# The mask must follow live DOF comparisons on the main camera exactly.
		copy.attributes = original.attributes if with_dof else original.attributes.duplicate(true) as CameraAttributes
		if not with_dof:
			var attributes := copy.attributes as CameraAttributesPractical
			if attributes != null:
				attributes.dof_blur_far_enabled = false
				attributes.dof_blur_near_enabled = false
	copy.make_current()
	return copy

func _install_star_composite(viewer: Node3D, camera: Camera3D, environment: Environment) -> void:
	var main := camera.get_viewport()
	# Same world, geometry, illumination, exposure and DOF; only the visible
	# background differs. Camera.environment avoids mutating the shared world.
	mask_viewport = _make_viewport(viewer, "PantiSkyMaskViewport", main, true)
	mask_environment = environment.duplicate(true) as Environment
	mask_environment.background_mode = Environment.BG_COLOR
	mask_environment.background_color = Color.WHITE
	# Preserve radiance energy: raising it also brightens reflected light on
	# foreground meshes, which would falsely admit stars through their surfaces.
	mask_environment.background_energy_multiplier = environment.background_energy_multiplier
	mask_environment.sky = sky
	mask_environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	mask_camera = _make_camera(mask_viewport, camera, mask_environment, true)
	# Static black-background star light, with the same camera and exposure.
	stars_viewport = _make_viewport(viewer, "PantiStaticStarsViewport", main, false)
	var stars_material := material.duplicate(true) as ShaderMaterial
	for color_key in ["zenith_color", "horizon_color", "ground_color"]:
		stars_material.set_shader_parameter(color_key, Color.BLACK)
	stars_material.set_shader_parameter("galaxy_strength", 0.0)
	stars_material.set_shader_parameter("star_strength", float(params.star_strength))
	stars_material.set_shader_parameter("night_weight", 1.0)
	var stars_sky := Sky.new()
	stars_sky.process_mode = Sky.PROCESS_MODE_QUALITY
	stars_sky.radiance_size = Sky.RADIANCE_SIZE_128
	stars_sky.sky_material = stars_material
	stars_environment = environment.duplicate(true) as Environment
	stars_environment.sky = stars_sky
	stars_environment.background_mode = Environment.BG_SKY
	stars_environment.fog_enabled = false
	stars_environment.volumetric_fog_enabled = false
	stars_environment.glow_enabled = false
	_make_camera(stars_viewport, camera, stars_environment, false)
	composite_material = ShaderMaterial.new()
	composite_material.shader = load(COMPOSITE_SHADER_PATH) as Shader
	composite_material.set_shader_parameter("white_background_texture", mask_viewport.get_texture())
	composite_material.set_shader_parameter("stars_texture", stars_viewport.get_texture())
	composite_material.set_shader_parameter("viewport_size", Vector2(stars_viewport.size))
	for key in meteor_params.uniforms:
		var value: Variant = meteor_params.uniforms[key]
		match str(meteor_params.uniform_types[key]):
			"Vector2":value = Vector2(value[0], value[1])
			"Vector3":value = Vector3(value[0], value[1], value[2])
			"Color":value = Color(value[0], value[1], value[2])
		composite_material.set_shader_parameter(key, value)
	for key in ["twinkle_amplitude", "twinkle_period_min_s", "twinkle_period_max_s"]:
		if twinkle.has(key):composite_material.set_shader_parameter(key, twinkle[key])
	twinkle_effective_amplitude = float(twinkle.get("twinkle_amplitude", 0.18))
	composite_layer = CanvasLayer.new()
	composite_layer.name = "PantiNightStarsComposite"
	composite_layer.layer = 100
	viewer.add_child(composite_layer)
	var rectangle := ColorRect.new()
	rectangle.name = "MaskedStarsOverOriginalScene"
	rectangle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rectangle.size = Vector2(stars_viewport.size)
	rectangle.material = composite_material
	composite_layer.add_child(rectangle)
	rectangle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	stars_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	stars_redraw_pending = false

func set_day_sky(value: Sky) -> void:
	day_sky_source = value
	if material == null or value == null:return
	var day := value.sky_material as ProceduralSkyMaterial
	if day == null:
		push_error("Panti sky transition requires the existing ProceduralSkyMaterial")
		return
	var settings := {
		"day_sky_top_color": day.sky_top_color, "day_sky_horizon_color": day.sky_horizon_color,
		"day_ground_bottom_color": day.ground_bottom_color, "day_ground_horizon_color": day.ground_horizon_color,
		"day_sky_curve": day.sky_curve, "day_ground_curve": day.ground_curve,
		"day_sky_energy": day.sky_energy_multiplier, "day_ground_energy": day.ground_energy_multiplier,
		"day_energy": day.energy_multiplier, "day_sun_angle_max": deg_to_rad(day.sun_angle_max),
		"day_sun_curve": day.sun_curve}
	for key in settings:material.set_shader_parameter(key, settings[key])

func set_anim_time(value: float) -> void:
	if frozen:return
	anim_t = maxf(value, 0.0)
	if night_weight >= 1.0 and not meteor_started:
		meteor_origin_t = anim_t
		meteor_started = true
	if composite_material != null:
		composite_material.set_shader_parameter("anim_t", anim_t)
		composite_material.set_shader_parameter("meteor_t", anim_t-meteor_origin_t if meteor_started else 0.0)

func set_sky_flow(rotation: Vector3, active: bool) -> void:
	var changed := not sky_flow_rotation.is_equal_approx(rotation) or sky_flow_active != active
	if stars_environment != null:
		changed = changed or not stars_environment.sky_rotation.is_equal_approx(rotation)
	sky_flow_rotation = rotation
	sky_flow_active = active
	set_twinkle_transition(active)
	if stars_environment != null and changed:
		# Rotate the celestial environment, never scene geometry or canvas UVs.
		stars_environment.sky_rotation = rotation
		stars_redraw_pending = true
	_update_stars_mode()

func set_twinkle_transition(active: bool) -> void:
	twinkle_transition_active = active
	var steady := float(twinkle.get("twinkle_amplitude", 0.18))
	var transition := float(twinkle.get("twinkle_transition_amplitude", steady))
	twinkle_effective_amplitude = transition if active else steady
	if composite_material != null:
		composite_material.set_shader_parameter("twinkle_amplitude", twinkle_effective_amplitude)

func _update_stars_mode() -> void:
	if not is_instance_valid(stars_viewport):return
	if frozen:
		stars_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	elif sky_flow_active:
		stars_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	elif stars_redraw_pending:
		# Render the final rotation once, then hold the resulting star texture.
		stars_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		stars_redraw_pending = false

func set_night_weight(value: float) -> void:
	var clamped := clampf(value, 0.0, 1.0)
	if material != null and not is_equal_approx(night_weight, clamped):
		material.set_shader_parameter("night_weight", clamped)
	night_weight = clamped
	if night_weight <= 0.0:meteor_started = false
	if composite_material != null:
		composite_material.set_shader_parameter("stars_weight", smoothstep(0.3, 0.9, night_weight))
	if is_instance_valid(composite_layer):composite_layer.visible = night_weight > 0.0
	_update_mask_mode()

func sync_environment(environment: Environment, camera: Camera3D) -> void:
	if mask_environment == null or not is_instance_valid(mask_camera):return
	# Copy the actual interpolated environment, excluding only the intentional
	# white background. Shared resource references preserve all sky illumination.
	for property in environment.get_property_list():
		var key := str(property.name)
		if (int(property.usage) & PROPERTY_USAGE_STORAGE) == 0:continue
		if key in ["script", "resource_path", "resource_name", "resource_local_to_scene", "background_mode", "background_color"]:continue
		mask_environment.set(key, environment.get(key))
	mask_environment.background_mode = Environment.BG_COLOR
	mask_environment.background_color = Color.WHITE
	mask_environment.background_energy_multiplier = environment.background_energy_multiplier
	mask_camera.global_transform = camera.global_transform
	mask_camera.projection = camera.projection
	mask_camera.keep_aspect = camera.keep_aspect
	mask_camera.fov = camera.fov
	mask_camera.near = camera.near
	mask_camera.far = camera.far
	mask_camera.size = camera.size
	mask_camera.frustum_offset = camera.frustum_offset
	mask_camera.h_offset = camera.h_offset
	mask_camera.v_offset = camera.v_offset
	mask_camera.cull_mask = camera.cull_mask
	mask_camera.attributes = camera.attributes
	_update_mask_mode()

func _update_mask_mode() -> void:
	if not is_instance_valid(mask_viewport):return
	if night_weight <= 0.0:
		mask_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	else:
		mask_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE if frozen else SubViewport.UPDATE_ALWAYS

func set_frozen(value: bool) -> void:
	frozen = value
	if value:stars_redraw_pending = true
	_update_mask_mode()
	_update_stars_mode()

func clear() -> void:
	if is_instance_valid(composite_layer):
		composite_layer.visible = false
		composite_layer.free()
	if is_instance_valid(mask_viewport):
		mask_viewport.free()
	if is_instance_valid(stars_viewport):
		stars_viewport.free()
	composite_layer = null
	composite_material = null
	mask_viewport = null
	stars_viewport = null
	mask_camera = null
	mask_environment = null
	stars_environment = null
	sky_flow_rotation = Vector3.ZERO
	sky_flow_active = false
	stars_redraw_pending = true
	day_sky_source = null
	sky = null
	material = null
	night_weight = 1.0
	anim_t = 0.0
	meteor_started = false
	meteor_origin_t = 0.0
	twinkle_transition_active = false
	twinkle_effective_amplitude = 0.18
	frozen = false
	configured = false

func evidence() -> Dictionary:
	return {"schema": "silkroad.panti-night-sky-evidence.v1", "configured": configured,
		"shader": SHADER_PATH, "parameters_source": PARAMS_PATH, "parameters": params.duplicate(true),
		"camera_azimuth_deg_at_configuration": camera_azimuth_deg, "resolved_galaxy_azimuth_deg": galaxy_azimuth_deg,
		"galaxy_center_world": _array(galaxy_center), "galaxy_tangent_world": _array(galaxy_tangent),
		"galaxy_normal_world": _array(galaxy_normal),
		"direction_basis": "EYEDIR; camera-relative configuration resolved once into world-space directions",
		"animation": "shared explicit anim_t modulates final star brightness only; no TIME and no animated sky cubemap",
		"anim_t": anim_t, "night_weight": night_weight, "twinkle": twinkle.duplicate(true),
		"twinkle_transition_active": twinkle_transition_active,
		"twinkle_effective_amplitude": twinkle_effective_amplitude,
		"meteor_time_s": anim_t-meteor_origin_t if meteor_started else 0.0,
		"meteor_started": meteor_started,
		"day_sky_connected": day_sky_source != null,
		"sky_flow": {"rotation_rad": _array(sky_flow_rotation), "active": sky_flow_active,
			"method": "star camera Environment.sky_rotation matches caller's main sky rotation; re-render real EYEDIR star field",
			"updates": "UPDATE_ALWAYS only during active flow; final rotation UPDATE_ONCE then static; frozen holds star viewport",
			"scene_geometry_rotated": false, "canvas_translation": false},
		"meteors": {"parameters_source": METEOR_PARAMS_PATH, "uniforms": meteor_params.get("uniforms", {}).duplicate(true),
			"clock": "same global anim_t as wind, seated idle and star twinkle; no reset per frame",
			"occlusion": "same sky_mask and eased stars_weight as fine stars"},
		"rendering": "opaque original scene with unchanged DOF; final canvas adds star light only through a soft white-background difference mask",
		"main_sky_star_strength": 0.0,
		"star_composite": {"shader": COMPOSITE_SHADER_PATH,
			"mask_viewport_size": [mask_viewport.size.x, mask_viewport.size.y] if is_instance_valid(mask_viewport) else [],
			"mask_world": "same World3D as main scene; no duplicated geometry",
			"mask_camera": "same transform, camera attributes including DOF, exposure, cull mask and viewport quality",
			"mask_background": "white BG_COLOR; original background energy, ambient and reflected sky preserved",
			"stars_viewport": "own empty World3D; black sky with stars only; same view/exposure; no DOF; static except transition sky flow",
			"mask": "smoothstep(0.025, 0.75, max(white_background_rgb - scene_rgb))",
			"frozen": frozen, "depth_writes": "none", "transparent_background": false,
			"validation": "capture must verify fine stars, opaque occlusion and unchanged soft cedar DOF edges"},
		"cubemap_pass": "blue gradient only; detailed stars and Milky Way excluded from reflections and sky irradiance",
		"ambient_light": "controlled independently by the Panti look, not by this helper",
		"implementation_source": "locally written from pasted design suggestions; external sandbox shader bundle was not accessed"}

func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
