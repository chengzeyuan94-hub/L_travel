extends CanvasLayer
## Act 4 「L叔在哪儿」 UI root. Add one instance above the scene; drive it with resolve() results
## (apply_resolve) or the individual calls below. Nothing is on screen by default:
##   · place caption, bottom-left, 12 s after an arrival, again for a few seconds on mouse movement
##   · a small stamp, bottom-right, only while there are unread postcards (no number)
##   · the postcard viewer (stamp click / thumbnail click), flip on click, away on empty click or idle
##   · the travel book (key L), grouped by trip, thumbnails beside the stops that sent a card
##   · 「你不在的时候」 after an absence of 2 h or more, gone after 15 s
## The UI never writes the save: it emits postcard_read(id) and the director calls
## LshuSave.mark_read(save, id). See scripts/traveler/lshu/ui/README.md.

signal postcard_opened(postcard_id: String)
signal postcard_closed(postcard_id: String, reason: String)
signal postcard_read(postcard_id: String)
signal stamp_pressed
signal book_toggled(is_open: bool)
## The 「你不在的时候」 card printed L叔's line (postcard library ids). The UI does not store it; a
## director that wants the line to count toward the postcards' no-repeat window can keep these ids.
signal away_line_shown(line_ids: Array)
## A postcard or the travel book opened (true) or the last of them closed (false). Clicks do not
## reach the scene while busy; the director can pause its own click handling (the bow) with it.
signal busy_changed(is_busy: bool)

const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")
const D := preload("res://scripts/traveler/lshu/ui/lshu_ui_data.gd")
const Images := preload("res://scripts/traveler/lshu/ui/lshu_ui_images.gd")
const Caption := preload("res://scripts/traveler/lshu/ui/lshu_place_caption.gd")
const Stamp := preload("res://scripts/traveler/lshu/ui/lshu_stamp_indicator.gd")
const View := preload("res://scripts/traveler/lshu/ui/lshu_postcard_view.gd")
const Book := preload("res://scripts/traveler/lshu/ui/lshu_travel_book.gd")
const Away := preload("res://scripts/traveler/lshu/ui/lshu_away_card.gd")
const BookButton := preload("res://scripts/traveler/lshu/ui/lshu_book_button.gd")
const LshuSave := preload("res://scripts/traveler/lshu/loop/lshu_save.gd")

const ROAD_TITLE: String = "在路上"
const ROAD_SUB_FMT: String = "刚离开%s"
## 夜里他钻进帐篷以后画面上看不到人：地名那一行换成这句（2026-09-27 夜测 LSHU-6）
const SLEEP_TITLE: String = "L叔睡着了"
const SLEEP_SUB_FMT: String = "在%s的帐篷里 · 早上 %s 起床"
## 明信片打开不到这么久就收回去（比如双击邮票），不算看过、不记已读（LSHU-4）
const READ_MIN_OPEN_S: float = 0.6
## 打开后这么久之内再点邮票不收回（双击、连点）
const STAMP_CLOSE_GUARD_S: float = 0.6

@export var caption_hold_s: float = 12.0
@export var caption_hover_s: float = 4.0
@export var postcard_idle_s: float = 20.0
@export var book_idle_s: float = 60.0
@export var away_hold_s: float = 15.0
@export var handle_book_key: bool = true
@export var book_keycode: Key = KEY_L

var save: Dictionary = {}
var tz_s: int = 0
var images: RefCounted = Images.new()

var _root: Control
var _caption: Control
var _stamp: Control
var _book_btn: Control
var _view: Control
var _book: Control
var _away: Control
var _unread: Array = []
var _read_local: Dictionary = {}
var _place: Dictionary = {}
var _on_road: bool = false
var _sleeping: bool = false
var _wake_label: String = ""
var _opened_at_ms: int = -1
var _band: String = ""
var _busy: bool = false
var _state_key: String = ""
var _places_by_tile: Dictionary = {}
var _s: float = 1.0
var _ppu: float = 1.0
var _vp: Vector2 = Vector2(1920.0, 1080.0)
var _layout_queued: bool = false


func _init() -> void:
	layer = 20
	tz_s = D.tz_from_config({})


