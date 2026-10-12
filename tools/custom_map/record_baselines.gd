extends Node
## 自制地图 WP0：改任何已有文件之前录「原版不变」的基线（docs/design/map-editor-20260930/DESIGN.md 4.1 P-0）。
## 夹具都写进 tests/fixtures/custom_map/，每一项的提交号、命令、SHA-256 记在同目录的 baselines_manifest.json。
## 写进夹具目录之前先核：工作区里已有的文件与 999e46bf 相比一个都没改（git diff --diff-filter=MDRT 为空），否则拒绝录。
## 改代码之后要重导出来比对（P-6、P-8），用 --out=<scratch 目录>：照常导出，manifest 里记下当时改过哪些文件。
##
## 用法（worktree 根目录；HOME 一律指到 scratch，不碰 Carlos 真实的 ShanheLvren/）：
##   无窗口四项：
##     godot --headless --path . res://tools/custom_map/record_baselines.tscn -- --record=pins,paths,save_keys,fun_on
##       pins      → frozen_pins.json       R1 冻结文件的 SHA-256（P-0e，T-FROZEN 用）
##       paths     → paths_export_base.txt  原布局 Paths.build 之后的导出（P-0b，P-6 用 paths_export_text 重导后逐字节比）
##       save_keys → save_keys_base.json    没地图时 snapshot() 的键集合和 schema（P-0d，P-8 用）
##       fun_on    → fun_on_baseline.json   趣味事件开 100 局整局指纹（P-0a，tests/custom_map_fun_on_parity_tests.gd）
##   出发页截图（要窗口）：
##     godot --path . --audio-driver Dummy res://tools/custom_map/record_baselines.tscn -- --setup-shot=<abs png> [--paths-live=<abs txt>]
##       切到正式 3D 入口 merchant_board_claude_play.tscn（当前场景必须是它：入口门按场景路径判断），
##       用固定种子 SETUP_SEED 调出发页的 begin_setup，淡入之后等 SETUP_SETTLE_SEC 截一张 1920×1080。
##   棋盘截图：直接跑 DESIGN P-0c 那条命令（必须带 --quick，见 BOARD_SHOT_ARGS），它自己存 <base>_00.png、<base>_01.png。
##   收截图、标定抖动（把第一张当基线拷进夹具，其余几张与它比差异，写进 manifest 的 shots）：
##     godot --headless --path . res://tools/custom_map/record_baselines.tscn -- --adopt-shot=<名字>|<基线 png>|<另一次 png>|...[|holdout:<png>] [--command=<命令>]
##   比两张图（P-7 / P-7s 用同一套函数）：整张图 --compare=<a png>|<b png>；只比遮罩之外 --compare-masked=<a>|<b>|<遮罩 png>
##     godot --headless --path . res://tools/custom_map/record_baselines.tscn -- --compare=<a png>|<b png>
## 其它工作包复用：build_base_paths() + paths_export_text(paths)、image_diff(a, b)、unstable_mask / masked_diff、region_stats(img, rect)、
## save_keys_doc()。

const Paths := preload("res://tools/merchant_board_claude_paths.gd")
const Token := preload("res://tools/merchant_board_claude_token.gd")
const MatchSave := preload("res://scripts/lshu_ui/lshu_match_save.gd")
const FUN_ON_TEST := "res://tests/custom_map_fun_on_parity_tests.gd"
const PIN_TEST := "res://tests/custom_map_frozen_pin_tests.gd"

const FIXTURE_DIR := "res://tests/fixtures/custom_map"
const MANIFEST := "baselines_manifest.json"
const MANIFEST_SCHEMA := "lshu.custom_map_baselines_manifest.v1"
const BASE_COMMIT := "999e46bf"
const LAYOUT := "res://assets/merchant_board_claude/board_layout.json"
const PLAY_SCENE := "res://tools/merchant_board_claude_play.tscn"

