extends Node
const Workshop = preload("res://scenes/map_workshop/map_workshop_main.tscn")
const Mutations = preload("res://scripts/map_workshop/workshop_mutations.gd")
const Progress = preload("res://scripts/lshu_ui/lshu_progress.gd")
var checks: Array = []
var w: Control
var done := false
class Catcher extends Logger:
	var errors: Array = []
	func _log_error(_fn:String,file:String,line:int,code:String,reason:String,_notify:bool,kind:int,_trace:Array[ScriptBacktrace])->void:
		if kind!=ERROR_TYPE_WARNING: errors.append("%s:%d %s %s"%[file,line,code,reason])
	func _log_message(_message:String,_error:bool)->void: pass
var logger := Catcher.new()
func _ready()->void:
	OS.add_logger(logger)
	get_tree().create_timer(100.0).timeout.connect(func()->void:
		if not done: check(false,"watchdog"); finish())
	call_deferred("run")
func check(ok:bool,label:String)->void:
	checks.append({"passed":ok,"label":label}); print("PUBLIC_CHECK ",ok," ",label)
func frames(n:=2)->void:
	for i in n: await get_tree().process_frame
func run()->void:
	check(not PublicRules.ready(),"fresh release requires owner configuration")
	var base:=GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	check(base.trade_card_index.is_empty() and base.event_definitions.is_empty(),"no original deck or event fallback")
	check(not GameData.validate_content(base).valid,"empty rules cannot pass formal validation")
	check(not PublicRules.install(JSON.stringify(PublicRules.template())).ok,"unconfirmed blank config is rejected")
	check(Progress.playtest_dir(PackedStringArray(["--workshop-data-dir=/tmp/forbidden"])).is_empty(),"ordinary game ignores child-only data switch")
	check(Progress.playtest_dir(PackedStringArray(["--workshop-playtest","--workshop-data-dir=relative"])).is_empty(),"relative child directory rejected")
	check(Progress.playtest_dir(PackedStringArray(["--workshop-playtest","--workshop-data-dir=/tmp/a","--workshop-data-dir=/tmp/b"])).is_empty(),"conflicting child roots rejected")
	check(Progress.playtest_dir(PackedStringArray(["--workshop-playtest","--workshop-data-dir=C:/QA Space/child"])).begins_with("C:/"),"Windows drive path is carried as a single argument")
	var params: Dictionary={"version":TradeGenV2Original.VERSION,"local_batches":[[1,7],[2,8],[3,9],[4,10],[5,11]],"silver_cap":23,"price_base":4,"distance_step":3,"silk_count":4,"partner_count":2,"foreign_max":3,"weight_scale":12,"assignment_relaxation_budget":400000}
	var goods: Dictionary={"silk":7}; var producers: Dictionary={}; var distance: Dictionary={}
	for i in 14:
		goods["qa_good_"+str(i)]=7; producers["qa_good_"+str(i)]="qa_origin_"+str(i); distance["qa_origin_"+str(i)]=2*i+1
	var request: Dictionary={"confirmed_by_owner":true,"goods":goods,"producers":producers,"distances":{"x_qa":distance},"goods_map":{"qa":"qa_local"},"topology":[{"slot":"qa"}]}
	var generated:=PublicRules.generate_trade(request,params); var generated_again:=PublicRules.generate_trade(request,params)
	check(generated.ok and generated.decks.size()==1 and generated.decks[0].cards.size()==10,"existing v2 works with explicit synthetic QA policy")
	check(CustomMapSchema.canonical_text(generated)==CustomMapSchema.canonical_text(generated_again),"v2 generation is deterministic")
	check(PublicRules.generate_events([],0).definitions.is_empty(),"no built-in event text")
	var recipes: Array=[{"id":"qa","title":"自有测试","deck_type":"LAND","template":"去{place}看看","variables":{"place":["花园","山坡"]},"effects":[{"op":"GAIN_SILVER","quantity":1}]}]
	check(PublicRules.generate_events(recipes,17)==PublicRules.generate_events(recipes,17),"owner event templates use deterministic seed")
	check(not PublicRules.generate_events([{}],0).ok,"missing event text/effects rejected")
	var progress:=Progress.new()
	check(Progress.ACTS.all(func(a):return progress.is_unlocked(str(a.id))),"all travel acts open without win override")
	check(CustomMapPiecePresets.ITEMS.size()==2,"only public generic pieces are offered")
	CustomMapSettings.test_force_entry=true
	w=Workshop.instantiate(); add_child(w)
	while not w._ready_done: await frames(1)
	await w._on_new_map(); await frames()
	check(w.doc.doc.new_cities.is_empty(),"empty-rule workshop creates a new draft")
	w._on_add_city(); w._on_place_requested(Vector2(14.125,28.125)); await frames()
	check(w.doc.doc.new_cities.size()==1,"empty-rule workshop places a city")
	check(GameState.content.get("cities",{}).has("x_w1"),"draft city has a real presentation record without configured trade")
	w._accept_mutation(Mutations.change_city(w.doc.doc,"x_w1","name","自定义城",w._base_content,w.board.base_layout,w.catalogue),"命名")
	w._on_save(); w.dialogs._name_edit.text="公开版编辑验收"
	while int(w.dialogs.debug_state().get("open_ms",0))<420: await frames(1)
	w.dialogs._choose("ok"); await frames()
	check(w.doc.ever_saved and not w.doc.is_dirty(),"draft saves with unconfigured rules")
	var saved: String=w.doc.sha(); var id: String=w.doc.map_id()
	var reopened:=CustomMapStore.load_map(id)
	check(CustomMapSchema.sha256(reopened)==saved,"real disk reopen has identical SHA")
	await w._switch_doc(reopened,true); await frames()
	check(w.doc.doc.new_cities.size()==1 and w.doc.sha()==saved,"workshop reopens editable draft")
	var launch: Dictionary=w._playtest.start(w.doc.doc)
	check(not launch.ok and w._playtest.pid<0 and w.doc.sha()==saved,"unconfigured trial is blocked without changing the map")

	# A synthetic policy verifies the complete import/start/trade route. It is
	# created only inside this isolated test directory, never shipped as defaults.
	var configured:=PublicRules.template()
	configured.confirmed_by_owner=true; configured.events_enabled=false; configured.seed=17
	configured.ruleset={"warehouse_capacity":4,"open_trade_route_reward":13,"direct_sale_rate":6,"silver_supply_by_player_count":{"2":211,"3":311,"4":411},"dice_faces":[1,2,3]}
	for good: Dictionary in base.goods.values(): configured.goods.append({"id":good.id,"supply_total":71})
	for city: Dictionary in base.cities.values(): configured.city_cards.append({"city_id":city.id,"starting_grant":{"entries":[{"resource_kind":"SILVER","resource_id":"silver","quantity":37}]}})
	var qa_entries: Array=[{"resource_kind":"SILVER","resource_id":"silver","quantity":19},{"resource_kind":"GOOD","resource_id":"silk","quantity":1},{"resource_kind":"GOOD","resource_id":"tea","quantity":2},{"resource_kind":"GOOD","resource_id":"jade","quantity":3}]
	configured.trade_decks=[{"id":"qa_owner_deck","city_ids":base.cities.keys(),"cards":[{"id":"qa_owner_card_1","entries":qa_entries},{"id":"qa_owner_card_2","entries":qa_entries},{"id":"qa_owner_card_3","entries":qa_entries}]}]
	configured.generator_params=params
	var installed:=PublicRules.install(JSON.stringify(configured))
	print("QA_CONFIG_INSTALL ",JSON.stringify(installed))
	check(installed.ok and PublicRules.ready(),"explicit complete synthetic config installs and passes formal validation")
	if installed.ok:
		var content:=GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
		var setup:=SetupSystem.start_new_game(content,[{"display_name":"QA1","color_id":"red","controller_type":"LOCAL_HUMAN"},{"display_name":"QA2","color_id":"blue","controller_type":"LOCAL_HUMAN"}],17)
		print("QA_SETUP ",JSON.stringify(setup))
		check(setup.success,"configured formal game starts with synthetic owner data")
		if setup.success:
			GameState.phase=GameState.Phase.TRADE
			var trade:=TradeSystem.trade_ratio(1,0,1)
			# Seed-dependent home cities share the independently specified QA deck.
			GameState.phase=GameState.Phase.TRADE
			var bought:=TradeSystem.trade_ratio(0,1,1)
			check(bought.success and GameState.current_player().cargo_count()==1,"configured transaction moves synthetic goods and silver")
			check(not trade.success,"trade rejects unavailable inventory without crashing")
		GameState.reset_session()
		var bad:=configured.duplicate(true); bad.trade_decks[0].cards[0].entries[0].quantity=-1
		var previous:=FileAccess.get_file_as_bytes(PublicRules.path())
		check(not PublicRules.install(JSON.stringify(bad)).ok and FileAccess.get_file_as_bytes(PublicRules.path())==previous,"invalid config preserves prior disk policy")
		DirAccess.remove_absolute(PublicRules.path()); DirAccess.remove_absolute(PublicRules.path()+".bak")
		GameData._formal_cache={}; CustomMapLoader._base_cache={}
		check(not PublicRules.ready(),"removing test policy restores empty public state")
	check(logger.errors.is_empty(),"no engine/script errors")
	finish()
func finish()->void:
	if done:return
	done=true
	var failed:int=checks.filter(func(c):return not c.passed).size()
	var result: Dictionary={"passed":checks.size()-failed,"failed":failed,"checks":checks,"errors":logger.errors,"scope":"headless cleaned public source; synthetic policy is QA only, never a default ruleset"}
	FileAccess.open(OS.get_environment("SILKROAD_DATA_DIR").path_join("public-results.json"),FileAccess.WRITE).store_string(JSON.stringify(result,"  "))
	print("PUBLIC_RESULT ",JSON.stringify({"passed":checks.size()-failed,"failed":failed,"errors":logger.errors})); OS.remove_logger(logger)
	get_tree().quit(0 if failed==0 else 1)
