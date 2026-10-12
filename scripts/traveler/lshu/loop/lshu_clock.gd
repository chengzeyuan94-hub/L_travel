extends RefCounted
## Act 4 「L叔在哪儿」: L叔's own real-time clock. Pure and deterministic, no scene dependencies.
##
##   var cfg: Dictionary = LshuClock.load_config()                  # loop.json (+ postcard lines)
##   var r: Dictionary = LshuClock.resolve(save, now_unix, places, cfg)
##   r.save      -> the new save to persist (the input is never mutated)
##   r.leg       -> the stop on screen now (tile id, place, kit, times ...)
##   r.substate  -> ARRIVE / STAY / NIGHT / HOME / LEAVE / ROAD, with substate_t seconds into it
##   r.events    -> transitions crossed since save.last_seen_unix (see README.md)
##   r.light     -> {preset_a, preset_b, blend, band, weights}
##
## Stop k is generated from hash(seed, k) plus the planner state carried in the save, so the
## journey is the same whether the program was open or closed. Every time comes from the system
## clock; nothing accumulates frame deltas. No tile, place or asset id appears in this file: the
## list of tiles comes in as `places` (see README.md for the fields).

const LshuHash := preload("res://scripts/traveler/lshu/loop/lshu_hash.gd")
const LshuSave := preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const LshuPostcardText := preload("res://scripts/traveler/lshu/loop/lshu_postcard_text.gd")

const LOOP_JSON: String = "res://data/traveler/lshu/loop.json"
const LINES_JSON: String = "res://data/traveler/lshu/postcard_lines.json"
const SAVE_SCHEMA: String = "lshu.where.save.v1"
const DAY: int = 86400

const ARRIVE: String = "ARRIVE"
const STAY: String = "STAY"
const LEAVE: String = "LEAVE"
const ROAD: String = "ROAD"
const NIGHT: String = "NIGHT"
const HOME: String = "HOME"

# Hash salts: one independent stream per decision.
const S_WALK_IN: int = 101
const S_STAY: int = 102
const S_ROAD: int = 103
const S_LONG: int = 104
const S_LONG_LEN: int = 105
const S_WALK_OUT: int = 106
const S_MORNING: int = 107
const S_PC: int = 108
const S_PC_AT: int = 109
const S_PC_SHOT: int = 110
const S_PC_LINE: int = 111
const S_PLACE: int = 112
const S_TILE: int = 113
const S_WANDER_N: int = 114
const S_WANDER: int = 115
const S_TRIP: int = 116
const S_FIRST: int = 117
const S_SEED: int = 118

# Order of events that share a timestamp inside one stop.
const EVENT_ORDER: Dictionary = {
	"light_blend": -1, "arrive": 0, "home_arrive": 0, "settle": 1, "wander_start": 2, "wander_end": 3,
	"postcard": 4, "night_start": 5, "tent_in": 6, "night_end": 7, "leave": 8, "home_leave": 8,
	"road_start": 9, "road_end": 10,
}


# =============================================================================================
# Config

static func load_config(path: String = LOOP_JSON, lines_path: String = LINES_JSON) -> Dictionary:
	var cfg: Dictionary = _read_json(path)
	if cfg.is_empty():
		return {}
	var lines: Dictionary = _read_json(lines_path)
	if not lines.is_empty():
		cfg["postcard_lines"] = lines
	return cfg


