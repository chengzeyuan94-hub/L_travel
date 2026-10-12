extends Control

## 游戏主界面：只显示 GameState 并发送命令，不保存对局数据。
## 轻量 1v1：AI 回合由 AITurnController 驱动，真人输入在 AI 期间锁定。

signal back_to_title_requested
signal restart_requested(player_configs: Array)

## 三个主模式都来自城市贸易卡；DIRECT_SALE 是原版“任意货物每件 1 银”的次要兜底。
## 保留 DIRECT_SALE=2，避免破坏既有测试注入；CARD_SELL 追加为 3。
enum TradePanelMode { BUY, EXCHANGE, DIRECT_SALE, CARD_SELL }

const COLOR_SUCCESS := Color("3F7D63")
const COLOR_FAILURE := Color("A54A3F")
const COLOR_INFO := Color("7D5A3A")
## 手柄 / 触屏防误触层（autoload PadInput 的脚本；静态工具 guards_on / canceled_press）
const PadInputLayer := preload("res://scripts/pad/pad_input.gd")
## 安卓触屏选中「不交易，结束回合」后主按钮上的字 / 提示行。主按钮不能和选中的那枚次要按钮同字，孩子分不清哪个是确认；
## 用「原地停留 → 就停在这里」同一个说法（Carlos 2026-09-30 选「就不交易了」）
const SKIP_END_CONFIRM_TEXT := "就不交易了"
const SKIP_END_PROMPT_PICKED := "再按「就不交易了」确认；想交易就点一行"

var _board_selecting := false
var _selected_path: Array = []
## 先选再确认（Carlos 2026-09-27「先选再确认」，推翻 09-26 的点一下就出发；夜测 NOV-5：孩子误点城市就走了 3 步）：
## 地图上点目的地 / 点「原地停留」都只是选中，只有主按钮（「出发（N 步）」/「就停在这里」）才真的走。
## _selected_path 是选中的路线；_stay_picked 是选了「原地停留」。两者最多一个有效。
var _stay_picked := false
## 安卓触屏：「不交易，结束回合」选中了（值 = 选中时的 _skip_end_key()：这一局、这一轮、这一位、这一处市集；换了就作废）。
## 只选中，主按钮变「就不交易了」，按主按钮才结束回合（安卓压力测试 TS-2；桌面上还是点一下就结束，和以前一样）
var _skip_end_picked_ctx := ""
## 市集清单最后一次选中某一行的时刻（连点不算取消）
var _lshu_row_pick_ms := 0
var _last_configs: Array = []
var _last_trade_signature := ""
var _last_sale_signature := ""
var _sale_selection := {}
var _sale_selected_slots := {}
## 真人事件丢货按“仓位”选择，避免同种货物多件时数量含糊。
## 规则状态仍只存在 EventSystem.pending_event_decision；这里仅保存临时 UI 选择。
var _event_loss_selected_slots := {}
## EXCHANGE_ONE_GOOD 的 UI 只保存尚未提交的三项选择；合法范围每次都由
## EventSystem.get_pending_exchange_availability() 只读重算。
var _event_exchange_give_good := ""
var _event_exchange_target := ""
var _event_exchange_receive_good := ""
var _event_exchange_submitting := false
var _event_exchange_sig := ""
## 这块界面正式开过的是哪一局（GameState.session_generation）。计时、时间到、电脑开走都只对这一局做：
## 3D 入口点「再来一局」时，新局在加载页淡入前就已经准备好（reset_session → prepare → finalize），
## 而 on_game_started 要等加载到第 ③ 步才调；中间这几帧若拿上一局停在 20:00 的秒表去判，
## 新局第 0 轮就被判时间到、当场结算，加载完是一块没有按钮的死棋盘（2026-09-26 Carlos：「点击再次开始，结果没有反应」）。
var _started_session := -1
## 自动存档记到哪一回合了（"局号|轮|座位"），同一回合开始只写一次
var _lshu_autosave_key := ""
var _trade_panel_mode := TradePanelMode.EXCHANGE
var _trade_context_signature := ""
var _player_rows: Array = []
var _ai: AITurnController
var _human_input_unlocked := true
var _awaiting_turn_ack := false
var _move_animating := false
var _trade_ui_updating := false
var _cached_trade_actions: Array = []
var _cached_trade_availability: Dictionary = {}
var _cached_buy_availability: Dictionary = {}
var _cached_exchange_availability: Dictionary = {}
var _cached_card_sale_availability: Dictionary = {}
var _cached_trade_card: Dictionary = {}
var _trade_selector := TradeSelectorModel.new()
var _trade_submitting := false
var _primary_action_guarded := false
var _primary_action_guard_serial := 0
var _trade_tile_tween: Tween
## 兼容旧测试字段；正式状态只读 TradeSelectorModel。
var _selected_give_index := -1
var _selected_receive_index := -1
var _action_log: Array[String] = []

# 夜间版“回合控制台”。旧场景节点保留为测试兼容层，但运行时不可见。
var _console: VBoxContainer
var _player_cards: HBoxContainer
var _turn_status: Label
var _stepper: RichTextLabel
var _roll_page: VBoxContainer
var _move_page: VBoxContainer
var _trade_page: VBoxContainer
var _end_page: VBoxContainer
var _dice_face: Label
var _dice_3d: Dice3DView
var _dice_meaning: Label
var _dice_rolling := false
var _move_budget: Label
var _move_title: Label
var _move_hint: Label
var _event_exchange_panel: VBoxContainer
var _event_exchange_give_list: VBoxContainer
var _event_exchange_receive_list: VBoxContainer
var _event_exchange_target_option: OptionButton
var _event_exchange_status: Label
var _console_switch_button: Button
var _trade_city_label: Label
var _trade_ratio_label: Label
var _give_grid: VBoxContainer
var _receive_grid: VBoxContainer
var _trade_connector: Control
var _hud_cargo_content_inner: VBoxContainer
var _console_trade_preview: Label
var _console_trade_status: Label
var _console_exchange_one: Button
var _console_exchange_max: Button
var _cargo_grid: GridContainer
var _console_sale: Button
var _console_discard: Button
var _log_text: RichTextLabel
var _console_feedback: Label
var _secondary_action: Button
var _secondary_alt_action: Button
var _primary_action: Button
var _silver_icon: Texture2D

# HUD-LOCK-001：由封板分层源稿驱动的对局 HUD。仅承载表现和既有命令入口，
# 不拥有任何规则状态。
const HUD_SCROLL_TEXTURE := preload("res://assets/game/ui/ui_hud_scroll_v1.png")
const HUD_TOPBAR_TEXTURE := preload("res://assets/game/ui/ui_hud_topbar_wood_v1.png")
const HUD_ACTION_PLAQUE_TEXTURE := preload("res://assets/game/ui/ui_hud_current_action_plaque_v1.png")
const HUD_AI_CARD_TEXTURE := preload("res://assets/game/ui/ui_hud_ai_card_v1.png")
const HUD_SILVER_TEXTURE := preload("res://assets/game/ui/ui_hud_silver_ingot_v1.png")
const HUD_SILVER_SMALL_TEXTURE := preload("res://assets/game/ui/ui_hud_silver_ingot_small_v1.png")
const TRADE_CARGO_NORMAL_TEXTURE := preload("res://assets/game/ui/trade/cargo_slot_normal_hd.png")
const TRADE_CARGO_SELECTED_TEXTURE := preload("res://assets/game/ui/trade/cargo_slot_selected_hd.png")
const TRADE_SELECTED_GLOW_TEXTURE := preload("res://assets/game/ui/trade/selected_glow_frame_square_hd.png")
const TRADE_REWARD_NORMAL_TEXTURE := preload("res://assets/game/ui/trade/reward_tile_normal_hd.png")
const TRADE_REWARD_SELECTED_TEXTURE := preload("res://assets/game/ui/trade/reward_tile_selected_hd.png")
const TRADE_EXCHANGE_BOARD_TEXTURE := preload("res://assets/game/ui/trade/exchange_board_blank_hd.png")
const TRADE_EXCHANGE_ARROW_TEXTURE := preload("res://assets/game/ui/trade/exchange_arrow_right_hd.png")
const TRADE_STATUS_STRIP_TEXTURE := preload("res://assets/game/ui/trade/status_preview_strip_blank_hd.png")
const TRADE_SEAL_BADGE_TEXTURE := preload("res://assets/game/ui/trade/seal_badge_blank_hd.png")
const TRADE_PRIMARY_ACTIVE_TEXTURE := preload("res://assets/game/ui/trade/main_button_active_blank_hd.png")
const TRADE_PRIMARY_HOVER_TEXTURE := preload("res://assets/game/ui/trade/main_button_hover_blank_hd.png")
const TRADE_PRIMARY_PRESSED_TEXTURE := preload("res://assets/game/ui/trade/main_button_pressed_blank_hd.png")
const TRADE_PRIMARY_DISABLED_TEXTURE := preload("res://assets/game/ui/trade/main_button_disabled_blank_hd.png")
const HUD_DIVIDER_ORNATE := preload("res://assets/game/ui/trade/divider_horizontal_ornate_hd.png")

## TASK-HUD-TRADE-LAYER-FIX-008：船舱几何约 95%（禁止 Container.scale）。
const CARGO_SLOT_PX := 46.0
const CARGO_SLOT_GAP_PX := 5.0
const CARGO_GRID_WIDTH_PX := 199.0 # 4×46 + 3×5
const CARGO_ICON_PX := 30.0
const CARGO_WALLET_ICON_PX := 19.0
const PUBLIC_SILVER_RIGHT_INSET_PX := 32.0
const TOPBAR_HEIGHT_PX := 64.0
const SCROLL_SRC_W := 1024.0
const SCROLL_SRC_H := 2314.0
const SCROLL_WIDTH_MIN := 286.0
const SCROLL_WIDTH_MAX := 344.0
## 地图可伸入卷轴左侧透明装饰的像素；内容 fit 仍排除卷轴纸面。
const MAP_UNDER_SCROLL_FRINGE_PX := 16.0
const MAP_SAFE_RIGHT_PAD_PX := 24.0
const AI_GOOD_SLOT_PX := 48.0
const AI_GOOD_ICON_PX := 30.0
const AI_CARD_HEIGHT_WITH_GOODS := 106.0
const AI_CARD_HEIGHT_COMPACT := 64.0

## TASK-HUD-TRADE-LAYER-FIX-008：全局模态与 HUD 层级。
## Board/HUD 用 Control.z_index；Event/Handover/Result 用 CanvasLayer.layer（压住 Node2D 下的 Control 名牌）。
const Z_BOARD := 0
const Z_SCROLL := 20
const Z_AI_CARD := 30
const Z_TOPBAR := 50
const Z_CITY_LORE := 70
const Z_EVENT_DIALOG := 90
const Z_MODAL_OVERLAY := 100

## 贸易契约板几何（摘要条在板外）。
const TRADE_FRAME_HEIGHT_PX := 210.0 # 单 Tile + 滚轮提示 + 倍数行；内容宽 ≤214
const TRADE_FRAME_HEIGHT_COMPACT_PX := 190.0
const TRADE_SAFE_MARGIN_L := 18
const TRADE_SAFE_MARGIN_R := 18
const TRADE_SAFE_MARGIN_T := 16
const TRADE_SAFE_MARGIN_B := 12
## PXD 原稿使用等宽方格。左右两侧固定同一包围盒，禁止 reward 竖长素材改变几何。
const TRADE_TILE_W := 52.0
const TRADE_TILE_H := 52.0
const TRADE_REWARD_SEP_PX := 4
const TRADE_SIDE_COL_W := 82.0
const TRADE_CONNECTOR_W := 42.0
const TRADE_CONTRACT_SEP := 4
## 箭头的可见符号仍保持轻量，但点击命中面不能沿用旧版 13×32px。
## 44px 是桌面触控板/触屏的最低可操作目标；按钮以重叠方式放在 Tile 两侧，
## 不挤压原稿的 82px 栏宽。
const TRADE_ARROW_HIT_PX := 44.0
const TRADE_ARROW_HIT_H := 44.0
const TRADE_CONTENT_MAX_W := 214.0 # 82+4+42+4+82
const TRADE_MAX_REWARDS := 3
const TRADE_RECEIVE_CHOICE_MAX := 4
const TRADE_RECEIVE_CHOICE_H := 44.0

var _hud_topbar: Control
var _hud_current_action: Label
var _hud_supply: Label
var _hud_supply_title: Label
## 对局时长上限（Carlos 2026-09-25：保持原版规则，但一局最长 20 分钟）。计时满后走原版
## 终局流程：触发终局 → 补齐本轮使所有玩家回合数相同 → 白银最多者胜。<= 0 表示不限时。
const MATCH_TIME_LIMIT_SEC := 1200.0
var match_time_limit_sec := MATCH_TIME_LIMIT_SEC
## 玩家在开局页把时长拉到「不限时」（Carlos 2026-09-26）：照样计时（日光循环、右上角「已玩」），只是不会时间到。
## 测试把 match_time_limit_sec 设成 0 是「关掉计时」，与此不同，所以单独一个开关。
var match_unlimited := false
const LshuMatchSettings := preload("res://scripts/lshu_ui/lshu_match_settings.gd")
const LshuMatchSave := preload("res://scripts/lshu_ui/lshu_match_save.gd")
var _match_elapsed := 0.0          # 真实秒数（不受测试加速的 Engine.time_scale 影响）
var _hud_clock: Label
var _clock_shown := -1
var _hud_scroll_root: Control
var _hud_scroll_art: TextureRect
var _hud_action_heading: Label
var _hud_round_caption: Label
var _hud_cargo_silver: Label
var _hud_cargo_grid: GridContainer
var _hud_cargo_grid_center: CenterContainer
var _hud_scroll_margin: MarginContainer
var _hud_cargo_block: VBoxContainer
var _hud_phase_content: VBoxContainer
var _hud_primary_wrap: Control
var _hud_trade_frame: Control
var _hud_move_dice: Label
var _hud_move_destination: Label
var _ai_page: VBoxContainer
var _ai_summary: Label
var _end_summary: Label
var _ai_card: Control
var _ai_card_name: Label
var _ai_card_silver: Label
var _ai_card_goods: HBoxContainer
var _primary_skin: TextureRect
var _trade_exchange_badge: Label
var _trade_give_tile: Control
var _trade_receive_tile: Control
var _trade_give_held: Label
var _trade_receive_meta: Label
var _trade_give_selector: Control
var _trade_receive_selector: Control
var _trade_times_max_label: Label
var _trade_times_current_label: Label
var _trade_times_buttons: Array = []
var _trade_consume_label: Label
var _trade_summary_skin: TextureRect
var _trade_summary_wrap: Control
var _trade_give_column: VBoxContainer
var _trade_receive_column: VBoxContainer
var _give_heading: Label
var _receive_heading: Label
var _trade_give_wheel_hint: Label
var _trade_receive_wheel_hint: Label
var _trade_receive_choice_list: VBoxContainer
var _trade_receive_choice_buttons: Array[Button] = []
var _trade_contract_row: HBoxContainer
var _trade_times_row: VBoxContainer
var _trade_sale_panel: VBoxContainer
var _trade_sale_icon_row: HBoxContainer
var _trade_sale_icon_slots: Array[TextureRect] = []
var _trade_sale_count_label: Label
var _trade_sale_silver_tile: Control
var _trade_sale_hint: Label
var _trade_mode_bar: HBoxContainer
var _trade_mode_buttons: Dictionary = {} # mode int -> Button

## 回合流程简化（Carlos 2026-09-26）：规则一条不改，只把「没有选择余地」的确认交给界面——
##   · AI 回合结束不再弹「已交接，继续」，改为不挡操作的「轮到你了」提示；
##   · 地图上点目的地只选中（画出路线和步数），按主按钮「出发（N 步）」才走；「原地停留」同样先选、再按「就停在这里」
##     （Carlos 2026-09-27「先选再确认」，推翻 09-26 的一步出发）；
##   · 移动落定、事件结算后自动 proceed（开通商道本就在其中），不再点「继续」；
##   · 停在道路/无任何可做交易时自动跳过贸易并结束回合；
##   · 「不交易，结束回合」= skip_trade + end_turn 合成一个真按钮；
##   · 本回合唯一一次交易完成后停一拍（可点「结束回合」跳过）再自动结束回合。
## 以上链式命令全部挂在玩家自己的操作回调里（不挂 state_changed），规则驱动的测试不受影响；
## auto_advance = false 可退回逐步确认（交易/事件机制测试用）。
const AUTO_END_TURN_DELAY_SEC := 1.1
const IDLE_HINT_SEC := 5.0
const TURN_TOAST_SEC := 1.8
const SECONDARY_BUTTON_H := 32.0
## 自动推进换掉了按钮的含义后，这么久之内落在操作坞上的点击 / 空格一律吞掉：
## 连点「就停在这里」/「出发」不能变成「不交易，结束回合」，连点「确认丢失」不能变成一笔交易。
const DOCK_CLICK_BLOCK_SEC := 0.5
## 先选再确认的文字（Carlos 2026-09-27）：没选时 / 选了目的地 / 选了原地停留，提示条和主按钮说同一件事
const STAY_CONFIRM_TEXT := "就停在这里"
const MOVE_PROMPT_PICK := "点地图上亮着的地方，选一个目的地"
const MOVE_PROMPT_DEST_PICKED := "按「出发（%d 步）」，或点别处改选"
const MOVE_PROMPT_STAY_PICKED := "按「就停在这里」，或点别处改选"
## 贸易页「紧凑排版」的高度上限：720（16:9 含 1080p 等比）与 800（16:10）都走紧凑排版
const DENSE_TRADE_MAX_H := 900.0
var auto_advance := true
var _auto_end_serial := 0
var _auto_end_pending := false
var _auto_proceed_after_move := false
var _idle_sec := 0.0
var _idle_hint_on := false
var _turn_result_text := ""
var _hud_prompt: Label
var _hud_secondary_row: HBoxContainer
var _hud_action_dock: VBoxContainer
var _hud_step_labels: Array[Label] = []
var _turn_toast: PanelContainer
var _turn_toast_label: Label
var _turn_toast_tween: Tween
var _primary_hint_plaque: Panel
var _idle_key := ""
var _dock_block_until_ms := 0
## 换人卡按下后这一小会儿地图不接点击（双击的第二下不能打开城市卡，复检 EI-7）
var _board_click_block_until_ms := 0


func _ready() -> void:
	_fun = LshuFunUiScript.new()
	_fun.screen = self
	add_child(_fun)
	_build_round_console()
	_ai = AITurnController.new()
	_ai.name = "AITurnController"
	add_child(_ai)
	_ai.board_view = %BoardView
	_ai.event_presenter = %EventDrawOverlay
	_ai.status_changed.connect(_on_ai_status)
	_ai.event_resolved.connect(func(_event: Dictionary): %CityLoreCard.force_close())
	_ai.event_resolved.connect(func(event: Dictionary): _fun.on_ai_event(event))
	%EventDrawOverlay.stage_revealed.connect(func(event: Dictionary): _fun.on_stage_revealed(event))
	%EventDrawOverlay.player_look = _fun.look
	_ai.turn_finished.connect(_on_ai_turn_finished)
	_ai.blocked.connect(_on_ai_blocked)
	GameState.state_changed.connect(_on_state_changed)
	%RollButton.pressed.connect(_on_roll_pressed)
	%StayButton.pressed.connect(_on_stay_pressed)
	%ConfirmMoveButton.pressed.connect(_on_confirm_move_pressed)
	%SwitchButton.pressed.connect(_on_switch_pressed)
	%ProceedButton.pressed.connect(_on_proceed_pressed)
	%SkipTradeButton.pressed.connect(_on_skip_trade_pressed)
	%EndTurnButton.pressed.connect(_on_end_turn_pressed)
	%ExchangeOneButton.pressed.connect(func(): _on_exchange_pressed(_trade_selector.times if _trade_selector.times > 0 else 1))
	%ExchangeMaxButton.pressed.connect(func(): _on_exchange_pressed(_trade_selector.max_times if _trade_selector.max_times > 0 else -1))
	%SaleButton.pressed.connect(_on_sale_pressed)
	%DiscardButton.pressed.connect(_on_discard_pressed)
	%HandoverButton.pressed.connect(_on_handover_ack)
	%RestartButton.pressed.connect(func(): restart_requested.emit(_last_configs))
	%BackTitleButton.pressed.connect(func(): back_to_title_requested.emit())
	%BoardView.node_clicked.connect(_on_board_node_clicked)
	%BoardView.city_inspect_requested.connect(_on_city_inspect_requested)
	%BoardView.move_animation_finished.connect(_on_move_animation_finished)
	%EventDrawOverlay.presentation_finished.connect(_on_event_presentation_finished)
	%EventDrawOverlay.revealed.connect(func() -> void:
		if _human_event_presenting():
			_refresh_action_buttons()
			_refresh_round_console())
	%GiveOption.item_selected.connect(_on_give_option_selected)
	%ReceiveOption.item_selected.connect(_on_receive_option_selected)
	_primary_action.pressed.connect(_on_primary_button_pressed)
	_secondary_action.pressed.connect(_on_secondary_action_pressed)
	_secondary_alt_action.pressed.connect(_on_secondary_alt_pressed)
	for dock_button: Button in [_primary_action, _secondary_action, _secondary_alt_action]:
		dock_button.button_down.connect(_on_dock_button_down.bind(dock_button))
	_console_switch_button.pressed.connect(_on_switch_pressed)
	_console_exchange_one.pressed.connect(func(): _on_confirm_trade_pressed())
	_console_exchange_max.pressed.connect(func(): _on_confirm_trade_pressed())
	_console_sale.pressed.connect(_on_sale_pressed)
	_console_discard.pressed.connect(_on_discard_pressed)
	_apply_modal_layer_stack()
	# 手柄（AYN Thor 等；scripts/pad/pad_match.gd）：只在按了手柄以后起作用，鼠标、触屏、键盘照旧
	add_child(preload("res://scripts/pad/pad_match.gd").new())


func _build_round_console() -> void:
	# 静态场景中的旧控件保留给自动化/信号契约；玩家只看到由封板源稿组成的 HUD。
	$RootMargin/RootVBox/TopBar.visible = false
	%ModeBanner.visible = false
	%EndgameBanner.visible = false
	var side: VBoxContainer = $RootMargin/RootVBox/MainRow/SidePanel
	for child in side.get_children():
		child.visible = false
	%CurrentPlayerLabel.visible = false
	%PhaseLabel.visible = false
	%TransportLabel.visible = false
	%RoundLabel.visible = false
	%SupplyLabel.visible = false
	%DiceLabel.visible = false
	# 兼容热重载中可能残留的早期底图背衬；正式 HUD 只保留 BoardView 自己的一张 MapStage。
	var legacy_map_bleed := %BoardView.get_node_or_null("MapBleedBackground")
	if legacy_map_bleed != null:
		legacy_map_bleed.queue_free()

	_build_hud_topbar()
	_build_hud_sidepanel(side)
	_build_hud_ai_card()
	if not legacy_hud:
		_build_lshu_hud()
	# BoardView 自己会在 resize 时用独立 x/y 映射填满地图区；不再二次 cover 裁切。
	resized.connect(_layout_hud)
	call_deferred("_layout_hud")
	%BoardView.resized.connect(_on_board_view_resized)


