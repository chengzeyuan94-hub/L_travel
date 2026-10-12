class_name EventDrawOverlay
extends Control

signal presentation_finished(event: Dictionary)
## 卡翻开了（对局界面据此把「先翻开卡片」换成「点『继续』」）
signal revealed
## 「L叔的趣味事件」的演出台揭晓了结果（赛骰落定、拳头 / 明信片打开）：GameScreen 这时才刷新压着的白银
signal stage_revealed(event: Dictionary)

enum PresentationState {
	HIDDEN,
	ENTERING,
	WAITING_SELECTION,
	MOVING_TO_CENTER,
	FLIPPING,
	REVEALED,
	EXITING,
}

const AI_PRESENTATION_SECONDS := 3.35
## 扩展卡（「L叔的趣味事件」）翻开后的演出台：卡挪到左边，台子放右边（scripts/ui/fun_event_stage.gd）
const FunStage := preload("res://scripts/ui/fun_event_stage.gd")
const DESIGN := Vector2(1920, 1080)
const DIM_COLOR := Color(0, 0, 0, 0.42)
const MAIN_ACTIVE := preload("res://assets/game/ui/trade/main_button_active_blank_hd.png")
const MAIN_HOVER := preload("res://assets/game/ui/trade/main_button_hover_blank_hd.png")
const MAIN_PRESSED := preload("res://assets/game/ui/trade/main_button_pressed_blank_hd.png")
const LSkin := preload("res://scripts/lshu_ui/lshu_skin.gd")
const HudKit := preload("res://scripts/lshu_ui/lshu_match_hud.gd")
const LKit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const DIVIDER_TEXTURE := "res://assets/game/ui/city_cards/v2/divider.png"
const TITLE_PICK := "命运抽取 · 选一张"
const TITLE_AI := "命运抽取 · 电脑来抽"
const TITLE_REVEALED := "命运抽取 · 翻开啦"
const SELECTED_SCALE := 1.25
## L叔 界面下的尺寸（设计像素 1920×1080，乘界面的 k）
const LSHU_PLAQUE := Vector2(420, 64)
const LSHU_CAPTION_W := 600.0
const LSHU_CARD_MAX_H := 640.0      # 翻开后放大的那张最高多少
const LSHU_EFFECT_PX := 32          # 效果原文（≥ 26）
const LSHU_IDIOM_PX := 23           # 成语释义（≥ 20）
const LSHU_CONTINUE := Vector2(240, 80)

var state := PresentationState.HIDDEN
var _event: Dictionary = {}
var _map_rect := Rect2(0, 64, 900, 656)
var _cards: Array[EventCard] = []
var _slot_positions: Array[Vector2] = []
var _active_tweens: Array[Tween] = []
var _serial := 0
var _session_generation := -1
var _is_ai := false
var _selected_index := -1
var _card_size := Vector2(210, 280)
var _content_override: Dictionary = {}
## L叔 对局界面在场时（复检 UIRES-3）：GameScreen 传进上下两排界面之间露出来的那条地图和界面的缩放 k。
## 卡、标题牌、「继续」都排在这条里，字号按同一个 k；遮罩照旧盖满 set_map_rect 给的整块地图（界面按钮点不到）。
var _hud_k := 0.0
var _safe_rect := Rect2()
var _caption: Control
var _caption_effect: Label
var _caption_idiom: Label
var _caption_rule: TextureRect
var _lshu_skinned := false
var _lshu_area_top := 0.0          # 标题牌下面、放卡的那一段（全局坐标）
var _lshu_area_h := 0.0
var _caption_box := Rect2()        # 说明牌可用的格子（放大的卡右边）
var _stage: Control = null
## GameScreen 注入：player_id -> {name, avatar, color, flip, human}（演出台上的头像、名字）
var player_look: Callable


func _ready() -> void:
	_cards = [$Card0, $Card1, $Card2]
	for card in _cards:
		card.clicked.connect(_on_card_clicked)
		card.mouse_entered.connect(func(c := card): _on_card_hover(c, true))
		card.mouse_exited.connect(func(c := card): _on_card_hover(c, false))
	$ContinueButton.pressed.connect(_on_continue_pressed)
	HudStyle.apply_heading($Title, HudStyle.PARCHMENT_LIGHT, 19)
	HudStyle.apply_button($ContinueButton)
	$ContinueButton.add_theme_stylebox_override("normal", _texture_style(MAIN_ACTIVE))
	$ContinueButton.add_theme_stylebox_override("hover", _texture_style(MAIN_HOVER))
	$ContinueButton.add_theme_stylebox_override("pressed", _texture_style(MAIN_PRESSED))
	$ContinueButton.add_theme_stylebox_override("focus", _texture_style(MAIN_HOVER))
	$Glow.texture = _radial_texture()
	visible = false


