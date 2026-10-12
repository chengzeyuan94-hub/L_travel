class_name SetupSystem

## 原版开局：洗牌、发城市卡、发放起始资源、建立公共白银。
## 相同种子与相同玩家输入必须得到相同开局。
## use_fixture=true 时仅接受 test_fixture；失败时完整 reset，不留下半初始化状态。
##
## 轻量 1v1 采用两阶段开局：prepare_new_game 洗牌、发城市卡、停在交通确认状态；
## finalize_new_game 应用交通选择、翻起始贸易卡、发起始资源、建立银库，进入 ROLL_DIE。
## start_new_game 是两阶段的组合包装器，供 fixture / 本地多人保持原有一次性调用方式。
## 正式模式 2–4 个座位、真人 / 电脑任意组合（本地轮流玩）：设置页用 update_prepared_seats 改座位属性、
## update_prepared_seat_difficulty 改单个电脑的难度、reprepare_with_seats 加减座位；
## 旧的 1v1 接口 update_prepared_display_config / update_prepared_ai_difficulty 保留给原设置页。

## player_configs: [{"display_name", "color_id", "controller_type" (可选，默认 LOCAL_HUMAN), "starting_transport" (可选),
##                    "ai_difficulty" (可选，AI 难度：qingzhuang / shanhai / wanli，默认 shanhai)}]
static var _pending_configs: Array = []


## 设置页只更新已准备会话的显示属性，不重新发牌、不消耗 RNG。
## 成功时仅触发一次 state_changed。
static func update_prepared_display_config(
	human_name: String,
	human_color_id: String,
	ai_color_id: String
) -> Dictionary:
	if GameState.session_mode != "DEMO_1V1" and GameState.session_mode != "FORMAL":
		return _fail("当前会话不支持更新商旅显示信息。")
	if GameState.phase != GameState.Phase.SETUP_TRANSPORT:
		return _fail("当前没有可更新的开局。")
	if GameState.players.size() != 2:
		return _fail("该显示配置接口仅支持 1v1 开局。")
	var valid_colors := {}
	for color in GameData.get_player_colors(GameState.content):
		valid_colors[String(color.get("id", ""))] = true
	if not valid_colors.has(human_color_id) or not valid_colors.has(ai_color_id):
		return _fail("无效的玩家颜色。")
	if human_color_id == ai_color_id:
		return _fail("玩家颜色不能重复。")
	var human := _find_player(GameState.human_player_id)
	var ai := _other_player(GameState.human_player_id)
	if human == null or ai == null:
		return _fail("1v1 玩家信息缺失。")
	var normalized_name := human_name.strip_edges()
	if normalized_name.is_empty():
		normalized_name = "玩家"
	human.display_name = normalized_name
	human.color_id = human_color_id
	human.camel_token_id = "camel_%s" % human_color_id
	human.ship_token_id = "ship_%s" % human_color_id
	ai.color_id = ai_color_id
	ai.camel_token_id = "camel_%s" % ai_color_id
	ai.ship_token_id = "ship_%s" % ai_color_id
	for i in _pending_configs.size():
		var config: Dictionary = _pending_configs[i]
		if String(config.get("controller_type", "LOCAL_HUMAN")) == "LOCAL_HUMAN":
			config["display_name"] = normalized_name
			config["color_id"] = human_color_id
		else:
			config["color_id"] = ai_color_id
		_pending_configs[i] = config
	GameState.state_changed.emit()
	return {"success": true, "message": "商旅显示信息已更新。"}


## 设置页切换电脑商旅难度：只改已准备会话里 AI 玩家的难度，不重新发牌、不消耗 RNG。
static func update_prepared_ai_difficulty(difficulty: String) -> Dictionary:
	if GameState.phase != GameState.Phase.SETUP_TRANSPORT:
		return _fail("当前没有可更新的开局。")
	var level := AIDifficulty.normalize(difficulty)
	for player in GameState.players:
		if (player as PlayerState).is_ai():
			(player as PlayerState).ai_difficulty = level
	for i in _pending_configs.size():
		var config: Dictionary = _pending_configs[i]
		if String(config.get("controller_type", "LOCAL_HUMAN")) == "AI":
			config["ai_difficulty"] = level
			_pending_configs[i] = config
	GameState.state_changed.emit()
	return {"success": true, "message": "电脑商旅难度：%s。" % AIDifficulty.display_name(level)}


