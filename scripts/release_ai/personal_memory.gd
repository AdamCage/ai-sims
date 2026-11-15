extends RefCounted
## One owner's immutable recent experience and versioned subjective layers.
## It has no world/simulation reference. Media archive retention is not access.

const Archive = preload("res://scripts/release_ai/media_archive.gd")
const RECENT_MINUTES: float = 60.0
const EPISODIC_MINUTES: float = 10080.0
var owner: String = ""
var run_id: int = -1
var version: int = 0
var _sequence: int = 0
var _last_capture_key: String = ""
var _recent: Array = []
var _older: Array = []
var _episodes: Array = []
var _semantic: String = ""
var _versions: Array = []
var archive = Archive.new()
var last_error: String = ""

func configure(id: String) -> void:
	owner = id

func reset(new_run: int) -> void:
	run_id = new_run
	version = 0
	_sequence = 0
	_last_capture_key = ""
	_recent.clear()
	_older.clear()
	_episodes.clear()
	_versions.clear()
	_semantic = ""
	last_error = ""

func append(raw: Dictionary, png: PackedByteArray = PackedByteArray()) -> bool:
	var context: Dictionary = personal_context(raw)
	var minute: float = float(context.minute)
	if int(context.tick) < 0 or not is_finite(minute) or minute < 0.0:
		last_error = "invalid_observation_time"
		return false
	if not _recent.is_empty() and minute < float(_recent[-1].minute):
		last_error = "observation_time_went_backwards"
		return false
	var image_ref: Dictionary = {}
	if not context.self_state.body.blind:
		image_ref = archive.store_png(png)
	var screen_ref: Dictionary = {}
	if may_read_screen(context) and raw.get("screen_png") is PackedByteArray:
		screen_ref = archive.store_png(raw.screen_png)
	var viewed_ref: Dictionary = {}
	if not context.self_state.body.blind and has_image_grant(context,str(raw.get("viewed_image_ref",""))):
		if raw.get("viewed_image_png") is PackedByteArray and Archive.digest_bytes(raw.viewed_image_png) == str(raw.viewed_image_ref):
			viewed_ref = archive.store_png(raw.viewed_image_png)
		elif Archive.valid_hash(raw.get("viewed_image_ref")):
			var granted_bytes: PackedByteArray = archive.retrieve(raw.viewed_image_ref)
			if not granted_bytes.is_empty():
				viewed_ref = archive.store_png(granted_bytes)
	var capture_key: String = (JSON.stringify(context) + str(image_ref.get("hash", "")) + str(screen_ref.get("hash","")) + str(viewed_ref.get("hash",""))).sha256_text()
	if capture_key == _last_capture_key:
		return false
	# Age records before applying the recent-count bound. Otherwise a full
	# protected hour could never accept a later observation or consolidate.
	while not _recent.is_empty() and float(_recent[0].minute) < minute - RECENT_MINUTES:
		if _older.size() >= 8192:
			last_error = "memory_capacity_requires_consolidation"
			return false
		_older.append(_recent.pop_front())
	if _recent.size() >= 4096 or _older.size() >= 8192:
		last_error = "memory_capacity_requires_consolidation"
		return false # Never silently rewrite/drop an immutable recent record.
	_sequence += 1
	context["id"] = _sequence
	context["image"] = image_ref
	context["screen_image"] = screen_ref
	context["viewed_image"] = viewed_ref
	context["source"] = "personal_observation"
	_recent.append(context.duplicate(true))
	_last_capture_key = capture_key
	last_error = ""
	return true

func build_job(profile: Dictionary, now: float, allow_trait_review: bool = false) -> Dictionary:
	if _older.is_empty():
		return {}
	var entries: Array = _older.slice(0, mini(128 if _older.size()>48 else 24, _older.size())).duplicate(true)
	var ids: Array = []
	var images: Array = []
	for entry in entries:
		ids.append(int(entry.id))
		if float(entry.minute) >= now - EPISODIC_MINUTES:
			for field in ["image","screen_image","viewed_image"]:
				if not entry.get(field,{}).is_empty() and not images.has(str(entry[field].hash)):
					images.append(str(entry[field].hash))
	# Images remain private refs. Memory role gets only selected owner pixels.
	return {"role":"memory","owner":owner,"base_version":version,"now":now,
		"profile":clean_profile(profile),"allow_trait_review":allow_trait_review,
		"entries":entries,"consume_ids":ids,"allowed_images":images,
		"previous_semantic":_semantic,"previous_episodes":_episodes.slice(maxi(0, _episodes.size() - 8)).duplicate(true)}

