extends RefCounted

const Simulation = preload("res://scripts/simulation/world_simulation.gd")
var failures: Array = []
var checks := 0


func run() -> Array:
	failures = []
	checks = 0
	_test_initial_and_isolation()
	_test_actions_and_conservation()
	_test_contested_ration()
	_test_walls_and_movement()
	_test_body_rules()
	_test_speech_and_stale()
	_test_persistence()
	_test_invalid_loaded_poses()
	_test_invalid_actions()
	print("Simulation: %d checks; %d failures" % [checks, failures.size()])
	return failures


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL simulation: " + message)


func _test_initial_and_isolation() -> void:
	var sim = Simulation.new()
	_check(sim.state.agents.size() == 3, "three distinct agents spawn")
	var ada: Dictionary = sim.observe("ada")
	var boris: Dictionary = sim.observe("boris")
	_check(_view_has(ada, "ration pack"), "Ada sees the storage ration")
	_check(not _view_has(boris, "ration pack"), "Boris cannot see behind his gaze / storage wall")
	_check(not _view_has(ada, "sealed ration pack"), "side room ration is occluded")
	var encoded := JSON.stringify(boris)
	for forbidden in ["ration_hidden", "ration_storage", "side_door", "geometry", "position", "run_id", "events"]:
		_check(not encoded.contains(forbidden), "observation excludes privileged field/id: " + forbidden)
	ada.self_state.needs.hunger = 9999.0
	_check(sim.state.agents.ada.needs.hunger < 100.0, "observations are detached copies")
	sim.state.agents.ada.body.blind = true
	_check(sim.observe("ada").mock_view.is_empty(), "blind agents get no visual descriptors")
	var copy: Dictionary = sim.snapshot()
	copy.agents.ada.position[0] = 999
	_check(sim.state.agents.ada.position[0] != 999, "snapshots cannot mutate authority")


