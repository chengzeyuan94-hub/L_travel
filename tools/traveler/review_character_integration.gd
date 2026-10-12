extends SceneTree
## Real-time input forwarding and actual cloud material-bank integration audit.
var output := ""
func _initialize() -> void:
 call_deferred("run")
func click_at(wrapper:Node3D,pixel:Vector2,fast:bool=false) -> void:
 var size:Vector2=root.get_visible_rect().size
 var factor:float=minf(size.x/1920.0,size.y/1080.0)
 var position:Vector2=(size-Vector2(1920,1080)*factor)*0.5+pixel*factor
 for pressed in [true,false]:
  var event:=InputEventMouseButton.new()
  event.button_index=MOUSE_BUTTON_LEFT
  event.position=position
  event.global_position=position
  event.pressed=pressed
  event.shift_pressed=fast
  wrapper._input(event)
func run() -> void:
 for arg in OS.get_cmdline_user_args():
  if arg.begins_with("--out="):output=arg.trim_prefix("--out=")
 if output.is_empty() or FileAccess.file_exists(output):
  push_error("Use --out=<new JSON path>")
  quit(1)
  return
 var wrapper=load("res://tools/traveler/character_preview.tscn").instantiate()
 root.add_child(wrapper)
 while not wrapper.review_ready:await process_frame
 var host=wrapper.host
 var cc=host.character_controller
 var cloud=host.motion_director.day_components["clouds"]
 var initial_position:Vector2=cc.screen_position
 var gate:=Vector2.ZERO
 for city in host.cities:
  if city.id=="changan":
   gate=host.camera.unproject_position(Vector3(city.x,float(city.base)+float(city.scale)*0.65,city.z))
 var records:Array=[]
 var walk_sent:=false
 var run_sent:=false
 var dusk_sent:=false
 var day_sent:=false
 var checks:Dictionary={"original_character":not cc.use_alt_character,"gate_hit":host.period_hotspot_hit(gate),"walk_observed":false,"run_observed":false,"both_banks_visible":false,"dusk_endpoint":false,"day_endpoint":false}
 var began:=Time.get_ticks_msec()
 while float(Time.get_ticks_msec()-began)/1000.0<19.0:
  await process_frame
  var time:=float(Time.get_ticks_msec()-began)/1000.0
  if time>=0.2 and not walk_sent:
   click_at(wrapper,Vector2(288,792))
   walk_sent=true
  if time>=0.8 and not dusk_sent:
   click_at(wrapper,gate)
   dusk_sent=true
  if time>=3.0 and not run_sent:
   click_at(wrapper,Vector2(576,846),true)
   run_sent=true
  if time>=10.0 and not day_sent:
   click_at(wrapper,gate)
   day_sent=true
  var banks:Dictionary={"day":[],"dusk":[]}
  for entry in cloud._clouds:
   banks[entry["set"]].append({"visible":entry["node"].visible,"alpha":entry["material"].get_shader_parameter("bank_alpha"),"position":str(entry["node"].position)})
  checks.walk_observed=checks.walk_observed or cc.state=="walk"
  checks.run_observed=checks.run_observed or cc.state=="run"
  checks.both_banks_visible=checks.both_banks_visible or (banks.day[0].visible and banks.dusk[0].visible and float(banks.day[0].alpha)>0.2 and float(banks.dusk[0].alpha)>0.2)
  checks.dusk_endpoint=checks.dusk_endpoint or (not banks.day[0].visible and float(banks.dusk[0].alpha)>0.999)
  if time>18.2:checks.day_endpoint=not banks.dusk[0].visible and float(banks.day[0].alpha)>0.999
  if records.is_empty() or time-float(records[-1].time_s)>=0.1:
   records.append({"time_s":time,"state":cc.state,"screen_position":str(cc.screen_position),"speed":cc.current_speed_px_s,"period":host.look_profile.current_period_t,"cloud_speed_multiplier":cloud._speed_multiplier,"banks":banks,"foot_correction_u":cc.footing.max_correction_u})
 checks.character_moved=cc.screen_position.distance_to(initial_position)>1.0 or checks.run_observed
 checks.cloud_counts=cloud._clouds.size()==18
 var peak:=0.0
 for record in records:peak=maxf(peak,float(record.cloud_speed_multiplier))
 checks.cloud_accelerates=peak>2.0
 checks.cloud_returns_to_quiet=is_equal_approx(cloud._speed_multiplier,1.0)
 var pass_all:=true
 for value in checks.values():pass_all=pass_all and bool(value)
 var report={"scope":"Real-time frames through character_preview._input -> SubViewport.push_input -> atlas input handling. No manual character or transition ticking.","checks":checks,"all_pass":pass_all,"peak_cloud_speed_multiplier":peak,"gate_native_px":str(gate),"samples":records,"commands":{"exe":OS.get_executable_path(),"args":OS.get_cmdline_args(),"user_args":OS.get_cmdline_user_args()}}
 FileAccess.open(output,FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
 print("INTEGRATION_AUDIT ",JSON.stringify(checks))
 quit(0 if pass_all else 1)
