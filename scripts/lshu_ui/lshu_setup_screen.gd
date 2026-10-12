extends "res://scripts/ui/player_setup_screen.gd"
## 「旅行L叔」风格的商旅设置页（概念图 docs/design/shanhe-luren/ui-concepts-lshu-20260925/03_setup.png、
## docs/design/shanhe-luren/setup-lshu-20260926/）。一台电脑 2–4 个座位轮流玩：1 位真人对 1–3 个电脑小伙伴，
## 或 2–4 位真人（可再加电脑）。
## 继承原设置页（scripts/ui/player_setup_screen.gd，另一个会话在维护）：信号、节点名、测试约定一律不动，
## 原来那些带名字的节点挪进新排版、换上 L叔 的皮；原 1v1 的「你的名字 / 颜色 / 对手难度」改成座位列表。
## 排版：设计分辨率 1920×1080，整页放在按 k = min(宽/1920, 高/1080) 缩放的 Stage 里，超宽屏左右居中。
##   左边 L叔 拿着地图 + 对话泡泡（跟着你的操作换话）；右边挎包面板「出发前准备」：
##   左栏「和谁一起玩？」：「和电脑玩 / 和朋友玩」两个快捷键 + 2–4 行座位（座位号 = 行动顺序）。
##     每行：头像（座位颜色圈）、名字（可改）、真人 / 电脑、颜色（点开调色盘，别人用着的颜色会和他交换）、
##     起始城市小签（点一下右栏就看这一位）、电脑的难度（7 岁 / 12 岁 / 16 岁）、请下车 ×；最后一行「再加一位旅伴」。
##   右栏「启程情报」：选中那一位的起始城市明信片、起始资源、起始交通；底下「出发！」「返回」。
## 座位规则：最少 2 位、最多 4 位，至少 1 位真人，颜色互不相同；改名字 / 颜色 / 真人电脑 / 难度都不重新发牌
## （SetupSystem.update_prepared_seats），加减座位用同一个种子重新准备（SetupSystem.reprepare_with_seats），
## 留下来的座位起始城市不变。旧测试用的接口（%NameEdit、_select_color、Difficulty_* 按钮）照旧可用：
## %NameEdit 就是第 1 行的名字框，_select_color 改第 1 行（或正打开调色盘的那一行）的颜色，
## Difficulty_* 改第一个电脑（或最近点过难度的那个电脑）的难度。
## 自制地图（地图工坊「导入地图」装进来的，docs/design/map-editor-20260930/DESIGN.md 3.7）：只有装过地图时，右上角「趣味事件」
## 小签的正上方才多一个「地图」小签；没装过时这一页和原来逐像素相同、开局选项就是原来的趣味事件选项。

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const LSkin := preload("res://scripts/lshu_ui/lshu_skin.gd")
const W := preload("res://scripts/lshu_ui/lshu_widgets.gd")
const Seats := preload("res://scripts/lshu_ui/lshu_seats.gd")
const MatchSettings := preload("res://scripts/lshu_ui/lshu_match_settings.gd")
const FunEvents := preload("res://scripts/lshu_ui/lshu_fun_events_settings.gd")
const MatchSave := preload("res://scripts/lshu_ui/lshu_match_save.gd")
const Pad := preload("res://scripts/pad/pad_input.gd")
## 「L叔的趣味事件」小签上的图标：事件卡的地图卡背
const FUN_EVENTS_ICON := "res://assets/game/ui/event_cards_v2/event_card_back_map_768x1024.png"
const SETUP_DIR := "res://assets/game/ui/lshu_setup/"
const HOME_DIR := "res://assets/game/ui/lshu_home/"
const STAGE := Vector2(1920, 1080)
const INK_BROWN := Color("#4A2C1A")
const INK_SOFT := Color("#7A5A44")
const CREAM_BOX := Color("#FBF1DE")
const GOLD := Color("#E89419")

const MIN_SEATS := 2
const MAX_SEATS := 4
## 座位列表（Stage 坐标）：第 i 行在 ROW_POS + (0, i × (行高 + 间距))
const ROW_POS := Vector2(668, 262)
const ROW_SIZE := Vector2(700, 150)
const ROW_GAP := 10.0
const NAME_PX := 28
const NAME_PX_MIN := 22

## 泡泡里 L叔 说的话
const KID_LINES: Dictionary = {
	"qingzhuang": "他才 7 岁，\n让着点他～",
	"shanhai": "12 岁的小伙伴，\n会算账了哦！",
	"wanli": "16 岁的老手，\n可要小心啦！",
}
const DEFAULT_LINE := "出发前，\n先看看咱们的商队！"
const LINES: Dictionary = {
	"add": "又来一位旅伴，\n热闹啦！",
	"remove": "好，这一局\n少一位旅伴～",
	"to_ai": "电脑小伙伴\n来一起玩！",
	"to_human": "真人玩家，\n轮到时自己掷骰哦！",
	"need_human": "至少要留一位\n真人玩家哦！",
	"full": "最多四位旅伴，\n坐满啦！",
	"vs_ai": "和电脑小伙伴\n比一比！",
	"friends": "叫上朋友，\n一台电脑轮流玩！",
	"fun_on": "趣味事件打开啦，\n路上会有新鲜事！",
	"fun_off": "好，这一局只用\n原版的事件卡。",
	"quiz_on": "耳听八方：\n竖起耳朵听一听！",
	"quiz_off": "耳听八方\n这局先不玩～",
}

## 「地图」小签（自制地图，docs/design/map-editor-20260930/DESIGN.md 3.7）：L叔 说的话
const MAP_LINES: Dictionary = {
	"new": "新地图「%s」\n装好啦！",
	"new_not_counting": "新地图装好啦！\n用它赢了不算胜场哦",
	"swapped": "新地图「%s」\n换上啦！",
	"swapped_not_counting": "新地图换上啦！\n用它赢了不算胜场哦",
	"broken": "你装的地图有点问题，\n这局先用原版地图哦",
	"not_counting": "用这张图赢了\n不算胜场哦",
	"on": "这一局就用\n「%s」！",
	"off": "好，这一局用\n原版地图。",
}

## 本次运行内记住上次的座位（真人 / 电脑、名字、颜色、难度），回开场再进来还是这一桌
static var _remembered_seats: Array = []
## 这次启动里第一次打开设置页时，默认对手用「轻装启程 7 岁」（Carlos：1 对电脑按 7–10 岁小孩的水平；复检 NOV-11）。
## 规则层 AIDifficulty.DEFAULT 仍是山海独旅（正式测试基准不变）；玩家改过难度后照旧记住
static var _kid_default_applied := false

var _meta: Dictionary = {}
var _design: Control
var _stage: Control
var _lshu: TextureRect
var _bubble_text: Label
var _stamp_city: Label
var _epithet: Label
var _postcard: Control
var _owner_badge: Control
var _owner_name: Label
var _ring: Control
var _ring_index := 0
var _go_shine: ShaderMaterial
var _skinned := false
var _idle_tweens: Array[Tween] = []
## Stage 坐标下屏幕实际能看到的横向范围（超宽屏时比 0..1920 宽），云和花瓣按它换行、出生
var _visible_x := Vector2(0, 1920)

## 座位：[{type: "LOCAL_HUMAN"|"AI", name, custom, color_id, ai_difficulty, ai_name}]，下标 = 座位号 - 1 = 行动顺序
var _seats: Array = []
var _rows: Array = []
var _add_slot: Button
var _preset_ai: Button
var _preset_friends: Button
var _palette: Control
var _palette_catcher: Control
## 右栏「启程情报」在看哪个座位
var _focus_seat := 0
## 调色盘在给哪个座位选颜色（没打开时是第 1 行，原测试的 _select_color 就是改它）
var _color_seat := 0
## 旧的三档难度按钮改哪个电脑座位（-1 = 第一个电脑）
var _difficulty_seat := -1
var _syncing := false
## 「L叔的趣味事件」：右栏标题行的小签 + 点开的小面板（主开关、子开关「耳听八方」）
var _fun_chip: Button
var _fun_check: TextureRect
var _fun_panel: Panel
var _fun_catcher: Control
var _fun_main_buttons: Dictionary = {}    # "off" / "on" -> Button
var _fun_quiz_buttons: Dictionary = {}
var _fun_quiz_note: Label
## 「地图」小签（自制地图）：只有装过地图（maps/installed.json 在）时才建，没装过时这三个一直是 null
var _map_chip: Button
var _map_panel: Panel
var _map_catcher: Control
## CustomMapSettings.refresh() 这次进页面（或切回窗口）时的结果；没进正式入口、没装地图时是 {} 或 installed=false
var _map_state: Dictionary = {}
## 最近一次成功的准备带着地图选项（= 这一局用的是自制地图）
var _map_in_use := false
## 最近一次拼开局选项时带了地图（准备失败时据此决定要不要按原版再准备一次，R4）
var _map_options_had_map := false
## R4 降级重试的次数（测试看；日志里每次一行 CUSTOM_MAP_MERGE_FAILED）
var map_merge_failures := 0
## R4 降级过的那份地图（按 sha 记，这次进程里一直有效）：CustomMapSettings.refresh 对它照样回 ok（只是 options 不再给），
## 再进出发页时要据此照样亮小红点、「<地图名>」按钮点不了、L叔 说明原因
static var _broken_map_sha := ""


func _ready() -> void:
	if not _kid_default_applied:
		_kid_default_applied = true
		_remembered_difficulty = AIDifficulty.EASY
	super()
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var p: String = SETUP_DIR + "setup.json"
	if FileAccess.file_exists(p):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if d is Dictionary:
			_meta = d
	if _seats.is_empty():
		_seats = _default_seats()
	_lshu_build()
	_skinned = true
	_restyle_colors()
	_restyle_transport()
	resized.connect(_lshu_layout)
	visibility_changed.connect(_on_visible_changed)
	_sync_rows()
	_lshu_layout()
	add_child(preload("res://scripts/pad/pad_setup.gd").new())   # 手柄（scripts/pad/pad_setup.gd）


func _tex(name: String) -> Texture2D:
	for dir: String in [SETUP_DIR, HOME_DIR]:
		for ext: String in [".png", ".jpg"]:
			var path: String = dir + name + ext
			if ResourceLoader.exists(path):
				return load(path) as Texture2D
	return LSkin.tex(name)


func _nine_of(name: String) -> Array:
	return ((_meta.get(name, {}) as Dictionary).get("nine", [0, 0, 0, 0])) as Array


# ------------------------------------------------------------------ 座位模型
func _new_seat(type: String, color_id: String) -> Dictionary:
	var s := {"type": type, "name": "", "custom": false, "color_id": color_id, "ai_difficulty": _remembered_difficulty, "ai_name": ""}
	if type == "AI":
		s["ai_name"] = _free_ai_name(-1)
	return s


## 默认一桌：1 位真人 + 1 个电脑小伙伴（和原来的 1v1 一样）
func _default_seats() -> Array:
	var out: Array = [_new_seat("LOCAL_HUMAN", _color_id_at(0))]
	_seats = out
	out.append(_new_seat("AI", _color_id_at(1)))
	return out


func _color_id_at(i: int) -> String:
	if i >= 0 and i < _colors.size():
		return String((_colors[i] as Dictionary).get("id", ""))
	return ["red", "blue", "green", "yellow"][clampi(i, 0, 3)]


