extends Node3D
## Claude's merchant board — the living layer (Carlos 2026-09-24 goal: 微动效果、小动物、动态天气、
## L叔彩蛋、骆驼和小船实机植入). Added by tools/merchant_board_claude_review.gd after the world is built.
##   caravans  - 3 camels walk every LAND route city to city (beside the dashes), pause, turn back
##   boats     - a dhow (west) or a junk (east) sails every SEA route, bobbing and rolling
##   smoke     - chimney smoke rising from every city and every camp fire, drifting with the wind
##   dust      - dust devils wandering over the deserts, fading in and out
##   mist      - low mist breathing in the valleys at the feet of green and snow mountains
##   birds     - crane flocks flying slow loops (their shadows cross the ground)
##   sheep     - small flocks grazing on the grassland
##   weather   - (off, see `weather`) a rain shower drifting across the board now and then (dark
##               cloud, rain, a moving shadow on the ground), leaving a rainbow behind it
##   L叔       - the hero of 旅人模式 wanders around a tent; every so often he packs up and turns up
##               at another camp (key 8 finds him)
## Placement comes from build_board.py (layout.routes, layout.life); assets are optional (a missing
## GLB just skips that part).

const LIFE_DIR := "res://assets/merchant_board_claude/life/"
const CRITTER_SHADER := "res://shaders/merchant_board_claude/board_critter.gdshader"
const LSHU_SCENE := "res://scenes/traveler/action2_character.tscn"
const LSHU_STYLE := "res://scripts/traveler/character_style.gd"

var board: Node          # the review scene (for load_gltf / layout / materials)
var layout: Dictionary
var time := 0.0
var wind := Vector3(0.35, 0.0, 0.08)

var movers: Array = []   # {mm, idx[], route, s, dir, pause, speed, spacing, side, kind, size, local}
# player pieces (set every frame by the playable board): ambient caravans and boats give way to
# them, shrinking out of the way instead of walking / sailing through a player's camel or boat
var avoid_points := PackedVector3Array()
var sheep: Array = []    # {mm, i, home, pos, target, heading, wait, local, size}
var birds: Array = []    # {mm, i, flock, lag, lat, dy, local, size}
var dust: Array = []     # {node, home, phase}
var smoke_mats: Array[StandardMaterial3D] = []
var mist_mat: ShaderMaterial
var storm := {}
# the passing shower (dark cloud, rain, its shadow, the rainbow) is off: Carlos 2026-09-25 「去掉乌云
# 和雨水彩虹吧，这个经常会被一些大陆地貌挡住很奇怪」 — mountains and plateaus cut through it
var weather := false
var lshu := {}
var camps: Array = []
var fires: Array = []
var fire_energy := 0.25
var boat_lights: Array[OmniLight3D] = []
var dust_mat: ShaderMaterial
var fx_light := 1.0
var mists: Array[MeshInstance3D] = []
## 工坊就地整理（docs/design/map-editor-20260930/DESIGN.md 3.12.7）：hide_near 藏起来的营地、羊、尘土、薄雾
var _hidden_near: Array = []   # [Vector2 中心, 半径]


func setup(review: Node) -> void:
	board = review
	layout = review.layout
	build_movers()
	if layout.has("life"):
		var L: Dictionary = layout.life
		build_camps(L.get("camps", []))
		build_sheep(L.get("flocks", []))
		build_birds(L.get("birds", []))
		build_dust(L.get("dust", []))
		build_mist(L.get("mist", []))
	build_city_smoke()
	if weather:
		build_weather()
	# offline captures (--life-time): advance the caravans and boats to that moment
	var steps := mini(int(time / 0.1), 6000)
	for i in steps:
		update_movers(0.1)


# ------------------------------------------------------------------ helpers
func glb_mesh(asset: String) -> Array:
	var path := LIFE_DIR + asset + ".glb"
	if not FileAccess.file_exists(path):
		push_warning("board life asset missing: " + path)
		return []
	return board.first_mesh(path)


