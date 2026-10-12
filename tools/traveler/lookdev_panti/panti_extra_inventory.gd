extends RefCounted
## 盘点：把场景里的灯、几何体材质、shader 列成 JSON 打印出来（探针用）。
func build(host: Node3D, _cfg: Dictionary) -> Dictionary:
	var geo: Array = []
	for item in host.find_children("*", "GeometryInstance3D", true, false):
		var gi := item as GeometryInstance3D
		var rec := {"path": str(host.get_path_to(gi)), "class": gi.get_class(), "visible": gi.is_visible_in_tree(), "cast": gi.cast_shadow, "layers": gi.layers}
		var mats: Array = []
		var list: Array = [gi.material_override]
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
			var mi := gi as MeshInstance3D
			rec["surfaces"] = mi.mesh.get_surface_count()
			rec["aabb"] = str(mi.get_aabb().size)
			for s in mi.mesh.get_surface_count():
				list.append(mi.get_active_material(s))
		if gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null:
			var mm := (gi as MultiMeshInstance3D).multimesh
			rec["instances"] = mm.instance_count
			if mm.mesh != null:
				for s in mm.mesh.get_surface_count():
					list.append(mm.mesh.surface_get_material(s))
		for m in list:
			var cur: Material = m
			var chain: Array = []
			while cur != null:
				if cur is ShaderMaterial:
					chain.append("S:" + ((cur as ShaderMaterial).shader.resource_path if (cur as ShaderMaterial).shader != null else "?"))
				elif cur is StandardMaterial3D:
					var sm := cur as StandardMaterial3D
					chain.append("Std:alb=%s tex=%s vc=%s rough=%.2f metal=%.2f spec=%.2f shade=%d em=%s" % [sm.albedo_color.to_html(false), sm.albedo_texture != null, sm.vertex_color_use_as_albedo, sm.roughness, sm.metallic, sm.metallic_specular, sm.shading_mode, sm.emission_enabled])
				else:
					chain.append(cur.get_class())
				cur = cur.next_pass
			mats.append(chain)
		rec["mats"] = mats
		geo.append(rec)
	var lights: Array = []
	for item in host.find_children("*", "Light3D", true, false):
		var l := item as Light3D
		var r := {"path": str(host.get_path_to(l)), "class": l.get_class(), "visible": l.is_visible_in_tree(), "energy": l.light_energy, "color": l.light_color.to_html(false), "shadow": l.shadow_enabled, "mask": l.light_cull_mask, "spec": l.light_specular, "pos": str(l.global_position)}
		if l is OmniLight3D:
			r["range"] = (l as OmniLight3D).omni_range
		lights.append(r)
	var env: Environment = host.environment
	var e := {}
	for k in ["background_mode","ambient_light_source","ambient_light_energy","ambient_light_sky_contribution","tonemap_mode","tonemap_exposure","tonemap_white","glow_enabled","glow_intensity","glow_bloom","glow_hdr_threshold","ssao_enabled","ssil_enabled","ssr_enabled","sdfgi_enabled","fog_enabled","fog_density","volumetric_fog_enabled","adjustment_enabled","reflected_light_source"]:
		e[k] = env.get(k)
	var out := {"geo": geo, "lights": lights, "env": e, "sun_rot_deg": str(host.sun.rotation_degrees), "sun_shadow": host.sun.shadow_enabled, "camera": str(host.camera.global_transform)}
	var f := FileAccess.open("res://docs/reports/traveler-panti-light-20260923/inventory_%s.json" % str(host.get("lighting_period")), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	return {"geo": geo.size(), "lights": lights.size()}
