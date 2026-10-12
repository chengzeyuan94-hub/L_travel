extends SceneTree
## Act 4 「L叔在哪儿」 postcard rules: the GDScript port (scripts/traveler/lshu/loop/lshu_postcard_text.gd)
## against the Python reference (tools/traveler/lshu/tests/postcard_lines_check.py), card by card.
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path <project> \
##       --script res://tools/traveler/lshu/tests/test_postcard_rules.gd [-- --ref=/path/ref.json]
## Without --ref it runs postcard_rules_export.py (python3 -B) into the OS temp folder first.
## The contexts are generated here in GDScript with the same seeds and the same draws as the Python
## exporter, then compared field by field with what Python generated, so a difference shows up
## either as a context difference (harness) or as a card difference (rules).
## Prints PASS / FAIL / METRIC / DIFF lines and LSHU_POSTCARD_RULES passed=N failed=M; exit 0 only
## when failed == 0. No tile, place or asset id is written here: stops come from the tile JSONs.

const LshuClock := preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const LshuSave := preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const LshuPoolAdapter := preload("res://scripts/traveler/lshu/loop/lshu_pool_adapter.gd")
const LshuPostcardText := preload("res://scripts/traveler/lshu/loop/lshu_postcard_text.gd")
const LshuPostcardContext := preload("res://scripts/traveler/lshu/loop/lshu_postcard_context.gd")

const LIB_PATH: String = "res://data/traveler/lshu/postcard_lines.json"
const SIMPLE_FIXTURE: String = "res://tools/traveler/lshu/tests/fixtures/postcard_lines_simple_78.json"
const EXPORTER: String = "res://tools/traveler/lshu/tests/postcard_rules_export.py"
const SIM_SEED: int = 20260924
const EDGE_SEED: int = 7
const SLOTS: Array = ["morning", "day", "sunset", "night"]
const EDGE_SLOTS: Array = ["morning", "day", "sunset", "night", "dusk", "evening", "noon", "dawn"]
const KIT_NUM: Dictionary = {"look": 0, "camp": 1, "tea": 2, "encounter": 3, "bloom": 3}
const EDGE_KITS: Array = ["look", "camp", "tea", "encounter", "bloom", 0, 1, 2, 3]
const GROUPS: Array = ["snow", "desert", "grass", "harbour", "rock", "city"]
const CTX_FIELDS: Array = ["place_key", "place_name", "biome", "landform", "city_id", "kit", "slot", "is_home",
	"is_overnight", "after_long_road", "minutes_since_arrive", "away_card", "postcard_terrain"]
const TZ_MIN: int = 480
const TIGHT_SEED: int = 11

var passed: int = 0
var failed: int = 0
var lib: Dictionary = {}
var lib_show: Dictionary = {}
var lib_tight: Dictionary = {}
var lib_tight_show: Dictionary = {}
var ref: Dictionary = {}
var stops: Array = []
var sub_nature: Dictionary = {}
var sub_any: Dictionary = {}
var lore: Dictionary = {}
var date_text: String = "9月24日"


func _init() -> void:
	var t_start: int = Time.get_ticks_msec()
	lib = _read_json(LIB_PATH)
	lib_show = lib.duplicate(true)
	((lib_show.stamp as Dictionary).city_lookup as Dictionary)["blocked_policy"] = "show"
	lore = LshuPostcardContext.city_lore(lib)
	ref = _load_ref()
	_check("library_and_reference_loaded", LshuPostcardText.is_rich(lib) and not ref.is_empty(),
		"library %s; Python %s; reference static errors %d"
		% [_s(lib.get("version", "")), _s(ref.get("python", "?")), (ref.get("static_errors", []) as Array).size()])
	if ref.is_empty():
		_finish(t_start)
		return
	date_text = _s(ref.get("date_text", date_text))
	lib_tight = lib.duplicate(true)
	(lib_tight.limits as Dictionary).merge(ref.get("tight_limits", {}) as Dictionary, true)
	lib_tight_show = lib_tight.duplicate(true)
	((lib_tight_show.stamp as Dictionary).city_lookup as Dictionary)["blocked_policy"] = "show"
	_build_stops()
	test_stops_match()
	test_rnd_stream()
	test_py_sum()
	test_scenario("sim", SIM_SEED, false, lib, lib_show)
	test_scenario("sim", SIM_SEED, true, lib, lib_show)
	test_scenario("edge", EDGE_SEED, false, lib, lib_show)
	test_scenario("tight", TIGHT_SEED, false, lib_tight, lib_tight_show)
	test_scenario("tight", TIGHT_SEED, true, lib_tight, lib_tight_show)
	test_sim_invariants()
	test_validate_library()
	test_legacy_api()
	test_robustness()
	test_clock_integration()
	_finish(t_start)