func _build_hud_topbar() -> void:
	_hud_topbar = Control.new()
	_hud_topbar.name = "HudTopbar"
	_hud_topbar.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_hud_topbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hud_topbar)
	move_child(_hud_topbar, 2)
	var wood := TextureRect.new()
	wood.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wood.texture = HUD_TOPBAR_TEXTURE
	wood.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wood.stretch_mode = TextureRect.STRETCH_SCALE
	wood.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_topbar.add_child(wood)

	var action_plaque := Control.new()
	action_plaque.name = "ActionPlaque"
	action_plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_topbar.add_child(action_plaque)
	var plaque_texture := TextureRect.new()
	plaque_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plaque_texture.texture = HUD_ACTION_PLAQUE_TEXTURE
	plaque_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	plaque_texture.stretch_mode = TextureRect.STRETCH_SCALE
	action_plaque.add_child(plaque_texture)
	_hud_current_action = _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_PLAQUE, HudStyle.PARCHMENT_LIGHT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_hud_current_action.name = "HudCurrentAction"
	action_plaque.add_child(_hud_current_action)
	# 红匾文字水平/垂直居中；左右安全内边距 16px。
	_hud_current_action.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud_current_action.offset_left = 16.0
	_hud_current_action.offset_right = -16.0
	_hud_current_action.offset_top = 4.0
	_hud_current_action.offset_bottom = -4.0
	_hud_current_action.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	var supply_row := HBoxContainer.new()
	supply_row.name = "SupplyRow"
	supply_row.alignment = BoxContainer.ALIGNMENT_END
	# 银锭 ↔ 文案、标题 ↔ 数字均为 8px。
	supply_row.add_theme_constant_override("separation", 8)
	supply_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_topbar.add_child(supply_row)
	var ingot := TextureRect.new()
	ingot.name = "SupplyIngot"
	ingot.custom_minimum_size = Vector2(38, 34)
	ingot.texture = HUD_SILVER_TEXTURE
	ingot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ingot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ingot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	supply_row.add_child(ingot)
	_hud_supply_title = _hud_styled_label(
		HudStyle.FONT_DISPLAY_BOLD, HudStyle.SIZE_PUBLIC_SILVER, HudStyle.TOPBAR_GOLD_TEXT, HORIZONTAL_ALIGNMENT_RIGHT
	)
	_hud_supply_title.name = "SupplyTitle"
	_hud_supply_title.text = "公共银两："
	_hud_supply_title.size_flags_horizontal = Control.SIZE_SHRINK_END
	_hud_supply_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hud_supply_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	supply_row.add_child(_hud_supply_title)
	_hud_supply = _hud_styled_label(
		HudStyle.FONT_DISPLAY_BOLD, HudStyle.SIZE_PUBLIC_SILVER, HudStyle.TOPBAR_GOLD_TEXT, HORIZONTAL_ALIGNMENT_RIGHT
	)
	_hud_supply.name = "SupplyValue"
	_hud_supply.size_flags_horizontal = Control.SIZE_SHRINK_END
	_hud_supply.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hud_supply.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	supply_row.add_child(_hud_supply)

	# 对局剩余时间：顶栏正中，与公共银两同一套金色字
	_hud_clock = _hud_styled_label(
		HudStyle.FONT_DISPLAY_BOLD, HudStyle.SIZE_PLAQUE + 4, HudStyle.TOPBAR_GOLD_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_hud_clock.name = "MatchClock"
	_hud_topbar.add_child(_hud_clock)


func _build_hud_sidepanel(side: VBoxContainer) -> void:
	# SidePanel 仅保留场景兼容节点；对局卷轴挂到 GameScreen 并叠在全宽地图上。
	side.custom_minimum_size = Vector2(0, 0)
	side.size_flags_horizontal = Control.SIZE_SHRINK_END
	side.clip_contents = false
	side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_scroll_root = Control.new()
	_hud_scroll_root.name = "HudScrollRoot"
	# 手绘高清 UI：组件包与卷轴继承 linear + mipmaps，禁止像素采样。
	_hud_scroll_root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_hud_scroll_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_hud_scroll_root.z_index = Z_SCROLL
	# 挂到 GameScreen：避免 VBox 每帧重置 position，才能叠在地图右缘上。
	add_child(_hud_scroll_root)
	var scroll_texture := TextureRect.new()
	scroll_texture.name = "ScrollSourceArt"
	scroll_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll_texture.texture = HUD_SCROLL_TEXTURE
	scroll_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# 保持源图宽高比，禁止横向拉胖。
	scroll_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	scroll_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_scroll_root.add_child(scroll_texture)
	_hud_scroll_art = scroll_texture

	var margin := MarginContainer.new()
	margin.name = "ScrollContentMargin"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 侧边安全区在 _layout_hud 中按卷轴实际宽度重算；顶/底固定。
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_top", 80)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_bottom", 64)
	_hud_scroll_root.add_child(margin)
	_hud_scroll_margin = margin
	_console = VBoxContainer.new()
	_console.name = "RoundConsole"
	_console.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 区块间距 12：分隔线上下各约 12，主按钮与底部提示 12。
	_console.add_theme_constant_override("separation", 12)
	margin.add_child(_console)

	var cargo_block := VBoxContainer.new()
	cargo_block.name = "CargoBlock"
	cargo_block.add_theme_constant_override("separation", 8)
	_console.add_child(cargo_block)
	_hud_cargo_block = cargo_block
	# 标题+网格同一内层容器，宽度≈纸面 95%，水平居中；禁止 scale。
	var cargo_outer := CenterContainer.new()
	cargo_outer.name = "CargoOuterCenter"
	cargo_outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cargo_block.add_child(cargo_outer)
	var cargo_inner := VBoxContainer.new()
	cargo_inner.name = "CargoContentInner"
	cargo_inner.custom_minimum_size = Vector2(CARGO_GRID_WIDTH_PX, 0)
	cargo_inner.add_theme_constant_override("separation", 8)
	cargo_outer.add_child(cargo_inner)
	_hud_cargo_content_inner = cargo_inner
	var cargo_header := HBoxContainer.new()
	cargo_header.add_theme_constant_override("separation", 4)
	cargo_inner.add_child(cargo_header)
	var cargo_title := _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_CARGO_TITLE, HudStyle.INK_STRONG, HORIZONTAL_ALIGNMENT_LEFT
	)
	cargo_title.name = "CargoTitle"
	cargo_title.text = "玩家船舱"
	cargo_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cargo_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cargo_header.add_child(cargo_title)
	var cargo_wallet := HBoxContainer.new()
	cargo_wallet.name = "CargoWallet"
	cargo_wallet.size_flags_horizontal = Control.SIZE_SHRINK_END
	cargo_wallet.alignment = BoxContainer.ALIGNMENT_END
	cargo_wallet.add_theme_constant_override("separation", 4)
	cargo_header.add_child(cargo_wallet)
	var cargo_ingot := TextureRect.new()
	cargo_ingot.name = "CargoWalletIcon"
	cargo_ingot.custom_minimum_size = Vector2(CARGO_WALLET_ICON_PX, CARGO_WALLET_ICON_PX)
	cargo_ingot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cargo_ingot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cargo_ingot.texture = HUD_SILVER_TEXTURE
	cargo_ingot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cargo_ingot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	cargo_wallet.add_child(cargo_ingot)
	_hud_cargo_silver = _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_CARGO_TITLE, HudStyle.GOLD, HORIZONTAL_ALIGNMENT_LEFT
	)
	_hud_cargo_silver.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_hud_cargo_silver.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hud_cargo_silver.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cargo_wallet.add_child(_hud_cargo_silver)
	# 卷轴右侧流苏会压住最右 ~16px：银两往里收，不再被挡住。
	var wallet_clear := Control.new()
	wallet_clear.name = "CargoWalletTasselClear"
	wallet_clear.custom_minimum_size = Vector2(16, 0)
	wallet_clear.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cargo_header.add_child(wallet_clear)
	var cargo_grid_center := CenterContainer.new()
	cargo_grid_center.name = "CargoGridCenter"
	cargo_grid_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cargo_inner.add_child(cargo_grid_center)
	_hud_cargo_grid_center = cargo_grid_center
	_hud_cargo_grid = GridContainer.new()
	_hud_cargo_grid.name = "CargoSelectGrid"
	_hud_cargo_grid.columns = 4
	_hud_cargo_grid.custom_minimum_size = Vector2(CARGO_GRID_WIDTH_PX, CARGO_SLOT_PX)
	_hud_cargo_grid.add_theme_constant_override("h_separation", int(CARGO_SLOT_GAP_PX))
	_hud_cargo_grid.add_theme_constant_override("v_separation", int(CARGO_SLOT_GAP_PX))
	cargo_grid_center.add_child(_hud_cargo_grid)
	_cargo_grid = _hud_cargo_grid
	# 正式装饰分隔线（禁止 1px ColorRect）；上下间距由 console separation=12 保证。
	var divider_wrap := MarginContainer.new()
	divider_wrap.name = "OrnateDividerWrap"
	divider_wrap.add_theme_constant_override("margin_top", 0)
	divider_wrap.add_theme_constant_override("margin_bottom", 0)
	_console.add_child(divider_wrap)
	var divider := TextureRect.new()
	divider.name = "OrnateDivider"
	divider.texture = HUD_DIVIDER_ORNATE
	divider.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	divider.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	divider.custom_minimum_size = Vector2(0, 12)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	divider_wrap.add_child(divider)

	var action_header := Control.new()
	action_header.name = "ActionHeader"
	action_header.custom_minimum_size = Vector2(0, 28)
	_console.add_child(action_header)
	_hud_action_heading = _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_ACTION_HEADING, HudStyle.INK_STRONG, HORIZONTAL_ALIGNMENT_CENTER
	)
	_hud_action_heading.name = "ActionHeading"
	_hud_action_heading.text = "本回合行动"
	_hud_action_heading.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud_action_heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 固定标题换成本回合三步进度（掷骰 → 行路 → 交易）；标题节点保留给旧契约，但不再显示。
	_hud_action_heading.visible = false
	action_header.add_child(_hud_action_heading)
	var steps := HBoxContainer.new()
	steps.name = "TurnSteps"
	steps.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	steps.offset_right = -56.0
	steps.alignment = BoxContainer.ALIGNMENT_CENTER
	steps.add_theme_constant_override("separation", 6)
	steps.mouse_filter = Control.MOUSE_FILTER_IGNORE
	action_header.add_child(steps)
	_hud_step_labels.clear()
	for i in 3:
		if i > 0:
			var arrow := _hud_styled_label(
				HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_CAPTION, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
			)
			arrow.text = "›"
			steps.add_child(arrow)
		var step := _hud_styled_label(
			HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_BODY, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
		)
		step.name = "TurnStep%d" % i
		step.text = ["掷骰", "行路", "交易"][i]
		steps.add_child(step)
		_hud_step_labels.append(step)
	_hud_round_caption = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_ROUND_CAPTION, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_RIGHT
	)
	_hud_round_caption.name = "RoundCaption"
	_hud_round_caption.text = "第 1 轮"
	_hud_round_caption.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	_hud_round_caption.offset_left = -72.0
	_hud_round_caption.offset_right = -8.0
	_hud_round_caption.offset_top = -10.0
	_hud_round_caption.offset_bottom = 10.0
	_hud_round_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	action_header.add_child(_hud_round_caption)
	var pages := VBoxContainer.new()
	pages.name = "PhaseContent"
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pages.add_theme_constant_override("separation", 8)
	_console.add_child(pages)
	_hud_phase_content = pages

	_roll_page = _new_hud_page("RollPage")
	pages.add_child(_roll_page)
	var roll_title := _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_PHASE, HudStyle.CINNABAR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	roll_title.name = "PhaseTitleRoll"
	roll_title.text = "准备掷骰"
	_roll_page.add_child(roll_title)
	_roll_page.add_theme_constant_override("separation", 16)
	# 展示槽约 120×112；骰子本体约 104px，不撑满槽。
	var dice_slot := CenterContainer.new()
	dice_slot.name = "DiceViewportSlot"
	dice_slot.custom_minimum_size = Vector2(120, 112)
	dice_slot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	dice_slot.clip_contents = true
	_roll_page.add_child(dice_slot)
	_dice_3d = preload("res://scenes/ui/dice_3d_view.tscn").instantiate()
	_dice_3d.name = "Dice3DView"
	_dice_3d.custom_minimum_size = Vector2(120, 112)
	dice_slot.add_child(_dice_3d)
	_dice_face = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, 1, Color.TRANSPARENT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_dice_face.visible = false
	_roll_page.add_child(_dice_face)
	_dice_meaning = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_BODY, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_dice_meaning.name = "DiceMeaning"
	_dice_meaning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_roll_page.add_child(_dice_meaning)

	_move_page = _new_hud_page("MovePage")
	pages.add_child(_move_page)
	_move_title = _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_PHASE, HudStyle.CINNABAR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_move_title.name = "PhaseTitleMove"
	_move_title.text = "移动"
	_move_page.add_child(_move_title)
	_hud_move_dice = _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_BODY, HudStyle.INK_STRONG, HORIZONTAL_ALIGNMENT_CENTER
	)
	_move_page.add_child(_hud_move_dice)
	_move_budget = _hud_styled_label(
		HudStyle.FONT_DISPLAY_BOLD, HudStyle.SIZE_MOVE_BUDGET, HudStyle.CINNABAR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_move_page.add_child(_move_budget)
	_move_hint = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_BODY, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_move_hint.text = "点击地图选择目的地"
	_move_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_move_page.add_child(_move_hint)
	_hud_move_destination = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_BODY, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_hud_move_destination.custom_minimum_size = Vector2(0, 38)
	_hud_move_destination.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud_move_destination.add_theme_stylebox_override("normal", _panel_style(Color("F2E6C9"), HudStyle.INK_WEAK, 1))
	_move_page.add_child(_hud_move_destination)
	_event_exchange_panel = _build_event_exchange_panel()
	_move_page.add_child(_event_exchange_panel)
	_console_switch_button = Button.new()
	_console_switch_button.name = "ConsoleSwitchButton"
	_console_switch_button.text = "切换交通"
	_console_switch_button.flat = true
	HudStyle.apply_caption(_console_switch_button, HudStyle.INK_WEAK, HudStyle.SIZE_CAPTION)
	_move_page.add_child(_console_switch_button)

	_ai_page = _new_hud_page("AiPage")
	pages.add_child(_ai_page)
	var ai_title := _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_PHASE, HudStyle.CINNABAR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	ai_title.name = "PhaseTitleAi"
	ai_title.text = "AI 正在行动"
	_ai_page.add_child(ai_title)
	_ai_summary = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_BODY, HudStyle.INK_BODY, HORIZONTAL_ALIGNMENT_CENTER
	)
	_ai_summary.name = "AiSummary"
	_ai_summary.custom_minimum_size = Vector2(0, 88)
	_ai_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ai_summary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_ai_summary.add_theme_stylebox_override("normal", _panel_style(Color("F2E6C9"), HudStyle.GOLD, 1))
	_ai_page.add_child(_ai_summary)

	_trade_times_buttons.clear()
	_trade_page = _new_hud_page("TradePage")
	pages.add_child(_trade_page)
	_trade_city_label = _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_PHASE, HudStyle.INK_STRONG, HORIZONTAL_ALIGNMENT_CENTER
	)
	_trade_city_label.name = "PhaseTitleTrade"
	_trade_page.add_child(_trade_city_label)
	_trade_mode_bar = HBoxContainer.new()
	_trade_mode_bar.name = "TradeModeBar"
	_trade_mode_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_trade_mode_bar.add_theme_constant_override("separation", 4)
	_trade_page.add_child(_trade_mode_bar)
	_trade_mode_buttons.clear()
	for mode_def in [
		{"mode": TradePanelMode.BUY, "text": "买入", "name": "TradeModeBuy"},
		{"mode": TradePanelMode.EXCHANGE, "text": "兑换", "name": "TradeModeExchange"},
		# 原版同时存在「按贸易卡换白银」与「每件 1 银直售」。仅写「出售」会
		# 把两种规则混为一谈，因此明确标出按牌面结算的这一支。
		{"mode": TradePanelMode.CARD_SELL, "text": "按卡售银", "name": "TradeModeSale"},
		# 每件 1 银的直售原来藏在小字链接里；它是同级的第四种交易方式，放回页签。
		{"mode": TradePanelMode.DIRECT_SALE, "text": "直售", "name": "TradeModeDirectSale"},
	]:
		var mode_btn := Button.new()
		mode_btn.name = String(mode_def["name"])
		mode_btn.text = String(mode_def["text"])
		mode_btn.focus_mode = Control.FOCUS_NONE
		mode_btn.custom_minimum_size = Vector2(50, 26)
		mode_btn.toggle_mode = false
		var captured_mode := int(mode_def["mode"])
		mode_btn.pressed.connect(func(): _set_trade_panel_mode(captured_mode))
		_trade_mode_bar.add_child(mode_btn)
		_trade_mode_buttons[captured_mode] = mode_btn
	var trade_frame := Control.new()
	trade_frame.name = "TradeFrame"
	trade_frame.custom_minimum_size = Vector2(0, TRADE_FRAME_HEIGHT_PX)
	trade_frame.clip_contents = true
	trade_frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_trade_page.add_child(trade_frame)
	_hud_trade_frame = trade_frame
	var trade_texture := TextureRect.new()
	trade_texture.name = "ExchangeBoardTexture"
	trade_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	trade_texture.texture = TRADE_EXCHANGE_BOARD_TEXTURE
	trade_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	trade_texture.stretch_mode = TextureRect.STRETCH_SCALE
	trade_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trade_frame.add_child(trade_texture)
	var trade_margin := MarginContainer.new()
	trade_margin.name = "TradeSafeMargin"
	trade_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	trade_margin.add_theme_constant_override("margin_left", TRADE_SAFE_MARGIN_L)
	trade_margin.add_theme_constant_override("margin_top", TRADE_SAFE_MARGIN_T)
	trade_margin.add_theme_constant_override("margin_right", TRADE_SAFE_MARGIN_R)
	trade_margin.add_theme_constant_override("margin_bottom", TRADE_SAFE_MARGIN_B)
	trade_frame.add_child(trade_margin)
	var board_stack := VBoxContainer.new()
	board_stack.name = "TradeBoardStack"
	board_stack.add_theme_constant_override("separation", 4)
	board_stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	trade_margin.add_child(board_stack)
	var contract_row := HBoxContainer.new()
	contract_row.name = "ContractRow"
	contract_row.alignment = BoxContainer.ALIGNMENT_CENTER
	contract_row.add_theme_constant_override("separation", TRADE_CONTRACT_SEP)
	contract_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board_stack.add_child(contract_row)
	_trade_contract_row = contract_row
	_trade_ratio_label = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_CAPTION, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_trade_ratio_label.visible = false
	_trade_page.add_child(_trade_ratio_label)

	_trade_give_column = VBoxContainer.new()
	_trade_give_column.name = "GiveColumn"
	_trade_give_column.custom_minimum_size = Vector2(TRADE_SIDE_COL_W, 0)
	_trade_give_column.add_theme_constant_override("separation", 2)
	_trade_give_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	contract_row.add_child(_trade_give_column)
	_give_heading = _section_label("交出")
	_give_heading.name = "GiveHeading"
	_give_heading.custom_minimum_size = Vector2(0, 18)
	_trade_give_column.add_child(_give_heading)
	_trade_give_selector = _make_trade_side_selector(false)
	_trade_give_column.add_child(_trade_give_selector)
	_give_grid = _trade_give_selector.get_node("TradeGiveGrid") as VBoxContainer

	_trade_connector = Control.new()
	_trade_connector.name = "ConnectorColumn"
	_trade_connector.custom_minimum_size = Vector2(TRADE_CONNECTOR_W, 0)
	_trade_connector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	contract_row.add_child(_trade_connector)
	var connector_vbox := VBoxContainer.new()
	connector_vbox.name = "ConnectorStack"
	connector_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	connector_vbox.add_theme_constant_override("separation", 4)
	connector_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_trade_connector.add_child(connector_vbox)
	var badge_wrap := Control.new()
	badge_wrap.name = "ExchangeBadge"
	badge_wrap.custom_minimum_size = Vector2(34, 20)
	badge_wrap.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	connector_vbox.add_child(badge_wrap)
	var badge_texture := TextureRect.new()
	badge_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge_texture.texture = TRADE_SEAL_BADGE_TEXTURE
	badge_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	badge_texture.stretch_mode = TextureRect.STRETCH_SCALE
	badge_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_wrap.add_child(badge_texture)
	_trade_exchange_badge = _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_TRADE_QTY, HudStyle.PARCHMENT_LIGHT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_trade_exchange_badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 2)
	badge_wrap.add_child(_trade_exchange_badge)
	var exchange_arrow := TextureRect.new()
	exchange_arrow.name = "ExchangeArrow"
	exchange_arrow.custom_minimum_size = Vector2(28, 18)
	exchange_arrow.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	exchange_arrow.texture = TRADE_EXCHANGE_ARROW_TEXTURE
	exchange_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	exchange_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	exchange_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	connector_vbox.add_child(exchange_arrow)

	_trade_receive_column = VBoxContainer.new()
	_trade_receive_column.name = "ReceiveColumn"
	_trade_receive_column.custom_minimum_size = Vector2(TRADE_SIDE_COL_W, 0)
	_trade_receive_column.add_theme_constant_override("separation", 2)
	_trade_receive_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	contract_row.add_child(_trade_receive_column)
	_receive_heading = _section_label("获得")
	_receive_heading.name = "ReceiveHeading"
	_receive_heading.custom_minimum_size = Vector2(0, 18)
	_trade_receive_column.add_child(_receive_heading)
	_trade_receive_selector = _make_trade_side_selector(true)
	_trade_receive_column.add_child(_trade_receive_selector)
	_receive_grid = _trade_receive_selector.get_node("TradeReceiveGrid") as VBoxContainer
	_trade_receive_choice_list = VBoxContainer.new()
	_trade_receive_choice_list.name = "ReceiveChoiceList"
	_trade_receive_choice_list.add_theme_constant_override("separation", 3)
	_trade_receive_choice_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trade_receive_choice_list.visible = false
	_trade_receive_column.add_child(_trade_receive_choice_list)
	_trade_receive_choice_buttons.clear()
	for slot_index in TRADE_RECEIVE_CHOICE_MAX:
		var choice := _make_receive_choice_button(slot_index)
		_trade_receive_choice_list.add_child(choice)
		_trade_receive_choice_buttons.append(choice)

	var times_row := VBoxContainer.new()
	times_row.name = "TradeTimesRow"
	times_row.add_theme_constant_override("separation", 0)
	times_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_stack.add_child(times_row)
	_trade_times_row = times_row
	_trade_times_max_label = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_CAPTION, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_trade_times_max_label.name = "TradeTimesMax"
	_trade_times_max_label.text = "可兑换 0 次"
	times_row.add_child(_trade_times_max_label)
	_trade_times_current_label = _hud_styled_label(
		HudStyle.FONT_BODY_MEDIUM, HudStyle.SIZE_CAPTION, HudStyle.INK_STRONG, HORIZONTAL_ALIGNMENT_CENTER
	)
	_trade_times_current_label.name = "TradeTimesCurrent"
	_trade_times_current_label.text = "当前兑换：第 0 次"
	times_row.add_child(_trade_times_current_label)

	# 直接出售与比例兑换共用同一契约板，但拥有独立且可见的操作态。
	_trade_sale_panel = VBoxContainer.new()
	_trade_sale_panel.name = "DirectSalePanel"
	_trade_sale_panel.add_theme_constant_override("separation", 8)
	_trade_sale_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_trade_sale_panel.visible = false
	board_stack.add_child(_trade_sale_panel)
	var sale_title := _section_label("直接出售")
	sale_title.name = "DirectSaleTitle"
	_trade_sale_panel.add_child(sale_title)
	var sale_row := HBoxContainer.new()
	sale_row.name = "DirectSaleRow"
	sale_row.alignment = BoxContainer.ALIGNMENT_CENTER
	sale_row.add_theme_constant_override("separation", 8)
	_trade_sale_panel.add_child(sale_row)
	var selected_box := VBoxContainer.new()
	selected_box.custom_minimum_size = Vector2(116, 0)
	selected_box.add_theme_constant_override("separation", 3)
	sale_row.add_child(selected_box)
	var selected_heading := _section_label("交出")
	selected_box.add_child(selected_heading)
	_trade_sale_icon_row = HBoxContainer.new()
	_trade_sale_icon_row.name = "DirectSaleSelectedGoods"
	_trade_sale_icon_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_trade_sale_icon_row.add_theme_constant_override("separation", 2)
	selected_box.add_child(_trade_sale_icon_row)
	for i in 4:
		var preview_slot := TextureRect.new()
		preview_slot.name = "SalePreviewSlot_%d" % i
		preview_slot.custom_minimum_size = Vector2(24, 24)
		preview_slot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview_slot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		preview_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_trade_sale_icon_row.add_child(preview_slot)
		_trade_sale_icon_slots.append(preview_slot)
	_trade_sale_count_label = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_CAPTION, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_trade_sale_count_label.name = "DirectSaleCount"
	_trade_sale_count_label.text = "已选 0 件"
	selected_box.add_child(_trade_sale_count_label)
	var sale_arrow := TextureRect.new()
	sale_arrow.custom_minimum_size = Vector2(26, 18)
	sale_arrow.texture = TRADE_EXCHANGE_ARROW_TEXTURE
	sale_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sale_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sale_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sale_row.add_child(sale_arrow)
	var silver_box := VBoxContainer.new()
	silver_box.custom_minimum_size = Vector2(62, 0)
	silver_box.add_theme_constant_override("separation", 3)
	sale_row.add_child(silver_box)
	var silver_heading := _section_label("获得")
	silver_box.add_child(silver_heading)
	_trade_sale_silver_tile = _make_fixed_trade_tile(true)
	_trade_sale_silver_tile.name = "DirectSaleSilverTile"
	_trade_sale_silver_tile.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	silver_box.add_child(_trade_sale_silver_tile)
	_trade_sale_hint = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_CAPTION, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_trade_sale_hint.name = "DirectSaleHint"
	_trade_sale_hint.text = "点击上方货舱格选择要出售的货物"
	_trade_sale_panel.add_child(_trade_sale_hint)

	var summary_wrap := Control.new()
	summary_wrap.name = "TradeSelectionSummary"
	summary_wrap.custom_minimum_size = Vector2(0, 34)
	_trade_page.add_child(summary_wrap)
	_trade_summary_wrap = summary_wrap
	_trade_summary_skin = TextureRect.new()
	_trade_summary_skin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_trade_summary_skin.texture = TRADE_STATUS_STRIP_TEXTURE
	_trade_summary_skin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_trade_summary_skin.stretch_mode = TextureRect.STRETCH_SCALE
	_trade_summary_skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	summary_wrap.add_child(_trade_summary_skin)
	_console_trade_preview = _hud_styled_label(
		HudStyle.FONT_BODY_MEDIUM, HudStyle.SIZE_TRADE_PREVIEW, HudStyle.INK_STRONG, HORIZONTAL_ALIGNMENT_CENTER
	)
	_console_trade_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	_console_trade_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary_wrap.add_child(_console_trade_preview)
	_trade_consume_label = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_CAPTION, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_trade_consume_label.name = "TradeConsumeHint"
	_trade_consume_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trade_page.add_child(_trade_consume_label)
	_console_trade_status = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_CAPTION, HudStyle.FAILURE, HORIZONTAL_ALIGNMENT_CENTER
	)
	_console_trade_status.name = "TradeStatus"
	_console_trade_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trade_page.add_child(_console_trade_status)
	_console_exchange_one = Button.new()
	_console_exchange_one.visible = false
	_trade_page.add_child(_console_exchange_one)
	_console_exchange_max = Button.new()
	_console_exchange_max.visible = false
	_trade_page.add_child(_console_exchange_max)
	_console_sale = Button.new()
	_console_sale.visible = false
	_trade_page.add_child(_console_sale)
	_console_discard = Button.new()
	_console_discard.visible = false
	_trade_page.add_child(_console_discard)

	_end_page = _new_hud_page("EndPage")
	pages.add_child(_end_page)
	var end_title := _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_PHASE, HudStyle.CINNABAR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	end_title.name = "PhaseTitleEnd"
	end_title.text = "回合结束"
	_end_page.add_child(end_title)
	_end_summary = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_BODY, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_end_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_end_summary.custom_minimum_size = Vector2(0, 74)
	_end_page.add_child(_end_summary)

	# 保留现有测试快照所需的玩家卡与日志容器，但不占用玩家可见的卷轴空间。
	_player_cards = HBoxContainer.new()
	_player_cards.name = "PlayerCards"
	_player_cards.visible = false
	_console.add_child(_player_cards)
	_log_text = RichTextLabel.new()
	_log_text.name = "ActionLog"
	_log_text.visible = false
	_log_text.bbcode_enabled = true
	_console.add_child(_log_text)

	# 「下一步」提示：主按钮正上方的一行，告诉玩家现在该做什么（空闲过久会转朱砂色并呼吸）。
	_hud_prompt = _hud_styled_label(
		HudStyle.FONT_BODY_MEDIUM, HudStyle.SIZE_BODY, HudStyle.INK_STRONG, HORIZONTAL_ALIGNMENT_CENTER
	)
	_hud_prompt.name = "NextStepPrompt"
	_hud_prompt.custom_minimum_size = Vector2(0, 18)
	_hud_prompt.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hud_prompt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# 底部操作坞：提示 / 主按钮 / 次要按钮 / 结果行 固定高度、固定间距，
	# 主按钮在所有阶段都停在卷轴底部同一位置（只有上方阶段内容伸缩）。
	_hud_action_dock = VBoxContainer.new()
	_hud_action_dock.name = "ActionDock"
	_hud_action_dock.add_theme_constant_override("separation", 6)
	_console.add_child(_hud_action_dock)
	_hud_action_dock.add_child(_hud_prompt)

	var primary_wrap := Control.new()
	primary_wrap.name = "PrimaryActionWrap"
	# HD 四态底板等比缩到统一 224×56；无论 hover/pressed/disabled 都不改变包围盒。
	primary_wrap.custom_minimum_size = Vector2(224, 56)
	primary_wrap.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_hud_action_dock.add_child(primary_wrap)
	_hud_primary_wrap = primary_wrap
	# 指引牌：下一步在地图上（选目的地 / 行路中）时替代红底按钮，羊皮纸底 + 金色描边。
	_primary_hint_plaque = Panel.new()
	_primary_hint_plaque.name = "PrimaryHintPlaque"
	_primary_hint_plaque.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_primary_hint_plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_primary_hint_plaque.visible = false
	var plaque_box := StyleBoxFlat.new()
	plaque_box.bg_color = Color("F7EDD5")
	plaque_box.border_color = HudStyle.GOLD
	plaque_box.set_border_width_all(2)
	plaque_box.set_corner_radius_all(4)
	plaque_box.shadow_color = Color(0.24, 0.16, 0.1, 0.16)
	plaque_box.shadow_size = 2
	plaque_box.shadow_offset = Vector2(0, 1)
	_primary_hint_plaque.add_theme_stylebox_override("panel", plaque_box)
	primary_wrap.add_child(_primary_hint_plaque)
	_primary_skin = TextureRect.new()
	_primary_skin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_primary_skin.texture = TRADE_PRIMARY_ACTIVE_TEXTURE
	_primary_skin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_primary_skin.stretch_mode = TextureRect.STRETCH_SCALE
	_primary_skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	primary_wrap.add_child(_primary_skin)
	_primary_action = Button.new()
	_primary_action.name = "PrimaryAction"
	_primary_action.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_primary_action.flat = true
	# 键盘由 _unhandled_input 统一处理（空格/回车 = 主按钮）；按钮不抢焦点，避免一次按键触发两次
	_primary_action.focus_mode = Control.FOCUS_NONE
	HudStyle.apply_button(_primary_action)
	_primary_action.add_theme_stylebox_override("normal", _transparent_style())
	_primary_action.add_theme_stylebox_override("hover", _transparent_style())
	_primary_action.add_theme_stylebox_override("pressed", _transparent_style())
	_primary_action.add_theme_stylebox_override("disabled", _transparent_style())
	primary_wrap.add_child(_primary_action)
	_primary_action.mouse_entered.connect(_refresh_primary_skin)
	_primary_action.mouse_exited.connect(_refresh_primary_skin)
	_primary_action.button_down.connect(func():
		if not _primary_action.disabled:
			_primary_skin.texture = TRADE_PRIMARY_PRESSED_TEXTURE
	)
	_primary_action.button_up.connect(_refresh_primary_skin)

	# 次要操作：主按钮下方的一排真按钮（原地停留 / 换乘 / 不交易，结束回合 / 重选），
	# 比主按钮低一级、比旧的小字链接高一级；主按钮不可用时它会被强调。
	var secondary_row := HBoxContainer.new()
	secondary_row.name = "SecondaryActions"
	secondary_row.alignment = BoxContainer.ALIGNMENT_CENTER
	secondary_row.add_theme_constant_override("separation", 8)
	secondary_row.custom_minimum_size = Vector2(224, SECONDARY_BUTTON_H)
	secondary_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_hud_action_dock.add_child(secondary_row)
	_hud_secondary_row = secondary_row
	_secondary_action = _new_secondary_button("SecondaryActionA")
	secondary_row.add_child(_secondary_action)
	_secondary_alt_action = _new_secondary_button("SecondaryActionB")
	secondary_row.add_child(_secondary_alt_action)

	_console_feedback = _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_FOOTER, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	_console_feedback.name = "RoundConsoleFeedback"
	_console_feedback.custom_minimum_size = Vector2(0, 18)
	_console_feedback.autowrap_mode = TextServer.AUTOWRAP_OFF
	# 结果行：本回合最近一条结果（开通商道、交易收据、事件效果）；过长时省略，不撑宽卷轴。
	_console_feedback.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hud_action_dock.add_child(_console_feedback)


func _build_hud_ai_card() -> void:
	_ai_card = Control.new()
	_ai_card.name = "AiMerchantCard"
	_ai_card.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# 高度随有无货物行在 _layout_hud 中切换（有货 106 / 空仓压缩 64）。
	_ai_card.custom_minimum_size = Vector2(250, AI_CARD_HEIGHT_COMPACT)
	_ai_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ai_card)
	move_child(_ai_card, 3)
	var background := TextureRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.texture = HUD_AI_CARD_TEXTURE
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_SCALE
	_ai_card.add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 13)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 10)
	_ai_card.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	margin.add_child(content)
	var header := HBoxContainer.new()
	content.add_child(header)
	_ai_card_name = _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_AI_TITLE, HudStyle.TOPBAR_GOLD_TEXT, HORIZONTAL_ALIGNMENT_LEFT
	)
	_ai_card_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ai_card_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_ai_card_name)
	var silver := TextureRect.new()
	silver.custom_minimum_size = Vector2(25, 23)
	silver.texture = HUD_SILVER_TEXTURE
	silver.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	silver.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	silver.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(silver)
	_ai_card_silver = _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_AI_SILVER, HudStyle.TOPBAR_GOLD_TEXT, HORIZONTAL_ALIGNMENT_RIGHT
	)
	_ai_card_silver.custom_minimum_size = Vector2(30, 0)
	_ai_card_silver.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_ai_card_silver)
	_ai_card_goods = HBoxContainer.new()
	_ai_card_goods.name = "AiCardGoods"
	_ai_card_goods.add_theme_constant_override("separation", 6)
	content.add_child(_ai_card_goods)


func _compute_scroll_width() -> float:
	var available_h := maxf(1.0, size.y - TOPBAR_HEIGHT_PX)
	var desired := available_h * SCROLL_SRC_W / SCROLL_SRC_H
	return clampf(roundf(desired), SCROLL_WIDTH_MIN, SCROLL_WIDTH_MAX)


func _layout_hud() -> void:
	if _hud_topbar == null or _hud_scroll_root == null:
		return
	if _lshu != null:
		_layout_lshu_hud()
		return
	var top_height := TOPBAR_HEIGHT_PX
	_hud_topbar.position = Vector2.ZERO
	_hud_topbar.size = Vector2(size.x, top_height)
	_hud_topbar.z_index = Z_TOPBAR
	# 地图从顶栏下沿开始，不再用 19px 折中把卷轴顶进木梁。
	$RootMargin.add_theme_constant_override("margin_top", int(top_height))
	$RootMargin.add_theme_constant_override("margin_bottom", 0)
	$RootMargin.add_theme_constant_override("margin_left", 0)
	$RootMargin.add_theme_constant_override("margin_right", 0)
	var main_row: HBoxContainer = $RootMargin/RootVBox/MainRow
	main_row.add_theme_constant_override("separation", 0)
	main_row.clip_contents = false
	var side: VBoxContainer = $RootMargin/RootVBox/MainRow/SidePanel
	side.clip_contents = false
	var scroll_w := _compute_scroll_width()
	# SidePanel 不占位：地图全宽铺底，卷轴叠上；透明流苏下仍是地图而非沙色底。
	side.custom_minimum_size = Vector2(0, 0)
	side.size_flags_horizontal = Control.SIZE_SHRINK_END
	%BoardView.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	%BoardView.custom_minimum_size = Vector2(maxf(500.0, size.x), 0)
	%BoardView.z_index = Z_BOARD
	# 内容 fit 排除卷轴纸面（保留 fringe）+ 红匾 24px。
	var right_inset := scroll_w - MAP_UNDER_SCROLL_FRINGE_PX + MAP_SAFE_RIGHT_PAD_PX
	if %BoardView.has_method("set_map_safe_right_inset"):
		%BoardView.set_map_safe_right_inset(right_inset)
	_apply_hud_density()
	# 卷轴：顶栏之下，保持源图比例宽度。
	_hud_scroll_root.position = Vector2(size.x - scroll_w, top_height)
	_hud_scroll_root.size = Vector2(scroll_w, maxf(1.0, size.y - top_height))
	_hud_scroll_root.z_index = Z_SCROLL
	if _hud_scroll_margin != null:
		# 纸面须同时容纳 210 货舱网格与贸易契约列（约 240+）。
		var side_m := int(clampi(roundi((scroll_w - 250.0) * 0.5), 16, 36))
		_hud_scroll_margin.add_theme_constant_override("margin_left", side_m)
		_hud_scroll_margin.add_theme_constant_override("margin_right", side_m)
		_hud_scroll_margin.add_theme_constant_override("margin_top", 80)
		_hud_scroll_margin.add_theme_constant_override("margin_bottom", 64)
	call_deferred("_sync_scroll_to_board")
	var plaque: Control = _hud_topbar.get_node_or_null("ActionPlaque")
	if plaque != null and _hud_current_action != null:
		var font: Font = _hud_current_action.get_theme_font("font")
		var font_size := int(_hud_current_action.get_theme_font_size("font_size"))
		var text_w := 160.0
		if font != null:
			text_w = font.get_string_size(_hud_current_action.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var plaque_w := maxf(232.0, text_w + 32.0)
		plaque.position = Vector2(24.0, 8.0)
		plaque.size = Vector2(plaque_w, 48.0)
		# Label uses full-rect anchors; update margins instead of writing size directly.
		# Direct size writes are overridden by the opposite anchors on the next layout pass.
		_hud_current_action.offset_left = 16.0
		_hud_current_action.offset_right = -16.0
		_hud_current_action.offset_top = 4.0
		_hud_current_action.offset_bottom = -4.0
	if _hud_clock != null:
		_hud_clock.position = Vector2(size.x * 0.5 - 180.0, 0.0)
		_hud_clock.size = Vector2(360.0, top_height)
	var supply_row: HBoxContainer = _hud_topbar.get_node_or_null("SupplyRow")
	if supply_row != null:
		var supply_width := minf(300.0, size.x * 0.42)
		supply_row.position = Vector2(size.x - supply_width - PUBLIC_SILVER_RIGHT_INSET_PX, 0)
		supply_row.size = Vector2(supply_width, top_height)
		if _hud_supply != null:
			_hud_supply.size_flags_horizontal = Control.SIZE_SHRINK_END
	if _hud_scroll_art != null:
		_hud_scroll_art.offset_bottom = 0.0
		_hud_scroll_art.offset_top = 0.0
	if _ai_card != null:
		var ai_h := (
			AI_CARD_HEIGHT_WITH_GOODS
			if _ai_card_goods != null and _ai_card_goods.visible
			else AI_CARD_HEIGHT_COMPACT
		)
		_ai_card.position = Vector2(20, maxf(top_height + 10.0, size.y - ai_h - 14.0))
		_ai_card.size = Vector2(clampf(size.x * 0.20, 220.0, 280.0), ai_h)
		_ai_card.z_index = Z_AI_CARD
	_apply_modal_layer_stack()
	# resize 后阶段显隐也要重新计算；否则从 1280 缩到 1024 时仍保留大屏
	# ActionHeader/210px 契约板，主操作会被推出卷轴底部。
	if _trade_sale_panel != null:
		call_deferred("_refresh_trade_mode_view")


func _sync_scroll_to_board() -> void:
	if _hud_scroll_root == null or _lshu != null:
		return
	var scroll_w := _compute_scroll_width()
	# 强制贴在顶栏下沿，禁止跟随 BoardView 上移进入木梁。
	_hud_scroll_root.position = Vector2(size.x - scroll_w, TOPBAR_HEIGHT_PX)
	_hud_scroll_root.size = Vector2(scroll_w, maxf(1.0, size.y - TOPBAR_HEIGHT_PX))
	_sync_event_overlay_rect()
	_sync_city_lore_rect()


## BoardView 在容器里，容器是延后排的：GameScreen.resized（_layout_hud）时它还是旧尺寸，事件卡、城市图鉴的遮罩
## 按旧地图算，窗口变了大小以后遮罩只盖一半、卡留在旧地方（安卓压力测试 MC-3）。它自己换了尺寸再对一遍
func _on_board_view_resized() -> void:
	_sync_event_overlay_rect()
	_sync_city_lore_rect()
	# Container size settles after GameScreen.resized: recompute against this board.
	if _lshu != null:
		call_deferred("_lshu_push_hud_insets")


func _sync_event_overlay_rect() -> void:
	if not is_inside_tree() or %EventDrawOverlay == null or %BoardView == null:
		return
	# BoardView 为了让地图延伸到卷轴流苏下方而铺满全宽；事件演出只能占用
	# 玩家实际可见的地图纸面，不能把卡背画到右侧卷轴上。
	var board_rect: Rect2 = %BoardView.get_global_rect()
	if _lshu != null:
		board_rect = _lshu_visible_board_rect(board_rect)
	elif _hud_scroll_root != null:
		var visible_right := minf(board_rect.end.x, _hud_scroll_root.global_position.x)
		board_rect.size.x = maxf(1.0, visible_right - board_rect.position.x)
	%EventDrawOverlay.set_map_rect(board_rect)
	# L叔 界面：遮罩照旧盖满地图，卡 / 标题牌 / 「继续」排在上下两排界面之间，字号按界面的 k（复检 UIRES-3）
	if _lshu != null and %EventDrawOverlay.has_method("set_hud_safe_rect"):
		%EventDrawOverlay.set_hud_safe_rect(_lshu.free_band(board_rect), _lshu.k)


func _sync_city_lore_rect() -> void:
	if not is_inside_tree() or %CityLoreCard == null or %BoardView == null:
		return
	var board_rect: Rect2 = %BoardView.get_global_rect()
	if _lshu != null:
		board_rect = _lshu_visible_board_rect(board_rect)
	elif _hud_scroll_root != null:
		var visible_right := minf(board_rect.end.x, _hud_scroll_root.global_position.x)
		board_rect.size.x = maxf(1.0, visible_right - board_rect.position.x)
	%CityLoreCard.set_map_rect(board_rect)


func _apply_modal_layer_stack() -> void:
	## 蒙版用 CanvasLayer 压住地图内 Control 名牌（Node2D 子树会逃逸兄弟 z_index）。
	if %BoardView:
		%BoardView.z_index = Z_BOARD
	if _hud_scroll_root:
		_hud_scroll_root.z_index = Z_SCROLL
	if _ai_card:
		_ai_card.z_index = Z_AI_CARD
	if _hud_topbar:
		_hud_topbar.z_index = Z_TOPBAR
	var event_draw: Control = %EventDrawOverlay
	if event_draw:
		var draw_layer := event_draw.get_parent()
		if draw_layer is CanvasLayer:
			(draw_layer as CanvasLayer).layer = 80
	var city_lore: Control = %CityLoreCard
	if city_lore:
		var lore_layer := city_lore.get_parent()
		if lore_layer is CanvasLayer:
			(lore_layer as CanvasLayer).layer = Z_CITY_LORE
	var event_dialog: Control = %EventDialog
	if event_dialog:
		var event_layer := event_dialog.get_parent()
		if event_layer is CanvasLayer:
			(event_layer as CanvasLayer).layer = Z_EVENT_DIALOG
		else:
			event_dialog.z_index = Z_EVENT_DIALOG
		var ed_center := event_dialog.get_node_or_null("CenterContainer") as Control
		if ed_center:
			ed_center.z_index = 1
	var handover: Control = %HandoverOverlay
	if handover:
		var h_layer := handover.get_parent()
		if h_layer is CanvasLayer:
			(h_layer as CanvasLayer).layer = Z_MODAL_OVERLAY
		else:
			handover.z_index = Z_MODAL_OVERLAY
		var h_center := handover.get_node_or_null("HandoverCenter") as Control
		if h_center:
			h_center.z_index = 1
	var result: Control = %ResultOverlay
	if result:
		var r_layer := result.get_parent()
		if r_layer is CanvasLayer:
			(r_layer as CanvasLayer).layer = Z_MODAL_OVERLAY
		else:
			result.z_index = Z_MODAL_OVERLAY
		var r_center := result.get_node_or_null("ResultCenter") as Control
		if r_center:
			r_center.z_index = 1
	# 保证模态层位于子树末尾。
	for layer_name in ["EventDrawLayer", "EventLayer", "HandoverLayer", "ResultLayer"]:
		var layer := get_node_or_null(layer_name)
		if layer and layer.get_parent() == self:
			move_child(layer, get_child_count() - 1)


func _fit_board_stage_cover() -> void:
	## 已废弃：cover 会裁切地图左右。保留空实现以免旧热重载/调用崩溃。
	pass


func _apply_hud_density() -> void:
	# 四层（船舱 / 行动区 / CTA / 提示）始终由 VBox 管理纵向占位。
	# 仅随高度压缩视觉留白，绝不把次要链接或提示叠在 CTA 上。
	if _hud_scroll_margin == null or _lshu != null:
		return
	var compact := _is_compact_hud()
	# 顶部/底部按卷轴内框的 80/64px 安全线；高度不足时仅压缩动作内容，
	# 不挤压 CTA 或底部提示行。
	_hud_scroll_margin.add_theme_constant_override("margin_top", 80)
	_hud_scroll_margin.add_theme_constant_override("margin_bottom", 64)
	_console.add_theme_constant_override("separation", 12 if not compact else 10)
	_hud_phase_content.add_theme_constant_override("separation", 8)
	_hud_cargo_block.add_theme_constant_override("separation", 8 if not compact else 4)
	# 侧边距由 _layout_hud 按卷轴宽度设置；此处不覆盖。
	_hud_trade_frame.custom_minimum_size.y = (
		TRADE_FRAME_HEIGHT_COMPACT_PX if compact else TRADE_FRAME_HEIGHT_PX
	)
	if compact and _hud_scroll_margin != null:
		_hud_scroll_margin.add_theme_constant_override("margin_top", 56)
		_hud_scroll_margin.add_theme_constant_override("margin_bottom", 40)
	elif _hud_scroll_margin != null:
		_hud_scroll_margin.add_theme_constant_override("margin_top", 72)
		_hud_scroll_margin.add_theme_constant_override("margin_bottom", 56)
	_hud_primary_wrap.custom_minimum_size = Vector2(224.0, 56.0)
	_console_feedback.custom_minimum_size.y = 18.0
	for child in _cargo_grid.get_children():
		if child is Button:
			child.custom_minimum_size = Vector2(CARGO_SLOT_PX, CARGO_SLOT_PX)


func _is_compact_hud() -> bool:
	# 根 Control 会被其内容最小高度顶回 720；真实窗口已经缩到 576 时，单看
	# size.y 会误判为大屏。将窗口物理高度也纳入判断，保证小屏/触控窗口可用。
	var window_h := float(get_window().size.y) if get_window() != null else size.y
	return minf(size.y, window_h) <= 620.0


func _new_hud_page(node_name: String) -> VBoxContainer:
	var page := VBoxContainer.new()
	page.name = node_name
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 5)
	return page


func _hud_styled_label(
	font: Font, font_size: int, color: Color, alignment: HorizontalAlignment
) -> Label:
	var label := Label.new()
	HudStyle.apply_font(label, font, font_size, color)
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _hud_label(font_size: int, color: Color, alignment: HorizontalAlignment) -> Label:
	## 兼容旧调用：按字号选字体家族，并把散落棕色映射到令牌色。
	var font: Font = HudStyle.FONT_BODY_REGULAR
	if font_size >= 24:
		font = HudStyle.FONT_DISPLAY_BOLD
	elif font_size >= 15:
		font = HudStyle.FONT_HEADING_SEMIBOLD
	return _hud_styled_label(font, font_size, _map_hud_text_color(color), alignment)


func _map_hud_text_color(color: Color) -> Color:
	if HudStyle.is_approved_text_color(color):
		return color
	var key := color.to_html(false).to_lower()
	match key:
		"70523a", "72503a", "5d3f2d":
			return HudStyle.INK_WEAK
		"6e3526", "3e2a1e", "2f2a24":
			return HudStyle.INK_STRONG
		"8d2d20", "a54a3f":
			return HudStyle.CINNABAR_TEXT
		"ffe9ad", "ffe9ac", "fff1bd", "f7efd2":
			return HudStyle.TOPBAR_GOLD_TEXT if color.g > 0.85 else HudStyle.PARCHMENT_LIGHT
		"f2e6c9":
			return HudStyle.PARCHMENT_LIGHT
		"c58b32":
			return HudStyle.GOLD
		_:
			# 默认落到正文弱色，避免再引入未批准色。
			return HudStyle.INK_WEAK


func _new_secondary_link(text: String) -> LinkButton:
	var link := LinkButton.new()
	link.text = text
	HudStyle.apply_link(link)
	return link


func _new_secondary_button(node_name: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, SECONDARY_BUTTON_H)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.clip_text = true
	button.visible = false
	_style_secondary_button(button, false)
	return button


## 次要按钮：羊皮纸底 + 墨色描边；emphasis（主按钮不可用、或玩家久未操作时的唯一出路）
## 换朱砂描边与朱砂字，但仍不抢主按钮的红底。
func _style_secondary_button(button: Button, emphasis: bool) -> void:
	if button.has_node("CandySkin"):
		# L叔 糖果按钮：底由 CandySkin 画；强调只换字色
		button.add_theme_color_override("font_color", LshuKit.OCHRE_DEEP if emphasis else LshuKit.INK)
		button.set_meta("emphasis", emphasis)
		return
	var ink := HudStyle.CINNABAR_TEXT if emphasis else HudStyle.INK_STRONG
	var states := {
		"normal": [HudStyle.PARCHMENT_LIGHT, HudStyle.CINNABAR_TEXT if emphasis else HudStyle.INK_WEAK, 2 if emphasis else 1],
		"hover": [Color("FBF3DE"), HudStyle.GOLD, 2],
		"pressed": [Color("E8D7B2"), HudStyle.GOLD, 2],
		"disabled": [Color(HudStyle.PARCHMENT_LIGHT, 0.55), Color(HudStyle.INK_WEAK, 0.45), 1],
	}
	for state in states:
		var spec: Array = states[state]
		var box := StyleBoxFlat.new()
		box.bg_color = spec[0]
		box.border_color = spec[1]
		box.set_border_width_all(int(spec[2]))
		box.set_corner_radius_all(4)
		box.content_margin_left = 8
		box.content_margin_right = 8
		box.content_margin_top = 4
		box.content_margin_bottom = 4
		box.shadow_color = Color(0.24, 0.16, 0.1, 0.18) if state == "normal" else Color.TRANSPARENT
		box.shadow_size = 2 if state == "normal" else 0
		box.shadow_offset = Vector2(0, 1)
		button.add_theme_stylebox_override(state, box)
	HudStyle.apply_font(button, HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_BODY, ink)
	button.add_theme_color_override("font_hover_color", HudStyle.INK_STRONG)
	button.add_theme_color_override("font_pressed_color", HudStyle.INK_STRONG)
	button.add_theme_color_override("font_disabled_color", Color(HudStyle.INK_WEAK, 0.6))
	button.set_meta("emphasis", emphasis)


func _refresh_primary_skin() -> void:
	if _primary_skin == null or _primary_action == null:
		return
	# 禁用态原图与可用态几乎同色（亮度比 1.2:1）：再压暗透明度，一眼能分出「现在点不了」。
	_primary_skin.modulate.a = 0.5 if _primary_action.disabled else 1.0
	if _primary_action.disabled:
		_primary_skin.texture = TRADE_PRIMARY_DISABLED_TEXTURE
	elif _primary_action.button_pressed:
		_primary_skin.texture = TRADE_PRIMARY_PRESSED_TEXTURE
	elif _primary_action.is_hovered():
		_primary_skin.texture = TRADE_PRIMARY_HOVER_TEXTURE
	else:
		_primary_skin.texture = TRADE_PRIMARY_ACTIVE_TEXTURE


func _transparent_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	return style


func _panel_style(fill: Color, stroke: Color, width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = stroke
	style.set_border_width_all(width)
	style.set_corner_radius_all(6)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style


func _new_page(title: String) -> VBoxContainer:
	var page := VBoxContainer.new()
	page.name = "%sPage" % title
	page.add_theme_constant_override("separation", 8)
	var heading := _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_PHASE, HudStyle.INK_STRONG, HORIZONTAL_ALIGNMENT_CENTER
	)
	heading.text = title
	page.add_child(heading)
	return page


func _section_label(text: String) -> Label:
	var label := _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_TRADE_COL, HudStyle.INK_STRONG, HORIZONTAL_ALIGNMENT_CENTER
	)
	label.text = text
	return label