func _color_index(id: String) -> int:
	for i in _colors.size():
		if String((_colors[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


func _seat_with_color(id: String) -> int:
	for i in _seats.size():
		if String(_seats[i]["color_id"]) == id:
			return i
	return -1


func _free_color() -> String:
	for c in _colors:
		var id := String((c as Dictionary).get("id", ""))
		if _seat_with_color(id) < 0:
			return id
	return _color_id_at(0)


func _free_ai_name(except_seat: int) -> String:
	var used := {}
	for i in _seats.size():
		if i != except_seat and String(_seats[i]["type"]) == "AI":
			used[String(_seats[i]["ai_name"])] = true
	for n: String in Seats.AI_NAMES:
		if not used.has(n):
			return n
	return Seats.AI_NAMES[0]


func _human_count() -> int:
	var n := 0
	for s in _seats:
		if String(s["type"]) == "LOCAL_HUMAN":
			n += 1
	return n


func _first_human() -> int:
	for i in _seats.size():
		if String(_seats[i]["type"]) == "LOCAL_HUMAN":
			return i
	return 0


func _first_ai() -> int:
	for i in _seats.size():
		if String(_seats[i]["type"]) == "AI":
			return i
	return -1


func _default_name(i: int) -> String:
	var s: Dictionary = _seats[i]
	if String(s["type"]) == "AI":
		return String(s["ai_name"]) if String(s["ai_name"]) != "" else Seats.default_ai_name(i)
	return Seats.default_human_name(i)


func _seat_name(i: int) -> String:
	var s: Dictionary = _seats[i]
	if bool(s["custom"]) and String(s["name"]).strip_edges() != "":
		return String(s["name"]).strip_edges().left(MAX_NAME_LEN)
	return _default_name(i)


## 颜色要在规则四色里且互不相同：不合规的换成空着的颜色
func _sanitize_colors() -> void:
	var seen := {}
	for i in _seats.size():
		var id := String(_seats[i]["color_id"])
		if _color_index(id) < 0 or seen.has(id):
			id = ""
			for c in _colors:
				var cid := String((c as Dictionary).get("id", ""))
				if not seen.has(cid) and _seat_with_color_after(cid, i) < 0:
					id = cid
					break
			_seats[i]["color_id"] = id
		seen[id] = true


func _seat_with_color_after(id: String, i: int) -> int:
	for j in range(i + 1, _seats.size()):
		if String(_seats[j]["color_id"]) == id:
			return j
	return -1


func _valid_seats(seats: Array) -> bool:
	if seats.size() < MIN_SEATS or seats.size() > MAX_SEATS:
		return false
	for s in seats:
		if not s is Dictionary or not (s as Dictionary).has("type"):
			return false
		if String(s["type"]) == "LOCAL_HUMAN":
			return true
	return false


func _remember() -> void:
	if _session_mode == "FORMAL":
		_remembered_seats = _seats.duplicate(true)


## 忘掉记住的座位（下次进来回到默认的 1 真人 + 1 电脑）；测试之间用
static func forget_remembered_seats() -> void:
	_remembered_seats = []


## 座位 → 开局配置（SetupSystem / GameScreen / 再来一局都用它）
func collect_configs() -> Array:
	if _colors.is_empty() or _seats.is_empty():
		return []
	_sanitize_colors()
	var out: Array = []
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		var c := {"display_name": _seat_name(i), "color_id": String(s["color_id"]), "controller_type": String(s["type"])}
		if String(s["type"]) == "AI":
			c["ai_difficulty"] = AIDifficulty.normalize(String(s["ai_difficulty"]))
		out.append(c)
	return out


## 空名字回到这一座位的默认名（第 1 行原来回退「玩家」，现在按座位号是「玩家一」）
func _normalized_name() -> String:
	return _seat_name(0) if not _seats.is_empty() else super()


# ------------------------------------------------------------------ 原逻辑的钩子
func begin_setup(seed: int = -1, session_mode: String = "FORMAL") -> Dictionary:
	_close_palette()
	_close_fun_panel()
	_close_map_panel()
	if session_mode == "FORMAL" and _valid_seats(_remembered_seats):
		_seats = _remembered_seats.duplicate(true)
	else:
		_seats = _default_seats()
	_focus_seat = _first_human()
	_color_seat = 0
	_difficulty_seat = -1
	# 自制地图：进出发页先读一次装着的地图（入口门、整份校验都在 CustomMapSettings 里），开局选项要用它
	_map_refresh(session_mode)
	_map_options_had_map = false
	# 上一次进页面留下的「用着地图」先清掉：基类在 super 里就会刷「出发！」下面那行，不能拿上一次的状态写「不算胜场」
	_map_in_use = false
	var result: Dictionary = super(seed, session_mode)
	if session_mode == "FORMAL" and not bool(result.get("success", false)) and _map_options_had_map:
		# R4：带着地图准备失败（合并出错、缓存里没有这份地图）→ 这份地图这次不用了，按原版再准备一次；
		# 第二次成功时基类会把 _prepared 等补齐、把第一次的报错清掉，原因改由地图小签和 L叔 说
		_map_merge_failed("begin_setup", String(result.get("message", "")))
		result = super(seed, session_mode)
	_map_in_use = bool(result.get("success", false)) and _map_options_had_map
	if _skinned:
		_refresh_caption()
		_refresh_ai_card()
		_sync_rows()
		_refresh_difficulty_buttons()
		_refresh_fun_events()
		_refresh_map_chip()
		if bool(result.get("success", false)) and _map_installed():
			_refresh_start_enabled()   # 「出发！」下面那行不算胜场的提示，要等 _map_in_use 定下来再写（R28）；降级回原版时清掉
		_set_line(DEFAULT_LINE)
		_say_map_on_enter(false)
	return result


## 开局用的扩展包选项：正式十六城才读「L叔的趣味事件」开关（本机设置，默认关）和装着的自制地图；七城演示永远是原版
func _expansion_options() -> Variant:
	if _session_mode != "FORMAL":
		return null
	FunEvents.load_if_real(get_tree())
	return _combined_options()


## 趣味事件选项 ∪ 自制地图选项（CustomMapSettings.options：选了「原版」、地图有问题、降级过都是 {}）。
## 没装过地图时就是 FunEvents.options() 本身（原版不变，R2）
func _combined_options() -> Dictionary:
	var out: Dictionary = FunEvents.options()
	_map_options_had_map = false
	if _map_usable() and get_tree() != null:
		var m: Variant = CustomMapSettings.options(get_tree())
		if m is Dictionary and (m as Dictionary).has(CustomMapSchema.OPTION_ID):
			out.merge(m as Dictionary, true)
			_map_options_had_map = true
	return out


## 名字 / 颜色 / 真人电脑 / 难度改了：整桌座位一起写回已准备的开局（不重新发牌）
func _apply_display_config() -> bool:
	if not _prepared or _colors.is_empty():
		return false
	var configs := collect_configs()
	var result := SetupSystem.update_prepared_seats(configs)
	if bool(result.get("success", false)):
		_last_configs = configs.duplicate(true)
		var prep: Variant = result.get("prepare")
		if prep is Dictionary:
			_prepare_result = (prep as Dictionary).duplicate(true)
		_remember()
		return true
	show_start_error(String(result.get("message", "无法更新商旅信息。")))
	return false


## 加减座位：同一个种子重新准备，留下的座位起始城市不变
func _reprepare() -> bool:
	if not _prepared:
		return false
	var configs := collect_configs()
	var result := SetupSystem.reprepare_with_seats(configs)
	if not bool(result.get("success", false)):
		result = _reprepare_seats_without_map(configs, result)
	if not bool(result.get("success", false)):
		if GameState.phase != GameState.Phase.SETUP_TRANSPORT:
			_prepared = false
		show_start_error(String(result.get("message", "无法调整座位。")))
		return false
	_prepare_result = result.duplicate(true)
	_last_configs = configs.duplicate(true)
	_allowed_transports = (result.get("allowed_transports", [GameData.Transport.CAMEL]) as Array).duplicate()
	_starting_transport_locked = bool(result.get("starting_transport_locked", false))
	_selected_transport = int(result.get("starting_transport", GameData.Transport.CAMEL))
	_remember()
	_after_seats_changed()
	_refresh_start_enabled()
	return true


## 加减座位时带着地图重新准备失败（R4 的第五处）：这份地图这次不用了，同一个种子、新的这桌座位、去掉地图的选项再准备一次，
## 「出发！」不因为地图被挡住。不是地图的问题（没带地图、已经不在准备阶段）时原样把失败交回去
func _reprepare_seats_without_map(configs: Array, failed: Dictionary) -> Dictionary:
	if GameState.phase != GameState.Phase.SETUP_TRANSPORT or _session_mode != "FORMAL":
		return failed
	var opts: Dictionary = ExpansionLoader.options_of(GameState.content).duplicate(true)
	if not opts.has(CustomMapSchema.OPTION_ID):
		return failed
	_map_merge_failed("seats", String(failed.get("message", "")))
	opts.erase(CustomMapSchema.OPTION_ID)
	var r := SetupSystem.prepare_new_game(GameState.content, configs, GameState.rng_seed, GameState.session_mode, opts)
	if not bool(r.get("success", false)):
		return r
	_map_in_use = false
	_map_options_had_map = false
	_refresh_map_chip()
	_set_line(String(MAP_LINES["broken"]))
	return r


func _after_seats_changed() -> void:
	_focus_seat = clampi(_focus_seat, 0, _seats.size() - 1)
	_refresh_caption()
	_refresh_ai_card()
	_sync_rows()
	_refresh_prepare_preview()
	_refresh_difficulty_buttons()


## 顶上的说明条：「丝路十六城 · 正式规则 · 真人 1 · 电脑 1」；用自制地图时城数按这一局算（「丝路十八城」），后面写地图名。
## 说明条在 TopBar（x=36、宽 520）里居中、字长了向两边长；接上地图名再开趣味事件就会伸出屏幕左边，把「丝路十八城」切掉。
## 所以用地图时改成只向右长，地图名最多 5 个字，右端到了「出发前准备」皮牌（x≈900）就再少一个字，实在放不下就不写（小签上有）。
## 不用地图时字和生长方向都和原来一样
const CAPTION_LEFT := 36.0
const CAPTION_MAX_RIGHT := 880.0
const CAPTION_MAP_CHARS := 5


func _refresh_caption() -> void:
	if _session_mode != "FORMAL":
		return
	var humans := _human_count()
	var head := "丝路%s城 · 正式规则 · 真人 %d · 电脑 %d" % [_cn_number(_city_count()), humans, _seats.size() - humans]
	var fun := ""
	if FunEvents.enabled:
		fun = " · 趣味事件" + ("+耳听八方" if FunEvents.sound_quiz else "")
	var cap := $TopBar/ContentCaption as Label
	if not _map_in_use:
		if cap.grow_horizontal != Control.GROW_DIRECTION_BOTH:
			cap.grow_horizontal = Control.GROW_DIRECTION_BOTH
		cap.text = head + fun
		return
	cap.grow_horizontal = Control.GROW_DIRECTION_END
	var full := _map_name()
	var keep := mini(full.length(), CAPTION_MAP_CHARS)
	while keep > 0:
		cap.text = head + " · " + (full if keep >= full.length() else full.left(keep) + "…") + fun
		if not _skinned or cap.get_minimum_size().x <= CAPTION_MAX_RIGHT - CAPTION_LEFT:
			return
		keep -= 1
	cap.text = head + fun


## 这一局有几座城：原版 16；自制地图每多一座新城 +1（准备好之前按基础包算）
func _city_count() -> int:
	var cities: Variant = GameState.content.get("cities") if _prepared and not GameState.content.is_empty() else _content.get("cities")
	return (cities as Dictionary).size() if cities is Dictionary and not (cities as Dictionary).is_empty() else 16


## 城数用中文数字（十六、十八、二十）
static func _cn_number(n: int) -> String:
	const DIGITS := ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
	if n <= 0 or n >= 100:
		return str(n)
	if n < 10:
		return DIGITS[n]
	var tens := floori(n / 10.0)
	return ("" if tens == 1 else DIGITS[tens]) + "十" + DIGITS[n % 10]


## 原来写「电脑商旅：X 色 · 自动避让」的那一行，现在说轮流的顺序
func _refresh_ai_card() -> void:
	if _seats.is_empty():
		%AIColorLabel.text = ""
		return
	var order: Array[String] = []
	for i in _seats.size():
		order.append(str(i + 1))
	%AIColorLabel.text = "一台电脑轮流玩：按 %s 的顺序走" % "→".join(order)


func _on_name_changed(text: String) -> void:
	if not _syncing and not _seats.is_empty():
		_set_name_from_edit(0, (%NameEdit as LineEdit).text)
	super(text)
	_refresh_owner()
	_refresh_difficulty_hint()


func _on_seat_name_changed(text: String, i: int) -> void:
	if _syncing or i >= _seats.size():
		return
	_set_name_from_edit(i, text)
	if _prepared:
		_apply_display_config()
	_refresh_start_enabled()
	_refresh_owner()
	_refresh_difficulty_hint()


func _set_name_from_edit(i: int, text: String) -> void:
	var t := text.strip_edges().left(MAX_NAME_LEN)
	var custom := t != "" and t != _default_name(i)
	_seats[i]["custom"] = custom
	_seats[i]["name"] = t if custom else ""


## 名字框清空后离开：填回这一座位的默认名
func _on_name_focus_out(i: int) -> void:
	if i >= _rows.size() or i >= _seats.size():
		return
	var e: LineEdit = _rows[i]["edit"]
	if e.text.strip_edges() == "":
		e.text = _seat_name(i)
	_fit_name_edit(e)


## 名字框（286 宽、字区 212）：12 个字的长名字先缩字号（28 → 22），还放不下就从名字开头显示，
## 不再只露出后半截（复检 UIRES-8：以前回车 / 点别处后停在末尾，看到的是「安小旅人一号阿」）
func _fit_name_edit(e: LineEdit) -> void:
	var font := e.get_theme_font("font")
	var sb := e.get_theme_stylebox("normal")
	var room := e.size.x - (sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT) if sb != null else 74.0) - 4.0
	var px := NAME_PX
	while px > NAME_PX_MIN and font != null and room > 0.0 and font.get_string_size(e.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > room:
		px -= 1
	e.add_theme_font_size_override("font_size", px)
	e.tooltip_text = e.text
	if not e.has_focus():
		e.caret_column = 0


func _build_color_buttons() -> void:
	# 原版每次进页面都会把颜色按钮全部释放重建，眼镜框先挪出来免得跟着被释放
	if _ring != null and _stage != null and _ring.get_parent() != _stage:
		_ring.reparent(_stage, false)
		_ring.visible = false
	super()
	if _skinned:
		_restyle_colors()


func _refresh_color_buttons() -> void:
	var seat := clampi(_color_seat, 0, maxi(_seats.size() - 1, 0))
	var sel: int = _selected_color_index
	if not _seats.is_empty():
		sel = maxi(_color_index(String(_seats[seat]["color_id"])), 0)
	_ring_index = sel
	var configs := collect_configs()
	for i in _color_buttons.size():
		var b := _color_buttons[i]
		b.button_pressed = i == sel
		var owner := b.get_node_or_null("Owner") as Control
		if owner != null and not configs.is_empty():
			var j := _seat_with_color(_color_id_at(i))
			owner.visible = j >= 0 and j != seat
			if owner.visible:
				owner.call("set_seat", configs[j], configs)
	if _skinned:
		_place_ring(true)


## 选颜色：给正在选颜色的座位换上；这个颜色别人用着的话，两人交换
func _select_color(index: int) -> void:
	if index < 0 or index >= _colors.size() or _seats.is_empty():
		return
	var seat := clampi(_color_seat, 0, _seats.size() - 1)
	var id := _color_id_at(index)
	var other := _seat_with_color(id)
	if other >= 0 and other != seat:
		_seats[other]["color_id"] = String(_seats[seat]["color_id"])
	_seats[seat]["color_id"] = id
	_selected_color_index = maxi(_color_index(String(_seats[0]["color_id"])), 0)
	_close_palette()
	if _prepared:
		_apply_display_config()
	if _skinned:
		_sync_rows()
		_refresh_owner()
		_set_line("%s色的商队，\n真精神！" % String((_colors[index] as Dictionary).get("display_name", "")))
		_pop(_rows[seat]["badge"], 1.12)
		if other >= 0 and other != seat:
			_pop(_rows[other]["badge"], 1.12)


func _difficulty_target() -> int:
	if _difficulty_seat >= 0 and _difficulty_seat < _seats.size() and String(_seats[_difficulty_seat]["type"]) == "AI":
		return _difficulty_seat
	return _first_ai()


func _refresh_difficulty_buttons() -> void:
	var t := _difficulty_target()
	if t >= 0:
		_difficulty = AIDifficulty.normalize(String(_seats[t]["ai_difficulty"]))
	super()
	_refresh_difficulty_hint()


## 座位列表下面那行「小沙枣：7 岁 · …」：改名字时也跟着换（复检 UIRES-8：以前改了电脑的名字，这一行还写旧名字）
func _refresh_difficulty_hint() -> void:
	if not _skinned:
		return
	var t := _difficulty_target()
	var hint := find_child("DifficultyHint", true, false) as Label
	if hint != null:
		hint.visible = t >= 0
		if t >= 0:
			var d := AIDifficulty.normalize(String(_seats[t]["ai_difficulty"]))
			hint.text = "%s：%s · %s" % [_seat_name(t), AIDifficulty.age_text(d), String(AIDifficulty.INFO[d]["blurb"])]


## 选难度：改「当前的」电脑座位（行里点过的那个；没点过就是第一个电脑），只改它一个
func _select_difficulty(id: String) -> void:
	_difficulty = AIDifficulty.normalize(id)
	_remembered_difficulty = _difficulty
	var seat := _difficulty_target()
	if seat >= 0:
		_seats[seat]["ai_difficulty"] = _difficulty
		if _prepared:
			var r := SetupSystem.update_prepared_seat_difficulty(seat, _difficulty)
			if bool(r.get("success", false)):
				_last_configs = collect_configs().duplicate(true)
				_remember()
	_refresh_difficulty_buttons()
	if _skinned:
		_sync_rows()
		if seat == _focus_seat:
			_refresh_owner()
		_set_line(String(KID_LINES.get(_difficulty, DEFAULT_LINE)))
		if seat >= 0:
			_pop(_rows[seat]["badge"], 1.12)


func _pick_seat_difficulty(i: int, id: String) -> void:
	if i >= _seats.size() or String(_seats[i]["type"]) != "AI":
		return
	_difficulty_seat = i
	_select_difficulty(id)


func _build_transport_button(button: Button, _sheet: Texture2D, title: String) -> void:
	# 原版用像素骆驼 / 商船，这里换成 L叔 风格的小图标
	button.text = ""
	var icon := TextureRect.new()
	icon.name = "PieceIcon"
	icon.texture = _tex("icon_camel" if title == "骆驼" else "icon_ship")
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 12
	icon.offset_right = -12
	icon.offset_top = 8
	icon.offset_bottom = -30
	button.add_child(icon)
	var label := Kit.label(title, 22, INK_BROWN, "body", 800)
	label.name = "TransportName"
	label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	label.offset_top = -32
	label.offset_bottom = -4
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(label)


func _refresh_transport_styles() -> void:
	if not _skinned:
		super()
		return
	for b: Button in [%CamelButton, %ShipButton]:
		var empty := StyleBoxEmpty.new()
		for state: String in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
			b.add_theme_stylebox_override(state, empty)
		var card := b.get_node_or_null("TransportCard") as Control
		if card != null:
			card.queue_redraw()


## 右栏看的是选中的座位：把那一位的起始城市 / 资源 / 交通临时当成「开局预览」交给原逻辑画，画完换回来
## （get_prepare_result() 仍是整局的预览，顶层是第一位真人）
func _refresh_prepare_preview() -> void:
	var saved: Dictionary = _prepare_result
	var view := _focus_view()
	if not view.is_empty():
		_prepare_result = view
		_allowed_transports = (view.get("allowed_transports", [GameData.Transport.CAMEL]) as Array).duplicate()
		_starting_transport_locked = bool(view.get("starting_transport_locked", false))
		if _starting_transport_locked:
			_selected_transport = int(view.get("starting_transport", GameData.Transport.CAMEL))
	super()
	if _skinned:
		_restyle_grant_row()
		%TransportHint.text = %TransportHint.text.replace("城市卡指定起始交通：", "城市卡指定：")
		_refresh_city_extras()
		_refresh_owner()
	_prepare_result = saved


func _focus_view() -> Dictionary:
	var seats: Array = _prepare_result.get("seats", [])
	if seats.is_empty():
		return {}
	var i := clampi(_focus_seat, 0, seats.size() - 1)
	if _session_mode != "FORMAL":
		i = clampi(_first_human(), 0, seats.size() - 1)  # 演示模式只有真人能选交通，右栏固定看真人
	return (seats[i] as Dictionary).duplicate(true)


func _restyle_grant_row() -> void:
	# 起始资源：原来那行是「起始资源：」+ 小图标 + ×N；标题我放在行外面了，行里换成 L叔 风格的 3D 小图标
	var grant: Array = _prepare_result.get("starting_grant", [])
	var gi: int = 0
	for c in %StartingGrantRow.get_children():
		if c is Label and (c as Label).text.ends_with("："):
			(c as Label).visible = false
		elif c is TextureRect:
			var t := c as TextureRect
			t.custom_minimum_size = Vector2(60, 60)
			if gi < grant.size():
				var entry: Dictionary = grant[gi]
				var id: String = "silver" if String(entry.get("resource_kind", "")) == "SILVER" else String(entry.get("resource_id", ""))
				var icon3d: Texture2D = Kit.icon(id)
				if icon3d != null:
					# 3D 小图标四周留白很多，只取中间一块，东西才看得清
					var crop := AtlasTexture.new()
					crop.atlas = icon3d
					crop.region = Rect2(Vector2(icon3d.get_width(), icon3d.get_height()) * 0.14, Vector2(icon3d.get_width(), icon3d.get_height()) * 0.72)
					t.texture = crop
				t.tooltip_text = _good_name(entry)
			gi += 1
		elif c is Label:
			var l := c as Label
			l.add_theme_font_override("font", Kit.font("body", 900))
			l.add_theme_font_size_override("font_size", 32)
			l.add_theme_color_override("font_color", INK_BROWN)
			l.add_theme_constant_override("outline_size", 0)
			l.add_theme_constant_override("shadow_offset_y", 0)


func _good_name(entry: Dictionary) -> String:
	if String(entry.get("resource_kind", "")) == "SILVER":
		return "白银 ×%d" % int(entry.get("quantity", 0))
	var content: Dictionary = GameState.content if not GameState.content.is_empty() else _content
	var goods: Variant = content.get("goods", {})
	var id: String = String(entry.get("resource_id", ""))
	if goods is Dictionary and (goods as Dictionary).has(id):
		return "%s ×%d" % [String(((goods as Dictionary)[id] as Dictionary).get("name", id)), int(entry.get("quantity", 0))]
	return id


func show_start_error(message: String) -> void:
	super(message)
	if _skinned:
		_style_gate()
		_refresh_go_state()


## 原版每次刷新「能不能出发」都会把出错提示改回旧的 11 号小字，这里再套一次新样式，出发按钮也跟着亮 / 暗
func _refresh_start_enabled() -> void:
	super()
	if _skinned:
		# 用的是不算胜场的自制地图、又没有别的报错：「出发！」下面这一行写明（R28；只是提示，不挡出发）
		if (%GateLabel as Label).text == "" and _map_in_use and not _map_counts() and _session_mode == "FORMAL":
			(%GateLabel as Label).text = MAP_NOT_COUNTING_GATE
		_style_gate()
		_refresh_go_state()


func _on_start_pressed() -> void:
	if _overwrite_needs_confirm():
		return
	_close_palette()
	_close_fun_panel()
	_close_map_panel()
	super()
	if _skinned:
		_refresh_go_state()


## 安卓（触屏防误触开着）：有没下完的存档时，「出发！」第一下只提醒会盖掉它；停一下（离上一下 ≥ 0.4 秒）、
## 3 秒内再点才开新局（开局第一次自动存档就把「加载存档」那一局盖掉了，以前两下就没了：安卓压力测试 TS-8）。
## 一直连点不算。桌面上和以前一样（点一下就开）
const OVERWRITE_ARM_MS := 3000
const OVERWRITE_CALM_MS := 400
const OVERWRITE_LINE := "会盖掉没下完的那一局哦，\n真要开新的就再点一次！"
var _overwrite_armed_at := -100000
var _overwrite_last := -100000


func _overwrite_needs_confirm() -> bool:
	if not Pad.guards_on(self) or %StartButton.disabled or not MatchSave.exists():
		return false
	if Pad.canceled_press(self):
		return true
	var now := Time.get_ticks_msec()
	var armed := now - _overwrite_armed_at < OVERWRITE_ARM_MS
	var calm := now - _overwrite_last >= OVERWRITE_CALM_MS
	_overwrite_last = now
	if armed and calm:
		_overwrite_armed_at = -100000
		return false
	_overwrite_armed_at = now
	_set_line(OVERWRITE_LINE)
	var go := %StartButton as Control
	go.pivot_offset = go.size * 0.5
	var tw := go.create_tween()
	for a: float in [-5.0, 4.0, -3.0, 0.0]:
		tw.tween_property(go, "rotation", deg_to_rad(a), 0.06)
	print("LSHU_SETUP_OVERWRITE_ARMED ", JSON.stringify({"ms": now}))
	return true


## 出发按钮不能按时：字和小花一起变暗，扫光停下
func _refresh_go_state() -> void:
	var start := %StartButton as Button
	var dim: bool = start.disabled
	for n: String in ["GoLabel", "GoFlower"]:
		var c := start.get_node_or_null(n) as CanvasItem
		if c != null:
			c.modulate = Color(0.78, 0.74, 0.7, 0.75) if dim else Color.WHITE
	if dim and _go_shine != null:
		_go_shine.set_shader_parameter("shine", -1.0)


# ------------------------------------------------------------------ 座位操作
func _set_seat_type(i: int, type: String) -> void:
	if _session_mode != "FORMAL" or i >= _seats.size():
		return
	var s: Dictionary = _seats[i]
	if String(s["type"]) == type:
		return
	if type == "AI" and _human_count() <= 1:
		_refuse(_rows[i]["ai"], "need_human")
		return
	s["type"] = type
	s["custom"] = false
	s["name"] = ""
	if type == "AI":
		s["ai_name"] = _free_ai_name(i)
		s["ai_difficulty"] = _remembered_difficulty
	_apply_display_config()
	_after_seats_changed()
	_pop(_rows[i]["badge"], 1.15)
	_set_line(String(LINES["to_ai" if type == "AI" else "to_human"]))


func _add_seat() -> void:
	if _session_mode != "FORMAL":
		return
	if _seats.size() >= MAX_SEATS:
		_set_line(String(LINES["full"]))
		return
	var type: String = String(_seats[_seats.size() - 1]["type"]) if not _seats.is_empty() else "AI"
	_seats.append(_new_seat(type, _free_color()))
	var failures_before := map_merge_failures
	if not _reprepare():
		_seats.pop_back()
		_sync_rows()
		return
	var row := _rows[_seats.size() - 1]["row"] as Control
	row.pivot_offset = row.size * 0.5
	row.scale = Vector2(0.8, 0.8)
	row.modulate.a = 0.0
	var tw := row.create_tween().set_parallel(true)
	tw.tween_property(row, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(row, "modulate:a", 1.0, 0.18)
	if map_merge_failures == failures_before:   # 地图这次没铺开（R4）时 L叔 先说地图的事
		_set_line(String(LINES["add"]))


func _remove_seat(i: int) -> void:
	if _session_mode != "FORMAL" or i >= _seats.size() or _seats.size() <= MIN_SEATS:
		return
	if String(_seats[i]["type"]) == "LOCAL_HUMAN" and _human_count() <= 1:
		_refuse(_rows[i]["remove"], "need_human")
		return
	var removed: Dictionary = _seats[i]
	var old_focus := _focus_seat
	_seats.remove_at(i)
	if _focus_seat == i:
		_focus_seat = _first_human()
	elif _focus_seat > i:
		_focus_seat -= 1
	if _difficulty_seat == i:
		_difficulty_seat = -1
	elif _difficulty_seat > i:
		_difficulty_seat -= 1
	var failures_before := map_merge_failures
	if not _reprepare():
		_seats.insert(i, removed)
		_focus_seat = old_focus
		_sync_rows()
		return
	if map_merge_failures == failures_before:
		_set_line(String(LINES["remove"]))


## 快捷键：「和电脑玩」= 留第一位真人，其余都换成电脑；「和朋友玩」= 至少两位真人（把第一个电脑换成真人，没有电脑就加一位真人）
func _apply_preset(kind: String) -> void:
	if _session_mode != "FORMAL" or _seats.is_empty():
		return
	var grow := false
	if kind == "ai":
		var keep := _first_human()
		for i in _seats.size():
			var s: Dictionary = _seats[i]
			if i != keep and String(s["type"]) == "LOCAL_HUMAN":
				s["type"] = "AI"
				s["custom"] = false
				s["name"] = ""
				s["ai_name"] = _free_ai_name(i)
				s["ai_difficulty"] = _remembered_difficulty
		_set_line(String(LINES["vs_ai"]))
	else:
		if _human_count() < 2:
			var ai := -1
			for i in _seats.size():
				if String(_seats[i]["type"]) == "AI" and i != _first_human():
					ai = i
					break
			if ai >= 0:
				_seats[ai]["type"] = "LOCAL_HUMAN"
				_seats[ai]["custom"] = false
				_seats[ai]["name"] = ""
			elif _seats.size() < MAX_SEATS:
				_seats.append(_new_seat("LOCAL_HUMAN", _free_color()))
				grow = true
		_set_line(String(LINES["friends"]))
	if grow:
		_reprepare()
	else:
		_apply_display_config()
		_after_seats_changed()
	for r in _rows:
		if (r["row"] as Control).visible:
			_pop(r["badge"], 1.1)


func _focus(i: int) -> void:
	if i < 0 or i >= _seats.size() or i == _focus_seat or _session_mode != "FORMAL":
		return
	_focus_seat = i
	_refresh_prepare_preview()
	_sync_rows()
	if _postcard != null:
		_pop(_postcard, 1.04)
	var seats: Array = _prepare_result.get("seats", [])
	if i < seats.size():
		_set_line("%s从%s出发，\n一路顺风！" % [_seat_name(i), String((seats[i] as Dictionary).get("home_city_name", ""))])


func _on_row_input(event: InputEvent, i: int) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_focus(i)


func _refuse(node: Control, key: String) -> void:
	_set_line(String(LINES.get(key, DEFAULT_LINE)))
	if node == null:
		return
	node.pivot_offset = node.size * 0.5
	var tw := node.create_tween()
	for a: float in [-7.0, 6.0, -4.0, 0.0]:
		tw.tween_property(node, "rotation", deg_to_rad(a), 0.06)


# ------------------------------------------------------------------ 调色盘（原来的 %ColorRow 四个圆章）
func _open_palette(i: int) -> void:
	if i >= _seats.size() or _palette == null:
		return
	_color_seat = i
	_refresh_color_buttons()
	var r: Dictionary = _rows[i]
	var cb := r["color"] as Control
	var anchor: Vector2 = (r["row"] as Control).position + cb.position
	var pos := Vector2(anchor.x + cb.size.x - _palette.size.x + 18, anchor.y + cb.size.y + 12)
	if pos.y + _palette.size.y > 1020.0:
		pos.y = anchor.y - _palette.size.y - 12
	_palette.position = pos
	_palette_catcher.visible = true
	_palette.visible = true
	_stage.move_child(_palette_catcher, _stage.get_child_count() - 1)
	_stage.move_child(_palette, _stage.get_child_count() - 1)
	_palette.pivot_offset = Vector2(_palette.size.x - 50, 0 if pos.y > anchor.y else _palette.size.y)
	_palette.scale = Vector2(0.85, 0.85)
	_palette.modulate.a = 0.0
	var tw := _palette.create_tween().set_parallel(true)
	tw.tween_property(_palette, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_palette, "modulate:a", 1.0, 0.12)
	_place_ring.call_deferred(false)


func _close_palette() -> void:
	if _palette == null:
		_color_seat = 0
		return
	_palette.visible = false
	_palette_catcher.visible = false
	_color_seat = 0
	_refresh_color_buttons()


# ------------------------------------------------------------------ 「L叔的趣味事件」开关（2026-09-27）
## 右栏标题行「启程情报」右边的小签：糖果按钮（开着是驼黄、关着是奶油色，开着时右边打个勾），
## 点开一个挎包小面板：「新事件卡 关 / 开」「耳听八方 关 / 开」（耳听八方只在主开关开着时能点），底下「好」收起。
## 切开关时用同一个种子重新准备（SetupSystem.set_prepared_expansion_options）：谁从哪座城出发不变，只换事件牌堆。
## 这是出发前的设置、不是对局里的决定，点一下就切，可以随时切回来；选择记在本机设置里（正式入口才写盘）。
func _build_fun_events() -> void:
	_fun_chip = LSkin.candy_button("cream")
	_fun_chip.name = "FunEventsChip"
	_fun_chip.position = Vector2(1650, 180)
	_fun_chip.size = Vector2(200, 64)
	_fun_chip.custom_minimum_size = _fun_chip.size
	_fun_chip.tooltip_text = "L叔的趣味事件：在原版事件卡里多加几张好玩的新卡"
	_stage.add_child(_fun_chip)
	var content := Control.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.size = _fun_chip.size
	_fun_chip.add_child(content)
	(_fun_chip as LSkin.CandyButton).content = content
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = load(FUN_EVENTS_ICON) as Texture2D if ResourceLoader.exists(FUN_EVENTS_ICON) else null
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.position = Vector2(14, 8)
	icon.size = Vector2(34, 46)
	icon.rotation = deg_to_rad(-6.0)
	content.add_child(icon)
	(_fun_chip as LSkin.CandyButton).wiggle_target = icon
	var l := Kit.label("趣味事件", 25, INK_BROWN, "body", 900)
	l.name = "Title"
	l.position = Vector2(54, 0)
	l.size = Vector2(110, 58)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(l)
	_fun_check = _image("icon_check", Vector2(160, 16), Vector2(28, 28), content)
	_fun_check.name = "Check"
	_fun_chip.pressed.connect(_open_fun_panel)

	# 点空白处收起的透明挡板 + 小面板
	_fun_catcher = Control.new()
	_fun_catcher.name = "FunEventsCatcher"
	_fun_catcher.position = Vector2(-4000, -4000)
	_fun_catcher.size = Vector2(12000, 12000)
	_fun_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_fun_catcher.visible = false
	_fun_catcher.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_close_fun_panel())
	_stage.add_child(_fun_catcher)
	_fun_panel = Panel.new()
	_fun_panel.name = "FunEventsPanel"
	_fun_panel.position = Vector2(1386, 256)
	_fun_panel.size = Vector2(470, 436)
	_fun_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_fun_panel.visible = false
	_fun_panel.add_theme_stylebox_override("panel", Kit.satchel_box(30, 5, 0))
	var stitch := W.StitchLayer.new()
	stitch.inset = 10.0
	stitch.radius = 20.0
	stitch.color = Color("#C9A77C")
	_fun_panel.add_child(stitch)
	_stage.add_child(_fun_panel)
	var title := Kit.label("L叔的趣味事件", 30, INK_BROWN, "body", 900)
	title.name = "PanelTitle"
	title.position = Vector2(30, 22)
	title.size = Vector2(410, 44)
	_fun_panel.add_child(title)
	var desc := Kit.label("陆地、海洋两堆各多几张新卡：全桌掷骰、猜眼镜、篝火聊天……原版 36 张一张不少。", 20, INK_SOFT, "body", 700)
	desc.name = "PanelNote"
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(410, 0)
	_fun_panel.add_child(desc)
	desc.position = Vector2(30, 66)
	desc.size = Vector2(410, 96)
	var row1 := Kit.label("新事件卡", 26, INK_BROWN, "body", 800)
	row1.position = Vector2(30, 180)
	row1.size = Vector2(200, 52)
	row1.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fun_panel.add_child(row1)
	_fun_main_buttons = _fun_toggle_pair("FunMain", Vector2(250, 174), func(on: bool) -> void: _set_fun_events(on, FunEvents.sound_quiz and on))
	var row2 := Kit.label("耳听八方", 26, INK_BROWN, "body", 800)
	row2.position = Vector2(30, 256)
	row2.size = Vector2(200, 40)
	_fun_panel.add_child(row2)
	_fun_quiz_note = Kit.label("听声猜物，要开着声音", 19, INK_SOFT, "body", 700)
	_fun_quiz_note.name = "QuizNote"
	_fun_quiz_note.position = Vector2(30, 294)
	_fun_quiz_note.size = Vector2(220, 30)
	_fun_panel.add_child(_fun_quiz_note)
	_fun_quiz_buttons = _fun_toggle_pair("FunQuiz", Vector2(250, 256), func(on: bool) -> void: _set_fun_events(FunEvents.enabled, on))
	var ok := Button.new()
	ok.name = "FunEventsOk"
	ok.text = "好"
	Kit.style_button(ok, "cream", 64, 28)
	ok.position = Vector2(165, 348)
	ok.size = Vector2(140, 64)
	ok.custom_minimum_size = ok.size
	ok.pressed.connect(_close_fun_panel)
	_fun_panel.add_child(ok)
	_refresh_fun_events()


## 一对「关 / 开」按钮（和真人 / 电脑同一套糖果按钮，选中的是驼黄色）
func _fun_toggle_pair(prefix: String, pos: Vector2, on_pick: Callable) -> Dictionary:
	var out := {}
	for pair: Array in [["off", "关", 0.0], ["on", "开", 96.0]]:
		var b := Button.new()
		b.name = "%s_%s" % [prefix, String(pair[0])]
		b.text = String(pair[1])
		Kit.style_button(b, "cream", 64, 26)
		b.position = pos + Vector2(float(pair[2]), 0)
		b.size = Vector2(88, 64)
		b.custom_minimum_size = b.size
		var value: bool = String(pair[0]) == "on"
		b.pressed.connect(func() -> void: on_pick.call(value))
		_fun_panel.add_child(b)
		out[String(pair[0])] = b
	return out


func _open_fun_panel() -> void:
	if _fun_panel == null or _session_mode != "FORMAL":
		return
	_close_palette()
	_refresh_fun_events()
	_fun_catcher.visible = true
	_fun_panel.visible = true
	_stage.move_child(_fun_catcher, _stage.get_child_count() - 1)
	_stage.move_child(_fun_panel, _stage.get_child_count() - 1)
	_fun_panel.pivot_offset = Vector2(_fun_panel.size.x - 100, 0)
	_fun_panel.scale = Vector2(0.85, 0.85)
	_fun_panel.modulate.a = 0.0
	var tw := _fun_panel.create_tween().set_parallel(true)
	tw.tween_property(_fun_panel, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_fun_panel, "modulate:a", 1.0, 0.12)


func _close_fun_panel() -> void:
	if _fun_panel == null:
		return
	_fun_panel.visible = false
	_fun_catcher.visible = false


## 切开关：先改设置，再用同一个种子重新准备；准备失败（扩展包读不到）就退回原来的选择并报错。
## 重新准备用的是「趣味事件 ∪ 自制地图」的选项（以前只传趣味事件，切一下开关就把地图选项冲掉了）
func _set_fun_events(main: bool, quiz: bool) -> void:
	var was := [FunEvents.enabled, FunEvents.sound_quiz]
	if was == [main, quiz]:
		return
	FunEvents.enabled = main
	FunEvents.sound_quiz = quiz and main
	var failures_before := map_merge_failures
	if _prepared and _session_mode == "FORMAL":
		var r := _reprepare_expansions("fun_events")
		if not bool(r.get("success", false)):
			FunEvents.enabled = bool(was[0])
			FunEvents.sound_quiz = bool(was[1])
			show_start_error(String(r.get("message", "趣味事件包读不到。")))
			_refresh_fun_events()
			_refresh_map_chip()
			return
		_prepare_result = r.duplicate(true)
		_last_configs = collect_configs().duplicate(true)
	FunEvents.save_if_real(get_tree())
	_refresh_fun_events()
	_refresh_caption()
	if map_merge_failures != failures_before:
		# 地图这次没铺开、已经按原版重新准备（R4）：小签亮红点，L叔 先说地图的事
		_refresh_map_chip()
		_refresh_start_enabled()
		_set_line(String(MAP_LINES["broken"]))
		return
	if main != bool(was[0]):
		_set_line(String(LINES["fun_on" if main else "fun_off"]))
		_pop(_fun_chip, 1.1)
	else:
		_set_line(String(LINES["quiz_on" if quiz else "quiz_off"]))


func _refresh_fun_events() -> void:
	if _fun_chip == null:
		return
	_fun_chip.visible = _session_mode == "FORMAL"
	_set_candy_color(_fun_chip, "ochre" if FunEvents.enabled else "cream")
	_fun_check.visible = FunEvents.enabled
	_fun_chip.tooltip_text = (
		"L叔的趣味事件：已打开%s · 点一下改" % ("（含耳听八方）" if FunEvents.sound_quiz else "")
		if FunEvents.enabled
		else "L叔的趣味事件：没打开（原版事件卡）· 点一下改"
	)
	for key: String in _fun_main_buttons:
		var b := _fun_main_buttons[key] as Button
		Kit.style_button(b, "primary" if (key == "on") == FunEvents.enabled else "cream", 64, 26)
		b.custom_minimum_size = Vector2(88, 64)
	for key: String in _fun_quiz_buttons:
		var b := _fun_quiz_buttons[key] as Button
		Kit.style_button(b, "primary" if (key == "on") == FunEvents.sound_quiz else "cream", 64, 26)
		b.custom_minimum_size = Vector2(88, 64)
		b.disabled = not FunEvents.enabled
	if _fun_quiz_note != null:
		_fun_quiz_note.text = "听声猜物，要开着声音" if FunEvents.enabled else "先打开新事件卡"


# ------------------------------------------------------------------ 「地图」小签：自制地图（2026-10-01，WP5）
## 地图工坊里点「导入地图」装进来的地图（docs/design/map-editor-20260930/DESIGN.md 3.7、R4、R28）。
## 只有 maps/installed.json 在时才建小签：位置在「趣味事件」小签正上方 (1650, 108)，同一套糖果按钮；
## 用着自制地图时是驼黄色、写地图名（超过 3 个字截断加「…」）并打勾，不算胜场的图第二行写红字「不算胜场」；
## 用原版时写「原版地图」；地图有问题时也写「原版地图」，外加一个小红点。点开挎包小面板：缩略图、多了哪几座城、
## 算不算胜场、银库增减，底下「原版地图」「<地图名>」两个按钮各占一行，点一下就切（出发前的设置，和趣味事件开关同一条规则），
## 用同一个种子重新准备（SetupSystem.set_prepared_expansion_options），起点城、资源、交通都不变；选择由 CustomMapSettings 记进本机设置。
## 「出发！」永远不因为地图被挡住：地图有问题就用原版；带着地图准备失败（R4）就 mark_broken、按原版再准备一次。
const MAP_CHIP_POS := Vector2(1650, 108)
const MAP_CHIP_SIZE := Vector2(200, 64)
const MAP_PANEL_POS := Vector2(1386, 184)
const MAP_PANEL_W := 470.0
## 小签上的地图名：名字标签从 x=54 起，勾在 x=160（照趣味事件小签）；最多留 3 个字，量出来右端还压到勾就再少一个字
const MAP_NAME_CHARS := 3
const MAP_LABEL_X := 54.0
const MAP_CHECK_X := 160.0
const MAP_RED := Color("#CD483A")
const MAP_NOT_COUNTING_GATE := "这张自制地图还在试玩，赢了不算胜场"
const MAP_MERGE_FAILED_KID := "这张地图这次没能铺开，这局先用原版地图。请在地图工坊里打开看看。"
## L叔 泡泡里的地图名最多这么多字（泡泡太宽会伸到挎包面板底下）
const MAP_LINE_NAME_CHARS := 6


func _map_installed() -> bool:
	return bool(_map_state.get("installed", false))


## 装着的地图能不能用（校验过了、这次进程里没降级过）
func _map_usable() -> bool:
	return _map_installed() and bool(_map_state.get("ok", false))


func _map_counts() -> bool:
	return bool(_map_state.get("counts_win", true))


func _map_name() -> String:
	var n := String(_map_state.get("name", "")).strip_edges()
	return n if n != "" else "自制地图"


func _map_short_name(chars: int) -> String:
	var n := _map_name()
	return n if n.length() <= chars else n.left(chars) + "…"


## 进页面 / 切回窗口时读一次装着的地图（入口门关着、七城演示、没有场景树时都当没装）
func _map_refresh(session_mode: String) -> void:
	_map_state = {}
	if session_mode != "FORMAL" or get_tree() == null:
		return
	var r: Variant = CustomMapSettings.refresh(get_tree())
	if r is Dictionary:
		_map_state = (r as Dictionary).duplicate(true)
	# 这次进程里降级过的同一份图：还当有问题（和降级那一刻的小签、面板、L叔 一样）
	var sha := String(_map_state.get("sha256", ""))
	if bool(_map_state.get("ok", false)) and sha != "" and sha == _broken_map_sha:
		_mark_map_state_broken()


## R4：带着地图准备失败 → 日志、mark_broken（这次进程里这份地图不再给选项），小签改成「原版地图 + 红点」
func _map_merge_failed(where: String, message: String) -> void:
	map_merge_failures += 1
	var sha := String(_map_state.get("sha256", ""))
	print("CUSTOM_MAP_MERGE_FAILED ", JSON.stringify({"where": where, "sha256": sha, "message": message}))
	CustomMapSettings.mark_broken("CUSTOM_MAP_MERGE_FAILED")
	if sha != "":
		_broken_map_sha = sha
	_mark_map_state_broken()


func _mark_map_state_broken() -> void:
	_map_state["ok"] = false
	_map_state["code"] = "CUSTOM_MAP_MERGE_FAILED"
	_map_state["kid_text"] = MAP_MERGE_FAILED_KID


## 忘掉降级过的地图（测试之间用；正式游戏里只有重开进程才忘）
static func forget_broken_map() -> void:
	_broken_map_sha = ""


## 切地图 / 切趣味事件 / 切回窗口：用同一个种子、按「趣味事件 ∪ 地图」的选项重新准备；
## 带着地图失败时 mark_broken，再只用趣味事件的选项准备一次（R4）
func _reprepare_expansions(where: String) -> Dictionary:
	var r := SetupSystem.set_prepared_expansion_options(_combined_options())
	if not bool(r.get("success", false)) and _map_options_had_map:
		_map_merge_failed(where, String(r.get("message", "")))
		_map_options_had_map = false
		r = SetupSystem.set_prepared_expansion_options(FunEvents.options())
	if bool(r.get("success", false)):
		_map_in_use = _map_options_had_map
	return r


## 小签里点「原版地图」/「<地图名>」：点一下就切，谁从哪座城出发不变
func _set_map_use(on: bool) -> void:
	if _session_mode != "FORMAL" or not _map_installed() or get_tree() == null:
		return
	if on and not _map_usable():
		_set_line(String(MAP_LINES["broken"]))
		return
	if on == _map_in_use:
		return
	var failures_before := map_merge_failures
	CustomMapSettings.set_use(get_tree(), on)
	if _prepared:
		var r := _reprepare_expansions("map_chip")
		if not bool(r.get("success", false)):
			show_start_error(String(r.get("message", "地图换不过来。")))
			_refresh_map_chip()
			return
		_prepare_result = r.duplicate(true)
		_last_configs = collect_configs().duplicate(true)
		if on and not _map_in_use and map_merge_failures == failures_before:
			# 规则层这次没给出地图选项（没有降级，也没铺上）：当作这张图这次用不了，别让孩子以为选上了
			_map_state["ok"] = false
			_map_state["kid_text"] = MAP_MERGE_FAILED_KID
	_refresh_map_chip()
	_refresh_caption()
	_refresh_start_enabled()
	if map_merge_failures != failures_before or (on and not _map_usable()):
		_set_line(String(MAP_LINES["broken"]))
	elif _map_in_use:
		_set_line(String(MAP_LINES["on"]) % _map_short_name(MAP_LINE_NAME_CHARS) if _map_counts() else String(MAP_LINES["not_counting"]))
	else:
		_set_line(String(MAP_LINES["off"]))
	_pop(_map_chip, 1.1)


## 进出发页（或切回窗口换上新图）时 L叔 说的话：新装的图、地图有问题、不算胜场（每次进页面都说，R28）
func _say_map_on_enter(swapped: bool) -> void:
	if _session_mode != "FORMAL" or not _map_installed():
		return
	if not _map_usable():
		_set_line(String(MAP_LINES["broken"]))
		return
	if not _map_in_use:
		return
	var short := _map_short_name(MAP_LINE_NAME_CHARS)
	var fresh := swapped or bool(_map_state.get("is_new", false))
	var key := "not_counting"
	if fresh:
		key = ("swapped" if swapped else "new") + ("" if _map_counts() else "_not_counting")
	elif _map_counts():
		return
	var line := String(MAP_LINES[key])
	_set_line(line % short if line.contains("%s") else line)


## 从地图工坊切回来（NOTIFICATION_APPLICATION_FOCUS_IN）：只读 installed.json 外壳的 installed_at；变了就照进页面的流程重读，
## 换上新图、用同一个种子重新准备（起点不变），L叔 说「新地图换上啦」（DESIGN 3.1）。入口门关着时 CustomMapSettings 不读文件
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_on_app_focus_in()


func _on_app_focus_in() -> void:
	if _session_mode != "FORMAL" or not _prepared or _launching or not _skinned or not is_visible_in_tree() or get_tree() == null:
		return
	if not CustomMapSettings.installed_changed(get_tree()):
		return
	_close_map_panel()
	var was_in_use := _map_in_use
	_map_refresh(_session_mode)
	var failures_before := map_merge_failures
	var r := _reprepare_expansions("focus_in")
	if not bool(r.get("success", false)):
		show_start_error(String(r.get("message", "地图换不过来。")))
		_refresh_map_chip()
		return
	_prepare_result = r.duplicate(true)
	_last_configs = collect_configs().duplicate(true)
	_refresh_map_chip()
	_refresh_caption()
	_refresh_start_enabled()
	print("CUSTOM_MAP_FOCUS_IN ", JSON.stringify({"installed": _map_installed(), "ok": _map_usable(), "in_use": _map_in_use, "was_in_use": was_in_use}))
	if map_merge_failures != failures_before:
		_set_line(String(MAP_LINES["broken"]))
	elif _map_in_use:
		_say_map_on_enter(true)
		_pop(_map_chip, 1.1)
	elif _map_installed():
		_say_map_on_enter(false)
	elif was_in_use:
		_set_line(String(MAP_LINES["off"]))


## 小签按当前状态刷新（不在时按需建出来；没装地图、七城演示时藏起来）
func _refresh_map_chip() -> void:
	var show: bool = _skinned and _session_mode == "FORMAL" and _map_installed()
	if not show:
		if _map_chip != null:
			_map_chip.visible = false
		_close_map_panel()
		return
	if _map_chip == null:
		_build_map_chip()
	_map_chip.visible = true
	var content := _map_chip.get_node("Content") as Control
	var title := content.get_node("Title") as Label
	var name_l := content.get_node("Name") as Label
	var note := content.get_node("Note") as Label
	var check := content.get_node("Check") as CanvasItem
	var dot := content.get_node("Dot") as CanvasItem
	var two_lines: bool = _map_in_use and not _map_counts()
	_set_candy_color(_map_chip, "ochre" if _map_in_use else "cream")
	title.visible = not two_lines
	name_l.visible = two_lines
	note.visible = two_lines
	if _map_in_use:
		title.text = _fit_chip_name(title, _map_name())
		name_l.text = _fit_chip_name(name_l, _map_name())
	else:
		title.text = "原版地图"
	check.visible = _map_in_use
	dot.visible = not _map_usable()
	if not _map_usable():
		_map_chip.tooltip_text = "地图：%s · 点一下看看" % String(_map_state.get("kid_text", "装进来的地图有点问题，这局先用原版地图。"))
	elif _map_in_use:
		_map_chip.tooltip_text = "地图：%s%s · 点一下改" % [_map_name(), "" if _map_counts() else "（还在试玩，赢了不算胜场）"]
	else:
		_map_chip.tooltip_text = "地图：原版地图 · 装着「%s」，点一下改" % _map_name()
	if _map_panel != null and _map_panel.visible:
		_fill_map_panel()


## 小签上的地图名：超过 3 个字截断加「…」；按这个标签的字体量一下，右端到了勾（x=160）就再少一个字
func _fit_chip_name(l: Label, full: String) -> String:
	var text := full if full.length() <= MAP_NAME_CHARS else full.left(MAP_NAME_CHARS) + "…"
	var font := l.get_theme_font("font")
	var px := l.get_theme_font_size("font_size")
	var room := MAP_CHECK_X - MAP_LABEL_X - 2.0
	var keep := mini(full.length(), MAP_NAME_CHARS)
	while font != null and keep > 1 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > room:
		keep -= 1
		text = full.left(keep) + "…"
	return text


func _build_map_chip() -> void:
	_map_chip = LSkin.candy_button("cream")
	_map_chip.name = "MapChip"
	_map_chip.position = MAP_CHIP_POS
	_map_chip.size = MAP_CHIP_SIZE
	_map_chip.custom_minimum_size = MAP_CHIP_SIZE
	_stage.add_child(_map_chip)
	# 和「趣味事件」小签挨着画（在小标题皮条之上、调色盘和小面板之下）
	if _fun_chip != null and _fun_chip.get_parent() == _stage:
		_stage.move_child(_map_chip, _fun_chip.get_index() + 1)
	var content := Control.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.size = MAP_CHIP_SIZE
	_map_chip.add_child(content)
	(_map_chip as LSkin.CandyButton).content = content
	var icon := _image("icon_pin", Vector2(16, 10), Vector2(32, 42), content)
	icon.name = "Icon"
	icon.rotation = deg_to_rad(-6.0)
	(_map_chip as LSkin.CandyButton).wiggle_target = icon
	var title := Kit.label("原版地图", 25, INK_BROWN, "body", 900)
	title.name = "Title"
	title.position = Vector2(MAP_LABEL_X, 0)
	title.size = Vector2(110, 58)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(title)
	# 不算胜场时两行：上面地图名（22 px），下面红字「不算胜场」（20 px）
	var name_l := Kit.label("", 22, INK_BROWN, "body", 900)
	name_l.name = "Name"
	name_l.position = Vector2(MAP_LABEL_X, 3)
	name_l.size = Vector2(110, 30)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_l.visible = false
	content.add_child(name_l)
	var note := Kit.label("不算胜场", 20, MAP_RED, "body", 900)
	# 驼黄底上的红字偏暗：描一圈奶油色的边，孩子一眼看得清
	note.add_theme_color_override("font_outline_color", Color("#FFF8EC"))
	note.add_theme_constant_override("outline_size", 6)
	note.name = "Note"
	note.position = Vector2(MAP_LABEL_X, 30)
	note.size = Vector2(110, 26)
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	note.visible = false
	content.add_child(note)
	var check := _image("icon_check", Vector2(MAP_CHECK_X, 16), Vector2(28, 28), content)
	check.name = "Check"
	# 地图有问题：右上角一个小红点
	var dot := _RedDot.new()
	dot.name = "Dot"
	dot.position = Vector2(172, 2)
	dot.size = Vector2(22, 22)
	dot.visible = false
	content.add_child(dot)
	_map_chip.pressed.connect(_open_map_panel)

	_map_catcher = Control.new()
	_map_catcher.name = "MapCatcher"
	_map_catcher.position = Vector2(-4000, -4000)
	_map_catcher.size = Vector2(12000, 12000)
	_map_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_map_catcher.visible = false
	_map_catcher.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_close_map_panel())
	_stage.add_child(_map_catcher)
	_map_panel = Panel.new()
	_map_panel.name = "MapPanel"
	_map_panel.position = MAP_PANEL_POS
	_map_panel.size = Vector2(MAP_PANEL_W, 436)
	_map_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_map_panel.visible = false
	_map_panel.add_theme_stylebox_override("panel", Kit.satchel_box(30, 5, 0))
	_stage.add_child(_map_panel)


## 地图有问题时小签右上角的小红点（白边）
class _RedDot extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		draw_circle(c, r, Color("#FFF8EC"), true, -1.0, true)
		draw_circle(c, r - 3.0, Color("#CD483A"), true, -1.0, true)


func _open_map_panel() -> void:
	if _map_panel == null or _session_mode != "FORMAL":
		return
	_close_palette()
	_close_fun_panel()
	_fill_map_panel()
	_map_catcher.visible = true
	_map_panel.visible = true
	_stage.move_child(_map_catcher, _stage.get_child_count() - 1)
	_stage.move_child(_map_panel, _stage.get_child_count() - 1)
	_map_panel.pivot_offset = Vector2(_map_panel.size.x - 100, 0)
	_map_panel.scale = Vector2(0.85, 0.85)
	_map_panel.modulate.a = 0.0
	var tw := _map_panel.create_tween().set_parallel(true)
	tw.tween_property(_map_panel, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_map_panel, "modulate:a", 1.0, 0.12)
	if not _map_usable():
		_set_line(String(MAP_LINES["broken"]))


func _close_map_panel() -> void:
	if _map_panel == null:
		return
	_map_panel.visible = false
	_map_catcher.visible = false


## 小面板从上到下：标题、缩略图、多了哪几座城、算不算胜场、银库增减（或者地图的问题），两个按钮各占一行，「好」。高度按行数算
func _fill_map_panel() -> void:
	if _map_panel == null:
		return
	for c in _map_panel.get_children():
		_map_panel.remove_child(c)
		c.queue_free()
	var stitch := W.StitchLayer.new()
	stitch.inset = 10.0
	stitch.radius = 20.0
	stitch.color = Color("#C9A77C")
	_map_panel.add_child(stitch)
	var inner := MAP_PANEL_W - 60.0
	var title := Kit.label("用哪张地图？", 30, INK_BROWN, "body", 800)
	title.name = "PanelTitle"
	title.position = Vector2(30, 22)
	title.size = Vector2(inner, 44)
	_map_panel.add_child(title)
	var y := 74.0
	# 缩略图 320×180（工坊导入时写的 installed.png；读不到就留一块浅色底）
	var frame := PanelContainer.new()
	frame.name = "ThumbFrame"
	var fs := StyleBoxFlat.new()
	fs.bg_color = Color("#E8D9BF")
	fs.set_corner_radius_all(14)
	fs.corner_detail = 8
	fs.anti_aliasing = true
	frame.add_theme_stylebox_override("panel", fs)
	frame.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	frame.position = Vector2((MAP_PANEL_W - 320.0) * 0.5, y)
	frame.size = Vector2(320, 180)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_panel.add_child(frame)
	var thumb := TextureRect.new()
	thumb.name = "Thumb"
	thumb.texture = _map_thumb() if _map_usable() else null   # 地图有问题时缩略图可能是上一张的，不放
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(thumb)
	if thumb.texture == null:
		var pin := _image("icon_pin", Vector2(140, 62), Vector2(40, 52), frame)
		pin.name = "ThumbPin"
		pin.modulate = Color(1, 1, 1, 0.55)
	y += 180.0 + 12.0
	if _map_usable():
		var cities := _map_new_city_text()
		if cities != "":
			y = _panel_line("NewCities", cities, INK_SOFT, y)
		if _map_counts():
			y = _panel_line("WinNote", "赢了电脑算胜场", Color("#4F7A3A"), y)
			var wl := _map_panel.get_node("WinNote") as Label
			var ok_icon := _image("icon_check", Vector2(30 + wl.get_theme_font("font").get_string_size(wl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x + 8, wl.position.y + 3), Vector2(26, 26), _map_panel)
			ok_icon.name = "WinCheck"
		else:
			y = _panel_line("WinNote", MAP_NOT_COUNTING_GATE, MAP_RED, y)
		var bank := _map_bank_delta()
		if bank != 0:
			y = _panel_line("BankNote", "银库 %s%d" % ["−" if bank < 0 else "+", absi(bank)], INK_SOFT, y)
	else:
		y = _panel_line("Problem", String(_map_state.get("kid_text", "装进来的地图有点问题，这局先用原版地图。")), MAP_RED, y)
	y += 6.0
	# 两个糖果按钮各占一行：「原版地图」「<地图名>」；宽度按字实测（地图名最多 10 个字）
	for pair: Array in [["MapOriginal", "原版地图", false], ["MapCustom", _map_name(), true]]:
		var b := Button.new()
		b.name = String(pair[0])
		b.text = String(pair[1])
		var picked: bool = bool(pair[2]) == _map_in_use
		Kit.style_button(b, "primary" if picked else "cream", 64, 26)
		var tw: float = b.get_theme_font("font").get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
		b.size = Vector2(clampf(tw + 72.0, 220.0, inner), 64)
		b.custom_minimum_size = b.size
		b.position = Vector2((MAP_PANEL_W - b.size.x) * 0.5, y)
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var on: bool = bool(pair[2])
		b.pressed.connect(func() -> void: _set_map_use(on))
		if on and not _map_usable():
			b.disabled = true
			b.tooltip_text = "这张地图有点问题，这局用不了"
		_map_panel.add_child(b)
		y += 64.0 + 12.0
	var ok := Button.new()
	ok.name = "MapPanelOk"
	ok.text = "好"
	Kit.style_button(ok, "cream", 64, 28)
	ok.size = Vector2(140, 64)
	ok.custom_minimum_size = ok.size
	ok.position = Vector2((MAP_PANEL_W - ok.size.x) * 0.5, y + 4.0)
	ok.pressed.connect(_close_map_panel)
	_map_panel.add_child(ok)
	_map_panel.size = Vector2(MAP_PANEL_W, y + 4.0 + 64.0 + 26.0)


## 面板里的一行说明（20–22 px，放不下就折行），返回下一行的 y
func _panel_line(node_name: String, text: String, color: Color, y: float) -> float:
	var l := Kit.label(text, 22, color, "body", 800)
	l.name = node_name
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.position = Vector2(30, y)
	l.custom_minimum_size = Vector2(MAP_PANEL_W - 60.0, 0)
	l.size = Vector2(MAP_PANEL_W - 60.0, 0)
	_map_panel.add_child(l)
	var h := maxf(l.get_combined_minimum_size().y, 32.0)
	l.size = Vector2(MAP_PANEL_W - 60.0, h)
	return y + h + 4.0


## 「多了 2 座城：景德镇（东）、忽鲁谟斯（西）」。东西看 refresh 结果里的 new_cities（[{name, origin, side: "E" / "W"}]，WP1 的形状）；
## 没有这个键时退回 new_city_names（只有名字，就不标东西）。两处的元素都可以是字，也可以是 {name, side|slot}
func _map_new_city_text() -> String:
	var raw: Variant = _map_state.get("new_cities", [])
	if not raw is Array or (raw as Array).is_empty():
		raw = _map_state.get("new_city_names", [])
	if not raw is Array or (raw as Array).is_empty():
		return ""
	var names: Array[String] = []
	for v: Variant in raw:
		if v is Dictionary:
			var d := v as Dictionary
			var side := String(d.get("side", "")).to_upper()
			if side == "":
				side = String(d.get("slot", "")).left(1).to_upper()
			var tag := "（东）" if side == "E" else ("（西）" if side == "W" else "")
			names.append(String(d.get("name", "")) + tag)
		else:
			names.append(String(v))
	var line := "多了 %d 座城：%s" % [names.size(), "、".join(names)]
	# 一行放不下时从「：」后面折行，别把「（西）」单独挤到下一行
	var font := Kit.font("body", 800)
	if font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x > MAP_PANEL_W - 60.0:
		line = "多了 %d 座城：\n%s" % [names.size(), "、".join(names)]
	return line


## 用这张图时公共银库比原版多 / 少几两（k ≠ 0 才写；按这一局的座位数算，合并后的规则 vs 基础包）
func _map_bank_delta() -> int:
	if not _map_in_use or GameState.content.is_empty():
		return 0
	var base := ExpansionLoader.base_content_of(GameState.content)
	var n := GameState.players.size() if not GameState.players.is_empty() else _seats.size()
	return GameData.get_silver_supply_for(GameState.content, n) - GameData.get_silver_supply_for(base, n)


## 缩略图 installed.png（480×270，在玩家目录里，不是 res://）
func _map_thumb() -> Texture2D:
	var dir := CustomMapStore.maps_dir()
	if dir == "":
		return null
	var path := dir.path_join("installed.png")
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	return ImageTexture.create_from_image(img) if img != null and not img.is_empty() else null


# ------------------------------------------------------------------ 搭新排版
func _lshu_build() -> void:
	# 旧页面的纸、木条、红牌子都藏起来；带名字的功能节点挪到新排版里
	$ParchmentBackground.visible = false
	$BackgroundWash.visible = false
	$TopBar.texture = null
	$TopBar/TitlePlaque.visible = false

	_design = Control.new()
	_design.name = "LshuDesign"
	_design.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_design)
	move_child(_design, 0)
	var bg := TextureRect.new()
	bg.name = "MapBackground"
	bg.texture = _tex("bg_map")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_design.add_child(bg)
	_stage = Control.new()
	_stage.name = "Stage"
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.size = STAGE
	_design.add_child(_stage)

	_build_drift()
	_build_guide()
	_build_panel()

	# ContentCaption 必须留在 TopBar 下面（测试按路径找），TopBar 自己改成左上角的小标签，跟着 Stage 缩放
	$TopBar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	$TopBar.custom_minimum_size = Vector2.ZERO
	var cap := $TopBar/ContentCaption as Label
	cap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.add_theme_font_override("font", Kit.font("body", 700))
	cap.add_theme_font_size_override("font_size", 22)
	cap.add_theme_color_override("font_color", INK_BROWN)
	cap.add_theme_constant_override("outline_size", 0)
	cap.add_theme_constant_override("shadow_offset_y", 0)
	var pill := Kit.pill_box(22, 6)
	cap.add_theme_stylebox_override("normal", pill)
	move_child($TopBar, get_child_count() - 1)
	$BodyMargin.visible = false


func _box(pos: Vector2, sz: Vector2, parent: Control = null) -> Control:
	var c := Control.new()
	c.position = pos
	c.size = sz
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(parent if parent != null else _stage).add_child(c)
	return c


func _image(name: String, pos: Vector2, sz: Vector2, parent: Control = null) -> TextureRect:
	var t := TextureRect.new()
	t.name = name.to_pascal_case()
	t.texture = _tex(name)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.position = pos
	t.size = sz
	(parent if parent != null else _stage).add_child(t)
	return t


## 对局时长：20 / 25 / 30 / 40 / 50 / 60 / 90 / 120 分钟 / 不限时，拖动或点击滑条；选择记在本机设置里
func _build_match_length_slider() -> void:
	MatchSettings.load_if_real(get_tree())
	var slider := HSlider.new()
	slider.name = "MatchLengthSlider"
	slider.min_value = 0
	slider.max_value = MatchSettings.STEPS.size() - 1
	slider.step = 1
	slider.tick_count = MatchSettings.STEPS.size()
	slider.ticks_on_borders = true
	slider.focus_mode = Control.FOCUS_NONE
	slider.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	slider.tooltip_text = "对局时长：往右拖更长，拖到最右边不限时"
	var track := StyleBoxFlat.new()
	track.bg_color = CREAM_BOX
	track.border_color = Color("#C98E4E")
	track.set_border_width_all(3)
	track.set_corner_radius_all(12)
	track.content_margin_top = 7
	track.content_margin_bottom = 7
	slider.add_theme_stylebox_override("slider", track)
	var fill := StyleBoxFlat.new()
	fill.bg_color = GOLD
	fill.set_corner_radius_all(12)
	fill.content_margin_top = 7
	fill.content_margin_bottom = 7
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	var knob := _small_icon(Kit.icon("potato_bloom"), 40)
	if knob != null:
		slider.add_theme_icon_override("grabber", knob)
		slider.add_theme_icon_override("grabber_highlight", knob)
	slider.position = Vector2(1442, 868)
	slider.size = Vector2(250, 30)
	_stage.add_child(slider)
	var value_label := Kit.label("", 24, INK_BROWN, "body", 700)
	value_label.name = "MatchLengthLabel"
	value_label.position = Vector2(1702, 864)
	value_label.size = Vector2(150, 36)
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_stage.add_child(value_label)
	slider.value = MatchSettings.step_index()
	value_label.text = MatchSettings.text()
	slider.value_changed.connect(func(v: float) -> void:
		MatchSettings.minutes = MatchSettings.STEPS[clampi(int(v), 0, MatchSettings.STEPS.size() - 1)]
		value_label.text = MatchSettings.text()
		MatchSettings.save_if_real(get_tree()))


func _small_icon(t: Texture2D, px: int) -> Texture2D:
	if t == null:
		return null
	var img := t.get_image()
	if img == null:
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)


func _move(node: Control, parent: Control, pos: Vector2, sz: Vector2) -> void:
	node.reparent(parent, false)
	node.set_anchors_preset(Control.PRESET_TOP_LEFT)
	node.position = pos
	node.size = sz
	node.custom_minimum_size = Vector2(minf(node.custom_minimum_size.x, sz.x), minf(node.custom_minimum_size.y, sz.y))
	node.visible = true


func _nine_panel(name: String, pos: Vector2, sz: Vector2, parent: Control = null) -> Control:
	var p := LSkin.NinePanel.new()
	p.name = name.to_pascal_case()
	p.skin = _tex(name)
	var n: Array = _nine_of(name)
	p.nine = n if n != [0, 0, 0, 0] else LSkin.margins(name)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.position = pos
	p.size = sz
	(parent if parent != null else _stage).add_child(p)
	return p


func _section_tab(text: String, pos: Vector2, width: float) -> Control:
	# 小标题皮条：棕色皮革胶囊 + 奶油色缝线 + 一朵小土豆花
	var tab := Panel.new()
	tab.name = "Tab_" + text
	tab.position = pos
	tab.size = Vector2(width, 50)
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	st.bg_color = Color("#7A4A2A")
	st.set_corner_radius_all(25)
	st.corner_detail = 10
	st.border_color = Color("#5A3219")
	st.border_width_bottom = 4
	st.anti_aliasing = true
	st.shadow_color = Color(0.25, 0.12, 0.05, 0.3)
	st.shadow_size = 4
	st.shadow_offset = Vector2(0, 2)
	tab.add_theme_stylebox_override("panel", st)
	var stitch := W.StitchLayer.new()
	stitch.inset = 6.0
	stitch.radius = 18.0
	stitch.dash = 8.0
	stitch.gap = 6.0
	stitch.width = 2.0
	stitch.color = Color("#E9C99C", 0.8)
	tab.add_child(stitch)
	_stage.add_child(tab)
	var flower := _image("petal_2", Vector2(12, 6), Vector2(38, 38), tab)
	flower.name = "Flower"
	var l := Kit.label(text, 27, Color("#FFF1DC"), "body", 800)
	l.position = Vector2(56, 2)
	l.size = Vector2(width - 68, 44)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tab.add_child(l)
	return tab


func _inset(pos: Vector2, sz: Vector2) -> Panel:
	# 面板里浅色的小隔间：奶油底 + 虚线缝线
	var p := Panel.new()
	p.position = pos
	p.size = sz
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var s := StyleBoxFlat.new()
	s.bg_color = Color("#FFF7EA", 0.7)
	s.set_corner_radius_all(22)
	s.corner_detail = 10
	s.border_color = Color("#E4CFAE")
	s.set_border_width_all(2)
	s.anti_aliasing = true
	p.add_theme_stylebox_override("panel", s)
	var stitch := W.StitchLayer.new()
	stitch.inset = 8.0
	stitch.radius = 16.0
	stitch.color = Color("#D2B48C")
	stitch.width = 2.0
	p.add_child(stitch)
	_stage.add_child(p)
	return p


func _build_drift() -> void:
	# 背景上慢慢飘的云和花瓣（和开场同一套）
	for i in 2:
		var cloud := _image("cloud_%d" % (i + 2), Vector2(-200 + i * 900, 20 + i * 90), Vector2(420, 230) * (0.9 - i * 0.2))
		cloud.modulate = Color(1, 1, 1, 0.75)
		cloud.set_meta("speed", 9.0 + i * 5.0)
		cloud.name = "DriftCloud%d" % i
	var petals := CPUParticles2D.new()
	petals.name = "Petals"
	petals.texture = _tex("petal_1")
	petals.amount = 6
	petals.lifetime = 20.0
	petals.preprocess = 20.0
	petals.position = Vector2(-60, 540)
	petals.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	petals.emission_rect_extents = Vector2(40, 480)
	petals.direction = Vector2(1, 0.1)
	petals.spread = 12.0
	petals.gravity = Vector2(0, 6)
	petals.initial_velocity_min = 70.0
	petals.initial_velocity_max = 110.0
	petals.angle_max = 360.0
	petals.angular_velocity_min = -60.0
	petals.angular_velocity_max = 60.0
	petals.scale_amount_min = 0.2
	petals.scale_amount_max = 0.32
	_stage.add_child(petals)


func _build_guide() -> void:
	# 脚下的岩台（从背景切出来的），16:9 时和背景重合；别的比例时仍垫在 L叔 脚下
	var lm: Dictionary = _meta.get("ledge", {})
	var src: Array = lm.get("src_box", [0, 860, 720, 1152])
	var bg_scale: float = STAGE.x / 2048.0
	var ledge := _image("ledge", Vector2(float(src[0]), float(src[1])) * bg_scale, Vector2(float(src[2]) - float(src[0]), float(src[3]) - float(src[1])) * bg_scale)
	ledge.name = "Ledge"
	ledge.stretch_mode = TextureRect.STRETCH_SCALE
	if ledge.texture == null:
		push_warning("lshu_setup: 岩台贴图 ledge.png 没导入，超宽 / 4:3 时 L叔 脚下会没有岩台")
	_lshu = _image("lshu_map", Vector2(40, 318), Vector2(500, 750))
	_lshu.name = "LshuFigure"
	_lshu.pivot_offset = Vector2(250, 750)
	var bubble := LSkin.nine_panel("bubble", Vector4(34, 24, 36, 54))
	bubble.name = "GuideBubble"
	bubble.position = Vector2(96, 120)
	bubble.custom_minimum_size = Vector2(420, 0)
	_bubble_text = Kit.label(DEFAULT_LINE, 32, INK_BROWN, "body", 800)
	_bubble_text.name = "GuideText"
	_bubble_text.add_theme_constant_override("line_spacing", 4)
	bubble.add_child(_bubble_text)
	_stage.add_child(bubble)
	bubble.rotation = deg_to_rad(-3.0)


func _build_panel() -> void:
	# 挎包面板本体 + 标题皮牌
	var panel := _nine_panel("panel_satchel", Vector2(600, 110), Vector2(1280, 930))
	panel.name = "SatchelPanel"
	# 标题皮牌「出发前准备」（从定稿概念图上抠下来的，连字带牌）
	var title_tab := _image("title_tab", Vector2(900, 36), Vector2(620, 144))
	title_tab.name = "TitleTab"

	# ---- 左栏：和谁一起玩？快捷键 + 座位列表
	_section_tab("和谁一起玩？", Vector2(660, 196), 300)
	var seats_box := _inset(Vector2(660, 226), Vector2(716, 756))
	seats_box.name = "SeatsBox"
	_build_presets()
	for i in MAX_SEATS:
		_rows.append(_build_row(i))
	_build_add_slot()
	_move(%AIColorLabel, _stage, Vector2(676, 900), Vector2(684, 32))
	var order := %AIColorLabel as Label
	order.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_small(order, 22, INK_SOFT)
	var hint: Label = find_child("DifficultyHint", true, false)
	_move(hint, _stage, Vector2(676, 936), Vector2(684, 32))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_small(hint, 22, INK_BROWN)
	hint.clip_text = true
	hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	%OpponentLabel.visible = false
	var dcap := find_child("DifficultyCaption", true, false) as Control
	if dcap != null:
		dcap.visible = false
	_build_palette()

	# ---- 右栏：启程情报（选中的那一位）
	_section_tab("启程情报", Vector2(1388, 196), 250)
	_inset(Vector2(1394, 226), Vector2(456, 640))
	_build_postcard()
	var res_cap := Kit.label("起始资源", 26, INK_BROWN, "body", 800)
	res_cap.position = Vector2(1414, 596)
	_stage.add_child(res_cap)
	var res_box := _inset(Vector2(1534, 578), Vector2(298, 76))
	res_box.name = "GrantBox"
	_move(%StartingGrantRow, _stage, Vector2(1542, 584), Vector2(282, 64))
	(%StartingGrantRow as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	(%StartingGrantRow as HBoxContainer).add_theme_constant_override("separation", 8)
	var tr_cap := Kit.label("起始交通", 26, INK_BROWN, "body", 800)
	tr_cap.position = Vector2(1414, 700)
	_stage.add_child(tr_cap)
	_inset(Vector2(1534, 664), Vector2(298, 190))
	var trow: Control = %CamelButton.get_parent()
	_move(trow, _stage, Vector2(1548, 674), Vector2(270, 112))
	(trow as HBoxContainer).add_theme_constant_override("separation", 22)
	(trow as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	for b: Button in [%CamelButton, %ShipButton]:
		b.custom_minimum_size = Vector2(124, 112)
	_move(%TransportHint, _stage, Vector2(1542, 812), Vector2(282, 30))
	(%TransportHint as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_small(%TransportHint, 20, INK_SOFT)

	# ---- 底部：对局时长滑条（Carlos 2026-09-26：从 20 分钟起，最长不限时，自己拉进度条）、出发、返回、出错提示
	var clock := _image("icon_clock", Vector2(1400, 866), Vector2(34, 34))
	clock.name = "ClockIcon"
	_build_match_length_slider()
	_move(%StartButton, _stage, Vector2(1394, 910), Vector2(300, 104))
	var start := %StartButton as Button
	start.text = ""
	LSkin.skin_button(start, "ochre")
	var go := _image("txt_go", Vector2(80, 20), Vector2(196, 62), start)
	go.name = "GoLabel"
	var go_flower := _image("petal_2", Vector2(24, 24), Vector2(52, 52), start)
	go_flower.name = "GoFlower"
	_go_shine = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nuniform float shine = -1.0;\nvoid fragment() {\n\tvec4 c = COLOR;\n\tfloat lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));\n\tfloat band = smoothstep(0.08, 0.0, abs(UV.x - shine + (UV.y - 0.5) * 0.22));\n\tc.rgb += band * smoothstep(0.42, 0.68, lum) * 0.34;\n\tCOLOR = c;\n}\n"
	_go_shine.shader = sh
	(start.get_node("CandySkin") as Control).material = _go_shine
	_move(%BackButton, _stage, Vector2(1706, 918), Vector2(146, 88))
	var back := %BackButton as Button
	back.text = "返回"
	back.flat = false
	LSkin.skin_button(back, "cream")
	back.add_theme_font_override("font", Kit.font("body", 800))
	back.add_theme_font_size_override("font_size", 32)
	for key: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		back.add_theme_color_override(key, INK_BROWN)
	back.add_theme_constant_override("outline_size", 0)
	back.tooltip_text = "回到开场"
	_move(%GateLabel, _stage, Vector2(610, 1040), Vector2(1260, 36))
	_style_gate()

	# 原来的两张卡片留作左右两栏的外框（测试要求它们在屏幕里），本身不画东西
	for pair: Array in [[%HumanCard, Vector2(660, 196), Vector2(716, 786)], [%InfoCard, Vector2(1388, 196), Vector2(462, 820)]]:
		var card := pair[0] as PanelContainer
		_move(card, _stage, pair[1], pair[2])
		card.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for c in card.get_children():
			(c as CanvasItem).visible = false
		_stage.move_child(card, 1)
	# 右栏标题行：「L叔的趣味事件」小签（点开小面板切开关）
	_build_fun_events()
	# 小标题皮条压在隔间的上沿，要最后画；调色盘和趣味事件小面板永远在最上面
	for c in _stage.get_children():
		if String(c.name).begins_with("Tab_"):
			_stage.move_child(c, _stage.get_child_count() - 1)
	_stage.move_child(_fun_chip, _stage.get_child_count() - 1)
	_stage.move_child(_palette_catcher, _stage.get_child_count() - 1)
	_stage.move_child(_palette, _stage.get_child_count() - 1)
	_stage.move_child(_fun_catcher, _stage.get_child_count() - 1)
	_stage.move_child(_fun_panel, _stage.get_child_count() - 1)


# ------------------------------------------------------------------ 左栏零件
func _build_presets() -> void:
	_preset_ai = _preset_button("PresetVsAI", Vector2(978, 184), "kid_12", "和电脑玩")
	_preset_ai.tooltip_text = "1 位真人，和 1–3 个电脑小伙伴比"
	_preset_ai.pressed.connect(_apply_preset.bind("ai"))
	_preset_friends = _preset_button("PresetFriends", Vector2(1178, 184), "icon_people", "和朋友玩")
	_preset_friends.tooltip_text = "2–4 位真人轮流用一台电脑，还可以再加电脑"
	_preset_friends.pressed.connect(_apply_preset.bind("friends"))


func _preset_button(node_name: String, pos: Vector2, icon_name: String, title: String) -> Button:
	var b := LSkin.candy_button("cream")
	b.name = node_name
	b.position = pos
	b.size = Vector2(192, 68)
	b.custom_minimum_size = b.size
	_stage.add_child(b)
	var content := Control.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.size = b.size
	b.add_child(content)
	b.content = content
	var ic := TextureRect.new()
	ic.name = "Icon"
	ic.texture = _tex(icon_name)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ic.position = Vector2(16, 8)
	ic.size = Vector2(46, 46)
	content.add_child(ic)
	b.wiggle_target = ic
	var l := Kit.label(title, 27, INK_BROWN, "body", 900)
	l.name = "Title"
	l.position = Vector2(66, 0)
	l.size = Vector2(118, 60)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	content.add_child(l)
	return b


func _set_candy_color(b: Button, color: String) -> void:
	var cb := b as LSkin.CandyButton
	if cb == null:
		return
	cb.skin = LSkin.tex("btn_" + color)
	cb.skin_pressed = LSkin.tex("btn_%s_pressed" % color)
	cb.nine = LSkin.margins("btn_" + color)
	cb.queue_redraw()


func _build_row(i: int) -> Dictionary:
	var row := Panel.new()
	row.name = "SeatRow%d" % (i + 1)
	row.position = ROW_POS + Vector2(0, i * (ROW_SIZE.y + ROW_GAP))
	row.size = ROW_SIZE
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.pivot_offset = ROW_SIZE * 0.5
	row.gui_input.connect(_on_row_input.bind(i))
	_stage.add_child(row)
	# 头像（座位颜色圈 + 左上角座位号）
	var badge := Seats.Badge.new(118)
	badge.name = "Avatar"
	badge.show_number = true
	badge.ring_px = 7.0
	badge.position = Vector2(16, 16)
	row.add_child(badge)
	# 名字（第 1 行就是原来的 %NameEdit）
	var edit: LineEdit
	if i == 0:
		edit = %NameEdit as LineEdit
		_move(edit, row, Vector2(146, 12), Vector2(286, 64))
	else:
		edit = LineEdit.new()
		edit.name = "SeatName%d" % (i + 1)
		edit.position = Vector2(146, 12)
		edit.size = Vector2(286, 64)
		row.add_child(edit)
		edit.text_changed.connect(_on_seat_name_changed.bind(i))
	edit.max_length = MAX_NAME_LEN
	edit.select_all_on_focus = true
	_style_edit(edit, 28)
	edit.focus_entered.connect(_focus.bind(i))
	edit.focus_exited.connect(_on_name_focus_out.bind(i))
	edit.text_submitted.connect(func(_t: String) -> void: edit.release_focus())
	var pencil := _image("icon_pencil", Vector2(240, 16), Vector2(32, 32), edit)
	pencil.name = "Pencil"
	# 真人 / 电脑
	var human_b := Button.new()
	human_b.name = "HumanToggle"
	human_b.text = "真人"
	row.add_child(human_b)
	var ai_b := Button.new()
	ai_b.name = "AIToggle"
	ai_b.text = "电脑"
	row.add_child(ai_b)
	for pair: Array in [[human_b, Vector2(444, 12)], [ai_b, Vector2(536, 12)]]:
		var b := pair[0] as Button
		Kit.style_button(b, "cream", 64, 26)
		b.position = pair[1]
		b.size = Vector2(88, 64)
		b.custom_minimum_size = b.size
	human_b.tooltip_text = "真人玩家：轮到时自己掷骰子"
	ai_b.tooltip_text = "电脑小伙伴：自己会走、会买卖"
	human_b.pressed.connect(_set_seat_type.bind(i, "LOCAL_HUMAN"))
	ai_b.pressed.connect(_set_seat_type.bind(i, "AI"))
	# 颜色圆章：点开调色盘
	var color_b := Button.new()
	color_b.name = "ColorButton"
	color_b.position = Vector2(634, 12)
	color_b.size = Vector2(64, 64)
	color_b.custom_minimum_size = color_b.size
	color_b.focus_mode = Control.FOCUS_NONE
	color_b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	color_b.tooltip_text = "换颜色"
	var empty := StyleBoxEmpty.new()
	for state: String in ["normal", "hover", "pressed", "focus", "hover_pressed", "disabled"]:
		color_b.add_theme_stylebox_override(state, empty)
	var token := TextureRect.new()
	token.name = "Token"
	token.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	token.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	token.mouse_filter = Control.MOUSE_FILTER_IGNORE
	token.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	color_b.add_child(token)
	row.add_child(color_b)
	color_b.pressed.connect(_open_palette.bind(i))
	color_b.mouse_entered.connect(_pop.bind(color_b, 1.1))
	color_b.mouse_exited.connect(_unpop.bind(color_b))
	# 第二行：起始城市小签（点了右栏看这一位）
	var chip := Button.new()
	chip.name = "CityChip"
	chip.position = Vector2(146, 80)
	chip.size = Vector2(222, 64)
	chip.custom_minimum_size = chip.size
	chip.focus_mode = Control.FOCUS_NONE
	chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	chip.tooltip_text = "看看从哪儿出发"
	var cs := StyleBoxFlat.new()
	cs.bg_color = Color("#FFF3DC")
	cs.border_color = Color("#E0C79F")
	cs.set_border_width_all(2)
	cs.border_width_bottom = 4
	cs.set_corner_radius_all(32)
	cs.corner_detail = 10
	cs.anti_aliasing = true
	var ch := cs.duplicate() as StyleBoxFlat
	ch.bg_color = Color("#FFF8EA")
	ch.border_color = GOLD
	for pair: Array in [["normal", cs], ["hover", ch], ["pressed", ch], ["hover_pressed", ch], ["focus", StyleBoxEmpty.new()]]:
		chip.add_theme_stylebox_override(pair[0], pair[1])
	row.add_child(chip)
	var pin := _image("icon_pin", Vector2(14, 14), Vector2(26, 34), chip)
	pin.name = "Pin"
	var city := Kit.label("—", 24, INK_BROWN, "body", 800)
	city.name = "City"
	city.position = Vector2(44, 0)
	city.size = Vector2(128, 60)
	city.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	city.clip_text = true
	city.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	city.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(city)
	var tr := _image("icon_camel", Vector2(172, 12), Vector2(40, 38), chip)
	tr.name = "Transport"
	chip.pressed.connect(_focus.bind(i))
	# 电脑的难度：7 岁 / 12 岁 / 16 岁（行里的头像跟着换成那个年纪的小伙伴）
	var diff := HBoxContainer.new()
	diff.name = "Difficulty"
	diff.position = Vector2(378, 80)
	diff.size = Vector2(250, 64)
	diff.add_theme_constant_override("separation", 5)
	diff.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(diff)
	var diff_buttons := {}
	for id: String in AIDifficulty.ORDER:
		var b := Button.new()
		b.name = "Diff_%s" % id
		b.text = AIDifficulty.age_text(id).replace(" ", "")
		Kit.style_button(b, "cream", 64, 24)
		_tight(b)
		b.custom_minimum_size = Vector2(80, 64)
		b.tooltip_text = "%s · %s" % [AIDifficulty.display_name(id), String(AIDifficulty.INFO[id]["blurb"])]
		b.pressed.connect(_pick_seat_difficulty.bind(i, id))
		diff.add_child(b)
		diff_buttons[id] = b
	var hcap := Kit.label("轮到时自己掷骰子", 22, INK_SOFT, "body", 700)
	hcap.name = "HumanHint"
	hcap.position = Vector2(384, 80)
	hcap.size = Vector2(240, 64)
	hcap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hcap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hcap)
	# 请下车
	var rm := W.lens_button("×", 64)
	rm.name = "RemoveSeat"
	rm.position = Vector2(634, 80)
	rm.size = Vector2(64, 64)
	rm.tooltip_text = "请这位旅伴下车"
	rm.pressed.connect(_remove_seat.bind(i))
	row.add_child(rm)
	# 选中时右边的小箭头，指向「启程情报」
	var chev := LSkin.Chevron.new(Vector2(18, 34))
	chev.name = "FocusArrow"
	chev.color = GOLD
	chev.thick = 7.0
	chev.position = Vector2(ROW_SIZE.x + 2, 58)
	row.add_child(chev)
	return {"row": row, "badge": badge, "edit": edit, "human": human_b, "ai": ai_b, "color": color_b, "token": token,
		"chip": chip, "city": city, "transport": tr, "diff": diff, "diff_buttons": diff_buttons, "hcap": hcap, "remove": rm, "chev": chev}


## Kit 的糖果按钮左右留白是高度的 0.38，放「16岁」这种小按钮会把按钮撑宽、挤到「×」上：收窄左右留白
func _tight(b: Button) -> void:
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var st := b.get_theme_stylebox(state) as StyleBoxFlat
		if st != null:
			st.content_margin_left = 6
			st.content_margin_right = 6


func _row_style(focused: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color("#FFF3D6") if focused else Color("#FFF9EE")
	s.border_color = GOLD if focused else Color("#DCC6A2")
	s.set_border_width_all(5 if focused else 3)
	s.set_corner_radius_all(28)
	s.corner_detail = 12
	s.anti_aliasing = true
	s.shadow_color = Color(1.0, 0.72, 0.2, 0.45) if focused else Color(0.3, 0.18, 0.08, 0.12)
	s.shadow_size = 12 if focused else 4
	s.shadow_offset = Vector2(0, 0) if focused else Vector2(0, 3)
	return s


func _build_add_slot() -> void:
	_add_slot = Button.new()
	_add_slot.name = "AddSeat"
	_add_slot.size = Vector2(ROW_SIZE.x, 96)
	_add_slot.custom_minimum_size = _add_slot.size
	_add_slot.focus_mode = Control.FOCUS_NONE
	_add_slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_add_slot.tooltip_text = "最多 4 位旅伴"
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1.0, 0.98, 0.93, 0.45)
	s.border_color = Color("#D8C3A3")
	s.set_border_width_all(3)
	s.set_corner_radius_all(28)
	s.corner_detail = 12
	s.anti_aliasing = true
	var h := s.duplicate() as StyleBoxFlat
	h.bg_color = Color(1.0, 0.97, 0.9, 0.85)
	h.border_color = GOLD
	for pair: Array in [["normal", s], ["hover", h], ["pressed", h], ["hover_pressed", h], ["focus", StyleBoxEmpty.new()]]:
		_add_slot.add_theme_stylebox_override(pair[0], pair[1])
	var stitch := W.StitchLayer.new()
	stitch.inset = 9.0
	stitch.radius = 20.0
	stitch.dash = 11.0
	stitch.gap = 8.0
	stitch.color = Color("#C9A77C")
	_add_slot.add_child(stitch)
	var plus := Panel.new()
	plus.name = "Plus"
	var ps := Kit.candy_box(Kit.OCHRE, Kit.OCHRE_DEEP, 30, 5, 0, 0)
	ps.shadow_size = 4
	plus.add_theme_stylebox_override("panel", ps)
	plus.position = Vector2(196, 18)
	plus.size = Vector2(60, 60)
	plus.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add_slot.add_child(plus)
	var pl := Kit.label("+", 44, Color("#FFF8EC"), "body", 900)
	pl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pl.offset_bottom = -6
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plus.add_child(pl)
	var l := Kit.label("再加一位旅伴", 30, INK_BROWN, "body", 900)
	l.name = "AddLabel"
	l.position = Vector2(272, 0)
	l.size = Vector2(300, 96)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add_slot.add_child(l)
	_add_slot.pressed.connect(_add_seat)
	_add_slot.mouse_entered.connect(func() -> void: LSkin.CandyButton.wiggle(plus))
	_stage.add_child(_add_slot)


func _build_palette() -> void:
	# 点空白处收起的透明挡板（铺满整个可见区域，超宽屏也够）
	_palette_catcher = Control.new()
	_palette_catcher.name = "PaletteCatcher"
	_palette_catcher.position = Vector2(-4000, -4000)
	_palette_catcher.size = Vector2(12000, 12000)
	_palette_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_palette_catcher.visible = false
	_palette_catcher.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_close_palette())
	_stage.add_child(_palette_catcher)
	_palette = Panel.new()
	_palette.name = "Palette"
	_palette.size = Vector2(484, 150)
	_palette.mouse_filter = Control.MOUSE_FILTER_STOP
	_palette.visible = false
	_palette.add_theme_stylebox_override("panel", Kit.satchel_box(30, 5, 0))
	var stitch := W.StitchLayer.new()
	stitch.inset = 10.0
	stitch.radius = 20.0
	stitch.color = Color("#C9A77C")
	_palette.add_child(stitch)
	_stage.add_child(_palette)
	_move(%ColorRow, _palette, Vector2(24, 25), Vector2(436, 100))
	(%ColorRow as HBoxContainer).add_theme_constant_override("separation", 12)
	(%ColorRow as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	_ring = _GlassesRing.new()
	_ring.name = "ColorRing"
	_stage.add_child(_ring)
	_ring.visible = false


func _build_postcard() -> void:
	# 起始城市做成一张夹在情报栏里的明信片：城市插画 + 邮戳 + 城市名和一句介绍；左上角贴着是谁的起点
	_postcard = _box(Vector2(1412, 262), Vector2(420, 300))
	_postcard.name = "Postcard"
	var paper := _nine_panel("card_blank", Vector2.ZERO, _postcard.size, _postcard)
	paper.name = "Paper"
	_postcard.pivot_offset = _postcard.size * 0.5
	_postcard.rotation = deg_to_rad(-2.5)
	var frame := PanelContainer.new()
	frame.name = "PhotoFrame"
	var fs := StyleBoxFlat.new()
	fs.bg_color = Color("#E8D9BF")
	fs.set_corner_radius_all(14)
	fs.corner_detail = 8
	fs.anti_aliasing = true
	frame.add_theme_stylebox_override("panel", fs)
	frame.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	frame.position = Vector2(18, 18)
	frame.size = Vector2(384, 174)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_postcard.add_child(frame)
	var ill := %CityIllustration as TextureRect
	ill.reparent(frame, false)
	ill.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	ill.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_move(%HomeCityLabel, _postcard, Vector2(28, 198), Vector2(372, 40))
	var home := %HomeCityLabel as Label
	home.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	home.add_theme_font_override("font", Kit.font("body", 900))
	home.add_theme_font_size_override("font_size", 30)
	home.add_theme_color_override("font_color", INK_BROWN)
	home.add_theme_constant_override("outline_size", 0)
	home.add_theme_constant_override("shadow_offset_y", 0)
	_epithet = Kit.label("", 21, INK_SOFT, "body", 700)
	_epithet.name = "Epithet"
	_epithet.position = Vector2(30, 240)
	_epithet.size = Vector2(372, 30)
	_epithet.clip_text = true
	_epithet.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_postcard.add_child(_epithet)
	var stamp := W.Postmark.new()
	stamp.name = "Stamp"
	stamp.position = Vector2(262, -24)
	stamp.size = Vector2(170, 110)
	stamp.pivot_offset = Vector2(60, 55)
	stamp.rotation = deg_to_rad(8)
	_postcard.add_child(stamp)
	_stamp_city = Kit.label("", 30, Color("#B5473A"), "body", 900)
	_stamp_city.name = "StampCity"
	_stamp_city.position = Vector2(14, 33)
	_stamp_city.size = Vector2(92, 44)
	_stamp_city.grow_horizontal = Control.GROW_DIRECTION_BOTH  # 万一字宽超出，也向两边长，保持在邮戳正中
	_stamp_city.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stamp_city.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stamp.add_child(_stamp_city)
	# 是谁的起点：圆头像 + 名字小签，像夹在明信片角上的行李牌
	_owner_name = Kit.label("", 22, INK_BROWN, "body", 900)
	_owner_name.name = "OwnerName"
	_owner_name.add_theme_stylebox_override("normal", Kit.pill_box(16, 4))
	_owner_name.position = Vector2(44, -20)
	_owner_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_postcard.add_child(_owner_name)
	var owner := Seats.Badge.new(76)
	owner.name = "OwnerBadge"
	owner.ring_px = 6.0
	owner.position = Vector2(-26, -34)
	_postcard.add_child(owner)
	_owner_badge = owner


func _refresh_city_extras() -> void:
	if _stamp_city == null:
		return
	var name: String = String(_prepare_result.get("home_city_name", ""))
	var city_id: String = String(_prepare_result.get("home_city_id", ""))
	# 邮戳里放完整城市名，字多就缩小（君士坦丁堡 5 个字也放得下）
	W.Postmark.fit_label(_stamp_city, name)
	var epithet: String = ""
	if _session_mode == "FORMAL" and city_id != "":
		var resolved: Dictionary = FormalCardPresentationResolver.resolve_city_card(_content, city_id)
		epithet = String(resolved.get("epithet", ""))
	_epithet.text = epithet
	_epithet.visible = epithet != ""


func _refresh_owner() -> void:
	if _owner_badge == null or _seats.is_empty():
		return
	var configs := collect_configs()
	var i := clampi(_focus_seat if _session_mode == "FORMAL" else _first_human(), 0, configs.size() - 1)
	_owner_badge.call("set_seat", configs[i], configs)
	# 名字最长 12 个字：小签右边就是邮戳（x=262），名字太长时截成「前几个字…的起点」，不压到邮戳上
	var who := String(configs[i]["display_name"])
	var text := "%s的起点" % who
	var font := _owner_name.get_theme_font("font")
	var font_px := _owner_name.get_theme_font_size("font_size")
	const OWNER_TEXT_MAX_W := 180.0
	while font != null and who.length() > 1 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_px).x > OWNER_TEXT_MAX_W:
		who = who.left(who.length() - 1)
		text = "%s…的起点" % who
	_owner_name.text = text
	_owner_name.size = Vector2.ZERO


