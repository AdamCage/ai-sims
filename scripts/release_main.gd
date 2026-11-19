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
const WebBridge = preload("res://scripts/release_storage/web_bridge.gd")
const DISPLAY_PRESETS := {"1080p": Vector2i(1920, 1080), "1440p": Vector2i(2560, 1440), "2160p": Vector2i(3840, 2160)}

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
var settings := {"language":"ru","quality":"medium","speed":1.0,"sfx_volume":0.5,"model":"~deepseek/deepseek-v4-flash-latest","provider":"byteplus","budget":1000.0,"ai_enabled":false,"display_mode":"windowed","window_preset":"auto","render_scale":1.0,"ui_scale":1.0}
var _key := ""
var _clock := 0.0
var _ui_clock := 0.0
var _single_step := false
var _next_decision: Dictionary = {}
var _last_event_cursor := 0
var _chronicle:Array=[]
var _replay_events:Array=[]
var _slot_cache: Array = []
var _reviewing := false
var _replay_cursor := 0
var _replay_clock := 0.0
var _replay_state: Dictionary = {}
var _replay_paused := false
var _live_view: Dictionary = {}
var _windowed_size := Vector2i.ZERO
var _sounds: Dictionary = {}
var _test_profile := false
var _last_autosave := 0.0
var _observations: Dictionary = {}
var _demo_camera_due:Dictionary={}
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
var _pending_decisions: Dictionary = {}
var _plans: Dictionary = {}
var _decision_states: Dictionary = {}
var _eligible_since: Dictionary = {}
var _blocked_ai: Dictionary = {}
var _sampling := false
var _capture_frame_lock := false
var _effective_speed := 1.0
var _step_expected: Array = []
var _episode_presented := false
var _last_useful_answer_ms := 0
var _web_booted := false
var _map_request := 0
var _loading_map := false
var _ai_pause_reason := ""
var _entered_story := false

func _ready() -> void:
	if WebBridge.is_web():
		set_process(false)
		if not await WebBridge.ensure_map_pack("closed_block",get_tree()):
			push_error("The starting map could not be loaded")
			return
	simulation.personal_experience.connect(_on_personal_experience)
	_test_profile = "--test-profile" in OS.get_cmdline_user_args()
	if _test_profile:
		repository.save_root="user://release_test_profile/saves"
		repository.session_root="user://release_test_profile/sessions"
		_ledger_path="user://release_test_profile/usage.json"
		_presets_path="user://release_test_profile/appearance_presets.json"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://release_test_profile"))
	if WebBridge.is_web():settings.render_scale=0.75
	elif DisplayServer.get_name()!="headless" and RenderingServer.get_current_rendering_method()=="forward_plus":settings.quality="high"
	_load_settings()
	_catalog=ProviderCatalog.new();add_child(_catalog);_catalog.quote_ready.connect(_on_quote_ready)
	ledger.configure(minf(1000.0,float(settings.budget)) if OS.has_feature("editor") else float(settings.budget),_ledger_path,4)
	if not _test_profile:
		_key = credentials.load_key()
	mode="real_vlm" if bool(settings.ai_enabled) or (WebBridge.is_web() and not _key.is_empty()) else "demo"
	world = World.new(); add_child(world)
	ui = Interface.new(); add_child(ui)
	ui.command.connect(_on_command)
	simulation.reset("closed_block",8,"episode",1)
	world.setup(simulation.snapshot())
	_apply_graphics(false)
	if not _test_profile and (settings.display_mode != "windowed" or settings.window_preset != "auto"):
		_apply_window_settings()
	ui.setup(world)
	ui.set_language(str(settings.language))
	_make_runtimes()
	repository.begin(simulation.snapshot())
	_chronicle=simulation.state.events.duplicate(true)
	_last_event_cursor = int(simulation.state.event_cursor)
	_slot_cache = repository.slot_summaries()
	_setup_audio()
	_web_booted=WebBridge.is_web()
	set_process(true)
	_refresh()
	if _web_booted:WebBridge.game_ready()
	ui.set_status(_text("Выберите сценарий. Демонстрационный режим работает без сети.","Choose a scenario. Demo mode works offline."))
	var launch:Dictionary={"map_id":"closed_block","count":8,"scenario":"episode","seed":1}
	var custom_launch:=false
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--agents="):launch.count=int(argument.trim_prefix("--agents="));custom_launch=true
		elif argument.begins_with("--map="):launch.map_id=argument.trim_prefix("--map=");custom_launch=true
		elif argument.begins_with("--scenario="):launch.scenario=argument.trim_prefix("--scenario=");custom_launch=true
		elif argument.begins_with("--seed="):launch.seed=int(argument.trim_prefix("--seed="));custom_launch=true
	if custom_launch:await new_session(launch)
	if "--auto-run" in OS.get_cmdline_user_args():ui.show_main_menu(false);_set_running(true)
	if "--configure-ai" in OS.get_cmdline_user_args():_set_running(false);ui.show_main_menu(false);ui.show_settings()

