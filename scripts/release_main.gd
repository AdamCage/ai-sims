extends Node
## Release composition: models return intentions, rules remain authoritative.
const Simulation = preload("res://scripts/game/session_simulation.gd")
const Runtime = preload("res://scripts/release_ai/agent_runtime.gd")
const World = preload("res://scripts/release_world/world_view.gd")
const Interface = preload("res://scripts/release_ui/observer_ui.gd")
const Repository = preload("res://scripts/release_storage/session_repository.gd")
const Credentials = preload("res://scripts/release_storage/credential_store.gd")
const Ledger = preload("res://scripts/release_ai/usage_ledger.gd")
const Media = preload("res://scripts/release_ai/media_archive.gd")
const PersonalMemory = preload("res://scripts/release_ai/personal_memory.gd")
const ProviderCatalog = preload("res://scripts/release_ai/provider_catalog.gd")
const PNGEncoder = preload("res://scripts/release_storage/png_encoder.gd")

var simulation = Simulation.new()
var world: Node3D
var ui: CanvasLayer
var runtimes: Dictionary = {}
var repository = Repository.new()
var credentials = Credentials.new()
var ledger = Ledger.new()
var media = Media.new()
var running := false
var collecting := false
var advancing := false
var mode := "demo"
var selected := "person_00"
var generation := 0
var settings := {"language":"ru","quality":"medium","speed":1.0,"sfx_volume":0.5,"model":"~deepseek/deepseek-v4-flash-latest","provider":"byteplus","budget":1000.0,"ai_enabled":false}
var _key := ""
var _clock := 0.0
var _ui_clock := 0.0
var _single_step := false
var _round: Dictionary = {}
var _next_decision: Dictionary = {}
var _last_event_cursor := 0
var _slot_cache: Array = []
var _reviewing := false
var _replay_cursor := 0
var _replay_clock := 0.0
var _sounds: Dictionary = {}
var _test_profile := false
var _last_autosave := 0.0
var _observations: Dictionary = {}
var _device_screens: Dictionary = {}
var _catalog: Node
var _quote: Dictionary = {}
var _catalog_tag := 0
var _provider_pending := false
var _quote_refresh_queued := false
var appearance_presets: Dictionary = {}
var _ledger_path:="user://release_usage_ledger.json"
var _presets_path:="user://appearance_presets.json"
var _deferred_commands:Array=[]

func _ready() -> void:
	simulation.personal_experience.connect(_on_personal_experience)
	_test_profile = "--test-profile" in OS.get_cmdline_user_args()
	if _test_profile:
		repository.save_root="user://release_test_profile/saves"
		repository.session_root="user://release_test_profile/sessions"
		_ledger_path="user://release_test_profile/usage.json"
		_presets_path="user://release_test_profile/appearance_presets.json"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://release_test_profile"))
	_load_settings()
	_catalog=ProviderCatalog.new();add_child(_catalog);_catalog.quote_ready.connect(_on_quote_ready)
	ledger.configure(minf(1000.0,float(settings.budget)) if OS.has_feature("editor") else float(settings.budget),_ledger_path,4)
	if not _test_profile:
		_key = credentials.load_key()
	mode="real_vlm" if bool(settings.ai_enabled) else "demo"
	world = World.new(); add_child(world)
	ui = Interface.new(); add_child(ui)
	ui.command.connect(_on_command)
	simulation.reset("closed_block",7,"scarcity",1)
	world.setup(simulation.snapshot())
	world.set_quality(str(settings.quality))
	ui.setup(world)
	ui.set_language(str(settings.language))
	_make_runtimes()
	repository.begin(simulation.snapshot())
	_last_event_cursor = int(simulation.state.event_cursor)
	_slot_cache = repository.slot_summaries()
	_setup_audio()
	_refresh()
	ui.set_status(_text("Выберите сценарий. Демонстрационный режим работает без сети.","Choose a scenario. Demo mode works offline."))
	var launch:Dictionary={"map_id":"closed_block","count":7,"scenario":"scarcity","seed":1}
	var custom_launch:=false
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--agents="):launch.count=int(argument.trim_prefix("--agents="));custom_launch=true
		elif argument.begins_with("--map="):launch.map_id=argument.trim_prefix("--map=");custom_launch=true
		elif argument.begins_with("--scenario="):launch.scenario=argument.trim_prefix("--scenario=");custom_launch=true
	if custom_launch:new_session(launch)
	if "--auto-run" in OS.get_cmdline_user_args():ui.show_main_menu(false);_set_running(true)
	if "--configure-ai" in OS.get_cmdline_user_args():_set_running(false);ui.show_main_menu(false);ui.show_settings()

