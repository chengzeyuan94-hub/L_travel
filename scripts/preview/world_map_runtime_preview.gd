extends Control
class_name WorldMapRuntimePreview

## TASK-WORLD-MAP-RUNTIME-002: independent 16-city map runtime preview.
## Does not write GameState / Dice / Trade / Event. Does not read docs/.

const MOVE_DURATION_SEC := 3.0
const MAX_ZOOM_MULT := 3.5
const MIN_HIT_SCREEN_PX := 44.0
const LAND_COLOR := Color(0.95, 0.78, 0.28, 0.95)
const SEA_COLOR := Color(0.25, 0.78, 0.95, 0.95)
const ROUTE_OUTLINE_COLOR := Color(0.12, 0.09, 0.05, 0.92)
const ROUTE_OUTER_SCREEN_PX := 5.0
const ROUTE_INNER_SCREEN_PX := 3.0
const STOP_HOVER_LAND := Color(1.0, 0.85, 0.35, 0.85)
const STOP_HOVER_SEA := Color(0.35, 0.85, 1.0, 0.85)
const STATUS_MSG_SEC := 2.2
const DRAG_THRESHOLD_PX := 8.0
const FOCUS_TWEEN_SEC := 0.30
const PAN_GESTURE_RELEASE_SEC := 0.12

signal move_finished(from_id: String, to_id: String)
signal hover_city_changed(city_id: String)
## Presentation-only city inspection request. The emitted id is always the
## formal ruleset id (for example ancient_rome -> rome), never a topology alias.
signal city_inspect_requested(city_id: String)

## Set BEFORE add_child / _ready. Enables overscan texture + 0.8–1.5 half-view camera.
var hud_half_view_mode := false

var _camera := MapCameraController.new()
var _bundle: Dictionary = {}
var _stops_by_id: Dictionary = {}
var _cities_by_id: Dictionary = {}
var _adjacency: Dictionary = {}
var _edges: Array = []

var _clip: Control
var _stage: Node2D
var _map_sprite: Sprite2D
var _route_layer: Node2D
var _stop_layer: Node2D
var _city_layer: Node2D
var _piece_layer: Node2D
var _hud: Control
var _status: Label
var _info: Label
var _transport_btn: Button

var _city_overlays: Dictionary = {} # city_id -> WorldMapCityHoverOverlay
var _stop_rings: Dictionary = {} # stop_id -> Polygon2D
var _highlight_outers: Array = [] # pooled Line2D (screen-constant outline)
var _highlight_inners: Array = [] # pooled Line2D (screen-constant fill)
var _piece: WorldMapPreviewPiece

var _selected_stop := ""
var _hovered_stop := ""
var _hovered_city := ""
var _preview_transport: int = GameData.Transport.CAMEL
var _panning := false
var _pan_last := Vector2.ZERO
var _status_ttl := 0.0
var _node_count_baseline := 0
var _moving := false
var _pulse_destinations: Dictionary = {} # stop_id -> true
var _pulse_t := 0.0
var _last_move_reject_reason := ""
var _camera_input_enabled := true
var _press_pos := Vector2.ZERO
var _press_active := false
var _drag_armed := false
var _press_hit_city := ""
var _press_hit_stop := ""
var _focus_city_id := "yumenguan"
var _elastic_tween: Tween
var _focus_tween: Tween
var _pan_release_timer: Timer
var _focus_safe_rect := Rect2()
var _external_safe_view := Rect2()
## The standalone topology preview keeps its original click-to-move behaviour.
## HUD/game presentation hosts explicitly turn this off outside route selection.
var _route_selection_active := true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_pan_release_timer = Timer.new()
	_pan_release_timer.name = "PanGestureReleaseTimer"
	_pan_release_timer.one_shot = true
	_pan_release_timer.wait_time = PAN_GESTURE_RELEASE_SEC
	_pan_release_timer.timeout.connect(_release_elastic)
	add_child(_pan_release_timer)
	_bundle = WorldMapRuntimeLoader.load_bundle()
	if not bool(_bundle.get("ok", false)):
		_set_status("LOAD FAILED: %s" % str(_bundle.get("errors", [])), 10.0)
		push_error("WorldMapRuntimePreview load failed: %s" % str(_bundle.get("errors", [])))
		return
	_ingest_bundle()
	_build_map_layers()
	_build_city_overlays()
	_build_stop_rings()
	_build_highlight_pool()
	_build_piece()
	# Do not connect camera_changed → apply: set_safe_view_rect emits camera_changed
	# and would recurse. Apply transform explicitly after every camera mutation.
	_reset_camera()
	_update_transport_btn()
	_node_count_baseline = _count_descendants()
	if hud_half_view_mode:
		if _hud != null:
			_hud.visible = false
		_set_status("正式地图半幅相机 · 0.8–1.5", 3.0)
	else:
		_set_status("世界地图预览 · 54 停靠 / 57 边 · 路线校准版", 4.0)


func _exit_tree() -> void:
	shutdown_preview()


func shutdown_preview() -> void:
	_panning = false
	_moving = false
	_kill_focus_tween()
	_kill_elastic_tween()
	if _pan_release_timer != null:
		_pan_release_timer.stop()
	for cid in _city_overlays.keys():
		var ov: WorldMapCityHoverOverlay = _city_overlays[cid]
		if ov != null:
			ov.kill_tweens()
			ov.set_hovered(false)
	if _piece != null and is_instance_valid(_piece):
		_piece.cancel_motion()
	if AudioManager != null:
		AudioManager.stop_piece_loop(false)
		AudioManager.silence_all()