## P-0e：R1 的冻结目录与点名文件（另钉原版实体账本）
const PIN_DIRS: Array[String] = ["res://data/rulesets/lshu_configurable_v1"]
const PIN_FILES: Array[String] = [
	"res://assets/merchant_board_claude/board_layout.json",
	"res://assets/merchant_board_claude/plaque_layout.json",
	"res://assets/merchant_board_claude/cities/building_bounds.json",
	"res://docs/research/YF064-original-physical-assets-ledger.md",
]

## P-0d：两种没地图的开局（原版、趣味事件开），同一个种子、同一桌座位
const SAVE_SEED := 2026093001
const SAVE_CLOCK := {"elapsed": 0.0, "limit_sec": 1200.0, "unlimited": false}

## P-0c：DESIGN 写死的棋盘截图参数（--shot 由调用方补上）
const BOARD_SHOT_ARGS := "--quick --seed=2026093001 --daytime=300 --day-speed=0"
## P-0f：出发页用的固定种子；正式入口平时用随机种子（main.gd:20），不固定的话右栏「启程情报」每次都不同
const SETUP_SEED := 2026093001
const SETUP_TITLE_WAIT_SEC := 1.5
const SETUP_SETTLE_SEC := 4.0

## 截图差异的上限（DESIGN P-7：容差取两次截图之间的差异，但不超过 0.1% 的像素、单像素 2/255）
const SHOT_CAP_FRAC := 0.001
const SHOT_CAP_CHANNEL := 2

var _failed := false


func _ready() -> void:
	call_deferred("_main")


func _main() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir := ProjectSettings.globalize_path(FIXTURE_DIR)
	var command := ""
	for a in args:
		if a.begins_with("--out="):
			out_dir = a.trim_prefix("--out=")
		elif a.begins_with("--command="):
			command = a.trim_prefix("--command=")
	for a in args:
		if a.begins_with("--setup-shot="):
			await _setup_shot(a.trim_prefix("--setup-shot="))
			return
	for a in args:
		if a.begins_with("--record="):
			_record(a.trim_prefix("--record=").split(","), out_dir)
		elif a.begins_with("--adopt-shot="):
			_adopt_shot(a.trim_prefix("--adopt-shot=").split("|"), out_dir, command)
		elif a.begins_with("--compare-masked="):
			var trio := a.trim_prefix("--compare-masked=").split("|")
			if trio.size() != 3:
				_fail("--compare-masked 需要 <a>|<b>|<遮罩 png>")
				continue
			print("RECORD_BASELINES_COMPARE_MASKED ", JSON.stringify(masked_diff(_load_png(trio[0]), _load_png(trio[1]), _load_png(trio[2]))))
		elif a.begins_with("--compare="):
			var pair := a.trim_prefix("--compare=").split("|")
			if pair.size() != 2:
				_fail("--compare 需要两张图：<a>|<b>")
				continue
			var d := image_diff(_load_png(pair[0]), _load_png(pair[1]))
			print("RECORD_BASELINES_COMPARE ", JSON.stringify(d))
	print("RECORD_BASELINES %s" % ("FAILED" if _failed else "ok"))
	get_tree().quit(1 if _failed else 0)


# ---------------------------------------------------------------- 无窗口四项

