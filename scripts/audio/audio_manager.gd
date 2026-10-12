extends Node

## 轻量音效总线：只监听表现层，不改规则、RNG 或信号语义。
## C 阶段（docs/design/shanhe-luren/sound-20260926/README.md）：
## - 允许出声时（amb_kit.allowed()：不是无界面 / 测试 / 驱动脚本）先建总线（audio_buses.gd），
##   一次性音效走 SFX，悬停和点击走 UI，移动循环走 Movement；不允许时总线不建，全部照旧走 Master。
## - 移动循环：骆驼 = 马蹄、商船 = 划桨（文件名不变）；循环终点按真实帧数算（原来 QOA 下拿字节数当帧数，只循环了前 1.6 秒），
##   每次从随机位置开始播。
## - 对局以外的「导演」SoundDirector（scripts/audio/sound_director.gd）读这里的几个公开量：
##   movement_transport（正在走的是骆驼还是船）、last_dice_roll_msec / last_trade_msec（刚刚有没有人放过，避免 AI 补声重复）。

const Amb := preload("res://scripts/audio/ambience/amb_kit.gd")
const Buses := preload("res://scripts/audio/audio_buses.gd")

const UI_HOVER := preload("res://assets/audio/sfx/ui_hover_v1.wav")
const UI_CLICK := preload("res://assets/audio/sfx/ui_click_v1.wav")
const DICE_ROLL := preload("res://assets/audio/sfx/dice_roll_v1.wav")
const DICE_LAND := preload("res://assets/audio/sfx/dice_land_v1.wav")
const CARD_DEAL := preload("res://assets/audio/sfx/card_deal_v1.wav")
const CARD_FLIP := preload("res://assets/audio/sfx/card_flip_v1.wav")
const TRADE_SUCCESS := preload("res://assets/audio/sfx/trade_success_v1.wav")
const PIECE_ARRIVE := preload("res://assets/audio/sfx/piece_arrive_v1.wav")
## 骆驼：马蹄行走（31.8 s 无缝循环）；商船：划桨（26.3 s）。见 tools/audio/phase_c_assets.py
const CAMEL_LOOP := preload("res://assets/audio/sfx/camel_walk_loop_v1.wav")
const SHIP_LOOP := preload("res://assets/audio/sfx/ship_sail_loop_v1.wav")
## 两条都落在约 −33 LUFS（马蹄文件 −31.6、划桨 −30.1，按双单声道算）
const CAMEL_LOOP_DB := -1.5
const SHIP_LOOP_DB := -3.0

const POOL_SIZE := 10

var _pool: Array[AudioStreamPlayer] = []
var _pool_cursor := 0
var _movement: AudioStreamPlayer
var _movement_fade: Tween
var _last_hover_msec := 0
var _pitch_rng := RandomNumberGenerator.new()
## 正在播的移动循环属于哪种交通工具（GameData.Transport），没在播 = -1
var movement_transport: int = -1
## 最近一次掷骰声 / 交易成功声的时间（Time.get_ticks_msec）
var last_dice_roll_msec: int = -100000
var last_trade_msec: int = -100000


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_pitch_rng.seed = 20260723
	if Amb.allowed():
		Buses.ensure()
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.name = "Sfx%02d" % i
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		player.bus = Buses.bus_or_master(Buses.SFX)
		add_child(player)
		_pool.append(player)
	_movement = AudioStreamPlayer.new()
	_movement.name = "PieceMovement"
	_movement.process_mode = Node.PROCESS_MODE_ALWAYS
	_movement.bus = Buses.bus_or_master(Buses.MOVEMENT)
	add_child(_movement)
	get_tree().node_added.connect(_on_node_added)
	call_deferred("_scan_existing_buttons")


