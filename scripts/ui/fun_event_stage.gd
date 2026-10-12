extends Control
## 「L叔的趣味事件」翻牌后的演出台（设计 docs/design/shanhe-luren/fun-events-20260926/README.md §3.1、§4；
## 扩展包 README §3 的 fx 字段）。EventDrawOverlay 翻开一张扩展卡后，把卡挪到左边，这块台子放在右边。
## 结果在抽牌时已经定下并结算好，这里只是给孩子看：
##   dice_race  你追我赶 / 力争上游：全桌的骰子，真人点「开赛」才滚，谁最大、得几块白银留在台上
##   fists      左右为难：两只手，先点一只（只高亮、可改点），再按「打开」；点中的先开，另一只随后也张开
##   postcards  鸿雁传书（第二批）：三张明信片，先点一张，再按「翻开」；另两张随后翻开给大家看
##   photo      普天同庆：合影明信片（邮票、L叔 邮戳、每位玩家的头像和骆驼 / 小船）；同屏两位以上真人时冒「一起说：生日快乐！」
##   campfire   围炉夜话：篝火问题和电脑的回话（盖上夜色）；台子收起后问题泡泡留在对局界面上，点一下或回合结束才收
##   quiz_ai    耳听八方（电脑抽到）：题目、电脑猜的和正确答案一起亮 2 秒
##   note       其余扩展卡：L叔 把结果和原因说一遍（自动结算的都写明原因）
## 真人：不设倒计时，不自动收起；每一步都是先点、再按按钮，最后按「继续」才收起（发 finished）。
## 电脑：按电脑演出的节奏自己播完，不等人点（extra_ai_seconds 告诉 overlay 要多等多久）。
## 字体：面板标题飘带是娃娃体，其余全是圆体（LshuMatchHud 的分层）。

signal revealed      ## 揭晓了（HUD 上压着没刷新的白银这时再刷新）
signal finished      ## 真人按了「继续」/ 电脑演出播完

const Parts := preload("res://scripts/lshu_ui/lshu_fun_parts.gd")
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")

## 设计像素（1920×1080 下 1:1），整块按 k 缩放
const PANEL_W := 700.0
const FULL_H := 640.0          # 带飘带的面板高（按钮在面板下面另占 110）
const NOTE_H := 300.0
const BUTTON_H := 96.0
const INK := Color("#3A2A22")
const RESULT_BG := Color("#FFF1D6")
const NIGHT_DIM := Color(0.08, 0.05, 0.12, 0.62)

var kind := ""
var event: Dictionary = {}
var is_ai := false
var done := false
var is_revealed := false
var picked := -1
## 玩家外观：player_id -> {name, avatar: Texture2D, color: Color, flip: bool, human: bool}（GameScreen 注入；没有就用默认）
var look: Callable

var _panel: Control
var _body: Control
var _result_box: PanelContainer
var _result: Label
var _action: Button
var _continue: Button
var _picks: Array[Button] = []
var _pick_faces: Array[Control] = []
var _dice: Array[TextureRect] = []
var _dice_badges: Array[Control] = []
var _serial := 0
var _vis_rng := RandomNumberGenerator.new()   # 只给骰子翻滚的动画用，不碰规则随机数


static func kind_for(ev: Dictionary) -> String:
	if not ev.has("expansion_id"):
		return ""
	var fx: Dictionary = ev.get("fx", {}) if ev.get("fx") is Dictionary else {}
	if fx.has("dice_race"):
		return "dice_race"
	if fx.has("ceremony"):
		var c := String((fx["ceremony"] as Dictionary).get("kind", ""))
		if c == "two_fists":
			return "fists"
		if c == "three_postcards":
			return "postcards"
	if String(ev.get("presentation_fx", "")) == "group_photo":
		return "photo"
	if fx.has("flavor_prompt"):
		return "campfire"
	if fx.has("sound_quiz") and (fx["sound_quiz"] as Dictionary).has("ai_guess"):
		return "quiz_ai"
	return "note"


## 电脑演出在原来 3.35 秒上要多等的秒数（设计 §3.3：赛骰 +1.5、揭晓 +1、合影连原来的停留在 2 秒以内，听声亮 2 秒；
## 每张最多加 1.5 秒，听声例外）
static func extra_ai_seconds(ev: Dictionary) -> float:
	match kind_for(ev):
		"dice_race":
			return 1.5
		"fists", "postcards":
			return 1.0
		"photo", "campfire":
			return 0.5
		"quiz_ai":
			return 2.0
		"note":
			return 0.4
	return 0.0


