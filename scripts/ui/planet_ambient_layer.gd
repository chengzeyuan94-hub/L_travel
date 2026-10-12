extends Node3D
## Pure presentation: owns its clock and inherits the board world's lifecycle.
## configure() accepts formal content, never a board's private node hierarchy.
## Geometry animation is batched; it does not mutate rules, actors or hit testing.

const PlanetGeometry := preload("res://scripts/ui/planet_geometry.gd")
const Meshes := preload("res://scripts/ui/ambient/ambient_meshes.gd")
const MotionShader := preload("res://scripts/ui/ambient/ambient_motion.gdshader")
const PLACEMENT_PATH := "res://scripts/ui/ambient/placements.json"
# Keep the full cloud bob cycle clear of Simhala's shared port approach.
const RAIN_LOGICAL_POSITION := Vector2(2000.0, 1000.0)
const VOLCANO_SMOKE_HEIGHT := 1.12
const CITY_SMOKE_OFFSETS := {
	# Actual exported roof samples (local Godot xyz), clear of towers/domes.
	# Changan: eastern gatehouse kitchen, Baghdad: western flat-roof house,
	# Quanzhou: southwest residential gable, not either pagoda.
	"changan": Vector3(0.58, 0.925, 0.38),
	"baghdad": Vector3(-0.405, 0.330, -0.135),
	"quanzhou": Vector3(-0.54, 0.369, 0.343),
}

var _clock := 0.0
var _global_built := false
var _global_build_count := 0
var _city_signature := ""
var _city_rebuild_count := 0
var _camera: Camera3D
var _zoom := 1.0
var _cloud_root: Node3D
var _rain_root: Node3D
var _rain_base := Vector3.ZERO
var _rain_basis := Basis.IDENTITY
var _city_group: Node3D
var _cloud_material: StandardMaterial3D
var _motion_materials: Array[ShaderMaterial] = []
var _anchors: Array[Dictionary] = []
var _city_anchors: Array[Dictionary] = []
var _placements: Dictionary = {}
var _configured_cities: Array[String] = []


func _init() -> void:
	name = "AmbientLayer"
	process_mode = Node.PROCESS_MODE_INHERIT


func configure(content: Dictionary, city_visual_offset: Vector2 = Vector2(0, -85)) -> void:
	if not _global_built:
		_placements = JSON.parse_string(FileAccess.get_file_as_string(PLACEMENT_PATH)) as Dictionary
		_build_global()
		_global_built = true
		_global_build_count += 1
	var board_nodes: Dictionary = content.get("board_nodes", {})
	var signature: Array = [city_visual_offset]
	for city_id in CITY_SMOKE_OFFSETS:
		var node: Dictionary = board_nodes.get(city_id, {})
		signature.append([city_id, node.get("map_position", [])])
	var key := str(signature)
	if key == _city_signature:
		return
	_city_signature = key
	_rebuild_city_smoke(board_nodes, city_visual_offset)


func set_view(camera: Camera3D, zoom: float) -> void:
	_camera = camera
	_zoom = zoom
	if _cloud_material != null:
		_cloud_material.albedo_color.a = lerpf(.42, .15, smoothstep(2.0, 2.4, zoom))


func _process(delta: float) -> void:
	if not _global_built:
		return
	_clock += minf(delta, .05)
	_cloud_root.rotation.y = _clock * .006
	_rain_root.position = _rain_base + _rain_basis.x * sin(_clock * .26) * .065 + _rain_basis.y * sin(_clock * .42) * .045
	for material in _motion_materials:
		material.set_shader_parameter("clock", _clock)


