class_name CustomMapFreeAuthor
extends RefCounted
## Independent v6 authoring contract. A city has identity before it has a road.
const GENERATOR := "tradegen_v2_free_author_1"
const MAX_CITIES := 4
const BOARD_MAX := Vector2(128.0, 59.63125)
static func enabled(doc:Dictionary)->bool:
 return doc.get("tradegen", "") == GENERATOR or (doc.get("free_routes") is Dictionary and doc.free_routes.get("version") == 2)
static func base_doc(doc:Dictionary)->Dictionary:
 var out:=doc.duplicate(true)
 out.erase("free_routes");out.erase("transport_overrides")
 out.schema="lshu.custom_map.v5";out.tradegen=CustomMapTradegenRegistry.ORIGINAL;out.new_cities=[]
 return out
static func enter(doc:Dictionary,base:Dictionary)->Dictionary:
 if enabled(doc):return doc.duplicate(true)
 var out:=doc.duplicate(true)
 var old_shapes:Dictionary={}
 for city:Dictionary in doc.get("new_cities",[]):
  for c:Dictionary in CustomMapSchema.corridor_entries({"new_cities":[city]}):old_shapes[CustomMapSchema.corridor_id(str(c.slot),str(c.host),str(c.route_type))]=c.get("route",{}).duplicate(true)
 var old:=CustomMapFreeRoutes.specs(base,doc)
 var originals:=CustomMapFreeRoutes.specs(base,base_doc(doc))
 out.schema=CustomMapFreeRoutes.SCHEMA;out.tradegen=GENERATOR
 out.map_id=preload("res://scripts/map_workshop/workshop_backend.gd").new_map_id()
 out.name=CustomMapStore._suffixed_name(str(out.get("name","地图")),"自由")
 out.free_routes={"version":2,"routes":{}};out.transport_overrides={}
 for rid:String in old:
  var r:Dictionary=old[rid]
  if originals.has(rid) and not doc.get("free_routes",{}).get("routes",{}).has(rid):continue
  var stops:Array=r.get("stop_t",[]).duplicate()
  if stops.is_empty():
   for i:int in r.stop_ids.size():stops.append(float(i+1)/float(r.stop_ids.size()+1))
  var edit:Dictionary=old_shapes.get(rid,doc.get("moves",{}).get("routes",{}).get(rid,{}))
  if edit.has("stop_t") and not r.has("stop_t"):stops=edit.stop_t.duplicate()
  out.free_routes.routes[rid]={"a":r.a,"b":r.b,"type":r.type,"handles":r.get("handles",edit.get("handles",[])).duplicate(true),"stop_t":stops}
 for rid:String in originals:
  if not old.has(rid):out.free_routes.routes[rid]={"deleted":true}
 for c:Dictionary in out.get("new_cities",[]):
  if c.get("host_interchange",false):out.transport_overrides[str(c.host)]={"routes":["LAND","SEA"],"interchange":true}
  for field:String in ["host","route_type","partner","route","extra_connections","host_interchange"]:c.erase(field)
  c.origin="USER"
 out.generated={"topology_key":"","decks":[]}
 return out
static func specs(base:Dictionary,doc:Dictionary)->Dictionary:
 var out:=CustomMapFreeRoutes.specs(base,base_doc(doc))
 for rid:String in doc.free_routes.routes:
  var p:Dictionary=doc.free_routes.routes[rid]
  if p.get("deleted",false):out.erase(rid);continue
  var r:Dictionary=out.get(rid,{}).duplicate(true);r.merge(p,true);r.id=rid
  var ts:Array=r.get("stop_t",[])
  var count:int=ts.size() if r.has("stop_t") else r.get("stop_ids",[]).size()
  var old:Array=r.get("stop_ids",[]);r.stop_ids=[]
  for i:int in count:r.stop_ids.append(old[i] if i<old.size() else "%s_%02d"%[rid,i+1])
  out[rid]=r
 return out