func get_debug_state() -> Dictionary:
	var playing := 0
	for cid in _city_overlays.keys():
		var ov: WorldMapCityHoverOverlay = _city_overlays[cid]
		if ov.is_playing():
			playing += 1
	return {
		"ok": bool(_bundle.get("ok", false)),
		"errors": _bundle.get("errors", []),
		"cities": _cities_by_id.size(),
		"playable_stops": _stops_by_id.size(),
		"edges": _edges.size(),
		"aliases": (_bundle.get("stop_aliases", {}) as Dictionary).size(),
		"interchanges": (_bundle.get("interchange_city_ids", []) as Array).size(),
		"selected_stop": _selected_stop,
		"hovered_city": _hovered_city,
		"hovered_stop": _hovered_stop,
		"playing_city_anims": playing,
		"preview_transport": _preview_transport,
		"transport_btn_disabled": _transport_btn.disabled if _transport_btn != null else true,
		"can_manual_transport_switch": can_manual_transport_switch(),
		"last_move_reject_reason": _last_move_reject_reason,
		"moving": _moving,
		"camera": _camera.debug_state(),
		"camera_input_enabled": _camera_input_enabled,
		"route_selection_active": _route_selection_active,
		"descendant_count": _count_descendants(),
		"descendant_baseline": _node_count_baseline,
		"highlight_pool": _highlight_inners.size(),
		"route_screen_widths": measure_route_screen_widths(),
		"piece_screen_height": measure_piece_screen_height(),
		"piece_layer_scale": _piece_layer.scale if _piece_layer != null else Vector2.ZERO,
		"piece_alpha_manifest": _piece.get_alpha_bbox_manifest() if _piece != null else {},
		"topology_to_ruleset_city_id": _bundle.get("topology_to_ruleset_city_id", {}),
		"ruleset_to_topology_city_id": _bundle.get("ruleset_to_topology_city_id", {}),
		"projection_hash": _bundle.get("projection_hash", ""),
		"interchange_city_ids": _bundle.get("interchange_city_ids", []),
	}


func set_route_selection_active(active: bool) -> void:
	_route_selection_active = active
	if not active:
		_press_active = false
		_drag_armed = false
		_panning = false


func is_route_selection_active() -> bool:
	return _route_selection_active


func ruleset_city_id_for_topology(topology_city_id: String) -> String:
	var mapping: Dictionary = _bundle.get("topology_to_ruleset_city_id", {})
	return String(mapping.get(topology_city_id, ""))


func can_manual_transport_switch() -> bool:
	if _selected_stop == "" or not _stops_by_id.has(_selected_stop):
		return false
	return bool(_stops_by_id[_selected_stop].get("is_transport_interchange", false))


func measure_route_screen_widths() -> Dictionary:
	var s := maxf(_camera.render_scale(), 0.0001)
	var outer_w := 0.0
	var inner_w := 0.0
	var visible := 0
	for i in range(_highlight_inners.size()):
		var inner: Line2D = _highlight_inners[i]
		var outer: Line2D = _highlight_outers[i]
		if not inner.visible:
			continue
		visible += 1
		outer_w = outer.width * s
		inner_w = inner.width * s
		break
	return {"visible": visible, "outer_screen_px": outer_w, "inner_screen_px": inner_w}


func measure_piece_screen_height() -> float:
	if _piece == null or not _piece.visible:
		return 0.0
	return _piece.measure_screen_visible_height(_camera)


func expected_piece_screen_anchor() -> Vector2:
	if _piece == null:
		return Vector2.ZERO
	return _camera.world_to_screen(_piece.position)


func rendered_piece_screen_anchor() -> Vector2:
	if _piece == null:
		return Vector2.ZERO
	return _piece.rendered_screen_anchor(_camera)


func get_city_overlay(city_id: String) -> WorldMapCityHoverOverlay:
	return _city_overlays.get(city_id, null) as WorldMapCityHoverOverlay


func get_piece_world_position() -> Vector2:
	return _piece.position if _piece != null else Vector2.ZERO


func get_piece() -> WorldMapPreviewPiece:
	return _piece


func dispatch_mouse_motion(screen_pos: Vector2) -> void:
	## Test helper that enters through Viewport input dispatch. Do not call
	## _gui_input directly: that would bypass Control hit testing/mouse filters.
	var ev := InputEventMouseMotion.new()
	ev.position = screen_pos
	ev.global_position = screen_pos
	get_viewport().push_input(ev, false)


func city_screen_anchor(city_id: String) -> Vector2:
	if not _city_overlays.has(city_id):
		return Vector2.ZERO
	var ov: WorldMapCityHoverOverlay = _city_overlays[city_id]
	# Use the calibrated alpha-visible building, not the extraction rectangle with
	# transparent padding. This is the same target a player actually sees.
	return _camera.world_to_screen(_city_interaction_rect(ov).get_center())