## 设置页 N 座位（2–4 人，真人 / 电脑任意组合）：按座位顺序整体更新已准备会话里每位玩家的
## 名字、颜色、真人 / 电脑、电脑难度。不重新发牌、不消耗 RNG；成功时只触发一次 state_changed。
## configs 与 prepare_new_game 同格式，数量必须等于已准备的玩家数；加减座位用 reprepare_with_seats。
## DEMO_1V1 仍只能是 1 名真人 + 1 名电脑。返回值里的 prepare 是刷新后的开局预览（同 prepared_payload）。
static func update_prepared_seats(configs: Array) -> Dictionary:
	if GameState.session_mode != "DEMO_1V1" and GameState.session_mode != "FORMAL":
		return _fail("当前会话不支持更新商旅显示信息。")
	if GameState.phase != GameState.Phase.SETUP_TRANSPORT:
		return _fail("当前没有可更新的开局。")
	if configs.size() != GameState.players.size():
		return _fail("座位数变了，要用同一种子重新准备开局。")
	var checked := _check_seat_configs(GameState.content, configs, GameState.session_mode)
	if not bool(checked.get("success", false)):
		return checked
	var normalized: Array = checked["configs"]
	for i in normalized.size():
		var config: Dictionary = normalized[i]
		var player: PlayerState = GameState.players[i]
		player.display_name = String(config["display_name"])
		player.color_id = String(config["color_id"])
		player.camel_token_id = "camel_%s" % player.color_id
		player.ship_token_id = "ship_%s" % player.color_id
		player.controller_type = String(config["controller_type"])
		player.ai_difficulty = AIDifficulty.normalize(String(config.get("ai_difficulty", ""))) if player.is_ai() else ""
		# 保留原配置里设置页不管的字段（FIXTURE 的 starting_transport 等），只覆盖座位属性
		var pending: Dictionary = (_pending_configs[i] as Dictionary).duplicate() if i < _pending_configs.size() else {}
		for key in ["display_name", "color_id", "controller_type"]:
			pending[key] = config[key]
		if player.is_ai():
			pending["ai_difficulty"] = player.ai_difficulty
		else:
			pending.erase("ai_difficulty")
		if i < _pending_configs.size():
			_pending_configs[i] = pending
		else:
			_pending_configs.append(pending)
	_refresh_human_player_id()
	GameState.state_changed.emit()
	return {"success": true, "message": "商旅座位已更新。", "prepare": _prepare_payload()}


## 设置页给某一个电脑座位换难度（按座位下标）；不重新发牌、不消耗 RNG。
static func update_prepared_seat_difficulty(seat_index: int, difficulty: String) -> Dictionary:
	if GameState.phase != GameState.Phase.SETUP_TRANSPORT:
		return _fail("当前没有可更新的开局。")
	if seat_index < 0 or seat_index >= GameState.players.size():
		return _fail("没有这个座位。")
	var player: PlayerState = GameState.players[seat_index]
	if not player.is_ai():
		return _fail("这个座位不是电脑小伙伴。")
	var level := AIDifficulty.normalize(difficulty)
	player.ai_difficulty = level
	if seat_index < _pending_configs.size():
		var config: Dictionary = (_pending_configs[seat_index] as Dictionary).duplicate()
		config["ai_difficulty"] = level
		_pending_configs[seat_index] = config
	GameState.state_changed.emit()
	return {"success": true, "message": "%s：%s。" % [player.display_name, AIDifficulty.display_name(level)]}


