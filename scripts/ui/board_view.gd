extends Control

## 对局地图视图：Demo 七城与正式十六城共用逻辑世界坐标、镜头与棋子动画。
## 规则与 MovementSystem 只使用世界逻辑坐标，不受镜头影响。

signal node_clicked(node_id: String)
signal city_inspect_requested(city_id: String)
signal move_animation_finished(player_id: String)

const LOGICAL_SIZE := Vector2(960, 540)
const MOVE_SPEED_PX_PER_SECOND := 100.0
const MIN_MOVE_SECONDS := 1.0
const TRANSPORT_SWITCH_SECONDS := 0.32
const SAMPLE_SPACING_PX := 2.0
const HIT_RADIUS_SCREEN_PX := 16.0
const LEGAL_HIT_RADIUS_SCREEN_PX := 22.0
const PAN_DRAG_THRESHOLD_PX := 6.0

const NODE_OUTER := Vector2(18.0, 14.5)
const NODE_INNER := Vector2(9.31, 7.5)

const COLOR_LAND_DASH := Color("f0e2c0", 0.95)
const COLOR_LAND_SHADOW := Color("5a4020", 0.28)
const COLOR_SEA_DASH := Color("5ec8e8", 0.95)
const COLOR_SEA_SHADOW := Color("1a4a6a", 0.35)
const COLOR_PATH := Color("c45c2a", 0.95)
const COLOR_HIGHLIGHT := Color("3f7d63", 0.45)
const COLOR_TEXT := Color("2f2a24")

const LAND_NODE_MID := Color("d4b56a")
const LAND_NODE_INNER := Color("a8873e")
const LAND_NODE_STROKE := Color("f7efd2")
const SEA_NODE_MID := Color("4a9fc4")
const SEA_NODE_INNER := Color("2a6d8c")
const SEA_NODE_STROKE := Color("c8e8f5")

const HOVER_GOLD := Color("ffd978")
const HOVER_CITY_SCALE := 1.075
const HOVER_CITY_LIFT := 3.0
const HOVER_RESPONSE := 14.0
# 从同一张透明分层红匾裁掉外部透明留白并等比缩为运行时九宫格源，
# 避免 1024px 原图在 72–96px 城市标签上把可见金边缩成一条细线。
const CITY_PLAQUE_TEXTURE := preload("res://assets/game/ui/ui_hud_city_plaque_v1.png")
const TRADE_BUBBLE_FRAME_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_frame_v1.png")
const TRADE_BUBBLE_ARROW_UP_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_arrow_up_v1.png")
const TRADE_BUBBLE_ARROW_DOWN_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_arrow_down_v1.png")
const TRADE_BUBBLE_ARROW_LEFT_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_arrow_left_v1.png")
const TRADE_BUBBLE_ARROW_RIGHT_TEXTURE := preload("res://assets/game/ui/trade_bubble/trade_bubble_arrow_right_v1.png")
const MAP_ENVIRONMENT_FX_SCENE := preload("res://scenes/map/fx/map_environment_fx.tscn")

## 交易卡气泡：主体与四向箭头动态组合（屏幕 UI，不随地图缩放变尺寸）。
const TRADE_BUBBLE_BODY_SIZE := Vector2(132, 114)
const TRADE_ARROW_UD_SIZE := Vector2(22, 15)
const TRADE_ARROW_LR_SIZE := Vector2(15, 22)
const TRADE_ARROW_OVERLAP := 3.0
const TRADE_TIP_GAP := 6.0
const TRADE_CORNER_CLEAR := 26.0
const TRADE_DIR_PRIORITY := ["up", "right", "left", "down"]

## 测试可注入覆盖移动速度/最短时长/固定总时长；生产保持 -1 使用默认常量。
var test_move_speed_px_per_second: float = -1.0
var test_min_move_seconds: float = -1.0
var test_duration_override: float = -1.0

var legal_nodes: Dictionary = {}
var selected_path: Array = []
var input_enabled := true
var animating := false

var _presentation: Dictionary = {}
var _logical_size := LOGICAL_SIZE
var _formal_world_mode := false
var _stage: Node2D
var _bg: Sprite2D
var _bg_content_overlay: Sprite2D
var _environment_fx: MapEnvironmentFX
var _route_shadow_layer: Node2D
var _route_layer: Node2D
var _node_shadow_layer: Node2D
var _node_layer: Node2D
var _city_layer: Node2D
var _piece_layer: Node2D
var _highlight_layer: Node2D
var _tooltip_layer: Control
var _tooltip: Label
var _city_trade_card: Control
var _city_trade_card_tween: Tween
var _city_trade_card_city_id := ""
var _city_trade_card_content_signature := ""
var _city_trade_card_direction := ""
var _city_trade_bubble_body: Control
var _city_trade_arrows: Dictionary = {} # direction name -> TextureRect
## 等比相机下不再需要非等比补偿；保留字段以免旧测试读取崩溃。
var _aspect_compensate := Vector2.ONE
var _pieces: Dictionary = {}
var _visual_override: Dictionary = {}
var _pending_anims := 0
var _pulse_t := 0.0
var _hover_node := ""
var _hover_path: Array = []
var _cached_route_polylines: Dictionary = {} # edge_id -> PackedVector2Array
var _city_visuals: Dictionary = {} # city_id -> {root, base_position}
## Debug/回归可见的静态缓存世代；只应在初始化或 ruleset presentation 重载时增长。
var _static_layer_rebuild_count := 0
var _route_cache_rebuild_count := 0
var _vfx_pool: MapVfxPool
var _vfx_layer: Node2D

var _camera := MapCameraController.new()
var _right_safe_inset := 0.0
var _pan_active := false
var _pan_from_blank := false
var _pan_pressed := false
var _pan_start_screen := Vector2.ZERO
var _pan_last_screen := Vector2.ZERO
var _pan_moved := false
var _pending_node_click := false
var _selection_mode := false
var _zoom_tween: Tween


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_stage()
	_load_presentation()
	_camera.camera_changed.connect(_apply_camera_transform)
	GameState.state_changed.connect(_on_state_changed)
	resized.connect(_on_board_resized)
	mouse_exited.connect(_clear_hover)
	_on_board_resized()
	_rebuild_static_layers()
	_rebuild_route_cache()
	_sync_pieces_from_state()
	reset_camera_to_fit()


func _process(delta: float) -> void:
	_pulse_t += delta
	_update_city_hover_visuals(delta)
	# 仅脉冲高亮层；避免每帧重绘路线。
	if _highlight_layer and (not legal_nodes.is_empty() or not _hover_node.is_empty()):
		_highlight_layer.queue_redraw()


func set_input_enabled(enabled: bool) -> void:
	input_enabled = enabled and not animating
	if not input_enabled:
		_clear_hover()


func set_selection_mode(enabled: bool) -> void:
	_selection_mode = enabled


func set_legal_nodes(nodes: Dictionary) -> void:
	legal_nodes = nodes
	if not _hover_node.is_empty() and not legal_nodes.has(_hover_node):
		_clear_hover()
	if _highlight_layer:
		_highlight_layer.queue_redraw()


func set_selected_path(path: Array) -> void:
	selected_path = path
	if _route_layer:
		_route_layer.queue_redraw()
	if _highlight_layer:
		_highlight_layer.queue_redraw()


func clear_selection() -> void:
	legal_nodes = {}
	selected_path = []
	_clear_hover()
	if _route_layer:
		_route_layer.queue_redraw()
	if _highlight_layer:
		_highlight_layer.queue_redraw()


func is_animating() -> bool:
	return animating


## 生产按恒定像素/秒速度移动；测试可注入覆盖速度或直接固定总时长。
func get_move_speed() -> float:
	if test_move_speed_px_per_second > 0.0:
		return test_move_speed_px_per_second
	return MOVE_SPEED_PX_PER_SECOND


func get_min_move_seconds() -> float:
	if test_min_move_seconds >= 0.0:
		return test_min_move_seconds
	return MIN_MOVE_SECONDS


func cancel_all_animations() -> void:
	for piece in _pieces.values():
		piece.cancel_motion()
	_visual_override.clear()
	animating = false
	_pending_anims = 0
	_sync_pieces_from_state()


## Main keeps GameScreen/BoardView instantiated while the title and setup screens are
## visible. The ruleset therefore changes after this node's _ready(). Reload the
## presentation explicitly when a prepared game is finalized; otherwise a formal game
## would retain the seven-city Demo background/camera even though its rule state is formal.
func reload_for_current_game() -> void:
	cancel_all_animations()
	clear_selection()
	_presentation = {}
	_load_presentation()
	_refresh_safe_view()
	_rebuild_static_layers()
	_rebuild_route_cache()
	_sync_pieces_from_state()
	reset_camera_to_fit()
	for layer in [
		_route_shadow_layer,
		_route_layer,
		_node_shadow_layer,
		_node_layer,
		_highlight_layer,
	]:
		if is_instance_valid(layer):
			layer.queue_redraw()


