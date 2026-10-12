extends Node
## 旅人模式：一幕开在开场同一个窗口里（2026-09-27 Carlos 三问都答「要」：同一个窗口里开、不另起进程、
## 窗口是全屏 / 窗口 / 最大化，进去回来都不变）。以前开场用 OS.create_process 另起一个进程开这一幕，自己收进程序坞。
## 开场（scripts/lshu_ui/lshu_title_screen.gd）点「进入」时 enter(开场, 幕 id, 追加参数)：
##   ① 记下这一幕可能改动的全局设置（traveler_globals.gd：帧率、垂直同步、根视口画质、渲染器全局、音频总线、鼠标…）
##   ② 建这一幕的「‹ 返回」/ 提示 / 载入卡那一层（act_exit_button.gd，第 120 层），载入卡从选幕页上淡入盖满；
##      开场自己已经停了音乐、让环境声淡出（0.4 秒），这里等它淡完
##   ③ 把商旅模式那一整棵（开场、设置页、对局界面、3D 棋盘）藏起来、停掉处理和输入；里面的 SubViewport、CanvasLayer 也一并关掉，
##      回来原样打开（3D 棋盘本来就在看不见时不画）
##   ④ 根视口换一个新的 3D 世界（这一幕专用，走的时候整个丢掉），后台线程读这一幕的场景，读完实例化挂在根下
##      （和单独开时一样是根视口里的 3D 场景，画面不变）；参数经 traveler_launch.gd 给它
##   ⑤ 这一幕就绪（act_exit_button.mark_ready）后载入卡淡出
## 离开（「‹ 返回」、Esc、这一幕出错时 traveler_launch.finish）request_return()：
##   ① 载入卡盖回来 ② 给这一幕发关窗口通知（找 L叔 在这时存旅行进度，和单独开时关窗口一样）
##   ③ 停掉这一幕的处理和所有声音，等音频线程 200 毫秒收走（同 AudioManager / SoundDirector 退出时的做法，不报 ObjectDB 泄漏）
##   ④ 释放这一幕、换回原来的 3D 世界、一项项还原全局设置 ⑤ 商旅模式那棵树原样打开，开场回到选幕页（音乐、环境声回来，胜场刷新）
## 入场片（Carlos 2026-09-27：四幕各一段 15 秒入场片，进这一幕时播；片子和播放器见 art-src/motion/README.md）：
##   这一幕照常在载入卡下面读、建、就绪（边播边建主线程会卡住片子），就绪后入场片整屏盖上来（第 125 层，高于这一幕的界面 120），
##   盖满后载入卡撤掉；片尾 0.5 秒叠化进这一幕的实时画面，「‹ 返回」和底部提示再出来一次。Esc 或「跳过 ›」跳过。
##   只在从开场进时放；单独开（命令行 --lshu-act、开发脚本、截图工具）不放。测试里 intro_enabled = false 或 -- --lshu-no-intro 关掉。
## 窗口的大小、位置、全屏 / 窗口 / 最大化从头到尾不动（traveler_globals.gd 只记不还原，测试断言没变）。
## 一幕开着时关掉整个游戏：先停声音再退；这一幕的场景还在后台线程读时（长安 5–6 秒）先不退，读完再退（_notification），
## 不然引擎退出时把读到一半的场景硬停，报解析错误和「ObjectDB instances were leaked」（2026-09-27 对抗复核）。

signal returned(info: Dictionary)

const SELF_PATH := "res://scripts/traveler/traveler_host.gd"
const Launch := preload("res://scripts/traveler/traveler_launch.gd")
const Globals := preload("res://scripts/traveler/traveler_globals.gd")
const Progress := preload("res://scripts/lshu_ui/lshu_progress.gd")
const OVERLAY_PATH := "res://scripts/traveler/act_exit_button.gd"
const Intro := preload("res://scripts/traveler/act_intro_player.gd")
## 入场片淡入 0.4 秒：盖满之后再撤载入卡
const INTRO_COVER_SEC := 0.6
## false：不放入场片（测试只测进出本身时关掉）
static var intro_enabled := true
## 载入卡从选幕页上淡入的秒数
const COVER_IN_SEC := 0.25
## 开场环境声进一幕时 0.4 秒淡出（title_ambience.gd act_out_sec）：等它淡完再停开场的处理
const TITLE_AUDIO_OUT_SEC := 0.45
## 离开时载入卡盖回来的秒数、回到开场后淡出的秒数
const COVER_BACK_SEC := 0.25
const UNCOVER_SEC := 0.35
## 停掉的播放要等音频线程再混一两次才真正释放（AudioManager / SoundDirector 退出时同样等 200 毫秒）
const DRAIN_MSEC := 200

