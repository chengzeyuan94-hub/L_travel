extends RefCounted
## 工坊的候选改动：先在副本里生成牌堆并走游戏同一份校验，成功才交给撤销栈。
## 编辑器不会把半对城市、旧牌堆或不合格的路线写回当前文档。

static func finish(doc: Dictionary, base: Dictionary, layout: Dictionary, catalogue: Dictionary) -> Dictionary:
	if CustomMapFreeRoutes.enabled(doc):return CustomMapFreeRoutes.finish(doc,base,layout,catalogue)
	var out := CustomMapSchema.round_coords(CustomMapSchema.canonicalize_slots(doc, base))
	var gen := CustomMapValidator.generate(base, out, catalogue)
	if not bool(gen.get("ok", false)):
		return failure("这组城市暂时配不出合适的贸易卡", str(gen.get("tech", "")))
	out["generated"] = gen["generated"]
	var check := CustomMapValidator.validate(base, layout, out, catalogue)
	if not bool(check.get("ok", false)):
		var errors: Array = check.get("errors", [])
		return {"ok": false, "reason": str(errors[0].get("kid", "地图还有问题")) if not errors.is_empty() else "地图还有问题", "errors": errors}
	return {"ok": true, "doc": out, "reason": "", "errors": [], "validation": check}


static func failure(reason: String, detail := "") -> Dictionary:
	return {"ok": false, "reason": reason, "detail": detail, "errors": []}


static func city(doc: Dictionary, cid: String) -> Dictionary:
	var slot := cid.trim_prefix("x_")
	for c: Dictionary in doc.get("new_cities", []):
		if str(c.get("slot", "")) == slot:
			return c
	return {}


static func _first_specialty(cat: Dictionary, side: String, used: Array, preferred := "") -> String:
	var preferred_entry := CustomMapCatalogue.specialty(cat, preferred)
	if not preferred_entry.is_empty() and CustomMapCatalogue.is_offered(preferred_entry) and not preferred in used:
		return preferred
	for wanted_side in [side, "E" if side == "W" else "W"]:
		for s: Dictionary in cat.get("specialties", []):
			if str(s.get("flavor_side", "")) == wanted_side and CustomMapCatalogue.is_offered(s) and not str(s.key) in used:
				return str(s.key)
	return ""


static func _arch(cat: Dictionary, side: String, rt: String) -> String:
	var id := CustomMapCatalogue.first_fit_in(cat, side, rt, [])
	return id if id != "" else CustomMapCatalogue.first_fit_in(cat, "E" if side == "W" else "W", rt, [])


## 预设位置也必须按当前布局重新画路；预设是提示，不是绕过几何校验的通行证。
static func partner_placement(doc: Dictionary, base: Dictionary, layout: Dictionary, cat: Dictionary, host: String, rt: String) -> Dictionary:
	var side := CustomMapRules.side_of_host(base, host)
	var aid := _arch(cat, side, rt)
	if aid == "":
		return {}
	var geo := CustomMapGeo.for_overlay(doc)
	var derived := CustomBoardLayout.derive(layout, doc, geo, cat)
	for p: Dictionary in CustomMapCatalogue.preset_slots(cat, host, rt):
		var q := Vector2(float(p.x), float(p.z))
		var route := CustomMapGeoRules.auto_route(derived, host, q, rt, geo)
		if not bool(route.get("ok", false)):
			continue
		var probe := doc.duplicate(true)
		(probe["new_cities"] as Array).append({"slot": "probe", "name": "试放", "archetype": aid, "host": host,
			"route_type": rt, "x": q.x, "z": q.y, "rotation": 0.0, "size": 1.0,
			"route": {"handles": route.handles, "stop_t": route.stop_t}})
		var lay := CustomBoardLayout.derive(layout, probe, geo, cat)
		if CustomMapGeoRules.check(lay, layout, probe, geo).is_empty():
			return {"x": q.x, "z": q.y, "rotation": 0.0, "size": 1.0, "route": {"handles": route.handles, "stop_t": route.stop_t}}
	var spots := CustomMapGeoRules.find_spots(layout, doc, host, rt, aid, cat, geo, 1, 3.0, "probe")
	if spots.is_empty():
		return {}
	var p: Dictionary = spots[0]
	return {"x": p.x, "z": p.z, "rotation": 0.0, "size": 1.0, "route": {"handles": p.handles, "stop_t": p.stop_t}}


