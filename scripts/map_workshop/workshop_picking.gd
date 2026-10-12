extends RefCounted
## 工坊的拾取（DESIGN 3.12.4）：对真实网格做射线拾取，悬停和点击共用同一套。
## 在棋盘自己的 SubViewport 世界（own_world_3d）里给能编辑的东西建静态碰撞体：
##   城市   每座城一个 StaticBody3D，该城每个 MeshInstance3D 一个 ConcavePolygonShape3D（get_faces() 的真三角形，点到的就是看到的）。
##          形状直接挂在 body 的 shape owner 上，不经过 CollisionShape3D 节点：实测给 CollisionShape3D 设一个 23 万面的形状
##          还要再花一遍建形状的时间（平城京 ≈ 140 ms），直接挂只剩建形状本身；按网格分开建也比合成一个大形状快约两成。
##   停靠点 CylinderShape3D，半径 0.68（硬币最大那一层，review.gd:1076），任何缩放下屏幕上至少 16 像素；
##   路线   沿线每 0.5 u 一个 CapsuleShape3D（半径 0.3），只用来「选中路线」；
##   把手   城脚圆环上的转向圆钮（以后还有路线控制点），只在选中时出现。
## 查询在 _gui_input 里同步做（direct_space_state.intersect_ray）：按下事件必须当场决定吃不吃掉。
## 本项目是默认的单线程物理，主线程可以直接查；以后有人打开多线程物理，T-E1 会红。
## 优先级：把手 > 停靠点 > 城市（名牌也算点城） > 路线，用碰撞层区分；同一层取最近的命中。

const L_ROUTE := 1
const L_CITY := 2
const L_STOP := 4
const L_HANDLE := 8
const STOP_R := 0.68
const STOP_MIN_PX := 16.0
const ROUTE_R := 0.3
const ROUTE_STEP := 0.5
const HANDLE_R := 0.42
const HANDLE_MIN_PX := 24.0          # 可点区域至少 48×48（3.12.2），不小于硬币

var board: Control
var root: Node3D                 # 全部拾取体挂在这里（棋盘世界的 world_root 下）
var city_bodies := {}            # city id -> StaticBody3D
var stop_bodies := {}            # stop id -> StaticBody3D
var route_bodies := {}           # route id -> StaticBody3D
var handle_bodies := {}          # handle id -> StaticBody3D
var build_ms := {}               # city id -> 建碰撞形状用了多少毫秒
var _stop_shape: CylinderShape3D
var _handle_shape: SphereShape3D
var _route_handle_shape: SphereShape3D
var _last_ppu := -1.0


func _init(b: Control) -> void:
	board = b


## 等待卡期间同步建完全部（3.12.4）：城市、停靠点、路线
func build_all() -> void:
	if root != null and is_instance_valid(root):
		root.queue_free()
	root = Node3D.new()
	root.name = "WorkshopPicking"
	board.world.world_root.add_child(root)
	city_bodies.clear()
	stop_bodies.clear()
	route_bodies.clear()
	handle_bodies.clear()
	_built_from.clear()
	_stop_shape = CylinderShape3D.new()
	_stop_shape.radius = STOP_R
	_stop_shape.height = 0.6
	_handle_shape = SphereShape3D.new()
	_handle_shape.radius = HANDLE_R
	_route_handle_shape = SphereShape3D.new()
	_route_handle_shape.radius = HANDLE_R
	for cid in board.world.city_nodes:
		rebuild_city(String(cid))
	rebuild_routes_and_stops(board.world.layout)


