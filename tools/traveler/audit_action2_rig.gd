extends SceneTree
## Exports Godot animation poses and skin data for the independent CPU deformation audit.
## Use --out=/absolute/path; writes only that evidence file.
var out_path := ""
var skeleton:Skeleton3D
var animator:AnimationPlayer
var mesh_node:MeshInstance3D
var bind_bones:Array[int]=[]
var samples:Array=[]

func _initialize()->void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):out_path=arg.trim_prefix("--out=")
	call_deferred("run")

func run()->void:
	if out_path.is_empty():push_error("--out is required");quit(1);return
	var scene:Node3D=(load("res://scenes/traveler/action2_character.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	skeleton=scene.find_child("Skeleton3D",true,false) as Skeleton3D
	animator=scene.find_child("AnimationPlayer",true,false) as AnimationPlayer
	mesh_node=scene.find_child("tripo_node_5fd74650",true,false) as MeshInstance3D
	if skeleton==null or animator==null or mesh_node==null:push_error("rig nodes missing");quit(1);return
	animator.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for bind in mesh_node.skin.get_bind_count():
		var bone:=skeleton.find_bone(mesh_node.skin.get_bind_name(bind))
		if bone<0:push_error("skin bind missing bone: "+str(bind));quit(1);return
		bind_bones.append(bone)
	var clips:Array=[]
	for name in ["idle","walk","turn_180","bow"]:
		var anim:=animator.get_animation(name)
		animator.play(name,0.0);animator.advance(0.0)
		var count:=int(ceil(anim.length*60.0))
		for i in count+1:
			var t:=minf(float(i)/60.0,anim.length-0.00001)
			animator.seek(t,true);_sample(name,t,"clip")
		clips.append({"name":name,"length_s":anim.length,"samples":count+1})
	# Directed transitions use the shipping no-blend path, plus a 0.2s blend as
	# an additional mesh integrity check. Clip positions vary each repetition.
	var transitions:=0
	for blend in [0.0,0.2]:
		for from_name in ["idle","walk","turn_180","bow"]:
			for to_name in ["idle","walk","turn_180","bow"]:
				if from_name==to_name:continue
				for repetition in 4:
					animator.play(from_name,0.0);animator.advance(0.0)
					animator.seek(animator.get_animation(from_name).length*(float(repetition)+0.2)/4.0,true)
					animator.play(to_name,blend);animator.advance(0.0)
					for frame in 19:
						animator.advance(1.0/60.0)
						_sample(from_name+">"+to_name,float(frame+1)/60.0,"transition-blend-"+str(blend))
					transitions+=1
	var arrays:=mesh_node.mesh.surface_get_arrays(0)
	var vertices:Array=[]
	for vertex in arrays[Mesh.ARRAY_VERTEX]:vertices.append([vertex.x,vertex.y,vertex.z])
	var binds:Array=[]
	for i in bind_bones.size():binds.append({"name":str(mesh_node.skin.get_bind_name(i)),"bone":bind_bones[i]})
	var output:={"schema":"silkroad.action2-rig-samples.v1","scene":"res://scenes/traveler/action2_character.tscn","samples_hz":60,"clips":clips,"directed_transition_runs":transitions,"vertex_positions":vertices,"indices":Array(arrays[Mesh.ARRAY_INDEX]),"skin_weights":Array(arrays[Mesh.ARRAY_WEIGHTS]),"skin_bones":Array(arrays[Mesh.ARRAY_BONES]),"bind_mapping":binds,"samples":samples}
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	FileAccess.open(out_path,FileAccess.WRITE).store_string(JSON.stringify(output))
	print("ACTION2_RIG_SAMPLES ",JSON.stringify({"out":out_path,"vertices":vertices.size(),"binds":binds.size(),"samples":samples.size(),"transitions":transitions}))
	scene.queue_free();await process_frame;quit()

func _sample(label:String,time:float,kind:String)->void:
	skeleton.force_update_all_bone_transforms()
	var matrices:Array=[]
	for i in bind_bones.size():
		var transform:=skeleton.get_bone_global_pose(bind_bones[i])*mesh_node.skin.get_bind_pose(i)
		matrices.append([transform.basis.x.x,transform.basis.y.x,transform.basis.z.x,transform.origin.x,transform.basis.x.y,transform.basis.y.y,transform.basis.z.y,transform.origin.y,transform.basis.x.z,transform.basis.y.z,transform.basis.z.z,transform.origin.z])
	var hips:=skeleton.get_bone_global_pose(skeleton.find_bone("mixamorig_Hips"))
	var forward:=hips.basis.z.normalized()
	var feet:Dictionary={}
	for side in ["Left","Right"]:
		var position:=skeleton.get_bone_global_pose(skeleton.find_bone("mixamorig_"+side+"Foot")).origin
		feet[side.to_lower()]=[position.x,position.y,position.z]
	samples.append({"clip":label,"time_s":time,"kind":kind,"skin_matrices":matrices,"hips_forward":[forward.x,forward.y,forward.z],"hips_yaw_rad":atan2(forward.x,forward.z),"feet":feet})