func _process(delta: float) -> void:
	if _quote_refresh_queued and not _provider_pending and int(ledger.status().active_requests)==0:
		_quote_refresh_queued=false;_request_quote()
	# Memory-role calls share the account's concurrency limit. Their completion
	# has no action callback, so resume queued decisions when a slot is released.
	if collecting and not _round.is_empty() and not _round.remaining.is_empty():_dispatch_real()
	if not advancing and not collecting and not _deferred_commands.is_empty():
		var queued:Dictionary=_deferred_commands.pop_front();_on_command(queued.name,queued.payload);return
	_ui_clock += delta
	if _ui_clock >= 0.75:
		_ui_clock = 0.0
		_refresh(false)
	if _reviewing:
		_replay_clock += delta
		if _replay_clock >= 0.35 and _replay_cursor < repository.sequence:
			_replay_clock = 0.0; _replay_cursor += 1; _display_replay()
		return
	if not running or collecting or advancing or _provider_pending:
		return
	_clock += delta * float(settings.speed)
	if _clock >= 0.2:
		_clock = minf(_clock-0.2,0.4)
		if not _decision_ids().is_empty():
			collect_decisions()
		else:
			advance_world(0.2)

func _on_command(name: String, payload: Dictionary) -> void:
	if advancing and name in ["new_session","step","save","load","replay","god","appearance","intent","provider"]:
		_deferred_commands.append({"name":name,"payload":payload.duplicate(true)})
		ui.set_status(_text("Завершаем уже выполненный игровой шаг и его снимки…","Finishing the committed step and its photographs…"));return
	_play_sound("click")
	match name:
		"new_session": new_session(payload)
		"run": _set_running(bool(payload.get("value",not running)))
		"step": single_step()
		"select":
			var id := str(payload.get("id",selected))
			if simulation.state.agents.has(id): selected=id; world.select_agent(id); _refresh()
		"view": world.set_first_person(bool(payload.get("first_person",false))); _refresh()
		"save": save_slot(int(payload.get("slot",1)))
		"load": load_slot(int(payload.get("slot",1)))
		"replay": start_replay()
		"settings":
			for key in ["language","quality","speed","sfx_volume"]:
				if payload.has(key): settings[key]=payload[key]
			settings.speed=clampf(float(settings.speed),0.25,10.0)
			settings.sfx_volume=clampf(float(settings.sfx_volume),0.0,1.0)
			world.set_quality(str(settings.quality));ui.set_language(str(settings.language)); _save_settings(); _refresh()
		"provider": configure_provider(payload)
		"god": god_intervention(str(payload.get("command","")),payload.get("args",{}))
		"appearance":
			god_intervention("appearance",payload)
			var preset_name:=str(payload.get("preset_name","")).strip_edges().left(80)
			if not preset_name.is_empty():
				var preset:=payload.duplicate(true);preset.erase("id");preset.erase("preset_name")
				appearance_presets[preset_name]=preset;Repository.atomic_write(_presets_path,JSON.stringify(appearance_presets))
		"intent":
			_invalidate()
			var id := str(payload.get("id",selected))
			var result: Dictionary=simulation.intervene("action",{"id":id,"action":payload.get("action",{})})
			ui.set_status(str(result.reason)); _record(); _refresh()
			if result.ok: advance_world(0.2)

