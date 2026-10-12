extends Node3D
## 旅人场景摆放编辑器 · C4D 式操作
##
## 设计约束：**不修改任何现有脚本或场景**。把 traveler_main.tscn 原样实例化，
## 等两帧让 atlas_viewer.gd 建完世界，再在运行时接管相机、把物件挂到新建的 PlacerRoot 下。
##
## 照 C4D 的操作逻辑：
##   对象管理器（左上）   列表，点选，Shift 加选，● 显隐，✕ 删除，名称可改
##   坐标面板（左下）     P.X/Y/Z  S.X/Y/Z  R.H/P/B 九个数值框，直接敲数字即生效
##   E / R / T           移动 / 缩放 / 旋转 模式
##   轴向手柄            选中物上画红绿蓝三轴，拖某一根就只沿那一根动
##   Alt+左键拖  环绕    Alt+中键拖  平移    Alt+右键拖 / 滚轮  推拉
##   Ctrl+D 复制   Ctrl+A 全选   Ctrl+Z 撤销   Ctrl+S 保存工程   Ctrl+E 导出 JSON
##   C 回冻结机位   Tab 隐藏编辑器面板   U 场景自带界面（默认藏起）   B 景深   G 程序化远景   F 对准

const PROJECT_PATH := "res://data/traveler/placement.json"
const EXPORT_PATH := "res://data/traveler/placement-export.json"
const HERO_VIEW := "changan"

enum Mode { MOVE, SCALE, ROTATE }

const PALETTE := [
	{"id": "massif", "label": "雪山 T7", "path": "res://assets/traveler/mountains/t7-snow-massif.glb", "scale": 2.4},
	{"id": "cypress", "label": "柏树", "path": "res://generated/traveler/atlas/assets/prototypes/cypress.glb", "scale": 1.0},
	{"id": "gold", "label": "金叶树", "path": "res://generated/traveler/atlas/assets/prototypes/gold.glb", "scale": 1.0},
	{"id": "copper", "label": "铜叶树", "path": "res://generated/traveler/atlas/assets/prototypes/copper.glb", "scale": 1.0},
	{"id": "olive", "label": "橄榄树", "path": "res://generated/traveler/atlas/assets/prototypes/olive.glb", "scale": 1.0},
	{"id": "dry", "label": "枯树", "path": "res://generated/traveler/atlas/assets/prototypes/dry.glb", "scale": 1.0},
	{"id": "sage", "label": "灰绿树", "path": "res://generated/traveler/atlas/assets/prototypes/sage.glb", "scale": 1.0},
	{"id": "cloud_bank", "label": "云·层", "path": "res://generated/traveler/lookdev/cloud_bank.glb", "scale": 4.0},
	{"id": "cloud_cumulus", "label": "云·积", "path": "res://generated/traveler/lookdev/cloud_cumulus.glb", "scale": 4.0},
	{"id": "cloud_drifter", "label": "云·絮", "path": "res://generated/traveler/lookdev/cloud_drifter.glb", "scale": 4.0},
]

const AXIS_COLORS := [Color(0.95, 0.27, 0.32), Color(0.45, 0.85, 0.30), Color(0.30, 0.55, 0.95)]
const AXIS_VECTORS := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]

var viewer: Node3D
var cam: Camera3D
var placed_root: Node3D
var procedural_root: Node3D
var gizmo_root: Node3D
var gizmo_arms: Array = []

var objects: Array = []            # {id, name, pos, scale, rot(度), visible, node}
var sel: Array = []
var brush: int = 0
var mode: int = Mode.MOVE
var undo_stack: Array = []
var scene_cache: Dictionary = {}
var project_dirty := false

var drag_axis: int = -1
var drag_start_mouse := Vector2.ZERO
var drag_start_state: Array = []
var drag_origin := Vector3.ZERO
var nav: int = 0
var place_y: float = -1.2
var dof_on := true

var pivot := Vector3.ZERO
var orbit_yaw := 0.62
var orbit_pitch := -0.23
var orbit_dist := 60.0
var hero_mode := true

var ui_layer: CanvasLayer
var ui_side: PanelContainer
var ui_top: PanelContainer
var list_box: VBoxContainer
var row_nodes: Array = []
var coord_fields: Dictionary = {}
var name_field: LineEdit
var mode_label: Label
var status: Label
var hud: Label
var suppress_field_sync := false


# =============================================================== 启动

func _ready() -> void:
	var main: PackedScene = load("res://scenes/traveler/traveler_main.tscn")
	var inst: Node = main.instantiate()
	add_child(inst)
	viewer = inst if inst is Node3D else inst.get_child(0)
	await get_tree().process_frame
	await get_tree().process_frame
	_takeover()
	_build_ui()
	_load_project()
	_snap_hero()
	var args := OS.get_cmdline_user_args()
	if "--placer-selftest" in args:
		_selftest()
		return
	for a in args:
		if a.begins_with("--placer-shot="):
			await _shot(a.trim_prefix("--placer-shot="))


