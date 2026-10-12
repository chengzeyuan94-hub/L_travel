extends Node
## 对局里的手柄（GameScreen 的子节点；scripts/pad/pad_input.gd 的一个上下文）。
## 全部走对局界面原有的入口（和鼠标点一下、键盘空格是同一条路、同一套防连点），这里不自己改规则状态。
##
## 单选决策里「高亮就是挑选」（和鼠标点一下一样只是选中）；A 只按主按钮，主按钮本来就是「先选、再确认」：
##   选目的地   十字键 / 左摇杆：跳到那个方向最近的可去地点；LB / RB：按一圈的顺序轮换（= 点了那个地点：路线、步数、
##              主按钮变「出发（N 步）」；城市还会亮金光、出市集小卡；在屏幕外就把镜头挪过去）
##              Y =「原地停留」（只是选中，主按钮变「就停在这里」）  B = 取消选中  X = 焦点框跳到「换乘」，再按 A 才换
##   市集清单   上下 = 行（交易行 = 选中；「直接卖」的货行只挪框，X 勾 / 不勾）  左右 = 次数 −1 / +1
##              往下走到底、或按 X（不在货行上时）= 框住「不交易，结束回合」，再按 A 才算  B = 取消选中  Y = 收起 / 展开市集
##   交换       十字键在「交出 / 从谁那换 / 换回」三块格子里走，框到哪个就选哪个；B = 重选
##   趣味事件   十字键挑选项（= 点一下）；B = 取消；A = 主按钮（「就这样」「确认付…」）
##   丢货 / 丢失货物（多选）  十字键在挎包口袋里挪框，X 勾 / 不勾，A = 主按钮「确认丢掉 N 件」；B = 不丢了 / 清空
##   事件卡     十字键 / LB / RB 挑一张（只把它抬起来）；A：没挑时先挑中间那张，挑了再按才翻；翻开后 A =「继续」
##              演出台（拳头 / 明信片）：十字键 = 点一只；A =「打开」，再 A =「继续」
##   换人卡、结算页  A = 按钮（刚出来 0.6 秒内的 A 不算；离上一下 A 不到 0.6 秒的也不算——一直狂按 A 的孩子
##              不会替下一位掷骰、不会结果还没看就「再来一局」；停一下再按才算）。刚从鼠标 / 触屏换回手柄的第一下只亮出框
##   电脑回合   X =「电脑走快点」开 / 关
##   Start      小菜单：丢货、L叔 提示开关、存档、回开场（齿轮要按两次，和鼠标一样）；B / Start 关上
##   镜头       右摇杆平移，LT / RT 缩放，R3 归位，L3 跟到当前玩家
## 孩子规则：进入每个决策时什么都不预选，只按 A 什么也不会发生；B 从不做不可逆的事；
## 一次 A 做成了事以后 0.7 秒内的 A 不算，棋子走路时和落地后 0.8 秒内的 A 也不算（乱按不会一口气走完再买、再结束；
## 手柄模式里主按钮也到那时才亮，亮着的主按钮按 A 一定算）。
## 手柄、鼠标 / 触屏混着用：一碰鼠标 / 触屏（退出手柄模式），框住的次要按钮和 Start 小菜单都放下——之后按 A 按的是
## 主按钮上写的那件事（触屏点了一行再按 A = 确认那一行），不是看不见的旧框；回到手柄时框跟着触屏选中的那一行 / 那一项。

const Pad := preload("res://scripts/pad/pad_input.gd")
const PRIORITY := 20
## 扳机按到底：每秒放大 / 缩小 2 倍
const ZOOM_RATE := 0.7
## 右摇杆推到底：每秒 1.1 个屏高（和方向键一样）
const PAN_SPEED := 1.1
const OVERLAY_GUARD_MS := 600
const A_COOLDOWN_MS := 700
const AFTER_WALK_MS := 800
const STAGE_GUARD_MS := 450
## 换人卡、结算页：离上一下 A 不到这么久的 A 不算（狂按）
const A_CALM_MS := 600
## 这些模式里地图在后面、镜头键照常能用
const CAMERA_MODES := ["move", "trade", "exchange", "decision", "loss", "discard", "dock", "ai", "menu"]

var gs: Control
var mode := ""
var _hl := ""                 # 当前焦点（按模式解释，见各段）
var _armed := ""              # 焦点框停在次要按钮上："switch" / "skip_end"：A 按的是它
var _menu_open := false
var _mode_since := 0
var _a_block_until := 0
var _was_walking := false
var _glow_id := ""            # 手柄选中的城市（金光 + 市集小卡是这里点亮的）
var _last_a_ms := -100000     # 上一下 A（换人卡、结算页的「停一下再按」）
var _a_calm := true           # 这一下 A 离上一下 A 够久


func _init() -> void:
	name = "PadMatch"


func _ready() -> void:
	gs = get_parent() as Control
	var hub := _hub()
	if hub != null:
		hub.register(self, PRIORITY)
		hub.pad_mode_changed.connect(_on_pad_mode_changed)


func _hub() -> Node:
	return get_node_or_null("/root/PadInput")


