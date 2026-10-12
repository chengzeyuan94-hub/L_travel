extends "res://tools/merchant_board_claude_play.gd"
## Dedicated coordinator: real merchant scene/3D board and formal SetupSystem, with no fallback map.
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
var expected_sha := ""
var token := ""
var overlay: Dictionary = {}
var _closing := false
var _status: Dictionary = {}
var _return_button: Button
var _layer: CanvasLayer
var _loading_layer: CanvasLayer
var _startup_started := Time.get_ticks_msec()
var _startup_timings: Array = []
var _return_confirm: ConfirmationDialog
var _focus_poll := 0.0

func _ready() -> void:
	# Resolve before map assets, progress and status files are accessed. The
	# argument is authoritative; it does not rely on a parent process environment.
	var child_dir := preload("res://scripts/lshu_ui/lshu_progress.gd").playtest_dir(OS.get_cmdline_user_args())
	if not child_dir.is_empty(): OS.set_environment("SILKROAD_DATA_DIR", child_dir)
	get_tree().set_auto_accept_quit(false)
	var map_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--workshop-sha="): expected_sha = a.trim_prefix("--workshop-sha=")
		elif a.begins_with("--workshop-token="): token = a.trim_prefix("--workshop-token=")
		elif a.begins_with("--custom-map="): map_path = a.trim_prefix("--custom-map=")
	if expected_sha.is_empty() or token.is_empty() or not FileAccess.file_exists(map_path):
		_fail("试玩地图副本缺失。"); return
	_fit_window()
	_show_loading()
	_mark_startup("validate_map")
	var parsed := CustomMapValidator.parse_text(FileAccess.get_file_as_string(map_path))
	if not (parsed.get("errors", []) as Array).is_empty(): _fail("试玩地图无法读取。"); return
	overlay = parsed.doc
	var remembered := CustomMapLoader.remember(overlay)
	if not bool(remembered.get("ok", false)) or str(remembered.get("sha256", "")) != expected_sha:
		_fail("试玩地图校验失败，或与安装版本不一致。"); return
	_mark_startup("load_scene")
	# Paint the waiting card before synchronous scene/model construction.
	await get_tree().process_frame
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw
	if _closing or not is_inside_tree(): return
	super() # Builds the exact official main scene, GameScreen and 3D board.


func _show_loading() -> void:
	_loading_layer = CanvasLayer.new(); _loading_layer.layer = 1000; add_child(_loading_layer)
	var background := ColorRect.new(); background.color = Kit.CREAM_DEEP
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); _loading_layer.add_child(background)
	var center := CenterContainer.new(); center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); _loading_layer.add_child(center)
	var panel := PanelContainer.new(); panel.add_theme_stylebox_override("panel", Kit.satchel_box(24, 3, 32)); center.add_child(panel)
	var box := VBoxContainer.new(); box.custom_minimum_size.x = 720; box.add_theme_constant_override("separation", 22); panel.add_child(box)
	box.add_child(Kit.label("正在准备试玩地图…", 30, Kit.SATCHEL_DEEP, "body", 700))
	var message := Kit.label("正在加载地图、模型和棋子。较大地图可能需要约 1 分钟。\n工坊窗口显示准备阶段和已等待秒数；可在那里随时返回。", 24, Kit.INK, "body", 500)
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; box.add_child(message)


func _mark_startup(phase: String, extra: Dictionary = {}) -> void:
	_startup_timings.append({"phase": phase, "ms": Time.get_ticks_msec() - _startup_started, "extra": extra})
	_write_status({"state": "starting", "phase": phase, "sha256": expected_sha})

func _fit_window() -> void:
	var win := get_window()
	if DisplayServer.get_name() == "headless": return
	var usable := DisplayServer.screen_get_usable_rect(win.current_screen)
	win.size = Vector2i(mini(1920, int(usable.size.x*0.92)), mini(1080, int(usable.size.y*0.92)))
	win.position = usable.position + (usable.size-win.size)/2
	win.grab_focus()

