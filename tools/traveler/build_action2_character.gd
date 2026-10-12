extends SceneTree
## Build the second character rig from the supplied stylized model and four FBX actions.
## The walk/idle/turn/bow clips share the model's skeleton. No run clip is wired.

const SOURCES := [
	{"key":"idle", "path":"res://assets/traveler/characters/action2/animations/idle.fbx", "loop":true},
	{"key":"walk", "path":"res://assets/traveler/characters/action2/animations/walk.fbx", "loop":true},
	{"key":"turn_180", "path":"res://assets/traveler/characters/action2/animations/turn_180.fbx", "loop":false},
	{"key":"bow", "path":"res://assets/traveler/characters/action2/animations/bow.fbx", "loop":false},
]
var out_path := "res://scenes/traveler/action2_character.tscn"
var report_path := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): out_path=arg.trim_prefix("--out=")
		elif arg.begins_with("--report="): report_path=arg.trim_prefix("--report=")
	call_deferred("run")

func _player_of(n:Node) -> AnimationPlayer:
	return n.find_child("AnimationPlayer",true,false) as AnimationPlayer

func run() -> void:
	# The standalone model FBX has no armature; the idle FBX carries the same
	# skinned mesh plus the 49-bone rig and is the canonical base scene.
	var base:PackedScene=load("res://assets/traveler/characters/action2/animations/idle.fbx")
	if base==null: push_error("action2 base model failed to load"); quit(1); return
	var root_node:Node3D=base.instantiate(); root_node.name="Action2Character"; root.add_child(root_node)
	await process_frame
	var ap:=_player_of(root_node)
	if ap==null: push_error("action2 base has no AnimationPlayer"); quit(1); return
	var lib:=AnimationLibrary.new(); var added:Array=[]
	var canonical_hips:=_first_hips_position(ap.get_animation(ap.get_animation_list()[0]))
	var base_skeleton:=root_node.find_child("Skeleton3D",true,false) as Skeleton3D
	var skeleton_checks:Array=[]
	for src in SOURCES:
		var scene:PackedScene=load(src.path)
		if scene==null: push_error("action2 clip failed: "+src.path); continue
		var inst:Node3D=scene.instantiate(); root.add_child(inst); await process_frame
		var src_ap:=_player_of(inst)
		if src_ap==null or src_ap.get_animation_list().is_empty(): push_error("action2 clip has no animation: "+src.path); inst.queue_free(); continue
		var src_skeleton:=inst.find_child("Skeleton3D",true,false) as Skeleton3D
		var skeleton_check:=_compare_skeletons(base_skeleton,src_skeleton)
		skeleton_check["clip"]=src.key
		skeleton_checks.append(skeleton_check)
		if not bool(skeleton_check.pass):
			push_error("action2 clip skeleton does not match base: "+src.path); inst.queue_free(); root_node.queue_free(); quit(1); return
		var source_name:String=src_ap.get_animation_list()[0]
		var anim:Animation=src_ap.get_animation(source_name).duplicate(true)
		anim.loop_mode=Animation.LOOP_LINEAR if bool(src.loop) else Animation.LOOP_NONE
		_normalize_root_motion(anim,canonical_hips)
		var yaw_report:Dictionary={}
		if String(src.key)=="turn_180":yaw_report=_normalize_turn_yaw(anim)
		anim.resource_name=String(src.key); lib.add_animation(String(src.key),anim)
		added.append({"key":src.key,"source":src.path,"source_name":source_name,"length_s":anim.length,"tracks":anim.get_track_count(),"loop":src.loop,"yaw_normalization":yaw_report})
		inst.queue_free()
	for name in ap.get_animation_library_list(): ap.remove_animation_library(name)
	ap.add_animation_library("",lib)
	root.remove_child(root_node)
	ap.autoplay="idle"
	_own(root_node,root_node)
	var packed:=PackedScene.new(); var err:=packed.pack(root_node)
	if err!=OK: push_error("action2 pack failed: "+str(err)); quit(1); return
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir()); var save_err:=ResourceSaver.save(packed,out_path)
	var report:Dictionary={"output":out_path,"save_error":save_err,"base":"res://assets/traveler/characters/action2/animations/idle.fbx","animations":added,"run_wired":false,"root_motion":"All clips use the idle first-frame Hips x/z and vertical baseline; relative y body compression retained", "canonical_hips_position":[canonical_hips.x,canonical_hips.y,canonical_hips.z], "skeleton_checks":skeleton_checks, "mesh_integrity":_mesh_integrity(root_node,base_skeleton),"note":"Action2 uses idle/walk/turn_180/bow. Run is intentionally omitted to avoid the previous gait-switch spike."}
	print("ACTION2_CHARACTER ",JSON.stringify(report))
	if not report_path.is_empty(): FileAccess.open(report_path,FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	root_node.free()
	await process_frame
	quit(0 if save_err==OK else 1)

func _own(n:Node,owner_node:Node)->void:
	for c in n.get_children(): c.owner=owner_node; _own(c,owner_node)

func _normalize_root_motion(anim:Animation,canonical:Vector3)->void:
	for track in anim.get_track_count():
		if anim.track_get_type(track)!=Animation.TYPE_POSITION_3D: continue
		var path:=str(anim.track_get_path(track)).to_lower()
		if not path.contains("hips"): continue
		if anim.track_get_key_count(track)==0: continue
		var first:Vector3=anim.track_get_key_value(track,0)
		for key in anim.track_get_key_count(track):
			var value:Vector3=anim.track_get_key_value(track,key)
			# Preserve authored vertical body compression but never let a clip
			# translate the actor or introduce a clip-to-clip root jump.
			anim.track_set_key_value(track,key,Vector3(canonical.x,canonical.y+value.y-first.y,canonical.z))

func _first_hips_position(anim:Animation)->Vector3:
	for track in anim.get_track_count():
		if anim.track_get_type(track)==Animation.TYPE_POSITION_3D and str(anim.track_get_path(track)).to_lower().contains("hips") and anim.track_get_key_count(track)>0:
			return anim.track_get_key_value(track,0)
	push_error("action2 idle Hips position track missing")
	return Vector3.ZERO

func _compare_skeletons(base:Skeleton3D,other:Skeleton3D)->Dictionary:
	if base==null or other==null:return {"pass":false,"reason":"missing Skeleton3D"}
	var same:=base.get_bone_count()==other.get_bone_count()
	var max_rest_delta:=0.0
	if same:
		for bone in base.get_bone_count():
			same = same and base.get_bone_name(bone)==other.get_bone_name(bone) and base.get_bone_parent(bone)==other.get_bone_parent(bone)
			var a:=base.get_bone_rest(bone); var b:=other.get_bone_rest(bone)
			max_rest_delta=maxf(max_rest_delta,a.origin.distance_to(b.origin))
			for axis in 3:max_rest_delta=maxf(max_rest_delta,a.basis[axis].distance_to(b.basis[axis]))
	return {"pass":same and max_rest_delta<0.00001,"bone_count":other.get_bone_count(),"max_rest_component_delta":max_rest_delta}

func _mesh_integrity(scene:Node,skeleton:Skeleton3D)->Array:
	var result:Array=[]
	for node in scene.find_children("*","MeshInstance3D",true,false):
		var mesh_node:=node as MeshInstance3D
		if mesh_node.mesh==null:continue
		for surface in mesh_node.mesh.get_surface_count():
			var arrays:=mesh_node.mesh.surface_get_arrays(surface)
			var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var weights:PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
			var bones:PackedInt32Array=arrays[Mesh.ARRAY_BONES]
			if vertices.is_empty() or weights.is_empty():continue
			var influences:=weights.size()/vertices.size()
			var low:=INF; var high:=-INF; var valid:=mesh_node.skin!=null
			for vertex in vertices.size():
				valid=valid and vertices[vertex].is_finite()
				var total:=0.0
				for weight in influences:
					var index:=vertex*influences+weight
					valid=valid and is_finite(weights[index]) and weights[index]>=0.0
					if weights[index]>0.0:valid=valid and bones[index]>=0 and bones[index]<mesh_node.skin.get_bind_count()
					total+=weights[index]
				low=minf(low,total); high=maxf(high,total)
			result.append({"mesh":str(mesh_node.name),"surface":surface,"vertices":vertices.size(),"influences_per_vertex":influences,"weight_sum_min":low,"weight_sum_max":high,"finite_weights_and_valid_bind_indices":valid,"bone_count":skeleton.get_bone_count() if skeleton else 0})
	return result

func _normalize_turn_yaw(anim:Animation)->Dictionary:
	for track in anim.get_track_count():
		if anim.track_get_type(track)!=Animation.TYPE_ROTATION_3D or not str(anim.track_get_path(track)).to_lower().contains("hips"):continue
		var count:=anim.track_get_key_count(track)
		var first_yaw:=0.0;var last_yaw:=0.0
		for key in count:
			var rotation:Quaternion=anim.track_get_key_value(track,key)
			rotation=rotation.normalized()
			var forward:=Basis(rotation).z
			var yaw:=atan2(forward.x,forward.z)
			if key==0:first_yaw=yaw
			if key==count-1:last_yaw=yaw
			# Actor rotation owns heading. Remove global Y yaw from the root
			# pose while retaining the authored roll and pitch of each step.
			anim.track_set_key_value(track,key,(Quaternion(Vector3.UP,-yaw)*rotation).normalized())
		return {"actor_owns_heading":true,"source_start_yaw_deg":rad_to_deg(first_yaw),"source_end_yaw_deg":rad_to_deg(last_yaw),"root_yaw_removed":true,"keys":count}
	push_error("action2 turn Hips rotation track missing")
	return {"root_yaw_removed":false}
