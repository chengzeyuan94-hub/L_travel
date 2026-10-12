extends Node3D
## Opt-in rain study. Owns its instances and local wet material copies only.
const STREAK := preload("res://shaders/traveler/baghdad/baghdad_rain_streak.gdshader")
const SPLASH := preload("res://shaders/traveler/baghdad/baghdad_rain_splash.gdshader")
const LENGTH_MULTIPLIER := 1.5
const SPEED_MULTIPLIER := 0.5
const DENSITY_MULTIPLIER := 0.5
var viewer: Node3D
var _materials: Array[ShaderMaterial] = []
var _wet: RefCounted
var _wet_evidence: Dictionary = {}
var _layers: Array[Dictionary] = []
var _splash_count := 0
var _time := 0.0
var _rng := RandomNumberGenerator.new()

func configure(host: Node3D) -> void:
	viewer = host
	name = "BaghdadRainStudy"
	_rng.seed = 20260923
	_wet = load("res://scripts/traveler/baghdad/baghdad_rain_surfaces.gd").new()
	_wet_evidence = _wet.apply(viewer)
	# Thin foreground rain reaches the stones inside the gateway. Perspective
	# makes close drops large, so these two layers use narrower, shorter geometry.
	_build_rain_layer("InsideArchRain", 130, 0.65, 1.5, 2.5, 3.8, 0.00045, 0.0233333, 0.18, 0.08)
	_build_rain_layer("ForegroundRain", 240, 1.5, 3.2, 3.4, 4.8, 0.0012, 0.0433333, 0.24, 0.10)
	_build_rain_layer("NearRain", 380, 3.2, 6.0, 5.5, 5.8, 0.0035, 0.075, 0.34)
	_build_rain_layer("MiddleRain", 1250, 6.0, 15.0, 10.0, 7.8, 0.008, 0.18, 0.30)
	_build_rain_layer("DistantRain", 1650, 15.0, 30.0, 15.0, 9.0, 0.011, 0.32, 0.14)
	_build_rain_layer("TreeFrontRain", 300, 8.8, 10.5, 8.5, 7.8, 0.004, 0.1466667, 0.22, 0.20, Vector2(-4.0, 0.8))
	_build_splashes()
	set_time(0.0)
	print("BAGHDAD_RAIN_READY ", JSON.stringify(evidence()))

func _build_rain_layer(label: String, count: int, z0: float, z1: float,
		height: float, speed: float, width: float, length_value: float, alpha: float,
		drift: float = 0.20, horizontal_range: Vector2 = Vector2.ZERO) -> void:
	var material := ShaderMaterial.new()
	material.shader = STREAK
	material.set_shader_parameter("fall_height", height)
	material.set_shader_parameter("fall_speed", speed * SPEED_MULTIPLIER)
	material.set_shader_parameter("streak_width", width)
	material.set_shader_parameter("streak_length", length_value * LENGTH_MULTIPLIER)
	material.set_shader_parameter("opacity", alpha)
	material.set_shader_parameter("horizontal_drift", drift)
	var beam: SpotLight3D = viewer.storm_look.tree_beam
	material.set_shader_parameter("beam_position", beam.global_position)
	material.set_shader_parameter("beam_direction", -beam.global_basis.z.normalized())
	material.set_shader_parameter("beam_cos_outer", cos(deg_to_rad(beam.spot_angle)))
	_materials.append(material)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = material
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = quad
	multi.instance_count = count
	# Keep the seeded instances and other layers' random state unchanged;
	# render exactly half of each existing layer.
	multi.visible_instance_count = roundi(float(count) * DENSITY_MULTIPLIER)
	multi.custom_aabb = AABB(Vector3(-24.0, -2.0, 0.4), Vector3(48.0, 26.0, 33.0))
	for index in count:
		var z := _rng.randf_range(z0, z1)
		var x := _rng.randf_range(-z * 0.64, z * 0.64)
		if horizontal_range != Vector2.ZERO:
			x = _rng.randf_range(horizontal_range.x, horizontal_range.y)
		var floor_height: float = viewer.ground_surface.height_at(Vector2(-x, z))
		multi.set_instance_transform(index, Transform3D(Basis.IDENTITY, Vector3(x, floor_height + 0.025, z)))
		multi.set_instance_custom_data(index, Color(_rng.randf(), _rng.randf(), _rng.randf(), _rng.randf()))
	var instance := MultiMeshInstance3D.new()
	instance.name = label
	instance.multimesh = multi
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	_layers.append({"name":label, "count":multi.visible_instance_count, "allocated_instances":count, "depth":[z0,z1],
		"fall_speed":speed * SPEED_MULTIPLIER, "streak_length":length_value * LENGTH_MULTIPLIER,
		"streak_width":width, "opacity":alpha, "horizontal_drift":drift})

func _build_splashes() -> void:
	var positions: Array[Vector3] = []
	for attempt in 360:
		var z := _rng.randf_range(0.70, 7.5)
		var half_width := minf(1.8, z * 0.62)
		var x := _rng.randf_range(-half_width, half_width)
		# Character and campfire exclusions are measured in stage coordinates.
		if Vector2(x - 0.47, z - 2.79).length() < 0.28 or Vector2(x + 0.43, z - 3.5).length() < 0.38:
			continue
		var y := NAN
		if _wet.has_method("sample_surface_height"):
			y = float(_wet.sample_surface_height(x,z))
		if is_nan(y):
			y = float(viewer.ground_surface.height_at(Vector2(-x,z)))
		positions.append(Vector3(x, y + 0.007, z))
	var material := ShaderMaterial.new()
	material.shader = SPLASH
	_materials.append(material)
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	plane.material = material
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = plane
	multi.instance_count = positions.size()
	for index in positions.size():
		var radius := _rng.randf_range(0.020, 0.045)
		multi.set_instance_transform(index, Transform3D(Basis.IDENTITY.scaled(Vector3(radius,1.0,radius)), positions[index]))
		multi.set_instance_custom_data(index, Color(_rng.randf(), _rng.randf(), _rng.randf(), 1.0))
	var instance := MultiMeshInstance3D.new()
	instance.name = "PavingRainSplashes"
	instance.multimesh = multi
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	_splash_count = positions.size()

func set_time(seconds: float) -> void:
	_time = seconds
	for material in _materials:
		material.set_shader_parameter("rain_time", seconds)
	if _wet != null and _wet.has_method("set_time"):
		_wet.set_time(seconds * SPEED_MULTIPLIER)

func evidence() -> Dictionary:
	return {"preset":"baghdad/spring-rain", "rain_layers":_layers, "splash_instances":_splash_count,
		"length_multiplier_vs_first_rain":LENGTH_MULTIPLIER, "speed_multiplier_vs_first_rain":SPEED_MULTIPLIER,
		"density_multiplier_vs_spring_rain":DENSITY_MULTIPLIER,
		"rain_inside_gateway":true, "tree_front_rain":true, "splash_depth_range":[0.70,7.5],
		"time_seconds":_time, "seed":20260923, "world_space_depth_occlusion":true,
		"wet_surface":_wet_evidence, "camera_and_layout_modified":false,
		"tree_glow_and_tyndall_preserved":true}

func _exit_tree() -> void:
	if _wet != null:
		_wet.restore()
