extends RefCounted
## rim 线 · 长安日暮金边 extra script（探针，不是交付代码）。
## 两种金边 pass，都挂 next_pass、加色、只认太阳、乘 ATTENUATION（阴影里不出边）：
##   edge    = rim_edge_pass.gdshader：屏幕空间深度差，朝太阳方向挪几个像素看是否"背后更远"→ 细线描轮廓（低多边形用）。
##   fresnel = rim_next_pass.gdshader：菲涅尔边（光滑法线的模型用，如人物）。
## cfg: {"targets": [
##   {"kind": "atlas", "exclude": [材质 resource_name 子串...], "cull_exempt": [不按距离剔除的材质子串，如 terrain], <edge 参数>}
##                                                                       → host.material_list 里全部 atlas_surface 材质
##   {"root": "character", "match": "tripo_node", "mode": "fresnel", <参数>}   → 人物（异步生成，交给 watch 节点延后挂）
##   {"path": "CliffBuddha", "mode": "edge", <参数>}                           → host.world 下的节点（含子 MeshInstance3D）
## ], "massif_key": {"path", "layer_bit", "color", "energy"}（可选：只照远景雪山的同向暖光）}
## 参数名与 shader uniform 同名（fresnel 的 intensity/power 映射到 rim_intensity/rim_power；color 映射到 rim_color/rim_tint）。
const FRESNEL_PATH := "res://tools/traveler/lookdev_changan/rim_next_pass.gdshader"
const EDGE_PATH := "res://tools/traveler/lookdev_changan/rim_edge_pass.gdshader"
const WATCH_PATH := "res://tools/traveler/lookdev_changan/changan_extra_rim_watch.gd"
const WIND_KEYS := ["wind_amp", "wind_stiff", "wind_gust", "wind_dir", "anim_t", "base_color", "brightness"]
var fresnel_shader: Shader
var edge_shader: Shader
var sun_dir := Vector3.ZERO
var pairs: Array = []   # [[主材质, edge pass]]，watch 节点每帧同步风动参数

func build(host: Node3D, cfg: Dictionary) -> Dictionary:
	fresnel_shader = load(FRESNEL_PATH)
	edge_shader = load(EDGE_PATH)
	sun_dir = (host.sun as DirectionalLight3D).global_basis.z.normalized()
	var out: Dictionary = {}
	var char_specs: Array = []
	for spec in cfg.get("targets", []):
		if str(spec.get("kind", "")) == "atlas":
			out["atlas"] = _apply_atlas(host, spec)
		elif str(spec.get("root", "world")) == "character":
			char_specs.append(spec)
			out["character:" + str(spec.get("match", ""))] = "deferred"
		else:
			out[str(spec.get("path", spec.get("match", "world")))] = apply_spec(host, spec)
	if cfg.has("massif_key"):
		out["massif_key"] = _massif_key(host, cfg.massif_key)
	if not pairs.is_empty() or not char_specs.is_empty():
		var watch: Node = load(WATCH_PATH).new()
		watch.name = "RimWatch"
		watch.set("extra", self)
		watch.set("host", host)
		watch.set("char_specs", char_specs)
		watch.set("pairs", pairs)
		watch.process_priority = 1000   # 在 MotionDirector 写完 anim_t 之后再同步
		host.add_child(watch)
	return out

func _apply_atlas(host: Node3D, spec: Dictionary) -> Dictionary:
	var names: Array = []
	var skipped: Array = []
	var excl: Array = spec.get("exclude", [])
	for m in host.material_list:
		var sm := m as ShaderMaterial
		if sm == null:
			continue
		var nm := str(sm.resource_name)
		var skip := false
		for e in excl:
			if nm.contains(str(e)):
				skip = true
		if skip:
			skipped.append(nm)
			continue
		var pm := _make(edge_shader, spec, "edge")
		var exempt := false
		for e in spec.get("cull_exempt", []):
			if nm.contains(str(e)):
				exempt = true
		if exempt:
			pm.set_shader_parameter("cull_dist", 1000000.0)
		for k in WIND_KEYS:
			var v: Variant = sm.get_shader_parameter(k)
			if v != null:
				pm.set_shader_parameter(k, v)
		sm.next_pass = pm
		pairs.append([sm, pm])
		names.append(nm)
	return {"materials": names.size(), "names": names, "skipped": skipped}

