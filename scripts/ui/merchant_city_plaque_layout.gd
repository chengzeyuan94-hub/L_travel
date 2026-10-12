extends RefCounted
## One ground ownership rule for base and custom cities. Cached side choices survive pan.
const TAG := preload("res://scripts/ui/merchant_city_plaque.gd")
var board
var band := -1
var _key := ""
var _geometry_key := ""
var _choices: Dictionary = {}
var _band_choices: Dictionary = {}
var _fade: Dictionary = {}
var _last_tick_us := 0
var diagnostics: Dictionary = {}
var solve_count := 0
var _city_fit: Dictionary = {}
var _city_yaw := -0.44
var _game_screen: Control

func _init(owner) -> void:
	board = owner
	var parent: Node=board.get_parent()
	while parent != null:
		if parent.has_method("_lshu_push_hud_insets"):
			_game_screen=parent as Control;break
		parent=parent.get_parent()
	var constants: Dictionary = board.world.get_script().get_script_constant_map()
	_city_fit=constants.get("CITY_FIT",{})
	_city_yaw=float(constants.get("CITY_YAW",-0.44))

func create_tag(cid: String) -> Control:
	var tag := TAG.new()
	HudStyle.apply_heading(tag.get_node("Name"), TAG.INK, 15)
	board._plaque_layer.add_child(tag)
	board._plaques[cid] = tag
	return tag

func _band_for(z: float) -> int:
	var cuts := [0.485,0.675,0.90,1.25]
	if band < 0:
		var initial := 0
		while initial < cuts.size() and z > float(cuts[initial]): initial += 1
		return initial
	var b := band
	while b < 4 and z > float(cuts[b])+0.035: b += 1
	while b > 0 and z < float(cuts[b-1])-0.035: b -= 1
	return b

func offset_unit() -> float:
	# Use the whole viewport, never the dock-sensitive board width. Board input is local canvas px.
	var viewport_size: Vector2 = board.get_viewport().get_visible_rect().size
	var canvas_scale: Vector2 = board.get_global_transform_with_canvas().get_scale()
	return maxf(0.01, minf(viewport_size.x/1920.0, viewport_size.y/1080.0) / maxf(0.01,absf(canvas_scale.x)))

func manual_offset(cid: String, centre: Vector2) -> Vector2:
	for c: Dictionary in board.world.layout.cities:
		if str(c.id) == cid:
			return (centre-board._to_view(_ground(c))) / offset_unit()
	return Vector2.ZERO

func _unit() -> float: return clampf(board.size.x/1920.0,0.70,1.25)

func _font_floor() -> int:
	var scale: Vector2 = board.get_viewport().get_stretch_transform().get_scale() * board.get_global_transform_with_canvas().get_scale()
	return maxi(12,int(ceil(12.0/maxf(0.1,minf(absf(scale.x),absf(scale.y))))))

func _ground(c: Dictionary) -> Vector3:
	var holder: Node3D = board.world.city_nodes[str(c.id)].node
	var fit: Array = [0.0,0.0,0.0] if c.has("model") else _city_fit.get(str(c.id),[_city_yaw,0.0,0.0])
	return holder.global_position+Vector3(-float(fit[1]),0.02,-float(fit[2]))

func _geometry() -> String:
	var parts: Array = [board.size.round(), board._safe_rect(), _font_floor()]
	for c: Dictionary in board.world.layout.cities:
		if not board.world.city_nodes.has(str(c.id)): continue
		var holder: Node3D = board.world.city_nodes[str(c.id)].node
		parts.append([c.get("city_badge", {}),c.get("badge_asset", ""),c.id,_ground(c).snapped(Vector3.ONE*0.0001),holder.rotation.y,c.foot,c.get("model",""),GameState.content.get("cities",{}).get(str(c.id),{}).get("display_name",c.get("name",c.id))])
	return str(parts)

