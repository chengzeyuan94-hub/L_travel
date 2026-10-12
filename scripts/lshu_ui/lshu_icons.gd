extends RefCounted
## 货物 / 白银图标统一入口（Carlos 2026-09-26：「城市交易小面板上面的 icon 和实际交易面板不一致，容易弄混，
## 请你统一面板 icon，以最新的为准」）。最新的是 L叔 立体小图标 assets/game/ui/lshu_3d/icons/<货物 id>.png
## 和 silver.png——市集面板、挎包口袋、对手小卡都用它。地图上的城市贸易小卡、2D 棋盘气泡、城市卡、
## 开局页、事件交换也统一从这里取；找不到才退回规则包里的旧图。

const DIR := "res://assets/game/ui/lshu_3d/icons/"
static var _cache: Dictionary = {}


static func good(good_id: String, content: Dictionary = {}) -> Texture2D:
	var actual_content: Dictionary = content if not content.is_empty() else GameState.content
	var sprite: String = str(actual_content.get("goods", {}).get(good_id, {}).get("sprite", ""))
	var key := "good:" + good_id + ":" + sprite
	if sprite.begins_with(CustomMapLocalAssets.root() + "/"):
		var local := CustomMapLocalAssets.read(sprite.get_file(), "good_icon")
		return CustomMapLocalAssets.texture(sprite.get_file()) if local.ok else null
	if _cache.has(key):
		return _cache[key]
	var p := DIR + good_id + ".png"
	var t: Texture2D = null
	if not good_id.is_empty() and ResourceLoader.exists(p):
		t = load(p) as Texture2D
	if t == null:
		var c: Dictionary = content if not content.is_empty() else GameState.content
		t = GameData.get_good_texture(c, good_id)
	_cache[key] = t
	return t


static func silver() -> Texture2D:
	if _cache.has("silver"):
		return _cache["silver"]
	var t := load(DIR + "silver.png") as Texture2D
	_cache["silver"] = t
	return t


## 贸易卡上的一项：白银或某种货
static func entry(e: Dictionary, content: Dictionary = {}) -> Texture2D:
	if String(e.get("resource_kind", "")) == "SILVER":
		return silver()
	return good(String(e.get("resource_id", "")), content)
