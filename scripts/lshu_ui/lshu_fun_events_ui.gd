extends Node
## 「L叔的趣味事件」在对局界面里的那一半（2026-09-27；设计 docs/design/shanhe-luren/fun-events-20260926/README.md，
## 待决字段和 fx 见 data/expansions/lshu_fun_events/README.md）。GameScreen 在几个固定的点调它，它自己不改规则：
##   · 真人要选的待决（付银或丢货 PAY_OR_DROP、听声猜物 SOUND_QUIZ；第二批的二选一 CHOOSE_ONE、看牌 PEEK_EVENT_DECK）
##     在市集面板里开一块选择面板（lshu_choice_view.gd）：点格子只高亮 + 预览（点错能改），成交只在右下主按钮；
##     挎包口袋也能点（付银或丢货时点一件货 = 选它）。没选时主按钮是灰的，不设倒计时，不替孩子自动放弃。
##   · 听声猜物：面板打开时播那一段声音（SoundDirector.play_event_cue；没有导演 / 静音时不出题，提交 {muted: true}，
##     结果写明「声音关着，这次不猜，改走 0–4 步」）。
##   · 丢货过滤版（碎碎平安、呦呦鹿鸣）：卡上没说的货格压暗，点了告诉孩子卡上说的是哪几样。
##   · 电脑抽的卡改了真人的白银或货：轮到那位真人时，右下提示里留一两行结果和原因（换人卡上也写），掷骰后才收。
##   · 围炉夜话：篝火问题泡泡留在界面上（不挡操作），点一下收起；真人抽到时这回合结束收，电脑抽到时下一位真人走完自己的回合收。
##   · 赛骰、左右为难、鸿雁传书：揭晓之前 HUD 上的白银先按抽牌前显示，揭晓后再刷新。
##   · 真人做完选择后的结果（「付1块白银。」「猜对了……可走 0–5 步。」）留在走棋提示里，走完这一步才收。

const FunStage := preload("res://scripts/ui/fun_event_stage.gd")
const Parts := preload("res://scripts/lshu_ui/lshu_fun_parts.gd")

const DECISION_OPS: Array[String] = ["PAY_OR_DROP", "SOUND_QUIZ", "CHOOSE_ONE", "PEEK_EVENT_DECK"]
## 和 GameScreen 的 COLOR_* 同值（反馈行的颜色）
const COLOR_SUCCESS := Color("3F7D63")
const COLOR_FAILURE := Color("A54A3F")
const COLOR_INFO := Color("7D5A3A")
const MAX_NOTICE_LINES := 3

## 测试注入：听声题的播放器（返回 true = 声音真的放出来了）。不设时走 SoundDirector。
var quiz_player: Callable

var screen: Control                  # GameScreen
var _sel := ""                       # 付银或丢货："pay" / "good:<id>"；其余：选项 id
var _sel_sig := ""
var _submitting := false
var _after: Dictionary = {}          # 二选一「放长线」再掷骰的结果：留在面板上，按「继续」才收
var _quiz_sig := ""                  # 这道听声题已经处理过（放过声音 / 已按静音提交）
var _quiz_live := false              # 声音放出来了，面板出题
var _notices: Dictionary = {}        # player_id -> Array[String]
var _move_note := ""                 # 选完之后的结果，留在走棋提示里
var _move_note_pid := ""
var _loss_hint := ""
var _campfire_owner := ""            # 抽到围炉夜话的真人（这回合结束收）；"*" = 电脑抽的（下一位真人走完回合收）
var _hold: Dictionary = {}           # player_id -> 揭晓前显示的白银
var _hold_supply := -1
var _presenting := false             # 真人的抽卡演出还开着：选择面板等它收了再开（卡和台子占满地图）


func _init() -> void:
	name = "LshuFunEventsUi"


func reset() -> void:
	_sel = ""
	_sel_sig = ""
	_submitting = false
	_after = {}
	_quiz_sig = ""
	_quiz_live = false
	_notices.clear()
	_move_note = ""
	_move_note_pid = ""
	_loss_hint = ""
	_campfire_owner = ""
	_hold.clear()
	_hold_supply = -1
	_presenting = false
	var hud := _hud()
	if hud != null:
		hud.hide_campfire()


# ================================================================ 待决

