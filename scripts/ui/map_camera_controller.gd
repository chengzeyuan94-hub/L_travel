class_name MapCameraController
extends RefCounted

## BoardView / world-map camera: fit / zoom / pan.
## Supports legacy fit-zoom (Demo) and half-view cover mode (formal HUD preview).

signal camera_changed

const DEFAULT_MIN_ZOOM := 1.0
const DEFAULT_MAX_ZOOM := 2.5
const WHEEL_ZOOM_STEP := 1.10
const ZOOM_TWEEN_SEC := 0.15
const CONTENT_PAD_PX := 40.0
const RIGHT_PLAQUE_PAD_PX := 24.0
const MIN_VISIBLE_FRACTION := 0.20

enum ClampMode { FRACTION, COVER }

var world_bounds := Rect2(0, 0, 960, 540)
var min_zoom := DEFAULT_MIN_ZOOM
var max_zoom := DEFAULT_MAX_ZOOM

var fit_scale := 1.0
var zoom_factor := 1.0
## 显示在 safe_view_rect 中心的世界坐标。
var camera_world_center := Vector2(480, 270)
var safe_view_rect := Rect2(0, 0, 960, 540)
## Optional focus/occlusion-aware safe rect (defaults to safe_view_rect).
var focus_safe_rect := Rect2(0, 0, 960, 540)
var focus_anchor := Vector2(0.45, 0.50)
var default_visible_width_ratio := 0.44
var logic_map_width := 4096.0
var clamp_mode := ClampMode.FRACTION
var elastic_overscroll_screen_px := 0.0
var _elastic_offset_screen := Vector2.ZERO

var _target_zoom := 1.0
var half_view_enabled := false


func configure_from_presentation(presentation: Dictionary, fallback_size: Vector2) -> void:
	half_view_enabled = false
	clamp_mode = ClampMode.FRACTION
	elastic_overscroll_screen_px = 0.0
	_elastic_offset_screen = Vector2.ZERO
	var wb: Variant = presentation.get("world_bounds", null)
	if wb is Array and wb.size() >= 4:
		world_bounds = Rect2(float(wb[0]), float(wb[1]), float(wb[2]), float(wb[3]))
	elif wb is Dictionary:
		world_bounds = Rect2(
			float(wb.get("x", 0)),
			float(wb.get("y", 0)),
			float(wb.get("w", fallback_size.x)),
			float(wb.get("h", fallback_size.y))
		)
	else:
		var ls: Variant = presentation.get("logical_size", [fallback_size.x, fallback_size.y])
		if ls is Array and ls.size() >= 2:
			world_bounds = Rect2(0, 0, float(ls[0]), float(ls[1]))
		else:
			world_bounds = Rect2(Vector2.ZERO, fallback_size)
	min_zoom = float(presentation.get("camera_min_zoom", DEFAULT_MIN_ZOOM))
	max_zoom = float(presentation.get("camera_max_zoom", DEFAULT_MAX_ZOOM))


func configure_half_view(profile: Dictionary, overscan_bounds: Rect2, safe_rect: Rect2) -> void:
	half_view_enabled = true
	clamp_mode = ClampMode.COVER
	world_bounds = overscan_bounds
	safe_view_rect = safe_rect
	focus_safe_rect = safe_rect
	default_visible_width_ratio = float(profile.get("default_visible_width_ratio", 0.44))
	min_zoom = float(profile.get("min_zoom_factor", 0.8))
	max_zoom = float(profile.get("max_zoom_factor", 1.5))
	var anchor: Array = profile.get("focus_anchor", [0.45, 0.50])
	if anchor.size() >= 2:
		focus_anchor = Vector2(float(anchor[0]), float(anchor[1]))
	logic_map_width = float(profile.get("logic_size", [4096, 1363])[0]) if profile.get("logic_size", []) is Array else 4096.0
	if profile.get("logic_size") is Array and (profile.get("logic_size") as Array).size() >= 1:
		logic_map_width = float((profile.get("logic_size") as Array)[0])
	elastic_overscroll_screen_px = float(profile.get("elastic_overscroll_screen_px", 24))
	_elastic_offset_screen = Vector2.ZERO
	_recompute_half_view_fit_scale()
	zoom_factor = float(profile.get("default_zoom_factor", 1.0))
	_target_zoom = zoom_factor
	_clamp_center()
	camera_changed.emit()


