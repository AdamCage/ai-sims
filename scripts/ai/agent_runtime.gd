class_name AgentRuntime
extends Node
## One isolated character runtime; all model output remains an intention.

signal decision_ready(agent_id: String, run_id: int, tick: int, action: Dictionary, diagnostic: Dictionary)

const MemoryStore = preload("res://scripts/ai/personal_memory.gd")
const RouterAdapter = preload("res://scripts/ai/router_adapter.gd")
const ACTION_FIELDS := {
	"wait": ["type"], "look": ["type"], "move": ["type", "forward", "right"],
	"turn": ["type", "degrees"], "take": ["type"], "put": ["type", "slot"],
	"give": ["type", "slot"], "speak": ["type", "text"]}
const ACTION_INSTRUCTIONS := "Return exactly one JSON action, without markdown or commentary. " + \
	"Actions: {\"type\":\"wait\"}, {\"type\":\"look\"}, " + \
	"{\"type\":\"move\",\"forward\":number,\"right\":number} (relative to your gaze; vector length at most 1 metre), " + \
	"{\"type\":\"turn\",\"degrees\":number} (-180 to 180, positive turns left), " + \
	"{\"type\":\"take\"} (nearest visible reachable item along your gaze), " + \
	"{\"type\":\"put\",\"slot\":integer}, {\"type\":\"give\",\"slot\":integer} " + \
	"(give to nearest visible reachable person), {\"type\":\"speak\",\"text\":string} (1 to 280 characters). " + \
	"Inventory slots refer only to your own inventory. No other fields are allowed. " + \
	"You know only your own context, memory and current image; uncertain reports are reports, not direct sight."

var agent_id: String = ""
var profile: Dictionary = {}
var _run_id: int = -1
var _generation: int = 0
var _request_counter: int = 0
var _live_request_limit: int = 0
var _live_requests_started: int = 0
var _pending: Dictionary = {}
var _policy: Dictionary = {}
var _memory = MemoryStore.new()
var _adapter = RouterAdapter.new()
var _debug: Dictionary = {"mode": "mock", "last_action": {}, "last_error": "", "pending": false}


func _init() -> void:
	add_child(_adapter)
	_adapter.response_ready.connect(_on_router_response)


func configure(id: String, own_profile: Dictionary) -> void:
	agent_id = id
	profile = MemoryStore.clean_profile(own_profile)
	_memory.configure(agent_id)


func reset(run_id: int) -> void:
	cancel_pending()
	_run_id = run_id
	_memory.reset(run_id)
	_policy = {"last_speech_tick": -100, "last_give_tick": -100, "search_turns": 0}
	_debug = {"mode": "mock", "last_action": {}, "last_error": "", "pending": false}


func remember(observation: Dictionary, image_png: PackedByteArray = PackedByteArray()) -> void:
	_memory.append(observation, image_png)
	_debug["last_result"] = MemoryStore.personal_context(observation)["last_result"]


func get_memory() -> Array:
	return _memory.entries()


func get_debug() -> Dictionary:
	var result: Dictionary = _debug.duplicate(true)
	result["memory_count"] = _memory.entries().size()
	result["profile"] = profile.duplicate(true)
	result["memory"] = _memory.text_context(12)
	result["last_intent"] = result.get("last_action", {}).duplicate(true)
	result["network_enabled"] = _adapter.enabled
	result["api_ready"] = _adapter.available()
	result["model"] = _adapter.model
	result["live_request_limit"] = _live_request_limit
	result["live_requests_started"] = _live_requests_started
	result["memory_status"] = "Append-only personal history; subjective summarisation pending"
	return result


func set_live_enabled(approved: bool) -> void:
	configure_real_mode(approved, 1 if approved else 0)


func configure_real_mode(approved: bool, max_requests: int) -> void:
	# An explicit approval provides a finite count budget. World reset does
	# not replenish this allowance; callers must obtain a new approval.
	cancel_pending()
	_live_request_limit = maxi(0, max_requests)
	_live_requests_started = 0
	_adapter.enabled = approved and _live_request_limit > 0


func cancel_pending() -> void:
	_generation += 1
	_pending.clear()
	_adapter.cancel_all()
	_debug["pending"] = false