func new_session(config: Dictionary) -> void:
	_set_running(false); _invalidate(); _reviewing=false
	advancing=false
	simulation.reset(str(config.get("map_id","closed_block")),clampi(int(config.get("count",7)),3,20),str(config.get("scenario","scarcity")),int(config.get("seed",1)))
	selected=str(simulation.state.agents.keys()[0])
	_next_decision.clear(); _observations.clear(); _device_screens.clear(); _clock=0.0; _last_autosave=0.0
	world.setup(simulation.snapshot()); world.select_agent(selected)
	_make_runtimes(); repository.begin(simulation.snapshot()); _last_event_cursor=int(simulation.state.event_cursor)
	_refresh(); ui.set_status(_text("Новая сессия готова. Нажмите «Продолжить», чтобы начать.","A new story is ready. Press Continue to begin."))

func _make_runtimes() -> void:
	for runtime in runtimes.values(): runtime.cancel_pending(); runtime.queue_free()
	runtimes.clear()
	for id in simulation.state.agents:
		var runtime=Runtime.new(); add_child(runtime)
		runtime.configure(id,simulation.state.agents[id].profile); runtime.reset(int(simulation.state.run_id))
		runtime.decision_ready.connect(_on_decision)
		runtime.memory_updated.connect(_on_memory_updated)
		runtime.configure_provider(_provider_config())
		runtimes[id]=runtime

func _provider_config() -> Dictionary:
	var config:=_quote.duplicate(true)
	config.merge({"enabled":mode=="real_vlm" and not _key.is_empty(),"key":_key,"model":settings.model,"ledger":ledger},true)
	return config

func _request_quote() -> void:
	if _provider_pending:return
	_provider_pending=true;_catalog_tag+=1
	var preference:String=str(settings.provider) if str(settings.model).contains("deepseek-v4") else ""
	var error:Error=_catalog.request_quote(str(settings.model),_catalog_tag,preference,420)
	if error!=OK:
		_provider_pending=false;running=false;ui.set_running(false);ui.set_status(_text("Не удалось проверить тариф и поддержку выбранной модели.","Could not verify the model tariff and capabilities."))
	else:ui.set_status(_text("Проверяем изображения, тариф и доступного провайдера RouterAI…","Checking images, tariff and RouterAI provider…"))

func _on_quote_ready(tag: int, quote: Dictionary) -> void:
	if tag!=_catalog_tag:return
	_provider_pending=false
	if not bool(quote.get("ok",false)):
		running=false;ui.set_running(false);ui.set_status("RouterAI: "+str(quote.get("error","Не удалось проверить модель")));return
	_quote=quote.duplicate(true)
	for runtime in runtimes.values():runtime.configure_provider(_provider_config())
	ui.set_status(_text("RouterAI готов. Провайдер и тариф проверены, бюджет %.2f ₽.","RouterAI is ready. Provider and tariff checked; budget %.2f RUB.")%float(ledger.status().remaining_rub))
	_refresh(false)
	if _single_step and not running:collect_decisions.call_deferred()

func _set_running(value: bool) -> void:
	if value and mode=="real_vlm" and not str(ledger.status().storage_error).is_empty():
		running=false;ui.set_running(false);ui.set_status(_ledger_message());return
	if value and mode=="real_vlm" and _key.is_empty():
		running=false;ui.set_running(false);ui.show_settings();ui.set_status(_text("Нужен личный ключ RouterAI. Сетевой режим сохранён; демонстрация не подменяет AI.","Your RouterAI key is required. Real AI remains selected."));return
	if not value: _invalidate()
	_reviewing=false; running=value; _clock=0.0
	ui.set_running(value)
	if value: ui.set_status(_text("Симуляция: реальная VLM","Simulation: real VLM") if mode=="real_vlm" else _text("Демонстрация без сети","Offline demo"))
	else: ui.set_status(_text("Пауза: игровое время остановлено","Paused: game time is stopped"))
	_refresh()