func critter_material(mesh: Mesh, hip_frac: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(CRITTER_SHADER)
	var box := mesh.get_aabb()
	m.set_shader_parameter("hip", box.position.y + box.size.y * hip_frac)
	return m


func multimesh(mesh: Mesh, n: int, mat: Material, shadows: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = n
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 200.0
	add_child(mmi)
	return mm


func route_table(points: Array) -> Dictionary:
	var pts := PackedVector3Array()
	for q: Array in points:
		pts.append(Vector3(q[0], q[1], q[2]))
	var cum := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		cum.append(cum[i - 1] + Vector2(pts[i].x, pts[i].z).distance_to(Vector2(pts[i - 1].x, pts[i - 1].z)))
	return {"pts": pts, "cum": cum, "L": cum[cum.size() - 1]}


func route_at(r: Dictionary, s: float) -> Array:
	var cum: PackedFloat32Array = r.cum
	s = clampf(s, 0.0, r.L)
	var i := clampi(cum.bsearch(s) - 1, 0, cum.size() - 2)
	var pts: PackedVector3Array = r.pts
	var t := (s - cum[i]) / maxf(cum[i + 1] - cum[i], 1e-5)
	var p := pts[i].lerp(pts[i + 1], t)
	var tan := Vector3(pts[i + 1].x - pts[i].x, 0.0, pts[i + 1].z - pts[i].z).normalized()
	return [p, tan]


func puff_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.45, Color(1, 1, 1, 0.75))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 64
	t.height = 64
	return t


func particles(amount: int, lifetime: float, mat: ParticleProcessMaterial, size: float, color: Color, additive := false, track := true) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.process_material = mat
	p.visibility_aabb = AABB(Vector3(-6, -2, -6), Vector3(12, 12, 12))
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.vertex_color_use_as_albedo = true
	sm.albedo_color = color
	sm.albedo_texture = puff_texture()
	sm.no_depth_test = false
	sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	q.material = sm
	p.draw_pass_1 = q
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if not additive and track:
		smoke_mats.append(sm)
	return p


func smoke_process(rise: float, spread: float) -> ParticleProcessMaterial:
	# a thin plume: puffs leave the chimney small, rise and lean with the wind, swell and fade
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = spread
	m.direction = Vector3(0, 1, 0)
	m.spread = 6.0
	m.initial_velocity_min = rise * 0.8
	m.initial_velocity_max = rise
	m.gravity = Vector3(wind.x * 0.3, 0.1, wind.z * 0.3)
	m.damping_min = 0.02
	m.damping_max = 0.05
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.12))
	sc.add_point(Vector2(0.5, 0.6))
	sc.add_point(Vector2(1, 1.0))
	var st := CurveTexture.new()
	st.curve = sc
	m.scale_curve = st
	var ag := Gradient.new()
	ag.set_color(0, Color(1, 1, 1, 0))
	ag.set_color(1, Color(1, 1, 1, 0))
	ag.add_point(0.08, Color(1, 1, 1, 0.85))
	ag.add_point(0.4, Color(1, 1, 1, 0.55))
	ag.add_point(0.7, Color(1, 1, 1, 0.0))
	var at := GradientTexture1D.new()
	at.gradient = ag
	m.color_ramp = at
	return m


# ------------------------------------------------------------------ caravans and boats
func build_movers() -> void:
	var camel := glb_mesh("camel")
	var dhow := glb_mesh("dhow")
	var junk := glb_mesh("junk")
	var land_routes: Array = []
	var sea_routes: Array = []
	for r: Dictionary in layout.routes:
		(land_routes if r.type == "LAND" else sea_routes).append(r)
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	if not camel.is_empty():
		var n := land_routes.size() * 3
		var mm := multimesh(camel[0], n, critter_material(camel[0], 0.4), true)
		var k := 0
		for r: Dictionary in land_routes:
			var tab := route_table(r.get("lane", r.points))
			var s0 := rng.randf_range(1.2, tab.L - 1.2)
			movers.append({"mm": mm, "idx": [k, k + 1, k + 2], "route": tab, "s": [s0, s0 - 0.55, s0 - 1.1],
				"dir": 1.0, "pause": 0.0, "speed": rng.randf_range(0.42, 0.55), "turn": 0.0,
				"side": 0.0 if r.has("lane") else 0.3, "kind": "camel", "size": 0.46, "local": camel[1], "rid": String(r.id)})
			for j in 3:
				mm.set_instance_custom_data(k + j, Color(0.0, rng.randf(), 1.0, 5.2))
			k += 3
	for r: Dictionary in sea_routes:
		var tab := route_table(r.get("lane", r.points))
		var mid: Vector3 = (tab.pts as PackedVector3Array)[(tab.pts as PackedVector3Array).size() / 2]
		var boat: Array = dhow if mid.x < 80.0 else junk
		if boat.is_empty():
			boat = junk if boat == dhow else dhow
		if boat.is_empty():
			continue
		var mm := multimesh(boat[0], 1, critter_material(boat[0], 0.0), true)
		mm.set_instance_custom_data(0, Color(2.0, rng.randf(), 0.0, 1.0))
		var wake := MeshInstance3D.new()
		var wp := PlaneMesh.new()
		wp.size = Vector2(1, 1)
		wake.mesh = wp
		wake.material_override = wake_material()
		wake.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(wake)
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.7, 0.35)
		lamp.light_energy = 1.2
		lamp.omni_range = 1.1
		lamp.shadow_enabled = false
		lamp.visible = false
		add_child(lamp)
		boat_lights.append(lamp)
		movers.append({"mm": mm, "idx": [0], "route": tab, "s": [rng.randf_range(0.5, tab.L - 0.5)],
			"dir": 1.0 if rng.randf() < 0.5 else -1.0, "pause": 0.0, "speed": rng.randf_range(0.55, 0.75), "turn": 0.0,
			"side": 0.0 if r.has("lane") else 0.35, "kind": "boat", "size": 0.95, "local": boat[1], "phase": rng.randf() * 6.28, "wake": wake, "lamp": lamp,
			"rid": String(r.id)})