## Turns loop.json into seconds. Cheap; resolve() calls it every time so edits to cfg apply at once.
static func compile_config(cfg: Dictionary) -> Dictionary:
	var c: Dictionary = {}
	var stop: Dictionary = cfg.get("stop", {}) as Dictionary
	c["stay"] = _range_s(stop.get("stay_min", [30, 60]), 60.0)
	c["walk_in"] = _range_s(stop.get("arrive_walk_s", [20, 40]), 1.0)
	c["walk_out"] = _range_s(stop.get("leave_walk_s", [20, 40]), 1.0)
	var road: Dictionary = cfg.get("road", {}) as Dictionary
	c["road"] = _range_s(road.get("min", [4, 12]), 60.0)
	c["long_chance"] = float(road.get("long_chance", 0.15))
	c["long_road"] = _range_s(road.get("long_min", [30, 60]), 60.0)
	var night: Dictionary = cfg.get("night", {}) as Dictionary
	c["cutoff"] = _hm(night.get("no_departure_after", "21:30"))
	c["resume"] = _hm(night.get("departures_resume", "07:00"))
	# Night offsets are measured from 00:00 of the evening's calendar day.
	var doze: int = _hm(night.get("doze_from", "21:30"))
	if doze < c.resume:
		doze += DAY
	c["doze_off"] = doze
	var tent: int = _hm(night.get("tent_at", "23:30"))
	while tent < doze:
		tent += DAY
	c["tent_off"] = tent
	var back: int = _hm(night.get("back_to_fire", "06:30"))
	while back < tent:
		back += DAY
	c["back_off"] = back
	c["overnight_depart"] = _range_hm(night.get("overnight_depart", ["07:00", "08:30"]), DAY)
	var trip: Dictionary = cfg.get("trip", {}) as Dictionary
	c["trip_stops"] = _range_int(trip.get("stops", [12, 24]))
	c["home_after"] = _hm(trip.get("home_after", "16:00"))
	c["trip_max"] = int(trip.get("max_stops", 40))
	var home: Dictionary = cfg.get("home", {}) as Dictionary
	c["home_depart"] = _range_hm(home.get("depart", ["08:00", "11:00"]), DAY)
	var first: Dictionary = cfg.get("first_launch", {}) as Dictionary
	c["first_depart"] = _range_s(first.get("depart_after_min", [5, 15]), 60.0)
	c["first_settled"] = int(round(float(first.get("settled_for_min", 60)) * 60.0))
	var pcs: Dictionary = cfg.get("postcards", {}) as Dictionary
	c["pc_day"] = float(pcs.get("day_chance", 0.25))
	c["pc_night"] = float(pcs.get("overnight_chance", 0.40))
	c["pc_home"] = float(pcs.get("home_chance", 0.40))
	var win: Array = pcs.get("window", [0.2, 0.8]) as Array
	c["pc_window"] = [float(win[0]), float(win[1])]
	var shots: Dictionary = pcs.get("shots", {"far": 0.4, "mid": 0.4, "back": 0.2}) as Dictionary
	var shot_names: Array = shots.keys()
	shot_names.sort()
	var shot_list: Array = []
	for n: Variant in shot_names:
		shot_list.append([_str(n), float(shots[n])])
	c["pc_shots"] = shot_list
	c["pc_max_catchup"] = int(pcs.get("max_catchup", 3))
	c["pc_max_pending"] = int(pcs.get("max_pending", 3))
	var cu: Dictionary = cfg.get("catchup", {}) as Dictionary
	c["max_catchup_stops"] = int(cu.get("max_stops", 3000))
	c["live_gap"] = float(cu.get("live_gap_s", 180))
	c["away_after"] = float(cu.get("away_card_after_s", 7200))
	c["away_places"] = int(cu.get("away_card_places", 8))
	var wd: Dictionary = cfg.get("wander", {}) as Dictionary
	c["wander_on"] = bool(wd.get("enabled", true))
	c["wander_count"] = _range_int(wd.get("count", [0, 2]))
	c["wander_stand"] = _range_s(wd.get("stand_min", [1, 3]), 60.0)
	c["wander_walk"] = int(wd.get("walk_s", 25))
	c["wander_min_window"] = int(round(float(wd.get("min_window_min", 12)) * 60.0))
	var pl: Dictionary = cfg.get("planner", {}) as Dictionary
	c["avoid_recent"] = int(pl.get("avoid_recent", 4))
	c["recent_keep"] = maxi(int(pl.get("recent_keep", 8)), int(c.avoid_recent))
	c["layout_repeat"] = float(pl.get("layout_repeat_factor", 0.25))
	c["tile_repeat"] = float(pl.get("tile_repeat_factor", 0.5))
	var lc: Dictionary = {}
	var lc_in: Dictionary = pl.get("layout_classes", {}) as Dictionary
	for key: Variant in lc_in.keys():
		lc[_str(key)] = _str(lc_in[key])
	c["layout_classes"] = lc
	var kits: Dictionary = cfg.get("kits", {}) as Dictionary
	var names: Array = []
	for n: Variant in kits.get("names", ["look", "camp", "tea", "encounter"]) as Array:
		names.append(_str(n))
	c["kit_names"] = names
	var alias: Dictionary = {}
	var alias_in: Dictionary = kits.get("aliases", {}) as Dictionary
	for key: Variant in alias_in.keys():
		alias[_str(key)] = _str(alias_in[key])
	c["kit_alias"] = alias
	c["fire_weights"] = _weights(kits.get("fire", {"camp": 3, "tea": 2}))
	c["night_needs_fire"] = bool(kits.get("night_band_needs_fire", true))
	c["unlisted_w"] = float(kits.get("unlisted_weight", 0.2))
	var by_time: Array = []
	for row: Variant in kits.get("by_time", []) as Array:
		var rd: Dictionary = row
		by_time.append({"from": _hm(rd.get("from", "00:00")), "to": _hm(rd.get("to", "00:00")),
			"weights": _weights(rd.get("weights", {}))})
	c["kit_by_time"] = by_time
	var light: Dictionary = cfg.get("light", {}) as Dictionary
	var bands: Array = []
	for row: Variant in light.get("bands", _default_bands()) as Array:
		var bd: Dictionary = row
		bands.append({"preset": _str(bd.get("preset", "")), "from": _hm(bd.get("from", "00:00")),
			"blend": int(round(float(bd.get("blend_min", 30)) * 60.0))})
	bands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.from) < int(b.from))
	# Keep neighbouring blends from overlapping.
	var nb: int = bands.size()
	for i: int in nb:
		var here: int = int(bands[i].from)
		var prev_from: int = int(bands[(i - 1 + nb) % nb].from)
		var next_from: int = int(bands[(i + 1) % nb].from)
		var gap_prev: int = posmod(here - prev_from, DAY) if nb > 1 else DAY
		var gap_next: int = posmod(next_from - here, DAY) if nb > 1 else DAY
		bands[i]["blend"] = mini(int(bands[i].blend), mini(gap_prev, gap_next))
	c["bands"] = bands
	c["night_preset"] = _band_index_preset(bands, 0.0)
	c["log_cap"] = int((cfg.get("log", {}) as Dictionary).get("cap", 500))
	var tz: Variant = cfg.get("tz_offset_minutes", null)
	if tz == null:
		c["tz_s"] = system_tz_offset_s()
	else:
		c["tz_s"] = int(round(float(tz) * 60.0))
	c["lines"] = LshuPostcardText.normalize_library(cfg.get("postcard_lines", {}) as Dictionary)
	return c


## Current offset of the local wall clock from UTC, in seconds. Derived from the local datetime
## rather than Time.get_time_zone_from_system().bias, which Godot 4.7 gets wrong by an hour in
## negative half-hour zones (America/St_Johns reports -90 min instead of -150).
static func system_tz_offset_s() -> int:
	var local: Dictionary = Time.get_datetime_dict_from_system()
	var now: int = int(floor(Time.get_unix_time_from_system()))
	var off: int = int(Time.get_unix_time_from_datetime_dict(local)) - now
	return int(round(float(off) / 60.0)) * 60


# =============================================================================================
# Pool

## places: Array of Dictionaries {id, place, kit, layout, biome, is_home, night_ok, ...}.
static func index_pool(places: Array, c: Dictionary) -> Dictionary:
	var tiles: Dictionary = {}
	var warnings: Array = []
	for raw: Variant in places:
		if not (raw is Dictionary):
			continue
		var e: Dictionary = _norm_tile(raw as Dictionary, c)
		if String(e.id) == "" or bool(e.blocked):
			continue
		if tiles.has(e.id):
			warnings.append("duplicate_tile:" + String(e.id))
			continue
		tiles[e.id] = e
	var ids: Array = tiles.keys()
	ids.sort()
	var by_place: Dictionary = {}
	var home_places: Dictionary = {}
	for id: Variant in ids:
		var e: Dictionary = tiles[id]
		if bool(e.is_home):
			home_places[e.place] = true
		if not by_place.has(e.place):
			by_place[e.place] = {"tiles": [], "fire": false, "night_ok": false, "fire_night": false}
		var p: Dictionary = by_place[e.place]
		(p.tiles as Array).append(e)
		if bool(e.fire):
			p["fire"] = true
		if bool(e.night_ok):
			p["night_ok"] = true
		if bool(e.fire) and bool(e.night_ok):
			p["fire_night"] = true
	var home_tiles: Array = []
	for id: Variant in ids:
		if bool((tiles[id] as Dictionary).is_home):
			home_tiles.append(tiles[id])
	if home_tiles.is_empty() and not ids.is_empty():
		# No home entry supplied: fall back to one place deterministically (first place with fire).
		warnings.append("no_home_tile")
		var names: Array = by_place.keys()
		names.sort()
		var chosen: String = String(names[0])
		for n: Variant in names:
			if bool((by_place[n] as Dictionary).fire_night):
				chosen = String(n)
				break
		home_places[chosen] = true
		home_tiles = ((by_place[chosen] as Dictionary).tiles as Array).duplicate()
	var trip_places: Array = []
	for n: Variant in by_place.keys():
		if not home_places.has(n):
			trip_places.append(String(n))
	trip_places.sort()
	if trip_places.is_empty():
		warnings.append("no_trip_places")
		for n: Variant in by_place.keys():
			trip_places.append(String(n))
		trip_places.sort()
	return {"tiles": tiles, "by_place": by_place, "trip_places": trip_places, "home_tiles": home_tiles,
		"home_places": home_places.keys(), "warnings": warnings}


