class_name CustomMapWin
## Win records are bound to both a topology and its exact document generator.
const PATH := "res://data/custom_map/validated_topologies_v1.json"
static var test_whitelist: Dictionary = {}
static var _cache: Dictionary = {}
static func counts(content: Dictionary) -> bool:
 if not content.has("custom_map"): return true
 var cm: Dictionary = content.custom_map
 var version := str(cm.get("tradegen", cm.get("overlay", {}).get("tradegen", "tradegen_v1")))
 return counts_key(str(cm.get("topology_key", "")), version)
static func counts_key(key: String, version: String = "tradegen_v1") -> bool:
 if key.is_empty(): return true
 if version not in CustomMapTradegenRegistry.VERSIONS: return false
 if not test_whitelist.is_empty():
  return test_whitelist.has(version+"|"+key) or (version == "tradegen_v1" and test_whitelist.has(key))
 return _whitelist(version).has(key)
static func _whitelist(version: String) -> Dictionary:
 if _cache.has(version): return _cache[version]
 var path := PATH if version == "tradegen_v1" else "res://data/custom_map/validated_topologies_"+version.trim_prefix("tradegen_")+".json"
 var out: Dictionary = {}
 if FileAccess.file_exists(path):
  var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
  if parsed is Dictionary and str(parsed.get("generator", "")) == version:
   var want: Dictionary = CustomMapTradegenRegistry.contract().get("bank_delta_per_city", {})
   if _canon_bank(want) == _canon_bank(parsed.get("bank_delta_per_city", {})):
    var topologies: Variant = parsed.get("topologies", {})
    if topologies is Dictionary:
     for key in topologies: out[str(key)] = true
 _cache[version] = out
 return out
static func _canon_bank(value: Variant) -> String:
 if not value is Dictionary: return ""
 var keys: Array = value.keys();keys.sort()
 var parts: PackedStringArray = []
 for key in keys: parts.append("%s=%d" % [str(key), int(value[key])])
 return ",".join(parts)
static func clear_cache() -> void:
 _cache.clear()
