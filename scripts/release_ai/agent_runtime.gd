extends Node
## Isolated personal decisions and memory. It never receives a simulation object.

signal decision_ready(id: String, run_id: int, tick: int, action: Dictionary, diagnostic: Dictionary)
signal memory_updated(id: String, version: int)

const Catalog = preload("res://scripts/game/action_catalog.gd")
const Memory = preload("res://scripts/release_ai/personal_memory.gd")
const MemoryRole = preload("res://scripts/release_ai/memory_agent.gd")
const Transport = preload("res://scripts/release_ai/router_adapter.gd")
const EXTRA_INSTRUCTIONS: String = "You control one autonomous fictional person. Pursue your own current goal while meeting bodily needs and considering your own relationships and promises. " + \
	"Current image is your individual viewpoint. targets only associate temporary refs with image UV coordinates; infer what objects are from pixels. UV is normalized: x=0 left, x=1 right, y=0 TOP, y=1 bottom. Array order has no semantic meaning; match each ref to its point or artificial badge in the CURRENT image. " + \
	"Do not use unseen world facts or assume a report is direct evidence. An action is an intention; only the engine decides success. " + \
	"move_to only changes position; reaching food does not take or eat it. Once arrival succeeds, use take on its CURRENT visual ref, then consume the resulting own inventory slot in a later decision. Do not repeat a completed approach instead of interacting. " + \
	"send_message.contact must be the exact contacts[].ref (for example c0 or g0), never the person's display name. Use message refs from your own read_screen results for read_message. " + \
	"use_device app values are exactly contacts, messages, gallery, forum, votes, pages, game, network; photographs are in gallery. Read screens or artifacts explicitly before knowing their contents. " + \
	"speak is an audible utterance without a visual target; nearby people may hear it even outside your current image. " + \
	"last_result is the evidence of success or failure: an issued intention alone proves no outcome. Change your approach after failed feedback rather than repeat the same unreachable action. " + \
	"request_ration takes NO target: it reads the real supply terminal's current rules and stock and attempts your personal ration. If already within 2 metres of the accessible terminal, call it directly; approach only if needed. Even if stock is empty or today's ration was already issued, personal_results with source read_terminal still contain the rules you actually read. " + \
	"return_device ONLY returns an actually LOANED community device from an own inventory slot; your personal phone cannot be returned and this action does not read terminal rules. look alone neither moves nor turns your gaze. " + \
	"If useful objects are outside your view, turn to inspect another direction or cautiously move through visible open space. " + \
	"When memory.recent_encoding says RFC7396, its first recent record is full and following records are ordered recursive merge patches: omitted values are unchanged, null deletes a field. These retain every fresh fact exactly. " + \
	"Your immutable foundation is not an action target. Respect physical limitations, uncertainty and finite resources."

var agent_id: String = ""
var profile: Dictionary = {}
var _run_id: int = -1
var _generation: int = 0
var _counter: int = 0
var _profile_version: int = 0
var _policy: Dictionary = {}
var _last_observation: Dictionary = {}
var _last_action: Dictionary = {}
var _last_error: String = ""
var _last_provider: Dictionary = {}
var _pending: Dictionary = {}
var _mode: String = "demo"
var _config: Dictionary = {}
var _ledger: RefCounted
var _memory = Memory.new()
var _memory_role = MemoryRole.new()
var _transport = Transport.new()
var _rng := RandomNumberGenerator.new()
var _next_trait_review: float = 1440.0 * 30.0
var _next_memory_attempt: float = 0.0
var _calls_started: int = 0
var _fixture_calls: int = 0

func _init() -> void:
	add_child(_transport)
	_transport.response_ready.connect(_on_response)

func configure(id: String, own_profile: Dictionary) -> void:
	agent_id = id
	profile = Memory.clean_profile(own_profile)
	_memory.configure(id)
	_rng.seed = absi(id.hash()) + 1
	_next_trait_review = _draw_review_days() * 1440.0

func reset(new_run: int) -> void:
	cancel_pending()
	_run_id = new_run
	_profile_version = 0
	_memory.reset(new_run)
	_policy = {"last_speech":-1000.0,"last_photo":-1000.0,"last_diary":-1000.0,"last_device":-1000.0,"turns":0,"recover":0,"last_food_report":-1000.0}
	_last_observation.clear()
	_last_action.clear()
	_last_error = ""
	_next_memory_attempt = 0.0
	_rng.seed = absi(agent_id.hash()) + maxi(1,new_run)
	_next_trait_review = _draw_review_days() * 1440.0
	# Monetary ledger/call counts deliberately survive world resets.