func _takeover() -> void:
	cam = viewer.camera if "camera" in viewer else _find_camera(viewer)
	if cam == null:
		push_error("找不到相机；编辑器无法接管")
		return
	var world: Node3D = viewer.world if "world" in viewer else viewer
	placed_root = Node3D.new()
	placed_root.name = "PlacerRoot"
	world.add_child(placed_root)
	gizmo_root = Node3D.new()
	gizmo_root.name = "PlacerGizmo"
	gizmo_root.visible = false
	world.add_child(gizmo_root)
	_build_gizmo()
	if world.has_node("FarBackdrop"):
		procedural_root = world.get_node("FarBackdrop")
	# 场景自带的底栏会压住坐标面板，且它把 H 用作「隐藏界面」容易误导。默认藏掉，U 键可调回。
	_set_viewer_ui(false)


func _set_viewer_ui(on: bool) -> void:
	var u = viewer.get("ui")
	if u != null and is_instance_valid(u):
		u.visible = on


func _find_camera(n: Node) -> Camera3D:
	for c in n.find_children("*", "Camera3D", true, false):
		return c
	return null


func _build_gizmo() -> void:
	for i in 3:
		var arm := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.035
		cyl.bottom_radius = 0.035
		cyl.height = 1.0
		cyl.radial_segments = 6
		arm.mesh = cyl
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = AXIS_COLORS[i]
		m.disable_fog = true
		m.no_depth_test = true
		m.render_priority = 120
		arm.material_override = m
		arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		gizmo_root.add_child(arm)
		gizmo_arms.append(arm)


# =============================================================== 文档模型

func _palette_of(id: String) -> Dictionary:
	for p in PALETTE:
		if p.id == id:
			return p
	return {}


func _scene_for(id: String) -> PackedScene:
	if scene_cache.has(id):
		return scene_cache[id]
	var p := _palette_of(id)
	if p.is_empty():
		return null
	var s: PackedScene = load(p.path)
	scene_cache[id] = s
	return s


func _spawn(o: Dictionary) -> Node3D:
	var s: PackedScene = _scene_for(String(o.id))
	if s == null:
		return null
	var n: Node3D = s.instantiate()
	for m in n.find_children("*", "MeshInstance3D", true, false):
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	placed_root.add_child(n)
	o["node"] = n
	_apply(o)
	return n


func _apply(o: Dictionary) -> void:
	var n = o.get("node")
	if n == null or not is_instance_valid(n):
		return
	n.position = o.pos
	n.scale = o.scale
	n.rotation = Vector3(deg_to_rad(o.rot.x), deg_to_rad(o.rot.y), deg_to_rad(o.rot.z))
	n.visible = bool(o.get("visible", true))


func _add(id: String, at: Vector3) -> int:
	var p := _palette_of(id)
	var sc: float = float(p.get("scale", 1.0))
	var n := 1
	for o in objects:
		if String(o.id) == id:
			n += 1
	var obj := {
		"id": id,
		"name": "%s_%02d" % [String(p.get("label", id)), n],
		"pos": at,
		"scale": Vector3(sc, sc, sc),
		"rot": Vector3(0.0, rad_to_deg(randf_range(-PI, PI)), 0.0),
		"visible": true,
	}
	_spawn(obj)
	objects.append(obj)
	return objects.size() - 1


func _state() -> Array:
	var out: Array = []
	for o in objects:
		out.append({"id": o.id, "name": o.name, "pos": o.pos, "scale": o.scale,
			"rot": o.rot, "visible": o.get("visible", true)})
	return out


func _restore(snap: Array) -> void:
	for o in objects:
		var n = o.get("node")
		if n != null and is_instance_valid(n):
			n.queue_free()
	objects.clear()
	sel.clear()
	for s in snap:
		var obj := {"id": String(s.id), "name": String(s.get("name", s.id)),
			"pos": s.pos, "scale": s.scale, "rot": s.rot,
			"visible": bool(s.get("visible", true))}
		_spawn(obj)
		objects.append(obj)
	_rebuild_list()
	_refresh()


func _push_undo() -> void:
	undo_stack.append(_state())
	if undo_stack.size() > 96:
		undo_stack.pop_front()
	project_dirty = true


func _undo() -> void:
	if undo_stack.is_empty():
		_note("没有可撤销的操作")
		return
	_restore(undo_stack.pop_back())
	_note("已撤销")


# =============================================================== 选择

func _select(i: int, additive: bool) -> void:
	if i < 0 or i >= objects.size():
		if not additive:
			sel.clear()
		_refresh()
		return
	if additive:
		if sel.has(i):
			sel.erase(i)
		else:
			sel.append(i)
	else:
		sel = [i]
	_refresh()