var act_id := ""
var scene_path := ""
var title: Control
## 开场所在的那一整棵（根下面的那个节点：正式包是 tools/merchant_board_claude_play.tscn，开发时是 scenes/main.tscn）
var merchant: Node
var act: Node
var overlay: CanvasLayer
var snapshot: Dictionary = {}
## 回开场时还原过的全局设置（带「report:」前缀的是只记不还原的窗口项，正常应该一项都没有）
var restored: Array[String] = []
## 各阶段耗时（毫秒，从点「进入」算）：covered / added / ready / leave
var timings: Dictionary = {}
var state := "idle"   # covering | loading | running | leaving | done

var _args := PackedStringArray()
## 正在放的入场片（act_intro_player.gd）；放完、跳过、离开时清空
var intro: Control
var _intro_wanted := false
var _t0 := 0
var _return_pending := false
var _return_code := 0
var _merchant_visible := true
var _merchant_process := Node.PROCESS_MODE_INHERIT
var _hidden_layers: Array[CanvasLayer] = []
var _paused_viewports: Array = []   # [[SubViewport, update mode]]
var _world_saved: World3D
## 后台线程正在读的这一幕场景（读完清空）；这时关窗口要等它读完再退出，见 _notification / _exit_tree
var _reading := ""
var _quit_after_read := false


## 开场点「进入」：建一个挂到根下，开始进场；已经有一幕开着、或这一幕不在包里时返回 null
static func enter(title_node: Control, id: String, extra: PackedStringArray = PackedStringArray()) -> Node:
	if Launch.hosting() or title_node == null or not title_node.is_inside_tree():
		return null
	var scene := str(Progress.act_info(id).get("scene", ""))
	if scene == "" or not ResourceLoader.exists(scene):
		push_error("旅人模式：没有这一幕或场景不在包里：%s（%s）" % [id, scene])
		return null
	# 场景在、它引用的东西不在（没有 generated/ 的检出导出的包，PAD-MAR-1）：进去只会一直卡在载入卡上（PAD-MAR-4），不进
	var missing := Progress.missing_for_act(id)
	if not missing.is_empty():
		print("TRAVELER_HOST_MISSING_DEPS ", JSON.stringify({"act": id, "scene": scene, "missing": Array(missing)}))
		return null
	var h: Node = (load(SELF_PATH) as GDScript).new()
	h.name = "TravelerHost"
	h.set("act_id", id)
	h.set("scene_path", scene)
	h.set("title", title_node)
	h.set("_args", Launch.args_for(id, extra))
	title_node.get_tree().root.add_child(h)
	return h


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_t0 = Time.get_ticks_msec()
	_enter()


