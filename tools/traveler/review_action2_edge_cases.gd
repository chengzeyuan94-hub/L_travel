extends SceneTree
var host:Node3D
var cc:Node3D
var checks:Dictionary={}
var output:=""
func _initialize() -> void:call_deferred("run")
func advance_until_hold(limit:int=1200) -> bool:
	for i in limit:
		cc._process(1.0/60.0)
		if cc.mode=="dusk_hold":return true
		if i%30==0:await process_frame
	return false
func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):output=arg.trim_prefix("--out=")
	if output.is_empty() or FileAccess.file_exists(output):push_error("Use a new --out=JSON path");quit(1);return
	var wrapper:Node=load("res://tools/traveler/action2_preview.tscn").instantiate()
	root.add_child(wrapper)
	host=wrapper.host
	# Request during deferred collision/model setup, before character readiness.
	host.toggle_period_transition()
	while not wrapper.review_ready:await process_frame
	cc=host.character_controller
	checks["startup_request_retained"]=cc.mode=="to_gate"
	cc.set_process(false)
	checks["startup_reaches_dusk_hold"]=await advance_until_hold()
	# Reverse to day, then immediately back to dusk before any translation.
	var before:Vector3=cc.actor.global_position
	host.toggle_period_transition()
	cc._process(0.1)
	host.toggle_period_transition()
	checks["reverse_does_not_teleport"]=cc.actor.global_position.distance_to(before)<0.06
	checks["same_position_reversal_finishes"]=await advance_until_hold()
	# Force a long-frame attempt through the courtyard bush. Runtime must stop
	# at the last clear step, even if a malformed caller bypasses path finding.
	var safe_screen:Vector2=cc.screen_position
	var bush_world:=Vector3(29.87,0.6927,8.03)
	var bush_screen:Vector2=host.camera.unproject_position(bush_world)
	cc.mode="to_gate"
	cc.route=PackedVector2Array([bush_screen])
	cc._play("walk")
	cc._process(2.0)
	checks["runtime_sweep_stops_bad_route"]=cc.collision_stops>0 and cc.obstacles.is_clear(cc.actor.global_position,cc.clearance_radius,cc.clearance_height,cc.clearance_bottom)
	checks["blocked_route_is_not_arrival"]=cc.mode!="dusk_hold" and cc.state!="bow"
	# Positive tests from imported geometry, including closed-volume interiors.
	var positive:Dictionary={"city_bush":bush_world,"tree":Vector3(31.04891,0.697129,9.282379),"rock":Vector3(31.643,0.731845,10.046)}
	for kind in positive:
		checks[kind+"_solid"]=not cc.obstacles.is_clear(positive[kind],cc.clearance_radius,cc.clearance_height,cc.clearance_bottom)
	var pass_all:=true
	for value in checks.values():pass_all=pass_all and bool(value)
	FileAccess.open(output,FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"all_pass":pass_all,"scope":"Production controller and actual physics world. Accelerated controller time for startup/reversal/forced invalid long-step cases; not performance measurement.","obstacles":cc.obstacles.report,"collision_stops":cc.collision_stops,"source_gate_screen":str(safe_screen),"commands":{"executable":OS.get_executable_path(),"args":OS.get_cmdline_args(),"user_args":OS.get_cmdline_user_args()}},"\t"))
	print("ACTION2_EDGE_CASES ",JSON.stringify(checks))
	quit(0 if pass_all else 1)