func play_visual_move(visual_move: Dictionary) -> void:
	if visual_move.is_empty():
		move_animation_finished.emit("")
		return
	var player_id := String(visual_move.get("player_id", ""))
	var path: Array = visual_move.get("path", [])
	var transport := int(visual_move.get("transport", GameData.Transport.CAMEL))
	if player_id.is_empty():
		move_animation_finished.emit("")
		return
	if not _pieces.has(player_id):
		_sync_pieces_from_state()
	if not _pieces.has(player_id):
		move_animation_finished.emit(player_id)
		return
	var piece: MapPieceActor = _pieces[player_id]
	piece.set_transport(transport)
	piece.test_duration_override = test_duration_override
	piece.vfx_pool = _vfx_pool
	var seat := Vector2.ZERO if _formal_world_mode else _seat_offset_for_id(player_id)
	var route_type := _route_type_for_transport(transport)
	var edges := _path_to_edge_polylines(path, route_type)
	for ei in range(edges.size()):
		var pts: Array = edges[ei]
		for i in range(pts.size()):
			pts[i] = pts[i] + seat
		edges[ei] = pts
	var steps := maxi(path.size() - 1, 0)
	if steps <= 0 or edges.is_empty():
		_visual_override.erase(player_id)
		piece.set_logical_position(
			_node_route_pos(String(visual_move.get("to_node_id", "")), route_type) + seat
		)
		move_animation_finished.emit(player_id)
		return
	var built := _build_continuous_path(edges)
	if built["total"] <= 0.001 or built["samples"].size() < 2:
		_visual_override.erase(player_id)
		piece.set_logical_position(
			_node_route_pos(String(visual_move.get("to_node_id", "")), route_type) + seat
		)
		move_animation_finished.emit(player_id)
		return
	var duration := maxf(float(built["total"]) / get_move_speed(), get_min_move_seconds())
	var mid_node_ids: Array = path.slice(1, path.size() - 1)
	animating = true
	_pending_anims += 1
	_visual_override[player_id] = built["samples"][0]
	piece.set_logical_position(built["samples"][0])
	piece.play_path(
		built["samples"], built["cum"], built["total"], duration,
		built["node_breaks"], mid_node_ids, get_move_speed()
	)


func estimated_move_seconds(visual_move: Dictionary) -> float:
	var path: Array = visual_move.get("path", [])
	var steps := maxi(path.size() - 1, 0)
	if steps <= 0:
		return 0.0
	# 与 play_visual_move 对 piece 的时长注入保持一致，保证 AI/UI 等待的时长与实际播放一致。
	if test_duration_override > 0.0:
		return test_duration_override
	var route_type := _route_type_for_transport(
		int(visual_move.get("transport", GameData.Transport.CAMEL))
	)
	var edges := _path_to_edge_polylines(path, route_type)
	var built := _build_continuous_path(edges)
	if built["total"] <= 0.001:
		return 0.0
	return maxf(float(built["total"]) / get_move_speed(), get_min_move_seconds())


## TurnSystem 已完成规则换乘后，补播同一城市陆/海锚点之间的短视觉过渡。
## 规则坐标与交通状态不在这里修改。
func play_transport_switch_visual(
	player_id: String,
	from_transport: int,
	to_transport: int
) -> void:
	if player_id.is_empty() or not _pieces.has(player_id):
		_sync_pieces_from_state()
	if player_id.is_empty() or not _pieces.has(player_id):
		move_animation_finished.emit(player_id)
		return
	var player := _player_by_id(player_id)
	if player == null:
		move_animation_finished.emit(player_id)
		return
	var seat := Vector2.ZERO if _formal_world_mode else _seat_offset(player)
	var from_pos := _node_route_pos(
		player.current_node_id,
		_route_type_for_transport(from_transport)
	) + seat
	var to_pos := _node_route_pos(
		player.current_node_id,
		_route_type_for_transport(to_transport)
	) + seat
	var piece: MapPieceActor = _pieces[player_id]
	if from_pos.distance_to(to_pos) <= 0.5:
		_visual_override.erase(player_id)
		piece.set_transport(to_transport)
		piece.set_logical_position(to_pos)
		move_animation_finished.emit(player_id)
		return
	animating = true
	_pending_anims += 1
	_visual_override[player_id] = from_pos
	piece.vfx_pool = _vfx_pool
	piece.play_transport_switch(
		from_pos,
		to_pos,
		from_transport,
		to_transport,
		TRANSPORT_SWITCH_SECONDS
	)


func estimated_transport_switch_seconds() -> float:
	return TRANSPORT_SWITCH_SECONDS


## 拼接多条边折线为一条连续弧长路径：去重相接节点，记录中途节点在整段弧长上的
## 累计距离（node_breaks），用于触发“经过节点但不停顿”的视觉反馈。
func _build_continuous_path(edges: Array) -> Dictionary:
	var samples := PackedVector2Array()
	var break_indices: Array = []
	for ei in range(edges.size()):
		var pts: Array = edges[ei]
		if pts.is_empty():
			continue
		var start_i := 0
		if samples.size() > 0:
			var first_pt: Vector2 = _as_vec2(pts[0])
			if samples[samples.size() - 1].distance_to(first_pt) < 0.01:
				start_i = 1
		for i in range(start_i, pts.size()):
			samples.append(_as_vec2(pts[i]))
		if ei < edges.size() - 1 and samples.size() > 0:
			break_indices.append(samples.size() - 1)
	var cum := PackedFloat32Array()
	cum.append(0.0)
	var total := 0.0
	for i in range(1, samples.size()):
		total += samples[i - 1].distance_to(samples[i])
		cum.append(total)
	if total < 0.001:
		total = 0.001
	var node_breaks := PackedFloat32Array()
	for idx in break_indices:
		var ii := int(idx)
		if ii >= 0 and ii < cum.size():
			node_breaks.append(cum[ii])
	return {"samples": samples, "cum": cum, "total": total, "node_breaks": node_breaks}


func _as_vec2(p) -> Vector2:
	if p is Vector2:
		return p
	if p is Array and p.size() >= 2:
		return Vector2(float(p[0]), float(p[1]))
	return Vector2.ZERO


func get_route_polyline(edge_id: String) -> PackedVector2Array:
	return _cached_route_polylines.get(edge_id, PackedVector2Array())


func get_node_style(node_id: String) -> String:
	var styles: Dictionary = _presentation.get("node_styles", {})
	return String(styles.get(node_id, "land"))


func _on_piece_move_finished(player_id: String) -> void:
	_visual_override.erase(player_id)
	_pending_anims = maxi(_pending_anims - 1, 0)
	if _pending_anims == 0:
		animating = false
	_sync_pieces_from_state()
	move_animation_finished.emit(player_id)


func _build_stage() -> void:
	# 相机 letterbox 区域不得透出 GameScreen 沙色底。
	var letterbox_fill := ColorRect.new()
	letterbox_fill.name = "MapLetterboxFill"
	letterbox_fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	letterbox_fill.color = Color("1e3340")
	letterbox_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(letterbox_fill)
	_stage = Node2D.new()
	_stage.name = "MapStage"
	add_child(_stage)
	_bg = Sprite2D.new()
	_bg.name = "MapBackground"
	_bg.centered = false
	_bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_stage.add_child(_bg)
	_bg_content_overlay = Sprite2D.new()
	_bg_content_overlay.name = "MapContentOverlay"
	_bg_content_overlay.centered = false
	_bg_content_overlay.visible = false
	_stage.add_child(_bg_content_overlay)
	_environment_fx = MAP_ENVIRONMENT_FX_SCENE.instantiate()
	_environment_fx.name = "MapEnvironmentFX"
	_stage.add_child(_environment_fx)
	_route_shadow_layer = Node2D.new()
	_route_shadow_layer.name = "RouteShadowLayer"
	_route_shadow_layer.draw.connect(_draw_route_shadows)
	_stage.add_child(_route_shadow_layer)
	_route_layer = Node2D.new()
	_route_layer.name = "RouteLayer"
	_route_layer.draw.connect(_draw_routes)
	_stage.add_child(_route_layer)
	_node_shadow_layer = Node2D.new()
	_node_shadow_layer.name = "NodeShadowLayer"
	_node_shadow_layer.draw.connect(_draw_node_shadows)
	_stage.add_child(_node_shadow_layer)
	_node_layer = Node2D.new()
	_node_layer.name = "NodeLayer"
	_node_layer.draw.connect(_draw_nodes)
	_stage.add_child(_node_layer)
	_city_layer = Node2D.new()
	_city_layer.name = "CityLayer"
	_stage.add_child(_city_layer)
	_vfx_layer = Node2D.new()
	_vfx_layer.name = "VfxLayer"
	_stage.add_child(_vfx_layer)
	_vfx_pool = MapVfxPool.new()
	_vfx_pool.name = "MapVfxPool"
	_vfx_layer.add_child(_vfx_pool)
	_piece_layer = Node2D.new()
	_piece_layer.name = "PieceLayer"
	_stage.add_child(_piece_layer)
	_highlight_layer = Node2D.new()
	_highlight_layer.name = "HighlightLayer"
	_highlight_layer.draw.connect(_draw_highlights)
	_stage.add_child(_highlight_layer)
	_tooltip_layer = Control.new()
	_tooltip_layer.name = "TooltipLayer"
	_tooltip_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_tooltip_layer)
	_tooltip = Label.new()
	_tooltip.visible = false
	_tooltip.add_theme_font_size_override("font_size", 12)
	_tooltip.add_theme_color_override("font_color", COLOR_TEXT)
	_tooltip_layer.add_child(_tooltip)
	_city_trade_card = _build_city_trade_card()
	_city_trade_card.visible = false
	_tooltip_layer.add_child(_city_trade_card)


