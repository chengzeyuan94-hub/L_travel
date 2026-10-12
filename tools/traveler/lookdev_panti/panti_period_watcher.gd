extends Node
## 每帧按时段过渡权重 w（0 = 清晨，1 = 深夜）把 variant 两个时段的数值插值写进场景。
## 排在 weather（它驱动时段过渡）之后执行，所以覆盖过渡写入的同名属性。
var host: Node3D
var m: Dictionary
var n: Dictionary
var base_env: Dictionary = {}
var base_sun: Dictionary = {}
var lights: Dictionary = {}       # name -> Light3D
var base_lights: Dictionary = {}  # name -> {prop: value}
var shader_mats: Dictionary = {}  # file -> Array[ShaderMaterial]
var base_uniforms: Dictionary = {}# file -> {uniform: value}
var mat_targets: Dictionary = {}  # glob -> Array[{"node": GeometryInstance3D, "mat": BaseMaterial3D}]
var base_mats: Dictionary = {}
var last_w := -1.0

func configure(h: Node3D, morning: Dictionary, midnight: Dictionary) -> Dictionary:
	host = h
	m = morning
	n = midnight
	process_priority = 1000
	var sun: DirectionalLight3D = host.sun
	for k in _keys("sun"):
		if k == "sunel":
			base_sun[k] = rad_to_deg(sun.rotation.x)
		elif k == "sunaz":
			base_sun[k] = rad_to_deg(sun.rotation.y)
		else:
			base_sun[k] = sun.get(k)
	for k in _keys("env"):
		base_env[k] = host.environment.get(k)
	for name in _keys("lights"):
		var l := host.find_child(name, true, false) as Light3D
		if l == null:
			continue
		lights[name] = l
		var props := {}
		for k in _subkeys("lights", name):
			props[k] = l.get(k)
		base_lights[name] = props
	var all_mats := _collect_shader_materials()
	for file in _keys("shaders"):
		var list: Array = []
		for mat in all_mats:
			if (mat as ShaderMaterial).shader != null and (mat as ShaderMaterial).shader.resource_path.get_file() == file:
				list.append(mat)
		shader_mats[file] = list
		var bu := {}
		if not list.is_empty():
			for k in _subkeys("shaders", file):
				bu[k] = (list[0] as ShaderMaterial).get_shader_parameter(k)
		base_uniforms[file] = bu
	for glob in _keys("materials"):
		var arr: Array = []
		for item in host.world.find_children(glob, "GeometryInstance3D", true, false):
			var gi := item as GeometryInstance3D
			var src: Material = gi.material_override
			if src == null and gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
				src = (gi as MeshInstance3D).get_active_material(0)
			if src is BaseMaterial3D:
				var d := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
				gi.material_override = d
				arr.append(d)
		mat_targets[glob] = arr
		var bm := {}
		if not arr.is_empty():
			for k in _subkeys("materials", glob):
				bm[k] = (arr[0] as BaseMaterial3D).get(k)
		base_mats[glob] = bm
	_apply(_weight())
	var counts := {}
	for f in shader_mats:
		counts[f] = (shader_mats[f] as Array).size()
	return {"lights_found": lights.keys(), "shader_materials": counts, "material_targets": mat_targets.keys(), "w": last_w}

func _process(_d: float) -> void:
	_apply(_weight())

func _weight() -> float:
	var pt: RefCounted = host.get("period_transition")
	if pt != null:
		return float(pt.get("weight"))
	return 1.0 if str(host.get("lighting_period")) == "midnight" else 0.0

func _keys(section: String) -> Array:
	var out: Array = []
	for d in [m, n]:
		for k in d.get(section, {}).keys():
			if not out.has(k):
				out.append(k)
	return out

func _subkeys(section: String, name: String) -> Array:
	var out: Array = []
	for d in [m, n]:
		for k in d.get(section, {}).get(name, {}).keys():
			if not out.has(k):
				out.append(k)
	return out