## 退出时停掉所有播放器、清空 stream；还有没回收的播放就给音频线程 200 毫秒把它们收掉，
## 不然引擎关音频时报 “ObjectDB instances leaked”（骰子、翻牌、交易这几个 WAV 各带一个播放实例）。
## 无界面跑测试时 60 毫秒不够（实测 6 次里 2 次还漏），200 毫秒连跑 10 次都干净；只在退出、且确实有声音没收时才等。
func _exit_tree() -> void:
	var busy := false
	for player in _pool + [_movement]:
		if player == null or not is_instance_valid(player):
			continue
		busy = busy or player.has_stream_playback()
		player.stop()
		player.stream = null
	if busy:
		OS.delay_msec(200)


func _scan_existing_buttons() -> void:
	if not is_inside_tree():
		return
	_scan_buttons(get_tree().root)


func _scan_buttons(node: Node) -> void:
	_connect_button(node)
	for child in node.get_children():
		_scan_buttons(child)


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		call_deferred("_connect_button", node)


func _connect_button(node: Variant) -> void:
	# node_added 的 deferred 回调可能在动态交易控件 queue_free() 后才执行。
	# 参数不能标注为 Node：引擎此时传回的是已失效 Object，会在进入函数前
	# 触发类型转换错误，导致测试和调试器出现无关红错。
	# 先验活性，随后才能做 `is BaseButton`；对已释放 Variant 先做类型判断本身
	# 也会触发 “Left operand of 'is' is a previously freed instance”。
	if node == null or not is_instance_valid(node):
		return
	if not node is BaseButton:
		return
	var button := node as BaseButton
	if button.has_meta("silkroad_sfx_connected"):
		return
	button.set_meta("silkroad_sfx_connected", true)
	button.mouse_entered.connect(_on_button_hover.bind(button))
	button.pressed.connect(_on_button_pressed.bind(button))


func _on_button_hover(button: BaseButton) -> void:
	if button.disabled or not button.visible:
		return
	var now := Time.get_ticks_msec()
	if now - _last_hover_msec < 45:
		return
	_last_hover_msec = now
	_play(UI_HOVER, -18.0, 0.98 + _pitch_rng.randf_range(-0.025, 0.025), Buses.UI)


## 不再看 button.disabled：点击声是 deferred 才接上的，排在按钮自己的处理函数后面，
## 「出发！」这类一按就把自己禁用的按钮，到这里已经是 disabled，原来就一声不响（夜测 AUD-8）。
## 禁用的按钮本来就不会发 pressed，不用再挡。
func _on_button_pressed(_button: BaseButton) -> void:
	_play(UI_CLICK, -12.0, 0.97 + _pitch_rng.randf_range(-0.02, 0.02), Buses.UI)


func play_dice_roll() -> void:
	last_dice_roll_msec = Time.get_ticks_msec()
	_play(DICE_ROLL, -7.0, 1.0)


func play_dice_land() -> void:
	_play(DICE_LAND, -5.5, 1.0)


func play_card_deal(pitch: float = 1.0) -> void:
	_play(CARD_DEAL, -10.0, pitch)


func play_card_flip() -> void:
	_play(CARD_FLIP, -7.5, 1.0)


## gain_db：AI 的交易由 SoundDirector 补声，比真人低 3 dB
func play_trade_success(gain_db: float = 0.0) -> void:
	last_trade_msec = Time.get_ticks_msec()
	_play(TRADE_SUCCESS, -7.0 + gain_db, 1.0)


func play_piece_arrive() -> void:
	_play(PIECE_ARRIVE, -9.0, 1.0)


func start_piece_loop(transport: int) -> void:
	if _movement_fade != null and _movement_fade.is_valid():
		_movement_fade.kill()
	_reset_movement_bus()
	var ship: bool = transport == GameData.Transport.SHIP
	var source: AudioStreamWAV = SHIP_LOOP if ship else CAMEL_LOOP
	var looped := source.duplicate() as AudioStreamWAV
	looped.loop_mode = AudioStreamWAV.LOOP_FORWARD
	looped.loop_begin = 0
	looped.loop_end = loop_frames(looped)
	_movement.stop()
	_movement.stream = looped
	_movement.volume_db = SHIP_LOOP_DB if ship else CAMEL_LOOP_DB
	# 每次从随机位置起播：31 秒的马蹄、26 秒的划桨，一局里不会老听到同一段开头
	_movement.play(_pitch_rng.randf() * maxf(0.0, looped.get_length() - 1.0))
	movement_transport = transport


