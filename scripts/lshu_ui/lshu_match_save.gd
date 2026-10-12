extends RefCounted
## 商旅模式存档（2026-09-27 Carlos：「到现在我都没有发现对局中存档按钮在哪」）。
## 只存「回合开始」这一刻：轮到某位玩家、还没掷骰、没有待决事件、没有动画。这一刻的对局全在 GameState 和各位玩家的
## PlayerState 里（牌堆、公共货物银两、城市贸易卡、随机数的进度），界面全部能从这些数据重新画出来，读档后就像刚轮到这位玩家。
## 每个回合开始自动存一次；对局里右上角的「存档」按钮把这一刻的存档再确认一遍（提示「已存档」）；一局结束就删掉。
## 文件和胜场放在一起：~/Library/Application Support/ShanheLvren/merchant_save.txt（var_to_str 文本，保留整数 / 浮点 / 空值的类型）。
## 只在正式入口写（测试、预览不碰玩家的存档），见 game_screen.gd _lshu_records_progress()。
## 自制地图（docs/design/map-editor-20260930/DESIGN.md R23、3.8）：用了地图的存档在 state 里多一个 custom_map_overlay
## （整份覆盖层），外层 schema 写 lshu.merchant_save.v1+map；读档时先把这份覆盖层登记进缓存，再按存档里的选项合并，
## 不依赖外面的地图文件（玩家存档后可能改图、删图、换装别的图）。旧版程序遇到 v1+map 直接不认（read 返回空），
## 不会把自制地图的对局悄悄套到原版上。没用地图的存档一字不变。

const Progress := preload("res://scripts/lshu_ui/lshu_progress.gd")
const FILE_NAME := "merchant_save.txt"
const SCHEMA := "lshu.merchant_save.v1"
const SCHEMA_MAP := "lshu.merchant_save.v1+map"
const MSG_MAP_2D := "这局用了自制地图，只能在 3D 版里接着玩。"
const MSG_MAP_UNREADABLE := "这一局用的是自制地图，地图资料读不到，存档接不上。请更新游戏。"
const KID_MAP_UNREADABLE := "这局用的地图读不到"
const KID_MAP_2D := "这局用了自制地图，只能在 3D 版里接着玩"

const STATE_FIELDS := [
	"rng_seed", "current_player_index", "round_index", "session_mode", "human_player_id",
	"silver_supply", "reserve_silver_used", "goods_supply", "trade_decks_state", "event_decks_state",
	"city_market_states", "end_triggered", "end_triggered_round", "end_reason",
]
const PLAYER_FIELDS := [
	"player_id", "display_name", "seat_index", "turn_order", "color_id", "controller_type", "ai_difficulty",
	"silver", "inventory", "warehouse_capacity", "warehouse_slots", "starting_city_card_id", "home_city_id",
	"starting_resource_snapshot", "camel_token_id", "ship_token_id", "active_transport", "reserve_transport",
	"current_node_id", "completed_turns", "die_result", "movement_budget", "movement_spent",
	"pending_event_needs_move", "move_confirmed", "opened_trade_route_this_turn", "trade_action_used",
	"turn_command_log", "event_tokens",
]


static func path() -> String:
	return Progress.dir_path().path_join(FILE_NAME)


## 这一刻能不能当存档：回合开始、没掷骰、没有待决事件、还没结束
static func is_turn_start() -> bool:
	if GameState.players.is_empty() or GameState.phase != GameState.Phase.ROLL_DIE:
		return false
	if not GameState.pending_event_decision.is_empty() or not GameState.result.is_empty():
		return false
	return GameState.current_player().die_result == null


## 把这一刻拍下来（configs：开局时的座位配置，「再来一局」要用；clock：GameScreen 的计时）
static func snapshot(configs: Array, clock: Dictionary) -> Dictionary:
	var state := {}
	for f in STATE_FIELDS:
		state[f] = GameState.get(f)
	state["rng_state"] = GameState.get_rng_state()
	# 这一局开了扩展包（「L叔的趣味事件」）：记下选项，读档时按同样的选项把扩展卡并回去（牌堆里有扩展卡的 id）
	var expansions := ExpansionLoader.options_of(GameState.content)
	if not expansions.is_empty():
		state["expansion_options"] = expansions
	# 这一局用了自制地图：整份覆盖层跟着存档走（约 20 KB），schema 升到 v1+map
	var schema := SCHEMA
	if GameState.content.has("custom_map"):
		state["custom_map_overlay"] = CustomMapLoader.overlay_of(GameState.content).duplicate(true)
		schema = SCHEMA_MAP
	var players := []
	for p in GameState.players:
		var d := {}
		for f in PLAYER_FIELDS:
			d[f] = (p as PlayerState).get(f)
		players.append(d)
	return {
		"schema": schema,
		"saved_at": Time.get_datetime_string_from_system(false, true),
		"state": state,
		"players": players,
		"configs": configs.duplicate(true),
		"clock": clock.duplicate(),
		# Variant text sorts dictionaries; only this traversal order selects tied AI targets.
		"city_market_order": GameState.city_market_states.keys(),
	}


