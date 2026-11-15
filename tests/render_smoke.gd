extends SceneTree
## Execute with a real renderer. Headless success is deliberately impossible here.

var failures: Array = []
var checks := 0
var game: Node
const OUTPUT = "res://docs/screenshots/"

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		printerr("FAIL render: ", message)
	else:
		print("PASS render: ", message)

func frames(count: int = 3) -> void:
	for frame in count:
		await process_frame
	await RenderingServer.frame_post_draw

func image_hash(image: Image) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(image.get_data())
	return context.finish().hex_encode()

func snapshot_png(name: String) -> void:
	await frames()
	root.get_texture().get_image().save_png(OUTPUT + name + ".png")

func click_control(control: Control) -> void:
	var point: Vector2 = control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	Input.parse_input_event(motion)
	await process_frame
	var press := InputEventMouseButton.new()
	press.position = point
	press.global_position = point
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var release: InputEventMouseButton = press.duplicate()
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Render smoke requires an actual renderer; omit --headless")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await frames(6)
	var state: Dictionary = game.simulation.snapshot()
	check(state.agents.size() == 3, "three agents in actual game")
	var hashes: Array = []
	for id in state.agents:
		var image: Image = game.world_view.capture_agent(id)
		check(not image.is_empty() and image.get_width() == 512, "real 512px individual camera: " + id)
		hashes.append(image_hash(image))
		image.save_png(OUTPUT + "camera_" + id + ".png")
	check(hashes[0] != hashes[1] and hashes[1] != hashes[2] and hashes[0] != hashes[2], "three distinct camera images")
	await snapshot_png("observer_initial")
	await click_control(game.observer_ui._run_button)
	check(game.running, "actual Run button accepts mouse input")
	await click_control(game.observer_ui._run_button)
	check(not game.running, "actual Pause button accepts mouse input")
	# Pixel test: the nearby ration really contributes to Ada's image.
	var visible_before: String = image_hash(game.world_view.capture_agent("ada"))
	var modified: Dictionary = state.duplicate(true)
	modified.items.erase("ration_storage")
	game.world_view.sync_state(modified)
	await frames()
	check(visible_before != image_hash(game.world_view.capture_agent("ada")), "visible ration changes actual camera pixels")
	# Pixel test: a wall occludes the side-room ration, even while the observer
	# may see that hidden room. Compare identical camera pose with/without it.
	modified = state.duplicate(true)
	modified.agents.ada.heading = 180.0
	game.world_view.sync_state(modified)
	await frames()
	var wall_before: String = image_hash(game.world_view.capture_agent("ada"))
	game.world_view.capture_agent("ada").save_png(OUTPUT + "camera_wall_occlusion.png")
	modified.items.erase("ration_hidden")
	game.world_view.sync_state(modified)
	await frames()
	check(wall_before == image_hash(game.world_view.capture_agent("ada")), "hidden ration behind opaque wall contributes zero pixels")
	game.world_view.sync_state(state)
	await frames()
	var overlay_before: String = image_hash(game.world_view.capture_agent("ada"))
	game.world_view.select_agent("cora")
	game.observer_ui.refresh(state, game._debug(), state.events)
	await frames()
	check(overlay_before == image_hash(game.world_view.capture_agent("ada")), "observer selection/UI excluded from agent pixels")
	game.world_view.select_agent("ada")
	# The same composition root and callbacks used by the UI drive these rounds.
	for tick in 12:
		game.observer_ui.step_requested.emit()
		while game.stepping:
			await process_frame
	check(int(game.simulation.snapshot().tick) == 12, "12 sequential executable mock rounds")
	check(game.runtimes.ada.get_memory().size() == 12, "personal observation history accumulates")
	check(not game.runtimes.ada.get_memory()[0].image_png_base64.is_empty(), "personal memory stores real first-person PNG")
	await snapshot_png("observer_running")
	game.observer_ui.agent_selected.emit("boris")
	game.observer_ui.view_toggled.emit(true)
	await snapshot_png("first_person_boris")
	var frozen_tick: int = int(game.simulation.snapshot().tick)
	game.observer_ui.run_toggled.emit(false)
	game._process(10.0)
	await frames()
	check(int(game.simulation.snapshot().tick) == frozen_tick, "pause prevents logical time advance")
	game.observer_ui.save_requested.emit()
	var saved: Dictionary = game.simulation.snapshot()
	var memory_count: int = game.runtimes.ada.get_memory().size()
	game.observer_ui.step_requested.emit()
	while game.stepping:
		await process_frame
	game.observer_ui.load_requested.emit()
	check(int(game.simulation.snapshot().tick) == int(saved.tick), "UI Load restores saved tick")
	check(game.runtimes.ada.get_memory().size() == memory_count, "UI Load restores personal memory")
	var trace_count: int = game.decision_trace.size()
	game.observer_ui.replay_requested.emit()
	check(game.decision_trace.size() == trace_count, "replay makes no model decisions")
	check(int(game._display_state.tick) == 0, "replay begins with recorded initial state")
	game._process(0.7)
	check(int(game._display_state.tick) == 1 and int(game.simulation.snapshot().tick) == int(saved.tick), "replay advances history without changing live authority")
	# Rejected session load is transactional across the world and all memories.
	var session_path: String = game.SAVE_PATH
	var session_file := FileAccess.open(session_path, FileAccess.READ)
	var session_text: String = session_file.get_as_text()
	session_file.close()
	var invalid_session: Dictionary = JSON.parse_string(session_text)
	invalid_session.runtimes.ada.memory.entries[0].self_state = []
	session_file = FileAccess.open(session_path, FileAccess.WRITE)
	session_file.store_string(JSON.stringify(invalid_session))
	session_file.close()
	var before_rejected_load: Dictionary = game.simulation.snapshot()
	game.load_session()
	check(game.simulation.snapshot() == before_rejected_load and game.runtimes.ada.get_memory().size() == memory_count, "invalid personal history cannot partially load a session")
	session_file = FileAccess.open(session_path, FileAccess.WRITE)
	session_file.store_string(session_text)
	session_file.close()
	game.observer_ui.reset_requested.emit()
	check(int(game.simulation.snapshot().tick) == 0 and game.runtimes.ada.get_memory().is_empty(), "UI Reset clears time and personal memory")
	game.observer_ui.step_requested.emit()
	game.observer_ui.reset_requested.emit()
	await frames()
	check(int(game.simulation.snapshot().tick) == 0, "reset invalidates pending render/decision round")
	game.observer_ui.run_toggled.emit(true)
	game.request_step()
	game.observer_ui.run_toggled.emit(false)
	await frames()
	check(int(game.simulation.snapshot().tick) == 0, "pause invalidates pending automatic round")
	# Exercise asynchronous collection with injected responses only. No adapter
	# or environment key is consulted, and no paid HTTP request is possible.
	var run_id: int = int(game.simulation.snapshot().run_id)
	game.stepping = true
	game._real_round = {"generation":game.lifecycle_generation,"run_id":run_id,"tick":0,"actions":{},"expected":["ada","boris","cora"],"record":{"run_id":run_id,"tick":0,"agents":{"ada":{},"boris":{},"cora":{}}}}
	game._on_real_decision("cora", run_id, 0, {"type":"wait"}, {"ok":true,"usage":{"total_tokens":0}})
	game._on_real_decision("cora", run_id, 0, {"type":"take"}, {"ok":true})
	game._on_real_decision("ada", run_id, 999, {"type":"take"}, {"ok":true})
	check(int(game.simulation.snapshot().tick) == 0 and game._real_round.actions.size() == 1, "collector rejects duplicate and mismatched-tick responses")
	game._on_real_decision("ada", run_id, 0, {"type":"wait"}, {"ok":true})
	check(int(game.simulation.snapshot().tick) == 0, "collector waits for all intentions")
	game._on_real_decision("boris", run_id, 0, {"type":"wait"}, {"ok":true})
	check(int(game.simulation.snapshot().tick) == 1 and not game.stepping, "collector commits exactly one complete round")
	game.reset_scenario()
	game._on_real_decision("boris", run_id, 0, {"type":"take"}, {"ok":true})
	check(int(game.simulation.snapshot().tick) == 0, "late collector callback cannot mutate reset session")
	var crawling: Dictionary = game.simulation.snapshot()
	crawling.agents.ada.body.left_leg = "broken"
	crawling.agents.ada.body.right_leg = "broken"
	game.world_view.sync_state(crawling)
	await frames()
	check(is_equal_approx(game.world_view.agent_cameras.ada.position.y, 0.55) and absf(game.world_view.agent_pose_nodes.ada.rotation.x) > 1.0, "crawling camera and actual body pose are both lowered")
	game._refresh()
	game.reset_scenario("last_ration")
	game.observer_ui.view_toggled.emit(false)
	game.observer_ui.agent_selected.emit("ada")
	game.request_step()
	while game.stepping:
		await process_frame
	var contested: Dictionary = game.simulation.snapshot()
	var held_count: int = contested.agents.ada.inventory.count("ration_storage") + contested.agents.boris.inventory.count("ration_storage")
	check(held_count == 1 and contested.agents.ada.last_action.type == "take" and contested.agents.boris.last_action.type == "take", "rendered contention scenario resolves two takes to exactly one ration")
	await snapshot_png("observer_last_ration")
	var report := {"engine":Engine.get_version_info().string,"renderer":RenderingServer.get_video_adapter_name(),"checks":checks,"failures":failures,"paid_api_calls":0}
	var file := FileAccess.open(OUTPUT + "render_report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("RENDER RESULT: ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