var _wake_mat: ShaderMaterial


func wake_material() -> ShaderMaterial:
	if _wake_mat == null:
		_wake_mat = ShaderMaterial.new()
		_wake_mat.shader = load("res://shaders/merchant_board_claude/board_wake.gdshader")
		_wake_mat.render_priority = 1   # the sea (priority 0) would otherwise draw over it
	return _wake_mat


func update_movers(dt: float) -> void:
	for m: Dictionary in movers:
		var r: Dictionary = m.route
		var L: float = r.L
		var sl: Array = m.s
		if m.pause > 0.0:
			m.pause -= dt
			m.turn = clampf(1.0 - m.pause / 3.5, 0.0, 1.0)
			if m.pause <= 0.0:
				m.dir = -m.dir
				m.turn = 0.0
		else:
			var lo := INF
			var hi := -INF
			for j in sl.size():
				sl[j] = float(sl[j]) + m.dir * m.speed * dt
				lo = minf(lo, float(sl[j]))
				hi = maxf(hi, float(sl[j]))
			# the lead animal (max s going forward, min s going back) reaches the end of the lane:
			# all stop and turn round on the spot
			if (m.dir > 0.0 and hi > L - 0.05) or (m.dir < 0.0 and lo < 0.05):
				m.pause = 3.5
		var moving := 1.0 if m.pause <= 0.0 else 0.25
		var idx: Array = m.idx
		if not m.has("vis"):
			m.vis = []
			for j in idx.size():
				m.vis.append(1.0)
		for j in idx.size():
			var at := route_at(r, float(sl[j]))
			var p: Vector3 = at[0]
			var tan: Vector3 = at[1] * m.dir
			var right := Vector3(-tan.z, 0.0, tan.x)
			p += right * m.side
			var want := 1.0
			for q in avoid_points:
				var d := Vector2(q.x - p.x, q.z - p.z).length()
				want = minf(want, smoothstep(0.9, 1.7, d))
			m.vis[j] = lerpf(float(m.vis[j]), want, minf(1.0, dt * 6.0))
			# during the pause the heading swings round to the way back
			var yaw := atan2(-tan.z, tan.x) + PI * smoothstep(0.0, 1.0, m.turn)
			var basis := Basis(Vector3.UP, yaw)
			var size: float = m.size * maxf(float(m.vis[j]), 0.001)
			if m.kind == "camel":
				(m.mm as MultiMesh).set_instance_custom_data(idx[j], Color(0.0, float(j) * 0.37, moving, 5.2))
			else:
				var ph: float = m.phase + time * 1.4
				p.y = -0.12 * size / 0.95 + sin(ph) * 0.025
				basis = basis * Basis(Vector3.RIGHT, sin(ph * 0.8) * 0.06) * Basis(Vector3.BACK, sin(ph * 0.6 + 1.0) * 0.04)
			(m.mm as MultiMesh).set_instance_transform(idx[j], Transform3D(basis.scaled(Vector3(size, size, size)), p) * (m.local as Transform3D))
			if m.has("wake"):
				var wk: MeshInstance3D = m.wake
				var fwd := Vector3(cos(yaw), 0.0, -sin(yaw))
				# a 2.2 x 1.2 V behind the stern, lying on the water (scale in the boat's own frame)
				wk.transform = Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(2.2, 1.0, 1.2)), Vector3(p.x, 0.01, p.z) - fwd * (1.1 + size * 0.45))
				wk.set_instance_shader_parameter("moving", (1.0 if m.pause <= 0.0 else 0.0) * float(m.vis[0]))
				(m.lamp as OmniLight3D).position = p + Vector3(0, 0.45, 0) - fwd * 0.25


# ------------------------------------------------------------------ smoke, fires
func build_city_smoke() -> void:
	# two plumes per city, each rising from a real roof point: the highest vertex of the city
	# model, then the highest one at least 0.9 u away from it (a second roof or chimney)
	for id in board.city_nodes:
		_smoke_for_city(id)