func set_preview_transport(transport: int) -> void:
	_preview_transport = transport
	if _piece != null:
		_piece.set_transport(transport)
		_piece.apply_camera_visual_scale(_camera.render_scale())
		if not _selected_stop.is_empty():
			_place_piece_at_stop(_selected_stop)
	_refresh_selection_highlights()
	_update_transport_btn()


func set_city_hovered(city_id: String, value: bool) -> void:
	if value:
		_apply_city_hover(city_id)
	elif _hovered_city == city_id:
		_clear_city_hover()


func clear_selection() -> void:
	_selected_stop = ""
	_refresh_selection_highlights()


func select_stop(stop_id: String) -> void:
	if stop_id == "":
		clear_selection()
		return
	if not _stops_by_id.has(stop_id):
		return
	if _moving:
		return
	if _selected_stop == stop_id:
		clear_selection()
		_set_status("已取消选择", STATUS_MSG_SEC)
		return
	if _selected_stop == "":
		_selected_stop = stop_id
		_sync_transport_to_stop(stop_id)
		_place_piece_at_stop(stop_id)
		_refresh_selection_highlights()
		_set_status("起点：%s" % stop_id, STATUS_MSG_SEC)
		return
	_try_move(_selected_stop, stop_id)


func play_edge_preview(from_id: String, to_id: String) -> bool:
	return _try_move(from_id, to_id)


func reset_camera_to_fit() -> void:
	_reset_camera()


func zoom_immediate_around(screen_point: Vector2, zoom_factor: float) -> void:
	_kill_focus_tween()
	_camera.set_zoom_around_screen_point(zoom_factor, screen_point)
	_apply_camera_transform()


func pan_by_screen_delta(delta: Vector2) -> void:
	_kill_focus_tween()
	_camera.pan_by_screen_delta(delta)
	_apply_camera_transform()


func screen_to_world(screen: Vector2) -> Vector2:
	return _camera.screen_to_world(screen)


func world_to_screen(world: Vector2) -> Vector2:
	return _camera.world_to_screen(world)


func capture_viewport_image() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


func _build_ui() -> void:
	_clip = Control.new()
	_clip.name = "MapViewportClip"
	_clip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)

	_stage = Node2D.new()
	_stage.name = "CameraRoot"
	_clip.add_child(_stage)

	_hud = Control.new()
	_hud.name = "PreviewHUD"
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hud)

	_info = Label.new()
	_info.name = "HoverInfo"
	_info.position = Vector2(16, 16)
	_info.add_theme_font_size_override("font_size", 18)
	_info.add_theme_color_override("font_color", Color(0.95, 0.92, 0.82, 1))
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_info)

	_transport_btn = Button.new()
	_transport_btn.name = "TransportToggle"
	_transport_btn.text = "预览：骆驼"
	_transport_btn.position = Vector2(16, 48)
	_transport_btn.custom_minimum_size = Vector2(140, 36)
	_transport_btn.pressed.connect(_on_transport_pressed)
	_hud.add_child(_transport_btn)

	var hint := Label.new()
	hint.name = "Hints"
	hint.position = Vector2(16, 92)
	hint.text = "滚轮缩放 · 中键/拖空白平移 · +/- 缩放 · R/Home 全图 · 点击停靠点预览移动"
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8, 0.9))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(hint)

	_status = Label.new()
	_status.name = "DebugStatus"
	_status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_top = -36
	_status.offset_bottom = -8
	_status.offset_left = 16
	_status.offset_right = -16
	_status.add_theme_font_size_override("font_size", 15)
	_status.add_theme_color_override("font_color", Color(1, 0.95, 0.75, 1))
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)


func _ingest_bundle() -> void:
	_edges = _bundle.get("edges", [])
	_adjacency = WorldMapRuntimeLoader.build_adjacency(_edges)
	_stops_by_id.clear()
	for s in _bundle.get("stops", []):
		_stops_by_id[String(s.get("id", ""))] = s
	_cities_by_id.clear()
	for c in _bundle.get("cities", []):
		_cities_by_id[String(c.get("city_id", ""))] = c


func _build_map_layers() -> void:
	var tex_path := String(_bundle.get("map_texture_path", ""))
	var origin := Vector2.ZERO
	if hud_half_view_mode:
		var overscan := String(_bundle.get("map_texture_overscan_path", ""))
		if overscan != "" and ResourceLoader.exists(overscan):
			tex_path = overscan
			var origin_v: Variant = _bundle.get("map_texture_origin", Vector2(0, -184))
			if origin_v is Vector2:
				origin = origin_v
			elif origin_v is Array and (origin_v as Array).size() >= 2:
				origin = Vector2(float(origin_v[0]), float(origin_v[1]))
	var tex := load(tex_path) as Texture2D
	if tex == null:
		push_error("WorldMapRuntimePreview: failed to load map texture %s" % tex_path)
	_map_sprite = Sprite2D.new()
	_map_sprite.name = "MapTexture"
	_map_sprite.centered = false
	_map_sprite.texture = tex
	_map_sprite.position = origin
	_map_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_stage.add_child(_map_sprite)

	_route_layer = Node2D.new()
	_route_layer.name = "RouteInteractionLayer"
	_stage.add_child(_route_layer)

	_stop_layer = Node2D.new()
	_stop_layer.name = "StopInteractionLayer"
	_stage.add_child(_stop_layer)

	_city_layer = Node2D.new()
	_city_layer.name = "CityHoverAnimationLayer"
	_stage.add_child(_city_layer)

	_piece_layer = Node2D.new()
	_piece_layer.name = "PieceLayer"
	_stage.add_child(_piece_layer)

	var logic: Vector2 = _bundle.get("logic_size", WorldMapRuntimeLoader.LOGIC_SIZE)
	if hud_half_view_mode:
		var profile: Dictionary = _bundle.get("camera_profile", {})
		var bounds: Rect2 = _bundle.get("overscan_bounds", Rect2(0, -184, 4096, 1755))
		_camera.configure_half_view(profile, bounds, _current_safe_view())
	else:
		_camera.configure_from_presentation(
			{
				"logical_size": [logic.x, logic.y],
				"camera_min_zoom": 1.0,
				"camera_max_zoom": MAX_ZOOM_MULT,
			},
			logic
		)