static func _norm_tile(raw: Dictionary, c: Dictionary) -> Dictionary:
	var id: String = _str(raw.get("id", ""))
	var place: String = _str(raw.get("place", id))
	var kit: String = _norm_kit(raw.get("kit", ""), c)
	var layout_v: Variant = raw.get("layout", "")
	var layout: String = ""
	if layout_v is int or layout_v is float:
		layout = str(int(layout_v))
	elif layout_v != null:
		layout = _str(layout_v)
	var layout_class: String = _str(raw.get("layout_class", ""))
	if layout_class == "":
		layout_class = _str((c.layout_classes as Dictionary).get(layout, layout))
	var fire_v: Variant = raw.get("fire", null)
	var fire: bool = bool(fire_v) if fire_v != null else (c.fire_weights as Dictionary).has(kit)
	return {
		"id": id, "place": place, "kit": kit, "layout": layout, "layout_class": layout_class,
		"biome": _str(raw.get("biome", "")), "is_home": bool(raw.get("is_home", false)),
		"night_ok": bool(raw.get("night_ok", true)), "fire": fire, "blocked": bool(raw.get("blocked", false)),
		"name": _str(raw.get("name", place)), "sub": _str(raw.get("sub", "")),
	}


static func _norm_kit(v: Variant, c: Dictionary) -> String:
	var names: Array = c.kit_names
	if v is int or v is float:
		var i: int = int(v)
		return String(names[i]) if i >= 0 and i < names.size() else str(i)
	var s: String = _str(v)
	return String((c.kit_alias as Dictionary).get(s, s))


# =============================================================================================
# resolve

static func resolve(save: Dictionary, now_unix: float, places: Array, cfg: Dictionary) -> Dictionary:
	var c: Dictionary = compile_config(cfg)
	var pool: Dictionary = index_pool(places, c)
	var warnings: Array = (pool.warnings as Array).duplicate()
	if (pool.tiles as Dictionary).is_empty():
		return {"ok": false, "error": "empty_pool", "save": save, "events": [], "warnings": warnings}
	var fresh: bool = false
	var s: Dictionary
	var cur_in: Variant = save.get("current_leg", {})
	if save.is_empty() or not (cur_in is Dictionary) or (cur_in as Dictionary).is_empty():
		s = _new_save(save, now_unix, pool, c)
		fresh = true
	elif not _leg_ok(cur_in as Dictionary) or not _is_num(save.get("seed")):
		# The file parsed but its current stop is unusable: start again at home, keep the history.
		s = _rebuild_save(save, now_unix, pool, c)
		fresh = true
		warnings.append("bad_leg_reset")
	else:
		s = _working_copy(save)
		_ensure_fields(s, now_unix)
	var last_seen: float = float(s.get("last_seen_unix", now_unix))
	var t: float = now_unix
	var held: bool = false
	if t < last_seen:
		# Clock rolled back: keep showing the state at last_seen until real time catches up.
		t = last_seen
		held = true
	var gap: float = t - last_seen
	var live: bool = gap <= float(c.live_gap)
	var cur: Dictionary = s.current_leg
	if not (pool.tiles as Dictionary).has(String(cur.get("tile", ""))):
		_apply_tile(cur, _replacement_tile(cur, s, pool, c))
		warnings.append("tile_replaced")
	var touched: Array = [s.current_leg]
	var steps: int = 0
	var far: bool = false
	var log_cap: int = int(c.log_cap)
	while t >= float(int((s.current_leg as Dictionary).road_end)):
		if steps >= int(c.max_catchup_stops):
			far = true
			break
		var done: Dictionary = s.current_leg
		_log_leg(s, done)
		var nxt: Dictionary = _generate_leg(s, pool, c, int(done.road_end), int(done.index) + 1, done)
		_commit_leg(s, nxt, c)
		touched.append(nxt)
		steps += 1
		if (s.log as Array).size() > log_cap + 100:
			s["log"] = LshuSave.compact_log(s.log as Array, log_cap)
	if far:
		# Gone for too long: he "walked a long way" and arrives at a fresh stop right now.
		var done2: Dictionary = s.current_leg
		_log_leg(s, done2)
		(s.log as Array).append({"type": "long_way", "trip": int(done2.trip), "from": int(done2.road_end),
			"to": int(floor(t))})
		var jump: Dictionary = _generate_leg(s, pool, c, int(floor(t)), int(done2.index) + 1, done2)
		_commit_leg(s, jump, c)
		touched.append(jump)
		(s.stats as Dictionary)["far_jumps"] = int((s.stats as Dictionary).get("far_jumps", 0)) + 1
	# Postcards whose moment fell inside (last_seen, t].
	var pc_legs: Array = []
	for leg: Variant in touched:
		var ld: Dictionary = leg
		var pa: int = int(ld.get("postcard_at", -1))
		if pa >= 0 and float(pa) > last_seen and float(pa) <= t:
			pc_legs.append(ld)
	var catchup_dropped: int = 0
	if not live and pc_legs.size() > int(c.pc_max_catchup):
		catchup_dropped = pc_legs.size() - int(c.pc_max_catchup)
		pc_legs = pc_legs.slice(pc_legs.size() - int(c.pc_max_catchup))
	var events: Array = []
	var new_pc_ids: Array = []
	var dropped_pc: Array = []
	for leg: Variant in pc_legs:
		var ld2: Dictionary = leg
		var pc: Dictionary = _make_postcard(ld2, c, int(s.seed), s.postcards as Array)
		if not LshuSave.find_postcard(s, String(pc.id)).is_empty():
			continue
		(s.postcards as Array).append(pc)
		(s.pending_renders as Array).append(pc.id)
		new_pc_ids.append(pc.id)
		dropped_pc.append_array(_cap_pending(s, int(c.pc_max_pending)))
		if live:
			events.append(_event("postcard", int(pc.unix), ld2, {"postcard": pc.id, "shot": pc.shot}))
	if (s.log as Array).size() > log_cap:
		s["log"] = LshuSave.compact_log(s.log as Array, log_cap)
	var catchup: Dictionary = {}
	if fresh:
		events.append(_event("first_launch", int(floor(t)), s.current_leg, {}))
	elif live:
		for leg: Variant in touched:
			events.append_array(_leg_events(leg as Dictionary, last_seen, t))
		events.append_array(_light_events(last_seen, t, c))
	else:
		var arrived: Array = []
		for i: int in range(1, touched.size()):
			var ld3: Dictionary = touched[i]
			if not bool(ld3.home):
				arrived.append(String(ld3.name))
		var shown: Array = arrived.slice(maxi(0, arrived.size() - int(c.away_places)))
		catchup = {"from": last_seen, "to": t, "gap_s": gap, "legs_passed": steps, "far_jump": far,
			"places": shown, "places_total": arrived.size(), "postcards": new_pc_ids,
			"postcards_dropped": catchup_dropped, "show_away_card": gap >= float(c.away_after)}
		events.append(_event("catchup", int(floor(t)), s.current_leg, catchup))
	events.sort_custom(_event_less)
	s["last_seen_unix"] = t
	var leg_now: Dictionary = s.current_leg
	var st: Dictionary = _substate(leg_now, t)
	var result: Dictionary = {
		"ok": true, "save": s, "now": t, "clock_held": held, "fresh": fresh, "live": live,
		"leg": leg_now.duplicate(true), "substate": st.name, "substate_t": t - float(st.t0),
		"substate_len": float(st.t1) - float(st.t0), "night_phase": st.phase,
		"activity": _activity(leg_now, t, String(st.name)),
		"character_visible": not (st.name == ROAD or (st.name == NIGHT and st.phase == "tent")),
		"fire": _fire_state(leg_now, st),
		"events": events, "light": light_at(t, c), "local": local_info(t, c),
		"next_change_unix": _next_change(leg_now, t), "next_tile": {}, "catchup": catchup,
		"new_postcards": new_pc_ids, "dropped_postcards": dropped_pc, "warnings": warnings,
	}
	if st.name == LEAVE or st.name == ROAD:
		var peek: Dictionary = _generate_leg(s, pool, c, int(leg_now.road_end), int(leg_now.index) + 1, leg_now)
		result["next_tile"] = {"tile": peek.tile, "place": peek.place, "name": peek.name, "kit": peek.kit,
			"home": peek.home, "arrive": peek.arrive}
	return result


