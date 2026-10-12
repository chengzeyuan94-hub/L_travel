extends SceneTree
## 逐帧采样骨架姿态，用来把一条拼接动画切成若干动作段。
##
##   godot --path . --script res://tools/traveler/probe_anim_segments.gd -- \
##       --asset=res://assets/traveler/characters/chibi-anim.fbx \
##       --anim=run_sit_walk_wait --fps=60 --out=/abs/path.json
##
## 导出每帧：髋部高度、两大腿夹角、两小腿夹角、全身关节位移速度。
## 坐 = 髋部高度骤降；跑/走 = 腿夹角摆幅与频率不同；等 = 速度接近 0。

var asset_path := ""
var anim_name := ""
var out_path := ""
var fps := 60.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--asset="):
			asset_path = a.trim_prefix("--asset=")
		elif a.begins_with("--anim="):
			anim_name = a.trim_prefix("--anim=")
		elif a.begins_with("--out="):
			out_path = a.trim_prefix("--out=")
		elif a.begins_with("--fps="):
			fps = float(a.trim_prefix("--fps="))
	if asset_path.is_empty() or out_path.is_empty():
		push_error("需要 --asset= 与 --out=")
		quit(1)
		return
	call_deferred("run")


func run() -> void:
	var packed: PackedScene = load(asset_path)
	if packed == null:
		print("[SEG] 加载失败 ", asset_path)
		quit(1)
		return
	var subject: Node3D = packed.instantiate()
	root.add_child(subject)
	await process_frame

	var skel: Skeleton3D = null
	for s in subject.find_children("*", "Skeleton3D", true, false):
		skel = s
		break
	var ap: AnimationPlayer = null
	for a in subject.find_children("*", "AnimationPlayer", true, false):
		ap = a
		break
	if skel == null or ap == null:
		print("[SEG] 缺 Skeleton3D 或 AnimationPlayer")
		quit(1)
		return
	if anim_name.is_empty():
		anim_name = ap.get_animation_list()[0]
	if not ap.has_animation(anim_name):
		print("[SEG] 没有动画 ", anim_name, " 现有 ", ap.get_animation_list())
		quit(1)
		return

	var want := {
		"hips": "mixamorig_Hips", "head": "mixamorig_Head",
		"lthigh": "mixamorig_LeftUpLeg", "rthigh": "mixamorig_RightUpLeg",
		"lshin": "mixamorig_LeftLeg", "rshin": "mixamorig_RightLeg",
		"lfoot": "mixamorig_LeftFoot", "rfoot": "mixamorig_RightFoot",
		"larm": "mixamorig_LeftArm", "rarm": "mixamorig_RightArm",
	}
	var idx := {}
	for k in want:
		var b: int = skel.find_bone(String(want[k]))
		if b < 0:
			print("[SEG] 找不到骨 ", want[k])
		idx[k] = b

	var length: float = ap.get_animation(anim_name).length
	var frames := int(round(length * fps))
	ap.play(anim_name)
	var rows: Array = []
	var prev: Array = []
	for f in frames + 1:
		var t: float = clampf(float(f) / fps, 0.0, length)
		ap.seek(t, true)
		ap.advance(0.0)
		await process_frame
		var pose := {}
		var all: Array = []
		for k in idx:
			var b: int = idx[k]
			if b < 0:
				continue
			var g: Transform3D = skel.get_bone_global_pose(b)
			pose[k] = g
			all.append(g.origin)
		var hips: Transform3D = pose.get("hips", Transform3D())
		var row := {
			"t": t,
			"hips_y": hips.origin.y,
			"head_y": (pose["head"].origin.y if pose.has("head") else 0.0),
		}
		# 两腿夹角：用大腿骨的前向（-Z 在 Godot 骨骼空间里不一定，改用足端相对髋的水平前后差）
		if pose.has("lfoot") and pose.has("rfoot"):
			var lf: Vector3 = pose["lfoot"].origin
			var rf: Vector3 = pose["rfoot"].origin
			row["foot_gap"] = (lf - rf).length()
			row["foot_dz"] = absf(lf.z - rf.z)
			row["foot_dy"] = absf(lf.y - rf.y)
		if pose.has("larm") and pose.has("rarm") and pose.has("hips"):
			row["arm_spread"] = (pose["larm"].origin - pose["rarm"].origin).length()
		# 全身关节速度
		var speed := 0.0
		if not prev.is_empty() and prev.size() == all.size():
			for i in all.size():
				speed += (all[i] - prev[i]).length()
			speed *= fps / float(max(1, all.size()))
		row["joint_speed"] = speed
		prev = all
		rows.append(row)

	var doc := {
		"asset": asset_path, "animation": anim_name, "length_s": length,
		"fps": fps, "frames": rows.size(),
		"bones_sampled": want, "rows": rows,
		"note": "hips_y/head_y 为骨骼全局姿态高度；joint_speed 为采样关节的平均位移速度。",
	}
	var fh := FileAccess.open(out_path, FileAccess.WRITE)
	if fh == null:
		print("[SEG] 写不了 ", out_path)
		quit(1)
		return
	fh.store_string(JSON.stringify(doc))
	fh.close()
	print("[SEG] 采样 %d 帧 / %.3fs -> %s" % [rows.size(), length, out_path])
	quit(0)