func _dynamic() -> String:
	var parts: Array = [band,board._selection,board._hud_top,board._hud_bottom,board._right_inset,board._piece_marks.size(),_hud_spots()]
	var legal: Array = board.legal_nodes.keys(); legal.sort();parts.append(legal)
	var ids: Array = board.tokens.keys();ids.sort()
	for pid in ids:
		var tok: Node3D = board.tokens[pid]
		parts.append([pid,tok.global_position.snapped(Vector3.ONE*0.35),tok.visible,board.shown.get(pid,{})])
	return str(parts)

func _foot(c: Dictionary) -> Rect2:
	var p0 := _ground(c)
	var rect := Rect2(board._to_view(p0),Vector2.ZERO)
	var radius := float(c.foot)*0.56
	for i in 20:
		var angle := TAU*float(i)/20.0
		rect = rect.expand(board._to_view(p0+Vector3(cos(angle)*radius,0,sin(angle)*radius)))
	return rect

func _transport_mode(modes: Array) -> String:
	if "LAND" in modes and "SEA" in modes: return "BOTH"
	if "LAND" in modes: return "LAND"
	if "SEA" in modes: return "SEA"
	return "UNKNOWN"

func _transport(cid: String) -> Dictionary:
	var layout_modes: Array = []
	for rid in board.paths.gates.get(cid,{}):
		var mode := str(board.paths.route_type(rid))
		if mode in ["LAND","SEA"] and mode not in layout_modes: layout_modes.append(mode)
	layout_modes.sort()
	var nodes: Dictionary = GameState.content.get("board_nodes",{})
	var cities: Dictionary = GameState.content.get("cities",{})
	# Fallback is only for content that has not loaded, never for a missing/invalid rule node.
	if nodes.is_empty():
		return {"transport_mode":_transport_mode(layout_modes),"transport_source":"layout_routes","node_id":"","node_allowed_routes":[],"is_transport_interchange":false,"layout_modes":layout_modes,"mismatch":false,"transport_issues":[]}
	var node_id := str(cities.get(cid,{}).get("board_node_id",""))
	var node: Dictionary = nodes.get(node_id,{})
	var allowed: Array = []
	var raw: Variant = node.get("allowed_routes",[])
	var issues: Array = []
	if raw is Array:
		for value in raw:
			var mode := str(value)
			if mode in ["LAND","SEA"] and mode not in allowed: allowed.append(mode)
			elif mode not in ["LAND","SEA"]: issues.append("invalid_allowed_route")
	else: issues.append("invalid_allowed_routes")
	allowed.sort()
	var mode := _transport_mode(allowed)
	var interchange := bool(node.get("is_transport_interchange",false))
	if node.is_empty(): issues.append("missing_rule_node")
	if mode == "UNKNOWN": issues.append("no_allowed_transport")
	if interchange != (mode == "BOTH"): issues.append("interchange_flag_mismatch")
	var mismatch := allowed != layout_modes
	if mismatch: issues.append("layout_routes_mismatch")
	return {"transport_mode":mode,"transport_source":"board_nodes","node_id":node_id,"node_allowed_routes":allowed,"is_transport_interchange":interchange,"layout_modes":layout_modes,"mismatch":mismatch,"transport_issues":issues}

