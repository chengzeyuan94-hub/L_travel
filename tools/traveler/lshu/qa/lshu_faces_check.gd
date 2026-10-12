extends SceneTree
## 第四幕 QA (repair_r2): for tiles loaded the way the director loads them (time-sliced, budget 6 ms), the collision triangles
## the assembler made on its worker (faces_for) must equal Mesh.get_faces() exactly, for every merged shadow mesh and
## procedural part. Last line: LSHU_FACES_CHECK tiles=T meshes=M precomputed=P mismatches=X
var viewport: SubViewport
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var pool: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/lshu/pool.json"))
	var ids: Array[String] = []
	var n_tiles: int = 40
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--tiles="):
			n_tiles = int(a.trim_prefix("--tiles="))
	var all: Array = pool.tiles
	for i: int in all.size():
		if i % maxi(1, all.size() / n_tiles) == 0 and ids.size() < n_tiles:
			ids.append(str((all[i] as Dictionary).id))
	viewport = SubViewport.new()
	viewport.size = Vector2i(640, 360)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene: Node3D = (load("res://scenes/traveler/lshu_main.tscn") as PackedScene).instantiate() as Node3D
	scene.set("director_mode", "off")
	scene.set("extra_args", PackedStringArray(["--tile=" + ids[0], "--light=day", "--park=26"]))
	viewport.add_child(scene)
	while scene.get("tile") == null:
		await process_frame
	var meshes_n: int = 0
	var pre_n: int = 0
	var bad: Array = []
	for id: String in ids:
		await scene.call("load_tile", id, 6.0)
		var tile: Node3D = scene.get("tile")
		var n: int = 0
		while not bool(tile.call("faces_ready")) and n < 600:
			await process_frame
			n += 1
		var list: Array[MeshInstance3D] = []
		for s: Variant in tile.get("shadow_nodes"):
			list.append(s as MeshInstance3D)
		for pv: Variant in (tile.get("proc_nodes") as Dictionary).values():
			list.append(pv as MeshInstance3D)
		for mi: MeshInstance3D in list:
			meshes_n += 1
			var pre: Variant = tile.call("faces_for", mi)
			if not pre is PackedVector3Array:
				continue
			pre_n += 1
			var ref: PackedVector3Array = mi.mesh.get_faces()
			if (pre as PackedVector3Array) != ref:
				bad.append({"tile": id, "mesh": str(mi.name), "pre": (pre as PackedVector3Array).size(), "ref": ref.size()})
		print("FACES_TILE ", id, " meshes=", list.size())
	print("LSHU_FACES_CHECK tiles=%d meshes=%d precomputed=%d mismatches=%d %s" % [ids.size(), meshes_n, pre_n, bad.size(), JSON.stringify(bad)])
	quit(0 if bad.is_empty() and pre_n > 0 else 1)
