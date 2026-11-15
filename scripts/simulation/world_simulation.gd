class_name WorldSimulation
extends RefCounted
## Authoritative, render-independent fixed-step world. No network calls live here.

const VERSION := 1
const AGENT_RADIUS := 0.30
const REACH := 1.45
const VISION_RANGE := 12.0
const HALF_FOV := 45.0
const HEARING_RANGE := 7.0
const ACTION_FIELDS := {
	"wait": ["type"], "look": ["type"], "move": ["type", "forward", "right"],
	"turn": ["type", "degrees"], "take": ["type"], "put": ["type", "slot"],
	"give": ["type", "slot"], "speak": ["type", "text"]
}

var state: Dictionary = {}
var _run_serial := 0
var _initial_state: Dictionary = {}
var _records: Array = []
var _heard: Dictionary = {}


func _init() -> void:
	reset()


func reset(scenario: String = "closed_block") -> Dictionary:
	_run_serial += 1
	var agents := {
		"ada": _agent("ada", "Ada", "e6ae55", [4.0, -3.2], -90.0,
			"Curious, cooperative engineer. Values evidence and helping others.", ["observant", "generous"]),
		"boris": _agent("boris", "Boris", "65b6d6", [-0.5, -3.2], 90.0,
			"Pragmatic survivor. Values fairness and checking claims personally.", ["skeptical", "resourceful"]),
		"cora": _agent("cora", "Cora", "c191cf", [-4.0, 2.0], 0.0,
			"Patient mediator. Values companionship and careful exploration.", ["calm", "social"])
	}
	var items := {
		"ration_storage": _item("ration_storage", "ration pack", "ration", [5.0, -3.2]),
		"ration_hidden": _item("ration_hidden", "sealed ration pack", "ration", [6.0, 3.0]),
		"mug_common": _item("mug_common", "red mug", "prop", [-3.0, 1.0]),
		"torch_common": _item("torch_common", "flashlight", "prop", [0.0, -4.8])
	}
	if scenario == "last_ration":
		agents.boris.position = [6.0, -3.2]
		agents.boris.heading = 90.0
		items.erase("ration_hidden")
	state = {
		"version": VERSION, "run_id": _run_serial, "tick": 0, "elapsed_minutes": 0,
		"scenario": scenario, "agents": agents, "items": items,
		"geometry": _geometry(), "events": []
	}
	_heard = {"ada": [], "boris": [], "cora": []}
	_records = []
	_initial_state = state.duplicate(true)
	return snapshot()


func _agent(id: String, agent_name: String, color: String, pos: Array, heading: float,
		foundation: String, traits: Array) -> Dictionary:
	return {
		"id": id, "name": agent_name, "color": color, "position": pos, "heading": heading,
		"profile": {"foundation": foundation, "traits": traits},
		"needs": {"hunger": 20.0, "fatigue": 5.0},
		"body": {"blind": false, "left_arm": "healthy", "right_arm": "healthy",
			"left_leg": "healthy", "right_leg": "healthy"},
		"inventory": [], "last_action": {}, "last_result": {}
	}


func _item(id: String, label: String, kind: String, pos: Array) -> Dictionary:
	return {"id": id, "label": label, "kind": kind, "position": pos, "holder": ""}


func _geometry() -> Dictionary:
	return {"walls": [
		_wall("outer_west", [-9.0, 0.0], [0.2, 12.2]),
		_wall("outer_east", [9.0, 0.0], [0.2, 12.2]),
		_wall("outer_north", [0.0, -6.0], [18.0, 0.2]),
		_wall("outer_south", [0.0, 6.0], [18.0, 0.2]),
		_wall("partition_north", [2.0, -5.1], [0.2, 1.8]),
		_wall("partition_middle", [2.0, -0.1], [0.2, 4.2]),
		_wall("partition_south", [2.0, 4.9], [0.2, 2.2]),
		_wall("east_divider", [5.5, 0.0], [7.0, 0.2])
	], "doors": [{"id": "side_door", "center": [2.0, 2.9],
		"size": [0.2, 1.8], "height": 2.8, "open": false}]}


func _wall(id: String, center: Array, size: Array) -> Dictionary:
	return {"id": id, "center": center, "size": size, "height": 2.8}


func snapshot() -> Dictionary:
	return state.duplicate(true)


func get_state() -> Dictionary:
	return snapshot()


