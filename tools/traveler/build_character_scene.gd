extends SceneTree
## 把六个 Mixamo 动作 FBX 合成一个带 AnimationLibrary 的角色场景。
##
##   godot --path . --script res://tools/traveler/build_character_scene.gd -- \
##       --out=res://scenes/traveler/chibi_character.tscn \
##       --report=/abs/report.json
##
## 做法：以 idle.fbx 为底（它自带同一套蒙皮网格，所以动画轨道的节点路径天然匹配，
## 不需要重映射），把其余五个 FBX 的动画取出来并入同一个 AnimationLibrary。
## 循环标记按动作性质设：idle / walk / run / sit_idle 循环，walk_start / sit 单次。

const SOURCES := [
	{"key": "idle", "path": "res://assets/traveler/characters/anim/idle.fbx", "loop": true},
	{"key": "walk_start", "path": "res://assets/traveler/characters/anim/walk-start.fbx", "loop": false},
	{"key": "walk", "path": "res://assets/traveler/characters/anim/walk.fbx", "loop": true},
	{"key": "run", "path": "res://assets/traveler/characters/anim/run.fbx", "loop": true},
	{"key": "sit", "path": "res://assets/traveler/characters/anim/sit.fbx", "loop": false},
	{"key": "sit_idle", "path": "res://assets/traveler/characters/anim/sit-idle.fbx", "loop": true},
]

var out_path := ""
var report_path := ""


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_path = a.trim_prefix("--out=")
		elif a.begins_with("--report="):
			report_path = a.trim_prefix("--report=")
	if out_path.is_empty():
		push_error("需要 --out=")
		quit(1)
		return
	call_deferred("run")


func _player_of(n: Node) -> AnimationPlayer:
	for a in n.find_children("*", "AnimationPlayer", true, false):
		return a
	return null


func run() -> void:
	var base_scene: PackedScene = load(SOURCES[0].path)
	if base_scene == null:
		print("[BUILD] 底模加载失败 ", SOURCES[0].path)
		quit(1)
		return
	var root_node: Node3D = base_scene.instantiate()
	root_node.name = "ChibiCharacter"
	root.add_child(root_node)
	await process_frame

	var ap: AnimationPlayer = _player_of(root_node)
	if ap == null:
		print("[BUILD] 底模没有 AnimationPlayer")
		quit(1)
		return

	var lib := AnimationLibrary.new()
	var added: Array = []
	for src in SOURCES:
		var scene: PackedScene = load(src.path)
		if scene == null:
			print("[BUILD] 跳过（加载失败） ", src.path)
			continue
		var inst: Node3D = scene.instantiate()
		root.add_child(inst)
		var src_ap: AnimationPlayer = _player_of(inst)
		if src_ap == null or src_ap.get_animation_list().is_empty():
			print("[BUILD] 跳过（无动画） ", src.path)
			inst.queue_free()
			continue
		var name0: String = src_ap.get_animation_list()[0]
		var anim: Animation = src_ap.get_animation(name0).duplicate(true)
		anim.loop_mode = Animation.LOOP_LINEAR if src.loop else Animation.LOOP_NONE
		anim.resource_name = String(src.key)
		lib.add_animation(String(src.key), anim)
		added.append({"key": src.key, "from": src.path, "source_name": name0,
			"length_s": anim.length, "tracks": anim.get_track_count(),
			"loop": bool(src.loop)})
		inst.queue_free()

	# 清掉底模自带的库，换成我们合成的这一份
	for l in ap.get_animation_library_list():
		ap.remove_animation_library(l)
	ap.add_animation_library("", lib)
	ap.autoplay = "idle"

	# 打包要求所有子节点的 owner 指向根
	_own(root_node, root_node)
	var packed := PackedScene.new()
	var err: int = packed.pack(root_node)
	if err != OK:
		print("[BUILD] pack 失败 ", err)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var werr: int = ResourceSaver.save(packed, out_path)
	print("[BUILD] 保存 %s err=%d  动作 %d 个" % [out_path, werr, added.size()])
	for a in added:
		print("   %-11s %6.3fs  轨道 %d  %s" % [a.key, a.length_s, a.tracks,
			("循环" if a.loop else "单次")])

	if not report_path.is_empty():
		var f := FileAccess.open(report_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({
				"output": out_path, "save_error": werr,
				"base": SOURCES[0].path, "animations": added,
				"autoplay": "idle",
				"note": "以 idle.fbx 为底合成；六个动作同源同骨架，轨道路径无需重映射。",
			}, "  "))
			f.close()
	quit(0 if werr == OK else 1)


func _own(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		_own(c, owner_node)