## 先检查另一侧有规则许可且几何上可安放的搭档，再给这一宿主画绿区。
static func has_partner(doc: Dictionary, base: Dictionary, layout: Dictionary, cat: Dictionary, host: String, rt: String) -> bool:
	var out := doc.duplicate(true)
	var n := (out.get("new_cities", []) as Array).size() / 2 + 1
	var slot := ("e" if CustomMapRules.side_of_host(base, host) == "E" else "w") + str(int(n))
	(out["new_cities"] as Array).append({"slot": slot, "host": host, "route_type": rt, "partner": ""})
	for candidate: Dictionary in CustomMapRules.legal_partner_hosts(base, out, slot):
		if not partner_placement(doc, base, layout, cat, str(candidate.host), str(candidate.route_type)).is_empty():
			return true
	return false


static func _unused_user_name(used: Dictionary) -> String:
	for candidate in ["新城", "新城二"]:
		if not used.has(candidate): return candidate
	# At most 20 cities exist, so one of these short legal names must be free.
	for n in range(3, 23):
		var candidate := "新城" + str(n)
		if not used.has(candidate): return candidate
	return "新城23"


static func add_pair(doc: Dictionary, base: Dictionary, layout: Dictionary, cat: Dictionary, rt: String, pos: Vector2, host_hint: String = "") -> Dictionary:
	var users := 0
	var used_goods: Array = []
	var used_names := CustomMapRules.used_city_names(base, doc)
	for c: Dictionary in doc.get("new_cities", []):
		users += int(str(c.get("origin", "")) == "USER")
		used_goods.append(str(c.get("specialty", "")))
	if users >= int(CustomMapRules.params().get("max_user", 2)):
		return failure("自己加的城市已经满啦")
	var geo := CustomMapGeo.for_overlay(doc)
	var derived := CustomBoardLayout.derive(layout, doc, geo, cat)
	var hosts := CustomMapRules.legal_hosts(base, doc, rt, "")
	if host_hint != "":
		if host_hint not in hosts:
			return failure("这个位置对应的连接城市已不可用，请重新找位置")
		hosts = [host_hint]
	var candidates: Array = []
	for host: String in hosts:
		var route := CustomMapGeoRules.auto_route(derived, host, pos, rt, geo)
		if bool(route.get("ok", false)):
			var length := 0.0
			var last := Vector2.ZERO
			for c: Dictionary in derived.get("cities", []):
				if str(c.id) == host:
					last = Vector2(float(c.x), float(c.z))
			for h: Array in route.handles:
				var q := Vector2(float(h[0]), float(h[1]))
				length += last.distance_to(q)
				last = q
			length += last.distance_to(pos)
			candidates.append({"host": host, "route": route, "length": length})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.length) < float(b.length))
	var last_error := failure("这里放不下城，试试离原版城市不远的陆地")
	for candidate: Dictionary in candidates:
		var host := str(candidate.host)
		var side := CustomMapRules.side_of_host(base, host)
		var aid := _arch(cat, side, rt)
		var arch := CustomMapCatalogue.archetype(cat, aid)
		var specialty := _first_specialty(cat, side, used_goods, str(arch.get("default_specialty", "")))
		if aid == "" or specialty == "":
			return failure("这一类城市的素材还没准备好")
		var out := doc.duplicate(true)
		var name := _unused_user_name(used_names)
		var slot := ("e" if side == "E" else "w") + str(users + 1)
		(out["new_cities"] as Array).append({"slot": slot, "origin": "USER", "partner": "",
			"name": name, "name_entry": "", "archetype": aid, "specialty": specialty, "host": host, "route_type": rt,
			"x": pos.x, "z": pos.y, "rotation": 0.0, "size": 1.0,
			"route": {"handles": candidate.route.handles, "stop_t": candidate.route.stop_t}, "text": {"mode": "AUTO"}})
		var paired := CustomMapRules.pick_auto_partner(base, out, slot, cat,
			func(h: String, t: String) -> Dictionary: return partner_placement(out, base, layout, cat, h, t))
		if not bool(paired.get("ok", false)):
			last_error = failure(str(paired.get("reason", "另一侧放不下搭档")))
			continue
		var result := finish(paired.doc, base, layout, cat)
		if bool(result.ok):
			for c: Dictionary in result.doc.new_cities:
				if str(c.host) == host and str(c.origin) == "USER":
					result["city_id"] = "x_" + str(c.slot)
			return result
		last_error = result
	return last_error


