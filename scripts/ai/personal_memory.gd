extends RefCounted
## An append-only record of one character's permitted experience.
## Summarisation is deliberately a separate, currently unimplemented role.

var _owner: String = ""
var _run_id: int = -1
var _entries: Array = []
var _ticks: Dictionary = {}


func configure(owner: String) -> void:
	_owner = owner


func reset(run_id: int) -> void:
	_run_id = run_id
	_entries.clear()
	_ticks.clear()


func append(observation: Dictionary, image_png: PackedByteArray = PackedByteArray()) -> bool:
	var tick: int = int(observation.get("tick", -1))
	if tick < 0 or _ticks.has(tick):
		return false
	var entry: Dictionary = personal_context(observation)
	# Copy image bytes now: later rendering cannot rewrite an old observation.
	var blind: bool = bool(entry.get("self_state", {}).get("body", {}).get("blind", false))
	entry["image_png_base64"] = "" if blind or image_png.is_empty() else Marshalls.raw_to_base64(image_png.duplicate())
	entry["channel"] = "personal_observation"
	_entries.append(entry.duplicate(true))
	_ticks[tick] = true
	return true


func entries() -> Array:
	return _entries.duplicate(true)


func text_context(limit: int = 12) -> Array:
	var result: Array = []
	for entry in _entries.slice(maxi(0, _entries.size() - limit)):
		var copy: Dictionary = entry.duplicate(true)
		copy.erase("image_png_base64")
		copy.erase("profile")
		result.append(copy)
	return result


func summarisation_job(before_tick: int, profile: Dictionary) -> Dictionary:
	# This contract receives only the owner's own old experiences. It cannot
	# access the simulation, observer archive, mock geometry, or other memories.
	var older: Array = []
	for entry in _entries:
		if int(entry.get("tick", -1)) < before_tick:
			older.append(entry.duplicate(true))
	return {"role": "memory", "version": 0, "profile": clean_profile(profile),
		"older_personal_experience": older, "status": "summarisation_not_implemented"}


func export_state() -> Dictionary:
	return {"owner": _owner, "run_id": _run_id, "entries": entries()}


func import_state(data: Variant, run_id: int) -> bool:
	# Validate the entire candidate before touching existing immutable records.
	if not data is Dictionary or run_id < 0 or _owner.is_empty():
		return false
	if not _keys_only(data, ["owner", "run_id", "entries"]) or data.get("owner") != _owner:
		return false
	if not _integer_in_range(data.get("run_id"), 0, 2147483647) or not data.get("entries") is Array:
		return false
	var incoming: Array = data.entries
	if incoming.size() > 100000:
		return false
	var seen: Dictionary = {}
	var previous_tick: int = -1
	for raw in incoming:
		if not _valid_entry(raw):
			return false
		var tick: int = int(raw.tick)
		if tick <= previous_tick:
			return false
		previous_tick = tick
		seen[tick] = true
	_run_id = run_id
	_entries = incoming.duplicate(true)
	_ticks = seen
	return true


static func _keys_only(data: Dictionary, keys: Array) -> bool:
	for key in data:
		if not key is String or not keys.has(key):
			return false
	return true