static func write(snap: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(Progress.dir_path())
	var tmp := path() + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(var_to_str(snap))
	# 打开成功不代表写完：磁盘满或文件大小受限时，先确认缓冲区落盘成功，才替换健康存档。
	f.flush()
	var written := f.get_error() == OK
	f.close()
	if not written:
		DirAccess.remove_absolute(tmp)
		return false
	return DirAccess.rename_absolute(tmp, path()) == OK


## 读存档；没有、坏了、版本不对都返回空字典
static func read() -> Dictionary:
	if not FileAccess.file_exists(path()):
		return {}
	var v: Variant = str_to_var(FileAccess.get_file_as_string(path()))
	if not v is Dictionary:
		return {}
	var d := v as Dictionary
	var schema := String(d.get("schema", ""))
	if (schema != SCHEMA and schema != SCHEMA_MAP) or not d.get("players") is Array or (d.get("players") as Array).size() < 2:
		return {}
	if not d.get("state") is Dictionary or not d.get("configs") is Array:
		return {}
	return d


static func exists() -> bool:
	return not read().is_empty()


static func clear() -> void:
	if FileAccess.file_exists(path()):
		DirAccess.remove_absolute(path())


## 开场按钮下的一行小字：「第 3 轮 · 小驼铃的回合」
static func summary(d: Dictionary) -> String:
	if d.is_empty():
		return ""
	var st: Dictionary = d.state
	var players: Array = d.players
	var idx := clampi(int(st.get("current_player_index", 0)), 0, players.size() - 1)
	return "第 %d 轮 · %s的回合" % [int(st.get("round_index", 0)) + 1, String((players[idx] as Dictionary).get("display_name", ""))]


## 把存档装回 GameState（先 reset_session，再按模式读规则数据）。成功返回 {success: true, configs, clock, home_city_name}
static func restore(d: Dictionary) -> Dictionary:
	if d.is_empty():
		return {"success": false, "message": "没有可以接着玩的存档。"}
	var st: Dictionary = d.state
	# Old saves without this optional array keep their existing restore path.
	if d.has("city_market_order"):
		var ordered := _restore_market_order(st.get("city_market_states"), d.city_market_order)
		if not bool(ordered.get("ok", false)):
			return {"success": false, "message": "存档的市场顺序记录不完整。"}
		st = st.duplicate(false)
		st.city_market_states = ordered.value
		d = d.duplicate(false)
		d.state = st
	var mode := String(st.get("session_mode", "FORMAL"))
	if not _map_binding_valid(d):
		return {"success": false, "message": MSG_MAP_UNREADABLE}
	# 用了自制地图的存档：2D 主场景（入口门关着）不恢复，也不删存档（R3）；先把存档里的覆盖层登记进缓存
	var map_overlay: Variant = st.get("custom_map_overlay")
	if map_overlay != null:
		if not map_overlay is Dictionary or not CustomMapSettings.entry_open(CustomMapSettings.current_tree()):
			return {"success": false, "message": MSG_MAP_2D if map_overlay is Dictionary else MSG_MAP_UNREADABLE}
		if not bool(CustomMapLoader.remember(map_overlay).get("ok", false)):
			return {"success": false, "message": MSG_MAP_UNREADABLE}
	var content := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR if mode != "DEMO_1V1" else GameData.DEMO_RULESET_DIR)
	if content.is_empty():
		return {"success": false, "message": "规则数据读不到，存档接不上。"}
	var expansions: Variant = st.get("expansion_options", {})
	if ExpansionLoader.is_any_enabled(expansions):
		var merged := ExpansionLoader.apply(content, expansions)
		if not bool(merged.get("success", false)):
			if map_overlay != null:
				return {"success": false, "message": MSG_MAP_UNREADABLE}
			return {"success": false, "message": "这一局开了「L叔的趣味事件」，扩展包读不到，存档接不上。"}
		content = merged["content"]
	# 规则和整份地图都接得上才替换会话；失败不能清掉还在内存里的上一局。
	GameState.reset_session()
	GameState.content = content
	for f in STATE_FIELDS:
		if st.has(f):
			GameState.set(f, st[f])
	GameState.set_rng_seed(int(st.get("rng_seed", 0)))
	if st.has("rng_state"):
		GameState.set_rng_state(int(st.rng_state))
	var players: Array = []
	for pd in d.players:
		var p := PlayerState.new()
		for f in PLAYER_FIELDS:
			if not (pd as Dictionary).has(f):
				continue
			if f == "warehouse_slots":
				p.warehouse_slots.assign((pd as Dictionary)[f])
			else:
				p.set(f, (pd as Dictionary)[f])
		players.append(p)
	GameState.players = players
	GameState.current_player_index = clampi(GameState.current_player_index, 0, players.size() - 1)
	GameState.phase = GameState.Phase.ROLL_DIE
	GameState.pending_event_decision = {}
	GameState.result = {}
	var home := ""
	for p in players:
		if (p as PlayerState).is_local_human():
			home = GameData.get_city_name(content, (p as PlayerState).home_city_id)
			break
	return {"success": true, "configs": d.configs, "clock": d.get("clock", {}), "home_city_name": home}


