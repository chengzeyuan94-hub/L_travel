extends RefCounted
## C 线 · 暖光 / 反弹光 / 反射（探针 extra script，不是交付代码）。
## 只加灯、只给现有几何体追加渲染层位（不去掉任何原有层位），不改贴图、不动机位。
##
## 1. 层位：雪地 += ground 位；营地道具（帐篷/树桩/火塘/灯笼/旗）+= camp 位；全部岩石 += rocks 位；城堡 += castle 位。
##    人物本来就在 1<<19（char）。灯的 light_cull_mask 用这些位组合，就能做到"只照雪地""只照营地+人物""只照城堡"。
## 2. 灯（cfg.lights，每盏都有唯一名字，能量交给 variant 的 morning / midnight 两节，watcher 按过渡权重插值）：
##    {"name", "type": "omni"|"dir", "mask": ["ground","camp","rocks","castle","char","all"],
##     "anchor": {"node": "fire"|"seat"|"lantern"} | {"spill": "<城下暖光名>"} | {"screen": [x,y], "on": "castle"|"ground"},
##     "offset": {"right", "up", "toward_cam", "normal"}（相机水平系，up 是世界竖直），
##     "dir": {"right","up","toward_cam"}（平行光：从表面指向光源的方向）,
##     "range", "attenuation", "specular", "color", "follow": "fire" | "breath:<城下暖光名>"}
## 3. 跟随节点 CWarmFollower（process_priority 1001，排在 watcher 之后）：
##    follow=fire 的灯每帧乘 CampFireWarmLight 当前能量 / 火焰基准能量（即火焰闪烁比例），不抢写 CampFireWarmLight；
##    follow=breath:<名> 的灯乘城下对应暖光的呼吸系数。
## 4. cfg.rock_override=true：给岩石 MultiMesh 挂一份原材质副本做 material_override，
##    这样 variant 的 "materials": {"SnowRocks_*": {...}} 才能生效（watcher 只认 material_override / MeshInstance 表面材质）。
const CHAR_BIT: int = 1 << 19
const FOLLOWER := "res://tools/traveler/lookdev_panti/c_warm_follower.gd"  # r4 copy of c_warm_bounce.gd: screen anchors via fixed 1080p reference camera

var host: Node3D
var cam: Camera3D
var bits: Dictionary = {}
var tri_cache: Dictionary = {}
var right_h: Vector3 = Vector3.RIGHT
var to_cam_h: Vector3 = Vector3.BACK

func build(h: Node3D, cfg: Dictionary) -> Dictionary:
	host = h
	cam = host.camera
	var lay: Dictionary = cfg.get("layers", {})
	bits = {"ground": 1 << int(lay.get("ground", 11)), "camp": 1 << int(lay.get("camp", 12)), "castle": 1 << int(lay.get("castle", 13)), "rocks": 1 << int(lay.get("rocks", 14)), "char": CHAR_BIT, "all": 0xFFFFF}
	var fwd: Vector3 = -cam.global_basis.z
	fwd.y = 0.0
	to_cam_h = -fwd.normalized()
	right_h = cam.global_basis.x
	right_h.y = 0.0
	right_h = right_h.normalized()
	var out: Dictionary = {"bits": bits.duplicate()}
	# 1. 层位
	var ground: GeometryInstance3D = host.get("snow_ground")
	ground.layers |= int(bits["ground"])
	var tagged: Array = ["SnowGround"]
	var camp: Node3D = host.get("camp")
	if camp != null:
		for k in camp.props.keys():
			var n: GeometryInstance3D = camp.props[k].node
			n.layers |= int(bits["camp"])
			tagged.append(str(n.name))
	for rn in host.get("rock_nodes"):
		var mmi := rn as MultiMeshInstance3D
		mmi.layers |= int(bits["rocks"])
		tagged.append(str(mmi.name))
		if bool(cfg.get("rock_override", false)) and mmi.material_override == null and mmi.multimesh != null and mmi.multimesh.mesh != null:
			var src: Material = mmi.multimesh.mesh.surface_get_material(0)
			if src is BaseMaterial3D:
				mmi.material_override = (src as BaseMaterial3D).duplicate()
	var castle: GeometryInstance3D = host.get("castle")
	castle.layers |= int(bits["castle"])
	tagged.append("PantiFortress")
	out["tagged"] = tagged
	# 2. 灯
	var follower: Node = load(FOLLOWER).new()
	follower.name = "CWarmFollower"
	follower.set("host", host)
	var made: Array = []
	for spec_v in cfg.get("lights", []):
		var spec: Dictionary = spec_v
		var l: Light3D = _make_light(spec)
		if l == null:
			made.append({"name": str(spec.get("name", "?")), "error": "anchor miss"})
			continue
		var fol: String = str(spec.get("follow", ""))
		if fol == "fire":
			(follower.get("fire_lights") as Array).append(l)
		elif fol.begins_with("breath:"):
			(follower.get("breath_lights") as Array).append({"light": l, "spill": fol.trim_prefix("breath:")})
		var rec: Dictionary = {"name": str(l.name), "mask": l.light_cull_mask}
		if l is OmniLight3D:
			var p: Vector3 = l.global_position
			var s: Vector2 = cam.unproject_position(p)
			rec["pos"] = [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)]
			rec["screen"] = [int(s.x), int(s.y)]
		else:
			rec["dir"] = str(-l.global_basis.z)
		made.append(rec)
	host.add_child(follower)
	_free_ref()
	out["lights"] = made
	return out

