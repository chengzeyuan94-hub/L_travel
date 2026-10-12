extends RefCounted
## 一局 20 分钟里的一天（Carlos 2026-09-26：「20 分钟内，有 4 种不同的光线效果，模仿一天变化」）。
## 清晨 → 正午 → 黄昏 → 暮色，按 GameState.match_elapsed_sec（真实秒数）逐帧渐变：
##   0:00–2:30 清晨 · 2:30–5:00 渐入正午 · 5:00–10:00 正午（已认可的概念图光）· 10:00–13:00 渐入黄昏
##   13:00–16:00 黄昏 · 16:00–18:00 渐入暮色（城灯逐渐亮起）· 18:00 起暮色（超时补齐的最后一轮也保持）
## 正午 / 黄昏 / 暮色沿用 merchant_board_claude_review.gd 的 LIGHTING；清晨是新加的（黄昏的镜像：
## 东北偏东低日，桃粉地平线，冷色补光从西边来，山谷薄雾）。数值是起点，不是定稿。
##
## 只混合每帧改也便宜、连续的量（颜色、能量、方向、shader uniform）。SDFGI 格子/级联、SSAO/SSIL、
## tonemap 模式、树影开关各预设相同，只在建场时由 apply_lighting 设一次——改它们会重建 SDFGI（卡 40+ ms）。
## 城灯不再开关，而是 night 0–1 淡入淡出（emission 常开、能量乘 night），避免首次编译卡顿。
## 太阳方向用 slerp：方位/仰角分开插值会让太阳绕到北侧海面镜面方向，整片海被刷白（原型已否决）。

const DEFAULTS := {
	"sky_energy": 1.0, "sdfgi_energy": 1.0, "shadow_opacity": 0.8, "shadow_blur": 2.0,
	"sun_angular": 3.0, "sun_indirect": 1.0,
	"sea_tint": Color(1, 1, 1), "sea_lines": 0.035,
	"night": 0.0,
	"night_lift": 0.0, "fire": 0.25, "fx_light": 1.0,
	"smoke": Color(0.97, 0.97, 0.95, 0.85), "mist": Color(0.96, 0.97, 1.0), "mist_opacity": 0.38,
	# 以前写死在 build_environment() / board_post2d 里的方向量：清晨时要镜像到另一侧
	"fill_dir": Vector3(-0.72, -0.55, -0.2),     # 补光 + CityShade 的前进方向（从东边来）
	"post_sun_pos": Vector2(-0.08, -0.16),        # 后期暖光的屏幕原点：左上
	"post_sun_gain": Vector3(0.55, 0.3, -0.04),
}

const DAWN := {
	"sky_top": Color(0.42, 0.52, 0.78), "sky_horizon": Color(1.0, 0.78, 0.68),
	"ground_bottom": Color(0.5, 0.5, 0.62), "ground_horizon": Color(0.96, 0.8, 0.74),
	"ambient": 0.4, "exposure": 1.08, "saturation": 1.32, "contrast": 1.04,
	"glow": 0.42, "glow_threshold": 0.95,
	"sun_color": Color(1.0, 0.8, 0.64), "sun_energy": 2.0, "sun_dir": Vector3(-0.84, -0.44, 0.31),
	"fill_color": Color(0.6, 0.66, 0.98), "fill_energy": 0.44,
	"rim_color": Color(1.0, 0.84, 0.78), "rim_energy": 0.14,
	"shadow_opacity": 0.9, "shadow_blur": 1.6, "sun_angular": 2.2, "sdfgi_energy": 1.0, "sun_indirect": 1.15,
	"sea_tint": Color(0.92, 0.88, 0.92), "sea_lines": 0.022,
	"smoke": Color(0.95, 0.9, 0.9, 0.85), "mist": Color(1.0, 0.9, 0.88), "mist_opacity": 0.58,
	"fire": 0.45, "fx_light": 0.9, "night_lift": 0.05, "night": 0.0,
	"cloud_lit": Color(1.0, 0.9, 0.86), "cloud_shade": Color(0.74, 0.74, 0.9),
	"fill_dir": Vector3(0.72, -0.55, -0.2),
	"post_sun_pos": Vector2(1.08, -0.16),
	"post_sun_gain": Vector3(0.5, 0.3, 0.02),
}

const ORDER := ["dawn", "noon", "dusk", "twilight"]
const NAMES := {"dawn": "清晨", "noon": "正午", "dusk": "黄昏", "twilight": "暮色"}