func pending_old_count() -> int:
	return _older.size()

func append_experience(raw: Dictionary) -> bool:
	# These are actual, owner-scoped acquisitions emitted by the rules at the
	# moment they occur. They are events, not invented body/inventory snapshots.
	if not _integer(raw.get("tick"),0,1000000000) or not _number(raw.get("minute"),0,1000000000):return false
	if not raw.get("heard",[]) is Array or not raw.get("personal_results",[]) is Array:return false
	if raw.get("heard",[]).size()>64 or raw.get("personal_results",[]).size()>32:return false
	var context: Dictionary = personal_context({"heard":raw.get("heard",[])})
	var results: Array = []
	for result in raw.get("personal_results",[]):
		if not result is Dictionary:return false
		results.append(_clean_result(result))
	if context.heard.is_empty() and results.is_empty():return false
	var minute: float = float(raw.minute)
	if not _recent.is_empty() and minute<float(_recent[-1].minute):return false
	while not _recent.is_empty() and float(_recent[0].minute)<minute-RECENT_MINUTES:
		if _older.size()>=8192:return false
		_older.append(_recent.pop_front())
	if _recent.size()>=4096 or _older.size()>=8192:
		last_error="memory_capacity_requires_consolidation";return false
	var viewed: Dictionary = {}
	for digest in _experienced_images(results):
		var bytes: PackedByteArray = archive.retrieve(digest)
		if not bytes.is_empty():viewed={"hash":digest,"mime":"image/png","bytes":bytes.size()};break
	_sequence+=1
	_recent.append({"id":_sequence,"tick":int(raw.tick),"minute":minute,"source":"personal_experience",
		"heard":context.heard,"personal_results":results,"image":{},"screen_image":{},"viewed_image":viewed})
	last_error=""
	return true

static func _experienced_images(results: Array) -> Array:
	var hashes: Array = []
	for entry in results:
		if not Archive.valid_hash(entry.get("image_ref")):continue
		var channel: String = str(entry.get("channel",""))
		var source: String = str(entry.get("source",""))
		if (channel=="message" and source=="received_message") or (channel in ["shown_photo","viewed_photo","photo","artifact"] and source in ["viewed_own_artifact","shown_artifact","explicit_photo_view"]):
			if not hashes.has(entry.image_ref):hashes.append(entry.image_ref)
	return hashes

func apply_job(job: Dictionary, proposal: Dictionary, mode: String) -> bool:
	if job.get("owner") != owner or int(job.get("base_version", -1)) != version:
		last_error = "stale_memory_version"
		return false
	var consume: Variant = job.get("consume_ids")
	if not consume is Array or consume.is_empty() or consume.size() > _older.size():
		return false
	for index in consume.size():
		if int(_older[index].id) != int(consume[index]):
			return false
	var incoming: Variant = proposal.get("episodes")
	if not incoming is Array or incoming.size() > 8 or not proposal.get("semantic_summary", "") is String:
		return false
	var episodes: Array = []
	for entry in incoming:
		if not entry is Dictionary or not _text(entry.get("text"), 1600) or not entry.get("images", []) is Array:
			return false
		var refs: Array = []
		for digest in entry.get("images", []):
			if not Archive.valid_hash(digest) or not job.allowed_images.has(digest):
				return false
			refs.append(digest)
		if refs.size() > 2:
			return false
		episodes.append({"text":entry.text,"images":refs,"from_minute":float(job.entries[0].minute),
			"to_minute":float(job.entries[-1].minute),"source":"subjective_memory","version":version + 1})
	var semantic: String = str(proposal.get("semantic_summary", "")).left(6000)
	if semantic.is_empty() and episodes.is_empty():
		return false
	var updated: Array = _episodes.duplicate(true)
	updated.append_array(episodes)
	var expired: Array = []
	while not updated.is_empty() and (updated.size() > 128 or float(updated[0].to_minute) < float(job.now) - EPISODIC_MINUTES):
		expired.append(updated.pop_front())
	# The role's own summary is authoritative as subjective memory. Expired
	# episodes are not silently restored from the immutable observer archive.
	if not expired.is_empty() and semantic.is_empty():
		var parts: Array[String] = [_semantic]
		for old in expired:
			parts.append(str(old.text))
		semantic = "\n".join(parts).right(6000)
	for index in consume.size():
		_older.pop_front()
	_episodes = updated
	if not semantic.is_empty():
		_semantic = semantic
	version += 1
	_versions.append({"version":version,"minute":job.now,"mode":mode,"consumed":consume.duplicate(),"episodes":episodes.duplicate(true),"semantic":_semantic})
	if _versions.size() > 32:
		_versions.pop_front()
	last_error = ""
	return true

