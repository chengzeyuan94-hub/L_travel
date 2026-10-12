extends Control
## 右栏（挎包面板，DESIGN 3.12.2、3.12.9）：x 1400–1920、y 96–1080 的设计像素。
##   【属性】y 116–760：标题行 + 行高 56 的属性行（标签列 120、数值列 336），底部一行固定按钮不跟着滚动；
##   【卡片】y 760–1080：页签 40 px；「城市卡」页直接放游戏里的 formal_city_card.tscn（0.19 倍，206×275），点它看大图；
##          「贸易卡」页读取 Loader 的真实牌组，逐张预览牌面资源及交换方向。
## 选择主要靠在视口里点模型；右栏只是辅助：没选中时是「这张地图」，选中城 / 路 / 停靠点时是它的属性。
## 数字框照 C4D 属性管理器（workshop_numfield.gd），离开即生效；只读的字是灰的。
## 同一个对象的属性只就地更新数值（update_original_city），不重建：重建会把正拿着焦点的框拆掉，按 Tab 就跳不到下一个框，
## 点「放回原处」这类不抢焦点的按钮时，框里没提交的字还会在拆的半路上提交。只有换了选中的对象才整栏重建（_begin），
## 重建前先把旧框 detach()，被拆掉的框永远不提交。

## target = 这个框属于哪个对象（建框时记下的，不看提交那一刻选中的是谁：换选中时旧框的字要落在旧对象上）
signal field_committed(target: String, field: String, value: float)
signal text_committed(target: String, field: String, value: String)
signal field_rejected(reason: String)
signal field_repaired
signal action(name: String)
signal card_enlarge(city_id: String)

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const NumField := preload("res://scripts/map_workshop/workshop_numfield.gd")
const CITY_CARD := preload("res://scenes/ui/components/formal_city_card.tscn")
const Icons := preload("res://scripts/lshu_ui/lshu_icons.gd")
const SIZE := Vector2(400, 952)
const PROPS_TOP := 20.0              # 116 − 96
const PROPS_BOTTOM := 632.0          # 760 − 96
const ROW_H := 56.0
const LABEL_W := 90.0
const VALUE_W := 250.0
const GREY := Color("#9A8B7C")
const RED := Color("#CD483A")
const GREEN := Color("#5E9E4E")

var kind := ""
var target := ""
var fields := {}                     # "x" / "z" / "rotation" -> NumField
var text_fields := {}                # "name" / "intro" -> LineEdit
var _text_values := {}               # 文档里的值；保留草稿时也随撤销 / 外部刷新更新
var _text_generation := 0            # 换对象后，旧输入框的失焦信号不再提交
var _discarding_text := false
var _text_validators: Dictionary = {}
var _name_drafts: Dictionary = {} # target -> exact unsubmitted text, including invalid/pasted text
var _name_problem := ""
var _number_drafts: Dictionary = {}
var _draft_context := ""
var _new_nodes := {}
var _reset_btn: Button               # 原版城底部的「放回原处」
var _feedback: VBoxContainer
var _feedback_height := 0.0
var _rows: VBoxContainer
var _scroll: ScrollContainer
var _bottom: HBoxContainer
var _tabs: HBoxContainer
var _tab_buttons := {}
var _card_host: Control
var _card_separator: Control
var _groups: Dictionary = {}
var _card: Control
var _card_note: Label
var _tab := "city"
var _content: Dictionary = {}
var _trade_pages: Dictionary = {}
var _trade_choices: Dictionary = {}
var _trade_preview: Dictionary = {}
var _trade_identity := ""

func _set_content(content: Dictionary) -> void:
	var identity := var_to_str([content.get("trade_decks", {}), content.get("trade_card_index", {}), content.get("custom_map", {}).get("tradegen", ""),content.get("custom_map",{}).get("editor_trade_ready",false)]).sha256_text()
	if identity != _trade_identity:
		_trade_choices.clear()
		_trade_preview.clear()
		_card_key = ""
		_trade_identity = identity
	_content = content
	if _tab_buttons.has("trade"):
		_tab_buttons.trade.disabled=not _trade_available()
		_tab_buttons.trade.tooltip_text=str(content.get("custom_map",{}).get("editor_trade_reason","")) if not _trade_available() else "查看当前地图的真实贸易卡与交换方向"
	if not _trade_available():_tab="city"


func _trade_available()->bool:
	var custom:Dictionary=_content.get("custom_map",{})
	return not custom.get("editor_draft",false) or custom.get("editor_trade_ready",false)


func _ready() -> void:
	size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Kit.CREAM
	sb.border_color = Kit.SATCHEL
	sb.border_width_left = 5
	sb.shadow_color = Color(0.2, 0.12, 0.06, 0.25)
	sb.shadow_size = 14
	bg.add_theme_stylebox_override("panel", sb)
	bg.size = SIZE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_feedback=VBoxContainer.new();_feedback.name="ObjectFeedback";_feedback.position=Vector2(28,PROPS_TOP);_feedback.custom_minimum_size.x=SIZE.x-60;_feedback.add_theme_constant_override("separation",8);add_child(_feedback)
	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(28, PROPS_TOP)
	_scroll.size = Vector2(SIZE.x - 44, PROPS_BOTTOM - PROPS_TOP - 92)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 0)
	_rows.custom_minimum_size.x = SIZE.x - 60
	_scroll.add_child(_rows)
	_bottom = HBoxContainer.new()
	_bottom.position = Vector2(28, PROPS_BOTTOM - 84)
	_bottom.size = Vector2(SIZE.x - 56, 72)
	_bottom.add_theme_constant_override("separation", 14)
	add_child(_bottom)
	var line := ColorRect.new()
	_card_separator = line
	line.color = Kit.SATCHEL.lightened(0.45)
	line.position = Vector2(20, PROPS_BOTTOM - 1)
	line.size = Vector2(SIZE.x - 40, 2)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)
	_tabs = HBoxContainer.new()
	_tabs.position = Vector2(28, PROPS_BOTTOM + 2)
	_tabs.size = Vector2(SIZE.x - 56, 40)
	_tabs.add_theme_constant_override("separation", 10)
	add_child(_tabs)
	for t in [["city", "城市卡"], ["trade", "贸易卡"]]:
		var b := Kit.button(String(t[1]), "cream", 40, 20)
		b.custom_minimum_size.x = 120
		b.pressed.connect(func() -> void: _set_tab(String(t[0])))
		_tabs.add_child(b)
		_tab_buttons[t[0]] = b
	_card_host = Control.new()
	# 卡片区 y 760–1080：页签 40 px，下面 280 px 正好放下 0.19 倍的城市卡（206×275）
	_card_host.position = Vector2(28, PROPS_BOTTOM + 44)
	_card_host.size = Vector2(SIZE.x - 56, SIZE.y - (PROPS_BOTTOM + 44))
	_card_host.clip_contents = true
	add_child(_card_host)
	_card_host.resized.connect(func()->void:
		_card_key=""
		if _tab=="trade":_show_card(target if kind in ["city","new_city"] else ""))
	_set_tab("city")


