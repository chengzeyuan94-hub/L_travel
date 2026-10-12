extends Control
## 「L叔地图工坊」的根节点（DESIGN 3.12；主场景 scenes/map_workshop/map_workshop_main.tscn，特性标签 lshu_map_workshop）。
## 管：设计分辨率缩放（按 1920×1080 设计，k = min(宽/1920, 高/1080)）、顶栏、整屏布局、启动时打开哪张图和欢迎卡、
## L叔 等待卡、关窗拦截、文件操作（保存 / 另存为 / 打开 / 重置 / 导入，全部先选再确认，R26），以及键盘：
##   _input 里先于任何控件处理 撤销 / 重做（ui_undo / ui_redo：⌘Z / ⇧⌘Z，Windows 是 Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y）、
##   ⌘S（Ctrl+S）和 Esc（3.12.3「输入框和快捷键」）。除此之外没有工坊自己发明的键：平移、缩放、R / Home 都是游戏棋盘的。
## 工坊的 GameState.content 是当前地图合并后的 content（第一阶段：原版），没有玩家，也不调 SetupSystem。
## 工坊从不调用胜场、设置、存档、音乐的代码；地图文件只经 CustomMapStore 写到 ShanheLvren/maps/（T-E7）。
## 开发参数：-- --size=1920x1080（固定窗口大小，截图用）  --catalogue-allow-draft（灰盒目录，R30）

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const Backend := preload("res://scripts/map_workshop/workshop_backend.gd")
const WorkshopBoard := preload("res://scripts/map_workshop/workshop_board.gd")
const Mutations := preload("res://scripts/map_workshop/workshop_mutations.gd")
const Doc := preload("res://scripts/map_workshop/workshop_doc.gd")
const History := preload("res://scripts/map_workshop/workshop_history.gd")
const PropPanel := preload("res://scripts/map_workshop/workshop_panel.gd")
const Dialogs := preload("res://scripts/map_workshop/workshop_dialogs.gd")
const Drawers := preload("res://scripts/map_workshop/workshop_drawers.gd")
const Library := preload("res://scripts/map_workshop/workshop_library.gd")
const Landscape := preload("res://scripts/custom_map/custom_map_landscape.gd")
const LshuIcons := preload("res://scripts/lshu_ui/lshu_icons.gd")
const STAGE := Vector2(1920, 1080)
const TOP_H := 76.0
const BOARD_RECT := Rect2(88, 76, 1432, 952)
const SETUP_DIR := "res://assets/game/ui/lshu_setup/"
const AUTOSAVE_SEC := 1.0
## 左下角那排按钮和提示条盖住视口最下面这么高（设计像素）：镜头按「没被挡住的那一块」对准，南边的城也能挪到它上面
const BOTTOM_BAR := 0.0
const RED := Color("#CD483A")

## 提示条上 L叔 说的话（3.12.10）
const LINES := {
	"first": "点「加一座城」，把你的家乡放到地图上！",
	"idle": "点一座城可以挪它；滚轮能放大缩小。",
	"place": "点一下绿色的地方，把城放下。",

	"saved": "存好啦！",
	"imported": "装好啦！回到《旅行L叔》的标题页，再点「商旅模式」，就是这张地图。",
	"first_route": "路怎么弯都行，走起来永远是 3 步。",
	"city_selected": "按住它拖一拖就能挪；城脚的小圆钮可以转向。",
	"store_pending": "保存没有成功，请稍后再试。",
	"import_pending": "地图还没有装好，请稍后再试。",
}

var board: Control
var doc                                        # workshop_doc.gd
var history                                    # workshop_history.gd
var panel: Control
var dialogs: Control
var drawers: Control
var library: Control
var catalogue: Dictionary = {}
var issues: Array = []                         # 当前地图错误；导入只看这些
var warnings: Array = []
var action_issues: Array = []                   # 未应用的修改，不属于地图校验
var boot_ms := {}                              # 启动各段耗时（T-E8）
var _stage: Control
var _bg: ColorRect
var _name_pill: Button
var _btn := {}                                 # 顶栏按钮
var _add_btn: Button
var _add_caption: Label
var _chooser: Control
var _hint: Label
var _wait: Control
var _welcome: Control
var _enlarge: Control
var _key_sink: Control
var _autosave_timer: Timer
var _k := 1.0
var _origin := Vector2.ZERO
var _ready_done := false
var _installed_name := ""
var _installed_sha := ""                       # 游戏里装着的那份的 sha（「已装进游戏」绿章）
var _counts_win := true                        # 校验器同一次返回的「算不算胜场」（D2 = A，R28）
var _state_map_id := ""                        # 上次写进 workshop_state.json 的 map_id
var _said_first_route := false
var _placing_type := ""
var _placement_busy := false
var _placement_epoch := 0
var _drawer_city := ""
var _base_content: Dictionary = {}
var _landscape_tools: PanelContainer
var _landscape_button: Button
var _landscape_buttons: Dictionary = {}
var _landscape_op := ""
var _landscape_radius := 4.0
var _landscape_busy := false
var _plant_tools: PanelContainer
var _plant_button: Button
var _local_assets: PanelContainer
var _piece_tools: PanelContainer
var _piece_button: Button
var _intro_tools: PanelContainer
var _intro_button: Button
var _asset_button: Button
var _plant_file_dialog: FileDialog
var plant_timings: Array = []
var _find_button: Button
var _stop_search_button: Button
var _search_epoch := 0
var _search_spots: Array = []
var _search_kind := ""
var _search_city := ""
var _search_running := false
var _search_cursor := 0
var _search_status := "idle"
var _search_phase := ""
var _search_limit_reason := ""
var _search_total_budget_ms := 24000
var _search_host_budget_ms := 6000
var _pair_cache: Dictionary = {}
var search_timings: Array = []
var _commit_measure_task := -1
var _connection_epoch := 0
var _connection_ui: PanelContainer
var _connection_city := ""
var _connection_user_medium := false
var _connection_modes: OptionButton
var _connection_targets: OptionButton
var _connection_note: Label
var _connection_preview_button: Button
var _connection_confirm_button: Button
var _connection_locate_button: Button
var _connection_candidate: Dictionary = {}
var _connection_running := false
var _playtest: Node
var _playtest_button: Button
var _playtest_guard: Dictionary = {}
var test_playtest_position := ""
var _playtest_wait_timer: Timer
var _asset_library: PanelContainer
var _asset_library_button: Button
var _v02_shell: Node
var _route_editor: Control


func _exit_tree() -> void:
	_ready_done = false
	if is_instance_valid(_playtest): _playtest.stop()
	_connection_epoch += 1
	# Direct queue_free also invalidates suspended work, without touching child UI.
	_search_epoch += 1
	_placement_epoch += 1
	_search_running = false
	_placement_busy = false
	_search_phase = ""
	_search_status = "cancelled"


func _ready() -> void:
	if "--workshop-playtest" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred("res://scenes/map_workshop/workshop_playtest.tscn")
		return
	PublicRulesUI.attach(self)
	get_tree().set_auto_accept_quit(false)
	_fit_window()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg = ColorRect.new()
	_bg.color = Kit.CREAM_DEEP
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)
	_stage = Control.new()
	_stage.name = "Stage"
	_stage.size = STAGE
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stage)
	_build_ui()
	_build_playtest_ui()
	_v02_shell = preload("res://scripts/map_workshop/workshop_shell_v02.gd").new()
	add_child(_v02_shell)
	_asset_library = preload("res://scripts/map_workshop/workshop_asset_library.gd").new()
	_asset_library.workshop = self
	_stage.add_child(_asset_library)
	_v02_shell.setup(self)
	resized.connect(_layout)
	_layout()
	_show_wait(true)
	# 等待卡先画出来，再同步建世界（建世界要几秒，这期间画面不刷新）
	await get_tree().process_frame
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	_boot()


## 1920×1080 的 90% 起一个 16:9 窗口，最小 1280×720（3.12.1）；--size=WxH 固定大小（截图用）
func _fit_window() -> void:
	var win := get_window()
	if DisplayServer.get_name() == "headless":
		return
	win.min_size = Vector2i(1280, 720)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--size="):
			var p := a.trim_prefix("--size=").split("x")
			win.size = Vector2i(int(p[0]), int(p[1]))
			return
	var usable := DisplayServer.screen_get_usable_rect(win.current_screen)
	var w := int(minf(usable.size.x * 0.9, usable.size.y * 0.9 * 16.0 / 9.0))
	var want := Vector2i(maxi(1280, w), maxi(720, int(w * 9.0 / 16.0)))
	win.size = want
	win.position = usable.position + (usable.size - want) / 2


# ------------------------------------------------------------------ 启动顺序（3.12.1）
## 先决定打开哪张图 → 设好 content → 棋盘 _ready 只建一次世界 → 等待卡期间同步建好拾取碰撞体 → 撤掉等待卡
func _boot() -> void:
	var t0 := Time.get_ticks_msec()
	catalogue = Backend.load_catalogue()
	_base_content = CustomMapLoader.base_content()
	var inst := Backend.startup_installed()
	_installed_name = String(inst.get("overlay", {}).get("name", "")) if not inst.is_empty() else ""
	_installed_sha = String(inst.get("sha256", ""))
	var start := _pick_start()
	var base := Backend.load_base_layout()
	doc = Doc.new(base)
	doc.installed_sha = _installed_sha
	history = History.new(Backend.canonical_text)
	if start.has("doc"):
		doc.open(start.doc, bool(start.get("saved", false)), String(start.get("saved_sha", "")))
	else:
		doc.new_map("新地图")
	GameState.content = Backend.content_for(doc.doc)
	if is_instance_valid(_piece_tools) and _piece_tools.visible and _piece_tools.source_sha != doc.sha():_piece_tools.load_transport(_piece_tools.transport)
	if is_instance_valid(_intro_tools) and _intro_tools.visible and _intro_tools.source_sha != doc.sha():
		if CustomMapCityIntro.city_ids(doc.doc).has(_intro_tools.target_city):_intro_tools.load_city(_intro_tools.target_city)
		else:_intro_tools.close_tools()
	board = WorkshopBoard.new()
	board.name = "WorkshopBoard"
	board.day_time_override = 300.0            # 固定正午的光（工坊里没有对局时间）
	board.day_speed = 0.0
	# 要打开的那张图的推导布局先设进棋盘，_ready 只建一次世界（WP3 的成员；WP3 之前返回 {}，先建原版再就地摆）
	var lay0: Dictionary = Backend.boot_layout(base, doc.doc)
	if not lay0.is_empty() and "initial_layout_override" in board:
		board.set("initial_layout_override", lay0)
	add_child(board)
	move_child(board, 1)                       # 在背景之上、界面之下
	_layout()
	board.set_hud_safe_insets(0.0, BOTTOM_BAR * _k)
	boot_ms["world"] = Time.get_ticks_msec() - t0
	boot_ms["picking"] = board.build_picking()
	board.selection_changed.connect(_on_selection_changed)
	board.badge_move_committed.connect(func(cid: String, offset: Vector2) -> void:
		_accept_badge(Mutations.change_badge(doc.doc,cid,"offset_px",[offset.x,offset.y],_base_content,board.base_layout,catalogue),"挪名牌"))
	board.city_move_committed.connect(_on_city_moved)
	board.drag_changed.connect(_on_drag_changed)
	board.say.connect(say)
	board.place_requested.connect(_on_place_requested)
	board.landscape_stroke_committed.connect(_on_landscape_stroke)
	board.suggestion_selected.connect(_on_suggestion_selected)
	_route_editor = preload("res://scripts/map_workshop/workshop_route_editor.gd").new()
	_route_editor.workshop = self; _route_editor.board = board; board.add_child(_route_editor)
	_plant_tools.bind(board, doc)
	_apply_doc(false)
	_show_wait(false)
	boot_ms["total"] = Time.get_ticks_msec() - t0
	print("MAP_WORKSHOP ready ", JSON.stringify(boot_ms))
	_ready_done = true
	board.view_all()
	if bool(start.get("welcome", false)):
		_show_welcome()
	elif bool(start.get("ask_autosave", false)):
		say(LINES.idle)
		_ask_autosave(start.get("saved_doc", {}))
	else:
		say(LINES.idle)


## 启动时打开哪张图（3.12.2，写死的三条）：
## 1. 有自动存档、而且内容 sha 和这张图已保存的不同（没保存过也算）→ 先打开它，再问「接着改吗？」；
## 2. 否则打开 maps/workshop_state.json 记下的上次那张（记录丢了而库不空时，退一步打开库里最新的一张）；
## 3. 都没有 → 欢迎卡。
## 第一阶段（WP1 之前）存储是骨架，三条都查不到东西，所以总是欢迎卡
func _pick_start() -> Dictionary:
	var last := String(Backend.read_workshop_state().get("last_map_id", ""))
	var ids: Array = Backend.autosave_ids()
	if last in ids:                             # 上次那张图的自动存档先看
		ids.erase(last)
		ids.push_front(last)
	for id: String in ids:
		var a := Backend.read_autosave(id)
		if a.is_empty():
			continue
		var saved := Backend.load_saved(id)
		if CustomMapStore.is_superseded_autosave(id, a, saved):
			continue
		if saved.is_empty() or Backend.sha256(saved) != Backend.sha256(a):
			return {"doc": a, "saved": not saved.is_empty(), "saved_sha": Backend.sha256(saved) if not saved.is_empty() else "",
				"saved_doc": saved, "ask_autosave": true}
	var d := Backend.load_saved(last)
	if not d.is_empty():
		return {"doc": d, "saved": true}
	var newest := {}
	for e in Backend.startup_library():
		if e is Dictionary and String(e.get("saved_at", e.get("updated_at", ""))) >= String(newest.get("saved_at", newest.get("updated_at", ""))):
			newest = e
	d = Backend.load_saved(String(newest.get("map_id", "")))
	if not d.is_empty():
		return {"doc": d, "saved": true}
	return {"welcome": true}


## 启动时有没保存的自动存档（3.12.2 第 1 条、3.12.11）：它已经打开在棋盘上了；【接着改】是安全选项（默认焦点、Esc），
## 【不要了】先把它放进「扔掉的地图」（没保存的改动），放成功了才换成已保存的那一版（没存过就是一张新地图）
func _ask_autosave(saved_doc: Dictionary) -> void:
	var entries := Backend.startup_library()
	var latest: Dictionary = entries[0] if not entries.is_empty() else {}
	var buttons: Array = [{"id":"keep", "text":"接着改草稿", "kind":"safe"}]
	if not latest.is_empty(): buttons.append({"id":"latest", "text":"打开最近作品", "kind":"middle"})
	buttons.append({"id":"drop", "text":"放进扔掉的地图", "kind":"outline_danger"})
	var stamp := str(doc.doc.get("workshop", {}).get("updated_at", "时间未记录")).replace("T", " ")
	var recent := "最近保存的是「%s」。" % str(latest.get("name", "")) if not latest.is_empty() else "还没有保存作品。"
	dialogs.confirm("autosave", "恢复「%s」的草稿？" % doc.map_name(), "草稿时间：%s\n%s\n放进扔掉的地图后仍可找回来。" % [stamp, recent], buttons,
		func(ch: String) -> void:
			if ch == "drop": _drop_autosave(saved_doc)
			elif ch == "latest" and _prepare_doc_departure(): _switch_doc(Backend.load_saved(str(latest.map_id)), true))


func _drop_autosave(saved_doc: Dictionary) -> void:
	if Backend.discard_autosave(doc.doc) != OK:
		say("没能放进「扔掉的地图」，先不丢。")
		return
	_switch_doc(saved_doc, not saved_doc.is_empty())


# ------------------------------------------------------------------ 界面
func _build_ui() -> void:
	# 顶栏
	var top := PanelContainer.new()
	top.name = "LegacyTop"
	var tb := StyleBoxFlat.new()
	tb.bg_color = Kit.CREAM
	tb.border_color = Kit.SATCHEL
	tb.border_width_bottom = 5
	tb.shadow_color = Color(0.2, 0.12, 0.06, 0.2)
	tb.shadow_size = 10
	top.add_theme_stylebox_override("panel", tb)
	top.position = Vector2.ZERO
	top.size = Vector2(STAGE.x, TOP_H)
	_stage.add_child(top)
	var row := HBoxContainer.new()
	row.name = "LegacyTopActions"
	row.position = Vector2(20, 12)
	row.size = Vector2(STAGE.x - 40, 72)
	row.add_theme_constant_override("separation", 12)
	_stage.add_child(row)
	var av := TextureRect.new()
	av.texture = Kit.icon("lshu_avatar")
	av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	av.custom_minimum_size = Vector2(68, 68)
	row.add_child(av)
	var title := Kit.label("L叔地图工坊", 40, Kit.SATCHEL_DEEP, "title", 700)       # 只有这里用娃娃体
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(title)
	_name_pill = Button.new()
	_name_pill.add_theme_stylebox_override("normal", _pill(Kit.CREAM_DEEP))
	_name_pill.add_theme_stylebox_override("hover", _pill(Kit.CREAM_DEEP.lightened(0.3)))
	_name_pill.add_theme_stylebox_override("pressed", _pill(Kit.CREAM_DEEP.darkened(0.05)))
	_name_pill.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_name_pill.add_theme_font_override("font", Kit.font("body", 600))
	_name_pill.add_theme_font_size_override("font_size", 24)
	_name_pill.add_theme_color_override("font_color", Kit.INK)
	_name_pill.add_theme_color_override("font_hover_color", Kit.INK)
	_name_pill.focus_mode = Control.FOCUS_NONE
	_name_pill.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_name_pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_name_pill.tooltip_text = "点一下给地图改名字"
	_name_pill.pressed.connect(_on_rename)
	row.add_child(_name_pill)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)
	for spec in [["undo", "撤销", "cream", 110], ["redo", "重做", "cream", 110], ["|", "", "", 16],
			["open", "打开", "cream", 110], ["save", "保存", "cream", 110], ["save_as", "另存为", "cream", 130], ["|", "", "", 16],
			["reset", "重置", "cream", 110], ["import", "导入地图", "primary", 190]]:
		if spec[0] == "|":
			var g := Control.new()
			g.custom_minimum_size = Vector2(int(spec[3]), 0)
			row.add_child(g)
			continue
		var b := Kit.button(String(spec[1]), String(spec[2]), 64, 26)
		b.custom_minimum_size.x = int(spec[3])
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		b.pressed.connect(Callable(self, "_on_" + String(spec[0])))
		row.add_child(b)
		_btn[spec[0]] = b
	# 「重置」：奶油底、红字
	for key: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		(_btn.reset as Button).add_theme_color_override(key, RED)
	# 「＋ 加一座城」(24, 120) 300×88，赭黄糖果按钮，图钉图标
	_add_btn = Kit.button("加一座城", "primary", 88, 32)
	_add_btn.icon = load(SETUP_DIR + "icon_pin.png")
	_add_btn.expand_icon = true
	_add_btn.position = Vector2(24, 120)
	_add_btn.size = Vector2(300, 88)
	_add_btn.custom_minimum_size = Vector2(300, 88)
	_add_btn.pressed.connect(_on_add_city)
	_stage.add_child(_add_btn)
	var cap := PanelContainer.new()
	cap.add_theme_stylebox_override("panel", Kit.pill_box(16, 4))
	cap.position = Vector2(40, 216)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add_caption = Kit.label("", 20, Kit.INK)
	cap.add_child(_add_caption)
	_stage.add_child(cap)
	_build_landscape_tools()
	_build_plant_tools()
	_build_local_assets()
	_build_city_intro()
	_build_piece_skins()
	_build_chooser()
	# 左下角：[看全图][＋][－]  (L叔) 提示条
	var bottom := HBoxContainer.new()
	bottom.name = "LegacyBottom"
	bottom.position = Vector2(24, STAGE.y - 88)
	bottom.size = Vector2(1082, 68)
	bottom.add_theme_constant_override("separation", 10)
	_stage.add_child(bottom)
	for spec in [["view_all", "看全图", 130], ["zoom_in", "＋", 64], ["zoom_out", "－", 64]]:
		var b := Kit.button(String(spec[1]), "cream", 64, 26)
		b.custom_minimum_size.x = int(spec[2])
		b.pressed.connect(Callable(self, "_on_" + String(spec[0])))
		bottom.add_child(b)
		_btn[spec[0]] = b
	var hint_box := PanelContainer.new()
	hint_box.add_theme_stylebox_override("panel", Kit.pill_box(18, 8))
	hint_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hint_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hr := HBoxContainer.new()
	hr.add_theme_constant_override("separation", 10)
	hint_box.add_child(hr)
	var hav := TextureRect.new()
	hav.texture = Kit.icon("lshu_avatar")
	hav.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hav.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hav.custom_minimum_size = Vector2(44, 44)
	hr.add_child(hav)
	_hint = Kit.label("", 20, Kit.INK)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.x = 560
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.max_lines_visible = 2
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hr.add_child(_hint)
	bottom.add_child(hint_box)
	# 右栏、抽屉、浮层、确认框（后加的在上面）
	panel = PropPanel.new()
	panel.position = Vector2(BOARD_RECT.end.x, TOP_H)
	_stage.add_child(panel)
	panel.field_committed.connect(_on_field)
	panel.text_committed.connect(_on_text_field)
	panel.field_rejected.connect(func(why: String) -> void: _reject_action({"reason": why}, String(panel.target)))
	panel.field_repaired.connect(func() -> void:
		_clear_action_issues()
		say("输入有效，可以继续编辑。"))
	panel.action.connect(_on_panel_action)
	panel.card_enlarge.connect(_on_card_enlarge)
	drawers = Drawers.new()
	_stage.add_child(drawers)
	drawers.picked.connect(_on_drawer_picked)
	drawers.closed.connect(func() -> void:
		_drawer_city = ""
		if board != null:
			board.set_hud_safe_insets(0.0, BOTTOM_BAR * _k))
	library = Library.new()
	_stage.add_child(library)
	library.request.connect(_on_library)
	_enlarge = Control.new()
	_enlarge.size = STAGE
	_enlarge.visible = false
	_enlarge.mouse_filter = Control.MOUSE_FILTER_STOP
	_enlarge.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_enlarge.visible = false)
	_stage.add_child(_enlarge)
	_build_welcome()
	dialogs = Dialogs.new()
	_stage.add_child(dialogs)
	_build_wait()
	# ⌘ / Ctrl 按着时把焦点放在一个看不见的控件上：游戏棋盘的 WASD 平移只在「没有控件拿着焦点」时走，
	# 这样按 ⌘S 存档不会顺带把地图往下拖一截
	_key_sink = Control.new()
	_key_sink.focus_mode = Control.FOCUS_ALL
	_key_sink.size = Vector2(1, 1)
	_key_sink.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_key_sink)
	_autosave_timer = Timer.new()
	_autosave_timer.one_shot = true
	_autosave_timer.wait_time = AUTOSAVE_SEC
	_autosave_timer.timeout.connect(_autosave_current)
	add_child(_autosave_timer)


