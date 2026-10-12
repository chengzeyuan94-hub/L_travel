extends SceneTree
## Act 4 「L叔在哪儿」 loop tests (P1). Headless, no scene, no network.
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path <project> \
##       --script res://tools/traveler/lshu/tests/test_loop.gd
## Prints PASS/FAIL lines, METRIC lines, and a final
##   LSHU_LOOP_TESTS passed=N failed=M
## Exit code 0 only when failed == 0.
## Tiles here are synthetic (generated names); the real-pool test reads pool.json at run time.

const LshuClock := preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const LshuSave := preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const LshuPoolAdapter := preload("res://scripts/traveler/lshu/loop/lshu_pool_adapter.gd")
const LshuPostcardText := preload("res://scripts/traveler/lshu/loop/lshu_postcard_text.gd")
const LshuHash := preload("res://scripts/traveler/lshu/loop/lshu_hash.gd")

const TZ_MIN: int = 480
const KITS: Array = ["look", "camp", "tea", "encounter"]
const BIOMES: Array = ["autumn", "desert", "harbor", "snow"]

var passed: int = 0
var failed: int = 0
var cfg: Dictionary = {}
var comp: Dictionary = {}
var pool: Array = []
var tz_s: int = TZ_MIN * 60
var base_midnight: int = 0
var tmp_root: String = ""
var long_chain: Array = []


func _init() -> void:
	var t_start: int = Time.get_ticks_msec()
	cfg = LshuClock.load_config()
	_check("config_loaded", not cfg.is_empty() and cfg.has("postcard_lines"), "loop.json + postcard_lines.json")
	cfg["tz_offset_minutes"] = TZ_MIN
	comp = LshuClock.compile_config(cfg)
	pool = _synthetic_pool(40, 4, {})
	base_midnight = int(Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 9, "day": 24, "hour": 0, "minute": 0, "second": 0})) - tz_s
	tmp_root = OS.get_temp_dir().path_join("lshu_loop_tests_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(tmp_root)

	test_first_launch()
	test_quit_mid_trip_3h()
	test_quit_3h_sweep()
	test_overnight_reopen()
	test_closed_30_days()
	test_far_jump()
	test_clock_rollback()
	test_same_seed()
	test_save_recovery_and_lock()
	test_long_chain_build()
	test_no_departures_at_night()
	test_every_trip_ends_home()
	test_distribution_1000()
	test_catchup_postcards_capped()
	test_live_2s_cadence()
	test_light_blend()
	test_night_ok_and_fire_filters()
	test_pool_change()
	test_real_pool()
	test_postcard_text()
	test_system_timezone()
	test_no_ids_in_loop_code()
	# Adversarial review, 2026-09-24.
	test_review_postcard_ids_unique_across_saves()
	test_review_resolve_cost_with_postcard_history()
	test_review_log_keeps_recent_trips()
	test_review_newest_complete_tmp_wins()
	test_review_damaged_leg_recovers()
	test_review_dead_lock_owner()
	test_review_tile_removed_keeps_place()
	test_review_scaled_clock_stays_live()
	test_review_rich_library_numeric_aliases()

	_rm_rf(tmp_root)
	print("METRIC total_ms=%d" % (Time.get_ticks_msec() - t_start))
	print("LSHU_LOOP_TESTS passed=%d failed=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)


# =============================================================================================
# Tests

func test_first_launch() -> void:
	var ok_day: int = 0
	var bad: Array = []
	var night_ok_count: int = 0
	for h: int in range(0, 24):
		for m: int in [0, 20, 40]:
			var t: float = _at(0, h * 3600 + m * 60)
			var r: Dictionary = LshuClock.resolve({"seed": 900 + h * 3 + m}, t, pool, cfg)
			var leg: Dictionary = r.leg
			var dep: int = int(leg.depart)
			var dsod: int = _sod(dep)
			var home_tile: bool = bool(_tile(String(leg.tile)).is_home)
			var in_5_15: bool = dep - int(floor(t)) >= 300 and dep - int(floor(t)) <= 900
			var legal_night: bool = bool(leg.night) and dsod >= 8 * 3600 and dsod <= 11 * 3600
			if not home_tile or not bool(leg.home):
				bad.append("%s not home" % _fmt(t))
			elif in_5_15 and _is_day_departure(dsod):
				ok_day += 1
			elif legal_night:
				night_ok_count += 1
			else:
				bad.append("%s dep=%s" % [_fmt(t), _fmt(dep)])
	_check("first_launch_leaves_5_15_min", bad.is_empty(), "72 launch times: %d leave in 5-15 min, %d at night wait for 08:00-11:00, bad=%s" % [ok_day, night_ok_count, str(bad)])
	var r10: Dictionary = LshuClock.resolve({"seed": 1}, _at(0, _hm("10:00")), pool, cfg)
	_check("first_launch_state", r10.substate == "HOME" and bool(r10.fresh) and (r10.events as Array).size() == 1
		and String((r10.events[0] as Dictionary).type) == "first_launch" and r10.light.band == "day",
		"10:00 -> %s, events=%s, light=%s" % [r10.substate, _types(r10.events), r10.light.band])
	var r23: Dictionary = LshuClock.resolve({"seed": 1}, _at(0, _hm("23:00")), pool, cfg)
	var r02: Dictionary = LshuClock.resolve({"seed": 1}, _at(0, _hm("02:00")), pool, cfg)
	_check("first_launch_at_night_sleeps", r23.substate == "NIGHT" and r23.night_phase == "doze" and r02.substate == "NIGHT"
		and r02.night_phase == "tent" and not bool(r02.character_visible) and bool(r23.leg.fire),
		"23:00 -> %s/%s, 02:00 -> %s/%s, fire kit=%s" % [r23.substate, r23.night_phase, r02.substate, r02.night_phase, r23.leg.kit])


func test_quit_mid_trip_3h() -> void:
	var t: float = _at(0, _hm("09:00"))
	var r: Dictionary = LshuClock.resolve({"seed": 11}, t, pool, cfg)
	var s: Dictionary = r.save
	while t < _at(0, _hm("11:00")):
		t += 60.0
		r = LshuClock.resolve(s, t, pool, cfg)
		s = r.save
	var a: Dictionary = s.duplicate(true)
	var a_t: float = t
	_check("mid_trip_state", int((a.current_leg as Dictionary).trip) >= 1 and not bool((a.current_leg as Dictionary).home),
		"at 11:00 leg %d trip %d %s" % [int(a.current_leg.index), int(a.current_leg.trip), r.substate])
	# Path 1: closed for 3 hours, one call.
	var t1_ms: int = Time.get_ticks_usec()
	var r1: Dictionary = LshuClock.resolve(a, a_t + 3 * 3600, pool, cfg)
	var us: int = Time.get_ticks_usec() - t1_ms
	# Path 2: open the whole time, resolve every 60 s.
	var s2: Dictionary = a.duplicate(true)
	var r2: Dictionary = {}
	var live_events: Array = []
	var tt: float = a_t
	while tt < a_t + 3 * 3600:
		tt += 60.0
		r2 = LshuClock.resolve(s2, tt, pool, cfg)
		s2 = r2.save
		live_events.append_array(r2.events)
	var same_leg: bool = JSON.stringify(r1.leg, "", true) == JSON.stringify(r2.leg, "", true)
	var same_log: bool = JSON.stringify(r1.save.log, "", true) == JSON.stringify(s2.log, "", true)
	_check("quit_3h_same_as_open", same_leg and same_log and r1.substate == r2.substate,
		"closed: leg %d %s %s | open: leg %d %s ; log %d entries equal=%s ; resolve %d us"
		% [int(r1.leg.index), r1.substate, r1.leg.name, int(r2.leg.index), r2.substate, (s2.log as Array).size(), str(same_log), us])
	var ev1: Array = r1.events
	var cu: Dictionary = r1.catchup
	_check("quit_3h_catchup_event", ev1.size() == 1 and String((ev1[0] as Dictionary).type) == "catchup" and bool(cu.show_away_card)
		and int(cu.legs_passed) == int(r2.leg.index) - int(a.current_leg.index) and (cu.places as Array).size() <= 8,
		"legs_passed=%d places=%s away_card=%s" % [int(cu.legs_passed), str(cu.places), str(cu.show_away_card)])
	var subset: bool = true
	for id: Variant in cu.postcards as Array:
		if not _live_pc_ids(live_events).has(id):
			subset = false
	_check("quit_3h_postcards", (cu.postcards as Array).size() <= 3 and subset,
		"closed: %d new postcards %s (all also produced live: %s); open: %d postcard events"
		% [(cu.postcards as Array).size(), str(cu.postcards), str(subset), _live_pc_ids(live_events).size()])
	# Events while open: ordered, no duplicates, each finished stop has its full sequence.
	var ordered: bool = true
	var seen: Dictionary = {}
	var dup: int = 0
	var per_leg: Dictionary = {}
	for i: int in live_events.size():
		var e: Dictionary = live_events[i]
		if i > 0 and int(e.at) < int((live_events[i - 1] as Dictionary).at):
			ordered = false
		var key: String = "%s|%d|%d" % [e.type, int(e.leg), int(e.at)]
		if seen.has(key):
			dup += 1
		seen[key] = true
		if String(e.type) != "light_blend" and String(e.type) != "postcard":
			if not per_leg.has(int(e.leg)):
				per_leg[int(e.leg)] = []
			(per_leg[int(e.leg)] as Array).append(String(e.type))
	var seq_bad: Array = []
	for k: Variant in per_leg.keys():
		var types: Array = per_leg[k]
		if int(k) > int(a.current_leg.index) and int(k) < int(r2.leg.index):
			var core: Array = types.filter(func(x: String) -> bool: return ["arrive", "home_arrive", "settle", "leave", "home_leave", "road_start", "road_end"].has(x))
			var want: Array = ["home_arrive" if types.has("home_arrive") else "arrive", "settle", "home_leave" if types.has("home_leave") else "leave", "road_start", "road_end"]
			if core != want:
				seq_bad.append("%d:%s" % [int(k), str(types)])
	_check("live_events_ordered_complete", ordered and dup == 0 and seq_bad.is_empty(),
		"%d events, ordered=%s dup=%d, bad sequences=%s, types=%s" % [live_events.size(), str(ordered), dup, str(seq_bad), str(_type_counts(live_events))])
	# The same state after a JSON round trip (floats instead of ints) resolves identically.
	var a_json: Dictionary = JSON.parse_string(JSON.stringify(a, "", true, true))
	var r1j: Dictionary = LshuClock.resolve(a_json, a_t + 3 * 3600, pool, cfg)
	_check("json_roundtrip_same", _leg_key(r1j.leg) == _leg_key(r1.leg) and r1j.substate == r1.substate,
		"%s vs %s" % [_leg_key(r1j.leg), _leg_key(r1.leg)])


## 20 seeds x 3 quit times (mid-morning, dusk, just before the 21:30 cutoff): closed for 3 h in
## one call must land exactly where resolving every 120 s (live) lands.
func test_quit_3h_sweep() -> void:
	var cases: int = 0
	var mismatch: Array = []
	var substates: Dictionary = {}
	var pcs_closed: int = 0
	var pcs_open: int = 0
	var not_subset: int = 0
	for seed: int in range(100, 120):
		for hm: String in ["10:37", "19:05", "21:10"]:
			var r: Dictionary = LshuClock.resolve({"seed": seed}, _at(0, _hm("08:00")), pool, cfg)
			var q: float = _at(1, _hm(hm))
			var rq: Dictionary = LshuClock.resolve(r.save, q, pool, cfg)
			var a: Dictionary = rq.save
			var r1: Dictionary = LshuClock.resolve(a, q + 3 * 3600, pool, cfg)
			var s2: Dictionary = a.duplicate(true)
			var r2: Dictionary = {}
			var live_ids: Array = []
			var tt: float = q
			while tt < q + 3 * 3600:
				tt = minf(tt + 120.0, q + 3 * 3600)
				r2 = LshuClock.resolve(s2, tt, pool, cfg)
				s2 = r2.save
				live_ids.append_array(_live_pc_ids(r2.events))
			cases += 1
			substates[rq.substate + ">" + r1.substate] = int(substates.get(rq.substate + ">" + r1.substate, 0)) + 1
			if JSON.stringify(r1.leg, "", true) != JSON.stringify(r2.leg, "", true) or r1.substate != r2.substate or r1.night_phase != r2.night_phase:
				mismatch.append("%d@%s" % [seed, hm])
			pcs_closed += (r1.catchup.postcards as Array).size()
			pcs_open += live_ids.size()
			for id: Variant in r1.catchup.postcards as Array:
				if not live_ids.has(id):
					not_subset += 1
			if (r1.catchup.postcards as Array).size() > 3:
				mismatch.append("pc>3 %d@%s" % [seed, hm])
	_check("quit_3h_sweep_same_as_open", mismatch.is_empty() and not_subset == 0,
		"%d cases: closed-for-3h == open-every-120s in all; postcards closed %d / open %d, closed not seen live %d; state before>after %s; mismatches=%s"
		% [cases, pcs_closed, pcs_open, not_subset, str(substates), str(mismatch)])


func test_overnight_reopen() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 21}, _at(0, _hm("09:00")), pool, cfg)
	var s: Dictionary = r.save
	var r_eve: Dictionary = LshuClock.resolve(s, _at(0, _hm("21:00")), pool, cfg)
	var r_22: Dictionary = LshuClock.resolve(r_eve.save, _at(0, _hm("22:40")), pool, cfg)
	var r_0030: Dictionary = LshuClock.resolve(r_22.save, _at(1, _hm("00:30")), pool, cfg)
	var r_morning: Dictionary = LshuClock.resolve(r_0030.save, _at(1, _hm("08:45")), pool, cfg)
	var night_leg: Dictionary = r_0030.leg
	var ok_night: bool = bool(night_leg.night) and _sod(int(night_leg.night_start)) >= _hm("21:30") \
		and _sod(int(night_leg.tent_in)) == _hm("23:30") and _sod(int(night_leg.night_end)) == _hm("06:30")
	var dep_sod: int = _sod(int(night_leg.depart))
	var dep_ok: bool = (dep_sod >= _hm("07:00") and dep_sod <= _hm("08:30")) or (bool(night_leg.home) and dep_sod >= _hm("08:00") and dep_sod <= _hm("11:00"))
	var bad_dep: Array = _night_departures(r_morning.save.log as Array)
	_check("overnight_reopen", ok_night and dep_ok and r_0030.substate == "NIGHT" and r_0030.night_phase == "tent"
		and bool(night_leg.fire) and bad_dep.is_empty() and int(r_morning.leg.index) > int(night_leg.index),
		"night stop %s (%s kit %s) doze %s tent %s back %s leaves %s; 00:30=%s/%s visible=%s; 08:45 leg %d %s; night departures=%d"
		% [night_leg.name, "home" if bool(night_leg.home) else "trip", night_leg.kit, _fmt(int(night_leg.night_start)),
		_fmt(int(night_leg.tent_in)), _fmt(int(night_leg.night_end)), _fmt(int(night_leg.depart)), r_0030.substate,
		r_0030.night_phase, str(r_0030.character_visible), int(r_morning.leg.index), r_morning.substate, bad_dep.size()])
	_check("overnight_22_40_state", r_22.substate == "NIGHT" or int(r_22.leg.settle) > int(_at(0, _hm("22:40"))),
		"22:40 -> %s/%s fire=%s" % [r_22.substate, r_22.night_phase, r_22.fire])