## 一座城的两缕烟（build_city_smoke 逐城调；工坊就地刷新时新城、换了样子的城也用它，add_city_smoke）
func _smoke_for_city(id: String) -> void:
	var holder: Node3D = board.city_nodes[id].node
	# 自制地图整体重建世界时（模型缓存开着）：同一个模型、同样大小的城，烟囱位置按城自己的坐标系记下来直接用，
	# 不再把几十万个顶点排一遍序（平城京 23.6 万面，4 座替身就要好几秒）。第一次建世界照旧逐城现算。
	var key := "%s|%.5f" % [str(board.city_nodes[id].get("model", "")), float(board.city_nodes[id].get("scale", 1.0))]
	var local_picks: Array = []
	if bool(board.get("use_model_cache")) and _smoke_cache.has(key):
		local_picks = _smoke_cache[key]
	else:
		var top: Array[Vector3] = []
		for mi: MeshInstance3D in board.mesh_instances(holder):
			if mi.mesh == null:
				continue
			var xf := mi.global_transform
			var faces := mi.mesh.get_faces()
			for i in range(0, faces.size(), 3):
				top.append(xf * faces[i])
		if top.is_empty():
			return
		top.sort_custom(func(a, b): return a.y > b.y)
		var picks: Array[Vector3] = [top[0]]
		for q in top:
			if Vector2(q.x - top[0].x, q.z - top[0].z).length() > 0.9:
				picks.append(q)
				break
		var inv := holder.global_transform.affine_inverse()
		for q in picks:
			local_picks.append(inv * q)
		_smoke_cache[key] = local_picks
		_place_smoke(picks, id)
		return
	var world_picks: Array[Vector3] = []
	for q: Vector3 in local_picks:
		world_picks.append(holder.global_transform * q)
	_place_smoke(world_picks, id)


static var _smoke_cache := {}   # "模型路径|缩放" -> 烟囱在城自己坐标系里的位置
## 每座城的烟（城 id -> [GPUParticles3D]）：工坊就地刷新时烟跟着城挪、跟着城拆（move_city_smoke / drop_city_smoke）
var smoke_by_city := {}


func _place_smoke(picks: Array[Vector3], cid := "") -> void:
	for k in picks.size():
		var p := particles(34, 7.5, smoke_process(0.22, 0.03), 0.5, Color(0.97, 0.97, 0.95, 0.85))
		p.position = picks[k] + Vector3(0, 0.05, 0)
		p.preprocess = 5.0
		add_child(p)
		if cid != "":
			if not smoke_by_city.has(cid):
				smoke_by_city[cid] = []
			smoke_by_city[cid].append(p)


## 工坊就地刷新（docs/design/map-editor-20260930/DESIGN.md 3.12.7）：城挪了、转了，它的烟跟着同样挪（moved = 新的城变换 × 旧的城变换的逆）。
## 已经飘出去的烟团在世界坐标里（local_coords = false），重开一次，旧地方不留一缕烟
func move_city_smoke(cid: String, moved: Transform3D) -> void:
	for p in smoke_by_city.get(cid, []):
		if is_instance_valid(p):
			(p as Node3D).global_position = moved * (p as Node3D).global_position
			(p as GPUParticles3D).restart()


## 城拆了（新城撤掉、换了样子要重建）：它的烟一起拆
func drop_city_smoke(cid: String) -> void:
	for p in smoke_by_city.get(cid, []):
		if is_instance_valid(p):
			var q := (p as GPUParticles3D).draw_pass_1
			if q is PrimitiveMesh:
				smoke_mats.erase((q as PrimitiveMesh).material)
			(p as Node).queue_free()
	smoke_by_city.erase(cid)


## 新建的城（新城、换了样子的城）：照 build_city_smoke 给它两缕烟；先拆掉这座城原来的烟
func add_city_smoke(cid: String) -> void:
	drop_city_smoke(cid)
	if board.city_nodes.has(cid):
		_smoke_for_city(cid)


func build_camps(list: Array) -> void:
	var tent := glb_mesh("tent")
	for c: Dictionary in list:
		var home := Vector3(c.x, c.y, c.z)
		var node := Node3D.new()
		node.position = home
		add_child(node)
		if not tent.is_empty():
			var mi := MeshInstance3D.new()
			mi.mesh = tent[0]
			var sm := StandardMaterial3D.new()
			sm.vertex_color_use_as_albedo = true
			sm.roughness = 0.85
			mi.material_override = sm
			mi.transform = Transform3D(Basis(Vector3.UP, 0.6).scaled(Vector3.ONE * 1.25), Vector3(0, -0.02, 0)) * (tent[1] as Transform3D)
			node.add_child(mi)
		# camp fire: flame puffs, warm flickering light, a wisp of smoke
		var fire_pos := Vector3(0.44, 0.08, 0.20)   # the stone ring in tent.glb
		var fm := ParticleProcessMaterial.new()
		fm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		fm.emission_sphere_radius = 0.04
		fm.direction = Vector3(0, 1, 0)
		fm.spread = 10.0
		fm.initial_velocity_min = 0.15
		fm.initial_velocity_max = 0.3
		fm.gravity = Vector3(0, 0.2, 0)
		var fc := Gradient.new()
		fc.set_color(0, Color(1.0, 0.85, 0.35, 1.0))
		fc.set_color(1, Color(0.9, 0.25, 0.05, 0.0))
		var fct := GradientTexture1D.new()
		fct.gradient = fc
		fm.color_ramp = fct
		var flame := particles(18, 0.7, fm, 0.16, Color(1, 0.62, 0.22, 1), false, false)
		flame.position = fire_pos
		node.add_child(flame)
		var sm2 := particles(16, 6.0, smoke_process(0.18, 0.02), 0.32, Color(0.9, 0.9, 0.9, 0.6))
		sm2.position = fire_pos + Vector3(0, 0.12, 0)
		sm2.preprocess = 3.0
		node.add_child(sm2)
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.6, 0.3)
		light.light_energy = 0.6
		light.omni_range = 1.4
		light.shadow_enabled = false
		light.position = fire_pos + Vector3(0, 0.15, 0)
		node.add_child(light)
		fires.append(light)
		var spots: Array[Vector3] = []
		for q: Array in c.get("spots", []):
			spots.append(Vector3(q[0], q[1], q[2]))
		if spots.is_empty():
			spots.append(home + Vector3(0.3, 0.0, 0.8))
		camps.append({"home": home, "node": node, "fire": home + fire_pos, "spots": spots})
	if not camps.is_empty():
		build_lshu()