func _record(items: PackedStringArray, out_dir: String) -> void:
	if not _fixture_writable(out_dir):
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	for item in items:
		var t0 := Time.get_ticks_msec()
		match item.strip_edges():
			"pins":
				_write_json(out_dir.path_join("frozen_pins.json"), frozen_pins_doc())
				_note(out_dir, "frozen_pins", "frozen_pins.json", "--record=pins")
			"paths":
				var p := build_base_paths()
				_write_text(out_dir.path_join("paths_export_base.txt"), paths_export_text(p))
				_note(out_dir, "paths_export", "paths_export_base.txt", "--record=paths")
			"save_keys":
				_write_json(out_dir.path_join("save_keys_base.json"), save_keys_doc())
				_note(out_dir, "save_keys", "save_keys_base.json", "--record=save_keys")
			"fun_on":
				var script = load(FUN_ON_TEST)
				var test: Node = script.new()
				var content := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
				# 先核：空选项打出的指纹 = 原版 75 局基线里的同一局（同一个指纹函数）
				test.call("_check_same_function_as_off_parity", content)
				var same_fn := int(test.get("_failed")) == 0
				var doc: Dictionary = test.call("run_all", content, int(script.DEFAULT_SEEDS), {})
				test.call("_free_helpers")
				test.free()
				if not same_fn:
					_fail("指纹函数与 fun_events_off_parity_tests 对不上，不录 fun_on")
					continue
				doc["recorded_at_commit"] = git_head()
				_write_json(out_dir.path_join("fun_on_baseline.json"), doc)
				_note(out_dir, "fun_on", "fun_on_baseline.json", "--record=fun_on",
					{"games": (doc["games"] as Dictionary).size()})
			_:
				_fail("不认识的项目：%s" % item)
				continue
		print("RECORDED %s in %.1fs" % [item, float(Time.get_ticks_msec() - t0) / 1000.0])


## 往夹具目录写之前：已有文件必须一个都没改；写到别的目录（改代码之后重导出来比对）不拦
func _fixture_writable(out_dir: String) -> bool:
	var changed := existing_file_changes()
	if not changed.is_empty() and out_dir.simplify_path() == ProjectSettings.globalize_path(FIXTURE_DIR).simplify_path():
		_fail("已有文件与 %s 相比已经改过，不能往夹具里录基线：%s" % [BASE_COMMIT, ", ".join(changed)])
		return false
	return true


## P-0e：R1 冻结文件的 SHA-256
static func frozen_pins_doc() -> Dictionary:
	var files := {}
	for dir_path in PIN_DIRS:
		for path: String in load(PIN_TEST).list_files(dir_path):
			files[path] = FileAccess.get_sha256(path)
	for path in PIN_FILES:
		files[path] = FileAccess.get_sha256(path)
	return {
		"schema": "lshu.custom_map_frozen_pins.v1",
		"note": "DESIGN R1：自制地图只是叠加层，这些文件一个字节都不改（T-FROZEN）",
		"recorded_at_commit": git_head(),
		"code_equivalent_to": BASE_COMMIT,
		"dirs": PIN_DIRS,
		"files": files,
	}


## 原布局上建一份 Paths，和棋盘 _ready 一样用玩家船身（Token.boat_size 长、0.55 倍宽），play_board.gd:119-122
static func build_base_paths() -> Object:
	var lay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	var probe: Node3D = Token.new()
	var hull := float(probe.get("boat_size"))
	probe.free()
	var p: Object = Paths.new()
	p.call("build", lay, hull, hull * 0.55)
	return p


