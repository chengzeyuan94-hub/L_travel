extends Control
## 默认开场「旅行L叔」：黄昏山坡上，L叔 坐在行李箱上，身后一条丝路蜿蜒进远方。
## 画面由 image 2.5 的原画拆成层（tools/lshu_ui/process_home.py），在这里动起来：
##   L叔 呼吸、眨眼、头顶小揪和手里的土豆花随风摆；点他会笑着跳一下，撒出小花。
##   云慢慢飘，热气球起伏，纸飞机隔一阵从左边滑到右上，鸟群飞过，驼队沿路慢慢走；
##   前景的草和花被风吹动，花瓣、蒲公英、金色光点在空中飘；鼠标移动时画面有一点视差。
## 所有坐标都是原画像素（2048×1152），_layout() 把整张画按铺满再放大 ZOOM 倍、往左推，给右上的进度面板让位。

signal lshu_poked

const DIR := "res://assets/game/ui/lshu_home/"
const ART := Vector2(2048, 1152)
const ZOOM := 1.07
const ANCHOR := Vector2(0.94, 0.5)  # 右边留一点余量，视差挪动时不露边
## L叔 坐在箱子上的着力点（原画坐标）：呼吸、跳起都以这里为轴
const SEAT := Vector2(1230, 800)

const SWAY_SHADER := """
shader_type canvas_item;
// 前景的草和花被风吹：遮罩只盖住草和花（行李箱、路牌、石头为 0）
uniform sampler2D sway_mask : filter_linear;
uniform vec2 art_size = vec2(2048.0, 1152.0);
void fragment() {
	float m = texture(sway_mask, UV).r;
	float w = m * m;
	vec2 px = UV * art_size;
	float gust = 0.6 + 0.4 * sin(TIME * 0.43 + UV.x * 2.2);
	float a = sin(TIME * 1.7 + px.y * 0.045 + px.x * 0.011) + 0.45 * sin(TIME * 3.1 + px.x * 0.031);
	vec2 off = vec2(a * 3.4 * gust, abs(a) * 0.7) * w;
	COLOR = texture(TEXTURE, UV - off / art_size);
}
"""

const BODY_SHADER := """
shader_type canvas_item;
// L叔 身上两处小动作：头顶的小揪左右摆，手里的土豆花绕握着的地方摇
uniform vec2 tex_size = vec2(430.0, 847.0);
uniform vec2 tuft_base = vec2(245.0, 62.0);
uniform vec2 flower_pivot = vec2(50.0, 298.0);
void fragment() {
	vec2 p = UV * tex_size;
	float tw = clamp((tuft_base.y - p.y) / 57.0, 0.0, 1.0) * smoothstep(62.0, 40.0, abs(p.x - tuft_base.x));
	p.x -= (sin(TIME * 2.3) * 4.5 + sin(TIME * 5.1) * 1.0) * tw * tw;
	vec2 d = p - flower_pivot;
	float fw = smoothstep(2.0, -12.0, d.y) * smoothstep(66.0, 58.0, p.x) * smoothstep(92.0, 72.0, length(d));
	float ang = (sin(TIME * 1.8) * 0.085 + sin(TIME * 4.3) * 0.02) * fw;
	float c = cos(ang);
	float s = sin(ang);
	p = flower_pivot + vec2(c * d.x - s * d.y, s * d.x + c * d.y);
	COLOR = texture(TEXTURE, p / tex_size);
}
"""

const POKE_LINES: Array[String] = [
	"嘿，别戳我眼镜～",
	"行李都收拾好啦，\n出发吗？",
	"土豆花开了，\n要不要去看看？",
	"今天的晚霞\n特别好看！",
	"走过山海，\n遇见世界～",
]

var meta: Dictionary = {}
var art: Control
var lshu: Control
var body: TextureRect
var face_blink: TextureRect
var face_laugh: TextureRect
var flower_glow: TextureRect
var sun_glow: TextureRect
var balloon: TextureRect
var plane: TextureRect
var trail: Line2D
var clouds: Array[Dictionary] = []
var birds: Array[Dictionary] = []
var camels: Array[Dictionary] = []
var poke_burst: CPUParticles2D
var _t: float = 0.0
var _next_blink: float = 2.5
var _blink_until: float = -1.0
var _laugh_until: float = -1.0
var _hop: Tween
var _parallax: Vector2 = Vector2.ZERO
var _art_base_pos: Vector2 = Vector2.ZERO
var _art_base_scale: float = 1.0
var _trail_pts: Array[Vector2] = []
var _poke_i: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var p: String = DIR + "home.json"
	if FileAccess.file_exists(p):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if d is Dictionary:
			meta = d
	_build()
	resized.connect(_layout)
	_layout()


