extends Node
## One clock and freeze switch for the independent Panti atmosphere and camp fire.
var viewer:Node3D
var params:Dictionary
var tree_wind:RefCounted
var mist:Node3D
var snow:Node3D
var anim_t:=0.0
var frozen:=false
var enabled:=true

func configure(stage:Node3D) -> void:
	viewer=stage;params=viewer.settings.weather
	tree_wind=load("res://scripts/traveler/baghdad/baghdad_tree_wind.gd").new()
	tree_wind.configure(viewer,params.wind)
	mist=load("res://scripts/traveler/baghdad/baghdad_wind_mist.gd").new()
	viewer.world.add_child(mist);mist.configure(viewer,params.mist)
	mist.set_process(false);mist.set_anim_time(anim_t)
	snow=load("res://scripts/traveler/baghdad/baghdad_snowfall.gd").new()
	viewer.world.add_child(snow);snow.configure(viewer,params.snow)
	if viewer.camp!=null:
		viewer.camp.fire.set_process(false)
		viewer.camp.fire.set_anim_time(anim_t)
	set_enabled(bool(params.get("enabled",true)))

func _process(delta:float) -> void:
	if viewer==null or frozen:return
	anim_t+=delta
	tree_wind.set_time(anim_t)
	mist.set_anim_time(anim_t)
	if viewer.camp!=null:viewer.camp.fire.set_anim_time(anim_t)
	if viewer.seated_actor!=null:viewer.seated_actor.set_time(anim_t)
	viewer.tick_period_effects(delta,anim_t)

func set_enabled(value:bool) -> void:
	enabled=value
	tree_wind.set_enabled(value and params.wind.get("enabled",true))
	mist.visible=value and params.mist.get("enabled",true)
	snow.visible=value and params.snow.get("enabled",true)
	set_frozen(frozen)

func set_frozen(value:bool) -> void:
	frozen=value
	mist.freeze(value or not mist.visible)
	snow.freeze(value or not snow.visible)
	if viewer.camp!=null:viewer.camp.fire.freeze(value)
	if viewer.seated_actor!=null:viewer.seated_actor.freeze(value)

func evidence() -> Dictionary:
	return {"enabled":enabled,"frozen":frozen,"anim_t":anim_t,"screen_direction":"right_to_left","tree_wind":tree_wind.evidence(),"mist":mist.evidence(),"snow":snow.evidence(),"camp_fire_uses_same_clock_and_freeze":viewer.camp!=null,"seated_idle":viewer.seated_actor.evidence() if viewer.seated_actor!=null else {"enabled":false}}