func _pill(bg: Color) -> StyleBoxFlat:
	var s := Kit.pill_box(24, 10)
	s.bg_color = bg
	s.border_color = Kit.SATCHEL.lightened(0.3)
	s.set_border_width_all(2)
	s.shadow_size = 0
	return s


func _build_plant_tools() -> void:
	_plant_tools = preload("res://scripts/map_workshop/workshop_plants.gd").new()
	_plant_tools.board = board; _plant_tools.document = doc
	_stage.add_child(_plant_tools)
	_plant_tools.requested.connect(_on_plant_requested)
	_plant_tools.file_requested.connect(_open_plant_json_dialog)
	_plant_tools.ended.connect(func() -> void: panel.visible = true; _refresh_panel())
	_plant_button = Kit.button("单株植物", "cream", 44, 20)
	_plant_button.name = "PlantToolsButton"; _plant_button.position = Vector2(540, 256); _plant_button.custom_minimum_size.x = 180
	_plant_button.pressed.connect(func() -> void:
		panel.suspend_edits(); _end_landscape(); _end_placement()
		if is_instance_valid(_piece_tools):_piece_tools.close_tools()
		if is_instance_valid(_intro_tools):_intro_tools.close_tools()
		if is_instance_valid(_local_assets): _local_assets.cancel(); _local_assets.hide()
		_plant_tools.open_tools(); panel.visible = false)
	_stage.add_child(_plant_button)

func _build_city_intro() -> void:
	_intro_tools = preload("res://scripts/map_workshop/workshop_city_intro.gd").new()
	_intro_tools.workshop = self;_stage.add_child(_intro_tools)
	_intro_button = Kit.button("城市介绍卡", "cream", 44, 20)
	_intro_button.name="CityIntroButton";_intro_button.position=Vector2(980,256);_intro_button.custom_minimum_size.x=240
	_intro_button.pressed.connect(func()->void:
		panel.suspend_edits();_end_landscape();_end_placement();_plant_tools.close_tools();_local_assets.cancel();_local_assets.hide();_piece_tools.close_tools();_intro_tools.open_tools())
	_stage.add_child(_intro_button)

func _build_local_assets() -> void:
	_local_assets = preload("res://scripts/map_workshop/workshop_local_assets.gd").new()
	_local_assets.workshop = self; _stage.add_child(_local_assets)
	_asset_button = Kit.button("导入自己的素材", "cream", 44, 20)
	_asset_button.name = "LocalAssetsButton"; _asset_button.position = Vector2(740, 256); _asset_button.custom_minimum_size.x = 220
	_asset_button.pressed.connect(func() -> void:
		panel.suspend_edits(); _end_landscape(); _end_placement(); _plant_tools.close_tools()
		if is_instance_valid(_piece_tools):_piece_tools.close_tools()
		if is_instance_valid(_intro_tools):_intro_tools.close_tools()
		_local_assets.open_tools())
	_stage.add_child(_asset_button)

func _open_plant_json_dialog(exporting: bool) -> void:
	if is_instance_valid(_plant_file_dialog): _plant_file_dialog.queue_free()
	_plant_file_dialog = FileDialog.new(); _plant_file_dialog.name = "PlantMapJSON"
	_plant_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_plant_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if exporting else FileDialog.FILE_MODE_OPEN_FILE
	_plant_file_dialog.filters = PackedStringArray(["*.json ; 地图 JSON"])
	_plant_file_dialog.title = "导出地图 JSON（含植物资源指纹）" if exporting else "导入地图 JSON"
	add_child(_plant_file_dialog)
	_plant_file_dialog.file_selected.connect(func(path: String) -> void:
		if exporting: export_plant_json(path)
		else: import_plant_json(path))
	_plant_file_dialog.popup_centered(Vector2i(850, 600))

func export_plant_json(path: String) -> Dictionary:
	var result: Dictionary = Backend.validate_for_editing(board.base_layout, doc.doc, board.geo, catalogue)
	if not result.ok: _reject_action(result, "plants"); return result
	var err := CustomMapStore.atomic_write(path, JSON.stringify(CustomMapSchema.round_coords(doc.doc), "  ", true) + "\n")
	say("地图 JSON 已导出；读取时会核对四种内置植物资源。" if err == OK else "地图 JSON 没有导出，当前稿未改变。")
	return {"ok": err == OK, "error": err}

func import_plant_json(path: String) -> Dictionary:
	var parsed := CustomMapValidator.parse_text(FileAccess.get_file_as_string(path))
	if not parsed.errors.is_empty(): _reject_action(parsed, "file"); return {"ok": false, "errors": parsed.errors}
	var result: Dictionary = Backend.validate_for_editing(board.base_layout, parsed.doc, board.geo, catalogue)
	if not result.ok: _reject_action(result, "file"); return result
	var go := func() -> void:
		# Recheck exact bytes/resources at commit, after any save/confirmation wait.
		var latest := CustomMapValidator.parse_text(FileAccess.get_file_as_string(path))
		if not latest.errors.is_empty() or Backend.sha256(latest.doc) != result.sha256:
			_reject_action({"reason": "地图文件已改变，请重新导入"}, "file"); return
		var checked: Dictionary = Backend.validate_for_editing(board.base_layout, latest.doc, board.geo, catalogue)
		if not checked.ok: _reject_action(checked, "file"); return
		_switch_doc(latest.doc, false)
	if doc.is_dirty() and not doc.is_untouched():
		dialogs.confirm("plant_json_dirty", "导入前保存当前地图？", "取消会保留当前稿；导入文件不改变贸易规则。", [{"id": "cancel", "text": "取消", "kind": "safe"}, {"id": "save", "text": "先保存", "kind": "middle"}], func(choice: String) -> void:
			if choice == "save": _save_then(go))
	else: go.call()
	return result

func _on_plant_requested(id: String, row: Dictionary, source_sha: String) -> void:
	if not _plant_tools.active or doc.sha() != source_sha:
		_plant_tools.reject("地图已改变，请重新选择植物")
		return
	var go := func() -> void:
		if not _plant_tools.active or doc.sha() != source_sha:
			_plant_tools.reject("地图已改变，旧修改没有应用")
			return
		var operation_started := Time.get_ticks_usec()
		var candidate: Dictionary = doc.doc.duplicate(true)
		var migrating := CustomMapSchema.schema_version_of(str(candidate.schema)) < 2
		if migrating:
			candidate.schema = CustomMapPlants.SCHEMA
			candidate.map_id = Backend.new_map_id()
		if not candidate.has("plants"):
			candidate.plants = CustomMapPlants.layer()
		var records: Dictionary = candidate.plants.instances
		if records.get(id) == row:
			_plant_tools.refresh(); return
		records[id] = row.duplicate(true)
		var validate_started := Time.get_ticks_usec()
		var result := Backend.validate(board.base_layout, candidate, board.geo, catalogue)
		plant_timings.append({"phase": "full_validate", "ms": (Time.get_ticks_usec() - validate_started) / 1000.0})
		if not result.ok:
			var errors: Array = result.errors
			var reason := str(errors[0].get("tech", errors[0].get("kid", "这里不能放"))) if not errors.is_empty() else "植物修改不能应用"
			_plant_tools.reject(reason); _reject_action(result, "plants." + id)
			return
		var before: Dictionary = doc.doc.duplicate(true)
		doc.doc = candidate; doc._touch()
		var commit_started := Time.get_ticks_usec()
		_commit(before, "创建 v2 副本并编辑植物" if migrating else "编辑单株植物", result)
		plant_timings.append({"phase": "commit_and_apply", "ms": (Time.get_ticks_usec() - commit_started) / 1000.0})
		_plant_tools.selected = id; _plant_tools.refresh()
		say("植物修改已应用，可撤销；原文件没有覆盖，原草稿保留在撤销记录中。" if migrating else "植物修改已应用，可以撤销。")
		plant_timings.append({"phase": "whole_successful_operation", "ms": (Time.get_ticks_usec() - operation_started) / 1000.0})
	if CustomMapSchema.schema_version_of(str(doc.doc.schema)) < 2:
		dialogs.confirm("plants_v2", "创建支持单株植物的副本？", "原 v1 地图保持不变。植物修改会写入新 v2 副本；旧版工坊不能读取。取消不改变地图。", [{"id": "cancel", "text": "取消", "kind": "safe"}, {"id": "copy", "text": "创建副本并应用", "kind": "middle"}], func(choice: String) -> void:
			if choice == "copy": go.call()
			else: _plant_tools.cancel_draft())
	else: go.call()

func _build_landscape_tools() -> void:
	_landscape_button = Kit.button("地形与树木", "cream", 52, 24)
	_landscape_button.name = "LandscapeToolsButton"
	_landscape_button.position = Vector2(24, 256)
	_landscape_button.custom_minimum_size.x = 220
	_landscape_button.pressed.connect(func() -> void:
		var opening := not _landscape_tools.visible
		if is_instance_valid(_piece_tools):_piece_tools.close_tools()
		if is_instance_valid(_intro_tools):_intro_tools.close_tools()
		if is_instance_valid(_local_assets): _local_assets.cancel(); _local_assets.hide()
		if is_instance_valid(_plant_tools): _plant_tools.close_tools(); panel.visible = true
		_commit_edits()
		_chooser.visible = false
		_landscape_tools.visible = opening)
	_stage.add_child(_landscape_button)
	_find_button = Kit.button("找个可放位置", "primary", 60, 26)
	_find_button.name = "FindPositionButton"
	_find_button.position = Vector2(344, 126)
	_find_button.custom_minimum_size.x = 258
	_find_button.visible = false
	_find_button.pressed.connect(_find_available_position)
	_stage.add_child(_find_button)
	_stop_search_button = Kit.button("停止寻找", "cream", 60, 26)
	_stop_search_button.name = "StopSearchButton"
	_stop_search_button.position = Vector2(622, 126)
	_stop_search_button.custom_minimum_size.x = 210
	_stop_search_button.visible = false
	_stop_search_button.pressed.connect(_stop_position_search)
	_stage.add_child(_stop_search_button)
	_landscape_tools = PanelContainer.new()
	_landscape_tools.name = "LandscapeTools"
	_landscape_tools.position = Vector2(24, 318)
	_landscape_tools.custom_minimum_size.x = 300
	_landscape_tools.add_theme_stylebox_override("panel", Kit.satchel_box(20, 4, 18))
	_landscape_tools.visible = false
	_stage.add_child(_landscape_tools)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_landscape_tools.add_child(col)
	col.add_child(Kit.label("给城市腾个地方", 26, Kit.SATCHEL_DEEP, "body", 700))
	for spec in [["flatten", "平整地形"], ["clear_trees", "清除树木"], ["plant_trees", "种树"]]:
		var b := Kit.button(str(spec[1]), "cream", 52, 24)
		b.name = "Brush_" + str(spec[0])
		b.toggle_mode = true
		b.pressed.connect(_set_landscape_tool.bind(str(spec[0])))
		_landscape_buttons[spec[0]] = b
		col.add_child(b)
	col.add_child(Kit.label("笔刷大小", 20, Kit.INK_SOFT))
	var sizes := HBoxContainer.new()
	sizes.add_theme_constant_override("separation", 8)
	var group := ButtonGroup.new()
	for spec in [["小", 2.0], ["中", 4.0], ["大", 6.0]]:
		var b := Kit.button(str(spec[0]), "cream", 46, 22)
		b.custom_minimum_size.x = 78
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = float(spec[1]) == _landscape_radius
		b.pressed.connect(func() -> void:
			_landscape_radius = float(spec[1])
			board.set_landscape_tool(_landscape_op, _landscape_radius))
		sizes.add_child(b)
	col.add_child(sizes)
	col.add_child(Kit.label("按住左键涂抹，松手应用\n右键拖地图 · ⌘Z 撤销", 19, Kit.INK_SOFT))
	var done := Kit.button("完成", "primary", 50, 24)
	done.pressed.connect(_end_landscape)
	col.add_child(done)


func _set_landscape_tool(op: String) -> void:
	if _landscape_busy or not op in ["flatten", "clear_trees", "plant_trees"]:
		return
	_commit_edits()
	_chooser.visible = false
	drawers.close()
	_landscape_op = op
	_landscape_tools.visible = true
	board.set_landscape_tool(op, _landscape_radius)
	for key: String in _landscape_buttons:
		(_landscape_buttons[key] as Button).set_pressed_no_signal(key == op)
	_refresh_find_button()
	say("%s：按住左键画，松手应用；Esc 取消这一笔。" % str((_landscape_buttons[op] as Button).text))


func _end_landscape() -> void:
	_landscape_op = ""
	if _landscape_tools != null:
		_landscape_tools.visible = false
	for button: Button in _landscape_buttons.values():
		button.set_pressed_no_signal(false)
	if board != null:
		board.set_landscape_tool("")
	_refresh_find_button()


func _on_landscape_stroke(points: Array, radius: float) -> void:
	if _landscape_op == "" or _landscape_busy or points.is_empty():
		return
	var op := _landscape_op
	var source_sha: String = doc.sha()
	var candidate: Dictionary = doc.doc.duplicate(true)
	_landscape_busy = true
	_show_wait(true)
	await get_tree().process_frame
	if doc.sha() != source_sha or _landscape_op != op:
		_landscape_busy = false
		_show_wait(false)
		return
	var failure := ""
	for point: Vector2 in points:
		var edit: Dictionary = Landscape.apply_edit(candidate, op, point, radius)
		if not bool(edit.get("ok", false)):
			failure = str(edit.get("message", "这里无法使用这个工具"))
			break
		candidate = edit.doc
		if candidate.has("plants") and op in ["clear_trees", "flatten"]:
			for row: Dictionary in candidate.plants.instances.values():
				if Vector2(float(row.x), float(row.z)).distance_to(point) <= radius: row.hidden = true
	if failure == "":
		var result := Mutations.finish(candidate, _base_content, board.base_layout, catalogue)
		if _accept_mutation(result, str((_landscape_buttons[op] as Button).text)):
			say("%s已应用，可以撤销；地形和树木会随地图一起保存。" % str((_landscape_buttons[op] as Button).text))
	else:
		_reject_action({"reason": failure + "；这一笔没有应用。"}, "landscape")
	_landscape_busy = false
	_show_wait(false)


func _clear_search() -> void:
	_cancel_connection(false)
	if _search_running or _placement_busy or not _search_spots.is_empty():
		_search_status = "cancelled"
	if _placement_busy:
		_placement_epoch += 1
		_placement_busy = false
		_show_wait(false)
	_search_epoch += 1
	_search_running = false
	_search_spots.clear()
	_search_kind = ""
	_search_city = ""
	_search_cursor = 0
	_search_phase = ""
	_search_limit_reason = ""
	if board != null:
		board.set_suggestions([], "")
	_refresh_find_button()


func _refresh_find_button() -> void:
	if _find_button == null:
		return
	_find_button.visible = not CustomMapFreeAuthor.enabled(doc.doc) and board != null and _landscape_op == "" and (board.placement_mode or str(board.sel.kind) == "city")
	_find_button.text = "正在找位置…" if _search_running and _search_spots.is_empty() else ("下一个位置" if not _search_spots.is_empty() else ("找可移动的位置" if board != null and not board.placement_mode else "找个可放位置"))
	if _stop_search_button != null:
		_stop_search_button.visible = _search_running


func _stop_position_search() -> void:
	_clear_action_issues()
	_clear_search()
	_search_status = "cancelled"
	say("已停止寻找；仍可手动放城，或再点「找个可放位置」。按 Esc 结束加城。" if board.placement_mode else "已停止寻找；仍可手动挪城，或再找一次位置。")


func _guide_obstacles() -> Array:
	var rectangles: Array = []
	if board == null:
		return rectangles
	var inverse: Transform2D = board.get_global_transform_with_canvas().affine_inverse()
	for control: Control in [_add_btn, _add_caption.get_parent(), _landscape_button, _find_button, _stop_search_button, _landscape_tools, _chooser]:
		if control.is_visible_in_tree():
			rectangles.append(inverse * control.get_global_rect().grow(6.0))
	return rectangles