func step(actions: Dictionary, expected_run_id: int = -1) -> Array:
	if expected_run_id != -1 and expected_run_id != int(state.run_id):
		return []
	# All decisions come from one frozen snapshot. Arbitration never uses request order.
	var before := snapshot()
	var ids: Array = state.agents.keys()
	ids.sort()
	var ordered: Array = []
	for offset in range(ids.size()):
		ordered.append(ids[(int(state.tick) + offset) % ids.size()])
	state.tick = int(state.tick) + 1
	state.elapsed_minutes = int(state.elapsed_minutes) + 1
	_heard = {}
	for id in ids:
		_heard[id] = []
	var events: Array = []
	for id in ordered:
		var raw: Variant = actions.get(id, {"type": "wait"})
		var checked := _validate_action(raw)
		var event: Dictionary
		if not checked.ok:
			event = _event(id, "invalid_action", false, checked.error, {})
			state.agents[id].last_action = {"type": "invalid"}
		else:
			var action: Dictionary = checked.action
			state.agents[id].last_action = action.duplicate(true)
			event = _execute(id, action, before)
		state.agents[id].last_result = {"ok": event.ok, "type": event.type, "message": event.message}
		events.append(event)
		state.events.append(event)
	for id in ids:
		var needs: Dictionary = state.agents[id].needs
		needs.hunger = minf(100.0, float(needs.hunger) + 0.35)
	_records.append({"tick": state.tick, "actions": actions.duplicate(true),
		"state": snapshot(), "heard": _heard.duplicate(true)})
	return events.duplicate(true)


func _validate_action(raw: Variant) -> Dictionary:
	if not raw is Dictionary or not raw.get("type") is String:
		return {"ok": false, "error": "Action must be an object with a string type."}
	var action: Dictionary = raw
	var kind: String = action.type
	if not ACTION_FIELDS.has(kind):
		return {"ok": false, "error": "Unknown action type."}
	var fields: Array = ACTION_FIELDS[kind]
	if action.size() != fields.size():
		return {"ok": false, "error": "Action fields do not match its strict schema."}
	for key in fields:
		if not action.has(key):
			return {"ok": false, "error": "A required action field is missing."}
	if kind == "move":
		if not _number(action.forward) or not _number(action.right):
			return {"ok": false, "error": "Movement must use finite numbers."}
		if absf(float(action.forward)) > 1.0 or absf(float(action.right)) > 1.0:
			return {"ok": false, "error": "Movement component exceeds one metre."}
		if Vector2(float(action.forward), float(action.right)).length() > 1.00001:
			return {"ok": false, "error": "Combined movement exceeds one metre."}
	if kind == "turn":
		if not _number(action.degrees) or absf(float(action.degrees)) > 180.0:
			return {"ok": false, "error": "Turn must be finite and within 180 degrees."}
	if kind in ["put", "give"]:
		if not _number(action.slot) or float(action.slot) != floorf(float(action.slot)) or int(action.slot) < 0:
			return {"ok": false, "error": "Inventory slot must be a nonnegative integer."}
	if kind == "speak":
		if not action.text is String or action.text.is_empty() or action.text.length() > 280:
			return {"ok": false, "error": "Speech must be text of 1 to 280 characters."}
	return {"ok": true, "action": action.duplicate(true)}


