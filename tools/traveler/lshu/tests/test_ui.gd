extends SceneTree
## Act 4 「L叔在哪儿」 UI tests. Headless, no renderer needed:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path <project> \
##       --script res://tools/traveler/lshu/tests/test_ui.gd
## Data helpers (dates, trips, routes, postmark, caption rules, wrapping), UI behaviour through real
## input events with shortened timers (caption, stamp, viewer, book, away card, key L / Esc, idle,
## click pass-through), scale at 1920x1080 / 3440x1440 / 640x360 with and without the project's
## canvas_items stretch, year-scale cost, and a scan of the UI code for tile / asset ids.
## Prints PASS / FAIL / METRIC lines and LSHU_UI_TESTS passed=N failed=M; exit code 0 only when M == 0.

const Sample := preload("res://tools/traveler/lshu/tests/ui_sample_data.gd")
const UiScript := preload("res://scripts/traveler/lshu/ui/lshu_ui.gd")
const D := preload("res://scripts/traveler/lshu/ui/lshu_ui_data.gd")
const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")
const LshuSave := preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const LshuClock := preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const LshuPostcardText := preload("res://scripts/traveler/lshu/loop/lshu_postcard_text.gd")

const TZ: int = 480 * 60


class Probe extends Node:
	var keys_l: int = 0
	var clicks: int = 0

	func _unhandled_key_input(e: InputEvent) -> void:
		var k: InputEventKey = e as InputEventKey
		if k != null and k.pressed and k.keycode == KEY_L:
			keys_l += 1

	func _unhandled_input(e: InputEvent) -> void:
		var mb: InputEventMouseButton = e as InputEventMouseButton
		if mb != null and mb.pressed:
			clicks += 1