func decide_mock(observation: Dictionary) -> Dictionary:
	_debug["mode"] = "mock"
	var tick: int = int(observation.get("tick", 0))
	var own: Dictionary = observation.get("self_state", {})
	var blind: bool = bool(own.get("body", {}).get("blind", false))
	var inventory: Array = observation.get("inventory", [])
	var visible: Array = [] if blind else observation.get("mock_view", [])
	var heard: Array = observation.get("heard", [])
	var action: Dictionary = {"type": "wait"}
	var food: Dictionary = {}
	var person: Dictionary = {}
	for target in visible:
		if not target is Dictionary:
			continue
		var kind: String = str(target.get("kind", ""))
		if kind in ["ration", "food"]:
			if food.is_empty() or float(target.get("distance", INF)) < float(food.get("distance", INF)):
				food = target
		if kind in ["agent", "person", "character"]:
			if person.is_empty() or float(target.get("distance", INF)) < float(person.get("distance", INF)):
				person = target
	var last_speech: int = int(_policy.get("last_speech_tick", -100))
	var last_result: Dictionary = observation.get("last_result", {})
	var generous: bool = profile.get("traits", []).has("generous") or profile.get("traits", []).has("social")
	if last_result.get("type", "") == "move" and not bool(last_result.get("ok", true)):
		# Learn from a physical refusal instead of repeatedly walking through
		# the same wall. This uses only the character's own action result.
		_policy["heard_remaining"] = 0.0
		_policy["recovery_steps"] = 2
		action = {"type": "turn", "degrees": 65.0 if agent_id != "cora" else -65.0}
	elif int(_policy.get("recovery_steps", 0)) > 0:
		_policy["recovery_steps"] = int(_policy["recovery_steps"]) - 1
		action = {"type": "move", "forward": 0.65, "right": 0.0}
	elif not inventory.is_empty():
		# Resource holders announce what they personally possess and seek a
		# physically visible recipient. They never know another inventory.
		if tick - last_speech >= 9:
			action = {"type": "speak", "text": "I have a ration. I can share it; come toward my voice." if generous else "I have a ration. I will keep it safe while we check the remaining supplies."}
			_policy["last_speech_tick"] = tick
		elif not generous:
			action = {"type": "look"} if tick % 3 != 0 else {"type": "turn", "degrees": 45.0}
		elif not person.is_empty():
			if float(person.get("distance", INF)) <= 1.35 and absf(float(person.get("bearing", 0.0))) <= 35.0:
				action = {"type": "give", "slot": 0}
				_policy["last_give_tick"] = tick
			else:
				action = _approach(person)
		else:
			action = {"type": "turn", "degrees": 45.0}
	elif not food.is_empty():
		if float(food.get("distance", INF)) <= 1.4 and absf(float(food.get("bearing", 0.0))) <= 35.0:
			action = {"type": "take"}
		else:
			action = _approach(food)
	elif not heard.is_empty():
		# A heard location is a bearing, not a newly visible object. Moving
		# toward it is an independent attempt to verify the speaker's report.
		var speech: Dictionary = heard[-1]
		_policy["heard_bearing"] = float(speech.get("bearing", 0.0))
		_policy["heard_remaining"] = minf(float(speech.get("distance", 0.0)), 6.0)
		if tick - last_speech >= 7:
			action = {"type": "speak", "text": "I heard you. I will come and check for myself."}
			_policy["last_speech_tick"] = tick
		else:
			action = _follow_heard()
	elif float(_policy.get("heard_remaining", 0.0)) > 0.0:
		action = _follow_heard()
	elif tick - last_speech > 14 and tick > 2:
		action = {"type": "speak", "text": "I am looking around. Has anyone found supplies?"}
		_policy["last_speech_tick"] = tick
	else:
		# Explore by looking, then taking local steps. There are no privileged
		# waypoints, room IDs, hidden item coordinates, or global tick scripts.
		var turns: int = int(_policy.get("search_turns", 0))
		if turns < 4:
			action = {"type": "turn", "degrees": 60.0 if agent_id != "cora" else -60.0}
			_policy["search_turns"] = turns + 1
		else:
			action = {"type": "move", "forward": 0.8, "right": 0.0}
			_policy["search_turns"] = 0
	var validated: Dictionary = parse_response(JSON.stringify(action))
	if not validated["ok"]:
		action = {"type": "wait"}
	_debug["last_action"] = action.duplicate(true)
	return action


