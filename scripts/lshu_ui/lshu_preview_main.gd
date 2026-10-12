extends "res://scripts/main.gd"
## 「旅行L叔」主流程：和 scripts/main.gd 完全一样，只在开局前插一页加载页「商队整装中…」
## （scripts/lshu_ui/lshu_loading_screen.gd）：设置页点「出发！」和结算页点「再来一局」都走它。原 main.gd 不动。
## 2026-09-26 起正式入口 scenes/main.tscn 也用这个脚本 + L叔 设置页（2–4 座位、真人 / 电脑任意组合）；
## scenes/lshu_ui/lshu_preview_main.tscn 与它相同，留给 tools/open_lshu_setup_preview.command。
## 「再来一局」原样把上一局的座位配置（GameScreen 记下的 configs）交回 prepare_new_game，所以还是同一桌人。
##
## 为什么需要它：开局时 GameScreen.on_game_started 会一口气卡住主线程约 5 秒（读 33 张大图约 1 秒，
## 棋盘逐像素扫描 16 座城的图约 3.6 秒），原流程这 5 秒里画面冻在一张没画完的旧棋盘上。
## 这里的做法（实测见 docs/design/shanhe-luren/loading-lshu-20260926/README.md）：
##   ① 清点货物银两…  准备 / 定局（0.1 毫秒，和原版一样在出加载页之前做，失败就回设置页报错）
##   ② 准备城市图画…  33 张大图在后台线程读（约 0.3 秒，进度条按真正读完的张数走），读完先攥在手里
##   ③ 铺开地图…      对局界面先在加载页下面显示一帧（必须显示着开局，隐藏时开局镜头会偏 188 像素），
##                     然后 on_game_started：这一步仍会卡住约 4 秒，卡之前骆驼先走到位、L叔 先说「地图有点大，稍等一下哦」
##                     这台电脑第一次画 3D 棋盘时这一帧要停 30 秒到一两分钟（编译着色器，见 BOARD_FIRST_FRAME_FILE），
##                     L叔 改说「第一次出发要先画好 3D 地图……别关掉哦」
##   ④ 叫醒电脑小伙伴… 让对局界面在下面先画两帧（第一帧约 0.1 秒的卡顿藏在这里）
##   出发！            走满、小旗弹一下、淡出，下面已经是画好的棋盘
## 加载页放在第 110 层画布上（对局界面自己的弹层到 100），盖住时挡鼠标、吞键盘（不然空格会在下面掷骰）。

const LOADING_SCENE := preload("res://scenes/lshu_ui/lshu_loading_screen.tscn")
const Loading := preload("res://scripts/lshu_ui/lshu_loading_screen.gd")
const PRESENTATION := preload("res://scripts/ui/formal_world_map_presentation.gd")
const MatchSave := preload("res://scripts/lshu_ui/lshu_match_save.gd")
## 前两步至少停这么久，小朋友看得清骆驼在走
const MIN_PRELOAD_SEC := 0.5
const MIN_WAKE_SEC := 0.2
const PRELOAD_TIMEOUT_MSEC := 8000
## 对局界面有几块（顶栏、卷轴、城市标记）画在自己的图层上，弹层最高到 100（事件、结算、交接）
const LOADING_LAYER := 110
## 这台电脑第一次把 3D 棋盘画出来时，Metal 要现场编译 SDFGI 那一组着色器（31 个材质，M1 Ultra 冷启动 28 秒，
## 慢的 MacBook 更久），这一帧里整个画面停住——2026-09-26 Carlos 在另一台 MacBook 上看到的「进度条卡在 54%」就是它。
## 编好的结果存在系统的 Metal 缓存里，以后同一步只要 1 秒多。引擎没法把这步挪到后台（试过开机时、标题页后面、
## 用看不见东西的相机提前触发，都会在触发的那一帧同步等完），所以第一次如实告诉玩家要等，画好后记一笔。
const BOARD_FIRST_FRAME_FILE := "user://board_first_frame.cfg"