func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _execute(id: String, action: Dictionary, frozen: Dictionary) -> Dictionary:
	var agent: Dictionary = state.agents[id]
	var kind: String = action.type
	match kind:
		"wait":
			agent.needs.fatigue = maxf(0.0, float(agent.needs.fatigue) - 0.4)
			return _event(id, kind, true, "Waited and rested.", {})
		"look":
			return _event(id, kind, true, "Observed the current view." if not agent.body.blind else "Listened; vision is unavailable.", {})
		"turn":
			agent.heading = wrapf(float(agent.heading) + float(action.degrees), -180.0, 180.0)
			return _event(id, kind, true, "Turned %.1f degrees." % float(action.degrees), {})
		"move":
			return _move(id, action)
		"take":
			if _healthy_hands(agent) == 0:
				return _event(id, kind, false, "Both arms are broken; cannot take an item.", {})
			var target := _nearest_item(id, frozen)
			if target.is_empty():
				return _event(id, kind, false, "No visible ground item within reach and gaze.", {})
			if not String(state.items[target].holder).is_empty():
				return _event(id, kind, false, "The item is no longer available; another action claimed it.", {})
			if not _visible(agent, _position(state.items[target]), state, REACH):
				return _event(id, kind, false, "The item moved out of reach before execution.", {})
			state.items[target].holder = id
			agent.inventory.append(target)
			return _event(id, kind, true, "Took %s." % state.items[target].label, {"item": target})
		"put", "give":
			var slot := int(action.slot)
			if slot >= frozen.agents[id].inventory.size():
				return _event(id, kind, false, "Inventory slot is empty.", {})
			if _healthy_hands(agent) == 0:
				return _event(id, kind, false, "Both arms are broken; cannot manipulate an item.", {})
			var item_id: String = frozen.agents[id].inventory[slot]
			if not agent.inventory.has(item_id):
				return _event(id, kind, false, "The item is no longer held.", {})
			if kind == "put":
				agent.inventory.erase(item_id)
				state.items[item_id].holder = ""
				state.items[item_id].position = agent.position.duplicate()
				return _event(id, kind, true, "Put down %s." % state.items[item_id].label, {"item": item_id})
			var recipient := _nearest_person(id, frozen)
			if recipient.is_empty():
				return _event(id, kind, false, "No visible person within reach and gaze.", {})
			if not _visible(agent, _position(state.agents[recipient]), state, REACH):
				return _event(id, kind, false, "The recipient moved out of reach before execution.", {})
			if _healthy_hands(state.agents[recipient]) == 0:
				return _event(id, kind, false, "The recipient cannot hold an item with both arms broken.", {})
			agent.inventory.erase(item_id)
			state.agents[recipient].inventory.append(item_id)
			state.items[item_id].holder = recipient
			return _event(id, kind, true, "Gave %s to %s." % [state.items[item_id].label, state.agents[recipient].name], {"item": item_id, "recipient": recipient})
		"speak":
			var listeners: Array = []
			for other in frozen.agents:
				if other == id:
					continue
				var listener: Dictionary = frozen.agents[other]
				var speaker: Dictionary = frozen.agents[id]
				var distance := _position(listener).distance_to(_position(speaker))
				if distance <= HEARING_RANGE and _line_clear(_position(listener), _position(speaker), frozen):
					_heard[other].append({"speaker": agent.name, "text": action.text,
						"bearing": _bearing(listener, _position(speaker)), "distance": snappedf(distance, 0.01)})
					listeners.append(other)
			return _event(id, kind, true, "%s: %s" % [agent.name, action.text], {"listeners": listeners, "text": action.text})
	return _event(id, kind, false, "Unsupported action.", {})


func _move(id: String, action: Dictionary) -> Dictionary:
	var agent: Dictionary = state.agents[id]
	var body: Dictionary = agent.body
	var broken_legs := int(body.left_leg == "broken") + int(body.right_leg == "broken")
	if broken_legs == 2 and _healthy_hands(agent) == 0:
		return _event(id, "move", false, "All four limbs are broken; independent movement is unavailable.", {})
	var injured: bool = body.left_leg != "healthy" or body.right_leg != "healthy"
	var speed := 0.25 if broken_legs == 2 else (0.55 if injured else 1.0)
	var rad := deg_to_rad(float(agent.heading))
	var forward := Vector2(-sin(rad), -cos(rad))
	var right := Vector2(cos(rad), -sin(rad))
	var delta := (forward * float(action.forward) + right * float(action.right)) * speed
	var origin := _position(agent)
	var destination := origin + delta
	if not _within_floor(destination):
		return _event(id, "move", false, "Movement blocked by the edge of the floor.", {})
	if not _line_clear(origin, destination, state, AGENT_RADIUS):
		return _event(id, "move", false, "Movement blocked by a wall or closed door.", {})
	for other in state.agents:
		if other == id:
			continue
		var center := _position(state.agents[other])
		var closest := Geometry2D.get_closest_point_to_segment(center, origin, destination)
		if closest.distance_to(center) < AGENT_RADIUS * 2.0 - 0.00001:
			return _event(id, "move", false, "Movement blocked by another person.", {})
	agent.position = [destination.x, destination.y]
	agent.needs.fatigue = minf(100.0, float(agent.needs.fatigue) + delta.length() * (2.0 if injured else 0.5))
	var mode := "crawled" if broken_legs == 2 else ("limped" if injured else "walked")
	return _event(id, "move", true, "%s %.2f m." % [mode.capitalize(), delta.length()], {"distance": delta.length(), "mode": mode})


