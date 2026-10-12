extends SceneTree
const Progress = preload("res://scripts/lshu_ui/lshu_progress.gd")
func _initialize() -> void:
	var acts: Array = []
	for act: Dictionary in Progress.ACTS:
		acts.append({"id":act.id,"missing":Progress.missing_deps(str(act.scene))})
	var out: Dictionary = {"engine":Engine.get_version_info(),"acts":acts,"scope":"Cleaned public source dependency audit; not a GUI acceptance claim"}
	var dir: String = OS.get_environment("SILKROAD_DATA_DIR")
	DirAccess.make_dir_recursive_absolute(dir)
	FileAccess.open(dir.path_join("release-preflight.json"),FileAccess.WRITE).store_string(JSON.stringify(out,"  "))
	FileAccess.open(dir.path_join("GODOT-LICENSE.txt"),FileAccess.WRITE).store_string(Engine.get_license_text())
	FileAccess.open(dir.path_join("GODOT-COPYRIGHT-INFO.json"),FileAccess.WRITE).store_string(JSON.stringify(Engine.get_copyright_info(),"  "))
	if Engine.has_method("get_license_info"):
		FileAccess.open(dir.path_join("GODOT-LICENSE-INFO.json"),FileAccess.WRITE).store_string(JSON.stringify(Engine.get_license_info(),"  "))
	print("RELEASE_PREFLIGHT ", JSON.stringify(out))
	quit(0)
