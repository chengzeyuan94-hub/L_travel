extends RefCounted
class_name WorldMapRuntimeLoader

## Loads approved world-map presentation + topology from data/ only (never docs/).

const PRESENTATION_PATH := "res://data/rulesets/lshu_configurable_v1/presentation/world_map_v1.json"
const TOPOLOGY_PATH := "res://data/rulesets/lshu_configurable_v1/presentation/world_map_topology_v1.json"
const HOVER_CALIBRATION_PATH := "res://data/rulesets/lshu_configurable_v1/presentation/world_city_hover_calibration_v1.json"
const CITIES_PATH := "res://data/rulesets/lshu_configurable_v1/cities.json"
const CITY_CARDS_PATH := "res://data/rulesets/lshu_configurable_v1/city_cards.json"
const NATIONS_PATH := "res://data/rulesets/lshu_configurable_v1/nations.json"
const LOGIC_SIZE := Vector2(4096, 1363)

## Topology city_id → ruleset city id. Only aliases differ.
const TOPOLOGY_TO_RULESET_CITY := {
	"ancient_rome": "rome",
	"pantuo": "panti",
}


static func load_bundle() -> Dictionary:
	var presentation := _load_json(PRESENTATION_PATH)
	var topology := _load_json(TOPOLOGY_PATH)
	var hover_calibration := _load_json(HOVER_CALIBRATION_PATH)
	var errors: Array[String] = []
	if presentation.is_empty():
		errors.append("missing presentation")
	if topology.is_empty():
		errors.append("missing topology")
	if hover_calibration.is_empty():
		errors.append("missing hover calibration")
	if not errors.is_empty():
		return {"ok": false, "errors": errors}

	var topo_ref := String(presentation.get("topology", ""))
	if topo_ref != TOPOLOGY_PATH:
		errors.append("presentation.topology mismatch: %s" % topo_ref)

	var logic: Array = presentation.get("logic_size", [])
	if logic.size() < 2 or int(logic[0]) != int(LOGIC_SIZE.x) or int(logic[1]) != int(LOGIC_SIZE.y):
		errors.append("logic_size must be 4096x1363")

	var cities: Array = presentation.get("cities", [])
	if cities.size() != 16:
		errors.append("expected 16 cities, got %d" % cities.size())
	var calibrated_cities: Array = []
	var calibration_cities: Dictionary = hover_calibration.get("cities", {})
	for city_value in cities:
		var city: Dictionary = (city_value as Dictionary).duplicate(true)
		var city_id := String(city.get("city_id", ""))
		if not calibration_cities.has(city_id):
			errors.append("missing hover calibration city: %s" % city_id)
		else:
			var calibration: Dictionary = calibration_cities[city_id]
			var rect: Array = calibration.get("static_visible_rect_px", [])
			if rect.size() != 4 or float(rect[2]) <= 0.0 or float(rect[3]) <= 0.0:
				errors.append("invalid hover calibration rect: %s" % city_id)
			else:
				city["static_visible_rect_px"] = rect.duplicate()
		calibrated_cities.append(city)
	if calibration_cities.size() != 16:
		errors.append("expected 16 hover calibration cities, got %d" % calibration_cities.size())
	cities = calibrated_cities

	var stops: Array = topology.get("playable_stops", [])
	var edges: Array = topology.get("edges", [])
	var aliases: Dictionary = topology.get("stop_aliases", {})
	var interchanges: Array = topology.get("interchange_city_ids", [])

	for err in WorldMapTopologyGate.validate(topology, presentation):
		errors.append(err)

	var stop_ids: Dictionary = {}
	for s in stops:
		stop_ids[String(s.get("id", ""))] = s

	for e in edges:
		var a := String(e.get("a", ""))
		var b := String(e.get("b", ""))
		if aliases.has(a) or aliases.has(b):
			errors.append("edge endpoint is alias: %s-%s" % [a, b])
		var layers: Array = e.get("source_path_layers", [])
		if 32 in layers:
			errors.append("path_32 present on edge %s-%s" % [a, b])
		var mov: Array = e.get("movement_polyline_px", [])
		var poly: Array = e.get("polyline_px", [])
		if mov.size() < 2:
			errors.append("movement_polyline too short: %s-%s" % [a, b])
		if not poly.is_empty() and poly != mov:
			errors.append("polyline_px != movement_polyline_px: %s-%s" % [a, b])
		if String(e.get("movement_verification_status", "")) != "auto_verified":
			errors.append("movement not auto_verified: %s-%s" % [a, b])

	var comps := _component_count(stops, edges)
	if comps != 1:
		errors.append("expected 1 connected component, got %d" % comps)
	var isolates := _isolated_stops(stops, edges)
	if not isolates.is_empty():
		errors.append("isolated stops: %s" % str(isolates))

	var id_maps := build_city_id_maps(cities)
	for err in id_maps.get("errors", []):
		errors.append(String(err))

	var origin_arr: Array = presentation.get("map_texture_origin", [0, 0])
	var map_origin := Vector2(
		float(origin_arr[0]) if origin_arr.size() > 0 else 0.0,
		float(origin_arr[1]) if origin_arr.size() > 1 else 0.0
	)
	var camera_profile: Dictionary = presentation.get("camera", {})
	if camera_profile.is_empty():
		camera_profile = {
			"default_visible_width_ratio": 0.44,
			"min_zoom_factor": 0.8,
			"default_zoom_factor": 1.0,
			"max_zoom_factor": 1.5,
			"focus_anchor": [0.45, 0.50],
			"overscan_bounds": [0, -184, 4096, 1755],
			"logic_size": [4096, 1363],
			"elastic_overscroll_screen_px": 24,
			"focus_safe_margin_px": 28,
		}
	var ob: Array = camera_profile.get("overscan_bounds", [0, -184, 4096, 1755])
	var overscan_bounds := Rect2(
		float(ob[0]) if ob.size() > 0 else 0.0,
		float(ob[1]) if ob.size() > 1 else -184.0,
		float(ob[2]) if ob.size() > 2 else 4096.0,
		float(ob[3]) if ob.size() > 3 else 1755.0
	)
	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"presentation": presentation,
		"topology": topology,
		"cities": cities,
		"stops": stops,
		"edges": edges,
		"stop_aliases": aliases,
		"interchange_city_ids": interchanges,
		"logic_size": LOGIC_SIZE,
		"map_texture_path": String(presentation.get("map_texture", "")),
		"map_texture_overscan_path": String(presentation.get("map_texture_overscan", "")),
		"map_texture_origin": map_origin,
		"camera_profile": camera_profile,
		"overscan_bounds": overscan_bounds,
		"topology_to_ruleset_city_id": id_maps.get("topology_to_ruleset_city_id", {}),
		"ruleset_to_topology_city_id": id_maps.get("ruleset_to_topology_city_id", {}),
		"projection_hash": runtime_topology_projection_hash(stops, edges),
	}


