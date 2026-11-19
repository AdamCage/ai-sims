extends RefCounted
## Append-only JSONL transitions + periodic checkpoints and atomic save slots.
## Image bytes and credentials never belong in this journal.

const SAVE_ROOT := "user://release_saves"
const SESSION_ROOT := "user://release_sessions"
const WebBridge = preload("res://scripts/release_storage/web_bridge.gd")
const ReplayArchive = preload("res://scripts/release_storage/replay_archive.gd")
var _archive = ReplayArchive.new()
var storage_error := ""
var save_root := SAVE_ROOT
var session_root := SESSION_ROOT
var session_path := ""
var sequence := 0
var _chronicle:Array = []
var _event_frames: Dictionary = {}
var checkpoints: Array = []
var _initial: Dictionary = {}
var _previous: Dictionary = {}
var _last_checkpoint_minute := 0.0
var _journal: FileAccess

func _init() -> void:
	# The portable slot already owns the durable journal. Temporary checkpoint
	# files should disappear when the page unloads.
	if WebBridge.is_web():session_root="/tmp/ai-sims-sessions"

func begin(state: Dictionary) -> void:
	if _journal != null:
		_journal.close()
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	session_path = session_root.path_join(stamp+"-"+Crypto.new().generate_random_bytes(4).hex_encode())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(session_path))
	sequence = 0
	_chronicle.clear()
	_event_frames.clear()
	_initial = state.duplicate(true)
	_index_events(0,state.get("events",[]))
	_archive.begin(state)
	_previous = state.duplicate(true)
	_previous.erase("events") # Indexed separately and excluded from world patches.
	checkpoints = []
	_last_checkpoint_minute = float(state.get("minute",0.0))
	_write_checkpoint(state)
	_journal = FileAccess.open(session_path.path_join("transitions.jsonl"),FileAccess.WRITE_READ)
	if _journal == null:storage_error = "session_journal_unavailable"
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
	_index_events(sequence,events)
	var record_data := {"sequence":sequence,"minute":state.get("minute",0),"patches":patches,"events":events}
	var line := JSON.stringify(record_data)
	_archive.append(line,record_data)
	if _journal != null:
		_journal.store_line(line)
		if _journal.get_error()!=OK:storage_error="session_journal_write_failed"
	# Update the private before-image with the same transition replay consumes.
	# This avoids cloning the entire map and up to 500 old events every 0.05 game minute.
	for patch in patches:
		if not _apply_patch(_previous,patch):
			_previous=state.duplicate(true);_previous.erase("events")
			break
	if float(state.get("minute",0)) - _last_checkpoint_minute >= 5.0:
		flush()
		_write_checkpoint(state)
		_last_checkpoint_minute = float(state.get("minute",0))

func flush() -> void:
	if _journal != null:
		_journal.flush()
	_write_manifest()

func _index_events(frame:int, events:Array) -> void:
	for event in events:
		if event is Dictionary:
			_chronicle.append({"frame":frame,"event":event.duplicate(true)})
			# A legacy slot can start with a tail of events at its final state.
			# Only the initial session event represents that actual base frame.
			var initial_event: bool = frame == 0 and event.get("type") == "session_started" and int(_initial.get("tick", -1)) == 0 and events.size() == 1
			if event.has("seq") and (frame > 0 or initial_event):
				_event_frames[int(event.seq)] = frame

func frame_for_event(event_sequence: int) -> int:
	return int(_event_frames.get(event_sequence, -1))

func event_frame_index() -> Dictionary:
	return _event_frames

func first_replay_event() -> int:
	if _event_frames.is_empty():
		return -1
	return int(_event_frames.keys().front())

func events_through(cursor:int) -> Array:
	return events_slice(0,event_count_through(cursor))

func event_count_through(cursor: int) -> int:
	var low := 0
	var high := _chronicle.size()
	while low < high:
		var middle := (low + high) >> 1
		if int(_chronicle[middle].frame) <= cursor:low=middle+1
		else:high=middle
	return low

func events_slice(first: int, end: int) -> Array:
	var result: Array = []
	for index in range(first,end):
		result.append(_chronicle[index].event.duplicate(true))
	return result

func _diff(old: Variant, next: Variant, path: Array, output: Array) -> void:
	if old == next:return
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
		storage_error="checkpoint_write_failed"
		return
	file.store_string(text)
	file.close()
	checkpoints.append({"sequence":sequence,"file":name,"sha256":text.sha256_text(),"offset":_journal.get_position() if sequence>0 and _journal!=null else 0})

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
	file.seek(int(selected.get("offset",0)))
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

static func _apply_patch(state: Dictionary, patch: Variant) -> bool:
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
	var current:Variant=data.get("world",{}).get("world") if data.get("world") is Dictionary else null
	if current is Dictionary and not session_path.is_empty():
		var extra_events:Array=[]
		for event in current.get("events",[]):
			if int(event.seq)>=int(_previous.get("event_cursor",0)):extra_events.append(event)
		record(current,extra_events)
		data=data.duplicate()
		data["replay"]=_archive.snapshot(sequence)
	flush()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_root))
	var path := save_root.path_join("slot_%d.json"%clampi(slot,1,3))
	var envelope := {"schema":2,"created_utc":Time.get_datetime_string_from_system(true),"session_path":session_path,"journal_sequence":sequence,"data":data}
	var body := JSON.stringify(envelope)
	var wrapper := JSON.stringify({"sha256":body.sha256_text(),"payload":body})
	if wrapper.length()>32*1024*1024:storage_error="save_slot_capacity";return ERR_OUT_OF_MEMORY
	if WebBridge.is_web():
		preload("res://scripts/release_ai/media_archive.gd").new().collect_browser_cache(path.get_file(),wrapper)
		if not WebBridge.persist_slot(path.get_file(),wrapper):
			storage_error="browser_save_write_failed";return ERR_CANT_CREATE
	else:
		var error := atomic_write(path,wrapper)
		if error!=OK:storage_error="save_write_failed";return error
	storage_error=""
	return OK

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
	if WebBridge.is_web() and not path.ends_with(".bak"):
		var stored := WebBridge.slot_json(path.get_file())
		if not stored.is_empty():return _read_envelope_text(stored)
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null:
		return {}
	return _read_envelope_text(file.get_as_text())

