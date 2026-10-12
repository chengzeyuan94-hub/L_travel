extends SceneTree
## 第四幕「L叔在哪儿」· pool load probe: how long LshuPoolAdapter.load_places() takes on the real pool (it parses
## every tile JSON), the field coverage the loop and the postcard context need, and a 14-day journey on the real
## pool per seed (stops, distinct tiles / places, repeats, consecutive layout-class repeats). Report only.
##   Godot --headless --path . --script res://tools/traveler/lshu/qa/lshu_pool_load_probe.gd -- [--out=PATH.json]

const LshuPoolAdapter := preload("res://scripts/traveler/lshu/loop/lshu_pool_adapter.gd")
const LshuPostcardContext := preload("res://scripts/traveler/lshu/loop/lshu_postcard_context.gd")
const LshuClock := preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const SEEDS: Array[int] = [1, 2, 3, 4]
const DAYS: int = 14

func _initialize() -> void:
	var out_path: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_path = arg.trim_prefix("--out=")
	var runs_ms: Array[float] = []
	var places: Array = []
	for i: int in 3:
		var t0: int = Time.get_ticks_usec()
		places = LshuPoolAdapter.load_places()
		runs_ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	var by_source: Dictionary = {}
	var place_ids: Dictionary = {}
	var kits: Dictionary = {}
	var homes: int = 0
	var fire: int = 0
	var missing: int = 0
	for e: Variant in places:
		var d: Dictionary = e
		by_source[str(d.source)] = int(by_source.get(str(d.source), 0)) + 1
		place_ids[str(d.place)] = true
		kits[str(d.kit)] = int(kits.get(str(d.kit), 0)) + 1
		homes += 1 if bool(d.is_home) else 0
		fire += 1 if bool(d.get("fire", false)) else 0
		if str(d.place) == "" or str(d.kit) == "" or str(d.biome) == "" or str(d.name) == "":
			missing += 1
	var ctx_city: int = 0
	var ctx_sub: int = 0
	var ctx_terrain: int = 0
	var ctx_landform: int = 0
	for e2: Variant in places:
		var d2: Dictionary = e2
		var leg: Dictionary = {"tile": d2.id, "kit": d2.kit, "biome": d2.biome, "name": d2.name, "sub": d2.sub, "arrive": 0}
		var ctx: Dictionary = LshuPostcardContext.for_leg(leg, "day", 600)
		ctx_city += 1 if str(ctx.get("city_id", "")) != "" else 0
		ctx_sub += 1 if str(ctx.get("sub", "")) != "" else 0
		ctx_terrain += 1 if ctx.has("postcard_terrain") else 0
		ctx_landform += 1 if str(ctx.get("landform", "")) != "" else 0
	var journeys: Array = []
	for seed: int in SEEDS:
		journeys.append(_journey(seed, places))
	var rep: Dictionary = {
		"schema": "lshu.pool-load-probe.v1", "tiles": places.size(), "places": place_ids.size(), "kits": kits,
		"home_tiles": homes, "tiles_with_fire": fire, "tiles_missing_fields": missing, "sources": by_source,
		"load_places_ms": runs_ms, "postcard_ctx": {"city_id": ctx_city, "sub": ctx_sub, "postcard_terrain": ctx_terrain, "landform": ctx_landform},
		"journey_14d": journeys,
	}
	print("LSHU_POOL_LOAD ", JSON.stringify(rep))
	if out_path != "":
		var f: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(rep, " ") + "\n")
		f.close()
	quit(0 if missing == 0 and not places.is_empty() else 1)


## Follows one seed for DAYS days from 2026-09-24 09:00 (UTC+8) by jumping from road end to road end.
func _journey(seed: int, places: Array) -> Dictionary:
	var cfg: Dictionary = LshuClock.load_config()
	cfg["tz_offset_minutes"] = 480
	var start: int = int(Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 9, "day": 24, "hour": 9, "minute": 0, "second": 0})) - 480 * 60
	var r: Dictionary = LshuClock.resolve({"seed": seed}, start, places, cfg)
	var s: Dictionary = r.save
	var legs: Array = [r.leg]
	var guard: int = 0
	while int((s.current_leg as Dictionary).arrive) < start + DAYS * 86400 and guard < 5000:
		guard += 1
		r = LshuClock.resolve(s, float(int((s.current_leg as Dictionary).road_end)), places, cfg)
		s = r.save
		legs.append(r.leg)
	var trip_stops: int = 0
	var tiles: Dictionary = {}
	var place_ids: Dictionary = {}
	var repeats: int = 0
	var same_class: int = 0
	var pairs: int = 0
	var prev_class: String = ""
	for leg: Variant in legs:
		var l: Dictionary = leg
		if bool(l.home):
			prev_class = ""
			continue
		trip_stops += 1
		var tid: String = str(l.tile)
		if tiles.has(tid):
			repeats += 1
		tiles[tid] = int(tiles.get(tid, 0)) + 1
		place_ids[str(l.place)] = true
		var cls: String = str(l.get("layout_class", ""))
		if prev_class != "":
			pairs += 1
			same_class += 1 if cls == prev_class else 0
		prev_class = cls
	return {"seed": seed, "days": DAYS, "legs": legs.size(), "trip_stops": trip_stops, "distinct_tiles": tiles.size(),
		"distinct_places": place_ids.size(), "tile_revisits": repeats, "consecutive_same_layout_class": same_class,
		"consecutive_pairs": pairs}
