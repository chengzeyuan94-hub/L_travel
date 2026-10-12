extends Node
## Dusk firelight: one deterministic clock drives the selected city's doorway
## glow and the three existing Buddha cave lights. No autonomous process clock.

var host: Node3D
var doorway: OmniLight3D
var doorway_base := 0.0
var buddha_lights: Array[OmniLight3D] = []
var buddha_base: Array[float] = []
var phase_offsets := [0.0, 1.7, 3.2]
var frozen := false
var last_time := 0.0
var settings: Dictionary = {}
var period_blend := 1.0

func configure(viewer: Node3D, overrides: Dictionary = {}) -> void:
	host = viewer
	name = "DuskFire"
	settings = overrides.duplicate(true)
	set_process(false)
	for i in viewer.cities.size():
		var city: Dictionary = viewer.cities[i]
		if str(city.id) == str(viewer.selected):
			if i < viewer.city_lights.size():
				doorway = viewer.city_lights[i]
				doorway_base = doorway.light_energy
			break
	var light_group := viewer.world.get_node_or_null("CliffBuddhaBacklight") as Node3D
	if light_group != null:
		for child in light_group.get_children():
			if child is OmniLight3D:
				buddha_lights.append(child as OmniLight3D)
				buddha_base.append((child as OmniLight3D).light_energy)
	apply_time(0.0)

func apply_time(at_time: float) -> void:
	if frozen:
		return
	if period_blend<=0.001:
		return
	last_time = maxf(at_time, 0.0)
	# A visible 8.5-second envelope keeps the doorway alive while the fast
	# terms make it read as fire rather than a smooth UI breathing effect.
	var door_cycle := 0.5 + 0.5 * sin(TAU * last_time / 8.5 - 0.55)
	var door_flicker := 1.0 + 0.075 * sin(last_time * 8.9) + 0.045 * sin(last_time * 13.7 + 1.2)
	if doorway != null:
		var door_factor:=clampf(0.70 + 0.62 * door_cycle, 0.52, 1.42) * door_flicker
		doorway.light_energy = doorway_base * lerpf(1.0,door_factor,period_blend)
	for i in buddha_lights.size():
		var pulse := 0.5 + 0.5 * sin(TAU * last_time / 11.7 + float(phase_offsets[i % phase_offsets.size()]))
		var lick := pow(maxf(0.0, sin(last_time * 5.4 + float(i) * 1.9)), 5.0)
		var fast := 1.0 + 0.06 * sin(last_time * 10.7 + float(i))
		var buddha_factor:=clampf(0.72 + 0.42 * pulse + 0.34 * lick, 0.48, 1.55) * fast
		buddha_lights[i].light_energy = buddha_base[i] * lerpf(0.0,buddha_factor,period_blend)

func set_period_blend(value: float, doorway_base_energy: float = -1.0) -> void:
	period_blend=clampf(value,0.0,1.0)
	if doorway_base_energy>=0.0:
		doorway_base=doorway_base_energy
	if period_blend<=0.001:
		return
	apply_time(last_time)

func set_frozen(value: bool) -> void:
	frozen = value
	if not frozen:
		apply_time(last_time)

func evidence() -> Dictionary:
	return {
		"schema": "silkroad.day-fire-evidence.v1",
		"kind": "existing OmniLight3D energy modulation",
		"anim_t": last_time,
		"frozen": frozen,
		"period_blend": period_blend,
		"doorway_light": doorway.get_path() if doorway != null else "",
		"doorway_base_energy": doorway_base,
		"doorway_current_energy": doorway.light_energy if doorway != null else 0.0,
		"doorway_cycle_s": 8.5,
		"doorway_energy_multiplier_clamp": [0.52, 1.42],
		"buddha_light_count": buddha_lights.size(),
		"buddha_light_names": buddha_lights.map(func(light): return str(light.name)),
		"buddha_cycle_s": 11.7,
		"buddha_phase_offsets_s": phase_offsets.duplicate(),
		"buddha_current_energy": buddha_lights.map(func(light): return light.light_energy),
		"clock": "MotionDirector apply_time only; deterministic sin terms, no per-frame random"
	}
