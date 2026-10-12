extends Control
## 旅人模式入场片播放器（2026-09-27，入场片见 art-src/motion/<幕>/README.md，接入说明见 art-src/motion/README.md）。
## 进一幕时整屏播 assets/traveler/intro/<幕 id>_intro.ogv（15.0 秒，Theora 画面 + Vorbis 声音在同一个文件里），
## 片子盖在这一幕上面播；片尾 0.5 秒和这一幕的开场画面一样，播完叠化进去。
##
## 用法（完整说明见 art-src/motion/README.md）：先在载入卡后面把这一幕建好、等它就绪，再开片，片子盖在这一幕上面播
## （边播边建会让片子跟着主线程停住 2–12 秒，实测见 README）：
##   const Intro := preload("res://scripts/traveler/act_intro_player.gd")
##   if Intro.has_intro(id):
##       var intro: Control = Intro.play_over(get_tree().root, id)   # 自己建一层 CanvasLayer（125，高于这一幕的界面层 120）
##       await intro.finished
##   还没就绪就开片时：intro.act_ready = false，再给 intro.ready_probe = func() -> bool: return overlay.is_act_ready()
##   （或者就绪时调 intro.mark_act_ready()），片尾会停在最后一帧等。
##
## 行为：
##   · 画面按 16:9 放进窗口，窗口比例不同时上下或左右留黑边；开头 0.4 秒淡入（声音一起），盖在原来的画面上
##     （画面底下不垫整屏黑底，所以淡入淡出是真正的叠化，中段不会发暗）。
##   · 声音走 Music 总线（开场的静音键静的就是 Music + Ambience，所以片子一起静）。片子自带这一幕的环境声，
##     所以播放时把 Ambience 总线压到听不见（开头跟着淡入压下去），片尾 0.5 秒等功率交叉还回去；duck_ambience = false 关掉。
##   · 交接：播到 length − 0.5 秒时这一幕已就绪 → 0.5 秒叠化进实时画面；还没就绪 → 停在最后一帧（它就是这一幕的开场画面），
##     等就绪了再 0.5 秒叠化，不退回载入卡。声音的交叉总按片子时间走，不等就绪。
##   · 跳过：Esc；或者「跳过 ›」小药丸（左上是这一幕的「‹ 返回」，这个在右上）。药丸只在动鼠标 / 点屏幕之后出来，
##     出来后 0.6 秒才能点，而且点它之前 0.6 秒内不能有点在别处的点击——小孩乱点一通不会跳过（夜测规则：不许一下误触就做不可逆的事）。
##     跳过 = 0.35 秒淡出，露出下面的东西（就绪了是这一幕，没就绪是这一幕的载入卡）。
##   · 播放期间吞掉全部按键（Esc 不会让这一幕「返回」开场）和鼠标（背景挡住点击，这一幕底下的城门 / 篝火点不到）。
##   · 结束（播完、跳过、文件坏了）都先发 revealing 再发 finished，各一次；finished 之后不再挡任何输入，
##     视频播放器和流当场释放；auto_free（默认开）时自己连同 play_over 建的那一层一起 queue_free。
##   · 文件不在或坏了：play() 返回 false，同一帧末尾（call_deferred）发 revealing + finished，界面从头到尾不出现。
##     Godot 4.7.1 碰到截断的 .ogv 会在 VideoStreamTheora.set_file 里死循环、整个游戏卡死（2026-09-27 实测：只有头 8 KB、
##     截到 600 KB 都卡死；乱码、空文件会报错然后 is_playing() 一直是 true、永远不发 finished），
##     所以交给播放器之前先按 Ogg 结构查一遍（check_file：只读开头和结尾各一段，几毫秒）。
##   · 不用 VideoStreamPlayer.finished 判断播完：它比流结束晚约 0.4–0.6 秒，而且发出时 stream_position 归零；这里看 stream_position。

signal skipped
signal revealing
signal finished

