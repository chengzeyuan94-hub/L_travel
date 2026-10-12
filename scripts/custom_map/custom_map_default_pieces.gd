class_name CustomMapDefaultPieces
extends RefCounted
## App-owned defaults use the same fingerprint, actor and two-asset budget gates
## as private transport overrides. No model or texture is duplicated by colour.
const Assets:=preload("res://scripts/custom_map/custom_map_local_assets.gd")
const Team:=preload("res://scripts/custom_map/custom_map_default_team_materials.gd")
const ROOT:="res://assets/piece_presets/lshu_defaults/"
const SPECS:={
 "CAMEL":{"asset":Team.CAMEL_ASSET,"size":1.0,"yaw":90.0,"pivot":0.0,"idle":"idle","move":"walk"},
 "SHIP":{"asset":Team.BOAT_ASSET,"size":1.0,"yaw":90.0,"pivot":0.10,"idle":"","move":""}
}
static func model(transport:String)->String:
 return ROOT+str(SPECS.get(transport,{}).get("asset",""))
static func read_default(transport:String)->Dictionary:
 if not SPECS.has(transport):return {"ok":false,"message":"默认交通类型不存在"}
 var id:String=SPECS[transport].asset
 if FileAccess.file_exists(Assets.path(id)):return Assets.read(id,"actor_model")
 var pending:=Assets.inspect_bytes(FileAccess.get_file_as_bytes(model(transport)),"actor_model",true)
 if not pending.ok or pending.id!=id:return {"ok":false,"message":"默认商旅模型指纹不符"}
 return Assets.publish(pending)
static func preflight(doc:Dictionary)->Dictionary:
 var resolved:Dictionary=doc.get("piece_skins",{}).get("transports",{}).duplicate(true)
 var budget_doc:=doc.duplicate(true);var overrides:Dictionary={}
 if not budget_doc.has("assets"):budget_doc.assets={"version":1,"entries":{},"bindings":{}}
 for transport in SPECS:
  if resolved.has(transport):continue
  var spec:Dictionary=SPECS[transport];var bytes:=FileAccess.get_file_as_bytes(model(transport))
  if bytes.is_empty():return {"ok":false,"message":"默认商旅模型缺失"}
  budget_doc.assets.entries[spec.asset]={"kind":"actor_model","bytes":bytes.size(),"rights":"private_unknown"}
  overrides[spec.asset]=bytes;resolved[transport]=spec.duplicate(true)
 var plan:=Assets.preflight_doc(budget_doc,"",overrides)
 if not plan.ok:return plan
 plan["specs"]=resolved
 return plan
static func prepare(content:Dictionary)->Dictionary:
 var doc:Dictionary=content.get("custom_map",{}).get("overlay",{}).duplicate(true)
 # Merged content is the authoritative runtime transport selection.
 doc["piece_skins"]={"version":1,"transports":content.get("piece_skins",{}).duplicate(true)}
 var plan:=preflight(doc)
 if not plan.ok:return plan
 for transport in SPECS:
  var id:String=plan.specs[transport].asset
  if id!=str(SPECS[transport].asset):continue
  var checked:=read_default(transport)
  if not checked.ok or checked.id!=id:return {"ok":false,"message":"默认商旅模型校验失败"}
 return plan
