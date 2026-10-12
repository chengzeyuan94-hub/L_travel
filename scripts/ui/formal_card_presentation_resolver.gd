extends RefCounted
class_name FormalCardPresentationResolver

## Read-only formal city/event/illustration presentation resolver.
## Never caches Texture2D; never mutates GameState.


static func resolve_illustration(
	content: Dictionary,
	illustration_id: String,
	expected_entity_type: String,
	expected_owner_id: String
) -> Dictionary:
	var fail := func(reason: String) -> Dictionary:
		push_warning("FormalCardPresentationResolver: %s" % reason)
		return {
			"success": false,
			"reason": reason,
			"illustration": {},
			"runtime_path": "",
		}
	if illustration_id == "":
		return fail.call("empty illustration_id")
	var illustrations: Dictionary = content.get("illustrations", {})
	if not illustrations.has(illustration_id):
		return fail.call("illustration missing: %s" % illustration_id)
	var ill: Dictionary = illustrations[illustration_id]
	var entity_type := String(ill.get("entity_type", ""))
	if entity_type != expected_entity_type:
		return fail.call(
			"entity_type mismatch for %s: got %s want %s" % [illustration_id, entity_type, expected_entity_type]
		)
	var entity_id := String(ill.get("entity_id", ""))
	var owner_id := String(ill.get("formal_owner_id", ""))
	if entity_id != expected_owner_id or owner_id != expected_owner_id:
		return fail.call(
			"owner mismatch for %s: entity_id=%s formal_owner_id=%s want %s"
			% [illustration_id, entity_id, owner_id, expected_owner_id]
		)
	var runtime_path := String(ill.get("runtime_path", ""))
	if runtime_path == "":
		return fail.call("empty runtime_path for %s" % illustration_id)
	if not ResourceLoader.exists(runtime_path):
		return fail.call("runtime_path missing on disk: %s" % runtime_path)
	return {
		"success": true,
		"reason": "",
		"illustration": ill.duplicate(true),
		"runtime_path": runtime_path,
	}


static func resolve_city_card(content: Dictionary, city_id: String) -> Dictionary:
	var fail := func(reason: String) -> Dictionary:
		push_warning("FormalCardPresentationResolver city: %s" % reason)
		return {"success": false, "reason": reason}
	if city_id == "" or city_id == "ancient_rome" or city_id == "pantuo":
		return fail.call("invalid formal city_id: %s" % city_id)
	var cities: Dictionary = content.get("cities", {})
	if not cities.has(city_id):
		return fail.call("city missing: %s" % city_id)
	var city: Dictionary = cities[city_id]
	var city_card_id := String(city.get("city_card_id", ""))
	var cards: Dictionary = content.get("city_cards", {})
	if not cards.has(city_card_id):
		return fail.call("city_card missing: %s" % city_card_id)
	var card: Dictionary = cards[city_card_id]
	if String(card.get("city_id", "")) != city_id:
		return fail.call("city_card.city_id mismatch for %s" % city_id)
	var ill_id_city := String(city.get("illustration_id", ""))
	var ill_id_card := String(card.get("illustration_id", ""))
	if ill_id_city == "" or ill_id_city != ill_id_card:
		return fail.call("illustration_id mismatch city/card for %s" % city_id)
	var ill := resolve_illustration(content, ill_id_city, "CITY", city_id)
	if not bool(ill.get("success", false)):
		return fail.call(String(ill.get("reason", "illustration resolve failed")))
	var nations: Dictionary = content.get("nations", {})
	var nation_id := String(city.get("nation_id", ""))
	var nation_name := nation_id
	if nations.has(nation_id):
		nation_name = String(nations[nation_id].get("display_name", nation_id))
	var lore_catalog: Dictionary = content.get("city_lore", {})
	if not lore_catalog.has(city_id):
		return fail.call("city_lore missing: %s" % city_id)
	var lore: Dictionary = lore_catalog[city_id]
	if String(lore.get("city_id", "")) != city_id:
		return fail.call("city_lore.city_id mismatch for %s" % city_id)
	for field in ["epithet", "position", "history", "sights", "historical_period", "modern_reference"]:
		if String(lore.get(field, "")).strip_edges().is_empty():
			return fail.call("city_lore.%s missing for %s" % [String(field), city_id])
	var grant: Dictionary = card.get("starting_grant", {})
	var entries: Array = grant.get("entries", []) if grant is Dictionary else []
	var art := String(ill.get("illustration", {}).get("art_review_status", ""))
	return {
		"success": true,
		"reason": "",
		"city_id": city_id,
		"display_name": String(city.get("display_name", city_id)),
		"user_intro": content.get("city_intro_cards", {}).get(city_id, {}).duplicate(true),
		"nation": nation_name,
		"nation_id": nation_id,
		"map_attribute": String(city.get("map_attribute", "")),
		"allowed_routes": city.get("allowed_routes", []).duplicate(true),
		"card_number": int(card.get("card_number", 0)),
		"starting_transport": String(card.get("starting_transport", city.get("starting_transport", "CAMEL"))),
		"starting_grant": {"entries": entries.duplicate(true)},
		"illustration_id": ill_id_city,
		"illustration_path": String(ill.get("runtime_path", "")),
		"art_review_status": art,
		"illustration": ill.get("illustration", {}),
		"epithet": String(lore.get("epithet", "")),
		"position": String(lore.get("position", "")),
		"history": String(lore.get("history", "")),
		"sights": String(lore.get("sights", "")),
		"historical_period": String(lore.get("historical_period", "")),
		"modern_reference": String(lore.get("modern_reference", "")),
		"lore_source_refs": lore.get("source_refs", []).duplicate(true),
		"lore_verification_status": String(lore.get("verification_status", "")),
		"intro": String(content.get("card_text_cities", {}).get(city_id, {}).get("intro", "")),
		"scenery": String(content.get("card_text_cities", {}).get(city_id, {}).get("scenery", "")),
	}