func _invalidate() -> void:
	generation += 1; collecting=false; _round.clear(); _single_step=false;_quote_refresh_queued=false
	for runtime in runtimes.values(): runtime.cancel_pending()

func _decision_ids() -> Array:
	var ids: Array=[]
	for id in simulation.state.agents:
		var actor: Dictionary=simulation.state.agents[id]
		if actor.alive and not actor.sleeping and not actor.unconscious and actor.busy.is_empty() and float(simulation.state.minute)>=float(_next_decision.get(id,-1.0)):
			ids.append(id)
	return ids

func single_step() -> void:
	_set_running(false); _single_step=true
	if _decision_ids().is_empty(): advance_world(1.0)
	else: collect_decisions()

func collect_decisions() -> void:
	if collecting or advancing: return
	# Leave enough verified-tariff lifetime for the entire queued 20-person
	# round. Refresh only after memory requests drain; reconfiguring their
	# transport while in flight would lose receipts and retain unknown charges.
	if mode=="real_vlm" and (_quote.is_empty() or float(_quote.get("expires_at",0.0))<=Time.get_unix_time_from_system()+420.0):
		_quote_refresh_queued=true
		if int(ledger.status().active_requests)==0:_quote_refresh_queued=false;_request_quote()
		return
	var ids:=_decision_ids()
	if ids.is_empty(): return
	collecting=true
	var ticket:=generation
	var run_id:=int(simulation.state.run_id)
	var tick:=int(simulation.state.tick)
	world.sync_state(simulation.snapshot(),true)
	var samples: Dictionary={}
	for id in ids:
		var observation: Dictionary=simulation.observe(id)
		var png:=PackedByteArray()
		if not observation.self_state.body.blind and DisplayServer.get_name()!="headless":
			world.set_perception_candidates(id,simulation.perception_candidates(id))
			world.prepare_capture(id)
			await RenderingServer.frame_post_draw
			if ticket!=generation: return
			var image: Image=world.capture_agent(id)
			if image!=null and not image.is_empty():png=await PNGEncoder.encode(image,get_tree())
			if ticket!=generation:return
			observation=world.enrich_observation(id,observation)
			if mode=="real_vlm" and not png.is_empty() and not observation.targets.is_empty():
				var grounding:Image=await world.grounding_image(image,observation.targets)
				if ticket!=generation:return
				if grounding!=null and not grounding.is_empty():
					observation["grounding_png"]=await PNGEncoder.encode(grounding,get_tree())
					if ticket!=generation:return
					observation["grounding_source_hash"]=Media.digest_bytes(png)
		if simulation.has_method("device_screen") and not observation.self_state.body.blind and DisplayServer.get_name()!="headless":
			var screen: Dictionary=simulation.device_screen(id)
			if not screen.is_empty() and not str(screen.get("text","")).is_empty():
				world.prepare_device_screen(str(screen.get("title","")),str(screen.text))
				await RenderingServer.frame_post_draw
				if ticket!=generation:return
				var screen_image:Image=world.capture_device_screen()
				if screen_image!=null and not screen_image.is_empty():observation["screen_png"]=await PNGEncoder.encode(screen_image,get_tree())
				if ticket!=generation:return
		var grants:Array=PersonalMemory.granted_images(PersonalMemory.personal_context(observation))
		if not grants.is_empty():observation["viewed_image_ref"]=grants[-1]
		runtimes[id].observe(observation,png)
		_observations[id]=observation.duplicate(true)
		samples[id]={"observation":observation,"png":png}
	if ticket!=generation:return
	_round={"generation":ticket,"run_id":run_id,"tick":tick,"expected":ids,"remaining":ids.duplicate(),"actions":{},"samples":samples,"diagnostics":{}}
	if mode=="demo":
		for id in ids:
			_round.actions[id]=runtimes[id].decide_demo(samples[id].observation)
		_finish_round()
	else:
		_dispatch_real()