## 设置页加减座位：用已准备会话的同一种子、同一模式重新准备。洗牌顺序与人数无关
## （事件牌、贸易牌先洗，城市卡整副洗好后按座位顺序发），所以留下来的座位拿到的起始城市不变。
## 校验失败时原会话保持不动；准备中途失败时和 prepare_new_game 一样整体 reset。
static func reprepare_with_seats(configs: Array) -> Dictionary:
	if GameState.phase != GameState.Phase.SETUP_TRANSPORT:
		return _fail("当前没有可更新的开局。")
	var mode := GameState.session_mode
	if mode != "FORMAL" and mode != "DEMO_1V1":
		return _fail("当前会话不支持调整座位。")
	var content: Dictionary = GameState.content
	return prepare_new_game(content, configs, GameState.rng_seed, mode)


## 设置页切扩展包开关（「L叔的趣味事件」和子开关「耳听八方」）：用已准备会话的同一种子、同一桌座位重新准备。
## 扩展卡在原版洗牌、发城市卡之后才并进事件牌堆，所以切开关不改变谁从哪座城出发、起始贸易卡和起始资源。
## 失败（扩展包不完整）时原会话保持不动。options 为空字典 = 回到原版。
static func set_prepared_expansion_options(options: Variant) -> Dictionary:
	if GameState.phase != GameState.Phase.SETUP_TRANSPORT:
		return _fail("当前没有可更新的开局。")
	var mode := GameState.session_mode
	var normalized := ExpansionLoader.normalize_options(options)
	if mode != "FORMAL" and not normalized.is_empty():
		return _fail("扩展包只能叠加在正式十六城对局上。")
	return prepare_new_game(GameState.content, _pending_configs.duplicate(true), GameState.rng_seed, mode, normalized)


## 已准备会话的开局预览（prepare_new_game 的返回值同款）：顶层是第一位真人的起始城市 / 资源 / 交通，
## seats 里按座位顺序给出每位玩家的同样信息。
static func prepared_payload() -> Dictionary:
	return _prepare_payload()


