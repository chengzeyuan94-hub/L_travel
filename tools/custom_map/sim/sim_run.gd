extends Node

## 自制地图 AI 对局批量模拟（DESIGN 4.4，WP2）。由 sim_boot.gd 在 Autoload 就位后加载；每局写一行 JSON（jsonl），
## analyze.py 读这些行出报告和胜场白名单。只读仓库，不改任何仓库文件。
##
## 规则命令循环与 tests/formal_full_game_stress_tests.gd:173-248 的 _execute_one_command 相同，只是每个座位按身份选策略：
##   AI 座位：正式 AIPolicy（自制地图里带 X3）或「不死等」参考 AI（policy=nostall，只用于 S7，由 emit_nostall.py 生成）；
##   真人座位（LOCAL_HUMAN）：三种真人代理之一（只在本目录生成，不进仓库的 AI）——
##     same = proxy_same.gd（与电脑同一套）；avoid_new = emit_avoid_new.py 生成的策略副本（新城和新商道在它眼里不存在）；
##     best_loop = proxy_best_loop.gd（盯着护栏枚举出的最好循环）。
##   policy=nostall 时所有座位（包括真人座位）都用同一份「不死等」策略，记录里 proxy 写 nostall：S7 量的是经济本身，
##   不能有一半座位还在死等（DESIGN 4.4）。
##
## 参数（-- 之后，key=value）：
##   map=base|B1..B8|<拓扑键>   mode=memory|real   overlay=<真实地图文件，mode=real 时用>
##   seats=HA|HAA|HAAA|AAA...   diffs=shanhai[,wanli,...]（按 AI 座位循环）   proxy=same|avoid_new|best_loop
##   rounds=R（0 = 不限时；截断在第 R 轮的轮首调 GameState.trigger_time_limit()，补齐本轮再结算）
##   clock=1|0（截断局按 20 分钟 / R 轮模拟对局时钟，万里商途的「剩余回合」估算与真实对局同口径；默认 1）
##   policy=formal|nostall   nostall_path=<ai_policy_nostall.gd 的绝对路径>   avoid_path=<ai_policy_avoid_new.gd 的绝对路径>
##   seeds=N first=S  out=<jsonl 路径>  tag=<标签>
##   bank=k（每座新城的银库增减，覆盖参数文件 bank_delta_per_city 里这个人数的值；只在 S7 标定时用。记录里写 bank_k 和
##     bank_k_file，analyze 只拿 bank_k == bank_k_file 的记录出白名单）
##
## mode=memory：基础包照常 prepare_new_game（原版洗牌、发城市卡的随机数不变），之后把 sim_overlay.gd 按 DESIGN 3.5
##   合并好的内容换进 GameState.content，再按 3.8 补开局状态（新牌堆独立洗牌）。WP1 合入前的冒烟用。
## mode=real：走真实加载路径——CustomMapLoader.remember(覆盖层) → 带地图选项 prepare_new_game。正式模拟用这个；
##   WP1 合入前 remember 是骨架，会直接报「WP1 未集成」并退出（不会悄悄退回 memory）。

const Overlay := preload("res://tools/custom_map/sim/sim_overlay.gd")
const COLORS := ["red", "blue", "green", "yellow"]
const MAX_COMMANDS := 40000
const MATCH_SEC := 1200.0
const B_KEYS := {
	"B1": "topo_v1|e1:changan:LAND:w1|w1:aden:SEA:e1",
	"B2": "topo_v1|e1:heijokyo:SEA:w1|w1:rome:SEA:e1",
	"B3": "topo_v1|e1:simhala:LAND:w1|w1:baghdad:LAND:e1",
	"B4": "topo_v1|e1:dagon:SEA:w1|w1:panti:LAND:e1",
	"B5": "topo_v1|e1:geumseong:SEA:w1|w1:cairo:SEA:e1",
	"B6": "topo_v1|e1:yumenguan:LAND:w1|w1:jeddah:LAND:e1",
	"B7": "topo_v1|e1:changan:LAND:w1|e2:heijokyo:SEA:w2|w1:aden:SEA:e1|w2:rome:SEA:e2",
	"B8": "topo_v1|e1:simhala:LAND:w1|e2:geumseong:SEA:w2|w1:baghdad:LAND:e1|w2:cairo:SEA:e2",
}