## Main-thread task: one preset, reach/scan/route step, generation or full validation
## per call. All original pair/topology/TradeGen/geometry/asset gates remain intact.
static func add_pair_begin(doc: Dictionary, base: Dictionary, layout: Dictionary, cat: Dictionary, rt: String, pos: Vector2, host_hint := "") -> Dictionary:
	return {"phase": "prepare", "done": false, "source": doc.duplicate(true), "base": base, "layout": layout,
		"cat": cat, "rt": rt, "pos": pos, "hint": host_hint, "timings": [], "result": failure("这里放不下城")}


static func add_pair_step(task: Dictionary) -> void:
	if bool(task.done): return
	var started := Time.get_ticks_usec()
	var phase := str(task.phase)
	var detail := str(task.get("partner_search", {}).get("phase", "")) if phase == "partner_search" else ""
	_pair_step(task)
	task.timings.append({"phase": phase, "detail": detail, "ms": (Time.get_ticks_usec() - started) / 1000.0})


static func _pair_step(t: Dictionary) -> void:
	var base: Dictionary = t.base
	var layout: Dictionary = t.layout
	var cat: Dictionary = t.cat
	var rt := str(t.rt)
	if t.phase == "prepare":
		var used_goods: Array = []
		var used_names := CustomMapRules.used_city_names(base, t.source)
		var users := 0
		for c: Dictionary in t.source.get("new_cities", []):
			users += int(str(c.get("origin", "")) == "USER")
			used_goods.append(str(c.get("specialty", "")))
		if users >= int(CustomMapRules.params().get("max_user", 2)):
			t.result = failure("自己加的城市已经满啦"); t.done = true; return
		t["users"] = users; t["goods"] = used_goods; t["names"] = used_names
		t["geo"] = CustomMapGeo.for_overlay(t.source)
		t["derived"] = CustomBoardLayout.derive(layout, t.source, t.geo, cat)
		var hosts := CustomMapRules.legal_hosts(base, t.source, rt, "")
		if str(t.hint) != "":
			if str(t.hint) not in hosts:
				t.result = failure("这个位置对应的连接城市已不可用，请重新找位置"); t.done = true; return
			hosts = [str(t.hint)]
		t["hosts"] = hosts; t["host_index"] = 0; t["candidates"] = []; t.phase = "routes"
	elif t.phase == "routes":
		if int(t.host_index) >= t.hosts.size():
			t.candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.length) < float(b.length))
			t["candidate_index"] = 0; t.phase = "user"; return
		var host := str(t.hosts[t.host_index]); t.host_index += 1
		var route := CustomMapGeoRules.auto_route(t.derived, host, t.pos, rt, t.geo)
		if bool(route.get("ok", false)):
			var length := 0.0
			var last := Vector2.ZERO
			for c: Dictionary in t.derived.cities:
				if str(c.id) == host: last = Vector2(float(c.x), float(c.z))
			for h: Array in route.handles:
				var q := Vector2(float(h[0]), float(h[1])); length += last.distance_to(q); last = q
			length += last.distance_to(t.pos)
			t.candidates.append({"host": host, "route": route, "length": length})
	elif t.phase == "user":
		if int(t.candidate_index) >= t.candidates.size(): t.done = true; return
		var candidate: Dictionary = t.candidates[t.candidate_index]; t.candidate_index += 1
		var host := str(candidate.host)
		var side := CustomMapRules.side_of_host(base, host)
		var aid := _arch(cat, side, rt)
		var arch := CustomMapCatalogue.archetype(cat, aid)
		var specialty := _first_specialty(cat, side, t.goods, str(arch.get("default_specialty", "")))
		if aid == "" or specialty == "":
			t.result = failure("这一类城市的素材还没准备好"); t.done = true; return
		var out: Dictionary = t.source.duplicate(true)
		var slot := ("e" if side == "E" else "w") + str(int(t.users) + 1)
		var pos: Vector2 = t.pos
		(out.new_cities as Array).append({"slot": slot, "origin": "USER", "partner": "",
			"name": _unused_user_name(t.names), "name_entry": "", "archetype": aid,
			"specialty": specialty, "host": host, "route_type": rt, "x": pos.x, "z": pos.y,
			"rotation": 0.0, "size": 1.0, "route": {"handles": candidate.route.handles, "stop_t": candidate.route.stop_t}, "text": {"mode": "AUTO"}})
		t["work"] = out; t["user_slot"] = slot; t["user_host"] = host
		t["partners"] = CustomMapRules.legal_partner_hosts(base, out, slot)
		t["partner_index"] = 0; t["placements"] = {}; t.phase = "partner_begin"
	elif t.phase == "partner_begin":
		if int(t.partner_index) >= t.partners.size():
			t.result = failure("另一侧没有放得下搭档的宿主"); t.phase = "user"; return
		var partner: Dictionary = t.partners[t.partner_index]
		var host := str(partner.host); var typ := str(partner.route_type)
		var aid := _arch(cat, CustomMapRules.side_of_host(base, host), typ)
		if aid == "": t.partner_index += 1; return
		t["partner"] = partner; t["partner_arch"] = aid
		t["partner_layout"] = CustomBoardLayout.derive(layout, t.work, t.geo, cat)
		t["presets"] = CustomMapCatalogue.preset_slots(cat, host, typ); t["preset_index"] = 0
		t.phase = "partner_preset"
	elif t.phase == "partner_preset":
		if int(t.preset_index) >= t.presets.size():
			var arch := CustomMapCatalogue.archetype(cat, str(t.partner_arch))
			t["partner_search"] = CustomMapGeoRules.placement_search_begin(t.partner_layout, str(t.partner.host), str(t.partner.route_type), t.geo, float(arch.get("foot", CustomMapGeoRules.PLACE_FOOT)))
			t["partner_considered"] = 0; t.phase = "partner_search"; return
		var preset: Dictionary = t.presets[t.preset_index]; t.preset_index += 1
		var pos := Vector2(float(preset.x), float(preset.z))
		var route := CustomMapGeoRules.auto_route(t.partner_layout, str(t.partner.host), pos, str(t.partner.route_type), t.geo)
		if bool(route.get("ok", false)):
			t["probe_pos"] = pos; t["probe_route"] = route; t["probe_next"] = "partner_preset"; t.phase = "partner_geometry_validate"
	elif t.phase == "partner_search":
		var state: Dictionary = t.partner_search
		if int(t.partner_considered) < state.spots.size():
			var spot: Dictionary = state.spots[t.partner_considered]; t.partner_considered += 1
			t["probe_pos"] = Vector2(float(spot.x), float(spot.z)); t["probe_route"] = spot; t["probe_next"] = "partner_search"; t.phase = "partner_geometry_validate"
		elif bool(state.done):
			t.partner_index += 1; t.phase = "partner_begin"
		else:
			CustomMapGeoRules.placement_search_step(state, t.geo, 8.0, 1)
	elif t.phase == "partner_geometry_validate":
		t.phase = t.probe_next
		_accept_partner_position(t, t.probe_pos, t.probe_route)
	elif t.phase == "pair":
		var placements: Dictionary = t.placements
		var paired := CustomMapRules.pick_auto_partner(base, t.work, str(t.user_slot), cat,
			func(h: String, typ: String) -> Dictionary: return placements.get(h + "|" + typ, {}))
		if not bool(paired.get("ok", false)):
			t.result = failure(str(paired.get("reason", "另一侧放不下搭档"))); t.phase = "user"; return
		t["out"] = CustomMapSchema.round_coords(CustomMapSchema.canonicalize_slots(paired.doc, base)); t.phase = "generate"
	elif t.phase == "generate":
		var gen := CustomMapValidator.generate(base, t.out, cat)
		if not bool(gen.get("ok", false)):
			t.result = failure("这组城市暂时配不出合适的贸易卡", str(gen.get("tech", ""))); t.phase = "user"; return
		t.out["generated"] = gen.generated; t.phase = "validate"
	elif t.phase == "validate":
		var check := CustomMapValidator.validate(base, layout, t.out, cat)
		if not bool(check.get("ok", false)):
			var errors: Array = check.get("errors", [])
			t.result = {"ok": false, "reason": str(errors[0].get("kid", "地图还有问题")) if not errors.is_empty() else "地图还有问题", "errors": errors}
			t.phase = "user"; return
		var cid := ""
		for c: Dictionary in t.out.new_cities:
			if str(c.host) == str(t.user_host) and str(c.origin) == "USER": cid = "x_" + str(c.slot)
		t.result = {"ok": true, "doc": t.out, "city_id": cid, "validation": check, "reason": "", "errors": []}
		t.done = true