func _sel_center() -> Vector3:
	if sel.is_empty():
		return Vector3.ZERO
	var c := Vector3.ZERO
	for i in sel:
		c += objects[i].pos
	return c / float(sel.size())


func _duplicate_selection() -> void:
	if sel.is_empty():
		_note("先选一个物件")
		return
	_push_undo()
	var made: Array = []
	for i in sel:
		var src: Dictionary = objects[i]
		var idx := _add(String(src.id), src.pos + Vector3(4.0, 0.0, 4.0))
		objects[idx].scale = src.scale
		objects[idx].rot = src.rot
		_apply(objects[idx])
		made.append(idx)
	sel = made
	_rebuild_list()
	_refresh()
	_note("已复制 %d 个" % made.size())


func _delete_selection() -> void:
	if sel.is_empty():
		return
	_push_undo()
	var idxs: Array = sel.duplicate()
	idxs.sort()
	idxs.reverse()
	for i in idxs:
		var n = objects[i].get("node")
		if n != null and is_instance_valid(n):
			n.queue_free()
		objects.remove_at(i)
	sel.clear()
	_rebuild_list()
	_refresh()


# =============================================================== 轴向手柄

func _gizmo_scale() -> float:
	if cam == null or sel.is_empty():
		return 1.0
	return maxf(0.6, cam.global_position.distance_to(_sel_center()) * 0.085)


func _update_gizmo() -> void:
	if gizmo_root == null:
		return
	if sel.is_empty() or cam == null:
		gizmo_root.visible = false
		return
	gizmo_root.visible = true
	var c := _sel_center()
	var L := _gizmo_scale()
	gizmo_root.position = c
	for i in 3:
		var arm: MeshInstance3D = gizmo_arms[i]
		var axis: Vector3 = AXIS_VECTORS[i]
		arm.position = axis * L * 0.5
		arm.scale = Vector3(L, L, L)
		if i == 0:
			arm.rotation = Vector3(0.0, 0.0, -PI * 0.5)
		elif i == 1:
			arm.rotation = Vector3.ZERO
		else:
			arm.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		var mat: StandardMaterial3D = arm.material_override
		mat.albedo_color = AXIS_COLORS[i] if drag_axis != i else Color(1.0, 0.92, 0.35)


func _pick_axis(mouse: Vector2) -> int:
	if sel.is_empty() or cam == null:
		return -1
	var c := _sel_center()
	if cam.is_position_behind(c):
		return -1
	var o := cam.unproject_position(c)
	var L := _gizmo_scale()
	var best := -1
	var best_d := 18.0
	for i in 3:
		var tip: Vector3 = c + AXIS_VECTORS[i] * L
		if cam.is_position_behind(tip):
			continue
		var t: Vector2 = cam.unproject_position(tip)
		var d: float = _dist_to_segment(mouse, o, t)
		if d < best_d:
			best_d = d
			best = i
	return best


func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-6:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _axis_point(mouse: Vector2, axis_idx: int, origin: Vector3) -> float:
	## 鼠标射线与该轴直线的最近点，返回沿轴的标量位移。
	var ro := cam.project_ray_origin(mouse)
	var rd := cam.project_ray_normal(mouse)
	var ad: Vector3 = AXIS_VECTORS[axis_idx]
	var w0 := ro - origin
	var a := ad.dot(ad)
	var b := ad.dot(rd)
	var c := rd.dot(rd)
	var d := ad.dot(w0)
	var e := rd.dot(w0)
	var den := a * c - b * b
	if absf(den) < 1e-8:
		return 0.0
	return (b * e - c * d) / den


func _pick_object(mouse: Vector2) -> int:
	var best := -1
	var best_d := 1e9
	for i in objects.size():
		var o: Dictionary = objects[i]
		if not bool(o.get("visible", true)):
			continue
		if cam.is_position_behind(o.pos):
			continue
		var sp := cam.unproject_position(o.pos)
		var d := sp.distance_to(mouse)
		var tol: float = clampf(60.0 * o.scale.x, 22.0, 240.0)
		if d < tol and d < best_d:
			best_d = d
			best = i
	return best


# =============================================================== 输入

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		_on_key(ev)
	elif ev is InputEventMouseButton:
		_on_button(ev)
	elif ev is InputEventMouseMotion:
		_on_motion(ev)


