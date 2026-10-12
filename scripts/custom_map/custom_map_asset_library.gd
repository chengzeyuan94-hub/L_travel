class_name CustomMapAssetLibrary
extends RefCounted
const TRADE_SHA := "a095b3c53de62d0b8143bcdf35dfa68e4759f1e59692634a8240a00cfa4aa773"
const TRADE_PATH := "res://data/rulesets/lshu_configurable_v1/trade_decks.json"
static var _versions: Dictionary = {}
static func version(path: String) -> String:
 if path=="" or not FileAccess.file_exists(path):return ""
 if not _versions.has(path):_versions[path]=FileAccess.get_sha256(path)
 return str(_versions[path])
static func byte_size(path: String) -> int:
 var file:=FileAccess.open(path,FileAccess.READ) if path!="" and FileAccess.file_exists(path) else null
 return file.get_length() if file!=null else 0
static func record(category: String, semantic_id: String, name: String, source: String, path := "", definition: Dictionary = {}) -> Dictionary:
 var sha:=version(path)
 return {"category":category,"semantic_id":semantic_id,"name":name,"source":source,"path":path,"sha":sha,"content_id":sha+"."+path.get_extension() if sha!="" else "","bytes":byte_size(path),"definition":definition.duplicate(true),"fits":definition.get("fits",definition.get("allowed_routes",[])),"status":str(definition.get("status","shipped")),"rights":definition.get("provenance",definition.get("source_refs",[])),"thumb":"","archived":false,"user":false}
static func builtins(base: Dictionary, catalogue: Dictionary) -> Array:
 var out:Array=[]
 for cid in base.get("cities",{}):
  var city:Dictionary=base.cities[cid]
  out.append(record("city_model","builtin:city:"+str(cid),str(city.display_name),"original","res://assets/merchant_board_claude/cities/"+str(cid)+".glb",city))
 for gid in base.get("goods",{}):
  var good:Dictionary=base.goods[gid]
  var item:=record("good_icon","builtin:good:"+str(gid),str(good.get("display_name",gid)),"original",str(good.get("sprite","")),good)
  item.identity=str(gid);item.thumb=item.path;out.append(item)
 for cid in base.get("city_cards",{}):
  var resolved:=FormalCardPresentationResolver.resolve_city_card(base,str(cid))
  var item:=record("city_card","builtin:city_card:"+str(cid),str(base.cities.get(cid,{}).get("display_name",cid)),"original",str(resolved.get("illustration_path","")),base.city_cards[cid])
  item.resolved=resolved;item.thumb=item.path;item.city_id=cid;out.append(item)
 for did in base.get("trade_decks",{}):
  var deck:Dictionary=base.trade_decks[did]
  for card_id in deck.get("cards",{}):
   var item:=record("trade_card","builtin:card:"+str(card_id),"用户配置贸易卡 · "+str(card_id).get_slice("_card_",1),"original",TRADE_PATH,GameData.get_trade_card(base,str(card_id)))
   item.deck_id=did;item.card_id=card_id;item.content=base;item.fits=[];item.frozen=true;out.append(item)
 for archetype in catalogue.get("archetypes",[]):
  if not CustomMapCatalogue.is_usable(archetype):continue
  var source:="draft" if archetype.status=="draft" else ("retired" if archetype.status=="retired" else "catalogue")
  var item:=record("city_model","catalogue:archetype:"+str(archetype.id),str(archetype.get("display_name",archetype.get("title",archetype.id))),source,str(archetype.model),archetype)
  item.thumb=str(archetype.get("thumb",""));out.append(item)
  var by_route:Dictionary=archetype.get("card_art_by_route",{})
  if by_route.is_empty() and archetype.get("card_art","")!="":by_route={"LAND":archetype.card_art}
  for route in by_route:
   var art:=record("city_card","catalogue:card_art:"+str(archetype.id)+":"+str(route),str(archetype.get("display_name",archetype.get("title",archetype.id)))+(" · 陆路" if route=="LAND" else " · 海路"),source,str(by_route[route]),archetype)
   art.thumb=art.path;art.fits=[route];art.route=route;out.append(art)
 for specialty in catalogue.get("specialties",[]):
  if not CustomMapCatalogue.is_usable(specialty):continue
  var source:="draft" if specialty.status=="draft" else ("retired" if specialty.status=="retired" else "catalogue")
  var item:=record("good_icon","catalogue:specialty:"+str(specialty.key),str(specialty.display_name),source,str(specialty.icon),specialty)
  item.identity=str(specialty.key);item.thumb=item.path;out.append(item)
 for preset in CustomMapPiecePresets.ITEMS:
  var item:=record("piece","preset:piece:"+str(preset.id),str(preset.name),"preset",CustomMapPiecePresets.model(str(preset.id)),preset)
  item.thumb=CustomMapPiecePresets.thumbnail(str(preset.id));item.fits=["LAND" if preset.transport=="CAMEL" else "SEA"];item.transport=preset.transport;item.rights="本项目通用棋子；见素材许可清单";out.append(item)
 return out
