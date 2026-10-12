extends RefCounted
## A 线（光与轮廓）· 盘橐轮廓光 extra script（探针，不是交付代码）。
## 给场景物体的材质挂加色 next_pass，只改运行时材质实例，不写任何 Codex 文件：
##   trees     → SnowCedars_* 的 panti_tree_wind 材质 next_pass = a_rim_edge_tree.gdshader（风动参数从主材质拷贝，anim_t 每帧同步）
##   castle    → 城堡原材质 + castle_lighting.lit_material 两份都挂同一个 a_rim_edge.gdshader pass
##   rocks     → SnowRocks_* 的材质 next_pass = a_rim_edge.gdshader
##   props     → 营地道具（Tent / Stump / Banner ...）next_pass = a_rim_edge.gdshader
##   character → PantiSeatedBody 各表面材质 next_pass = a_rim_char.gdshader（菲涅尔 + 篝火暖边）
## cfg 每一类：{"enabled": bool, "gain" / "gain_night": float 或 {"G": .., "L": ..}（树按层级；清晨 / 深夜各一套，按 period_w 混合）,
##             其余键 = 该类材质固定的 shader uniform}
## 随时段变化的 uniform（rim_tint / rim_strength / back_* ...）不在这里写，写在 variant 的 morning / midnight 的 "shaders" 节。
const EDGE_PATH := "res://tools/traveler/lookdev_panti/a_rim_edge.gdshader"
const EDGE_TREE_PATH := "res://tools/traveler/lookdev_panti/a_rim_edge_tree.gdshader"
const CHAR_PATH := "res://tools/traveler/lookdev_panti/a_rim_char.gdshader"
const SYNC_PATH := "res://tools/traveler/lookdev_panti/a_rim_sync.gd"
const WIND_KEYS: Array[String] = ["uv_scale", "uv_offset", "wind_enabled", "anim_t", "wind_world", "mesh_bottom_y", "mesh_height",
	"tip_displacement_ratio", "gust_period_s", "sway_period_s", "gust_weight", "rest_bend_ratio", "bend_exponent",
	"root_lock_fraction", "crown_ripple_ratio", "crown_layers"]
const RESERVED: Array[String] = ["enabled", "gain", "gain_night", "nodes", "render_priority"]

var tree_pairs: Array = []   # [[主材质, pass]]
var passes: Array = []       # 所有 pass（每帧同步主光方向）

