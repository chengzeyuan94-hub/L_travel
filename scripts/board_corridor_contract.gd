class_name BoardCorridorContract
extends RefCounted

## Physical board rules are city corridors, independent of artwork path vertices.
## Each corridor owns exactly two ROAD stops and three undirected movement edges.
const MANIFEST_PATH := "res://data/rulesets/lshu_configurable_v1/map_corridors_v1.json"
const EXPECTED_NODES := 54
const EXPECTED_EDGES := 57
const EXPECTED_LAND_EDGES := 30
const EXPECTED_SEA_EDGES := 27
const PRESENTATION_CITY_IDS := {"ancient_rome": "rome", "pantuo": "panti"}
const CORRIDOR_CITIES := {
	"LAND": [
		["rome", "constantinople"], ["constantinople", "baghdad"],
		["baghdad", "jeddah"], ["baghdad", "panti"], ["panti", "yumenguan"],
		["panti", "delhi"], ["delhi", "simhala"], ["yumenguan", "changan"],
		["changan", "quanzhou"], ["changan", "geumseong"],
	],
	"SEA": [
		["rome", "cairo"], ["cairo", "jeddah"], ["jeddah", "aden"],
		["aden", "simhala"], ["simhala", "dagon"], ["dagon", "chenla"],
		["chenla", "quanzhou"], ["quanzhou", "geumseong"],
		["quanzhou", "heijokyo"],
	],
}


static func load_manifest() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	return parsed if parsed is Dictionary else {}


static func validate(nodes: Array, edges: Array, manifest: Dictionary, presentation_ids: bool = false) -> Array[String]:
	var errors: Array[String] = []
	var expected_corridors := _expected_corridors()
	if String(manifest.get("city_anchor_policy", "")) != "one_logical_city_seat":
		errors.append("corridor manifest must use one_logical_city_seat")
	var corridors_variant: Variant = manifest.get("corridors")
	if not (corridors_variant is Array):
		errors.append("corridor manifest missing corridors array")
		return errors
	var corridors: Array = corridors_variant
	if corridors.size() != expected_corridors.size():
		errors.append("corridor manifest must contain exactly 19 city corridors")
	var expected_nodes := {}
	var expected_edges := {}
	var seen_corridors := {}
	var road_owners := {}
	for item in corridors:
		if not (item is Dictionary):
			errors.append("corridor manifest contains a malformed corridor")
			continue
		var corridor: Dictionary = item
		var corridor_id := String(corridor.get("id", ""))
		if not expected_corridors.has(corridor_id):
			errors.append("unexpected city corridor: %s" % corridor_id)
			continue
		if seen_corridors.has(corridor_id):
			errors.append("duplicate city corridor: %s" % corridor_id)
		seen_corridors[corridor_id] = true
		var expected: Dictionary = expected_corridors[corridor_id]
		var route_type := String(corridor.get("route_type", ""))
		var a := String(corridor.get("a", ""))
		var b := String(corridor.get("b", ""))
		if a != expected["a"] or b != expected["b"] or route_type != expected["route_type"]:
			errors.append("city corridor endpoints or route type changed: %s" % corridor_id)
			continue
		var via_variant: Variant = corridor.get("via")
		if not (via_variant is Array) or via_variant.size() != 2:
			errors.append("corridor %s must have exactly two ordinary stops" % corridor_id)
			continue
		var via: Array = via_variant
		for index in range(2):
			var road_id := String(via[index])
			if road_id != "%s_%02d" % [corridor_id, index + 1]:
				errors.append("corridor %s has invalid ordinary stop identity: %s" % [corridor_id, road_id])
			if road_owners.has(road_id):
				errors.append("ordinary stop shared between corridors: %s" % road_id)
			road_owners[road_id] = corridor_id
			_add_expected_node(expected_nodes, road_id, "ROAD", route_type)
		_add_expected_node(expected_nodes, a, "CITY", route_type)
		_add_expected_node(expected_nodes, b, "CITY", route_type)
		var chain := [a, String(via[0]), String(via[1]), b]
		for index in range(3):
			expected_edges[_edge_key(chain[index], chain[index + 1], route_type)] = corridor_id
		_validate_polyline(corridor.get("geometry_px"), "corridor %s geometry" % corridor_id, errors)
	for corridor_id in expected_corridors:
		if not seen_corridors.has(corridor_id):
			errors.append("missing city corridor: %s" % corridor_id)
	if not errors.is_empty():
		return errors

	if nodes.size() != EXPECTED_NODES or edges.size() != EXPECTED_EDGES:
		errors.append("corridor board must have 54 nodes and 57 edges; got %d/%d" % [nodes.size(), edges.size()])
	var actual_nodes := {}
	var positions := {}
	var degree := {}
	for item in nodes:
		if not (item is Dictionary):
			errors.append("corridor board has a malformed node")
			continue
		var node: Dictionary = item
		var node_id := _node_id(String(node.get("id", "")), presentation_ids)
		if actual_nodes.has(node_id):
			errors.append("duplicate corridor node: %s" % node_id)
		actual_nodes[node_id] = node
		degree[node_id] = 0
		if not expected_nodes.has(node_id):
			errors.append("unexpected corridor node: %s" % node_id)
			continue
		var expected: Dictionary = expected_nodes[node_id]
		var kind := String(node.get("node_type", ""))
		if presentation_ids:
			kind = {"city": "CITY", "route_point": "ROAD"}.get(String(node.get("kind", "")), "")
		if kind != expected["kind"]:
			errors.append("corridor node %s must be %s" % [node_id, expected["kind"]])
		var allowed_variant: Variant = node.get("allowed_routes")
		var allowed: Array = allowed_variant.duplicate() if allowed_variant is Array else []
		allowed.sort()
		var wanted_routes: Array = expected["routes"].duplicate()
		wanted_routes.sort()
		if allowed != wanted_routes:
			errors.append("corridor node route eligibility changed: %s" % node_id)
		if bool(node.get("is_transport_interchange", false)) != (wanted_routes.size() == 2):
			errors.append("corridor node interchange eligibility changed: %s" % node_id)
		var anchors_variant: Variant = node.get("route_anchors_px" if presentation_ids else "route_anchors")
		var anchors: Dictionary = anchors_variant if anchors_variant is Dictionary else {}
		for route_type in wanted_routes:
			if _point(anchors.get(route_type)) == null:
				errors.append("corridor node has invalid or nonfinite route anchor: %s/%s" % [node_id, route_type])
		var position: Variant = _point(node.get("position_px") if presentation_ids else node.get("map_position"))
		if position == null:
			errors.append("corridor node has invalid or nonfinite position: %s" % node_id)
		else:
			positions[node_id] = position
			if kind == "CITY":
				for route_type in wanted_routes:
					var anchor: Variant = _point(anchors.get(route_type))
					if anchor != null and (position as Vector2).distance_to(anchor) > 0.01:
						errors.append("city route anchor must share its logical city seat: %s/%s" % [node_id, route_type])
	for node_id in expected_nodes:
		if not actual_nodes.has(node_id):
			errors.append("missing corridor node: %s" % node_id)
	# Artwork spacing never changes the number of movement steps.
	var positioned_ids: Array = positions.keys()
	for one in range(positioned_ids.size()):
		for two in range(one + 1, positioned_ids.size()):
			if (positions[positioned_ids[one]] as Vector2).distance_to(positions[positioned_ids[two]]) <= 0.000001:
				errors.append("distinct corridor stops overlap: %s/%s" % [positioned_ids[one], positioned_ids[two]])

	var actual_edges := {}
	for item in edges:
		if not (item is Dictionary):
			errors.append("corridor board has a malformed edge")
			continue
		var edge: Dictionary = item
		var a := _node_id(String(edge.get("a", "")), presentation_ids)
		var b := _node_id(String(edge.get("b", "")), presentation_ids)
		var route_type := String(edge.get("route_type", ""))
		var key := _edge_key(a, b, route_type)
		if actual_edges.has(key):
			errors.append("duplicate corridor edge: %s" % key)
		actual_edges[key] = true
		if not expected_edges.has(key):
			errors.append("unexpected corridor edge: %s" % key)
		for endpoint in [a, b]:
			if degree.has(endpoint):
				degree[endpoint] += 1
		_validate_polyline(edge.get("movement_polyline_px") if presentation_ids else edge.get("movement_polyline", edge.get("movement_polyline_px")), "edge %s" % key, errors)
	for key in expected_edges:
		if not actual_edges.has(key):
			errors.append("missing corridor edge: %s" % key)
	for road_id in road_owners:
		if int(degree.get(road_id, 0)) != 2:
			errors.append("ordinary stop must have degree 2: %s (got %d)" % [road_id, int(degree.get(road_id, 0))])
	return errors


