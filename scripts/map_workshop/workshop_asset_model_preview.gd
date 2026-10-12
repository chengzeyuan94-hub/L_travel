extends Control
## Shared real renderer for asset detail and exported 192px thumbnails.
const Team := preload("res://scripts/custom_map/custom_map_default_team_materials.gd")
const Token := preload("res://tools/merchant_board_claude_token.gd")
var actor:Node3D
var orbit:Node3D
var viewport:SubViewport
var token:Node3D
var locomotion:CustomMapCamelLocomotion
var moving:=false
var time:=0.0
var mechanism:=""
var preview_error:=""
func builtin_scene(path:String)->Node3D:
 if not FileAccess.file_exists(path):return null
 var document:=GLTFDocument.new();var state:=GLTFState.new()
 if document.append_from_buffer(FileAccess.get_file_as_bytes(path),path.get_base_dir(),state)!=OK:return null
 return document.generate_scene(state) as Node3D
func first_mesh(path:String)->Array:
 var scene:Node3D=builtin_scene(path)
 var todo:Array=[scene]
 var result:Array=[]
 while not todo.is_empty():
  var node:Node=todo.pop_front();todo.append_array(node.get_children())
  if node is MeshInstance3D:
   var transform:=Transform3D.IDENTITY;var parent:Node=node
   while parent!=null and parent!=scene:
    if parent is Node3D:transform=parent.transform*transform
    parent=parent.get_parent()
   result=[node.mesh,transform];break
 scene.free();return result
func _bounds(root:Node3D,geometry:Node3D=null)->AABB:
 var box:=AABB();var first:=true;var todo:Array=[root if geometry==null else geometry]
 while not todo.is_empty():
  var node:Node=todo.pop_back();todo.append_array(node.get_children())
  if node is MeshInstance3D and node.is_visible_in_tree():
   var transform:Transform3D=root.global_transform.affine_inverse()*node.global_transform
   var part:AABB=transform*node.get_aabb()
   box=part if first else box.merge(part);first=false
 return box
func show_item(item:Dictionary, color:Color, mode:String)->void:
 moving=mode=="move";time=0
 var container:=SubViewportContainer.new();container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);container.stretch=true;container.mouse_filter=Control.MOUSE_FILTER_IGNORE;add_child(container)
 viewport=SubViewport.new();viewport.size=Vector2i(830,420);viewport.own_world_3d=true;viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;container.add_child(viewport)
 var root:=Node3D.new();viewport.add_child(root);orbit=Node3D.new();root.add_child(orbit)
 var definition:Dictionary=item.get("definition",{})
 var path:=str(item.get("path",""))
 var is_piece:bool=item.category=="piece"
 var checked:Dictionary={}
 if item.get("user",false):checked=CustomMapLocalAssets.read(str(item.content_id),"actor_model" if is_piece else "city_model")
 elif is_piece:checked=CustomMapLocalAssets.inspect_file(path,"actor_model")
 if is_piece and str(definition.get("id",""))=="legacy_camel":
  token=Token.new();token.camel_size=2.5;orbit.add_child(token);token.setup(self,color);token.set_process(false);token.set_medium("LAND");token.place(Vector3.ZERO,"LAND",0);token._pose(0)
  # Actual original Token mesh, flag material and distance-driven shader pose.
  token.boat.get_parent().hide();token.pin.hide();token.role_label.hide();actor=token;mechanism="原 Token · 四色旗帜与着色器步态"
 elif is_piece and checked.get("ok",false):
  var spec:Dictionary={"asset":checked.id,"size":float(definition.get("size",1)),"yaw":float(definition.get("yaw",90)),"pivot":float(definition.get("pivot",0)),"idle":str(definition.get("idle","idle")),"move":str(definition.get("move","move"))}
  actor=CustomMapPieceSkins.instantiate(checked,spec,2.5,true);orbit.add_child(actor)
  if Team.supports(checked.id):Team.apply(actor,checked.id,color)
  if checked.id==Team.CAMEL_ASSET:
   locomotion=CustomMapCamelLocomotion.new(actor,2.5);mechanism="骨架动画 · 对局步态控制器"
   if moving:locomotion.begin(PackedFloat32Array([0,100]),PackedFloat32Array([100]),PackedStringArray(["edge"]))
  else:
   var clips:Array=[]
   for clip in checked.get("clips",[]):clips.append(str(clip.name))
   var chosen:=str(spec[mode])
   if chosen in clips:CustomMapPieceSkins.play(actor,chosen)
   mechanism="骨架片段" if int(checked.get("skins",0))>0 else ("云漂浮 · 整体轨道动画" if CustomMapPiecePresets.is_cloud_asset(checked.id) else "整体轨道动画")
   if checked.id==CustomMapLiaoningVisual.ASSET:
    CustomMapLiaoningVisual.preview_motion(actor,moving);mechanism="整船浮动 · 四色小旗 · 原版航线航行"
   if checked.id==Team.BOAT_ASSET:mechanism="四色帆旗船舷 · 对局由 Token 航行；此处停泊预览"
 elif not is_piece:
  if item.get("user",false):
   var packed:PackedScene=checked.get("scene")
   if packed!=null:actor=packed.instantiate() as Node3D
  else:actor=builtin_scene(path)
  if actor!=null:orbit.add_child(actor)
 else:preview_error=str(checked.get("message","资源无法预览"));return
 if actor==null:preview_error="运行模型无法加载";return
 var box:=_bounds(actor,token.camel if token!=null else null)
 if not is_piece:
  var factor:=3.2/maxf(maxf(box.size.x,box.size.z),0.01)
  actor.scale*=factor;actor.position=-Vector3(box.get_center().x,box.position.y,box.get_center().z)*factor
  box=_bounds(actor)
 var target:=Vector3(0,box.get_center().y,0)
 var camera:=Camera3D.new();camera.position=target+Vector3(4,3.0,5);camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.size=maxf(4.0,box.size.y*1.4);root.add_child(camera);camera.look_at(target);camera.current=true
 var light:=DirectionalLight3D.new();light.rotation_degrees=Vector3(-40,-35,0);light.light_energy=1.6;root.add_child(light)
 var environment:=WorldEnvironment.new();environment.environment=Environment.new();environment.environment.background_mode=Environment.BG_COLOR;environment.environment.background_color=Color("e5dccb");environment.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;environment.environment.ambient_light_color=Color.WHITE;environment.environment.ambient_light_energy=0.75;root.add_child(environment)
 gui_input.connect(func(event:InputEvent)->void:
  if event is InputEventMouseMotion and event.button_mask&MOUSE_BUTTON_MASK_LEFT:orbit.rotation.y+=event.relative.x*0.012)
func _process(delta:float)->void:
 time+=delta
 if token!=null:
  token.bob_t=time;token.walk_phase=time*5.5 if moving else 0;token._moving=moving;token._speed=1.0 if moving else 0;token._pose(delta)
 if locomotion!=null:locomotion.update(delta,true,moving,delta if moving else 0,1.0 if moving else 0,time,0,100,0)
func _exit_tree()->void:
 if locomotion!=null:locomotion.stop()
 if actor!=null and token==null:CustomMapPieceSkins.play(actor,"")