# =============================================================================================
# Leg generation

static func _new_save(prior: Dictionary, now: float, pool: Dictionary, c: Dictionary) -> Dictionary:
	var seed: int = int(prior.seed) if _is_num(prior.get("seed")) else -1
	if seed < 0:
		seed = LshuHash.hash3(int(floor(now)), int(fmod(now, 1.0) * 1000000.0), S_SEED)
	var t0: int = int(floor(now))
	var s: Dictionary = {
		"schema": SAVE_SCHEMA, "seed": seed, "origin_unix": t0, "leg_index": 0, "current_leg": {},
		"recent_places": [], "visited": {}, "visited_tiles": {}, "last_layout_class": "",
		"trip": {"index": 0, "stops": 0, "target": 0, "started": t0},
		"log": [], "postcards": [], "pending_renders": [], "last_seen_unix": now,
		"stats": {"legs": 0, "far_jumps": 0, "home_nights": 0},
	}
	# First launch: he is already at home, settled, and leaves in 5-15 minutes (never at night).
	var walk_in: int = LshuHash.range_i(seed, 0, S_WALK_IN, int(c.walk_in[0]), int(c.walk_in[1]))
	var settle: int = t0 - int(c.first_settled)
	var leg: Dictionary = {
		"index": 0, "initial": true, "home": true, "trip": 0, "trip_stop": 0, "trip_target": 0,
		"trip_started": t0, "arrive": settle - walk_in, "settle": settle,
	}
	var cand: int = t0 + LshuHash.range_i(seed, 0, S_FIRST, int(c.first_depart[0]), int(c.first_depart[1]))
	_fill_timing(leg, seed, 0, c, cand)
	_apply_tile(leg, _choose_tile(leg, s, pool, c))
	_commit_leg(s, leg, c)
	return s


static func _ensure_fields(s: Dictionary, now: float) -> void:
	for key: String in ["recent_places", "log", "postcards", "pending_renders"]:
		if not (s.get(key) is Array):
			s[key] = []
	for key2: String in ["visited", "visited_tiles", "stats"]:
		if not (s.get(key2) is Dictionary):
			s[key2] = {}
	if not (s.get("trip") is Dictionary):
		s["trip"] = {"index": 0, "stops": 0, "target": 0, "started": int(now)}
	if not s.has("last_seen_unix"):
		s["last_seen_unix"] = now
	s["schema"] = SAVE_SCHEMA


## Copies only what resolve() changes. Log lines and postcard records are shared with the input:
## resolve() never edits one in place (it appends, removes or replaces whole entries), so a deep
## copy would only add cost that grows with the postcard history (about 1800 records a year).
static func _working_copy(save: Dictionary) -> Dictionary:
	var s: Dictionary = save.duplicate(false)
	for key: String in ["log", "postcards", "pending_renders", "recent_places"]:
		if s.get(key) is Array:
			s[key] = (s[key] as Array).duplicate(false)
	for key2: String in ["visited", "visited_tiles", "stats", "trip"]:
		if s.get(key2) is Dictionary:
			s[key2] = (s[key2] as Dictionary).duplicate(false)
	s["current_leg"] = (s.current_leg as Dictionary).duplicate(true)
	return s


const LEG_NUM_KEYS: Array = ["index", "trip", "arrive", "settle", "depart", "road_start", "road_end",
	"night_start", "tent_in", "night_end", "postcard_at"]


static func _is_num(v: Variant) -> bool:
	return v is int or v is float


## True when every field resolve() reads from a stop is present, typed and in order.
static func _leg_ok(leg: Dictionary) -> bool:
	for key: String in LEG_NUM_KEYS:
		if not _is_num(leg.get(key)):
			return false
	if not (leg.get("home") is bool) or not (leg.get("night") is bool) or not (leg.get("tile") is String):
		return false
	if leg.has("wanders") and not (leg.wanders is Array):
		return false
	var a: float = float(leg.arrive)
	var st: float = float(leg.settle)
	var d: float = float(leg.depart)
	var rs: float = float(leg.road_start)
	var re: float = float(leg.road_end)
	return a <= st and st <= d and d <= rs and rs <= re and re - a < 40.0 * float(DAY)


## A save whose current stop is unusable: a new first-launch stop at home (5-15 minutes before he
## sets off), with the old history, visit counts and postcards carried over. Leg and trip numbers
## continue past everything already recorded, so postcard ids and travel-book trips never repeat.
static func _rebuild_save(prior: Dictionary, now: float, pool: Dictionary, c: Dictionary) -> Dictionary:
	var seeded: Dictionary = {}
	if _is_num(prior.get("seed")) and int(prior.seed) >= 0:
		seeded["seed"] = int(prior.seed)
	var s: Dictionary = _new_save(seeded, now, pool, c)
	var max_k: int = int(prior.get("leg_index", 0)) if _is_num(prior.get("leg_index")) else 0
	var max_trip: int = 0
	var old_trip: Variant = prior.get("trip")
	if old_trip is Dictionary and _is_num((old_trip as Dictionary).get("index")):
		max_trip = int((old_trip as Dictionary).index)
	for key: String in ["log", "postcards", "pending_renders", "recent_places"]:
		if prior.get(key) is Array:
			s[key] = (prior[key] as Array).duplicate(true)
	for key2: String in ["visited", "visited_tiles", "stats"]:
		if prior.get(key2) is Dictionary:
			s[key2] = (prior[key2] as Dictionary).duplicate(true)
	for e: Variant in s.log as Array:
		if e is Dictionary:
			var ed: Dictionary = e
			if _is_num(ed.get("k")):
				max_k = maxi(max_k, int(ed.k))
			if _is_num(ed.get("trip")):
				max_trip = maxi(max_trip, int(ed.trip))
	for p: Variant in s.postcards as Array:
		if p is Dictionary and _is_num((p as Dictionary).get("leg")):
			max_k = maxi(max_k, int((p as Dictionary).leg))
	var cur_in: Variant = prior.get("current_leg")
	if cur_in is Dictionary and _is_num((cur_in as Dictionary).get("index")):
		max_k = maxi(max_k, int((cur_in as Dictionary).index))
	var leg: Dictionary = s.current_leg
	leg["index"] = max_k + 1
	leg["trip"] = max_trip
	s["leg_index"] = max_k + 1
	s["trip"] = {"index": max_trip, "stops": 0, "target": 0, "started": int(floor(now))}
	if _is_num(prior.get("origin_unix")):
		s["origin_unix"] = int(prior.origin_unix)
	return s