## 第一阶段：校验、重置、洗牌、发城市卡，停在 SETUP_TRANSPORT 阶段。
## session_mode: "DEMO_1V1" | "FIXTURE" | "FORMAL"
## expansion_options：扩展包选项（ExpansionLoader.normalize_options 的形状；空字典 = 原版）。
## 不传（null）时沿用 content 上次合并时的选项（设置页加减座位、改开关后重新准备都走这里）；原版 content 就是原版。
## 扩展包只能叠加在 FORMAL 会话上：先用合并前的基础包过 validate_content，再过扩展包自己的门禁；
## 原版的洗牌、发城市卡照旧用基础包、随机数消耗和原版一模一样，最后才把扩展卡并进事件牌堆再洗一次。
static func prepare_new_game(
	content: Dictionary,
	player_configs: Array,
	seed: int = -1,
	session_mode: String = "DEMO_1V1",
	expansion_options: Variant = null
) -> Dictionary:
	var is_demo := session_mode == "DEMO_1V1"
	var use_fixture := session_mode == "FIXTURE"
	var options := ExpansionLoader.normalize_options(
		ExpansionLoader.options_of(content) if expansion_options == null else expansion_options
	)
	content = ExpansionLoader.base_content_of(content)
	var validation: Dictionary = (
		GameData.validate_demo_content(content) if is_demo else GameData.validate_content(content, use_fixture)
	)
	if not validation["valid"]:
		return {"success": false, "message": "内容不完整：%s" % "; ".join(validation["missing"])}
	var play_content := content
	if not options.is_empty():
		if session_mode != "FORMAL":
			return {"success": false, "message": "扩展包只能叠加在正式十六城对局上。"}
		var merged := ExpansionLoader.apply(content, options)
		if not bool(merged.get("success", false)):
			return {"success": false, "message": String(merged.get("message", "扩展包不完整。"))}
		play_content = merged["content"]
	var ruleset: Dictionary = content["ruleset"]
	var min_players := int(ruleset.get("min_players", 2))
	var max_players := int(ruleset.get("max_players", 4))
	if is_demo:
		if player_configs.size() != 2:
			return {"success": false, "message": "轻量 1v1 必须恰好 2 名玩家。"}
	elif player_configs.size() < min_players or player_configs.size() > max_players:
		return {"success": false, "message": "玩家人数必须为 %d–%d。" % [min_players, max_players]}
	var colors := {}
	for color in GameData.get_player_colors(content):
		colors[color["id"]] = true
	var used_colors := {}
	var human_count := 0
	var ai_count := 0
	var normalized_configs: Array = []
	for raw_config in player_configs:
		var config: Dictionary = (raw_config as Dictionary).duplicate()
		if String(config.get("display_name", "")).strip_edges().is_empty():
			return {"success": false, "message": "玩家名称不能为空。"}
		var color_id := String(config.get("color_id", ""))
		if not colors.has(color_id):
			return {"success": false, "message": "无效的玩家颜色。"}
		if used_colors.has(color_id):
			return {"success": false, "message": "玩家颜色不能重复。"}
		used_colors[color_id] = true
		var controller_type := String(config.get("controller_type", "LOCAL_HUMAN"))
		if controller_type != "LOCAL_HUMAN" and controller_type != "AI":
			return {"success": false, "message": "无效的玩家控制类型。"}
		config["controller_type"] = controller_type
		if controller_type == "LOCAL_HUMAN":
			human_count += 1
		else:
			ai_count += 1
		# FORMAL 的起始交通由洗到的城市卡决定，设置页和调用者不得预先覆盖。
		# FIXTURE 没有正式城市卡交通字段，继续沿用显式配置以保持测试兼容。
		if use_fixture:
			var transport := int(config.get("starting_transport", -1))
			if transport != GameData.Transport.CAMEL and transport != GameData.Transport.SHIP:
				return {"success": false, "message": "无效的起始交通工具。"}
		normalized_configs.append(config)
	if is_demo and (human_count != 1 or ai_count != 1):
		return {"success": false, "message": "轻量 1v1 必须恰好 1 名真人与 1 名 AI。"}
	if content["city_cards"].size() < normalized_configs.size():
		return {"success": false, "message": "城市卡数量不足以开局。"}

	GameState.reset_session()
	GameState.content = play_content
	GameState.session_mode = session_mode
	if seed >= 0:
		GameState.set_rng_seed(seed)
	else:
		GameState.randomize_rng_seed()

	_shuffle_event_decks(content)
	_shuffle_trade_decks(content)
	_init_goods_supply(content)
	_init_city_markets(content)
	var players_result := _create_players(content, normalized_configs, ruleset)
	if not bool(players_result.get("success", false)):
		return _abort(String(players_result.get("message", "开局失败。")))
	if not options.is_empty():
		ExpansionLoader.merge_into_event_decks(play_content)
		# 自制地图：新货供应、新城市场、新牌堆（各用自己的随机数洗，不碰上面这条随机数流）。content 里没有 custom_map 时什么都不做
		CustomMapLoader.init_session_state(play_content)

	_pending_configs = normalized_configs
	_refresh_human_player_id()
	GameState.phase = GameState.Phase.SETUP_TRANSPORT
	print(
		"SetupSystem: prepared game, seed = %d, players = %d, session_mode = %s"
		% [GameState.rng_seed, GameState.players.size(), session_mode]
	)
	GameState.state_changed.emit()
	return _prepare_payload()