func _records(u: float) -> Dictionary:
	var out := {}
	var content: Dictionary = GameState.content.get("cities",{})
	for c: Dictionary in board.world.layout.cities:
		var cid := str(c.id)
		if not board._plaques.has(cid) or not board.world.city_nodes.has(cid): continue
		var tag: Control = board._plaques[cid]
		var text := str(content.get(cid,{}).get("display_name",c.get("name",cid)))
		var label: Label = tag.get_node("Name")
		var font: Font = label.get_theme_font("font")
		var floor_px := _font_floor()
		var fs := maxi(floor_px,int(round(float([12,13,14,14,15][band])*maxf(1.0,u))))
		var text_width := font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,fs).x
		var measured := TAG.measured_size(text_width,fs,u)
		while measured.x > 184.0*u and fs > floor_px:
			fs -= 1
			text_width = font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,fs).x
			measured = TAG.measured_size(text_width,fs,u)
		# Keep the complete long name at >=12px; grow instead of silently truncating.
		tag.size = measured
		tag.pivot_offset = Vector2.ZERO;tag.scale = Vector2.ONE
		var transport := _transport(cid)
		var display: Dictionary = c.get("city_badge", {})
		var icon := str(display.get("icon", "AUTO"))
		var texture: Texture2D = CustomMapLocalAssets.texture(str(c.get("badge_asset", ""))) if icon == "IMAGE" else null
		tag.configure(text,fs,u,str(transport.transport_mode),icon,texture)
		var p0 := _ground(c)
		var p: Vector2 = board._to_view(p0)
		var behind: bool = board.world.camera.is_position_behind(p0)
		var foot := _foot(c)
		var body: Rect2 = board._city_building_screen_rect(cid)
		out[cid] = {"id":cid,"p":p,"ground":p0,"foot":foot,"body":body,"size":tag.size,"font_px":fs,"font_floor_px":floor_px,"text_width_px":text_width,"behind":behind,"display":display}
		out[cid].merge(transport)
	return out

func _box(a: Vector2,b: Vector2) -> Rect2: return Rect2(a,Vector2.ZERO).expand(b)

func _hud_spots() -> Array:
	var spots: Array=[]
	if _game_screen == null:return spots
	var hud=_game_screen.get("_lshu")
	if hud == null:return spots
	var inv: Transform2D=board.get_global_transform_with_canvas().affine_inverse()
	# Visible opponent chips, including the optional status bubble, have separate bounds.
	for chip: Dictionary in hud.get("_chips"):
		var root: Control=chip.root
		if not root.is_visible_in_tree():continue
		for child in root.get_children():
			if child is NinePatchRect and child.is_visible_in_tree():
				spots.append(inv * (child as Control).get_global_rect())
	var campfire: Control=hud.get("campfire")
	if campfire != null and campfire.is_visible_in_tree():spots.append(inv*campfire.get_global_rect())
	return spots

func _obstacles(u: float) -> Array:
	var spots: Array = _hud_spots()
	# Gate stands and coins are protected even before a player arrives.
	for cid in board.paths.gates:
		for rid in board.paths.gates[cid]:
			var g: Vector3 = board.paths.gates[cid][rid]
			spots.append(_box(board._to_view(g+Vector3(-0.38,0,0)),board._to_view(g+Vector3(0.38,1.12,0))).grow(2.0*u))
	for sid in board.paths.stop_pos:
		var p: Vector3 = board.paths.stop_pos[sid]
		spots.append(_box(board._to_view(p+Vector3(-0.50,0,-0.43)),board._to_view(p+Vector3(0.50,0,0.43))).grow(2.0*u))
	for pid in board.tokens:
		var tok = board.tokens[pid]
		if not tok.visible: continue
		var p: Vector2 = board._to_view(tok.global_position)
		var top: Vector2 = board._to_view(tok.global_position+Vector3(0,maxf(tok.camel_size,1.2),0))
		var half := maxf(9.0*u,absf(top.y-p.y)*0.55)
		spots.append(Rect2(Vector2(p.x-half,top.y),Vector2(half*2,maxf(8.0,p.y-top.y))).grow(3.0*u))
		if board._piece_marks.has(pid):
			for name in ["pin","role"]:
				var mark: Control = board._piece_marks[pid][name]
				if mark.visible: spots.append(mark.get_rect().grow(3.0*u))
	for m: Dictionary in board._markers.values():
		if m.has("disc") and (m.disc as Control).visible: spots.append((m.disc as Control).get_rect().grow(3.0*u))
	return spots

