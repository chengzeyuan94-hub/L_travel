class_name CustomMapAssetMeta
extends RefCounted
## Optional local metadata. Map loading never depends on this file.
const SCHEMA := "lshu.asset_library.v1"
static var test_fail_commit := false
static var test_fail_finalize := false
static func path() -> String: return CustomMapStore.maps_dir().path_join("asset_library/index.json")
static func _parse(file: String) -> Dictionary:
 if not FileAccess.file_exists(file) or _blocked(file): return {}
 var json := JSON.new()
 if json.parse(FileAccess.get_file_as_string(file)) != OK: return {}
 var value: Variant = json.data
 if not value is Dictionary or value.get("schema") != SCHEMA or not value.get("items") is Dictionary: return {}
 for id in value.items:
  if not id is String or not CustomMapLocalAssets.valid_id(id) or not value.items[id] is Dictionary: return {}
  var item: Dictionary = value.items[id]
  if not item.get("tags",[]) is Array or not item.get("claims",[]) is Array or not item.get("archived",false) is bool: return {}
  for claim in item.get("claims",[]):
   if not claim is Dictionary or claim.get("rights") not in ["private_unknown","owned","permission"]: return {}
 return _normalize(value) if _valid_candidate(value) else {}
static func load_index() -> Dictionary:
 var data := _parse(path())
 if not data.is_empty(): return {"ok":true,"data":data,"message":"部分附属元数据缺失，已用结构默认值显示；缺失的名称、标签与许可声明未知。" if data.items.values().any(func(item:Dictionary)->bool:return not item.get("unknown_fields",[]).is_empty()) else ""}
 data = _parse(path()+".bak")
 if not data.is_empty(): return {"ok":true,"data":data,"message":"附属元数据损坏，已读取备份；保存后恢复。","from_backup":true}
 return {"ok":true,"data":{"schema":SCHEMA,"items":{}},"message":"附属元数据未知；可从文件与引用重建结构，名称、标签、许可声明和归档状态不能凭空恢复。" if FileAccess.file_exists(path()) else ""}
static func _blocked(file: String) -> bool:
 var dir:=DirAccess.open(file.get_base_dir())
 return DirAccess.dir_exists_absolute(file) or (dir!=null and dir.is_link(file.get_file()))
static func _write_guard() -> String:
 var root:=CustomMapStore.maps_dir()
 var dir:=DirAccess.open(root)
 if dir!=null and dir.is_link("asset_library"):return "元数据目录符号链接被拒绝"
 for file in [path(),path()+".bak",path()+".next",path()+".old",path()+".next.tmp",path()+".old.tmp"]:
  if _blocked(file):return "元数据路径受阻，未提交"
 return ""
static func _valid_candidate(data: Dictionary) -> bool:
 if data.get("schema") != SCHEMA or not data.get("items") is Dictionary:return false
 for id in data.items:
  if not id is String or not CustomMapLocalAssets.valid_id(id) or not data.items[id] is Dictionary:return false
  var item:Dictionary=data.items[id]
  if not item.get("tags",[]) is Array or not item.get("claims",[]) is Array or not item.get("archived",false) is bool:return false
  if item.get("purpose_hint","") not in ["","city_model","good_icon","actor_model","badge_icon","city_intro"]:return false
  if not item.get("purpose_hints",[]) is Array or not item.get("unknown_fields",[]) is Array:return false
  for purpose in item.get("purpose_hints",[]):
   if purpose not in ["city_model","good_icon","actor_model","badge_icon","city_intro"]:return false
  for unknown in item.get("unknown_fields",[]):
   if not unknown is String or unknown not in default_item(id):return false
  for field in ["display_name","note","purpose_hint","derived_from","imported_at","archived_at"]:
   if item.has(field) and not item[field] is String:return false
  if str(item.get("display_name","")).length()>80 or str(item.get("note","")).length()>2000:return false
  for tag in item.get("tags",[]):
   if not tag is String or tag.length()>80:return false
  if item.get("tags",[]).size()>32:return false
  for claim in item.get("claims",[]):
   if not claim is Dictionary or claim.get("rights") not in ["private_unknown","owned","permission"] or not claim.get("source","") is String:return false
 return true