## P-0b / P-6：Paths.build 之后的 gates、stop_pos、routes[*].a,b,s0,s1（外加停靠点弧长、点列摘要）、edge_route，
## 以及每座城每条路的 4 个 slot_offsets（外加每个停靠点的 4 个）。键一律排序，数一律 %.6f，逐字节可比。
static func paths_export_text(p: Object) -> String:
	var lines := PackedStringArray()
	lines.append("# paths_export v1: Paths.build(board_layout.json) hull %s x %s" % [_f(float(p.get("boat_len"))), _f(float(p.get("boat_beam")))])
	var routes: Dictionary = p.get("routes")
	var rids := routes.keys()
	rids.sort()
	for rid in rids:
		var R: Dictionary = routes[rid]
		var pts: PackedVector3Array = R["pts"]
		var pts_text := PackedStringArray()
		for q in pts:
			pts_text.append(_v3(q))
		var cum: PackedFloat32Array = R["cum"]
		var stop_s: Dictionary = R["stop_s"]
		var sids := stop_s.keys()
		sids.sort()
		var ss := PackedStringArray()
		for sid in sids:
			ss.append("%s=%s" % [sid, _f(float(stop_s[sid]))])
		lines.append("route %s type=%s a=%s b=%s s0=%s s1=%s len=%s pts=%d pts_sha256=%s stop_s=%s" % [
			rid, R["type"], R["a"], R["b"], _f(float(R["s0"])), _f(float(R["s1"])), _f(float(cum[cum.size() - 1])),
			pts.size(), ";".join(pts_text).sha256_text(), ",".join(ss)])
	var stop_pos: Dictionary = p.get("stop_pos")
	var stops := stop_pos.keys()
	stops.sort()
	for sid in stops:
		lines.append("stop %s %s" % [sid, _v3(stop_pos[sid])])
	var gates: Dictionary = p.get("gates")
	var cids := gates.keys()
	cids.sort()
	for cid in cids:
		var g: Dictionary = gates[cid]
		var grids := g.keys()
		grids.sort()
		for rid in grids:
			lines.append("gate %s %s %s" % [cid, rid, _v3(g[rid])])
	var edge_route: Dictionary = p.get("edge_route")
	var ekeys := edge_route.keys()
	ekeys.sort()
	for k in ekeys:
		lines.append("edge %s %s" % [k, edge_route[k]])
	for cid in cids:
		var grids: Array = (gates[cid] as Dictionary).keys()
		grids.sort()
		for rid in grids:
			var medium := String(routes[rid]["type"])
			lines.append("slots city %s %s %s %s" % [cid, rid, medium, _slots_text(p.call("slot_offsets", cid, rid, medium, 4))])
	for sid in stops:
		var rid := String(p.call("route_of_stop", sid))
		var medium := String(routes[rid]["type"]) if routes.has(rid) else "LAND"
		lines.append("slots stop %s %s %s %s" % [sid, rid, medium, _slots_text(p.call("slot_offsets", sid, rid, medium, 4))])
	return "\n".join(lines) + "\n"


static func _slots_text(offs: Array) -> String:
	var parts := PackedStringArray()
	for o: Dictionary in offs:
		parts.append("[%s s=%s]" % [_v3(o["off"]), _f(float(o["scale"]))])
	return " ".join(parts)


## P-0d：没地图时 snapshot() 的键集合、键顺序、每个值的类型、schema；外加去掉 saved_at 之后整份存档的 SHA-256（只作参考）
static func save_keys_doc() -> Dictionary:
	var base := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var configs := _ha_configs()
	var variants := {}
	for v: Array in [["formal_HA", {}], ["formal_HA_fun_events", ExpansionLoader.fun_events_options(true, false)]]:
		GameState.reset_session()
		var prepared := SetupSystem.prepare_new_game(base, configs, SAVE_SEED, "FORMAL", v[1])
		var finalized := SetupSystem.finalize_new_game() if bool(prepared.get("success", false)) else prepared
		if not bool(finalized.get("success", false)):
			push_error("save_keys：开局失败 %s" % str(finalized.get("message", "")))
			continue
		var snap: Dictionary = MatchSave.snapshot(configs, SAVE_CLOCK)
		var state: Dictionary = snap["state"]
		var players: Array = snap["players"]
		var player_types := {}
		for k in (players[0] as Dictionary).keys():
			player_types[k] = type_string(typeof(players[0][k]))
		var state_types := {}
		for k in state.keys():
			state_types[k] = type_string(typeof(state[k]))
		# 状态里「字典套字典」的字段（牌堆、市场、事件牌堆）：条目 id 和条目里的键（没地图时贸易牌堆条目里没有 rng_state，R2）
		var nested := {}
		for k in _sorted_keys(state):
			if not state[k] is Dictionary or (state[k] as Dictionary).is_empty():
				continue
			var inner_keys := {}
			var all_dicts := true
			for e in (state[k] as Dictionary).values():
				if e is Dictionary:
					for ik in (e as Dictionary).keys():
						inner_keys[ik] = true
				else:
					all_dicts = false
			if all_dicts:
				nested[k] = {"entry_ids": _sorted_keys(state[k]), "entry_keys": _sorted_keys(inner_keys)}
		var no_time := snap.duplicate(true)
		no_time.erase("saved_at")
		variants[v[0]] = {
			"schema": String(snap["schema"]),
			"top_keys": _sorted_keys(snap),
			"top_key_order": snap.keys(),
			"state_keys": _sorted_keys(state),
			"state_key_order": state.keys(),
			"state_types": state_types,
			"player_keys": _sorted_keys(players[0]),
			"player_key_order": (players[0] as Dictionary).keys(),
			"player_types": player_types,
			"player_count": players.size(),
			"state_nested": nested,
			"snapshot_sha256_without_saved_at": var_to_str(no_time).sha256_text(),
		}
	GameState.reset_session()
	return {
		"schema": "lshu.custom_map_save_keys_base.v1",
		"note": "没地图时 lshu_match_save.snapshot() 的键集合和 schema（DESIGN P-0d / P-8）；种子 %d，座位 HA" % SAVE_SEED,
		"recorded_at_commit": git_head(),
		"code_equivalent_to": BASE_COMMIT,
		"save_schema": MatchSave.SCHEMA,
		"state_fields": MatchSave.STATE_FIELDS,
		"player_fields": MatchSave.PLAYER_FIELDS,
		"variants": variants,
	}