## 当前真人的扩展待决（付银或丢货 / 听声 / 二选一 / 看牌）；不是就返回 {}
func pending() -> Dictionary:
	if GameState.players.is_empty() or not EventSystem.has_pending_decision():
		return {}
	var p: Dictionary = GameState.pending_event_decision
	var op := String(p.get("operation", ""))
	if op not in DECISION_OPS:
		return {}
	var cur := GameState.current_player()
	if not cur.is_local_human() or String(p.get("acting_player_id", "")) != cur.player_id:
		return {}
	_sync_sig(p)
	return p


## 面板开着（选择面板或「放长线」的结果）
func is_active() -> bool:
	return not _after.is_empty() or _decision_visible()


## 主按钮归这里管：面板开着，或者听声题还在等声音（按钮先灰着写「就是它」）
func owns_primary() -> bool:
	return not _after.is_empty() or not pending().is_empty()


## 面板要不要开：听声题只有声音真的放出来才开（静音时直接提交，不开面板）
func _decision_visible() -> bool:
	var p := pending()
	if p.is_empty() or _presenting:
		return false
	if String(p.get("operation", "")) == "SOUND_QUIZ":
		return _quiz_live
	return true


func _sync_sig(p: Dictionary) -> void:
	var sig := "%s|%s|%s" % [String(p.get("event_id", "")), String(p.get("operation", "")), str(GameState.round_index)]
	if sig != _sel_sig:
		_sel_sig = sig
		_sel = ""
		_submitting = false


func title_of(event_id: String) -> String:
	return String(GameState.content.get("event_definitions", {}).get(event_id, {}).get("title", ""))


func title() -> String:
	if not _after.is_empty():
		return String(_after.get("title", ""))
	var p := pending()
	var def: Dictionary = GameState.content.get("event_definitions", {}).get(String(p.get("event_id", "")), {})
	return String(def.get("title", "趣味事件"))


## 选择面板的内容（LshuChoiceView.set_view 的格式）
func view() -> Dictionary:
	if not _after.is_empty():
		return _after_view()
	var p := pending()
	match String(p.get("operation", "")):
		"PAY_OR_DROP":
			return _pay_or_drop_view(p)
		"SOUND_QUIZ":
			return _quiz_view(p)
		"CHOOSE_ONE":
			return _choose_one_view(p)
		"PEEK_EVENT_DECK":
			return _peek_view(p)
	return {}


func _pay_or_drop_view(p: Dictionary) -> Dictionary:
	var player := GameState.current_player()
	var pay := int(p.get("pay_silver", 1))
	var can_pay := bool(p.get("can_pay", false))
	var can_drop := bool(p.get("can_drop", false))
	var goods: Array = p.get("legal_give_goods", [])
	var tiles := []
	for g in goods:
		var id := String(g)
		var n := player.held_count(id)
		tiles.append({
			"id": "good:" + id, "kind": "good", "icon": Parts.good_icon(id),
			"text": _good_name(id) + (" ×%d" % n if n > 1 else ""), "sub": "",
			"enabled": can_drop and not _submitting, "selected": _sel == "good:" + id,
		})
	var sections := [
		{"head": "① 付白银", "tiles": [{
			"id": "pay", "kind": "wide", "icon": Parts.silver_icon(),
			"text": String(p.get("pay_label", "付%d块白银" % pay)),
			"sub": ("付了还剩 %d 块白银" % (player.silver - pay)) if can_pay else String(p.get("pay_blocked_reason", "没有白银")),
			"enabled": can_pay and not _submitting, "selected": _sel == "pay",
		}]},
		{"head": "② 或者丢 1 件货", "note": "" if can_drop else String(p.get("drop_blocked_reason", "挎包是空的")) + "，只能付白银", "tiles": tiles},
	]
	if not can_pay:
		sections[0]["note"] = String(p.get("pay_blocked_reason", "没有白银")) + "，只能丢 1 件货"
	var preview := {}
	if _sel == "pay":
		preview = {"icon": Parts.silver_icon(), "text": "付 %d 块白银，还剩 %d 块" % [pay, player.silver - pay]}
	elif _sel.begins_with("good:"):
		var gid := _sel.trim_prefix("good:")
		preview = {"icon": Parts.good_icon(gid), "text": "丢掉 1 个%s" % _good_name(gid)}
	return {
		"subtitle": "二选一：付 %d 块白银，或者丢 1 件货。先点一样，再按下面的按钮" % pay,
		"sections": sections,
		"preview": preview,
		"hint": "付%d块白银，或点一件要丢的货" % pay,
	}