func _build_event_exchange_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = "EventExchangePanel"
	panel.visible = false
	panel.add_theme_constant_override("separation", 5)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var instruction := _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR,
		HudStyle.SIZE_CAPTION,
		HudStyle.INK_WEAK,
		HORIZONTAL_ALIGNMENT_CENTER
	)
	instruction.name = "EventExchangeInstruction"
	instruction.text = "各选择 1 件不同货物，确认前可随时更改"
	instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(instruction)

	var columns := HBoxContainer.new()
	columns.name = "EventExchangeColumns"
	columns.add_theme_constant_override("separation", 6)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(columns)

	var give_column := VBoxContainer.new()
	give_column.name = "EventExchangeGiveColumn"
	give_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	give_column.add_theme_constant_override("separation", 3)
	columns.add_child(give_column)
	var give_heading := _section_label("交出")
	give_heading.name = "EventExchangeGiveHeading"
	give_column.add_child(give_heading)
	var give_scroll := ScrollContainer.new()
	give_scroll.name = "EventExchangeGiveScroll"
	give_scroll.custom_minimum_size = Vector2(0, 112)
	give_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	give_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	give_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	give_column.add_child(give_scroll)
	_event_exchange_give_list = VBoxContainer.new()
	_event_exchange_give_list.name = "EventExchangeGiveList"
	_event_exchange_give_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_event_exchange_give_list.add_theme_constant_override("separation", 3)
	give_scroll.add_child(_event_exchange_give_list)

	var receive_column := VBoxContainer.new()
	receive_column.name = "EventExchangeReceiveColumn"
	receive_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	receive_column.add_theme_constant_override("separation", 3)
	columns.add_child(receive_column)
	var receive_heading := _section_label("获得")
	receive_heading.name = "EventExchangeReceiveHeading"
	receive_column.add_child(receive_heading)
	_event_exchange_target_option = OptionButton.new()
	_event_exchange_target_option.name = "EventExchangeTargetOption"
	_event_exchange_target_option.custom_minimum_size = Vector2(0, 24)
	_event_exchange_target_option.fit_to_longest_item = false
	_event_exchange_target_option.add_theme_font_size_override("font_size", HudStyle.SIZE_CAPTION)
	if HudStyle.FONT_BODY_REGULAR != null:
		_event_exchange_target_option.add_theme_font_override("font", HudStyle.FONT_BODY_REGULAR)
	_event_exchange_target_option.item_selected.connect(_on_event_exchange_target_selected)
	receive_column.add_child(_event_exchange_target_option)
	var receive_scroll := ScrollContainer.new()
	receive_scroll.name = "EventExchangeReceiveScroll"
	receive_scroll.custom_minimum_size = Vector2(0, 84)
	receive_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	receive_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	receive_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	receive_column.add_child(receive_scroll)
	_event_exchange_receive_list = VBoxContainer.new()
	_event_exchange_receive_list.name = "EventExchangeReceiveList"
	_event_exchange_receive_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_event_exchange_receive_list.add_theme_constant_override("separation", 3)
	receive_scroll.add_child(_event_exchange_receive_list)

	_event_exchange_status = _hud_styled_label(
		HudStyle.FONT_BODY_MEDIUM,
		HudStyle.SIZE_CAPTION,
		HudStyle.INK_STRONG,
		HORIZONTAL_ALIGNMENT_CENTER
	)
	_event_exchange_status.name = "EventExchangeStatus"
	_event_exchange_status.custom_minimum_size = Vector2(0, 34)
	_event_exchange_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_event_exchange_status.add_theme_stylebox_override(
		"normal", _panel_style(HudStyle.PARCHMENT_LIGHT, HudStyle.GOLD, 1)
	)
	panel.add_child(_event_exchange_status)
	return panel


func _make_trade_side_selector(is_receive: bool) -> Control:
	## 固定 Tile + 44px 命中面的倍数箭头；滚轮、触控板手势与轻触都可切换资源。
	## 箭头重叠到 Tile 的无交互边缘，保持原稿栏宽，不让 82px 交易列横向膨胀。
	var host := Control.new()
	host.name = "ReceiveSelector" if is_receive else "GiveSelector"
	host.custom_minimum_size = Vector2(TRADE_SIDE_COL_W, TRADE_TILE_H + 36.0)
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	host.focus_mode = Control.FOCUS_ALL
	host.gui_input.connect(func(event: InputEvent): _on_trade_selector_gui_input(event, is_receive))
	var col := VBoxContainer.new()
	col.name = "TradeReceiveGrid" if is_receive else "TradeGiveGrid"
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)
	var row := Control.new()
	row.name = "TileRow"
	row.custom_minimum_size = Vector2(TRADE_SIDE_COL_W, TRADE_TILE_H)
	col.add_child(row)
	var dec := _make_trade_times_arrow("‹", -1)
	dec.name = "ReceiveTimesDec" if is_receive else "GiveTimesDec"
	dec.position = Vector2(-6.0, (TRADE_TILE_H - TRADE_ARROW_HIT_H) * 0.5)
	row.add_child(dec)
	var tile := _make_fixed_trade_tile(is_receive)
	tile.position = Vector2((TRADE_SIDE_COL_W - TRADE_TILE_W) * 0.5, 0.0)
	row.add_child(tile)
	if is_receive:
		_trade_receive_tile = tile
	else:
		_trade_give_tile = tile
	var inc := _make_trade_times_arrow("›", 1)
	inc.name = "ReceiveTimesInc" if is_receive else "GiveTimesInc"
	inc.position = Vector2(TRADE_SIDE_COL_W - TRADE_ARROW_HIT_PX + 6.0, (TRADE_TILE_H - TRADE_ARROW_HIT_H) * 0.5)
	row.add_child(inc)
	var meta := _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_TRADE_HELD, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	meta.custom_minimum_size = Vector2(TRADE_SIDE_COL_W, 12)
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(meta)
	if is_receive:
		meta.name = "ReceiveMeta"
		_trade_receive_meta = meta
	else:
		meta.name = "HeldCount"
		_trade_give_held = meta
	var hint := _hud_styled_label(
		HudStyle.FONT_BODY_REGULAR, HudStyle.SIZE_CAPTION, HudStyle.INK_WEAK, HORIZONTAL_ALIGNMENT_CENTER
	)
	hint.name = "ReceiveWheelHint" if is_receive else "GiveWheelHint"
	hint.custom_minimum_size = Vector2(TRADE_SIDE_COL_W, 12)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(hint)
	if is_receive:
		_trade_receive_wheel_hint = hint
	else:
		_trade_give_wheel_hint = hint
	return host


func _make_trade_times_arrow(text: String, delta: int) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(TRADE_ARROW_HIT_PX, TRADE_ARROW_HIT_H)
	button.text = text
	button.focus_mode = Control.FOCUS_ALL
	button.flat = true
	button.tooltip_text = "减少交易倍数" if delta < 0 else "增加交易倍数"
	var empty := StyleBoxEmpty.new()
	for style_name in ["normal", "hover", "pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(style_name, empty)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", HudStyle.INK_STRONG)
	button.add_theme_color_override("font_hover_color", HudStyle.CINNABAR_TEXT)
	button.add_theme_color_override("font_pressed_color", HudStyle.CINNABAR_TEXT)
	button.add_theme_color_override("font_disabled_color", Color(HudStyle.INK_WEAK, 0.45))
	if HudStyle.FONT_BODY_REGULAR != null:
		button.add_theme_font_override("font", HudStyle.FONT_BODY_REGULAR)
	button.pressed.connect(func(): _on_trade_times_arrow(delta))
	_trade_times_buttons.append(button)
	return button


func _make_fixed_trade_tile(is_receive: bool) -> Control:
	var tile := Control.new()
	tile.name = "ReceiveTile" if is_receive else "GiveTile"
	tile.custom_minimum_size = Vector2(TRADE_TILE_W, TRADE_TILE_H)
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var plate := TextureRect.new()
	plate.name = "TilePlate"
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 设计稿左右均为方形资源格；selected 仅由独立 glow 表达，禁止替换为竖长 reward 贴图。
	plate.texture = TRADE_CARGO_NORMAL_TEXTURE
	plate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	plate.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(plate)
	var glow := TextureRect.new()
	glow.name = "SelectedGlow"
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.texture = TRADE_SELECTED_GLOW_TEXTURE
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.visible = false
	tile.add_child(glow)
	var icon := TextureRect.new()
	icon.name = "ResourceIcon"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size = Vector2(28, 28)
	icon.position = Vector2((TRADE_TILE_W - 28.0) * 0.5, 7.0)
	tile.add_child(icon)
	var quantity := _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_TRADE_QTY, HudStyle.CINNABAR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	quantity.name = "Quantity"
	quantity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	quantity.clip_text = true
	quantity.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	quantity.offset_left = -19.0
	quantity.offset_right = -4.0
	quantity.offset_top = -17.0
	quantity.offset_bottom = -3.0
	quantity.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tile.add_child(quantity)
	return tile


func _make_receive_choice_button(slot_index: int) -> Button:
	var button := Button.new()
	button.name = "ReceiveChoice%d" % slot_index
	button.custom_minimum_size = Vector2(TRADE_SIDE_COL_W, TRADE_RECEIVE_CHOICE_H)
	button.focus_mode = Control.FOCUS_ALL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.expand_icon = true
	button.add_theme_constant_override("h_separation", 3)
	button.add_theme_font_size_override("font_size", HudStyle.SIZE_CAPTION)
	if HudStyle.FONT_BODY_MEDIUM != null:
		button.add_theme_font_override("font", HudStyle.FONT_BODY_MEDIUM)
	button.pressed.connect(func(): _on_receive_choice_pressed(slot_index))
	button.visible = false
	return button


func cancel_ai() -> void:
	_lshu_restore_time_scale()
	if _lshu != null:
		_lshu.reset_for_new_match()
	if _fun != null:
		_fun.reset()
	if _ai:
		_ai.cancel()
	if %EventDrawOverlay:
		%EventDrawOverlay.cancel_presentation()
	if %CityLoreCard:
		%CityLoreCard.force_close()
	if %BoardView.has_method("cancel_all_animations"):
		%BoardView.cancel_all_animations()
	_awaiting_turn_ack = false
	_human_input_unlocked = true
	_move_animating = false
	_auto_end_serial += 1
	_auto_end_pending = false
	_auto_proceed_after_move = false


func on_game_started(player_configs: Array, resume_clock: Dictionary = {}) -> void:
	cancel_ai()
	# GameScreen is a persistent child of Main and reaches _ready() on the title page.
	# Re-resolve BoardView now that SetupSystem has installed the selected ruleset.
	if %BoardView.has_method("reload_for_current_game"):
		%BoardView.reload_for_current_game()
	_last_configs = player_configs.duplicate(true)
	_match_elapsed = 0.0
	_clock_shown = -1
	_started_session = GameState.session_generation
	if _lshu != null:
		# 开局页的「对局时长」滑条（正式入口才读本机设置；测试一律默认 20 分钟）
		LshuMatchSettings.load_if_real(get_tree())
		match_time_limit_sec = LshuMatchSettings.limit_sec()
		match_unlimited = LshuMatchSettings.minutes <= 0
	# 读档的时钟要先恢复，再触发下面的回合开始自动存档；否则会先把磁盘改成新局的 0 秒 / 默认局长。
	if resume_clock.is_empty():
		_refresh_match_clock()
	else:
		resume_match_clock(resume_clock)
	_board_selecting = false
	_selected_path = []
	_stay_picked = false
	_last_trade_signature = ""
	_last_sale_signature = ""
	_sale_selection = {}
	_sale_selected_slots = {}
	_event_loss_selected_slots = {}
	_clear_event_exchange_selection()
	_event_exchange_submitting = false
	_trade_panel_mode = TradePanelMode.EXCHANGE
	_trade_context_signature = ""
	_cached_trade_actions = []
	_cached_trade_availability = {}
	_cached_trade_card = {}
	_trade_selector.clear()
	_trade_submitting = false
	_primary_action_guard_serial += 1
	_primary_action_guarded = false
	_selected_give_index = -1
	_selected_receive_index = -1
	_action_log.clear()
	_human_input_unlocked = true
	_awaiting_turn_ack = false
	_turn_result_text = ""
	_idle_sec = 0.0
	_idle_hint_on = false
	_lshu_ai_status.clear()
	lshu_ai_fast = false
	_lshu_discard_mode = false
	_lshu_discard_slots.clear()
	_lshu_last_toast = ""
	_lshu_win_recorded = false
	_lshu_market_sig = ""
	_lshu_last_human_id = ""
	if not GameState.players.is_empty() and GameState.current_player().is_local_human():
		_lshu_last_human_id = GameState.current_player().player_id
	if _lshu != null:
		_lshu.reset_for_new_match()
	# 测试内容提示改由卷轴底部提示承载，避免破坏封板 HUD 顶栏层级。
	%ModeBanner.visible = false
	%EventDrawOverlay.cancel_presentation()
	%CityLoreCard.force_close()
	%EventDialog.visible = false
	%HandoverOverlay.visible = false
	%ResultOverlay.visible = false
	_set_feedback("对局开始，请 %s 掷骰。" % GameState.current_player().display_name, COLOR_INFO)
	_refresh()
	%BoardView.clear_selection()
	%BoardView.queue_redraw()
	if %BoardView.has_method("reset_camera_to_fit"):
		%BoardView.reset_camera_to_fit()
	_sync_event_overlay_rect()
	_sync_city_lore_rect()
	_lshu_autosave_key = ""
	_lshu_autosave()
	_maybe_start_ai()


## 读档接着玩：on_game_started 之后把上一回的计时接回来（开场「加载存档」，lshu_preview_main._on_continue_requested）
func resume_match_clock(clock: Dictionary) -> void:
	if clock.is_empty():
		return
	match_unlimited = bool(clock.get("unlimited", match_unlimited))
	match_time_limit_sec = float(clock.get("limit_sec", match_time_limit_sec))
	_match_elapsed = maxf(0.0, float(clock.get("elapsed", 0.0)))
	_clock_shown = -1
	_refresh_match_clock()


func _on_state_changed() -> void:
	if not visible:
		return
	_refresh()
	_lshu_autosave()
	_maybe_start_ai()


func _process(delta: float) -> void:
	_update_idle(delta / maxf(Engine.time_scale, 0.0001))
	_lshu_push_edge_scroll_state()
	if (match_time_limit_sec <= 0.0 and not match_unlimited) or not visible or GameState.players.is_empty():
		return
	if _started_session != GameState.session_generation:
		return  # 新局还没 on_game_started：秒表还是上一局的，不计时、不判时间到
	if GameState.phase == GameState.Phase.GAME_OVER:
		_refresh_match_clock()
		return
	_match_elapsed += delta / maxf(Engine.time_scale, 0.0001)
	# 公开给 AI「万里商途」估算剩余轮数、给棋盘的日光循环（不参与规则判定）
	GameState.match_elapsed_sec = _match_elapsed
	GameState.match_limit_sec = 0.0 if match_unlimited else match_time_limit_sec
	GameState.match_time_left_sec = INF if match_unlimited else maxf(0.0, match_time_limit_sec - _match_elapsed)
	if not match_unlimited and not GameState.end_triggered and _match_elapsed >= match_time_limit_sec:
		_on_match_time_up()
	_refresh_match_clock()


## 时长用完：触发原版终局。若恰好在新一轮开始、尚无人行动（所有玩家回合数相同），
## 直接结算；否则本轮其余玩家照常行动，最后一位结束回合时由 TurnSystem 结算。
func _on_match_time_up() -> void:
	if not GameState.trigger_time_limit():
		return
	var round_start := (
		GameState.current_player_index == 0
		and GameState.phase == GameState.Phase.ROLL_DIE
		and not EventSystem.has_pending_decision()
		and not _move_animating
		and not _dice_rolling
		and EndgameSystem.should_settle()
	)
	if round_start:
		cancel_ai()
		%HandoverOverlay.visible = false
		EndgameSystem.settle()
		GameState.state_changed.emit()
		_show_result()
		return
	_set_feedback("对局已满 %d 分钟：补齐本轮后结算。" % int(round(match_time_limit_sec / 60.0)), COLOR_INFO)
	_refresh()


func _refresh_match_clock() -> void:
	if _hud_clock == null:
		return
	_hud_clock.visible = match_time_limit_sec > 0.0 or (match_unlimited and _lshu != null)
	if match_unlimited and _lshu != null and GameState.phase != GameState.Phase.GAME_OVER and not GameState.end_triggered:
		# 不限时：右上角写已经玩了多久
		var played := int(_match_elapsed)
		if played != _clock_shown:
			_clock_shown = played
			_hud_clock.text = "已玩 %d:%02d" % [played / 60, played % 60]
			_hud_clock.add_theme_font_size_override("font_size", 25)
			_hud_clock.tooltip_text = "这局不限时：公共银库拿空后补完这一轮就结算"
		_hud_clock.modulate.a = 1.0
		return
	if GameState.end_reason == "TIME" or (GameState.end_triggered and GameState.phase != GameState.Phase.GAME_OVER):
		_hud_clock.text = "本轮结束后结算" if GameState.phase != GameState.Phase.GAME_OVER else "对局结束"
		if _lshu != null:
			# 右上胶囊只放得下四个字：钟面图标旁写「最后一轮」
			_hud_clock.text = "最后一轮" if GameState.phase != GameState.Phase.GAME_OVER else "结束"
			_hud_clock.add_theme_font_size_override("font_size", 28)
		_hud_clock.modulate.a = 1.0
		return
	if GameState.phase == GameState.Phase.GAME_OVER:
		_hud_clock.text = "对局结束" if _lshu == null else "结束"
		_hud_clock.modulate.a = 1.0
		return
	var left := maxi(0, int(ceil(match_time_limit_sec - _match_elapsed)))
	if left != _clock_shown:
		_clock_shown = left
		_hud_clock.text = ("对局剩余 %d:%02d" if _lshu == null else "%d:%02d") % [left / 60, left % 60]
		if _lshu != null:
			_hud_clock.add_theme_font_size_override("font_size", 36)
	# 最后两分钟轻轻闪烁提醒
	_hud_clock.modulate.a = (0.55 + 0.45 * absf(cos(_match_elapsed * PI))) if left <= 120 else 1.0


## 玩家该操作却迟迟不动（IDLE_HINT_SEC）：提示行转朱砂色，下一步的按钮 / 指引牌开始呼吸（1.2 s 周期）。
func _update_idle(real_delta: float) -> void:
	if not visible or GameState.players.is_empty() or _primary_action == null:
		return
	var key := "%d|%d|%d|%s|%d|%s" % [
		GameState.round_index, GameState.current_player_index, GameState.phase,
		str(_move_animating), _selected_path.size() + (100 if _stay_picked else 0), str(_auto_end_pending),
	]
	var waiting := (
		GameState.phase != GameState.Phase.GAME_OVER
		and not GameState.current_player().is_ai()
		and not _auto_end_pending
		and _can_accept_human()
	)
	if key != _idle_key or not waiting:
		_idle_key = key
		_reset_idle()
		return
	_idle_sec += real_delta
	if not _idle_hint_on and _idle_sec >= IDLE_HINT_SEC:
		_idle_hint_on = true
		_refresh_round_console()
	if _idle_hint_on:
		var target := _idle_pulse_target()
		var k := 0.5 + 0.5 * sin(_idle_sec * TAU / 1.2)
		for c in [_hud_primary_wrap, _secondary_action, _secondary_alt_action]:
			if c != null:
				(c as CanvasItem).modulate = Color(1, 1, 1).lerp(Color(1.18, 1.1, 0.95), k) if c == target else Color.WHITE


## 防连点的范围：旧卷轴是整个操作坞；L叔 界面是右下的主按钮 + 次要按钮
func _dock_click_rect() -> Rect2:
	if _lshu == null:
		return _hud_action_dock.get_global_rect()
	return _hud_primary_wrap.get_global_rect().merge(_hud_secondary_row.get_global_rect())


func _block_dock_clicks() -> void:
	_dock_block_until_ms = Time.get_ticks_msec() + int(DOCK_CLICK_BLOCK_SEC * 1000.0)


func _reset_idle() -> void:
	_idle_sec = 0.0
	if not _idle_hint_on:
		return
	_idle_hint_on = false
	for c in [_hud_primary_wrap, _secondary_action, _secondary_alt_action]:
		if c != null:
			(c as CanvasItem).modulate = Color.WHITE
	_refresh_round_console()


func _idle_pulse_target() -> Control:
	if (
		_lshu != null and GameState.phase == GameState.Phase.TRADE and not GameState.players.is_empty()
		and _trade_possible_here(GameState.current_player()) and _primary_action.disabled
	):
		return null     # 市集里还没选行：不让「不交易」呼吸（复检 TE-2）
	if _hud_primary_wrap != null and _hud_primary_wrap.visible:
		if not _primary_action.disabled or bool(_primary_action.get_meta("hint_mode", false)):
			return _hud_primary_wrap
	for b in [_secondary_action, _secondary_alt_action]:
		if b != null and b.visible and bool(b.get_meta("emphasis", false)):
			return b
	return null


func _apply_idle_emphasis() -> void:
	if _hud_prompt == null:
		return
	if _lshu != null:
		_lshu_style(_hud_prompt, 24, LshuKit.OCHRE_DEEP if _idle_hint_on else LshuKit.INK, "title" if _idle_hint_on else "body")
		return
	HudStyle.apply_font(
		_hud_prompt,
		HudStyle.FONT_HEADING_SEMIBOLD if _idle_hint_on else HudStyle.FONT_BODY_MEDIUM,
		HudStyle.SIZE_BODY,
		HudStyle.CINNABAR_TEXT if _idle_hint_on else HudStyle.INK_STRONG
	)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if (
		event is InputEventMouseButton
		and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
		and Time.get_ticks_msec() < _dock_block_until_ms
		and _hud_action_dock != null
		and _dock_click_rect().has_point(
			get_viewport().get_canvas_transform().affine_inverse() * (event as InputEventMouseButton).position
		)
	):
		get_viewport().set_input_as_handled()
		return
	var active := (
		(event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
		or (event is InputEventKey and (event as InputEventKey).pressed)
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
		or (event is InputEventMouseMotion and (event as InputEventMouseMotion).relative.length() > 3.0)
	)
	if active and (_idle_sec > 0.0 or _idle_hint_on):
		_reset_idle()


## 空格 / 回车 = 按下当前主按钮（只在它可见、可用、且不是指引牌时）。
func _unhandled_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode != KEY_SPACE and key_event.keycode != KEY_ENTER and key_event.keycode != KEY_KP_ENTER:
		return
	if %ResultOverlay.visible or %EventDrawOverlay.visible or _primary_action == null:
		return
	if %CityLoreCard != null and %CityLoreCard.has_method("is_open") and %CityLoreCard.is_open():
		return
	if not _primary_action.is_visible_in_tree() or _primary_action.disabled:
		return
	if bool(_primary_action.get_meta("hint_mode", false)):
		return
	# 有按钮持有键盘焦点（交易倍数箭头、买入候选等）时，空格/回车归它：BaseButton 在按下时
	# 不吞事件、松开时才触发，这里再按主按钮就成了一次按键两次动作
	var focus := get_viewport().gui_get_focus_owner()
	if focus is BaseButton and (focus as Control).is_visible_in_tree() and not (focus as BaseButton).disabled:
		return
	if focus != null:
		focus.release_focus()           # 焦点停在已禁用的箭头上：空格交还主按钮
	if Time.get_ticks_msec() < _dock_block_until_ms:
		get_viewport().set_input_as_handled()
		return
	get_viewport().set_input_as_handled()
	_on_primary_action_pressed()


## AI 回合结束后的「轮到你了」：地图上方一条不挡操作的朱砂横幅，淡入—停留—淡出。
func _show_turn_toast(text: String) -> void:
	if _turn_toast == null:
		_turn_toast = PanelContainer.new()
		_turn_toast.name = "TurnToast"
		_turn_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_turn_toast.z_index = Z_TOPBAR - 5
		var box := StyleBoxFlat.new()
		box.bg_color = Color(HudStyle.CINNABAR_TEXT, 0.94)
		box.border_color = HudStyle.GOLD
		box.set_border_width_all(2)
		box.set_corner_radius_all(4)
		box.content_margin_left = 28
		box.content_margin_right = 28
		box.content_margin_top = 8
		box.content_margin_bottom = 8
		box.shadow_color = Color(0.1, 0.05, 0.02, 0.35)
		box.shadow_size = 6
		box.shadow_offset = Vector2(0, 2)
		_turn_toast.add_theme_stylebox_override("panel", box)
		_turn_toast_label = _hud_styled_label(
			HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_ACTION_HEADING, HudStyle.PARCHMENT_LIGHT, HORIZONTAL_ALIGNMENT_CENTER
		)
		_turn_toast_label.name = "TurnToastLabel"
		_turn_toast.add_child(_turn_toast_label)
		add_child(_turn_toast)
	if _lshu != null and not _turn_toast.has_meta("lshu"):
		# L叔 界面：奶油色胶囊 + 驼色描边 + 墨色圆体字，和回合牌同一套
		_turn_toast.set_meta("lshu", true)
		var lbox := StyleBoxFlat.new()
		lbox.bg_color = LshuKit.CREAM
		lbox.border_color = LshuKit.CAMEL
		lbox.set_border_width_all(4)
		lbox.set_corner_radius_all(40)
		lbox.content_margin_left = 40
		lbox.content_margin_right = 40
		lbox.content_margin_top = 10
		lbox.content_margin_bottom = 12
		lbox.shadow_color = Color(0.3, 0.18, 0.08, 0.25)
		lbox.shadow_size = 8
		lbox.shadow_offset = Vector2(0, 3)
		_turn_toast.add_theme_stylebox_override("panel", lbox)
		_lshu_style(_turn_toast_label, 24, LshuKit.INK, "title")
	_turn_toast_label.text = text
	_turn_toast.visible = true
	_turn_toast.reset_size()
	var map_w := size.x - _compute_scroll_width() if _lshu == null else size.x
	if _lshu != null:
		# 宽度封顶、长话折行，整条留在屏幕里（复检 TE-4）
		_turn_toast_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		_turn_toast_label.custom_minimum_size = Vector2.ZERO
		var cap := size.x * 0.5
		var font := _turn_toast_label.get_theme_font("font")
		var fpx := _turn_toast_label.get_theme_font_size("font_size")
		if font != null and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fpx).x > cap:
			_turn_toast_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
			_turn_toast_label.custom_minimum_size = Vector2(cap, 0)
		_turn_toast.reset_size()
	var toast_y := TOPBAR_HEIGHT_PX + 18.0 if _lshu == null else (LshuMatchHudScript.TC_SIZE.y + 30.0) * _lshu.k
	_turn_toast.position = Vector2(
		maxf(12.0, roundf((map_w - _turn_toast.get_combined_minimum_size().x) * 0.5)), toast_y
	)
	if _turn_toast_tween != null and _turn_toast_tween.is_valid():
		_turn_toast_tween.kill()
	_turn_toast.modulate.a = 0.0
	_turn_toast_tween = create_tween()
	_turn_toast_tween.tween_property(_turn_toast, "modulate:a", 1.0, 0.2)
	_turn_toast_tween.tween_interval(TURN_TOAST_SEC)
	_turn_toast_tween.tween_property(_turn_toast, "modulate:a", 0.0, 0.4)
	_turn_toast_tween.tween_callback(func() -> void: _turn_toast.visible = false)


func _maybe_start_ai() -> void:
	if not visible:
		return
	if not _board_assets_ready():
		if _ai != null:
			_ai.cancel()
		return
	if GameState.phase == GameState.Phase.GAME_OVER:
		return
	if GameState.players.is_empty():
		return
	if _started_session != GameState.session_generation:
		return  # 新局还在加载页底下：等 on_game_started 再让电脑走（不然开局时被 cancel_ai 打断重来）
	if GameState.current_player().is_ai() and not _ai.is_running():
		_human_input_unlocked = false
		%HandoverOverlay.visible = false
		_ai.start_if_needed()


func _on_ai_status(text: String) -> void:
	if not GameState.players.is_empty() and GameState.current_player().is_ai():
		# 对手小卡的气泡只要一句短话：去掉名字前缀
		var who := GameState.current_player().display_name
		_lshu_ai_status[GameState.current_player().player_id] = text.trim_prefix(who).trim_prefix("：").trim_suffix("……").trim_suffix("。")
	_set_feedback(text, COLOR_INFO)
	_refresh_action_buttons()


func _on_ai_turn_finished() -> void:
	_fun.release_hold()
	_refresh()
	if GameState.phase == GameState.Phase.GAME_OVER:
		_show_result()
		return
	if QuerySystem.current_is_human():
		# 对电脑的 1v1 不需要「交接设备」：不再弹模态「已交接，继续」，只给一条不挡操作的提示，
		# 并短暂锁住主按钮，免得 AI 回合里的连点被当成「掷骰」。
		# 同屏两位以上真人时，轮到另一位真人则先亮换人卡（L叔 界面）。
		%CityLoreCard.force_close()
		%HandoverOverlay.visible = false
		_awaiting_turn_ack = false
		_human_input_unlocked = true
		_turn_result_text = ""
		_idle_sec = 0.0
		var next := GameState.current_player()
		if not _lshu_maybe_handover(next):
			var who := "你" if _lshu_human_count() <= 1 else next.display_name
			_show_turn_toast("轮到%s了" % who)
			_block_dock_clicks()
			_set_feedback("轮到%s了：掷骰开始本回合" % who, COLOR_INFO)
			_arm_primary_action_guard()
		_refresh_move_selection()
	_refresh_action_buttons()
	# 连续几位电脑：上一位收尾时控制器还在运行，state_changed 里的启动被跳过，这里接上下一位
	if QuerySystem.current_is_ai():
		call_deferred("_maybe_start_ai")


func _on_ai_blocked(reason: String) -> void:
	_set_feedback(reason, COLOR_FAILURE)
	_refresh_action_buttons()


func _on_handover_ack() -> void:
	%HandoverOverlay.visible = false
	_awaiting_turn_ack = false
	_human_input_unlocked = true
	_refresh_action_buttons()
	_refresh_move_selection()


func _board_assets_ready() -> bool:
	return not %BoardView.has_method("is_ready_for_play") or %BoardView.is_ready_for_play()


func _can_accept_human() -> bool:
	if not _board_assets_ready():
		return false
	return (
		_human_input_unlocked
		and not _awaiting_turn_ack
		and not _move_animating
		and not _primary_action_guarded
		and not _ai.is_running()
		and QuerySystem.accepts_human_input()
	)


# ---------- 命令 ----------

func _on_primary_action_pressed() -> void:
	# The same physical CTA is reused across phases.  A rapid second click after
	# a successful trade must not be reinterpreted as END_TURN and silently hand
	# control to the AI.
	if _primary_action_guarded:
		return
	if _lshu_discard_mode:
		_lshu_confirm_discard()
		return
	if _fun.owns_primary():
		_fun.confirm()
		return
	if _is_pending_event_exchange():
		_on_confirm_event_exchange_pressed()
		return
	if _is_pending_loss_decision():
		_on_confirm_event_loss_pressed()
		return
	match GameState.phase:
		GameState.Phase.ROLL_DIE:
			_on_roll_pressed()
		GameState.Phase.MOVE_OR_EVENT:
			var player := GameState.current_player()
			if player.move_confirmed or (DiceSystem.is_event_face(player.die_result) and not player.pending_event_needs_move):
				_on_proceed_pressed()
			else:
				_on_confirm_move_pressed()
		GameState.Phase.OPEN_TRADE_ROUTE:
			_on_proceed_pressed()
		GameState.Phase.TRADE:
			if not _trade_possible_here(GameState.current_player()):
				_on_skip_and_end_pressed()
			elif _skip_end_pick_active():
				_on_skip_and_end_pressed()          # 安卓触屏：先选了「不交易，结束回合」，这是确认（TS-2）
			elif _lshu != null and not _lshu_row_picked and _trade_panel_mode != TradePanelMode.DIRECT_SALE:
				# 还没点过任何一行：不按默认选项成交（防误触的第二道闸，按钮本身也是灰的）
				return
			elif _trade_panel_mode == TradePanelMode.DIRECT_SALE:
				_on_sale_pressed()
			else:
				_on_confirm_trade_pressed()
		GameState.Phase.END_TURN:
			_on_end_turn_pressed()


## 主按钮 / 次要按钮被手指点：防连点的那 0.5 秒（_block_dock_clicks）在这里也拦一道。
## _input 只吞得掉手指模拟出来的鼠标那一半；按钮还会从原始的 InputEventScreenTouch 自己按下去（任何一根手指都行），
## 所以光在 _input 里吞鼠标事件，安卓上这道闸等于没有（安卓压力测试 TS-1）。只拦手指按的（PadInput 记着这一下是不是触屏）：
## 桌面没有触屏，鼠标在这 0.5 秒里的按下 / 抬起照旧被 _input 吞掉，和以前一样。键盘、手柄、托盘骰子各自已经查过。
## 系统取消的触摸（安卓 ACTION_CANCEL：手掌误触、拉通知栏）松开时不算点（TS-3，只在安卓上有）
func _on_primary_button_pressed() -> void:
	if _touch_press_blocked(_primary_action) or PadInputLayer.canceled_press(self):
		return
	_on_primary_action_pressed()


func _on_secondary_action_pressed() -> void:
	_on_secondary_button_pressed(_secondary_action)


func _on_secondary_alt_pressed() -> void:
	_on_secondary_button_pressed(_secondary_alt_action)


func _on_secondary_button_pressed(button: Button) -> void:
	if _touch_press_blocked(button) or PadInputLayer.canceled_press(self):
		return
	# 安卓（触屏防误触开着）：有交易能做时「不交易，结束回合」点一下只是选中，主按钮变成「不交易，结束回合」，
	# 按主按钮才算（和「原地停留 → 就停在这里」一样；孩子乱点不会一下放弃这回合的交易，TS-2）。
	# 手柄走 _run_secondary_action（焦点框框住再按 A，本来就是两步），不经过这里
	if (
		button != null and button.visible and String(button.get_meta("action", "")) == "skip_end"
		and PadInputLayer.guards_on(self) and _lshu != null
		and GameState.phase == GameState.Phase.TRADE and _trade_possible_here(GameState.current_player())
	):
		_pick_skip_end()
		return
	_run_secondary_action(button)


## 手指在防连点的 0.5 秒里按到了操作坞的按钮
func _touch_blocked() -> bool:
	return Time.get_ticks_msec() < _dock_block_until_ms and PadInputLayer.touch_press(self)


## 操作坞按钮被按下（还没抬起）：记下这一下是不是手指在防连点的 0.5 秒里按的。按钮 id -> bool
var _dock_touch_down_blocked := {}


func _on_dock_button_down(button: Button) -> void:
	_dock_touch_down_blocked[button.get_instance_id()] = _touch_blocked()


## 这一下手指点（按钮的 pressed 里问）不算：抬起时还在 0.5 秒里，或者按下时在 0.5 秒里、窗口过了才抬起。
## 鼠标在窗口里按下会被 _input 吞掉，那一下永远成不了点击；手指的原始 ScreenTouch 按下照样到按钮，
## 只在抬起时查窗口，孩子在窗口快结束时点下去、刚过窗口抬起（一下普通的点，150 毫秒）就漏过去了（复核 TS-1）
func _touch_press_blocked(button: Button) -> bool:
	if _touch_blocked():
		return true
	return (
		button != null and PadInputLayer.touch_press(self)
		and bool(_dock_touch_down_blocked.get(button.get_instance_id(), false))
	)


## 「不交易，结束回合」选中了（安卓触屏；只在这一局、这一轮、这一位、这一处市集有效：下一回合停在同一座城也不会预先选好）
func _skip_end_pick_active() -> bool:
	return (
		_skip_end_picked_ctx != "" and GameState.phase == GameState.Phase.TRADE and not GameState.players.is_empty()
		and not GameState.current_player().is_ai() and _skip_end_picked_ctx == _skip_end_key()
	)


func _skip_end_key() -> String:
	return "%d|%d|%d|%s" % [GameState.session_generation, GameState.round_index, GameState.current_player_index, _trade_context_signature]


func _pick_skip_end() -> void:
	if not _can_accept_human():
		return
	# 选了「不交易」：市集里已经选中的那一行 / 勾上的货放下（主按钮只写一件事）
	_lshu_row_picked = false
	_sale_selected_slots.clear()
	_sale_selection.clear()
	_skip_end_picked_ctx = _skip_end_key()
	_update_trade_preview_and_buttons()
	_refresh_action_buttons()


func _run_secondary_action(button: Button) -> void:
	if button == null or not button.visible:
		return
	match String(button.get_meta("action", "")):
		"reselect_exchange":
			_clear_event_exchange_selection()
			_sync_event_exchange_panel()
			_refresh_cargo_slot_visuals()
			_set_feedback(_event_exchange_prompt(), COLOR_INFO)
			_refresh_action_buttons()
		"stay":
			_on_stay_picked()
		"switch":
			_on_switch_pressed()
		"skip_end":
			_on_skip_and_end_pressed()
		"discard_cancel":
			_lshu_discard_mode = false
			_lshu_discard_slots.clear()
			_refresh_cargo_slot_visuals()
			_refresh_round_console()
		"ai_fast":
			if Time.get_ticks_msec() - _lshu_fast_toggled_ms < 350:
				return
			_lshu_fast_toggled_ms = Time.get_ticks_msec()
			lshu_ai_fast = not lshu_ai_fast
			_lshu_apply_ai_speed()
			_refresh_round_console()


func _set_trade_panel_mode(mode: int) -> void:
	if GameState.phase != GameState.Phase.TRADE or _trade_submitting:
		return
	if _trade_panel_mode == mode:
		_paint_trade_mode_bar()
		return
	_trade_panel_mode = mode
	_sale_selected_slots.clear()
	_sale_selection.clear()
	_reload_trade_selector_for_mode()
	_refresh_trade_mode_view()
	_refresh_sale_action_state()
	_refresh_action_buttons()