const DIR := "res://assets/traveler/intro/"
const SUFFIX := "_intro.ogv"
## play_over 建的 CanvasLayer 的层号：高于这一幕的界面层（act_exit_button.gd 的 120：返回、提示、载入卡）
const LAYER := 125
const FADE_IN_SEC := 0.4
## 片尾交接：画面叠化、声音交叉都是 0.5 秒（入场片最后 0.5 秒 = 这一幕的开场画面 + 实时环境声电平）
const HANDOVER_SEC := 0.5
const SKIP_FADE_SEC := 0.35
const MUSIC_BUS := "Music"
const AMBIENCE_BUS := "Ambience"
const SILENT_DB := -80.0
## 跳过药丸：出现后多久能点、点之前多久内不能有别处的点击、不动多久收起
const PILL_ARM_SEC := 0.6
const CALM_SEC := 0.6
const PILL_IDLE_SEC := 2.5
const PILL_ARMING_ALPHA := 0.45
const PILL_ALPHA := 1.0
const PILL_TEXT := "跳过 ›"
## 播放器卡住（位置不走）多久算坏了；总时长兜底 = 片长 + 这么多秒
const STALL_SEC := 3.0
const OVERRUN_SEC := 4.0
## check_file 读开头 / 结尾多少字节
const HEAD_BYTES := 262144
const TAIL_BYTES := 524288
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")

enum State { IDLE, PLAYING, HOLDING, REVEALING, DONE }

## 这一幕已经能看了：片尾到了就叠化进去；false 时停在最后一帧等（也可以在播放中途设成 true，或调 mark_act_ready()）
var act_ready := true
## 可选：每帧问一次这一幕就绪没有（比如 func() -> bool: return overlay.is_act_ready()）；和 act_ready 任一为真都算就绪
var ready_probe: Callable
## 播放时压住 Ambience 总线（片子里已经带了这一幕的环境声），片尾交叉还回去
var duck_ambience := true
## finished 之后自己 queue_free（play_over 建的那一层一起）
var auto_free := true

## 当前这一次在播哪一幕（play_file 时是空串）、哪个文件
var act_id := ""
var path := ""
## 这一次是被跳过的；这一次没播成（文件不在 / 坏了），原因
var was_skipped := false
var failed := false
var fail_reason := ""
## check_file 的结果（fps、帧数、片长……）
var info: Dictionary = {}

var _state := State.IDLE
var _video: VideoStreamPlayer
var _backdrop: Control
var _aspect: AspectRatioContainer
var _frame: Control
var _pill: Button
var _owned_layer: CanvasLayer
var _pending := ""
var _length := 0.0
var _alpha := 0.0
var _fade_sec := HANDOVER_SEC
var _t := 0.0
var _frames := 0
var _last_pos := -1.0
var _stall := 0.0
var _revealed := false
var _amb_idx := -1
var _amb_db0 := 0.0
var _idle := 1.0e9
var _pill_on := 0.0
var _pill_alpha := 0.0
var _last_outside_press := -1000000
var _press_ok := false

static var _checked: Dictionary = {}


# ------------------------------------------------------------------ 静态
static func intro_path(id: String) -> String:
	return DIR + id + SUFFIX


## 这一幕有能播的入场片（文件在，而且 Ogg 结构完整）
static func has_intro(id: String) -> bool:
	if id == "":
		return false
	return bool(check_file(intro_path(id)).get("ok", false))


## 在 host 下挂一层 CanvasLayer（层号 layer_index）并开始播这一幕的入场片，返回播放器。
## 这一层在这一帧末尾才真正挂上去（add_child.call_deferred：从某个 _ready 里调也不会碰上「父节点正忙」），
## 所以片子从下一帧开始走；拿到返回值后先连信号再 await 都来得及（播不了时 finished 也在这一帧末尾才发）。
## 结束后连这一层一起释放（auto_free）。挂在 get_tree().root 下时，中途换场景（change_scene_to_*）不影响它。
static func play_over(host: Node, id: String, layer_index: int = LAYER) -> Control:
	var layer := CanvasLayer.new()
	layer.name = "ActIntroLayer"
	layer.layer = layer_index
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var intro: Control = load("res://scripts/traveler/act_intro_player.gd").new()
	intro.name = "ActIntroPlayer"
	intro.set("_owned_layer", layer)
	layer.add_child(intro)
	host.add_child.call_deferred(layer)
	intro.call("play", id)
	return intro