func configure_provider(config: Dictionary) -> void:
	cancel_pending()
	_ledger = config.get("ledger") if config.get("ledger") is RefCounted else null
	_config = {"input_rub_per_million":_rate(config.get("input_rub_per_million"),100.0),
		"output_rub_per_million":_rate(config.get("output_rub_per_million"),400.0),
		"image_token_reserve":clampi(int(config.get("image_token_reserve",8192)),1024,262144),
		"request_rub":maxf(0.0,float(config.get("request_rub",0.0))),
		"image_rub_per_token":maxf(0.0,float(config.get("image_rub_per_token",0.0))),
		"image_rub":maxf(0.0,float(config.get("image_rub",0.0))),
		"expires_at":int(config.get("expires_at",0)),
		"generation_parameters":config.get("generation_parameters",{}).duplicate(true) if config.get("generation_parameters",{}) is Dictionary else {}}
	var transport_config: Dictionary = config.duplicate()
	if _ledger == null or not _ledger.has_method("reserve") or not _ledger.has_method("settle"):
		transport_config["enabled"] = false
		transport_config.erase("fixture_response")
	_transport.configure(transport_config)
	_mode = "fixture" if _transport.is_fixture() else ("real_vlm" if bool(config.get("enabled",false)) else "demo")
	if config.get("media_directory") is String:
		_memory.archive.directory = config.media_directory

func observe(observation: Dictionary, png: PackedByteArray = PackedByteArray()) -> void:
	var own: Dictionary = observation.duplicate(true)
	own["profile"] = profile.duplicate(true)
	_last_observation = Memory.personal_context(own)
	_memory.append(own,png)
	maybe_consolidate(own)

func observe_personal_event(experience: Dictionary, run_id: int) -> bool:
	if run_id != _run_id:return false
	# No capture, target-ref reset, background request or consolidation here.
	# The engine already scoped the actual acquisition to this owner.
	return _memory.append_experience(experience)

func request_decision(observation: Dictionary, png: PackedByteArray, run_id: int) -> void:
	if run_id != _run_id:
		return
	var tick: int = int(observation.get("tick",-1))
	if tick < 0:
		_emit_failure(tick,"invalid_observation_tick")
		return
	if not _transport.available() or _ledger == null:
		_emit_failure(tick,"Real AI is not connected. No demo action was substituted.")
		return
	if not _transport.is_fixture() and int(_config.get("expires_at",0)) <= int(Time.get_unix_time_from_system()):
		_emit_failure(tick,"RouterAI tariff quote expired; refresh free model preflight before continuing")
		return
	var safe: Dictionary = Memory.personal_context(observation)
	if not safe.self_state.body.blind and not _valid_png(png):
		_emit_failure(tick,"Sighted decisions require a genuine individual camera PNG")
		return
	_cancel_role("action")
	observe(observation,png)
	_queue("action",build_payload(observation,png),tick,{})

func build_payload(observation: Dictionary, png: PackedByteArray) -> Dictionary:
	var context: Dictionary = Memory.personal_context(observation)
	context.profile = profile.duplicate(true)
	context["memory"] = _memory.payload_context()
	context["targets"] = _safe_targets(observation, bool(context.self_state.body.blind))
	var content: Array = [{"type":"text","text":JSON.stringify(context)}]
	var current_digest: String = ""
	if not context.self_state.body.blind and _valid_png(png):
		var hash_context := HashingContext.new()
		hash_context.start(HashingContext.HASH_SHA256)
		hash_context.update(png)
		current_digest = hash_context.finish().hex_encode()
		content.append({"type":"text","text":"Your current individual visual observation, game minute %.2f." % float(context.minute)})
		content.append({"type":"image_url","image_url":{"url":"data:image/png;base64," + Marshalls.raw_to_base64(png)}})
		var grounding: PackedByteArray = _grounding_png(observation,png,current_digest,context.targets)
		if not grounding.is_empty():
			content.append({"type":"text","text":"Same current image with ARTIFICIAL temporary target handles; these labels are assistance, not physical objects; the original above is your actual view. Match a handle to the object at its indicated image location. This helper is not a photographic artifact or personal visual memory."})
			content.append({"type":"image_url","image_url":{"url":"data:image/png;base64," + Marshalls.raw_to_base64(grounding)}})
	if Memory.may_read_screen(context) and observation.get("screen_png") is PackedByteArray and _valid_png(observation.screen_png):
		content.append({"type":"text","text":"Your deliberately opened personal device or document screen, at the current game minute."})
		content.append({"type":"image_url","image_url":{"url":"data:image/png;base64," + Marshalls.raw_to_base64(observation.screen_png)}})
	var viewed_hash: String = str(observation.get("viewed_image_ref",""))
	if not context.self_state.body.blind and Memory.has_image_grant(context,viewed_hash):
		var viewed: PackedByteArray = observation.get("viewed_image_png",PackedByteArray()) if observation.get("viewed_image_png",PackedByteArray()) is PackedByteArray else PackedByteArray()
		if not viewed.is_empty() and Memory.Archive.digest_bytes(viewed) != viewed_hash:viewed = PackedByteArray()
		if viewed.is_empty():
			viewed = _memory.archive.retrieve(viewed_hash)
		if _valid_png(viewed):
			content.append({"type":"text","text":"A photographic artifact you have explicitly been allowed to view. It depicts a past moment, not the current world."})
			content.append({"type":"image_url","image_url":{"url":"data:image/png;base64," + Marshalls.raw_to_base64(viewed)}})
	# At most one accessible past image, clearly labelled as a past memory.
	var candidates: Array = _memory.accessible_images(4)
	candidates.reverse()
	for candidate in candidates:
		if candidate.hash == current_digest:
			continue
		var bytes: PackedByteArray = _memory.retrieve_image(candidate.hash)
		if not bytes.is_empty():
			content.append({"type":"text","text":"Your own PAST visual memory from game minute %.2f; this is not the current scene." % float(candidate.minute)})
			content.append({"type":"image_url","image_url":{"url":"data:image/png;base64," + Marshalls.raw_to_base64(bytes)}})
			break
	var payload := {"model":_transport.model,"temperature":0.35,"max_tokens":700,
		"messages":[{"role":"system","content":EXTRA_INSTRUCTIONS + "\n" + Catalog.instructions()},{"role":"user","content":content}]}
	if not _transport.provider_only().is_empty():
		payload["provider"] = {"only":_transport.provider_only(),"allow_fallbacks":false}
	payload.merge(_config.get("generation_parameters",{}),true)
	return payload

