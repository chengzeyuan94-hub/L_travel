extends "res://tools/merchant_board_claude_play_board.gd"
## 地图工坊的视口（DESIGN 3.12.3、3.12.4、3.12.7）：就是发布版那块 3D 棋盘。
## 平移（拖空白处、右键 / 中键拖、双指滑、贴边滚）、缩放（滚轮在光标处 ×1.1、捏合、+ / −）、方向键 / WASD、R / Home、
## 双击地面滑镜头，都直接继承游戏棋盘的代码，一行不改；工坊只改「点到什么」：
##   - 左键按下先 gui_release_focus()（输入框离开即生效），再当场做射线拾取（workshop_picking.gd，悬停和点击同一套）；
##   - 打中城（或转向圆钮）：记下候选、吃掉这次按下；挪过 6 像素（游戏拖地图同一个阈值）才开始拖，没挪过就松手 = 选中；
##     单击选中不改文档、不进撤销栈；
##   - 双击城 = 选中并让镜头滑过去，不进入拖动；
##   - 没打中：交给游戏棋盘（平移），松手时没挪过 = 单击：选中路线 / 停靠点，或者点空白处取消选择（绝不生成任何东西）。
## 悬停：复用游戏的城市发光，但不放大（一拖模型就跳）、不弹市集小卡；悬停对象就是此刻按下会点中的对象，鼠标变小手。
## 选中城：发光常亮、城脚奶油色描驼色边的椭圆环、名牌变金色；拖动中圆环绿 = 能放、红 = 不行，光标旁写孩子话；
## 在红色处松手，0.25 秒弹回上一个合格的位置，原因留 2 秒。原版城拖动时地上有虚线圆（离老家 R_move），到圆边就停住。
##
## 原版与新城都可拖动和转向；新城放置使用真实可达区域、配对规则与全量校验。
## 拖动预览、松手检查、提交刷新共用 Backend.derive。尺寸/模型变化同步重建真实网格拾取体。
## 打开另一张图会重建世界，_build_city_hover() 在世界就绪后重建工坊节点；改路和停靠点当前只读。

signal badge_move_committed(cid: String, offset: Vector2)
var _badge_drag: Dictionary = {}

signal selection_changed(kind: String, id: String)
signal hover_changed(kind: String, id: String)
## 一次真正挪动了的拖动（松手时位置有变化）；单击、位移为 0 的拖动不发
signal city_move_committed(cid: String, x: float, z: float, rotation: float)
## 拖动中每一帧：{cid, x, z, rotation, ok, reason}；结束时 {cid: ""}
signal drag_changed(state: Dictionary)
## L叔 提示条要说的一句话
signal say(text: String)
signal place_requested(world_position: Vector2)
signal landscape_stroke_committed(points: Array, radius: float)
signal suggestion_selected(index: int)

const Guides := preload("res://scripts/map_workshop/workshop_guides.gd")
const Picking := preload("res://scripts/map_workshop/workshop_picking.gd")
const Backend := preload("res://scripts/map_workshop/workshop_backend.gd")
const Doc := preload("res://scripts/map_workshop/workshop_doc.gd")
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const DRAG_PX := 6.0                     # 与游戏拖地图同一个常数（play_board.gd:1006）
const SNAP_BACK_SEC := 0.25
const REASON_HOLD_MS := 2000
const EDGE_PAN_PX := 24.0                # 拖城到视口边：地图朝那边走
const KNOB_MIN_ZOOM := 0.7               # 缩得比这还小时城只有二三十像素宽，转向圆钮太小、会挡住城本身：不出
const KNOB_VIS_R := 0.44                 # 圆钮外圈（描边球）的半径；按可点半径整体缩放，看见多大就能点多大
const RED := Color("#CD483A")            # 棋子红（play_board.gd:28 的 TEAM.red）
const GREEN := Color("#7DBF6A")          # SPROUT
const RING_FILL := Color("#FBF3E4")      # 奶油
const RING_EDGE := Color("#C98E4E")      # 驼色
const PLAQUE_GOLD := Color(1.0, 0.8, 0.32)
## 城脚的圆环、离老家的虚线圆、硬币外圈都是贴在地面上的 Decal（cull_mask = 1：只印在地面、树、山上，不印在城的模型上），
## 地面高低起伏也贴得住；颜色换贴图（奶油描驼色 = 选中，绿 = 能放，红 = 不行）
const DECAL_TEX := 256

## T-R3：本文件的顶层 var 分两类。rebuild_world_with_layout（WP3）换世界时，WORLD_STATE_VARS_EXTRA 要复位（初值见
## _world_state_defaults()，两边必须一一对应，冒烟测试会查）、挂在旧世界里的节点要重建；KEEP_VARS_EXTRA 跨世界保留
const WORLD_STATE_VARS_EXTRA := ["_badge_drag", "picking", "geo", "cur_layout", "_ring", "_home_circle", "_knob", "_stop_ring", "_route_hl",
	"_band", "_attach", "_glowing", "_hover_city", "sel", "hover", "_press", "_obj_drag", "_drag", "_start", "_last_ok",
	"_snap_tween", "_snap_cid", "_reason_until", "_reason_text", "_at_edge", "_label", "_label_box", "placement_mode", "_placement_zone", "_placement_decal", "_placement_pin"]
const KEEP_VARS_EXTRA := ["base_layout", "cur_doc", "_gold_plaque", "_tex", "_world_hooked", "_guides", "route_pick_preferred"]

var picking                                  # workshop_picking.gd
var geo                                      # 基础宿主/端点索引及共享 CustomMapGeo，见 Backend.geo_for
var base_layout: Dictionary = {}             # 原布局（不改）
var cur_layout: Dictionary = {}              # 现在画着的推导布局
var cur_doc: Dictionary = {}                 # 当前文档（根节点每次改文档后同步过来；拖动时拿它去推导）
var sel := {"kind": "", "id": ""}
var route_pick_preferred := false # 路线工具优先拾取线，防止城市名牌挡住连线。
var hover := {"kind": "", "id": ""}
var _press := {}                             # 按在城 / 圆钮上还没松手：{kind, id, pos, moved, off}
var _obj_drag := false
var _drag := {}                              # 拖动中现在的位置 {x, z, rotation}
var _start := {}                             # 按下之前的位置
var _last_ok := {}                           # 这次拖动里最后一个合格的位置
var _at_edge := false
var _snap_tween: Tween
var _snap_cid := ""
var _reason_until := 0
var _reason_text := ""
var _ring: Decal
var _tex := {}                               # 贴花贴图（不是节点，跨世界留着）：0 / 1 / -1 圆环，"home" 虚线圆，"stop" 硬币环
var _home_circle: Decal
var _knob: MeshInstance3D
var _stop_ring: Decal
var _route_hl: MeshInstance3D
var _band: MeshInstance3D
var _attach := {}                            # city id -> {decal, decal_local, lights: [[node, local]], plaque_local}
var _glowing := {}                           # 发着光的城（悬停的 + 选中的）
var _hover_city := ""
var _label: Label
var _label_box: PanelContainer
var _gold_plaque: Texture2D
var _world_hooked := false                   # _ready 走完之后再建世界 = 换世界（rebuild_world_with_layout）
var placement_mode := false
var _placement_zone: Image
var _placement_decal: Decal
var _placement_pin: MeshInstance3D
var _guides: Control


