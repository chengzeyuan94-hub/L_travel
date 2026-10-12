extends Control
## 市集面板里的「趣味事件」选择面板（market_mode == "decision"，2026-09-27）。和「商旅交换」同一个做法：
## 面板标题飘带（卡通字，市集面板自带）写卡名；下面几块选项格子，点格子只是选中（高亮 + 底部预览，点错可以改点），
## 成交只在右下角的主按钮（「确认付1块白银」「就是它」「就这样」「确认」）——主按钮不在这里。
## 用于：付银或丢货（亡羊补牢 / 未雨绸缪）、听声三选一（耳听八方）、二选一（左右逢源 / 放长线钓大鱼）、看牌（先睹为快）。
## 字体：格子、预览、说明全是圆体（title / body 两档）。
##
## set_view(d)：
##   {subtitle: String,
##    card_event_id: String（看牌：左边摆那张事件卡的正面，可空）,
##    sections: [{head: String, note: String（这一块做不到时的原因，可空）,
##                tiles: [{id, kind: "good" | "wide" | "big", icon: Texture2D, text, sub, selected, enabled}]}],
##    preview: {icon: Texture2D, text: String} 或 {}（空时显示 hint）, hint: String}

signal picked(id: String)

const Parts := preload("res://scripts/lshu_ui/lshu_fun_parts.gd")
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const EventCardScene := preload("res://scenes/ui/components/event_card.tscn")

const W := 800.0
const GOOD_TILE := Vector2(152, 116)
const BIG_TILE := Vector2(236, 196)
const WIDE_H := 104.0
const CARD_W := 246.0
const INK := Color("#3A2A22")

var _subtitle: Label
var _body: VBoxContainer
var _scroll: ScrollContainer
var _preview: PanelContainer
var _card: Control
var _sig := ""
var _nodes := {}          # id -> Button


func _init() -> void:
	name = "MarketChoice"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_subtitle = Parts.label("", 25, Kit.INK_SOFT, "body", 500)
	_subtitle.name = "ChoiceSubtitle"
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_subtitle.max_lines_visible = 2
	add_child(_subtitle)
	_scroll = ScrollContainer.new()
	_scroll.name = "ChoiceScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_body = VBoxContainer.new()
	_body.name = "ChoiceBody"
	_body.add_theme_constant_override("separation", 10)
	_scroll.add_child(_body)
	_preview = PanelContainer.new()
	_preview.name = "ChoicePreview"
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#FFF1D6")
	sb.border_color = Kit.OCHRE
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(22)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	_preview.add_theme_stylebox_override("panel", sb)
	add_child(_preview)
	var line := HBoxContainer.new()
	line.name = "PreviewLine"
	line.alignment = BoxContainer.ALIGNMENT_CENTER
	line.add_theme_constant_override("separation", 10)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.add_child(line)


## 面板里标题飘带以下归这里（和交换面板同一块位置）
func layout_in(h: float) -> void:
	var eh := h - 118.0 - 18.0
	Parts.place(self, Rect2(40, 118, W, eh))
	var sub_h := 64.0 if _subtitle.get_line_count() > 1 else 36.0
	Parts.place(_subtitle, Rect2(0, 0, W, sub_h))
	var preview_h := 64.0
	Parts.place(_preview, Rect2(0, eh - preview_h, W, preview_h))
	var left := 0.0
	if _card != null:
		left = CARD_W + 24.0
		var ch := CARD_W / 0.75
		Parts.place(_card, Rect2(0, sub_h + 10.0, CARD_W, ch))
		_card.pivot_offset = Vector2.ZERO
	# 左边留 10px：分段标题不压面板的缝线
	Parts.place(_scroll, Rect2(left + 10.0, sub_h + 8.0, W - left - 10.0, maxf(120.0, eh - preview_h - 16.0 - sub_h)))
	_body.custom_minimum_size = Vector2(W - left - 30.0, 0)


