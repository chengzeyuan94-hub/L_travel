extends SceneTree
var output:=""
func _initialize():call_deferred("run")
func run():
 for arg in OS.get_cmdline_user_args():
  if arg.begins_with("--out="):output=arg.trim_prefix("--out=")
 if output.is_empty() or FileAccess.file_exists(output):
  push_error("Use --out=<new JSON path>")
  quit(1)
  return
 var viewport:=SubViewport.new()
 viewport.size=Vector2i(1920,1080)
 viewport.own_world_3d=true
 root.add_child(viewport)
 var viewer=load("res://scenes/traveler/traveler_main.tscn").instantiate()
 viewport.add_child(viewer)
 while not is_instance_valid(viewer.character_controller) or not viewer.character_controller.ready_for_input:await process_frame
 viewer.set_process(false)
 viewer.motion_director.externally_clocked=true
 var cc=viewer.character_controller
 cc.set_process(false)
 if OS.get_cmdline_user_args().has("--without-footing"):cc.footing=null
 var checks:Dictionary={}
 var sk:Skeleton3D=cc.character_skeleton
 var bones:Array=[]
 for i in sk.get_bone_count():
  var name:=sk.get_bone_name(i)
  if name.contains("Leg") or name.contains("Foot") or name.contains("Toe") or name.contains("Hips"):
   var p:=sk.get_bone_global_pose(i).origin
   bones.append({"name":name,"parent":sk.get_bone_name(sk.get_bone_parent(i)) if sk.get_bone_parent(i)>=0 else "", "position":[p.x,p.y,p.z]})
 var available:Array=[]
 for pixel in [Vector2(360,810),Vector2(558,810),Vector2(360,882),Vector2(558,882),Vector2(288,792),Vector2(576,846),Vector2(450,900),Vector2(300,900)]:
  available.append({"pixel":str(pixel),"valid":not cc._valid_ground(pixel).is_empty()})
 var samples:Array=[]
 cc.move_to(Vector2(288,792),false)
 for i in 330:
  if i==240:cc.move_to(Vector2(576,846),true)
  cc._process(1.0/30.0)
  sk.force_update_all_bone_transforms()
  if i==100:
   var phase:float=cc.animator.current_animation_position
   cc.move_to(Vector2(288,792),false)
   checks["retarget_preserves_phase"]=is_equal_approx(phase,cc.animator.current_animation_position)
  if i==180:
   viewer.motion_director.set_motion_enabled(false)
   var pose:Transform3D=sk.get_bone_global_pose(sk.find_bone("mixamorig_LeftFoot"))
   var location:Vector3=cc.actor.global_position
   for frozen_tick in 60:cc._process(1.0/30.0)
   checks["freeze_foot_pose"]=pose==sk.get_bone_global_pose(sk.find_bone("mixamorig_LeftFoot"))
   checks["freeze_position"]=location==cc.actor.global_position
   viewer.motion_director.set_motion_enabled(true)
  var feet:Dictionary={}
  for name in ["mixamorig_LeftFoot","mixamorig_LeftToeBase","mixamorig_RightFoot","mixamorig_RightToeBase"]:
   var index:=sk.find_bone(name)
   var world:=sk.global_transform*sk.get_bone_global_pose(index).origin
   var query:=PhysicsRayQueryParameters3D.create(world+Vector3.UP,world-Vector3.UP,cc.GROUND_LAYER)
   var hit:Dictionary=cc.get_world_3d().direct_space_state.intersect_ray(query)
   feet[name]={"world":[world.x,world.y,world.z],"clearance_u":world.y-hit.position.y if not hit.is_empty() else -999,"pixel":str(viewer.camera.unproject_position(world))}
  samples.append({"frame":i,"feet":feet,"state":cc.state,"speed":cc.current_speed_px_s,"yaw":cc.actor.rotation.y,"screen":str(cc.screen_position)})
 FileAccess.open(output,FileAccess.WRITE).store_string(JSON.stringify({"bones":bones,"available":available,"checks":checks,"character_settings":cc.settings,"command_args":OS.get_cmdline_args(),"user_args":OS.get_cmdline_user_args(),"model_position":str(cc.model.position),"samples":samples},"\t"))
 print("GROUND_AUDIT_COMPLETE")
 quit()
