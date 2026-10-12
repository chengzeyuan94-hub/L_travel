extends MapPieceActor
class_name WorldMapPreviewPiece

## Preview-only piece wrapper: world root stays at topology coords.
## VisualRoot scales sprites/shadow/wake only — never the path position.

const TARGET_SCREEN_H := 30.0
const TARGET_SCREEN_H_MIN := 28.0
const TARGET_SCREEN_H_MAX := 32.0
## Linear filtering expands an alpha silhouette by roughly one composited screen
## pixel.  Size the source silhouette to 27--31 so the independently rasterized
## result lands inside the actual product contract of 28--32 px.
const RASTER_FILTER_MARGIN_PX := 1.0
const SOURCE_SILHOUETTE_H_MIN := TARGET_SCREEN_H_MIN - RASTER_FILTER_MARGIN_PX
const SOURCE_SILHOUETTE_H_MAX := TARGET_SCREEN_H_MAX - RASTER_FILTER_MARGIN_PX
const ALPHA_THRESHOLD := 32.0 / 255.0
const FRAME := 256

var _visual_root: Node2D
var _alpha_heights: Dictionary = {} # unit -> compatibility median; never used for scaling
var _alpha_bboxes: Dictionary = {} # unit -> 64 serializable frame measurements
var _frame_bbox_by_key: Dictionary = {} # "unit|dir|frame" -> Rect2 in frame pixels
var _frame_outline_by_key: Dictionary = {} # key -> alpha silhouette column extrema
var _alpha_stats: Dictionary = {} # unit -> min/max/stable screen scale
var _preview_visual_scale := 1.0


func setup(p_id: String, human: bool, start_transport: int) -> void:
	# VisualRoot owns on-screen size; keep MapPieceActor display_scale neutral.
	# This standalone preview validates movement visuals, not SFX. Suppress the
	# arrival one-shot so headless teardown cannot race AudioServer; the base
	# production actor remains enabled by default.
	arrival_sfx_enabled = false
	display_scale = 1.0
	super.setup(p_id, human, start_transport)
	_ensure_visual_root()
	_cache_alpha_bboxes()
	display_scale = 1.0
	_apply_idle_visual()
	_apply_visual_root_scale()


func set_transport(new_transport: int) -> void:
	var keep_pos := position
	super.set_transport(new_transport)
	display_scale = 1.0
	_apply_visual_root_scale()
	position = keep_pos
	logical_pos = keep_pos


func apply_camera_visual_scale(camera_display_scale: float) -> void:
	## One stable scale per unit keeps every source frame inside 28–32 screen px.
	## Camera zoom is cancelled here; the current frame is not used to derive its
	## own scale, so this measurement cannot prove itself true by construction.
	var unit := _unit_key()
	var stats: Dictionary = _alpha_stats.get(unit, {})
	var stable_screen_scale := float(stats.get("stable_screen_scale", TARGET_SCREEN_H / 181.0))
	var cam := maxf(camera_display_scale, 0.0001)
	_preview_visual_scale = stable_screen_scale / cam
	_apply_visual_root_scale()


func get_preview_visual_scale() -> float:
	return _preview_visual_scale


func get_alpha_bbox_manifest() -> Dictionary:
	var unit := _unit_key()
	var stats: Dictionary = _alpha_stats.get(unit, {})
	return {
		"unit": unit,
		"anchor_kind": "foot" if unit == "camel" else "waterline",
		"median_visible_height_px": _alpha_heights.get(unit, 0.0),
		"min_visible_height_px": stats.get("min_visible_height_px", 0.0),
		"max_visible_height_px": stats.get("max_visible_height_px", 0.0),
		"max_rotation_envelope_height_px": stats.get("max_rotation_envelope_height_px", 0.0),
		"stable_screen_scale": stats.get("stable_screen_scale", 0.0),
		"sample_bboxes": _alpha_bboxes.get(unit, []), # compatibility key; now all 64 frames
		"all_64_frames_scanned": (_alpha_bboxes.get(unit, []) as Array).size() == 64,
		"visual_root_scale": _preview_visual_scale,
		"piece_layer_must_be_one": true,
	}


