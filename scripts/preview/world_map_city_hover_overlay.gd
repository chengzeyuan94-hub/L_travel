extends Node2D
class_name WorldMapCityHoverOverlay

## Hover scales relative to the building as it is actually baked into the world map.
## Every animation frame uses one city-wide uniform scale and is independently
## bottom-centre aligned. Smoke/flags may extend naturally, but cannot resize or
## anisotropically stretch the building from one frame to the next.

const HOVER_SCALE := 1.05
const TWEEN_SEC := 0.12
const ATLAS_COLUMNS := 8
const FRAME_SIZE := Vector2(256, 256)
const ALPHA_THRESHOLD := 32.0 / 255.0

var city_id := ""
var display_name := ""
var allowed_routes: Array = []
var is_interchange := false
var building_rect := Rect2()
var hover_hit_rect := Rect2()

var _pivot: Node2D
var _anim: AnimatedSprite2D
var _hovered := false
var _scale_tween: Tween
var _frame_visible_rects: Array[Rect2] = []
var _frame_count := 0
var _static_visible_rect := Rect2() # in idle texture pixels
var _static_canvas_size := Vector2(1024, 1024)
var _static_visible_map_size := Vector2.ONE
var _static_bottom_center_map := Vector2.ZERO
var _uniform_frame_scale := 1.0


func setup_from_city(city: Dictionary) -> void:
	city_id = String(city.get("city_id", ""))
	display_name = String(city.get("display_name", city_id))
	allowed_routes = city.get("allowed_routes", [])
	is_interchange = bool(city.get("is_transport_interchange", false))
	var bp: Array = city.get("building_position", [0, 0])
	var bs: Array = city.get("building_size", [1, 1])
	building_rect = Rect2(float(bp[0]), float(bp[1]), float(bs[0]), float(bs[1]))
	var hr: Dictionary = city.get("hover_hit_rect", {})
	hover_hit_rect = Rect2(
		float(hr.get("x", building_rect.position.x)),
		float(hr.get("y", building_rect.position.y)),
		float(hr.get("w", building_rect.size.x)),
		float(hr.get("h", building_rect.size.y))
	)

	var static_path := String(city.get("static_texture", ""))
	var static_tex := load(static_path) as Texture2D
	if static_tex != null:
		_static_canvas_size = Vector2(static_tex.get_width(), static_tex.get_height())
		_static_visible_rect = _alpha_bbox_image(static_tex.get_image(), 0, 0, int(_static_canvas_size.x), int(_static_canvas_size.y))
	if _static_visible_rect.size.x < 1.0 or _static_visible_rect.size.y < 1.0:
		_static_visible_rect = Rect2(Vector2.ZERO, _static_canvas_size)

	# building_rect is an extraction/audit rectangle and is deliberately padded. It
	# is not the size of the city painted into world_map_v1.png. The loader injects
	# this rect from the PXD layer transform calibration; it is the authoritative
	# map-space alpha-visible building bound.
	var calibrated: Array = city.get("static_visible_rect_px", [])
	if calibrated.size() == 4:
		var calibrated_rect := Rect2(
			float(calibrated[0]), float(calibrated[1]),
			float(calibrated[2]), float(calibrated[3])
		)
		if calibrated_rect.size.x > 0.0 and calibrated_rect.size.y > 0.0:
			_static_visible_map_size = calibrated_rect.size
			_static_bottom_center_map = Vector2(
				calibrated_rect.get_center().x, calibrated_rect.end.y
			)
	else:
		# Safe compatibility fallback for fixtures that predate the calibration.
		# Formal world-map content treats a missing calibration as a loader error.
		_static_visible_map_size = Vector2(
			building_rect.size.x * (_static_visible_rect.size.x / maxf(_static_canvas_size.x, 1.0)),
			building_rect.size.y * (_static_visible_rect.size.y / maxf(_static_canvas_size.y, 1.0))
		)
		var static_bc_tex := Vector2(
			_static_visible_rect.get_center().x,
			_static_visible_rect.position.y + _static_visible_rect.size.y
		)
		_static_bottom_center_map = building_rect.position + Vector2(
			static_bc_tex.x / maxf(_static_canvas_size.x, 1.0) * building_rect.size.x,
			static_bc_tex.y / maxf(_static_canvas_size.y, 1.0) * building_rect.size.y
		)
	position = _static_bottom_center_map

	var anim_path := String(city.get("animation_texture", ""))
	var atlas := load(anim_path) as Texture2D
	if atlas == null:
		push_error("WorldMapCityHoverOverlay: missing atlas %s" % anim_path)
		return

	_frame_count = int(city.get("frame_count", 32))
	_frame_visible_rects = _load_frame_visible_rects(anim_path, atlas, _frame_count)
	# One fixed, uniform scale per city. Frame zero is generated from the same
	# source icon used by the PXD map; averaging its X/Y fit absorbs minor alpha
	# extraction rounding without stretching either axis. Later smoke/flag pixels
	# may extend beyond the building, but never resize the building itself.
	var reference_rect := _frame_rect(0)
	var fit_x := _static_visible_map_size.x / maxf(reference_rect.size.x, 1.0)
	var fit_y := _static_visible_map_size.y / maxf(reference_rect.size.y, 1.0)
	_uniform_frame_scale = (fit_x + fit_y) * 0.5

	_pivot = Node2D.new()
	_pivot.name = "HoverPivot"
	_pivot.scale = Vector2.ONE
	add_child(_pivot)

	var fps := float(city.get("fps", 8.0))
	_anim = AnimatedSprite2D.new()
	_anim.name = "HoverAnim"
	_anim.centered = true
	_anim.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_anim.sprite_frames = _build_frames(atlas, _frame_count, fps)
	_anim.visible = false
	_anim.set_process(false)
	_pivot.add_child(_anim)
	_anim.frame_changed.connect(_on_animation_frame_changed)
	_apply_frame_geometry(0)