func context() -> Dictionary:
	var recent: Array = []
	for record in _recent:
		var copy: Dictionary = record.duplicate(true)
		copy.erase("image")
		copy.erase("screen_image")
		copy.erase("viewed_image")
		copy.erase("profile")
		recent.append(copy)
	var active: Array = _active_episodes()
	return {"version":version,"recent":recent,"episodes":active.slice(maxi(0, active.size() - 12)).duplicate(true),
		"semantic":_semantic,"pending_old_count":_older.size()}

func payload_context() -> Dictionary:
	var result: Dictionary = context()
	if result.recent.size()<2 or JSON.stringify(result.recent).length()<16000:return result
	# This is a reversible wire representation, never subjective compression.
	# The first full record and ordered RFC7396 patches retain every value in
	# the protected hour while avoiding repeated bodies/inventories/reports.
	var encoded: Array = [result.recent[0].duplicate(true)]
	for index in range(1,result.recent.size()):encoded.append(_merge_patch(result.recent[index-1],result.recent[index]))
	result.recent = encoded
	result["recent_encoding"] = "ordered_rfc7396_merge_patches_first_record_full"
	return result

static func _merge_patch(before: Dictionary, after: Dictionary) -> Dictionary:
	var patch: Dictionary = {}
	for key in before:
		if not after.has(key):patch[key]=null
	for key in after:
		if not before.has(key):patch[key]=after[key]
		elif before[key] is Dictionary and after[key] is Dictionary:
			var nested: Dictionary = _merge_patch(before[key],after[key])
			if not nested.is_empty():patch[key]=nested
		elif before[key]!=after[key]:patch[key]=after[key]
	return patch

func accessible_images(limit: int = 2) -> Array:
	var result: Array = []
	for entry in _recent:
		for field in ["image","screen_image","viewed_image"]:
			if not entry.get(field,{}).is_empty():
				result.append({"hash":entry[field].hash,"minute":entry.minute,"source":"personal_visual_memory"})
	for episode in _active_episodes():
		for digest in episode.images:
			result.append({"hash":digest,"minute":episode.to_minute,"source":"retained_subjective_episode_image"})
	result.sort_custom(func(left: Dictionary,right: Dictionary) -> bool:return float(left.minute)<float(right.minute))
	return result.slice(maxi(0, result.size() - clampi(limit, 0, 4)))

func retrieve_image(digest: String) -> PackedByteArray:
	for entry in _recent:
		for field in ["image","screen_image","viewed_image"]:
			if entry.get(field,{}).get("hash","") == digest:
				return archive.retrieve(digest)
	for episode in _active_episodes():
		if episode.images.has(digest):
			return archive.retrieve(digest)
	return PackedByteArray()

func _active_episodes() -> Array:
	# Provider failure must not extend photographic recall past seven days.
	# Keep the observer's versioned source intact until the separate memory
	# role folds it into semantics; only current private access expires here.
	var now: float = 0.0
	if not _recent.is_empty():now = float(_recent[-1].minute)
	elif not _older.is_empty():now = float(_older[-1].minute)
	var active: Array = []
	for episode in _episodes:
		if float(episode.to_minute) >= now - EPISODIC_MINUTES:active.append(episode)
	return active