# ------------------------------------------------------------------ 四种内容
## 没选中任何东西：「这张地图」（3.12.2）
## info: {east, west, rows: [{id, name, side, partner}], issues: [{kid, target}], counts_win, edits, can_reset_all}
func show_map(info: Dictionary) -> void:
	_begin("map", "")
	_title("这张地图", [])
	_problem_rows(info.get("issues", []), "地图错误", RED)
	_problem_rows(info.get("action_issues", []), "未应用的修改", RED)
	_text("选择城市或路线，开始编辑。", 22, Kit.INK)
	if info.get("author_mode",false):
		_text("自由作品 · 未平衡：原80张牌保持原值，新卡按实际路网生成；不计胜场。",20,Kit.INK_SOFT)
	else:
		var recovery := _action_button("地图规则 · 版本与卡片", "upgrade_rules")
		recovery.name = "RuleRecoveryButton"
		_rows.add_child(recovery)
	for r:Dictionary in info.get("deleted_routes",[]):
		_rows.add_child(_action_button("恢复 " + str(r.label), "route_restore:"+str(r.id)))
	_text("新增城市 · 点选查看", 20, Kit.INK_SOFT)
	var rows: Array = info.get("rows", [])
	if rows.is_empty():
		_text("从左侧「加城」开始，也可以在地图上选中原有城市或路线。", 22, Kit.INK)
	for r: Dictionary in rows:
		var b := Kit.button("%s   %s ⇄ %s" % [r.name, r.side, r.partner], "cream", 64, 22)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void: action.emit("goto:" + String(r.id)))
		_rows.add_child(b)
	_gap(10)
	var e := int(info.get("east", 0))
	var w := int(info.get("west", 0))
	if info.get("author_mode",false):
		_text("新城 %d/4 · 无需宿主或搭档"%rows.size(),22,Kit.INK)
	else:
		_text("东边 %d 座 · 西边 %d 座  %s" % [e, w, "✓ 伙伴数量一致；贸易与路程另行校验" if e == w else "✗ 两边不一样多"], 22, GREEN if e == w else RED)
	var issues: Array = info.get("issues", [])
	if issues.is_empty():
		_kv("地图检查", "✓ 当前地图没有错误", GREEN)
	_problem_rows(info.get("warnings", []), "地图警告", Color("#976214"))
	if not bool(info.get("counts_win", true)):
		_text("自制地图的试玩不计入胜场。", 20, Kit.INK_SOFT)
	var edits := String(info.get("edits", ""))
	if edits != "":
		_text("已调整：%s" % edits, 20, Kit.INK_SOFT)
	var b := Kit.button("全部放回原处", "cream", 64, 24)
	b.disabled = not bool(info.get("can_reset_all", false))
	b.pressed.connect(func() -> void: action.emit("reset_all"))
	if bool(info.get("can_reset_all", false)):
		_bottom.add_child(b)
	else:
		b.queue_free()
	_show_card("")


## Each row retains its validator level/scope. Only a real current-layout target can be located.
func _problem_rows(problems: Array, title: String, color: Color) -> void:
	if problems.is_empty():
		return
	_text("%s（%d）" % [title, problems.size()], 22, color)
	for issue: Dictionary in problems:
		var row := VBoxContainer.new()
		row.name = "ProblemRow"
		row.set_meta("problem", issue.duplicate(true))
		row.add_theme_constant_override("separation", 4)
		_rows.add_child(row)
		var message := String(issue.get("kid", "")).strip_edges()
		if message.is_empty():
			message = String(issue.get("tech", issue.get("code", "需要检查")))
		var row_color := Kit.INK_SOFT if issue.get("pending",false) else color
		var label := Kit.label(("待完成 · " if issue.get("pending",false) else "")+message, 22, row_color)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(label)
		var detail := String(issue.get("tech", "")).strip_edges()
		if not detail.is_empty() and detail != message:
			var explanation := Kit.label(detail, 18, Kit.INK_SOFT)
			explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			row.add_child(explanation)
		var go := Kit.button("带我去看" if bool(issue.get("locatable", false)) else "全局问题 · 无定位目标", "cream", 44, 20)
		go.name = "IssueGotoButton"
		go.set_meta("problem", issue.duplicate(true))
		go.set_meta("readonly_location", true)
		go.disabled = not bool(issue.get("locatable", false))
		go.pressed.connect(func() -> void: action.emit("issue:"+str(issue.issue_index) if int(issue.get("issue_index",-1))>=0 else "goto:"+str(issue.get("target",""))))
		row.add_child(go)
		_gap(6)