static func _number_in_range(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= minimum and float(value) <= maximum


static func _integer_in_range(value: Variant, minimum: int, maximum: int) -> bool:
	return _number_in_range(value, minimum, maximum) and float(value) == floorf(float(value))


static func _text(value: Variant, maximum: int) -> bool:
	return value is String and value.length() <= maximum


static func _valid_profile(data: Variant) -> bool:
	if not data is Dictionary or not _keys_only(data, ["foundation", "traits"]):
		return false
	if not _text(data.get("foundation"), 8192) or not data.get("traits") is Array or data.traits.size() > 64:
		return false
	for personality_trait in data.traits:
		if not _text(personality_trait, 512):
			return false
	return true


static func _valid_entry(raw: Variant) -> bool:
	if not raw is Dictionary or not _keys_only(raw, ["tick", "self_state", "inventory", "heard", "last_result", "profile", "image_png_base64", "channel"]):
		return false
	if not _integer_in_range(raw.get("tick"), 0, 2147483647) or raw.get("channel") != "personal_observation":
		return false
	var own: Variant = raw.get("self_state")
	if not own is Dictionary or not _keys_only(own, ["name", "needs", "body"]) or not _text(own.get("name"), 128):
		return false
	var needs: Variant = own.get("needs")
	if not needs is Dictionary or not _keys_only(needs, ["hunger", "fatigue"]):
		return false
	for key in ["hunger", "fatigue"]:
		if not _number_in_range(needs.get(key), 0.0, 100.0):
			return false
	var body: Variant = own.get("body")
	if not body is Dictionary or not _keys_only(body, ["blind", "left_arm", "right_arm", "left_leg", "right_leg"]) or not body.get("blind") is bool:
		return false
	for limb in ["left_arm", "right_arm", "left_leg", "right_leg"]:
		if not body.get(limb) is String or not ["healthy", "injured", "broken"].has(body[limb]):
			return false
	if not raw.get("inventory") is Array or raw.inventory.size() > 32:
		return false
	for index in raw.inventory.size():
		var item: Variant = raw.inventory[index]
		if not item is Dictionary or not _keys_only(item, ["slot", "label", "kind"]):
			return false
		if not _integer_in_range(item.get("slot"), index, index) or not _text(item.get("label"), 512) or not _text(item.get("kind"), 64):
			return false
	if not raw.get("heard") is Array or raw.heard.size() > 128:
		return false
	for speech in raw.heard:
		if not speech is Dictionary or not _keys_only(speech, ["speaker", "text", "bearing", "distance", "source"]):
			return false
		if not _text(speech.get("speaker"), 128) or not _text(speech.get("text"), 280) or speech.get("source") != "heard_speech":
			return false
		if not _number_in_range(speech.get("bearing"), -180.0, 180.0) or not _number_in_range(speech.get("distance"), 0.0, 1000.0):
			return false
	var last: Variant = raw.get("last_result")
	if not last is Dictionary or not _keys_only(last, ["ok", "message", "type", "reason"]):
		return false
	if last.has("ok") and not last.ok is bool:
		return false
	for key in ["message", "type", "reason"]:
		if last.has(key) and not _text(last[key], 2048):
			return false
	if not _valid_profile(raw.get("profile")) or not _valid_base64(raw.get("image_png_base64")):
		return false
	return not body.blind or raw.image_png_base64.is_empty()


static func _valid_base64(value: Variant) -> bool:
	if not value is String or value.length() > 4 * 1024 * 1024 or value.length() % 4 != 0:
		return false
	if value.is_empty():
		return true
	var pattern := RegEx.create_from_string("^[A-Za-z0-9+/]*={0,2}$")
	if pattern.search(value) == null:
		return false
	var decoded: PackedByteArray = Marshalls.base64_to_raw(value)
	return not decoded.is_empty() and Marshalls.raw_to_base64(decoded) == value


static func clean_profile(profile: Dictionary) -> Dictionary:
	var traits: Array = []
	for personality_trait in profile.get("traits", []):
		if personality_trait is String:
			traits.append(personality_trait)
	return {"foundation": str(profile.get("foundation", "")), "traits": traits}


static func personal_context(observation: Dictionary) -> Dictionary:
	# Reconstruct each field rather than copying arbitrary observer data.
	var own: Dictionary = observation.get("self_state", {})
	var needs: Dictionary = own.get("needs", {})
	var body: Dictionary = own.get("body", {})
	var own_body: Dictionary = {"blind": bool(body.get("blind", false))}
	for limb in ["left_arm", "right_arm", "left_leg", "right_leg"]:
		own_body[limb] = str(body.get(limb, "healthy"))
	var own_inventory: Array = []
	for item in observation.get("inventory", []):
		if item is Dictionary:
			own_inventory.append({"slot": int(item.get("slot", 0)),
				"label": str(item.get("label", "")), "kind": str(item.get("kind", ""))})
	var heard: Array = []
	for speech in observation.get("heard", []):
		if speech is Dictionary:
			heard.append({"speaker": str(speech.get("speaker", "Someone")),
				"text": str(speech.get("text", "")), "bearing": float(speech.get("bearing", 0.0)),
				"distance": float(speech.get("distance", 0.0)), "source": "heard_speech"})
	var last: Dictionary = observation.get("last_result", {})
	var safe_last: Dictionary = {}
	# Engine-specific details may contain target IDs or hidden geometry: omit them.
	for key in ["ok", "message", "type", "reason"]:
		if last.has(key) and (last[key] is String or last[key] is bool):
			safe_last[key] = last[key]
	return {"tick": int(observation.get("tick", -1)),
		"self_state": {"name": str(own.get("name", "")),
			"needs": {"hunger": float(needs.get("hunger", 0.0)), "fatigue": float(needs.get("fatigue", 0.0))},
			"body": own_body},
		"inventory": own_inventory, "heard": heard, "last_result": safe_last,
		"profile": clean_profile(observation.get("profile", {}))}
