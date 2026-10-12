extends Control
## 《山河旅人》商旅模式 on Claude's 3D merchant board: the formal game exactly as scenes/main.tscn
## runs it — title (StartScreen) → one-page setup (PlayerSetupScreen) → a complete 1v1 match
## (GameScreen: formal rules, AI, dice, trade, events, HUD, restart / back to title) — with the
## GameScreen's %BoardView presented by tools/merchant_board_claude_play_board.gd (its script is
## swapped before the scene enters the tree; no formal file is edited). Players are L叔 on a camel /
## in a boat in their colour.
## Args (debug): -- [--quick] straight into a match (red human vs blue AI)
##          [--showcase] 4 AI players (all four colours) playing on their own
##          [--difficulty=qingzhuang|shanhai|wanli] AI level for --quick / --showcase
##          [--seed=N] fixed game seed          [--ai-delay=S] AI step delay (default 0.35 s)
##          [--zoom=Z] close-up following the current player   [--press-start] title → setup → 启程
##          [--press-roll] [--pick-far] [--hover=<city>]   [--shot=<abs png>,<t1>,<t2>...]
##          [--day-speed=N] 一天的光照按 N 倍速走（例：60 = 20 秒走完一天）   [--daytime=S] 固定在对局第 S 秒的光
##          [--fun-events | --fun-events=quiz] --quick / --showcase 开局时打开「L叔的趣味事件」（=quiz 连耳听八方）
##          [--custom-map=<abs json>] --quick / --showcase 开局时用这张自制地图（读文件 → 校验登记 → 带地图选项开局 → 铺开地图）
##          [--setup-seed=N] --press-start 时出发页用固定种子（「标题 → 设置页 → 出发」这条路也能复现）
##          [--catalogue-allow-draft] 从源码运行时目录也收 draft 条目（灰盒素材；导出包里无效）

## 棋盘脚本和正式主场景在 _ready 里、旅人模式路由之后才读（以前是 preload）：单独开一幕（-- --lshu-act=<id>）时不用先把整个商旅模式读进来
const BOARD_PATH := "res://tools/merchant_board_claude_play_board.gd"
const MAIN_PATH := "res://scenes/main.tscn"

var _main: Control
var _screen: Control
var _seed := -1
var _ai_delay := 0.35


