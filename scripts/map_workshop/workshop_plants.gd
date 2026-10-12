extends PanelContainer
## 单株工具：表单是未提交草稿；拖动只更新现有 MultiMesh transform，松手才请求一次事务。
signal requested(id: String, row: Dictionary, source_sha: String)
signal ended
signal file_requested(exporting: bool)
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const Backend := preload("res://scripts/map_workshop/workshop_backend.gd")
var board: Control
var document
var active := false
var adding := false
var selected := ""
var _layout := {}
var _ids: Array = []
var _fields := {}
var _type: OptionButton
var _message: Label
var _apply_button: Button
var _delete_button: Button
var _add_button: Button
var _cancel_button: Button
var _draft := {}
var _source_sha := ""
var _source_map_id := ""
var _read_error := ""
var _press := {}
var _drag := {}
var timings: Array = []
var _marker: Control
class Marker extends Control:
	func _draw() -> void:
		draw_arc(Vector2.ZERO, 20.0, 0, TAU, 48, Color("#FFF8E7"), 6.0, true)
		draw_arc(Vector2.ZERO, 20.0, 0, TAU, 48, Color("#E7AF48"), 3.0, true)
		draw_line(Vector2(0, -22), Vector2(0, -52), Color("#FFF8E7"), 3.0, true)

func _ready() -> void:
	name = "PlantTools"; position = Vector2(1520, 76); size = Vector2(400, 952)
	add_theme_stylebox_override("panel", Kit.satchel_box(20, 4, 22)); visible = false
	var col := VBoxContainer.new(); col.add_theme_constant_override("separation", 14); add_child(col)
	col.add_child(Kit.label("单株植物", 30, Kit.INK))
	col.add_child(Kit.label("点植物选择，拖动后松手提交。\n表单修改按「应用」，取消不写地图。", 20, Kit.INK_SOFT))
	_type = OptionButton.new(); _type.name = "PlantType"; _type.custom_minimum_size = Vector2(350, 50)
	for asset: String in CustomMapPlants.HASHES: _type.add_item(CustomMapPlants.NAMES[asset]); _type.set_item_metadata(_type.item_count - 1, asset)
	_style_input(_type)
	col.add_child(_type)
	for spec in [["x", "X"], ["z", "Z"], ["yaw", "朝向（度）"], ["scale", "大小（0.5–2.0）"]]:
		var box := HBoxContainer.new(); col.add_child(box)
		var label := Kit.label(str(spec[1]), 22, Kit.INK); label.custom_minimum_size.x = 145; box.add_child(label)
		var edit := LineEdit.new(); edit.name = "Plant_" + str(spec[0]); edit.custom_minimum_size = Vector2(185, 48); box.add_child(edit); _fields[spec[0]] = edit; _style_input(edit)
	_apply_button = Kit.button("应用这株修改", "primary", 52, 22); col.add_child(_apply_button); _apply_button.pressed.connect(_apply)
	_delete_button = Kit.button("删除这株（可撤销）", "cream", 52, 22); col.add_child(_delete_button); _delete_button.pressed.connect(_delete)
	_add_button = Kit.button("添加一株：再点陆地", "cream", 52, 22); col.add_child(_add_button); _add_button.pressed.connect(func() -> void:
		var kind := _type.selected; cancel_draft(); selected = ""; _draft.clear(); _type.select(kind); _apply_button.disabled = true; _delete_button.disabled = true; adding = true; _message.text = "选择类型，再点陆地放置一株。Esc 取消。")
	_cancel_button = Kit.button("取消本次修改", "cream", 52, 22); col.add_child(_cancel_button); _cancel_button.pressed.connect(cancel_draft)
	var close := Kit.button("结束植物编辑", "cream", 52, 22); col.add_child(close); close.pressed.connect(func() -> void: close_tools(); ended.emit())
	var files := HBoxContainer.new(); col.add_child(files)
	for spec in [[true, "导出 JSON"], [false, "导入 JSON"]]:
		var button := Kit.button(str(spec[1]), "cream", 44, 20); button.custom_minimum_size.x = 160; files.add_child(button); button.pressed.connect(func() -> void: file_requested.emit(bool(spec[0])))
	_message = Kit.label("", 20, Kit.INK_SOFT); _message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _message.custom_minimum_size.x = 350; col.add_child(_message)
	refresh()

func bind(b: Control, d) -> void:
	board = b; document = d
	board.set_meta("plant_editor", self)
	_marker = Marker.new(); _marker.mouse_filter = Control.MOUSE_FILTER_IGNORE; _marker.z_index = 20; board.add_child(_marker)
	var label := Kit.label("选中这株", 18, Kit.INK); label.position = Vector2(-44, -78); label.mouse_filter = Control.MOUSE_FILTER_IGNORE; _marker.add_child(label)
	refresh()