## 选中一座原版城（3.12.9「原版城」）：名字、特产只读；位置、朝向可以改；底部「放回原处」
## info: {id, name, transport, side, specialty, specialty_icon, x, z, rotation, moved}
func show_original_city(info: Dictionary, content: Dictionary) -> void:
	_begin("city", String(info.id))
	var tport := "陆地城 · 骆驼" if String(info.transport) == "CAMEL" else "海港城 · 商船"
	_new_nodes.title = _title(String(info.name), [tport, String(info.side)])
	_row("名字").add_child(_text_field("name", String(info.name)))
	_new_nodes.name_problem = Kit.label("",20,RED)
	_new_nodes.name_problem.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rows.add_child(_new_nodes.name_problem)
	var sp := _kv("特产", String(info.specialty), GREY)
	_new_nodes.specialty_row = sp
	var icon: Texture2D = info.get("specialty_icon")
	if icon != null:
		var t := TextureRect.new()
		t.texture = icon
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.custom_minimum_size = Vector2(40, 40)
		sp.add_child(t)
		sp.move_child(t, 1)
	var position_start := _rows.get_child_count()
	for f in ["x", "z"]:
		_row("位置 " + f.to_upper()).add_child(_numfield(f, float(info[f]), 0.1, 2, 150.0))
	var rot := _row("朝向")
	var nr := _numfield("rotation", rad_to_deg(float(info.rotation)), 1.0, 0, 104.0)
	rot.add_child(nr)
	rot.add_child(Kit.label("°", 22, Kit.INK_SOFT))
	_gap(6)
	_text("城市地理位置离老家 6 格以内；名牌位置可单独拖动。", 20, Kit.INK_SOFT)
	_reset_btn = Kit.button("放回原处", "cream", 64, 24)
	_reset_btn.disabled = not bool(info.get("moved", false))
	_reset_btn.pressed.connect(func() -> void: action.emit("reset_city"))
	_bottom.add_child(_reset_btn)
	_set_content(content)
	if not _trade_available():_tab="city"
	_show_card(String(info.id))
	_group_span("地图位置",position_start,_rows.get_child_count(),true)
	_group_span("基础",1,position_start,true)
	var start := _rows.get_child_count()
	_kv("接在哪",str(info.get("connections","原版连接")),GREY)
	if info.get("author_mode",false):
		_rows.add_child(_action_button("连接城市","author_connect"))
		_new_nodes.transport_note=Kit.label("自由作品增开：海陆交通与换乘" if info.get("transport_override",false) else "原城交通保持；可以为这份自由作品增开。",20,Kit.INK_SOFT)
		_new_nodes.transport_note.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
		_rows.add_child(_new_nodes.transport_note)
		_rows.add_child(_action_button("增开海陆交通并换乘","enable_transport"))
	_group_span("连接",start,_rows.get_child_count(),true)
	_rows.move_child(_groups["连接"].root,2)


## 还是这座原版城（挪了、撤销了、别的框提交了）：只就地换数值和「放回原处」能不能点，不重建
func update_original_city(info: Dictionary) -> void:
	if kind != "city" or target != String(info.id):
		return
	if _new_nodes.has("transport_note"):
		_new_nodes.transport_note.text="自由作品增开：海陆交通与换乘" if info.get("transport_override",false) else "原城交通保持；可以为这份自由作品增开。"
	if fields.has("x"):
		(fields.x as NumField).set_value(float(info.x))
		(fields.z as NumField).set_value(float(info.z))
		(fields.rotation as NumField).set_value(rad_to_deg(float(info.rotation)))
	if _reset_btn != null and is_instance_valid(_reset_btn):
		_reset_btn.disabled = not bool(info.get("moved", false))


## 新城：同一对象只原位刷新。正在输入的草稿与焦点保留；换对象前由主控提交或丢弃。
func show_new_city(info: Dictionary, content: Dictionary) -> void:
	if not shows("new_city", String(info.id)):
		_begin("new_city", String(info.id))
		_new_nodes.title = _title(String(info.name), [])
		_row("名字").add_child(_text_field("name", String(info.name)))
		_new_nodes.name_problem = Kit.label("", 20, RED)
		_new_nodes.name_problem.name = "NameProblemLabel"
		_new_nodes.name_problem.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rows.add_child(_new_nodes.name_problem)
		var look := _row("外观")
		_new_nodes.look = _value_label(look)
		look.add_child(_action_button("换外观", "change_look"))
		var sp := _row("特产")
		var icon := TextureRect.new()
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(36, 36)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sp.add_child(icon)
		_new_nodes.icon = icon
		_new_nodes.good = _value_label(sp)
		sp.add_child(_action_button("换特产", "change_good"))
		_new_nodes.host = _value_label(_row("接在哪"))
		_new_nodes.connection = _action_button("连接另一座城", "extra_connection")
		_rows.add_child(_new_nodes.connection)
		_new_nodes.remove_connection = _action_button("移除额外连接（可撤销）", "remove_connection")
		_rows.add_child(_new_nodes.remove_connection)
		_new_nodes.partner = _value_label(_row("搭档"))
		for f in ["x", "z"]:
			_row("位置 " + f.to_upper()).add_child(_numfield(f, float(info[f]), 0.1, 2, 150.0))
		var rot := _row("朝向")
		rot.add_child(_numfield("rotation", rad_to_deg(float(info.rotation)), 1.0, 0, 104.0))
		rot.add_child(Kit.label("°", 22, Kit.INK_SOFT))
		var scale_row := _row("大小")
		scale_row.add_child(_numfield("size", float(info.get("size", 1.0)), 0.01, 2, 104.0))
		scale_row.add_child(Kit.label("倍", 20, Kit.INK_SOFT))
		_text("大小范围：0.90–1.10", 20, Kit.INK_SOFT)
		_row("介绍").add_child(_text_field("intro", String(info.get("intro", ""))))
		(text_fields.intro as LineEdit).placeholder_text = "自动生成；也可以自己写一句"
		_new_nodes.text_note = _value_label(_row("卡片文字"))
		_new_nodes.reset_text = _action_button("恢复自动介绍", "reset_text")
		_rows.add_child(_new_nodes.reset_text)
		_new_nodes.origin_note = Kit.label("", 20, Kit.INK_SOFT)
		_new_nodes.origin_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_new_nodes.origin_note.custom_minimum_size.x = SIZE.x - 64
		_rows.add_child(_new_nodes.origin_note)
		_new_nodes.remove_pair = _action_button("拆掉这一对城", "remove_pair", 64)
		_bottom.add_child(_new_nodes.remove_pair)
		_group_span("卡片",14,18,false)
		_group_span("地图位置",9,14,true)
		_group_span("连接",5,9,true)
		_group_span("基础",1,5,true)
		_new_nodes.remove_pair.reparent(_groups["卡片"].body)
		_danger_style(_new_nodes.remove_pair)
		_danger_style(_new_nodes.remove_connection)
	_update_new_city(info)
	_set_content(content)
	if not _trade_available():_tab="city"
	_show_card(String(info.id))


