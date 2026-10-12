class_name CustomMapCamelLocomotion
extends RefCounted
## Owns visual animation only. The original Token planner and arrival time own
## game movement. Large native strides stay legible without stretching a turn.
const PERIOD := 2.4
const DUTY := 0.60
const HALF_STRIDE := 0.100
const TRANSITION := 1.4
const MIN_WALK_HZ := 0.45
const MAX_WALK_HZ := 1.60
const MAX_PACE_HZ := 2.40
const PACE_DUTY := 0.425
const WALK_DISTANCE_MODEL := 0.3468734230070653
const PACE_DISTANCE_MODEL := 0.5369037180482341
const GAIT_BLEND_SECONDS := 0.15
const START_WINDOW := 0.16
const STOP_WINDOW := 0.24
var player: AnimationPlayer
var skeleton: Skeleton3D
var distance_per_cycle := 0.0
var phase := 0.0
var frequency := 0.0
var state := "idle"
var clock := 0.0
var _body_size := 1.1
var gait := "walk"
var duty := DUTY
var gait_blend := 0.0
var _model_scale := 1.0
var _previous_gait := "walk"
var _knots := PackedFloat32Array()
var _averages := PackedFloat32Array()
var _travel_s := 0.0
var phase_increment := 0.0
var _stop_from: Array[Transform3D] = []
var _stop_base: Array[Transform3D] = []
var _root_bone := -1
var _rest: Array[Transform3D] = []
var _partners: Array[int] = []
func _init(root: Node3D, body_size: float) -> void:
 _body_size = maxf(body_size, 0.001)
 var todo: Array[Node] = [root]
 while not todo.is_empty():
  var node: Node = todo.pop_back(); todo.append_array(node.get_children())
  if node is AnimationPlayer: player = node
  if node is Skeleton3D: skeleton = node
 assert(player != null and skeleton != null)
 for clip in ["idle", "walk", "pace", "start", "stop", "turn_left"]: assert(player.has_animation(clip))
 player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
 player.speed_scale = 0.0
 _model_scale = root.get_child(1).scale.x
 distance_per_cycle = WALK_DISTANCE_MODEL * _model_scale
 _root_bone = skeleton.find_bone("root")
 for i in skeleton.get_bone_count():
  _rest.append(skeleton.get_bone_global_rest(i))
  var name := skeleton.get_bone_name(i)
  var counterpart := name
  for pair in [["LF_", "RF_"], ["LH_", "RH_"]]:
   if name.begins_with(pair[0]): counterpart = str(pair[1]) + name.substr(3)
   elif name.begins_with(pair[1]): counterpart = str(pair[0]) + name.substr(3)
  _partners.append(skeleton.find_bone(counterpart))
 reset()
func reset() -> void:
 phase = 0.0; frequency = 0.0; clock = 0.0; state = "idle"
 gait = "walk"; duty = DUTY; gait_blend = 0.0; _travel_s = 0.0; phase_increment = 0.0; _knots.clear(); _averages.clear(); distance_per_cycle = WALK_DISTANCE_MODEL * _model_scale
 _stop_from.clear(); _stop_base.clear(); _seek("idle", 0.0)
func begin(knots: PackedFloat32Array, durations: PackedFloat32Array, kinds: PackedStringArray) -> void:
 phase = 0.0; frequency = 0.0; clock = 0.0; state = "start"
 _knots = knots.duplicate(); _averages.clear(); _travel_s = 0.0; gait_blend = 0.0
 for i in kinds.size(): _averages.append((knots[i+1]-knots[i])/maxf(durations[i],0.001) if kinds[i] == "edge" else 0.0)
 gait = "pace" if not _averages.is_empty() and _averages[0] > WALK_DISTANCE_MODEL*_model_scale*MAX_WALK_HZ else "walk"
 duty = PACE_DUTY if gait == "pace" else DUTY
 distance_per_cycle = (PACE_DISTANCE_MODEL if gait == "pace" else WALK_DISTANCE_MODEL)*_model_scale
 _stop_from.clear(); _stop_base.clear()
func _seek(clip: String, time: float) -> void:
 if player.current_animation != clip: player.play(clip)
 player.seek(clampf(time, 0.0, player.get_animation(clip).length), true)
func _pose_array() -> Array[Transform3D]:
 var out: Array[Transform3D] = []
 for i in skeleton.get_bone_count(): out.append(skeleton.get_bone_pose(i))
 return out
func _mirror_turn() -> void:
 var source: Array[Transform3D] = []
 for i in skeleton.get_bone_count(): source.append(skeleton.get_bone_global_pose(i))
 var mirror := Transform3D(Basis.from_scale(Vector3(-1, 1, 1)), Vector3.ZERO)
 for i in skeleton.get_bone_count():
  var other := _partners[i]
  skeleton.set_bone_global_pose(i, mirror * source[other] * _rest[other].affine_inverse() * mirror * _rest[i])
