extends RefCounted
## Shared public intention schema. World identifiers are never model targets.
const DEVICE_APPS := ["contacts","messages","gallery","forum","votes","pages","game","network"]

const SCHEMAS := {
	"wait": {"minutes":"number?"}, "look": {}, "turn": {"degrees":"number"}, "set_goal":{"text":"string"},
	"move": {"forward":"number", "right":"number"}, "move_to": {"target":"string"}, "follow_route":{"route":"string"},
	"take": {"target":"string?"}, "put": {"slot":"integer", "target":"string?"},
	"give": {"slot":"integer", "target":"string"}, "consume": {"slot":"integer"},
	"rest": {"minutes":"number?"}, "sleep": {"minutes":"number?"}, "wake": {},
	"open": {"target":"string"}, "close": {"target":"string"}, "unlock": {"target":"string"},
	"interact": {"target":"string"}, "attack": {"target":"string"}, "defend": {},
	"flee": {"target":"string?"}, "treat": {"target":"string?", "slot":"integer", "limb":"string?"},
	"help": {"target":"string"}, "carry": {"target":"string"}, "release": {},
	"speak": {"text":"string"}, "offer": {"target":"string", "slot":"integer?", "tokens":"integer?", "request_tokens":"integer?", "promise":"string?", "deadline":"number?"},
	"accept_offer": {"offer":"string"}, "transfer_tokens": {"target":"string", "tokens":"integer"},
	"request_ration": {}, "join_queue": {"kind":"string?"}, "return_device": {"slot":"integer"},
	"write_diary": {"text":"string"}, "read_diary": {"slot":"integer"},
	"take_photo": {"digital":"boolean?"}, "show_photo": {"slot":"integer", "target":"string", "index":"integer?"},
	"view_photo": {"slot":"integer", "index":"integer?"},
	"copy_photo": {"slot":"integer", "index":"integer?"}, "destroy": {"slot":"integer"},
	"use_device": {"slot":"integer", "app":"string"}, "read_screen": {}, "login": {"slot":"integer"}, "logout": {"slot":"integer"},
	"send_message": {"contact":"string", "text":"string", "attachment":"integer?", "attachment_index":"integer?"},
	"create_group":{"title":"string","members":"array"},"leave_group":{"group":"string"},
	"read_message": {"message":"string"}, "delete_message": {"message":"string"},
	"replace_message": {"message":"string", "text":"string"}, "set_network": {"online":"boolean", "delay":"number?"},
	"create_topic": {"title":"string", "text":"string"}, "reply": {"topic":"string", "text":"string"},
	"create_vote": {"title":"string", "options":"array", "minutes":"number?"},
	"vote": {"poll":"string", "option":"integer"}, "read_page": {"page":"string"},
	"publish_page": {"page":"string", "title":"string", "text":"string"},
	"play_game": {"contact":"string?", "cell":"integer?"},
	"buy": {"target":"string", "kind":"string?"}, "sell": {"slot":"integer"},
	"fulfil_promise": {"offer":"string"}
}

static func validate(raw: Variant) -> Dictionary:
	if not raw is Dictionary or not raw.get("type") is String:
		return _bad("Intention must be an object with a string type.")
	var kind: String = raw.type
	if not SCHEMAS.has(kind):
		return _bad("Unsupported action type.")
	var schema: Dictionary = SCHEMAS[kind]
	for key in raw:
		if key != "type" and not schema.has(key):
			return _bad("Unknown action field: " + str(key))
	for key in schema:
		var rule: String = schema[key]
		if not raw.has(key):
			if rule.ends_with("?"):
				continue
			return _bad("Missing field: " + str(key))
		rule = rule.trim_suffix("?")
		var value: Variant = raw[key]
		match rule:
			"number":
				if not (value is int or value is float) or not is_finite(float(value)):
					return _bad("A finite number is required: " + str(key))
			"integer":
				if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floorf(float(value)) or float(value) < 0.0:
					return _bad("A non-negative integer is required: " + str(key))
			"string":
				if not value is String or value.is_empty() or value.length() > (2000 if key in ["text", "promise"] else 120):
					return _bad("Invalid text field: " + str(key))
			"boolean":
				if not value is bool:
					return _bad("A boolean is required: " + str(key))
			"array":
				var minimum:=1 if key=="members" else 2
				var maximum:=19 if key=="members" else 8
				if not value is Array or value.size() < minimum or value.size() > maximum:
					return _bad("Array size is outside its allowed range.")
				for entry in value:
					if not entry is String or entry.is_empty() or entry.length() > 120:
						return _bad("Invalid option text.")
	if kind == "turn" and absf(float(raw.degrees)) > 180.0:
		return _bad("Turn must be within 180 degrees.")
	if kind == "move" and Vector2(float(raw.forward), float(raw.right)).length() > 5.0:
		return _bad("Relative move must be at most five metres.")
	if raw.has("minutes") and (float(raw.minutes) <= 0.0 or float(raw.minutes) > 720.0):
		return _bad("Duration must be in (0,720] game minutes.")
	if raw.has("delay") and (float(raw.delay) < 0.0 or float(raw.delay) > 1440.0):
		return _bad("Network delay is outside its allowed range.")
	if kind == "play_game" and raw.has("cell") and int(raw.cell) > 8:
		return _bad("Game cell must be 0–8.")
	if kind == "use_device" and not DEVICE_APPS.has(raw.app):
		return _bad("Unknown device app. Use one of: " + ", ".join(DEVICE_APPS))
	if kind=="send_message" and raw.has("attachment_index") and not raw.has("attachment"):
		return _bad("An attachment index requires an inventory attachment slot.")
	return {"ok":true,"action":raw.duplicate(true),"error":""}

static func _bad(message: String) -> Dictionary:
	return {"ok":false,"action":{"type":"wait"},"error":message}

static func instructions() -> String:
	return "Each action must have a type and only the documented fields. " + \
		"Targets use temporary visual refs from your own current image, never world IDs. " + \
		"Inventory slot numbers refer only to your own inventory. Positive turn is left. " + \
		"move forward/right are metres relative to your gaze, total at most five. " + \
		"After personally reading a physical noticeboard, follow_route accepts a route ref from the printed floor plan in your personal_results. A labelled destination gives no information about occupants, stock or which evacuation order is current. " + \
		"move_to ONLY approaches a currently perceived target; it does not take, consume, open or interact. " + \
		"For food, across separate decisions: approach if needed, take the CURRENT nearby food ref, then consume its own inventory slot. After arrival choose the interaction instead of repeating move_to. " + \
		"send_message.contact uses contacts[].ref such as c0 or g0, never a display name. Open messages and read_screen to obtain your scoped message refs before read_message. " + \
		"use_device.app must be exactly one of " + JSON.stringify(DEVICE_APPS) + "; photos use gallery. " + \
		"request_ration has NO target: within 2 metres of the accessible supply terminal, call it directly to read its real rules/stock and attempt your ration; move closer only when needed. The read_terminal personal result is produced even if your quota is already issued or stock is empty. " + \
		"return_device is ONLY for a LOANED community device in your inventory, never your personal phone; it is not a terminal-reading action. " + \
		"speak needs text only and is heard by nearby eligible listeners; no visual target is required. " + \
		"Only last_result establishes an executed outcome; do not invent success. Available schemas (field:type, ? means optional): " + JSON.stringify(SCHEMAS)