## 需要等揭晓才刷新 HUD 白银的演出
static func holds_silver(ev: Dictionary) -> bool:
	return kind_for(ev) in ["dice_race", "fists", "postcards"]


func _init() -> void:
	name = "FunEventStage"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vis_rng.seed = 20260927


func design_size() -> Vector2:
	if kind == "note":
		return Vector2(PANEL_W, NOTE_H + 16.0 + BUTTON_H)
	return Vector2(PANEL_W, FULL_H + 16.0 + BUTTON_H)


func night_tint() -> bool:
	return kind == "campfire" and bool(_fx("flavor_prompt").get("night_tint", false))


func setup(ev: Dictionary, ai: bool, look_provider: Callable = Callable()) -> void:
	event = ev.duplicate(true)
	is_ai = ai
	look = look_provider
	kind = kind_for(event)
	size = design_size()
	_build()


# ------------------------------------------------------------------ 公共动作（测试和按钮都走这里）

## 真人点第 i 个（拳头 / 明信片）：只高亮，可以改点
func pick(i: int) -> void:
	if done or is_revealed or i < 0 or i >= _picks.size():
		return
	picked = i
	_paint_picks()
	if _action != null:
		_action.disabled = is_ai
	_set_result(_hint_after_pick())


## 「开赛」「打开」「翻开」
func act() -> void:
	if done or is_revealed:
		return
	match kind:
		"dice_race":
			_run_dice(true)
		"fists", "postcards":
			if picked < 0:
				return
			_open_picked()


## 「继续」
func finish() -> void:
	if done:
		return
	if kind in ["dice_race", "fists", "postcards"] and not is_revealed:
		return
	done = true
	finished.emit()


## 电脑：自己把这一出播完（overlay 在翻牌后调；时长由 extra_ai_seconds 预留）
func run_ai() -> void:
	var serial := _serial
	match kind:
		"dice_race":
			await _wait(0.15)
			if serial == _serial:
				_run_dice(false)
		"fists", "postcards":
			await _wait(0.3)
			if serial != _serial:
				return
			var slot := int(_fx("ceremony").get("ai_pick_slot", 0))
			picked = clampi(slot, 0, maxi(0, _picks.size() - 1))
			_paint_picks()
			await _wait(0.35)
			if serial == _serial:
				_open_picked()
		_:
			_mark_revealed()


func cancel() -> void:
	_serial += 1


# ------------------------------------------------------------------ 搭建

func _build() -> void:
	var sea := String(event.get("event_id", "")).contains("_sea_")
	if kind == "note":
		_build_note()
	else:
		_panel = Control.new()
		_panel.name = "Panel"
		_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		Parts.place(_panel, Rect2(0, 0, PANEL_W, FULL_H))
		add_child(_panel)
		var bg := Parts.hud_nine("panel_satchel", true)
		Parts.place(bg, Rect2(0, 44, PANEL_W, FULL_H - 44))
		_panel.add_child(bg)
		_panel.add_child(Parts.ribbon_title(_panel_title(), Rect2(110, -8, 480, 128), sea))
		_body = Control.new()
		_body.name = "Body"
		_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		Parts.place(_body, Rect2(40, 124, PANEL_W - 80, 344))
		_panel.add_child(_body)
		_build_result_box(Rect2(38, 470, PANEL_W - 76, 124))
		match kind:
			"dice_race":
				_build_dice()
			"fists":
				_build_fists()
			"postcards":
				_build_postcards()
			"photo":
				_build_photo()
			"campfire":
				_build_campfire()
			"quiz_ai":
				_build_quiz_ai()
	_build_buttons()
	_set_result(_initial_text())
	if kind not in ["dice_race", "fists", "postcards"] and not is_ai:
		_mark_revealed()


func _panel_title() -> String:
	match kind:
		"dice_race":
			return "赛骰"
		"fists":
			return "猜猜在哪只手"
		"postcards":
			return "翻一张明信片"
		"photo":
			return "合影"
		"campfire":
			return "围炉夜话"
		"quiz_ai":
			return "耳听八方"
	return String(event.get("title", ""))


func _build_result_box(r: Rect2) -> void:
	_result_box = PanelContainer.new()
	_result_box.name = "ResultBox"
	_result_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = RESULT_BG
	sb.border_color = Kit.OCHRE
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(22)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	_result_box.add_theme_stylebox_override("panel", sb)
	Parts.place(_result_box, r)
	_panel.add_child(_result_box)
	_result = Parts.label("", 27, INK, "title", 700)
	_result.name = "ResultText"
	_result.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_result.max_lines_visible = 3
	_result_box.add_child(_result)