func _start(configs: Array, seed: int) -> void:
	# Same formal Session setup as the merchant entry. Only this coordinator supplies a strict map option.
	GameState.reset_session()
	var initial_board: Node = _screen.get_node("%BoardView")
	_mark_startup("prepare_rules", {"initial_world_ms": initial_board.get("world").get("build_ms")})
	var options := CustomMapLoader.option_for(expected_sha)
	var result := SetupSystem.prepare_new_game(GameData.load_ruleset(GameData.FORMAL_RULESET_DIR), configs, seed, "FORMAL", options)
	if bool(result.get("success", false)): result = SetupSystem.finalize_new_game()
	if not bool(result.get("success", false)): _fail(str(result.get("message", "正式对局准备失败。"))); return
	if str(GameState.content.get("custom_map", {}).get("sha256", "")) != expected_sha:
		_fail("正式对局加载了不同的地图。"); return
	_main.call("_show_only", _screen)
	var board: Node = _screen.get_node("%BoardView")
	_mark_startup("build_world")
	await board.call("prepare_map_world")
	if _closing or not is_inside_tree(): return
	_mark_startup("prepare_hud", {"world_rebuild_ms": board.get("last_rebuild_ms"), "world_ms": board.get("world").get("build_ms")})
	_screen.on_game_started(configs)
	if str(GameState.content.get("custom_map", {}).get("sha256", "")) != expected_sha: _fail("试玩签名变了。"); return
	_build_return_bar()
	if is_instance_valid(_loading_layer): _loading_layer.queue_free()
	await get_tree().process_frame
	if _closing or not is_inside_tree(): return
	_startup_timings.append({"phase": "ready", "ms": Time.get_ticks_msec() - _startup_started})
	var badge_views := {}
	for city: Dictionary in board.get("world").layout.cities:
		var cid := str(city.id)
		var tag: Control = board.get("_plaques").get(cid)
		badge_views[cid] = {"name":GameState.content.cities.get(cid,{}).get("display_name",cid),"layout_name":city.get("name",cid),"display":city.get("city_badge",{}),"asset":city.get("badge_asset",""),"display_icon":tag.get("display_icon") if tag != null and tag.has_method("configure") else "","true_transport_mode":board.get("_city_plaque_runtime")._transport(cid).transport_mode if board.get("_city_plaque_runtime") != null else "UNKNOWN","image_texture":tag.get("custom_texture").resource_path if tag != null and tag.has_method("configure") and tag.get("custom_texture") != null else "","true_d_control":tag != null and tag.has_method("configure"),"label":tag.get_node("Name").text if tag != null else ""}
	_write_status({"city_badges":badge_views,"badge_layout":board.get("_city_plaque_runtime").diagnostics if board.get("_city_plaque_runtime") != null else {},"state": "ready", "sha256": expected_sha, "name": str(GameState.content.custom_map.name), "session_mode": GameState.session_mode, "players": GameState.players.size(), "counts_win": bool(GameState.content.custom_map.get("counts_win", false)), "records_progress": bool(_screen.call("_lshu_records_progress"))})
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--workshop-test-return-after="):
			get_tree().create_timer(float(a.trim_prefix("--workshop-test-return-after="))).timeout.connect(_return)
		elif a.begins_with("--workshop-test-gui-return-after="):
			get_tree().create_timer(float(a.trim_prefix("--workshop-test-gui-return-after="))).timeout.connect(_test_gui_return)
		elif a == "--workshop-test-name-contract":
			await _test_name_contract()
		elif a == "--workshop-test-escape":
			await _test_escape_chain()
		elif a == "--workshop-test-city-intro":
			await _test_city_intro()
		elif a == "--workshop-test-catalogue-trade":
			await _test_catalogue_trade()
		elif a == "--workshop-test-ai":
			# Focused lifecycle test, using the real GameScreen's AI dispatcher.
			_screen.get("_ai").step_delay = 30.0
			GameState.current_player_index = 1
			_screen.call("_maybe_start_ai")
			var updated := _status.duplicate(true); updated["ai_running"] = _screen.get("_ai").is_running(); _write_status(updated)
	if DisplayServer.get_name() != "headless":
		await get_tree().create_timer(2.0).timeout
		if not _closing and is_inside_tree():
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(OS.get_environment("SILKROAD_DATA_DIR").path_join("playtest.png"))

func _build_return_bar() -> void:
	_layer = CanvasLayer.new(); _layer.layer = 120; add_child(_layer)
	var bar := HBoxContainer.new(); bar.position = Vector2(16, 130); _layer.add_child(bar)
	bar.add_theme_constant_override("separation", 16)
	var name_label := Kit.label("试玩 · " + str(overlay.name), 18, Kit.INK)
	var box := PanelContainer.new(); box.add_theme_stylebox_override("panel", Kit.pill_box(12, 3)); box.add_child(name_label); bar.add_child(box)
	var button := Kit.button("返回地图工坊", "cream", 42, 18); button.name = "ReturnToWorkshopButton"; _return_button = button; button.pressed.connect(_ask_return); bar.add_child(button)
	_return_confirm = ConfirmationDialog.new(); _return_confirm.title="返回地图工坊？"
	_return_confirm.dialog_text="结束这次试玩，回到原来的地图继续编辑。"
	_return_confirm.ok_button_text="结束试玩"; _return_confirm.cancel_button_text="继续试玩"
	_return_confirm.confirmed.connect(_return); add_child(_return_confirm)