func _process(delta: float) -> void:
	if _web_booted:
		var command:=WebBridge.poll_command()
		if not command.is_empty():_on_browser_command(command)
	if _loading_map:return
	if _quote_refresh_queued and not _provider_pending and int(ledger.status().active_requests)==0 and _pending_decisions.is_empty() and not _sampling:
		_quote_refresh_queued=false;_request_quote()
	if not advancing and not _sampling and not _deferred_commands.is_empty():
		var queued:Dictionary=_deferred_commands.pop_front();_on_command(queued.name,queued.payload);return
	_ui_clock += delta
	if _ui_clock >= 0.25:
		_ui_clock = 0.0
		_refresh(false)
	if _reviewing:
		if _replay_paused:return
		_replay_clock += delta
		if _replay_clock >= 0.35 and _replay_cursor < repository.sequence:
			_replay_clock = 0.0; _replay_cursor += 1; _display_replay()
		return
	if not advancing and not _sampling and int(simulation.state.event_cursor) != _last_event_cursor:
		_record()
	if (running or _single_step) and not _sampling and not advancing and not _provider_pending and not _quote_refresh_queued:
		collect_decisions()
	if _single_step and not _sampling and _pending_decisions.is_empty():
		var ready := true
		for id in _step_expected:
			if not _plans.has(id) and not _blocked_ai.has(id):ready=false
		if ready and not advancing:
			_apply_plans();advance_world(1.0)
		return
	if not running or advancing or _capture_frame_lock or _provider_pending:return
	_effective_speed=_scheduler_speed()
	if _effective_speed==0.0:return
	_clock += delta * 0.5 * _effective_speed
	_clock=minf(_clock,0.2)
	while _clock >= 0.05 and running and not advancing:
		_clock-=0.05
		_apply_plans()
		advance_world(0.05)

func _scheduler_speed() -> float:
	var requested:float=clampf(float(settings.speed),0.5,2.0)
	if mode != "real_vlm":return requested
	var available:=false
	var living:=0
	for id in simulation.state.agents:
		var actor:Dictionary=simulation.state.agents[id]
		if not actor.alive:continue
		living+=1
		if not actor.busy.is_empty() or _plans.has(id):
			available=true
	if living>0 and not available:
		if _blocked_ai.size()>=living:
			_ai_pause_reason=_text("AI недоступен","AI unavailable")
			running=false
			ui.set_running(false)
			ui.set_status(_text("AI недоступен. Возобновите игру после восстановления соединения.","AI unavailable. Resume when the connection returns."))
			return 0.0
		if not _pending_decisions.is_empty() and Time.get_ticks_msec()-_last_useful_answer_ms>3000:return 0.0
	if _pending_decisions.is_empty():return requested
	var oldest := 0.0
	for packet in _pending_decisions.values():oldest=maxf(oldest,float(Time.get_ticks_msec()-int(packet.started_ms))/1000.0)
	if oldest>40.0:return minf(requested,0.25)
	if oldest>20.0:return minf(requested,0.5)
	return requested

func _on_browser_command(command:Dictionary) -> void:
	match str(command.get("type","")):
		"pause":
			_set_running(false)
			_single_step=false
			if bool(command.get("autosave",true)) and not _loading_map and _entered_story:save_slot(3,true)
		"backup":
			var ok:bool=not _entered_story or save_slot(3,true)==OK
			WebBridge.complete_command(int(command.get("id",-1)),ok)
		"import":
			var imported:bool=repository.import_browser_slots()
			if imported:imported=await WebBridge.save_committed(get_tree())
			WebBridge.complete_command(int(command.get("id",-1)),imported)
			_slot_cache=repository.slot_summaries()
			_refresh(false)
			ui.set_status(_text("Копия восстановлена. Выберите слот.","Backup restored. Select a slot.") if imported else _text("Не удалось импортировать сохранения.","Could not import saves."))