func _healthy_hands(agent: Dictionary) -> int:
	return int(agent.body.left_arm != "broken") + int(agent.body.right_arm != "broken")


func _nearest_item(id: String, frozen: Dictionary) -> String:
	var agent: Dictionary = frozen.agents[id]
	var winner := ""
	var distance := INF
	var ids: Array = frozen.items.keys()
	ids.sort()
	for item_id in ids:
		var item: Dictionary = frozen.items[item_id]
		if not String(item.holder).is_empty() or not _visible(agent, _position(item), frozen, REACH):
			continue
		var candidate := _position(agent).distance_to(_position(item))
		if candidate < distance:
			distance = candidate
			winner = item_id
	return winner


func _nearest_person(id: String, frozen: Dictionary) -> String:
	var agent: Dictionary = frozen.agents[id]
	var winner := ""
	var distance := INF
	var ids: Array = frozen.agents.keys()
	ids.sort()
	for other in ids:
		if other == id or not _visible(agent, _position(frozen.agents[other]), frozen, REACH):
			continue
		var candidate := _position(agent).distance_to(_position(frozen.agents[other]))
		if candidate < distance:
			distance = candidate
			winner = other
	return winner


func observe(agent_id: String) -> Dictionary:
	if not state.agents.has(agent_id):
		return {}
	var agent: Dictionary = state.agents[agent_id]
	var inventory: Array = []
	for slot in range(agent.inventory.size()):
		var item: Dictionary = state.items[agent.inventory[slot]]
		inventory.append({"slot": slot, "label": item.label, "kind": item.kind})
	var view: Array = []
	for item_id in state.items:
		var item: Dictionary = state.items[item_id]
		if String(item.holder).is_empty() and _visible(agent, _position(item), state):
			view.append(_view_entry(agent, item.kind, item.label, _position(item)))
	for other in state.agents:
		if other != agent_id and _visible(agent, _position(state.agents[other]), state):
			view.append(_view_entry(agent, "person", "%s clothing" % state.agents[other].color, _position(state.agents[other])))
	return {"tick": state.tick,
		"self_state": {"name": agent.name, "needs": agent.needs.duplicate(true), "body": agent.body.duplicate(true)},
		"inventory": inventory, "heard": _heard.get(agent_id, []).duplicate(true),
		"last_result": agent.last_result.duplicate(true), "profile": agent.profile.duplicate(true),
		"memory": [], "mock_view": view}


func _view_entry(agent: Dictionary, kind: String, label: String, point: Vector2) -> Dictionary:
	return {"kind": kind, "label": label, "distance": snappedf(_position(agent).distance_to(point), 0.01),
		"bearing": snappedf(_bearing(agent, point), 0.1)}


func _position(entity: Dictionary) -> Vector2:
	return Vector2(float(entity.position[0]), float(entity.position[1]))


func _bearing(agent: Dictionary, point: Vector2) -> float:
	var delta := point - _position(agent)
	return wrapf(rad_to_deg(atan2(-delta.x, -delta.y)) - float(agent.heading), -180.0, 180.0)


func _visible(agent: Dictionary, point: Vector2, world: Dictionary, max_range: float = VISION_RANGE) -> bool:
	return not agent.body.blind and _position(agent).distance_to(point) <= max_range \
		and absf(_bearing(agent, point)) <= HALF_FOV and _line_clear(_position(agent), point, world)


func _line_clear(origin: Vector2, target: Vector2, world: Dictionary, margin: float = 0.0) -> bool:
	for wall in world.geometry.walls:
		if _segment_hits_rectangle(origin, target, wall, margin):
			return false
	for door in world.geometry.doors:
		if not door.open and _segment_hits_rectangle(origin, target, door, margin):
			return false
	return true


func _segment_hits_rectangle(origin: Vector2, target: Vector2, obstacle: Dictionary, margin: float) -> bool:
	var center := Vector2(float(obstacle.center[0]), float(obstacle.center[1]))
	var half := Vector2(float(obstacle.size[0]), float(obstacle.size[1])) * 0.5 + Vector2.ONE * margin
	var low := center - half
	var high := center + half
	var direction := target - origin
	var t_min := 0.0
	var t_max := 1.0
	for axis in range(2):
		if absf(direction[axis]) < 0.000001:
			if origin[axis] < low[axis] or origin[axis] > high[axis]:
				return false
		else:
			var a := (low[axis] - origin[axis]) / direction[axis]
			var b := (high[axis] - origin[axis]) / direction[axis]
			t_min = maxf(t_min, minf(a, b))
			t_max = minf(t_max, maxf(a, b))
			if t_min > t_max:
				return false
	return true