func test_closed_30_days() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 30}, _at(0, _hm("09:00")), pool, cfg)
	var s0: Dictionary = r.save
	var t0: int = Time.get_ticks_msec()
	var r30: Dictionary = LshuClock.resolve(s0, _at(30, _hm("12:00")), pool, cfg)
	var ms: int = Time.get_ticks_msec() - t0
	var log30: Array = r30.save.log
	var summaries: int = 0
	for e: Variant in log30:
		if String((e as Dictionary).get("type", "")) == "trip":
			summaries += 1
	var cu: Dictionary = r30.catchup
	var expect_summaries: bool = int(cu.legs_passed) > 500
	_check("closed_30_days", bool(r30.ok) and not bool(cu.far_jump) and log30.size() <= 500 and (summaries > 0) == expect_summaries
		and (r30.save.pending_renders as Array).size() <= 3 and (cu.postcards as Array).size() <= 3 and ms < 5000,
		"%d stops caught up in %d ms; log %d lines (%d trip summaries); postcards kept %d, dropped %d; away card %s"
		% [int(cu.legs_passed), ms, log30.size(), summaries, (cu.postcards as Array).size(), int(cu.postcards_dropped), str(cu.show_away_card)])
	# Same answer when the 30 days are resolved one day at a time.
	var s: Dictionary = s0.duplicate(true)
	var rd: Dictionary = {}
	for d: int in range(1, 31):
		rd = LshuClock.resolve(s, _at(d, _hm("12:00")), pool, cfg)
		s = rd.save
	_check("closed_30_days_chunked_same", _leg_key(rd.leg) == _leg_key(r30.leg) and JSON.stringify(rd.leg, "", true) == JSON.stringify(r30.leg, "", true),
		"one call %s | 30 daily calls %s" % [_leg_key(r30.leg), _leg_key(rd.leg)])


func test_far_jump() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 400}, _at(0, _hm("09:00")), pool, cfg)
	var t_far: float = _at(400, _hm("13:07"))
	var t0: int = Time.get_ticks_msec()
	var rf: Dictionary = LshuClock.resolve(r.save, t_far, pool, cfg)
	var ms: int = Time.get_ticks_msec() - t0
	var has_long: bool = false
	for e: Variant in rf.save.log as Array:
		if String((e as Dictionary).get("type", "")) == "long_way":
			has_long = true
	_check("max_3000_catchup_stops", bool(rf.catchup.far_jump) and int(rf.catchup.legs_passed) == 3000 and has_long
		and int(rf.leg.arrive) == int(floor(t_far)) and rf.substate == "ARRIVE" and (rf.save.log as Array).size() <= 500,
		"400 days away: %d stops then a long-way jump, arrives now (%s), log %d lines, %d ms"
		% [int(rf.catchup.legs_passed), rf.substate, (rf.save.log as Array).size(), ms])
	var r2: Dictionary = LshuClock.resolve(rf.save, t_far + 7200, pool, cfg)
	_check("after_far_jump_continues", bool(r2.ok) and int(r2.leg.index) > int(rf.leg.index), "leg %d -> %d" % [int(rf.leg.index), int(r2.leg.index)])
	# Runtime cost of the 2-second tick with a full log (worst case the scene will see).
	var s: Dictionary = r2.save
	var t: float = t_far + 7200
	var t0us: int = Time.get_ticks_usec()
	var worst: int = 0
	for i: int in 200:
		var c0: int = Time.get_ticks_usec()
		t += 2.0
		var rr: Dictionary = LshuClock.resolve(s, t, pool, cfg)
		s = rr.save
		worst = maxi(worst, Time.get_ticks_usec() - c0)
	var avg_us: int = (Time.get_ticks_usec() - t0us) / 200
	_check("tick_cost", avg_us < 20000, "resolve every 2 s with a %d-line log and 160 tiles: avg %d us, worst %d us" % [(s.log as Array).size(), avg_us, worst])


