extends Control
## Players' pieces on Claude's merchant board, walking and sailing scripted routes in a loop — for
## judging the pieces' motion (walk cycle, footfall dust, boat bob / spray / wake / splash, turns,
## slopes, stepping onto coins, switching camel <-> boat at a port) without playing a match.
## Same world, token and path mapping as the playable board (merchant_board_claude_play_board.gd).
##   keys: 1-4 follow a piece   +/- zoom   Space pause   L lighting (noon / dusk / twilight)
##   args: -- [--focus=N] [--zoom=Z] [--slow=0.3] [--shot=<abs png>,<t1>,<t2>...] (debug captures, then quit)

const World := preload("res://tools/merchant_board_claude_play_world.gd")
const Paths := preload("res://tools/merchant_board_claude_paths.gd")
const Token := preload("res://tools/merchant_board_claude_token.gd")
const PITCH := 0.76
const TEAM := [Color8(205, 72, 58), Color8(62, 118, 196), Color8(58, 160, 98), Color8(238, 184, 52)]
# each piece: legs played in order, then the whole loop again backwards.
# a leg is a node path (one medium) or ["switch", city, "LAND"/"SEA"] (change at the port)
const SCRIPT := [
	[["rome", "land_rome_constantinople_01", "land_rome_constantinople_02", "constantinople", "land_constantinople_baghdad_01"]],
	[["rome", "sea_rome_cairo_01", "sea_rome_cairo_02", "cairo", "sea_cairo_jeddah_01"]],
	[["baghdad", "land_baghdad_jeddah_01", "land_baghdad_jeddah_02", "jeddah"], ["switch", "jeddah", "SEA"],
		["jeddah", "sea_jeddah_aden_01", "sea_jeddah_aden_02", "aden"]],
	[["land_constantinople_baghdad_01", "land_constantinople_baghdad_02", "baghdad", "land_baghdad_jeddah_01"]],
]

var world: Node
var paths := Paths.new()
var vp: SubViewport
var tokens: Array = []
var state: Array = []      # per piece: {legs, i, dir, rid, medium, node, wait}
var focus := 0
var zoom := 3.0
var _t := 0.0
var _goal := Vector3.ZERO
var tight := false         # camera locked on the piece (captures)


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.size = Vector2i(1920, 1080)
	add_child(vp)
	var view := TextureRect.new()
	view.texture = vp.get_texture()
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_SCALE
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(view)
	world = World.new()
	add_child(world)
	world.build_into(vp, "noon")
	paths.build(world.layout, 1.8, 1.0)
	var coins := PackedVector3Array(paths.stop_pos.values())
	for i in SCRIPT.size():
		var tok: Node3D = Token.new()
		world.world_root.add_child(tok)
		tok.setup(world, TEAM[i])
		tok.set_coins(coins)
		tok.fit_fn = paths.hull_fit
		tok.set_active(i == 0)
		tok.arrived.connect(_on_arrived.bind(i))
		tokens.append(tok)
		var first: Array = SCRIPT[i][0]
		var start := String(first[0])
		var rid := paths.route_between(start, String(first[1]))
		var m := paths.route_type(rid)
		state.append({"legs": SCRIPT[i], "i": 0, "dir": 1, "rid": rid, "medium": m, "node": start, "wait": 0.6 + 0.4 * i})
		tok.place(paths.node_point(start, rid), m)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--focus="):
			focus = clampi(int(a.trim_prefix("--focus=")), 0, tokens.size() - 1)
		elif a.begins_with("--zoom="):
			zoom = float(a.trim_prefix("--zoom="))
		elif a.begins_with("--shot="):
			tight = true
			call_deferred("_shots", a.trim_prefix("--shot="))
		elif a.begins_with("--slow="):
			Engine.time_scale = float(a.trim_prefix("--slow="))
	for i in tokens.size():
		tokens[i].set_active(i == focus)
	_goal = tokens[focus].global_position


func _leg(st: Dictionary) -> Array:
	var legs: Array = st.legs
	return legs[st.i]


func _start_leg(k: int) -> void:
	var st: Dictionary = state[k]
	var tok: Node3D = tokens[k]
	var leg: Array = _leg(st)
	if String(leg[0]) == "switch":
		var city := String(leg[1])
		var m1 := String(leg[2]) if st.dir > 0 else ("LAND" if String(leg[2]) == "SEA" else "SEA")
		var sw: Dictionary = paths.switch_path(city, st.rid, st.medium, m1)
		st.rid = sw.end_rid
		st.medium = m1
		tok.move_along(sw, tok.plan_seconds(sw))
		return
	var nodes: Array = leg.duplicate()
	if st.dir < 0:
		nodes.reverse()
	var p: Dictionary = paths.move_path(nodes, st.rid, st.medium)
	st.rid = p.end_rid
	st.node = nodes[nodes.size() - 1]
	st.medium = (p.media as PackedStringArray)[(p.media as PackedStringArray).size() - 1]
	tok.move_along(p, tok.plan_seconds(p))


func _on_arrived(k: int) -> void:
	var st: Dictionary = state[k]
	var n: int = (st.legs as Array).size()
	st.i += st.dir
	if st.i >= n or st.i < 0:
		st.dir = -st.dir
		st.i = clampi(st.i, 0, n - 1)
	st.wait = 1.2


func _process(dt: float) -> void:
	if get_tree().paused:
		return
	_t += dt
	for k in state.size():
		var st: Dictionary = state[k]
		if st.wait > 0.0:
			st.wait -= dt
			if st.wait <= 0.0:
				_start_leg(k)
	var pts := PackedVector3Array()
	for t in tokens:
		pts.append((t as Node3D).global_position)
	world.life.avoid_points = pts
	var cam: Camera3D = world.camera
	var p: Vector3 = tokens[focus].global_position
	_goal = _goal.lerp(p + Vector3(0, 0.4, 0), 1.0 if tight else minf(1.0, dt * 6.0))
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 36.0 / zoom
	cam.position = _goal + Vector3(0, sin(PITCH), cos(PITCH)) * 120.0
	cam.look_at(_goal, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var kc := (event as InputEventKey).keycode
		if kc >= KEY_1 and kc <= KEY_4:
			focus = clampi(kc - KEY_1, 0, tokens.size() - 1)
			for i in tokens.size():
				tokens[i].set_active(i == focus)
		elif kc == KEY_EQUAL or kc == KEY_PLUS or kc == KEY_KP_ADD:
			zoom = minf(zoom * 1.25, 8.0)
		elif kc == KEY_MINUS or kc == KEY_KP_SUBTRACT:
			zoom = maxf(zoom / 1.25, 0.8)
		elif kc == KEY_L:
			var order := {"noon": "dusk", "dusk": "twilight", "twilight": "noon"}
			world.apply_lighting(order.get(world.light_name, "noon"))


func _shots(spec: String) -> void:
	var parts := spec.split(",")
	var base := parts[0].trim_suffix(".png")
	var k := 0
	for i in range(1, parts.size()):
		while _t < float(parts[i]):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		vp.get_texture().get_image().save_png("%s_%02d.png" % [base, k])
		var tok: Node3D = tokens[focus]
		print("SHOT %d t=%.2f medium=%s moving=%s on_coin=%.2f heading=%.2f pitch=%.3f" % [k, _t, tok.medium, tok.is_moving(), tok.on_coin, tok.heading, tok.pitch])
		k += 1
	get_tree().quit()