func _settle(u: float) -> void:
 if state != "stop":
  _stop_from = _pose_array(); _seek("stop", 0.0); _stop_base = _pose_array()
  state = "stop"
 _seek("stop", clampf(u, 0.0, 1.0) * TRANSITION)
 var fade := 1.0 - smoothstep(0.0, 1.0, u)
 for i in skeleton.get_bone_count():
  var native_pose := skeleton.get_bone_pose(i)
  var delta_q := _stop_from[i].basis.get_rotation_quaternion() * _stop_base[i].basis.get_rotation_quaternion().inverse()
  skeleton.set_bone_pose_rotation(i, Quaternion.IDENTITY.slerp(delta_q, fade) * native_pose.basis.get_rotation_quaternion())
  skeleton.set_bone_pose_position(i, native_pose.origin + (_stop_from[i].origin - _stop_base[i].origin) * fade)
 if u >= 1.0: state = "idle"; clock = 0.0; frequency = 0.0
func update(dt: float, shown: bool, moving: bool, ds: float, speed: float,
 elapsed: float, pre_seconds: float, run_seconds: float, turn_diff: float) -> void:
 if not shown:
  reset(); return
 if moving and elapsed < pre_seconds:
  state = "turn"; clock = elapsed; frequency = 0.0
  _seek("turn_left", clampf(elapsed / maxf(pre_seconds, 0.001), 0.0, 1.0) * 2.4)
  if turn_diff > 0.0: _mirror_turn()
  # Heading belongs to the original route follower; remove the clip's15deg root yaw.
  skeleton.set_bone_pose_rotation(_root_bone, skeleton.get_bone_rest(_root_bone).basis.get_rotation_quaternion())
 elif moving:
  var run_time := maxf(elapsed - pre_seconds, 0.0)
  var start_window := minf(START_WINDOW, run_seconds * 0.12)
  var stop_window := minf(STOP_WINDOW, run_seconds * 0.15)
  _travel_s += maxf(ds,0.0)
  var span := 0
  while span+1 < _averages.size() and _travel_s >= _knots[span+1]: span += 1
  var average := _averages[span] if not _averages.is_empty() else absf(speed)
  var walk_capacity := WALK_DISTANCE_MODEL*_model_scale*MAX_WALK_HZ
  var next_gait := gait
  if average <= walk_capacity or absf(speed) < walk_capacity*.80: next_gait = "walk"
  elif absf(speed) > walk_capacity*.95: next_gait = "pace"
  if next_gait != gait:
   _previous_gait = gait; gait = next_gait; gait_blend = GAIT_BLEND_SECONDS
  duty = PACE_DUTY if gait == "pace" else DUTY
  distance_per_cycle = (PACE_DISTANCE_MODEL if gait == "pace" else WALK_DISTANCE_MODEL)*_model_scale
  var cap := MAX_PACE_HZ if gait == "pace" else MAX_WALK_HZ
  phase_increment = minf(absf(ds)/distance_per_cycle,cap*dt) if absf(speed) > .01 else 0.0
  frequency = phase_increment/maxf(dt,.000001)
  if run_time < start_window:
   state = "start"; _seek("start", run_time / maxf(start_window, 0.001) * TRANSITION)
  elif run_time >= run_seconds - stop_window:
   _settle(clampf((run_time - run_seconds + stop_window) / maxf(stop_window, 0.001), 0.0, 1.0))
  else:
   state = gait; phase += phase_increment
   var old_pose: Array[Transform3D] = []
   if gait_blend > 0.0:
    _seek(_previous_gait,fposmod(phase,1.0)*PERIOD); old_pose = _pose_array()
   _seek(gait,fposmod(phase,1.0)*PERIOD)
   if gait_blend > 0.0:
    gait_blend = maxf(0.0,gait_blend-dt)
    var mix := smoothstep(0.0,1.0,1.0-gait_blend/GAIT_BLEND_SECONDS)
    for i in skeleton.get_bone_count():
     var target := skeleton.get_bone_pose(i)
     skeleton.set_bone_pose_rotation(i,old_pose[i].basis.get_rotation_quaternion().slerp(target.basis.get_rotation_quaternion(),mix))
     skeleton.set_bone_pose_position(i,old_pose[i].origin.lerp(target.origin,mix))
 elif state in ["walk", "pace", "start", "turn", "stop"]:
  # Finish the short blend on arrival; never add time to the original busy/arrival contract.
  _settle(1.0)
 else:
  frequency = 0.0; clock += dt; _seek("idle", fposmod(clock, 3.2))
func stop() -> void:
 if is_instance_valid(player): player.stop()
 player = null; skeleton = null
