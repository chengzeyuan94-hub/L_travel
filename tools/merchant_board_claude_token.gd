extends Node3D
## A player's piece on Claude's merchant board: L叔 riding a camel on land, L叔 sailing a boat
## at sea, in the player's colour (team-key faces of the GLB take the colour in
## board_player.gdshader). Drawn well above the ambient caravans (camel 0.46) and boats (0.95) so
## a player's piece is the first thing the eye finds on the board.
##
##   plan_seconds(points, kinds)            exact duration of a move: every span of the path has its
##                                          own time (a road step 2 s, a walk through a city 1 s, a
##                                          transport switch 1.3 s) plus a short turn on the spot
##   move_along(points, media, knots, kinds, secs)
##                                          plays it: eases out of the start, slows (does not stop)
##                                          through each coin / gate on the way, eases into the end,
##                                          turns in place first if the road starts >50 deg off the
##                                          current heading; emits `arrived` exactly at the end
##   cancel()                               stops without emitting
##   place(point, medium, yaw)              snaps (restart / resync)
##
## Motion details: the camel pitches with the slope of the road and the heading looks ahead and
## turns at a capped rate; the walk cycle follows the distance travelled (capped at 3 Hz), the body
## sways from side to side with the steps and the head nods; dust puffs kick up on each footfall
## with a bigger puff on departure and a nose-down settle on arrival. The boat bobs, lifts its bow
## under way, banks into turns, throws bow spray and drags a wake that grow with its speed; it
## splashes on departure and settles with a ripple on arrival. A medium change inside a move (embarking at a port) swaps camel <-> boat
## with a splash. The current player's piece glows softly and has a pulsing team-colour ring;
## the others keep a faint ring so every player can be told apart at a glance. A small map pin in
## the team colour floats above every piece and shows through buildings, so a piece waiting at a
## city gate behind the houses can still be found (a pin, not a numbered disc: numbered discs are
## the step counts of the move markers).

signal arrived

const PLAYER_SHADER := "res://shaders/merchant_board_claude/board_player.gdshader"
const WAKE_SHADER := "res://shaders/merchant_board_claude/board_wake.gdshader"
const CAMEL_GLB := "res://assets/merchant_board_claude/player/player_camel.glb"
const BOAT_GLB := "res://assets/merchant_board_claude/player/player_boat.glb"
const FALLBACK_CAMEL := "res://assets/merchant_board_claude/life/camel.glb"
const FALLBACK_BOAT := "res://assets/merchant_board_claude/life/dhow.glb"

# Starting values (Carlos tunes art parameters freely; nothing here is a gate).
@export var camel_size := 1.1       # model length in world units; ambient camels are 0.46
@export var boat_size := 1.8        # ambient boats are 0.95 (with a much taller sail)
@export var edge_seconds := 2.0     # one road step between two nodes (Carlos: 「2 秒一段路线」)
@export var cross_seconds := 1.0    # through a city from one gate to another
@export var switch_seconds := 1.3   # a transport switch at a port
@export var through_speed := 0.35   # speed through a coin / gate on the way, x the slower
									# neighbouring span's average speed
@export var turn_rate := 4.0        # rad / s
@export var stride_per_unit := 5.5  # walk-cycle radians per camel length travelled
@export var max_gait_hz := 3.6
@export var ramp := 0.22            # share of a span spent speeding up / slowing down (the rest cruises)

var team_color := Color(0.8, 0.28, 0.23)
var camel: MeshInstance3D
var boat: MeshInstance3D
var camel_mat: ShaderMaterial
var boat_mat: ShaderMaterial
var wake: MeshInstance3D
var dust: GPUParticles3D
var puff: GPUParticles3D
var spray: GPUParticles3D
var splash: GPUParticles3D
var ring: MeshInstance3D            # at sea: a flat torus on the water
var ring_mat: StandardMaterial3D
var ground_ring: Decal              # on land: projected onto the ground / coin, never clips a slope
const PIECE_LAYER := 2              # the piece's own meshes: excluded from its ground ring decal
var ripple: MeshInstance3D
var ripple_mat: StandardMaterial3D
var _custom_skins: Dictionary = {}
var _default_skins: Dictionary = {}
var _camel_locomotion: CustomMapCamelLocomotion
var _frame_distance := 0.0
var _turn_diff := 0.0
var _skin_specs: Dictionary = {}
var medium := "LAND"
var heading := 0.0
var pitch := 0.0
var bank := 0.0
var walk_phase := 0.0
var bob_t := 0.0
var active := false
var slot_offset := Vector3.ZERO
var slot_scale := 1.0               # a crowded berth draws an extra boat smaller (paths.slot_offsets)
var _slot_scale := 1.0
var _slot := Vector3.ZERO
var ground_offset := 0.09           # route points sit this far above the ground (land)
var waterline := 0.15               # boat model: height of the waterline above its keel (model units)
const SEA_Y := 0.02                 # water surface
const COIN_TOP := 0.22              # stop coins are discs this thick on the route line, tilted 18 deg
const COIN_TILT := 0.314            # (radians) toward the camera
var coins := PackedVector3Array()   # stop coin centres: a piece steps up onto a coin and down again
var on_coin := 0.0                  # 0..1 how far up on a coin the piece stands now
var pin: Sprite3D
var role_label: Label3D             # 「你」 / 「AI」 over the pin (formal RoleLabel)
var pop := 0.0                      # camel <-> boat swap: the new model pops in with a small overshoot
const POP_TIME := 0.32
var settle := 0.0                   # arrival settle / ripple timer
var _base := Vector3.ZERO

