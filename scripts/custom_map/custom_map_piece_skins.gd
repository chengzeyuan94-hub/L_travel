class_name CustomMapPieceSkins
extends RefCounted
const SCHEMA:="lshu.custom_map.v5"
static func error(doc:Dictionary)->String:
 if not doc.has("piece_skins"):return ""
 var layer:Variant=doc.piece_skins
 if doc.get("schema") not in [SCHEMA,"lshu.custom_map.v6"] or not layer is Dictionary or layer.size()!=2 or layer.get("version")!=1 or not layer.get("transports") is Dictionary or layer.transports.size()>2:return "棋子皮肤层格式不合法"
 if not doc.get("assets",{}) is Dictionary or not doc.get("assets",{}).get("entries",{}) is Dictionary:return "棋子资源清单不合法"
 for transport in layer.transports:
  var skin:Variant=layer.transports[transport]
  if transport not in ["CAMEL","SHIP"] or not skin is Dictionary or skin.size()!=6:return "棋子按交通类型绑定，每种一份"
  for spec in [["size",0.25,3.0],["yaw",-180.0,180.0],["pivot",0.0,1.0]]:
   if not CustomMapLandscape._number(skin.get(spec[0])) or float(skin[spec[0]])<spec[1] or float(skin[spec[0]])>spec[2]:return "棋子尺寸、朝向或支点超出范围"
  var id:Variant=skin.get("asset")
  if not id is String or not CustomMapLocalAssets.valid_id(id):return "棋子资源引用不合法"
  var entry:Variant=doc.get("assets",{}).get("entries",{}).get(id)
  if not entry is Dictionary or entry.get("kind") not in ["actor_model","city_model"]:return "棋子资源缺失或用途不合法"
  var checked:=CustomMapLocalAssets.read(id,"actor_model")
  if not checked.ok or checked.id!=id:return "棋子资源实际格式或指纹不符"
  var names:Array=[]
  for clip in checked.clips:names.append(clip.name)
  for key in ["idle","move"]:
   if not skin.get(key) is String or (skin[key]!="" and skin[key] not in names):return "棋子只能选择模型自身已有动画"
 return ""
static func candidate(doc:Dictionary,transport:String,pending:Dictionary,skin:Dictionary,rights:String)->Dictionary:
 var out:=doc.duplicate(true)
 if out.schema not in [SCHEMA,"lshu.custom_map.v6"]:out.schema=SCHEMA;out.map_id=preload("res://scripts/map_workshop/workshop_backend.gd").new_map_id()
 if not out.has("piece_skins"):out.piece_skins={"version":1,"transports":{}}
 out.piece_skins.transports[transport]=skin.duplicate(true)
 if not pending.is_empty():
  if not out.has("assets"):out.assets={"version":1,"entries":{},"bindings":{}}
  if not out.assets.entries.has(pending.id):out.assets.entries[pending.id]={"kind":"actor_model","bytes":pending.bytes.size(),"rights":rights}
 CustomMapLocalAssets.prune(out);return out
static func remove(doc:Dictionary,transport:String)->Dictionary:
 var out:=doc.duplicate(true)
 if out.has("piece_skins"):out.piece_skins.transports.erase(transport)
 CustomMapLocalAssets.prune(out);return out
static func instantiate(checked:Dictionary,skin:Dictionary,base_size:float,preview_motion:bool=false)->Node3D:
 var root:=Node3D.new();root.name="CustomTransportSkin"
 var model:Node3D=checked.scene.instantiate();root.add_child(model)
 if checked.get("high_resolution",false):
  var lease:=Node.new();lease.set_script(preload("res://scripts/custom_map/custom_map_actor_cache_lease.gd"));lease.asset_id=checked.id;root.add_child(lease)
 if checked.id==CustomMapLiaoningVisual.ASSET:CustomMapLiaoningVisual.decorate(model)
 var box:AABB=checked.bounds;var factor:=base_size*float(skin.size)/maxf(box.size.x,box.size.z)
 var normalizer:=Node3D.new();root.remove_child(model);root.add_child(normalizer);normalizer.add_child(model)
 normalizer.scale=Vector3.ONE*factor;normalizer.rotation_degrees.y=float(skin.yaw)
 model.position-=Vector3(box.get_center().x,box.position.y+box.size.y*float(skin.pivot),box.get_center().z)
 if CustomMapPiecePresets.is_cloud_asset(str(skin.get("asset",""))):
  preload("res://scripts/custom_map/custom_map_cloud_float.gd").attach(normalizer,box.size.y*factor)
 if preview_motion and checked.id==CustomMapLiaoningVisual.ASSET:CustomMapLiaoningVisual.attach_preview(root,normalizer)
 return root
static func play(root:Node,clip:String)->void:
 for player:AnimationPlayer in CustomMapActorAssets.animation_players(root):
  if clip=="":player.stop();continue
  if player.has_animation(clip) and (player.current_animation!=clip or not player.is_playing()):
   player.get_animation(clip).loop_mode=Animation.LOOP_LINEAR;player.play(clip)