func set_map_rect(rect: Rect2) -> void:
	_map_rect = rect
	if visible:
		_layout_static()


## L叔 对局界面：rect = 上下两排界面之间露出来的地图（全局坐标），ui_scale = 界面的 k（设计 1920×1080）。
## 不调用（或 ui_scale <= 0）时照旧按整块地图排（Demo / 旧卷轴界面）。
func set_hud_safe_rect(rect: Rect2, ui_scale: float) -> void:
	_safe_rect = rect
	_hud_k = ui_scale
	if _lshu_mode():
		_apply_lshu_look()
	if visible:
		_layout_static()
		if state == PresentationState.REVEALED and _selected_index >= 0:
			_place_revealed(false)


func _lshu_mode() -> bool:
	return _hud_k > 0.0 and _safe_rect.size.x > 1.0 and _safe_rect.size.y > 1.0


func set_content_override(content: Dictionary) -> void:
	_content_override = content.duplicate(true) if not content.is_empty() else {}
	for card in _cards:
		if card != null:
			card.set_content_override(_content_override)


func show_human_event(event: Dictionary) -> void:
	_start_presentation(event, false)


func show_ai_event(event: Dictionary) -> float:
	_start_presentation(event, true)
	_run_ai_sequence(_serial)
	return AI_PRESENTATION_SECONDS + FunStage.extra_ai_seconds(event)


func cancel_presentation() -> void:
	_serial += 1
	for tween in _active_tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_active_tweens.clear()
	state = PresentationState.HIDDEN
	_event = {}
	_selected_index = -1
	_clear_stage()
	visible = false
	modulate = Color.WHITE
	$Glow.visible = false
	$ContinueButton.visible = false
	if _caption != null:
		_caption.visible = false
	for card in _cards:
		card.show_back()
		card.clear_illustration()
		card.set_interactive(false)
		card.scale = Vector2.ONE
		card.modulate = Color.WHITE
		card.z_index = 0


func _start_presentation(event: Dictionary, ai: bool) -> void:
	cancel_presentation()
	_serial += 1
	var serial := _serial
	_event = event.duplicate(true)
	_is_ai = ai
	# 电脑的抽卡演出不接点击：遮罩不拦鼠标，下面的「电脑走快点」照样能点（复检 NOV-8）
	$Dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE if ai else Control.MOUSE_FILTER_STOP
	_session_generation = GameState.session_generation
	state = PresentationState.ENTERING
	visible = true
	modulate = Color.WHITE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 翻开以后不再写「选一张」；电脑抽卡时也不叫小朋友去选（复检 UIRES-3）
	$Title.text = TITLE_AI if ai else TITLE_PICK
	_layout_static()
	var content := _content_override if not _content_override.is_empty() else GameState.content
	for i in _cards.size():
		var card := _cards[i]
		card.set_content_override(content)
		card.configure_front(String(_event.get("event_id", "")), content)
		card.show_back()
		card.set_interactive(false)
		card.modulate = Color(1, 1, 1, 0)
		card.scale = Vector2.ONE
		card.position = _slot_positions[i] + Vector2(100, 0)
	$ContinueButton.visible = false
	$Glow.visible = false
	_run_entry(serial)


func _layout_static() -> void:
	var old_slots := _slot_positions.duplicate()
	_layout_static_inner()
	# 等玩家挑卡时窗口变了大小（安卓：在掌机两块屏之间挪、分屏；MC-3）：卡跟着新的位置走。
	# 卡的位置本来只有发牌动画和翻开时才设，重排只改了大小，卡就留在旧地方、互相压住或压在下面的界面上。
	# 悬停 / 手柄抬起的那一点高度留着
	if state == PresentationState.WAITING_SELECTION:
		for i in mini(_cards.size(), _slot_positions.size()):
			var lift := 0.0
			if i < old_slots.size():
				lift = clampf(_cards[i].position.y - (old_slots[i] as Vector2).y, -8.0, 0.0)
			var tw: Tween = _hover_tweens.get(i)
			if tw != null and tw.is_valid():
				tw.kill()                 # 还在往旧位置抬 / 放的那一下：停掉，不然会把卡拉回旧地方
			_cards[i].position = _slot_positions[i] + Vector2(0.0, lift)