## [对局秒数, 预设]；相邻同名 = 保持，异名 = 渐变（smoothstep 缓入缓出）
const KEYS := [
	[0.0, "dawn"], [150.0, "dawn"],
	[300.0, "noon"], [600.0, "noon"],
	[780.0, "dusk"], [960.0, "dusk"],
	[1080.0, "twilight"], [1200.0, "twilight"],
]

var presets := {}
var _base_energy := {}   # OmniLight3D -> 原始能量
var _city_shade: DirectionalLight3D


func setup(w) -> void:
	for name in ["noon", "dusk", "twilight"]:
		presets[name] = complete(w.LIGHTING[name])
	presets["dawn"] = complete(DAWN)
	for l in w.city_lights:
		_base_energy[l] = l.light_energy
	if w.life:
		for l in w.life.boat_lights:
			_base_energy[l] = l.light_energy
	_city_shade = w.world_root.get_node_or_null("CityShade")


static func complete(p: Dictionary) -> Dictionary:
	var q: Dictionary = DEFAULTS.duplicate()
	for k in p:
		q[k] = p[k]
	if p.has("city_lights"):
		q["night"] = 1.0 if bool(p["city_lights"]) else 0.0
	q.erase("city_lights")
	return q


static func blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for k in a:
		var va = a[k]
		var vb = b.get(k, va)
		match typeof(va):
			TYPE_COLOR:
				out[k] = (va as Color).lerp(vb, t)
			TYPE_FLOAT, TYPE_INT:
				out[k] = lerpf(float(va), float(vb), t)
			TYPE_VECTOR3:
				if String(k).ends_with("_dir"):
					out[k] = (va as Vector3).normalized().slerp((vb as Vector3).normalized(), t)
				else:
					out[k] = (va as Vector3).lerp(vb, t)
			TYPE_VECTOR2:
				out[k] = (va as Vector2).lerp(vb, t)
			_:
				out[k] = va if t < 0.5 else vb
	return out


func sample(sec: float) -> Dictionary:
	sec = clampf(sec, 0.0, float(KEYS[KEYS.size() - 1][0]))
	for i in range(KEYS.size() - 1):
		var k0: Array = KEYS[i]
		var k1: Array = KEYS[i + 1]
		if sec <= float(k1[0]):
			var span := float(k1[0]) - float(k0[0])
			var u := 0.0 if span <= 0.0 else (sec - float(k0[0])) / span
			u = u * u * (3.0 - 2.0 * u)
			return blend(presets[k0[1]], presets[k1[1]], u)
	return presets[KEYS[KEYS.size() - 1][1]]


## 不限时对局（Carlos 2026-09-26 起时长可调到「不限时」）：一天循环往复——20 分钟的一天之后是 4 分钟的夜与日出，
## 再回到清晨。暮色→清晨的太阳方向几乎相反，直接插值会从头顶扫过（像正午光配暮色），所以先把太阳熄到 0，
## 趁黑换到清晨的方向再亮起来。
const DAY_SEC := 1200.0
const LOOP_SEC := 1440.0


func sample_loop(sec: float) -> Dictionary:
	sec = fposmod(sec, LOOP_SEC)
	if sec <= DAY_SEC:
		return sample(sec)
	var tw: Dictionary = presets["twilight"]
	var dn: Dictionary = presets["dawn"]
	var mid := (DAY_SEC + LOOP_SEC) * 0.5
	var night := blend(tw, dn, 0.35)
	night["sun_energy"] = 0.0
	if sec <= mid:
		night["sun_dir"] = tw["sun_dir"]
		var u := (sec - DAY_SEC) / (mid - DAY_SEC)
		return blend(tw, night, u * u * (3.0 - 2.0 * u))
	night["sun_dir"] = dn["sun_dir"]
	var v := (sec - mid) / (LOOP_SEC - mid)
	return blend(night, dn, v * v * (3.0 - 2.0 * v))


static func stage_name_loop(sec: float) -> String:
	sec = fposmod(sec, LOOP_SEC)
	return stage_name(sec) if sec <= DAY_SEC else "twilight->dawn"


## 当前时段名（保持段为单名，渐变段为「甲→乙」）
static func stage_name(sec: float) -> String:
	for i in range(KEYS.size() - 1):
		if sec <= float(KEYS[i + 1][0]):
			var a := String(KEYS[i][1])
			var b := String(KEYS[i + 1][1])
			return a if a == b else "%s->%s" % [a, b]
	return String(KEYS[KEYS.size() - 1][1])