## The tile on screen left the pool: keep him at the same place when it still has tiles.
static func _replacement_tile(leg: Dictionary, s: Dictionary, pool: Dictionary, c: Dictionary) -> Dictionary:
	var place: String = String(leg.get("place", ""))
	var home: bool = bool(leg.get("home", false))
	if not home and (pool.by_place as Dictionary).has(place):
		var night_preset: String = String(c.night_preset)
		var band_in: String = String(light_at(float(int(leg.settle)), c).band)
		var band_out: String = String(light_at(float(int(leg.depart)), c).band)
		var needs_fire: bool = bool(leg.night) or (bool(c.night_needs_fire) and band_in == night_preset)
		var needs_night_ok: bool = bool(leg.night) or band_in == night_preset or band_out == night_preset
		var weights: Dictionary = c.fire_weights if needs_fire else _kit_weights(float(int(leg.settle)), c)
		return _pick_tile((pool.by_place[place] as Dictionary).tiles, weights, needs_fire, needs_night_ok,
			String(s.get("last_layout_class", "")), s.get("visited_tiles", {}) as Dictionary, int(s.seed), int(leg.index), c)
	return _choose_tile(leg, s, pool, c)


static func _generate_leg(s: Dictionary, pool: Dictionary, c: Dictionary, arrive: int, k: int, prev: Dictionary) -> Dictionary:
	var seed: int = int(s.seed)
	var trip: Dictionary = s.get("trip", {}) as Dictionary
	var trip_index: int = int(trip.get("index", 0))
	var trip_stops: int = int(trip.get("stops", 0))
	var trip_target: int = int(trip.get("target", 0))
	var trip_started: int = int(trip.get("started", arrive))
	if bool(prev.get("home", false)) or trip_target <= 0:
		trip_index += 1
		trip_stops = 0
		trip_target = LshuHash.range_i(seed, trip_index, S_TRIP, int(c.trip_stops[0]), int(c.trip_stops[1]))
		trip_started = arrive
	var home: bool = trip_stops >= int(c.trip_max) or (trip_stops >= trip_target and _after_home_time(float(arrive), c))
	var walk_in: int = LshuHash.range_i(seed, k, S_WALK_IN, int(c.walk_in[0]), int(c.walk_in[1]))
	var settle: int = arrive + walk_in
	var leg: Dictionary = {
		"index": k, "initial": false, "home": home, "trip": trip_index,
		"trip_stop": trip_stops if home else trip_stops + 1, "trip_target": trip_target,
		"trip_started": trip_started, "arrive": arrive, "settle": settle,
		"after_long_road": bool(prev.get("long_road", false)),
	}
	var stay: int = LshuHash.range_i(seed, k, S_STAY, int(c.stay[0]), int(c.stay[1]))
	_fill_timing(leg, seed, k, c, settle + stay)
	_apply_tile(leg, _choose_tile(leg, s, pool, c))
	return leg


## Fills depart / night / road / postcard / wander times. leg already has arrive, settle, home, initial.
static func _fill_timing(leg: Dictionary, seed: int, k: int, c: Dictionary, depart_cand: int) -> void:
	var settle: int = int(leg.settle)
	var home: bool = bool(leg.home)
	var initial: bool = bool(leg.initial)
	var night: bool = false
	var depart: int = depart_cand
	var e: int = 0
	if home and not initial:
		night = true
		e = _night_day_for(float(settle), c)
		depart = _day_start(e, c) + LshuHash.range_i(seed, k, S_MORNING, int(c.home_depart[0]), int(c.home_depart[1]))
	elif _in_night_window(float(depart_cand), c):
		night = true
		e = _night_day_for(float(depart_cand), c)
		var w: Array = c.home_depart if home else c.overnight_depart
		depart = _day_start(e, c) + LshuHash.range_i(seed, k, S_MORNING, int(w[0]), int(w[1]))
	var ns: int = -1
	var ti: int = -1
	var ne: int = -1
	if night:
		ns = maxi(_day_start(e, c) + int(c.doze_off), settle)
		ti = maxi(_day_start(e, c) + int(c.tent_off), ns)
		ne = maxi(_day_start(e, c) + int(c.back_off), ti)
		depart = maxi(depart, maxi(ne + 60, settle + 300))
	var walk_out: int = LshuHash.range_i(seed, k, S_WALK_OUT, int(c.walk_out[0]), int(c.walk_out[1]))
	var long_road: bool = LshuHash.unit(seed, k, S_LONG) < float(c.long_chance)
	var road_s: int
	if long_road:
		road_s = LshuHash.range_i(seed, k, S_LONG_LEN, int(c.long_road[0]), int(c.long_road[1]))
	else:
		road_s = LshuHash.range_i(seed, k, S_ROAD, int(c.road[0]), int(c.road[1]))
	# Postcard moment.
	var chance: float = 0.0
	if not initial:
		chance = float(c.pc_home) if home else (float(c.pc_night) if night else float(c.pc_day))
	var pc_at: int = -1
	if chance > 0.0 and LshuHash.unit(seed, k, S_PC) < chance:
		var lo: int = settle
		var hi: int = depart
		if night:
			hi = ti
			if hi - lo < 120:
				lo = ne
				hi = depart
		if hi - lo >= 60:
			var wf: float = lerpf(float(c.pc_window[0]), float(c.pc_window[1]), LshuHash.unit(seed, k, S_PC_AT))
			pc_at = lo + int(floor(float(hi - lo) * wf))
	var shot: String = _weighted_name(c.pc_shots as Array, LshuHash.unit(seed, k, S_PC_SHOT))
	# Optional short wanders to the landmark during the daytime part of the stay.
	var wanders: Array = []
	if bool(c.wander_on) and not initial:
		var w_lo: int = settle + 120
		var w_hi: int = (mini(ns, depart) if night else depart) - 180
		if w_hi - w_lo >= int(c.wander_min_window):
			var n: int = LshuHash.range_i(seed, k, S_WANDER_N, int(c.wander_count[0]), int(c.wander_count[1]))
			if n > 0:
				var slot: int = (w_hi - w_lo) / n
				for i: int in n:
					var dur: int = 2 * int(c.wander_walk) + LshuHash.range_i(seed, k, S_WANDER + 1000 * (i + 1),
						int(c.wander_stand[0]), int(c.wander_stand[1]))
					var s0: int = w_lo + i * slot
					var s1: int = s0 + slot - dur
					if s1 > s0:
						var at: int = s0 + int(floor(LshuHash.unit(seed, k, S_WANDER + 2000 * (i + 1)) * float(s1 - s0)))
						wanders.append([at, at + dur])
	leg["night"] = night
	leg["night_start"] = ns
	leg["tent_in"] = ti
	leg["night_end"] = ne
	leg["depart"] = depart
	leg["road_start"] = depart + walk_out
	leg["road_s"] = road_s
	leg["long_road"] = long_road
	leg["road_end"] = depart + walk_out + road_s
	leg["postcard_at"] = pc_at
	leg["postcard_shot"] = shot
	leg["line_seed"] = LshuHash.hash3(seed, k, S_PC_LINE)
	leg["wanders"] = wanders