static func _ha_configs() -> Array:
	return [
		{"display_name": "座位1", "color_id": "red", "controller_type": "LOCAL_HUMAN"},
		{"display_name": "座位2", "color_id": "blue", "controller_type": "AI", "ai_difficulty": "qingzhuang"},
	]


static func _sorted_keys(d: Dictionary) -> Array:
	var k := d.keys()
	k.sort()
	return k


# ---------------------------------------------------------------- 截图

## P-0f：正式 3D 入口的出发页。把当前场景让出来（current_scene = null，本节点留在 root 下接着跑），
## 换成 merchant_board_claude_play.tscn；标题页停 SETUP_TITLE_WAIT_SEC 后，照 main.gd:_on_new_game_requested
## 的两步走（begin_setup → _transition_to），只把随机种子换成 SETUP_SEED。
func _setup_shot(png: String) -> void:
	var tree := get_tree()
	tree.current_scene = null
	tree.change_scene_to_file(PLAY_SCENE)
	while tree.current_scene == null or tree.current_scene.scene_file_path != PLAY_SCENE:
		await tree.process_frame
	var play := tree.current_scene
	await tree.create_timer(SETUP_TITLE_WAIT_SEC).timeout
	var main: Node = play.get("_main")
	var setup: Node = main.get_node("%PlayerSetupScreen")
	var r: Dictionary = setup.call("begin_setup", SETUP_SEED, "FORMAL")
	if not bool(r.get("success", false)):
		_fail("出发页准备失败：%s" % str(r.get("message", "")))
	main.call("_transition_to", setup)
	await tree.create_timer(SETUP_SETTLE_SEC).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(png.get_base_dir())
	var err := img.save_png(png)
	if err != OK:
		_fail("存图失败 %s：%s" % [png, error_string(err)])
	print("SETUP_SHOT %s size=%s seed=%d rng_seed=%d home=%s" % [png, str(img.get_size()), SETUP_SEED, GameState.rng_seed,
		str(SetupSystem.prepared_payload().get("home_city_id", ""))])
	# 顺带把棋盘自己 _ready 里建的那份 Paths 导出来（--paths-live=<文件>），用来核无窗口导出与游戏里的一致
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--paths-live="):
			var board: Node = (play.get("_screen") as Node).get_node("%BoardView")
			_write_text(a.trim_prefix("--paths-live="), paths_export_text(board.get("paths")))
	print("RECORD_BASELINES %s" % ("FAILED" if _failed else "ok"))
	tree.quit(1 if _failed else 0)