func _on_pad_mode_changed(on: bool) -> void:
	var board := _board()
	if on:
		# 鼠标停在哪儿都不再算悬停（棋盘的悬停卡、贴边滚动都靠它）；鼠标一动就回来
		if board != null and board.has_method("_on_mouse_exited") and gs.is_visible_in_tree():
			board.call("_on_mouse_exited")
		_follow_touch_pick()
	else:
		_unglow()
		# 改用鼠标 / 触屏了：框住的次要按钮（「不交易，结束回合」「换乘」）和小菜单放下，
		# 不然触屏点了一行、再拿起手柄按 A，按的会是看不见的旧框（复检：结束回合、一件没换）
		_armed = ""
		_menu_open = false
		# 事件卡：手柄抬起的那张放下（之后第一下 A 又是先挑中间那张，不翻看不见的旧框）
		if mode == "event" and _hl.is_valid_int():
			_card_hl(-1)
			_hl = ""
	# 提示换成按键 / 点击的说法（game_screen.gd _pad_says）
	if gs.is_visible_in_tree() and not GameState.players.is_empty():
		gs.call("_refresh_round_console")


## 回到手柄时：框跟着鼠标 / 触屏选中的那一行（市集）/ 那一项（趣味事件），框在哪儿 A 就确认哪一个
func _follow_touch_pick() -> void:
	if gs == null or not pad_active():
		return
	_sync_mode()
	match mode:
		"trade":
			var k := _picked_row_key()
			if k != "":
				_hl = k
			elif _hl.begins_with("row:") and not _is_sale_row(_hl):
				_hl = ""          # 框着的交易行已经被触屏取消了：不再框它
		"decision":
			var fun := _fun()
			if fun != null:
				_hl = String(fun.get("_sel"))


## 市集里眼下选中的那一行（交易行）；没有返回 ""
func _picked_row_key() -> String:
	if not bool(gs.get("_lshu_row_picked")):
		return ""
	var sel: Object = gs.get("_trade_selector")
	if sel == null:
		return ""
	var src: Array = gs.get("_lshu_row_src")
	var tmode := int(gs.get("_trade_panel_mode"))
	for i in src.size():
		var s: Dictionary = src[i]
		if s.is_empty() or s.has("sale_slot") or not bool(s.get("enabled", false)):
			continue
		if (
			int(s.get("mode", -1)) == tmode and int(s.get("give_index", -1)) == int(sel.call("give_index"))
			and int(s.get("receive_index", -1)) == int(sel.call("receive_index"))
		):
			return "row:%d" % i
	return ""


# ------------------------------------------------------------------ 上下文接口
func pad_active() -> bool:
	return gs != null and gs.is_visible_in_tree() and not GameState.players.is_empty()


## 从鼠标 / 触屏换回手柄的第一下（scripts/pad/pad_input.gd _wake）：结算页、换人卡只把框亮出来，不按——
## 以前触屏之后第一下 A 就按了早先框好的「再来一局」，那时框是藏着的（安卓压力测试 MC-2）。
## 这一下也算「上一下 A」：紧跟着的 A 要停一下再按才算。别的模式照常（那一下就是动作，和以前一样）
func pad_wake() -> bool:
	_sync_mode()
	if mode in ["result", "handover"]:
		_last_a_ms = Time.get_ticks_msec()
		return true
	return false


func pad_action(a: String) -> bool:
	if a == "accept":
		var now := Time.get_ticks_msec()
		_a_calm = now - _last_a_ms >= A_CALM_MS
		_last_a_ms = now
	_sync_mode()
	match a:
		"start":
			if mode in ["result", "handover", "event", "lore"]:
				return false
			_menu_open = not _menu_open
			_hl = "save" if _menu_open else ""
			_sync_mode()
			return true
		"l3":
			if mode in CAMERA_MODES and _board() != null and _board().has_method("focus_current_player"):
				_board().call("focus_current_player")
				return true
			return false
		"r3":
			if mode in CAMERA_MODES and _board() != null and _board().has_method("reset_camera_to_fit"):
				_board().call("reset_camera_to_fit")
				return true
			return false
	var used := false
	match mode:
		"result":
			used = _menu_page(a, _result_buttons(), "RestartButton")
		"handover":
			used = _handover(a)
		"event":
			used = _event(a)
		"lore":
			if a == "back":
				var lore := gs.get_node_or_null("%CityLoreCard")
				if lore != null and lore.has_method("close"):
					lore.call("close")
					used = true
		"menu":
			used = _menu(a)
		"ai":
			used = _ai(a)
		"discard", "loss":
			used = _pockets(a)
		"decision":
			used = _decision(a)
		"exchange":
			used = _exchange(a)
		"trade":
			used = _trade(a)
		"move":
			used = _move(a)
		"dock":
			used = _dock(a)
	if not used and a == "back" and _lshu() != null and _lshu().campfire.visible and mode not in ["result", "handover", "event"]:
		Pad.press(_lshu().campfire as BaseButton)       # 篝火泡泡：B 也能收起
		used = true
	return used


func pad_focus() -> Variant:
	_sync_mode()
	match mode:
		"result", "menu":
			return _named_control(_hl)
		"handover":
			return _lshu().handover_button
		"event":
			return _event_focus()
		"move":
			if _armed != "":
				return _secondary(_armed)
			if bool(gs.get("_stay_picked")):
				return _node_rect(GameState.current_player().current_node_id)
			var sel: Array = gs.get("_selected_path")
			return _node_rect(String(sel.back())) if not sel.is_empty() else null
		"trade":
			if _armed != "":
				return _secondary(_armed)
			if _lshu().market_collapsed:
				return null
			return _row_node(_hl)
		"exchange":
			return _exchange_node(_hl)
		"decision":
			return _choice_node(_hl)
		"discard", "loss":
			return _pocket(_hl)
		"dock", "ai":
			return _secondary(_armed) if _armed != "" else null
	return null