func _on_command(name: String, payload: Dictionary) -> void:
	if _reviewing and name in ["save","god","appearance","intent","scenario_intervention","continue_sandbox"]:
		ui.set_status(_text("Вернитесь в текущий мир кнопкой «Продолжить».","Press Continue to return to the current world."))
		return
	if (advancing or _sampling) and name in ["new_session","step","save","load","replay","replay_event","god","appearance","intent","provider"]:
		_deferred_commands.append({"name":name,"payload":payload.duplicate(true)})
		ui.set_status(_text("Завершаем уже выполненный игровой шаг и его снимки…","Finishing the committed step and its photographs…"));return
	_play_sound("click")
	match name:
		"new_session": new_session(payload)
		"run":
			if _reviewing: _leave_replay()
			_set_running(bool(payload.get("value",not running)))
		"retry_agent":
			var id:=str(payload.get("id",selected))
			if not _reviewing and _blocked_ai.has(id) and mode=="real_vlm":
				_blocked_ai.erase(id)
				_decision_states.erase(id)
				_eligible_since.erase(id)
				_next_decision.erase(id)
				if not running:_set_running(true,false)
				_refresh(false)
		"step":
			if _reviewing:_seek_replay(_replay_cursor+1)
			else:single_step()
		"select":
			var id := str(payload.get("id",selected))
			var displayed:Dictionary=_replay_state if _reviewing else simulation.state
			if displayed.agents.has(id):
				var changed := selected != id
				selected=id
				world.select_agent(id)
				if changed:
					world.follow_selected=false
					if not world.first_person:world.center_agent()
				if _reviewing:_refresh_replay()
				else:_refresh(false)
		"view":
			world.set_first_person(bool(payload.get("first_person",false)))
			if _reviewing:_refresh_replay()
			else:_refresh()
		"save": save_slot(int(payload.get("slot",1)))
		"load": load_slot(int(payload.get("slot",1)))
		"replay": start_replay()
		"replay_event":
			_commit_pending_events()
			var frame: int = repository.frame_for_event(int(payload.get("seq", -1)))
			if frame < 0:ui.set_status(_text("Кадр этого события недоступен.","The frame for this event is unavailable."))
			elif _reviewing:_seek_replay(frame)
			else:start_replay(frame, true)
		"replay_pause":
			if _reviewing:
				_replay_paused=bool(payload.get("paused",not _replay_paused))
				if not _replay_paused and _replay_cursor >= repository.sequence:
					_replay_cursor=0;_display_replay()
				else:_refresh_replay()
		"replay_seek":
			if _reviewing:_seek_replay(int(payload.get("frame",_replay_cursor)))
		"replay_exit": _leave_replay()
		"settings":
			var old_window := [settings.display_mode,settings.window_preset]
			for key in ["language","quality","speed","sfx_volume","display_mode","window_preset","render_scale","ui_scale"]:
				if payload.has(key): settings[key]=payload[key]
			_validate_settings()
			for runtime in runtimes.values():runtime.demo_language=str(settings.language)
			_apply_graphics(old_window != [settings.display_mode,settings.window_preset])
			ui.set_language(str(settings.language));_save_settings()
			if _reviewing:_refresh_replay()
			else:_refresh(false)
		"provider": configure_provider(payload)
		"god": god_intervention(str(payload.get("command","")),payload.get("args",{}))
		"web_connect": WebBridge.connect_router()
		"export_backup","import_backup":
			if WebBridge.is_web():
				if name=="export_backup":WebBridge.request_backup()
				else:WebBridge.request_import()
		"download_report": _download_report()
		"scenario_intervention": god_intervention("episode_intervention",payload)
		"continue_sandbox":
			if god_intervention("continue_sandbox",{}):
				_episode_presented=true
				save_slot(3,true)
				_set_running(true)
		"focus_event":
			var event_actor:=str(payload.get("actor",""))
			var displayed:Dictionary=_replay_state if _reviewing else simulation.state
			if displayed.agents.has(event_actor):
				selected=event_actor
				world.select_agent(selected)
			if payload.get("position") is Array and payload.position.size()==2:
				world.set_first_person(false);world.focus_position(payload.position,true)
			elif displayed.agents.has(event_actor):world.center_agent()
			if _reviewing:_refresh_replay()
			else:_refresh(false)
		"focus_location":
			if payload.get("position") is Array and payload.position.size()==2:
				world.set_first_person(false);world.focus_position(payload.position,true)
				if _reviewing:_refresh_replay()
				else:_refresh(false)
		"fit_map":
			world.toggle_overview()
			if _reviewing:_refresh_replay()
			else:_refresh(false)
		"follow":
			if world.follow_selected:world.follow_selected=false
			else:
				world.set_first_person(false);world.focus_agent()
			if _reviewing:_refresh_replay()
			else:_refresh(false)
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
	if not await _prepare_map(str(config.get("map_id","closed_block"))):return
	advancing=false
	simulation.reset(str(config.get("map_id","closed_block")),clampi(int(config.get("count",8)),3,20),str(config.get("scenario","episode")),int(config.get("seed",1)))
	selected=str(simulation.state.agents.keys()[0])
	_entered_story=true
	_next_decision.clear(); _observations.clear(); _device_screens.clear(); _clock=0.0; _last_autosave=0.0;_episode_presented=false
	_demo_camera_due.clear()
	world.set_first_person(false);world.setup(simulation.snapshot()); world.select_agent(selected)
	_frame_residential_episode()
	_make_runtimes(); repository.begin(simulation.snapshot()); _last_event_cursor=int(simulation.state.event_cursor)
	_chronicle=simulation.state.events.duplicate(true)
	_refresh(); ui.set_status(_text("Новая сессия готова. Нажмите «Продолжить», чтобы начать.","A new story is ready. Press Continue to begin."))

func _frame_residential_episode() -> void:
	if world.first_person or simulation.state.map_id != "residence":
		return
	if simulation.state.scenario == "common_house" or simulation.state.get("completed_episode", {}).get("id") == "common_house":
		world.frame_story_start()

func _make_runtimes() -> void:
	for runtime in runtimes.values(): runtime.cancel_pending(); runtime.queue_free()
	runtimes.clear()
	for id in simulation.state.agents:
		var runtime=Runtime.new(); add_child(runtime)
		runtime.demo_language=str(settings.language)
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
		_single_step=false
		_provider_pending=false;running=false;ui.set_running(false);ui.set_status(_text("Не удалось проверить тариф и поддержку выбранной модели.","Could not verify the model tariff and capabilities."))
	else:ui.set_status(_text("Проверяем изображения, тариф и доступного провайдера RouterAI…","Checking images, tariff and RouterAI provider…"))

func _on_quote_ready(tag: int, quote: Dictionary) -> void:
	if tag!=_catalog_tag:return
	_provider_pending=false
	if not bool(quote.get("ok",false)):
		_single_step=false
		running=false;ui.set_running(false);ui.set_status("RouterAI: "+str(quote.get("error","Не удалось проверить модель")));return
	_quote=quote.duplicate(true)
	for runtime in runtimes.values():runtime.configure_provider(_provider_config())
	ui.set_status(_text("RouterAI готов. Провайдер и тариф проверены, бюджет %.2f ₽.","RouterAI is ready. Provider and tariff checked; budget %.2f RUB.")%float(ledger.status().remaining_rub))
	_refresh(false)
	if _single_step and not running:collect_decisions.call_deferred()