static func _accept_partner_position(t: Dictionary, pos: Vector2, route: Dictionary) -> void:
	var probe: Dictionary = t.work.duplicate(true)
	(probe.new_cities as Array).append({"slot": "probe", "name": "试放", "archetype": t.partner_arch,
		"host": t.partner.host, "route_type": t.partner.route_type, "x": pos.x, "z": pos.y,
		"rotation": 0.0, "size": 1.0, "route": {"handles": route.handles, "stop_t": route.stop_t}})
	var lay := CustomBoardLayout.derive(t.layout, probe, t.geo, t.cat)
	if CustomMapGeoRules.check(lay, t.layout, probe, t.geo).is_empty():
		t.placements[str(t.partner.host) + "|" + str(t.partner.route_type)] = {"x": pos.x, "z": pos.y,
			"rotation": 0.0, "size": 1.0, "route": {"handles": route.handles, "stop_t": route.stop_t}}
		t.phase = "pair"


static func change_city(doc: Dictionary, cid: String, field: String, value: Variant, base: Dictionary, layout: Dictionary, cat: Dictionary) -> Dictionary:
	if not field in ["name", "archetype", "specialty", "x", "z", "rotation", "size", "text"]:
		return failure("这项内容不能直接修改")
	var out := doc.duplicate(true)
	var c := city(out, cid)
	if c.is_empty():
		if field != "name" or not base.get("cities", {}).has(cid): return failure("这项内容不能直接修改")
		var why := city_name_problem(doc, cid, str(value), base)
		if why != "": return failure(why)
		return finish(CustomMapCityBadges.with_value(doc, cid, "name", value), base, layout, cat)
	if CustomMapFreeAuthor.enabled(doc):
		c[field]=value
		return finish(out,base,layout,cat)
	if field == "name":
		var why := city_name_problem(doc, cid, str(value), base)
		if why != "": return failure(why)
		if str(c.get("origin", "")) == "USER":
			out = CustomMapRules.rename_auto_on_conflict(out, cat, str(value), base).doc
			c = city(out, cid)
		c["name_entry"] = ""
		for known: Dictionary in cat.get("known_names", []):
			if str(known.get("name", "")) == str(value):
				c["name_entry"] = str(known.id)
				break
	c[field] = value
	return finish(out, base, layout, cat)


