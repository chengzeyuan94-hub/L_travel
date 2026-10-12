class_name CustomMapStore

## ShanheLvren/maps/ 目录读写：原子写、库、安装、回收站、按图分开的自动存档
## （docs/design/map-editor-20260930/DESIGN.md 3.1、3.12.8、3.12.11）。工坊写，游戏只读。归 WP1。
##
##   maps/installed.json          「导入地图」写的外壳：{schema, sha256, installed_at, overlay: 整份地图}（整份副本，不是指针）
##   maps/installed.png           缩略图 480×270
##   maps/library/<map_id>.json   命名保存的地图；.png 缩略图；.json.bak 覆盖保存前自动留的上一版
##   maps/autosave/<map_id>.json  工坊每次改动后写；每张图一份
##   maps/trash/<map_id>.<sha 前 8 位>.json   扔掉的地图、丢掉的未保存改动、另存为时换掉的旧图；按 map_id + sha 去重，留最近 40 份
## 被换下的 installed.json 不进 trash：库里没有同 sha 的副本时存进 library/，名字后加「（换下来的）」。
## 写文件一律 .tmp → flush → 查错 → rename（照 lshu_match_save.gd:67-81）；rename 是原子的，工坊和游戏可以同时开着。

const Progress := preload("res://scripts/lshu_ui/lshu_progress.gd")
const INSTALLED := "installed.json"
const INSTALLED_THUMB := "installed.png"
const TRASH_SCHEMA := "lshu.custom_map_trash.v1"
const TRASH_KEEP := 40
const THUMB_SIZE := Vector2i(480, 270)
const SUFFIX_REPLACED := "（换下来的）"
const SUFFIX_RESTORED := "（拿回来的）"
const TRASH_KINDS: Array[String] = ["thrown", "unsaved", "replaced"]

## maps/ 下读文件的次数（P-2：入口门关着时必须是 0）
static var reads := 0
static var last_thumbnail_warning := ""
## 普通保存的 JSON 已提交，但附属文件未能更新；与安装提示独立。
static var last_save_warning := ""


## <OS.get_data_dir()>/ShanheLvren/maps
static func maps_dir() -> String:
	return Progress.dir_path().path_join("maps")


static func _sub(name: String) -> String:
	return maps_dir().path_join(name)


## 写 .tmp → flush → 查错 → rename（照 lshu_match_save.gd:67-81）
static func atomic_write(path: String, text: String) -> Error:
	return _atomic(path, text.to_utf8_buffer())


static func _atomic(path: String, bytes: PackedByteArray) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if err != OK and not DirAccess.dir_exists_absolute(path.get_base_dir()):
		return err
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	# 打开成功不代表写完：先确认缓冲区落盘成功，才替换原文件
	f.flush()
	var written := f.get_error() == OK
	f.close()
	if not written:
		DirAccess.remove_absolute(tmp)
		return ERR_FILE_CANT_WRITE
	var renamed := DirAccess.rename_absolute(tmp, path)
	if renamed != OK and FileAccess.file_exists(tmp):
		# Only the regular temporary file written by this call; obstruction directories stay.
		DirAccess.remove_absolute(tmp)
	return renamed


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	reads += 1
	# 用户文件损坏是可恢复的读取失败，交给上层给出地图提示；不要额外触发引擎错误。
	var json := JSON.new()
	return json.data if json.parse(FileAccess.get_file_as_string(path)) == OK else null


static func _write_json(path: String, doc: Dictionary) -> Error:
	return atomic_write(path, JSON.stringify(doc, "  ", true) + "\n")


static func _write_thumb(path: String, thumb: Image) -> Error:
	if thumb == null or thumb.is_empty():
		return OK
	var img := thumb.duplicate() as Image
	if img.get_size() != THUMB_SIZE:
		img.resize(THUMB_SIZE.x, THUMB_SIZE.y, Image.INTERPOLATE_BILINEAR)
	return _atomic(path, img.save_png_to_buffer())


## map_id 只用于文件名，只收 [a-z0-9_]（防止路径穿越）
static func valid_map_id(map_id: String) -> bool:
	if map_id.is_empty() or map_id.length() > 64:
		return false
	for ch in map_id:
		if not (ch >= "a" and ch <= "z") and not (ch >= "0" and ch <= "9") and ch != "_":
			return false
	return true


## 本机时间，精确到毫秒（一次读系统时间，排序不会在整秒交界处颠倒）
static func _now() -> String:
	var t := Time.get_unix_time_from_system()
	var local := int(floor(t)) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return "%s.%03d" % [Time.get_datetime_string_from_unix_time(local, true), int((t - floor(t)) * 1000.0)]


