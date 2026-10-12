class_name CustomMapFreeRoutes
extends RefCounted
## v6 changes the logical route graph. Legacy graph and prices remain frozen.
const SCHEMA := "lshu.custom_map.v6"
const GENERATOR := "tradegen_v2_free_routes_1"
const MAX_STOPS := 32
const MAX_ROUTES := 64
static func enabled(doc:Dictionary)->bool:return doc.has("free_routes")
static func clean(doc:Dictionary)->Dictionary:
 var out:=doc.duplicate(true);out.erase("free_routes");out.schema="lshu.custom_map.v5";out.tradegen=CustomMapTradegenRegistry.ORIGINAL;return out
static func enter(doc:Dictionary)->Dictionary:
 var out:=doc.duplicate(true)
 if not enabled(out):
  out.schema=SCHEMA;out.tradegen=GENERATOR
  out.map_id=preload("res://scripts/map_workshop/workshop_backend.gd").new_map_id()
  out.name=CustomMapStore._suffixed_name(str(out.get("name","地图")),"自由")
  out.free_routes={"version":1,"routes":{}}
 return out
static func specs(base:Dictionary,doc:Dictionary)->Dictionary:
 if CustomMapFreeAuthor.enabled(doc):return CustomMapFreeAuthor.specs(base,doc)
 var graph:=CustomMapRules.build_graph(base,clean(doc))
 var groups:Dictionary={}
 for e:Dictionary in graph.edges:
  if not groups.has(str(e.corridor_id)):groups[str(e.corridor_id)]=[]
  groups[str(e.corridor_id)].append(e)
 var out:Dictionary={}
 for rid:String in groups:
  var edges:Array=groups[rid];edges.sort_custom(func(a,b):return int(a.corridor_step_index)<int(b.corridor_step_index))
  var ids:Array=[]
  for i:int in range(edges.size()-1):ids.append(str(edges[i].b))
  out[rid]={"id":rid,"a":str(graph.nodes[str(edges[0].a)].city_id),"b":str(graph.nodes[str(edges[-1].b)].city_id),"type":str(edges[0].route_type),"stop_ids":ids}
 if not enabled(doc):return out
 for rid:String in doc.free_routes.routes:
  var patch:Dictionary=doc.free_routes.routes[rid]
  if patch.get("deleted",false):out.erase(rid);continue
  var r:Dictionary=out.get(rid,{}).duplicate(true)
  for k:String in ["a","b","type","handles","stop_t"]:
   if patch.has(k):r[k]=patch[k].duplicate(true) if patch[k] is Array else patch[k]
  r.id=rid
  var count:int=patch.get("stop_t",r.get("stop_ids",["a","b"])).size()
  var old:Array=r.get("stop_ids",[]);var ids:Array=[]
  for i:int in count:ids.append(old[i] if i<old.size() else "%s_%02d"%[rid,i+1])
  r.stop_ids=ids;out[rid]=r
 return out