# ------------------------------------------------------------------ 界面
func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	modulate.a = 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 黑边只画在画面外面（不是整屏黑底）：整体淡入淡出时每个子节点各自乘透明度，整屏黑底会让叠化中段发暗
	# （实测长安交接：片子和实时画面的红通道平均都在 88–90，叠化中段掉到 75）。
	# 这一层整屏铺满，播放时挡住鼠标，这一幕底下的城门、篝火点不到。
	_backdrop = Control.new()
	_backdrop.name = "Letterbox"
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.draw.connect(_draw_letterbox)
	_backdrop.resized.connect(_backdrop.queue_redraw)
	_aspect = AspectRatioContainer.new()
	_aspect.name = "Aspect"
	_aspect.ratio = 16.0 / 9.0
	_aspect.stretch_mode = AspectRatioContainer.STRETCH_FIT
	_aspect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_aspect)
	_aspect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame = Control.new()
	_frame.name = "Frame"
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_aspect.add_child(_frame)
	_frame.item_rect_changed.connect(_backdrop.queue_redraw)
	_build_pill()
	set_process(false)
	set_process_input(false)
	var pad_hub := get_node_or_null("/root/PadInput")
	if pad_hub != null:
		pad_hub.register(self, PAD_PRIORITY)
	if _pending != "":
		var p := _pending
		_pending = ""
		_start(p)


## 画面（16:9）外面的上下或左右黑边；和画面重叠 1 像素，免得小数坐标漏一条缝
func _draw_letterbox() -> void:
	var full := Rect2(Vector2.ZERO, _backdrop.size)
	var fr := Rect2(_frame.global_position - _backdrop.global_position, _frame.size).grow(-1.0)
	if fr.size.x <= 0.0 or fr.size.y <= 0.0:
		_backdrop.draw_rect(full, Color.BLACK)
		return
	var bars: Array[Rect2] = [
		Rect2(0.0, 0.0, full.size.x, fr.position.y),
		Rect2(0.0, fr.end.y, full.size.x, full.size.y - fr.end.y),
		Rect2(0.0, fr.position.y, fr.position.x, fr.size.y),
		Rect2(fr.end.x, fr.position.y, full.size.x - fr.end.x, fr.size.y),
	]
	for r in bars:
		if r.size.x > 0.0 and r.size.y > 0.0:
			_backdrop.draw_rect(r, Color.BLACK)


## 右上角「跳过 ›」：和这一幕左上角的「‹ 返回」同一套药丸（奶油底、挎包棕细边、圆体粗字）
func _build_pill() -> void:
	_pill = Button.new()
	_pill.name = "SkipPill"
	_pill.text = PILL_TEXT
	_pill.tooltip_text = "跳过（Esc）"
	_pill.focus_mode = Control.FOCUS_NONE
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pill.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_pill.add_theme_font_override("font", Kit.font("body", 700))
	_pill.add_theme_font_size_override("font_size", 18)
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		_pill.add_theme_color_override(key, Kit.INK)
	for st in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		_pill.add_theme_stylebox_override(st, _pill_box(0.86 if st == "normal" or st == "focus" else 0.97))
	_pill.anchor_left = 1.0
	_pill.anchor_right = 1.0
	_pill.offset_left = -18.0
	_pill.offset_right = -18.0
	_pill.offset_top = 16.0
	_pill.offset_bottom = 16.0
	_pill.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_pill.modulate.a = 0.0
	_pill.pressed.connect(_on_pill_pressed)
	_frame.add_child(_pill)