static func _choose_tile(leg: Dictionary, s: Dictionary, pool: Dictionary, c: Dictionary) -> Dictionary:
	var seed: int = int(s.seed)
	var k: int = int(leg.index)
	var night_preset: String = String(c.night_preset)
	var band_in: String = String(light_at(float(int(leg.settle)), c).band)
	var band_out: String = String(light_at(float(int(leg.depart)), c).band)
	var needs_fire: bool = bool(leg.night) or (bool(c.night_needs_fire) and band_in == night_preset)
	var needs_night_ok: bool = bool(leg.night) or band_in == night_preset or band_out == night_preset
	var weights: Dictionary = c.fire_weights if needs_fire else _kit_weights(float(int(leg.settle)), c)
	var tiles: Array
	if bool(leg.home):
		tiles = pool.home_tiles
	else:
		var place: String = _pick_place(s, pool, c, k, needs_fire, needs_night_ok)
		tiles = (pool.by_place[place] as Dictionary).tiles
	return _pick_tile(tiles, weights, needs_fire, needs_night_ok, String(s.get("last_layout_class", "")),
		s.get("visited_tiles", {}) as Dictionary, seed, k, c)


## Web planner rule, ported: never the last N places, unseen (fewest visits) first, then by hash rank.
static func _pick_place(s: Dictionary, pool: Dictionary, c: Dictionary, k: int, needs_fire: bool, needs_night_ok: bool) -> String:
	var by_place: Dictionary = pool.by_place
	var cands: Array = (pool.trip_places as Array).duplicate()
	var recent: Array = s.get("recent_places", []) as Array
	var avoid: Array = recent.slice(maxi(0, recent.size() - int(c.avoid_recent)))
	cands = _keep_if_any(cands, func(p: String) -> bool: return not avoid.has(p))
	if needs_fire:
		cands = _keep_if_any(cands, func(p: String) -> bool:
			var pd: Dictionary = by_place[p]
			return bool(pd.fire_night) if needs_night_ok else bool(pd.fire))
	if needs_night_ok:
		cands = _keep_if_any(cands, func(p: String) -> bool: return bool((by_place[p] as Dictionary).night_ok))
	var visited: Dictionary = s.get("visited", {}) as Dictionary
	var min_v: int = 1 << 30
	for p: Variant in cands:
		min_v = mini(min_v, int(visited.get(p, 0)))
	var seed: int = int(s.seed)
	var best: String = ""
	var best_r: int = 1 << 40
	for p: Variant in cands:
		if int(visited.get(p, 0)) != min_v:
			continue
		var r: int = LshuHash.hash3(seed ^ LshuHash.str_hash(String(p)), k, S_PLACE)
		if r < best_r or (r == best_r and String(p) < best):
			best_r = r
			best = String(p)
	return best


static func _pick_tile(tiles: Array, weights: Dictionary, needs_fire: bool, needs_night_ok: bool,
		prev_class: String, visited_tiles: Dictionary, seed: int, k: int, c: Dictionary) -> Dictionary:
	var cands: Array = tiles
	if needs_night_ok:
		cands = _keep_if_any(cands, func(e: Dictionary) -> bool: return bool(e.night_ok))
	if needs_fire:
		cands = _keep_if_any(cands, func(e: Dictionary) -> bool: return bool(e.fire))
	var min_v: int = 1 << 30
	for e: Variant in cands:
		min_v = mini(min_v, int(visited_tiles.get((e as Dictionary).id, 0)))
	var ws: Array[float] = []
	var total: float = 0.0
	for e: Variant in cands:
		var ed: Dictionary = e
		var w: float = float(weights.get(ed.kit, c.unlisted_w))
		if prev_class != "" and String(ed.layout_class) == prev_class:
			w *= float(c.layout_repeat)
		w *= pow(float(c.tile_repeat), float(int(visited_tiles.get(ed.id, 0)) - min_v))
		ws.append(maxf(w, 0.0))
		total += maxf(w, 0.0)
	if total <= 0.0:
		return cands[0]
	var u: float = LshuHash.unit(seed, k, S_TILE) * total
	for i: int in cands.size():
		u -= ws[i]
		if u < 0.0:
			return cands[i]
	return cands[cands.size() - 1]


static func _apply_tile(leg: Dictionary, e: Dictionary) -> void:
	leg["tile"] = e.id
	leg["place"] = e.place
	leg["name"] = e.name
	leg["kit"] = e.kit
	leg["layout"] = e.layout
	leg["layout_class"] = e.layout_class
	leg["biome"] = e.biome
	leg["fire"] = e.fire
	leg["sub"] = e.sub


static func _commit_leg(s: Dictionary, leg: Dictionary, c: Dictionary) -> void:
	s["current_leg"] = leg
	s["leg_index"] = int(leg.index)
	s["trip"] = {"index": int(leg.trip), "stops": int(leg.trip_stop), "target": int(leg.trip_target),
		"started": int(leg.trip_started)}
	var visited: Dictionary = s.visited
	var vt: Dictionary = s.visited_tiles
	var recent: Array = s.recent_places
	if not bool(leg.home):
		visited[leg.place] = int(visited.get(leg.place, 0)) + 1
		recent.append(leg.place)
		while recent.size() > int(c.recent_keep):
			recent.remove_at(0)
	else:
		(s.stats as Dictionary)["home_nights"] = int((s.stats as Dictionary).get("home_nights", 0)) + (1 if bool(leg.night) else 0)
	vt[leg.tile] = int(vt.get(leg.tile, 0)) + 1
	s["last_layout_class"] = leg.layout_class
	(s.stats as Dictionary)["legs"] = int((s.stats as Dictionary).get("legs", 0)) + 1


static func _log_leg(s: Dictionary, leg: Dictionary) -> void:
	(s.log as Array).append({
		"type": "leg", "k": int(leg.index), "trip": int(leg.trip), "tile": leg.tile, "place": leg.place,
		"name": leg.name, "kit": leg.kit, "home": bool(leg.home), "night": bool(leg.night),
		"arrive": int(leg.arrive), "depart": int(leg.depart), "road_end": int(leg.road_end),
	})


## Ids carry the save's seed so two saves (a fresh start after corrupt files, or the scaled debug
## clock) never write the same postcards/<id>.jpg: pc_<seed as 8 hex digits>_<leg index>.
static func postcard_id(seed: int, leg_index: int) -> String:
	return "pc_%08x_%d" % [seed & 0xFFFFFFFF, leg_index]