func _on_roll_pressed() -> void:
	if not _can_accept_human():
		return
	if _dice_rolling or (_dice_3d != null and _dice_3d.is_rolling()):
		return
	_human_input_unlocked = false
	_dice_rolling = true
	_turn_result_text = ""
	_fun.on_human_rolled(GameState.current_player().player_id)
	var roll_session := GameState.session_generation
	_refresh_action_buttons()
	# 先确定规则结果（只消耗一次 RNG），再播 3D，再注入提交——避免阶段刷新藏起掷骰页。
	var target_face: Variant = DiceSystem.roll()
	AudioManager.play_dice_roll()
	if _dice_3d != null:
		_dice_3d.roll_to_face(target_face)
		# 仅在真实进入 rolling 时 await，避免 fallback 同步结束后永久卡死
		if _dice_3d.is_rolling():
			await _dice_3d.roll_finished
	else:
		await _play_dice_roll_animation()
	_dice_rolling = false
	if GameState.session_generation != roll_session or GameState.players.is_empty():
		return      # 掷骰动画中途回了开场 / 开了新局：这次掷骰作废（复检 MS-5）
	AudioManager.play_dice_land()
	_human_input_unlocked = true
	var result := TurnSystem.roll_die(target_face)
	if not result["success"]:
		_set_feedback(result["message"], COLOR_FAILURE)
		_refresh_action_buttons()
		return
	_set_feedback(result["message"], COLOR_INFO)
	if _dice_face:
		_dice_face.text = _dice_symbol(target_face)
	var event: Dictionary = result.get("event", {})
	# Presentation order: blocked before triggered (mirror AI). RULE_BLOCKED must not open overlay.
	if event.get("blocked", false):
		_set_feedback(event["effect_message"], COLOR_FAILURE)
		_refresh_move_selection()
		_refresh_action_buttons()
	elif event.get("triggered", false):
		%CityLoreCard.force_close()
		_human_input_unlocked = false
		_board_selecting = false
		%BoardView.set_input_enabled(false)
		_fun.on_human_event(event)
		_sync_event_overlay_rect()
		%EventDrawOverlay.show_human_event(event)
		# 掷骰那一下的刷新已经把目的地光圈和按钮摆出来了：演出开始后收掉（复检 NOV-2）
		_refresh_move_selection()
		_refresh_action_buttons()
		_refresh_round_console()
	else:
		_refresh_move_selection()
		_refresh_action_buttons()


## 真人正在看抽事件卡的演出（卡在翻 / 等着点「继续」）
func _human_event_presenting() -> bool:
	var ov := %EventDrawOverlay as EventDrawOverlay
	return (
		ov != null and ov.visible and ov.state != EventDrawOverlay.PresentationState.HIDDEN
		and not GameState.players.is_empty() and not GameState.current_player().is_ai()
	)


func _event_card_revealed() -> bool:
	return (%EventDrawOverlay as EventDrawOverlay).state == EventDrawOverlay.PresentationState.REVEALED


func _on_event_presentation_finished(event: Dictionary) -> void:
	# AI 演出由 AITurnController 的等待时长串行推进，不解锁真人输入。
	if GameState.players.is_empty() or GameState.current_player().is_ai():
		return
	_human_input_unlocked = true
	_fun.on_human_presentation_finished(event)
	if _is_pending_event_exchange():
		_clear_event_exchange_selection()
		_set_feedback(_event_exchange_prompt(), COLOR_INFO)
	elif _is_pending_loss_decision():
		_event_loss_selected_slots.clear()
		_fun.clear_loss_hint()
		_set_feedback(_event_loss_prompt(), COLOR_INFO)
	elif _fun.owns_primary():
		_set_feedback(_fun.prompt(), COLOR_INFO)
	else:
		var effect := String(event.get("effect_message", "事件已结算。"))
		_turn_result_text = effect
		_set_feedback(effect, COLOR_INFO)
	_refresh()
	_refresh_move_selection()
	_refresh_action_buttons()
	_after_human_move_settled()


func _play_dice_roll_animation() -> void:
	if _dice_face == null:
		return
	var symbols := ["⚀", "⚃", "⚁", "⚄", "⚂", "⚅"]
	for i in 7:
		_dice_face.text = symbols[i % symbols.size()]
		_dice_face.rotation_degrees = -5.0 if i % 2 == 0 else 5.0
		_dice_face.scale = Vector2(0.92, 0.92) if i % 2 == 0 else Vector2(1.08, 1.08)
		await get_tree().create_timer(0.045).timeout
	_dice_face.rotation_degrees = 0.0
	_dice_face.scale = Vector2.ONE


## 旧的「原地停留」按钮（%StayButton，界面上早已藏起，只留信号 / 测试契约）：直接提交原地停留。
## 玩家能点到的「原地停留」是次要按钮，走 _on_stay_picked（只选中）。
func _on_stay_pressed() -> void:
	if not _can_accept_human():
		return
	_submit_move([])


## 次要按钮「原地停留」：只选中「留在这里」（棋盘上自己脚下亮成选中），主按钮变成「就停在这里」，按它才算数。
## 再点一次仍是选中；之后点地图上别的地方就改选那里。
func _on_stay_picked() -> void:
	if not _can_accept_human() or not _move_pick_open():
		return
	_selected_path = []
	_stay_picked = true
	_show_move_pick()
	_refresh_action_buttons()


## 主按钮「出发（N 步）」/「就停在这里」：提交选中的那一项。什么都没选时什么也不做（主按钮这时是指引牌）。
func _on_confirm_move_pressed() -> void:
	if not _can_accept_human():
		return
	if _stay_picked:
		_submit_move([])
	elif not _selected_path.is_empty():
		_submit_move(_selected_path)


## 当前真人正在选目的地（还没走、没有待决事件）
func _move_pick_open() -> bool:
	if GameState.players.is_empty() or GameState.phase != GameState.Phase.MOVE_OR_EVENT:
		return false
	var player := GameState.current_player()
	if player.is_ai() or player.move_confirmed or EventSystem.has_pending_decision():
		return false
	return not DiceSystem.is_event_face(player.die_result) or player.pending_event_needs_move


func _move_pick_made() -> bool:
	return _stay_picked or not _selected_path.is_empty()


func _clear_move_pick() -> void:
	_selected_path = []
	_stay_picked = false


## 把选中的那一项画到棋盘上：目的地 = 路线 + 选中标记；原地停留 = 自己脚下的「原地」标记亮成选中
func _show_move_pick() -> void:
	if _stay_picked and not GameState.players.is_empty():
		%BoardView.set_selected_path([GameState.current_player().current_node_id])
	else:
		%BoardView.set_selected_path(_selected_path)


func _submit_move(path: Array) -> void:
	var result := TurnSystem.confirm_move(path)
	_set_feedback(result["message"], COLOR_SUCCESS if result["success"] else COLOR_FAILURE)
	if result["success"]:
		_block_dock_clicks()
		_board_selecting = false
		_clear_move_pick()
		%BoardView.clear_selection()
		var visual: Dictionary = result.get("visual_move", {})
		if not visual.is_empty() and int(visual.get("steps", 0)) > 0:
			_move_animating = true
			# 只有玩家自己的移动在落定后自动 proceed；AI 与换乘动画同样会发 move_animation_finished
			_auto_proceed_after_move = true
			_refresh_action_buttons()
			%BoardView.play_visual_move(visual)
		else:
			_move_animating = false
			_after_human_move_settled()


func _on_move_animation_finished(_player_id: String) -> void:
	_move_animating = false
	var chain := _auto_proceed_after_move
	_auto_proceed_after_move = false
	if chain:
		# 自己走完落地：大按钮先挡一小会儿。港口（海陆交叉点）落地时它马上变成「进入贸易」，
		# 走路那两三秒一直在狂点的孩子会一下按进市集、跳过换乘（2026-09-27 复查「先选再确认」）
		_block_dock_clicks()
		_arm_primary_action_guard()
	_refresh_action_buttons()
	_refresh_move_selection()
	if chain:
		_after_human_move_settled()


func _on_switch_pressed() -> void:
	if not _can_accept_human():
		return
	var player := GameState.current_player()
	var player_id := player.player_id
	var old_transport := player.active_transport
	var result := TurnSystem.switch_transport()
	_set_feedback(result["message"], COLOR_SUCCESS if result["success"] else COLOR_FAILURE)
	if result["success"]:
		# 换乘后能去的地方和路线都变了：之前选中的目的地 / 原地停留作废，重新选
		_clear_move_pick()
		%BoardView.set_selected_path([])
		_move_animating = true
		%BoardView.play_transport_switch_visual(
			player_id,
			old_transport,
			player.active_transport
		)
		_refresh_move_selection()


func _on_proceed_pressed() -> void:
	if not _can_accept_human():
		return
	_proceed_now()


func _proceed_now() -> void:
	var result := TurnSystem.proceed()
	_set_feedback(result["message"], COLOR_SUCCESS if result["success"] else COLOR_FAILURE)
	if not result["success"]:
		return
	_block_dock_clicks()
	if bool(result.get("opened", false)):
		_turn_result_text = String(result["message"])
	_after_trade_phase_entered()


## 移动 / 事件落定：没有待决事件、无需再走时，自动做原来「继续」那一步（TurnSystem.proceed）。
## 海陆交叉点例外：规则允许到港后换乘（会决定下回合抽陆路还是海路事件），停下让玩家决定。
func _after_human_move_settled() -> void:
	if auto_advance:
		call_deferred("_auto_proceed")


func _auto_proceed() -> void:
	if not auto_advance or not _human_can_auto_advance():
		return
	if GameState.phase != GameState.Phase.MOVE_OR_EVENT or EventSystem.has_pending_decision() or _move_animating:
		return
	var player := GameState.current_player()
	if not _move_phase_done(player) or MovementSystem.can_switch_transport(player):
		return
	_proceed_now()


func _move_phase_done(player: PlayerState) -> bool:
	return player.move_confirmed or (
		player.die_result != null
		and DiceSystem.is_event_face(player.die_result)
		and not player.pending_event_needs_move
	)


## 自动推进只替玩家按「没有选择余地」的键：必须是真人回合、界面未被动画/演出/AI 锁住。
## 与 _can_accept_human() 的差别只在于忽略主按钮的 0.25 s 防连点锁。
func _human_can_auto_advance() -> bool:
	if GameState.players.is_empty() or GameState.phase == GameState.Phase.GAME_OVER:
		return false
	if GameState.current_player().is_ai() or not _board_assets_ready():
		return false
	return (
		_human_input_unlocked
		and not _awaiting_turn_ack
		and not _move_animating
		and not _ai.is_running()
		and QuerySystem.accepts_human_input()
	)


## 进入贸易阶段：当前位置没有任何能做的交易（道路、没货也买不起、或已交易）时，
## 唯一的合法出路是跳过贸易，直接替玩家跳过并按节奏结束回合。
func _after_trade_phase_entered() -> void:
	if not auto_advance or GameState.phase != GameState.Phase.TRADE:
		return
	var player := GameState.current_player()
	if player.is_ai() or _trade_possible_here(player):
		return
	var at_city := GameData.is_city_node(GameState.content, player.current_node_id)
	if at_city and _lshu != null:
		# L叔 界面（Carlos 2026-09-26：「到了城市点，进入贸易就自动结束了」）：城市里做不成交易时不再悄悄结束——
		# 照样打开市集面板，写清原因（多半是白银不够、挎包空着），玩家看完点「结束回合」。停在路上仍自动结束。
		_set_feedback(_lshu_no_trade_reason(player), COLOR_INFO)
		_refresh_round_console()
		return
	var reason := "停在路上，这里没有集市" if not at_city else "这里没有做得成的交易"
	var result := TurnSystem.skip_trade()
	if not result["success"]:
		return
	if _turn_result_text.is_empty():
		_turn_result_text = reason
	else:
		_turn_result_text = "%s；%s" % [_turn_result_text, reason]
	_set_feedback(reason + "，本回合结束", COLOR_INFO)
	_schedule_auto_end_turn()


func _trade_possible_here(player: PlayerState) -> bool:
	if player == null or player.trade_action_used:
		return false
	if not GameData.is_city_node(GameState.content, player.current_node_id):
		return false
	if bool(TradeSystem.get_legal_direct_sale(player).get("can_sell", false)):
		return true
	return not TradeSystem.get_legal_ratio_actions(player).is_empty()


func _on_skip_trade_pressed() -> void:
	if not _can_accept_human():
		return
	var result := TurnSystem.skip_trade()
	_set_feedback(result["message"], COLOR_INFO if result["success"] else COLOR_FAILURE)


## 「不交易，结束回合」：skip_trade + end_turn 一次完成（玩家明确选择，不再等节拍）。
func _on_skip_and_end_pressed() -> void:
	if not _can_accept_human():
		return
	if GameState.phase == GameState.Phase.TRADE:
		var result := TurnSystem.skip_trade()
		if not result["success"]:
			_set_feedback(result["message"], COLOR_FAILURE)
			return
	if GameState.phase == GameState.Phase.END_TURN:
		_end_turn_now()


func _on_end_turn_pressed() -> void:
	if not _can_accept_human():
		return
	_end_turn_now()


func _end_turn_now() -> void:
	_auto_end_serial += 1
	_auto_end_pending = false
	_skip_end_picked_ctx = ""
	_block_dock_clicks()
	if not GameState.players.is_empty() and GameState.current_player().is_local_human():
		_fun.on_turn_ended(GameState.current_player().player_id)
	var result := TurnSystem.end_turn()
	if not result["success"]:
		_set_feedback(result["message"], COLOR_FAILURE)
		return
	if result.get("game_over", false):
		_show_result()
	else:
		var next := GameState.current_player()
		if next.is_ai():
			_human_input_unlocked = false
			_set_feedback("%s回合…" % next.display_name, COLOR_INFO)
		else:
			# 同屏两位真人：上一位的连点 / 迟到的空格不能替下一位掷骰
			_set_feedback("轮到%s掷骰" % next.display_name, COLOR_INFO)
			if not _lshu_maybe_handover(next):
				_arm_primary_action_guard()
		_maybe_start_ai()


## 本回合唯一一次交易完成（或自动跳过）后：停一拍让玩家看清结果，再自动结束回合；
## 期间主按钮仍是「结束回合」，点它立刻结束。
func _schedule_auto_end_turn() -> void:
	if not auto_advance or GameState.phase != GameState.Phase.END_TURN or GameState.players.is_empty():
		return
	var player := GameState.current_player()
	if player.is_ai():
		return
	_auto_end_serial += 1
	var serial := _auto_end_serial
	var pid := player.player_id
	_auto_end_pending = true
	_refresh_round_console()
	var timer := get_tree().create_timer(AUTO_END_TURN_DELAY_SEC, true, false, false)
	timer.timeout.connect(
		func() -> void:
			if serial != _auto_end_serial or not is_inside_tree():
				return
			_auto_end_pending = false
			if (
				GameState.players.is_empty()
				or GameState.phase != GameState.Phase.END_TURN
				or GameState.current_player().player_id != pid
				or not _human_can_auto_advance()
				or _lshu_discard_mode
			):
				_refresh_round_console()
				return
			_end_turn_now(),
		CONNECT_ONE_SHOT
	)


func _on_confirm_trade_pressed() -> void:
	_on_exchange_pressed(-1)


func _on_exchange_pressed(_times_arg: int) -> void:
	## times_arg 保留兼容；正式倍数只来自 TradeSelectorModel.times。
	if _trade_submitting or not _can_accept_human():
		return
	var meta := _selected_trade_meta()
	if meta.is_empty():
		var reason := String(_trade_selector.message)
		if reason.is_empty():
			reason = String(_cached_trade_availability.get("message", ""))
		_set_feedback(reason if not reason.is_empty() else "请选择交付与回报。", COLOR_FAILURE)
		return
	var give_index := int(meta["give_index"])
	var receive_index := int(meta["receive_index"])
	var actual_times := int(meta.get("times", _trade_selector.times))
	if actual_times < 1:
		var reason2 := String(_trade_selector.message)
		if reason2.is_empty():
			reason2 = String(_cached_trade_availability.get("message", ""))
		_set_feedback(reason2 if not reason2.is_empty() else "当前没有可完成的兑换。", COLOR_FAILURE)
		return
	_trade_submitting = true
	_primary_action.disabled = true
	_refresh_primary_skin()
	var result := TradeSystem.trade_ratio(give_index, receive_index, actual_times)
	if result["success"]:
		_arm_primary_action_guard()
	_trade_submitting = false
	if result["success"]:
		AudioManager.play_trade_success()
		_block_dock_clicks()
		_turn_result_text = String(result["message"])
	_set_feedback(result["message"], COLOR_SUCCESS if result["success"] else COLOR_FAILURE)
	_refresh()
	if result["success"]:
		_schedule_auto_end_turn()


func _on_sale_pressed() -> void:
	if _trade_submitting or not _can_accept_human() or _trade_panel_mode != TradePanelMode.DIRECT_SALE:
		return
	var selection := _active_sale_selection()
	var quote := TradeSystem.get_direct_sale_quote(GameState.current_player(), selection)
	if not bool(quote.get("can_sell", false)):
		_set_feedback(String(quote.get("message", "请选择要出售的货物。")), COLOR_FAILURE)
		return
	_trade_submitting = true
	_primary_action.disabled = true
	_refresh_primary_skin()
	var result := TradeSystem.trade_direct_sale(selection)
	if result["success"]:
		_arm_primary_action_guard()
	_trade_submitting = false
	if result["success"]:
		AudioManager.play_trade_success()
	_set_feedback(result["message"], COLOR_SUCCESS if result["success"] else COLOR_FAILURE)
	if result["success"]:
		_sale_selection.clear()
		_sale_selected_slots.clear()
		_last_sale_signature = ""
		_block_dock_clicks()
		_turn_result_text = String(result["message"])
	_refresh()
	if result["success"]:
		_schedule_auto_end_turn()


func _arm_primary_action_guard() -> void:
	_primary_action_guard_serial += 1
	var serial := _primary_action_guard_serial
	_primary_action_guarded = true
	if _primary_action != null:
		_primary_action.disabled = true
		_refresh_primary_skin()
	# 至少等到防连点（_block_dock_clicks）结束再亮：以前 0.25 s 就亮了，0.5 s 内那一下却被吞掉，
	# 电脑回合后第一下点「掷骰」没反应（复检 NOV-7）
	var wait := maxf(0.25, float(_dock_block_until_ms - Time.get_ticks_msec()) / 1000.0 + 0.02)
	var timer := get_tree().create_timer(wait, true, false, true)
	timer.timeout.connect(
		func() -> void:
			if serial != _primary_action_guard_serial or not is_inside_tree():
				return
			_primary_action_guarded = false
			_refresh_action_buttons(),
		CONNECT_ONE_SHOT
	)


func _on_discard_pressed() -> void:
	if not _can_accept_human():
		return
	var selection := _active_sale_selection()
	if selection.is_empty():
		_set_feedback("请选择要丢弃的货物。", COLOR_FAILURE)
		return
	var result := TradeSystem.discard_goods(selection)
	_set_feedback(result["message"], COLOR_SUCCESS if result["success"] else COLOR_FAILURE)
	if result["success"]:
		_sale_selection = {}
		_last_sale_signature = ""


func _active_sale_selection() -> Dictionary:
	if GameState.phase == GameState.Phase.TRADE and _trade_panel_mode == TradePanelMode.DIRECT_SALE:
		_rebuild_sale_selection_from_slots()
	var selection := {}
	for good_id in _sale_selection:
		if int(_sale_selection[good_id]) > 0:
			selection[good_id] = _sale_selection[good_id]
	return selection


func _pending_loss_decision() -> Dictionary:
	if not EventSystem.has_pending_decision() or GameState.players.is_empty():
		return {}
	var pending := EventSystem.get_pending_decision()
	if String(pending.get("operation", "")) not in ["LOSE_GOOD", "LOSE_HALF_GOODS_MAX_2"]:
		return {}
	var player := GameState.current_player()
	if not player.is_local_human() or String(pending.get("acting_player_id", "")) != player.player_id:
		return {}
	return pending


func _is_pending_loss_decision() -> bool:
	return not _pending_loss_decision().is_empty()


func _pending_exchange_decision() -> Dictionary:
	if not EventSystem.has_pending_decision() or GameState.players.is_empty():
		return {}
	var pending := EventSystem.get_pending_decision()
	if String(pending.get("operation", "")) != "EXCHANGE_ONE_GOOD":
		return {}
	var player := GameState.current_player()
	if not player.is_local_human() or String(pending.get("acting_player_id", "")) != player.player_id:
		return {}
	return pending


func _is_pending_event_exchange() -> bool:
	return not _pending_exchange_decision().is_empty()


func _clear_event_exchange_selection() -> void:
	_event_exchange_give_good = ""
	_event_exchange_target = ""
	_event_exchange_receive_good = ""


func _event_exchange_target_label(target_id: String) -> String:
	if target_id == "SUPPLY":
		return "公共商品堆"
	for other in GameState.players:
		if other.player_id == target_id:
			return other.display_name
	return target_id


func _event_exchange_selection_valid(availability: Dictionary = {}) -> bool:
	var live := availability
	if live.is_empty():
		live = EventSystem.get_pending_exchange_availability()
	if not bool(live.get("available", false)):
		return false
	if _event_exchange_give_good.is_empty() or _event_exchange_target.is_empty() or _event_exchange_receive_good.is_empty():
		return false
	if _event_exchange_give_good not in live.get("give_goods", []):
		return false
	if _event_exchange_give_good == _event_exchange_receive_good:
		return false
	var by_target: Dictionary = live.get("legal_receive_goods_by_target", {})
	return by_target.has(_event_exchange_target) and _event_exchange_receive_good in by_target[_event_exchange_target]


func _event_exchange_prompt() -> String:
	if not _is_pending_event_exchange():
		return ""
	var availability := EventSystem.get_pending_exchange_availability()
	if not bool(availability.get("available", false)):
		return String(availability.get("message", "没有可完成的交换。"))
	if _event_exchange_give_good.is_empty():
		return "先在左侧选择要交出的货物。"
	if _event_exchange_receive_good.is_empty():
		return "再在右侧选择要获得的不同货物。"
	if not _event_exchange_selection_valid(availability):
		return "当前组合无效，请重新选择。"
	return "将用 %s 交换 %s（来自%s）。" % [
		GameData.get_good_name(GameState.content, _event_exchange_give_good),
		GameData.get_good_name(GameState.content, _event_exchange_receive_good),
		_event_exchange_target_label(_event_exchange_target),
	]


func _make_event_exchange_good_button(good_id: String, is_receive: bool, enabled: bool) -> Button:
	var button := Button.new()
	button.name = "%s_%s" % ["EventExchangeReceive" if is_receive else "EventExchangeGive", good_id]
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 32)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_ALL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 22)
	button.icon = _hud_good_texture(good_id)
	button.text = GameData.get_good_name(GameState.content, good_id)
	button.disabled = not enabled
	button.button_pressed = (
		_event_exchange_receive_good == good_id if is_receive else _event_exchange_give_good == good_id
	)
	button.tooltip_text = (
		"不能获得与交出货物相同的商品。"
		if is_receive and not enabled and not _event_exchange_give_good.is_empty()
		else "选择获得的货物" if is_receive else "选择交出的货物"
	)
	button.add_theme_font_size_override("font_size", HudStyle.SIZE_CAPTION)
	if HudStyle.FONT_BODY_MEDIUM != null:
		button.add_theme_font_override("font", HudStyle.FONT_BODY_MEDIUM)
	var captured_good := good_id
	if is_receive:
		button.pressed.connect(func(): _on_event_exchange_receive_selected(captured_good))
	else:
		button.pressed.connect(func(): _on_event_exchange_give_selected(captured_good))
	return button


func _sync_event_exchange_panel() -> void:
	if _event_exchange_panel == null:
		return
	var pending := _is_pending_event_exchange()
	_event_exchange_panel.visible = pending
	if not pending:
		return
	var availability := EventSystem.get_pending_exchange_availability()
	var give_goods: Array = availability.get("give_goods", [])
	var targets: Array = availability.get("targets", [])
	if _event_exchange_give_good not in give_goods:
		_event_exchange_give_good = ""
	if _event_exchange_target not in targets:
		_event_exchange_target = String(targets[0]) if not targets.is_empty() else ""
	var by_target: Dictionary = availability.get("legal_receive_goods_by_target", {})
	var receive_goods: Array = by_target.get(_event_exchange_target, [])
	if _event_exchange_receive_good not in receive_goods or _event_exchange_receive_good == _event_exchange_give_good:
		_event_exchange_receive_good = ""
	# 内容没变就不重建按钮：空闲提示复位发生在 _input 里，那时重建会让这一下点击落空（复检 LC-4）
	var sig := JSON.stringify([give_goods, targets, receive_goods, _event_exchange_give_good, _event_exchange_target, _event_exchange_receive_good, _event_exchange_submitting])
	if sig == _event_exchange_sig and _event_exchange_give_list.get_child_count() == give_goods.size():
		_event_exchange_status.text = _event_exchange_prompt()
		return
	_event_exchange_sig = sig

	_clear_children_now(_event_exchange_give_list)
	for good_id_v in give_goods:
		var good_id := String(good_id_v)
		_event_exchange_give_list.add_child(_make_event_exchange_good_button(good_id, false, true))

	_event_exchange_target_option.clear()
	for target_id_v in targets:
		var target_id := String(target_id_v)
		_event_exchange_target_option.add_item(_event_exchange_target_label(target_id))
		var item_index := _event_exchange_target_option.item_count - 1
		_event_exchange_target_option.set_item_metadata(item_index, target_id)
		if target_id == _event_exchange_target:
			_event_exchange_target_option.select(item_index)
	_event_exchange_target_option.disabled = targets.is_empty() or _event_exchange_submitting

	_clear_children_now(_event_exchange_receive_list)
	for good_id_v in receive_goods:
		var good_id := String(good_id_v)
		var enabled := not _event_exchange_give_good.is_empty() and good_id != _event_exchange_give_good
		_event_exchange_receive_list.add_child(_make_event_exchange_good_button(good_id, true, enabled))
	_event_exchange_status.text = _event_exchange_prompt()


func _on_event_exchange_give_selected(good_id: String) -> void:
	if not _can_accept_human() or not _is_pending_event_exchange() or _event_exchange_submitting:
		return
	var availability := EventSystem.get_pending_exchange_availability()
	if good_id not in availability.get("give_goods", []):
		return
	_event_exchange_give_good = "" if _event_exchange_give_good == good_id else good_id
	if _event_exchange_give_good == _event_exchange_receive_good:
		_event_exchange_receive_good = ""
	_set_feedback(_event_exchange_prompt(), COLOR_INFO)
	call_deferred("_refresh_after_event_exchange_selection")


func _on_event_exchange_target_selected(index: int) -> void:
	if not _can_accept_human() or not _is_pending_event_exchange() or _event_exchange_submitting:
		return
	if index < 0 or index >= _event_exchange_target_option.item_count:
		return
	_event_exchange_target = String(_event_exchange_target_option.get_item_metadata(index))
	_event_exchange_receive_good = ""
	_set_feedback(_event_exchange_prompt(), COLOR_INFO)
	call_deferred("_refresh_after_event_exchange_selection")


func _on_event_exchange_receive_selected(good_id: String) -> void:
	if not _can_accept_human() or not _is_pending_event_exchange() or _event_exchange_submitting:
		return
	var availability := EventSystem.get_pending_exchange_availability()
	var by_target: Dictionary = availability.get("legal_receive_goods_by_target", {})
	if (
		_event_exchange_give_good.is_empty()
		or good_id == _event_exchange_give_good
		or not by_target.has(_event_exchange_target)
		or good_id not in by_target[_event_exchange_target]
	):
		return
	_event_exchange_receive_good = "" if _event_exchange_receive_good == good_id else good_id
	_set_feedback(_event_exchange_prompt(), COLOR_INFO)
	call_deferred("_refresh_after_event_exchange_selection")


func _refresh_after_event_exchange_selection() -> void:
	if not _is_pending_event_exchange():
		return
	_sync_event_exchange_panel()
	if _lshu != null:
		_lshu_refresh_exchange()
	_refresh_cargo_slot_visuals()
	_refresh_action_buttons()


func _on_confirm_event_exchange_pressed() -> void:
	if (
		not _can_accept_human()
		or not _is_pending_event_exchange()
		or _event_exchange_submitting
	):
		return
	var availability := EventSystem.get_pending_exchange_availability()
	if not _event_exchange_selection_valid(availability):
		_set_feedback(_event_exchange_prompt(), COLOR_FAILURE)
		_refresh_action_buttons()
		return
	_event_exchange_submitting = true
	_primary_action.disabled = true
	_refresh_primary_skin()
	var result := EventSystem.resolve_pending_decision(
		{
			"target": _event_exchange_target,
			"give_good": _event_exchange_give_good,
			"receive_good": _event_exchange_receive_good,
		}
	)
	_event_exchange_submitting = false
	if bool(result.get("success", false)):
		_clear_event_exchange_selection()
	_set_feedback(
		String(result.get("message", "事件交换失败。")),
		COLOR_SUCCESS if bool(result.get("success", false)) else COLOR_FAILURE
	)
	_refresh()
	if bool(result.get("success", false)):
		_block_dock_clicks()
		_turn_result_text = String(result.get("message", ""))
		_after_human_move_settled()


func _event_loss_required_count() -> int:
	return int(_pending_loss_decision().get("required_give_count", 0))


func _event_loss_prompt() -> String:
	var required := _event_loss_required_count()
	var selected := _event_loss_selected_slots.size()
	if _lshu != null and _fun.loss_filter_active():
		return _fun.loss_prompt(required, selected)
	if _lshu != null:
		return "点挎包里要丢的货（%d/%d）" % [selected, required]
	return "请在玩家船舱选择要失去的货物（%d/%d）。" % [selected, required]


func _event_loss_selection_by_good() -> Dictionary:
	var selection := {}
	if GameState.players.is_empty():
		return selection
	var player := GameState.current_player()
	var legal_goods: Array = _pending_loss_decision().get("legal_give_goods", [])
	var stale: Array = []
	for raw_index in _event_loss_selected_slots:
		var slot_index := int(raw_index)
		if slot_index < 0 or slot_index >= player.warehouse_slots.size():
			stale.append(raw_index)
			continue
		var good_id := String(player.warehouse_slots[slot_index])
		if good_id not in legal_goods:
			stale.append(raw_index)
			continue
		selection[good_id] = int(selection.get(good_id, 0)) + 1
	for raw_index in stale:
		_event_loss_selected_slots.erase(raw_index)
	return selection


func _on_confirm_event_loss_pressed() -> void:
	if not _can_accept_human() or not _is_pending_loss_decision():
		return
	var required := _event_loss_required_count()
	var selection := _event_loss_selection_by_good()
	var selected_total := 0
	for good_id in selection:
		selected_total += int(selection[good_id])
	if required <= 0 or selected_total != required:
		_set_feedback(_event_loss_prompt(), COLOR_FAILURE)
		_refresh_action_buttons()
		return
	var result := EventSystem.resolve_pending_decision({"give_goods": selection})
	if bool(result.get("success", false)):
		_event_loss_selected_slots.clear()
		_last_sale_signature = ""
	_set_feedback(
		String(result.get("message", "事件选择失败。")),
		COLOR_SUCCESS if bool(result.get("success", false)) else COLOR_FAILURE
	)
	_refresh()
	if bool(result.get("success", false)):
		_block_dock_clicks()
		_turn_result_text = String(result.get("message", ""))
		_after_human_move_settled()


func _sale_selected_total() -> int:
	var total := 0
	for good_id in _sale_selection:
		total += int(_sale_selection[good_id])
	return total


func _selected_trade_meta() -> Dictionary:
	## 正式状态只读 TradeSelectorModel；同步兼容字段供旧断言读取。
	var meta := _trade_selector.selection_meta()
	_selected_give_index = int(meta.get("give_index", -1)) if not meta.is_empty() else -1
	_selected_receive_index = int(meta.get("receive_index", -1)) if not meta.is_empty() else -1
	return meta


func _on_give_option_selected(_index: int) -> void:
	## 隐藏 OptionButton 仅为自动化兼容层，不再驱动正式状态。
	pass


func _on_receive_option_selected(_index: int) -> void:
	pass


func _on_trade_times_arrow(delta: int) -> void:
	if not _can_accept_human() or GameState.phase != GameState.Phase.TRADE or _trade_submitting:
		return
	if _trade_selector.adjust_times(delta):
		_sync_trade_selector_view()
		_refresh_action_buttons()


func _on_trade_selector_gui_input(event: InputEvent, is_receive: bool) -> void:
	if not _can_accept_human() or GameState.phase != GameState.Phase.TRADE or _trade_submitting:
		return
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var delta := -1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1
			var changed := (
				_trade_selector.cycle_receive(delta) if is_receive else _trade_selector.cycle_give(delta)
			)
			if changed:
				_play_trade_tile_swap(is_receive)
				_sync_trade_selector_view()
				_refresh_action_buttons()
			accept_event()
			return
	if event is InputEventPanGesture:
		var pan := event as InputEventPanGesture
		if absf(pan.delta.y) >= 6.0:
			var pan_delta := -1 if pan.delta.y < 0.0 else 1
			var pan_changed := (
				_trade_selector.cycle_receive(pan_delta) if is_receive else _trade_selector.cycle_give(pan_delta)
			)
			if pan_changed:
				_play_trade_tile_swap(is_receive)
				_sync_trade_selector_view()
				_refresh_action_buttons()
			accept_event()
			return
	if event is InputEventScreenTouch and event.pressed:
		# 触屏没有滚轮；点资源格本体即可轮换候选。两侧箭头自己的 Button 会先
		# 消费事件，因此这里不会抢走加减倍数操作。
		var tap_changed := (
			_trade_selector.cycle_receive(1) if is_receive else _trade_selector.cycle_give(1)
		)
		if tap_changed:
			_play_trade_tile_swap(is_receive)
			_sync_trade_selector_view()
			_refresh_action_buttons()
		accept_event()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		match key.keycode:
			KEY_UP:
				var up_changed := (
					_trade_selector.cycle_receive(-1) if is_receive else _trade_selector.cycle_give(-1)
				)
				if up_changed:
					_play_trade_tile_swap(is_receive)
					_sync_trade_selector_view()
					_refresh_action_buttons()
				accept_event()
			KEY_DOWN:
				var down_changed := (
					_trade_selector.cycle_receive(1) if is_receive else _trade_selector.cycle_give(1)
				)
				if down_changed:
					_play_trade_tile_swap(is_receive)
					_sync_trade_selector_view()
					_refresh_action_buttons()
				accept_event()
			KEY_LEFT:
				_on_trade_times_arrow(-1)
				accept_event()
			KEY_RIGHT:
				_on_trade_times_arrow(1)
				accept_event()
			KEY_ENTER, KEY_KP_ENTER:
				_on_confirm_trade_pressed()
				accept_event()


func _play_trade_tile_swap(is_receive: bool) -> void:
	var tile := _trade_receive_tile if is_receive else _trade_give_tile
	if tile == null:
		return
	if _trade_tile_tween != null and _trade_tile_tween.is_valid():
		_trade_tile_tween.kill()
	tile.modulate.a = 0.35
	tile.position.y = 4.0
	_trade_tile_tween = create_tween()
	_trade_tile_tween.set_parallel(true)
	_trade_tile_tween.tween_property(tile, "modulate:a", 1.0, 0.10)
	_trade_tile_tween.tween_property(tile, "position:y", 0.0, 0.10)


# ---------- 棋盘路径选择 ----------

func _refresh_move_selection() -> void:
	var player := GameState.current_player()
	var need_move := (
		_can_accept_human()
		and GameState.phase == GameState.Phase.MOVE_OR_EVENT
		and not player.move_confirmed
		and not EventSystem.has_pending_decision()
	)
	if need_move and (not DiceSystem.is_event_face(player.die_result) or player.pending_event_needs_move):
		_board_selecting = true
		%BoardView.set_selection_mode(true)
		%BoardView.set_input_enabled(true)
		var legal := MovementSystem.get_legal_destinations(player, player.movement_budget)
		%BoardView.set_legal_nodes(legal)
		# 选中的目的地已经去不了（步数 / 交通变了）：作废；还能去就在重铺的标记上照样亮着
		if not _selected_path.is_empty() and (
			String(_selected_path[0]) != player.current_node_id or not legal.has(String(_selected_path.back()))
		):
			_selected_path = []
		_show_move_pick()
	else:
		_board_selecting = false
		%BoardView.set_selection_mode(false)
		%BoardView.set_input_enabled(false)
		%BoardView.clear_selection()
		if not _move_pick_open():
			_clear_move_pick()


func _on_board_node_clicked(node_id: String) -> void:
	if not _board_selecting or not _can_accept_human() or Time.get_ticks_msec() < _board_click_block_until_ms:
		return
	var player := GameState.current_player()
	if node_id == player.current_node_id:
		# 点自己脚下 = 取消已选（目的地和「原地停留」都取消）；要留在原地请按「原地停留」
		_clear_move_pick()
		_show_move_pick()
		_refresh_action_buttons()
		return
	# 已经选中的目的地再点一下（孩子连点、双击）：什么都不变，绝不出发——只有主按钮「出发（N 步）」才走
	if not _selected_path.is_empty() and String(_selected_path.back()) == node_id:
		return
	var path := MovementSystem.find_path(player, node_id, player.movement_budget)
	if path.is_empty():
		_set_feedback("该节点不在可达范围内。", COLOR_FAILURE)
		return
	# 鼠标、触屏一样：点一下只是选中（画出路线和步数），点别的地方就改选（Carlos 2026-09-27「先选再确认」）
	_selected_path = path
	_stay_picked = false
	_show_move_pick()
	_refresh_action_buttons()


func _on_city_inspect_requested(city_id: String) -> void:
	if _board_selecting or %CityLoreCard == null or Time.get_ticks_msec() < _board_click_block_until_ms:
		return
	# 棋子还在走、或者真人正开着市集时不弹城市图鉴：会盖住市集，孩子下一下只是把它关掉（复检 NOV-3）
	if _move_animating or (
		_lshu != null and GameState.phase == GameState.Phase.TRADE
		and not GameState.players.is_empty() and GameState.current_player().is_local_human()
	):
		return
	_sync_city_lore_rect()
	%CityLoreCard.open_for_city(city_id)


# ---------- 显示刷新 ----------

func _refresh() -> void:
	if GameState.players.is_empty():
		return
	if not _is_pending_loss_decision():
		_event_loss_selected_slots.clear()
	if not _is_pending_event_exchange():
		_clear_event_exchange_selection()
		_event_exchange_submitting = false
	var player := GameState.current_player()
	var role := "你" if player.is_local_human() else "AI"
	%CurrentPlayerLabel.text = "当前：%s（%s）" % [player.display_name, role]
	%PhaseLabel.text = "阶段：%s" % _phase_text()
	%TransportLabel.text = "交通：%s" % ("骆驼" if player.active_transport == GameData.Transport.CAMEL else "商船")
	%RoundLabel.text = "轮次：%d" % (GameState.round_index + 1)
	%SupplyLabel.text = "公共白银：%d" % GameState.silver_supply
	%EndgameBanner.visible = false
	%DiceLabel.text = "骰面：%s" % (DiceSystem.face_text(player.die_result) if player.die_result != null else "-")
	if _hud_current_action != null:
		_hud_current_action.text = "当前行动：%s" % ("玩家" if player.is_local_human() else "AI")
	if _hud_supply_title != null:
		_hud_supply_title.text = "公共银两："
	if _hud_supply != null:
		_hud_supply.text = str(_fun.shown_supply())
	_refresh_players()
	_refresh_ai_card()
	_refresh_warehouse()
	_refresh_trade_panel()
	if %BoardView.has_method("refresh_visible_trade_card"):
		%BoardView.refresh_visible_trade_card()
	_refresh_sale_rows()
	_refresh_move_selection()
	_refresh_action_buttons()
	_refresh_round_console()