func _build_city_overlays() -> void:
	for city in _bundle.get("cities", []):
		var ov := WorldMapCityHoverOverlay.new()
		ov.name = "CityHover_%s" % String(city.get("city_id", ""))
		ov.setup_from_city(city)
		_city_layer.add_child(ov)
		_city_overlays[String(city.get("city_id", ""))] = ov


func _build_stop_rings() -> void:
	for sid in _stops_by_id.keys():
		var stop: Dictionary = _stops_by_id[sid]
		var ring := Polygon2D.new()
		ring.name = "StopRing_%s" % sid
		ring.polygon = _ring_poly(10.0)
		ring.color = Color(1, 1, 1, 0)
		ring.position = WorldMapRuntimeLoader.stop_position(stop)
		ring.visible = true
		_stop_layer.add_child(ring)
		_stop_rings[sid] = ring


func _build_highlight_pool() -> void:
	for i in range(24):
		var outer := Line2D.new()
		outer.name = "HighlightOuter_%02d" % i
		outer.width = ROUTE_OUTER_SCREEN_PX
		outer.default_color = ROUTE_OUTLINE_COLOR
		outer.antialiased = true
		outer.visible = false
		outer.joint_mode = Line2D.LINE_JOINT_ROUND
		outer.begin_cap_mode = Line2D.LINE_CAP_ROUND
		outer.end_cap_mode = Line2D.LINE_CAP_ROUND
		outer.z_index = 0
		_route_layer.add_child(outer)
		_highlight_outers.append(outer)

		var inner := Line2D.new()
		inner.name = "HighlightInner_%02d" % i
		inner.width = ROUTE_INNER_SCREEN_PX
		inner.default_color = LAND_COLOR
		inner.antialiased = true
		inner.visible = false
		inner.joint_mode = Line2D.LINE_JOINT_ROUND
		inner.begin_cap_mode = Line2D.LINE_CAP_ROUND
		inner.end_cap_mode = Line2D.LINE_CAP_ROUND
		inner.z_index = 1
		_route_layer.add_child(inner)
		_highlight_inners.append(inner)


func _build_piece() -> void:
	_piece_layer.scale = Vector2.ONE
	_piece = WorldMapPreviewPiece.new()
	_piece.name = "PreviewPiece"
	_piece.setup("preview", true, _preview_transport)
	_piece.visible = false
	_piece.move_finished.connect(_on_piece_move_finished)
	_piece_layer.add_child(_piece)
	_piece.apply_camera_visual_scale(_camera.render_scale())


func _tune_piece_preview_scale() -> void:
	## Never scale PieceLayer (would warp world coords). VisualRoot only.
	if _piece_layer != null:
		_piece_layer.scale = Vector2.ONE
	if _piece == null:
		return
	_piece.apply_camera_visual_scale(_camera.render_scale())


func _reset_camera() -> void:
	_kill_focus_tween()
	_kill_elastic_tween()
	_camera.clear_elastic_offset()
	var safe := _current_safe_view()
	_camera.safe_view_rect = safe
	if _focus_safe_rect.size.x > 1.0:
		_camera.set_focus_safe_rect(_focus_safe_rect)
	else:
		_camera.set_focus_safe_rect(safe)
	if hud_half_view_mode:
		var focus := city_world_point(_focus_city_id)
		if focus == Vector2.INF:
			focus = city_world_point("yumenguan")
		_camera.reset_half_view_default(focus)
	else:
		var logic: Vector2 = _bundle.get("logic_size", WorldMapRuntimeLoader.LOGIC_SIZE)
		_camera.reset_to_fit(Rect2(Vector2.ZERO, logic))
	_apply_camera_transform()
	_tune_piece_preview_scale()


var _applying_camera := false


func _apply_camera_transform() -> void:
	if _stage == null or _applying_camera:
		return
	_applying_camera = true
	# Assign directly to avoid camera_changed re-entrancy via set_safe_view_rect.
	_camera.safe_view_rect = _current_safe_view()
	if _focus_safe_rect.size.x > 1.0:
		_camera.set_focus_safe_rect(_focus_safe_rect)
	var s := _camera.render_scale()
	_stage.scale = Vector2(s, s)
	_stage.position = _camera.stage_position()
	if _piece_layer != null:
		_piece_layer.scale = Vector2.ONE
	_apply_highlight_widths()
	_tune_piece_preview_scale()
	_applying_camera = false


