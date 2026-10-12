extends RefCounted
## Act 4 loop: the back of a postcard, from the global line library
## data/traveler/lshu/postcard_lines.json (rich schema lshu.postcard_lines.v1; the older simple
## shape {time, kit, biome, home, rules} still works through the legacy compose()).
##
## compose_card() ports compose() of tools/traveler/lshu/tests/postcard_lines_check.py and gives
## the same card for the same (context, history, key): the same random stream (SHA-256 of the
## "|"-joined key parts plus a step counter, first 8 bytes big-endian over 2^64), the same order of
## draws and the same filters. tools/traveler/lshu/tests/test_postcard_rules.gd compares the two
## card by card. Every number comes from the library (compose / limits / terrain_resolve / stamp):
##   1. context: slot and kit through their aliases; terrain tags = postcard_terrain when given,
##      else [city for a city place] + from_landform[landform] + from_biome[biome], else fallback.
##   2. main category: away card -> road; home -> home; after a long road and within
##      max_minutes_since_arrive -> road with p; a fresh arrival -> road with p; otherwise terrain
##      or kit by weights (weights_overnight on an overnight stop).
##   3. a terrain group: city with city_weight, otherwise evenly among the natural tags.
##   4. main line: not used in the last no_repeat_window_cards cards and not avoided (slot:x /
##      kit:x / terrain:x, terrain meaning any tag of the stop); when none is left, the least
##      recently used line that is not avoided.
##   5. second line with p (p_home after a home line, never on the away card), category from
##      weights_by_primary minus the main category, never sharing a motif with the main line (no
##      motif fallback: it is dropped); when both lines exceed max_card_chars, one more draw,
##      then the main line alone.
##   6. lines sorted by card_order, joined with joiner. line_ids go into the postcard record and
##      feed the next cards' recency filter.
## Stamp: title = place name; caption = the city's epithet from city_lore_v1.json (left out when
## its verification_status is blocked_status and blocked_policy is "omit"), or the nature place's
## own `sub`; a city's `sub` is never used. Slot label and home mark from the stamp block.
##
## Intentional differences from the Python reference (none reachable with the current library;
## where Python raises, this keeps going):
##   - a slot that is not a time group after aliases -> "day"; an unknown kit -> itself when it is a
##     kit group, else the first kit group; postcard_terrain values that are not terrain groups are
##     dropped (all dropped -> resolved from city / landform / biome).
##   - a main-line group whose every line is avoided -> the slot's time line instead, else no line.
##   - weights_by_primary missing the main category, or empty -> no second line.
##   - no_repeat_window_cards <= 0 turns the recency filter off (Python's history[-0:] is "all").
##   - weights are summed as floats with Python 3.12's compensated sum(); integer weights in the JSON
##     are summed the same way (identical unless a sum needs more than 53 bits).

const LshuHash := preload("res://scripts/traveler/lshu/loop/lshu_hash.gd")
const LshuPostcardContext := preload("res://scripts/traveler/lshu/loop/lshu_postcard_context.gd")

const TWO_POW_32: float = 4294967296.0
const TWO_POW_64: float = 18446744073709551616.0


# =============================================================================================
# Random stream, identical to rnd() in the Python reference

## sha256("|".join(str(p) for p in parts)), first 8 bytes big-endian / 2^64, in [0, 1].
static func rnd(parts: Array) -> float:
	var strs: PackedStringArray = PackedStringArray()
	for p: Variant in parts:
		strs.append(_str(p))
	var d: PackedByteArray = "|".join(strs).sha256_buffer()
	var hi: int = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]
	var lo: int = (d[4] << 24) | (d[5] << 16) | (d[6] << 8) | d[7]
	# hi * 2^32 is exact; the one addition rounds like Python's int -> float conversion.
	return (float(hi) * TWO_POW_32 + float(lo)) / TWO_POW_64


static func _step(key: Array, step: Array[int]) -> float:
	var parts: Array = key.duplicate()
	parts.append(step[0])
	step[0] += 1
	return rnd(parts)