func _quiz_view(p: Dictionary) -> Dictionary:
	var labels: Dictionary = p.get("option_labels", {})
	var images := _quiz_images()
	var tiles := []
	for o in p.get("options", []):
		var id := String(o)
		var img: Texture2D = images.get(id)
		tiles.append({
			"id": id, "kind": "big", "icon": img if img != null else Parts.tex(Parts.MUSIC_LENS),
			"text": String(labels.get(id, id)), "sub": "",
			"enabled": not _submitting, "selected": _sel == id,
		})
	var preview := {}
	if not _sel.is_empty():
		preview = {"icon": Parts.tex(Parts.MUSIC_LENS), "text": "你选的是：%s（还能改）" % String(labels.get(_sel, _sel))}
	return {
		"subtitle": "听一听，这是什么声音？点一张图，再按「就是它」",
		"sections": [{"head": "三选一", "tiles": tiles}],
		"preview": preview,
		"hint": "点一张你听到的",
	}


func _choose_one_view(p: Dictionary) -> Dictionary:
	var tiles := []
	var chosen := {}
	for o in p.get("options", []):
		var od := o as Dictionary
		var id := String(od.get("id", ""))
		var available := bool(od.get("available", false))
		var tile := {
			"id": id, "kind": "wide", "icon": _option_icon(od),
			"text": String(od.get("label", "")),
			"sub": String(od.get("preview", "")) if available else "做不到：%s" % String(od.get("blocked_reason", "")),
			"enabled": available and not _submitting, "selected": _sel == id,
		}
		tiles.append(tile)
		if _sel == id:
			chosen = tile
	return {
		"subtitle": "二选一：先点一个，再按「就这样」",
		"sections": [{"head": "选一个", "tiles": tiles}],
		"preview": {} if chosen.is_empty() else {"icon": chosen.get("icon"), "text": String(chosen.get("sub", ""))},
		"hint": "先点一个，看看会怎样",
	}


func _peek_view(p: Dictionary) -> Dictionary:
	var subs := {"KEEP_TOP": "下一个抽这堆牌的人会抽到它", "TO_BOTTOM": "它去最底下了"}
	var names := {"KEEP_TOP": "留在顶上", "TO_BOTTOM": "压到最底下"}
	var tiles := []
	for id in ["KEEP_TOP", "TO_BOTTOM"]:
		tiles.append({
			"id": id, "kind": "wide", "icon": null, "text": String(names[id]), "sub": String(subs[id]),
			"enabled": not _submitting, "selected": _sel == id,
		})
	return {
		"subtitle": "下一张事件卡是「%s」。留在顶上，还是压到最底下？" % String(p.get("title", "")),
		"card_event_id": String(p.get("peek_event_id", "")),
		"sections": [{"head": "这张卡放哪儿？", "tiles": tiles}],
		"preview": {} if _sel.is_empty() else {"icon": null, "text": String(subs.get(_sel, ""))},
		"hint": "先点一个",
	}


func _after_view() -> Dictionary:
	var face: Variant = _after.get("face")
	var won := bool(_after.get("won", false))
	return {
		"subtitle": String(_after.get("subtitle", "")),
		"sections": [{"head": "再掷一次", "tiles": [{
			"id": "after_dice", "kind": "big", "icon": Parts.dice_face(face),
			"text": "事件面" if DiceSystem.is_event_face(face) else "%d 点" % int(face),
			"sub": "钓到大鱼了！" if won else "鱼跑了", "enabled": true, "selected": won,
		}]}],
		"preview": {"icon": Parts.silver_icon() if won else null, "text": String(_after.get("message", ""))},
		"hint": "",
	}


func _option_icon(o: Dictionary) -> Texture2D:
	for e in o.get("effects", []):
		match String((e as Dictionary).get("op", "")):
			"MOVE_BY_RANGE":
				return Parts.hud_tex("icon_walk")
			"GAIN_STARTING_RESOURCE":
				var snap: Dictionary = GameState.current_player().starting_resource_snapshot
				if String(snap.get("resource_kind", "")) == "GOOD":
					return Parts.good_icon(String(snap.get("resource_id", "")))
				return Parts.silver_icon()
			"DICE_CHANCE":
				return Parts.good_icon("dice")
	return null