func _ready() -> void:
	if _route_to_act():
		return
	_fit_window()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var args := OS.get_cmdline_user_args()
	var difficulty := AIDifficulty.DEFAULT
	for a in args:
		if a.begins_with("--difficulty="):
			difficulty = AIDifficulty.normalize(a.trim_prefix("--difficulty="))
		if a.begins_with("--seed="):
			_seed = int(a.trim_prefix("--seed="))
		elif a.begins_with("--ai-delay="):
			_ai_delay = float(a.trim_prefix("--ai-delay="))
	_main = (load(MAIN_PATH) as PackedScene).instantiate()
	_screen = _main.get_node("%GameScreen")
	(_screen.get_node("%BoardView") as Control).set_script(load(BOARD_PATH))
	add_child(_main)
	_main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var ai = _screen.get("_ai")
	if ai != null:
		ai.set("step_delay", _ai_delay)
		# the formal screen is 1v1 (human, AI): it never has two AI turns in a row, so it only
		# restarts the AI from state_changed while the old turn is still running. With more AIs
		# (--showcase) kick the next one once a turn has finished.
		ai.turn_finished.connect(func(): _screen.call_deferred("_maybe_start_ai"))
	var dbg := false
	for a in args:
		dbg = dbg or a.begins_with("--zoom=") or a.begins_with("--shot=") or a == "--showcase" or a == "--debug-keys"
	(_screen.get_node("%BoardView")).set("debug_keys", dbg)
	for a in args:
		if a.begins_with("--day-speed="):
			(_screen.get_node("%BoardView")).set("day_speed", maxf(0.0, float(a.trim_prefix("--day-speed="))))
		elif a.begins_with("--daytime="):
			(_screen.get_node("%BoardView")).set("day_time_override", maxf(0.0, float(a.trim_prefix("--daytime="))))
	for a in args:
		if a.begins_with("--zoom="):
			# debug close-up (beyond the player's 0.8-1.5 range) for checking the pieces' motion
			var b = _screen.get_node("%BoardView")
			b.set("_zoom", float(a.trim_prefix("--zoom=")))
			b.set("zoom_debug_lock", true)
	if "--open-setup" in args:
		# debug: straight to the setup page (开始新游戏 on the title)
		get_tree().create_timer(1.0).timeout.connect(func(): _main.call("_on_new_game_requested"))
	if "--press-start" in args:
		# debug: 开始新游戏 on the title, then 启程 on the setup page (the default flow end to end)
		var setup_seed := -1
		for a in args:
			if a.begins_with("--setup-seed="):
				setup_seed = int(a.trim_prefix("--setup-seed="))
		if setup_seed < 0:
			get_tree().create_timer(1.5).timeout.connect(func(): _main.call("_on_new_game_requested"))
		else:
			# 与 main.gd:_on_new_game_requested 同样两步（begin_setup → _transition_to），只把随机种子换成固定的
			get_tree().create_timer(1.5).timeout.connect(func():
				var setup: Node = _main.get_node("%PlayerSetupScreen")
				var r: Dictionary = setup.call("begin_setup", setup_seed, "FORMAL")
				if not bool(r.get("success", false)):
					push_error("SetupSystem prepare: %s" % String(r.get("message", "")))
				_main.call("_transition_to", setup))
		get_tree().create_timer(3.0).timeout.connect(func():
			(_main.get_node("%PlayerSetupScreen").get_node("%StartButton") as Button).pressed.emit())
	for a in args:
		if a.begins_with("--hover="):
			# debug: point at a city (its gold glow + market card), for captures
			var hc := a.trim_prefix("--hover=")
			get_tree().create_timer(5.0).timeout.connect(func():
				var b = _screen.get_node("%BoardView")
				b._goal = b._focus_point(b._node_anchor(hc))
				b._target = b._goal
				b._apply_camera()
				await get_tree().process_frame
				var e := InputEventMouseMotion.new()
				e.position = (b._city_building_screen_rect(hc) as Rect2).get_center()
				b._gui_input(e))
	if "--overview" in args:
		# debug: zoom all the way out (the whole board)
		get_tree().create_timer(4.0).timeout.connect(func():
			var b = _screen.get_node("%BoardView")
			b._zoom_at(Vector2(b.size.x - b._right_inset, b.size.y) * 0.5, b.MIN_ZOOM, false))
	if "--press-roll" in args:
		# debug: roll for the human after the board settles (to capture the move markers)
		get_tree().create_timer(4.0).timeout.connect(func():
			if GameState.current_player().is_local_human():
				_screen.call("_on_primary_action_pressed"))
	if "--pick-far" in args:
		# debug: then pick the farthest marked node, exactly as a click on it does (since 2026-09-27
		# 先选再确认 a click only selects: route, step badge and 「出发（N 步）」, and nothing moves)
		get_tree().create_timer(6.0).timeout.connect(func():
			var b = _screen.get_node("%BoardView")
			if b.legal_nodes.is_empty():
				return
			var best := ""
			for id in b.legal_nodes:
				if best == "" or int(b.legal_nodes[id]) > int(b.legal_nodes[best]):
					best = id
			_screen.call("_on_board_node_clicked", String(best)))
	for a in args:
		if a.begins_with("--shot="):
			# debug: --shot=<abs png>[,<seconds>[,<more seconds>...]] saves screenshots, then quits
			call_deferred("_shots", a.trim_prefix("--shot="))
	if "--showcase" in args:
		_start([
			{"display_name": "红商旅", "color_id": "red", "controller_type": "AI", "ai_difficulty": difficulty},
			{"display_name": "蓝商旅", "color_id": "blue", "controller_type": "AI", "ai_difficulty": difficulty},
			{"display_name": "绿商旅", "color_id": "green", "controller_type": "AI", "ai_difficulty": difficulty},
			{"display_name": "黄商旅", "color_id": "yellow", "controller_type": "AI", "ai_difficulty": difficulty}], _seed)
	elif "--quick" in args:
		_start([{"display_name": "玩家", "color_id": "red", "controller_type": "LOCAL_HUMAN"},
			{"display_name": "电脑商旅", "color_id": "blue", "controller_type": "AI", "ai_difficulty": difficulty}], _seed)
	# no args: scenes/main.tscn shows its title screen, exactly like the formal game


## 单独开旅人模式的一幕：只带用户参数 -- --lshu-act=<幕 id> ...（正式包的导出模板不许命令行指定场景、也不认 --script，
## 夜测 TL-1 / TRV-1），在这里、搭棋盘之前直接换到那一幕的场景。窗口大小位置用命令行的 --position / --resolution，不调 _fit_window。
## 2026-09-27 起开场里「进入」不走这里了（同一个窗口里开，scripts/traveler/traveler_host.gd）；这条路留给
## tools/traveler/release_act_smoke.sh 逐幕冒烟、tools/open_baghdad_traveler.command 等单独开一幕的时候。
## 开场的静音键（只静音乐和环境声）记在玩家的设置里：这里是正式入口，按玩家的设置来（各幕的声音都走环境声总线）。
func _route_to_act() -> bool:
	var prefix := "--lshu-act="
	var id := ""
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			id = a.trim_prefix(prefix)
	if id == "":
		return false
	var scene := str(preload("res://scripts/lshu_ui/lshu_progress.gd").act_info(id).get("scene", ""))
	if scene == "" or not ResourceLoader.exists(scene):
		push_error("旅人模式：没有这一幕或场景不在包里：%s（%s）" % [id, scene])
		get_tree().quit.call_deferred(2)
		return true
	var muted: bool = preload("res://scripts/audio/audio_buses.gd").load_music_muted(get_tree())
	print("LSHU_ACT_ROUTE ", JSON.stringify({"act": id, "scene": scene, "music_muted": muted}))
	get_tree().change_scene_to_file.call_deferred(scene)
	return true