func _approach(target: Dictionary) -> Dictionary:
	var bearing: float = float(target.get("bearing", 0.0))
	if absf(bearing) > 12.0:
		return {"type": "turn", "degrees": clampf(bearing, -90.0, 90.0)}
	return {"type": "move", "forward": minf(0.85, maxf(0.1, float(target.get("distance", 0.0)) - 1.1)), "right": 0.0}


func _follow_heard() -> Dictionary:
	var bearing: float = float(_policy.get("heard_bearing", 0.0))
	if absf(bearing) > 12.0:
		_policy["heard_bearing"] = 0.0
		return {"type": "turn", "degrees": clampf(bearing, -180.0, 180.0)}
	_policy["heard_remaining"] = maxf(0.0, float(_policy.get("heard_remaining", 0.0)) - 0.8)
	return {"type": "move", "forward": 0.8, "right": 0.0}


func build_payload(observation: Dictionary, image_png: PackedByteArray) -> Dictionary:
	var context: Dictionary = MemoryStore.personal_context(observation)
	context["profile"] = profile.duplicate(true)
	context["memory"] = _memory.text_context(12)
	var content: Array = [{"type": "text", "text": JSON.stringify(context)}]
	var blind: bool = bool(context["self_state"]["body"]["blind"])
	if not blind and not image_png.is_empty():
		content.append({"type": "image_url", "image_url": {
			"url": "data:image/png;base64," + Marshalls.raw_to_base64(image_png)}})
	return {"model": _adapter.model, "temperature": 0.2, "max_tokens": 220,
		"messages": [{"role": "system", "content": ACTION_INSTRUCTIONS},
			{"role": "user", "content": content}]}


func request_real(observation: Dictionary, image_png: PackedByteArray, run_id: int) -> void:
	var tick: int = int(observation.get("tick", -1))
	if run_id != _run_id:
		return
	_debug["mode"] = "real_vlm"
	var blind: bool = bool(observation.get("self_state", {}).get("body", {}).get("blind", false))
	if not blind and image_png.is_empty():
		_emit_failure(tick, "Sighted VLM requires a real camera PNG")
		return
	if _live_requests_started >= _live_request_limit and _adapter.enabled:
		_emit_failure(tick, "Approved live request count exhausted")
		return
	_request_counter += 1
	var token: int = _request_counter
	# One pending request per character. Superseding one invalidates callbacks.
	_adapter.cancel_all()
	_pending.clear()
	_pending[token] = {"generation": _generation, "run_id": run_id, "tick": tick}
	_debug["pending"] = true
	var error: Error = _adapter.send_request(build_payload(observation, image_png), token)
	if error != OK:
		_pending.erase(token)
		_emit_failure(tick, "Live calls disabled or unavailable (%s)" % error)
	else:
		_live_requests_started += 1


func _emit_failure(tick: int, message: String) -> void:
	_debug["pending"] = false
	_debug["last_error"] = message
	_debug["last_action"] = {"type": "wait"}
	decision_ready.emit(agent_id, _run_id, tick, {"type": "wait"}, {"ok": false, "error": message})


func _on_router_response(token: int, response: Dictionary) -> void:
	if not _pending.has(token):
		return
	var ticket: Dictionary = _pending[token]
	_pending.erase(token)
	if int(ticket["generation"]) != _generation or int(ticket["run_id"]) != _run_id:
		return
	_debug["pending"] = false
	if not bool(response.get("ok", false)):
		_emit_failure(int(ticket["tick"]), str(response.get("error", "Provider error")))
		return
	var parsed: Dictionary = parse_response(str(response.get("text", "")))
	var action: Dictionary = parsed["action"] if parsed["ok"] else {"type": "wait"}
	_debug["last_action"] = action.duplicate(true)
	_debug["last_error"] = parsed["error"]
	_debug["requested_model"] = response.get("requested_model", _adapter.model)
	_debug["returned_model"] = response.get("returned_model", "not_disclosed")
	_debug["usage"] = response.get("usage", {}).duplicate(true) if response.get("usage", {}) is Dictionary else {}
	decision_ready.emit(agent_id, _run_id, int(ticket["tick"]), action,
		{"ok": parsed["ok"], "error": parsed["error"],
			"requested_model": _debug["requested_model"], "returned_model": _debug["returned_model"],
			"usage": _debug["usage"].duplicate(true)})


