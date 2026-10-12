extends RefCounted
## 环境音公共组件（方案见 docs/design/shanhe-luren/sound-20260926/README.md）。
## - allowed()：无界面运行、测试、驱动脚本下一律不出声，也不建节点、不读文件（不打扰另一个会话的测试）
## - bus()：确保「Ambience」总线在（C 阶段起由 audio_buses.gd 统一建全部总线），不改 project.godot，也不新建总线布局文件
## - stream()：读 assets/audio/ambience/<名字>.ogg，循环素材打开 loop；没导入时直接从文件读
## - Layer：一条循环底床，按目标音量平滑淡变，从随机位置开始播
## - Scatter：按随机间隔播一次性点缀（音高、音量带一点抖动，不连续重复同一个）
## - mix(name)：读 data/audio/ambience/<场景>.json 的参数（起点值，不是冻结值，可以随时调）

const DIR := "res://assets/audio/ambience/"
const MIX_DIR := "res://data/audio/ambience/"
const BUS := "Ambience"

static var _cache: Dictionary = {}
static var _mix: Dictionary = {}


## 能直接出声的 -s 驱动脚本（其余 .gd 驱动脚本都是截图、录像、测试类工具，一律静音）
const SCRIPT_ALLOW: Array[String] = ["tools/traveler/baghdad/cycle/review_cycle.gd"]


static func allowed() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	# 无声驱动（--audio-driver Dummy 的截图、录像工具）不出声；Movie Maker 的驱动也叫 Dummy，但它会把声音录进去，放行（量响度靠它）
	if AudioServer.get_driver_name() == "Dummy" and not OS.has_feature("movie"):
		return false
	# 注意：--audio-driver、--write-movie、--path 这类引擎参数不在 get_cmdline_args() 里，这里只看得到 -s 脚本和场景路径
	var args: PackedStringArray = OS.get_cmdline_args()
	for i in args.size():
		var a: String = args[i].to_lower()
		if a.contains("tests/") or a.contains("/scratchpad/") or a.contains("probe") or a == "--no-ambience":
			return false
		if (a == "-s" or a == "--script") and i + 1 < args.size():
			var drv: String = args[i + 1].to_lower()
			if drv.ends_with(".gd") and not SCRIPT_ALLOW.any(func(k: String) -> bool: return drv.ends_with(k)):
				return false
	for a in OS.get_cmdline_user_args():
		if a == "--no-ambience":
			return false
	return true


## 混音器离树时调用：停掉 root 下所有播放器、清空 stream。
## 停掉的播放要等音频线程再混一两次才真正释放；关窗 / 退出时 AudioServer 若抢先关闭，
## 还在响的循环会报 “ObjectDB instances leaked”，所以出过声就给音频线程留 60 毫秒。
static func release(root: Node, played: bool = true) -> void:
	for p in root.find_children("*", "AudioStreamPlayer", true, false):
		(p as AudioStreamPlayer).stop()
		(p as AudioStreamPlayer).stream = null
	if played:
		OS.delay_msec(60)


## C 阶段起总线统一由 scripts/audio/audio_buses.gd 建（Ambience 带低通和 sidechain 避让）；这里只保证它在
static func bus() -> String:
	if AudioServer.get_bus_index(BUS) == -1:
		load("res://scripts/audio/audio_buses.gd").ensure()
	return BUS


static func stream(name: String) -> AudioStream:
	if _cache.has(name):
		return _cache[name]
	var path: String = DIR + name + ".ogg"
	var s: AudioStream = null
	if ResourceLoader.exists(path):
		s = load(path) as AudioStream
	elif FileAccess.file_exists(path):
		s = AudioStreamOggVorbis.load_from_file(ProjectSettings.globalize_path(path))
	if s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = name.contains("_loop")
	_cache[name] = s
	return s


static func mix(scene: String) -> Dictionary:
	if not _mix.has(scene):
		var p: String = MIX_DIR + scene + ".json"
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null
		_mix[scene] = d if d is Dictionary else {}
	return _mix[scene]


static func db_to_amp(db: float) -> float:
	return 0.0 if db <= -79.0 else pow(10.0, db / 20.0)


static func amp_to_db(a: float) -> float:
	return -80.0 if a <= 0.0001 else 20.0 * log(a) / log(10.0)


