extends SceneTree
const Motion = preload("res://scripts/traveler/public_owned_motion.gd")
func _initialize()->void:
	var changed: Array=[]
	for path: String in ["res://scenes/traveler/action2_character.tscn","res://scenes/traveler/chibi_character.tscn"]:
		if not FileAccess.file_exists(path):continue
		var scene:=load(path) as PackedScene
		var root:=scene.instantiate() as Node3D
		var skeleton:=root.find_child("Skeleton3D",true,false) as Skeleton3D
		if skeleton!=null:skeleton.reset_bone_poses()
		for player: AnimationPlayer in root.find_children("*","AnimationPlayer",true,false):
			for library_name: StringName in player.get_animation_library_list():
				var old:=player.get_animation_library(library_name)
				var library:=AnimationLibrary.new()
				for name: StringName in old.get_animation_list(): library.add_animation(name,Motion.make(root,str(name)))
				player.remove_animation_library(library_name);player.add_animation_library(library_name,library)
		var output:=PackedScene.new();output.pack(root)
		var code:=ResourceSaver.save(output,path)
		changed.append({"path":path,"error":code});root.free()
	print("PUBLIC_OWNED_MOTION ",JSON.stringify(changed));quit(0)