func _on_key(ev: InputEventKey) -> void:
	var k: int = ev.keycode
	if ev.ctrl_pressed or ev.meta_pressed:
		match k:
			KEY_Z: _undo()
			KEY_S: _save_project()
			KEY_E: _export_json()
			KEY_D: _duplicate_selection()
			KEY_A:
				sel.clear()
				for i in objects.size():
					sel.append(i)
				_refresh()
		return
	match k:
		KEY_E:
			mode = Mode.MOVE
			_refresh()
		KEY_R:
			mode = Mode.SCALE
			_refresh()
		KEY_T:
			mode = Mode.ROTATE
			_refresh()
		KEY_C:
			_snap_hero()
		KEY_F:
			_frame_selection()
		KEY_TAB:
			if ui_top != null: ui_top.visible = not ui_top.visible
			if ui_side != null: ui_side.visible = not ui_side.visible
		KEY_U:
			var u = viewer.get("ui")
			if u != null and is_instance_valid(u):
				_set_viewer_ui(not u.visible)
				_note("场景自带界面 " + ("显示" if u.visible else "隐藏"))
		KEY_B:
			_toggle_dof()
		KEY_G:
			if procedural_root != null:
				procedural_root.visible = not procedural_root.visible
				_note("程序化远景 " + ("显示" if procedural_root.visible else "隐藏"))
		KEY_X, KEY_DELETE:
			_delete_selection()
		KEY_ESCAPE:
			sel.clear()
			_refresh()
		KEY_PAGEUP:
			place_y += 0.5
			_refresh()
		KEY_PAGEDOWN:
			place_y -= 0.5
			_refresh()
		_:
			if k >= KEY_1 and k <= KEY_9:
				var i: int = k - KEY_1
				if i < PALETTE.size():
					brush = i
					_refresh()
			elif k == KEY_0 and PALETTE.size() >= 10:
				brush = 9
				_refresh()


func _on_button(ev: InputEventMouseButton) -> void:
	if ev.alt_pressed:
		if ev.pressed:
			match ev.button_index:
				MOUSE_BUTTON_LEFT: nav = 1
				MOUSE_BUTTON_MIDDLE: nav = 2
				MOUSE_BUTTON_RIGHT: nav = 3
		else:
			nav = 0
		return
	if ev.button_index == MOUSE_BUTTON_WHEEL_UP or ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		var f: float = 0.9 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.9
		orbit_dist = clampf(orbit_dist * f, 2.0, 600.0)
		_drive_camera()
		return
	if ev.button_index != MOUSE_BUTTON_LEFT:
		return
	if ev.pressed:
		var ax := _pick_axis(ev.position)
		if ax >= 0:
			drag_axis = ax
			drag_start_mouse = ev.position
			drag_origin = _sel_center()
			_push_undo()
			drag_start_state = _state()
			_refresh()
			return
		var hit := _pick_object(ev.position)
		if hit >= 0:
			_select(hit, ev.shift_pressed)
		else:
			var p: Variant = _ray_plane(ev.position)
			if p != null:
				_push_undo()
				var idx := _add(String(PALETTE[brush].id), p)
				sel = [idx]
				_rebuild_list()
				_refresh()
	else:
		drag_axis = -1
		_refresh()


func _ray_plane(mouse: Vector2) -> Variant:
	if cam == null:
		return null
	return Plane(Vector3.UP, place_y).intersects_ray(
		cam.project_ray_origin(mouse), cam.project_ray_normal(mouse))


func _on_motion(ev: InputEventMouseMotion) -> void:
	if nav != 0:
		match nav:
			1:
				orbit_yaw -= ev.relative.x * 0.006
				orbit_pitch = clampf(orbit_pitch - ev.relative.y * 0.006, -1.45, 1.45)
			2:
				var b := Basis(Vector3.UP, orbit_yaw) * Basis(Vector3.RIGHT, orbit_pitch)
				pivot += b * Vector3(-ev.relative.x, ev.relative.y, 0.0) * orbit_dist * 0.0016
			3:
				orbit_dist = clampf(orbit_dist * (1.0 + ev.relative.y * 0.006), 2.0, 600.0)
		_drive_camera()
		return
	if drag_axis < 0 or sel.is_empty() or drag_start_state.is_empty():
		return
	var d0 := _axis_point(drag_start_mouse, drag_axis, drag_origin)
	var d1 := _axis_point(ev.position, drag_axis, drag_origin)
	var delta := d1 - d0
	var axis: Vector3 = AXIS_VECTORS[drag_axis]
	var uniform: bool = Input.is_key_pressed(KEY_SHIFT)
	for i in sel:
		if i >= drag_start_state.size():
			continue
		var src: Dictionary = drag_start_state[i]
		var o: Dictionary = objects[i]
		match mode:
			Mode.MOVE:
				o.pos = src.pos + axis * delta
			Mode.SCALE:
				var f: float = clampf(1.0 + delta * 0.06, 0.05, 40.0)
				var s: Vector3 = src.scale
				if uniform:
					o.scale = s * f
				else:
					o.scale = Vector3(
						s.x * (f if drag_axis == 0 else 1.0),
						s.y * (f if drag_axis == 1 else 1.0),
						s.z * (f if drag_axis == 2 else 1.0))
			Mode.ROTATE:
				var r: Vector3 = src.rot
				o.rot = Vector3(
					r.x + (delta * 2.0 if drag_axis == 0 else 0.0),
					r.y + (delta * 2.0 if drag_axis == 1 else 0.0),
					r.z + (delta * 2.0 if drag_axis == 2 else 0.0))
		_apply(o)
	_sync_fields()
	_update_gizmo()
	_sync_list()