func get_all_frame_alpha_metrics(unit: String = "") -> Dictionary:
	## Read-only debug API for falsifiable tests. Returned bboxes are source-frame
	## measurements; no camera or runtime scale is folded into them.
	if unit != "":
		return {
			"unit": unit,
			"stats": (_alpha_stats.get(unit, {}) as Dictionary).duplicate(true),
			"frames": (_alpha_bboxes.get(unit, []) as Array).duplicate(true),
		}
	return {
		"camel": get_all_frame_alpha_metrics("camel"),
		"ship": get_all_frame_alpha_metrics("ship"),
	}


func debug_set_direction_frame(dir: String, frame_index: int) -> bool:
	## Test-only pose control. It deliberately uses MapPieceActor's real direction
	## and anchor path instead of swapping textures behind the actor.
	if dir not in DIRS or frame_index < 0 or frame_index >= 8:
		return false
	_set_direction(dir, false, false)
	_sprite.frame = frame_index
	_apply_visual_root_scale()
	return true


func debug_step_motion_fixed(delta_seconds: float) -> bool:
	## Deterministic visual-evidence hook. The preview test pauses automatic
	## processing and advances the exact production movement integrator in fixed
	## 1/12-second steps, so GPU readback latency cannot skip poses. No movement
	## formula, duration, interpolation or state transition is duplicated here.
	if not is_animating() or delta_seconds <= 0.0:
		return false
	set_process(false)
	super._process(delta_seconds)
	# Parent completion deliberately keeps processing disabled; otherwise retain
	# manual stepping until the evidence sequence is complete.
	set_process(false)
	return true


func rendered_screen_anchor(_camera: MapCameraController) -> Vector2:
	## Transform the manifest foot/waterline through AnimatedSprite2D.offset,
	## Sprite transform, VisualRoot, map camera canvas and viewport. This is not
	## the piece/root origin, even though a correct offset usually makes them meet.
	if _sprite == null:
		return Vector2.ZERO
	var anchor_px := _manifest_anchor(_unit_key(), _current_dir)
	return _sprite.get_global_transform_with_canvas() * _frame_pixel_to_sprite_local(anchor_px)


func get_current_visible_screen_bbox() -> Rect2:
	## Exact current alpha bbox transformed through the same render hierarchy as
	## the AnimatedSprite2D. Rotation/squash/bob are therefore observable.
	if _sprite == null:
		return Rect2()
	var bbox := _current_frame_bbox()
	if bbox.size.x <= 0.0 or bbox.size.y <= 0.0:
		return Rect2()
	var xf := _sprite.get_global_transform_with_canvas()
	var key := _frame_key(_unit_key(), _current_dir, int(_sprite.frame))
	var outline: PackedVector2Array = _frame_outline_by_key.get(key, PackedVector2Array())
	if outline.is_empty():
		outline = PackedVector2Array([
			bbox.position,
			Vector2(bbox.end.x, bbox.position.y),
			bbox.end,
			Vector2(bbox.position.x, bbox.end.y),
		])
	var first := xf * _frame_pixel_to_sprite_local(outline[0])
	var min_x := first.x
	var min_y := first.y
	var max_x := first.x
	var max_y := first.y
	for source_point in outline:
		var screen_point := xf * _frame_pixel_to_sprite_local(source_point)
		min_x = minf(min_x, screen_point.x)
		min_y = minf(min_y, screen_point.y)
		max_x = maxf(max_x, screen_point.x)
		max_y = maxf(max_y, screen_point.y)
	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


func get_current_frame_render_metrics() -> Dictionary:
	var source_bbox := _current_frame_bbox()
	var screen_bbox := get_current_visible_screen_bbox()
	return {
		"unit": _unit_key(),
		"anchor_kind": "foot" if _unit_key() == "camel" else "waterline",
		"direction": _current_dir,
		"frame": int(_sprite.frame) if _sprite != null else -1,
		"source_anchor": _manifest_anchor(_unit_key(), _current_dir),
		"source_bbox": [source_bbox.position.x, source_bbox.position.y, source_bbox.size.x, source_bbox.size.y],
		"screen_bbox": [screen_bbox.position.x, screen_bbox.position.y, screen_bbox.size.x, screen_bbox.size.y],
		"screen_anchor": rendered_screen_anchor(null),
		"sprite_offset": _sprite.offset if _sprite != null else Vector2.ZERO,
		"sprite_position": _sprite.position if _sprite != null else Vector2.ZERO,
		"sprite_rotation": _sprite.rotation if _sprite != null else 0.0,
		"visual_root_scale": _visual_root.scale if _visual_root != null else Vector2.ZERO,
	}