## Name preflight uses the existing R29 syntax gate. USER may take an AUTO name;
## rename_auto_on_conflict remains responsible for renaming that AUTO partner.
static func city_name_problem(doc: Dictionary, cid: String, wanted: String, base: Dictionary) -> String:
	if CustomMapFreeAuthor.enabled(doc):return "城市名字超过200字" if wanted.length()>200 else ""
	var problem := CustomMapValidator.name_problem(wanted)
	if problem != "": return problem
	for original_id in base.get("cities", {}):
		if original_id == cid: continue
		var original: Dictionary = base.cities[original_id]
		if str(CustomMapCityBadges.config(doc, original_id).get("name", original.get("display_name", ""))) == wanted: return "和原版的城重名：" + wanted
	var current := city(doc, cid)
	for other: Dictionary in doc.get("new_cities", []):
		if "x_" + str(other.slot) == cid or str(other.get("name", "")) != wanted: continue
		if str(other.get("origin", "")) == "USER" or str(current.get("origin", "")) != "USER":
			return "和另一座城市重名：" + wanted
	return ""


static func remove_pair(doc: Dictionary, cid: String, base: Dictionary, layout: Dictionary, cat: Dictionary) -> Dictionary:
	if CustomMapFreeAuthor.enabled(doc):return CustomMapFreeAuthor.remove_city(doc,cid,base,layout,cat)
	var c := city(doc, cid)
	if c.is_empty() or str(c.get("origin", "")) != "USER":
		return failure("要拆搭档，请拆掉和它配对的那座城")
	var out := doc.duplicate(true)
	# Resolve effective endpoints while all old city/route definitions exist.
	CustomMapSchema.detach_reassigned_free_routes(out, base)
	var kept: Array = []
	for other: Dictionary in out.new_cities:
		if not str(other.slot) in [str(c.slot), str(c.partner)]:
			kept.append(other)
	out.new_cities = kept
	# Deleting a pair also renumbers surviving slots and removes their old
	# references. Free-route validation must see the cleaned document.
	out = CustomMapSchema.canonicalize_slots(out, base)
	return finish(out, base, layout, cat)


