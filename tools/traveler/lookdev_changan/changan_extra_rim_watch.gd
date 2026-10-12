extends Node
## rim 线 · changan_extra_rim.gd 的伴随节点：
##   1. 每帧把主材质的风动参数（anim_t / wind_gust / wind_amp）同步到 edge pass（process_priority=1000，排在 MotionDirector 之后）；
##   2. 人物异步生成、character_style 材质就位后，再给人物挂金边，然后不再检查。
var extra: RefCounted
var host: Node3D
var char_specs: Array = []
var pairs: Array = []
var frames := 0
var waited := 0.0
var char_done := false

func _process(delta: float) -> void:
	frames += 1
	waited += delta
	for p in pairs:
		var base: ShaderMaterial = p[0]
		var pm: ShaderMaterial = p[1]
		pm.set_shader_parameter("anim_t", base.get_shader_parameter("anim_t"))
		pm.set_shader_parameter("wind_gust", base.get_shader_parameter("wind_gust"))
		pm.set_shader_parameter("wind_amp", base.get_shader_parameter("wind_amp"))
	if char_done or char_specs.is_empty():
		return
	var cc: Node = host.character_controller
	if is_instance_valid(cc) and cc.get("appearance") != null:
		var counts: Array = []
		for spec in char_specs:
			counts.append(extra.call("apply_spec", host, spec))
		print("RIM_CHARACTER_APPLIED ", JSON.stringify({"frames": frames, "seconds": waited, "surfaces": counts}))
		char_done = true
	elif waited > 120.0:   # 人物生成要等导航建好，机器忙时可能晚于 2 秒预热；按时间而不是帧数超时
		print("RIM_CHARACTER_APPLIED ", JSON.stringify({"frames": frames, "seconds": waited, "surfaces": [], "timeout": true}))
		char_done = true