func test_clock_rollback() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 55}, _at(0, _hm("09:00")), pool, cfg)
	var rT: Dictionary = LshuClock.resolve(r.save, _at(0, _hm("13:00")), pool, cfg)
	var T: float = float(rT.save.last_seen_unix)
	var rb: Dictionary = LshuClock.resolve(rT.save, T - 3600, pool, cfg)
	var rb2: Dictionary = LshuClock.resolve(rb.save, T - 2 * 86400, pool, cfg)
	var held_ok: bool = bool(rb.clock_held) and bool(rb2.clock_held) and (rb.events as Array).is_empty() and (rb2.events as Array).is_empty()
	held_ok = held_ok and float(rb2.save.last_seen_unix) == T and _leg_key(rb2.leg) == _leg_key(rT.leg) and rb2.substate == rT.substate
	# Real time catches up: continues from last_seen, and no event before last_seen is replayed.
	var rc: Dictionary = LshuClock.resolve(rb2.save, T + 60, pool, cfg)
	var replay: int = 0
	for e: Variant in rc.events as Array:
		if float((e as Dictionary).at) <= T:
			replay += 1
	_check("clock_rolled_back", held_ok and not bool(rc.clock_held) and replay == 0 and float(rc.save.last_seen_unix) == T + 60,
		"-1 h and -2 days: held=%s/%s, state unchanged (%s), events=0; +60 s later: held=%s replayed=%d"
		% [str(rb.clock_held), str(rb2.clock_held), rb2.substate, str(rc.clock_held), replay])


func test_same_seed() -> void:
	var a: Dictionary = _run_to(77, _at(0, _hm("08:10")), _at(7, _hm("20:00")), 3 * 3600.0)
	var b: Dictionary = _run_to(77, _at(0, _hm("08:10")), _at(7, _hm("20:00")), 3 * 3600.0)
	var c2: Dictionary = _run_to(78, _at(0, _hm("08:10")), _at(7, _hm("20:00")), 3 * 3600.0)
	var ja: String = JSON.stringify(a, "", true, true)
	var jb: String = JSON.stringify(b, "", true, true)
	var jc: String = JSON.stringify(c2, "", true, true)
	_check("same_seed_identical", ja == jb and ja != jc,
		"seed 77 twice: %d bytes identical=%s; seed 78 differs=%s; legs=%d" % [ja.length(), str(ja == jb), str(ja != jc), int(a.leg_index)])
	var d: Dictionary = _run_to(77, _at(0, _hm("08:10")), _at(7, _hm("20:00")), 37 * 60.0 + 11.0)
	_check("same_seed_any_call_pattern", JSON.stringify(d.current_leg, "", true) == JSON.stringify(a.current_leg, "", true)
		and JSON.stringify(d.log, "", true) == JSON.stringify(a.log, "", true),
		"calls every 3 h vs every 37 min 11 s: current leg and %d log lines identical" % (a.log as Array).size())


func test_save_recovery_and_lock() -> void:
	var dir: String = tmp_root.path_join("save_a")
	var store: LshuSave = LshuSave.new(dir)
	var opened: Dictionary = store.open(_at(0, _hm("09:00")))
	_check("save_open_new", bool(opened.ok) and String(opened.source) == "new" and not bool(opened.read_only), "source=%s" % opened.source)
	var r: Dictionary = LshuClock.resolve(opened.data, _at(0, _hm("09:00")), pool, cfg)
	var w1: bool = store.write(r.save, _at(0, _hm("09:00")))
	var r2: Dictionary = LshuClock.resolve(r.save, _at(0, _hm("12:00")), pool, cfg)
	var w2: bool = store.write(r2.save, _at(0, _hm("12:00")))
	var bak1: Dictionary = LshuSave._read_json(store.bak_path())
	_check("save_atomic_write_and_bak", w1 and w2 and bool(bak1.ok) and float(bak1.data.last_seen_unix) == float(r.save.last_seen_unix)
		and not FileAccess.file_exists(store.tmp_path()), "two writes, .bak holds the previous one, no .tmp left")
	# a) killed while writing .tmp: save.json intact.
	_write_text(store.tmp_path(), "{\"schema\": \"lshu.where.sa")
	var la: Dictionary = store.load_data()
	var w3: bool = store.write(LshuClock.resolve(la.data, _at(0, _hm("13:00")), pool, cfg).save, _at(0, _hm("13:00")))
	_check("killed_during_tmp_write", String(la.source) == "main" and float(la.data.last_seen_unix) == float(r2.save.last_seen_unix) and w3,
		"source=%s, next write ok=%s" % [la.source, str(w3)])
	# b) save.json truncated: fall back to .bak, and the journey is the same from there.
	var main_text: String = FileAccess.get_file_as_string(store.save_path())
	var main_data: Dictionary = JSON.parse_string(main_text)
	_write_text(store.save_path(), main_text.substr(0, main_text.length() / 2))
	var lb: Dictionary = store.load_data()
	var t_check: float = _at(0, _hm("16:20"))
	var from_bak: Dictionary = LshuClock.resolve(lb.data, t_check, pool, cfg)
	var from_main: Dictionary = LshuClock.resolve(main_data, t_check, pool, cfg)
	_check("killed_mid_write_recovers_from_bak", String(lb.source) == "bak" and _leg_key(from_bak.leg) == _leg_key(from_main.leg),
		"source=%s; state at 16:20 from .bak %s == from lost save %s" % [lb.source, _leg_key(from_bak.leg), _leg_key(from_main.leg)])
	var w4: bool = store.write(from_bak.save, t_check)
	var after: Dictionary = LshuSave._read_json(store.save_path())
	var bak_after: Dictionary = LshuSave._read_json(store.bak_path())
	_check("write_after_corrupt_keeps_good_bak", w4 and bool(after.ok) and bool(bak_after.ok), "corrupt save.json was not rotated into .bak")
	# c) killed between the two renames: no save.json, complete .tmp and .bak. The .tmp is the
	#    newest complete save, so it wins (review 2026-09-24; it used to fall back to the older .bak).
	DirAccess.rename_absolute(store.save_path(), store.tmp_path())
	var lc: Dictionary = store.load_data()
	_check("killed_between_renames", String(lc.source) == "tmp" and bool(lc.ok)
		and float((lc.data as Dictionary).last_seen_unix) == float(from_bak.save.last_seen_unix),
		"source=%s (newest complete write)" % lc.source)
	# d) all three corrupt: start fresh but keep the corrupt files aside.
	_write_text(store.save_path(), "{broken")
	_write_text(store.bak_path(), "")
	_write_text(store.tmp_path(), "{\"schema\": \"lshu.where")
	var ld: Dictionary = store.load_data(_at(0, _hm("17:00")))
	var kept: int = 0
	for f: String in DirAccess.get_files_at(dir):
		if f.contains(".corrupt-"):
			kept += 1
	_check("both_corrupt_starts_fresh", String(ld.source) == "new" and (ld.data as Dictionary).is_empty() and kept == 2, "corrupt files kept aside: %d" % kept)
	# Lock: a second instance opens read-only.
	var now_lock: float = _at(0, _hm("17:00"))
	store.write(from_bak.save, now_lock)
	var second: LshuSave = LshuSave.new(dir)
	var o2: Dictionary = second.open(now_lock + 10)
	var w_second: bool = second.write(from_bak.save, now_lock + 10)
	var w_first: bool = store.write(from_bak.save, now_lock + 20)
	_check("lock_second_instance_read_only", bool(o2.read_only) and not w_second and w_first and bool(o2.ok),
		"second instance read_only=%s write=%s (data still loaded: %s); first instance write=%s" % [str(o2.read_only), str(w_second), str(bool(o2.ok)), str(w_first)])
	var took: bool = second.try_acquire(now_lock + 20 + 1000)
	var w_first_after: bool = store.write(from_bak.save, now_lock + 1030)
	var w_second_after: bool = second.write(from_bak.save, now_lock + 1030)
	_check("stale_lock_taken_over", took and not w_first_after and w_second_after and store.read_only,
		"lock older than %d s taken over; old owner now read-only" % int(store.lock_stale_s))
	second.close()
	_check("lock_released_on_close", not FileAccess.file_exists(second.lock_path()), "save.lock removed")
	# Unknown schema: never overwritten.
	var dir_b: String = tmp_root.path_join("save_b")
	DirAccess.make_dir_recursive_absolute(dir_b)
	_write_text(dir_b.path_join("save.json"), JSON.stringify({"schema": "lshu.where.save.v99", "x": 1}))
	var sb: LshuSave = LshuSave.new(dir_b)
	var ob: Dictionary = sb.open(now_lock)
	var wb: bool = sb.write({"a": 1}, now_lock)
	_check("unknown_schema_read_only", bool(ob.read_only) and String(ob.source) == "schema_mismatch" and not wb
		and FileAccess.get_file_as_string(dir_b.path_join("save.json")).contains("v99"), "source=%s" % ob.source)
	sb.close()
	# Log cap applied on write.
	var big: Dictionary = (from_bak.save as Dictionary).duplicate(true)
	var biglog: Array = []
	for i: int in 800:
		biglog.append({"type": "leg", "k": i, "trip": i / 15, "name": "p%d" % (i % 30), "home": i % 15 == 14, "night": false, "arrive": i * 100, "road_end": i * 100 + 50})
	big["log"] = biglog
	var dir_c: String = tmp_root.path_join("save_c")
	var sc: LshuSave = LshuSave.new(dir_c)
	sc.open(now_lock)
	sc.write(big, now_lock)
	var written: Dictionary = LshuSave._read_json(sc.save_path())
	var wl: Array = written.data.log
	var stops_total: int = 0
	for e: Variant in wl:
		var ed: Dictionary = e
		stops_total += int(ed.get("stops", 0)) if String(ed.type) == "trip" else (0 if bool(ed.get("home", false)) else 1)
	_check("log_capped_500_collapsed_per_trip", wl.size() <= 500 and String((wl[0] as Dictionary).type) == "trip" and stops_total == 800 - 800 / 15,
		"800 entries -> %d lines, first=%s, stops preserved %d" % [wl.size(), (wl[0] as Dictionary).type, stops_total])
	sc.close()
	store.close()


