extends Node3D
class_name LowpolyMapPieceActor

## A visual actor only. Paths and transports have already been committed by TurnSystem.
signal move_finished(player_id: String)
signal mid_node_reached(player_id: String, node_id: String)

const PlanetGeometry := preload("res://scripts/ui/planet_geometry.gd")
const GROUND_Y := 0.08
const SHIP_Y := 0.035
const WAKE_RADIUS := PlanetGeometry.RADIUS + 0.043
const MODEL_PATHS := {
	GameData.Transport.CAMEL: "res://assets/game/lowpoly/vehicles/camel.glb",
	GameData.Transport.SHIP: "res://assets/game/lowpoly/vehicles/ship.glb",
}

var player_id := ""
var is_human := false
var transport := GameData.Transport.CAMEL
var logical_pos := Vector2.ZERO
var test_duration_override := -1.0
var missing_models: Array[String] = []
var _models: Dictionary = {}
var _body: Node3D
var _ring: MeshInstance3D
var _samples := PackedVector2Array()
var _cumulative := PackedFloat32Array()
var _breaks := PackedFloat32Array()
var _node_ids: Array = []
var _total := 0.0
var _duration := 0.0
var _elapsed := 0.0
var _moving := false
var _switching := false
var _next_break := 0
var _segment := 1
var _phase := 0.0
var _switch_tween: Tween
var _generation := 0
var _legs: Array[Dictionary] = []
var _sail: Node3D
var _sail_rest_rotation := Vector3.ZERO
var _player_color := Color("b54d36")
var _trail_fx: Dictionary = {}
var _ship_bounds := AABB()
var _ship_stern_z := 0.0
var _camel_bounds := AABB()
var _camel_tail_z := 0.0
var _trail_drain_left := 0.0
var _visual_motion: IdleVisualMotion


## This clock belongs to the visual child, so the actor stays idle between moves.
## Inherited process mode also freezes it with the board's isolated 3D world.
class IdleVisualMotion extends Node:

	var clock := 0.0


	func _process(delta: float) -> void:
		var step := minf(delta, 0.05)
		clock += step
		get_parent().call("_tick_motion_visuals", clock, step)


static func to_world(point: Vector2, height: float = GROUND_Y) -> Vector3:
	return PlanetGeometry.to_world(point, height)


func setup(p_id: String, human: bool, initial_transport: int, player_color: Color = Color("b54d36")) -> void:
	player_id = p_id
	is_human = human
	_player_color = player_color
	name = "Piece_%s" % p_id
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	for key in MODEL_PATHS:
		var path: String = MODEL_PATHS[key]
		var model: Node3D
		if ResourceLoader.exists(path):
			var packed := load(path) as PackedScene
			if packed != null:
				model = packed.instantiate() as Node3D
		if model == null:
			missing_models.append(path)
			model = _diagnostic_model(int(key))
		_body.add_child(model)
		_models[int(key)] = model
		_apply_player_accent(model)
		for part in model.find_children("*", "Node3D", true, false):
			if int(key) == GameData.Transport.CAMEL and String(part.name).begins_with("leg_"):
				_legs.append({"node": part, "rest": part.rotation,
					"phase": 0.0 if String(part.name).ends_with("left") else PI})
			elif int(key) == GameData.Transport.SHIP and String(part.name) == "sail":
				_sail = part
				_sail_rest_rotation = part.rotation
	_ring = MeshInstance3D.new()
	_ring.name = "PlayerMarker"
	var ring := CylinderMesh.new()
	ring.top_radius = 0.26
	ring.bottom_radius = 0.26
	ring.height = 0.012
	ring.radial_segments = 24
	_ring.mesh = ring
	var material := StandardMaterial3D.new()
	material.albedo_color = _player_color.lightened(0.25)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring.material_override = material
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.position.y = 0.012
	add_child(_ring)
	_ship_bounds = _read_model_bounds(_models[GameData.Transport.SHIP])
	_ship_stern_z = _ship_bounds.end.z
	_camel_bounds = _read_model_bounds(_models[GameData.Transport.CAMEL])
	_camel_tail_z = _camel_bounds.end.z
	_visual_motion = IdleVisualMotion.new()
	_visual_motion.name = "IdleShipMotion"
	add_child(_visual_motion)
	_build_motion_effects()
	set_transport(initial_transport)
	set_process(false)


func _apply_player_accent(model: Node3D) -> void:
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.mesh == null:
			continue
		for index in range(mesh.mesh.get_surface_count()):
			var source := mesh.get_active_material(index) as StandardMaterial3D
			if source != null and source.resource_name.begins_with("player_accent"):
				var material := source.duplicate() as StandardMaterial3D
				material.albedo_color = _player_color
				mesh.set_surface_override_material(index, material)