func _ready() -> void:
	_root = Control.new()
	_root.name = "LshuUiRoot"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	_caption = Caption.new()
	_root.add_child(_caption)
	_away = Away.new()
	_away.set("images", images)
	_away.set("hold_s", away_hold_s)
	_away.connect("postcard_requested", open_postcard)
	_root.add_child(_away)
	_book = Book.new()
	_book.set("images", images)
	_book.set("idle_limit", book_idle_s)
	_book.connect("postcard_requested", open_postcard)
	_book.connect("closed", _on_book_closed)
	_root.add_child(_book)
	_view = View.new()
	_view.set("idle_limit", postcard_idle_s)
	_view.connect("closed", _on_view_closed)
	_root.add_child(_view)
	# the stamp sits above the blur so a card visibly flies back into it
	_stamp = Stamp.new()
	_stamp.connect("pressed", _on_stamp_pressed)
	_root.add_child(_stamp)
	# 右下角邮票左边的旅行本：一动鼠标和地名一起浮出来，点开旅行本（LSHU-3：以前只有 L 键）
	_book_btn = BookButton.new()
	_book_btn.connect("pressed", open_book)
	_root.add_child(_book_btn)
	_root.resized.connect(_queue_layout)
	get_viewport().size_changed.connect(_queue_layout)
	_apply_layout()


func _exit_tree() -> void:
	images.call("shutdown")


# ============================================================================== setup

## Optional. cfg: LshuClock.load_config() (time zone for printed dates, the postcard line library
## for stamp labels and city epithets). places: LshuPoolAdapter.load_places() (each place's own
## one-line `sub` for the caption when an event does not carry it).
func configure(cfg: Dictionary = {}, places: Array = []) -> void:
	tz_s = D.tz_from_config(cfg)
	var lib: Variant = cfg.get("postcard_lines", {})
	if lib is Dictionary and not (lib as Dictionary).is_empty():
		D.set_lines_library(lib as Dictionary)
	_places_by_tile = {}
	for p: Variant in places:
		if p is Dictionary:
			_places_by_tile[String((p as Dictionary).get("id", ""))] = p


func set_tz_offset_s(seconds: int) -> void:
	tz_s = seconds


## The latest save dict (read only here). The travel book and the away card read it.
func set_save(data: Dictionary) -> void:
	save = data


# ============================================================================== one call per tick

## Everything from one LshuClock.resolve() result: save, where he is, road or not, the events of
## this tick, and the unread postcards. Safe to call every 2 s.
func apply_resolve(r: Dictionary) -> void:
	if not bool(r.get("ok", false)):
		return
	set_save(r.get("save", {}) as Dictionary)
	var light: Variant = r.get("light", {})
	if light is Dictionary:
		_band = String((light as Dictionary).get("band", _band))
	var leg: Dictionary = r.get("leg", {}) as Dictionary
	var road: bool = String(r.get("substate", "")) == "ROAD"
	var sleeping: bool = String(r.get("substate", "")) == "NIGHT" and String(r.get("night_phase", "")) == "tent"
	var key: String = "%s|%s|%s|%s" % [String(leg.get("tile", "")), str(int(leg.get("index", -1))), str(road), str(sleeping)]
	if key != _state_key:
		_state_key = key
		_sleeping = sleeping
		_wake_label = _clock_label(int(leg.get("night_end", 0))) if sleeping else ""
		set_place(_place_from_leg(leg), road)
	for e: Variant in r.get("events", []) as Array:
		handle_event(e as Dictionary)
	set_unread(LshuSave.unread(save))


## React to one resolve() event. Only the ones the UI cares about do anything.
func handle_event(e: Dictionary) -> void:
	match String(e.get("type", "")):
		"arrive", "home_arrive", "first_launch":
			show_arrival(_place_from_event(e))
		"leave", "home_leave":
			_caption.call("hide_soft", 1.2)
		"road_start":
			set_place(_place_from_event(e), true)
		"catchup":
			var road: bool = _on_road
			set_place(_place_from_event(e), road)
			if bool(e.get("show_away_card", false)):
				show_away(e)
			if not is_busy():
				_caption.call("peek", caption_hold_s)


# ============================================================================== caption

