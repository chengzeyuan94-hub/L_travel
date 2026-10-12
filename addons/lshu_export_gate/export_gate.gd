@tool
extends EditorExportPlugin
## 导出门禁（2026-09-30 安卓压力测试 PAD-MAR-1）。
## generated/（tools/traveler/build_atlas_scene.gd 烘出来的长安地图 generated/traveler/atlas/atlas_world.tscn 等）被 .gitignore
## 挡在版本库外，worktree、新 clone 里没有它。以前从这样的检出导出，Godot 只打一行「Cannot open file」照样出包，
## 包里的长安一进去就永远卡在「L叔在收拾行李…」。
## 这里在导出开始时查旅人模式每一幕的场景和它直接引用的资源（和 scripts/lshu_ui/lshu_progress.gd missing_deps 同一个查法）：
## 缺了就报错（编辑器导出窗口、命令行都能看到），并在导出写完后把刚出的包删掉——宁可没有包，也不要一个坏包。
## Godot 的导出插件拦不住导出本身（试过：报错、选项警告都照样出包、退出码 0），所以用「写完就删」；
## tools/导出*安装包.command 在导出前也先查一遍，缺了直接不导。
## 旅人模式的幕不在包里（导出过滤掉了场景本身）也算缺。
## 地图工坊（2026-10-01，docs/design/map-editor-20260930/DESIGN.md 3.6、3.12.1、3.13.6）分流：
##   - 特性里有 lshu_map_workshop（工坊的两个预设）：跳过旅人模式检查（工坊的包本来就排除了旅人模式的素材）；
##   - 桌面预设（macOS / Windows，游戏和工坊都算）：加查自制地图素材目录 data/custom_map/catalogue_v1.json 的完整性——
##     目录文件以及每个 shipped 条目引用的模型、卡图、缩略图、图标都要在；
##   - 缺东西时的处理和旅人模式一样：报错，导出写完后把包删掉。安卓预设不查目录（安卓不读自制地图，素材也被排除了）。

const Progress := preload("res://scripts/lshu_ui/lshu_progress.gd")
const WORKSHOP_FEATURE := "lshu_map_workshop"
const CATALOGUE := "res://data/custom_map/catalogue_v1.json"

var _drop_paths: PackedStringArray = []


func _get_name() -> String:
	return "LshuExportGate"


## 旅人模式各幕缺的东西（场景 + 直接引用的资源）；空 = 齐全
static func missing() -> PackedStringArray:
	return missing_for_acts(Progress.ACTS)


## 与正式门禁共用的检查器；单元测试用隔离的小场景验证，不要求检出里已烘焙完整旅人地图。
static func missing_for_acts(acts: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for a: Dictionary in acts:
		var scene := str(a.get("scene", ""))
		if scene == "" or not ResourceLoader.exists(scene):
			out.append(scene)
			continue
		for dep: String in ResourceLoader.get_dependencies(scene):
			var p := dep.get_slice("::", dep.get_slice_count("::") - 1) if dep.contains("::") else dep
			if p.begins_with("res://") and not ResourceLoader.exists(p) and not out.has(p):
				out.append(p)
		for r: String in a.get("requires", []):
			if not ResourceLoader.exists(r) and not out.has(r):
				out.append(r)
	return out


## 自制地图素材目录里 shipped 条目缺的文件；空 = 齐全。目录缺失也拒绝：桌面游戏与工坊都已依赖它。
static func catalogue_missing(catalogue_path := CATALOGUE) -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(catalogue_path):
		out.append(catalogue_path + "（目录文件不存在）")
		return out
	var json := JSON.new()
	var parsed := json.parse(FileAccess.get_file_as_string(catalogue_path))
	var d: Variant = json.data
	if parsed != OK or not (d is Dictionary):
		out.append(catalogue_path + "（读不出来）")
		return out
	var fields := {"archetypes": ["model", "card_art", "thumb"], "specialties": ["icon"]}
	for group: String in fields:
		var entries: Variant = (d as Dictionary).get(group)
		if not entries is Array:
			out.append("%s.%s（应为数组）" % [catalogue_path, group])
			continue
		for e in entries:
			if not e is Dictionary:
				out.append("%s.%s（条目应为对象）" % [catalogue_path, group])
				continue
			if str(e.get("status", "")) != "shipped":
				continue
			for f: String in fields[group]:
				var p := str(e.get(f, ""))
				if p == "" or not (FileAccess.file_exists(p) or ResourceLoader.exists(p)):
					var tag := "%s.%s.%s" % [group, str(e.get("id", e.get("key", "?"))), f]
					out.append("%s=%s" % [tag, p] if p != "" else tag)
			# 双交通原型可能默认卡图齐全，但海路专用卡丢了；不能让这份目录通过门禁。
			if group == "archetypes" and e.has("card_art_by_route"):
				var variants: Variant = e["card_art_by_route"]
				var tag := "archetypes.%s.card_art_by_route" % str(e.get("id", "?"))
				if not variants is Dictionary:
					out.append(tag + "（应为对象）")
					continue
				var fits: Variant = e.get("fits", [])
				if not fits is Array:
					out.append("archetypes.%s.fits（应为数组）" % str(e.get("id", "?")))
					continue
				var routes: Array = variants.keys()
				for route in fits:
					if not routes.has(route):
						routes.append(route)
				for route in routes:
					var p := str(variants.get(route, ""))
					if p == "" or not (FileAccess.file_exists(p) or ResourceLoader.exists(p)):
						out.append("%s.%s=%s" % [tag, str(route), p])
	return out


## 桌面预设：macOS / Windows（安卓不读自制地图）
static func is_desktop(features: PackedStringArray) -> bool:
	return features.has("macos") or features.has("windows") or (features.has("pc") and not features.has("android"))


func _export_begin(features: PackedStringArray, _is_debug: bool, path: String, _flags: int) -> void:
	_drop_paths = PackedStringArray()
	var msgs := PackedStringArray()
	if features.has(WORKSHOP_FEATURE):
		print("LSHU_EXPORT_GATE map workshop: 跳过旅人模式检查")
	else:
		var miss := missing()
		if not miss.is_empty():
			msgs.append("旅人模式要用的东西不在这个检出里，导出的包会坏（长安进不去）。先把 generated/traveler/atlas 放进来（从正式检出拷，或用 tools/traveler/build_atlas_scene.gd 重烘）再导出。缺：%s" % ", ".join(miss))
	if is_desktop(features):
		var cat := catalogue_missing()
		if not cat.is_empty():
			msgs.append("自制地图素材目录里标了 shipped 的素材不在这个检出里（DESIGN 3.13.6），导出的包里新城会没有样子。先补齐素材、重跑 tools/custom_map/build_catalogue.gd 再导出。缺：%s" % ", ".join(cat))
		# Godot exports imported GLBs as scenes; include_filter does not preserve
		# their original bytes. Runtime fingerprint/preflight/import needs those bytes.
		for source: String in raw_piece_sources():
			var bytes := FileAccess.get_file_as_bytes(source)
			if bytes.is_empty(): msgs.append("棋子原始资源缺失：" + source)
			else: add_file(source, bytes, false)
	if msgs.is_empty():
		print("LSHU_EXPORT_GATE ok")
		return
	var msg := "\n".join(msgs)
	push_error("LSHU_EXPORT_GATE " + msg)
	var platform := get_export_platform()
	if platform != null:
		platform.add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "旅行L叔导出门禁", msg)
	_drop_paths = export_artifact_paths(path)