func _test_actions_and_conservation() -> void:
	var sim = Simulation.new()
	var total: int = sim.state.items.size()
	sim.step({"ada": {"type": "take"}})
	_check(sim.state.agents.ada.inventory.size() == 1, "take changes authoritative inventory")
	_check(sim.state.items.ration_storage.holder == "ada", "item holder matches take")
	sim.state.agents.boris.position = [5.0, -3.2]
	sim.step({"ada": {"type": "give", "slot": 0}})
	_check(sim.state.agents.boris.inventory.has("ration_storage"), "give transfers one item")
	_check(sim.state.agents.ada.inventory.is_empty(), "giver loses transferred item")
	sim.step({"boris": {"type": "put", "slot": 0}})
	_check(sim.state.items.ration_storage.holder == "", "put returns item to world")
	_check(sim.state.agents.boris.inventory.is_empty(), "put clears inventory")
	_check(sim.state.items.size() == total, "take/give/put conserve item count")
	_check(_conserved(sim.state), "all holder/inventory relationships remain unique")
	# Tick 1 gives Boris priority. A target selected from the frozen world must
	# still be in reach when Ada's give is applied after Boris walks away.
	sim.reset()
	sim.step({"ada": {"type": "take"}})
	sim.state.agents.boris.position = [5.0, -3.2]
	sim.state.agents.boris.heading = -90.0
	sim.step({"ada": {"type": "give", "slot": 0},
		"boris": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(not sim.state.agents.ada.last_result.ok, "give rechecks recipient's current reach after earlier movement")
	_check(sim.state.agents.ada.inventory.has("ration_storage"), "failed out-of-range give retains item")


func _test_contested_ration() -> void:
	var sim = Simulation.new()
	sim.reset("last_ration")
	sim.step({"boris": {"type": "take"}, "ada": {"type": "take"}})
	_check(sim.state.agents.ada.inventory.size() + sim.state.agents.boris.inventory.size() == 1,
		"contested last ration is never duplicated")
	_check(not sim.state.agents.boris.last_result.ok, "second claimant receives rejection")
	var sim2 = Simulation.new()
	sim2.reset("last_ration")
	sim2.step({"ada": {"type": "take"}, "boris": {"type": "take"}})
	_check(sim2.state.items.ration_storage.holder == sim.state.items.ration_storage.holder,
		"arbitration ignores dictionary/network arrival order")
	sim2.reset("last_ration")
	sim2.step({})
	sim2.step({"ada": {"type": "take"}, "boris": {"type": "take"}})
	_check(sim2.state.items.ration_storage.holder == "boris", "priority rotates by logical tick")


func _test_walls_and_movement() -> void:
	var sim = Simulation.new()
	sim.state.agents.ada.position = [1.2, 1.0]
	sim.state.agents.ada.heading = -90.0
	var initial: Array = sim.state.agents.ada.position.duplicate()
	sim.step({"ada": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(sim.state.agents.ada.position == initial, "swept move cannot cross a partition")
	_check(not sim.state.agents.ada.last_result.ok, "blocked movement has explicit result")
	sim.state.agents.ada.position = [1.2, -3.2]
	sim.step({"ada": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(is_equal_approx(float(sim.state.agents.ada.position[0]), 2.2), "storage passage permits movement")
	sim.state.agents.ada.position = [1.2, 2.9]
	sim.step({"ada": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(is_equal_approx(float(sim.state.agents.ada.position[0]), 1.2), "closed door blocks movement")
	sim.state.agents.ada.position = [8.5, -3.2]
	sim.step({"ada": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(is_equal_approx(float(sim.state.agents.ada.position[0]), 8.5), "outer wall prevents escaping floor")
	sim.state.agents.ada.position = [-1.5, -3.2]
	sim.step({"ada": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(is_equal_approx(float(sim.state.agents.ada.position[0]), -1.5), "agents cannot sweep through another body")


func _test_body_rules() -> void:
	var sim = Simulation.new()
	sim.state.agents.ada.body.left_arm = "broken"
	sim.step({"ada": {"type": "take"}})
	_check(sim.state.agents.ada.last_result.ok, "one healthy arm permits taking one-hand item")
	sim.reset()
	sim.state.agents.ada.body.left_arm = "broken"
	sim.state.agents.ada.body.right_arm = "broken"
	sim.step({"ada": {"type": "take"}})
	_check(not sim.state.agents.ada.last_result.ok, "both broken arms block taking")
	sim.reset()
	sim.state.agents.ada.body.left_leg = "injured"
	sim.step({"ada": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(is_equal_approx(float(sim.state.agents.ada.position[0]), 4.55), "injured leg slows movement")
	_check(sim.state.agents.ada.needs.fatigue > 6.0, "injured leg increases fatigue cost")
	sim.reset()
	sim.state.agents.ada.body.left_leg = "broken"
	sim.state.agents.ada.body.right_leg = "broken"
	sim.step({"ada": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(is_equal_approx(float(sim.state.agents.ada.position[0]), 4.25), "two broken legs allow slow crawling")
	_check(sim.state.agents.ada.last_result.message.contains("Crawled"), "crawl is a distinct movement mode")
	sim.state.agents.ada.body.left_arm = "broken"
	sim.state.agents.ada.body.right_arm = "broken"
	sim.step({"ada": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(not sim.state.agents.ada.last_result.ok, "all four broken limbs prevent independent movement")


func _test_speech_and_stale() -> void:
	var sim = Simulation.new()
	sim.step({"ada": {"type": "speak", "text": "I found a ration."}})
	_check(sim.observe("boris").heard.size() == 1, "audible speech reaches Boris through storage passage")
	_check(sim.observe("cora").heard.is_empty(), "inaudible speech is not globally broadcast")
	_check(sim.observe("boris").heard[0].speaker == "Ada", "speech retains attributed source")
	var run_id: int = sim.state.run_id
	sim.reset()
	var before: Dictionary = sim.snapshot()
	_check(sim.step({"ada": {"type": "take"}}, run_id).is_empty(), "stale generation returns no events")
	_check(sim.snapshot() == before, "reset invalidates delayed actions without changing world")
	for i in range(5):
		sim.observe("ada")
	_check(sim.state.tick == 0, "observation/render reads cannot advance logical time")


func _test_persistence() -> void:
	var sim = Simulation.new()
	sim.step({"ada": {"type": "take"}})
	sim.step({"ada": {"type": "turn", "degrees": 90.0}})
	var expected: Dictionary = sim.snapshot()
	var replayed: Dictionary = sim.replay_to()
	_check(replayed == expected, "journal reconstructs final authoritative state")
	_check(sim.replay_to(0).tick == 0, "journal can review initial snapshot")
	_check(sim.snapshot() == expected, "review is read-only and leaves live state unchanged")
	var path := "user://simulation_test_save.json"
	_check(sim.save_to(path) == OK, "save succeeds")
	var restored = Simulation.new()
	_check(restored.load_from(path) == OK, "save loads successfully")
	var loaded: Dictionary = restored.snapshot()
	loaded.run_id = expected.run_id
	_check(JSON.parse_string(JSON.stringify(loaded)) == JSON.parse_string(JSON.stringify(expected)), "save restores all world fields/events")
	_check(restored.state.run_id != sim.state.run_id, "load invalidates prior async generation")
	_check(restored.replay_to(1).agents.ada.inventory.has("ration_storage"), "loaded journal replays without models")
	var bad := FileAccess.open("user://simulation_bad_save.json", FileAccess.WRITE)
	bad.store_string("{\"version\":1,\"state\":{}}")
	bad.close()
	var before: Dictionary = restored.snapshot()
	_check(restored.load_from("user://simulation_bad_save.json") == ERR_FILE_CORRUPT, "corrupt save rejected")
	_check(restored.snapshot() == before, "failed load leaves authority unchanged")
	var valid_file := FileAccess.open(path, FileAccess.READ)
	var valid_save: Dictionary = JSON.parse_string(valid_file.get_as_text())
	valid_file.close()
	var corrupt_cases: Array = []
	var malformed_body: Dictionary = valid_save.duplicate(true)
	malformed_body.state.agents.ada.body = []
	corrupt_cases.append(malformed_body)
	var orphan_holder: Dictionary = valid_save.duplicate(true)
	orphan_holder.state.items.ration_storage.holder = "unknown_person"
	corrupt_cases.append(orphan_holder)
	var malformed_record: Dictionary = valid_save.duplicate(true)
	malformed_record.records[0].state.agents.ada.position = ["bad", 0]
	corrupt_cases.append(malformed_record)
	var bad_initial: Dictionary = valid_save.duplicate(true)
	bad_initial.initial_state.geometry.walls[0].size = [-1, 2]
	corrupt_cases.append(bad_initial)
	var divergent_live: Dictionary = valid_save.duplicate(true)
	divergent_live.state.agents.ada.heading = 45.0
	corrupt_cases.append(divergent_live)
	var divergent_endpoint: Dictionary = valid_save.duplicate(true)
	divergent_endpoint.records[-1].state.agents.ada.needs.hunger = 80.0
	corrupt_cases.append(divergent_endpoint)
	var rewritten_history: Dictionary = valid_save.duplicate(true)
	rewritten_history.records[-1].state.events[0].message = "Rewritten earlier event."
	corrupt_cases.append(rewritten_history)
	var divergent_hearing: Dictionary = valid_save.duplicate(true)
	divergent_hearing.heard.ada = [{"speaker": "Boris", "text": "Invented message", "bearing": 0.0, "distance": 1.0}]
	corrupt_cases.append(divergent_hearing)
	for corrupt in corrupt_cases:
		var broken_file := FileAccess.open("user://simulation_bad_save.json", FileAccess.WRITE)
		broken_file.store_string(JSON.stringify(corrupt))
		broken_file.close()
		_check(restored.load_from("user://simulation_bad_save.json") == ERR_FILE_CORRUPT, "malformed nested save rejected")
		_check(restored.snapshot() == before, "malformed nested load leaves authority unchanged")
	_check(restored.save_to(path) == OK and restored.load_from(path) == OK,
		"load then resave preserves journal parity despite new generation token")
	restored.step({"ada": {"type": "look"}})
	_check(restored.save_to(path) == OK and restored.load_from(path) == OK,
		"continued loaded run preserves journal parity across generation tokens")
	var fresh = Simulation.new()
	_check(fresh.save_to(path) == OK and fresh.load_from(path) == OK,
		"tick-zero save matches initial journal snapshot")
	var fresh_file := FileAccess.open(path, FileAccess.READ)
	var corrupt_initial: Dictionary = JSON.parse_string(fresh_file.get_as_text())
	fresh_file.close()
	corrupt_initial.state.agents.ada.heading = 25.0
	var corrupt_file := FileAccess.open("user://simulation_bad_save.json", FileAccess.WRITE)
	corrupt_file.store_string(JSON.stringify(corrupt_initial))
	corrupt_file.close()
	_check(fresh.load_from("user://simulation_bad_save.json") == ERR_FILE_CORRUPT,
		"tick-zero live state divergence from initial journal rejected")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://simulation_bad_save.json"))


func _test_invalid_actions() -> void:
	var sim = Simulation.new()
	var invalid: Array = [null, [], "take", {}, {"type": "teleport"}, {"type": "wait", "secret": true},
		{"type": "move", "forward": 1.0, "right": 1.0}, {"type": "move", "forward": "fast", "right": 0},
		{"type": "turn", "degrees": INF}, {"type": "put", "slot": 0.5}, {"type": "speak", "text": 44},
		{"type": "speak", "text": ""}]
	for action in invalid:
		var before: Array = sim.state.agents.ada.position.duplicate()
		sim.step({"ada": action})
		_check(not sim.state.agents.ada.last_result.ok, "invalid intent is safely rejected: " + str(action))
		_check(sim.state.agents.ada.position == before, "invalid intent cannot move actor")
	_check(_conserved(sim.state), "invalid intents cannot create resources")


func _test_invalid_loaded_poses() -> void:
	var sim = Simulation.new()
	var path := "user://simulation_pose_test.json"
	_check(sim.save_to(path) == OK, "pose validation fixture saves")
	var file := FileAccess.open(path, FileAccess.READ)
	var baseline: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()
	var before: Dictionary = sim.snapshot()
	for point in [[2.0, -1.0], [2.0, 2.9], [1.75, -1.0], [-0.5, -3.2], [8.85, -3.2], [0.0, 5.85]]:
		var corrupt: Dictionary = baseline.duplicate(true)
		for field in ["state", "initial_state"]:
			corrupt[field].agents.ada.position = point.duplicate()
			# Independently enforce the floor even if outer geometry was modified.
			corrupt[field].geometry.walls = corrupt[field].geometry.walls.filter(
				func(wall): return not String(wall.id).begins_with("outer_"))
		var output := FileAccess.open(path, FileAccess.WRITE)
		output.store_string(JSON.stringify(corrupt))
		output.close()
		_check(sim.load_from(path) == ERR_FILE_CORRUPT,
			"load rejects physically invalid pose despite consistent initial/current snapshots: " + str(point))
		_check(sim.snapshot() == before, "invalid physical pose load is transactional")
	# Debug geometry cannot make independent movement walk beyond the floor.
	sim.state.geometry.walls = sim.state.geometry.walls.filter(
		func(wall): return not String(wall.id).begins_with("outer_"))
	sim.state.agents.ada.position = [8.5, -3.2]
	sim.state.agents.ada.heading = -90.0
	sim.step({"ada": {"type": "move", "forward": 1.0, "right": 0.0}})
	_check(not sim.state.agents.ada.last_result.ok, "movement honors floor bound independently of wall geometry")
	_check(is_equal_approx(float(sim.state.agents.ada.position[0]), 8.5), "floor bound rejection retains position")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _view_has(observation: Dictionary, label: String) -> bool:
	for entry in observation.mock_view:
		if entry.label == label:
			return true
	return false


func _conserved(world: Dictionary) -> bool:
	var occurrences: Dictionary = {}
	for id in world.agents:
		for item_id in world.agents[id].inventory:
			occurrences[item_id] = int(occurrences.get(item_id, 0)) + 1
			if world.items[item_id].holder != id:
				return false
	for item_id in world.items:
		var wanted := 0 if String(world.items[item_id].holder).is_empty() else 1
		if int(occurrences.get(item_id, 0)) != wanted:
			return false
	return true