func _write_status(value: Dictionary) -> void:
	_status = value.duplicate(true); _status["token"] = token
	_status["startup_timings"] = _startup_timings.duplicate(true)
	if str(value.get("state", "")) == "ready" and is_instance_valid(_screen):
		# Observe actual formal content and instantiated city holders, not overlay fields.
		var actual_world: Node = _screen.get_node("%BoardView").get("world")
		var city_rows := []
		for cid in GameState.content.custom_map.get("new_city_ids", []):
			var entry: Dictionary = actual_world.get("city_nodes").get(cid, {})
			if entry.is_empty(): continue
			var holder: Node3D = entry.node
			var acc: Array = [null]
			actual_world.node_aabb(holder, Transform3D.IDENTITY, acc)
			var bounds: AABB = acc[0] if acc[0] != null else AABB()
			city_rows.append({"id": cid, "model": entry.model, "model_sha256": FileAccess.get_sha256(entry.model), "position": [holder.position.x, holder.position.y, holder.position.z], "rotation_y": holder.rotation.y, "scale": [holder.scale.x, holder.scale.y, holder.scale.z], "mesh_bounds": {"position": [bounds.position.x, bounds.position.y, bounds.position.z], "size": [bounds.size.x, bounds.size.y, bounds.size.z]}, "building_only": entry.building_only})
		var goods_rows := []
		var icons := preload("res://scripts/lshu_ui/lshu_icons.gd")
		for gid in GameState.content.custom_map.get("new_good_ids", []):
			var texture: Texture2D = icons.good(gid, GameState.content)
			var path := texture.resource_path if texture != null else ""
			var inventory := {}
			for player in GameState.players: inventory[player.player_id] = player.held_count(gid)
			goods_rows.append({"id": gid, "name": GameData.get_good_name(GameState.content, gid), "sprite_lookup": GameData.get_good_sprite_path(GameState.content, gid), "texture_path": path, "texture_sha256": FileAccess.get_sha256(path) if path != "" else "", "supply_total": GameState.content.goods[gid].supply_total, "actual_goods_supply": GameState.goods_supply.get(gid, -1), "player_inventory": inventory})
		_status["catalogue_city_instances"] = city_rows
		_status["catalogue_goods_bindings"] = goods_rows
	if str(value.get("state", "")) == "ready" and overlay.has("plants") and is_instance_valid(_screen):
		var actual_board: Node = _screen.get_node("%BoardView")
		var actual_world: Node = actual_board.get("world")
		var actual_layout: Dictionary = actual_world.get("layout")
		_status["plants_layout_sha256"] = CustomMapSchema.sha256({"tree_kit": actual_layout.get("tree_kit", [])})
		_status["plant_ids"] = actual_layout.get("plant_ids", [])
		var mismatches := 0
		var count := 0
		var entries: Dictionary = actual_world.get("decor_index").get("tree_kit", {})
		var hidden: Dictionary = actual_world.get("decor_hidden").get("tree_kit", {})
		for index in entries:
			for e: Array in entries[index]:
				var expected: Transform3D = actual_world.hidden_transform(e[2]) if hidden.has(index) else e[2]
				var actual: Transform3D = (e[0] as MultiMesh).get_instance_transform(int(e[1]))
				count += 1
				if not actual.is_equal_approx(expected): mismatches += 1
		_status["plant_render_instances"] = count
		_status["plant_render_mismatches"] = mismatches
	if is_instance_valid(_screen) and GameState.content.has("piece_skins"):
		var skin_rows:Array=[];var skin_board:Node=_screen.get_node("%BoardView")
		for pid in skin_board.tokens:
			var tok:Node=skin_board.tokens[pid]
			for transport in tok._custom_skins:
				var root:Node=tok._custom_skins[transport];var meshes:=_skin_mesh_count(root);var clips:Array=[]
				for player:AnimationPlayer in CustomMapActorAssets.animation_players(root):clips.append({"available":Array(player.get_animation_list()),"current":player.current_animation,"playing":player.is_playing()})
				var asset:String=tok._skin_specs[transport].asset
				skin_rows.append({"player_id":pid,"transport":transport,"asset":asset,"fingerprint":FileAccess.get_sha256(CustomMapLocalAssets.path(asset)),"mesh_instances":meshes,"clips":clips,"visible":root.is_visible_in_tree()})
		_status["piece_skin_views"]=skin_rows
	var path := OS.get_environment("SILKROAD_DATA_DIR").path_join("status.json")
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null: return
	f.store_string(JSON.stringify(_status)); f.close()
	DirAccess.rename_absolute(path + ".tmp", path)
	print("WORKSHOP_PLAYTEST ", JSON.stringify(_status))