func _update_new_city(info: Dictionary) -> void:
	_new_nodes.title.text = String(info.name)
	_new_nodes.look.text = String(info.get("archetype_name", ""))
	_new_nodes.good.text = String(info.get("specialty_name", ""))
	_new_nodes.icon.texture = info.get("specialty_icon")
	_new_nodes.icon.visible = _new_nodes.icon.texture != null
	_new_nodes.host.text = "%s · %s" % [info.get("host_name", ""), info.get("side", "")]
	_new_nodes.partner.text = String(info.get("partner_name", ""))
	_new_nodes.connection.disabled = bool(info.get("has_extra_connection", false))
	_new_nodes.remove_connection.visible = bool(info.get("has_extra_connection", false))
	_new_nodes.connection.text = "已有额外连接 · 可先移除" if _new_nodes.connection.disabled else "连接另一座城"
	_new_nodes.connection.tooltip_text = "先点下方「移除额外连接」，再预览另一条" if _new_nodes.connection.disabled else "先选择目标并完整校验；确认才增加一条连接"
	if info.get("free_mode",false):
		_new_nodes.connection.disabled=false;_new_nodes.connection.text="编辑城市连线";_new_nodes.connection.tooltip_text="选择连线，预览延长或改接后再确认"
		_new_nodes.remove_connection.visible=int(info.get("active_link_count",0))>0;_new_nodes.remove_connection.text="删除一条连线（先预览）"
	else:_new_nodes.remove_connection.text="移除额外连接（可撤销）"
	for f in ["x", "z", "size"]:
		(fields[f] as NumField).set_value(float(info.get(f, 1.0 if f == "size" else 0.0)))
	(fields.rotation as NumField).set_value(rad_to_deg(float(info.rotation)))
	for f in ["name", "intro"]:
		_set_text_value(f, String(info.get(f, "")))
	var automatic := String(info.get("text_mode", "AUTO")) == "AUTO"
	_new_nodes.text_note.text = "随外观和特产自动生成" if automatic else "用了你写的介绍"
	_new_nodes.reset_text.disabled = automatic
	var user_city := String(info.get("origin", "AUTO")) == "USER"
	_new_nodes.remove_pair.visible = user_city
	_new_nodes.origin_note.text = "拆城会连同搭档一起拆掉；可以撤销。" if user_city else "这是系统补的搭档。想拆掉这一对，请选「%s」。" % String(info.get("partner_name", ""))
	if info.get("author_mode",false):
		_new_nodes.host.text=String(info.get("host_name","尚未连接"));_new_nodes.partner.text="无需搭档"
		_new_nodes.connection.text="连接城市";_new_nodes.connection.tooltip_text="选择任意城市与交通；确认后可撤销"
		_new_nodes.remove_pair.text="删除这座城市"
		_new_nodes.origin_note.text="先放城、再连线、最后修地形。冲突可保存；正式试玩须全部修复。"


## 右栏现在显示的是不是这个对象
func shows(k: String, id: String) -> bool:
	return kind == k and target == id


## 选中路线（3.12.9「路线」）：只读；原版路的「恢复原样」、新路的「帮我重画」等改路形接上后再出
func show_route(info: Dictionary) -> void:
	_begin("route", String(info.id))
	_new_nodes.title = _title("%s — %s" % [info.a, info.b], [])
	_kv("通行", "%s · %d 步" % ["陆路" if String(info.type) == "LAND" else "海路",int(info.get("steps",3))], Kit.INK)
	_text("拖白点调弯，拖金币调整站位。曲线长短不改变步数。",20,Kit.INK_SOFT)
	_text("形状",22,Kit.SATCHEL_DEEP)
	for spec:Array in [["route_focus","放大这条路线"],["route_add_point","＋ 控制点"],["route_delete_point","删除选中控制点"],["route_reset","恢复形状"]]:
		_rows.add_child(_action_button(str(spec[1]),str(spec[0])))
	_gap(12); _text("连接",22,Kit.SATCHEL_DEEP)
	_rows.add_child(_action_button("延长 / 改接","route_extend"))
	_gap(28); _text("删除",22,RED)
	var remove := _action_button("删除整条路线","route_delete")
	_danger_style(remove); _rows.add_child(remove)
	var actions: Array[Button]=[]
	for node in _rows.get_children():
		if node is Button: actions.append(node)
	for i in actions.size()-1:
		actions[i].focus_next=actions[i].get_path_to(actions[i+1])
		actions[i+1].focus_previous=actions[i+1].get_path_to(actions[i])


## 选中停靠点：「长安—玉门关 · 第 1 站」和位置比例
func show_stop(info: Dictionary) -> void:
	_begin("stop", String(info.id))
	_new_nodes.title = _title("停靠点", [])
	_kv("在哪", "%s—%s · 第 %d 站" % [info.a, info.b, int(info.index)], Kit.INK)
	_kv("位置", "这条路的 %d%%" % int(round(float(info.t) * 100.0)), Kit.INK)
	_show_card("")


## 拖动中：数字框跟着显示（只显示，不提交）
func show_live(x: float, z: float, rotation: float) -> void:
	if fields.has("x"):
		(fields.x as NumField).set_value(x)
		(fields.z as NumField).set_value(z)
		(fields.rotation as NumField).set_value(rad_to_deg(rotation))


## 有输入框正在编辑、且有没提交的字（⌘Z 这时让给输入框）
func has_uncommitted_edit() -> bool:
	for f in fields.values():
		if (f as NumField).has_uncommitted_edit():
			return true
	for field in text_fields:
		var edit: LineEdit = text_fields[field]
		if edit.has_focus() and edit.text != String(_text_values.get(field, "")):
			return true
	return false


func editing_field() -> Control:
	for f in fields.values():
		if (f as NumField).edit.has_focus():
			return f
	for edit: LineEdit in text_fields.values():
		if edit.has_focus():
			return edit
	return null


## Esc：丢掉没提交的字、结束编辑
func discard_edits() -> void:
	_name_drafts.erase(target)
	_number_drafts.erase(target)
	for f in fields.values():
		(f as NumField).discard_edit()
	_discarding_text = true
	for field in text_fields:
		var edit: LineEdit = text_fields[field]
		edit.text = String(_text_values.get(field, ""))
		edit.release_focus()
	_discarding_text = false
	_update_name_problem()