func _build_global() -> void:
	_cloud_root = Node3D.new()
	_cloud_root.name = "CloudLayer"
	add_child(_cloud_root)
	var clouds: Array[Transform3D] = []
	var phases: Array[float] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 260909
	for i in 9:
		var lat := clampf(18.0 + sin(i * 1.6) * 35.0, -55, 55)
		var logical := _lon_lat(80.0 + i * 43.0, lat)
		var transform := _at(logical, 1.50 + rng.randf() * .30)
		transform.basis = transform.basis.scaled(Vector3.ONE * rng.randf_range(.85, 1.08))
		clouds.append(transform)
		phases.append(0.0)
		_record("cloud_%d" % i, "cloud", transform, .83, 0.0, "cloud")
	_cloud_material = _standard(true)
	_cloud_material.albedo_color.a = .42
	_batch("Clouds9", Meshes.cloud(), clouds, phases, _cloud_material, _cloud_root)

	var gulls: Array[Transform3D] = []
	var gull_phases: Array[float] = []
	for group in (_placements["gull_groups"] as Array).size():
		var center := _vec2(_placements["gull_groups"][group])
		for i in 3:
			var logical := center + Vector2(i * 32.0 - 32.0, (i % 2) * 25.0)
			var transform := _at(logical, 1.70 + i * .035)
			var phase := group * 2.1 + i * 1.6
			gulls.append(transform)
			gull_phases.append(phase)
			_record("gull_%d_%d" % [group, i], "seagull", transform, .60, phase, "gull")
	_batch("Gulls6", Meshes.gull(), gulls, gull_phases, _motion(1))
	_add_placed_batch("Sheep3", "sheep", Meshes.sheep(), _placements["sheep"], .08, 2, .40, _placements["sheep_ground_heights"], _placements["sheep_yaws"])
	var whale_xy := _vec2(_placements["whale_lon_lat"])
	_add_placed_batch("Whale1", "whale", Meshes.whale(), [_lon_lat(whale_xy.x, whale_xy.y)], .060, 3, 1.12, [], [], 1.15)
	# This small boat's deck is below its mesh origin. Keep the complete deck
	# and gunwale above water through roll/heave while the keel stays submerged.
	_add_placed_batch("MooredBoats3", "moored_boat", Meshes.boat(), _placements["moored_boats"], .091, 4, .62)
	var ice_positions: Array = []
	for point in _placements["ice_lon_lat"]:
		var ll := _vec2(point)
		ice_positions.append(_lon_lat(ll.x, ll.y))
	_add_placed_batch("IceFloes4", "ice_floe", Meshes.ice(), ice_positions, .035, 5, .45)
	_add_placed_batch("WaystationFlags", "flag", Meshes.flag(), _placements["flags"], .08, 6, .80, _placements["flag_ground_heights"])

	var windmill := _at(_vec2(_placements["windmill"]), float(_placements["windmill_ground_height"]))
	_batch("WindmillWindcatcher", Meshes.windmill(false), [windmill], [0.0], _standard())
	var rotor := windmill.translated_local(Vector3(0,.16,0))
	_batch("WindmillVerticalRotor", Meshes.windmill(true), [rotor], [0.0], _motion(7))
	_record("windmill", "windmill", rotor, .78)
	_build_rain()
	var volcano := _at(_lon_lat(155,20), VOLCANO_SMOKE_HEIGHT)
	var smoke := _smoke("VolcanoSmoke", volcano, 10, Color("77767d"), 6.5)
	add_child(smoke)
	_record("volcano_smoke", "volcano_smoke", volcano.translated_local(Vector3(0,.55,0)), .95)


