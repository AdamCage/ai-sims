extends SceneTree
## Runs the offline episode against the native renderer. The external script can
## also be passed with --main-pack to exercise the Windows release PCK.
const Main = preload("res://scripts/release_main.gd")
var game: Node
var failures: Array[String] = []
var output: String

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> bool:
	if value:
		print("PASS RESIDENCE: ", message)
	else:
		failures.append(message)
		printerr("FAIL RESIDENCE: ", message)
	return value

func frames() -> void:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw

func capture(name: String) -> void:
	await frames()
	var image := root.get_texture().get_image()
	check(image.get_size() == root.size and image.save_png(output.path_join(name + ".png")) == OK, "captured " + name)

func wait_until(predicate: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()

func press_chapter(text: String) -> bool:
	for child in game.ui._intervention_box.get_children():
		if child is Button and child.text == text:
			child.pressed.emit()
			return true
	return false

func run() -> void:
	output = OS.get_environment("AISIMS_DESKTOP_QA_OUTPUT")
	if output.is_empty() or not output.is_absolute_path() or DisplayServer.get_name() == "headless" or "--test-profile" not in OS.get_cmdline_user_args():
		printerr("Real renderer, absolute AISIMS_DESKTOP_QA_OUTPUT and --test-profile required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output)
	root.borderless = true
	root.position = Vector2i(-4000, -2500)
	root.size = Vector2i(1920, 1080)
	Engine.max_fps = 90
	game = Main.new()
	root.add_child(game)
	await frames()
	check(game.mode == "demo" and game._key.is_empty(), "isolated offline mode")
	var session := "user://residence_desktop_qa_" + str(Time.get_ticks_usec())
	game.repository.save_root = session.path_join("saves")
	game.repository.session_root = session.path_join("sessions")
	await capture("menu")
	game.ui.show_main_menu(false)
	await game.new_session({"map_id": "residence", "count": 8, "scenario": "episode", "seed": 42})
	game._on_command("settings", {"speed": 2.0, "quality": "high"})
	await capture("chapter-one")
	check(game.ui._chapter_popup.visible and game.world.follow_selected, "chapter one opens over the resident camera")
	game.ui._chapter_popup.hide()
	game._on_command("fit_map", {})
	await capture("overview")
	game._on_command("fit_map", {})
	game._on_command("view", {"first_person": true})
	await capture("resident-view")
	game._on_command("view", {"first_person": false})
	game.ui._open_appearance()
	await capture("studio")
	game.ui._appearance_popup.hide()
	game.ui._show_chapter(game.simulation.state.scenario_state, false)
	game.ui._chapter_continue.pressed.emit()
	await capture("observation")
	Engine.time_scale = 10.0
	if await wait_until(func(): return float(game.simulation.state.minute) >= 30.0, 35000):
		await capture("after-thirty-game-minutes")
	if not check(await wait_until(func(): return float(game.simulation.state.minute) >= 240.0, 170000), "reached noon with eight residents"):
		quit(1)
		return
	game._set_running(false)
	await frames()
	game.ui._show_chapter(game.simulation.state.scenario_state, false)
	check(press_chapter("Открыть фонд помощи"), "used the relief fund button")
	game.ui._show_chapter(game.simulation.state.scenario_state, false)
	check(press_chapter("Зафиксировать цену"), "used the price freeze button")
	var story: Dictionary = game.simulation.state.scenario_state
	check(int(story.metrics.interventions) == 2 and story.reserve_fund == 0 and story.triggered.has("aid_fund"), "the relief fund was distributed")
	check(game.simulation.state.economy.prices.ration == 3 and story.triggered.has("price_frozen"), "the ration price was frozen")
	game._set_running(true)
	if not check(await wait_until(func(): return bool(game.simulation.state.scenario_state.completed), 240000), "completed the full day"):
		quit(1)
		return
	Engine.time_scale = 1.0
	await capture("debrief")
	var ending: Dictionary = game.repository.load_slot(3)
	check(bool(ending.get("data", {}).get("world", {}).get("world", {}).get("scenario_state", {}).get("completed", false)), "ending was autosaved")
	var outcome: String = str(game.simulation.state.scenario_state.outcome.id)
	check(press_chapter("Продолжить в песочнице"), "continued through the debrief button")
	check(game.simulation.state.scenario == "sandbox" and game.running, "sandbox resumes the completed world")
	game._set_running(false)
	await game.load_slot(3)
	check(game.simulation.state.scenario == "sandbox" and str(game.simulation.state.completed_episode.outcome.id) == outcome, "saved sandbox retained the ending")
	game._on_command("replay", {})
	await capture("replay")
	check(game._reviewing and game.ui._replay_strip.visible and int(game._replay_state.tick) < int(game.simulation.state.tick), "replay displays actual historical state")
	var report := {"renderer": RenderingServer.get_current_rendering_method(), "version": ProjectSettings.get_setting("application/config/version"), "outcome": outcome, "minutes": game.simulation.state.minute, "failures": failures}
	var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if failures.is_empty() else 1)
