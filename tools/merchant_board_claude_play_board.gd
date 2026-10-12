extends Control
## Playable board view on Claude's 3D merchant board. Drops into the formal GameScreen in place of
## %BoardView (tools/merchant_board_claude_play.gd swaps the script before the screen enters the
## tree), so the formal rules engine, AI, dice, trade, events and HUD run unchanged; this view only
## presents: the board world, the players' pieces (L叔 on a camel / in a boat, in the player's
## colour), legal-move markers, the planned route, picking, and the camera.
##
## Contract with GameScreen / AITurnController (same as scripts/ui/lowpoly_board_view.gd):
##   signals node_clicked, city_inspect_requested, move_animation_finished (exactly once per
##   play_visual_move / play_transport_switch_visual, including trivial and not-ready cases);
##   estimated_* return exactly what the animation will take.

signal node_clicked(node_id: String)
signal city_inspect_requested(city_id: String)
signal move_animation_finished(player_id: String)

const World := preload("res://tools/merchant_board_claude_play_world.gd")
const DayCycle := preload("res://tools/merchant_board_claude_daycycle.gd")
const Paths := preload("res://tools/merchant_board_claude_paths.gd")
const Token := preload("res://tools/merchant_board_claude_token.gd")
const DefaultPieces := preload("res://scripts/custom_map/custom_map_default_pieces.gd")
const SWITCH_SECONDS := 1.3
const PITCH := 0.76
const DEFAULT_WIDTH := 128.0 * 0.44     # world units across the free map area at zoom 1
const MIN_ZOOM := 0.42                  # zoomed out: the whole board (to jump east <-> west)
const MAX_ZOOM := 1.5
const HIT_RADIUS := 22.0
# token colours: the ruleset colours brightened for the board
const TEAM := {"red": Color8(205, 72, 58), "blue": Color8(62, 118, 196), "green": Color8(58, 160, 98), "yellow": Color8(238, 184, 52)}

var legal_nodes: Dictionary = {}
var selected_path: Array = []
var input_enabled := false
var animating := false
var test_duration_override := -1.0

var world: Node
var paths := Paths.new()
var vp: SubViewport
var view: TextureRect
var tokens := {}        # player id -> token
var default_piece_plan: Dictionary = {}
var shown := {}         # player id -> {node, rid, medium}
var busy := {}
var planned := {}
var _selection := false
var _right_inset := 0.0
## 鼠标停在屏幕边上一小会儿，地图朝那边走（2026-09-26 Carlos：「鼠标拖到边距，可以进行地图方向移动」）。
## 只在鼠标下面就是地图时走（压在面板、按钮上不动）；窗口没焦点、鼠标出了窗口也不动。
var edge_scroll := true
var edge_scroll_needs_focus := true    # 测试里关掉（无窗口时拿不到焦点）
const EDGE_BAND := 0.024               # 边带宽 = 地图高的 2.4%（1080p 约 26 像素）
const EDGE_DWELL_MS := 180             # 在边带里停这么久才开始走，免得只是路过
var _pointer_in := false
var _skip_release_click := false
## 贴边滚动（夜测 CAM-2/4/5/8）：滚到头就停，等鼠标再动才重新启用；拖完松手时鼠标在边带里，要先离开边带；
## 有弹层（换人卡、结算、抽卡、城市图鉴）时 GameScreen 写 edge_scroll_blocked；市集面板那一块（连到屏幕右边）写进 edge_scroll_exclude
var _edge_armed := true
var _edge_need_leave := false
var edge_scroll_blocked := false
var edge_scroll_exclude := Rect2()
## 被界面挡住的上下两条（画布像素，GameScreen 按 L叔 顶栏和底部三组算好推过来）：镜头对准的是「没被挡住的那一块」的正中
## （夜测 CAM-1 / UIRES-6：阿丹、狮子国一开局就压在骰子托盘下面）
var _hud_top := 0.0
var _hud_bottom := 0.0
## 上一组目的地（掷骰后第一次出现时才帮着挪镜头，CAM-6）
var _legal_key := ""
var _edge_since := -1
var _zoom := 1.0
var _target := Vector3(64.0, 0.0, 30.0)
var _goal := Vector3(64.0, 0.0, 30.0)
var _follow := ""
var _drag_from := Vector2.ZERO
var _dragging := false
var _drag_moved := false
var _ready_world := false
var _rendering := true
var _marker_root: Node3D
var _path_mesh: MeshInstance3D
var _hover_mesh: MeshInstance3D   # the hovered destination's route, drawn next to the chosen one
var _current_pid := ""
var _render_scale := 1.0
var _dimmed := false
var slot_idx := {}      # player id -> {key: group key (node, or node|route at a city), idx}
var arrive_slot := {}   # player id -> {off, scale} of the slot its current move ends in
var _audio_move := {}   # player id -> true while its move plays the movement loop
var _switch_secs := -1.0
var zoom_debug_lock := false
## 一局里的一天：清晨 → 正午 → 黄昏 → 暮色，随对局真实时间逐帧渐变（merchant_board_claude_daycycle.gd）
var daycycle
var day_speed := 1.0              # 调试：时间倍速（--day-speed=）
var day_time_override := -1.0     # 调试：固定在某一刻（--daytime=秒）
var _day_hold := ""               # 调试键 L 选中的固定时段（非空时暂停日循环）
var _day_state: Dictionary = {}
var debug_keys := false         # F (focus) / L (lighting): debug sessions only; formal keys are +/-, R/Home    # --zoom= debug close-up: keeps following the current player
## 自制地图（docs/design/map-editor-20260930/DESIGN.md 3.10）：世界只在 _ready 里用原文件建一次；换地图时整体重建
## （rebuild_world_with_layout），只在加载页 ③、开发入口、工坊打开一张图时发生，设置页上不重建。
var initial_layout_override: Dictionary = {}   # 工坊在 _ready 之前设成要打开的那张图的推导结果（默认空 = 原文件）
var world_rebuilds := 0                        # 整体重建的次数（测试 T-R5 用）
var last_rebuild_ms := -1                      # 上一次整体重建的耗时、重建后第一帧的耗时（测试 T-R4a 用）
var last_first_frame_ms := -1
var _map_sig := ""                             # 当前世界的签名；"" = 原布局
var _layout_pinned := false                    # 工坊用 open_layout 打开了一张图：世界由工坊定，不再按 GameState.content 换
var _peeking := false                          # peek_city 期间棋盘不接收按下
var _life_route_pts := {}                      # 工坊就地整理：驼队 / 船队现在沿哪份点列走（路线 id -> points）


func _ready() -> void:
	process_priority = 1
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	view = TextureRect.new()
	view.texture = vp.get_texture()
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_SCALE
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(view)
	world = World.new()
	world.name = "BoardWorld"
	world.layout_override = initial_layout_override
	add_child(world)
	world.build_into(vp, "noon")
	daycycle = DayCycle.new()
	daycycle.setup(world)
	_apply_daylight()
	# the stands, lanes and slot checks use the player boat's hull (Token.boat_size long, ~0.55 of
	# that wide)
	var probe: Node3D = Token.new()
	paths.build(world.layout, float(probe.boat_size), float(probe.boat_size) * 0.55)
	probe.free()
	_marker_root = Node3D.new()
	world.world_root.add_child(_marker_root)
	_path_mesh = MeshInstance3D.new()
	_path_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.world_root.add_child(_path_mesh)
	_hover_mesh = MeshInstance3D.new()
	_hover_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.world_root.add_child(_hover_mesh)
	_ready_world = true
	_build_city_hover()
	# the formal main scene keeps this screen alive behind the title and setup pages: no 3D
	# rendering while it is not shown
	visibility_changed.connect(func(): set_rendering_enabled(is_visible_in_tree()))
	visibility_changed.connect(func():
		if not is_visible_in_tree():
			_reset_touches())
	set_rendering_enabled(is_visible_in_tree())
	resized.connect(_on_resized)
	_on_resized()
	GameState.state_changed.connect(_on_state_changed)
	if not GameState.content.is_empty():
		reload_for_current_game()


# ------------------------------------------------------------------ lifecycle
func reload_for_current_game() -> void:
	# 保险（3.10.1）：设置页阶段永远不重建世界；正常流程里加载页 ③ 已经 prepare_map_world() 过，签名相同，什么都不做
	if GameState.phase != GameState.Phase.SETUP_TRANSPORT:
		_ensure_map_world()
	cancel_all_animations()
	clear_selection()
	_clear_city_hover()
	if _plaque_layer != null:
		_name_plaques()
		_layout_plaques()
	for t in tokens.values():
		# Release actors before a replacement pair is decoded, including same-frame reloads.
		if is_instance_valid(t):
			(t as Node).free()
	tokens.clear()
	default_piece_plan = DefaultPieces.prepare(GameState.content) if not GameState.players.is_empty() else {}
	for pm in _piece_marks.values():
		(pm.pin as Node).queue_free()
		(pm.role as Node).queue_free()
	_piece_marks.clear()
	shown.clear()
	planned.clear()
	slot_idx.clear()
	arrive_slot.clear()
	for p in GameState.players:
		var tok: Node3D = Token.new()
		world.world_root.add_child(tok)
		tok.setup(world, TEAM.get(String(p.color_id), _ruleset_color(String(p.color_id))), default_piece_plan)
		tok.set_coins(PackedVector3Array(paths.stop_pos.values()))
		tok.fit_fn = paths.hull_fit
		tok.set_role(_role_text(p))       # formal map_piece_actor RoleLabel
		tok.arrived.connect(_on_token_arrived.bind(String(p.player_id)))
		tokens[p.player_id] = tok
		var m := _medium(p.active_transport)
		var rid := paths.default_gate_rid(p.current_node_id, m) if paths.is_city(p.current_node_id) else ""
		shown[p.player_id] = {"node": p.current_node_id, "rid": rid, "medium": m}
	_current_pid = String(GameState.current_player().player_id) if not GameState.players.is_empty() else ""
	for pid in tokens:
		(tokens[pid] as Node3D).set_active(pid == _current_pid)
	_snap_all()
	_relayout()
	reset_camera_to_fit()


func _ruleset_color(color_id: String) -> Color:
	for c in GameData.get_player_colors(GameState.content):
		if String(c.get("id", "")) == color_id:
			return Color(String(c.get("color", "#b54d36")))
	return Color8(205, 72, 58)


func _medium(transport: int) -> String:
	return "SEA" if transport == GameData.Transport.SHIP else "LAND"


func _snap(pid: String) -> void:
	if not tokens.has(pid):
		return
	var sh: Dictionary = shown.get(pid, {})
	var node := String(sh.get("node", ""))
	var rid := String(sh.get("rid", ""))
	var tok: Node3D = tokens[pid]
	tok.place(paths.node_point(node, rid), String(sh.get("medium", "LAND")), _yaw_at(node, rid))


func _snap_all() -> void:
	for pid in tokens:
		if not busy.has(pid):
			_snap(pid)


func _yaw_at(node: String, rid: String) -> float:
	# at a city stand: facing out along its route; on a coin: along the route
	return paths.rest_yaw(node, rid)


func is_ready_for_play() -> bool:
	if not _ready_world:
		return false
	for p in GameState.players:
		if not tokens.has(p.player_id):
			return false
	return true


func get_missing_asset_paths() -> Array[String]:
	var out: Array[String] = []
	for pth in [Token.CAMEL_GLB, Token.BOAT_GLB]:
		if not FileAccess.file_exists(pth):
			out.append(pth)
	return out


func _on_state_changed() -> void:
	call_deferred("_sync_now")


func _sync_now() -> void:
	if not _ready_world:
		return
	if GameState.players.is_empty():
		cancel_all_animations()
		return
	var cur = GameState.current_player() if not GameState.players.is_empty() else null
	for p in GameState.players:
		if not tokens.has(p.player_id):
			reload_for_current_game()
			return
		var pid := String(p.player_id)
		var sh: Dictionary = shown.get(pid, {})
		var m := _medium(p.active_transport)
		if not busy.has(pid) and (String(sh.get("node", "")) != String(p.current_node_id) or String(sh.get("medium", "")) != m):
			var rid := paths.default_gate_rid(p.current_node_id, m) if paths.is_city(p.current_node_id) else ""
			shown[pid] = {"node": p.current_node_id, "rid": rid, "medium": m}
			_snap(pid)
	# game over: the board steps back behind the (translucent) formal result panel
	var over := GameState.phase == GameState.Phase.GAME_OVER
	if over != _dimmed:
		_dimmed = over
		create_tween().tween_property(view, "modulate", Color(0.42, 0.42, 0.48) if over else Color.WHITE, 0.6)
	var cid := String(cur.player_id) if cur != null else ""
	for pid in tokens:
		(tokens[pid] as Node3D).set_active(pid == cid)
	if cid != _current_pid and cid != "":
		_current_pid = cid
		if not busy.has(cid):
			_goal = _focus_point((tokens[cid] as Node3D).global_position)
	_relayout()


# ------------------------------------------------------------------ moves
func play_visual_move(visual: Dictionary) -> void:
	var id := String(visual.get("player_id", ""))
	var path: Array = visual.get("path", [])
	if not is_ready_for_play() or not tokens.has(id) or path.size() < 2:
		busy.erase(id)
		animating = not busy.is_empty()
		_snap(id)
		move_animation_finished.emit(id)
		return
	var tok: Node3D = tokens[id]
	if busy.has(id):
		tok.cancel()
		_stop_move_audio(id, false)
	var plan := _plan(id, path, int(visual.get("transport", 0)))
	var m := _medium(int(visual.get("transport", 0)))
	shown[id] = {"node": String(path[path.size() - 1]), "rid": plan.end_rid, "medium": m}
	busy[id] = true
	animating = true
	slot_idx[id] = {"key": plan.slot_key, "idx": plan.slot_idx}
	arrive_slot[id] = plan.slot
	tok.move_along(plan, plan.seconds)
	_follow = id
	# the formal board's move sound: camel / ship loop while moving, a chime on arrival
	AudioManager.start_piece_loop(int(visual.get("transport", GameData.Transport.CAMEL)))
	_audio_move[id] = true


func _group_key(node: String, rid: String) -> String:
	return "%s|%s" % [node, rid] if paths.is_city(node) else node


## lowest slot index of a group not taken by another piece (standing there or on its way)
func _free_slot(key: String, except_pid: String) -> int:
	var used := {}
	for pid in slot_idx:
		if pid != except_pid and String(slot_idx[pid].key) == key:
			used[int(slot_idx[pid].idx)] = true
	var i := 0
	while used.has(i):
		i += 1
	return i


## Adjusts a planned path to the pieces around: it sets off from where the piece really stands (a
## side slot) and ends in the first free slot of its destination (another player may be there).
func _fit_to_slots(id: String, p: Dictionary, end_node: String) -> Dictionary:
	var pts: PackedVector3Array = PackedVector3Array(p.points)
	var media: PackedStringArray = PackedStringArray(p.media)
	var knots: PackedFloat32Array = PackedFloat32Array(p.get("knots", PackedFloat32Array([0.0, 0.0])))
	var hops: PackedInt32Array = PackedInt32Array(p.get("hops", PackedInt32Array()))
	var tok: Node3D = tokens[id]
	if pts.size() >= 2 and (tok.slot_offset as Vector3).length() > 0.02:
		var here: Vector3 = tok.global_position
		if hops.has(0):
			pts[0] = here
			knots[1] = knots[1] + maxf(0.0, Vector2(pts[1].x - here.x, pts[1].z - here.z).length() - (knots[1] - knots[0]))
		else:
			var lead := Vector2(pts[0].x - here.x, pts[0].z - here.z).length()
			pts.insert(0, here)
			media.insert(0, media[0])
			for k in range(1, knots.size()):
				knots[k] += lead
			for h in hops.size():
				hops[h] += 1
	var key := _group_key(end_node, String(p.end_rid))
	var idx := _free_slot(key, id)
	var m := media[media.size() - 1] if not media.is_empty() else "LAND"
	var slot: Dictionary = paths.slot_offsets(end_node, String(p.end_rid), m, idx + 1)[idx]
	var off: Vector3 = slot.off
	if off.length() > 0.02 and not pts.is_empty():
		var last := pts[pts.size() - 1]
		if hops.has(pts.size() - 2):
			pts[pts.size() - 1] = last + off         # a hop pops in straight into the slot
		else:
			pts.append(last + off)
			media.append(m)
			knots[knots.size() - 1] += Vector2(off.x, off.z).length()
	var q := p.duplicate()
	q.points = pts
	q.media = media
	q.knots = knots
	q.hops = hops
	q.slot = slot
	q.slot_key = key
	q.slot_idx = idx
	return q


func _plan(id: String, path: Array, transport: int) -> Dictionary:
	var sh: Dictionary = shown.get(id, {})
	var p: Dictionary = paths.move_path(path, String(sh.get("rid", "")), String(sh.get("medium", _medium(transport))))
	p = _fit_to_slots(id, p, String(path[path.size() - 1]))
	var secs := test_duration_override if test_duration_override > 0.0 else float((tokens[id] as Node3D).plan_seconds(p))
	p.seconds = secs
	planned[id] = {"key": ",".join(PackedStringArray(path)), "seconds": secs}
	return p


func _length(pts: PackedVector3Array) -> float:
	var L := 0.0
	for i in range(1, pts.size()):
		L += Vector2(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z).length()
	return L


func estimated_move_seconds(visual: Dictionary) -> float:
	var path: Array = visual.get("path", [])
	var id := String(visual.get("player_id", ""))
	if path.size() < 2 or not tokens.has(id) or not is_ready_for_play():
		return 0.0
	if test_duration_override > 0.0:
		return test_duration_override
	var c: Dictionary = planned.get(id, {})
	if String(c.get("key", "")) == ",".join(PackedStringArray(path)):
		return float(c.seconds)
	return float(_plan(id, path, int(visual.get("transport", 0))).seconds)