func _tex(name: String) -> Texture2D:
	for ext: String in [".png", ".jpg"]:
		var p: String = DIR + name + ext
		if ResourceLoader.exists(p):
			return load(p) as Texture2D
	return null


func _sprite(name: String, parent: Control, pos_key: String = "") -> TextureRect:
	var t := TextureRect.new()
	t.name = name.to_pascal_case()
	t.texture = _tex(name)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_SCALE
	if t.texture != null:
		t.size = t.texture.get_size()
	var key: String = pos_key if pos_key != "" else name
	if meta.has(key):
		var m: Dictionary = meta[key]
		t.position = Vector2(m.pos[0], m.pos[1])
		t.size = Vector2(m.size[0], m.size[1])
	t.set_meta("base_pos", t.position)
	t.pivot_offset = t.size * 0.5
	parent.add_child(t)
	return t


func _soft(sz: int, inner: float = 0.2) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, inner, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.5), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = sz
	t.height = sz
	return t


func _add_mat() -> CanvasItemMaterial:
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return m


# ------------------------------------------------------------------ 搭场景
func _build() -> void:
	art = Control.new()
	art.name = "Art"
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.size = ART
	add_child(art)

	var plate := TextureRect.new()
	plate.name = "Plate"
	plate.texture = _tex("plate")
	plate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	plate.size = ART
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SWAY_SHADER
	sm.shader = sh
	sm.set_shader_parameter("sway_mask", _tex("sway_mask"))
	plate.material = sm
	art.add_child(plate)

	# 太阳的光晕轻轻呼吸
	sun_glow = TextureRect.new()
	sun_glow.name = "SunGlow"
	sun_glow.texture = _soft(128, 0.12)
	sun_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sun_glow.size = Vector2(560, 560)
	sun_glow.position = Vector2(245, 578) - sun_glow.size * 0.5
	sun_glow.modulate = Color(1.0, 0.82, 0.55, 0.3)
	sun_glow.material = _add_mat()
	sun_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.add_child(sun_glow)

	# 云：四朵，在天上慢慢往右飘，出了右边从左边再进来
	var cl: Array = meta.get("clouds", [])
	var cloud_plan: Array = [[0.62, 70.0, 7.0, 0.1], [0.5, 190.0, 11.0, 0.55], [0.44, 20.0, 9.0, 0.82], [0.55, 150.0, 5.5, 0.33]]
	for i in cl.size():
		var c: Dictionary = cl[i]
		var plan: Array = cloud_plan[i % cloud_plan.size()]
		var t := _sprite(str(c.name), art, str(c.name))
		t.size = Vector2(c.size[0], c.size[1]) * float(plan[0])
		t.modulate = Color(1, 1, 1, 0.82)
		clouds.append({"node": t, "y": float(plan[1]), "speed": float(plan[2]), "x": lerpf(-300.0, ART.x, float(plan[3]))})

	balloon = _sprite("balloon", art)
	# 鸟：三只一小群，隔一阵从左往右飞过
	for i in 3:
		var bname: String = "bird_2" if i != 1 else "bird_1"
		var b := _sprite(bname, art, bname)
		if i == 2:
			b.size *= 0.8
		b.pivot_offset = b.size * 0.5
		birds.append({"node": b, "off": [Vector2(0, 0), Vector2(-70, 34), Vector2(-120, -18)][i], "phase": float(i) * 1.7})

	trail = Line2D.new()
	trail.name = "PlaneTrail"
	trail.width = 3.0
	trail.default_color = Color(1, 1, 1, 0.55)
	var tg := Gradient.new()
	tg.offsets = PackedFloat32Array([0.0, 1.0])
	tg.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.6)])
	trail.gradient = tg
	trail.joint_mode = Line2D.LINE_JOINT_ROUND
	trail.begin_cap_mode = Line2D.LINE_CAP_ROUND
	trail.end_cap_mode = Line2D.LINE_CAP_ROUND
	trail.antialiased = true
	art.add_child(trail)
	plane = _sprite("plane", art)

	# 驼队：四头骆驼沿右边的沙路慢慢走，各自起伏
	var cm: Array = meta.get("camels", [])
	for i in cm.size():
		var m: Dictionary = cm[i]
		var t := TextureRect.new()
		t.name = "Camel%d" % (i + 1)
		t.texture = _tex("camel_%d" % (i + 1))
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.position = Vector2(m.pos[0], m.pos[1])
		t.size = Vector2(m.size[0], m.size[1])
		t.pivot_offset = Vector2(t.size.x * 0.5, t.size.y)
		art.add_child(t)
		camels.append({"node": t, "base": t.position, "phase": float(i) * 1.35})

	# 金色光点从草地里慢慢升起
	var motes := CPUParticles2D.new()
	motes.name = "Motes"
	motes.texture = _soft(48, 0.1)
	motes.amount = 34
	motes.lifetime = 8.0
	motes.preprocess = 8.0
	motes.position = Vector2(ART.x * 0.5, 1010)
	motes.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	motes.emission_rect_extents = Vector2(ART.x * 0.5, 130)
	motes.direction = Vector2(0.25, -1)
	motes.spread = 25.0
	motes.gravity = Vector2(4, -4)
	motes.initial_velocity_min = 8.0
	motes.initial_velocity_max = 22.0
	motes.scale_amount_min = 0.12
	motes.scale_amount_max = 0.32
	motes.color = Color(1.0, 0.85, 0.5, 0.9)
	motes.color_ramp = _fade_ramp()
	motes.material = _add_mat()
	art.add_child(motes)

	# L叔：身体一层 + 闭眼 / 大笑两张脸，整组以坐的位置为轴
	lshu = Control.new()
	lshu.name = "Lshu"
	lshu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lm: Dictionary = meta.get("lshu", {"pos": [1027, 227], "size": [430, 847]})
	lshu.position = Vector2(lm.pos[0], lm.pos[1])
	lshu.size = Vector2(lm.size[0], lm.size[1])
	lshu.pivot_offset = SEAT - lshu.position
	lshu.set_meta("base_pos", lshu.position)
	art.add_child(lshu)
	body = TextureRect.new()
	body.name = "Body"
	body.texture = _tex("lshu_body")
	body.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	body.size = lshu.size
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bm := ShaderMaterial.new()
	var bsh := Shader.new()
	bsh.code = BODY_SHADER
	bm.shader = bsh
	bm.set_shader_parameter("tex_size", lshu.size)
	body.material = bm
	lshu.add_child(body)
	face_blink = _face("face_blink")
	face_laugh = _face("face_laugh")
	flower_glow = TextureRect.new()
	flower_glow.name = "FlowerGlow"
	flower_glow.texture = _soft(64, 0.15)
	flower_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	flower_glow.size = Vector2(150, 150)
	flower_glow.position = Vector2(34, 250) - flower_glow.size * 0.5
	flower_glow.modulate = Color(1.0, 0.95, 0.75, 0.4)
	flower_glow.material = _add_mat()
	flower_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lshu.add_child(flower_glow)

	# 前景飘的：花瓣、小花、蒲公英
	var pet: Array = meta.get("petals", [])
	var groups: Array = [
		{"names": ["petal_1", "petal_3", "petal_7", "petal_8"], "amount": 5, "scale": [0.2, 0.34], "vel": [70.0, 120.0], "dir": Vector2(1, 0.12), "spin": 70.0, "grav": Vector2(0, 7)},
		{"names": ["petal_2", "petal_5"], "amount": 2, "scale": [0.22, 0.3], "vel": [60.0, 95.0], "dir": Vector2(1, 0.05), "spin": 50.0, "grav": Vector2(0, 5)},
		{"names": ["petal_4", "petal_6"], "amount": 2, "scale": [0.34, 0.46], "vel": [35.0, 60.0], "dir": Vector2(1, -0.3), "spin": 8.0, "grav": Vector2(0, -3)},
	]
	if not pet.is_empty():
		for g: Dictionary in groups:
			for nm: String in g.names:
				var pt := CPUParticles2D.new()
				pt.name = "Drift_" + nm
				pt.texture = _tex(nm)
				pt.amount = int(g.amount)
				pt.lifetime = 22.0
				pt.preprocess = 22.0
				pt.position = Vector2(-60, 640)
				pt.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
				pt.emission_rect_extents = Vector2(40, 420)
				pt.direction = g.dir
				pt.spread = 10.0
				pt.gravity = g.grav
				pt.initial_velocity_min = float(g.vel[0])
				pt.initial_velocity_max = float(g.vel[1])
				pt.angle_min = 0.0
				pt.angle_max = 360.0
				pt.angular_velocity_min = -float(g.spin)
				pt.angular_velocity_max = float(g.spin)
				pt.scale_amount_min = float(g.scale[0])
				pt.scale_amount_max = float(g.scale[1])
				pt.color_ramp = _fade_ramp()
				art.add_child(pt)

	# 点 L叔 撒出来的小花
	poke_burst = CPUParticles2D.new()
	poke_burst.name = "PokeBurst"
	poke_burst.texture = _tex("petal_2")
	poke_burst.emitting = false
	poke_burst.one_shot = true
	poke_burst.explosiveness = 0.92
	poke_burst.amount = 14
	poke_burst.lifetime = 1.6
	poke_burst.position = Vector2(1230, 330)
	poke_burst.direction = Vector2(0, -1)
	poke_burst.spread = 80.0
	poke_burst.gravity = Vector2(0, 420)
	poke_burst.initial_velocity_min = 260.0
	poke_burst.initial_velocity_max = 420.0
	poke_burst.angular_velocity_min = -240.0
	poke_burst.angular_velocity_max = 240.0
	poke_burst.scale_amount_min = 0.3
	poke_burst.scale_amount_max = 0.5
	poke_burst.color_ramp = _fade_ramp()
	art.add_child(poke_burst)

	# 能点的区域：L叔 的身子（不含箱子）
	var hit := Control.new()
	hit.name = "LshuHit"
	hit.position = Vector2(1060, 240)
	hit.size = Vector2(380, 620)
	hit.mouse_filter = Control.MOUSE_FILTER_STOP
	hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hit.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			poke())
	art.add_child(hit)