func view(recent_limit: int = -1) -> Dictionary:
	var recent: Array = _recent if recent_limit<0 else _recent.slice(maxi(0,_recent.size()-recent_limit))
	var episodes: Array = _episodes if recent_limit<0 else _episodes.slice(maxi(0,_episodes.size()-recent_limit))
	var versions: Array = _versions if recent_limit<0 else _versions.slice(maxi(0,_versions.size()-recent_limit))
	return {"version":version,"recent":recent.duplicate(true),"episodes":episodes.duplicate(true),
		"semantic":_semantic,"pending_old_count":_older.size(),"versions":versions.duplicate(true),"last_error":last_error,
		"recent_count":_recent.size(),"episode_count":_episodes.size(),"version_count":_versions.size()}

func export_state() -> Dictionary:
	return {"version":1,"owner":owner,"run_id":run_id,"revision":version,"sequence":_sequence,
		"recent":_recent.duplicate(true),"older":_older.duplicate(true),"episodes":_episodes.duplicate(true),
		"semantic":_semantic,"versions":_versions.duplicate(true),"last_capture_key":_last_capture_key}

func import_state(raw: Variant, new_run: int) -> bool:
	if not raw is Dictionary or raw.get("version") != 1 or raw.get("owner") != owner or new_run < 0:
		return false
	if not _integer(raw.get("revision"), 0, 10000000) or not _integer(raw.get("sequence"), 0, 1000000000):
		return false
	if not raw.get("recent") is Array or not raw.get("older") is Array or not raw.get("episodes") is Array or not raw.get("versions") is Array:
		return false
	if raw.recent.size() > 4096 or raw.older.size() > 8192 or raw.episodes.size() > 128 or raw.versions.size() > 32 or not _text(raw.get("semantic"), 6000):
		return false
	var previous: int = 0
	var minute: float = -1.0
	for records in [raw.older, raw.recent]:
		for entry in records:
			if not _valid_record(entry) or int(entry.id) <= previous or int(entry.id) > int(raw.sequence) or float(entry.minute) < minute:
				return false
			previous = int(entry.id)
			minute = float(entry.minute)
	for episode in raw.episodes:
		if not _valid_episode(episode):
			return false
	for revision in raw.versions:
		if not revision is Dictionary or not _integer(revision.get("version"), 1, int(raw.revision)) or not _number(revision.get("minute"), 0, 1000000000) or not _text(revision.get("mode"), 32) or not revision.get("consumed") is Array or not revision.get("episodes") is Array or not _text(revision.get("semantic"), 6000):
			return false
		for episode in revision.episodes:
			if not _valid_episode(episode):
				return false
	var capture: Variant = raw.get("last_capture_key", "")
	if not capture is String or (not capture.is_empty() and not Archive.valid_hash(capture)):
		return false
	# Commit only after every nested record has passed validation.
	run_id = new_run
	version = int(raw.revision)
	_sequence = int(raw.sequence)
	_recent = raw.recent.duplicate(true)
	_older = raw.older.duplicate(true)
	_episodes = raw.episodes.duplicate(true)
	_semantic = raw.semantic
	_versions = raw.versions.duplicate(true)
	_last_capture_key = capture
	last_error = ""
	return true

func intervene(args: Dictionary) -> bool:
	if not args.get("text", "") is String:
		return false
	if bool(args.get("clear", false)):
		_recent.clear()
		_older.clear()
		_episodes.clear()
		_last_capture_key = ""
	_semantic = str(args.get("text", "")).left(6000)
	version += 1
	_versions.append({"version":version,"minute":float(args.get("minute", 0.0)),"mode":"explicit_player_intervention","consumed":[],"episodes":[],"semantic":_semantic})
	if _versions.size() > 32:
		_versions.pop_front()
	return true

static func clean_profile(raw: Variant) -> Dictionary:
	var profile: Dictionary = raw if raw is Dictionary else {}
	var traits: Array = []
	var values: Variant = profile.get("traits", [])
	if values is Array:
		for personality_trait in values.slice(0, 32):
			if personality_trait is String and personality_trait.length() <= 120:
				traits.append(personality_trait)
	return {"foundation":_string(profile.get("foundation", ""), 8192),"traits":traits,"goal":_string(profile.get("goal", ""), 2000)}