func _build_rain() -> void:
	var base := _at(RAIN_LOGICAL_POSITION, 1.30)
	_rain_root = Node3D.new()
	_rain_root.name = "MonsoonRainCloud"
	_rain_root.transform = base
	add_child(_rain_root)
	_rain_base = base.origin
	_rain_basis = base.basis
	var cloud_material := _standard(true)
	cloud_material.albedo_color.a = .78
	var cloud_shape := Transform3D(Basis.IDENTITY.scaled(Vector3(.85,.90,.78)), Vector3.ZERO)
	_batch("RainCloud", Meshes.cloud(true), [cloud_shape], [0.0], cloud_material, _rain_root)
	var rain := CPUParticles3D.new()
	rain.name = "LocalRain30"
	rain.amount = 30
	rain.lifetime = 1.05
	rain.preprocess = 1.05
	rain.local_coords = true
	# A modest prevailing wind lets the falling column emerge beside the cloud
	# even when a player looks nearly straight down at this part of the globe.
	rain.position.y = -.16
	rain.direction = Vector3(.52,-1,.22).normalized()
	rain.particle_flag_align_y = true
	rain.spread = 1.5
	rain.gravity = Vector3.ZERO
	rain.initial_velocity_min = 1.05
	rain.initial_velocity_max = 1.15
	rain.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	rain.emission_box_extents = Vector3(.34,.015,.20)
	rain.randomness = .25
	var drop := BoxMesh.new()
	drop.size = Vector3(.026,.20,.026)
	rain.mesh = drop
	rain.material_override = _particle_material()
	var rain_gradient := Gradient.new()
	rain_gradient.offsets = PackedFloat32Array([0.0,.08,.78,1.0])
	rain_gradient.colors = PackedColorArray([Color(.35,.65,.75,0),Color(.35,.65,.75,.86),Color(.35,.65,.75,.72),Color(.35,.65,.75,0)])
	rain.color_ramp = rain_gradient
	rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rain_root.add_child(rain)
	_record("monsoon_rain", "rain_cloud", base.translated_local(Vector3(.16,-.38,.06)), 1.12, 0, "rain")


func _rebuild_city_smoke(nodes: Dictionary, visual_offset: Vector2) -> void:
	if is_instance_valid(_city_group):
		_city_group.free()
	_city_anchors.clear()
	_configured_cities.clear()
	_city_group = Node3D.new()
	_city_group.name = "AmbientCity"
	add_child(_city_group)
	var chimney_transforms: Array[Transform3D] = []
	var chimney_phases: Array[float] = []
	for city_id in CITY_SMOKE_OFFSETS:
		var node: Dictionary = nodes.get(city_id, {})
		if not node.has("map_position"):
			continue
		var logical := _vec2(node["map_position"]) + visual_offset
		var roof := _at(logical, .08).translated_local(CITY_SMOKE_OFFSETS[city_id])
		var smoke := _smoke("HouseSmoke_" + city_id, roof.translated_local(Vector3(0,.07,0)), 6, Color("bed2c2"), 6.0)
		_city_group.add_child(smoke)
		chimney_transforms.append(roof)
		chimney_phases.append(0.0)
		_configured_cities.append(city_id)
		_city_anchors.append({"id": "house_smoke_"+city_id, "category": "city_smoke", "transform": roof.translated_local(Vector3(0,.50,0)), "radius_world": .90, "motion": "", "phase": 0.0, "moving": true, "city_id": city_id})
	if not chimney_transforms.is_empty():
		var b := Meshes.Builder.new()
		b.box(Vector3(0,.035,0),Vector3(.052,.09,.05),Color("a99674"))
		b.box(Vector3(0,.08,0),Vector3(.075,.018,.075),Color("c8b48d"))
		b.box(Vector3(0,.090,0),Vector3(.036,.006,.035),Color("574d43"))
		_batch("KitchenChimneys", b.finish(), chimney_transforms, chimney_phases, _standard(), _city_group)
	_city_rebuild_count += 1