func set_hovered(value: bool) -> void:
	if _anim == null or _pivot == null or _hovered == value:
		return
	_hovered = value
	if _scale_tween != null:
		_scale_tween.kill()
	if value:
		_apply_frame_geometry(_anim.frame)
		_anim.visible = true
		_anim.set_process(true)
		_anim.play("hover")
		_scale_tween = create_tween()
		_scale_tween.tween_property(
			_pivot, "scale", Vector2.ONE * HOVER_SCALE, TWEEN_SEC
		).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	else:
		_anim.stop()
		_anim.frame = 0
		_anim.set_process(false)
		_scale_tween = create_tween()
		_scale_tween.tween_property(
			_pivot, "scale", Vector2.ONE, TWEEN_SEC
		).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		_scale_tween.tween_callback(func():
			if not _hovered and _anim != null:
				_anim.visible = false
		)


func is_hovered() -> bool:
	return _hovered


func is_playing() -> bool:
	return _hovered and _anim != null and _anim.is_playing()


func current_frame() -> int:
	return _anim.frame if _anim != null else -1


func route_label() -> String:
	if is_interchange:
		return "换乘"
	if "LAND" in allowed_routes and "SEA" in allowed_routes:
		return "换乘"
	if "SEA" in allowed_routes:
		return "海路"
	return "陆路"


func building_bottom_center() -> Vector2:
	return _static_bottom_center_map


func visible_bottom_center_world() -> Vector2:
	return position


func visible_size_world() -> Vector2:
	if _pivot == null or _anim == null or _frame_visible_rects.is_empty():
		return _static_visible_map_size
	var rect := _frame_rect(_anim.frame)
	return rect.size * _anim.scale.abs() * _pivot.scale.abs()


func static_visible_size_world() -> Vector2:
	return _static_visible_map_size


func static_visible_rect_world() -> Rect2:
	return Rect2(
		_static_bottom_center_map - Vector2(_static_visible_map_size.x * 0.5, _static_visible_map_size.y),
		_static_visible_map_size
	)


func hover_scale_factor() -> float:
	if _pivot == null:
		return 1.0
	return absf(_pivot.scale.x)


