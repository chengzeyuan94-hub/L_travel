extends RefCounted
## Act 4 「L叔在哪儿」 UI: pure data helpers, no nodes. Turns the save dict, postcard records and
## resolve() events into the strings and groupings the UI shows. Reads, read only: the postcard line
## library (stamp labels, city lookup rules), a tile's lshu.tile.v1 JSON (only its place.city) and the
## city lore / cities files named by the library. Names no tile, place or asset id.

const LshuClock := preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const LshuPostcardText := preload("res://scripts/traveler/lshu/loop/lshu_postcard_text.gd")

const LINES_JSON: String = "res://data/traveler/lshu/postcard_lines.json"
const TILES_DIR: String = "res://data/traveler/lshu/tiles"
const DEFAULT_SLOT_LABELS: Dictionary = {"morning": "晨", "day": "昼", "sunset": "昏", "night": "夜"}
const DEFAULT_DATE_FORMAT: String = "{year}年{month}月{day}日"
const HOME_WORD: String = "回家"
## 还没出过门的那一段（第一次打开、他在家时点他拍的照片）：写「在家」，不是「回家」（LSHU-12）
const HOME_STAY_WORD: String = "在家"
const NIGHT_MARK: String = "（过夜）"
const LONG_WAY_WORD: String = "走了很远的路"
const MORE_MARK: String = "…"

static var _lines: Dictionary = {}
static var _lines_loaded: bool = false
static var _tile_city: Dictionary = {}          # tile id -> city display name ("" = nature place)
static var _epithets: Dictionary = {}           # city display name -> epithet ("" = none or blocked)
static var _epithets_loaded: bool = false


# ============================================================================== library / time

## postcard_lines.json (the rich library). Loaded once; LshuUi.configure() can hand in the copy
## LshuClock.load_config() already read (cfg.postcard_lines).
static func lines_library() -> Dictionary:
	if not _lines_loaded:
		_lines_loaded = true
		_lines = _read_json(LINES_JSON)
	return _lines


static func set_lines_library(lib: Dictionary) -> void:
	if not lib.is_empty():
		_lines = lib
		_lines_loaded = true
		_epithets_loaded = false
		_epithets = {}


## Seconds east of UTC used for every date the UI prints: loop.json's tz_offset_minutes when set
## (tests pin it), else the machine's zone the same way the clock computes it.
static func tz_from_config(cfg: Dictionary) -> int:
	var tz: Variant = cfg.get("tz_offset_minutes", null)
	if tz != null and (tz is float or tz is int):
		return int(tz) * 60
	return LshuClock.system_tz_offset_s()


static func local_dt(unix: int, tz_s: int) -> Dictionary:
	return Time.get_datetime_dict_from_unix_time(unix + tz_s)


## "9月23日", "9月23日–24日", "9月30日–10月1日"; the year is written only when it is not the
## current one ("2025年12月31日–2026年1月1日").
static func date_range_label(from_unix: int, to_unix: int, tz_s: int, now_unix: int = -1) -> String:
	if from_unix < 0:
		return ""
	var a: Dictionary = local_dt(from_unix, tz_s)
	var now_year: int = int(local_dt(now_unix if now_unix >= 0 else int(Time.get_unix_time_from_system()), tz_s).year)
	var b: Dictionary = local_dt(maxi(to_unix, from_unix), tz_s)
	var show_year: bool = int(a.year) != now_year or int(b.year) != now_year
	var head: String = ("%d年" % int(a.year) if show_year else "") + "%d月%d日" % [int(a.month), int(a.day)]
	if to_unix < 0 or (int(a.year) == int(b.year) and int(a.month) == int(b.month) and int(a.day) == int(b.day)):
		return head
	if int(a.year) != int(b.year):
		return head + "–%d年%d月%d日" % [int(b.year), int(b.month), int(b.day)]
	if int(a.month) != int(b.month):
		return head + "–%d月%d日" % [int(b.month), int(b.day)]
	return head + "–%d日" % int(b.day)


## "40 分钟", "约 5 小时", "约 3 天".
static func gap_label(gap_s: float) -> String:
	if gap_s < 3600.0:
		return "%d 分钟" % maxi(1, roundi(gap_s / 60.0))
	if gap_s < 86400.0:
		return "约 %d 小时" % maxi(1, roundi(gap_s / 3600.0))
	return "约 %d 天" % maxi(1, roundi(gap_s / 86400.0))


