extends RefCounted

const Runtime = preload("res://scripts/ai/agent_runtime.gd")
const Memory = preload("res://scripts/ai/personal_memory.gd")
const Adapter = preload("res://scripts/ai/router_adapter.gd")

var failures: Array = []
var checks: int = 0


func run() -> Array:
	failures.clear()
	checks = 0
	var runtime = Runtime.new()
	runtime.configure("ada", {"foundation": "Cooperative and observant", "traits": ["patient"]})
	runtime.reset(1)
	_test_parser(runtime)
	_test_isolation(runtime)
	_test_memory(runtime)
	_test_transactional_import(runtime)
	_test_mock(runtime)
	_test_generation(runtime)
	_test_provider_wrapper()
	runtime.free()
	print("Runtime: ", checks, " checks; ", failures.size(), " failures")
	return failures


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _observation() -> Dictionary:
	return {"tick": 0,
		"self_state": {"name": "Ada", "needs": {"hunger": 0.1, "fatigue": 0.0},
			"body": {"blind": false, "left_arm": "healthy", "right_arm": "healthy", "left_leg": "healthy", "right_leg": "healthy"}},
		"inventory": [], "heard": [], "last_result": {},
		"profile": {"foundation": "Cooperative and observant", "traits": ["patient"]},
		"mock_view": [{"kind": "ration", "label": "Visible ration", "distance": 1.0, "bearing": 0.0}]}


func _test_parser(runtime: Node) -> void:
	var good: Array = [
		'{"type":"wait"}', '{"type":"look"}', '{"type":"take"}',
		'{"type":"move","forward":0.6,"right":0.8}',
		'{"type":"turn","degrees":-180}', '{"type":"put","slot":0}',
		'{"type":"give","slot":1}', '{"type":"speak","text":"Hello"}']
	for text in good:
		check(runtime.parse_response(text)["ok"], "Valid action was rejected: " + text)
	var bad: Array = ["not JSON", "[]", "null", "{}", "42", '"wait"',
		'{"type":"teleport"}', '{"type":"wait","target":"hidden_item_id"}',
		'{"type":"move","forward":1,"right":1}', '{"type":"move","forward":true,"right":0}',
		'{"type":"move","forward":0}', '{"type":"move","forward":"0","right":0}',
		'{"type":"turn","degrees":181}', '{"type":"give","slot":-1}',
		'{"type":"put","slot":0.5}', '{"type":"speak","text":""}',
		'{"type":"speak","text":8}', '```json\n{"type":"wait"}\n```',
		'{"type":"speak","text":"' + "x".repeat(281) + '"}',
		"x".repeat(8193)]
	for text in bad:
		var result: Dictionary = runtime.parse_response(text)
		check(not result["ok"] and result["action"] == {"type": "wait"}, "Invalid command was accepted: " + text.left(100))


func _test_isolation(runtime: Node) -> void:
	var observation: Dictionary = _observation()
	observation["world"] = {"secret": "GLOBAL_SECRET_CANARY"}
	observation["agent_id"] = "PRIVATE_AGENT_CANARY"
	observation["mock_view"].append({"kind": "prop", "label": "MOCK_VIEW_CANARY", "distance": 2.0, "bearing": 10.0})
	observation["self_state"]["position"] = "POSITION_CANARY"
	observation["self_state"]["body"]["hidden_inventory"] = "BODY_SECRET_CANARY"
	observation["inventory"].append({"slot": 0, "kind": "ration", "label": "Own ration", "id": "OBJECT_ID_CANARY"})
	observation["last_result"] = {"ok": true, "message": "You looked around", "details": {"id": "RESULT_ID_CANARY"}}
	var png := PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])
	var payload: Dictionary = runtime.build_payload(observation, png)
	var encoded: String = JSON.stringify(payload)
	for canary in ["GLOBAL_SECRET_CANARY", "PRIVATE_AGENT_CANARY", "MOCK_VIEW_CANARY", "POSITION_CANARY", "BODY_SECRET_CANARY", "OBJECT_ID_CANARY", "RESULT_ID_CANARY", "mock_view", "agent_id"]:
		check(not encoded.contains(canary), "VLM payload leaked " + canary)
	check(encoded.contains("data:image/png;base64,"), "Sighted payload lacked actual PNG content block")
	check(payload["model"] == "~deepseek/deepseek-v4-flash-latest", "Wrong default VLM model")
	observation["self_state"]["body"]["blind"] = true
	var blind_payload: String = JSON.stringify(runtime.build_payload(observation, png))
	check(not blind_payload.contains("image_url"), "Blind payload contains a current camera image")
	check(not runtime.get_debug()["network_enabled"], "Paid network adapter was enabled by default")


