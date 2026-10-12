extends Node
## bounce 线 · 等人物异步生成后，挂一盏只照人物层的暖色贴地小灯（院子地面被暖灯照亮后反到腿上的光），每帧跟随人物脚下。
## 灯的 light_cull_mask = character_controller.CHARACTER_LIGHT_LAYER（1<<17），不照场景，也不投影。
var host: Node3D
var spec: Dictionary
var frames := 0
var light: OmniLight3D
var cc: Variant

func _process(_delta: float) -> void:
	frames += 1
	if light != null and not is_instance_valid(light):
		light = null
	if light == null:
		cc = host.get("character_controller")
		# 等人物风格材质就位（appearance）后再挂：开场几帧的临时 actor 会被释放重建
		if is_instance_valid(cc) and cc.get("appearance") != null and is_instance_valid(cc.get("actor")) and cc.get("dusk_fill") != null:
			light = OmniLight3D.new()
			light.name = "CharacterBounceWarm"
			var layer: Variant = cc.get("CHARACTER_LIGHT_LAYER")
			light.light_cull_mask = int(layer) if layer != null else (1 << 17)
			var c: Array = spec.get("color", [1.0, 0.6, 0.32])
			light.light_color = Color(float(c[0]), float(c[1]), float(c[2]))
			light.light_energy = float(spec.get("energy", 0.8))
			light.omni_range = float(spec.get("range", 0.6))
			light.omni_attenuation = float(spec.get("attenuation", 1.2))
			light.light_specular = 0.0
			light.shadow_enabled = false
			cc.add_child(light)
			_follow()
			print("BOUNCE_CHARACTER_LIGHT ", JSON.stringify({"frames": frames, "layer": light.light_cull_mask, "pos": [light.global_position.x, light.global_position.y, light.global_position.z]}))
		elif frames > 20000:
			print("BOUNCE_CHARACTER_LIGHT ", JSON.stringify({"frames": frames, "timeout": true}))
			queue_free()
		return
	_follow()

func _follow() -> void:
	if not is_instance_valid(cc):
		return
	var a: Variant = cc.get("actor")
	if not is_instance_valid(a):
		return
	var p: Vector3 = (a as Node3D).global_position
	var court: Vector3 = p
	var mats: Array = host.material_list
	if not mats.is_empty():
		var v: Variant = (mats[0] as ShaderMaterial).get_shader_parameter("lamp_bounce_pos")
		if v is Vector3:
			court = v
	var d: Vector3 = court - p
	d.y = 0.0
	if d.length() > 0.001:
		d = d.normalized()
	light.global_position = p + d * float(spec.get("toward_court", 0.15)) + Vector3.UP * float(spec.get("lift", -0.05))