func _refresh_players() -> void:
	while _player_rows.size() < GameState.players.size():
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 15)
		%PlayersBox.add_child(label)
		_player_rows.append(label)
	while _player_rows.size() > GameState.players.size():
		var stale: Label = _player_rows.pop_back()
		%PlayersBox.remove_child(stale)
		stale.free()
	for i in GameState.players.size():
		var p: PlayerState = GameState.players[i]
		var marker := "▶ " if i == GameState.current_player_index else "　"
		var role := "你" if p.is_local_human() else "AI"
		var node_name := GameData.get_node_display_name(GameState.content, p.current_node_id)
		_player_rows[i].visible = true
		_player_rows[i].text = "%s%s（%s）｜白银 %d｜货物 %d｜%s" % [
			marker, p.display_name, role, p.silver, p.cargo_count(), node_name
		]
		_player_rows[i].add_theme_color_override("font_color", _player_color(p.color_id))
	_refresh_player_cards()


func _refresh_player_cards() -> void:
	_clear_children_now(_player_cards)
	for i in GameState.players.size():
		var p: PlayerState = GameState.players[i]
		var active := i == GameState.current_player_index
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.add_theme_stylebox_override(
			"panel",
			_panel_style(
				Color("f4e4bd") if active else Color("dfc99d", 0.72),
				Color("c58b32") if active else Color("8a6a3d", 0.45),
				2 if active else 1
			)
		)
		_player_cards.add_child(panel)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 1)
		panel.add_child(box)
		var name := Label.new()
		name.text = "%s  %s" % ["●" if active else "○", "你" if p.is_local_human() else "AI"]
		name.add_theme_color_override("font_color", _player_color(p.color_id))
		name.add_theme_font_size_override("font_size", 14)
		box.add_child(name)
		var stats := Label.new()
		stats.text = "银 %d · 货 %d/4\n%s" % [
			p.silver,
			p.cargo_count(),
			GameData.get_node_display_name(GameState.content, p.current_node_id),
		]
		stats.add_theme_font_size_override("font_size", 11)
		box.add_child(stats)


## 右侧卷轴永远是「我的船舱」：AI 回合里仍显示本机玩家，而不是把 AI 的货挂在「玩家船舱」下
## （AI 的货与银两在左下角 AI 卡上）。真人回合里等于 current_player()。
func _hud_owner() -> PlayerState:
	if GameState.players.is_empty():
		return null
	var current := GameState.current_player()
	if not current.is_ai():
		return current
	# 电脑回合里挎包停在最近一位行动过的真人（同屏多位真人时不跳回一号位）
	for p in GameState.players:
		if (p as PlayerState).player_id == _lshu_last_human_id:
			return p
	for p in GameState.players:
		if (p as PlayerState).is_local_human():
			return p
	return current


func _refresh_warehouse() -> void:
	var player := _hud_owner()
	for i in 4:
		var slot: Label = %WarehouseSlots.get_child(i)
		if i < player.warehouse_slots.size():
			slot.text = GameData.get_good_name(GameState.content, player.warehouse_slots[i])
		else:
			slot.text = "空"
	if _hud_cargo_silver != null:
		_hud_cargo_silver.text = str(_fun.shown_silver(player))


func _refresh_ai_card() -> void:
	if _ai_card == null or _ai_card_goods == null:
		return
	var ai_player: PlayerState = null
	for candidate in GameState.players:
		if candidate.is_ai():
			ai_player = candidate
			break
	if ai_player == null:
		_ai_card.visible = false
		return
	_ai_card.visible = true
	_ai_card_name.text = "%s · %s" % [ai_player.display_name, AIDifficulty.display_name(ai_player.ai_difficulty)]
	_ai_card_silver.text = str(ai_player.silver)
	_clear_children_now(_ai_card_goods)
	# 资产摘要：只渲染 count>0；0 库存不建控件。
	for good_id in GameData.get_goods_ordered(GameState.content):
		var count := ai_player.held_count(good_id)
		if count <= 0:
			continue
		var slot := Control.new()
		slot.name = "AiGood_%s" % good_id
		slot.custom_minimum_size = Vector2(AI_GOOD_SLOT_PX, AI_GOOD_SLOT_PX)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var plate := Panel.new()
		plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		plate.add_theme_stylebox_override("panel", _panel_style(Color("130e0a", 0.86), Color("9e6729"), 1))
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(plate)
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.texture = _hud_good_texture(good_id)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.size = Vector2(AI_GOOD_ICON_PX, AI_GOOD_ICON_PX)
		# 略偏左上，与右下数量小底至少留 3px。
		icon.position = Vector2(5, 4)
		slot.add_child(icon)
		slot.add_child(_make_inventory_count_badge(count, false))
		_ai_card_goods.add_child(slot)
	_ai_card_goods.visible = _ai_card_goods.get_child_count() > 0
	if _ai_card != null:
		_ai_card.custom_minimum_size = Vector2(
			_ai_card.custom_minimum_size.x,
			AI_CARD_HEIGHT_WITH_GOODS if _ai_card_goods.visible else AI_CARD_HEIGHT_COMPACT
		)
	if is_inside_tree() and _lshu == null:
		_layout_hud()


## 货物图标统一用最新的 L叔 图标（scripts/lshu_ui/lshu_icons.gd），和市集面板、地图上的城市贸易小卡一致
func _hud_good_texture(good_id: String) -> Texture2D:
	return LshuIconsScript.good(good_id)


func _refresh_trade_panel() -> void:
	var player := GameState.current_player()
	var at_city := GameData.is_city_node(GameState.content, player.current_node_id)
	var city_id := GameData.get_city_at_node(GameState.content, player.current_node_id)
	_cached_trade_availability = TradeSystem.get_ratio_trade_availability(player)
	_cached_buy_availability = TradeSystem.get_buy_availability(player)
	_cached_exchange_availability = TradeSystem.get_exchange_availability(player)
	_cached_card_sale_availability = TradeSystem.get_card_sale_availability(player)
	_cached_trade_actions = _cached_trade_availability.get("actions", [])
	_cached_trade_card = TradeSystem.get_current_trade_card()
	if _cached_trade_card.is_empty():
		%TradeTitleLabel.text = "城市贸易（当前不在已开通城市）" if at_city else "城市贸易（道路节点）"
		%TradeCardLabel.text = ""
		_trade_city_label.text = "当前贸易"
		_trade_ratio_label.text = ""
	else:
		%TradeTitleLabel.text = "城市贸易：%s" % GameData.get_city_name(GameState.content, city_id)
		%TradeCardLabel.text = TradePanelHelper.format_card_ratio(_cached_trade_card)
		_trade_city_label.text = "%s当前贸易" % GameData.get_city_name(GameState.content, city_id)
		_trade_ratio_label.text = TradePanelHelper.format_card_ratio(_cached_trade_card)
	var context_signature := "%s|%s|%s|used:%s" % [
		player.player_id,
		city_id,
		String(_cached_trade_card.get("card_id", _cached_trade_card.get("id", ""))),
		str(player.trade_action_used),
	]
	var context_changed := context_signature != _trade_context_signature
	if context_changed:
		_trade_context_signature = context_signature
		_lshu_row_picked = false
		if _lshu != null:
			_lshu.market_rows_scroll.scroll_vertical = 0
		_sale_selected_slots.clear()
		_sale_selection.clear()
		_trade_panel_mode = _default_trade_panel_mode(player, at_city)
	var signature := TradePanelHelper.trade_state_signature(player)
	if signature != _last_trade_signature or context_changed:
		_last_trade_signature = signature
		_rebuild_give_options()
	else:
		_update_trade_preview_and_buttons()
	_refresh_trade_mode_view()


func _default_trade_panel_mode(player: PlayerState, at_city: bool) -> int:
	var can_buy := bool(_cached_buy_availability.get("can_trade", false))
	var can_exchange := bool(_cached_exchange_availability.get("can_trade", false))
	var can_card_sell := bool(_cached_card_sale_availability.get("can_trade", false))
	var can_sell := (
		at_city
		and not player.trade_action_used
		and player.cargo_count() > 0
	)
	if player.cargo_count() == 0 and can_buy:
		return TradePanelMode.BUY
	if can_exchange:
		return TradePanelMode.EXCHANGE
	if can_card_sell:
		return TradePanelMode.CARD_SELL
	if can_buy:
		return TradePanelMode.BUY
	if can_sell:
		return TradePanelMode.DIRECT_SALE
	return TradePanelMode.EXCHANGE


func _default_card_trade_mode() -> int:
	if bool(_cached_exchange_availability.get("can_trade", false)):
		return TradePanelMode.EXCHANGE
	if bool(_cached_card_sale_availability.get("can_trade", false)):
		return TradePanelMode.CARD_SELL
	if bool(_cached_buy_availability.get("can_trade", false)):
		return TradePanelMode.BUY
	return TradePanelMode.EXCHANGE


func _availability_for_mode(mode: int) -> Dictionary:
	match mode:
		TradePanelMode.BUY:
			return _cached_buy_availability
		TradePanelMode.CARD_SELL:
			return _cached_card_sale_availability
		TradePanelMode.DIRECT_SALE:
			return {}
		_:
			return _cached_exchange_availability


func _reload_trade_selector_for_mode() -> void:
	_trade_ui_updating = true
	if _trade_panel_mode == TradePanelMode.DIRECT_SALE:
		_trade_selector.clear()
	else:
		_trade_selector.load_from_availability(
			_availability_for_mode(_trade_panel_mode),
			_cached_trade_card,
			GameState.current_player()
		)
	_sync_legacy_option_buttons_from_model()
	_trade_ui_updating = false
	_sync_trade_selector_view()


func _rebuild_give_options() -> void:
	## 从当前模式的 TradeSystem 可用性重建选择模型；不销毁 Tile。
	_reload_trade_selector_for_mode()
	_update_trade_preview_and_buttons()


func _rebuild_trade_icon_controls() -> void:
	## 兼容旧测试入口：不再销毁重建 Tile，只同步模型视图。
	_sync_trade_selector_view()
	_update_trade_preview_and_buttons()


func _rebuild_receive_icon_controls() -> void:
	_sync_trade_selector_view()


func _on_icon_give_selected(give_index: int) -> void:
	if not _can_accept_human():
		return
	_lshu_row_picked = true
	if _trade_selector.select_give_by_index(give_index):
		_sync_trade_selector_view()
		_update_trade_preview_and_buttons()


func _on_icon_receive_selected(receive_index: int) -> void:
	if not _can_accept_human():
		return
	_lshu_row_picked = true
	if _trade_selector.select_receive_by_index(receive_index):
		_sync_trade_selector_view()
		_update_trade_preview_and_buttons()


func _on_receive_choice_pressed(slot_index: int) -> void:
	if (
		not _can_accept_human()
		or GameState.phase != GameState.Phase.TRADE
		or _trade_submitting
		or slot_index < 0
		or slot_index >= _trade_selector.receive_candidates.size()
	):
		return
	var item: Dictionary = _trade_selector.receive_candidates[slot_index]
	if not bool(item.get("enabled", false)):
		return
	_lshu_row_picked = true
	var receive_index := int(item.get("receive_index", -1))
	if receive_index >= 0 and _trade_selector.select_receive_by_index(receive_index):
		_sync_trade_selector_view()
		_update_trade_preview_and_buttons()


func _sync_legacy_option_buttons_from_model() -> void:
	%GiveOption.clear()
	%ReceiveOption.clear()
	for item in _trade_selector.give_candidates:
		var idx: int = %GiveOption.item_count
		%GiveOption.add_item(String(item.get("label", "")))
		%GiveOption.set_item_metadata(idx, {"give_index": int(item.get("give_index", -1))})
	if _trade_selector.give_candidates.is_empty():
		%GiveOption.select(-1)
	else:
		%GiveOption.select(_trade_selector.give_cursor)
	for item in _trade_selector.receive_candidates:
		var ridx: int = %ReceiveOption.item_count
		%ReceiveOption.add_item(String(item.get("label", "")))
		%ReceiveOption.set_item_metadata(
			ridx,
			{
				"receive_index": int(item.get("receive_index", -1)),
				"max_times": int(item.get("max_times", 0)),
			}
		)
	if _trade_selector.receive_candidates.is_empty():
		%ReceiveOption.select(-1)
	else:
		%ReceiveOption.select(_trade_selector.receive_cursor)


func _sync_trade_selector_view() -> void:
	_selected_give_index = _trade_selector.give_index()
	_selected_receive_index = _trade_selector.receive_index()
	var give_entry := _trade_selector.give_entry()
	var receive_entry := _trade_selector.receive_entry()
	var give_display_total := _trade_selector.give_total()
	var receive_display_total := _trade_selector.receive_total()
	# 条件不足时仍展示牌面的完整基础比例，只灰显，不把货物/白银项变成空白。
	if give_display_total <= 0 and not give_entry.is_empty():
		give_display_total = int(give_entry.get("quantity", 0))
	if receive_display_total <= 0 and not receive_entry.is_empty():
		receive_display_total = int(receive_entry.get("quantity", 0))
	_paint_trade_tile(
		_trade_give_tile, give_entry, false, give_display_total, _trade_selector.can_trade
	)
	_paint_trade_tile(
		_trade_receive_tile, receive_entry, true, receive_display_total, _trade_selector.can_trade
	)
	_paint_trade_side_meta(false)
	_paint_trade_side_meta(true)
	_paint_trade_wheel_hints()
	_paint_receive_choice_list()
	var phase_trade := GameState.phase == GameState.Phase.TRADE
	var can := _trade_selector.can_trade
	var reason := _trade_block_reason_text()
	## 比例兑换/买入的数据仍在后台同步；最终显隐统一由 _refresh_trade_mode_view 决定。
	var times_verb := (
		"买入" if _trade_panel_mode == TradePanelMode.BUY
		else "按卡售银" if _trade_panel_mode == TradePanelMode.CARD_SELL
		else "兑换"
	)
	if _trade_times_max_label != null:
		_trade_times_max_label.visible = can
		_trade_times_max_label.text = "可%s %d 次" % [times_verb, maxi(_trade_selector.max_times, 0)]
	if _trade_times_current_label != null:
		_trade_times_current_label.visible = can
		_trade_times_current_label.text = (
			"当前%s：第 %d 次" % [times_verb, _trade_selector.times]
			if can and _trade_selector.times > 0
			else "当前%s：—" % times_verb
		)
	if _trade_exchange_badge != null:
		_trade_exchange_badge.text = "×%d" % maxi(_trade_selector.times, 0) if can else "—"
	for button in _trade_times_buttons:
		if button == null or not is_instance_valid(button):
			continue
		var is_dec: bool = String(button.name).ends_with("TimesDec") or button.text == "‹"
		button.disabled = (
			not _can_accept_human()
			or not can
			or _trade_submitting
			or (not _trade_selector.can_dec_times() if is_dec else not _trade_selector.can_inc_times())
		)
	_sync_legacy_option_buttons_from_model()
	_refresh_cargo_slot_visuals()
	var meta := _trade_selector.selection_meta()
	if can and not meta.is_empty():
		if _console_trade_preview != null:
			_console_trade_preview.text = _trade_selection_summary(meta)
		if _trade_consume_label != null:
			_trade_consume_label.text = _trade_footer_prompt(meta)
			_trade_consume_label.visible = not _is_dense_trade()
		if _console_trade_status != null:
			_console_trade_status.text = ""
			_console_trade_status.visible = false
	else:
		if _console_trade_preview != null:
			_console_trade_preview.text = ""
		if _trade_consume_label != null:
			_trade_consume_label.text = ""
			_trade_consume_label.visible = false
		if _console_trade_status != null:
			_console_trade_status.text = reason if phase_trade else ""
			_console_trade_status.visible = phase_trade and not reason.is_empty()
	_refresh_trade_mode_view()


func _refresh_trade_mode_view() -> void:
	if _trade_sale_panel == null:
		return
	var phase_trade := GameState.phase == GameState.Phase.TRADE
	# 1024×576 紧凑视口：贸易页优先保留 44px 触控候选和主操作，
	# 暂时收起重复的回合标题（顶栏仍明确显示当前行动）。
	var compact_trade := phase_trade and _is_compact_hud()
	var window_h := float(get_window().size.y) if get_window() != null else size.y
	var dense_trade := phase_trade and minf(size.y, window_h) <= DENSE_TRADE_MAX_H
	# 720p 是首要基准：保留船舱与阶段标题，但收紧纵向留白，避免 CTA 被卷轴底端裁切。
	if _console != null:
		_console.add_theme_constant_override("separation", 6 if dense_trade else 12)
	if _hud_phase_content != null:
		_hud_phase_content.add_theme_constant_override("separation", 4 if dense_trade else 8)
	if _hud_cargo_block != null:
		_hud_cargo_block.add_theme_constant_override("separation", 4 if dense_trade else 8)
	var action_header := find_child("ActionHeader", true, false) as Control
	if action_header != null:
		# 720p 贸易页最满：步骤条让位给契约板（城市标题已说明正在交易）
		action_header.visible = not compact_trade and not dense_trade
	# 576px 高度时优先保证完整交易闭环：候选、摘要、次要操作与 CTA 必须
	# 同屏可见。货舱仍可从交出栏/交易摘要确认；回到其它阶段立即恢复。
	if _hud_cargo_block != null:
		# 直售要在船舱里点选货物：小窗口下也保留船舱
		_hud_cargo_block.visible = not compact_trade or _trade_panel_mode == TradePanelMode.DIRECT_SALE
	var divider_wrap := find_child("OrnateDividerWrap", true, false) as Control
	if divider_wrap != null:
		divider_wrap.visible = not compact_trade and not dense_trade
	if _console_feedback != null:
		# 贸易契约下已有摘要条与消耗提示；720p 再显示阶段 footer 会重复并贴卷轴底端。
		_console_feedback.visible = not compact_trade
	if _trade_mode_bar != null:
		_trade_mode_bar.visible = phase_trade
	_paint_trade_mode_bar()
	var ratio_mode := (
		phase_trade
		and (
			_trade_panel_mode == TradePanelMode.BUY
			or _trade_panel_mode == TradePanelMode.EXCHANGE
			or _trade_panel_mode == TradePanelMode.CARD_SELL
		)
	)
	var sale_mode := phase_trade and _trade_panel_mode == TradePanelMode.DIRECT_SALE
	var ratio_visible := ratio_mode and _trade_selector.has_candidates()
	var player: PlayerState = GameState.current_player() if not GameState.players.is_empty() else null
	var sale_available := (
		sale_mode
		and player != null
		and GameData.is_city_node(GameState.content, player.current_node_id)
		and not player.trade_action_used
	)
	if _hud_trade_frame != null:
		_hud_trade_frame.visible = ratio_visible or sale_available
		_hud_trade_frame.custom_minimum_size.y = (
			TRADE_FRAME_HEIGHT_COMPACT_PX if dense_trade else TRADE_FRAME_HEIGHT_PX
		)
	if _trade_contract_row != null:
		_trade_contract_row.visible = ratio_visible
	var use_receive_list := (
		ratio_visible
		and _trade_panel_mode == TradePanelMode.BUY
		and not _trade_selector.receive_candidates.is_empty()
	)
	# 买入候选已把所有比例同时展示；倍数仍由左侧箭头和中央徽章表达，
	# 隐藏重复的两行倍数文案，给 44px 触控候选留出安全高度。
	if _trade_times_row != null:
		_trade_times_row.visible = ratio_visible and not use_receive_list
	_trade_sale_panel.visible = sale_available
	for node in [
		_trade_give_selector,
		_give_heading,
		_receive_heading,
		_trade_give_column,
		_trade_receive_column,
		_trade_connector,
	]:
		if node != null:
			node.visible = ratio_visible
	if _trade_receive_selector != null:
		_trade_receive_selector.visible = ratio_visible and not use_receive_list
	if _trade_receive_choice_list != null:
		_trade_receive_choice_list.visible = use_receive_list
	if _give_heading != null:
		_give_heading.text = (
			"支付" if _trade_panel_mode == TradePanelMode.BUY
			else "售出" if _trade_panel_mode == TradePanelMode.CARD_SELL
			else "交出"
		)
	if _receive_heading != null:
		_receive_heading.text = "购得" if _trade_panel_mode == TradePanelMode.BUY else "获得"
	if sale_mode:
		_refresh_direct_sale_view()
	else:
		if _trade_summary_wrap != null:
			_trade_summary_wrap.visible = ratio_visible and _trade_selector.can_trade
		if _console_trade_status != null:
			var reason := _trade_block_reason_text()
			_console_trade_status.text = reason if phase_trade and not _trade_selector.can_trade else ""
			_console_trade_status.visible = (
				phase_trade and not _trade_selector.can_trade and not reason.is_empty()
			)
	# 720p：这笔交易的摘要改由底部「下一步」提示行说出，摘要条与「将消耗…」收起，
	# 保证主按钮与「不交易，结束回合」始终落在卷轴安全区内、位置不跳。
	if dense_trade:
		if _trade_consume_label != null:
			_trade_consume_label.visible = false
		if _trade_summary_wrap != null:
			_trade_summary_wrap.visible = false
	_refresh_cargo_slot_visuals()


## 720p（含 1080p 等比放大）下的贸易页：卷轴最满的状态，需要收起重复信息。
func _is_dense_trade() -> bool:
	if GameState.phase != GameState.Phase.TRADE:
		return false
	var window_h := float(get_window().size.y) if get_window() != null else size.y
	return minf(size.y, window_h) <= DENSE_TRADE_MAX_H


func _paint_trade_mode_bar() -> void:
	if _trade_mode_bar == null:
		return
	var player: PlayerState = GameState.current_player() if not GameState.players.is_empty() else null
	var at_city := player != null and GameData.is_city_node(GameState.content, player.current_node_id)
	var can_buy := bool(_cached_buy_availability.get("can_trade", false))
	var can_exchange := bool(_cached_exchange_availability.get("can_trade", false))
	var can_card_sell := bool(_cached_card_sale_availability.get("can_trade", false))
	var can_sell := (
		player != null
		and at_city
		and not player.trade_action_used
		and player.cargo_count() > 0
	)
	var reasons := {
		TradePanelMode.BUY: String(_cached_buy_availability.get("message", "当前无法买入。")),
		TradePanelMode.EXCHANGE: String(_cached_exchange_availability.get("message", "当前无法兑换。")),
		TradePanelMode.CARD_SELL: String(_cached_card_sale_availability.get("message", "当前无法按牌面出售。")),
		TradePanelMode.DIRECT_SALE: (
			"本回合已经完成贸易。"
			if player != null and player.trade_action_used
			else "当前不在城市。" if not at_city
			else "没有可出售的货物。" if player != null and player.cargo_count() == 0
			else ""
		),
	}
	for mode in _trade_mode_buttons.keys():
		var button: Button = _trade_mode_buttons[mode]
		if button == null:
			continue
		var selected := int(mode) == _trade_panel_mode
		var mode_ok := (
			can_buy if int(mode) == TradePanelMode.BUY
			else can_exchange if int(mode) == TradePanelMode.EXCHANGE
			else can_card_sell if int(mode) == TradePanelMode.CARD_SELL
			else can_sell
		)
		## 模式按钮始终可点以查看原因；不可用仅视觉置灰。
		button.disabled = false
		button.tooltip_text = "" if mode_ok else String(reasons.get(mode, ""))
		_style_trade_mode_button(button, selected, mode_ok)


func _style_trade_mode_button(button: Button, selected: bool, available: bool) -> void:
	var fill := HudStyle.CINNABAR_TEXT if selected else Color("E8D7B2")
	var border := HudStyle.GOLD if selected else Color("B08A4A")
	var text_color := HudStyle.PARCHMENT_LIGHT if selected else HudStyle.INK_STRONG
	if not available:
		fill = Color(fill.r, fill.g, fill.b, 0.45 if selected else 0.55)
		text_color = Color(HudStyle.INK_WEAK.r, HudStyle.INK_WEAK.g, HudStyle.INK_WEAK.b, 0.75)
		border = Color(border.r, border.g, border.b, 0.55)
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(2 if selected else 1)
	box.set_corner_radius_all(3)
	box.content_margin_left = 6
	box.content_margin_right = 6
	box.content_margin_top = 3
	box.content_margin_bottom = 3
	for style_name in ["normal", "hover", "pressed", "disabled"]:
		button.add_theme_stylebox_override(style_name, box)
	button.add_theme_color_override("font_color", text_color)
	button.add_theme_color_override("font_hover_color", text_color)
	button.add_theme_color_override("font_pressed_color", text_color)
	button.add_theme_color_override("font_disabled_color", text_color)
	if HudStyle.FONT_BODY_MEDIUM != null:
		button.add_theme_font_override("font", HudStyle.FONT_BODY_MEDIUM)
	button.add_theme_font_size_override("font_size", HudStyle.SIZE_CAPTION)


func _refresh_direct_sale_view() -> void:
	if GameState.players.is_empty():
		return
	_rebuild_sale_selection_from_slots()
	var player := GameState.current_player()
	var quote := TradeSystem.get_direct_sale_quote(player, _sale_selection)
	var total_items := int(quote.get("total_items", 0))
	var silver_gain := int(quote.get("silver_gain", 0))
	for preview in _trade_sale_icon_slots:
		preview.texture = null
		preview.visible = false
	var preview_index := 0
	var slot_indices: Array = _sale_selected_slots.keys()
	slot_indices.sort()
	for raw_index in slot_indices:
		var slot_index := int(raw_index)
		if slot_index < 0 or slot_index >= player.warehouse_slots.size():
			continue
		if preview_index >= _trade_sale_icon_slots.size():
			break
		var preview: TextureRect = _trade_sale_icon_slots[preview_index]
		preview.texture = _hud_good_texture(String(player.warehouse_slots[slot_index]))
		preview.visible = true
		preview_index += 1
	_trade_sale_count_label.text = "已选 %d 件" % total_items
	_paint_trade_tile(
		_trade_sale_silver_tile,
		{"resource_kind": "SILVER", "resource_id": "silver", "quantity": 1},
		true,
		silver_gain
	)
	_trade_sale_hint.text = (
		"点击上方货舱格选择要出售的货物"
		if total_items == 0
		else "每件货物可直接出售 1 白银"
	)
	if _trade_summary_wrap != null:
		_trade_summary_wrap.visible = total_items > 0 and not _is_dense_trade()
	if _console_trade_preview != null:
		_console_trade_preview.text = _direct_sale_summary(_sale_selection, silver_gain)
	if _trade_consume_label != null:
		_trade_consume_label.text = (
			"将出售 %d 件货物，获得 %d 白银" % [total_items, silver_gain]
			if total_items > 0
			else ""
		)
		_trade_consume_label.visible = total_items > 0 and not _is_dense_trade()
	if _console_trade_status != null:
		_console_trade_status.text = (
			String(quote.get("message", ""))
			if total_items == 0 and player.cargo_count() == 0
			else ""
		)
		_console_trade_status.visible = not _console_trade_status.text.is_empty()


func _direct_sale_summary(selection: Dictionary, silver_gain: int) -> String:
	if selection.is_empty():
		return ""
	var parts: Array[String] = []
	for good_id in GameData.get_goods_ordered(GameState.content):
		var count := int(selection.get(good_id, 0))
		if count > 0:
			parts.append("%s×%d" % [GameData.get_good_name(GameState.content, good_id), count])
	return "已选：%s → 白银×%d" % ["、".join(parts), silver_gain]


func _trade_block_reason_text() -> String:
	var msg := String(_trade_selector.message)
	if msg.is_empty():
		var avail := _availability_for_mode(_trade_panel_mode)
		msg = String(avail.get("message", ""))
	if msg.is_empty():
		msg = String(_cached_trade_availability.get("message", ""))
	return msg


func _paint_trade_wheel_hints() -> void:
	if _trade_panel_mode == TradePanelMode.BUY and _trade_give_wheel_hint != null:
		_trade_give_wheel_hint.visible = true
		_trade_give_wheel_hint.text = "完整比例 · 组数 ×%d" % maxi(_trade_selector.times, 1)
		if _trade_receive_wheel_hint != null:
			_trade_receive_wheel_hint.visible = false
			_trade_receive_wheel_hint.text = ""
		return
	_set_wheel_hint(_trade_give_wheel_hint, _trade_selector.give_candidates.size(), _trade_selector.give_cursor)
	_set_wheel_hint(
		_trade_receive_wheel_hint, _trade_selector.receive_candidates.size(), _trade_selector.receive_cursor
	)


func _paint_receive_choice_list() -> void:
	if _trade_receive_choice_list == null:
		return
	var entries: Array = _trade_selector.card.get("entries", [])
	for slot_index in _trade_receive_choice_buttons.size():
		var button: Button = _trade_receive_choice_buttons[slot_index]
		if slot_index >= _trade_selector.receive_candidates.size():
			button.visible = false
			button.set_meta("receive_index", -1)
			continue
		var item: Dictionary = _trade_selector.receive_candidates[slot_index]
		var receive_index := int(item.get("receive_index", -1))
		var entry: Dictionary = entries[receive_index] if receive_index >= 0 and receive_index < entries.size() else {}
		var selected := receive_index == _trade_selector.receive_index()
		var enabled := bool(item.get("enabled", false))
		var base_quantity := int(entry.get("quantity", 0))
		button.visible = true
		button.disabled = _trade_submitting or not _can_accept_human() or not enabled
		button.set_meta("receive_index", receive_index)
		button.set_meta("enabled", enabled)
		button.icon = _resource_icon(entry)
		button.text = "%s ×%d" % [_resource_name(entry), base_quantity]
		button.tooltip_text = _receive_choice_tooltip(entry, item)
		_style_receive_choice_button(button, selected and enabled, enabled)


func _style_receive_choice_button(button: Button, selected: bool, enabled: bool = true) -> void:
	var normal := _panel_style(
		Color("F3E1B9") if selected else Color("DCC9A2"),
		HudStyle.CINNABAR_TEXT if selected else Color("9D7B43"),
		2 if selected else 1
	)
	if not enabled:
		normal = _panel_style(Color("B9AC92", 0.62), Color("8A7B63", 0.65), 1)
	var hover := _panel_style(Color("F7E9CA"), HudStyle.GOLD, 2)
	var pressed := _panel_style(Color("E7D1A3"), HudStyle.CINNABAR_TEXT, 2)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", hover)
	button.add_theme_stylebox_override("disabled", normal)
	var color := (
		HudStyle.CINNABAR_TEXT if selected
		else HudStyle.INK_STRONG if enabled
		else Color(HudStyle.INK_WEAK, 0.62)
	)
	button.add_theme_color_override("font_color", color)
	button.add_theme_color_override("font_hover_color", HudStyle.CINNABAR_TEXT)
	button.add_theme_color_override("font_pressed_color", HudStyle.CINNABAR_TEXT)
	button.add_theme_color_override("font_focus_color", color)
	button.add_theme_color_override("font_disabled_color", Color(color, 0.55))


func _receive_choice_tooltip(entry: Dictionary, item: Dictionary) -> String:
	if entry.is_empty():
		return ""
	if not bool(item.get("enabled", false)):
		var blocked_message := String(item.get("message", "当前无法按完整比例获得该项。"))
		return "%s ×%d · 不可选：%s" % [
			_resource_name(entry), int(entry.get("quantity", 0)), blocked_message
		]
	var resource_id := String(entry.get("resource_id", ""))
	var supply := (
		int(GameState.silver_supply)
		if String(entry.get("resource_kind", "")) == "SILVER"
		else int(GameState.goods_supply.get(resource_id, 0))
	)
	return "%s · 供应 %d · 最多 %d 次" % [
		_resource_name(entry), supply, int(item.get("max_times", 0))
	]


func _set_wheel_hint(label: Label, total: int, cursor: int) -> void:
	if label == null:
		return
	if total <= 0:
		label.text = ""
		label.visible = false
		return
	label.visible = true
	if total == 1:
		label.text = "仅此一项"
	else:
		label.text = "滚轮切换 · %d/%d" % [cursor + 1, total]


func _paint_trade_tile(
	tile: Control, entry: Dictionary, is_receive: bool, total_qty: int, enabled: bool = true
) -> void:
	if tile == null:
		return
	var plate := tile.get_node_or_null("TilePlate") as TextureRect
	var glow := tile.get_node_or_null("SelectedGlow") as TextureRect
	var icon := tile.get_node_or_null("ResourceIcon") as TextureRect
	var quantity := tile.get_node_or_null("Quantity") as Label
	var has_entry := not entry.is_empty() and total_qty > 0
	tile.modulate = Color.WHITE if enabled or not has_entry else Color(0.72, 0.72, 0.72, 0.72)
	if plate != null:
		# 固定使用同一个方形底板；选中态只叠加透明 glow，避免双框与竖长框。
		plate.texture = TRADE_CARGO_NORMAL_TEXTURE
		plate.modulate = Color.WHITE if has_entry else Color(1, 1, 1, 0.55)
	if glow != null:
		glow.visible = has_entry and enabled
	if icon != null:
		icon.texture = _resource_icon(entry) if has_entry else null
		icon.visible = has_entry
	if quantity != null:
		quantity.text = str(total_qty) if has_entry else ""
		quantity.visible = has_entry


func _paint_trade_side_meta(is_receive: bool) -> void:
	var player := GameState.current_player()
	if is_receive:
		if _trade_receive_meta == null:
			return
		var entry := _trade_selector.receive_entry()
		if entry.is_empty():
			_trade_receive_meta.text = ""
			return
		if String(entry.get("resource_kind", "")) == "SILVER":
			_trade_receive_meta.text = "公共银两 %d" % int(GameState.silver_supply)
		else:
			var gid := String(entry.get("resource_id", ""))
			_trade_receive_meta.text = "供应 %d" % int(GameState.goods_supply.get(gid, 0))
	else:
		if _trade_give_held == null:
			return
		var give := _trade_selector.give_entry()
		if give.is_empty():
			_trade_give_held.text = ""
			return
		if String(give.get("resource_kind", "")) == "SILVER":
			_trade_give_held.text = "银两 %d" % player.silver
		else:
			_trade_give_held.text = "持有 %d" % player.held_count(String(give.get("resource_id", "")))


func _resource_button(entry: Dictionary, label_text: String, selected: bool, is_reward: bool) -> Button:
	## 保留给非交易页兼容调用；交易选择器已改用固定 Tile。
	var button := Button.new()
	button.custom_minimum_size = Vector2(TRADE_TILE_W, TRADE_TILE_H)
	button.tooltip_text = label_text
	button.toggle_mode = true
	button.button_pressed = selected
	button.add_theme_stylebox_override("normal", _transparent_style())
	button.add_theme_stylebox_override("hover", _transparent_style())
	button.add_theme_stylebox_override("pressed", _transparent_style())
	button.add_theme_stylebox_override("focus", _transparent_style())
	return button


func _decorate_button_content(button: Button, icon: Texture2D, text: String) -> void:
	button.text = ""
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 4)
	margin.add_theme_constant_override("margin_left", 5)
	margin.add_theme_constant_override("margin_right", 5)
	margin.add_theme_constant_override("margin_top", 3)
	margin.add_theme_constant_override("margin_bottom", 3)
	button.add_child(margin)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 3)
	margin.add_child(row)
	if icon != null:
		var texture := TextureRect.new()
		texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture.custom_minimum_size = Vector2(24, 24)
		texture.texture = icon
		texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(texture)
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(label)


func _resource_icon(entry: Dictionary) -> Texture2D:
	if String(entry.get("resource_kind", "")) == "SILVER":
		return _get_silver_icon()
	var good_id := String(entry.get("resource_id", ""))
	var tex := _hud_good_texture(good_id)
	return tex


func _resource_name(entry: Dictionary) -> String:
	if String(entry.get("resource_kind", "")) == "SILVER":
		return "白银"
	return GameData.get_good_name(GameState.content, String(entry.get("resource_id", "")))


func _get_silver_icon() -> Texture2D:
	var lshu_silver := LshuIconsScript.silver()
	if lshu_silver != null:
		return lshu_silver
	if HUD_SILVER_TEXTURE != null:
		return HUD_SILVER_TEXTURE
	if _silver_icon != null:
		return _silver_icon
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var center := Vector2(15.5, 15.5)
	for y in 32:
		for x in 32:
			var d := Vector2(x, y).distance_to(center)
			if d <= 13.5:
				var color := Color("f1c45b") if d < 11.5 else Color("9b6b2f")
				if d < 8.0:
					color = color.lightened(0.12 * (1.0 - d / 8.0))
				image.set_pixel(x, y, color)
	_silver_icon = ImageTexture.create_from_image(image)
	return _silver_icon


func _clear_children_now(parent: Node) -> void:
	if parent == null:
		return
	for child in parent.get_children():
		parent.remove_child(child)
		child.free()


func _rebuild_receive_options() -> void:
	_sync_legacy_option_buttons_from_model()


func _fill_receive_options() -> void:
	_sync_legacy_option_buttons_from_model()


func _update_trade_preview_and_buttons() -> void:
	var allow := _can_accept_human() and not _trade_submitting
	var phase_trade := GameState.phase == GameState.Phase.TRADE
	var meta := _selected_trade_meta()
	var can_exchange := phase_trade and not meta.is_empty() and int(meta.get("times", 0)) >= 1
	var action_verb := (
		"买入" if _trade_panel_mode == TradePanelMode.BUY
		else "按卡售银" if _trade_panel_mode == TradePanelMode.CARD_SELL
		else "兑换"
	)
	_sync_trade_selector_view()
	if can_exchange:
		%TradePreviewLabel.text = TradePanelHelper.format_preview(
			_cached_trade_card,
			int(meta["give_index"]),
			int(meta["receive_index"]),
			int(meta["max_times"])
		)
		%TradeStatusLabel.text = ""
		%ExchangeMaxButton.text = "确认%s ×%d" % [action_verb, int(meta["times"])]
		_console_exchange_max.text = %ExchangeMaxButton.text
	else:
		%TradePreviewLabel.text = ""
		## 正式 UI 只通过 TradeStatus 显示一次原因；兼容层标签保持同步但不另开第三处。
		%TradeStatusLabel.text = _trade_block_reason_text() if phase_trade else ""
		%ExchangeMaxButton.text = "确认%s" % action_verb
		_console_exchange_max.text = "确认%s" % action_verb
	%GiveLabel.visible = false
	%ReceiveLabel.visible = false
	%GiveOption.visible = false
	%ReceiveOption.visible = false
	%ExchangeOneButton.visible = false
	%ExchangeMaxButton.visible = false
	%GiveOption.disabled = true
	%ReceiveOption.disabled = true
	%ExchangeOneButton.disabled = not allow or not can_exchange
	%ExchangeMaxButton.disabled = not allow or not can_exchange
	_console_exchange_one.disabled = not allow or not can_exchange
	_console_exchange_max.disabled = not allow or not can_exchange
	_refresh_sale_action_state()