static func format_error(doc:Dictionary,base:Dictionary)->String:
 if not CustomMapLocalAssets._finite(doc):return "数据必须有限且深度不超过64层"
 if CustomMapSchema.canonical_text(doc).to_utf8_buffer().size()>CustomMapSchema.MAX_FILE_BYTES:return "地图文件超过安全上限"
 if not CustomMapStore.valid_map_id(str(doc.get("map_id",""))):return "地图编号无效"
 if doc.get("schema")!=CustomMapFreeRoutes.SCHEMA or doc.get("tradegen")!=GENERATOR:return "自由作品需要第六版外壳与独立交易规则"
 var f:Variant=doc.get("free_routes")
 if not f is Dictionary or f.size()!=2 or f.get("version")!=2 or not f.get("routes") is Dictionary:return "自由作品路线层格式不合法"
 if not doc.get("new_cities") is Array or doc.new_cities.size()>MAX_CITIES:return "自由作品最多4座新城"
 if f.routes.size()>CustomMapFreeRoutes.MAX_ROUTES:return "路线数量超过上限"
 var ids:Dictionary=base.cities.duplicate(false);var slots:Dictionary={}
 for c in doc.new_cities:
  if not c is Dictionary:return "城市资料不是对象"
  var slot:Variant=c.get("slot")
  if not slot is String or slot not in CustomMapSchema.SLOTS or slots.has(slot):return "城市编号无效或重复"
  slots[slot]=true;ids[CustomMapSchema.city_id(slot)]=true
  if c.get("origin")!="USER":return "自由城市来源无效"
  for field:String in ["host","route_type","partner","route","extra_connections","host_interchange"]:
   if c.has(field):return "自由城市不能保留旧宿主或配对字段"
  for field:String in ["name","archetype","specialty"]:
   if not c.get(field) is String or c[field].length()>200:return "城市文字字段无效或过长"
  for field:String in ["x","z","rotation","size"]:
   if not CustomBoardLayout._is_num(c.get(field)):return "城市坐标和尺寸必须有限"
  if float(c.x)<0 or float(c.x)>BOARD_MAX.x or float(c.z)<0 or float(c.z)>BOARD_MAX.y:return "城市在棋盘范围之外"
  if float(c.size)<=0 or float(c.size)>5:return "城市尺寸超过安全范围"
  if not c.get("text",{}) is Dictionary or CustomMapSchema.canonical_text(c.get("text",{})).length()>2000:return "城市介绍格式或长度无效"
 var originals:=CustomMapFreeRoutes.specs(base,base_doc(doc))
 for rid in f.routes:
  if not rid is String or rid.length()>100 or not rid.is_valid_identifier():return "路线编号无效"
  var p:Variant=f.routes[rid]
  if not p is Dictionary:return "路线资料不是对象"
  for k in p:
   if k not in ["deleted","a","b","type","handles","stop_t"]:return "未知路线字段"
  if p.has("deleted") and not p.deleted is bool:return "路线删除标记无效"
  if p.get("deleted",false):
   if not originals.has(rid):return "已删除的自建路线应移除记录"
   continue
  var r:Dictionary=originals.get(rid,{}).duplicate(true);r.merge(p,true)
  if not r.get("a") is String or not r.get("b") is String or not ids.has(r.a) or not ids.has(r.b) or r.a==r.b:return "路线需连接两座存在且不同的城市"
  if r.get("type") not in ["LAND","SEA"]:return "路线交通无效"
  var hs:Variant=r.get("handles",[])
  if not hs is Array or hs.size()>12:return "路线控制点超过上限"
  for h in hs:
   if not h is Array or h.size()!=2 or not CustomBoardLayout._is_num(h[0]) or not CustomBoardLayout._is_num(h[1]):return "控制点必须有限"
   if float(h[0])<0 or float(h[0])>BOARD_MAX.x or float(h[1])<0 or float(h[1])>BOARD_MAX.y:return "控制点在棋盘之外"
  var ts:Variant=r.get("stop_t",[])
  if not ts is Array or ts.size()>CustomMapFreeRoutes.MAX_STOPS:return "停靠点超过上限"
  var previous:=0.0
  for t in ts:
   if not CustomBoardLayout._is_num(t) or float(t)<0.01 or float(t)>0.99 or float(t)-previous<0.00999:return "停靠点顺序或间距无效"
   previous=float(t)
 var overrides:Variant=doc.get("transport_overrides",{})
 if not overrides is Dictionary or overrides.size()>base.cities.size():return "原城交通声明无效"
 for cid in overrides:
  var o:Variant=overrides[cid]
  if not base.cities.has(cid) or not o is Dictionary or o.size()!=2 or not o.get("routes") is Array or not o.get("interchange") is bool:return "原城交通声明无效"
  if o.routes.size()!=2 or not o.interchange:return "自由作品仅支持明确增开海陆交通并换乘"
  var seen:Array=[]
  for rt in o.routes:
   if rt not in ["LAND","SEA"] or rt in seen:return "原城交通声明重复或未知"
   seen.append(rt)
  for rt in base.cities[cid].allowed_routes:
   if rt not in seen:return "自由作品交通声明不能移除原城已有交通"
 var moved_error:=CustomBoardLayout.overlay_error(base_doc(doc),CustomMapLoader.base_layout())
 if moved_error!="":return moved_error
 for move:Dictionary in doc.get("moves",{}).get("cities",{}).values():
  if move.has("x") and (float(move.x)<0 or float(move.x)>BOARD_MAX.x):return "原城位置在棋盘范围之外"
  if move.has("z") and (float(move.z)<0 or float(move.z)>BOARD_MAX.y):return "原城位置在棋盘范围之外"
 for route:Dictionary in doc.get("moves",{}).get("routes",{}).values():
  for handle:Array in route.get("handles",[]):
   if float(handle[0])<0 or float(handle[0])>BOARD_MAX.x or float(handle[1])<0 or float(handle[1])>BOARD_MAX.y:return "原路线控制点在棋盘范围之外"
 return ""