func _diagnostic_model(kind: int) -> Node3D:
	var root := Node3D.new()
	root.name = "MissingModelDiagnostic"
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.3, 0.4 if kind == GameData.Transport.CAMEL else 0.2, 0.7)
	mesh.mesh = box
	mesh.position.y = box.size.y * 0.5
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("d58542")
	mesh.material_override = material
	root.add_child(mesh)
	return root


func set_logical_position(point: Vector2) -> void:
	logical_pos = point
	position = to_world(point, SHIP_Y if transport == GameData.Transport.SHIP else GROUND_Y)
	# Models keep local +Y outwards and local -Z forward. Moving their root
	# through geographic coordinates keeps every intermediate frame on the sphere.
	basis = PlanetGeometry.surface_basis(point)
	_sync_trail_transforms()


func set_transport(new_transport: int) -> void:
	if transport != new_transport and _body != null:
		_stop_motion_effects(true)
		_body.position.y = 0.0
		_body.rotation.x = 0.0
		_body.rotation.z = 0.0
	transport = new_transport
	for key in _models:
		(_models[key] as Node3D).visible = int(key) == transport
	_sync_visual_processing()


func play_path(samples: PackedVector2Array, cumulative: PackedFloat32Array,
		total: float, duration: float, node_breaks := PackedFloat32Array(),
		node_ids: Array = [], _reference_speed: float = 100.0) -> void:
	cancel_motion()
	if samples.size() < 2 or total <= 0.001:
		move_finished.emit(player_id)
		return
	_samples = samples
	_cumulative = cumulative
	_total = total
	_duration = maxf(test_duration_override if test_duration_override > 0.0 else duration, 0.001)
	_breaks = node_breaks
	_node_ids = node_ids
	_elapsed = 0.0
	_next_break = 0
	_segment = 1
	_moving = true
	set_logical_position(samples[0])
	# Face the initial segment before emitting; otherwise the first wake can appear
	# at the bow when the preceding move ended with the opposite heading.
	_face_path_tangent(samples[1] - samples[0], 1.0)
	_sync_trail_transforms()
	var effect := _trail_fx.get(transport) as CPUParticles3D
	if effect != null:
		effect.visible = true
		effect.restart(true)
		effect.emitting = true
	_sync_visual_processing()
	AudioManager.start_piece_loop(transport)
	set_process(true)


func _process(delta: float) -> void:
	if not _moving or _switching:
		return
	_elapsed += delta
	var progress := clampf(_elapsed / _duration, 0.0, 1.0)
	var distance := progress * _total
	while _segment < _cumulative.size() - 1 and _cumulative[_segment] < distance:
		_segment += 1
	var previous := maxi(_segment - 1, 0)
	var span := maxf(_cumulative[_segment] - _cumulative[previous], 0.0001)
	var amount := clampf((distance - _cumulative[previous]) / span, 0.0, 1.0)
	set_logical_position(_samples[previous].lerp(_samples[_segment], amount))
	var tangent := _samples[_segment] - _samples[previous]
	_face_path_tangent(tangent, minf(delta * 14.0, 1.0))
	_sync_trail_transforms()
	_phase += delta * (10.0 if transport == GameData.Transport.CAMEL else 2.4)
	_body.position.y = absf(sin(_phase)) * 0.018
	_body.rotation.z = sin(_phase) * (0.015 if transport == GameData.Transport.CAMEL else 0.045)
	if transport == GameData.Transport.CAMEL:
		for leg in _legs:
			var part: Node3D = leg["node"]
			var rest: Vector3 = leg["rest"]
			part.rotation = rest + Vector3(sin(_phase + float(leg["phase"])) * 0.3, 0, 0)
	elif _sail != null:
		_sail.rotation = _sail_rest_rotation + Vector3(0, sin(_phase * 0.7) * 0.035, 0)
	while _next_break < _breaks.size() and distance >= _breaks[_next_break]:
		if _next_break < _node_ids.size():
			mid_node_reached.emit(player_id, String(_node_ids[_next_break]))
		_next_break += 1
	if progress >= 1.0:
		set_logical_position(_samples[-1])
		_finish()


func play_transport_switch(from_pos: Vector2, to_pos: Vector2,
		from_transport: int, to_transport: int, duration: float = 0.32) -> void:
	cancel_motion()
	_generation += 1
	var generation := _generation
	set_transport(from_transport)
	set_logical_position(from_pos)
	_moving = true
	_switching = true
	_sync_visual_processing()
	var half := maxf(duration * 0.5, 0.02)
	_switch_tween = create_tween()
	_switch_tween.tween_property(_body, "scale", Vector3.ONE * 0.02, half)
	_switch_tween.tween_callback(func():
		if generation == _generation:
			set_transport(to_transport)
			set_logical_position(to_pos)
	)
	_switch_tween.tween_property(_body, "scale", Vector3.ONE, half)
	_switch_tween.finished.connect(func():
		if generation == _generation:
			_switch_tween = null
			_finish()
	, CONNECT_ONE_SHOT)