## Read-only navigation suspends drafts; only explicit cancel discards them.
func suspend_edits() -> void:
	_remember_name_draft()
	for f in fields.values():
		(f as NumField).suspend_edit()
	_remember_number_drafts()
	_discarding_text = true
	for edit: LineEdit in text_fields.values():
		edit.release_focus()
	_discarding_text = false


func set_draft_context(map_id: String) -> void:
	if map_id != _draft_context:
		clear_text_drafts()
		_draft_context = map_id


func clear_text_drafts() -> void:
	discard_edits()
	_name_drafts.clear()
	_number_drafts.clear()


func _remember_number_drafts() -> void:
	var drafts: Dictionary = _number_drafts.get(target, {})
	for field in fields:
		var nf: NumField = fields[field]
		if nf.has_suspended_draft(): drafts[field] = nf.edit.text
		else: drafts.erase(field)
	if drafts.is_empty(): _number_drafts.erase(target)
	else: _number_drafts[target] = drafts


func has_ime_composition() -> bool:
	for edit: LineEdit in text_fields.values():
		if edit.has_focus() and edit.has_ime_text():
			return true
	return false


func _remember_name_draft() -> void:
	if text_fields.has("name"):
		var edit: LineEdit = text_fields.name
		if edit.text != String(_text_values.get("name", "")):
			_name_drafts[target] = edit.text
		else:
			_name_drafts.erase(target)


func _update_name_problem() -> void:
	if not text_fields.has("name") or not _new_nodes.has("name_problem"):
		return
	var edit: LineEdit = text_fields.name
	if edit.has_ime_text():
		return # Composition belongs to the IME; never trim, replace, or commit it.
	var fn: Callable = _text_validators.get("name", Callable())
	var reason: String = fn.call(edit.text) if fn.is_valid() else ""
	var was_invalid := not _name_problem.is_empty()
	_name_problem = reason
	_new_nodes.name_problem.text = reason
	_new_nodes.name_problem.visible = not reason.is_empty()
	edit.add_theme_color_override("font_color", RED if not reason.is_empty() else Kit.INK)
	if was_invalid and reason.is_empty():
		field_repaired.emit()


# ------------------------------------------------------------------ 零件
func _begin(k: String, id: String) -> void:
	var changed := kind != k or target != id
	_remember_number_drafts()
	_remember_name_draft()
	_name_problem = ""
	if changed: scroll_to_top()
	# 旧框先拆下来（不再提交），再释放
	_text_generation += 1
	for edit: LineEdit in text_fields.values():
		edit.release_focus()
	text_fields.clear()
	_text_values.clear()
	_new_nodes.clear()
	for f in fields.values():
		(f as NumField).detach()
	kind = k
	target = id
	_groups.clear()
	var show_cards := k in ["city", "new_city", "map"]
	_tabs.visible=show_cards; _card_host.visible=show_cards; _card_separator.visible=show_cards
	_scroll.size.y=PROPS_BOTTOM-PROPS_TOP-92 if show_cards else SIZE.y-PROPS_TOP-30
	fields.clear()
	_text_validators.clear()
	_reset_btn = null
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	for c in _bottom.get_children():
		_bottom.remove_child(c)
		c.queue_free()


func _title(text: String, tags: Array) -> Label:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 64)
	row.add_theme_constant_override("separation", 10)
	var t := Kit.label(text, 30, Kit.SATCHEL_DEEP, "body", 700)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.clip_text = true
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(t)
	_rows.add_child(row)
	if not tags.is_empty():
		var tag_row := HBoxContainer.new()
		tag_row.add_theme_constant_override("separation", 8)
		_rows.add_child(tag_row)
		for tag in tags:
			var p := PanelContainer.new()
			var sb := Kit.pill_box(12, 4)
			sb.bg_color = Kit.CREAM_DEEP
			sb.shadow_size = 0
			p.add_theme_stylebox_override("panel", sb)
			p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			p.add_child(Kit.label(String(tag), 20, Kit.SATCHEL_DEEP))
			tag_row.add_child(p)
	return t


func _value_label(row: HBoxContainer) -> Label:
	var label := Kit.label("", 22, Kit.INK)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	return label


func _action_button(text: String, action_name: String, height := 44) -> Button:
	var button := Kit.button(text, "cream", height, 20)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(func() -> void: action.emit(action_name))
	return button