func measure_screen_visible_height(_camera: MapCameraController) -> float:
	return get_current_visible_screen_bbox().size.y


func _ensure_visual_root() -> void:
	if _visual_root != null:
		return
	_ensure_nodes()
	_visual_root = Node2D.new()
	_visual_root.name = "VisualRoot"
	add_child(_visual_root)
	# Reparent visual children under VisualRoot; root keeps world position.
	for node in [_shadow, _wake, _ring, _sprite, _label]:
		if node == null:
			continue
		if node.get_parent() == self:
			remove_child(node)
			_visual_root.add_child(node)


func _apply_visual_root_scale() -> void:
	if _visual_root == null:
		return
	_visual_root.scale = Vector2(_preview_visual_scale, _preview_visual_scale)
	# Keep MapPieceActor deform base at 1 so squash tweens don't fight VisualRoot.
	display_scale = 1.0
	if _sprite != null and not is_animating():
		_sprite.scale = Vector2.ONE


func _play_depart_squash() -> void:
	## The production actor's 0.90–1.10 squash is useful at its native size, but
	## would push this screen-locked preview below 28px. Keep the wrapper's single
	## stable size; movement interpolation and timing remain inherited unchanged.
	_cancel_preview_deform()


func _play_arrive_bounce() -> void:
	_cancel_preview_deform()


func _play_turn_squash() -> void:
	_cancel_preview_deform()


func _cancel_preview_deform() -> void:
	if _tween_deform != null and _tween_deform.is_valid():
		_tween_deform.kill()
	_tween_deform = null
	if _sprite != null:
		_sprite.scale = Vector2.ONE


func _unit_key() -> String:
	return "camel" if transport == GameData.Transport.CAMEL else "ship"


func _manifest_anchor(unit: String, dir: String) -> Vector2:
	var fallback_y := 220.0 if unit == "camel" else 190.0
	var anchor := Vector2(128.0, fallback_y)
	for entry in _manifest.get("units", []):
		if String(entry.get("unit", "")) == unit and String(entry.get("direction", "")) == dir:
			var a: Array = entry.get("anchor", [128.0, fallback_y])
			if a.size() >= 2:
				anchor = Vector2(float(a[0]), float(a[1]))
			break
	return anchor


func _frame_pixel_to_sprite_local(frame_pixel: Vector2) -> Vector2:
	## AnimatedSprite2D is centered. Sprite2D.offset participates in drawing but
	## is not part of Node2D's transform, so include it explicitly here.
	var centered_origin := Vector2(FRAME, FRAME) * 0.5 if _sprite.centered else Vector2.ZERO
	var local := frame_pixel - centered_origin
	if _sprite.flip_h:
		local.x = -local.x
	if _sprite.flip_v:
		local.y = -local.y
	return local + _sprite.offset


func _current_frame_bbox() -> Rect2:
	if _sprite == null:
		return Rect2()
	return _frame_bbox_by_key.get(_frame_key(_unit_key(), _current_dir, int(_sprite.frame)), Rect2()) as Rect2


func _frame_key(unit: String, dir: String, frame_index: int) -> String:
	return "%s|%s|%d" % [unit, dir, frame_index]