# ------------------------------------------------------------------ L叔 (Easter egg)
func build_lshu() -> void:
	if not ResourceLoader.exists(LSHU_SCENE):
		return
	var model := (load(LSHU_SCENE) as PackedScene).instantiate() as Node3D
	var root := Node3D.new()
	root.name = "LShu"
	root.add_child(model)
	add_child(root)
	var player := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var body := model.find_children("*", "MeshInstance3D", true, false)
	var h := 1.0
	if not body.is_empty():
		var aabb: AABB = (body[0] as MeshInstance3D).get_aabb()
		h = maxf(aabb.size.y, 0.01)
		model.position = Vector3(-aabb.get_center().x, -aabb.position.y, -aabb.get_center().z)
	if ResourceLoader.exists(LSHU_STYLE):
		var style: Object = (load(LSHU_STYLE) as GDScript).new()
		style.call("configure", model)
	var height := 0.5
	root.scale = Vector3.ONE * (height / h)
	lshu = {"root": root, "player": player, "camp": 0, "pos": Vector3.ZERO, "target": Vector3.ZERO,
		"wait": 1.0, "anim": "", "hop": 55.0, "vis": 1.0, "spot": 0, "base_scale": root.scale.x}
	var start_camp := int(OS.get_environment("LSHU_CAMP")) if OS.get_environment("LSHU_CAMP") != "" else 0
	place_lshu(clampi(start_camp, 0, camps.size() - 1))


func place_lshu(ci: int) -> void:
	lshu.camp = ci
	var spots: Array = camps[ci].spots
	lshu.spot = spots.size() / 2
	lshu.pos = spots[lshu.spot]
	lshu.target = lshu.pos
	lshu.wait = 1.5
	lshu.hop = randf_range(45.0, 70.0)


func lshu_play(anim: String) -> void:
	if lshu.anim == anim or lshu.player == null:
		return
	lshu.anim = anim
	var ap: AnimationPlayer = lshu.player
	if ap.has_animation(anim):
		ap.play(anim, 0.25)
		if anim == "bow":
			ap.queue("idle")


func update_lshu(dt: float) -> void:
	if lshu.is_empty():
		return
	var root: Node3D = lshu.root
	var spots: Array = camps[lshu.camp].spots
	lshu.hop -= dt
	if lshu.hop <= 0.0 and camps.size() > 1:
		# packs up (shrinks away) and turns up at the next camp
		lshu.vis = maxf(0.0, lshu.vis - dt * 1.2)
		if lshu.vis <= 0.0:
			place_lshu((int(lshu.camp) + 1) % camps.size())
	else:
		lshu.vis = minf(1.0, lshu.vis + dt * 1.2)
	var to: Vector3 = lshu.target - lshu.pos
	if lshu.wait > 0.0:
		lshu.wait -= dt
		if lshu.anim != "bow":
			lshu_play("idle")
		if lshu.wait <= 0.0:
			# walks to a neighbouring spot on the ring in front of the tent (never through it)
			var n := spots.size()
			var k: int = clampi(int(lshu.spot) + (1 if randf() < 0.5 else -1) * randi_range(1, 2), 0, n - 1)
			lshu.spot = k
			lshu.target = spots[k]
	elif Vector2(to.x, to.z).length() < 0.04:
		lshu.wait = randf_range(2.5, 6.0)
		if randf() < 0.3:
			lshu.anim = ""
			lshu_play("bow")
			lshu.wait = maxf(lshu.wait, 4.2)
	else:
		lshu_play("walk")
		var step := minf(to.length(), 0.3 * dt)
		lshu.pos += to.normalized() * step
		root.rotation.y = atan2(to.x, to.z)
	root.position = lshu.pos
	var e: float = smoothstep(0.0, 1.0, lshu.vis)
	root.scale = Vector3.ONE * lshu.base_scale * maxf(e, 0.001)
	root.visible = lshu.vis > 0.01
	for f in fires:
		f.light_energy = fire_energy * (1.0 + 0.3 * sin(time * 13.0 + f.position.x) + 0.18 * sin(time * 23.0))


func lshu_position() -> Vector3:
	return lshu.root.global_position if not lshu.is_empty() else Vector3.ZERO