static func route_edit(doc: Dictionary, rid: String) -> Dictionary:
	return preload("res://scripts/map_workshop/workshop_route_resolver.gd").read(doc,rid)

static func change_route(doc: Dictionary, rid: String, edit: Dictionary, base: Dictionary, layout: Dictionary, cat: Dictionary) -> Dictionary:
	var out:Dictionary=preload("res://scripts/map_workshop/workshop_route_resolver.gd").write(doc,rid,edit)
	return finish(out,base,layout,cat)


## 使用工坊候选提交及真实全量验证保存第二连线。
static func add_connection(doc: Dictionary, cid: String, host: String, rt: String, route: Dictionary, base: Dictionary, layout: Dictionary, cat: Dictionary) -> Dictionary:
	var out := doc.duplicate(true)
	var c := city(out, cid)
	if c.is_empty(): return failure("请先选新增城市")
	c["extra_connections"] = [{"host": host, "route_type": rt, "route": route.duplicate(true)}]
	return finish(out, base, layout, cat)


static func remove_connection(doc: Dictionary, cid: String, base: Dictionary, layout: Dictionary, cat: Dictionary) -> Dictionary:
	var out := doc.duplicate(true)
	var c := city(out, cid)
	if c.is_empty() or c.get("extra_connections", []).is_empty(): return failure("这座城没有额外连接")
	c.erase("extra_connections")
	return finish(out, base, layout, cat)

static func change_badge(doc: Dictionary, cid: String, field: String, value: Variant, base: Dictionary, layout: Dictionary, cat: Dictionary) -> Dictionary:
	if not base.get("cities", {}).has(cid) and city(doc, cid).is_empty(): return failure("名牌目标城市不存在")
	if field not in ["mode", "offset_px", "icon"]: return failure("名牌属性不合法")
	var out := CustomMapCityBadges.with_value(doc, cid, field, value)
	if field == "offset_px": out.city_badges[cid].mode = "MANUAL"
	if field == "mode" and value == "AUTO": out.city_badges[cid].erase("offset_px")
	if field == "icon" and value != "IMAGE" and out.has("assets"):
		var slot := cid.trim_prefix("x_")
		if out.assets.bindings.has(slot):
			out.assets.bindings[slot].erase("badge_icon")
			if out.assets.bindings[slot].is_empty(): out.assets.bindings.erase(slot)
		CustomMapLocalAssets.prune(out)
	var why := CustomMapCityBadges.error(out, base)
	if why != "": return failure(why)
	return finish(out, base, layout, cat)
