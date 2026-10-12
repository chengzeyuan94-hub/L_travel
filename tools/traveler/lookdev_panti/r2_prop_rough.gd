extends RefCounted
## r2 · 营地道具静态材质参数 extra script（探针，不是交付代码）。
## 背景（实测）：variant 的 "materials": {"Stump": …, "Tent": …} 让 watcher 给这两个节点再挂一份 material_override
## （复制自 a_extra_rim.gd 已经挂了轮廓 next_pass 的表面覆盖材质，next_pass 共用）。渲染结果正确，但退出时引擎报
## 8 条 'ERROR: Parameter "material" is null'（material_casts_shadows / is_animated / … 各 2 次），新的跑批器把它算 errs=8。
## 这两个值清晨 / 深夜相同（不需要插值），所以改成在 a_extra_rim.gd 之后直接写进节点当前生效的材质：
## 有 material_override 写 override，否则写表面覆盖材质（没有就先复制一份再设为表面覆盖，不改共享的网格资源）。
## cfg: {"nodes": {"Stump": {"roughness": 0.75}, "Tent": {"roughness": 0.85}}}

func build(host: Node3D, cfg: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var nodes: Dictionary = cfg.get("nodes", {})
	for n_v: Variant in nodes.keys():
		var nm: String = str(n_v)
		var props: Dictionary = nodes[n_v]
		var node: MeshInstance3D = host.world.find_child(nm, true, false) as MeshInstance3D
		if node == null or node.mesh == null:
			out[nm] = -1
			continue
		var count: int = 0
		if node.material_override is BaseMaterial3D:
			_apply_props(node.material_override as BaseMaterial3D, props)
			count += 1
		else:
			for s: int in node.mesh.get_surface_count():
				var own: Material = node.get_surface_override_material(s)
				if own == null:
					var src: Material = node.get_active_material(s)
					if src == null:
						continue
					own = src.duplicate() as Material
					node.set_surface_override_material(s, own)
				if own is BaseMaterial3D:
					_apply_props(own as BaseMaterial3D, props)
					count += 1
		out[nm] = count
	return out

func _apply_props(mat: BaseMaterial3D, props: Dictionary) -> void:
	for k_v: Variant in props.keys():
		mat.set(str(k_v), props[k_v])
