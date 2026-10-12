extends Node
## C 线跟随节点：排在 LookdevPeriodWatcher（1000）之后，把 watcher 刚写好的时段能量再乘上闪烁 / 呼吸系数。
## 只读 CampFireWarmLight、城下暖光和过渡权重，不写它们。
##   fire_lights：乘 CampFireWarmLight 当前能量 / 火焰基准能量（火焰闪烁比例）。
##   breath_lights：乘城下对应暖光的呼吸系数；并把 watcher 的线性权重 w 换成城灯自己的淡入权重
##   （castle_lights_begin..full 的 smoothstep），这样点篝火过渡时城前光池和城窗、城下暖光同步亮起。
##   前提：breath 灯在 variant 的 morning 节能量写 0（watcher 给出的就是 E_midnight × w）。
var host: Node3D
var fire_lights: Array = []
var breath_lights: Array = []

func _init() -> void:
	process_priority = 1001

func _process(_d: float) -> void:
	var ratio: float = 1.0
	var camp: Node3D = host.get("camp")
	if camp != null and camp.fire != null and camp.fire.fire_light != null:
		var base: float = float(camp.fire.params.get("light_energy", 0.0))
		if base > 0.0001:
			ratio = float(camp.fire.fire_light.light_energy) / base
	for l in fire_lights:
		(l as Light3D).light_energy = (l as Light3D).light_energy * ratio
	var cl: Node3D = host.get("castle_lighting")
	if cl == null or breath_lights.is_empty():
		return
	var sync: float = 1.0
	var pt: RefCounted = host.get("period_transition")
	if pt != null:
		var w: float = float(pt.get("weight"))
		sync = float(cl.get("night_weight")) / w if w > 0.0001 else 0.0
	var anchors: Array = cl.settings.spill.anchors
	for item in breath_lights:
		var b: float = 1.0
		for rec in anchors:
			if str(rec.get("id", "")) == str(item["spill"]):
				b = float(cl.call("breath_multiplier", rec.get("breath", {})))
				break
		var l: Light3D = item["light"]
		l.light_energy = l.light_energy * b * sync
		l.visible = l.light_energy > 0.0001