# =============================================================== 相机

func _drive_camera() -> void:
	if cam == null:
		return
	hero_mode = false
	var b := Basis(Vector3.UP, orbit_yaw) * Basis(Vector3.RIGHT, orbit_pitch)
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 36.0
	cam.transform = Transform3D(b, pivot + b * Vector3(0.0, 0.0, orbit_dist))
	_refresh()


func _snap_hero() -> void:
	if viewer.has_method("set_view"):
		viewer.set_view(HERO_VIEW)
	if viewer.has_method("update_camera"):
		viewer.update_camera()
	if cam != null:
		orbit_yaw = cam.global_rotation.y
		orbit_pitch = cam.global_rotation.x
		orbit_dist = 11.0
		pivot = cam.global_position - cam.global_transform.basis * Vector3(0.0, 0.0, orbit_dist)
	hero_mode = true
	_note("已回到冻结机位（构图以此为准；Tab 可隐藏面板）")
	_refresh()


func _frame_selection() -> void:
	if sel.is_empty() or cam == null:
		_note("先选一个物件（左侧列表点一下）")
		return
	pivot = _sel_center()
	var span := 2.0
	for i in sel:
		span = maxf(span, objects[i].scale.x * 14.0)
	orbit_dist = span * 2.4
	_drive_camera()
	_note("视角已对准选中物（C 回冻结机位）")


func _toggle_dof() -> void:
	if cam == null or cam.attributes == null:
		_note("这个机位没有景深属性")
		return
	var a := cam.attributes as CameraAttributesPractical
	if a == null:
		_note("相机属性不是 Practical")
		return
	dof_on = not dof_on
	a.dof_blur_far_enabled = dof_on
	a.dof_blur_near_enabled = dof_on
	_note("景深 " + ("开" if dof_on else "关（只影响本次编辑，不动预设）"))


# =============================================================== 存 / 导出

func _doc(for_export: bool) -> Dictionary:
	var items: Array = []
	for o in objects:
		var e := {
			"id": o.id,
			"name": o.name,
			"position": [snappedf(o.pos.x, 0.001), snappedf(o.pos.y, 0.001), snappedf(o.pos.z, 0.001)],
			"scale": [snappedf(o.scale.x, 0.001), snappedf(o.scale.y, 0.001), snappedf(o.scale.z, 0.001)],
			"rotation_deg": [snappedf(o.rot.x, 0.01), snappedf(o.rot.y, 0.01), snappedf(o.rot.z, 0.01)],
			"visible": bool(o.get("visible", true)),
		}
		if for_export:
			e["source"] = String(_palette_of(String(o.id)).get("path", ""))
		items.append(e)
	var doc := {
		"schema": "silkroad.traveler-placement.v2",
		"units": "world units; 1 unit = 20 m (data/traveler/world-scale.json)",
		"axis": "Godot Y-up; rotation_deg 是欧拉 XYZ，单位度",
		"hero_view": HERO_VIEW,
		"count": items.size(),
		"items": items,
	}
	if for_export:
		doc["note"] = "由 scripts/traveler/traveler_placer.gd 手工摆放导出。场景侧按 items 逐个 load(source) 并实例化即可。"
	return doc


func _write(path: String, doc: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_note("写入失败：" + path)
		return false
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	return true


func _save_project() -> void:
	if _write(PROJECT_PATH, _doc(false)):
		project_dirty = false
		_note("已保存 %d 个物件 → %s" % [objects.size(), PROJECT_PATH])


func _export_json() -> void:
	if _write(EXPORT_PATH, _doc(true)):
		_note("已导出 %d 个物件 → %s（每项带资产路径）" % [objects.size(), EXPORT_PATH])


func _load_project() -> void:
	if not FileAccess.file_exists(PROJECT_PATH):
		_note("没有现成工程，从空白开始（Ctrl+S 保存工程，Ctrl+E 导出 JSON）")
		return
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROJECT_PATH))
	if typeof(doc) != TYPE_DICTIONARY or not doc.has("items"):
		_note("工程读不动，从空白开始")
		return
	for s in doc.items:
		var pkey: String = "position" if s.has("position") else "pos"
		var rot := Vector3.ZERO
		if s.has("rotation_deg"):
			rot = Vector3(s.rotation_deg[0], s.rotation_deg[1], s.rotation_deg[2])
		elif s.has("yaw"):
			rot = Vector3(0.0, rad_to_deg(float(s.yaw)), 0.0)
		var obj := {
			"id": String(s.id),
			"name": String(s.get("name", s.id)),
			"pos": Vector3(s[pkey][0], s[pkey][1], s[pkey][2]),
			"scale": Vector3(s.scale[0], s.scale[1], s.scale[2]),
			"rot": rot,
			"visible": bool(s.get("visible", true)),
		}
		_spawn(obj)
		objects.append(obj)
	_rebuild_list()
	_note("已读入 %d 个物件" % objects.size())


