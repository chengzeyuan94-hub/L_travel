extends RefCounted
## Act 4 loop: the input context of one postcard (the `input_contract` block of
## data/traveler/lshu/postcard_lines.json), built from a stop of the loop.
##
## Field            first non-empty source wins (input_contract order)
##   slot             the light band at the postcard moment (the rules resolve its aliases)
##   kit              leg.kit (the pool adapter already merged pool.kit / tile.kit.mode)
##   biome            leg.biome, else tile.place.theme
##   landform         leg.landform, pool entry landform, tile.place.landform
##   city_id          leg.city_id, pool entry city_id, else a city name (leg.city, pool entry city,
##                    tile.place.city) looked up in cities.json by display_name
##   postcard_terrain leg.postcard_terrain, pool entry postcard_terrain
##   place_name       leg.name (the adapter merged pool.place_name / tile.place.name)
##   sub              leg.sub (the adapter merged pool.sub / the web catalog's nature-place sub)
##   is_home / is_overnight / after_long_road   leg.home / leg.night / leg.after_long_road
##   minutes_since_arrive   (card_unix - leg.arrive) / 60
##
## The pool adapter does not carry landform, city or postcard_terrain on a stop yet, so they are
## read here from pool.json and tiles/<id>.json. Every file is read-only, parsed once and read
## again only when its modification time changes. No tile, place or asset id is written here.

const LshuPoolAdapter := preload("res://scripts/traveler/lshu/loop/lshu_pool_adapter.gd")

const CITIES_JSON: String = "res://data/rulesets/lshu_configurable_v1/cities.json"
const LORE_JSON: String = "res://data/rulesets/lshu_configurable_v1/presentation/city_lore_v1.json"

## path -> {mtime:int, data:Variant, derived:{name: Variant}}
static var _cache: Dictionary = {}


static func for_leg(leg: Dictionary, band: String, card_unix: int, lib: Dictionary = {},
		pool_path: String = LshuPoolAdapter.POOL_JSON, tiles_dir: String = LshuPoolAdapter.TILES_DIR) -> Dictionary:
	var tile_id: String = _str(leg.get("tile", ""))
	var entry: Dictionary = pool_entry(tile_id, pool_path)
	var place: Dictionary = tile_place(tile_id, tiles_dir)
	var city_id: String = _first([leg.get("city_id"), entry.get("city_id")])
	if city_id == "":
		var city_name: String = _first([leg.get("city"), entry.get("city"), place.get("city")])
		if city_name != "":
			city_id = city_id_for_name(city_name, lib)
	var terrain: Variant = leg.get("postcard_terrain")
	if not _filled(terrain):
		terrain = entry.get("postcard_terrain")
	var ctx: Dictionary = {
		"slot": band,
		"kit": leg.get("kit", ""),
		"biome": _first([leg.get("biome"), place.get("theme")]),
		"landform": _first([leg.get("landform"), entry.get("landform"), place.get("landform")]),
		"city_id": city_id,
		"place_name": _first([leg.get("name"), place.get("name"), leg.get("place")]),
		"sub": _str(leg.get("sub", "")),
		"is_home": bool(leg.get("home", false)),
		"is_overnight": bool(leg.get("night", false)),
		"after_long_road": bool(leg.get("after_long_road", false)),
	}
	if _filled(terrain):
		ctx["postcard_terrain"] = terrain
	var arrive: Variant = leg.get("arrive")
	if card_unix >= 0 and (arrive is int or arrive is float):
		ctx["minutes_since_arrive"] = float(card_unix - int(arrive)) / 60.0
	return ctx


## The pool.json entry for a tile ({} when the pool lists it as a bare id or not at all).
static func pool_entry(tile_id: String, pool_path: String = LshuPoolAdapter.POOL_JSON) -> Dictionary:
	if tile_id == "":
		return {}
	var data: Variant = _load(pool_path)
	if not (data is Dictionary):
		return {}
	var by_id: Variant = _derived(pool_path, "by_id")
	if not (by_id is Dictionary):
		by_id = {}
		for raw: Variant in (data as Dictionary).get("tiles", []) as Array:
			if raw is Dictionary:
				(by_id as Dictionary)[_str((raw as Dictionary).get("id", ""))] = raw
		_set_derived(pool_path, "by_id", by_id)
	return (by_id as Dictionary).get(tile_id, {}) as Dictionary