## 第二阶段：应用交通选择、翻起始贸易卡、发起始资源、建立银库，进入 P1 ROLL_DIE。
## DEMO_1V1 允许玩家在港口确认交通；FORMAL 严格读取城市卡；FIXTURE 使用测试配置。
static func finalize_new_game(human_transport: int = -1, ai_transport: int = -1) -> Dictionary:
	if GameState.phase != GameState.Phase.SETUP_TRANSPORT:
		return _fail("当前阶段不能确认交通工具。")
	var content: Dictionary = GameState.content
	var transports: Dictionary = {}
	if GameState.session_mode == "DEMO_1V1":
		var human := _find_player(GameState.human_player_id)
		var ai := _other_player(GameState.human_player_id)
		if human == null or ai == null:
			return _abort("演示模式玩家缺失。")
		var human_check := _validate_transport_choice(content, human, human_transport)
		if not human_check["success"]:
			return _abort(String(human_check["message"]))
		transports[human.player_id] = human_transport
		var resolved_ai_transport := ai_transport
		if resolved_ai_transport < 0:
			resolved_ai_transport = _default_ai_transport(content, ai)
		var ai_check := _validate_transport_choice(content, ai, resolved_ai_transport)
		if not ai_check["success"]:
			return _abort(String(ai_check["message"]))
		transports[ai.player_id] = resolved_ai_transport
	elif GameState.session_mode == "FORMAL":
		for player in GameState.players:
			var resolved := _formal_starting_transport(content, player)
			if not bool(resolved.get("success", false)):
				return _abort(String(resolved.get("message", "城市卡起始交通无效。")))
			transports[player.player_id] = int(resolved["transport"])
	else:
		for i in GameState.players.size():
			var player: PlayerState = GameState.players[i]
			var config: Dictionary = _pending_configs[i] if i < _pending_configs.size() else {}
			var transport := int(config.get("starting_transport", -1))
			var check := _validate_transport_choice(content, player, transport)
			if not check["success"]:
				return _abort(String(check["message"]))
			transports[player.player_id] = transport

	# ---- 原子执行：应用交通、翻牌、发起始资源、建立银库 ----
	for player in GameState.players:
		var transport: int = transports[player.player_id]
		player.active_transport = transport
		player.reserve_transport = (
			GameData.Transport.SHIP if transport == GameData.Transport.CAMEL else GameData.Transport.CAMEL
		)

	var flip_result := _flip_starting_trade_cards(content)
	if not bool(flip_result.get("success", false)):
		return _abort(String(flip_result.get("message", "翻开起始贸易卡失败。")))
	var grant_result := _grant_starting_resources(content)
	if not bool(grant_result.get("success", false)):
		return _abort(String(grant_result.get("message", "发放起始资源失败。")))

	GameState.silver_supply = GameData.get_silver_supply_for(content, GameState.players.size())
	GameState.current_player_index = 0
	GameState.round_index = 0
	GameState.phase = GameState.Phase.ROLL_DIE
	_pending_configs = []
	print(
		"SetupSystem: finalized game, seed = %d, players = %d, supply = %d, session_mode = %s"
		% [GameState.rng_seed, GameState.players.size(), GameState.silver_supply, GameState.session_mode]
	)
	GameState.state_changed.emit()
	return {"success": true, "message": "开局完成。"}


## 一次性包装：prepare 后立即用每位玩家配置内的 starting_transport 完成 finalize。
## 供 fixture 冒烟与既有本地多人调用方式保持兼容。
static func start_new_game(
	content: Dictionary,
	player_configs: Array,
	seed: int = -1,
	use_fixture: bool = false
) -> Dictionary:
	var session_mode := "FIXTURE" if use_fixture else "FORMAL"
	var prepared := prepare_new_game(content, player_configs, seed, session_mode)
	if not bool(prepared.get("success", false)):
		return prepared
	return finalize_new_game()


# ---------- 内部：洗牌与初始化 ----------

static func _shuffle_event_decks(content: Dictionary) -> void:
	var land_draw: Array = []
	var sea_draw: Array = []
	for instance in content["event_card_instances"].values():
		if instance.get("deck_type") == "LAND":
			land_draw.append(instance["id"])
		else:
			sea_draw.append(instance["id"])
	land_draw.sort()
	sea_draw.sort()
	GameState.rng_shuffle(land_draw)
	GameState.rng_shuffle(sea_draw)
	GameState.event_decks_state = {
		GameData.DeckType.LAND: {"draw": land_draw, "discard": []},
		GameData.DeckType.SEA: {"draw": sea_draw, "discard": []},
	}