# =============================================================== UI

func _panel_style(a: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.13, a)
	sb.border_color = Color(0.34, 0.40, 0.52, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 100
	add_child(ui_layer)

	ui_top = PanelContainer.new()
	ui_top.position = Vector2(312, 12)
	ui_top.add_theme_stylebox_override("panel", _panel_style(0.90))
	ui_layer.add_child(ui_top)
	var tb := VBoxContainer.new()
	ui_top.add_child(tb)
	mode_label = Label.new()
	mode_label.add_theme_font_size_override("font_size", 14)
	tb.add_child(mode_label)
	hud = Label.new()
	hud.add_theme_font_size_override("font_size", 12)
	tb.add_child(hud)
	status = Label.new()
	status.add_theme_font_size_override("font_size", 12)
	status.modulate = Color(1, 0.86, 0.5)
	tb.add_child(status)

	ui_side = PanelContainer.new()
	ui_side.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	ui_side.offset_left = 10.0
	ui_side.offset_top = 10.0
	ui_side.offset_right = 300.0
	ui_side.offset_bottom = -10.0
	ui_side.add_theme_stylebox_override("panel", _panel_style(0.98))
	ui_layer.add_child(ui_side)
	var side := VBoxContainer.new()
	ui_side.add_child(side)

	var om := Label.new()
	om.add_theme_font_size_override("font_size", 14)
	om.text = "对象管理器"
	om.modulate = Color(0.72, 0.84, 1.0)
	side.add_child(om)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 260)
	side.add_child(scroll)
	list_box = VBoxContainer.new()
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_box)

	side.add_child(HSeparator.new())
	var cl := Label.new()
	cl.add_theme_font_size_override("font_size", 14)
	cl.text = "坐标"
	cl.modulate = Color(0.72, 0.84, 1.0)
	side.add_child(cl)

	var nb := HBoxContainer.new()
	side.add_child(nb)
	var nl := Label.new()
	nl.text = "名称"
	nl.custom_minimum_size = Vector2(36, 0)
	nl.add_theme_font_size_override("font_size", 12)
	nb.add_child(nl)
	name_field = LineEdit.new()
	name_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_field.add_theme_font_size_override("font_size", 12)
	name_field.text_submitted.connect(_rename_selected)
	nb.add_child(name_field)

	_coord_row(side, "P", ["px", "py", "pz"], ["X", "Y", "Z"], 0.01)
	_coord_row(side, "S", ["sx", "sy", "sz"], ["X", "Y", "Z"], 0.01)
	_coord_row(side, "R", ["rh", "rp", "rb"], ["H", "P", "B"], 0.1)

	_rebuild_list()
	_refresh()


func _rename_selected(t: String) -> void:
	if sel.size() == 1:
		objects[sel[0]].name = t
		project_dirty = true
		_sync_list()


func _coord_row(parent: Node, tag: String, keys: Array, labels: Array, step: float) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var t := Label.new()
	t.text = tag
	t.custom_minimum_size = Vector2(14, 0)
	t.add_theme_font_size_override("font_size", 12)
	row.add_child(t)
	for i in 3:
		var l := Label.new()
		l.text = String(labels[i])
		l.add_theme_font_size_override("font_size", 11)
		l.modulate = AXIS_COLORS[i]
		row.add_child(l)
		var sb := SpinBox.new()
		sb.min_value = -100000.0
		sb.max_value = 100000.0
		sb.step = step
		sb.allow_greater = true
		sb.allow_lesser = true
		sb.custom_minimum_size = Vector2(62, 0)
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.get_line_edit().add_theme_font_size_override("font_size", 11)
		var key := String(keys[i])
		sb.value_changed.connect(func(v: float): _field_edited(key, v))
		row.add_child(sb)
		coord_fields[key] = sb


func _field_edited(key: String, v: float) -> void:
	if suppress_field_sync or sel.is_empty():
		return
	for i in sel:
		var o: Dictionary = objects[i]
		match key:
			"px": o.pos.x = v
			"py": o.pos.y = v
			"pz": o.pos.z = v
			"sx": o.scale.x = v
			"sy": o.scale.y = v
			"sz": o.scale.z = v
			"rh": o.rot.y = v
			"rp": o.rot.x = v
			"rb": o.rot.z = v
		_apply(o)
	project_dirty = true
	_update_gizmo()
	_sync_list()