## Show the place name (bottom-left) for caption_hold_s, then fade. place: a resolve() event, r.leg,
## a places[] entry or {name, sub}; an explicit {caption_sub} overrides the sub/epithet rule.
func show_arrival(place: Dictionary) -> void:
	_place = place
	_on_road = false
	var cap: Dictionary = D.place_caption(place)
	_caption.call("show_place", String(cap.title), String(cap.sub), caption_hold_s, 1.2)
	if not is_busy():
		_book_btn.call("peek", caption_hold_s)   # 到了一个地方：旅行本跟地名一起露一会儿


## Update what the caption would say on mouse movement, without showing it. on_road: he walked off
## the tile (caption reads 在路上 / 刚离开…).
func set_place(place: Dictionary, on_road: bool = false) -> void:
	_place = place
	_on_road = on_road
	var cap: Dictionary = _caption_now()
	_caption.call("set_place", String(cap.title), String(cap.sub))


func hide_caption() -> void:
	_caption.call("hide_now")


# ============================================================================== stamp / postcards

## Unread postcards (LshuSave.unread(save)): the stamp shows while this is non-empty and a click
## opens the oldest one. Cards the UI already reported read are ignored until the save catches up.
func set_unread(records: Array) -> void:
	var present: Dictionary = {}
	var list: Array = []
	for v: Variant in records:
		var rec: Dictionary = v
		var id: String = String(rec.get("id", ""))
		present[id] = true
		if not _read_local.has(id) and not bool(rec.get("read", false)):
			list.append(rec)
	for id: Variant in _read_local.keys():
		if not present.has(id):
			_read_local.erase(id)
	_unread = list
	var pal: Dictionary = {}
	if not list.is_empty():
		var newest: Dictionary = list[list.size() - 1]
		pal = S.stamp_palette(String(newest.get("biome", "")), String(newest.get("band", "")))
		images.call("prefetch", String((list[0] as Dictionary).get("file", "")))
	_stamp.call("set_unread", list.size(), pal)


## Indicator only (no records): the stamp shows for n > 0 and a click just emits stamp_pressed.
func set_unread_count(n: int) -> void:
	_unread = []
	_stamp.call("set_unread", n, {})


func unread() -> Array:
	return _unread


## Open a postcard record (front first). from_rect: global rect of a thumbnail to grow out of and
## return to; empty = slide up from the bottom and fly back into the stamp.
func open_postcard(record: Dictionary, from_rect: Rect2 = Rect2()) -> void:
	if record.is_empty():
		return
	var tex: Texture2D = images.call("texture", String(record.get("file", ""))) as Texture2D
	_view.set("fly_target", _stamp_center())
	_caption.call("hide_soft", 0.5)
	_book_btn.call("set_suppressed", true)
	# 先开（上一张还在飞回邮票时，open 会先把它收尾、报「已读」，那时还要用上一张的打开时刻），再记这一张的打开时刻
	_view.call("open", record, tex, tz_s, from_rect)
	_opened_at_ms = Time.get_ticks_msec()
	postcard_opened.emit(String(record.get("id", "")))


func close_postcard() -> void:
	_view.call("close", "api")


func flip_postcard() -> void:
	_view.call("flip")


# ============================================================================== book / away

func open_book() -> void:
	if _book.call("is_open"):
		return
	_book.set("tz_s", tz_s)
	_caption.call("hide_soft", 0.5)
	_stamp.call("set_suppressed", true)
	_book_btn.call("set_suppressed", true)
	_book.call("open", D.build_trips(save, tz_s))
	book_toggled.emit(true)


func close_book() -> void:
	if _book.call("is_open"):
		_book.call("close")


func toggle_book() -> void:
	if _book.call("is_open"):
		close_book()
	else:
		open_book()