func _build_note() -> void:
	_panel = Control.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	Parts.place(_panel, Rect2(0, 0, PANEL_W, NOTE_H))
	add_child(_panel)
	var face := Parts.image(Parts.tex(Parts.LSHU_FACE), Rect2(0, NOTE_H - 190, 150, 180))
	face.name = "LshuFace"
	_panel.add_child(face)
	var bubble := Parts.speech_bubble()
	Parts.place(bubble, Rect2(128, 0, PANEL_W - 128, NOTE_H - 20))
	_panel.add_child(bubble)
	_result = Parts.label("", 28, INK, "title", 700)
	_result.name = "ResultText"
	_result.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_result.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_result.max_lines_visible = 5
	Parts.place(_result, Rect2(128 + 62, 30, PANEL_W - 128 - 110, NOTE_H - 20 - 78))
	_panel.add_child(_result)


func _build_buttons() -> void:
	var top := (NOTE_H if kind == "note" else FULL_H) + 16.0
	var row := Rect2((PANEL_W - 340) * 0.5, top, 340, BUTTON_H)
	if kind in ["dice_race", "fists", "postcards"]:
		var text := {"dice_race": "开赛", "fists": "打开", "postcards": "翻开"}[kind] as String
		_action = Parts.candy(text, "ochre", 38)
		_action.name = "StageAction"
		Parts.place(_action, row)
		_action.disabled = is_ai or kind != "dice_race"
		_action.visible = not is_ai
		_action.pressed.connect(act)
		add_child(_action)
	_continue = Parts.candy("继续", "ochre", 38)
	_continue.name = "StageContinue"
	Parts.place(_continue, row)
	_continue.visible = not is_ai and _action == null
	_continue.pressed.connect(finish)
	add_child(_continue)


func _initial_text() -> String:
	match kind:
		"dice_race":
			return "大家一起掷骰子，点数最大的得 %d 块白银\n点「开赛」！" % int(_fx("dice_race").get("prize_silver", 1)) if not is_ai else "%s开赛啦……" % _drawer_name()
		"fists":
			return "L叔把眼镜藏在一只手里\n点一只手，再按「打开」" if not is_ai else "%s来猜……" % _drawer_name()
		"postcards":
			return "大雁衔来三张明信片\n点一张，再按「翻开」" if not is_ai else "%s来翻……" % _drawer_name()
		"photo":
			return _photo_text()
		"campfire":
			return _campfire_text()
		"quiz_ai":
			return String(event.get("effect_message", ""))
	return _note_text()


func _hint_after_pick() -> String:
	var names := ["左手", "右手"] if kind == "fists" else ["左边那张", "中间那张", "右边那张"]
	var which := String(names[picked]) if picked < names.size() else ""
	return "选好了%s（还能改）\n按「%s」揭晓" % [which, "打开" if kind == "fists" else "翻开"]


# ------------------------------------------------------------------ 赛骰

func _build_dice() -> void:
	var rolls: Array = _fx("dice_race").get("rolls", [])
	var n := maxi(1, rolls.size())
	var die := 150.0 if n <= 3 else 124.0
	var gap := 36.0 if n <= 3 else 22.0
	var total := n * die + (n - 1) * gap
	var x0 := (_body.size.x - total) * 0.5
	for i in rolls.size():
		var r: Dictionary = rolls[i]
		var x := x0 + i * (die + gap)
		var col := Control.new()
		col.name = "DiceCol_%d" % i
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		Parts.place(col, Rect2(x, 0, die, 344))
		_body.add_child(col)
		var badge := _silver_badge("+%d" % int(_fx("dice_race").get("prize_silver", 1)))
		Parts.place(badge, Rect2((die - 110) * 0.5, 0, 110, 46))
		badge.visible = false
		col.add_child(badge)
		_dice_badges.append(badge)
		var face := Parts.image(Parts.good_icon("dice"), Rect2(0, 52, die, die))
		face.name = "Die"
		face.pivot_offset = Vector2(die, die) * 0.5
		col.add_child(face)
		_dice.append(face)
		var who := _look(String(r.get("player_id", "")))
		var ring := _avatar(who, Rect2((die - 70) * 0.5, 60 + die, 70, 70))
		col.add_child(ring)
		var nm := Parts.label(String(who.get("name", r.get("display_name", ""))), 22, INK, "title", 700)
		nm.name = "Name"
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.clip_text = true
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		Parts.place(nm, Rect2(-14, 134 + die, die + 28, 30))
		col.add_child(nm)