func _face(name: String) -> TextureRect:
	var t := TextureRect.new()
	t.name = name.to_pascal_case()
	t.texture = _tex(name)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if meta.has(name):
		var m: Dictionary = meta[name]
		t.position = Vector2(m.pos[0], m.pos[1]) - lshu.position
		t.size = Vector2(m.size[0], m.size[1])
	t.visible = false
	lshu.add_child(t)
	return t


func _fade_ramp() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.1, 0.85, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	return g


# ------------------------------------------------------------------ 互动
## 点 L叔：笑着跳一下，撒一把小花，并告诉开场换一句话
func poke() -> void:
	_laugh_until = _t + 1.4
	poke_burst.restart()
	poke_burst.emitting = true
	if _hop != null:
		_hop.kill()
	var base: Vector2 = lshu.get_meta("base_pos")
	_hop = create_tween()
	_hop.tween_property(lshu, "position:y", base.y - 30.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_hop.tween_property(lshu, "position:y", base.y, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_hop.tween_property(lshu, "position:y", base.y - 6.0, 0.08).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_hop.tween_property(lshu, "position:y", base.y, 0.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	lshu_poked.emit()


func next_poke_line() -> String:
	var line: String = POKE_LINES[_poke_i % POKE_LINES.size()]
	_poke_i += 1
	return line


# ------------------------------------------------------------------ 每帧
func _process(delta: float) -> void:
	_t += delta
	var t: float = _t
	# 视差：鼠标偏哪边，画面往反方向挪一点；整张画还有很慢的推拉
	if size.x > 0.0:
		var m: Vector2 = (get_local_mouse_position() / size - Vector2(0.5, 0.5)).clamp(Vector2(-0.5, -0.5), Vector2(0.5, 0.5))
		_parallax = _parallax.lerp(-m * Vector2(12, 8), minf(1.0, delta * 2.5))
	# 开场头 3 秒镜头从稍近处慢慢退回来，之后很慢地推拉
	var intro: float = 1.0 + 0.06 * pow(1.0 - clampf(t / 3.2, 0.0, 1.0), 3.0)
	var breathe: float = (1.0 + 0.008 * sin(t * TAU / 26.0)) * intro
	art.scale = Vector2.ONE * _art_base_scale * breathe
	var center: Vector2 = size * 0.5
	art.position = center + (_art_base_pos - center) * breathe + _parallax
	var px_art: Vector2 = _parallax / maxf(0.001, art.scale.x)

	# 云
	for c: Dictionary in clouds:
		var n: TextureRect = c.node
		var x: float = fposmod(float(c.x) + t * float(c.speed) + 400.0, ART.x + 800.0) - 400.0 - n.size.x * 0.5
		n.position = Vector2(x, float(c.y) + sin(t * 0.2 + float(c.speed)) * 6.0) - px_art * 0.35
	# 热气球
	var bb: Vector2 = balloon.get_meta("base_pos")
	balloon.position = bb + Vector2(sin(t * 0.11) * 42.0, sin(t * 0.9) * 9.0 + sin(t * 0.37) * 6.0) - px_art * 0.25
	balloon.rotation = sin(t * 0.7) * 0.035
	# 鸟群：每 38 秒飞过一次
	var bu: float = fposmod(t + 6.0, 38.0) / 24.0
	for b: Dictionary in birds:
		var n: TextureRect = b.node
		n.visible = bu < 1.0
		if bu < 1.0:
			var off: Vector2 = b.off
			n.position = Vector2(lerpf(-160.0, ART.x + 160.0, bu), 190.0 - bu * 90.0 + sin(bu * 9.0 + float(b.phase)) * 14.0) + off - px_art * 0.3
			n.scale = Vector2(1.0, 0.45 + 0.55 * absf(sin(t * 6.5 + float(b.phase))))
	# 纸飞机：每 26 秒从左下滑到右上，中途打个小弯，带一条尾迹
	var pu: float = fposmod(t + 12.0, 26.0) / 12.0
	plane.visible = pu < 1.0
	if pu < 1.0:
		var pos: Vector2 = _plane_path(pu)
		var ahead: Vector2 = _plane_path(minf(1.0, pu + 0.01))
		plane.position = pos - plane.size * 0.5 - px_art * 0.3
		plane.rotation = (ahead - pos).angle() + 0.42
		_trail_pts.append(pos - px_art * 0.3)
		if _trail_pts.size() > 40:
			_trail_pts.remove_at(0)
	else:
		_trail_pts.clear()
	trail.points = PackedVector2Array(_trail_pts)
	# 驼队：沿路往右下走，走到头淡出再从头来
	var cu: float = fposmod(t * 3.2, 150.0)
	var dir: Vector2 = Vector2(1.0, 0.33).normalized()
	var fade: float = clampf(cu / 12.0, 0.0, 1.0) * clampf((150.0 - cu) / 12.0, 0.0, 1.0)
	for c: Dictionary in camels:
		var n: TextureRect = c.node
		var step: float = t * 3.4 + float(c.phase)
		n.position = Vector2(c.base) + dir * (cu - 70.0) + Vector2(0, -absf(sin(step)) * 2.2)
		n.rotation = sin(step) * 0.04
		n.modulate.a = fade
	# 太阳光晕
	sun_glow.modulate.a = 0.26 + 0.06 * sin(t * 0.6)
	# L叔：呼吸、轻晃、眨眼、笑
	var br: float = sin(t * TAU / 3.4)
	lshu.scale = Vector2(1.0 - 0.004 * br, 1.0 + 0.011 * br)
	lshu.rotation = sin(t * TAU / 7.3) * 0.006
	flower_glow.modulate.a = 0.34 + 0.16 * sin(t * 2.3)
	if t >= _next_blink:
		_blink_until = t + 0.13
		_next_blink = t + (0.28 if randf() < 0.2 else randf_range(2.4, 5.2))
	var laughing: bool = t < _laugh_until
	face_laugh.visible = laughing
	face_blink.visible = not laughing and t < _blink_until


func _plane_path(u: float) -> Vector2:
	var a := Vector2(-140, 560)
	var b := Vector2(ART.x + 160, 90)
	var p: Vector2 = a.lerp(b, u)
	p.y += sin(u * PI * 2.2) * 70.0
	# 中段打一个小圈
	var lu: float = clampf((u - 0.52) / 0.14, 0.0, 1.0)
	if lu > 0.0 and lu < 1.0:
		var th: float = lu * TAU
		p += Vector2(sin(th) * 70.0 - lu * 0.0, -(1.0 - cos(th)) * 60.0)
	return p


# ------------------------------------------------------------------ 布局：铺满再放大一点，往左推
func _layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_art_base_scale = maxf(size.x / ART.x, size.y / ART.y) * ZOOM
	_art_base_pos = (size - ART * _art_base_scale) * ANCHOR
	art.scale = Vector2.ONE * _art_base_scale
	art.position = _art_base_pos