static func collect(base: Dictionary, catalogue: Dictionary, current: Dictionary, merged: Dictionary = {}) -> Dictionary:
 var out:=builtins(base,catalogue)
 var builtin_content:Dictionary={}
 for item in out:
  if item.content_id!="":
   if not builtin_content.has(item.content_id):builtin_content[item.content_id]=[]
   builtin_content[item.content_id].append(item.semantic_id)
 var scanned:=CustomMapAssetRefs.scan(current,out)
 var metadata:=CustomMapAssetMeta.load_index()
 var map_id:=str(current.get("map_id","未保存"));var map_sha:=CustomMapSchema.sha256(current)
 # Current generated decks are read verbatim. They are never independently generated here.
 for deck in current.get("generated",{}).get("decks",[]):
  for card in deck.get("cards",[]):
   var item:=record("trade_card","map:"+map_id+":card:"+str(card.id)+"@"+str(current.get("tradegen","")),str(current.get("name","当前图"))+" · "+str(card.id).get_slice("_card_",1),"map","",card)
   item.deck_id=deck.id;item.card_id=card.id;item.content=merged;item.map_id=map_id;item.map_sha=map_sha;item.version=str(current.get("tradegen",""));item.frozen=false;out.append(item)
 for cid in current.get("city_intro_cards",{}).get("cards",{}):
  var card:Dictionary=current.city_intro_cards.cards[cid]
  var item:=record("city_card","map:"+map_id+":city_card:"+str(cid),str(card.title),"map",CustomMapLocalAssets.path(str(card.get("image",""))),card)
  item.city_id=cid;item.user_card=card;item.map_id=map_id;item.map_sha=map_sha;out.append(item)
 # Semantic goods are independent from shared image bytes and carry the owning map identity.
 for city in current.get("new_cities",[]):
  var slot:=str(city.get("slot",""));var spec:=str(city.get("specialty",""))
  if spec=="":continue
  var good_id:="x_"+slot+"_"+spec
  var image:=str(current.get("assets",{}).get("bindings",{}).get(slot,{}).get("good_icon",""))
  var specialty:=CustomMapCatalogue.specialty(catalogue,spec)
  var item:=record("good_icon","map:"+map_id+":good:"+good_id,str(specialty.get("display_name",spec))+" · 本图","map",CustomMapLocalAssets.path(image) if image!="" else str(specialty.get("icon","")),specialty)
  item.identity=good_id;item.map_id=map_id;item.map_sha=map_sha;item.thumb=item.path;out.append(item)
 for file in CustomMapAssetRefs.files(CustomMapLocalAssets.root()):
  if not CustomMapLocalAssets.valid_id(file):continue
  var meta:Dictionary=metadata.data.items.get(file,CustomMapAssetMeta.default_item(file))
  var roles:Array=[]
  for ref in scanned.items.get(file,[]):
   var role:=str(ref.role)
   if role not in roles:roles.append(role)
  var kind:=str(meta.get("purpose_hint",""))
  if kind=="":
   for ref in scanned.items.get(file,[]):
    if ref.get("kind","") in ["city_model","actor_model","good_icon"]:kind=str(ref.kind);break
  if kind=="":kind="actor_model" if "piece" in roles else (reconstructed_glb_kind(CustomMapLocalAssets.path(file)) if file.ends_with(".glb") else "good_icon")
  var category:="piece" if kind=="actor_model" else ("city_card" if kind=="city_intro" else ("city_model" if kind=="city_model" else "good_icon"))
  var item:=record(category,"user:content:"+file,str(meta.get("display_name",file.substr(0,12))),"user",CustomMapLocalAssets.path(file))
  item.content_id=file;item.user=true;item.meta=meta;item.archived=bool(meta.get("archived",false));item.roles=roles;item.rights=meta.get("claims",[]);item.same_as_builtin=builtin_content.get(file,[]);item.kind=kind;item.thumb=item.path if not file.ends_with(".glb") else "";out.append(item)
  var purposes:Array=meta.get("purpose_hints",[]).duplicate()
  if "city_intro" in roles and "city_intro" not in purposes:purposes.append("city_intro")
  if "city_intro" in purposes and category!="city_card":
   var intro_item:Dictionary=item.duplicate(true);intro_item.category="city_card";intro_item.semantic_id="user:purpose:city_intro:"+file;intro_item.kind="city_intro";out.append(intro_item)
  if ("good_icon" in purposes or "badge_icon" in purposes) and category=="city_card":
   var icon_item:Dictionary=item.duplicate(true);icon_item.category="good_icon";icon_item.semantic_id="user:purpose:good_icon:"+file;icon_item.kind="good_icon";out.append(icon_item)
 for item in out:item.refs=scanned.items.get(item.content_id,[])
 return {"items":out,"refs":scanned,"metadata_message":str(metadata.message)+("\n引用扫描不完整："+"、".join(scanned.warnings)+"；我的资源暂受保护。" if not scanned.warnings.is_empty() else ""),"trade_frozen":FileAccess.get_sha256(TRADE_PATH)==TRADE_SHA}