func test_long_chain_build() -> void:
	var t0: int = Time.get_ticks_msec()
	long_chain = _chain(2026, _at(0, _hm("09:00")), 1000, pool, cfg)
	var ms: int = Time.get_ticks_msec() - t0
	var days: float = (float(int((long_chain[long_chain.size() - 1] as Dictionary).arrive)) - _at(0, _hm("09:00"))) / 86400.0
	_check("long_chain_built", _non_home(long_chain).size() >= 1000, "%d stops (%d at home) over %.1f days, stepped in %d ms" % [long_chain.size(), long_chain.size() - _non_home(long_chain).size(), days, ms])
	print("METRIC stops_per_day=%.2f" % (float(_non_home(long_chain).size()) / days))


func test_no_departures_at_night() -> void:
	var bad: Array = []
	var earliest: int = 86400
	var latest: int = 0
	var overnight: int = 0
	var late_arrivals: int = 0
	var bad_night: Array = []
	for leg: Variant in long_chain:
		var l: Dictionary = leg
		if bool(l.initial):
			continue
		var d: int = _sod(int(l.depart))
		if not _is_day_departure(d):
			bad.append("%d@%s" % [int(l.index), _fmt(int(l.depart))])
		earliest = mini(earliest, d)
		latest = maxi(latest, d)
		if bool(l.night):
			overnight += 1
			if _sod(int(l.tent_in)) < _hm("23:30") and _sod(int(l.tent_in)) > _hm("12:00"):
				bad_night.append(int(l.index))
			if not bool(l.fire):
				bad_night.append(int(l.index))
		var a: int = _sod(int(l.arrive))
		if a >= _hm("21:30") or a < _hm("07:00"):
			late_arrivals += 1
	_check("no_departures_at_night", bad.is_empty() and bad_night.is_empty(),
		"%d stops: departures between %s and %s; %d overnight stops all with fire; %d arrivals after 21:30 (roads started before); bad=%s"
		% [long_chain.size(), _hms(earliest), _hms(latest), overnight, late_arrivals, str(bad.slice(0, 5))])


func test_every_trip_ends_home() -> void:
	var trips: Dictionary = {}
	for leg: Variant in long_chain:
		var l: Dictionary = leg
		var k: int = int(l.trip)
		if not trips.has(k):
			trips[k] = []
		(trips[k] as Array).append(l)
	var keys: Array = trips.keys()
	keys.sort()
	var bad: Array = []
	var min_stops: int = 999
	var max_stops: int = 0
	var complete: int = 0
	var home_arr_bad: int = 0
	var home_dep_bad: int = 0
	var durations: Array = []
	for k: Variant in keys:
		var legs: Array = trips[k]
		if int(k) == 0:
			continue
		var last: Dictionary = legs[legs.size() - 1]
		if k == keys[keys.size() - 1] and not bool(last.home):
			continue
		complete += 1
		var stops: int = legs.size() - 1
		min_stops = mini(min_stops, stops)
		max_stops = maxi(max_stops, stops)
		durations.append((float(int(last.depart)) - float(int((legs[0] as Dictionary).arrive))) / 86400.0)
		if not bool(last.home) or stops < int(last.trip_target) or stops > int(comp.trip_max):
			bad.append(int(k))
		for i: int in legs.size() - 1:
			if bool((legs[i] as Dictionary).home):
				bad.append(int(k))
		if _sod(int(last.arrive)) < _hm("16:00") and stops < int(comp.trip_max):
			home_arr_bad += 1
		var hd: int = _sod(int(last.depart))
		if hd < _hm("08:00") or hd > _hm("11:00"):
			home_dep_bad += 1
	durations.sort()
	_check("every_trip_ends_at_home", bad.is_empty() and home_arr_bad == 0 and home_dep_bad == 0 and complete >= 30,
		"%d complete trips, %d-%d stops each (target 12-24), home arrival always after 16:00, leaves home 08:00-11:00; trip length %.1f-%.1f days; bad=%s"
		% [complete, min_stops, max_stops, float(durations[0]), float(durations[durations.size() - 1]), str(bad)])


func test_distribution_1000() -> void:
	var stops: Array = _non_home(long_chain).slice(0, 1000)
	var trip_places: int = 39
	var first_places: Dictionary = {}
	for i: int in trip_places:
		first_places[(stops[i] as Dictionary).place] = true
	var repeat4: int = 0
	var layout_same: int = 0
	var counts: Dictionary = {}
	var tile_counts: Dictionary = {}
	var kit_by_band: Dictionary = {}
	var fire_violations: int = 0
	var pc_day: int = 0
	var pc_night: int = 0
	var n_day: int = 0
	var n_night: int = 0
	var long_roads: int = 0
	for i: int in stops.size():
		var l: Dictionary = stops[i]
		for j: int in range(maxi(0, i - 4), i):
			if String((stops[j] as Dictionary).place) == String(l.place):
				repeat4 += 1
		if i > 0 and String((stops[i - 1] as Dictionary).layout_class) == String(l.layout_class):
			layout_same += 1
		counts[l.place] = int(counts.get(l.place, 0)) + 1
		tile_counts[l.tile] = int(tile_counts.get(l.tile, 0)) + 1
		var band: String = String(LshuClock.light_at(float(int(l.settle)), comp).band)
		if bool(l.night):
			band = "overnight"
		if not kit_by_band.has(band):
			kit_by_band[band] = {}
		(kit_by_band[band] as Dictionary)[l.kit] = int((kit_by_band[band] as Dictionary).get(l.kit, 0)) + 1
		if (bool(l.night) or band == "night") and not bool(l.fire):
			fire_violations += 1
		if bool(l.night):
			n_night += 1
			pc_night += 1 if int(l.postcard_at) >= 0 else 0
		else:
			n_day += 1
			pc_day += 1 if int(l.postcard_at) >= 0 else 0
		long_roads += 1 if bool(l.long_road) else 0
	var vmin: int = 1 << 30
	var vmax: int = 0
	for p: Variant in counts.keys():
		vmin = mini(vmin, int(counts[p]))
		vmax = maxi(vmax, int(counts[p]))
	var tmin: int = 1 << 30
	var tmax: int = 0
	for tk: Variant in tile_counts.keys():
		tmin = mini(tmin, int(tile_counts[tk]))
		tmax = maxi(tmax, int(tile_counts[tk]))
	_check("unseen_places_first", first_places.size() == trip_places, "first %d stops visit %d distinct places" % [trip_places, first_places.size()])
	_check("last_4_places_never_repeat", repeat4 == 0, "1000 stops, repeats within the last 4 = %d" % repeat4)
	_check("place_visits_balanced", counts.size() == trip_places and vmax - vmin <= 1,
		"%d places, visits per place %d-%d; tiles used %d/%d, per tile %d-%d" % [counts.size(), vmin, vmax, tile_counts.size(), trip_places * 4, tmin, tmax])
	_check("night_stops_get_fire_kit", fire_violations == 0, "overnight / night-band stops without fire = %d; kits by band %s" % [fire_violations, str(kit_by_band)])
	_check("home_never_a_trip_stop", not counts.has(_home_place()), "home place visited as a trip stop: %s" % str(counts.has(_home_place())))
	print("METRIC layout_class_repeat_rate=%.3f (random baseline ~0.33)" % (float(layout_same) / float(stops.size() - 1)))
	print("METRIC postcard_rate_day=%.3f (target 0.25) postcard_rate_overnight=%.3f (target 0.40) n_day=%d n_overnight=%d" % [float(pc_day) / float(n_day), float(pc_night) / float(maxi(1, n_night)), n_day, n_night])
	print("METRIC long_road_rate=%.3f (target 0.15)" % (float(long_roads) / float(stops.size())))