## `place` block of tiles/<id>.json ({} when the tile JSON is not baked yet).
static func tile_place(tile_id: String, tiles_dir: String = LshuPoolAdapter.TILES_DIR) -> Dictionary:
	if tile_id == "" or tiles_dir == "":
		return {}
	var data: Variant = _load(tiles_dir.path_join(tile_id + ".json"))
	if not (data is Dictionary):
		return {}
	var place: Variant = (data as Dictionary).get("place", {})
	return place if place is Dictionary else {}


## cities.json display_name -> id; "" when the name is not a known city.
static func city_id_for_name(display_name: String, lib: Dictionary = {}) -> String:
	var path: String = _lookup_path(lib, "cities_file", CITIES_JSON)
	var data: Variant = _load(path)
	if not (data is Dictionary):
		return ""
	var by_name: Variant = _derived(path, "by_name")
	if not (by_name is Dictionary):
		by_name = {}
		for it: Variant in (data as Dictionary).get("items", []) as Array:
			if it is Dictionary:
				(by_name as Dictionary)[_str((it as Dictionary).get("display_name", ""))] = _str((it as Dictionary).get("id", ""))
		_set_derived(path, "by_name", by_name)
	return _str((by_name as Dictionary).get(display_name, ""))


## city_lore_v1.json items keyed by city_id.
static func city_lore(lib: Dictionary = {}) -> Dictionary:
	var path: String = _lookup_path(lib, "lore_file", LORE_JSON)
	var data: Variant = _load(path)
	if not (data is Dictionary):
		return {}
	var by_id: Variant = _derived(path, "by_city")
	if not (by_id is Dictionary):
		by_id = {}
		for it: Variant in (data as Dictionary).get("items", []) as Array:
			if it is Dictionary:
				(by_id as Dictionary)[_str((it as Dictionary).get("city_id", ""))] = it
		_set_derived(path, "by_city", by_id)
	return by_id as Dictionary


static func _lookup_path(lib: Dictionary, field: String, fallback: String) -> String:
	var st: Variant = lib.get("stamp", {})
	if st is Dictionary:
		var cl: Variant = (st as Dictionary).get("city_lookup", {})
		if cl is Dictionary and _str((cl as Dictionary).get(field, "")) != "":
			return _str((cl as Dictionary)[field])
	return fallback


# ---------------------------------------------------------------------------------------------
# Read-only JSON cache

static func _load(path: String) -> Variant:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var mt: int = FileAccess.get_modified_time(path)
	var hit: Variant = _cache.get(path)
	if hit is Dictionary and int((hit as Dictionary).mtime) == mt:
		return (hit as Dictionary).data
	var j: JSON = JSON.new()
	var data: Variant = null
	if j.parse(FileAccess.get_file_as_string(path)) == OK:
		data = j.data
	_cache[path] = {"mtime": mt, "data": data, "derived": {}}
	return data


static func _derived(path: String, name: String) -> Variant:
	var hit: Variant = _cache.get(path)
	if hit is Dictionary:
		return ((hit as Dictionary).derived as Dictionary).get(name)
	return null


static func _set_derived(path: String, name: String, value: Variant) -> void:
	var hit: Variant = _cache.get(path)
	if hit is Dictionary:
		((hit as Dictionary).derived as Dictionary)[name] = value


# ---------------------------------------------------------------------------------------------
# Small helpers

static func _filled(v: Variant) -> bool:
	if v == null:
		return false
	if v is String:
		return (v as String) != ""
	if v is Array:
		return not (v as Array).is_empty()
	return true


static func _first(values: Array) -> String:
	for v: Variant in values:
		var s: String = _str(v)
		if s != "":
			return s
	return ""


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