static func routes_for(base:Dictionary,doc:Dictionary,cid:String)->Array:
 if base.cities.has(cid):return doc.get("transport_overrides",{}).get(cid,{}).get("routes",base.cities[cid].allowed_routes).duplicate()
 var types:Array=[]
 for r:Dictionary in specs(base,doc).values():
  if cid in [str(r.a),str(r.b)] and not r.type in types:types.append(r.type)
 types.sort();return types
static func graph(base:Dictionary,doc:Dictionary)->Dictionary:
 var legacy:=CustomMapRules.build_graph(base,base_doc(doc));var nodes:Dictionary={};var city_node:Dictionary={}
 for id:String in legacy.nodes:
  var n:Dictionary=legacy.nodes[id]
  if n.kind!="CITY":continue
  nodes[id]=n.duplicate(true);city_node[str(n.city_id)]=id
  nodes[id].routes=routes_for(base,doc,str(n.city_id))
  nodes[id].interchange=doc.get("transport_overrides",{}).get(str(n.city_id),{}).get("interchange",n.interchange)
 for c:Dictionary in doc.new_cities:
  var cid:=CustomMapSchema.city_id(str(c.slot));var types:=routes_for(base,doc,cid)
  nodes[cid]={"kind":"CITY","city_id":cid,"routes":types,"interchange":types.size()>1};city_node[cid]=cid
 var edges:Array=[]
 for rid:String in specs(base,doc):
  var r:Dictionary=specs(base,doc)[rid]
  var chain:Array=[str(city_node[r.a])];chain.append_array(r.stop_ids);chain.append(str(city_node[r.b]))
  for sid:String in r.stop_ids:nodes[sid]={"kind":"ROAD","city_id":"","routes":[r.type],"interchange":false}
  for i:int in range(chain.size()-1):edges.append({"id":CustomMapSchema.edge_id(chain[i],chain[i+1],str(r.type)),"a":chain[i],"b":chain[i+1],"route_type":r.type,"corridor_id":rid,"corridor_step_index":i+1})
 return {"nodes":nodes,"edges":edges,"free_routes":true}
static func key(doc:Dictionary)->String:
 return "topo_free_author_v1|"+CustomMapSchema.canonical_text({"cities":doc.new_cities.map(func(c):return {"slot":c.slot}),"routes":CustomMapFreeRoutes._topology_patches(doc.free_routes.routes),"transport":doc.get("transport_overrides",{})}).sha256_text()