func pad_glyphs() -> Array:
	_sync_mode()
	var out: Array = []
	if mode in ["result", "handover", "lore", "menu", ""]:
		return out
	if mode == "event":
		var b := _event_accept_button()
		if b != null:
			out.append([b, "A"])
		return out
	var p := _primary()
	if p != null and p.is_visible_in_tree() and not p.disabled and not bool(p.get_meta("hint_mode", false)):
		out.append([p, "A"])
	for pair: Array in [["stay", "Y"], ["switch", "X"], ["skip_end", "X"], ["ai_fast", "X"], ["discard_cancel", "B"], ["reselect_exchange", "B"]]:
		var s := _secondary(String(pair[0]))
		if s != null:
			out.append([s, String(pair[1])])
	if mode in ["trade", "exchange", "decision"] and _lshu() != null:
		out.append([_lshu().market_tab, "Y"])
	if mode in ["discard", "loss"] and _pocket(_hl) != null:
		out.append([_pocket(_hl), "X"])
	if mode == "trade" and _is_sale_row(_hl) and _row_node(_hl) != null:
		out.append([_row_node(_hl), "X"])
	return out


func pad_axes(pan: Vector2, zoom: float, dt: float) -> void:
	_sync_mode()
	var b := _board()
	if mode not in CAMERA_MODES or b == null or not b.has_method("_pan_by"):
		return
	if pan != Vector2.ZERO:
		b.set("_fling", Vector2.ZERO)
		b.call("_pan_by", -pan * float(b.size.y) * PAN_SPEED * dt)
	if absf(zoom) > 0.0 and b.has_method("_zoom_at"):
		var c: Vector2 = (b.call("_safe_rect") as Rect2).get_center() if b.has_method("_safe_rect") else b.size * 0.5
		b.call("_zoom_at", c, float(b.get("_zoom")) * exp(zoom * ZOOM_RATE * dt), false)


# ------------------------------------------------------------------ 每帧
func _process(_dt: float) -> void:
	if gs == null or not gs.is_visible_in_tree():
		return
	var walking := bool(gs.get("_move_animating"))
	if _was_walking and not walking:
		_a_block_until = maxi(_a_block_until, Time.get_ticks_msec() + AFTER_WALK_MS)
		_hold_primary_for_pad()
	_was_walking = walking
	var hub := _hub()
	if _glow_id == "" and (hub == null or not bool(hub.get("pad_mode"))):
		return          # 没用手柄：什么都不做（鼠标 / 触屏 / 键盘的对局和以前一样）
	_sync_mode()
	if _glow_id != "":
		var sel: Array = gs.get("_selected_path")
		if mode != "move" or sel.is_empty() or String(sel.back()) != _glow_id:
			_unglow()
		elif _board() != null and _board().has_method("refresh_visible_trade_card"):
			_board().call("refresh_visible_trade_card")     # 镜头滑动时小卡跟着城走


var _mode_key := ""


## 手柄模式里「主按钮亮着 = 按 A 就算」：落地后 A 要等 AFTER_WALK_MS，主按钮也挡到那时再亮
## （以前 0.52 秒就亮了，0.52–0.8 秒之间按 A 不声不响地没用，安卓压力测试 PAD-MAR-5）。只在手柄模式、真人回合；
## 鼠标 / 触屏的对局不经过这里，和以前一样
func _hold_primary_for_pad() -> void:
	var hub := _hub()
	if hub == null or not bool(hub.get("pad_mode")) or GameState.players.is_empty() or GameState.current_player().is_ai():
		return
	if int(gs.get("_dock_block_until_ms")) < _a_block_until:
		gs.set("_dock_block_until_ms", _a_block_until)
	gs.call("_arm_primary_action_guard")


## 模式变了、或换了回合 / 阶段（同一种模式的下一个决定）：焦点、框住的次要按钮都清掉，不带到下一个决定里
func _sync_mode() -> void:
	var m := _mode()
	var key := "%s|%d|%d|%d" % [m, GameState.round_index, GameState.current_player_index, GameState.phase] if not GameState.players.is_empty() else m
	if m == mode and key == _mode_key:
		return
	var same_mode := m == mode
	_mode_key = key
	if same_mode and m == "menu":
		return
	mode = m
	_hl = "save" if m == "menu" else ("RestartButton" if m == "result" else "")
	_armed = ""
	_mode_since = Time.get_ticks_msec()
	if m != "menu":
		_menu_open = false
	if m != "move":
		_unglow()


func _mode() -> String:
	if not pad_active():
		return ""
	var lshu := _lshu()
	if (lshu != null and lshu.result.visible) or (lshu == null and (gs.get_node("%ResultOverlay") as Control).visible):
		return "result"
	if lshu != null and lshu.handover.visible:
		return "handover"
	var ov := gs.get_node_or_null("%EventDrawOverlay") as EventDrawOverlay
	if ov != null and ov.visible and ov.state != EventDrawOverlay.PresentationState.HIDDEN:
		return "event"
	var lore := gs.get_node_or_null("%CityLoreCard")
	if lore != null and lore.has_method("is_open") and bool(lore.call("is_open")):
		return "lore"
	if _menu_open and lshu != null:
		return "menu"
	if GameState.current_player().is_ai():
		return "ai"
	if bool(gs.get("_lshu_discard_mode")):
		return "discard"
	if bool(gs.call("_is_pending_loss_decision")):
		return "loss"
	if lshu != null:
		match String(lshu.market_mode):
			"decision":
				return "decision"
			"exchange":
				return "exchange"
			"trade":
				return "trade"
	if bool(gs.call("_move_pick_open")) and bool(gs.get("_board_selecting")):
		return "move"
	return "dock"


