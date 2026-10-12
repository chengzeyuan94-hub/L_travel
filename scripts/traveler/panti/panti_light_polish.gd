extends Node3D
## Panti light polish (Carlos approved probe variant m4_final, 2026-09-23): main light, rim light,
## snow surface, warm bounce lights and camp / rock material response for the morning and midnight
## periods. Every number lives in data/traveler/panti_light_polish.json.
##
## Built once by panti_viewer.gd after the stage, camp, weather and castle lights exist.
## panti_period_transition.gd owns the weight: it reads main_light(weight) while it blends the sun
## and environment, then calls apply_blend(weight) at the end of every _apply() (snap(), request()
## ticks and hold()). tick(anim_t) follows the shared weather clock for fire flicker, castle-lamp
## breathing, snow glitter and the cedar rim wind, so pause (space) holds all of it.
## Layers ("main", "rim", "snow", "warm") can be switched off one by one for comparisons; with all
## four off the frame is the pre-polish look.
const DATA_PATH := "res://data/traveler/panti_light_polish.json"
const LAYERS: Array[String] = ["main", "rim", "snow", "warm"]
const PERIOD_LIGHTING_SCRIPT := "res://scripts/traveler/panti/panti_period_lighting.gd"

var viewer: Node3D
var data: Dictionary = {}
var rim: RefCounted
var warm: RefCounted
var snow: RefCounted
var layer_enabled: Dictionary = {"main": true, "rim": true, "snow": true, "warm": true}
var active: bool = true
var weight: float = 0.0
var layer_bits: Dictionary = {}
var material_targets: Array[Dictionary] = []
var built: Dictionary = {}

func configure(stage: Node3D) -> void:
	viewer = stage
	name = "PantiLightPolish"
	data = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	assert(data.get("schema", "") == "silkroad.panti-light-polish.v1", "Unexpected Panti light polish data")
	_register_layers()
	# Order matters: rim passes go onto the source materials first, so every material copy made
	# afterwards (rock overrides, camp material response) carries its rim pass.
	rim = load("res://scripts/traveler/panti/panti_rim_light.gd").new()
	built["rim"] = rim.build(viewer, data.rim)
	warm = load("res://scripts/traveler/panti/panti_warm_bounce.gd").new()
	built["warm"] = warm.build(viewer, self, data.warm_lights, layer_bits)
	built["materials"] = _build_materials()
	snow = load("res://scripts/traveler/panti/panti_snow_shading.gd").new()
	built["snow"] = snow.build(viewer, data.snow_surface)

## One registry for Panti render-layer bits; the character bit must stay the one panti_period_lighting uses.
func _register_layers() -> void:
	var layers: Dictionary = data.render_layers
	for key: String in ["ground", "camp", "castle", "rocks", "character"]:
		layer_bits[key] = 1 << int(layers[key])
	var character_bit: int = (load(PERIOD_LIGHTING_SCRIPT) as GDScript).get_script_constant_map().get("CHARACTER_LAYER", 0)
	assert(int(layer_bits.character) == character_bit, "panti_light_polish.json character layer must match panti_period_lighting.gd")

## Camp / rock material response. Each target gets its own material_override copy (single-surface
## nodes only, never alongside a surface override); rim passes already hung on the source survive.
func _build_materials() -> Dictionary:
	var periods: Dictionary = data.materials
	var report: Dictionary = {}
	for pattern: String in periods.morning:
		var count: int = 0
		for item: Node in viewer.world.find_children(pattern, "GeometryInstance3D", true, false):
			var node: GeometryInstance3D = item as GeometryInstance3D
			var material: BaseMaterial3D = _own_override(node)
			if material == null:
				push_error("Panti material response target has no StandardMaterial3D: " + str(node.name))
				continue
			var base: Dictionary = {}
			for property: String in periods.morning[pattern]:
				base[property] = material.get(property)
			material_targets.append({"pattern": pattern, "node": node, "material": material, "base": base})
			count += 1
		report[pattern] = count
	return report

func _own_override(node: GeometryInstance3D) -> BaseMaterial3D:
	if node.material_override is BaseMaterial3D:
		return node.material_override as BaseMaterial3D
	var source: Material = null
	if node is MultiMeshInstance3D:
		var multimesh: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if multimesh != null and multimesh.mesh != null:
			source = multimesh.mesh.surface_get_material(0)
	elif node is MeshInstance3D:
		source = (node as MeshInstance3D).get_active_material(0)
	if not source is BaseMaterial3D:
		return null
	var copy: BaseMaterial3D = (source as BaseMaterial3D).duplicate() as BaseMaterial3D
	node.material_override = copy
	return copy