func _process(_delta: float) -> void:
	if not is_instance_valid(_marker): return
	_marker.visible = active and selected != "" and _ids.has(selected) and board.world != null
	if not _marker.visible: return
	var row: Dictionary = _layout.tree_kit[_ids.find(selected)]
	var point := Vector3(float(row.x), float(row.y) + CustomMapPlants.bounds(str(row.asset)).size.y * float(row.s), float(row.z))
	if not _drag.is_empty(): point = Vector3(float(_drag.x), board.geo.real_geo.height(float(_drag.x), float(_drag.z)) + CustomMapPlants.bounds(str(row.asset)).size.y * float(row.s), float(_drag.z))
	_marker.position = board._to_view(point)
	_marker.visible = Rect2(Vector2.ZERO, board.size).has_point(_marker.position)
	var label: Control = _marker.get_child(0)
	label.position = Vector2(clampf(-44.0, -_marker.position.x, board.size.x - _marker.position.x - label.size.x), maxf(-78.0, 4.0 - _marker.position.y))

func _exit_tree() -> void:
	if is_instance_valid(_marker): _marker.queue_free()

func _style_input(control: Control) -> void:
	var box := StyleBoxFlat.new(); box.bg_color = Color("#FFFDF7"); box.border_color = Kit.SATCHEL.lightened(0.35); box.set_border_width_all(2); box.set_corner_radius_all(10); box.content_margin_left = 12; box.content_margin_right = 12
	control.add_theme_stylebox_override("normal", box); control.add_theme_stylebox_override("focus", box)
	control.add_theme_font_override("font", Kit.font("body", 600)); control.add_theme_font_size_override("font_size", 22); control.add_theme_color_override("font_color", Kit.INK)

func open_tools() -> void:
	active = true; visible = true; refresh()
func close_tools() -> void:
	cancel_draft(); active = false; visible = false
func refresh() -> void:
	if board == null or document == null: return
	if _source_map_id != document.map_id():
		selected = ""; _draft.clear(); _press.clear(); _drag.clear(); adding = false
		if is_instance_valid(_marker): _marker.visible = false
		_source_map_id = document.map_id()
	var copy: Dictionary = document.doc.duplicate(true)
	if not copy.has("plants"):
		if CustomMapSchema.schema_version_of(str(copy.schema)) < 2: copy.schema = CustomMapPlants.SCHEMA
		copy.plants = CustomMapPlants.layer()
	_layout = Backend.derive(board.base_layout, copy, board.geo)
	_ids = _layout.get("plant_ids", [])
	_source_sha = document.sha()
	if selected != "" and _ids.has(selected):
		var row: Dictionary = _layout.tree_kit[_ids.find(selected)]
		if float(row.s) > 0.0 and not _layout.get("decor_cleared", {}).get("tree_kit", []).has(_ids.find(selected)): _set_draft(CustomMapPlants.record(row))
		else: selected = ""; _draft.clear()
	elif selected != "": selected = ""; _draft.clear()
	_apply_button.disabled = selected == ""; _delete_button.disabled = selected == ""
	var n := 0
	for id in document.doc.get("plants", {}).get("instances", {}):
		if str(id).begins_with("new:"): n += 1
	_message.text = "单株新增 %d/%d（含已隐藏）；\n覆盖 %d/%d 条，原笔刷预算另计。" % [n, CustomMapPlants.MAX_NEW, document.doc.get("plants", {}).get("instances", {}).size(), CustomMapPlants.MAX_RECORDS]

func _set_draft(row: Dictionary) -> void:
	_draft = row.duplicate(true)
	for i in _type.item_count:
		if _type.get_item_metadata(i) == row.asset: _type.select(i)
	for key: String in _fields:
		var value := float(row[key])
		if key == "yaw": value = rad_to_deg(value); value = value - 360.0 if value > 180.0 else value
		_fields[key].text = "%.3f" % value

func select_plant(id: String) -> bool:
	cancel_draft()
	if not _ids.has(id): return false
	var i := _ids.find(id); var row: Dictionary = _layout.tree_kit[i]
	if float(row.s) <= 0.0 or _layout.get("decor_cleared", {}).get("tree_kit", []).has(i): return false
	selected = id; _set_draft(CustomMapPlants.record(row)); _apply_button.disabled = false; _delete_button.disabled = false
	_message.text = CustomMapPlants.NAMES[row.asset] + " 已选中；修改后应用，或拖动。"
	return true

func _read() -> Dictionary:
	_read_error = "请输入有限数字，当前地图没有改变。"
	var row := {"asset": _type.get_item_metadata(_type.selected), "hidden": false}
	for key: String in _fields:
		if not _fields[key].text.is_valid_float(): return {}
		var n: float = _fields[key].text.to_float()
		if not is_finite(n): return {}
		# Check the typed value before quantization, including values just beyond an endpoint.
		var limits: Array = {"x": [0.0, CustomMapLandscape.MAX_X], "z": [0.0, CustomMapLandscape.MAX_Z], "yaw": [-180.0, 360.0], "scale": [CustomMapPlants.MIN_SCALE, CustomMapPlants.MAX_SCALE]}[key]
		if n < float(limits[0]) or n > float(limits[1]):
			_read_error = "大小应在 0.5–2.0 之间，地图未改变。" if key == "scale" else ("朝向应在 -180–360 度之间，地图未改变。" if key == "yaw" else "植物坐标超出棋盘，地图未改变。")
			return {}
		var value := snappedf(deg_to_rad(n) if key == "yaw" else n, 0.001)
		# The shared JSON precision can round -PI below the valid lower bound.
		# Only a raw-valid angle gets an equivalent positive representation.
		if key == "yaw" and value < -PI: value = snappedf(deg_to_rad(n) + TAU, 0.001)
		row[key] = value
	return row
