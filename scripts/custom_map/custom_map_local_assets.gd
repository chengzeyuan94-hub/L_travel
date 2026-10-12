class_name CustomMapLocalAssets
extends RefCounted
## Private, content-addressed v3 dependencies; v1/v2 stay readable. No source filename/path is persisted.
const SCHEMA := "lshu.custom_map.v3"
const LIMIT := 16 * 1024 * 1024
const IMAGE_LIMIT := 8 * 1024 * 1024
const MAX_SIDE := 2048
const Budget:=preload("res://scripts/custom_map/custom_map_texture_budget.gd")
static var image_decode_calls:=0
static var native_import_calls:=0
static var _high_order:Array=[]
static var _checked: Dictionary = {}
static var _textures: Dictionary = {}
static func root() -> String: return CustomMapStore.maps_dir().path_join("assets")
static func valid_id(id: String) -> bool:
 var re := RegEx.new(); re.compile("^[a-f0-9]{64}\\.(glb|png|jpg)$"); return re.search(id) != null
static func path(id: String) -> String: return root().path_join(id) if valid_id(id) else ""
static func release_actor(id:String)->void:
 if _checked.has(id) and _checked[id].get("high_resolution",false):_checked.erase(id)
 _high_order.erase(id)
static func release_high_cache()->void:
 for id in _high_order.duplicate():release_actor(id)
static func _remember_checked(checked:Dictionary)->void:
 if checked.get("high_resolution",false):
  _high_order.erase(checked.id)
  while _high_order.size()>=2:release_actor(str(_high_order[0]))
  _high_order.append(checked.id)
 _checked[checked.id]=checked
static func fail(message: String) -> Dictionary:
 release_high_cache()
 return {"ok": false, "message": message}
static func _hash(bytes: PackedByteArray) -> String:
 var h := HashingContext.new(); h.start(HashingContext.HASH_SHA256); h.update(bytes); return h.finish().hex_encode()
static func inspect_file(source: String, kind: String) -> Dictionary:
 if kind not in ["city_model", "good_icon", "badge_icon", "actor_model"]: return fail("素材用途不认识")
 if not FileAccess.file_exists(source): return fail("文件不存在")
 var f := FileAccess.open(source, FileAccess.READ)
 if f == null or f.get_length() > (LIMIT if kind in ["city_model","actor_model"] else IMAGE_LIMIT): return fail("文件太大或不能读取")
 var bytes := f.get_buffer(f.get_length()); f.close()
 var ext := source.get_extension().to_lower()
 if (kind in ["city_model","actor_model"] and ext != "glb") or (kind in ["good_icon","badge_icon"] and ext not in ["png", "jpg", "jpeg"]): return fail("只支持城市 GLB、商品 PNG/JPEG")
 return inspect_bytes(bytes, kind)