func _layout_static_inner() -> void:
	$Dimmer.position = _map_rect.position
	$Dimmer.size = _map_rect.size
	if _lshu_mode():
		_layout_static_lshu()
		return
	var card_h := clampf(_map_rect.size.y * 0.55, 240.0, 360.0)
	var card_w := card_h * 0.75
	var gap := clampf(_map_rect.size.x * 0.02, 16.0, 24.0)
	_card_size = Vector2(card_w, card_h)
	var total_w := card_w * 3.0 + gap * 2.0
	var start_x := _map_rect.position.x + (_map_rect.size.x - total_w) * 0.5
	var start_y := _map_rect.position.y + (_map_rect.size.y - card_h) * 0.52
	_slot_positions = []
	for i in 3:
		_slot_positions.append(Vector2(start_x + i * (card_w + gap), start_y))
		_cards[i].size = _card_size
		_cards[i].pivot_offset = _card_size * 0.5
	var plaque_size := Vector2(280, 46)
	$TitlePlaque.position = Vector2(
		_map_rect.position.x + (_map_rect.size.x - plaque_size.x) * 0.5,
		_map_rect.position.y + 14
	)
	$TitlePlaque.size = plaque_size
	$Title.position = $TitlePlaque.position + Vector2(18, 4)
	$Title.size = plaque_size - Vector2(36, 8)
	$ContinueButton.size = Vector2(180, 48)
	$ContinueButton.position = Vector2(
		_map_rect.position.x + (_map_rect.size.x - 180.0) * 0.5,
		minf(_map_rect.end.y - 58.0, start_y + card_h + 14.0)
	)
	if _stage != null and _selected_index >= 0:
		_place_stage(false)


## L叔 界面：标题牌贴在露出来的那条地图顶上（不再压住上中的回合牌），三张卡排在它下面；
## 卡的大小让翻开放大（×1.25）后的那张正好放进这条地图，「继续」放到卡旁边的说明牌里，不再落在骰子托盘上
func _layout_static_lshu() -> void:
	var k := _hud_k
	var band := _safe_rect
	var plaque_size := (LSHU_PLAQUE * k).round()
	$TitlePlaque.size = plaque_size
	$TitlePlaque.position = Vector2(band.position.x + (band.size.x - plaque_size.x) * 0.5, band.position.y + 8.0 * k).round()
	$Title.position = $TitlePlaque.position + Vector2(26, 6) * k
	$Title.size = plaque_size - Vector2(52, 12) * k
	$Title.add_theme_font_size_override("font_size", maxi(12, roundi(28.0 * k)))
	_lshu_area_top = $TitlePlaque.position.y + plaque_size.y + 10.0 * k
	_lshu_area_h = maxf(160.0, band.end.y - 10.0 * k - _lshu_area_top)
	var gap := 32.0 * k
	var card_h := minf(_lshu_area_h, LSHU_CARD_MAX_H * k) / SELECTED_SCALE
	var card_w := card_h * 0.75
	var max_w := (band.size.x - 48.0 * k - gap * 2.0) / 3.0
	if card_w > max_w:
		card_w = max_w
		card_h = card_w / 0.75
	# 卡面场景的最小尺寸是 180×240，再小就按最小的放
	card_w = maxf(card_w, 180.0)
	card_h = maxf(card_h, 240.0)
	_card_size = Vector2(card_w, card_h).round()
	var total_w := _card_size.x * 3.0 + gap * 2.0
	var start_x := band.position.x + (band.size.x - total_w) * 0.5
	var start_y := _lshu_area_top + (_lshu_area_h - _card_size.y) * 0.5
	_slot_positions = []
	for i in 3:
		_slot_positions.append(Vector2(start_x + i * (_card_size.x + gap), start_y).round())
		_cards[i].size = _card_size
		_cards[i].pivot_offset = _card_size * 0.5
	$ContinueButton.size = (LSHU_CONTINUE * k).round()
	$ContinueButton.add_theme_font_size_override("font_size", maxi(14, roundi(34.0 * k)))