func _smoke(label: String, transform: Transform3D, amount: int, tint: Color, lifetime: float) -> CPUParticles3D:
	var smoke := CPUParticles3D.new()
	smoke.name = label
	smoke.transform = transform
	smoke.amount = amount
	smoke.lifetime = lifetime
	smoke.preprocess = lifetime
	smoke.local_coords = true
	smoke.direction = Vector3(.08,1,.02)
	smoke.spread = 9.0
	smoke.gravity = Vector3.ZERO
	smoke.initial_velocity_min = .22
	smoke.initial_velocity_max = .28
	smoke.randomness = .4
	var b := Meshes.Builder.new()
	b.ico(Vector3.ZERO, Vector3.ONE*.14, Color.WHITE)
	smoke.mesh = b.finish()
	smoke.material_override = _particle_material()
	tint.a = .27
	smoke.color_ramp = _gradient(tint)
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0,.35))
	scale_curve.add_point(Vector2(.45,1.25))
	scale_curve.add_point(Vector2(1,2.2))
	smoke.scale_amount_curve = scale_curve
	smoke.scale_amount_min = 1.0
	smoke.scale_amount_max = 1.0
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return smoke


func _add_placed_batch(label: String, category: String, mesh: Mesh, points: Array, height: float, kind: int, radius: float, ground_heights: Array = [], yaws: Array = [], uniform_scale: float = 1.0) -> void:
	var transforms: Array[Transform3D] = []
	var phases: Array[float] = []
	for i in points.size():
		var point := _vec2(points[i])
		# Offline samples are from the exported terrain, including low-poly face
		# sag and city visual offsets. Runtime never edits or queries rule data.
		var transform := _at(point, float(ground_heights[i]) if i < ground_heights.size() else height)
		if i < yaws.size():
			transform = transform.rotated_local(Vector3.UP, float(yaws[i]))
		transform.basis = transform.basis.scaled(Vector3.ONE * uniform_scale)
		var phase := i*1.7
		transforms.append(transform)
		phases.append(phase)
		_record(category+"_%d"%i, category, transform, radius, phase, category)
	_batch(label, mesh, transforms, phases, _motion(kind))


func _batch(label: String, mesh: Mesh, transforms: Array, phases: Array, material: Material, parent: Node3D = null) -> MultiMeshInstance3D:
	var result := MultiMeshInstance3D.new()
	result.name = label
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Explicit white tint is required by Compatibility's instance-color path,
	# including opaque vertex-colour batches and alpha clouds.
	mm.use_colors = true
	mm.use_custom_data = true
	mm.instance_count = transforms.size()
	mm.mesh = mesh
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, Color.WHITE)
		mm.set_instance_custom_data(i, Color(float(phases[i]),0,0,1))
	result.multimesh = mm
	result.material_override = material
	result.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Shader articulation is outside the source mesh's tight AABB. The batches
	# have very few instances; a conservative globe AABB prevents pop-in.
	result.custom_aabb = AABB(Vector3.ONE*-14.5,Vector3.ONE*29.0)
	(parent if parent != null else self).add_child(result)
	return result


func _motion(kind: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = MotionShader
	material.set_shader_parameter("kind", kind)
	material.set_shader_parameter("clock", _clock)
	_motion_materials.append(material)
	return material


func _standard(transparent: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _particle_material() -> StandardMaterial3D:
	var material := _standard(true)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _gradient(tint: Color) -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0,.12,.65,1.0])
	gradient.colors = PackedColorArray([Color(tint,0),tint,Color(tint,tint.a*.38),Color(tint,0)])
	return gradient


func _at(logical: Vector2, height: float) -> Transform3D:
	return Transform3D(PlanetGeometry.surface_basis(logical), PlanetGeometry.to_world(logical,height))


func _lon_lat(lon: float, lat: float) -> Vector2:
	return PlanetGeometry.LOGICAL_CENTER + Vector2(deg_to_rad(lon)/PlanetGeometry.LONGITUDE_SCALE, -deg_to_rad(lat)/PlanetGeometry.LATITUDE_SCALE)


func _vec2(value: Variant) -> Vector2:
	return value if value is Vector2 else Vector2(float(value[0]),float(value[1]))


func _record(id: String, category: String, transform: Transform3D, radius: float, phase: float = 0.0, motion: String = "") -> void:
	_anchors.append({"id": id, "category": category, "transform": transform, "radius_world": radius, "phase": phase, "motion": motion, "moving": true})


