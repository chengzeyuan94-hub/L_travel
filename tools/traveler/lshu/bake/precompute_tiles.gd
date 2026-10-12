extends SceneTree
## 第四幕「L叔在哪儿」· offline precompute (fix #6): ground information and scatter instances for every baked
## tile, appended to data/traveler/lshu/tiles/<id>.json as the key "precompute". Runs headless after
## bake_recipes.cjs and --import. Same algorithms and seeds as the approved probe (scripts/traveler/lshu/
## lshu_ground_info.gd, lshu_scatter.gd); the scene only uploads the stored buffers.
##
##   Godot --headless --path . --script res://tools/traveler/lshu/bake/precompute_tiles.gd -- [--tiles=A,B] [--check]
##         [--pool-file=PATH]
##   --check      compute in memory and compare with the stored precompute; exit 1 on any difference
##   --pool-file  read the tile list from PATH (a staged pool) instead of data/traveler/lshu/pool.json
## Written files carry no timings, so the output is byte-identical for identical inputs.

const LOOK_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_look.gd")
const ASSEMBLER_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_tile_assembler.gd")
const GROUND_INFO_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_ground_info.gd")
const SCATTER_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_scatter.gd")
const POOL_PATH: String = "res://data/traveler/lshu/pool.json"
const MARKER: String = ",\"precompute\":"
const NON_FOOTPRINT_ROLES: Array[String] = ["ground", "skirt", "water", "water_side", "foam", "ripple", "grass"]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var only: Array[String] = []
	var check: bool = false
	var pool_path: String = POOL_PATH
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--tiles="):
			for id: String in arg.trim_prefix("--tiles=").split(",", false):
				only.append(id)
		elif arg == "--check":
			check = true
		elif arg.begins_with("--pool-file="):
			pool_path = arg.trim_prefix("--pool-file=")
	var look: RefCounted = LOOK_SCRIPT.new()
	if not look.call("load_look") or not look.call("set_light", "day"):
		quit(1)
		return
	var pool: Variant = JSON.parse_string(FileAccess.get_file_as_string(pool_path))
	if not pool is Dictionary:
		push_error("LSHU precompute: pool list invalid: " + pool_path)
		quit(1)
		return
	var ids: Array[String] = []
	for t: Variant in (pool as Dictionary).get("tiles", []):
		var id: String = str((t as Dictionary).get("id", ""))
		if only.is_empty() or only.has(id):
			ids.append(id)
	var scatter_cfg: Dictionary = look.call("module_cfg", "scatter")
	var cfg_sha: String = JSON.stringify(scatter_cfg, "", true).sha256_text().substr(0, 16)
	var failures: int = 0
	for id: String in ids:
		var t0: int = Time.get_ticks_usec()
		var asm: Node3D = ASSEMBLER_SCRIPT.new() as Node3D
		root.add_child(asm)
		asm.call("prepare", id)
		var ok: bool = await asm.call("build", look, true, 0.0, true)
		if not ok:
			failures += 1
			asm.free()
			continue
		var tile: Dictionary = asm.get("tile")
		var proc_nodes: Dictionary = asm.get("proc_nodes")
		var instance_nodes: Array[Dictionary] = asm.get("instance_nodes")
		var footprints: Array[MeshInstance3D] = []
		for rec: Dictionary in instance_nodes:
			for mi: MeshInstance3D in rec.meshes:
				footprints.append(mi)
		for role: String in proc_nodes.keys():
			if not NON_FOOTPRINT_ROLES.has(role):
				footprints.append(proc_nodes[role] as MeshInstance3D)
		var gi: RefCounted = GROUND_INFO_SCRIPT.new()
		gi.call("compute", tile, proc_nodes.get("ground") as MeshInstance3D, footprints)
		var sc: RefCounted = SCATTER_SCRIPT.new()
		var scatter_rec: Dictionary = sc.call("compute", tile, gi, instance_nodes, scatter_cfg)
		var pre: Dictionary = {"schema": "lshu.precompute.v1", "scatter_cfg_sha256_16": cfg_sha, "ground_info": gi.call("to_record"), "scatter": scatter_rec}
		var path: String = ASSEMBLER_SCRIPT.call("tile_path", id)
		var text: String = FileAccess.get_file_as_string(path)
		var cut: int = text.find(MARKER)
		var head: String = text.substr(0, cut) if cut >= 0 else text.substr(0, text.length() - 1)
		if not head.begins_with("{") or (cut < 0 and not text.ends_with("}")):
			push_error("LSHU precompute: unexpected tile JSON layout " + path)
			failures += 1
			asm.free()
			continue
		var out: String = head + MARKER + JSON.stringify(pre) + "}"
		var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
		if check:
			var same: bool = out == text
			if not same:
				failures += 1
			print("PRECOMPUTE_CHECK ", id, " same=", same, " scatter=", scatter_rec.get("total", 0))
		elif out != text:
			var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
			f.store_string(out)
			f.close()
			print("PRECOMPUTE ", id, " scatter=", scatter_rec.get("total", 0), " counts=", JSON.stringify(scatter_rec.get("counts", {})), " written ", "%.0f" % ms, "ms")
		else:
			print("PRECOMPUTE ", id, " unchanged ", "%.0f" % ms, "ms")
		asm.free()
	print("PRECOMPUTE_DONE tiles=", ids.size(), " failures=", failures)
	quit(1 if failures > 0 else 0)
