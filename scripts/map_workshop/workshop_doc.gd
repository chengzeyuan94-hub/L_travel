extends RefCounted
## 工坊当前打开的那张地图（DESIGN 3.2、3.12.12）：文档本身、它的规范化文本和 sha、有没有没保存的改动，
## 以及工坊对文档的每一种改法。只改数据，不碰棋盘；每改一次返回改之前的文档，给撤销栈记一步。
## 原版城位移写 moves.cities；新城位移写 new_cities 并带动路线末端。其它候选修改由 workshop_mutations.gd 校验后提交。
## 「存过没有、存的是哪一版」按 map_id 记（saved_shas）：撤销栈只存文档，撤销 / 重做把 map_id 带回来时，
## 保存状态跟着 map_id 自动推出来（重置换了新 map_id，撤销重置又回到存过的那张）。

const Backend := preload("res://scripts/map_workshop/workshop_backend.gd")

var doc: Dictionary = {}
var home := {}                   # city id -> 原布局 city 字典（原位）
var saved_shas := {}             # map_id -> 上次保存（或打开）时的 sha
var fresh_sha := ""              # 新建 / 重置出来那一刻的 sha：一下都没改过的新图，关窗口不用问
var installed_sha := ""          # 游戏里装着的那份的 sha（「已装进游戏」小绿章）

## 这张图（按现在的 map_id）存过没有
var ever_saved: bool:
	get:
		return saved_shas.has(map_id())
	set(v):
		if v and not saved_shas.has(map_id()):
			saved_shas[map_id()] = ""
		elif not v:
			saved_shas.erase(map_id())

## 这张图上次保存时的 sha（"" = 从没保存过）
var saved_sha: String:
	get:
		return String(saved_shas.get(map_id(), ""))
	set(v):
		saved_shas[map_id()] = v


func _init(base_layout: Dictionary) -> void:
	for c: Dictionary in base_layout.get("cities", []):
		home[String(c.id)] = c


func new_map(map_name := "新地图") -> void:
	doc = Backend.empty_doc(map_name)
	fresh_sha = sha()


## 打开一张图。saved = 它在库里存着；saved_version_sha 给了时按它算「存过的那一版」（自动存档打开的图：内容比存的新）
func open(d: Dictionary, saved: bool, saved_version_sha := "") -> void:
	doc = d.duplicate(true)
	fresh_sha = ""
	if saved:
		saved_shas[map_id()] = saved_version_sha if saved_version_sha != "" else sha()


func map_id() -> String:
	return String(doc.get("map_id", ""))


func canonical() -> String:
	return Backend.canonical_text(doc)


func sha() -> String:
	return Backend.sha256(doc)


## 有没保存的改动：新建、没保存过的图也算
func is_dirty() -> bool:
	return not ever_saved or sha() != saved_sha


## 新建（或重置）出来以后一下都没改过：关窗口直接关，不用问「要先保存吗」
func is_untouched() -> bool:
	return not ever_saved and fresh_sha != "" and sha() == fresh_sha


func mark_saved() -> void:
	saved_shas[map_id()] = sha()


func map_name() -> String:
	return String(doc.get("name", "新地图"))


func moves() -> Dictionary:
	return doc.get("moves", {}).get("cities", {})


## 一座原版城现在在哪：{x, z, rotation}（没挪过就是原位）
func city_pos(cid: String) -> Dictionary:
	for c: Dictionary in doc.get("new_cities", []):
		if "x_" + String(c.slot) == cid:
			return {"x": float(c.x), "z": float(c.z), "rotation": float(c.get("rotation", 0.0))}
	var m: Dictionary = moves().get(cid, {})
	if not m.is_empty():
		return {"x": float(m.x), "z": float(m.z), "rotation": float(m.get("rotation", 0.0))}
	var h: Dictionary = home.get(cid, {})
	return {"x": float(h.get("x", 0.0)), "z": float(h.get("z", 0.0)), "rotation": float(h.get("rotation", 0.0))}


func is_moved(cid: String) -> bool:
	return moves().has(cid)


# ------------------------------------------------------------------ 改法（每个都返回改之前的文档）
## 挪原版城：坐标取整到 0.001；挪回原位就从 moves 里拿掉（文档里只列真的挪过的城）
func set_city(cid: String, x: float, z: float, rotation: float) -> Dictionary:
	var before := doc.duplicate(true)
	_put_city(doc, home, cid, x, z, rotation)
	_touch()
	return before


