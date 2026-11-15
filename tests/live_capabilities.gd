extends SceneTree
## Explicit goal-following fixtures, not an emergent-behaviour benchmark.
## This script is NEVER part of ordinary tests or the exported game. It never
## substitutes an operator action for a requested model action.
const Game=preload("res://scripts/release_main.gd")
const Credentials=preload("res://scripts/release_storage/credential_store.gd")
const Ledger=preload("res://scripts/release_ai/usage_ledger.gd")
const Repository=preload("res://scripts/release_storage/session_repository.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
const PersonalMemory=preload("res://scripts/release_ai/personal_memory.gd")
const OUTPUT="res://test-output/live/capabilities"
const ACTOR="person_00"
const WITNESS="person_01"
var game:Node
var started:=0
var initial_requests:=0
var initial_committed:=0.0
var max_calls:=60
var max_additional_rub:=80.0
var aborted:=false
var stage:="setup"
var fixture_ration:=""
var before_step_inventory:Dictionary={}
var model_consumed_items:Array=[]
var report:Dictionary={"kind":"real_vlm_explicit_goal_following_fixtures","complete":false,"passed":false,"stages":[],"decisions":[],"fixture_setup":[],"failures":[],"network_time_is_frozen":true}

func _initialize()->void:run.call_deferred()

func run()->void:
	# Gate before creating the game or reading any credential/production ledger.
	if not "--allow-paid" in OS.get_cmdline_user_args() or not "--test-profile" in OS.get_cmdline_user_args():
		printerr("Explicit --allow-paid and --test-profile are required; no credential or production ledger was read.");quit(2);return
	if DisplayServer.get_name()=="headless":
		printerr("A genuine renderer is required; no credential or production ledger was read.");quit(2);return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--max-calls="):max_calls=clampi(int(argument.get_slice("=",1)),1,60)
		elif argument.begins_with("--max-additional-rub="):max_additional_rub=clampf(float(argument.get_slice("=",1)),1.0,80.0)
	started=Time.get_ticks_msec();report["started_utc"]=Time.get_datetime_string_from_system(true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DisplayServer.window_set_position(Vector2i(-5000,-5000));Engine.max_fps=30
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var key:String=Credentials.new().load_key()
	if key.is_empty():fail("Local RouterAI credential is missing");finish();return
	game=Game.new();root.add_child(game)
	game.ledger.release_storage_lease();game.ledger=Ledger.new()
	game._ledger_path="user://release_usage_ledger.json"
	game.configure_provider({"enabled":true,"key":key,"remember":false,"budget":1000.0});key=""
	var deadline:=Time.get_ticks_msec()+60000
	while game._provider_pending and Time.get_ticks_msec()<deadline:await process_frame
	if game._quote.is_empty() or not str(game.ledger.status().storage_error).is_empty():
		fail("Provider preflight or exclusive account-ledger lease unavailable");finish();return
	report["provider"]=game._quote.get("provider_only",[])
	report["model"]=game.settings.model
	report["initial_ledger"]=game.ledger.status()
	initial_requests=int(game.ledger.status().request_count)
	initial_committed=committed_cost(game.ledger.status())
	new_fixture("sandbox")
	if not place_food_fixture():fail("Could not construct a physically valid food/witness fixture");finish();return
	await picture(ACTOR,"food_fixture.png")
	await goal_stage("perceive_approach_take_consume",ACTOR,
		"Перед тобой на полу виден жёлтый пакет с пищей. Подойди к нему, возьми и съешь. Действуй по своему изображению и текущим временным визуальным ссылкам. Осмотр не поворачивает голову. Заверши задачу реальным употреблением еды.",12,
		func()->bool:return model_consumed_items.has(fixture_ration))
	if aborted:finish();return
	var heard_before:int=game.simulation.state.agents[WITNESS].heard.size()
	await goal_stage("communicate_personal_observation",ACTOR,
		"Скажи вслух стоящему рядом человеку, что ты лично увидел и что произошло при твоих действиях с едой. Одной короткой реплики достаточно; не выдумывай успешный результат, если действие не удалось.",3,
		func()->bool:return has_event(ACTOR,"speak") and game.simulation.state.agents[WITNESS].heard.size()>heard_before)
	if aborted:finish();return
	await goal_stage("take_genuine_photo",ACTOR,
		"Сделай цифровую фотографию текущего вида своим разблокированным телефоном. Используй действие съёмки; запись в дневник не является фотографией.",5,
		func()->bool:return has_attached_photo(ACTOR))
	if aborted:finish();return
	await goal_stage("view_exact_photo",ACTOR,
		"Рассмотри уже сделанную фотографию на своём телефоне: открой именно доступный снимок прошлого, чтобы лично увидеть его. Не делай новый снимок вместо просмотра старого.",5,
		func()->bool:return has_personal(ACTOR,"viewed_photo","viewed_own_artifact"))
	if aborted:finish();return
	await goal_stage("send_private_message",ACTOR,
		"Открой приложение сообщений на своём телефоне и отправь личное сообщение Борису, известному тебе контакту, с кратким описанием твоего личного опыта с едой. Используй контакт из личного списка, а не произнесение вслух.",8,
		func()->bool:return has_message(ACTOR,WITNESS))
	if aborted:finish();return
	await goal_stage("read_private_message",WITNESS,
		"На твоём телефоне ожидает личное сообщение от Ады. Открой сообщения, прочитай экран и само доставленное сообщение. Текст должен стать твоим личным опытом чтения; не угадывай его содержание.",8,
		func()->bool:return has_personal(WITNESS,"message","received_message"))
	if aborted:finish();return
	# A separate authored scenario provides an actually altered delivered notice.
	new_fixture("deception")
	if not place_by_terminal():fail("Could not place the deception actor beside the real terminal");finish();return
	await picture(ACTOR,"deception_fixture.png")
	await goal_stage("read_altered_notice",ACTOR,
		"Прочти ожидающее сообщение на своём телефоне: открой приложение сообщений, прочти экран и конкретное сообщение. Сначала получи личный опыт чтения; не считай уведомление доказательством содержимого.",8,
		func()->bool:return has_personal(ACTOR,"message","received_message"))
	if aborted:finish();return
	await goal_stage("verify_notice_at_terminal",ACTOR,
		"Теперь лично проверь сведения прочитанного сообщения у видимого рядом терминала пайков. Взаимодействуй с ним или запроси свой паёк, чтобы прочесть настоящее правило выдачи. Сравни личные источники, не принимай чужое сообщение за прямое наблюдение.",8,
		func()->bool:return objective_complete("verify") and has_personal(ACTOR,"terminal","read_terminal"))
	if aborted:finish();return
	await memory_stage(ACTOR)
	report.complete=not aborted
	finish()

func new_fixture(scenario:String)->void:
	game.new_session({"map_id":"closed_block","count":3,"scenario":scenario,"seed":17})
	game.ui.show_main_menu(false)
	for runtime in game.runtimes.values():runtime.decision_ready.connect(on_decision)
	for id in game.simulation.state.agents:
		var actor:Dictionary=game.simulation.state.agents[id]
		actor.busy={"type":"wait","remaining":720.0}
		actor.sleeping=false;actor.unconscious=false
	game._record()

func place_food_fixture()->bool:
	var geometry:Dictionary=game.simulation.state.geometry
	var layout:Dictionary={}
	for z in range(-3,4):
		for x in range(-4,5):
			var origin:=Vector2(float(x),float(z))
			for degrees in range(0,360,45):
				var forward:=Vector2.from_angle(deg_to_rad(float(degrees)))
				var side:=Vector2(-forward.y,forward.x)
				var food:=origin+forward*2.4
				var witness:=origin+side*1.6
				var third:=origin+side*3.0
				if not Spatial.walkable(origin,geometry) or not Spatial.walkable(food,geometry) or not Spatial.walkable(witness,geometry) or not Spatial.walkable(third,geometry):continue
				if not Spatial.clear_line(origin,food,geometry,.3) or not Spatial.clear_line(origin,witness,geometry):continue
				layout={"origin":origin,"food":food,"witness":witness,"third":third,"heading":rad_to_deg(atan2(-forward.x,-forward.y))};break
			if not layout.is_empty():break
		if not layout.is_empty():break
	if layout.is_empty():return false
	for pair in [[ACTOR,"origin"],[WITNESS,"witness"],["person_02","third"]]:
		var actor:Dictionary=game.simulation.state.agents[pair[0]]
		var point:Vector2=layout[pair[1]];actor.position=[point.x,point.y]
		actor.heading=float(layout.heading);actor.surface_height=0.0
	game.simulation.state.agents[ACTOR].needs.hunger=65.0
	game.simulation._introduce(ACTOR,WITNESS);game.simulation._introduce(WITNESS,ACTOR)
	var food:Vector2=layout.food
	var created:Dictionary=game.simulation.intervene("spawn_item",{"kind":"ration","label":"Паёк","position":[food.x,food.y]})
	if not created.ok:return false
	fixture_ration=str(created.get("details",{}).get("item",""))
	setup_trace("food_and_awake_witness",{"actor_position":game.simulation.state.agents[ACTOR].position,"heading":layout.heading,"food_position":[food.x,food.y],"fixture_item":fixture_ration,"witness_position":game.simulation.state.agents[WITNESS].position,"note":"Positions, need and acquaintance are authored fixture setup, never credited as AI actions."})
	return true

func place_by_terminal()->bool:
	var terminal:=Spatial.point({"position":game.simulation.state.terminal.position})
	var geometry:Dictionary=game.simulation.state.geometry
	for degrees in range(0,360,15):
		var offset:=Vector2.from_angle(deg_to_rad(float(degrees)))*1.3
		var candidate:=terminal+offset
		if not Spatial.walkable(candidate,geometry,game.simulation.state.agents,ACTOR):continue
		var terminal_id:=""
		for prop in geometry.props:
			if prop.kind=="terminal":terminal_id=str(prop.id);break
		if not Spatial.clear_line(candidate,terminal,geometry,0.0,terminal_id,true):continue
		var actor:Dictionary=game.simulation.state.agents[ACTOR]
		actor.position=[candidate.x,candidate.y];actor.heading=rad_to_deg(atan2(offset.x,offset.y));actor.surface_height=0.0
		setup_trace("altered_notice_and_nearby_terminal",{"actor_position":actor.position,"heading":actor.heading,"terminal_position":[terminal.x,terminal.y],"note":"Scenario supplies an altered message; pose beside terminal is operator fixture setup."})
		return true
	return false

func setup_trace(name:String,details:Dictionary)->void:
	report.fixture_setup.append({"name":name,"details":details.duplicate(true)})
	game.simulation._event("observer","capability_fixture",true,"Authored acceptance fixture setup",{"fixture":name,"details":details})
	game.world.sync_state(game.simulation.snapshot(),true);game._record();game._refresh()

func goal_stage(name:String,id:String,goal:String,call_limit:int,predicate:Callable)->void:
	stage=name
	var before_requests:int=int(game.ledger.status().request_count)
	var before_seq:int=int(game.simulation.state.event_cursor)
	var phase_start:=Time.get_ticks_msec()
	# An operator goal is declared explicitly. Every resulting intention is real.
	game.god_intervention("goal",{"id":id,"goal":goal})
	game.selected=id;game.world.select_agent(id)
	for other in game.simulation.state.agents:
		if other!=id:game.simulation.state.agents[other].busy={"type":"wait","remaining":720.0}
	var steps:=0
	while not predicate.call() and steps<40 and int(game.ledger.status().request_count)-before_requests<call_limit:
		if not may_call():break
		steps+=1
		await step_once(id)
		if aborted:break
	var passed:bool=predicate.call()
	var facts:Array=[]
	for event in game.simulation.state.events:
		if int(event.seq)>=before_seq and event.actor==id and event.type!="intervention":facts.append({"minute":event.minute,"type":event.type,"ok":event.ok,"message":event.message})
	report.stages.append({"name":name,"actor":id,"passed":passed,"model_requests":int(game.ledger.status().request_count)-before_requests,"world_steps":steps,"wall_seconds":(Time.get_ticks_msec()-phase_start)/1000.0,"facts":facts})
	if not passed:report.failures.append("Goal-following fixture did not complete: "+name)
	await picture(id,name+".png");write_report()
	print("LIVE CAPABILITY ",name," ","PASS" if passed else "FAIL"," calls=",int(game.ledger.status().request_count)-before_requests)

func step_once(id:String)->void:
	var before_tick:int=int(game.simulation.state.tick)
	before_step_inventory.clear()
	for actor_id in game.simulation.state.agents:before_step_inventory[actor_id]=game.simulation.state.agents[actor_id].inventory.duplicate()
	game.single_step()
	var deadline:=Time.get_ticks_msec()+110000
	while (game.collecting or game.advancing or game._provider_pending) and Time.get_ticks_msec()<deadline:
		if game.collecting and not game._round.is_empty():
			var source:String=str(game._round.expected[0])
			if int(game.simulation.state.tick)!=int(game._round.tick) or float(game.simulation.state.minute)!=float(game._round.samples[source].observation.minute):report.network_time_is_frozen=false
		await process_frame
	if game.collecting or game.advancing or game._provider_pending:
		fail("Timed out waiting for a real model step");return
	if int(game.simulation.state.tick)==before_tick:
		var error:String=str(game.runtimes[id].debug().last_error)
		fail("Real step did not commit: "+error.left(300));return
	await process_frame

func on_decision(id:String,run_id:int,tick:int,action:Dictionary,diagnostic:Dictionary)->void:
	var safe:Dictionary={}
	for field in ["ok","error","mode","role","status","cost_source","actual_rub","provider_name","quoted_provider","requested_model","returned_model","currency","prompt_tokens","completion_tokens"]:
		if diagnostic.has(field) and (diagnostic[field] is String or diagnostic[field] is bool or diagnostic[field] is int or diagnostic[field] is float):safe[field]=diagnostic[field]
	report.decisions.append({"stage":stage,"actor":id,"run_id":run_id,"tick":tick,"intention":action.duplicate(true),"diagnostic":safe})
	# Observe the committed result of the model's own consumption, using the
	# inventory snapshot from BEFORE that call. Fixture items are never consumed
	# or granted by this driver. This proves the pictured ration was the one used.
	if action.get("type")=="consume" and before_step_inventory.has(id):
		var slot:int=int(action.get("slot",-1))
		var own_inventory:Array=before_step_inventory[id]
		if slot>=0 and slot<own_inventory.size():
			for event in game.simulation.state.events:
				if event.actor==id and event.type=="consume" and bool(event.ok) and int(event.tick)==tick+1:
					model_consumed_items.append(str(own_inventory[slot]));break
	if not bool(diagnostic.get("ok",false)):fail("Provider or strict action-schema failure in "+stage+": "+str(diagnostic.get("error","unknown")).left(300))
	write_report()

func memory_stage(id:String)->void:
	stage="separate_real_memory_role"
	if aborted or not may_call():return
	var runtime:Node=game.runtimes[id]
	var before:Dictionary=runtime.memory_view()
	var foundation:String=str(runtime.profile.foundation)
	# Advance fictional time without model actions. The existing private records
	# age out naturally; the setup is declared and never counted as AI behaviour.
	game.advance_world(60.0)
	while game.advancing:await process_frame
	game.advance_world(5.0)
	while game.advancing:await process_frame
	setup_trace("age_own_experience_for_memory_role",{"advanced_game_minutes":65.0,"note":"Explicit time-aging fixture; no generated action is implied."})
	var observation:Dictionary=game.simulation.observe(id)
	game.world.set_perception_candidates(id,game.simulation.perception_candidates(id));game.world.prepare_capture(id)
	await RenderingServer.frame_post_draw
	var png:PackedByteArray=game.world.capture_agent(id).save_png_to_buffer()
	observation=game.world.enrich_observation(id,observation)
	var before_calls:int=int(game.ledger.status().request_count)
	runtime.observe(observation,png)
	var protected:Dictionary=runtime.memory_view().recent[-1].duplicate(true)
	var target_id:int=int(protected.id)
	var deadline:=Time.get_ticks_msec()+110000
	while int(runtime.memory_view().version)<=int(before.version) and Time.get_ticks_msec()<deadline and not aborted:
		var debug:Dictionary=runtime.debug()
		if debug.pending.is_empty() and not str(debug.last_error).is_empty():break
		await process_frame
	var after:Dictionary=runtime.memory_view()
	var fresh_unchanged:=false
	for entry in after.recent:
		if int(entry.id)==target_id:fresh_unchanged=JSON.stringify(entry)==JSON.stringify(protected)
	var real_version:=false
	for revision in after.versions:
		if int(revision.version)>int(before.version) and revision.mode=="real_memory_agent":real_version=true
	var passed:bool=real_version and fresh_unchanged and str(runtime.profile.foundation)==foundation
	report.stages.append({"name":stage,"actor":id,"passed":passed,"model_requests":int(game.ledger.status().request_count)-before_calls,"real_memory_version":real_version,"protected_fresh_record_unchanged":fresh_unchanged,"foundation_unchanged":str(runtime.profile.foundation)==foundation,"before_version":before.version,"after_version":after.version,"error":str(runtime.debug().last_error).left(300)})
	if not passed:report.failures.append("Separate real memory role did not consolidate while preserving protected experience")
	print("LIVE CAPABILITY ",stage," ","PASS" if passed else "FAIL");write_report()

func picture(id:String,filename:String)->void:
	if not is_instance_valid(game) or not game.simulation.state.agents.has(id):return
	game.world.sync_state(game.simulation.snapshot(),true);game.world.prepare_capture(id)
	await RenderingServer.frame_post_draw
	var image:Image=game.world.capture_agent(id)
	if image!=null and not image.is_empty():image.save_png(OUTPUT.path_join(filename))

func has_event(id:String,type:String)->bool:
	for event in game.simulation.state.events:
		if event.actor==id and event.type==type and bool(event.get("ok",false)):return true
	return false
func has_personal(id:String,channel:String,source:String)->bool:
	for entry in game.simulation.state.agents[id].personal_results:
		if entry.get("channel")==channel and entry.get("source")==source:return true
	return false
func has_attached_photo(id:String)->bool:
	for artifact in game.simulation.state.artifacts.values():
		if artifact.creator==id and not str(artifact.image_ref).is_empty():return true
	return false
func has_message(sender:String,recipient:String)->bool:
	for message in game.simulation.state.network.messages.values():
		if message.sender==sender and message.recipient==recipient and message.status in ["delivered","read"]:return true
	return false
func objective_complete(id:String)->bool:
	for objective in game.simulation.state.objectives:
		if objective.id==id and objective.get("complete",false):return true
	return false
func committed_cost(status:Dictionary)->float:
	return float(status.spent_rub)+float(status.unknown_rub)+float(status.reserved_rub)
func may_call()->bool:
	var status:Dictionary=game.ledger.status()
	if int(status.request_count)-initial_requests>=max_calls:
		fail("Explicit capability request cap reached");return false
	if committed_cost(status)-initial_committed>=max_additional_rub or float(status.remaining_rub)<5.0:
		fail("Capability spending sub-limit or shared account budget reached");return false
	if not str(status.storage_error).is_empty():fail("Shared usage ledger unavailable");return false
	return not aborted
func fail(message:String)->void:
	report.failures.append(message);aborted=true;write_report()
func write_report()->void:
	if started==0:return
	report["wall_seconds"]=(Time.get_ticks_msec()-started)/1000.0
	if is_instance_valid(game):
		report["ledger"]=game.ledger.status()
		report["requests_this_run"]=maxi(0,int(game.ledger.status().request_count)-initial_requests)
		report["model_consumed_items"]=model_consumed_items.duplicate()
	Repository.atomic_write(OUTPUT.path_join("report.json"),JSON.stringify(report,"\t"))
func finish()->void:
	if is_instance_valid(game):
		game._set_running(false)
		game.repository.flush()
	report.passed=bool(report.complete) and report.failures.is_empty() and bool(report.network_time_is_frozen)
	write_report();print("LIVE CAPABILITIES ","PASS" if report.passed else "FAIL"," stages=",report.stages.size())
	quit(0 if report.passed else 1)