static func personal_context(raw: Dictionary) -> Dictionary:
	var own: Dictionary = _dictionary(raw.get("self_state"))
	var needs: Dictionary = _dictionary(own.get("needs"))
	var body: Dictionary = _dictionary(own.get("body"))
	var clean_body := {"blind":bool(body.get("blind", false))}
	for limb in ["left_arm","right_arm","left_leg","right_leg"]:
		clean_body[limb] = str(body.get(limb, "healthy")) if body.get(limb, "healthy") in ["healthy","injured","broken"] else "healthy"
	var inventory: Array = []
	var raw_items: Variant = raw.get("inventory", [])
	if raw_items is Array:
		for item in raw_items.slice(0, 64):
			if item is Dictionary:
				inventory.append({"slot":maxi(0, int(_finite(item.get("slot"), 0.0))),"label":_string(item.get("label"), 256),
					"kind":_string(item.get("kind"), 64),"quantity":maxi(0, int(_finite(item.get("quantity"), 1.0)))})
	var heard: Array = []
	var raw_heard: Variant = raw.get("heard", [])
	if raw_heard is Array:
		for speech in raw_heard.slice(0, 64):
			if speech is Dictionary:
				var event: Dictionary = {"speaker":_string(speech.get("speaker", "Someone"), 128),"text":_string(speech.get("text"), 2000),
					"bearing":clampf(_finite(speech.get("bearing"), 0.0), -180.0, 180.0),
					"distance":clampf(_finite(speech.get("distance"), 0.0), 0.0, 1000.0),"source":"heard_speech"}
				if _number(speech.get("minute"),0,1000000000):event["minute"]=speech.minute
				heard.append(event)
	var contacts: Array = []
	var raw_contacts: Variant = raw.get("contacts", [])
	if raw_contacts is Array:
		for contact in raw_contacts.slice(0, 64):
			if contact is Dictionary:
				contacts.append({"ref":_string(contact.get("ref"), 120),"name":_string(contact.get("name"), 128)})
	var personal_results: Array = []
	var results: Variant = raw.get("personal_results", [])
	if results is Array:
		for result in results.slice(0, 32):
			if result is Dictionary:
				var channel: String = _string(result.get("channel", "own_action"), 64)
				if clean_body.blind and channel not in ["heard_speech","own_action","body","proprioception"]:
					continue
				personal_results.append(_clean_result(result))
	var busy: Dictionary = _dictionary(own.get("busy"))
	if own.get("busy") is String and not str(own.busy).is_empty():
		busy = {"type":str(own.busy)}
	var safe_busy: Dictionary = {}
	for field in ["type","state"]:
		if busy.get(field) is String:
			safe_busy[field] = str(busy[field]).left(64)
	for field in ["progress","remaining"]:
		if busy.get(field) is int or busy.get(field) is float:
			safe_busy[field] = _finite(busy[field], 0.0)
	var relations: Array = []
	if own.get("relations") is Array:
		for relation in own.relations.slice(0,64):
			if not relation is Dictionary:
				continue
			var experience: Array = []
			if relation.get("experience") is Array:
				for event in relation.experience.slice(maxi(0,relation.experience.size()-8)):
					if event is String:
						experience.append(event.left(512))
			relations.append({"name":_string(relation.get("name"),128),"trust":clampf(_finite(relation.get("trust"),0),-100,100),"experience":experience})
	return {"tick":int(_finite(raw.get("tick"), -1)),"minute":_finite(raw.get("minute"), 0.0),
		"self_state":{"name":_string(own.get("name"),128),"health":clampf(_finite(own.get("health"),100),0,100),
			"pain":clampf(_finite(own.get("pain"),0),0,100),"needs":{"hunger":clampf(_finite(needs.get("hunger"),0),0,100),"fatigue":clampf(_finite(needs.get("fatigue"),0),0,100)},
			"body":clean_body,"alive":bool(own.get("alive",true)),"sleeping":bool(own.get("sleeping",false)),"unconscious":bool(own.get("unconscious",false)),
			"tokens":maxi(0,int(_finite(own.get("tokens"),0))),"busy":safe_busy,"relations":relations},
		"profile":clean_profile(raw.get("profile",{})),"inventory":inventory,"heard":heard,
		"contacts":contacts,"personal_results":personal_results,"last_result":_clean_last(_dictionary(raw.get("last_result")))}