## 自制地图（docs/design/map-editor-20260930/DESIGN.md 3.7、3.8、R4）：加载页第 ③ 步前按这局的地图铺开 3D 世界
## （棋盘的 prepare_map_world / peek_city 由 WP3 提供，没合入时跳过）；「再来一局」带着地图准备失败就退回原版再准备一次；
## 读档失败把孩子话交给标题页（show_notice 由 WP5 提供，没合入时只打警告）
const MAP_PEEK_SEC := 1.5
## 最近一次读档失败时交给标题页的那句话（测试读）
var last_continue_notice := ""

var _loading: Loading
var _loading_busy := false
var _preloaded: Array[Resource] = []
var _pending_paths: Array[String] = []
## 自检用（-- --lshu-smoke --lshu-smoke-shot=<png>）：画棋盘第一帧之前把加载页存一张图
var _smoke_shot := ""


func _ready() -> void:
	var layer := CanvasLayer.new()
	layer.name = "LoadingLayer"
	layer.layer = LOADING_LAYER
	add_child(layer)
	_loading = LOADING_SCENE.instantiate() as Loading
	_loading.name = "LoadingScreen"
	_loading.visible = false
	layer.add_child(_loading)
	super()
	# 手柄：加载页盖着、换页的淡入淡出时手柄键一律不算（scripts/pad/pad_input.gd 的 pad_blocker）
	_loading.add_to_group("pad_blocker")
	_transition_overlay.add_to_group("pad_blocker")
	# 开场「加载存档」：接着上一局（2026-09-27）
	if %StartScreen.has_signal("continue_requested"):
		%StartScreen.connect("continue_requested", _on_continue_requested)
	# 2–4 座位时可能连着几个电脑：每个电脑回合结束后再叫一次对局界面的「该电脑走了吗」（它自己判断当前是不是电脑、
	# 是不是已经在跑，重复调用无害）。对局界面自己也接了这一步时，这里只是多一道保险。
	var ai: Object = %GameScreen.get("_ai")
	if ai != null and ai.has_signal("turn_finished") and %GameScreen.has_method("_maybe_start_ai"):
		ai.connect("turn_finished", func() -> void: %GameScreen.call_deferred("_maybe_start_ai"))
	# 安装包自检（2026-09-26：另一台 Mac 上进对局卡在 54%）：-- --lshu-smoke 走一遍「开场 → 开局页 → 出发」再退出
	if "--lshu-smoke" in OS.get_cmdline_user_args():
		call_deferred("_smoke_start")


func _smoke_start() -> void:
	var title_wait := 1.5
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--lshu-smoke-title-wait="):
			title_wait = float(a.trim_prefix("--lshu-smoke-title-wait="))
		elif a.begins_with("--lshu-smoke-shot="):
			_smoke_shot = a.trim_prefix("--lshu-smoke-shot=")
	var t0 := Time.get_ticks_msec()
	var last := t0
	var worst := 0
	var next_log := t0 + 2000
	while float(Time.get_ticks_msec() - t0) / 1000.0 < title_wait:
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		worst = maxi(worst, now - last)
		last = now
		if now >= next_log:
			_log_pipelines("title (longest frame %d ms)" % worst, t0)
			worst = 0
			next_log = now + 2000
	print("LSHU SMOKE: new game")
	await _on_new_game_requested()
	await get_tree().create_timer(0.8).timeout
	print("LSHU SMOKE: start (出发)")
	await _on_transport_confirmed(GameData.Transport.CAMEL)
	print("LSHU SMOKE: loading finished, match on screen")
	await get_tree().create_timer(6.0).timeout
	print("LSHU SMOKE: ok")
	get_tree().quit()


## 渲染管线编译计数（Godot 4.4+）：第一次画 3D 棋盘时 surface 从 60 涨到 95，就是那一帧停住的原因
func _log_pipelines(what: String, since: int) -> void:
	print("LSHU PIPELINES %s +%d ms canvas=%d mesh=%d surface=%d draw=%d spec=%d" % [what, Time.get_ticks_msec() - since,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION)])