## postcards: the save's records so far; the postcard rules skip lines used by the last 20 of them.
static func _make_postcard(leg: Dictionary, c: Dictionary, seed: int, postcards: Array = []) -> Dictionary:
	var pa: int = int(leg.postcard_at)
	var info: Dictionary = local_info(float(pa), c)
	var pc: Dictionary = {
		"id": postcard_id(seed, int(leg.index)), "leg": int(leg.index), "trip": int(leg.trip), "tile": leg.tile,
		"place": leg.place, "name": leg.name, "kit": leg.kit, "biome": leg.biome, "home": bool(leg.home),
		"night": bool(leg.night), "shot": leg.postcard_shot, "unix": pa, "band": light_at(float(pa), c).band,
		"date": info.date_label, "time": info.time_label, "line_seed": int(leg.line_seed),
		"text": [], "signature": "", "file": "", "read": false,
	}
	LshuPostcardText.fill_postcard(pc, leg, c.lines, seed, postcards, info)
	return pc


## Keeps at most `cap` pending renders; the oldest unrendered postcards are dropped entirely.
static func _cap_pending(s: Dictionary, cap: int) -> Array:
	var dropped: Array = []
	var pending: Array = s.pending_renders
	while pending.size() > cap:
		var id: String = String(pending.pop_front())
		dropped.append(id)
		var pcs: Array = s.postcards
		for i: int in pcs.size():
			if String((pcs[i] as Dictionary).id) == id:
				pcs.remove_at(i)
				break
	return dropped


# =============================================================================================
# State at time t

static func _substate(leg: Dictionary, t: float) -> Dictionary:
	var settle: float = float(int(leg.settle))
	var depart: float = float(int(leg.depart))
	var rs: float = float(int(leg.road_start))
	if t < settle:
		return {"name": ARRIVE, "t0": float(int(leg.arrive)), "t1": settle, "phase": ""}
	if t < depart:
		var base: String = HOME if bool(leg.home) else STAY
		if bool(leg.night):
			var ns: float = float(int(leg.night_start))
			var ne: float = float(int(leg.night_end))
			if t >= ns and t < ne:
				return {"name": NIGHT, "t0": ns, "t1": ne, "phase": "doze" if t < float(int(leg.tent_in)) else "tent"}
			if t >= ne:
				return {"name": base, "t0": ne, "t1": depart, "phase": ""}
			return {"name": base, "t0": settle, "t1": ns, "phase": ""}
		return {"name": base, "t0": settle, "t1": depart, "phase": ""}
	if t < rs:
		return {"name": LEAVE, "t0": depart, "t1": rs, "phase": ""}
	return {"name": ROAD, "t0": rs, "t1": float(int(leg.road_end)), "phase": ""}


static func _activity(leg: Dictionary, t: float, st: String) -> String:
	if st != STAY and st != HOME:
		return ""
	for w: Variant in leg.get("wanders", []) as Array:
		var wa: Array = w
		if t >= float(wa[0]) and t < float(wa[1]):
			return "wander"
	return ""


static func _fire_state(leg: Dictionary, st: Dictionary) -> String:
	if not bool(leg.get("fire", false)):
		return "none"
	if st.name == ROAD:
		return "embers"
	if st.name == NIGHT and st.phase == "tent":
		return "low"
	return "lit"


static func _leg_timeline(leg: Dictionary) -> Array:
	var out: Array = []
	var home: bool = bool(leg.home)
	if not bool(leg.get("initial", false)):
		out.append(["home_arrive" if home else "arrive", int(leg.arrive)])
		out.append(["settle", int(leg.settle)])
	for w: Variant in leg.get("wanders", []) as Array:
		var wa: Array = w
		out.append(["wander_start", int(wa[0])])
		out.append(["wander_end", int(wa[1])])
	if bool(leg.night):
		out.append(["night_start", int(leg.night_start)])
		out.append(["tent_in", int(leg.tent_in)])
		out.append(["night_end", int(leg.night_end)])
	out.append(["home_leave" if home else "leave", int(leg.depart)])
	out.append(["road_start", int(leg.road_start)])
	out.append(["road_end", int(leg.road_end)])
	return out


static func _leg_events(leg: Dictionary, after: float, upto: float) -> Array:
	var out: Array = []
	for row: Variant in _leg_timeline(leg):
		var r: Array = row
		var at: int = int(r[1])
		if float(at) > after and float(at) <= upto:
			out.append(_event(String(r[0]), at, leg, {}))
	return out


static func _next_change(leg: Dictionary, t: float) -> float:
	var best: float = float(int(leg.road_end))
	for row: Variant in _leg_timeline(leg):
		var at: float = float(int((row as Array)[1]))
		if at > t and at < best:
			best = at
	var pa: int = int(leg.get("postcard_at", -1))
	if pa >= 0 and float(pa) > t and float(pa) < best:
		best = float(pa)
	return best


static func _event(kind: String, at: int, leg: Dictionary, extra: Dictionary) -> Dictionary:
	var ev: Dictionary = {
		"type": kind, "at": at, "leg": int(leg.get("index", -1)), "tile": leg.get("tile", ""),
		"place": leg.get("place", ""), "name": leg.get("name", ""), "kit": leg.get("kit", ""),
		"home": bool(leg.get("home", false)), "night": bool(leg.get("night", false)),
	}
	ev.merge(extra, true)
	return ev


static func _event_less(a: Dictionary, b: Dictionary) -> bool:
	if int(a.at) != int(b.at):
		return int(a.at) < int(b.at)
	if int(a.leg) != int(b.leg):
		return int(a.leg) < int(b.leg)
	return int(EVENT_ORDER.get(a.type, 50)) < int(EVENT_ORDER.get(b.type, 50))


# =============================================================================================
# Light

## Four presets follow the local clock; each boundary blends over blend_min centred on its time.
static func light_at(t: float, c: Dictionary) -> Dictionary:
	var bands: Array = c.bands
	var sod: float = _sod(t, c)
	var n: int = bands.size()
	var weights: Dictionary = {}
	for b: Variant in bands:
		weights[(b as Dictionary).preset] = 0.0
	if n == 0:
		return {"preset_a": "", "preset_b": "", "blend": 0.0, "band": "", "weights": weights}
	for i: int in n:
		var bd: Dictionary = bands[i]
		var half: float = float(int(bd.blend)) * 0.5
		if half <= 0.0:
			continue
		var d: float = fposmod(sod - float(int(bd.from)) + 43200.0, 86400.0) - 43200.0
		if absf(d) < half:
			var x: float = (d + half) / (2.0 * half)
			var bl: float = smoothstep(0.0, 1.0, x)
			var a: String = String((bands[(i - 1 + n) % n] as Dictionary).preset)
			var b2: String = String(bd.preset)
			weights[a] = float(weights[a]) + (1.0 - bl)
			weights[b2] = float(weights[b2]) + bl
			return {"preset_a": a, "preset_b": b2, "blend": bl, "band": a if bl < 0.5 else b2, "weights": weights}
	var cur: String = _band_index_preset(bands, sod)
	weights[cur] = 1.0
	return {"preset_a": cur, "preset_b": cur, "blend": 0.0, "band": cur, "weights": weights}