# ---------------------------------------------------------------- 安装（游戏读的那一份）

## 读 installed.json 外壳：{schema, sha256, installed_at, overlay}；没有、不是对象时返回 {}。
## 外壳的 schema 和 sha 由调用方核对（CustomMapValidator.validate_installed），这里只读
static func read_installed() -> Dictionary:
	var v: Variant = _read_json(_sub(INSTALLED))
	return v if v is Dictionary else {}


## installed.json 在不在（不算读文件）
static func has_installed() -> bool:
	return FileAccess.file_exists(_sub(INSTALLED))


## 只读外壳的 {installed_at, sha256}，切回窗口时用（不做整份校验）
static func read_installed_stamp() -> Dictionary:
	var shell := read_installed()
	if shell.is_empty():
		return {}
	return {"installed_at": str(shell.get("installed_at", "")), "sha256": str(shell.get("sha256", ""))}


## 「导入地图」：写 installed.json 和 installed.png（480×270）。原来装着的那份，库里没有同 sha 的副本时先存进 library/
static func write_installed(overlay: Dictionary, thumb: Image) -> Error:
	var keep_err := _keep_replaced_installed()
	if keep_err != OK:
		return keep_err
	var shell := {
		"schema": CustomMapSchema.INSTALL_SCHEMA,
		"sha256": CustomMapSchema.sha256(overlay),
		"installed_at": _now(),
		"overlay": overlay,
	}
	# 缩略图先准备；失败时 installed.json 尚未改动，错误不会误报已安装的地图。
	last_thumbnail_warning = ""
	var staged := _sub(INSTALLED_THUMB) + ".pending"
	if thumb != null:
		var preview_err := _write_thumb(staged, thumb)
		if preview_err != OK: return preview_err
	var err := _write_json(_sub(INSTALLED), shell)
	if err != OK:
		if FileAccess.file_exists(staged): DirAccess.remove_absolute(staged)
		return err
	if thumb != null and FileAccess.file_exists(staged):
		var preview_err := DirAccess.rename_absolute(staged, _sub(INSTALLED_THUMB))
		if preview_err != OK:
			# 地图已原子提交：报告安装成功、记录非关键缩略图告警。
			last_thumbnail_warning = "地图已导入；缩略图未更新。"
			DirAccess.remove_absolute(staged)
	else:
		if FileAccess.file_exists(_sub(INSTALLED_THUMB)): DirAccess.remove_absolute(_sub(INSTALLED_THUMB))
	return OK


## 卸下已导入的地图（「让游戏用回原版」）：同样先把它留进 library/，再删
static func uninstall() -> Error:
	if not has_installed():
		return OK
	var keep_err := _keep_replaced_installed()
	if keep_err != OK:
		return keep_err
	var err := DirAccess.remove_absolute(_sub(INSTALLED))
	if FileAccess.file_exists(_sub(INSTALLED_THUMB)):
		DirAccess.remove_absolute(_sub(INSTALLED_THUMB))
	return err


## 被换下的 installed.json：库里没有同 sha 的副本时存进 library/，名字后加「（换下来的）」（3.1）
static func _keep_replaced_installed() -> Error:
	var shell := read_installed()
	var overlay: Variant = shell.get("overlay")
	if not overlay is Dictionary or (overlay as Dictionary).is_empty():
		return OK
	var sha := CustomMapSchema.sha256(overlay)
	for entry in list_library():
		if str(entry.get("sha256", "")) == sha:
			return OK
	var doc := (overlay as Dictionary).duplicate(true)
	doc["name"] = _suffixed_name(str(doc.get("name", "")), SUFFIX_REPLACED)
	var map_id := str(doc.get("map_id", ""))
	if not valid_map_id(map_id) or _map_id_in_use(map_id):
		doc["map_id"] = _fresh_map_id(map_id)
	var thumb := Image.load_from_file(_sub(INSTALLED_THUMB)) if FileAccess.file_exists(_sub(INSTALLED_THUMB)) else null
	return save_map(doc, thumb, false)


## 系统加的后缀也占地图名的 10 字额度，保全的副本仍须能重新导入。
static func _suffixed_name(name: String, suffix: String) -> String:
	return name.left(maxi(0, CustomMapValidator.MAP_NAME_MAX - suffix.length())) + suffix


# ---------------------------------------------------------------- 库

static func _lib_path(map_id: String) -> String:
	return _sub("library").path_join(map_id + ".json")


## 恢复/保全副本不能占用只有自动存档、尚未进库的地图 id。
static func _map_id_in_use(map_id: String) -> bool:
	return FileAccess.file_exists(_lib_path(map_id)) or FileAccess.file_exists(_sub("autosave").path_join(map_id + ".json"))