func _dispatch_real() -> void:
	if _round.is_empty():return
	while not _round.remaining.is_empty() and int(ledger.status().active_requests)<4:
		var id: String=str(_round.remaining.pop_front())
		var sample: Dictionary=_round.samples[id]
		runtimes[id].request_decision(sample.observation,sample.png,int(_round.run_id))
		if _round.is_empty():return # A disabled transport can synchronously report failure.

func _on_decision(id: String, run_id: int, tick: int, action: Dictionary, diagnostic: Dictionary) -> void:
	if _round.is_empty() or int(_round.generation)!=generation or int(_round.run_id)!=run_id or int(_round.tick)!=tick or not _round.expected.has(id) or _round.actions.has(id):return
	_round.actions[id]=action.duplicate(true); _round.diagnostics[id]=diagnostic.duplicate(true)
	if not bool(diagnostic.get("ok",true)):
		# A provider failure pauses explicitly instead of quietly continuing as demo.
		var reason:=str(diagnostic.get("error","Ошибка провайдера"))
		_set_running(false); ui.set_status(_text("AI приостановлен: ","AI paused: ")+reason); return
	if _round.actions.size()==_round.expected.size():_finish_round()
	else:_dispatch_real()

func _finish_round() -> void:
	if _round.is_empty():return
	var actions: Dictionary=_round.actions
	var run_id:=int(_round.run_id)
	_round.clear(); collecting=false
	for id in actions:
		var result: Dictionary=simulation.submit(id,actions[id],run_id)
		_next_decision[id]=float(simulation.state.minute)+(1.0 if result.ok else 3.0)
	advance_world(1.0 if _single_step else 0.2)

func advance_world(minutes: float) -> void:
	if advancing:return
	advancing=true
	var committed_run:=int(simulation.state.run_id)
	var events: Array=simulation.advance(minutes)
	# The logical transition is already committed. Journal it before any render
	# await so pause/reset cannot erase an executed action from the history.
	_record()
	for event in events:
		if bool(event.get("ok",false)) and event.type=="set_goal" and runtimes.has(str(event.actor)):
			runtimes[str(event.actor)].apply_intervention("goal",{"goal":simulation.state.agents[event.actor].profile.goal})
	world.sync_state(simulation.snapshot(),true if not running else false)
	for event in events:
		if bool(event.get("ok",false)):
			if event.type in ["attack","death"]:_play_sound("impact")
			elif event.type in ["open","close"]:_play_sound("door")
			elif event.type in ["send_message","message_delivered"]:_play_sound("message")
			if event.type=="photo_capture" and simulation.has_method("attach_photo") and DisplayServer.get_name()!="headless":
				var actor_id:=str(event.actor)
				var artifact_id:=str(event.get("details",{}).get("artifact_id",""))
				if not artifact_id.is_empty():
					world.sync_state(simulation.snapshot(),true);world.prepare_capture(actor_id)
					await RenderingServer.frame_post_draw
					if committed_run!=int(simulation.state.run_id):return
					var image:Image=world.capture_agent(actor_id)
					var png:PackedByteArray=await PNGEncoder.encode(image,get_tree()) if image!=null and not image.is_empty() else PackedByteArray()
					if committed_run!=int(simulation.state.run_id):return
					var stored:Dictionary=media.store_png(png)
					if not stored.is_empty():simulation.attach_photo(actor_id,artifact_id,str(stored.hash))
	if int(simulation.state.event_cursor)!=_last_event_cursor:_record()
	# The automatic HUD has its own bounded refresh rate; rebuilding it after
	# every accelerated physics step needlessly stalls presentation.
	if not running or _single_step:_refresh(false)
	advancing=false; _single_step=false
	if float(simulation.state.minute)-_last_autosave>=60.0:
		_last_autosave=float(simulation.state.minute);save_slot(3,true)