func set_view(d: Dictionary) -> void:
	_subtitle.text = String(d.get("subtitle", ""))
	var sections: Array = d.get("sections", [])
	var card_id := String(d.get("card_event_id", ""))
	# 格子只在选项清单变了时重建（重建会吃掉正在按下的那一下）；选中 / 可点只改状态
	var sig := JSON.stringify([card_id, sections.map(func(s): return [s.get("head", ""), s.get("note", ""), (s.get("tiles", []) as Array).map(func(t): return [t.get("id", ""), t.get("kind", ""), t.get("text", "")])])])
	if sig != _sig:
		_sig = sig
		_body.custom_minimum_size = Vector2(W - (CARD_W + 24.0 if not card_id.is_empty() else 0.0) - 30.0, 0)
		_rebuild(sections, card_id)
	for s in sections:
		for t in s.get("tiles", []):
			_paint_tile(_nodes.get(String(t.get("id", ""))), t)
	_paint_preview(d.get("preview", {}), String(d.get("hint", "")))
	if get_parent() is Control:
		layout_in((get_parent() as Control).size.y)


func tile(id: String) -> Button:
	return _nodes.get(id) as Button


func preview_text() -> String:
	var parts: Array[String] = []
	for c in (_preview.get_node("PreviewLine") as Node).get_children():
		if c is Label:
			parts.append((c as Label).text)
	return " ".join(parts)


func card() -> Control:
	return _card


func _rebuild(sections: Array, card_id: String) -> void:
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	_nodes.clear()
	if _card != null:
		_card.queue_free()
		_card = null
	if not card_id.is_empty():
		_card = EventCardScene.instantiate()
		_card.name = "PeekCard"
		_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_card)
		_card.size = Vector2(CARD_W, CARD_W / 0.75)
		_card.call("configure_front", card_id)
		_card.call("show_front")
		_card.call("set_interactive", false)
	for s in sections:
		var head := Parts.label(String(s.get("head", "")), 27, Kit.SATCHEL, "title", 700)
		head.name = "ChoiceHead"
		head.custom_minimum_size = Vector2(0, 38)
		head.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		_body.add_child(head)
		var tiles: Array = s.get("tiles", [])
		var kind := String((tiles[0] as Dictionary).get("kind", "good")) if not tiles.is_empty() else "good"
		var box: Container
		if kind == "wide":
			var v := VBoxContainer.new()
			v.add_theme_constant_override("separation", 10)
			box = v
		else:
			var h := HFlowContainer.new()
			h.add_theme_constant_override("h_separation", 14)
			h.add_theme_constant_override("v_separation", 10)
			box = h
		box.name = "ChoiceRow"
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_body.add_child(box)
		for t in tiles:
			var b := _make_tile(t)
			box.add_child(b)
			_nodes[String(t.get("id", ""))] = b
		var note := String(s.get("note", ""))
		if not note.is_empty():
			var n := Parts.label(note, 22, Kit.INK_SOFT, "body", 500)
			n.name = "ChoiceNote"
			n.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
			_body.add_child(n)


