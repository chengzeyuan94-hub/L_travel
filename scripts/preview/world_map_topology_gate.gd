extends RefCounted
class_name WorldMapTopologyGate

## Strict topology integrity checks (used by loader + negative-path tests).

const CorridorContract := preload("res://scripts/board_corridor_contract.gd")
const EXPECTED_STOPS := CorridorContract.EXPECTED_NODES
const EXPECTED_EDGES := CorridorContract.EXPECTED_EDGES
const EXPECTED_ALIASES := 20
const EXPECTED_ALIAS_TARGETS := {
	"land_point_001": "ancient_rome",
	"sea_point_001": "ancient_rome",
	"land_point_003": "constantinople",
	"sea_point_003": "cairo",
	"land_point_006": "jeddah",
	"sea_point_006": "jeddah",
	"land_point_008": "baghdad",
	"sea_point_009": "aden",
	"land_point_011": "pantuo",
	"land_point_014": "delhi",
	"land_point_016": "simhala",
	"sea_point_013": "simhala",
	"sea_point_015": "dagon",
	"land_point_018": "yumenguan",
	"sea_point_020": "chenla",
	"land_point_021": "changan",
	"land_point_023": "quanzhou",
	"sea_point_022": "quanzhou",
	"sea_point_025": "geumseong",
	"sea_point_026": "heijokyo",
}
const EXPECTED_INTERCHANGE_TOPOLOGY := ["ancient_rome", "geumseong", "simhala", "jeddah", "quanzhou"]
const EXPECTED_INTERCHANGE_RULESET := ["rome", "jeddah", "simhala", "quanzhou", "geumseong"]
const TOPOLOGY_TO_RULESET := {"ancient_rome": "rome", "pantuo": "panti"}
const VALID_ROUTE_TYPES := ["LAND", "SEA"]


