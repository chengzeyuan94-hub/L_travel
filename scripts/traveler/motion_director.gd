extends Node
## One delta-based wind clock. No frame cap and no shader globals.
var anim_t := 0.0
var wind_enabled := true
var externally_clocked := false
var params: Dictionary
var wind_materials: Array[ShaderMaterial] = []
var original_amplitudes: Array[float] = []
var motion_enabled := true
var active_items: Array[String] = ["wind", "clouds", "leaves"]
var day_components: Dictionary = {}
var period_dusk_blend := 0.0
var period_auto_items := true

func configure(materials: Array[ShaderMaterial], contract: Dictionary) -> void:
	params = contract
	process_mode = Node.PROCESS_MODE_ALWAYS
	for material in materials:
		if material.shader == null or not material.shader.resource_path.ends_with("atlas_surface.gdshader"):
			continue
		wind_materials.append(material)
		var amplitude: Variant = material.get_shader_parameter("wind_amp")
		original_amplitudes.append(float(amplitude) if amplitude != null else 0.0)
	apply_time(0.0)

func configure_day(host: Node3D) -> void:
	if not host.look_on or host.selected != "changan" or not host.look_far:
		return
	host.world.tree_exiting.connect(_world_exiting)
	for kind in ["clouds", "leaves"]:
		var component: Node = load("res://scripts/traveler/day_%s.gd" % kind).new()
		component.name = "Day" + kind.capitalize()
		host.world.add_child(component)
		var settings: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/day_%s_params.json" % kind))
		component.configure(host, settings)
		day_components[kind] = component
	# Keep the dusk components installed in daytime too. They start hidden/frozen,
	# then the period transition can bring them in without rebuilding the scene.
	for kind in ["fire", "sparks"]:
		var component: Node = load("res://scripts/traveler/day_%s.gd" % kind).new()
		component.name = "Dusk" + kind.capitalize()
		host.world.add_child(component)
		component.configure(host, {})
		day_components[kind] = component
	period_dusk_blend = 1.0 if host.look_dusk or host.night else 0.0
	if period_dusk_blend>0.0:
		active_items = ["wind", "clouds", "leaves", "fire", "sparks"]
	for arg in preload("res://scripts/traveler/traveler_launch.gd").user_args():
		if arg.begins_with("--motion-only="):
			period_auto_items=false
			var items: Array[String] = []
			for item in arg.trim_prefix("--motion-only=").split(",", false):
				items.append(item)
			set_active_items(items)
	set_period_blend(period_dusk_blend)
	apply_time(0.0)
	if preload("res://scripts/traveler/traveler_launch.gd").user_args().has("--motion-off"):
		set_motion_enabled(false)

func _world_exiting() -> void:
	motion_enabled = false
	set_process(false)
	day_components.clear()

func set_active_items(items: Array[String]) -> void:
	active_items = []
	for item in items:
		if item in ["wind", "clouds", "leaves", "fire", "sparks"] and not active_items.has(item):
			active_items.append(item)
	wind_enabled = active_items.has("wind")
	for kind in day_components:
		var component: Node = day_components[kind]
		var enabled:bool = active_items.has(kind) and (kind not in ["fire","sparks"] or period_dusk_blend>0.001)
		if component is Node3D:
			component.visible = enabled
		if component.has_method("set_enabled"):
			component.set_enabled(enabled)
		if component.has_method("set_frozen"):
			component.set_frozen(not motion_enabled or not enabled)
		if not enabled:
			component.apply_time(0.0)
	_write_wind()

func set_period_blend(blend: float, doorway_base_energy: float = -1.0, transition_active: bool = false) -> void:
	period_dusk_blend=clampf(blend,0.0,1.0)
	if period_auto_items:
		if period_dusk_blend>0.001:
			for kind in ["fire","sparks"]:
				if not active_items.has(kind):active_items.append(kind)
		else:
			active_items.erase("fire")
			active_items.erase("sparks")
	for kind in ["fire","sparks"]:
		if not day_components.has(kind):continue
		var component: Node=day_components[kind]
		var enabled:=active_items.has(kind) and period_dusk_blend>0.001
		if component is Node3D:component.visible=enabled
		if component.has_method("set_period_blend"):
			component.set_period_blend(period_dusk_blend,doorway_base_energy)
		if component.has_method("set_frozen"):
			component.set_frozen(not motion_enabled or not enabled)
		if not enabled:component.apply_time(0.0)
	if day_components.has("clouds"):
		var clouds:Node=day_components["clouds"]
		if clouds.has_method("set_period_blend"):
			clouds.set_period_blend(period_dusk_blend,transition_active)

func set_motion_enabled(enabled: bool) -> void:
	# Freeze the current pose for every layer, including the GPU particle state.
	motion_enabled = enabled
	for kind in day_components:
		var component: Node = day_components[kind]
		if component.has_method("set_frozen"):
			component.set_frozen(not enabled or not active_items.has(kind))
		if component.has_method("set_enabled"):
			component.set_enabled(active_items.has(kind))
		if kind in ["fire","sparks"] and component.has_method("set_period_blend"):
			component.set_period_blend(period_dusk_blend)

func evidence() -> Dictionary:
	var result := {"anim_t": anim_t, "enabled": motion_enabled, "active_items": active_items.duplicate(), "externally_clocked": externally_clocked, "wind_enabled": wind_enabled}
	var wind_values: Array = []
	for index in wind_materials.size():
		if original_amplitudes[index] > 0.0:
			var material := wind_materials[index]
			wind_values.append({"material": material.resource_name, "wind_amp": material.get_shader_parameter("wind_amp"), "wind_stiff": material.get_shader_parameter("wind_stiff"), "wind_gust": material.get_shader_parameter("wind_gust"), "anim_t": material.get_shader_parameter("anim_t")})
	result["wind_materials"] = wind_values
	for kind in day_components:
		result[kind] = day_components[kind].evidence()
	return result

func gust(at_time: float) -> float:
	return 1.05 + 0.50 * sin(at_time / 13.7) * (0.60 + 0.40 * sin(at_time / 4.3))

func _process(delta: float) -> void:
	if not externally_clocked and motion_enabled:
		apply_time(anim_t + delta)

func apply_time(at_time: float) -> void:
	if not motion_enabled:
		return
	anim_t = at_time
	_write_wind()
	for kind in day_components:
		if active_items.has(kind):
			day_components[kind].apply_time(anim_t)

func _write_wind() -> void:
	for index in wind_materials.size():
		var material := wind_materials[index]
		material.set_shader_parameter("anim_t",anim_t)
		material.set_shader_parameter("wind_gust",gust(anim_t))
		material.set_shader_parameter("wind_amp",original_amplitudes[index] if wind_enabled else 0.0)

func set_wind_enabled(enabled: bool) -> void:
	wind_enabled = enabled
	_write_wind()