# ------------------------------------------------------------------ sheep
func build_sheep(flocks: Array) -> void:
	var m := glb_mesh("sheep")
	if m.is_empty() or flocks.is_empty():
		return
	var n := 0
	for f: Dictionary in flocks:
		n += int(f.count)
	var mm := multimesh(m[0], n, critter_material(m[0], 0.3), true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var i := 0
	for f: Dictionary in flocks:
		var home := Vector3(f.x, f.y, f.z)
		for k in int(f.count):
			var p := home + Vector3(rng.randf_range(-0.6, 0.6), 0, rng.randf_range(-0.5, 0.5))
			sheep.append({"mm": mm, "i": i, "home": home, "pos": p, "target": p, "heading": rng.randf() * TAU,
				"wait": rng.randf_range(0.5, 6.0), "local": m[1], "size": rng.randf_range(0.2, 0.25)})
			mm.set_instance_custom_data(i, Color(0.0, rng.randf(), 0.0, 6.0))
			i += 1


func update_sheep(dt: float) -> void:
	for s: Dictionary in sheep:
		var to: Vector3 = s.target - s.pos
		to.y = 0.0
		var moving := 0.0
		if s.wait > 0.0:
			s.wait -= dt
			if s.wait <= 0.0:
				s.target = s.home + Vector3(randf_range(-0.7, 0.7), 0, randf_range(-0.55, 0.55))
		elif to.length() < 0.03:
			s.wait = randf_range(3.0, 9.0)
		else:
			moving = 1.0
			s.pos += to.normalized() * minf(to.length(), 0.1 * dt)
			s.heading = lerp_angle(s.heading, atan2(-to.z, to.x), minf(1.0, dt * 3.0))
		var mm: MultiMesh = s.mm
		var sz: float = s.size
		if s.get("hidden", false):
			sz = 0.0001          # 工坊里新城盖住了这群羊（hide_near）
		mm.set_instance_transform(s.i, Transform3D(Basis(Vector3.UP, s.heading).scaled(Vector3(sz, sz, sz)), s.pos) * (s.local as Transform3D))
		var cd := mm.get_instance_custom_data(s.i)
		mm.set_instance_custom_data(s.i, Color(0.0, cd.g, moving, 6.0))


# ------------------------------------------------------------------ birds
func build_birds(flocks: Array) -> void:
	var m := glb_mesh("crane")
	if m.is_empty() or flocks.is_empty():
		return
	var n := 0
	for f: Dictionary in flocks:
		n += int(f.count)
	var mat := critter_material(m[0], 0.0)
	mat.set_shader_parameter("wing_amp", 0.22)
	var mm := multimesh(m[0], n, mat, true)
	var i := 0
	for fi in flocks.size():
		var f: Dictionary = flocks[fi]
		for k in int(f.count):
			# a loose V: the leader first, the rest alternating left / right behind
			var side := 0.0 if k == 0 else (1.0 if k % 2 == 1 else -1.0) * float((k + 1) / 2)
			birds.append({"mm": mm, "i": i, "flock": f, "lag": float((k + 1) / 2) * 0.05, "lat": side * 0.45,
				"dy": randf_range(-0.1, 0.1), "local": m[1], "size": 0.55, "dir": 1.0 if fi % 2 == 0 else -1.0})
			mm.set_instance_custom_data(i, Color(1.0, randf(), 0.0, randf_range(4.0, 5.0)))
			i += 1


func update_birds() -> void:
	for b: Dictionary in birds:
		var f: Dictionary = b.flock
		var r: float = f.r
		var w: float = 0.55 / r * b.dir
		var a: float = time * w - float(b.lag) * signf(w) * 6.0
		var c := Vector3(f.x, f.y, f.z)
		var pos := c + Vector3(cos(a) * r, sin(time * 0.3 + a) * 0.25 + b.dy, sin(a) * r * 0.75)
		var tan := Vector3(-sin(a) * r, 0, cos(a) * r * 0.75).normalized() * signf(w)
		var right := Vector3(-tan.z, 0, tan.x)
		pos += right * b.lat
		var yaw := atan2(-tan.z, tan.x)
		var bank := -0.35 * signf(w)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, bank)
		var sz: float = b.size
		(b.mm as MultiMesh).set_instance_transform(b.i, Transform3D(basis.scaled(Vector3(sz, sz, sz)), pos) * (b.local as Transform3D))


# ------------------------------------------------------------------ dust devils
func build_dust(list: Array) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/merchant_board_claude/board_dust_devil.gdshader")
	dust_mat = mat
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.07
	cyl.height = 1.0
	cyl.cap_top = false
	cyl.cap_bottom = false
	cyl.radial_segments = 20
	cyl.rings = 6
	var k := 0.0
	for d: Dictionary in list:
		var mi := MeshInstance3D.new()
		mi.mesh = cyl
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_instance_shader_parameter("seed", k)
		mi.scale = Vector3(1.0, 1.7, 1.0)
		add_child(mi)
		dust.append({"node": mi, "home": Vector3(d.x, d.y, d.z), "phase": k * 2.7, "r": float(d.get("r", 0.8))})
		k += 1.0