func _route_samples() -> PackedVector2Array:
	var samples := PackedVector2Array()
	for route: Dictionary in board.world.layout.routes:
		var points: Array = route.get("points",[])
		for i in range(0,points.size(),5):
			var p: Array = points[i]
			samples.append(board._to_view(Vector3(float(p[0]),float(p[1]),float(p[2]))))
	return samples

func _position(record: Dictionary,choice: Dictionary,u: float) -> Vector2:
	if record.get("display", {}).get("mode", "AUTO") == "MANUAL":
		var offset: Array = record.display.get("offset_px", [0,0])
		return record.p + Vector2(float(offset[0]),float(offset[1]))*offset_unit() - Vector2(record.size)*0.5
	if choice.has("hud_path"):
		var obstacle: Control=board.get_node_or_null(NodePath(str(choice.hud_path)))
		if obstacle != null and obstacle.is_visible_in_tree():
			var inv: Transform2D=board.get_global_transform_with_canvas().affine_inverse()
			var h: Rect2=inv*obstacle.get_global_rect()
			var p: Vector2=record.p
			var sz: Vector2=record.size
			var hud_slide := float(choice.get("slide",0))*u
			match str(choice.side):
				"right":return Vector2(h.end.x+8.0*u,p.y-sz.y*0.5+hud_slide)
				"left":return Vector2(h.position.x-8.0*u-sz.x,p.y-sz.y*0.5+hud_slide)
				"bottom":return Vector2(p.x-sz.x*0.5+hud_slide,h.end.y+8.0*u)
				_:return Vector2(p.x-sz.x*0.5+hud_slide,h.position.y-8.0*u-sz.y)
	var foot: Rect2 = record.foot
	var body: Rect2 = record.body
	var extent := foot.merge(body) if body.size != Vector2.ZERO else foot
	var sz: Vector2 = record.size
	var p: Vector2 = record.p
	var gap := 6.0*u
	var slide := float(choice.get("slide",0))*u
	var extra := float(choice.get("extra",0))*u
	match str(choice.side):
		"bottom": return Vector2(p.x-sz.x*0.5+slide,foot.end.y+gap+extra)
		"right": return Vector2(extent.end.x+gap+extra,p.y-sz.y*0.5+slide)
		"left": return Vector2(extent.position.x-gap-extra-sz.x,p.y-sz.y*0.5+slide)
		_: return Vector2(p.x-sz.x*0.5+slide,extent.position.y-gap-extra-sz.y)

func _fit_position(raw: Vector2,sz: Vector2,safe: Rect2) -> Vector2:
	return Vector2(clampf(raw.x,safe.position.x,maxf(safe.position.x,safe.end.x-sz.x)),clampf(raw.y,safe.position.y,maxf(safe.position.y,safe.end.y-sz.y)))

func _hud_options(record: Dictionary,u: float) -> Array:
	var options: Array=[]
	var fallback: Array=[]
	if _game_screen == null:return options
	var hud=_game_screen.get("_lshu")
	if hud == null:return options
	var inv: Transform2D=board.get_global_transform_with_canvas().affine_inverse()
	for chip: Dictionary in hud.get("_chips"):
		var root: Control=chip.root
		if not root.is_visible_in_tree():continue
		for child in root.get_children():
			if not child is NinePatchRect or not child.is_visible_in_tree():continue
			var h: Rect2=inv*(child as Control).get_global_rect()
			if not h.intersects((record.foot as Rect2).merge(record.body).grow(24.0*u)):continue
			for side in ["right","left","bottom","top"]:
				options.append({"side":side,"hud_path":str(child.get_path()),"slide":0.0,"extra":0.0})
				for slide in [-12.0,12.0,-24.0,24.0]:
					fallback.append({"side":side,"hud_path":str(child.get_path()),"slide":slide,"extra":0.0,"fallback":true})
	# Keep every original HUD placement before any along-edge fallback slide.
	options.append_array(fallback)
	return options

func _area(a: Rect2,b: Rect2) -> float:
	if not a.intersects(b): return 0.0
	return a.intersection(b).get_area()