func _sync_fields() -> void:
	if coord_fields.is_empty():
		return
	suppress_field_sync = true
	var enable: bool = sel.size() > 0
	for k in coord_fields:
		coord_fields[k].editable = enable
	if enable:
		var o: Dictionary = objects[sel[0]]
		coord_fields["px"].value = o.pos.x
		coord_fields["py"].value = o.pos.y
		coord_fields["pz"].value = o.pos.z
		coord_fields["sx"].value = o.scale.x
		coord_fields["sy"].value = o.scale.y
		coord_fields["sz"].value = o.scale.z
		coord_fields["rh"].value = o.rot.y
		coord_fields["rp"].value = o.rot.x
		coord_fields["rb"].value = o.rot.z
		if name_field != null:
			name_field.text = String(o.name) if sel.size() == 1 else "（%d 个选中）" % sel.size()
	elif name_field != null:
		name_field.text = ""
	suppress_field_sync = false


func _rebuild_list() -> void:
	if list_box == null:
		return
	for c in list_box.get_children():
		c.queue_free()
	row_nodes.clear()
	var last := ""
	for i in objects.size():
		var o: Dictionary = objects[i]
		var id := String(o.id)
		if id != last:
			last = id
			var n := 0
			for x in objects:
				if String(x.id) == id:
					n += 1
			var g := Label.new()
			g.add_theme_font_size_override("font_size", 11)
			g.text = "%s ×%d" % [String(_palette_of(id).get("label", id)), n]
			g.modulate = Color(0.6, 0.66, 0.76)
			list_box.add_child(g)
		var row := HBoxContainer.new()
		list_box.add_child(row)
		var captured := i
		var pick := Button.new()
		pick.add_theme_font_size_override("font_size", 12)
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pick.alignment = HORIZONTAL_ALIGNMENT_LEFT
		pick.tooltip_text = "点选；Shift 点击加选；选中后 F 对准"
		pick.pressed.connect(func(): _select(captured, Input.is_key_pressed(KEY_SHIFT)))
		row.add_child(pick)
		var eye := Button.new()
		eye.add_theme_font_size_override("font_size", 11)
		eye.custom_minimum_size = Vector2(26, 0)
		eye.tooltip_text = "单独显示/隐藏"
		eye.pressed.connect(func(): _toggle_visible(captured))
		row.add_child(eye)
		var kill := Button.new()
		kill.text = "✕"
		kill.add_theme_font_size_override("font_size", 11)
		kill.custom_minimum_size = Vector2(24, 0)
		kill.tooltip_text = "删除"
		kill.pressed.connect(func(): _kill_one(captured))
		row.add_child(kill)
		row_nodes.append({"index": i, "pick": pick, "eye": eye})
	_sync_list()


func _toggle_visible(i: int) -> void:
	if i < 0 or i >= objects.size():
		return
	var o: Dictionary = objects[i]
	o["visible"] = not bool(o.get("visible", true))
	_apply(o)
	project_dirty = true
	_sync_list()


func _kill_one(i: int) -> void:
	if i < 0 or i >= objects.size():
		return
	sel = [i]
	_delete_selection()


func _sync_list() -> void:
	for r in row_nodes:
		var i: int = int(r.index)
		if i >= objects.size():
			continue
		var o: Dictionary = objects[i]
		var vis: bool = bool(o.get("visible", true))
		r.pick.text = String(o.name)
		if sel.has(i):
			r.pick.modulate = Color(1.0, 0.86, 0.38)
		else:
			r.pick.modulate = Color(1, 1, 1, 1.0 if vis else 0.42)
		r.eye.text = "●" if vis else "○"


func _refresh() -> void:
	_update_gizmo()
	_sync_fields()
	_sync_list()
	if mode_label == null:
		return
	var mname: String = ["移动 E", "缩放 R", "旋转 T"][mode]
	var names: Array = []
	for i in PALETTE.size():
		names.append("%s%d %s" % ["▸" if i == brush else "", (i + 1) % 10, PALETTE[i].label])
	mode_label.text = "旅人摆放编辑器　模式：%s　物件 %d　选中 %d　机位 %s%s" % [
		mname, objects.size(), sel.size(), ("冻结" if hero_mode else "自由"),
		"　*未保存" if project_dirty else ""]
	hud.text = "%s\nE 移动 · R 缩放 · T 旋转（拖轴向手柄；缩放时按 Shift 等比）　｜　Alt+左 环绕 · Alt+中 平移 · Alt+右/滚轮 推拉\nC 回冻结机位 · Tab 隐藏面板 · U 场景界面 · B 景深 · G 程序化远景 · F 对准 · Ctrl+D 复制 · Ctrl+A 全选 · X 删除 · Ctrl+Z 撤销\nCtrl+S 保存工程 · Ctrl+E 导出 JSON · Esc 取消选择 · PgUp/PgDn 改放置平面（当前 y=%.1f）" % [
		" | ".join(names), place_y]