func _fail(message: String) -> void:
	_write_status({"state": "failed", "message": message}); _closing = true
	get_tree().quit.call_deferred(2)

func _return() -> void:
	if _closing: return
	_closing = true
	var was_running := false
	var ai: Node = _screen.get("_ai") if is_instance_valid(_screen) else null
	if is_instance_valid(ai):
		was_running = bool(ai.is_running()); _screen.cancel_ai()
	var value := _status.duplicate(true); value["state"] = "returned"; value["ai_was_running"] = was_running
	value["ai_cancelled"] = not is_instance_valid(ai) or not bool(ai.is_running())
	value["ai_timer_stopped"] = not is_instance_valid(ai) or bool(ai.get("_timer").is_stopped())
	_write_status(value)
	get_tree().quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST: _return()
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if _close_top_overlay(): return
		_ask_return()

func _ask_return() -> void:
	if is_instance_valid(_return_confirm): _return_confirm.popup_centered(Vector2i(480,180))

func _close_top_overlay() -> bool:
	# CityLoreCard has a real _unhandled_input close path; this fallback also respects it.
	if not is_instance_valid(_screen): return false
	for name in ["CityLoreCard", "EventDrawOverlay", "ResultOverlay"]:
		var node: Node = _screen.get_node_or_null("%"+name)
		if not node is Control or not node.is_visible_in_tree(): continue
		if node.has_method("close"): node.close(); return true
		if name == "EventDrawOverlay": node._on_continue_pressed(); return true
		if name == "ResultOverlay": node.hide(); return true
		# Pending event/results carry gameplay choices; keep them open, never exit beneath them.
		return true
	return false

func _process(delta: float) -> void:
	_focus_poll += delta
	if _focus_poll < 0.2 or _closing: return
	_focus_poll = 0.0
	var path := OS.get_environment("SILKROAD_DATA_DIR").path_join("foreground.json")
	if not FileAccess.file_exists(path): return
	var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	DirAccess.remove_absolute(path)
	if request is Dictionary and str(request.get("token","")) == token and str(request.get("sha256","")) == expected_sha and str(_status.get("state","")) == "ready" and DisplayServer.get_name() != "headless": get_window().grab_focus()
func _exit_tree() -> void:
	_closing = true
	# Children may already be outside the tree: stop the timer without snapping detached tokens.
	if is_instance_valid(_screen):
		var ai: Node = _screen.get("_ai")
		if is_instance_valid(ai):
			ai.board_view = null; ai.event_presenter = null; ai.cancel()

func _test_gui_return() -> void:
	if _closing or not is_instance_valid(_return_button): return
	var at := _return_button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new(); motion.position = at; motion.global_position = at
	get_viewport().push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new(); event.button_index = MOUSE_BUTTON_LEFT
		event.position = at; event.global_position = at; event.pressed = pressed
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		get_viewport().push_input(event, true)
		await get_tree().process_frame

# Isolated visual adapter: stage a real generated card in the actual formal trade UI.
# Normal trial/game sessions never enter this branch; no card amounts or rules change.
func _test_catalogue_trade() -> void:
	_screen.auto_advance = false
	GameState.current_player_index = 0
	var player: PlayerState = GameState.current_player()
	var observations := []
	for cid in GameState.content.custom_map.new_city_ids:
		var own: String = GameState.content.city_cards[cid].starting_grant.entries[0].resource_id
		var did: String = GameState.content.cities[cid].trade_color_id
		var selected: Dictionary = {}
		for card: Dictionary in GameState.content.trade_decks[did].cards.values():
			if card.entries.any(func(e: Dictionary) -> bool: return e.resource_id == own): selected = card; break
		if selected.is_empty(): continue
		player.current_node_id = cid
		player.trade_action_used = false
		player.active_transport = GameData.Transport.SHIP if GameState.content.cities[cid].starting_transport == "SHIP" else GameData.Transport.CAMEL
		if player.held_count(own) == 0 and int(GameState.goods_supply[own]) >= 1:
			player.add_good(own, 1); GameState.goods_supply[own] -= 1
		GameState.city_market_states[cid]["current_trade_card_id"] = selected.id
		GameState.phase = GameState.Phase.TRADE
		GameState.state_changed.emit()
		for i in 60: await get_tree().process_frame
		var hud: Control = _screen.get("_lshu")
		var paths := []
		_collect_visible_textures(hud, paths)
		var file := OS.get_environment("SILKROAD_DATA_DIR").path_join("formal-trade-" + str(cid) + ".png")
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png(file)
		observations.append({"city_id": cid, "own_good": own, "actual_card": TradeSystem.get_current_trade_card(), "ui_cached_card": _screen.get("_cached_trade_card"), "market_mode": hud.get("market_mode"), "market_visible": hud.get("market").is_visible_in_tree(), "actual_visible_texture_paths": paths, "png": file, "png_error": error, "fixture": "test-only teleport/phase/current card selection from actual generated deck; no amounts or price calculation modified"})
	var value := _status.duplicate(true); value["catalogue_formal_trade_views"] = observations; _write_status(value)

