extends Node
## Composition root: only an explicit logical step may change authoritative state.

const Simulation = preload("res://scripts/simulation/world_simulation.gd")
const Runtime = preload("res://scripts/ai/agent_runtime.gd")
const World = preload("res://scripts/world/world_view.gd")
const Interface = preload("res://scripts/ui/observer_ui.gd")

const SAVE_PATH = "user://closed_block.session.json"
const WORLD_STAGE_PATH = "user://closed_block.world-stage.json"
var simulation = Simulation.new()
var world_view: Node3D
var observer_ui: CanvasLayer
var runtimes: Dictionary = {}
var running := false
var stepping := false
var selected_agent := "ada"
var first_person := false
var reviewing := false
var cadence := 0.0
var step_interval := 1.25
var lifecycle_generation := 0
var decision_trace: Array = []
var _display_state: Dictionary = {}
var ai_mode := "mock"
var _remaining_real_requests := 0
var _real_round: Dictionary = {}
var replay_cursor := 0
var replay_target := 0
var replay_cadence := 0.0
var current_scenario := "closed_block"

func _ready() -> void:
	world_view = World.new()
	add_child(world_view)
	observer_ui = Interface.new()
	add_child(observer_ui)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--scenario="):
			var requested: String = argument.trim_prefix("--scenario=")
			if requested in ["closed_block", "last_ration"]:
				current_scenario = requested
	simulation.reset(current_scenario)
	world_view.setup(simulation.snapshot())
	observer_ui.setup(world_view)
	observer_ui.run_toggled.connect(_set_running)
	observer_ui.step_requested.connect(request_step)
	observer_ui.reset_requested.connect(reset_scenario)
	observer_ui.save_requested.connect(save_session)
	observer_ui.load_requested.connect(load_session)
	observer_ui.replay_requested.connect(replay_session)
	observer_ui.agent_selected.connect(_select_agent)
	observer_ui.view_toggled.connect(_set_view)
	_create_runtimes()
	_refresh()
	observer_ui.set_status("Paused · deterministic Mock AI · no API calls")
	if "--auto-run" in OS.get_cmdline_user_args():
		_set_running(true)

func _process(delta: float) -> void:
	if reviewing:
		replay_cadence += delta
		if replay_cadence >= 0.65 and replay_cursor < replay_target:
			replay_cadence = 0.0
			replay_cursor += 1
			_display_replay_tick()
		return
	if running and not stepping:
		cadence += delta
		if cadence >= step_interval:
			cadence = 0.0
			request_step()

func _create_runtimes() -> void:
	for runtime in runtimes.values():
		runtime.cancel_pending()
		runtime.queue_free()
	runtimes.clear()
	var state: Dictionary = simulation.snapshot()
	for id in state.agents:
		var runtime = Runtime.new()
		add_child(runtime)
		runtime.configure(id, state.agents[id].profile)
		runtime.reset(int(state.run_id))
		runtime.decision_ready.connect(_on_real_decision)
		if ai_mode == "real_vlm":
			runtime.configure_real_mode(true, _remaining_real_requests)
		runtimes[id] = runtime

func _set_running(value: bool) -> void:
	if not value and stepping:
		_cancel_round()
	if reviewing:
		reviewing = false
		_refresh()
	running = value
	cadence = 0.0
	observer_ui.set_running(value)
	observer_ui.set_status(("Running · " + ai_mode) if value else "Paused · logical time stopped")

func configure_real_mode(approved: bool, max_requests: int) -> void:
	# Public integration boundary. The shipped UI never calls this function.
	# An operator must first obtain explicit permission and a monetary budget;
	# the finite request allowance is an additional cap, not a cost estimate.
	_set_running(false)
	_cancel_round()
	ai_mode = "real_vlm" if approved and max_requests >= runtimes.size() else "mock"
	_remaining_real_requests = maxi(0, max_requests) if ai_mode == "real_vlm" else 0
	for runtime in runtimes.values():
		runtime.configure_real_mode(ai_mode == "real_vlm", _remaining_real_requests)
	observer_ui.set_ai_mode(ai_mode)
	observer_ui.set_status("Real VLM configured with explicit request cap" if ai_mode == "real_vlm" else "Mock AI · paid API disabled")

func _cancel_round() -> void:
	lifecycle_generation += 1
	_real_round.clear()
	stepping = false
	for runtime in runtimes.values():
		runtime.cancel_pending()