## 「我的地图」列表：[{map_id, name, sha256, updated_at, new_city_count, path, thumb}]，最近改过的在前
static func list_library() -> Array:
	var out: Array = []
	var dir := _sub("library")
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".json"):
			continue
		var doc: Variant = _read_json(dir.path_join(f))
		if not doc is Dictionary:
			continue
		var map_id := f.trim_suffix(".json")
		out.append({
			"map_id": map_id,
			"name": str(doc.get("name", "")),
			"sha256": CustomMapSchema.sha256(doc),
			"updated_at": str((doc.get("workshop", {}) as Dictionary).get("updated_at", "")) if doc.get("workshop") is Dictionary else "",
			"mtime": FileAccess.get_modified_time(dir.path_join(f)),
			"new_city_count": (doc.get("new_cities", []) as Array).size() if doc.get("new_cities") is Array else 0,
			"path": dir.path_join(f),
			"thumb": dir.path_join(map_id + ".png"),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["mtime"] > b["mtime"] if a["mtime"] != b["mtime"] else str(a["map_id"]) < str(b["map_id"]))
	return out


## 命名保存。已存在且不许覆盖时返回 ERR_ALREADY_EXISTS；覆盖前自动留 .bak（D5：要不要问由工坊决定，这里只管写）
static func save_map(doc: Dictionary, thumb: Image, allow_overwrite: bool) -> Error:
	last_save_warning = ""
	var map_id := str(doc.get("map_id", ""))
	if not valid_map_id(map_id):
		return ERR_INVALID_PARAMETER
	var path := _lib_path(map_id)
	if FileAccess.file_exists(path) and not allow_overwrite:
		return ERR_ALREADY_EXISTS
	if thumb != null and thumb.is_empty():
		return ERR_INVALID_PARAMETER
	var thumb_path := _sub("library").path_join(map_id + ".png")
	var pending := thumb_path + ".pending"
	var has_thumb := thumb != null and not thumb.is_empty()
	# 先准备缩略图，准备失败时不触碰库 JSON、旧图或自动稿。
	if has_thumb:
		var prepared := _write_thumb(pending, thumb)
		if prepared != OK:
			_remove_save_pending(pending)
			return prepared
	var captured := _capture_autosave(map_id)
	if int(captured.error) != OK:
		_remove_save_pending(pending)
		return int(captured.error) as Error
	# This identity commits in the SAME library JSON rename as the saved document.
	# workshop is excluded from the existing content SHA contract; caller stays untouched.
	var saved_doc := doc.duplicate(true)
	var metadata: Dictionary = saved_doc.get("workshop", {}).duplicate(true) if saved_doc.get("workshop") is Dictionary else {}
	metadata.erase("superseded_autosave")
	if not (captured.identity as Dictionary).is_empty():
		metadata["superseded_autosave"] = captured.identity
	saved_doc["workshop"] = metadata
	if FileAccess.file_exists(path):
		var old := FileAccess.get_file_as_bytes(path)
		var bak_err := _atomic(path + ".bak", old)
		if bak_err != OK:
			_remove_save_pending(pending)
			return bak_err
	var err := _write_json(path, saved_doc)
	if err != OK:
		_remove_save_pending(pending)
		return err
	# JSON 的原子 rename 是保存提交点。其后的附属失败不能冒充「未保存」。
	if has_thumb:
		err = DirAccess.rename_absolute(pending, thumb_path)
		if err != OK:
			last_save_warning = "地图已保存；缩略图未更新。"
		_remove_save_pending(pending)
	if clear_autosave(map_id) != OK:
		if last_save_warning != "":
			last_save_warning += " "
		last_save_warning += "地图已保存；自动稿还没能清理，已保留恢复入口。"
		var old_auto: Dictionary = captured.doc
		if not old_auto.is_empty() and CustomMapSchema.sha256(old_auto) != CustomMapSchema.sha256(doc):
			if trash_doc(old_auto, "unsaved") == OK:
				last_save_warning += " 旧稿已放进「扔掉的地图」，可手动拿回。"
			else:
				last_save_warning += " 旧稿未能放进「扔掉的地图」，磁盘自动稿仍保留。"
	return OK


static func _remove_save_pending(path: String) -> void:
	for temporary in [path, path + ".tmp"]:
		if FileAccess.file_exists(temporary):
			DirAccess.remove_absolute(temporary)


## Capture bytes and parsed content together; an unreadable existing draft aborts precommit.
static func _capture_autosave(map_id: String) -> Dictionary:
	var out := {"error": OK, "identity": {}, "doc": {}}
	var path := _sub("autosave").path_join(map_id + ".json")
	if not FileAccess.file_exists(path): return out
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		out.error = FileAccess.get_open_error(); return out
	var length := file.get_length()
	var raw := file.get_buffer(length)
	file.close()
	if raw.size() != length:
		out.error = ERR_FILE_CANT_READ; return out
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK or not json.data is Dictionary: return out # malformed drafts were never recoverable
	var draft: Dictionary = json.data
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256); hash.update(raw)
	var metadata: Dictionary = draft.get("workshop", {}) if draft.get("workshop") is Dictionary else {}
	out.identity = {"map_id": map_id, "generation": str(metadata.get("autosave_generation", "")),
		"file_sha256": hash.finish().hex_encode(), "content_sha256": CustomMapSchema.sha256(draft)}
	out.doc = draft
	return out


