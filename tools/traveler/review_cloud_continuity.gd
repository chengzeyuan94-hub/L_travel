extends SceneTree
func _initialize() -> void:
 call_deferred("run")
func run() -> void:
 var cloud=load("res://scripts/traveler/day_clouds.gd").new()
 root.add_child(cloud)
 cloud._settings=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/day_clouds_params.json"))
 var node:=Node3D.new()
 root.add_child(node)
 cloud._clouds.append({"node":node,"set":"day","material":null,"original_transform":Transform3D.IDENTITY,"local_axis":Vector3.RIGHT,"initial_center":0.0,"half_span":10000.0,"speed":0.084})
 cloud.apply_time(0.0)
 cloud.apply_time(600.0)
 var initial:=node.position.x
 var previous:=initial
 var max_step:=0.0
 var min_step:=INF
 var t:=600.0
 # Enter after ten minutes, reverse at mid-transition, then resume.
 for i in 720:
  var blend:float
  if i<240:blend=float(i)/480.0
  elif i<480:blend=0.5-float(i-240)/480.0
  else:blend=float(i-480)/240.0
  cloud.set_period_blend(blend,true)
  t+=1.0/30.0
  cloud.apply_time(t)
  var step:float=node.position.x-previous
  min_step=minf(min_step,step)
  max_step=maxf(max_step,step)
  previous=node.position.x
 var before:=node.transform
 for i in 60:cloud.apply_time(t)
 var result={"late_start_time_s":600.0,"min_step_u":min_step,"max_step_u":max_step,"conservative_max_step_u":0.084*16.0*1.12/30.0,"always_forward":min_step>=0.0,"no_time_multiplier_jump":max_step<=0.051,"same_time_transform_unchanged":node.transform==before,"phases":"late transition, mid-transition reverse, forward transition","command_args":OS.get_cmdline_args()}
 var output:=""
 for arg in OS.get_cmdline_user_args():
  if arg.begins_with("--out="):output=arg.trim_prefix("--out=")
 if output.is_empty() or FileAccess.file_exists(output):
  push_error("Use --out=<new JSON path>")
  quit(1)
  return
 FileAccess.open(output,FileAccess.WRITE).store_string(JSON.stringify(result,"\t"))
 print(JSON.stringify(result))
 quit()