func _pill_box(bg_alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Kit.CREAM, bg_alpha)
	sb.border_color = Color(Kit.SATCHEL, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(18)
	sb.content_margin_left = 18
	sb.content_margin_right = 16
	sb.content_margin_top = 6
	sb.content_margin_bottom = 7
	sb.shadow_color = Color(0.15, 0.08, 0.03, 0.18)
	sb.shadow_size = 4
	sb.anti_aliasing = true
	return sb


# ------------------------------------------------------------------ 播放
## 播这一幕的入场片。返回 true = 开始播了；false = 没有能播的文件（照样会发 revealing + finished，在这一帧末尾）
func play(id: String) -> bool:
	act_id = id
	return play_file(intro_path(id))


## 播任意一个 .ogv（res:// 或 user:// 或绝对路径）
func play_file(file_path: String) -> bool:
	if _state in [State.PLAYING, State.HOLDING, State.REVEALING]:
		push_warning("act_intro_player: 已经在播 %s，忽略 %s" % [path, file_path])
		return false
	path = file_path
	was_skipped = false
	failed = false
	fail_reason = ""
	_revealed = false
	info = check_file(file_path)
	if not bool(info.get("ok", false)):
		_fail(str(info.get("reason", "bad file")))
		return false
	if not is_node_ready():
		_state = State.PLAYING   # 进树后在 _ready 里真正开始
		_pending = file_path
		return true
	return _start(file_path)


func _start(file_path: String) -> bool:
	var stream: VideoStream = null
	if file_path.begins_with("res://") and ResourceLoader.exists(file_path):
		stream = load(file_path) as VideoStream
	if stream == null:
		var th := VideoStreamTheora.new()
		th.file = file_path
		stream = th
	_video = VideoStreamPlayer.new()
	_video.name = "IntroVideo"
	_video.process_mode = Node.PROCESS_MODE_ALWAYS
	_video.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_video.expand = true
	_video.bus = MUSIC_BUS
	_video.volume_db = SILENT_DB
	_frame.add_child(_video)
	_frame.move_child(_video, 0)
	_video.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_video.stream = stream
	_video.play()
	var tex := _video.get_video_texture()
	if not _video.is_playing() or tex == null or tex.get_width() <= 0:
		_release_video()
		_fail("player did not start")
		return false
	if tex.get_height() > 0:
		_aspect.ratio = float(tex.get_width()) / float(tex.get_height())
	_length = _video.get_stream_length()
	if _length <= 0.0:
		_length = float(info.get("length", 0.0))
	_video.finished.connect(_on_video_finished)
	_state = State.PLAYING
	_t = 0.0
	_frames = 0
	_alpha = 0.0
	_last_pos = -1.0
	_stall = 0.0
	_idle = 1.0e9
	_pill_on = 0.0
	_pill_alpha = 0.0
	_press_ok = false
	modulate.a = 0.0
	visible = true
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_duck_begin()
	set_process(true)
	set_process_input(true)
	print("ACT_INTRO_PLAY ", JSON.stringify({"act": act_id, "path": file_path, "length": _length, "fps": info.get("fps", 0.0), "frames": info.get("frames", 0)}))
	return true


## 这一幕能看了（片尾到了就叠化；已经停在最后一帧就马上叠化）
func mark_act_ready() -> void:
	act_ready = true


## 立刻跳过（和 Esc、药丸一样）
func skip() -> void:
	if _state != State.PLAYING and _state != State.HOLDING:
		return
	if _pending != "":
		# 还没进树、还没真正开始：直接收尾，不建播放器
		_pending = ""
		was_skipped = true
		print("ACT_INTRO_SKIP ", JSON.stringify({"act": act_id, "at": 0.0}))
		skipped.emit()
		_state = State.DONE
		_emit_done.call_deferred()
		return
	was_skipped = true
	print("ACT_INTRO_SKIP ", JSON.stringify({"act": act_id, "at": snappedf(_pos(), 0.01)}))
	skipped.emit()
	_reveal(SKIP_FADE_SEC)


func is_active() -> bool:
	return _state in [State.PLAYING, State.HOLDING, State.REVEALING]


## 片子播完了、停在最后一帧等这一幕就绪
func is_holding() -> bool:
	return _state == State.HOLDING


## 片子里的时间（秒）；没在播时 0
func position_sec() -> float:
	return _pos()


func length_sec() -> float:
	return _length


## 测试 / 调试用：当前的视频播放器（没在播时 null）
func video_player() -> VideoStreamPlayer:
	return _video


func skip_pill() -> Button:
	return _pill


func _is_act_ready() -> bool:
	if act_ready:
		return true
	return ready_probe.is_valid() and bool(ready_probe.call())


func _pos() -> float:
	return _video.stream_position if _video != null and is_instance_valid(_video) else 0.0


func _process(delta: float) -> void:
	# 计时用截短的 delta：这一幕在下面建场景、编着色器时主线程可能卡一两秒，别让药丸、卡住检测被一帧长 delta 骗了
	var dt := minf(delta, 0.1)
	_t += dt
	var pos := _pos()
	var ended := _length > 0.0 and pos >= _length
	match _state:
		State.PLAYING:
			_frames += 1
			if _frames > 1:
				# 第一帧先不淡入：play() 那一刻视频贴图还是黑的，第一次 _process 之后才有片子的第 0 帧
				_alpha = move_toward(_alpha, 1.0, dt / FADE_IN_SEC)
			if pos > _last_pos + 0.0001:
				_stall = 0.0
			else:
				_stall += dt
			if ended:
				_film_over()
			elif _stall >= STALL_SEC or _t >= maxf(_length, 1.0) + OVERRUN_SEC:
				push_warning("act_intro_player: %s 卡住了（位置 %.2f 秒不走），直接交给这一幕" % [path, pos])
				_film_over()
				if _state == State.HOLDING:
					act_ready = true   # 坏了就别等
			elif _length > 0.0 and pos >= _length - HANDOVER_SEC and _is_act_ready():
				_reveal(HANDOVER_SEC)
		State.HOLDING:
			if _is_act_ready():
				_reveal(HANDOVER_SEC)
		State.REVEALING:
			if ended and _video != null and not _video.paused:
				_video.paused = true   # 片子先到头了：停在最后一帧，接着淡完
			_alpha = move_toward(_alpha, 0.0, dt / _fade_sec)
	_last_pos = maxf(_last_pos, pos)
	modulate.a = _alpha
	_update_audio(pos)
	_update_pill(dt)
	if _state == State.REVEALING and _alpha <= 0.0:
		_finish()


## 片子到头了：这一幕就绪就淡出，没就绪就停在最后一帧等
func _film_over() -> void:
	if _video != null:
		_video.paused = true
	if _is_act_ready():
		_reveal(HANDOVER_SEC)
	else:
		_state = State.HOLDING
		print("ACT_INTRO_HOLD ", JSON.stringify({"act": act_id, "at": snappedf(_pos(), 0.01)}))


func _on_video_finished() -> void:
	# 兜底：一般到不了这里（位置到头时已经暂停在最后一帧）
	if _state == State.PLAYING:
		_film_over()


func _reveal(sec: float) -> void:
	if _state == State.REVEALING or _state == State.DONE:
		return
	_state = State.REVEALING
	_fade_sec = maxf(0.05, sec)
	_emit_revealing()


func _emit_revealing() -> void:
	if _revealed:
		return
	_revealed = true
	revealing.emit()


# ------------------------------------------------------------------ 声音
## 片子声音 = 画面透明度 × 片尾交叉（cos）；Ambience 总线 = 压住，片尾交叉（sin）或淡出时还回去
func _update_audio(pos: float) -> void:
	var u := 0.0
	if _state == State.HOLDING:
		u = 1.0
	elif _length > 0.0:
		u = clampf((pos - (_length - HANDOVER_SEC)) / HANDOVER_SEC, 0.0, 1.0)
	if _video != null:
		var g := _alpha * cos(u * PI * 0.5)
		_video.volume_db = maxf(SILENT_DB, linear_to_db(g)) if g > 0.0001 else SILENT_DB
	if _amb_idx != -1:
		var back := maxf(1.0 - _alpha, sin(u * PI * 0.5))
		var amp := db_to_linear(_amb_db0) * back
		AudioServer.set_bus_volume_db(_amb_idx, maxf(SILENT_DB, linear_to_db(amp)) if amp > 0.0001 else SILENT_DB)


func _duck_begin() -> void:
	_amb_idx = -1
	if not duck_ambience:
		return
	var i := AudioServer.get_bus_index(AMBIENCE_BUS)
	if i == -1:
		return
	_amb_idx = i
	_amb_db0 = AudioServer.get_bus_volume_db(i)


func _duck_end() -> void:
	if _amb_idx != -1 and _amb_idx < AudioServer.bus_count and AudioServer.get_bus_name(_amb_idx) == AMBIENCE_BUS:
		AudioServer.set_bus_volume_db(_amb_idx, _amb_db0)
	_amb_idx = -1


# ------------------------------------------------------------------ 跳过
func _input(event: InputEvent) -> void:
	if not is_active():
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			skip()
		get_viewport().set_input_as_handled()   # 片子在的时候按键一个都不给下面（Esc 不会让这一幕返回开场）
		return
	# 手柄键：手柄层开着（安卓）时不在这里吞，手柄层（scripts/pad/pad_input.gd）把它们交给这里的 pad_action
	# （片子在时这一层排最前面），一样一个都不给下面；手柄层没开（桌面）时和以前一样在这里吞掉
	if event is InputEventJoypadButton:
		var hub := get_node_or_null("/root/PadInput")
		if hub == null or not bool(hub.get("enabled")):
			get_viewport().set_input_as_handled()
			return
	var press_at := Vector2.INF
	if event is InputEventMouseMotion:
		if (event as InputEventMouseMotion).relative.length_squared() > 0.0:
			_idle = 0.0
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		press_at = (event as InputEventMouseButton).position
	elif event is InputEventScreenTouch or event is InputEventScreenDrag or event is InputEventGesture:
		# 触屏、触控板手势：只拿来叫出药丸，然后吞掉（点药丸靠触屏模拟出来的鼠标事件，不受影响）
		_idle = 0.0
		get_viewport().set_input_as_handled()
		return
	if press_at != Vector2.INF:
		_idle = 0.0
		var now := Time.get_ticks_msec()
		if _pill_clickable() and _pill.get_global_rect().has_point(press_at):
			_press_ok = _pill_armed() and now - _last_outside_press >= int(CALM_SEC * 1000.0)
		else:
			_last_outside_press = now
			_press_ok = false


## 手柄（scripts/pad/pad_input.gd 的上下文，片子在时排最前面）：任何键都只是叫出「跳过 ›」药丸；
## 药丸出来 0.6 秒以后、而且离上一下手柄键也过了 0.6 秒，按 A 才跳过——和点药丸同一条规矩，连着乱按 A 不会跳过
const PAD_PRIORITY := 60


func pad_active() -> bool:
	return is_inside_tree() and is_active()


func pad_action(a: String) -> bool:
	_idle = 0.0
	var now := Time.get_ticks_msec()
	if a == "accept" and _pill_clickable() and _pill_armed() and now - _last_outside_press >= int(CALM_SEC * 1000.0):
		skip()
		return true
	_last_outside_press = now
	return true


func pad_focus() -> Variant:
	return _pill if _pill != null and _pill_armed() and _pill_alpha > 0.5 else null


func pad_glyphs() -> Array:
	return [[_pill, "A", "side"]] if _pill != null and _pill_armed() and _pill_alpha > 0.5 else []


func _on_pill_pressed() -> void:
	var ok := _press_ok
	_press_ok = false
	if ok:
		skip()
	else:
		print("ACT_INTRO_PILL_IGNORED ", JSON.stringify({"act": act_id, "armed": _pill_armed(), "since_outside_ms": Time.get_ticks_msec() - _last_outside_press}))


func _pill_armed() -> bool:
	return _pill_on >= PILL_ARM_SEC


func _pill_clickable() -> bool:
	return _pill != null and _pill.mouse_filter == Control.MOUSE_FILTER_STOP


func _update_pill(dt: float) -> void:
	if _pill == null:
		return
	_idle += dt
	var up := _state == State.PLAYING or _state == State.HOLDING
	var hovered := _pill_clickable() and _pill.get_global_rect().has_point(_pill.get_global_mouse_position())
	var want := up and (_idle < PILL_IDLE_SEC or hovered)
	if want:
		_pill_on += dt
	elif _pill_alpha < 0.05:
		_pill_on = 0.0
	var goal := 0.0
	if want:
		goal = PILL_ALPHA if _pill_armed() else PILL_ARMING_ALPHA
	_pill_alpha = move_toward(_pill_alpha, goal, dt * (4.0 if goal > _pill_alpha else 1.6))
	if not up:
		_pill_alpha = move_toward(_pill_alpha, 0.0, dt * 6.0)
	_pill.modulate.a = _pill_alpha
	var filter := Control.MOUSE_FILTER_STOP if up and _pill_alpha > 0.05 else Control.MOUSE_FILTER_IGNORE
	if _pill.mouse_filter != filter:
		_pill.mouse_filter = filter


# ------------------------------------------------------------------ 收尾
func _fail(reason: String) -> void:
	failed = true
	fail_reason = reason
	_state = State.DONE
	print("ACT_INTRO_UNAVAILABLE ", JSON.stringify({"act": act_id, "path": path, "reason": reason}))
	_emit_done.call_deferred()


func _emit_done() -> void:
	_emit_revealing()
	finished.emit()
	_maybe_free()


func _finish() -> void:
	if _state == State.DONE:
		return
	_state = State.DONE
	_release_video()
	_duck_end()
	_quiet()
	print("ACT_INTRO_DONE ", JSON.stringify({"act": act_id, "skipped": was_skipped, "t": snappedf(_t, 0.01)}))
	_emit_revealing()
	finished.emit()
	_maybe_free()


## 不再挡任何输入、不再每帧跑
func _quiet() -> void:
	visible = false
	modulate.a = 0.0
	_alpha = 0.0
	if _backdrop != null:
		_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _pill != null:
		_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pill.modulate.a = 0.0
	_pill_alpha = 0.0
	set_process(false)
	set_process_input(false)


func _release_video() -> void:
	if _video == null:
		return
	if is_instance_valid(_video):
		if _video.finished.is_connected(_on_video_finished):
			_video.finished.disconnect(_on_video_finished)
		_video.stop()
		_video.stream = null
		if _video.get_parent() != null:
			_video.get_parent().remove_child(_video)
		_video.queue_free()
	_video = null


func _maybe_free() -> void:
	if not auto_free:
		return
	if _owned_layer != null and is_instance_valid(_owned_layer):
		_owned_layer.queue_free()
	elif is_inside_tree():
		queue_free()


func _exit_tree() -> void:
	# 被中途拿掉（比如整个开场被换掉）：不发信号，只把视频和 Ambience 总线收拾好
	if _state != State.DONE and _state != State.IDLE:
		_state = State.DONE
		_release_video()
		_duck_end()
		_quiet()


# ------------------------------------------------------------------ 文件检查
## 按 Ogg 结构查一遍这个 .ogv 能不能安全交给 VideoStreamPlayer（只读开头 256 KB、结尾 512 KB）：
## 开头的页首尾相接、有 Theora 流且 Theora / Vorbis 各三个头包齐全；结尾一串页正好接到文件末尾，每条流都有结束页。
## 返回 {ok, reason, fps, frames, length, audio, bytes}；同一个文件（路径 + 大小 + 修改时间）只查一次。
static func check_file(file_path: String) -> Dictionary:
	var r := {"ok": false, "reason": "", "fps": 0.0, "frames": 0, "length": 0.0, "audio": false, "bytes": 0}
	if file_path == "" or not FileAccess.file_exists(file_path):
		r.reason = "missing"
		return r
	var key := "%s|%d" % [file_path, FileAccess.get_modified_time(file_path)]
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		r.reason = "unreadable"
		return r
	var size := f.get_length()
	key += "|%d" % size
	if _checked.has(key):
		return (_checked[key] as Dictionary).duplicate()
	r.bytes = size
	_check_ogg(f, size, r)
	f.close()
	_checked[key] = r.duplicate()
	return r


static func _check_ogg(f: FileAccess, size: int, r: Dictionary) -> void:
	if size < 4096:
		r.reason = "too small (%d bytes)" % size
		return
	var head := f.get_buffer(mini(size, HEAD_BYTES))
	var streams: Dictionary = {}   # serial -> {"kind": theora|vorbis|other, "packets": 完整包数}
	var theora := -1
	var shift := 0
	var frn := 0
	var frd := 0
	var vrev := 0
	var off := 0
	var pages := 0
	while true:
		var pg := _page(head, off)
		if pg.is_empty():
			if off == 0:
				r.reason = "not an Ogg file"
			elif size <= HEAD_BYTES:
				r.reason = "truncated in the header pages"
			else:
				r.reason = "bad Ogg page at byte %d" % off
			return
		pages += 1
		var serial: int = pg.serial
		var body: int = pg.body
		if int(pg.type) & 2:
			if streams.has(serial) or pages > 8:
				r.reason = "bad stream start"
				return
			var kind := "other"
			if int(pg.body_len) >= 42 and head[body] == 0x80 and head.slice(body + 1, body + 7).get_string_from_ascii() == "theora":
				kind = "theora"
				if head[body + 7] != 3:
					r.reason = "unsupported Theora version"
					return
				vrev = head[body + 9]
				frn = _be32(head, body + 22)
				frd = _be32(head, body + 26)
				shift = (((head[body + 40] << 8) | head[body + 41]) >> 5) & 31
				if theora == -1:
					theora = serial
			elif int(pg.body_len) >= 7 and head[body] == 0x01 and head.slice(body + 1, body + 7).get_string_from_ascii() == "vorbis":
				kind = "vorbis"
				r.audio = true
			streams[serial] = {"kind": kind, "packets": 0}
		elif not streams.has(serial):
			r.reason = "page before its stream starts"
			return
		var cur: Dictionary = streams[serial]
		cur.packets = int(cur.packets) + int(pg.packets)
		off += int(pg.len)
		if not (int(pg.type) & 2) and theora != -1:
			var done := true
			for s: int in streams:
				var st: Dictionary = streams[s]
				if st.kind != "other" and int(st.packets) < 3:
					done = false
			if done:
				break
		if pages > 256:
			r.reason = "headers not found"
			return
	if theora == -1:
		r.reason = "no Theora video stream"
		return
	if frn <= 0 or frd <= 0:
		r.reason = "bad frame rate"
		return
	# 结尾：一串首尾相接、正好停在文件末尾的页，每条认识的流都要有结束页（EOS）
	var tail_start := maxi(0, size - TAIL_BYTES)
	f.seek(tail_start)
	var tail := f.get_buffer(size - tail_start)
	var chain := _tail_chain(tail)
	if chain.is_empty():
		r.reason = "does not end on a complete Ogg page (truncated?)"
		return
	var eos: Dictionary = {}
	var last_gp := -1
	for pg: Dictionary in chain:
		var serial: int = pg.serial
		if int(pg.type) & 4:
			eos[serial] = true
		if serial == theora and int(pg.gp) >= 0:
			last_gp = int(pg.gp)
	for s: int in streams:
		if (streams[s] as Dictionary).kind != "other" and not eos.has(s):
			r.reason = "no end-of-stream page (truncated?)"
			return
	if last_gp < 0:
		r.reason = "no video timing at the end"
		return
	var frames := (last_gp >> shift) + (last_gp & ((1 << shift) - 1)) + (0 if vrev >= 1 else 1)
	r.fps = float(frn) / float(frd)
	r.frames = frames
	r.length = float(frames) * float(frd) / float(frn)
	if frames <= 0:
		r.reason = "no video frames"
		return
	r.ok = true


## 解析 b[off] 开始的一页 Ogg；不是完整的一页就返回 {}
static func _page(b: PackedByteArray, off: int) -> Dictionary:
	var n := b.size()
	if off < 0 or off + 27 > n:
		return {}
	if b[off] != 0x4F or b[off + 1] != 0x67 or b[off + 2] != 0x67 or b[off + 3] != 0x53 or b[off + 4] != 0:
		return {}
	var type := b[off + 5]
	if type & ~7:
		return {}
	var nseg := b[off + 26]
	if off + 27 + nseg > n:
		return {}
	var body_len := 0
	var packets := 0
	for i in nseg:
		var lace := b[off + 27 + i]
		body_len += lace
		if lace < 255:
			packets += 1
	var total := 27 + nseg + body_len
	if off + total > n:
		return {}
	return {"type": type, "gp": b.decode_s64(off + 6), "serial": b.decode_u32(off + 14), "body": off + 27 + nseg,
		"body_len": body_len, "packets": packets, "len": total}


## 在文件末尾这一段里找一串首尾相接、正好停在末尾的页
static func _tail_chain(b: PackedByteArray) -> Array[Dictionary]:
	var n := b.size()
	var i := b.find(0x4F, 0)
	while i != -1 and i + 27 <= n:
		if b[i + 1] == 0x67 and b[i + 2] == 0x67 and b[i + 3] == 0x53 and b[i + 4] == 0:
			var pages: Array[Dictionary] = []
			var p := i
			while p < n:
				var pg := _page(b, p)
				if pg.is_empty():
					break
				pages.append(pg)
				p += int(pg.len)
			if p == n and not pages.is_empty():
				return pages
		i = b.find(0x4F, i + 1)
	return []


static func _be32(b: PackedByteArray, o: int) -> int:
	return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]