## 「你不在的时候」 from a catchup event (or r.catchup). records: the new postcards to show; when empty
## they are looked up in the save by catchup.postcards (only those with an image).
func show_away(catchup: Dictionary, records: Array = []) -> void:
	var recs: Array = records
	if recs.is_empty():
		for id: Variant in catchup.get("postcards", []) as Array:
			var pc: Dictionary = LshuSave.find_postcard(save, String(id))
			if not pc.is_empty() and Images.file_ok(String(pc.get("file", ""))):
				recs.append(pc)
	var here: String = String(_place.get("name", catchup.get("name", "")))
	var line: Dictionary = D.away_line(save, catchup, _band, catchup.get("kit", _place.get("kit", "")))
	_away.set("hold_s", away_hold_s)
	_away.call("present", catchup, recs, here, line)
	if not line.is_empty():
		away_line_shown.emit(line.get("line_ids", []) as Array)


func hide_away() -> void:
	_away.call("dismiss", 0.6)


# ============================================================================== state

func is_busy() -> bool:
	return bool(_view.call("is_open")) or bool(_book.call("is_open"))


## True when anything at all is on screen.
func is_any_visible() -> bool:
	for c: Control in [_caption, _stamp, _book_btn, _view, _book, _away]:
		if c.visible and c.modulate.a > 0.001:
			return true
	return false


## The director's own input handler can call this so the caption peeks and idle timers reset.
func notify_activity() -> void:
	_activity()


func ui_scale() -> float:
	return _s


## Snapshot for QA and tests.
func state() -> Dictionary:
	return {
		"scale": _s, "px_per_unit": _ppu, "viewport": [_vp.x, _vp.y], "any_visible": is_any_visible(),
		"caption": {"visible": _caption.visible, "showing": _caption.call("is_showing"), "title": _caption.get("title_text"),
			"sub": _caption.get("sub_text"), "rect": _rect_arr(_caption.get_global_rect()), "hold_left": _caption.call("hold_left")},
		"stamp": {"visible": _stamp.visible, "unread": _stamp.get("unread"), "rect": _rect_arr(_stamp.get_global_rect())},
		"book_button": {"visible": _book_btn.visible, "shown": _book_btn.call("is_shown"), "rect": _rect_arr(_book_btn.get_global_rect())},
		"viewer": {"open": _view.call("is_open"), "animating": _view.call("is_animating"), "back": _view.call("showing_back"),
			"id": String((_view.call("record") as Dictionary).get("id", "")), "card_rect": _rect_arr(_view.call("card_rect") as Rect2),
			"idle": _view.call("idle_time")},
		"book": {"open": _book.call("is_open"), "visible": _book.visible, "rect": _rect_arr(_book.call("book_rect") as Rect2),
			"trips_shown": _book.call("trip_count_shown"), "thumbs": (_book.call("thumbs") as Array).size()},
		"away": {"showing": _away.call("is_showing"), "visible": _away.visible, "rect": _rect_arr(_away.get_global_rect()),
			"time_left": _away.call("time_left")},
	}


func caption_control() -> Control:
	return _caption


func stamp_control() -> Control:
	return _stamp


func book_button_control() -> Control:
	return _book_btn


func viewer_control() -> Control:
	return _view


func book_control() -> Control:
	return _book


func away_control() -> Control:
	return _away


# ============================================================================== internals

func _process(_delta: float) -> void:
	images.call("poll")
	var busy: bool = is_busy()
	if busy != _busy:
		_busy = busy
		busy_changed.emit(busy)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if (event as InputEventMouseMotion).relative.length_squared() > 0.0:
			_activity()
	elif event is InputEventMouseButton or event is InputEventKey:
		_view.call("poke")
		_book.call("poke")


func _unhandled_key_input(event: InputEvent) -> void:
	var k: InputEventKey = event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if handle_book_key and k.keycode == book_keycode:
		if _view.call("is_open"):
			_view.call("close", "key")
		else:
			toggle_book()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_ESCAPE:
		if _view.call("is_open"):
			_view.call("close", "key")
			get_viewport().set_input_as_handled()
		elif _book.call("is_open"):
			close_book()
			get_viewport().set_input_as_handled()


func _activity() -> void:
	_view.call("poke")
	_book.call("poke")
	if not is_busy():
		_caption.call("peek", caption_hover_s)
		_book_btn.call("peek", caption_hover_s)