func _find_available_position() -> void:
	if _search_running and _search_spots.is_empty():
		return
	if not _search_spots.is_empty():
		_search_cursor = (_search_cursor + 1) % _search_spots.size()
		var s: Dictionary = _search_spots[_search_cursor]
		board.focus_position(Vector2(float(s.x), float(s.z)))
		return
	if board.placement_mode:
		_start_position_search("place", "")
	elif str(board.sel.kind) == "city":
		_start_position_search("move", str(board.sel.id))


func _start_position_search(kind: String, cid: String) -> void:
	_clear_search()
	_search_kind = kind
	_search_city = cid
	_search_running = true
	_search_status = "searching"
	_search_phase = "geometry"
	_refresh_find_button()
	var epoch := _search_epoch
	var snapshot: Dictionary = doc.doc.duplicate(true)
	var source_sha: String = doc.sha()
	var transport := _placing_type
	var user_identity := _user_identity(snapshot)
	# Repeat searches may restore only previously fully validated pairs for this
	# exact document and city identity. Rebind them to this new task number.
	if kind == "place":
		for entry: Dictionary in _pair_cache.values():
			if str(entry.source_sha) != source_sha or str(entry.transport) != transport or str(entry.user_identity) != user_identity: continue
			var spot: Dictionary = entry.spot.duplicate(true)
			var pair: Dictionary = entry.result.duplicate(true)
			if not _pair_matches(pair, Vector2(float(spot.x), float(spot.z)), str(spot.host), transport): continue
			var distinct := true
			for previous: Dictionary in _search_spots:
				if Vector2(float(previous.x), float(previous.z)).distance_to(Vector2(float(spot.x), float(spot.z))) < 1.5: distinct = false
			if not distinct: continue
			spot["complete_pair"] = pair; spot["source_sha"] = source_sha; spot["transport"] = transport
			spot["user_identity"] = user_identity; spot["task_id"] = epoch
			_search_spots.append(spot)
			search_timings.append({"phase": "complete_candidate_cache_hit", "task_id": epoch, "ms": 0.0})
			if _search_spots.size() >= 4: break
		if not _search_spots.is_empty():
			board.set_suggestions(_search_spots, kind)
			board.focus_position(Vector2(float(_search_spots[0].x), float(_search_spots[0].z)))
			_search_running = false; _search_phase = ""; _search_status = "ready"; _refresh_find_button()
			say("找到啦！点大号圆点就能放城，也可以继续拖动探索。")
			return
	var lay: Dictionary = Backend.derive(board.base_layout, snapshot, board.geo)
	var sampler := CustomMapGeo.for_layout(lay)
	var jobs: Array = []
	if kind == "move":
		jobs.append(CustomMapGeoRules.move_search_begin(_base_content, board.base_layout, snapshot, cid, catalogue, sampler))
	else:
		var hosts: Array = CustomMapRules.legal_hosts(_base_content, snapshot, _placing_type, "")
		var center: Vector3 = board._target
		hosts.sort_custom(func(a: String, b: String) -> bool:
			var ca: Dictionary = board.city_state(a)
			var cb: Dictionary = board.city_state(b)
			return Vector2(float(ca.x) - center.x, float(ca.z) - center.z).length_squared() < Vector2(float(cb.x) - center.x, float(cb.z) - center.z).length_squared())
		for host: String in hosts:
			jobs.append(CustomMapGeoRules.placement_search_begin(lay, host, _placing_type, sampler))
	var search_started := Time.get_ticks_msec()
	var limit_reason := ""
	for state: Dictionary in jobs:
		var considered := 0
		var host_started := Time.get_ticks_msec()
		while (not bool(state.get("done", false)) or considered < (state.get("spots", []) as Array).size()) and _search_spots.size() < 4:
			_search_phase = "geometry"
			await get_tree().process_frame
			if not _search_is_current(epoch, source_sha):
				return
			if board.is_dragging() or _placement_busy:
				continue
			var step_started := Time.get_ticks_usec()
			var step_detail := str(state.get("phase", ""))
			if kind == "move":
				CustomMapGeoRules.move_search_step(state, sampler, 8.0, 1)
			else:
				CustomMapGeoRules.placement_search_step(state, sampler, 8.0, 1)
			search_timings.append({"phase": "geometry_search", "detail": step_detail, "host": state.get("host", ""), "task_id": epoch, "ms": (Time.get_ticks_usec() - step_started) / 1000.0})
			var spots: Array = state.get("spots", [])
			while considered < spots.size() and _search_spots.size() < 4:
				var spot: Dictionary = spots[considered]
				considered += 1
				var accepted := kind == "move"
				if kind == "place":
					await get_tree().process_frame
					if not _search_is_current(epoch, source_sha): return
					if Time.get_ticks_msec() - search_started > _search_total_budget_ms:
						limit_reason = "total"; break
					# A numbered marker holds a complete validated, immutable pair.
					var key := _candidate_key(source_sha, transport, user_identity, spot)
					var pair: Dictionary = _pair_cache.get(key, {}).get("result", {}).duplicate(true)
					if not _pair_matches(pair, Vector2(float(spot.x), float(spot.z)), str(spot.get("host", "")), transport):
						var task := Mutations.add_pair_begin(snapshot, _base_content, board.base_layout, catalogue, transport,
							Vector2(float(spot.x), float(spot.z)), str(spot.get("host", "")))
						while not bool(task.done):
							_search_phase = "pair_" + str(task.phase)
							await get_tree().process_frame
							if not _search_is_current(epoch, source_sha): return
							Mutations.add_pair_step(task)
							if Time.get_ticks_msec() - search_started > _search_total_budget_ms:
								limit_reason = "total"; break
						for timing: Dictionary in task.timings:
							search_timings.append({"phase": timing.phase, "detail": timing.get("detail", ""), "task_id": epoch, "ms": timing.ms})
						pair = task.result
						if bool(task.done) and _validated_pair(pair):
							if _pair_cache.size() >= 16: _pair_cache.clear()
							_pair_cache[key] = {"result": pair.duplicate(true), "spot": spot.duplicate(true), "source_sha": source_sha, "transport": transport, "user_identity": user_identity}
					else:
						search_timings.append({"phase": "complete_candidate_cache_hit", "task_id": epoch, "ms": 0.0})
					if not _search_is_current(epoch, source_sha): return
					accepted = _pair_matches(pair, Vector2(float(spot.x), float(spot.z)), str(spot.get("host", "")), transport)
					if not accepted: continue
					spot = spot.duplicate(true)
					spot["complete_pair"] = pair.duplicate(true)
					spot["task_id"] = epoch
					spot["source_sha"] = source_sha
					spot["transport"] = transport
					spot["user_identity"] = user_identity
				var distinct := true
				for prev: Dictionary in _search_spots:
					if Vector2(float(prev.x), float(prev.z)).distance_to(Vector2(float(spot.x), float(spot.z))) < (0.6 if kind == "move" else 1.5):
						distinct = false
				if distinct:
					_search_spots.append(spot)
					board.set_suggestions(_search_spots, kind)
					_refresh_find_button()
					if _search_spots.size() == 1:
						board.focus_position(Vector2(float(spot.x), float(spot.z)))
						say("找到啦！点大号圆点就能%s，也可以继续拖动探索。" % ("挪城" if kind == "move" else "放城"))
			if Time.get_ticks_msec() - search_started > _search_total_budget_ms:
				limit_reason = "total"; break
			if Time.get_ticks_msec() - host_started > _search_host_budget_ms:
				if not bool(state.get("done", false)) or considered < (state.get("spots", []) as Array).size(): limit_reason = "host"
				break
		if _search_spots.size() >= 4 or limit_reason == "total":
			break
	_finish_position_search(epoch, limit_reason)


func _finish_position_search(epoch: int, limit_reason: String) -> void:
	if epoch != _search_epoch or not is_inside_tree() or is_queued_for_deletion():
		return
	_search_running = false
	_search_phase = ""
	_search_limit_reason = limit_reason
	_search_status = ("exhausted" if limit_reason == "" else "budget_exhausted") if _search_spots.is_empty() else "ready"
	_refresh_find_button()
	if _search_spots.is_empty():
		if limit_reason == "total":
			say("本轮寻找的总时间预算已用完，还没找到通过完整检查的位置；可以再找一次或调整附近地形。")
		elif limit_reason == "host":
			say("部分连接城市的寻找时间预算已用完，本轮没找到通过完整检查的位置；可以再找一次。")
		else:
			say("本轮候选检查已完成，没找到通过完整检查的位置；这不代表所有位置都放不下，可以调整地形后再找。")


func _on_suggestion_selected(index: int) -> void:
	if index < 0 or index >= _search_spots.size():
		return
	var spot: Dictionary = _search_spots[index]
	if _search_kind == "place" and board.placement_mode:
		_on_place_requested(Vector2(float(spot.x), float(spot.z)), str(spot.get("host", "")), spot)
	elif _search_kind == "move" and str(board.sel.id) == _search_city:
		var cid := _search_city
		var at: Dictionary = board.city_state(cid)
		_on_city_moved(cid, float(spot.x), float(spot.z), float(spot.get("rotation", at.rotation)))


## 「这座城怎么去？」小挎包（3.12.5 第 1 步）：两个 200×180 的大按钮 + 一行小字「算了」
func _build_chooser() -> void:
	_chooser = PanelContainer.new()
	_chooser.add_theme_stylebox_override("panel", Kit.satchel_box(28, 5, 22))
	_chooser.position = Vector2(112, 250)
	_chooser.visible = false
	_stage.add_child(_chooser)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	_chooser.add_child(v)
	v.add_child(Kit.label("这座城怎么去？", 28, Kit.SATCHEL_DEEP, "body", 700))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	v.add_child(h)
	for spec in [["LAND", "骆驼去 · 陆地城", "icon_camel.png"], ["SEA", "商船去 · 海港城", "icon_ship.png"]]:
		var b := Button.new()
		b.custom_minimum_size = Vector2(200, 180)
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var n := StyleBoxFlat.new()
		n.bg_color = Color("#FFFDF7")
		n.border_color = Kit.SATCHEL.lightened(0.4)
		n.set_border_width_all(3)
		n.set_corner_radius_all(20)
		var hv := n.duplicate() as StyleBoxFlat
		hv.border_color = Kit.OCHRE
		b.add_theme_stylebox_override("normal", n)
		b.add_theme_stylebox_override("hover", hv)
		b.add_theme_stylebox_override("pressed", hv)
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var vb := VBoxContainer.new()
		vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(vb)
		var ic := TextureRect.new()
		ic.texture = load(SETUP_DIR + String(spec[2]))
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.custom_minimum_size = Vector2(0, 110)
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(ic)
		var l := Kit.label(String(spec[1]), 22, Kit.INK)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(l)
		b.pressed.connect(_on_transport_chosen.bind(String(spec[0])))
		h.add_child(b)
	var never := Button.new()
	never.text = "算了"
	never.flat = true
	never.focus_mode = Control.FOCUS_NONE
	never.add_theme_font_override("font", Kit.font("body", 600))
	never.add_theme_font_size_override("font_size", 22)
	never.add_theme_color_override("font_color", Kit.INK_SOFT)
	never.pressed.connect(func() -> void: _chooser.visible = false)
	v.add_child(never)


func _build_welcome() -> void:
	_welcome = Control.new()
	_welcome.size = STAGE
	_welcome.visible = false
	_welcome.mouse_filter = Control.MOUSE_FILTER_STOP
	_stage.add_child(_welcome)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.size = STAGE
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_welcome.add_child(dim)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", Kit.satchel_box(34, 5, 40))
	card.custom_minimum_size = Vector2(820, 0)
	card.name = "WelcomeCard"
	_welcome.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 22)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(v)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 18)
	v.add_child(h)
	var av := TextureRect.new()
	av.texture = Kit.icon("lshu_fullbody")
	av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	av.custom_minimum_size = Vector2(150, 190)
	h.add_child(av)
	var tv := VBoxContainer.new()
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(tv)
	tv.add_child(Kit.label("欢迎来到地图工坊！", 34, Kit.SATCHEL_DEEP, "body", 700))
	var sub := Kit.label("在这里可以把你的家乡加到《旅行L叔》的地图上，也可以把老城挪一挪。", 24, Kit.INK)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size = Vector2(560, 0)
	tv.add_child(sub)
	var rule_note := Kit.label("先放城，再连线，最后调整地形与植物。\n随时保存草稿；路线检查通过后可以试玩，自由作品平衡需试玩确认。", 20, Kit.INK_SOFT)
	rule_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rule_note.custom_minimum_size.x = 740
	v.add_child(rule_note)
	var go := Kit.button("自由创作 · 先放城，再连线", "primary", 88, 30)
	go.name = "NewMapButton"
	go.pressed.connect(_on_new_map)
	v.add_child(go)
	var compatible := Kit.button("原版兼容 · 在原地图上微调", "cream", 64, 24)
	compatible.name = "CompatibleMapButton"
	compatible.pressed.connect(_on_new_compatible_map)
	v.add_child(compatible)
	var st := HBoxContainer.new()
	st.name = "StatusRow"
	st.add_theme_constant_override("separation", 16)
	st.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(st)
	var status := Kit.label("", 22, Kit.INK_SOFT)
	status.name = "Status"
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	st.add_child(status)
	var back := Kit.button("让游戏用回原版", "cream", 56, 22)
	back.name = "UninstallButton"
	back.pressed.connect(_on_uninstall)
	st.add_child(back)


func _show_welcome() -> void:
	var status: Label = _welcome.find_child("Status", true, false)
	status.text = "游戏正在用：%s" % (_installed_name if _installed_name != "" else "原版地图")    # 只是状态文字，点了不做任何事
	(_welcome.find_child("UninstallButton", true, false) as Control).visible = _installed_name != ""
	_welcome.visible = true
	var card: Control = _welcome.find_child("WelcomeCard", true, false)
	card.reset_size()
	card.position = Vector2((BOARD_RECT.size.x - card.size.x) * 0.5, TOP_H + (BOARD_RECT.size.y - card.size.y) * 0.5 - 20)
	say(LINES.first)


func _build_wait() -> void:
	_wait = Control.new()
	_wait.size = STAGE
	_wait.mouse_filter = Control.MOUSE_FILTER_STOP
	_stage.add_child(_wait)
	var dim := ColorRect.new()
	dim.color = Kit.CREAM_DEEP
	dim.size = STAGE
	_wait.add_child(dim)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", Kit.satchel_box(34, 5, 40))
	card.position = Vector2(560, 360)
	card.custom_minimum_size = Vector2(800, 300)
	_wait.add_child(card)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 24)
	card.add_child(h)
	var av := TextureRect.new()
	av.texture = Kit.icon("lshu_fullbody")
	av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	av.custom_minimum_size = Vector2(160, 220)
	h.add_child(av)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(v)
	v.add_child(Kit.label("L叔在铺地图…", 34, Kit.SATCHEL_DEEP, "body", 700))
	var l := Kit.label("第一次打开要先画好 3D 地图，大约 1–2 分钟。", 24, Kit.INK)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(520, 0)
	v.add_child(l)


func _show_wait(on: bool) -> void:
	_wait.visible = on


## 设计分辨率：整屏按 k = min(宽/1920, 高/1080) 缩放、居中；棋盘放在舞台外（画布坐标，和游戏里一样大的名牌和标记）
func _layout() -> void:
	var vp := size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	_k = minf(vp.x / STAGE.x, vp.y / STAGE.y)
	var design_height := maxf(STAGE.y,vp.y/_k)
	_origin = Vector2((vp.x-STAGE.x*_k)*0.5,0)
	_stage.size=Vector2(STAGE.x,design_height)
	if _v02_shell != null:_v02_shell.fit_height(design_height);_v02_shell.readable_fonts(_stage)
	_stage.scale = Vector2(_k, _k)
	_stage.position = _origin
	if board != null:
		var rect: Rect2 = _v02_shell.board_rect() if _v02_shell != null else BOARD_RECT
		board.position = _origin + rect.position * _k
		board.size = rect.size * _k
		board.set_hud_safe_insets(0.0, 0.0)


## 舞台坐标（设计像素）→ 棋盘控件里的坐标（画布像素）
func stage_to_board(p: Vector2) -> Vector2:
	return (p - (_v02_shell.board_rect().position if _v02_shell != null else BOARD_RECT.position)) * _k


# ------------------------------------------------------------------ 文档 → 棋盘、面板、顶栏
func _apply_doc(schedule_autosave := true, validation: Dictionary = {}) -> void:
	if board != null: board.cancel_badge_drag()
	panel.set_draft_context(doc.map_id()) # Includes history/reset/save-as map identity changes.
	action_issues.clear()
	_clear_search()
	var apply_started := Time.get_ticks_usec()
	GameState.content = Backend.content_for(doc.doc)
	if is_instance_valid(_piece_tools) and _piece_tools.visible and _piece_tools.source_sha != doc.sha():_piece_tools.load_transport(_piece_tools.transport)
	if is_instance_valid(_intro_tools) and _intro_tools.visible and _intro_tools.source_sha != doc.sha():
		if CustomMapCityIntro.city_ids(doc.doc).has(_intro_tools.target_city):_intro_tools.load_city(_intro_tools.target_city)
		else:_intro_tools.close_tools()
	_measure_apply("content", apply_started)
	apply_started = Time.get_ticks_usec()
	board.cur_doc = doc.doc
	var lay: Dictionary = Backend.derive(board.base_layout, doc.doc, board.geo)
	_measure_apply("derive", apply_started)
	apply_started = Time.get_ticks_usec()
	board.show_layout(lay)
	_measure_apply("board_rebuild", apply_started)
	# 候选刚通过全量校验、且规范化 SHA 未变时复用同一结果；其余入口仍重新检查。
	# content_for 内部的 Loader.remember 仍独立校验，安装时也会再次校验。
	if bool(validation.get("ok", false)) and str(validation.get("sha256", "")) == doc.sha():
		issues = validation.get("errors", [])
		warnings = validation.get("warnings", [])
		_counts_win = bool(validation.get("counts_win", false))
	else:
		_revalidate()
	_refresh_top()
	_refresh_panel()
	_refresh_find_button()
	_remember_last_map()
	if schedule_autosave:
		if doc.is_dirty() and not doc.is_untouched():
			_autosave_timer.start()
		else:
			_autosave_timer.stop()
			# 撤销回已存版本后，可能立刻关窗；不能等一秒后才退役旧自动稿。
			_autosave_current()


func _autosave_current() -> bool:
	if doc.is_dirty() and not doc.is_untouched():
		return Backend.autosave(doc.doc) == OK
	var old := CustomMapStore.read_autosave(doc.map_id())
	var saved := CustomMapStore.load_map(doc.map_id())
	if Backend.sha256(saved) == doc.sha() and CustomMapStore.is_superseded_autosave(doc.map_id(), old, saved):
		return true # The committed library identity already retired this exact disk draft.
	if not old.is_empty() and Backend.sha256(old) != doc.sha():
		if CustomMapStore.trash_doc(old, "unsaved") != OK:
			return false
	return CustomMapStore.clear_autosave(doc.map_id()) == OK


## maps/workshop_state.json 记下现在开着的是哪张图（下次启动的第 2 条规则，3.12.2）
func _remember_last_map() -> void:
	var id: String = doc.map_id()
	if id == _state_map_id:
		return
	if Backend.write_workshop_state({"last_map_id": id}) == OK:
		_state_map_id = id