static func validate(topology: Dictionary, presentation: Dictionary = {}) -> Array[String]:
	var errors: Array[String] = []
	var stops: Array = topology.get("playable_stops", [])
	var edges: Array = topology.get("edges", [])
	errors.append_array(CorridorContract.validate(stops, edges, CorridorContract.load_manifest(), true))
	var aliases: Dictionary = topology.get("stop_aliases", {})
	var interchanges: Array = topology.get("interchange_city_ids", [])

	if stops.size() != EXPECTED_STOPS:
		errors.append("playable_stops count %d != %d" % [stops.size(), EXPECTED_STOPS])
	if edges.size() != EXPECTED_EDGES:
		errors.append("edges count %d != %d" % [edges.size(), EXPECTED_EDGES])
	if aliases.size() != EXPECTED_ALIASES:
		errors.append("aliases count %d != %d" % [aliases.size(), EXPECTED_ALIASES])

	var stop_ids: Dictionary = {}
	var stop_by_id: Dictionary = {}
	var flagged_interchanges: Dictionary = {}
	for s in stops:
		if not (s is Dictionary):
			errors.append("malformed playable stop")
			continue
		var sid := String(s.get("id", ""))
		if sid == "":
			errors.append("empty stop id")
			continue
		if stop_ids.has(sid):
			errors.append("duplicate stop id: %s" % sid)
		stop_ids[sid] = true
		stop_by_id[sid] = s
		var position: Variant = _point_or_null(s.get("position_px"))
		if position == null:
			errors.append("stop %s has invalid position_px" % sid)
		var allowed_variant: Variant = s.get("allowed_routes", [])
		var allowed: Array = allowed_variant if allowed_variant is Array else []
		var anchors_variant: Variant = s.get("route_anchors_px", {})
		var anchors: Dictionary = anchors_variant if anchors_variant is Dictionary else {}
		if anchors.size() != allowed.size():
			errors.append("stop %s route anchor count mismatch" % sid)
		for route_value in allowed:
			var route_type := String(route_value)
			if not anchors.has(route_type):
				errors.append("stop %s missing %s route anchor" % [sid, route_type])
			elif _point_or_null(anchors[route_type]) == null:
				errors.append("stop %s has invalid %s route anchor" % [sid, route_type])
		for anchor_key_value in anchors.keys():
			if String(anchor_key_value) not in allowed:
				errors.append("stop %s has unexpected route anchor %s" % [sid, String(anchor_key_value)])
		if bool(s.get("is_transport_interchange", false)):
			flagged_interchanges[sid] = true

	# Original artwork city-seat aliases are source references, not movement stops.
	for alias_id in EXPECTED_ALIAS_TARGETS.keys():
		if not aliases.has(alias_id):
			errors.append("missing alias entry: %s" % alias_id)
			continue
		var expected_target := String(EXPECTED_ALIAS_TARGETS[alias_id])
		var actual_target := String(aliases[alias_id])
		if actual_target != expected_target:
			errors.append("alias target mismatch: %s -> %s (expected %s)" % [alias_id, actual_target, expected_target])
	for raw_alias_id in aliases.keys():
		var alias_id := String(raw_alias_id)
		if alias_id == "":
			errors.append("empty alias id")
			continue
		if not EXPECTED_ALIAS_TARGETS.has(alias_id):
			errors.append("unexpected alias entry: %s" % alias_id)
		if stop_ids.has(alias_id):
			errors.append("alias listed as playable stop: %s" % alias_id)
		var target := String(aliases[raw_alias_id])
		if not stop_ids.has(target):
			errors.append("alias target missing: %s -> %s" % [alias_id, target])

	var edge_keys: Dictionary = {}
	var land_edges := 0
	var sea_edges := 0
	for i in range(edges.size()):
		if not (edges[i] is Dictionary):
			errors.append("malformed edge %d" % i)
			continue
		var e: Dictionary = edges[i]
		var a := String(e.get("a", ""))
		var b := String(e.get("b", ""))
		var route_type := String(e.get("route_type", ""))
		var edge_key := _canonical_edge_key(a, b, route_type)
		if edge_keys.has(edge_key):
			errors.append("duplicate undirected edge: %s" % edge_key)
		edge_keys[edge_key] = true
		if a == "" or b == "":
			errors.append("edge %d has empty endpoint" % i)
		if a == b and a != "":
			errors.append("edge %d is a self loop: %s" % [i, a])
		if not (route_type in VALID_ROUTE_TYPES):
			errors.append("edge %d invalid route_type: %s" % [i, route_type])
		elif route_type == "LAND":
			land_edges += 1
		else:
			sea_edges += 1
		if not stop_ids.has(a):
			errors.append("edge dangling a: %s (edge %d)" % [a, i])
		if not stop_ids.has(b):
			errors.append("edge dangling b: %s (edge %d)" % [b, i])
		_validate_movement_polyline(errors, e.get("movement_polyline_px", null), i, edge_key)
		var movement_variant: Variant = e.get("movement_polyline_px", [])
		if movement_variant is Array and (movement_variant as Array).size() >= 2:
			var movement: Array = movement_variant
			for endpoint_data in [[a, movement[0], "start"], [b, movement[movement.size() - 1], "end"]]:
				var endpoint_id := String(endpoint_data[0])
				if not stop_by_id.has(endpoint_id):
					continue
				var endpoint_stop: Dictionary = stop_by_id[endpoint_id]
				var anchors_variant: Variant = endpoint_stop.get("route_anchors_px", {})
				var anchors: Dictionary = anchors_variant if anchors_variant is Dictionary else {}
				var actual: Variant = _point_or_null(endpoint_data[1])
				var expected: Variant = _point_or_null(anchors.get(route_type))
				if actual == null or expected == null or (actual as Vector2).distance_to(expected as Vector2) > 1.0:
					errors.append(
					"edge %d %s does not attach to %s/%s route anchor"
					% [i, String(endpoint_data[2]), endpoint_id, route_type]
				)
	if land_edges != CorridorContract.EXPECTED_LAND_EDGES or sea_edges != CorridorContract.EXPECTED_SEA_EDGES:
		errors.append("route edge counts must be LAND=30 SEA=27, got %d/%d" % [land_edges, sea_edges])

	var topology_interchanges: Dictionary = {}
	var mapped: Dictionary = {}
	for raw in interchanges:
		var tid := String(raw)
		if topology_interchanges.has(tid):
			errors.append("duplicate interchange city: %s" % tid)
		topology_interchanges[tid] = true
		var rid := String(TOPOLOGY_TO_RULESET.get(tid, tid))
		mapped[rid] = tid
	_append_exact_set_errors(errors, "topology interchange", topology_interchanges, EXPECTED_INTERCHANGE_TOPOLOGY)
	_append_exact_set_errors(errors, "flagged interchange", flagged_interchanges, EXPECTED_INTERCHANGE_TOPOLOGY)
	if mapped.size() != EXPECTED_INTERCHANGE_RULESET.size():
		errors.append("interchange mapped size %d != %d" % [mapped.size(), EXPECTED_INTERCHANGE_RULESET.size()])
	for want in EXPECTED_INTERCHANGE_RULESET:
		if not mapped.has(want):
			errors.append("missing interchange ruleset city: %s" % want)
	for got in mapped.keys():
		if not (got in EXPECTED_INTERCHANGE_RULESET):
			errors.append("unexpected interchange ruleset city: %s" % got)

	if not presentation.is_empty():
		var notes: Dictionary = presentation.get("notes", {})
		# PXD circles retain their city/road source roles; the corridor manifest
		# assigns their gameplay identities rather than exposing raw marker IDs.
		for marker in presentation.get("route_points", []):
			if marker is Dictionary and bool(marker.get("playable", false)):
				errors.append("source marker must not be directly playable: %s" % String(marker.get("id", "")))
		# candidate alias keys referenced by presentation counts if present
		var counts: Dictionary = presentation.get("counts", {})
		if counts.has("playable_stops") and int(counts.get("playable_stops")) != EXPECTED_STOPS:
			errors.append("presentation.counts.playable_stops mismatch")
		if counts.has("unique_edges") and int(counts.get("unique_edges")) != EXPECTED_EDGES:
			errors.append("presentation.counts.unique_edges mismatch")
		if bool(notes.get("candidate_only", false)):
			errors.append("candidate_only must be false")

	return errors