static func _shuffle_trade_decks(content: Dictionary) -> void:
	for deck_id in content["trade_decks"]:
		var draw: Array = content["trade_decks"][deck_id]["cards"].keys()
		GameState.rng_shuffle(draw)
		GameState.trade_decks_state[deck_id] = {"draw": draw, "discard": []}


static func _init_goods_supply(content: Dictionary) -> void:
	for good_id in content["goods"]:
		GameState.goods_supply[good_id] = int(content["goods"][good_id].get("supply_total", 0))


static func _init_city_markets(content: Dictionary) -> void:
	for city_id in content["cities"]:
		GameState.city_market_states[city_id] = {
			"trade_route_open": false,
			"current_trade_card_id": "",
			"opened_by_player_id": "",
			"opened_on_turn": -1,
		}


## 洗城市卡，每位玩家发 1 张并建立座位、颜色、同色骆驼与商船、固定货仓；不分配交通、不发资源。
static func _create_players(content: Dictionary, player_configs: Array, ruleset: Dictionary) -> Dictionary:
	var city_card_ids: Array = content["city_cards"].keys()
	GameState.rng_shuffle(city_card_ids)
	for i in player_configs.size():
		var config: Dictionary = player_configs[i]
		var player := PlayerState.new()
		player.player_id = "P%d" % (i + 1)
		player.display_name = String(config["display_name"]).strip_edges()
		player.seat_index = i
		player.turn_order = i
		player.color_id = String(config["color_id"])
		player.controller_type = String(config.get("controller_type", "LOCAL_HUMAN"))
		if player.controller_type == "AI":
			player.ai_difficulty = AIDifficulty.normalize(String(config.get("ai_difficulty", AIDifficulty.DEFAULT)))
		player.camel_token_id = "camel_%s" % player.color_id
		player.ship_token_id = "ship_%s" % player.color_id
		player.warehouse_capacity = int(ruleset.get("warehouse_capacity", 4))
		player.starting_city_card_id = String(city_card_ids[i])
		var card: Dictionary = content["city_cards"][player.starting_city_card_id]
		player.home_city_id = String(card["city_id"])
		var city: Dictionary = content["cities"][player.home_city_id]
		player.current_node_id = String(city["board_node_id"])
		player.reset_turn_assets()
		GameState.players.append(player)
	return {"success": true}


## 每个起始城市翻开同色贸易卡（无开通奖励）。
static func _flip_starting_trade_cards(content: Dictionary) -> Dictionary:
	for player in GameState.players:
		var city: Dictionary = content["cities"][player.home_city_id]
		var deck_id := String(city["trade_color_id"])
		var deck_state: Dictionary = GameState.trade_decks_state[deck_id]
		if deck_state["draw"].is_empty():
			return {"success": false, "message": "贸易牌堆不足以翻开起始城市贸易卡。"}
		var card_id: String = deck_state["draw"].pop_front()
		GameState.city_market_states[player.home_city_id]["current_trade_card_id"] = card_id
		GameState.city_market_states[player.home_city_id]["trade_route_open"] = true
	return {"success": true}


## 按城市卡右上角发放起始资源及数量（先于公共白银建立，起始白银出自盒内）。
static func _grant_starting_resources(content: Dictionary) -> Dictionary:
	for player in GameState.players:
		var grant := GameData.get_starting_grant(content, player.starting_city_card_id)
		for entry in grant:
			if String(entry["resource_kind"]) == "SILVER":
				player.silver += int(entry["quantity"])
			else:
				var good_id := String(entry["resource_id"])
				var quantity := int(entry["quantity"])
				if not GameState.take_good_from_supply(good_id, quantity):
					return {"success": false, "message": "商品供应不足以发放起始资源。"}
				if player.cargo_count() + quantity > player.warehouse_capacity:
					return {"success": false, "message": "起始货物超过货仓容量。"}
				player.add_good(good_id, quantity)
		if not grant.is_empty():
			player.starting_resource_snapshot = grant[0].duplicate()
	return {"success": true}


# ---------- 内部：交通确认 ----------