static func build_city_id_maps(cities: Array) -> Dictionary:
	var errors: Array[String] = []
	var topo_to_ruleset: Dictionary = {}
	var ruleset_to_topo: Dictionary = {}
	var cities_doc := _load_json(CITIES_PATH)
	var cards_doc := _load_json(CITY_CARDS_PATH)
	var nations_doc := _load_json(NATIONS_PATH)
	var city_ids := _item_id_set(cities_doc)
	var card_ids := _item_id_set(cards_doc)
	var nation_ids := _item_id_set(nations_doc)

	for city in cities:
		var topo_id := String(city.get("city_id", ""))
		if topo_id == "":
			errors.append("city missing city_id")
			continue
		var ruleset_id := String(TOPOLOGY_TO_RULESET_CITY.get(topo_id, topo_id))
		if topo_to_ruleset.has(topo_id):
			errors.append("duplicate topology city_id: %s" % topo_id)
		if ruleset_to_topo.has(ruleset_id):
			errors.append("duplicate ruleset city_id mapping: %s" % ruleset_id)
		topo_to_ruleset[topo_id] = ruleset_id
		ruleset_to_topo[ruleset_id] = topo_id
		if not city_ids.has(ruleset_id):
			errors.append("ruleset city missing in cities.json: %s" % ruleset_id)
		if not card_ids.has(ruleset_id):
			errors.append("ruleset city missing in city_cards.json: %s" % ruleset_id)
		if not nation_ids.has(ruleset_id):
			errors.append("ruleset city missing in nations.json: %s" % ruleset_id)

	if topo_to_ruleset.size() != 16:
		errors.append("expected 16 topology↔ruleset mappings, got %d" % topo_to_ruleset.size())

	return {
		"errors": errors,
		"topology_to_ruleset_city_id": topo_to_ruleset,
		"ruleset_to_topology_city_id": ruleset_to_topo,
	}


static func runtime_topology_projection_hash(stops: Array, edges: Array) -> String:
	## Canonical hash of playable topology used by runtime (ids, routes, polylines).
	var stop_rows: Array = []
	for s in stops:
		var routes: Array = s.get("allowed_routes", [])
		var route_copy: Array = []
		for r in routes:
			route_copy.append(String(r))
		route_copy.sort()
		var pos: Array = s.get("position_px", [0, 0])
		var anchors_variant: Variant = s.get("route_anchors_px", {})
		var anchors: Dictionary = anchors_variant if anchors_variant is Dictionary else {}
		var anchor_rows: Array[String] = []
		for route_type_value in anchors.keys():
			var route_type := String(route_type_value)
			var anchor: Array = anchors[route_type_value]
			anchor_rows.append(
				"%s:%.3f,%.3f" % [
					route_type,
					float(anchor[0]) if anchor.size() > 0 else 0.0,
					float(anchor[1]) if anchor.size() > 1 else 0.0,
				]
			)
		anchor_rows.sort()
		stop_rows.append(
			"%s|%s|%s|%.3f,%.3f|%s"
			% [
				String(s.get("id", "")),
				",".join(route_copy),
				"1" if bool(s.get("is_transport_interchange", false)) else "0",
				float(pos[0]) if pos.size() > 0 else 0.0,
				float(pos[1]) if pos.size() > 1 else 0.0,
				";".join(anchor_rows),
			]
		)
	stop_rows.sort()

	var edge_rows: Array = []
	for e in edges:
		var a := String(e.get("a", ""))
		var b := String(e.get("b", ""))
		if a > b:
			var tmp := a
			a = b
			b = tmp
		var mov: Array = e.get("movement_polyline_px", [])
		var pts: Array = []
		for p in mov:
			if p is Array and p.size() >= 2:
				pts.append("%.3f,%.3f" % [float(p[0]), float(p[1])])
		edge_rows.append(
			"%s|%s|%s|%s" % [a, b, String(e.get("route_type", "")), ";".join(pts)]
		)
	edge_rows.sort()

	var payload := "stops\n%s\nedges\n%s" % ["\n".join(stop_rows), "\n".join(edge_rows)]
	return payload.sha256_text()


