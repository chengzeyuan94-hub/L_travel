class_name TradeGenV2Original
extends RefCounted
## Original economic design; intentionally isolated from the frozen v1 algorithm.
const VERSION := "tradegen_v2_original_1"
const PARAMS := "res://data/custom_map/tradegen_v2_original_params.json"

static func params() -> Dictionary:
 var v: Variant = PublicRules.configuration().get("generator_params", {})
 return integers(v) if v is Dictionary and PublicRules.parameter_errors(v).is_empty() else {}
static func integers(v: Variant) -> Variant:
 if v is float:return int(v)
 if v is Array:
  var out: Array = []
  for value in v:out.append(integers(value))
  return out
 if v is Dictionary:
  var out: Dictionary = {}
  for k in v:out[k]=integers(v[k])
  return out
 return v
static func canonical(v: Variant) -> String:
 if v is int or v is float:return str(int(v))
 if v is Array:
  var items: PackedStringArray = []
  for value in v:items.append(canonical(value))
  return "["+",".join(items)+"]"
 if v is Dictionary:
  var keys: Array = v.keys();keys.sort();var items: PackedStringArray = []
  for k in keys:items.append(JSON.stringify(str(k))+":"+canonical(v[k]))
  return "{"+",".join(items)+"}"
 return JSON.stringify(v)
static func key(seed: String, label: String) -> String:
 return (seed+"|"+label).sha256_text()
static func quote(d: int, p: Dictionary) -> int:
 return mini(int(p.silver_cap),int(p.price_base)+int(d/int(p.distance_step)))
static func fail(reason: String, code: String = "CONSTRAINT_INFEASIBLE") -> Dictionary:
 return {"ok":false,"version":VERSION,"failure_code":code,"errors":[reason],"decks":[]}

static func generate(base: Dictionary, topology: Array, goods_map: Dictionary) -> Dictionary:
 var goods: Dictionary = {}
 var producer: Dictionary = {}
 for g in base.get("goods",{}).values(): goods[str(g.id)]=int(g.get("supply_total",0))
 for card in base.get("city_cards",{}).values():
  var entries: Array = card.get("starting_grant",{}).get("entries",[])
  if not entries.is_empty() and str(entries[0].get("resource_kind",""))=="GOOD": producer[str(entries[0].resource_id)]=str(card.city_id)
 var graph: Dictionary = CustomMapRules.build_graph(base,{"new_cities":topology})
 var errors: Array = CustomMapRules.check_graph(base,graph)
 if not errors.is_empty(): return fail("illegal transport graph: "+str(errors))
 return generate_context(goods,producer,CustomMapRules.city_distances(graph),topology,goods_map,params())

