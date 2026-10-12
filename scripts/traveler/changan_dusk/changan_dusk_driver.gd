extends Node
## 长安旅人 · 日暮图层的每帧伴随节点（changan_dusk_layers.gd 建，挂在 atlas_viewer 下，process_priority = 1000）。
##   1. 首次生效：start() 由 install 推迟调用（等 MotionDirector 收完风动材质再换日暮着色器）；
##   2. 日暮生效时，每帧把主材质的风动参数（anim_t / wind_gust / wind_amp）同步到金边 pass（排在 MotionDirector 之后）；
##   3. 金边代理跟随原几何的可见性（植被开关）；
##   4. 人物异步生成、character_style 材质就位后挂人物金边和腿脚暖反光小灯，小灯每帧跟随人物。
## 白天（layers.active = false）什么都不做。
var layers: RefCounted
var frames := 0
var waited := 0.0
var char_state := "waiting"

func start() -> void:
	layers.call("start")

## 世界节点要被释放（截图结束 / 换场景）：停下，不再碰已释放的代理和材质。
func stop() -> void:
	layers.call("stop")
	set_process(false)

func _process(delta: float) -> void:
	frames += 1
	waited += delta
	_hook_character()
	if not bool(layers.get("active")):
		return
	for p in layers.get("rim_pairs"):
		var base: ShaderMaterial = p[0]
		var pm: ShaderMaterial = p[1]
		pm.set_shader_parameter("anim_t", base.get_shader_parameter("anim_t"))
		pm.set_shader_parameter("wind_gust", base.get_shader_parameter("wind_gust"))
		pm.set_shader_parameter("wind_amp", base.get_shader_parameter("wind_amp"))
	for p in layers.get("rim_proxies"):
		if not is_instance_valid(p[0]) or not is_instance_valid(p[1]):
			continue
		var proxy := p[0] as GeometryInstance3D
		var v := (p[1] as GeometryInstance3D).is_visible_in_tree()
		if proxy.visible != v:
			proxy.visible = v
	var host: Node3D = layers.get("host")
	var cc: Variant = host.get("character_controller")
	if layers.get("char_light") != null and is_instance_valid(cc):
		layers.call("follow_character_light", cc)

func _hook_character() -> void:
	if char_state != "waiting":
		return
	var host: Node3D = layers.get("host")
	var cc: Variant = host.get("character_controller")
	if host.get("character_controller") == null and waited > 5.0:
		char_state = "none"   # 这次运行没有人物（--no-character 或非旅人视图）
		return
	# 等人物风格材质就位（appearance）后再挂：开场几帧的临时 actor 会被释放重建
	if is_instance_valid(cc) and cc.get("appearance") != null and is_instance_valid(cc.get("actor")) and cc.get("dusk_fill") != null:
		var counts: Array = layers.call("attach_character")
		layers.call("attach_character_light", cc)
		char_state = "attached"
		print("CHANGAN_DUSK_CHARACTER ", JSON.stringify({"frames": frames, "seconds": waited, "rim_surfaces": counts, "bounce_light": layers.get("char_light") != null}))
	elif waited > 120.0:
		char_state = "timeout"
		print("CHANGAN_DUSK_CHARACTER ", JSON.stringify({"frames": frames, "seconds": waited, "timeout": true}))