# ============================================================================== postmark

static func slot_label(band: String, lib: Dictionary = {}) -> String:
	var L: Dictionary = lib if not lib.is_empty() else lines_library()
	var stamp: Dictionary = L.get("stamp", {}) as Dictionary
	var labels: Dictionary = stamp.get("slot_labels", DEFAULT_SLOT_LABELS) as Dictionary
	var aliases: Dictionary = ((L.get("input_contract", {}) as Dictionary).get("slot", {}) as Dictionary).get("aliases", {}) as Dictionary
	var key: String = String(aliases.get(band, band))
	return String(labels.get(key, labels.get(band, "")))


## What the round postmark on a postcard back shows: {place, date, band_label, home_mark, time}.
static func postmark_info(pc: Dictionary, tz_s: int, lib: Dictionary = {}) -> Dictionary:
	var L: Dictionary = lib if not lib.is_empty() else lines_library()
	var stamp: Dictionary = L.get("stamp", {}) as Dictionary
	var date: String = _s(pc.get("date", ""))
	var unix: int = int(pc.get("unix", -1)) if (pc.get("unix", null) is float or pc.get("unix", null) is int) else -1
	if unix >= 0:
		var dt: Dictionary = local_dt(unix, tz_s)
		date = String(stamp.get("date_format", DEFAULT_DATE_FORMAT)).format({"year": int(dt.year), "month": int(dt.month), "day": int(dt.day)})
	# the loop stores the composed stamp on the record (LshuPostcardText.stamp); older records
	# without it fall back to the same rules here
	var rec_stamp: Dictionary = pc.get("stamp", {}) as Dictionary if pc.get("stamp") is Dictionary else {}
	if date == "" and _s(rec_stamp.get("date", "")) != "":
		date = _s(rec_stamp.date)
	var name: String = _s(rec_stamp.get("title", ""))
	if name == "":
		name = _s(pc.get("name", ""))
	if name == "":
		name = _s(pc.get("place", ""))
	var short: String = name.get_slice(" · ", 0).strip_edges() if name.contains(" · ") else name
	var band_label: String = _s(rec_stamp.get("slot_label", ""))
	if band_label == "":
		band_label = slot_label(_s(pc.get("band", "")), L)
	var home_mark: String = String(stamp.get("home_mark", "家")) if bool(pc.get("home", false)) else ""
	if rec_stamp.has("home_mark"):
		home_mark = _s(rec_stamp.home_mark)
	return {
		"place": short,
		"place_full": name,
		"date": date,
		"band_label": band_label,
		"home_mark": home_mark,
		"time": _s(pc.get("time", "")),
	}