## 换成另一张图（打开、启动提示点了「不要了」）：撤销栈清空、选中清空。d 为空 = 一张新地图。
## WP3 之后布局变了就整体重建世界（3.12.7：只在「打开另一张图」时做，显示 L叔 等待卡）；之前就地摆
func _switch_doc(d: Dictionary, saved: bool, saved_sha := "") -> void:
	if board != null: board.cancel_badge_drag()
	if is_instance_valid(_piece_tools):_piece_tools.close_tools()
	if is_instance_valid(_intro_tools):_intro_tools.close_tools()
	if is_instance_valid(_local_assets): _local_assets.cancel(); _local_assets.hide()
	if is_instance_valid(_plant_tools): _plant_tools.close_tools()
	_autosave_timer.stop()
	_end_placement()
	panel.clear_text_drafts()
	if d.is_empty():
		doc.new_map("新地图")
	else:
		doc.open(d, saved, saved_sha)
	history.clear()
	board.select("", "")
	GameState.content = Backend.content_for(doc.doc)
	if is_instance_valid(_piece_tools) and _piece_tools.visible and _piece_tools.source_sha != doc.sha():_piece_tools.load_transport(_piece_tools.transport)
	if is_instance_valid(_intro_tools) and _intro_tools.visible and _intro_tools.source_sha != doc.sha():
		if CustomMapCityIntro.city_ids(doc.doc).has(_intro_tools.target_city):_intro_tools.load_city(_intro_tools.target_city)
		else:_intro_tools.close_tools()
	var lay: Dictionary = Backend.boot_layout(board.base_layout, doc.doc)
	if Backend.WP3_READY and board.has_method("rebuild_world_with_layout") and not (lay.is_empty() and is_same(board.cur_layout, board.base_layout)):
		_show_wait(true)
		await get_tree().process_frame
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
		board.call("rebuild_world_with_layout", lay)
		_show_wait(false)
	_apply_doc(false)


## 记一步撤销，然后刷新（内容没变的不进栈）
func _commit(before: Dictionary, label: String, validation: Dictionary = {}) -> void:
	history.record(before, doc.doc, label)
	_apply_doc(true, validation)


func _revalidate() -> void:
	var r: Dictionary = Backend.validate(board.base_layout, doc.doc, board.geo, catalogue)
	issues = r.get("errors", [])
	warnings = r.get("warnings", [])
	_counts_win = bool(r.get("counts_win", false))


func _refresh_top() -> void:
	var text: String = doc.map_name()
	if doc.is_dirty():
		text += " · 未保存"
	elif doc.installed_sha != "" and doc.installed_sha == doc.sha():
		text += " · 已装进游戏"
	_name_pill.text = text
	(_btn.undo as Button).disabled = not history.can_undo()
	(_btn.redo as Button).disabled = not history.can_redo()
	(_btn.undo as Button).tooltip_text = "撤销最近一次修改" if history.can_undo() else "还没有可撤销的修改"
	(_btn.redo as Button).tooltip_text = "重做刚撤销的修改" if history.can_redo() else "没有待重做的修改"
	var imp: Button = _btn["import"]
	imp.disabled = not issues.is_empty()
	imp.tooltip_text = "" if issues.is_empty() else "还有 %d 个问题要先修好" % issues.size()
	_playtest_button.disabled = not issues.is_empty() or _playtest.pid > 0
	_playtest_button.text = "试玩" if issues.is_empty() else "先修 %d 处" % issues.size()
	_playtest_button.tooltip_text = "保存并开始独立试玩" if issues.is_empty() else "先修好地图问题，草稿仍可保存"
	var capacity:int=CustomMapFreeAuthor.MAX_CITIES if CustomMapFreeAuthor.enabled(doc.doc) else Backend.MAX_USER
	var left: int = capacity - int(doc.user_city_count())
	_add_btn.disabled = left <= 0
	_add_btn.tooltip_text = "新增城市" if left > 0 else "已达到新增城市上限"
	_add_caption.text = "新城 %d/4"%doc.new_city_count() if CustomMapFreeAuthor.enabled(doc.doc) else ("还能加 %d 座" % left if left > 0 else "最多自己加 %d 座（另一边是系统补的搭档）" % Backend.MAX_USER)
	if CustomMapFreeAuthor.enabled(doc.doc):
		_add_btn.tooltip_text="自由放城 · 新城 %d/4"%doc.new_city_count()
		_playtest_button.disabled=_playtest.pid>0
		imp.disabled=false


func _refresh_panel() -> void:
	if is_instance_valid(_plant_tools) and _plant_tools.active:
		panel.visible = false; _plant_tools.refresh(); return
	panel.visible = true
	var s: Dictionary = board.sel
	match String(s.kind):
		"city":
			_show_city_panel(String(s.id))
			_show_badge_panel(String(s.id))
		"route":
			panel.show_route(_route_info(String(s.id)))
		"stop":
			panel.show_stop(_stop_info(String(s.id)))
		_:
			var names := {}
			for cid in doc.home:
				names[cid] = _display_name(String(cid))
			var rows: Array = []
			var deleted_routes:Array=[]
			if CustomMapFreeRoutes.enabled(doc.doc):
				var definitions:=CustomMapFreeRoutes.specs(_base_content,CustomMapFreeAuthor.base_doc(doc.doc) if CustomMapFreeAuthor.enabled(doc.doc) else CustomMapFreeRoutes.clean(doc.doc))
				for rid:String in doc.doc.free_routes.routes:
					if doc.doc.free_routes.routes[rid].get("deleted",false):
						var r:Dictionary=definitions.get(rid,{}).duplicate(true);r.merge(doc.doc.free_routes.routes[rid],true)
						deleted_routes.append({"id":rid,"label":_display_name(str(r.a))+" — "+_display_name(str(r.b))})
			var east := 0
			for c: Dictionary in doc.doc.get("new_cities", []):
				if CustomMapFreeAuthor.enabled(doc.doc):
					rows.append({"id":"x_"+str(c.slot),"name":str(c.name),"side":"自由城市","partner":_connection_host_names(c)})
					continue
				var side := CustomMapRules.side_of_host(_base_content, str(c.get("host","")))
				east += int(side == "E")
				rows.append({"id": "x_" + str(c.slot), "name": str(c.name), "side": "东边" if side == "E" else "西边", "partner": _display_name("x_" + str(c.get("partner","")))})
			panel.show_map({"author_mode":CustomMapFreeAuthor.enabled(doc.doc),"east": east, "west": rows.size() - east, "rows": rows, "issues": _problem_rows(issues, "error", "map"),
				"deleted_routes":deleted_routes,
				"warnings": _problem_rows(warnings, "warning", "map"), "action_issues": _problem_rows(action_issues, "error", "action"), "counts_win": _counts_win,
				"tradegen": doc.doc.get("tradegen", ""), "edits": doc.edits_summary(names), "can_reset_all": not doc.moves().is_empty()})

	_refresh_object_feedback()
	if _v02_shell != null: _v02_shell.readable_fonts(panel)


func _problem_rows(source: Array, level: String, scope: String) -> Array:
	var rows: Array = []
	for original: Dictionary in source:
		var row := original.duplicate(true)
		row.level = level
		row.scope = scope
		row.locatable = not _issue_location(row).is_empty()
		row.issue_index = issues.find(original)
		if str(row.get("code",""))=="E_FREE_DISCONNECTED":row.pending=true
		if str(row.get("code",""))=="E_FREE_TRANSPORT":
			row.kid = "%s不支持%s" % [_display_name(str(row.get("endpoint_city","城市"))),"陆路" if str(row.get("medium","LAND"))=="LAND" else "海路"]
		rows.append(row)
	return rows


## Resolve only actual current-layout objects. Schema/global fields have no camera target.
func _resolve_problem_target(raw: String) -> Dictionary:
	var target := raw
	var wanted := ""
	for prefix in ["moves.cities.", "moves.city.", "moves.routes.", "moves.route.", "moves.stops.", "moves.stop.", "city:", "route:", "corridor:", "stop:"]:
		if target.begins_with(prefix):
			wanted = "route" if prefix.contains("route") or prefix == "corridor:" else ("stop" if prefix.contains("stop") else "city")
			target = target.trim_prefix(prefix).get_slice(".", 0)
			break
	if wanted == "":
		# Numeric/type/name validator errors can address a slot's property.
		target = target.get_slice(".", 0)
		for c: Dictionary in doc.doc.get("new_cities", []):
			if target == String(c.slot):
				target = "x_" + target
				break
	for entry: Dictionary in board.cur_layout.get("cities", []):
		if wanted in ["", "city"] and String(entry.id) == target:
			return {"kind": "city", "id": target, "anchor": Vector2(float(entry.x), float(entry.z))}
	for entry: Dictionary in board.cur_layout.get("stops", []):
		if wanted in ["", "stop"] and String(entry.id) == target:
			return {"kind": "stop", "id": target, "anchor": Vector2(float(entry.x), float(entry.z))}
	var route := _layout_route(target)
	if wanted in ["", "route"] and not route.is_empty():
		var points: Array = route.get("points", [])
		var length := 0.0
		for i in range(1, points.size()):
			length += Vector2(float(points[i][0]), float(points[i][2])).distance_to(Vector2(float(points[i - 1][0]), float(points[i - 1][2])))
		var remaining := length * 0.5
		for i in range(1, points.size()):
			var start := Vector2(float(points[i - 1][0]), float(points[i - 1][2]))
			var end := Vector2(float(points[i][0]), float(points[i][2]))
			var segment := start.distance_to(end)
			if remaining <= segment and segment > 0.0:
				return {"kind": "route", "id": target, "anchor": start.lerp(end, remaining / segment)}
			remaining -= segment
	return {}


func _action_reason(result:Dictionary)->String:
	var reason:=str(result.get("reason",""))
	if reason!="":return reason
	for issue:Dictionary in result.get("errors",[]):
		for field:String in ["kid","tech"]:
			if str(issue.get(field,""))!="":return str(issue[field])
	return str(result.get("detail","")) if str(result.get("detail",""))!="" else "这次修改不能保存"


func _reject_action(result: Dictionary, target: String) -> void:
	var reason := _action_reason(result)
	action_issues = result.get("errors", []).duplicate(true)
	for issue:Dictionary in action_issues:
		if str(issue.get("kid",""))=="":issue.kid=reason
	if action_issues.is_empty():
		action_issues.append({"code": "ACTION_REJECTED", "target": target, "kid": reason, "tech": String(result.get("detail", ""))})
	say(reason)
	if panel.kind == "map":
		_refresh_panel()


func _clear_action_issues() -> void:
	if action_issues.is_empty():
		return
	action_issues.clear()
	if panel.kind == "map":
		_refresh_panel()


func _show_city_panel(cid: String) -> void:
	if cid.begins_with("x_"):
		_show_new_city_panel(cid)
		return
	var p: Dictionary = doc.city_pos(cid)
	var live := {"id": cid, "x": float(p.x), "z": float(p.z), "rotation": float(p.rotation), "moved": doc.is_moved(cid),"author_mode":CustomMapFreeAuthor.enabled(doc.doc),"transport_override":doc.doc.get("transport_overrides",{}).has(cid)}
	if panel.shows("city", cid):
		panel.update_original_name(_display_name(cid))
		panel.update_original_city(live)          # 还是这座城：就地换数值，正拿着焦点的框不拆（Tab 能跳到下一个框）
		return
	var content: Dictionary = GameState.content
	var city: Dictionary = content.get("cities", {}).get(cid, {})
	var card: Dictionary = content.get("city_cards", {}).get(String(city.get("city_card_id", cid)), {})
	var good_id := ""
	for e: Dictionary in card.get("starting_grant", {}).get("entries", []):
		if String(e.get("resource_kind", "")) == "GOOD":
			good_id = String(e.get("resource_id", ""))
			break
	live.merge({
		"name": _display_name(cid), "transport": String(city.get("starting_transport", "CAMEL")),
		"side": "西边" if _side(cid) == "W" else "东边",
		"specialty": GameData.get_good_name(content, good_id) if good_id != "" else "—",
		"author_mode":CustomMapFreeAuthor.enabled(doc.doc),"transport_override":doc.doc.get("transport_overrides",{}).has(cid),
		"connections": _city_connection_names(cid),
		"specialty_icon": LshuIcons.good(good_id, content) if good_id != "" else null,
	})
	panel.show_original_city(live, content)
	panel.set_text_validator("name", func(value: String) -> String: return Mutations.city_name_problem(doc.doc, cid, value, _base_content))
	panel.set_validator("x", func(v: float) -> String: return _field_reason(cid, v, float(doc.city_pos(cid).z), float(doc.city_pos(cid).rotation)))
	panel.set_validator("z", func(v: float) -> String: return _field_reason(cid, float(doc.city_pos(cid).x), v, float(doc.city_pos(cid).rotation)))
	panel.set_validator("rotation", func(v: float) -> String: return _field_reason(cid, float(doc.city_pos(cid).x), float(doc.city_pos(cid).z), deg_to_rad(v)))


## 数字框输入合不合格：和拖动同一套几何检查（R27）
func _field_reason(cid: String, x: float, z: float, rot: float) -> String:
	if CustomMapFreeAuthor.enabled(doc.doc) and cid.begins_with("x_"):
		return "位置必须在棋盘范围内" if not is_finite(x) or not is_finite(z) or not is_finite(rot) or x<0 or x>128 or z<0 or z>59.63125 else ""
	var h: Dictionary = doc.home.get(cid, {})
	if not h.is_empty():
		if Vector2(x - float(h.x), z - float(h.z)).length() > Backend.R_MOVE + 0.0005 or absf(rot - float(h.get("rotation", 0.0))) > Backend.YAW_MAX + 0.0005:
			return Backend.kid_text("G_MOVE_FAR", _display_name(cid))
	var lay: Dictionary = board.derived_with(cid, {"x": x, "z": z, "rotation": rot})
	var errs: Array[Dictionary] = Backend.check_city(lay, cid, board.geo, false)
	return String(errs[0].kid) if not errs.is_empty() else ""


func _side(cid: String) -> String:
	if CustomMapFreeAuthor.enabled(doc.doc):return "W" if float(doc.city_pos(cid).x)<64 else "E"
	if Backend.WP1_READY:
		var c := Mutations.city(doc.doc, cid)
		return CustomMapRules.side_of_host(_base_content, str(c.get("host", cid)))
	# STUB：棋盘东西两半（正式 4096 宽的逻辑坐标里 x < 2048 = 西，3D 里约 x < 64）
	return "W" if float(doc.home.get(cid, {}).get("x", 64.0)) < 64.0 else "E"


func _display_name(cid: String) -> String:
	return String(GameState.content.get("cities", {}).get(cid, {}).get("display_name", cid))


## 路线的只读信息：直接从现在画着的推导布局里算（工坊不重建 Paths，见 workshop_board.gd 文件头）
func _route_info(rid: String) -> Dictionary:
	var r := _layout_route(rid)
	var base_ends:Array=board.geo.ends.get(rid,["",""])
	var e: Array = [str(r.get("a",base_ends[0])),str(r.get("b",base_ends[1]))]
	var pts: Array = r.get("points", [])
	var length := 0.0
	for i in range(1, pts.size()):
		length += Vector2(float(pts[i][0]) - float(pts[i - 1][0]), float(pts[i][2]) - float(pts[i - 1][2])).length()
	return {"id": rid, "a": _display_name(String(e[0])), "b": _display_name(String(e[1])), "type": String(r.get("type", "LAND")),
		"length": length,"steps":board.paths.routes.get(rid,{}).get("stop_s",{}).size()+1}


## 停靠点：「长安—玉门关 · 第 1 站」和它在这条路上的位置比例（按路线上离它最近的点算弧长）
func _stop_info(sid: String) -> Dictionary:
	var rid := sid.substr(0, sid.rfind("_"))
	var info := _route_info(rid)
	var pts: Array = _layout_route(rid).get("points", [])
	var at := Vector2.ZERO
	for st: Dictionary in board.cur_layout.get("stops", []):
		if String(st.id) == sid:
			at = Vector2(float(st.x), float(st.z))
	var acc := 0.0
	var best := 0.0
	var bd := INF
	for i in pts.size():
		if i > 0:
			acc += Vector2(float(pts[i][0]) - float(pts[i - 1][0]), float(pts[i][2]) - float(pts[i - 1][2])).length()
		var d := Vector2(float(pts[i][0]), float(pts[i][2])).distance_squared_to(at)
		if d < bd:
			bd = d
			best = acc
	return {"id": sid, "a": info.a, "b": info.b, "index": int(sid.get_slice("_", sid.get_slice_count("_") - 1)),
		"t": best / maxf(float(info.length), 0.001)}


func _layout_route(rid: String) -> Dictionary:
	for r: Dictionary in board.cur_layout.get("routes", []):
		if String(r.id) == rid:
			return r
	return {}


# ------------------------------------------------------------------ 棋盘事件
func _on_selection_changed(kind: String, id: String) -> void:
	if CustomMapFreeAuthor.enabled(doc.doc) and is_instance_valid(_connection_ui) and kind=="city" and id!=_connection_city:
		for i:int in _connection_targets.item_count:
			if str(_connection_targets.get_item_metadata(i))==id:
				_connection_targets.select(i);_preview_selected_connection();return
	_clear_search()
	_refresh_find_button()
	if drawers.is_open() and id != _drawer_city:
		drawers.close()
	# 换了选中的对象：输入框先提交（离开即生效）
	get_viewport().gui_release_focus()
	_refresh_panel()
	if kind == "city" and doc.home.has(id):
		say(LINES.city_selected)
	elif kind == "":
		say(LINES.idle)


func _on_city_moved(cid: String, x: float, z: float, rotation: float) -> void:
	var candidate: Dictionary = Doc.with_city(doc.doc, doc.home, cid, x, z, rotation)
	_accept_mutation(Mutations.finish(candidate, _base_content, board.base_layout, catalogue), "挪%s" % _display_name(cid))


func _on_drag_changed(st: Dictionary) -> void:
	if String(st.get("cid", "")) == "":
		return
	panel.show_live(float(st.x), float(st.z), float(st.rotation))


## 数字框提交：落在建这个框时的那座城上（换选中时旧框的字不会打到新选中的城上）
func _on_field(cid: String, field: String, value: float) -> void:
	if field.begins_with("badge_"):
		var offset := _current_badge_offset(cid)
		if field == "badge_x": offset.x = value
		else: offset.y = value
		_accept_badge(Mutations.change_badge(doc.doc,cid,"offset_px",[offset.x,offset.y],_base_content,board.base_layout,catalogue),"调整名牌位置")
		return
	if cid.begins_with("x_"):
		var result: Dictionary
		if field == "size":
			result = Mutations.change_city(doc.doc, cid, field, value, _base_content, board.base_layout, catalogue)
		else:
			var at: Dictionary = doc.city_pos(cid)
			at[field] = value
			result = Mutations.finish(Doc.with_city(doc.doc, doc.home, cid, at.x, at.z, at.rotation), _base_content, board.base_layout, catalogue)
		_accept_mutation(result, "改%s的数字" % _display_name(cid))
		return
	if not doc.home.has(cid):
		return
	var p: Dictionary = doc.city_pos(cid)
	p[field] = value
	var before: Dictionary = doc.set_city(cid, float(p.x), float(p.z), float(p.rotation))
	_commit(before, "改%s的数字" % _display_name(cid))