func _note(msg: String) -> void:
	if status != null:
		status.text = msg
	print("[PLACER] ", msg)


# =============================================================== 无人值守验证

func _selftest() -> void:
	var probe := "res://data/traveler/placement-selftest.json"
	var before := objects.size()
	for i in 3:
		brush = i % PALETTE.size()
		_add(String(PALETTE[brush].id), Vector3(float(i) * 7.0, place_y, -60.0 - float(i) * 9.0))
	objects[1].scale = Vector3(3.25, 2.5, 3.25)
	objects[1].rot = Vector3(0.0, 41.5, 0.0)
	objects[1].name = "改过名字的"
	_apply(objects[1])
	sel = [1]
	_rebuild_list()
	_refresh()

	var gizmo_ok: bool = gizmo_root.visible and gizmo_arms.size() == 3
	var axis_ok: bool = _pick_axis(cam.unproject_position(_sel_center() + AXIS_VECTORS[1] * _gizmo_scale())) == 1
	_field_edited("px", -123.5)
	_field_edited("sy", 4.75)
	_field_edited("rh", 88.25)
	var field_ok: bool = absf(objects[1].pos.x + 123.5) < 1e-4 \
		and absf(objects[1].scale.y - 4.75) < 1e-4 and absf(objects[1].rot.y - 88.25) < 1e-4

	# 模拟一次沿 Y 轴的拖动，验证轴向约束确实只改一个轴
	var p0: Vector3 = objects[1].pos
	drag_axis = 1
	drag_origin = _sel_center()
	drag_start_state = _state()
	drag_start_mouse = cam.unproject_position(drag_origin)
	var ev := InputEventMouseMotion.new()
	ev.position = drag_start_mouse + Vector2(0.0, -40.0)
	_on_motion(ev)
	var p1: Vector3 = objects[1].pos
	var constrained: bool = absf(p1.x - p0.x) < 1e-4 and absf(p1.z - p0.z) < 1e-4 and absf(p1.y - p0.y) > 1e-3
	drag_axis = -1

	var expect := _state()
	var wrote: bool = _write(probe, _doc(true))
	_restore([])
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(probe))
	var parsed: bool = typeof(doc) == TYPE_DICTIONARY and doc.has("items") and doc.items.size() == 3
	var has_source: bool = parsed and doc.items[0].has("source") and not String(doc.items[0].source).is_empty()
	if parsed:
		for s in doc.items:
			var obj := {"id": String(s.id), "name": String(s.name),
				"pos": Vector3(s.position[0], s.position[1], s.position[2]),
				"scale": Vector3(s.scale[0], s.scale[1], s.scale[2]),
				"rot": Vector3(s.rotation_deg[0], s.rotation_deg[1], s.rotation_deg[2]),
				"visible": bool(s.visible)}
			_spawn(obj)
			objects.append(obj)
	var got := _state()
	var same: bool = got.size() == expect.size()
	if same:
		for i in got.size():
			if String(got[i].id) != String(expect[i].id) or String(got[i].name) != String(expect[i].name) \
				or got[i].pos.distance_to(expect[i].pos) > 1e-3 \
				or got[i].scale.distance_to(expect[i].scale) > 1e-3 \
				or got[i].rot.distance_to(expect[i].rot) > 1e-2:
				same = false
				break
	var spawned := 0
	for o in objects:
		if o.get("node") != null and is_instance_valid(o.get("node")):
			spawned += 1
	print("[SELFTEST] 手柄=%s 轴拾取=%s 数值框=%s 轴向约束=%s 导出项=%d 带资产路径=%s 读回=%d 实例化=%d 往返一致=%s" % [
		str(gizmo_ok), str(axis_ok), str(field_ok), str(constrained),
		(doc.items.size() if parsed else -1), str(has_source), got.size(), spawned, str(same)])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(probe))
	var verdict: bool = gizmo_ok and axis_ok and field_ok and constrained and wrote \
		and parsed and has_source and same and spawned == 3 and before == 0
	print("[SELFTEST] ", "PASS" if verdict else "FAIL", "  （工程 ", PROJECT_PATH, " 未被触碰）")
	get_tree().quit(0 if verdict else 1)


func _shot(path: String) -> void:
	for i in 4:
		brush = i % PALETTE.size()
		_add(String(PALETTE[brush].id), Vector3(-30.0 + float(i) * 20.0, place_y, -70.0 - float(i) * 6.0))
	sel = [1]
	_rebuild_list()
	_refresh()
	for i in 8:
		await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var err: int = img.save_png(path)
	print("[SHOT] %s  %dx%d  err=%d" % [path, img.get_width(), img.get_height(), err])
	_restore([])
	get_tree().quit(0 if err == OK else 1)