static func format_error(doc:Dictionary,base:Dictionary)->String:
 if CustomMapFreeAuthor.enabled(doc):return CustomMapFreeAuthor.format_error(doc,base)
 if not enabled(doc):return ""
 if doc.get("schema")!=SCHEMA or doc.get("tradegen")!=GENERATOR:return "自由路线需要第六版地图与对应交易规则"
 var f:Variant=doc.free_routes
 if not f is Dictionary or f.size()!=2 or f.get("version")!=1 or not f.get("routes") is Dictionary:return "自由路线层格式不合法"
 if f.routes.size()>MAX_ROUTES:return "路线修改超过上限"
 if not doc.get("new_cities",[]) is Array:return "新增城市层格式不合法"
 for c in doc.get("new_cities",[]):
  if not c is Dictionary or str(c.get("slot","")) not in CustomMapSchema.SLOTS or not base.cities.has(str(c.get("host",""))) or c.get("route_type") not in ["LAND","SEA"] or not c.get("route",{}) is Dictionary:return "新增城市的路线资料不合法"
  if not c.get("extra_connections",[]) is Array:return "新增城市的额外连接资料不合法"
  for link in c.get("extra_connections",[]):
   if not link is Dictionary or not base.cities.has(str(link.get("host",""))) or link.get("route_type") not in ["LAND","SEA"] or not link.get("route",{}) is Dictionary:return "新增城市的额外连接资料不合法"
 var original:=specs(base,clean(doc));var city_ids:Dictionary=base.cities.duplicate(false)
 for c:Dictionary in doc.get("new_cities",[]):city_ids[CustomMapSchema.city_id(str(c.slot))]=true
 for key in f.routes:
  if typeof(key) not in [TYPE_STRING,TYPE_STRING_NAME] or str(key).length()>100 or not str(key).is_valid_identifier():return "路线标识不合法"
  var p:Variant=f.routes[key]
  if not p is Dictionary:return "路线修改不是对象"
  for k in p:
   if k not in ["deleted","a","b","type","handles","stop_t"]:return "未知路线字段："+str(k)
  if p.has("deleted") and not p.deleted is bool:return "删除标记不合法"
  if p.get("deleted",false):
   if not original.has(key):return "找不到要删除的路线"
  var r:Dictionary=original.get(key,{}).duplicate(true);r.merge(p,true)
  if not city_ids.has(str(r.get("a",""))) or not city_ids.has(str(r.get("b",""))) or r.a==r.b:return "路线需连接两座不同的城市"
  if r.get("type") not in ["LAND","SEA"]:return "路线交通类型不合法"
  var handles:Variant=r.get("handles",[])
  if not handles is Array or handles.size()>12:return "路线控制点数量不合法"
  for h in handles:
   if not h is Array or h.size()!=2 or not CustomBoardLayout._is_num(h[0]) or not CustomBoardLayout._is_num(h[1]):return "控制点需为有限坐标"
  var ts:Variant=r.get("stop_t",[0.333,0.667])
  if not ts is Array or ts.size()>MAX_STOPS:return "停靠点数量不合法"
  var prev:=0.0
  for t in ts:
   if not CustomBoardLayout._is_num(t) or float(t)<0.01 or float(t)>0.99 or float(t)-prev<0.01-0.00001:return "停靠点需按路线顺序排列并保持间隔"
   prev=float(t)
 return ""
static func graph(base:Dictionary,doc:Dictionary)->Dictionary:
 if CustomMapFreeAuthor.enabled(doc):return CustomMapFreeAuthor.graph(base,doc)
 var legacy:=CustomMapRules.build_graph(base,clean(doc));var nodes:Dictionary={};var city_node:Dictionary={}
 for id:String in legacy.nodes:
  var n:Dictionary=legacy.nodes[id]
  if n.kind=="CITY":nodes[id]=n.duplicate(true);city_node[str(n.city_id)]=id
 var edges:Array=[]
 var definitions:=specs(base,doc)
 for rid:String in definitions:
  var r:Dictionary=definitions[rid]
  var chain:Array=[str(city_node.get(r.a,r.a))];chain.append_array(r.stop_ids);chain.append(str(city_node.get(r.b,r.b)))
  for sid:String in r.stop_ids:nodes[sid]={"kind":"ROAD","city_id":"","routes":[r.type],"interchange":false}
  for i:int in range(chain.size()-1):edges.append({"id":CustomMapSchema.edge_id(chain[i],chain[i+1],str(r.type)),"a":chain[i],"b":chain[i+1],"route_type":r.type,"corridor_id":rid,"corridor_step_index":i+1})
 return {"nodes":nodes,"edges":edges,"free_routes":true}
static func issue(code:String,target:String,kid:String)->Dictionary:return {"code":code,"target":target,"kid":kid,"tech":kid}
static func check(base:Dictionary,doc:Dictionary)->Array[Dictionary]:
 var errors:Array[Dictionary]=[];var bad:=format_error(doc,base)
 if bad!="":errors.append(issue("E_FREE_FORMAT","free_routes",bad));return errors
 var g:=graph(base,doc)
 var seen:Dictionary={}
 for e:Dictionary in g.edges:
  var key:=str(e.id)
  if seen.has(key):errors.append(issue("E_FREE_DUPLICATE",str(e.corridor_id),"有重复的路线连接"))
  seen[key]=true
  for id:String in [str(e.a),str(e.b)]:
   var n:Dictionary=g.nodes[id]
   if str(e.route_type) not in n.routes:
    var problem:=issue("E_FREE_TRANSPORT",str(e.corridor_id),"端点城市不支持这条路的交通方式")
    problem.endpoint_city=str(n.get("city_id",id));problem.medium=str(e.route_type);errors.append(problem)
 var distances:=CustomMapRules.city_distances(g)
 var cities:Array=[]
 for n:Dictionary in g.nodes.values():
  if n.kind=="CITY":cities.append(str(n.city_id))
 cities.sort()
 # Retain the complete ordered-pair reachability gate. City reachability
 # need not be transitive when a city supports both media without interchange.
 # Report one useful location rather than repeating the same missing corridor.
 var missing_total:=0;var focus:="";var other:="";var focus_count:=0
 for a:String in cities:
  var missing:Array=[]
  for b:String in cities:
   if not (distances.get(a,{}) as Dictionary).has(b):missing.append(b)
  missing_total+=missing.size()
  if missing.size()>focus_count:focus=a;other=str(missing[0]);focus_count=missing.size()
 if missing_total>0:
  var problem:=issue("E_FREE_DISCONNECTED",focus,"%s与%s还不通；草稿可保存，接通后才能试玩。"%[_city_label(base,doc,focus),_city_label(base,doc,other)])
  problem.tech="%d 个有向城市对无法按交通规则到达"%missing_total
  errors.append(problem)
 return errors