func set_focus_safe_rect(rect: Rect2) -> void:
	focus_safe_rect = rect


func display_scale() -> float:
	return fit_scale * zoom_factor


func render_scale() -> float:
	## Elastic drag moves the map by a few screen pixels.  Moving a cover-fitted
	## texture without compensating its scale exposes the viewport clear colour
	## along the opposite edge.  Grow the rendered stage just enough that the
	## shifted edge still touches the safe rect.  Logical zoom/visible-width
	## calculations deliberately continue to use display_scale().
	var base := display_scale()
	if clamp_mode != ClampMode.COVER or _elastic_offset_screen.length_squared() <= 0.0001:
		return base
	var safe := safe_view_rect.size
	if safe.x <= 0.0001 or safe.y <= 0.0001:
		return base
	var guard_x := 1.0 + 2.0 * absf(_elastic_offset_screen.x) / safe.x
	var guard_y := 1.0 + 2.0 * absf(_elastic_offset_screen.y) / safe.y
	return base * maxf(guard_x, guard_y)


func cover_min_scale() -> float:
	if safe_view_rect.size.x < 1.0 or safe_view_rect.size.y < 1.0:
		return 1.0
	if world_bounds.size.x < 1.0 or world_bounds.size.y < 1.0:
		return 1.0
	return maxf(safe_view_rect.size.x / world_bounds.size.x, safe_view_rect.size.y / world_bounds.size.y)


func visible_world_width() -> float:
	var s := display_scale()
	if s <= 0.0001:
		return 0.0
	return safe_view_rect.size.x / s


func visible_width_ratio() -> float:
	if logic_map_width <= 0.0001:
		return 0.0
	return visible_world_width() / logic_map_width


func world_to_screen(world: Vector2) -> Vector2:
	var s := render_scale()
	return safe_view_rect.get_center() + (world - camera_world_center) * s + _elastic_offset_screen


func screen_to_world(screen: Vector2) -> Vector2:
	var s := render_scale()
	if s <= 0.0001:
		return camera_world_center
	return camera_world_center + (screen - safe_view_rect.get_center() - _elastic_offset_screen) / s


func stage_position() -> Vector2:
	## Node2D 舞台：position + world * uniform_scale = screen
	var s := render_scale()
	return safe_view_rect.get_center() + _elastic_offset_screen - camera_world_center * s


func set_safe_view_rect(rect: Rect2) -> void:
	safe_view_rect = rect
	if focus_safe_rect.size.x < 1.0:
		focus_safe_rect = rect
	if half_view_enabled:
		_recompute_half_view_fit_scale()
	_clamp_center()
	camera_changed.emit()


func fit_content_bounds(content: Rect2) -> void:
	half_view_enabled = false
	clamp_mode = ClampMode.FRACTION
	_elastic_offset_screen = Vector2.ZERO
	var pad := CONTENT_PAD_PX
	var bounds := content.grow(pad)
	if bounds.size.x < 1.0 or bounds.size.y < 1.0:
		bounds = world_bounds
	var avail := safe_view_rect.size
	if avail.x < 1.0 or avail.y < 1.0:
		return
	fit_scale = minf(avail.x / bounds.size.x, avail.y / bounds.size.y)
	zoom_factor = 1.0
	_target_zoom = 1.0
	camera_world_center = bounds.get_center()
	_clamp_center()
	camera_changed.emit()


func reset_to_fit(content: Rect2) -> void:
	fit_content_bounds(content)