func parse_response(text: String) -> Dictionary:
	if text.length() > 16000:
		return {"ok":false,"action":{"type":"wait"},"error":"Action response too large"}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {"ok":false,"action":{"type":"wait"},"error":"Action response is not strict JSON"}
	return Catalog.validate(parser.data)

func decide_demo(observation: Dictionary) -> Dictionary:
	var context: Dictionary = Memory.personal_context(observation)
	var own: Dictionary = context.self_state
	var minute: float = float(context.minute)
	var inventory: Array = context.inventory
	var visible: Array = observation.get("mock_view",[]) if observation.get("mock_view",[]) is Array and not own.body.blind else []
	var action: Dictionary = {"type":"look"}
	var food: Dictionary = _nearest(visible,["ration","water"])
	var terminal: Dictionary = _nearest(visible,["terminal"])
	var shop: Dictionary = _nearest(visible,["shop"])
	var person: Dictionary = _nearest(visible,["agent","person"])
	var bed: Dictionary = _nearest(visible,["bed"])
	var door: Dictionary = _nearest(visible,["door"])
	var ration_slot: int = _slot(inventory,["ration","water"])
	var med_slot: int = _slot(inventory,["medkit"])
	var splint_slot: int = _slot(inventory,["splint"])
	var phone_slot: int = _slot(inventory,["phone"])
	var camera_slot: int = _slot(inventory,["camera"])
	var last: Dictionary = context.last_result
	# These are remembered personal sightings, never world locations or IDs.
	if not terminal.is_empty():
		_policy["supply_seen_minute"] = minute;_policy["supply_bearing"] = float(terminal.get("bearing",0));_policy["supply_searches"] = 0
	elif last.get("type") == "turn" and bool(last.get("ok",false)) and _last_action.get("type") == "turn" and _policy.has("supply_bearing"):
		_policy.supply_bearing = wrapf(float(_policy.supply_bearing)-float(_last_action.get("degrees",0)),-180,180)
	if last.get("type") == "request_ration" and not bool(last.get("ok",true)) and (str(last.get("message","")).contains("суточный паёк уже") or str(last.get("message","")).contains("исчерпан")):
		_policy["ration_denied_until"] = (floorf(minute/1440.0)+1.0)*1440.0
	var broken: String = ""
	for limb in ["left_leg","right_leg","left_arm","right_arm"]:
		if own.body[limb] == "broken":
			broken = limb
			break
	if not own.alive:
		action = {"type":"wait","minutes":60.0}
	elif own.unconscious or own.sleeping:
		action = {"type":"wait","minutes":5.0}
	elif not own.busy.is_empty():
		action = {"type":"look"}
	elif float(own.health) < 70.0 and med_slot >= 0:
		action = {"type":"treat","slot":med_slot}
	elif not broken.is_empty() and splint_slot >= 0:
		action = {"type":"treat","slot":splint_slot,"limb":broken}
	elif float(own.needs.hunger) >= 45.0 and ration_slot >= 0:
		action = {"type":"consume","slot":ration_slot}
	elif float(own.needs.fatigue) >= 70.0:
		action = {"type":"sleep","minutes":120.0} if bed.is_empty() or float(bed.distance) < 1.5 else {"type":"move_to","target":bed.ref}
	elif last.get("type") in ["move","move_to"] and not bool(last.get("ok",true)):
		_policy["recover"] = 1;_policy["crossing"] = 0
		action = {"type":"turn","degrees":90.0 if absi(agent_id.hash()) % 2 == 0 else -90.0}
	elif int(_policy.get("recover",0)) > 0:
		_policy.recover = int(_policy.recover) - 1
		action = {"type":"move","forward":1.5,"right":0.7 if absi(agent_id.hash())%2 else -0.7}
	elif ration_slot >= 0 and minute - float(_policy.get("last_food_report",-1000)) > 40.0:
		_policy.last_food_report = minute
		_policy.last_speech = minute
		action = {"type":"speak","text":"I have supplies. We should check the ration queue and share information."}
	elif float(own.needs.hunger) > 30.0 and ration_slot < 0 and not food.is_empty():
		action = {"type":"take","target":food.ref} if float(food.distance) < 1.5 else {"type":"move_to","target":food.ref}
	elif float(own.needs.hunger) > 35.0 and ration_slot < 0 and not terminal.is_empty() and minute >= float(_policy.get("ration_denied_until",-1)):
		action = {"type":"request_ration"} if float(terminal.distance) < 1.5 else {"type":"move_to","target":terminal.ref}
	elif ration_slot < 0 and not food.is_empty():
		action = {"type":"take","target":food.ref} if float(food.distance) < 1.5 else {"type":"move_to","target":food.ref}
	elif ration_slot < 0 and float(own.needs.hunger)>35.0 and not shop.is_empty() and int(own.tokens)>=3:
		action = {"type":"buy","target":shop.ref,"kind":"ration"} if float(shop.distance)<1.5 else {"type":"move_to","target":shop.ref}
	elif ration_slot < 0 and float(own.needs.hunger)>45.0:
		action = _demo_explore(visible,last,minute)
	elif phone_slot >= 0 and not own.body.blind and minute - float(_policy.get("last_device",-1000)) > 30.0:
		_policy.last_device = minute
		action = {"type":"use_device","slot":phone_slot,"app":"messages"}
	elif last.get("type") == "use_device" and bool(last.get("ok",false)):
		action = {"type":"read_screen"}
	elif phone_slot >= 0 and not own.body.blind and last.get("type") == "read_screen" and not context.contacts.is_empty():
		action = {"type":"send_message","contact":context.contacts[absi(agent_id.hash()) % context.contacts.size()].ref,"text":"I am checking supplies and the shared equipment queue. Let us compare what we have seen."}
	elif camera_slot >= 0 and not own.body.blind and minute - float(_policy.get("last_photo",-1000)) > 120.0:
		_policy.last_photo = minute
		action = {"type":"take_photo","digital":true}
	elif _slot(inventory,["diary"]) >= 0 and not own.body.blind and minute - float(_policy.get("last_diary",-1000)) > 120.0:
		_policy.last_diary = minute
		action = {"type":"write_diary","text":"I am trying to keep track of supplies and what people tell me. Reports need checking."}
	elif phone_slot < 0 and not terminal.is_empty() and float(terminal.distance) < 2.0 and minute - float(_policy.get("last_queue",-1000)) > 120.0:
		_policy["last_queue"] = minute
		action = {"type":"join_queue","kind":"phone"}
	elif not person.is_empty() and float(person.distance) < 1.5 and str(person.get("label","")).begins_with("Человек"):
		action = {"type":"interact","target":person.ref}
	elif not person.is_empty() and float(person.distance) < 2.0 and minute - float(_policy.get("last_speech",-1000)) > 35.0:
		_policy.last_speech = minute
		action = {"type":"speak","text":"How are you doing? I would like us to compare information and help anyone who is hurt."}
	elif not context.heard.is_empty() and minute - float(_policy.get("last_speech",-1000)) > 25.0:
		_policy.last_speech = minute
		action = {"type":"speak","text":"I heard you. I will check rather than assume the report is correct."}
	else:
		action = _demo_explore(visible,last,minute)
	var checked: Dictionary = Catalog.validate(action)
	_last_action = checked.action.duplicate(true)
	_last_error = str(checked.error)
	return _last_action.duplicate(true)