# ------------------------------------------------------------------ 进场
func _enter() -> void:
	state = "covering"
	var tree := get_tree()
	snapshot = Globals.snapshot(tree)
	merchant = _top_of(title)
	overlay = (load(OVERLAY_PATH) as GDScript).new() as CanvasLayer
	overlay.name = "ActExitButton"
	overlay.set("act_id", act_id)
	overlay.set("hosted", true)
	overlay.set("cover_in", COVER_IN_SEC)
	_intro_wanted = intro_enabled and not _args.has("--lshu-no-intro") and Intro.has_intro(act_id)
	overlay.set("hold_cover", _intro_wanted)
	Launch.begin(self, _args, overlay)
	tree.root.add_child(overlay)
	overlay.connect("act_ready", _on_act_ready)
	print("LSHU_TITLE_ENTER ", JSON.stringify({"act": act_id, "hosted": true, "args": _args, "scene": scene_path,
		"window_mode": DisplayServer.window_get_mode(), "window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y]}))
	# 载入卡淡入盖满、开场环境声淡完
	await _wait(maxf(COVER_IN_SEC, TITLE_AUDIO_OUT_SEC))
	_hide_merchant()
	timings["covered"] = _ms()
	if _return_pending:
		await _leave()
		return
	# 这一幕专用的 3D 世界
	_world_saved = tree.root.world_3d
	tree.root.world_3d = World3D.new()
	state = "loading"
	var t_load := Time.get_ticks_msec()
	var packed := await _load_scene(scene_path)
	timings["scene_load"] = Time.get_ticks_msec() - t_load
	if _quit_after_read:
		# 读的时候玩家关了窗口：读完了，这就退出（不再挂这一幕）
		print("TRAVELER_HOST_QUIT_AFTER_READ ", JSON.stringify({"act": act_id, "scene_load_ms": timings.scene_load}))
		tree.quit()
		return
	if packed == null:
		push_error("旅人模式：%s 的场景读不出来（%s）" % [act_id, scene_path])
		await _leave()
		return
	if _return_pending:
		await _leave()
		return
	act = packed.instantiate()
	Launch.set_act(act)
	# 挂在这一层之后：未处理的按键这一幕先收，这一层最后收（明信片开着时 Esc 先收起它，见 act_exit_button.gd）
	tree.root.add_child(act)
	timings["added"] = _ms()
	print("TRAVELER_HOST_ACT_ADDED ", JSON.stringify({"act": act_id, "ms": timings.added, "scene_load_ms": timings.scene_load}))
	if _return_pending and state == "loading":
		await _leave()


func _on_act_ready() -> void:
	if state != "loading":
		return
	state = "running"
	timings["ready"] = _ms()
	print("LSHU_TITLE_ACT_READY ", JSON.stringify({"act": act_id, "ms": timings.ready, "timings": timings}))
	if _intro_wanted:
		_play_intro()


# ------------------------------------------------------------------ 入场片
func _play_intro() -> void:
	intro = Intro.play_over(get_tree().root, act_id)
	intro.revealing.connect(_on_intro_revealing)
	intro.finished.connect(_on_intro_finished)
	timings["intro"] = _ms()
	print("TRAVELER_HOST_INTRO ", JSON.stringify({"act": act_id, "ms": timings.intro}))
	# 连在自己身上（不用 await）：这 0.6 秒里离开、宿主释放了，这个回调跟着作废
	get_tree().create_timer(INTRO_COVER_SEC, true, false, true).timeout.connect(_release_cover.bind(0.0))


## 载入卡撤掉（只撤一次；离开时不撤）
func _release_cover(sec: float) -> void:
	if state == "running" and is_instance_valid(overlay) and bool(overlay.get("hold_cover")):
		overlay.call("release_cover", sec)


## 片子开始叠化 / 淡出：刚开始就跳过（片子还没盖满、载入卡还在）时，载入卡跟着一起淡掉
func _on_intro_revealing() -> void:
	_release_cover(0.3)


func _on_intro_finished() -> void:
	intro = null
	_release_cover(0.35)          # 片子播不了时这里才撤
	if state == "running" and is_instance_valid(overlay):
		overlay.call("replay_hint")
	timings["intro_done"] = _ms()
	print("TRAVELER_HOST_INTRO_DONE ", JSON.stringify({"act": act_id, "ms": timings.intro_done}))


## 离开时片子还在：整层拿掉（播放器会把视频、Ambience 总线收拾好）。片子那一层是这一帧末尾才挂上去的，也放到帧末再拿
func _drop_intro() -> void:
	if not is_instance_valid(intro):
		intro = null
		return
	var layer := intro.get_parent()
	intro = null
	if is_instance_valid(layer):
		layer.call_deferred("queue_free")


## 后台线程读场景（长安的地图场景要读 5–6 秒，载入卡上的小人照常走）；读不出来返回 null。
## 场景直接挂的脚本先在主线程读好：「L叔在哪儿」的两个脚本（lshu_main.gd + lshu_director.gd）一起在后台线程里编译时，
## 引擎的读取凭据（ResourceLoader 的 LoadToken）会漏掉 10 个左右，退出时报「ObjectDB instances were leaked」，而且每进一次漏一次；
## 先在主线程读脚本（不到半秒）就没有（2026-09-27 实测：只后台读 lshu_main.tscn 漏 10 个，先读脚本 0 个）。
func _load_scene(path: String) -> PackedScene:
	var scripts: Array[Resource] = []
	for dep: String in ResourceLoader.get_dependencies(path):
		var dep_path: String = dep.get_slice("::", dep.get_slice_count("::") - 1)
		if dep_path.get_extension() == "gd" and ResourceLoader.exists(dep_path):
			scripts.append(load(dep_path))
	if ResourceLoader.load_threaded_request(path, "PackedScene") != OK:
		return load(path) as PackedScene
	_reading = path
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	_reading = ""
	scripts.clear()
	return packed


# ------------------------------------------------------------------ 离开
## 这一幕要结束（「‹ 返回」、Esc、出错）：回开场。进场还没走完时记下来，走到能收尾的地方再收
func request_return(code: int = 0) -> void:
	print("TRAVELER_HOST_RETURN_REQUESTED ", JSON.stringify({"act": act_id, "code": code, "state": state}))
	_return_code = code
	match state:
		"covering":
			_return_pending = true
		"loading":
			# 场景还在读：读完就收；已经挂上了：马上收（这一幕 _ready 里还没走完的协程随它释放一起取消）
			_return_pending = true
			if act != null:
				_leave()
		"running":
			_leave()


func _leave() -> void:
	if state == "leaving" or state == "done":
		return
	state = "leaving"
	_drop_intro()
	var t_leave := Time.get_ticks_msec()
	var tree := get_tree()
	if is_instance_valid(overlay):
		overlay.call("show_cover", COVER_BACK_SEC)
		await _wait(COVER_BACK_SEC)
	# ② 关窗口通知：各幕在这时存进度（找 L叔 写旅行存档），和单独开时关窗口一样
	if is_instance_valid(act):
		act.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
		# ③ 停处理、停声音，等音频线程把停掉的播放收走
		act.process_mode = Node.PROCESS_MODE_DISABLED
		if _stop_audio(act):
			await _wait(DRAIN_MSEC / 1000.0)
		tree.root.remove_child(act)
		act.queue_free()
	act = null
	Launch.set_act(null)
	# 这一幕 _exit_tree 里交出的东西（延迟释放、换地的后台任务）走完
	await tree.process_frame
	await tree.process_frame
	# ④ 换回原来的 3D 世界，还原全局设置
	if _world_saved != null:
		# 换回时手里先攥着这一幕的世界：它要是在 set_world_3d 里就被释放，引擎随后从已释放的场景里摘视口，会报
		# 「Parameter "scenario" is null」（scenario_remove_viewport_visibility_mask）
		var act_world: World3D = tree.root.world_3d
		tree.root.world_3d = _world_saved
		_world_saved = null
		await tree.process_frame
		act_world = null
	Launch.end()
	restored = Globals.restore(tree, snapshot)
	# ⑤ 商旅模式那棵树原样打开，开场回到选幕页
	_show_merchant()
	timings["leave"] = Time.get_ticks_msec() - t_leave
	var info := {"act": act_id, "code": _return_code, "restored": restored, "timings": timings,
		"window_mode": DisplayServer.window_get_mode(), "window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y]}
	print("LSHU_TITLE_ACT_RETURNED ", JSON.stringify(info))
	if is_instance_valid(title) and title.has_method("_on_act_returned"):
		title.call("_on_act_returned", info)
	returned.emit(info)
	if is_instance_valid(overlay):
		overlay.call("uncover", UNCOVER_SEC)
		await _wait(UNCOVER_SEC)
		overlay.get_parent().remove_child(overlay)
		overlay.queue_free()
	overlay = null
	state = "done"
	queue_free()


## 停掉 node 下面所有播放器、清空 stream；返回有没有还在放的（要等音频线程收走）
static func _stop_audio(node: Node) -> bool:
	var busy := false
	for cls: String in ["AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]:
		for p: Node in node.find_children("*", cls, true, false):
			busy = busy or bool(p.call("has_stream_playback"))
			p.call("stop")
			p.set("stream", null)
	return busy


# ------------------------------------------------------------------ 商旅模式那一棵
func _top_of(n: Node) -> Node:
	var root := get_tree().root
	while n != null and n.get_parent() != root:
		n = n.get_parent()
	return n


func _hide_merchant() -> void:
	if merchant == null or not is_instance_valid(merchant):
		return
	_hidden_layers.clear()
	_paused_viewports.clear()
	for l: Node in merchant.find_children("*", "CanvasLayer", true, false):
		if (l as CanvasLayer).visible:
			(l as CanvasLayer).visible = false
			_hidden_layers.append(l as CanvasLayer)
	for v: Node in merchant.find_children("*", "SubViewport", true, false):
		var sv := v as SubViewport
		if sv.render_target_update_mode != SubViewport.UPDATE_DISABLED:
			_paused_viewports.append([sv, sv.render_target_update_mode])
			sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if merchant is CanvasItem:
		_merchant_visible = (merchant as CanvasItem).visible
		(merchant as CanvasItem).visible = false
	_merchant_process = merchant.process_mode
	merchant.process_mode = Node.PROCESS_MODE_DISABLED
	print("TRAVELER_HOST_MERCHANT_HIDDEN ", JSON.stringify({"root": str(merchant.name), "layers": _hidden_layers.size(), "viewports": _paused_viewports.size()}))


func _show_merchant() -> void:
	if merchant == null or not is_instance_valid(merchant):
		return
	merchant.process_mode = _merchant_process
	if merchant is CanvasItem:
		(merchant as CanvasItem).visible = _merchant_visible
	for l: CanvasLayer in _hidden_layers:
		if is_instance_valid(l):
			l.visible = true
	for pair: Array in _paused_viewports:
		if is_instance_valid(pair[0]):
			(pair[0] as SubViewport).render_target_update_mode = int(pair[1]) as SubViewport.UpdateMode
	_hidden_layers.clear()
	_paused_viewports.clear()


# ------------------------------------------------------------------ 关窗口（一幕开着时玩家直接关掉整个游戏）
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	if _reading != "":
		# 这一幕的场景还在后台线程读（长安要 5–6 秒）：引擎退出时会把读到一半的场景硬停，报一串解析错误和
		# 「ObjectDB instances were leaked」。先不接受这次退出，载入卡照常走着，读完再退（_enter 里）
		if not _quit_after_read:
			_quit_after_read = true
			get_tree().auto_accept_quit = false
			print("TRAVELER_HOST_QUIT_DEFERRED ", JSON.stringify({"act": act_id, "state": state, "reading": _reading}))
		return
	if is_instance_valid(act) and state != "leaving":
		# 这一幕自己的关窗口处理（存进度）随后照常收到；这里先把声音停了，给音频线程 200 毫秒，退出时不报泄漏
		if _stop_audio(act):
			OS.delay_msec(DRAIN_MSEC)


## 别的路径退出（不经关窗口）时场景还在读：在这里等它读完、收走（阻塞，最多几秒），同上不让引擎硬停
func _exit_tree() -> void:
	if _reading != "":
		ResourceLoader.load_threaded_get(_reading)
		_reading = ""


## 这一幕里的声音走哪条总线（测试用；正式入口的 -- --lshu-audio-probe 由 act_exit_button.gd 每秒打一行）
func audio_state() -> Dictionary:
	var d: Dictionary = Globals.audio_state(act)
	d["act"] = act_id
	var bgm: Variant = title.get("bgm") if is_instance_valid(title) else null
	d["title_bgm_playing"] = bgm is AudioStreamPlayer and (bgm as AudioStreamPlayer).playing
	return d


func _ms() -> int:
	return Time.get_ticks_msec() - _t0


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true, false, true).timeout