func _load_presentation() -> void:
	var ruleset_id := String(GameState.content.get("ruleset", {}).get("ruleset_id", ""))
	_formal_world_mode = ruleset_id == "lshu_configurable_v1"
	if _formal_world_mode:
		_presentation = FormalWorldMapPresentation.build(GameState.content)
	else:
		var path := "res://data/rulesets/cn_demo_v1/presentation/map_presentation.json"
		if FileAccess.file_exists(path):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if parsed is Dictionary:
				_presentation = parsed
	var logical: Array = _presentation.get("logical_size", [LOGICAL_SIZE.x, LOGICAL_SIZE.y])
	_logical_size = Vector2(
		float(logical[0]) if logical.size() > 0 else LOGICAL_SIZE.x,
		float(logical[1]) if logical.size() > 1 else LOGICAL_SIZE.y
	)
	if _formal_world_mode:
		# 正式对局默认显示约半幅世界地图，支持 80%–150% 缩放。相机 cover
		# 边界包含 4096×1755 的纯地形 overscan；城市、路线与节点均由独立
		# 运行时图层绘制，严禁重新叠加拍平的 world_map_v1 预览图。
		var profile: Dictionary = _presentation.get("camera_profile", {}).duplicate(true)
		profile["min_zoom_factor"] = 0.8
		profile["max_zoom_factor"] = 1.5
		profile["elastic_overscroll_screen_px"] = 0.0
		var wb: Array = _presentation.get("world_bounds", [0.0, 0.0, _logical_size.x, _logical_size.y])
		var world_bounds := Rect2(
			float(wb[0]), float(wb[1]), float(wb[2]), float(wb[3])
		) if wb.size() >= 4 else Rect2(Vector2.ZERO, _logical_size)
		_camera.configure_half_view(profile, world_bounds, _camera.safe_view_rect)
	else:
		_camera.configure_from_presentation(_presentation, _logical_size)
	var focus: Variant = _presentation.get("initial_focus_bounds", null)
	if focus is Array and focus.size() >= 4:
		# 可选：表现层预置焦点框；默认仍用内容包围盒。
		pass
	var bg_path := String(_presentation.get("map_background", "res://assets/game/map/map_cn_7city_unmarked_v1.png"))
	var tex: Texture2D = load(bg_path)
	if tex != null:
		_bg.texture = tex
		_bg.texture_filter = (
			CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			if _formal_world_mode
			else CanvasItem.TEXTURE_FILTER_NEAREST
		)
		var bg_origin: Array = _presentation.get("map_background_origin", [0.0, 0.0])
		var bg_world_size: Array = _presentation.get(
			"map_background_world_size", [_logical_size.x, _logical_size.y]
		)
		_bg.position = Vector2(float(bg_origin[0]), float(bg_origin[1]))
		_bg.scale = Vector2(
			float(bg_world_size[0]) / tex.get_width(),
			float(bg_world_size[1]) / tex.get_height()
		)
	var overlay_path := String(_presentation.get("map_content_overlay", ""))
	var overlay_tex: Texture2D = load(overlay_path) if not overlay_path.is_empty() else null
	if _bg_content_overlay != null:
		_bg_content_overlay.visible = overlay_tex != null
		_bg_content_overlay.texture = overlay_tex
		if overlay_tex != null:
			var overlay_origin: Array = _presentation.get("map_content_overlay_origin", [0.0, 0.0])
			var overlay_size: Array = _presentation.get(
				"map_content_overlay_world_size", [_logical_size.x, _logical_size.y]
			)
			_bg_content_overlay.position = Vector2(float(overlay_origin[0]), float(overlay_origin[1]))
			_bg_content_overlay.scale = Vector2(
				float(overlay_size[0]) / overlay_tex.get_width(),
				float(overlay_size[1]) / overlay_tex.get_height()
			)
			_bg_content_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if _environment_fx != null:
		# 七城专用风沙/海浪坐标不可复用到 4096px 世界地图；正式地图后续使用
		# 自己的分区 FX，不让 Demo 特效漂到错误地形上。
		_environment_fx.visible = not _formal_world_mode


## HUD 告知右侧卷轴占用：BoardView 全宽时可把卷轴纸面排除出默认 fit 安全区。
func set_map_safe_right_inset(pixels: float) -> void:
	_right_safe_inset = maxf(0.0, pixels)
	_refresh_safe_view()
	if zoom_factor_is_default():
		reset_camera_to_fit()
	else:
		_apply_camera_transform()


func zoom_factor_is_default() -> bool:
	return absf(_camera.zoom_factor - 1.0) < 0.001


func reset_camera_to_fit() -> void:
	_refresh_safe_view()
	if _formal_world_mode:
		var focus := _logical_size * 0.5
		if not GameState.players.is_empty():
			var current: PlayerState = GameState.players[0]
			if GameState.is_in_turn():
				current = GameState.current_player()
			if current != null and not String(current.current_node_id).is_empty():
				focus = _node_pos(String(current.current_node_id))
		_camera.reset_half_view_default(focus)
	else:
		_camera.reset_to_fit(compute_content_bounds())
	_apply_camera_transform()


func compute_content_bounds() -> Rect2:
	var has_any := false
	var bounds := Rect2()
	if not GameState.content.is_empty():
		for node_id in GameState.content.get("board_nodes", {}):
			var p := _node_pos(String(node_id))
			if not has_any:
				bounds = Rect2(p, Vector2.ZERO)
				has_any = true
			else:
				bounds = bounds.expand(p)
	for city_id in _city_visuals:
		var entry: Dictionary = _city_visuals[city_id]
		var base: Vector2 = entry.get("base_position", Vector2.ZERO)
		var bsize: Vector2 = entry.get("building_size", Vector2(72, 72))
		var half := bsize * 0.5
		var city_rect := Rect2(base - half, bsize)
		# 红匾大致在建筑下方。
		city_rect = city_rect.expand(base + Vector2(0, half.y + 28.0))
		city_rect = city_rect.expand(base + Vector2(-half.x - 8.0, half.y + 28.0))
		city_rect = city_rect.expand(base + Vector2(half.x + 8.0, half.y + 28.0))
		if not has_any:
			bounds = city_rect
			has_any = true
		else:
			bounds = bounds.merge(city_rect)
	for piece in _pieces.values():
		if is_instance_valid(piece):
			var pp: Vector2 = (piece as Node2D).position
			if not has_any:
				bounds = Rect2(pp, Vector2.ZERO)
				has_any = true
			else:
				bounds = bounds.expand(pp)
	if not has_any:
		return _camera.world_bounds
	return bounds


func world_to_screen(world: Vector2) -> Vector2:
	return _camera.world_to_screen(world)


func screen_to_world(screen: Vector2) -> Vector2:
	return _camera.screen_to_world(screen)


func _on_board_resized() -> void:
	_refresh_safe_view()
	if _camera.fit_scale <= 0.0001 or zoom_factor_is_default():
		reset_camera_to_fit()
	else:
		_camera.pan_by_screen_delta(Vector2.ZERO)
		_apply_camera_transform()


func _refresh_safe_view() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	var w := maxf(1.0, size.x - _right_safe_inset)
	_camera.set_safe_view_rect(Rect2(0, 0, w, size.y))


func _apply_camera_transform() -> void:
	if _stage == null:
		return
	var s := _camera.render_scale()
	_stage.scale = Vector2(s, s)
	_stage.position = _camera.stage_position()
	_aspect_compensate = Vector2.ONE
	_apply_aspect_compensation()
	if _city_trade_card != null and _city_trade_card.visible and not _city_trade_card_city_id.is_empty():
		_show_city_trade_card(_city_trade_card_city_id)


func _fit_stage() -> void:
	## 兼容旧调用名：改为内容 fit + 相机变换。
	reset_camera_to_fit()


func _apply_aspect_compensation() -> void:
	## 等比相机下建筑/棋子保持 scale=1（悬停倍率另计）。
	for city_id in _city_visuals:
		var entry: Dictionary = _city_visuals[city_id]
		var root: Node2D = entry.get("root")
		if not is_instance_valid(root):
			continue
		if String(city_id) != _hover_node:
			root.scale = Vector2.ONE
	for piece in _pieces.values():
		if is_instance_valid(piece):
			# 世界地图放大时只放大地理关系，不把棋子也放成巨物；按 zoom
			# 反补偿后，棋子屏幕尺寸在 80%–150% 范围内保持稳定。
			var piece_scale := 1.0 / maxf(_camera.zoom_factor, 0.001) if _formal_world_mode else 1.0
			(piece as Node2D).scale = Vector2(piece_scale, piece_scale)