func _trade_selection_summary(meta: Dictionary) -> String:
	if meta.is_empty():
		return "已选：— → —"
	var give := _trade_selector.give_entry()
	var recv := _trade_selector.receive_entry()
	if give.is_empty() or recv.is_empty():
		return "已选：— → —"
	var times := int(meta.get("times", _trade_selector.times))
	return "已选：%s → %s" % [
		_format_entry_times(give, times),
		_format_entry_times(recv, times),
	]


func _format_entry_times(entry: Dictionary, times: int) -> String:
	var qty := int(entry.get("quantity", 0)) * maxi(times, 0)
	if String(entry.get("resource_kind", "")) == "SILVER":
		return "白银×%d" % qty
	return "%s×%d" % [GameData.get_good_name(GameState.content, String(entry.get("resource_id", ""))), qty]


func _refresh_sale_rows() -> void:
	var player := _hud_owner()
	# 签名必须反映真实件数，避免 inventory 里残留 0 键时漏刷船舱。
	var counts: Array = []
	for good_id in GameData.get_goods_ordered(GameState.content):
		counts.append("%s:%d" % [good_id, player.held_count(good_id)])
	var pending_any := EventSystem.get_pending_decision() if EventSystem.has_pending_decision() else {}
	var pending_signature := (
		"%s:%d:%s" % [
			String(pending_any.get("operation", "")),
			int(pending_any.get("required_give_count", 0)),
			String(pending_any.get("acting_player_id", "")),
		]
		if not pending_any.is_empty()
		else "none"
	)
	var signature := "%s|%s|slots:%d|pending:%s" % [
		player.player_id, ",".join(counts), player.cargo_count(), pending_signature
	]
	if signature == _last_sale_signature:
		_refresh_sale_action_state()
		return
	_last_sale_signature = signature
	for child in %SaleRows.get_children():
		child.queue_free()
	_sale_selection = {}
	_sale_selected_slots.clear()
	for good_id in GameData.get_goods_ordered(GameState.content):
		if player.held_count(good_id) <= 0:
			continue
		_sale_selection[good_id] = 0
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var name_label := Label.new()
		name_label.custom_minimum_size = Vector2(110, 0)
		name_label.text = "%s ×%d" % [GameData.get_good_name(GameState.content, good_id), player.held_count(good_id)]
		row.add_child(name_label)
		var minus := Button.new()
		minus.text = "-"
		var gid := String(good_id)
		minus.pressed.connect(func(): _bump_sale(gid, -1))
		row.add_child(minus)
		var count_label := Label.new()
		count_label.name = "Count"
		count_label.custom_minimum_size = Vector2(28, 0)
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		count_label.text = "0"
		row.add_child(count_label)
		var plus := Button.new()
		plus.text = "+"
		plus.pressed.connect(func(): _bump_sale(gid, 1))
		row.add_child(plus)
		%SaleRows.add_child(row)
	_rebuild_console_cargo()
	_refresh_sale_action_state()


func _rebuild_console_cargo() -> void:
	_clear_children_now(_cargo_grid)
	var player := _hud_owner()
	for slot_index in player.warehouse_capacity:
		var button := Button.new()
		button.name = "CargoSlot_%d" % slot_index
		button.focus_mode = Control.FOCUS_NONE      # 点货舱格后空格仍 = 主按钮（确认出售 / 丢失）
		# CargoSlot 外框固定 48×48；normal/selected 源图尺寸不同，只能在固定容器内换肤。
		button.custom_minimum_size = _cargo_slot_size()
		button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		button.toggle_mode = true
		button.add_theme_stylebox_override("normal", _transparent_style())
		button.add_theme_stylebox_override("hover", _transparent_style())
		button.add_theme_stylebox_override("pressed", _transparent_style())
		button.add_theme_stylebox_override("focus", _transparent_style())
		button.add_theme_stylebox_override("disabled", _transparent_style())
		var plate := TextureRect.new()
		plate.name = "CargoPlate"
		plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		plate.texture = _cargo_plate_texture(slot_index >= player.warehouse_slots.size(), false)
		plate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		plate.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 空格保留暗槽表达总容量；不显示图标与数量。
		plate.modulate = _cargo_empty_modulate() if slot_index >= player.warehouse_slots.size() else Color.WHITE
		button.add_child(plate)
		var glow := TextureRect.new()
		glow.name = "SelectedGlow"
		glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		glow.texture = TRADE_SELECTED_GLOW_TEXTURE if _lshu == null else _lshu.tex("pocket_sel")
		glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		glow.visible = false
		button.add_child(glow)
		if slot_index < player.warehouse_slots.size():
			var good_id := String(player.warehouse_slots[slot_index])
			var good_name := GameData.get_good_name(GameState.content, good_id)
			var event_exchange_selected := (
				_is_pending_event_exchange()
				and _event_exchange_give_good == good_id
				and player.warehouse_slots.find(good_id) == slot_index
			)
			var icon := TextureRect.new()
			icon.name = "CargoIcon"
			icon.texture = _hud_good_texture(good_id)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon.size = Vector2(CARGO_ICON_PX, CARGO_ICON_PX)
			# 相对中心略向左上，为右下数量留空。
			icon.position = Vector2(
				(CARGO_SLOT_PX - CARGO_ICON_PX) * 0.5 - 1.0,
				(CARGO_SLOT_PX - CARGO_ICON_PX) * 0.5 - 2.0
			)
			if _lshu != null:
				# 挎包口袋：L叔 图标放大，口袋下沿写货名
				icon.texture = _lshu_good_texture(good_id)
				icon.size = Vector2(LSHU_POCKET_ICON_PX, LSHU_POCKET_ICON_PX)
				icon.position = Vector2((LSHU_POCKET_SIZE.x - LSHU_POCKET_ICON_PX) * 0.5, 22.0)
			button.add_child(icon)
			if _lshu != null:
				var name_tag := Label.new()
				name_tag.name = "CargoName"
				name_tag.text = good_name
				_lshu_style(name_tag, 20, LshuKit.CREAM, "title")
				name_tag.add_theme_color_override("font_outline_color", Color("#4A2C1A"))
				name_tag.add_theme_constant_override("outline_size", 6)
				name_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				name_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
				name_tag.position = Vector2(0, 84)
				name_tag.size = Vector2(LSHU_POCKET_SIZE.x, 26)
				button.add_child(name_tag)
			# 船舱的每一格代表一张实体货物卡。不要把同种货物的总数
			# 重复画到每张卡上：玉佩×2 应占两个玉佩格，而不是两个都标“2”。
			var badge_wrap := Control.new()
			badge_wrap.name = "SelectedBadge"
			badge_wrap.position = Vector2(2, 2) if _lshu == null else Vector2(6, 4)
			badge_wrap.size = Vector2(28, 14) if _lshu == null else Vector2(56, 28)
			badge_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var badge_texture := TextureRect.new()
			badge_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			badge_texture.texture = TRADE_SEAL_BADGE_TEXTURE
			badge_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			badge_texture.stretch_mode = TextureRect.STRETCH_SCALE
			badge_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
			badge_wrap.add_child(badge_texture)
			var badge := _hud_label(8 if _lshu == null else 16, Color("f2e6c9"), HORIZONTAL_ALIGNMENT_CENTER)
			badge.name = "SelectedBadgeLabel"
			badge.text = (
				"丢失"
				if _is_pending_loss_decision()
				else "交出" if _is_pending_event_exchange() else "出售"
			)
			badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 1)
			badge_wrap.add_child(badge)
			badge_wrap.visible = (
				_event_loss_selected_slots.has(slot_index)
				if _is_pending_loss_decision()
				else event_exchange_selected if _is_pending_event_exchange() else _sale_selected_slots.has(slot_index)
			)
			button.add_child(badge_wrap)
			button.button_pressed = (
				_event_loss_selected_slots.has(slot_index)
				if _is_pending_loss_decision()
				else event_exchange_selected if _is_pending_event_exchange() else _sale_selected_slots.has(slot_index)
			)
			button.tooltip_text = (
				"选择失去 %s（1 件，占用 1 格）" % good_name
				if _is_pending_loss_decision()
				else "选择交出 %s（1 件）" % good_name
				if _is_pending_event_exchange()
				else "在直接出售模式点选 %s（1 件，占用 1 格）" % good_name
			)
			button.pressed.connect(func(): _toggle_cargo_slot(slot_index, good_id))
		else:
			button.disabled = true
		_cargo_grid.add_child(button)


## 统一数量角标：真实数字 1–4，无 ×；固定右下，完全落在格子内。
func _make_inventory_count_badge(count: int, on_parchment: bool) -> Control:
	var wrap := Control.new()
	wrap.name = "Count"
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var plate_w := 15.0
	var plate_h := 13.0
	var slot := CARGO_SLOT_PX
	wrap.position = Vector2(slot - 3.0 - plate_w, slot - 3.0 - plate_h)
	wrap.size = Vector2(plate_w, plate_h)
	var plate := ColorRect.new()
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.color = Color(0.18, 0.12, 0.08, 0.55 if on_parchment else 0.72)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(plate)
	var ink := HudStyle.PARCHMENT_LIGHT if on_parchment else Color("FFF1BD")
	var label := _hud_styled_label(
		HudStyle.FONT_HEADING_SEMIBOLD, HudStyle.SIZE_COUNT_BADGE, ink, HORIZONTAL_ALIGNMENT_CENTER
	)
	label.name = "CountValue"
	label.text = str(count)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	wrap.add_child(label)
	return wrap


func _toggle_cargo_slot(slot_index: int, good_id: String) -> void:
	if not _can_accept_human():
		return
	if _lshu_discard_mode:
		if _lshu_discard_slots.has(slot_index):
			_lshu_discard_slots.erase(slot_index)
		else:
			_lshu_discard_slots[slot_index] = true
		_refresh_cargo_slot_visuals()
		_refresh_round_console()
		return
	if slot_index < 0 or slot_index >= _cargo_grid.get_child_count():
		return
	var button: Button = _cargo_grid.get_child(slot_index)
	if _fun.handles_pocket():
		_fun.on_pocket(good_id)
		return
	if _is_pending_loss_decision():
		if good_id not in _pending_loss_decision().get("legal_give_goods", []):
			if _fun.loss_filter_active():
				_fun.on_illegal_loss_pocket(good_id)   # 卡上没说这件：告诉孩子是哪几样（不再不声不响）
			return
		_fun.clear_loss_hint()
		var required := _event_loss_required_count()
		if _event_loss_selected_slots.has(slot_index):
			_event_loss_selected_slots.erase(slot_index)
		elif _event_loss_selected_slots.size() < required:
			_event_loss_selected_slots[slot_index] = true
		_refresh_cargo_slot_visuals()
		_set_feedback(_event_loss_prompt(), COLOR_INFO)
		_refresh_action_buttons()
		return
	if _is_pending_event_exchange():
		_on_event_exchange_give_selected(good_id)
		return
	if GameState.phase == GameState.Phase.TRADE and _lshu != null and _lshu.market_mode == "trade" and not bool(get_meta("_pocket_to_row", false)):
		# L叔 市集：点挎包口袋 = 点这件货的「直接卖」那一行（复检 TE-7）
		for i in _lshu_row_src.size():
			if int((_lshu_row_src[i] as Dictionary).get("sale_slot", -1)) == slot_index:
				set_meta("_pocket_to_row", true)
				_lshu_select_row(i)
				set_meta("_pocket_to_row", false)
				return
	if GameState.phase == GameState.Phase.TRADE:
		# 比例兑换模式只镜像交出货物，不让船舱点击篡改模型。
		if _trade_panel_mode != TradePanelMode.DIRECT_SALE:
			_refresh_cargo_slot_visuals()
			return
		if _sale_selected_slots.has(slot_index):
			_sale_selected_slots.erase(slot_index)
		else:
			_sale_selected_slots[slot_index] = true
		_rebuild_sale_selection_from_slots()
		_refresh_cargo_slot_visuals()
		_refresh_direct_sale_view()
		_refresh_sale_action_state()
		_refresh_round_console()
		return
	var delta := 1 if button.button_pressed else -1
	_sale_selection[good_id] = clampi(
		int(_sale_selection.get(good_id, 0)) + delta,
		0,
		GameState.current_player().held_count(good_id)
	)
	_refresh_cargo_slot_visuals()
	_refresh_sale_action_state()


func _cargo_slot_size() -> Vector2:
	return Vector2(CARGO_SLOT_PX, CARGO_SLOT_PX) if _lshu == null else LSHU_POCKET_SIZE


## 旧卷轴：空格用普通格压暗；L叔 挎包：空口袋有自己的贴图（带「+」），选中时口袋不换、外面套金光框
func _cargo_plate_texture(empty: bool, selected: bool) -> Texture2D:
	if _lshu != null:
		return _lshu.tex("pocket_empty" if empty else "pocket")
	return TRADE_CARGO_SELECTED_TEXTURE if selected else TRADE_CARGO_NORMAL_TEXTURE


func _cargo_empty_modulate() -> Color:
	return Color(0.62, 0.62, 0.62, 0.82) if _lshu == null else Color.WHITE


func _refresh_cargo_slot_visuals() -> void:
	if _cargo_grid == null or GameState.players.is_empty():
		return
	var ai_turn := not GameState.players.is_empty() and GameState.current_player().is_ai()
	var give_entry := _trade_selector.give_entry() if GameState.phase == GameState.Phase.TRADE and not ai_turn else {}
	var give_good := ""
	if not give_entry.is_empty() and String(give_entry.get("resource_kind", "")) == "GOOD":
		give_good = String(give_entry.get("resource_id", ""))
	var player := _hud_owner()
	for child in _cargo_grid.get_children():
		if not child is Button:
			continue
		var button: Button = child
		var slot_index := button.get_index()
		var plate := button.get_node_or_null("CargoPlate") as TextureRect
		if slot_index >= player.warehouse_slots.size():
			if plate != null:
				plate.texture = _cargo_plate_texture(true, false)
				plate.modulate = _cargo_empty_modulate()
			continue
		var good_id := String(player.warehouse_slots[slot_index])
		var selected := false
		if ai_turn:
			selected = false
		elif _lshu_discard_mode:
			selected = _lshu_discard_slots.has(slot_index)
		elif _fun.handles_pocket():
			selected = _fun.selected_good() == good_id and player.warehouse_slots.find(good_id) == slot_index
		elif _is_pending_loss_decision():
			selected = _event_loss_selected_slots.has(slot_index)
		elif _is_pending_event_exchange():
			selected = (
				_event_exchange_give_good == good_id
				and player.warehouse_slots.find(good_id) == slot_index
			)
		else:
			selected = (
				GameState.phase == GameState.Phase.TRADE
				and _trade_panel_mode == TradePanelMode.DIRECT_SALE
				and _sale_selected_slots.has(slot_index)
			)
		# 碎碎平安 / 呦呦鹿鸣：卡上没说的货格压暗（点了会告诉孩子卡上说的是哪几样）
		var dim: bool = not ai_turn and _is_pending_loss_decision() and _fun.loss_filter_active() and not _fun.loss_legal(good_id)
		button.modulate = Color(1, 1, 1, 0.38) if dim else Color.WHITE
		var mirror := (
			not _lshu_discard_mode
			and (_lshu == null or _lshu_row_picked)
			and GameState.phase == GameState.Phase.TRADE
			and _trade_panel_mode in [TradePanelMode.EXCHANGE, TradePanelMode.CARD_SELL]
			and not give_good.is_empty()
			and good_id == give_good
		)
		button.button_pressed = selected or mirror
		if plate != null:
			plate.texture = _cargo_plate_texture(false, selected or mirror)
			plate.modulate = Color.WHITE
		var glow := button.get_node_or_null("SelectedGlow") as TextureRect
		if glow != null:
			glow.visible = selected or mirror
		var badge := button.get_node_or_null("SelectedBadge") as Control
		if badge != null:
			badge.visible = selected
			var badge_label := badge.get_node_or_null("SelectedBadgeLabel") as Label
			if badge_label != null:
				badge_label.text = (
					"丢掉" if _lshu_discard_mode
					else "丢失" if _is_pending_loss_decision() or _fun.handles_pocket()
					else "交出" if _is_pending_event_exchange() else "出售"
				)


func _rebuild_sale_selection_from_slots() -> void:
	_sale_selection.clear()
	if GameState.players.is_empty():
		return
	var player := GameState.current_player()
	var stale: Array = []
	for raw_index in _sale_selected_slots:
		var slot_index := int(raw_index)
		if slot_index < 0 or slot_index >= player.warehouse_slots.size():
			stale.append(raw_index)
			continue
		var good_id := String(player.warehouse_slots[slot_index])
		_sale_selection[good_id] = int(_sale_selection.get(good_id, 0)) + 1
	for raw_index in stale:
		_sale_selected_slots.erase(raw_index)


func _bump_sale(good_id: String, delta: int) -> void:
	if not _can_accept_human():
		return
	var player := GameState.current_player()
	_sale_selection[good_id] = clampi(int(_sale_selection.get(good_id, 0)) + delta, 0, player.held_count(good_id))
	for row in %SaleRows.get_children():
		var gid := _row_good_id(row)
		if gid == good_id:
			row.get_node("Count").text = str(_sale_selection[good_id])
	_refresh_sale_action_state()


func _row_good_id(row: HBoxContainer) -> String:
	var index: int = row.get_index()
	var keys: Array = _sale_selection.keys()
	keys.sort()
	return keys[index] if index < keys.size() else ""


func _refresh_sale_action_state() -> void:
	var allow := _can_accept_human()
	var phase := GameState.phase
	if phase == GameState.Phase.TRADE and _trade_panel_mode == TradePanelMode.DIRECT_SALE:
		_rebuild_sale_selection_from_slots()
	var quote := TradeSystem.get_direct_sale_quote(GameState.current_player(), _sale_selection)
	var total := int(quote.get("total_items", 0))
	var silver_gain := int(quote.get("silver_gain", 0))
	%SalePreviewLabel.text = "预计获得：%d 白银" % silver_gain
	%SaleButton.text = "直接出售（+%d 白银）" % silver_gain
	%DiscardButton.text = "丢弃 %d 件" % total
	%SaleButton.visible = phase == GameState.Phase.TRADE
	%SaleButton.disabled = not allow or not bool(quote.get("can_sell", false)) or phase != GameState.Phase.TRADE
	%DiscardButton.visible = GameState.is_in_turn()
	%DiscardButton.disabled = not allow or total < 1 or EventSystem.has_pending_decision()
	if _console_sale != null:
		_console_sale.text = "直接出售（+%d 银）" % silver_gain
		_console_sale.disabled = not allow or not bool(quote.get("can_sell", false)) or phase != GameState.Phase.TRADE
		_console_discard.text = "丢弃 %d 件" % total
		_console_discard.disabled = (
			not allow or total < 1 or not GameState.is_in_turn() or EventSystem.has_pending_decision()
		)
	_refresh_cargo_slot_visuals()


func _refresh_action_buttons() -> void:
	var allow := _can_accept_human()
	var phase := GameState.phase
	var player: PlayerState = GameState.current_player() if not GameState.players.is_empty() else null
	%RollButton.visible = phase == GameState.Phase.ROLL_DIE
	%RollButton.disabled = not allow
	var move_phase := phase == GameState.Phase.MOVE_OR_EVENT
	%StayButton.visible = move_phase and _board_selecting
	%StayButton.disabled = not allow
	%ConfirmMoveButton.visible = move_phase and _board_selecting
	%ConfirmMoveButton.disabled = not allow
	%SwitchButton.visible = move_phase and player != null and MovementSystem.can_switch_transport(player)
	%SwitchButton.disabled = not allow
	%ProceedButton.visible = move_phase
	%ProceedButton.disabled = not allow
	%SkipTradeButton.visible = phase == GameState.Phase.TRADE
	%SkipTradeButton.disabled = not allow
	%EndTurnButton.visible = phase == GameState.Phase.END_TURN
	%EndTurnButton.disabled = not allow
	_update_trade_preview_and_buttons()
	%BoardView.set_input_enabled(allow and _board_selecting)
	# 旧按钮只保留信号/测试契约，不再出现在玩家界面。
	%RollButton.visible = false
	%StayButton.visible = false
	%ConfirmMoveButton.visible = false
	%SwitchButton.visible = false
	%ProceedButton.visible = false
	%SkipTradeButton.visible = false
	%EndTurnButton.visible = false
	_refresh_cargo_slot_visuals()
	if _primary_action != null:
		_refresh_round_console()


func _refresh_round_console() -> void:
	if _console == null or GameState.players.is_empty():
		return
	var phase := GameState.phase
	var player := GameState.current_player()
	var allow := _can_accept_human() and not _primary_action_guarded
	var ai_turn := player.is_ai()
	if _hud_action_heading != null:
		_hud_action_heading.text = "本回合行动"
	if _hud_round_caption != null:
		_hud_round_caption.text = "第 %d 轮" % (GameState.round_index + 1)
	_paint_turn_steps(phase, ai_turn)

	_roll_page.visible = not ai_turn and phase == GameState.Phase.ROLL_DIE
	_move_page.visible = not ai_turn and phase in [GameState.Phase.MOVE_OR_EVENT, GameState.Phase.OPEN_TRADE_ROUTE]
	_trade_page.visible = not ai_turn and phase == GameState.Phase.TRADE
	_end_page.visible = not ai_turn and phase in [GameState.Phase.END_TURN, GameState.Phase.GAME_OVER]
	_ai_page.visible = ai_turn and phase != GameState.Phase.GAME_OVER
	_sync_event_exchange_panel()
	var event_exchange_pending := _is_pending_event_exchange()
	var loss_pending := _is_pending_loss_decision()
	var fun_pending: bool = not ai_turn and _fun.owns_primary()
	var moving := _move_animating or player.move_confirmed
	var event_face := player.die_result != null and DiceSystem.is_event_face(player.die_result)
	_move_title.text = (
		"商旅交换" if event_exchange_pending
		else "意外事件" if loss_pending
		else "行路中" if _move_animating
		else "已抵达" if player.move_confirmed
		else "选择目的地"
	)
	_move_budget.visible = not event_exchange_pending and not moving
	_move_hint.visible = false
	_hud_move_destination.visible = not event_exchange_pending

	var face_text := DiceSystem.face_text(player.die_result) if player.die_result != null else ""
	_dice_face.text = _dice_symbol(player.die_result)
	if _dice_3d != null and not _dice_3d.is_rolling() and player.die_result != null:
		_dice_3d.snap_to_face(player.die_result)
	if _dice_3d != null:
		# 本回合还没掷：骰子停在上回合的点数会像「已经掷过」，压暗表示待掷
		var waiting_roll := player.die_result == null and not _dice_3d.is_rolling() and not _dice_rolling
		_dice_3d.modulate.a = 0.45 if waiting_roll and _lshu == null else 1.0
	_dice_meaning.text = (
		"掷出 1–5 步，或抽一张意外事件"
		if player.die_result == null
		else "本回合骰面：%s" % face_text
	)
	var chosen_steps := maxi(_selected_path.size() - 1, 0)
	# 数字骰只显示「可走 N 步」一处；事件骰额外说明步数来自事件
	_hud_move_dice.visible = loss_pending or (event_face and not event_exchange_pending and not moving)
	_hud_move_dice.text = "意外事件 · 可移动 0–%d 步" % player.movement_budget
	# 掷出来能走几步（选了目的地也不减：下面一行和主按钮会写「需要 / 出发 N 步」）
	_move_budget.text = "可走 %d 步" % player.movement_budget
	if loss_pending:
		var required_loss := _event_loss_required_count()
		var selected_loss := _event_loss_selected_slots.size()
		_hud_move_dice.text = "事件选择"
		_move_budget.visible = true
		_move_budget.text = "选择失去的货物"
		_hud_move_destination.text = "已选择 %d / %d 件" % [selected_loss, required_loss]
		_hud_move_destination.add_theme_color_override(
			"font_color", HudStyle.PARCHMENT_LIGHT if selected_loss == required_loss else HudStyle.INK_WEAK
		)
		_hud_move_destination.add_theme_stylebox_override(
			"normal",
			_panel_style(
				HudStyle.FAILURE if selected_loss == required_loss else HudStyle.PARCHMENT_LIGHT,
				HudStyle.CINNABAR_TEXT if selected_loss == required_loss else HudStyle.INK_WEAK,
				1
			)
		)
	elif moving:
		var here := GameData.get_node_display_name(GameState.content, player.current_node_id)
		var interchange := GameData.is_transport_interchange(GameState.content, player.current_node_id)
		_hud_move_destination.text = (
			"正在前往 %s" % here if _move_animating
			else "%s · 海陆交叉点" % here if interchange
			else here
		)
		_hud_move_destination.add_theme_color_override("font_color", HudStyle.INK_STRONG)
		_hud_move_destination.add_theme_stylebox_override("normal", _panel_style(HudStyle.PARCHMENT_LIGHT, HudStyle.GOLD, 1))
	elif not _move_pick_made():
		_hud_move_destination.text = "尚未选择目的地"
		_hud_move_destination.add_theme_color_override("font_color", HudStyle.INK_WEAK)
		_hud_move_destination.add_theme_stylebox_override("normal", _panel_style(HudStyle.PARCHMENT_LIGHT, HudStyle.INK_WEAK, 1))
	elif _stay_picked:
		var here_name := GameData.get_node_display_name(GameState.content, player.current_node_id)
		_hud_move_destination.text = "%s · 原地停留" % here_name
		_hud_move_destination.add_theme_color_override("font_color", HudStyle.PARCHMENT_LIGHT)
		_hud_move_destination.add_theme_stylebox_override(
			"normal", _panel_style(HudStyle.FAILURE, HudStyle.CINNABAR_TEXT, 1)
		)
	else:
		var node_id := String(_selected_path.back())
		var destination := GameData.get_node_display_name(GameState.content, node_id)
		_hud_move_destination.text = "%s · 需要 %d 步" % [destination, chosen_steps]
		_hud_move_destination.add_theme_color_override("font_color", HudStyle.PARCHMENT_LIGHT)
		_hud_move_destination.add_theme_stylebox_override(
			"normal", _panel_style(HudStyle.FAILURE, HudStyle.CINNABAR_TEXT, 1)
		)
	_console_switch_button.visible = false
	_console_switch_button.disabled = not allow
	_ai_summary.text = _ai_current_step_summary(player)
	_refresh_end_page(player)

	# AI 态没有玩家可执行动作：主按钮位显示羊皮纸指引牌（不是一枚点不动的红按钮）。
	_primary_action.visible = phase != GameState.Phase.GAME_OVER
	_hud_primary_wrap.visible = phase != GameState.Phase.GAME_OVER
	_primary_action.disabled = not allow
	var hint_mode := false
	var secondary := []          # [[text, emphasis, action], …] → 次要按钮（最多两枚）
	if ai_turn:
		_primary_action.text = "%s行动中…" % player.display_name
		_primary_action.disabled = true
		hint_mode = true
		if _lshu != null and phase != GameState.Phase.GAME_OVER:
			secondary.append(["正常速度" if lshu_ai_fast else "电脑走快点", false, "ai_fast"])
	else:
		match phase:
			GameState.Phase.ROLL_DIE:
				_primary_action.text = "掷骰"
				if _dice_rolling or (_dice_3d != null and _dice_3d.is_rolling()):
					_primary_action.text = "掷骰中…"
					_primary_action.disabled = true
			GameState.Phase.MOVE_OR_EVENT:
				if fun_pending:
					# 趣味事件的选择面板：没选时主按钮是灰的，按钮上写要确认的那一项
					_primary_action.text = _fun.primary_text()
					_primary_action.disabled = not allow or not _fun.primary_enabled()
				elif event_exchange_pending:
					_primary_action.text = "确认交换"
					_primary_action.disabled = (
						not allow
						or _event_exchange_submitting
						or not _event_exchange_selection_valid()
					)
					secondary.append(["重选", false, "reselect_exchange"])
				elif loss_pending:
					var required_loss := _event_loss_required_count()
					var selected_loss := _event_loss_selected_slots.size()
					_primary_action.text = "确认丢失（%d/%d）" % [selected_loss, required_loss]
					_primary_action.disabled = not allow or selected_loss != required_loss
				elif _move_animating:
					_primary_action.text = "行路中…"
					_primary_action.disabled = true
					hint_mode = true
				elif player.move_confirmed or (event_face and not player.pending_event_needs_move):
					# 自动推进时只有海陆交叉点会停在这里：可先换乘，再进入贸易
					_primary_action.text = "进入贸易" if auto_advance else "继续"
					if MovementSystem.can_switch_transport(player):
						secondary.append([_switch_button_text(player), false, "switch"])
				else:
					# 先选再确认：没选时主按钮位是指引牌（点不动）；选了目的地 =「出发（N 步）」，
					# 选了「原地停留」=「就停在这里」——只有按它才真的走 / 停。次要按钮一直在同一位置，连点不会点到别的
					if not _move_pick_made():
						_primary_action.text = _pad_says("在地图上点选目的地", "十字键选目的地")
						_primary_action.disabled = true
						hint_mode = true
					elif _stay_picked:
						_primary_action.text = STAY_CONFIRM_TEXT
						_primary_action.disabled = not allow
					else:
						_primary_action.text = "出发（%d 步）" % chosen_steps
						_primary_action.disabled = not allow
					secondary.append(["原地停留", false, "stay"])
					if MovementSystem.can_switch_transport(player):
						secondary.append([_switch_button_text(player), false, "switch"])
			GameState.Phase.OPEN_TRADE_ROUTE:
				_primary_action.text = "进入贸易"
			GameState.Phase.TRADE:
				if not _trade_possible_here(player):
					# 无可做的交易：唯一的合法出路就是结束回合，直接做成主按钮
					_primary_action.text = "结束回合"
				else:
					_refresh_trade_primary(player, allow)
					# L叔 界面：有能做的交易时不强调「不交易」（主按钮灰着只是因为还没选行，别把孩子引去放弃，复检 TE-2）
					secondary.append(["不交易，结束回合", _primary_action.disabled and _lshu == null, "skip_end"])
			GameState.Phase.END_TURN:
				_primary_action.text = "结束回合"
			_:
				_primary_action.text = "继续"
	# 真人抽事件卡的演出期间，底下先别亮结果和按钮：卡还背面朝上，步数、目的地、交换面板就已经摆出来，
	# 按钮看着能点又点不了（复检 NOV-2）。演出结束（_on_event_presentation_finished）再照常刷新
	if not ai_turn and _human_event_presenting():
		_primary_action.text = (
			_pad_says("点卡片旁边的「继续」", "按 A 继续") if _event_card_revealed()
			else _pad_says("先翻开卡片，再点「继续」", "十字键挑卡，按 A 翻开")
		)
		_primary_action.disabled = true
		hint_mode = true
		secondary = []
	_apply_primary_mode(hint_mode)
	_apply_secondary_buttons(secondary, allow)
	_refresh_primary_skin()
	_refresh_next_step_prompt(phase, player, ai_turn, chosen_steps)
	if _lshu_discard_mode:
		if not _lshu_discard_allowed():
			_lshu_discard_mode = false
			_lshu_discard_slots.clear()
			_refresh_cargo_slot_visuals()
		else:
			_lshu_apply_discard_mode(allow)
	_apply_idle_emphasis()
	_refresh_log_text()
	_lshu_refresh()


func _refresh_trade_primary(player: PlayerState, allow: bool) -> void:
	if _skip_end_pick_active():
		_primary_action.text = SKIP_END_CONFIRM_TEXT
		_primary_action.disabled = not allow
		return
	if _lshu != null and (
		(not _lshu_row_picked and _trade_panel_mode != TradePanelMode.DIRECT_SALE)
		or (_trade_panel_mode == TradePanelMode.DIRECT_SALE and _sale_selected_slots.is_empty())
	):
		_primary_action.text = _pad_says("先点一行选好", "十字键选一行")
		_primary_action.disabled = true
		return
	if _trade_panel_mode == TradePanelMode.DIRECT_SALE:
		_rebuild_sale_selection_from_slots()
		var sale_quote := TradeSystem.get_direct_sale_quote(player, _sale_selection)
		var sale_gain := int(sale_quote.get("silver_gain", 0))
		var can_sell := bool(sale_quote.get("can_sell", false))
		_primary_action.text = "确认出售（+%d 白银）" % sale_gain if can_sell else ("先在船舱选货物" if _lshu == null else "先选要卖的货")
		_primary_action.disabled = not allow or not can_sell or _trade_submitting
	elif _trade_panel_mode == TradePanelMode.BUY:
		var buy_meta := _selected_trade_meta()
		var can_buy := not buy_meta.is_empty() and int(buy_meta.get("times", 0)) > 0
		var silver_cost := _trade_selector.give_total() if can_buy else 0
		_primary_action.text = "确认买入（-%d 白银）" % silver_cost if can_buy else "当前无法买入"
		_primary_action.disabled = not allow or not can_buy or _trade_submitting
	elif _trade_panel_mode == TradePanelMode.CARD_SELL:
		var sale_meta := _selected_trade_meta()
		var can_card_sell := not sale_meta.is_empty() and int(sale_meta.get("times", 0)) > 0
		var silver_gain := _trade_selector.receive_total() if can_card_sell else 0
		_primary_action.text = "确认按卡售银（+%d 白银）" % silver_gain
		_primary_action.disabled = not allow or not can_card_sell or _trade_submitting
	else:
		var trade_meta := _selected_trade_meta()
		var can_exchange := not trade_meta.is_empty() and int(trade_meta.get("times", 0)) > 0
		_primary_action.text = "确认兑换"
		_primary_action.disabled = not allow or not can_exchange or _trade_submitting


func _switch_button_text(player: PlayerState) -> String:
	return "换乘商船" if player.active_transport == GameData.Transport.CAMEL else "换乘骆驼"


func _paint_turn_steps(phase: int, ai_turn: bool) -> void:
	var current := -1
	if not ai_turn:
		match phase:
			GameState.Phase.ROLL_DIE:
				current = 0
			GameState.Phase.MOVE_OR_EVENT, GameState.Phase.OPEN_TRADE_ROUTE:
				current = 1
			GameState.Phase.TRADE, GameState.Phase.END_TURN:
				current = 2
	for i in _hud_step_labels.size():
		var label := _hud_step_labels[i]
		var active := i == current
		HudStyle.apply_font(
			label,
			HudStyle.FONT_HEADING_SEMIBOLD if active else HudStyle.FONT_BODY_REGULAR,
			HudStyle.SIZE_CARGO_TITLE if active else HudStyle.SIZE_BODY,
			HudStyle.CINNABAR_TEXT if active else HudStyle.INK_WEAK
		)
		label.modulate.a = 1.0 if active or current < 0 or i > current else 0.6


## 主按钮位的两种形态：红底按钮，或「下一步在地图上」时的羊皮纸指引牌（不可点，文字是指令）。
func _apply_primary_mode(hint_mode: bool) -> void:
	if _primary_hint_plaque != null:
		_primary_hint_plaque.visible = hint_mode and _hud_primary_wrap.visible
	if _primary_skin != null:
		_primary_skin.visible = not hint_mode
	_primary_action.mouse_filter = Control.MOUSE_FILTER_IGNORE if hint_mode else Control.MOUSE_FILTER_STOP
	var disabled_text := HudStyle.INK_STRONG if hint_mode else Color(HudStyle.PARCHMENT_LIGHT, 0.72)
	_primary_action.add_theme_color_override("font_disabled_color", disabled_text)
	_primary_action.add_theme_color_override(
		"font_outline_color", Color(0, 0, 0, 0) if hint_mode else HudStyle.TEXT_OUTLINE_DARK
	)
	_primary_action.set_meta("hint_mode", hint_mode)
	if _lshu != null:
		_lshu_paint_primary(hint_mode)


func _apply_secondary_buttons(specs: Array, allow: bool) -> void:
	var buttons := [_secondary_action, _secondary_alt_action]
	for i in buttons.size():
		var button: Button = buttons[i]
		if button == null:
			continue
		var on := i < specs.size()
		button.visible = on
		if not on:
			continue
		button.text = String(specs[i][0])
		button.set_meta("action", String(specs[i][2]))
		# 「电脑走快点」在电脑回合里用，不受真人输入锁影响
		button.disabled = not allow and String(specs[i][2]) != "ai_fast"
		var emphasis := bool(specs[i][1]) or (_idle_hint_on and _primary_action.disabled)
		if bool(button.get_meta("emphasis", false)) != emphasis:
			_style_secondary_button(button, emphasis)
	if _hud_secondary_row != null:
		# 空着也保留高度：主按钮不因有无次要操作而上下跳
		_hud_secondary_row.visible = GameState.phase != GameState.Phase.GAME_OVER


func _refresh_end_page(player: PlayerState) -> void:
	if _end_summary == null:
		return
	var end_title := _end_page.get_node_or_null("PhaseTitleEnd") as Label
	if end_title != null:
		end_title.text = "交易完成" if player.trade_action_used else "本回合结束"
	_end_summary.text = (
		_turn_result_text if not _turn_result_text.is_empty() else "本回合没有交易"
	)


func _ai_current_step_summary(player: PlayerState) -> String:
	# 只读 GameState 推导当前步骤；不能复用上一位玩家留下的 _console_feedback，
	# 否则 AI 页会错误显示“对局开始，请玩家掷骰”。
	var city := GameData.get_node_display_name(GameState.content, player.current_node_id)
	match GameState.phase:
		GameState.Phase.ROLL_DIE:
			return "当前位置：%s\nAI 正在掷骰…" % city
		GameState.Phase.MOVE_OR_EVENT:
			if player.move_confirmed:
				return "当前位置：%s\nAI 正在抵达目的地…" % city
			if player.movement_budget > 0:
				return "当前位置：%s\nAI 正在规划路线…\n剩余 %d 步" % [city, player.movement_budget]
			return "当前位置：%s\nAI 正在结束移动…" % city
		GameState.Phase.OPEN_TRADE_ROUTE:
			return "当前位置：%s\nAI 正在开通商道…" % city
		GameState.Phase.TRADE:
			return "当前位置：%s\nAI 正在查看当地贸易…" % city
		GameState.Phase.END_TURN:
			return "当前位置：%s\nAI 正在结束回合…" % city
		_:
			return "AI 正在规划路线…"