## 一座城的碰撞体：换样子、放新城时只重建这一座（同步）
func rebuild_city(cid: String) -> void:
	var t0 := Time.get_ticks_usec()
	if city_bodies.has(cid) and is_instance_valid(city_bodies[cid]):
		(city_bodies[cid] as Node).free()
	var holder: Node3D = board.world.city_nodes[cid].node
	var body := StaticBody3D.new()
	body.name = "PickCity_" + cid
	body.collision_layer = L_CITY
	body.collision_mask = 0
	body.set_meta("pick", {"kind": "city", "id": cid})
	root.add_child(body)
	body.global_transform = _body_xf(holder)
	var inv := body.global_transform.affine_inverse()
	var owner := body.create_shape_owner(body)
	for mi: MeshInstance3D in board.world.mesh_instances(holder):
		if mi.mesh == null:
			continue
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces((inv * mi.global_transform) * mi.mesh.get_faces())
		body.shape_owner_add_shape(owner, shape)
	city_bodies[cid] = body
	build_ms[cid] = (Time.get_ticks_usec() - t0) / 1000.0


## 城被挪了（拖动中每一帧）：碰撞体跟着模型走
func sync_city(cid: String) -> void:
	if not city_bodies.has(cid):
		return
	var holder: Node3D = board.world.city_nodes[cid].node
	(city_bodies[cid] as Node3D).global_transform = _body_xf(holder)


## 模型的变换去掉缩放（碰撞体不带缩放，三角形在建的时候已经乘上了）
func _body_xf(holder: Node3D) -> Transform3D:
	var xf := holder.global_transform
	return Transform3D(xf.basis.orthonormalized(), xf.origin)


var _built_from := {}             # route / stop id -> 建碰撞体时用的那个布局字典（推导没改的路线还是同一个对象）


## 路线和停靠点：只重建变了的那几条（推导函数对没改的路线原样返回同一个字典）
func rebuild_routes_and_stops(layout: Dictionary) -> void:
	var keep := {}
	for st: Dictionary in layout.get("stops", []):
		if _built_from.get(String(st.id)) == st and stop_bodies.has(String(st.id)):
			keep[String(st.id)] = true
	for r: Dictionary in layout.get("routes", []):
		if _built_from.get(String(r.id)) == r and route_bodies.has(String(r.id)):
			keep[String(r.id)] = true
	for d in [stop_bodies, route_bodies]:
		for k in d.keys():
			if keep.has(k):
				continue
			if is_instance_valid(d[k]):
				(d[k] as Node).free()
			d.erase(k)
	for st: Dictionary in layout.get("stops", []):
		if keep.has(String(st.id)):
			continue
		_built_from[String(st.id)] = st
		var body := StaticBody3D.new()
		body.collision_layer = L_STOP
		body.collision_mask = 0
		body.set_meta("pick", {"kind": "stop", "id": String(st.id)})
		var cs := CollisionShape3D.new()
		cs.shape = _stop_shape
		body.add_child(cs)
		root.add_child(body)
		body.global_position = Vector3(float(st.x), float(st.y) + 0.1, float(st.z))
		stop_bodies[String(st.id)] = body
	for r: Dictionary in layout.get("routes", []):
		if keep.has(String(r.id)):
			continue
		_built_from[String(r.id)] = r
		var body := StaticBody3D.new()
		body.collision_layer = L_ROUTE
		body.collision_mask = 0
		body.set_meta("pick", {"kind": "route", "id": String(r.id)})
		root.add_child(body)
		var pts: Array = r.points
		var acc := ROUTE_STEP
		var prev := Vector3(float(pts[0][0]), float(pts[0][1]), float(pts[0][2]))
		for i in range(1, pts.size()):
			var p := Vector3(float(pts[i][0]), float(pts[i][1]), float(pts[i][2]))
			acc += Vector2(p.x - prev.x, p.z - prev.z).length()
			if acc >= ROUTE_STEP or i == pts.size() - 1:
				acc = 0.0
				var cap := CapsuleShape3D.new()
				cap.radius = ROUTE_R
				cap.height = ROUTE_STEP + ROUTE_R * 2.0
				var cs := CollisionShape3D.new()
				cs.shape = cap
				var d := p - prev
				var y_axis := d.normalized() if d.length() > 1e-4 else Vector3.RIGHT
				var x_axis := y_axis.cross(Vector3.UP).normalized()
				if x_axis.length() < 0.5:
					x_axis = Vector3.RIGHT
				var z_axis := x_axis.cross(y_axis).normalized()
				cs.transform = Transform3D(Basis(x_axis, y_axis, z_axis), p + Vector3(0, 0.05, 0))
				body.add_child(cs)
			prev = p
		route_bodies[String(r.id)] = body