func test_catchup_postcards_capped() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 33}, _at(0, _hm("09:00")), pool, cfg)
	var r3: Dictionary = LshuClock.resolve(r.save, _at(3, _hm("15:00")), pool, cfg)
	var cu: Dictionary = r3.catchup
	_check("catchup_postcards_capped_3", (cu.postcards as Array).size() == 3 and int(cu.postcards_dropped) > 0
		and (r3.save.postcards as Array).size() <= 3 and (r3.save.pending_renders as Array).size() <= 3,
		"3 days away: %d postcards drawn, %d kept for rendering, %d dropped" % [(cu.postcards as Array).size() + int(cu.postcards_dropped), (cu.postcards as Array).size(), int(cu.postcards_dropped)])
	var pcs: Array = r3.save.postcards
	var texts_ok: bool = true
	for pc: Variant in pcs:
		var p: Dictionary = pc
		if (p.text as Array).is_empty() or String(p.signature) != "L" or String(p.file) != "" or bool(p.read):
			texts_ok = false
	_check("postcard_records", texts_ok, "each has 1-2 lines, signature L, file empty until rendered; e.g. %s" % str((pcs[0] as Dictionary).text if not pcs.is_empty() else []))
	# Live: renders never complete (window occluded) -> pending stays capped at 3.
	var s: Dictionary = r.save
	var t: float = _at(0, _hm("09:00"))
	var max_pending: int = 0
	var drops: int = 0
	var events_pc: int = 0
	while t < _at(1, _hm("09:00")):
		t += 60.0
		var rr: Dictionary = LshuClock.resolve(s, t, pool, cfg)
		s = rr.save
		max_pending = maxi(max_pending, (s.pending_renders as Array).size())
		drops += (rr.dropped_postcards as Array).size()
		for e: Variant in rr.events as Array:
			if String((e as Dictionary).type) == "postcard":
				events_pc += 1
	_check("pending_renders_capped", max_pending <= 3 and events_pc >= 1, "one day open, nothing rendered: %d postcard events, pending max %d, %d dropped" % [events_pc, max_pending, drops])
	var pid: String = String((s.pending_renders as Array)[0]) if not (s.pending_renders as Array).is_empty() else ""
	var done: bool = LshuSave.complete_render(s, pid, "user://x.jpg")
	var unread_n: int = LshuSave.unread(s).size()
	var read_ok: bool = LshuSave.mark_read(s, pid)
	_check("render_and_read_flags", done and unread_n == 1 and read_ok and LshuSave.unread(s).is_empty() and not (s.pending_renders as Array).has(pid),
		"complete_render -> unread 1 -> mark_read -> unread 0")


func test_live_2s_cadence() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 44}, _at(0, _hm("09:00")), pool, cfg)
	var s: Dictionary = r.save
	var t: float = float(int((s.current_leg as Dictionary).depart)) - 60.0
	var events: Array = []
	var substates: Array = []
	var calls: int = 0
	while t < float(int((r.save.current_leg as Dictionary).road_end)) + 120.0:
		t += 2.0
		var rr: Dictionary = LshuClock.resolve(s, t, pool, cfg)
		s = rr.save
		calls += 1
		events.append_array(rr.events)
		if substates.is_empty() or substates[substates.size() - 1] != rr.substate:
			substates.append(rr.substate)
	var types: Array = _types(events)
	_check("live_2s_home_departure", types.has("home_leave") and types.has("road_start") and types.has("road_end") and types.has("arrive")
		and substates.has("LEAVE") and substates.has("ROAD") and substates.has("ARRIVE"),
		"%d calls every 2 s: substates %s, events %s" % [calls, str(substates), str(types)])


func test_light_blend() -> void:
	var max_step: float = 0.0
	var prev: Dictionary = {}
	var band_at: Dictionary = {}
	for m: int in range(0, 2 * 1440 + 1):
		var t: float = _at(0, m * 60)
		var l: Dictionary = LshuClock.light_at(t, comp)
		if not prev.is_empty():
			var d: float = 0.0
			for key: Variant in (l.weights as Dictionary).keys():
				d += absf(float(l.weights[key]) - float(prev.weights[key]))
			max_step = maxf(max_step, d)
		prev = l
	for hm: String in ["00:00", "04:00", "06:45", "12:00", "16:00", "18:15", "21:00"]:
		band_at[hm] = String(LshuClock.light_at(_at(0, _hm(hm)), comp).band)
	var mid: Dictionary = LshuClock.light_at(_at(0, _hm("17:00")), comp)
	var edge: Dictionary = LshuClock.light_at(_at(0, _hm("16:30")), comp)
	_check("light_bands", band_at["00:00"] == "night" and band_at["04:00"] == "night" and band_at["06:45"] == "morning"
		and band_at["12:00"] == "day" and band_at["16:00"] == "day" and band_at["18:15"] == "sunset" and band_at["21:00"] == "night",
		str(band_at))
	_check("light_blend_continuous", max_step <= 0.11 and absf(float(mid.blend) - 0.5) < 0.001 and mid.preset_a == "day" and mid.preset_b == "sunset"
		and float(edge.blend) == 0.0,
		"48 h sampled per minute: largest weight change per minute %.4f (30-40 min smoothstep blends); 17:00 = day->sunset %.2f" % [max_step, float(mid.blend)])


func test_night_ok_and_fire_filters() -> void:
	var p2: Array = _synthetic_pool(40, 4, {"no_night_look": true, "no_fire_every": 3})
	var chain: Array = _chain(505, _at(0, _hm("09:00")), 300, p2, cfg)
	var bad_night: int = 0
	var bad_fire: int = 0
	var needs_night_n: int = 0
	var repeats: int = 0
	var stops: Array = _non_home(chain)
	for i: int in stops.size():
		for j: int in range(maxi(0, i - 4), i):
			if (stops[j] as Dictionary).place == (stops[i] as Dictionary).place:
				repeats += 1
	for leg: Variant in chain:
		var l: Dictionary = leg
		var bi: String = String(LshuClock.light_at(float(int(l.settle)), comp).band)
		var bo: String = String(LshuClock.light_at(float(int(l.depart)), comp).band)
		var e: Dictionary = _tile_in(p2, String(l.tile))
		if bool(l.night) or bi == "night" or bo == "night":
			needs_night_n += 1
			if not bool(e.get("night_ok", true)):
				bad_night += 1
		if (bool(l.night) or bi == "night") and not _tile_has_fire(e):
			bad_fire += 1
	_check("night_ok_and_fire_respected", bad_night == 0 and bad_fire == 0 and repeats == 0,
		"sparse pool (look tiles not night_ok, every 3rd place without fire): %d night-overlapping stops, night_ok violations %d, fire violations %d, recent-4 repeats %d"
		% [needs_night_n, bad_night, bad_fire, repeats])


func test_pool_change() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 66}, _at(0, _hm("09:00")), pool, cfg)
	var r2: Dictionary = LshuClock.resolve(r.save, _at(0, _hm("11:00")), pool, cfg)
	var gone: String = String(r2.leg.tile)
	var smaller: Array = pool.filter(func(e: Dictionary) -> bool: return String(e.id) != gone)
	var r3: Dictionary = LshuClock.resolve(r2.save, _at(0, _hm("11:01")), smaller, cfg)
	_check("tile_removed_from_pool", bool(r3.ok) and String(r3.leg.tile) != gone and (r3.warnings as Array).has("tile_replaced")
		and _tile_in(smaller, String(r3.leg.tile)).size() > 0, "current tile removed -> replaced, times kept")
	var r4: Dictionary = LshuClock.resolve({"seed": 1}, _at(0, _hm("09:00")), [], cfg)
	_check("empty_pool_is_an_error_not_a_crash", not bool(r4.ok) and String(r4.error) == "empty_pool", str(r4.get("error", "")))
	var nohome: Array = []
	for e: Variant in pool:
		var d: Dictionary = (e as Dictionary).duplicate()
		d["is_home"] = false
		nohome.append(d)
	var r5: Dictionary = LshuClock.resolve({"seed": 2}, _at(0, _hm("09:00")), nohome, cfg)
	_check("missing_home_falls_back", bool(r5.ok) and (r5.warnings as Array).has("no_home_tile") and bool(r5.leg.home), "home picked by rule, warning raised")


