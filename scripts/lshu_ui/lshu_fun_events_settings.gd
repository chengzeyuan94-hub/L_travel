extends RefCounted
## 设置页的「L叔的趣味事件」开关和它的子开关「耳听八方」（Carlos 2026-09-27 接受趣味事件设计 §7：扩展包默认关，
## 耳听八方单独一个子开关、默认关）。打开后陆、海两堆各加 7–8 张新事件卡（data/expansions/lshu_fun_events/）；
## 耳听八方打开后两堆再各加 1 张。子开关只在主开关打开时生效。
## 和对局时长一样存在本机 settings.cfg 的 [fun_events] 段，只有正式入口读写；测试与预览一律用默认（都关），不碰玩家的设置。

const MatchSettings := preload("res://scripts/lshu_ui/lshu_match_settings.gd")

static var enabled := false
static var sound_quiz := false
static var _loaded := false


static func load_if_real(tree: SceneTree) -> void:
	if _loaded or not MatchSettings.is_real_game(tree):
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(MatchSettings.settings_path()) != OK:
		return
	enabled = bool(cfg.get_value("fun_events", "enabled", false))
	sound_quiz = bool(cfg.get_value("fun_events", "sound_quiz", false))


static func save_if_real(tree: SceneTree) -> void:
	if not MatchSettings.is_real_game(tree):
		return
	var cfg := ConfigFile.new()
	cfg.load(MatchSettings.settings_path())
	cfg.set_value("fun_events", "enabled", enabled)
	cfg.set_value("fun_events", "sound_quiz", sound_quiz)
	DirAccess.make_dir_recursive_absolute(MatchSettings.Progress.dir_path())
	cfg.save(MatchSettings.settings_path())


## 开局用的扩展包选项（ExpansionLoader 的形状；主开关关着 = 空字典 = 原版）
static func options() -> Dictionary:
	return ExpansionLoader.fun_events_options(enabled, sound_quiz)


## 测试之间复位（不读写磁盘）
static func reset_for_tests() -> void:
	enabled = false
	sound_quiz = false
	_loaded = false