func alignment_metrics() -> Dictionary:
	var bbc := building_bottom_center()
	var vbc := visible_bottom_center_world()
	var vis := visible_size_world()
	var static_sz := static_visible_size_world()
	var wr := vis.x / maxf(static_sz.x, 0.001)
	var hr := vis.y / maxf(static_sz.y, 0.001)
	var frame_rect := _frame_rect(_anim.frame if _anim != null else 0)
	return {
		"city_id": city_id,
		"static_bbox_tex": [
			_static_visible_rect.position.x, _static_visible_rect.position.y,
			_static_visible_rect.size.x, _static_visible_rect.size.y
		],
		"hover_bbox_tex": [
			frame_rect.position.x, frame_rect.position.y,
			frame_rect.size.x, frame_rect.size.y
		],
		"frame": _anim.frame if _anim != null else 0,
		"frame_count": _frame_visible_rects.size(),
		"static_visible_map_size": [static_sz.x, static_sz.y],
		"hover_visible_map_size": [vis.x, vis.y],
		"width_ratio": wr,
		"height_ratio": hr,
		"building_bottom_center": [bbc.x, bbc.y],
		"visible_bottom_center": [vbc.x, vbc.y],
		"bottom_center_error_px": vbc.distance_to(bbc),
		"hover_scale_factor": hover_scale_factor(),
	}


func all_frame_alignment_metrics(scale_factor := HOVER_SCALE) -> Array:
	## Read-only source-math QA surface retained for reports. Runtime tests should
	## additionally use debug_set_frame()+rendered_visible_rect_world(), which
	## measures the actual node transforms rather than trusting this calculation.
	var result: Array = []
	for index in range(_frame_visible_rects.size()):
		var rect := _frame_visible_rects[index]
		var frame_scale := _scale_for_frame(rect)
		var visible_size := rect.size * frame_scale.abs() * scale_factor
		result.append({
			"frame": index,
			"bbox": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
			"width_ratio": visible_size.x / maxf(_static_visible_map_size.x, 0.001),
			"height_ratio": visible_size.y / maxf(_static_visible_map_size.y, 0.001),
			"bottom_center_error_px": 0.0,
			"uniform_frame_scale": _uniform_frame_scale,
		})
	return result


func uniform_frame_scale() -> float:
	return _uniform_frame_scale


func current_frame_sprite_scale() -> Vector2:
	return _anim.scale if _anim != null else Vector2.ZERO


func debug_set_frame(index: int, scale_factor := HOVER_SCALE) -> bool:
	## Test-only deterministic pose control for falsifiable render measurements.
	if _anim == null or _pivot == null or index < 0 or index >= _frame_visible_rects.size():
		return false
	if _scale_tween != null and _scale_tween.is_valid():
		_scale_tween.kill()
	_scale_tween = null
	_hovered = true
	_anim.visible = true
	_anim.stop()
	_anim.set_process(false)
	_anim.frame = index
	_apply_frame_geometry(index)
	_pivot.scale = Vector2.ONE * scale_factor
	return true


func rendered_visible_rect_world() -> Rect2:
	## Alpha-visible frame bounds transformed into map/world coordinates while
	## intentionally excluding the parent camera transform.
	if _anim == null or _pivot == null:
		return Rect2()
	var rect := _frame_rect(_anim.frame)
	var frame_center := FRAME_SIZE * 0.5
	var local_points := PackedVector2Array([
		rect.position - frame_center,
		Vector2(rect.end.x, rect.position.y) - frame_center,
		rect.end - frame_center,
		Vector2(rect.position.x, rect.end.y) - frame_center,
	])
	var world_xf := transform * _pivot.transform * _anim.transform
	var first := world_xf * local_points[0]
	var min_x := first.x
	var min_y := first.y
	var max_x := first.x
	var max_y := first.y
	for local_point in local_points:
		var p := world_xf * local_point
		min_x = minf(min_x, p.x)
		min_y = minf(min_y, p.y)
		max_x = maxf(max_x, p.x)
		max_y = maxf(max_y, p.y)
	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


func rendered_visible_bottom_center_world() -> Vector2:
	var rect := rendered_visible_rect_world()
	return Vector2(rect.get_center().x, rect.end.y)


func kill_tweens() -> void:
	if _scale_tween != null and _scale_tween.is_valid():
		_scale_tween.kill()
	_scale_tween = null