static func _city_label(base:Dictionary,doc:Dictionary,cid:String)->String:
 if base.cities.has(cid):return str(base.cities[cid].get("display_name",cid))
 for city:Dictionary in doc.get("new_cities",[]):
  if "x_"+str(city.slot)==cid:return str(city.name)
 return cid
static func key(doc:Dictionary)->String:
 if CustomMapFreeAuthor.enabled(doc):return CustomMapFreeAuthor.key(doc)
 return "topo_free_v1|"+CustomMapSchema.canonical_text({"cities":doc.get("new_cities",[]).map(func(c):return {"slot":c.slot,"host":c.host,"route_type":c.route_type,"partner":c.partner,"extra_connections":c.get("extra_connections",[]).map(func(e):return {"host":e.host,"route_type":e.route_type}),"host_interchange":c.get("host_interchange",false)}),"routes":_topology_patches(doc.free_routes.routes)}).sha256_text()
static func _topology_patches(patches:Dictionary)->Dictionary:
 var out:Dictionary={}
 for id:String in patches:
  var p:Dictionary={}
  for k:String in ["deleted","a","b","type"]:
   if patches[id].has(k):p[k]=patches[id][k]
  if patches[id].has("stop_t"):p.stops=patches[id].stop_t.size()
  if not p.is_empty():out[id]=p
 return out
static func derive(layout:Dictionary,doc:Dictionary,geo:CustomMapGeo,base:Dictionary)->Dictionary:
 var bad:=format_error(doc,base)
 if bad!="":return {"error":bad}
 var out:=layout.duplicate(true);var cities:Dictionary={};var old:Dictionary={};var old_stops:Dictionary={}
 for c:Dictionary in out.cities:cities[str(c.id)]=c
 for r:Dictionary in out.routes:old[str(r.id)]=r
 for s:Dictionary in out.stops:old_stops[str(s.id)]=s
 out.routes=[];out.stops=[]
 var definitions:=specs(base,doc)
 for rid:String in definitions:
  var spec:Dictionary=definitions[rid];var r:Dictionary=old.get(rid,{}).duplicate(true)
  var patch:Dictionary=doc.free_routes.routes.get(rid,{})
  var change_shape:=r.is_empty() or patch.has("a") or patch.has("b") or patch.has("handles") or patch.has("type")
  r.id=rid;r.a=spec.a;r.b=spec.b;r.type=spec.type
  if change_shape:
   r.points=CustomBoardLayout.with_heights(CustomBoardLayout.spline_points(cities[r.a],cities[r.b],spec.get("handles",[])),str(r.type),geo);r.erase("lane")
  var ts:Array=patch.get("stop_t",[])
  if ts.is_empty() and spec.stop_ids.size()>0:
   for i:int in spec.stop_ids.size():ts.append(float(i+1)/float(spec.stop_ids.size()+1))
  var stops:Array=[]
  for sid:String in spec.stop_ids:
   var st:Dictionary=old_stops.get(sid,{"id":sid,"type":r.type,"x":0.0,"y":0.0,"z":0.0,"coin_matched":false}).duplicate(true)
   st.type=r.type;stops.append(st)
  if change_shape or patch.has("stop_t") or old.get(rid,{}).is_empty():CustomBoardLayout._place_stops(stops,r,ts,geo)
  out.routes.append(r);out.stops.append_array(stops)
 out.effective_edges=graph(base,doc).edges;out.edges_extra=[];out.free_routes=true
 return out