func _event(actor: String, kind: String, ok: bool, message: String, details: Dictionary) -> Dictionary:
	return {"seq": state.events.size(), "tick": state.tick, "type": kind, "actor": actor,
		"ok": ok, "message": message, "details": details}


func save_to(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"version": VERSION, "state": state,
		"initial_state": _initial_state, "records": _records, "heard": _heard}))
	return OK


func load_from(path: String) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not _valid_save(parsed):
		return ERR_FILE_CORRUPT
	_run_serial = maxi(_run_serial, int(parsed.state.run_id)) + 1
	state = parsed.state.duplicate(true)
	state.run_id = _run_serial
	_initial_state = parsed.initial_state.duplicate(true)
	_records = parsed.records.duplicate(true)
	_heard = parsed.heard.duplicate(true)
	return OK


func _valid_save(value: Variant) -> bool:
	if not value is Dictionary or value.get("version") != VERSION:
		return false
	if not value.get("state") is Dictionary or not value.get("initial_state") is Dictionary \
		or not value.get("records") is Array or not value.get("heard") is Dictionary:
		return false
	if not _valid_world(value.state) or not _valid_world(value.initial_state) or not _valid_heard(value.heard):
		return false
	if int(value.initial_state.tick) != 0 or int(value.state.tick) != value.records.size():
		return false
	var latest: Dictionary = value.initial_state
	var latest_heard: Dictionary = {"ada": [], "boris": [], "cora": []}
	for index in range(value.records.size()):
		var record: Variant = value.records[index]
		if not record is Dictionary or not _whole(record.get("tick")) or int(record.tick) != index + 1:
			return false
		if not _valid_world(record.get("state")) or not _valid_heard(record.get("heard")):
			return false
		if int(record.state.tick) != index + 1:
			return false
		# The journal is append-only: earlier world events cannot disappear or
		# change in a later snapshot, even if each isolated snapshot is well-typed.
		if record.state.events.size() != latest.events.size() + value.state.agents.size():
			return false
		for event_index in range(latest.events.size()):
			if record.state.events[event_index] != latest.events[event_index]:
				return false
		for event_index in range(latest.events.size(), record.state.events.size()):
			if int(record.state.events[event_index].tick) != index + 1:
				return false
		latest = record.state
		latest_heard = record.heard
	# Loading changes only the generation token. Every other live field must
	# equal the replay endpoint, including speech delivered at that endpoint.
	if not _same_authority(value.state, latest) or value.heard != latest_heard:
		return false
	return true


func _same_authority(left: Dictionary, right: Dictionary) -> bool:
	var left_copy := left.duplicate(true)
	var right_copy := right.duplicate(true)
	left_copy.erase("run_id")
	right_copy.erase("run_id")
	return left_copy == right_copy


func _whole(value: Variant) -> bool:
	return _number(value) and float(value) == floorf(float(value))