func _set_running(value: bool, retry_blocked: bool=true) -> void:
	if value and _loading_map:return
	_single_step=false
	_step_expected.clear()
	if not value:_quote_refresh_queued=false
	if value and mode=="real_vlm" and not str(ledger.status().storage_error).is_empty():
		running=false;ui.set_running(false);ui.set_status(_ledger_message());return
	if value and mode=="real_vlm" and _key.is_empty():
		running=false;ui.set_running(false);ui.show_settings();ui.set_status(_text("Нужен личный ключ RouterAI. Сетевой режим сохранён; демонстрация не подменяет AI.","Your RouterAI key is required. Real AI remains selected."));return
	if value:
		_entered_story=true
		if retry_blocked:
			for id in _blocked_ai:_decision_states.erase(id)
			_blocked_ai.clear()
		_ai_pause_reason=""
		_last_useful_answer_ms=Time.get_ticks_msec()
	_reviewing=false; running=value; _clock=0.0
	ui.set_running(value)
	if value: ui.set_status(_text("Симуляция: реальная VLM","Simulation: real VLM") if mode=="real_vlm" else _text("Демонстрация без сети","Offline demo"))
	else: ui.set_status(_text("Пауза: игровое время остановлено","Paused: game time is stopped"))
	_refresh()

func _invalidate() -> void:
	generation += 1
	collecting=false;_single_step=false;_quote_refresh_queued=false
	_sampling=false;_capture_frame_lock=false;_step_expected.clear()
	_pending_decisions.clear();_plans.clear();_decision_states.clear();_eligible_since.clear();_blocked_ai.clear()
	for runtime in runtimes.values():runtime.cancel_pending()

func _decision_ids() -> Array:
	var ids: Array=[]
	var now:=Time.get_ticks_msec()
	for id in simulation.state.agents:
		var actor: Dictionary=simulation.state.agents[id]
		if actor.alive and not actor.sleeping and not actor.unconscious and actor.busy.is_empty() and not _plans.has(id) and not _pending_decisions.has(id) and not _blocked_ai.has(id) and float(simulation.state.minute)>=float(_next_decision.get(id,-1.0)):
			ids.append(id)
			if not _eligible_since.has(id):_eligible_since[id]=now
	ids.sort_custom(func(a,b):
		if _eligible_since[a]==_eligible_since[b]:return str(a)<str(b)
		return int(_eligible_since[a])<int(_eligible_since[b]))
	return ids

func single_step() -> void:
	_set_running(false);_single_step=true
	_step_expected=_decision_ids()
	if _step_expected.is_empty() and _pending_decisions.is_empty():_apply_plans();advance_world(1.0)
	else:collect_decisions()

func collect_decisions() -> void:
	# Capture and dispatch one person at a time; rendering waits never become a
	# barrier for the other persons' already accepted movement and actions.
	if _sampling or advancing or _provider_pending or _quote_refresh_queued:return
	if not running and not _single_step:
		_single_step=true;_step_expected=_decision_ids()
	var ids:=_decision_ids()
	if ids.is_empty():return
	if mode=="real_vlm":
		if _quote.is_empty() or float(_quote.get("expires_at",0.0))<=Time.get_unix_time_from_system()+120.0:
			_quote_refresh_queued=true
			if int(ledger.status().active_requests)==0 and _pending_decisions.is_empty():_quote_refresh_queued=false;_request_quote()
			return
		if _pending_decisions.size()>=4 or int(ledger.status().active_requests)>=4:return
	var id:String=str(ids[0])
	var ticket:=generation
	var run_id:=int(simulation.state.run_id)
	_sampling=true;collecting=true
	_pending_decisions[id]={"generation":ticket,"run_id":run_id,"tick":int(simulation.state.tick),"started_ms":Time.get_ticks_msec(),"phase":"capture"}
	_decision_states[id]={"state":"capturing","waiting_since":Time.get_ticks_msec()}
	var observation:Dictionary=simulation.observe(id)
	var refs:Dictionary=simulation.capture_observation_refs(id) if simulation.has_method("capture_observation_refs") else {}
	var slots:Array=simulation.state.agents[id].inventory.duplicate()
	var png:=PackedByteArray()
	# The deterministic policy uses the simulation's occluded personal view.
	# Store periodic real camera memories in demo; every sighted VLM request
	# still captures the exact pose and frame of its own decision.
	var capture_needed:=mode=="real_vlm" or float(observation.minute)>=float(_demo_camera_due.get(id,0.0))
	var render_capture:bool=capture_needed and not observation.self_state.body.blind and DisplayServer.get_name()!="headless"
	if render_capture:
		world.sync_state(simulation.state,true)
		world.set_perception_candidates(id,simulation.perception_candidates(id))
		_capture_frame_lock=true
		world.prepare_capture(id)
		await RenderingServer.frame_post_draw
		if ticket!=generation:return
		var image:Image=world.capture_agent(id)
		observation=world.enrich_observation(id,observation)
		_capture_frame_lock=false
		if image!=null and not image.is_empty():png=await PNGEncoder.encode(image,get_tree())
		if ticket!=generation:return
		if mode=="demo" and not png.is_empty():_demo_camera_due[id]=float(observation.minute)+15.0
		if mode=="real_vlm" and not png.is_empty() and not observation.targets.is_empty():
			var grounding:Image=await world.grounding_image(image,observation.targets)
			if ticket!=generation:return
			if grounding!=null and not grounding.is_empty():
				observation["grounding_png"]=await PNGEncoder.encode(grounding,get_tree())
				if ticket!=generation:return
				observation["grounding_source_hash"]=Media.digest_bytes(png)
	if render_capture and simulation.has_method("device_screen"):
		var screen:Dictionary=simulation.device_screen(id)
		if not screen.is_empty() and not str(screen.get("text","")).is_empty():
			world.prepare_device_screen(str(screen.get("title","")),str(screen.text))
			await RenderingServer.frame_post_draw
			if ticket!=generation:return
			var screen_image:Image=world.capture_device_screen()
			if screen_image!=null and not screen_image.is_empty():observation["screen_png"]=await PNGEncoder.encode(screen_image,get_tree())
			if ticket!=generation:return
	var grants:Array=PersonalMemory.granted_images(PersonalMemory.personal_context(observation))
	if not grants.is_empty():observation["viewed_image_ref"]=grants[-1]
	if ticket!=generation:return
	if not running and not _single_step:
		_pending_decisions.erase(id);_decision_states.erase(id);_sampling=false
		collecting=not _pending_decisions.is_empty()
		return
	if simulation.has_method("restrict_observation_refs"):
		refs=simulation.restrict_observation_refs(id,refs,observation.get("targets",[]))
	var packet:Dictionary=_pending_decisions[id]
	packet.merge({"tick":int(observation.tick),"minute":float(observation.minute),"refs":refs,"slots":slots,"phase":"request"},true)
	_observations[id]=observation.duplicate(true)
	_sampling=false
	if mode=="demo":
		runtimes[id].observe(observation,png)
		var action:Dictionary=runtimes[id].decide_demo(observation)
		_on_decision(id,run_id,int(observation.tick),action,{"ok":true,"steps":[action],"intent":runtimes[id].declared_intent,"mode":"demo"})
	else:
		_decision_states[id]={"state":"thinking","waiting_since":int(packet.started_ms)}
		runtimes[id].request_decision(observation,png,run_id)
	collecting=_sampling or not _pending_decisions.is_empty()