func _score(rect: Rect2,record: Dictionary,records: Dictionary,spots: Array,placed: Array,roads: PackedVector2Array,safe: Rect2,u: float) -> Vector2:
	var hard := maxf(0.0,rect.get_area()-rect.intersection(safe).get_area())
	var grown := rect.grow(2.0*u)
	for cid in records:
		var body: Rect2 = records[cid].body
		if body.size != Vector2.ZERO: hard += _area(grown,body.grow(1.0*u))
	for spot: Rect2 in spots: hard += _area(grown,spot)
	for taken: Rect2 in placed: hard += _area(rect.grow(4.0*u),taken)
	var soft := 0.0
	for p: Vector2 in roads:
		if grown.has_point(p): soft += 1.0
	return Vector2(hard,soft)

func _options() -> Array:
	var options: Array = []
	for side in ["bottom","right","left","top"]: options.append({"side":side,"slide":0.0,"extra":0.0})
	for slide in [-12.0,12.0,-24.0,24.0]: options.append({"side":"bottom","slide":slide,"extra":0.0})
	for extra in [12.0,24.0,36.0,48.0]:
		for side in ["bottom","right","left","top"]:
			for slide in [0.0,-24.0,24.0]:options.append({"side":side,"slide":slide,"extra":extra})
	# The larger D badge can need a finer side slide or one additional gap step.
	# Keep every original candidate first; these are used only when none is clear.
	for side in ["right","left","top"]:
		for slide in [-12.0,12.0]:options.append({"side":side,"slide":slide,"extra":0.0,"fallback":true})
	for extra in [60.0,72.0]:
		for side in ["bottom","right","left","top"]:
			for slide in [0.0,-12.0,12.0,-24.0,24.0]:options.append({"side":side,"slide":slide,"extra":extra,"fallback":true})
	return options

func _eligible(record: Dictionary, safe: Rect2) -> bool:
	# A city whose ground footprint is outside the map area belongs offscreen,
	# including the area covered by the fixed HUD. Do not drag its name into view.
	return not record.behind and (record.foot as Rect2).intersects(safe)

func _solve(records: Dictionary,spots: Array,roads: PackedVector2Array,safe: Rect2,u: float) -> void:
	solve_count += 1
	var ids: Array = records.keys();ids.sort()
	var occupied := {}
	for row: Dictionary in board.shown.values(): occupied[str(row.get("node",""))] = true
	# Stable tie order; priority changes do not evict an already clear cached position.
	ids.sort_custom(func(a,b):
		var ap := 2 if board.legal_nodes.has(a) else (1 if occupied.has(a) else 0)
		var bp := 2 if board.legal_nodes.has(b) else (1 if occupied.has(b) else 0)
		return ap > bp if ap != bp else str(a)<str(b))
	var previous: Dictionary = _band_choices.get(band,_choices).duplicate(true)
	var result := {}
	var placed: Array = []
	for cid in ids:
		var record: Dictionary = records[cid]
		if not _eligible(record,safe): continue
		var best := {}
		var best_cost := INF
		if previous.has(cid):
			var old: Dictionary = previous[cid]
			var old_rect := Rect2(_fit_position(_position(record,old,u),record.size,safe),record.size)
			var cost := _score(old_rect,record,records,spots,placed,roads,safe,u)
			if cost.x < 0.01: best = old
		if best.is_empty():
			var options := _options()
			var fallback := options.filter(func(option): return bool(option.get("fallback",false)))
			options = options.filter(func(option): return not bool(option.get("fallback",false)))
			options.append_array(_hud_options(record,u));options.append_array(fallback)
			# A newly obstructed cached position may still have room on the same side.
			# Preserve that ownership side before considering a clear opposite side.
			if previous.has(cid):
				var cached_side := str(previous[cid].side)
				var original_same_side_clear := false
				for index in options.size():
					var choice: Dictionary = options[index]
					if bool(choice.get("fallback",false)) and original_same_side_clear: break
					if str(choice.side) != cached_side: continue
					var raw := _position(record,choice,u)
					var rect := Rect2(_fit_position(raw,record.size,safe),record.size)
					var score := _score(rect,record,records,spots,placed,roads,safe,u)
					if score.x>=0.01: continue
					if not bool(choice.get("fallback",false)): original_same_side_clear=true
					var total := score.x*10000.0+float(index)*4.0+minf(score.y,30.0)*0.4+rect.position.distance_to(raw)*4.0
					if total < best_cost: best_cost=total;best=choice
			if best.is_empty():
				var original_clear := false
				for index in options.size():
					var choice: Dictionary = options[index]
					if bool(choice.get("fallback",false)) and original_clear: break
					var raw := _position(record,choice,u)
					var rect := Rect2(_fit_position(raw,record.size,safe),record.size)
					var score := _score(rect,record,records,spots,placed,roads,safe,u)
					if not bool(choice.get("fallback",false)) and score.x<0.01: original_clear=true
					var total := score.x*10000.0+float(index)*4.0+minf(score.y,30.0)*0.4+rect.position.distance_to(raw)*4.0
					if total < best_cost: best_cost=total;best=choice
					if index==0 and score.x<0.01 and score.y<8.0: break
		result[cid]=best
		placed.append(Rect2(_fit_position(_position(record,best,u),record.size,safe),record.size))
	_choices=result
	_band_choices[band]=result.duplicate(true)

