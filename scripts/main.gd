extends Control

## 主场景：StartScreen → 一页式 PlayerSetupScreen → GameScreen。
## “开始新游戏”默认进入正式 16 城；七城 Demo 只保留显式测试入口。

var _transition_overlay: ColorRect
var _transition_tween: Tween

func _ready() -> void:
	PublicRulesUI.attach(self)
	_build_transition_overlay()
	%StartScreen.new_game_requested.connect(_on_new_game_requested)
	%PlayerSetupScreen.transport_confirmed.connect(_on_transport_confirmed)
	%PlayerSetupScreen.back_requested.connect(_on_setup_back)
	%GameScreen.back_to_title_requested.connect(_on_back_to_title)
	%GameScreen.restart_requested.connect(_on_restart_requested)
	_show_only(%StartScreen)


func _on_new_game_requested() -> void:
	if not PublicRules.ready():
		(get_node("PublicRulesSettings") as PublicRulesUI).open()
		return
	var result: Dictionary = %PlayerSetupScreen.begin_setup(-1, "FORMAL")
	if not bool(result.get("success", false)):
		push_error("SetupSystem prepare: %s" % String(result.get("message", "开局准备失败。")))
	await _transition_to(%PlayerSetupScreen)


func _on_setup_back() -> void:
	GameState.reset_session()
	await _transition_to(%StartScreen)


func _on_transport_confirmed(human_transport: int) -> void:
	var result := SetupSystem.finalize_new_game(human_transport)
	if not result["success"]:
		%PlayerSetupScreen.show_start_error(String(result["message"]))
		push_error("SetupSystem finalize: %s" % result["message"])
		return
	var configs: Array = %PlayerSetupScreen.get_last_configs()
	await _transition_to(%GameScreen)
	%GameScreen.on_game_started(configs)


func _on_restart_requested(player_configs: Array) -> void:
	%GameScreen.cancel_ai()
	var restarting_mode := GameState.session_mode
	if restarting_mode != "FORMAL" and restarting_mode != "DEMO_1V1":
		restarting_mode = "FORMAL"
	# 「再来一局」沿用上一局的扩展包（「L叔的趣味事件」开关），和同一桌座位一样
	var expansions := ExpansionLoader.options_of(GameState.content)
	GameState.reset_session()
	var content := GameData.load_ruleset(
		GameData.FORMAL_RULESET_DIR if restarting_mode == "FORMAL" else GameData.DEMO_RULESET_DIR
	)
	var prepared := SetupSystem.prepare_new_game(content, player_configs, -1, restarting_mode, expansions)
	if not prepared["success"]:
		_show_only(%PlayerSetupScreen)
		%PlayerSetupScreen.show_start_error(String(prepared["message"]))
		return
	# FORMAL 忽略传入值并严格按城市卡决定交通；Demo 重开维持骆驼默认。
	var finalized := SetupSystem.finalize_new_game(GameData.Transport.CAMEL)
	if not finalized["success"]:
		_show_only(%PlayerSetupScreen)
		%PlayerSetupScreen.show_start_error(String(finalized["message"]))
		return
	%GameScreen.on_game_started(player_configs)


func _on_back_to_title() -> void:
	%GameScreen.cancel_ai()
	GameState.reset_session()
	await _transition_to(%StartScreen)


func _show_only(screen: Control) -> void:
	%StartScreen.visible = screen == %StartScreen
	%PlayerSetupScreen.visible = screen == %PlayerSetupScreen
	%GameScreen.visible = screen == %GameScreen


func _build_transition_overlay() -> void:
	_transition_overlay = ColorRect.new()
	_transition_overlay.name = "TransitionOverlay"
	_transition_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_transition_overlay.color = Color(0.10, 0.075, 0.045, 0.0)
	_transition_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_transition_overlay.visible = false
	_transition_overlay.z_index = 1000
	add_child(_transition_overlay)


func _transition_to(screen: Control) -> void:
	if _transition_tween != null and _transition_tween.is_valid():
		_transition_tween.kill()
	_transition_overlay.visible = true
	_transition_overlay.color.a = 0.0
	_transition_tween = create_tween()
	_transition_tween.tween_property(_transition_overlay, "color:a", 0.72, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await _transition_tween.finished
	_show_only(screen)
	_transition_tween = create_tween()
	_transition_tween.tween_property(_transition_overlay, "color:a", 0.0, 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await _transition_tween.finished
	_transition_overlay.visible = false