func _dispatch_real() -> void:
	if running or _single_step:collect_decisions()

func _on_decision(id:String,run_id:int,tick:int,action:Dictionary,diagnostic:Dictionary) -> void:
	if not _pending_decisions.has(id):return
	var packet:Dictionary=_pending_decisions[id]
	if int(packet.generation)!=generation or int(packet.run_id)!=run_id or int(packet.tick)!=tick:return
	_pending_decisions.erase(id)
	collecting=_sampling or not _pending_decisions.is_empty()
	if not bool(diagnostic.get("ok",true)):
		var reason:=str(diagnostic.get("error","Ошибка AI"))
		_blocked_ai[id]=reason;_decision_states[id]={"state":"error","reason":reason}
		ui.set_status(_text("Персонаж ждёт восстановления AI: ","Person is waiting for AI recovery: ")+reason)
		if reason.to_lower().contains("budget") or reason.to_lower().contains("ledger") or reason.to_lower().contains("balance"):
			_ai_pause_reason=reason
			_single_step=false;running=false;ui.set_running(false)
		return
	var steps:Array=diagnostic.get("steps",[action]).duplicate(true)
	if steps.is_empty():steps=[action.duplicate(true)]
	_plans[id]={"steps":steps,"index":0,"refs":packet.get("refs",{}),"slots":packet.get("slots",[]),"minute":packet.get("minute",simulation.state.minute),"expires":float(packet.get("minute",simulation.state.minute))+60.0,"intent":str(diagnostic.get("intent","")),"awaiting":false,"received":"","acquisition_ticket":"","next_ms":0}
	_decision_states[id]={"state":"ready","intent":str(diagnostic.get("intent",""))}
	_eligible_since.erase(id);_last_useful_answer_ms=Time.get_ticks_msec()

func _apply_plans() -> void:
	for id in _plans.keys():
		if not simulation.state.agents.has(id):_plans.erase(id);continue
		var actor:Dictionary=simulation.state.agents[id]
		var plan:Dictionary=_plans[id]
		if not actor.alive or actor.unconscious:
			_plans.erase(id)
			continue
		if bool(plan.awaiting) or not actor.busy.is_empty() or Time.get_ticks_msec()<int(plan.next_ms):continue
		if int(plan.index)>0 and not bool(actor.last_result.get("ok",true)):
			_decision_states[id]={"state":"replanning","reason":str(actor.last_result.get("message",""))}
			_plans.erase(id)
			continue
		if int(plan.index)>=plan.steps.size() or float(simulation.state.minute)>float(plan.expires):
			_plans.erase(id);_next_decision[id]=float(simulation.state.minute)+0.5;continue
		var action:Dictionary=plan.steps[int(plan.index)].duplicate(true)
		if action.has("slot"):
			var item_id:=""
			if action.slot is String and action.slot=="received":
				item_id=str(plan.received)
				if item_id.is_empty() and not str(plan.acquisition_ticket).is_empty():
					item_id=simulation.acquisition_receipt(id,plan.acquisition_ticket)
					if item_id.is_empty():continue
			elif action.slot is int or action.slot is float:
				var original_slot:=int(action.slot)
				if original_slot>=0 and original_slot<plan.slots.size():item_id=str(plan.slots[original_slot])
			var current_slot:int=actor.inventory.find(item_id)
			if current_slot<0:
				_decision_states[id]={"state":"replanning","reason":_text("Предмет больше недоступен.","The item is no longer available.")};_plans.erase(id);continue
			action.slot=current_slot
		var result:Dictionary
		result=simulation.submit_observed(id,action,plan.refs,int(simulation.state.run_id),float(plan.minute))
		if not result.ok:
			_decision_states[id]={"state":"replanning","reason":str(result.reason)};_plans.erase(id);_next_decision[id]=float(simulation.state.minute)+1.0;continue
		plan.awaiting=true;plan.submitted_tick=int(simulation.state.tick);plan.action=action

