extends RefCounted
## 音频总线（方案 docs/design/shanhe-luren/sound-20260926/plan.md §2.1，C 阶段）。
## - ensure()：按需建 Music / Ambience / SFX / UI / Movement 五条总线（都送 Master），Master 末端加限幅器（天花板 −1 dB）。
##   只在 amb_kit.allowed() 为真时由 AudioManager 调：无界面、测试、驱动脚本下一条都不多建（AudioServer.bus_count 保持 1），
##   播放器指向不存在的总线时引擎会自动退回 Master，所以那些情况下声音照旧。
##   不新建 default_bus_layout.tres、不改 project.godot 的 [audio]。
## - Music、Ambience 上各两个效果：① 低通（平时关着，只在对局界面由 SoundDirector 打开并推截止频率）；
##   ② 压缩器，sidechain 接 SFX：骰子、翻牌、交易、事件点缀这些对局音效一响，音乐和环境声自动让开几 dB（替掉原来的 Tween 避让）。
##   移动循环（马蹄 / 划桨）走单独的 Movement 总线，不触发避让，免得一路走一路「喘」。
## - 开场静音键（Carlos 2026-09-27）：只静 Music + Ambience（按钮音、对局音效照常）；记在
##   LshuProgress.dir_path()/settings.cfg 的 [audio] music_muted，和其他 L叔 设置同一个文件。
##   只有正式入口（lshu_match_settings.is_real_game）读写这个设置；测试与预览只在内存里切，不碰玩家的设置。

const MatchSettings := preload("res://scripts/lshu_ui/lshu_match_settings.gd")

const MASTER := "Master"
const MUSIC := "Music"
const AMBIENCE := "Ambience"
const SFX := "SFX"
const UI := "UI"
const MOVEMENT := "Movement"
const ORDER: Array[String] = [MUSIC, AMBIENCE, SFX, UI, MOVEMENT]

## UI 总线推子（悬停、点击，方案 §2.1）
const UI_DB := -2.0
## Master 限幅器天花板
const LIMIT_CEILING_DB := -1.0
## sidechain 避让（读的是 SFX 总线推子之后的信号）。2026-09-27 Movie Maker 实测（稳定正弦做底床、带通测它自己）：
## 掷骰 −4.8 dB、落骰 −4.6、交易成功 −5.5、翻牌 −2.4、发牌 −0.7；起音约 0.1 秒，约 1.5 秒回到 0.5 dB 以内。
## 事件点缀的铃（峰值约 −18 dBFS）基本不触发。
const DUCK: Dictionary = {"threshold_db": -20.0, "ratio": 2.0, "attack_us": 20000.0, "release_ms": 400.0}
## 低通关着时的截止频率（对局以外）
const LOWPASS_OPEN_HZ := 20000.0

const SETTINGS_SECTION := "audio"
const SETTINGS_KEY := "music_muted"

static var _music_muted: bool = false


## 建总线和效果（重复调用无害：已有的总线、已有的效果都不重复加）
static func ensure() -> void:
	for name in ORDER:
		var i: int = AudioServer.get_bus_index(name)
		if i == -1:
			AudioServer.add_bus()
			i = AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, name)
			AudioServer.set_bus_send(i, MASTER)
			if name == UI:
				AudioServer.set_bus_volume_db(i, UI_DB)
		if name == MUSIC or name == AMBIENCE:
			if _effect_index(i, "AudioEffectLowPassFilter") == -1:
				var lp := AudioEffectLowPassFilter.new()
				lp.cutoff_hz = LOWPASS_OPEN_HZ
				AudioServer.add_bus_effect(i, lp)
				AudioServer.set_bus_effect_enabled(i, AudioServer.get_bus_effect_count(i) - 1, false)
			if _effect_index(i, "AudioEffectCompressor") == -1:
				var c := AudioEffectCompressor.new()
				c.threshold = float(DUCK.threshold_db)
				c.ratio = float(DUCK.ratio)
				c.attack_us = float(DUCK.attack_us)
				c.release_ms = float(DUCK.release_ms)
				c.sidechain = SFX
				AudioServer.add_bus_effect(i, c)
	if _effect_index(0, "AudioEffectHardLimiter") == -1:
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = LIMIT_CEILING_DB
		AudioServer.add_bus_effect(0, lim)
	_apply_mute()


static func exists(bus_name: String) -> bool:
	return AudioServer.get_bus_index(bus_name) != -1


## 总线在就用它，不在（无界面、测试）就用 Master
static func bus_or_master(bus_name: String) -> String:
	return bus_name if exists(bus_name) else MASTER


## 某条总线上第一个某类效果的序号，没有就 -1
static func _effect_index(bus_idx: int, cls: String) -> int:
	if bus_idx < 0:
		return -1
	for e in AudioServer.get_bus_effect_count(bus_idx):
		var fx: AudioEffect = AudioServer.get_bus_effect(bus_idx, e)
		if fx != null and fx.is_class(cls):
			return e
	return -1


## 对局界面用：把某条总线的低通推到 hz（≥ LOWPASS_OPEN_HZ 时直接关掉）
static func set_lowpass(bus_name: String, hz: float) -> void:
	var i: int = AudioServer.get_bus_index(bus_name)
	var e: int = _effect_index(i, "AudioEffectLowPassFilter")
	if e == -1:
		return
	var on: bool = hz < LOWPASS_OPEN_HZ - 1.0
	var lp := AudioServer.get_bus_effect(i, e) as AudioEffectLowPassFilter
	if on:
		lp.cutoff_hz = hz
	if AudioServer.is_bus_effect_enabled(i, e) != on:
		AudioServer.set_bus_effect_enabled(i, e, on)


# ------------------------------------------------------------------ 开场静音键
static func music_muted() -> bool:
	return _music_muted


## 开场建好时调：正式入口里读玩家上次的设置并应用；返回现在是不是静音（给按钮画斜杠）
static func load_music_muted(tree: SceneTree) -> bool:
	if MatchSettings.is_real_game(tree):
		var cfg := ConfigFile.new()
		if cfg.load(MatchSettings.settings_path()) == OK:
			_music_muted = bool(cfg.get_value(SETTINGS_SECTION, SETTINGS_KEY, false))
	_apply_mute()
	return _music_muted


## 点静音键：只静 Music + Ambience；正式入口里记下来，下次打开还是这样
static func set_music_muted(on: bool, tree: SceneTree) -> void:
	_music_muted = on
	_apply_mute()
	if not MatchSettings.is_real_game(tree):
		return
	var cfg := ConfigFile.new()
	cfg.load(MatchSettings.settings_path())
	cfg.set_value(SETTINGS_SECTION, SETTINGS_KEY, on)
	DirAccess.make_dir_recursive_absolute(MatchSettings.settings_path().get_base_dir())
	cfg.save(MatchSettings.settings_path())


static func _apply_mute() -> void:
	for name in [MUSIC, AMBIENCE]:
		var i: int = AudioServer.get_bus_index(name)
		if i != -1 and AudioServer.is_bus_mute(i) != _music_muted:
			AudioServer.set_bus_mute(i, _music_muted)