static func _expected_corridors() -> Dictionary:
	var result := {}
	for route_type in CORRIDOR_CITIES:
		for pair in CORRIDOR_CITIES[route_type]:
			var corridor_id := "%s_%s_%s" % [String(route_type).to_lower(), pair[0], pair[1]]
			result[corridor_id] = {"a": pair[0], "b": pair[1], "route_type": route_type}
	return result


static func _add_expected_node(nodes: Dictionary, node_id: String, kind: String, route_type: String) -> void:
	if not nodes.has(node_id):
		nodes[node_id] = {"kind": kind, "routes": []}
	if route_type not in nodes[node_id]["routes"]:
		nodes[node_id]["routes"].append(route_type)


static func _node_id(value: String, presentation_ids: bool) -> String:
	return String(PRESENTATION_CITY_IDS.get(value, value)) if presentation_ids else value


static func _edge_key(a: String, b: String, route_type: String) -> String:
	return "%s|%s|%s" % [route_type, a, b] if a < b else "%s|%s|%s" % [route_type, b, a]


static func _point(value: Variant) -> Variant:
	if value is Vector2:
		return value if is_finite(value.x) and is_finite(value.y) else null
	if not (value is Array) or value.size() < 2:
		return null
	for index in range(2):
		if typeof(value[index]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value[index])):
			return null
	return Vector2(float(value[0]), float(value[1]))


static func _validate_polyline(value: Variant, label: String, errors: Array[String]) -> void:
	if not (value is Array) or value.size() < 2:
		errors.append("%s has no valid polyline" % label)
		return
	var previous: Variant = null
	var length := 0.0
	for raw_point in value:
		var position: Variant = _point(raw_point)
		if position == null:
			errors.append("%s has a malformed or nonfinite polyline point" % label)
			return
		if previous != null:
			length += (previous as Vector2).distance_to(position)
		previous = position
	if length <= 0.000001:
		errors.append("%s polyline has zero length" % label)
