extends Node
## Camera-right cloud motion for the frozen traveler view.
##
## Each bank contains static wispy density cards in world space. Day and dusk banks
## are both present from frame zero; the period controller crossfades them and
## briefly increases their drift speed while the lighting transition is active.

var _settings: Dictionary = {}
var _clouds: Array[Dictionary] = []
var _records: Array[Dictionary] = []
var _camera_right := Vector3.ZERO
var _time := 0.0
var _drift_phase := 0.0
var _errors: Array[String] = []
var _period_blend := 0.0
var _transition_active := false
var _speed_multiplier := 1.0
var _enabled := true

func configure(host: Node3D, settings: Dictionary) -> void:
	_settings = settings.duplicate(true)
	_clouds.clear()
	_records.clear()
	_errors.clear()
	_time = 0.0
	_drift_phase = 0.0
	_period_blend = 0.0
	_transition_active = false
	_speed_multiplier = 1.0
	_enabled = true
	var world := host.get("world") as Node3D
	var camera := host.get("camera") as Camera3D
	if world == null or camera == null:
		_fail("Cloud motion needs the existing traveler world and camera")
		return
	var backdrop := world.get_node_or_null(NodePath(str(settings.backdrop_path))) as Node3D
	if backdrop == null:
		_fail("Cloud motion needs the existing FarBackdrop; use --far")
		return
	var target: Vector3 = host.get("target")
	_camera_right = camera.global_basis.x.normalized()
	var forward := -camera.global_basis.z.normalized()
	var aspect := camera.get_viewport().get_visible_rect().size.aspect()
	var horizontal_slope := tan(deg_to_rad(camera.fov) * 0.5) * aspect
	var motion: Dictionary = settings.motion
	var day_count:=0
	var dusk_count:=0
	for child in backdrop.get_children():
		var cloud := child as Node3D
		if cloud == null or not bool(cloud.get_meta("traveler_cloud_cluster", false)):
			continue
		var meshes: Array[GeometryInstance3D] = []
		_collect_geometry(cloud, meshes)
		if meshes.is_empty():
			_fail("Cloud contains no geometry: " + str(cloud.get_path()))
			continue
		var min_x := INF
		var max_x := -INF
		var min_depth := INF
		var max_depth := -INF
		var mesh_records: Array = []
		for geometry in meshes:
			var bounds := geometry.get_aabb()
			for corner_index in 8:
				var relative := geometry.global_transform * bounds.get_endpoint(corner_index) - camera.global_position
				var x := relative.dot(_camera_right)
				var depth := relative.dot(forward)
				min_x = minf(min_x, x)
				max_x = maxf(max_x, x)
				min_depth = minf(min_depth, depth)
				max_depth = maxf(max_depth, depth)
			var mesh_path := ""
			if geometry is MeshInstance3D and geometry.mesh != null:
				mesh_path = geometry.mesh.resource_path
			elif geometry is MultiMeshInstance3D and geometry.multimesh != null and geometry.multimesh.mesh != null:
				mesh_path = geometry.multimesh.mesh.resource_path
			mesh_records.append({
				"path": str(geometry.get_path()),
				"mesh_resource": mesh_path,
				"material_id": geometry.material_override.get_instance_id() if geometry.material_override != null else 0,
				"cast_shadow": geometry.cast_shadow
			})
		var set_name:=str(cloud.get_meta("cloud_set", "day"))
		if set_name=="day":day_count+=1
		else:dusk_count+=1
		var band := "far" if target.z - cloud.global_position.z > float(motion.band_split_target_back_u) else "near"
		var band_settings: Dictionary = motion[band]
		var speed := float(band_settings.speed_u_per_s) * float(motion.direction)
		var initial_center := (min_x + max_x) * 0.5
		var half_extent := (max_x - min_x) * 0.5
		var frustum_half_width := max_depth * horizontal_slope
		var margin := float(motion.wrap_margin_u)
		var half_span := maxf(float(band_settings.minimum_wrap_half_span_u), frustum_half_width + half_extent + margin)
		half_span = maxf(half_span, absf(initial_center) + margin)
		var original := cloud.transform
		var local_axis := backdrop.global_basis.inverse() * _camera_right
		_clouds.append({
			"node": cloud, "set": set_name, "original_transform": original, "local_axis": local_axis,
			"initial_center": initial_center, "half_span": half_span, "speed": speed,
			"material": cloud.get_node("Lobes").material_override if cloud.has_node("Lobes") else null
		})
		_records.append({
			"path": str(cloud.get_path()), "set": set_name, "scene": "procedural_wispy_density", "band": band,
			"original_local_position": _vector(original.origin), "original_world_position": _vector(cloud.global_position),
			"original_basis": [_vector(original.basis.x), _vector(original.basis.y), _vector(original.basis.z)],
			"target_back_u": target.z - cloud.global_position.z, "camera_depth_range_u": [min_depth, max_depth],
			"camera_horizontal_center_u": initial_center, "mesh_half_extent_camera_x_u": half_extent,
			"frustum_half_width_at_farthest_corner_u": frustum_half_width,
			"speed_u_per_s": speed, "wrap_center_range_camera_x_u": [-half_span, half_span],
			"wrap_margin_u": margin, "wrap_period_s": half_span * 2.0 / absf(speed) if speed != 0.0 else 0.0,
			"meshes": mesh_records
		})
	if day_count != int(settings.expected_cloud_count):
		_fail("Expected %d day cloud clusters, found %d" % [int(settings.expected_cloud_count), day_count])
	if dusk_count != int(settings.expected_cloud_count):
		_fail("Expected %d dusk cloud clusters, found %d" % [int(settings.expected_cloud_count), dusk_count])
	apply_time(0.0)
	set_period_blend(0.0, false)

