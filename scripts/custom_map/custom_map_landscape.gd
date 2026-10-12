class_name CustomMapLandscape
extends RefCounted

## 可选、可撤销的地形/树林笔刷层。只改变画面与几何，不改海岸、规则拓扑或经济。
## 旧图不带此字段，整个基础布局仍原样返回。全部编辑随地图保存、校验、指纹及安装。
const MAX_EDITS := 256
const MIN_RADIUS := 1.0
const MAX_RADIUS := 8.0
const INDEX_CELL := 8.0
const OPS := ["flatten", "clear_trees", "plant_trees"]
const MAX_X := 128.0
const MAX_Z := 59.63125

static func error(layer: Variant) -> String:
	if not layer is Dictionary:
		return "landscape 不是对象"
	for key in layer:
		if key not in ["version", "edits"]:
			return "landscape 有未知字段"
	if not _number(layer.get("version")) or float(layer.version) != 1.0:
		return "landscape.version 必须为 1"
	if not layer.get("edits") is Array or layer.edits.size() > MAX_EDITS:
		return "地形笔刷最多 %d 笔" % MAX_EDITS
	for edit in layer.edits:
		if not edit is Dictionary or not edit.get("op") is String or edit.op not in OPS:
			return "地形笔刷类型不认识"
		for key in edit:
			if key not in (["op", "x", "z", "radius", "height"] if edit.op == "flatten" else ["op", "x", "z", "radius"]):
				return "地形笔刷有未知字段"
		for key in ["x", "z", "radius"]:
			if not _number(edit.get(key)):
				return "地形笔刷坐标或半径不是有限数"
		if float(edit.x) < 0.0 or float(edit.x) > MAX_X or float(edit.z) < 0.0 or float(edit.z) > MAX_Z:
			return "地形笔刷超出棋盘"
		if float(edit.radius) < MIN_RADIUS or float(edit.radius) > MAX_RADIUS:
			return "地形笔刷半径应在 1–8 之间"
		if edit.op == "flatten" and (not _number(edit.get("height")) or float(edit.height) < 0.1 or float(edit.height) > 8.0):
			return "平整高度应在 0.1–8 之间"
	return ""

static func _number(value: Variant) -> bool:
	return value is int or (value is float and is_finite(value))

static func apply_edit(doc: Dictionary, op: String, at: Vector2, radius := 4.0) -> Dictionary:
	if op not in OPS or not is_finite(at.x) or not is_finite(at.y) or not is_finite(radius):
		return {"ok": false, "message": "笔刷数据不对"}
	var layer: Variant = doc.get("landscape", {"version": 1, "edits": []})
	var bad := error(layer)
	if bad != "":
		return {"ok": false, "message": bad}
	var edit := {"op": op, "x": snappedf(at.x, 0.001), "z": snappedf(at.y, 0.001), "radius": snappedf(radius, 0.001)}
	if op == "flatten":
		var geo := CustomMapGeo.for_overlay(doc)
		if not geo.is_land(at.x, at.y):
			return {"ok": false, "message": "只能平整陆地，海岸会保留"}
		edit["height"] = snappedf(clampf(geo.height(at.x, at.y), 0.1, 8.0), 0.001)
	var trial := {"version": 1, "edits": [edit]}
	bad = error(trial)
	if bad != "":
		return {"ok": false, "message": bad}
	var out := doc.duplicate(true)
	var next: Dictionary = layer.duplicate(true)
	var edits: Array = next.edits
	# 同一操作、半径、极近中心不重复消耗预算；更早的笔刷不合并，保留删树→种树的时间顺序。
	if not edits.is_empty():
		var last: Dictionary = edits.back()
		if last.op == op and is_equal_approx(float(last.radius), radius) and Vector2(float(last.x), float(last.z)).distance_to(at) < radius * 0.2:
			return {"ok": true, "doc": out, "message": "", "changed": false}
	if edits.size() >= MAX_EDITS:
		return {"ok": false, "message": "地形笔刷已满（最多 %d 笔），请撤销一些改动" % MAX_EDITS}
	edits.append(edit)
	out["landscape"] = next
	return {"ok": true, "doc": out, "message": "", "changed": true}

static func build_index(layer: Dictionary) -> Dictionary:
	var index := {}
	for edit: Dictionary in layer.get("edits", []):
		if edit.op != "flatten":
			continue
		var r := float(edit.radius)
		for x in range(int(floor((float(edit.x) - r) / INDEX_CELL)), int(floor((float(edit.x) + r) / INDEX_CELL)) + 1):
			for z in range(int(floor((float(edit.z) - r) / INDEX_CELL)), int(floor((float(edit.z) + r) / INDEX_CELL)) + 1):
				var key := Vector2i(x, z)
				if not index.has(key):
					index[key] = []
				index[key].append(edit)
	return index

static func height_at(base_height: float, x: float, z: float, index: Dictionary) -> float:
	var h := base_height
	for edit: Dictionary in index.get(Vector2i(int(floor(x / INDEX_CELL)), int(floor(z / INDEX_CELL))), []):
		var fraction := Vector2(x - float(edit.x), z - float(edit.z)).length() / float(edit.radius)
		if fraction >= 1.0:
			continue
		var weight := 1.0 - smoothstep(0.75, 1.0, fraction)
		h = lerpf(h, float(edit.height), weight)
	return h