## Ignore only the precise draft superseded by the committed save, including legacy raw bytes.
static func is_superseded_autosave(map_id: String, draft: Dictionary, saved: Dictionary) -> bool:
	var metadata: Dictionary = saved.get("workshop", {}) if saved.get("workshop") is Dictionary else {}
	var identity: Dictionary = metadata.get("superseded_autosave", {}) if metadata.get("superseded_autosave") is Dictionary else {}
	if str(identity.get("map_id", "")) != map_id or str(draft.get("map_id", "")) != map_id: return false
	if str(identity.get("content_sha256", "")) != CustomMapSchema.sha256(draft): return false
	var draft_metadata: Dictionary = draft.get("workshop", {}) if draft.get("workshop") is Dictionary else {}
	if str(identity.get("generation", "")) != str(draft_metadata.get("autosave_generation", "")): return false
	var path := _sub("autosave").path_join(map_id + ".json")
	return FileAccess.file_exists(path) and str(identity.get("file_sha256", "")) == FileAccess.get_sha256(path)


## 读库里的一张图；没有或坏了返回 {}
static func load_map(map_id: String) -> Dictionary:
	if not valid_map_id(map_id):
		return {}
	var v: Variant = _read_json(_lib_path(map_id))
	return v if v is Dictionary else {}


## 把库里的一张图扔进回收站（先写进 trash/，再删库里的文件）
static func trash_map(map_id: String) -> Error:
	var doc := load_map(map_id)
	if doc.is_empty():
		return ERR_FILE_NOT_FOUND
	var err := trash_doc(doc, "thrown")
	if err != OK:
		return err
	var autosaved := read_autosave(map_id)
	if not autosaved.is_empty() and CustomMapSchema.sha256(autosaved) != CustomMapSchema.sha256(doc):
		err = trash_doc(autosaved, "unsaved")
		if err != OK:
			return err
	err = clear_autosave(map_id)
	if err != OK:
		return err
	for f in [_lib_path(map_id), _lib_path(map_id) + ".bak", _sub("library").path_join(map_id + ".png")]:
		if FileAccess.file_exists(f):
			err = DirAccess.remove_absolute(f)
			if err != OK:
				return err
	return OK


# ---------------------------------------------------------------- 回收站

## 把一份文档放进回收站；kind: "thrown"（扔掉的）/ "unsaved"（没保存的改动）/ "replaced"（另存为时换掉的旧图）。
## 按 map_id + sha 去重（同一份内容只留一份，时间更新成这次）；只留最近 40 份
static func trash_doc(doc: Dictionary, kind: String) -> Error:
	if not kind in TRASH_KINDS:
		return ERR_INVALID_PARAMETER
	var map_id := str(doc.get("map_id", ""))
	if not valid_map_id(map_id):
		map_id = "m_unnamed"
	var sha := CustomMapSchema.sha256(doc)
	var path := _sub("trash").path_join("%s.%s.json" % [map_id, sha.left(8)])
	var err := _write_json(path, {"schema": TRASH_SCHEMA, "kind": kind, "trashed_at": _now(), "sha256": sha, "doc": doc})
	if err != OK:
		return err
	var entries := list_trash()
	for i in range(TRASH_KEEP, entries.size()):
		DirAccess.remove_absolute(str(entries[i]["path"]))
	return OK


