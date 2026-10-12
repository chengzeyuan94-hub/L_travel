class_name CustomMapAssetRefs
extends RefCounted
## Read-only scanner. External retained bundles are outside the known local scope.
static func _json(file: String) -> Dictionary:
 var json := JSON.new()
 if not FileAccess.file_exists(file) or json.parse(FileAccess.get_file_as_string(file))!=OK: return {}
 return json.data if json.data is Dictionary else {}
static var scan_warnings:Array=[]
static var test_extra_bundle_roots:Array=[]
static func files(dir:String)->PackedStringArray:
 var out:=PackedStringArray()
 if not DirAccess.dir_exists_absolute(dir):
  if FileAccess.file_exists(dir) or _linked(dir):scan_warnings.append(dir+" 不是可扫描目录")
  return out
 var directory:=DirAccess.open(dir)
 if directory==null or directory.list_dir_begin()!=OK:scan_warnings.append(dir+" 目录无法枚举，引用范围未知");return out
 var file:=directory.get_next()
 while file!="":
  if not directory.current_is_dir():out.append(file)
  file=directory.get_next()
 directory.list_dir_end();return out
static func _safe_doc(doc:Dictionary)->bool:
 if doc.is_empty() or not doc.get("map_id") is String or not CustomMapStore.valid_map_id(str(doc.map_id)) or doc.get("schema") not in CustomMapSchema.SUPPORTED_SCHEMAS:return false
 if not (doc.get("catalogue_version") is int or doc.get("catalogue_version") is float) or int(doc.catalogue_version)<1 or int(doc.catalogue_version)>CustomMapSchema.CATALOGUE_VERSION:return false
 if not doc.get("tradegen") is String or doc.tradegen not in CustomMapSchema.KNOWN_TRADEGENS or not doc.get("name") is String or doc.name.strip_edges().is_empty():return false
 if not doc.get("base") is Dictionary:return false
 for field in ["ruleset_id","edition_id","graph_sig"]:
  if not doc.base.get(field) is String or doc.base[field].is_empty():return false
 for layer_name in ["assets","city_intro_cards","piece_skins"]:
  if doc.has(layer_name) and (not doc[layer_name] is Dictionary or doc[layer_name].get("version")!=1):return false
 for pair in [["assets","entries"],["assets","bindings"],["city_intro_cards","cards"],["piece_skins","transports"]]:
  var layer:Variant=doc.get(pair[0],{})
  if not layer is Dictionary or (doc.has(pair[0]) and not layer.get(pair[1]) is Dictionary):return false
  for key in layer.get(pair[1],{}):
   if not layer[pair[1]][key] is Dictionary:return false
 if doc.has("assets"):
  for id in doc.assets.get("entries",{}):
   var entry:Dictionary=doc.assets.entries[id]
   if not CustomMapLocalAssets.valid_id(str(id)) or entry.get("kind") not in ["city_model","good_icon","actor_model"] or entry.get("rights") not in ["private_unknown","owned","permission"] or not (entry.get("bytes") is int or entry.get("bytes") is float):return false
  for slot in doc.assets.get("bindings",{}):
   for role in doc.assets.bindings[slot]:
    if not doc.assets.bindings[slot][role] is String:return false
 for card in doc.get("city_intro_cards",{}).get("cards",{}).values():
  if not card.get("image","") is String:return false
 for spec in doc.get("piece_skins",{}).get("transports",{}).values():
  if not spec.get("asset","") is String:return false
 return true
static func _linked(file:String)->bool:
 var parent:=DirAccess.open(file.get_base_dir())
 return parent!=null and parent.is_link(file.get_file())
static func documents(current: Dictionary) -> Array:
 var out: Array = []
 if not current.is_empty(): out.append({"scope":"current","file":"当前未保存文档","doc":current})
 var installed_path:=CustomMapStore.maps_dir().path_join("installed.json")
 var installed := {} if _linked(installed_path) else _json(installed_path)
 var installed_exists:=FileAccess.file_exists(installed_path) or DirAccess.dir_exists_absolute(installed_path) or _linked(installed_path)
 var installed_ok:bool=not _linked(installed_path) and installed.get("schema")==CustomMapSchema.INSTALL_SCHEMA and installed.get("overlay") is Dictionary and _safe_doc(installed.overlay)
 if installed_ok:installed_ok=str(installed.get("sha256",""))==CustomMapSchema.sha256(installed.overlay)
 if installed_exists and not installed_ok:scan_warnings.append("installed.json 安装副本损坏，引用范围未知")
 if installed_ok:out.append({"scope":"installed","file":"installed.json","doc":installed.overlay})
 for folder in ["library","autosave","trash"]:
  var dir := CustomMapStore.maps_dir().path_join(folder)
  if _linked(dir):scan_warnings.append(folder+"目录为符号链接，未扫描");continue
  for file in files(dir):
   if not (file.ends_with(".json") or file.ends_with(".json.bak")):continue
   if _linked(dir.path_join(file)):scan_warnings.append(folder+"/"+file+"为符号链接，未扫描");continue
   var value := _json(dir.path_join(file))
   var doc: Variant = value.get("doc",value) if folder=="trash" else value
   if not doc is Dictionary or not doc.has("map_id") or not _safe_doc(doc):scan_warnings.append(folder+"/"+file+"损坏，引用范围未知");continue
   if doc is Dictionary and doc.has("map_id"):out.append({"scope":folder+"_bak" if file.ends_with(".bak") else folder,"file":folder+"/"+file,"doc":doc})
 return out