## 这一局的棋盘是不是 3D 棋盘（正式入口 scenes/main.tscn 的平面棋盘没有第一次编译着色器的问题）
func _board_is_3d() -> bool:
	var board: Node = %GameScreen.get_node_or_null("%BoardView")
	return board != null and board.has_method("set_rendering_enabled")


## 这一份安装在这台电脑上画过 3D 棋盘没有。Metal 的编译缓存跟着装好的这一份程序走（同一台 Mac 换一个新版本，
## 实测又要重新编一遍），所以记录里带上程序的路径和修改时间，装了新版本就当第一次。
func _board_drawn_before() -> bool:
	var cf := ConfigFile.new()
	return cf.load(BOARD_FIRST_FRAME_FILE) == OK and str(cf.get_value("board", "install", "")) == _install_key()


func _install_key() -> String:
	var exe := OS.get_executable_path()
	return "%s@%d" % [exe, FileAccess.get_modified_time(exe)]


func _record_board_first_frame(msec: int) -> void:
	var cf := ConfigFile.new()
	cf.load(BOARD_FIRST_FRAME_FILE)
	if str(cf.get_value("board", "install", "")) != _install_key():
		cf.set_value("board", "install", _install_key())
		cf.set_value("board", "first_msec", msec)
	cf.set_value("board", "last_msec", msec)
	cf.set_value("board", "engine", Engine.get_version_info().string)
	cf.save(BOARD_FIRST_FRAME_FILE)


## 加载各阶段写一行日志（带毫秒）：安装包里出问题时，~/Library/Application Support/Godot/app_userdata/旅行L叔/logs/godot.log 能看出卡在哪一步
func _log_stage(what: String, since: int) -> void:
	print("LSHU LOADING %s +%d ms" % [what, Time.get_ticks_msec() - since])


func _exit_tree() -> void:
	# 还没收回的后台读图请求要收回，不然退出时会报对象泄漏
	_drain_pending()


func _show_only(screen: Control) -> void:
	super(screen)
	if _loading != null:
		_loading.visible = screen == _loading


## 设置页点「出发！」
func _on_transport_confirmed(human_transport: int) -> void:
	if _loading_busy:
		return
	# ① 清点货物银两：和原版一样，失败就留在设置页报错
	var result := SetupSystem.finalize_new_game(human_transport)
	if not result["success"]:
		%PlayerSetupScreen.show_start_error(String(result["message"]))
		push_error("SetupSystem finalize: %s" % result["message"])
		return
	await _run_loading(%PlayerSetupScreen.get_last_configs(), %PlayerSetupScreen.get_prepare_result())


## 结算页点「再来一局」：准备和定局和原版一样（失败回设置页报错），开局也走加载页
func _on_restart_requested(player_configs: Array) -> void:
	if _loading_busy:
		return
	%GameScreen.cancel_ai()
	var restarting_mode := GameState.session_mode
	if restarting_mode != "FORMAL" and restarting_mode != "DEMO_1V1":
		restarting_mode = "FORMAL"
	# 「再来一局」沿用上一局的扩展包（「L叔的趣味事件」开关），和同一桌座位一样；自制地图也一样（缓存钉住了这份，一定命中）
	var expansions := ExpansionLoader.options_of(GameState.content)
	GameState.reset_session()
	var content := GameData.load_ruleset(
		GameData.FORMAL_RULESET_DIR if restarting_mode == "FORMAL" else GameData.DEMO_RULESET_DIR
	)
	# 万一带着地图准备失败（R4）：去掉地图选项再准备一次，用原版开局，不退回设置页
	var prepared := CustomMapSettings.prepare_or_fallback(content, player_configs, -1, restarting_mode, expansions)
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
	await _run_loading(player_configs, prepared)