func _ready() -> void:
	super()
	# 工坊里没有对局：固定正午的光（和 P-0c 截图一样），不走日循环
	# 启动时根节点可能已经把要打开的那张图的推导布局设进 initial_layout_override（WP3 的成员，3.12.1 启动顺序），
	# 这时世界是按推导布局建的，原布局要另读文件
	var ov: Variant = get("initial_layout_override")
	base_layout = Backend.load_base_layout() if ov is Dictionary and not (ov as Dictionary).is_empty() else world.layout
	cur_layout = world.layout
	geo = Backend.geo_for(self)
	_build_overlays()
	_record_attachments()
	_guides = Guides.new()
	_guides.name = "WorkshopGuides"
	_guides.board = self
	add_child(_guides)
	_guides.stroke_finished.connect(func(points: Array, radius: float) -> void: landscape_stroke_committed.emit(points, radius))
	_guides.stroke_rejected.connect(func(message: String) -> void: say.emit(message))
	_guides.suggestion_selected.connect(func(index: int) -> void: suggestion_selected.emit(index))
	_world_hooked = true


## 建世界的最后一步（_ready 里、以及 WP3 的 rebuild_world_with_layout 第 5 步，3.10.2）。
## 不直接覆盖 rebuild_world_with_layout：WP3 合入前基类没有这个函数，GDScript 不许 super 一个不存在的函数
func _build_city_hover() -> void:
	super()
	if _world_hooked:
		_on_world_rebuilt()


## WORLD_STATE_VARS_EXTRA 每一个的初值（和声明时一样；换世界时照这张表复位）
func _world_state_vars() -> Array[String]:
	var vars: Array[String] = super().duplicate()
	vars.append_array(WORLD_STATE_VARS_EXTRA)
	return vars


func _world_state_defaults() -> Dictionary:
	return {"_badge_drag": {}, "picking": null, "geo": null, "cur_layout": {}, "_ring": null, "_home_circle": null, "_knob": null,
		"_stop_ring": null, "_route_hl": null, "_band": null, "_attach": {}, "_glowing": {}, "_hover_city": "",
		"sel": {"kind": "", "id": ""}, "hover": {"kind": "", "id": ""}, "_press": {}, "_obj_drag": false, "_drag": {}, "_start": {},
		"_last_ok": {}, "_snap_tween": null, "_snap_cid": "", "_reason_until": 0, "_reason_text": "", "_at_edge": false,
		"_label": null, "_label_box": null, "placement_mode": false, "_placement_zone": null, "_placement_decal": null, "_placement_pin": null}


## 世界换过了：旧世界里的拾取体、圆环、圆钮、预览带、光标旁的字都已随旧 SubViewport 删掉，只剩引用。
## 照 WORLD_STATE_VARS_EXTRA 复位，再按新世界重建（拾取体同步建完，3.12.4）；选中清空（打开的是另一张图）
func _on_world_rebuilt() -> void:
	if _snap_tween != null and _snap_tween.is_valid():
		_snap_tween.kill()
	var had_sel := String(sel.kind) != ""
	var d := _world_state_defaults()
	for k in d:
		set(k, d[k])
	cur_layout = world.layout
	geo = Backend.geo_for(self)
	_build_overlays()
	_record_attachments()
	build_picking()
	if had_sel:
		selection_changed.emit("", "")


## 等待卡期间同步建完全部拾取碰撞体（3.12.4）；返回用了多少毫秒
func build_picking() -> float:
	var t0 := Time.get_ticks_usec()
	picking = Picking.new(self)
	picking.build_all()
	return (Time.get_ticks_usec() - t0) / 1000.0


func pick_at(pos: Vector2) -> Dictionary:
	if picking == null:
		return {"kind": "", "id": ""}
	return picking.pick(pos)


## 工坊可改变地面高度，不能沿用正式固定棋盘的 0.95 平面反投影。
## 从上向下寻找第一个地表交点，二分细化，画笔与可见落点保持一致。
func _ground_at(pos: Vector2) -> Vector3:
	if geo == null or geo.real_geo == null or world == null:
		return super(pos)
	var cam: Camera3D = world.camera
	var origin := cam.project_ray_origin(pos * _render_scale)
	var direction := cam.project_ray_normal(pos * _render_scale)
	if direction.y >= -0.0001:
		return Vector3.INF
	var near_t := maxf(0.0, (12.0 - origin.y) / direction.y)
	var far_t := maxf(near_t, (0.04 - origin.y) / direction.y)
	var previous := near_t
	for i in range(1, 49):
		var t := lerpf(near_t, far_t, i / 48.0)
		var p := origin + direction * t
		var h := maxf(0.04, geo.real_geo.height(p.x, p.z)) if geo.real_geo.is_land(p.x, p.z) else 0.04
		if p.y <= h:
			var lo := previous
			var hi := t
			for _j in 12:
				var mid := (lo + hi) * 0.5
				var q := origin + direction * mid
				var qh := maxf(0.04, geo.real_geo.height(q.x, q.z)) if geo.real_geo.is_land(q.x, q.z) else 0.04
				if q.y > qh:
					lo = mid
				else:
					hi = mid
			return origin + direction * ((lo + hi) * 0.5)
		previous = t
	return origin + direction * far_t


## 画布上一个世界单位有多少像素（缩放 0.42 时约 10）
func px_per_unit() -> float:
	return _to_view(Vector3(60, 0, 30)).distance_to(_to_view(Vector3(61, 0, 30)))


## 指针在哪座城的名牌上（名牌也算点城）
func plaque_city_at(pos: Vector2) -> String:
	var ids: Array = _plaques.keys()
	if city_plaque_candidate: ids.reverse()
	for cid in ids:
		if _plaque_screen_rect(String(cid)).has_point(pos):
			return String(cid)
	return ""


# ------------------------------------------------------------------ 输入：只改「点到什么」
func _gui_input(event: InputEvent) -> void:
	if OS.get_environment("SILKROAD_INPUT_TRACE") == "1" and event is InputEventMouseButton:
		print("WORKSHOP_OS_INPUT ", event, " pick=", pick_at(event.position))
	# A panel edit can change the document and rebuild picking synchronously.
	# Commit it before the route editor captures a drag transaction.
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed:
		get_viewport().gui_release_focus()
	var route_editor: Variant = get_meta("route_editor", null)
	if route_editor != null and route_editor.consume_event(event):
		accept_event()
		return
	var plants: Variant = get_meta("plant_editor", null)
	if plants != null and plants.active and plants.consume_event(event):
		accept_event()
		return
	if _guides != null and _guides.consume_event(event):
		accept_event()
		return
	if placement_mode:
		if event is InputEventMouseMotion:
			_update_placement_pin((event as InputEventMouseMotion).position)
		super(event)
		return
	if _badge_input(event):
		accept_event(); return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			# 输入框离开即生效：先让它提交，再拾取（点视口这种 focus_mode = NONE 的地方它自己不会失焦）
			get_viewport().gui_release_focus()
			if _snap_tween != null and _snap_tween.is_valid():
				_snap_tween.custom_step(SNAP_BACK_SEC)        # 上一下的弹回还没走完：直接走完
			var hit := pick_at(mb.position)
			if mb.double_click:
				# 双击城（双击它的转向圆钮也算这座城）：选中并让镜头滑过去，不进入拖动（它的松开也吃掉）
				var dcid := String(hit.id) if String(hit.kind) == "city" else (String(sel.id) if String(hit.kind) == "handle" else "")
				if dcid != "":
					select("city", dcid)
					fly_to_city(dcid)
					_press = {"kind": "swallow"}
					accept_event()
					return
			elif String(hit.kind) == "city" or String(hit.kind) == "handle":
				_begin_press(hit, mb.position)
				accept_event()
				return
		elif not _press.is_empty():
			_release(mb.position)
			accept_event()
			return
	elif event is InputEventMouseMotion and not _press.is_empty():
		var mm := event as InputEventMouseMotion
		_last_pointer = mm.position
		_pointer_in = true
		if String(_press.kind) != "swallow":
			_press_motion(mm.position)
		accept_event()
		return
	super(event)