# move state
var _pts := PackedVector3Array()
var _media := PackedStringArray()
var _cum := PackedFloat32Array()
var _L := 0.0
var _t_of_s := PackedFloat32Array()  # time (s) at each sample of _s_samples
var _s_samples := PackedFloat32Array()
var _T := 0.0
var _pre := 0.0                      # in-place pre-turn time
var _pre_shrink := false             # (unused: turning boats fit themselves to the water via fit)
var _hops := PackedInt32Array()      # segments hopped (in at one city stand, out at another)
var _hop_fx := {}                    # hop segment -> 1 dipped out / 2 popped in
var _end_yaw := INF                  # heading to take when the move ends in a hop (a switch)
var _on_coin_target := 0.0
var hop_vis := 1.0                   # 0..1 scale of the piece during a hop
var spin_shrink := 1.0
var fit_fn: Callable                 # (point, yaw) -> hull scale that fits the water there
									 # (paths.hull_fit); the boat sails a little smaller through a
									 # strait narrower than its hull
var fit := 1.0
var _fit_key := Vector4(INF, INF, INF, 0.0)
var _elapsed := 0.0
var _moving := false
var _speed := 0.0
var _last_s := 0.0


func setup(board: Node, color: Color, default_plan: Dictionary = {}) -> void:
	team_color = color
	var cm: Array = board.first_mesh(CAMEL_GLB if FileAccess.file_exists(CAMEL_GLB) else FALLBACK_CAMEL)
	var bm: Array = board.first_mesh(BOAT_GLB if FileAccess.file_exists(BOAT_GLB) else FALLBACK_BOAT)
	camel_mat = _material()
	boat_mat = _material()
	camel = _instance(cm, camel_mat, camel_size)
	boat = _instance(bm, boat_mat, boat_size)
	var ca: AABB = (cm[0] as Mesh).get_aabb()
	var ba: AABB = (bm[0] as Mesh).get_aabb()
	# model contracts (player GLB notes): legs are everything below 0.28 H; the pennant is
	# everything above the rider's head / the mast cap (~0.09 / 0.07 under the top) and flies aft
	# from its hoist, the pennant's most forward vertex; boat waterline z 0.15
	camel_mat.set_shader_parameter("hip", ca.position.y + ca.size.y * 0.28)
	camel_mat.set_shader_parameter("stride_amp", 0.13)     # longer steps: the feet keep up with the ground
	var cf := ca.end.y - 0.088
	camel_mat.set_shader_parameter("flag_from", cf)
	camel_mat.set_shader_parameter("flag_x", _hoist_x(cm[0], cf))
	boat_mat.set_shader_parameter("hip", -10.0)
	var bf := ba.end.y - 0.07
	boat_mat.set_shader_parameter("flag_from", bf)
	boat_mat.set_shader_parameter("flag_x", _hoist_x(bm[0], bf))
	waterline = 0.15 if FileAccess.file_exists(BOAT_GLB) else 0.126
	_load_transport_skins(default_plan)
	_build_fx()
	set_medium("LAND")


func _hoist_x(mesh: Mesh, from_y: float) -> float:
	var hx := -INF
	if mesh is ArrayMesh and (mesh as ArrayMesh).get_surface_count() > 0:
		var arr := (mesh as ArrayMesh).surface_get_arrays(0)
		if not arr.is_empty():
			for v: Vector3 in arr[Mesh.ARRAY_VERTEX]:
				if v.y > from_y:
					hx = maxf(hx, v.x)
	return hx if hx > -INF else 0.0


func _material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(PLAYER_SHADER)
	m.set_shader_parameter("team_color", team_color)
	return m


func _instance(ml: Array, mat: ShaderMaterial, size: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = ml[0]
	mi.material_override = mat
	mi.transform = Transform3D(Basis.from_scale(Vector3.ONE * size), Vector3.ZERO) * (ml[1] as Transform3D)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.layers = PIECE_LAYER
	var holder := Node3D.new()
	holder.add_child(mi)
	add_child(holder)
	return mi


func _puff_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 32
	t.height = 32
	return t


func _particles(amount: int, life: float, pm: ParticleProcessMaterial, size: float, color: Color, one_shot := false) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.local_coords = false
	p.one_shot = one_shot
	p.explosiveness = 0.9 if one_shot else 0.0
	p.process_material = pm
	p.emitting = false
	p.visibility_aabb = AABB(Vector3(-3, -1, -3), Vector3(6, 4, 6))
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.vertex_color_use_as_albedo = true
	sm.albedo_color = color
	sm.albedo_texture = _puff_texture()
	sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	q.material = sm
	p.draw_pass_1 = q
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	return p


func _dust_process(spread_box: Vector3, vmin: float, vmax: float) -> ParticleProcessMaterial:
	var dm := ParticleProcessMaterial.new()
	dm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	dm.emission_box_extents = spread_box
	dm.direction = Vector3(0, 1, 0)
	dm.spread = 70.0
	dm.initial_velocity_min = vmin
	dm.initial_velocity_max = vmax
	dm.gravity = Vector3(0, -0.2, 0)
	dm.damping_min = 0.8
	dm.damping_max = 1.4
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.35))
	sc.add_point(Vector2(1, 1.4))
	var st := CurveTexture.new()
	st.curve = sc
	dm.scale_curve = st
	var ag := Gradient.new()
	ag.set_color(0, Color(1, 1, 1, 0.75))
	ag.set_color(1, Color(1, 1, 1, 0))
	var at := GradientTexture1D.new()
	at.gradient = ag
	dm.color_ramp = at
	return dm