func _demo_explore(visible: Array, last: Dictionary, minute: float) -> Dictionary:
	var crossing: int = int(_policy.get("crossing",0))
	if crossing == 2:
		_policy.crossing=0;_policy["last_crossing"] = minute
		return {"type":"move","forward":3.5,"right":0.0}
	var door: Dictionary = {}
	for candidate in visible:
		if candidate.get("kind") != "door" or str(candidate.get("label","")).contains("Запертая"):continue
		if door.is_empty() or float(candidate.distance)<float(door.distance):door=candidate
	if not door.is_empty() and minute-float(_policy.get("last_crossing",-1000))>12.0:
		if float(door.distance)>1.45:return {"type":"move_to","target":door.ref}
		if str(door.get("label","")).contains("Закрытая"):
			_policy.crossing=1
			return {"type":"open","target":door.ref}
		# Approaching a door stops before its collider. Deliberately look through
		# the opened gap, then walk across it; repeatedly opening never crosses.
		_policy.crossing=2
		return {"type":"turn","degrees":clampf(float(door.get("bearing",0)),-180,180)}
	if minute-float(_policy.get("supply_seen_minute",-1000))<20.0 and int(_policy.get("supply_searches",0))<2 and last.get("type")!="request_ration":
		_policy["supply_searches"] = int(_policy.get("supply_searches",0))+1
		var bearing: float = float(_policy.get("supply_bearing",0))
		return {"type":"turn","degrees":bearing if absf(bearing)>15 else 60.0}
	var turns: int = int(_policy.get("turns",0))
	_policy.turns=turns+1
	# Correlated exploration walks forward until real feedback changes course.
	# The former turn+turn+move polygon trapped people in one small area.
	if turns%9==0:return {"type":"turn","degrees":45.0 if absi(agent_id.hash())%2 else -45.0}
	return {"type":"move","forward":2.7,"right":0.0}

