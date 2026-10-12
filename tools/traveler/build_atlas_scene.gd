extends SceneTree

func _initialize() -> void:
	call_deferred("build")

func build() -> void:
	var builder = load("res://scripts/traveler/atlas_builder.gd").new()
	var world: Node3D = builder.build()
	root.add_child(world)
	await process_frame
	await RenderingServer.frame_post_draw
	var resources:Dictionary=load("res://scripts/traveler/scene_resources.gd").externalize(world)
	if not resources.get("success",false):
		push_error("Scene resource export failed: "+JSON.stringify(resources))
		quit(1)
		return
	assign_owners(world, world)
	var packed := PackedScene.new()
	var error := packed.pack(world)
	if error == OK:
		error = ResourceSaver.save(packed, "res://generated/traveler/atlas/atlas_world.tscn")
	var report: Dictionary = builder.report
	report["resources"]=resources
	report["scene_save_error"] = error
	var report_path := "res://docs/reports/traveler-merge-atlas/godot-build.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--report="): report_path=arg.trim_prefix("--report=")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(report, "\t"))
	print("ATLAS_BUILD ", JSON.stringify(report))
	world.queue_free()
	await process_frame
	await process_frame
	quit(error)

func assign_owners(node: Node, scene_root: Node) -> void:
	for child in node.get_children():
		child.owner = scene_root
		assign_owners(child, scene_root)