## 把手（转向圆钮）：id -> 世界坐标；空字典 = 收起全部
func set_handles(handles: Dictionary) -> void:
	for k in handle_bodies.keys():
		if not handles.has(k):
			(handle_bodies[k] as Node).free()
			handle_bodies.erase(k)
	for k in handles:
		var body: StaticBody3D = handle_bodies.get(k)
		if body == null:
			body = StaticBody3D.new()
			body.collision_layer = L_HANDLE
			body.collision_mask = 0
			body.set_meta("pick", {"kind": String(k).get_slice(":",0) if String(k).begins_with("route_") else "handle", "id": String(k)})
			var cs := CollisionShape3D.new()
			cs.shape = _route_handle_shape if String(k).begins_with("route_") else _handle_shape
			body.add_child(cs)
			root.add_child(body)
			handle_bodies[k] = body
		body.global_position = handles[k]


## 硬币、把手在屏幕上至少这么大（缩得很小时把形状放大）
func _fit_min_radius() -> void:
	var ppu: float = board.px_per_unit()
	if absf(ppu - _last_ppu) < 1e-3:
		return
	_last_ppu = ppu
	_stop_shape.radius = maxf(STOP_R, STOP_MIN_PX / maxf(ppu, 0.01))
	_handle_shape.radius = handle_radius()
	_route_handle_shape.radius = 9.0 / maxf(ppu, 0.01)


## 转向圆钮的可点半径（世界单位）：屏幕上至少 HANDLE_MIN_PX；棋盘按它画圆钮（看见多大就能点多大）
func handle_radius() -> float:
	return maxf(HANDLE_R, HANDLE_MIN_PX / maxf(board.px_per_unit(), 0.01))


## 棋盘控件内的一点（画布坐标）下面是什么：{kind, id, point}；什么都没有时 kind 为 ""
func pick(pos: Vector2) -> Dictionary:
	if root == null or board.world == null or board.world.camera == null:
		return {"kind": "", "id": ""}
	_fit_min_radius()
	var cam: Camera3D = board.world.camera
	var sp: Vector2 = pos * float(board.get("_render_scale"))
	var from := cam.project_ray_origin(sp)
	var to := from + cam.project_ray_normal(sp) * 1000.0
	var space: PhysicsDirectSpaceState3D = board.vp.find_world_3d().direct_space_state
	for layer in [L_HANDLE, L_STOP]:
		var h := _ray(space, from, to, layer)
		if not h.is_empty():
			return h
	# 显式路线工具与悬停共用优先级；选择工具仍保留原城市名牌行为。
	if board.route_pick_preferred:
		var route_hit := _ray(space, from, to, L_ROUTE)
		if not route_hit.is_empty():
			return route_hit
	# 名牌也算点城：名牌画在 3D 画面上面，指针在名牌上时看到的就是名牌
	var plaque: String = board.plaque_city_at(pos)
	if plaque != "":
		return {"kind": "city", "id": plaque, "point": Vector3.INF}
	for layer in [L_CITY, L_ROUTE]:
		var h := _ray(space, from, to, layer)
		if not h.is_empty():
			return h
	return {"kind": "", "id": ""}


func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, mask: int) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, mask)
	q.hit_back_faces = true
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	var col: Object = hit.get("collider")
	if col == null or not col.has_meta("pick"):
		return {}
	var info: Dictionary = (col.get_meta("pick") as Dictionary).duplicate()
	info["point"] = hit.get("position", Vector3.INF)
	return info


## 只查一层（测试用：判断一个表面点是不是「看得见」）
func ray_layer(pos: Vector2, layer: int) -> Dictionary:
	var cam: Camera3D = board.world.camera
	var sp: Vector2 = pos * float(board.get("_render_scale"))
	var from := cam.project_ray_origin(sp)
	return _ray(board.vp.find_world_3d().direct_space_state, from, from + cam.project_ray_normal(sp) * 1000.0, layer)
