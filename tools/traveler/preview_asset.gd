extends SceneTree
## 通用资产四视预览。用法：
##   godot --path . --script res://tools/traveler/preview_asset.gd -- \
##       --asset=res://assets/traveler/characters/chibi-raw.glb \
##       --out=/abs/path/prefix
## 产出 prefix-{front,left,back,right}.png 与 prefix.json（三角数、bbox、材质、每视图尺寸）。
## 正交、中性灰底、随视角旋转的三点光，只为看形体，不代表场景观感。

const VIEWS := ["front", "left", "back", "right"]

var asset_path := ""
var out_prefix := ""
var size_px := Vector2i(1920, 1080)
var anim_name := ""
var anim_at := 0.0
var seq_out := ""
var seq_fps := 30.0
var seq_yaw := 0.72


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--asset="):
			asset_path = a.trim_prefix("--asset=")
		elif a.begins_with("--out="):
			out_prefix = a.trim_prefix("--out=")
		elif a.begins_with("--anim="):
			anim_name = a.trim_prefix("--anim=")
		elif a.begins_with("--at="):
			anim_at = float(a.trim_prefix("--at="))
		elif a.begins_with("--seq="):
			seq_out = a.trim_prefix("--seq=")
		elif a.begins_with("--fps="):
			seq_fps = float(a.trim_prefix("--fps="))
		elif a.begins_with("--yaw="):
			seq_yaw = float(a.trim_prefix("--yaw="))
	if asset_path.is_empty() or (out_prefix.is_empty() and seq_out.is_empty()):
		push_error("需要 --asset= 与 --out=")
		quit(1)
		return
	call_deferred("run")


func run() -> void:
	var packed: PackedScene = load(asset_path)
	if packed == null:
		print("[PREVIEW] 加载失败 ", asset_path)
		quit(1)
		return

	var vp := SubViewport.new()
	vp.size = size_px
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.63, 0.66)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.70, 0.74, 0.82)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	var subject: Node3D = packed.instantiate()
	vp.add_child(subject)
	# Atlas 的城市/地形把颜色存在 COLOR_0 顶点色里（材质是 Library_VertexColor_White），
	# 而 Godot 从 GLB 导入的 StandardMaterial3D 默认不读顶点色，会渲成全白。
	for mi in subject.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var sm: Material = mi.mesh.surface_get_material(si)
			if sm is StandardMaterial3D and not sm.vertex_color_use_as_albedo:
				var dup: StandardMaterial3D = sm.duplicate()
				dup.vertex_color_use_as_albedo = true
				mi.set_surface_override_material(si, dup)

	# 摆到指定动画时刻，用来验证蒙皮变形（而不是只看静止姿势）
	if not anim_name.is_empty():
		var ap: AnimationPlayer = null
		for cand in subject.find_children("*", "AnimationPlayer", true, false):
			ap = cand
			break
		if ap == null:
			print("[PREVIEW] 没有 AnimationPlayer，无法摆姿势")
		elif not ap.has_animation(anim_name):
			print("[PREVIEW] 没有动画 ", anim_name, "；现有 ", ap.get_animation_list())
		else:
			ap.play(anim_name)
			ap.seek(anim_at, true)
			ap.advance(0.0)
			print("[PREVIEW] 已摆到 %s @ %.3fs（长度 %.3fs）" % [anim_name, anim_at, ap.get_animation(anim_name).length])

	var info := _measure(subject)
	var aabb: AABB = info.aabb
	var span: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var centre: Vector3 = aabb.position + aabb.size * 0.5

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = span * 1.25
	cam.near = 0.01
	cam.far = span * 40.0 + 100.0
	vp.add_child(cam)
	cam.make_current()

	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.95, 0.88)
	key.light_energy = 1.7
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.70, 0.78, 1.0)
	fill.light_energy = 0.45
	fill.shadow_enabled = false
	vp.add_child(fill)

	if not seq_out.is_empty():
		await _render_sequence(vp, cam, key, fill, subject, centre, span)
		return

	var written: Array = []
	for i in VIEWS.size():
		var yaw: float = PI * 0.5 * float(i)
		var basis := Basis(Vector3.UP, yaw)
		cam.transform = Transform3D(basis, centre + basis * Vector3(0.0, 0.0, span * 3.0))
		key.transform = Transform3D(Basis(Vector3.UP, yaw - 0.7) * Basis(Vector3.RIGHT, -0.6), Vector3.ZERO)
		fill.transform = Transform3D(Basis(Vector3.UP, yaw + 2.3) * Basis(Vector3.RIGHT, -0.2), Vector3.ZERO)
		for f in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = vp.get_texture().get_image()
		var path := "%s-%s.png" % [out_prefix, VIEWS[i]]
		var err: int = img.save_png(path)
		written.append({"view": VIEWS[i], "path": path, "err": err,
			"size": [img.get_width(), img.get_height()]})
		print("[PREVIEW] %s err=%d" % [path, err])

	var doc := {
		"asset": asset_path,
		"triangles": info.tris,
		"vertices": info.verts,
		"surfaces": info.surfaces,
		"mesh_instances": info.instances,
		"materials": info.materials,
		"aabb_position": [aabb.position.x, aabb.position.y, aabb.position.z],
		"aabb_size": [aabb.size.x, aabb.size.y, aabb.size.z],
		"has_skeleton": info.skeletons > 0,
		"skeletons": info.skeletons,
		"bones": info.bones,
		"bone_names": info.bone_names,
		"animation_players": info.anim_players,
		"animations": info.animations,
		"anim_info": info.anim_info,
		"views": written,
		"note": "正交中性预览，仅看形体；光照与场景无关。",
	}
	var f := FileAccess.open("%s.json" % out_prefix, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(doc, "  "))
		f.close()
	print("[PREVIEW] 三角 %d 顶点 %d 骨架 %d 骨骼 %d 动画 %d  bbox %.3f x %.3f x %.3f" % [
		info.tris, info.verts, info.skeletons, info.bones, info.animations,
		aabb.size.x, aabb.size.y, aabb.size.z])
	quit(0)