static func _band_index_preset(bands: Array, sod: float) -> String:
	if bands.is_empty():
		return ""
	var cur: String = String((bands[bands.size() - 1] as Dictionary).preset)
	for b: Variant in bands:
		if float(int((b as Dictionary).from)) <= sod:
			cur = String((b as Dictionary).preset)
	return cur


static func _light_events(after: float, upto: float, c: Dictionary) -> Array:
	var out: Array = []
	var bands: Array = c.bands
	var n: int = bands.size()
	if n == 0 or upto <= after:
		return out
	for d: int in range(_day(after, c) - 1, _day(upto, c) + 2):
		for i: int in n:
			var bd: Dictionary = bands[i]
			var start: int = _day_start(d, c) + int(bd.from) - int(bd.blend) / 2
			if float(start) > after and float(start) <= upto and int(bd.blend) > 0:
				out.append({"type": "light_blend", "at": start, "leg": -1, "from": (bands[(i - 1 + n) % n] as Dictionary).preset,
					"to": bd.preset, "duration_s": int(bd.blend)})
	return out


# =============================================================================================
# Local time

static func local_info(t: float, c: Dictionary) -> Dictionary:
	var dt: Dictionary = Time.get_datetime_dict_from_unix_time(int(floor(t)) + int(c.tz_s))
	return {
		"year": int(dt.year), "month": int(dt.month), "day": int(dt.day), "hour": int(dt.hour),
		"minute": int(dt.minute), "weekday": int(dt.weekday), "sod": _sod(t, c), "day_index": _day(t, c),
		"date_label": "%d月%d日" % [int(dt.month), int(dt.day)], "time_label": "%02d:%02d" % [int(dt.hour), int(dt.minute)],
	}


static func _day(t: float, c: Dictionary) -> int:
	return int(floor((t + float(int(c.tz_s))) / 86400.0))


static func _sod(t: float, c: Dictionary) -> float:
	var local: float = t + float(int(c.tz_s))
	return local - floor(local / 86400.0) * 86400.0


static func _day_start(day_index: int, c: Dictionary) -> int:
	return day_index * DAY - int(c.tz_s)


static func _in_night_window(t: float, c: Dictionary) -> bool:
	var sod: float = _sod(t, c)
	return sod >= float(int(c.cutoff)) or sod < float(int(c.resume))


## Calendar day of the evening that starts the current (or the coming) night.
static func _night_day_for(t: float, c: Dictionary) -> int:
	var d: int = _day(t, c)
	return d - 1 if _sod(t, c) < float(int(c.resume)) else d


static func _after_home_time(t: float, c: Dictionary) -> bool:
	var sod: float = _sod(t, c)
	return sod >= float(int(c.home_after)) or sod < float(int(c.resume))


static func _kit_weights(t: float, c: Dictionary) -> Dictionary:
	var sod: float = _sod(t, c)
	for row: Variant in c.kit_by_time as Array:
		var r: Dictionary = row
		var a: float = float(int(r.from))
		var b: float = float(int(r.to))
		var inside: bool = (sod >= a and sod < b) if a <= b else (sod >= a or sod < b)
		if inside:
			return r.weights
	return {}


# =============================================================================================
# Debug clock (--lshu-clock-scale=60): the scene maps real time to logic time with these helpers.
# A scaled clock runs ahead of real time, so it must use LshuSave.default_dir(true), never the
# real save (otherwise the real save would look "rolled back" for days).

static func clock_scale_from_args(args: PackedStringArray, prefix: String = "--lshu-clock-scale=") -> float:
	for a: String in args:
		if a.begins_with(prefix):
			var v: float = a.substr(prefix.length()).to_float()
			return v if v > 0.0 else 1.0
	return 1.0


## Config for the scaled debug window: one 2 s tick is 2 * scale logic seconds, so the live/offline
## threshold (catchup.live_gap_s, 180 s of logic time) is scaled with it. Without this, at 60x any
## tick that arrives more than 1 s late turns into an offline catch-up and he jumps instead of walking.
static func scaled_config(cfg: Dictionary, scale: float) -> Dictionary:
	var out: Dictionary = cfg.duplicate(true)
	var cu: Dictionary = (out.get("catchup", {}) as Dictionary).duplicate(true)
	cu["live_gap_s"] = float(cu.get("live_gap_s", 180)) * maxf(1.0, scale)
	out["catchup"] = cu
	return out


static func scaled_now(real_now: float, anchor_real: float, anchor_logic: float, scale: float) -> float:
	return anchor_logic + (real_now - anchor_real) * scale


# =============================================================================================
# Small helpers

static func _keep_if_any(arr: Array, pred: Callable) -> Array:
	var kept: Array = arr.filter(pred)
	return kept if not kept.is_empty() else arr


static func _weighted_name(pairs: Array, u: float) -> String:
	var total: float = 0.0
	for p: Variant in pairs:
		total += maxf(float((p as Array)[1]), 0.0)
	if pairs.is_empty():
		return ""
	var x: float = u * total
	for p: Variant in pairs:
		x -= maxf(float((p as Array)[1]), 0.0)
		if x < 0.0:
			return String((p as Array)[0])
	return String((pairs[pairs.size() - 1] as Array)[0])


static func _weights(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if v is Dictionary:
		for key: Variant in (v as Dictionary).keys():
			out[_str(key)] = float((v as Dictionary)[key])
	return out


static func _hm(v: Variant) -> int:
	var s: String = _str(v)
	var parts: PackedStringArray = s.split(":")
	if parts.size() < 2:
		return 0
	return (parts[0].to_int() * 60 + parts[1].to_int()) * 60


static func _range_hm(v: Variant, add: int) -> Array:
	var a: Array = v as Array
	return [_hm(a[0]) + add, _hm(a[1]) + add]


static func _range_s(v: Variant, unit_s: float) -> Array:
	var a: Array = v as Array
	return [int(round(float(a[0]) * unit_s)), int(round(float(a[1]) * unit_s))]


static func _range_int(v: Variant) -> Array:
	var a: Array = v as Array
	return [int(a[0]), int(a[1])]


static func _default_bands() -> Array:
	return [
		{"preset": "morning", "from": "05:30", "blend_min": 40}, {"preset": "day", "from": "08:00", "blend_min": 30},
		{"preset": "sunset", "from": "17:00", "blend_min": 30}, {"preset": "night", "from": "19:30", "blend_min": 40},
	]


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var j: JSON = JSON.new()
	if j.parse(FileAccess.get_file_as_string(path)) != OK or not (j.data is Dictionary):
		return {}
	return j.data


## JSON values to String without String(v), which Godot 4 rejects for numbers (JSON gives floats):
## 3.0 -> "3", "x" -> "x", null -> "".
static func _str(v: Variant) -> String:
	if v is String:
		return v
	if v == null:
		return ""
	if v is float and is_equal_approx(float(v), roundf(float(v))) and absf(float(v)) < 1.0e15:
		return str(int(v))
	return str(v)