func _valid_position(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _number(value[0]) and _number(value[1])


func _within_floor(point: Vector2) -> bool:
	# Floor bounds remain authoritative even if a debug scenario omits an outer wall.
	return absf(point.x) + AGENT_RADIUS <= 9.000001 and absf(point.y) + AGENT_RADIUS <= 6.000001


func _valid_world(value: Variant) -> bool:
	if not value is Dictionary or value.get("version") != VERSION:
		return false
	for field in ["run_id", "tick", "elapsed_minutes"]:
		if not _whole(value.get(field)) or float(value[field]) < 0.0:
			return false
	if not value.get("scenario") is String or not value.get("agents") is Dictionary \
		or not value.get("items") is Dictionary or not value.get("geometry") is Dictionary \
		or not value.get("events") is Array:
		return false
	if value.agents.size() != 3:
		return false
	var held: Dictionary = {}
	for id in ["ada", "boris", "cora"]:
		var raw: Variant = value.agents.get(id)
		if not raw is Dictionary:
			return false
		var agent: Dictionary = raw
		if agent.get("id") != id or not agent.get("name") is String or not agent.get("color") is String:
			return false
		if not Color.html_is_valid(agent.color) or not _valid_position(agent.get("position")) or not _number(agent.get("heading")):
			return false
		if absf(float(agent.position[0])) > 9.0 or absf(float(agent.position[1])) > 6.0:
			return false
		if not agent.get("body") is Dictionary or not agent.body.get("blind") is bool:
			return false
		for limb in ["left_arm", "right_arm", "left_leg", "right_leg"]:
			if not agent.body.get(limb) in ["healthy", "injured", "broken"]:
				return false
		if not agent.get("needs") is Dictionary:
			return false
		for need in ["hunger", "fatigue"]:
			if not _number(agent.needs.get(need)) or float(agent.needs[need]) < 0.0 or float(agent.needs[need]) > 100.0:
				return false
		if not agent.get("profile") is Dictionary or not agent.profile.get("foundation") is String or not agent.profile.get("traits") is Array:
			return false
		for trait_value in agent.profile.traits:
			if not trait_value is String:
				return false
		if not agent.get("last_action") is Dictionary or not agent.get("last_result") is Dictionary or not agent.get("inventory") is Array:
			return false
		for item_id in agent.inventory:
			if not item_id is String or held.has(item_id):
				return false
			held[item_id] = id
	for item_id in value.items:
		if not item_id is String or not value.items[item_id] is Dictionary:
			return false
		var item: Dictionary = value.items[item_id]
		if item.get("id") != item_id or not item.get("label") is String or not item.get("kind") is String \
			or not item.get("holder") is String or not _valid_position(item.get("position")):
			return false
		if String(item.holder).is_empty():
			if held.has(item_id):
				return false
		elif not value.agents.has(item.holder) or held.get(item_id) != item.holder:
			return false
	for item_id in held:
		if not value.items.has(item_id):
			return false
	if not value.geometry.get("walls") is Array or not value.geometry.get("doors") is Array:
		return false
	for wall in value.geometry.walls:
		if not _valid_obstacle(wall, false):
			return false
	for door in value.geometry.doors:
		if not _valid_obstacle(door, true):
			return false
	# A structurally valid snapshot is still corrupt if a body is outside the
	# floor, intersects a solid rectangle, or overlaps another body's capsule.
	var agent_ids: Array = value.agents.keys()
	for index in range(agent_ids.size()):
		var point := _position(value.agents[agent_ids[index]])
		if not _within_floor(point) or not _line_clear(point, point, value, AGENT_RADIUS):
			return false
		for other_index in range(index + 1, agent_ids.size()):
			if point.distance_to(_position(value.agents[agent_ids[other_index]])) < AGENT_RADIUS * 2.0 - 0.00001:
				return false
	for index in range(value.events.size()):
		var event: Variant = value.events[index]
		if not event is Dictionary or not _whole(event.get("seq")) or int(event.seq) != index:
			return false
		if not _whole(event.get("tick")) or float(event.tick) < 0.0 or float(event.tick) > float(value.tick):
			return false
		if not event.get("actor") is String or not value.agents.has(event.actor) or not event.get("type") is String \
			or not event.get("message") is String or not event.get("ok") is bool or not event.get("details") is Dictionary:
			return false
	return true


func _valid_obstacle(value: Variant, door: bool) -> bool:
	if not value is Dictionary or not value.get("id") is String or not _valid_position(value.get("center")) \
		or not _valid_position(value.get("size")) or not _number(value.get("height")):
		return false
	if float(value.size[0]) <= 0.0 or float(value.size[1]) <= 0.0 or float(value.height) <= 0.0:
		return false
	return not door or value.get("open") is bool


func _valid_heard(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 3:
		return false
	for id in ["ada", "boris", "cora"]:
		if not value.get(id) is Array:
			return false
		for entry in value[id]:
			if not entry is Dictionary or not entry.get("speaker") is String or not entry.get("text") is String \
				or not _number(entry.get("bearing")) or not _number(entry.get("distance")) or float(entry.distance) < 0.0:
				return false
	return true


func replay_to(tick: int = -1) -> Dictionary:
	var target := _records.size() if tick < 0 else clampi(tick, 0, _records.size())
	var restored: Dictionary = _initial_state.duplicate(true) if target == 0 else _records[target - 1].state.duplicate(true)
	# Read-only review never changes the live world's tick, generation or speech inbox.
	return restored