func _screen_to_logical(screen_pos: Vector2) -> Vector2:
	return screen_to_world(screen_pos)


func logical_to_screen(logical: Vector2) -> Vector2:
	return world_to_screen(logical)


func get_map_debug_state() -> Dictionary:
	var corners := {
		"tl": logical_to_screen(Vector2.ZERO),
		"br": logical_to_screen(_logical_size),
	}
	var cities := {}
	for city_id in _city_visuals:
		var entry: Dictionary = _city_visuals[city_id]
		var base: Vector2 = entry.get("base_position", Vector2.ZERO)
		var bsize: Vector2 = entry.get("building_size", Vector2(72, 72))
		var root: Node2D = entry.get("root")
		var plaque: Control = root.get_node_or_null("CityPlaque") if is_instance_valid(root) else null
		var plaque_rect := Rect2()
		if plaque != null:
			plaque_rect = plaque.get_global_rect()
		cities[city_id] = {
			"base": base,
			"screen": logical_to_screen(base),
			"building_size": bsize,
			"plaque_global": plaque_rect,
			"in_safe_view": _camera.safe_view_rect.has_point(logical_to_screen(base)),
		}
	var cam := _camera.debug_state()
	var pieces := {}
	for player_id in _pieces:
		var piece: Node2D = _pieces[player_id]
		if not is_instance_valid(piece):
			continue
		pieces[String(player_id)] = {
			"world_position": piece.position,
			"screen_position": logical_to_screen(piece.position),
			"scale": piece.scale,
			"visible": piece.visible,
		}
	return {
		"board_size": size,
		"stage_scale": _stage.scale if _stage else Vector2.ZERO,
		"stage_position": _stage.position if _stage else Vector2.ZERO,
		"aspect_compensate": _aspect_compensate,
		"corners": corners,
		"cities": cities,
		"camera": cam,
		"content_bounds": compute_content_bounds(),
		"right_safe_inset": _right_safe_inset,
		"formal_world_mode": _formal_world_mode,
		"logical_size": _logical_size,
		"background_path": _bg.texture.resource_path if _bg != null and _bg.texture != null else "",
		"content_overlay_path": (
			_bg_content_overlay.texture.resource_path
			if _bg_content_overlay != null and _bg_content_overlay.texture != null
			else ""
		),
		"city_visual_count": _city_visuals.size(),
		"route_polyline_count": _cached_route_polylines.size(),
		"static_layer_rebuild_count": _static_layer_rebuild_count,
		"route_cache_rebuild_count": _route_cache_rebuild_count,
		"piece_count": _pieces.size(),
		"pieces": pieces,
	}


func _on_state_changed() -> void:
	if GameState.content.is_empty():
		return
	# 城市建筑/名牌与路线折线只依赖当前 ruleset 的 presentation，不依赖回合状态。
	# 正式世界地图有 16 城、50 边；每个 state_changed 都销毁重建静态树会让一次
	# 完整回合产生多次 4K 地图重建。规则集切换已经由 reload_for_current_game()
	# 显式负责重载，这里只同步真正随状态变化的棋子与动态绘制层。
	if not animating:
		_sync_pieces_from_state()
	_route_shadow_layer.queue_redraw()
	_route_layer.queue_redraw()
	_node_shadow_layer.queue_redraw()
	_node_layer.queue_redraw()
	_highlight_layer.queue_redraw()


func _rebuild_route_cache() -> void:
	_route_cache_rebuild_count += 1
	_cached_route_polylines.clear()
	if GameState.content.is_empty():
		return
	for route in _presentation.get("routes", []):
		var edge_id := String(route.get("edge_id", ""))
		var pts: Array = route.get("points", [])
		if edge_id.is_empty() or pts.size() < 2:
			continue
		if _formal_world_mode:
			var poly := PackedVector2Array()
			for point in pts:
				poly.append(_as_vec2(point))
			_cached_route_polylines[edge_id] = poly
		else:
			_cached_route_polylines[edge_id] = _sample_curve_dense(pts)


func _rebuild_static_layers() -> void:
	_static_layer_rebuild_count += 1
	_city_visuals.clear()
	for child in _city_layer.get_children():
		_city_layer.remove_child(child)
		child.free()
	if GameState.content.is_empty():
		return
	var cities_visual: Dictionary = _presentation.get("cities_visual", {})
	for city_id in GameState.content["cities"]:
		var city: Dictionary = GameState.content["cities"][city_id]
		var vis: Dictionary = cities_visual.get(city_id, {})
		if _formal_world_mode:
			_build_formal_city_visual(String(city_id), city, vis)
		else:
			_build_demo_city_visual(String(city_id), city, vis)


func _build_formal_city_visual(city_id: String, city: Dictionary, vis: Dictionary) -> void:
	var raw_rect: Array = vis.get("static_visible_rect_px", [])
	if raw_rect.size() != 4:
		push_error("BoardView: missing calibrated city rect %s" % city_id)
		return
	var target_rect := Rect2(
		float(raw_rect[0]), float(raw_rect[1]),
		float(raw_rect[2]), float(raw_rect[3])
	)
	var bottom_center := Vector2(target_rect.get_center().x, target_rect.end.y)
	var root := Node2D.new()
	root.name = "City_%s" % city_id
	root.position = bottom_center
	_city_layer.add_child(root)
	var entry := {
		"root": root,
		# Public/interaction centre is the visible building centre.  The render
		# pivot is bottom-centre so every 32f frame can share the same foot line.
		"base_position": target_rect.get_center(),
		"render_bottom_center": bottom_center,
		"building_size": target_rect.size,
		"visible_building_rect": target_rect,
	}
	_city_visuals[city_id] = entry

	var sprite_path := String(vis.get("sprite", ""))
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var spr := Sprite2D.new()
		spr.name = "IdleCity"
		spr.texture = load(sprite_path)
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		spr.centered = true
		var bbox := _texture_opaque_bbox(spr.texture, 32)
		var fit_x := target_rect.size.x / maxf(bbox.size.x, 1.0)
		var fit_y := target_rect.size.y / maxf(bbox.size.y, 1.0)
		var uniform_scale := (fit_x + fit_y) * 0.5
		spr.scale = Vector2.ONE * uniform_scale
		var texture_center := Vector2(spr.texture.get_width(), spr.texture.get_height()) * 0.5
		var visible_bottom_center := Vector2(bbox.get_center().x, bbox.end.y)
		spr.position = -(visible_bottom_center - texture_center) * uniform_scale
		root.add_child(spr)
		entry["sprite"] = spr
		entry["visible_building_rect"] = _compute_visible_building_world_rect(root.position, spr)

	# Reuse the already-approved PXD-calibrated 32-frame hover implementation.
	var hover := WorldMapCityHoverOverlay.new()
	hover.name = "Hover_%s" % city_id
	hover.setup_from_city(vis)
	var hover_world_position := hover.position
	hover.position = hover_world_position - root.position
	hover.z_index = 1
	root.add_child(hover)
	entry["hover_overlay"] = hover
	_attach_city_plaque(root, city_id, city, vis, target_rect.size)


func _build_demo_city_visual(city_id: String, city: Dictionary, vis: Dictionary) -> void:
	var center: Array = vis.get(
		"center",
		vis.get("building_center", city.get("building_center", city.get("map_position", [0, 0])))
	)
	if not (center is Array and center.size() >= 2):
		center = city.get("map_position", [0, 0])
	var bsize: Array = vis.get("size", city.get("building_size", [96, 96]))
	var size_vec := Vector2(float(bsize[0]), float(bsize[1]))
	var root := Node2D.new()
	root.name = "City_%s" % city_id
	root.position = Vector2(float(center[0]), float(center[1]))
	_city_layer.add_child(root)
	var entry := {
		"root": root,
		"base_position": root.position,
		"render_bottom_center": root.position + Vector2(0, size_vec.y * 0.5),
		"building_size": size_vec,
		"visible_building_rect": Rect2(root.position - size_vec * 0.5, size_vec),
	}
	_city_visuals[city_id] = entry
	var sprite_path := String(vis.get("sprite", city.get("sprite", "")))
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var spr := Sprite2D.new()
		spr.name = "IdleCity"
		spr.texture = load(sprite_path)
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.centered = true
		spr.scale = Vector2(size_vec.x / spr.texture.get_width(), size_vec.y / spr.texture.get_height())
		root.add_child(spr)
		entry["sprite"] = spr
		entry["visible_building_rect"] = _compute_visible_building_world_rect(root.position, spr)
	var explicit_hit: Variant = vis.get("building_hit_rect", null)
	if explicit_hit is Dictionary:
		var hit: Dictionary = explicit_hit
		entry["visible_building_rect"] = Rect2(
			float(hit.get("x", root.position.x - size_vec.x * 0.5)),
			float(hit.get("y", root.position.y - size_vec.y * 0.5)),
			float(hit.get("w", size_vec.x)),
			float(hit.get("h", size_vec.y))
		)
	_attach_city_plaque(root, city_id, city, vis, size_vec)