func _on_panel_action(name: String) -> void:
	if name.begins_with("issue:"):
		var i := int(name.trim_prefix("issue:"))
		if i>=0 and i<issues.size(): _locate_issue(issues[i])
		return
	if name.begins_with("fix_medium:"):
		var parts := name.split(":");_repair_route_medium(str(parts[1]),str(parts[2]));return
	if name.begins_with("fix_transport:"):
		if CustomMapFreeAuthor.enabled(doc.doc): _accept_mutation(CustomMapFreeAuthor.transport(doc.doc,name.trim_prefix("fix_transport:"),_base_content,board.base_layout,catalogue),"增开海陆交通并换乘")
		return
	if name.begins_with("badge_icon:"):
		var parts := name.split(":")
		if int(parts[2]) == 5: _open_badge_import(str(parts[1]))
		else: _accept_badge(Mutations.change_badge(doc.doc,str(parts[1]),"icon",CustomMapCityBadges.ICONS[int(parts[2])],_base_content,board.base_layout,catalogue),"换名牌显示图标")
		return
	if name == "badge_import":
		_open_badge_import(str(panel.target)); return
	if name == "badge_reset":
		_accept_badge(Mutations.change_badge(doc.doc,str(panel.target),"mode","AUTO",_base_content,board.base_layout,catalogue),"名牌恢复自动位置"); return
	if name.begins_with("route_") and _route_editor != null:
		_route_editor.action(name)
		return
	if name.begins_with("goto:"):
		var location := _resolve_problem_target(name.trim_prefix("goto:"))
		if not location.is_empty():
			# Locating is read-only; keep name drafts until repair or explicit cancel.
			panel.suspend_edits()
			board.select(String(location.kind), String(location.id))
			board.focus_position(location.anchor)
			panel.locate_problem(name.trim_prefix("goto:"))
		return
	_commit_edits()
	match name:
		"upgrade_rules":
			var tool := preload("res://scripts/map_workshop/workshop_rule_versions.gd").new()
			tool.workshop = self
			_stage.add_child(tool)
		"remove_connection":
			if CustomMapFreeRoutes.enabled(doc.doc):_route_editor.city_routes(str(panel.target),true);return
			var cid := str(panel.target)
			dialogs.confirm("remove_connection", "移除额外连接？", "主连接与两座搭档城保留。规则距离改变时会重新生成新增贸易卡，可撤销。", [{"id": "cancel", "text": "取消", "kind": "safe"}, {"id": "remove", "text": "移除连接", "kind": "danger"}], func(ch: String) -> void:
				if ch == "remove": _accept_mutation(Mutations.remove_connection(doc.doc, cid, _base_content, board.base_layout, catalogue), "移除额外连接"))
		"enable_transport":
			_accept_mutation(CustomMapFreeAuthor.transport(doc.doc,str(panel.target),_base_content,board.base_layout,catalogue),"增开原城交通并换乘")
		"author_connect":
			_open_connection(str(panel.target))
		"extra_connection":
			if CustomMapFreeAuthor.enabled(doc.doc):_open_connection(str(panel.target));return
			if CustomMapFreeRoutes.enabled(doc.doc):_route_editor.city_routes(str(panel.target))
			else:_open_connection(str(panel.target))
		"change_look", "change_good":
			var c := Mutations.city(doc.doc, str(panel.target))
			if not c.is_empty():
				open_drawer("look" if name == "change_look" else "goods", str(c.get("route_type","LAND")), _side(str(panel.target)))
		"remove_pair":
			_ask_remove_pair(str(panel.target))
		"reset_text":
			_accept_mutation(Mutations.change_city(doc.doc, str(panel.target), "text", {"mode": "AUTO"}, _base_content, board.base_layout, catalogue), "恢复城市介绍")
		"reset_city":
			if panel.kind != "city" or not doc.home.has(panel.target):
				return
			var cid: String = panel.target
			_commit(doc.reset_city(cid), "%s放回原处" % _display_name(cid))
		"reset_all":
			dialogs.confirm("reset_all", "把挪过的老城、改过的路都放回原处？", "加的新城不受影响。可以按「撤销」找回来。",
				[{"id": "cancel", "text": "再想想", "kind": "safe"}, {"id": "reset", "text": "放回原处", "kind": "danger"}],
				func(ch: String) -> void:
					if ch == "reset":
						_commit(doc.reset_all_originals(), "全部放回原处"))


func _on_card_enlarge(cid: String) -> void:
	_commit_edits()
	for c in _enlarge.get_children():
		c.queue_free()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.size = STAGE
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_enlarge.add_child(dim)
	var card: Control = preload("res://scenes/ui/components/formal_city_card.tscn").instantiate()
	card.custom_minimum_size = Vector2(673, 898)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_enlarge.add_child(card)
	card.size = Vector2(673, 898)                # 0.62 倍
	card.position = (STAGE - card.size) * 0.5
	card.call("bind_resolved", FormalCardPresentationResolver.resolve_city_card(GameState.content, cid), GameState.content)
	_enlarge.visible = true


# ------------------------------------------------------------------ 键盘（3.12.3「输入框和快捷键」）
func _input(event: InputEvent) -> void:
	if not _ready_done:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_commit_before_click(event as InputEventMouseButton)
		return
	if event is InputEventKey:
		if _route_editor != null and _route_editor.key_event(event):
			get_viewport().set_input_as_handled();return
		var k := event as InputEventKey
		if k.keycode in [KEY_META, KEY_CTRL]:
			if k.pressed and get_viewport().gui_get_focus_owner() == null:
				_key_sink.grab_focus()
			elif not k.pressed and get_viewport().gui_get_focus_owner() == _key_sink:
				_key_sink.release_focus()
			return
	if not event.is_pressed() or event.is_echo():
		return
	# ⇧⌘Z 也能匹配上 ui_undo（多出来的修饰键不算），所以先看重做
	var is_redo := event.is_action_pressed("ui_redo")
	if is_redo or event.is_action_pressed("ui_undo"):
		# 只有焦点在一个正在编辑、且有没提交改动的输入框里时，才让给输入框（撤销框里的字）；其它时候都是地图的撤销 / 重做
		if dialogs.is_open() or library.is_open():
			return
		if panel.has_uncommitted_edit():
			return
		if is_redo:
			_on_redo()
		else:
			_on_undo()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and (event as InputEventKey).keycode == KEY_S and (event as InputEventKey).is_command_or_control_pressed():
		if not dialogs.is_open():
			get_viewport().gui_release_focus()
			_on_save()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel"):
		if board.cancel_badge_drag():
			get_viewport().set_input_as_handled(); return
		if panel.has_ime_composition():
			return # Let the IME consume Esc for its composition first.
		_on_escape()
		get_viewport().set_input_as_handled()


## 离开即生效（3.12.3）：点到正在编辑的数字框以外的任何地方，先提交再让那一下生效。顶栏、面板、卡片区的按钮都不抢焦点
## （Kit 按钮是 FOCUS_NONE），点它们时输入框自己不会失焦，所以在这里（早于任何控件）统一提交。
## 例外：点的是这个框自己（含 ▲▼，由它自己处理）；点「撤销」「重做」按钮（照 ⌘Z 的规则：只撤框里的字，见 _on_undo）
func _commit_before_click(mb: InputEventMouseButton) -> void:
	if not (mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]):
		return
	var hovered: Control = get_viewport().gui_get_hovered_control()
	while hovered != null:
		if bool(hovered.get_meta("readonly_location", false)) and hovered.get_global_rect().has_point(mb.position):
			panel.suspend_edits()
			return
		hovered = hovered.get_parent() as Control
	var f: Control = panel.editing_field()
	if f == null or f.get_global_rect().has_point(mb.position):
		return
	for k in ["undo", "redo"]:
		var b: Button = _btn[k]
		if not b.disabled and b.is_visible_in_tree() and b.get_global_rect().has_point(mb.position):
			return
	get_viewport().gui_release_focus()


## 改文档、开框、换图之前先提交输入框（从代码里直接调这些入口时也一样，不只靠上面的点击）
func _commit_edits() -> void:
	if board != null: board.cancel_badge_drag()
	if _route_editor != null:
		if _route_editor.cancel_drag():say("这次路线拖动已取消，地图没有改动。")
		_route_editor.adding=false
	if _landscape_op != "":
		_end_landscape()
	_clear_search()
	if board != null and (board.placement_mode or _placement_busy):
		_end_placement()
	get_viewport().gui_release_focus()


## Esc 一次到位：确认框 = 安全选项；输入框正在编辑 → 丢掉没提交的字、结束编辑，同一下执行对应的含义；
## 拖动中 → 回到按下之前；放城 / 选交通 → 退出；抽屉 → 收起；其它时候 = 取消选择
func _on_escape() -> void:
	if _route_editor != null and _route_editor.cancel_drag():
		say("已取消路线拖动。")
		return
	if panel.has_ime_composition():
		return
	_clear_action_issues()
	if is_instance_valid(_connection_ui):
		_cancel_connection()
		return
	if dialogs.is_open():
		dialogs.press_safe()
		return
	if is_instance_valid(_plant_tools) and _plant_tools.active:
		_plant_tools.cancel_draft(); say("植物草稿已取消，地图未变；结束按钮可收起工具。")
		return
	var editing: bool = panel.editing_field() != null
	if editing:
		panel.discard_edits()
	if board.cancel_landscape_stroke():
		say("这一笔没有应用；可以继续画，或再按 Esc 收起工具。")
		return
	if _landscape_op != "" or _landscape_tools.visible:
		_end_landscape()
		return
	if board.cancel_drag():
		return
	if board.placement_mode or _placement_busy or _placing_type != "":
		_end_placement()
		say(LINES.idle)
		return
	if _chooser.visible:
		_chooser.visible = false
		return
	if drawers.is_open():
		drawers.close()
		return
	if _enlarge.visible:
		_enlarge.visible = false
		return
	if library.is_open():
		library.close()
		return
	if not editing and not _welcome.visible:
		board.select("", "")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_close_requested()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT and _key_sink != null and get_viewport().gui_get_focus_owner() == _key_sink:
		_key_sink.release_focus()


## 关窗口：有没保存的改动时拦下来问（【再想想】= 不关；【不保存】先把当前文档写进 trash/，再关）
func _on_close_requested() -> void:
	if is_instance_valid(_playtest) and _playtest.pid > 0: _playtest.stop()
	_commit_edits()
	# 没改过 = 存过的那一版原样没动，或者新建（重置）出来一下都没碰过；按内容 sha 比，不按「挪过几座城」数
	if doc == null or not doc.is_dirty() or doc.is_untouched():
		_quit()
		return
	dialogs.confirm("close", "要先保存吗？", "「%s」还有没保存的改动。" % doc.map_name(),
		[{"id": "cancel", "text": "再想想", "kind": "safe"}, {"id": "save", "text": "先保存", "kind": "middle"}, {"id": "discard", "text": "不保存", "kind": "danger"}],
		func(ch: String) -> void:
			if ch == "save":
				_save_then(_quit)
			elif ch == "discard":
				# 第一阶段（WP1 之前）store 是骨架：放不进 trash/，也存不了；不放行的话有改动时窗口永远关不掉，所以只在这时直接关
				if _discard_to_trash() or not Backend.WP1_READY:
					_quit())


## 测试用：设了就不真退出（冒烟测试里一个误放行的「不保存」会让整个测试进程带着退出码 0 静悄悄地结束）
var test_quit := Callable()


func _quit() -> void:
	if test_quit.is_valid():
		test_quit.call()
	else:
		get_tree().quit()


## 丢掉没保存的改动之前，先放进「扔掉的地图」（R26）
func _discard_to_trash() -> bool:
	var err := CustomMapStore.trash_doc(doc.doc, "unsaved")
	if err == OK:
		err = CustomMapStore.clear_autosave(doc.map_id())
	if err != OK:
		say("没能放进「扔掉的地图」，先不丢。")
		return false
	if _autosave_timer != null:
		_autosave_timer.stop()
	return true


# ------------------------------------------------------------------ 顶栏按钮
## 顶栏「撤销」和 ⌘Z 同一个规则：框里有没提交的字时只撤框里的字（⌘Z 在 _input 里直接让给输入框）
func _on_undo() -> void:
	if board != null: board.cancel_badge_drag()
	board.cancel_landscape_stroke()
	_end_placement()
	if panel.has_uncommitted_edit():
		panel.discard_edits()
		return
	if not _prepare_history_switch(history.undo_map_id()):
		return
	var prev: Dictionary = history.undo(doc.doc)
	if prev.is_empty():
		return
	doc.doc = prev
	_apply_doc()


func _on_redo() -> void:
	if board != null: board.cancel_badge_drag()
	board.cancel_landscape_stroke()
	_end_placement()
	if panel.has_uncommitted_edit():
		panel.discard_edits()
		return
	if not _prepare_history_switch(history.redo_map_id()):
		return
	var nxt: Dictionary = history.redo(doc.doc)
	if nxt.is_empty():
		return
	doc.doc = nxt
	_apply_doc()


func _prepare_history_switch(target_id: String) -> bool:
	if target_id == "" or target_id == doc.map_id():
		return true
	# 重置前后的文档 ID 不同；撤销后再次重做，也不能留下旧 ID 的待恢复自动稿。
	return _prepare_doc_departure()


func _prepare_doc_departure() -> bool:
	if doc.is_dirty() and not doc.is_untouched():
		return _discard_to_trash()
	# 当前已回到保存/新建版本，仍可能留有上次清理失败的自动稿，不能直接放行。
	_autosave_timer.stop()
	if _autosave_current():
		return true
	say("旧自动稿还没能放进「扔掉的地图」，先不切换。")
	return false


func _on_rename() -> void:
	_commit_edits()
	dialogs.ask_name("rename", "给这张地图起个名字", doc.map_name(), "好了", func(ch: String) -> void:
		if ch == "ok" and dialogs.last_entered_name() != doc.map_name():
			_commit(doc.rename(dialogs.last_entered_name()), "改地图名"))


func _default_name() -> String:
	for c: Dictionary in doc.doc.get("new_cities", []):
		if String(c.get("origin", "")) == "USER":
			return "%s之旅" % String(c.get("name", ""))
	return "我的地图" if doc.map_name() == "新地图" else doc.map_name()


func _on_save() -> void:
	_commit_edits()
	_save_then(Callable())


## 保存：第一次先起名；同一作品直接保存，覆盖前自动留 .bak（store 负责）。另存为重名仍询问。
func _save_then(then: Callable) -> void:
	if not doc.ever_saved:
		dialogs.ask_name("save_name", "给这张地图起个名字", _default_name(), "存", func(ch: String) -> void:
			if ch != "ok":
				return
			var nm: String = dialogs.last_entered_name()
			if nm != doc.map_name():
				_commit(doc.rename(nm), "起名")
			_write_save(false, then))
		return
	_write_save(true, then)


func _write_save(overwrite: bool, then: Callable) -> void:
	var err := CustomMapStore.save_map(doc.doc, thumbnail(), overwrite)
	var save_warning := CustomMapStore.last_save_warning
	if err != OK:
		say(LINES.store_pending)
		return
	_autosave_timer.stop()
	doc.mark_saved()
	_refresh_top()
	_remember_last_map()
	say(save_warning if save_warning != "" else "已保存到「我的地图 / %s」" % doc.map_name())
	if then.is_valid():
		then.call()


## 另存为（3.12.8）：新的 map_id，名字预填「X 2」；和库里别的地图重名时自动往后加数字，孩子直接点「存」不会碰到重名。
## 孩子坚持改回库里已有的名字：问「已经有一张『X』了，要换成现在这张吗？」【另起个名字】（安全，回到起名框）【换掉旧的】
## （旧图先挪进 trash/，能在「扔掉的地图」里拿回来，R26）
func _on_save_as() -> void:
	_commit_edits()
	var names := _library_by_name()
	var base_name: String = doc.map_name()
	var n := 2
	var nm := _copy_name(base_name, n)
	while names.has(nm):
		n += 1
		nm = _copy_name(base_name, n)
	_ask_save_as_name(nm)


## 编号也占十字额度；先为它留位置，再对最终名称查重，不能截掉编号变回原名。
func _copy_name(base_name: String, number: int) -> String:
	var suffix := " %d" % number
	return base_name.substr(0, maxi(0, CustomMapValidator.MAP_NAME_MAX - suffix.length())) + suffix


func _library_by_name() -> Dictionary:
	var out := {}
	for e in Backend.startup_library():
		if e is Dictionary:
			out[String(e.get("name", ""))] = e
	return out


func _ask_save_as_name(prefill: String) -> void:
	dialogs.ask_name("save_as", "另存为一张新地图", prefill, "存", func(ch: String) -> void:
		if ch != "ok":
			return
		var nm: String = dialogs.last_entered_name()
		var same: Dictionary = _library_by_name().get(nm, {})
		if same.is_empty():
			_write_save_as(nm, "")
		else:
			_ask_replace_same_name(same, nm))


func _ask_replace_same_name(old: Dictionary, nm: String) -> void:
	dialogs.confirm("save_as_replace", "已经有一张「%s」了，要换成现在这张吗？" % nm, "换掉的旧图会先放进「扔掉的地图」，还能拿回来。",
		[{"id": "rename", "text": "另起个名字", "kind": "safe"}, {"id": "replace", "text": "换掉旧的", "kind": "danger"}],
		func(ch: String) -> void:
			if ch == "replace":
				_write_save_as(nm, String(old.get("map_id", "")))
			else:
				_ask_save_as_name(nm))


func _write_save_as(nm: String, replace_id: String) -> void:
	if replace_id != "" and CustomMapStore.trash_map(replace_id) != OK:
		say("没能把旧的「%s」放进「扔掉的地图」，先不换。" % nm)
		return
	var copy: Dictionary = doc.doc.duplicate(true)
	copy["map_id"] = Backend.new_map_id()
	copy["name"] = nm
	var err := CustomMapStore.save_map(copy, thumbnail(), false)
	var save_warning := CustomMapStore.last_save_warning
	if err != OK:
		say(LINES.store_pending)
		return
	# 另存成功后，旧 ID 的自动稿不再是待恢复的当前稿；先保全，再清理。
	# 新图写入失败时不会走到这里，原稿的恢复入口仍完整保留。
	var old_id: String = doc.map_id()
	var old_auto := CustomMapStore.read_autosave(old_id)
	if not old_auto.is_empty():
		err = CustomMapStore.trash_doc(old_auto, "unsaved")
	if err == OK:
		err = CustomMapStore.clear_autosave(old_id)
	if err != OK:
		say((save_warning + " " if save_warning != "" else "") + "新地图已保存，旧自动稿还没能整理好，先保留当前稿。")
		return
	_autosave_timer.stop()
	doc.open(copy, true)
	history.clear()            # 另存为以后是另一张图：撤销不再把旧图的名字和 map_id 带回来（不然 ⌘S 会存回旧图）
	_apply_doc(false)
	say(save_warning if save_warning != "" else LINES.saved)


func _on_open() -> void:
	_commit_edits()
	_refill_library()


## 「我的地图」浮层的两页卡片：工坊自己拼副标题、读缩略图、判断「已装进游戏」（条目形状见 workshop_backend.gd 的集成清单）
func _refill_library() -> void:
	var lib: Array = Backend.library_cards(CustomMapStore.list_library(), _installed_sha)
	var tr: Array = Backend.trash_cards(CustomMapStore.list_trash())
	library.open(lib, tr, _installed_name)


