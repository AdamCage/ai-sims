extends RefCounted
## Independent adversarial checks; deliberately separate from subsystem authors.

const Simulation = preload("res://scripts/simulation/world_simulation.gd")
const Runtime = preload("res://scripts/ai/agent_runtime.gd")
var failures: Array = []
var checks := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("QA: " + message)

func run() -> Array:
	failures.clear()
	checks = 0
	_test_isolation_against_world_secrets()
	_test_action_order_and_replay()
	_test_blindness_and_late_responses()
	_test_transactional_personal_import()
	_test_corrupted_replay_agreement()
	_test_loaded_physical_positions()
	print("Independent QA: ", checks, " checks; ", failures.size(), " failures")
	return failures

func _test_isolation_against_world_secrets() -> void:
	var sim = Simulation.new()
	var runtime = Runtime.new()
	runtime.configure("boris", sim.state.agents.boris.profile)
	runtime.reset(int(sim.state.run_id))
	var initial: Dictionary = sim.observe("boris")
	var payload_before: Dictionary = runtime.build_payload(initial, PackedByteArray([1,2,3]))
	# These mutations affect only facts Boris cannot currently see or hear.
	sim.state.items.ration_hidden.label = "HIDDEN_RATION_SENTINEL"
	sim.state.agents.ada.profile.foundation = "FOREIGN_THOUGHT_SENTINEL"
	sim.state.agents.ada.inventory.append("ration_hidden")
	sim.state.items.ration_hidden.holder = "ada"
	var hidden: Dictionary = sim.observe("boris")
	check(JSON.stringify(initial) == JSON.stringify(hidden), "unseen inventory/thought changes must not alter Boris's observation")
	check(JSON.stringify(payload_before) == JSON.stringify(runtime.build_payload(hidden, PackedByteArray([1,2,3]))), "unseen secrets must not alter model text")
	runtime.remember(hidden)
	check(not JSON.stringify(runtime.make_memory_job(1)).contains("SENTINEL"), "memory role must exclude hidden facts")
	sim.step({"ada":{"type":"speak","text":"There is food near me."}})
	var informed: Dictionary = sim.observe("boris")
	check(informed.heard.size() == 1, "report reaches only permitted hearing channel")
	check(informed.mock_view.is_empty(), "hearing report does not synthesize visual evidence")
	runtime.remember(informed)
	var personal: String = JSON.stringify(runtime.get_memory())
	check(personal.contains("heard_speech") and personal.contains("There is food near me."), "private memory retains source provenance of report")
	check(not personal.contains("HIDDEN_RATION_SENTINEL") and not personal.contains("FOREIGN_THOUGHT_SENTINEL"), "new heard report must not reveal extra authority")
	runtime.free()

func _test_action_order_and_replay() -> void:
	for advance in [0,1,2]:
		var left = Simulation.new()
		var right = Simulation.new()
		left.reset("last_ration")
		right.reset("last_ration")
		for step_index in advance:
			left.step({})
			right.step({})
		left.step({"ada":{"type":"take"},"boris":{"type":"take"}})
		right.step({"boris":{"type":"take"},"ada":{"type":"take"}})
		check(left.state.items.ration_storage.holder == right.state.items.ration_storage.holder, "request arrival order must not choose winner at phase %d" % advance)
		var count: int = left.state.agents.ada.inventory.count("ration_storage") + left.state.agents.boris.inventory.count("ration_storage")
		check(count == 1, "exactly one holder in contested phase %d" % advance)
	var sim = Simulation.new()
	var snapshots: Array = [sim.snapshot()]
	var intentions: Array = [
		{"ada":{"type":"take"}},
		{"ada":{"type":"turn","degrees":180}},
		{"ada":{"type":"move","forward":0.8,"right":0}},
		{"ada":{"type":"put","slot":0}},
		{"ada":{"type":"speak","text":"I set it down."}}]
	for actions in intentions:
		sim.step(actions)
		snapshots.append(sim.snapshot())
	for index in snapshots.size():
		check(sim.replay_to(index) == snapshots[index], "replay reconstructs every intermediate snapshot %d" % index)
	var returned: Dictionary = sim.replay_to(2)
	returned.agents.ada.inventory.clear()
	check(sim.replay_to(2) == snapshots[2], "replay result is detached from stored journal")