func build(host: Node3D, cfg: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var sun_dir: Vector3 = (host.sun as DirectionalLight3D).global_basis.z.normalized()
	var edge_shader: Shader = load(EDGE_PATH) as Shader
	var tree_shader: Shader = load(EDGE_TREE_PATH) as Shader
	var char_shader: Shader = load(CHAR_PATH) as Shader
	var tc: Dictionary = cfg.get("trees", {})
	if bool(tc.get("enabled", true)):
		out["trees"] = _trees(host, tree_shader, tc, sun_dir)
	var cc: Dictionary = cfg.get("castle", {})
	if bool(cc.get("enabled", true)):
		out["castle"] = _castle(host, edge_shader, cc, sun_dir)
	var rc: Dictionary = cfg.get("rocks", {})
	if bool(rc.get("enabled", true)):
		out["rocks"] = _rocks(host, edge_shader, rc, sun_dir)
	var pc: Dictionary = cfg.get("props", {})
	if bool(pc.get("enabled", true)):
		out["props"] = _props(host, edge_shader, pc, sun_dir)
	var chc: Dictionary = cfg.get("character", {})
	if bool(chc.get("enabled", true)):
		out["character"] = _character(host, char_shader, chc)
	var sync: Node = (load(SYNC_PATH) as GDScript).new() as Node
	sync.name = "ARimSync"
	sync.set("host", host)
	sync.set("tree_pairs", tree_pairs)
	sync.set("passes", passes)
	sync.process_priority = 1001   # 排在 LookdevPeriodWatcher（1000，它写太阳角度）之后，读到的是最终主光方向
	host.add_child(sync)
	out["passes"] = passes.size()
	return out

func _make(shader: Shader, spec: Dictionary, key: String, sun_dir: Vector3) -> ShaderMaterial:
	var pm: ShaderMaterial = ShaderMaterial.new()
	pm.shader = shader
	pm.set_shader_parameter("sun_dir_world", sun_dir)
	var gd: float = _gain_for(spec, "gain", key)
	pm.set_shader_parameter("gain_day", gd)
	pm.set_shader_parameter("gain_night", _gain_for(spec, "gain_night", key) if spec.has("gain_night") else gd)
	for k: String in spec.keys():
		if k in RESERVED:
			continue
		pm.set_shader_parameter(k, _val(spec[k]))
	passes.append(pm)
	return pm

func _val(v: Variant) -> Variant:
	if v is Array:
		var a: Array = v
		if a.size() >= 3:
			return Color(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2:
			return Vector2(float(a[0]), float(a[1]))
	return v

func _gain_for(spec: Dictionary, field: String, key: String) -> float:
	var g: Variant = spec.get(field, 1.0)
	if g is Dictionary:
		return float((g as Dictionary).get(key, 1.0))
	return float(g)

func _trees(host: Node3D, shader: Shader, spec: Dictionary, sun_dir: Vector3) -> Dictionary:
	var res: Dictionary = {}
	for item: Node in host.world.find_children("SnowCedars_*", "MultiMeshInstance3D", true, false):
		var node: MultiMeshInstance3D = item as MultiMeshInstance3D
		var main: ShaderMaterial = node.material_override as ShaderMaterial
		if main == null:
			res[str(node.name)] = "no shader material"
			continue
		var tier: String = str(node.name).trim_prefix("SnowCedars_")
		var pm: ShaderMaterial = _make(shader, spec, tier, sun_dir)
		for k: String in WIND_KEYS:
			var v: Variant = main.get_shader_parameter(k)
			if v != null:
				pm.set_shader_parameter(k, v)
		main.next_pass = pm
		tree_pairs.append([main, pm])
		res[str(node.name)] = node.multimesh.instance_count
	return res

func _castle(host: Node3D, shader: Shader, spec: Dictionary, sun_dir: Vector3) -> Dictionary:
	var castle: MeshInstance3D = host.castle
	var pm: ShaderMaterial = _make(shader, spec, "castle", sun_dir)
	var targets: Array = []
	var cands: Array = [castle.mesh.surface_get_material(0), castle.get_surface_override_material(0)]
	var cl: Node = host.castle_lighting
	if cl != null:
		cands.append(cl.get("original_material"))
		cands.append(cl.get("original_material_override"))
		cands.append(cl.get("lit_material"))
	for m: Variant in cands:
		var mat: Material = m as Material
		if mat != null and not targets.has(mat):
			mat.next_pass = pm
			targets.append(mat)
	return {"materials": targets.size()}

func _rocks(host: Node3D, shader: Shader, spec: Dictionary, sun_dir: Vector3) -> Dictionary:
	var pm: ShaderMaterial = _make(shader, spec, "rocks", sun_dir)
	var count: int = 0
	var seen: Array = []
	for item: Node in host.world.find_children("SnowRocks_*", "MultiMeshInstance3D", true, false):
		var node: MultiMeshInstance3D = item as MultiMeshInstance3D
		if node.material_override != null:
			if not seen.has(node.material_override):
				node.material_override.next_pass = pm
				seen.append(node.material_override)
				count += 1
			continue
		var mesh: Mesh = node.multimesh.mesh
		for s: int in mesh.get_surface_count():
			var mat: Material = mesh.surface_get_material(s)
			if mat != null and not seen.has(mat):
				mat.next_pass = pm
				seen.append(mat)
				count += 1
	return {"materials": count}

func _props(host: Node3D, shader: Shader, spec: Dictionary, sun_dir: Vector3) -> Dictionary:
	var pm: ShaderMaterial = _make(shader, spec, "props", sun_dir)
	var res: Dictionary = {}
	var names: Array = spec.get("nodes", ["Tent", "Stump", "Banner"])
	for n: Variant in names:
		var node: MeshInstance3D = host.world.find_child(str(n), true, false) as MeshInstance3D
		if node == null or node.mesh == null:
			res[str(n)] = -1
			continue
		var c: int = 0
		if node.material_override != null:
			var d: Material = node.material_override.duplicate() as Material
			d.next_pass = pm
			node.material_override = d
			c += 1
		else:
			for s: int in node.mesh.get_surface_count():
				var m: Material = node.get_active_material(s)
				if m == null:
					continue
				var d2: Material = m.duplicate() as Material
				d2.next_pass = pm
				node.set_surface_override_material(s, d2)
				c += 1
		res[str(n)] = c
	return res

func _character(host: Node3D, shader: Shader, spec: Dictionary) -> Dictionary:
	var pm: ShaderMaterial = ShaderMaterial.new()
	pm.shader = shader
	# 人物主材质是 ALPHA_DEPTH_PRE_PASS（透明队列）：边光 pass 必须排在本体之后画，否则被本体的 alpha 混合盖掉
	pm.render_priority = int(spec.get("render_priority", 1))
	for k: String in spec.keys():
		if k in RESERVED:
			continue
		pm.set_shader_parameter(k, _val(spec[k]))
	var count: int = 0
	var diag: Array = []
	for item: Node in host.character_model.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = item as MeshInstance3D
		if mi.mesh == null or str(mi.name).contains("Outline") or mi.material_override != null:
			continue
		for s: int in mi.mesh.get_surface_count():
			var m: Material = mi.get_active_material(s)
			if m == null:
				continue
			var own: Material = mi.get_surface_override_material(s)
			if own == null:
				own = m.duplicate() as Material
				mi.set_surface_override_material(s, own)
			own.next_pass = pm
			count += 1
			if own is BaseMaterial3D:
				var bm: BaseMaterial3D = own as BaseMaterial3D
				diag.append({"node": str(mi.name), "transparency": bm.transparency, "cull": bm.cull_mode, "depth_draw": bm.depth_draw_mode,
					"blend": bm.blend_mode, "prio": bm.render_priority, "no_depth_test": bm.no_depth_test, "grow": bm.grow,
					"skin": mi.skin != null, "layers": mi.layers, "vis": mi.is_visible_in_tree()})
	return {"surfaces": count, "diag": diag}
