class_name CustomMapCloudFloat
extends Node3D
## Trusted visual wrapper for explicitly registered, verified fixed cloud presets.
## Imported GLBs retain the original no-root-translation gate. Navigation stays
## on the original CustomTransportSkin parent; no gameplay state or RNG is used.
var _player:AnimationPlayer
var _height:=0.0
static func attach(visual:Node3D,height_world:float)->Node3D:
 if not is_finite(height_world) or height_world<=0.0 or height_world>10000.0:return null
 var player:AnimationPlayer
 for item:AnimationPlayer in CustomMapActorAssets.animation_players(visual):
  if item.has_animation("idle") and item.has_animation("move"):player=item;break
 if player==null or visual.get_parent()==null:return null
 var bob:=CustomMapCloudFloat.new();bob.name="CloudVisualFloat";bob.process_priority=1;bob._player=player;bob._height=height_world
 var parent:=visual.get_parent();parent.remove_child(visual);parent.add_child(bob);bob.add_child(visual)
 return bob
func _process(_delta:float)->void:
 position=Vector3.ZERO
 if not is_visible_in_tree() or not is_instance_valid(_player) or not _player.is_playing():return
 var clip:=String(_player.current_animation)
 if clip not in ["idle","move"]:return
 var animation:=_player.get_animation(clip)
 if animation==null or animation.length<=0.0:return
 var phase:=TAU*fmod(_player.current_animation_position,animation.length)/animation.length
 var ratio:=0.007 if clip=="idle" else 0.012
 # A small fixed clearance keeps the thick cloud above its original token plane.
 position.y=_height*(0.018+ratio*sin(phase))