func _make_tile(t: Dictionary) -> Button:
	var kind := String(t.get("kind", "good"))
	var b := Button.new()
	b.name = "Choice_%s" % String(t.get("id", ""))
	Parts.Hud.flat_hit(b)
	var sz := GOOD_TILE
	if kind == "big":
		sz = BIG_TILE
	elif kind == "wide":
		sz = Vector2(_body.custom_minimum_size.x, WIDE_H)
	b.custom_minimum_size = sz
	b.set_meta("kind", kind)
	var bg := NinePatchRect.new()
	bg.name = "Bg"
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	b.add_child(bg)
	var icon_tex: Texture2D = t.get("icon")
	match kind:
		"wide":
			# row / row_sel 贴图上沿 ~22px 是小花和眼镜的装饰，框里的内容放在 24–92 之间（和市集清单的行一样）
			# 选中时 row_sel 左上角有一副小眼镜（约 50×45）：图标和字都从它右边开始
			if icon_tex != null:
				b.add_child(Parts.image(icon_tex, Rect2(66, 30, 52, 52)))
			var x := 132.0 if icon_tex != null else 72.0
			var lt := Parts.label(String(t.get("text", "")), 27, INK, "title", 700)
			lt.name = "TileText"
			lt.clip_text = true
			lt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			Parts.place(lt, Rect2(x, 24, sz.x - x - 70, 36))
			b.add_child(lt)
			var sub := Parts.label(String(t.get("sub", "")), 21, Kit.INK_SOFT, "body", 500)
			sub.name = "TileSub"
			sub.clip_text = true
			sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			Parts.place(sub, Rect2(x, 58, sz.x - x - 70, 30))
			b.add_child(sub)
		"big":
			if icon_tex != null:
				b.add_child(Parts.image(icon_tex, Rect2((sz.x - 96) * 0.5, 22, 96, 84)))
			var bt := Parts.label(String(t.get("text", "")), 30, INK, "title", 700)
			bt.name = "TileText"
			bt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			bt.clip_text = true
			Parts.place(bt, Rect2(10, 114 if icon_tex != null else 70, sz.x - 20, 44))
			b.add_child(bt)
			var bs := Parts.label(String(t.get("sub", "")), 20, Kit.INK_SOFT, "body", 500)
			bs.name = "TileSub"
			bs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			bs.clip_text = true
			Parts.place(bs, Rect2(10, 156, sz.x - 20, 28))
			b.add_child(bs)
		_:
			if icon_tex != null:
				b.add_child(Parts.image(icon_tex, Rect2((sz.x - 52) * 0.5, 10, 52, 52)))
			var gt := Parts.label(String(t.get("text", "")), 22, INK, "title", 700)
			gt.name = "TileText"
			gt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			gt.clip_text = true
			Parts.place(gt, Rect2(10, 62, sz.x - 20, 30))
			b.add_child(gt)
			var gs := Parts.label(String(t.get("sub", "")), 18, Kit.INK_SOFT, "body", 500)
			gs.name = "TileSub"
			gs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			gs.clip_text = true
			Parts.place(gs, Rect2(8, 88, sz.x - 16, 24))
			b.add_child(gs)
	# 选中：右上角一个橙色小勾（和交换面板一样）
	var tick_bg := Parts.Hud.ring(Kit.CREAM, 3, Kit.OCHRE)
	tick_bg.name = "Tick"
	Parts.place(tick_bg, Rect2(sz.x - 44, 6, 36, 36) if kind != "wide" else Rect2(sz.x - 70, 38, 36, 36))
	var tick := Parts.label("✓", 24, INK, "title", 700)
	tick.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tick.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Parts.place(tick, Rect2(0, 0, 36, 36))
	tick_bg.add_child(tick)
	b.add_child(tick_bg)
	var id := String(t.get("id", ""))
	b.pressed.connect(func() -> void: picked.emit(id))
	return b


func _paint_tile(b: Button, t: Dictionary) -> void:
	if b == null:
		return
	var sel := bool(t.get("selected", false))
	var enabled := bool(t.get("enabled", true))
	var kind := String(b.get_meta("kind", "good"))
	var bg := b.get_node("Bg") as NinePatchRect
	var skin := ("row_sel" if sel else "row") if kind == "wide" else ("pocket_sel" if sel else "tile")
	var fresh := Parts.hud_nine(skin)
	bg.texture = fresh.texture
	bg.patch_margin_left = fresh.patch_margin_left
	bg.patch_margin_right = fresh.patch_margin_right
	bg.patch_margin_top = fresh.patch_margin_top
	bg.patch_margin_bottom = fresh.patch_margin_bottom
	fresh.free()
	(b.get_node("Tick") as Control).visible = sel
	var sub := b.get_node_or_null("TileSub") as Label
	if sub != null:
		sub.text = String(t.get("sub", ""))
	b.disabled = not enabled
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if enabled else Control.CURSOR_ARROW
	b.modulate = Color.WHITE if enabled else Color(1, 1, 1, 0.45)
	b.tooltip_text = String(t.get("sub", "")) if not enabled else ""
	b.set_meta("selected", sel)
	b.set_meta("enabled", enabled)


func _paint_preview(pv: Dictionary, hint: String) -> void:
	var line := _preview.get_node("PreviewLine") as HBoxContainer
	for c in line.get_children():
		line.remove_child(c)
		c.queue_free()
	if pv.is_empty():
		var t := Parts.label(hint, 26, INK, "title", 700)
		t.name = "PreviewHint"
		t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.add_child(t)
		return
	var icon: Texture2D = pv.get("icon")
	if icon != null:
		var ic := TextureRect.new()
		ic.texture = icon
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.custom_minimum_size = Vector2(48, 48)
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(ic)
	var tx := Parts.label(String(pv.get("text", "")), 28 if String(pv.get("text", "")).length() <= 22 else 24, INK, "title", 700)
	tx.name = "PreviewText"
	tx.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(tx)
