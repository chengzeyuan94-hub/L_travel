class_name CustomMapCityIntro
extends RefCounted
## One plain-text introduction per existing or new city, only in the map overlay.
const SCHEMA:="lshu.custom_map.v4"
const TITLE_MAX:=24
const BODY_MAX:=360
const LINE_MAX:=8
static func city_ids(doc:Dictionary)->Dictionary:
 var ids:Dictionary={}
 var base:Variant=JSON.parse_string(FileAccess.get_file_as_string("res://data/rulesets/lshu_configurable_v1/cities.json"))
 for city in base.get("items",[]):ids[str(city.id)]=true
 if doc.get("new_cities",[]) is Array:
  for city in doc.new_cities:
   if city is Dictionary:ids[CustomMapSchema.city_id(str(city.get("slot","")))]=true
 return ids
static func normalize_lines(text:String)->String:
 return text.replace("\r\n","\n").replace("\r","\n").replace(String.chr(0x85),"\n").replace(String.chr(0x2028),"\n").replace(String.chr(0x2029),"\n")
static func text_error(title:Variant,body:Variant)->String:
 if not title is String or not body is String:return "标题和介绍必须是纯文本"
 title=normalize_lines(title);body=normalize_lines(body)
 if title.strip_edges().is_empty() or title.length()>TITLE_MAX or title.contains("\n") or title.contains("\r"):return "标题须为1–24字，不能换行"
 if body.strip_edges().is_empty() or body.length()>BODY_MAX or body.count("\n")>=LINE_MAX or body.contains("\r"):return "介绍须为1–360字，最多8行"
 for text:String in [title,body]:
  for i in text.length():
   var code:=text.unicode_at(i)
   if (code<32 and code!=10) or code==127 or code in range(0x202a,0x202f) or code in range(0x2066,0x206a):return "文本含不支持的控制字符"
 return ""
static func error(doc:Dictionary)->String:
 if not doc.has("city_intro_cards"):return ""
 var layer:Variant=doc.city_intro_cards
 if doc.get("schema") not in [SCHEMA,"lshu.custom_map.v5","lshu.custom_map.v6"] or not layer is Dictionary or layer.size()!=2 or layer.get("version")!=1 or not layer.get("cards") is Dictionary or layer.cards.size()>20:return "城市介绍卡层格式或版本不合法"
 if doc.has("assets") and (not doc.assets is Dictionary or not doc.assets.get("entries",{}) is Dictionary):return "图片资源层格式不合法"
 var cities:=city_ids(doc)
 for cid in layer.cards:
  var card:Variant=layer.cards[cid]
  if not cid is String or not cities.has(cid) or not card is Dictionary or card.size()!=3:return "介绍卡须绑定当前地图内城市"
  var bad:=text_error(card.get("title"),card.get("description"))
  if bad!="":return bad
  var image:Variant=card.get("image")
  if not image is String:return "介绍卡图片引用格式不合法"
  if image!="":
   var entry:Variant=doc.get("assets",{}).get("entries",{}).get(image)
   if not CustomMapLocalAssets.valid_id(image) or not entry is Dictionary or entry.get("kind")!="good_icon" or not CustomMapLocalAssets.read(image,"good_icon").ok:return "介绍卡图片缺失或损坏"
 return ""
static func card(doc:Dictionary,cid:String)->Dictionary:
 return doc.get("city_intro_cards",{}).get("cards",{}).get(cid,{}).duplicate(true)
static func candidate(doc:Dictionary,cid:String,title:String,body:String,image:String,pending:Dictionary,rights:String)->Dictionary:
 var out:=doc.duplicate(true)
 if str(out.schema) not in [SCHEMA,"lshu.custom_map.v5","lshu.custom_map.v6"]:out.schema=SCHEMA;out.map_id=preload("res://scripts/map_workshop/workshop_backend.gd").new_map_id()
 if not out.has("city_intro_cards"):out.city_intro_cards={"version":1,"cards":{}}
 out.city_intro_cards.cards[cid]={"title":title,"description":normalize_lines(body),"image":image}
 if not pending.is_empty():
  if not out.has("assets"):out.assets={"version":1,"entries":{},"bindings":{}}
  out.assets.entries[pending.id]={"kind":"good_icon","bytes":pending.bytes.size(),"rights":rights}
 CustomMapLocalAssets.prune(out)
 return out
static func remove(doc:Dictionary,cid:String)->Dictionary:
 var out:=doc.duplicate(true)
 if out.has("city_intro_cards"):out.city_intro_cards.cards.erase(cid)
 CustomMapLocalAssets.prune(out)
 return out