## 一条循环底床：set_level(db, 秒) 淡到目标；set_level(-80) 淡到无声后自动暂停，省 CPU
class Layer extends AudioStreamPlayer:
	var target_db: float = -80.0
	var fade_sec: float = 2.0
	var _amp: float = 0.0

	func setup(sound: String, start_db: float = -80.0) -> Layer:
		name = "Amb_" + sound
		stream = LshuAmbStreams.get_stream(sound)
		bus = LshuAmbStreams.get_bus()
		target_db = start_db
		_amp = 0.0
		volume_db = -80.0
		return self

	func set_level(db: float, sec: float = 2.0) -> void:
		target_db = db
		fade_sec = maxf(0.05, sec)
		if db > -79.0 and not playing and stream != null:
			play(randf() * maxf(0.0, stream.get_length() - 0.1))

	func _ready() -> void:
		if target_db > -79.0:
			set_level(target_db, fade_sec)

	func _process(delta: float) -> void:
		var goal: float = 0.0 if target_db <= -79.0 else pow(10.0, target_db / 20.0)
		var rate: float = maxf(goal, _amp) / fade_sec if fade_sec > 0.0 else 1.0
		_amp = move_toward(_amp, goal, maxf(rate, 0.02) * delta)
		var db: float = -80.0 if _amp <= 0.0001 else 20.0 * log(_amp) / log(10.0)
		# 只在真的变了时写：Godot 4.7.1 播放中每写一次 volume_db 都换一份混音参数、两帧后释放旧的，
		# 混音线程卡在那两帧里会读到已释放的内存（夜测 STRESS-1）。稳态一次不写，淡入淡出按 0.2 dB 一步写，
		# 引擎在每个混音块里本来就把音量平滑过渡，听不出台阶。
		if absf(db - volume_db) >= 0.2 or (_amp == goal and db != volume_db):
			volume_db = db
		if _amp <= 0.0001 and goal <= 0.0 and playing:
			stop()

	func _exit_tree() -> void:
		stop()
		stream = null


## 随机点缀：每隔 [min,max] 秒从 sounds 里挑一个（不连着重复）播一次
class Scatter extends Node:
	var sounds: Array = []
	var interval := Vector2(20, 40)
	var volume := Vector2(-14, -10)
	var pitch := Vector2(0.95, 1.05)
	var enabled := true
	var gain_db: float = 0.0
	var _left: float = 0.0
	var _last: String = ""
	var _players: Array[AudioStreamPlayer] = []

	func setup(list: Array, every: Vector2, vol: Vector2, pit: Vector2 = Vector2(0.95, 1.05), first_delay: float = -1.0) -> Scatter:
		sounds = list
		interval = every
		volume = vol
		pitch = pit
		_left = first_delay if first_delay >= 0.0 else randf_range(every.x, every.y)
		return self

	func _ready() -> void:
		for i in 3:
			var p := AudioStreamPlayer.new()
			p.bus = LshuAmbStreams.get_bus()
			add_child(p)
			_players.append(p)

	func _process(delta: float) -> void:
		if not enabled or sounds.is_empty():
			return
		_left -= delta
		if _left > 0.0:
			return
		_left = randf_range(interval.x, interval.y)
		fire()

	## 立刻播一个（也给外面按事件触发用）；extra_db 叠加在随机音量上
	func fire(extra_db: float = 0.0, pitch_override: float = -1.0) -> void:
		if sounds.is_empty():
			return
		var pick: String = str(sounds[randi() % sounds.size()])
		if sounds.size() > 1:
			var guard := 0
			while pick == _last and guard < 6:
				pick = str(sounds[randi() % sounds.size()])
				guard += 1
		_last = pick
		var p: AudioStreamPlayer = null
		for q in _players:
			if not q.playing:
				p = q
				break
		if p == null:
			p = _players[0]
		p.stream = LshuAmbStreams.get_stream(pick)
		p.volume_db = randf_range(volume.x, volume.y) + gain_db + extra_db
		p.pitch_scale = pitch_override if pitch_override > 0.0 else randf_range(pitch.x, pitch.y)
		p.play()

	func _exit_tree() -> void:
		for p in _players:
			p.stop()
			p.stream = null


## 内部类拿不到外层的静态函数：转发一下
class LshuAmbStreams:
	static func get_stream(n: String) -> AudioStream:
		return load("res://scripts/audio/ambience/amb_kit.gd").stream(n)

	static func get_bus() -> String:
		return load("res://scripts/audio/ambience/amb_kit.gd").bus()
