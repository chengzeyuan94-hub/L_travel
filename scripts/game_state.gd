extends Node

## 全局对局状态（Autoload：GameState）。多人对局的唯一数据来源。
## 规则分层见 docs/design/expandable-domain-model.md：公共供应与牌堆只属于本类，
## 不复制进玩家或城市状态。

signal state_changed

enum Phase { SETUP, SETUP_TRANSPORT, ROLL_DIE, MOVE_OR_EVENT, OPEN_TRADE_ROUTE, TRADE, END_TURN, GAME_OVER }

var content: Dictionary = {}
var rng_seed: int = 0
var players: Array = []
var current_player_index: int = 0
var round_index: int = 0
var phase: Phase = Phase.SETUP
## "" | "DEMO_1V1" | "FIXTURE" | "FORMAL"
var session_mode: String = ""
var human_player_id: String = ""
## 每次 reset_session 递增；旧的异步流程（如 AI 回合控制器）据此判断自己已过期。
var session_generation: int = 0
var silver_supply: int = 0
## 盒内备用白银（终局触发后使用）。数字记账视为不限量，记录使用量供审计。
var reserve_silver_used: int = 0
var goods_supply: Dictionary = {}
var trade_decks_state: Dictionary = {}
var event_decks_state: Dictionary = {}
var city_market_states: Dictionary = {}
var end_triggered: bool = false
var end_triggered_round: int = -1
## 终局由什么触发："SILVER"（公共白银首次拿空，原版规则）或 "TIME"（对局时长上限，
## Carlos 2026-09-25：保持原版规则，但一局最长 20 分钟）。
var end_reason: String = ""
## 对局限时的公开进度（GameScreen 每帧写入；无界面的规则测试保持默认 = 不限时）。
## 只供 AI「万里商途」估算还剩几轮，不参与任何规则判定。
var match_time_left_sec: float = INF
var match_elapsed_sec: float = 0.0
## 本局时长上限（秒，<= 0 = 不限时）；GameScreen 每帧写入，只给棋盘的日光循环用，不参与规则判定
var match_limit_sec: float = 1200.0
var result: Dictionary = {}
## 事件待决策：非空时禁止结束回合 / 重复抽事件；由 EventSystem 读写。
var pending_event_decision: Dictionary = {}

var _rng := RandomNumberGenerator.new()


func reset_session() -> void:
	content = {}
	rng_seed = 0
	players = []
	current_player_index = 0
	round_index = 0
	phase = Phase.SETUP
	session_mode = ""
	human_player_id = ""
	session_generation += 1
	silver_supply = 0
	reserve_silver_used = 0
	goods_supply = {}
	trade_decks_state = {}
	event_decks_state = {}
	city_market_states = {}
	end_triggered = false
	end_triggered_round = -1
	end_reason = ""
	match_time_left_sec = INF
	match_elapsed_sec = 0.0
	match_limit_sec = 1200.0
	result = {}
	pending_event_decision = {}


func current_player() -> PlayerState:
	return players[current_player_index]


func is_in_turn() -> bool:
	return phase == Phase.ROLL_DIE or phase == Phase.MOVE_OR_EVENT or phase == Phase.OPEN_TRADE_ROUTE or phase == Phase.TRADE or phase == Phase.END_TURN


## 从公共供应堆支付白银；不足时先取空并触发终局，差额计入盒内备用白银。
func payout_silver(amount: int) -> int:
	if amount <= 0:
		return 0
	# 供应堆首次拿空后，说明书要求本轮余下所有收入改从盒内备用白银领取。
	# 后续买入仍会把玩家支付的白银放回供应堆，但这些银两不得再次作为收入发出。
	if end_triggered:
		reserve_silver_used += amount
		return amount
	var from_supply: int = mini(amount, silver_supply)
	silver_supply -= from_supply
	if silver_supply == 0 and not end_triggered:
		end_triggered = true
		end_triggered_round = round_index
		end_reason = "SILVER"
		print("GameState: silver supply exhausted, endgame triggered in round %d" % round_index)
	var remainder := amount - from_supply
	if remainder > 0:
		reserve_silver_used += remainder
	return amount


## 对局时长用完：与公共白银拿空走同一条原版终局流程（补齐本轮后按白银→货物结算）。
## 已触发过终局则不重复触发。返回是否由本次调用触发。
func trigger_time_limit() -> bool:
	if end_triggered or phase == Phase.GAME_OVER or players.is_empty():
		return false
	end_triggered = true
	end_triggered_round = round_index
	end_reason = "TIME"
	print("GameState: match time limit reached, endgame triggered in round %d" % round_index)
	return true


func return_silver(amount: int) -> void:
	if amount > 0:
		silver_supply += amount


func take_good_from_supply(good_id: String, count: int) -> bool:
	if int(goods_supply.get(good_id, 0)) < count:
		return false
	goods_supply[good_id] = int(goods_supply[good_id]) - count
	return true


func return_good_to_supply(good_id: String, count: int) -> void:
	goods_supply[good_id] = int(goods_supply.get(good_id, 0)) + count


# ---------- 对局随机数（唯一种子源） ----------

func set_rng_seed(new_seed: int) -> void:
	rng_seed = new_seed
	_rng.seed = new_seed


## 随机数走到哪一步了（存档用：读档后骰子、洗牌和存档前一模一样地接着走）
func get_rng_state() -> int:
	return _rng.state


func set_rng_state(value: int) -> void:
	_rng.state = value


func randomize_rng_seed() -> void:
	_rng.randomize()
	rng_seed = int(_rng.randi())
	_rng.seed = rng_seed


func rng_int(bound: int) -> int:
	return _rng.randi_range(0, bound - 1)


func rng_shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func rng_pick(arr: Array) -> Variant:
	if arr.is_empty():
		return null
	return arr[rng_int(arr.size())]