## 单击（按下后没挪过 6 像素就松手，且没打中城）：选中路线 / 停靠点，或者取消选择
func _click(pos: Vector2) -> void:
	if OS.get_environment("SILKROAD_INPUT_TRACE") == "1": print("WORKSHOP_CLICK ", pos)
	_last_pointer = pos
	if placement_mode:
		var p := _ground_at(pos)
		if p != Vector3.INF:
			place_requested.emit(Vector2(p.x, p.z))
		return
	var hit := pick_at(pos)
	select(String(hit.kind), String(hit.id))
	_update_pointer()


func _begin_press(hit: Dictionary, pos: Vector2) -> void:
	var cid := String(hit.id) if String(hit.kind) == "city" else String(sel.id)
	var st := city_state(cid)
	var g := _ground_at(pos)
	var off := Vector2.ZERO
	if g != Vector3.INF:
		off = Vector2(float(st.x) - g.x, float(st.z) - g.z)
	_press = {"kind": String(hit.kind), "id": cid, "pos": pos, "moved": false, "off": off}
	_start = st
	_last_ok = st
	_drag = st.duplicate()


func _press_motion(pos: Vector2) -> void:
	if not bool(_press.moved):
		if pos.distance_to(_press.pos) <= DRAG_PX:
			return
		_press.moved = true
		_obj_drag = true
		_set_hover({"kind": "", "id": ""})
		select("city", String(_press.id))
		_home_circle.visible = String(_press.kind) == "city" and _is_original(String(_press.id))
		var h: Dictionary = geo.home.get(String(_press.id), {})
		if not h.is_empty():
			_home_circle.global_position = Vector3(float(h.x), float(h.y), float(h.z))
	_drag_to(pos)


## 拖到 pos：原版城到 R_move 的圆边就停住；圆钮转向夹在 ±45°。每一帧只查这座城（3.11「性能」）
func _drag_to(pos: Vector2) -> void:
	var cid := String(_press.id)
	var g := _ground_at(pos)
	if g == Vector3.INF:
		return
	var h: Dictionary = geo.home.get(cid, {})
	_at_edge = false
	if String(_press.kind) == "handle":
		var c := Vector2(float(_drag.x), float(_drag.z))
		var phi := atan2(-(g.z - c.y), g.x - c.x)          # 圆钮在东边：Basis(UP, φ) × (1, 0, 0) = (cos φ, 0, −sin φ)
		var rot0 := float(h.get("rotation", 0.0))
		var clamped := clampf(phi, -Backend.YAW_MAX, Backend.YAW_MAX) if _is_original(cid) else phi
		_at_edge = absf(clamped - phi) > 1e-4
		_drag.rotation = Backend.round3(rot0 + clamped)
	else:
		var want := Vector2(g.x, g.z) + (_press.off as Vector2)
		if not h.is_empty():
			var home := Vector2(float(h.x), float(h.z))
			var d := want - home
			if d.length() > Backend.R_MOVE:
				want = home + d.normalized() * Backend.R_MOVE
				_at_edge = true
		_drag.x = Backend.round3(want.x)
		_drag.z = Backend.round3(want.y)
	_place_city(cid, float(_drag.x), float(_drag.z), float(_drag.rotation))
	var lay := derived_with(cid, _drag)
	var issues: Array[Dictionary] = Backend.check_city(lay, cid, geo, true)
	var ok := issues.is_empty()
	var reason := ""
	if not ok:
		reason = String(issues[0].kid)
	elif _at_edge and _is_original(cid):
		reason = Backend.kid_text("G_MOVE_FAR", _city_name(cid))
	if ok:
		_last_ok = _drag.duplicate()
	_ring_state(1 if ok else -1)
	_draw_band(lay, cid, ok)
	_show_label(reason if reason != "" else "%s · 可以放" % _city_name(cid), pos, not ok or reason != "")
	drag_changed.emit({"cid": cid, "x": float(_drag.x), "z": float(_drag.z), "rotation": float(_drag.rotation), "ok": ok, "reason": reason})


## 松手：没挪过 = 选中；挪过：合格就提交，不合格 0.25 秒弹回上一个合格的位置（原因在光标旁留 2 秒）
func _release(pos: Vector2) -> void:
	var p := _press
	_press = {}
	if String(p.get("kind", "")) == "swallow":
		return
	var cid := String(p.id)
	if not bool(p.moved):
		if String(p.kind) == "city":
			select("city", cid)
		_last_pointer = pos
		_update_pointer()
		return
	_obj_drag = false
	_home_circle.visible = false
	_band.visible = false
	# 松手时按全套（不隔点）再查一遍：拖动中为了帧率路线点隔一个查一个，边界上可能差一点点（R27：地图永远合格）
	var author:=CustomMapFreeAuthor.enabled(cur_doc) and cid.begins_with("x_")
	var ok_now := _author_safe(_drag) if author else (_ring_is_ok() and _full_ok(cid, _drag))
	var final := _drag.duplicate() if ok_now else _last_ok.duplicate()
	if not ok_now and not _full_ok(cid, final):
		final = _start.duplicate()
	if not ok_now:
		if _ring_is_ok():
			_show_label(String(_full_issues(cid, _drag)[0].kid), pos, true)
		_reason_text = _label.text
		_reason_until = Time.get_ticks_msec() + REASON_HOLD_MS
		say.emit(_reason_text)
		var from := _drag.duplicate()
		_snap_cid = cid
		_snap_tween = create_tween()
		_snap_tween.tween_method(func(t: float) -> void:
			_place_city(cid, lerpf(float(from.x), float(final.x), t), lerpf(float(from.z), float(final.z), t),
				lerp_angle(float(from.rotation), float(final.rotation), t)), 0.0, 1.0, SNAP_BACK_SEC)
		_snap_tween.finished.connect(func() -> void: _snap_cid = "")
	else:
		_label_box.visible = false
	_ring_state(0)
	drag_changed.emit({"cid": ""})
	if not _same(final, _start):
		city_move_committed.emit(cid, float(final.x), float(final.z), float(final.rotation))


func _full_issues(cid: String, at: Dictionary) -> Array[Dictionary]:
	return Backend.check_city(derived_with(cid, at), cid, geo, false)


## 当前文档里把这座城换到 at = {x, z, rotation} 之后的推导布局（和提交后走同一个 Backend.derive）
func derived_with(cid: String, at: Dictionary) -> Dictionary:
	var d: Dictionary = Doc.with_city(cur_doc, geo.home, cid, float(at.x), float(at.z), float(at.rotation))
	return Backend.derive(base_layout, d, geo)


func _full_ok(cid: String, at: Dictionary) -> bool:
	return _full_issues(cid, at).is_empty()


## Esc：拖动中 → 回到按下之前（不提交）；返回 true = 吃掉了这下 Esc
func cancel_drag() -> bool:
	if _press.is_empty():
		return false
	var p := _press
	_press = {}
	if bool(p.get("moved", false)):
		_obj_drag = false
		_home_circle.visible = false
		_band.visible = false
		_label_box.visible = false
		_ring_state(0)
		_place_city(String(p.id), float(_start.x), float(_start.z), float(_start.rotation))
		drag_changed.emit({"cid": ""})
	return true


