extends Node
## A 线（光与轮廓）· a_extra_rim.gd 的伴随节点，每帧：
##   1. 把 Daylight 的朝向（指向主光）写进所有轮廓 pass 的 sun_dir_world —— 点篝火过渡时太阳 / 月亮在转，屏幕上的"朝光方向"跟着转；
##   2. 把雪松主材质的 anim_t / wind_enabled 同步到树的轮廓 pass（风动与主 pass 同步，金边不错位）。
## process_priority = 1001：排在 LookdevPeriodWatcher（1000）和 weather 之后。
var host: Node3D
var tree_pairs: Array = []
var passes: Array = []

func _process(_delta: float) -> void:
	sync_now()

func sync_now() -> void:
	if host == null:
		return
	var sun: DirectionalLight3D = host.get("sun") as DirectionalLight3D
	if sun != null:
		var d: Vector3 = sun.global_basis.z.normalized()
		for p: Variant in passes:
			(p as ShaderMaterial).set_shader_parameter("sun_dir_world", d)
	for pair: Variant in tree_pairs:
		var arr: Array = pair
		var main: ShaderMaterial = arr[0]
		var pm: ShaderMaterial = arr[1]
		pm.set_shader_parameter("anim_t", main.get_shader_parameter("anim_t"))
		pm.set_shader_parameter("wind_enabled", main.get_shader_parameter("wind_enabled"))