func _on_animation_frame_changed() -> void:
	if _anim != null:
		_apply_frame_geometry(_anim.frame)


func _apply_frame_geometry(index: int) -> void:
	if _anim == null:
		return
	var rect := _frame_rect(index)
	var frame_scale := _scale_for_frame(rect)
	var frame_center := FRAME_SIZE * 0.5
	var visible_bottom_center := Vector2(rect.get_center().x, rect.end.y)
	_anim.scale = frame_scale
	# AnimatedSprite2D is centred on the full 256px cell. Translate the alpha
	# bottom-centre to the overlay origin after applying this frame's scale.
	_anim.position = -(visible_bottom_center - frame_center) * frame_scale


func _scale_for_frame(rect: Rect2) -> Vector2:
	return Vector2.ONE * _uniform_frame_scale


func _frame_rect(index: int) -> Rect2:
	if _frame_visible_rects.is_empty():
		return Rect2(Vector2.ZERO, FRAME_SIZE)
	return _frame_visible_rects[clampi(index, 0, _frame_visible_rects.size() - 1)]


func _load_frame_visible_rects(anim_path: String, atlas: Texture2D, frame_count: int) -> Array[Rect2]:
	var result: Array[Rect2] = []
	# The asset pipeline stores alpha>32 bboxes for every frame beside the atlas.
	# Loading them avoids 33M get_pixel calls during scene startup. If an older
	# asset has no valid manifest, fall back to scanning the actual atlas.
	var manifest_path := anim_path.get_base_dir().path_join("manifest.json")
	if FileAccess.file_exists(manifest_path):
		var file := FileAccess.open(manifest_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				var entries: Array = parsed.get("frames", [])
				if entries.size() >= frame_count:
					for index in range(frame_count):
						var raw: Array = (entries[index] as Dictionary).get("bbox", [])
						if raw.size() != 4:
							result.clear()
							break
						# Manifest follows PIL getbbox: right/bottom are exclusive.
						var rect := Rect2(
							float(raw[0]), float(raw[1]),
							float(raw[2]) - float(raw[0]),
							float(raw[3]) - float(raw[1])
						)
						if rect.size.x < 1.0 or rect.size.y < 1.0:
							result.clear()
							break
						result.append(rect)
	if result.size() == frame_count:
		return result

	result.clear()
	var img := atlas.get_image()
	if img == null:
		for _index in range(frame_count):
			result.append(Rect2(Vector2.ZERO, FRAME_SIZE))
		return result
	for index in range(frame_count):
		var ox := (index % ATLAS_COLUMNS) * int(FRAME_SIZE.x)
		var oy := int(index / ATLAS_COLUMNS) * int(FRAME_SIZE.y)
		var rect := _alpha_bbox_image(img, ox, oy, int(FRAME_SIZE.x), int(FRAME_SIZE.y))
		if rect.size.x < 1.0 or rect.size.y < 1.0:
			rect = Rect2(Vector2.ZERO, FRAME_SIZE)
		result.append(rect)
	return result


func _alpha_bbox_image(img: Image, ox: int, oy: int, w: int, h: int) -> Rect2:
	if img == null:
		return Rect2()
	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	var iw := img.get_width()
	var ih := img.get_height()
	for y in range(h):
		var py := oy + y
		if py < 0 or py >= ih:
			continue
		for x in range(w):
			var px := ox + x
			if px < 0 or px >= iw:
				continue
			if img.get_pixel(px, py).a > ALPHA_THRESHOLD:
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	if max_x < min_x:
		return Rect2()
	return Rect2(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


func _build_frames(atlas: Texture2D, frame_count: int, fps: float) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("hover")
	frames.set_animation_loop("hover", true)
	frames.set_animation_speed("hover", fps)
	for index in range(frame_count):
		var tex := AtlasTexture.new()
		tex.atlas = atlas
		tex.region = Rect2(
			Vector2(index % ATLAS_COLUMNS, int(index / ATLAS_COLUMNS)) * FRAME_SIZE,
			FRAME_SIZE
		)
		frames.add_frame("hover", tex)
	return frames