func update() -> void:
	if board.world==null or board.world.camera==null or board._plaque_layer==null: return
	if board._plaques.is_empty(): return
	var u := _unit()
	var safe: Rect2 = board._safe_rect().grow(-8.0*u)
	# Workshop ready can run before its board has a positive canvas/safe area.
	if safe.size.x <= 0.0 or safe.size.y <= 0.0:
		for tag: Control in board._plaques.values(): tag.visible=false
		return
	var next_band := _band_for(board._zoom)
	var geometry := _geometry()
	if geometry != _geometry_key:
		_geometry_key=geometry;_band_choices.clear();_choices.clear();_key=""
	band=next_band
	var records := _records(u)
	var spots := _obstacles(u)
	var on_screen: Array = []
	for cid in records:
		if _eligible(records[cid],safe):on_screen.append(cid)
	on_screen.sort()
	var edges: Array = []
	for cid in on_screen:
		if _choices.has(cid):
			var r := Rect2(_position(records[cid],_choices[cid],u),records[cid].size)
			if r.intersection(safe).get_area()<r.get_area()-0.5:edges.append(cid)
	var conflicts: Array=[]
	var placed: Array=[]
	for cid in on_screen:
		if not _choices.has(cid):continue
		var rect := Rect2(_fit_position(_position(records[cid],_choices[cid],u),records[cid].size,safe),records[cid].size)
		var cost := _score(rect,records[cid],records,spots,placed,PackedVector2Array(),safe,u)
		if cost.x>0.5:conflicts.append(cid)
		placed.append(rect)
	var key := geometry+"|"+_dynamic()+"|"+str(on_screen)+"|"+str(edges)+"|"+str(conflicts)
	if key != _key:
		_solve(records,spots,_route_samples(),safe,u);_key=key
	for cid in on_screen:
		if records[cid].display.get("mode", "AUTO") == "MANUAL": _choices[cid] = {"side":"bottom", "manual":true}
	var now := Time.get_ticks_usec()
	var elapsed := minf(0.05,float(now-_last_tick_us)/1000000.0) if _last_tick_us>0 else 0.05
	_last_tick_us=now
	var warnings: Array = []
	var visible: Array = []
	var hidden: Array = []
	for cid in records:
		var tag: Control = board._plaques[cid]
		var record: Dictionary = records[cid]
		for issue in record.transport_issues:
			warnings.append({"kind":"transport_data","city":cid,"issue":issue,"source":record.transport_source,"node_allowed_routes":record.node_allowed_routes,"layout_modes":record.layout_modes})
		if not _choices.has(cid):
			tag.visible=false;_fade[cid]=0.0
			hidden.append({"id":cid,"reason":"ground footprint outside visible map area","anchor_px":record.p,"foot":record.foot})
			continue
		var choice: Dictionary = _choices[cid]
		var raw := _position(record,choice,u)
		# Edge-only sliding does not change the ownership side or re-solve while panning.
		var target := _fit_position(raw,tag.size,safe)
		tag.position=target
		var editor_selection: Variant = board.get("sel") if board.has_method("cancel_badge_drag") else null
		var selected_city: String = str(editor_selection.get("id", "")) if editor_selection is Dictionary and editor_selection.get("kind", "") == "city" else board._target_id
		tag.set_highlight(cid == board._glow_city,cid == selected_city)
		tag.visible=true
		_fade[cid]=minf(1.0,float(_fade.get(cid,0.0))+elapsed/0.12)
		tag.modulate.a=float(_fade[cid])
		var anchor: Vector2 = record.p
		var local_anchor := anchor-tag.position
		var edge_point := Vector2(clampf(anchor.x,target.x,target.x+tag.size.x),clampf(anchor.y,target.y,target.y+tag.size.y))
		var leader := bool(choice.get("manual",false)) or choice.has("hud_path") or float(choice.get("extra",0))>0.0 or absf(float(choice.get("slide",0)))>0.0 or not target.is_equal_approx(raw)
		tag.point_to(local_anchor,str(choice.side),leader)
		var rect := Rect2(tag.position,tag.size)
		for taken: Dictionary in visible:
			if rect.intersects(taken.rect):warnings.append({"kind":"tag_overlap","a":cid,"b":taken.id})
		var cost := _score(rect,record,records,spots,[],PackedVector2Array(),safe,u)
		if cost.x>0.5:warnings.append({"kind":"protected_overlap","city":cid,"area":cost.x})
		var row := {"id":cid,"rect":rect,"requested_rect":Rect2(raw,tag.size),"rendered_centre_delta_px":rect.get_center()-anchor,"side":choice.side,"font_px":record.font_px,"font_floor_px":record.font_floor_px,"text_width_px":record.text_width_px,"ground":record.ground,"anchor_px":anchor,"foot":record.foot,"building":record.body,"body_gap_px":raw.y-(record.foot as Rect2).end.y if choice.side=="bottom" else -1.0,"leader_px":edge_point.distance_to(anchor) if leader else 0.0,"badge_rect":Rect2(tag.position+tag.get_badge_rect().position,tag.get_badge_rect().size),"body_rect":Rect2(tag.position+tag.get_text_body_rect().position,tag.get_text_body_rect().size),"text_rect":Rect2(tag.position+tag.get_text_rect().position,tag.get_text_rect().size),"icon_rects_local":tag.get_icon_rects(),"display":record.display,"offset_unit":offset_unit(),"clamped":not raw.is_equal_approx(target),"hovered":tag.highlighted,"selected":tag.selected}
		for field in ["transport_mode","transport_source","node_id","node_allowed_routes","is_transport_interchange","layout_modes","mismatch","transport_issues"]: row[field]=record[field]
		visible.append(row)
	diagnostics={"band":band,"solve_count":solve_count,"unit":u,"cities":visible,"warnings":warnings,"hidden":hidden,"safe_rect":safe,"canvas_scale":board.get_global_transform().get_scale(),"cached_sides":_choices.duplicate(true),"font_min_px":_font_floor(),"source":"ground projection; automatic collision layout or saved 1920-unit manual centre offsets; screen clamp never persisted"}

func screen_rect(cid: String) -> Rect2:
	var tag: Control = board._plaques.get(cid)
	if tag==null or not tag.visible:return Rect2()
	return Rect2(tag.position,tag.size).grow(4.0*_unit())