var _args := {}
var _ai_policy: Variant = null
var _proxy: Variant = null


func run_sim() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := String(a).split("=", true, 1)
		if kv.size() == 2:
			_args[kv[0]] = kv[1]
	var code := _main()
	get_tree().quit(code)


func _arg(k: String, d: String) -> String:
	return String(_args.get(k, d))


func _main() -> int:
	var t0 := Time.get_ticks_msec()
	var base := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var map_arg := _arg("map", "base")
	var key := String(B_KEYS.get(map_arg, map_arg))
	if key == "base":
		key = ""
	var parsed_key := TradeGenV1.parse_topology_key_result(key)
	if not bool(parsed_key.ok):
		print("SIM_FATAL 拓扑键解析失败：%s" % str(parsed_key.errors))
		return 2
	var mode := _arg("mode", "memory")
	var seats := _arg("seats", "HA")
	var diffs := _arg("diffs", "shanhai").split(",")
	var proxy_name := _arg("proxy", "same")
	var rounds_cap := int(_arg("rounds", "0"))
	var clock := _arg("clock", "1") == "1"
	var policy := _arg("policy", "formal")
	var seeds := int(_arg("seeds", "10"))
	var first := int(_arg("first", "2026100100"))
	var bank_arg := _arg("bank", "")
	var out_path := _arg("out", "")
	var tag := _arg("tag", "run")
	_ai_policy = AIPolicy
	if policy == "nostall":
		_ai_policy = load(_arg("nostall_path", ""))
		if _ai_policy == null:
			print("SIM_FATAL 读不到 nostall 策略：%s（先跑 emit_nostall.py）" % _arg("nostall_path", ""))
			return 2
		_proxy = _ai_policy          # S7：真人座位也不死等
		proxy_name = "nostall"
	elif proxy_name == "avoid_new":
		_proxy = load(_arg("avoid_path", "")) if not _arg("avoid_path", "").is_empty() else null
		if _proxy == null:
			print("SIM_FATAL 读不到 avoid_new 策略：%s（先跑 emit_avoid_new.py，再传 avoid_path=）" % _arg("avoid_path", ""))
			return 2
	elif proxy_name == "same" or proxy_name == "best_loop":
		_proxy = load("res://tools/custom_map/sim/proxy_%s.gd" % proxy_name)
	if _proxy == null:
		print("SIM_FATAL 不认识的真人代理：%s" % proxy_name)
		return 2
	var merged: Dictionary = {}
	var option := {}
	if mode == "memory":
		if not key.is_empty():
			var mc := Overlay.merged_content(base, parsed_key.topology)
			if not bool(mc["ok"]):
				print("SIM_FATAL 生成失败：%s" % str(mc["errors"]))
				return 2
			merged = mc["content"]
	elif mode == "real":
		var overlay_path := _arg("overlay", "")
		# 空键明确声明基础图；只要提供 overlay，就必须核对其实际身份。
		if not overlay_path.is_empty() or not key.is_empty():
			var overlay: Variant = JSON.parse_string(FileAccess.get_file_as_string(overlay_path)) if not overlay_path.is_empty() else null
			if not overlay is Dictionary:
				print("SIM_FATAL mode=real 需要 overlay=<lshu.custom_map.v1 文件>：%s" % overlay_path)
				return 2
			if CustomMapSchema.topology_key(overlay) != TradeGenV1.topology_key(parsed_key.topology):
				print("SIM_FATAL 拓扑键与正式 overlay 不一致")
				return 2
			var rem: Dictionary = CustomMapLoader.remember(overlay)
			if not bool(rem.get("ok", false)):
				print("SIM_FATAL CustomMapLoader.remember 没通过（WP1 未集成，或地图不合格）：%s" % str(rem))
				return 2
			option = {CustomMapSchema.OPTION_ID: {"enabled": true, "sha256": String(rem.get("sha256", ""))}}
	else:
		print("SIM_FATAL 不认识的 mode：%s" % mode)
		return 2
	var f: FileAccess = null
	if not out_path.is_empty():
		f = FileAccess.open(out_path, FileAccess.WRITE)
	var fails := 0
	var t_games := Time.get_ticks_msec()
	for i in seeds:
		var rec := _play(base, merged, option, key, seats, diffs, first + i, rounds_cap, clock, bank_arg, mode)
		rec["tag"] = tag
		rec["map"] = map_arg
		rec["mode"] = mode
		rec["proxy"] = proxy_name
		rec["policy"] = policy
		if not bool(rec["ok"]):
			fails += 1
		if f != null:
			f.store_line(JSON.stringify(rec))
	if f != null:
		f.close()
	var elapsed := float(Time.get_ticks_msec() - t_games) / 1000.0
	print("SIM_DONE tag=%s games=%d fails=%d elapsed=%.1fs per_game=%.3fs total=%.1fs" % [tag, seeds, fails, elapsed,
		elapsed / maxf(1.0, float(seeds)), float(Time.get_ticks_msec() - t0) / 1000.0])
	return 0 if fails == 0 else 1