func set_layer_enabled(layer: String, value: bool) -> void:
	if layer == "all":
		for each: String in LAYERS:
			layer_enabled[each] = value
		return
	assert(layer in LAYERS, "Unknown Panti light polish layer: " + layer)
	layer_enabled[layer] = value

## Morning / midnight only. Day and sunset keep the pre-polish look (all layers neutral).
func set_active(value: bool) -> void:
	active = value
	if not active:
		_apply_layers(weight)

func is_layer_on(layer: String) -> bool:
	return active and bool(layer_enabled[layer])

## Sun / moon energy, colour, shadow blur and ambient energy for this weight, or {} when the main
## layer is off (the transition then keeps look_presets.json values).
func main_light(blend_weight: float) -> Dictionary:
	if not is_layer_on("main"):
		return {}
	var a: Dictionary = data.main_light.morning
	var b: Dictionary = data.main_light.midnight
	return {"energy": lerpf(float(a.sun_energy), float(b.sun_energy), blend_weight),
		"color": _color(a.sun_color).lerp(_color(b.sun_color), blend_weight),
		"shadow_blur": lerpf(float(a.shadow_blur), float(b.shadow_blur), blend_weight),
		"ambient": lerpf(float(a.ambient_energy), float(b.ambient_energy), blend_weight)}

func apply_blend(blend_weight: float) -> void:
	weight = blend_weight
	_apply_layers(weight)

func _apply_layers(blend_weight: float) -> void:
	rim.enabled = is_layer_on("rim")
	warm.enabled = is_layer_on("warm")
	snow.enabled = is_layer_on("snow")
	var endpoints: Array[Color] = _sun_endpoints()
	rim.apply_blend(blend_weight, viewer.sun.light_color, endpoints[0], endpoints[1])
	warm.apply_blend(blend_weight)
	_apply_materials(blend_weight)
	snow.apply_blend(blend_weight)
	refresh()

## The rim brightness line runs between the main-light colours actually used at both ends.
func _sun_endpoints() -> Array[Color]:
	if is_layer_on("main"):
		return [_color(data.main_light.morning.sun_color), _color(data.main_light.midnight.sun_color)]
	var recipes: Dictionary = viewer.period_transition.recipes if viewer.period_transition != null else {}
	if recipes.is_empty():
		return [viewer.sun.light_color, viewer.sun.light_color]
	return [_color(recipes.morning.sky.sun_color), _color(recipes.midnight.sky.sun_color)]

func _apply_materials(blend_weight: float) -> void:
	var morning: Dictionary = data.materials.morning
	var midnight: Dictionary = data.materials.midnight
	var on: bool = is_layer_on("warm")
	for target: Dictionary in material_targets:
		var material: BaseMaterial3D = target.material
		for property: String in target.base:
			var value: float = float(target.base[property])
			if on:
				value = lerpf(float(morning[target.pattern][property]), float(midnight[target.pattern][property]), blend_weight)
			material.set(property, value)

## Shared weather clock (and every apply_blend): flicker / breathing, snow feed, rim sync.
func tick(anim_t: float) -> void:
	if not active:
		return
	refresh(anim_t)

func refresh(anim_t: float = -1.0) -> void:
	var clock: float = anim_t
	if clock < 0.0:
		clock = float(viewer.weather.anim_t) if viewer.weather != null else 0.0
	rim.sync()
	warm.follow()
	snow.feed(clock)

func _color(values: Array) -> Color:
	return Color(float(values[0]), float(values[1]), float(values[2]))

func evidence() -> Dictionary:
	var materials: Array[Dictionary] = []
	for target: Dictionary in material_targets:
		var values: Dictionary = {}
		for property: String in target.base:
			values[property] = target.material.get(property)
		materials.append({"node": str(target.node.name), "values": values})
	return {"data": DATA_PATH, "source": data.get("source", {}), "active": active, "weight": weight, "layers": layer_enabled.duplicate(),
		"layer_bits": layer_bits, "main_light": main_light(weight), "built": built, "rim": rim.evidence(),
		"warm": warm.evidence(), "snow": snow.evidence(), "materials": materials,
		"clock": "weather.anim_t (tick) + transition weight (apply_blend); no own process"}