func _test_memory(runtime: Node) -> void:
	runtime.reset(2)
	var observation: Dictionary = _observation()
	runtime.remember(observation, PackedByteArray([1, 2, 3]))
	observation["self_state"]["name"] = "MUTATED"
	var entries: Array = runtime.get_memory()
	check(entries.size() == 1, "Personal memory did not append observation")
	check(entries[0]["self_state"]["name"] == "Ada", "External observation mutation rewrote memory")
	entries[0]["self_state"]["name"] = "MUTATED_AGAIN"
	check(runtime.get_memory()[0]["self_state"]["name"] == "Ada", "Returned memory exposed mutable originals")
	check(not runtime.get_memory()[0].has("mock_view"), "Memory retained privileged diagnostic geometry")
	runtime.remember(_observation())
	check(runtime.get_memory().size() == 1, "Duplicate tick rewrote or duplicated recent memory")
	var job: Dictionary = runtime.make_memory_job(1)
	check(job["status"] == "summarisation_not_implemented", "Unimplemented subjective memory was reported ready")
	check(not JSON.stringify(job).contains("mock_view"), "Memory role received mock geometry")
	var saved: Dictionary = runtime.export_state()
	runtime.reset(3)
	check(runtime.get_memory().is_empty(), "Reset retained previous character experience")
	check(runtime.import_state(saved, 4), "Personal state restore failed")
	check(runtime.get_memory().size() == 1, "Personal memory did not survive sidecar restore")
	var blind: Dictionary = _observation()
	blind["tick"] = 1
	blind["self_state"]["body"]["blind"] = true
	runtime.remember(blind, PackedByteArray([9, 8, 7]))
	check(runtime.get_memory()[-1]["image_png_base64"] == "", "Blind memory retained a current image")


func _test_mock(runtime: Node) -> void:
	runtime.reset(5)
	var observation: Dictionary = _observation()
	var action: Dictionary = runtime.decide_mock(observation)
	check(action["type"] == "take", "Mock did not act on directly visible reachable ration")
	runtime.reset(5)
	check(runtime.decide_mock(observation) == action, "Mock reset was not deterministic")
	observation["self_state"]["body"]["blind"] = true
	check(runtime.decide_mock(observation)["type"] != "take", "Blind mock used forbidden visual scaffold")
	observation["self_state"]["body"]["blind"] = false
	observation["mock_view"] = [{"kind": "ration", "label": "Ration", "distance": 3.0, "bearing": 30.0}]
	check(runtime.decide_mock(observation) == {"type": "turn", "degrees": 30.0}, "Mock did not turn toward permitted visible evidence")
	observation["mock_view"] = []
	observation["heard"] = [{"speaker": "Ada", "text": "I found food", "distance": 4.0, "bearing": -80.0}]
	var heard_action: Dictionary = runtime.decide_mock(observation)
	check(heard_action["type"] == "speak", "Mock did not acknowledge personal heard report")
	check(not heard_action.has("target"), "Mock emitted hidden target identifier")
	observation["last_result"] = {"type": "move", "ok": false, "message": "Movement blocked"}
	check(runtime.decide_mock(observation)["type"] == "turn", "Mock ignored its own blocked-movement result")


func _test_transactional_import(runtime: Node) -> void:
	runtime.reset(40)
	runtime.remember(_observation(), PackedByteArray([1, 2, 3]))
	var baseline: Dictionary = runtime.export_state()
	var malformed: Array = [null, [], "bad"]
	for path in ["memory", "policy"]:
		var broken: Dictionary = baseline.duplicate(true)
		broken[path] = "bad"
		malformed.append(broken)
	for field in ["self_state", "inventory", "heard", "last_result", "profile"]:
		var broken: Dictionary = baseline.duplicate(true)
		broken.memory.entries[0][field] = "bad"
		malformed.append(broken)
	for field in ["needs", "body"]:
		var broken: Dictionary = baseline.duplicate(true)
		broken.memory.entries[0].self_state[field] = []
		malformed.append(broken)
	for value in [NAN, INF, "bad", true, -1.0]:
		var broken: Dictionary = baseline.duplicate(true)
		broken.memory.entries[0].self_state.needs.hunger = value
		malformed.append(broken)
	for value in [-1, 0.5, "0", NAN]:
		var broken: Dictionary = baseline.duplicate(true)
		broken.memory.entries[0].tick = value
		malformed.append(broken)
	for value in ["?%%%", "A===", "AB==", "AA", "====", 3]:
		var broken: Dictionary = baseline.duplicate(true)
		broken.memory.entries[0].image_png_base64 = value
		malformed.append(broken)
	for policy in [{"search_turns": "bad"}, {"search_turns": -1}, {"heard_bearing": INF}, {"heard_remaining": -2}, {"foreign_agent": "secret"}]:
		var broken: Dictionary = baseline.duplicate(true)
		broken.policy = policy
		malformed.append(broken)
	var wrong_owner: Dictionary = baseline.duplicate(true)
	wrong_owner.memory.owner = "boris"
	malformed.append(wrong_owner)
	var duplicate: Dictionary = baseline.duplicate(true)
	duplicate.memory.entries.append(duplicate.memory.entries[0].duplicate(true))
	malformed.append(duplicate)
	var reversed: Dictionary = baseline.duplicate(true)
	reversed.memory.entries[0].tick = 2
	var earlier: Dictionary = reversed.memory.entries[0].duplicate(true)
	earlier.tick = 1
	reversed.memory.entries.append(earlier)
	malformed.append(reversed)
	for candidate in malformed:
		var generation: int = runtime._generation
		runtime._pending[12345] = {"generation": generation, "run_id": 40, "tick": 0}
		check(not runtime.import_state(candidate, 99), "Malformed private save was accepted")
		check(runtime.export_state() == baseline and runtime._generation == generation and runtime._pending.has(12345), "Failed private import mutated memory, policy, generation, budget, or pending work")
	check(runtime.import_state(baseline, 41), "Valid state failed staged import")
	check(runtime._run_id == 41 and runtime._pending.is_empty(), "Successful state import did not replace request generation")
	# An older save cannot grant new paid permission or replenish an allowance.
	runtime._live_request_limit = 5
	runtime._live_requests_started = 4
	var saved_budget: Dictionary = runtime.export_state()
	saved_budget.budget.started = 1
	check(runtime.import_state(saved_budget, 42), "Valid lower historical request count failed import")
	check(runtime.get_debug().live_requests_started == 4, "Import replenished consumed request allowance")
	runtime._live_request_limit = 0
	check(runtime.import_state(runtime.export_state(), 43), "Exhausted restricted allowance could not round-trip")
	check(runtime.get_debug().live_requests_started == 4 and runtime.get_debug().live_request_limit == 0, "Restricted exhausted allowance was replenished")
	runtime._live_requests_started = 0