## 收一组截图：第一张拷进夹具当基线（<名字>.png）；其余几张是标定用的另几次截图，与基线比出差异，并合成「会动的像素」遮罩
## （<名字>_unstable_mask.png）；带 holdout: 前缀的几张不参与合成遮罩，只拿来验证「只比遮罩之外」这条比法站不站得住（结果记在 holdout_runs）。
func _adopt_shot(parts: PackedStringArray, out_dir: String, command: String) -> void:
	if parts.size() < 3:
		_fail("--adopt-shot 需要 <名字>|<基线 png>|<另一次 png>[|...][|holdout:<png>]")
		return
	if not _fixture_writable(out_dir):
		return
	var name := parts[0]
	var ref := _load_png(parts[1])
	if ref == null:
		_fail("读不到 %s" % parts[1])
		return
	var dst := out_dir.path_join(name + ".png")
	DirAccess.make_dir_recursive_absolute(out_dir)
	if DirAccess.copy_absolute(parts[1], dst) != OK:
		_fail("拷不进夹具 %s" % dst)
		return
	var cal: Array = []
	var holdouts: Array = []
	for i in range(2, parts.size()):
		if parts[i].begins_with("holdout:"):
			holdouts.append(parts[i].trim_prefix("holdout:"))
		else:
			cal.append(parts[i])
	var runs: Array = []
	var cal_imgs: Array = []
	var worst_frac := 0.0
	var worst_channel := 0
	for path in cal:
		var img := _load_png(path)
		cal_imgs.append(img)
		var d := image_diff(ref, img)
		d["file"] = String(path).get_file()
		runs.append(d)
		worst_frac = maxf(worst_frac, float(d.get("diff_frac", 1.0)))
		worst_channel = maxi(worst_channel, int(d.get("max_channel_diff", 255)))
	var mask := unstable_mask(ref, cal_imgs)
	var mask_name := name + "_unstable_mask.png"
	mask.save_png(out_dir.path_join(mask_name))
	var held: Array = []
	for path in holdouts:
		var img := _load_png(path)
		held.append({"file": String(path).get_file(), "full": image_diff(ref, img), "outside_mask": masked_diff(ref, img, mask)})
	var w := ref.get_width()
	var h := ref.get_height()
	var extra := {
		"size": [w, h],
		"centre_region": region_stats(ref, Rect2i(int(w * 0.2), int(h * 0.2), int(w * 0.4), int(h * 0.6))),
		"calibration_runs": runs,
		"observed_max_diff_frac": worst_frac,
		"observed_max_channel_diff": worst_channel,
		"cap": {"diff_frac": SHOT_CAP_FRAC, "channel": SHOT_CAP_CHANNEL},
		"jitter_within_cap": worst_frac <= SHOT_CAP_FRAC and worst_channel <= SHOT_CAP_CHANNEL,
		"unstable_mask": {"file": mask_name, "sha256": FileAccess.get_sha256(out_dir.path_join(mask_name)),
			"threshold": SHOT_CAP_CHANNEL, "grow_px": 3, "masked_frac": 1.0 - float(masked_diff(ref, ref, mask).get("stable_frac", 0.0))},
		"holdout_runs": held,
	}
	_note(out_dir, name, name + ".png", command, extra, "shots")
	print("ADOPTED %s %s" % [name, JSON.stringify(extra)])


## 两张图逐像素比（RGBA8，按通道取最大差）：{same_size, pixels, diff_pixels, diff_frac, over_cap_pixels, max_channel_diff}
static func image_diff(a: Image, b: Image) -> Dictionary:
	if a == null or b == null:
		return {"same_size": false, "error": "missing image"}
	if a.get_size() != b.get_size():
		return {"same_size": false, "a": [a.get_width(), a.get_height()], "b": [b.get_width(), b.get_height()]}
	var ca := a.duplicate() as Image
	var cb := b.duplicate() as Image
	ca.convert(Image.FORMAT_RGBA8)
	cb.convert(Image.FORMAT_RGBA8)
	var da := ca.get_data()
	var db := cb.get_data()
	var n := ca.get_width() * ca.get_height()
	var out := {"same_size": true, "pixels": n, "diff_pixels": 0, "diff_frac": 0.0, "over_cap_pixels": 0, "max_channel_diff": 0}
	if da == db:
		return out
	var diff := 0
	var over := 0
	var worst := 0
	for i in n:
		var o := i * 4
		var d := maxi(maxi(absi(da[o] - db[o]), absi(da[o + 1] - db[o + 1])), maxi(absi(da[o + 2] - db[o + 2]), absi(da[o + 3] - db[o + 3])))
		if d > 0:
			diff += 1
			if d > SHOT_CAP_CHANNEL:
				over += 1
			worst = maxi(worst, d)
	out["diff_pixels"] = diff
	out["diff_frac"] = float(diff) / float(n)
	out["over_cap_pixels"] = over
	out["max_channel_diff"] = worst
	return out