static func resolve_event(content: Dictionary, event_id: String) -> Dictionary:
	var fail := func(reason: String) -> Dictionary:
		push_warning("FormalCardPresentationResolver event: %s" % reason)
		return {"success": false, "reason": reason}
	if event_id == "":
		return fail.call("empty event_id")
	var defs: Dictionary = content.get("event_definitions", {})
	if not defs.has(event_id):
		return fail.call("event definition missing: %s" % event_id)
	var definition: Dictionary = defs[event_id]
	var ill_id := String(definition.get("illustration_id", ""))
	var ill := resolve_illustration(content, ill_id, "EVENT", event_id)
	if not bool(ill.get("success", false)):
		return fail.call(String(ill.get("reason", "illustration resolve failed")))
	var illustration: Dictionary = ill.get("illustration", {})
	var deck := String(definition.get("deck_type", ""))
	var card_number := int(definition.get("card_number", 0))
	if String(illustration.get("deck_type", "")) != deck:
		return fail.call("deck_type mismatch for %s" % event_id)
	if int(illustration.get("card_number", -1)) != card_number:
		return fail.call("card_number mismatch for %s" % event_id)
	var sentiment := normalize_sentiment(String(definition.get("sentiment", "NEUTRAL")))
	var art := String(illustration.get("art_review_status", ""))
	return {
		"success": true,
		"reason": "",
		"event_id": event_id,
		"title": String(definition.get("title", "")),
		"deck_type": deck,
		"card_number": card_number,
		"original_effect_text": String(definition.get("original_effect_text", "")),
		"normalized_effect_text": String(definition.get("normalized_effect_text", "")),
		"flavor_text": String(definition.get("flavor_text", "")),
		"idiom_explain": String(content.get("card_text_events", {}).get(event_id, {}).get("explain", "")),
		"sentiment": sentiment,
		"runtime_resolution_status": String(definition.get("runtime_resolution_status", "")),
		"illustration_id": ill_id,
		"illustration_path": String(ill.get("runtime_path", "")),
		"art_review_status": art,
		"illustration": illustration,
	}


static func resolve_event_instance(content: Dictionary, instance_id: String) -> Dictionary:
	var fail := func(reason: String) -> Dictionary:
		push_warning("FormalCardPresentationResolver instance: %s" % reason)
		return {"success": false, "reason": reason}
	var instances: Dictionary = content.get("event_card_instances", {})
	if not instances.has(instance_id):
		return fail.call("event instance missing: %s" % instance_id)
	var instance: Dictionary = instances[instance_id]
	var event_id := String(instance.get("event_id", ""))
	var resolved := resolve_event(content, event_id)
	if not bool(resolved.get("success", false)):
		return fail.call(String(resolved.get("reason", "event resolve failed")))
	if String(instance.get("deck_type", "")) != String(resolved.get("deck_type", "")):
		return fail.call("instance deck_type mismatch: %s" % instance_id)
	if int(instance.get("card_number", -1)) != int(resolved.get("card_number", -2)):
		return fail.call("instance card_number mismatch: %s" % instance_id)
	resolved["instance_id"] = instance_id
	resolved["copy_index"] = int(instance.get("copy_index", 0))
	return resolved


static func normalize_sentiment(raw: String) -> String:
	var s := raw.strip_edges().to_lower()
	if s == "positive" or s == "negative" or s == "neutral":
		return s
	return "neutral"


static func transport_label(transport: String) -> String:
	return "商船" if transport == "SHIP" else "骆驼"