func _apply() -> void:
	if selected == "": return
	var row := _read()
	if row.is_empty(): _message.text = _read_error; return
	requested.emit(selected, row, _source_sha)
func _delete() -> void:
	if selected == "" or _draft.is_empty(): return
	var row := _draft.duplicate(true); row.hidden = true
	requested.emit(selected, row, _source_sha)
func reject(reason: String) -> void:
	_restore_preview(); _press.clear(); _drag.clear(); _message.text = reason + "；没有应用。"
func cancel_draft() -> void:
	_restore_preview(); _press.clear(); _drag.clear(); adding = false
	if selected != "" and _ids.has(selected): _set_draft(CustomMapPlants.record(_layout.tree_kit[_ids.find(selected)]))
	if _message != null: _message.text = "本次修改已取消，地图未变。"

func _pick(pos: Vector2) -> String:
	var camera: Camera3D = board.world.camera
	var origin := camera.project_ray_origin(pos * board._render_scale)
	var direction := camera.project_ray_normal(pos * board._render_scale)
	var best := INF; var result := ""
	var cleared: Array = _layout.get("decor_cleared", {}).get("tree_kit", [])
	for i in _ids.size():
		var row: Dictionary = _layout.tree_kit[i]
		if float(row.s) <= 0.0 or cleared.has(i): continue
		var xf := _transform(row); var inv := xf.affine_inverse()
		var hit: Variant = CustomMapPlants.bounds(str(row.asset)).intersects_ray(inv * origin, inv.basis * direction)
		if hit is Vector3:
			var distance: float = (xf * hit).distance_to(origin)
			if distance < best: best = distance; result = str(_ids[i])
	return result
func _transform(row: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, float(row.yaw)).scaled(Vector3.ONE * float(row.s)), Vector3(float(row.x), float(row.y), float(row.z)))
func _preview(row: Dictionary) -> void:
	var i := _ids.find(selected)
	if i < 0: return
	var original: Dictionary = _layout.tree_kit[i]
	var y: float = board.geo.real_geo.height(float(row.x), float(row.z)) - CustomMapPlants.bounds(str(row.asset)).position.y * float(row.scale)
	var next := Transform3D(Basis(Vector3.UP, float(row.yaw)).scaled(Vector3.ONE * float(row.scale)), Vector3(float(row.x), y, float(row.z)))
	var change := next * _transform(original).affine_inverse()
	for e: Array in board.world.decor_index.get("tree_kit", {}).get(i, []): (e[0] as MultiMesh).set_instance_transform(int(e[1]), change * (e[2] as Transform3D))
func _restore_preview() -> void:
	if board == null or board.world == null or selected == "": return
	var i := _ids.find(selected)
	for e: Array in board.world.decor_index.get("tree_kit", {}).get(i, []): (e[0] as MultiMesh).set_instance_transform(int(e[1]), e[2])

func consume_event(event: InputEvent) -> bool:
	if not active: return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			get_viewport().gui_release_focus()
			if adding:
				var p: Vector3 = board._ground_at(event.position)
				if p != Vector3.INF:
					adding = false
					requested.emit(CustomMapPlants.new_id(), {"asset": _type.get_item_metadata(_type.selected), "x": snappedf(p.x,0.001), "z": snappedf(p.z,0.001), "yaw": 0.0, "scale": 1.0, "hidden": false}, document.sha())
				return true
			var id := _pick(event.position)
			if id != "" and select_plant(id): _press = {"pos": event.position, "sha": document.sha()}; return true
			selected = ""; refresh(); return true
		elif not _press.is_empty():
			var sha: String = _press.sha
			var row := _drag.duplicate(true); _restore_preview(); _press.clear(); _drag.clear()
			if not row.is_empty(): requested.emit(selected, row, sha)
			return true
	if event is InputEventMouseMotion and not _press.is_empty():
		if event.position.distance_to(_press.pos) < 6.0: return true
		var start := Time.get_ticks_usec()
		if document.sha() != _press.sha: cancel_draft(); return true
		var p: Vector3 = board._ground_at(event.position)
		if p != Vector3.INF:
			var row := _draft.duplicate(true); row.x = snappedf(p.x,0.001); row.z = snappedf(p.z,0.001)
			var reason := CustomMapPlants.placement_error(_layout, row, board.geo.real_geo)
			if reason == "": _drag = row; _preview(row); _message.text = "松手提交一次；Esc 取消拖动。"
			else: _drag.clear(); _restore_preview(); _message.text = reason
		timings.append((Time.get_ticks_usec() - start) / 1000.0)
		return true
	return false