func _quiz_images() -> Dictionary:
	var out := {}
	var pool := ExpansionLoader.presentation(GameState.content, "sound_quiz_v1")
	for snd in pool.get("sounds", []):
		var path := String((snd as Dictionary).get("image", ""))
		if not path.is_empty() and ResourceLoader.exists(path):
			out[String(snd.get("id", ""))] = load(path) as Texture2D
	return out


## 点了面板上的一格
func on_pick(id: String) -> void:
	if not screen.call("_can_accept_human") or _submitting:
		return
	if not _after.is_empty():
		return
	var p := pending()
	if p.is_empty():
		return
	match String(p.get("operation", "")):
		"PAY_OR_DROP":
			if id == "pay" and not bool(p.get("can_pay", false)):
				return
			if id.begins_with("good:") and (not bool(p.get("can_drop", false)) or id.trim_prefix("good:") not in p.get("legal_give_goods", [])):
				return
		"CHOOSE_ONE":
			for o in p.get("options", []):
				if String((o as Dictionary).get("id", "")) == id and not bool((o as Dictionary).get("available", false)):
					return
	_sel = "" if _sel == id else id
	_changed()


## 付银或丢货时点挎包口袋 = 选这件货（和面板上的格子是同一份选择）
func handles_pocket() -> bool:
	return String(pending().get("operation", "")) == "PAY_OR_DROP"


func on_pocket(good_id: String) -> void:
	var p := pending()
	if not bool(p.get("can_drop", false)):
		screen.call("_set_feedback", String(p.get("drop_blocked_reason", "挎包是空的")), COLOR_INFO)
		return
	on_pick("good:" + good_id)


func selected_good() -> String:
	return _sel.trim_prefix("good:") if _sel.begins_with("good:") and handles_pocket() else ""


func primary_text() -> String:
	if not _after.is_empty():
		return "继续"
	var p := pending()
	match String(p.get("operation", "")):
		"PAY_OR_DROP":
			if _sel == "pay":
				return "确认付%d块白银" % int(p.get("pay_silver", 1))
			if _sel.begins_with("good:"):
				return "确认丢失%s" % _good_name(_sel.trim_prefix("good:"))
			return "先选一样"
		"SOUND_QUIZ":
			return "就是它"
		"CHOOSE_ONE":
			return "就这样"
		"PEEK_EVENT_DECK":
			return "确认"
	return "确认"


func primary_enabled() -> bool:
	if not _after.is_empty():
		return true
	return not _sel.is_empty() and not _submitting and not pending().is_empty()


func prompt() -> String:
	if not _after.is_empty():
		return String(_after.get("message", "")) + " 按「继续」"
	var p := pending()
	match String(p.get("operation", "")):
		"PAY_OR_DROP":
			return "付%d块白银，或点一件要丢的货" % int(p.get("pay_silver", 1)) if _sel.is_empty() else "按「%s」" % primary_text()
		"SOUND_QUIZ":
			return "点一张你听到的，再按「就是它」"
		"CHOOSE_ONE":
			return "先点一个，再按「就这样」"
		"PEEK_EVENT_DECK":
			return "留在顶上，还是压到最底下？点一个再按「确认」"
	return ""


## 右下主按钮
func confirm() -> void:
	if not screen.call("_can_accept_human"):
		return
	if not _after.is_empty():
		_after = {}
		_block_and_refresh()
		screen.call("_after_human_move_settled")
		return
	var p := pending()
	if p.is_empty() or _sel.is_empty() or _submitting:
		return
	var choice := {}
	match String(p.get("operation", "")):
		"PAY_OR_DROP":
			choice = {"pay_silver": true} if _sel == "pay" else {"give_goods": {_sel.trim_prefix("good:"): int(p.get("required_give_count", 1))}}
		"SOUND_QUIZ":
			choice = {"option_id": _sel}
		"CHOOSE_ONE":
			choice = {"option_id": _sel}
		"PEEK_EVENT_DECK":
			choice = {"choice": _sel}
	_submit(p, choice)


