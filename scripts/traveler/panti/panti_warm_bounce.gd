extends RefCounted
## Panti light polish · warm light and bounce (ported 1:1 from the approved probe, variant m4_final).
## Adds lights only; existing geometry just gains extra render-layer bits (never loses one), so each
## light can reach one class of surface through its cull mask:
##   ground = SnowGround, camp = camp props, castle = PantiFortress, rocks = SnowRocks_*, character = seated traveller.
## Anchors come from data: the fire light, a castle spill light, or a castle-local point (the probe's
## screen-ray anchors, converted once; no runtime ray casts). Offsets use the frozen camera's
## horizontal frame. follow() runs on the shared weather clock:
##   fire               energy x CampFireWarmLight flicker ratio (never writes CampFireWarmLight itself)
##   breath:<spill id>  fades with the castle lamps' own curve and breathes with that spill light
const CURVE_FIRE := "fire"
const BREATH_PREFIX := "breath:"

var viewer: Node3D
var cfg: Dictionary = {}
var layer_bits: Dictionary = {}
var records: Array[Dictionary] = []
var enabled: bool = true
var right_h: Vector3 = Vector3.RIGHT
var toward_camera_h: Vector3 = Vector3.BACK
var tagged: Array[String] = []

func build(stage: Node3D, parent: Node3D, config: Dictionary, bits: Dictionary) -> Dictionary:
	viewer = stage
	cfg = config
	layer_bits = bits
	var camera: Camera3D = viewer.camera
	var forward: Vector3 = -camera.global_basis.z
	forward.y = 0.0
	toward_camera_h = -forward.normalized()
	right_h = camera.global_basis.x
	right_h.y = 0.0
	right_h = right_h.normalized()
	_tag_layers()
	var made: Array[Dictionary] = []
	for spec_value: Variant in cfg.lights:
		var spec: Dictionary = spec_value
		var light: Light3D = _make_light(spec, parent)
		var record: Dictionary = {"light": light, "name": str(spec.name), "follow": str(spec.get("follow", "")),
			"base_energy": 0.0, "morning_energy": 0.0, "midnight_energy": 0.0}
		records.append(record)
		var report: Dictionary = {"name": str(spec.name), "mask": light.light_cull_mask}
		if light is OmniLight3D:
			var screen: Vector2 = camera.unproject_position(light.global_position)
			report["position"] = [light.global_position.x, light.global_position.y, light.global_position.z]
			report["screen_px"] = [screen.x, screen.y]
		else:
			report["direction"] = str(-light.global_basis.z)
		made.append(report)
	return {"layer_bits": layer_bits.duplicate(), "tagged": tagged.duplicate(), "lights": made}

func _tag_layers() -> void:
	var ground: GeometryInstance3D = viewer.snow_ground
	ground.layers |= int(layer_bits.ground)
	tagged.append(str(ground.name))
	if viewer.camp != null:
		for key: String in viewer.camp.props:
			var prop: GeometryInstance3D = viewer.camp.props[key].node
			prop.layers |= int(layer_bits.camp)
			tagged.append(str(prop.name))
	for node: MultiMeshInstance3D in viewer.rock_nodes:
		node.layers |= int(layer_bits.rocks)
		tagged.append(str(node.name))
	var castle: GeometryInstance3D = viewer.castle
	castle.layers |= int(layer_bits.castle)
	tagged.append(str(castle.name))

func _mask(names: Array) -> int:
	var mask: int = 0
	for mask_name: Variant in names:
		assert(layer_bits.has(str(mask_name)), "Unknown Panti light mask: " + str(mask_name))
		mask |= int(layer_bits[str(mask_name)])
	return mask

func _offset(offset: Dictionary) -> Vector3:
	return right_h * float(offset.get("right", 0.0)) + Vector3.UP * float(offset.get("up", 0.0)) + toward_camera_h * float(offset.get("toward_cam", 0.0))

func _color(values: Array) -> Color:
	return Color(float(values[0]), float(values[1]), float(values[2]))