func _spray_process(dir: Vector3, spread: float, vmin: float, vmax: float, box: Vector3) -> ParticleProcessMaterial:
	var sp := ParticleProcessMaterial.new()
	sp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	sp.emission_box_extents = box
	sp.direction = dir
	sp.spread = spread
	sp.initial_velocity_min = vmin
	sp.initial_velocity_max = vmax
	sp.gravity = Vector3(0, -3.5, 0)
	var sg := Gradient.new()
	sg.set_color(0, Color(1, 1, 1, 0.95))
	sg.set_color(1, Color(1, 1, 1, 0))
	var sgt := GradientTexture1D.new()
	sgt.gradient = sg
	sp.color_ramp = sgt
	return sp


func _build_fx() -> void:
	var sand := Color(0.86, 0.74, 0.55, 0.95)
	var k := camel_size / 0.72
	var kb := boat_size / 1.3
	dust = _particles(56, 1.0, _dust_process(Vector3(0.2, 0.01, 0.12) * k, 0.15 * k, 0.4 * k), 0.26 * k, sand)
	puff = _particles(22, 1.1, _dust_process(Vector3(0.28, 0.02, 0.2) * k, 0.3 * k, 0.7 * k), 0.3 * k, sand, true)
	spray = _particles(64, 0.55, _spray_process(Vector3(-0.35, 1.0, 0.0), 80.0, 0.6 * kb, 1.1 * kb, Vector3(0.06, 0.03, 0.26) * kb), 0.13 * kb, Color(0.95, 0.98, 1.0, 1.0))
	splash = _particles(40, 0.8, _spray_process(Vector3(0, 1, 0), 75.0, 0.7 * kb, 1.3 * kb, Vector3(0.3, 0.02, 0.2) * kb), 0.1 * kb, Color(0.95, 0.98, 1.0, 1.0), true)
	wake = MeshInstance3D.new()
	var wp := PlaneMesh.new()
	wp.size = Vector2(1, 1)
	wake.mesh = wp
	var wm := ShaderMaterial.new()
	wm.shader = load(WAKE_SHADER)
	wm.render_priority = 1
	wake.material_override = wm
	wake.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(wake)
	ring = _torus(0.42, 0.5)
	ring_mat = ring.material_override
	ground_ring = Decal.new()
	ground_ring.texture_albedo = _ring_texture(false)
	ground_ring.texture_emission = _ring_texture(true)
	ground_ring.albedo_mix = 1.0
	ground_ring.upper_fade = 0.15
	ground_ring.lower_fade = 0.3
	ground_ring.normal_fade = 0.55     # not on cliff faces (a straight-down projection smears there)
	ground_ring.cull_mask = 0xFFFFF & ~PIECE_LAYER
	add_child(ground_ring)
	ripple = _torus(0.46, 0.52)
	ripple_mat = ripple.material_override
	ripple_mat.albedo_color = Color(1, 1, 1, 0.0)
	_build_pin()


func _pin_image() -> Image:
	# map pin: team-colour head with a white dot, white rim, point at the bottom
	var w := 64
	var h := 84
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var c := Vector2(32, 30)
	var dark := team_color.darkened(0.3)
	for y in h:
		for x in w:
			var p := Vector2(x + 0.5, y + 0.5)
			var d := p.distance_to(c)
			var t := (p.y - 30.0) / 50.0
			var half := 27.0 * (1.0 - t)
			var in_tip := t >= 0.0 and t <= 1.0 and absf(p.x - 32.0) <= half
			if d > 28.5 and not in_tip:
				continue
			var inner := d <= 24.0 or (in_tip and absf(p.x - 32.0) <= half - 5.0 and t < 0.86)
			var col := Color.WHITE
			if inner:
				col = team_color.lerp(dark, clampf((p.y - 20.0) / 50.0, 0.0, 1.0))
				if d <= 9.0:
					col = Color.WHITE
			var a := 1.0 if in_tip else clampf(28.5 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(col, a))
	return img


func _build_pin() -> void:
	pin = Sprite3D.new()
	pin.texture = ImageTexture.create_from_image(_pin_image())
	pin.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	pin.fixed_size = true
	pin.no_depth_test = true
	pin.pixel_size = 0.0012
	pin.render_priority = 5
	pin.offset = Vector2(0, 42)          # the point touches the anchor
	pin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pin)
	role_label = Label3D.new()
	role_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	role_label.fixed_size = true
	role_label.no_depth_test = true
	role_label.pixel_size = 0.0011
	role_label.font_size = 40
	role_label.outline_size = 12
	role_label.modulate = Color.WHITE
	role_label.outline_modulate = team_color.darkened(0.45)
	role_label.render_priority = 6
	role_label.offset = Vector2(0, 110)
	role_label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	role_label.visible = false
	add_child(role_label)


func set_role(text: String) -> void:
	role_label.text = text
	role_label.visible = text != ""