func _configs(seats: String, diffs: PackedStringArray) -> Array:
	var out: Array = []
	var ai := 0
	for i in seats.length():
		var c := {"display_name": "座位%d" % (i + 1), "color_id": COLORS[i]}
		if seats[i] == "H":
			c["controller_type"] = "LOCAL_HUMAN"
		else:
			c["controller_type"] = "AI"
			c["ai_difficulty"] = diffs[ai % diffs.size()]
			ai += 1
		out.append(c)
	return out


## 请求键与实际加载键都规范化后比较；空串是基础图声明，不是省略检查。
static func topology_for_content(content: Dictionary, expected_key: String) -> Dictionary:
	var expected := TradeGenV1.parse_topology_key_result(expected_key)
	if not bool(expected.ok):
		return expected
	var custom: Dictionary = content.get("custom_map", {})
	var parsed := TradeGenV1.parse_topology_key_result(String(custom.get("topology_key", "")))
	if not bool(parsed.ok):
		return parsed
	if TradeGenV1.topology_key(parsed.topology) != TradeGenV1.topology_key(expected.topology):
		return {"ok": false, "topology": [], "errors": ["请求拓扑与实际加载拓扑不一致"]}
	var newc: Dictionary = content.get("custom_map_new_cities", {})
	if (parsed.topology as Array).size() != newc.size():
		return {"ok": false, "topology": [], "errors": ["拓扑与实际新城数不一致"]}
	for entry in parsed.topology:
		if not newc.has("x_" + String(entry.slot)):
			return {"ok": false, "topology": [], "errors": ["拓扑槽位不在实际加载图中"]}
	var overlay: Dictionary = custom.get("overlay", {})
	if not overlay.is_empty() and CustomMapSchema.topology_key(overlay) != TradeGenV1.topology_key(parsed.topology):
		return {"ok": false, "topology": [], "errors": ["所报拓扑与实际 overlay 不一致"]}
	return parsed