func _attach_city_plaque(
	root: Node2D,
	city_id: String,
	city: Dictionary,
	vis: Dictionary,
	building_size: Vector2
) -> void:
	var tag := Control.new()
	tag.name = "CityPlaque"
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var city_name := String(city.get("display_name", city_id))
	var plaque_width := clampf(56.0 + city_name.length() * 12.0, 72.0, 124.0)
	var label_pos: Array = vis.get("label_position", [])
	var label_size: Array = vis.get("label_size", [])
	if label_pos.size() >= 2 and label_size.size() >= 2:
		tag.position = Vector2(float(label_pos[0]), float(label_pos[1])) - root.position
		tag.size = Vector2(float(label_size[0]), float(label_size[1]))
	else:
		tag.size = Vector2(plaque_width, 25.0)
		tag.position = Vector2(-plaque_width * 0.5, building_size.y * 0.08)

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
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.offset_left = 6.0
	label.offset_right = -6.0
	label.offset_top = 1.0
	label.offset_bottom = -1.0
	label.text = city_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	HudStyle.apply_heading(label, HudStyle.PARCHMENT_LIGHT, HudStyle.SIZE_CITY_PLAQUE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_child(label)
	tag.z_index = 2
	root.add_child(tag)
	root.scale = Vector2.ONE
func _sync_pieces_from_state() -> void:
	if GameState.players.is_empty():
		return
	var seen := {}
	for player in GameState.players:
		seen[player.player_id] = true
		if not _pieces.has(player.player_id):
			var actor := MapPieceActor.new()
			_piece_layer.add_child(actor)
			actor.setup(player.player_id, player.is_local_human(), player.active_transport)
			actor.vfx_pool = _vfx_pool
			actor.move_finished.connect(_on_piece_move_finished)
			_pieces[player.player_id] = actor
		var piece: MapPieceActor = _pieces[player.player_id]
		piece.set_transport(player.active_transport)
		var piece_scale := 1.0 / maxf(_camera.zoom_factor, 0.001) if _formal_world_mode else 1.0
		piece.scale = Vector2(piece_scale, piece_scale)
		if _visual_override.has(player.player_id):
			piece.set_logical_position(_visual_override[player.player_id])
		else:
			var route_type := _route_type_for_transport(player.active_transport)
			var seat := Vector2.ZERO if _formal_world_mode else _seat_offset(player)
			piece.set_logical_position(_node_route_pos(player.current_node_id, route_type) + seat)
	for pid in _pieces.keys():
		if not seen.has(pid):
			_pieces[pid].queue_free()
			_pieces.erase(pid)


func _seat_offset(player: PlayerState) -> Vector2:
	return Vector2(-18 + 36 * player.seat_index, 4 * player.seat_index)


func _seat_offset_for_id(player_id: String) -> Vector2:
	for player in GameState.players:
		if player.player_id == player_id:
			return _seat_offset(player)
	return Vector2.ZERO


func _player_by_id(player_id: String) -> PlayerState:
	for player in GameState.players:
		if player.player_id == player_id:
			return player
	return null


func _node_pos(node_id: String) -> Vector2:
	var node: Dictionary = GameState.content.get("board_nodes", {}).get(node_id, {})
	var pos = node.get("map_position", Vector2.ZERO)
	if pos is Vector2:
		return pos
	if pos is Array and pos.size() >= 2:
		return Vector2(float(pos[0]), float(pos[1]))
	return Vector2.ZERO


func _node_route_pos(node_id: String, route_type: String) -> Vector2:
	var node: Dictionary = GameState.content.get("board_nodes", {}).get(node_id, {})
	var anchors_variant: Variant = node.get("route_anchors", {})
	if anchors_variant is Dictionary:
		var anchors: Dictionary = anchors_variant
		if anchors.has(route_type):
			return _as_vec2(anchors[route_type])
	return _node_pos(node_id)


func _node_visual_anchors(node_id: String) -> Array[Dictionary]:
	# 各交通方式使用路线锚点命中；正式地图的换乘方式共用城市下的一个座位。
	# 合并重合锚点，避免将一个城市画成两个停靠点。
	var node: Dictionary = GameState.content.get("board_nodes", {}).get(node_id, {})
	var anchors_variant: Variant = node.get("route_anchors", {})
	var allowed_variant: Variant = node.get("allowed_routes", [])
	var anchors: Dictionary = anchors_variant if anchors_variant is Dictionary else {}
	var allowed: Array = allowed_variant if allowed_variant is Array else []
	var result: Array[Dictionary] = []
	for route_value in allowed:
		var route_type := String(route_value).to_upper()
		if route_type != "LAND" and route_type != "SEA":
			continue
		var pos := _node_route_pos(node_id, route_type)
		var duplicate := false
		for existing in result:
			if (existing.get("position", Vector2.INF) as Vector2).distance_to(pos) <= 0.5:
				duplicate = true
				break
		if not duplicate:
			result.append({"position": pos, "route_type": route_type})
	if result.is_empty():
		result.append({
			"position": _node_pos(node_id),
			"route_type": "SEA" if get_node_style(node_id) == "sea" else "LAND",
		})
	return result


func _interaction_node_pos(node_id: String) -> Vector2:
	var route_type := _current_route_type()
	return _node_route_pos(node_id, route_type) if not route_type.is_empty() else _node_pos(node_id)


func _route_type_for_transport(transport: int) -> String:
	return "LAND" if transport == GameData.Transport.CAMEL else "SEA"


func _current_route_type() -> String:
	if GameState.players.is_empty() or not GameState.is_in_turn():
		return ""
	return _route_type_for_transport(GameState.current_player().active_transport)


func _path_to_edge_polylines(path: Array, route_type: String = "") -> Array:
	var edges: Array = []
	if path.size() < 2:
		return edges
	for i in range(1, path.size()):
		var a := String(path[i - 1])
		var b := String(path[i])
		edges.append(_edge_curve_points(a, b, route_type))
	return edges


func _edge_curve_points(a: String, b: String, route_type: String = "") -> Array:
	var edge_id := _find_edge_id(a, b, route_type)
	if not edge_id.is_empty() and _cached_route_polylines.has(edge_id):
		var poly: PackedVector2Array = _cached_route_polylines[edge_id]
		var p0 := poly[0]
		var route_a := _node_route_pos(a, route_type) if not route_type.is_empty() else _node_pos(a)
		var route_b := _node_route_pos(b, route_type) if not route_type.is_empty() else _node_pos(b)
		if p0.distance_to(route_a) <= p0.distance_to(route_b):
			return _packed_to_array(poly)
		return _packed_to_array_reversed(poly)
	# fallback: dense straight
	var fallback_a := _node_route_pos(a, route_type) if not route_type.is_empty() else _node_pos(a)
	var fallback_b := _node_route_pos(b, route_type) if not route_type.is_empty() else _node_pos(b)
	return _sample_line(fallback_a, fallback_b)


func _find_edge_id(a: String, b: String, route_type: String = "") -> String:
	for edge in GameState.content.get("board_edges", []):
		var ea := String(edge.get("a", ""))
		var eb := String(edge.get("b", ""))
		if (
			((ea == a and eb == b) or (ea == b and eb == a))
			and (route_type.is_empty() or String(edge.get("route_type", "")) == route_type)
		):
			return String(edge.get("id", ""))
	return ""


func _packed_to_array(poly: PackedVector2Array) -> Array:
	var out: Array = []
	for p in poly:
		out.append(p)
	return out


func _packed_to_array_reversed(poly: PackedVector2Array) -> Array:
	var out: Array = []
	for i in range(poly.size() - 1, -1, -1):
		out.append(poly[i])
	return out


func _sample_line(a: Vector2, b: Vector2) -> Array:
	var out: Array = [a]
	var dist := a.distance_to(b)
	var n := maxi(int(ceil(dist / SAMPLE_SPACING_PX)), 1)
	for i in range(1, n + 1):
		out.append(a.lerp(b, float(i) / float(n)))
	return out


func _sample_curve_dense(ctrl: Array) -> PackedVector2Array:
	# 先高密度参数采样，再按弧长重采样到约 2px。
	var dense: Array = []
	var param_n := maxi(ctrl.size() * 24, 48)
	for i in param_n + 1:
		dense.append(_bezier(ctrl, float(i) / float(param_n)))
	var out := PackedVector2Array()
	out.append(dense[0])
	var acc := 0.0
	for i in range(1, dense.size()):
		var d: float = dense[i - 1].distance_to(dense[i])
		acc += d
		if acc >= SAMPLE_SPACING_PX or i == dense.size() - 1:
			out.append(dense[i])
			acc = 0.0
	# 强制端点贴合控制点首尾（节点中心）
	if ctrl.size() >= 2:
		out[0] = Vector2(float(ctrl[0][0]), float(ctrl[0][1]))
		out[out.size() - 1] = Vector2(float(ctrl[ctrl.size() - 1][0]), float(ctrl[ctrl.size() - 1][1]))
	return out


func _bezier(ctrl: Array, t: float) -> Vector2:
	var pts: Array = []
	for p in ctrl:
		pts.append(Vector2(float(p[0]), float(p[1])))
	while pts.size() > 1:
		var next: Array = []
		for i in range(pts.size() - 1):
			next.append(pts[i].lerp(pts[i + 1], t))
		pts = next
	return pts[0]


func _draw_route_shadows() -> void:
	_draw_all_routes(true)


func _draw_routes() -> void:
	_draw_all_routes(false)
	if selected_path.size() > 1:
		var edges := _path_to_edge_polylines(selected_path, _current_route_type())
		for edge_pts in edges:
			var poly := PackedVector2Array()
			for p in edge_pts:
				poly.append(p)
			_draw_polyline_solid(_route_layer, poly, COLOR_PATH, 4.2)


func _draw_all_routes(as_shadow: bool) -> void:
	if GameState.content.is_empty():
		return
	# Formal mode uses the PXD-derived pure terrain raster.  Routes are an actual
	# runtime layer, not pixels baked into the background.
	var canvas := _route_shadow_layer if as_shadow else _route_layer
	for route in _presentation.get("routes", []):
		var edge_id := String(route.get("edge_id", ""))
		var poly: PackedVector2Array = _cached_route_polylines.get(edge_id, PackedVector2Array())
		if poly.size() < 2:
			continue
		var is_land := String(route.get("route_type", "LAND")) == "LAND"
		if as_shadow:
			var shadow := COLOR_LAND_SHADOW if is_land else COLOR_SEA_SHADOW
			_draw_dashed_along_polyline(canvas, poly, shadow, 4.8, 7.5, 4.5, Vector2(0.8, 1.0))
		else:
			var color := COLOR_LAND_DASH if is_land else COLOR_SEA_DASH
			_draw_dashed_along_polyline(canvas, poly, color, 3.7, 7.5, 4.5, Vector2.ZERO)


func _draw_dashed_along_polyline(
	canvas: CanvasItem,
	poly: PackedVector2Array,
	color: Color,
	width: float,
	dash: float,
	gap: float,
	offset: Vector2
) -> void:
	if poly.size() < 2:
		return
	# 沿折线逐段推进 dash 相位，保证跨段连续且绝不空转。
	var remaining := dash
	var drawing := true
	for i in range(1, mini(poly.size(), 2048)):
		var a: Vector2 = poly[i - 1] + offset
		var b: Vector2 = poly[i] + offset
		var seg_len := a.distance_to(b)
		if seg_len < 0.001:
			continue
		var dir := (b - a) / seg_len
		var cursor := 0.0
		while cursor < seg_len:
			var take := mini(remaining, seg_len - cursor)
			if take < 0.001:
				# 切换 dash/gap，并保证至少推进一点，避免空转
				drawing = not drawing
				remaining = dash if drawing else gap
				take = mini(remaining, seg_len - cursor)
				if take < 0.001:
					break
			var p0 := a + dir * cursor
			var p1 := a + dir * (cursor + take)
			if drawing:
				_draw_round_dash(canvas, p0, p1, color, width)
			cursor += take
			remaining -= take
			if remaining < 0.001:
				drawing = not drawing
				remaining = dash if drawing else gap


func _draw_round_dash(canvas: CanvasItem, a: Vector2, b: Vector2, color: Color, width: float) -> void:
	canvas.draw_line(a, b, color, width, true)
	var r := width * 0.5
	canvas.draw_circle(a, r, color)
	canvas.draw_circle(b, r, color)


func _draw_polyline_solid(canvas: CanvasItem, poly: PackedVector2Array, color: Color, width: float) -> void:
	for i in range(1, poly.size()):
		canvas.draw_line(poly[i - 1], poly[i], color, width, true)


func _draw_node_shadows() -> void:
	if GameState.content.is_empty():
		return
	for node_id in GameState.content["board_nodes"]:
		for anchor in _node_visual_anchors(String(node_id)):
			var pos: Vector2 = anchor.get("position", Vector2.ZERO)
			_draw_ellipse_filled(_node_shadow_layer, pos + Vector2(0.8, 1.2), NODE_OUTER * 0.55, Color(0, 0, 0, 0.22))


func _draw_nodes() -> void:
	if GameState.content.is_empty():
		return
	for node_id in GameState.content["board_nodes"]:
		for anchor in _node_visual_anchors(String(node_id)):
			var pos: Vector2 = anchor.get("position", Vector2.ZERO)
			var is_sea := String(anchor.get("route_type", "LAND")) == "SEA"
			var mid := SEA_NODE_MID if is_sea else LAND_NODE_MID
			var inner := SEA_NODE_INNER if is_sea else LAND_NODE_INNER
			var stroke := SEA_NODE_STROKE if is_sea else LAND_NODE_STROKE
			_draw_ellipse_filled(_node_layer, pos, NODE_OUTER * 0.5, mid)
			_draw_ellipse_outline(_node_layer, pos, NODE_OUTER * 0.5, stroke, 1.6)
			_draw_ellipse_filled(_node_layer, pos, NODE_INNER * 0.5, inner)


func _draw_ellipse_filled(canvas: CanvasItem, center: Vector2, radii: Vector2, color: Color) -> void:
	var pts := PackedVector2Array()
	var n := 28
	for i in n:
		var ang := TAU * float(i) / float(n)
		pts.append(center + Vector2(cos(ang) * radii.x, sin(ang) * radii.y))
	canvas.draw_colored_polygon(pts, color)


func _draw_ellipse_outline(canvas: CanvasItem, center: Vector2, radii: Vector2, color: Color, width: float) -> void:
	var prev := center + Vector2(radii.x, 0)
	var n := 28
	for i in range(1, n + 1):
		var ang := TAU * float(i) / float(n)
		var p := center + Vector2(cos(ang) * radii.x, sin(ang) * radii.y)
		canvas.draw_line(prev, p, color, width, true)
		prev = p


func _draw_highlights() -> void:
	if GameState.content.is_empty():
		return
	var pulse := 0.55 + 0.45 * sin(_pulse_t * 3.0)
	_draw_hover_preview(pulse)
	for node_id in legal_nodes:
		if String(node_id) == _current_node_id():
			continue
		var pos := _interaction_node_pos(String(node_id))
		# 仅外圈呼吸光，不遮挡 PXD 节点本体
		_draw_ellipse_outline(
			_highlight_layer,
			pos,
			Vector2(12.0 + 2.0 * pulse, 10.0 + 1.5 * pulse),
			Color(COLOR_HIGHLIGHT.r, COLOR_HIGHLIGHT.g, COLOR_HIGHLIGHT.b, 0.35 + 0.25 * pulse),
			2.0
		)
	var cur := _current_node_id()
	if not cur.is_empty():
		_draw_ellipse_outline(_highlight_layer, _interaction_node_pos(cur), Vector2(13.0, 10.5), Color("c58b32"), 2.0)
	if selected_path.size() > 0:
		var dest := String(selected_path[selected_path.size() - 1])
		if dest != cur:
			_draw_ellipse_outline(_highlight_layer, _interaction_node_pos(dest), Vector2(14.0, 11.5), Color("c45c2a", 0.9), 2.2)
		elif selected_path.size() == 1:
			# 选了「原地停留」（GameScreen 先选再确认）：自己脚下套一圈选中色
			_draw_ellipse_outline(_highlight_layer, _interaction_node_pos(cur), Vector2(16.0, 13.0), Color("c45c2a", 0.9), 2.2)


func _draw_hover_preview(pulse: float) -> void:
	if _hover_node.is_empty() or _hover_path.is_empty():
		return
	# 宽而柔的底光 + 清晰金线，预览当前 hover 目的地的实际最短路径。
	if _hover_path.size() > 1:
		for edge_pts in _path_to_edge_polylines(_hover_path, _current_route_type()):
			var poly := PackedVector2Array()
			for p in edge_pts:
				poly.append(p)
			_draw_polyline_solid(_highlight_layer, poly, Color(HOVER_GOLD, 0.10 + pulse * 0.05), 12.0)
			_draw_polyline_solid(_highlight_layer, poly, Color(HOVER_GOLD, 0.22 + pulse * 0.08), 6.5)
			_draw_polyline_solid(_highlight_layer, poly, Color("fff1b8", 0.88), 2.5)
	var pos := _interaction_node_pos(_hover_node)
	var scale_pulse := 1.0 + pulse * 0.10
	_draw_ellipse_filled(
		_highlight_layer,
		pos,
		Vector2(19.0, 15.5) * scale_pulse,
		Color(HOVER_GOLD, 0.12 + pulse * 0.08)
	)
	_draw_ellipse_outline(
		_highlight_layer,
		pos,
		Vector2(16.0, 13.0) * scale_pulse,
		Color("fff1b8", 0.90),
		2.4
	)


func _current_node_id() -> String:
	if GameState.players.is_empty() or not GameState.is_in_turn():
		return ""
	return GameState.current_player().current_node_id


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMagnifyGesture:
		var mag := event as InputEventMagnifyGesture
		_zoom_at_screen(get_local_mouse_position(), mag.factor)
		accept_event()
		return
	if event is InputEventPanGesture:
		var pan := event as InputEventPanGesture
		_camera.pan_by_screen_delta(pan.delta)
		_apply_camera_transform()
		accept_event()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at_screen(mb.position, MapCameraController.WHEEL_ZOOM_STEP)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at_screen(mb.position, 1.0 / MapCameraController.WHEEL_ZOOM_STEP)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_begin_pan(mb.position, true)
			else:
				_end_pan()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var pointer_target := _pointer_target_at(mb.position)
				var target_kind := String(pointer_target.get("kind", ""))
				# 城市图鉴在非选路阶段始终可查（包括 AI 回合）；普通路线节点仍只在
				# 可输入的选路阶段响应。释放时才真正派发，拖动不会误触。
				if (
					target_kind == "city"
					or (target_kind == "node" and input_enabled and not animating)
				):
					_pending_node_click = true
					_pan_start_screen = mb.position
					_pan_pressed = false
				else:
					_pending_node_click = false
					_begin_pan(mb.position, false)
			else:
				if _pending_node_click:
					if mb.position.distance_to(_pan_start_screen) <= PAN_DRAG_THRESHOLD_PX:
						var pointer_target := _pointer_target_at(mb.position)
						var target_id := String(pointer_target.get("id", ""))
						match String(pointer_target.get("kind", "")):
							"node":
								if not target_id.is_empty() and input_enabled and not animating:
									node_clicked.emit(target_id)
							"city":
								if not _selection_mode and not target_id.is_empty():
									city_inspect_requested.emit(target_id)
					_pending_node_click = false
				elif _pan_pressed:
					if not _pan_moved and input_enabled and not animating:
						var node_id2 := (
							_legal_node_at(mb.position) if _selection_mode else _node_at(mb.position)
						)
						if not node_id2.is_empty():
							node_clicked.emit(node_id2)
					_end_pan()
			return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _pan_pressed:
			var drag := mm.position - _pan_start_screen
			if not _pan_moved and drag.length() >= PAN_DRAG_THRESHOLD_PX:
				_pan_moved = true
				_pan_active = true
				mouse_default_cursor_shape = Control.CURSOR_DRAG
			if _pan_active:
				_camera.pan_by_screen_delta(mm.position - _pan_last_screen)
				_pan_last_screen = mm.position
				_apply_camera_transform()
				accept_event()
				return
		_update_hover(mm.position)


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		match key.keycode:
			KEY_EQUAL, KEY_KP_ADD:
				_zoom_at_screen(size * 0.5, MapCameraController.WHEEL_ZOOM_STEP)
				get_viewport().set_input_as_handled()
			KEY_MINUS, KEY_KP_SUBTRACT:
				_zoom_at_screen(size * 0.5, 1.0 / MapCameraController.WHEEL_ZOOM_STEP)
				get_viewport().set_input_as_handled()
			KEY_R, KEY_HOME:
				reset_camera_to_fit()
				get_viewport().set_input_as_handled()


func _zoom_at_screen(screen_point: Vector2, factor: float) -> void:
	var target := clampf(_camera.zoom_factor * factor, _camera.min_zoom, _camera.max_zoom)
	if absf(target - _camera.zoom_factor) < 0.0001:
		return
	if _zoom_tween != null:
		_zoom_tween.kill()
	var start_zoom := _camera.zoom_factor
	_zoom_tween = create_tween()
	_zoom_tween.set_ease(Tween.EASE_OUT)
	_zoom_tween.set_trans(Tween.TRANS_QUAD)
	_zoom_tween.tween_method(
		func(z: float) -> void:
			_camera.set_zoom_around_screen_point(z, screen_point)
			_apply_camera_transform(),
		start_zoom,
		target,
		MapCameraController.ZOOM_TWEEN_SEC
	)


## 测试/调试：无补间立即缩放到绝对 zoom_factor（相对当前 fit）。
func zoom_immediate_around(screen_point: Vector2, absolute_zoom: float) -> void:
	if _zoom_tween != null:
		_zoom_tween.kill()
	_camera.set_zoom_around_screen_point(absolute_zoom, screen_point)
	_apply_camera_transform()


func _begin_pan(screen_pos: Vector2, force: bool) -> void:
	_pan_pressed = true
	_pan_from_blank = not force
	_pan_active = force
	_pan_moved = force
	_pan_start_screen = screen_pos
	_pan_last_screen = screen_pos
	if force:
		mouse_default_cursor_shape = Control.CURSOR_DRAG


func _end_pan() -> void:
	_pan_pressed = false
	_pan_active = false
	_pan_moved = false
	_pan_from_blank = false
	mouse_default_cursor_shape = Control.CURSOR_ARROW


func _update_hover(screen_pos: Vector2) -> void:
	# 城市市集牌是只读预览：即使非移动阶段、AI 等待或输入锁定也可看。
	# 真正的路线高亮/点击仍只受 legal_nodes + input_enabled 控制。
	if _pan_active:
		return
	var city_id := _city_at(screen_pos)
	var legal_node_id := _legal_node_at(screen_pos) if _selection_mode else ""
	var node_id := legal_node_id if not legal_node_id.is_empty() else _node_at(screen_pos)
	var path_preview_allowed := (
		input_enabled
		and not animating
		and legal_nodes.has(node_id)
		and node_id != _current_node_id()
	)
	# During movement selection a legal stop always wins over a nearby city art
	# hitbox.  Outside selection the city keeps its read-only market/lore hover.
	var target := node_id if path_preview_allowed else city_id
	_set_hover_target(target)
	if not city_id.is_empty() and not path_preview_allowed:
		_show_city_trade_card(city_id)
		_tooltip.visible = false
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if path_preview_allowed else Control.CURSOR_ARROW
		return
	_hide_city_trade_card()
	if target.is_empty():
		_tooltip.visible = false
		mouse_default_cursor_shape = Control.CURSOR_ARROW
		return
	_tooltip.visible = true
	_tooltip.text = _hover_label(node_id)
	_tooltip.position = screen_pos + Vector2(12, 8)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _set_hover_target(node_id: String) -> void:
	if node_id == _hover_node:
		return
	_hover_node = node_id
	_hover_path = []
	if not node_id.is_empty() and legal_nodes.has(node_id) and input_enabled and not animating and not GameState.players.is_empty() and GameState.is_in_turn():
		var player := GameState.current_player()
		_hover_path = MovementSystem.find_path(player, node_id, player.movement_budget)
	if _highlight_layer:
		_highlight_layer.queue_redraw()


func _clear_hover() -> void:
	_set_hover_target("")
	_hide_city_trade_card()
	if _tooltip:
		_tooltip.visible = false
	mouse_default_cursor_shape = Control.CURSOR_ARROW


func _hover_label(node_id: String) -> String:
	var steps := int(legal_nodes.get(node_id, maxi(_hover_path.size() - 1, 0)))
	if GameData.is_city_node(GameState.content, node_id):
		var city: Dictionary = GameState.content.get("cities", {}).get(node_id, {})
		return "%s · %d 步" % [String(city.get("display_name", node_id)), steps]
	return "途经节点 · %d 步" % steps


func _update_city_hover_visuals(delta: float) -> void:
	var weight := 1.0 - exp(-HOVER_RESPONSE * delta)
	for city_id in _city_visuals:
		var entry: Dictionary = _city_visuals[city_id]
		var root: Node2D = entry.get("root")
		if not is_instance_valid(root):
			continue
		var active := String(city_id) == _hover_node
		var hover: WorldMapCityHoverOverlay = entry.get("hover_overlay")
		if is_instance_valid(hover):
			hover.set_hovered(active)
			# The calibrated overlay owns formal hover size/motion.  Scaling the
			# static root again would reintroduce the oversized double-city bug.
			root.scale = Vector2.ONE
			root.modulate = Color.WHITE
			root.z_index = 0
			continue
		var target_factor := HOVER_CITY_SCALE if active else 1.0
		var target_position: Vector2 = entry.get("render_bottom_center", root.position)
		if active:
			target_position.y -= HOVER_CITY_LIFT
		var current_factor := root.scale.x
		var next_factor := lerpf(current_factor, target_factor, weight)
		root.scale = Vector2(next_factor, next_factor)
		root.position = root.position.lerp(target_position, weight)
		# 只提亮 RGB，alpha 永远为 1。
		var lit := Color(1.08, 1.05, 0.94, 1.0) if active else Color.WHITE
		var m := root.modulate.lerp(lit, weight)
		m.a = 1.0
		root.modulate = m
		root.z_index = 3 if active else 0


func get_hover_debug_state() -> Dictionary:
	var city_scale := 1.0
	if _city_visuals.has(_hover_node):
		var root: Node2D = _city_visuals[_hover_node].get("root")
		if is_instance_valid(root):
			city_scale = root.scale.x
	return {
		"node_id": _hover_node,
		"path": _hover_path.duplicate(),
		"is_city": not _hover_node.is_empty() and GameData.is_city_node(GameState.content, _hover_node),
		"city_scale": city_scale,
	}


func _node_at(screen_pos: Vector2) -> String:
	if _stage == null or GameState.content.is_empty():
		return ""
	var best := ""
	var best_d := HIT_RADIUS_SCREEN_PX
	for node_id in GameState.content.get("board_nodes", {}):
		for anchor in _node_visual_anchors(String(node_id)):
			var screen := world_to_screen(anchor.get("position", Vector2.ZERO))
			var d := screen_pos.distance_to(screen)
			if d < best_d:
				best_d = d
				best = String(node_id)
	return best


func _legal_node_at(screen_pos: Vector2) -> String:
	if _stage == null or GameState.content.is_empty() or legal_nodes.is_empty():
		return ""
	var best := ""
	var best_d := LEGAL_HIT_RADIUS_SCREEN_PX
	for node_id_value in legal_nodes.keys():
		var node_id := String(node_id_value)
		if node_id == _current_node_id():
			continue
		var d := screen_pos.distance_to(world_to_screen(_interaction_node_pos(node_id)))
		if d < best_d:
			best_d = d
			best = node_id
	return best


func _pointer_target_at(screen_pos: Vector2) -> Dictionary:
	# Legal route stops get first refusal in selection mode.  This is the core
	# interaction contract: decorative city art may never swallow a legal stop.
	if _selection_mode and input_enabled and not animating:
		var legal_node := _legal_node_at(screen_pos)
		if not legal_node.is_empty():
			return {"kind": "node", "id": legal_node}

	var city_id := _city_at(screen_pos)
	if not city_id.is_empty():
		if _selection_mode and input_enabled and not animating and legal_nodes.has(city_id):
			return {"kind": "node", "id": city_id}
		return {"kind": "city", "id": city_id}

	var node_id := _node_at(screen_pos)
	if not node_id.is_empty():
		return {"kind": "node", "id": node_id}
	return {}


func _city_at(screen_pos: Vector2) -> String:
	if _stage == null or _city_visuals.is_empty():
		return ""
	# 红匾是独立的屏幕 UI，可能比建筑热区更靠下；先按它的真实屏幕矩形命中，
	# 避免沿海城市（泉州/广州）的名牌点击落到建筑逻辑包围盒之外。
	for city_id in _city_visuals:
		if _plaque_screen_rect(String(city_id)).has_point(screen_pos):
			return String(city_id)
	var local := screen_to_world(screen_pos)
	var best := ""
	var best_score := INF
	for city_id in _city_visuals:
		var entry: Dictionary = _city_visuals[city_id]
		var visible_rect: Rect2 = entry.get("visible_building_rect", Rect2())
		if visible_rect.size == Vector2.ZERO:
			var base: Vector2 = entry.get("base_position", Vector2.ZERO)
			var building_size: Vector2 = entry.get("building_size", Vector2(72, 72))
			visible_rect = Rect2(base - building_size * 0.5, building_size)
		# Six screen pixels provide a forgiving city target without recreating
		# the former 3× transparent-canvas hitbox.
		var grow_world := 6.0 / maxf(_camera.render_scale(), 0.001)
		var hit_rect := visible_rect.grow(grow_world)
		if hit_rect.has_point(local):
			var score := local.distance_squared_to(visible_rect.get_center())
			if score < best_score:
				best_score = score
				best = String(city_id)
	return best


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


## direction = 气泡相对城市的方位；箭头素材始终指向城市。
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


## 扫描纹理 alpha>threshold 的像素包围盒（纹理像素坐标，左闭右开）。
func _texture_opaque_bbox(tex: Texture2D, alpha_threshold: int = 32) -> Rect2:
	if tex == null:
		return Rect2()
	var img: Image = tex.get_image()
	if img == null:
		return Rect2()
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a * 255.0 > float(alpha_threshold):
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	if max_x < min_x or max_y < min_y:
		return Rect2(0, 0, w, h)
	return Rect2(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


## 可见建筑世界矩形（逻辑坐标），由 Sprite2D centered + scale + alpha 包围盒推导。
func _compute_visible_building_world_rect(root_pos: Vector2, spr: Sprite2D) -> Rect2:
	if spr == null or spr.texture == null:
		return Rect2(root_pos - Vector2(36, 36), Vector2(72, 72))
	var tex: Texture2D = spr.texture
	var bbox := _texture_opaque_bbox(tex, 32)
	var tex_w := float(tex.get_width())
	var tex_h := float(tex.get_height())
	var sc: Vector2 = spr.scale
	var top_left := root_pos + Vector2(
		(bbox.position.x - tex_w * 0.5) * sc.x,
		(bbox.position.y - tex_h * 0.5) * sc.y
	) + spr.position
	var vis_size := Vector2(bbox.size.x * sc.x, bbox.size.y * sc.y)
	return Rect2(top_left, vis_size)


## 目标城市可见建筑的屏幕矩形（基于 alpha 缓存，非 building_size 留白框）。
func _city_building_screen_rect(city_id: String) -> Rect2:
	var world := Rect2()
	if _city_visuals.has(city_id):
		world = _city_visuals[city_id].get("visible_building_rect", Rect2())
	if world.size == Vector2.ZERO:
		var city_logical: Vector2 = _node_pos(city_id)
		var bsize := Vector2(72, 72)
		if _city_visuals.has(city_id):
			city_logical = _city_visuals[city_id].get("base_position", city_logical)
			bsize = _city_visuals[city_id].get("building_size", bsize)
		world = Rect2(city_logical - bsize * 0.5, bsize)
	var tl := logical_to_screen(world.position)
	var br := logical_to_screen(world.end)
	return Rect2(tl, br - tl)


func _trade_bubble_safe_rect() -> Rect2:
	var margin := 8.0
	var w := maxf(1.0, size.x - _right_safe_inset - margin * 2.0)
	var h := maxf(1.0, size.y - margin * 2.0)
	return Rect2(Vector2(margin, margin), Vector2(w, h))


func _plaque_screen_rect(city_id: String) -> Rect2:
	if not _city_visuals.has(city_id):
		return Rect2()
	var root: Node2D = _city_visuals[city_id].get("root")
	if not is_instance_valid(root):
		return Rect2()
	var plaque: Control = root.get_node_or_null("CityPlaque")
	if plaque == null:
		return Rect2()
	# 逻辑坐标换算，避免 get_global_rect 首帧未就绪。
	var world_tl: Vector2 = root.position + plaque.position
	var world_br: Vector2 = world_tl + plaque.size
	var tl := logical_to_screen(world_tl)
	var br := logical_to_screen(world_br)
	return Rect2(tl, br - tl)


## 全图硬避让：七城可见建筑 + 七城红匾 + 棋子（BoardView 本地坐标）。
func _trade_bubble_occlusion_rects(_target_city_id: String = "") -> Array:
	var rects: Array = []
	for city_id in _city_visuals.keys():
		var building := _city_building_screen_rect(String(city_id))
		if building.size.x > 0.0 and building.size.y > 0.0:
			rects.append(building)
		var plaque := _plaque_screen_rect(String(city_id))
		if plaque.size.x > 0.0 and plaque.size.y > 0.0:
			rects.append(plaque)
	for piece in _pieces.values():
		if not is_instance_valid(piece):
			continue
		var pp: Vector2 = logical_to_screen((piece as Node2D).position)
		rects.append(Rect2(pp - Vector2(14, 18), Vector2(28, 36)))
	return rects


func _rect_overlap_area(a: Rect2, b: Rect2) -> float:
	if not a.intersects(b):
		return 0.0
	return a.intersection(b).get_area()


func _body_hard_occludes(body_rect: Rect2, arrow_rect: Rect2, target_city_id: String) -> bool:
	var target_building := _city_building_screen_rect(target_city_id)
	for city_id in _city_visuals.keys():
		var cid := String(city_id)
		var building := _city_building_screen_rect(cid)
		if _rect_overlap_area(body_rect, building) > 0.5:
			return true
		# 箭头可跨空白，但不得穿过其他城市建筑。
		if cid != target_city_id and _rect_overlap_area(arrow_rect, building) > 0.5:
			return true
		var plaque := _plaque_screen_rect(cid)
		if _rect_overlap_area(body_rect, plaque) > 0.5:
			return true
	for piece in _pieces.values():
		if not is_instance_valid(piece):
			continue
		var pp: Vector2 = logical_to_screen((piece as Node2D).position)
		var piece_rect := Rect2(pp - Vector2(14, 18), Vector2(28, 36))
		if _rect_overlap_area(body_rect, piece_rect) > 0.5:
			return true
	# 主体亦不得压住目标建筑本体。
	if _rect_overlap_area(body_rect, target_building) > 0.5:
		return true
	return false


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
		"score": (0.0 if fits else 1_000_000.0) + dist + slide_cost + float(priority) * 0.01,
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
	if _city_trade_card == null or _stage == null:
		return
	var city_changed := city_id != _city_trade_card_city_id
	var content_signature := _trade_card_content_signature(city_id)
	var content_changed := city_changed or content_signature != _city_trade_card_content_signature
	var was_visible := _city_trade_card.visible
	if content_changed:
		_rebuild_city_trade_card_content(city_id)
		_city_trade_card_city_id = city_id
		_city_trade_card_content_signature = content_signature

	var layout := _pick_trade_bubble_layout(city_id)
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
		for cid in _city_visuals.keys():
			var area := _rect_overlap_area(body, _city_building_screen_rect(String(cid)))
			area += _rect_overlap_area(body, _plaque_screen_rect(String(cid)))
			overlaps[String(cid)] = area
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