func _on_memory_updated(id: String, _version: int) -> void:
	if not simulation.state.agents.has(id) or not runtimes.has(id):return
	if simulation.has_method("apply_memory_traits"):
		var own_profile:Dictionary=runtimes[id].profile
		if own_profile.get("traits") is Array and own_profile.traits!=simulation.state.agents[id].profile.traits:
			simulation.apply_memory_traits(id,own_profile.traits)

func _on_personal_experience(id:String,experience:Dictionary) -> void:
	# Record actual heard/read events synchronously, before the engine trims its
	# short notification tail. This hook neither resets visual refs nor calls AI.
	if runtimes.has(id) and runtimes[id].has_method("observe_personal_event"):
		runtimes[id].observe_personal_event(experience,int(simulation.state.run_id))

func god_intervention(command_name: String, args: Dictionary) -> void:
	_invalidate(); _reviewing=false
	command_name={"set_memory":"memory","clear_memory":"memory","set_profile":"profile","set_goal":"goal"}.get(command_name,command_name)
	args=args.duplicate(true)
	if not args.has("id") and not args.has("actor"):args["id"]=selected
	var result: Dictionary=simulation.intervene(command_name,args)
	var id:=str(args.get("id",selected))
	if result.ok and runtimes.has(id) and command_name in ["profile","goal","memory"]:
		runtimes[id].apply_intervention(command_name,args)
		if command_name in ["profile","goal"]:runtimes[id].profile=simulation.state.agents[id].profile.duplicate(true)
	_next_decision.erase(id)
	_record();_refresh();ui.set_status(str(result.reason))

func configure_provider(config: Dictionary) -> void:
	_set_running(false)
	var key:=str(config.get("key","")).strip_edges()
	if not key.is_empty():
		_key=key
		if not _test_profile and bool(config.get("remember",true)):credentials.save_key(key)
	settings.model=str(config.get("model",settings.model))
	var ceiling:=1000.0 if OS.has_feature("editor") else 1000000.0
	settings.budget=clampf(float(config.get("budget",settings.budget)),0.01,ceiling)
	ledger.configure(float(settings.budget),_ledger_path,4)
	if bool(config.get("enabled",false)) and not str(ledger.status().storage_error).is_empty():
		ui.set_status(_ledger_message());return
	if bool(config.get("enabled",false)) and _key.is_empty():
		ui.set_status(_text("Введите личный ключ RouterAI в этом окне. Ключ не отправляется в чат.","Enter your RouterAI key in this window. It stays on this computer."));return
	mode="real_vlm" if bool(config.get("enabled",false)) else "demo"
	settings.ai_enabled=mode=="real_vlm"
	_catalog_tag+=1;_provider_pending=false;_quote.clear()
	for runtime in runtimes.values():runtime.configure_provider(_provider_config())
	_save_settings();_refresh()
	if mode=="real_vlm":_request_quote()
	else:ui.set_status(_text("Выбрана демонстрация без сети.","Offline demo selected."))

func _record() -> void:
	var new_events: Array=[]
	for event in simulation.state.events:
		if int(event.seq)>=_last_event_cursor:new_events.append(event)
	_last_event_cursor=int(simulation.state.event_cursor)
	repository.record(simulation.snapshot(),new_events)

func save_slot(slot: int, automatic: bool = false) -> void:
	var personal: Dictionary={}
	for id in runtimes:personal[id]=runtimes[id].export_state()
	var result:Error=repository.save_slot(slot,{"world":simulation.export_state(),"runtimes":personal,"next_decision":_next_decision,"settings":_public_settings()})
	_slot_cache=repository.slot_summaries()
	if not automatic:ui.set_status(_text("Сессия сохранена в слот %d.","Story saved in slot %d.")%clampi(slot,1,3) if result==OK else _text("Ошибка сохранения: ","Save failed: ")+error_string(result))
	_refresh(false)