static func generate(base:Dictionary,doc:Dictionary,goods_map:Dictionary,topology:Array)->Dictionary:
 var errors:=check(base,doc)
 if not errors.is_empty():return {"ok":false,"errors":errors,"failure_code":"FREE_GRAPH_INVALID"}
 var goods:Dictionary={};var producer:Dictionary={}
 for g:Dictionary in base.goods.values():goods[str(g.id)]=int(g.get("supply_total",0))
 for card:Dictionary in base.city_cards.values():
  var entries:Array=card.get("starting_grant",{}).get("entries",[])
  if not entries.is_empty() and str(entries[0].get("resource_kind",""))=="GOOD":producer[str(entries[0].resource_id)]=str(card.city_id)
 var result:=TradeGenV2Original.generate_context(goods,producer,CustomMapRules.city_distances(graph(base,doc)),topology,goods_map,TradeGenV2Original.params())
 result.version=GENERATOR;return result
static func finish(doc:Dictionary,base:Dictionary,layout:Dictionary,catalogue:Dictionary)->Dictionary:
 if CustomMapFreeAuthor.enabled(doc):return CustomMapFreeAuthor.finish(doc,base,layout,catalogue)
 var out:=CustomMapSchema.round_coords(doc)
 var bad:=format_error(out,base)
 if bad!="":return {"ok":false,"reason":bad}
 # Only physical/topological editing problems may be kept as drafts. File,
 # naming, asset and original expansion contracts retain their existing gates.
 var unsafe:Array[Dictionary]=[];var warnings:Array[Dictionary]=[]
 CustomMapValidator._check_file(out,base,unsafe,warnings,true)
 if unsafe.is_empty():unsafe.append_array(CustomMapRules.check_topology(base,clean(out),{}))
 if unsafe.is_empty():
  CustomMapValidator._check_names(base,out,unsafe);CustomMapValidator._check_catalogue(out,catalogue,unsafe)
 if unsafe.is_empty():CustomMapValidator._check_texts(base,out,catalogue,unsafe);CustomMapValidator._check_assets(out,catalogue,unsafe)
 if not unsafe.is_empty():return {"ok":false,"reason":str(unsafe[0].get("kid","地图文件不合法")),"errors":unsafe}
 var generated:=CustomMapValidator.generate(base,out,catalogue)
 if generated.get("ok",false):out.generated=generated.generated
 var check_result:=CustomMapValidator.validate(base,layout,out,catalogue)
 for error:Dictionary in check_result.errors:
  if str(error.code)=="E_GENERATOR_PARAMS" and not PublicRules.ready():continue
  if not str(error.code).begins_with("E_FREE_") and (not str(error.code).begins_with("G_") or str(error.code)=="G_DATA"):
   return {"ok":false,"reason":str(error.get("kid","地图文件不合法")),"errors":check_result.errors}
 return {"ok":true,"doc":out,"validation":check_result,"draft":not check_result.ok,"cards_ready":generated.get("ok",false),"errors":[],"reason":""}
static func card_diff(before:Dictionary,after:Dictionary,base:Dictionary)->Dictionary:
 var old:Dictionary={};var changes:Array=[]
 for d:Dictionary in before.get("generated",{}).get("decks",[]):
  for c:Dictionary in d.cards:old[str(c.id)]=c
 for d:Dictionary in after.get("generated",{}).get("decks",[]):
  var changed:=0;var examples:Array=[]
  for c:Dictionary in d.cards:
   if CustomMapSchema.canonical_text(old.get(str(c.id),{}))!=CustomMapSchema.canonical_text(c):
    changed+=1
    if examples.size()<2:examples.append({"card_id":str(c.id),"number":int(c.card_number),"before":old.get(str(c.id),{}).get("entries",[]),"after":c.entries.duplicate(true)})
  changes.append({"city_id":str(d.city_id),"changed":changed,"total":d.cards.size(),"examples":examples})
 var g0:=CustomMapRules.build_graph(base,before);var g1:=CustomMapRules.build_graph(base,after)
 var d0:=CustomMapRules.city_distances(g0);var d1:=CustomMapRules.city_distances(g1);var distance_changes:=0
 for a in base.cities:
  for b in base.cities:
   if (d0.get(a,{}) as Dictionary).get(b,-1)!=(d1.get(a,{}) as Dictionary).get(b,-1):distance_changes+=1
 return {"original_cards_changed":0,"new_cards":changes,"original_distance_pairs_changed":distance_changes,"graph_before":CustomMapSchema.canonical_text(g0).sha256_text(),"graph_after":CustomMapSchema.canonical_text(g1).sha256_text()}