## 标题页「加载存档」按钮的轻查（只读，不做整份校验）：{ok, kid_text}。
## 不带自制地图的存档直接通过；带的话只查入口门、覆盖层的 schema、生成器版本、目录版本（3.8）
static func quick_check(d: Dictionary) -> Dictionary:
	if d.is_empty():
		return {"ok": false, "kid_text": ""}
	if not _map_binding_valid(d):
		return {"ok": false, "kid_text": KID_MAP_UNREADABLE}
	var st: Variant = d.get("state")
	if not st is Dictionary or not (st as Dictionary).has("custom_map_overlay"):
		return {"ok": true, "kid_text": ""}
	var overlay: Variant = (st as Dictionary).get("custom_map_overlay")
	if not CustomMapSettings.entry_open(CustomMapSettings.current_tree()):
		return {"ok": false, "kid_text": KID_MAP_2D}
	if not overlay is Dictionary:
		return {"ok": false, "kid_text": KID_MAP_UNREADABLE}
	var o: Dictionary = overlay
	var cv: Variant = o.get("catalogue_version")
	if String(o.get("schema", "")) not in CustomMapSchema.SUPPORTED_SCHEMAS or not String(o.get("tradegen", "")) in CustomMapSchema.KNOWN_TRADEGENS \
			or not (cv is int or cv is float) or int(cv) > CustomMapSchema.CATALOGUE_VERSION:
		return {"ok": false, "kid_text": KID_MAP_UNREADABLE}
	if o.has("plants") and (str(o.schema) not in [CustomMapPlants.SCHEMA, CustomMapLocalAssets.SCHEMA, CustomMapCityIntro.SCHEMA, CustomMapPieceSkins.SCHEMA] or CustomMapPlants.error(o.plants) != "" or CustomMapPlants.dependencies_error(o.plants) != ""):
		return {"ok": false, "kid_text": KID_MAP_UNREADABLE}
	if CustomMapPieceSkins.error(o) != "" or CustomMapCityIntro.error(o) != "" or CustomMapLocalAssets.layer_error(o) != "":
		return {"ok": false, "kid_text": KID_MAP_UNREADABLE}
	return {"ok": true, "kid_text": ""}


## 地图存档的三处标记必须一致：新 schema、嵌入的完整地图、启用选项里的同一份 sha。
## 缺任何一处都拒收；尤其不能因为地图字段被删掉而把新城/新牌堆状态装进原版规则。
## 原版 v1 存档没有这三处标记，保持原来的读取路径。
static func _map_binding_valid(d: Dictionary) -> bool:
	var st: Variant = d.get("state")
	if not st is Dictionary:
		return false
	var options: Variant = st.get("expansion_options", {})
	var has_option: bool = options is Dictionary and (options as Dictionary).has(CustomMapSchema.OPTION_ID)
	var has_map: bool = str(d.get("schema", "")) == SCHEMA_MAP or st.has("custom_map_overlay") or has_option
	if not has_map:
		return true
	if str(d.get("schema", "")) != SCHEMA_MAP or str(st.get("session_mode", "")) != "FORMAL" or not st.get("custom_map_overlay") is Dictionary or not has_option:
		return false
	var option: Variant = options[CustomMapSchema.OPTION_ID]
	if not option is Dictionary or option.get("enabled") != true:
		return false
	var overlay: Dictionary = st["custom_map_overlay"]
	return str(option.get("sha256", "")) == CustomMapSchema.sha256(overlay)


## Preserve a single order-sensitive dictionary, never a second copy of resources.
static func _restore_market_order(markets: Variant, order: Variant) -> Dictionary:
	if not markets is Dictionary or not order is Array or order.size() != markets.size():
		return {"ok": false}
	var result := {}
	for key in order:
		if not key is String or not markets.has(key) or result.has(key): return {"ok": false}
		result[key] = markets[key]
	return {"ok": true, "value": result}
