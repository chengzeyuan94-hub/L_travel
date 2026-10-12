extends RefCounted
## bounce 线 · 长安日暮"反光" extra script（探针，不是交付代码）。
## 依赖 surface 节已把 atlas_surface 材质换成 atlas_surface_dusk_bounce.gdshader（overlay 先跑 surface，再跑 extra）。
## 做四件事：
##   1. 琉璃瓦：只给寺庙 Cities/changan/changan 的 surface 0（Atlas_solid）打开 glaze_enable，写 glaze_center。
##      Atlas_solid 是所有城市共用的材质，所以着色器里还有 glaze_center/glaze_radius 的世界球遮罩，其他城市不受影响。
##   2. 灯下暖反光：按寺庙位置 + 朝相机的水平方向算出院心，写进全部 atlas 材质的 lamp_bounce_pos。
##   3. 雪面柔光：给 FarBackdrop/MassifBandMerged 的 material_override 挂 bounce_snow_sheen.gdshader（接在已有 next_pass 链的末尾，不覆盖别人的 pass）。
##   4. 人物腿部暖反光：人物异步生成，交给 changan_extra_bounce_watch.gd 等人物就位后，挂一盏只照人物层（CHARACTER_LIGHT_LAYER）的暖色小灯，贴地跟随。
## cfg.cliff_rig: {"path", "layer", "lights": [{"color", "energy", "dir": {"right", "up", "toward_cam"}}]}
## cfg: {"temple_path", "glaze_center_lift", "court_offset", "court_lift",
##       "snow": {bounce_snow_sheen 的 uniform}, "character": {"energy", "range", "color", "toward_court", "lift", "attenuation"}}
const SNOW_SHADER := "res://tools/traveler/lookdev_changan/bounce_snow_sheen.gdshader"
const WATCH := "res://tools/traveler/lookdev_changan/changan_extra_bounce_watch.gd"

func _v(v: Variant) -> Variant:
	if v is Array:
		var a: Array = v
		if a.size() == 2:
			return Vector2(float(a[0]), float(a[1]))
		if a.size() >= 3:
			return Color(float(a[0]), float(a[1]), float(a[2]))
	return v

func build(host: Node3D, cfg: Dictionary) -> Dictionary:
	var out := {}
	var sun_dir: Vector3 = (host.sun as DirectionalLight3D).global_basis.z.normalized()
	# 1 + 2：寺庙与院心
	var temple := host.world.get_node_or_null(NodePath(str(cfg.get("temple_path", "Cities/changan/changan")))) as MeshInstance3D
	if temple == null:
		out["temple"] = "missing"
	else:
		var tp: Vector3 = temple.global_position
		var to_cam: Vector3 = host.camera.global_position - tp
		to_cam.y = 0.0
		to_cam = to_cam.normalized()
		var court: Vector3 = tp + to_cam * float(cfg.get("court_offset", 1.4)) + Vector3.UP * float(cfg.get("court_lift", 0.0))
		for m in host.material_list:
			(m as ShaderMaterial).set_shader_parameter("lamp_bounce_pos", court)
		var solid := temple.get_active_material(0) as ShaderMaterial
		var glaze_center: Vector3 = tp + Vector3.UP * float(cfg.get("glaze_center_lift", 0.8))
		if solid != null:
			solid.set_shader_parameter("glaze_enable", 1.0)
			solid.set_shader_parameter("glaze_center", glaze_center)
		out["temple"] = {"pos": [tp.x, tp.y, tp.z], "court": [court.x, court.y, court.z], "solid": solid.resource_name if solid != null else "none",
			"surfaces": temple.mesh.get_surface_count(), "aabb_world_size": [temple.get_aabb().size.x * temple.global_basis.get_scale().x, temple.get_aabb().size.y * temple.global_basis.get_scale().y]}
	# 3：雪面柔光
	var massif := host.world.get_node_or_null("FarBackdrop/MassifBandMerged") as MeshInstance3D
	if massif == null or massif.material_override == null:
		out["snow"] = "missing"
	elif cfg.has("snow"):
		var sm := ShaderMaterial.new()
		sm.shader = load(SNOW_SHADER)
		for k in cfg.snow.keys():
			sm.set_shader_parameter(k, _v(cfg.snow[k]))
		sm.set_shader_parameter("sun_dir_world", sun_dir)
		var tail: Material = massif.material_override
		var depth := 0
		while tail.next_pass != null and depth < 8:
			tail = tail.next_pass
			depth += 1
		tail.next_pass = sm
		out["snow"] = {"chain_depth": depth + 1}
	# 5：山崖佛窟（StandardMaterial3D，不走 atlas 着色器）的反光：把 CliffBuddha 的网格加进专用可见层（默认 1<<16），
	#    再放几盏只照这一层、不投影的平行光——暖的从院子 / 地面方向往上打（地面反光），冷的从天顶打（天光反光）。
	#    方向用相机系写：{"right", "up", "toward_cam"}，指的是"从表面指向光源"。
	if cfg.has("cliff_rig"):
		var rig: Dictionary = cfg.cliff_rig
		var bit := int(rig.get("layer", 1 << 16))
		var root: Node = host.world.get_node_or_null(NodePath(str(rig.get("path", "CliffBuddha"))))
		var meshes := 0
		if root != null:
			var list: Array = root.find_children("*", "MeshInstance3D", true, false)
			if root is MeshInstance3D:
				list.append(root)
			for mi in list:
				(mi as MeshInstance3D).layers |= bit
				meshes += 1
		var fwd: Vector3 = -host.camera.global_basis.z
		fwd.y = 0.0
		var to_cam_h: Vector3 = -fwd.normalized()
		var right_h: Vector3 = host.camera.global_basis.x
		right_h.y = 0.0
		right_h = right_h.normalized()
		var made := 0
		for spec in rig.get("lights", []):
			var d: Dictionary = spec.get("dir", {})
			var to_light: Vector3 = (right_h * float(d.get("right", 0.0)) + Vector3.UP * float(d.get("up", 0.0)) + to_cam_h * float(d.get("toward_cam", 0.0))).normalized()
			var l := DirectionalLight3D.new()
			l.name = "BounceRig%d" % made
			l.light_cull_mask = bit
			var c: Array = spec.get("color", [1.0, 0.6, 0.35])
			l.light_color = Color(float(c[0]), float(c[1]), float(c[2]))
			l.light_energy = float(spec.get("energy", 0.2))
			l.light_specular = 0.0
			l.shadow_enabled = false
			l.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
			host.world.add_child(l)
			l.look_at(l.global_position - to_light, Vector3.UP if absf(to_light.y) < 0.95 else Vector3.RIGHT)
			made += 1
		out["cliff_rig"] = {"meshes": meshes, "lights": made, "layer": bit}
	# 4：人物暖反光（异步）
	if cfg.has("character"):
		var w: Node = load(WATCH).new()
		w.name = "BounceCharacterWatch"
		w.set("host", host)
		w.set("spec", cfg.character)
		host.add_child(w)
		out["character"] = "deferred"
	var names: Array = []
	for c in host.world.get_children():
		names.append(str(c.name))
	out["world_children"] = names
	out["materials"] = host.material_list.size()
	return out
