extends RefCounted
## Append-only JSONL transitions + periodic checkpoints and atomic save slots.
## Image bytes and credentials never belong in this journal.

const SAVE_ROOT := "user://release_saves"
const SESSION_ROOT := "user://release_sessions"
var save_root := SAVE_ROOT
var session_root := SESSION_ROOT
var session_path := ""
var sequence := 0
var checkpoints: Array = []
var _initial: Dictionary = {}
var _previous: Dictionary = {}
var _last_checkpoint_minute := 0.0
var _journal: FileAccess

func begin(state: Dictionary) -> void:
	if _journal != null:
		_journal.close()
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	session_path = session_root.path_join(stamp+"-"+Crypto.new().generate_random_bytes(4).hex_encode())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(session_path))
	sequence = 0
	_initial = state.duplicate(true)
	_previous = state.duplicate(true)
	checkpoints = []
	_last_checkpoint_minute = float(state.get("minute",0.0))
	_write_checkpoint(state)
	_journal = FileAccess.open(session_path.path_join("transitions.jsonl"),FileAccess.WRITE_READ)
	_write_manifest()

func record(state: Dictionary, events: Array = []) -> void:
	if session_path.is_empty():
		begin(state)
		return
	var patches: Array = []
	_diff(_previous,state,[],patches)
	if patches.is_empty() and events.is_empty():
		return
	sequence += 1
	var record_data := {"sequence":sequence,"minute":state.get("minute",0),"patches":patches,"events":events}
	if _journal != null:
		_journal.store_line(JSON.stringify(record_data))
	_previous = state.duplicate(true)
	if float(state.get("minute",0)) - _last_checkpoint_minute >= 5.0:
		flush()
		_write_checkpoint(state)
		_last_checkpoint_minute = float(state.get("minute",0))

func flush() -> void:
	if _journal != null:
		_journal.flush()
	_write_manifest()

func _diff(old: Variant, next: Variant, path: Array, output: Array) -> void:
	if old is Dictionary and next is Dictionary:
		for key in old:
			if path.is_empty() and key == "events":
				continue
			if not next.has(key):
				output.append({"op":"remove","path":path+[str(key)]})
		for key in next:
			if path.is_empty() and key == "events":
				continue
			if not old.has(key):
				output.append({"op":"set","path":path+[str(key)],"value":next[key]})
			else:
				_diff(old[key],next[key],path+[str(key)],output)
	elif old != next:
		output.append({"op":"set","path":path,"value":next})

func _write_checkpoint(state: Dictionary) -> void:
	var name := "checkpoint_%08d.json" % sequence
	var text := JSON.stringify({"version":2,"sequence":sequence,"state":state})
	var file := FileAccess.open(session_path.path_join(name),FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()
	checkpoints.append({"sequence":sequence,"file":name,"sha256":text.sha256_text()})

func _write_manifest() -> void:
	if session_path.is_empty():
		return
	var file := FileAccess.open(session_path.path_join("manifest.json"),FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"version":2,"sequence":sequence,"checkpoints":checkpoints,"map_id":_initial.get("map_id",""),"agent_count":_initial.get("agents",{}).size()}))

