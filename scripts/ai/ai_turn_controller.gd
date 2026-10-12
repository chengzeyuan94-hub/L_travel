class_name AITurnController
extends Node

## P2 AI 完整合法回合控制器：按阶段调用 AIPolicy 决策，
## 通过既有规则系统命令执行，不直接修改 GameState/PlayerState。
## 使用 Timer 异步推进，避免在 state_changed 回调中递归连发命令；
## 每步检查 session_generation，重开/返回标题后旧流程立即失效。

signal status_changed(text: String)
signal turn_finished
signal blocked(reason: String)
signal event_resolved(event: Dictionary)

const MAX_COMMANDS := 32

var step_delay: float = 0.35
## 可选：由 GameScreen 注入，用于播放 AI visual_move；测试 step_delay=0 时不等待动画。
var board_view: Node = null
## 可选表现层；规则自动化 step_delay=0 时不会播放或等待。
var event_presenter: Node = null

var _running := false
var _generation := -1
var _command_count := 0
var _timer: Timer
var _extra_wait := 0.0


func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timer_timeout)
	add_child(_timer)


func is_running() -> bool:
	return _running


## 取消当前 AI 流程；重开、返回标题或新局必须调用，防止旧计时器残留命令。
func cancel() -> void:
	_running = false
	_extra_wait = 0.0
	if _timer != null:
		_timer.stop()
	if board_view != null and board_view.has_method("cancel_all_animations"):
		board_view.cancel_all_animations()
	if event_presenter != null and event_presenter.has_method("cancel_presentation"):
		event_presenter.cancel_presentation()


## 若当前应由 AI 行动且控制器未在运行，则启动一整个 AI 回合。
func start_if_needed() -> void:
	if _running:
		return
	if GameState.players.is_empty() or GameState.phase == GameState.Phase.GAME_OVER:
		return
	if not QuerySystem.current_is_ai():
		return
	_running = true
	_generation = GameState.session_generation
	_command_count = 0
	status_changed.emit("%s正在行动……" % _who())
	_schedule_step()


## 状态文字用正在行动的那位电脑玩家自己的名字（多位电脑同场时分得清是谁）
func _who() -> String:
	if GameState.players.is_empty():
		return "电脑"
	return GameState.current_player().display_name


func _schedule_step() -> void:
	if not _running:
		return
	var wait := step_delay + _extra_wait
	_extra_wait = 0.0
	if wait <= 0.0:
		call_deferred("_step")
	else:
		_timer.start(wait)


func _on_timer_timeout() -> void:
	_step()


func _step() -> void:
	if not _running:
		return
	if GameState.session_generation != _generation:
		_running = false
		return
	if GameState.players.is_empty() or GameState.phase == GameState.Phase.GAME_OVER:
		_finish()
		return
	if not QuerySystem.current_is_ai():
		_finish()
		return
	_command_count += 1
	if _command_count > MAX_COMMANDS:
		_running = false
		blocked.emit("AI 回合命令数超过上限（%d）。" % MAX_COMMANDS)
		return

	var player: PlayerState = GameState.current_player()
	var result: Dictionary
	match GameState.phase:
		GameState.Phase.ROLL_DIE:
			result = _do_roll(player)
		GameState.Phase.MOVE_OR_EVENT:
			result = _do_move(player)
		GameState.Phase.OPEN_TRADE_ROUTE:
			result = {"success": true}
		GameState.Phase.TRADE:
			result = _do_trade(player)
		GameState.Phase.END_TURN:
			result = _do_end_turn(player)
		_:
			result = {"success": false, "message": "AI 无法在当前阶段行动。"}

	if not bool(result.get("success", false)):
		_running = false
		blocked.emit(String(result.get("message", "AI 命令失败。")))
		return
	if bool(result.get("turn_done", false)):
		_finish()
		return
	_schedule_step()


func _finish() -> void:
	_running = false
	turn_finished.emit()


# ---------- 阶段处理：每步只发一个规则命令 ----------

func _do_roll(_player: PlayerState) -> Dictionary:
	status_changed.emit("%s正在掷骰……" % _who())
	var result := TurnSystem.roll_die()
	if not bool(result.get("success", false)):
		return result
	status_changed.emit("%s：%s" % [_who(), String(result.get("message", "完成掷骰。"))])
	var event: Dictionary = result.get("event", {})
	if bool(event.get("blocked", false)):
		return {"success": false, "message": String(event.get("effect_message", "事件被阻断。"))}
	if bool(event.get("triggered", false)):
		status_changed.emit("%s抽到事件：%s" % [_who(), String(event.get("title", ""))])
		event_resolved.emit(event)
		if step_delay > 0.0 and event_presenter != null and event_presenter.has_method("show_ai_event"):
			_extra_wait += float(event_presenter.show_ai_event(event))
	return {"success": true}