func test_real_pool() -> void:
	var places: Array = LshuPoolAdapter.load_places()
	if places.is_empty():
		_check("real_pool_loaded", false, "pool.json missing")
		return
	var homes: Array = places.filter(func(e: Dictionary) -> bool: return bool(e.is_home))
	var fields_ok: bool = true
	for e: Variant in places:
		var d: Dictionary = e
		if String(d.place) == "" or String(d.kit) == "" or String(d.biome) == "" or not ["look", "camp", "tea", "encounter"].has(String(d.kit)):
			fields_ok = false
	var pool_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/lshu/pool.json"))
	var home_entry: String = str(pool_json.get("home", ""))
	var home_matches: bool = false
	for h: Variant in homes:
		if String((h as Dictionary).id) == home_entry:
			home_matches = true
	_check("real_pool_adapter", fields_ok and not homes.is_empty() and home_matches,
		"%d tiles from pool.json, %d home tiles (incl. pool.json home), sources %s" % [places.size(), homes.size(), str(_count_by(places, "source"))])
	var chain: Array = _chain(9, _at(0, _hm("09:00")), 200, places, cfg)
	var stops: Array = _non_home(chain)
	var repeats: int = 0
	var fire_bad: int = 0
	var home_bad: int = 0
	var night_dep: int = 0
	for i: int in stops.size():
		for j: int in range(maxi(0, i - 4), i):
			if (stops[j] as Dictionary).place == (stops[i] as Dictionary).place:
				repeats += 1
	for leg: Variant in chain:
		var l: Dictionary = leg
		if bool(l.night) and not bool(l.fire):
			fire_bad += 1
		if bool(l.home) and not bool(_tile_in(places, String(l.tile)).get("is_home", false)):
			home_bad += 1
		if not bool(l.initial) and not _is_day_departure(_sod(int(l.depart))):
			night_dep += 1
	var trip_places: Dictionary = {}
	for e2: Variant in places:
		if not bool((e2 as Dictionary).is_home):
			trip_places[(e2 as Dictionary).place] = true
	var first_n: Dictionary = {}
	for i: int in mini(trip_places.size(), stops.size()):
		first_n[(stops[i] as Dictionary).place] = true
	_check("real_pool_journey", repeats == 0 and fire_bad == 0 and home_bad == 0 and night_dep == 0,
		"P0 pool, %d stops: recent-4 repeats %d, overnight without fire %d, home off home tiles %d, night departures %d; first %d stops cover %d places"
		% [stops.size(), repeats, fire_bad, home_bad, night_dep, trip_places.size(), first_n.size()])


func test_postcard_text() -> void:
	var lines: Dictionary = LshuPostcardText.normalize_library(cfg.postcard_lines)
	var all: Dictionary = {}
	for g: String in ["time", "kit", "biome"]:
		for key: Variant in (lines[g] as Dictionary).keys():
			for x: Variant in (lines[g] as Dictionary)[key] as Array:
				all[String(x)] = true
	for x2: Variant in lines.home as Array:
		all[String(x2)] = true
	var ok: bool = true
	var two: int = 0
	for i: int in 200:
		var pc: Dictionary = {"line_seed": LshuHash.hash3(i, 7, 3), "band": ["morning", "day", "sunset", "night"][i % 4],
			"kit": KITS[i % 4], "biome": BIOMES[(i / 4) % 4], "home": i % 10 == 0}
		var a: Array[String] = LshuPostcardText.compose(pc, lines, "测试地点的一句话。" if i % 3 == 0 else "")
		var b: Array[String] = LshuPostcardText.compose(pc, lines, "测试地点的一句话。" if i % 3 == 0 else "")
		if a != b or a.is_empty() or a.size() > 2:
			ok = false
		for x3: String in a:
			if not all.has(x3) and x3 != "测试地点的一句话。":
				ok = false
		two += 1 if a.size() == 2 else 0
	_check("postcard_text", ok and all.size() >= 70, "library %d lines; 200 cards deterministic, 1-2 lines each, %d with two lines" % [all.size(), two])
	var rich: Dictionary = {
		"lines": {"time": {"dusk": [{"id": "t1", "text": "傍晚句"}], "day": ["白天句"]}, "kit": {"bloom": [{"id": "k1", "text": "拾花句"}]},
			"terrain": {"grass": [{"id": "g1", "text": "草地句"}]}, "home": [{"id": "h1", "text": "到家句"}]},
		"kits": {"bloom": {"aliases": ["encounter"]}}, "terrain_resolve": {"from_biome": {"autumn": "grass"}, "fallback": "grass"},
		"input_contract": {"slot": {"aliases": {"sunset": "dusk"}}},
	}
	var norm: Dictionary = LshuPostcardText.normalize_library(rich)
	var got: Array[String] = LshuPostcardText.compose({"line_seed": 5, "band": "sunset", "kit": "encounter", "biome": "autumn", "home": false}, norm, "")
	_check("postcard_library_rich_shape", (norm.kit as Dictionary).has("encounter") and (norm.time.sunset as Array).size() == 1
		and (norm.biome.autumn as Array).size() == 1 and not got.is_empty(), "rich library shape normalises; sample card %s" % str(got))


func test_system_timezone() -> void:
	var c_sys: Dictionary = cfg.duplicate(true)
	c_sys["tz_offset_minutes"] = null
	var cs: Dictionary = LshuClock.compile_config(c_sys)
	var now: float = Time.get_unix_time_from_system()
	var info: Dictionary = LshuClock.local_info(now, cs)
	var sys: Dictionary = Time.get_datetime_dict_from_system()
	_check("system_timezone", int(cs.tz_s) == LshuClock.system_tz_offset_s() and int(info.hour) == int(sys.hour)
		and int(info.minute) == int(sys.minute), "tz %+d min, local %s == system %02d:%02d (more zones: test_loop_tz.gd)" % [int(cs.tz_s) / 60, info.time_label, int(sys.hour), int(sys.minute)])


func test_no_ids_in_loop_code() -> void:
	var files: Array = []
	for f: String in DirAccess.get_files_at("res://scripts/traveler/lshu/loop"):
		if f.ends_with(".gd") or f.ends_with(".md"):
			files.append("res://scripts/traveler/lshu/loop".path_join(f))
	files.append("res://data/traveler/lshu/loop.json")
	files.append("res://data/traveler/lshu/postcard_lines.json")
	var re: RegEx = RegEx.new()
	re.compile("\\b[JDSPC][0-9]{2,3}\\b")
	var hits: Array = []
	var ids: Array = []
	var catalog: Dictionary = {}
	if FileAccess.file_exists(LshuPoolAdapter.DEV_CATALOG_JSON):
		catalog = JSON.parse_string(FileAccess.get_file_as_string(LshuPoolAdapter.DEV_CATALOG_JSON))
		for p: Variant in catalog.get("places", []) as Array:
			ids.append(String((p as Dictionary).id))
	var pool_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/lshu/pool.json"))
	for t: Variant in pool_json.get("tiles", []) as Array:
		ids.append(String((t as Dictionary).id))
	for path: Variant in files:
		var text: String = FileAccess.get_file_as_string(String(path))
		for m: RegExMatch in re.search_all(text):
			hits.append("%s:%s" % [String(path).get_file(), m.get_string()])
		for id: Variant in ids:
			if text.contains("\"%s\"" % id) or text.contains("'%s'" % id):
				hits.append("%s:%s" % [String(path).get_file(), id])
	_check("no_tile_or_place_ids_in_loop_code", hits.is_empty(), "%d files scanned against a code-id pattern and %d known place/tile ids; hits=%s" % [files.size(), ids.size(), str(hits)])


# =============================================================================================
# Adversarial review, 2026-09-24: one test per defect found.

## Postcard images are saved as <id>.jpg. Ids must not repeat between two saves (a fresh start
## after both save files were corrupt, or the --lshu-clock-scale save), or old images get overwritten.
func test_review_postcard_ids_unique_across_saves() -> void:
	var owner: Dictionary = {}
	var clashes: Array = []
	var total: int = 0
	for seed: int in range(1, 11):
		var r: Dictionary = LshuClock.resolve({"seed": seed}, _at(0, _hm("09:00")), pool, cfg)
		var s: Dictionary = r.save
		for d: int in range(1, 11):
			var rr: Dictionary = LshuClock.resolve(s, _at(d, _hm("12:00")), pool, cfg)
			s = rr.save
			for id: Variant in rr.new_postcards as Array:
				total += 1
				if owner.has(id) and int(owner[id]) != seed:
					clashes.append("%s(seeds %d,%d)" % [id, int(owner[id]), seed])
				owner[id] = seed
	_check("review_postcard_ids_unique_across_saves", clashes.is_empty() and total >= 50,
		"10 seeds x 10 days: %d postcards, ids shared between different saves %d %s" % [total, clashes.size(), str(clashes.slice(0, 3))])


## resolve() runs every 2 s on the main thread. Its cost must not grow with the postcard history
## (about 1800 records a year), and it must never modify the save it was given.
func test_review_resolve_cost_with_postcard_history() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 88}, _at(0, _hm("09:00")), pool, cfg)
	var base: Dictionary = LshuClock.resolve(r.save, _at(3, _hm("12:00")), pool, cfg).save
	var tmpl: Dictionary = ((base.postcards as Array)[0] as Dictionary).duplicate(true)
	var avg: Dictionary = {}
	var mutated: int = 0
	for n: int in [0, 1800, 9000]:
		var s: Dictionary = base.duplicate(true)
		var pcs: Array = []
		for i: int in n:
			var p: Dictionary = tmpl.duplicate(true)
			p["id"] = "old_%d" % i
			p["file"] = "old_%d.jpg" % i
			p["read"] = true
			pcs.append(p)
		s["postcards"] = pcs
		var before: String = JSON.stringify(s, "", true, true)
		var t: float = float(s.last_seen_unix)
		var probe_in: Dictionary = s
		var t0: int = Time.get_ticks_usec()
		for i: int in 40:
			t += 2.0
			var rr: Dictionary = LshuClock.resolve(s, t, pool, cfg)
			s = rr.save
		avg[n] = (Time.get_ticks_usec() - t0) / 40
		if JSON.stringify(probe_in, "", true, true) != before:
			mutated += 1
	var ratio: float = float(avg[9000]) / float(maxi(1, int(avg[0])))
	_check("review_resolve_cost_flat_with_history", ratio < 2.0 and mutated == 0,
		"avg resolve with 0 / 1800 / 9000 postcards: %d / %d / %d us (x%.1f); input saves modified: %d"
		% [int(avg[0]), int(avg[1800]), int(avg[9000]), ratio, mutated])