## 「扔掉的地图」列表：[{entry_id, map_id, name, kind, trashed_at, sha256, path}]，最近的在前（最多 40 份）
static func list_trash() -> Array:
	var out: Array = []
	var dir := _sub("trash")
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".json"):
			continue
		var w: Variant = _read_json(dir.path_join(f))
		if not w is Dictionary or str(w.get("schema", "")) != TRASH_SCHEMA or not w.get("doc") is Dictionary:
			continue
		out.append({
			"entry_id": f.trim_suffix(".json"),
			"map_id": str((w["doc"] as Dictionary).get("map_id", "")),
			"name": str((w["doc"] as Dictionary).get("name", "")),
			"kind": str(w.get("kind", "")),
			"trashed_at": str(w.get("trashed_at", "")),
			"sha256": str(w.get("sha256", "")),
			"path": dir.path_join(f),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["trashed_at"] > b["trashed_at"] if a["trashed_at"] != b["trashed_at"] else a["entry_id"] < b["entry_id"])
	return out


## 从回收站放回 library；map_id 已被占用就换一个新的，名字后加「（拿回来的）」。内容逐字节不变（除了换 id、改名这两种情况）
static func restore_from_trash(entry_id: String) -> Error:
	if entry_id.contains("/") or entry_id.contains("\\") or entry_id.contains(".."):
		return ERR_INVALID_PARAMETER
	var path := _sub("trash").path_join(entry_id + ".json")
	var w: Variant = _read_json(path)
	if not w is Dictionary or not w.get("doc") is Dictionary:
		return ERR_FILE_NOT_FOUND
	var doc: Dictionary = (w["doc"] as Dictionary).duplicate(true)
	var map_id := str(doc.get("map_id", ""))
	if not valid_map_id(map_id) or _map_id_in_use(map_id):
		doc["map_id"] = _fresh_map_id(map_id)
		doc["name"] = _suffixed_name(str(doc.get("name", "")), SUFFIX_RESTORED)
	var err := save_map(doc, null, false)
	if err != OK:
		return err
	return DirAccess.remove_absolute(path)


static func _fresh_map_id(old: String) -> String:
	var stem := old if valid_map_id(old) else "m_map"
	stem = stem.left(56)
	for i in range(2, 1000):
		var id := "%s_%d" % [stem, i]
		if not _map_id_in_use(id):
			return id
	return "%s_%d" % [stem, Time.get_ticks_msec()]


# ---------------------------------------------------------------- 自动存档

## autosave/<map_id>.json（每张图一份，互不覆盖）
static func write_autosave(doc: Dictionary) -> Error:
	var map_id := str(doc.get("map_id", ""))
	if not valid_map_id(map_id):
		return ERR_INVALID_PARAMETER
	var draft := doc.duplicate(true)
	var metadata: Dictionary = draft.get("workshop", {}).duplicate(true) if draft.get("workshop") is Dictionary else {}
	metadata.erase("superseded_autosave")
	metadata["autosave_generation"] = Crypto.new().generate_random_bytes(16).hex_encode()
	draft["workshop"] = metadata
	return _write_json(_sub("autosave").path_join(map_id + ".json"), draft)


static func read_autosave(map_id: String) -> Dictionary:
	if not valid_map_id(map_id):
		return {}
	var v: Variant = _read_json(_sub("autosave").path_join(map_id + ".json"))
	return v if v is Dictionary else {}


## 仅在新版本已经保存，或当前修改已经进回收站后调用；不会替代丢弃前的保全。
static func clear_autosave(map_id: String) -> Error:
	if not valid_map_id(map_id):
		return ERR_INVALID_PARAMETER
	var path := _sub("autosave").path_join(map_id + ".json")
	return DirAccess.remove_absolute(path) if FileAccess.file_exists(path) else OK


## [{map_id, name, sha256, saved_sha256, path}]：saved_sha256 是库里同 map_id 那一份的 sha（没保存过为 ""），
## 工坊据此决定启动时要不要问「上次没保存的……还在」（比较内容 sha，不比时间，3.12.11）
static func list_autosaves() -> Array:
	var out: Array = []
	var dir := _sub("autosave")
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".json"):
			continue
		var doc: Variant = _read_json(dir.path_join(f))
		if not doc is Dictionary:
			continue
		var map_id := f.trim_suffix(".json")
		var saved := load_map(map_id)
		out.append({
			"map_id": map_id,
			"name": str(doc.get("name", "")),
			"sha256": CustomMapSchema.sha256(doc),
			"saved_sha256": CustomMapSchema.sha256(saved) if not saved.is_empty() else "",
			"path": dir.path_join(f),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["map_id"]) < str(b["map_id"]))
	return out


## 删掉一张图的自动存档（先挪进回收站算「没保存的改动」，3.12.11【不要了】）
static func discard_autosave(map_id: String) -> Error:
	var doc := read_autosave(map_id)
	if doc.is_empty():
		return OK
	var err := trash_doc(doc, "unsaved")
	if err != OK:
		return err
	return clear_autosave(map_id)