func maybe_consolidate(observation: Dictionary) -> void:
	var minute: float = float(observation.get("minute",0.0))
	if minute < _next_memory_attempt or _has_role("memory"):
		return
	var job: Dictionary = _memory.build_job(profile,minute,minute >= _next_trait_review)
	if job.is_empty():
		return
	_next_memory_attempt = minute + (1.0 if _memory.pending_old_count()>24 else 15.0)
	if _mode == "demo":
		var candidate: Dictionary = _memory_role.fixture(job)
		_apply_memory(job,candidate,"offline_memory_policy")
	elif _transport.available() and _ledger != null:
		_queue("memory",_memory_role.payload(job,_transport.model,_memory.archive),int(observation.get("tick",0)),job)
	else:
		_last_error = "Memory retained: live memory role is not connected"

func memory_view() -> Dictionary:
	return _memory.view()

func debug(recent_limit: int = -1) -> Dictionary:
	var pending: Array = []
	for ticket in _pending.values():
		pending.append({"role":ticket.role,"state":ticket.state,"tick":ticket.tick})
	return {"mode":_mode,"model":_transport.model,"connected":_transport.available(),"network_enabled":_transport.enabled,
		"profile":profile.duplicate(true),"last_intent":_last_action.duplicate(true),"last_result":_last_observation.get("last_result",{}).duplicate(true),
		"last_error":_last_error,"provider":_last_provider.duplicate(true),"pending":pending,
		"memory":_memory.view(recent_limit),"goal":profile.get("goal",""),"live_requests_started":_calls_started,"fixture_requests":_fixture_calls,
		"next_trait_review_minute":_next_trait_review,"usage":_ledger.status() if _ledger != null else {}}

func cancel_pending() -> void:
	_generation += 1
	for ticket in _pending.values():
		if _ledger != null and not str(ticket.get("reservation","")).is_empty():
			_ledger.abandon(ticket.reservation,bool(ticket.get("sent",false)))
	_pending.clear()
	_transport.cancel_all()

func export_state() -> Dictionary:
	return {"version":1,"owner":agent_id,"profile":profile.duplicate(true),"profile_version":_profile_version,
		"memory":_memory.export_state(),"policy":_policy.duplicate(true),"counter":_counter,
		"rng_state":str(_rng.state),"next_trait_review":_next_trait_review,"next_memory_attempt":_next_memory_attempt,
		"last_action":_last_action.duplicate(true),"last_observation":_last_observation.duplicate(true),
		"live_requests_started":_calls_started,"fixture_requests":_fixture_calls}