func _render_sequence(vp: SubViewport, cam: Camera3D, key: DirectionalLight3D,
		fill: DirectionalLight3D, subject: Node3D, centre: Vector3, span: float) -> void:
	## 按「idle 2s -> walk 2s -> run 2.5s」渲一整段序列到 PNG，供外部编码成视频。
	var ap: AnimationPlayer = null
	for cand in subject.find_children("*", "AnimationPlayer", true, false):
		ap = cand
		break
	if ap == null:
		print("[SEQ] 没有 AnimationPlayer")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(seq_out)
	var basis := Basis(Vector3.UP, seq_yaw)
	cam.transform = Transform3D(basis, centre + basis * Vector3(0.0, 0.10 * span, span * 2.6))
	cam.size = span * 1.35
	key.transform = Transform3D(Basis(Vector3.UP, seq_yaw - 0.8) * Basis(Vector3.RIGHT, -0.65), Vector3.ZERO)
	fill.transform = Transform3D(Basis(Vector3.UP, seq_yaw + 2.4) * Basis(Vector3.RIGHT, -0.15), Vector3.ZERO)

	var plan: Array = []
	for want in [["idle", 2.6], ["walk", 2.4], ["run", 2.2], ["sit", 5.0], ["sit_idle", 3.0]]:
		if ap.has_animation(String(want[0])):
			plan.append(want)
	if plan.is_empty():
		# 文件里没有我们约定的名字，就把现有动画依次完整播一遍（最多 6 秒一个）
		for a in ap.get_animation_list():
			plan.append([a, minf(14.0, maxf(1.0, ap.get_animation(a).length))])
		print("[SEQ] 按文件自带动画播放：", ap.get_animation_list())
	var dt := 1.0 / seq_fps
	var n := 0
	for seg in plan:
		var name: String = seg[0]
		var dur: float = seg[1]
		if not ap.has_animation(name):
			print("[SEQ] 缺动画 ", name)
			continue
		ap.play(name)
		var t := 0.0
		var length: float = ap.get_animation(name).length
		while t < dur:
			ap.seek(fmod(t, length), true)
			ap.advance(0.0)
			await RenderingServer.frame_post_draw
			var img: Image = vp.get_texture().get_image()
			img.save_png("%s/f%04d.png" % [seq_out, n])
			n += 1
			t += dt
	print("[SEQ] 帧数 %d  fps %.0f  目录 %s" % [n, seq_fps, seq_out])
	quit(0)


func _measure(n: Node) -> Dictionary:
	var tris := 0
	var verts := 0
	var surfaces := 0
	var instances := 0
	var mats: Array = []
	var aabb := AABB()
	var first := true
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		instances += 1
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		var world: Transform3D = mi.global_transform if mi.is_inside_tree() else mi.transform
		var box: AABB = world * mesh.get_aabb()
		if first:
			aabb = box
			first = false
		else:
			aabb = aabb.merge(box)
		for s in mesh.get_surface_count():
			surfaces += 1
			var arrays: Array = mesh.surface_get_arrays(s)
			var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			verts += pos.size()
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			tris += (idx.size() / 3) if idx.size() > 0 else (pos.size() / 3)
			var m: Material = mesh.surface_get_material(s)
			if m != null:
				mats.append(m.resource_name if not m.resource_name.is_empty() else m.get_class())
	var skels := 0
	var bones := 0
	var bone_names: Array = []
	for sk in n.find_children("*", "Skeleton3D", true, false):
		skels += 1
		bones += sk.get_bone_count()
		for b in sk.get_bone_count():
			bone_names.append(sk.get_bone_name(b))
	var players := 0
	var anims := 0
	var anim_info: Array = []
	for ap in n.find_children("*", "AnimationPlayer", true, false):
		players += 1
		for a in ap.get_animation_list():
			anims += 1
			var res: Animation = ap.get_animation(a)
			anim_info.append({"name": a, "length_s": res.length, "tracks": res.get_track_count(),
				"loop": int(res.loop_mode)})
	return {"tris": tris, "verts": verts, "surfaces": surfaces, "instances": instances,
		"materials": mats, "aabb": aabb, "skeletons": skels, "bones": bones,
		"anim_players": players, "animations": anims, "bone_names": bone_names, "anim_info": anim_info}