func _finish(t_start: int) -> void:
	print("METRIC total_ms=%d" % (Time.get_ticks_msec() - t_start))
	print("LSHU_POSTCARD_RULES passed=%d failed=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)


# =============================================================================================
# Reference

func _load_ref() -> Dictionary:
	var path: String = ""
	var made: bool = false
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--ref="):
			path = a.substr(6)
	if path == "":
		path = OS.get_temp_dir().path_join("lshu_postcard_rules_ref_%d.json" % OS.get_process_id())
		var out: Array = []
		var script: String = ProjectSettings.globalize_path(EXPORTER)
		var code: int = OS.execute("python3", ["-B", script, "--out", path], out, true)
		if code != 0:
			code = OS.execute("/usr/bin/python3", ["-B", script, "--out", path], out, true)
		print("REF exporter exit=%d %s" % [code, "".join(PackedStringArray(out)).strip_edges()])
		if code != 0:
			return {}
		made = true
	var d: Dictionary = _read_json(path)
	if d.is_empty():
		print("REF could not read %s" % path)
	if made:
		DirAccess.remove_absolute(path)
	return d


## Port of tile_contexts() in postcard_lines_check.py: one stop per tile JSON, sorted by file name.
func _build_stops() -> void:
	var by_name: Dictionary = {}
	for it: Variant in _read_json(_s(((lib.stamp as Dictionary).city_lookup as Dictionary).cities_file)).get("items", []) as Array:
		by_name[_s((it as Dictionary).display_name)] = _s((it as Dictionary).id)
	var files: Array = []
	for f: String in DirAccess.get_files_at(LshuPoolAdapter.TILES_DIR):
		if f.ends_with(".json"):
			files.append(f)
	files.sort()
	for f: Variant in files:
		var d: Dictionary = _read_json(LshuPoolAdapter.TILES_DIR.path_join(String(f)))
		var place: Dictionary = d.get("place", {}) as Dictionary
		var kit: Dictionary = d.get("kit", {}) as Dictionary
		var city: Variant = place.get("city")
		stops.append({
			"place_key": place.get("id", ""), "place_name": place.get("name", ""), "biome": place.get("theme", ""),
			"landform": place.get("landform", ""), "city_id": by_name.get(_s(city) if city != null else "", ""),
			"kit": kit.get("mode", kit.get("id", 0)),
		})
	var journey: Dictionary = _read_json(LshuPoolAdapter.DEV_CATALOG_JSON)
	for p: Variant in journey.get("places", []) as Array:
		var pd: Dictionary = p
		sub_any[_s(pd.id)] = _s(pd.get("sub", ""))
		if not _truthy(pd.get("city")):
			sub_nature[_s(pd.id)] = _s(pd.get("sub", ""))


func test_stops_match() -> void:
	var ref_stops: Array = ref.get("stops", []) as Array
	var diffs: Array = []
	for i: int in maxi(ref_stops.size(), stops.size()):
		var a: String = _canon(ref_stops[i] as Dictionary) if i < ref_stops.size() else "-"
		var b: String = _canon(stops[i] as Dictionary) if i < stops.size() else "-"
		if a != b:
			diffs.append("%d: py %s / gd %s" % [i, a, b])
	var cities: int = stops.filter(func(s: Dictionary) -> bool: return _s(s.city_id) != "").size()
	_check("stops_match_python", diffs.is_empty() and not stops.is_empty(),
		"%d tile stops (%d city, %d nature) from the tile JSONs; differences %d %s"
		% [stops.size(), cities, stops.size() - cities, diffs.size(), str(diffs.slice(0, 2))])


func test_rnd_stream() -> void:
	var samples: Array = ref.get("rnd_samples", []) as Array
	var bad: Array = []
	for s: Variant in samples:
		var sd: Dictionary = s
		var parts: Array = []
		for p: Variant in sd.parts as Array:
			parts.append(int(p) if p is float else p)
		var x: float = LshuPostcardText.rnd(parts) * LshuPostcardText.TWO_POW_64
		var hi: float = floor(x / LshuPostcardText.TWO_POW_32)
		var lo: float = x - hi * LshuPostcardText.TWO_POW_32
		if hi != float(sd.hi) or lo != float(sd.lo):
			bad.append(str(sd.parts))
	_check("rnd_stream_identical", bad.size() == 0 and samples.size() >= 300,
		"%d draws of sha256(\"|\".join(parts)) (incl. Chinese text and \"|\" inside a part) equal bit for bit; bad %d %s"
		% [samples.size(), bad.size(), str(bad.slice(0, 2))])


## CPython 3.12 sums floats with Neumaier compensation; the weight totals must match it exactly.
func test_py_sum() -> void:
	var samples: Array = ref.get("sum_samples", []) as Array
	var bad: int = 0
	var naive_differs: int = 0
	for s: Variant in samples:
		var sd: Dictionary = s
		var xs: Array = []
		for v: Variant in sd.ints as Array:
			xs.append(float(int(v)) / 1000.0)
		var total: float = LshuPostcardText.py_sum(xs)
		if total * float(1 << (53 - int(sd.exp))) != float(sd.mant):
			bad += 1
		naive_differs += 0 if bool(sd.naive_same) else 1
	_check("weight_sum_matches_python", bad == 0 and samples.size() >= 300,
		"%d sums of 2-5 floats equal Python 3.12 sum() bit for bit, bad %d (a plain left-to-right sum differs in %d of them)"
		% [samples.size(), bad, naive_differs])


# =============================================================================================
# Card by card

## The same generators as postcard_rules_export.py (sim = simulate() of the reference).
func _gen(name: String, seed: int, i: int) -> Dictionary:
	var s: Dictionary = stops[int(_rnd([seed, "stop", i]) * float(stops.size()))]
	var ctx: Dictionary = s.duplicate()
	if name == "sim":
		ctx["slot"] = SLOTS[int(_rnd([seed, "slot", i]) * 4.0)]
		ctx["is_home"] = _rnd([seed, "home", i]) < 0.08
		ctx["is_overnight"] = (not bool(ctx.is_home)) and _rnd([seed, "night", i]) < 0.15
		if bool(ctx.is_overnight):
			ctx["kit"] = "camp" if _rnd([seed, "k", i]) < 0.5 else "tea"
		ctx["after_long_road"] = _rnd([seed, "long", i]) < 0.15
		ctx["minutes_since_arrive"] = int(_rnd([seed, "min", i]) * 60.0)
	else:
		ctx["slot"] = EDGE_SLOTS[int(_rnd([seed, "slot", i]) * float(EDGE_SLOTS.size()))]
		var kv: float = _rnd([seed, "kitv", i])
		if kv < 0.3:
			if KIT_NUM.has(_s(ctx.kit)):
				ctx["kit"] = KIT_NUM[_s(ctx.kit)]
		elif kv < 0.4:
			ctx["kit"] = EDGE_KITS[int(_rnd([seed, "kitp", i]) * float(EDGE_KITS.size()))]
		ctx["is_home"] = _rnd([seed, "home", i]) < 0.1
		ctx["is_overnight"] = (not bool(ctx.is_home)) and _rnd([seed, "night", i]) < 0.2
		ctx["after_long_road"] = _rnd([seed, "long", i]) < 0.3
		if _rnd([seed, "nomin", i]) >= 0.05:
			ctx["minutes_since_arrive"] = int(_rnd([seed, "min", i]) * 40.0)
		ctx["away_card"] = _rnd([seed, "away", i]) < 0.05
		var pt: float = _rnd([seed, "pt", i])
		if pt < 0.08:
			ctx["postcard_terrain"] = [GROUPS[int(_rnd([seed, "ptg", i]) * 6.0)]]
		elif pt < 0.12:
			ctx["postcard_terrain"] = ["city", GROUPS[int(_rnd([seed, "ptg", i]) * 5.0)]]
	return ctx


## window_history: pass only the last no_repeat_window_cards cards, as the clock does.
func test_scenario(name: String, seed: int, window_history: bool, L: Dictionary, L_show: Dictionary) -> void:
	var sc: Dictionary = (ref.scenarios as Dictionary).get(name, {}) as Dictionary
	var ref_cards: Array = sc.get("cards", []) as Array
	var history: Array = []
	var diffs: Array = []
	var ctx_diffs: int = 0
	var field_diffs: Dictionary = {}
	var stamp_diffs: int = 0
	var counts: Dictionary = {"two_line": 0, "fallbacks": 0, "away": 0, "road": 0, "epithet": 0, "sub": 0,
		"blocked_omitted": 0, "blocked_shown": 0, "numeric_kit": 0, "slot_alias": 0, "terrain_override": 0}
	var win: int = LshuPostcardText.window(L)
	var us: int = 0
	var max_card: int = int((L.limits as Dictionary).max_card_chars)
	var one_line: int = 0
	var over_len: int = 0
	for i: int in ref_cards.size():
		var rc: Dictionary = ref_cards[i]
		var ctx: Dictionary = _gen(name, seed, i)
		if _canon(ctx) != _canon(rc["in"] as Dictionary):
			ctx_diffs += 1
			if diffs.size() < 6:
				diffs.append("#%d ctx py %s / gd %s" % [i, _canon(rc["in"] as Dictionary), _canon(ctx)])
		# The stamp reads `sub`; a city place gets its web disclaimer too, which must never show.
		var key: String = _s(ctx.place_key)
		ctx["sub"] = sub_any.get(key, "") if _s(ctx.city_id) != "" else sub_nature.get(key, "")
		var hist: Array = history.slice(maxi(0, history.size() - win)) if window_history else history
		var t0: int = Time.get_ticks_usec()
		var card: Dictionary = LshuPostcardText.compose_card(L, ctx, hist, [seed, i, 0])
		us += Time.get_ticks_usec() - t0
		var got: Dictionary = {
			"categories": card.categories, "terrain_group": card.terrain_group, "line_ids": card.line_ids,
			"text": card.text, "fallbacks": card.fallbacks, "slot": (card.ctx as Dictionary).slot,
			"kit": (card.ctx as Dictionary).kit, "terrain_tags": (card.ctx as Dictionary).terrain_tags,
		}
		for f: String in got.keys():
			if _canon_v(got[f]) != _canon_v(rc[f]):
				field_diffs[f] = int(field_diffs.get(f, 0)) + 1
				if diffs.size() < 6:
					diffs.append("#%d %s py %s / gd %s" % [i, f, _canon_v(rc[f]), _canon_v(got[f])])
		var st_omit: Dictionary = LshuPostcardText.stamp(L, card.ctx, {}, lore)
		var st_show: Dictionary = LshuPostcardText.stamp(L_show, card.ctx, {}, lore)
		var chars: int = 0
		for t: Variant in card.lines as Array:
			chars += _s(t).length()
		over_len += 1 if chars > max_card else 0
		one_line += 1 if (card.line_ids as Array).size() == 1 else 0
		var line_omit: String = LshuPostcardText.stamp_line(st_omit, date_text)
		var line_show: String = LshuPostcardText.stamp_line(st_show, date_text)
		if line_omit != _s(rc.stamp_omit) or line_show != _s(rc.stamp_show):
			stamp_diffs += 1
			if diffs.size() < 6:
				diffs.append("#%d stamp py %s | %s / gd %s | %s" % [i, _s(rc.stamp_omit), _s(rc.stamp_show), line_omit, line_show])
		history.append(card.line_ids)
		counts["two_line"] += 1 if (card.line_ids as Array).size() == 2 else 0
		counts["fallbacks"] += int(card.fallbacks)
		counts["away"] += 1 if _truthy(ctx.get("away_card")) else 0
		counts["road"] += 1 if (card.categories as Array).has("road") else 0
		var kind: String = _s(st_omit.caption_kind) if _s(st_omit.caption_kind) != "" else "none"
		counts[kind] = int(counts.get(kind, 0)) + 1
		if bool(st_omit.city_blocked):
			counts["blocked_omitted"] += 1 if _s(st_omit.caption) == "" else 0
			counts["blocked_shown"] += 1 if _s(st_show.caption) != "" else 0
		counts["numeric_kit"] += 1 if (rc["in"] as Dictionary).get("kit") is float else 0
		counts["slot_alias"] += 1 if not SLOTS.has(_s(ctx.slot)) else 0
		counts["terrain_override"] += 1 if ctx.has("postcard_terrain") else 0
	var label: String = "%s_cards_identical%s" % [name, "_window_history" if window_history else ""]
	var ok: bool = ref_cards.size() >= 2000 and ctx_diffs == 0 and field_diffs.is_empty() and stamp_diffs == 0
	ok = ok and over_len == 0
	_check(label, ok, "seed %d, %d cards%s, max_card_chars %d: context diffs %d, card field diffs %s, stamp diffs %d (blocked_policy omit + show); one-line cards %d, over max_card_chars %d; %s"
		% [seed, ref_cards.size(), " (history = last %d cards)" % win if window_history else " (full history)", max_card,
		ctx_diffs, str(field_diffs), stamp_diffs, one_line, over_len, str(counts)])
	for d: Variant in diffs:
		print("DIFF %s %s" % [label, d])
	print("METRIC %s_compose_us_per_card=%.1f" % [label, float(us) / float(maxi(1, ref_cards.size()))])


## The invariants simulate() counts, recomputed here on the GDScript cards.
func test_sim_invariants() -> void:
	var stats: Dictionary = ref.get("simulate_stats", {}) as Dictionary
	var by_id: Dictionary = {}
	for g: Variant in LshuPostcardText._groups(lib):
		for l: Variant in g as Array:
			by_id[_s((l as Dictionary).id)] = l
	var win: int = LshuPostcardText.window(lib)
	var max_card: int = int(((lib.limits as Dictionary).max_card_chars))
	var history: Array = []
	var outputs: PackedStringArray = PackedStringArray()
	var v: Dictionary = {"repeat_in_window": 0, "motif_clash": 0, "over_len": 0, "same_cat": 0, "avoid_hit": 0}
	var cats: Dictionary = {}
	var two: int = 0
	var fb: int = 0
	var n: int = int(stats.get("cards", 2000))
	for i: int in n:
		var card: Dictionary = LshuPostcardText.compose_card(lib, _gen("sim", SIM_SEED, i), history, [SIM_SEED, i, 0])
		var recent: Dictionary = {}
		for h: Variant in history.slice(maxi(0, history.size() - win)):
			for x: Variant in h as Array:
				recent[x] = true
		var ids: Array = card.line_ids
		if int(card.fallbacks) == 0:
			for x2: Variant in ids:
				if recent.has(x2):
					v["repeat_in_window"] += 1
					break
		var ls: Array = ids.map(func(x3: Variant) -> Dictionary: return by_id[x3])
		if ls.size() == 2:
			two += 1
			for m: Variant in ((ls[0] as Dictionary).get("motifs", []) as Array):
				if ((ls[1] as Dictionary).get("motifs", []) as Array).has(m):
					v["motif_clash"] += 1
					break
			if (card.categories as Array)[0] == (card.categories as Array)[1]:
				v["same_cat"] += 1
		var chars: int = 0
		for l2: Variant in ls:
			chars += _s((l2 as Dictionary).text).length()
			if LshuPostcardText.avoided(l2 as Dictionary, card.ctx as Dictionary):
				v["avoid_hit"] += 1
		if chars > max_card:
			v["over_len"] += 1
		fb += int(card.fallbacks)
		for c: Variant in card.categories as Array:
			cats[c] = int(cats.get(c, 0)) + 1
		history.append(ids)
		outputs.append(_s(card.text))
	var digest: String = "\n".join(outputs).sha256_text().substr(0, 16)
	var total_v: int = 0
	for k: Variant in v.keys():
		total_v += int(v[k])
	var same_stats: bool = two == int(stats.get("two_line", -1)) and fb == int(stats.get("fallbacks", -1)) \
		and _canon_v(cats) == _canon_v(stats.get("cats", {}))
	_check("sim_invariants_and_digest", total_v == 0 and digest == _s(stats.get("digest", "")) and same_stats,
		"%d cards: violations %s; two-line %d (py %d), fallbacks %d (py %d), categories %s; text digest %s (py %s)"
		% [n, str(v), two, int(stats.get("two_line", -1)), fb, int(stats.get("fallbacks", -1)), str(cats), digest, _s(stats.get("digest", ""))])


# =============================================================================================
# Library checks, legacy API, robustness

func test_validate_library() -> void:
	var errs: Array[String] = LshuPostcardText.validate_library(lib)
	var bad: Dictionary = lib.duplicate(true)
	var road: Array = (bad.lines as Dictionary).road
	(road[0] as Dictionary)["text"] = "这一句故意写得很长很长很长很长很长很长很长很长很长很长。"
	(road[1] as Dictionary)["text"] = "没有句号"
	(road[2] as Dictionary)["avoid"] = ["season:winter"]
	(road[3] as Dictionary)["id"] = _s((road[4] as Dictionary).id)
	var errs_bad: Array[String] = LshuPostcardText.validate_library(bad)
	_check("validate_library", errs.is_empty() and errs_bad.size() == 4,
		"real library errors %d; injected 4 (line over %d chars, no 。, bad avoid token, duplicate id) -> found %d %s"
		% [errs.size(), int((lib.limits as Dictionary).max_line_chars), errs_bad.size(), str(errs_bad)])


func test_legacy_api() -> void:
	var norm: Dictionary = LshuPostcardText.normalize_library(lib)
	var all: Dictionary = {}
	for g: Variant in LshuPostcardText._groups(lib):
		for l: Variant in g as Array:
			all[_s((l as Dictionary).text)] = true
	var ok_rich: bool = norm.has("rich") and not LshuPostcardText.rich_of(norm).is_empty()
	var cards: int = 0
	var bad: int = 0
	for i: int in 200:
		var pc: Dictionary = {"line_seed": i * 7919, "band": SLOTS[i % 4], "kit": ["look", "camp", "tea", "encounter"][i % 4],
			"biome": ["autumn", "desert", "harbor", "snow"][(i / 4) % 4], "home": i % 10 == 0}
		var a: Array[String] = LshuPostcardText.compose(pc, norm, "地点自带的一句话。")
		var b: Array[String] = LshuPostcardText.compose(pc, norm, "地点自带的一句话。")
		cards += 1
		if a != b or a.is_empty() or a.size() > 2 or a.any(func(t: String) -> bool: return not all.has(t)):
			bad += 1
	var simple: Dictionary = _read_json(SIMPLE_FIXTURE)
	var s_norm: Dictionary = LshuPostcardText.normalize_library(simple)
	var s_bad: int = 0
	for i2: int in 100:
		var pc2: Dictionary = {"line_seed": i2, "band": SLOTS[i2 % 4], "kit": "tea", "biome": "desert", "home": i2 % 9 == 0}
		var got: Array[String] = LshuPostcardText.compose(pc2, s_norm, "")
		if got.is_empty() or got.size() > 2:
			s_bad += 1
	_check("legacy_api_compatible", ok_rich and bad == 0 and s_bad == 0 and LshuPostcardText.signature(norm) == "L",
		"normalize_library keeps the rules (rich=%s); compose(pc, lines, sub): %d rich cards, %d bad (lines outside the library or not deterministic); simple 78-line library: 100 cards, %d bad"
		% [str(ok_rich), cards, bad, s_bad])


func test_robustness() -> void:
	var cases: Array = [
		{"slot": "midnight", "kit": "look", "biome": "desert"},
		{"slot": "day", "kit": "juggling", "biome": "desert"},
		{"slot": "day", "kit": 9, "biome": ""},
		{"slot": "day", "kit": "tea", "biome": "snow", "postcard_terrain": ["lava", "moon"]},
		{"slot": "night", "kit": "camp", "biome": "snow", "postcard_terrain": "snow"},
	]
	var out: Array = []
	var ok: bool = true
	for i: int in cases.size():
		var card: Dictionary = LshuPostcardText.compose_card(lib, cases[i], [], [1, i, 0])
		ok = ok and not (card.lines as Array).is_empty()
		out.append("%s/%s/%s" % [(card.ctx as Dictionary).slot, (card.ctx as Dictionary).kit, str(card.terrain_group)])
	# Every bloom line avoided on snow: a kit-first card falls back to the time line.
	var all_avoid: Dictionary = lib.duplicate(true)
	for l: Variant in (((all_avoid.lines as Dictionary).kit as Dictionary).bloom as Array):
		(l as Dictionary)["avoid"] = ["terrain:snow"]
	var fell_back: int = 0
	for j: int in 200:
		var c2: Dictionary = LshuPostcardText.compose_card(all_avoid, {"slot": "day", "kit": "bloom", "biome": "snow",
			"minutes_since_arrive": 30}, [], [2, j, 0])
		ok = ok and not (c2.lines as Array).is_empty()
		for id: Variant in c2.line_ids as Array:
			if _s(id).begins_with("k.bloom"):
				ok = false
		# A card of one time line only: the main line fell back (time is never drawn as the main category).
		fell_back += 1 if _canon_v(c2.categories) == "[time]" else 0
	# The away card: one road line, never a second line.
	var away_ok: bool = true
	var hist: Array = []
	for k: int in 30:
		var ac: Dictionary = LshuPostcardText.away_card(lib, hist, [3, "away", k])
		away_ok = away_ok and _canon_v(ac.categories) == "[road]" and (ac.line_ids as Array).size() == 1
		hist.append(ac.line_ids)
	var distinct: Dictionary = {}
	for h: Variant in hist.slice(hist.size() - 10):
		distinct[(h as Array)[0]] = true
	_check("robustness_where_python_raises", ok and away_ok and distinct.size() == 10,
		"unknown slot / kit / terrain override -> %s; every bloom line avoided on snow: 200 cards, none empty, no bloom line, %d kit-first cards fell back to a time line; away card 30x: road only, last 10 distinct=%d"
		% [str(out), fell_back, distinct.size()])


# =============================================================================================
# In the clock

## Real pool, 4 seeds x 14 days, resolved every 20 minutes (every stop is on screen at least once,
## so each postcard's stop is known), renders completed at once so no postcard is dropped.
func test_clock_integration() -> void:
	var cfg: Dictionary = LshuClock.load_config()
	cfg["tz_offset_minutes"] = TZ_MIN
	var places: Array = LshuPoolAdapter.load_places()
	var base: int = int(Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 9, "day": 24, "hour": 0, "minute": 0, "second": 0})) - TZ_MIN * 60
	var max_card: int = int((lib.limits as Dictionary).max_card_chars)
	var win: int = LshuPostcardText.window(lib)
	var n_pc: int = 0
	var bad_shape: int = 0
	var replay_diff: int = 0
	var replay_missing: int = 0
	var repeats: int = 0
	var fallbacks: int = 0
	var bad_stamp: int = 0
	var long_wire_bad: int = 0
	var cats: Dictionary = {}
	var captions: Dictionary = {}
	var with_landform: int = 0
	var after_long: int = 0
	var road_after_long: int = 0
	var sample: String = ""
	var json_bad: int = 0
	var restamp_bad: int = 0
	var restamped_blocked: int = 0
	for seed: int in [11, 12, 13, 14]:
		var t: float = float(base + 9 * 3600)
		var r: Dictionary = LshuClock.resolve({"seed": seed}, t, places, cfg)
		var s: Dictionary = r.save
		var legs: Dictionary = {int(r.leg.index): r.leg}
		while t < float(base + 15 * 86400):
			t += 1200.0
			r = LshuClock.resolve(s, t, places, cfg)
			s = r.save
			legs[int(r.leg.index)] = r.leg
			for id: Variant in r.new_postcards as Array:
				LshuSave.complete_render(s, String(id), "mem://%s.jpg" % String(id))
		for k: Variant in legs.keys():
			if legs.has(int(k) - 1) and bool((legs[k] as Dictionary).get("after_long_road", false)) != bool((legs[int(k) - 1] as Dictionary).long_road):
				long_wire_bad += 1
		var pcs: Array = s.postcards
		for i: int in pcs.size():
			var pc: Dictionary = pcs[i]
			n_pc += 1
			var text: Array = pc.get("text", []) as Array
			var ids: Array = pc.get("line_ids", []) as Array
			var chars: int = 0
			for x: Variant in text:
				chars += _s(x).length()
			if text.is_empty() or text.size() > 2 or ids.size() != text.size() or (pc.get("categories", []) as Array).size() != ids.size() \
					or chars > max_card or _s(pc.signature) != "L" or not (pc.get("stamp") is Dictionary):
				bad_shape += 1
				continue
			for c: Variant in pc.categories as Array:
				cats[c] = int(cats.get(c, 0)) + 1
			var st: Dictionary = pc.stamp
			var kind: String = _s(st.caption_kind)
			if kind == "":
				kind = "blocked" if bool(st.city_blocked) else "none"
			captions[kind] = int(captions.get(kind, 0)) + 1
			if _s(st.title) != _s(pc.name) or _s(st.date) == "" or _s(st.slot_label) == "":
				bad_stamp += 1
			if not legs.has(int(pc.leg)):
				replay_missing += 1
				continue
			var leg: Dictionary = legs[int(pc.leg)]
			var ctx: Dictionary = LshuPostcardContext.for_leg(leg, _s(pc.band), int(pc.unix), lib)
			with_landform += 1 if _s(ctx.landform) != "" else 0
			if bool(ctx.after_long_road):
				after_long += 1
				road_after_long += 1 if (pc.categories as Array).has("road") else 0
			# City places: the epithet (or nothing when blocked); nature places: their own sub only.
			if _s(ctx.city_id) != "":
				var item: Dictionary = lore.get(_s(ctx.city_id), {}) as Dictionary
				var want: String = "" if _s(item.get("verification_status", "")) == "CONTENT_BLOCKED" else _s(item.get("epithet", ""))
				if _s(st.caption) != want:
					bad_stamp += 1
			elif _s(st.caption) != _s(leg.get("sub", "")):
				bad_stamp += 1
			var hist: Array = LshuPostcardText.history_from_postcards(pcs.slice(0, i), win)
			var card: Dictionary = LshuPostcardText.compose_card(lib, ctx, hist, [seed, int(pc.leg), 0])
			if _canon_v(card.line_ids) != _canon_v(ids) or _canon_v(card.lines) != _canon_v(text):
				replay_diff += 1
			fallbacks += int(card.fallbacks)
			if int(card.fallbacks) == 0:
				var recent: Dictionary = {}
				for h: Variant in hist:
					for x2: Variant in h as Array:
						recent[x2] = true
				for x3: Variant in ids:
					if recent.has(x3):
						repeats += 1
						break
			# Flipping blocked_policy to "show" must reach postcards that were saved without the epithet.
			var re_show: Dictionary = LshuPostcardText.restamp(pc, lib_show, lore)
			var want_show: String = _s(st.caption)
			if bool(st.city_blocked):
				want_show = _s((lore.get(_s(pc.city_id), {}) as Dictionary).get("epithet", ""))
				restamped_blocked += 1
			if _s(re_show.caption) != want_show or _s(re_show.date) != _s(st.date) or _s(re_show.title) != _s(st.title):
				restamp_bad += 1
			if sample == "" and text.size() == 2 and _s(st.caption) != "":
				sample = "%s / %s" % [LshuPostcardText.stamp_line(st), " ".join(PackedStringArray(text))]
		# A save written to JSON and read back gives the same history.
		var rt: Dictionary = JSON.parse_string(JSON.stringify(s))
		if _canon_v(LshuPostcardText.history_from_postcards(rt.postcards as Array, win)) != _canon_v(LshuPostcardText.history_from_postcards(pcs, win)):
			json_bad += 1
	_check("clock_postcards_follow_rules", json_bad == 0 and restamp_bad == 0 and n_pc >= 100 and bad_shape == 0 and replay_diff == 0 and replay_missing == 0
		and repeats == 0 and bad_stamp == 0 and long_wire_bad == 0 and with_landform > 0,
		"real pool, 4 seeds x 14 days: %d postcards; bad shape %d; replay with [seed, leg, 0] + last %d records: %d differ, %d stop unknown; repeats within %d cards %d (fallbacks %d); stamp errors %d; categories %s; captions %s; landform/city found for %d; after a long road %d (road line %d); after_long_road wiring errors %d; history after a JSON round trip differs in %d saves; restamp with blocked_policy show: %d wrong (%d blocked-city cards get their epithet back); e.g. %s"
		% [n_pc, bad_shape, win, replay_diff, replay_missing, win, repeats, fallbacks, bad_stamp, str(cats), str(captions),
		with_landform, after_long, road_after_long, long_wire_bad, json_bad, restamp_bad, restamped_blocked, sample])