func _style_edit(e: LineEdit, px: int) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = CREAM_BOX
	s.border_color = Color("#C9A77C")
	s.set_border_width_all(3)
	s.set_corner_radius_all(32)
	s.corner_detail = 12
	s.content_margin_left = 22
	s.content_margin_right = 52
	s.anti_aliasing = true
	s.shadow_color = Color(0.3, 0.18, 0.08, 0.12)
	s.shadow_size = 4
	s.shadow_offset = Vector2(0, 2)
	var f := s.duplicate() as StyleBoxFlat
	f.border_color = GOLD
	f.set_border_width_all(4)
	e.add_theme_stylebox_override("normal", s)
	e.add_theme_stylebox_override("focus", f)
	e.add_theme_stylebox_override("read_only", s)
	e.add_theme_font_override("font", Kit.font("body", 900))
	e.add_theme_font_size_override("font_size", px)
	e.add_theme_color_override("font_color", INK_BROWN)
	e.add_theme_color_override("font_placeholder_color", Color(INK_SOFT, 0.6))
	e.add_theme_color_override("caret_color", INK_BROWN)
	e.add_theme_color_override("selection_color", Color("#F3C77A", 0.6))
	e.add_theme_constant_override("outline_size", 0)


func _style_small(l: Label, px: int, color: Color) -> void:
	l.add_theme_font_override("font", Kit.font("body", 700))
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", 0)
	l.add_theme_constant_override("shadow_offset_y", 0)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.clip_text = false