func _current_safe_view() -> Rect2:
	## Camera math is always in this Control's local space.
	if _external_safe_view.size.x > 1.0:
		return _external_safe_view
	return Rect2(Vector2.ZERO, size)


func set_external_safe_view(rect_local: Rect2) -> void:
	_external_safe_view = rect_local
	_camera.set_safe_view_rect(rect_local)
	_apply_camera_transform()


func set_focus_safe_rect(rect_local: Rect2) -> void:
	_focus_safe_rect = rect_local
	_camera.set_focus_safe_rect(rect_local)


func set_camera_input_enabled(enabled: bool) -> void:
	_camera_input_enabled = enabled
	if not enabled:
		_kill_focus_tween()
		_panning = false
		_press_active = false
		_drag_armed = false


func set_focus_city_id(city_id: String) -> void:
	_focus_city_id = city_id


func focus_world_point(world_point: Vector2, animated: bool = true) -> void:
	_kill_focus_tween()
	_kill_elastic_tween()
	_camera.clear_elastic_offset()
	var target := _camera.focus_center_for_world_point(world_point)
	if not animated or _camera.camera_world_center.distance_to(target) < 0.05:
		_camera.set_world_center(target)
		_apply_camera_transform()
		return
	var start := _camera.camera_world_center
	_focus_tween = create_tween()
	_focus_tween.tween_method(_set_focus_center, start, target, FOCUS_TWEEN_SEC) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_focus_tween.finished.connect(func():
		_camera.set_world_center(target)
		_apply_camera_transform()
		_focus_tween = null
	)


func focus_city(city_id: String, animated: bool = true) -> void:
	var wp := city_world_point(city_id)
	if wp == Vector2.INF:
		return
	_focus_city_id = city_id
	focus_world_point(wp, animated)


func focus_active_piece(animated: bool = true) -> void:
	if _piece != null and _piece.visible:
		focus_world_point(_piece.position, animated)
		return
	focus_city(_focus_city_id, animated)


func reset_to_active_piece() -> void:
	focus_active_piece(true)


func city_world_point(city_id: String) -> Vector2:
	if city_id == "":
		return Vector2.INF
	if _cities_by_id.has(city_id):
		var city: Dictionary = _cities_by_id[city_id]
		var anchor: Array = city.get("piece_anchor_px", city.get("snapped_anchor_px", []))
		if anchor.size() >= 2:
			return Vector2(float(anchor[0]), float(anchor[1]))
	if _stops_by_id.has(city_id):
		return WorldMapRuntimeLoader.stop_position(_stops_by_id[city_id])
	return Vector2.INF


func get_camera() -> MapCameraController:
	return _camera


func is_focus_animating() -> bool:
	return _focus_tween != null and _focus_tween.is_valid()


func map_texture_origin() -> Vector2:
	if _map_sprite == null:
		return Vector2.ZERO
	return _map_sprite.position


func map_texture_path_loaded() -> String:
	if _map_sprite == null or _map_sprite.texture == null:
		return ""
	return String(_map_sprite.texture.resource_path)


func _apply_highlight_widths() -> void:
	var s := maxf(_camera.render_scale(), 0.0001)
	var outer_w := ROUTE_OUTER_SCREEN_PX / s
	var inner_w := ROUTE_INNER_SCREEN_PX / s
	for line in _highlight_outers:
		line.width = outer_w
	for line in _highlight_inners:
		line.width = inner_w


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_camera.set_safe_view_rect(_current_safe_view())
		_apply_camera_transform()
		_tune_piece_preview_scale()


func _process(delta: float) -> void:
	if _status_ttl > 0.0:
		_status_ttl -= delta
		if _status_ttl <= 0.0 and _status != null:
			_status.text = ""
	_pulse_t += delta
	_update_destination_pulse()