static func raw_piece_sources() -> PackedStringArray:
	var sources := PackedStringArray()
	for transport in ["CAMEL", "SHIP"]:
		for item: Dictionary in CustomMapPiecePresets.items(transport):
			var source := CustomMapPiecePresets.model(str(item.id))
			if not sources.has(source): sources.append(source)
	# Frozen legacy identities and shipped portable-map dependencies remain readable.
	for source in ["res://assets/piece_presets/lshu_defaults/67ad4054a876ca46b0885221ef33348ef096b315d0a468d3c90ecae2a1f829c6.glb", "res://assets/merchant_board_claude/player/player_boat.glb"]:
		if not sources.has(source): sources.append(source)
	for bundle in ["lshu_defaults_bundle"]:
		var root: String = "res://data/custom_map/" + str(bundle) + "/assets"
		if not DirAccess.dir_exists_absolute(root): continue
		for filename: String in DirAccess.get_files_at(root):
			if filename.get_extension() in ["glb", "png", "jpg"]:
				var source: String = root.path_join(filename)
				if not sources.has(source): sources.append(source)
	return sources


static func export_artifact_paths(path: String, project_dir := "") -> PackedStringArray:
	# Godot 的相对导出路径只相对于 project.godot；不能额外猜测启动 cwd 下的同名文件。
	# https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html
	if path.is_empty():
		return PackedStringArray()
	if project_dir.is_empty():
		project_dir = ProjectSettings.globalize_path("res://")
	var target := path if path.is_absolute_path() else project_dir.path_join(path)
	target = ProjectSettings.globalize_path(target).simplify_path()
	var out := PackedStringArray()
	for p: String in [target, target.get_basename() + ".pck", target + ".idsig"]:
		if not out.has(p):
			out.append(p)
	return out


func _export_end() -> void:
	var cleanup_failed := false
	for p: String in _drop_paths:
		var err := remove_export_artifact(p)
		print("LSHU_EXPORT_GATE cleanup ", p, " err=", err)
		if err != OK:
			cleanup_failed = true
			push_error("LSHU_EXPORT_GATE 无法删除拒绝导出的产物：%s（%s）" % [p, error_string(err)])
	if not _drop_paths.is_empty():
		if cleanup_failed:
			push_error("LSHU_EXPORT_GATE 这次导出已被拒绝，但部分产物无法删除；禁止分发，见上面的路径与错误。")
		else:
			push_error("LSHU_EXPORT_GATE 这次导出的包已删除（缺东西，见上面）")
	_drop_paths = PackedStringArray()


static func remove_export_artifact(path: String) -> Error:
	# 只移除传入的导出目标。应用内的链接（例如框架链接）只删链接本身，绝不遍历其目标。
	var parent := DirAccess.open(path.get_base_dir())
	if parent != null and parent.is_link(path.get_file()):
		return DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute(path):
		if path.get_extension().to_lower() != "app":
			return ERR_INVALID_PARAMETER
		return _remove_bundle_tree(path)
	if FileAccess.file_exists(path):
		return DirAccess.remove_absolute(path)
	return OK


static func _remove_bundle_tree(path: String) -> Error:
	var dir := DirAccess.open(path)
	if dir == null:
		return DirAccess.get_open_error()
	dir.include_hidden = true
	var first_error: Error = OK
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := path.path_join(name)
			var err := _remove_bundle_tree(child) if dir.current_is_dir() and not dir.is_link(name) else DirAccess.remove_absolute(child)
			if err != OK and first_error == OK:
				first_error = err
		name = dir.get_next()
	dir.list_dir_end()
	return DirAccess.remove_absolute(path) if first_error == OK else first_error
