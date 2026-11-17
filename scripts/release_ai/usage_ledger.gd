extends RefCounted
## Process-wide account ledger. Game saves must never replace this object.
## Integer millionths of a rouble avoid cumulative float rounding errors.

const SCALE: int = 1000000
const Credentials = preload("res://scripts/release_storage/credential_store.gd")
const WebBridge = preload("res://scripts/release_storage/web_bridge.gd")
var limit_microrub: int = 1000 * SCALE
var max_parallel: int = 4
var _entries: Dictionary = {}
var _storage_path: String = ""
var _persist_error: String = ""
var _lease: Dictionary = {}
var _lease_path: String = ""
var _owner_instance: String = Crypto.new().generate_random_bytes(16).hex_encode()
var _totals_cache: Dictionary = {}

func configure(limit_rub: float = 1000.0, storage_path: String = "", parallel: int = 4) -> void:
	if is_finite(limit_rub) and limit_rub >= 0.0:
		limit_microrub = roundi(limit_rub * SCALE)
	max_parallel = clampi(parallel, 1, 20)
	if storage_path != _lease_path:release_storage_lease()
	_storage_path = storage_path
	if not _storage_path.is_empty():
		var writable: bool = _acquire_storage_lease()
		if not writable:_persist_error = "usage_ledger_in_use"
		if WebBridge.is_web():
			var stored := WebBridge.ledger_json()
			if not stored.is_empty() and not _merge_state(JSON.parse_string(stored),writable,false,writable):
				_persist_error="usage_ledger_corrupt";return
			if writable:_persist_error="";_persist()
			return
		var loaded: bool = false
		var existing: bool = false
		for candidate_path in [_storage_path,_storage_path + ".bak"]:
			if not FileAccess.file_exists(candidate_path):
				continue
			existing = true
			var file := FileAccess.open(candidate_path,FileAccess.READ)
			if file != null:
				var raw: Variant = JSON.parse_string(file.get_as_text())
				file.close()
				if _merge_state(raw,writable,false,writable):
					loaded = true
					break
		if existing and not loaded:
			_persist_error = "usage_ledger_corrupt"
		elif writable:
			_persist_error = ""
			_persist()
	else:_persist_error = ""

func reserve(request_id: String, estimate_rub: float, role: String = "action") -> Dictionary:
	if WebBridge.is_web() and not str(WebBridge.status().get("storage_error","")).is_empty():_persist_error="browser_ledger_write_failed"
	if not _storage_path.is_empty() and not _has_storage_lease():_persist_error = "usage_ledger_lease_lost" if not _lease.is_empty() else "usage_ledger_in_use"
	if not _persist_error.is_empty():
		return {"ok":false,"error":"ledger_persistence_failed"}
	if request_id.is_empty() or request_id.length() > 256 or _entries.has(request_id):
		return {"ok":false,"error":"duplicate_request"}
	if not is_finite(estimate_rub) or estimate_rub <= 0.0 or estimate_rub > 1000000.0:
		return {"ok":false,"error":"invalid_estimate"}
	var estimate: int = maxi(1, ceili(estimate_rub * SCALE))
	var totals := _totals()
	if int(totals.active) >= max_parallel:
		return {"ok":false,"error":"parallel_limit","retryable":true}
	if int(totals.committed) + estimate > limit_microrub:
		return {"ok":false,"error":"budget_exhausted","retryable":false}
	_entries[request_id] = {"id":request_id,"role":role,"estimate":estimate,"actual":0,"state":"reserved","metadata":{},"owner_pid":maxi(1,OS.get_process_id()),"owner_instance":_owner_instance}
	_totals_cache.clear()
	_persist()
	if not _persist_error.is_empty():
		_entries[request_id].state = "cancelled"
		_totals_cache.clear()
		return {"ok":false,"error":"ledger_persistence_failed"}
	return {"ok":true,"reserved_rub":float(estimate) / SCALE}

func settle(request_id: String, actual_rub: float = -1.0, metadata: Dictionary = {}) -> bool:
	if not _storage_path.is_empty() and not _has_storage_lease():
		_persist_error = "usage_ledger_lease_lost"
		return false
	if not _entries.has(request_id):
		return false
	var entry: Dictionary = _entries[request_id]
	if entry.state == "settled":
		return _persist_error.is_empty() # Duplicate callbacks never charge twice.
	if actual_rub < 0.0 or not is_finite(actual_rub):
		entry.state = "unknown"
	else:
		entry.state = "settled"
		entry.actual = maxi(0, ceili(actual_rub * SCALE))
	entry.metadata = _safe_metadata(metadata)
	_totals_cache.clear()
	_persist()
	return _persist_error.is_empty()