func _make_light(spec: Dictionary, parent: Node3D) -> Light3D:
	var light: Light3D
	if str(spec.get("type", "omni")) == "dir":
		var directional: DirectionalLight3D = DirectionalLight3D.new()
		directional.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
		directional.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		light = directional
	else:
		var omni: OmniLight3D = OmniLight3D.new()
		omni.omni_range = float(spec.range)
		omni.omni_attenuation = float(spec.attenuation)
		light = omni
	light.name = str(spec.name)
	light.light_color = _color(spec.color)
	light.light_energy = 0.0
	light.light_specular = float(spec.get("specular", 0.0))
	light.shadow_enabled = false
	light.light_cull_mask = _mask(spec.mask)
	light.visible = false
	parent.add_child(light)
	if light is DirectionalLight3D:
		var to_light: Vector3 = _offset(spec.dir).normalized()
		light.look_at(light.global_position - to_light, Vector3.UP if absf(to_light.y) < 0.95 else Vector3.RIGHT)
		return light
	light.global_position = _anchor(spec.anchor) + _offset(spec.get("offset", {}))
	return light

func _anchor(anchor: Dictionary) -> Vector3:
	if anchor.has("node"):
		assert(str(anchor.node) == "fire" and viewer.camp != null, "Panti warm light anchor needs the camp fire")
		return viewer.camp.fire.fire_light.global_position
	if anchor.has("spill"):
		return _spill(str(anchor.spill)).global_position
	var local: Array = anchor.castle_local
	return viewer.castle.to_global(Vector3(float(local[0]), float(local[1]), float(local[2])))

func _spill(spill_id: String) -> OmniLight3D:
	for lamp: OmniLight3D in viewer.castle_lighting.spills:
		if str(lamp.name) == spill_id:
			return lamp
	assert(false, "Missing Panti castle spill light: " + spill_id)
	return null

## Period values by transition weight; follow() then applies flicker / breathing.
func apply_blend(weight: float) -> void:
	var morning: Dictionary = cfg.morning
	var midnight: Dictionary = cfg.midnight
	for record: Dictionary in records:
		var light: Light3D = record.light
		var a: Dictionary = morning.get(record.name, {})
		var b: Dictionary = midnight.get(record.name, {})
		record.base_energy = lerpf(float(a.get("light_energy", 0.0)), float(b.get("light_energy", 0.0)), weight)
		record.morning_energy = float(a.get("light_energy", 0.0))
		record.midnight_energy = float(b.get("light_energy", 0.0))
		if a.has("light_color") and b.has("light_color"):
			light.light_color = _color(a.light_color).lerp(_color(b.light_color), weight)
		if light is OmniLight3D and a.has("omni_range") and b.has("omni_range"):
			(light as OmniLight3D).omni_range = lerpf(float(a.omni_range), float(b.omni_range), weight)
	follow()

func follow() -> void:
	var ratio: float = 1.0
	var fire: Node3D = viewer.camp.fire if viewer.camp != null else null
	if fire != null and fire.fire_light != null:
		var base: float = float(fire.params.get("light_energy", 0.0))
		if base > 0.0001:
			ratio = fire.fire_light.light_energy / base
	var castle_lights: Node3D = viewer.castle_lighting
	for record: Dictionary in records:
		var light: Light3D = record.light
		var follow_mode: String = record.follow
		var energy: float = float(record.base_energy)
		var shown: bool = energy > 0.0001
		if follow_mode == CURVE_FIRE:
			energy *= ratio
		elif follow_mode.begins_with(BREATH_PREFIX):
			# Castle-foot lights fade in on the castle lamps' curve, not the raw transition weight.
			energy = lerpf(float(record.morning_energy), float(record.midnight_energy), float(castle_lights.night_weight))
			energy *= _breath(castle_lights, follow_mode.trim_prefix(BREATH_PREFIX))
			shown = energy > 0.0001
		if not enabled:
			energy = 0.0
			shown = false
		light.light_energy = energy
		light.visible = shown

func _breath(castle_lights: Node3D, spill_id: String) -> float:
	for anchor: Dictionary in castle_lights.settings.spill.anchors:
		if str(anchor.get("id", "")) == spill_id:
			return float(castle_lights.breath_multiplier(anchor.get("breath", {})))
	return 1.0

func evidence() -> Dictionary:
	var lights: Array[Dictionary] = []
	for record: Dictionary in records:
		var light: Light3D = record.light
		lights.append({"name": record.name, "visible": light.visible, "energy": light.light_energy, "base_energy": record.base_energy,
			"follow": record.follow, "cull_mask": light.light_cull_mask})
	return {"enabled": enabled, "layer_bits": layer_bits, "tagged": tagged, "lights": lights}
