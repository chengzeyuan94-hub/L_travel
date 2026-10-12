extends SceneTree
## wp_particle_period.gd（2026-09-23，macOS 动态壁纸试验）：GPUParticles3D 能不能做到"按周期精确重复"。
## 5 个并排的小 SubViewport，各放一套粒子，只改"种子取法"和 randomness：
##   V0 NUMBER+RANDOM_SEED, randomness 0.8   ← 与 lookdev_tree_leaves / sand_flow 现在的写法相同
##   V1 NUMBER+RANDOM_SEED, randomness 0
##   V2 INDEX+RANDOM_SEED,  randomness 0     ← 检验 use_fixed_seed 下 RANDOM_SEED 是否跨周期不变
##   V3 NUMBER % (amount*3), randomness 0     ← 期望周期 = 3 × lifetime
##   V4 INDEX only,          randomness 0.8   ← 单独检验 randomness 的影响
## 用 --fixed-fps 30 跑：每帧固定 1/30 s。在第 A 帧和 A + k·60 帧（lifetime = 2 s）抓图比较。
## 输出一行 WP_PARTICLE_PERIOD {...}，然后退出。只写 stdout，不写文件。

const LIFETIME := 2.0
const FPS := 30
const AMOUNT := 16
const SIZE := Vector2i(160, 160)
const BASE_FRAME := 100
const CHECKS := [0, 60, 120, 180, 240, 360]

const SHADER_CODE := """
shader_type particles;
uniform int mode = 0;
uniform int number_mod = 48;
uint hash_u(uint x) {
	x ^= x >> 16u; x *= 0x7feb352du; x ^= x >> 15u; x *= 0x846ca68bu; x ^= x >> 16u;
	return x;
}
float r(uint s, uint k) {
	return float(hash_u(s * 0x9E3779B9u + k * 0x85EBCA6Bu + 0x68E31DA4u) & 0x00FFFFFFu) / 16777216.0;
}
void start() {
	uint key;
	if (mode == 0) { key = NUMBER * 747796405u + RANDOM_SEED * 2891336453u; }
	else if (mode == 1) { key = INDEX * 747796405u; }
	else if (mode == 2) { key = INDEX * 747796405u + RANDOM_SEED * 2891336453u; }
	else { key = (NUMBER % uint(number_mod)) * 747796405u; }
	uint seed = hash_u(key + 17u);
	vec3 pos = vec3(r(seed, 1u) * 2.0 - 1.0, r(seed, 2u) * 1.4 - 0.2, 0.0);
	TRANSFORM = mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(pos, 1.0));
	VELOCITY = vec3((r(seed, 3u) - 0.5) * 0.6, -0.4 - 0.3 * r(seed, 4u), 0.0);
}
void process() {
}
"""

var views: Array = []
var frame := 0
var shots := {}
var done := false

func _initialize() -> void:
	var cfgs := [
		{"name": "V0_number_seed_rand0.8", "mode": 0, "randomness": 0.8},
		{"name": "V1_number_seed_rand0", "mode": 0, "randomness": 0.0},
		{"name": "V2_index_seed_rand0", "mode": 2, "randomness": 0.0},
		{"name": "V3_number_mod3_rand0", "mode": 3, "randomness": 0.0},
		{"name": "V4_index_only_rand0.8", "mode": 1, "randomness": 0.8},
	]
	var shader := Shader.new()
	shader.code = SHADER_CODE
	var i := 0
	for c in cfgs:
		var vp := SubViewport.new()
		vp.size = SIZE
		vp.own_world_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(vp)
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = 3.0
		cam.position = Vector3(0, 0, 5)
		vp.add_child(cam)
		cam.make_current()
		var p := GPUParticles3D.new()
		p.amount = AMOUNT
		p.lifetime = LIFETIME
		p.preprocess = 0.0
		p.randomness = float(c.randomness)
		p.explosiveness = 0.0
		p.fixed_fps = FPS
		p.interpolate = false
		p.fract_delta = true
		p.use_fixed_seed = true
		p.seed = 7
		p.local_coords = false
		p.visibility_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))
		var pm := ShaderMaterial.new()
		pm.shader = shader
		pm.set_shader_parameter("mode", int(c.mode))
		pm.set_shader_parameter("number_mod", AMOUNT * 3)
		p.process_material = pm
		var q := QuadMesh.new()
		q.size = Vector2(0.12, 0.12)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color.WHITE
		q.material = m
		p.draw_pass_1 = q
		vp.add_child(p)
		p.emitting = true
		var tr := TextureRect.new()
		tr.texture = vp.get_texture()
		tr.position = Vector2(i * (SIZE.x + 4), 0)
		tr.size = Vector2(SIZE)
		root.add_child(tr)
		views.append({"name": c.name, "vp": vp})
		i += 1
	RenderingServer.frame_post_draw.connect(_on_post_draw)

func _on_post_draw() -> void:
	if done:
		return
	frame += 1
	for k in CHECKS:
		if frame == BASE_FRAME + int(k):
			for v in views:
				var img: Image = (v.vp as SubViewport).get_texture().get_image()
				shots["%s@%d" % [v.name, k]] = img
	if frame >= BASE_FRAME + int(CHECKS.back()):
		done = true
		var out := {"lifetime_s": LIFETIME, "fps": FPS, "amount": AMOUNT, "base_frame": BASE_FRAME, "godot": Engine.get_version_info().string, "results": {}}
		for v in views:
			var base: Image = shots["%s@0" % v.name]
			var row := {}
			for k in CHECKS:
				if int(k) == 0:
					continue
				var img: Image = shots["%s@%d" % [v.name, k]]
				row["+%d_frames(%.0fs)" % [k, float(k) / FPS]] = _diff(base, img)
			out.results[v.name] = row
		print("WP_PARTICLE_PERIOD ", JSON.stringify(out))
		quit()

# 返回不同像素的比例（任一通道差 > 8/255）
func _diff(a: Image, b: Image) -> float:
	var n := 0
	var tot := a.get_width() * a.get_height()
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) > 0.03 or absf(ca.g - cb.g) > 0.03 or absf(ca.b - cb.b) > 0.03:
				n += 1
	return snappedf(float(n) / float(tot), 0.0001)