# ------------------------------------------------------------------ 公共
func _lshu() -> Node:
	return gs.get("_lshu") as Node


func _board() -> Control:
	return gs.get_node_or_null("%BoardView") as Control


func _primary() -> Button:
	return gs.get("_primary_action") as Button


## 看得见的、动作是 action 的那枚次要按钮
func _secondary(action: String) -> Button:
	for key in ["_secondary_action", "_secondary_alt_action"]:
		var b := gs.get(key) as Button
		if b != null and b.is_visible_in_tree() and String(b.get_meta("action", "")) == action:
			return b
	return null


func _a_ready() -> bool:
	return Time.get_ticks_msec() >= _a_block_until


## A：焦点框停在次要按钮上就按它，否则按主按钮（和键盘空格同一套条件）
func _accept() -> bool:
	if not _a_ready():
		return true
	if _armed != "":
		var s := _secondary(_armed)
		_armed = ""
		if s != null and not s.disabled:
			gs.call("_run_secondary_action", s)
			_a_block_until = Time.get_ticks_msec() + A_COOLDOWN_MS
			return true
		return true
	return _press_primary()


func _press_primary() -> bool:
	var p := _primary()
	if p == null or not p.is_visible_in_tree() or p.disabled or bool(p.get_meta("hint_mode", false)):
		return false
	if Time.get_ticks_msec() < int(gs.get("_dock_block_until_ms")):
		return true
	gs.call("_on_primary_action_pressed")
	_a_block_until = Time.get_ticks_msec() + A_COOLDOWN_MS
	return true


func _step(a: String) -> int:
	return -1 if a in ["up", "left", "lb"] else (1 if a in ["down", "right", "rb"] else 0)


static func _dir(a: String) -> Vector2:
	match a:
		"up":
			return Vector2.UP
		"down":
			return Vector2.DOWN
		"left":
			return Vector2.LEFT
		"right":
			return Vector2.RIGHT
	return Vector2.ZERO


## 按键名找控件（结算页、小菜单用）
func _named_control(key: String) -> Control:
	if key == "":
		return null
	if mode == "result":
		for b: Control in _result_buttons():
			if String(b.name) == key:
				return b
		return null
	for pair: Array in _menu_items():
		if String(pair[0]) == key:
			return pair[1] as Control
	return null


## 一页按钮：十字键 / LB / RB 挪框，A 按（刚出来的 0.6 秒内不算）
func _menu_page(a: String, buttons: Array, first: String) -> bool:
	if buttons.is_empty():
		return false
	var names: Array = buttons.map(func(b: Control) -> String: return String(b.name))
	var cur := names.find(_hl)
	if a == "accept":
		if Time.get_ticks_msec() - _mode_since < OVERLAY_GUARD_MS or not _a_calm:
			return true
		if cur < 0:
			_hl = first if names.has(first) else String(names[0])
			return true
		return Pad.press(buttons[cur] as BaseButton)
	if a in ["lb", "rb"]:
		var n := names.size()
		_hl = String(names[0 if cur < 0 else (cur + (1 if a == "rb" else -1) + n) % n])
		return true
	var d := _dir(a)
	if d == Vector2.ZERO:
		return false
	var i := Pad.nav_controls(buttons, cur, d, maxi(0, names.find(first)))
	if i >= 0:
		_hl = String(names[i])
	return true


func _result_buttons() -> Array:
	var out: Array = []
	for n in ["%RestartButton", "%BackTitleButton"]:
		var b := gs.get_node_or_null(n) as Button
		if b != null and b.is_visible_in_tree() and not b.disabled:
			out.append(b)
	return out


# ------------------------------------------------------------------ 换人卡
func _handover(a: String) -> bool:
	if a != "accept":
		return false
	if Time.get_ticks_msec() - _mode_since < OVERLAY_GUARD_MS or not _a_calm:
		return true
	return Pad.press(_lshu().handover_button as BaseButton)


# ------------------------------------------------------------------ 小菜单（Start）
func _menu_items() -> Array:
	var lshu := _lshu()
	if lshu == null:
		return []
	var out: Array = []
	for pair: Array in [
		["discard", lshu.discard_button], ["guide", lshu.group_br.get_node_or_null("GuideToggle")],
		["save", lshu.save_button], ["gear", lshu.group_tr.get_node_or_null("MenuButton")],
	]:
		var b := pair[1] as BaseButton
		if b != null and b.is_visible_in_tree() and not b.disabled:
			out.append(pair)
	return out


func _menu(a: String) -> bool:
	var items := _menu_items()
	if a == "back":
		_menu_open = false
		_sync_mode()
		return true
	if items.is_empty():
		return false
	var keys: Array = items.map(func(p: Array) -> String: return String(p[0]))
	var ctrls: Array = items.map(func(p: Array) -> Control: return p[1] as Control)
	var cur := keys.find(_hl)
	if a == "accept":
		if cur < 0:
			_hl = String(keys[0])
			return true
		var key := String(keys[cur])
		Pad.press(ctrls[cur] as BaseButton)
		if key == "discard":
			_menu_open = false          # 进了挑货：框交给挎包口袋
			_sync_mode()
		return true
	if a in ["lb", "rb"]:
		var n := keys.size()
		_hl = String(keys[0 if cur < 0 else (cur + (1 if a == "rb" else -1) + n) % n])
		return true
	var d := _dir(a)
	if d == Vector2.ZERO:
		return false
	var i := Pad.nav_controls(ctrls, cur, d, 0)
	if i >= 0:
		_hl = String(keys[i])
	return true