func _mask(names: Array) -> int:
	var m: int = 0
	for nm in names:
		m |= int(bits.get(str(nm), 0))
	return m

func _off(o: Dictionary) -> Vector3:
	return right_h * float(o.get("right", 0.0)) + Vector3.UP * float(o.get("up", 0.0)) + to_cam_h * float(o.get("toward_cam", 0.0))

func _col(v: Variant, fallback: Color) -> Color:
	if v is Array:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return fallback

func _make_light(spec: Dictionary) -> Light3D:
	var kind: String = str(spec.get("type", "omni"))
	var l: Light3D
	if kind == "dir":
		var dl := DirectionalLight3D.new()
		dl.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
		dl.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		l = dl
	else:
		var ol := OmniLight3D.new()
		ol.omni_range = float(spec.get("range", 1.0))
		ol.omni_attenuation = float(spec.get("attenuation", 1.0))
		l = ol
	l.name = str(spec.get("name", "CLight"))
	l.light_color = _col(spec.get("color", null), Color(1.0, 0.7, 0.45))
	l.light_energy = float(spec.get("energy", 0.0))
	l.light_specular = float(spec.get("specular", 0.0))
	l.shadow_enabled = false
	l.light_cull_mask = _mask(spec.get("mask", ["all"]))
	l.visible = l.light_energy > 0.0001
	host.world.add_child(l)
	if kind == "dir":
		var to_light: Vector3 = _off(spec.get("dir", {"up": -1.0})).normalized()
		l.look_at(l.global_position - to_light, Vector3.UP if absf(to_light.y) < 0.95 else Vector3.RIGHT)
		return l
	var hit: Dictionary = _anchor(spec.get("anchor", {"node": "fire"}))
	if hit.is_empty():
		l.queue_free()
		return null
	var pos: Vector3 = hit["position"]
	var off: Dictionary = spec.get("offset", {})
	pos += _off(off)
	if off.has("normal") and hit.has("normal"):
		pos += (hit["normal"] as Vector3) * float(off["normal"])
	l.global_position = pos
	return l

func _anchor(a: Dictionary) -> Dictionary:
	var camp: Node3D = host.get("camp")
	if a.has("node"):
		var nm: String = str(a["node"])
		if camp == null:
			return {}
		if nm == "fire":
			return {"position": (camp.fire.fire_light as Node3D).global_position}
		if nm == "seat":
			return {"position": camp.seat_world}
		if nm == "lantern":
			return {"position": (camp.lantern_light as Node3D).global_position}
		if camp.props.has(nm):
			var n: MeshInstance3D = camp.props[nm].node
			return {"position": (n.global_transform * n.get_aabb()).get_center()}
		return {}
	if a.has("spill"):
		for l in host.castle_lighting.spills:
			if str((l as Node).name) == str(a["spill"]):
				return {"position": (l as Node3D).global_position}
		return {}
	if a.has("screen"):
		# r4: rays are cast from a fixed 1920x1080 reference camera (same transform / fov / keep_aspect), so the
		# anchors land on the same castle points whatever the live window aspect is (stretch aspect = "expand").
		var px: Array = a["screen"]
		var rc: Camera3D = _ref_cam()
		var sp := Vector2(float(px[0]), float(px[1]))
		var o: Vector3 = rc.project_ray_origin(sp)
		var d: Vector3 = rc.project_ray_normal(sp)
		var target: String = str(a.get("on", "ground"))
		var gi: MeshInstance3D = host.get("castle") if target == "castle" else host.get("snow_ground")
		return _ray(gi, o, d)
	return {}

var ref_vp: SubViewport = null
var ref_cam: Camera3D = null

func _ref_cam() -> Camera3D:
	if ref_cam == null:
		ref_vp = SubViewport.new()
		ref_vp.size = Vector2i(1920, 1080)
		ref_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		host.add_child(ref_vp)
		ref_cam = Camera3D.new()
		ref_cam.keep_aspect = cam.keep_aspect
		ref_cam.fov = cam.fov
		ref_cam.near = cam.near
		ref_cam.far = cam.far
		ref_vp.add_child(ref_cam)
		ref_cam.global_transform = cam.global_transform
	return ref_cam

func _free_ref() -> void:
	if ref_vp != null:
		host.remove_child(ref_vp)
		ref_vp.free()
		ref_vp = null
		ref_cam = null

func _ray(gi: MeshInstance3D, o: Vector3, d: Vector3) -> Dictionary:
	var key: int = gi.get_instance_id()
	if not tri_cache.has(key):
		tri_cache[key] = gi.mesh.generate_triangle_mesh()
	var tm: TriangleMesh = tri_cache[key]
	var inv: Transform3D = gi.global_transform.affine_inverse()
	var r: Dictionary = tm.intersect_ray(inv * o, (inv.basis * d).normalized())
	if r.is_empty():
		return {}
	var p: Vector3 = gi.global_transform * (r["position"] as Vector3)
	var n: Vector3 = (gi.global_basis.inverse().transposed() * (r["normal"] as Vector3)).normalized()
	if n.dot(-d) < 0.0:
		n = -n
	return {"position": p, "normal": n}
