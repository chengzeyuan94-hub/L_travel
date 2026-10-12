extends Control
## Screen-sized landing markers and a landscape brush. The brush only gathers a
## preview; the document is changed once, on release, by the workshop root.
signal stroke_finished(points: Array, radius: float)
signal stroke_rejected(message: String)
signal suggestion_selected(index: int)

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const GREEN := Color("#367C43")
const AMBER := Color("#E8AE4C")
const MAX_STROKE_POINTS := 96
var board: Control
var tool := ""
var radius := 4.0
var points: Array = []
var painting := false
var pointer := Vector3.INF
var suggestions: Array = []
var suggestion_buttons: Array[Button] = []
var suggestion_kind := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func set_tool(op: String, brush_radius := 4.0) -> void:
	cancel_stroke()
	tool = op
	radius = brush_radius
	pointer = Vector3.INF
	queue_redraw()


func cancel_stroke() -> bool:
	var was_painting := painting
	painting = false
	points.clear()
	queue_redraw()
	return was_painting


func consume_event(event: InputEvent) -> bool:
	if tool == "":
		return false
	if event is InputEventMouseMotion:
		pointer = board._ground_at(event.position)
		var was_painting := painting
		if painting:
			_append_point(pointer)
		queue_redraw()
		return was_painting
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pointer = board._ground_at(event.position)
		if event.pressed:
			get_viewport().gui_release_focus()
			painting = pointer != Vector3.INF
			points.clear()
			if painting:
				_append_point(pointer)
		else:
			if painting:
				_append_point(pointer)
				var stroke := points.duplicate()
				cancel_stroke()
				if not stroke.is_empty():
					stroke_finished.emit(stroke, radius)
		queue_redraw()
		return true
	return false


func _append_point(p: Vector3) -> void:
	if p == Vector3.INF:
		return
	var at := Vector2(p.x, p.z)
	if at.x < 0.0 or at.x > 128.0 or at.y < 0.0 or at.y > 59.63125:
		return
	if points.is_empty():
		points.append(at)
		return
	# Mouse events are sparse during a quick sweep: fill their segment so the
	# brush produces a continuous strip rather than isolated circles.
	var step := radius * 0.65
	while (points.back() as Vector2).distance_to(at) >= step:
		if points.size() >= MAX_STROKE_POINTS:
			cancel_stroke()
			stroke_rejected.emit("这一笔太长了，请分两笔画；刚才这一笔没有应用。")
			return
		var previous: Vector2 = points.back()
		points.append(previous.move_toward(at, step))


func set_suggestions(spots: Array, kind: String) -> void:
	# Keep existing controls alive while background search appends candidates;
	# replacing a pressed button between mouse-down and mouse-up loses the click.
	while suggestion_buttons.size() > spots.size():
		var b: Button = suggestion_buttons.pop_back()
		remove_child(b)
		b.queue_free()
	suggestions = spots.duplicate(true)
	suggestion_kind = kind
	for i in suggestions.size():
		if i < suggestion_buttons.size():
			continue
		var b := Kit.button(str(i + 1), "primary", 48, 24)
		b.name = "LandingSpot%d" % (i + 1)
		b.custom_minimum_size = Vector2(48, 48)
		b.size = Vector2(48, 48)
		b.tooltip_text = "点击把选中的城移到这里" if kind == "move" else "点击在这里放城并生成搭档"
		b.pressed.connect(func() -> void: suggestion_selected.emit(i))
		add_child(b)
		suggestion_buttons.append(b)
	_update_markers()


func _process(_dt: float) -> void:
	_update_markers()
	if tool != "":
		# Releasing outside the board must not leave a half stroke armed.
		if painting and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			cancel_stroke()
		queue_redraw()


func _update_markers() -> void:
	if board == null or board.world == null:
		return
	var placed: Array[Rect2] = []
	var obstacles: Array = board.get_parent()._guide_obstacles() if board.get_parent().has_method("_guide_obstacles") else []
	for i in suggestion_buttons.size():
		var s: Dictionary = suggestions[i]
		var p := Vector3(float(s.x), _height(float(s.x), float(s.z)) + 0.5, float(s.z))
		var xy: Vector2 = board._to_view(p)
		var b := suggestion_buttons[i]
		b.position = xy - Vector2(24, 52)
		for _attempt in 16:
			var hud_overlap := false
			for rect: Rect2 in obstacles:
				if rect.intersects(Rect2(b.position, Vector2(48, 48))):
					b.position.y = rect.end.y + 8.0
					hud_overlap = true
			if hud_overlap:
				continue
			var overlaps := false
			for rect in placed:
				if rect.intersects(Rect2(b.position, Vector2(48, 48))):
					overlaps = true
					break
			if not overlaps:
				break
			b.position.x += 54.0
		b.visible = Rect2(Vector2(4, 4), board.size - Vector2(52, 124)).has_point(b.position)
		if b.visible:
			placed.append(Rect2(b.position, Vector2(52, 52)))
	queue_redraw()


func _height(x: float, z: float) -> float:
	if board.geo != null and board.geo.real_geo != null:
		return board.geo.real_geo.height(x, z)
	return 0.0


func _draw() -> void:
	if board == null:
		return
	for i in suggestion_buttons.size():
		if not suggestion_buttons[i].visible:
			continue
		var s: Dictionary = suggestions[i]
		var anchor: Vector2 = board._to_view(Vector3(float(s.x), _height(float(s.x), float(s.z)) + 0.1, float(s.z)))
		var button_center := suggestion_buttons[i].position + Vector2(24, 44)
		draw_line(button_center, anchor, Color("#FFF8E7"), 5.0, true)
		draw_line(button_center, anchor, GREEN, 2.5, true)
		draw_circle(anchor, 6.0, Color("#FFF8E7"))
		draw_circle(anchor, 4.0, GREEN)
	if tool == "" or pointer == Vector3.INF:
		return
	var color := AMBER if tool == "flatten" else GREEN
	if tool == "clear_trees":
		color = Color("#C86E49")
	var ring := PackedVector2Array()
	for i in 49:
		var angle := TAU * i / 48.0
		var x := pointer.x + cos(angle) * radius
		var z := pointer.z + sin(angle) * radius
		ring.append(board._to_view(Vector3(x, _height(x, z) + 0.1, z)))
	var fill_ring := ring.slice(0, ring.size() - 1)
	if Geometry2D.triangulate_polygon(fill_ring).size() > 0:
		draw_colored_polygon(fill_ring, Color(color, 0.18))
	draw_polyline(ring, Color("#FFF8E7"), 6.0, true)
	draw_polyline(ring, color, 3.0, true)
	for p: Vector2 in points:
		draw_circle(board._to_view(Vector3(p.x, _height(p.x, p.y) + 0.2, p.y)), 5.0, color)


func debug_state() -> Dictionary:
	var visible_markers := 0
	for b in suggestion_buttons:
		if b.is_visible_in_tree():
			visible_markers += 1
	return {"tool": tool, "radius": radius, "painting": painting, "stroke_points": points.size(),
		"suggestions": suggestions.duplicate(true), "visible_markers": visible_markers, "kind": suggestion_kind}