## 翻开时三张卡要去的位置：{selected, left, right, side_modulate}
func _revealed_targets() -> Dictionary:
	if not _lshu_mode():
		return {
			"selected": Vector2(_slot_positions[1].x, maxf(_map_rect.position.y + 118.0, _slot_positions[1].y - 36.0)),
			"left": Vector2(_map_rect.position.x + 8.0, _slot_positions[0].y),
			"right": Vector2(_map_rect.end.x - 8.0 - _card_size.x, _slot_positions[2].y),
			"side_modulate": Color(0.55, 0.55, 0.55, 1),
		}
	var k := _hud_k
	var band := _safe_rect
	var vis := _card_size * SELECTED_SCALE
	var gap := 28.0 * k
	var cap_w := clampf(band.size.x - vis.x - gap - 48.0 * k, 260.0 * k, LSHU_CAPTION_W * k)
	var group_w := vis.x + gap + cap_w
	var gx := band.position.x + maxf(24.0 * k, (band.size.x - group_w) * 0.5)
	var vy := _lshu_area_top + maxf(0.0, (_lshu_area_h - vis.y) * 0.5)
	var left := Vector2(band.position.x + 16.0 * k - _card_size.x * 0.06, _slot_positions[0].y)
	var right := Vector2(band.end.x - 16.0 * k - _card_size.x * 0.94, _slot_positions[2].y)
	# 两张没选中的卡背退到两边；和中间「卡 + 说明牌」挤在一起时就淡掉
	var group := Rect2(gx, vy, group_w, vis.y).grow(10.0 * k)
	var room := (
		not Rect2(left + _card_size * 0.06, _card_size * 0.88).intersects(group)
		and not Rect2(right + _card_size * 0.06, _card_size * 0.88).intersects(group)
	)
	_caption_box = Rect2(gx + vis.x + gap, vy, cap_w, vis.y)
	return {
		"selected": (Vector2(gx, vy) + (vis - _card_size) * 0.5).round(),
		"left": left.round(),
		"right": right.round(),
		"side_modulate": Color(0.55, 0.55, 0.55, 1.0 if room else 0.0),
	}


## 窗口在翻开后变了大小：直接摆到新位置（不再播动画）
func _place_revealed(_animate: bool) -> void:
	var t := _revealed_targets()
	var sides: Array[EventCard] = []
	for i in _cards.size():
		if i == _selected_index:
			_cards[i].position = t.selected
			_cards[i].scale = Vector2(SELECTED_SCALE, SELECTED_SCALE)
		else:
			sides.append(_cards[i])
			_cards[i].modulate = t.side_modulate
	if sides.size() == 2:
		sides[0].position = t.left
		sides[1].position = t.right
	var sel := _cards[_selected_index]
	_position_glow(sel)
	if _stage != null:
		_place_stage(false)
	elif _lshu_mode():
		_show_caption(sel, false)
	else:
		$ContinueButton.position.y = minf(
			_map_rect.end.y - $ContinueButton.size.y - 8.0,
			sel.position.y + _card_size.y * 1.125 + 8.0
		)


## L叔 界面：「继续」换成 L叔 的糖果按钮；翻开后卡旁边多一块说明牌（大字写效果原文和成语释义）
func _apply_lshu_look() -> void:
	if _lshu_skinned:
		if _caption != null:
			(_caption.get_node("Paper") as LSkin.NinePanel).px = 0.5 * _hud_k
		return
	_lshu_skinned = true
	var b: Button = $ContinueButton
	LSkin.skin_button(b, "ochre")
	b.custom_minimum_size = Vector2.ZERO
	b.add_theme_font_override("font", HudKit.ui_font(700))
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color", "font_disabled_color"]:
		b.add_theme_color_override(key, LKit.INK)
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))
	b.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	b.add_theme_constant_override("outline_size", 0)
	_caption = Control.new()
	_caption.name = "RevealCaption"
	_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_caption.visible = false
	var paper := LSkin.nine_panel("card_blank", Vector4.ZERO)
	paper.name = "Paper"
	paper.px = 0.5 * _hud_k
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_caption.add_child(paper)
	_caption_effect = HudKit.label("", LSHU_EFFECT_PX, LKit.INK, "title", 700)
	_caption_effect.name = "CaptionEffect"
	_caption_effect.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption_effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption.add_child(_caption_effect)
	_caption_rule = TextureRect.new()
	_caption_rule.name = "CaptionRule"
	_caption_rule.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_caption_rule.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_caption_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(DIVIDER_TEXTURE):
		_caption_rule.texture = load(DIVIDER_TEXTURE) as Texture2D
	_caption.add_child(_caption_rule)
	_caption_idiom = HudKit.label("", LSHU_IDIOM_PX, Color("#5E4A3C"), "body", 500)
	_caption_idiom.name = "CaptionIdiom"
	_caption_idiom.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption_idiom.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption.add_child(_caption_idiom)
	add_child(_caption)
	move_child(_caption, b.get_index())