func apply_spec(host: Node3D, spec: Dictionary) -> int:
	var root: Node = host.world
	if str(spec.get("root", "world")) == "character":
		root = host.character_controller
	if spec.has("path"):
		root = host.world.get_node_or_null(NodePath(str(spec.path)))
		if root == null:
			return -1
	var mode := str(spec.get("mode", "fresnel"))
	var needle := str(spec.get("match", ""))
	var nodes: Array = root.find_children("*" + needle + "*" if not needle.is_empty() else "*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		nodes.append(root)
	var count := 0
	for item in nodes:
		var mi := item as MeshInstance3D
		if mi == null or mi.mesh == null or str(mi.name).begins_with("CharacterOutline_"):
			continue
		var pm := _make(edge_shader if mode == "edge" else fresnel_shader, spec, mode)
		if mode == "edge":
			pm.set_shader_parameter("use_vertex_color", bool(spec.get("use_vertex_color", false)))
			pm.set_shader_parameter("brightness", 1.0)
		if mi.material_override != null:
			var d := mi.material_override.duplicate() as Material
			d.next_pass = pm
			mi.material_override = d
			count += 1
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			if m == null:
				continue
			var d2 := m.duplicate() as Material
			d2.next_pass = pm
			mi.set_surface_override_material(s, d2)
			count += 1
	return count

func _make(shader: Shader, spec: Dictionary, mode: String) -> ShaderMaterial:
	var pm := ShaderMaterial.new()
	pm.shader = shader
	pm.set_shader_parameter("sun_dir_world", sun_dir)
	for k in spec.keys():
		if k in ["kind", "root", "match", "path", "mode", "exclude", "cull_exempt", "use_vertex_color"]:
			continue
		var pname: String = k
		if k == "color":
			pname = "rim_tint" if mode == "edge" else "rim_color"
		elif mode != "edge" and k in ["intensity", "power"]:
			pname = "rim_" + k
		var v: Variant = spec[k]
		if v is Array:
			var a: Array = v
			v = Color(float(a[0]), float(a[1]), float(a[2])) if a.size() >= 3 else Vector2(float(a[0]), float(a[1]))
		pm.set_shader_parameter(pname, v)
	return pm

## 远景雪山单独补一盏与太阳同向的暖光（只照雪山：给雪山节点加一个专用 layer 位，灯的 cull_mask 只含这一位）。
## 让雪山受光面有日暮的粉金色（alpenglow），不把近景地面一起照亮。雪山在阴影距离之外，这盏灯不开阴影。
func _massif_key(host: Node3D, c: Dictionary) -> Dictionary:
	var node := host.world.get_node_or_null(NodePath(str(c.get("path", "FarBackdrop/MassifBandMerged")))) as VisualInstance3D
	if node == null:
		return {"error": "missing"}
	var bit := 1 << int(c.get("layer_bit", 19))
	node.layers = node.layers | bit
	var l := DirectionalLight3D.new()
	l.name = "RimMassifAlpenglow"
	var col: Array = c.get("color", [1.0, 0.72, 0.6])
	l.light_color = Color(float(col[0]), float(col[1]), float(col[2]))
	l.light_energy = float(c.get("energy", 0.35))
	l.light_specular = 0.0
	l.shadow_enabled = false
	l.light_cull_mask = bit
	host.world.add_child(l)
	l.global_basis = (host.sun as DirectionalLight3D).global_basis
	return {"layers": node.layers, "energy": l.light_energy}