static func affects_height(x: float, z: float, index: Dictionary) -> bool:
	for edit: Dictionary in index.get(Vector2i(int(floor(x / INDEX_CELL)), int(floor(z / INDEX_CELL))), []):
		if Vector2(x - float(edit.x), z - float(edit.z)).length() < float(edit.radius):
			return true
	return false

## 保持已有 kit/tree 下标稳定。删除用 s=0，新增树追加，恢复/撤销从基础布局重新推导。
static func decorate(layout: Dictionary, layer: Dictionary, geo: CustomMapGeo, stable_ids := false) -> void:
	for key in ["kit", "tree_kit", "props"]:
		layout[key] = (layout.get(key, []) as Array).duplicate(true)
	var route_geos: Array = []
	for route: Dictionary in layout.get("routes", []):
		route_geos.append(CustomMapGeoRules._route_geo(route))
	for edit_index in layer.edits.size():
		var edit: Dictionary = layer.edits[edit_index]
		var p := Vector2(float(edit.x), float(edit.z))
		var r := float(edit.radius)
		if edit.op in ["flatten", "clear_trees"]:
			for row: Dictionary in layout.tree_kit:
				if Vector2(float(row.x), float(row.z)).distance_to(p) <= r:
					row.s = 0.0
			for row: Dictionary in layout.kit:
				var forest := String(row.asset).begins_with("forest")
				if (forest or edit.op == "flatten") and Vector2(float(row.x), float(row.z)).distance_to(p) <= r:
					row.s = 0.0
			if edit.op == "flatten":
				for row: Dictionary in layout.props:
					if Vector2(float(row.x), float(row.z)).distance_to(p) <= r:
						row.s = 0.0
		elif edit.op == "plant_trees":
			# 稳定七点，避开城市/商路；同一地图每次读取树木位置一致，不动对局 RNG。
			for i in 7:
				var theta := TAU * float(i) / 6.0
				var q := p if i == 6 else p + Vector2(cos(theta), sin(theta)) * r * 0.6
				if q.x < 0.0 or q.x > MAX_X or q.y < 0.0 or q.y > MAX_Z or not geo.is_land(q.x, q.y) or _occupied(layout, q, route_geos):
					continue
				var close := false
				for row: Dictionary in layout.tree_kit:
					if float(row.s) > 0.0 and Vector2(float(row.x), float(row.z)).distance_to(q) < 0.8:
						close = true
						break
				if not close:
					var row := {"asset": "tree_pine" if i % 2 == 0 else "tree_pine_tall", "x": q.x, "z": q.y, "y": geo.height(q.x, q.y), "s": 1.05 + (i % 3) * 0.1, "yaw": theta}
					if stable_ids: row["plant_id"] = "brush:%d:%d" % [edit_index, i]
					layout.tree_kit.append(row)
	# 未删除的装饰跟随地面，避免平整边缘浮树。
	for key in ["kit", "tree_kit", "props"]:
		for row: Dictionary in layout[key]:
			if geo.has_height_edit(float(row.x), float(row.z)):
				row.y = geo.edited_height(float(row.y), float(row.x), float(row.z))

static func _occupied(layout: Dictionary, p: Vector2, route_geos: Array) -> bool:
	for c: Dictionary in layout.get("cities", []):
		if Vector2(float(c.x), float(c.z)).distance_to(p) < float(c.foot) * 0.75 + 0.5:
			return true
	return CustomBoardLayout._near_routes(route_geos, p, 1.1)

## 从共享导入网格复制一次，仅改命中的顶点；不写 .glb/原始资源，旧图零开销。
static func deform_mesh(mesh: Mesh, transform: Transform3D, geo: CustomMapGeo) -> Mesh:
	if mesh == null or not geo.has_height_edits():
		return mesh
	var out := ArrayMesh.new()
	var inverse := transform.affine_inverse()
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var changed := false
		for i in vertices.size():
			var world := transform * vertices[i]
			if not geo.has_height_edit(world.x, world.z) or not geo.is_land(world.x, world.z):
				continue
			# 只改地面顶层，底面及海岸竖壁保留；顶点的原始高度作为边缘过渡输入。
			if world.y < 0.05:
				continue
			world.y = geo.edited_height(world.y, world.x, world.z)
			vertices[i] = inverse * world
			changed = true
		arrays[Mesh.ARRAY_VERTEX] = vertices
		var one := ArrayMesh.new()
		one.add_surface_from_arrays(mesh.surface_get_primitive_type(surface), arrays)
		if changed and mesh.surface_get_primitive_type(surface) == Mesh.PRIMITIVE_TRIANGLES:
			var surface_tool := SurfaceTool.new()
			surface_tool.create_from(one, 0)
			surface_tool.generate_normals()
			surface_tool.commit(out)
		else:
			out.add_surface_from_arrays(mesh.surface_get_primitive_type(surface), arrays)
		out.surface_set_material(out.get_surface_count() - 1, mesh.surface_get_material(surface))
	return out