## 一条 WAV 的真实帧数（循环终点）。get_length() 已按格式（PCM / IMA-ADPCM / QOA）和声道数折算过，
## 乘回采样率就是帧数；原来的 data.size() / 每样本字节数 对 QOA 和立体声都是错的。
static func loop_frames(stream: AudioStreamWAV) -> int:
	if stream == null:
		return 0
	return int(round(stream.get_length() * float(stream.mix_rate)))


func stop_piece_loop(with_arrival: bool = true) -> void:
	if _movement == null:
		return
	if _movement_fade != null and _movement_fade.is_valid():
		_movement_fade.kill()
	_movement_fade = null
	if with_arrival:
		var bus: int = AudioServer.get_bus_index(Buses.MOVEMENT)
		if _movement.playing and bus != -1:
			# 淡出推的是 Movement 总线推子，不是播放器的 volume_db：Godot 4.7.1 里播放中每写一次 volume_db，
			# 引擎都换一份混音参数、旧的两帧后释放，混音线程恰好卡在那两帧里就读到已释放的内存
			# （2026-09-27 夜测 STRESS-1：到站淡出时 SIGSEGV）。总线推子只是一个浮点数，没有这个问题。
			# 没有 Movement 总线（无界面、测试）时不淡，直接停。
			_movement_fade = create_tween()
			_movement_fade.tween_method(func(db: float) -> void: AudioServer.set_bus_volume_db(bus, db), 0.0, -38.0, 0.14)
			_movement_fade.tween_callback(func() -> void:
				if _movement != null:
					_movement.stop()
					_movement.stream = null
				_reset_movement_bus()
				movement_transport = -1
			)
		else:
			_movement.stop()
			_movement.stream = null
			movement_transport = -1
		play_piece_arrive()
	else:
		_movement.stop()
		_movement.stream = null
		_reset_movement_bus()
		movement_transport = -1


## 移动循环的淡出被打断（又开始走、或者硬停）时，把 Movement 总线推子放回 0 dB
func _reset_movement_bus() -> void:
	var bus: int = AudioServer.get_bus_index(Buses.MOVEMENT)
	if bus != -1:
		AudioServer.set_bus_volume_db(bus, 0.0)


func silence_all() -> void:
	## Hard stop for test teardown / preview shutdown (no arrival chime).
	if _movement_fade != null and _movement_fade.is_valid():
		_movement_fade.kill()
	_movement_fade = null
	if _movement != null:
		_movement.stop()
		_movement.stream = null
	_reset_movement_bus()
	movement_transport = -1
	for player in _pool:
		if player == null or not is_instance_valid(player):
			continue
		player.stop()
		player.stream = null
	# SoundDirector（对局、设置页、加载页的环境声和音乐）一起停
	var director := get_node_or_null("/root/SoundDirector")
	if director != null and director.has_method("stop_all"):
		director.call("stop_all")


func _play(stream: AudioStream, volume_db: float, pitch: float, bus_name: String = Buses.SFX) -> void:
	if stream == null or _pool.is_empty():
		return
	var chosen: AudioStreamPlayer = null
	for i in _pool.size():
		var candidate := _pool[(_pool_cursor + i) % _pool.size()]
		if not candidate.playing:
			chosen = candidate
			_pool_cursor = (_pool_cursor + i + 1) % _pool.size()
			break
	if chosen == null:
		chosen = _pool[_pool_cursor]
		_pool_cursor = (_pool_cursor + 1) % _pool.size()
	chosen.stream = stream
	chosen.volume_db = volume_db
	chosen.pitch_scale = pitch
	chosen.bus = Buses.bus_or_master(bus_name)
	chosen.play()