func _test_blindness_and_late_responses() -> void:
	var sim = Simulation.new()
	var runtime = Runtime.new()
	runtime.configure("ada", sim.state.agents.ada.profile)
	runtime.reset(int(sim.state.run_id))
	sim.state.agents.ada.body.blind = true
	var observation: Dictionary = sim.observe("ada")
	check(observation.mock_view.is_empty(), "blind character gets no fresh symbolic visual channel")
	runtime.remember(observation, PackedByteArray([1,2,3]))
	check(not JSON.stringify(runtime.build_payload(observation, PackedByteArray([1,2,3]))).contains("image_url"), "blind payload never uses supplied current pixels")
	check(runtime.get_memory()[0].image_png_base64.is_empty(), "blind memory rejects supplied current pixels")
	var delivered: Array = []
	runtime.decision_ready.connect(func(id,run_id,tick,action,diagnostic): delivered.append([id,run_id,tick,action,diagnostic]))
	# Inject transport tickets rather than invoking any provider or API key.
	runtime._pending[77] = {"generation":runtime._generation,"run_id":runtime._run_id,"tick":0}
	runtime.cancel_pending()
	runtime._on_router_response(77,{"ok":true,"text":"{\"type\":\"take\"}"})
	check(delivered.is_empty(), "cancelled transport completion cannot issue an action")
	runtime._pending[78] = {"generation":runtime._generation,"run_id":runtime._run_id,"tick":0}
	runtime._on_router_response(78,{"ok":true,"text":"{\"type\":\"teleport\"}"})
	check(delivered.size() == 1 and delivered[0][3] == {"type":"wait"}, "invalid provider command yields one safe wait")
	runtime._on_router_response(78,{"ok":true,"text":"{\"type\":\"take\"}"})
	check(delivered.size() == 1, "duplicate completion cannot issue a second command")
	runtime.free()

func _test_transactional_personal_import() -> void:
	var sim = Simulation.new()
	var runtime = Runtime.new()
	runtime.configure("ada",sim.state.agents.ada.profile)
	runtime.reset(int(sim.state.run_id))
	runtime.remember(sim.observe("ada"))
	var before: Dictionary = runtime.export_state()
	var corrupted: Dictionary = before.duplicate(true)
	corrupted.memory.entries = [7]
	check(not runtime.import_state(corrupted,100), "malformed personal history is rejected")
	check(runtime.get_memory() == before.memory.entries, "failed personal import preserves previous immutable history")
	var bad_nested: Dictionary = before.duplicate(true)
	bad_nested.memory.entries[0].self_state = []
	check(not runtime.import_state(bad_nested,101), "malformed nested private context rejected without runtime exception")
	check(runtime.get_memory() == before.memory.entries, "nested failed import preserves prior memory")
	runtime.free()

func _test_corrupted_replay_agreement() -> void:
	var sim = Simulation.new()
	sim.step({"ada":{"type":"take"}})
	var path := "user://qa_replay_agreement.json"
	check(sim.save_to(path) == OK, "QA session save succeeds")
	var read := FileAccess.open(path,FileAccess.READ)
	var archive: Dictionary = JSON.parse_string(read.get_as_text())
	read.close()
	# A single corrupted current-state field must not yield two different truths
	# for the same recorded tick when loaded and replayed.
	archive.state.agents.ada.heading = 27.0
	var write := FileAccess.open(path,FileAccess.WRITE)
	write.store_string(JSON.stringify(archive))
	write.close()
	var restored = Simulation.new()
	var pristine: Dictionary = restored.snapshot()
	check(restored.load_from(path) == ERR_FILE_CORRUPT, "save current state must agree with final recorded snapshot")
	check(restored.snapshot() == pristine, "inconsistent journal rejection leaves world unchanged")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _test_loaded_physical_positions() -> void:
	var sim = Simulation.new()
	var path := "user://qa_invalid_pose.json"
	sim.save_to(path)
	var read := FileAccess.open(path,FileAccess.READ)
	var archive: Dictionary = JSON.parse_string(read.get_as_text())
	read.close()
	# Keep current+initial snapshots consistent, but place Ada inside the
	# central opaque wall. Such a save must not create an impossible live pose.
	archive.state.agents.ada.position = [2.0, -1.0]
	archive.initial_state.agents.ada.position = [2.0, -1.0]
	var write := FileAccess.open(path,FileAccess.WRITE)
	write.store_string(JSON.stringify(archive))
	write.close()
	var before: Dictionary = sim.snapshot()
	check(sim.load_from(path) == ERR_FILE_CORRUPT, "loaded character body must not intersect a wall")
	check(sim.snapshot() == before, "impossible loaded pose cannot change authority")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