func _play(base: Dictionary, merged: Dictionary, option: Dictionary, key: String, seats: String, diffs: PackedStringArray,
		seed: int, rounds_cap: int, clock: bool, bank_arg: String, mode: String) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	GameState.reset_session()
	var configs := _configs(seats, diffs)
	var prepared := SetupSystem.prepare_new_game(base, configs, seed, "FORMAL", option if not option.is_empty() else null)
	if not bool(prepared.get("success", false)):
		return {"seed": seed, "ok": false, "why": "prepare: %s" % prepared.get("message", ""), "key": key, "seats": seats}
	if not merged.is_empty():
		GameState.content = merged
		Overlay.init_session_state(merged)
	var fin := SetupSystem.finalize_new_game()
	if not bool(fin.get("success", false)):
		return {"seed": seed, "ok": false, "why": "finalize: %s" % fin.get("message", ""), "key": key, "seats": seats}
	var content: Dictionary = GameState.content
	var newc: Dictionary = content.get("custom_map_new_cities", {})
	# 银库 k（R20）：参数文件按人数给的值；mode=real 时 WP1 的 merge 已经按它改过银库，mode=memory 由这里补上。
	# bank= 只在 S7 标定时覆盖它（多出来的差额这里补），记录里两个都写，analyze 只拿两者相同的记录出白名单。
	var n_players := GameState.players.size()
	var k_file := int((TradeGenV1.product_params().get("bank_delta_per_city", {}) as Dictionary).get(str(n_players), 0))
	var k := int(bank_arg) if not bank_arg.is_empty() else k_file
	var k_apply := (k - k_file) if mode == "real" else k
	if k_apply != 0 and not newc.is_empty():
		GameState.silver_supply = maxi(1, GameState.silver_supply + k_apply * newc.size())
	var parsed_topology := topology_for_content(content, key)
	if not bool(parsed_topology.ok):
		return {"seed": seed, "ok": false, "why": str(parsed_topology.errors), "key": key, "seats": seats}
	var topo: Array = parsed_topology.topology
	var hosts: Array = []
	var partner_city := {}
	for t in topo:
		hosts.append(String(t["host"]))
		partner_city["x_" + String(t["slot"])] = "x_" + String(t["partner"])
	# 距离与产地：算「新特产远途卖出」和原版对照（离产地 ≥ 15 步按牌面卖出）
	var dist := TradeGenV1._city_distances(TradeGenV1._board_from_content(content))
	var producer := {}
	for cc in (content.get("city_cards", {}) as Dictionary).values():
		var ent: Dictionary = cc["starting_grant"]["entries"][0]
		if String(ent["resource_kind"]) == "GOOD":
			producer[String(ent["resource_id"])] = String(cc["city_id"])
	var players_info: Array = []
	for pv in GameState.players:
		var p := pv as PlayerState
		players_info.append({"id": p.player_id, "controller": "H" if p.is_local_human() else "A",
			"diff": p.ai_difficulty, "start_city": GameData.get_city_at_node(content, p.current_node_id)})
	var trades_by_city := {}
	var ai_turns := {"new": 0, "orig": 0}
	var stall := {"new": 0, "orig": 0}
	var ended_at_new := 0
	var streak := {}            # player_id → {"kind": new/orig, "stall": n, "noprog": n, "node": id}
	var stall_max := {"new": 0, "orig": 0}
	var noprog_max := {}        # diff → {"new": n, "orig": n}
	var noprog8 := {"new": 0, "orig": 0}
	var turn_start := {}
	var turn_traded := {}
	var new_far_units := 0
	var new_far_any_units := 0
	var orig_far_sold := {}
	var human_turns := 0
	var human_still := 0
	# S12 的来源口径：每个玩家每种货一条先进先出队列，记每件货是在哪座城拿到的（不是城时记空串）。
	# 卖出新特产时只数「不是在卖出的这座城买进的」件数，原地倒腾（在搭档城买进、换一张牌再卖回）不算（DESIGN 4.4）。
	var fifo := {}
	_fifo_update(fifo, {}, content)        # 开局就有的货（起始物资）记在起点城
	var commands := 0
	var failed := ""
	var truncated := false
	var n := GameState.players.size()
	while GameState.phase != GameState.Phase.GAME_OVER and commands < MAX_COMMANDS:
		if rounds_cap > 0:
			if clock:
				var done := float(GameState.round_index) + float(GameState.current_player_index) / float(n)
				GameState.match_limit_sec = MATCH_SEC
				GameState.match_elapsed_sec = done * MATCH_SEC / float(rounds_cap)
				GameState.match_time_left_sec = maxf(0.0, MATCH_SEC - GameState.match_elapsed_sec)
			if not GameState.end_triggered and GameState.round_index >= rounds_cap - 1 and GameState.current_player_index == 0 \
					and GameState.phase == GameState.Phase.ROLL_DIE:
				truncated = GameState.trigger_time_limit()
		var p: PlayerState = GameState.current_player()
		var pid := p.player_id
		if GameState.phase == GameState.Phase.ROLL_DIE and not turn_start.has(pid):
			turn_start[pid] = p.current_node_id
			turn_traded[pid] = false
		var here_city := GameData.get_city_at_node(content, p.current_node_id)
		var card_before: Dictionary = {}
		if GameState.phase == GameState.Phase.TRADE:
			card_before = TradeSystem.get_current_trade_card()
		var inv_before := _inventories()
		var step := _execute_one()
		commands += 1
		if not bool(step.get("success", false)):
			failed = "%s @%d: %s" % [String(step.get("kind", "?")), commands, String(step.get("message", ""))]
			break
		var popped := _fifo_update(fifo, inv_before, content)
		var kind := String(step.get("kind", ""))
		if kind == "RATIO" or kind == "DIRECT_SALE":
			turn_traded[pid] = true
			trades_by_city[here_city] = int(trades_by_city.get(here_city, 0)) + 1
		if kind == "RATIO" and not card_before.is_empty():
			var give: Dictionary = card_before["entries"][int(step.get("_give", -1))] if step.has("_give") else {}
			var recv: Dictionary = card_before["entries"][int(step.get("_receive", -1))] if step.has("_receive") else {}
			if not give.is_empty() and String(give.get("resource_kind", "")) == "GOOD" and String(recv.get("resource_kind", "")) == "SILVER":
				var g := String(give["resource_id"])
				var units := int(give["quantity"]) * int(step.get("_times", 1))
				if producer.has(g):
					var src := String(producer[g])
					if newc.has(src):
						# 只数在别处拿到、运到这里卖的件数
						var carried := 0
						for from_city in (popped.get(pid, {}) as Dictionary).get(g, []):
							if String(from_city) != here_city:
								carried += 1
						carried = mini(carried, units)
						if here_city != src:
							new_far_any_units += carried
						if String(partner_city.get(src, "")) == here_city:
							new_far_units += carried
					elif dist.has(here_city) and int((dist[here_city] as Dictionary).get(src, 0)) >= 15:
						orig_far_sold[g] = true
		if kind == "END_TURN":
			var start_node := String(turn_start.get(pid, p.current_node_id))
			turn_start.erase(pid)
			var end_node := p.current_node_id
			var start_city := GameData.get_city_at_node(content, start_node) if GameData.is_city_node(content, start_node) else ""
			var same := start_node == end_node and not start_city.is_empty()
			var kind_city := "new" if newc.has(start_city) else "orig"
			if GameData.is_city_node(content, end_node) and newc.has(GameData.get_city_at_node(content, end_node)) and p.is_ai():
				ended_at_new += 1
			if not p.is_ai():
				human_turns += 1
				if start_node == end_node:
					human_still += 1
			if p.is_ai():
				if not start_city.is_empty():
					ai_turns[kind_city] += 1
				var st: Dictionary = streak.get(pid, {"stall": 0, "noprog": 0, "node": ""})
				if st["node"] != start_node:
					st = {"stall": 0, "noprog": 0, "node": start_node}
				var is_stall: bool = same and not bool(turn_traded.get(pid, false)) and p.cargo_count() > 0
				var is_noprog: bool = same
				if is_stall:
					stall[kind_city] += 1
					st["stall"] = int(st["stall"]) + 1
					stall_max[kind_city] = maxi(int(stall_max[kind_city]), int(st["stall"]))
				else:
					st["stall"] = 0
				var dkey := AIDifficulty.of(p)
				if not noprog_max.has(dkey):
					noprog_max[dkey] = {"new": 0, "orig": 0}
				if is_noprog:
					st["noprog"] = int(st["noprog"]) + 1
					noprog_max[dkey][kind_city] = maxi(int(noprog_max[dkey][kind_city]), int(st["noprog"]))
				else:
					st["noprog"] = 0
				st["node"] = end_node
				streak[pid] = st
			turn_traded[pid] = false
	for dkey in noprog_max.keys():
		for kc in ["new", "orig"]:
			if int(noprog_max[dkey][kc]) >= 8:
				noprog8[kc] = 1
	var opened_new := 0
	for cid in newc.keys():
		if not String(GameState.city_market_states.get(cid, {}).get("opened_by_player_id", "")).is_empty():
			opened_new += 1
	var winners: Array = GameState.result.get("winner_ids", [])
	var total_silver := 0
	for i in GameState.players.size():
		var pl := GameState.players[i] as PlayerState
		total_silver += pl.silver
		players_info[i]["silver"] = pl.silver
		players_info[i]["cargo"] = pl.cargo_count()
		players_info[i]["win_share"] = (1.0 / float(winners.size())) if winners.has(pl.player_id) else 0.0
	return {
		"seed": seed, "key": String(content.get("custom_map", {}).get("topology_key", key)), "seats": seats, "diffs": ",".join(diffs), "rounds_cap": rounds_cap,
		"ok": failed.is_empty() and GameState.phase == GameState.Phase.GAME_OVER and commands < MAX_COMMANDS,
		"why": failed if not failed.is_empty() else ("" if commands < MAX_COMMANDS else "MAX_COMMANDS"),
		"commands": commands, "rounds": GameState.round_index + 1, "end_reason": GameState.end_reason, "truncated": truncated,
		"players": players_info, "winner_ids": winners, "total_silver": total_silver, "hosts": hosts,
		"new_cities": newc.keys(), "trades_by_city": trades_by_city, "opened_new": opened_new,
		"ai_turns": ai_turns, "stall": stall, "stall_streak_max": stall_max, "noprog_streak_max": noprog_max,
		"noprog8": noprog8, "ai_turns_ended_at_new": ended_at_new,
		"new_good_partner_units": new_far_units, "new_good_away_units": new_far_any_units, "orig_far_sold": orig_far_sold.keys(),
		"human_turns": human_turns, "human_still": human_still, "bank_k": k, "bank_k_file": k_file,
		"generator": TradeGenV1.VERSION, "ms": Time.get_ticks_msec() - t0,
	}