func reset_half_view_default(focus_world: Vector2 = Vector2.INF) -> void:
	if not half_view_enabled:
		return
	_recompute_half_view_fit_scale()
	zoom_factor = 1.0
	_target_zoom = 1.0
	_elastic_offset_screen = Vector2.ZERO
	if focus_world != Vector2.INF:
		focus_world_point(focus_world, false)
	else:
		_clamp_center()
		camera_changed.emit()


func set_zoom_around_screen_point(new_zoom: float, screen_point: Vector2) -> void:
	var before := screen_to_world(screen_point)
	_target_zoom = clampf(new_zoom, min_zoom, max_zoom)
	zoom_factor = _target_zoom
	if half_view_enabled:
		_ensure_cover_after_zoom()
	var after_center_delta := before - screen_to_world(screen_point)
	camera_world_center += after_center_delta
	_clamp_center()
	camera_changed.emit()


func apply_zoom_step(factor: float, screen_point: Vector2) -> void:
	set_zoom_around_screen_point(zoom_factor * factor, screen_point)


func pan_by_screen_delta(delta_screen: Vector2) -> void:
	var s := display_scale()
	if s <= 0.0001:
		return
	camera_world_center -= delta_screen / s
	if elastic_overscroll_screen_px > 0.0 and clamp_mode == ClampMode.COVER:
		_apply_elastic_pan()
	else:
		_elastic_offset_screen = Vector2.ZERO
		_clamp_center()
	camera_changed.emit()


func clear_elastic_offset() -> void:
	_elastic_offset_screen = Vector2.ZERO
	_clamp_center()
	camera_changed.emit()


func set_elastic_offset_screen(offset: Vector2) -> void:
	var lim := elastic_overscroll_screen_px
	if lim <= 0.0:
		_elastic_offset_screen = Vector2.ZERO
	else:
		_elastic_offset_screen = Vector2(clampf(offset.x, -lim, lim), clampf(offset.y, -lim, lim))
	camera_changed.emit()


func elastic_offset_screen() -> Vector2:
	return _elastic_offset_screen


func focus_center_for_world_point(world_point: Vector2) -> Vector2:
	## Pure focus calculation used by the view's Tween.  Keeping this calculation
	## here guarantees animated and immediate focus share the same clamp rules.
	var s := display_scale()
	if s <= 0.0001:
		return camera_world_center
	var anchor_rect := focus_safe_rect if focus_safe_rect.size.x > 1.0 else safe_view_rect
	var target_screen := anchor_rect.position + anchor_rect.size * focus_anchor
	var target := world_point - (target_screen - safe_view_rect.get_center()) / s
	var hard := _hard_center_limits()
	target.x = clampf(target.x, hard.position.x, hard.end.x)
	target.y = clampf(target.y, hard.position.y, hard.end.y)
	return target


func set_world_center(center: Vector2) -> void:
	camera_world_center = center
	_elastic_offset_screen = Vector2.ZERO
	_clamp_center()
	camera_changed.emit()


func focus_world_point(world_point: Vector2, _animated: bool = true) -> void:
	## The controller owns geometry only.  The Control that renders it performs
	## animation and calls set_world_center(); immediate callers use this path.
	set_world_center(focus_center_for_world_point(world_point))


func focus_city_world(world_point: Vector2, animated: bool = true) -> void:
	focus_world_point(world_point, animated)


func is_world_point_in_focus_safe(world_point: Vector2, margin_px: float = 0.0) -> bool:
	var screen := world_to_screen(world_point)
	var r := focus_safe_rect.grow(-margin_px)
	return r.has_point(screen)


func _recompute_half_view_fit_scale() -> void:
	var avail_w := maxf(safe_view_rect.size.x, 1.0)
	var half := avail_w / maxf(logic_map_width * default_visible_width_ratio, 1.0)
	var cover := cover_min_scale()
	# Keep cover even at min_zoom: fit_scale * min_zoom >= cover
	var min_fit := cover / maxf(min_zoom, 0.0001)
	fit_scale = maxf(half, min_fit)