func _update_plan_outcomes() -> void:
	for id in _plans.keys():
		var plan:Dictionary=_plans[id]
		if not bool(plan.get("awaiting",false)) or int(simulation.state.tick)<=int(plan.submitted_tick):continue
		var actor:Dictionary=simulation.state.agents[id]
		plan.awaiting=false
		if not bool(actor.last_result.get("ok",false)):
			_decision_states[id]={"state":"replanning","reason":str(actor.last_result.get("message",""))};_plans.erase(id);_next_decision[id]=float(simulation.state.minute)+1.0;continue
		if plan.action.type in ["take","buy","request_ration","interact","join_queue"]:
			plan.received=str(actor.get("last_acquired_item",""))
			plan.acquisition_ticket=str(actor.get("last_acquisition_ticket","")) if plan.action.type=="join_queue" else ""
		plan.index=int(plan.index)+1
		plan.next_ms=Time.get_ticks_msec()+(800 if plan.action.type in ["speak","use_device","read_screen","take","give"] else 150)
		_decision_states[id]={"state":"acting","intent":str(plan.intent),"step":int(plan.index),"total":plan.steps.size()}

func advance_world(minutes: float) -> void:
	if advancing:return
	advancing=true
	var committed_run:=int(simulation.state.run_id)
	var events: Array=simulation.advance(minutes)
	_update_plan_outcomes()
	# The logical transition is already committed. Journal it before any render
	# await so pause/reset cannot erase an executed action from the history.
	_record()
	for event in events:
		if bool(event.get("ok",false)) and event.type=="set_goal" and runtimes.has(str(event.actor)):
			runtimes[str(event.actor)].apply_intervention("goal",{"goal":simulation.state.agents[event.actor].profile.goal})
	world.sync_state(simulation.state,not running)
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
	var scenario:Dictionary=simulation.state.get("scenario_state",{})
	if bool(scenario.get("completed",false)) and not _episode_presented:
		_episode_presented=true;running=false;ui.set_running(false);_refresh(false)
		_last_autosave=float(simulation.state.minute)
		if save_slot(3,true)!=OK:ui.set_status(_text("Не удалось автоматически сохранить итог. Скачайте копию из меню сохранений.","The ending could not be autosaved. Download a backup from Saves."))
		if ui.has_method("show_debrief"):ui.show_debrief(scenario)
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

func god_intervention(command_name: String, args: Dictionary) -> bool:
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
	return bool(result.ok)

func _prepare_map(map_id:String) -> bool:
	if not WebBridge.is_web():return true
	_map_request+=1
	var request:=_map_request
	_loading_map=true
	var ok:=await WebBridge.ensure_map_pack(map_id,get_tree())
	if request!=_map_request:return false
	_loading_map=false
	if not ok:ui.set_status(_text("Не удалось загрузить карту. Проверьте соединение и повторите выбор.","Map download failed. Check the connection and select it again."))
	return ok

func _download_report() -> void:
	_commit_pending_events()
	var state:Dictionary=_replay_state if _reviewing else simulation.state
	var story:Dictionary=state.get("scenario_state",state.get("completed_episode",{}))
	if state.get("scenario")=="sandbox" and state.has("completed_episode"):story=state.completed_episode
	var report:={"map":state.get("map_name",""),"minute":state.minute,"story":story.get("title",""),"phase":story.get("phase_title",""),"outcome":story.get("outcome",{}),"summary":story.get("debrief",[]),"metrics":story.get("metrics",{}),"events":_replay_events if _reviewing else _chronicle}
	var contents:=JSON.stringify(report,"\t")
	if WebBridge.is_web():
		JavaScriptBridge.download_buffer(contents.to_utf8_buffer(),"AI-Sims-story.json","application/json")
		return
	var path:=OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS).path_join("AI-Sims-story-%d.json"%int(Time.get_unix_time_from_system()))
	var err:=Repository.atomic_write(path,contents)
	ui.set_status(_text("Отчёт сохранён в ","Story report saved to ")+path if err==OK else error_string(err))

func configure_provider(config: Dictionary) -> void:
	_set_running(false)
	_invalidate()
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
	var events:Array=simulation.state.events
	var first:=events.size()
	while first>0 and int(events[first-1].seq)>=_last_event_cursor:
		first-=1
	if first<events.size():new_events=events.slice(first)
	_chronicle.append_array(new_events)
	_last_event_cursor=int(simulation.state.event_cursor)
	repository.record(simulation.state,new_events)