## 「下一步」提示：只说一件事——现在该做什么。结果/反馈留在底部结果行，不再互相覆盖。
func _refresh_next_step_prompt(phase: int, player: PlayerState, ai_turn: bool, chosen_steps: int) -> void:
	if _hud_prompt == null:
		return
	var prompt := ""
	if ai_turn:
		var n_players := GameState.players.size()
		var nxt: PlayerState = GameState.players[(GameState.current_player_index + 1) % n_players] if n_players > 0 else null
		if nxt != null and nxt.is_ai():
			prompt = "%s在走，下一个是%s" % [player.display_name, nxt.display_name]
		else:
			prompt = (
				"%s在走，走完就轮到你" % player.display_name if _lshu_human_count() <= 1
				else "%s在走，走完轮到%s" % [player.display_name, _next_human_name()]
			)
	else:
		match phase:
			GameState.Phase.ROLL_DIE:
				prompt = (
					"骰子滚动中…"
					if _dice_rolling or (_dice_3d != null and _dice_3d.is_rolling())
					else _pad_says("点「掷骰」开始本回合（空格键）", "按 A 掷骰")
				)
				# 电脑抽的卡改了你的白银 / 货：结果和原因留在这里，掷骰后才收（不被「轮到你了」冲掉）
				var notes: Array = _fun.notices_for(player.player_id)
				if not notes.is_empty():
					prompt = "\n".join(notes) + "\n" + prompt
			GameState.Phase.MOVE_OR_EVENT:
				if _fun.owns_primary():
					prompt = _fun.prompt()
				elif _is_pending_event_exchange():
					prompt = _event_exchange_prompt()
				elif _is_pending_loss_decision():
					prompt = _event_loss_prompt()
				elif _move_animating:
					prompt = "到达后自动进入当地贸易" if auto_advance else ""
				elif player.move_confirmed or (DiceSystem.is_event_face(player.die_result) and not player.pending_event_needs_move):
					prompt = (
						"海陆交叉点：可先换乘，再进入贸易"
						if MovementSystem.can_switch_transport(player)
						else _pad_says("点「继续」进入贸易", "按 A 进入贸易")
					)
				elif not _move_pick_made():
					prompt = _pad_says(MOVE_PROMPT_PICK, "十字键选一个亮着的地方（Y 原地停留）")
				elif _stay_picked:
					prompt = _pad_says(MOVE_PROMPT_STAY_PICKED, "按 A 就停在这里，十字键改选")
				else:
					prompt = _pad_says(MOVE_PROMPT_DEST_PICKED % chosen_steps, "按 A 出发（%d 步），十字键改选" % chosen_steps)
				# 趣味事件选完的结果（「付1块白银。」「猜对了……」）留到走完这一步
				var note: String = _fun.move_note_for(player)
				if not note.is_empty() and not _fun.owns_primary() and not _is_pending_loss_decision() and not _is_pending_event_exchange():
					prompt = note + "\n" + prompt
			GameState.Phase.TRADE:
				if not _trade_possible_here(player):
					prompt = "这里没有可做的交易，结束回合吧"
				elif _skip_end_pick_active():
					prompt = SKIP_END_PROMPT_PICKED
				elif _primary_action.disabled:
					prompt = (
						"换一种交易方式，或不交易结束回合" if _lshu == null
						else _pad_says("点一行选中，再按下面的按钮确认；不想换就不交易", "十字键选一行，再按 A 确认")
					)
				else:
					var summary := _console_trade_preview.text if _console_trade_preview != null else ""
					prompt = summary if not summary.is_empty() else "确认这笔交易（每回合只能交易一次）"
			GameState.Phase.END_TURN:
				prompt = (
					"稍后自动交给%s" % _next_player_name()
					if _auto_end_pending
					else _pad_says("点「结束回合」交给%s" % _next_player_name(), "按 A 结束回合，交给%s" % _next_player_name())
				)
			_:
				prompt = ""
	_hud_prompt.text = prompt
	_hud_prompt.visible = phase != GameState.Phase.GAME_OVER
	# 结束页正文已经写着本回合结果，结果行在此处留位不显字
	if _console_feedback != null:
		_console_feedback.self_modulate.a = 0.0 if phase == GameState.Phase.END_TURN and not ai_turn else 1.0


func _next_player_name() -> String:
	if GameState.players.size() < 2:
		return "下一位"
	var next_player: PlayerState = GameState.players[(GameState.current_player_index + 1) % GameState.players.size()]
	return next_player.display_name


## 下一位真人的名字（电脑回合提示「走完轮到谁」用）
func _next_human_name() -> String:
	var n := GameState.players.size()
	for step in range(1, n + 1):
		var p: PlayerState = GameState.players[(GameState.current_player_index + step) % n]
		if p.is_local_human():
			return p.display_name
	return "下一位"


func _trade_footer_prompt(meta: Dictionary) -> String:
	if meta.is_empty():
		var msg := _trade_block_reason_text()
		return msg if not msg.is_empty() else "请选择交出与获得的货物"
	var times := int(meta.get("times", _trade_selector.times))
	var give := _trade_selector.give_entry()
	var recv := _trade_selector.receive_entry()
	if give.is_empty() or recv.is_empty():
		return "请选择交出与获得的货物"
	if _trade_panel_mode == TradePanelMode.BUY:
		var silver_cost := int(give.get("quantity", 0)) * times
		var good_name := GameData.get_good_name(GameState.content, String(recv.get("resource_id", "")))
		var good_qty := int(recv.get("quantity", 0)) * times
		return "将支付 %d 白银，购得 %s×%d" % [silver_cost, good_name, good_qty]
	if _trade_panel_mode == TradePanelMode.CARD_SELL:
		return "将按城市贸易卡售出 %s，获得 %s" % [
			_format_entry_times(give, times), _format_entry_times(recv, times)
		]
	return "将消耗 %s，获得 %s" % [_format_entry_times(give, times), _format_entry_times(recv, times)]


func _phase_step_index(phase: int) -> int:
	match phase:
		GameState.Phase.ROLL_DIE:
			return 0
		GameState.Phase.MOVE_OR_EVENT, GameState.Phase.OPEN_TRADE_ROUTE:
			return 1
		GameState.Phase.TRADE:
			return 2
		_:
			return 3


func _dice_symbol(result) -> String:
	if result == null:
		return "◆"
	if result is int and result >= 1 and result <= 6:
		return ["⚀", "⚁", "⚂", "⚃", "⚄", "⚅"][int(result) - 1]
	return "✦"


func _refresh_log_text() -> void:
	if _log_text == null:
		return
	var lines: Array[String] = []
	for i in _action_log.size():
		lines.append("[color=#7d5a3a]•[/color] %s" % _action_log[i])
	_log_text.text = "\n".join(lines)


func _show_result() -> void:
	# 这一局打完了：存档不再能接着玩
	if _lshu != null and _lshu_records_progress():
		LshuMatchSave.clear()
	%CityLoreCard.force_close()
	var result: Dictionary = GameState.result
	var lines: Array[String] = []
	var rank := 0
	for entry in result["standings"]:
		rank += 1
		var role := "你"
		for p in GameState.players:
			if p.player_id == entry["player_id"]:
				role = "你" if p.is_local_human() else "AI"
				break
		lines.append("%d. %s（%s）｜白银 %d｜货物 %d" % [rank, entry["display_name"], role, entry["silver"], entry["goods"]])
	var names: Array[String] = []
	for winner_id in result["winner_ids"]:
		for entry in result["standings"]:
			if entry["player_id"] == winner_id:
				names.append(entry["display_name"])
	%ResultTitleLabel.text = "并列获胜：%s" % "、".join(names) if result["is_tie"] else "胜者：%s" % "、".join(names)
	if String(result.get("end_reason", "")) == "TIME":
		lines.append("")
		lines.append("对局已满 %d 分钟，补齐本轮后按白银结算。" % int(round(match_time_limit_sec / 60.0)))
	%ResultListLabel.text = "\n".join(lines)
	%ResultOverlay.visible = true
	if _lshu != null:
		_lshu_show_result()


func _phase_text() -> String:
	match GameState.phase:
		GameState.Phase.SETUP:
			return "准备"
		GameState.Phase.SETUP_TRANSPORT:
			return "确认交通"
		GameState.Phase.ROLL_DIE:
			return "掷骰"
		GameState.Phase.MOVE_OR_EVENT:
			return "移动/事件"
		GameState.Phase.OPEN_TRADE_ROUTE:
			return "开通商道"
		GameState.Phase.TRADE:
			return "贸易"
		GameState.Phase.END_TURN:
			return "结束回合"
		GameState.Phase.GAME_OVER:
			return "已结算"
	return "?"


func _set_feedback(text: String, color: Color) -> void:
	%FeedbackLabel.text = text
	%FeedbackLabel.add_theme_color_override("font_color", color)
	if _console_feedback != null:
		_console_feedback.text = text
		_console_feedback.add_theme_color_override("font_color", color)
		if _lshu != null and not GameState.players.is_empty():
			_lshu_paint_receipt()        # 结果先设好再弹横幅，不慢一拍（复检 TE-3）
	var clean := text.strip_edges()
	if not clean.is_empty() and (_action_log.is_empty() or _action_log.back() != clean):
		_action_log.append(clean)
		while _action_log.size() > 5:
			_action_log.pop_front()
	_refresh_log_text()


func _player_color(color_id: String) -> Color:
	for color in GameData.get_player_colors(GameState.content):
		if color["id"] == color_id:
			return Color(color["color"])
	return HudStyle.INK_STRONG


## 表现层只读验收快照；不接触规则状态，便于自动化验证“单阶段、单主 CTA、无下拉框”。
func get_round_console_debug_state() -> Dictionary:
	## 固定 Tile 架构：图标在 GiveTile/ReceiveTile 的 ResourceIcon，不再统计可销毁的 Button 子树。
	var give_texture_icon_count := 0
	if _trade_give_tile != null:
		var give_icon := _trade_give_tile.get_node_or_null("ResourceIcon") as TextureRect
		if give_icon != null and give_icon.texture != null and give_icon.visible:
			give_texture_icon_count = 1
	var give_choice_count := 0 if _trade_selector == null else _trade_selector.give_candidates.size()
	var receive_choice_count := 0 if _trade_selector == null else _trade_selector.receive_candidates.size()
	if give_choice_count <= 0 and _give_grid != null:
		give_choice_count = _give_grid.get_child_count()
	if receive_choice_count <= 0 and _receive_grid != null:
		receive_choice_count = _receive_grid.get_child_count()
	return {
		"roll_visible": _roll_page.visible,
		"move_visible": _move_page.visible,
		"trade_visible": _trade_page.visible,
		"end_visible": _end_page.visible,
		"primary_text": _primary_action.text,
		"primary_visible": _primary_action.visible,
		"primary_disabled": _primary_action.disabled,
		"event_loss_pending": _is_pending_loss_decision(),
		"event_loss_selected": _event_loss_selected_slots.size(),
		"event_loss_required": _event_loss_required_count(),
		"event_exchange_pending": _is_pending_event_exchange(),
		"event_exchange_panel_visible": _event_exchange_panel != null and _event_exchange_panel.visible,
		"event_exchange_give": _event_exchange_give_good,
		"event_exchange_target": _event_exchange_target,
		"event_exchange_receive": _event_exchange_receive_good,
		"event_exchange_valid": _event_exchange_selection_valid() if _is_pending_event_exchange() else false,
		"secondary_visible": _secondary_action.visible,
		"secondary_texts": [_secondary_action, _secondary_alt_action].filter(func(b): return b.visible).map(func(b): return b.text),
		"secondary_emphasis": [_secondary_action, _secondary_alt_action].filter(func(b): return b.visible).map(func(b): return bool(b.get_meta("emphasis", false))),
		"prompt_text": "" if _hud_prompt == null or not _hud_prompt.visible else _hud_prompt.text,
		"primary_hint_mode": bool(_primary_action.get_meta("hint_mode", false)),
		"move_selected_path": _selected_path.duplicate(),
		"move_stay_picked": _stay_picked,
		"auto_end_pending": _auto_end_pending,
		"idle_hint": _idle_hint_on,
		"turn_toast_visible": _turn_toast != null and _turn_toast.visible,
		"turn_result": _turn_result_text,
		"legacy_give_visible": %GiveOption.visible,
		"legacy_receive_visible": %ReceiveOption.visible,
		"give_icon_count": give_choice_count,
		"give_texture_icon_count": give_texture_icon_count,
		"receive_icon_count": receive_choice_count,
		"cargo_slot_count": _cargo_grid.get_child_count(),
		"cargo_slot_px": CARGO_SLOT_PX,
		"cargo_grid_width_px": CARGO_GRID_WIDTH_PX,
		"public_silver_right_inset_px": PUBLIC_SILVER_RIGHT_INSET_PX,
		"ai_goods_visible": _ai_card_goods != null and _ai_card_goods.visible,
		"ai_goods_count": 0 if _ai_card_goods == null else _ai_card_goods.get_child_count(),
		"action_heading_text": "" if _hud_action_heading == null else _hud_action_heading.text,
		"round_caption_text": "" if _hud_round_caption == null else _hud_round_caption.text,
		"primary_font_size": (
			0 if _primary_action == null else int(_primary_action.get_theme_font_size("font_size"))
		),
		"uses_hud_fonts": (
			HudStyle.uses_hud_font(_hud_current_action)
			and HudStyle.uses_hud_font(_hud_supply)
			and HudStyle.uses_hud_font(_primary_action)
			and HudStyle.uses_hud_font(_console_feedback)
		),
		"log_count": _action_log.size(),
		"player_card_count": _player_cards.get_child_count(),
	}


# ======================================================================
# 「旅行L叔」对局界面（Carlos 2026-09-26：「重新设计对局模式的 UI，希望符合目前的参考图和已经正在开发的
# UI 体系，整体可爱一些，高效一些」；「同时最多 4 个真实玩家在场 PK」）。
# LshuMatchHud 只管外观与摆放；这里把原有功能节点（节点名、信号、处理函数都不变）搬进它的插槽，
# 每次刷新后同步它的显示。交易改成参考图 05 的「一行一个换法」，底层仍是 TradeSelectorModel。
# legacy_hud = true（在加入场景树之前设置）时不搭建，旧卷轴 HUD 原样保留（旧几何测试用）。
# ======================================================================
const LshuMatchHudScript := preload("res://scripts/lshu_ui/lshu_match_hud.gd")
## 「L叔的趣味事件」的界面那一半（选择面板、听声、电脑抽卡的留言、篝火泡泡、揭晓前的白银）
const LshuFunUiScript := preload("res://scripts/lshu_ui/lshu_fun_events_ui.gd")
var _fun: Node
const LshuKit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const LshuSkinScript := preload("res://scripts/lshu_ui/lshu_skin.gd")
const LshuProgressScript := preload("res://scripts/lshu_ui/lshu_progress.gd")
const LshuIconsScript := preload("res://scripts/lshu_ui/lshu_icons.gd")
const LSHU_SEATS_PATH := "res://scripts/lshu_ui/lshu_seats.gd"
## 挎包口袋（设计像素，挎包组整体按 k 缩放）
const LSHU_POCKET_SIZE := Vector2(112, 113)
const LSHU_POCKET_ICON_PX := 62.0
const LSHU_POCKET_GAP := 10
const LSHU_INSET_TWEEN_SEC := 0.35
const LSHU_MODE_NAMES := {0: "买入", 1: "兑换", 2: "直售", 3: "按卡售银"}

var legacy_hud := false
var _lshu: LshuMatchHudScript
var _lshu_primary_skin: Control
var _lshu_market_sig := ""
var _lshu_row_src: Array = []
var _lshu_last_human_id := ""
var _lshu_ai_status: Dictionary = {}
var _lshu_seats: Script
var _lshu_inset := 0.0
var _lshu_inset_goal := -1.0
var _lshu_inset_tween: Tween
var _lshu_menu_armed_ms := 0
var _lshu_win_recorded := false
## 防误触（Carlos 2026-09-26：小孩子会瞎点，要给反悔的机会）：进市集不替玩家预选，点过一行才能按「确认」
var _lshu_row_picked := false
## 挎包丢货（原版：「货仓里的货物可在任何时候丢弃，但不会获得任何白银」）：点「丢货」→ 点口袋选 → 「确认丢掉」
var _lshu_discard_mode := false
var _lshu_discard_slots: Dictionary = {}
## 右下角 L叔 提示条开关（点 L叔 头像切换）；收据横幅去重
var _lshu_hints_on := true
var _lshu_last_toast := ""
## 「电脑走快点」：电脑回合里整体加速（Engine.time_scale），轮到真人立刻恢复；对局计时用真实秒数不受影响
const LSHU_AI_FAST_SCALE := 2.5
var lshu_ai_fast := false
var _lshu_fast_toggled_ms := -10000
var _lshu_saved_time_scale := -1.0


func _build_lshu_hud() -> void:
	if ResourceLoader.exists(LSHU_SEATS_PATH):
		_lshu_seats = load(LSHU_SEATS_PATH) as Script
	_lshu = LshuMatchHudScript.new()
	add_child(_lshu)
	_lshu.build()
	_lshu.z_index = Z_SCROLL
	_lshu.trade_row_pressed.connect(_on_lshu_row_pressed)
	_lshu.trade_row_action.connect(_on_lshu_row_action)
	_lshu.trade_times_pressed.connect(_on_lshu_times_pressed)
	_lshu.mode_tab_pressed.connect(_on_lshu_mode_tab)
	_lshu.dice_pressed.connect(_on_lshu_dice_pressed)
	_lshu.menu_pressed.connect(_on_lshu_menu_pressed)
	_lshu.save_pressed.connect(_on_lshu_save_pressed)
	_lshu.handover_pressed.connect(_on_lshu_handover_go)
	_lshu.discard_toggled.connect(_on_lshu_discard_toggled)
	_lshu.exchange_give_pressed.connect(_on_event_exchange_give_selected)
	_lshu.exchange_target_pressed.connect(_on_lshu_exchange_target)
	_lshu.exchange_receive_pressed.connect(_on_event_exchange_receive_selected)
	_lshu.choice_pressed.connect(func(id: String) -> void: _fun.on_pick(id))
	_lshu.campfire_dismissed.connect(func() -> void: _fun.on_campfire_dismissed())
	# 市集面板收起 / 展开：事件抽卡、城市图鉴按露出来的地图重新摆
	_lshu.market_collapse_changed.connect(func(_c: bool) -> void:
		_sync_event_overlay_rect()
		_sync_city_lore_rect()
		_refresh_round_console())

	# 上中：回合牌；右上：时钟、公共银库（木梁顶栏退场）
	_hud_topbar.visible = false
	_lshu_adopt(_hud_current_action, _lshu.slot_round)
	_lshu_style(_hud_current_action, 32, LshuKit.INK, "title")
	_hud_current_action.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_current_action.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hud_current_action.clip_text = true
	_lshu_adopt(_hud_clock, _lshu.slot_clock)
	_lshu_style(_hud_clock, 36, LshuKit.INK, "title")
	_hud_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_clock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var supply_row := _hud_topbar.get_node("SupplyRow") as HBoxContainer
	_lshu_adopt(supply_row, _lshu.slot_supply)
	supply_row.alignment = BoxContainer.ALIGNMENT_CENTER
	supply_row.add_theme_constant_override("separation", 6)
	var supply_ingot := supply_row.get_node("SupplyIngot") as TextureRect
	supply_ingot.texture = LshuKit.icon("silver")
	supply_ingot.custom_minimum_size = Vector2(46, 46)
	_lshu_style(_hud_supply_title, 24, LshuKit.INK_SOFT, "body")
	_lshu_style(_hud_supply, 34, LshuKit.INK, "title")

	# 左下：挎包 = 银两 + 四个口袋（旧「玩家船舱」标题、分隔线、阶段标题退场）
	var wallet := _hud_cargo_block.find_child("CargoWallet", true, false) as HBoxContainer
	_lshu_adopt(wallet, _lshu.slot_wallet)
	wallet.alignment = BoxContainer.ALIGNMENT_CENTER
	var wallet_icon := wallet.get_node("CargoWalletIcon") as TextureRect
	wallet_icon.texture = LshuKit.icon("silver")
	wallet_icon.custom_minimum_size = Vector2(40, 40)
	var tassel_clear := wallet.get_parent().get_node_or_null("CargoWalletTasselClear") as Control
	if tassel_clear != null:
		tassel_clear.visible = false
	_lshu_style(_hud_cargo_silver, 32, LshuKit.INK, "title")
	var pockets := CenterContainer.new()
	pockets.name = "CargoPockets"
	pockets.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lshu.slot_cargo.add_child(pockets)
	pockets.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud_cargo_grid.reparent(pockets, false)
	_hud_cargo_grid.custom_minimum_size = Vector2.ZERO
	_hud_cargo_grid.add_theme_constant_override("h_separation", LSHU_POCKET_GAP)
	_hud_cargo_grid.add_theme_constant_override("v_separation", LSHU_POCKET_GAP)
	_hud_cargo_block.visible = false
	for n in ["OrnateDividerWrap", "ActionHeader"]:
		var legacy := _console.get_node_or_null(n) as Control
		if legacy != null:
			legacy.visible = false

	# 下中：骰子托盘
	_dice_3d.reparent(_lshu.slot_dice, false)
	_dice_3d.custom_minimum_size = Vector2.ZERO
	_dice_3d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _dice_3d.has_method("set_display_size"):
		# 约托盘宽的 0.75：骰子坐在皮垫上，不悬在外面（渲染区比骰子大，上方留给抛起，插槽不裁切）
		_dice_3d.call("set_display_size", _lshu.slot_dice.size.x * 0.75)

	# 右下：L叔 泡泡里的「下一步」、糖果主按钮、次要按钮、收据
	_lshu_adopt(_hud_prompt, _lshu.slot_prompt)
	_hud_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_prompt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 单行提示条：放不下时省略号，完整内容在悬停提示里
	_hud_prompt.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hud_prompt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hud_prompt.max_lines_visible = 1
	_hud_prompt.mouse_filter = Control.MOUSE_FILTER_PASS
	_lshu.guide_toggled.connect(_on_lshu_guide_toggled)
	_lshu_hints_on = _lshu_load_hints_setting()
	_lshu.set_hints_look(_lshu_hints_on)
	_lshu_adopt(_hud_primary_wrap, _lshu.slot_primary)
	_primary_skin.visible = false
	_primary_hint_plaque.visible = false
	_lshu_primary_skin = LshuSkinScript.skin_button(_primary_action, "ochre")
	_lshu_button_font(_primary_action, 40)
	_lshu_adopt(_hud_secondary_row, _lshu.slot_secondary)
	_hud_secondary_row.add_theme_constant_override("separation", 14)
	for b in [_secondary_action, _secondary_alt_action]:
		LshuSkinScript.skin_button(b, "cream")
		_lshu_button_font(b, 25)
		(b as Button).custom_minimum_size = Vector2(0, 56)
	_lshu_adopt(_console_feedback, _lshu.slot_receipt)
	_lshu_style(_console_feedback, 21, LshuKit.INK_SOFT, "body")
	_console_feedback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_console_feedback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hud_action_dock.visible = false

	# 旧卷轴：纸面和 AI 卡退场；控制台只在「事件交换」时整块搬进市集面板
	_hud_scroll_art.visible = false
	_ai_card.visible = false
	_lshu_adopt(_hud_scroll_root, _lshu.slot_market_extra)
	for side_name in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		_hud_scroll_margin.add_theme_constant_override(side_name, 0)
	_hud_scroll_root.visible = false

	# 结算：沿用正式按钮（节点名与信号不变），换成糖果皮放进结算页
	for pair in [[%RestartButton, "ochre", "再来一局"], [%BackTitleButton, "cream", "回到开场"]]:
		var rb := pair[0] as Button
		rb.reparent(_lshu.slot_result_buttons, false)
		rb.text = String(pair[2])
		rb.custom_minimum_size = Vector2(360, 112)
		LshuSkinScript.skin_button(rb, String(pair[1]))
		_lshu_button_font(rb, 42)


func _lshu_adopt(node: Control, slot: Control) -> void:
	node.reparent(slot, false)
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	node.size_flags_horizontal = Control.SIZE_FILL
	node.size_flags_vertical = Control.SIZE_FILL


func _lshu_style(label: Label, px: int, color: Color, kind: String) -> void:
	LshuMatchHudScript.style_label(label, px, color, kind, 700)


func _lshu_button_font(b: Button, px: int) -> void:
	b.add_theme_font_override("font", LshuMatchHudScript.ui_font(700))
	b.add_theme_font_size_override("font_size", px)
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(key, LshuKit.INK)
	b.add_theme_color_override("font_disabled_color", LshuKit.INK_SOFT)
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))
	b.add_theme_constant_override("outline_size", 0)


func _layout_lshu_hud() -> void:
	$RootMargin.add_theme_constant_override("margin_top", 0)
	$RootMargin.add_theme_constant_override("margin_bottom", 0)
	$RootMargin.add_theme_constant_override("margin_left", 0)
	$RootMargin.add_theme_constant_override("margin_right", 0)
	var main_row: HBoxContainer = $RootMargin/RootVBox/MainRow
	main_row.add_theme_constant_override("separation", 0)
	var side: VBoxContainer = $RootMargin/RootVBox/MainRow/SidePanel
	side.custom_minimum_size = Vector2.ZERO
	side.size_flags_horizontal = Control.SIZE_SHRINK_END
	%BoardView.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	%BoardView.custom_minimum_size = Vector2(maxf(500.0, size.x), 0)
	%BoardView.z_index = Z_BOARD
	_lshu.layout(size)
	_lshu_inset_goal = -1.0
	_lshu_apply_board_inset(false)
	_lshu_push_hud_insets()
	_apply_modal_layer_stack()
	_sync_event_overlay_rect()
	_sync_city_lore_rect()


## 地图右侧留白：市集面板打开时让出面板宽度（镜头平滑挪开），平时整屏都是地图。
func _lshu_apply_board_inset(animate := true) -> void:
	if _lshu == null or not %BoardView.has_method("set_map_safe_right_inset"):
		return
	# 2026-09-26：打开市集面板不再挪 / 缩镜头（「每次都要放大缩放镜头很麻烦」），面板直接盖在地图右侧
	var goal := 0.0
	if is_equal_approx(goal, _lshu_inset_goal):
		return
	_lshu_inset_goal = goal
	if _lshu_inset_tween != null and _lshu_inset_tween.is_valid():
		_lshu_inset_tween.kill()
	if not animate or not is_inside_tree():
		_lshu_set_inset(goal)
		return
	_lshu_inset_tween = create_tween()
	_lshu_inset_tween.tween_method(_lshu_set_inset, _lshu_inset, goal, LSHU_INSET_TWEEN_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## 3D 棋盘的镜头要知道上下被界面挡住多少（顶栏步骤条的下沿、底部挎包 / 骰子 / 按钮组的上沿），对准没被挡住的那一块（夜测 CAM-1）
func _lshu_push_hud_insets() -> void:
	if _lshu == null or not %BoardView.has_method("set_hud_safe_insets"):
		return
	var board := %BoardView as Control
	var by := board.get_global_rect().position.y
	var tc: Control = _lshu.group_tc
	var top := tc.global_position.y + tc.size.y * tc.scale.y - by
	var bottom_top := minf(_lshu.group_bl.global_position.y, minf(_lshu.group_bc.global_position.y, _lshu.group_br.global_position.y))
	%BoardView.set_hud_safe_insets(top, board.size.y - (bottom_top - by))


## 每帧告诉 3D 棋盘：有弹层时别贴边滚；市集面板（连到屏幕右边）那一块不算边带（夜测 CAM-5 / CAM-8）
func _lshu_push_edge_scroll_state() -> void:
	if _lshu == null or not ("edge_scroll_blocked" in %BoardView):
		return
	var blocked: bool = (
		%EventDrawOverlay.visible or _lshu.handover.visible or _lshu.result.visible
		or (%CityLoreCard.has_method("is_open") and %CityLoreCard.is_open())
	)
	%BoardView.set("edge_scroll_blocked", blocked)
	var m: Rect2 = _lshu.market_rect()
	if m.size.x > 0.0:
		var board := %BoardView as Control
		var origin := board.get_global_rect().position
		m = Rect2(m.position - origin, Vector2(board.size.x - (m.position.x - origin.x), m.size.y))
	%BoardView.set("edge_scroll_exclude", m)


func _lshu_set_inset(px: float) -> void:
	_lshu_inset = px
	%BoardView.set_map_safe_right_inset(px)
	_sync_event_overlay_rect()
	_sync_city_lore_rect()


## 地图可见区（事件抽卡、城市图鉴用）：去掉市集面板遮住的那一截
func _lshu_visible_board_rect(board_rect: Rect2) -> Rect2:
	var m := _lshu.market_rect()
	if m.size.x > 0.0:
		board_rect.size.x = maxf(1.0, minf(board_rect.end.x, m.position.x) - board_rect.position.x)
	return board_rect


# ---------- 刷新 ----------

func _lshu_refresh() -> void:
	if _lshu == null or GameState.players.is_empty():
		return
	var cur := GameState.current_player()
	var owner := _hud_owner()
	var phase := GameState.phase
	var round_text := "第 %d 轮 · %s的回合" % [GameState.round_index + 1, cur.display_name]
	if _hud_current_action.text != round_text:
		_hud_current_action.text = round_text
		LshuMatchHudScript.fit_label(_hud_current_action, 496.0, 32, 22)
	_hud_supply_title.text = "公共银库"
	_lshu.set_steps(_lshu_step_index(phase))
	_lshu.set_satchel(_lshu_avatar(owner), owner.display_name, _lshu_seat_color(owner))
	_lshu.discard_button.text = "不丢了" if _lshu_discard_mode else "丢货"
	_lshu.discard_button.disabled = not _lshu_discard_mode and not _lshu_discard_allowed()
	var seats := []
	for p in GameState.players:
		if p == owner:
			continue
		seats.append({
			"name": p.display_name,
			"avatar": _lshu_avatar(p),
			"flip": _lshu_avatar_flip(p),
			"color": _lshu_seat_color(p),
			"silver": _fun.shown_silver(p),
			"goods": _lshu_goods_textures(p),
			"acting": p == cur and phase != GameState.Phase.GAME_OVER,
			"status": String(_lshu_ai_status.get(p.player_id, "")) if p.is_ai() else "轮到我啦",
		})
	_lshu.set_roster(seats)
	# 骰子托盘上的步数牌：掷出来能走几步。选了目的地也不减（先选再确认后「选了 3 步的地方」很常见，
	# 牌上写「0步」、主按钮写「出发（3 步）」会让孩子以为走不了）
	var badge := ""
	if not cur.is_ai() and phase == GameState.Phase.MOVE_OR_EVENT and cur.die_result != null and not cur.move_confirmed:
		if DiceSystem.is_event_face(cur.die_result):
			badge = "事件" if not cur.pending_event_needs_move else "%d步" % cur.movement_budget
		else:
			badge = "%d步" % cur.movement_budget
	_lshu.set_step_badge("" if _human_event_presenting() else badge)
	# 右下：泡泡只在有话说时出现；收据行空时不占底
	# 主按钮：糖果皮；「下一步在地图上」时换奶油色指引牌
	_lshu_paint_primary(bool(_primary_action.get_meta("hint_mode", false)))
	_ai_card.visible = false
	_lshu_apply_ai_speed()
	# 市集面板
	var mode := ""
	if (
		not cur.is_ai() and phase == GameState.Phase.TRADE and not _auto_end_pending
		and GameData.is_city_node(GameState.content, cur.current_node_id)
	):
		mode = "trade"
	elif not cur.is_ai() and _is_pending_event_exchange():
		mode = "exchange"
	elif not cur.is_ai() and _fun.is_active():
		mode = "decision"
	if _human_event_presenting():
		mode = ""          # 卡还没翻完，市集 / 交换面板先不开（复检 NOV-2）
	_lshu.set_market_mode(mode)
	_lshu_fit_prompt(_hud_prompt.text)
	_lshu_paint_receipt()
	# 提示条：L叔 提示打开、且有话说时才出现；市集里「下一步」搬进面板顶上，不受开关影响
	# 待决的事件（丢货 / 交换）关了提示也要说清怎么做（复检 EI-5）
	var must_say: bool = (
		_is_pending_loss_decision() or _is_pending_event_exchange() or _fun.owns_primary()
		or _hud_prompt.text.contains("\n")
	)
	var strip_on := (
		mode == "" and (_lshu_hints_on or must_say)
		and _hud_prompt.visible and not _hud_prompt.text.strip_edges().is_empty()
	)
	if _human_event_presenting():
		_hud_prompt.text = (
			_pad_says("看完点卡片旁边的「继续」", "看完按 A 继续") if _event_card_revealed()
			else _pad_says("先点一张卡翻开，看看这回发生了什么", "十字键挑一张卡，按 A 翻开")
		)
	# 市集收起时：提示条回到右下，告诉孩子怎么打开（复检 NOV-4）
	var collapsed: bool = mode != "" and _lshu.market_collapsed
	if collapsed:
		_hud_prompt.text = _pad_says("市集收起来了：点右边的「◂ 市集」打开，再选一行", "市集收起来了：按 Y 打开")
	_lshu.guide_bubble.visible = strip_on or collapsed
	# 交换有自己的预览条，不再叠一行提示（旧版提示压在货物列表后面）
	_lshu.slot_prompt.visible = strip_on or mode == "trade" or collapsed
	_hud_prompt.tooltip_text = _hud_prompt.text
	# 搬进市集里的提示只是说明，不接鼠标（不挡下面的按钮，复检 EI-1）
	_hud_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE if mode != "" else Control.MOUSE_FILTER_PASS
	# 旧卷轴的零件（玩家船舱标题、分隔线、旧步骤条、阶段标题）每次刷新都可能被旧代码重新显示，这里统一收掉（复检 EI-4）
	_hud_cargo_block.visible = false
	for legacy_name in ["OrnateDividerWrap", "ActionHeader"]:
		var legacy := _console.get_node_or_null(legacy_name) as Control
		if legacy != null:
			legacy.visible = false
	# 旧卷轴（连同里面的旧交换面板）不再露面；旧面板仍在后台跟着同步，旧测试直接按它的按钮
	_hud_scroll_root.visible = false
	if mode == "trade":
		_lshu_refresh_market(cur)
	elif mode == "exchange":
		_lshu.market_title.text = "商旅交换"
		_lshu_refresh_exchange()
	elif mode == "decision":
		_lshu.market_title.text = _fun.title()
		LshuMatchHudScript.fit_label(_lshu.market_title, 400.0, 46, 30)
		_lshu.market_choice.call("set_view", _fun.view())
	if not cur.is_ai() and EventSystem.has_pending_decision():
		_fun.call_deferred("maybe_open_quiz")
	_lshu_apply_board_inset()


## 只有玩家打开过「电脑走快点」才动 time_scale（测试自己设的加速不被覆盖）
func _lshu_apply_ai_speed() -> void:
	var want := (
		lshu_ai_fast and not GameState.players.is_empty()
		and GameState.current_player().is_ai() and GameState.phase != GameState.Phase.GAME_OVER
	)
	if want and _lshu_saved_time_scale < 0.0:
		_lshu_saved_time_scale = Engine.time_scale
		Engine.time_scale = LSHU_AI_FAST_SCALE
	elif not want:
		_lshu_restore_time_scale()


func _lshu_restore_time_scale() -> void:
	if _lshu_saved_time_scale >= 0.0:
		Engine.time_scale = _lshu_saved_time_scale
		_lshu_saved_time_scale = -1.0


func _lshu_step_index(phase: int) -> int:
	match phase:
		GameState.Phase.ROLL_DIE:
			return 0
		GameState.Phase.MOVE_OR_EVENT, GameState.Phase.OPEN_TRADE_ROUTE:
			return 1
		GameState.Phase.TRADE:
			return 2
		GameState.Phase.END_TURN:
			return 3
	return -1


func _lshu_paint_primary(hint_mode: bool) -> void:
	if _lshu_primary_skin == null:
		return
	_primary_skin.visible = false
	_primary_hint_plaque.visible = false
	var color := "cream" if hint_mode else "ochre"
	if String(_lshu_primary_skin.get_meta("color", "")) != color:
		_lshu_primary_skin.set_meta("color", color)
		_lshu_primary_skin.set("skin", LshuSkinScript.tex("btn_" + color))
		_lshu_primary_skin.set("skin_pressed", LshuSkinScript.tex("btn_%s_pressed" % color))
		_lshu_primary_skin.set("nine", LshuSkinScript.margins("btn_" + color))
		_lshu_primary_skin.set("dim_disabled", not hint_mode)
		_lshu_primary_skin.queue_redraw()
	# 字多时自动缩小，不让长文字（如「确认按卡售银（+4 白银）」）顶满按钮
	var px := 30 if hint_mode else 38
	var room := _hud_primary_wrap.size.x - 60.0
	var font := _primary_action.get_theme_font("font")
	while px > 24 and font != null and room > 0.0 and font.get_string_size(_primary_action.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > room:
		px -= 2
	_primary_action.add_theme_font_size_override("font_size", px)
	# 点不了时按钮上写的是下一步怎么做（「先点一行选好」「确认丢失（0/1）」）：底色压暗表示点不了，字仍用深墨色，
	# 以前是浅墨色压在暗底上，对比度只有 1.8:1（复检 UIRES-7）
	_primary_action.add_theme_color_override("font_disabled_color", LshuKit.INK)
	_primary_action.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))


## 右下提示条：平常一行（放不下就省略号）；有「电脑抽的卡改了你的白银 / 货」或选完的结果时两三行，泡泡往上长
func _lshu_fit_prompt(prompt: String) -> void:
	if not prompt.contains("\n") or _lshu.market_mode != "":
		_hud_prompt.autowrap_mode = TextServer.AUTOWRAP_OFF
		_hud_prompt.max_lines_visible = 1
		_lshu.set_prompt_lines(1)
		return
	var lines := 0
	for part in prompt.split("\n"):
		lines += maxi(1, ceili(float(part.length()) / 21.0))
	lines = mini(lines, 4)
	_hud_prompt.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_hud_prompt.max_lines_visible = lines
	_lshu.set_prompt_lines(lines)