func is_animating() -> bool:
	return _moving


func cancel_motion(clear_effects: bool = true) -> void:
	_generation += 1
	if _switch_tween != null and _switch_tween.is_valid():
		_switch_tween.kill()
	_switch_tween = null
	if _moving:
		AudioManager.stop_piece_loop(false)
	_moving = false
	_switching = false
	_stop_motion_effects(clear_effects)
	set_process(false)
	if _body != null:
		_body.scale = Vector3.ONE
		_body.position.y = 0.0
		_body.rotation.x = 0.0
		_body.rotation.z = 0.0
	for leg in _legs:
		(leg["node"] as Node3D).rotation = leg["rest"]
	if _sail != null:
		_sail.rotation = _sail_rest_rotation
	_sync_visual_processing()


func _finish() -> void:
	# Completed moves stop emitting but let existing world-space stamps dissipate.
	# Explicit cancellation, replacement and transport changes clear them at once.
	cancel_motion(false)
	move_finished.emit(player_id)


func _face_path_tangent(tangent: Vector2, weight: float) -> void:
	if tangent.length_squared() <= 0.0001:
		return
	var latitude := PlanetGeometry.latitude_at(logical_pos)
	var east := tangent.x * PlanetGeometry.LONGITUDE_SCALE * cos(latitude)
	var south := tangent.y * PlanetGeometry.LATITUDE_SCALE
	_body.rotation.y = lerp_angle(_body.rotation.y, atan2(-east, -south), weight)


func _read_model_bounds(model: Node3D) -> AABB:
	var minimum := Vector3.INF
	var maximum := -Vector3.INF
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.mesh == null:
			continue
		var relative := Transform3D.IDENTITY
		var cursor: Node3D = mesh
		while cursor != _body:
			relative = cursor.transform * relative
			cursor = cursor.get_parent() as Node3D
		var bounds := mesh.get_aabb()
		for index in range(8):
			var point := relative * bounds.get_endpoint(index)
			minimum = minimum.min(point)
			maximum = maximum.max(point)
	return AABB(minimum, maximum - minimum) if minimum.is_finite() else AABB(Vector3(-0.15, 0, -0.35), Vector3(0.3, 0.2, 0.7))


func _build_motion_effects() -> void:
	for kind in [GameData.Transport.CAMEL, GameData.Transport.SHIP]:
		var ship: bool = kind == GameData.Transport.SHIP
		var effect := CPUParticles3D.new()
		effect.name = "WakeTrail" if ship else "DustTrail"
		effect.emitting = false
		effect.visible = false
		effect.amount = 12
		effect.lifetime = 1.2 if ship else 0.6
		effect.local_coords = false
		effect.gravity = Vector3.ZERO
		effect.use_fixed_seed = true
		effect.seed = 2609087 + kind
		effect.damping_min = 0.4
		effect.damping_max = 0.4
		effect.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.vertex_color_use_as_albedo = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		var color := Color("eef7f4") if ship else Color("cdbfaa")
		var fade := Gradient.new()
		fade.colors = PackedColorArray([Color(color, 0.6 if ship else 0.65), Color(color, 0.0)])
		effect.color_ramp = fade
		var growth := Curve.new()
		growth.max_value = 2.2
		growth.add_point(Vector2(0, 0.5 if ship else 0.6))
		growth.add_point(Vector2(1, 2.2 if ship else 1.6))
		effect.scale_amount_curve = growth
		if ship:
			var foam := PlaneMesh.new()
			foam.orientation = PlaneMesh.FACE_Y
			foam.size = Vector2(0.05, 0.05)
			foam.material = material
			effect.mesh = foam
			# Stationary stamps preserve the sphere normal captured at birth. Any
			# artificial DOWN gravity would pull distant stamps through the water.
			effect.initial_velocity_min = 0.0
			effect.initial_velocity_max = 0.0
			effect.spread = 0.0
		else:
			var dust := SphereMesh.new()
			# At the normal close camera this grows through roughly 2–5 pixels.
			# The old 0.012 radius disappeared against the warm sand after AA.
			dust.radius = 0.035
			dust.height = 0.07
			dust.radial_segments = 5
			dust.rings = 2
			dust.material = material
			effect.mesh = dust
			effect.direction = Vector3(0, 0.85, 1).normalized()
			effect.spread = 20.0
			effect.initial_velocity_min = 0.10
			effect.initial_velocity_max = 0.22
		add_child(effect)
		_trail_fx[kind] = effect