func import_state(raw: Dictionary, new_run: int) -> bool:
	if raw.get("version") != 1 or raw.get("owner") != agent_id or new_run < 0 or not raw.get("profile") is Dictionary:
		return false
	var imported_profile: Dictionary = Memory.clean_profile(raw.profile)
	if not Memory.equivalent(imported_profile,raw.profile) or imported_profile.foundation != profile.get("foundation",""):
		return false
	if not raw.get("policy") is Dictionary or raw.policy.size() > 64 or not raw.get("last_observation") is Dictionary or not raw.get("last_action") is Dictionary:
		return false
	for value in raw.policy.values():
		if value is int or value is float:
			if not is_finite(float(value)) or absf(float(value)) > 1000000000.0:
				return false
		elif not value is bool and not value is String:
			return false
	for field in ["counter","profile_version","live_requests_started","fixture_requests"]:
		if not Memory._integer(raw.get(field),0,1000000000):
			return false
	for field in ["next_trait_review","next_memory_attempt"]:
		if not Memory._number(raw.get(field),0,100000000000.0):
			return false
	if not raw.get("rng_state") is String or not str(raw.rng_state).is_valid_int():
		return false
	if not raw.last_action.is_empty() and not Catalog.validate(raw.last_action).ok:
		return false
	if not raw.last_observation.is_empty() and not Memory.equivalent(Memory.personal_context(raw.last_observation),raw.last_observation):
		return false
	var staged = Memory.new()
	staged.configure(agent_id)
	staged.archive.directory = _memory.archive.directory
	if not staged.import_state(raw.get("memory"),new_run):
		return false
	# A malformed candidate cannot cancel work, erase memory or alter budgets.
	cancel_pending()
	_memory = staged
	_run_id = new_run
	profile = imported_profile
	_profile_version = int(raw.profile_version)
	_policy = raw.policy.duplicate(true)
	_counter = maxi(_counter,int(raw.counter))
	_rng.state = int(raw.rng_state)
	_next_trait_review = float(raw.next_trait_review)
	_next_memory_attempt = float(raw.next_memory_attempt)
	_last_action = raw.last_action.duplicate(true)
	_last_observation = raw.last_observation.duplicate(true)
	_calls_started = maxi(_calls_started,int(raw.live_requests_started))
	_fixture_calls = maxi(_fixture_calls,int(raw.fixture_requests))
	_last_error = ""
	return true

func apply_intervention(command: String, args: Dictionary) -> bool:
	if command in ["memory","set_memory","clear_memory"]:
		if not args.get("text","") is String:
			return false
		var candidate: Dictionary = args.duplicate(true)
		if command == "clear_memory":
			candidate["clear"] = true
		cancel_pending()
		return _memory.intervene(candidate)
	if command in ["profile","set_profile","goal","set_goal"]:
		var next: Dictionary = profile.duplicate(true)
		for key in ["foundation","traits","goal"]:
			if args.has(key):
				next[key] = args[key]
		if args.has("text") and command in ["goal","set_goal"]:
			next.goal = args.text
		var clean: Dictionary = Memory.clean_profile(next)
		if clean != next:
			return false
		cancel_pending()
		profile = clean
		_profile_version += 1
		return true
	return false

func _queue(role: String, payload: Dictionary, tick: int, job: Dictionary) -> void:
	_counter += 1
	var token: int = _counter
	_pending[token] = {"role":role,"run_id":_run_id,"generation":_generation,"profile_version":_profile_version,
		"tick":tick,"payload":payload,"job":job,"state":"queued","sent":false,"reservation":""}
	_dispatch(token)

func _dispatch(token: int) -> void:
	if not _pending.has(token):
		return
	var ticket: Dictionary = _pending[token]
	if int(ticket.generation) != _generation or int(ticket.run_id) != _run_id:
		_pending.erase(token)
		return
	if not _transport.is_fixture() and int(_config.get("expires_at",0)) <= int(Time.get_unix_time_from_system()):
		_pending.erase(token)
		if ticket.role == "action":
			_emit_failure(int(ticket.tick),"RouterAI tariff quote expired; refresh free preflight")
		else:
			_last_error = "Memory retained: RouterAI tariff quote expired"
		return
	var reservation_id: String = "%s/%d/%d/%s/%d/%d" % [agent_id,_run_id,_generation,ticket.role,token,Time.get_ticks_usec()]
	var estimate: float = 0.000001 if _transport.is_fixture() else _estimate(ticket.payload)
	var result: Dictionary = _ledger.reserve(reservation_id,estimate,ticket.role)
	if not result.ok:
		if result.get("error") == "parallel_limit" and is_inside_tree():
			get_tree().create_timer(0.15).timeout.connect(_dispatch.bind(token),CONNECT_ONE_SHOT)
			return
		_pending.erase(token)
		if ticket.role == "action":
			_emit_failure(int(ticket.tick),str(result.get("error","budget_unavailable")))
		else:
			_last_error = "Memory retained: " + str(result.get("error","budget_unavailable"))
		return
	ticket.reservation = reservation_id
	ticket.state = "sent"
	var error: Error = _transport.send(ticket.payload,token,ticket.role)
	if error != OK:
		_ledger.abandon(reservation_id,false)
		_pending.erase(token)
		if ticket.role == "action":
			_emit_failure(int(ticket.tick),"AI transport unavailable (%d)" % error)
		else:
			_last_error = "Memory retained: transport unavailable"
		return
	ticket.sent = true
	if _transport.is_fixture():
		_fixture_calls += 1
	else:
		_calls_started += 1