static func generate_context(goods_in: Dictionary, producer_in: Dictionary, distances: Dictionary, topology_in: Array, goods_map: Dictionary, p: Dictionary) -> Dictionary:
 if str(p.get("version",""))!=VERSION:return fail("parameter version mismatch","INVALID_INPUT")
 var topology: Array = topology_in.duplicate(true)
 topology.sort_custom(func(a,b):return str(a.slot)<str(b.slot))
 var goods: Dictionary = goods_in.duplicate(true)
 var producer: Dictionary = producer_in.duplicate(true)
 for city in topology:
  var slot: String = str(city.slot)
  var good: String = str(goods_map.get(slot,""))
  if good=="" or goods.has(good): return fail("new good missing or already exists: "+slot)
  goods[good]=10; producer[good]="x_"+slot
 var decks: Array = []
 var audits: Array = []
 for c in topology:
  var slot: String = str(c.slot)
  var city: String = "x_"+slot
  var local: String = str(goods_map[slot])
  var partner: String = str(goods_map.get(str(c.get("partner","")),""))
  var pool: Array = producer.keys(); pool.erase(local); pool.sort()
  var ds: Dictionary = {}; var dependencies: Array = []
  for g in pool:
   if not distances.has(city) or not distances[city].has(producer[g]): return fail("unreachable origin: "+str(g),"UNREACHABLE")
   ds[g]=int(distances[city][producer[g]])
   dependencies.append([g,ds[g],goods[g],producer[g]])
  var seed: String = (VERSION+"|"+canonical(p)+"|"+city+"|"+local+"|"+partner+"|"+canonical(dependencies)).sha256_text()
  var indices: Array = range(10)
  indices.sort_custom(func(a,b):return key(seed,"local|"+str(a))<key(seed,"local|"+str(b)))
  var local_rows: Array = indices.slice(0,5)
  var remote_rows: Array = []
  for i in range(10):
   if not i in local_rows: remote_rows.append(i)
  remote_rows.sort_custom(func(a,b):return key(seed,"remote|"+str(a))<key(seed,"remote|"+str(b)))
  var silk_rows: Array = remote_rows.slice(0,int(p.silk_count))
  var slots: Array = []; var capacity: int = 0
  for i in range(10):
   slots.append(3-int(i in local_rows)-int(i in silk_rows)); capacity+=int(slots[i])
  var rank: Array = pool.duplicate()
  rank.sort_custom(func(a,b):
   if int(ds[a])!=int(ds[b]): return int(ds[a])>int(ds[b])
   var ka: String = key(seed,"include|"+str(a)); var kb: String = key(seed,"include|"+str(b))
   return ka<kb if ka!=kb else str(a)<str(b))
  rank.erase(partner)
  var included: Array = [partner] if partner!="" else []
  included.append_array(rank.slice(0,capacity-(int(p.partner_count) if partner!="" else 0)))
  included.sort()
  var counts: Dictionary = {}; var weights: Dictionary = {}; var total: int = 0; var denominator: int = 0
  for g in included:
   counts[g]=int(p.partner_count) if str(g)==partner else 1; total+=int(counts[g])
   weights[g]=int(p.weight_scale)+int(ds[g]); denominator+=int(weights[g])
   if int(goods[g])<1:return fail("insufficient foreign goods","INSUFFICIENT_GOODS")
  if included.size()<8:return fail("insufficient foreign goods","INSUFFICIENT_GOODS")
  while total<capacity:
   var choices: Array = []
   for g in included:
    if int(counts[g])<int(p.foreign_max) and str(g)!=partner:choices.append(g)
   if choices.is_empty():return fail("foreign frequency capacity exhausted")
   choices.sort_custom(func(a,b):
    var va: int = int(counts[a])*denominator-capacity*int(weights[a]); var vb: int = int(counts[b])*denominator-capacity*int(weights[b])
    if va!=vb:return va<vb
    var ka: String = key(seed,"quota|"+str(a)); var kb: String = key(seed,"quota|"+str(b))
    return ka<kb if ka!=kb else str(a)<str(b))
   counts[choices[0]]=int(counts[choices[0]])+1; total+=1
  if total>capacity:return fail("forced quota exceeds capacity")
  var targets: Dictionary = {}; var values: Array = []; var prices: Dictionary = {}; var local_q: Dictionary = {}
  for g in included:
   targets[g]=quote(int(ds[g]),p)
   for _j in range(int(counts[g])):values.append(targets[g])
  values.sort()
  for j in range(5):
   prices[local_rows[j]]=int(p.local_batches[j][1]); local_q[local_rows[j]]=int(p.local_batches[j][0])
   prices[remote_rows[j]]=int(values[int(j*(values.size()-1)/4)])
  var assignment: Dictionary = assign(counts,slots,prices,targets,seed,int(p.assignment_relaxation_budget))
  if not assignment.ok:return fail("finite assignment failed",str(assignment.failure_code))
  var did: String = "deck_"+city; var cards: Array = []
  for i in range(10):
   var entries: Array = []
   for g in assignment.rows[i]:entries.append({"resource_kind":"GOOD","resource_id":g,"quantity":1})
   if i in silk_rows:entries.append({"resource_kind":"GOOD","resource_id":"silk","quantity":1})
   if i in local_rows:entries.insert(1,{"resource_kind":"GOOD","resource_id":local,"quantity":int(local_q[i])})
   entries.append({"resource_kind":"SILVER","resource_id":"silver","quantity":int(prices[i])})
   cards.append({"id":"%s_card_%02d"%[did,i+1],"card_number":i+1,"entries":entries})
  decks.append({"id":did,"city_id":city,"cards":cards})
  var saturated: Array = []
  for g in pool:
   if int(ds[g])>=int(p.distance_step)*(int(p.silver_cap)-int(p.price_base)):saturated.append(g)
  var quote_errors: Array = []
  for i in range(10):
   for g in assignment.rows[i]:quote_errors.append({"card_number":i+1,"good":g,"target":targets[g],"actual":prices[i],"absolute_error":absi(int(targets[g])-int(prices[i]))})
  audits.append({"city_id":city,"seed":seed,"distances":ds,"unit_quote_targets":targets,"foreign_counts":counts,"assignment":{"flow":assignment.flow,"cost":assignment.cost},"quote_errors":quote_errors,"saturated_distance_goods":saturated})
 return {"ok":true,"version":VERSION,"errors":[],"decks":decks,"audit":audits}