func is_dragging() -> bool:
	return _obj_drag


func _same(a: Dictionary, b: Dictionary) -> bool:
	return absf(float(a.x) - float(b.x)) < 0.0005 and absf(float(a.z) - float(b.z)) < 0.0005 and absf(float(a.rotation) - float(b.rotation)) < 0.0005


# ------------------------------------------------------------------ 选中与悬停
func select(kind: String, id: String) -> void:
	if kind == String(sel.kind) and id == String(sel.id):
		return
	if String(sel.kind) == "city":
		_plaque_gold(String(sel.id), false)
	sel = {"kind": kind, "id": id}
	if kind == "city":
		_plaque_gold(id, true)
	_sync_glow()
	_update_selection_visuals()
	selection_changed.emit(kind, id)


func clear_workshop_selection() -> void:
	select("", "")


func _update_city_hover(pos: Vector2) -> void:
	if placement_mode or (_guides != null and _guides.tool != ""):
		return
	if not _press.is_empty() or _obj_drag:
		return
	if not _in_free_map(pos):
		_set_hover({"kind": "", "id": ""})
		return
	_set_hover(pick_at(pos))


func _clear_city_hover() -> void:
	super()
	if _label_box != null and not _obj_drag and Time.get_ticks_msec() > _reason_until:
		_label_box.visible = false
	hover = {"kind": "", "id": ""}
	for tag in _plaques.values():
		if tag.has_method("configure"): tag.drag_hover = false; tag.queue_redraw()
	mouse_default_cursor_shape = Control.CURSOR_ARROW


func _set_hover(hit: Dictionary) -> void:
	var kind := String(hit.get("kind", ""))
	var id := String(hit.get("id", ""))
	var changed := kind != String(hover.kind) or id != String(hover.id)
	hover = {"kind": kind, "id": id}
	_set_city_glow(id if kind == "city" else "")
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if kind != "" else Control.CURSOR_ARROW
	if Time.get_ticks_msec() > _reason_until:
		if kind == "city":
			var badge_hit := plaque_city_at(_last_pointer) == id and not route_pick_preferred
			for cid in _plaques:
				var tag: Control = _plaques[cid]
				if tag.has_method("configure"): tag.drag_hover = badge_hit and cid == id; tag.queue_redraw()
			_show_label("%s · %s" % [_city_name(id), "挪名牌" if badge_hit else "挪城"], _last_pointer, false)
		elif kind == "handle":
			_show_label("拖这个小圆钮，转一转", _last_pointer, false)
		elif kind == "stop":
			_show_label("停靠点 · 点一下看看", _last_pointer, false)
		elif kind == "route":
			_show_label("路线 · 点击显示控制点", _last_pointer, false)
		else:
			_label_box.visible = false
		if kind != "city":
			for tag in _plaques.values():
				if tag.has_method("configure"): tag.drag_hover = false; tag.queue_redraw()
	if changed:
		hover_changed.emit(kind, id)


## 发光：悬停的城 + 选中的城（都不放大）；地上的光晕和火星跟着悬停的（没有就跟着选中的）
func _set_city_glow(cid: String) -> void:
	_hover_city = cid
	_sync_glow()


func _sync_glow() -> void:
	if not is_inside_tree() or world == null or not is_instance_valid(world.world_root) or not world.world_root.is_inside_tree():
		return
	if _sheen_mat == null:
		return
	var want := {}
	if _hover_city != "":
		want[_hover_city] = true
	if String(sel.kind) == "city" and String(sel.id) != "":
		want[String(sel.id)] = true
	for c in _glowing.keys():
		if not want.has(c):
			_city_glow_on(String(c), false)
			_glowing.erase(c)
	for c in want:
		if not _glowing.has(c):
			_city_glow_on(String(c), true)
			_glowing[c] = true
	_sheen_mat.set_shader_parameter("strength", 1.0)
	_glow_city = _hover_city if _hover_city != "" else (String(sel.id) if String(sel.kind) == "city" else "")
	_place_aura()


## 游戏的发光去掉 1.05 倍放大（HOVER_SCALE）：只留城灯、金色描边；光晕另放
func _city_glow_on(cid: String, on: bool) -> void:
	if not world.city_nodes.has(cid):
		return
	var holder: Node3D = world.city_nodes[cid].node
	_apply_city_lamps(cid, on)
	for mi: MeshInstance3D in world.mesh_instances(holder):
		mi.material_overlay = _sheen_mat if on else null


func _place_aura() -> void:
	if not is_instance_valid(_aura) or not _aura.is_inside_tree():
		return
	var cid := _glow_city
	if cid == "" or not world.city_nodes.has(cid):
		_aura.visible = false
		_sparkles.emitting = false
		return
	var st := city_state(cid)
	var foot := float(st.foot)
	_aura.global_position = Vector3(float(st.x), float(st.y) + 0.04, float(st.z))
	_aura.scale = Vector3.ONE * foot * 1.55
	_aura.visible = true
	_aura_mat.set_shader_parameter("strength", 1.0)
	(_sparkles.process_material as ParticleProcessMaterial).emission_ring_radius = foot * 0.6
	(_sparkles.process_material as ParticleProcessMaterial).emission_ring_inner_radius = foot * 0.35
	_sparkles.global_position = Vector3(float(st.x), float(st.y) + 0.2, float(st.z))
	_sparkles.emitting = true


func _apply_daylight() -> void:
	super()
	for c in _glowing:
		_apply_city_lamps(String(c), true)


func _plaque_gold(cid: String, on: bool) -> void:
	var tag: Control = _plaques.get(cid)
	if tag == null or tag.get_child_count() == 0:
		return
	if tag.has_method("set_highlight"):
		tag.set_highlight(on,on)
		return
	(tag.get_child(0) as NinePatchRect).texture = _gold_plaque if on and _gold_plaque != null else CITY_PLAQUE_TEXTURE
	var label := tag.get_node_or_null("Name") as Label
	if label != null:
		if on:
			label.add_theme_color_override("font_color", Kit.SATCHEL_DEEP)
			label.add_theme_color_override("font_outline_color", Color("#FFF3C8"))
		else:
			label.remove_theme_color_override("font_outline_color")
			HudStyle.apply_heading(label, HudStyle.PARCHMENT_LIGHT, HudStyle.SIZE_CITY_PLAQUE)


# ------------------------------------------------------------------ 城的位置
## 一座城现在画在哪：{x, y, z, rotation, foot, name}
func city_state(cid: String) -> Dictionary:
	for c: Dictionary in cur_layout.get("cities", []):
		if String(c.id) == cid:
			var st := {"x": float(c.x), "y": float(c.y), "z": float(c.z), "rotation": float(c.get("rotation", 0.0)), "foot": float(c.get("foot", 3.5)), "name": String(c.get("name", cid))}
			if (_obj_drag or not _press.is_empty()) and String(_press.get("id", "")) == cid and not _drag.is_empty():
				st.x = float(_drag.x)
				st.z = float(_drag.z)
				st.rotation = float(_drag.rotation)
			return st
	return {"x": 0.0, "y": 0.0, "z": 0.0, "rotation": 0.0, "foot": 3.5, "name": cid}


func _is_original(cid: String) -> bool:
	return geo.home.has(cid)


func _city_name(cid: String) -> String:
	var cities: Dictionary = GameState.content.get("cities", {}) if not GameState.content.is_empty() else {}
	if cities.has(cid):
		return String(cities[cid].get("display_name", cid))
	return String(city_state(cid).name)