## 每个玩家的持货：{player_id: {good_id: 件数}}
func _inventories() -> Dictionary:
	var out := {}
	for pv in GameState.players:
		var p := pv as PlayerState
		var inv := {}
		for g in p.inventory.keys():
			var n := p.held_count(String(g))
			if n > 0:
				inv[String(g)] = n
		out[p.player_id] = inv
	return out


## 按这一步前后的持货差更新先进先出队列：多出来的件记上玩家现在所在的城，少掉的件从队头取走。
## 返回这一步取走的件的来源：{player_id: {good_id: [来源城, …]}}。
func _fifo_update(fifo: Dictionary, before: Dictionary, content: Dictionary) -> Dictionary:
	var popped := {}
	var after := _inventories()
	for pv in GameState.players:
		var p := pv as PlayerState
		var pid := p.player_id
		var b: Dictionary = before.get(pid, {})
		var a: Dictionary = after.get(pid, {})
		var goods := {}
		for g in b.keys():
			goods[g] = true
		for g in a.keys():
			goods[g] = true
		if not fifo.has(pid):
			fifo[pid] = {}
		var here := GameData.get_city_at_node(content, p.current_node_id) if GameData.is_city_node(content, p.current_node_id) else ""
		for g in goods.keys():
			var delta := int(a.get(g, 0)) - int(b.get(g, 0))
			if delta == 0:
				continue
			var q: Array = fifo[pid].get(g, [])
			if delta > 0:
				for i in delta:
					q.append(here)
			else:
				var took: Array = []
				for i in -delta:
					took.append(q.pop_front() if not q.is_empty() else "")
				if not popped.has(pid):
					popped[pid] = {}
				popped[pid][g] = took
			fifo[pid][g] = q
	return popped