static func inspect_bytes(bytes: PackedByteArray, kind: String, metadata_only:=false) -> Dictionary:
 if kind == "actor_model":return CustomMapActorAssets.inspect_bytes(bytes,metadata_only)
 if kind in ["good_icon","badge_icon","actor_texture"]:
  if bytes.size() > IMAGE_LIMIT or bytes.size() < 24: return fail("图片体积不合要求")
  var max_side:int=4096 if kind=="actor_texture" else MAX_SIDE
  var header:=Budget.image_header(bytes,max_side)
  if not header.ok:return fail(header.message)
  if metadata_only:return {"ok":true,"id":_hash(bytes)+"."+header.ext,"kind":kind,"bytes":bytes,"width":header.width,"height":header.height,"decoded_texture_bytes":int(header.pixels)*4,"high_resolution":false}
  image_decode_calls+=1
  var img := Image.new(); var ext := ""
  if bytes.slice(0,8) == PackedByteArray([137,80,78,71,13,10,26,10]):
   var w := bytes.decode_u32(16); var h := bytes.decode_u32(20)
   # PNG fields are big endian; reverse byte order before checking allocation.
   w = (w & 255) << 24 | (w & 65280) << 8 | (w >> 8 & 65280) | (w >> 24 & 255)
   h = (h & 255) << 24 | (h & 65280) << 8 | (h >> 8 & 65280) | (h >> 24 & 255)
   if w < 1 or h < 1 or w > max_side or h > max_side: return fail("图片边长须为1–2048像素")
   if not _png_complete(bytes): return fail("PNG 区块截断或结构损坏")
   if img.load_png_from_buffer(bytes) != OK: return fail("PNG 已损坏")
   ext = "png"
  elif bytes[0] == 255 and bytes[1] == 216:
   # Find a JPEG SOF dimension marker before actual decode.
   var at := 2; var found := false
   while at + 8 < bytes.size():
    if bytes[at] != 255: return fail("JPEG 结构损坏")
    var marker := bytes[at+1]; at += 2
    if marker == 255: at -= 1; continue
    if marker in [216,217] or marker in range(208,216): continue
    if marker == 218: break
    if at+2 > bytes.size(): return fail("JPEG 截断")
    var length := int(bytes[at]) * 256 + int(bytes[at+1])
    if length < 2 or at+length > bytes.size(): return fail("JPEG 截断")
    if marker in [192,193,194]:
     var h := int(bytes[at+3])*256+int(bytes[at+4]); var w := int(bytes[at+5])*256+int(bytes[at+6])
     if w < 1 or h < 1 or w > max_side or h > max_side: return fail("图片边长须为1–2048像素")
     found = true; break
    at += length
   if bytes[bytes.size()-2]!=255 or bytes[bytes.size()-1]!=217:return fail("JPEG 截断")
   if not found or img.load_jpg_from_buffer(bytes) != OK: return fail("JPEG 已损坏或格式不支持")
   ext = "jpg"
  else: return fail("不是实际 PNG/JPEG 图片")
  if img.is_empty() or img.get_width() > max_side or img.get_height() > max_side: return fail("图片尺寸不合要求")
  if img.get_width()!=int(header.width) or img.get_height()!=int(header.height):return fail("图片解码尺寸与预检不符")
  if kind=="actor_texture" and (int(header.depth)!=8 or img.get_data().size()>int(header.pixels)*4):return fail("高分纹理解码格式或字节量超限")
  return {"ok":true,"id":_hash(bytes)+"."+ext,"kind":kind,"bytes":bytes,"image":img,"width":img.get_width(),"height":img.get_height()}
 if kind not in ["city_model","actor_base"] or bytes.size() < 28 or bytes.size() > LIMIT: return fail("GLB 体积不合要求")
 if bytes.decode_u32(0) != 0x46546C67 or bytes.decode_u32(4) != 2 or bytes.decode_u32(8) != bytes.size(): return fail("不是完整的 GLB 2 文件")
 var length := int(bytes.decode_u32(12))
 if bytes.decode_u32(16) != 0x4E4F534A or length < 2 or 20+length+8 > bytes.size(): return fail("GLB JSON 数据损坏")
 var parsed: Variant = JSON.parse_string(bytes.slice(20,20+length).get_string_from_utf8())
 if not parsed is Dictionary: return fail("GLB JSON 损坏")
 var d: Dictionary = parsed
 if _has_uri(d): return fail("GLB 必须自包含，禁止任何 URI 或外部依赖")
 if not d.get("asset") is Dictionary or d.asset.get("version") != "2.0": return fail("GLB 版本不支持")
 for key in ["nodes","meshes","materials","textures","images","accessors","bufferViews","buffers","skins","animations","cameras","extensionsUsed","scenes","samplers"]:
  if not d.get(key,[]) is Array: return fail("GLB 数组字段损坏")
 for pair in [["nodes",128],["meshes",64],["materials",64],["textures",32],["images",32],["accessors",512],["bufferViews",512],["buffers",1],["scenes",32],["samplers",32]]:
  if d.get(pair[0],[]).size() > pair[1]: return fail("GLB 节点、网格、材质或纹理超过上限")
 if not d.get("skins",[]).is_empty() or not d.get("animations",[]).is_empty() or not d.get("cameras",[]).is_empty(): return fail("仅支持静态城市，不支持骨骼、动画、相机或扩展")
 if not d.get("extensionsUsed",[]) is Array: return fail("GLB 扩展字段损坏")
 for extension in d.get("extensionsUsed",[]):
  if extension not in ["KHR_materials_emissive_strength","KHR_materials_unlit"]: return fail("不支持此 GLB 扩展")
 if not _integer_fields(d): return fail("GLB 整数引用或缓冲区字段损坏")
 var binary := 20+length
 if bytes.decode_u32(binary+4) != 0x004E4942 or binary+8+bytes.decode_u32(binary) != bytes.size(): return fail("GLB BIN 数据损坏或有多余区块")
 var bin := bytes.slice(binary+8)
 if d.get("buffers",[]).size() != 1 or not d.buffers[0] is Dictionary or int(d.buffers[0].get("byteLength",-1)) < 0 or int(d.buffers[0].get("byteLength",-1)) > bin.size(): return fail("GLB 缓冲区损坏")
 for v in d.get("bufferViews",[]):
  if not v is Dictionary or int(v.get("buffer",-1)) != 0 or int(v.get("byteOffset",0)) < 0 or int(v.get("byteLength",-1)) < 0 or int(v.get("byteOffset",0))+int(v.get("byteLength",-1)) > bin.size(): return fail("GLB 缓冲区越界")
 var vertices := 0
 for ac in d.get("accessors",[]):
  if not ac is Dictionary or not CustomMapLandscape._number(ac.get("count")) or int(ac.count) < 0 or int(ac.count) > 300000 or ac.has("sparse"): return fail("GLB 顶点数量或结构超限")
  vertices += int(ac.count)
 if vertices > 1000000: return fail("GLB 总几何数据超限")
 var structure_error := _structure_error(d,bin)
 if structure_error != "": return fail(structure_error)
 var texture_plan:=Budget.glb_plan(bytes,kind=="actor_base")
 if not texture_plan.ok:return fail(texture_plan.message)
 if metadata_only:return {"ok":true,"id":_hash(bytes)+".glb","kind":kind,"bytes":bytes,"high_resolution":texture_plan.high_resolution,"decoded_texture_bytes":texture_plan.decoded_texture_bytes}
 var decoded_texture_bytes := 0
 for im in d.get("images",[]):
  if not im is Dictionary or not im.get("bufferView") is float and not im.get("bufferView") is int: return fail("纹理必须嵌入 BIN")
  var i := int(im.bufferView)
  if i < 0 or i >= d.bufferViews.size(): return fail("GLB 纹理引用越界")
  var v: Dictionary = d.bufferViews[i]; var texture := inspect_bytes(bin.slice(int(v.get("byteOffset",0)),int(v.get("byteOffset",0))+int(v.byteLength)),"actor_texture" if texture_plan.high_resolution else "good_icon")
  if not texture.ok: return fail("GLB 纹理："+texture.message)
  if im.get("mimeType") not in ["image/png","image/jpeg"] or (im.mimeType=="image/png")!=(texture.id.get_extension()=="png"):return fail("GLB 纹理 MIME 与实际图片不符")
  decoded_texture_bytes += texture.width * texture.height * 4
  if decoded_texture_bytes > (192 * 1024 * 1024 if texture_plan.high_resolution else 64 * 1024 * 1024): return fail("GLB 解码纹理总量超过64 MB")
 native_import_calls+=1
 var document := GLTFDocument.new(); var state := GLTFState.new()
 if document.append_from_buffer(bytes,"",state) != OK: return fail("GLB 实际解码失败")
 var scene := document.generate_scene(state)
 if scene == null: return fail("GLB 场景生成失败")
 var actual_error := _actual_budget_error(scene)
 if actual_error != "":
  scene.free();return fail(actual_error)
 var boxes: Array = []; CustomMapPlants._collect_bounds(scene,Transform3D.IDENTITY,boxes)
 var box := AABB()
 for b: AABB in boxes: box = b if box.size == Vector3.ZERO else box.merge(b)
 if boxes.is_empty() or not box.position.is_finite() or not box.size.is_finite() or maxf(box.size.x,box.size.z) <= 0.00001 or box.size.length() > 10000 or box.position.length() > 100000 or box.size.y / maxf(box.size.x,box.size.z) > 4.0:
  scene.free(); return fail("GLB 没有有效城市网格或坐标超限")
 var packed := PackedScene.new(); _owners(scene,scene)
 var err := packed.pack(scene); scene.free()
 if err != OK: return fail("GLB 不能创建预览")
 return {"ok":true,"id":_hash(bytes)+".glb","kind":kind,"bytes":bytes,"scene":packed,"bounds":box,"nodes":d.get("nodes",[]).size(),"meshes":d.get("meshes",[]).size(),"materials":d.get("materials",[]).size(),"textures":d.get("images",[]).size(),"high_resolution":texture_plan.high_resolution,"decoded_texture_bytes":texture_plan.decoded_texture_bytes}