static func derive(layout:Dictionary,doc:Dictionary,geo:CustomMapGeo,cat:Dictionary,sha:String="")->Dictionary:
 var bad:=format_error(doc,CustomMapLoader.base_content())
 if bad!="":return {"error":bad}
 var out:=CustomBoardLayout.derive(layout,base_doc(doc),geo,cat,sha).duplicate(true)
 if out.has("error"):return out
 for c:Dictionary in doc.new_cities:
  var arch:=CustomMapCatalogue.archetype(cat,str(c.archetype));var foot:=float(arch.get("foot",CustomBoardLayout.DEFAULT_FOOT))*float(c.size)
  var cid:=CustomMapSchema.city_id(str(c.slot));var slot:=str(c.slot)
  var y:=maxf(geo.city_y(float(c.x),float(c.z),foot),0.15)
  var model:=str(arch.get("model",CustomBoardLayout.FALLBACK_TOWN));var local:=CustomMapLocalAssets.bound_id(doc,slot,"city_model")
  if local!="":model=CustomMapLocalAssets.path(local)
  out.cities.append({"id":cid,"board_id":cid,"name":c.name,"x":float(c.x),"y":y,"z":float(c.z),"foot":foot,"rotation":float(c.rotation),"size":float(c.size),"model":model,"bounds":arch.get("bounds",{}) if local=="" else {},"city_badge":CustomMapCityBadges.config(doc,cid).duplicate(true),"badge_asset":CustomMapLocalAssets.bound_id(doc,slot,"badge_icon")})
 out=CustomMapFreeRoutes.derive(out,doc,geo,CustomMapLoader.base_content())
 if sha!="":out.custom_map_sha=sha
 return out
static func validate(base:Dictionary,layout:Dictionary,doc:Dictionary,cat:Dictionary)->Dictionary:
 var errors:Array[Dictionary]=[];var warnings:Array[Dictionary]=[]
 var out:Dictionary={"ok":false,"errors":errors,"warnings":warnings,"sha256":"","topology_key":"","generated":{},"counts_win":false}
 CustomMapValidator._check_file(doc,base,errors,warnings)
 if not errors.is_empty():return out
 out.sha256=CustomMapSchema.sha256(doc);out.topology_key=key(doc)
 errors.append_array(CustomMapFreeRoutes.check(base,doc))
 CustomMapValidator._check_names(base,doc,errors);CustomMapValidator._check_catalogue(doc,cat,errors)
 CustomMapValidator._check_texts(base,doc,cat,errors);CustomMapValidator._check_assets(doc,cat,errors)
 var geo:=CustomMapGeo.for_overlay(doc);var derived:=derive(layout,doc,geo,cat)
 for issue:Dictionary in CustomMapGeoRules.check(derived,layout,doc,geo):
  if issue.get("level","")=="warning":warnings.append(issue)
  else:errors.append(issue)
 if doc.has("plants") and not derived.has("error"):errors.append_array(CustomMapPlants.check(derived,doc,geo))
 var gen:=CustomMapValidator.generate(base,doc,cat)
 if gen.get("ok",false):
  out.generated=gen.generated
  if CustomMapSchema.canonical_text(doc.get("generated",{}))!=CustomMapSchema.canonical_text(gen.generated):errors.append(CustomMapFreeRoutes.issue("E_CARDS_MISMATCH","generated","交易卡尚未重新生成"))
 else:errors.append(CustomMapFreeRoutes.issue("E_CARDS_INVARIANT","generated",str(gen.get("tech","交易卡未就绪"))))
 out.ok=errors.is_empty();return out
static func finish(doc:Dictionary,base:Dictionary,layout:Dictionary,cat:Dictionary)->Dictionary:
 var errors:Array[Dictionary]=[];var warnings:Array[Dictionary]=[]
 CustomMapValidator._check_file(doc,base,errors,warnings,true)
 if not errors.is_empty():return {"ok":false,"reason":str(errors[0].kid),"errors":errors}
 var out:=CustomMapSchema.round_coords(doc)
 CustomMapValidator._check_file(out,base,errors,warnings,true)
 if not errors.is_empty():return {"ok":false,"reason":str(errors[0].kid),"errors":errors}
 var gen:=CustomMapValidator.generate(base,out,cat)
 out.generated=gen.generated if gen.get("ok",false) else {"topology_key":key(out),"decks":[]}
 var result:=validate(base,layout,out,cat)
 return {"ok":true,"doc":out,"validation":result,"draft":not result.ok,"cards_ready":gen.get("ok",false),"errors":[],"reason":""}