func abandon(request_id: String, uncertain: bool = true) -> bool:
	if not _storage_path.is_empty() and not _has_storage_lease():return false
	if not _entries.has(request_id):
		return false
	var entry: Dictionary = _entries[request_id]
	if entry.state != "reserved":
		return true
	entry.state = "unknown" if uncertain else "cancelled"
	_totals_cache.clear()
	_persist()
	return true

func status() -> Dictionary:
	if WebBridge.is_web() and not str(WebBridge.status().get("storage_error","")).is_empty():_persist_error="browser_ledger_write_failed"
	var sums := _totals()
	return {"limit_rub":float(limit_microrub) / SCALE,
		"spent_rub":float(sums.spent) / SCALE,"reserved_rub":float(sums.reserved) / SCALE,
		"unknown_rub":float(sums.unknown) / SCALE,
		"remaining_rub":float(maxi(0, limit_microrub - int(sums.committed))) / SCALE,
		"active_requests":sums.active,"request_count":_entries.size(),
		"over_budget":int(sums.committed) > limit_microrub,"storage_error":_persist_error}

func export_state() -> Dictionary:
	return {"version":1,"limit_microrub":limit_microrub,"entries":_entries.duplicate(true)}

func merge_state(raw: Variant) -> bool:
	return _merge_state(raw,true,true)

func _merge_state(raw: Variant, recover_abandoned: bool, write: bool, authoritative_file: bool = false) -> bool:
	# Monotonic merge, never assignment: loading an old save cannot replenish.
	if not raw is Dictionary or raw.get("version") != 1 or not raw.get("entries") is Dictionary:
		return false
	var staged: Dictionary = _entries.duplicate(true)
	if recover_abandoned:
		for entry in staged.values():
			if entry.state == "reserved" and str(entry.get("owner_instance","")) != _owner_instance:entry.state="unknown"
	for key in raw.entries:
		var candidate: Variant = raw.entries[key]
		if not _valid_entry(key, candidate):
			return false
		var incoming: Dictionary = candidate.duplicate(true)
		# A persisted in-flight request has an uncertain charge after restart.
		# Only an acquired account lease proves the previous writer exited.
		# A read-only second game must preserve the live writer's reservations.
		if recover_abandoned and incoming.state == "reserved" and str(incoming.get("owner_instance","")) != _owner_instance:
			incoming.state = "unknown"
		if not staged.has(key):
			staged[key] = incoming
		else:
			var current: Dictionary = staged[key]
			var current_cost: int = _committed(current)
			var incoming_cost: int = _committed(incoming)
			# A follower may have observed the former writer's reservation while
			# read-only. After acquiring the OS lease, the durable final receipt
			# legitimately settles that estimate, even when the actual fee is less.
			if authoritative_file and incoming.state == "settled" and current.state in ["reserved","unknown"]:
				staged[key] = incoming
			elif incoming_cost > current_cost:
				staged[key] = incoming
			elif incoming.state == "settled" and current.state != "settled" and incoming_cost == current_cost:
				staged[key] = incoming
	_entries = staged
	_totals_cache.clear()
	if write:_persist()
	return true

func _totals() -> Dictionary:
	if not _totals_cache.is_empty():return _totals_cache
	var sums := {"spent":0,"reserved":0,"unknown":0,"active":0,"committed":0}
	for entry in _entries.values():
		match entry.state:
			"settled": sums.spent += int(entry.actual)
			"reserved":
				sums.reserved += int(entry.estimate)
				sums.active += 1
			"unknown": sums.unknown += int(entry.estimate)
		sums.committed += _committed(entry)
	_totals_cache = sums
	return _totals_cache

static func _committed(entry: Dictionary) -> int:
	return int(entry.actual) if entry.state == "settled" else (0 if entry.state == "cancelled" else int(entry.estimate))

static func _safe_metadata(raw: Dictionary) -> Dictionary:
	var clean: Dictionary = {}
	for key in ["requested_model","returned_model","prompt_tokens","completion_tokens","total_tokens","role","error","currency","generation_ref","cost_source"]:
		var value: Variant = raw.get(key)
		if value is String:
			clean[key] = value.left(256)
		elif value is int or value is float:
			if is_finite(float(value)):
				clean[key] = value
	return clean