static func project_candidate_edges_for_hash(candidate_edges: Array) -> Array:
	## Project candidate_edges → runtime edge fields for hash comparison.
	var out: Array = []
	for e in candidate_edges:
		out.append(
			{
				"a": String(e.get("a", "")),
				"b": String(e.get("b", "")),
				"route_type": String(e.get("route_type", "")),
				"movement_polyline_px": e.get("movement_polyline_px", []),
			}
		)
	return out


static func build_adjacency(edges: Array) -> Dictionary:
	## stop_id -> Array of {other, edge_index, route_type}
	var adj: Dictionary = {}
	for i in range(edges.size()):
		var e: Dictionary = edges[i]
		var a := String(e.get("a", ""))
		var b := String(e.get("b", ""))
		var rt := String(e.get("route_type", ""))
		if not adj.has(a):
			adj[a] = []
		if not adj.has(b):
			adj[b] = []
		adj[a].append({"other": b, "edge_index": i, "route_type": rt})
		adj[b].append({"other": a, "edge_index": i, "route_type": rt})
	return adj


static func stop_position(stop: Dictionary) -> Vector2:
	var p: Array = stop.get("position_px", [0, 0])
	return Vector2(float(p[0]), float(p[1]))


static func stop_route_position(stop: Dictionary, route_type: String) -> Vector2:
	var anchors_variant: Variant = stop.get("route_anchors_px", {})
	if anchors_variant is Dictionary:
		var anchors: Dictionary = anchors_variant
		var value: Variant = anchors.get(route_type)
		if value is Array and value.size() >= 2:
			return Vector2(float(value[0]), float(value[1]))
	return stop_position(stop)


static func polyline_to_packed(points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		if p is Array and p.size() >= 2:
			out.append(Vector2(float(p[0]), float(p[1])))
		elif p is Vector2:
			out.append(p)
	return out


static func build_arc_buffers(points: PackedVector2Array) -> Dictionary:
	var cum := PackedFloat32Array()
	cum.append(0.0)
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
		cum.append(total)
	if total < 0.001:
		total = 0.001
	return {"samples": points, "cum": cum, "total": total}


static func point_on_polyline_distance(points: PackedVector2Array, world: Vector2) -> float:
	if points.is_empty():
		return INF
	var best := world.distance_to(points[0])
	for i in range(1, points.size()):
		best = minf(best, _dist_point_segment(world, points[i - 1], points[i]))
	return best


static func _dist_point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _item_id_set(doc: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for item in doc.get("items", []):
		out[String(item.get("id", ""))] = true
	return out


static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("WorldMapRuntimeLoader: missing %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


static func _component_count(stops: Array, edges: Array) -> int:
	var adj: Dictionary = {}
	for s in stops:
		adj[String(s.get("id", ""))] = []
	for e in edges:
		var a := String(e.get("a", ""))
		var b := String(e.get("b", ""))
		if adj.has(a) and adj.has(b):
			adj[a].append(b)
			adj[b].append(a)
	var seen: Dictionary = {}
	var comps := 0
	for sid in adj.keys():
		if seen.has(sid):
			continue
		comps += 1
		var q: Array = [sid]
		seen[sid] = true
		while not q.is_empty():
			var u: String = q.pop_back()
			for v in adj[u]:
				if not seen.has(v):
					seen[v] = true
					q.append(v)
	return comps


static func _isolated_stops(stops: Array, edges: Array) -> Array:
	var deg: Dictionary = {}
	for s in stops:
		deg[String(s.get("id", ""))] = 0
	for e in edges:
		var a := String(e.get("a", ""))
		var b := String(e.get("b", ""))
		if deg.has(a):
			deg[a] = int(deg[a]) + 1
		if deg.has(b):
			deg[b] = int(deg[b]) + 1
	var out: Array = []
	for sid in deg.keys():
		if int(deg[sid]) == 0:
			out.append(sid)
	return out