## ring for the ground decal; emission: black outside the ring (emission ignores alpha)
func _ring_texture(emission: bool) -> ImageTexture:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var a := clampf((d - 0.8) / 0.03, 0.0, 1.0) * clampf((0.98 - d) / 0.03, 0.0, 1.0)
			img.set_pixel(x, y, Color(a, a, a, 1.0) if emission else Color(1, 1, 1, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _torus(inner: float, outer: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = inner
	tm.outer_radius = outer
	tm.rings = 40
	tm.ring_segments = 6
	mi.mesh = tm
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = team_color.lightened(0.15)
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.render_priority = 2
	mi.material_override = rm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func set_coins(pts: PackedVector3Array) -> void:
	coins = pts


func _coin_mask(p: Vector3) -> float:
	var best := INF
	for c in coins:
		var d := (c.x - p.x) * (c.x - p.x) + (c.z - p.z) * (c.z - p.z)
		if d < best:
			best = d
	return 1.0 - smoothstep(0.35, 1.2, sqrt(best))


func set_medium(m: String) -> void:
	medium = m
	camel.get_parent().visible = m == "LAND"
	boat.get_parent().visible = m != "LAND"


func set_active(on: bool) -> void:
	active = on


func set_slot_offset(v: Vector3) -> void:
	slot_offset = v
	slot_scale = 1.0


func set_slot(v: Vector3, scale := 1.0) -> void:
	slot_offset = v
	slot_scale = scale


## After a move that ended in a slot (the path's last point is node point + v): keep the piece where
## it is and call that its slot.
func adopt_slot(v: Vector3, scale := 1.0) -> void:
	_base = _base - v
	_slot = v
	slot_offset = v
	slot_scale = scale


func place(p: Vector3, m: String, yaw := INF) -> void:
	set_medium(m)
	_moving = false
	_speed = 0.0
	if _camel_locomotion != null: _camel_locomotion.reset()
	_base = p
	_slot = slot_offset
	global_position = p + _slot
	if yaw != INF:
		heading = yaw


func cancel() -> void:
	_moving = false
	_speed = 0.0
	if _camel_locomotion != null: _camel_locomotion.reset()


func is_moving() -> bool:
	return _moving


# ------------------------------------------------------------------ timing
func _cumulative(points: PackedVector3Array) -> PackedFloat32Array:
	var cum := PackedFloat32Array([0.0])
	for i in range(1, points.size()):
		cum.append(cum[i - 1] + Vector2(points[i].x - points[i - 1].x, points[i].z - points[i - 1].z).length())
	return cum


func span_durations(kinds: PackedStringArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for k in kinds:
		out.append(cross_seconds if k == "cross" else (switch_seconds if k == "switch" else edge_seconds))
	return out


## Exact seconds a move will take (the board reports this to the AI / GameScreen before playing).
## p: a path from merchant_board_claude_paths.gd {points, media, knots, kinds, hops}.
func plan_seconds(p: Dictionary, start_yaw := INF) -> float:
	var total := 0.0
	for d in span_durations(p.get("kinds", PackedStringArray())):
		total += d
	return total + _pre_turn_seconds(p, start_yaw)


## A turn on the spot before setting off when the road starts well off the current heading (not
## when the move starts with a hop: the piece dips out of sight there anyway).
func _pre_turn_seconds(p: Dictionary, start_yaw: float) -> float:
	var points: PackedVector3Array = p.get("points", PackedVector3Array())
	if points.size() < 2 or (p.get("hops", PackedInt32Array()) as PackedInt32Array).has(0):
		return 0.0
	var yaw := heading if start_yaw == INF else start_yaw
	var d := Vector3.ZERO
	var run := 0.0
	for i in range(1, points.size()):
		run += Vector2(points[i].x - points[i - 1].x, points[i].z - points[i - 1].z).length()
		d = Vector3(points[i].x - points[0].x, 0.0, points[i].z - points[0].z)
		if run >= 1.2:
			break
	if d.length() < 1e-3:
		return 0.0
	var diff := absf(wrapf(atan2(-d.z, d.x) - yaw, -PI, PI))
	return minf(diff / turn_rate, 0.8) if diff > deg_to_rad(50.0) else 0.0


## Plays path p (see plan_seconds) in `seconds`: each span a cubic Hermite s(t) over its own time,
## zero speed at the ends of the move, reduced speed through the knots between (a coin, a city
## stand); hop segments are not travelled: the piece dips out at one end and pops in at the other.
func move_along(p: Dictionary, seconds: float) -> void:
	var points: PackedVector3Array = PackedVector3Array(p.get("points", PackedVector3Array()))
	if points.size() < 2:
		_moving = false
		arrived.emit()
		return
	var media: PackedStringArray = PackedStringArray(p.get("media", PackedStringArray()))
	var hops: PackedInt32Array = PackedInt32Array(p.get("hops", PackedInt32Array()))
	var knots_in: PackedFloat32Array = PackedFloat32Array(p.get("knots", PackedFloat32Array()))
	# a piece standing in a side slot sets off from where it actually stands (no sliding back to the
	# node point first): a hop dips out right there, a walk / sail starts with a short lead-in
	var here := _base + _slot
	var starts_here := Vector2(points[0].x - here.x, points[0].z - here.z).length() < 0.02
	if _slot.length() > 0.02 and starts_here:
		# the board already started the path where the piece stands (its slot)
		_base = here
		_slot = Vector3.ZERO
		slot_offset = Vector3.ZERO
		slot_scale = 1.0
	elif _slot.length() > 0.02:
		if hops.has(0):
			points[0] = here
		else:
			var lead := Vector2(points[0].x - here.x, points[0].z - here.z).length()
			points.insert(0, here)
			media.insert(0, media[0])
			for k in range(1, knots_in.size()):
				knots_in[k] += lead
			for h in hops.size():
				hops[h] += 1
		_base = here
		_slot = Vector3.ZERO
		slot_offset = Vector3.ZERO
		slot_scale = 1.0
	p = p.duplicate()
	p.points = points
	p.media = media
	p.hops = hops
	p.knots = knots_in
	_end_yaw = float(p.get("end_yaw", INF))
	_pts = points
	_media = media
	_hops = hops
	_hop_fx = {}
	_cum = _cumulative(points)
	_L = _cum[_cum.size() - 1]
	_pre = minf(_pre_turn_seconds(p, INF), seconds * 0.3)     # a squeezed (test) duration squeezes the turn too
	_pre_shrink = false
	var knots: PackedFloat32Array = PackedFloat32Array(p.get("knots", PackedFloat32Array()))
	var kinds: PackedStringArray = p.get("kinds", PackedStringArray())
	if knots.size() != kinds.size() + 1 or kinds.is_empty():
		knots = PackedFloat32Array([0.0, _L])
		kinds = PackedStringArray(["edge"])
	knots[0] = 0.0
	knots[knots.size() - 1] = _L
	var durs := span_durations(kinds)
	_s_samples = PackedFloat32Array([0.0])
	_t_of_s = PackedFloat32Array([0.0])
	var n_span := kinds.size()
	var t0 := 0.0
	for k in n_span:
		var s0 := knots[k]
		var s1 := knots[k + 1]
		var T := maxf(durs[k], 0.01)
		var avg := (s1 - s0) / T
		var v0 := 0.0
		var v1 := 0.0
		if k > 0:
			v0 = through_speed * minf(avg, (knots[k] - knots[k - 1]) / maxf(durs[k - 1], 0.01))
		if k < n_span - 1:
			v1 = through_speed * minf(avg, (knots[k + 2] - knots[k + 1]) / maxf(durs[k + 1], 0.01))
		var n := maxi(16, int((s1 - s0) / 0.04))
		# trapezoid: speed up over `ramp` of the span, cruise, slow down over `ramp` (the peak is
		# only ~1.3x the average); spans too short for that use a cubic Hermite
		var rr := ramp
		var vc := ((s1 - s0) / T - rr * (v0 + v1) * 0.5) / (1.0 - rr)
		var trap := vc >= maxf(v0, v1)
		for i in range(1, n + 1):
			var u := float(i) / float(n)
			var sv := 0.0
			if trap:
				var t := u * T
				var ta := rr * T
				if t <= ta:
					sv = s0 + v0 * t + 0.5 * (vc - v0) / ta * t * t
				elif t <= T - ta:
					sv = s0 + ta * (v0 + vc) * 0.5 + vc * (t - ta)
				else:
					var tt := t - (T - ta)
					sv = s0 + ta * (v0 + vc) * 0.5 + vc * (T - 2.0 * ta) + vc * tt + 0.5 * (v1 - vc) / ta * tt * tt
			else:
				var u2 := u * u
				var u3 := u2 * u
				sv = (2.0 * u3 - 3.0 * u2 + 1.0) * s0 + (u3 - 2.0 * u2 + u) * T * v0 + (-2.0 * u3 + 3.0 * u2) * s1 + (u3 - u2) * T * v1
			_s_samples.append(clampf(maxf(sv, _s_samples[_s_samples.size() - 1]), 0.0, s1))
			_t_of_s.append(t0 + u * T)
		t0 += T
	var run := maxf(seconds - _pre, 0.05)
	for i in _t_of_s.size():
		_t_of_s[i] = _t_of_s[i] / maxf(t0, 1e-4) * run
	_T = run
	_elapsed = 0.0
	_last_s = 0.0
	_moving = true
	if _camel_locomotion != null:
		var look := _pts[0]
		for i in range(1, _pts.size()):
			look = _pts[i]
			if _cum[i] >= 1.2: break
		var direction := look - _pts[0]
		_turn_diff = wrapf(atan2(-direction.z, direction.x) - heading, -PI, PI)
		_camel_locomotion.begin(knots, durs, kinds)
	if _hops.has(0):
		return          # the hop does its own splash / dust
	if _media[0] == "LAND":
		puff.global_position = global_position + Vector3(0, -ground_offset + 0.03, 0)
		puff.restart()
	else:
		splash.global_position = Vector3(global_position.x, SEA_Y + 0.01, global_position.z)
		splash.restart()


func _s_at_time(t: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= _T:
		return _L
	var i := clampi(_t_of_s.bsearch(t) - 1, 0, _t_of_s.size() - 2)
	var u := (t - _t_of_s[i]) / maxf(_t_of_s[i + 1] - _t_of_s[i], 1e-6)
	return lerpf(_s_samples[i], _s_samples[i + 1], u)


func _seg(s: float) -> int:
	return clampi(_cum.bsearch(s, false) - 1, 0, _cum.size() - 2)


func _sample(s: float) -> Array:
	s = clampf(s, 0.0, _L)
	var i := _seg(s)
	var t := (s - _cum[i]) / maxf(_cum[i + 1] - _cum[i], 1e-5)
	if _hops.has(i):
		return [_pts[i] if t < 0.5 else _pts[i + 1], _media[i] if t < 0.5 else _media[i + 1]]
	return [_pts[i].lerp(_pts[i + 1], t), _media[i + 1] if t > 0.5 else _media[i]]


## s_to moved back so a window from s_from never reaches across a hop (the two ends of a hop are
## different places).
func _window(s_from: float, s_to: float) -> float:
	for h in _hops:
		var h0 := _cum[h]
		var h1 := _cum[h + 1]
		if s_from <= h0 and s_to > h0:
			s_to = h0
		elif s_from >= h1 and s_to < h1:
			s_to = h1
	return s_to


# ------------------------------------------------------------------ per frame
func _process(dt: float) -> void:
	bob_t += dt
	settle = maxf(0.0, settle - dt)
	pop = maxf(0.0, pop - dt)
	_slot = _slot.lerp(slot_offset, minf(1.0, dt * 4.0))
	hop_vis = 1.0
	spin_shrink = 1.0
	_frame_distance = 0.0
	if _moving:
		_elapsed += dt
		var t := _elapsed - _pre
		var s := _s_at_time(t)
		var ds := s - _last_s
		_frame_distance = ds
		_speed = ds / maxf(dt, 1e-4)
		_last_s = s
		var i := _seg(s)
		var hopping := _hops.has(i)
		var at := _sample(s)
		var p: Vector3 = at[0]
		if hopping:
			_speed = 0.0
			var u := clampf((s - _cum[i]) / maxf(_cum[i + 1] - _cum[i], 1e-5), 0.0, 1.0)
			var state: int = _hop_fx.get(i, 0)
			if u < 0.5:
				hop_vis = 1.0 - smoothstep(0.05, 0.5, u)
				if state < 1:
					_hop_fx[i] = 1
					_burst(_pts[i], _media[i])
			else:
				var w := clampf((u - 0.5) / 0.45, 0.0, 1.0)
				hop_vis = 1.0 + 2.2 * pow(w - 1.0, 3.0) + 1.2 * pow(w - 1.0, 2.0)      # pops in, small overshoot
				if state < 2:
					_hop_fx[i] = 2
					set_medium(String(at[1]))
					var nxt: Vector3 = _sample(minf(_cum[i + 1] + 1.0, _L))[0]
					var out_dir := Vector3(nxt.x - p.x, 0.0, nxt.z - p.z)
					if out_dir.length() > 0.05:
						heading = atan2(-out_dir.z, out_dir.x)
					elif _end_yaw != INF:
						heading = _end_yaw          # a switch: the boat pops in facing out of the harbour
					pitch = 0.0
					_burst(p, String(at[1]))
		else:
			if String(at[1]) != medium:
				set_medium(String(at[1]))
				pop = POP_TIME
				_burst(p, medium)
			# heading from a window around the piece (the traced road zigzags finely; a short
			# look-ahead makes the piece wobble at walking pace), never across a hop
			var reach := maxf(0.35 + 0.5 * (camel_size if medium == "LAND" else boat_size), absf(_speed) * 0.3)
			var ahead: Vector3 = _sample(_window(s, s + reach))[0]
			var behind: Vector3 = _sample(_window(s, s - 0.25))[0]
			var dir := Vector3(ahead.x - behind.x, 0.0, ahead.z - behind.z)
			if dir.length() > 1e-3:
				var want := atan2(-dir.z, dir.x)
				var d := wrapf(want - heading, -PI, PI)
				var rate := maxf(turn_rate, absf(_speed) * 1.4)     # quick pieces turn quicker (no crabbing)
				var step := clampf(d, -rate * dt, rate * dt)
				heading += step
				bank = lerpf(bank, clampf(-step / maxf(dt, 1e-3) * 0.05, -0.25, 0.25), minf(1.0, dt * 4.0))
			if medium == "LAND":
				var back: Vector3 = _sample(_window(s, s - 0.3))[0]
				var fwd: Vector3 = _sample(_window(s, s + 0.3))[0]
				var runv := Vector2(fwd.x - back.x, fwd.z - back.z).length()
				if runv > 0.1:
					pitch = lerpf(pitch, clampf(atan2(fwd.y - back.y, runv), -0.35, 0.35), minf(1.0, dt * 6.0))
			walk_phase += minf(absf(ds) * stride_per_unit / camel_size, max_gait_hz * TAU * dt)
		_base = p
		if _elapsed >= _pre + _T:
			_moving = false
			_speed = 0.0
			hop_vis = 1.0
			_base = _pts[_pts.size() - 1]
			settle = 0.9
			if medium == "LAND":
				puff.global_position = _base + Vector3(0, -ground_offset + 0.03, 0)
				puff.restart()
			arrived.emit()
	else:
		_speed = 0.0
		pitch = lerpf(pitch, 0.0, minf(1.0, dt * 4.0))
		bank = lerpf(bank, 0.0, minf(1.0, dt * 3.0))
	global_position = _base + _slot
	# stepping onto a coin: a wider ramp, followed smoothly (no 5-frame jump at walking pace)
	_on_coin_target = _coin_mask(_base)
	on_coin = lerpf(on_coin, _on_coin_target, 1.0 - exp(-dt * 9.0)) if _moving else _on_coin_target
	_slot_scale = lerpf(_slot_scale, slot_scale, minf(1.0, dt * 5.0))
	_update_fit(dt)
	_pose(dt)


func _update_fit(dt: float) -> void:
	if medium == "LAND" or not fit_fn.is_valid():
		fit = lerpf(fit, 1.0, minf(1.0, dt * 8.0))
		return
	var p := global_position
	var key := Vector4(p.x, p.z, heading, 0.0)
	var want := _fit_key.w
	if absf(key.x - _fit_key.x) + absf(key.y - _fit_key.y) > 0.04 or absf(wrapf(key.z - _fit_key.z, -PI, PI)) > 0.04:
		# here and a little ahead, so the hull is already small when the strait narrows
		var fwd := Vector3(cos(heading), 0.0, -sin(heading))
		want = minf(float(fit_fn.call(p, heading)), float(fit_fn.call(p + fwd * 0.8, heading)) if _moving else 1.0)
		_fit_key = Vector4(p.x, p.z, heading, want)
	fit = lerpf(fit, want, minf(1.0, dt * (10.0 if want < fit else 3.0)))


## dust on land, a splash at sea (hops and medium changes)
func _burst(at: Vector3, m: String) -> void:
	if m == "LAND":
		puff.global_position = at + Vector3(0, -ground_offset + 0.03, 0)
		puff.restart()
	else:
		splash.global_position = Vector3(at.x, SEA_Y + 0.01, at.z)
		splash.restart()


func _pose(_dt: float) -> void:
	var land := medium == "LAND"
	var moving_now := _moving and _speed > 0.05
	_update_skin_animation(moving_now)
	var stride := clampf(_speed / 1.0, 0.0, 1.0) if land else 0.0
	var arrive := sin(settle / 0.9 * PI) if settle > 0.0 else 0.0
	camel_mat.set_shader_parameter("walk_phase", walk_phase)
	camel_mat.set_shader_parameter("stride", stride)
	var glow := (0.55 + 0.45 * sin(bob_t * 3.2)) if active else 0.0
	camel_mat.set_shader_parameter("highlight", glow)
	boat_mat.set_shader_parameter("highlight", glow)
	var yaw_basis := Basis(Vector3.UP, heading)
	var pu := 1.0 - pop / POP_TIME
	var grow := Basis.from_scale(Vector3.ONE * (0.4 + 0.6 * (1.0 + 2.2 * pow(pu - 1.0, 3.0) + 1.2 * pow(pu - 1.0, 2.0))) * maxf(hop_vis, 0.001) * spin_shrink * _slot_scale)
	if land:
		var h := camel.get_parent() as Node3D
		# sway from side to side with the steps (model +X is forward: roll is about X); nose-down
		# settle on arrival
		var sway := sin(walk_phase) * 0.035 * stride if _camel_locomotion == null else 0.0
		if _camel_locomotion != null: arrive = 0.0
		h.basis = Basis(Vector3.RIGHT, COIN_TILT * on_coin * 0.5) * yaw_basis * Basis(Vector3.BACK, pitch - arrive * 0.06) * Basis(Vector3.RIGHT, sway) * grow
		h.position = Vector3(0, lerpf(-ground_offset, COIN_TOP + 0.02, on_coin) + (0.0 if moving_now or _camel_locomotion != null else sin(bob_t * 1.6) * 0.005), 0)
		if _camel_locomotion != null:
			# Cream route capsule top is .065 + .125*.55 above the path.
			h.basis = Basis(Vector3.RIGHT, COIN_TILT * on_coin) * yaw_basis * Basis(Vector3.BACK, pitch) * grow
			h.position.y = lerpf(0.136, 0.215, on_coin)
	else:
		var h := boat.get_parent() as Node3D
		var dip := sin(settle / 0.9 * PI) * 0.07 if settle > 0.0 else 0.0
		var roll := sin(bob_t * 1.3) * 0.05 + bank
		var way := clampf(_speed / 3.0, 0.0, 1.0) if moving_now else 0.0
		var pitch_b := sin(bob_t * 1.7 + 1.0) * 0.035 - dip + way * 0.045     # bow lifts under way
		h.basis = yaw_basis * Basis(Vector3.RIGHT, roll) * Basis(Vector3.BACK, pitch_b) * grow * Basis.from_scale(Vector3.ONE * fit)
		# waterline on the water surface (route points at sea sit at y 0.04)
		var wl := lerpf(SEA_Y - global_position.y, COIN_TOP + 0.02, on_coin)
		h.position = Vector3(0, wl - waterline * boat_size * fit + sin(bob_t * 2.0) * 0.025 - dip * 0.25, 0)
	if _camel_locomotion != null:
		_camel_locomotion.update(_dt, land, _moving, _frame_distance, _speed, _elapsed, _pre, _T, _turn_diff)
	var fwd := Vector3(cos(heading), 0.0, -sin(heading))
	# footfall dust: bursts twice per gait cycle
	dust.emitting = land and moving_now
	dust.amount_ratio = clampf(0.25 + 0.75 * absf(sin(walk_phase)), 0.0, 1.0)
	dust.global_position = global_position + Vector3(0, -ground_offset + 0.02, 0) - fwd * camel_size * 0.2
	spray.emitting = (not land) and moving_now
	spray.amount_ratio = clampf(_speed / 3.0, 0.25, 1.0)
	# local +x = the heading: the spray box spans the bow's width and throws water up and aft
	spray.global_transform = Transform3D(Basis(Vector3.UP, heading), Vector3(global_position.x, SEA_Y + 0.08, global_position.z) + fwd * boat_size * fit * 0.4)
	wake.visible = not land
	wake.global_transform = Transform3D(Basis(Vector3.UP, heading) * Basis.from_scale(Vector3(1.5, 1.0, 1.05) * boat_size * fit), Vector3(global_position.x, 0.012, global_position.z) - fwd * (boat_size * fit * 1.2))
	wake.set_instance_shader_parameter("moving", clampf(_speed / 2.5, 0.0, 1.0) if moving_now else 0.0)
	# team ring: pulsing on the current player, faint on the others
	var gy := lerpf(-ground_offset + 0.06, COIN_TOP + 0.04, on_coin) if land else lerpf(SEA_Y - global_position.y, COIN_TOP + 0.04, on_coin)
	ring.global_position = Vector3(global_position.x, global_position.y + gy, global_position.z)
	var rs := (1.0 + 0.08 * sin(bob_t * 3.2)) if active else 0.9
	var k := camel_size / 0.72 if land else boat_size / 0.85 * fit
	ring.visible = not land
	ring.basis = Basis(Vector3.RIGHT, COIN_TILT * on_coin) * Basis.from_scale(Vector3(rs * k, 0.35, rs * k))
	ring_mat.albedo_color = Color(team_color.lightened(0.2), (0.95 if active else 0.4) * hop_vis)
	ground_ring.visible = land
	if land:
		var dr := 1.1 * rs * k          # ring outer radius ~ 0.5 * k, like the torus
		ground_ring.size = Vector3(dr, 1.0, dr)
		ground_ring.global_position = Vector3(global_position.x, global_position.y + lerpf(-ground_offset, COIN_TOP, on_coin) + 0.2, global_position.z)
		ground_ring.modulate = Color(team_color.lightened(0.2), (0.95 if active else 0.45) * clampf(hop_vis, 0.0, 1.0))
		ground_ring.emission_energy = (0.6 + 0.3 * sin(bob_t * 3.2)) if active else 0.15
	# pin above the piece: bobs gently on the current player's piece
	var top := (1.25 * camel_size if land else 0.95 * boat_size) + (0.18 + 0.08 * sin(bob_t * 3.2) if active else 0.18)
	var base_y := (lerpf(-ground_offset, COIN_TOP, on_coin) if land else lerpf(SEA_Y - global_position.y, COIN_TOP, on_coin))
	pin.position = Vector3(0, base_y + top, 0)
	role_label.position = pin.position
	var pa := 1.0 if active else 0.85
	pin.modulate = Color(1, 1, 1, pa)
	# arrival ripple on water
	ripple.visible = (not land) and settle > 0.0
	if ripple.visible:
		var u := 1.0 - settle / 0.9
		var rr := k * (0.8 + u * 1.2)
		ripple.global_position = Vector3(global_position.x, 0.015, global_position.z)
		ripple.scale = Vector3(rr, 0.2, rr)
		ripple_mat.albedo_color = Color(1, 1, 1, 0.55 * (1.0 - u))

func _load_transport_skins(default_plan: Dictionary) -> void:
	if not default_plan.get("ok",false):return
	_skin_specs=default_plan.specs.duplicate(true)
	var overrides:Dictionary=GameState.content.get("piece_skins",{})
	for transport in _skin_specs:
		var spec:Dictionary=_skin_specs[transport]
		var checked:=CustomMapLocalAssets.read(spec.asset,"actor_model")
		if not checked.ok or checked.id!=spec.asset:continue
		var source:MeshInstance3D=camel if transport=="CAMEL" else boat
		if transport == "CAMEL" and CustomMapPiecePresets.is_legacy_token(str(spec.asset)):
			# Keep the original +X mesh, team shader and visual gait. No hidden substitute.
			source.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(float(spec.yaw))) * Basis.from_scale(Vector3.ONE * float(spec.size)), Vector3(0, -float(spec.pivot), 0)) * source.transform
			continue
		var root:=CustomMapPieceSkins.instantiate(checked,spec,camel_size if transport=="CAMEL" else boat_size)
		# Imported models must honour the same decal exclusion as original player meshes.
		var pieces:Array=[root]
		while not pieces.is_empty():
			var piece:Node=pieces.pop_back();pieces.append_array(piece.get_children())
			if piece is MeshInstance3D:piece.layers=PIECE_LAYER
		var is_default:bool=not overrides.has(transport)
		if CustomMapDefaultTeamMaterials.supports(checked.id):
			var team:=preload("res://scripts/custom_map/custom_map_default_team_materials.gd").apply(root,checked.id,team_color)
			if not team.ok:root.free();continue
		if is_default:
			root.name="DefaultTransportSkin";_default_skins[transport]=root
		else:_custom_skins[transport]=root
		source.get_parent().add_child(root);source.hide()
		if transport == "CAMEL" and checked.id == CustomMapDefaultTeamMaterials.CAMEL_ASSET: _camel_locomotion = CustomMapCamelLocomotion.new(root, camel_size)
		if transport=="SHIP":root.position.y=waterline*boat_size
func _update_skin_animation(moving_now:bool)->void:
	for transport in _custom_skins:
		if transport == "CAMEL" and _camel_locomotion != null: continue
		var root:Node3D=_custom_skins[transport];var shown:bool=(medium=="LAND")== (transport=="CAMEL")
		var spec:Dictionary=_skin_specs[transport]
		CustomMapPieceSkins.play(root,str(spec.move if moving_now else spec.idle) if shown else "")
func _exit_tree()->void:
	if _camel_locomotion != null: _camel_locomotion.stop(); _camel_locomotion = null
	for root in _custom_skins.values():CustomMapPieceSkins.play(root,"")
	_custom_skins.clear()
	_default_skins.clear()