## 收据（开通商道 +2 两、交易结果、停在路上的原因……）：不再常驻右下角，改成屏幕上方淡入淡出的横幅，
## 每条只弹一次。只在真人回合的贸易 / 结束阶段弹；电脑回合的动态挂在左上它自己的小卡旁边。
func _lshu_paint_receipt() -> void:
	var text := _console_feedback.text.strip_edges()
	var cur_ai := not GameState.players.is_empty() and GameState.current_player().is_ai()
	_console_feedback.self_modulate.a = 1.0
	_lshu.slot_receipt.visible = false
	if _lshu.market_mode != "":
		_lshu_last_toast = text          # 市集开着时不弹横幅（原因、开通商道都写在面板里），也别等关了再补弹旧话
		return
	if (
		text.is_empty() or cur_ai or text == _lshu_last_toast
		or GameState.phase != GameState.Phase.END_TURN
		or _hud_prompt.text.contains(text)
	):
		return
	_lshu_last_toast = text
	_show_turn_toast(text)


## 用手柄时（scripts/pad/pad_input.gd 的手柄模式）提示换成按键的说法；只用鼠标 / 触屏 / 键盘时原样
func _pad_says(mouse_text: String, pad_text: String) -> String:
	var hub := get_node_or_null("/root/PadInput")
	return pad_text if hub != null and bool(hub.get("pad_mode")) else mouse_text


## 点 L叔 头像：收起 / 打开右下角的提示条（记在本机设置里，下一局沿用）
func _on_lshu_guide_toggled() -> void:
	_lshu_hints_on = not _lshu_hints_on
	_lshu.set_hints_look(_lshu_hints_on)
	_lshu_save_hints_setting()
	_refresh_round_console()


func _lshu_settings_path() -> String:
	return LshuProgressScript.dir_path().path_join("settings.cfg")


func _lshu_load_hints_setting() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(_lshu_settings_path()) != OK:
		return true
	return bool(cfg.get_value("match", "hints", true))


## 事件「商旅交换」的三块内容（lshu_match_hud.gd set_exchange_view）：选中状态全在这里的 _event_exchange_*，
## 和旧面板、挎包口袋上的「交出」标记是同一份
func _lshu_refresh_exchange() -> void:
	if _lshu == null or not _is_pending_event_exchange():
		return
	var player := GameState.current_player()
	var av := EventSystem.get_pending_exchange_availability()
	var give_goods: Array = av.get("give_goods", [])
	var targets: Array = av.get("targets", [])
	var by_target: Dictionary = av.get("legal_receive_goods_by_target", {})
	var receive_goods: Array = by_target.get(_event_exchange_target, [])
	var gives := []
	for g in give_goods:
		var id := String(g)
		var n := player.held_count(id)
		gives.append({
			"id": id, "icon": _lshu_good_texture(id), "enabled": not _event_exchange_submitting,
			"text": GameData.get_good_name(GameState.content, id) + (" ×%d" % n if n > 1 else ""),
			"selected": id == _event_exchange_give_good,
		})
	var tlist := []
	var others := false
	for t in targets:
		var tid := String(t)
		others = others or tid != "SUPPLY"
		tlist.append({"id": tid, "text": _event_exchange_target_label(tid), "selected": tid == _event_exchange_target})
	var recvs := []
	for g in receive_goods:
		var id := String(g)
		recvs.append({
			"id": id, "icon": _lshu_good_texture(id), "text": GameData.get_good_name(GameState.content, id),
			"selected": id == _event_exchange_receive_good,
			"enabled": not _event_exchange_give_good.is_empty() and id != _event_exchange_give_good and not _event_exchange_submitting,
		})
	var preview := {}
	var hint := ""
	if not bool(av.get("available", false)):
		hint = String(av.get("message", "没有可完成的交换。"))
	elif _event_exchange_give_good.is_empty():
		hint = "先点 ① 里你要交出的货"
	elif _event_exchange_receive_good.is_empty():
		hint = "再点 ② 里想换回的货"
	elif _event_exchange_selection_valid(av):
		preview = {
			"give": {"icon": _lshu_good_texture(_event_exchange_give_good), "text": GameData.get_good_name(GameState.content, _event_exchange_give_good)},
			"receive": {"icon": _lshu_good_texture(_event_exchange_receive_good), "text": GameData.get_good_name(GameState.content, _event_exchange_receive_good)},
			"from": _event_exchange_target_label(_event_exchange_target),
		}
	else:
		hint = "这样换不行，请重新选"
	_lshu.set_exchange_view({
		"subtitle": (
			"用你的 1 件货换 1 件不一样的货，公共商品堆和别的玩家都能换" if others
			else "用你的 1 件货，从公共商品堆换 1 件不一样的货"
		),
		"give": gives, "targets": tlist, "receive": recvs, "preview": preview, "hint": hint,
		"receive_head": "② 换回什么？" if others else "② 从公共商品堆换回什么？",
	})


## 交换来源（公共商品堆 / 别的玩家）：换来源就清掉已选的「换回」，和旧下拉框一样
func _on_lshu_exchange_target(target_id: String) -> void:
	if not _can_accept_human() or not _is_pending_event_exchange() or _event_exchange_submitting:
		return
	if target_id not in EventSystem.get_pending_exchange_availability().get("targets", []) or target_id == _event_exchange_target:
		return
	_event_exchange_target = target_id
	_event_exchange_receive_good = ""
	_set_feedback(_event_exchange_prompt(), COLOR_INFO)
	call_deferred("_refresh_after_event_exchange_selection")


## 只在正式入口写盘（测试不改玩家的设置）
func _lshu_save_hints_setting() -> void:
	if not _lshu_records_progress():
		return
	var cfg := ConfigFile.new()
	cfg.load(_lshu_settings_path())
	cfg.set_value("match", "hints", _lshu_hints_on)
	DirAccess.make_dir_recursive_absolute(LshuProgressScript.dir_path())
	cfg.save(_lshu_settings_path())


## 市集清单（Carlos 2026-09-26：「交易面板不够直观和高效」）：四个页签合成一张清单——
##   「按这张牌」：卖（货→白银）/ 换（货→货）/ 买（白银→货）三种牌面交易，每行行尾一个一键成交按钮；
##   「直接卖」：挎包里每件货一行，可多选，主按钮一起卖掉。
## 每行背后仍是 TradeSystem 给的合法组合（candidate_states）；点行 = 切到那种交易并选中这一组。
func _lshu_refresh_market(player: PlayerState) -> void:
	var city_id := GameData.get_city_at_node(GameState.content, player.current_node_id)
	var city := GameData.get_city_name(GameState.content, city_id)
	_lshu.market_title.text = "%s市集" % city
	var rows := []
	var chain := []
	_lshu_row_src.clear()
	var entries: Array = _cached_trade_card.get("entries", [])
	if entries.is_empty():
		_lshu.market_subtitle.text = "这里的商道还没开通：只能直接卖货，每件 1 两白银"
	else:
		_lshu.market_subtitle.text = (
			"新开通商道，得了 2 两白银！牌上的东西在%s一样值钱" % city if player.opened_trade_route_this_turn
			else "这张牌上的东西，在%s一样值钱" % city
		)
		for e in entries:
			chain.append({"icon": _lshu_entry_icon(e), "text": _lshu_entry_text(e, 1)})
	if not _trade_possible_here(player):
		rows.append({"notice": _lshu_no_trade_reason(player)})
		_lshu_row_src.append({})
	var card_rows := []
	for mode in [TradePanelMode.CARD_SELL, TradePanelMode.EXCHANGE, TradePanelMode.BUY]:
		for s in _lshu_mode_states(mode):
			var g := int(s.get("give_index", -1))
			var r := int(s.get("receive_index", -1))
			if g < 0 or r < 0 or g >= entries.size() or r >= entries.size() or g == r:
				continue
			var give: Dictionary = entries[g]
			var recv: Dictionary = entries[r]
			var enabled := bool(s.get("enabled", false))
			# 手里根本没有的货不列（整张牌的组合太多，只留和自己有关的）；白银不够的「买」照列，好知道这张牌能买什么
			if not enabled and String(give.get("resource_kind", "")) != "SILVER" and not _lshu_holds(player, give):
				continue
			var selected: bool = (
				_lshu_row_picked and enabled and mode == _trade_panel_mode
				and g == _trade_selector.give_index() and r == _trade_selector.receive_index()
			)
			var times := _trade_selector.times if selected else 1
			var max_t := _trade_selector.max_times if selected else int(s.get("max_times", 1))
			var tag := "买" if mode == TradePanelMode.BUY else "卖" if mode == TradePanelMode.CARD_SELL else "换"
			var note := ""
			if selected:
				note = _lshu_after_trade_note(player, give, recv, times)
			elif enabled:
				# 用手柄时写按键说法（安卓压力测试 MC-4；换手柄 / 触屏时 PadMatch 会刷新这一页）
				note = (
					_pad_says("点一下选中（最多%s %d 次）" % [tag, max_t], "十字键选中（最多%s %d 次）" % [tag, max_t]) if max_t > 1
					else _pad_says("点一下选中", "十字键选中")
				)
			else:
				note = _lshu_reason_text(s)
			card_rows.append([enabled, {
				"tag": tag,
				"tag_color": LshuKit.OCHRE_DEEP if mode == TradePanelMode.BUY else Color("#5E9A4C") if mode == TradePanelMode.CARD_SELL else LshuKit.DENIM_DEEP,
				"give": {"icon": _lshu_entry_icon(give), "text": _lshu_entry_text(give, times)},
				"receive": {"icon": _lshu_entry_icon(recv), "text": _lshu_entry_text(recv, times)},
				"note": note,
				"enabled": enabled,
				"selected": selected,
				"times": times,
				"max_times": max_t,
				"action": "",
			}, {"mode": mode, "give_index": g, "receive_index": r, "enabled": enabled,
				"reason_code": String(s.get("reason_code", "")), "message": String(s.get("message", ""))}])
	# 排序按「能不能做」：能做的牌面交易 → 直接卖 → 做不了的（压成一行字，放最后看看就好）
	var ok_rows := card_rows.filter(func(x): return bool(x[0]))
	var no_rows := card_rows.filter(func(x): return not bool(x[0]))
	if not ok_rows.is_empty():
		rows.append({"section": _pad_says("按这张牌：点一行选中，再按下面的按钮确认", "按这张牌：十字键选一行，再按 A 确认")})
		_lshu_row_src.append({})
		for x in ok_rows:
			rows.append(x[1])
			_lshu_row_src.append(x[2])
	if _lshu_mode_available(TradePanelMode.DIRECT_SALE, player):
		var picked_n := _sale_selected_slots.size() if _trade_panel_mode == TradePanelMode.DIRECT_SALE else 0
		var sale_after := ""
		if picked_n > 0:
			var rate := int(GameState.content["ruleset"].get("direct_sale_rate", 1))
			sale_after = "（已选 %d 件 · 之后：银 %d · 货 %d/%d）" % [picked_n, player.silver + picked_n * rate, player.cargo_count() - picked_n, player.warehouse_capacity]
		rows.append({"section": "直接卖：每件 1 两白银，可以多选" + sale_after})
		_lshu_row_src.append({})
		for slot_index in player.warehouse_slots.size():
			var good_id := String(player.warehouse_slots[slot_index])
			var picked := _trade_panel_mode == TradePanelMode.DIRECT_SALE and _sale_selected_slots.has(slot_index)
			rows.append({
				"tag": "卖",
				"tag_color": LshuKit.CAMEL,
				"give": {"icon": _lshu_good_texture(good_id), "text": "%s ×1" % GameData.get_good_name(GameState.content, good_id)},
				"receive": {"icon": LshuKit.icon("silver"), "text": "白银 ×1"},
				"note": "选上了" if picked else _pad_says("点一下选上", "按 X 选上"),
				"enabled": true,
				"selected": picked,
				"check_row": true,
			})
			_lshu_row_src.append({"sale_slot": slot_index, "good_id": good_id, "enabled": true})
	if not no_rows.is_empty():
		rows.append({"section": "这张牌上暂时做不了的"})
		_lshu_row_src.append({})
		for x in no_rows:
			var r: Dictionary = x[1]
			rows.append({"line": "%s：%s → %s · %s" % [r.tag, r.give.text, r.receive.text, r.note]})
			_lshu_row_src.append(x[2])
	elif card_rows.is_empty() and not entries.is_empty():
		rows.append({"section": "按这张牌：你手里没有牌上的货"})
		_lshu_row_src.append({})
	var sig := JSON.stringify([rows.map(func(r): return [r.get("notice", ""), r.get("section", ""), r.get("line", ""), r.get("tag", ""), r.get("give", {}).get("text", ""), r.get("receive", {}).get("text", ""), r.get("note", ""), r.get("enabled", false), r.get("selected", false), r.get("times", 0), r.get("max_times", 0)]), chain.map(func(c): return c.text)])
	if sig != _lshu_market_sig:
		_lshu_market_sig = sig
		_lshu.set_market_chain(chain, "=")
		_lshu.set_market_rows(rows)


# ---------- 挎包丢货 ----------

## 自己的回合、没有待决事件、挎包里有货才能丢（规则层 TradeSystem.discard_goods 也会再查一遍）
func _lshu_discard_allowed() -> bool:
	if GameState.players.is_empty() or GameState.phase == GameState.Phase.GAME_OVER:
		return false
	var p := GameState.current_player()
	return not p.is_ai() and GameState.is_in_turn() and not EventSystem.has_pending_decision() and p.cargo_count() > 0


func _on_lshu_discard_toggled() -> void:
	if not _can_accept_human() and not _lshu_discard_mode:
		return
	if _lshu_discard_mode:
		_lshu_discard_mode = false
	elif _lshu_discard_allowed():
		_lshu_discard_mode = true
	else:
		_set_feedback("现在不能丢货（轮到自己、挎包里有货时才行）", COLOR_INFO)
	_lshu_discard_slots.clear()
	_block_dock_clicks()
	_refresh_cargo_slot_visuals()
	_refresh_round_console()


func _lshu_apply_discard_mode(allow: bool) -> void:
	var n := _lshu_discard_slots.size()
	_primary_action.text = "确认丢掉 %d 件" % n if n > 0 else _pad_says("先点要丢的货", "按 X 勾上要丢的货")
	_primary_action.disabled = not allow or n == 0
	_apply_primary_mode(false)
	_apply_secondary_buttons([["不丢了", false, "discard_cancel"]], true)
	_hud_prompt.text = _pad_says("点挎包里不要的货，丢掉不换钱（已选 %d 件）" % n, "X 勾要丢的货，A 丢掉（已选 %d 件）" % n)


func _lshu_confirm_discard() -> void:
	if not _can_accept_human() or _lshu_discard_slots.is_empty():
		return
	var player := GameState.current_player()
	var selection := {}
	var names: Array[String] = []
	for raw in _lshu_discard_slots:
		var slot_index := int(raw)
		if slot_index < 0 or slot_index >= player.warehouse_slots.size():
			continue
		var good_id := String(player.warehouse_slots[slot_index])
		selection[good_id] = int(selection.get(good_id, 0)) + 1
		names.append(GameData.get_good_name(GameState.content, good_id))
	_lshu_discard_mode = false
	_lshu_discard_slots.clear()
	var result := TradeSystem.discard_goods(selection)
	_block_dock_clicks()
	_set_feedback(
		"丢掉了 %s（不换钱）" % "、".join(names) if bool(result.get("success", false)) else String(result.get("message", "丢不了")),
		COLOR_INFO if bool(result.get("success", false)) else COLOR_FAILURE
	)
	_refresh()


## 城市里做不成任何交易时的原因（写在市集面板顶上）
func _lshu_no_trade_reason(player: PlayerState) -> String:
	if player.trade_action_used:
		return "这回合已经交易过了"
	var parts: Array[String] = []
	var need_silver := 0
	for e in _cached_trade_card.get("entries", []):
		if String((e as Dictionary).get("resource_kind", "")) == "SILVER":
			need_silver = int((e as Dictionary).get("quantity", 0))
	var buy_codes := {}
	for st in _lshu_mode_states(TradePanelMode.BUY):
		buy_codes[String((st as Dictionary).get("reason_code", ""))] = true
	if need_silver > 0 and player.silver < need_silver:
		parts.append("白银不够：买牌上的货要 %d 两，你只有 %d 两" % [need_silver, player.silver])
	elif buy_codes.has("SUPPLY_SHORT"):
		parts.append("牌上的货在市集里卖完了")
	elif buy_codes.has("CARGO_FULL"):
		parts.append("挎包装满了，买不下")
	if player.cargo_count() == 0:
		parts.append("挎包是空的，没有货可卖")
	if parts.is_empty():
		return "这里现在做不成交易，点「结束回合」继续"
	return "；".join(parts)


## 某种牌面交易的全部组合（含做不了的，用来灰显原因）
func _lshu_mode_states(mode: int) -> Array:
	if _trade_panel_mode == mode and not _trade_selector.candidate_states.is_empty():
		return _trade_selector.candidate_states
	var availability := _availability_for_mode(mode)
	var states: Array = availability.get("candidate_states", [])
	if states.is_empty():
		for action in availability.get("actions", []):
			var a: Dictionary = (action as Dictionary).duplicate(true)
			a["enabled"] = true
			states.append(a)
	return states


func _lshu_mode_available(mode: int, player: PlayerState) -> bool:
	match mode:
		TradePanelMode.BUY:
			return bool(_cached_buy_availability.get("can_trade", false))
		TradePanelMode.EXCHANGE:
			return bool(_cached_exchange_availability.get("can_trade", false))
		TradePanelMode.CARD_SELL:
			return bool(_cached_card_sale_availability.get("can_trade", false))
	return (
		GameData.is_city_node(GameState.content, player.current_node_id)
		and not player.trade_action_used
		and player.cargo_count() > 0
	)


func _lshu_holds(player: PlayerState, entry: Dictionary) -> bool:
	if String(entry.get("resource_kind", "")) == "SILVER":
		return player.silver >= int(entry.get("quantity", 0))
	return player.held_count(String(entry.get("resource_id", ""))) > 0


func _lshu_entry_icon(entry: Dictionary) -> Texture2D:
	if String(entry.get("resource_kind", "")) == "SILVER":
		return LshuKit.icon("silver")
	return _lshu_good_texture(String(entry.get("resource_id", "")))


func _lshu_entry_text(entry: Dictionary, times: int) -> String:
	var qty := int(entry.get("quantity", 0)) * maxi(times, 1)
	if String(entry.get("resource_kind", "")) == "SILVER":
		return "白银 ×%d" % qty
	return "%s ×%d" % [GameData.get_good_name(GameState.content, String(entry.get("resource_id", ""))), qty]


func _lshu_good_texture(good_id: String) -> Texture2D:
	return LshuIconsScript.good(good_id)


## 选中的那一行写「换完：白银 X · 货仓 Y/4」——只是把这一笔的进出加减到当前持有上，不重算规则。
func _lshu_after_trade_note(player: PlayerState, give: Dictionary, recv: Dictionary, times: int) -> String:
	var silver := player.silver
	var cargo := player.cargo_count()
	for pair in [[give, -1], [recv, 1]]:
		var e: Dictionary = pair[0]
		var n := int(e.get("quantity", 0)) * times * int(pair[1])
		if String(e.get("resource_kind", "")) == "SILVER":
			silver += n
		else:
			cargo += n
	return "之后：银 %d · 货 %d/%d" % [silver, cargo, player.warehouse_capacity]


func _lshu_reason_text(state: Dictionary) -> String:
	var code := String(state.get("reason_code", ""))
	if code.contains("CAPACITY") or code.contains("WAREHOUSE") or code.contains("FULL"):
		return "装不下啦"
	if code.contains("SILVER") or code.contains("FUND") or code.contains("AFFORD"):
		return "白银不够"
	if code.contains("SUPPLY"):
		return "市集里没货了"
	if code == "INSUFFICIENT_QTY":
		return "货不够"
	if code == "NO_MATCHING_GOOD":
		return "手里没有"
	var msg := String(state.get("message", "")).strip_edges()
	return msg if not msg.is_empty() else "现在换不了"


func _lshu_goods_textures(p: PlayerState) -> Array:
	var out := []
	for good_id in p.warehouse_slots:
		out.append(_lshu_good_texture(String(good_id)))
	return out


func _lshu_human_count() -> int:
	var n := 0
	for p in GameState.players:
		if (p as PlayerState).is_local_human():
			n += 1
	return n


## 头像：优先用开局页的座位规则（LshuSeats：第一位真人是 L叔，其余真人是 seat_N，电脑按难度用 7/12/16 岁小孩）
func _lshu_avatar(p: PlayerState) -> Texture2D:
	if _lshu_seats != null:
		var t: Variant = _lshu_seats.call("avatar_texture", p)
		if t is Texture2D:
			return t
	if p.is_ai():
		var kid := {AIDifficulty.EASY: "kid_7", AIDifficulty.MEDIUM: "kid_12", AIDifficulty.HARD: "kid_16"}
		return load("res://assets/game/ui/lshu_setup/%s.png" % String(kid.get(AIDifficulty.of(p), "kid_12"))) as Texture2D
	var human_index := 0
	for q in GameState.players:
		if q == p:
			break
		if (q as PlayerState).is_local_human():
			human_index += 1
	if human_index == 0:
		return load("res://assets/game/ui/lshu_title/lshu_avatar2.png") as Texture2D
	var path := "res://assets/game/ui/lshu_setup/seat_%d.png" % (human_index + 1)
	return load(path) as Texture2D if ResourceLoader.exists(path) else load("res://assets/game/ui/lshu_setup/token_%s.png" % p.color_id) as Texture2D


## 同一难度的第二个电脑头像镜像一下，好分辨（LshuSeats 的规则）
func _lshu_avatar_flip(p: PlayerState) -> bool:
	if _lshu_seats == null:
		return false
	return bool(_lshu_seats.call("avatar_flip_h", p))


func _lshu_seat_color(p: PlayerState) -> Color:
	if _lshu_seats != null:
		var c: Variant = _lshu_seats.call("seat_color", p.color_id)
		if c is Color:
			return c
	var palette := {"red": Color("#D9695F"), "blue": LshuKit.DENIM_DEEP, "green": Color("#6FA35A"), "yellow": LshuKit.OCHRE}
	return palette.get(p.color_id, _player_color(p.color_id))


# ---------- 交互 ----------

func _on_lshu_row_pressed(index: int) -> void:
	if not _can_accept_human() or GameState.phase != GameState.Phase.TRADE or _trade_submitting:
		return
	if index < 0 or index >= _lshu_row_src.size():
		return
	# 过一会儿再点一次已选中的那一行 = 取消（和直接卖、交换格子一样能反悔；复检 NOV-9）。
	# 0.4 秒内的第二下是连点，仍然只是选中（孩子双击不会把刚选的又取消掉）
	var s: Dictionary = _lshu_row_src[index]
	if (
		_lshu_row_picked and not s.is_empty() and not s.has("sale_slot") and bool(s.get("enabled", false))
		and Time.get_ticks_msec() - _lshu_row_pick_ms > 400
		and int(s.get("mode", -1)) == _trade_panel_mode
		and int(s.get("give_index", -1)) == _trade_selector.give_index()
		and int(s.get("receive_index", -1)) == _trade_selector.receive_index()
	):
		_lshu_row_picked = false
		_update_trade_preview_and_buttons()
		_refresh_action_buttons()
		_refresh_round_console()
		return
	if _lshu_select_row(index):
		_lshu_row_pick_ms = Time.get_ticks_msec()


## 选中清单里的一行；成功返回 true（一键成交按钮接着按主按钮的路径提交）
func _lshu_select_row(index: int) -> bool:
	if index < 0 or index >= _lshu_row_src.size():
		return false
	var s: Dictionary = _lshu_row_src[index]
	if s.is_empty():
		return false
	_skip_end_picked_ctx = ""          # 点了一行（或勾了货）：改成交易，「不交易」的选中放下
	if s.has("sale_slot"):
		if _trade_panel_mode != TradePanelMode.DIRECT_SALE:
			_set_trade_panel_mode(TradePanelMode.DIRECT_SALE)
		_toggle_cargo_slot(int(s["sale_slot"]), String(s["good_id"]))
		return true
	if not bool(s.get("enabled", false)):
		_set_feedback(_lshu_reason_text(s), COLOR_INFO)
		_refresh_round_console()
		return false
	var mode := int(s.get("mode", _trade_panel_mode))
	if mode != _trade_panel_mode:
		_set_trade_panel_mode(mode)
	_lshu_row_picked = true
	var g := int(s.get("give_index", -1))
	var r := int(s.get("receive_index", -1))
	var new_pair := _trade_selector.give_index() != g or _trade_selector.receive_index() != r
	if _trade_selector.give_index() != g:
		_trade_selector.select_give_by_index(g)
	if _trade_selector.receive_index() != r:
		_trade_selector.select_receive_by_index(r)
	if new_pair:
		_trade_selector.set_times(1)      # 换了一行就从 1 次算起（复检 MKT-4）
	_sync_trade_selector_view()
	_update_trade_preview_and_buttons()
	_refresh_action_buttons()
	return _trade_selector.give_index() == g and _trade_selector.receive_index() == r


## 手柄 X 勾 / 不勾「直接卖」的一件货（pad_match.gd）。勾只是挑选、还要按 A 确认，所以落地 / 刚成交后主按钮那道闸
## （_primary_action_guarded，约 0.5 秒）不拦它——以前焦点框已经在货行上，X 却不声不响地被吞掉（安卓压力测试 PAD-MAR-6）。
## 走路中、电脑回合、换人卡、防连点之外的其余条件照旧（_can_accept_human 的其余几条）；主按钮仍按原来的闸亮
func _pad_toggle_sale_row(index: int) -> bool:
	if not _primary_action_guarded:
		return _lshu_select_row(index)
	_primary_action_guarded = false
	var ok := _lshu_select_row(index)
	_primary_action_guarded = true
	_refresh_action_buttons()          # 中间那次刷新把主按钮当成了没闸：按真实状态再刷一遍（闸放开时计时器会再刷）
	return ok


## 行尾「卖这个 / 换这个 / 买这个」：选中这一行并立刻成交（次数取行里调好的次数，默认 1 次）
func _on_lshu_row_action(index: int) -> void:
	if not _can_accept_human() or GameState.phase != GameState.Phase.TRADE or _trade_submitting:
		return
	if Time.get_ticks_msec() < _dock_block_until_ms:
		return
	if _lshu_select_row(index) and not _primary_action.disabled:
		_on_primary_action_pressed()


func _on_lshu_times_pressed(delta: int) -> void:
	_on_trade_times_arrow(delta)
	_refresh_round_console()


func _on_lshu_mode_tab(mode: int) -> void:
	if not _can_accept_human():
		return
	if not _lshu_mode_available(mode, GameState.current_player()):
		var reasons := {
			TradePanelMode.BUY: String(_cached_buy_availability.get("message", "现在买不了")),
			TradePanelMode.EXCHANGE: String(_cached_exchange_availability.get("message", "现在换不了")),
			TradePanelMode.CARD_SELL: String(_cached_card_sale_availability.get("message", "现在卖不了")),
		}
		_set_feedback(String(reasons.get(mode, "挎包里没有货可以卖")), COLOR_INFO)
		_refresh_round_console()
		return
	_set_trade_panel_mode(mode)


## 点托盘上的骰子 = 掷骰（与主按钮同一条路，同样受防连点保护）
func _on_lshu_dice_pressed() -> void:
	if GameState.players.is_empty() or GameState.phase != GameState.Phase.ROLL_DIE:
		return
	if PadInputLayer.canceled_press(self):
		return          # 系统取消的触摸（安卓）不算点
	if GameState.current_player().is_ai() or _primary_action.disabled:
		return
	if Time.get_ticks_msec() < _dock_block_until_ms:
		return
	_on_primary_action_pressed()


## 右上齿轮：点两次才回开场（防手滑丢掉一局）。
## 安卓（触屏防误触开着）：第二下还要「停一下再点」——离上一下（不管算没算）不到 0.4 秒的不算，
## 一直连点的孩子怎么点都回不了开场（和旅人幕「‹ 返回」、手柄 B 同一条规矩；安卓压力测试 TS-5）。桌面上和以前一样
const LSHU_MENU_CALM_MS := 400
var _lshu_menu_last_ms := -100000


func _on_lshu_menu_pressed() -> void:
	var now := Time.get_ticks_msec()
	var guards := PadInputLayer.guards_on(self)
	var calm := now - _lshu_menu_last_ms >= LSHU_MENU_CALM_MS
	_lshu_menu_last_ms = now
	if guards and PadInputLayer.canceled_press(self):
		return          # 系统取消的触摸不算点（TS-3）
	if now - _lshu_menu_armed_ms < 450:
		return          # 双击的第二下：不算确认（复检 EI-3）
	if now - _lshu_menu_armed_ms < 2500:
		if guards and not calm:
			return      # 连点：不算确认，停一下再点才算
		_lshu_menu_armed_ms = 0
		cancel_ai()
		back_to_title_requested.emit()
		return
	_lshu_menu_armed_ms = now
	var save_note := (
		"保留最近一次成功存档，开场点「加载存档」接着玩" if not _lshu_autosave_key.is_empty()
		else "这局还没存下来，返回会丢失进度"
	)
	_show_turn_toast("再点一次齿轮，回到开场（%s）" % save_note)


## 每个回合开始（轮到某位、还没掷骰、没有待决事件）自动存一次；只在正式入口写（测试不碰玩家的存档）
func _lshu_autosave() -> void:
	if _lshu == null or _started_session != GameState.session_generation or not LshuMatchSave.is_turn_start():
		return
	if _move_animating or _dice_rolling or not _lshu_records_progress():
		return
	var key := "%d|%d|%d" % [GameState.session_generation, GameState.round_index, GameState.current_player_index]
	if key == _lshu_autosave_key:
		return
	if LshuMatchSave.write(LshuMatchSave.snapshot(_last_configs, _lshu_clock_state())):
		_lshu_autosave_key = key


func _lshu_clock_state() -> Dictionary:
	return {"elapsed": _match_elapsed, "limit_sec": match_time_limit_sec, "unlimited": match_unlimited}


## 右上角「存档」：存的是这一回合开始的样子（回合中途的骰子、走到一半都不存），开场「加载存档」接着玩
func _on_lshu_save_pressed() -> void:
	if GameState.players.is_empty() or GameState.phase == GameState.Phase.GAME_OVER:
		return
	var here := GameState.current_player()
	var text := ""
	if LshuMatchSave.is_turn_start() and not _move_animating and not _dice_rolling:
		if _lshu_records_progress():
			if not LshuMatchSave.write(LshuMatchSave.snapshot(_last_configs, _lshu_clock_state())):
				_show_turn_toast("没能存档：存档目录写不进去，请先别退出，稍后再试")
				return
			_lshu_autosave_key = "%d|%d|%d" % [GameState.session_generation, GameState.round_index, GameState.current_player_index]
		text = "已存档：第 %d 轮 · %s的回合开始" % [GameState.round_index + 1, here.display_name]
	elif _lshu_autosave_key != "":
		text = "已存档：读档时从最近一次成功存下的回合开始接着玩"
	else:
		_show_turn_toast("这一回合结束后会自动存档")
		return
	_lshu.flash_saved()
	_show_turn_toast(text)


# ---------- 同屏多位真人：换人卡 ----------

## 轮到另一位真人时（≥2 位真人），先亮换人卡把设备交出去；卡上的按钮直接掷骰。
func _lshu_maybe_handover(next: PlayerState) -> bool:
	if _lshu == null or next == null or next.is_ai() or _lshu_human_count() < 2:
		return false
	if next.player_id == _lshu_last_human_id:
		return false
	_awaiting_turn_ack = true
	_human_input_unlocked = false
	var sub := "把设备交给%s，%s准备好了就点下面" % [next.display_name, next.display_name]
	# 电脑抽的卡改了这位的白银 / 货：换人卡上也写（卡上的按钮直接掷骰，提示条来不及看）
	var notes: Array = _fun.notices_for(next.player_id)
	_lshu.show_handover(_lshu_avatar(next), next.display_name, _lshu_seat_color(next), sub, "\n".join(notes))
	_refresh_action_buttons()
	return true


func _on_lshu_handover_go() -> void:
	if _lshu == null or not _lshu.handover.visible:
		return
	if PadInputLayer.canceled_press(self):
		return          # 系统取消的触摸（安卓）不算点：换人卡上的按钮直接掷骰
	_lshu.handover.visible = false
	_board_click_block_until_ms = Time.get_ticks_msec() + 600
	_block_dock_clicks()
	_awaiting_turn_ack = false
	_human_input_unlocked = true
	_primary_action_guarded = false
	_idle_sec = 0.0
	if not GameState.players.is_empty():
		_lshu_last_human_id = GameState.current_player().player_id
	_refresh_action_buttons()
	_refresh_move_selection()
	if GameState.phase == GameState.Phase.ROLL_DIE and not GameState.current_player().is_ai():
		_on_roll_pressed()


# ---------- 结算页 ----------

func _lshu_show_result() -> void:
	var result: Dictionary = GameState.result
	var winners: Array = result.get("winner_ids", [])
	var standings := []
	var rank := 0
	for entry in result.get("standings", []):
		rank += 1
		var p: PlayerState = null
		for q in GameState.players:
			if q.player_id == entry["player_id"]:
				p = q
				break
		standings.append({
			"rank": rank,
			"name": String(entry.get("display_name", "")),
			"avatar": _lshu_avatar(p) if p != null else null,
			"flip": _lshu_avatar_flip(p) if p != null else false,
			"color": _lshu_seat_color(p) if p != null else LshuKit.CAMEL,
			"silver": int(entry.get("silver", 0)),
			"goods": int(entry.get("goods", 0)),
			"winner": winners.has(entry["player_id"]),
		})
	var human_won := false
	var ai_won := false
	var has_ai := false
	var winner_names: Array[String] = []
	for p in GameState.players:
		if p.is_ai():
			has_ai = true
		if winners.has(p.player_id):
			winner_names.append(p.display_name)
			if p.is_local_human():
				human_won = true
			elif p.is_ai():
				ai_won = true
	var title := ""
	if bool(result.get("is_tie", false)):
		title = "平手啦！"
	elif _lshu_human_count() == 1 and human_won:
		title = "你赢啦！"
	else:
		title = "%s赢啦！" % "、".join(winner_names)
	# 胜场（Carlos：「人vs机胜利，而全人类玩家不计入」）：有电脑同场、真人赢了、且没有电脑一起并列赢才算——
	# 和电脑打平不算赢过电脑（复检 WIN-3）；全是真人时总有人赢，不计入。只在正式游戏里写盘
	var counts := human_won and has_ai and not ai_won
	var progress_text := ""
	var save_failed := false
	# 自制地图（D2 = A，docs/design/map-editor-20260930/DESIGN.md R28）：只有模拟验过的接法赢了电脑才算胜场；
	# 没地图、只改布局的地图照旧算
	if counts and not CustomMapWin.counts(GameState.content):
		counts = false
		progress_text = MAP_TRIAL_TEXT
	if counts:
		var prog := LshuProgressScript.new()
		prog.load_progress()
		if not _lshu_win_recorded and _lshu_records_progress():
			save_failed = not prog.add_win()
			_lshu_win_recorded = not save_failed
		# 不写盘的场合（测试、预览）也按「这局算进去」来显示，数字和「+1」对得上
		var wins_now := prog.wins if _lshu_win_recorded or save_failed else prog.wins + 1
		var nxt: Dictionary = {}
		for act in LshuProgressScript.ACTS:
			if int(act.get("wins", 0)) > wins_now - 1:
				nxt = act
				break
		progress_text = "胜场 +1 · 已经赢了 %d 局" % wins_now
		if not nxt.is_empty():
			var left := int(nxt.get("wins", 0)) - wins_now
			progress_text += "\n" + ("解锁了新的旅行地：%s！" % String(nxt.get("name", "")) if left <= 0 else "再赢 %d 局解锁「%s」" % [left, String(nxt.get("name", ""))])
		if save_failed:
			# 写不进盘就别说「+1」（复检 WIN-5）
			progress_text = "这局赢了！可惜胜场没能存下来（存档目录写不进去）"
	var guide := (
		"干得漂亮！下一站，更大的世界在等你！" if human_won and not ai_won
		else "和电脑打平了！再多赚一点，下一局就能赢过它。" if human_won and ai_won
		else "差一点点！换条路线，下一局再来。"
	)
	if String(result.get("end_reason", "")) == "TIME":
		guide = "%d 分钟到啦，按白银算。" % int(round(match_time_limit_sec / 60.0)) + guide
	if _turn_toast != null:
		_turn_toast.visible = false
	_lshu.show_result(title, standings, progress_text, guide)
	var r_layer := %ResultOverlay.get_parent()
	if r_layer is CanvasLayer:
		(r_layer as CanvasLayer).visible = false


## 自制地图没验过的接法，结算页的孩子话（R28）
const MAP_TRIAL_TEXT := "这张自制地图还在试玩，这局不算胜场"
## 结算页开着时从工坊切回来、并且工坊里新导入了地图（3.1）：只提示，不改这一局
const MAP_NEW_INSTALLED_TEXT := "工坊里装了新地图，回标题页换上"


func _notification(what: int) -> void:
	if what != NOTIFICATION_APPLICATION_FOCUS_IN or _lshu == null or not _lshu.result.visible:
		return
	if not CustomMapSettings.installed_changed(get_tree()):
		return
	var label: Variant = _lshu.get("_result_progress")
	if label is Label and not (label as Label).text.contains(MAP_NEW_INSTALLED_TEXT):
		(label as Label).text = ((label as Label).text + "\n" if not (label as Label).text.is_empty() else "") + MAP_NEW_INSTALLED_TEXT
		(label as Label).visible = true


func _lshu_records_progress() -> bool:
	# 项目主场景或 3D 棋盘入口（复检 MS-7：以前用 3D 入口玩赢了不记胜场，结算页却写「胜场 +1」）
	return LshuMatchSettings.is_real_game(get_tree())


## 自动化验收快照（新界面）
func get_lshu_hud_debug_state() -> Dictionary:
	if _lshu == null:
		return {}
	return {
		"round_text": _hud_current_action.text,
		"steps": [0, 1, 2, 3].map(func(i): return _lshu.step_state(i)),
		"satchel_name": _lshu.satchel_name.text,
		"roster_count": _lshu.chip_count(),
		"market_mode": _lshu.market_mode,
		"market_title": _lshu.market_title.text,
		"market_rows": _lshu.market_row_count(),
		"exchange_visible": _lshu.market_exchange.visible,
		"legacy_scroll_visible": _hud_scroll_root.visible,
		"handover_visible": _lshu.handover.visible,
		"result_visible": _lshu.result.visible,
		"prompt_text": _hud_prompt.text,
		"board_inset": _lshu_inset_goal,
		"k": _lshu.k,
		"choice_visible": _lshu.market_choice.visible,
		"campfire_visible": _lshu.campfire.visible,
		"prompt_lines": _lshu.prompt_lines(),
		"fun": _fun.debug_state(),
	}