func _style_gate() -> void:
	var g := %GateLabel as Label
	g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	g.autowrap_mode = TextServer.AUTOWRAP_OFF
	g.clip_text = true
	g.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	g.tooltip_text = g.text
	g.mouse_filter = Control.MOUSE_FILTER_PASS if g.text != "" else Control.MOUSE_FILTER_IGNORE
	g.add_theme_font_override("font", Kit.font("body", 800))
	g.add_theme_font_size_override("font_size", 22)
	g.add_theme_color_override("font_color", Color("#B5473A"))
	g.add_theme_constant_override("outline_size", 0)
	g.add_theme_constant_override("shadow_offset_y", 0)


# ------------------------------------------------------------------ 座位列表刷新
func _sync_rows() -> void:
	if _rows.is_empty():
		return
	_syncing = true
	var configs := collect_configs()
	var n: int = _seats.size()
	var formal: bool = _session_mode == "FORMAL"
	var seats_payload: Array = _prepare_result.get("seats", [])
	var humans := _human_count()
	for i in MAX_SEATS:
		var r: Dictionary = _rows[i]
		var row := r["row"] as Control
		row.visible = i < n
		if i >= n:
			continue
		var s: Dictionary = _seats[i]
		var ai: bool = String(s["type"]) == "AI"
		var focused: bool = i == (_focus_seat if formal else _first_human())
		row.add_theme_stylebox_override("panel", _row_style(focused))
		(r["chev"] as Control).visible = focused
		r["badge"].call("set_seat", configs[i], configs)
		var edit := r["edit"] as LineEdit
		edit.placeholder_text = _default_name(i)
		if not edit.has_focus() and edit.text != _seat_name(i):
			edit.text = _seat_name(i)
		if not edit.has_focus():
			_fit_name_edit(edit)
		Kit.style_button(r["human"], "cream" if ai else "primary", 64, 26)
		Kit.style_button(r["ai"], "primary" if ai else "cream", 64, 26)
		for key: String in ["human", "ai"]:
			var tb := r[key] as Button
			tb.disabled = not formal
			tb.custom_minimum_size = Vector2(88, 64)
		(r["token"] as TextureRect).texture = Seats.token_texture(String(s["color_id"]))
		(r["color"] as Button).tooltip_text = "%s色 · 点一下换颜色" % Seats.color_name(String(s["color_id"]))
		var city_name := "—"
		var transport := GameData.Transport.CAMEL
		if i < seats_payload.size():
			city_name = String((seats_payload[i] as Dictionary).get("home_city_name", "—"))
			transport = int((seats_payload[i] as Dictionary).get("starting_transport", GameData.Transport.CAMEL))
		(r["city"] as Label).text = city_name
		(r["transport"] as TextureRect).texture = _tex("icon_ship" if transport == GameData.Transport.SHIP else "icon_camel")
		(r["chip"] as Button).tooltip_text = "从%s出发 · 点一下看看" % city_name
		(r["diff"] as Control).visible = ai
		(r["hcap"] as Control).visible = not ai
		if ai:
			for id: String in r["diff_buttons"]:
				var db := r["diff_buttons"][id] as Button
				Kit.style_button(db, "primary" if id == AIDifficulty.normalize(String(s["ai_difficulty"])) else "cream", 64, 24)
				_tight(db)
				db.custom_minimum_size = Vector2(80, 64)
		(r["remove"] as Control).visible = formal and n > MIN_SEATS and not (not ai and humans <= 1)
	_add_slot.visible = formal and n < MAX_SEATS
	var slot_pos := ROW_POS + Vector2(0, n * (ROW_SIZE.y + ROW_GAP))
	# 进页面的升起动画还在跑时加减了座位：先停掉它，不然它会把「再加一位旅伴」拉回旧位置、压在新的一行上
	# get_meta(key, null) 在键不存在时仍会报 ERROR（null 默认值等于没给默认值），所以先 has_meta
	var rise: Variant = _add_slot.get_meta("from_tween") if _add_slot.has_meta("from_tween") else null
	if rise is Tween and (rise as Tween).is_valid():
		(rise as Tween).kill()
		_add_slot.modulate.a = 1.0
	_add_slot.position = slot_pos
	_add_slot.set_meta("base_pos", slot_pos)
	if _preset_ai != null:
		_set_candy_color(_preset_ai, "ochre" if humans <= 1 else "cream")
		_set_candy_color(_preset_friends, "ochre" if humans >= 2 else "cream")
		_preset_ai.disabled = not formal
		_preset_friends.disabled = not formal
	_syncing = false