func _on_library(action: String, entry: Dictionary) -> void:
	_commit_edits()
	match action:
		"close":
			library.close()
		"open":
			var go := func() -> void:
				var d := CustomMapStore.load_map(String(entry.get("map_id", "")))
				if d.is_empty():
					say("这张地图打不开。")
					return
				library.close()
				_switch_doc(d, true)
			if doc.is_dirty():
				dialogs.confirm("open_dirty", "现在这张还没保存，要先保存吗？", "「%s」还有没保存的改动。" % doc.map_name(),
					[{"id": "cancel", "text": "再想想", "kind": "safe"}, {"id": "save", "text": "先保存", "kind": "middle"}, {"id": "discard", "text": "不保存", "kind": "danger"}],
					func(ch: String) -> void:
						if ch == "save":
							_save_then(go)
						elif ch == "discard" and _discard_to_trash():
							go.call())
			else:
				go.call()
		"trash":
			dialogs.confirm("trash", "真的要扔掉「%s」吗？" % String(entry.get("name", "")), "扔掉的地图可以在「扔掉的地图」里拿回来。",
				[{"id": "cancel", "text": "再想想", "kind": "safe"}, {"id": "trash", "text": "扔掉", "kind": "danger"}],
				func(ch: String) -> void:
					if ch != "trash":
						return
					var target_id := String(entry.get("map_id", ""))
					var is_current: bool = target_id == doc.map_id()
					# 当前内存稿可能比一秒前的自动稿更新，扔图前也要保全它（R26）。
					if is_current and doc.is_dirty() and CustomMapStore.trash_doc(doc.doc, "unsaved") != OK:
						say(LINES.store_pending)
						return
					if CustomMapStore.trash_map(target_id) != OK:
						say(LINES.store_pending)
						return
					if is_current:
						await _switch_doc({}, false)
					_refill_library())
		"restore":
			if CustomMapStore.restore_from_trash(String(entry.get("id", ""))) != OK:
				say(LINES.store_pending)
			else:
				_refill_library()
				library.set_tab("trash")
		"reveal":
			var dir := CustomMapStore.maps_dir()
			if dir == "":
				say(LINES.store_pending)
			else:
				OS.shell_open(dir)
		"uninstall":
			_on_uninstall()


## 「重置」：回到原版棋盘，成为一张名叫「新地图」的未保存地图；也进撤销栈
func _on_reset() -> void:
	_commit_edits()
	dialogs.confirm("reset", "从原版地图重新开始？", "加的城、挪的路都会不见。保存过的地图不受影响。",
		[{"id": "cancel", "text": "再想想", "kind": "safe"}, {"id": "reset", "text": "变回原版", "kind": "danger"}],
		func(ch: String) -> void:
			if ch == "reset":
				if not _prepare_doc_departure():
					return
				board.select("", "")
				_commit(doc.reset_to_original(), "重置"))


## 「导入地图」：先保存（需要的话）→ 用和游戏同一份校验器再查一遍 → 带缩略图的确认框 → 写 installed.json
func _on_import() -> void:
	_commit_edits()
	if not issues.is_empty():
		return
	if doc.is_dirty():
		_save_then(_confirm_import)
	else:
		_confirm_import()


func _confirm_import(start_playtest := false) -> void:
	_revalidate()
	if not issues.is_empty():
		_refresh_top()
		say(String(issues[0].kid))
		return
	var moved: int = doc.moves().size()
	var parts := PackedStringArray()
	parts.append("没有新城" if doc.new_city_count() == 0 else "多了 %d 座城" % doc.new_city_count())
	if moved > 0:
		parts.append("挪了 %d 座老城" % moved)
	var win := "赢了电脑算胜场 ✓" if _counts_win else "这张自制地图还在试玩，赢了不算胜场"
	var text := "%s。%s。回到游戏标题页、再点「商旅模式」，就用这张地图。" % [" · ".join(parts), win]
	if _installed_name != "" and _installed_name != doc.map_name():
		text += "原来装着的「%s」会被换下来（它还在「我的地图」里）。" % _installed_name
	var thumb := thumbnail()
	var import_sha: String = doc.sha()
	var import_map_id: String = doc.map_id()
	var on_choice := func(ch: String) -> void:
		if ch != "import":
			return
		if doc.sha() != import_sha or doc.map_id() != import_map_id:
			say("地图已变化，请重新确认安装。"); return
		if CustomMapStore.write_installed(doc.doc, thumb) != OK:
			say(LINES.import_pending)
			return
		doc.installed_sha = doc.sha()
		_installed_sha = doc.installed_sha
		_installed_name = doc.map_name()
		_refresh_top()
		say(CustomMapStore.last_thumbnail_warning if not CustomMapStore.last_thumbnail_warning.is_empty() else LINES.imported)
		if start_playtest: _launch_playtest()
		else: _offer_playtest()
	dialogs.confirm("import", "把「%s」装进游戏？" % doc.map_name(), text,
		[{"id": "cancel", "text": "再想想", "kind": "safe"}, {"id": "import", "text": "装进游戏", "kind": "danger"}],
		on_choice, ImageTexture.create_from_image(thumb))


func _on_uninstall() -> void:
	_commit_edits()
	dialogs.confirm("uninstall", "让游戏用回原版地图？", "你的地图还留在「我的地图」里。",
		[{"id": "cancel", "text": "再想想", "kind": "safe"}, {"id": "uninstall", "text": "用回原版", "kind": "danger"}],
		func(ch: String) -> void:
			if ch == "uninstall":
				if CustomMapStore.uninstall() != OK:
					say(LINES.store_pending)
				else:
					_installed_name = ""
					_installed_sha = ""
					doc.installed_sha = ""
					_refresh_top())


func _on_new_map() -> void:
	_commit_edits()
	_welcome.visible = false
	var fresh := CustomMapFreeAuthor.enter(Backend.empty_doc("新地图"), _base_content)
	fresh.name = "新地图"
	await _switch_doc(fresh, false)
	doc.fresh_sha = doc.sha()
	say("先点左侧「加城」，在地图上放城；选中城市后连接，再调整地形。")

func _on_new_compatible_map() -> void:
	_commit_edits()
	_welcome.visible = false
	await _switch_doc({}, false)
	say("原版兼容地图：可微调原城；新增城市使用原有宿主与搭档规则。")

func _on_view_all() -> void:
	board.view_all()


func _on_zoom_in() -> void:
	board.zoom_button(1)


func _on_zoom_out() -> void:
	board.zoom_button(-1)


# ------------------------------------------------------------------ 加一座城（3.12.5）
func _on_add_city() -> void:
	_commit_edits()
	if CustomMapFreeAuthor.enabled(doc.doc):
		_end_landscape();_end_placement();drawers.close();_chooser.hide()
		_placing_type="AUTHOR";_placement_epoch+=1;board.begin_placement(null)
		say("点地图任意位置落城；之后命名、选特产和连线。Esc或右键取消。")
		return
	_chooser.visible = not _chooser.visible


## 放城候选经过同一套规则、生成器与全量几何检查，成功后一次提交一对城市。
func _on_transport_chosen(route_type: String) -> void:
	if CustomMapFreeAuthor.enabled(doc.doc):_on_add_city();return
	if _placement_busy or _landscape_busy or doc.user_city_count() >= Backend.MAX_USER:
		return
	_end_landscape()
	_chooser.visible = false
	drawers.close()
	_placing_type = route_type
	_placement_epoch += 1
	board.begin_placement(null)
	_refresh_find_button()
	say("正在找可放的位置，找到后会用大号圆点标出来。")
	_start_position_search("place", "")


func _end_placement() -> void:
	_clear_search()
	_placement_epoch += 1
	_placement_busy = false
	_show_wait(false)
	_placing_type = ""
	if board != null:
		board.end_placement()
	_refresh_find_button()


func _measure_apply(phase: String, started: int) -> void:
	if _commit_measure_task >= 0:
		search_timings.append({"phase": "apply_" + phase, "task_id": _commit_measure_task, "ms": (Time.get_ticks_usec() - started) / 1000.0})


func _user_identity(source: Dictionary) -> String:
	var users: Array = []
	for c: Dictionary in source.get("new_cities", []):
		if str(c.get("origin", "")) == "USER": users.append(c)
	return CustomMapSchema.canonical_text({"users": users}).sha256_text()


func _candidate_key(sha: String, transport: String, identity: String, spot: Dictionary) -> String:
	return "%s|%s|%s|%s|%.6f|%.6f" % [sha, transport, identity, str(spot.get("host", "")), float(spot.x), float(spot.z)]


func _validated_pair(pair: Dictionary) -> bool:
	if not (bool(pair.get("ok", false)) and bool(pair.get("validation", {}).get("ok", false)) and pair.has("doc") and str(pair.validation.get("sha256", "")) == CustomMapSchema.sha256(pair.doc)): return false
	# A document SHA cannot certify resources changed independently on disk.
	var asset_errors: Array[Dictionary] = []
	CustomMapValidator._check_assets(pair.doc, catalogue, asset_errors)
	return asset_errors.is_empty()


func _pair_matches(pair: Dictionary, pos: Vector2, host: String, transport: String) -> bool:
	if not _validated_pair(pair): return false
	var c := Mutations.city(pair.doc, str(pair.get("city_id", "")))
	return not c.is_empty() and str(c.get("origin", "")) == "USER" and str(c.get("host", "")) == host and str(c.get("route_type", "")) == transport and Vector2(float(c.x), float(c.z)).distance_to(pos) < 0.001


func _search_is_current(epoch: int, source_sha: String) -> bool:
	if epoch != _search_epoch or not is_inside_tree() or is_queued_for_deletion(): return false
	if doc.sha() != source_sha:
		_end_placement()
		_search_status = "expired"
		return false
	return true


func _on_place_requested(pos: Vector2, host_hint := "", cached: Dictionary = {}) -> void:
	if CustomMapFreeAuthor.enabled(doc.doc):
		if _placing_type!="AUTHOR" or not board.placement_mode:return
		var placed:=CustomMapFreeAuthor.place(doc.doc,pos,_base_content,board.base_layout,catalogue)
		if not placed.get("ok",false):_reject_action(placed,"");return
		_end_placement();_accept_mutation(placed,"放置自由城市")
		board.select("city",str(placed.city_id))
		if panel.text_fields.has("name"):
			(panel.text_fields.name as LineEdit).grab_focus();(panel.text_fields.name as LineEdit).select_all()
		return
	if _placement_busy or _placing_type == "" or not board.placement_mode: return
	# A late signal from an obsolete numbered task must never place anything.
	if not cached.is_empty() and int(cached.get("task_id", -1)) != _search_epoch: return
	_placement_busy = true
	var epoch := _placement_epoch
	var search_id := _search_epoch
	var source_sha: String = doc.sha()
	var transport := _placing_type
	var identity := _user_identity(doc.doc)
	_search_status = "committing"
	_show_wait(true)
	await get_tree().process_frame
	if epoch != _placement_epoch or not _search_is_current(search_id, source_sha): return
	var result: Dictionary = {}
	if str(cached.get("source_sha", "")) == source_sha and str(cached.get("transport", "")) == transport and str(cached.get("user_identity", "")) == identity:
		result = cached.get("complete_pair", {}).duplicate(true)
	if not _pair_matches(result, pos, host_hint, transport):
		var task := Mutations.add_pair_begin(doc.doc, _base_content, board.base_layout, catalogue, transport, pos, host_hint)
		while not bool(task.done):
			_search_phase = "commit_" + str(task.phase)
			await get_tree().process_frame
			if epoch != _placement_epoch or not _search_is_current(search_id, source_sha): return
			Mutations.add_pair_step(task)
		for timing: Dictionary in task.timings:
			search_timings.append({"phase": "commit_" + str(timing.phase), "detail": timing.get("detail", ""), "task_id": search_id, "ms": timing.ms})
		result = task.result
	if epoch != _placement_epoch or not _search_is_current(search_id, source_sha): return
	_placement_busy = false
	_show_wait(false)
	if not _validated_pair(result):
		_search_status = "rejected"
		_reject_action(result, "")
		return
	_end_placement()
	var started := Time.get_ticks_usec()
	_commit_measure_task = search_id
	_accept_mutation(result, "加一对城市")
	_commit_measure_task = -1
	search_timings.append({"phase": "commit_apply", "task_id": search_id, "ms": (Time.get_ticks_usec() - started) / 1000.0})
	_search_status = "committed"
	started = Time.get_ticks_usec()
	board.select("city", str(result.get("city_id", "")))
	board.fly_to_city(str(result.get("city_id", "")))
	if panel.text_fields.has("name"):
		var edit: LineEdit = panel.text_fields.name
		edit.grab_focus()
		edit.select_all()
	search_timings.append({"phase": "commit_selection", "task_id": search_id, "ms": (Time.get_ticks_usec() - started) / 1000.0})
	say("放好啦！另一边也有了搭档。点右边给你的城市起个名字。")


func open_drawer(mode: String, route_type: String, side: String, preview := false) -> void:
	drawers.free_author=CustomMapFreeAuthor.enabled(doc.doc)
	board.set_hud_safe_insets(0.0, 0.0)
	_drawer_city = str(panel.target)
	var c := Mutations.city(doc.doc, _drawer_city)
	if mode == "look":
		drawers.open_look(side, route_type, str(c.get("archetype", "")), preview)
	else:
		var used := {}
		for other: Dictionary in doc.doc.get("new_cities", []):
			if str(other.slot) != str(c.get("slot", "")):
				used[str(other.specialty)] = str(other.name)
		drawers.open_goods(side, str(c.get("specialty", "")), used, preview)


func _on_drawer_picked(kind: String, id: String) -> void:
	if _drawer_city == "" or _drawer_city != str(panel.target):
		drawers.close()
		return
	var field := "archetype" if kind == "look" else "specialty"
	var current_city := Mutations.city(doc.doc,_drawer_city)
	if kind=="goods" and str(current_city.get("specialty",""))==id:
		drawers.show_applied(_specialty_name(id)); return
	if _accept_mutation(Mutations.change_city(doc.doc, _drawer_city, field, id, _base_content, board.base_layout, catalogue), "换城市样子" if kind == "look" else "换城市特产"):
		if kind=="goods": drawers.show_applied(_specialty_name(id))
		else: drawers.close()
	else:
		var current := Mutations.city(doc.doc, _drawer_city)
		drawers.restore_selection(str(current.get(field, "")))


func _on_text_field(cid: String, field: String, value: String) -> void:
	var v: Variant = value
	if field == "intro":
		field = "text"
		v = {"mode": "CUSTOM", "line": CustomMapCardText.clean_line(value)}
	_accept_mutation(Mutations.change_city(doc.doc, cid, field, v, _base_content, board.base_layout, catalogue), "改城市名字" if field == "name" else "改城市介绍")


func _accept_mutation(result: Dictionary, label: String) -> bool:
	if not bool(result.get("ok", false)):
		var rejected_target := String(panel.target)
		_apply_doc(false)
		_reject_action(result, rejected_target)
		return false
	var before: Dictionary = doc.doc.duplicate(true)
	doc.doc = result.doc
	doc._touch()
	_commit(before, label, result.get("validation", {}))
	return true


func _ask_remove_pair(cid: String) -> void:
	var c := Mutations.city(doc.doc, cid)
	if c.is_empty() or str(c.get("origin", "")) != "USER":
		return
	dialogs.confirm("remove_pair", ("删除「%s」？" if CustomMapFreeAuthor.enabled(doc.doc) else "拆掉「%s」和它的搭档？") % str(c.name), "这座城和连接的路会一起删除；可以撤销。" if CustomMapFreeAuthor.enabled(doc.doc) else "两座城和连接的路会一起拆掉。可以按「撤销」找回来。",
		[{"id": "cancel", "text": "再想想", "kind": "safe"}, {"id": "remove", "text": "一起拆掉", "kind": "danger"}],
		func(ch: String) -> void:
			if ch == "remove":
				board.select("", "")
				_accept_mutation(Mutations.remove_pair(doc.doc, cid, _base_content, board.base_layout, catalogue), "拆掉一对城市"))


func _show_new_city_panel(cid: String) -> void:
	var c := Mutations.city(doc.doc, cid)
	if c.is_empty():
		return
	var spec := CustomMapCatalogue.specialty(catalogue, str(c.specialty))
	var arch := CustomMapCatalogue.archetype(catalogue, str(c.archetype))
	var intro := str(c.get("text", {}).get("line", ""))
	panel.show_new_city({"id": cid, "name": str(c.name), "origin": str(c.origin), "host_name": _connection_host_names(c),
		"author_mode":CustomMapFreeAuthor.enabled(doc.doc),"free_mode":CustomMapFreeRoutes.enabled(doc.doc),"active_link_count":_free_link_count(cid),
		"has_extra_connection": not c.get("extra_connections", []).is_empty(), "partner_name": _display_name("x_" + str(c.get("partner",""))), "side": "西边" if _side(cid) == "W" else "东边",
		"specialty_name": "尚未选择特产" if str(c.specialty)=="" else str(spec.get("name", spec.get("display_name", c.specialty))), "specialty_icon": null if spec.is_empty() else LshuIcons.good(CustomMapSchema.good_id(str(c.slot), str(c.specialty)), GameState.content),
		"archetype_name": str(arch.get("title", c.archetype)), "x": float(c.x), "z": float(c.z),
		"rotation": float(c.get("rotation", 0.0)), "size": float(c.get("size", 1.0)), "text_mode": str(c.get("text", {}).get("mode", "AUTO")), "intro": intro}, GameState.content)
	panel.set_validator("x", func(v: float) -> String: return _field_reason(cid, v, float(doc.city_pos(cid).z), float(doc.city_pos(cid).rotation)))
	panel.set_validator("z", func(v: float) -> String: return _field_reason(cid, float(doc.city_pos(cid).x), v, float(doc.city_pos(cid).rotation)))
	panel.set_validator("rotation", func(v: float) -> String: return _field_reason(cid, float(doc.city_pos(cid).x), float(doc.city_pos(cid).z), deg_to_rad(v)))
	panel.set_text_validator("name", func(value: String) -> String: return Mutations.city_name_problem(doc.doc, cid, value, _base_content))


# ------------------------------------------------------------------ 其它
func say(text: String) -> void:
	if _hint != null:
		_hint.text = text


## 缩略图：视口全图截一张，裁成 16:9，480×270（3.12.8）
func thumbnail() -> Image:
	var img: Image = null
	if board != null and board.vp != null and DisplayServer.get_name() != "headless":
		img = board.vp.get_texture().get_image()
	if img == null or img.is_empty():
		img = Image.create(480, 270, false, Image.FORMAT_RGB8)
		img.fill(Kit.CREAM_DEEP)
		return img
	var w := img.get_width()
	var h := img.get_height()
	var cw := mini(w, int(h * 16.0 / 9.0))
	var ch := int(cw * 9.0 / 16.0)
	var out := img.get_region(Rect2i((w - cw) / 2, (h - ch) / 2, cw, ch))
	out.resize(480, 270, Image.INTERPOLATE_LANCZOS)
	return out


func get_workshop_state() -> Dictionary:
	return {"ready": _ready_done, "welcome": _welcome.visible, "dialog": dialogs.current_id(), "drawer": drawers.mode if drawers.is_open() else "",
		"hint": _hint.text, "dirty": doc.is_dirty() if doc != null else false, "undo": history.undo_size() if history != null else 0,
		"search_status": _search_status, "search_task_id": _search_epoch, "candidate_count": _search_spots.size(), "redo": history.redo_size() if history != null else 0, "issues": issues.size(), "warnings": warnings.size(), "action_issues": action_issues.size(), "counts_win": _counts_win, "k": _k, "boot_ms": boot_ms}


func _connection_host_names(c: Dictionary) -> String:
	if CustomMapFreeRoutes.enabled(doc.doc):
		var active:Array[String]=[];var cid:="x_"+str(c.slot)
		for r:Dictionary in board.cur_layout.routes:
			if str(r.a)==cid:active.append(_display_name(str(r.b)))
			elif str(r.b)==cid:active.append(_display_name(str(r.a)))
		return "、".join(active) if not active.is_empty() else "尚未连接"
	var names: Array[String] = [_display_name(str(c.get("host","")))]
	for link: Dictionary in c.get("extra_connections", []):
		names.append(_display_name(str(link.host)))
	return "、".join(names)