static func _owners(node: Node, owner: Node) -> void:
 for c in node.get_children(): c.owner=owner; _owners(c,owner)
static func _has_uri(v: Variant, depth := 0) -> bool:
 if depth > 64:return true
 if v is Dictionary:
  for k in v:
   if str(k).to_lower() in ["uri","script"] or _has_uri(v[k],depth+1): return true
 elif v is Array:
  for x in v:
   if _has_uri(x,depth+1): return true
 return false
static func publish(pending: Dictionary) -> Dictionary:
 if not pending.get("ok",false) or not valid_id(str(pending.get("id",""))): return fail("未校验素材不能应用")
 var checked := inspect_bytes(pending.bytes,pending.kind)
 if not checked.ok or checked.id != pending.id: return fail("预览素材已改变")
 var parent := DirAccess.open(CustomMapStore.maps_dir())
 if parent != null and parent.is_link("assets"): return fail("资源目录符号链接被拒绝")
 var destination := path(checked.id)
 var dir := DirAccess.open(root())
 if dir != null and (dir.is_link(checked.id) or dir.is_link(checked.id + ".tmp")): return fail("资源文件符号链接被拒绝")
 if FileAccess.file_exists(destination):
  if FileAccess.get_sha256(destination) != checked.id.get_basename(): return fail("既有资源指纹冲突，未覆盖")
 else:
  var err := CustomMapStore._atomic(destination,checked.bytes)
  if err != OK: return fail("资源复制失败，地图未改变")
 _remember_checked(checked)
 return checked
static func read(id: String, kind: String) -> Dictionary:
 var file := path(id)
 var dir := DirAccess.open(root())
 var parent := DirAccess.open(CustomMapStore.maps_dir())
 if (dir != null and dir.is_link(id)) or (parent != null and parent.is_link("assets")): return fail("资源符号链接被拒绝")
 if file == "" or not FileAccess.file_exists(file) or FileAccess.get_sha256(file) != id.get_basename(): return fail("缺少资源或指纹不符")
 if _checked.has(id) and _checked[id].kind == kind: return _checked[id]
 var checked := inspect_file(file,kind)
 if checked.ok and checked.id == id: _remember_checked(checked); return checked
 return fail("资源实际格式或用途不符")