func request_step() -> void:
	if stepping:
		return
	if reviewing:
		reviewing = false
		_refresh()
	stepping = true
	var generation := lifecycle_generation
	var frozen: Dictionary = simulation.snapshot()
	var run_id: int = int(frozen.run_id)
	# Never capture old interpolated poses. WorldView snaps authoritative camera poses.
	world_view.sync_state(frozen)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	else:
		await get_tree().process_frame
	if generation != lifecycle_generation:
		return
	var actions: Dictionary = {}
	var samples: Dictionary = {}
	var record := {"run_id":run_id,"tick":frozen.tick,"mode":ai_mode,"agents":{}}
	for id in runtimes:
		var observation: Dictionary = simulation.observe(id)
		var png := PackedByteArray()
		if not observation.self_state.body.get("blind", false) and DisplayServer.get_name() != "headless":
			var image: Image = world_view.capture_agent(id)
			if image != null and not image.is_empty():
				png = image.save_png_to_buffer()
		var runtime = runtimes[id]
		observation["memory"] = runtime.get_memory()
		runtime.remember(observation, png)
		samples[id] = {"observation":observation,"png":png}
		record.agents[id] = {"observation":_trace_observation(observation),"image_png_base64":"" if png.is_empty() else Marshalls.raw_to_base64(png)}
		if ai_mode == "real_vlm":
			record.agents[id]["payload"] = runtime.build_payload(observation, png)
			continue
		var intention: Dictionary = runtime.decide_mock(observation)
		# The same strict boundary validates diagnostics and network responses.
		var parsed: Dictionary = runtime.parse_response(JSON.stringify(intention))
		actions[id] = parsed.action if parsed.ok else {"type":"wait"}
		record.agents[id]["intent"] = intention
		record.agents[id]["validated"] = parsed
	if ai_mode == "real_vlm":
		if _remaining_real_requests < samples.size():
			stepping = false
			_set_running(false)
			observer_ui.set_status("Approved request allowance exhausted · paused")
			return
		_remaining_real_requests -= samples.size()
		_real_round = {"generation":generation,"run_id":run_id,"tick":int(frozen.tick),"actions":{},"record":record,"expected":samples.keys()}
		# Initialize the entire round before dispatch: disabled adapters can
		# synchronously report failures, whereas live HTTP is asynchronous.
		for id in samples:
			runtimes[id].request_real(samples[id].observation, samples[id].png, run_id)
		return
	_commit_round(actions, record, generation, run_id)

func _on_real_decision(id: String, run_id: int, tick: int, action: Dictionary, diagnostic: Dictionary) -> void:
	if _real_round.is_empty() or not _real_round.expected.has(id):
		return
	if int(_real_round.generation) != lifecycle_generation or int(_real_round.run_id) != run_id or int(_real_round.tick) != tick:
		return
	if _real_round.actions.has(id):
		return
	var parsed: Dictionary = runtimes[id].parse_response(JSON.stringify(action))
	_real_round.actions[id] = parsed.action
	_real_round.record.agents[id]["intent"] = action.duplicate(true)
	_real_round.record.agents[id]["validated"] = parsed
	_real_round.record.agents[id]["provider"] = diagnostic.duplicate(true)
	if _real_round.actions.size() == _real_round.expected.size():
		var ready := _real_round.duplicate(true)
		_real_round.clear()
		_commit_round(ready.actions, ready.record, int(ready.generation), run_id)

func _commit_round(actions: Dictionary, record: Dictionary, generation: int, run_id: int) -> void:
	if generation != lifecycle_generation or int(simulation.snapshot().run_id) != run_id:
		return
	var events: Array = simulation.step(actions, run_id)
	record["events"] = events
	decision_trace.append(record)
	_refresh()
	observer_ui.set_status("Tick %d · %d validated intentions · %s" % [simulation.snapshot().tick, actions.size(), ai_mode])
	stepping = false

func _trace_observation(observation: Dictionary) -> Dictionary:
	var result := observation.duplicate(true)
	result.erase("memory") # Stored once per runtime; avoid quadratic replay archives.
	return result

func reset_scenario(scenario: String = "") -> void:
	_cancel_round()
	running = false
	stepping = false
	reviewing = false
	decision_trace.clear()
	if scenario in ["closed_block", "last_ration"]:
		current_scenario = scenario
	simulation.reset(current_scenario)
	_create_runtimes()
	observer_ui.set_running(false)
	_refresh()
	observer_ui.set_status("Reset · old requests invalidated · paused")

func save_session() -> void:
	var result: int = simulation.save_to(WORLD_STAGE_PATH)
	if result != OK:
		observer_ui.set_status("Save failed: %s" % error_string(result))
		return
	var personal: Dictionary = {}
	for id in runtimes:
		personal[id] = runtimes[id].export_state()
	var archive_file := FileAccess.open(WORLD_STAGE_PATH, FileAccess.READ)
	if archive_file == null:
		observer_ui.set_status("Save failed: could not read staged world archive")
		return
	var archive: String = archive_file.get_as_text()
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		observer_ui.set_status("Save failed: could not write session")
		return
	# A single envelope binds world, personal memory and frames. A stale or
	# partially replaced sidecar can never be silently imported into a new run.
	file.store_string(JSON.stringify({"version":1,"world_archive":archive,"world_sha256":archive.sha256_text(),"runtimes":personal,"trace":decision_trace}))
	observer_ui.set_status("Saved world, journal, personal memory and camera frames")