func save_slot(slot: int, automatic: bool = false) -> Error:
	_commit_pending_events()
	var personal: Dictionary={}
	for id in runtimes:personal[id]=runtimes[id].export_state()
	var result:Error=repository.save_slot(slot,{"world":simulation.export_state(),"runtimes":personal,"next_decision":_next_decision,"settings":_public_settings()})
	_slot_cache=repository.slot_summaries()
	if not automatic:ui.set_status(_text("Сессия сохранена в слот %d.","Story saved in slot %d.")%clampi(slot,1,3) if result==OK else _text("Ошибка сохранения: ","Save failed: ")+error_string(result))
	_refresh(false)
	return result

func load_slot(slot: int) -> void:
	if not _reviewing:_set_running(false)
	var envelope:Dictionary=repository.load_slot(slot)
	if envelope.is_empty():ui.set_status(_text("Слот пуст или повреждён.","The slot is empty or damaged."));return
	var data:Dictionary=envelope.data
	if not data.get("world") is Dictionary or not data.get("runtimes") is Dictionary:ui.set_status(_text("Повреждён формат сессии.","The story format is damaged."));return
	var staged=Simulation.new()
	if not staged.import_state(data.world):ui.set_status(_text("Загрузка отклонена: недопустимое состояние мира.","Load rejected: invalid world state."));return
	if not await _prepare_map(str(staged.state.map_id)):return
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
	if not repository.resume_from_slot(staged.snapshot(),data.get("replay",{})):
		ui.set_status(_text("Не удалось открыть запись этой истории.","The history for this save could not be opened."))
		return
	_invalidate();simulation.import_state(data.world);_make_runtimes()
	advancing=false
	for id in runtimes:runtimes[id].import_state(data.runtimes[id],int(simulation.state.run_id))
	_entered_story=true
	_next_decision=data.get("next_decision",{}).duplicate(true) if data.get("next_decision",{}) is Dictionary else {}
	_last_autosave=float(simulation.state.minute)
	_observations.clear();_device_screens.clear()
	_demo_camera_due.clear()
	if not simulation.state.agents.has(selected):selected=str(simulation.state.agents.keys()[0])
	_reviewing=false;_replay_state={};_replay_events=[];_live_view.clear()
	_episode_presented=bool(simulation.state.get("scenario_state",{}).get("completed",false));world.setup(simulation.snapshot());world.select_agent(selected)
	_frame_residential_episode()
	_last_event_cursor=int(simulation.state.event_cursor)
	_chronicle=repository.events_through(repository.sequence)
	_refresh();ui.set_status(_text("Сессия восстановлена. Поколение запросов обновлено; денежный бюджет сохранён.","Story restored. Previous AI requests are invalidated; spending is preserved."))

func _commit_pending_events() -> void:
	if not _reviewing and int(simulation.state.event_cursor) != _last_event_cursor:
		_record()

func start_replay(frame: int = 0, paused: bool = false) -> void:
	if not _reviewing:
		_commit_pending_events()
		_live_view={"selected":selected,"camera":world.snapshot_camera()}
		_set_running(false)
		_invalidate()
		_replay_state={}
		_replay_events=[]
		_reviewing=true
	_replay_paused=paused
	_replay_cursor=clampi(frame,0,repository.sequence)
	_replay_clock=0.0
	_display_replay()

func _seek_replay(frame: int) -> void:
	_replay_paused=true
	_replay_cursor=clampi(frame,0,repository.sequence)
	_replay_clock=0.0
	_display_replay()

func _leave_replay() -> void:
	if not _reviewing:return
	_reviewing=false
	_replay_state={}
	_replay_events=[]
	selected=str(_live_view.get("selected",selected))
	world.reset_action_feedback()
	world.sync_state(simulation.snapshot(),true)
	world.select_agent(selected)
	world.restore_camera(_live_view.get("camera",{}))
	_live_view.clear()
	_set_running(false)

func _display_replay() -> void:
	var state:Dictionary=repository.reconstruct(_replay_cursor)
	if state.is_empty():
		_leave_replay();ui.set_status(_text("Повреждён фрагмент журнала.","The journal fragment is damaged."));return
	var validator=Simulation.new()
	if not validator.import_state(state):
		_leave_replay();ui.set_status(_text("Запись журнала содержит недопустимый мир.","The journal contains an invalid world state."));return
	if _replay_state.is_empty() or int(state.get("event_cursor",0)) < int(_replay_state.get("event_cursor",0)):
		world.reset_action_feedback()
	_replay_state=state
	var event_count: int = repository.event_count_through(_replay_cursor)
	if event_count < _replay_events.size():_replay_events.resize(event_count)
	else:_replay_events.append_array(repository.events_slice(_replay_events.size(),event_count))
	world.sync_state(state,true)
	if _replay_cursor>=repository.sequence:_replay_paused=true
	_refresh_replay()
	ui.set_status(_text("Воспроизведение %d / %d — без обращений к модели","Replay %d / %d — no model calls")%[_replay_cursor,repository.sequence])

func _refresh_replay() -> void:
	if not _replay_state.is_empty():ui.refresh(_replay_state,{},_session_info(_replay_state))

func _debug() -> Dictionary:
	var values:Dictionary={}
	# Only the visible person's inspector consumes this data. Copying all twenty
	# protected histories on each HUD refresh caused avoidable long frames.
	if runtimes.has(selected):values[selected]=runtimes[selected].debug(12)
	return values