func get_motion_anchors() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var records: Array[Dictionary] = []
	records.append_array(_anchors)
	records.append_array(_city_anchors)
	for record in records:
		var transform: Transform3D = record["transform"]
		var phase := float(record["phase"])
		var point := transform.origin
		match String(record["motion"]):
			"cloud": point = Basis(Vector3.UP,_clock*.006)*point
			"gull": point = transform*Vector3(cos(_clock*.33+phase)*.22,sin(_clock*.7+phase)*.04,sin(_clock*.33+phase)*.18)
			"whale": point = transform*Vector3(cos(_clock*.2+phase)*.35,sin(_clock*.6)*.007,sin(_clock*.2+phase)*.25)
			"moored_boat": point = transform*Vector3(0,sin(_clock*.8+phase)*.017,0)
			"ice_floe": point = transform*Vector3(0,sin(_clock*.8+phase)*.012,0)
			"rain": point += _rain_root.position-_rain_base
		var item := record.duplicate()
		item.erase("transform")
		item["world_position"] = to_global(point)
		item["visible"] = _anchor_visible(item["world_position"],float(item["radius_world"]))
		result.append(item)
	return result


func _anchor_visible(point: Vector3, radius: float) -> bool:
	if not is_instance_valid(_camera):
		return false
	if _camera.is_position_behind(point) or not _camera.is_position_in_frustum(point):
		return false
	var hit := PlanetGeometry.ray_intersection(_camera.global_position, point-_camera.global_position, 0.0)
	return not hit.is_finite() or _camera.global_position.distance_to(hit) >= _camera.global_position.distance_to(point)-radius*.65


func get_diagnostics() -> Dictionary:
	var counts := {}
	var visible_counts := {}
	var anchors := get_motion_anchors()
	for anchor in anchors:
		var category: String = anchor["category"]
		counts[category] = int(counts.get(category,0))+1
		if anchor["visible"]:
			visible_counts[category] = int(visible_counts.get(category,0))+1
	var particle_capacity := 0
	var emitting_particles := 0
	var mesh_batches := 0
	var triangles := 0
	var shadows := 0
	for node in find_children("*", "GeometryInstance3D", true, false):
		var geometry := node as GeometryInstance3D
		if geometry.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			shadows += 1
		if node is CPUParticles3D:
			particle_capacity += node.amount
			if node.emitting:
				emitting_particles += node.amount
		elif node is MultiMeshInstance3D:
			mesh_batches += 1
			var mm: MultiMesh = node.multimesh
			for surface in mm.mesh.get_surface_count():
				triangles += mm.mesh.surface_get_array_len(surface)/3*mm.instance_count
	return {"clock":_clock, "counts":counts, "visible_by_category":visible_counts,
		"anchors":anchors, "anchor_count":anchors.size(), "rain_logical_position":RAIN_LOGICAL_POSITION,
		"cloud_count":int(counts.get("cloud",0)), "city_smoke_count":_configured_cities.size(),
		"smoke_emitter_count":_configured_cities.size()+1, "rain_emitter_count":1,
		"particle_capacity":particle_capacity, "emitting_particle_capacity":emitting_particles,
		"mesh_batches":mesh_batches, "mesh_triangles_instanced":triangles,
		"estimated_draw_surfaces":mesh_batches+_configured_cities.size()+2,
		"draw_estimate_note":"One surface per batch/emitter; GPU draw calls and frame time require a real window measurement.",
		"shadow_casting_geometry_count":shadows, "dynamic_transform_updates_per_frame":2,
		"shader_clock_uniforms_per_frame":_motion_materials.size(), "global_build_count":_global_build_count,
		"city_rebuild_count":_city_rebuild_count, "configured_city_ids":_configured_cities.duplicate(),
		"can_process":can_process(), "view_zoom":_zoom,
		"cloud_alpha":_cloud_material.albedo_color.a if _cloud_material != null else 0.0}
