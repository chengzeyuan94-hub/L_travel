extends RefCounted
## Act 4 loop: builds the `places` Array that LshuClock.resolve() takes, from pool.json.
##
## Field sources, later ones win:
##   1. data/traveler/lshu/tiles/<id>.json (lshu.tile.v1): place.id / place.name / place.theme,
##      layout.id, kit.mode, fires[] (non-empty = the tile has a fire)
##   2. dev only: the web catalog copy (journey960.json) by composition_id, used when a tile JSON
##      is not baked yet; it also supplies the nature places' one-line `sub` for postcards.
##      The catalog lives in a .gdignore'd folder, so an exported build simply skips this step.
##   3. explicit fields on the pool.json tile entry: place, kit, layout, layout_class, biome,
##      is_home, night_ok, fire, place_name, sub, blocked
## pool.json top level: "home" (tile id, place id, or an array of them), "blocklist" (tile,
## place or composition ids; skipped), optional "night_blocklist" (never shown at night).
## This file names no tile, place or asset id: all of them come from pool.json.

const POOL_JSON: String = "res://data/traveler/lshu/pool.json"
const TILES_DIR: String = "res://data/traveler/lshu/tiles"
const DEV_CATALOG_JSON: String = "res://tools/traveler/lshu/web_src/config/journey960.json"


static func load_places(pool_path: String = POOL_JSON, tiles_dir: String = TILES_DIR,
		catalog_path: String = DEV_CATALOG_JSON, home_whole_place: bool = true) -> Array:
	var pool: Dictionary = _read_json(pool_path)
	if pool.is_empty():
		return []
	return places_from_pool(pool, tiles_dir, catalog_path, home_whole_place)


static func places_from_pool(pool: Dictionary, tiles_dir: String, catalog_path: String, home_whole_place: bool) -> Array:
	var catalog: Dictionary = _catalog(catalog_path)
	var block: Dictionary = _as_set(pool.get("blocklist", []))
	var night_block: Dictionary = _as_set(pool.get("night_blocklist", []))
	var out: Array = []
	for raw: Variant in pool.get("tiles", []) as Array:
		var entry: Dictionary = raw if raw is Dictionary else {"id": _str(raw)}
		var id: String = _str(entry.get("id", ""))
		if id == "":
			continue
		var comp: String = _str(entry.get("composition_id", id))
		var e: Dictionary = {"id": id, "place": "", "kit": "", "layout": "", "biome": "", "name": "",
			"sub": "", "is_home": false, "night_ok": true, "blocked": false, "source": "entry"}
		var tj: Dictionary = _read_json(tiles_dir.path_join(id + ".json")) if tiles_dir != "" else {}
		if not tj.is_empty():
			var place: Dictionary = tj.get("place", {}) as Dictionary
			e["place"] = _str(place.get("id", ""))
			e["name"] = _str(place.get("name", ""))
			e["biome"] = _str(place.get("theme", ""))
			e["layout"] = (tj.get("layout", {}) as Dictionary).get("id", "")
			e["kit"] = _str((tj.get("kit", {}) as Dictionary).get("mode", ""))
			e["fire"] = not (tj.get("fires", []) as Array).is_empty()
			e["source"] = "tile_json"
		if not catalog.is_empty() and (catalog.recipes as Dictionary).has(comp):
			var r: Dictionary = catalog.recipes[comp]
			var pl: Dictionary = (catalog.places as Dictionary).get(_str(r.get("scene_id", "")), {}) as Dictionary
			if _str(e.place) == "":
				e["place"] = _str(r.get("scene_id", ""))
				e["name"] = _str(pl.get("name", e.place))
				e["biome"] = _str(pl.get("theme", ""))
				e["layout"] = int(r.get("variant", 0))
				var profiles: Array = catalog.profiles
				var pi: int = int(r.get("profile", 0))
				e["kit"] = _str((profiles[pi] as Dictionary).get("mode", "")) if pi >= 0 and pi < profiles.size() else ""
				e["source"] = "catalog"
			# Nature places carry a one-line description that reads well on a postcard; city
			# places carry modelling notes instead, so they are skipped.
			if pl.get("city", null) == null and not bool(pl.get("new_city", false)):
				e["sub"] = _str(pl.get("sub", ""))
		for key: String in ["place", "kit", "layout", "layout_class", "biome", "is_home", "night_ok", "fire", "sub", "blocked"]:
			if entry.has(key) and entry[key] != null:
				e[key] = entry[key]
		if entry.has("place_name"):
			e["name"] = _str(entry.place_name)
		if _str(e.place) == "":
			e["place"] = id
		if _str(e.name) == "":
			e["name"] = _str(e.place)
		if block.has(id) or block.has(e.place) or block.has(comp):
			e["blocked"] = true
		if night_block.has(id) or night_block.has(e.place) or night_block.has(comp):
			e["night_ok"] = false
		out.append(e)
	var home_keys: Dictionary = _as_set(pool.get("home", []))
	var home_places: Dictionary = {}
	for e: Variant in out:
		var ed: Dictionary = e
		if home_keys.has(ed.id) or home_keys.has(ed.place):
			ed["is_home"] = true
		if bool(ed.is_home):
			home_places[ed.place] = true
	if home_whole_place:
		for e: Variant in out:
			if home_places.has((e as Dictionary).place):
				(e as Dictionary)["is_home"] = true
	return out


static func _catalog(path: String) -> Dictionary:
	if path == "":
		return {}
	var d: Dictionary = _read_json(path)
	if d.is_empty():
		return {}
	var recipes: Dictionary = {}
	for r: Variant in d.get("recipes", []) as Array:
		recipes[_str((r as Dictionary).get("composition_id", ""))] = r
	var places: Dictionary = {}
	for p: Variant in d.get("places", []) as Array:
		places[_str((p as Dictionary).get("id", ""))] = p
	return {"recipes": recipes, "places": places, "profiles": d.get("profiles", []) as Array}


static func _as_set(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if v is String:
		if _str(v) != "":
			out[_str(v)] = true
	elif v is Array:
		for x: Variant in v as Array:
			out[_str(x)] = true
	elif v is Dictionary:
		for key: String in ["tile", "place", "id"]:
			if (v as Dictionary).has(key):
				out[_str((v as Dictionary)[key])] = true
		for x: Variant in (v as Dictionary).get("tiles", []) as Array:
			out[_str(x)] = true
	return out


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