## After ~500 trips (about two years) the log is all trip summaries. New stops must still be kept
## one line each for the current and the previous trip; the oldest summaries go instead.
func test_review_log_keeps_recent_trips() -> void:
	var log_in: Array = []
	for tr: int in 494:
		log_in.append({"type": "trip", "trip": tr, "from": tr * 100, "to": tr * 100 + 90, "stops": 15, "home": true, "nights": 1, "places": ["x"]})
	for i: int in 6:
		log_in.append({"type": "leg", "k": 9000 + i, "trip": 494, "name": "p%d" % i, "home": i == 5, "night": i == 5, "arrive": 50000 + i * 10, "road_end": 50005 + i * 10})
	for i2: int in 8:
		log_in.append({"type": "leg", "k": 9010 + i2, "trip": 495, "name": "q%d" % i2, "home": false, "night": false, "arrive": 60000 + i2 * 10, "road_end": 60005 + i2 * 10})
	var out: Array = LshuSave.compact_log(log_in, 500)
	var legs_494: int = 0
	var legs_495: int = 0
	for e: Variant in out:
		var d: Dictionary = e
		if String(d.type) == "leg":
			legs_494 += 1 if int(d.trip) == 494 else 0
			legs_495 += 1 if int(d.trip) == 495 else 0
	var first_trip: int = int((out[0] as Dictionary).get("trip", -1))
	_check("review_log_keeps_recent_trips", out.size() <= 500 and legs_494 == 6 and legs_495 == 8 and first_trip > 0,
		"494 trip summaries + 14 new stop lines -> %d lines; stop lines kept: previous trip %d/6, current trip %d/8; oldest line now trip %d"
		% [out.size(), legs_494, legs_495, first_trip])


## write() verifies save.json.tmp before rotating. If the process dies after that, the .tmp is the
## newest complete save and must win over the older save.json / .bak; a stale .tmp must not.
func test_review_newest_complete_tmp_wins() -> void:
	var dir: String = tmp_root.path_join("save_tmp")
	var store: LshuSave = LshuSave.new(dir)
	store.open(_at(0, _hm("09:00")))
	var r1: Dictionary = LshuClock.resolve({"seed": 91}, _at(0, _hm("09:00")), pool, cfg)
	store.write(r1.save, _at(0, _hm("09:00")))
	var r2: Dictionary = LshuClock.resolve(r1.save, _at(0, _hm("11:00")), pool, cfg)
	store.write(r2.save, _at(0, _hm("11:00")))
	var r3: Dictionary = LshuClock.resolve(r2.save, _at(0, _hm("13:00")), pool, cfg)
	var want: float = float(r3.save.last_seen_unix)
	var got: Array = []
	var ok: bool = true
	# Killed after the .tmp was verified (save.json still the 11:00 one), then between the renames.
	for point: String in ["after_tmp", "after_rotate"]:
		store.fail_point = point
		var w: bool = store.write(r3.save, _at(0, _hm("13:00")))
		store.fail_point = ""
		var reader: LshuSave = LshuSave.new(dir)
		var l: Dictionary = reader.load_data()
		var t_loaded: float = float((l.data as Dictionary).get("last_seen_unix", -1.0))
		got.append("%s->%s %s" % [point, l.source, _fmt(t_loaded)])
		ok = ok and not w and t_loaded == want and String(l.source) == "tmp"
		store.load_data()
		store.write(r2.save, _at(0, _hm("13:01")))
	# A stale complete .tmp (older write) next to a good save.json is ignored.
	store.write(r3.save, _at(0, _hm("13:05")))
	var stale: Dictionary = r1.save.duplicate(true)
	stale["schema"] = "lshu.where.save.v1"
	stale["saved_unix"] = _at(0, _hm("09:00"))
	stale["save_seq"] = 1
	_write_text(store.tmp_path(), JSON.stringify(stale, " ", true, true))
	var lb: Dictionary = LshuSave.new(dir).load_data()
	var got_b: float = float((lb.data as Dictionary).get("last_seen_unix", -1.0))
	_check("review_newest_complete_tmp_wins", ok and got_b == want and String(lb.source) == "main",
		"killed at %s (newest %s); stale .tmp next to save.json: loaded %s from %s" % [str(got), _fmt(want), _fmt(got_b), lb.source])
	store.close()


## A save.json that parses and has the right schema but a broken current_leg (hand edit, bit rot,
## a later build renaming a field) must not make resolve() throw every 2 s. He starts again at home,
## the history stays, and leg / trip numbers keep counting so postcard ids do not repeat.
func test_review_damaged_leg_recovers() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 93}, _at(0, _hm("09:00")), pool, cfg)
	var good: Dictionary = LshuClock.resolve(r.save, _at(2, _hm("15:00")), pool, cfg).save
	var results: Array = []
	var cases: Array = []
	var bad1: Dictionary = good.duplicate(true)
	(bad1.current_leg as Dictionary).erase("road_end")
	cases.append(bad1)
	var bad2: Dictionary = good.duplicate(true)
	bad2["current_leg"] = {"index": 3}
	cases.append(bad2)
	var bad3: Dictionary = good.duplicate(true)
	(bad3.current_leg as Dictionary)["depart"] = "soon"
	cases.append(bad3)
	var bad4: Dictionary = good.duplicate(true)
	bad4["seed"] = null
	cases.append(bad4)
	var ok_all: bool = true
	for b: Variant in cases:
		var rb: Dictionary = LshuClock.resolve(b as Dictionary, _at(2, _hm("15:10")), pool, cfg)
		var fine: bool = bool(rb.get("ok", false)) and (rb.get("warnings", []) as Array).has("bad_leg_reset") and bool(rb.leg.home)
		if fine:
			var sv: Dictionary = rb.save
			fine = (sv.log as Array).size() >= (good.log as Array).size() and (sv.postcards as Array).size() == (good.postcards as Array).size() \
				and int(rb.leg.index) > int(good.current_leg.index) and int(sv.trip.index) >= int(good.trip.index)
			var later: Dictionary = LshuClock.resolve(sv, _at(5, _hm("15:00")), pool, cfg)
			var ids: Dictionary = {}
			for pc: Variant in later.save.postcards as Array:
				if ids.has((pc as Dictionary).id):
					fine = false
				ids[(pc as Dictionary).id] = true
			fine = fine and bool(later.ok) and int(later.leg.index) > int(rb.leg.index)
		results.append("%s:%s" % [str(rb.get("ok", "error")), rb.get("substate", "-")])
		ok_all = ok_all and fine
	_check("review_damaged_leg_recovers", ok_all,
		"4 damaged saves (missing road_end, leg stub, text time, null seed) -> %s; history kept, numbering continues" % str(results))


## A crash leaves save.lock behind with a fresh heartbeat. If the pid in it is gone, the next launch
## must not sit read-only for 15 minutes; a live owner is still respected.
func test_review_dead_lock_owner() -> void:
	var dir: String = tmp_root.path_join("save_lock_dead")
	DirAccess.make_dir_recursive_absolute(dir)
	var now: float = _at(0, _hm("10:00"))
	_write_text(dir.path_join("save.lock"), JSON.stringify({"pid": 4194305, "token": "crashed", "heartbeat_unix": now - 30.0}))
	var a: LshuSave = LshuSave.new(dir)
	var oa: Dictionary = a.open(now)
	var wa: bool = a.write({"seed": 1}, now)
	a.close()
	var dir2: String = tmp_root.path_join("save_lock_live")
	DirAccess.make_dir_recursive_absolute(dir2)
	_write_text(dir2.path_join("save.lock"), JSON.stringify({"pid": 1, "token": "someone", "heartbeat_unix": now - 30.0}))
	var b: LshuSave = LshuSave.new(dir2)
	var ob: Dictionary = b.open(now)
	_check("review_dead_lock_owner", not bool(oa.read_only) and wa and bool(ob.read_only),
		"fresh lock of a dead pid: read_only=%s write=%s; fresh lock of a live pid: read_only=%s" % [str(oa.read_only), str(wa), str(ob.read_only)])
	b.close()


## When the tile on screen leaves the pool between sessions but its place still has tiles, he stays
## at the same place (the log, the stamp and recent_places all keep agreeing).
func test_review_tile_removed_keeps_place() -> void:
	var r: Dictionary = LshuClock.resolve({"seed": 66}, _at(0, _hm("09:00")), pool, cfg)
	var moved: int = 0
	var n: int = 0
	var s: Dictionary = r.save
	for h: int in range(10, 60, 3):
		var rr: Dictionary = LshuClock.resolve(s, _at(0, 0) + float(h) * 3600.0, pool, cfg)
		s = rr.save
		if bool(rr.leg.home):
			continue
		var gone: String = String(rr.leg.tile)
		var smaller: Array = pool.filter(func(e: Dictionary) -> bool: return String(e.id) != gone)
		var r3: Dictionary = LshuClock.resolve(s, float(rr.now) + 1.0, smaller, cfg)
		n += 1
		if String(r3.leg.place) != String(rr.leg.place) or String(r3.leg.tile) == gone:
			moved += 1
	_check("review_tile_removed_keeps_place", n >= 8 and moved == 0,
		"%d stops whose tile was dropped from the pool: moved to another place %d" % [n, moved])


