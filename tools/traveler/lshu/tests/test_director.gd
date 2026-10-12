extends SceneTree
## 第四幕「L叔在哪儿」· headless tests of the director's pure rules (scripts/traveler/lshu/lshu_director.gd) and of the
## click-him photo record against the loop: flags, save dir choice, tick / transition timing under a scaled clock, the
## frame-cap policy, the fire level, and "snap" records in save.postcards (the route, the loop's postcard ids and its
## pending queue are the same with and without them; the UI data layer keeps the loop card as a stop's thumbnail).
## No ids are written here: the real pool is read at run time.
##   Godot --headless --path . --script res://tools/traveler/lshu/tests/test_director.gd
## Last line: LSHU_DIRECTOR_TESTS passed=N failed=M

const DIRECTOR: GDScript = preload("res://scripts/traveler/lshu/lshu_director.gd")
const CLOCK: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const SAVE: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const POOL: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_pool_adapter.gd")
const UI_DATA: GDScript = preload("res://scripts/traveler/lshu/ui/lshu_ui_data.gd")

var passed: int = 0
var failed: int = 0

func _initialize() -> void:
	_test_args()
	_test_timing()
	_test_fps()
	_test_fire()
	_test_config()
	_test_snaps_with_loop()
	print("LSHU_DIRECTOR_TESTS passed=%d failed=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)

func _ok(name: String, cond: bool, detail: Variant = "") -> void:
	if cond:
		passed += 1
		print("PASS ", name)
	else:
		failed += 1
		print("FAIL ", name, " ", str(detail))

func _test_args() -> void:
	var a: Dictionary = DIRECTOR.call("parse_args", PackedStringArray(["--lshu-clock-scale=600", "--lshu-save-dir=/tmp/x", "--lshu-now=1790000000", "--lshu-dev", "--lshu-fps-cap=off"]))
	_ok("args_all", float(a.scale) == 600.0 and str(a.save_dir) == "/tmp/x" and float(a.now) == 1790000000.0 and bool(a.dev) and not bool(a.fps_cap), a)
	var b: Dictionary = DIRECTOR.call("parse_args", PackedStringArray([]))
	_ok("args_default", float(b.scale) == 1.0 and str(b.save_dir) == "" and float(b.now) < 0.0 and not bool(b.dev) and bool(b.fps_cap), b)
	_ok("save_dir_real", str(DIRECTOR.call("save_dir_for", b)) == str(SAVE.call("default_dir", false)))
	var c: Dictionary = DIRECTOR.call("parse_args", PackedStringArray(["--lshu-clock-scale=60"]))
	_ok("save_dir_scaled_is_dev_dir", str(DIRECTOR.call("save_dir_for", c)) == str(SAVE.call("default_dir", true)))
	var d: Dictionary = DIRECTOR.call("parse_args", PackedStringArray(["--lshu-now=1790000000"]))
	_ok("save_dir_moved_clock_is_dev_dir", str(DIRECTOR.call("save_dir_for", d)) == str(SAVE.call("default_dir", true)))
	_ok("save_dir_explicit_wins", str(DIRECTOR.call("save_dir_for", a)) == "/tmp/x")

func _test_timing() -> void:
	_ok("tick_1x", is_equal_approx(float(DIRECTOR.call("tick_interval", 2.0, 1.0, 0.05)), 2.0))
	_ok("tick_60x", is_equal_approx(float(DIRECTOR.call("tick_interval", 2.0, 60.0, 0.05)), 0.05))
	_ok("tick_10x", is_equal_approx(float(DIRECTOR.call("tick_interval", 2.0, 10.0, 0.05)), 0.2))
	_ok("fade_1x", is_equal_approx(float(DIRECTOR.call("transition_s", 2.5, 1.0, 150.0)), 2.5))
	_ok("fade_60x", is_equal_approx(float(DIRECTOR.call("transition_s", 2.5, 60.0, 150.0)), 2.5))
	_ok("fade_600x", is_equal_approx(float(DIRECTOR.call("transition_s", 2.5, 600.0, 150.0)), 0.25))

func _test_fps() -> void:
	# Carlos 2026-09-27: no unfocused throttling — the act runs beside other apps like a screensaver; never below 30
	var f: Dictionary = {"focused": 30, "unfocused": 10}
	_ok("fps_focused", int(DIRECTOR.call("fps_for", true, false, f)) == 30)
	_ok("fps_unfocused_never_below_30", int(DIRECTOR.call("fps_for", false, false, f)) == 30)
	_ok("fps_minimized_never_below_30", int(DIRECTOR.call("fps_for", true, true, f)) == 30)
	_ok("fps_missing_config_30", int(DIRECTOR.call("fps_for", false, false, {})) == 30)
	var cfg: Dictionary = DIRECTOR.call("load_config")
	var fc: Dictionary = cfg.get("fps", {})
	_ok("fps_config_unfocused_is_30", int(fc.get("unfocused", -1)) == 30 and int(fc.get("focused", -1)) == 30, fc)
	_ok("fps_config", int(DIRECTOR.call("fps_for", true, false, fc)) == 30 and int(DIRECTOR.call("fps_for", false, false, fc)) == 30
		and int(DIRECTOR.call("fps_for", false, true, fc)) == 30, fc)

func _test_fire() -> void:
	var fc: Dictionary = {"low_level": 0.45, "low_fade_logic_s": 120.0, "ember_level": 0.1, "ember_fade_logic_s": 180.0}
	var leg: Dictionary = {"night": false, "road_start": 1000, "tent_in": -1, "night_end": -1}
	_ok("fire_lit_before_leaving", is_equal_approx(float(DIRECTOR.call("fire_level_at", leg, 999.0, fc)), 1.0))
	_ok("fire_embers_after_road_start", is_equal_approx(float(DIRECTOR.call("fire_level_at", leg, 1000.0 + 180.0, fc)), 0.1))
	var mid: float = float(DIRECTOR.call("fire_level_at", leg, 1090.0, fc))
	_ok("fire_fades_gradually", mid < 1.0 and mid > 0.1, mid)
	var prev: float = 1.0
	var mono: bool = true
	for s: int in 40:
		var v: float = float(DIRECTOR.call("fire_level_at", leg, 1000.0 + float(s) * 5.0, fc))
		mono = mono and v <= prev + 1e-6
		prev = v
	_ok("fire_monotonic_to_embers", mono)
	var night: Dictionary = {"night": true, "tent_in": 5000, "night_end": 9000, "road_start": 12000}
	_ok("fire_lit_before_tent", is_equal_approx(float(DIRECTOR.call("fire_level_at", night, 4999.0, fc)), 1.0))
	_ok("fire_low_in_tent", is_equal_approx(float(DIRECTOR.call("fire_level_at", night, 7000.0, fc)), 0.45))
	_ok("fire_back_up_after_night_end", is_equal_approx(float(DIRECTOR.call("fire_level_at", night, 9000.0 + 120.0, fc)), 1.0))
	_ok("fire_embers_after_overnight", is_equal_approx(float(DIRECTOR.call("fire_level_at", night, 12000.0 + 180.0, fc)), 0.1))
	_ok("fire_no_leg", is_equal_approx(float(DIRECTOR.call("fire_level_at", {}, 5.0, fc)), 1.0))
	var no_fire: Dictionary = {"fire": false, "night": false, "road_start": 1000}
	_ok("fire_none_on_fireless_tile", is_equal_approx(float(DIRECTOR.call("fire_level_at", no_fire, 1500.0, fc)), 1.0))

func _test_config() -> void:
	var cfg: Dictionary = DIRECTOR.call("load_config")
	_ok("director_json", str(cfg.get("schema", "")) == "lshu.director.v1" and cfg.has("switch") and cfg.has("fire") and cfg.has("fps") and cfg.has("snap"))
	var sw: Dictionary = cfg.get("switch", {})
	_ok("fade_2_to_3_s", float(sw.get("fade_s", 0.0)) >= 2.0 and float(sw.get("fade_s", 0.0)) <= 3.0, sw.get("fade_s"))

## A 10-day route with a click-him photo on every third stop (as the director records it) against the same route without:
## the loop must not see them.
func _test_snaps_with_loop() -> void:
	var places: Array = POOL.call("load_places")
	_ok("pool_loaded", places.size() > 0, places.size())
	var cfg: Dictionary = CLOCK.call("scaled_config", CLOCK.call("load_config"), 10.0)
	cfg["tz_offset_minutes"] = 480
	var c: Dictionary = CLOCK.call("compile_config", cfg)
	var start: float = 1790204400.0
	var a: Dictionary = _route(places, cfg, c, start, false)
	var b: Dictionary = _route(places, cfg, c, start, true)
	_ok("snaps_recorded", int(b.snaps) > 5, b.snaps)
	_ok("route_unchanged_by_snaps", a.legs == b.legs and (a.legs as Array).size() > 20, [(a.legs as Array).size(), (b.legs as Array).size()])
	_ok("loop_postcard_ids_unchanged", a.pc_ids == b.pc_ids and (a.pc_ids as Array).size() > 3, [(a.pc_ids as Array).size(), (b.pc_ids as Array).size()])
	_ok("snaps_never_pending", not bool(b.snap_pending), b.snap_pending)
	_ok("snaps_survive_resolve", int(b.snaps_in_save) == int(b.snaps), [b.snaps_in_save, b.snaps])
	var sv: Dictionary = b.save
	var unread: Array = SAVE.call("unread", sv)
	var unread_snaps: int = 0
	for v: Variant in unread:
		if str((v as Dictionary).get("type", "")) == "snap":
			unread_snaps += 1
	_ok("snaps_unread_until_read", unread_snaps == int(b.snaps), [unread_snaps, b.snaps])
	var snap_ok: bool = true
	for v2: Variant in sv.get("postcards", []) as Array:
		var pc: Dictionary = v2
		if str(pc.get("type", "")) == "snap":
			snap_ok = snap_ok and str(pc.id).begins_with("snap_") and str(pc.shot) == "snap" and (pc.get("text", []) as Array).size() >= 1 \
				and str(pc.get("signature", "")) != "" and str(pc.get("date", "")) != "" and pc.has("stamp") and pc.has("line_ids")
	_ok("snap_record_fields", snap_ok)
	# the same stop and moment give the same photo record (deterministic text)
	var leg: Dictionary = (sv.current_leg as Dictionary).duplicate(true)
	var r1: Dictionary = DIRECTOR.call("make_snap_record", sv, leg, float(leg.arrive) + 600.0, c, 1, "snap_x_1", "/tmp/a.jpg")
	var r2: Dictionary = DIRECTOR.call("make_snap_record", sv, leg, float(leg.arrive) + 600.0, c, 1, "snap_x_1", "/tmp/a.jpg")
	_ok("snap_record_deterministic", JSON.stringify(r1) == JSON.stringify(r2))
	_ok("snap_id_format", str(DIRECTOR.call("snap_id", 0x1234abcd, 7, 1)) == "snap_1234abcd_7_1")
	# travel book: a stop with both a loop postcard and a photo shows the loop postcard
	var both: int = 0
	var loop_wins: bool = true
	var by_leg: Dictionary = {}
	for v3: Variant in sv.get("postcards", []) as Array:
		var pc3: Dictionary = v3
		if str(pc3.get("file", "")) == "":
			continue
		var k: int = int(pc3.leg)
		if not by_leg.has(k):
			by_leg[k] = []
		(by_leg[k] as Array).append(pc3)
	var trips: Array = UI_DATA.call("build_trips", sv, 28800)
	for t: Variant in trips:
		for st: Variant in (t as Dictionary).get("stops", []) as Array:
			var sd: Dictionary = st
			var k2: int = int(sd.get("k", -1))
			if by_leg.has(k2) and (by_leg[k2] as Array).size() >= 2:
				both += 1
				loop_wins = loop_wins and str((sd.postcard as Dictionary).get("type", "")) != "snap"
	_ok("book_prefers_loop_postcard", both >= 1 and loop_wins, [both, loop_wins])

func _route(places: Array, cfg: Dictionary, c: Dictionary, start: float, with_snaps: bool) -> Dictionary:
	var save: Dictionary = {}
	var t: float = start
	var snaps: int = 0
	var snap_pending: bool = false
	var done_legs: Dictionary = {}
	while t < start + 10.0 * 86400.0:
		var r: Dictionary = CLOCK.call("resolve", save, t, places, cfg)
		save = r.save
		# every postcard gets an image at once (as the director does when it renders)
		for id: Variant in (save.pending_renders as Array).duplicate():
			SAVE.call("complete_render", save, str(id), "/tmp/" + str(id) + ".jpg")
		var leg: Dictionary = save.current_leg
		var k: int = int(leg.index)
		if with_snaps and str(r.substate) == "STAY" and k % 3 == 0 and not done_legs.has(k):
			done_legs[k] = true
			var n: int = int(DIRECTOR.call("snaps_on_leg", save, k))
			var id2: String = str(DIRECTOR.call("snap_id", int(save.seed), k, n + 1))
			var rec: Dictionary = DIRECTOR.call("make_snap_record", save, leg, t, c, n + 1, id2, "/tmp/" + id2 + ".jpg")
			(save.postcards as Array).append(rec)
			snaps += 1
		for pid: Variant in save.pending_renders as Array:
			if str(pid).begins_with("snap_"):
				snap_pending = true
		t += 120.0
	var legs: Array = []
	for row: Variant in save.log as Array:
		var rd: Dictionary = row
		if str(rd.get("type", "")) == "leg":
			legs.append("%d:%s:%d" % [int(rd.k), str(rd.tile), int(rd.arrive)])
	var pc_ids: Array = []
	var in_save: int = 0
	for v: Variant in save.postcards as Array:
		var pc: Dictionary = v
		if str(pc.get("type", "")) == "snap":
			in_save += 1
		else:
			pc_ids.append(str(pc.id))
	return {"legs": legs, "pc_ids": pc_ids, "snaps": snaps, "snaps_in_save": in_save, "snap_pending": snap_pending, "save": save}