func update_dust() -> void:
	for d: Dictionary in dust:
		var ph: float = d.phase
		var cyc := fposmod(time + ph * 7.0, 26.0) / 26.0       # a 26 s life cycle
		var life := smoothstep(0.0, 0.15, cyc) * (1.0 - smoothstep(0.55, 0.75, cyc))
		var home: Vector3 = d.home
		var rr: float = d.r
		var p := home + Vector3(sin(time * 0.11 + ph) * rr, 0.85, cos(time * 0.09 + ph) * rr * 0.8)
		var mi: MeshInstance3D = d.node
		mi.position = p
		mi.visible = life > 0.01 and not d.get("hidden", false)
		mi.set_instance_shader_parameter("life", life)


# ------------------------------------------------------------------ mist
func build_mist(list: Array) -> void:
	mist_mat = ShaderMaterial.new()
	mist_mat.shader = load("res://shaders/merchant_board_claude/board_mist.gdshader")
	var plane := PlaneMesh.new()
	plane.size = Vector2(1, 1)
	var k := 0.0
	for m: Dictionary in list:
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		mi.material_override = mist_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_instance_shader_parameter("seed", k)
		mi.scale = Vector3(float(m.w) * 1.4, 1.0, float(m.w) * 0.8)
		mi.position = Vector3(m.x, float(m.y) + 0.35, m.z)
		add_child(mi)
		mists.append(mi)
		k += 1.37


# ------------------------------------------------------------------ weather: a passing shower + rainbow
func build_weather() -> void:
	var cloud := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	cloud.mesh = q
	var cm := ShaderMaterial.new()
	cm.shader = load("res://shaders/merchant_board_claude/board_cloud.gdshader")
	cm.set_shader_parameter("lit", Color(0.78, 0.8, 0.86))
	cm.set_shader_parameter("shade", Color(0.42, 0.45, 0.55))
	cloud.material_override = cm
	cloud.set_instance_shader_parameter("seed", 3.3)
	cloud.set_instance_shader_parameter("opacity", 0.0)
	cloud.scale = Vector3(9.0, 4.2, 1.0)
	cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(cloud)
	var rm := ParticleProcessMaterial.new()
	rm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	rm.emission_ring_axis = Vector3(0, 1, 0)
	rm.emission_ring_radius = 2.8
	rm.emission_ring_inner_radius = 0.0
	rm.emission_ring_height = 0.2
	rm.scale_min = 0.6
	rm.scale_max = 1.0
	rm.direction = Vector3(0.15, -1, 0)
	rm.spread = 2.0
	rm.initial_velocity_min = 6.0
	rm.initial_velocity_max = 7.5
	rm.gravity = Vector3(0, -2, 0)
	rm.particle_flag_align_y = true
	var rain := GPUParticles3D.new()
	rain.amount = 900
	rain.lifetime = 0.75
	rain.local_coords = false
	rain.process_material = rm
	rain.visibility_aabb = AABB(Vector3(-5, -8, -4), Vector3(10, 10, 8))
	var streak := QuadMesh.new()
	streak.size = Vector2(0.03, 0.45)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	sm.billboard_keep_scale = true
	sm.albedo_color = Color(0.78, 0.86, 1.0, 0.55)
	streak.material = sm
	rain.draw_pass_1 = streak
	rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rain.emitting = false
	add_child(rain)
	var bow := MeshInstance3D.new()
	var bq := QuadMesh.new()
	bq.size = Vector2(1, 1)
	bow.mesh = bq
	var bm := ShaderMaterial.new()
	bm.shader = load("res://shaders/merchant_board_claude/board_rainbow.gdshader")
	bow.material_override = bm
	bow.scale = Vector3(14.0, 7.0, 1.0)
	bow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bow)
	storm = {"cloud": cloud, "cloud_mat": cm, "rain": rain, "rain_mat": sm, "bow": bow, "bow_mat": bm, "period": 95.0, "z": 20.0, "cycle": -1}