static func add(out: Dictionary, id: String, role: String, target: String, row: Dictionary, rights := "") -> void:
 if id=="":return
 if not out.has(id):out[id]=[]
 var doc: Dictionary = row.get("doc",{})
 out[id].append({"id":id,"scope":row.scope,"file":row.file,"map_id":str(doc.get("map_id","")),"map_name":str(doc.get("name","")),"doc_sha":CustomMapSchema.sha256(doc) if not doc.is_empty() else "","role":role,"target":target,"rights":rights,"kind":str(doc.get("assets",{}).get("entries",{}).get(id,{}).get("kind",""))})
static func scan(current: Dictionary, builtin: Array = []) -> Dictionary:
 var out: Dictionary = {}
 scan_warnings=[]
 for row in documents(current):
  if not _safe_doc(row.doc):scan_warnings.append(str(row.file)+"引用结构损坏");continue
  var doc: Dictionary = row.doc
  var entries: Dictionary = doc.get("assets",{}).get("entries",{})
  for slot in doc.get("assets",{}).get("bindings",{}):
   var binding: Dictionary=doc.assets.bindings[slot]
   for role in binding:
    var id := str(binding[role]);add(out,id,str(role),str(slot),row,str(entries.get(id,{}).get("rights","")))
  for cid in doc.get("city_intro_cards",{}).get("cards",{}):
   var id := str(doc.city_intro_cards.cards[cid].get("image",""));add(out,id,"city_intro",str(cid),row,str(entries.get(id,{}).get("rights","")))
  for kind in doc.get("piece_skins",{}).get("transports",{}):
   var id := str(doc.piece_skins.transports[kind].get("asset",""));add(out,id,"piece",str(kind),row,str(entries.get(id,{}).get("rights","")))
  # Entries that survive old maps protect files even if the binding is absent.
  for id in entries:
   var seen:=false
   for ref in out.get(id,[]):
    if ref.file==row.file and ref.scope==row.scope:seen=true
   if not seen:add(out,str(id),"entry","保留依赖",row,str(entries[id].get("rights","")))
 for item in builtin:
  var id := str(item.get("content_id",""))
  if id!="":add(out,id,"registered",str(item.get("semantic_id","")),{"scope":"implicit","file":str(item.get("path",""))})
 # Implicit historical defaults, public/private registered bundles and fixtures.
 for path in [CustomMapDefaultPieces.model("CAMEL"),CustomMapDefaultPieces.model("SHIP"),"res://assets/merchant_board_claude/player/player_camel.glb","res://assets/merchant_board_claude/player/player_boat.glb","res://assets/piece_presets/lshu_defaults/"+CustomMapDefaultTeamMaterials.OLD_CAMEL_ASSET]:
  if FileAccess.file_exists(path):add(out,FileAccess.get_sha256(path)+"."+path.get_extension(),"default/historical",path,{"scope":"implicit","file":path})
 for root in ["res://data/custom_map","res://tests/fixtures/custom_map"]+test_extra_bundle_roots:_scan_bundles(str(root),out)
 var local_files:=files(CustomMapLocalAssets.root())
 if not scan_warnings.is_empty():
  for id in local_files:
   if CustomMapLocalAssets.valid_id(id):add(out,id,"unknown_reference_scope","损坏文档保护",{"scope":"unknown","file":"、".join(scan_warnings)})
 return {"warnings":scan_warnings.duplicate(),"items":out,"scanned_at":Time.get_datetime_string_from_system(),"note":"本机已知引用；包含当前稿、库、备份、安装副本、自动存档、回收站与内置注册。外部携带包无法检查。"}
static func _scan_bundles(root: String,out: Dictionary) -> void:
 for file in files(root):
  if file!="map.json":continue
  var doc:=_json(root.path_join(file))
  if not _safe_doc(doc):scan_warnings.append(root.path_join(file)+"引用结构损坏");continue
  for id in doc.get("assets",{}).get("entries",{}):add(out,str(id),"bundle",str(doc.get("map_id","")),{"scope":"implicit_bundle","file":root.path_join(file),"doc":doc},str(doc.assets.entries[id].get("rights","")))
 if not DirAccess.dir_exists_absolute(root):return
 var directory:=DirAccess.open(root)
 if directory==null or directory.list_dir_begin()!=OK:scan_warnings.append(root+" 目录无法枚举，引用范围未知");return
 var folder:=directory.get_next()
 while folder!="":
  if directory.current_is_dir() and folder not in ["assets","tradegen_ref"]:
   if directory.is_link(folder):scan_warnings.append(root.path_join(folder)+" 为符号链接，未扫描")
   else:_scan_bundles(root.path_join(folder),out)
  folder=directory.get_next()
 directory.list_dir_end()
static func dependencies(doc: Dictionary) -> Array:
 var out:Array=[]
 if not _safe_doc(doc):return [{"id":"未知","kind":"未知","ok":false,"uses":[],"message":"依赖结构损坏；先从备份或携带包恢复。"}]
 var refs: Dictionary=scan(doc).items
 for id in doc.get("assets",{}).get("entries",{}):
  var entry:Dictionary=doc.assets.entries[id]
  var checked:=CustomMapLocalAssets.read(str(id),str(entry.kind))
  var valid:bool=checked.ok and checked.get("bytes",PackedByteArray()).size()==int(entry.bytes)
  var uses:Array=[]
  for ref in refs.get(id,[]):
   if ref.scope=="current":uses.append(ref.role+" · "+ref.target)
  out.append({"id":id,"kind":entry.kind,"ok":valid,"uses":uses,"message":"可用" if valid else "缺失或损坏：%s…用于%s；可用『打开资产包』恢复"%[str(id).substr(0,12),"、".join(uses)]})
 return out