## 记下每座城跟着模型走的东西（接触阴影、夜里的灯、名牌挂点），都存成模型坐标系里的点
func _record_attachments() -> void:
	_attach.clear()
	var decals: Array = []
	for ch in world.world_root.get_children():
		if ch is Decal:
			decals.append(ch)
	for c: Dictionary in cur_layout.get("cities", []):          # 世界是按它建的（启动时可能已经是推导布局）
		var cid := String(c.id)
		if not world.city_nodes.has(cid):
			continue
		var holder: Node3D = world.city_nodes[cid].node
		var inv := holder.global_transform.affine_inverse()
		var a := {"decal": null, "decal_local": Vector3.ZERO, "lights": [], "plaque_local": Vector3.INF}
		var best := 1.0
		var hp := holder.global_position
		for d: Decal in decals:
			var dd := Vector2(d.global_position.x - 0.12 - hp.x, d.global_position.z - 0.08 - hp.z).length()
			if dd < best:
				best = dd
				a.decal = d
		if a.decal != null:
			a.decal_local = inv * (a.decal as Decal).global_position
		for l: OmniLight3D in world.city_lights:
			if Vector2(l.global_position.x - float(c.x), l.global_position.z - float(c.z)).length() < float(c.foot) * 1.1:
				(a.lights as Array).append([l, inv * l.global_position])
		if plaque_anchors.has(cid):
			a.plaque_local = inv * (plaque_anchors[cid] as Vector3)
		_attach[cid] = a


## 把一座城摆到 (x, z)、朝向 rotation：模型、接触阴影、城灯、名牌挂点、碰撞体一起走
func _place_city(cid: String, x: float, z: float, rotation: float) -> void:
	if not world.city_nodes.has(cid):
		return
	var holder: Node3D = world.city_nodes[cid].node
	var fit: Array = world.CITY_FIT.get(cid, [world.CITY_YAW, 0.0, 0.0])
	holder.rotation.y = rotation + float(fit[0])
	holder.position = Vector3(x + float(fit[1]), holder.position.y, z + float(fit[2]))
	var xf := holder.global_transform
	var a: Dictionary = _attach.get(cid, {})
	if a.get("decal") != null:
		(a.decal as Decal).global_position = xf * (a.decal_local as Vector3)
	for pair: Array in a.get("lights", []):
		(pair[0] as Node3D).global_position = xf * (pair[1] as Vector3)
	if a.get("plaque_local", Vector3.INF) != Vector3.INF:
		plaque_anchors[cid] = xf * (a.plaque_local as Vector3)
	_city_rects_frame = -1
	if picking != null:
		picking.sync_city(cid)
	_layout_plaques()
	if _glow_city == cid:
		_place_aura()
	_update_selection_visuals()


## 轻量更新（3.12.7 第 1 步）。STUB：WP3 之前本地做——城的位置和朝向、路线虚线和硬币（build_routes 重建）、
## 名牌、碰撞体；不重建 Paths（见文件头）。WP3 合入后：refresh_routes_and_cities(lay) + apply_ground_edits(lay)
func show_layout(lay: Dictionary) -> float:
	var t0 := Time.get_ticks_usec()
	if (lay.has("plants") or cur_layout.has("plants")) and lay.get("landscape", {}) == cur_layout.get("landscape", {}) and lay.get("cities", []) == cur_layout.get("cities", []) and lay.get("routes", []) == cur_layout.get("routes", []) and lay.get("stops", []) == cur_layout.get("stops", []) and lay.get("kit", []) == cur_layout.get("kit", []) and lay.get("props", []) == cur_layout.get("props", []):
		if lay.get("tree_kit", []) != cur_layout.get("tree_kit", []) or lay.get("decor_cleared", {}) != cur_layout.get("decor_cleared", {}):
			world.update_tree_instances(lay)
		cur_layout = lay
		return (Time.get_ticks_usec() - t0) / 1000.0
	if lay.get("landscape", {}) != cur_layout.get("landscape", {}) or (lay.has("landscape") and (lay.get("tree_kit", []) != cur_layout.get("tree_kit", []) or lay.get("kit", []) != cur_layout.get("kit", []) or lay.get("props", []) != cur_layout.get("props", []))):
		var selected: Dictionary = sel.duplicate()
		set_suggestions([], "")
		rebuild_world_with_layout(lay)
		if selected.kind == "city" and world.city_nodes.has(selected.id):
			select(str(selected.kind), str(selected.id))
		elif selected.kind in ["route","stop"]:
			var rows:Array=cur_layout.routes if selected.kind=="route" else cur_layout.stops
			for row:Dictionary in rows:
				if str(row.id)==str(selected.id):
					select(str(selected.kind),str(selected.id))
					break
		return (Time.get_ticks_usec() - t0) / 1000.0
	if Backend.WP3_READY and has_method("refresh_routes_and_cities"):
		if lay == cur_layout:
			return 0.0
		var old_foot := {}
		for c: Dictionary in cur_layout.get("cities", []):
			old_foot[str(c.id)] = float(c.get("foot", 3.5))
		var new_foot := {}
		for c: Dictionary in lay.get("cities", []):
			new_foot[str(c.id)] = float(c.get("foot", 3.5))
		var changed: Dictionary = call("refresh_routes_and_cities", lay)
		call("apply_ground_edits", lay)
		cur_layout = lay
		if picking != null:
			for cid in picking.city_bodies.keys():
				if not world.city_nodes.has(cid):
					(picking.city_bodies[cid] as Node).free()
					picking.city_bodies.erase(cid)
			for cid in world.city_nodes:
				if cid in changed.get("rebuilt_cities", []) or not picking.city_bodies.has(cid) or not is_equal_approx(float(old_foot.get(cid, 0.0)), float(new_foot.get(cid, 0.0))):
					picking.rebuild_city(String(cid))
				else:
					picking.sync_city(String(cid))
			picking.rebuild_routes_and_stops(lay)
		_record_attachments()
		for cid in changed.get("rebuilt_cities", []):
			_glowing.erase(cid)
		_sync_glow()
		if String(sel.kind) == "city" and not world.city_nodes.has(String(sel.id)):
			select("", "")
		_update_selection_visuals()
		return (Time.get_ticks_usec() - t0) / 1000.0
	var routes_changed: bool = lay.get("routes") != cur_layout.get("routes") or lay.get("stops") != cur_layout.get("stops")
	cur_layout = lay
	for c: Dictionary in lay.cities:
		var cid := String(c.id)
		if (_press.get("id", "") == cid and _obj_drag) or cid == _snap_cid:
			continue                          # 正在拖、正在弹回的城由拖动自己摆
		_place_city(cid, float(c.x), float(c.z), float(c.get("rotation", 0.0)))
	if routes_changed:
		world.layout = lay
		if world.routes_node != null and is_instance_valid(world.routes_node):
			world.routes_node.queue_free()
		world.build_routes()
		if picking != null:
			picking.rebuild_routes_and_stops(lay)
	world.layout = lay
	_name_plaques()
	_layout_plaques()
	_update_selection_visuals()
	return (Time.get_ticks_usec() - t0) / 1000.0


# ------------------------------------------------------------------ 镜头
## 双击城 / 列表里点一行：镜头滑过去（游戏双击地面同一种滑法）
func fly_to_city(cid: String) -> void:
	var st := city_state(cid)
	_fling = Vector2.ZERO
	_follow = ""
	_goal = _clamp_target(_focus_point(Vector3(float(st.x), 0.0, float(st.z))), world.camera.size)