static func validate_or_empty_ok(topology: Dictionary, presentation: Dictionary = {}) -> bool:
	return validate(topology, presentation).is_empty()


static func _append_exact_set_errors(
	errors: Array[String], label: String, actual: Dictionary, expected: Array
) -> void:
	for expected_id in expected:
		if not actual.has(String(expected_id)):
			errors.append("missing %s: %s" % [label, expected_id])
	for actual_id in actual.keys():
		if not (String(actual_id) in expected):
			errors.append("unexpected %s: %s" % [label, actual_id])


static func _canonical_edge_key(a: String, b: String, route_type: String) -> String:
	var first := a
	var second := b
	if second < first:
		first = b
		second = a
	return "%s|%s|%s" % [first, second, route_type]


static func _validate_movement_polyline(
	errors: Array[String], raw_polyline: Variant, edge_index: int, edge_key: String
) -> void:
	if typeof(raw_polyline) != TYPE_ARRAY:
		errors.append("edge %d missing movement_polyline_px: %s" % [edge_index, edge_key])
		return
	var polyline: Array = raw_polyline
	if polyline.size() < 2:
		errors.append("edge %d movement_polyline_px too short: %s" % [edge_index, edge_key])
		return
	for point_index in range(polyline.size()):
		var raw_point: Variant = polyline[point_index]
		if typeof(raw_point) != TYPE_ARRAY or (raw_point as Array).size() < 2:
			errors.append(
				"edge %d movement point %d malformed: %s" % [edge_index, point_index, edge_key]
			)
			return
		var point: Array = raw_point
		if not _is_number(point[0]) or not _is_number(point[1]):
			errors.append(
				"edge %d movement point %d is not numeric: %s" % [edge_index, point_index, edge_key]
			)
			return
		if not is_finite(float(point[0])) or not is_finite(float(point[1])):
			errors.append(
				"edge %d movement point %d is not finite: %s" % [edge_index, point_index, edge_key]
			)
			return


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _point_or_null(value: Variant) -> Variant:
	if value is Vector2:
		return value if is_finite(value.x) and is_finite(value.y) else null
	if value is Array and value.size() >= 2 and _is_number(value[0]) and _is_number(value[1]):
		if is_finite(float(value[0])) and is_finite(float(value[1])):
			return Vector2(float(value[0]), float(value[1]))
	return null