## 「会动的像素」遮罩：基线图与另外几次截图之间任何通道差 > threshold 的像素，再向外膨胀 grow 像素。
## 画面里本来就在动的东西（水面、云、烟、驼队、船、L叔 的待机动作、倒计时）靠它排除，剩下的像素才严格比。
static func unstable_mask(ref: Image, others: Array, threshold := SHOT_CAP_CHANNEL, grow := 3) -> Image:
	var w := ref.get_width()
	var h := ref.get_height()
	var r := ref.duplicate() as Image
	r.convert(Image.FORMAT_RGBA8)
	var dr := r.get_data()
	var hit := PackedByteArray()
	hit.resize(w * h)
	for other in others:
		var o := (other as Image).duplicate() as Image
		if o.get_size() != ref.get_size():
			continue
		o.convert(Image.FORMAT_RGBA8)
		var d := o.get_data()
		for i in w * h:
			if hit[i] != 0:
				continue
			var k := i * 4
			if maxi(maxi(absi(dr[k] - d[k]), absi(dr[k + 1] - d[k + 1])), maxi(absi(dr[k + 2] - d[k + 2]), absi(dr[k + 3] - d[k + 3]))) > threshold:
				hit[i] = 255
	# 膨胀：先横后竖，各 grow 像素
	for _pass in 2:
		var src := hit.duplicate()
		for y in h:
			for x in w:
				var i := y * w + x
				if src[i] == 0:
					continue
				for t in range(-grow, grow + 1):
					var xx := x + t if _pass == 0 else x
					var yy := y if _pass == 0 else y + t
					if xx >= 0 and xx < w and yy >= 0 and yy < h:
						hit[yy * w + xx] = 255
	return Image.create_from_data(w, h, false, Image.FORMAT_L8, hit)


## 只比遮罩之外（稳定）的像素：{stable_pixels, stable_frac, diff_pixels, diff_frac, over_cap_pixels, over_cap_frac, max_channel_diff}
## （over_cap = 通道差 > 2/255 的像素；diff_frac、over_cap_frac 都按稳定像素数算）
static func masked_diff(a: Image, b: Image, mask: Image) -> Dictionary:
	if a == null or b == null or mask == null or a.get_size() != b.get_size() or a.get_size() != mask.get_size():
		return {"error": "size mismatch or missing image"}
	var ca := a.duplicate() as Image
	var cb := b.duplicate() as Image
	ca.convert(Image.FORMAT_RGBA8)
	cb.convert(Image.FORMAT_RGBA8)
	var m := mask.duplicate() as Image
	m.convert(Image.FORMAT_L8)
	var da := ca.get_data()
	var db := cb.get_data()
	var dm := m.get_data()
	var n := ca.get_width() * ca.get_height()
	var stable := 0
	var diff := 0
	var over := 0
	var worst := 0
	for i in n:
		if dm[i] != 0:
			continue
		stable += 1
		var o := i * 4
		var d := maxi(maxi(absi(da[o] - db[o]), absi(da[o + 1] - db[o + 1])), maxi(absi(da[o + 2] - db[o + 2]), absi(da[o + 3] - db[o + 3])))
		if d > 0:
			diff += 1
			if d > SHOT_CAP_CHANNEL:
				over += 1
			worst = maxi(worst, d)
	return {"stable_pixels": stable, "stable_frac": float(stable) / float(n), "diff_pixels": diff,
		"diff_frac": float(diff) / maxf(1.0, float(stable)), "over_cap_pixels": over,
		"over_cap_frac": float(over) / maxf(1.0, float(stable)), "max_channel_diff": worst}