## 「看全图」：_zoom_at(视口中心, MIN_ZOOM)，目标 (64, 0, 30)，整块棋盘都在画面里（3.12.3）
func view_all() -> void:
	_zoom_at(_safe_rect().get_center(), MIN_ZOOM, false)
	_fling = Vector2.ZERO
	_follow = ""
	_goal = _clamp_target(Vector3(64.0, 0.0, 30.0), world.camera.size)


## 左下角的「＋」「－」：和键盘 + / − 一样（视口中心 ×1.1）
func zoom_button(dir: int) -> void:
	_zoom_at(_safe_rect().get_center(), _zoom * (1.1 if dir > 0 else 1.0 / 1.1))


func zoom_factor() -> float:
	return _zoom


# ------------------------------------------------------------------ 画在棋盘上的反馈
func _build_overlays() -> void:
	if _tex.is_empty():
		_tex[0] = _ring_texture(RING_FILL, RING_EDGE, 0.7, 0)
		_tex[1] = _ring_texture(GREEN.lightened(0.15), GREEN.darkened(0.35), 0.7, 0)
		_tex[-1] = _ring_texture(RED.lightened(0.1), RED.darkened(0.35), 0.7, 0)
		_tex["home"] = _ring_texture(Color(1, 1, 1, 0.95), Color(1, 1, 1, 0.95), 0.965, 64)
		_tex["stop"] = _ring_texture(Kit.OCHRE, Kit.OCHRE_DEEP, 0.62, 0)
	_ring = _decal(_tex[0])
	_ring.set_meta("state", 0)
	_home_circle = _decal(_tex["home"])
	_home_circle.size = Vector3(Backend.R_MOVE * 2.0, 4.0, Backend.R_MOVE * 2.0)
	_stop_ring = _decal(_tex["stop"])
	_stop_ring.size = Vector3(2.1, 2.0, 2.1)
	var km := StandardMaterial3D.new()
	km.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	km.albedo_color = RING_FILL
	km.no_depth_test = true
	km.render_priority = 4
	var kom := StandardMaterial3D.new()
	kom.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	kom.albedo_color = RING_EDGE.darkened(0.2)
	kom.no_depth_test = true
	kom.render_priority = 3
	_knob = MeshInstance3D.new()
	var ks := SphereMesh.new()
	ks.radius = 0.34
	ks.height = 0.68
	_knob.mesh = ks
	_knob.material_override = km
	var outline := MeshInstance3D.new()
	var os := SphereMesh.new()
	os.radius = 0.44
	os.height = 0.88
	outline.mesh = os
	outline.material_override = kom
	_knob.add_child(outline)
	_knob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_knob.visible = false
	world.world_root.add_child(_knob)
	_route_hl = MeshInstance3D.new()
	_route_hl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_route_hl.visible = false
	world.world_root.add_child(_route_hl)
	_band = MeshInstance3D.new()
	_band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_band.visible = false
	world.world_root.add_child(_band)
	if _gold_plaque == null:
		_gold_plaque = _gold_plaque_texture()
	# 光标旁的一句话（悬停：「长安 · 可以拖」；拖动：不合格的原因）
	_label_box = PanelContainer.new()
	_label_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label_box.add_theme_stylebox_override("panel", Kit.pill_box(14, 6))
	_label = Kit.label("", 20, Kit.INK)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label_box.add_child(_label)
	_label_box.visible = false
	_tooltip_layer.add_child(_label_box)


func _decal(tex: Texture2D) -> Decal:
	var d := Decal.new()
	d.texture_albedo = tex
	d.texture_emission = tex
	d.emission_energy = 0.35
	d.cull_mask = 1                        # 只印在地面层（城在第 2 层，review.gd build_cities）
	d.upper_fade = 0.05
	d.lower_fade = 0.05
	d.visible = false
	world.world_root.add_child(d)
	return d


