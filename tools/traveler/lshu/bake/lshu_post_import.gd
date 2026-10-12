@tool
extends EditorScenePostImport
## 第四幕「L叔在哪儿」· import-time edge data (fix #6: computed once per source mesh, never at runtime).
## Props (assets/traveler/lshu/props/*.glb): every mesh, including rotor children.
## Tiles (assets/traveler/lshu/tiles/proc_*.glb): only the nodes proc_<role> for the roles listed in
## look.json modules.edges.proc_roles. Same algorithm as the approved probe (scripts/traveler/lshu/lshu_edges.gd).
## Changing look.json modules.edges needs a re-import of these folders.

const EDGES: GDScript = preload("res://scripts/traveler/lshu/lshu_edges.gd")

func _post_import(scene: Node) -> Object:
	var source: String = get_source_file()
	var cfg: Dictionary = EDGES.edges_config()
	if cfg.is_empty():
		push_error("LSHU post-import: look.json modules.edges missing; " + source + " imported without edge data")
		return scene
	var crease_deg: float = float(cfg.get("crease_deg", 28.0))
	var proc_roles: Array = cfg.get("proc_roles", [])
	var is_tile: bool = source.begins_with("res://assets/traveler/lshu/tiles/")
	var stats: Dictionary = {}
	var cache: Dictionary = {}
	for node: Node in scene.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node as MeshInstance3D
		if mi.mesh == null:
			continue
		if is_tile:
			var role: String = str(mi.name).trim_prefix("proc_")
			if not proc_roles.has(role):
				continue
		var key: int = mi.mesh.get_instance_id()
		if not cache.has(key):
			cache[key] = EDGES.process_mesh(mi.mesh as ArrayMesh, crease_deg, stats)
		var out: ArrayMesh = cache[key]
		if out != null:
			mi.mesh = out
	scene.set_meta("lshu_edges", {"crease_deg": crease_deg, "meshes": int(stats.get("meshes", 0)), "triangles": int(stats.get("triangles", 0)), "creases": int(stats.get("creases", 0))})
	return scene