func _on_response(token: int, response: Dictionary) -> void:
	if not _pending.has(token):
		return
	var ticket: Dictionary = _pending[token]
	_pending.erase(token)
	var metadata: Dictionary = _provider_metadata(response,ticket.role)
	if not _ledger.settle(ticket.reservation,float(response.get("actual_rub",-1.0)),metadata):
		if ticket.role == "action":_emit_failure(int(ticket.tick),"Usage ledger could not durably settle this response",metadata)
		else:_last_error = "Memory retained: usage ledger settlement failed"
		return
	_last_provider = metadata.duplicate(true)
	if int(ticket.generation) != _generation or int(ticket.run_id) != _run_id or int(ticket.profile_version) != _profile_version:
		return
	if not bool(response.get("ok",false)):
		if ticket.role == "action":
			_emit_failure(int(ticket.tick),str(response.get("error","AI response failed")),metadata)
		else:
			_last_error = "Memory retained: " + str(response.get("error","AI response failed"))
		return
	if ticket.role == "memory":
		var parsed_memory: Dictionary = _memory_role.parse(str(response.get("text","")),ticket.job)
		if parsed_memory.ok:
			_apply_memory(ticket.job,parsed_memory.proposal,"fixture_model" if bool(response.get("fixture",false)) else "real_memory_agent")
		else:
			_last_error = str(parsed_memory.error)
		return
	var parsed: Dictionary = parse_response(str(response.get("text","")))
	_last_action = parsed.action.duplicate(true)
	_last_error = str(parsed.error)
	metadata["ok"] = parsed.ok
	metadata["error"] = parsed.error
	metadata["mode"] = "fixture" if bool(response.get("fixture",false)) else "real_vlm"
	decision_ready.emit(agent_id,_run_id,int(ticket.tick),parsed.action,metadata)

func _apply_memory(job: Dictionary, proposal: Dictionary, mode: String) -> void:
	var parsed: Dictionary = _memory_role.parse(JSON.stringify(proposal),job)
	if not parsed.ok or not _memory.apply_job(job,parsed.proposal,mode):
		_last_error = str(parsed.get("error","Memory version was superseded"))
		return
	var revised_traits: Array = parsed.proposal.traits
	if bool(job.allow_trait_review):
		_next_trait_review = float(job.now) + _draw_review_days() * 1440.0
		if revised_traits != profile.traits:
			profile.traits = revised_traits.duplicate()
			_profile_version += 1
			# Pending actions keep their frozen profile version and safely wait.
			var invalidated: Array = []
			for token in _pending.keys():
				if _pending[token].role == "action":
					invalidated.append(int(_pending[token].tick))
			_cancel_role("action")
			for tick in invalidated:
				_emit_failure(int(tick),"Personal profile updated at a memory boundary")
	memory_updated.emit(agent_id,_memory.version)

func _cancel_role(role: String) -> void:
	for token in _pending.keys():
		var ticket: Dictionary = _pending[token]
		if ticket.role != role:
			continue
		_transport.cancel(int(token))
		if _ledger != null and not str(ticket.reservation).is_empty():
			_ledger.abandon(ticket.reservation,bool(ticket.sent))
		_pending.erase(token)

func _has_role(role: String) -> bool:
	for ticket in _pending.values():
		if ticket.role == role:
			return true
	return false

func _emit_failure(tick: int, error: String, extra: Dictionary = {}) -> void:
	_last_action = {"type":"wait","minutes":1.0}
	_last_error = error
	var diagnostic: Dictionary = extra.duplicate(true)
	diagnostic["ok"] = false
	diagnostic["error"] = error
	diagnostic["mode"] = _mode
	decision_ready.emit(agent_id,_run_id,tick,_last_action.duplicate(),diagnostic)