static func layer_error(doc: Dictionary) -> String:
 if not doc.has("assets"): return ""
 if doc.get("schema") not in [SCHEMA,"lshu.custom_map.v4","lshu.custom_map.v5","lshu.custom_map.v6"] or not doc.assets is Dictionary: return "私用素材只允许在 v3 地图副本中保存"
 var a: Dictionary = doc.assets
 if a.size()!=3 or a.get("version")!=1 or not a.get("entries") is Dictionary or not a.get("bindings") is Dictionary or a.entries.size()>entry_limit(doc) or a.bindings.size()>(20 if doc.has("city_badges") else 4): return "私用素材清单格式或数量不符"
 var plan:=preflight_doc(doc)
 if not plan.ok:return plan.message
 var slots := {}
 if not doc.get("new_cities",[]) is Array: return "新城市字段损坏"
 for c in doc.get("new_cities",[]):
  if not c is Dictionary: return "新城市记录损坏"
  slots[str(c.get("slot",""))]=true
 for id in a.entries:
  var e: Variant=a.entries[id]
  if not id is String or not valid_id(id) or not e is Dictionary or e.size()!=3 or e.get("kind") not in ["city_model","good_icon","actor_model"] or e.get("rights") not in ["owned","permission","private_unknown"] or not CustomMapLandscape._number(e.get("bytes")) or float(e.bytes)!=floor(float(e.bytes)) or float(e.bytes)<1 or float(e.bytes)>LIMIT: return "私用素材字段不合法"
  if e.kind=="actor_model" and doc.get("schema") not in ["lshu.custom_map.v5","lshu.custom_map.v6"]:return "角色素材需要第五版地图"
  var checked:=read(id,e.kind)
  if not checked.ok or checked.bytes.size()!=int(e.bytes): return "私用素材缺失、损坏或指纹不符"
 for slot in a.bindings:
  if not a.bindings[slot] is Dictionary: return "私用素材目标城市不存在"
  for kind in a.bindings[slot]:
   var id: Variant=a.bindings[slot][kind]
   if (not slots.has(slot) and (kind != "badge_icon" or not CustomMapLoader.base_content().get("cities", {}).has(slot))) or kind not in ["city_model","good_icon","badge_icon"] or not id is String or not a.entries.has(id) or (a.entries[id].kind!=kind and not (kind=="badge_icon" and a.entries[id].kind=="good_icon")): return "私用素材绑定不合法"
 return ""
static func bound_id(doc: Dictionary, slot: String, kind: String) -> String:
 return str(doc.get("assets",{}).get("bindings",{}).get(slot,{}).get(kind,""))
static func bound_path(doc: Dictionary, slot: String, kind: String, fallback: String) -> String:
 var id:=bound_id(doc,slot,kind); return path(id) if id!="" else fallback
static func candidate(doc: Dictionary, slot: String, pending: Dictionary, rights: String) -> Dictionary:
 var out:=doc.duplicate(true)
 if str(out.schema) not in [SCHEMA,"lshu.custom_map.v4","lshu.custom_map.v5","lshu.custom_map.v6"]: out.schema=SCHEMA; out.map_id=preload("res://scripts/map_workshop/workshop_backend.gd").new_map_id()
 if not out.has("assets"): out.assets={"version":1,"entries":{},"bindings":{}}
 if pending.kind!="badge_icon" or not out.assets.entries.has(pending.id):
  out.assets.entries[pending.id]={"kind":"good_icon" if pending.kind=="badge_icon" else pending.kind,"bytes":pending.bytes.size(),"rights":rights}
 if not out.assets.bindings.has(slot): out.assets.bindings[slot]={}
 out.assets.bindings[slot][pending.kind]=pending.id
 prune(out)
 return out
static func prune(doc:Dictionary)->void:
 if not doc.get("assets") is Dictionary:return
 if not doc.assets.get("entries") is Dictionary or not doc.assets.get("bindings") is Dictionary:return
 var used:Dictionary={}
 for bind in doc.assets.bindings.values():
  if not bind is Dictionary:return
  for id in bind.values():
   if not id is String:return
   used[id]=true
 for layer_info in [["city_intro_cards","cards","image"],["piece_skins","transports","asset"]]:
  var layer:Variant=doc.get(layer_info[0],{})
  if not layer is Dictionary or not layer.get(layer_info[1],{}) is Dictionary:return
  for ref in layer.get(layer_info[1],{}).values():
   if not ref is Dictionary or not ref.get(layer_info[2],"") is String:return
   var id:String=ref.get(layer_info[2],"")
   if id!="":used[id]=true
 for id in doc.assets.entries.keys():
  if not used.has(id):doc.assets.entries.erase(id)
static func export_bundle(doc: Dictionary, destination: String) -> Dictionary:
 if DirAccess.dir_exists_absolute(destination) or FileAccess.file_exists(destination): return fail("目标已存在，未覆盖；请选择新目录")
 var bad:=layer_error(doc)
 if bad!="": return fail(bad)
 var temporary:=destination+".pending_"+Crypto.new().generate_random_bytes(8).hex_encode()
 var err:=DirAccess.make_dir_recursive_absolute(temporary.path_join("assets"))
 if err!=OK: return fail("不能创建导出目录")
 for id in doc.get("assets",{}).get("entries",{}):
  var e: Dictionary=doc.assets.entries[id]; var checked:=read(id,e.kind)
  if not checked.ok or CustomMapStore._atomic(temporary.path_join("assets").path_join(id),checked.bytes)!=OK:
   _remove_owned_stage(temporary); return fail("资源复制失败，导出未提交")
 if CustomMapStore.atomic_write(temporary.path_join("map.json"),JSON.stringify(CustomMapSchema.round_coords(doc),"  ",true)+"\n")!=OK:
  _remove_owned_stage(temporary); return fail("地图写入失败")
 err=DirAccess.rename_absolute(temporary,destination)
 if err!=OK: _remove_owned_stage(temporary); return fail("导出提交失败，目标未覆盖")
 return {"ok":true,"directory":destination}