static func _normalize(data:Dictionary)->Dictionary:
 var normalized:Dictionary={"schema":SCHEMA,"items":{}}
 for id in data.get("items",{}):
  var defaults:=default_item(str(id));var missing:Array=[]
  for field in defaults:
   if not data.items[id].has(field):missing.append(field)
  defaults.merge(data.items[id],true)
  if not missing.is_empty():defaults.unknown_fields=missing
  normalized.items[id]=defaults
 return normalized
static func _stage(data: Dictionary) -> Dictionary:
 if not _valid_candidate(data):return CustomMapLocalAssets.fail("附属元数据格式不符，未保存")
 if test_fail_commit:return CustomMapLocalAssets.fail("元数据写入失败，未提交")
 var guard:=_write_guard()
 if guard!="":return CustomMapLocalAssets.fail(guard)
 var old_text:=FileAccess.get_file_as_string(path()) if FileAccess.file_exists(path()) else ""
 var old:=_parse(path())
 var error:=CustomMapStore.atomic_write(path()+".next",JSON.stringify(_normalize(data),"  ",true)+"\n")
 if error!=OK:return CustomMapLocalAssets.fail("元数据无法暂存，未提交")
 if not old.is_empty():
  error=CustomMapStore.atomic_write(path()+".old",old_text)
  if error!=OK:DirAccess.remove_absolute(path()+".next");return CustomMapLocalAssets.fail("元数据备份无法暂存，未提交")
 return {"ok":true,"old_text":old_text,"backup":not old.is_empty(),"had_primary":FileAccess.file_exists(path())}
static func _unstage()->void:
 for file in [path()+".next",path()+".old"]:
  if FileAccess.file_exists(file):DirAccess.remove_absolute(file)
static func _finish(staged: Dictionary) -> Dictionary:
 if test_fail_finalize:_unstage();return CustomMapLocalAssets.fail("元数据最终提交失败，未提交")
 var error:=DirAccess.rename_absolute(path()+".next",path())
 if error!=OK:_unstage();return CustomMapLocalAssets.fail("元数据提交失败，未提交")
 if staged.backup:
  error=DirAccess.rename_absolute(path()+".old",path()+".bak")
  if error!=OK:
   # Restore the previous visible primary; existing backup never changed.
   CustomMapStore.atomic_write(path(),str(staged.old_text));_unstage()
   return CustomMapLocalAssets.fail("元数据备份提交失败，已回滚")
 return {"ok":true}
static func commit(data: Dictionary) -> Dictionary:
 var staged:=_stage(data)
 if not staged.ok:return staged
 return _finish(staged)
static func default_item(id: String) -> Dictionary:
 return {"display_name":id.substr(0,12),"note":"","tags":[],"purpose_hint":"","purpose_hints":[],"imported_at":"","derived_from":"","archived":false,"archived_at":"","claims":[]}
static func edit(id: String, fields: Dictionary) -> Dictionary:
 if not CustomMapLocalAssets.valid_id(id) or not FileAccess.file_exists(CustomMapLocalAssets.path(id)): return CustomMapLocalAssets.fail("本机文件不存在，不能编辑元数据")
 var data: Dictionary = load_index().data.duplicate(true)
 var item: Dictionary = data.items.get(id,default_item(id)).duplicate(true)
 for key in fields:
  if key not in ["display_name","note","tags","purpose_hint","derived_from"]: return CustomMapLocalAssets.fail("元数据字段不支持")
 if str(fields.get("display_name",item.display_name)).length()>80 or str(fields.get("note",item.note)).length()>2000: return CustomMapLocalAssets.fail("名称或备注太长")
 if fields.has("tags") and not fields.tags is Array: return CustomMapLocalAssets.fail("标签格式不符")
 item.merge(fields,true);data.items[id]=item
 return commit(data)