# ------------------------------------------------------------------ 颜色、交通的新皮
func _restyle_colors() -> void:
	for i in _color_buttons.size():
		var b := _color_buttons[i]
		var cd: Dictionary = _colors[i]
		b.custom_minimum_size = Vector2(100, 100)
		b.tooltip_text = "%s色" % String(cd.get("display_name", ""))
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var seal := b.get_node_or_null("Seal") as TextureRect
		if seal != null:
			var tok: Texture2D = _tex("token_%s" % String(cd.get("id", "")))
			if tok != null:
				seal.texture = tok
				seal.modulate = Color.WHITE
			seal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			seal.offset_left = 8
			seal.offset_top = 8
			seal.offset_right = -8
			seal.offset_bottom = -8
		var nm := b.get_node_or_null("ColorName") as Control
		if nm != null:
			nm.visible = false
		# 别人用着这个颜色时，右下角贴一个他的小头像（选了就和他交换）
		if b.get_node_or_null("Owner") == null:
			var owner := Seats.Badge.new(46)
			owner.name = "Owner"
			owner.ring_px = 4.0
			owner.position = Vector2(60, 58)
			owner.visible = false
			b.add_child(owner)
		# 颜色按钮每次进页面都是新建的，直接连就行
		b.mouse_entered.connect(_pop.bind(b, 1.08))
		b.mouse_exited.connect(_unpop.bind(b))
		var empty := StyleBoxEmpty.new()
		for state: String in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			b.add_theme_stylebox_override(state, empty)
	_refresh_color_buttons()