static func inspect_bundle(map_file: String) -> Dictionary:
 if map_file.get_file()!="map.json" or not FileAccess.file_exists(map_file): return fail("请选择资产包内 map.json")
 var f:=FileAccess.open(map_file,FileAccess.READ)
 if f==null or f.get_length()>CustomMapSchema.MAX_FILE_BYTES: return fail("地图文件太大或无法读取")
 var parsed:=CustomMapValidator.parse_text(f.get_as_text()); f.close()
 if not parsed.errors.is_empty(): return fail("地图 JSON 损坏")
 var doc: Dictionary=parsed.doc; var a: Variant=doc.get("assets",{})
 if not a is Dictionary or not a.get("entries",{}) is Dictionary or a.get("entries",{}).size()>entry_limit(doc): return fail("资源清单不合法")
 var meta:=preflight_doc(doc,map_file.get_base_dir().path_join("assets"))
 if not meta.ok:return meta
 var pending: Array=[]
 for id in a.get("entries",{}):
  if not id is String or not valid_id(id): return fail("资源名禁止绝对路径或路径穿越")
  var entry: Variant=a.entries[id]
  if not entry is Dictionary or entry.get("kind") not in ["city_model","good_icon","actor_model"] or not CustomMapLandscape._number(entry.get("bytes")): return fail("资源用途不合法")
  var parent:=DirAccess.open(map_file.get_base_dir())
  if parent==null or parent.is_link("assets"): return fail("资产目录符号链接被拒绝")
  var folder:=map_file.get_base_dir().path_join("assets"); var dir:=DirAccess.open(folder)
  if dir==null or dir.is_link(id): return fail("资源缺失或符号链接被拒绝")
  var checked:=inspect_file(folder.path_join(id),entry.kind)
  if not checked.ok or checked.id!=id or checked.bytes.size()!=int(entry.get("bytes",-1)): return fail("资源指纹、体积或实际格式不符")
  pending.append(checked)
 return {"ok":true,"doc":doc,"pending":pending,"source_sha":FileAccess.get_sha256(map_file),"source_path":map_file}
static func _remove_owned_stage(directory: String) -> void:
 var dir:=DirAccess.open(directory.path_join("assets"))
 if dir!=null:
  for name in dir.get_files(): DirAccess.remove_absolute(directory.path_join("assets").path_join(name))
  DirAccess.remove_absolute(directory.path_join("assets"))
 if FileAccess.file_exists(directory.path_join("map.json")): DirAccess.remove_absolute(directory.path_join("map.json"))
 DirAccess.remove_absolute(directory)
static func _index(value: Variant, count: int) -> bool:
 return CustomMapLandscape._number(value) and float(value)==floor(float(value)) and int(value)>=0 and int(value)<count
static func _finite(value: Variant, depth := 0) -> bool:
 if depth>64:return false
 if value is float:return is_finite(value)
 if value is Dictionary:
  for v in value.values():
   if not _finite(v,depth+1):return false
 elif value is Array:
  for v in value:
   if not _finite(v,depth+1):return false
 return true