func _free_link_count(cid:String)->int:
	if not CustomMapFreeRoutes.enabled(doc.doc):return 0
	var count:=0
	for r:Dictionary in board.cur_layout.routes:
		if cid in [str(r.a),str(r.b)]:count+=1
	return count


func _cancel_connection(clear_action := true) -> void:
	_connection_epoch += 1
	_connection_candidate.clear()
	_connection_running = false
	_connection_city = ""
	if is_instance_valid(_connection_ui):
		_connection_ui.hide()
		_connection_ui.queue_free()
	_connection_ui = null
	if is_instance_valid(board):
		board.clear_connection_preview()
	if clear_action:
		_clear_action_issues()
		say("已取消连接；地图没有改动。")


func _open_connection(cid: String) -> void:
	_commit_edits()
	_cancel_connection(false)
	var c := Mutations.city(doc.doc, cid)
	if c.is_empty() and CustomMapFreeAuthor.enabled(doc.doc):c={"name":_display_name(cid),"x":doc.city_pos(cid).x,"z":doc.city_pos(cid).z}
	if c.is_empty(): return
	_clear_action_issues()
	_connection_city = cid
	_connection_ui = PanelContainer.new()
	_connection_ui.name = "ConnectionChooser"
	_connection_ui.position = Vector2(1400, 96)
	_connection_ui.custom_minimum_size = Vector2(520, 984)
	_connection_ui.size = Vector2(520, 984)
	_connection_ui.add_theme_stylebox_override("panel", Kit.satchel_box(24, 4, 24))
	_stage.add_child(_connection_ui)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 18)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	_connection_ui.add_child(scroll)
	col.size_flags_horizontal=Control.SIZE_EXPAND_FILL;col.custom_minimum_size.x=350
	scroll.add_child(col)
	col.add_child(Kit.label("连接另一座城", 30, Kit.SATCHEL_DEEP, "body", 700))
	col.add_child(Kit.label("从："+_display_name(cid) if CustomMapFreeAuthor.enabled(doc.doc) else "原宿主：" + _display_name(str(c.get("host",""))), 24, Kit.INK))
	var existing: Array = c.get("extra_connections", [])
	var caption := "选择任意原城或新城；也可点地图上的目标。冲突连线可保存，试玩前修复。" if CustomMapFreeAuthor.enabled(doc.doc) else "仅增加一条连接；原宿主路线保留。"
	if not existing.is_empty():
		caption = "现有额外连接：%s\n请在城市属性点「移除额外连接」，之后可重新选择；原宿主路线保留。" % _display_name(str(existing[0].host))
	var description := Kit.label(caption, 22, Kit.INK_SOFT)
	description.name = "ExistingConnectionLabel"
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(description)
	col.add_child(Kit.label("交通方式" if CustomMapFreeAuthor.enabled(doc.doc) else "交通（与这座新城一致）", 22, Kit.INK))
	_connection_user_medium=false
	_connection_modes = OptionButton.new()
	_connection_modes.name = "ConnectionTransport"
	_connection_modes.custom_minimum_size.y = 58
	_style_connection_select(_connection_modes)
	_connection_modes.add_item("陆路", 0)
	_connection_modes.add_item("海路", 1)
	_connection_modes.select(0 if str(c.get("route_type","LAND")) == "LAND" else 1)
	for i in 2: _connection_modes.set_item_disabled(i, not CustomMapFreeAuthor.enabled(doc.doc) and ("LAND" if i == 0 else "SEA") != str(c.get("route_type","LAND")))
	col.add_child(_connection_modes)
	col.add_child(Kit.label("选择目标城市" if CustomMapFreeAuthor.enabled(doc.doc) else "选择原版城市", 22, Kit.INK))
	_connection_targets = OptionButton.new()
	_connection_targets.name = "ConnectionTarget"
	_connection_targets.custom_minimum_size.y = 58
	_style_connection_select(_connection_targets)
	col.add_child(_connection_targets)
	_connection_note = Kit.label("选择目标后预览；有问题也可存为待修复连线。" if CustomMapFreeAuthor.enabled(doc.doc) else "选择目标后预览；校验通过才可确认。", 22, Kit.INK)
	_connection_note.name = "ConnectionStatus"
	_connection_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_connection_note.custom_minimum_size.y = 168
	col.add_child(_connection_note)
	_connection_preview_button = Kit.button("预览连接", "denim", 60, 26)
	_connection_preview_button.name = "PreviewConnectionButton"
	_connection_preview_button.pressed.connect(_preview_selected_connection)
	col.add_child(_connection_preview_button)
	_connection_confirm_button = Kit.button("确认连接", "primary", 60, 26)
	_connection_confirm_button.name = "ConfirmConnectionButton"
	_connection_confirm_button.disabled = true
	_connection_confirm_button.pressed.connect(_confirm_connection)
	col.add_child(_connection_confirm_button)
	var cancel := Kit.button("取消连接", "cream", 60, 26)
	cancel.name = "CancelConnectionButton"
	cancel.pressed.connect(_cancel_connection)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	col.add_child(bottom)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(cancel)
	_connection_locate_button = Kit.button("定位城市", "cream", 60, 24)
	_connection_locate_button.name = "LocateConnectionCityButton"
	_connection_locate_button.set_meta("readonly_location", true)
	_connection_locate_button.visible = false
	_connection_locate_button.pressed.connect(func() -> void:
		var target := _connection_city
		_cancel_connection(false)
		_on_panel_action("goto:" + target)
		_refresh_panel())
	bottom.add_child(_connection_locate_button)
	_connection_targets.item_selected.connect(func(_index: int) -> void: _match_connection_medium();_connection_choice_changed())
	_connection_modes.item_selected.connect(func(_index: int) -> void: _connection_user_medium=true;_fill_connection_targets())
	_fill_connection_targets()


func _style_connection_select(select: OptionButton) -> void:
	select.fit_to_longest_item=false;select.clip_text=true
	select.add_theme_font_override("font", Kit.font("body", 500))
	select.add_theme_font_size_override("font_size", 24)
	select.add_theme_color_override("font_color", Kit.INK)
	select.add_theme_stylebox_override("normal", Kit.satchel_box(12, 2, 12))
	select.add_theme_stylebox_override("hover", Kit.satchel_box(12, 3, 12))
	select.get_popup().add_theme_font_override("font", Kit.font("body", 500))
	select.get_popup().add_theme_font_size_override("font_size", 22)


func _connection_problem(c: Dictionary, host: String, rt: String) -> String:
	if CustomMapFreeAuthor.enabled(doc.doc):
		if host==_connection_city:return "不能连接自己"
		for r:Dictionary in board.cur_layout.routes:
			if [str(r.a),str(r.b)].has(host) and [str(r.a),str(r.b)].has(_connection_city) and str(r.type)==rt:return "已经有这类连线"
		return ""
	if c.is_empty() or not _base_content.cities.has(host): return "请选择新增城市和原版目标城市"
	if rt != str(c.get("route_type","LAND")): return "新增城市不能换乘；请选择相同交通"
	if host == str(c.get("host","")): return "这座城已经是原宿主"
	for link: Dictionary in c.get("extra_connections", []):
		if str(link.host) == host: return "已经连接这座城；请选择另一个目标"
	if not rt in _base_content.cities[host].allowed_routes: return "目标城市不支持这类交通"
	if CustomMapRules.host_degree(_base_content, host) > 4: return "目标城市原度数超过 4"
	return ""


func _fill_connection_targets() -> void:
	var selected_host := str(_connection_targets.get_item_metadata(_connection_targets.selected)) if _connection_targets.selected>=0 else ""
	_connection_targets.clear()
	var c := Mutations.city(doc.doc, _connection_city)
	var rt := "LAND" if _connection_modes.selected == 0 else "SEA"
	var ids: Array = GameState.content.cities.keys() if CustomMapFreeAuthor.enabled(doc.doc) else _base_content.cities.keys()
	ids.sort_custom(func(a,b):return _display_name(str(a)).naturalnocasecmp_to(_display_name(str(b)))<0)
	var first := -1
	for host: String in ids:
		var problem := _connection_problem(c, host, rt)
		var modes: Array=CustomMapFreeAuthor.routes_for(_base_content,doc.doc,host) if CustomMapFreeAuthor.enabled(doc.doc) else _base_content.cities[host].allowed_routes
		var transport_label := "陆海" if modes.size()>1 else ("陆路" if "LAND" in modes else ("海路" if "SEA" in modes else "待连接"))
		_connection_targets.add_item(_display_name(host) + " · " + transport_label + (" · " + problem if problem != "" else ""))
		var index := _connection_targets.item_count - 1
		_connection_targets.set_item_metadata(index, host)
		_connection_targets.set_item_disabled(index, problem != "")
		if first < 0 and problem == "": first = index
	_connection_targets.select(first)
	for i:int in _connection_targets.item_count:
		if str(_connection_targets.get_item_metadata(i))==selected_host and not _connection_targets.is_item_disabled(i): _connection_targets.select(i)
	_match_connection_medium()
	_connection_preview_button.disabled = first < 0 or not c.get("extra_connections", []).is_empty()
	_connection_targets.disabled = not c.get("extra_connections", []).is_empty()
	_connection_modes.disabled = not c.get("extra_connections", []).is_empty()
	_connection_choice_changed()


func _connection_choice_changed() -> void:
	_connection_epoch += 1
	_connection_candidate.clear()
	_connection_running = false
	board.clear_connection_preview()
	_connection_confirm_button.disabled = true
	_connection_locate_button.visible = false
	_connection_note.text = "已有额外连接。先在城市属性移除，再预览另一条连接。" if not Mutations.city(doc.doc, _connection_city).get("extra_connections", []).is_empty() else ("选择目标后预览；有问题也可存为待修复连线。" if CustomMapFreeAuthor.enabled(doc.doc) else "选择目标后预览；校验通过才可确认。")
	_clear_action_issues()


func _preview_selected_connection() -> void:
	if _connection_targets.selected < 0: return
	_match_connection_medium()
	_preview_connection(str(_connection_targets.get_item_metadata(_connection_targets.selected)), "LAND" if _connection_modes.selected == 0 else "SEA")


func _connection_current(epoch: int, sha: String, cid: String) -> bool:
	return is_inside_tree() and epoch == _connection_epoch and cid == _connection_city and is_instance_valid(_connection_ui) and doc.sha() == sha


func _connection_failed(result: Dictionary, cid: String) -> void:
	_connection_running = false
	_connection_candidate.clear()
	board.clear_connection_preview()
	_connection_confirm_button.disabled = true
	_connection_locate_button.visible = true
	var detail := str(result.get("detail", ""))
	var errors: Array = result.get("errors", [])
	if detail == "" and not errors.is_empty(): detail = str(errors[0].get("tech", ""))
	_connection_note.text = str(result.get("reason", "这条连接没有通过校验")) + ("\n" + detail if detail != "" else "") + "\n连接未应用；请换目标或调整城市位置。"
	_reject_action(result, cid)


func _preview_connection(host: String, rt: String) -> void:
	if CustomMapFreeAuthor.enabled(doc.doc):
		_preview_author_connection(host,rt)
		return
	if not is_instance_valid(_connection_ui): return
	_connection_choice_changed()
	var epoch := _connection_epoch
	var cid := _connection_city
	var sha: String = doc.sha()
	var snapshot: Dictionary = doc.doc.duplicate(true)
	var c := Mutations.city(snapshot, cid)
	if not c.get("extra_connections", []).is_empty():
		_connection_failed(Mutations.failure("已有额外连接。先在城市属性移除，再预览另一条连接。"), cid)
		return
	var problem := _connection_problem(c, host, rt)
	if problem != "":
		_connection_failed(Mutations.failure(problem), cid)
		return
	_connection_running = true
	_connection_note.text = "正在寻找并完整校验连接…"
	await get_tree().process_frame
	if not _connection_current(epoch, sha, cid):
		_connection_stale(epoch)
		return
	var geo := CustomMapGeo.for_overlay(snapshot)
	# The route helper recognizes an existing endpoint through its incident route.
	# Declare only a speculative route in a copy; no live graph or document changes.
	var routing_doc := snapshot.duplicate(true)
	Mutations.city(routing_doc, cid)["extra_connections"] = [{"host": host, "route_type": rt, "route": {"handles": [], "stop_t": [0.333, 0.667]}}]
	var topology_errors := CustomMapRules.check_topology(_base_content, routing_doc, CustomMapRules.params())
	if not topology_errors.is_empty():
		_connection_failed({"ok": false, "reason": str(topology_errors[0].kid), "errors": topology_errors}, cid)
		return
	var derived := CustomBoardLayout.derive(board.base_layout, routing_doc, geo, catalogue)
	var route := CustomMapGeoRules.auto_route(derived, host, Vector2(float(c.x), float(c.z)), rt, geo)
	if not bool(route.get("ok", false)):
		# A shortest route may be shorter than the unchanged 7u gate. Try a
		# bounded set of automatic bends; every candidate uses the existing probe.
		var start := Vector2.ZERO
		var foot := 3.4
		for city: Dictionary in derived.cities:
			if str(city.id) == host: start = Vector2(float(city.x), float(city.z))
			if str(city.id) == cid: foot = float(city.get("foot", foot))
		var end := Vector2(float(c.x), float(c.z))
		var normal := (end - start).normalized().orthogonal()
		var found := false
		for radius in [3.0, 4.0, 5.0, 6.0, 7.0, 8.0]:
			for sign in [1.0, -1.0]:
				await get_tree().process_frame
				if not _connection_current(epoch, sha, cid):
					_connection_stale(epoch)
					return
				var h1: Vector2 = start.lerp(end, 1.0 / 3.0) + normal * radius * sign
				var h2: Vector2 = start.lerp(end, 2.0 / 3.0) + normal * radius * sign
				var handles := [[h1.x, h1.y], [h2.x, h2.y]]
				var errors := CustomMapGeoRules._probe_route(derived, host, cid, end, foot, rt, handles, [0.333, 0.667], geo)
				if errors.is_empty():
					route = {"ok": true, "handles": handles, "stop_t": [0.333, 0.667]}
					found = true
					break
			if found: break
	if not bool(route.get("ok", false)):
		_connection_failed(Mutations.failure("到%s的%s本次未找到可用路线" % [_display_name(host), "陆路" if rt == "LAND" else "海路"], str(route.get("reason", ""))), cid)
		return
	await get_tree().process_frame
	if not _connection_current(epoch, sha, cid):
		_connection_stale(epoch)
		return
	var edit := {"handles": route.handles, "stop_t": route.stop_t}
	var result := Mutations.add_connection(snapshot, cid, host, rt, edit, _base_content, board.base_layout, catalogue)
	await get_tree().process_frame
	if not _connection_current(epoch, sha, cid):
		_connection_stale(epoch)
		return
	if not bool(result.get("ok", false)):
		_connection_failed(result, cid)
		return
	_connection_running = false
	_connection_candidate = {"epoch": epoch, "source_sha": sha, "cid": cid, "host": host, "transport": rt, "route": edit.duplicate(true)}
	var layout := CustomBoardLayout.derive(board.base_layout, result.doc, geo, catalogue)
	var rid := CustomMapSchema.corridor_id(str(c.slot), host, rt)
	board.show_connection_preview(layout, rid)
	var verb := "新增"
	_connection_note.text = "%s → %s\n%s · 2 个停靠点 · 3 步\n完整校验通过，尚未写入地图。\n%s" % [str(c.name), _display_name(host), "陆路" if rt == "LAND" else "海路", verb]
	_connection_confirm_button.text = "确认连接"
	_connection_confirm_button.disabled = false


func _connection_stale(epoch: int) -> void:
	# Never let an old coroutine clear the state of a newer task.
	if not is_inside_tree() or epoch != _connection_epoch: return
	_connection_failed(Mutations.failure("地图已变化；请重新预览连接"), _connection_city)


func _confirm_connection() -> void:
	if CustomMapFreeAuthor.enabled(doc.doc):
		if _connection_candidate.is_empty():return
		var candidate:=_connection_candidate.duplicate(true)
		if not _connection_current(int(candidate.epoch),str(candidate.source_sha),str(candidate.cid)):_connection_stale(int(candidate.epoch));return
		var result:=CustomMapFreeAuthor.connect_cities(doc.doc,str(candidate.cid),str(candidate.host),str(candidate.transport),candidate.route,_base_content,board.base_layout,catalogue)
		_cancel_connection(false)
		if _accept_mutation(result,"连接城市"):
			board.select("route",str(result.route_id))
			say("连线已保存为待修复草稿；原因和修复入口在右栏。" if result.get("draft",false) else "连接完成；拖白点调弯，拖金点挪停靠点，可撤销。")
		return
	if _connection_candidate.is_empty(): return
	var candidate := _connection_candidate.duplicate(true)
	var epoch := int(candidate.epoch)
	var cid := str(candidate.cid)
	if not Mutations.city(doc.doc, cid).get("extra_connections", []).is_empty():
		_connection_failed(Mutations.failure("已有额外连接。先在城市属性移除，再预览另一条连接。"), cid)
		return
	if not _connection_current(epoch, str(candidate.source_sha), cid):
		_connection_stale(epoch)
		return
	if _connection_targets.selected < 0 or str(_connection_targets.get_item_metadata(_connection_targets.selected)) != str(candidate.host) or ("LAND" if _connection_modes.selected == 0 else "SEA") != str(candidate.transport):
		_connection_stale(epoch)
		return
	_connection_confirm_button.disabled = true
	_connection_running = true
	await get_tree().process_frame
	if not _connection_current(epoch, str(candidate.source_sha), cid):
		_connection_stale(epoch)
		return
	# Revalidate the exact route against the current source at confirmation.
	var result := Mutations.add_connection(doc.doc, cid, str(candidate.host), str(candidate.transport), candidate.route, _base_content, board.base_layout, catalogue)
	await get_tree().process_frame
	if not _connection_current(epoch, str(candidate.source_sha), cid):
		_connection_stale(epoch)
		return
	if not bool(result.get("ok", false)):
		_connection_failed(result, cid)
		return
	var label := "连接%s" % _display_name(str(candidate.host))
	_cancel_connection(false)
	_accept_mutation(result, label)
	say(label + "；2 个停靠点、3 步，可以撤销。")


# ------------------------------------------------------------------ Isolated formal playtest / return to this editor instance.
func _build_playtest_ui() -> void:
	_playtest = load("res://scripts/map_workshop/workshop_playtest.gd").new()
	add_child(_playtest)
	_playtest.changed.connect(_playtest_changed)
	_playtest_wait_timer = Timer.new()
	_playtest_wait_timer.wait_time = 1.0
	_playtest_wait_timer.timeout.connect(_refresh_playtest_wait)
	add_child(_playtest_wait_timer)
	_playtest_button = Kit.button("开始试玩", "cream", 60, 26)
	_playtest_button.name = "StartPlaytestButton"
	_playtest_button.position = Vector2(1130, 1008); _playtest_button.size = Vector2(246, 60)
	_playtest_button.pressed.connect(_on_playtest); _stage.add_child(_playtest_button)
	_stage.move_child(_playtest_button, _stage.get_children().find(dialogs))