func _sync_trail_transforms() -> void:
	if _body == null or position.length_squared() < 1.0:
		return
	var heading := Basis(Vector3.UP, _body.rotation.y)
	for kind in _trail_fx:
		var ship: bool = int(kind) == GameData.Transport.SHIP
		# Dust starts beyond the actual hindquarters, so the camel cannot hide
		# its own first particles; both models keep their unchanged root anchor.
		var tail := _ship_stern_z + 0.025 if ship else _camel_tail_z + 0.075
		var point := transform * (heading * Vector3(0, 0, tail))
		var normal := point.normalized()
		var backwards := basis * heading.z
		backwards = (backwards - normal * backwards.dot(normal)).normalized()
		var frame := Basis(normal.cross(backwards).normalized(), normal, backwards)
		var radius := WAKE_RADIUS if ship else PlanetGeometry.RADIUS + GROUND_Y + 0.075
		(_trail_fx[kind] as CPUParticles3D).transform = transform.affine_inverse() * Transform3D(frame, normal * radius)


func _stop_motion_effects(clear_live: bool) -> void:
	_trail_drain_left = 0.0
	for effect: CPUParticles3D in _trail_fx.values():
		if clear_live:
			effect.restart(true)
			effect.visible = false
		elif effect.visible:
			_trail_drain_left = maxf(_trail_drain_left, effect.lifetime)
		effect.emitting = false


func _sync_visual_processing() -> void:
	if _visual_motion != null:
		_visual_motion.set_process(_trail_drain_left > 0.0 or
			(transport == GameData.Transport.SHIP and not _moving and not _switching))


func _tick_motion_visuals(clock: float, delta: float) -> void:
	if _trail_drain_left > 0.0:
		_trail_drain_left = maxf(0.0, _trail_drain_left - delta)
		if _trail_drain_left <= 0.0:
			for effect: CPUParticles3D in _trail_fx.values():
				effect.visible = false
			_sync_visual_processing()
	if transport != GameData.Transport.SHIP or _moving or _switching:
		return
	_body.rotation.x = sin(clock * 0.71) * 0.006
	_body.rotation.z = sin(clock * 0.58 + 1.0) * 0.012
	# Preserve at least the imported hull's resting immersion. Compensating the
	# rotated bounds avoids a downward roll forcing the gunwale through the sea.
	var lowest := INF
	for index in range(8):
		lowest = minf(lowest, (_body.basis * _ship_bounds.get_endpoint(index)).y)
	_body.position.y = maxf(0.0, _ship_bounds.position.y - lowest) + 0.007 + sin(clock * 0.76) * 0.003
	if _sail != null:
		_sail.rotation = _sail_rest_rotation + Vector3(0, sin(clock * 1.3) * 0.035, 0)


func get_motion_effects_debug_state() -> Dictionary:
	var effects := {}
	for kind in _trail_fx:
		var effect := _trail_fx[kind] as CPUParticles3D
		effects["ship" if int(kind) == GameData.Transport.SHIP else "camel"] = {
			"emitting": effect.emitting, "visible": effect.visible,
			"can_process": effect.can_process(), "local_coords": effect.local_coords,
			"amount": effect.amount, "lifetime": effect.lifetime,
			"position": effect.global_position, "up": effect.global_basis.y.normalized(),
			"backwards": effect.global_basis.z.normalized(),
			"rendered_particles": _rendered_particle_evidence(effect),
		}
	return {"moving": _moving, "switching": _switching, "trails": effects,
		"drain_seconds": _trail_drain_left, "ship_stern_z": _ship_stern_z,
		"camel_bounds": _camel_bounds, "camel_tail_z": _camel_tail_z,
		"ship_bounds": _ship_bounds, "idle_clock": _visual_motion.clock if _visual_motion != null else 0.0,
		"idle_processing": _visual_motion.is_processing() if _visual_motion != null else false,
		"idle_can_process": _visual_motion.can_process() if _visual_motion != null else false}


func _rendered_particle_evidence(effect: CPUParticles3D) -> Array[Dictionary]:
	# Read the actual submitted CPU-particle transforms only when diagnostics are
	# requested. Emitter flags alone do not prove a particle reaches the image.
	var result: Array[Dictionary] = []
	var buffer := RenderingServer.multimesh_get_buffer(effect.get_base())
	var camera := get_viewport().get_camera_3d()
	for offset in range(0, buffer.size() - 19, 20):
		var axis := Vector3(buffer[offset], buffer[offset + 4], buffer[offset + 8])
		if axis.length_squared() < .00001:
			continue
		var point := effect.global_transform * Vector3(buffer[offset + 3], buffer[offset + 7], buffer[offset + 11])
		result.append({"position": point, "radius": point.length(), "scale": axis.length(),
			"alpha": buffer[offset + 15], "viewport_pixel": camera.unproject_position(point) if camera != null else Vector2.INF})
	return result


func _exit_tree() -> void:
	cancel_motion()