func _mix(base: Variant, a: Variant, b: Variant, w: float) -> Variant:
	var va: Variant = _conv(a if a != null else base, base)
	var vb: Variant = _conv(b if b != null else base, base)
	if va is Color and vb is Color:
		return (va as Color).lerp(vb as Color, w)
	if (va is float or va is int) and (vb is float or vb is int):
		return lerpf(float(va), float(vb), w)
	if va is Vector3 and vb is Vector3:
		return (va as Vector3).lerp(vb as Vector3, w)
	return vb if w >= 0.5 else va

func _conv(v: Variant, like: Variant) -> Variant:
	if v is Array:
		var a: Array = v
		if like is Vector3 or (a.size() == 3 and like is Vector3):
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() >= 3:
			return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	if v is bool:
		return 1.0 if v else 0.0
	return v

func _sec(section: String, d: Dictionary, k: String) -> Variant:
	return d.get(section, {}).get(k, null)

func _apply(w: float) -> void:
	last_w = w
	var sun: DirectionalLight3D = host.sun
	var el: Variant = null
	var az: Variant = null
	for k in base_sun.keys():
		var v: Variant = _mix(base_sun[k], _sec("sun", m, k), _sec("sun", n, k), w)
		if k == "sunel":
			el = v
		elif k == "sunaz":
			az = v
		else:
			sun.set(k, v)
	if el != null or az != null:
		sun.rotation = Vector3(deg_to_rad(float(el if el != null else rad_to_deg(sun.rotation.x))), deg_to_rad(float(az if az != null else rad_to_deg(sun.rotation.y))), 0.0)
	for k in base_env.keys():
		host.environment.set(k, _mix(base_env[k], _sec("env", m, k), _sec("env", n, k), w))
	for name in lights.keys():
		var l: Light3D = lights[name]
		for k in base_lights[name].keys():
			var v: Variant = _mix(base_lights[name][k], m.get("lights", {}).get(name, {}).get(k, null), n.get("lights", {}).get(name, {}).get(k, null), w)
			l.set(k, v)
		if l.get("light_energy") != null:
			l.visible = float(l.light_energy) > 0.0001
	for file in shader_mats.keys():
		for k in base_uniforms[file].keys():
			var v: Variant = _mix(base_uniforms[file][k], m.get("shaders", {}).get(file, {}).get(k, null), n.get("shaders", {}).get(file, {}).get(k, null), w)
			for mat in shader_mats[file]:
				(mat as ShaderMaterial).set_shader_parameter(k, v)
	for glob in mat_targets.keys():
		for k in base_mats[glob].keys():
			var v: Variant = _mix(base_mats[glob][k], m.get("materials", {}).get(glob, {}).get(k, null), n.get("materials", {}).get(glob, {}).get(k, null), w)
			for mat in mat_targets[glob]:
				(mat as BaseMaterial3D).set(k, v)

func _collect_shader_materials() -> Array:
	var out: Array = []
	var seen := {}
	for item in host.find_children("*", "GeometryInstance3D", true, false):
		var gi := item as GeometryInstance3D
		var mats: Array = [gi.material_override]
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
			var mi := gi as MeshInstance3D
			for s in mi.mesh.get_surface_count():
				mats.append(mi.get_active_material(s))
		if gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null and (gi as MultiMeshInstance3D).multimesh.mesh != null:
			var mm := (gi as MultiMeshInstance3D).multimesh.mesh
			for s in mm.get_surface_count():
				mats.append(mm.surface_get_material(s))
		if gi is GPUParticles3D:
			mats.append((gi as GPUParticles3D).process_material)
		for mat in mats:
			var cur: Material = mat
			while cur != null:
				if cur is ShaderMaterial and not seen.has(cur.get_instance_id()):
					seen[cur.get_instance_id()] = true
					out.append(cur)
				cur = cur.next_pass
	return out

func evidence() -> Dictionary:
	return {"w": last_w}
