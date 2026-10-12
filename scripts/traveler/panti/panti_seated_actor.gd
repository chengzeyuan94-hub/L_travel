extends RefCounted
## One seated idle, sampled absolutely by Panti's shared clock. No local tick.
var model:Node3D
var player:AnimationPlayer
var skeleton:Skeleton3D
var body:MeshInstance3D
var animation_name:StringName=&""
var metadata:Dictionary={}
var seat_anchor:=Vector3.ZERO
var duration_s:=0.0
var start_offset_s:=0.0
var last_time:=0.0
var phase_s:=0.0
var frozen:=false
var hips_index:=-1
var seat_anchor_in_bone:=Vector3.ZERO
var last_seat_correction:=Vector3.ZERO
var max_seat_correction_u:=0.0

func configure(character_model:Node3D,configuration:Dictionary={}) -> void:
	model=character_model
	hips_index=-1
	var metadata_path:String=str(configuration.get("metadata","res://assets/traveler/panti/camp/character/seated-idle-landmarks.json"))
	metadata=JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
	var anchor:Array=metadata.seat_anchor_local_godot
	seat_anchor=Vector3(float(anchor[0]),float(anchor[1]),float(anchor[2]))
	start_offset_s=float(configuration.get("start_offset_s",metadata.start_offset_s))
	player=model.find_child("AnimationPlayer",true,false) as AnimationPlayer
	skeleton=model.find_child("Skeleton3D",true,false) as Skeleton3D
	body=model.find_child("PantiSeatedBody",true,false) as MeshInstance3D
	assert(player!=null and skeleton!=null and body!=null,"Incomplete Panti seated animation scene")
	for candidate in player.get_animation_list():
		if str(candidate)=="seated_idle" or str(candidate).ends_with("/seated_idle"):
			animation_name=candidate
	assert(not animation_name.is_empty(),"Panti seated_idle animation is missing")
	var animation:Animation=player.get_animation(animation_name)
	duration_s=animation.length
	assert(duration_s>0.0,"Panti seated_idle has zero duration")
	animation.loop_mode=Animation.LOOP_LINEAR
	player.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	player.play(animation_name,0.0)
	_apply_time(0.0)
	for index in skeleton.get_bone_count():
		if str(skeleton.get_bone_name(index)).to_lower().ends_with("hips"):hips_index=index
	assert(hips_index>=0,"Panti seated skeleton has no Hips anchor")
	seat_anchor_in_bone=skeleton.get_bone_global_pose(hips_index).affine_inverse()*skeleton.to_local(model.to_global(seat_anchor))

func set_time(time_s:float) -> void:
	if frozen:return
	_apply_time(time_s)

func _apply_time(time_s:float) -> void:
	last_time=time_s
	phase_s=fposmod(time_s+start_offset_s,duration_s)
	player.seek(phase_s,true)
	player.advance(0.0)
	skeleton.force_update_all_bone_transforms()
	if hips_index>=0:
		# Godot's importer reduces the coupled 537-sample Hips translation to
		# 16 keys. Reassert the physical seat point after interpolation, on the
		# actual bone pose. The outer model transform and all rotations stay put.
		assert(skeleton.get_bone_parent(hips_index)<0,"Seated Hips correction expects a root bone")
		var wanted:Vector3=skeleton.to_local(model.to_global(seat_anchor))
		var current:Vector3=skeleton.get_bone_global_pose(hips_index)*seat_anchor_in_bone
		last_seat_correction=wanted-current
		max_seat_correction_u=maxf(max_seat_correction_u,last_seat_correction.length())
		skeleton.set_bone_pose_position(hips_index,skeleton.get_bone_pose_position(hips_index)+last_seat_correction)
		skeleton.force_update_all_bone_transforms()

func freeze(value:bool) -> void:
	frozen=value

func current_seat_anchor() -> Vector3:
	return model.to_local(skeleton.to_global(skeleton.get_bone_global_pose(hips_index)*seat_anchor_in_bone))

func evidence() -> Dictionary:
	return {"asset":metadata.get("asset",""),"animation":str(animation_name),"duration_s":duration_s,"start_offset_s":start_offset_s,"time_s":last_time,"phase_s":phase_s,"frozen":frozen,"seat_anchor_local":[seat_anchor.x,seat_anchor.y,seat_anchor.z],"bones":skeleton.get_bone_count() if skeleton!=null else 0,"clock":"Absolute shared Panti anim_t; manual seek, no local tick or accumulated transform","loop_mode":"single seated_idle / LOOP_LINEAR","run_walk_mix":false,"root_anchor":"Source stabilization plus an actual Hips position correction after Godot interpolation; outer model transform is untouched","max_seat_correction_u":max_seat_correction_u,"last_seat_correction_skeleton_local":[last_seat_correction.x,last_seat_correction.y,last_seat_correction.z]}