func reconstruct(at_sequence: int) -> Dictionary:
	flush()
	var target := clampi(at_sequence,0,sequence)
	var selected: Dictionary = {}
	for checkpoint in checkpoints:
		if int(checkpoint.sequence) <= target:
			selected = checkpoint
	if selected.is_empty():
		return {}
	var file := FileAccess.open(session_path.path_join(str(selected.file)),FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	if text.sha256_text() != selected.sha256:
		return {}
	var checkpoint_data = _decode(text)
	if not checkpoint_data is Dictionary or not checkpoint_data.get("state") is Dictionary:
		return {}
	var restored: Dictionary = checkpoint_data.state
	if int(selected.sequence) == target:
		return restored
	file = FileAccess.open(session_path.path_join("transitions.jsonl"),FileAccess.READ)
	if file == null:
		return {}
	var applied:=int(selected.sequence)
	while not file.eof_reached():
		var line := file.get_line()
		if line.is_empty():
			continue
		var entry = _decode(line)
		if not entry is Dictionary:
			return {} # A truncated tail is never applied as a partial transition.
		var cursor := int(entry.get("sequence",-1))
		if cursor <= int(selected.sequence):
			continue
		if cursor > target:
			break
		if cursor!=applied+1 or not entry.get("patches") is Array or not entry.get("events") is Array:
			return {} # Missing/reordered transitions cannot masquerade as target.
		for patch in entry.get("patches",[]):
			if not _apply_patch(restored,patch):
				return {}
		var recent: Array = restored.get("events",[])
		recent.append_array(entry.get("events",[]))
		if recent.size()>500:
			recent = recent.slice(recent.size()-500)
		restored["events"] = recent
		applied=cursor
	return restored if applied==target else {}

func _apply_patch(state: Dictionary, patch: Variant) -> bool:
	if not patch is Dictionary or not patch.get("path") is Array or patch.path.is_empty():
		return false
	var node: Dictionary = state
	for key in patch.path.slice(0,patch.path.size()-1):
		if not node.get(key) is Dictionary:
			return false
		node = node[key]
	var key: String = str(patch.path[-1])
	if patch.get("op") == "remove":
		node.erase(key)
	elif patch.get("op") == "set":
		var value = patch.get("value")
		node[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	else:
		return false
	return true

func save_slot(slot: int, data: Dictionary) -> Error:
	flush()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_root))
	var path := save_root.path_join("slot_%d.json"%clampi(slot,1,3))
	var envelope := {"schema":2,"created_utc":Time.get_datetime_string_from_system(true),"session_path":session_path,"journal_sequence":sequence,"data":data}
	var body := JSON.stringify(envelope)
	var wrapper := JSON.stringify({"sha256":body.sha256_text(),"payload":body})
	return atomic_write(path,wrapper)

func load_slot(slot: int) -> Dictionary:
	var path := save_root.path_join("slot_%d.json"%clampi(slot,1,3))
	for candidate in [path,path+".bak"]:
		var loaded := _read_envelope(candidate)
		if not loaded.is_empty():
			loaded["recovered_backup"] = candidate.ends_with(".bak")
			return loaded
	return {}

func slot_summaries() -> Array:
	var result: Array = []
	for slot in range(1,4):
		var entry := load_slot(slot)
		var world: Dictionary = entry.get("data",{}).get("world",{})
		var state: Dictionary = world.get("world",world.get("state",world))
		result.append({"slot":slot,"exists":not entry.is_empty(),"created":entry.get("created_utc",""),"map_id":state.get("map_id",""),"minute":state.get("minute",0)})
	return result

func _read_envelope(path: String) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null:
		return {}
	var wrapper = _decode(file.get_as_text())
	if not wrapper is Dictionary or not wrapper.get("payload") is String or not wrapper.get("sha256") is String:
		return {}
	if wrapper.payload.sha256_text() != wrapper.sha256:
		return {}
	var envelope = _decode(wrapper.payload)
	if not envelope is Dictionary or envelope.get("schema") != 2 or not envelope.get("data") is Dictionary:
		return {}
	return envelope

static func _decode(text: String) -> Variant:
	var parser:=JSON.new()
	return parser.data if parser.parse(text)==OK else null

static func atomic_write(path: String, text: String) -> Error:
	var temporary := path+".tmp"
	var file := FileAccess.open(temporary,FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(text)
	file.flush()
	file.close()
	var absolute := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		if FileAccess.file_exists(path+".bak"):
			DirAccess.remove_absolute(absolute+".bak")
		var moved := DirAccess.rename_absolute(absolute,absolute+".bak")
		if moved != OK:
			return moved
	var error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary),absolute)
	if error != OK and FileAccess.file_exists(path+".bak"):
		DirAccess.rename_absolute(absolute+".bak",absolute)
	return error