# =============================================================================================
# Helpers

func _check(name: String, cond: bool, detail: String) -> void:
	if cond:
		passed += 1
		print("PASS %s | %s" % [name, detail])
	else:
		failed += 1
		print("FAIL %s | %s" % [name, detail])


func _rnd(parts: Array) -> float:
	return LshuPostcardText.rnd(parts)


## Order-independent text form of a context, only the fields both sides generate.
func _canon(d: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for f: String in CTX_FIELDS:
		if d.has(f):
			parts.append("%s=%s" % [f, _canon_v(d[f])])
	return ",".join(parts)


## JSON numbers come back as floats and Python ints as floats: 3 and 3.0 print the same here.
func _canon_v(v: Variant) -> String:
	if v is Array:
		var out: PackedStringArray = PackedStringArray()
		for x: Variant in v as Array:
			out.append(_canon_v(x))
		return "[" + ",".join(out) + "]"
	if v is Dictionary:
		var keys: Array = (v as Dictionary).keys()
		keys.sort()
		var out2: PackedStringArray = PackedStringArray()
		for k: Variant in keys:
			out2.append("%s:%s" % [_s(k), _canon_v((v as Dictionary)[k])])
		return "{" + ",".join(out2) + "}"
	if v is bool:
		return "true" if v else "false"
	return _s(v)


func _truthy(v: Variant) -> bool:
	return LshuPostcardText._truthy(v)


func _s(v: Variant) -> String:
	return LshuPostcardText._str(v)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var j: JSON = JSON.new()
	if j.parse(FileAccess.get_file_as_string(path)) != OK or not (j.data is Dictionary):
		return {}
	return j.data