func _text_field(field: String, value: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.custom_minimum_size = Vector2(0, 44)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	edit.add_theme_font_override("font", Kit.font("body", 600))
	edit.add_theme_font_size_override("font_size", 22)
	edit.add_theme_color_override("font_color", Kit.INK)
	for style in ["normal", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color("#FFFDF7")
		box.border_color = Kit.OCHRE if style == "focus" else Kit.SATCHEL.lightened(0.35)
		box.set_border_width_all(2)
		box.set_corner_radius_all(10)
		box.content_margin_left = 10
		box.content_margin_right = 10
		edit.add_theme_stylebox_override(style, box)
	edit.text = String(_name_drafts.get(target, value)) if field == "name" else value
	edit.select_all_on_focus = true
	edit.context_menu_enabled = false
	text_fields[field] = edit
	_text_values[field] = value
	var tgt := target
	var generation := _text_generation
	if field == "name":
		edit.text_changed.connect(func(_text: String) -> void:
			if generation == _text_generation and not _discarding_text:
				_remember_name_draft()
				_update_name_problem())
	var commit := func() -> void:
		if generation != _text_generation or _discarding_text or not edit.is_inside_tree() or edit.has_ime_text():
			return
		if edit.text == String(_text_values.get(field, "")):
			return
		var validator: Callable = _text_validators.get(field, Callable())
		var reason: String = validator.call(edit.text) if validator.is_valid() else ""
		if reason != "":
			if field == "name":
				_remember_name_draft()
				_update_name_problem()
			else:
				edit.text = String(_text_values.get(field, ""))
			field_rejected.emit(reason)
			return
		if field == "name":
			_name_drafts.erase(tgt)
			_update_name_problem()
		# 先记录提交值：同步刷新可把校验失败的值还原，也不会再次提交。
		_text_values[field] = edit.text
		text_committed.emit(tgt, field, edit.text)
	edit.text_submitted.connect(func(_text: String) -> void: commit.call())
	edit.focus_exited.connect(commit)
	return edit


func _set_text_value(field: String, value: String) -> void:
	var edit: LineEdit = text_fields[field]
	var typing := (edit.has_focus() or (field == "name" and _name_drafts.has(target))) and edit.text != String(_text_values.get(field, ""))
	_text_values[field] = value
	if not typing and edit.text != value:
		edit.text = value


func _row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_H)
	row.add_theme_constant_override("separation", 8)
	var l := Kit.label(label_text, 22, Kit.INK_SOFT)
	l.custom_minimum_size = Vector2(LABEL_W, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	_rows.add_child(row)
	return row


func _kv(label_text: String, value: String, color: Color) -> HBoxContainer:
	var row := _row(label_text)
	var v := Kit.label(value, 22, color)
	v.custom_minimum_size = Vector2(0, 0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(v)
	return row


func _text(text: String, px: int, color: Color) -> void:
	var l := Kit.label(text, px, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(SIZE.x - 64, 0)
	_rows.add_child(l)
	_gap(6)


func _gap(h: float) -> void:
	var g := Control.new()
	g.custom_minimum_size = Vector2(0, h)
	_rows.add_child(g)


func _numfield(field: String, v: float, step: float, decimals: int, width: float) -> NumField:
	var nf := NumField.new(width, 22)
	nf.step = step
	nf.decimals = decimals
	if field == "size":
		nf.min_value = 0.90
		nf.max_value = 1.10
	nf.set_value(v)
	if _number_drafts.get(target, {}).has(field):
		nf.restore_draft(String(_number_drafts[target][field]))
	nf.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var tgt := target
	nf.committed.connect(func(val: float) -> void:
		if _number_drafts.has(tgt): _number_drafts[tgt].erase(field)
		field_committed.emit(tgt, field, deg_to_rad(val) if field == "rotation" else val))
	nf.rejected.connect(func(why: String) -> void: field_rejected.emit(why))
	nf.repaired.connect(func() -> void: field_repaired.emit())
	fields[field] = nf
	return nf


## 数字框的「合不合格」由根节点给（用和拖动同一套几何检查）
func set_validator(field: String, fn: Callable) -> void:
	if fields.has(field):
		(fields[field] as NumField).validator = fn


func set_text_validator(field: String, fn: Callable) -> void:
	_text_validators[field] = fn
	if field == "name": _update_name_problem()


# ------------------------------------------------------------------ 卡片区
func _set_tab(t: String) -> void:
	if t=="trade" and not _trade_available():t="city"
	_tab = t
	for k in _tab_buttons:
		var b: Button = _tab_buttons[k]
		b.modulate = Color.WHITE if k == t else Color(1, 1, 1, 0.6)
	_show_card(target if kind in ["city", "new_city"] else "")


var _card_key := ""


func _show_card(city_id: String) -> void:
	# 内容可原位改变（改名、介绍、特产、插画）；只按 city_id 缓存会留着旧卡。
	var resolved := FormalCardPresentationResolver.resolve_city_card(_content, city_id) if city_id != "" else {}
	var city: Dictionary = _content.get("cities", {}).get(city_id, {})
	var deck_id := str(city.get("trade_color_id", ""))
	var deck: Dictionary = _content.get("trade_decks", {}).get(deck_id, {})
	var key := "%s|%s|%s|%s" % [city_id, kind, _tab, var_to_str([resolved, _content.get("resources", {}), _content.get("goods", {}), deck,
		_content.get("trade_card_index", {}), _trade_pages.get(deck_id, 0), _trade_choices,_card_host.size]).hash()]
	if key == _card_key and _card_host.get_child_count() > 0:
		return
	_card_key = key
	for c in _card_host.get_children():
		_card_host.remove_child(c)
		c.queue_free()
	_card = null
	_trade_preview = {}
	if city_id == "":
		var l := Kit.label("点一座城，看它的城市卡。", 22, Kit.INK_SOFT)
		l.position = Vector2(4, 20)
		_card_host.add_child(l)
		return
	if _tab == "trade":
		_show_trade_card(city_id, deck_id, deck)
		return
	_card = CITY_CARD.instantiate()
	_card.custom_minimum_size = Vector2(206, 275)
	_card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_card_host.add_child(_card)
	_card.size = Vector2(206, 275)               # 进了树再设（之前设会被场景里的 270×360 顶回去）；0.19 × 1086×1448
	_card.position = Vector2(0, 0)
	_card.call("bind_resolved", resolved, _content)
	_card.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			card_enlarge.emit(city_id))
	_card_note = Kit.label("点卡片看大图。\n这张卡和游戏里看到的是同一张。", 20, Kit.INK_SOFT)
	_card_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_note.position = Vector2(222, 12)
	_card_note.size = Vector2(_card_host.size.x - 226, 200)
	_card_host.add_child(_card_note)


func trade_preview() -> Dictionary:
	return _trade_preview.duplicate(true)


func _trade_turn(deck_id: String, delta: int, count: int) -> void:
	_trade_pages[deck_id] = posmod(int(_trade_pages.get(deck_id, 0)) + delta, count)
	_show_card(target)


func _show_trade_card(city_id: String, deck_id: String, deck: Dictionary) -> void:
	var width:=_card_host.size.x
	var cards: Dictionary = deck.get("cards", {})
	var ids: Array = cards.keys()
	ids.sort()
	if ids.is_empty():
		_card_host.add_child(Kit.label("这座城没有可预览的贸易卡。", 22, Kit.INK_SOFT)); return
	var page := clampi(int(_trade_pages.get(deck_id, 0)), 0, ids.size() - 1)
	_trade_pages[deck_id] = page
	var card_id := str(ids[page])
	# Resolve via the same card index GameData uses in the game; no price derivation.
	var card := GameData.get_trade_card(_content, card_id)
	var entries: Array = card.get("entries", [])
	_trade_preview = {"city_id": city_id, "deck_id": deck_id, "card_id": card_id, "page": page,
		"count": ids.size(), "card": card.duplicate(true), "rows": []}
	var title := Kit.label("真实贸易卡 %d / %d" % [page + 1, ids.size()], 18, Kit.SATCHEL_DEEP, "body", 700)
	title.position = Vector2(0, 2);title.size=Vector2(width-108,32);title.clip_text=true;_card_host.add_child(title)
	for delta in [-1, 1]:
		var button := Kit.button("‹" if delta < 0 else "›", "cream", 32, 20)
		button.name = "TradePreviousButton" if delta < 0 else "TradeNextButton"
		button.position = Vector2(width-100 if delta < 0 else width-44, 0);button.custom_minimum_size=Vector2(44,32);button.size=Vector2(44,32)
		button.pressed.connect(func() -> void: _trade_turn(deck_id, delta, ids.size()))
		_card_host.add_child(button)
	var starting: Array = _content.get("city_cards", {}).get(city_id, {}).get("starting_grant", {}).get("entries", [])
	var own_good := str(starting[0].get("resource_id", "")) if not starting.is_empty() else ""
	var give := -1; var receive := -1
	for index in entries.size():
		var entry: Dictionary = entries[index]
		var silver := str(entry.get("resource_kind", "")) == "SILVER"
		var resource_id := str(entry.get("resource_id", ""))
		var resource_name := "白银" if silver else GameData.get_good_name(_content, resource_id)
		var quantity := int(entry.get("quantity", 1))
		var texture: Texture2D = Icons.silver() if silver else GameData.get_good_texture(_content, resource_id)
		_trade_preview.rows.append({"resource_kind": str(entry.get("resource_kind", "")), "resource_id": resource_id,
			"name": resource_name, "quantity": quantity, "texture_path": texture.resource_path if texture != null else ""})
		var cell := HBoxContainer.new()
		var column_width:float=(width-8)/2.0
		cell.position = Vector2((index % 2) * (column_width+8), 42 + (index / 2) * 58)
		cell.size = Vector2(column_width, 52); cell.add_theme_constant_override("separation", 8)
		cell.set_meta("trade_entry", entry.duplicate(true)); _card_host.add_child(cell)
		var icon := TextureRect.new(); icon.texture = texture
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(36, 48); cell.add_child(icon)
		var label := Kit.label("%s\n× %d" % [resource_name, quantity], 18, Kit.INK, "body", 600)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL;label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;cell.add_child(label)
		if silver: receive = index
		elif give < 0 or resource_id == own_good: give = index
	if receive < 0:
		for index in entries.size():
			if index != give: receive = index; break
	var choices: Dictionary = _trade_choices.get(card_id, {})
	give = int(choices.get("give", give)); receive = int(choices.get("receive", receive))
	if give >= 0 and receive >= 0:
		var direction := "%s %s → 获得 %s" % ["支付" if str(entries[give].get("resource_kind", "")) == "SILVER" else "交付",
			GameData.describe_entry(_content, entries[give]), GameData.describe_entry(_content, entries[receive])]
		_trade_preview["give_index"] = give; _trade_preview["receive_index"] = receive; _trade_preview["direction"] = direction
		var label := Kit.label(direction, 18, Kit.INK, "body", 600)
		label.add_theme_font_size_override("font_size",16)
		label.position = Vector2(0, 208); label.size = Vector2(width-82, 64); label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_card_host.add_child(label)
		for side in ["give", "receive"]:
			var selector := OptionButton.new()
			selector.name = "TradeGiveSelector" if side == "give" else "TradeReceiveSelector"
			selector.position = Vector2(0 if side == "give" else (width+8)/2.0, 164)
			selector.size = Vector2((width-8)/2.0, 36);selector.clip_text=true;selector.fit_to_longest_item=false;selector.add_theme_font_override("font", Kit.font("body", 600))
			selector.add_theme_font_size_override("font_size", 16)
			for index in entries.size(): selector.add_item(("交付 " if side == "give" else "获得 ") + GameData.describe_entry(_content, entries[index]), index)
			selector.select(give if side == "give" else receive)
			selector.tooltip_text=selector.get_item_text(selector.selected)
			selector.item_selected.connect(func(index: int) -> void: _choose_trade_entry(card_id, side, index))
			_card_host.add_child(selector)
		var reverse := Kit.button("反向", "cream", 34, 18)
		reverse.name = "TradeReverseButton"; reverse.position = Vector2(width-76, 208); reverse.size = Vector2(76, 34)
		reverse.pressed.connect(func() -> void: _trade_choices[card_id] = {"give": receive, "receive": give}; _show_card(target))
		_card_host.add_child(reverse)


func _choose_trade_entry(card_id: String, side: String, index: int) -> void:
	var give := int(_trade_preview.get("give_index", 0)); var receive := int(_trade_preview.get("receive_index", 1))
	if side == "give":
		if index == receive: receive = give
		give = index
	else:
		if index == give: give = receive
		receive = index
	_trade_choices[card_id] = {"give": give, "receive": receive}
	_show_card(target)

func show_badge(config: Dictionary, automatic_offset: Vector2, transport: String) -> void:
	var manual: bool = config.get("mode", "AUTO") == "MANUAL"
	var a: Array = config.get("offset_px", [automatic_offset.x,automatic_offset.y])
	if not _new_nodes.has("badge_mode"):
		var start := _rows.get_child_count()
		_new_nodes.badge_mode = _value_label(_row("名牌位置"))
		for axis in ["x", "y"]:
			_row("横向" if axis=="x" else "纵向").add_child(_numfield("badge_"+axis, float(a[0 if axis=="x" else 1]), 1.0,1,150.0))
		_rows.add_child(_action_button("重置名牌自动位置（可撤销）", "badge_reset"))
		_new_nodes.badge_traffic = _value_label(_row("自动交通"))
		var choice := OptionButton.new(); choice.name="BadgeIconChoice"
		for text in ["自动交通图标", "骆驼 · 自定义外观", "商船 · 自定义外观", "双交通 · 自定义外观", "星星 · 自定义外观", "导入图片 · 自定义外观"]: choice.add_item(text)
		var cid := target
		choice.item_selected.connect(func(i: int) -> void: action.emit("badge_icon:"+cid+":"+str(i)))
		_rows.add_child(choice); _new_nodes.badge_choice = choice
		_rows.add_child(_action_button("导入名牌 PNG / JPEG", "badge_import"))
		_new_nodes.badge_message = Kit.label("选一个文件开始预览；确认后才应用。",18,Kit.INK_SOFT)
		_new_nodes.badge_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rows.add_child(_new_nodes.badge_message)
		_text("直接拖动名牌，不会挪动城市。横向 / 纵向调整名牌与城脚的距离；屏边会暂时避让。自定义主图保留真实交通角标。",18,Kit.INK_SOFT)
		_group_span("名牌位置 · 不挪城",start,_rows.get_child_count(),false)
		if _groups.has("卡片"): _rows.move_child(_groups["名牌位置 · 不挪城"].root,_groups["卡片"].root.get_index())
	_new_nodes.badge_mode.text = "手动" if manual else "自动避让"
	_new_nodes.badge_traffic.text = {"LAND":"陆路 · 骆驼","SEA":"海路 · 商船","BOTH":"陆海双交通"}.get(transport,"未知")
	_new_nodes.badge_choice.select(CustomMapCityBadges.ICONS.find(str(config.get("icon","AUTO"))))
	for axis in ["x", "y"]:
		(fields["badge_"+axis] as NumField).set_value(float(a[0 if axis=="x" else 1]))

func update_original_name(value: String) -> void:
	_new_nodes.title.text = value
	# Same update path as new-city drafts; invalid drafts remain visible and recoverable.
	_set_text_value("name", value)
	_update_name_problem()

func scroll_to_top() -> void:
	_scroll.scroll_vertical = 0
	_scroll.set_deferred("scroll_vertical", 0)

func locate_problem(raw: String) -> void:
	scroll_to_top()
	var field := raw.get_slice(".", raw.get_slice_count(".") - 1)
	var control: Control = text_fields.get(field, fields.get(field))
	if control != null and "edit" in control: control = control.edit
	if control == null: control = _new_nodes.get("host", _new_nodes.get("title"))
	if control == null: return
	var box := StyleBoxFlat.new()
	box.bg_color = Color("fff8df"); box.border_color = Kit.OCHRE
	box.set_border_width_all(3); box.set_corner_radius_all(10)
	if control is LineEdit:
		control.add_theme_stylebox_override("normal", box)
	else:
		control.modulate = Color("ffcc70")
	var tween := create_tween().set_loops(3)
	tween.tween_property(control, "modulate", Color("fff3bf"), 0.3)
	tween.tween_property(control, "modulate", Color.WHITE, 0.3)

func badge_import_message(message: String, error := false) -> void:
	if _new_nodes.has("badge_message"):
		_new_nodes.badge_message.text = message
		_new_nodes.badge_message.add_theme_color_override("font_color", RED if error else Kit.INK_SOFT)

func _group_span(title: String, start: int, end: int, expanded: bool) -> void:
	var members := _rows.get_children().slice(start,end)
	var root := VBoxContainer.new(); root.name="Group_"+title
	root.add_theme_constant_override("separation",0)
	var header := Kit.button(("▾ " if expanded else "▸ ")+title,"cream",38,20)
	header.alignment=HORIZONTAL_ALIGNMENT_LEFT; header.name="Section_"+title
	header.focus_mode=Control.FOCUS_ALL
	root.add_child(header)
	var body := VBoxContainer.new(); body.add_theme_constant_override("separation",0); root.add_child(body)
	_rows.add_child(root); _rows.move_child(root,start)
	for member in members: member.reparent(body)
	body.visible=expanded
	header.pressed.connect(func() -> void:
		body.visible=not body.visible
		header.text=("▾ " if body.visible else "▸ ")+title)
	_groups[title]={"root":root,"header":header,"body":body}

func _danger_style(button: Button) -> void:
	for state in ["normal","hover","pressed","hover_pressed"]:
		var box := StyleBoxFlat.new(); box.bg_color=Color("fffdf7") if state=="normal" else Color("fff0ea")
		box.border_color=RED; box.set_border_width_all(2); box.set_corner_radius_all(14)
		box.content_margin_left=12; box.content_margin_right=12
		button.add_theme_stylebox_override(state,box)
	for key in ["font_color","font_hover_color","font_pressed_color","font_focus_color"]:button.add_theme_color_override(key,RED)
	button.tooltip_text="先查看影响并确认；应用后可以撤销。"
	var marker := Control.new(); marker.name="DangerCorner"; marker.mouse_filter=Control.MOUSE_FILTER_IGNORE
	marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); button.add_child(marker)
	marker.draw.connect(func() -> void:
		marker.draw_colored_polygon(PackedVector2Array([Vector2(marker.size.x-14,3),Vector2(marker.size.x-3,3),Vector2(marker.size.x-3,14)]), RED))

func show_object_feedback(problems:Array,next_step:bool=false) -> void:
	for node in _feedback.get_children():_feedback.remove_child(node);node.queue_free()
	if next_step:
		var next:=_action_button("下一步：连接城市","extra_connection",52)
		next.name="NextConnectCity";_feedback.add_child(next)
		var note:=Kit.label("点地图上的目标城，或在列表中选择。",21,Kit.INK_SOFT);note.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;_feedback.add_child(note)
	var visible_problems:=problems.filter(func(e):return not e.get("pending",false))
	for i:int in mini(2,visible_problems.size()):
		var issue:Dictionary=visible_problems[i]
		var label:=Kit.label("待修复 · "+str(issue.get("kid","需要检查")),22,RED);label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;label.custom_minimum_size.x=SIZE.x-64;_feedback.add_child(label)
		var go:=_action_button("定位问题","issue:"+str(issue.get("issue_index",-1)),42);go.disabled=not issue.get("locatable",false);_feedback.add_child(go)
		for repair:Dictionary in issue.get("repairs",[]):_feedback.add_child(_action_button(str(repair.text),str(repair.action),42))
	_feedback_height=_feedback.get_combined_minimum_size().y+14 if _feedback.get_child_count()>0 else 0.0
	_scroll.position.y=PROPS_TOP+_feedback_height
	_scroll.size.y=maxf(160,(PROPS_BOTTOM-PROPS_TOP-92 if kind in ["city","new_city","map"] else size.y-PROPS_TOP-30)-_feedback_height)
	_feedback.visible=_feedback.get_child_count()>0

func fit_height(height:float) -> void:
	size.y=height
	var background:=get_child(0) as Control
	if background!=null:background.size.y=height
	_card_host.size.y=maxf(120,height-(PROPS_BOTTOM+44))
	if kind not in ["city","new_city","map"]:_scroll.size.y=maxf(160,height-PROPS_TOP-30-_feedback_height)
