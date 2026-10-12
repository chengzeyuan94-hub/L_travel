extends RefCounted
## 第四幕「L叔在哪儿」· surface detail binding (look.json modules.surface_detail). Global rules only.
##  - binds the tile's ground maps (precomputed cell colour texture, path distance texture, ground height range)
##    to every role in map_roles, and the height field to every role whose shader samples it
##  - procedural water: instance uniform l2_level (continuous depth colour + shore foam in lshu_water.gdshader);
##    the water_side role gets l2_water_level; the web's dashed foam strips are hidden when hide_proc_foam
##  - per light preset: l2_sun_dir on every role whose shader has it; ripple overlay visibility
## Role materials are shared by all tiles, so bind_tile() runs in the same frame the tile becomes visible.

## Per-tile inputs. tile: the assembled tile node (lshu_tile_assembler.gd).
static func bind_tile(look: RefCounted, tile: Node3D) -> Dictionary:
	var cfg: Dictionary = look.call("module_cfg", "surface_detail")
	var maps: Dictionary = tile.get("ground_maps")
	var height_texture: ImageTexture = tile.get("height_texture")
	var grid_n: int = int(tile.get("terrain_n")) + 1
	var materials: Dictionary = look.get("materials")
	for role: String in materials.keys():
		look.call("set_role_uniform", role, "height_tex", height_texture)
		look.call("set_role_uniform", role, "height_rect", Vector4(-4.0, -4.0, 8.0, 8.0))
		look.call("set_role_uniform", role, "height_grid_n", float(grid_n))
	var bound: Array[String] = []
	if not maps.is_empty():
		for r: Variant in cfg.get("map_roles", ["ground", "skirt", "cliff"]):
			var role: String = str(r)
			look.call("set_role_uniform", role, "l2_ground_col_tex", maps.get("color_tex"))
			look.call("set_role_uniform", role, "l2_path_tex", maps.get("path_tex"))
			look.call("set_role_uniform", role, "l2_ground_range", maps.get("ground_range", Vector2(0.0, 1.0)))
			look.call("set_role_uniform", role, "l2_maps_ready", 1.0)
			bound.append(role)
	var level: float = float(maps.get("water_level", -100.0))
	var nodes: Dictionary = tile.get("proc_nodes")
	var water_set: bool = false
	if level > -50.0 and nodes.has("water"):
		(nodes["water"] as MeshInstance3D).set_instance_shader_parameter("l2_level", level)
		water_set = true
	look.call("set_role_uniform", "water_side", "l2_water_level", level if level > -50.0 else 0.0)
	var foam_hidden: bool = false
	if bool(cfg.get("hide_proc_foam", false)) and nodes.has("foam"):
		(nodes["foam"] as Node3D).visible = false
		foam_hidden = true
	return {"bound_roles": bound, "water_level": level, "water_depth_shader": water_set, "proc_foam_hidden": foam_hidden, "maps": "offline (tile JSON precompute.ground_info)"}

## Per light preset (after look.apply()).
static func on_light(look: RefCounted, sun: DirectionalLight3D, tile: Node3D) -> void:
	var cfg: Dictionary = look.call("module_cfg", "surface_detail")
	var to_sun: Vector3 = sun.global_transform.basis.z.normalized()
	var materials: Dictionary = look.get("materials")
	for role: String in materials.keys():
		look.call("set_role_uniform", role, "l2_sun_dir", to_sun)
	var nodes: Dictionary = tile.get("proc_nodes")
	if nodes.has("ripple"):
		var rv: Dictionary = cfg.get("ripple_visible", {})
		(nodes["ripple"] as Node3D).visible = bool(rv.get(str(look.get("light_name")), rv.get("default", true)))