## 1920×1080 放得下就居中放；屏幕的可用区域比它小（MacBook 1440×900、带程序坞 / 菜单栏的 1080p 屏）就铺满可用区域。
## 以前只改大小不改位置，1080p 屏上窗口右边 320 像素跑到屏幕外，进度卡、L叔 的泡泡被切掉（复检 TL-8）
func _fit_window() -> void:
	var win := get_window()
	var want := Vector2i(1920, 1080)
	if DisplayServer.get_name() == "headless":
		win.size = want
		return
	var usable := DisplayServer.screen_get_usable_rect(win.current_screen)
	if usable.size.x >= want.x and usable.size.y >= want.y:
		win.size = want
		win.position = usable.position + (usable.size - want) / 2
	else:
		win.size = usable.size
		win.position = usable.position
		win.mode = Window.MODE_MAXIMIZED


## straight into a match (debug), the way main.gd's restart does it
func _start(configs: Array, seed: int) -> void:
	GameState.reset_session()
	# --fun-events[=quiz]：调试开局打开「L叔的趣味事件」扩展包（=quiz 连子开关「耳听八方」一起开）
	var expansions := {}
	for a in OS.get_cmdline_user_args():
		if a == "--fun-events" or a == "--fun-events=quiz":
			expansions = ExpansionLoader.fun_events_options(true, a.ends_with("=quiz"))
	# --custom-map=<绝对路径>：读文件 → 整份校验、登记 → 带上地图选项开局（docs/design/map-editor-20260930/DESIGN.md 3.6）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--custom-map="):
			var map_opt := _custom_map_option(a.trim_prefix("--custom-map="))
			for k in map_opt.keys():
				expansions[k] = map_opt[k]
	var r := SetupSystem.prepare_new_game(GameData.load_ruleset(GameData.FORMAL_RULESET_DIR), configs, seed, "FORMAL", expansions)
	if bool(r.get("success", false)):
		r = SetupSystem.finalize_new_game()
	if not bool(r.get("success", false)):
		push_error("开局失败：%s" % str(r.get("message", "")))
		return
	_main.call("_show_only", _screen)
	# 自制地图要先把 3D 世界铺成这张图（签名相同时立即返回；棋盘的 prepare_map_world 由 WP3 提供，没合入时跳过）
	var board: Node = _screen.get_node("%BoardView")
	if board.has_method("prepare_map_world"):
		await board.call("prepare_map_world")
	_screen.on_game_started(configs)


## 开发参数 --custom-map：读一张地图文件并登记，返回开局选项里地图那一项（坏图返回 {}，照旧用原版开局）
func _custom_map_option(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("自制地图文件不存在：%s" % path)
		return {}
	var parsed := CustomMapValidator.parse_text(FileAccess.get_file_as_string(path))
	var doc: Dictionary = parsed["doc"]
	if not (parsed["errors"] as Array).is_empty():
		print("CUSTOM_MAP_REJECTED code=E_PARSE path=%s" % path)
		return {}
	var r := CustomMapLoader.remember(doc)
	if not bool(r.get("ok", false)):
		print("CUSTOM_MAP_REJECTED code=%s path=%s errors=%s" % [str(r.get("code", "")), path, str(r.get("errors", []))])
		return {}
	print("CUSTOM_MAP_LOADED name=%s sha=%s" % [str(r.get("name", "")), str(r.get("sha256", "")).left(12)])
	return CustomMapLoader.option_for(str(r["sha256"]))


func _shots(spec: String) -> void:
	var parts := spec.split(",")
	var base := parts[0].trim_suffix(".png")
	var times: Array = []
	for i in range(1, parts.size()):
		times.append(float(parts[i]))
	if times.is_empty():
		times = [8.0]
	var t0 := Time.get_ticks_msec() / 1000.0
	var k := 0
	for t in times:
		while Time.get_ticks_msec() / 1000.0 - t0 < float(t):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s_%02d.png" % [base, k])
		var b = _screen.get_node("%BoardView") if is_instance_valid(_screen) else null
		print("SHOT %d t=%.1f debug=%s" % [k, float(t), str(b.get_map_debug_state()) if b != null and _screen.visible else ""])
		k += 1
	get_tree().quit()
