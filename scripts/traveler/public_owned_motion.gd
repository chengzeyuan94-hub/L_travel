class_name PublicOwnedMotion
extends RefCounted
## Independently written basic motion. Uses only the character's rig/rest shape;
## no imported motion samples, external keyframes or sampled source clips.
static func make(root: Node3D, name: String) -> Animation:
	var skeleton := root.find_child("Skeleton3D",true,false) as Skeleton3D
	var animation := Animation.new()
	animation.resource_name=name
	animation.length=1.2 if "walk" in name.to_lower() else 4.0
	animation.loop_mode=Animation.LOOP_NONE if "bow" in name.to_lower() or "turn" in name.to_lower() else Animation.LOOP_LINEAR
	if skeleton==null: return animation
	var path := str(root.get_path_to(skeleton))
	for i: int in skeleton.get_bone_count():
		var bone := str(skeleton.get_bone_name(i)); var lower := bone.to_lower()
		if not ("spine" in lower or "upleg" in lower or lower.ends_with("arm") or "head" in lower): continue
		var rest := skeleton.get_bone_rest(i).basis.orthonormalized().get_rotation_quaternion()
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track,NodePath(path+":"+bone))
		for k: int in 13:
			var phase := float(k)/12.0; var angle := 0.0
			var axis := Vector3.RIGHT
			if "spine" in lower:
				angle=0.32*sin(PI*phase) if "bow" in name.to_lower() else 0.025*sin(TAU*phase)
			elif "upleg" in lower and "walk" in name.to_lower(): angle=0.30*sin(TAU*phase)*(1 if "left" in lower else -1)
			elif lower.ends_with("arm"):
				axis=Vector3.FORWARD; angle=0.65*(1 if "left" in lower else -1)
				if "walk" in name.to_lower(): angle+=0.12*sin(TAU*phase)
			elif "head" in lower: axis=Vector3.UP; angle=0.025*sin(TAU*phase)
			animation.rotation_track_insert_key(track,phase*animation.length,rest*Quaternion(axis,angle))
	return animation