func _submit(p: Dictionary, choice: Dictionary) -> void:
	_submitting = true
	var op := String(p.get("operation", ""))
	var event_ref := {"event_id": String(p.get("event_id", ""))}
	var result := EventSystem.resolve_pending_decision(choice)
	_submitting = false
	var ok := bool(result.get("success", false))
	var msg := String(result.get("message", "事件选择失败。"))
	if not ok:
		screen.call("_set_feedback", msg, COLOR_FAILURE)
		_changed()
		return
	Parts.play_cue(screen, event_ref, "confirm")
	_sel = ""
	_quiz_live = false
	_quiz_sig = ""        # 这道题答完了：下一道听声题（哪怕题面一模一样）照常出题

	screen.set("_turn_result_text", msg)
	screen.call("_set_feedback", msg, COLOR_SUCCESS)
	var fx: Dictionary = result.get("fx", {}) if result.get("fx") is Dictionary else {}
	if op == "CHOOSE_ONE" and fx.has("dice_chance"):
		var dc: Dictionary = fx["dice_chance"]
		_after = {
			"title": String(GameState.content.get("event_definitions", {}).get(String(p.get("event_id", "")), {}).get("title", "")),
			"subtitle": "原地再掷一次骰：3–5 点就钓到大鱼",
			"face": dc.get("face"), "won": bool(dc.get("won", false)), "message": msg,
		}
	else:
		_set_move_note("%s：%s" % [title_of(String(p.get("event_id", ""))), msg])
	_block_and_refresh()
	if _after.is_empty():
		screen.call("_after_human_move_settled")


func _block_and_refresh() -> void:
	screen.call("_block_dock_clicks")
	screen.call("_refresh")


func _changed() -> void:
	screen.call("_refresh_cargo_slot_visuals")
	screen.call("_refresh_action_buttons")


# ================================================================ 听声猜物

## 待决里有一道还没处理的听声题、演出也收了：放声音出题；放不出来就按「声音关着」提交
func maybe_open_quiz() -> void:
	var p := pending()
	if String(p.get("operation", "")) != "SOUND_QUIZ":
		return
	# 带上轮数和抽牌人：同一张卡洗回来再抽到、正好出了同一道题时也要重新出题（否则面板永远不开，孩子卡住）
	var sig := "%s|%s|%s|%s|%s" % [
		str(GameState.round_index), String(p.get("acting_player_id", "")),
		String(p.get("event_id", "")), String(p.get("sound_id", "")), ",".join(p.get("options", [])),
	]
	if sig == _quiz_sig:
		return
	var overlay := screen.get_node_or_null("%EventDrawOverlay") as Control
	if overlay != null and overlay.visible:
		return
	_quiz_sig = sig
	var played := false
	if quiz_player.is_valid():
		played = bool(quiz_player.call(String(p.get("sound_id", ""))))
	else:
		played = Parts.play_quiz_sound(screen, String(p.get("sound_id", "")))
	if played:
		_quiz_live = true
		_changed()
		return
	_quiz_live = false
	_submit(p, {"muted": true})


# ================================================================ 丢货过滤版（碎碎平安 / 呦呦鹿鸣）

func loss_filter_active() -> bool:
	var p: Dictionary = screen.call("_pending_loss_decision")
	return p.has("good_filter")


func loss_legal(good_id: String) -> bool:
	var p: Dictionary = screen.call("_pending_loss_decision")
	return good_id in p.get("legal_give_goods", [])


## 点了压暗的货格：告诉孩子卡上说的是哪几样
func on_illegal_loss_pocket(good_id: String) -> void:
	var p: Dictionary = screen.call("_pending_loss_decision")
	var names: Array[String] = []
	for g in p.get("good_filter", []):
		names.append(_good_name(String(g)))
	_loss_hint = "%s不算：卡上说的是%s\n点亮着的那几件" % [_good_name(good_id), "、".join(names)]
	screen.call("_set_feedback", _loss_hint, COLOR_INFO)
	screen.call("_refresh_round_console")


func loss_prompt(required: int, selected: int) -> String:
	var p: Dictionary = screen.call("_pending_loss_decision")
	if not _loss_hint.is_empty() and selected == 0:
		return _loss_hint
	# 「驼背一颠：玻璃、陶瓷里要碎掉1个，点一个再确认。」→ 两行，第二行带件数
	var fp := String(p.get("filter_prompt", "")).trim_suffix("。")
	var cut := fp.rfind("，")
	if cut > 0:
		fp = fp.substr(0, cut) + "\n" + fp.substr(cut + 1)
	return "%s（%d/%d）" % [fp, selected, required]


func clear_loss_hint() -> void:
	_loss_hint = ""


# ================================================================ 抽牌 / 回合的钩子

## 真人刚抽到（演出开始前）：要揭晓的卡先把 HUD 白银压住
func on_human_event(event: Dictionary) -> void:
	_presenting = true
	_hold_for(event)
	if not pending().is_empty():
		screen.call("_refresh")     # roll_die 的刷新已经把面板打开了：先收起，演出收了再开