func _gui_input(event: InputEvent) -> void:
	if not _camera_input_enabled:
		return
	if event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		_kill_focus_tween()
		_camera.apply_zoom_step(mg.factor, mg.position)
		_apply_camera_transform()
		accept_event()
		return
	if event is InputEventPanGesture:
		var pg := event as InputEventPanGesture
		_kill_focus_tween()
		_kill_elastic_tween()
		_camera.pan_by_screen_delta(pg.delta)
		_apply_camera_transform()
		if _pan_release_timer != null:
			_pan_release_timer.start(PAN_GESTURE_RELEASE_SEC)
		accept_event()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_kill_focus_tween()
			_camera.apply_zoom_step(MapCameraController.WHEEL_ZOOM_STEP, mb.position)
			_apply_camera_transform()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_kill_focus_tween()
			_camera.apply_zoom_step(1.0 / MapCameraController.WHEEL_ZOOM_STEP, mb.position)
			_apply_camera_transform()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_kill_focus_tween()
			_panning = mb.pressed
			_pan_last = mb.position
			if not mb.pressed:
				_release_elastic()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press_active = true
				_drag_armed = false
				_press_pos = mb.position
				_pan_last = mb.position
				_press_hit_city = _city_at(mb.position)
				_press_hit_stop = _stop_at(mb.position)
			else:
				if _press_active and not _drag_armed and not _panning:
					_handle_click(mb.position)
				_press_active = false
				_drag_armed = false
				_panning = false
				_release_elastic()
			accept_event()
			return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning or (mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0:
			_kill_focus_tween()
			_camera.pan_by_screen_delta(mm.position - _pan_last)
			_pan_last = mm.position
			_apply_camera_transform()
			accept_event()
			return
		if _press_active and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			var dist := mm.position.distance_to(_press_pos)
			if not _drag_armed and dist >= DRAG_THRESHOLD_PX:
				# Convert to drag only when press started on empty map, or after threshold.
				if _press_hit_city == "" and _press_hit_stop == "":
					_drag_armed = true
					_panning = true
				elif dist >= DRAG_THRESHOLD_PX:
					# Cancel click on interactive target once dragged past threshold.
					_drag_armed = true
					_panning = true
			if _panning or _drag_armed:
				_kill_focus_tween()
				_camera.pan_by_screen_delta(mm.position - _pan_last)
				_pan_last = mm.position
				_apply_camera_transform()
				accept_event()
				return
		_update_hover(mm.position)


func _unhandled_input(event: InputEvent) -> void:
	if not _camera_input_enabled:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		var anchor := _current_safe_view().get_center()
		if hud_half_view_mode and _focus_safe_rect.size.x > 1.0:
			anchor = _focus_safe_rect.get_center()
		if k.keycode == KEY_EQUAL or k.keycode == KEY_KP_ADD:
			_camera.apply_zoom_step(MapCameraController.WHEEL_ZOOM_STEP, anchor)
			_apply_camera_transform()
			get_viewport().set_input_as_handled()
		elif k.keycode == KEY_MINUS or k.keycode == KEY_KP_SUBTRACT:
			_camera.apply_zoom_step(1.0 / MapCameraController.WHEEL_ZOOM_STEP, anchor)
			_apply_camera_transform()
			get_viewport().set_input_as_handled()
		elif k.keycode == KEY_R or k.keycode == KEY_HOME:
			if hud_half_view_mode:
				reset_to_active_piece()
			else:
				_reset_camera()
			get_viewport().set_input_as_handled()


func _release_elastic() -> void:
	if not hud_half_view_mode:
		_camera.clear_elastic_offset()
		_apply_camera_transform()
		return
	_kill_elastic_tween()
	var start := _camera.elastic_offset_screen()
	if start.length() < 0.05:
		_camera.clear_elastic_offset()
		_apply_camera_transform()
		return
	_elastic_tween = create_tween()
	_elastic_tween.tween_method(_set_elastic_offset, start, Vector2.ZERO, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_elastic_tween.finished.connect(func():
		_camera.clear_elastic_offset()
		_apply_camera_transform()
	)


func _set_elastic_offset(v: Vector2) -> void:
	_camera.set_elastic_offset_screen(v)
	_apply_camera_transform()


func _set_focus_center(v: Vector2) -> void:
	_camera.set_world_center(v)
	_apply_camera_transform()


func _kill_elastic_tween() -> void:
	if _elastic_tween != null and _elastic_tween.is_valid():
		_elastic_tween.kill()
	_elastic_tween = null


func _kill_focus_tween() -> void:
	if _focus_tween != null and _focus_tween.is_valid():
		_focus_tween.kill()
	_focus_tween = null


func _handle_click(screen_pos: Vector2) -> void:
	if _moving:
		return
	var city_id := _city_at(screen_pos)
	if city_id != "" and not _route_selection_active:
		var ruleset_city_id := ruleset_city_id_for_topology(city_id)
		if ruleset_city_id == "":
			push_warning("WorldMapRuntimePreview: 正式城市 ID 映射缺失 %s" % city_id)
			return
		_clear_city_hover()
		city_inspect_requested.emit(ruleset_city_id)
		return
	var stop_id := _stop_at(screen_pos)
	# Prefer stop if both hit and stop is the city seat / nearby route point.
	if stop_id != "":
		select_stop(stop_id)
		return
	if city_id != "" and _stops_by_id.has(city_id):
		select_stop(city_id)


func _update_hover(screen_pos: Vector2) -> void:
	var city_id := _city_at(screen_pos)
	if city_id != _hovered_city:
		if city_id == "":
			_clear_city_hover()
		else:
			_apply_city_hover(city_id)
	var stop_id := _stop_at(screen_pos)
	if stop_id != _hovered_stop:
		_hovered_stop = stop_id
		_refresh_stop_hover_visuals()


func _apply_city_hover(city_id: String) -> void:
	if _hovered_city != "" and _hovered_city != city_id and _city_overlays.has(_hovered_city):
		_city_overlays[_hovered_city].set_hovered(false)
	_hovered_city = city_id
	if _city_overlays.has(city_id):
		_city_overlays[city_id].set_hovered(true)
		var ov: WorldMapCityHoverOverlay = _city_overlays[city_id]
		_info.text = "%s · %s" % [ov.display_name, ov.route_label()]
	hover_city_changed.emit(city_id)


func _clear_city_hover() -> void:
	if _hovered_city != "" and _city_overlays.has(_hovered_city):
		_city_overlays[_hovered_city].set_hovered(false)
	_hovered_city = ""
	_info.text = ""
	hover_city_changed.emit("")


func _city_at(screen_pos: Vector2) -> String:
	var world := _camera.screen_to_world(screen_pos)
	var scale := _camera.render_scale()
	var hits: Array = []
	for cid in _city_overlays.keys():
		var ov: WorldMapCityHoverOverlay = _city_overlays[cid]
		var rect := _city_interaction_rect(ov)
		# Enforce min 44px screen hit.
		var min_logic := MIN_HIT_SCREEN_PX / maxf(scale, 0.0001)
		var grow := Vector2(
			maxf(0.0, (min_logic - rect.size.x) * 0.5),
			maxf(0.0, (min_logic - rect.size.y) * 0.5)
		)
		var hit_rect := Rect2(rect.position - grow, rect.size + grow * 2.0)
		if hit_rect.has_point(world):
			hits.append({"id": cid, "center": rect.get_center()})
	if hits.is_empty():
		return ""
	if hits.size() == 1:
		return String(hits[0]["id"])
	var best_id := ""
	var best_d := INF
	for h in hits:
		var d: float = world.distance_squared_to(h["center"])
		if d < best_d:
			best_d = d
			best_id = String(h["id"])
	return best_id


func _city_interaction_rect(ov: WorldMapCityHoverOverlay) -> Rect2:
	return ov.static_visible_rect_world()


func _stop_at(screen_pos: Vector2) -> String:
	var world := _camera.screen_to_world(screen_pos)
	var scale := _camera.render_scale()
	var radius := maxf(12.0, MIN_HIT_SCREEN_PX * 0.5 / maxf(scale, 0.0001))
	var best_id := ""
	var best_d := radius * radius
	for sid in _stops_by_id.keys():
		var pos := WorldMapRuntimeLoader.stop_position(_stops_by_id[sid])
		var d := world.distance_squared_to(pos)
		if d <= best_d:
			best_d = d
			best_id = sid
	return best_id


func _refresh_stop_hover_visuals() -> void:
	for sid in _stop_rings.keys():
		var ring: Polygon2D = _stop_rings[sid]
		if sid == _hovered_stop or sid == _selected_stop or _pulse_destinations.has(sid):
			var stop: Dictionary = _stops_by_id[sid]
			var routes: Array = stop.get("allowed_routes", [])
			var col := STOP_HOVER_SEA if ("SEA" in routes and not ("LAND" in routes)) else STOP_HOVER_LAND
			if sid == _selected_stop:
				col.a = 1.0
			elif _pulse_destinations.has(sid):
				col.a = 0.55
			ring.color = col
		else:
			ring.color = Color(1, 1, 1, 0)
			ring.scale = Vector2.ONE


func _update_destination_pulse() -> void:
	if _pulse_destinations.is_empty():
		return
	var pulse := 1.0 + 0.12 * sin(_pulse_t * 4.0)
	var alpha := 0.45 + 0.35 * (0.5 + 0.5 * sin(_pulse_t * 4.0))
	for sid in _pulse_destinations.keys():
		if not _stop_rings.has(sid):
			continue
		var ring: Polygon2D = _stop_rings[sid]
		ring.scale = Vector2(pulse, pulse)
		var col := ring.color
		col.a = alpha
		ring.color = col


func _refresh_selection_highlights() -> void:
	for line in _highlight_outers:
		line.visible = false
		line.points = PackedVector2Array()
	for line in _highlight_inners:
		line.visible = false
		line.points = PackedVector2Array()
	_pulse_destinations.clear()
	_refresh_stop_hover_visuals()
	_update_transport_btn()
	if _selected_stop == "" or not _adjacency.has(_selected_stop):
		return
	var pool_i := 0
	var want_rt := _route_type_for_transport(_preview_transport)
	var stop: Dictionary = _stops_by_id[_selected_stop]
	var allowed: Array = stop.get("allowed_routes", [])
	var is_x := bool(stop.get("is_transport_interchange", false))
	_apply_highlight_widths()
	for link in _adjacency[_selected_stop]:
		var rt := String(link.get("route_type", ""))
		if is_x:
			if rt != want_rt:
				continue
		elif not (rt in allowed):
			continue
		var ei := int(link.get("edge_index", -1))
		if ei < 0 or ei >= _edges.size():
			continue
		if pool_i >= _highlight_inners.size():
			break
		var e: Dictionary = _edges[ei]
		var pts := WorldMapRuntimeLoader.polyline_to_packed(e.get("movement_polyline_px", []))
		if String(e.get("a", "")) != _selected_stop:
			pts = _reversed_packed(pts)
		var outer: Line2D = _highlight_outers[pool_i]
		var inner: Line2D = _highlight_inners[pool_i]
		outer.points = pts
		inner.points = pts
		outer.default_color = ROUTE_OUTLINE_COLOR
		inner.default_color = LAND_COLOR if rt == "LAND" else SEA_COLOR
		outer.visible = true
		inner.visible = true
		var other := String(link.get("other", ""))
		if other != "":
			_pulse_destinations[other] = true
		pool_i += 1
	_refresh_stop_hover_visuals()


func _sync_transport_to_stop(stop_id: String) -> void:
	if not _stops_by_id.has(stop_id):
		return
	var stop: Dictionary = _stops_by_id[stop_id]
	if bool(stop.get("is_transport_interchange", false)):
		_update_transport_btn()
		return
	var allowed: Array = stop.get("allowed_routes", [])
	if "LAND" in allowed and not ("SEA" in allowed):
		set_preview_transport(GameData.Transport.CAMEL)
	elif "SEA" in allowed and not ("LAND" in allowed):
		set_preview_transport(GameData.Transport.SHIP)
	else:
		_update_transport_btn()


func _try_move(from_id: String, to_id: String) -> bool:
	_last_move_reject_reason = ""
	if _moving:
		_last_move_reject_reason = "already_moving"
		return false
	if from_id == to_id:
		_last_move_reject_reason = "same_stop"
		return false
	var want := _route_type_for_transport(_preview_transport)
	var edge_i := _find_edge_index(from_id, to_id, want)
	if edge_i < 0:
		var other_edge_i := _find_edge_index(from_id, to_id)
		if other_edge_i >= 0:
			var other_type := String((_edges[other_edge_i] as Dictionary).get("route_type", ""))
			_last_move_reject_reason = "transport_mismatch:%s_need_%s" % [want, other_type]
			_set_status(
				"交通不匹配：当前%s，路线为%s" % [
					"骆驼" if want == "LAND" else "商船",
					"陆路" if other_type == "LAND" else "海路",
				],
				STATUS_MSG_SEC
			)
		else:
			_last_move_reject_reason = "not_adjacent"
			_set_status("不是相邻路线", STATUS_MSG_SEC)
		return false
	var e: Dictionary = _edges[edge_i]
	var rt := String(e.get("route_type", ""))
	if rt != want:
		_last_move_reject_reason = "transport_mismatch:%s_need_%s" % [want, rt]
		_set_status(
			"交通不匹配：当前%s，路线为%s" % [
				"骆驼" if want == "LAND" else "商船",
				"陆路" if rt == "LAND" else "海路",
			],
			STATUS_MSG_SEC
		)
		return false
	var from_stop: Dictionary = _stops_by_id[from_id]
	var allowed: Array = from_stop.get("allowed_routes", [])
	if rt not in allowed:
		_last_move_reject_reason = "route_not_allowed"
		_set_status("该停靠点不允许此路线类型", STATUS_MSG_SEC)
		return false

	var pts := WorldMapRuntimeLoader.polyline_to_packed(e.get("movement_polyline_px", []))
	if String(e.get("a", "")) != from_id:
		pts = _reversed_packed(pts)
	var buffers := WorldMapRuntimeLoader.build_arc_buffers(pts)
	_place_piece_at_stop(from_id)
	_piece.set_transport(_preview_transport)
	_piece.visible = true
	_moving = true
	_piece.play_path(
		buffers["samples"],
		buffers["cum"],
		buffers["total"],
		MOVE_DURATION_SEC,
		PackedFloat32Array(),
		[],
		90.0
	)
	_set_status("移动中 %s → %s (%s)" % [from_id, to_id, rt], MOVE_DURATION_SEC + 0.5)
	_selected_stop = from_id
	_pending_to = to_id
	_refresh_selection_highlights()
	return true


var _pending_to := ""


func _on_piece_move_finished(_player_id: String) -> void:
	_moving = false
	var from_id := _selected_stop
	var to_id := _pending_to
	if to_id != "" and _stops_by_id.has(to_id):
		_selected_stop = to_id
		_place_piece_at_stop(to_id)
	_pending_to = ""
	_refresh_selection_highlights()
	move_finished.emit(from_id, to_id)


func _place_piece_at_stop(stop_id: String) -> void:
	if not _stops_by_id.has(stop_id) or _piece == null:
		return
	var pos := WorldMapRuntimeLoader.stop_route_position(
		_stops_by_id[stop_id], _route_type_for_transport(_preview_transport)
	)
	_piece.set_logical_position(pos)
	_piece.position = pos
	_piece.visible = true


func _find_edge_index(a: String, b: String, route_type: String = "") -> int:
	for i in range(_edges.size()):
		var e: Dictionary = _edges[i]
		var ea := String(e.get("a", ""))
		var eb := String(e.get("b", ""))
		if (
			((ea == a and eb == b) or (ea == b and eb == a))
			and (route_type.is_empty() or String(e.get("route_type", "")) == route_type)
		):
			return i
	return -1


func _route_type_for_transport(t: int) -> String:
	return "LAND" if t == GameData.Transport.CAMEL else "SEA"


func _on_transport_pressed() -> void:
	if not can_manual_transport_switch():
		_set_status("仅换乘城市可切换交通工具", STATUS_MSG_SEC)
		return
	if _preview_transport == GameData.Transport.CAMEL:
		set_preview_transport(GameData.Transport.SHIP)
	else:
		set_preview_transport(GameData.Transport.CAMEL)


func _update_transport_btn() -> void:
	if _transport_btn == null:
		return
	_transport_btn.text = (
		"预览：骆驼" if _preview_transport == GameData.Transport.CAMEL else "预览：商船"
	)
	_transport_btn.disabled = not can_manual_transport_switch()


func _set_status(text: String, ttl: float) -> void:
	if _status != null:
		_status.text = text
	_status_ttl = ttl


func _ring_poly(radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(20):
		var a := TAU * float(i) / 20.0
		pts.append(Vector2(cos(a), sin(a)) * radius)
	return pts


func _reversed_packed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(pts.size() - 1, -1, -1):
		out.append(pts[i])
	return out


func _count_descendants() -> int:
	return _count_node(self)


func _count_node(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count_node(ch)
	return c