func load_slot(slot: int) -> void:
	_set_running(false)
	var envelope:Dictionary=repository.load_slot(slot)
	if envelope.is_empty():ui.set_status(_text("Слот пуст или повреждён.","The slot is empty or damaged."));return
	var data:Dictionary=envelope.data
	if not data.get("world") is Dictionary or not data.get("runtimes") is Dictionary:ui.set_status(_text("Повреждён формат сессии.","The story format is damaged."));return
	var staged=Simulation.new()
	if not staged.import_state(data.world):ui.set_status(_text("Загрузка отклонена: недопустимое состояние мира.","Load rejected: invalid world state."));return
	if not data.get("next_decision",{}) is Dictionary:ui.set_status(_text("Загрузка отклонена: повреждён планировщик.","Load rejected: invalid scheduler."));return
	for id in data.get("next_decision",{}):
		var due:Variant=data.next_decision[id]
		if not staged.state.agents.has(id) or not (due is int or due is float) or not is_finite(float(due)) or float(due)<0.0:
			ui.set_status(_text("Загрузка отклонена: повреждён планировщик.","Load rejected: invalid scheduler."));return
	for id in staged.state.agents:
		if not data.runtimes.get(id) is Dictionary:ui.set_status(_text("Загрузка отклонена: нет личной истории.","Load rejected: personal history is missing."));return
		var candidate=Runtime.new();candidate.configure(id,staged.state.agents[id].profile)
		var valid:bool=candidate.import_state(data.runtimes[id],int(staged.state.run_id));candidate.free()
		if not valid:ui.set_status(_text("Загрузка отклонена: повреждена личная память.","Load rejected: personal memory is damaged."));return
	simulation.import_state(data.world);_make_runtimes()
	advancing=false
	for id in runtimes:runtimes[id].import_state(data.runtimes[id],int(simulation.state.run_id))
	_next_decision=data.get("next_decision",{}).duplicate(true) if data.get("next_decision",{}) is Dictionary else {}
	if not simulation.state.agents.has(selected):selected=str(simulation.state.agents.keys()[0])
	_reviewing=false;world.setup(simulation.snapshot());world.select_agent(selected)
	repository.begin(simulation.snapshot());_last_event_cursor=int(simulation.state.event_cursor)
	_refresh();ui.set_status(_text("Сессия восстановлена. Поколение запросов обновлено; денежный бюджет сохранён.","Story restored. Previous AI requests are invalidated; spending is preserved."))

func start_replay() -> void:
	_set_running(false);repository.flush();_reviewing=true;_replay_cursor=0;_replay_clock=0.0;_display_replay()

func _display_replay() -> void:
	var state:Dictionary=repository.reconstruct(_replay_cursor)
	if state.is_empty():ui.set_status(_text("Повреждён фрагмент журнала.","The journal fragment is damaged."));return
	var validator=Simulation.new()
	if not validator.import_state(state):
		_reviewing=false;ui.set_status(_text("Запись журнала содержит недопустимый мир.","The journal contains an invalid world state."));return
	world.sync_state(state,true);ui.refresh(state,_debug(),_session_info())
	ui.set_status(_text("Воспроизведение %d / %d — без обращений к модели","Replay %d / %d — no model calls")%[_replay_cursor,repository.sequence])

func _debug() -> Dictionary:
	var values:Dictionary={}
	# Only the visible person's inspector consumes this data. Copying all twenty
	# protected histories on each HUD refresh caused avoidable long frames.
	if runtimes.has(selected):values[selected]=runtimes[selected].debug(12)
	return values