## 真人的演出收起了
func on_human_presentation_finished(event: Dictionary) -> void:
	_presenting = false
	release_hold()
	var fx: Dictionary = event.get("fx", {}) if event.get("fx") is Dictionary else {}
	if fx.has("flavor_prompt"):
		_show_campfire(fx["flavor_prompt"], String(event.get("drawn_by", "")))
	call_deferred("maybe_open_quiz")


## 电脑抽到（AITurnController.event_resolved）
func on_ai_event(event: Dictionary) -> void:
	if not event.has("expansion_id"):
		return
	_hold_for(event)
	var fx: Dictionary = event.get("fx", {}) if event.get("fx") is Dictionary else {}
	if fx.has("flavor_prompt"):
		_show_campfire(fx["flavor_prompt"], "*")
	for a in event.get("affected", []):
		var ad := a as Dictionary
		var p := _player(String(ad.get("player_id", "")))
		if p == null or not p.is_local_human():
			continue
		var line := _notice_line(event, p, ad)
		if line.is_empty():
			continue
		var list: Array = _notices.get(p.player_id, [])
		list.append(line)
		while list.size() > MAX_NOTICE_LINES:
			list.pop_front()
		_notices[p.player_id] = list


## 某位真人掷骰了（开始自己的回合）：给他的留言收起
func on_human_rolled(player_id: String) -> void:
	_notices.erase(player_id)
	_move_note = ""


## 某位真人结束回合
func on_turn_ended(player_id: String) -> void:
	_notices.erase(player_id)
	_move_note = ""
	_loss_hint = ""
	if not _campfire_owner.is_empty() and (_campfire_owner == "*" or _campfire_owner == player_id):
		_campfire_owner = ""
		var hud := _hud()
		if hud != null:
			hud.hide_campfire()


func on_stage_revealed(_event: Dictionary) -> void:
	release_hold()


func notices_for(player_id: String) -> Array:
	return _notices.get(player_id, [])


func move_note_for(player: PlayerState) -> String:
	if _move_note.is_empty() or player == null or player.player_id != _move_note_pid or player.move_confirmed:
		return ""
	return _move_note


func _set_move_note(text: String) -> void:
	var cur := GameState.current_player()
	_move_note = text.strip_edges()
	_move_note_pid = cur.player_id if cur != null else ""


func _show_campfire(fp: Dictionary, owner: String) -> void:
	var hud := _hud()
	if hud == null or String(fp.get("text", "")).is_empty():
		return
	_campfire_owner = owner
	hud.show_campfire(String(fp.get("text", "")), fp.get("ai_replies", []))


func campfire_owner() -> String:
	return _campfire_owner


func on_campfire_dismissed() -> void:
	_campfire_owner = ""


# ================================================================ 揭晓前压住 HUD 白银

func _hold_for(event: Dictionary) -> void:
	if not FunStage.holds_silver(event):
		return
	var total := 0
	for a in event.get("affected", []):
		var d := int((a as Dictionary).get("silver_delta", 0))
		if d == 0:
			continue
		var p := _player(String((a as Dictionary).get("player_id", "")))
		if p != null:
			_hold[p.player_id] = p.silver - d
			total += d
	if not _hold.is_empty():
		_hold_supply = GameState.silver_supply + total
		screen.call("_refresh")


func release_hold() -> void:
	if _hold.is_empty() and _hold_supply < 0:
		return
	_hold.clear()
	_hold_supply = -1
	if screen != null and screen.is_inside_tree():
		screen.call("_refresh")


func shown_silver(p: PlayerState) -> int:
	return int(_hold.get(p.player_id, p.silver))


func shown_supply() -> int:
	return _hold_supply if _hold_supply >= 0 else GameState.silver_supply


func holding() -> bool:
	return not _hold.is_empty()


# ================================================================ 电脑抽的卡改了真人的白银 / 货：留言