func _ensure_cover_after_zoom() -> void:
	var cover := cover_min_scale()
	var s := display_scale()
	if s + 0.0001 < cover:
		# Raise zoom to cover floor without leaving half-view intent when possible.
		zoom_factor = clampf(cover / maxf(fit_scale, 0.0001), min_zoom, max_zoom)
		_target_zoom = zoom_factor


func _apply_elastic_pan() -> void:
	var hard := _hard_center_limits()
	var cx := camera_world_center.x
	var cy := camera_world_center.y
	var elastic := Vector2.ZERO
	if cx < hard.position.x:
		elastic.x = (hard.position.x - cx) * display_scale()
		cx = hard.position.x
	elif cx > hard.end.x:
		elastic.x = (hard.end.x - cx) * display_scale()
		cx = hard.end.x
	if cy < hard.position.y:
		elastic.y = (hard.position.y - cy) * display_scale()
		cy = hard.position.y
	elif cy > hard.end.y:
		elastic.y = (hard.end.y - cy) * display_scale()
		cy = hard.end.y
	camera_world_center = Vector2(cx, cy)
	var lim := elastic_overscroll_screen_px
	_elastic_offset_screen = Vector2(clampf(elastic.x, -lim, lim), clampf(elastic.y, -lim, lim))


func _hard_center_limits() -> Rect2:
	var s := display_scale()
	var view_world := safe_view_rect.size / maxf(s, 0.0001)
	var bounds := world_bounds
	if clamp_mode == ClampMode.COVER:
		var min_c := bounds.position + view_world * 0.5
		var max_c := bounds.end - view_world * 0.5
		if min_c.x > max_c.x:
			min_c.x = bounds.get_center().x
			max_c.x = bounds.get_center().x
		if min_c.y > max_c.y:
			min_c.y = bounds.get_center().y
			max_c.y = bounds.get_center().y
		return Rect2(min_c, max_c - min_c)
	var min_c2 := bounds.position + view_world * MIN_VISIBLE_FRACTION * 0.5
	var max_c2 := bounds.end - view_world * MIN_VISIBLE_FRACTION * 0.5
	if min_c2.x > max_c2.x:
		min_c2.x = bounds.get_center().x
		max_c2.x = bounds.get_center().x
	if min_c2.y > max_c2.y:
		min_c2.y = bounds.get_center().y
		max_c2.y = bounds.get_center().y
	return Rect2(min_c2, max_c2 - min_c2)


func _clamp_center() -> void:
	var s := display_scale()
	if s <= 0.0001:
		return
	if clamp_mode == ClampMode.COVER:
		_ensure_cover_after_zoom()
	var hard := _hard_center_limits()
	camera_world_center.x = clampf(camera_world_center.x, hard.position.x, hard.end.x)
	camera_world_center.y = clampf(camera_world_center.y, hard.position.y, hard.end.y)
	if _elastic_offset_screen != Vector2.ZERO and elastic_overscroll_screen_px <= 0.0:
		_elastic_offset_screen = Vector2.ZERO


func debug_state() -> Dictionary:
	return {
		"fit_scale": fit_scale,
		"zoom_factor": zoom_factor,
		"display_scale": display_scale(),
		"render_scale": render_scale(),
		"camera_world_center": camera_world_center,
		"world_bounds": world_bounds,
		"safe_view_rect": safe_view_rect,
		"focus_safe_rect": focus_safe_rect,
		"min_zoom": min_zoom,
		"max_zoom": max_zoom,
		"half_view_enabled": half_view_enabled,
		"clamp_mode": clamp_mode,
		"visible_width_ratio": visible_width_ratio(),
		"cover_min_scale": cover_min_scale(),
		"elastic_offset_screen": _elastic_offset_screen,
		"focus_anchor": focus_anchor,
	}