static func reconstructed_glb_kind(path:String)->String:
 var bytes:=FileAccess.get_file_as_bytes(path)
 if bytes.size()<28 or bytes.size()>CustomMapLocalAssets.LIMIT:return "city_model"
 var length:=int(bytes.decode_u32(12))
 if length<2 or 20+length>bytes.size():return "city_model"
 var json:=JSON.new()
 if json.parse(bytes.slice(20,20+length).get_string_from_utf8())!=OK or not json.data is Dictionary:return "city_model"
 var doc:Dictionary=json.data
 if doc.get("skins",[]) is Array and not doc.get("skins",[]).is_empty():return "actor_model"
 if doc.get("animations",[]) is Array and not doc.get("animations",[]).is_empty():return "actor_model"
 return "city_model"
static func filtered(items: Array, category: String, query: String, source: String, archived: bool, fit: String) -> Array:
 var out:Array=[];var needle:=query.strip_edges().to_lower()
 for item in items:
  if item.category!=category or bool(item.archived)!=archived:continue
  if source!="all" and item.source!=source:continue
  if fit!="all" and not item.fits.is_empty() and fit not in item.fits:continue
  if fit!="all" and item.category=="piece" and fit not in item.fits:continue
  var haystack:=str(item.name)+" "+str(item.semantic_id)+" "+str(item.sha)+" "+JSON.stringify(item.get("meta",{}))+" "+JSON.stringify(item.get("refs",[]))
  if needle!="" and needle not in haystack.to_lower():continue
  out.append(item)
 return out
