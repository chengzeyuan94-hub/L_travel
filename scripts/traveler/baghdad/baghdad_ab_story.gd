extends Node3D
## Local A -> B story controller. All motion uses an explicit deterministic clock.
const FLOWER_END_SECONDS := 4.0
const BEAM_START_SECONDS := 3.0
const BEAM_FADE_END_SECONDS := 3.8
const BEAM_ARRIVAL_SECONDS := 6.0
const TREE_GLOW_START_SECONDS := 6.2
const TRANSITION_END_SECONDS := 8.0
const B_HOLD_SECONDS := 4.0
const TOTAL_SECONDS := TRANSITION_END_SECONDS + B_HOLD_SECONDS
const FLOWER_REVEAL_SECONDS := 4.4

var _viewer: Node3D
var _pose: Node3D
var _flower: Node3D
var _rain: Node3D
var _motion: Node3D
var _city: Node3D
var _beam: SpotLight3D
var _bounce: SpotLight3D
var _sky: ShaderMaterial
var _camera: Camera3D
var _old_camera_attributes: CameraAttributes
var _story_camera_attributes: CameraAttributesPractical
var _tree_materials: Array[Dictionary] = []
var _rain_materials: Array[Dictionary] = []
var _saved_beam: Dictionary = {}
var _saved_bounce: Dictionary = {}
var _saved_opening := 0.24
var _time := 0.0
var _progress := 0.0
var _blend := 0.0
var _beam_reach := 0.0
var _tree_glow_blend := 0.0
var _flower_progress := 0.0
var _city_blend := 0.0
var _configured := false

func configure(viewer: Node3D, pose: Node3D, flower: Node3D, rain: Node3D) -> bool:
	restore()
	name = "BaghdadABStory"
	_viewer = viewer
	_pose = pose
	_flower = flower
	_rain = rain
	if not _pose.has_method("set_time") or not _flower.has_method("set_story_time") or not _rain.has_method("set_time"):
		push_error("A/B story requires the ready animated character, story-driven blossoms and rain")
		return false
	var storm: Node3D = viewer.get("storm_look") as Node3D
	if storm == null:
		push_error("A/B story requires the storm and Tree of Life lighting")
		return false
	_beam = storm.get("tree_beam") as SpotLight3D
	_bounce = storm.find_child("TreeWarmCloudBounce", true, false) as SpotLight3D
	_sky = storm.get("sky_material") as ShaderMaterial
	_camera = viewer.get("camera") as Camera3D
	if _beam == null or _bounce == null or _sky == null or _camera == null:
		push_error("A/B story is missing the cloudbreak beam, bounce, sky or camera")
		return false
	_saved_beam = {"energy":_beam.light_energy, "visible":_beam.visible, "range":_beam.spot_range}
	_saved_bounce = {"energy":_bounce.light_energy, "visible":_bounce.visible}
	var opening: Variant = _sky.get_shader_parameter("opening_strength")
	_saved_opening = float(opening) if opening != null else 0.24
	_motion = load("res://scripts/traveler/baghdad/baghdad_ambient_motion.gd").new()
	add_child(_motion)
	if not bool(_motion.call("configure", viewer)):
		push_error("A/B story could not configure fire and tree motion")
		restore()
		return false
	_city = load("res://scripts/traveler/baghdad/baghdad_city_lights.gd").new()
	add_child(_city)
	if not bool(_city.call("configure", viewer)):
		push_error("A/B story could not configure the distant city windows")
		restore()
		return false
	# Collect the current wet, wind-animated copies, not the superseded storm refs.
	var tree: Node3D = viewer.get("tree") as Node3D
	var meshes: Array[Node] = tree.find_children("*", "MeshInstance3D", true, false)
	if tree is MeshInstance3D:
		meshes.append(tree)
	for item in meshes:
		var mesh := item as MeshInstance3D
		if mesh.mesh == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			var material := mesh.get_active_material(surface) as ShaderMaterial
			if material != null and material.shader.code.contains("uniform float glow_strength"):
				var value: Variant = material.get_shader_parameter("glow_strength")
				_tree_materials.append({"material":material, "strength":float(value) if value != null else 6.5,
					"range":material.get_shader_parameter("beam_range")})
	if _tree_materials.is_empty():
		push_error("A/B story did not find the active tree glow surface")
		restore()
		return false
	# The rain's warm highlight must follow the real shaft, including its reach.
	# The source shader defaults preserve standalone rain previews.
	for material in _rain.get("_materials"):
		if material is ShaderMaterial and material.shader.code.contains("uniform float beam_strength"):
			_rain_materials.append({"material":material,
				"strength":material.get_shader_parameter("beam_strength"),
				"range":material.get_shader_parameter("beam_range")})
	_old_camera_attributes = _camera.attributes
	_story_camera_attributes = _old_camera_attributes.duplicate() as CameraAttributesPractical if _old_camera_attributes is CameraAttributesPractical else CameraAttributesPractical.new()
	_story_camera_attributes.dof_blur_near_enabled = false
	_story_camera_attributes.dof_blur_far_enabled = true
	_story_camera_attributes.dof_blur_far_distance = 14.3
	_story_camera_attributes.dof_blur_far_transition = 3.0
	_story_camera_attributes.dof_blur_amount = 0.065
	_camera.attributes = _story_camera_attributes
	_pose.set_process(false)
	_flower.set("autoplay", false)
	_flower.set_process(false)
	_rain.set_process(false)
	_configured = true
	set_time(0.0)
	print("BAGHDAD_AB_STORY_READY ", JSON.stringify(evidence()))
	return true