func _on_stamp_pressed() -> void:
	if bool(_view.call("is_open")):
		# clicking the stamp while a card is up sends the card back into it — but not right after it opened
		# or while it is still flying（双击、连点不会把刚打开的卡收回去，LSHU-4）
		if bool(_view.call("is_animating")) or float(Time.get_ticks_msec() - _opened_at_ms) / 1000.0 < STAMP_CLOSE_GUARD_S:
			return
		_view.call("close", "click")
		return
	stamp_pressed.emit()
	if _unread.is_empty():
		open_book()   # 没有没看过的明信片：邮票就当旅行本的入口（LSHU-3）
		return
	open_postcard(_unread[0] as Dictionary)


func _on_book_closed() -> void:
	_stamp.call("set_suppressed", false)
	_book_btn.call("set_suppressed", false)
	book_toggled.emit(false)


func _on_view_closed(rec: Dictionary, reason: String) -> void:
	var id: String = String(rec.get("id", ""))
	postcard_closed.emit(id, reason)
	if not _book.call("is_open"):
		_book_btn.call("set_suppressed", false)
	var open_s: float = float(Time.get_ticks_msec() - _opened_at_ms) / 1000.0 if _opened_at_ms >= 0 else 999.0
	if open_s < READ_MIN_OPEN_S:
		return   # 一闪就收回：还算没看过，邮票留着（LSHU-4）
	if id != "" and not bool(rec.get("read", false)) and not _read_local.has(id):
		_read_local[id] = true
		postcard_read.emit(id)
	var still: Array = []
	for v: Variant in _unread:
		if String((v as Dictionary).get("id", "")) != id:
			still.append(v)
	_unread = still
	_stamp.call("set_unread", still.size(), {})
	if still.size() > 0:
		_stamp.call("bump")


func _stamp_center() -> Vector2:
	return Rect2(_stamp.position, _stamp.size).get_center()


func _caption_now() -> Dictionary:
	if _on_road:
		var from: String = String(_place.get("name", ""))
		return {"title": ROAD_TITLE, "sub": ROAD_SUB_FMT % from if from != "" else ""}
	if _sleeping:
		var here: String = String(_place.get("name", ""))
		return {"title": SLEEP_TITLE, "sub": SLEEP_SUB_FMT % [here if here != "" else "这里", _wake_label if _wake_label != "" else "六点半"]}
	return D.place_caption(_place)


## 当地时间 H:MM（夜里醒来的时刻），用存档的时区
func _clock_label(unix: int) -> String:
	if unix <= 0:
		return ""
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(unix + tz_s)
	return "%d:%02d" % [int(d.hour), int(d.minute)]


func _place_from_leg(leg: Dictionary) -> Dictionary:
	return {"tile": leg.get("tile", ""), "place": leg.get("place", ""), "name": leg.get("name", ""),
		"home": bool(leg.get("home", false)), "night": bool(leg.get("night", false)), "sub": String(leg.get("sub", "")),
		"kit": leg.get("kit", "")}


func _place_from_event(e: Dictionary) -> Dictionary:
	var p: Dictionary = {"tile": e.get("tile", ""), "place": e.get("place", ""), "name": e.get("name", ""),
		"home": bool(e.get("home", false)), "night": bool(e.get("night", false))}
	var tile: String = String(e.get("tile", ""))
	var cur: Dictionary = save.get("current_leg", {}) as Dictionary
	if tile != "" and String(cur.get("tile", "")) == tile:
		p["sub"] = String(cur.get("sub", ""))
	elif _places_by_tile.has(tile):
		p["sub"] = String((_places_by_tile[tile] as Dictionary).get("sub", ""))
	return p


func _queue_layout() -> void:
	if _layout_queued:
		return
	_layout_queued = true
	_apply_layout.call_deferred()


func _apply_layout() -> void:
	_layout_queued = false
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	_vp = vp.get_visible_rect().size
	_ppu = S.pixels_per_unit(vp)
	_s = S.ui_scale(_vp, _ppu)
	for c: Control in [_caption, _stamp, _book_btn, _view, _book, _away]:
		c.call("layout", _vp, _s, _ppu)


static func _rect_arr(r: Rect2) -> Array:
	return [snappedf(r.position.x, 0.1), snappedf(r.position.y, 0.1), snappedf(r.size.x, 0.1), snappedf(r.size.y, 0.1)]