func _policy_for(p: PlayerState) -> Variant:
	return _proxy if p.is_local_human() else _ai_policy


## 与 tests/formal_full_game_stress_tests.gd:173-248 同一套规则命令；策略按座位身份选。
func _execute_one() -> Dictionary:
	var player: PlayerState = GameState.current_player()
	var pol: Variant = _policy_for(player)
	if EventSystem.has_pending_decision():
		var pending := EventSystem.get_pending_decision()
		var choice: Dictionary = pol.choose_event_decision(player, pending)
		if choice.is_empty():
			return {"success": false, "message": "empty pending choice for %s" % String(pending.get("operation", ""))}
		var resolved := EventSystem.resolve_pending_decision(choice)
		resolved["kind"] = "PENDING"
		return resolved
	match GameState.phase:
		GameState.Phase.ROLL_DIE:
			var rolled := TurnSystem.roll_die()
			var event: Dictionary = rolled.get("event", {})
			if bool(event.get("blocked", false)):
				return {"success": false, "kind": "ROLL", "message": "RULE_BLOCKED %s" % String(event.get("effect_message", ""))}
			rolled["kind"] = "ROLL"
			return rolled
		GameState.Phase.MOVE_OR_EVENT:
			if player.move_confirmed or (DiceSystem.is_event_face(player.die_result) and not player.pending_event_needs_move and player.movement_budget <= 0):
				var proceeded := TurnSystem.proceed()
				proceeded["kind"] = "PROCEED"
				return proceeded
			var decision: Dictionary = pol.choose_move(player)
			if bool(decision.get("blocked", false)):
				return {"success": false, "kind": "MOVE", "message": String(decision.get("reason", "move blocked"))}
			var chosen: Dictionary = decision.get("chosen", {})
			if chosen.is_empty():
				return {"success": false, "kind": "MOVE", "message": "empty move choice"}
			if bool(chosen.get("needs_switch", false)) and player.active_transport != int(chosen.get("transport", player.active_transport)):
				var switched := TurnSystem.switch_transport()
				switched["kind"] = "SWITCH"
				return switched
			var moved := TurnSystem.confirm_move(chosen.get("path", []))
			moved["kind"] = "MOVE"
			return moved
		GameState.Phase.TRADE:
			var trade: Dictionary = pol.choose_trade(player)
			if bool(trade.get("blocked", false)):
				return {"success": false, "kind": "TRADE", "message": String(trade.get("reason", "trade blocked"))}
			var ct: Dictionary = trade.get("chosen", {})
			match String(ct.get("kind", "skip")):
				"ratio":
					var ratio := TradeSystem.trade_ratio(int(ct.get("give_index", -1)), int(ct.get("receive_index", -1)), int(ct.get("times", 0)))
					ratio["kind"] = "RATIO"
					ratio["_give"] = int(ct.get("give_index", -1))
					ratio["_receive"] = int(ct.get("receive_index", -1))
					ratio["_times"] = int(ct.get("times", 0))
					return ratio
				"direct_sale":
					var sold := TradeSystem.trade_direct_sale(ct.get("selection", {}))
					sold["kind"] = "DIRECT_SALE"
					return sold
				_:
					var skipped := TurnSystem.skip_trade()
					skipped["kind"] = "SKIP_TRADE"
					return skipped
		GameState.Phase.END_TURN:
			var ended := TurnSystem.end_turn()
			ended["kind"] = "END_TURN"
			return ended
	return {"success": false, "message": "unsupported phase %s" % str(GameState.phase)}