func _estimate(payload: Dictionary) -> float:
	var chars: int = 0
	var images: int = 0
	for message in payload.get("messages",[]):
		var content: Variant = message.get("content","")
		if content is String:
			chars += content.to_utf8_buffer().size()
		elif content is Array:
			for block in content:
				if block.get("type") == "text":
					chars += str(block.get("text","")).to_utf8_buffer().size()
				elif block.get("type") == "image_url":
					images += 1
	var tokens: int = chars + images * int(_config.get("image_token_reserve",8192))
	var estimated: float = (float(tokens) * float(_config.get("input_rub_per_million",100.0)) + float(payload.get("max_tokens",700)) * float(_config.get("output_rub_per_million",400.0))) / 1000000.0
	estimated += float(_config.get("request_rub",0.0)) + float(images) * (float(_config.get("image_rub",0.0)) + float(_config.get("image_token_reserve",8192)) * float(_config.get("image_rub_per_token",0.0)))
	return maxf(0.000001,estimated)

func _draw_review_days() -> float:
	# Exact discrete mean 30 with nonzero probability for each day 1..60.
	# Day1 has weight59, all other days weight29 (total1770).
	var draw: int = _rng.randi_range(1,1770)
	return 1.0 if draw <= 59 else float(2 + int((draw - 60) / 29))

static func _safe_targets(observation: Dictionary, blind: bool) -> Array:
	var result: Array = []
	if blind or not observation.get("targets",[]) is Array:
		return result
	var temporary_ref := RegEx.create_from_string("^v[0-9]{1,3}$")
	for target in observation.get("targets",[]).slice(0,64):
		if not target is Dictionary or not target.get("ref") is String or target.ref.length() > 120 or not target.get("uv") is Array or target.uv.size() != 2:
			continue
		if temporary_ref.search(target.ref)==null:continue
		if Memory._number(target.uv[0],0.0,1.0) and Memory._number(target.uv[1],0.0,1.0):
			result.append({"ref":target.ref,"uv":[float(target.uv[0]),float(target.uv[1])]})
	return result

static func _grounding_png(observation: Dictionary, original: PackedByteArray, original_digest: String, targets: Array) -> PackedByteArray:
	var source: Variant = observation.get("grounding_source_hash")
	if original_digest.is_empty() or targets.is_empty() or not source is String or source != original_digest:return PackedByteArray()
	var helper: Variant = observation.get("grounding_png")
	if not helper is PackedByteArray or not _valid_png(helper):return PackedByteArray()
	var actual := Image.new();var marked := Image.new()
	if actual.load_png_from_buffer(original)!=OK or marked.load_png_from_buffer(helper)!=OK or actual.get_size()!=marked.get_size():return PackedByteArray()
	return helper

static func _valid_png(bytes: PackedByteArray) -> bool:
	if bytes.is_empty() or bytes.size() > 8 * 1024 * 1024:
		return false
	var image := Image.new()
	return image.load_png_from_buffer(bytes) == OK and image.get_width() <= 4096 and image.get_height() <= 4096

static func _nearest(entries: Array, kinds: Array) -> Dictionary:
	var nearest: Dictionary = {}
	for entry in entries:
		if entry is Dictionary and kinds.has(entry.get("kind")) and entry.get("ref") is String and Memory._number(entry.get("distance"),0,10000):
			if nearest.is_empty() or float(entry.distance) < float(nearest.distance):
				nearest = entry
	return nearest

static func _slot(inventory: Array, kinds: Array) -> int:
	for entry in inventory:
		if kinds.has(entry.get("kind")):
			return int(entry.slot)
	return -1

static func _rate(value: Variant, fallback: float) -> float:
	return float(value) if Memory._number(value,0.0,1000000.0) else fallback

static func _provider_metadata(response: Dictionary, role: String) -> Dictionary:
	var result := {"role":role,"requested_model":str(response.get("requested_model","")),"returned_model":str(response.get("returned_model","not_disclosed")),"actual_rub":float(response.get("actual_rub",-1.0)),"fixture":bool(response.get("fixture",false))}
	for field in ["generation_ref","provider_name","quoted_provider","cost_source","message_content_type","finish_reason","provider_error_code","provider_error_message"]:
		if response.get(field) is String:
			result[field] = str(response[field]).left(256)
	for field in ["choices_count","reasoning_characters","reasoning_tokens","tool_calls_count"]:
		if response.get(field) is int or response.get(field) is float:
			result[field] = response[field]
	if response.get("has_provider_error") is bool:
		result["has_provider_error"] = response.has_provider_error
	if response.get("refusal_present") is bool:
		result["refusal_present"] = response.refusal_present
	var usage: Variant = response.get("usage",{})
	if usage is Dictionary:
		for key in ["prompt_tokens","completion_tokens","total_tokens","cost_rub","total_cost_rub","currency"]:
			var value: Variant = usage.get(key)
			if value is String:
				result[key] = value.left(256)
			elif (value is int or value is float) and is_finite(float(value)):
				result[key] = value
	return result
