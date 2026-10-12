extends RefCounted
## Small two-bone leg correction after authored animation. No extra clock.
var controller:Node3D
var skeleton:Skeleton3D
var legs:Array[Dictionary]=[]
var planted_count:=0
var max_correction_u:=0.0
func configure(cc:Node3D) -> void:
 controller=cc
 skeleton=cc.character_skeleton
 for side in ["Left","Right"]:
  var leg:Dictionary={}
  for part in ["UpLeg","Leg","Foot","ToeBase"]:
   leg[part]=skeleton.find_bone("mixamorig_"+side+part)
  if int(leg.Foot)<0 or int(leg.UpLeg)<0 or int(leg.Leg)<0 or int(leg.ToeBase)<0:continue
  leg["locked"]=false
  leg["anchor"]=Vector3.ZERO
  leg["previous_toe"]=Vector3.ZERO
  legs.append(leg)
func apply(_delta:float) -> void:
 if skeleton==null or controller.state in ["sit","sit_idle"]:return
 planted_count=0
 max_correction_u=0.0
 skeleton.force_update_all_bone_transforms()
 for leg in legs:
  var hip:Transform3D=skeleton.get_bone_global_pose(int(leg.UpLeg))
  var knee:Transform3D=skeleton.get_bone_global_pose(int(leg.Leg))
  var ankle:Transform3D=skeleton.get_bone_global_pose(int(leg.Foot))
  var toe:Vector3=skeleton.get_bone_global_pose(int(leg.ToeBase)).origin
  var world_toe:Vector3=skeleton.global_transform*toe
  var query:=PhysicsRayQueryParameters3D.create(world_toe+Vector3.UP*0.5,world_toe-Vector3.UP,controller.GROUND_LAYER)
  var hit:Dictionary=controller.get_world_3d().direct_space_state.intersect_ray(query)
  if hit.is_empty():continue
  var scale:float=controller.actor.scale.x
  var sole:float=float(controller.settings.get("toe_sole_local_u",0.021))*scale
  var contact:=1.0-smoothstep(0.033,0.065,toe.y)
  var moving:bool=controller.state in ["walk","run"]
  if not moving:contact=1.0
  var previous:Vector3=leg.previous_toe
  var stance:bool=contact>0.5 and (not moving or toe.z<=previous.z+0.00005)
  leg.previous_toe=toe
  if stance and not bool(leg.locked):
   leg.anchor=world_toe
   leg.locked=true
  if not stance:leg.locked=false
  var corrected:=world_toe
  if bool(leg.locked):
   var anchor:Vector3=leg.anchor
   var horizontal:=Vector3(anchor.x-world_toe.x,0.0,anchor.z-world_toe.z)
   # Keep the correction below a fraction of one foot length; release a
   # planted foot cleanly instead of stretching a leg through a sharp turn.
   var limit:=float(controller.settings.get("foot_lock_local_u",0.045))*scale
   if horizontal.length()>limit:
    leg.locked=false
   else:
    corrected+=horizontal*contact
    planted_count+=1
  var ground_y:float=hit.position.y+sole
  corrected.y=lerpf(world_toe.y,ground_y,contact)
  # Never allow the animated toe to sink through a slope, even during swing.
  corrected.y=maxf(corrected.y,ground_y)
  var correction:Vector3=(corrected-world_toe).limit_length(float(controller.settings.get("foot_ground_max_local_u",0.16))*scale)
  max_correction_u=maxf(max_correction_u,correction.length())
  var target:Vector3=ankle.origin+skeleton.global_basis.inverse()*correction
  _solve(leg,hip,knee,ankle,target)
func _solve(leg:Dictionary,hip:Transform3D,knee:Transform3D,ankle:Transform3D,target:Vector3) -> void:
 var a:=hip.origin.distance_to(knee.origin)
 var b:=knee.origin.distance_to(ankle.origin)
 var line:=target-hip.origin
 var distance:=clampf(line.length(),absf(a-b)+0.0001,a+b-0.0001)
 if line.length()<0.0001:return
 var direction:=line.normalized()
 var bend:Vector3=(knee.origin-hip.origin)-direction*(knee.origin-hip.origin).dot(direction)
 if bend.length()<0.0001:bend=hip.basis.z-direction*hip.basis.z.dot(direction)
 bend=bend.normalized()
 var along:float=(a*a-b*b+distance*distance)/(2.0*distance)
 var height:=sqrt(maxf(a*a-along*along,0.0))
 var knee_target:=hip.origin+direction*along+bend*height
 var rotation:=Quaternion((knee.origin-hip.origin).normalized(),(knee_target-hip.origin).normalized())
 hip.basis=Basis(rotation)*hip.basis
 skeleton.set_bone_global_pose(int(leg.UpLeg),hip)
 skeleton.force_update_all_bone_transforms()
 var posed_knee:=skeleton.get_bone_global_pose(int(leg.Leg))
 var posed_ankle:=skeleton.get_bone_global_pose(int(leg.Foot))
 rotation=Quaternion((posed_ankle.origin-posed_knee.origin).normalized(),(target-posed_knee.origin).normalized())
 posed_knee.basis=Basis(rotation)*posed_knee.basis
 skeleton.set_bone_global_pose(int(leg.Leg),posed_knee)
 skeleton.force_update_all_bone_transforms()
 posed_ankle=skeleton.get_bone_global_pose(int(leg.Foot))
 posed_ankle.basis=ankle.basis
 skeleton.set_bone_global_pose(int(leg.Foot),posed_ankle)
 skeleton.force_update_all_bone_transforms()