func update_weather() -> void:
	if storm.is_empty():
		return
	var period: float = storm.period
	var cyc := int(floor((time + 20.0) / period))
	var t := fposmod(time + 20.0, period) / period      # 0..1 across the board, west -> east
	if cyc != storm.cycle:
		storm.cycle = cyc
		var rng := RandomNumberGenerator.new()
		rng.seed = cyc * 7919 + 13
		storm.z = rng.randf_range(12.0, 40.0)
		storm.x0 = rng.randf_range(10.0, 40.0)
	var x: float = storm.x0 + t * 70.0
	var z: float = storm.z + sin(t * 3.0) * 3.0
	var on := smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.7, 0.85, t))
	var cloud: MeshInstance3D = storm.cloud
	cloud.position = Vector3(x, 7.2, z)
	cloud.set_instance_shader_parameter("opacity", 0.95 * on)
	var rain: GPUParticles3D = storm.rain
	rain.position = Vector3(x, 4.8, z)
	rain.emitting = on > 0.3
	# rainbow: rises behind the shower as it leaves, then fades
	var bow: MeshInstance3D = storm.bow
	var b := smoothstep(0.45, 0.62, t) * (1.0 - smoothstep(0.82, 0.98, t)) * smoothstep(0.6, 0.9, fx_light)
	bow.position = Vector3(x - 6.5, 2.6, z - 3.5)
	(storm.bow_mat as ShaderMaterial).set_shader_parameter("strength", b)
	bow.visible = b > 0.01
	# the shower's shadow and wet darkening on the ground
	if board.ground_mat:
		board.ground_mat.set_shader_parameter("storm", Vector4(x + 1.2, z + 1.8, 5.0, 0.4 * on))
	if OS.get_environment("LIFE_DEBUG") != "" and Engine.get_process_frames() % 60 == 0:
		print("STORM t=%.2f x=%.1f z=%.1f on=%.2f bow=%.2f" % [t, x, z, on, b])


# ------------------------------------------------------------------ lighting hooks
func set_preset(p: Dictionary) -> void:
	fire_energy = float(p.get("fire", 0.25))
	# unshaded effects follow the scene brightness (no glowing dust or rain at night)
	fx_light = float(p.get("fx_light", 1.0))
	if dust_mat:
		dust_mat.set_shader_parameter("light", fx_light * fx_light)
	if _wake_mat:
		_wake_mat.set_shader_parameter("light", clampf(fx_light * 1.1, 0.0, 1.0))
	if not storm.is_empty():
		(storm.cloud_mat as ShaderMaterial).set_shader_parameter("lit", Color(0.78, 0.8, 0.86) * fx_light)
		(storm.cloud_mat as ShaderMaterial).set_shader_parameter("shade", Color(0.42, 0.45, 0.55) * fx_light)
		(storm.rain_mat as StandardMaterial3D).albedo_color = Color(0.78 * fx_light, 0.86 * fx_light, 1.0 * fx_light, 0.7)
	for l in boat_lights:
		l.visible = bool(p.get("city_lights", false))
	var smoke_col: Color = p.get("smoke", Color(0.97, 0.97, 0.95, 0.85))
	for m in smoke_mats:
		m.albedo_color = smoke_col
	if mist_mat:
		mist_mat.set_shader_parameter("tint", p.get("mist", Color(0.96, 0.97, 1.0)))
		mist_mat.set_shader_parameter("opacity", float(p.get("mist_opacity", 0.38)))


# ------------------------------------------------------------------ 工坊就地更新（自制地图）
## 换一条路的路线表（工坊改了路形、挪了城，docs/design/map-editor-20260930/DESIGN.md 3.12.7）：这条路上的驼队 / 船队
## 改沿新点列走（没有 lane 了，照没有 lane 的路那样走在虚线旁边），位置夹到新长度以内。没有这条路的驼队时什么都不做。
func retarget_route(rid: String, points: Array) -> int:
	var n := 0
	for m: Dictionary in movers:
		if String(m.get("rid", "")) != rid:
			continue
		var tab := route_table(points)
		m.route = tab
		m.side = 0.3 if m.kind == "camel" else 0.35
		var sl: Array = m.s
		for j in sl.size():
			sl[j] = clampf(float(sl[j]), 0.05, maxf(float(tab.L) - 0.05, 0.05))
		n += 1
	return n


## 藏起 (x, z) 周围 r 以内的营地、羊群、尘土、薄雾（新城、挪过的城盖在上面）。可以叠加调用；clear_hidden() 全部放回。
func hide_near(xz: Vector2, r: float) -> int:
	_hidden_near.append([xz, r])
	return _apply_hidden()


func clear_hidden() -> void:
	_hidden_near.clear()
	_apply_hidden()


func _is_hidden_at(p: Vector3) -> bool:
	for h: Array in _hidden_near:
		if Vector2(p.x, p.z).distance_to(h[0]) < float(h[1]):
			return true
	return false


func _apply_hidden() -> int:
	var n := 0
	for c: Dictionary in camps:
		var hid := _is_hidden_at(c.home)
		(c.node as Node3D).visible = not hid
		n += 1 if hid else 0
	for sh: Dictionary in sheep:
		sh.hidden = _is_hidden_at(sh.home)
		n += 1 if sh.hidden else 0
	for d: Dictionary in dust:
		d.hidden = _is_hidden_at(d.home)
		n += 1 if d.hidden else 0
	for mi in mists:
		var hid := _is_hidden_at(mi.position)
		mi.visible = not hid
		n += 1 if hid else 0
	return n


func _process(dt: float) -> void:
	time += dt
	update_movers(dt)
	update_sheep(dt)
	update_birds()
	update_dust()
	update_weather()
	update_lshu(dt)