## 说明牌：效果原文（按吉凶上色）· 花朵分隔线 · 成语释义，下面是「继续」（电脑抽卡时没有按钮）
func _show_caption(card: EventCard, fade: bool) -> void:
	if _caption == null:
		return
	var k := _hud_k
	var instruction := card.get_node_or_null("Front/Instruction") as Label
	var emphasis := card.get_node_or_null("Front/Emphasis") as Label
	var idiom := card.get_node_or_null("Front/IdiomNote") as Label
	var effect := instruction.text.strip_edges() if instruction != null else ""
	if emphasis != null and emphasis.visible and not emphasis.text.is_empty():
		effect = (effect + " " + emphasis.text).strip_edges()
	var note := idiom.text.strip_edges() if idiom != null and idiom.visible else ""
	var ink := LKit.INK
	if card.sentiment == "positive":
		ink = EventCard.POSITIVE_INK
	elif card.sentiment == "negative":
		ink = EventCard.NEGATIVE_INK
	var e_px := maxi(12, roundi(LSHU_EFFECT_PX * k))
	var i_px := maxi(10, roundi(LSHU_IDIOM_PX * k))
	_caption_effect.text = effect
	_caption_effect.add_theme_font_size_override("font_size", e_px)
	_caption_effect.add_theme_color_override("font_color", ink)
	_caption_idiom.text = note
	_caption_idiom.add_theme_font_size_override("font_size", i_px)
	_caption_idiom.visible = not note.is_empty()
	_caption_rule.visible = _caption_idiom.visible
	var box := _caption_box
	var pad := Vector2(40, 32) * k
	var text_w := maxf(40.0, box.size.x - pad.x * 2.0)
	var y := pad.y
	var ef := _caption_effect.get_theme_font("font")
	var eh := ef.get_multiline_string_size(effect, HORIZONTAL_ALIGNMENT_CENTER, text_w, e_px).y if ef != null else e_px * 1.4
	_caption_effect.position = Vector2(pad.x, y)
	_caption_effect.size = Vector2(text_w, eh + 4.0 * k)
	y += eh + 14.0 * k
	if _caption_idiom.visible:
		_caption_rule.position = Vector2(pad.x + text_w * 0.2, y)
		_caption_rule.size = Vector2(text_w * 0.6, 22.0 * k)
		y += 22.0 * k + 12.0 * k
		var fi := _caption_idiom.get_theme_font("font")
		var ih := fi.get_multiline_string_size(note, HORIZONTAL_ALIGNMENT_CENTER, text_w, i_px).y if fi != null else i_px * 3.0
		_caption_idiom.position = Vector2(pad.x, y)
		_caption_idiom.size = Vector2(text_w, ih + 4.0 * k)
		y += ih + 18.0 * k
	var btn: Button = $ContinueButton
	var btn_y := y
	if not _is_ai:
		y += btn.size.y + 4.0 * k
	y += pad.y - 6.0 * k
	var h := y
	var cy := box.position.y + maxf(0.0, (box.size.y - h) * 0.5)
	cy = clampf(cy, _safe_rect.position.y, maxf(_safe_rect.position.y, _safe_rect.end.y - h))
	_caption.position = Vector2(box.position.x, cy).round()
	_caption.size = Vector2(box.size.x, h).round()
	var paper := _caption.get_node("Paper") as Control
	paper.position = Vector2.ZERO
	paper.size = _caption.size
	btn.position = (_caption.position + Vector2((box.size.x - btn.size.x) * 0.5, btn_y)).round()
	_caption.visible = true
	if fade:
		_caption.modulate.a = 0.0
		var tw := create_tween()
		_active_tweens.append(tw)
		tw.tween_property(_caption, "modulate:a", 1.0, 0.18)
	else:
		_caption.modulate.a = 1.0