func _do_move(player: PlayerState) -> Dictionary:
	if EventSystem.has_pending_decision():
		status_changed.emit("%s正在处理事件选择……" % _who())
		var pending := EventSystem.get_pending_decision()
		var choice := AIPolicy.choose_event_decision(player, pending)
		return EventSystem.resolve_pending_decision(choice)
	if player.move_confirmed or (
		DiceSystem.is_event_face(player.die_result)
		and not player.pending_event_needs_move
		and player.movement_budget <= 0
	):
		status_changed.emit("%s正在结束移动……" % _who())
		return TurnSystem.proceed()
	var decision := AIPolicy.choose_move(player)
	if bool(decision.get("blocked", false)):
		return {"success": false, "message": String(decision.get("reason", "AI 移动被阻断。"))}
	var chosen: Dictionary = decision.get("chosen", {})
	if chosen.is_empty():
		return {"success": false, "message": "AI 没有可用的移动候选。"}
	if bool(chosen.get("switched", false)) and player.active_transport != int(chosen.get("transport", player.active_transport)):
		status_changed.emit("%s正在换乘……" % _who())
		var old_transport := player.active_transport
		var switch_result := TurnSystem.switch_transport()
		if (
			bool(switch_result.get("success", false))
			and board_view != null
			and board_view.has_method("play_transport_switch_visual")
		):
			board_view.play_transport_switch_visual(
				player.player_id,
				old_transport,
				player.active_transport
			)
			if step_delay > 0.0 and board_view.has_method("estimated_transport_switch_seconds"):
				_extra_wait = float(board_view.estimated_transport_switch_seconds())
		return switch_result
	status_changed.emit("%s正在移动……" % _who())
	var move_result := TurnSystem.confirm_move(chosen.get("path", []))
	if bool(move_result.get("success", false)):
		status_changed.emit("%s：%s" % [_who(), String(move_result.get("message", "完成移动。"))])
		var visual: Dictionary = move_result.get("visual_move", {})
		if board_view != null and board_view.has_method("play_visual_move") and not visual.is_empty():
			board_view.play_visual_move(visual)
			# 仅当 UI 步进延迟 > 0 时等待动画；自动化测试 step_delay=0 不被拖死。
			if step_delay > 0.0 and board_view.has_method("estimated_move_seconds"):
				_extra_wait = float(board_view.estimated_move_seconds(visual))
	return move_result


func _do_trade(player: PlayerState) -> Dictionary:
	if player.trade_action_used:
		return TurnSystem.skip_trade()
	var decision := AIPolicy.choose_trade(player)
	if bool(decision.get("blocked", false)):
		return {"success": false, "message": String(decision.get("reason", "AI 贸易被阻断。"))}
	var chosen: Dictionary = decision.get("chosen", {})
	var kind := String(chosen.get("kind", "skip"))
	match kind:
		"ratio":
			status_changed.emit("%s正在贸易……" % _who())
			var result := TradeSystem.trade_ratio(int(chosen["give_index"]), int(chosen["receive_index"]), int(chosen["times"]))
			if bool(result.get("success", false)):
				status_changed.emit("%s：%s" % [_who(), String(result.get("message", "完成贸易。"))])
			return result
		"direct_sale":
			status_changed.emit("%s正在出售货物……" % _who())
			var result := TradeSystem.trade_direct_sale(chosen.get("selection", {}))
			if bool(result.get("success", false)):
				status_changed.emit("%s：%s" % [_who(), String(result.get("message", "完成出售。"))])
			return result
		_:
			status_changed.emit("%s跳过贸易。" % _who())
			return TurnSystem.skip_trade()


func _do_end_turn(_player: PlayerState) -> Dictionary:
	status_changed.emit("%s正在结束回合……" % _who())
	var result := TurnSystem.end_turn()
	if bool(result.get("success", false)):
		result["turn_done"] = true
		if not bool(result.get("game_over", false)):
			status_changed.emit("轮到%s了。" % GameState.current_player().display_name)
	return result