func _collect_visible_textures(node: Node, paths: Array) -> void:
	if node is TextureRect and node.is_visible_in_tree() and node.texture != null:
		var path: String = node.texture.resource_path
		if path != "" and not paths.has(path): paths.append(path)
	for child in node.get_children(): _collect_visible_textures(child, paths)

func _test_city_intro() -> void:
	var views:Array=[]
	var lore:Control=_screen.get_node("%CityLoreCard")
	for cid in GameState.content.get("city_intro_cards",{}):
		lore.force_close();_screen.call("_on_city_inspect_requested",cid)
		for i in 45:await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var card:FormalCityCard=lore.get("_formal_card")
		var path:=OS.get_environment("SILKROAD_DATA_DIR").path_join("formal-intro-"+str(cid)+".png")
		var png_error:=get_viewport().get_texture().get_image().save_png(path)
		views.append({"city_id":cid,"bound_city_id":card.bound_city_id(),"visible":lore.visible and card._panel.is_visible_in_tree() and card._user_intro_active,"title":card._title.text,"description":card.user_description_text(),"texture_path":card._art.texture.resource_path if card._art.texture!=null else "","png":path,"png_error":png_error})
	lore.force_close();var updated:=_status.duplicate(true);updated["city_intro_views"]=views;_write_status(updated)

func _skin_mesh_count(node:Node)->int:
	var count:=1 if node is MeshInstance3D else 0
	for child in node.get_children():count+=_skin_mesh_count(child)
	return count

func _test_escape_chain() -> void:
	var lore: Control = _screen.get_node("%CityLoreCard")
	_screen.call("_on_city_inspect_requested", "cairo")
	await get_tree().create_timer(0.35).timeout
	var opened: bool = lore.is_open()
	var escape := InputEventKey.new(); escape.keycode=KEY_ESCAPE; escape.pressed=true
	get_viewport().push_input(escape,true)
	await get_tree().create_timer(0.35).timeout
	var first_closed: bool = not lore.is_open() and not _return_confirm.visible and not _closing
	get_viewport().push_input(escape,true)
	for i in 3: await get_tree().process_frame
	var second_confirm := _return_confirm.visible and not _closing
	_return_confirm.hide()
	var value := _status.duplicate(true)
	value["escape_chain"]={"actual_lore_opened":opened,"first_closed_only_lore":first_closed,"second_return_confirmation":second_confirm,"cancel_keeps_trial":not _closing}
	_write_status(value)

func _test_name_contract() -> void:
	var rows: Array = []
	var board: Node = _screen.get_node("%BoardView")
	var lore: Control = _screen.get_node("%CityLoreCard")
	for cid in overlay.get("city_badges",{}):
		if not overlay.city_badges[cid].has("name"): continue
		lore.force_close(); _screen.call("_on_city_inspect_requested",cid)
		for i in 30: await get_tree().process_frame
		var tag: Control = board.get("_plaques").get(cid)
		var card: Control = lore.get("_formal_card")
		rows.append({"city_id":cid,"expected_name":overlay.city_badges[cid].name,"game_data_name":GameData.get_city_name(GameState.content,cid),"plaque_name":tag.get_node("Name").text,"actual_city_card_title":card.get("_title").text,"actual_city_card_id":card.bound_city_id()})
	lore.force_close()
	var base := CustomMapLoader.base_content()
	var unchanged := true
	for deck_id in base.trade_decks:
		if GameState.content.trade_decks.get(deck_id,{}) != base.trade_decks[deck_id]: unchanged=false
	var value := _status.duplicate(true); value["authoritative_names"]=rows
	value["original_trade_decks_unchanged"]=unchanged; _write_status(value)