## 一块区域的亮度均值和标准差（每 4 个像素取 1 个）；标准差接近 0 说明是纯色（又截到了标题页 / 空画面）
static func region_stats(img: Image, rect: Rect2i) -> Dictionary:
	var sum := 0.0
	var sum2 := 0.0
	var n := 0
	for y in range(rect.position.y, rect.end.y, 4):
		for x in range(rect.position.x, rect.end.x, 4):
			var l := img.get_pixel(x, y).get_luminance()
			sum += l
			sum2 += l * l
			n += 1
	var mean := sum / maxf(1.0, float(n))
	return {"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y], "luma_mean": mean,
		"luma_std": sqrt(maxf(0.0, sum2 / maxf(1.0, float(n)) - mean * mean))}


static func _load_png(path: String) -> Image:
	var p := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	var img := Image.load_from_file(p)
	return img if img != null and not img.is_empty() else null


# ---------------------------------------------------------------- manifest、git、小工具

## 已有（被 git 跟踪的）文件相对 999e46bf 的改动：改、删、改名、改类型。只加新文件不算。
static func existing_file_changes() -> PackedStringArray:
	var out: Array = []
	var code := OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "diff", "--name-only", "--diff-filter=MDRT", BASE_COMMIT], out, true)
	if code != 0:
		return PackedStringArray(["<git diff 失败>"])
	var changed := PackedStringArray()
	for line in String(out[0]).split("\n", false):
		changed.append(line.strip_edges())
	return changed


static func git_head() -> String:
	var out: Array = []
	var code := OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "rev-parse", "HEAD"], out)
	return String(out[0]).strip_edges() if code == 0 and not out.is_empty() else ""


func _note(out_dir: String, key: String, file: String, command: String, extra: Dictionary = {}, section := "items") -> void:
	var path := out_dir.path_join(MANIFEST)
	var m: Dictionary = {}
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			m = parsed
	m["schema"] = MANIFEST_SCHEMA
	m["note"] = "自制地图 WP0 的「原版不变」基线（DESIGN 4.1 P-0）。录制工具 tools/custom_map/record_baselines.gd；每项都在改任何已有文件之前录，代码与 %s 相同" % BASE_COMMIT
	m["board_shot_command"] = "godot --path <worktree> --audio-driver Dummy res://tools/merchant_board_claude_play.tscn -- %s --shot=<abs base>,6,12" % BOARD_SHOT_ARGS
	m["setup_shot_command"] = "godot --path <worktree> --audio-driver Dummy res://tools/custom_map/record_baselines.tscn -- --setup-shot=<abs png>"
	if not m.has(section) or not m[section] is Dictionary:
		m[section] = {}
	var entry := {
		"file": file,
		"sha256": FileAccess.get_sha256(out_dir.path_join(file)),
		"recorded_at_commit": git_head(),
		"code_equivalent_to": BASE_COMMIT,
		"existing_file_changes_vs_base": Array(existing_file_changes()),
		"recorded_at": Time.get_datetime_string_from_system(false, true),
		"godot": String(Engine.get_version_info().get("string", "")),
		"command": command,
	}
	entry.merge(extra, true)
	m[section][key] = entry
	_write_json(path, m)


func _write_json(path: String, doc: Dictionary) -> void:
	_write_text(path, JSON.stringify(doc, "  ", true) + "\n")


func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("写不了 %s" % path)
		return
	f.store_string(text)
	f.close()


func _fail(msg: String) -> void:
	_failed = true
	push_error("RECORD_BASELINES: " + msg)
	print("RECORD_BASELINES FAIL: " + msg)


static func _f(x: float) -> String:
	return "%.6f" % x


static func _v3(v: Vector3) -> String:
	return "%s %s %s" % [_f(v.x), _f(v.y), _f(v.z)]