static func _legal_transports(content: Dictionary, node_id: String) -> Array:
	if GameData.is_port_node(content, node_id):
		return [GameData.Transport.CAMEL, GameData.Transport.SHIP]
	return [GameData.Transport.CAMEL]


static func _validate_transport_choice(content: Dictionary, player: PlayerState, transport: int) -> Dictionary:
	if transport != GameData.Transport.CAMEL and transport != GameData.Transport.SHIP:
		return _fail("无效的起始交通工具。")
	if transport not in _legal_transports(content, player.current_node_id):
		return _fail("%s 的起始城市不允许该交通工具。" % player.display_name)
	return {"success": true}


## 正式规则：起始交通是城市卡事实，不是玩家设置项。
## 同时核对 city/card 双方字段与城市可用路线，避免数据漂移被静默吞掉。
static func _formal_starting_transport(content: Dictionary, player: PlayerState) -> Dictionary:
	var cards: Dictionary = content.get("city_cards", {})
	var cities: Dictionary = content.get("cities", {})
	if not cards.has(player.starting_city_card_id):
		return _fail("%s 的起始城市卡不存在。" % player.display_name)
	if not cities.has(player.home_city_id):
		return _fail("%s 的起始城市不存在。" % player.display_name)
	var card: Dictionary = cards[player.starting_city_card_id]
	var city: Dictionary = cities[player.home_city_id]
	var card_transport := String(card.get("starting_transport", ""))
	var city_transport := String(city.get("starting_transport", ""))
	if card_transport != city_transport:
		return _fail("%s 的城市卡与城市起始交通不一致。" % player.display_name)
	var transport := -1
	var required_route := ""
	if card_transport == "CAMEL":
		transport = GameData.Transport.CAMEL
		required_route = "LAND"
	elif card_transport == "SHIP":
		transport = GameData.Transport.SHIP
		required_route = "SEA"
	else:
		return _fail("%s 的城市卡起始交通无效：%s" % [player.display_name, card_transport])
	var allowed_routes: Array = city.get("allowed_routes", [])
	if required_route not in allowed_routes:
		return _fail("%s 的城市卡交通与城市路线类型不一致。" % player.display_name)
	return {"success": true, "transport": transport, "transport_name": card_transport}


## AI 合法起始交通：优先调用 AIPolicy；类不可用时退化为骆驼优先的简单合法选择。
static func _default_ai_transport(content: Dictionary, ai_player: PlayerState) -> int:
	var legal := _legal_transports(content, ai_player.current_node_id)
	if legal.size() == 1:
		return int(legal[0])
	var decision: Dictionary = AIPolicy.choose_starting_transport(ai_player)
	var chosen: Variant = decision.get("chosen", GameData.Transport.CAMEL)
	if chosen == null or int(chosen) not in legal:
		return GameData.Transport.CAMEL
	return int(chosen)


static func _find_player(player_id: String) -> PlayerState:
	for player in GameState.players:
		if player.player_id == player_id:
			return player
	return null


static func _other_player(player_id: String) -> PlayerState:
	for player in GameState.players:
		if player.player_id != player_id:
			return player
	return null


## 第一位本地真人（座位顺序）记为 human_player_id；只有设置阶段的接口读它，规则不读。
static func _refresh_human_player_id() -> void:
	GameState.human_player_id = ""
	for player in GameState.players:
		if player.is_local_human():
			GameState.human_player_id = player.player_id
			break