func _notice_line(event: Dictionary, p: PlayerState, a: Dictionary) -> String:
	var ai := _player(String(event.get("drawn_by", "")))
	var who := ai.display_name if ai != null else "电脑"
	# 第一行谁抽到哪张卡，第二行你怎么了、为什么（提示条一行约 21 个字，分两行不在词中间折断）
	var head := "%s抽到「%s」：\n" % [who, String(event.get("title", ""))]
	var fx: Dictionary = event.get("fx", {}) if event.get("fx") is Dictionary else {}
	var you := "你" if int(screen.call("_lshu_human_count")) <= 1 else p.display_name
	if fx.has("gifts"):
		for g in fx["gifts"]:
			if String((g as Dictionary).get("player_id", "")) == p.player_id:
				# 货仓满 / 缺货改得白银时，message 本身写了原因（「货仓满了，改得1块白银。」）
				if String((g as Dictionary).get("result", "")) == "FALLBACK_SILVER":
					return head + "%s也有 1 份起始物资，%s" % [you, _plain(String((g as Dictionary).get("message", "")))]
				return head + "%s也领了 1 份起始物资，%s" % [you, _plain(String((g as Dictionary).get("message", "")))]
	if fx.has("dice_race"):
		var d: Dictionary = fx["dice_race"]
		for r in d.get("rolls", []):
			if String((r as Dictionary).get("player_id", "")) == p.player_id:
				var face_text := "事件面（算 %d 点）" % int(d.get("event_face_value", 0)) if DiceSystem.is_event_face((r as Dictionary).get("face")) else "%d 点" % int((r as Dictionary).get("value", 0))
				return head + "赛骰%s掷了 %s，点数最大，%s。" % [you, face_text, _delta_text(a)]
	if fx.has("silver_gain") and (fx["silver_gain"] as Array).size() > 1:
		return head + "L叔过生日，每人得 1 块白银，%s也%s。" % [you, _delta_text(a)]
	if fx.has("swap"):
		var sw: Dictionary = fx["swap"]
		if String(sw.get("partner_id", "")) == p.player_id and sw.has("give_good"):
			return head + "包袱拿错啦，%s拿走了%s的%s，给了%s%s。" % [who, you, _good_name(String(sw.get("receive_good", ""))), you, _good_name(String(sw.get("give_good", "")))]
	if fx.has("help"):
		return head + "送去帮忙，%s%s。" % [you, _delta_text(a)]
	if fx.has("nearest"):
		return head + "%s离%s最近，%s。" % [you, GameData.get_city_name(GameState.content, String((fx["nearest"] as Dictionary).get("city_id", ""))), _delta_text(a)]
	return head + "%s%s。" % [you, _delta_text(a)]


func _delta_text(a: Dictionary) -> String:
	var parts: Array[String] = []
	var s := int(a.get("silver_delta", 0))
	if s > 0:
		parts.append("得了 %d 块白银" % s)
	elif s < 0:
		parts.append("少了 %d 块白银" % -s)
	var goods: Dictionary = a.get("goods_delta", {})
	for g in goods:
		var n := int(goods[g])
		parts.append(("得了 %d 个%s" if n > 0 else "少了 %d 个%s") % [absi(n), _good_name(String(g))])
	return "，".join(parts)


func _plain(msg: String) -> String:
	# 「获得 茶叶 ×1。」→「得了 1 个茶叶。」；「货仓满了，改得1块白银。」原样
	var m := msg.strip_edges()
	var rx := RegEx.create_from_string("获得\\s*(\\S+)\\s*×(\\d+)")
	var hit := rx.search(m)
	if hit != null:
		var unit := "块" if hit.get_string(1) == "白银" else "个"
		return "得了 %s %s%s。" % [hit.get_string(2), unit, hit.get_string(1)]
	return m


# ================================================================ 小工具

func look(pid: String) -> Dictionary:
	var p := _player(pid)
	if p == null or screen == null:
		return {}
	return {
		"name": p.display_name,
		"avatar": screen.call("_lshu_avatar", p),
		"color": screen.call("_lshu_seat_color", p),
		"flip": screen.call("_lshu_avatar_flip", p),
		"human": p.is_local_human(),
	}


func _hud() -> Node:
	return screen.get("_lshu") if screen != null else null


func _player(pid: String) -> PlayerState:
	for p in GameState.players:
		if (p as PlayerState).player_id == pid:
			return p
	return null


func _good_name(good_id: String) -> String:
	return GameData.get_good_name(GameState.content, good_id)


func debug_state() -> Dictionary:
	return {
		"active": is_active(),
		"operation": String(pending().get("operation", "")),
		"selected": _sel,
		"quiz_live": _quiz_live,
		"after": not _after.is_empty(),
		"notices": _notices.duplicate(true),
		"move_note": _move_note,
		"campfire_owner": _campfire_owner,
		"holding": holding(),
		"loss_hint": _loss_hint,
	}