func play_transport_switch_visual(id: String, from_transport: int, to_transport: int) -> void:
	if not is_ready_for_play() or not tokens.has(id):
		move_animation_finished.emit(id)
		return
	var player = null
	for p in GameState.players:
		if p.player_id == id:
			player = p
	if player == null:
		move_animation_finished.emit(id)
		return
	var node := String(player.current_node_id)
	var m0 := _medium(from_transport)
	var m1 := _medium(to_transport)
	var sh: Dictionary = shown.get(id, {})
	var tok: Node3D = tokens[id]
	var sw: Dictionary
	if paths.is_city(node):
		sw = paths.switch_path(node, String(sh.get("rid", "")), m0, m1)
	else:
		var here := paths.node_point(node)
		sw = {"points": PackedVector3Array([here, here + Vector3(0.02, 0, 0)]), "media": PackedStringArray([m0, m1]),
			"knots": PackedFloat32Array([0.0, 0.02]), "kinds": PackedStringArray(["switch"]), "hops": PackedInt32Array([0]), "end_rid": ""}
	sw.end_yaw = paths.rest_yaw(node, String(sw.end_rid)) if paths.is_city(node) else INF
	sw = _fit_to_slots(id, sw, node)
	var pts: PackedVector3Array = sw.points
	var media: PackedStringArray = sw.media
	shown[id] = {"node": node, "rid": sw.end_rid, "medium": m1}
	slot_idx[id] = {"key": sw.slot_key, "idx": sw.slot_idx}
	arrive_slot[id] = sw.slot
	if busy.has(id):
		tok.cancel()
		_stop_move_audio(id, false)
	busy[id] = true
	animating = true
	var secs := test_duration_override if test_duration_override > 0.0 else float(tok.plan_seconds(sw))
	_switch_secs = secs
	tok.move_along(sw, secs)
	_follow = id


func estimated_transport_switch_seconds() -> float:
	# the AI asks right after play_transport_switch_visual(): the switch it just started
	if test_duration_override > 0.0:
		return test_duration_override
	return _switch_secs if _switch_secs > 0.0 else SWITCH_SECONDS


func _on_token_arrived(id: String) -> void:
	if not busy.has(id):
		return
	busy.erase(id)
	animating = not busy.is_empty()
	if _follow == id:
		_follow = ""
	_stop_move_audio(id, true)
	if arrive_slot.has(id):
		var sl: Dictionary = arrive_slot[id]
		(tokens[id] as Node3D).adopt_slot(sl.off, float(sl.scale))
		arrive_slot.erase(id)
	# back in step with the rules (formal _on_piece_move_finished -> _sync_pieces_from_state)
	for p in GameState.players:
		if String(p.player_id) == id:
			var m := _medium(p.active_transport)
			var sh: Dictionary = shown.get(id, {})
			if String(sh.get("node", "")) != String(p.current_node_id) or String(sh.get("medium", "")) != m:
				shown[id] = {"node": p.current_node_id, "rid": paths.default_gate_rid(p.current_node_id, m) if paths.is_city(p.current_node_id) else "", "medium": m}
				(tokens[id] as Node3D).set_slot_offset(Vector3.ZERO)
				_snap(id)
	_relayout()
	move_animation_finished.emit(id)


func _stop_move_audio(id: String, arrival: bool) -> void:
	if _audio_move.has(id):
		_audio_move.erase(id)
		AudioManager.stop_piece_loop(arrival)


func cancel_all_animations() -> void:
	for t in tokens.values():
		(t as Node3D).cancel()
	if not _audio_move.is_empty():
		_audio_move.clear()
		AudioManager.stop_piece_loop(false)
	busy.clear()
	animating = false
	_follow = ""
	for p in GameState.players:
		var pid := String(p.player_id)
		if tokens.has(pid):
			var m := _medium(p.active_transport)
			var sh: Dictionary = shown.get(pid, {})
			if String(sh.get("node", "")) != String(p.current_node_id) or String(sh.get("medium", "")) != m:
				shown[pid] = {"node": p.current_node_id, "rid": paths.default_gate_rid(p.current_node_id, m) if paths.is_city(p.current_node_id) else "", "medium": m}
			_snap(pid)
	arrive_slot.clear()
	_relayout()


func is_animating() -> bool:
	return animating


# pieces sharing a node stand side by side across the road
func _relayout() -> void:
	# pieces sharing a coin (whatever route they came by) or a city stand stand apart (boats bow to
	# stern along their route, camels beside the road: paths.slot_offsets). Slots are stable: a piece
	# keeps its slot while others come and go, a newcomer takes the first free one.
	var groups := {}
	for pid in tokens:
		if busy.has(pid):
			continue
		var sh: Dictionary = shown.get(pid, {})
		var node := String(sh.get("node", ""))
		var key := _group_key(node, String(sh.get("rid", "")))
		if not slot_idx.has(pid) or String(slot_idx[pid].key) != key:
			slot_idx[pid] = {"key": key, "idx": _free_slot(key, pid)}
		if not groups.has(key):
			groups[key] = []
		groups[key].append(pid)
	for key in groups:
		var ids: Array = groups[key]
		var n := 0
		for pid in slot_idx:
			if String(slot_idx[pid].key) == key:
				n = maxi(n, int(slot_idx[pid].idx) + 1)
		var sh0: Dictionary = shown.get(ids[0], {})
		var offs: Array = paths.slot_offsets(String(sh0.get("node", "")), String(sh0.get("rid", "")), String(sh0.get("medium", "LAND")), n)
		for pid in ids:
			var sl: Dictionary = offs[int(slot_idx[pid].idx)]
			(tokens[pid] as Node3D).set_slot(sl.off, float(sl.scale))


# ------------------------------------------------------------------ selection
func set_input_enabled(enabled: bool) -> void:
	var was := input_enabled
	input_enabled = enabled and not animating and is_ready_for_play()
	if was and not input_enabled:
		_clear_marker_hover()
		_clear_city_hover()          # back on the next mouse motion (formal _clear_hover)


func set_selection_mode(enabled: bool) -> void:
	_selection = enabled


func set_legal_nodes(nodes: Dictionary) -> void:
	legal_nodes = nodes.duplicate()
	_update_markers()
	_frame_legal_nodes()


## 掷骰后可去的地点有的在屏幕外、有的压在界面下（夜测 CAM-6）：同一组目的地第一次出现时，若棋子和这些标记
## 有一个不在「没被界面挡住的那一块」里，就按当前缩放滑到能一起看到它们的位置（只平移，不缩放；只对真人）
func _frame_legal_nodes() -> void:
	if legal_nodes.is_empty():
		_legal_key = ""
		return
	var ids := PackedStringArray()
	for id in legal_nodes.keys():
		ids.append(String(id))
	ids.sort()
	var key := _current_pid + "|" + ",".join(ids)
	if key == _legal_key:
		return
	_legal_key = key
	if world == null or world.camera == null or _current_pid == "" or not tokens.has(_current_pid) or zoom_debug_lock:
		return
	if GameState.players.is_empty() or GameState.current_player().is_ai():
		return
	var pts: Array[Vector3] = [(tokens[_current_pid] as Node3D).global_position]
	for id in ids:
		pts.append(_node_anchor(id))
	var safe := _safe_rect().grow(-24.0)
	var all_in := true
	for pt in pts:
		if not safe.has_point(_to_view(pt)):
			all_in = false
			break
	if all_in:
		return
	var lo: Vector3 = pts[0]
	var hi: Vector3 = pts[0]
	for pt in pts:
		lo = lo.min(pt)
		hi = hi.max(pt)
	_follow = ""
	_goal = _clamp_target(_focus_point((lo + hi) * 0.5), world.camera.size)


func set_selected_path(path: Array) -> void:
	selected_path = path.duplicate()
	_update_path()


func clear_selection() -> void:
	legal_nodes.clear()
	selected_path.clear()
	_hover_path = []
	_hover = ""
	_update_markers()
	_update_path()
	_update_tooltip()


## 一人对一个电脑：沿用正式棋盘的「你 / AI」；多位真人或多个电脑同场（2026-09-26 起最多 4 座）时
## 「你 / AI」分不清是谁，改写各自的名字。
func _role_text(p: PlayerState) -> String:
	var humans := 0
	for q in GameState.players:
		if (q as PlayerState).is_local_human():
			humans += 1
	if GameState.players.size() <= 2 and humans == 1:
		return "你" if p.is_local_human() else "AI"
	return p.display_name


func _team_of_current() -> Color:
	if _current_pid != "" and tokens.has(_current_pid):
		return (tokens[_current_pid] as Node3D).team_color
	for p in GameState.players:
		if p.is_local_human():
			return (tokens[p.player_id] as Node3D).team_color if tokens.has(p.player_id) else Color.WHITE
	return Color.WHITE


func _node_anchor(id: String) -> Vector3:
	# where a node's marker sits: the coin, or in front of the city
	if paths.stop_pos.has(id):
		return paths.stop_pos[id]
	var c: Dictionary = paths.city.get(id, {})
	return Vector3(float(c.get("x", 0)), float(c.get("y", 0)) + 0.1, float(c.get("z", 0)))


