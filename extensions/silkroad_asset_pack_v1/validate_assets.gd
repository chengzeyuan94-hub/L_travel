extends SceneTree
const Assets := preload("res://extensions/silkroad_asset_pack_v1/asset_loader.gd")
func _initialize() -> void:
	var errors: Array[String] = []
	var report := {"models": {}, "icons": {}, "city_goods": {}}
	var definitions := Assets.manifest()
	for category in ["cities", "pieces"]:
		for id in definitions.get(category, {}):
			var model := Assets.create_model(category, id)
			if model == null:
				errors.append("Failed model: " + id)
				continue
			var meshes := _meshes(model)
			report.models[id] = {"mesh_instances": meshes, "loaded": true}
			if meshes == 0: errors.append("Empty model: " + id)
			model.free()
	for id in definitions.get("goods", {}):
		var texture := Assets.good_icon(id)
		if texture == null:
			errors.append("Failed icon: " + id)
		else:
			report.icons[id] = {"width": texture.get_width(), "height": texture.get_height(), "alpha": texture.get_image().detect_alpha() != Image.ALPHA_NONE}
	for id in definitions.get("cities", {}):
		var good := str(definitions.cities[id].specialty)
		report.city_goods[id] = good
		if not definitions.goods.has(good): errors.append("Missing specialty: " + id)
	report["ok"] = errors.is_empty()
	report["errors"] = errors
	print("ASSET_PACK_VALIDATION ", JSON.stringify(report))
	quit(0 if errors.is_empty() else 1)
func _meshes(node: Node) -> int:
	var count := 1 if node is MeshInstance3D else 0
	for child in node.get_children(): count += _meshes(child)
	return count