func parse_response(text: String) -> Dictionary:
	if text.length() > 8192:
		return _invalid("Response exceeds command size limit")
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return _invalid("Expected one JSON object")
	var action: Dictionary = parser.data
	if not action.get("type", null) is String or not ACTION_FIELDS.has(action["type"]):
		return _invalid("Unknown action type")
	var fields: Array = ACTION_FIELDS[action["type"]]
	if action.size() != fields.size():
		return _invalid("Missing or extra action fields")
	for key in action:
		if not fields.has(key):
			return _invalid("Unknown action field")
	match action["type"]:
		"move":
			if not _finite_number(action.get("forward")) or not _finite_number(action.get("right")):
				return _invalid("Movement requires finite numeric components")
			if Vector2(float(action["forward"]), float(action["right"])).length() > 1.000001:
				return _invalid("Movement exceeds one metre")
		"turn":
			if not _finite_number(action.get("degrees")) or absf(float(action["degrees"])) > 180.0:
				return _invalid("Turn requires -180..180 degrees")
		"put", "give":
			if not _finite_number(action.get("slot")) or float(action["slot"]) != floorf(float(action["slot"])) or float(action["slot"]) < 0.0 or float(action["slot"]) > 31.0:
				return _invalid("Inventory slot must be a nonnegative integer below 32")
			action["slot"] = int(action["slot"])
		"speak":
			if not action.get("text", null) is String or action["text"].is_empty() or action["text"].length() > 280:
				return _invalid("Speech requires 1..280 characters")
	return {"ok": true, "action": action.duplicate(true), "error": ""}


func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _invalid(message: String) -> Dictionary:
	return {"ok": false, "action": {"type": "wait"}, "error": message}


func export_personal_state() -> Dictionary:
	return {"agent_id": agent_id, "memory": _memory.export_state(), "policy": _policy.duplicate(true),
		"budget": {"limit": _live_request_limit, "started": _live_requests_started}}


func import_personal_state(data: Variant, run_id: int) -> bool:
	if not data is Dictionary or run_id < 0 or data.get("agent_id") != agent_id:
		return false
	for key in data:
		if not key is String or not ["agent_id", "memory", "policy", "budget"].has(key):
			return false
	if not _valid_policy(data.get("policy")):
		return false
	var budget: Variant = data.get("budget", {"limit": _live_request_limit, "started": _live_requests_started})
	if not budget is Dictionary or not MemoryStore._keys_only(budget, ["limit", "started"]):
		return false
	# Consumed count may exceed a subsequently restricted allowance. That
	# represents exhaustion, and must remain serialisable without resetting it.
	if not MemoryStore._integer_in_range(budget.get("limit"), 0, 2147483647) or not MemoryStore._integer_in_range(budget.get("started"), 0, 2147483647):
		return false
	# Stage both subsystems. Invalid input must not erase live experience,
	# cancel valid requests, change generation, or partially restore policy.
	var candidate_memory = MemoryStore.new()
	candidate_memory.configure(agent_id)
	if not candidate_memory.import_state(data.get("memory"), run_id):
		return false
	cancel_pending()
	_run_id = run_id
	_memory = candidate_memory
	_policy = data.policy.duplicate(true)
	# Loading an older save never replenishes a current allowance or enables
	# the network. Only a new explicit configure_real_mode approval can do so.
	_live_requests_started = maxi(_live_requests_started, int(budget.started))
	_live_request_limit = mini(_live_request_limit, int(budget.limit))
	_debug = {"mode": "mock", "last_action": {}, "last_error": "", "pending": false}
	return true


func _valid_policy(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	var integer_ranges: Dictionary = {"last_speech_tick": [-100, 2147483647],
		"last_give_tick": [-100, 2147483647], "search_turns": [0, 4], "recovery_steps": [0, 2]}
	for key in data:
		if not key is String:
			return false
		if integer_ranges.has(key):
			if not MemoryStore._integer_in_range(data[key], integer_ranges[key][0], integer_ranges[key][1]):
				return false
		elif key == "heard_bearing":
			if not MemoryStore._number_in_range(data[key], -180.0, 180.0):
				return false
		elif key == "heard_remaining":
			if not MemoryStore._number_in_range(data[key], 0.0, 6.0):
				return false
		else:
			return false
	return true


func export_state() -> Dictionary:
	return export_personal_state()


func import_state(data: Variant, new_run_id: int = -1) -> bool:
	return import_personal_state(data, _run_id if new_run_id == -1 else new_run_id)


func make_memory_job(before_tick: int) -> Dictionary:
	return _memory.summarisation_job(before_tick, profile)
