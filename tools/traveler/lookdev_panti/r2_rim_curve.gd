extends RefCounted
## r2（过渡连续性）· 轮廓光过渡亮度校正 extra script（探针，不是交付代码）。
##
## 问题（实测）：a_rim_edge(_tree).gdshader 的边光颜色 = 主光色相（LIGHT_COLOR 按最大通道归一）× rim_tint。
## watcher 把太阳色和 rim_tint 都按 w 线性插值；太阳色从暖 (1,0.85,0.67) 走到冷 (0.5,0.64,1.0) 的中途 R≈B，
## "按最大通道归一"把接近中性的色相抬到三个通道都≈1 → 边光颜色的亮度在 w≈0.4 比两端线性插值高 ~38%。
## 前景大雪松的实测金边能量在 w=0.40 比清晨高 21%、比线性插值高 36%，中间帧读成一条发白的硬线。
##
## 做法：挂一个 Node（process_priority 1002，排在 watcher 1000 / ARimSync 1001 之后），每帧：
##   c(w)  = 亮度( srgb→linear(当前太阳色) / 最大通道 × srgb→linear(当前 rim_tint) )   —— 与 shader 里算的完全一致
##   c0/c1 = 同一公式在清晨 / 深夜两端（端点值从 watcher 的 morning / midnight 两节读，缺省取场景原值）
##   rim_strength ← watcher 刚写的值 × lerp(c0, c1, w) / c(w)
## 于是边光的颜色路径不变（暖金 → 中性 → 月光蓝），亮度沿两端之间的直线走；w = 0 / 1 时系数恰为 1，两个已批准时段逐像素不变。
## 可选 "dip"：再乘 1 - dip·4w(1-w)，让中间帧的边光比直线再弱一点（黄昏 → 月夜交接时光线本来就软）。
## cfg: {"targets": ["a_rim_edge_tree.gdshader", "a_rim_edge.gdshader"], "dip": 0.0}

class CurveNode extends Node:
	var host: Node3D
	var files: Array = []
	var mats: Dictionary = {}     # file -> Array[ShaderMaterial]
	var dip: float = 0.0
	var watcher: Node = null
	var last: Dictionary = {}     # material id -> [watcher 值, 我们写的值]
	var evidence: Dictionary = {}

	func weight() -> float:
		var pt: RefCounted = host.get("period_transition")
		if pt != null:
			return float(pt.get("weight"))
		return 1.0 if str(host.get("lighting_period")) == "midnight" else 0.0

	func _col(v: Variant, fallback: Color) -> Color:
		if v is Color:
			return v as Color
		if v is Array:
			var a: Array = v
			if a.size() >= 3:
				return Color(float(a[0]), float(a[1]), float(a[2]))
		if v is Vector3:
			var p: Vector3 = v
			return Color(p.x, p.y, p.z)
		return fallback

	func rim_lum(sun_srgb: Color, tint_srgb: Color) -> float:
		var s: Color = sun_srgb.srgb_to_linear()
		var mx: float = maxf(maxf(s.r, s.g), maxf(s.b, 0.0001))
		var t: Color = tint_srgb.srgb_to_linear()
		return 0.2126 * s.r / mx * t.r + 0.7152 * s.g / mx * t.g + 0.0722 * s.b / mx * t.b

	func endpoint(section: String, key: String, file: String, fallback: Color) -> Color:
		if watcher == null:
			return fallback
		var d: Dictionary = watcher.get(section) as Dictionary
		if file.is_empty():
			var sun: Dictionary = d.get("sun", {})
			if sun.has(key):
				return _col(sun[key], fallback)
			var bs: Dictionary = watcher.get("base_sun") as Dictionary
			return _col(bs.get(key, null), fallback)
		var sh: Dictionary = (d.get("shaders", {}) as Dictionary).get(file, {})
		if sh.has(key):
			return _col(sh[key], fallback)
		var bu: Dictionary = (watcher.get("base_uniforms") as Dictionary).get(file, {})
		return _col(bu.get(key, null), fallback)

	func _process(_d: float) -> void:
		apply_now()

	func apply_now() -> void:
		if watcher == null:
			watcher = host.get_node_or_null("LookdevPeriodWatcher")
			if watcher == null:
				return
		var w: float = weight()
		var sun: DirectionalLight3D = host.get("sun") as DirectionalLight3D
		if sun == null:
			return
		var sun_now: Color = sun.light_color
		var sun_m: Color = endpoint("m", "light_color", "", sun_now)
		var sun_n: Color = endpoint("n", "light_color", "", sun_now)
		for f_v: Variant in files:
			var file: String = str(f_v)
			var list: Array = mats.get(file, [])
			if list.is_empty():
				continue
			var tint_now: Color = _col((list[0] as ShaderMaterial).get_shader_parameter("rim_tint"), Color(1, 1, 1))
			var tint_m: Color = endpoint("m", "rim_tint", file, tint_now)
			var tint_n: Color = endpoint("n", "rim_tint", file, tint_now)
			var c: float = rim_lum(sun_now, tint_now)
			var c0: float = rim_lum(sun_m, tint_m)
			var c1: float = rim_lum(sun_n, tint_n)
			var k: float = 1.0
			if w > 0.0 and w < 1.0 and c > 0.00001:
				k = lerpf(c0, c1, w) / c * (1.0 - dip * 4.0 * w * (1.0 - w))
			evidence[file] = {"w": w, "k": k, "c": c, "c0": c0, "c1": c1}
			for mat_v: Variant in list:
				var mat: ShaderMaterial = mat_v as ShaderMaterial
				var raw: Variant = mat.get_shader_parameter("rim_strength")
				if raw == null:
					continue
				var cur: float = float(raw)
				var id: int = mat.get_instance_id()
				# watcher 每帧都重写 rim_strength；若这一帧没重写（值仍是上帧我们写的），取上帧的原值，避免连乘
				if last.has(id) and is_equal_approx(cur, float((last[id] as Array)[1])):
					cur = float((last[id] as Array)[0])
				var nv: float = cur * k
				mat.set_shader_parameter("rim_strength", nv)
				last[id] = [cur, nv]

func build(host: Node3D, cfg: Dictionary) -> Dictionary:
	var node: CurveNode = CurveNode.new()
	node.name = "R2RimCurve"
	node.host = host
	node.process_priority = 1002
	node.dip = float(cfg.get("dip", 0.0))
	var out: Dictionary = {}
	var sync: Node = host.get_node_or_null("ARimSync")
	var passes: Array = []
	if sync != null:
		passes = sync.get("passes") as Array
	for f_v: Variant in cfg.get("targets", ["a_rim_edge_tree.gdshader"]):
		var file: String = str(f_v)
		var list: Array = []
		for p_v: Variant in passes:
			var p: ShaderMaterial = p_v as ShaderMaterial
			if p != null and p.shader != null and p.shader.resource_path.get_file() == file:
				list.append(p)
		node.files.append(file)
		node.mats[file] = list
		out[file] = list.size()
	host.add_child(node)
	return out