## 一张圆环贴图：外圈描边、里面一圈填色；dashes > 0 时是虚线
func _ring_texture(fill: Color, edge: Color, inner: float, dashes: int) -> ImageTexture:
	var n := DECAL_TEX
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var half := n * 0.5
	var aa := 2.0 / half
	var edge_w := 0.09 if dashes == 0 else 0.0
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5 - half, y + 0.5 - half) / half
			var r := d.length()
			var a := clampf((1.0 - r) / aa, 0.0, 1.0) * clampf((r - inner) / aa, 0.0, 1.0)
			if dashes > 0 and fmod((atan2(d.y, d.x) / TAU + 1.0) * dashes, 1.0) > 0.55:
				a = 0.0
			if a <= 0.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var c := edge if (r > 1.0 - edge_w or r < inner + edge_w) else fill
			img.set_pixel(x, y, Color(c.r, c.g, c.b, c.a * a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## 选中的名牌变金色：把游戏名牌贴图按亮度重新上成金色（字换成深色）
func _gold_plaque_texture() -> Texture2D:
	var img := CITY_PLAQUE_TEXTURE.get_image()
	if img == null or img.is_empty():
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var dark := Color("#E3A34E")
	var light := Color("#FFF3C8")
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var lum := c.r * 0.3 + c.g * 0.59 + c.b * 0.11
			var g := dark.lerp(light, clampf(lum * 2.2, 0.0, 1.0))
			img.set_pixel(x, y, Color(g.r, g.g, g.b, c.a))
	return ImageTexture.create_from_image(img)


## 圆环的状态：0 = 选中（奶油描驼色），1 = 拖动中能放（绿），-1 = 不行（红）
func _ring_state(st: int) -> void:
	_ring.set_meta("state", st)
	_ring.texture_albedo = _tex[st]
	_ring.texture_emission = _tex[st]


func _ring_is_ok() -> bool:
	return int(_ring.get_meta("state", 0)) >= 0


## 城脚的椭圆环、转向圆钮、选中的硬币环、选中的路线（赭黄、加粗）
func _update_selection_visuals() -> void:
	if _ring == null:
		return
	var kind := String(sel.kind)
	var id := String(sel.id)
	_ring.visible = kind == "city"
	_knob.visible = false
	_stop_ring.visible = kind == "stop"
	_route_hl.visible = kind == "route"
	var handles := {}
	if kind == "city":
		var st := city_state(id)
		var foot := float(st.foot)
		_ring.global_position = Vector3(float(st.x), float(st.y), float(st.z))
		_ring.size = Vector3(foot * 1.6, 3.0, foot * 1.36)
		if not _obj_drag and _zoom >= KNOB_MIN_ZOOM:
			# 转向圆钮在圆环东边（南边会被名牌挡住）；转 ±45° 时沿着东边这段弧走。
			# 可点半径屏幕上至少 24 像素（3.12.2 的 48×48），圆钮画得和可点的一样大，整个放在圆环外面：
			# 不然放大了的可点球会盖住城的东半边，点城、双击城都会点到圆钮上
			var h: Dictionary = geo.home.get(id, {})
			var phi := float(st.rotation) - float(h.get("rotation", 0.0))
			var r: float = picking.handle_radius() if picking != null else Picking.HANDLE_R
			var kp := Vector3(float(st.x) + cos(phi) * (foot * 0.8 + r), float(st.y) + 0.3, float(st.z) - sin(phi) * (foot * 0.68 + r))
			_knob.global_position = kp
			_knob.scale = Vector3.ONE * (r / KNOB_VIS_R)
			_knob.visible = true
			handles["rotate"] = kp
	elif kind == "stop":
		for s: Dictionary in cur_layout.get("stops", []):
			if String(s.id) == id:
				_stop_ring.global_position = Vector3(float(s.x), float(s.y), float(s.z))
	elif kind == "route":
		_draw_route_highlight(id)
		var editor: Variant = get_meta("route_editor", null)
		if editor != null and editor.rid == id: handles = editor.handles_for()
	if picking != null:
		picking.set_handles(handles)


func _draw_route_highlight(rid: String) -> void:
	for r: Dictionary in cur_layout.get("routes", []):
		if String(r.id) == rid:
			_route_hl.mesh = _ribbon(r.points, 0.45, 0.005)
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.albedo_color = Kit.OCHRE
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_color.a = 0.28
			m.render_priority = -1
			_route_hl.material_override = m
			return


## 拖原版城时连着它的路按橡皮筋跟着变形：画成半透明的预览带，绿 = 合格，红 = 不合格；松手才换真正的虚线
func _draw_band(lay: Dictionary, cid: String, ok: bool) -> void:
	var mine: Array = geo.incident.get(cid, [])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for r: Dictionary in lay.get("routes", []):
		if String(r.id) in mine:
			_ribbon_into(st, r.points, 0.3, 0.16)
			any = true
	_band.visible = any
	if not any:
		return
	_band.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var c := GREEN if ok else RED
	m.albedo_color = Color(c.r, c.g, c.b, 0.6)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.render_priority = 2
	_band.material_override = m


func _ribbon(points: Array, width: float, lift: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_ribbon_into(st, points, width, lift)
	return st.commit()


func _ribbon_into(st: SurfaceTool, points: Array, width: float, lift: float) -> void:
	var step := 3
	var prev := Vector3.INF
	for i in range(0, points.size(), step):
		var j := mini(i + step, points.size() - 1)
		var a := Vector3(float(points[i][0]), float(points[i][1]) + lift, float(points[i][2]))
		var b := Vector3(float(points[j][0]), float(points[j][1]) + lift, float(points[j][2]))
		var d := b - a
		if d.length() < 1e-4:
			continue
		var side := Vector3(-d.z, 0.0, d.x).normalized() * width * 0.5
		st.add_vertex(a - side)
		st.add_vertex(b - side)
		st.add_vertex(b + side)
		st.add_vertex(a - side)
		st.add_vertex(b + side)
		st.add_vertex(a + side)
		prev = b


func _show_label(text: String, pos: Vector2, warn: bool) -> void:
	if _label_box == null:
		return
	if text == "":
		_label_box.visible = false
		return
	_label.text = text
	_label.add_theme_color_override("font_color", RED if warn else Kit.INK)
	_label_box.visible = true
	_label_box.reset_size()
	# 放在光标右上方：城的名牌在城下面，放右下会把名牌盖住
	var p := pos + Vector2(20, -_label_box.size.y - 14)
	p.x = clampf(p.x, 6.0, size.x - _label_box.size.x - 6.0)
	if p.y < 6.0:
		p.y = pos.y + 22.0
	_label_box.position = p


func _process(dt: float) -> void:
	super(dt)
	# 缩放变了：圆钮跟着换大小和位置（屏幕上一样大），缩得太小就收起
	if String(sel.kind) == "city":
		var ppu := px_per_unit()
		if absf(ppu - float(get_meta("knob_ppu", -1.0))) > 0.01:
			set_meta("knob_ppu", ppu)
			_update_selection_visuals()
	if _obj_drag:
		_edge_pan_while_dragging(dt)
	elif _reason_until > 0 and Time.get_ticks_msec() > _reason_until:
		_reason_until = 0
		if hover.kind == "":
			_label_box.visible = false


func begin_placement(zone: Image) -> void:
	set_landscape_tool("")
	end_placement()
	clear_workshop_selection()
	_set_hover({"kind": "", "id": ""})
	_label_box.visible = false
	placement_mode = true
	_placement_zone = zone
	if zone != null and not zone.is_empty():
		var tint := Image.create(zone.get_width(), zone.get_height(), false, Image.FORMAT_RGBA8)
		for y in zone.get_height():
			for x in zone.get_width():
				tint.set_pixel(x, y, Color(GREEN.r, GREEN.g, GREEN.b, 0.52) if zone.get_pixel(x, y).r > 0.0 else Color(0, 0, 0, 0))
		_placement_decal = Decal.new()
		_placement_decal.texture_albedo = ImageTexture.create_from_image(tint)
		_placement_decal.texture_emission = _placement_decal.texture_albedo
		_placement_decal.emission_energy = 0.35
		_placement_decal.cull_mask = 1
		_placement_decal.upper_fade = 0.05
		_placement_decal.lower_fade = 0.05
		_placement_decal.size = Vector3(zone.get_width() * CustomMapGeoRules.GRID, 12.0, zone.get_height() * CustomMapGeoRules.GRID)
		_placement_decal.position = Vector3(_placement_decal.size.x * 0.5, 2.0, _placement_decal.size.z * 0.5)
		world.world_root.add_child(_placement_decal)
	_placement_pin = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.52
	cone.bottom_radius = 0.0
	cone.height = 1.5
	_placement_pin.mesh = cone
	_placement_pin.visible = false
	world.world_root.add_child(_placement_pin)


func end_placement() -> void:
	set_suggestions([], "")
	placement_mode = false
	_placement_zone = null
	for node in [_placement_decal, _placement_pin]:
		if is_instance_valid(node):
			node.queue_free()
	_placement_decal = null
	_placement_pin = null


func _update_placement_pin(pos: Vector2) -> void:
	if _placement_pin == null:
		return
	var p := _ground_at(pos)
	_placement_pin.visible = p != Vector3.INF
	if p == Vector3.INF:
		return
	_placement_pin.position = p + Vector3(0.0, 0.75, 0.0)
	var ok := CustomMapFreeAuthor.enabled(cur_doc) and p.x>=0 and p.x<=128 and p.z>=0 and p.z<=59.63125
	if _placement_zone != null:
		var cell := Vector2i(int(p.x / CustomMapGeoRules.GRID), int(p.z / CustomMapGeoRules.GRID))
		if Rect2i(Vector2i.ZERO, _placement_zone.get_size()).has_point(cell):
			ok = _placement_zone.get_pixelv(cell).r > 0.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = GREEN if ok else RED
	_placement_pin.material_override = mat
	_show_label(("点这里放自由城市草稿" if CustomMapFreeAuthor.enabled(cur_doc) else "点这里放城") if ok else "这里暂时放不下，试试绿色的地方", pos, not ok)


## 拖到视口边：地图朝那边走（3.12.3「移动城」），同时让城跟着光标
func _edge_pan_while_dragging(dt: float) -> void:
	var p := _last_pointer
	if p == Vector2.INF:
		return
	var dir := Vector2(
		-1.0 if p.x < EDGE_PAN_PX else (1.0 if p.x > size.x - EDGE_PAN_PX else 0.0),
		-1.0 if p.y < EDGE_PAN_PX else (1.0 if p.y > size.y - EDGE_PAN_PX else 0.0))
	if dir == Vector2.ZERO:
		return
	_pan_by(-dir.normalized() * size.y * 0.6 * dt)
	_drag_to(p)


func get_workshop_debug_state() -> Dictionary:
	return {"sel": sel.duplicate(), "hover": hover.duplicate(), "dragging": _obj_drag, "pressing": not _press.is_empty(),
		"glowing": _glowing.keys(), "ring_state": int(_ring.get_meta("state", 0)) if _ring != null else 0,
		"label": _label.text if _label_box != null and _label_box.visible else "", "zoom": _zoom,
		"cursor": mouse_default_cursor_shape, "world_rebuilds": int(get("world_rebuilds")) if "world_rebuilds" in self else -1}


# Screen-sized hints remain readable when the player zooms out.
func set_suggestions(spots: Array, kind: String) -> void:
	if _guides != null:
		_guides.set_suggestions(spots, kind)


func focus_position(at: Vector2) -> void:
	_zoom_at(_safe_rect().get_center(), maxf(_zoom, 0.85), false)
	_fling = Vector2.ZERO
	_follow = ""
	_goal = _clamp_target(_focus_point(Vector3(at.x, 0.0, at.y)), world.camera.size)


func set_landscape_tool(op: String, radius := 4.0) -> void:
	cancel_drag()
	if _guides != null:
		_guides.set_tool(op, radius)
	if op != "":
		set_suggestions([], "")
		_set_hover({"kind": "", "id": ""})
		_label_box.visible = false


func cancel_landscape_stroke() -> bool:
	return _guides.cancel_stroke() if _guides != null else false


func landscape_debug_state() -> Dictionary:
	return _guides.debug_state() if _guides != null else {}


# Confirmation preview projects actual validated 3D geometry into a pointer-transparent
# screen overlay. Terrain and plaques cannot hide its two stops or step label.
var _route_preview_root: Node3D
var _route_preview_key := ""
var _connection_preview: Control
var connection_preview_state: Dictionary = {}

class ConnectionOverlay extends Control:
	const UI := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
	const COLOR := Color("#834DCE")
	var board: Control
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	func _process(_dt: float) -> void:
		queue_redraw()
	func _draw() -> void:
		if not is_instance_valid(board) or board.connection_preview_state.is_empty(): return
		var data: Dictionary = board.connection_preview_state
		var points := PackedVector2Array()
		for p: Array in data.route.points:
			points.append(board._to_view(Vector3(float(p[0]), float(p[1]) + 0.22, float(p[2]))))
		if points.size() < 2: return
		# The route and coin stops are rendered by the production 3D renderer.
		var font: Font = UI.font("body", 600)
		var index := 0
		for stop: Dictionary in data.stops:
			index += 1
			var at: Vector2 = board._to_view(Vector3(float(stop.x), float(stop.y) + 0.22, float(stop.z)))
			draw_string(font, at + Vector2(-6, -14), str(index), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, COLOR)
		var middle: Vector2 = points[points.size() / 2]
		var label := Rect2(middle + Vector2(-100, -78), Vector2(200, 38))
		draw_line(label.get_center() + Vector2(0, 19), middle, COLOR, 2.0, true)
		draw_rect(label, UI.CREAM)
		draw_rect(label, COLOR, false, 2.0)
		draw_string(font, label.position + Vector2(12, 27), "预览 · %s · %d 步" % ["陆路" if str(data.route.type)=="LAND" else "海路",int(data.steps)], HORIZONTAL_ALIGNMENT_LEFT, -1, 20, COLOR)

func clear_route_preview() -> void:
	if is_instance_valid(_route_preview_root): _route_preview_root.queue_free()
	_route_preview_root = null
	_route_preview_key = ""

func show_route_preview(route: Dictionary, stops: Array, opacity := 0.7) -> void:
	var key := var_to_str([route,stops]).sha256_text()
	if key == _route_preview_key and is_instance_valid(_route_preview_root): return
	clear_route_preview()
	if world == null or not is_instance_valid(world.world_root) or route.is_empty(): return
	_route_preview_key = key
	_route_preview_root = Node3D.new()
	_route_preview_root.name = "WorkshopRoutePreview"
	world.world_root.add_child(_route_preview_root)
	var renderer := preload("res://tools/merchant_board_claude_review.gd").new()
	renderer.world_root = _route_preview_root
	renderer.layout = {"routes":[route],"stops":stops}
	renderer.build_routes()
	for mesh: GeometryInstance3D in renderer.routes_node.find_children("*","GeometryInstance3D",true,false):
		if mesh.material_override is StandardMaterial3D:
			mesh.material_override.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mesh.material_override.albedo_color.a = opacity
	renderer.free()

func clear_connection_preview() -> void:
	clear_route_preview()
	if is_instance_valid(_connection_preview):
		_connection_preview.hide()
		_connection_preview.queue_free()
	_connection_preview = null
	connection_preview_state.clear()

func show_connection_preview(layout: Dictionary, rid: String, errors: Array = []) -> void:
	clear_connection_preview()
	var route: Dictionary = {}
	for r: Dictionary in layout.get("routes", []):
		if str(r.id) == rid: route = r; break
	if route.is_empty(): return
	var stops: Array = []
	for stop: Dictionary in layout.get("stops", []):
		if str(stop.id).begins_with(rid + "_"): stops.append(stop.duplicate(true))
	connection_preview_state = {"route": route.duplicate(true), "stops": stops, "steps": stops.size()+1, "issues":errors.duplicate(true)}
	show_route_preview(route,stops,0.7)
	var overlay := ConnectionOverlay.new()
	overlay.name = "TemporaryConnectionPreview"
	overlay.board = self
	add_child(overlay)
	_connection_preview = overlay
	var middle: Array = route.points[route.points.size() / 2]
	focus_position(Vector2(float(middle[0]), float(middle[2])))

func cancel_badge_drag() -> bool:
	if _badge_drag.is_empty(): return false
	_badge_drag.clear()
	world.layout = Backend.derive(base_layout, cur_doc, geo)
	cur_layout = world.layout
	_layout_plaques()
	return true

func _badge_input(event: InputEvent) -> bool:
	if _city_plaque_runtime == null: return false
	if not _badge_drag.is_empty():
		if event is InputEventMouseMotion:
			var delta: Vector2 = event.position - Vector2(_badge_drag.start)
			if delta.length() >= DRAG_PX: _badge_drag.moved = true
			if _badge_drag.moved:
				var tag: Control = _plaques[_badge_drag.cid]
				var safe := _safe_rect().grow(-8.0)
				var top: Vector2 = _city_plaque_runtime._fit_position(Vector2(_badge_drag.top)+delta,tag.size,safe)
				var offset: Vector2 = _city_plaque_runtime.manual_offset(_badge_drag.cid,top+tag.size*0.5)
				offset = offset.clamp(Vector2.ONE*-1920.0,Vector2.ONE*1920.0)
				_badge_drag.offset = offset
				for c: Dictionary in world.layout.cities:
					if str(c.id) == str(_badge_drag.cid):
						c.city_badge = c.get("city_badge", {}).duplicate(true)
						c.city_badge.mode = "MANUAL"; c.city_badge.offset_px = [offset.x,offset.y]
				_layout_plaques()
			return true
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			var before := _badge_drag.duplicate(true)
			cancel_badge_drag()
			if before.moved: badge_move_committed.emit(str(before.cid),Vector2(before.offset))
			return true
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not event.double_click and not route_pick_preferred:
		var cid := plaque_city_at(event.position)
		if cid != "":
			get_viewport().gui_release_focus()
			select("city",cid)
			var tag: Control = _plaques[cid]
			# Preview must never mutate the live persisted dictionary or the cached base layout.
			world.layout = world.layout.duplicate(true)
			_badge_drag = {"cid":cid,"start":event.position,"top":tag.position,"moved":false,"offset":Vector2.ZERO}
			say.emit("拖动名牌调整位置；Esc 取消。城市落点保持不动。")
			return true
	return false

func _author_safe(at:Dictionary)->bool:
	return is_finite(float(at.x)) and is_finite(float(at.z)) and is_finite(float(at.rotation)) and float(at.x)>=0 and float(at.x)<=128 and float(at.z)>=0 and float(at.z)<=59.63125