## Python's pick_weighted(): cumulative w / total in dictionary order.
static func pick_weighted(weights: Dictionary, r: float) -> String:
	if weights.is_empty():
		return ""
	var values: Array = []
	for k: Variant in weights.keys():
		values.append(float(weights[k]))
	var total: float = py_sum(values)
	var acc: float = 0.0
	var keys: Array = weights.keys()
	for i: int in keys.size():
		acc += float(values[i]) / total
		if r < acc:
			return _str(keys[i])
	return _str(keys[keys.size() - 1])


## CPython 3.12 sum() of floats: Neumaier compensated summation, compensation added at the end.
static func py_sum(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var f: float = float(values[0])
	var c: float = 0.0
	for i: int in range(1, values.size()):
		var x: float = float(values[i])
		var t: float = f + x
		if absf(f) >= absf(x):
			c += (f - t) + x
		else:
			c += (x - t) + f
		f = t
	if c != 0.0 and is_finite(c):
		f += c
	return f


# =============================================================================================
# Library

## A library with composition rules: the rich shape with a `compose` block.
static func is_rich(lib: Dictionary) -> bool:
	return lib.get("lines") is Dictionary and lib.get("compose") is Dictionary


## The rich library behind `lines`: the library itself, or the one normalize_library() kept.
static func rich_of(lines: Dictionary) -> Dictionary:
	if is_rich(lines):
		return lines
	var kept: Variant = lines.get("rich")
	if kept is Dictionary and is_rich(kept as Dictionary):
		return kept
	return {}


static func window(lib: Dictionary) -> int:
	return int(_num(_dict(lib.get("limits")).get("no_repeat_window_cards"), 20.0))


## str(alias) -> kit group, from kits.*.aliases (numbers become "0".."3" like Python's str()).
static func alias_map(lib: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var kits: Dictionary = _dict(lib.get("kits"))
	for key: Variant in kits.keys():
		for a: Variant in _arr(_dict(kits[key]).get("aliases")):
			out[_str(a)] = _str(key)
	return out


## Line ids of the last `window` postcards, oldest first (postcards without line_ids give []).
static func history_from_postcards(postcards: Array, win: int = 20) -> Array:
	var out: Array = []
	if win <= 0:
		return out
	for i: int in range(maxi(0, postcards.size() - win), postcards.size()):
		var p: Variant = postcards[i]
		if p is Dictionary:
			out.append(_arr((p as Dictionary).get("line_ids")).duplicate())
	return out


## Structural problems in a rich library (ids, text, length, ending, avoid tokens). [] when fine.
static func validate_library(lib: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	if not is_rich(lib):
		errs.append("not a rich library (needs lines and compose)")
		return errs
	var lines: Dictionary = lib.lines
	var max_len: int = int(_num(_dict(lib.get("limits")).get("max_line_chars"), 26.0))
	var valid: Dictionary = {
		"slot": _dict(lines.get("time")).keys(), "kit": _dict(lib.get("kits")).keys(),
		"terrain": _dict(lines.get("terrain")).keys(),
	}
	var seen: Dictionary = {}
	for group: Array in _groups(lib):
		for raw: Variant in group:
			if not (raw is Dictionary):
				errs.append("line is not an object: %s" % str(raw))
				continue
			var l: Dictionary = raw
			var id: String = _str(l.get("id", ""))
			var t: String = _str(l.get("text", ""))
			if id == "" or t == "":
				errs.append("%s: missing id or text" % id)
			if seen.has(id):
				errs.append("%s: duplicate id" % id)
			seen[id] = true
			if t.length() > max_len:
				errs.append("%s: %d chars > %d" % [id, t.length(), max_len])
			if not t.ends_with("。"):
				errs.append("%s: does not end with 。" % id)
			for token: Variant in _arr(l.get("avoid")):
				var parts: PackedStringArray = _partition(_str(token))
				if not valid.has(parts[0]) or not (valid[parts[0]] as Array).has(parts[1]):
					errs.append("%s: bad avoid token %s" % [id, _str(token)])
	return errs


static func _groups(lib: Dictionary) -> Array:
	var out: Array = []
	var lines: Dictionary = _dict(lib.get("lines"))
	for cat: Variant in lines.keys():
		var v: Variant = lines[cat]
		if v is Dictionary:
			for key: Variant in (v as Dictionary).keys():
				out.append(_arr((v as Dictionary)[key]))
		else:
			out.append(_arr(v))
	return out


# =============================================================================================
# Compose (port of compose() in postcard_lines_check.py)

## raw_ctx: slot, kit, biome, landform, city_id, postcard_terrain, place_name, sub, is_home,
## is_overnight, after_long_road, minutes_since_arrive, away_card (see input_contract).
## history: Array of line-id Arrays, oldest first. key: e.g. [save seed, leg index, card index].
## Returns {categories, terrain_group, line_ids, lines, text, fallbacks, ctx (normalised)}.
static func compose_card(lib: Dictionary, raw_ctx: Dictionary, history: Array, key: Array) -> Dictionary:
	var ctx: Dictionary = normalize_context(lib, raw_ctx)
	var comp: Dictionary = _dict(lib.get("compose"))
	var prim: Dictionary = _dict(comp.get("primary"))
	var step: Array[int] = [0]
	var away: bool = _truthy(ctx.get("away_card"))
	# Step 2: the main category.
	var primary: String = ""
	if away:
		primary = _str(_dict(comp.get("away_card")).get("category", "road"))
	elif _truthy(ctx.get("is_home")):
		primary = "home"
	else:
		var m: float = _num(ctx.get("minutes_since_arrive"), 999.0)
		var r_long: float = _step(key, step)
		var r_fresh: float = _step(key, step)
		var ral: Dictionary = _dict(prim.get("road_after_long_road"))
		var rfa: Dictionary = _dict(prim.get("road_fresh_arrival"))
		if _truthy(ctx.get("after_long_road")) and m <= _num(ral.get("max_minutes_since_arrive"), 20.0) \
				and r_long < _num(ral.get("p"), 0.0):
			primary = "road"
		elif m <= _num(rfa.get("max_minutes_since_arrive"), 10.0) and r_fresh < _num(rfa.get("p"), 0.0):
			primary = "road"
		if primary == "":
			var wkey: String = "weights_overnight" if _truthy(ctx.get("is_overnight")) else "weights"
			primary = pick_weighted(_dict(prim.get(wkey)), _step(key, step))
	# Step 3: the terrain group (drawn on every card, used by terrain lines).
	var r1: float = _step(key, step)
	var r2: float = _step(key, step)
	var group: String = pick_terrain(lib, ctx.terrain_tags as Array, r1, r2)
	var taken: Array = []
	var cats: Array = []
	var fallbacks: int = 0
	var r_first: float = _step(key, step)
	var first_pick: Dictionary = _choose(lib, _pool_for(lib, primary, ctx, group), ctx, history, taken, r_first, false)
	if first_pick.line == null and primary != "time":
		# Every line of the group is avoided (Python would crash): the slot's time line instead.
		primary = "time"
		first_pick = _choose(lib, _pool_for(lib, primary, ctx, group), ctx, history, taken, r_first, false)
	if first_pick.line != null:
		var first: Dictionary = first_pick.line
		fallbacks += 1 if bool(first_pick.fallback) else 0
		taken.append(first)
		cats.append(primary)
		# Step 4: an optional second line of another category.
		var sl: Dictionary = _dict(comp.get("second_line"))
		var p_second: float = 0.0
		if not away:
			p_second = _num(sl.get("p_home"), 0.0) if primary == "home" else _num(sl.get("p"), 0.0)
		if _step(key, step) < p_second:
			var wbp: Dictionary = _dict(_dict(sl.get("weights_by_primary")).get(primary))
			var weights: Dictionary = {}
			for k: Variant in wbp.keys():
				if _str(k) != primary:
					weights[_str(k)] = wbp[k]
			var second_cat: String = pick_weighted(weights, _step(key, step))
			if second_cat != "":
				var max_card: int = int(_num(_dict(lib.get("limits")).get("max_card_chars"), 50.0))
				for _attempt: int in 2:
					var pick: Dictionary = _choose(lib, _pool_for(lib, second_cat, ctx, group), ctx, history, taken,
						_step(key, step), true)
					if pick.line == null:
						break
					var line: Dictionary = pick.line
					if _str(first.get("text", "")).length() + _str(line.get("text", "")).length() <= max_card:
						fallbacks += 1 if bool(pick.fallback) else 0
						taken.append(line)
						cats.append(second_cat)
						break
	# Step 8: fixed order, joined.
	var order: Array = _arr(comp.get("card_order"))
	if cats.size() == 2 and _order_index(order, String(cats[1])) < _order_index(order, String(cats[0])):
		cats.reverse()
		taken.reverse()
	var ids: Array[String] = []
	var texts: Array[String] = []
	var joined: PackedStringArray = PackedStringArray()
	for line2: Variant in taken:
		ids.append(_str((line2 as Dictionary).get("id", "")))
		texts.append(_str((line2 as Dictionary).get("text", "")))
		joined.append(texts[texts.size() - 1])
	var cat_out: Array[String] = []
	for c: Variant in cats:
		cat_out.append(String(c))
	return {
		"categories": cat_out, "terrain_group": group if cats.has("terrain") else "", "line_ids": ids,
		"lines": texts, "text": _str(comp.get("joiner", "\n")).join(joined), "fallbacks": fallbacks, "ctx": ctx,
	}


## The one line of the 「你不在的时候」 card: a road line under the same recency rule.
static func away_card(lib: Dictionary, history: Array, key: Array, slot: String = "day", kit: Variant = "look") -> Dictionary:
	return compose_card(lib, {"slot": slot, "kit": kit, "biome": "", "away_card": true, "place_name": ""}, history, key)


## Step 1: slot and kit through their aliases, plus terrain_tags.
static func normalize_context(lib: Dictionary, raw_ctx: Dictionary) -> Dictionary:
	var ctx: Dictionary = raw_ctx.duplicate()
	var lines: Dictionary = _dict(lib.get("lines"))
	ctx["slot"] = _norm_slot(lib, _str(ctx.get("slot", "")))
	var kit_in: String = _str(ctx.get("kit", ""))
	var kit: String = _str(alias_map(lib).get(kit_in, ""))
	if kit == "":
		var kit_groups: Dictionary = _dict(lines.get("kit"))
		if kit_groups.has(kit_in) or kit_groups.is_empty():
			kit = kit_in
		else:
			kit = _str(kit_groups.keys()[0])
	ctx["kit"] = kit
	ctx["terrain_tags"] = terrain_tags(lib, ctx)
	return ctx


static func _norm_slot(lib: Dictionary, slot_in: String) -> String:
	var aliases: Dictionary = _dict(_dict(_dict(lib.get("input_contract")).get("slot")).get("aliases"))
	var slot: String = _str(aliases.get(slot_in, slot_in))
	var time_groups: Dictionary = _dict(_dict(lib.get("lines")).get("time"))
	if not time_groups.is_empty() and not time_groups.has(slot):
		slot = "day" if time_groups.has("day") else _str(time_groups.keys()[0])
	return slot


static func terrain_tags(lib: Dictionary, ctx: Dictionary) -> Array:
	var groups: Dictionary = _dict(_dict(lib.get("lines")).get("terrain"))
	var given: Array = []
	var pt: Variant = ctx.get("postcard_terrain")
	if pt is Array:
		for x: Variant in pt as Array:
			if groups.is_empty() or groups.has(_str(x)):
				given.append(_str(x))
	elif pt is String and groups.has(pt):
		given.append(pt)
	if not given.is_empty():
		return given
	var tr: Dictionary = _dict(lib.get("terrain_resolve"))
	var tags: Array = []
	if _truthy(ctx.get("city_id")):
		tags.append("city")
	var lf: String = _str(_dict(tr.get("from_landform")).get(_str(ctx.get("landform", "")), ""))
	if lf != "" and not tags.has(lf):
		tags.append(lf)
	var bi: String = _str(_dict(tr.get("from_biome")).get(_str(ctx.get("biome", "")), ""))
	if bi != "" and not tags.has(bi):
		tags.append(bi)
	if tags.is_empty():
		tags.append(_str(tr.get("fallback", "grass")))
	return tags


static func pick_terrain(lib: Dictionary, tags: Array, r1: float, r2: float) -> String:
	var natural: Array = []
	for t: Variant in tags:
		if _str(t) != "city":
			natural.append(_str(t))
	var city_w: float = _num(_dict(_dict(lib.get("terrain_resolve")).get("pick")).get("city_weight"), 0.5)
	if tags.has("city") and (natural.is_empty() or r1 < city_w):
		return "city"
	if natural.is_empty():
		return ""
	return String(natural[mini(int(r2 * float(natural.size())), natural.size() - 1)])


static func _pool_for(lib: Dictionary, cat: String, ctx: Dictionary, group: String) -> Array:
	var lines: Dictionary = _dict(lib.get("lines"))
	if cat == "time":
		return _arr(_dict(lines.get("time")).get(ctx.slot))
	if cat == "kit":
		return _arr(_dict(lines.get("kit")).get(ctx.kit))
	if cat == "terrain":
		return _arr(_dict(lines.get("terrain")).get(group))
	return _arr(lines.get(cat))


static func avoided(line: Dictionary, ctx: Dictionary) -> bool:
	for token: Variant in _arr(line.get("avoid")):
		var parts: PackedStringArray = _partition(_str(token))
		if parts[0] == "slot" and _str(ctx.get("slot", "")) == parts[1]:
			return true
		if parts[0] == "kit" and _str(ctx.get("kit", "")) == parts[1]:
			return true
		if parts[0] == "terrain" and _arr(ctx.get("terrain_tags")).has(parts[1]):
			return true
	return false


static func _line_ok(line: Dictionary, ctx: Dictionary, used_motifs: Dictionary, check_motif: bool) -> bool:
	if avoided(line, ctx):
		return false
	if check_motif:
		for m: Variant in _arr(line.get("motifs")):
			if used_motifs.has(_str(m)):
				return false
	return true


## Port of choose(): a fresh line, else the least recently used allowed one. {line, fallback}.
static func _choose(lib: Dictionary, cands: Array, ctx: Dictionary, history: Array, taken: Array,
		r: float, strict_motif: bool) -> Dictionary:
	var win: int = window(lib)
	var recent: Dictionary = {}
	if win > 0:
		for i: int in range(maxi(0, history.size() - win), history.size()):
			for id: Variant in _arr(history[i]):
				recent[_str(id)] = true
	var used: Dictionary = {}
	for t: Variant in taken:
		for m: Variant in _arr(_dict(t).get("motifs")):
			used[_str(m)] = true
	var fresh: Array = []
	for c: Variant in cands:
		var cd: Dictionary = _dict(c)
		if not recent.has(_str(cd.get("id", ""))) and _line_ok(cd, ctx, used, true):
			fresh.append(cd)
	if not fresh.is_empty():
		return {"line": fresh[mini(int(r * float(fresh.size())), fresh.size() - 1)], "fallback": false}
	var last_use: Dictionary = {}
	for idx: int in history.size():
		for id2: Variant in _arr(history[idx]):
			last_use[_str(id2)] = idx
	var passes: Array = [true] if strict_motif else [true, false]
	for check_motif: Variant in passes:
		var found: bool = false
		var best: Dictionary = {}
		var best_use: int = 0
		var best_id: String = ""
		for c2: Variant in cands:
			var cd2: Dictionary = _dict(c2)
			if not _line_ok(cd2, ctx, used, bool(check_motif)):
				continue
			var id3: String = _str(cd2.get("id", ""))
			var u: int = int(last_use.get(id3, -1))
			if not found or u < best_use or (u == best_use and id3 < best_id):
				found = true
				best = cd2
				best_use = u
				best_id = id3
		if found:
			return {"line": best, "fallback": true}
	return {"line": null, "fallback": true}


static func _order_index(order: Array, cat: String) -> int:
	var i: int = order.find(cat)
	return i if i >= 0 else order.size()


# =============================================================================================
# Stamp

## ctx: place_name, city_id, sub, slot, is_home (compose_card's ctx works as is).
## date: {year, month, day} (LshuClock.local_info); lore: city_id -> item, loaded when empty.
## Returns {title, home_mark, date, slot, slot_label, caption, caption_kind, city_id, city_blocked}.
static func stamp(lib: Dictionary, ctx: Dictionary, date: Dictionary = {}, lore: Dictionary = {}) -> Dictionary:
	var st: Dictionary = _dict(lib.get("stamp"))
	var cl: Dictionary = _dict(st.get("city_lookup"))
	var slot: String = _norm_slot(lib, _str(ctx.get("slot", "")))
	var city_id: String = _str(ctx.get("city_id", ""))
	var caption: String = ""
	var kind: String = ""
	var blocked: bool = false
	if city_id != "":
		var items: Dictionary = lore if not lore.is_empty() else LshuPostcardContext.city_lore(lib)
		var item: Dictionary = _dict(items.get(city_id))
		blocked = not item.is_empty() and _str(item.get("verification_status", "")) == _str(cl.get("blocked_status", "CONTENT_BLOCKED"))
		if not item.is_empty() and not (blocked and _str(cl.get("blocked_policy", "omit")) == "omit"):
			caption = _str(item.get("epithet", ""))
			kind = "epithet" if caption != "" else ""
	else:
		caption = _str(ctx.get("sub", ""))
		kind = "sub" if caption != "" else ""
	var date_text: String = ""
	if date.has("month") and date.has("day"):
		date_text = _str(st.get("date_format", "{year}年{month}月{day}日")).format(
			{"year": int(date.get("year", 0)), "month": int(date.month), "day": int(date.day)})
	return {
		"title": _str(ctx.get("place_name", "")),
		"home_mark": _str(st.get("home_mark", "")) if _truthy(ctx.get("is_home")) else "",
		"date": date_text, "slot": slot, "slot_label": _str(_dict(st.get("slot_labels")).get(slot, "")),
		"caption": caption, "caption_kind": kind, "city_id": city_id, "city_blocked": blocked,
	}


## A saved postcard's stamp with the city caption looked up again, so a changed blocked_policy or
## epithet applies to old postcards too. Nature-place captions are kept as saved.
static func restamp(record: Dictionary, lib: Dictionary, lore: Dictionary = {}) -> Dictionary:
	var old: Dictionary = _dict(record.get("stamp"))
	var ctx: Dictionary = {
		"place_name": old.get("title", record.get("name", "")), "city_id": record.get("city_id", old.get("city_id", "")),
		"sub": old.get("caption", "") if _str(old.get("caption_kind", "")) == "sub" else "",
		"slot": old.get("slot", record.get("band", "")), "is_home": record.get("home", false),
	}
	var out: Dictionary = stamp(lib, ctx, {}, lore)
	out["date"] = _str(old.get("date", ""))
	return out


## One line in the Python reference's sample layout: [title  家｜date label]  caption.
static func stamp_line(st: Dictionary, date_text: String = "") -> String:
	var d: String = date_text if date_text != "" else _str(st.get("date", ""))
	var home: String = ("  " + _str(st.home_mark)) if _str(st.get("home_mark", "")) != "" else ""
	var out: String = "[%s%s｜%s %s]" % [_str(st.get("title", "")), home, d, _str(st.get("slot_label", ""))]
	if _str(st.get("caption", "")) != "":
		out += "  " + _str(st.caption)
	return out


# =============================================================================================
# Loop entry point

## Fills a postcard record the clock just made: text[], signature, and with a rich library also
## line_ids[], categories[], city_id and stamp{}. postcards: the save's records so far (the last
## no_repeat_window_cards of them are the history). date: LshuClock.local_info() of the moment.
## Random key [seed, leg index, 0] (the 0 is the card's index within the stop).
static func fill_postcard(pc: Dictionary, leg: Dictionary, lines: Dictionary, seed: int, postcards: Array,
		date: Dictionary = {}) -> void:
	if lines.is_empty():
		return
	pc["signature"] = signature(lines)
	var lib: Dictionary = rich_of(lines)
	if lib.is_empty():
		pc["text"] = compose(pc, lines, _str(leg.get("sub", "")))
		return
	var ctx: Dictionary = LshuPostcardContext.for_leg(leg, _str(pc.get("band", "")), int(pc.get("unix", -1)), lib)
	var card: Dictionary = compose_card(lib, ctx, history_from_postcards(postcards, window(lib)),
		[seed, int(leg.get("index", 0)), 0])
	pc["text"] = card.lines
	pc["line_ids"] = card.line_ids
	pc["categories"] = card.categories
	pc["city_id"] = _str((card.ctx as Dictionary).get("city_id", ""))
	pc["stamp"] = stamp(lib, card.ctx, date)


# =============================================================================================
# Legacy API (simple library shape, and callers that pass a postcard record)

## pc needs: line_seed:int, band:String, kit:String, biome:String, home:bool (night, landform,
## city_id, after_long_road, minutes_since_arrive optional). With a rich library (or one that
## normalize_library() kept) this is compose_card() with no history and key [line_seed];
## place_sub then belongs on the stamp, not in the lines. Otherwise the simple rules below.
static func compose(pc: Dictionary, lines: Dictionary, place_sub: String = "") -> Array[String]:
	var out: Array[String] = []
	if lines.is_empty():
		return out
	var lib: Dictionary = rich_of(lines)
	if not lib.is_empty():
		var ctx: Dictionary = {
			"slot": pc.get("band", ""), "kit": pc.get("kit", ""), "biome": pc.get("biome", ""),
			"landform": pc.get("landform", ""), "city_id": pc.get("city_id", ""),
			"is_home": pc.get("home", false), "is_overnight": pc.get("night", false),
			"after_long_road": pc.get("after_long_road", false), "place_name": pc.get("name", ""), "sub": place_sub,
		}
		if pc.has("minutes_since_arrive"):
			ctx["minutes_since_arrive"] = pc.minutes_since_arrive
		if pc.has("postcard_terrain"):
			ctx["postcard_terrain"] = pc.postcard_terrain
		for t: String in compose_card(lib, ctx, [], [int(pc.get("line_seed", 0))]).lines:
			out.append(t)
		return out
	if lines.get("lines") is Dictionary:
		lines = normalize_library(lines)
	var seed: int = int(pc.get("line_seed", 0))
	var rules: Dictionary = lines.get("rules", {}) as Dictionary
	var sub_chance: float = float(rules.get("sub_chance", 0.3))
	var second_chance: float = float(rules.get("second_line_chance", 0.6))
	var first: String = ""
	if bool(pc.get("home", false)):
		first = _pick(lines.get("home", []) as Array, seed, 1)
	if first == "" and place_sub != "" and LshuHash.unit(seed, 2, 0) < sub_chance:
		first = place_sub
	if first == "":
		var use_kit: bool = LshuHash.unit(seed, 3, 0) < 0.5
		var kit_lines: Array = (lines.get("kit", {}) as Dictionary).get(_str(pc.get("kit", "")), []) as Array
		var biome_lines: Array = (lines.get("biome", {}) as Dictionary).get(_str(pc.get("biome", "")), []) as Array
		if use_kit and not kit_lines.is_empty():
			first = _pick(kit_lines, seed, 4)
		elif not biome_lines.is_empty():
			first = _pick(biome_lines, seed, 5)
		elif not kit_lines.is_empty():
			first = _pick(kit_lines, seed, 4)
	var time_lines: Array = (lines.get("time", {}) as Dictionary).get(_str(pc.get("band", "")), []) as Array
	if first == "":
		first = _pick(time_lines, seed, 6)
	if first != "":
		out.append(first)
	if not time_lines.is_empty() and LshuHash.unit(seed, 7, 0) < second_chance:
		var second: String = _pick(time_lines, seed, 8)
		if second != "" and second != first:
			out.append(second)
	return out


static func signature(lines: Dictionary) -> String:
	# 正式版句库的署名是 {text: "L", ...}，简版是 "L"
	var sig: Variant = lines.get("signature", "L")
	if sig is Dictionary:
		sig = (sig as Dictionary).get("text", "L")
	return _str(sig)


## Accepts either library shape and returns the simple one the legacy compose() reads:
##   simple: {time:{band:[str]}, kit:{kit:[str]}, biome:{biome:[str]}, home:[str], rules, signature}
##   rich:   {lines:{time:{slot:[..]}, kit:{kit:[..]}, terrain:{tag:[..]}, home:[..], road:[..]},
##            kits:{kit:{aliases:[..]}}, terrain_resolve:{from_biome:{biome:tag}, fallback},
##            input_contract:{slot:{aliases:{band:slot}}}, compose:{..}}  (items: strings or {text})
## A rich library with a compose block is also kept as `rich` (by reference), so compose() and
## fill_postcard() apply its full rules; the plain lists stay for callers that read them.
static func normalize_library(lib: Dictionary) -> Dictionary:
	if lib.is_empty() or not (lib.get("lines") is Dictionary):
		return lib
	var src: Dictionary = lib.lines
	var out: Dictionary = {"signature": signature(lib), "rules": {}, "time": {}, "kit": {}, "biome": {}, "home": []}
	if is_rich(lib):
		out["rich"] = lib
	var slot_alias: Dictionary = ((lib.get("input_contract", {}) as Dictionary).get("slot", {}) as Dictionary).get("aliases", {}) as Dictionary
	var time_src: Dictionary = src.get("time", {}) as Dictionary
	for band: String in ["morning", "day", "sunset", "night"]:
		var key: String = _str(slot_alias.get(band, band))
		(out.time as Dictionary)[band] = _texts(time_src.get(key, time_src.get(band, [])))
	var kit_src: Dictionary = src.get("kit", {}) as Dictionary
	var kits_meta: Dictionary = lib.get("kits", {}) as Dictionary
	for k: Variant in kit_src.keys():
		var texts: Array = _texts(kit_src[k])
		(out.kit as Dictionary)[_str(k)] = texts
		for a: Variant in ((kits_meta.get(k, {}) as Dictionary).get("aliases", []) as Array):
			(out.kit as Dictionary)[_str(a)] = texts
	var terrain_src: Dictionary = src.get("terrain", {}) as Dictionary
	var resolve: Dictionary = lib.get("terrain_resolve", {}) as Dictionary
	var from_biome: Dictionary = resolve.get("from_biome", {}) as Dictionary
	for b: Variant in from_biome.keys():
		(out.biome as Dictionary)[_str(b)] = _texts(terrain_src.get(from_biome[b], []))
	for t: Variant in terrain_src.keys():
		if not (out.biome as Dictionary).has(t):
			(out.biome as Dictionary)[_str(t)] = _texts(terrain_src[t])
	out["home"] = _texts(src.get("home", []))
	return out


static func _texts(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for item: Variant in v as Array:
			if item is String:
				out.append(item)
			elif item is Dictionary and (item as Dictionary).has("text"):
				out.append(_str((item as Dictionary).text))
	return out


static func _pick(arr: Array, seed: int, salt: int) -> String:
	if arr.is_empty():
		return ""
	return _str(arr[LshuHash.range_i(seed, salt, 11, 0, arr.size() - 1)])


# =============================================================================================
# Small helpers

static func _partition(token: String) -> PackedStringArray:
	var i: int = token.find(":")
	if i < 0:
		return PackedStringArray([token, ""])
	return PackedStringArray([token.substr(0, i), token.substr(i + 1)])


## Python truthiness for JSON-ish values.
static func _truthy(v: Variant) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if v is int or v is float:
		return float(v) != 0.0
	if v is String:
		return (v as String) != ""
	if v is Array:
		return not (v as Array).is_empty()
	if v is Dictionary:
		return not (v as Dictionary).is_empty()
	return true


static func _num(v: Variant, fallback: float) -> float:
	if v is int or v is float:
		return float(v)
	return fallback


static func _dict(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}


static func _arr(v: Variant) -> Array:
	return v if v is Array else []


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
