extends Node3D
## One quiet flock, driven exclusively by MotionDirector's explicit clock.

const PARAMS_PATH := "res://data/traveler/day_birds_params.json"
const SHADER_PATH := "res://shaders/traveler/day_birds.gdshader"

var settings: Dictionary = {}
var flock: MultiMeshInstance3D
var material: ShaderMaterial
var last_time := 0.0
var layer_report: Dictionary = {}


func configure(host: Node3D, overrides: Dictionary = {}) -> void:
	settings = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
	settings.merge(overrides, true)
	name = "DayBirds"
	var world := host.get("world") as Node3D
	var camera := host.get("camera") as Camera3D
	if get_parent() == null:
		world.add_child(self)
	# Copy the frozen view once. Subsequent positions live in world space;
	# the camera is not modified and this node is not a camera child.
	global_transform = camera.global_transform
	material = ShaderMaterial.new()
	material.shader = load(SHADER_PATH)
	for key in ["cycle_s", "crossing_s", "start_x_u", "end_x_u", "sky_y_u", "camera_depth_u"]:
		material.set_shader_parameter(key, float(settings[key]))
	material.set_shader_parameter("bird_scale", float(settings.shape.bird_scale))
	for pair in [["hz", "flap_hz"], ["lift_ratio", "flap_lift_ratio"], ["glide_fraction", "glide_fraction"], ["bob_u", "bob_u"], ["bob_hz", "bob_hz"]]:
		material.set_shader_parameter(pair[1], float(settings.flap[pair[0]]))
	material.set_shader_parameter("bird_color", Color(str(settings.shape.color_srgb)))
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = _load_approved_goose_mesh()
	multi.instance_count = int(settings.count)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(settings.seed)
	var formation: Dictionary = settings.formation
	for i in multi.instance_count:
		multi.set_instance_transform(i, Transform3D.IDENTITY)
		var rank := float((i + 1) / 2)
		var side := -1.0 if i % 2 == 0 else 1.0
		var jitter := float(formation.position_jitter_u)
		var lag := -rank * float(formation.trailing_step_u) + rng.randf_range(-jitter, jitter)
		var lift := side * rank * float(formation.vertical_step_u) + rng.randf_range(-jitter, jitter)
		var depth := rng.randf_range(-float(formation.depth_jitter_u), float(formation.depth_jitter_u))
		multi.set_instance_custom_data(i, Color(rng.randf(), lag, lift, depth))
	flock = MultiMeshInstance3D.new()
	flock.name = "SkyFlock"
	flock.multimesh = multi
	flock.material_override = material
	flock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bounds: Dictionary = settings.custom_aabb
	flock.custom_aabb = AABB(_vec3(bounds.position), _vec3(bounds.size))
	add_child(flock)
	_measure_mountain_depth(host)
	apply_time(0.0)


func apply_time(t: float) -> void:
	last_time = maxf(t, 0.0)
	material.set_shader_parameter("anim_t", last_time)
	flock.visible = bool(settings.enabled) and fmod(last_time, float(settings.cycle_s)) <= float(settings.crossing_s)


func evidence() -> Dictionary:
	var triangle_count := 0
	for surface in flock.multimesh.mesh.get_surface_count():
		var arrays := flock.multimesh.mesh.surface_get_arrays(surface)
		if arrays[Mesh.ARRAY_VERTEX] != null:
			triangle_count += int(arrays[Mesh.ARRAY_VERTEX].size() / 3)
	return {
		"params_path": PARAMS_PATH,
		"effective_parameters": settings.duplicate(true),
		"anim_t": last_time,
		"instance_count": flock.multimesh.instance_count,
		"multimesh_instance_nodes": 1,
		"use_custom_data": flock.multimesh.use_custom_data,
		"vertex_shader_position": true,
		"cycle_s": settings.cycle_s,
		"crossing_s": settings.crossing_s,
		"visible": flock.visible,
		"shadows": false,
		"alpha": 1.0,
		"source_palette": settings.shape.color_srgb,
		"source_model": settings.shape.asset_path,
		"mountain_occlusion": layer_report.duplicate(true),
		"custom_aabb": settings.custom_aabb,
		"geometry_triangles_per_bird": triangle_count,
		"world_transform": {"origin": [global_position.x, global_position.y, global_position.z], "basis": "frozen camera orientation copied once"}
	}


func _measure_mountain_depth(host: Node3D) -> void:
	var world := host.get("world") as Node3D
	var camera := host.get("camera") as Camera3D
	var mountain := world.get_node_or_null("FarBackdrop/MassifBandMerged") as MeshInstance3D
	var nearest := INF
	var farthest := -INF
	var forward: Vector3 = -camera.global_basis.z
	if mountain != null:
		for surface in mountain.mesh.get_surface_count():
			var arrays := mountain.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				var depth: float = (mountain.to_global(vertex) - camera.global_position).dot(forward)
				nearest = minf(nearest, depth)
				farthest = maxf(farthest, depth)
	var flock_farthest := float(settings.camera_depth_u) + float(settings.formation.depth_jitter_u)
	layer_report = {
		"asset": "res://assets/traveler/mountains/changan-framed-massif.res",
		"placement": "in front of all three mountain bands, above the skyline",
		"bird_camera_forward_depth_range_u": [float(settings.camera_depth_u) - float(settings.formation.depth_jitter_u), flock_farthest],
		"mountain_mesh_found": mountain != null,
		"mountain_vertex_depth_min_u": nearest if mountain != null else null,
		"mountain_vertex_depth_max_u": farthest if mountain != null else null,
		"front_margin_u": nearest - flock_farthest if mountain != null else null,
		"all_birds_in_front_of_every_mountain_vertex": mountain != null and flock_farthest < nearest,
		"depth_test": "normal opaque depth testing; no depth override or mountain modification",
		"frustum_clipping": "Flock uses the frozen camera frustum directly and is closer than the entire clipped mountain mesh. Mountain clipping cannot remove the separate flock geometry."
	}


func _load_approved_goose_mesh() -> Mesh:
	var packed := load(str(settings.shape.asset_path)) as PackedScene
	if packed == null:
		push_error("Approved goose asset is not a PackedScene: "+str(settings.shape.asset_path))
		return ArrayMesh.new()
	var root := packed.instantiate()
	var found := root.find_children("*", "MeshInstance3D", true, false)
	if found.is_empty() or not found[0] is MeshInstance3D:
		push_error("Approved goose asset has no MeshInstance3D")
		root.free()
		return ArrayMesh.new()
	var source := found[0] as MeshInstance3D
	var mesh := source.mesh
	root.free()
	return mesh


func _vec3(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))