const PATH_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;
uniform vec3 tint : source_color = vec3(1.0);
uniform float dim = 1.0;         // 1 chosen route, less while only hovering a destination
void fragment() {
	// UV.x = distance along the route (world units), UV.y = across (0..1)
	float across = abs(UV.y * 2.0 - 1.0);
	float edge = 1.0 - smoothstep(0.7, 1.0, across);
	// chevrons marching toward the destination
	float u = UV.x * 1.6 - TIME * 2.2 - across * 0.35;
	float chev = smoothstep(0.35, 0.5, fract(u)) * (1.0 - smoothstep(0.85, 1.0, fract(u)));
	float fade_in = smoothstep(0.0, 0.8, UV.x);
	ALBEDO = mix(tint, vec3(1.0), chev * 0.55);
	ALPHA = edge * fade_in * (0.7 + 0.3 * chev) * dim;
}
"""
var _markers := {}          # node id -> {root, ring, ring_mat, chip, label, coin}
var _hover := ""
var _target_id := ""
var _disc_cache := {}
var _path_shader: Shader


## round badge: fill with a rim
func _disc_texture(fill: Color, rim: Color) -> ImageTexture:
	var key := "%s|%s" % [fill.to_html(), rim.to_html()]
	if _disc_cache.has(key):
		return _disc_cache[key]
	var n := 72
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(n, n) * 0.5
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			if d > 35.0:
				continue
			var a := clampf(35.0 - d, 0.0, 1.0)
			var col := rim if d > 29.0 else fill.lerp(fill.darkened(0.2), clampf((y - 36.0) / 36.0, 0.0, 1.0))
			img.set_pixel(x, y, Color(col, a))
	var tex := ImageTexture.create_from_image(img)
	_disc_cache[key] = tex
	return tex


func _update_markers() -> void:
	if _marker_root == null:
		return
	for ch in _marker_root.get_children():
		ch.queue_free()
	if _mark_layer != null:
		for ch in _mark_layer.get_children():
			if ch.has_meta("badge"):
				ch.queue_free()
	_markers.clear()
	var had_hover := not _hover_path.is_empty()
	_hover = ""
	_hover_path = []
	_hover_is_marker = false
	var col := _team_of_current()
	for id in legal_nodes:
		var sid := String(id)
		var steps := int(legal_nodes[id])
		var coin := paths.stop_pos.has(sid)
		var root := Node3D.new()
		_marker_root.add_child(root)
		root.position = _node_anchor(sid)
		# ring: bright, pulsing, drawn over everything (it is UI); tilted like the coin
		var ring_mat := StandardMaterial3D.new()
		ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ring_mat.no_depth_test = true
		ring_mat.albedo_color = Color(col.lightened(0.3), 0.95)
		ring_mat.render_priority = 3
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		var r := 0.98 if coin else float(paths.city.get(sid, {}).get("foot", 3.0)) * 0.6
		var w := 0.11 if coin else 0.16
		tm.inner_radius = r - w
		tm.outer_radius = r + w
		tm.rings = 56
		tm.ring_segments = 6
		ring.mesh = tm
		ring.material_override = ring_mat
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if coin:
			ring.basis = Basis(Vector3.RIGHT, 0.314) * Basis.from_scale(Vector3(1, 0.25, 1))
			ring.position = Vector3(0, 0.24, 0)
		else:
			ring.basis = Basis.from_scale(Vector3(1, 0.25, 1))
			ring.position = Vector3(0, 0.05, 0)
		root.add_child(ring)
		# step-count badge floating above, always on top, constant size on screen
		var chip := Sprite3D.new()
		chip.texture = _disc_texture(col.darkened(0.05), Color.WHITE)
		chip.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		chip.fixed_size = true
		chip.no_depth_test = true
		chip.pixel_size = 0.0011
		chip.render_priority = 7
		chip.position = Vector3(0, 0.75 if coin else 2.3, 0)
		chip.offset = Vector2(0, 30)
		root.add_child(chip)
		var lab := Label3D.new()
		lab.text = "原地" if steps == 0 else str(steps)
		lab.font_size = 22 if steps == 0 else 40
		lab.outline_size = 0
		lab.modulate = Color.WHITE
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.fixed_size = true
		lab.no_depth_test = true
		lab.pixel_size = 0.0011
		lab.render_priority = 8
		lab.position = chip.position
		lab.offset = Vector2(0, 31)
		root.add_child(lab)
		# the badge people see: 2D, above the city name plaques (a name never hides a step count)
		chip.visible = false
		lab.visible = false
		var disc := TextureRect.new()
		disc.set_meta("badge", sid)
		disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		disc.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		disc.stretch_mode = TextureRect.STRETCH_SCALE
		var num := Label.new()
		num.text = lab.text
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		num.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		disc.add_child(num)
		if _mark_layer != null:
			_mark_layer.add_child(disc)
		_markers[sid] = {"root": root, "ring": ring, "ring_mat": ring_mat, "chip": chip, "label": lab, "coin": coin, "disc": disc, "num": num, "steps": steps}
	_style_markers()
	if had_hover:
		_update_path()
		_update_tooltip()


## hovered: grows; chosen destination: white badge with the number in the team colour
func _style_markers() -> void:
	var col := _team_of_current()
	for sid in _markers:
		var m: Dictionary = _markers[sid]
		var chosen: bool = sid == _target_id
		var hot: bool = sid == _hover
		(m.chip as Sprite3D).texture = _disc_texture(Color.WHITE, col) if chosen else _disc_texture(col.darkened(0.05), Color.WHITE)
		(m.label as Label3D).modulate = col.darkened(0.15) if chosen else Color.WHITE
		var k := 1.25 if (hot or chosen) else 1.0
		(m.chip as Sprite3D).pixel_size = 0.0011 * k
		(m.label as Label3D).pixel_size = 0.0011 * k
		if m.has("disc"):
			(m.disc as TextureRect).texture = (m.chip as Sprite3D).texture
			(m.num as Label).add_theme_color_override("font_color", (m.label as Label3D).modulate)
		(m.ring_mat as StandardMaterial3D).albedo_color = Color(Color.WHITE if chosen else col.lightened(0.3), 0.95)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hover != "" else Control.CURSOR_ARROW


var _mark_layer: Control        # pins, 你/AI labels and step badges: above the name plaques
var _piece_marks := {}          # player id -> {pin: TextureRect, role: Label}


## the pins, 你/AI labels and step badges drawn in 2D over the board, above the city names, each
## where its 3D stand-in would be (same size and place as the fixed-size Sprite3D / Label3D)
func _layout_marks() -> void:
	if _mark_layer == null or world == null:
		return
	var px := float(vp.size.y) * 0.5 / maxf(_render_scale, 0.001)      # canvas px per unit of pixel_size
	for pid in tokens:
		var tok: Node3D = tokens[pid]
		if not _piece_marks.has(pid):
			var pin := TextureRect.new()
			pin.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pin.stretch_mode = TextureRect.STRETCH_SCALE
			pin.texture = tok.pin.texture
			_mark_layer.add_child(pin)
			var role := Label.new()
			role.mouse_filter = Control.MOUSE_FILTER_IGNORE
			role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			role.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			_mark_layer.add_child(role)
			_piece_marks[pid] = {"pin": pin, "role": role}
			tok.pin.visible = false
			tok.role_label.visible = false
		var pm: Dictionary = _piece_marks[pid]
		var pin_r: TextureRect = pm.pin
		var tip := _to_view(tok.pin.global_position)
		var ps: float = tok.pin.pixel_size * px
		var tsz := (tok.pin.texture as Texture2D).get_size() * ps
		pin_r.size = tsz
		pin_r.position = tip - Vector2(tsz.x * 0.5, tsz.y)
		pin_r.modulate = tok.pin.modulate
		pin_r.visible = tok.visible
		var role: Label = pm.role
		var rl: Label3D = tok.role_label
		role.text = rl.text
		role.visible = tok.visible and rl.text != ""
		var fs := int(round(rl.font_size * rl.pixel_size * px))
		role.add_theme_font_size_override("font_size", maxi(fs, 8))
		role.add_theme_color_override("font_color", rl.modulate)
		role.add_theme_color_override("font_outline_color", rl.outline_modulate)
		role.add_theme_constant_override("outline_size", maxi(int(round(rl.outline_size * rl.pixel_size * px)), 1))
		role.size = Vector2(fs * 2.4, fs * 1.4)
		role.position = tip - Vector2(0.0, rl.offset.y * rl.pixel_size * px) - role.size * 0.5
	for sid in _markers:
		var m: Dictionary = _markers[sid]
		if not m.has("disc"):
			continue
		var chip: Sprite3D = m.chip
		var disc: TextureRect = m.disc
		var c := _to_view((m.root as Node3D).global_position + chip.position) - Vector2(0.0, chip.offset.y * chip.pixel_size * px)
		var d := 72.0 * chip.pixel_size * px
		disc.size = Vector2(d, d)
		disc.position = c - disc.size * 0.5
		var lab: Label3D = m.label
		(m.num as Label).add_theme_font_size_override("font_size", maxi(int(round(lab.font_size * lab.pixel_size * px)), 7))


func _animate_markers() -> void:
	var t := Time.get_ticks_msec() / 1000.0
	for sid in _markers:
		var m: Dictionary = _markers[sid]
		var hot: bool = sid == _hover or sid == _target_id
		var pulse := 1.0 + (0.1 if hot else 0.05) * sin(t * 4.0)
		(m.ring as Node3D).scale = Vector3.ONE * pulse * (1.12 if hot else 1.0)


func _update_path() -> void:
	if _path_mesh == null:
		return
	# a one-stop path is 「原地停留」 picked (GameScreen 先选再确认): the piece's own 原地 badge shows as chosen
	_target_id = String(selected_path[selected_path.size() - 1]) if selected_path.size() >= 1 else ""
	_style_markers()
	# the chosen route (bright) and, as on the formal board, the hovered destination's route
	# (dimmer) so alternatives can be compared before confirming
	_path_mesh.mesh = null
	_hover_mesh.mesh = null
	if _current_pid == "":
		return
	if selected_path.size() >= 2:
		_draw_route(_path_mesh, selected_path, 1.0)
	if _hover_path.size() >= 2 and _hover != _target_id:
		_draw_route(_hover_mesh, _hover_path, 0.6)


func _draw_route(target: MeshInstance3D, route: Array, dim: float) -> void:
	var sh: Dictionary = shown.get(_current_pid, {})
	var p: Dictionary = paths.move_path(route, String(sh.get("rid", "")), String(sh.get("medium", "LAND")))
	var pts: PackedVector3Array = p.points
	var hops: PackedInt32Array = p.get("hops", PackedInt32Array())
	if pts.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := 0.3
	var along := 0.0
	for i in range(pts.size() - 1):
		if hops.has(i):
			continue            # through a city: no ribbon across the houses
		var a := pts[i] + Vector3(0, 0.12, 0)
		var b := pts[i + 1] + Vector3(0, 0.12, 0)
		var seg := Vector2(b.x - a.x, b.z - a.z).length()
		if seg < 1e-4:
			continue
		var d := Vector3(b.x - a.x, 0, b.z - a.z) / seg
		var n := Vector3(-d.z, 0, d.x) * w
		var u0 := along
		var u1 := along + seg
		for q in [[a - n, u0, 0.0], [b - n, u1, 0.0], [b + n, u1, 1.0], [a - n, u0, 0.0], [b + n, u1, 1.0], [a + n, u0, 1.0]]:
			st.set_uv(Vector2(q[1], q[2]))
			st.add_vertex(q[0])
		along = u1
	if _path_shader == null:
		_path_shader = Shader.new()
		_path_shader.code = PATH_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _path_shader
	mat.render_priority = 2 if dim >= 1.0 else 1
	mat.set_shader_parameter("tint", _team_of_current().lightened(0.25) if dim >= 1.0 else HOVER_GOLD)
	mat.set_shader_parameter("dim", dim)
	target.mesh = st.commit()
	target.material_override = mat


# ------------------------------------------------------------------ picking and camera input
func _to_view(p: Vector3) -> Vector2:
	var cam: Camera3D = world.camera
	var sp := cam.unproject_position(p)
	return sp / _render_scale


func _pick(pos: Vector2, candidates: Array, radius := HIT_RADIUS) -> String:
	var best := ""
	var bd := INF
	for id in candidates:
		var sid := String(id)
		var p := _node_anchor(sid)
		var sp := _to_view(p)
		var r := radius
		if paths.is_city(sid):
			var edge := _to_view(p + Vector3(float(paths.city[sid].foot) * 0.6, 0, 0))
			r = maxf(HIT_RADIUS, sp.distance_to(edge))
		var d := sp.distance_to(pos)
		if d < r and d < bd:
			bd = d
			best = sid
	return best


func _gui_input(event: InputEvent) -> void:
	if _peeking and ((event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
			or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)):
		accept_event()                     # 镜头正在看一眼新城（peek_city）：这一会儿不接收按下（松开照常收，拖动状态才能结束）
		return
	if touch_gestures and event is InputEventMouseButton and event.device < 0:
		var emb := event as InputEventMouseButton
		if emb.pressed and emb.button_index == MOUSE_BUTTON_LEFT:
			_emu_press_pending = true       # 这根手指模拟出了鼠标（接着到的那条 ScreenTouch 就是它）
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		if touch_gestures:
			_touch_input(event)
			accept_event()
		return
	if _gesture and (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device < 0:
		# 手势里手指模拟出来的鼠标（设备号 -1，比触摸事件先到）：点击、拖动、双击滑镜头一律不算
		accept_event()
		return
	if event is InputEventMouseMotion and event.device >= 0:
		_touch_pointer = false             # 真鼠标又动了：贴边滚动照旧
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, _zoom * 1.1)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, _zoom / 1.1)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.double_click:
			# 双击的那次抬起不再当成一下单击（以前会接着开城市图鉴；复检 NOV-3）
			_skip_release_click = true
			# double-click the map: the camera glides there —— 双击的是可去的地点、或棋子正在走时不滑
			# （不然选中的标记从鼠标下面滑走，第二下点空；夜测 CAM-10）
			var g := _ground_at(mb.position)
			var on_target := _selection and input_enabled and not _legal_target(mb.position).is_empty()
			if g != Vector3.INF and not on_target and busy.is_empty():
				_fling = Vector2.ZERO
				_follow = ""
				_goal = _clamp_target(Vector3(g.x, 0.0, g.z), world.camera.size)
			accept_event()
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			if mb.pressed:
				_stale_release = false
				_dragging = true
				_fling = Vector2.ZERO
				_drag_vel = Vector2.ZERO
				# the middle button pans straight away and never clicks (formal board_view.gd)
				_drag_moved = mb.button_index == MOUSE_BUTTON_MIDDLE
				_drag_from = mb.position
			else:
				_dragging = false
				_edge_need_leave = true      # 松手时鼠标在边带里：先离开边带再贴边滚（不把刚拖的又滚回去，CAM-4）
				if _skip_release_click and mb.button_index == MOUSE_BUTTON_LEFT:
					_skip_release_click = false
				elif _stale_release:
					_stale_release = false     # 地图收起时没抬的那根手指，后来的松开：不算点
				elif mb.canceled and touch_gestures:
					pass                       # 系统取消了这次触摸（安卓 ACTION_CANCEL，比如被系统手势抢走）：不算点，也不甩
				elif not _drag_moved and mb.button_index == MOUSE_BUTTON_LEFT:
					_click(mb.position)
				elif _drag_moved and Time.get_ticks_msec() - _drag_last_ms < 90:
					_fling = _drag_vel          # let go while moving: the map glides on
			accept_event()
	elif event is InputEventMouseMotion and not _dragging:
		_last_pointer = (event as InputEventMouseMotion).position
		_pointer_in = true
		if (event as InputEventMouseMotion).relative.length() > 0.5:
			_edge_armed = true
		_update_pointer()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_last_pointer = mm.position
		if mm.position.distance_to(_drag_from) > 6.0:
			_drag_moved = true
		if _drag_moved:
			_pan_by(mm.relative)
			var now := Time.get_ticks_msec()
			var dt := maxf((now - _drag_last_ms) / 1000.0, 0.004)
			_drag_vel = _drag_vel.lerp(mm.relative / dt, 0.5)
			_drag_last_ms = now
		accept_event()
	elif event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		_zoom_at(mg.position, _zoom * mg.factor, false)
		accept_event()
	elif event is InputEventPanGesture:
		# two-finger pan moves the map with the fingers, like a drag (formal pan_by_screen_delta)
		_pan_by((event as InputEventPanGesture).delta)
		accept_event()


# ------------------------------------------------------------------ touch gestures
## 触屏手势（2026-09-29 Carlos：「地图最好可以双指放大，三指拖移地图位置」；安卓版 / AYN Thor）：
##   两指捏合 = 缩放，以两指中点为锚点（和滚轮一样，钳在 MIN_ZOOM..MAX_ZOOM）；
##   三指及以上 = 按手指重心平移（和单指拖同方向，受同样的棋盘边界和界面安全区约束，都走 _pan_by / _zoom_step）。
## 只认落在地图上的手指（落在界面上的归界面，Viewport 按落点分发）。第二根手指一落下，这一串触摸就是「手势」：
## 第一根手指模拟出来的鼠标（先于触摸事件到）按下、拖动、双击滑镜头一律作废，直到所有手指都抬起，那次抬起不算点；
## 手势里不弹悬停卡、不贴边滚。手指数一变就重取基准，抬手指的先后不会让镜头跳。单指（点选、拖动、双击滑行）照旧。
## 不开 input_devices/pointing/android/enable_pan_and_scale_gestures：它分不出两指和三指，缩放一开始还会取消
## 第一根手指（安卓调研 §3.2）。
## 只在安卓版打开（Carlos 2026-09-29：「这些 bug 仅限于安卓版本」）：桌面版（macOS / Windows，包括 Windows 触屏电脑）
## 一点不变——多指触摸照旧只有第一根手指（模拟鼠标）起作用，系统取消的触摸也照旧处理。
## 手指挪动一帧只算一次（_process 里，用每根手指这一帧最后的位置）：安卓把一次挪动拆成每根手指各一条 ScreenDrag，
## 一条一条算的话，两指一起平移时中间那一刻像是「间距变了」，会越过 PINCH_SLOP 缩放、镜头还会跟着锚点漂。
var touch_gestures := OS.has_feature("android")
const PINCH_SLOP := 10.0            # 两指间距变了这么多（画布像素）才开始缩放：三指抬成两指、手指抖一下都不缩放
var _touches := {}                  # finger index -> position (board canvas units); only fingers that landed on the map
var _gesture := false               # two or more map fingers have been down since all fingers were last up
var _gesture_n := 0                 # the finger count the current baseline was taken with
var _gesture_dirty := false         # map fingers moved since the last gesture step (applied once per frame)
var _pinching := false
var _pinch_d0 := 0.0
var _pinch_z0 := 1.0
var _pan_c0 := Vector2.ZERO
var _touch_pointer := false         # the last pointer input came from a touchscreen: no edge scroll
var _stale_release := false         # touches were reset mid-gesture: the next button release (before any press) is no click
## 不模拟鼠标的那根手指的单点（安卓压力测试 TS-6）：拇指搭在界面上（挎包、按钮）时，第一根手指是它，模拟出来的鼠标
## 归界面；这时另一根手指点地图什么都不算（选不了目的地、开不了图鉴）。这根手指单独在地图上、没挪、很快抬起、没被系统取消，
## 就当一下点击（和模拟鼠标的点击同一个 _click，只是挑选，不会走）。模拟鼠标的那根照旧走鼠标那条路
const LONE_TAP_SLOP := 10.0
const LONE_TAP_MS := 350
var _emu_press_pending := false     # an emulated left press just reached the board (its ScreenTouch comes next)
var _lone_taps := {}                # finger index -> {pos, ms, emulated, moved, gesture}
var _emu_index := -1                # the finger Input turns into the mouse (the first one down while none are down)


## 哪根手指在模拟鼠标：和 Input 同一条规矩（没有手指按着时落下的那根，抬起就没了）。在 _input 里看全部手指
## （落在界面上的也算），地图上的 _gui_input 只看得到落在地图上的；步数牌会先吃掉模拟鼠标的按下，光看地图收到的鼠标不够
func _input(event: InputEvent) -> void:
	if not touch_gestures or not (event is InputEventScreenTouch):
		return
	var st := event as InputEventScreenTouch
	if st.pressed:
		if _emu_index == -1:
			_emu_index = st.index
	elif st.index == _emu_index:
		_emu_index = -1


func _touch_input(event: InputEvent) -> void:
	_touch_pointer = true
	if event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if _touches.has(sd.index):          # (a finger that landed on the HUD is the HUD's)
			_touches[sd.index] = sd.position
			_gesture_dirty = true
		if _lone_taps.has(sd.index) and sd.position.distance_to((_lone_taps[sd.index] as Dictionary).pos) > LONE_TAP_SLOP:
			(_lone_taps[sd.index] as Dictionary).moved = true
		return
	# a finger lands or lifts: first apply what the fingers already down did, with the count they did it with
	_flush_gesture()
	var st := event as InputEventScreenTouch
	var lone_click := false
	if st.pressed:
		_touches[st.index] = st.position
		_lone_taps[st.index] = {"pos": st.position, "ms": Time.get_ticks_msec(), "emulated": _emu_press_pending or st.index == _emu_index, "moved": false, "gesture": _gesture}
		_emu_press_pending = false
	else:
		_touches.erase(st.index)                # a lift or a system cancel (canceled = true)
		var lt: Dictionary = _lone_taps.get(st.index, {})
		_lone_taps.erase(st.index)
		lone_click = (
			not lt.is_empty() and not bool(lt.emulated) and not bool(lt.moved) and not bool(lt.gesture) and not _gesture
			and not st.canceled and Time.get_ticks_msec() - int(lt.ms) <= LONE_TAP_MS
		)
	var n := _touches.size()
	if not _gesture:
		if n >= 2:
			_begin_gesture()
		elif lone_click:
			_click(st.position)
		return
	if n == 0:
		_end_gesture()
	elif n != _gesture_n:
		_gesture_rebase()


## the fingers' moves since the last step, as one step (called from _process, and before a finger lands or lifts)
func _flush_gesture() -> void:
	if not _gesture_dirty:
		return
	_gesture_dirty = false
	if _gesture and _touches.size() == _gesture_n:
		_gesture_step()


func _begin_gesture() -> void:
	_gesture = true
	for k in _lone_taps:
		(_lone_taps[k] as Dictionary).gesture = true     # 手势里的手指抬起时不算点
	# the first finger's emulated press already reached the board: drop its click, drag and fling
	_dragging = false
	_drag_moved = false
	_skip_release_click = true
	_drag_vel = Vector2.ZERO
	_fling = Vector2.ZERO
	if _zoom_tween != null and _zoom_tween.is_valid():
		_zoom_tween.kill()
	# a glide (double-tap, the destinations framing) stops where the camera is now
	_pan_by(Vector2.ZERO)
	_clear_marker_hover()
	_clear_city_hover()
	_gesture_rebase()


func _end_gesture() -> void:
	_gesture = false
	_gesture_n = 0
	_gesture_dirty = false
	_pinching = false
	_dragging = false
	_drag_moved = false
	_skip_release_click = false             # the emulated release came while the gesture was on and was swallowed
	_drag_vel = Vector2.ZERO
	_fling = Vector2.ZERO


func _gesture_rebase() -> void:
	var pts: Array = _touches.values()
	_gesture_n = pts.size()
	_gesture_dirty = false
	_pinching = false
	if pts.size() == 2:
		_pinch_d0 = (pts[0] as Vector2).distance_to(pts[1] as Vector2)
		_pinch_z0 = _zoom
	elif pts.size() >= 3:
		_pan_c0 = _touch_centroid()


func _gesture_step() -> void:
	var pts: Array = _touches.values()
	if pts.size() == 2:
		var a := pts[0] as Vector2
		var b := pts[1] as Vector2
		var d := a.distance_to(b)
		if not _pinching:
			if absf(d - _pinch_d0) < PINCH_SLOP:
				return
			_pinching = true                    # starts from here: crossing the slop does not jump
			_pinch_d0 = d
			_pinch_z0 = _zoom
			return
		var raw := _pinch_z0 * d / maxf(_pinch_d0, 1.0)
		var z := clampf(raw, MIN_ZOOM, MAX_ZOOM)
		if z != raw:
			# 捏过了头：从这里重新算，往回一捏马上就有反应（不用先把多张开 / 多捏拢的那段退回来）
			_pinch_d0 = d
			_pinch_z0 = z
		if absf(z - _zoom) > 0.0001:
			_zoom_step((a + b) * 0.5, z)
	elif pts.size() >= 3:
		var c := _touch_centroid()
		_pan_by(c - _pan_c0)
		_pan_c0 = c


func _touch_centroid() -> Vector2:
	var c := Vector2.ZERO
	for p in _touches.values():
		c += p as Vector2
	return c / maxf(float(_touches.size()), 1.0)


## 地图被收起（开场 / 设置 / 旅人幕盖上来）或应用切到后台：忘掉还按着的手指。那些手指后来的抬起可能被别的界面
## 吃掉，留在这里就会让地图一直以为「手势还没完」，以后单指点什么都不算
func _reset_touches() -> void:
	_touches.clear()
	_lone_taps.clear()
	_emu_press_pending = false
	_emu_index = -1                         # 不确定时当「下一根手指在模拟鼠标」：宁可不算点
	_gesture_dirty = false
	if _gesture:
		_end_gesture()
		_stale_release = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_EXIT_TREE:
		_reset_touches()


func get_touch_debug_state() -> Dictionary:
	return {"touches": _touches.size(), "gesture": _gesture, "pinching": _pinching, "touch_pointer": _touch_pointer,
		"zoom": _zoom, "target": _target, "goal": _goal, "dragging": _dragging, "skip_release_click": _skip_release_click}


## grab the map and move it by a screen delta (board canvas units)
func _pan_by(delta: Vector2) -> void:
	var units_per_px: float = world.camera.size / maxf(size.y, 1.0)
	# 从眼下看到的位置挪（镜头还在滑行时一拖就跳到滑行终点，夜测 CAM-3）
	_goal = _clamp_target(_clamp_target(_target, world.camera.size) + Vector3(-delta.x * units_per_px, 0, -delta.y * units_per_px / sin(PITCH)), world.camera.size)
	_target = _goal
	_follow = ""
	_apply_camera()


var _zoom_tween: Tween
var _fling := Vector2.ZERO          # screen px / s the map keeps gliding at after a drag
var _drag_vel := Vector2.ZERO
var _drag_last_ms := 0


## zoom keeping the ground point under the pointer still (formal _zoom_at_screen; 0.15 s tween)
func _zoom_at(pos: Vector2, z: float, tween := true) -> void:
	z = clampf(z, MIN_ZOOM, MAX_ZOOM)
	if absf(z - _zoom) < 0.0001:
		return
	if _zoom_tween != null and _zoom_tween.is_valid():
		_zoom_tween.kill()
	if not tween:
		_zoom_step(pos, z)
		return
	_zoom_tween = create_tween()
	_zoom_tween.set_ease(Tween.EASE_OUT)
	_zoom_tween.set_trans(Tween.TRANS_QUAD)
	_zoom_tween.tween_method(func(v: float): _zoom_step(pos, v), _zoom, z, 0.15)


func _zoom_step(pos: Vector2, z: float) -> void:
	var before := _ground_at(pos)
	_zoom = z
	_apply_camera()
	var after := _ground_at(pos)
	if before != Vector3.INF and after != Vector3.INF:
		_goal = _clamp_target(_clamp_target(_target, world.camera.size) + (before - after), world.camera.size)
		_target = _goal
		_follow = ""
		_apply_camera()


func _ground_at(pos: Vector2) -> Vector3:
	var cam: Camera3D = world.camera
	var o := cam.project_ray_origin(pos * _render_scale)
	var d := cam.project_ray_normal(pos * _render_scale)
	if absf(d.y) < 1e-4:
		return Vector3.INF
	# the pointer's ground: land plateaus stand ~0.95 above the sea; zooming about the wrong height
	# makes the point under the pointer drift
	var h := 0.04
	for _k in 2:
		var q := o + d * ((h - o.y) / d.y)
		h = 0.95 if paths.water_clearance(q.x, q.z) < 0.0 else 0.04
	return o + d * ((h - o.y) / d.y)


## The step badge of a legal destination under the pointer.
func _pick_badge(pos: Vector2) -> String:
	var best := ""
	var bd := INF
	var k := _badge_px_per_texel()
	for sid in _markers:
		var m: Dictionary = _markers[sid]
		var chip: Sprite3D = m.chip
		var c := _to_view((m.root as Node3D).global_position + chip.position * (m.root as Node3D).scale) - Vector2(0.0, chip.offset.y * k * chip.pixel_size / 0.0011)
		var r := 36.0 * k * chip.pixel_size / 0.0011 + 3.0
		var d := c.distance_to(pos)
		if d < r and d < bd:
			bd = d
			best = String(sid)
	return best


## screen size of one texel of a fixed-size badge at pixel_size 0.0011 (board canvas units)
func _badge_px_per_texel() -> float:
	return 0.0011 * float(vp.size.y) * 0.5 / maxf(_render_scale, 0.001)


## A legal destination under the pointer in move selection (formal _pointer_target_at /
## _update_hover). {id, kind}: "marker" — the step badge, a legal road stop, or the stand where a
## piece would stand at a legal city (tooltip, route preview, no card); "city" — the rest of a legal
## city's building art or plaque (route preview AND its market card, as on the formal board).
func _legal_target(pos: Vector2) -> Dictionary:
	var id := _pick_badge(pos)
	if id == "":
		var stops: Array = legal_nodes.keys().filter(func(n): return not paths.is_city(String(n)))
		id = _pick(pos, stops)
	if id == "":
		for cid in legal_nodes:
			if not paths.is_city(String(cid)):
				continue
			for g in paths.gates.get(String(cid), {}):
				if _to_view(paths.gates[cid][g]).distance_to(pos) < HIT_RADIUS:
					id = String(cid)
	if id != "":
		return {"id": id, "kind": "marker"}
	var c := _city_at(pos)
	if c != "":
		return {"id": c, "kind": "city"} if legal_nodes.has(c) else {}
	var cities: Array = legal_nodes.keys().filter(func(n): return paths.is_city(String(n)))
	id = _pick(pos, cities)             # the rest of a legal city's ground ring, off its art
	return {"id": id, "kind": "marker"} if id != "" else {}


## hover state under the pointer: legal destination (route preview, tooltip), then city (gold glow +
## market card; a legal city's art shows both, as on the formal board)
func _update_pointer() -> void:
	if _last_pointer == Vector2.INF:
		return
	var hv := ""
	var kind := ""
	if _selection and input_enabled and not animating and not legal_nodes.is_empty():
		var t := _legal_target(_last_pointer)
		hv = String(t.get("id", ""))
		kind = String(t.get("kind", ""))
	_hover_is_marker = kind == "marker"
	if hv != _hover:
		_hover = hv
		_hover_path = []
		if hv != "" and hv != _current_node() and not GameState.players.is_empty():
			var player = GameState.current_player()
			_hover_path = MovementSystem.find_path(player, hv, player.movement_budget)
		_style_markers()
		_update_path()
	_update_tooltip()
	_update_city_hover(_last_pointer)


func _update_tooltip() -> void:
	if _tooltip == null:
		return
	# the match went back to the title (GameState.reset_session) while a finger's last point still sits on a destination:
	# a touch never sends the board a mouse exit, and _process keeps refreshing this every frame. No match, no tooltip
	# (was a SCRIPT ERROR 'board_nodes' per frame on the title, Android review 2026-09-30)
	var show := (
		_hover != "" and _hover_is_marker and _hover != _current_node() and _last_pointer != Vector2.INF
		and not GameState.content.is_empty()
	)
	_tooltip.visible = show
	if show:
		_tooltip.text = _hover_label(_hover)
		_tooltip.position = _last_pointer + Vector2(12, 8)


## formal board_view.gd _hover_label
func _hover_label(node_id: String) -> String:
	var steps := int(legal_nodes.get(node_id, maxi(_hover_path.size() - 1, 0)))
	if GameData.is_city_node(GameState.content, node_id):
		var city: Dictionary = GameState.content.get("cities", {}).get(node_id, {})
		return "%s · %d 步" % [String(city.get("display_name", node_id)), steps]
	return "途经节点 · %d 步" % steps


func _click(pos: Vector2) -> void:
	_last_pointer = pos
	_update_pointer()
	if _selection and input_enabled and not animating and not legal_nodes.is_empty():
		var t := _legal_target(pos)
		if not t.is_empty():
			node_clicked.emit(String(t.id))
			return
		# any other road stop: the game screen answers 「该节点不在可达范围内。」 (formal _node_at);
		# a city that is not a legal destination does nothing in selection
		if _city_at(pos) == "":
			var any := _pick(pos, paths.stop_pos.keys(), 16.0)
			if any != "":
				node_clicked.emit(any)
		return
	if not _selection:
		var cid := _city_at(pos)
		if cid != "":
			city_inspect_requested.emit(cid)


## pointer left the board: no hover of any kind stays behind (formal _clear_hover)
func _on_mouse_exited() -> void:
	_pointer_in = false
	_edge_since = -1
	_clear_city_hover()
	_clear_marker_hover()


func _clear_marker_hover() -> void:
	if _hover == "" and _hover_path.is_empty():
		return
	_hover = ""
	_hover_path = []
	_hover_is_marker = false
	_style_markers()
	_update_path()
	_update_tooltip()


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_EQUAL, KEY_KP_ADD:
				_zoom_at(Vector2(size.x - _right_inset, size.y) * 0.5, _zoom * 1.1)
				get_viewport().set_input_as_handled()
			KEY_MINUS, KEY_KP_SUBTRACT:
				_zoom_at(Vector2(size.x - _right_inset, size.y) * 0.5, _zoom / 1.1)
				get_viewport().set_input_as_handled()
			KEY_F:
				if debug_keys:
					focus_current_player()
					get_viewport().set_input_as_handled()
			KEY_R, KEY_HOME:
				reset_camera_to_fit()
				get_viewport().set_input_as_handled()
			KEY_L:
				if debug_keys:
					# 调试：依次固定在 清晨 / 正午 / 黄昏 / 暮色，再按一次回到随对局时间变化
					var order: Array = DayCycle.ORDER
					var i := order.find(_day_hold)
					_day_hold = "" if i == order.size() - 1 else String(order[i + 1])
					_apply_daylight()
					get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ camera
func set_map_safe_right_inset(pixels: float) -> void:
	_right_inset = pixels
	_apply_camera()


func reset_camera_to_fit() -> void:
	if not zoom_debug_lock:
		_zoom = 1.0
	var focus := Vector3(64.0, 0.0, 30.0)
	if not GameState.players.is_empty():
		var p = GameState.current_player() if GameState.is_in_turn() else GameState.players[0]
		if p != null and tokens.has(p.player_id):
			focus = (tokens[p.player_id] as Node3D).global_position
	_goal = _focus_point(focus)
	_target = _goal
	_apply_camera()


func focus_current_player() -> void:
	if _current_pid != "" and tokens.has(_current_pid):
		_goal = _focus_point((tokens[_current_pid] as Node3D).global_position)


func _free_w() -> float:
	return clampf((size.x - _right_inset) / maxf(size.x, 1.0), 0.4, 1.0)


func set_hud_safe_insets(top_px: float, bottom_px: float) -> void:
	_hud_top = maxf(0.0, top_px)
	_hud_bottom = maxf(0.0, bottom_px)


## 没被界面挡住的那一块（画布像素，本控件内坐标）
func _safe_rect() -> Rect2:
	var h := maxf(size.y * 0.3, size.y - _hud_top - _hud_bottom)
	return Rect2(0.0, _hud_top, size.x - _right_inset, h)


func _focus_point(p: Vector3) -> Vector3:
	# 让这一点落在「没被界面挡住的那一块」的正中，而不是整屏正中（夜测 CAM-1）
	if world != null and world.camera != null and size.y > 1.0:
		var up_px := size.y * 0.5 - _safe_rect().get_center().y
		var upp: float = world.camera.size / size.y
		return Vector3(p.x, 0.0, p.z + up_px * upp / sin(PITCH))
	return Vector3(p.x, 0.0, p.z)


func _apply_camera() -> void:
	if world == null or world.camera == null:
		return
	var cam: Camera3D = world.camera
	var aspect := size.x / maxf(size.y, 1.0)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = (DEFAULT_WIDTH / _zoom) / _free_w() / maxf(aspect, 0.1)
	var shift := cam.size * aspect * (1.0 - _free_w()) * 0.5
	var t := _clamp_target(_target, cam.size)
	t.x += shift
	cam.position = t + Vector3(0, sin(PITCH), cos(PITCH)) * 120.0
	cam.look_at(t, Vector3.UP)
	var now_key := "%s|%s" % [cam.global_transform, cam.size]
	if now_key != _cam_key:
		_cam_key = now_key
		_city_rects_frame = -1         # projected city rects are stale
		if _plaque_layer != null:
			_layout_plaques()


# keeps the free map area (left of the HUD panel) on the board: no board edge or sky in view
func _clamp_target(t: Vector3, cam_size: float) -> Vector3:
	if zoom_debug_lock:
		return Vector3(t.x, 0.0, t.z)
	var b: Dictionary = world.layout.board
	var hw := DEFAULT_WIDTH / _zoom * 0.5
	var hd := cam_size * 0.5 / sin(PITCH)
	var x0 := float(b.x0) + hw
	var x1 := float(b.x1) - hw
	var z0 := float(b.z0) + hd - 0.6       # land sits ~1 u above y=0: the far edge reads a little higher
	# 南边可以多走一条底栏的高度：最南边的城（阿丹、狮子国）能挪到骰子托盘上面，多出来的棋盘边缘藏在底栏后面
	var z1 := float(b.z1) - hd - 0.6 + _hud_bottom * cam_size / maxf(size.y, 1.0) / sin(PITCH)
	t.x = clampf(t.x, x0, x1) if x1 > x0 else (float(b.x0) + float(b.x1)) * 0.5
	t.z = clampf(t.z, z0, z1) if z1 > z0 else (float(b.z0) + float(b.z1)) * 0.5
	t.y = 0.0
	return t


func _process(dt: float) -> void:
	_flush_gesture()           # this frame's finger moves, all fingers at once (touch gestures)
	if is_visible_in_tree() and _ready_world:
		_apply_daylight()
	_animate_markers()
	if world != null and world.life != null:
		var pts := PackedVector3Array()
		for t in tokens.values():
			pts.append((t as Node3D).global_position)
		world.life.avoid_points = pts
	if zoom_debug_lock and _follow == "" and _current_pid != "" and tokens.has(_current_pid):
		_goal = _focus_point((tokens[_current_pid] as Node3D).global_position)
	if _follow != "" and tokens.has(_follow):
		# dead zone: only re-aim when the moving piece leaves the middle 60% of the free map area
		var p: Vector3 = (tokens[_follow] as Node3D).global_position
		var sp := _to_view(p)
		var free := _safe_rect()
		var inner := free.grow_individual(-free.size.x * 0.2, -free.size.y * 0.2, -free.size.x * 0.2, -free.size.y * 0.2)
		if not inner.has_point(sp):
			_goal = _focus_point(p)
	if _fling.length() > 20.0:
		_pan_by(_fling * dt)
		_fling *= exp(-dt * 3.5)
	else:
		_fling = Vector2.ZERO
	# arrow keys / WASD pan (the formal keys +/-, R stay as they are)
	if is_visible_in_tree() and get_viewport().gui_get_focus_owner() == null:
		var k := Vector2(float(Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W)))
		if k != Vector2.ZERO:
			_pan_by(-k * size.y * 1.1 * dt)
	_edge_scroll(dt / maxf(Engine.time_scale, 0.0001))
	_target = _target.lerp(_goal, minf(1.0, dt * 2.5))
	_apply_camera()
	if _last_pointer != Vector2.INF:
		_update_pointer()      # after the camera moved: what is under the pointer changes as it glides
	_layout_marks()
	if _city_plaque_runtime != null: _city_plaque_runtime.update()


func _edge_scroll(real_dt: float) -> void:
	var focused := not edge_scroll_needs_focus or get_window().has_focus()
	var ai_turn := not GameState.players.is_empty() and GameState.current_player().is_ai()
	# 电脑回合、棋子在走（镜头要跟着它）、有弹层时不贴边滚（CAM-2/5）；滚到头以后等鼠标再动（CAM-2）
	# 触屏没有悬停：最后一下点在边上不算「鼠标停在边上」，手势里也不滚（真鼠标一动就恢复）
	if (
		not edge_scroll or _dragging or _touch_pointer or _gesture
		or not _pointer_in or _last_pointer == Vector2.INF or not focused or not is_visible_in_tree()
		or edge_scroll_blocked or ai_turn or _follow != "" or not busy.is_empty() or not _edge_armed
	):
		_edge_since = -1
		return
	var band := maxf(8.0, size.y * EDGE_BAND)
	var p := _last_pointer
	var depth := Vector2(
		(band - p.x) / band if p.x < band else ((p.x - (size.x - band)) / band if p.x > size.x - band else 0.0),
		(band - p.y) / band if p.y < band else ((p.y - (size.y - band)) / band if p.y > size.y - band else 0.0))
	var dir := Vector2(
		-1.0 if p.x < band else (1.0 if p.x > size.x - band else 0.0),
		-1.0 if p.y < band else (1.0 if p.y > size.y - band else 0.0))
	if dir == Vector2.ZERO:
		_edge_since = -1
		_edge_need_leave = false
		return
	if _edge_need_leave or edge_scroll_exclude.has_point(p):
		_edge_since = -1
		return
	var now := Time.get_ticks_msec()
	if _edge_since < 0:
		_edge_since = now
	if now - _edge_since < EDGE_DWELL_MS:
		return
	# 刚进边带走得慢，贴到最边上走得快（方向键是每秒 1.1 个屏高）
	var speed := size.y * lerpf(0.45, 1.1, clampf(maxf(depth.x, depth.y), 0.0, 1.0))
	_fling = Vector2.ZERO
	var before := _goal
	_pan_by(-dir.normalized() * speed * real_dt)
	if _goal.is_equal_approx(before):
		_edge_armed = false      # 滚到头了：停下，等鼠标再动


func _on_resized() -> void:
	if vp == null:
		return
	_render_scale = clampf(1920.0 / maxf(size.x, 1.0), 1.0, 2.0)
	vp.size = Vector2i(maxi(64, int(size.x * _render_scale)), maxi(64, int(size.y * _render_scale)))
	_apply_camera()


func set_rendering_enabled(enabled: bool) -> void:
	_rendering = enabled
	if vp != null:
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED


func get_map_debug_state() -> Dictionary:
	var token_px := {}
	for pid in tokens:
		var tok: Node3D = tokens[pid]
		var a := _to_view(tok.global_position)
		var b := _to_view(tok.global_position + Vector3(tok.camel_size if tok.medium == "LAND" else tok.boat_size, 0, 0))
		token_px[pid] = {"px": snappedf(a.distance_to(b), 0.01), "at": a.round(), "node": shown.get(pid, {}).get("node", ""), "medium": tok.medium, "moving": tok.is_moving()}
	var gates := 0
	for c in paths.gates:
		gates += 1 if not (paths.gates[c] as Dictionary).is_empty() else 0
	var cities := {}
	for cid in paths.city:
		var sp := _to_view(_node_anchor(cid))
		cities[cid] = {"screen": sp, "in_safe_view": _in_free_map(sp)}
	var pieces := {}
	for pid in tokens:
		var tk: Node3D = tokens[pid]
		pieces[pid] = {"world_position": tk.global_position, "screen_position": _to_view(tk.global_position), "visible": tk.visible, "node": shown.get(pid, {}).get("node", "")}
	return {"renderer": "merchant_board_claude", "own_world_3d": true, "formal_world_mode": true, "cities": cities, "pieces": pieces,
		"camera": {"zoom_factor": _zoom, "min_zoom": MIN_ZOOM, "max_zoom": MAX_ZOOM}, "viewport_size": vp.size if vp else Vector2i.ZERO,
		"city_visual_count": paths.city.size(), "visual_anchor_count": paths.stop_pos.size() + gates,
		"route_polyline_count": paths.edge_route.size() / 2, "corridor_count": paths.routes.size(),
		"piece_count": tokens.size(), "token_px": token_px, "cam_size": snappedf(world.camera.size, 0.01), "right_inset": _right_inset, "zoom": _zoom, "current": _current_pid, "follow": _follow, "goal": _goal.round(), "target": _target.round(), "busy": busy.keys(),
		"px_per_unit": snappedf(_to_view(Vector3(60, 0, 30)).distance_to(_to_view(Vector3(61, 0, 30))), 0.01), "board_size": size, "missing_assets": get_missing_asset_paths()}


# ------------------------------------------------------------------ city hover: gold glow + trade card
# Same behaviour as the formal board (scripts/ui/board_view.gd): pointing at any city, on any turn,
# makes it glow gold and grow to 1.05x in 0.12 s and pops its market card (the city's face-up trade
# card, or 「此商路未打通」 while its trade route is not open) next to it, preferring above; pointing
# away hides both. Clicking a city still opens the city lore card (city_inspect_requested). During
# move selection a legal marker under the pointer wins: its route is previewed and no card shows.
# The card layout, content and chrome below are ported verbatim from board_view.gd; only the screen
# rect of a city (its projected 3D bounds) and the occluders (3D pieces) are this board's own.
const HOVER_GOLD := Color("ffd978")
const HOVER_SCALE := 1.05
const HOVER_TWEEN := 0.12
const TRADE_BUBBLE_FRAME_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_frame_v1.png")
const TRADE_BUBBLE_ARROW_UP_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_arrow_up_v1.png")
const TRADE_BUBBLE_ARROW_DOWN_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_arrow_down_v1.png")
const TRADE_BUBBLE_ARROW_LEFT_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_arrow_left_v1.png")
const TRADE_BUBBLE_ARROW_RIGHT_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_arrow_right_v1.png")
const TRADE_BUBBLE_BODY_SIZE := Vector2(132, 114)
const TRADE_ARROW_UD_SIZE := Vector2(22, 15)
const TRADE_ARROW_LR_SIZE := Vector2(15, 22)
const TRADE_ARROW_OVERLAP := 3.0
const TRADE_TIP_GAP := 6.0
const TRADE_CORNER_CLEAR := 26.0
const TRADE_DIR_PRIORITY := ["up", "right", "left", "down"]
const SHEEN_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
uniform vec3 gold : source_color = vec3(1.0, 0.58, 0.1);
uniform float strength = 0.0;
void fragment() {
	// a saturated gold rim on the faceted building and a warm gold wash on its sunlit faces
	// (keeps the building's own colours readable), pulsing like the formal hover (0.55 + 0.45 sin 3t)
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	float up = clamp(NORMAL.y, 0.0, 1.0);
	float pulse = 0.55 + 0.45 * sin(TIME * 3.0);
	ALBEDO = gold * (0.1 + 0.55 * f + 0.08 * up) * strength * (0.7 + 0.3 * pulse);
}
"""
const AURA_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform vec3 gold : source_color = vec3(1.0, 0.72, 0.25);
uniform float strength = 0.0;
void fragment() {
	// a soft gold halo on the ground round the city, breathing
	float r = length(UV - vec2(0.5)) * 2.0;
	float pulse = 0.55 + 0.45 * sin(TIME * 3.0);
	float ring = smoothstep(0.35, 0.72, r) * (1.0 - smoothstep(0.72, 1.0, r));
	float fill = (1.0 - smoothstep(0.0, 0.85, r)) * 0.35;
	ALBEDO = gold * (ring * (0.8 + 0.4 * pulse) + fill) * strength;
}
"""

var _tooltip_layer: Control
var _city_trade_card: Control
var _city_trade_card_tween: Tween
var _city_trade_card_city_id := ""
var _city_trade_card_content_signature := ""
var _city_trade_card_direction := ""
var _city_trade_bubble_body: Control
var _city_trade_arrows: Dictionary = {}
var _glow_city := ""
var _last_pointer := Vector2.INF
var _city_boxes := {}          # city id -> AABB of its model in the city's own frame
var _city_pts := {}            # city id -> sample of the model's vertices in the city's own frame
									# (projected, they bound the silhouette; a box's corners overshoot)
var _city_rects := {}          # city id -> projected screen rect (board canvas units), this frame
var _city_rects_frame := -1
var _cam_key := ""
var _city_lamp_mats := {}      # city id -> [[StandardMaterial3D, colour, energy], ...]
var _city_tweens := {}
var _sheen_mat: ShaderMaterial
var _aura: MeshInstance3D
var _aura_mat: ShaderMaterial
var _sparkles: GPUParticles3D
var _hover_path: Array = []
var _hover_is_marker := false
var _tooltip: Label


func _build_city_hover() -> void:
	_tooltip_layer = Control.new()
	_tooltip_layer.name = "TooltipLayer"
	_tooltip_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_tooltip_layer)
	_city_trade_card = _build_city_trade_card()
	_city_trade_card.visible = false
	_tooltip_layer.add_child(_city_trade_card)
	var glow_set := {}
	for g: Array in world.city_glow:
		glow_set[g[0]] = g
	for cid in world.city_nodes:
		_measure_city(cid, glow_set)
	var sh := Shader.new()
	sh.code = SHEEN_SHADER
	_sheen_mat = ShaderMaterial.new()
	_sheen_mat.shader = sh
	_sheen_mat.set_shader_parameter("gold", HOVER_GOLD)
	var ash := Shader.new()
	ash.code = AURA_SHADER
	_aura_mat = ShaderMaterial.new()
	_aura_mat.shader = ash
	_aura = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(1, 1)
	_aura.mesh = pm
	_aura.material_override = _aura_mat
	_aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aura.visible = false
	world.world_root.add_child(_aura)
	_sparkles = GPUParticles3D.new()
	_sparkles.amount = 28
	_sparkles.lifetime = 1.6
	_sparkles.emitting = false
	_sparkles.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 6, 8))
	var spm := ParticleProcessMaterial.new()
	spm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	spm.emission_ring_axis = Vector3.UP
	spm.emission_ring_height = 0.2
	spm.direction = Vector3(0, 1, 0)
	spm.spread = 12.0
	spm.initial_velocity_min = 0.5
	spm.initial_velocity_max = 0.9
	spm.gravity = Vector3(0, 0.1, 0)
	var ag := Gradient.new()
	ag.set_color(0, Color(1.0, 0.86, 0.45, 0.0))
	ag.add_point(0.2, Color(1.0, 0.86, 0.45, 1.0))
	ag.set_color(ag.get_point_count() - 1, Color(1.0, 0.7, 0.3, 0.0))
	var at := GradientTexture1D.new()
	at.gradient = ag
	spm.color_ramp = at
	_sparkles.process_material = spm
	var q := QuadMesh.new()
	q.size = Vector2(0.09, 0.09)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	qm.vertex_color_use_as_albedo = true
	q.material = qm
	_sparkles.draw_pass_1 = q
	_sparkles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.world_root.add_child(_sparkles)
	if not mouse_exited.is_connected(_on_mouse_exited):     # 整体重建世界时会再调一次
		mouse_exited.connect(_on_mouse_exited)
	_tooltip = Label.new()
	_tooltip.name = "Tooltip"
	_tooltip.visible = false
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_theme_font_size_override("font_size", 12)
	_tooltip.add_theme_color_override("font_color", Color("2f2a24"))
	_tooltip.add_theme_color_override("font_outline_color", Color("f2e6c9"))
	_tooltip.add_theme_constant_override("outline_size", 4)
	_tooltip_layer.add_child(_tooltip)
	_build_plaques()


## 一座城的悬停数据：模型在城自己坐标系里的包围盒、投影用的顶点样本、城灯材质（_build_city_hover 里逐城调；
## 工坊轻量刷新时只给新城、换了样子的城重算）
func _measure_city(cid: String, glow_set: Dictionary) -> void:
	var holder: Node3D = world.city_nodes[cid].node
	# 包围盒和顶点样本都在城自己的坐标系里，只由模型决定：整体重建世界时（模型缓存开着）同一个模型直接用上次量的
	var mkey := str((world.city_nodes[cid] as Dictionary).get("model", ""))
	if bool(world.get("use_model_cache")) and _measure_cache.has(mkey):
		var mc: Array = _measure_cache[mkey]
		if mc[0] != null:
			_city_boxes[cid] = mc[0]
		if mc[1] != null:
			_city_pts[cid] = mc[1]
		_city_lamp_mats[cid] = _lamp_mats_of(holder, glow_set)
		return
	var acc := [null]
	for ch in holder.get_children():
		if ch is Node3D:
			world.node_aabb(ch, Transform3D.IDENTITY, acc)     # in the holder's own frame: tight
	if acc[0] != null:
		_city_boxes[cid] = acc[0]
	var inv := holder.global_transform.affine_inverse()
	var verts := PackedVector3Array()
	for mi: MeshInstance3D in world.mesh_instances(holder):
		if mi.mesh == null:
			continue
		var xf := inv * mi.global_transform
		var faces := mi.mesh.get_faces()
		for fi in range(0, faces.size(), 3):
			verts.append(xf * faces[fi])
	if verts.size() > 0:
		# keep ~400: every k-th vertex plus the extremes along each axis
		var k := maxi(1, verts.size() / 400)
		var keep := PackedVector3Array()
		var ext := [0, 0, 0, 0, 0, 0]
		for vi in verts.size():
			var v := verts[vi]
			if vi % k == 0:
				keep.append(v)
			if v.x < verts[ext[0]].x: ext[0] = vi
			if v.x > verts[ext[1]].x: ext[1] = vi
			if v.y < verts[ext[2]].y: ext[2] = vi
			if v.y > verts[ext[3]].y: ext[3] = vi
			if v.z < verts[ext[4]].z: ext[4] = vi
			if v.z > verts[ext[5]].z: ext[5] = vi
		for e in ext:
			keep.append(verts[e])
		_city_pts[cid] = keep
	if mkey != "":
		_measure_cache[mkey] = [_city_boxes.get(cid), _city_pts.get(cid)]
	_city_lamp_mats[cid] = _lamp_mats_of(holder, glow_set)


static var _measure_cache := {}    # 模型路径 -> [包围盒, 顶点样本]（城自己的坐标系）


func _lamp_mats_of(holder: Node3D, glow_set: Dictionary) -> Array:
	var mats: Array = []
	for mi: MeshInstance3D in world.mesh_instances(holder):
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var m: Material = mi.get_surface_override_material(si)
			if m != null and glow_set.has(m):
				mats.append(glow_set[m])
	return mats


## Projected screen rect of a city's model (board canvas units); cached per frame.
func _city_building_screen_rect(city_id: String) -> Rect2:
	if _city_rects_frame != 1:
		_city_rects_frame = 1
		_city_rects.clear()
	if _city_rects.has(city_id):
		return _city_rects[city_id]
	var r := Rect2()
	if _city_boxes.has(city_id) and world != null and world.camera != null:
		var box: AABB = _city_boxes[city_id]
		var xf: Transform3D = (world.city_nodes[city_id].node as Node3D).global_transform
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		var ok := true
		var pts: PackedVector3Array = _city_pts.get(city_id, PackedVector3Array())
		if pts.is_empty():
			for i in 8:
				pts.append(box.get_endpoint(i))
		for p0 in pts:
			var p := xf * p0
			if world.camera.is_position_behind(p):
				ok = false
				break
			var sp := _to_view(p)
			lo = Vector2(minf(lo.x, sp.x), minf(lo.y, sp.y))
			hi = Vector2(maxf(hi.x, sp.x), maxf(hi.y, sp.y))
		if ok:
			r = Rect2(lo, hi - lo)
	_city_rects[city_id] = r
	return r


const CityPlaqueRuntime := preload("res://scripts/ui/merchant_city_plaque_layout.gd")
var _city_plaque_runtime
var city_plaque_candidate := OS.get_environment("SILKROAD_CITY_PLAQUE_BASELINE") != "1"

const CITY_PLAQUE_TEXTURE := preload("res://assets/game/ui/ui_hud_city_plaque_v1.png")
var _plaque_layer: Control
var _plaques := {}             # city id -> CityPlaque Control (formal _attach_city_plaque)


## every city's red name plaque, as on the formal board: always shown, under the city's buildings
func _build_plaques() -> void:
	_plaque_layer = Control.new()
	_plaque_layer.name = "PlaqueLayer"
	_plaque_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plaque_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tooltip_layer.add_child(_plaque_layer)
	_tooltip_layer.move_child(_plaque_layer, 0)          # under the market card and the tooltip
	_mark_layer = Control.new()
	_mark_layer.name = "MarkLayer"
	_mark_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mark_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tooltip_layer.add_child(_mark_layer)
	_tooltip_layer.move_child(_mark_layer, 1)            # above the names, under the card
	if city_plaque_candidate:
		_city_plaque_runtime = CityPlaqueRuntime.new(self)
		for cid in paths.city: _city_plaque_runtime.create_tag(str(cid))
		_name_plaques()
		return
	for cid in paths.city:
		var tag := Control.new()
		tag.name = "CityPlaque"
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var plaque := NinePatchRect.new()
		plaque.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		plaque.texture = CITY_PLAQUE_TEXTURE
		plaque.patch_margin_left = 20
		plaque.patch_margin_right = 20
		plaque.patch_margin_top = 12
		plaque.patch_margin_bottom = 12
		plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.add_child(plaque)
		var label := Label.new()
		label.name = "Name"
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.offset_left = 6.0
		label.offset_right = -6.0
		label.offset_top = 1.0
		label.offset_bottom = -1.0
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		HudStyle.apply_heading(label, HudStyle.PARCHMENT_LIGHT, HudStyle.SIZE_CITY_PLAQUE)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.add_child(label)
		_plaque_layer.add_child(tag)
		_plaques[cid] = tag
	_load_plaque_layout()
	_name_plaques()


## the plaques' text: the ruleset's display names (the layout's names until a game is loaded)
func _name_plaques() -> void:
	if _city_plaque_runtime != null:
		_city_plaque_runtime.update()
		return
	var cities: Dictionary = GameState.content.get("cities", {}) if not GameState.content.is_empty() else {}
	for cid in _plaques:
		var name := String(cities.get(cid, {}).get("display_name", paths.city[cid].get("name", cid)))
		var tag: Control = _plaques[cid]
		(tag.get_node("Name") as Label).text = name
		var w := clampf(56.0 + name.length() * 12.0, 72.0, 124.0)
		tag.size = Vector2(w, 25.0)


const PLAQUE_LAYOUT := "res://assets/merchant_board_claude/plaque_layout.json"
var plaque_anchors := {}       # city id -> world point on the city's buildings (designed layout)
var plaque_offsets := {}       # city id -> plaque centre offset from that point, board canvas px


## The plaques' designed places (tools/merchant_board_claude_plaque_layout.tscn): each city's name
## sits at its own fixed spot beside it — clear of the routes, the stands where pieces wait, the
## coins and the other cities — hung from its buildings, so it only moves with the camera.
func _load_plaque_layout() -> void:
	plaque_anchors.clear()
	plaque_offsets.clear()
	if city_plaque_candidate: return
	if not FileAccess.file_exists(PLAQUE_LAYOUT):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(PLAQUE_LAYOUT))
	if typeof(data) != TYPE_DICTIONARY:
		return
	for cid in (data as Dictionary).get("cities", {}):
		var a: Array = data.cities[cid].anchor
		plaque_anchors[cid] = Vector3(float(a[0]), float(a[1]), float(a[2]))
		var o: Array = data.cities[cid].get("offset_px", [0, 0])
		plaque_offsets[cid] = Vector2(float(o[0]), float(o[1]))


func _layout_plaques() -> void:
	if _city_plaque_runtime != null:
		# Project pins/roles with this camera before using them as plaque obstacles.
		_layout_marks()
		_city_plaque_runtime.update()
		return
	var shift: Dictionary = world.layout.get("plaque_shift", {}) if world != null and world.layout is Dictionary else {}
	for cid in _plaques:
		var tag: Control = _plaques[cid]
		var k := plaque_scale()
		tag.pivot_offset = tag.size * 0.5
		tag.scale = Vector2(k, k)
		if plaque_anchors.has(cid):
			# hung from a point on the city's buildings at a fixed pixel offset: it stays on the
			# city at every zoom and moves only with the camera; zoomed out it shrinks with the map
			var anchor: Vector3 = plaque_anchors[cid]
			if shift.has(cid):
				# 自制地图挪过的原城：名牌锚点跟着城平移（3.10.3 第 9 步）
				anchor += Vector3(float(shift[cid][0]), float(shift[cid][1]), float(shift[cid][2]))
			tag.position = _to_view(anchor) + plaque_offsets.get(cid, Vector2.ZERO) * k - tag.size * 0.5
			tag.visible = true
			continue
		# no designed place: centred under the buildings (formal: 8% into the art)
		var r := _city_building_screen_rect(cid)
		if r.size == Vector2.ZERO:
			tag.visible = false
			continue
		tag.position = Vector2(r.get_center().x - tag.size.x * 0.5, r.end.y - r.size.y * 0.08)
		tag.visible = true             # always shown (the board clips what is off screen), as formal


## name plaques keep their size down to zoom 0.8 and shrink with the map below it (to 0.55 at
## the whole-board view), as the formal board's plaques scale with its map
func plaque_scale() -> float:
	return clampf(_zoom / 0.8, 0.55, 1.0)


func _plaque_screen_rect(city_id: String) -> Rect2:
	if _city_plaque_runtime != null: return _city_plaque_runtime.screen_rect(city_id)
	var tag: Control = _plaques.get(city_id)
	if tag == null or not tag.visible:
		return Rect2()
	var sz := tag.size * tag.scale
	return Rect2(tag.position + tag.size * 0.5 - sz * 0.5, sz)


func _city_at(pos: Vector2) -> String:
	# Match topmost visible draw order and the current rounded body hit box.
	var plaque_ids: Array = _plaques.keys()
	if city_plaque_candidate: plaque_ids.reverse()
	for cid in plaque_ids:
		if _plaque_screen_rect(String(cid)).has_point(pos):
			return String(cid)
	var best := ""
	var best_score := INF
	for cid in paths.city:
		var rect := _city_building_screen_rect(String(cid))
		if rect.size == Vector2.ZERO:
			continue
		if rect.grow(6.0).has_point(pos):
			var score := pos.distance_squared_to(rect.get_center())
			if score < best_score:
				best_score = score
				best = String(cid)
	return best


func _current_node() -> String:
	return String(shown.get(_current_pid, {}).get("node", ""))


func _in_free_map(pos: Vector2) -> bool:
	return pos.x >= 0.0 and pos.y >= 0.0 and pos.x <= size.x - _right_inset and pos.y <= size.y


func _update_city_hover(pos: Vector2) -> void:
	if not _in_free_map(pos):
		_clear_city_hover()
		return
	if _selection and input_enabled and not animating and _hover != "" and _hover_is_marker and _hover != _current_node():
		# a legal marker wins: its route is previewed, the city under it (if it is one) glows
		_hide_city_trade_card()
		_set_city_glow(_hover if paths.is_city(_hover) else "")
		return
	var cid := _city_at(pos)
	_set_city_glow(cid)
	if cid != "":
		_show_city_trade_card(cid)
	else:
		_hide_city_trade_card()


func _clear_city_hover() -> void:
	_last_pointer = Vector2.INF
	_set_city_glow("")
	_hide_city_trade_card()


func _set_city_glow(cid: String) -> void:
	if cid == _glow_city:
		return
	if _glow_city != "":
		_city_glow_on(_glow_city, false)
	_glow_city = cid
	if cid != "":
		_city_glow_on(cid, true)


func _city_glow_on(cid: String, on: bool) -> void:
	if not world.city_nodes.has(cid):
		return
	var holder: Node3D = world.city_nodes[cid].node
	var s: float = world.city_nodes[cid].scale
	if _city_tweens.has(cid) and (_city_tweens[cid] as Tween).is_valid():
		(_city_tweens[cid] as Tween).kill()
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(holder, "scale", Vector3.ONE * s * (HOVER_SCALE if on else 1.0), HOVER_TWEEN).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	_city_tweens[cid] = tw
	# lanterns and windows light up gold (the formal hover frames' lit lanterns)
	_apply_city_lamps(cid, on)
	# a pulsing gold rim over the building, and a warm light over the city
	for mi: MeshInstance3D in world.mesh_instances(holder):
		mi.material_overlay = _sheen_mat if on else null
	if on:
		_sheen_mat.set_shader_parameter("strength", 0.0)
		tw.tween_method(func(v: float): _sheen_mat.set_shader_parameter("strength", v), 0.0, 1.0, HOVER_TWEEN)
		var c: Dictionary = paths.city[cid]
		var foot := float(c.get("foot", 3.5))
		var centre := holder.global_position
		_aura.global_position = Vector3(centre.x, float(c.get("y", 1.0)) + 0.04, centre.z)
		_aura.scale = Vector3.ONE * foot * 1.55
		_aura.visible = true
		_aura_mat.set_shader_parameter("strength", 0.0)
		tw.tween_method(func(v: float): _aura_mat.set_shader_parameter("strength", v), 0.0, 1.0, HOVER_TWEEN)
		(_sparkles.process_material as ParticleProcessMaterial).emission_ring_radius = foot * 0.6
		(_sparkles.process_material as ParticleProcessMaterial).emission_ring_inner_radius = foot * 0.35
		_sparkles.global_position = Vector3(centre.x, float(c.get("y", 1.0)) + 0.2, centre.z)
		_sparkles.emitting = true
	else:
		_aura.visible = false
		_sparkles.emitting = false


## 城灯：白天熄、入夜随 night 渐亮（日循环每帧写）；被悬停的城额外点亮成金色
func _apply_city_lamps(cid: String, on: bool) -> void:
	var night := day_night()
	for g: Array in _city_lamp_mats.get(cid, []):
		var m: StandardMaterial3D = g[0]
		m.emission_enabled = true
		m.emission = g[1]
		m.emission_energy_multiplier = float(g[2]) * (maxf(2.5 * (1.0 - night) + night, night) if on else night)


func day_night() -> float:
	return clampf(float(_day_state.get("night", 0.0)), 0.0, 1.0)


func day_stage() -> String:
	if _day_hold != "":
		return _day_hold
	return DayCycle.stage_name_loop(_day_seconds()) if _day_loops() else DayCycle.stage_name(_day_seconds())


## 日光时钟：一天（20 分钟的四段光）按本局时长伸缩，保证结束前走完一天；不限时就一天接一天循环
func _day_seconds() -> float:
	if day_time_override >= 0.0:
		return day_time_override
	var e := GameState.match_elapsed_sec * day_speed
	var lim := GameState.match_limit_sec
	if lim > 0.0:
		return e * DayCycle.DAY_SEC / lim
	return e


func _day_loops() -> bool:
	return day_time_override < 0.0 and GameState.match_limit_sec <= 0.0


func _apply_daylight() -> void:
	if daycycle == null or world == null:
		return
	if _day_hold != "":
		_day_state = daycycle.presets[_day_hold]
	else:
		_day_state = daycycle.sample_loop(_day_seconds()) if _day_loops() else daycycle.sample(_day_seconds())
	daycycle.apply_fast(world, _day_state)
	if _glow_city != "":
		_apply_city_lamps(_glow_city, true)      # 日循环刚把所有城灯写回 night，悬停城补回金光


## re-apply the hovered city's lanterns after a lighting change (L)
func _refresh_city_glow() -> void:
	if _glow_city != "":
		var cid := _glow_city
		_glow_city = ""
		_set_city_glow(cid)


func _trade_bubble_safe_rect() -> Rect2:
	var margin := 8.0
	var w := maxf(1.0, size.x - _right_inset - margin * 2.0)
	var h := maxf(1.0, size.y - margin * 2.0)
	return Rect2(Vector2(margin, margin), Vector2(w, h))


func _body_hard_occludes(body_rect: Rect2, arrow_rect: Rect2, target_city_id: String) -> bool:
	var target_building := _city_building_screen_rect(target_city_id)
	for city_id in paths.city.keys():
		var cid := String(city_id)
		var building := _city_building_screen_rect(cid)
		if _rect_overlap_area(body_rect, building) > 0.5:
			return true
		if cid != target_city_id and _rect_overlap_area(arrow_rect, building) > 0.5:
			return true
		if _rect_overlap_area(body_rect, _plaque_screen_rect(cid)) > 0.5:
			return true
	for tok in tokens.values():
		if not is_instance_valid(tok):
			continue
		var pp := _to_view((tok as Node3D).global_position)
		var piece_rect := Rect2(pp - Vector2(16, 30), Vector2(32, 40))
		if _rect_overlap_area(body_rect, piece_rect) > 0.5:
			return true
	if _rect_overlap_area(body_rect, target_building) > 0.5:
		return true
	return false


var _layout_key := ""
var _layout_cache: Dictionary = {}


## the bubble layout search is heavy (4 directions x 35 slides x every city and piece): redo it only
## when the city, the camera or a piece moved
func _cached_trade_layout(city_id: String) -> Dictionary:
	var key := "%s|%s" % [city_id, world.camera.global_transform]
	for t in tokens.values():
		key += "|%s" % (t as Node3D).global_position.snapped(Vector3.ONE * 0.05)
	if key != _layout_key or _layout_cache.is_empty():
		_layout_key = key
		_layout_cache = _pick_trade_bubble_layout(city_id)
	return _layout_cache


func get_hover_debug_state() -> Dictionary:
	var sc := 1.0
	if _glow_city != "" and world.city_nodes.has(_glow_city):
		sc = (world.city_nodes[_glow_city].node as Node3D).scale.x / float(world.city_nodes[_glow_city].scale)
	var hn := _hover if _hover != "" else _glow_city
	return {"node_id": hn, "path": _hover_path.duplicate(), "is_city": paths.is_city(hn),
		"glow_city": _glow_city, "marker": _hover, "city_scale": sc, "hover_path": _hover_path.duplicate(),
		"card_city": _city_trade_card_city_id, "card_visible": _city_trade_card != null and _city_trade_card.visible}


func _build_city_trade_card() -> Control:
	var card := Control.new()
	card.name = "CityTradeHoverCard"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	var arrow_layer := Control.new()
	arrow_layer.name = "ArrowLayer"
	arrow_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.add_child(arrow_layer)

	_city_trade_arrows.clear()
	var arrow_defs := [
		["up", "ArrowUp", TRADE_BUBBLE_ARROW_UP_TEXTURE, TRADE_ARROW_UD_SIZE],
		["down", "ArrowDown", TRADE_BUBBLE_ARROW_DOWN_TEXTURE, TRADE_ARROW_UD_SIZE],
		["left", "ArrowLeft", TRADE_BUBBLE_ARROW_LEFT_TEXTURE, TRADE_ARROW_LR_SIZE],
		["right", "ArrowRight", TRADE_BUBBLE_ARROW_RIGHT_TEXTURE, TRADE_ARROW_LR_SIZE],
	]
	for def in arrow_defs:
		var arrow := TextureRect.new()
		arrow.name = String(def[1])
		arrow.texture = def[2]
		arrow.size = def[3]
		arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		arrow.stretch_mode = TextureRect.STRETCH_SCALE
		arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		arrow.visible = false
		arrow_layer.add_child(arrow)
		_city_trade_arrows[String(def[0])] = arrow

	var body := Control.new()
	body.name = "BubbleBody"
	body.size = TRADE_BUBBLE_BODY_SIZE
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(body)
	_city_trade_bubble_body = body

	var frame := TextureRect.new()
	frame.name = "Frame"
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.texture = TRADE_BUBBLE_FRAME_TEXTURE
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(frame)

	var grid := GridContainer.new()
	grid.name = "TradeEntryGrid"
	grid.columns = 2
	grid.position = Vector2(24, 20)
	grid.size = Vector2(84, 74)
	grid.add_theme_constant_override("h_separation", 0)
	grid.add_theme_constant_override("v_separation", 0)
	body.add_child(grid)

	var blocked := Label.new()
	blocked.name = "BlockedRouteLabel"
	blocked.visible = false
	blocked.text = "此商路未打通"
	blocked.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	blocked.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	blocked.position = Vector2(16, 16)
	blocked.size = Vector2(100, 82)
	blocked.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	HudStyle.apply_heading(blocked, HudStyle.CINNABAR_TEXT, HudStyle.SIZE_CARGO_TITLE)
	blocked.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(blocked)

	_apply_trade_bubble_chrome("up")
	return card


func _trade_bubble_root_size(direction: String) -> Vector2:
	match direction:
		"left", "right":
			return Vector2(
				TRADE_BUBBLE_BODY_SIZE.x + TRADE_ARROW_LR_SIZE.x - TRADE_ARROW_OVERLAP,
				TRADE_BUBBLE_BODY_SIZE.y
			)
		_:
			return Vector2(
				TRADE_BUBBLE_BODY_SIZE.x,
				TRADE_BUBBLE_BODY_SIZE.y + TRADE_ARROW_UD_SIZE.y - TRADE_ARROW_OVERLAP
			)


func _arrow_texture_key_for_bubble_dir(direction: String) -> String:
	match direction:
		"up":
			return "down"
		"down":
			return "up"
		"left":
			return "right"
		"right":
			return "left"
		_:
			return "down"


func _apply_trade_bubble_chrome(direction: String, arrow_along: float = 0.5) -> void:
	if _city_trade_card == null or _city_trade_bubble_body == null:
		return
	var root_size := _trade_bubble_root_size(direction)
	_city_trade_card.size = root_size
	_city_trade_card_direction = direction

	for key in _city_trade_arrows:
		(_city_trade_arrows[key] as TextureRect).visible = false

	var arrow_key := _arrow_texture_key_for_bubble_dir(direction)
	var arrow: TextureRect = _city_trade_arrows.get(arrow_key)
	if arrow == null:
		return
	arrow.visible = true

	var body := _city_trade_bubble_body
	body.size = TRADE_BUBBLE_BODY_SIZE
	match direction:
		"up":
			body.position = Vector2.ZERO
			var ax := _clamp_arrow_along(
				TRADE_BUBBLE_BODY_SIZE.x, TRADE_ARROW_UD_SIZE.x, arrow_along
			)
			arrow.position = Vector2(ax, TRADE_BUBBLE_BODY_SIZE.y - TRADE_ARROW_OVERLAP)
			arrow.size = TRADE_ARROW_UD_SIZE
		"down":
			body.position = Vector2(0, TRADE_ARROW_UD_SIZE.y - TRADE_ARROW_OVERLAP)
			var ax2 := _clamp_arrow_along(
				TRADE_BUBBLE_BODY_SIZE.x, TRADE_ARROW_UD_SIZE.x, arrow_along
			)
			arrow.position = Vector2(ax2, 0)
			arrow.size = TRADE_ARROW_UD_SIZE
		"left":
			body.position = Vector2.ZERO
			var ay := _clamp_arrow_along(
				TRADE_BUBBLE_BODY_SIZE.y, TRADE_ARROW_LR_SIZE.y, arrow_along
			)
			arrow.position = Vector2(TRADE_BUBBLE_BODY_SIZE.x - TRADE_ARROW_OVERLAP, ay)
			arrow.size = TRADE_ARROW_LR_SIZE
		"right":
			body.position = Vector2(TRADE_ARROW_LR_SIZE.x - TRADE_ARROW_OVERLAP, 0)
			var ay2 := _clamp_arrow_along(
				TRADE_BUBBLE_BODY_SIZE.y, TRADE_ARROW_LR_SIZE.y, arrow_along
			)
			arrow.position = Vector2(0, ay2)
			arrow.size = TRADE_ARROW_LR_SIZE
		_:
			body.position = Vector2.ZERO
			arrow.position = Vector2(
				(TRADE_BUBBLE_BODY_SIZE.x - TRADE_ARROW_UD_SIZE.x) * 0.5,
				TRADE_BUBBLE_BODY_SIZE.y - TRADE_ARROW_OVERLAP
			)
			arrow.size = TRADE_ARROW_UD_SIZE


func _clamp_arrow_along(edge_len: float, arrow_len: float, along: float) -> float:
	var min_x := TRADE_CORNER_CLEAR
	var max_x := maxf(min_x, edge_len - TRADE_CORNER_CLEAR - arrow_len)
	var ideal := along * edge_len - arrow_len * 0.5
	return clampf(ideal, min_x, max_x)


func _rect_overlap_area(a: Rect2, b: Rect2) -> float:
	if not a.intersects(b):
		return 0.0
	return a.intersection(b).get_area()


func _trade_bubble_arrow_rect(direction: String, root_pos: Vector2, along: float) -> Rect2:
	var tip_local := _trade_bubble_tip_local(direction, along)
	match direction:
		"up":
			var ax := _clamp_arrow_along(TRADE_BUBBLE_BODY_SIZE.x, TRADE_ARROW_UD_SIZE.x, along)
			return Rect2(root_pos + Vector2(ax, TRADE_BUBBLE_BODY_SIZE.y - TRADE_ARROW_OVERLAP), TRADE_ARROW_UD_SIZE)
		"down":
			var ax2 := _clamp_arrow_along(TRADE_BUBBLE_BODY_SIZE.x, TRADE_ARROW_UD_SIZE.x, along)
			return Rect2(root_pos + Vector2(ax2, 0), TRADE_ARROW_UD_SIZE)
		"left":
			var ay := _clamp_arrow_along(TRADE_BUBBLE_BODY_SIZE.y, TRADE_ARROW_LR_SIZE.y, along)
			return Rect2(root_pos + Vector2(TRADE_BUBBLE_BODY_SIZE.x - TRADE_ARROW_OVERLAP, ay), TRADE_ARROW_LR_SIZE)
		"right":
			var ay2 := _clamp_arrow_along(TRADE_BUBBLE_BODY_SIZE.y, TRADE_ARROW_LR_SIZE.y, along)
			return Rect2(root_pos + Vector2(0, ay2), TRADE_ARROW_LR_SIZE)
		_:
			return Rect2(root_pos + tip_local, Vector2.ONE)


func _tip_aligned_to_building(tip: Vector2, building: Rect2, direction: String) -> bool:
	var pad := 6.0
	match direction:
		"up", "down":
			return tip.x >= building.position.x - pad and tip.x <= building.end.x + pad
		"left", "right":
			return tip.y >= building.position.y - pad and tip.y <= building.end.y + pad
		_:
			return false


func _compute_trade_bubble_candidate(city_id: String, direction: String, slide_px: float = 0.0) -> Dictionary:
	var building := _city_building_screen_rect(city_id)
	if building.size == Vector2.ZERO:
		return {}
	var city_screen := building.get_center()
	var root_size := _trade_bubble_root_size(direction)
	var tip := Vector2.ZERO
	var root_pos := Vector2.ZERO
	match direction:
		"up":
			tip = Vector2(city_screen.x, building.position.y - TRADE_TIP_GAP)
			root_pos = Vector2(tip.x - root_size.x * 0.5 + slide_px, tip.y - root_size.y)
		"down":
			tip = Vector2(city_screen.x, building.end.y + TRADE_TIP_GAP)
			root_pos = Vector2(tip.x - root_size.x * 0.5 + slide_px, tip.y)
		"left":
			tip = Vector2(building.position.x - TRADE_TIP_GAP, city_screen.y)
			root_pos = Vector2(tip.x - root_size.x, tip.y - root_size.y * 0.5 + slide_px)
		"right":
			tip = Vector2(building.end.x + TRADE_TIP_GAP, city_screen.y)
			root_pos = Vector2(tip.x, tip.y - root_size.y * 0.5 + slide_px)
		_:
			return {}

	var safe := _trade_bubble_safe_rect()
	# 不钳制次轴：否则会把气泡拖离城市却仍报 tip_gap=6。越界直接非法。
	var root_rect := Rect2(root_pos, root_size)
	var in_safe := (
		root_rect.position.x >= safe.position.x - 0.5
		and root_rect.position.y >= safe.position.y - 0.5
		and root_rect.end.x <= safe.end.x + 0.5
		and root_rect.end.y <= safe.end.y + 0.5
	)
	if not in_safe:
		return _candidate_fail(direction, root_pos, root_size, 2_000_000.0 + absf(slide_px))

	var along := 0.5
	match direction:
		"up", "down":
			along = (city_screen.x - root_pos.x) / maxf(1.0, TRADE_BUBBLE_BODY_SIZE.x)
		"left", "right":
			along = (city_screen.y - root_pos.y) / maxf(1.0, TRADE_BUBBLE_BODY_SIZE.y)

	var tip_after := _trade_bubble_tip_local(direction, along) + root_pos
	var tip_gap := 0.0
	match direction:
		"up":
			tip_gap = building.position.y - tip_after.y
		"down":
			tip_gap = tip_after.y - building.end.y
		"left":
			tip_gap = building.position.x - tip_after.x
		"right":
			tip_gap = tip_after.x - building.end.x

	var body_rect := _trade_bubble_body_rect(direction, root_pos)
	var arrow_rect := _trade_bubble_arrow_rect(direction, root_pos, along)
	var tip_ok := tip_gap >= 4.0 and tip_gap <= 8.5 and _tip_aligned_to_building(tip_after, building, direction)
	var occludes := _body_hard_occludes(body_rect, arrow_rect, city_id)
	var fits := tip_ok and not occludes

	var dist := body_rect.get_center().distance_to(city_screen)
	var priority := TRADE_DIR_PRIORITY.find(direction)
	if priority < 0:
		priority = 99
	# 平移量作为弱成本，优先无心对准。
	var slide_cost := absf(slide_px) * 0.05

	return {
		"direction": direction,
		"position": root_pos,
		"size": root_size,
		"along": along,
		"tip": tip_after,
		"tip_gap": tip_gap,
		"fits": fits,
		"occludes": occludes,
		"dist": dist,
		"priority": priority,
		"slide": slide_px,
		# 3D board: the direction priority decides among fitting layouts (Carlos: 「上方弹出」);
		# formal only breaks ties with it (its plaques already force the side)
		"score": (0.0 if fits else 1_000_000.0) + dist + slide_cost + float(priority) * 1000.0,
	}


func _candidate_fail(direction: String, root_pos: Vector2, root_size: Vector2, score: float) -> Dictionary:
	return {
		"direction": direction,
		"position": root_pos,
		"size": root_size,
		"along": 0.5,
		"tip": Vector2.ZERO,
		"tip_gap": -1.0,
		"fits": false,
		"occludes": true,
		"dist": INF,
		"priority": 99,
		"slide": 0.0,
		"score": score,
	}


func _trade_bubble_body_rect(direction: String, root_pos: Vector2) -> Rect2:
	var offset := Vector2.ZERO
	match direction:
		"down":
			offset = Vector2(0, TRADE_ARROW_UD_SIZE.y - TRADE_ARROW_OVERLAP)
		"right":
			offset = Vector2(TRADE_ARROW_LR_SIZE.x - TRADE_ARROW_OVERLAP, 0)
	return Rect2(root_pos + offset, TRADE_BUBBLE_BODY_SIZE)


func _trade_bubble_tip_local(direction: String, along: float) -> Vector2:
	match direction:
		"up":
			var ax := _clamp_arrow_along(TRADE_BUBBLE_BODY_SIZE.x, TRADE_ARROW_UD_SIZE.x, along)
			return Vector2(ax + TRADE_ARROW_UD_SIZE.x * 0.5, _trade_bubble_root_size(direction).y)
		"down":
			var ax2 := _clamp_arrow_along(TRADE_BUBBLE_BODY_SIZE.x, TRADE_ARROW_UD_SIZE.x, along)
			return Vector2(ax2 + TRADE_ARROW_UD_SIZE.x * 0.5, 0)
		"left":
			var ay := _clamp_arrow_along(TRADE_BUBBLE_BODY_SIZE.y, TRADE_ARROW_LR_SIZE.y, along)
			return Vector2(_trade_bubble_root_size(direction).x, ay + TRADE_ARROW_LR_SIZE.y * 0.5)
		"right":
			var ay2 := _clamp_arrow_along(TRADE_BUBBLE_BODY_SIZE.y, TRADE_ARROW_LR_SIZE.y, along)
			return Vector2(0, ay2 + TRADE_ARROW_LR_SIZE.y * 0.5)
		_:
			return Vector2.ZERO


func _pick_trade_bubble_layout(city_id: String) -> Dictionary:
	var best_fit: Dictionary = {}
	var best_fit_score := INF
	var best_any: Dictionary = {}
	var best_any_score := INF
	var slides: Array = [0.0]
	for step in range(1, 18):
		var px := float(step * 8)
		slides.append(px)
		slides.append(-px)
	for direction in TRADE_DIR_PRIORITY:
		for slide in slides:
			var cand := _compute_trade_bubble_candidate(city_id, direction, float(slide))
			if cand.is_empty():
				continue
			var score := float(cand.get("score", INF))
			if score < best_any_score:
				best_any_score = score
				best_any = cand
			if bool(cand.get("fits", false)) and score < best_fit_score:
				best_fit_score = score
				best_fit = cand
	if not best_fit.is_empty():
		return best_fit
	return best_any if not best_any.is_empty() else _compute_trade_bubble_candidate(city_id, "up", 0.0)


func _show_city_trade_card(city_id: String) -> void:
	if _city_trade_card == null or world == null:
		return
	var city_changed := city_id != _city_trade_card_city_id
	var content_signature := _trade_card_content_signature(city_id)
	var content_changed := city_changed or content_signature != _city_trade_card_content_signature
	var was_visible := _city_trade_card.visible
	if content_changed:
		_rebuild_city_trade_card_content(city_id)
		_city_trade_card_city_id = city_id
		_city_trade_card_content_signature = content_signature

	var layout := _cached_trade_layout(city_id)
	if layout.is_empty():
		return
	var direction := String(layout.get("direction", "up"))
	var along := float(layout.get("along", 0.5))
	var target: Vector2 = layout.get("position", Vector2.ZERO)
	_apply_trade_bubble_chrome(direction, along)

	# 同一城市持续 MouseMotion / 相机平移：禁止 kill/restart tween，也不改动 alpha。
	if was_visible and not city_changed:
		var fading := _city_trade_card_tween != null and _city_trade_card_tween.is_valid() and _city_trade_card_tween.is_running()
		if not fading:
			_city_trade_card.position = target
			_city_trade_card.modulate = Color.WHITE
		return

	# 首次显示或切换城市：安全结束旧 tween 后重启 0.12s 淡入。
	if _city_trade_card_tween != null and _city_trade_card_tween.is_valid():
		_city_trade_card_tween.kill()
		_city_trade_card_tween = null
	_city_trade_card.visible = true
	_city_trade_card.position = target + Vector2(0, 6)
	_city_trade_card.modulate = Color(1, 1, 1, 0)
	_city_trade_card_tween = create_tween()
	_city_trade_card_tween.set_parallel(true)
	_city_trade_card_tween.tween_property(_city_trade_card, "position", target, 0.12)
	_city_trade_card_tween.tween_property(_city_trade_card, "modulate:a", 1.0, 0.12)
	_city_trade_card_tween.chain().tween_callback(func():
		if is_instance_valid(_city_trade_card):
			_city_trade_card.modulate = Color.WHITE
	)


func refresh_visible_trade_card() -> void:
	## 比例交易会立即覆盖城市牌；鼠标不动时也必须刷新当前可见气泡。
	if _city_trade_card != null and _city_trade_card.visible and not _city_trade_card_city_id.is_empty():
		_show_city_trade_card(_city_trade_card_city_id)


func _trade_card_content_signature(city_id: String) -> String:
	var market: Dictionary = GameState.city_market_states.get(city_id, {})
	return "%s|open:%s|card:%s" % [
		city_id,
		str(bool(market.get("trade_route_open", false))),
		String(market.get("current_trade_card_id", "")),
	]


func _rebuild_city_trade_card_content(city_id: String) -> void:
	var grid := _city_trade_card.find_child("TradeEntryGrid", true, false) as GridContainer
	var blocked := _city_trade_card.find_child("BlockedRouteLabel", true, false) as Label
	if grid == null:
		return
	for child in grid.get_children():
		child.queue_free()
	var market: Dictionary = GameState.city_market_states.get(city_id, {})
	var route_open := bool(market.get("trade_route_open", false))
	var card_id := String(market.get("current_trade_card_id", ""))
	if not route_open:
		grid.visible = false
		if blocked:
			blocked.visible = true
			blocked.text = "此商路未打通"
		return
	var card := TradeSystem.get_trade_card_for_city(city_id)
	var entries: Array = card.get("entries", [])
	if card_id.is_empty() or entries.is_empty():
		grid.visible = true
		if blocked:
			blocked.visible = false
		var empty := Label.new()
		empty.text = "暂无\n市集牌"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.custom_minimum_size = Vector2(84, 74)
		HudStyle.apply_caption(empty, HudStyle.CINNABAR_TEXT, 12)
		grid.add_child(empty)
		return
	grid.visible = true
	if blocked:
		blocked.visible = false
	for entry in entries.slice(0, 4):
		grid.add_child(_make_city_trade_entry(entry))


func _make_city_trade_entry(entry: Dictionary) -> Control:
	var tile := Control.new()
	tile.custom_minimum_size = Vector2(42, 37)
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.position = Vector2(6, 2)
	icon.size = Vector2(28, 26)
	# 和市集面板同一套 L叔 图标（scripts/lshu_ui/lshu_icons.gd）
	icon.texture = preload("res://scripts/lshu_ui/lshu_icons.gd").entry(entry)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(icon)
	var quantity := Label.new()
	quantity.name = "EntryQuantity"
	quantity.text = "×%d" % int(entry.get("quantity", 0))
	quantity.position = Vector2(22, 22)
	quantity.size = Vector2(18, 14)
	quantity.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# 羊皮纸底上用朱砂色，避免浅字不可读。
	HudStyle.apply_caption(quantity, HudStyle.CINNABAR_TEXT, 9)
	quantity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(quantity)
	return tile


func get_trade_bubble_debug_state() -> Dictionary:
	if _city_trade_card == null:
		return {}
	var layout := {}
	if not _city_trade_card_city_id.is_empty():
		layout = _pick_trade_bubble_layout(_city_trade_card_city_id)
	var overlaps := {}
	if not _city_trade_card_city_id.is_empty() and _city_trade_card.visible:
		var body := _trade_bubble_body_rect(
			_city_trade_card_direction,
			_city_trade_card.position
		)
		for cid in paths.city.keys():
			overlaps[String(cid)] = _rect_overlap_area(body, _city_building_screen_rect(String(cid)))
	return {
		"city_id": _city_trade_card_city_id,
		"direction": _city_trade_card_direction,
		"visible": _city_trade_card.visible,
		"position": _city_trade_card.position,
		"size": _city_trade_card.size,
		"modulate": _city_trade_card.modulate,
		"layout": layout,
		"arrow_key": _arrow_texture_key_for_bubble_dir(_city_trade_card_direction),
		"overlaps": overlaps,
		"visible_building": _city_building_screen_rect(_city_trade_card_city_id) if not _city_trade_card_city_id.is_empty() else Rect2(),
	}


func _hide_city_trade_card() -> void:
	if _city_trade_card == null or not _city_trade_card.visible:
		return
	if _city_trade_card_tween != null and _city_trade_card_tween.is_valid():
		_city_trade_card_tween.kill()
		_city_trade_card_tween = null
	_city_trade_card.visible = false
	_city_trade_card.modulate = Color.WHITE
	_city_trade_card_city_id = ""
	_city_trade_card_content_signature = ""
	_city_trade_card_direction = ""


# ------------------------------------------------------------------ 自制地图：整体重建、轻量刷新、地面就地整理、看一眼新城
# docs/design/map-editor-20260930/DESIGN.md 3.10、3.12.7。没有地图时这里的函数都不会被调到（签名 "" == ""）。

## 「每个世界一份」的成员：整体重建时复位到声明时的初值（paths 因此换成新的 Paths 对象；旧世界的 Paths 只追加、从不清空，
## 复用它会留下幽灵路、幽灵硬币、幽灵城，3.10.2）。测试 T-R3 扫描全部顶层 var，每一个都必须在这两张表之一里。
const WORLD_STATE_VARS: Array[String] = [
	"legal_nodes", "selected_path", "animating", "world", "paths", "vp", "view", "tokens", "shown", "busy", "planned",
	"_legal_key", "_follow", "_ready_world", "_marker_root", "_path_mesh", "_hover_mesh", "_current_pid", "_dimmed",
	"slot_idx", "arrive_slot", "_audio_move", "_switch_secs", "daycycle", "_day_state", "_life_route_pts", "default_piece_plan",
	"_markers", "_hover", "_target_id", "_mark_layer", "_piece_marks",
	"_tooltip_layer", "_city_trade_card", "_city_trade_card_tween", "_city_trade_card_city_id",
	"_city_trade_card_content_signature", "_city_trade_card_direction", "_city_trade_bubble_body", "_city_trade_arrows",
	"_glow_city", "_city_boxes", "_city_pts", "_city_rects", "_city_rects_frame", "_cam_key", "_city_lamp_mats",
	"_city_tweens", "_sheen_mat", "_aura", "_aura_mat", "_sparkles", "_hover_path", "_hover_is_marker", "_tooltip",
	"_plaque_layer", "_plaques", "plaque_anchors", "plaque_offsets", "_layout_key", "_layout_cache", "_city_plaque_runtime",
]
## 跨世界保留的成员：相机、输入、触摸、贴边滚动、界面安全区、日光调试、测试配置，以及重建本身的记账
const KEEP_VARS: Array[String] = [
	"input_enabled", "test_duration_override", "_selection", "_right_inset", "edge_scroll", "edge_scroll_needs_focus",
	"_pointer_in", "_skip_release_click", "_edge_armed", "_edge_need_leave", "edge_scroll_blocked", "edge_scroll_exclude",
	"_hud_top", "_hud_bottom", "_edge_since", "_zoom", "_target", "_goal", "_drag_from", "_dragging", "_drag_moved",
	"_rendering", "_render_scale", "zoom_debug_lock", "day_speed", "day_time_override", "_day_hold", "debug_keys",
	"initial_layout_override", "world_rebuilds", "last_rebuild_ms", "last_first_frame_ms", "_map_sig", "_layout_pinned", "_peeking",
	"_disc_cache", "_path_shader", "city_plaque_candidate",
	"touch_gestures", "_touches", "_gesture", "_gesture_n", "_gesture_dirty", "_pinching", "_pinch_d0", "_pinch_z0",
	"_pan_c0", "_touch_pointer", "_stale_release", "_emu_press_pending", "_lone_taps", "_emu_index", "_zoom_tween",
	"_fling", "_drag_vel", "_drag_last_ms", "_last_pointer",
]


## 「每个世界一份」的成员表（WorkshopBoard 覆盖它，加上自己挂在世界上的成员）
func _world_state_vars() -> Array[String]:
	return WORLD_STATE_VARS


## 这一局要的世界签名：没地图（或地图里既没挪动也没新城）→ ""
func _wanted_sig() -> String:
	if GameState.content.is_empty() or not GameState.content.has("custom_map"):
		return ""
	var sig := CustomMapLoader.layout_sig(GameState.content)
	if sig == "":
		# WP1 的 layout_sig 返回空、而覆盖层里确实有挪动或新城时，按地图指纹（布局推导只由覆盖层决定）
		var cm: Dictionary = GameState.content.custom_map
		var ov: Dictionary = cm.get("overlay", {}) if cm.get("overlay", {}) is Dictionary else {}
		var mv: Dictionary = ov.get("moves", {}) if ov.get("moves", {}) is Dictionary else {}
		if not (mv.get("cities", {}) as Dictionary).is_empty() or not (mv.get("routes", {}) as Dictionary).is_empty() \
				or not (ov.get("new_cities", []) as Array).is_empty():
			sig = String(cm.get("sha256", "custom_map"))
	return sig


func _ensure_map_world() -> void:
	if _layout_pinned:
		return
	var sig := _wanted_sig()
	if sig == _map_sig:
		return
	var lay: Dictionary = {} if sig == "" else CustomBoardLayout.derive_for_content(GameState.content)
	if lay.has("error"):
		# 按说到不了这里：合并之前校验器已经用同一个 derive + check 把坏地图拦下。真到了就用原布局建，不让棋盘半建
		push_error("CUSTOM_MAP_WORLD derive failed, original layout used: %s" % String(lay.error))
		lay = {}
	rebuild_world_with_layout(lay)
	_map_sig = sig                   # 重建走完才记：中途出错的话，下次还会再试


## 这一局要的世界和现在的不一样、要整体重建吗（加载页 ③ 据此决定要不要先把文字换成「铺开你的地图…」）
func map_world_pending() -> bool:
	return _ready_world and not _layout_pinned and _wanted_sig() != _map_sig


## 加载页 ③ 之前 await 调用（出发、「再来一局」、读档都走这里），开发入口 _start() 之后也调；签名相同时立即返回。
## 要重建时先等一帧，让加载页把「铺开你的地图…」画出来。
func prepare_map_world() -> void:
	if not map_world_pending():
		return
	if is_inside_tree():
		await get_tree().process_frame
	_ensure_map_world()


## 工坊打开一张图（3.10.1 的第三处调用）：世界换成这份推导好的布局 lay，签名记成 sig（sig 相同时什么都不做）。
## 在 _ready 之前调也行：那时只记下来，_ready 直接用它建世界（initial_layout_override），不先建一遍原版。
## 调过之后世界由工坊定，不再按 GameState.content 换（工坊里没有对局，content 里没有地图，照它会把世界换回原版）。
## 直接调 rebuild_world_with_layout 不改签名。
func open_layout(lay: Dictionary, sig: String) -> void:
	_layout_pinned = true
	if not _ready_world:
		initial_layout_override = lay
		_map_sig = sig
		return
	if sig == _map_sig:
		return
	rebuild_world_with_layout(lay)
	_map_sig = sig


## 整体重建世界（3.10.2）：摘下并释放旧的 SubViewport、画面、世界、提示层，把「每个世界一份」的成员复位，
## 再照 _ready 的顺序用 lay（空 = 原文件）建一遍；相机的位置和缩放保留。棋子由接下来的 reload_for_current_game 重建。
func rebuild_world_with_layout(lay: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	# 1. 停下一切
	cancel_all_animations()
	clear_selection()
	_clear_city_hover()
	for tw in _city_tweens.values():
		if tw is Tween and (tw as Tween).is_valid():
			(tw as Tween).kill()
	if _city_trade_card_tween != null and _city_trade_card_tween.is_valid():
		_city_trade_card_tween.kill()
	# 2. 相机
	var keep_zoom := _zoom
	var keep_target := _target
	var keep_goal := _goal
	# 3. 摘下旧世界（棋子、标记、路线带都挂在 world_root 下，world_root 在 vp 里，跟着一起走）
	var slots: Array[int] = []
	var old: Array = [vp, view, world, _tooltip_layer]
	for n: Node in old:
		slots.append(n.get_index() if n != null and is_instance_valid(n) and n.get_parent() == self else -1)
	for n: Node in old:
		if n != null and is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.free() # Old actor resources must be gone before a different pair is allocated.
	# 4. 复位
	_reset_world_state()
	# 5. 照 _ready 的顺序重建
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	view = TextureRect.new()
	view.texture = vp.get_texture()
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_SCALE
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(view)
	world = World.new()
	world.name = "BoardWorld"
	world.layout_override = lay
	world.use_model_cache = true
	add_child(world)
	var t_build := Time.get_ticks_msec()
	world.build_into(vp, "noon")
	t_build = Time.get_ticks_msec() - t_build
	daycycle = DayCycle.new()
	daycycle.setup(world)
	_apply_daylight()
	var t_paths := Time.get_ticks_msec()
	paths = Paths.new()
	paths.use_route_cache = true          # 结果与现算相同；顺带把缓存填上，工坊接下来的轻量刷新就只算改过的路
	var probe: Node3D = Token.new()
	paths.build(world.layout, float(probe.boat_size), float(probe.boat_size) * 0.55)
	probe.free()
	t_paths = Time.get_ticks_msec() - t_paths
	_marker_root = Node3D.new()
	world.world_root.add_child(_marker_root)
	_path_mesh = MeshInstance3D.new()
	_path_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.world_root.add_child(_path_mesh)
	_hover_mesh = MeshInstance3D.new()
	_hover_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.world_root.add_child(_hover_mesh)
	_ready_world = true
	var t_hover := Time.get_ticks_msec()
	_build_city_hover()
	t_hover = Time.get_ticks_msec() - t_hover
	# 放回原来的层次（棋盘自己之后又加的子节点不被压到下面）
	var fresh: Array[Node] = [vp, view, world, _tooltip_layer]
	for i in fresh.size():
		if slots[i] >= 0:
			move_child(fresh[i], mini(slots[i], get_child_count() - 1))
	set_rendering_enabled(is_visible_in_tree())
	# 6. 相机：位置、缩放照旧，按新棋盘夹紧
	_zoom = keep_zoom
	_on_resized()
	_target = _clamp_target(keep_target, world.camera.size)
	_goal = _clamp_target(keep_goal, world.camera.size)
	_apply_camera()
	# 7.
	world_rebuilds += 1
	var ms := Time.get_ticks_msec() - t0
	last_rebuild_ms = ms
	last_first_frame_ms = -1
	print("CUSTOM_MAP_WORLD rebuilt ms=%d cities=%d routes=%d stops=%d custom=%s build_into=%d (world %d, cities %d, life %d) paths=%d hover=%d" % [ms,
		paths.city.size(), paths.routes.size(), paths.stop_pos.size(), str(not lay.is_empty()), t_build, int(world.build_ms.get("world", -1)),
		int(world.build_ms.get("cities", -1)), int(world.build_ms.get("life", -1)), t_paths, t_hover])
	var t1 := Time.get_ticks_msec()
	RenderingServer.frame_post_draw.connect(func():
		last_first_frame_ms = Time.get_ticks_msec() - t1
		print("CUSTOM_MAP_WORLD first_frame ms=%d" % last_first_frame_ms), CONNECT_ONE_SHOT)


## 把 _world_state_vars() 里的成员复位到声明时的初值：用本脚本新建一个不进树的实例，逐个拿它的初值
## （容器是新的空容器，paths 是新的 Paths 对象）
func _reset_world_state() -> void:
	var fresh: Object = (get_script() as Script).new()
	for n in _world_state_vars():
		set(n, fresh.get(n))
	if fresh is Node:
		(fresh as Node).free()


## 轻量刷新（工坊松手后第一步，3.12.7，≤ 100 ms）：城的位置、朝向、大小，路线虚线和硬币，新的 Paths，名牌，
## 新城和换了样子的城的悬停数据。世界、SubViewport 不动，选中不丢；已有的棋子重新接上新 Paths。返回耗时等。
func refresh_routes_and_cities(lay: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	if world == null or lay.is_empty():
		return {"ms": 0}
	var want := {}
	for c: Dictionary in lay.cities:
		want[String(c.id)] = c
	var glow_set := {}
	var rebuilt: Array[String] = []
	# 拆掉的城、换了样子的城
	for cid in world.city_nodes.keys():
		var e: Dictionary = world.city_nodes[cid]
		var c: Dictionary = want.get(String(cid), {})
		if c.is_empty() or String(c.get("model", World.CITY_DIR + String(cid) + ".glb")) != String(e.get("model", "")):
			_drop_city(String(cid))
	# 新城、换了样子的城：建；其余的就地挪
	for cid in want:
		var c: Dictionary = want[cid]
		if not world.city_nodes.has(cid):
			world.build_city(c)
			rebuilt.append(cid)
			if world.life != null:
				world.life.call("add_city_smoke", String(cid))      # 新城（换了样子的城）也冒两缕烟
			# 新城的夜灯也跟着日循环（DayCycle.setup 只在建世界时记一次各盏灯的原始亮度）
			if daycycle != null:
				for l in (world.city_nodes[cid] as Dictionary).get("lights", []):
					(daycycle.get("_base_energy") as Dictionary)[l] = (l as OmniLight3D).light_energy
			continue
		var e: Dictionary = world.city_nodes[cid]
		var holder: Node3D = e.node
		var fit: Array = World.CITY_FIT.get(cid, [World.CITY_YAW, 0.0, 0.0])
		var before := holder.global_transform
		var k := float(c.foot) / maxf(float(e.get("foot", c.foot)), 1e-6)
		e.scale = float(e.scale) * k
		e.foot = float(c.foot)
		holder.scale = Vector3.ONE * float(e.scale)
		holder.rotation.y = float(c.rotation) + float(fit[0])
		holder.position = Vector3(float(c.x) + float(fit[1]), float(c.y) - 0.02, float(c.z) + float(fit[2]))
		var moved := holder.global_transform * before.affine_inverse()
		if e.has("shadow") and is_instance_valid(e.shadow):
			(e.shadow as Decal).position = Vector3(float(c.x) + float(fit[1]), float(c.y), float(c.z) + float(fit[2])) + Vector3(0.12, 0.0, 0.08)
			(e.shadow as Decal).size = Vector3(float(c.foot) * 1.25, 1.2, float(c.foot) * 1.05)
		for l in e.get("lights", []):
			if is_instance_valid(l):
				(l as Node3D).position = moved * (l as Node3D).position
		if world.life != null and not moved.is_equal_approx(Transform3D.IDENTITY):
			world.life.call("move_city_smoke", String(cid), moved)   # 烟跟着城走
	if not rebuilt.is_empty():
		for g: Array in world.city_glow:
			glow_set[g[0]] = g
		for cid in rebuilt:
			_measure_city(cid, glow_set)
	# 路线虚线和硬币
	world.layout = lay
	if world.routes_node != null and is_instance_valid(world.routes_node):
		world.routes_node.queue_free()
	world.build_routes()
	# 新的 Paths（没改过的路直接用上次算好的，见 Paths.use_route_cache）；已有棋子重新接上
	paths = Paths.new()
	paths.use_route_cache = true
	var probe: Node3D = Token.new()
	paths.build(lay, float(probe.boat_size), float(probe.boat_size) * 0.55)
	probe.free()
	for pid in tokens:
		var tok: Node3D = tokens[pid]
		tok.fit_fn = paths.hull_fit
		tok.set_coins(PackedVector3Array(paths.stop_pos.values()))
		var sh: Dictionary = shown.get(pid, {})
		if String(sh.get("rid", "")) != "" and not paths.routes.has(String(sh.get("rid", ""))):
			sh.rid = paths.default_gate_rid(String(sh.get("node", "")), String(sh.get("medium", "LAND")))
	_snap_all()
	_relayout()
	# 名牌：按新的城表重建
	_rebuild_plaque_tags()
	_city_rects_frame = -1
	_cam_key = ""
	_update_markers()
	_update_path()
	_apply_camera()
	var ms := Time.get_ticks_msec() - t0
	return {"ms": ms, "cities": paths.city.size(), "routes": paths.routes.size(), "rebuilt_cities": rebuilt}


func _drop_city(cid: String) -> void:
	var e: Dictionary = world.city_nodes.get(cid, {})
	if e.is_empty():
		return
	if _glow_city == cid:
		_set_city_glow("")
	var day_lights: Dictionary = daycycle.get("_base_energy") if daycycle != null else {}
	for l in e.get("lights", []):
		world.city_lights.erase(l)
		day_lights.erase(l)
		if is_instance_valid(l):
			(l as Node).queue_free()
	if e.has("shadow") and is_instance_valid(e.shadow):
		(e.shadow as Node).queue_free()
	if is_instance_valid(e.node):
		(e.node as Node).queue_free()
	if world.life != null:
		world.life.call("drop_city_smoke", cid)        # 城拆了，烟一起拆
	world.city_nodes.erase(cid)
	_city_boxes.erase(cid)
	_city_pts.erase(cid)
	_city_lamp_mats.erase(cid)


func _rebuild_plaque_tags() -> void:
	if _plaque_layer == null:
		return
	for tag in _plaques.values():
		(tag as Node).queue_free()
	_plaques.clear()
	if city_plaque_candidate:
		_city_plaque_runtime = CityPlaqueRuntime.new(self)
		for cid in paths.city: _city_plaque_runtime.create_tag(str(cid))
		_name_plaques()
		return
	var tmp_layer := _plaque_layer
	# 只重建名牌本身（名牌层、标记层留着）：照 _build_plaques 的写法
	for cid in paths.city:
		var tag := Control.new()
		tag.name = "CityPlaque"
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var plaque := NinePatchRect.new()
		plaque.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		plaque.texture = CITY_PLAQUE_TEXTURE
		plaque.patch_margin_left = 20
		plaque.patch_margin_right = 20
		plaque.patch_margin_top = 12
		plaque.patch_margin_bottom = 12
		plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.add_child(plaque)
		var label := Label.new()
		label.name = "Name"
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.offset_left = 6.0
		label.offset_right = -6.0
		label.offset_top = 1.0
		label.offset_bottom = -1.0
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		HudStyle.apply_heading(label, HudStyle.PARCHMENT_LIGHT, HudStyle.SIZE_CITY_PLAQUE)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.add_child(label)
		tmp_layer.add_child(tag)
		_plaques[cid] = tag
	_name_plaques()
	_layout_plaques()


## 地面就地整理（工坊松手后第二步，3.12.7，≤ 150 ms）：树、道具、森林按新的 decor_cleared 缩成 0 或放回；
## 石板在原图副本上重放全部铺地操作；改过的路上的驼队、船队换路线表；新城、挪过的城周围的营地、羊群、尘土藏起来。
## 新加的路上暂时没有驼队（下次整体重建才有），这是工坊里唯一和游戏不一样的地方。
func apply_ground_edits(lay: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	if world == null or lay.is_empty():
		return {"ms": 0}
	var decor := int(world.set_decor_cleared(lay.get("decor_cleared", {})))
	world.replay_paving(lay.get("paving", []))
	var retargeted := 0
	var hidden := 0
	var life: Node = world.life
	if life != null:
		if _life_route_pts.is_empty():
			for r: Dictionary in life.get("layout").get("routes", []):
				_life_route_pts[String(r.id)] = r.points
		for r: Dictionary in lay.routes:
			var rid := String(r.id)
			if _life_route_pts.has(rid) and _life_route_pts[rid] != r.points:
				retargeted += int(life.call("retarget_route", rid, r.points))
				_life_route_pts[rid] = r.points
		life.call("clear_hidden")
		var shift: Dictionary = lay.get("plaque_shift", {})
		for c: Dictionary in lay.cities:
			if String(c.id).begins_with("x_") or shift.has(String(c.id)):
				hidden = int(life.call("hide_near", Vector2(float(c.x), float(c.z)), float(c.foot)))
	return {"ms": Time.get_ticks_msec() - t0, "decor_changed": decor, "retargeted": retargeted, "hidden": hidden}


## 镜头滑到某座城、停 sec 秒，再滑回当前玩家（加载页淡出后给孩子看一眼自己加的新城，3.7）；期间棋盘不接收按下。
## 开始和结束时都把拖动、触摸的状态放掉：孩子在加载页淡出那一刻按着鼠标、看新城期间才松开，地图不会粘在鼠标上
func peek_city(city_id: String, sec := 1.5) -> void:
	if world == null or world.camera == null or not paths.city.has(city_id) or _peeking:
		return
	_peeking = true
	_release_pointer()
	_follow = ""
	var back := _goal
	_goal = _clamp_target(_focus_point(_node_anchor(city_id)), world.camera.size)
	await get_tree().create_timer(0.9 + maxf(sec, 0.0)).timeout
	if _current_pid != "" and tokens.has(_current_pid):
		focus_current_player()
	else:
		_goal = back
	await get_tree().create_timer(0.9).timeout
	_peeking = false
	_release_pointer()


## 放掉拖动和触摸：之后到的那一下松开不算点、不甩
func _release_pointer() -> void:
	_dragging = false
	_drag_moved = false
	_fling = Vector2.ZERO
	_drag_vel = Vector2.ZERO
	_reset_touches()
	_stale_release = true


# ------------------------------------------------------------------ 名牌提醒（3.11：名牌与棋子站位、硬币重叠只报提醒，不拦导入）
const PLAQUE_WARN_STAND := Vector2(0.45, 1.25)   # 城门、码头上站着的棋子：半宽、高（世界单位）
const PLAQUE_WARN_COIN := Vector2(0.75, 0.62)    # 硬币：半宽、半深（同 plaque_layout.gd 的硬币框）


## 新城、挪过的原城的名牌有没有压到棋子的站位（城门、码头）或硬币：返回 [{code, target, kid, tech, level: "warn"}]。
## 名牌的位置是屏幕上的（固定的像素偏移，随缩放缩小），所以按棋盘当前的镜头算；原版的名牌是一座一座摆好的，不查。
## 工坊松手刷新之后调，把结果当黄色提醒显示；游戏端导入时不查（没有镜头，也不拦导入）
func plaque_warnings() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if world == null or world.camera == null or not (world.layout is Dictionary):
		return out
	var shift: Dictionary = world.layout.get("plaque_shift", {})
	_layout_plaques()
	var spots: Array = []            # [屏幕框, 说明]
	for cid in paths.gates:
		for rid in paths.gates[cid]:
			var g: Vector3 = paths.gates[cid][rid]
			var a := _to_view(g + Vector3(-PLAQUE_WARN_STAND.x, 0.0, 0.0))
			var b := _to_view(g + Vector3(PLAQUE_WARN_STAND.x, PLAQUE_WARN_STAND.y, 0.0))
			spots.append([Rect2(a, Vector2.ZERO).expand(b), "%s 的%s" % [cid, "码头" if String(paths.route_type(rid)) == "SEA" else "城门"]])
	for sid in paths.stop_pos:
		var c: Vector3 = paths.stop_pos[sid]
		var a := _to_view(c + Vector3(-PLAQUE_WARN_COIN.x, 0.0, -PLAQUE_WARN_COIN.y))
		var b := _to_view(c + Vector3(PLAQUE_WARN_COIN.x, 0.0, PLAQUE_WARN_COIN.y))
		spots.append([Rect2(a, Vector2.ZERO).expand(b), "硬币 %s" % sid])
	for cid in _plaques:
		if not (String(cid).begins_with("x_") or shift.has(cid)):
			continue
		var rect := _plaque_screen_rect(String(cid)).grow(-2.0)
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		for sp: Array in spots:
			if rect.intersects(sp[0] as Rect2):
				var name := String((_plaques[cid].get_node("Name") as Label).text)
				out.append({"code": "W_PLAQUE_STAND", "target": String(cid), "kid": "%s的名牌挡住了棋子要站的地方" % name,
					"tech": "名牌 %s 压到 %s（缩放 %.2f）" % [str(rect), String(sp[1]), _zoom], "level": "warn"})
				break
	return out


func get_city_plaque_debug_state() -> Dictionary:
	if _city_plaque_runtime != null: return _city_plaque_runtime.diagnostics.duplicate(true)
	return {"baseline":true,"cities":_plaques.keys()}