static func apply_content(merged:Dictionary,base:Dictionary,doc:Dictionary,catalogue:Dictionary)->void:
 var g:=graph(base,doc)
 var layout:=CustomBoardLayout.derive(CustomMapLoader.base_layout(),doc,CustomMapGeo.for_overlay(doc),catalogue)
 var stop_map:Dictionary={};var route_map:Dictionary={}
 for st:Dictionary in layout.stops:stop_map[str(st.id)]=st
 for r:Dictionary in layout.routes:route_map[str(r.id)]=r
 var previous:Dictionary=merged.get("board_nodes",{});var nodes:Dictionary={};var from:Dictionary={};var edges:Array=[]
 var definitions:=specs(base,doc);var pieces_by_route:Dictionary={}
 for id:String in g.nodes:
  var n:Dictionary=g.nodes[id];var row:Dictionary=previous.get(id,{}).duplicate(true)
  if n.kind=="ROAD":
   var st:Dictionary=stop_map[id];var pos:=Vector2(float(st.x)*32.0,float(st.z)*32.0/1.4)
   row={"id":id,"node_type":"ROAD","city_id":null,"map_position":pos,"position_px":[pos.x,pos.y],"route_anchors":{str(st.type):pos},"allowed_routes":n.routes.duplicate(),"is_transport_interchange":false,"presentation_stop_id":id}
  row.allowed_routes=n.routes.duplicate();row.is_transport_interchange=n.interchange
  if CustomMapFreeAuthor.enabled(doc) and n.kind=="CITY":
   var pos:Vector2=row.get("map_position",Vector2.ZERO)
   row.route_anchors=row.get("route_anchors",{}).duplicate(true)
   for medium:String in n.routes:
    if not row.route_anchors.has(medium):row.route_anchors[medium]=pos
  nodes[id]=row;from[id]=[]
 for raw:Dictionary in g.edges:
  var e:=raw.duplicate(true);var r:Dictionary=route_map[str(e.corridor_id)];var points:Array[Vector2]=[]
  for q:Array in r.points:points.append(Vector2(float(q[0])*32.0,float(q[2])*32.0/1.4))
  var route_id:=str(e.corridor_id)
  if not pieces_by_route.has(route_id):
   var cuts:Array=[];var patch:Dictionary=doc.free_routes.routes.get(route_id,{})
   if patch.has("stop_t"):cuts=patch.stop_t
   else:
    var definition:Dictionary=definitions[route_id]
    for sid:String in definition.stop_ids:
     var st:Dictionary=stop_map[sid];cuts.append(project_t(r.points,Vector2(st.x,st.z)))
   pieces_by_route[route_id]=CustomMapLoader._split_polyline(points,cuts)
  var pieces:Array=pieces_by_route[route_id];var index:=int(e.corridor_step_index)-1
  var poly:Array=[]
  for p:Vector2 in CustomMapLoader._resample(pieces[index],16):poly.append([p.x,p.y])
  var a:Vector2=nodes[str(e.a)].map_position;var b:Vector2=nodes[str(e.b)].map_position
  poly[0]=[a.x,a.y];poly[-1]=[b.x,b.y];e.movement_polyline=poly;e.movement_polyline_px=poly.duplicate(true)
  edges.append(e);from[str(e.a)].append(e);from[str(e.b)].append(e)
 merged.board_nodes=nodes;merged.board_edges=edges;merged.edges_from=from

static func project_t(pts:Array,p:Vector2)->float:
 var total:=0.0;var best:=INF;var found:=0.0
 for i:int in range(1,pts.size()):
  var a:=Vector2(float(pts[i-1][0]),float(pts[i-1][2]));var b:=Vector2(float(pts[i][0]),float(pts[i][2]));var length:=a.distance_to(b)
  var q:=Geometry2D.get_closest_point_to_segment(p,a,b);var distance:=q.distance_squared_to(p)
  if distance<best:best=distance;found=total+a.distance_to(q)
  total+=length
 return found/maxf(total,0.0001)