## --lshu-clock-scale=60: one 2 s tick is 120 logic seconds. A tick that arrives 3.5 s late
## (210 s) must still be handled live (walk-out, arrive...), not as an offline catch-up.
func test_review_scaled_clock_stays_live() -> void:
	var scale: float = 60.0
	var c60: Dictionary = LshuClock.scaled_config(cfg, scale)
	var r: Dictionary = LshuClock.resolve({"seed": 44}, _at(0, _hm("09:00")), pool, c60)
	var s: Dictionary = r.save
	var t: float = float(int((s.current_leg as Dictionary).depart)) - 600.0
	var live_all: bool = true
	var types: Array = []
	var i: int = 0
	while t < float(int((r.save.current_leg as Dictionary).road_end)) + 1200.0:
		i += 1
		t += (3.5 if i % 5 == 0 else 2.0) * scale
		var rr: Dictionary = LshuClock.resolve(s, t, pool, c60)
		s = rr.save
		live_all = live_all and bool(rr.live)
		types.append_array(_types(rr.events))
	var plain: Dictionary = LshuClock.resolve(s, t + 3.5 * scale, pool, cfg)
	_check("review_scaled_clock_stays_live", live_all and types.has("home_leave") and types.has("arrive") and not types.has("catchup")
		and not bool(plain.live),
		"60x, ticks every 2 s with every 5th 3.5 s late: all live=%s, events %s; same late tick with the unscaled config live=%s"
		% [str(live_all), str(_type_counts_arr(types)), str(plain.live)])


func _type_counts_arr(types: Array) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in types:
		out[String(k)] = int(out.get(String(k), 0)) + 1
	return out


## The copywriter's library lists kit aliases as strings and numbers ("bloom", "encounter", 3).
## Godot reads 3 as a float and String(3.0) is not a valid constructor, so normalize_library()
## used to abort and every postcard back came out empty. Checked on an inline case and on the
## recovered copywriter file (fixtures/postcard_lines_rich_recovered.json).
func test_review_rich_library_numeric_aliases() -> void:
	var inline: Dictionary = {
		"lines": {"time": {"day": [{"id": "t", "text": "白天句"}]}, "kit": {"bloom": [{"id": "k", "text": "拾花句"}]},
			"terrain": {"grass": [{"id": "g", "text": "草地句"}]}, "home": [{"id": "h", "text": "到家句"}]},
		"kits": {"bloom": {"aliases": ["bloom", "encounter", 3]}}, "terrain_resolve": {"from_biome": {"autumn": "grass"}},
	}
	var parsed_inline: Dictionary = JSON.parse_string(JSON.stringify(inline))
	var norm: Dictionary = LshuPostcardText.normalize_library(parsed_inline)
	var inline_ok: bool = not norm.is_empty() and ((norm.get("kit", {}) as Dictionary).get("encounter", []) as Array).size() == 1
	var fixture: String = "res://tools/traveler/lshu/tests/fixtures/postcard_lines_rich_recovered.json"
	var rich: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(fixture))
	var c_rich: Dictionary = cfg.duplicate(true)
	c_rich["postcard_lines"] = rich
	var cr: Dictionary = LshuClock.compile_config(c_rich)
	var cards: int = 0
	var empty: int = 0
	for i: int in 200:
		var pc: Dictionary = {"line_seed": LshuHash.hash3(i, 5, 1), "band": ["morning", "day", "sunset", "night"][i % 4],
			"kit": KITS[i % 4], "biome": BIOMES[(i / 4) % 4], "home": i % 10 == 0}
		var got: Array[String] = LshuPostcardText.compose(pc, cr.get("lines", {}) as Dictionary, "")
		cards += 1
		if got.is_empty() or got.size() > 2:
			empty += 1
	_check("review_rich_library_numeric_aliases", inline_ok and empty == 0,
		"inline aliases [\"bloom\", \"encounter\", 3]: normalised=%s; recovered copywriter library: %d cards, %d empty" % [str(inline_ok), cards, empty])


# =============================================================================================
# Helpers

func _check(name: String, cond: bool, detail: String) -> void:
	if cond:
		passed += 1
		print("PASS %s | %s" % [name, detail])
	else:
		failed += 1
		print("FAIL %s | %s" % [name, detail])


func _synthetic_pool(n_places: int, n_kits: int, opts: Dictionary) -> Array:
	var out: Array = []
	for p: int in n_places:
		for k: int in n_kits:
			var kit: String = KITS[k]
			var e: Dictionary = {
				"id": "tile_%02d_%d" % [p, k], "place": "place_%02d" % p, "name": "地点%02d" % p, "kit": kit,
				"layout": (p * 7 + k * 3) % 6, "biome": BIOMES[p % 4], "is_home": p == 0, "night_ok": true,
				"sub": "测试地点%02d的一句话。" % p if p % 2 == 0 else "",
			}
			if bool(opts.get("no_night_look", false)) and kit == "look":
				e["night_ok"] = false
			var every: int = int(opts.get("no_fire_every", 0))
			if every > 0 and p % every == 1:
				e["fire"] = false
			out.append(e)
	return out


func _chain(seed: int, start: float, n_stops: int, places: Array, c: Dictionary) -> Array:
	var r: Dictionary = LshuClock.resolve({"seed": seed}, start, places, c)
	var s: Dictionary = r.save
	var legs: Array = [r.leg]
	var stops: int = 0
	var guard: int = 0
	while stops < n_stops and guard < 50000:
		guard += 1
		var t: float = float(int((s.current_leg as Dictionary).road_end))
		r = LshuClock.resolve(s, t, places, c)
		s = r.save
		legs.append(r.leg)
		if not bool(r.leg.home):
			stops += 1
	return legs


func _run_to(seed: int, start: float, end: float, step: float) -> Dictionary:
	var r: Dictionary = LshuClock.resolve({"seed": seed}, start, pool, cfg)
	var s: Dictionary = r.save
	var t: float = start
	while t < end:
		t = minf(t + step, end)
		r = LshuClock.resolve(s, t, pool, cfg)
		s = r.save
	return s


## Same rule as the clock: an explicit `fire` field wins, otherwise camp / tea kits have a fire.
func _tile_has_fire(e: Dictionary) -> bool:
	if e.has("fire") and e.fire != null:
		return bool(e.fire)
	return ["camp", "tea"].has(String(e.get("kit", "")))


func _non_home(legs: Array) -> Array:
	return legs.filter(func(l: Dictionary) -> bool: return not bool(l.home))


func _tile(id: String) -> Dictionary:
	return _tile_in(pool, id)


func _tile_in(places: Array, id: String) -> Dictionary:
	for e: Variant in places:
		if String((e as Dictionary).id) == id:
			return e
	return {}


func _home_place() -> String:
	for e: Variant in pool:
		if bool((e as Dictionary).is_home):
			return String((e as Dictionary).place)
	return ""


func _leg_key(leg: Dictionary) -> String:
	return "%d:%s@%d-%d" % [int(leg.index), String(leg.tile), int(leg.arrive), int(leg.road_end)]


func _types(events: Array) -> Array:
	var out: Array = []
	for e: Variant in events:
		out.append(String((e as Dictionary).type))
	return out


func _type_counts(events: Array) -> Dictionary:
	var out: Dictionary = {}
	for e: Variant in events:
		var k: String = String((e as Dictionary).type)
		out[k] = int(out.get(k, 0)) + 1
	return out


func _count_by(arr: Array, key: String) -> Dictionary:
	var out: Dictionary = {}
	for e: Variant in arr:
		var k: String = String((e as Dictionary).get(key, ""))
		out[k] = int(out.get(k, 0)) + 1
	return out


func _live_pc_ids(events: Array) -> Array:
	var out: Array = []
	for e: Variant in events:
		if String((e as Dictionary).type) == "postcard":
			out.append(String((e as Dictionary).postcard))
	return out


func _night_departures(log_arr: Array) -> Array:
	var out: Array = []
	for e: Variant in log_arr:
		var d: Dictionary = e
		if String(d.get("type", "")) == "leg" and not _is_day_departure(_sod(int(d.depart))) and int(d.k) > 0:
			out.append(int(d.k))
	return out


func _is_day_departure(sod: int) -> bool:
	return sod >= _hm("07:00") and sod <= _hm("21:30")


func _at(day: int, sod: int) -> float:
	return float(base_midnight + day * 86400 + sod)


func _sod(t: int) -> int:
	return posmod(t + tz_s, 86400)


func _hm(s: String) -> int:
	var p: PackedStringArray = s.split(":")
	return (p[0].to_int() * 60 + p[1].to_int()) * 60


func _hms(sod: int) -> String:
	return "%02d:%02d" % [sod / 3600, (sod % 3600) / 60]


func _fmt(t: float) -> String:
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(int(floor(t)) + tz_s)
	return "%d/%d %02d:%02d" % [int(d.month), int(d.day), int(d.hour), int(d.minute)]


func _write_text(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _rm_rf(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d: String in DirAccess.get_directories_at(path):
		_rm_rf(path.path_join(d))
	for f: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
