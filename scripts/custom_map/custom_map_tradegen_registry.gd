class_name CustomMapTradegenRegistry
extends RefCounted
## A document version selects exactly one frozen economic implementation.
const LEGACY := "tradegen_v1"
const HARDENED := "tradegen_v1_hardened_1"
const ORIGINAL := "tradegen_v2_original_1"
const FREE := "tradegen_v2_free_routes_1"
const AUTHOR := "tradegen_v2_free_author_1"
const DEFAULT := ORIGINAL
const VERSIONS: Array[String] = [LEGACY, HARDENED, ORIGINAL, FREE, AUTHOR]
const CONTRACT_PATH := "res://data/custom_map/editor_rule_contract_v01.json"
const V1_PARAMS := "res://data/custom_map/tradegen_v1_params.json"
const V2_PARAMS := "res://data/custom_map/tradegen_v2_original_params.json"
const V1_SHA := "1a97041ef8fee545e8dabb83a33021d1af4d1d77e79c04f540f9ceef1889da41"
const V2_SHA := "5449577648fc516a85e87a4ce7584680b74e1a3648330685715cc20739935494"
static var _cache: Dictionary = {}
static var generation_count := 0
static var generation_microseconds := 0

static func label(version: String) -> String:
 match version:
  LEGACY: return "兼容算法 v1（无原卡参数）"
  HARDENED: return "交易规则 v1 加固版"
  ORIGINAL: return "原创交易规则 v2（测试版）"
  AUTHOR: return "自由作品（未平衡）"
  FREE: return "自由地图规则 v0.2（测试版）"
 return "未知交易规则：" + version

static func disclosure(version: String) -> String:
 if version in [FREE,AUTHOR]:return "自由地图会改变路程；交易卡按使用者确认的规则生成。经济平衡未验证，试玩不计胜场。"
 if version == ORIGINAL:
  return "原创规则为测试版：旧200次尝试中，v2有2局、旧v1有1局未在1200轮内结束；未证明死锁，也未验证货换货平衡。公开版没有原牌数值。"
 return "本图按保存的规则版本读取。更新规则须预览差异并另存副本，原图保留。"

static func params_path(version: String) -> String:
 if version in [ORIGINAL,FREE,AUTHOR]: return V2_PARAMS
 if version in [LEGACY, HARDENED]: return V1_PARAMS
 return ""

static func parameter_error(version: String) -> String:
 if version not in VERSIONS: return "未知交易规则版本：" + version
 if version in [LEGACY,HARDENED]: return "公开版不提供从原卡拟合的旧参数；请配置原创v2参数。"
 var problems := PublicRules.parameter_errors(PublicRules.configuration().get("generator_params",{}))
 return "生成规则待配置：" + "；".join(problems) if not problems.is_empty() else ""

static func contract() -> Dictionary:
 if not FileAccess.file_exists(CONTRACT_PATH): return {}
 var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONTRACT_PATH))
 if not value is Dictionary or str(value.get("schema", "")) != "lshu.editor.rule_contract.v01": return {}
 if int(value.get("max_pairs", 0)) != 2 or int(value.get("max_user", 0)) != 2: return {}
 var bank: Variant = value.get("bank_delta_per_city")
 if not bank is Dictionary or bank.size() != 3: return {}
 for count in ["2", "3", "4"]:
  if not bank.has(count) or float(bank[count]) != 0.0: return {}
 return value

static func generate(base: Dictionary, topology: Array, goods_map: Dictionary, version: String) -> Dictionary:
 if version in [FREE,AUTHOR]:return {"ok":false,"errors":["自由路线生成需要完整有效图，请使用 CustomMapValidator.generate"],"failure_code":"FREE_GRAPH_REQUIRED"}
 var problem := parameter_error(version)
 if problem != "": return {"ok": false, "errors": [problem], "failure_code": "PARAMETERS_UNAVAILABLE"}
 # Real edges and origins participate; labels/coordinates in the overlay do not.
 var signature := CustomMapSchema.canonical_text({"version": version, "params": CustomMapSchema.canonical_text(PublicRules.configuration().get("generator_params",{})).sha256_text(),
  "topology": topology, "goods_map": goods_map, "base_edges": base.get("board_edges", []),
  "base_goods": base.get("goods", {}), "base_city_cards": base.get("city_cards", {})}).sha256_text()
 if _cache.has(signature): return _cache[signature].duplicate(true)
 var started := Time.get_ticks_usec()
 var result: Dictionary = {}
 match version:
  LEGACY: result = TradeGenV1Legacy.generate(base, topology, goods_map)
  HARDENED: result = TradeGenV1.generate(base, topology, goods_map)
  ORIGINAL: result = TradeGenV2Original.generate(base, topology, goods_map)
 generation_count += 1
 generation_microseconds += Time.get_ticks_usec() - started
 if result.get("ok", false):
  if _cache.size() >= 16: _cache.erase(_cache.keys()[0])
  _cache[signature] = result.duplicate(true)
 return result

static func validate_deck(deck: Dictionary, goods: Dictionary, existing: Dictionary, local_good: String, version: String) -> Array:
 var problem := parameter_error(version)
 if problem != "": return [problem]
 match version:
  LEGACY: return TradeGenV1Legacy.validate_deck(deck, goods, existing, [local_good])
  HARDENED: return TradeGenV1.validate_deck(deck, goods, existing, [local_good])
  ORIGINAL, FREE, AUTHOR: return TradeGenV2Original.validate_deck(deck, goods, existing, local_good)
 return ["未知交易规则版本"]

static func clear_cache() -> void:
 _cache.clear()
 generation_count = 0
 generation_microseconds = 0