## 开场点「加载存档」：把存档装回 GameState（lshu_match_save.gd），走同一个加载页，开局后把计时接回来
func _on_continue_requested() -> void:
	if _loading_busy:
		return
	var restored: Dictionary = MatchSave.restore(MatchSave.read())
	if not bool(restored.get("success", false)):
		push_warning("存档接不上：%s" % String(restored.get("message", "")))
		# 孩子点了「加载存档」没反应会以为坏了：让 L叔 在标题页把原因说出来（show_notice 归 WP5）
		last_continue_notice = String(restored.get("message", ""))
		if %StartScreen.has_method("show_notice"):
			%StartScreen.call("show_notice", last_continue_notice)
		if %StartScreen.has_method("_refresh_load_button"):
			%StartScreen.call("_refresh_load_button")
		return
	await _run_loading(restored.configs, {"home_city_name": restored.home_city_name}, restored.clock)


## 加载页流程：② 读图 → ③ 铺开地图（开局）→ ④ 叫醒电脑小伙伴 → 出发
## resume_clock：读档时上一回的计时（elapsed / limit_sec / unlimited），开局后接回去
func _run_loading(configs: Array, prepare: Dictionary, resume_clock: Dictionary = {}) -> void:
	_loading_busy = true
	# 「再来一局」时新局已经准备好、对局界面还显示着；上一局的计时要等 on_game_started 清零，
	# 在那之前别让对局界面跑（上一局满 20 分钟结束的话，淡入那几帧里新局就会被判时间到，复检 2026-09-26）。
	# game_screen.gd 自己也按局号挡着（_started_session），这里是第二道。
	%GameScreen.set_process(false)
	var t_all := Time.get_ticks_msec()
	_loading.begin(configs, prepare)
	await _transition_to(_loading)
	var t0 := Time.get_ticks_msec()
	_log_stage("① shown", t_all)

	# ② 准备城市图画：后台线程读图，进度按读完的张数走
	var paths: Array[String] = _board_texture_paths()
	_loading.set_stage("准备城市图画…", 0.14)
	for p in paths:
		if ResourceLoader.load_threaded_request(p, "", true) == OK:
			_pending_paths.append(p)
	var total: int = maxi(1, paths.size())
	while not _pending_paths.is_empty():
		for p in _pending_paths.duplicate():
			var st: int = ResourceLoader.load_threaded_get_status(p)
			if st == ResourceLoader.THREAD_LOAD_LOADED:
				var res: Resource = ResourceLoader.load_threaded_get(p)
				if res != null:
					_preloaded.append(res)
				_pending_paths.erase(p)
			elif st == ResourceLoader.THREAD_LOAD_FAILED or st == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				ResourceLoader.load_threaded_get(p)  # 收回请求；读不到的图开局时棋盘会自己再读
				_pending_paths.erase(p)
		_loading.set_stage("准备城市图画…", 0.14 + 0.4 * float(total - _pending_paths.size()) / float(total))
		if Time.get_ticks_msec() - t0 > PRELOAD_TIMEOUT_MSEC:
			_drain_pending()
			break
		await get_tree().process_frame
	await _hold_since(t0, MIN_PRELOAD_SEC)
	_log_stage("② textures %d preloaded, %d pending" % [_preloaded.size(), _pending_paths.size()], t_all)

	# ③ 之前：这局用了自制地图、3D 世界还不是这张图时，先把世界铺成这张图（签名相同时立即返回）
	# （从自制地图换回原版时也要把世界重建回原样，那时不说「你的地图」）
	var board: Node = %GameScreen.get_node_or_null("%BoardView")
	if board != null and board.has_method("prepare_map_world"):
		var want_sig := CustomMapLoader.layout_sig(GameState.content)
		var have_sig: Variant = board.get("_map_sig")
		var rebuild := have_sig is String and String(have_sig) != want_sig
		if rebuild and want_sig != "":
			_loading.set_stage("铺开你的地图…", 0.6)
			_loading.say("这局用的是你的地图\n「%s」！" % String((GameState.content.get("custom_map", {}) as Dictionary).get("name", "")))
			await _loading.wait_caught_up(0.4)
			await get_tree().process_frame
		await board.call("prepare_map_world")
		if rebuild:
			_log_stage("③ map world rebuilt", t_all)
	# ③ 铺开地图：卡之前把骆驼走到位、先打招呼；对局界面在加载页下面显示一帧，再开局
	var first_3d := _board_is_3d() and not _board_drawn_before()
	if first_3d:
		_loading.set_stage("第一次画 3D 地图…", 0.62)
		_loading.say("第一次出发要先画好 3D 地图，\n大约等 1～2 分钟，画面会停住，\n别关掉哦！以后就快啦～")
		await _loading.wait_caught_up(1.2)
		# 泡泡弹出的动画走完再停，停住的那一帧就是这句话
		await get_tree().create_timer(0.5).timeout
		await get_tree().process_frame
	else:
		_loading.set_stage("铺开地图…", 0.62)
		_loading.say("地图有点大，\n稍等一下哦～")
		await _loading.wait_caught_up(0.4)
	_log_stage("③ bar caught up%s" % (" (first 3D board on this computer)" if first_3d else ""), t_all)
	_log_pipelines("before first frame", t_all)
	if _smoke_shot != "":
		get_viewport().get_texture().get_image().save_png(_smoke_shot)
	%StartScreen.visible = false
	%PlayerSetupScreen.visible = false
	%GameScreen.visible = true
	var t_frame := Time.get_ticks_msec()
	await get_tree().process_frame
	_log_stage("③ first frame with the board drawn", t_all)
	if _board_is_3d():
		_record_board_first_frame(Time.get_ticks_msec() - t_frame)
	_log_pipelines("after first frame", t_all)
	%GameScreen.on_game_started(configs, resume_clock)
	_log_stage("③ on_game_started returned", t_all)
	%GameScreen.set_process(true)
	_preloaded.clear()

	# ④ 叫醒电脑小伙伴：让对局界面在下面先画两帧
	t0 = Time.get_ticks_msec()
	_loading.say("")
	_loading.set_stage("叫醒电脑小伙伴…", 0.9)
	await get_tree().process_frame
	await get_tree().process_frame
	await _hold_since(t0, MIN_WAKE_SEC)
	_log_stage("④ two frames drawn", t_all)

	# 出发！
	_loading.finish()
	await _loading.finished
	_loading.visible = false
	_loading_busy = false
	# 孩子自己加的新城不当起点、又在地图边上，开局镜头往往看不到：真人的回合先让镜头滑过去看一眼再回来（3.7）
	_peek_user_city(board)