func load_session() -> void:
	_set_running(false)
	_cancel_round()
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		observer_ui.set_status("Load failed: no saved session")
		return
	var data = JSON.parse_string(file.get_as_text())
	if not _valid_session_envelope(data):
		observer_ui.set_status("Load rejected: invalid session envelope")
		return
	var staged_file := FileAccess.open(WORLD_STAGE_PATH, FileAccess.WRITE)
	if staged_file == null:
		observer_ui.set_status("Load failed: could not stage archive")
		return
	staged_file.store_string(data.world_archive)
	staged_file.close()
	var staged_sim = Simulation.new()
	var result: int = staged_sim.load_from(WORLD_STAGE_PATH)
	if result != OK:
		observer_ui.set_status("Load failed: %s" % error_string(result))
		return
	var state: Dictionary = staged_sim.snapshot()
	for id in state.agents:
		if not data.runtimes.get(id) is Dictionary:
			observer_ui.set_status("Load rejected: missing personal history")
			return
		var staged_runtime = Runtime.new()
		staged_runtime.configure(id, state.agents[id].profile)
		var valid: bool = staged_runtime.import_state(data.runtimes[id], int(state.run_id))
		if valid:
			for entry in staged_runtime.get_memory():
				if int(entry.tick) > int(state.tick):
					valid = false
		staged_runtime.free()
		if not valid:
			observer_ui.set_status("Load rejected: invalid personal history")
			return
	# All components have been validated without changing the live session.
	result = simulation.load_from(WORLD_STAGE_PATH)
	if result != OK:
		observer_ui.set_status("Load failed: %s" % error_string(result))
		return
	_create_runtimes()
	current_scenario = str(simulation.snapshot().scenario)
	for id in runtimes:
		runtimes[id].import_state(data.runtimes[id], int(simulation.snapshot().run_id))
	decision_trace = data.trace.duplicate(true)
	reviewing = false
	_refresh()
	observer_ui.set_status("Loaded saved session · new request generation · paused")

func _valid_session_envelope(data: Variant) -> bool:
	if not data is Dictionary or data.get("version") != 1:
		return false
	if not data.get("world_archive") is String or not data.get("world_sha256") is String:
		return false
	if data.world_archive.sha256_text() != data.world_sha256:
		return false
	if not data.get("runtimes") is Dictionary or not data.get("trace") is Array:
		return false
	for record in data.trace:
		if not record is Dictionary or not record.get("agents") is Dictionary or not record.get("events") is Array:
			return false
	return true

func replay_session() -> void:
	_set_running(false)
	_cancel_round()
	reviewing = true
	replay_cursor = 0
	replay_target = int(simulation.snapshot().tick)
	replay_cadence = 0.0
	_display_replay_tick()

func _display_replay_tick() -> void:
	var replayed: Dictionary = simulation.replay_to(replay_cursor)
	_display_state = replayed
	world_view.sync_state(replayed)
	var debug: Dictionary = _debug()
	for id in debug:
		var past: Array = []
		for memory in debug[id].memory:
			if int(memory.get("tick", -1)) <= replay_cursor:
				past.append(memory)
		debug[id]["memory"] = past
	observer_ui.refresh(replayed, debug, replayed.get("events", []))
	observer_ui.set_status("Replay %d / %d · recorded transitions · zero model calls · Run returns to live" % [replay_cursor, replay_target])

func _select_agent(id: String) -> void:
	if not runtimes.has(id):
		return
	selected_agent = id
	world_view.select_agent(id)
	observer_ui.select_agent(id)
	if reviewing:
		_display_replay_tick()
	else:
		_refresh()

func _set_view(value: bool) -> void:
	first_person = value
	world_view.set_view_mode(value)
	observer_ui.set_view_mode(value)
	if reviewing:
		_display_replay_tick()
	else:
		_refresh()

func _debug() -> Dictionary:
	var data: Dictionary = {}
	for id in runtimes:
		data[id] = runtimes[id].get_debug()
		data[id]["memory"] = runtimes[id].get_memory()
	return data

func _refresh() -> void:
	var state: Dictionary = simulation.snapshot()
	_display_state = state
	world_view.sync_state(state)
	observer_ui.refresh(state, _debug(), state.get("events", []))
