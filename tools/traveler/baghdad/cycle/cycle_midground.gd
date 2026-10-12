extends RefCounted
## 雨世界（A）的中景沙地对齐：Codex 的雨景中景是一块光板，这里补上晚霞世界已认可的沙脊和碎石散布。
##
## 直接复用晚霞探针的两个图层（lookdev_extra_drift.gd / lookdev_extra_scatter.gd，参数与 t_combo_geo 相同），
## 生成后按雨世界的约定改造：
## - 雨世界的地面被 Codex 的 storm_surface 翻正了三角绕序（法线朝上、cull_back）；晚霞图层是按旧绕序做的，
##   所以沙脊与沙斑贴片要翻转绕序，再换成 cycle_wet_ridge.gdshader（顶点色 × 雨世界沙色 + 同一套湿润公式）；
## - 碎石换成湿润版本（更暗、更光滑）。
const DRIFT := "res://tools/traveler/lookdev_baghdad/lookdev_extra_drift.gd"
const SCATTER := "res://tools/traveler/lookdev_baghdad/lookdev_extra_scatter.gd"
const RIDGE_SHADER := "res://tools/traveler/baghdad/cycle/cycle_wet_ridge.gdshader"

func build(viewer: Node3D, drift_cfg: Dictionary, scatter_cfg: Dictionary, wet: Dictionary) -> Dictionary:
	var ev := {}
	ev["drift"] = load(DRIFT).new().build(viewer, drift_cfg)
	ev["scatter"] = load(SCATTER).new().build(viewer, scatter_cfg)
	var shader: Shader = load(RIDGE_SHADER)
	var converted: Array = []
	for node_name in ["LookdevDriftRidges", "ScatterSandPatches"]:
		var node := viewer.world.find_child(node_name, true, false) as MeshInstance3D
		if node == null or node.mesh == null:
			continue
		node.mesh = _flipped(node.mesh)
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("wetness", float(wet.get("wetness", 0.92)))
		node.material_override = mat
		converted.append(node_name)
	var pebbles := viewer.world.find_child("ScatterPebbles", true, false) as GeometryInstance3D
	if pebbles != null and pebbles.material_override is StandardMaterial3D:
		var m := (pebbles.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
		var k := float(wet.get("pebble_darken", 0.72))
		m.albedo_color = Color(m.albedo_color.r * k, m.albedo_color.g * k, m.albedo_color.b * k, 1.0)
		m.roughness = float(wet.get("pebble_roughness", 0.38))
		m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
		m.metallic_specular = float(wet.get("pebble_specular", 0.5))
		pebbles.material_override = m
		converted.append("ScatterPebbles(wet)")
	ev["converted_for_rain_world"] = converted
	return ev

func _flipped(src: Mesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(s)
		var idx = arrays[Mesh.ARRAY_INDEX]
		if idx != null and (idx as PackedInt32Array).size() > 0:
			var ind: PackedInt32Array = idx
			for t in range(0, ind.size() - 2, 3):
				var tmp := ind[t + 1]
				ind[t + 1] = ind[t + 2]
				ind[t + 2] = tmp
			arrays[Mesh.ARRAY_INDEX] = ind
		else:
			var n: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			for a in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
				if arrays[a] == null:
					continue
				var arr = arrays[a]
				for t in range(0, n - 2, 3):
					var tmp = arr[t + 1]
					arr[t + 1] = arr[t + 2]
					arr[t + 2] = tmp
				arrays[a] = arr
			arrays[Mesh.ARRAY_TANGENT] = null
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out
