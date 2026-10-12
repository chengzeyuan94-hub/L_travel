extends "res://tools/lowpoly/ground_023_preview.gd"
## Isolated style experiment: identical rejected geometry, two normal treatments.
const ARCHIVE := "/Users/chengzeyuan/SilkRoadEvidence/ground-detail-023/soft-surface-rejected/library"
var _facet_pairs: Array[Dictionary] = []

func _ready() -> void:
	super._ready()
	OUTPUT = "/Users/chengzeyuan/SilkRoadEvidence/ground-detail-023/normals-probe"
	_mode = "capture"
	_ground_plan = JSON.parse_string(FileAccess.get_file_as_string(ARCHIVE.path_join("placements.json")))
	_ground_specs.clear()
	_prop_adjustments.clear()
	for row: Dictionary in _ground_plan["landmarks"]: _ground_specs[row["id"]] = row
	for row: Dictionary in _ground_plan["props"]: _prop_adjustments[row["id"]] = row
	_transition_views = [
		{"id":"city_delhi", "title":"德里", "logical":[2117.5,578], "zoom":2.6},
		{"id":"plain", "title":"平原", "logical":[2305,658], "zoom":3.8},
		{"id":"dunes", "title":"沙地", "logical":[2218,407], "zoom":3.6},
	]

func _load_scene(path: String, linear_colors: bool) -> Node3D:
	var ground := path.ends_with("/ground.glb")
	var model := super._load_scene(ARCHIVE.path_join("exports/ground.glb") if ground else path, linear_colors)
	if not ground or model == null: return model
	for child in model.find_children("spherical_continents_and_biomes*", "MeshInstance3D", true, false):
		var node := child as MeshInstance3D
		var original := node.mesh
		var facet := ArrayMesh.new()
		for surface in original.get_surface_count():
			var arrays := original.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			var order: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if order.is_empty():
				for i in vertices.size(): order.append(i)
			var new_vertices := PackedVector3Array()
			var new_normals := PackedVector3Array()
			var new_colors := PackedColorArray()
			for t in range(0,order.size(),3):
				var a := order[t]
				var b := order[t+1]
				var c := order[t+2]
				var face := (vertices[b]-vertices[a]).cross(vertices[c]-vertices[a]).normalized()
				if face.dot(normals[a]+normals[b]+normals[c]) < 0: face = -face
				for i in [a,b,c]:
					new_vertices.append(vertices[i])
					new_normals.append(normals[i].lerp(face,0.75).normalized())
					new_colors.append(colors[i])
			var result := []
			result.resize(Mesh.ARRAY_MAX)
			result[Mesh.ARRAY_VERTEX] = new_vertices
			result[Mesh.ARRAY_NORMAL] = new_normals
			result[Mesh.ARRAY_COLOR] = new_colors
			facet.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,result)
			facet.surface_set_material(surface,original.surface_get_material(surface))
		_facet_pairs.append({"node":node,"soft":original,"faceted":facet})
	return model

func _capture_all() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	_freeze_detail_stills()
	for actor in (_board.get("_pieces") as Dictionary).values(): (actor as Node).process_mode = Node.PROCESS_MODE_DISABLED
	_set_phase("after")
	var rows := []
	for treatment in ["soft","faceted"]:
		for pair: Dictionary in _facet_pairs: (pair["node"] as MeshInstance3D).mesh = pair[treatment]
		for view: Dictionary in _transition_views:
			_focus_view(view)
			await _frames(16)
			await RenderingServer.frame_post_draw
			var path := OUTPUT.path_join(String(view["id"]) + "-" + treatment + ".png")
			assert(get_viewport().get_texture().get_image().save_png(path) == OK)
			rows.append({"view":view,"treatment":treatment,"path":path,"sha256":FileAccess.get_sha256(path),"camera":_layout_evidence()["camera_transform"]})
	var file := FileAccess.open(OUTPUT.path_join("probe.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"method":"Same archived geometry/colors/camera/light. Only land normals lerp 75% towards actual triangle normals; no vertex position change.","source_glb_sha256":FileAccess.get_sha256(ARCHIVE.path_join("exports/ground.glb")),"script_sha256":FileAccess.get_sha256("res://tools/lowpoly/ground_023_normals_probe.gd"),"captures":rows},"\t"))
	AudioManager.silence_all()
	print("NORMALS_PROBE_COMPLETE ",rows.size())
	get_tree().quit()