## 逐帧安全的应用：只写颜色、能量、方向和 shader uniform。
func apply_fast(w, p: Dictionary) -> void:
	w.sky_mat.sky_top_color = p.sky_top
	w.sky_mat.sky_horizon_color = p.sky_horizon
	w.sky_mat.ground_bottom_color = p.ground_bottom
	w.sky_mat.ground_horizon_color = p.ground_horizon
	w.sky_mat.energy_multiplier = p.sky_energy
	var env: Environment = w.env
	env.ambient_light_energy = p.ambient
	env.tonemap_exposure = p.exposure
	env.adjustment_saturation = p.saturation
	env.adjustment_contrast = p.contrast
	env.glow_intensity = p.glow
	env.glow_hdr_threshold = p.glow_threshold
	env.sdfgi_energy = p.sdfgi_energy
	var sd: Vector3 = (p.sun_dir as Vector3).normalized()
	w.sun.light_color = p.sun_color
	w.sun.light_energy = p.sun_energy
	w.sun.transform = Transform3D(Basis.looking_at(sd, Vector3.UP), Vector3.ZERO)
	w.sun.shadow_opacity = p.shadow_opacity
	w.sun.shadow_blur = p.shadow_blur
	w.sun.light_angular_distance = p.sun_angular
	w.sun.light_indirect_energy = p.sun_indirect
	if w.ground_mat:
		w.ground_mat.set_shader_parameter("sun_dir", sd)
	w.set_post_param("sun_to", -sd)
	if w.post2d_rect:
		var m2 := w.post2d_rect.material as ShaderMaterial
		if m2 != null:
			m2.set_shader_parameter("sun_pos", p.post_sun_pos)
			m2.set_shader_parameter("sun_gain", p.post_sun_gain)
	var fd: Vector3 = (p.fill_dir as Vector3).normalized()
	w.fill.light_color = p.fill_color
	w.fill.light_energy = p.fill_energy
	w.fill.transform = Transform3D(Basis.looking_at(fd, Vector3.UP), Vector3.ZERO)
	if _city_shade:
		_city_shade.transform = w.fill.transform
	w.rim.light_color = p.rim_color
	w.rim.light_energy = p.rim_energy
	if w.sea_mat:
		w.sea_mat.set_shader_parameter("light_tint", p.sea_tint)
		w.sea_mat.set_shader_parameter("light_lines", p.sea_lines)
	var night: float = clampf(float(p.night), 0.0, 1.0)
	for g: Array in w.city_glow:
		var m: StandardMaterial3D = g[0]
		if not m.emission_enabled:
			m.emission_enabled = true
			m.emission = g[1]
		m.emission_energy_multiplier = float(g[2]) * night
	for l: OmniLight3D in _base_energy:
		l.light_energy = float(_base_energy[l]) * night
		l.visible = night > 0.01
	for sm in w.sealife_mats:
		sm.set_shader_parameter("night_lift", float(p.night_lift))
	var life = w.life
	if life:
		life.fire_energy = float(p.fire)
		var fx: float = p.fx_light
		life.fx_light = fx
		if life.dust_mat:
			life.dust_mat.set_shader_parameter("light", fx * fx)
		if life._wake_mat:
			life._wake_mat.set_shader_parameter("light", clampf(fx * 1.1, 0.0, 1.0))
		if not life.storm.is_empty():
			(life.storm.cloud_mat as ShaderMaterial).set_shader_parameter("lit", Color(0.78, 0.8, 0.86) * fx)
			(life.storm.cloud_mat as ShaderMaterial).set_shader_parameter("shade", Color(0.42, 0.45, 0.55) * fx)
			(life.storm.rain_mat as StandardMaterial3D).albedo_color = Color(0.78 * fx, 0.86 * fx, 1.0 * fx, 0.7)
		for m in life.smoke_mats:
			m.albedo_color = p.smoke
		if life.mist_mat:
			life.mist_mat.set_shader_parameter("tint", p.mist)
			life.mist_mat.set_shader_parameter("opacity", float(p.mist_opacity))
	if w.cloud_mat:
		w.cloud_mat.set_shader_parameter("lit", p.cloud_lit)
		w.cloud_mat.set_shader_parameter("shade", p.cloud_shade)