func _test_generation(runtime: Node) -> void:
	var signals: Array = []
	runtime.decision_ready.connect(func(_id, run_id, tick, action, diagnostic):
		signals.append({"run": run_id, "tick": tick, "action": action, "diagnostic": diagnostic}))
	runtime.reset(20)
	runtime.request_real(_observation(), PackedByteArray([1]), 19)
	check(signals.is_empty(), "Stale run request emitted a decision")
	runtime.request_real(_observation(), PackedByteArray([1]), 20)
	check(signals.size() == 1 and signals[0]["action"] == {"type": "wait"}, "Disabled real provider did not safely return wait")
	runtime.reset(21)
	runtime._on_router_response(1, {"ok": true, "text": '{"type":"take"}'})
	check(signals.size() == 1, "Late pre-reset response escaped the generation guard")
	# Model callbacks can be injected without enabling the network. Establish
	# a genuinely pending ticket, reset, then deliver that successful reply.
	runtime._pending[777] = {"generation": runtime._generation, "run_id": 21, "tick": 0}
	runtime.reset(22)
	runtime._on_router_response(777, {"ok": true, "text": '{"type":"take"}'})
	check(signals.size() == 1, "A genuine pending pre-reset callback survived reset")
	runtime.request_real(_observation(), PackedByteArray(), 22)
	check(signals.size() == 2 and not signals[1]["diagnostic"]["ok"], "Sighted request without pixels was not rejected")
	var before: int = runtime.get_memory().size()
	runtime.cancel_pending()
	check(runtime.get_memory().size() == before, "Cancelling pending requests erased personal memory")
	runtime.configure_real_mode(false, 50)
	check(not runtime.get_debug()["network_enabled"], "Missing approval enabled paid mode")
	runtime.configure_real_mode(true, 0)
	check(not runtime.get_debug()["network_enabled"], "Zero budget enabled paid mode")
	runtime._pending[800] = {"generation": runtime._generation, "run_id": runtime._run_id, "tick": 2}
	runtime._on_router_response(800, {"ok": true, "text": '{"type":"wait"}',
		"requested_model": "alias", "returned_model": "revision", "usage": {"prompt_tokens": 12, "completion_tokens": 4, "cost": 0.001}})
	var diagnostic: Dictionary = signals[-1].diagnostic
	check(diagnostic.get("usage", {}).get("prompt_tokens") == 12 and diagnostic.get("usage", {}).get("cost") == 0.001, "Provider usage/cost was lost from decision diagnostics")
	check(diagnostic.get("requested_model") == "alias" and diagnostic.get("returned_model") == "revision", "Provider model provenance was lost")
	check(runtime.get_debug().get("usage", {}).get("completion_tokens") == 4, "Provider usage was lost from observer debug")


func _test_provider_wrapper() -> void:
	for malformed in ["not json", "null", "[]", "{}", '{"choices":null}', '{"choices":[null]}',
		'{"choices":[{"message":"wrong"}]}', '{"choices":[{"message":{"content":[]}}]}']:
		check(not Adapter.parse_completion(malformed)["ok"], "Malformed provider wrapper was accepted: " + malformed)
	var valid: Dictionary = Adapter.parse_completion('{"model":"revision-for-test","choices":[{"message":{"content":"{\\\"type\\\":\\\"wait\\\"}"}}]}')
	check(valid["ok"] and valid["returned_model"] == "revision-for-test", "Valid provider wrapper/model metadata failed")