static func _clean_result(raw: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for field in ["channel","ref","sender","author","name","text","title","app","status","source","attachment","image_ref"]:
		if raw.get(field) is String:
			result[field] = str(raw[field]).left(2000 if field == "text" else 256)
	# Keep acquisition and original-artifact time distinct. Reopening an old
	# photo is new experience, but does not change when the photo was taken.
	for field in ["minute","original_minute","revision"]:
		if _number(raw.get(field),0.0,1000000000.0):
			result[field] = raw[field]
	if raw.get("options") is Array:
		var options: Array = []
		for option in raw.options.slice(0,8):
			if option is String:
				options.append(option.left(120))
		result["options"] = options
	if raw.get("entries") is Array:
		var entries: Array = []
		for entry in raw.entries.slice(0,32):
			if entry is Dictionary:
				var shallow: Dictionary = entry.duplicate()
				shallow.erase("entries")
				entries.append(_clean_result(shallow))
		result["entries"] = entries
	return result

static func _clean_last(raw: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in ["ok","type","message","reason"]:
		if raw.get(key) is String:
			result[key] = str(raw[key]).left(2000)
		elif key == "ok" and raw.get(key) is bool:
			result[key] = raw[key]
	return result

static func _valid_record(raw: Variant) -> bool:
	if not raw is Dictionary or not _integer(raw.get("id"),1,1000000000) or not _integer(raw.get("tick"),0,1000000000) or not _number(raw.get("minute"),0,1000000000):
		return false
	if raw.get("source") == "personal_experience":return _valid_experience(raw)
	if raw.get("source") != "personal_observation":return false
	for key in raw:
		if not key in ["id","tick","minute","self_state","profile","inventory","heard","contacts","personal_results","last_result","image","screen_image","viewed_image","source"]:
			return false
	for field in ["self_state","profile","last_result","image"]:
		if not raw.get(field) is Dictionary:
			return false
	for field in ["inventory","heard","contacts","personal_results"]:
		if not raw.get(field) is Array:
			return false
	var own: Dictionary = raw.self_state
	if not _text(own.get("name"),128) or not own.get("needs") is Dictionary or not own.get("body") is Dictionary:
		return false
	for key in ["alive","sleeping","unconscious"]:
		if not own.get(key) is bool:
			return false
	for key in ["health","pain"]:
		if not _number(own.get(key),0,100):
			return false
	for key in ["hunger","fatigue"]:
		if not _number(own.needs.get(key),0,100):
			return false
	if not own.body.get("blind") is bool:
		return false
	for limb in ["left_arm","right_arm","left_leg","right_leg"]:
		if not own.body.get(limb) in ["healthy","injured","broken"]:
			return false
	if not _text(raw.profile.get("foundation"),8192) or not _text(raw.profile.get("goal"),2000) or not raw.profile.get("traits") is Array:
		return false
	for personality_trait in raw.profile.traits:
		if not _text(personality_trait,120):
			return false
	for field in ["image","screen_image","viewed_image"]:
		var image: Variant = raw.get(field,{})
		if not image is Dictionary:
			return false
		if not image.is_empty() and (not Archive.valid_hash(image.get("hash")) or image.get("mime") != "image/png" or not _integer(image.get("bytes"),1,8*1024*1024)):
			return false
		for key in image:
			if key not in ["hash","mime","bytes"]:return false
		if own.body.blind and not image.is_empty():
			return false
	# Canonical reconstruction rejects unexpected nested secrets/types too.
	var canonical: Dictionary = personal_context(raw)
	for field in ["self_state","profile","last_result","inventory","heard","contacts","personal_results"]:
		if not equivalent(canonical[field],raw[field]):
			return false
	return true

static func _valid_experience(raw: Dictionary) -> bool:
	for key in raw:
		if key not in ["id","tick","minute","source","heard","personal_results","image","screen_image","viewed_image"]:return false
	if not raw.get("heard") is Array or not raw.get("personal_results") is Array or raw.heard.size()>64 or raw.personal_results.size()>32:return false
	var context: Dictionary = personal_context({"heard":raw.heard})
	if not equivalent(context.heard,raw.heard):return false
	var results: Array = []
	for result in raw.personal_results:
		if not result is Dictionary:return false
		results.append(_clean_result(result))
	if not equivalent(results,raw.personal_results) or (raw.heard.is_empty() and results.is_empty()):return false
	for field in ["image","screen_image"]:
		if not raw.get(field) is Dictionary or not raw[field].is_empty():return false
	var viewed: Variant = raw.get("viewed_image")
	if not viewed is Dictionary:return false
	if not viewed.is_empty():
		if viewed.size()!=3 or not Archive.valid_hash(viewed.get("hash")) or viewed.get("mime")!="image/png" or not _integer(viewed.get("bytes"),1,8*1024*1024):return false
		if not _experienced_images(results).has(viewed.hash):return false
	return true

static func _valid_episode(raw: Variant) -> bool:
	if not raw is Dictionary or not _text(raw.get("text"),1600) or not raw.get("images") is Array or raw.images.size() > 2 or raw.get("source") != "subjective_memory":
		return false
	for key in raw:
		if not key in ["text","images","from_minute","to_minute","source","version"]:
			return false
	if not _number(raw.get("from_minute"),0,1000000000) or not _number(raw.get("to_minute"),float(raw.from_minute),1000000000) or not _integer(raw.get("version"),1,10000000):
		return false
	for digest in raw.images:
		if not Archive.valid_hash(digest):
			return false
	return true

static func _dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}

static func may_read_screen(context: Dictionary) -> bool:
	var own: Dictionary = context.self_state
	return bool(own.alive) and not bool(own.body.blind) and not bool(own.sleeping) and not bool(own.unconscious) and not (own.body.left_arm == "broken" and own.body.right_arm == "broken") and bool(context.last_result.get("ok",false)) and context.last_result.get("type") in ["use_device","read_screen","read_message","read_diary","read_page"]

static func has_image_grant(context: Dictionary, digest: String) -> bool:
	return Archive.valid_hash(digest) and granted_images(context).has(digest)

static func granted_images(context: Dictionary) -> Array:
	var granted: Array = []
	var own: Dictionary = _dictionary(context.get("self_state"))
	var body: Dictionary = _dictionary(own.get("body"))
	if not bool(own.get("alive",false)) or bool(body.get("blind",true)) or bool(own.get("sleeping",false)) or bool(own.get("unconscious",false)):
		return granted
	var entries: Variant = context.get("personal_results",[])
	if not entries is Array:
		return granted
	for entry in entries:
		if not entry is Dictionary or not Archive.valid_hash(entry.get("image_ref")):
			continue
		var channel: String = str(entry.get("channel",""))
		var source: String = str(entry.get("source",""))
		var permitted: bool = false
		match channel:
			"message":
				# Delivery/envelope notification is not permission to inspect an
				# attachment. Only the received, explicitly read version qualifies.
				permitted = source == "received_message" and not (body.get("left_arm") == "broken" and body.get("right_arm") == "broken")
			"shown_photo":
				permitted = source == "shown_artifact"
			"viewed_photo","photo","artifact":
				permitted = source in ["viewed_own_artifact","shown_artifact","explicit_photo_view"]
			"screen","device_screen":
				permitted = source == "read_personal_screen" and may_read_screen(context)
		if permitted and not granted.has(entry.image_ref):
			granted.append(entry.image_ref)
	return granted

static func _string(value: Variant, maximum: int) -> String:
	return value.left(maximum) if value is String else ""

static func _finite(value: Variant, fallback: float) -> float:
	return float(value) if (value is int or value is float) and is_finite(float(value)) else fallback

static func _text(value: Variant, maximum: int) -> bool:
	return value is String and value.length() <= maximum

static func _number(value: Variant, low: float, high: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= low and float(value) <= high

static func _integer(value: Variant, low: int, high: int) -> bool:
	return _number(value,low,high) and float(value) == floorf(float(value))

static func equivalent(left: Variant, right: Variant) -> bool:
	# Godot JSON restores all numbers as floats, while canonical slot/tick
	# fields are ints. Normalise both sides before strict structural comparison.
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))