## 加载页淡出后：有孩子自己加的新城、且当前是真人的回合时，镜头滑到那座城停一会儿再滑回来（电脑先手时不做）
func _peek_user_city(board: Node) -> void:
	if board == null or not board.has_method("peek_city") or not GameState.content.has("custom_map"):
		return
	if GameState.players.is_empty() or not GameState.current_player().is_local_human():
		return
	for c in (GameState.content["custom_map"] as Dictionary).get("new_cities", []):
		if String((c as Dictionary).get("origin", "")) == "USER":
			board.call("peek_city", String(c["id"]), MAP_PEEK_SEC)
			return


## 开局时棋盘要读的大图：地图底图 + 16 座城的静态图和悬停动画图（和 BoardView 读的是同一批路径）
func _board_texture_paths() -> Array[String]:
	var out: Array[String] = []
	var pres: Dictionary = PRESENTATION.build(GameState.content)
	var bg: String = String(pres.get("map_background", ""))
	if bg != "" and ResourceLoader.exists(bg):
		out.append(bg)
	var visuals: Dictionary = pres.get("cities_visual", {})
	for id in visuals:
		var v: Dictionary = visuals[id]
		for key: String in ["static_texture", "animation_texture"]:
			var p: String = String(v.get(key, ""))
			if p != "" and not out.has(p) and ResourceLoader.exists(p):
				out.append(p)
	return out


## 收回所有还在读的后台请求（会等它们读完，最多几百毫秒）
func _drain_pending() -> void:
	for p in _pending_paths:
		ResourceLoader.load_threaded_get(p)
	_pending_paths.clear()


func _hold_since(t0: int, min_sec: float) -> void:
	var left: float = min_sec - float(Time.get_ticks_msec() - t0) / 1000.0
	if left > 0.0:
		await get_tree().create_timer(left).timeout
