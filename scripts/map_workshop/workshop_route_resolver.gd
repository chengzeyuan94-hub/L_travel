extends RefCounted
## One address for BASE, PRIMARY and SECONDARY routes.
static func resolve(doc:Dictionary,rid:String)->Dictionary:
 if CustomMapFreeAuthor.enabled(doc):return {"kind":"BASE","id":rid}
 for i:int in doc.get("new_cities",[]).size():
  var c:Dictionary=doc.new_cities[i]
  if CustomMapSchema.corridor_id(str(c.slot),str(c.host),str(c.route_type))==rid:return {"kind":"PRIMARY","city":i,"id":rid,"host":str(c.host),"slot":str(c.slot)}
  for j:int in c.get("extra_connections",[]).size():
   var link:Dictionary=c.extra_connections[j]
   if CustomMapSchema.corridor_id(str(c.slot),str(link.host),str(link.route_type))==rid:return {"kind":"SECONDARY","city":i,"link":j,"id":rid,"host":str(link.host),"slot":str(c.slot)}
 return {"kind":"BASE","id":rid}
static func read(doc:Dictionary,rid:String)->Dictionary:
 if CustomMapFreeRoutes.enabled(doc) and doc.free_routes.routes.has(rid):
  var p:Dictionary=doc.free_routes.routes[rid];var out:Dictionary={}
  for k:String in ["handles","stop_t"]:
   if p.has(k):out[k]=p[k].duplicate(true)
  if not out.is_empty():return out
 var address:=resolve(doc,rid)
 if address.kind=="PRIMARY":return doc.new_cities[address.city].get("route",{}).duplicate(true)
 if address.kind=="SECONDARY":return doc.new_cities[address.city].extra_connections[address.link].get("route",{}).duplicate(true)
 return doc.get("moves",{}).get("routes",{}).get(rid,{}).duplicate(true)
static func write(doc:Dictionary,rid:String,edit:Dictionary)->Dictionary:
 if CustomMapFreeRoutes.enabled(doc):
  var next:=doc.duplicate(true);var p:Dictionary=next.free_routes.routes.get(rid,{})
  p.erase("handles");p.erase("stop_t")
  for k in edit:p[k]=edit[k].duplicate(true) if edit[k] is Array else edit[k]
  next.free_routes.routes[rid]=p;return next
 var out:=doc.duplicate(true);var address:=resolve(out,rid)
 if address.kind=="PRIMARY":out.new_cities[address.city]["route"]=edit.duplicate(true)
 elif address.kind=="SECONDARY":out.new_cities[address.city].extra_connections[address.link]["route"]=edit.duplicate(true)
 elif edit.is_empty():out.moves.routes.erase(rid)
 else:out.moves.routes[rid]=edit.duplicate(true)
 return out