func _session_info(replay:Dictionary={}) -> Dictionary:
	var historical:=not replay.is_empty()
	var shown:Dictionary=replay if historical else simulation.state
	var waiting:bool=not historical and (collecting or _provider_pending)
	var statuses:Dictionary={}
	for id in shown.agents:
		var status:Dictionary=shown.agents[id].get("activity_status",{}).duplicate(true)
		if not historical:
			status["decision"]=_decision_states.get(id,{}).duplicate(true)
			status["ai_state"]=str(status.decision.get("state","queued" if _eligible_since.has(id) else ""))
			if status.decision.has("reason"):status["blocked_reason"]=str(status.decision.reason)
			if _plans.has(id):status["intent"]=str(_plans[id].intent)
		statuses[id]=status
	var budget:Dictionary=ledger.status()
	return {
		"mode":mode,"running":running,"waiting":waiting,"selected":selected,"settings":_public_settings(),
		"budget":budget,"slots":_slot_cache,"replaying":historical,"map_catalog":simulation.get_map_catalog(),
		"version":ProjectSettings.get_setting("application/config/version"),"scenario":shown.get("scenario_state",{}),
		"chronicle_events":_replay_events if historical else _chronicle,
		"replay_frame":_replay_cursor,"replay_length":repository.sequence,"replay_paused":_replay_paused,"replay_first_event":repository.first_replay_event(),
		"replay_event_frames":repository.event_frame_index(),
		"observations":{} if historical else _observations,"device_screens":{} if historical else _device_screens,
		"agent_statuses":statuses,"decision_states":{} if historical else _decision_states,"appearance_presets":appearance_presets,
		"effective_speed":_effective_speed,"web":_web_booted,"display_presets":_display_presets(),"display_pixels":get_window().size,
		"connection":{"mode":mode,"has_key":not _key.is_empty(),"budget":budget,"waiting":waiting,"pause_reason":_ai_pause_reason}
	}

func _refresh(update_world: bool = true) -> void:
	if not is_instance_valid(ui) or _reviewing:return
	var state:Dictionary=simulation.snapshot()
	if update_world:world.sync_state(state)
	if simulation.state.agents.has(selected) and simulation.has_method("device_screen"):
		_device_screens[selected]=simulation.device_screen(selected)
	ui.refresh(state,_debug(),_session_info())
	if _web_booted:
		WebBridge.interface().playtestContext(str(ProjectSettings.get_setting("application/config/version")),str(state.map_id),mode,str(settings.language))

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
	_validate_settings()
	settings.budget=clampf(float(settings.budget),0.01,1000.0 if OS.has_feature("editor") else 1000000.0)

func _validate_settings() -> void:
	settings.language="en" if str(settings.language)=="en" else "ru"
	if settings.quality not in ["low","medium","high"]:settings.quality="medium"
	settings.speed=clampf(float(settings.speed),0.5,2.0)
	settings.sfx_volume=clampf(float(settings.sfx_volume),0.0,1.0)
	if settings.display_mode not in ["windowed","fullscreen"]:settings.display_mode="windowed"
	if not DISPLAY_PRESETS.has(settings.window_preset):settings.window_preset="auto"
	settings.render_scale=float(settings.render_scale)
	if settings.render_scale not in [0.5,0.75,1.0]:settings.render_scale=0.75 if WebBridge.is_web() else 1.0
	settings.ui_scale=clampf(float(settings.ui_scale),0.85,1.3)

func _display_presets() -> Array[String]:
	var presets: Array[String]=["auto"]
	if WebBridge.is_web() or DisplayServer.get_name()=="headless":return presets
	var window:=get_window()
	var usable:=DisplayServer.screen_get_usable_rect(window.current_screen).size
	var frame:=Vector2i(16,40) if window.mode==Window.MODE_FULLSCREEN else (window.get_size_with_decorations()-window.size).max(Vector2i.ZERO)
	for key in DISPLAY_PRESETS:
		var size:Vector2i=DISPLAY_PRESETS[key]+frame
		if size.x<=usable.x and size.y<=usable.y:presets.append(key)
	return presets

func _apply_graphics(apply_window: bool) -> void:
	get_window().content_scale_factor=float(settings.ui_scale)
	world.set_render_scale(float(settings.render_scale))
	world.set_quality(str(settings.quality))
	if apply_window:_apply_window_settings()

func _apply_window_settings() -> void:
	if WebBridge.is_web() or DisplayServer.get_name()=="headless":return
	var window:=get_window()
	if settings.display_mode=="fullscreen":
		if window.mode==Window.MODE_WINDOWED:_windowed_size=window.size
		window.mode=Window.MODE_FULLSCREEN
		return
	var was_fullscreen:=window.mode==Window.MODE_FULLSCREEN
	window.mode=Window.MODE_WINDOWED
	if settings.window_preset in _display_presets() and DISPLAY_PRESETS.has(settings.window_preset):
		window.size=DISPLAY_PRESETS[settings.window_preset]
		var usable:=DisplayServer.screen_get_usable_rect(window.current_screen)
		window.position=usable.position+(usable.size-window.get_size_with_decorations())/2
	elif was_fullscreen and _windowed_size!=Vector2i.ZERO:
		window.size=_windowed_size

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