static func _walk_replay(archive:Dictionary, observer:Callable=Callable()) -> Dictionary:
	if archive.get("version")!=1 or not archive.get("chunks") is Array or archive.chunks.size()>2048 or not archive.get("media") is Array:return {}
	var initial:=ReplayArchive.unpack(archive.get("initial"))
	var state:Variant=_decode(initial.get_string_from_utf8())
	if not state is Dictionary or not state.get("events") is Array:return {}
	var count:=0
	var total:=initial.size()
	for part in archive.chunks:
		var bytes:=ReplayArchive.unpack(part)
		total+=bytes.size()
		if bytes.is_empty() or total>ReplayArchive.MAX_TOTAL_BYTES:return {}
		for line in bytes.get_string_from_utf8().split("\n",false):
			var entry:Variant=_decode(line)
			count+=1
			if not entry is Dictionary or int(entry.get("sequence",-1))!=count or not entry.get("patches") is Array or not entry.get("events") is Array:return {}
			for patch in entry.patches:
				if not _apply_patch(state,patch):return {}
			if not state.get("events") is Array:return {}
			state.events.append_array(entry.events)
			if state.events.size()>500:state.events=state.events.slice(-500)
			if observer.is_valid():observer.call(count,line,state,entry.events)
	return state if count==int(archive.get("sequence",-1)) else {}

static func _valid_replay(expected:Dictionary, replay:Variant) -> bool:
	if not replay is Dictionary:return false
	if replay.is_empty():return true # Earlier saves started a new timeline on load.
	var actual:=_walk_replay(replay)
	var normalized=preload("res://scripts/game/session_simulation.gd").new()
	if actual.is_empty() or not normalized.import_state(actual):return false
	normalized.state.run_id=expected.run_id
	return _decode(JSON.stringify(normalized.state))==_decode(JSON.stringify(expected))

func resume_from_slot(state:Dictionary, replay:Variant) -> bool:
	if not _valid_replay(state,replay):return false
	if replay.is_empty():
		begin(state)
		return _journal!=null
	var first:Dictionary=_decode(ReplayArchive.unpack(replay.initial).get_string_from_utf8())
	begin(first)
	if _journal==null:return false
	var last:=_walk_replay(replay,func(cursor:int,line:String,frame:Dictionary,events:Array):
		sequence=cursor
		_journal.store_line(line)
		_index_events(cursor,events)
		if float(frame.get("minute",0))-_last_checkpoint_minute>=5.0:
			_write_checkpoint(frame)
			_last_checkpoint_minute=float(frame.minute))
	if last.is_empty() or _journal.get_error()!=OK:return false
	_archive.initial=replay.initial
	_archive.chunks=replay.chunks.duplicate()
	for item in replay.get("media",[]):_archive.collect_images(item)
	_previous=last
	_previous.erase("events")
	record(state) # The restored run has a new generation.
	flush()
	return true

func import_browser_slots() -> bool:
	if not WebBridge.is_web() or not WebBridge.has_lease():return false
	var incoming := WebBridge.imported_save()
	if incoming.is_empty():return false
	# Validate every slot before replacing anything. Financial state is never imported.
	for name in incoming:
		if name not in ["slot_1.json","slot_2.json","slot_3.json"] or not incoming[name] is String:return false
		var envelope := _read_envelope_text(incoming[name])
		if not _valid_import_data(envelope.get("data",{})):return false
	return WebBridge.commit_import(incoming)

static func _valid_import_data(data:Dictionary) -> bool:
	if not data.get("world") is Dictionary or not data.get("runtimes") is Dictionary or not data.get("next_decision",{}) is Dictionary:return false
	var staged = preload("res://scripts/game/session_simulation.gd").new()
	if not staged.import_state(data.world):return false
	if not _valid_replay(staged.state,data.get("replay",{})):return false
	for actor in staged.state.agents:
		if not data.runtimes.get(actor) is Dictionary:return false
		var candidate = preload("res://scripts/release_ai/agent_runtime.gd").new()
		candidate.configure(actor,staged.state.agents[actor].profile)
		var valid:bool = candidate.import_state(data.runtimes[actor],int(staged.state.run_id))
		candidate.free()
		if not valid:return false
	for actor in data.get("next_decision",{}):
		var due:Variant=data.next_decision[actor]
		if not staged.state.agents.has(actor) or not (due is int or due is float) or not is_finite(float(due)) or float(due)<0.0:return false
	return true


func browser_storage_error() -> String:
	return str(WebBridge.status().get("storage_error",storage_error)) if WebBridge.is_web() else storage_error

static func _read_envelope_text(text: String) -> Dictionary:
	if text.length()>32*1024*1024:return {}
	var wrapper = _decode(text)
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
	if WebBridge.is_web() and not WebBridge.has_lease():return ERR_BUSY
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