# ------------------------------------------------------------------ 电脑回合 / 其余
func _ai(a: String) -> bool:
	if a == "x":
		var s := _secondary("ai_fast")
		if s != null and not s.disabled:
			gs.call("_run_secondary_action", s)
			return true
	return false


func _dock(a: String) -> bool:
	match a:
		"accept":
			return _accept()
		"x":
			if _secondary("switch") != null:
				_armed = "" if _armed == "switch" else "switch"
				return true
		"back":
			if _armed != "":
				_armed = ""
				return true
	return false


# ------------------------------------------------------------------ 选目的地
func _move_targets() -> Array:
	var b := _board()
	if b == null:
		return []
	var here := GameState.current_player().current_node_id
	var out: Array = []
	for id in (b.get("legal_nodes") as Dictionary).keys():
		if String(id) != here:
			out.append(String(id))
	out.sort()
	return out


## 地点在画布上的位置（棋盘自己的投影）；拿不到时 INF
func _node_point(id: String) -> Vector2:
	var b := _board()
	if b == null or not b.has_method("_to_view") or not b.has_method("_node_anchor"):
		return Vector2.INF
	var local: Vector2 = b.call("_to_view", b.call("_node_anchor", id))
	return b.get_global_transform_with_canvas() * local


## 焦点框：可去地点的步数牌；没有牌（原地）时是地点周围一块
func _node_rect(id: String) -> Variant:
	var b := _board()
	if b == null:
		return null
	var markers: Dictionary = b.get("_markers") if b.get("_markers") is Dictionary else {}
	if markers.has(id):
		var disc := (markers[id] as Dictionary).get("disc") as Control
		if disc != null and disc.is_visible_in_tree():
			return disc
	var p := _node_point(id)
	if p == Vector2.INF:
		return null
	var k := b.get_global_transform_with_canvas().get_scale().x
	return Rect2(p - Vector2(36, 36) * k, Vector2(72, 72) * k)


func _move(a: String) -> bool:
	match a:
		"accept":
			return _accept()
		"y":
			_armed = ""
			gs.call("_on_stay_picked")
			if bool(gs.get("_stay_picked")):
				_hl = ""
				_unglow()
				_reveal(GameState.current_player().current_node_id)     # 自己脚下在屏幕外：镜头挪回来（PAD-MAR-7）
			return true
		"x":
			if _secondary("switch") != null:
				_armed = "" if _armed == "switch" else "switch"
				return true
			return false
		"back":
			if _armed != "":
				_armed = ""
				return true
			if bool(gs.call("_move_pick_made")):
				gs.call("_clear_move_pick")
				gs.call("_show_move_pick")
				gs.call("_refresh_action_buttons")
				_unglow()
				return true
			return false
		"lb", "rb":
			var ids := _move_targets()
			if ids.is_empty():
				return true
			var here := _node_point(GameState.current_player().current_node_id)
			# 绕着自己转一圈的顺序（从正上方顺时针）
			ids.sort_custom(func(p: String, q: String) -> bool:
				return _angle(here, _node_point(p)) < _angle(here, _node_point(q)))
			var cur := ids.find(_current_dest())
			var n := ids.size()
			var i: int = (0 if a == "rb" else n - 1) if cur < 0 else (cur + (1 if a == "rb" else -1) + n) % n
			_pick_dest(String(ids[i]))
			return true
		"up", "down", "left", "right":
			var ids := _move_targets()
			if ids.is_empty():
				return true
			var origin := _current_dest()
			var from_p := _node_point(origin if origin != "" else GameState.current_player().current_node_id)
			if from_p == Vector2.INF:
				_pick_dest(String(ids[0]))
				return true
			var rects: Array = []
			for id: String in ids:
				var p := _node_point(id)
				rects.append(Rect2(p, Vector2.ZERO) if p != Vector2.INF else Rect2(Vector2(1e9, 1e9), Vector2.ZERO))
			var i := Pad.pick_dir(Rect2(from_p, Vector2.ZERO), rects, _dir(a))
			if i < 0 and origin == "":
				# 第一下：那个方向没有就挑离自己最近的（总得选中一个）
				var best := INF
				for j in rects.size():
					var dd := (rects[j] as Rect2).position.distance_to(from_p)
					if dd < best:
						best = dd
						i = j
			if i >= 0:
				_pick_dest(String(ids[i]))
			return true
	return false


static func _angle(c: Vector2, p: Vector2) -> float:
	if c == Vector2.INF or p == Vector2.INF:
		return 0.0
	return fposmod(atan2(p.x - c.x, -(p.y - c.y)), TAU)


func _current_dest() -> String:
	var sel: Array = gs.get("_selected_path")
	return String(sel.back()) if not sel.is_empty() else ""


## 选中一个目的地（= 点了它）；城市亮金光、出市集小卡；在「没被界面挡住的那一块」外面就把镜头挪过去（只平移）
func _pick_dest(id: String) -> void:
	_armed = ""
	gs.call("_on_board_node_clicked", id)
	if _current_dest() != id:
		return
	_hl = id
	var b := _board()
	if b == null:
		return
	if b.has_method("_set_city_glow") and b.get("paths") != null:
		var is_city := bool(b.get("paths").call("is_city", id))
		_glow_id = id if is_city else ""
		b.call("_set_city_glow", _glow_id)
		if is_city and b.has_method("_show_city_trade_card"):
			b.call("_show_city_trade_card", id)
		elif b.has_method("_hide_city_trade_card"):
			b.call("_hide_city_trade_card")
	_reveal(id)