static func place(doc:Dictionary,pos:Vector2,base:Dictionary,layout:Dictionary,cat:Dictionary)->Dictionary:
 var out:=doc.duplicate(true);var used:Array=out.new_cities.map(func(c):return str(c.slot));var slot:=""
 for candidate:String in CustomMapSchema.SLOTS:
  if candidate not in used:slot=candidate;break
 if slot=="":return {"ok":false,"reason":"新城已满4座","errors":[]}
 var arch:Dictionary={}
 for a:Dictionary in cat.get("archetypes",[]):
  if CustomMapCatalogue.is_offered(a):arch=a;break
 out.new_cities.append({"slot":slot,"origin":"USER","name":"新城"+str(used.size()+1),"archetype":str(arch.get("id","")),"specialty":"","x":pos.x,"z":pos.y,"rotation":0.0,"size":1.0,"text":{"mode":"AUTO"}})
 var result:=finish(out,base,layout,cat);result.city_id=CustomMapSchema.city_id(slot);return result
static func connect_cities(doc:Dictionary,a:String,b:String,rt:String,route:Dictionary,base:Dictionary,layout:Dictionary,cat:Dictionary)->Dictionary:
 var out:=doc.duplicate(true);var rid:="free_"+(str(Time.get_ticks_usec())+a+b+str(out.free_routes.routes.size())).sha256_text().left(12)
 var p:=route.duplicate(true);p.a=a;p.b=b;p.type=rt;out.free_routes.routes[rid]=p
 var result:=finish(out,base,layout,cat);result.route_id=rid;return result
static func remove_city(doc:Dictionary,cid:String,base:Dictionary,layout:Dictionary,cat:Dictionary)->Dictionary:
 var out:=doc.duplicate(true);out.new_cities=out.new_cities.filter(func(c):return CustomMapSchema.city_id(str(c.slot))!=cid)
 var slots:Dictionary={}
 for c:Dictionary in out.new_cities:slots[str(c.slot)]=str(c.slot)
 CustomMapSchema._remap_city_layers(out,slots,base)
 return finish(out,base,layout,cat)
static func transport(doc:Dictionary,cid:String,base:Dictionary,layout:Dictionary,cat:Dictionary)->Dictionary:
 var out:=doc.duplicate(true);out.transport_overrides[cid]={"routes":["LAND","SEA"],"interchange":true}
 return finish(out,base,layout,cat)
static func texts_for(city:Dictionary,cat:Dictionary)->Dictionary:
 var copy:=city.duplicate(true);copy.route_type="LAND"
 var texts:=CustomMapCardText.texts_for(copy,"远方城市","W" if float(city.x)<64 else "E",cat)
 texts.lore.position="自由作品中的城市，交通由你连接的路线决定。"
 return texts
static func node_distances(content:Dictionary,source:String)->Dictionary:
 var nodes:Dictionary=content.board_nodes;var dist:Dictionary={};var queue:Array=[];var out:Dictionary={}
 for medium:String in nodes.get(source,{}).get("allowed_routes",[]):dist[source+"|"+medium]=0;queue.append([source,medium])
 while not queue.is_empty():
  var state:Array=queue.pop_front();var id:=str(state[0]);var medium:=str(state[1]);var steps:=int(dist[id+"|"+medium])
  if not out.has(id) or steps<int(out[id]):out[id]=steps
  if nodes[id].get("is_transport_interchange",false):
   for other:String in nodes[id].allowed_routes:
    var k:=id+"|"+other
    if not dist.has(k) or steps<int(dist[k]):dist[k]=steps;queue.push_front([id,other])
  for edge:Dictionary in content.edges_from.get(id,[]):
   if str(edge.route_type)!=medium:continue
   var other:=str(edge.b) if str(edge.a)==id else str(edge.a);var k:=other+"|"+medium
   if not dist.has(k) or steps+1<int(dist[k]):dist[k]=steps+1;queue.append([other,medium])
 return out