static func add_edge(edges: Array, a: int, b: int, capacity: int, cost: int) -> int:
 var ix: int = edges.size()
 edges.append([a,b,capacity,cost]);edges.append([b,a,0,-cost])
 return ix
static func assign(counts: Dictionary, slots: Array, prices: Dictionary, targets: Dictionary, seed: String, budget: int = 400000) -> Dictionary:
 var goods: Array = counts.keys();goods.sort()
 var n: int = goods.size()+12;var source: int = 0;var sink: int = n-1
 var edges: Array = [];var references: Array = []
 var required: int = 0
 for value in slots:required+=int(value)
 for j in range(goods.size()):
  var g: String = str(goods[j]);add_edge(edges,source,j+1,int(counts[g]),0)
  for i in range(10):
   var cost: int = absi(int(targets[g])-int(prices[i]))*1000+int(key(seed,"flow|%s|%d"%[g,i]).substr(0,8).hex_to_int()%20)
   references.append([g,i,add_edge(edges,j+1,1+goods.size()+i,1,cost)])
 for i in range(10):add_edge(edges,1+goods.size()+i,sink,int(slots[i]),0)
 var flow: int = 0;var total_cost: int = 0;var relaxations: int = 0
 while flow<required:
  var distances: Array = [];distances.resize(n);distances.fill(1000000000000);distances[source]=0
  var parents: Array = [];parents.resize(n);parents.fill(-1)
  for _sweep in range(n-1):
   var changed: bool = false
   for ix in range(edges.size()):
    relaxations+=1
    if relaxations>budget:return {"ok":false,"flow":flow,"cost":total_cost,"failure_code":"BUDGET_EXHAUSTED"}
    var e: Array = edges[ix];var a: int = int(e[0]);var b: int = int(e[1])
    if int(e[2])>0 and int(distances[a])<1000000000000 and int(distances[a])+int(e[3])<int(distances[b]):
     distances[b]=int(distances[a])+int(e[3]);parents[b]=ix;changed=true
   if not changed:break
  if int(parents[sink])<0:return {"ok":false,"flow":flow,"cost":total_cost,"failure_code":"CONSTRAINT_INFEASIBLE"}
  var node: int = sink;var path: Array = []
  while node!=source:
   var ix: int = int(parents[node])
   if ix<0 or path.size()>=n:return {"ok":false,"flow":flow,"cost":total_cost,"failure_code":"CONSTRAINT_INFEASIBLE"}
   path.append(ix);node=int(edges[ix][0])
  for ix in path:
   edges[ix][2]=int(edges[ix][2])-1;edges[int(ix)^1][2]=int(edges[int(ix)^1][2])+1
  flow+=1;total_cost+=int(distances[sink])
 var rows: Array = []
 for _i in range(10):rows.append([])
 for ref in references:
  if int(edges[int(ref[2])][2])==0:rows[int(ref[1])].append(ref[0])
 return {"ok":true,"rows":rows,"flow":flow,"cost":total_cost}

static func validate_deck(deck: Dictionary, goods: Dictionary, existing: Dictionary, local: String) -> Array[String]:
 var out: Array[String] = []
 var p: Dictionary = params();var local_pairs: Array = [];var counts: Dictionary = {};var silk: int = 0
 for card in deck.get("cards",[]):
  if existing.has(str(card.get("id",""))):out.append("duplicate card")
  var silver: int = 0;var local_q: int = 0
  for e in card.get("entries",[]):
   var g: String = str(e.get("resource_id",""));var q: int = int(e.get("quantity",0))
   if str(e.get("resource_kind",""))=="SILVER":silver=q
   elif g==local:local_q=q
   else:
    counts[g]=int(counts.get(g,0))+1
    if q!=1:out.append("foreign quantity must equal one")
    if g=="silk":silk+=1
   if str(e.get("resource_kind",""))=="GOOD" and not goods.has(g):out.append("unknown good")
  if local_q>0:local_pairs.append([local_q,silver])
 if local_pairs.size()!=5:out.append("expected five local batch rows")
 local_pairs.sort_custom(func(a,b):return int(a[0])<int(b[0]) if int(a[0])!=int(b[0]) else int(a[1])<int(b[1]))
 if canonical(local_pairs)!=canonical(p.local_batches):out.append("local batch policy mismatch")
 if silk!=int(p.silk_count):out.append("silk count mismatch")
 for g in counts:
  if str(g)!="silk" and int(counts[g])>int(p.foreign_max):out.append("foreign count exceeded")
 return out