## 地点在「没被界面挡住的那一块」外面：把镜头挪过去（只平移）
func _reveal(id: String) -> void:
	var b := _board()
	if b == null:
		return
	if b.has_method("_safe_rect") and b.has_method("_focus_point") and b.get("world") != null:
		var local: Vector2 = b.call("_to_view", b.call("_node_anchor", id))
		var safe: Rect2 = (b.call("_safe_rect") as Rect2).grow(-60.0)
		if not safe.has_point(local):
			var cam: Camera3D = b.get("world").get("camera")
			b.set("_follow", "")
			b.set("_fling", Vector2.ZERO)
			b.set("_goal", b.call("_clamp_target", b.call("_focus_point", b.call("_node_anchor", id)), cam.size))


func _unglow() -> void:
	if _glow_id == "":
		return
	_glow_id = ""
	var b := _board()
	if b != null and b.has_method("_set_city_glow"):
		b.call("_set_city_glow", "")
		b.call("_hide_city_trade_card")


# ------------------------------------------------------------------ 市集清单
## 可以停的行：交易行（能做的）、货行（直接卖）；最后是「不交易，结束回合」
func _trade_items() -> Array:
	var out: Array = []
	var lshu := _lshu()
	var nodes: Array = lshu.get("_market_row_nodes")
	var src: Array = gs.get("_lshu_row_src")
	for i in nodes.size():
		var b := nodes[i] as Button
		if b == null or not is_instance_valid(b) or not b.is_visible_in_tree():
			continue
		var s: Dictionary = src[i] if i < src.size() else {}
		if s.is_empty():
			continue
		if not s.has("sale_slot") and not bool(s.get("enabled", false)):
			continue
		out.append("row:%d" % i)
	if _secondary("skip_end") != null:
		out.append("dock:skip_end")
	return out


func _row_index(key: String) -> int:
	return int(key.trim_prefix("row:")) if key.begins_with("row:") else -1


func _row_node(key: String) -> Control:
	var i := _row_index(key)
	if i < 0:
		return null
	var nodes: Array = _lshu().get("_market_row_nodes")
	return nodes[i] as Control if i < nodes.size() and is_instance_valid(nodes[i]) else null


func _is_sale_row(key: String) -> bool:
	var i := _row_index(key)
	var src: Array = gs.get("_lshu_row_src")
	return i >= 0 and i < src.size() and (src[i] as Dictionary).has("sale_slot")


func _trade(a: String) -> bool:
	var lshu := _lshu()
	match a:
		"accept":
			return _accept()
		"y":
			lshu.call("set_market_collapsed", not bool(lshu.market_collapsed))
			return true
		"back":
			if _armed != "":
				_armed = ""
				_hl = ""
				return true
			if bool(gs.get("_lshu_row_picked")) or not (gs.get("_sale_selected_slots") as Dictionary).is_empty() or bool(gs.call("_skip_end_pick_active")):
				_clear_trade_pick()
				_hl = ""
				return true
			return false
		"x":
			if _is_sale_row(_hl):
				gs.call("_pad_toggle_sale_row", _row_index(_hl))     # 落地后那 0.5 秒也勾得上（PAD-MAR-6）
				_scroll_to_row.call_deferred(_hl)
				return true
			if _secondary("skip_end") != null:
				_trade_focus("dock:skip_end")
				return true
			return false
		"left", "right":
			if lshu.market_collapsed:
				lshu.call("set_market_collapsed", false)
				return true
			var i := _row_index(_hl)
			if i >= 0 and bool(gs.get("_lshu_row_picked")) and not _is_sale_row(_hl):
				gs.call("_on_lshu_times_pressed", _step(a))
			return true
		"up", "down", "lb", "rb":
			if lshu.market_collapsed:
				lshu.call("set_market_collapsed", false)
				return true
			var items := _trade_items()
			if items.is_empty():
				return true
			var cur := items.find(_hl)
			var nxt := 0 if cur < 0 else clampi(cur + _step(a), 0, items.size() - 1)
			_trade_focus(String(items[nxt]))
			return true
	return false


func _trade_focus(key: String) -> void:
	_hl = key
	if key == "dock:skip_end":
		if bool(gs.get("_lshu_row_picked")):
			_clear_trade_pick()
		_hl = key
		_armed = "skip_end"
		return
	_armed = ""
	var i := _row_index(key)
	if _is_sale_row(key):
		# 货行：框过去不勾（多选，X 勾）；框从交易行挪下来时，那一行的选中取消，A 不会成交框外的那一行
		if bool(gs.get("_lshu_row_picked")):
			gs.set("_lshu_row_picked", false)
			gs.call("_update_trade_preview_and_buttons")
			gs.call("_refresh_action_buttons")
	else:
		gs.call("_lshu_select_row", i)
		gs.set("_lshu_row_pick_ms", Time.get_ticks_msec())
	_scroll_to_row.call_deferred(key)


func _scroll_to_row(key: String) -> void:
	var n := _row_node(key)
	var lshu := _lshu()
	if n != null and lshu != null and lshu.market_rows_scroll != null:
		(lshu.market_rows_scroll as ScrollContainer).ensure_control_visible(n)


func _clear_trade_pick() -> void:
	gs.set("_lshu_row_picked", false)
	gs.set("_skip_end_picked_ctx", "")          # 触屏先选了「不交易，结束回合」（安卓）：B 同样放下
	(gs.get("_sale_selected_slots") as Dictionary).clear()
	(gs.get("_sale_selection") as Dictionary).clear()
	gs.call("_update_trade_preview_and_buttons")
	gs.call("_refresh_cargo_slot_visuals")
	gs.call("_refresh_action_buttons")


