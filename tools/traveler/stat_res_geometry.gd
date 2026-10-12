extends SceneTree

## Dump geometry statistics for every mesh .res under a directory.
## Run it in each project and diff the two JSONs: bytes may differ (the binary
## embeds its own dependency paths) but the geometry must not.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var dir_path := "res://generated/traveler/atlas/meshes"
	var out := "res://res_stats.json"
	for a in args:
		if a.begins_with("--dir="):
			dir_path = a.trim_prefix("--dir=")
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	var d := DirAccess.open(dir_path)
	var names: Array[String] = []
	if d:
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if n.ends_with(".res"):
				names.append(n)
			n = d.get_next()
	names.sort()
	var stats := {}
	var failed := 0
	for n in names:
		var m: Mesh = ResourceLoader.load(dir_path + "/" + n, "", ResourceLoader.CACHE_MODE_IGNORE) as Mesh
		if m == null:
			failed += 1
			continue
		var surf := m.get_surface_count()
		var verts := 0
		var idx := 0
		for i in surf:
			var arr := m.surface_get_arrays(i)
			verts += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var ii = arr[Mesh.ARRAY_INDEX]
			if ii != null:
				idx += (ii as PackedInt32Array).size()
		var ab := m.get_aabb()
		stats[n] = "%d|%d|%d|%.4f,%.4f,%.4f,%.4f,%.4f,%.4f" % [surf, verts, idx,
			ab.position.x, ab.position.y, ab.position.z, ab.size.x, ab.size.y, ab.size.z]
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(stats, "", true, true))
	f.close()
	print("STAT_RES ", JSON.stringify({"dir": dir_path, "files": names.size(), "stats": stats.size(), "load_failed": failed}))
	quit(0)
