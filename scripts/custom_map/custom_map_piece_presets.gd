class_name CustomMapPiecePresets
extends RefCounted
const ITEMS := [
 {"id":"lshu_camel","name":"L叔 · 骆驼","transport":"CAMEL","tags":"陆路 · 原生步态","yaw":90.0,"size":1.0,"pivot":0.0,"idle":"idle","move":"walk"},
 {"id":"lshu_boat","name":"L叔 · 小船","transport":"SHIP","tags":"海路 · 航行","yaw":90.0,"size":1.0,"pivot":0.10,"idle":"","move":""}
]
static func items(kind:String)->Array:
 return ITEMS.filter(func(row):return row.transport==kind).duplicate(true)
static func find(id:String)->Dictionary:
 for row in ITEMS:
  if row.id==id:return row.duplicate(true)
 return {}
static func model(id:String)->String:
 var item:=find(id)
 return CustomMapDefaultPieces.model(str(item.transport)) if not item.is_empty() else ""
static func thumbnail(id:String)->String:return "res://assets/piece_presets/general/"+id+".png" if not find(id).is_empty() else ""
static func is_cloud_asset(_id:String)->bool:return false
static func is_legacy_token(_id:String)->bool:return false