## 拖动、数字框试一个位置用：文档的浅拷贝，只把这座城换到 (x, z, rotation)，原文档不动。
## 拖动中的合格判断、松手时的全套检查、数字框的检查都拿它去推导（Backend.derive），和提交后走的是同一条路（R27）
static func with_city(d: Dictionary, home_of: Dictionary, cid: String, x: float, z: float, rotation: float) -> Dictionary:
	var out := d.duplicate(false)
	if cid.begins_with("x_"):
		out["new_cities"] = (d.get("new_cities", []) as Array).duplicate(true)
	var mv: Dictionary = d.get("moves", {}).duplicate(false)
	mv["cities"] = (mv.get("cities", {}) as Dictionary).duplicate(false)
	out["moves"] = mv
	_put_city(out, home_of, cid, x, z, rotation)
	return out


static func _put_city(d: Dictionary, home_of: Dictionary, cid: String, x: float, z: float, rotation: float) -> void:
	if cid.begins_with("x_"):
		for c: Dictionary in d.get("new_cities", []):
			if "x_" + String(c.slot) != cid:
				continue
			var old := Vector2(float(c.x), float(c.z))
			var delta := Vector2(x, z) - old
			var handles: Array = c.get("route", {}).get("handles", [])
			for i in handles.size():
				var p := Vector2(float(handles[i][0]), float(handles[i][1]))
				p += delta * clampf(1.0 - p.distance_to(old) / 4.0, 0.0, 1.0)
				handles[i] = [Backend.round3(p.x), Backend.round3(p.y)]
			c["x"] = Backend.round3(x)
			c["z"] = Backend.round3(z)
			c["rotation"] = Backend.round3(rotation)
			return
		return
	var h: Dictionary = home_of.get(cid, {})
	var m := {"x": Backend.round3(x), "z": Backend.round3(z), "rotation": Backend.round3(rotation)}
	if not d.has("moves"):
		d["moves"] = {"cities": {}, "routes": {}}
	if not (d["moves"] as Dictionary).has("cities"):
		d["moves"]["cities"] = {}
	var cities: Dictionary = d["moves"]["cities"]
	if not h.is_empty() and absf(m.x - Backend.round3(float(h.x))) < 0.0005 and absf(m.z - Backend.round3(float(h.z))) < 0.0005 \
			and absf(m.rotation - Backend.round3(float(h.get("rotation", 0.0)))) < 0.0005:
		cities.erase(cid)
	else:
		cities[cid] = m


## 「放回原处」（一座）
func reset_city(cid: String) -> Dictionary:
	var before := doc.duplicate(true)
	(doc["moves"]["cities"] as Dictionary).erase(cid)
	_touch()
	return before


## 「全部放回原处」：撤掉所有原城的挪动和原路的改形（新城不受影响）
func reset_all_originals() -> Dictionary:
	var before := doc.duplicate(true)
	doc["moves"] = {"cities": {}, "routes": {}}
	_touch()
	return before


## 「重置」：回到原版棋盘，成为一张名叫「新地图」的未保存地图（也进撤销栈；新的 map_id，所以自然是「没存过」）
func reset_to_original() -> Dictionary:
	var before := doc.duplicate(true)
	doc = Backend.empty_doc("新地图")
	fresh_sha = sha()
	return before


func rename(new_name: String) -> Dictionary:
	var before := doc.duplicate(true)
	doc["name"] = new_name
	_touch()
	return before


func _touch() -> void:
	if doc.has("workshop"):
		doc["workshop"]["updated_at"] = Time.get_datetime_string_from_system(false, false)


## 「这张地图」面板的「改过的原版」一行：长安挪了一点 · 真腊—泉州 改了路形
func edits_summary(names: Dictionary) -> String:
	var parts := PackedStringArray()
	var ids: Array = moves().keys()
	ids.sort()
	for cid in ids:
		var m: Dictionary = moves()[cid]
		var h: Dictionary = home.get(String(cid), {})
		var turned := not h.is_empty() and absf(float(m.get("rotation", 0.0)) - float(h.get("rotation", 0.0))) > 0.0005
		var shifted := not h.is_empty() and Vector2(float(m.x) - float(h.x), float(m.z) - float(h.z)).length() > 0.0005
		var what := "挪了一点" if shifted and not turned else ("转了个向" if turned and not shifted else "挪了挪、转了转")
		parts.append("%s%s" % [String(names.get(cid, cid)), what])
	return " · ".join(parts)


func new_city_count() -> int:
	return (doc.get("new_cities", []) as Array).size()


func user_city_count() -> int:
	var n := 0
	for c: Dictionary in doc.get("new_cities", []):
		if String(c.get("origin", "")) == "USER":
			n += 1
	return n