func _session_info() -> Dictionary:
	return {"mode":mode,"running":running,"waiting":collecting or _provider_pending,"selected":selected,"settings":_public_settings(),"budget":ledger.status(),"slots":_slot_cache,"replaying":_reviewing,"map_catalog":simulation.get_map_catalog(),"version":ProjectSettings.get_setting("application/config/version","0.2.0"),"observations":_observations,"device_screens":_device_screens,"appearance_presets":appearance_presets,"connection":{"mode":mode,"has_key":not _key.is_empty(),"budget":ledger.status(),"waiting":collecting or _provider_pending}}

func _refresh(update_world: bool = true) -> void:
	if not is_instance_valid(ui) or _reviewing:return
	var state:Dictionary=simulation.snapshot()
	if update_world:world.sync_state(state)
	if not collecting and not advancing and simulation.state.agents.has(selected):
		_observations[selected]=simulation.observe(selected)
		if simulation.has_method("device_screen"):_device_screens[selected]=simulation.device_screen(selected)
	ui.refresh(state,_debug(),_session_info())
	ui.set_connection_state({"mode":mode,"has_key":not _key.is_empty(),"budget":ledger.status(),"waiting":collecting or _provider_pending})

func _public_settings() -> Dictionary:
	return settings.duplicate(true)

func _text(ru:String,en:String) -> String:
	return en if str(settings.language)=="en" else ru

func _ledger_message() -> String:
	match str(ledger.status().storage_error):
		"usage_ledger_in_use":return _text("Бюджет используется другим окном AI Sims. Закройте его перед подключением AI здесь.","Another AI Sims window is using this budget. Close it before connecting AI here.")
		"usage_ledger_lease_lost":return _text("Защита общего бюджета прервана. Перезапустите игру перед продолжением AI.","The shared budget lock was lost. Restart the game before continuing AI.")
		_:return _text("Денежный журнал недоступен. AI остановлен, чтобы сохранить лимит расходов.","The usage ledger is unavailable. AI is paused to preserve the spending limit.")

func _load_settings() -> void:
	if _test_profile:return
	if FileAccess.file_exists("user://appearance_presets.json"):
		var presets=Repository._decode(FileAccess.get_file_as_string("user://appearance_presets.json"))
		if presets is Dictionary:appearance_presets=presets
	var path:="user://release_settings.json"
	if FileAccess.file_exists(path):
		var loaded=Repository._decode(FileAccess.get_file_as_string(path))
		if loaded is Dictionary:
			for key in settings:
				if loaded.has(key) and typeof(loaded[key])==typeof(settings[key]):settings[key]=loaded[key]
	settings.language="en" if str(settings.language)=="en" else "ru"
	if settings.quality not in ["low","medium","high"]:settings.quality="medium"
	settings.speed=clampf(float(settings.speed),0.25,10.0)
	settings.sfx_volume=clampf(float(settings.sfx_volume),0.0,1.0)
	settings.budget=clampf(float(settings.budget),0.01,1000.0 if OS.has_feature("editor") else 1000000.0)

func _save_settings() -> void:
	if not _test_profile:Repository.atomic_write("user://release_settings.json",JSON.stringify(_public_settings()))

func _setup_audio() -> void:
	for name in ["click","success","door","step","message","impact"]:
		var path:String="res://assets/release/audio/"+str(name)+".wav"
		if ResourceLoader.exists(path):
			var player:=AudioStreamPlayer.new();player.stream=load(path);player.volume_db=-14.0;add_child(player);_sounds[name]=player

func _play_sound(name: String) -> void:
	if _test_profile or not _sounds.has(name) or float(settings.sfx_volume)<=0.0:return
	_sounds[name].volume_db=linear_to_db(float(settings.sfx_volume))-10.0;_sounds[name].play()

func _notification(what: int) -> void:
	if what==NOTIFICATION_WM_CLOSE_REQUEST:
		if is_instance_valid(repository):repository.flush()
		if is_instance_valid(ledger):ledger.status()