## update_prepared_seats 的校验：名字非空、颜色有效且不重复、控制类型有效；DEMO_1V1 必须 1 真人 + 1 电脑。
static func _check_seat_configs(content: Dictionary, configs: Array, session_mode: String) -> Dictionary:
	var colors := {}
	for color in GameData.get_player_colors(content):
		colors[String(color.get("id", ""))] = true
	var used := {}
	var humans := 0
	var ais := 0
	var out: Array = []
	for raw in configs:
		if not raw is Dictionary:
			return _fail("座位配置无效。")
		var config: Dictionary = (raw as Dictionary).duplicate()
		var name := String(config.get("display_name", "")).strip_edges()
		if name.is_empty():
			return _fail("玩家名称不能为空。")
		config["display_name"] = name
		var color_id := String(config.get("color_id", ""))
		if not colors.has(color_id):
			return _fail("无效的玩家颜色。")
		if used.has(color_id):
			return _fail("玩家颜色不能重复。")
		used[color_id] = true
		var controller_type := String(config.get("controller_type", "LOCAL_HUMAN"))
		if controller_type != "LOCAL_HUMAN" and controller_type != "AI":
			return _fail("无效的玩家控制类型。")
		config["controller_type"] = controller_type
		if controller_type == "AI":
			ais += 1
		else:
			humans += 1
		out.append(config)
	if session_mode == "DEMO_1V1" and (humans != 1 or ais != 1):
		return _fail("轻量 1v1 必须恰好 1 名真人与 1 名 AI。")
	return {"success": true, "configs": out}


## 一个座位的开局预览：起始城市、城市卡、起始资源、起始交通（FORMAL 由城市卡锁定）。
static func _seat_payload(content: Dictionary, player: PlayerState) -> Dictionary:
	var city: Dictionary = GameData.get_city(content, player.home_city_id)
	var seat := {
		"player_id": player.player_id,
		"seat_index": player.seat_index,
		"display_name": player.display_name,
		"color_id": player.color_id,
		"controller_type": player.controller_type,
		"ai_difficulty": player.ai_difficulty,
		"home_city_id": player.home_city_id,
		"home_city_name": String(city.get("display_name", player.home_city_id)),
		"city_card_id": player.starting_city_card_id,
		"starting_grant": GameData.get_starting_grant(content, player.starting_city_card_id),
	}
	if GameState.session_mode == "FORMAL":
		var resolved := _formal_starting_transport(content, player)
		var ok := bool(resolved.get("success", false))
		seat["starting_transport"] = int(resolved["transport"]) if ok else -1
		seat["allowed_transports"] = [int(resolved["transport"])] if ok else []
		seat["starting_transport_locked"] = true
	else:
		var legal := _legal_transports(content, player.current_node_id)
		seat["starting_transport"] = int(legal[0])
		seat["allowed_transports"] = legal
		seat["starting_transport_locked"] = false
	return seat


static func _prepare_payload() -> Dictionary:
	var payload := {"success": true, "message": "已发城市卡，请确认起始交通工具。"}
	var seats: Array = []
	for player in GameState.players:
		seats.append(_seat_payload(GameState.content, player))
	payload["seats"] = seats
	payload["player_count"] = GameState.players.size()
	var expansions := ExpansionLoader.options_of(GameState.content)
	if not expansions.is_empty():
		payload["expansion_options"] = expansions
	var human := _find_player(GameState.human_player_id)
	if human == null:
		return payload
	var content: Dictionary = GameState.content
	var city: Dictionary = GameData.get_city(content, human.home_city_id)
	payload["human_player_id"] = human.player_id
	payload["home_city_id"] = human.home_city_id
	payload["home_city_name"] = String(city.get("display_name", human.home_city_id))
	payload["starting_grant"] = GameData.get_starting_grant(content, human.starting_city_card_id)
	if GameState.session_mode == "FORMAL":
		var resolved := _formal_starting_transport(content, human)
		if bool(resolved.get("success", false)):
			payload["starting_transport"] = int(resolved["transport"])
			payload["allowed_transports"] = [int(resolved["transport"])]
			payload["starting_transport_locked"] = true
		else:
			payload["success"] = false
			payload["message"] = String(resolved.get("message", "城市卡起始交通无效。"))
	else:
		payload["allowed_transports"] = _legal_transports(content, human.current_node_id)
		payload["starting_transport_locked"] = false
	payload["city_card_id"] = human.starting_city_card_id
	return payload


static func _abort(message: String) -> Dictionary:
	GameState.reset_session()
	_pending_configs = []
	return {"success": false, "message": message}


static func _fail(message: String) -> Dictionary:
	return {"success": false, "message": message}