func _run_entry(serial: int) -> void:
	for i in _cards.size():
		_play_deal_sound_after(i * 0.08, serial, 0.96 + i * 0.035)
		var tween := create_tween().set_parallel(true)
		_active_tweens.append(tween)
		tween.tween_property(_cards[i], "position", _slot_positions[i], 0.25).set_delay(i * 0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(_cards[i], "modulate:a", 1.0, 0.18).set_delay(i * 0.08)
	await get_tree().create_timer(0.43).timeout
	if not _is_current(serial):
		return
	state = PresentationState.WAITING_SELECTION
	for card in _cards:
		card.set_interactive(not _is_ai)


func _run_ai_sequence(serial: int) -> void:
	while _is_current(serial) and state == PresentationState.ENTERING:
		await get_tree().process_frame
	if not _is_current(serial):
		return
	await get_tree().create_timer(0.40).timeout
	if not _is_current(serial):
		return
	await _select_card(1, serial)
	if not _is_current(serial):
		return
	await get_tree().create_timer(1.50 + FunStage.extra_ai_seconds(_event)).timeout
	if _is_current(serial):
		await _exit_presentation(serial)


func _on_card_clicked(card: EventCard) -> void:
	if _is_ai or state != PresentationState.WAITING_SELECTION:
		return
	var index := _cards.find(card)
	if index >= 0:
		_select_card(index, _serial)


func _select_card(index: int, serial: int) -> void:
	if not _is_current(serial) or state != PresentationState.WAITING_SELECTION:
		return
	state = PresentationState.MOVING_TO_CENTER
	_selected_index = index
	for card in _cards:
		card.set_interactive(false)
	var selected := _cards[index]
	selected.z_index = 3
	var side_cards: Array[EventCard] = []
	for card in _cards:
		if card != selected:
			side_cards.append(card)
	# 放大后的中央卡上移，为底部“继续”按钮留出独立空间；按钮不得压住卡框。
	# L叔 界面：放大的卡偏左，右边留给说明牌（「继续」在说明牌里）
	var targets := _revealed_targets()
	var move := create_tween().set_parallel(true)
	_active_tweens.append(move)
	move.tween_property(selected, "position", targets.selected, 0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	move.tween_property(selected, "scale", Vector2(SELECTED_SCALE, SELECTED_SCALE), 0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	move.tween_property(side_cards[0], "position", targets.left, 0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	move.tween_property(side_cards[1], "position", targets.right, 0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	for i in _cards.size():
		if i != index:
			# 没选中的两张卡背退到后面：压暗、略缩（保持不透明），不和翻开的正面抢戏
			move.tween_property(_cards[i], "modulate", targets.side_modulate, 0.20)
			_cards[i].pivot_offset = _card_size * 0.5
			move.tween_property(_cards[i], "scale", Vector2(0.88, 0.88), 0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await move.finished
	if not _is_current(serial):
		return
	state = PresentationState.FLIPPING
	var close := create_tween()
	_active_tweens.append(close)
	close.tween_property(selected, "scale:x", 0.0, 0.175).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await close.finished
	if not _is_current(serial):
		return
	selected.show_front()
	AudioManager.play_card_flip()
	var open := create_tween()
	_active_tweens.append(open)
	open.tween_property(selected, "scale:x", SELECTED_SCALE, 0.175).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await open.finished
	if not _is_current(serial):
		return
	state = PresentationState.REVEALED
	revealed.emit()
	$Title.text = TITLE_REVEALED
	_position_glow(selected)
	_pulse_glow(String((selected as EventCard).sentiment))
	if not FunStage.kind_for(_event).is_empty():
		# 扩展卡：旧的「继续」和 L叔 说明牌都不出来，改由演出台收尾（真人按台上的「继续」，电脑自己播完）；
		# L叔 界面下台子摆进说明牌那一格（放大的卡右边），卡不再挪
		if not _lshu_mode():
			$ContinueButton.position.y = minf(
				_map_rect.end.y - $ContinueButton.size.y - 8.0,
				selected.position.y + _card_size.y * 1.125 + 8.0
			)
		_begin_stage(serial)
		return
	if _lshu_mode():
		_show_caption(selected, true)
	else:
		$ContinueButton.position.y = minf(
			_map_rect.end.y - $ContinueButton.size.y - 8.0,
			selected.position.y + _card_size.y * 1.125 + 8.0
		)
	$ContinueButton.visible = not _is_ai


func _position_glow(card: Control) -> void:
	var glow_size := _card_size * 1.20
	$Glow.size = glow_size
	$Glow.position = card.position + (_card_size - glow_size) * 0.5
	var sent := String((card as EventCard).sentiment)
	var col := Color("5D4632")
	if sent == "negative":
		col = Color("A54A3F")
	elif sent == "positive":
		col = Color("C58B32")
	$Glow.modulate = Color(col.r, col.g, col.b, 0.0)
	$Glow.visible = sent != "neutral"
	$Glow.z_index = 2


func _pulse_glow(sentiment: String) -> void:
	if sentiment == "neutral":
		$Glow.visible = false
		return
	var peak := 0.13 if sentiment == "negative" else 0.11
	var pulses := 2 if sentiment == "negative" else 1
	var tween := create_tween()
	_active_tweens.append(tween)
	for _i in pulses:
		tween.tween_property($Glow, "modulate:a", peak, 0.12)
		tween.tween_property($Glow, "modulate:a", 0.0, 0.18)


## 每张卡眼下的悬停 / 抬起动画（重排时停掉，MC-3）
var _hover_tweens := {}


func _on_card_hover(card: EventCard, entered: bool) -> void:
	if state != PresentationState.WAITING_SELECTION or _is_ai:
		return
	var index := _cards.find(card)
	if index < 0:
		return
	var tween := create_tween()
	_hover_tweens[index] = tween
	_active_tweens.append(tween)
	tween.tween_property(card, "position:y", _slot_positions[index].y - (8.0 if entered else 0.0), 0.15).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _on_continue_pressed() -> void:
	if _is_ai or state != PresentationState.REVEALED:
		return
	if _stage != null and not bool(_stage.get("done")):
		return        # 演出台还没走完（没开赛 / 没打开）：旧入口不替孩子跳过
	$ContinueButton.disabled = true
	_exit_presentation(_serial)


func _exit_presentation(serial: int) -> void:
	if not _is_current(serial):
		return
	state = PresentationState.EXITING
	var finished_event := _event.duplicate(true)
	var tween := create_tween()
	_active_tweens.append(tween)
	tween.tween_property(self, "modulate:a", 0.0, 0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await tween.finished
	if not _is_current(serial):
		return
	state = PresentationState.HIDDEN
	visible = false
	modulate = Color.WHITE
	$ContinueButton.disabled = false
	$ContinueButton.visible = false
	$Glow.visible = false
	if _caption != null:
		_caption.visible = false
	_clear_stage()
	presentation_finished.emit(finished_event)


func _is_current(serial: int) -> bool:
	return serial == _serial and GameState.session_generation == _session_generation and visible


func _radial_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.58, 1.0])
	gradient.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0.45), Color(1, 1, 1, 0)])
	var texture := GradientTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.gradient = gradient
	return texture


func _texture_style(texture: Texture2D) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = texture
	style.texture_margin_left = 34
	style.texture_margin_top = 14
	style.texture_margin_right = 34
	style.texture_margin_bottom = 14
	return style


func _play_deal_sound_after(delay: float, serial: int, pitch: float) -> void:
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if _is_current(serial):
		AudioManager.play_card_deal(pitch)


func debug_selected_card() -> EventCard:
	return _cards[_selected_index] if _selected_index >= 0 else null


# ------------------------------------------------------------------ 趣味事件演出台

func stage() -> Control:
	return _stage


## 翻开之后：卡往左挪、另两张背面淡出，右边搭演出台
func _begin_stage(serial: int) -> void:
	_clear_stage()
	_stage = FunStage.new()
	_stage.z_index = 4
	_stage.revealed.connect(func() -> void:
		if _is_current(serial):
			stage_revealed.emit(_event.duplicate(true)))
	_stage.finished.connect(func() -> void:
		if _is_current(serial) and not _is_ai:
			$ContinueButton.disabled = true
			_exit_presentation(serial))
	_stage.call("setup", _event, _is_ai, player_look)
	add_child(_stage)
	if bool(_stage.call("night_tint")):
		var night := create_tween()
		_active_tweens.append(night)
		night.tween_property($Dimmer, "color", FunStage.NIGHT_DIM, 0.35)
	_place_stage(true)
	if _is_ai:
		_stage.call("run_ai")


func _clear_stage() -> void:
	if _stage != null:
		_stage.call("cancel")
		_stage.queue_free()
		_stage = null
	if has_node("Dimmer"):
		$Dimmer.color = DIM_COLOR


## L叔 界面：放大的卡已经按「卡 + 说明牌」摆好（_revealed_targets），台子就放进说明牌那一格，
## 可以比说明牌宽一些（到可见区右边为止），上下不出上中回合牌和底部三组之间那条
func _place_stage_lshu(design: Vector2, animate: bool) -> void:
	var k := _hud_k
	var box := _caption_box
	# 上沿不压标题牌（台子的飘带比说明牌高）：从标题牌下面那段开始，到可见区底为止
	var top := maxf(_safe_rect.position.y, _lshu_area_top)
	var avail_h := maxf(40.0, _safe_rect.end.y - top - 8.0 * k)
	var max_w := maxf(40.0, _safe_rect.end.x - 24.0 * k - box.position.x)
	var s := minf(k, minf(max_w / design.x, minf(box.size.y + 120.0 * k, avail_h) / design.y))
	var sz := design * s
	var y := box.position.y + (box.size.y - sz.y) * 0.5
	y = clampf(y, top, maxf(top, _safe_rect.end.y - sz.y))
	_stage.scale = Vector2(s, s)
	_stage.position = Vector2(box.position.x, y).round()
	if animate:
		_stage.modulate.a = 0.0
		var tw := create_tween()
		_active_tweens.append(tw)
		tw.tween_property(_stage, "modulate:a", 1.0, 0.22).set_delay(0.08)


## 卡（放大 1.25 倍）和台子并排居中；台子按 1920×1080 的设计像素整体缩放，高度对齐卡
func _place_stage(animate: bool) -> void:
	if _stage == null or _selected_index < 0:
		return
	var selected := _cards[_selected_index]
	var view := get_viewport_rect().size if is_inside_tree() else _map_rect.size
	var k := minf(view.x / DESIGN.x, view.y / DESIGN.y)
	var card_vis := _card_size * 1.25
	var design: Vector2 = _stage.call("design_size")
	if _lshu_mode():
		_place_stage_lshu(design, animate)
		return
	var s := minf(k, (card_vis.y + 120.0 * k) / design.y)
	var gap := 28.0 * k
	var stage_w := design.x * s
	var room := _map_rect.size.x - 24.0 * k
	if card_vis.x + gap + stage_w > room:
		s = maxf(0.2, (room - card_vis.x - gap) / design.x)
		stage_w = design.x * s
	var total := card_vis.x + gap + stage_w
	var left := _map_rect.position.x + (_map_rect.size.x - total) * 0.5
	var card_top := selected.position.y + (_card_size.y - card_vis.y) * 0.5
	var card_center := Vector2(left + card_vis.x * 0.5, card_top + card_vis.y * 0.5)
	var card_pos := card_center - _card_size * 0.5
	_stage.scale = Vector2(s, s)
	var stage_top := card_top + 6.0 * k
	if design.y * s < card_vis.y:
		stage_top = card_top + (card_vis.y - design.y * s) * 0.5
	_stage.position = Vector2(left + card_vis.x + gap, stage_top)
	if animate:
		_stage.modulate.a = 0.0
		var tw := create_tween().set_parallel(true)
		_active_tweens.append(tw)
		tw.tween_property(selected, "position", card_pos, 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(_stage, "modulate:a", 1.0, 0.22).set_delay(0.08)
		for i in _cards.size():
			if i != _selected_index:
				tw.tween_property(_cards[i], "modulate:a", 0.0, 0.18)
		tw.tween_property($Glow, "position", $Glow.position + (card_pos - selected.position), 0.22)
	else:
		$Glow.position += card_pos - selected.position
		selected.position = card_pos
		for i in _cards.size():
			if i != _selected_index:
				_cards[i].modulate.a = 0.0
