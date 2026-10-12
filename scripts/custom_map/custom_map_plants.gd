class_name CustomMapPlants
extends RefCounted

## v2 单株覆盖；yaw 是弧度，scale 是原库归一化模型的统一倍率。不接受文件路径。
const SCHEMA := "lshu.custom_map.v2"
const DIRECTORY := "res://assets/merchant_board_claude/trees/"
const HASHES := {
	"tree_pine": "17b181d09de890dc9fd5f9612b3e22d231eb43d64641d49dbcfd11c5d59afed3",
	"tree_pine_tall": "f7eb3542c5a0e1401445eaf63c0467397d9874f72b4ceb43cecfba21bc5dcf31",
	"tree_round": "c33d06d116269f152538c91a7d2e832739227def08b13fb9118af45ca2105a84",
	"bush": "44ea53d102818d038dbe2adee08dcbc19e2eb6b803d7bb0aea57c7b90aa3f994",
}
const NAMES := {"tree_pine": "松树", "tree_pine_tall": "高松树", "tree_round": "圆冠树", "bush": "灌木"}
const MAX_NEW := 256
const MAX_RECORDS := 1024
const MIN_SCALE := 0.5
const MAX_SCALE := 2.0
const MAX_SLOPE := 0.35
static var _bounds := {}

static func dependencies_error(layer: Dictionary, directory := DIRECTORY) -> String:
	var refs: Variant = layer.get("builtin_sha256")
	if not refs is Dictionary or refs.size() != HASHES.size(): return "植物资源清单必须包含四种内置植物"
	for asset: String in HASHES:
		if refs.get(asset) != HASHES[asset]: return "植物资源指纹不匹配：" + asset
		var path := directory.path_join(asset + ".glb")
		if not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != HASHES[asset]:
			return "缺少植物资源或文件已改变：" + asset
	return ""

static func error(layer: Variant) -> String:
	if not layer is Dictionary: return "plants 不是对象"
	for key in layer:
		if key not in ["version", "builtin_sha256", "instances"]: return "plants 有未知字段"
	if not CustomMapLandscape._number(layer.get("version")) or float(layer.version) != 1.0: return "plants.version 必须为 1"
	if not layer.get("instances") is Dictionary or layer.instances.size() > MAX_RECORDS: return "植物覆盖最多 %d 条（包含已隐藏）" % MAX_RECORDS
	var count := 0
	for id in layer.instances:
		if not id is String or not valid_id(id): return "植物 ID 不认识"
		if id.begins_with("new:"): count += 1
		var row: Variant = layer.instances[id]
		if not row is Dictionary: return "植物记录不是对象"
		for key in row:
			if key not in ["asset", "x", "z", "yaw", "scale", "hidden"]: return "植物记录有未知字段"
		if row.get("asset") not in HASHES or not row.get("hidden") is bool: return "植物类型或隐藏状态不对"
		for key in ["x", "z", "yaw", "scale"]:
			if not CustomMapLandscape._number(row.get(key)): return "植物坐标、朝向和倍率必须是有限数"
		if row.x < 0.0 or row.x > CustomMapLandscape.MAX_X or row.z < 0.0 or row.z > CustomMapLandscape.MAX_Z: return "植物超出棋盘"
		if row.scale < MIN_SCALE or row.scale > MAX_SCALE: return "植物大小应在 0.5–2.0 之间（隐藏记录也计入）"
		if row.yaw < -PI or row.yaw > TAU: return "植物朝向超出范围（弧度）"
	if count > MAX_NEW: return "新增植物最多 %d 株（包含已隐藏）" % MAX_NEW
	return ""

static func valid_id(id: String) -> bool:
	var parts := id.split(":")
	if parts.size() == 3 and parts[0] == "base" and parts[1] == "tree_kit": return parts[2].is_valid_int() and int(parts[2]) >= 0 and str(int(parts[2])) == parts[2]
	if parts.size() == 3 and parts[0] == "brush": return parts[1].is_valid_int() and parts[2].is_valid_int() and int(parts[1]) >= 0 and int(parts[2]) in range(7)
	if parts.size() == 2 and parts[0] == "new":
		var regex := RegEx.new(); regex.compile("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
		return regex.search(parts[1]) != null
	return false

static func new_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16); bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128
	var h := bytes.hex_encode()
	return "new:%s-%s-%s-%s-%s" % [h.substr(0,8),h.substr(8,4),h.substr(12,4),h.substr(16,4),h.substr(20,12)]

static func layer() -> Dictionary:
	return {"version": 1, "builtin_sha256": HASHES.duplicate(), "instances": {}}

static func bounds(asset: String) -> AABB:
	if _bounds.has(asset): return _bounds[asset]
	if asset not in HASHES or FileAccess.get_sha256(DIRECTORY.path_join(asset + ".glb")) != HASHES[asset]: return AABB()
	var document := GLTFDocument.new(); var state := GLTFState.new()
	if document.append_from_file(DIRECTORY.path_join(asset + ".glb"), state) != OK: return AABB()
	var scene := document.generate_scene(state)
	if scene == null: return AABB()
	var found: Array = []; _collect_bounds(scene, Transform3D.IDENTITY, found)
	var result := AABB()
	for box: AABB in found: result = box if result.size == Vector3.ZERO else result.merge(box)
	scene.free(); _bounds[asset] = result
	return result

