extends RefCounted
## 地面草随风摆动（Carlos 2026-09-23：「地板上的草记得动一下」）。导演探针，挂在 lookdev_overlay 的 extra_scripts 上。
##
## 三套草：
##   DryGrass*               Codex 的前景路面资产 cracked_road.glb 里的干草（baghdad_foreground_details.gd）
##   SparseForegroundTufts   Codex 的稀疏草丛（baghdad_supporting_props.gd）
##   ScatterDryGrass         探针散布层的小草（lookdev_extra_scatter.gd，MultiMesh）
##
## 做法：外观参数逐项从草原来的 StandardMaterial3D 拷到等价着色器 lookdev_grass_wind_*.gdshader，
## 只在 vertex() 里加风（Godot 4.7 的 GDScript 取不到 BaseMaterial3D 生成的源码）。
## sway_ratio=0 时应与原来一致（见 m_grass0 对比）。
##
## 每个顶点"离地多高"写进 UV2：
##   合并网格（DryGrass / Tufts）：UV2.x = 顶点世界高度 − 该处沙面高度（height_at），UV2.y = 相对高度 0..1；
##   MultiMesh（ScatterDryGrass）：UV2.x = 顶点局部高度（shader 里乘实例的 Y 缩放换成世界高度），UV2.y 同上。
## 根部不动，越往上摆得越多；风向与云、落叶、风沙一致（画面右 → 左）。

const TARGETS := ["DryGrass", "SparseForegroundTufts", "ScatterDryGrass"]
var _shader_cache: Dictionary = {}
var _material_notes: Array = []

func build(viewer: Node3D, cfg: Dictionary) -> Dictionary:
	var wind: Vector3 = -(viewer.camera as Camera3D).global_basis.x
	wind.y = 0.0
	wind = wind.normalized()
	var ev := {"wind_world": [wind.x, wind.y, wind.z], "nodes": []}
	for item in (viewer.world as Node).find_children("*", "GeometryInstance3D", true, false):
		var node_name := str(item.name)
		var hit := false
		for prefix in TARGETS:
			if node_name.begins_with(prefix):
				hit = true
		if not hit:
			continue
		if item is MeshInstance3D:
			ev.nodes.append(_bind_mesh(viewer, item as MeshInstance3D, wind, cfg))
		elif item is MultiMeshInstance3D:
			ev.nodes.append(_bind_multimesh(item as MultiMeshInstance3D, wind, cfg))
	ev["materials"] = _material_notes
	return ev

# ------------------------------------------------------------ 合并网格：重建一份带 UV2 高度的网格
func _bind_mesh(viewer: Node3D, node: MeshInstance3D, wind: Vector3, cfg: Dictionary) -> Dictionary:
	var src_mesh := node.mesh
	if src_mesh == null:
		return {"node": str(node.name), "skipped": "no mesh"}
	var out := ArrayMesh.new()
	var xf := node.global_transform
	var max_h := 0.0
	var heights_by_surface: Array = []
	for s in src_mesh.get_surface_count():
		var arrays: Array = src_mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var hs := PackedFloat32Array()
		hs.resize(verts.size())
		for i in verts.size():
			var w: Vector3 = xf * verts[i]
			var ground := float(viewer.ground_surface.height_at(Vector2(-w.x, w.z)))
			hs[i] = maxf(w.y - ground, 0.0)
			max_h = maxf(max_h, hs[i])
		heights_by_surface.append(hs)
	# 相对高度：以本网格草高的 90% 分位作"草尖"，避免个别高点把其余都压扁
	var all_h: Array = []
	for hs in heights_by_surface:
		for v in hs:
			all_h.append(v)
	all_h.sort()
	var ref_h: float = maxf(all_h[int(all_h.size() * 0.9)] if not all_h.is_empty() else max_h, 0.005)
	var materials: Array = []
	for s in src_mesh.get_surface_count():
		var arrays: Array = src_mesh.surface_get_arrays(s)
		var hs: PackedFloat32Array = heights_by_surface[s]
		var uv2 := PackedVector2Array()
		uv2.resize(hs.size())
		for i in hs.size():
			uv2[i] = Vector2(hs[i], clampf(hs[i] / ref_h, 0.0, 1.0))
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat: Material = node.get_active_material(s)
		var wind_mat := _wind_material(mat, wind, cfg, 0.0)
		out.surface_set_material(s, wind_mat if wind_mat != null else mat)
		materials.append(wind_mat != null)
	node.mesh = out
	if node.material_override != null:
		var wm := _wind_material(node.material_override, wind, cfg, 0.0)
		if wm != null:
			node.material_override = wm
	for s in node.get_surface_override_material_count():
		var so := node.get_surface_override_material(s)
		if so != null:
			var wm2 := _wind_material(so, wind, cfg, 0.0)
			if wm2 != null:
				node.set_surface_override_material(s, wm2)
	# 摆动会让网格超出原包围盒一点，放宽剔除
	node.extra_cull_margin = maxf(node.extra_cull_margin, ref_h)
	return {"node": str(node.name), "kind": "mesh", "surfaces": src_mesh.get_surface_count(), "grass_top_u": ref_h, "max_h_u": max_h, "wind_materials": materials}