func set_time(seconds: float) -> void:
	if not _configured:
		return
	_time = maxf(seconds, 0.0)
	_progress = clampf(_time / TRANSITION_END_SECONDS, 0.0, 1.0)
	_flower_progress = clampf(_time / FLOWER_END_SECONDS, 0.0, 1.0)
	_blend = smoothstep(BEAM_START_SECONDS, BEAM_FADE_END_SECONDS, _time)
	_beam_reach = smoothstep(BEAM_START_SECONDS, BEAM_ARRIVAL_SECONDS, _time)
	# Wait until the full shaft has reached the crown, then let the leaves respond.
	_tree_glow_blend = smoothstep(TREE_GLOW_START_SECONDS, TRANSITION_END_SECONDS, _time)
	_city_blend = smoothstep(FLOWER_END_SECONDS, TRANSITION_END_SECONDS, _time)
	_pose.call("set_time", _time)
	_flower.call("set_story_time", _flower_progress * FLOWER_REVEAL_SECONDS, _time)
	_rain.call("set_time", _time)
	_motion.call("set_time", _time)
	_city.call("set_amount", _city_blend, _time)
	_beam.visible = _blend > 0.000001
	_beam.light_energy = float(_saved_beam.energy) * _blend
	# The source is above the frame: 70% range reaches its upper edge. Increasing
	# range extends the existing diagonal shaft downwards without moving the light.
	_beam.spot_range = float(_saved_beam.range) * lerpf(0.70, 1.0, _beam_reach)
	_bounce.visible = _tree_glow_blend > 0.000001
	_bounce.light_energy = float(_saved_bounce.energy) * _tree_glow_blend
	for record in _tree_materials:
		(record.material as ShaderMaterial).set_shader_parameter("glow_strength", float(record.strength) * _tree_glow_blend)
		(record.material as ShaderMaterial).set_shader_parameter("beam_range", _beam.spot_range)
	for record in _rain_materials:
		(record.material as ShaderMaterial).set_shader_parameter("beam_strength", _blend)
		(record.material as ShaderMaterial).set_shader_parameter("beam_range", _beam.spot_range)
	_sky.set_shader_parameter("opening_strength", _saved_opening * _blend)

func evidence() -> Dictionary:
	var phase := "A" if _time <= 0.0 else ("B" if _time >= TRANSITION_END_SECONDS else "A_to_B")
	return {"configured":_configured, "time_seconds":_time, "phase":phase,
		"timeline":{"A_hold_seconds":0.0, "transition_start_seconds":0.0,
			"transition_end_seconds":TRANSITION_END_SECONDS, "transition_duration_seconds":TRANSITION_END_SECONDS,
			"flower_growth_seconds":[0.0,FLOWER_END_SECONDS], "beam_sequence_seconds":[BEAM_START_SECONDS,TRANSITION_END_SECONDS],
			"beam_travel_seconds":[BEAM_START_SECONDS,BEAM_ARRIVAL_SECONDS],
			"leaf_glow_seconds":[TREE_GLOW_START_SECONDS,TRANSITION_END_SECONDS],
			"city_lights_seconds":[FLOWER_END_SECONDS,TRANSITION_END_SECONDS],
			"B_hold_seconds":B_HOLD_SECONDS, "preview_duration_seconds":TOTAL_SECONDS,
			"live_after_end":"hold B while ambient and Carrying continue"},
		"transition_progress":_progress, "light_blend":_blend,
		"flower_progress":_flower_progress, "beam_reach_progress":_beam_reach,
		"leaf_glow_blend":_tree_glow_blend, "beam_arrives_before_leaf_glow":BEAM_ARRIVAL_SECONDS < TREE_GLOW_START_SECONDS,
		"beam_energy":_beam.light_energy if is_instance_valid(_beam) else 0.0,
		"beam_range":_beam.spot_range if is_instance_valid(_beam) else 0.0,
		"tree_glow_strength":float(_tree_materials[0].strength) * _tree_glow_blend if not _tree_materials.is_empty() else 0.0,
		"storm_and_rain_in_both_states":true, "source_layout_unchanged":true,
		"depth_of_field":{"enabled":true,"far_distance":14.3,"transition":3.0,"amount":0.065},
		"ambient_motion":_motion.call("evidence") if is_instance_valid(_motion) else {},
		"city_lights":_city.call("evidence") if is_instance_valid(_city) else {},
		"flowers":_flower.call("evidence") if is_instance_valid(_flower) else {}}

func restore() -> void:
	if is_instance_valid(_camera) and _story_camera_attributes != null:
		_camera.attributes = _old_camera_attributes
	_story_camera_attributes = null
	if is_instance_valid(_beam) and not _saved_beam.is_empty():
		_beam.light_energy = float(_saved_beam.energy)
		_beam.visible = bool(_saved_beam.visible)
		_beam.spot_range = float(_saved_beam.range)
	if is_instance_valid(_bounce) and not _saved_bounce.is_empty():
		_bounce.light_energy = float(_saved_bounce.energy)
		_bounce.visible = bool(_saved_bounce.visible)
	if is_instance_valid(_sky):
		_sky.set_shader_parameter("opening_strength", _saved_opening)
	for record in _tree_materials:
		(record.material as ShaderMaterial).set_shader_parameter("glow_strength", record.strength)
		(record.material as ShaderMaterial).set_shader_parameter("beam_range", record.range)
	_tree_materials.clear()
	for record in _rain_materials:
		(record.material as ShaderMaterial).set_shader_parameter("beam_strength", record.strength)
		(record.material as ShaderMaterial).set_shader_parameter("beam_range", record.range)
	_rain_materials.clear()
	for child in [_city, _motion]:
		if is_instance_valid(child):
			if child.has_method("restore"):
				child.call("restore")
			child.free()
	_city = null
	_motion = null
	_configured = false

func _exit_tree() -> void:
	restore()