var passed: int = 0
var failed: int = 0
var data: Dictionary = {}
var ui: CanvasLayer
var probe: Probe
var reads: Array = []
var closes: Array = []
var away_lines: Array = []
var busy_log: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var t0: int = Time.get_ticks_msec()
	data = Sample.build(OS.get_temp_dir().path_join("lshu_ui_tests_%d" % OS.get_process_id()), false)
	_check("sample_built", (data.save.postcards as Array).size() >= 4 and not (data.arrive_r as Dictionary).is_empty(),
		"postcards=%d log=%d" % [(data.save.postcards as Array).size(), (data.save.log as Array).size()])
	_data_tests()
	await _ui_tests()
	await _scale_tests()
	_cost_tests()
	_id_scan()
	print("METRIC total_ms %d" % (Time.get_ticks_msec() - t0))
	print("LSHU_UI_TESTS passed=%d failed=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)


# ============================================================================== data

func _data_tests() -> void:
	var now: int = Sample.local_unix(2026, 9, 24, 12, 0)
	var a: int = Sample.local_unix(2026, 9, 23, 9, 0)
	_eq("date_same_day", D.date_range_label(a, a + 3600, TZ, now), "9月23日")
	_eq("date_same_month", D.date_range_label(a, a + 86400, TZ, now), "9月23日–24日")
	_eq("date_cross_month", D.date_range_label(Sample.local_unix(2026, 9, 30, 9, 0), Sample.local_unix(2026, 10, 1, 9, 0), TZ, now), "9月30日–10月1日")
	_eq("date_cross_year", D.date_range_label(Sample.local_unix(2026, 12, 31, 9, 0), Sample.local_unix(2027, 1, 1, 9, 0), TZ, now), "2026年12月31日–2027年1月1日")
	_eq("date_past_year", D.date_range_label(Sample.local_unix(2025, 5, 2, 9, 0), Sample.local_unix(2025, 5, 3, 9, 0), TZ, now), "2025年5月2日–3日")
	_eq("gap_minutes", D.gap_label(40 * 60), "40 分钟")
	_eq("gap_hours", D.gap_label(5.2 * 3600), "约 5 小时")
	_eq("gap_days", D.gap_label(3.1 * 86400), "约 3 天")

	var save: Dictionary = data.save
	var trips: Array = D.build_trips(save, TZ, now)
	var idx_desc: bool = true
	for i: int in range(1, trips.size()):
		idx_desc = idx_desc and int((trips[i - 1] as Dictionary).trip) > int((trips[i] as Dictionary).trip)
	_check("trips_newest_first", trips.size() >= 2 and idx_desc, "trips=%d" % trips.size())
	var first_launch_only: bool = false
	for t: Variant in trips:
		var stops: Array = (t as Dictionary).stops
		if stops.size() == 1 and bool((stops[0] as Dictionary).home):
			first_launch_only = true
	_check("first_launch_home_trip_left_out", not first_launch_only, "")
	var done: Dictionary = {}
	var live: Dictionary = {}
	for t: Variant in trips:
		if bool((t as Dictionary).home) and not bool((t as Dictionary).in_progress):
			done = t
		if bool((t as Dictionary).in_progress):
			live = t
	var done_text: String = D.route_text(done)
	_check("finished_trip_ends_home", done_text.ends_with("→ 回家") and done_text.contains("：") and done_text.contains(" → "), done_text.left(120))
	_check("finished_trip_date_range", String(done.date_label).contains("–"), String(done.date_label))
	var live_text: String = D.route_text(live)
	_check("current_trip_ends_ellipsis", live_text.ends_with("→ …"), live_text.right(60))
	var nights: int = 0
	for st: Variant in done.stops:
		if bool((st as Dictionary).night):
			nights += 1
	_check("night_stop_marked", nights == 0 or done_text.contains("（过夜）→"), "nights=%d" % nights)
	# every rendered postcard hangs on exactly one stop
	var attached: Dictionary = {}
	var dup: int = 0
	for t: Variant in trips:
		for st: Variant in (t as Dictionary).stops:
			var pc: Dictionary = (st as Dictionary).postcard
			if not pc.is_empty():
				dup += 1 if attached.has(pc.id) else 0
				attached[pc.id] = true
	var rendered: int = 0
	for pc: Variant in save.postcards:
		if String((pc as Dictionary).file) != "" and int((pc as Dictionary).trip) > 0:
			rendered += 1
	_check("postcards_attached_once", attached.size() == rendered and dup == 0, "attached=%d rendered=%d dup=%d" % [attached.size(), rendered, dup])
	var route_only: String = " ".join(D.route_items(done)) + " ".join(D.route_items(live))
	var digits: RegEx = RegEx.new()
	digits.compile("[0-9０-９]|张|次|完成")
	_check("no_counts_in_route", digits.search(route_only) == null, "")

	# compacted log + long_way
	var log: Array = []
	var k: int = 0
	var pcs: Array = []
	var base: int = Sample.local_unix(2026, 3, 1, 8, 0)
	for trip: int in range(1, 7):
		for i: int in 10:
			var home: bool = i == 9
			log.append({"type": "leg", "k": k, "trip": trip, "tile": "t%d" % k, "place": "p%d" % i, "name": "地点%d" % i,
				"kit": "look", "home": home, "night": i == 4, "arrive": base + k * 3600, "depart": base + k * 3600 + 3000, "road_end": base + (k + 1) * 3600})
			if i == 3:
				pcs.append({"id": "pc_x_%d" % k, "leg": k, "trip": trip, "file": "/nonexistent/%d.jpg" % k, "read": true, "band": "day"})
			k += 1
	log.append({"type": "long_way", "trip": 6, "from": base + k * 3600, "to": base + k * 3600 + 86400 * 5})
	var compacted: Array = LshuSave.compact_log(log, 25)
	var syn: Dictionary = {"log": compacted, "postcards": pcs, "current_leg": {}}
	var st2: Array = D.build_trips(syn, TZ, now)
	var summaries: int = 0
	var summary_ok: bool = true
	for t: Variant in st2:
		var td: Dictionary = t
		if bool(td.summary):
			summaries += 1
			var items: PackedStringArray = D.route_items(td)
			summary_ok = summary_ok and (td.places as Array).size() <= 8 and items[items.size() - 1] == "回家" and (td.postcards as Array).size() == 1
	_check("compacted_trips_render", summaries >= 1 and summary_ok and st2.size() == 6, "trips=%d summaries=%d" % [st2.size(), summaries])
	_check("long_way_in_route", D.route_text(st2[0] as Dictionary).contains("走了很远的路"), D.route_text(st2[0] as Dictionary).right(40))

	# postmark
	var pc0: Dictionary = {"name": "长安 · 石窟台地", "unix": Sample.local_unix(2026, 9, 23, 18, 40), "band": "sunset", "home": false}
	var pm: Dictionary = D.postmark_info(pc0, TZ)
	_check("postmark_fields", String(pm.place) == "长安" and String(pm.date) == "2026年9月23日" and String(pm.band_label) == "昏" and String(pm.home_mark) == "",
		JSON.stringify(pm))
	var labels: Array = []
	for b: String in ["morning", "day", "sunset", "night", "dusk"]:
		labels.append(D.slot_label(b))
	_eq("postmark_band_labels", "".join(PackedStringArray(labels)), "晨昼昏夜昏")
	_eq("postmark_home_mark", String(D.postmark_info({"name": "x", "home": true, "band": "night"}, TZ).home_mark), "家")

	# caption rules, examples found in the real pool at run time
	var city_tile: String = ""
	var blocked_tile: String = ""
	var nature: Dictionary = {}
	for p: Variant in data.places:
		var pd: Dictionary = p
		var city: String = D.tile_city(String(pd.id))
		if city != "" and D.city_epithet(city) != "" and city_tile == "":
			city_tile = String(pd.id)
		elif city != "" and D.city_epithet(city) == "" and blocked_tile == "":
			blocked_tile = String(pd.id)
		elif city == "" and String(pd.get("sub", "")) != "" and nature.is_empty():
			nature = pd
	var c1: Dictionary = D.place_caption({"tile": city_tile, "name": "n", "sub": "建模说明不该出现"})
	_check("caption_city_epithet", city_tile != "" and String(c1.sub) != "" and String(c1.sub) != "建模说明不该出现", "%s -> %s" % [city_tile, c1.sub])
	var c2: Dictionary = D.place_caption({"tile": blocked_tile, "name": "n"})
	_check("caption_blocked_epithet_omitted", blocked_tile == "" or String(c2.sub) == "", "%s -> '%s'" % [blocked_tile, c2.sub])
	var c3: Dictionary = D.place_caption({"tile": String(nature.get("id", "")), "name": String(nature.get("name", "")), "sub": String(nature.get("sub", ""))})
	_check("caption_nature_sub", not nature.is_empty() and String(c3.sub) == String(nature.sub), String(c3.sub))
	_eq("caption_override", String(D.place_caption({"name": "a", "caption_sub": "b"}).sub), "b")

	# wrapping
	var font: Font = S.FONT_REGULAR
	var worst: float = 0.0
	var bad_start: int = 0
	var joined_ok: bool = true
	var lib: Dictionary = D.lines_library()
	var all_lines: Array = []
	for grp: Variant in (lib.get("lines", {}) as Dictionary).values():
		if grp is Dictionary:
			for arr: Variant in (grp as Dictionary).values():
				all_lines.append_array(arr as Array)
		elif grp is Array:
			all_lines.append_array(grp as Array)
	for item: Variant in all_lines:
		var text: String = String((item as Dictionary).get("text", "")) if item is Dictionary else String(item)
		for w: float in [180.0, 260.0, 420.0]:
			var out: PackedStringArray = S.wrap_cjk(text, font, 24, w)
			joined_ok = joined_ok and "".join(out) == text
			for i: int in out.size():
				worst = maxf(worst, font.get_string_size(out[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x - w)
				if i > 0 and out[i].length() > 0 and S.NO_LINE_START.contains(out[i].substr(0, 1)):
					bad_start += 1
	_check("wrap_cjk_library", all_lines.size() >= 60 and joined_ok and bad_start == 0 and worst <= 26.0,
		"lines=%d overflow_px_max=%.1f bad_starts=%d" % [all_lines.size(), worst, bad_start])

	# away text
	var aw: Dictionary = D.away_text({"gap_s": 6.5 * 3600, "places": ["甲", "乙"], "places_total": 9}, "丙")
	_check("away_text", String(aw.when) == "你离开了约 7 小时" and String(aw.body).begins_with("他走过了 … → 甲") and String(aw.now) == "现在他在丙。", JSON.stringify(aw))
	_eq("away_route_drops_current", String(D.away_text({"gap_s": 9000.0, "places": ["甲", "丙"], "places_total": 2}, "丙").body), "他走过了 甲")
	_eq("away_text_far", String(D.away_text({"gap_s": 90000.0, "far_jump": true, "places": []}, "丙").now), "他走了很远的路，现在在丙。")
	_eq("away_text_stayed", String(D.away_text({"gap_s": 9000.0, "places": []}, "丙").now), "他一直在丙。")
	# the UI prints the record's own text, never its own
	var same: bool = true
	for pc: Variant in save.postcards:
		same = same and Array(D.postcard_lines(pc as Dictionary)) == ((pc as Dictionary).text as Array)
	_check("back_text_is_record_text", same, "")

	# the away card's line: one road line from the library, fixed per catchup, outside the last 20 cards
	var rich_lib: Dictionary = LshuPostcardText.rich_of(D.lines_library())
	var road_ids: Dictionary = {}
	for item: Variant in ((rich_lib.get("lines", {}) as Dictionary).get("road", []) as Array):
		road_ids[String((item as Dictionary).get("id", ""))] = String((item as Dictionary).get("text", ""))
	var cu: Dictionary = Sample.catchup_event(data.catchup_r)
	var al: Dictionary = D.away_line(save, cu, "day", "look")
	var al2: Dictionary = D.away_line(save, cu, "day", "look")
	var hist: Dictionary = {}
	for ids: Variant in LshuPostcardText.history_from_postcards(save.postcards as Array, LshuPostcardText.window(rich_lib)):
		for id: Variant in ids as Array:
			hist[String(id)] = true
	var al_ids: Array = al.get("line_ids", []) as Array
	_check("away_line_is_one_road_line", al_ids.size() == 1 and road_ids.has(String(al_ids[0])) and String(al.text) == String(road_ids[String(al_ids[0])])
		and String(al.signature) == "L", JSON.stringify(al))
	_check("away_line_stable_and_fresh", JSON.stringify(al) == JSON.stringify(al2) and not hist.has(String(al_ids[0]) if al_ids.size() > 0 else ""), str(al_ids))
	var seen: Dictionary = {}
	for d: int in 12:
		var o2: Dictionary = cu.duplicate()
		o2["to"] = float(cu.get("to", 0)) + 3600.0 * float(d)
		seen[String(D.away_line(save, o2).get("text", ""))] = true
	_check("away_line_varies_by_catchup", seen.size() >= 3, "distinct=%d of 12" % seen.size())


# ============================================================================== behaviour

func _make_ui(px: Vector2i) -> void:
	root.size = px
	probe = Probe.new()
	root.add_child(probe)
	ui = UiScript.new()
	ui.set("caption_hold_s", 0.5)
	ui.set("caption_hover_s", 0.3)
	ui.set("postcard_idle_s", 1.5)
	ui.set("away_hold_s", 0.5)
	ui.set("book_idle_s", 0.9)
	root.add_child(ui)
	ui.call("configure", data.cfg, data.places)
	ui.connect("postcard_read", func(id: String) -> void: reads.append(id))
	ui.connect("postcard_closed", func(id: String, why: String) -> void: closes.append([id, why]))
	ui.connect("away_line_shown", func(ids: Array) -> void: away_lines.append(ids))
	ui.connect("busy_changed", func(b: bool) -> void: busy_log.append(b))
	await _frames(3)


func _free_ui() -> void:
	ui.queue_free()
	probe.queue_free()
	await _frames(2)


func _ui_tests() -> void:
	await _make_ui(Vector2i(1920, 1080))
	var save: Dictionary = data.save
	_check("idle_by_default", not bool(ui.call("is_any_visible")), "")
	# click on empty screen reaches the scene
	_click(Vector2(600, 300))
	await _frames(2)
	_check("idle_click_passes_through", probe.clicks == 1, "probe clicks=%d" % probe.clicks)
	# arrival caption via resolve()
	var ar: Dictionary = data.arrive_r
	ui.call("apply_resolve", ar)
	ui.call("set_unread", [])
	await _frames(2)
	var st: Dictionary = ui.call("state")
	_check("arrive_shows_caption", bool(st.caption.showing) and String(st.caption.title) == String(ar.leg.name) and String(st.caption.sub) != "",
		"%s / %s" % [st.caption.title, st.caption.sub])
	await _wait(2.6)
	_check("caption_fades_after_hold", not bool((ui.call("state") as Dictionary).caption.visible), "")
	_motion(Vector2(700, 400))
	await _frames(2)
	_check("mouse_move_peeks_caption", bool((ui.call("state") as Dictionary).caption.showing), "")
	await _wait(2.4)
	_check("peek_fades_again", not bool((ui.call("state") as Dictionary).caption.visible), "")
	# road caption
	ui.call("handle_event", {"type": "road_start", "tile": ar.leg.tile, "name": ar.leg.name})
	_motion(Vector2(710, 400))
	await _frames(2)
	st = ui.call("state")
	_check("road_caption", String(st.caption.title) == "在路上" and String(st.caption.sub) == "刚离开" + String(ar.leg.name), "%s / %s" % [st.caption.title, st.caption.sub])
	ui.call("hide_caption")
	# stamp
	Sample.reset_unread(data)
	ui.call("set_save", save)
	var unread: Array = LshuSave.unread(save)
	ui.call("set_unread", unread)
	await _frames(2)
	st = ui.call("state")
	_check("stamp_only_with_unread", bool(st.stamp.visible) and int(st.stamp.unread) == unread.size() and unread.size() >= 2, "unread=%d" % unread.size())
	# stamp click -> oldest unread, flip, empty click -> read once
	_click(_center(st.stamp.rect))
	await _wait(0.9)
	st = ui.call("state")
	var id0: String = String((unread[0] as Dictionary).id)
	_check("stamp_click_opens_oldest", bool(st.viewer.open) and String(st.viewer.id) == id0, String(st.viewer.id))
	_check("click_while_open_not_leaked", probe.clicks == 1, "probe clicks=%d" % probe.clicks)
	_click(_center(st.viewer.card_rect))
	await _wait(0.6)
	_check("card_click_flips", bool((ui.call("state") as Dictionary).viewer.back), "")
	_check("busy_signal_on_open", busy_log.size() >= 1 and busy_log.back() == true, str(busy_log))
	for wheel: MouseButton in [MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_UP]:
		var wb: InputEventMouseButton = InputEventMouseButton.new()
		wb.button_index = wheel
		wb.pressed = true
		wb.position = Vector2(10, 10)
		wb.global_position = Vector2(10, 10)
		root.push_input(wb, true)
	await _wait(0.3)
	_check("wheel_keeps_card_open", bool((ui.call("state") as Dictionary).viewer.open) and probe.clicks == 1, "probe clicks=%d" % probe.clicks)
	_click(Vector2(10, 10))
	await _wait(0.8)
	st = ui.call("state")
	_check("empty_click_closes_reads_once", not bool(st.viewer.open) and reads == [id0] and closes.back() == [id0, "click"] and int(st.stamp.unread) == unread.size() - 1,
		"reads=%s closes=%s" % [str(reads), str(closes)])
	_check("busy_signal_on_close", busy_log.size() >= 2 and busy_log.back() == false, str(busy_log))
	LshuSave.mark_read(save, id0)
	ui.call("set_unread", LshuSave.unread(save))
	# idle auto-dismiss (postcard_idle_s = 1.5 here, 20 s by default)
	var id1: String = String((unread[1] as Dictionary).id)
	ui.call("open_postcard", unread[1])
	await _wait(0.8 + 1.5 + 0.8)
	_check("idle_dismiss_reads", not bool((ui.call("state") as Dictionary).viewer.open) and reads.has(id1) and closes.back() == [id1, "idle"], str(closes.back()))
	LshuSave.mark_read(save, id1)
	ui.call("set_unread", LshuSave.unread(save))
	# reopen while the previous card still flies back: the first one still reports closed + read
	var others: Array = LshuSave.unread(save)
	if others.size() >= 1:
		var r0: Dictionary = others[0]
		var n_reads: int = reads.size()
		ui.call("open_postcard", r0)
		await _wait(0.8)
		ui.call("close_postcard")
		await _frames(2)
		ui.call("open_postcard", (save.postcards as Array)[0])
		await _frames(2)
		_check("reopen_during_close_finishes_first", reads.size() == n_reads + 1 and reads.back() == String(r0.id) and bool((ui.call("state") as Dictionary).viewer.open), str(reads))
		ui.call("close_postcard")
		await _wait(0.8)
		LshuSave.mark_read(save, String(r0.id))
	# an already-read card opened again does not report read
	var n2: int = reads.size()
	var read_pc: Dictionary = (save.postcards as Array)[0]
	ui.call("open_postcard", read_pc)
	await _wait(0.8)
	_press_key(KEY_ESCAPE)
	await _wait(0.8)
	_check("read_card_not_reported_again", reads.size() == n2 and closes.back() == [String(read_pc.id), "key"], str(closes.back()))
	# book: L opens (and is consumed), thumbnails load, a thumbnail opens its card, L closes the card first
	_press_key(KEY_L)
	await _wait(0.5)
	st = ui.call("state")
	_check("key_L_opens_book", bool(st.book.open) and int(st.book.trips_shown) >= 2 and int(st.book.thumbs) >= 3, "trips=%d thumbs=%d" % [int(st.book.trips_shown), int(st.book.thumbs)])
	_check("key_L_consumed", probe.keys_l == 0, "probe saw L %d times" % probe.keys_l)
	_check("stamp_hidden_under_book", not bool((ui.call("state") as Dictionary).stamp.visible) or ui.call("stamp_control").get("suppressed"), "")
	var t_wait: int = Time.get_ticks_msec()
	while int(ui.get("images").call("pending")) > 0 and Time.get_ticks_msec() - t_wait < 5000:
		await _frames(1)
	var thumbs: Array = ui.call("book_control").call("thumbs")
	var loaded: int = 0
	for th: Variant in thumbs:
		if (th as Control).get("texture") != null:
			loaded += 1
	_check("book_thumbs_loaded_off_thread", loaded == thumbs.size() and thumbs.size() > 0, "%d/%d in %d ms" % [loaded, thumbs.size(), Time.get_ticks_msec() - t_wait])
	var loose: Array = _loose_flow_marks(ui.call("book_control"))
	_check("book_arrows_ride_with_stop", loose.is_empty(), "loose=%s" % str(loose))
	var th0: Control = thumbs[0]
	_click(th0.get_global_rect().get_center())
	await _wait(0.8)
	st = ui.call("state")
	_check("thumb_opens_card", bool(st.viewer.open) and String(st.viewer.id) == String((th0.get("record") as Dictionary).id), String(st.viewer.id))
	_press_key(KEY_L)
	await _wait(0.8)
	st = ui.call("state")
	_check("key_L_with_card_closes_card_only", not bool(st.viewer.open) and bool(st.book.open), "")
	_press_key(KEY_ESCAPE)
	await _wait(0.6)
	_check("esc_closes_book", not bool((ui.call("state") as Dictionary).book.visible), "")
	ui.call("open_book")
	await _wait(0.9 + 0.6)
	_check("book_idle_closes", not bool((ui.call("state") as Dictionary).book.open), "")
	# away card: only when show_away_card, hides itself
	var rc: Dictionary = data.catchup_r
	var ev: Dictionary = Sample.catchup_event(rc)
	var quiet: Dictionary = ev.duplicate()
	quiet["show_away_card"] = false
	ui.call("handle_event", quiet)
	await _frames(2)
	_check("no_away_card_when_short", not bool((ui.call("state") as Dictionary).away.showing), "")
	ui.call("apply_resolve", rc)
	await _frames(3)
	st = ui.call("state")
	_check("away_card_after_2h", bool(st.away.showing) and float(ev.gap_s) >= 7200.0, "gap_h=%.1f" % (float(ev.gap_s) / 3600.0))
	var line_label: Label = ui.call("away_control").get("_line")
	_check("away_card_prints_line", line_label != null and line_label.visible and line_label.text != "" and away_lines.size() == 1
		and (away_lines[0] as Array).size() == 1, "line=%s ids=%s" % [line_label.text if line_label != null else "", str(away_lines)])
	_check("away_route_arrows_ride_with_name", _loose_flow_marks(ui.call("away_control")).is_empty(), "")
	await _wait(0.5 + 1.6)
	_check("away_card_hides", not bool((ui.call("state") as Dictionary).away.visible), "")
	# everything idle again
	ui.call("set_unread", [])
	await _wait(2.2)
	_check("idle_again_nothing_on_screen", not bool(ui.call("is_any_visible")), JSON.stringify((ui.call("state") as Dictionary).caption))
	await _free_ui()


# ============================================================================== scale

func _scale_tests() -> void:
	for stretch: bool in [true, false]:
		for px: Vector2i in [Vector2i(1920, 1080), Vector2i(3440, 1440), Vector2i(640, 360)]:
			root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS if stretch else Window.CONTENT_SCALE_MODE_DISABLED
			root.content_scale_size = Vector2i(1280, 720)
			root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
			await _make_ui(px)
			var tag: String = "%s_%dx%d" % ["stretch" if stretch else "plain", px.x, px.y]
			var ppu: float = S.pixels_per_unit(root)
			var s: float = float(ui.call("ui_scale"))
			var phys: float = s * ppu
			var want: float = clampf(minf(px.x / 1920.0, px.y / 1080.0), 0.5, 4.0)
			_check("scale_" + tag, absf(phys - want) < 0.01, "px_per_unit=%.3f logical_scale=%.3f on_screen=%.3f want=%.3f" % [ppu, s, phys, want])
			Sample.reset_unread(data)
			ui.call("set_save", data.save)
			ui.call("show_arrival", {"name": "君士坦丁堡 · 穹顶城丘", "sub": "海峡帝都，东西津梁"})
			ui.call("set_unread", LshuSave.unread(data.save))
			ui.call("show_away", Sample.catchup_event(data.catchup_r))
			ui.call("open_postcard", LshuSave.unread(data.save)[0])
			await _wait(1.0)
			var st: Dictionary = ui.call("state")
			var vp: Array = st.viewport
			var cr: Array = st.viewer.card_rect
			var inside: bool = _inside(st.caption.rect, vp) and _inside(st.stamp.rect, vp) and _inside(st.away.rect, vp) and _inside(cr, vp)
			var cap_px: float = float(ui.call("caption_control").get_child(0).get_theme_font_size("font_size")) * ppu
			_check("layout_" + tag, inside and absf(float(cr[2]) / float(cr[3]) - 1.5) < 0.01 and cap_px >= 21.0,
				"card=%s caption_title_px=%.0f away=%s" % [str(cr), cap_px, str(st.away.rect)])
			ui.call("close_postcard")
			await _wait(0.7)
			ui.call("open_book")
			await _wait(0.6)
			st = ui.call("state")
			_check("book_inside_" + tag, _inside(st.book.rect, st.viewport), str(st.book.rect))
			await _free_ui()
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED


# ============================================================================== cost

func _cost_tests() -> void:
	# a year-long save: ~1800 postcards, a 500-row log
	var save: Dictionary = {"postcards": [], "log": [], "current_leg": {}}
	var base: int = Sample.local_unix(2025, 9, 24, 8, 0)
	var k: int = 0
	for trip: int in range(1, 300):
		for i: int in 18:
			(save.log as Array).append({"type": "leg", "k": k, "trip": trip, "name": "地点%d" % (k % 40), "home": i == 17,
				"night": i == 9, "arrive": base + k * 3000, "depart": base + k * 3000 + 2400, "road_end": base + (k + 1) * 3000})
			if k % 3 == 0:
				(save.postcards as Array).append({"id": "pc_y_%d" % k, "leg": k, "trip": trip, "file": "/nonexistent/%d.jpg" % k,
					"read": k < 5300, "band": "day", "biome": "snow", "text": ["一句。"]})
			k += 1
	save["log"] = LshuSave.compact_log(save.log as Array, 500)
	var t: int = Time.get_ticks_usec()
	var trips: Array = D.build_trips(save, TZ)
	var build_ms: float = float(Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	for _i: int in 10:
		LshuSave.unread(save)
	var unread_ms: float = float(Time.get_ticks_usec() - t) / 10000.0
	print("METRIC year_save postcards=%d log_rows=%d trips=%d build_trips_ms=%.2f unread_scan_ms=%.3f" % [(save.postcards as Array).size(), (save.log as Array).size(), trips.size(), build_ms, unread_ms])
	_check("year_scale_cost", build_ms < 50.0 and unread_ms < 5.0 and trips.size() == 299, "build_trips %.1f ms, unread scan %.2f ms" % [build_ms, unread_ms])


# ============================================================================== ids in code

func _id_scan() -> void:
	var dir: String = "res://scripts/traveler/lshu/ui"
	var re: RegEx = RegEx.new()
	re.compile("\\b[DJ]\\d{2,3}\\b|\\bS\\d{2}\\b")
	var hits: Array = []
	var files: int = 0
	for f: String in DirAccess.get_files_at(dir):
		if not f.ends_with(".gd"):
			continue
		files += 1
		var text: String = FileAccess.get_file_as_string(dir.path_join(f))
		for m: RegExMatch in re.search_all(text):
			hits.append("%s:%s" % [f, m.get_string()])
	_check("no_tile_or_asset_ids_in_ui_code", hits.is_empty() and files >= 10, "files=%d hits=%s" % [files, str(hits)])
	# every tile id, place id and place name the pool and tiles actually hold, read at run time
	var needles: Dictionary = {}
	var pool: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/lshu/pool.json"))
	for t: Variant in ((pool as Dictionary).get("tiles", []) as Array) if pool is Dictionary else []:
		var td: Dictionary = t
		for f: String in ["id", "composition_id", "name"]:
			var v: String = str(td.get(f, ""))
			if v.length() >= 2:
				needles[v] = true
	for f: String in DirAccess.get_files_at("res://data/traveler/lshu/tiles"):
		if not f.ends_with(".json"):
			continue
		needles[f.get_basename()] = true
		var place: Dictionary = {}
		var tj: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/lshu/tiles".path_join(f)))
		if tj is Dictionary:
			place = ((tj as Dictionary).get("place", {}) as Dictionary) if (tj as Dictionary).get("place") is Dictionary else {}
		for key: String in ["id", "name", "city", "asset"]:
			var pv: String = str(place.get(key, ""))
			for part: String in pv.split(" · "):
				if part.strip_edges().length() >= 2:
					needles[part.strip_edges()] = true
	var named: Array = []
	for f: String in DirAccess.get_files_at(dir):
		if not f.ends_with(".gd"):
			continue
		var text: String = FileAccess.get_file_as_string(dir.path_join(f))
		for n: Variant in needles.keys():
			var ns: String = String(n)
			var hit: bool = false
			if ns.is_valid_ascii_identifier():
				# ascii ids as whole words only ("cape" is not in "escape")
				var wre: RegEx = RegEx.create_from_string("(?<![A-Za-z0-9_])" + ns + "(?![A-Za-z0-9_])")
				hit = wre.search(text) != null
			else:
				hit = text.contains(ns)
			if hit:
				named.append("%s:%s" % [f, ns])
	_check("no_pool_ids_or_place_names_in_ui_code", named.is_empty() and needles.size() >= 25, "needles=%d hits=%s" % [needles.size(), str(named)])


# ============================================================================== helpers

## Labels "→" / "…" sitting on their own in a flow container: those can wrap to the start of a line.
func _loose_flow_marks(node: Node) -> Array:
	var out: Array = []
	for c: Node in node.find_children("*", "HFlowContainer", true, false):
		for k: Node in c.get_children():
			if k is Label and ((k as Label).text == "→" or (k as Label).text == "…"):
				out.append((k as Label).text)
	return out


func _click(pos: Vector2) -> void:
	_motion(pos)
	for pressed: bool in [true, false]:
		var mb: InputEventMouseButton = InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = pressed
		mb.position = pos
		mb.global_position = pos
		root.push_input(mb, true)


func _motion(pos: Vector2) -> void:
	var mv: InputEventMouseMotion = InputEventMouseMotion.new()
	mv.position = pos
	mv.global_position = pos
	mv.relative = Vector2(3.0, 0.0)
	root.push_input(mv, true)


func _press_key(code: Key) -> void:
	for pressed: bool in [true, false]:
		var k: InputEventKey = InputEventKey.new()
		k.keycode = code
		k.physical_keycode = code
		k.pressed = pressed
		root.push_input(k, true)


func _center(rect: Variant) -> Vector2:
	var r: Array = rect
	return Vector2(float(r[0]) + float(r[2]) * 0.5, float(r[1]) + float(r[3]) * 0.5)


func _inside(rect: Variant, vp: Variant) -> bool:
	var r: Array = rect
	var v: Array = vp
	return float(r[0]) >= -0.5 and float(r[1]) >= -0.5 and float(r[0]) + float(r[2]) <= float(v[0]) + 0.5 and float(r[1]) + float(r[3]) <= float(v[1]) + 0.5


func _eq(name_value: String, got: Variant, want: Variant) -> void:
	_check(name_value, got == want, "got=%s want=%s" % [str(got), str(want)])


func _check(name_value: String, ok: bool, detail: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name_value, detail])


func _wait(s: float) -> void:
	await create_timer(s).timeout


func _frames(n: int) -> void:
	for _i: int in n:
		await process_frame