## 选中的颜色外面套一个 L叔 眼镜片形状的粗框
class _GlassesRing extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size = Vector2(118, 118)
		pivot_offset = size * 0.5

	func _draw() -> void:
		var r := Rect2(Vector2(6, 6), size - Vector2(12, 12))
		var s := StyleBoxFlat.new()
		s.draw_center = false
		s.border_color = Color("#2E2019")
		s.set_border_width_all(9)
		s.set_corner_radius_all(30)
		s.corner_detail = 10
		s.anti_aliasing = true
		s.shadow_color = Color(0.2, 0.1, 0.05, 0.25)
		s.shadow_size = 4
		draw_style_box(s, r)
		# 两边的小镜腿
		draw_rect(Rect2(Vector2(-4, size.y * 0.3), Vector2(12, 12)), Color("#2E2019"))
		draw_rect(Rect2(Vector2(size.x - 8, size.y * 0.3), Vector2(12, 12)), Color("#2E2019"))


func _place_ring(animate: bool) -> void:
	# 眼镜框直接挂在选中的颜色按钮上，居中；换颜色时弹一下
	if _ring == null or _color_buttons.is_empty():
		return
	var b := _color_buttons[clampi(_ring_index, 0, _color_buttons.size() - 1)]
	if _ring.get_parent() != b:
		if _ring.get_parent() != null:
			_ring.reparent(b, false)
		else:
			b.add_child(_ring)
		b.move_child(_ring, b.get_child_count() - 1)
		var owner := b.get_node_or_null("Owner")
		if owner != null:
			b.move_child(owner, b.get_child_count() - 1)
	_ring.set_anchors_preset(Control.PRESET_CENTER)
	_ring.position = b.custom_minimum_size * 0.5 - _ring.size * 0.5
	_ring.visible = true
	if animate:
		_ring.scale = Vector2(1.18, 1.18)
		var tw := _ring.create_tween()
		tw.tween_property(_ring, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _restyle_transport() -> void:
	for b: Button in [%CamelButton, %ShipButton]:
		b.pivot_offset = b.custom_minimum_size * 0.5
		var card := _TransportCard.new()
		card.name = "TransportCard"
		card.button = b
		card.owner_screen = self
		card.is_ship = b == %ShipButton
		b.add_child(card)
		b.move_child(card, 0)
	_refresh_transport_styles()


class _TransportCard extends Control:
	var button: Button
	var owner_screen: Object
	var is_ship: bool = false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		show_behind_parent = true

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	func _draw() -> void:
		var sel_t: int = int(owner_screen.get("_selected_transport")) if owner_screen != null else 0
		var selected: bool = (sel_t == 1) == is_ship
		var s := StyleBoxFlat.new()
		s.bg_color = Color("#FFF3D6") if selected else Color("#F1E6D4")
		s.border_color = Color("#E89419") if selected else Color("#D8C3A3")
		s.set_border_width_all(5 if selected else 2)
		s.set_corner_radius_all(20)
		s.corner_detail = 10
		s.anti_aliasing = true
		s.shadow_color = Color(1.0, 0.72, 0.2, 0.45) if selected else Color(0, 0, 0, 0)
		s.shadow_size = 12 if selected else 0
		draw_style_box(s, Rect2(Vector2.ZERO, size))


# ------------------------------------------------------------------ 泡泡、动效
func _set_line(text: String) -> void:
	if _bubble_text == null or _bubble_text.text == text:
		return
	_bubble_text.text = text
	_bubble_text.visible_ratio = 0.0
	var bubble := _bubble_text.get_parent() as Control
	bubble.pivot_offset = Vector2(60, bubble.size.y)
	var tw := bubble.create_tween()
	tw.tween_property(bubble, "scale", Vector2(1.06, 1.06), 0.09).set_trans(Tween.TRANS_SINE)
	tw.tween_property(bubble, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(_bubble_text, "visible_ratio", 1.0, 0.45)
	if _lshu != null:
		var nod := _lshu.create_tween()
		nod.tween_property(_lshu, "rotation", deg_to_rad(-2.5), 0.12).set_trans(Tween.TRANS_SINE)
		nod.tween_property(_lshu, "rotation", 0.0, 0.4).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _unpop(node: Control) -> void:
	var tw := node.create_tween()
	tw.tween_property(node, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _pop(node: Control, s: float) -> void:
	if node == null:
		return
	node.pivot_offset = node.size * 0.5
	var tw := node.create_tween()
	tw.tween_property(node, "scale", Vector2(s, s), 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if not (node is BaseButton and (node as BaseButton).is_hovered()):
		tw.tween_property(node, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _on_visible_changed() -> void:
	for t in _idle_tweens:
		if t != null and t.is_valid():
			t.kill()
	_idle_tweens.clear()
	# 停在半截的扫光和呼吸要复位，不然再进来时按钮上会留一道亮带
	if _go_shine != null:
		_go_shine.set_shader_parameter("shine", -1.0)
	if _lshu != null:
		_lshu.scale = Vector2.ONE
	if not is_visible_in_tree() or _stage == null:
		_close_palette()
		_close_fun_panel()
		_close_map_panel()
		return
	_play_entrance()


func _from(node: Control, delay: float, offset: Vector2, dur: float = 0.6) -> void:
	var base: Vector2 = node.get_meta("base_pos", node.position)
	node.set_meta("base_pos", base)
	node.position = base + offset
	node.modulate.a = 0.0
	var tw := node.create_tween().set_parallel(true)
	tw.tween_property(node, "position", base, dur).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "modulate:a", 1.0, dur * 0.45).set_delay(delay)
	node.set_meta("from_tween", tw)


func _play_entrance() -> void:
	# 进页面：L叔 从左边走进来，面板从下面升上来，标题牌落下，座位一行行弹出；之后 L叔 轻轻呼吸，出发按钮隔一会儿扫一道光
	_from(_lshu, 0.0, Vector2(-260, 0), 0.7)
	var bubble := _bubble_text.get_parent() as Control
	_from(bubble, 0.45, Vector2(0, 30), 0.5)
	# 测试会在页面刚显示时检查这几个节点在不在屏幕里，它们不做位移，只淡入 / 弹一下
	var keep_in_place: Array[Control] = [%HumanCard, %InfoCard, %StartButton, %BackButton, %GateLabel, _palette, _palette_catcher]
	var rows: Array[Control] = []
	for r in _rows:
		rows.append(r["row"])
	var movers: Array[Control] = []
	for c in _stage.get_children():
		var ctl := c as Control
		if ctl == null or ctl == _lshu or ctl == bubble or ctl.name.begins_with("Drift") or ctl.name == "TitleTab" or ctl.name == "Ledge":
			continue
		if ctl in keep_in_place or ctl in rows:
			continue
		movers.append(ctl)
	for ctl in movers:
		_from(ctl, 0.12, Vector2(0, 90), 0.6)
	# 座位一行行从下面弹上来
	for i in rows.size():
		_from(rows[i], 0.3 + 0.08 * i, Vector2(0, 70), 0.55)
	for ctl: Control in [%StartButton, %BackButton]:
		ctl.modulate.a = 0.0
		var ft := ctl.create_tween()
		ft.tween_property(ctl, "modulate:a", 1.0, 0.35).set_delay(0.5)
	var tab := _stage.get_node("TitleTab") as Control
	_from(tab, 0.35, Vector2(0, -160), 0.7)
	var breathe := _lshu.create_tween().set_loops()
	breathe.tween_property(_lshu, "scale", Vector2(1.0, 1.012), 1.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	breathe.tween_property(_lshu, "scale", Vector2.ONE, 1.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_idle_tweens.append(breathe)
	var shine := create_tween().set_loops()
	shine.tween_interval(2.4)
	shine.tween_method(func(v: float) -> void:
		_go_shine.set_shader_parameter("shine", -1.0 if (%StartButton as Button).disabled else v), -0.25, 1.25, 0.95).set_trans(Tween.TRANS_SINE)
	shine.tween_interval(3.2)
	_idle_tweens.append(shine)
	_place_ring(false)
	_refresh_go_state()


func _process(delta: float) -> void:
	if _stage == null or not is_visible_in_tree():
		return
	for c in _stage.get_children():
		if c is TextureRect and String(c.name).begins_with("DriftCloud"):
			var t := c as TextureRect
			t.position.x += float(t.get_meta("speed", 8.0)) * delta
			if t.position.x > _visible_x.y + 100:
				t.position.x = _visible_x.x - t.size.x - 100


# ------------------------------------------------------------------ 布局
func _lshu_layout() -> void:
	if _design == null:
		return
	var vp: Vector2 = size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	var k: float = minf(vp.x / STAGE.x, vp.y / STAGE.y)
	_design.position = Vector2.ZERO
	_design.size = vp
	var origin: Vector2 = (vp - STAGE * k) * 0.5
	_stage.scale = Vector2(k, k)
	_stage.position = origin
	# 超宽 / 4:3 时屏幕能看到的 Stage 横向范围：云在它外面换行，花瓣从它左边外面出生
	_visible_x = Vector2(-origin.x / k, (vp.x - origin.x) / k)
	var petals := _stage.get_node_or_null("Petals") as Node2D
	if petals != null:
		petals.position.x = _visible_x.x - 60.0
	var top := $TopBar as Control
	top.scale = Vector2(k, k)
	top.position = origin + Vector2(36, 20) * k
	top.size = Vector2(520, 44)
	_place_ring(false)