# ------------------------------------------------------------------ 交换
func _exchange_keys() -> Array:
	var out: Array = []
	var nodes: Dictionary = _lshu().get("_exchange_nodes")
	for k: String in nodes:
		var b := nodes[k] as Button
		if b != null and is_instance_valid(b) and b.is_visible_in_tree() and not b.disabled:
			out.append(k)
	return out


func _exchange_node(key: String) -> Control:
	if key == "":
		return null
	var b: Variant = (_lshu().get("_exchange_nodes") as Dictionary).get(key)
	return b as Control if b != null and is_instance_valid(b) else null


func _exchange(a: String) -> bool:
	match a:
		"accept":
			return _accept()
		"y":
			_lshu().call("set_market_collapsed", not bool(_lshu().market_collapsed))
			return true
		"back":
			var s := _secondary("reselect_exchange")
			if s != null and (String(gs.get("_event_exchange_give_good")) != "" or String(gs.get("_event_exchange_receive_good")) != ""):
				gs.call("_run_secondary_action", s)
				_hl = ""
				return true
			return false
		"up", "down", "left", "right", "lb", "rb":
			if _lshu().market_collapsed:
				_lshu().call("set_market_collapsed", false)
				return true
			var keys := _exchange_keys()
			# 从上到下、从左到右排好（「交出」一排在最上面）
			keys.sort_custom(func(p: String, q: String) -> bool:
				var rp := Pad.rect_of(_exchange_node(p))
				var rq := Pad.rect_of(_exchange_node(q))
				return rp.position.y < rq.position.y - 8.0 or (absf(rp.position.y - rq.position.y) <= 8.0 and rp.position.x < rq.position.x))
			if keys.is_empty():
				return true
			var cur := keys.find(_hl)
			var i := 0
			if cur >= 0:
				if a in ["lb", "rb"]:
					i = clampi(cur + _step(a), 0, keys.size() - 1)
				else:
					var ctrls: Array = keys.map(func(k: String) -> Control: return _exchange_node(k))
					i = Pad.nav_controls(ctrls, cur, _dir(a), 0)
			_exchange_pick(String(keys[i]))
			return true
	return false


func _exchange_pick(key: String) -> void:
	_hl = key
	var id := key.get_slice(":", 1)
	if key.begins_with("give:"):
		if String(gs.get("_event_exchange_give_good")) != id:
			gs.call("_on_event_exchange_give_selected", id)
	elif key.begins_with("target:"):
		gs.call("_on_lshu_exchange_target", id)
	elif key.begins_with("recv:"):
		if String(gs.get("_event_exchange_receive_good")) != id:
			gs.call("_on_event_exchange_receive_selected", id)


# ------------------------------------------------------------------ 趣味事件的选择
func _fun() -> Node:
	return gs.get("_fun") as Node


func _choice_ids() -> Array:
	var view: Node = _lshu().market_choice
	var nodes: Dictionary = view.get("_nodes") if view != null else {}
	var out: Array = []
	for id: String in nodes:
		var b := nodes[id] as Button
		if b != null and is_instance_valid(b) and b.is_visible_in_tree() and not b.disabled:
			out.append(id)
	return out


func _choice_node(id: String) -> Control:
	if id == "":
		return null
	var view: Node = _lshu().market_choice
	var b: Variant = (view.get("_nodes") as Dictionary).get(id) if view != null else null
	return b as Control if b != null and is_instance_valid(b) else null


func _decision(a: String) -> bool:
	var fun := _fun()
	match a:
		"accept":
			return _accept()
		"y":
			_lshu().call("set_market_collapsed", not bool(_lshu().market_collapsed))
			return true
		"back":
			var sel := String(fun.get("_sel"))
			if sel != "":
				fun.call("on_pick", sel)          # 再点一下已选的 = 取消
				_hl = ""
				return true
			return false
		"up", "down", "left", "right", "lb", "rb":
			if _lshu().market_collapsed:
				_lshu().call("set_market_collapsed", false)
				return true
			var ids := _choice_ids()
			if ids.is_empty():
				return true
			var ctrls: Array = ids.map(func(id: String) -> Control: return _choice_node(id))
			var cur := ids.find(_hl if _hl != "" else String(fun.get("_sel")))
			var i := 0
			if cur >= 0:
				if a in ["lb", "rb"]:
					i = clampi(cur + _step(a), 0, ids.size() - 1)
				else:
					i = Pad.nav_controls(ctrls, cur, _dir(a), 0)
			var id := String(ids[i])
			_hl = id
			if String(fun.get("_sel")) != id:
				fun.call("on_pick", id)
			return true
	return false


# ------------------------------------------------------------------ 挎包口袋（丢货 / 丢失货物：多选）
func _pocket_buttons() -> Array:
	var grid := gs.get("_cargo_grid") as Control
	var out: Array = []
	if grid == null:
		return out
	for c in grid.get_children():
		var b := c as Button
		if b != null and b.is_visible_in_tree() and not b.disabled:
			out.append(b)
	return out


func _pocket(key: String) -> Control:
	if not key.begins_with("slot:"):
		return null
	var grid := gs.get("_cargo_grid") as Control
	var i := int(key.trim_prefix("slot:"))
	return grid.get_child(i) as Control if grid != null and i >= 0 and i < grid.get_child_count() else null