func _cache_alpha_bboxes() -> void:
	_alpha_heights.clear()
	_alpha_bboxes.clear()
	_frame_bbox_by_key.clear()
	_frame_outline_by_key.clear()
	_alpha_stats.clear()
	for unit in ["camel", "ship"]:
		var heights: Array = []
		var boxes: Array = []
		var max_rotation_envelope_h := 0.0
		var suffix := "walk_8f" if unit == "camel" else "sail_8f"
		for dir in DIRS:
			var path := "res://assets/game/pieces/%s/%s_%s_%s.png" % [unit, unit, dir, suffix]
			if not ResourceLoader.exists(path):
				continue
			var tex := load(path) as Texture2D
			if tex == null:
				continue
			var img := tex.get_image()
			if img == null:
				continue
			for fi in range(8):
				var measured := _measure_alpha_region(img, fi * FRAME, 0, FRAME, FRAME)
				var bbox: Rect2 = measured.get("bbox", Rect2())
				if bbox.size.y > 1.0:
					heights.append(bbox.size.y)
					var key := _frame_key(unit, dir, fi)
					_frame_bbox_by_key[key] = bbox
					_frame_outline_by_key[key] = measured.get("outline", PackedVector2Array())
					var envelope_h := bbox.size.y
					if unit == "ship":
						var sway := deg_to_rad(absf(SHIP_SWAY_DEG))
						envelope_h = bbox.size.y * cos(sway) + bbox.size.x * sin(sway)
					max_rotation_envelope_h = maxf(max_rotation_envelope_h, envelope_h)
					boxes.append({
						"dir": dir,
						"frame": fi,
						"bbox": [bbox.position.x, bbox.position.y, bbox.size.x, bbox.size.y],
						"visible_width_px": bbox.size.x,
						"visible_height_px": bbox.size.y,
					})
		heights.sort()
		var median := 178.0
		var min_h := 178.0
		var max_h := 192.0
		if not heights.is_empty():
			median = float(heights[int(heights.size() / 2)])
			min_h = float(heights[0])
			max_h = float(heights[heights.size() - 1])
		if max_rotation_envelope_h <= 0.0:
			max_rotation_envelope_h = max_h
		# The hard 28--32px contract is checked from real viewport pixels.  Source
		# alpha bounds must reserve one pixel for the linear-filter footprint.
		var lower_scale := SOURCE_SILHOUETTE_H_MIN / maxf(min_h, 1.0)
		var upper_scale := SOURCE_SILHOUETTE_H_MAX / maxf(max_rotation_envelope_h, 1.0)
		var stable_scale := (TARGET_SCREEN_H - RASTER_FILTER_MARGIN_PX) / maxf(median, 1.0)
		if lower_scale <= upper_scale:
			stable_scale = (lower_scale + upper_scale) * 0.5
		else:
			# Asset variation cannot satisfy the range with one scale. Keep the
			# largest frames inside the hard maximum and expose feasibility=false.
			stable_scale = upper_scale
		_alpha_heights[unit] = median
		_alpha_bboxes[unit] = boxes
		_alpha_stats[unit] = {
			"frame_count": boxes.size(),
			"min_visible_height_px": min_h,
			"max_visible_height_px": max_h,
			"max_rotation_envelope_height_px": max_rotation_envelope_h,
			"stable_screen_scale": stable_scale,
			"predicted_min_screen_height_px": min_h * stable_scale,
			"predicted_max_screen_height_px": max_rotation_envelope_h * stable_scale,
			"raster_filter_margin_px": RASTER_FILTER_MARGIN_PX,
			"stable_scale_feasible": lower_scale <= upper_scale,
		}


func _measure_alpha_region(img: Image, ox: int, oy: int, w: int, h: int) -> Dictionary:
	## For every non-empty source column keep the top/bottom pixel-square corners.
	## Any affine screen-space x/y extremum of the alpha silhouette must occur at
	## one of these points, so the runtime bbox remains exact under sway/scale.
	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	var iw := img.get_width()
	var ih := img.get_height()
	var outline := PackedVector2Array()
	for x in range(w):
		var px := ox + x
		if px < 0 or px >= iw:
			continue
		var column_min_y := h
		var column_max_y := -1
		for y in range(h):
			var py := oy + y
			if py < 0 or py >= ih:
				continue
			if img.get_pixel(px, py).a > ALPHA_THRESHOLD:
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
				column_min_y = mini(column_min_y, y)
				column_max_y = maxi(column_max_y, y)
		if column_max_y >= column_min_y:
			# Pixel squares occupy [x,x+1] × [y,y+1], not just their centers.
			outline.append(Vector2(x, column_min_y))
			outline.append(Vector2(x + 1, column_min_y))
			outline.append(Vector2(x, column_max_y + 1))
			outline.append(Vector2(x + 1, column_max_y + 1))
	if max_x < min_x:
		return {"bbox": Rect2(), "outline": PackedVector2Array()}
	return {
		"bbox": Rect2(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1),
		"outline": outline,
	}