func _offer_playtest() -> void:
	dialogs.confirm("playtest_ready", "地图已装好", "可以开始正式商旅试玩；返回后接着编辑。试玩使用独立数据，不写正式存档或胜场。",
		[{"id": "cancel", "text": "继续编辑", "kind": "safe"}, {"id": "play", "text": "开始试玩", "kind": "middle"}],
		func(ch: String) -> void:
			if ch == "play": _on_playtest())

func _on_playtest() -> void:
	if not PublicRules.ready():
		say("玩法规则尚未配置；可先编辑保存地图，再配置规则。")
		(get_node("PublicRulesSettings") as PublicRulesUI).open()
		return
	if _playtest.pid > 0: return
	_commit_edits()
	_revalidate(); _refresh_top()
	if not issues.is_empty():
		_locate_issue(issues[0]);say("还有%d处待完成；已定位第一处，右栏可继续修复。"%issues.size());return
	_clear_search()
	if doc.is_dirty() or not doc.ever_saved: _save_then(_prepare_playtest_install)
	else: _prepare_playtest_install()

func _prepare_playtest_install() -> void:
	_revalidate(); _refresh_top()
	if not issues.is_empty():
		_locate_issue(issues[0]);say("还有%d处待完成；已定位第一处，右栏可继续修复。"%issues.size());return
	var installed := CustomMapStore.read_installed()
	if str(installed.get("sha256", "")) == doc.sha(): _launch_playtest()
	else: _confirm_import(true)

func _launch_playtest() -> void:
	if doc.is_dirty() or not doc.ever_saved:
		say("请先保存再试玩。"); return
	var installed := CustomMapStore.read_installed()
	var overlay: Dictionary = installed.get("overlay", {})
	if str(installed.get("sha256", "")) != doc.sha() or Backend.sha256(overlay) != doc.sha():
		say("已安装地图与当前地图不同，请重新安装。"); return
	_playtest_guard = {"sha256": doc.sha(), "map_id": doc.map_id(), "undo": history.undo_size(), "redo": history.redo_size(), "target": board._target, "goal": board._goal, "zoom": board._zoom, "process_mode": board.process_mode, "selection":board.sel.duplicate(true)}
	_autosave_timer.stop()
	var result: Dictionary = _playtest.start(overlay, test_playtest_position)
	if not bool(result.get("ok", false)):
		say(str(result.get("message", "试玩没有启动。")))
		if doc.is_dirty() and not doc.is_untouched(): _autosave_timer.start()
		return
	board.process_mode = Node.PROCESS_MODE_DISABLED
	_show_playtest_running()
	_refresh_playtest_wait()
	_playtest_wait_timer.start()


func _show_playtest_running() -> void:
	dialogs.confirm("playtest_running", "正在试玩「%s」" % doc.map_name(), "商旅试玩在独立窗口。结束试玩后返回这一张地图，镜头、选择和撤销记录保留。",
		[{"id": "front", "text": "去试玩窗口（前置）", "kind": "safe"}, {"id":"return", "text":"结束试玩", "kind":"middle"}],
		func(ch: String) -> void:
			if ch == "return": _playtest.stop()
			elif ch == "front":
				_playtest.request_foreground(); _show_playtest_running())
	_refresh_playtest_wait()

func _refresh_playtest_wait() -> void:
	if not is_instance_valid(_playtest) or dialogs.current_id() != "playtest_running":
		return
	if _playtest.state == "starting":
		var elapsed := maxi(0, int((Time.get_ticks_msec() - int(_playtest.get("_started"))) / 1000))
		var stage := str(_playtest.report.get("phase", "load_scene"))
		var label := str({"validate_map": "检查地图", "load_scene": "加载场景与模型", "prepare_rules": "准备正式规则", "build_world": "铺开地图", "prepare_hud": "准备棋子与界面"}.get(stage, "准备地图"))
		dialogs.update_confirm_text("playtest_running", "正在准备试玩「%s」" % doc.map_name(),
			"%s，已等待 %d 秒。\n较大地图可能需要约 1 分钟；超过 2 分钟会返回并提示原因。\n可以继续等待，也可随时返回工坊。" % [label, elapsed])
	elif _playtest.state == "playing":
		dialogs.update_confirm_text("playtest_running", "正在试玩「%s」" % doc.map_name(), "商旅试玩已经准备好，点「去试玩窗口（前置）」开始。结束后可返回这张地图，镜头、选择和撤销记录保留。")
		_playtest_wait_timer.stop()

func _playtest_changed(state: String, report: Dictionary) -> void:
	if not is_inside_tree() or not _ready_done: return
	_playtest_button.disabled = state in ["starting", "playing"] or not issues.is_empty()
	if state == "playing": _refresh_playtest_wait()
	if state in ["returned", "failed"]:
		_playtest_wait_timer.stop()
		if not _playtest_guard.is_empty():
			board._target = _playtest_guard.target; board._goal = _playtest_guard.goal; board._zoom = _playtest_guard.zoom
			board._apply_camera()
			board.process_mode = int(_playtest_guard.process_mode)
			var selected: Dictionary = _playtest_guard.get("selection",{})
			board.select(str(selected.get("kind","")),str(selected.get("id","")))
			_refresh_panel()
		if dialogs.current_id() == "playtest_running": dialogs._finish("ended")
		if state == "failed": say(str(report.get("message", "试玩没有成功启动，已返回地图工坊。")))
		else: say("已返回地图工坊，可以接着编辑。")
		if doc.is_dirty() and not doc.is_untouched(): _autosave_timer.start()

func _build_piece_skins()->void:
	_piece_tools=preload("res://scripts/map_workshop/workshop_piece_skins.gd").new();_piece_tools.workshop=self;_stage.add_child(_piece_tools)
	_piece_button=Kit.button("棋子模型", "cream",44,20);_piece_button.name="PieceSkinsButton";_piece_button.position=Vector2(1176,256);_piece_button.custom_minimum_size.x=200
	_piece_button.pressed.connect(func()->void:
		panel.suspend_edits();_end_landscape();_end_placement();_plant_tools.close_tools();_intro_tools.close_tools();_local_assets.cancel();_local_assets.hide();_piece_tools.open_tools())
	_stage.add_child(_piece_button)

var _badge_file: FileDialog
var _badge_import_city := ""
var _badge_import_context: Dictionary = {}
func _current_badge_offset(cid: String) -> Vector2:
	var display := CustomMapCityBadges.config(doc.doc,cid)
	if display.get("mode","AUTO") == "MANUAL": return Vector2(float(display.offset_px[0]),float(display.offset_px[1]))
	var tag: Control = board._plaques.get(cid)
	return board._city_plaque_runtime.manual_offset(cid,tag.position+tag.size*0.5) if tag != null else Vector2.ZERO

func _show_badge_panel(cid: String) -> void:
	var runtime = board._city_plaque_runtime
	if runtime == null: return
	panel.show_badge(CustomMapCityBadges.config(doc.doc,cid),_current_badge_offset(cid),str(runtime._transport(cid).transport_mode))
	for axis in ["x", "y"]:
		panel.set_validator("badge_"+axis,func(v: float) -> String: return "名牌偏移超出可调整范围" if not is_finite(v) or absf(v)>1920.0 else "")

func _open_badge_import(cid: String) -> void:
	_commit_edits()
	_begin_badge_import_context(cid)
	if _badge_file == null:
		_badge_file = FileDialog.new(); _badge_file.name="BadgeImageFile"
		_badge_file.use_native_dialog=true
		_badge_file.canceled.connect(_end_badge_import)
		_badge_file.file_mode=FileDialog.FILE_MODE_OPEN_FILE; _badge_file.access=FileDialog.ACCESS_FILESYSTEM
		_badge_file.filters=PackedStringArray(["*.png,*.jpg,*.jpeg ; PNG / JPEG"])
		add_child(_badge_file)
		_badge_file.file_selected.connect(_import_badge_image)
	_badge_file.popup_centered_ratio(0.7)

func _begin_badge_import_context(cid: String) -> void:
	_badge_import_city = cid
	_badge_import_context = {"cid":cid,"map_id":doc.map_id(),"sha":doc.sha()}

func _end_badge_import() -> void:
	_badge_import_city = ""
	_badge_import_context.clear()
	_refresh_panel()

func _badge_context_valid(context: Dictionary) -> bool:
	return not context.is_empty() and str(context.map_id) == doc.map_id() and str(context.sha) == doc.sha() and str(context.cid) == str(panel.target) and (_base_content.get("cities", {}).has(str(context.cid)) or not Mutations.city(doc.doc,str(context.cid)).is_empty())

func _import_badge_image(source: String, library_rights := "private_unknown") -> void:
	var context := _badge_import_context.duplicate(true)
	if not _badge_context_valid(context):
		say("地图或选中的城市已改变，请重新选择名牌图片。")
		_end_badge_import(); return
	var pending := CustomMapLocalAssets.inspect_file(source,"badge_icon")
	pending.library_rights = library_rights
	pending.source_name = source.get_file().get_basename()
	if not pending.ok:
		panel.badge_import_message(str(pending.message), true)
		say(str(pending.message)); _end_badge_import(); return
	dialogs.confirm("badge_preview", "应用到：%s · 名牌图片" % _display_name(str(context.cid)), "确认后应用，可以撤销。真实交通角标始终保留。", [{"id":"cancel","text":"取消预览","kind":"safe"},{"id":"apply","text":"确认并应用","kind":"primary"}],
		func(choice: String) -> void:
			if choice == "apply": _apply_badge_image(context,pending)
			_end_badge_import(), ImageTexture.create_from_image(pending.image))

func _apply_badge_image(context: Dictionary, pending: Dictionary) -> void:
	if not _badge_context_valid(context):
		say("地图或选中的城市已改变，请重新预览。"); return
	var cid := str(context.cid)
	var candidate := CustomMapCityBadges.with_value(doc.doc,cid,"icon","IMAGE")
	candidate = CustomMapLocalAssets.candidate(candidate,cid.trim_prefix("x_"),pending,str(pending.get("library_rights","private_unknown")))
	if CustomMapSchema.canonical_text(candidate) == doc.canonical():
		_accept_badge({"ok":true,"doc":candidate}, "导入名牌图片"); return
	var shape := candidate.duplicate(true)
	shape.erase("assets"); CustomMapCityBadges.clear_image_dependencies(shape)
	var checked := Backend.validate_for_editing(board.base_layout,shape,board.geo,catalogue)
	if not checked.ok: say("地图校验未通过，图片没有应用。"); return
	var published := CustomMapAssetMeta.admit(pending,{"display_name":str(pending.get("source_name",pending.id)),"tags":[],"note":""},str(pending.get("library_rights","private_unknown")),"当前地图 · "+cid+" · 名牌图片")
	if not published.ok: say(str(published.message)); return
	_accept_badge(Mutations.finish(candidate,_base_content,board.base_layout,catalogue),"导入名牌图片")

func _accept_badge(result: Dictionary, label: String) -> bool:
	# Reapplying the same display setting is a true no-op, including workshop timestamps.
	if bool(result.get("ok",false)) and CustomMapSchema.canonical_text(result.doc) == doc.canonical():
		_refresh_panel()
		return true
	return _accept_mutation(result,label)

func _city_connection_names(cid: String) -> String:
	var names: Array[String]=[]
	for route in board.cur_layout.get("routes",[]):
		var ends: Array=board.geo.ends.get(str(route.id),["",""])
		var a: String=str(route.get("a",ends[0])); var b: String=str(route.get("b",ends[1]))
		if a==cid and b!="": names.append(_display_name(b))
		elif b==cid and a!="": names.append(_display_name(a))
	return "、".join(names) if not names.is_empty() else "尚无连线"

func _specialty_name(id: String) -> String:
	return str(CustomMapCatalogue.specialty(catalogue,id).get("display_name",id))

func _enter_free_author() -> void:
	_commit_edits();_end_placement();_chooser.hide()
	if CustomMapFreeAuthor.enabled(doc.doc):say("正在编辑自由作品，新城最多4座。");return
	var candidate:=CustomMapFreeAuthor.enter(doc.doc,_base_content)
	var result:=CustomMapFreeAuthor.finish(candidate,_base_content,board.base_layout,catalogue)
	if _accept_mutation(result,"建立自由作品副本"):say("已建立独立自由副本；已有新城的卡将按显式路网重新生成。原80牌保留原值。")
func _original_author_mode() -> void:
	if CustomMapFreeAuthor.enabled(doc.doc):
		_on_reset()
	else:say("原版兼容模式：保留原规则、宿主与搭档流程。")
func _preview_author_connection(host:String,rt:String) -> void:
	if not is_instance_valid(_connection_ui):return
	_connection_choice_changed()
	var epoch:=_connection_epoch;var source_sha:String=doc.sha();var cid:=_connection_city
	_connection_running=true;_connection_note.text="正在预览连接…"
	await get_tree().process_frame
	if not _connection_current(epoch,source_sha,cid):return
	var snapshot:Dictionary=doc.doc.duplicate(true);var geo:=CustomMapGeo.for_overlay(snapshot)
	var derived:=CustomBoardLayout.derive(board.base_layout,snapshot,geo,catalogue)
	# The search helper recognises new destinations through a speculative edge.
	# Route from an original endpoint toward a new endpoint when possible.
	var reverse:=cid.begins_with("x_") and not host.begins_with("x_")
	var source:String=host if reverse else cid
	var destination:String=cid if reverse else host
	var end:Dictionary=doc.city_pos(destination)
	var routing_cities:Dictionary={}
	for row:Dictionary in derived.cities:routing_cities[str(row.id)]=row
	derived=derived.duplicate(true)
	derived.routes.append({"id":"free_preview","a":source,"b":destination,"type":rt,"points":CustomBoardLayout.with_heights(CustomBoardLayout.spline_points(routing_cities[source],routing_cities[destination],[]),rt,geo)})
	var route:=CustomMapGeoRules.auto_route(derived,source,Vector2(float(end.x),float(end.z)),rt,geo)
	var edit:Dictionary={"handles":route.get("handles",[]) if route.get("ok",false) else [],"stop_t":route.get("stop_t",[0.333,0.667]) if route.get("ok",false) else [0.333,0.667]}
	if reverse and route.get("ok",false):
		edit.handles.reverse();edit.stop_t.reverse()
		for i:int in edit.stop_t.size():edit.stop_t[i]=1.0-float(edit.stop_t[i])
	var result:=CustomMapFreeAuthor.connect_cities(snapshot,cid,host,rt,edit,_base_content,board.base_layout,catalogue)
	if not _connection_current(epoch,source_sha,cid):return
	if not result.get("ok",false):_connection_failed(result,cid);return
	_connection_candidate={"epoch":epoch,"source_sha":source_sha,"cid":cid,"host":host,"transport":rt,"route":edit}
	var lay:=CustomBoardLayout.derive(board.base_layout,result.doc,geo,catalogue)
	var route_errors: Array=result.validation.errors.filter(func(e):return str(e.get("target",""))==str(result.route_id))
	board.show_connection_preview(lay,str(result.route_id),route_errors)
	_connection_running=false;_connection_confirm_button.disabled=false
	var mismatch:bool=_base_content.cities.has(host) and rt not in CustomMapFreeAuthor.routes_for(_base_content,snapshot,host)
	_connection_note.text="%s → %s\n%s · 尚未写入地图\n%s"%[_display_name(cid),_display_name(host),"陆路" if rt=="LAND" else "海路","已找到路径；下方显示最终检查结果。" if route.get("ok",false) else "未找到自动路径，预览为待调整草稿。"]
	if not route_errors.is_empty():
		_connection_note.text += "\n待修复：" + "；".join(route_errors.map(func(e):return _issue_message(e)))
	elif result.get("draft",false):_connection_note.text+="\n这条路已检查；地图还有其它待完成项。"
	else:_connection_note.text+="\n最终地图检查通过，可以通行。"
	_connection_confirm_button.text="存为待修复连线" if not route_errors.is_empty() else "确认连接"
	if mismatch:_connection_note.text+="\n可保留当前交通；确认后在右栏增开交通或改路。"

func _match_connection_medium() -> void:
	if not CustomMapFreeAuthor.enabled(doc.doc) or _connection_user_medium or _connection_targets.selected<0:return
	var host:=str(_connection_targets.get_item_metadata(_connection_targets.selected))
	var medium:=preload("res://scripts/map_workshop/workshop_route_feedback.gd").preferred_medium(_base_content,doc.doc,_connection_city,host,"LAND" if _connection_modes.selected==0 else "SEA")
	_connection_modes.select(0 if medium=="LAND" else 1)

func _issue_message(issue:Dictionary) -> String:
	if str(issue.get("code",""))=="E_FREE_TRANSPORT":return "%s不支持%s"%[_display_name(str(issue.get("endpoint_city","城市"))),"陆路" if str(issue.get("medium","LAND"))=="LAND" else "海路"]
	return str(issue.get("kid",issue.get("tech","需要检查")))

func _issue_location(issue:Dictionary) -> Dictionary:
	var location:=preload("res://scripts/map_workshop/workshop_route_feedback.gd").locate(board.cur_layout,issue)
	return _resolve_problem_target(str(issue.get("target",""))) if location.is_empty() else location

func _locate_issue(issue:Dictionary) -> void:
	var location:=_issue_location(issue)
	if location.is_empty():panel.scroll_to_top();say(_issue_message(issue));return
	panel.suspend_edits()
	board.select(str(location.kind),str(location.id))
	board.focus_position(location.anchor)
	_refresh_panel();panel.scroll_to_top();say(_issue_message(issue))

func _refresh_object_feedback() -> void:
	var selected:Dictionary=board.sel;var relevant:Array=[]
	for issue:Dictionary in issues:
		var location:=_issue_location(issue)
		if str(issue.get("target",""))==str(selected.get("id","")) or (not location.is_empty() and str(location.id)==str(selected.get("id",""))):relevant.append(issue)
	var rows:=_problem_rows(relevant,"error","map")
	for row:Dictionary in rows:
		row.kid=_issue_message(row);row.repairs=[]
		if str(row.get("code",""))=="E_FREE_TRANSPORT" and CustomMapFreeAuthor.enabled(doc.doc):
			var medium:=str(row.get("medium","LAND"));var other:="SEA" if medium=="LAND" else "LAND"
			row.repairs.append({"text":"改成海路" if other=="SEA" else "改成陆路","action":"fix_medium:"+str(row.target)+":"+other})
			row.repairs.append({"text":"增开交通并换乘","action":"fix_transport:"+str(row.get("endpoint_city",""))})
		elif str(selected.get("kind",""))=="route":row.repairs.append({"text":"调整曲线","action":"route_focus"})
	var next_step:=CustomMapFreeAuthor.enabled(doc.doc) and str(selected.get("kind",""))=="city" and str(selected.get("id","")).begins_with("x_") and CustomMapFreeAuthor.routes_for(_base_content,doc.doc,str(selected.id)).is_empty()
	panel.show_object_feedback(rows,next_step)

func _repair_route_medium(rid:String,medium:String) -> void:
	if not CustomMapFreeRoutes.enabled(doc.doc) or medium not in ["LAND","SEA"]:return
	var candidate:Dictionary=doc.doc.duplicate(true);var patch:Dictionary=candidate.free_routes.routes.get(rid,{}).duplicate(true)
	patch.type=medium;candidate.free_routes.routes[rid]=patch
	var result:=CustomMapFreeRoutes.finish(candidate,_base_content,board.base_layout,catalogue)
	if _accept_mutation(result,"修改路线交通"):
		board.select("route",rid)
		say("已修改交通；还有问题时会保留局部标记，可继续调整或撤销。" if not issues.is_empty() else "已修改交通，检查通过；可以撤销。")