# ------------------------------------------------------------ MultiMesh：给共享网格加 UV2 局部高度
func _bind_multimesh(node: MultiMeshInstance3D, wind: Vector3, cfg: Dictionary) -> Dictionary:
	var mm := node.multimesh
	if mm == null or mm.mesh == null:
		return {"node": str(node.name), "skipped": "no multimesh"}
	var src := mm.mesh
	var out := ArrayMesh.new()
	var top := 0.0
	for s in src.get_surface_count():
		var verts: PackedVector3Array = src.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for v in verts:
			top = maxf(top, v.y)
	top = maxf(top, 0.001)
	for s in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uv2 := PackedVector2Array()
		uv2.resize(verts.size())
		for i in verts.size():
			var h := maxf(verts[i].y, 0.0)
			uv2[i] = Vector2(h, clampf(h / top, 0.0, 1.0))
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var sm := src.surface_get_material(s)
		if sm != null:
			out.surface_set_material(s, sm)
	mm.mesh = out
	var ok := false
	if node.material_override != null:
		var wm := _wind_material(node.material_override, wind, cfg, 1.0)
		if wm != null:
			node.material_override = wm
			ok = true
	node.extra_cull_margin = maxf(node.extra_cull_margin, 0.1)
	return {"node": str(node.name), "kind": "multimesh", "instances": mm.instance_count, "local_top": top, "wind_material": ok}

# ------------------------------------------------------------ StandardMaterial3D → 等价 ShaderMaterial + 风
# Godot 4.7 的 GDScript 取不到 BaseMaterial3D 生成的着色器源码（get_shader_rid 未开放），
# 所以用 lookdev_grass_wind_*.gdshader 这组等价着色器：高光开/关 × 剔除 双面/背面 四个变体，
# 其余外观参数逐项从原材质拷过来。
func _wind_material(mat: Material, wind: Vector3, cfg: Dictionary, height_mode: float) -> ShaderMaterial:
	var base := mat as BaseMaterial3D
	if base == null:
		return null
	var spec := "nospec" if base.specular_mode == BaseMaterial3D.SPECULAR_DISABLED else "spec"
	var cull := "back" if base.cull_mode == BaseMaterial3D.CULL_BACK else "disabled"
	var path := "res://tools/traveler/lookdev_baghdad/lookdev_grass_wind_%s_%s.gdshader" % [spec, cull]
	if not _shader_cache.has(path):
		_shader_cache[path] = load(path)
	var sm := ShaderMaterial.new()
	sm.shader = _shader_cache[path]
	sm.set_shader_parameter("albedo_color", base.albedo_color)
	sm.set_shader_parameter("use_texture", base.albedo_texture != null)
	if base.albedo_texture != null:
		sm.set_shader_parameter("texture_albedo", base.albedo_texture)
	sm.set_shader_parameter("use_vertex_color", base.vertex_color_use_as_albedo)
	sm.set_shader_parameter("vertex_color_is_srgb", base.vertex_color_is_srgb)
	sm.set_shader_parameter("uv1_scale", base.uv1_scale)
	sm.set_shader_parameter("uv1_offset", base.uv1_offset)
	sm.set_shader_parameter("roughness_v", base.roughness)
	sm.set_shader_parameter("specular_v", base.metallic_specular)
	sm.set_shader_parameter("use_backlight", base.backlight_enabled)
	sm.set_shader_parameter("backlight_color", Color(base.backlight.r, base.backlight.g, base.backlight.b))
	sm.set_shader_parameter("grass_wind_world", wind)
	sm.set_shader_parameter("grass_height_mode", height_mode)
	for key in ["sway_ratio", "gust_period", "wave_k", "rest_bend", "flutter", "flutter_hz"]:
		if cfg.has(key):
			sm.set_shader_parameter("grass_" + key, float(cfg[key]))
	sm.render_priority = mat.render_priority
	_material_notes.append({"shader": path.get_file(), "shading_mode": base.shading_mode, "diffuse_mode": base.diffuse_mode,
		"albedo_texture": base.albedo_texture != null, "normal_enabled": base.normal_enabled, "vertex_color": base.vertex_color_use_as_albedo,
		"srgb": base.vertex_color_is_srgb, "roughness": base.roughness, "backlight": base.backlight_enabled})
	return sm