## The 1–2 lines in L叔's voice. They were composed when the postcard was made (record.text); the UI
## never invents text.
static func postcard_lines(pc: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var t: Variant = pc.get("text", [])
	if t is Array:
		for v: Variant in t as Array:
			var s: String = _s(v).strip_edges()
			if s != "":
				out.append(s)
	elif t is String and String(t).strip_edges() != "":
		out.append(String(t).strip_edges())
	return out


static func signature(pc: Dictionary) -> String:
	var sig: String = _s(pc.get("signature", ""))
	if sig != "":
		return sig
	var s: Variant = lines_library().get("signature", "L")
	if s is Dictionary:
		return _s((s as Dictionary).get("text", "L"))
	return _s(s) if _s(s) != "" else "L"


# ============================================================================== place caption

## Caption for a place: {title, sub}. `place` may be a resolve() event, r.leg, a places[] entry or
## a hand-made {name, sub}. Sub follows postcard_lines.json stamp.caption: a city place shows its
## city_lore epithet (omitted while that epithet is CONTENT_BLOCKED); a nature place shows its own
## one-line `sub`; a city place never shows `sub` (that text is a modelling note).
static func place_caption(place: Dictionary) -> Dictionary:
	var title: String = _s(place.get("name", ""))
	if title == "":
		title = _s(place.get("place_name", place.get("place", "")))
	if place.has("caption_sub"):
		return {"title": title, "sub": _s(place.caption_sub)}
	var city: String = _s(place.get("city", ""))
	if city == "":
		city = tile_city(_s(place.get("tile", place.get("id", ""))))
	var sub: String = ""
	if city != "":
		sub = city_epithet(city)
	else:
		sub = _s(place.get("sub", ""))
	return {"title": title, "sub": sub}


## The city display name a tile's place belongs to ("" for nature places). Reads only the small
## "place" object out of data/traveler/lshu/tiles/<id>.json; cached per tile.
static func tile_city(tile_id: String) -> String:
	if tile_id == "":
		return ""
	if _tile_city.has(tile_id):
		return _tile_city[tile_id]
	var city: String = ""
	var path: String = TILES_DIR.path_join(tile_id + ".json")
	if FileAccess.file_exists(path):
		var text: String = FileAccess.get_file_as_string(path)
		var re: RegEx = RegEx.new()
		re.compile("\"place\"\\s*:\\s*(\\{[^{}]*\\})")
		var m: RegExMatch = re.search(text)
		if m != null:
			var parsed: Variant = JSON.parse_string(m.get_string(1))
			if parsed is Dictionary:
				city = _s((parsed as Dictionary).get("city", ""))
	_tile_city[tile_id] = city
	return city


static func city_epithet(city_display_name: String) -> String:
	if not _epithets_loaded:
		_epithets_loaded = true
		_load_epithets()
	return String(_epithets.get(city_display_name, ""))


static func _load_epithets() -> void:
	_epithets = {}
	var lookup: Dictionary = ((lines_library().get("stamp", {}) as Dictionary).get("city_lookup", {}) as Dictionary)
	var lore_path: String = String(lookup.get("lore_file", "res://data/rulesets/lshu_configurable_v1/presentation/city_lore_v1.json"))
	var cities_path: String = String(lookup.get("cities_file", "res://data/rulesets/lshu_configurable_v1/cities.json"))
	var blocked_status: String = String(lookup.get("blocked_status", "CONTENT_BLOCKED"))
	var show_blocked: bool = String(lookup.get("blocked_policy", "omit")) == "show"
	var lore: Dictionary = _read_json(lore_path)
	var cities: Dictionary = _read_json(cities_path)
	var by_id: Dictionary = {}
	for it: Variant in lore.get("items", []) as Array:
		var d: Dictionary = it
		var blocked: bool = String(d.get("verification_status", "")) == blocked_status
		by_id[_s(d.get("city_id", d.get("id", "")))] = "" if (blocked and not show_blocked) else _s(d.get("epithet", ""))
	for it: Variant in cities.get("items", []) as Array:
		var c: Dictionary = it
		var id: String = _s(c.get("id", ""))
		if by_id.has(id):
			_epithets[_s(c.get("display_name", ""))] = by_id[id]


# ============================================================================== travel book

## Trips for the travel book, newest first. Each trip:
##   {trip, from, to, date_label, stops:[{k, name, night, home, arrive, long_way, current, postcard}],
##    summary, places, more, home, in_progress, postcards}
## Built from save.log (leg rows, compacted trip rows, long_way rows) plus save.current_leg; postcards
## hang on their leg, or on their trip once that trip was compacted into one row. Only postcards that
## already have an image are attached. A trip with no travelled stop and no postcard (the first
## launch at home) is left out. No counts are produced.
static func build_trips(save: Dictionary, tz_s: int, now_unix: int = -1) -> Array:
	var pcs_by_leg: Dictionary = {}
	var pcs_by_trip: Dictionary = {}
	for v: Variant in save.get("postcards", []) as Array:
		var pc: Dictionary = v
		if _s(pc.get("file", "")) == "":
			continue
		# one thumbnail per stop: the loop's postcard wins over a click-him photo (type "snap") of the same stop
		var lk: int = int(pc.get("leg", -1))
		if not (_s(pc.get("type", "")) == "snap" and pcs_by_leg.has(lk)):
			pcs_by_leg[lk] = pc
		var tk: int = int(pc.get("trip", -1))
		if not pcs_by_trip.has(tk):
			pcs_by_trip[tk] = []
		(pcs_by_trip[tk] as Array).append(pc)
	var trips: Dictionary = {}
	var max_k: int = -1
	for v: Variant in save.get("log", []) as Array:
		var e: Dictionary = v
		var kind: String = _s(e.get("type", "leg"))
		var t: Dictionary = _trip(trips, int(e.get("trip", 0)))
		if kind == "leg":
			var k: int = int(e.get("k", -1))
			max_k = maxi(max_k, k)
			(t.stops as Array).append(_stop(e, k, pcs_by_leg))
		elif kind == "trip":
			t["summary"] = true
			t["from"] = int(e.get("from", -1))
			t["to"] = int(e.get("to", -1))
			t["places"] = (e.get("places", []) as Array).duplicate()
			t["stops_total"] = int(e.get("stops", 0))
			t["home"] = bool(e.get("home", false))
		elif kind == "long_way":
			(t.stops as Array).append({"k": -1, "name": LONG_WAY_WORD, "night": false, "home": false,
				"arrive": int(e.get("to", -1)), "long_way": true, "current": false, "postcard": {}})
	var cur: Dictionary = save.get("current_leg", {}) as Dictionary
	if not cur.is_empty() and int(cur.get("index", -1)) > max_k:
		var ct: Dictionary = _trip(trips, int(cur.get("trip", 0)))
		var st: Dictionary = _stop(cur, int(cur.get("index", -1)), pcs_by_leg)
		st["current"] = true
		(ct.stops as Array).append(st)
		ct["in_progress"] = true
	var keys: Array = trips.keys()
	keys.sort()
	keys.reverse()
	var out: Array = []
	for key: Variant in keys:
		var t: Dictionary = trips[key]
		var stops: Array = t.stops
		var travelled: bool = false
		var any_pc: bool = false
		for sv: Variant in stops:
			var sd: Dictionary = sv
			if not bool(sd.home) and not bool(sd.long_way):
				travelled = true
			if not (sd.postcard as Dictionary).is_empty():
				any_pc = true
		if bool(t.summary):
			t["postcards"] = pcs_by_trip.get(int(key), []) as Array
			travelled = travelled or int(t.get("stops_total", 0)) > 0
			any_pc = any_pc or not (t.postcards as Array).is_empty()
			if not stops.is_empty():
				t["to"] = maxi(int(t.to), int((stops[stops.size() - 1] as Dictionary).arrive))
		if not travelled and not any_pc:
			continue
		if not travelled:
			for sv2: Variant in stops:
				if bool((sv2 as Dictionary).get("home", false)):
					(sv2 as Dictionary)["home_word"] = HOME_STAY_WORD
		if not bool(t.summary):
			t["from"] = int((stops[0] as Dictionary).arrive)
			var last: Dictionary = stops[stops.size() - 1]
			t["to"] = int(last.arrive)
			t["home"] = bool(last.home)
		else:
			t["more"] = int(t.get("stops_total", 0)) > (t.places as Array).size()
		t["date_label"] = date_range_label(int(t.from), int(t.to), tz_s, now_unix)
		out.append(t)
	return out


## One line of text for a trip, in the book's order:
## "9月23日–24日：甲地 → 乙地（过夜）→ … → 回家". The book lays the same items out with
## thumbnails; this string is what tests and logs read.
static func route_items(trip: Dictionary) -> PackedStringArray:
	var parts: PackedStringArray = PackedStringArray()
	if bool(trip.get("summary", false)):
		for n: Variant in trip.get("places", []) as Array:
			parts.append(_s(n))
		for sv: Variant in trip.get("stops", []) as Array:
			var sd: Dictionary = sv
			if bool(sd.long_way):
				parts.append(LONG_WAY_WORD)
		if bool(trip.get("more", false)):
			parts.append(MORE_MARK)
		if bool(trip.get("home", false)):
			parts.append(HOME_WORD)
		return parts
	for sv: Variant in trip.get("stops", []) as Array:
		parts.append(stop_label(sv as Dictionary))
	if bool(trip.get("in_progress", false)) and not bool(trip.get("home", false)):
		parts.append(MORE_MARK)
	return parts


static func stop_label(st: Dictionary) -> String:
	if bool(st.get("long_way", false)):
		return LONG_WAY_WORD
	if bool(st.get("home", false)):
		return String(st.get("home_word", HOME_WORD))
	return _s(st.get("name", "")) + (NIGHT_MARK if bool(st.get("night", false)) else "")


static func route_text(trip: Dictionary) -> String:
	var joined: String = " → ".join(route_items(trip)).replace("） → ", "）→ ")
	return _s(trip.get("date_label", "")) + "：" + joined


static func _trip(trips: Dictionary, idx: int) -> Dictionary:
	if not trips.has(idx):
		trips[idx] = {"trip": idx, "from": -1, "to": -1, "date_label": "", "stops": [], "summary": false,
			"places": [], "more": false, "home": false, "in_progress": false, "postcards": [], "stops_total": 0}
	return trips[idx]


static func _stop(e: Dictionary, k: int, pcs_by_leg: Dictionary) -> Dictionary:
	return {"k": k, "name": _s(e.get("name", e.get("place", ""))), "night": bool(e.get("night", false)),
		"home": bool(e.get("home", false)), "arrive": int(e.get("arrive", -1)), "long_way": false,
		"current": false, "postcard": pcs_by_leg.get(k, {}) as Dictionary}


# ============================================================================== while you were away

## Places for the 「你不在的时候」 route, oldest first: catchup.places (the last <= 8 he arrived at)
## minus the place he is at now (the card says that on its own line), led by "…" when more were
## passed than listed.
static func away_places(catchup: Dictionary, current_name: String) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	var places: Array = catchup.get("places", []) as Array
	for n: Variant in places:
		names.append(_s(n))
	if names.size() > 0 and names[names.size() - 1] == current_name:
		names.remove_at(names.size() - 1)
	if names.size() > 0 and int(catchup.get("places_total", places.size())) > places.size():
		names.insert(0, MORE_MARK)
	return names


## Text for the 「你不在的时候」 card from a catchup event: {title, when, body, now}.
static func away_text(catchup: Dictionary, current_name: String) -> Dictionary:
	var places: Array = catchup.get("places", []) as Array
	var names: PackedStringArray = away_places(catchup, current_name)
	var body: String = ("他走过了 " + " → ".join(names)) if not names.is_empty() else ""
	var now_line: String = ""
	if current_name != "":
		if bool(catchup.get("far_jump", false)):
			now_line = "他走了很远的路，现在在%s。" % current_name
		elif places.is_empty():
			now_line = "他一直在%s。" % current_name
		else:
			now_line = "现在他在%s。" % current_name
	return {"title": "你不在的时候", "when": "你离开了" + gap_label(float(catchup.get("gap_s", 0.0))),
		"body": body, "now": now_line}


## L叔's one line on the 「你不在的时候」 card. postcard_lines.json compose.away_card: one road-category
## line, no time line, under the same no-repeat window as the postcards (history = the save's last
## postcards' line_ids). Same catchup, same line: key [save.seed, "away", catchup.to]. band / kit only
## feed the library's avoid filters. {} when the library has no composition rules.
## Returns {text, line_ids, signature}. The line is not written into the save (the UI never writes it);
## LshuUi emits away_line_shown(line_ids) for a director that wants to remember it.
static func away_line(save: Dictionary, catchup: Dictionary, band: String = "", kit: Variant = "") -> Dictionary:
	var lib: Dictionary = LshuPostcardText.rich_of(lines_library())
	if lib.is_empty():
		return {}
	var history: Array = LshuPostcardText.history_from_postcards(save.get("postcards", []) as Array, LshuPostcardText.window(lib))
	var at: Variant = catchup.get("to", catchup.get("at", 0))
	var key: Array = [int(save.get("seed", 0)) if (save.get("seed") is int or save.get("seed") is float) else 0, "away",
		int(floor(float(at))) if (at is int or at is float) else 0]
	var k: Variant = kit if _s(kit) != "" else "look"
	var card: Dictionary = LshuPostcardText.away_card(lib, history, key, band if band != "" else "day", k)
	var text: String = _s(card.get("text", "")).strip_edges()
	if text == "":
		return {}
	return {"text": text, "line_ids": (card.get("line_ids", []) as Array).duplicate(), "signature": signature({})}


# ============================================================================== helpers

static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## JSON values to String (numbers come back as floats): 3.0 -> "3", null -> "".
static func _s(v: Variant) -> String:
	if v is String:
		return v
	if v == null:
		return ""
	if v is float and is_equal_approx(float(v), roundf(float(v))) and absf(float(v)) < 1.0e15:
		return str(int(v))
	return str(v)