static func _valid_entry(key: Variant, raw: Variant) -> bool:
	if not key is String or key.is_empty() or key.length() > 256 or not raw is Dictionary:
		return false
	if raw.get("id") != key or not raw.get("role") is String or not raw.get("state") in ["reserved","unknown","settled","cancelled"]:
		return false
	for field in raw:
		if field not in ["id","role","estimate","actual","state","metadata","owner_pid","owner_instance"]:return false
	if raw.has("owner_pid"):
		var pid: Variant = raw.owner_pid
		if not (pid is int or pid is float) or not is_finite(float(pid)) or float(pid)<1.0 or float(pid)>2147483647.0 or float(pid)!=floorf(float(pid)):return false
	if raw.has("owner_instance") and (not raw.owner_instance is String or RegEx.create_from_string("^[0-9a-f]{32}$").search(raw.owner_instance)==null):return false
	for field in ["estimate","actual"]:
		var number: Variant = raw.get(field)
		if not (number is int or number is float) or not is_finite(float(number)) or float(number) < 0 or float(number) != floorf(float(number)) or float(number) > 1000000000000.0:
			return false
	return raw.get("metadata") is Dictionary

func _persist() -> void:
	if _storage_path.is_empty():
		return
	if not _has_storage_lease():
		_persist_error = "usage_ledger_in_use"
		return
	if WebBridge.is_web():
		_persist_error="" if WebBridge.persist_ledger(JSON.stringify(export_state()))>=0 else "browser_ledger_write_failed"
		return
	var temp_path: String = _storage_path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		_persist_error = "usage_ledger_write_failed"
		return
	file.store_string(JSON.stringify(export_state()))
	file.close()
	var destination: String = ProjectSettings.globalize_path(_storage_path)
	if FileAccess.file_exists(_storage_path):
		var backup: String = destination + ".bak"
		if FileAccess.file_exists(backup):
			DirAccess.remove_absolute(backup)
		if DirAccess.rename_absolute(destination, backup) != OK:
			_persist_error = "usage_ledger_backup_failed"
			return
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path), destination) != OK:
		_persist_error = "usage_ledger_replace_failed"
	else:
		_persist_error = ""

func _acquire_storage_lease() -> bool:
	if _has_storage_lease() and _lease_path == _storage_path:return true
	if not _lease.is_empty():release_storage_lease()
	if WebBridge.is_web():
		if not WebBridge.ready() or not WebBridge.has_lease():return false
		_lease={"web":true};_lease_path=_storage_path;return true
	if OS.get_name() != "Windows":return false
	var binary: String = Credentials.new().helper_path()
	if binary.is_empty():return false
	# No key or financial data enters argv: the digest names an OS mutex only.
	var identity: String = ProjectSettings.globalize_path(_storage_path).simplify_path().to_lower().sha256_text()
	var child: Dictionary = OS.execute_with_pipe(binary,PackedStringArray(["ledger-lease",identity,str(OS.get_process_id())]),true)
	if child.is_empty():return false
	var pipe: FileAccess = child.stdio
	var response: String = pipe.get_line()
	if response != "locked":
		pipe.close()
		if child.has("stderr"):child.stderr.close()
		return false
	_lease = child;_lease_path = _storage_path
	return true

func _has_storage_lease() -> bool:
	if WebBridge.is_web():return not _lease.is_empty() and WebBridge.has_lease()
	return not _lease.is_empty() and OS.is_process_running(int(_lease.get("pid",0)))

func release_storage_lease() -> void:
	if _lease.is_empty():return
	if WebBridge.is_web():_lease.clear();_lease_path="";return
	var pid: int = int(_lease.get("pid",0))
	var pipe: FileAccess = _lease.stdio
	if pipe.is_open():
		if pid>0 and OS.is_process_running(pid):pipe.store_line("release");pipe.flush()
		pipe.close()
	if _lease.has("stderr"):_lease.stderr.close()
	_lease.clear();_lease_path = ""
	# The helper releases its named mutex on stdin EOF, explicit release or
	# parent death. Wait briefly only when changing/closing an account lease.
	var deadline: int = Time.get_ticks_msec()+500
	while pid>0 and OS.is_process_running(pid) and Time.get_ticks_msec()<deadline:OS.delay_msec(2)

func _notification(what: int) -> void:
	# RefCounted has no callable self during PREDELETE. Closing its inherited
	# stdin inline releases the helper mutex even on ordinary reference cleanup.
	if what == NOTIFICATION_PREDELETE and not _lease.is_empty():
		if WebBridge.is_web():return
		_lease.stdio.close()
		if _lease.has("stderr"):_lease.stderr.close()