static func _structure_error(d: Dictionary, binary: PackedByteArray) -> String:
 if _unsupported_extensions(d):return "GLB 包含不支持的扩展数据"
 if not _finite(d):return "GLB 数值非有限或嵌套过深"
 var nodes: Array=d.get("nodes",[]);var parents:Dictionary={}
 for i in nodes.size():
  var n: Variant=nodes[i]
  if not n is Dictionary:return "GLB 节点损坏"
  if n.has("mesh") and not _index(n.mesh,d.get("meshes",[]).size()):return "GLB 网格引用越界"
  if n.has("skin") or n.has("camera") or n.has("extensions"):return "GLB 节点包含不支持的绑定或扩展"
  for transform in [["matrix",16],["translation",3],["rotation",4],["scale",3]]:
   if n.has(transform[0]):
    var value: Variant=n[transform[0]]
    if not value is Array or value.size()!=transform[1]:return "GLB 变换损坏"
    for number in value:
     if not CustomMapLandscape._number(number):return "GLB 变换不是有限数值"
  if not n.get("children",[]) is Array:return "GLB 子节点损坏"
  for child in n.get("children",[]):
   if not _index(child,nodes.size()) or parents.has(int(child)) or int(child)==i:return "GLB 层级引用越界、重复或循环"
   parents[int(child)]=i
 for i in nodes.size():
  var at:=i;var seen:Dictionary={}
  while parents.has(at):
   if seen.has(at):return "GLB 层级循环"
   seen[at]=true;at=parents[at]
 var scenes: Array=d.get("scenes",[])
 if scenes.is_empty():return "GLB 必须包含显式场景"
 if d.has("scene") and not _index(d.scene,scenes.size()):return "GLB 默认场景引用越界"
 for definition in scenes:
  if not definition is Dictionary or not definition.get("nodes",[]) is Array:return "GLB 场景根数组损坏"
  var roots:Dictionary={}
  for root in definition.get("nodes",[]):
   if not _index(root,nodes.size()) or roots.has(int(root)) or parents.has(int(root)):return "GLB 场景根越界、重复或已有父节点"
   roots[int(root)]=true
 var material_error:=_material_error(d)
 if material_error!="":return material_error
 var accessors: Array=d.get("accessors",[]);var views: Array=d.get("bufferViews",[])
 for ac:Dictionary in accessors:
  if not _index(ac.get("bufferView"),views.size()):return "GLB 访问器引用越界"
  var component:int={5120:1,5121:1,5122:2,5123:2,5125:4,5126:4}.get(int(ac.get("componentType",0)),0)
  var components:int={"SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4,"MAT4":16}.get(ac.get("type"),0)
  if ac.has("normalized") and not ac.normalized is bool:return "GLB 访问器 normalized 类型不合法"
  for key in ["min","max"]:
   if ac.has(key):
    var bounds:Variant=ac[key]
    if not bounds is Array or bounds.size()!=components:return "GLB 访问器边界向量不合法"
    for number in bounds:
     if not CustomMapLandscape._number(number):return "GLB 访问器边界不是有限数值"
  var view:Dictionary=views[int(ac.bufferView)];var stride:=int(view.get("byteStride",component*components));var offset:=int(ac.get("byteOffset",0));var count:=int(ac.count)
  if component==0 or components==0 or stride<component*components or offset<0 or (count>0 and offset+(count-1)*stride+component*components>int(view.byteLength)):return "GLB 几何缓冲区越界"
 var triangles:=0;var mesh_triangles:Array=[]
 for mesh in d.get("meshes",[]):
  if not mesh is Dictionary or not mesh.get("primitives") is Array or mesh.primitives.size()>64:return "GLB 网格结构超限"
  var mesh_total:=0
  for primitive in mesh.primitives:
   if not primitive is Dictionary or not primitive.get("attributes") is Dictionary or int(primitive.get("mode",4))!=4 or primitive.has("targets"):return "只支持静态三角形城市网格"
   if not primitive.attributes.has("POSITION"):return "GLB 没有顶点位置"
   for semantic in primitive.attributes:
    if semantic not in ["POSITION","NORMAL","TANGENT","TEXCOORD_0","TEXCOORD_1","COLOR_0"]:return "GLB 顶点属性不支持"
   for index in primitive.attributes.values():
    if not _index(index,accessors.size()):return "GLB 顶点引用越界"
   if primitive.has("indices") and not _index(primitive.indices,accessors.size()):return "GLB 索引越界"
   if primitive.has("material") and not _index(primitive.material,d.get("materials",[]).size()):return "GLB 材质引用越界"
   var position:Dictionary=accessors[int(primitive.attributes.POSITION)]
   if position.type!="VEC3" or int(position.componentType)!=5126 or int(position.count)<1:return "GLB 位置访问器必须为非空浮点 VEC3"
   var count:=int(accessors[int(primitive.get("indices",primitive.attributes.POSITION))].count)
   if count<3 or count%3!=0:return "GLB 三角形顶点或索引数量不合法"
   if primitive.has("indices"):
    var index_accessor:Dictionary=accessors[int(primitive.indices)]
    if index_accessor.type!="SCALAR" or int(index_accessor.componentType) not in [5121,5123,5125]:return "GLB 索引访问器类型不合法"
    var view:Dictionary=views[int(index_accessor.bufferView)]
    var component:int={5121:1,5123:2,5125:4}[int(index_accessor.componentType)]
    var offset:=int(view.get("byteOffset",0))+int(index_accessor.get("byteOffset",0));var stride:=int(view.get("byteStride",component))
    for i in count:
     var at:=offset+i*stride;var vertex:int=binary[at] if component==1 else (binary.decode_u16(at) if component==2 else binary.decode_u32(at))
     if vertex>=int(position.count):return "GLB 实际顶点索引越界"
   triangles+=count/3;mesh_total+=count/3
  mesh_triangles.append(mesh_total)
 if triangles<1 or triangles>250000:return "GLB 三角形数量须为1–250000"
 var selected:Dictionary=scenes[int(d.get("scene",0))];var stack:Array=selected.get("nodes",[]).duplicate();var reachable:Dictionary={};var actual_triangles:=0;var actual_nodes:=0
 while not stack.is_empty():
  var index:int=int(stack.pop_back())
  if reachable.has(index):return "GLB 场景展开重复节点"
  reachable[index]=true;actual_nodes+=1
  if actual_nodes>128:return "GLB 场景展开节点超过128"
  var node:Dictionary=nodes[index]
  if node.has("mesh"):
   actual_triangles+=int(mesh_triangles[int(node.mesh)])
   if actual_triangles>250000:return "GLB 展开实例三角形超过250000"
  stack.append_array(node.get("children",[]))
 if actual_nodes<1 or actual_triangles<1:return "GLB 场景没有可达城市网格"
 for texture in d.get("textures",[]):
  if not texture is Dictionary or not _index(texture.get("source"),d.get("images",[]).size()) or (texture.has("sampler") and not _index(texture.sampler,d.get("samplers",[]).size())):return "GLB 纹理引用越界"
 return ""

static func texture(id: String, kind := "good_icon") -> Texture2D:
 var checked:=read(id,kind)
 if not checked.ok:return null
 var key:=path(id)
 if not _textures.has(key):
  var image:=ImageTexture.create_from_image(checked.image);image.resource_path=key;_textures[key]=image
 return _textures[key]

static func _png_complete(bytes: PackedByteArray) -> bool:
 var at:=8;var count:=0;var seen_header:=false
 while at+12<=bytes.size():
  var n:=int(bytes[at])*16777216+int(bytes[at+1])*65536+int(bytes[at+2])*256+int(bytes[at+3]);var name:=bytes.slice(at+4,at+8).get_string_from_ascii()
  if n<0 or at+12+n>bytes.size() or count>128:return false
  if count==0:
   if name!="IHDR" or n!=13:return false
   seen_header=true
  if name=="IEND":return seen_header and n==0 and at+12==bytes.size()
  at+=12+n;count+=1
 return false
static func _unsupported_extensions(value: Variant) -> bool:
 if value is Dictionary:
  for key in value:
   if key=="extensions":
    if not value[key] is Dictionary:return true
    for extension in value[key]:
     if extension not in ["KHR_materials_emissive_strength","KHR_materials_unlit"]:return true
   if _unsupported_extensions(value[key]):return true
 elif value is Array:
  for x in value:
   if _unsupported_extensions(x):return true
 return false
static func copy_dependencies(doc: Dictionary, directory: String) -> Dictionary:
 var bad:=layer_error(doc)
 if bad!="":return fail(bad)
 if doc.get("assets",{}).get("entries",{}).is_empty():return {"ok":true}
 if DirAccess.make_dir_recursive_absolute(directory)!=OK:return fail("不能创建隔离素材目录")
 for id in doc.assets.entries:
  var checked:=read(id,doc.assets.entries[id].kind)
  var destination:=directory.path_join(id)
  if not checked.ok or FileAccess.file_exists(destination):return fail("隔离素材缺失或目标已存在")
  if CustomMapStore._atomic(destination,checked.bytes)!=OK:return fail("隔离素材复制失败")
 return {"ok":true}

static func _integer_fields(value: Variant) -> bool:
 if value is Dictionary:
  for key in value:
   if key in ["bufferView","buffer","mesh","camera","skin","componentType","count","byteOffset","byteLength","byteStride","indices","material","source","sampler","scene","index","texCoord","mode"]:
    var number:Variant=value[key]
    if not CustomMapLandscape._number(number) or float(number)!=floor(float(number)) or float(number)<0 or float(number)>2147483647:return false
   if not _integer_fields(value[key]):return false
 elif value is Array:
  for x in value:
   if not _integer_fields(x):return false
 return true

# JSON.parse_string represents numbers as floats; Array.has distinguishes float/int.
# Validate the numeric integer value before comparing against the supported enums.
static func _integer_enum(value:Variant, allowed:Array)->bool:
 if not CustomMapLandscape._number(value) or float(value)!=floor(float(value)) or float(value)<0 or float(value)>2147483647:return false
 return int(value) in allowed

static func _material_error(d:Dictionary)->String:
 for sampler in d.get("samplers",[]):
  if not sampler is Dictionary:return "GLB 采样器类型不合法"
  for key in ["wrapS","wrapT"]:
   if sampler.has(key) and not _integer_enum(sampler[key],[33071,33648,10497]):return "GLB 采样器 wrap 不合法"
  if sampler.has("magFilter") and not _integer_enum(sampler.magFilter,[9728,9729]):return "GLB 采样器 magFilter 不合法"
  if sampler.has("minFilter") and not _integer_enum(sampler.minFilter,[9728,9729,9984,9985,9986,9987]):return "GLB 采样器 minFilter 不合法"
 for material in d.get("materials",[]):
  if not material is Dictionary:return "GLB 材质类型不合法"
  if material.has("pbrMetallicRoughness") and not material.pbrMetallicRoughness is Dictionary:return "GLB PBR 材质类型不合法"
  if material.has("doubleSided") and not material.doubleSided is bool:return "GLB 材质布尔值不合法"
  if material.has("alphaMode") and material.alphaMode not in ["OPAQUE","MASK","BLEND"]:return "GLB 材质透明模式不合法"
  if material.has("extensions"):
   if not material.extensions is Dictionary:return "GLB 材质扩展结构不合法"
   for name in material.extensions:
    var extension:Variant=material.extensions[name]
    if not extension is Dictionary:return "GLB 材质扩展字段不合法"
    if name=="KHR_materials_emissive_strength" and (not CustomMapLandscape._number(extension.get("emissiveStrength")) or float(extension.emissiveStrength)<0):return "GLB 发光强度字段不合法"
  var groups:Array=[material,material.get("pbrMetallicRoughness",{})]
  for group:Dictionary in groups:
   for spec in [["baseColorFactor",4],["emissiveFactor",3]]:
    if group.has(spec[0]):
     var factor:Variant=group[spec[0]]
     if not factor is Array or factor.size()!=spec[1]:return "GLB 材质颜色结构不合法"
     for v in factor:
      if not CustomMapLandscape._number(v):return "GLB 材质颜色不是有限数值"
   for key in ["metallicFactor","roughnessFactor","alphaCutoff"]:
    if group.has(key) and not CustomMapLandscape._number(group[key]):return "GLB 材质数值类型不合法"
   for key in ["baseColorTexture","metallicRoughnessTexture","normalTexture","occlusionTexture","emissiveTexture"]:
    if group.has(key):
     var info:Variant=group[key]
     if not info is Dictionary or not _index(info.get("index"),d.get("textures",[]).size()):return "GLB 材质纹理引用越界"
     if info.has("texCoord") and (not _index(info.texCoord,2)):return "GLB 纹理坐标通道不支持"
     for numeric in ["scale","strength"]:
      if info.has(numeric) and not CustomMapLandscape._number(info[numeric]):return "GLB 纹理数值类型不合法"
 return ""
static func _actual_budget_error(scene:Node)->String:
 var stack:Array=[scene];var nodes:=0;var triangles:=0
 while not stack.is_empty():
  var node:Node=stack.pop_back();nodes+=1
  # One generated wrapper is not an imported node; primitive splits still count.
  if nodes>129:return "GLB 实际生成节点超过预算"
  if node.get_script()!=null or node.get_class() not in ["Node3D","MeshInstance3D"]:return "GLB 实际生成节点类型不支持"
  if node is MeshInstance3D:
   var mesh:Mesh=node.mesh
   if mesh==null:return "GLB 实际网格缺失"
   for surface in mesh.get_surface_count():
    if mesh.surface_get_primitive_type(surface)!=Mesh.PRIMITIVE_TRIANGLES:return "GLB 实际网格不是三角形"
    var arrays:Array=mesh.surface_get_arrays(surface);var indices:PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
    var count:int=indices.size() if not indices.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
    if count%3!=0:return "GLB 实际三角形结构不合法"
    triangles+=count/3
    if triangles>250000:return "GLB 实际生成三角形超过预算"
  stack.append_array(node.get_children())
 return "" if triangles>0 else "GLB 实际网格为空"

static func preflight_doc(doc:Dictionary,folder:="",overrides:Dictionary={})->Dictionary:
 var assets:Variant=doc.get("assets",{})
 if not assets is Dictionary:return fail("地图资源层类型不合法")
 var entries:Variant=assets.get("entries",{})
 if not entries is Dictionary or entries.size()>entry_limit(doc):return fail("地图资源元数据不合法")
 var actor_count:=0;var actor_bytes:=0;var plans:Dictionary={}
 var directory:String=root() if folder=="" else folder
 var parent:=DirAccess.open(directory.get_base_dir());var dir:=DirAccess.open(directory)
 var needs_files:=false
 for id in entries:needs_files=needs_files or not overrides.has(id)
 if (parent!=null and parent.is_link(directory.get_file())) or (needs_files and dir==null):return fail("资源目录缺失或符号链接")
 for id in entries:
  var entry:Variant=entries[id]
  if not id is String or not valid_id(id) or not entry is Dictionary or entry.size()!=3 or entry.get("rights") not in ["owned","permission","private_unknown"] or entry.get("kind") not in ["actor_model","city_model","good_icon"] or not CustomMapLandscape._number(entry.get("bytes")) or float(entry.bytes)!=floor(float(entry.bytes)):return fail("资源元数据字段不合法")
  var bytes:PackedByteArray
  if overrides.has(id):
   if not overrides[id] is PackedByteArray:return fail("候选资源字节不合法")
   bytes=overrides[id]
  else:
   if dir==null or dir.is_link(id):return fail("资源缺失或符号链接")
   var f:=FileAccess.open(directory.path_join(id),FileAccess.READ)
   if f==null or f.get_length()<1 or f.get_length()>(IMAGE_LIMIT if entry.kind in ["good_icon","badge_icon"] else LIMIT):return fail("资源体积超限或无法读取")
   bytes=f.get_buffer(f.get_length());f.close()
  if bytes.size()!=int(entry.bytes) or _hash(bytes)!=id.get_basename():return fail("资源元数据指纹或体积不符")
  var plan:=inspect_bytes(bytes,str(entry.kind),true)
  if not plan.ok:return plan
  if plan.get("high_resolution",false):
   actor_count+=1;actor_bytes+=int(plan.decoded_texture_bytes)
   if actor_count>Budget.MAP_ACTORS or actor_bytes>Budget.MAP_BYTES:return fail("地图最多2份高分棋子、384 MiB基础像素")
  plans[id]={"high_resolution":plan.get("high_resolution",false),"decoded_texture_bytes":plan.get("decoded_texture_bytes",0)}
 return {"ok":true,"high_resolution_actors":actor_count,"decoded_actor_bytes":actor_bytes,"plans":plans}
static func preflight_replacement(doc:Dictionary,transport:String,source:String)->Dictionary:
 if transport not in ["CAMEL","SHIP"] or source.get_extension().to_lower()!="glb":return fail("棋子候选类型不合法")
 var f:=FileAccess.open(source,FileAccess.READ)
 if f==null or f.get_length()<1 or f.get_length()>LIMIT:return fail("候选棋子体积超限")
 var bytes:=f.get_buffer(f.get_length());f.close();var id:=_hash(bytes)+".glb";var out:=doc.duplicate(true)
 if not out.has("assets"):out.assets={"version":1,"entries":{},"bindings":{}}
 if not out.has("piece_skins"):out.piece_skins={"version":1,"transports":{}}
 out.piece_skins.transports[transport]={"asset":id}
 out.assets.entries[id]={"kind":"actor_model","bytes":bytes.size(),"rights":"private_unknown"};prune(out)
 return preflight_doc(out,"",{id:bytes})

static func entry_limit(doc: Dictionary) -> int:
 var previous := 30 if doc.get("schema") in ["lshu.custom_map.v5","lshu.custom_map.v6"] else (28 if doc.get("schema")=="lshu.custom_map.v4" else 8)
 return previous + (20 if doc.has("city_badges") else 0)