static func _collect_bounds(node: Node, parent: Transform3D, found: Array) -> void:
	var xf: Transform3D = parent * node.transform if node is Node3D else parent
	if node is MeshInstance3D and node.mesh != null: found.append(xf * node.mesh.get_aabb())
	for child in node.get_children(): _collect_bounds(child, xf, found)

## IDs derived before brushes run. Each accepted brush sample marks its own stable identity.
static func decorate(layout: Dictionary, doc: Dictionary, geo: CustomMapGeo) -> String:
	var rows: Array = layout.get("tree_kit", []).duplicate(true)
	var ids: Array[String] = []
	for i in rows.size(): ids.append(str(rows[i].get("plant_id", "base:tree_kit:%d" % i)))
	var records: Dictionary = doc.plants.instances
	for id: String in records:
		if not id.begins_with("new:") and not ids.has(id): return "找不到植物：" + id
	var new_ids: Array = records.keys().filter(func(id): return str(id).begins_with("new:")); new_ids.sort()
	for id: String in new_ids: ids.append(id); rows.append({})
	for i in rows.size():
		var id := ids[i]
		if not records.has(id): continue # Original plants keep their exact original y and transform.
		var r: Dictionary = records[id]
		rows[i] = {"asset": r.asset, "x": r.x, "z": r.z, "y": geo.height(float(r.x), float(r.z)) - bounds(str(r.asset)).position.y * float(r.scale), "yaw": r.yaw, "s": 0.0 if r.hidden else r.scale}
		# Explicit overrides are not hidden by original-row clearance at the previous position.
		var cleared: Array = layout.get("decor_cleared", {}).get("tree_kit", [])
		cleared.erase(i)
	layout["tree_kit"] = rows; layout["plant_ids"] = ids; layout["plants"] = doc.plants.duplicate(true)
	return ""

static func record(row: Dictionary) -> Dictionary:
	return {"asset": row.asset, "x": row.x, "z": row.z, "yaw": row.yaw, "scale": row.s, "hidden": float(row.s) <= 0.0}

static func placement_error(layout: Dictionary, row: Dictionary, geo: CustomMapGeo) -> String:
	if row.hidden: return ""
	var box := bounds(str(row.asset))
	if box.size == Vector3.ZERO: return "植物资源没有实际网格"
	var xf := Transform3D(Basis(Vector3.UP, float(row.yaw)).scaled(Vector3.ONE * float(row.scale)), Vector3(float(row.x), 0, float(row.z)))
	var corners: Array[Vector2] = []
	for sx in [box.position.x, box.end.x]:
		for sz in [box.position.z, box.end.z]:
			var q := xf * Vector3(sx, 0, sz); corners.append(Vector2(q.x, q.z))
	var radius := 0.0
	var center := Vector2(float(row.x), float(row.z))
	for q in corners: radius = maxf(radius, q.distance_to(center))
	var h := geo.height(center.x, center.y)
	var samples: Array[Vector2] = [center]
	var steps_x := maxi(1, int(ceil(box.size.x * float(row.scale) / 0.25)))
	var steps_z := maxi(1, int(ceil(box.size.z * float(row.scale) / 0.25)))
	for ix in range(steps_x + 1):
		for iz in range(steps_z + 1):
			var q := xf * Vector3(lerpf(box.position.x, box.end.x, float(ix) / steps_x), 0.0, lerpf(box.position.z, box.end.z, float(iz) / steps_z))
			samples.append(Vector2(q.x, q.z))
	for q in samples:
		if not geo.board.has_point(q) or not geo.is_land(q.x, q.y): return "整株植物要放在陆地上，不能跨海岸"
		if absf(geo.height(q.x, q.y) - h) > MAX_SLOPE: return "这里太陡，植物站不稳"
	for city: Dictionary in layout.get("cities", []):
		if Vector2(float(city.x), float(city.z)).distance_to(center) < float(city.foot) * 0.75 + radius + 0.5: return "植物离城市太近，会挡住操作"
	var geos: Array = []
	for route: Dictionary in layout.get("routes", []): geos.append(CustomMapGeoRules._route_geo(route))
	if CustomBoardLayout._near_routes(geos, center, radius + 1.1): return "植物离商路太近，会挡住操作"
	for stop: Dictionary in layout.get("stops", []):
		if Vector2(float(stop.x), float(stop.z)).distance_to(center) < radius + 1.0: return "植物离停靠点太近"
	return ""

static func check(layout: Dictionary, doc: Dictionary, geo: CustomMapGeo) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	for id: String in doc.plants.instances:
		var problem := placement_error(layout, doc.plants.instances[id], geo)
		if problem != "": issues.append({"code": "G_PLANT", "target": "plants." + id, "kid": problem, "tech": problem})
	return issues