func _collect_geometry(node: Node, result: Array[GeometryInstance3D]) -> void:
	if node is GeometryInstance3D:
		result.append(node as GeometryInstance3D)
	for child in node.get_children():
		_collect_geometry(child, result)

func set_enabled(enabled: bool) -> void:
	_enabled=enabled
	_update_bank_visibility()

func set_period_blend(blend: float, transition_active: bool = false) -> void:
	_period_blend=clampf(blend,0.0,1.0)
	_transition_active=transition_active
	var dusk_speed:=float(_settings.motion.get("dusk_speed_multiplier",1.12))
	var transition_peak:=float(_settings.motion.get("transition_speed_multiplier",4.2))
	var transition_envelope:=sin(PI*_period_blend) if _transition_active else 0.0
	_speed_multiplier=lerpf(1.0,dusk_speed,_period_blend)*(1.0+(transition_peak-1.0)*transition_envelope)
	_update_bank_visibility()

func _update_bank_visibility() -> void:
	for entry in _clouds:
		var cloud:Node3D=entry["node"]
		var alpha:=1.0-_period_blend if entry["set"]=="day" else _period_blend
		cloud.visible=alpha>0.003
		var material:=entry["material"] as ShaderMaterial
		if material!=null:material.set_shader_parameter("bank_alpha",alpha)

func apply_time(t: float) -> void:
	if t<=0.0 or t<_time:
		_drift_phase=maxf(t,0.0)*_speed_multiplier
	elif _enabled:
		_drift_phase+=(t-_time)*_speed_multiplier
	_time=t
	for entry in _clouds:
		var cloud: Node3D = entry["node"]
		var original: Transform3D = entry["original_transform"]
		if t == 0.0:
			cloud.transform = original
			continue
		var half_span: float = entry["half_span"]
		var start: float = entry["initial_center"]
		var center := fposmod(start + float(entry["speed"]) * _drift_phase + half_span, half_span * 2.0) - half_span
		original.origin += Vector3(entry["local_axis"]) * (center - start)
		cloud.transform = original

func evidence() -> Dictionary:
	var sets={"day":0,"dusk":0}
	for entry in _clouds:sets[entry["set"]]=int(sets.get(entry["set"],0))+1
	return {
		"schema": "silkroad.day-clouds-evidence.v2", "cloud_count": sets["day"],
		"total_cluster_count": _clouds.size(), "expected_cloud_count": _settings.get("expected_cloud_count", 0),
		"cloud_sets": sets, "style": "wispy_static_density", "period_blend": _period_blend,
		"transition_active": _transition_active, "speed_multiplier": _speed_multiplier, "anim_t": _time, "integrated_drift_phase": _drift_phase,
		"axis_world": _vector(_camera_right), "settings": _settings.duplicate(true),
		"clouds": _records.duplicate(true), "errors": _errors.duplicate(),
		"wrap_proof": "Each transformed cloud-card AABB is used for camera-right wrapping; no cluster is reset until its full silhouette clears the frustum plus margin.",
		"clock": "MotionDirector apply_time only; this node has no independent process clock"
	}

func _vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _fail(message: String) -> void:
	_errors.append(message)
	push_error(message)