static func admit(checked: Dictionary, fields: Dictionary, rights: String, source_note: String) -> Dictionary:
 if not checked.get("ok",false) or rights not in ["private_unknown","owned","permission"]: return CustomMapLocalAssets.fail("没有有效入库预览或许可声明")
 var data: Dictionary = load_index().data.duplicate(true)
 var id := str(checked.id)
 var item: Dictionary = data.items.get(id,default_item(id)).duplicate(true)
 var existed := FileAccess.file_exists(CustomMapLocalAssets.path(id))
 if not data.items.has(id):
  item.merge(fields,true);item.imported_at=Time.get_datetime_string_from_system();item.purpose_hint=str(fields.get("purpose_hint",checked.kind))
 var purpose:=str(fields.get("purpose_hint",checked.kind))
 var purposes:Array=item.get("purpose_hints",[]).duplicate()
 if str(item.get("purpose_hint",""))!="" and item.purpose_hint not in purposes:purposes.append(item.purpose_hint)
 if purpose not in purposes:purposes.append(purpose)
 item.purpose_hints=purposes
 # Every distinct declaration survives content deduplication. Never promote unknown rights.
 var claims: Array = item.get("claims",[]).duplicate(true)
 var found := false
 for claim in claims:
  if claim.rights==rights and str(claim.get("source",""))==source_note: found=true
 if not found: claims.append({"rights":rights,"source":source_note,"at":Time.get_datetime_string_from_system()})
 item.claims=claims;data.items[id]=item
 var staged:=_stage(data)
 if not staged.ok:return staged
 # Allocate a rollback destination before any public content write. Only new bytes
 # from this transaction can move here; every pre-existing SHA stays untouched.
 var quarantine:=path().get_base_dir().path_join("uncommitted")
 if not existed and DirAccess.make_dir_recursive_absolute(quarantine)!=OK and not DirAccess.dir_exists_absolute(quarantine):
  _unstage();return CustomMapLocalAssets.fail("无法准备事务回滚目录，未入库")
 var published:=CustomMapLocalAssets.publish(checked)
 if not published.ok:_unstage();return published
 var finished:=_finish(staged)
 if not finished.ok:
  if not existed:
   var rollback:=DirAccess.rename_absolute(CustomMapLocalAssets.path(id),quarantine.path_join(id))
   CustomMapLocalAssets._checked.erase(id)
   if rollback!=OK:return CustomMapLocalAssets.fail("元数据失败且新文件隔离回滚受阻；请刷新诊断。地图未改变")
  return finished
 return {"ok":true,"id":id,"duplicate":existed,"claims":claims.size()}
static func archive(id: String, value: bool, refs: Array) -> Dictionary:
 if not CustomMapLocalAssets.valid_id(id) or not FileAccess.file_exists(CustomMapLocalAssets.path(id)): return CustomMapLocalAssets.fail("只能归档我的本机文件")
 if value and not refs.is_empty(): return CustomMapLocalAssets.fail("仍有本机已知引用，不能归档")
 var data: Dictionary = load_index().data.duplicate(true)
 var item: Dictionary = data.items.get(id,default_item(id)).duplicate(true)
 item.archived=value;item.archived_at=Time.get_datetime_string_from_system() if value else "";data.items[id]=item
 return commit(data)

static func declare(id:String,rights:String,source_note:String)->Dictionary:
 if rights not in ["private_unknown","owned","permission"] or not FileAccess.file_exists(CustomMapLocalAssets.path(id)):return CustomMapLocalAssets.fail("许可或本机文件不符")
 var data:Dictionary=load_index().data.duplicate(true)
 var item:Dictionary=data.items.get(id,default_item(id)).duplicate(true)
 var claims:Array=item.get("claims",[]).duplicate(true)
 for claim in claims:
  if claim.rights==rights and str(claim.get("source",""))==source_note:return {"ok":true,"unchanged":true}
 claims.append({"rights":rights,"source":source_note,"at":Time.get_datetime_string_from_system()});item.claims=claims;data.items[id]=item
 return commit(data)