func _pockets(a: String) -> bool:
	match a:
		"accept":
			return _accept()
		"x":
			var p := _pocket(_hl) as Button
			if p != null and not p.disabled:
				p.pressed.emit()        # 口袋自己的「点一下」：勾 / 不勾（_toggle_cargo_slot）
				return true
			return false
		"back":
			if mode == "discard":
				var s := _secondary("discard_cancel")
				if s != null:
					gs.call("_run_secondary_action", s)
					return true
				return false
			var sel := gs.get("_event_loss_selected_slots") as Dictionary
			if not sel.is_empty():
				sel.clear()
				gs.call("_refresh_cargo_slot_visuals")
				gs.call("_refresh_action_buttons")
				return true
			return false
		"up", "down", "left", "right", "lb", "rb":
			var btns := _pocket_buttons()
			if btns.is_empty():
				return true
			var cur := btns.find(_pocket(_hl))
			var i := 0
			if cur >= 0:
				i = clampi(cur + _step(a), 0, btns.size() - 1) if a in ["lb", "rb"] else Pad.nav_controls(btns, cur, _dir(a), 0)
			_hl = "slot:%d" % (btns[i] as Node).get_index()
			return true
	return false


# ------------------------------------------------------------------ 事件卡
func _overlay() -> EventDrawOverlay:
	return gs.get_node_or_null("%EventDrawOverlay") as EventDrawOverlay


func _event_cards() -> Array:
	var ov := _overlay()
	return ov.get("_cards") if ov != null else []


func _event(a: String) -> bool:
	var ov := _overlay()
	if ov == null or bool(ov.get("_is_ai")):
		return false
	var now := Time.get_ticks_msec()
	match ov.state:
		EventDrawOverlay.PresentationState.WAITING_SELECTION:
			var cards := _event_cards()
			if cards.is_empty():
				return false
			var cur := int(_hl) if _hl.is_valid_int() else -1
			if a == "accept":
				if cur < 0:
					_card_hl(1 if cards.size() > 1 else 0)    # 没挑时先挑中间那张，不翻
					return true
				if now < _a_block_until:
					return true
				_a_block_until = now + STAGE_GUARD_MS
				ov.call("_on_card_clicked", cards[cur])
				return true
			var s := _step(a)
			if s == 0:
				return false
			_card_hl(1 if cur < 0 else clampi(cur + s, 0, cards.size() - 1))
			return true
		EventDrawOverlay.PresentationState.REVEALED:
			var st := ov.stage()
			if st != null and not bool(st.get("done")):
				var picks := _stage_picks(st)
				if a == "accept":
					if now < _a_block_until:
						return true
					var act := st.call("action_button") as Button
					var cont := st.call("continue_button") as Button
					if act != null and act.is_visible_in_tree() and not act.disabled:
						_a_block_until = now + STAGE_GUARD_MS
						st.call("act")
						return true
					if cont != null and cont.is_visible_in_tree() and not cont.disabled:
						_a_block_until = now + STAGE_GUARD_MS
						st.call("finish")
						return true
					return true
				var s2 := _step(a)
				if s2 == 0 or picks.is_empty() or bool(st.get("is_revealed")):
					return false
				var cur2 := int(st.get("picked"))
				var nxt := 0 if cur2 < 0 else clampi(cur2 + s2, 0, picks.size() - 1)
				st.call("pick", nxt)
				return true
			if a == "accept":
				if now < _a_block_until:
					return true
				var cb := ov.get_node_or_null("ContinueButton") as Button
				if cb != null and cb.is_visible_in_tree() and not cb.disabled:
					_a_block_until = now + STAGE_GUARD_MS
					ov.call("_on_continue_pressed")
				return true
	return false


func _card_hl(i: int) -> void:
	var ov := _overlay()
	var cards := _event_cards()
	var old := int(_hl) if _hl.is_valid_int() else -1
	if old == i:
		return
	if old >= 0 and old < cards.size():
		ov.call("_on_card_hover", cards[old], false)
	_hl = str(i)
	if i >= 0 and i < cards.size():
		ov.call("_on_card_hover", cards[i], true)


func _stage_picks(st: Node) -> Array:
	var out: Array = []
	var i := 0
	while true:
		var b := st.call("pick_button", i) as Button if st.has_method("pick_button") else null
		if b == null:
			break
		out.append(b)
		i += 1
	return out


func _event_focus() -> Variant:
	var ov := _overlay()
	if ov == null or bool(ov.get("_is_ai")):
		return null
	if ov.state == EventDrawOverlay.PresentationState.WAITING_SELECTION:
		var cards := _event_cards()
		var i := int(_hl) if _hl.is_valid_int() else -1
		return cards[i] if i >= 0 and i < cards.size() else null
	if ov.state == EventDrawOverlay.PresentationState.REVEALED:
		var st := ov.stage()
		if st != null and not bool(st.get("done")):
			var picked := int(st.get("picked"))
			if picked >= 0 and not bool(st.get("is_revealed")):
				return st.call("pick_button", picked)
		return _event_accept_button()
	return null


## 事件卡上 A 按的那个按钮（演出台的「开赛 / 打开」「继续」，或说明牌里的「继续」）
func _event_accept_button() -> Button:
	var ov := _overlay()
	if ov == null or bool(ov.get("_is_ai")) or ov.state != EventDrawOverlay.PresentationState.REVEALED:
		return null
	var st := ov.stage()
	if st != null and not bool(st.get("done")):
		for m in ["action_button", "continue_button"]:
			var b := st.call(m) as Button
			if b != null and b.is_visible_in_tree() and not b.disabled:
				return b
		return null
	var cb := ov.get_node_or_null("ContinueButton") as Button
	return cb if cb != null and cb.is_visible_in_tree() and not cb.disabled else null