func _run_dice(from_human: bool) -> void:
	if is_revealed:
		return
	var serial := _serial
	if _action != null:
		_action.disabled = true
	_set_result("骰子滚起来啦……")
	AudioManager.play_dice_roll()
	var rolls: Array = _fx("dice_race").get("rolls", [])
	var steps := 14
	for s in steps:
		for i in _dice.size():
			var t := _dice[i]
			t.texture = Parts.dice_face(_vis_rng.randi_range(1, 5) if _vis_rng.randf() < 0.85 else DiceSystem.FACE_EVENT)
			t.rotation = deg_to_rad(_vis_rng.randf_range(-16.0, 16.0))
			t.scale = Vector2.ONE * _vis_rng.randf_range(0.9, 1.06)
		await _wait(0.075)
		if serial != _serial:
			return
	var winners: Array = _fx("dice_race").get("winner_ids", [])
	for i in _dice.size():
		var t := _dice[i]
		t.texture = Parts.dice_face((rolls[i] as Dictionary).get("face", 1))
		t.rotation = 0.0
		t.scale = Vector2.ONE
		var bounce := t.create_tween()
		bounce.tween_property(t, "scale", Vector2(1.12, 1.12), 0.08)
		bounce.tween_property(t, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	AudioManager.play_dice_land()
	await _wait(0.25)
	if serial != _serial:
		return
	for i in _dice.size():
		var win := String((rolls[i] as Dictionary).get("player_id", "")) in winners
		_dice_badges[i].visible = win
		if not win:
			_dice[i].modulate = Color(1, 1, 1, 0.55)
	Parts.play_cue(self, event, "winner")
	_set_result(_dice_result_text())
	_mark_revealed()
	if from_human:
		_show_continue()


func _dice_result_text() -> String:
	var d := _fx("dice_race")
	var rolls: Array = d.get("rolls", [])
	var winners: Array = d.get("winner_ids", [])
	var names: Array[String] = []
	var faces: Array[String] = []
	for r in rolls:
		var who := _look(String(r.get("player_id", "")))
		var face_text := "事件面算 %d 点" % int(d.get("event_face_value", 0)) if DiceSystem.is_event_face(r.get("face")) else "%d 点" % int(r.get("value", 0))
		faces.append("%s：%s" % [String(who.get("name", "")), face_text])
		if String(r.get("player_id", "")) in winners:
			names.append(String(who.get("name", "")))
	var prize := int(d.get("prize_silver", 1))
	var lead := "%s点数最大，得 %d 块白银！" % [names[0], prize] if names.size() == 1 else "%s一样大，各得 %d 块白银！" % ["、".join(names), prize]
	var tail := lead + _move_tail().replace("\n", "")
	if rolls.size() <= 2:
		return "%s\n%s" % ["　".join(faces), tail]
	# 3–4 人：每人的点数已经画在骰子上、名字写在骰子下面，结果框只放得下三行（并列时赢家一句就占两行）：
	# 这里只说谁赢、得几块、你再走几步；有人掷到事件面时补一句算几点
	var any_event := false
	for r in rolls:
		any_event = any_event or DiceSystem.is_event_face((r as Dictionary).get("face"))
	return ("事件面算 %d 点。\n" % int(d.get("event_face_value", 0)) if any_event else "") + tail


# ------------------------------------------------------------------ 两只拳头 / 三张明信片

func _build_fists() -> void:
	var tile := 230.0
	var gap := 120.0
	var x0 := (_body.size.x - tile * 2 - gap) * 0.5
	var names := ["左手", "右手"]
	for i in 2:
		var b := _pick_button(i, Rect2(x0 + i * (tile + gap), 6, tile, tile))
		var face := Control.new()
		face.name = "Face"
		face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		Parts.place(face, Rect2(Vector2.ZERO, Vector2(tile, tile)))
		b.add_child(face)
		var q := Parts.label("?", 120, Kit.CAMEL, "title", 700)
		q.name = "Question"
		q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		q.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		Parts.place(q, Rect2(0, 0, tile, tile))
		face.add_child(q)
		_pick_faces.append(face)
		var cap := Parts.label(names[i], 30, INK, "title", 700)
		cap.name = "Caption"
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Parts.place(cap, Rect2(b.position.x, tile + 22, tile, 40))
		_body.add_child(cap)


func _build_postcards() -> void:
	var w := 180.0
	var h := 240.0
	var gap := 24.0
	var x0 := (_body.size.x - w * 3 - gap * 2) * 0.5
	for i in 3:
		var b := _pick_button(i, Rect2(x0 + i * (w + gap), 30, w, h))
		var face := Control.new()
		face.name = "Face"
		face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		Parts.place(face, Rect2(Vector2.ZERO, Vector2(w, h)))
		b.add_child(face)
		var back := Parts.image(Parts.tex(Parts.POSTCARD_BACK), Rect2(0, 0, w, h), true)
		back.name = "Back"
		face.add_child(back)
		_pick_faces.append(face)


func _pick_button(i: int, r: Rect2) -> Button:
	var b := Button.new()
	b.name = "StagePick_%d" % i
	Parts.Hud.flat_hit(b)
	Parts.place(b, r)
	b.pivot_offset = r.size * 0.5
	if kind == "fists":
		var bg := Parts.hud_nine("tile")
		bg.name = "Bg"
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		b.add_child(bg)
	else:
		var glow := Parts.image(Parts.tex(Parts.HIGHLIGHT), Rect2(-40, -30, r.size.x + 80, r.size.y + 60))
		glow.name = "Glow"
		glow.visible = false
		glow.show_behind_parent = true
		b.add_child(glow)
	var tick := Parts.Hud.ring(Kit.CREAM, 3, Kit.OCHRE)
	tick.name = "Tick"
	Parts.place(tick, Rect2(r.size.x - 46, 6, 40, 40))
	var mark := Parts.label("✓", 26, INK, "title", 700)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Parts.place(mark, Rect2(0, 0, 40, 40))
	tick.add_child(mark)
	tick.visible = false
	b.add_child(tick)
	b.disabled = is_ai
	b.set_meta("y0", r.position.y)
	b.set_meta("selected", false)
	b.pressed.connect(pick.bind(i))
	_body.add_child(b)
	_picks.append(b)
	return b


func _paint_picks() -> void:
	for i in _picks.size():
		var b := _picks[i]
		var sel := i == picked
		var bg := b.get_node_or_null("Bg") as NinePatchRect
		if bg != null:
			bg.texture = Parts.hud_tex("pocket_sel" if sel else "tile")
			var m := 30 if sel else 36
			bg.patch_margin_left = m
			bg.patch_margin_right = m
			bg.patch_margin_top = m
			bg.patch_margin_bottom = m
		var glow := b.get_node_or_null("Glow") as Control
		if glow != null:
			glow.visible = sel
		(b.get_node("Tick") as Control).visible = sel and not is_revealed
		b.set_meta("selected", sel)
		var tw := b.create_tween()
		tw.set_parallel(true)
		tw.tween_property(b, "scale", Vector2(1.06, 1.06) if sel else Vector2.ONE, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(b, "position:y", float(b.get_meta("y0")) - (16.0 if sel else 0.0), 0.14)


func _open_picked() -> void:
	if is_revealed or picked < 0:
		return
	var serial := _serial
	if _action != null:
		_action.disabled = true
	for b in _picks:
		b.disabled = true
	var c := _fx("ceremony")
	var order: Array = c.get("reveal_order", [])
	var outcome := int(order[0]) if not order.is_empty() else 0
	await _open_slot(picked, outcome)
	if serial != _serial:
		return
	var win := _is_win(outcome)
	Parts.play_cue(self, event, "reveal_win" if win else "reveal_lose")
	_set_result(_ceremony_result_text(outcome))
	_mark_revealed()
	await _wait(0.5)
	if serial != _serial:
		return
	var k := 1
	for slot in _picks.size():
		if slot == picked:
			continue
		if k < order.size():
			_open_slot(slot, int(order[k]))
		k += 1
	await _wait(0.35)
	if serial == _serial and not is_ai:
		_show_continue()


func _open_slot(slot: int, prize: int) -> void:
	var b := _picks[slot]
	var face := _pick_faces[slot]
	var tw := b.create_tween()
	tw.tween_property(b, "scale:x", 0.0, 0.14).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await tw.finished
	if not is_instance_valid(face):
		return
	for ch in face.get_children():
		face.remove_child(ch)
		ch.queue_free()
	_fill_prize(face, prize, b.size)
	if kind == "postcards":
		AudioManager.play_card_flip()
	var back := b.create_tween()
	back.tween_property(b, "scale:x", 1.06 if slot == picked else 1.0, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await back.finished


func _fill_prize(face: Control, prize: int, sz: Vector2) -> void:
	var labels: Array = _fx("ceremony").get("labels", [])
	var text := String(labels[prize]) if prize >= 0 and prize < labels.size() else ""
	if kind == "fists":
		var icon: Texture2D = Parts.tex(Parts.GLASSES) if prize == 0 else Parts.good_icon("potato_seed")
		var ih := 90.0 if prize == 0 else 150.0
		face.add_child(Parts.image(icon, Rect2(22, 24 + (150 - ih) * 0.5, sz.x - 44, ih)))
		var cap := Parts.label(text.split("：")[0], 30, INK, "title", 700)
		cap.name = "PrizeText"
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Parts.place(cap, Rect2(0, sz.y - 62, sz.x, 40))
		face.add_child(cap)
		return
	face.add_child(Parts.image(Parts.tex(Parts.POSTCARD_FACE), Rect2(Vector2.ZERO, sz), true))
	var icon2: Texture2D = Parts.silver_icon()
	if prize == 1:
		icon2 = Parts.hud_tex("icon_walk")
	elif prize == 2:
		icon2 = Parts.tex(Parts.STAMP)
	face.add_child(Parts.image(icon2, Rect2((sz.x - 76) * 0.5, 22, 76, 76)))
	var t := Parts.label(text.replace("：", "\n"), 19, INK, "title", 700)
	t.name = "PrizeText"
	t.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.max_lines_visible = 4
	Parts.place(t, Rect2(10, 106, sz.x - 20, sz.y - 118))
	face.add_child(t)


func _is_win(prize: int) -> bool:
	# 两只手：0 = 眼镜（得银）；明信片：0 = 得 2 块、1 = 走 0–6 步（都是好结果），2 = 付邮费
	return prize == 0 if kind == "fists" else prize != 2


func _ceremony_result_text(outcome: int) -> String:
	var labels: Array = _fx("ceremony").get("labels", [])
	var text := String(labels[outcome]) if outcome >= 0 and outcome < labels.size() else ""
	var who := "你" if not is_ai else _drawer_name()
	var names := ["左手", "右手"] if kind == "fists" else ["左边那张", "中间那张", "右边那张"]
	var which := String(names[picked]) if picked >= 0 and picked < names.size() else ""
	var head := text.trim_suffix("。")
	var verb := "点" if kind == "fists" else "翻"
	# 两行：「你点了右手，是眼镜！」/「猜中啦，得1块白银。」；「你翻了中间那张：」/「明信片上画着远方！走 0–6 步。」
	var line := "%s%s了%s：\n%s。" % [who, verb, which, head]
	if head.contains("："):
		var bits := head.split("：", true, 1)
		if kind == "fists":
			line = "%s%s了%s，是%s！\n%s。" % [who, verb, which, bits[0], bits[1]]
		else:
			line = "%s%s了%s：\n%s！%s。" % [who, verb, which, bits[0], bits[1]]
	# 付邮费但没有白银：规则层写了「你没有白银，邮费免了。」
	if String(event.get("effect_message", "")).contains("邮费免了"):
		line += "没有白银，邮费免了。"
	return line if line.contains("步") else line + _move_tail().replace("\n", "")


# ------------------------------------------------------------------ 合影

func _build_photo() -> void:
	var photo := Parts.image(Parts.tex("res://assets/game/ui/event_cards_v2/event_paper_768x1024.png"), Rect2(0, 0, _body.size.x, 330), true)
	photo.name = "PhotoPaper"
	_body.add_child(photo)
	var gains: Array = (event.get("fx", {}) as Dictionary).get("silver_gain", [])
	var ids: Array[String] = []
	for g in gains:
		ids.append(String((g as Dictionary).get("player_id", "")))
	if ids.is_empty():
		for p in GameState.players:
			ids.append((p as PlayerState).player_id)
	# 上一行：左边「L叔过生日啦！」，右上角邮票（里面是 L叔）和压在邮票边上的 L叔 邮戳；下面一排是每位玩家
	var cap := Parts.label("L叔过生日啦！", 30, Kit.SATCHEL, "title", 700)
	cap.name = "PhotoCaption"
	Parts.place(cap, Rect2(20, 10, 300, 44))
	_body.add_child(cap)
	var stamp := Parts.image(Parts.tex(Parts.STAMP), Rect2(_body.size.x - 100, 0, 88, 94))
	stamp.name = "Stamp"
	_body.add_child(stamp)
	_body.add_child(Parts.image(Parts.tex(Parts.LSHU_FACE), Rect2(_body.size.x - 88, 14, 64, 66)))
	var mark := Parts.image(Parts.tex(Parts.POSTMARK), Rect2(_body.size.x - 196, 12, 100, 69))
	mark.name = "Postmark"
	mark.modulate = Color(1, 1, 1, 0.9)
	_body.add_child(mark)
	var n := ids.size()
	var cell := 124.0
	var gap := 20.0 if n > 3 else 40.0
	var total := n * cell + (n - 1) * gap
	var x0 := (_body.size.x - total) * 0.5
	var humans := 0
	for i in n:
		var who := _look(ids[i])
		if bool(who.get("human", false)):
			humans += 1
		var x := x0 + i * (cell + gap)
		var av := _avatar(who, Rect2(x + 14, 102, 96, 96))
		av.name = "PhotoFace_%d" % i
		_body.add_child(av)
		var p := _player(ids[i])
		var ride := Parts.image(Parts.tex(Parts.SHIP_ICON if p != null and p.active_transport == GameData.Transport.SHIP else Parts.CAMEL_ICON), Rect2(x + 78, 154, 50, 46))
		_body.add_child(ride)
		var nm := Parts.label(String(who.get("name", "")), 22, INK, "title", 700)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.clip_text = true
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		Parts.place(nm, Rect2(x - 10, 200, cell + 20, 30))
		_body.add_child(nm)
		var badge := _silver_badge("+%d" % int((gains[i] as Dictionary).get("amount", 1)) if i < gains.size() else "+1")
		Parts.place(badge, Rect2(x + 12, 232, 100, 42))
		_body.add_child(badge)
	if humans >= 2:
		var bub := Parts.speech_bubble()
		bub.name = "TogetherBubble"
		Parts.place(bub, Rect2((_body.size.x - 330) * 0.5, 280, 330, 64))
		_body.add_child(bub)
		var say := Parts.label("一起说：生日快乐！", 26, INK, "title", 700)
		say.name = "TogetherText"
		say.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		say.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		Parts.place(say, Rect2((_body.size.x - 330) * 0.5 + 20, 282, 290, 48))
		_body.add_child(say)


func _photo_text() -> String:
	return "每位玩家各得 1 块白银。" + _move_tail()


# ------------------------------------------------------------------ 篝火

func _build_campfire() -> void:
	var fp := _fx("flavor_prompt")
	_body.add_child(Parts.image(Parts.tex(Parts.LSHU_FACE), Rect2(0, 10, 124, 146)))
	var bubble := Parts.speech_bubble()
	Parts.place(bubble, Rect2(112, 0, _body.size.x - 112, 150))
	_body.add_child(bubble)
	var q := Parts.label(String(fp.get("text", "")), 30, INK, "title", 700)
	q.name = "Question"
	q.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	q.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	q.max_lines_visible = 3
	Parts.place(q, Rect2(166, 16, _body.size.x - 112 - 96, 96))
	_body.add_child(q)
	var y := 166.0
	var replies: Array = (fp.get("ai_replies", []) as Array).filter(func(r): return not String((r as Dictionary).get("text", "")).is_empty())
	var per := clampi(5 / maxi(1, replies.size()), 1, 4)
	for reply in replies:
		var r := reply as Dictionary
		var who := _look(String(r.get("player_id", "")))
		_body.add_child(_avatar(who, Rect2(6, y, 52, 52)))
		var line := Parts.label("%s：%s" % [String(r.get("display_name", who.get("name", ""))), String(r.get("text", ""))], 23, INK, "body", 500)
		line.name = "Reply"
		line.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		line.max_lines_visible = per
		Parts.place(line, Rect2(70, y + 4, _body.size.x - 74, 32.0 * per))
		_body.add_child(line)
		y += maxf(60.0, 32.0 * per + 8.0)
		if y > 320.0:
			break


func _campfire_text() -> String:
	return "大家轮流说一句，不想说也可以。" + _move_tail()


# ------------------------------------------------------------------ 电脑听声

func _build_quiz_ai() -> void:
	var q := _fx("sound_quiz")
	var options: Array = q.get("options", [])
	var labels: Dictionary = q.get("option_labels", {})
	var guess := String(q.get("ai_guess", ""))
	var right := String(q.get("sound_id", ""))
	var w := 180.0
	var gap := 30.0
	var x0 := (_body.size.x - w * options.size() - gap * (options.size() - 1)) * 0.5
	for i in options.size():
		var id := String(options[i])
		var tile := Control.new()
		tile.name = "QuizOption_%s" % id
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		Parts.place(tile, Rect2(x0 + i * (w + gap), 40, w, 190))
		_body.add_child(tile)
		var bg := Parts.hud_nine("pocket_sel" if id == right else "tile")
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tile.add_child(bg)
		tile.add_child(Parts.image(Parts.tex(Parts.MUSIC_LENS), Rect2((w - 80) * 0.5, 22, 80, 70)))
		var t := Parts.label(String(labels.get(id, id)), 28, INK, "title", 700)
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Parts.place(t, Rect2(8, 104, w - 16, 40))
		tile.add_child(t)
		if id == guess:
			var who := _look(String(event.get("drawn_by", "")))
			var av := _avatar(who, Rect2(-14, -14, 58, 58))
			tile.add_child(av)
			var g := Parts.label("%s猜的" % String(who.get("name", "")), 20, Kit.INK_SOFT, "body", 500)
			g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			Parts.place(g, Rect2(-20, 196, w + 40, 30))
			tile.add_child(g)
		if id == right:
			var mark := Parts.label("✓ 就是它", 22, Color("#4E8A3C"), "title", 700)
			mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			Parts.place(mark, Rect2(0, 146, w, 32))
			tile.add_child(mark)


# ------------------------------------------------------------------ 结果文字

func _note_text() -> String:
	var fx: Dictionary = event.get("fx", {}) if event.get("fx") is Dictionary else {}
	if fx.has("gifts"):
		var lines: Array[String] = []
		for g in fx["gifts"]:
			var who := _look(String((g as Dictionary).get("player_id", "")))
			lines.append("%s：%s" % [String(who.get("name", "")), String((g as Dictionary).get("message", ""))])
		return "\n".join(lines)
	# 规则层把几条效果的结果用空格连在一起（「付1块白银，或点一件要丢的货。 可移动 0–2 步。」）：一条一行
	var msg := String(event.get("effect_message", "")).strip_edges().replace("。 ", "。\n")
	return msg if not msg.is_empty() else "事件已结算。"


func _move_tail() -> String:
	if is_ai:
		return ""
	var p := _player(String(event.get("drawn_by", "")))
	if p != null and p.pending_event_needs_move and p.movement_budget > 0 and not EventSystem.has_pending_decision():
		return "\n你再走 0–%d 步。" % p.movement_budget
	return ""


func _set_result(text: String) -> void:
	if _result != null:
		_result.text = text


func _show_continue() -> void:
	if _action != null:
		_action.visible = false
	if _continue != null:
		_continue.visible = not is_ai
		_continue.disabled = false


func _mark_revealed() -> void:
	if is_revealed:
		return
	is_revealed = true
	for b in _picks:
		(b.get_node("Tick") as Control).visible = false
	revealed.emit()


# ------------------------------------------------------------------ 小工具

func _fx(key: String) -> Dictionary:
	var fx: Variant = event.get("fx", {})
	if fx is Dictionary and (fx as Dictionary).get(key) is Dictionary:
		return (fx as Dictionary)[key]
	return {}


func _player(pid: String) -> PlayerState:
	for p in GameState.players:
		if (p as PlayerState).player_id == pid:
			return p
	return null


func _drawer_name() -> String:
	return String(_look(String(event.get("drawn_by", ""))).get("name", ""))


func _look(pid: String) -> Dictionary:
	if look.is_valid():
		var d: Variant = look.call(pid)
		if d is Dictionary and not (d as Dictionary).is_empty():
			return d
	var p := _player(pid)
	if p == null:
		return {"name": pid, "avatar": null, "color": Kit.CAMEL, "flip": false, "human": false}
	return {
		"name": p.display_name,
		"avatar": Parts.tex("res://assets/game/ui/lshu_setup/token_%s.png" % p.color_id),
		"color": Kit.CAMEL,
		"flip": false,
		"human": p.is_local_human(),
	}


func _avatar(who: Dictionary, r: Rect2) -> Control:
	var root := Control.new()
	root.name = "Avatar"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Parts.place(root, r)
	var ring := Parts.Hud.ring(who.get("color", Kit.CAMEL), maxi(3, int(r.size.x * 0.07)), Kit.CREAM)
	ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(ring)
	var av := Parts.Hud.round_avatar()
	av.texture = who.get("avatar")
	av.flip_h = bool(who.get("flip", false))
	var pad := r.size.x * 0.08
	Parts.place(av, Rect2(pad, pad, r.size.x - pad * 2, r.size.y - pad * 2))
	root.add_child(av)
	return root


## 一个小银锭 + 「+1」
func _silver_badge(text: String) -> Control:
	var root := PanelContainer.new()
	root.name = "SilverBadge"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Kit.CREAM
	sb.border_color = Kit.OCHRE
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(22)
	sb.content_margin_left = 10
	sb.content_margin_right = 12
	root.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(row)
	var ic := TextureRect.new()
	ic.texture = Parts.silver_icon()
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.custom_minimum_size = Vector2(34, 34)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(ic)
	var t := Parts.label(text, 26, INK, "title", 700)
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(t)
	return root


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


## 测试 / 自动化用：台上的按钮、可点的格子
func action_button() -> Button:
	return _action


func continue_button() -> Button:
	return _continue


func pick_button(i: int) -> Button:
	return _picks[i] if i >= 0 and i < _picks.size() else null


func result_text() -> String:
	return _result.text if _result != null else ""
