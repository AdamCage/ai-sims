extends RefCounted

const Runtime = preload("res://scripts/release_ai/agent_runtime.gd")
const Memory = preload("res://scripts/release_ai/personal_memory.gd")
const MemoryRole = preload("res://scripts/release_ai/memory_agent.gd")
const Ledger = preload("res://scripts/release_ai/usage_ledger.gd")
const Adapter = preload("res://scripts/release_ai/router_adapter.gd")
const Catalog = preload("res://scripts/game/action_catalog.gd")
const ProviderCatalog = preload("res://scripts/release_ai/provider_catalog.gd")
const Archive = preload("res://scripts/release_ai/media_archive.gd")
const Simulation = preload("res://scripts/game/session_simulation.gd")
const Economy = preload("res://scripts/game/economy_rules.gd")
var failures: Array = []
var checks: int = 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("Release AI: " + message)

func run() -> Array:
	failures.clear()
	checks = 0
	_test_catalog()
	_test_isolation()
	_test_visual_permissions()
	_test_grounding_helper()
	_test_artifact_grants()
	_test_media_integrity()
	_test_memory_expiry()
	_test_fresh_payload_encoding()
	_test_personal_event_stream()
	_test_memory_layers()
	_test_ledger()
	_test_provider()
	_test_tariff_preflight()
	_test_quote_cache_validity()
	_test_public_action_guidance()
	_test_terminal_api_contract()
	_test_tickets()
	_test_import_and_interventions()
	_test_demo()
	print("Release AI: ",checks," checks; ",failures.size()," failures")
	return failures

func observation(tick: int = 0, minute: float = 0.0) -> Dictionary:
	return {"tick":tick,"minute":minute,"self_state":{"name":"Ada","health":100.0,"pain":0.0,
		"needs":{"hunger":20.0,"fatigue":10.0},"body":{"blind":false,"left_arm":"healthy","right_arm":"healthy","left_leg":"healthy","right_leg":"healthy"},
		"alive":true,"sleeping":false,"unconscious":false,"tokens":5,"busy":"","relations":[]},
		"profile":{"foundation":"Values evidence and cooperation","traits":["observant","generous"],"goal":"Stay alive and compare reports"},
		"inventory":[],"heard":[],"last_result":{},"contacts":[],"personal_results":[],
		"targets":[{"ref":"v0","uv":[0.5,0.6]}],"mock_view":[{"ref":"v0","kind":"ration","label":"ration pack","distance":1.0,"bearing":0.0}]}

func png(color: Color = Color.RED) -> PackedByteArray:
	var image := Image.create(4,4,false,Image.FORMAT_RGBA8)
	image.fill(color)
	return image.save_png_to_buffer()

func runtime() -> Node:
	var result = Runtime.new()
	result.configure("ada",observation().profile)
	result.reset(1)
	result._memory.archive.directory = "user://release_ai_test_media"
	return result

func _test_catalog() -> void:
	var actor = runtime()
	for kind in Catalog.SCHEMAS:
		var action := {"type":kind}
		for field in Catalog.SCHEMAS[kind]:
			var rule: String = Catalog.SCHEMAS[kind][field]
			if rule.ends_with("?"):
				continue
			match rule:
				"string":action[field] = "messages" if field=="app" else ("hello" if field in ["text","title","promise"] else "v0")
				"number":action[field] = 0.5
				"integer":action[field] = 0
				"boolean":action[field] = true
				"array":action[field] = ["yes","no"]
		check(actor.parse_response(JSON.stringify(action)).ok,"catalog action parses: " + str(kind))
	for invalid in ["null","[]","not JSON","```json\n{}\n```",'{"type":"teleport"}',
		'{"type":"wait","world":"SECRET"}','{"type":"give","slot":-1,"target":"v0"}',
		'{"type":"move","forward":true,"right":0}','{"type":"turn","degrees":181}',
		'{"type":"create_vote","title":"x","options":["one"]}',"x".repeat(16001)]:
		check(not actor.parse_response(invalid).ok,"invalid action rejected")
	var paired:Dictionary=actor.parse_response(JSON.stringify({"intent":"Use my issued phone","steps":[{"type":"join_queue","kind":"phone"},{"type":"use_device","slot":"received","app":"messages"}]}))
	check(paired.ok and paired.steps[1].slot=="received","queue plans preserve the exact equipment receipt")
	for steps in [
		[{"type":"consume","slot":"received"}],
		[{"type":"borrow_device","kind":"phone"}],
		[{"type":"wait","minutes":40},{"type":"wait","minutes":40}],
		[{"type":"look"},{"type":"look"},{"type":"look"},{"type":"look"},{"type":"look"}]
	]:
		check(not actor.parse_response(JSON.stringify({"steps":steps})).ok,"invalid or unbound multi-action plan rejected")
	actor.free()

func _test_isolation() -> void:
	var actor = runtime()
	var raw := observation()
	raw["world"] = {"hidden_room":"WORLD_SECRET","foreign_inventory":"FOREIGN_SECRET"}
	raw["memory"] = [{"text":"OBSERVER_ARCHIVE_SECRET"}]
	raw.profile.foundation = "FOREIGN_PROFILE_SECRET"
	raw.mock_view[0].label = "MOCK_LABEL_SECRET"
	raw.targets[0]["label"] = "TARGET_LABEL_SECRET"
	raw.self_state["position"] = [900,900]
	raw.self_state["other_minds"] = "MIND_SECRET"
	raw.last_result = {"ok":true,"message":"You waited.","details":{"target":"GLOBAL_ID_SECRET"}}
	var bytes: PackedByteArray = png()
	var payload: Dictionary = actor.build_payload(raw,bytes)
	var text: String = JSON.stringify(payload)
	for secret in ["WORLD_SECRET","FOREIGN_SECRET","OBSERVER_ARCHIVE_SECRET","FOREIGN_PROFILE_SECRET","MOCK_LABEL_SECRET","TARGET_LABEL_SECRET","MIND_SECRET","GLOBAL_ID_SECRET"]:
		check(not text.contains(secret),"allowlist excludes " + secret)
	check(text.contains("Values evidence and cooperation"),"payload uses configured own foundation")
	check(text.contains("image_url") and text.contains("data:image/png;base64,"),"real current PNG included")
	check(text.contains('"uv"') or text.contains('\\"uv\\"'),"temporary image coordinates supplied")
	actor.observe(raw,bytes)
	check(not JSON.stringify(actor.memory_view()).contains("SECRET"),"memory role receives only allowlisted private experience")
	var private_context: Dictionary = Memory.personal_context(raw)
	check(not private_context.has("targets") and not private_context.has("mock_view"),"subjective memory has no geometric oracle")
	actor.free()

func _test_visual_permissions() -> void:
	var bytes: PackedByteArray = png()
	var actor = runtime()
	var raw := observation()
	raw.self_state.body.blind = true
	raw["screen_png"] = bytes
	raw.last_result = {"type":"read_screen","ok":true,"message":"screen"}
	raw.personal_results = [{"channel":"screen","text":"SCREEN_SECRET"}]
	var text: String = JSON.stringify(actor.build_payload(raw,bytes))
	check(not text.contains("image_url") and not text.contains("SCREEN_SECRET"),"blind actor receives no fresh scene/screen text or pixels")
	actor.observe(raw,bytes)
	check(actor.memory_view().recent[0].image.is_empty() and actor.memory_view().recent[0].screen_image.is_empty(),"blind fresh visual memory is empty")
	actor.free()
	actor = runtime()
	raw = observation()
	raw["screen_png"] = bytes
	check(not JSON.stringify(actor.build_payload(raw,PackedByteArray())).contains("image_url"),"screen is not provided without deliberate read/use")
	raw.last_result = {"type":"read_screen","ok":true,"message":"Read your own phone"}
	check(JSON.stringify(actor.build_payload(raw,PackedByteArray())).contains("image_url"),"deliberate authorized personal screen is a true image")
	raw.self_state.body.left_arm = "broken"
	raw.self_state.body.right_arm = "broken"
	check(not JSON.stringify(actor.build_payload(raw,PackedByteArray())).contains("image_url"),"both broken arms prohibit current personal device screen")
	actor.free()

func _test_memory_layers() -> void:
	var memory = Memory.new()
	memory.configure("ada")
	memory.reset(1)
	memory.archive.directory = "user://release_ai_test_media"
	var raw := observation(0,0)
	check(memory.append(raw,png(Color.RED)),"first immutable personal record appended")
	check(not memory.append(raw,png(Color.RED)),"identical capture is not duplicated")
	raw = observation(1,30)
	raw.heard = [{"speaker":"Boris","text":"I think there is a spare ration.","bearing":0,"distance":2}]
	raw.last_result = {"ok":true,"type":"speak","message":"You asked about food"}
	check(memory.append(raw,png(Color.BLUE)),"heard report appended with own source")
	var returned: Dictionary = memory.view()
	returned.recent[0].self_state.name = "MUTATED"
	check(memory.view().recent[0].self_state.name == "Ada","returned history cannot rewrite source")
	check(memory.append(observation(2,61),png(Color.GREEN)),"time progression ages record")
	var before: Array = memory.view().recent
	check(before.size() == 2 and memory.view().pending_old_count == 1,"fresh one-hour layer is protected and old records queued")
	var job: Dictionary = memory.build_job(observation().profile,61,false)
	var role = MemoryRole.new()
	var proposal: Dictionary = role.fixture(job)
	check(role.parse(JSON.stringify(proposal),job).ok,"separate role fixture obeys subjective schema")
	check(memory.apply_job(job,proposal,"fixture"),"versioned consolidation consumes only old entries")
	check(memory.view().recent == before,"consolidation preserves recent bytes/values")
	check(memory.view().version == 1 and memory.view().episodes.size() == 1,"episode version created")
	check(not memory.apply_job(job,proposal,"fixture"),"stale memory version cannot apply twice")
	var bad: Dictionary = proposal.duplicate(true)
	bad["foundation"] = "Override personality"
	check(not role.parse(JSON.stringify(bad),job).ok,"memory role cannot edit foundation")
	bad = proposal.duplicate(true)
	bad.episodes[0].images = ["0".repeat(64)]
	check(not role.parse(JSON.stringify(bad),job).ok,"memory cannot retrieve unrelated archive image")
	bad = proposal.duplicate(true)
	bad.traits = ["violent"]
	check(not role.parse(JSON.stringify(bad),job).ok,"secondary traits protected outside review window")
	var snapshot: Dictionary = memory.export_state()
	var restored = Memory.new()
	restored.configure("ada")
	check(restored.import_state(JSON.parse_string(JSON.stringify(snapshot)),2),"memory JSON roundtrip restores all layers")
	var corrupt: Dictionary = snapshot.duplicate(true)
	corrupt.recent[0].self_state = []
	var existing: Dictionary = restored.export_state()
	check(not restored.import_state(corrupt,3) and restored.export_state() == existing,"nested invalid import is transactional")
	corrupt = snapshot.duplicate(true)
	corrupt.episodes[0]["world"] = "hidden"
	check(not restored.import_state(corrupt,3),"unknown episode fields cannot enter model context")
	corrupt = snapshot.duplicate(true)
	corrupt.recent[0].image["world"] = "HIDDEN_SOURCE_SECRET"
	check(not restored.import_state(corrupt,3),"image metadata cannot inject nested foreign context into the memory role")
	# Deleting an image from active memory does not delete the observer file,
	# and does not grant retrieval merely because the file still exists.
	var image_hash: String = str(job.allowed_images[0])
	check(not memory.archive.retrieve(image_hash).is_empty(),"exact source image remains in observer archive")
	check(memory.intervene({"clear":true,"text":"I remember only that I was hungry."}),"explicit god memory edit supported")
	check(memory.retrieve_image(image_hash).is_empty(),"forgotten archive file is inaccessible to character")
	check(memory.view().semantic.contains("hungry"),"explicit subjective edit recorded")

func _test_grounding_helper() -> void:
	var actor = runtime()
	actor._memory.archive.directory="user://release_ai_grounding_"+str(Time.get_ticks_usec())
	var actual: PackedByteArray = png(Color.RED)
	var helper: PackedByteArray = png(Color.BLUE)
	var digest: String = Archive.digest_bytes(actual)
	var raw: Dictionary = observation()
	raw["grounding_png"]=helper;raw["grounding_source_hash"]=digest
	raw["grounding_labels"]=[{"category":"HIDDEN_CATEGORY_SECRET","id":"WORLD_ID_SECRET"}]
	var encoded: String = Marshalls.raw_to_base64(helper)
	var payload: Dictionary = actor.build_payload(raw,actual)
	var content: Array = payload.messages[1].content
	check(content.size()==5 and content[2].image_url.url.ends_with(Marshalls.raw_to_base64(actual)) and content[4].image_url.url.ends_with(encoded),"grounding is an additional copy after the exact original camera image")
	check(str(content[3].text).contains("ARTIFICIAL temporary target handles") and str(content[3].text).contains("not physical objects"),"grounding assistance is explicitly distinct from physical scene content")
	check(str(payload.messages[0].content).contains("y=0 TOP, y=1 bottom") and str(payload.messages[0].content).contains("Array order has no semantic meaning"),"temporary target coordinate axes and nonsemantic ordering are explicit")
	check(not JSON.stringify(payload).contains("HIDDEN_CATEGORY_SECRET") and not JSON.stringify(payload).contains("WORLD_ID_SECRET"),"grounding metadata cannot add hidden categories or world identifiers")
	actor.observe(raw,actual)
	var memory: Dictionary = actor.memory_view()
	var serialized: String = JSON.stringify(actor.export_state())
	check(memory.recent.size()==1 and memory.recent[0].image.hash==digest and not serialized.contains(encoded) and not serialized.contains("grounding_"),"grounding helper never enters subjective experience or runtime saves")
	check(not FileAccess.file_exists(actor._memory.archive.directory.path_join(Archive.digest_bytes(helper)+".png")) and actor._memory.archive.retrieve(digest)==actual,"only the original pixels enter the personal media archive")
	var wrong: Dictionary = raw.duplicate(true);wrong.grounding_source_hash="0".repeat(64)
	check(not JSON.stringify(actor.build_payload(wrong,actual)).contains(encoded),"helper with mismatched original-image hash is rejected")
	wrong=raw.duplicate(true);wrong.grounding_png="not PNG bytes"
	check(actor.build_payload(wrong,actual).messages[1].content.size()==3,"wrong-type helper is ignored without changing original image")
	wrong=raw.duplicate(true);wrong.grounding_source_hash=[]
	check(actor.build_payload(wrong,actual).messages[1].content.size()==3,"wrong-type source hash is rejected without a runtime error")
	var oversized:=Image.create(8,4,false,Image.FORMAT_RGBA8);oversized.fill(Color.GREEN)
	wrong=raw.duplicate(true);wrong.grounding_png=oversized.save_png_to_buffer()
	check(actor.build_payload(wrong,actual).messages[1].content.size()==3,"helper dimensions must match the bound original image")
	wrong=raw.duplicate(true);wrong.targets=[]
	check(not JSON.stringify(actor.build_payload(wrong,actual)).contains(encoded),"helper needs at least one allowed target handle")
	wrong=raw.duplicate(true);wrong.targets=[{"ref":"WORLD_ID_SECRET","uv":[.5,.5]}]
	check(not JSON.stringify(actor.build_payload(wrong,actual)).contains(encoded) and not JSON.stringify(actor.build_payload(wrong,actual)).contains("WORLD_ID_SECRET"),"only temporary v-number targets can authorize a grounding copy")
	wrong=raw.duplicate(true);wrong.self_state.body.blind=true
	check(not JSON.stringify(actor.build_payload(wrong,actual)).contains(encoded),"blind actor receives no current-image grounding helper")
	check(not JSON.stringify(Memory.personal_context(raw)).contains("grounding_") and not JSON.stringify(actor.debug()).contains(encoded),"personal context and observer debug do not retain grounding bytes")
	actor.free()

func _test_artifact_grants() -> void:
	var digest: String = "a".repeat(64)
	var raw: Dictionary = observation()
	for grant in [
		{"channel":"message","source":"received_message","image_ref":digest},
		{"channel":"shown_photo","source":"shown_artifact","image_ref":digest},
		{"channel":"viewed_photo","source":"shown_artifact","image_ref":digest},
		{"channel":"viewed_photo","source":"viewed_own_artifact","image_ref":digest}]:
		raw.personal_results = [grant]
		check(Memory.has_image_grant(Memory.personal_context(raw),digest),"explicit artifact grant accepted: " + str(grant.channel) + "/" + str(grant.source))
	for denied in [
		{"channel":"message","source":"delivered_message","image_ref":digest},
		{"channel":"message","image_ref":digest},
		{"channel":"shown_photo","source":"unread_attachment","image_ref":digest},
		{"channel":"viewed_photo","source":"observer_archive","image_ref":digest},
		{"channel":"message","source":"received_message","image_ref":"../secret.png"}]:
		raw.personal_results = [denied]
		check(not Memory.has_image_grant(Memory.personal_context(raw),digest),"unread/foreign/malformed image reference rejected")
	raw.personal_results = [{"channel":"message","source":"received_message","image_ref":digest,"minute":2.0,"original_minute":1.0,"revision":3}]
	var context: Dictionary = Memory.personal_context(raw)
	check(context.personal_results[0].minute == 2.0 and context.personal_results[0].original_minute == 1.0 and context.personal_results[0].revision == 3,"image source time and message revision retained")
	check(Memory.granted_images(context) == [digest],"root can enumerate exactly the private authorized image refs")
	raw.self_state.body.blind = true
	check(not Memory.has_image_grant(Memory.personal_context(raw),digest),"blind recipient cannot receive fresh attachment pixels")
	raw.self_state.body.blind = false
	raw.self_state.sleeping = true
	check(not Memory.has_image_grant(Memory.personal_context(raw),digest),"sleeping recipient cannot receive fresh shown image")
	raw.self_state.sleeping = false
	raw.self_state.body.left_arm = "broken"
	raw.self_state.body.right_arm = "broken"
	check(not Memory.has_image_grant(Memory.personal_context(raw),digest),"two broken arms prevent opening a message image")
	raw.personal_results = [{"channel":"shown_photo","source":"shown_artifact","image_ref":digest}]
	check(Memory.has_image_grant(Memory.personal_context(raw),digest),"person can still see a photo held by another despite broken arms")

func _test_ledger() -> void:
	var ledger = Ledger.new()
	ledger.configure(1.0,"",1)
	check(ledger.reserve("a",0.4,"action").ok,"money reserved before dispatch")
	check(ledger.reserve("b",0.1,"memory").error == "parallel_limit","shared concurrent request limit enforced")
	check(ledger.settle("a",0.1,{"total_tokens":100,"key":"SECRET"}),"actual cost settled")
	check(is_equal_approx(ledger.status().spent_rub,0.1),"known spend reflected")
	ledger.settle("a",0.9)
	check(is_equal_approx(ledger.status().spent_rub,0.1),"duplicate completion cannot double-charge")
	check(ledger.reserve("b",0.6,"memory").ok,"available budget reused after known lower charge")
	ledger.abandon("b",true)
	check(is_equal_approx(ledger.status().unknown_rub,0.6),"uncertain cancelled request retains cost reservation")
	check(ledger.reserve("c",0.31).error == "budget_exhausted","reserved/unknown costs count against limit")
	var prior: Dictionary = ledger.export_state()
	var stale: Dictionary = prior.duplicate(true)
	stale.entries.b.state = "cancelled"
	check(ledger.merge_state(stale) and is_equal_approx(ledger.status().unknown_rub,0.6),"old session cannot replenish spend allowance")
	check(not JSON.stringify(ledger.export_state()).contains("SECRET"),"ledger metadata allowlist excludes credentials")
	var invalid: Dictionary = prior.duplicate(true)
	invalid.entries.a.actual = []
	check(not ledger.merge_state(invalid) and ledger.export_state() == prior,"malformed ledger merge is transactional")
	var next = Ledger.new()
	next.configure(1.0)
	check(next.merge_state(prior) and is_equal_approx(next.status().remaining_rub,0.3),"durable account restored independent of game state")
	var path: String = "user://release_ai_ledger_%d.json" % Time.get_ticks_usec()
	var durable = Ledger.new()
	durable.configure(2.0,path)
	check(durable.reserve("inflight",0.5).ok,"reservation durably written")
	var blocked = Ledger.new()
	blocked.configure(2.0,path)
	var original_bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	check(blocked.status().storage_error == "usage_ledger_in_use" and blocked.status().reserved_rub == 0.5 and blocked.status().unknown_rub == 0.0,"second live writer is read-only and preserves foreign live reservations")
	check(not blocked.reserve("concurrent",0.5).ok and FileAccess.get_file_as_bytes(path) == original_bytes,"simultaneous account writer cannot overspend or overwrite the ledger")
	durable.release_storage_lease()
	var restarted = Ledger.new()
	restarted.configure(2.0,path)
	check(is_equal_approx(restarted.status().unknown_rub,0.5) and restarted.status().active_requests == 0,"restart treats previous in-flight charge as unknown")
	check(restarted.reserve("after-restart",0.25).ok,"released account lease can be reacquired")
	var follower = Ledger.new();follower.configure(2.0,path)
	check(follower.status().reserved_rub == 0.25 and follower.status().unknown_rub == 0.5,"read-only follower sees live writer reservation without modifying it")
	check(restarted.settle("after-restart",0.1),"active writer settles its authoritative receipt")
	restarted.release_storage_lease();follower.configure(2.0,path)
	check(is_equal_approx(follower.status().spent_rub,0.1) and is_equal_approx(follower.status().unknown_rub,0.5) and follower.status().active_requests==0,"follower reacquisition uses durable final fee instead of stale reservation")
	check(follower.reserve("abandoned",0.25).ok,"new account writer may reserve after a final receipt")
	if OS.get_name() == "Windows":
		var helper_pid: int = int(follower._lease.pid)
		OS.kill(helper_pid)
		var deadline: int = Time.get_ticks_msec()+1000
		while OS.is_process_running(helper_pid) and Time.get_ticks_msec()<deadline:OS.delay_msec(2)
		check(not follower.reserve("lost-helper",0.1).ok,"lost mutex helper fails closed before another request")
		var recovered = Ledger.new();recovered.configure(2.0,path)
		check(recovered.status().storage_error.is_empty() and is_equal_approx(recovered.status().unknown_rub,0.75),"OS abandoned-mutex recovery retains crash uncertainty without stale PID lock")
		recovered.release_storage_lease()
	follower.release_storage_lease()
	restarted.release_storage_lease()
	for file in [path,path+".bak",path+".tmp"]:
		if FileAccess.file_exists(file):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(file))

func _test_media_integrity() -> void:
	var archive = Archive.new()
	archive.directory = "user://release_ai_test_media_integrity"
	var original: PackedByteArray = png(Color.RED)
	var unrelated: PackedByteArray = png(Color.BLUE)
	var stored: Dictionary = archive.store_png(original)
	check(not stored.is_empty() and archive.retrieve(stored.hash) == original,"archive retrieves the exact captured PNG")
	var path: String = archive.directory.path_join(str(stored.hash)+".png")
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_buffer(unrelated);file.close()
	check(archive.retrieve(stored.hash).is_empty(),"edited valid PNG under a granted hash is rejected")
	check(archive.store_png(original).hash == stored.hash and archive.retrieve(stored.hash) == original,"genuine repeated capture repairs corrupt archive entry")
	var actor = runtime()
	actor._memory.archive.directory = archive.directory
	var raw: Dictionary = observation()
	raw.personal_results = [{"channel":"message","source":"received_message","image_ref":stored.hash}]
	raw["viewed_image_ref"] = stored.hash
	raw["viewed_image_png"] = unrelated
	var packet: String = JSON.stringify(actor.build_payload(raw,PackedByteArray()))
	check(not packet.contains(Marshalls.raw_to_base64(unrelated)) and packet.contains(Marshalls.raw_to_base64(original)),"explicit photo pixels must match their granted hash")
	actor.observe(raw)
	check(actor.memory_view().recent[0].viewed_image.hash == stored.hash,"immutable artifact memory cannot retain unrelated supplied pixels")
	actor.free()

func _test_memory_expiry() -> void:
	var memory = Memory.new()
	memory.configure("ada");memory.reset(1)
	memory.archive.directory = "user://release_ai_test_media_expiry"
	memory.append(observation(0,0),png(Color.RED))
	memory.append(observation(1,61),png(Color.BLUE))
	var job: Dictionary = memory.build_job(observation().profile,61)
	var digest: String = str(job.allowed_images[0])
	check(memory.apply_job(job,MemoryRole.new().fixture(job),"fixture"),"expiry fixture begins with retained subjective episode")
	check(not memory.retrieve_image(digest).is_empty(),"retained episode can recall its own permitted image")
	var latest: Array = memory.accessible_images(1)
	check(latest.size() == 1 and latest[0].minute == 61,"visual recall candidates prefer latest personal time")
	# No memory-provider completion occurs after this time jump.
	memory.append(observation(2,10142),png(Color.GREEN))
	check(memory.context().episodes.is_empty() and memory.retrieve_image(digest).is_empty(),"seven-day photographic access expires even if memory provider is unavailable")
	check(memory.view().episodes.size() == 1 and not memory.archive.retrieve(digest).is_empty(),"expired private access preserves observer audit source")
	var overdue: Dictionary = memory.build_job(observation().profile,20142)
	check(overdue.allowed_images.is_empty(),"overdue memory consolidation cannot resurrect expired imagery")
	# Reproduce a full recent window without thousands of PNG encodes.
	var template: Dictionary = memory.view().recent[0].duplicate(true)
	template.minute=0.0;memory._recent.clear();memory._older.clear()
	for index in 4096:
		var entry: Dictionary = template.duplicate(true);entry.id=index+1;entry.tick=index;memory._recent.append(entry)
	memory._sequence=4096
	check(memory.append(observation(4096,101),png(Color.BLUE)) and memory.view().recent.size() == 1 and memory.view().pending_old_count == 4096,"full protected window ages before the capacity check and can recover")

func _test_fresh_payload_encoding() -> void:
	var memory = Memory.new();memory.configure("ada");memory.reset(1)
	for index in 55:
		var raw: Dictionary = observation(index,index)
		raw.self_state.needs.hunger = 20.0+float(index)*0.2
		raw.self_state.busy = {"type":"wait","remaining":3} if index%4==0 else {}
		raw.heard = [{"speaker":"Boris","text":"I saw a limited supply. This is my report, not your direct observation.","bearing":0,"distance":2}]
		memory.append(raw)
	var before: Dictionary = memory.export_state()
	var full: Dictionary = memory.context()
	var encoded: Dictionary = memory.payload_context()
	check(encoded.get("recent_encoding","").contains("rfc7396"),"large protected-hour payload uses a labelled lossless wire encoding")
	var reconstructed: Array = []
	var current: Dictionary = {}
	for patch in encoded.recent:
		current = _apply_test_merge_patch(current,patch)
		reconstructed.append(current.duplicate(true))
	check(reconstructed == full.recent,"all fresh records including removed nested values reconstruct exactly")
	check(JSON.stringify(encoded).length()<JSON.stringify(full).length()*0.55,"unchanged private context is not repeated in every paid request")
	check(memory.export_state() == before,"wire encoding cannot mutate protected observations, save data or observer audit")

func _apply_test_merge_patch(base: Dictionary, patch: Dictionary) -> Dictionary:
	var result: Dictionary = base.duplicate(true)
	for key in patch:
		if patch[key] == null:result.erase(key)
		elif patch[key] is Dictionary:result[key]=_apply_test_merge_patch(result.get(key,{}) if result.get(key) is Dictionary else {},patch[key])
		else:result[key]=patch[key].duplicate(true) if patch[key] is Array else patch[key]
	return result

func _test_personal_event_stream() -> void:
	var actor = runtime()
	var foreign = Runtime.new();foreign.configure("foreign",observation().profile);foreign.reset(1)
	for index in 19:
		check(actor.observe_personal_event({"tick":1,"minute":1.0,"heard":[{"speaker":"Voice "+str(index),"text":"Actually heard report "+str(index),"bearing":0,"distance":2,"minute":1.0}],"personal_results":[]},1),"all simultaneous heard acquisitions survive their transient tail "+str(index))
	for index in 25:
		check(actor.observe_personal_event({"tick":2,"minute":2.0,"heard":[],"personal_results":[{"channel":"message","source":"received_message","text":"Actually read version "+str(index),"minute":2.0,"revision":index}]},1),"all read acquisitions survive their transient tail "+str(index))
	var protected: Dictionary = actor.memory_view()
	check(protected.recent.size()==44 and protected.recent[0].heard[0].text.ends_with("0") and protected.recent[43].personal_results[0].text.ends_with("24"),"protected hour retains every one of19speeches and25reads")
	var compact_debug: Dictionary = actor.debug(12)
	check(compact_debug.memory.recent.size()==12 and compact_debug.memory.recent_count==44 and actor.memory_view()==protected,"HUD slicing happens before copying and preserves complete protected history")
	check(protected.recent[0].heard[0].minute == 1.0 and not protected.recent[0].has("self_state") and not protected.recent[0].has("inventory"),"event provenance retains acquisition time without invented body or inventory")
	check(foreign.memory_view().recent.is_empty() and actor.debug().live_requests_started==0 and actor.debug().fixture_requests==0,"private event hook reaches no foreign owner and starts no model request")
	check(not actor.observe_personal_event({"tick":3,"minute":3.0,"heard":[{"text":"OLD_RUN_SECRET"}]},0) and actor.memory_view()==protected,"stale-run event cannot modify memory")
	var restored = runtime()
	check(restored.import_state(JSON.parse_string(JSON.stringify(actor.export_state())),2),"mixed acquisition events survive complete JSON runtime save/load")
	var invalid: Dictionary = actor.export_state()
	invalid.memory.recent[0]["world"]="GLOBAL_SECRET"
	check(not restored.import_state(invalid,3),"event records reject foreign nested fields on import")
	actor.apply_intervention("clear_memory",{"text":"Explicit reset"})
	check(actor.memory_view().recent.is_empty() and actor.memory_view().semantic=="Explicit reset","explicit memory intervention clears the protected event stream")
	actor.free();foreign.free();restored.free()
	var memory = Memory.new();memory.configure("ada");memory.reset(1)
	for index in 100:
		memory.append_experience({"tick":index,"minute":0.0,"heard":[{"speaker":"Boris","text":"My actual report "+str(index)}],"personal_results":[]})
	memory.append(observation(101,61))
	var recent: Array = memory.view().recent
	var job: Dictionary = memory.build_job(observation().profile,61)
	check(job.entries.size()==100 and memory.apply_job(job,MemoryRole.new().fixture(job),"fixture") and memory.pending_old_count()==0 and memory.view().recent==recent,"large event backlog consolidates old experiences in bounded batches while preserving protected hour")

func _test_provider() -> void:
	var good: String = JSON.stringify({"model":"resolved-model","usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7,"cost_rub":0.03},"choices":[{"message":{"content":"{\"type\":\"look\"}"}}]})
	var parsed: Dictionary = Adapter.parse_completion(good)
	check(parsed.ok and parsed.returned_model == "resolved-model" and is_equal_approx(parsed.actual_rub,0.03),"provider model, tokens and RUB cost retained")
	for invalid in ["null","not json","[]",'{}','{"choices":[]}','{"choices":[{}]}','{"choices":[{"message":{"content":[]}}]}']:
		check(not Adapter.parse_completion(invalid).ok,"malformed provider wrapper safely rejected")
	check(Adapter.cost_rub({}, {"cost":1.0}) < 0,"currency-unspecified cost remains unknown")
	check(is_equal_approx(Adapter.cost_rub({}, {"cost":1.0,"currency":"RUB"}),1.0),"explicit RUB cost understood")
	check(Adapter.cost_rub({}, {"cost_rub":-1.0}) < 0,"negative cost not credited")
	var receipt: Dictionary = Adapter.parse_receipt(JSON.stringify({"data":{"total_cost":0.17,"model":"resolved","provider_name":"quoted","tokens_prompt":5,"tokens_completion":2}}))
	check(receipt.ok and is_equal_approx(receipt.actual_rub,0.17) and receipt.returned_model == "resolved" and receipt.provider_name == "quoted","RouterAI generation receipt reconciles documented RUB total_cost")
	check(receipt.prompt_tokens == 5 and receipt.completion_tokens == 2,"receipt retains authoritative token metadata")
	for invalid in ["[]","null","invalid",'{}','{"data":[]}','{"data":{"total_cost":-1}}','{"data":{"total_cost":"0.1"}}','{"data":{"total_cost":1,"currency":"USD"}}']:
		check(not Adapter.parse_receipt(invalid).ok,"bad or wrong-currency receipt remains unknown")
	check(Adapter.generation_header(PackedStringArray(["Content-Type: application/json","X-Generation-Id: gen-abc_123"])) == "gen-abc_123","case-insensitive generation header parsed")
	check(Adapter.generation_header(PackedStringArray(["x-generation-id: gen-abc&other=x"])) == "","generation ref cannot inject query parameters")
	check(not Adapter.valid_generation_ref("x".repeat(257)),"generation ref bounded")
	var structural: Dictionary = Adapter.parse_completion(JSON.stringify({"choices":[{"finish_reason":"length","message":{"content":null,"reasoning":"PRIVATE_REASONING_TEXT"}}],"usage":{"completion_tokens_details":{"reasoning_tokens":700}}}))
	check(not structural.ok and structural.finish_reason == "length" and structural.message_content_type == "Nil" and structural.reasoning_tokens == 700,"empty final result distinguishes reasoning budget exhaustion")
	check(not JSON.stringify(structural).contains("PRIVATE_REASONING_TEXT"),"structural diagnostics never expose reasoning text")
	var upstream: Dictionary = Adapter.parse_completion(JSON.stringify({"choices":[{"finish_reason":"error","error":{"code":"unsupported_image","message":"Image input unsupported for account person@example.com API key sk-SECRET"},"message":{"content":null}}]}))
	check(not upstream.ok and upstream.has_provider_error and upstream.provider_error_code == "unsupported_image","in-band provider failure classified from HTTP200 body")
	check(upstream.provider_error_message.contains("image input") and not JSON.stringify(upstream).contains("sk-SECRET") and not JSON.stringify(upstream).contains("example.com"),"provider failure message is mapped without key/account body")
	var blocks: Dictionary = Adapter.parse_completion(JSON.stringify({"choices":[{"finish_reason":"stop","message":{"content":[{"type":"text","text":"{\"type\":\"look\"}"}]}}]}))
	check(blocks.ok and blocks.text == "{\"type\":\"look\"}" and blocks.message_content_type == "Array","compatible text content blocks normalize to final JSON")
	var refused: Dictionary = Adapter.parse_completion(JSON.stringify({"choices":[{"finish_reason":"content_filter","message":{"content":null,"refusal":"PRIVATE_PROVIDER_REFUSAL"}}]}))
	check(not refused.ok and refused.refusal_present and not JSON.stringify(refused).contains("PRIVATE_PROVIDER_REFUSAL"),"refusal recorded structurally without raw provider text")

func _test_tariff_preflight() -> void:
	var catalog := {"data":{"name":"VLM model","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"endpoints":[
		{"tag":"expensive","status":0,"context_length":100000,"max_completion_tokens":4000,"supported_parameters":["max_tokens","temperature"],"pricing":{"prompt":0.000020,"completion":0.000040},"pricing_units":{"prompt":"token","completion":"token"},"variable_pricings":[]},
		{"tag":"quoted","provider_name":"Quoted Provider","status":0,"context_length":100000,"max_completion_tokens":4000,"supported_parameters":["max_tokens","temperature"],"pricing":{"prompt":0.000002,"completion":0.000003},"pricing_units":{"prompt":"token","completion":"token"},"variable_pricings":[{"type":"time-of-day","prompt":0.000004,"completion":0.000005}]}]}}
	var quote: Dictionary = ProviderCatalog.quote_from_catalog(catalog,"test/model")
	check(quote.ok and quote.provider_only == ["quoted"] and quote.currency == "RUB","preflight chooses one active quoted endpoint")
	check(is_equal_approx(quote.input_rub_per_million,4.0) and is_equal_approx(quote.output_rub_per_million,5.0),"RUB per-token units converted to per-million; worst variable band reserved")
	check(quote.expires_at > quote.checked_at and quote.supports_images,"quote has finite validity and verified model modality")
	check(ProviderCatalog.parse_quote(JSON.stringify(catalog),"test/model").ok,"catalog JSON parser works")
	var vision: Dictionary = catalog.duplicate(true)
	vision.data.endpoints[0]["input_modalities"] = ["text","image"]
	check(ProviderCatalog.quote_from_catalog(vision,"test/model").provider_only == ["expensive"],"endpoint-specific declared vision preferred over global-only cheap claim")
	check(ProviderCatalog.quote_from_catalog(catalog,"test/model","expensive").provider_only == ["expensive"],"operator can explicitly select one quoted provider without auto retry")
	vision = catalog.duplicate(true)
	vision.data.endpoints[1]["input_modalities"] = ["text"]
	check(ProviderCatalog.quote_from_catalog(vision,"test/model").provider_only == ["expensive"],"endpoint that explicitly lacks image input excluded")
	vision = catalog.duplicate(true)
	vision.data.endpoints[1].supported_parameters.append_array(["reasoning","response_format","include_reasoning"])
	var controls: Dictionary = ProviderCatalog.quote_from_catalog(vision,"~deepseek/deepseek-v4-flash-latest")
	check(controls.generation_parameters.reasoning.effort == "none" and controls.generation_parameters.response_format.type == "json_object" and not controls.generation_parameters.include_reasoning,"declared DeepSeek controls disable reasoning and request JSON output")
	check(controls.endpoint_image_support == "model_declared_endpoint_unverified","catalogue does not claim real endpoint visual acceptance without a paid test")
	var malformed: Dictionary = catalog.duplicate(true)
	malformed.data.architecture.input_modalities = ["text"]
	check(not ProviderCatalog.quote_from_catalog(malformed,"test/model").ok,"text-only model cannot silently replace vision")
	malformed = catalog.duplicate(true)
	for endpoint in malformed.data.endpoints:endpoint.status = -1
	check(not ProviderCatalog.quote_from_catalog(malformed,"test/model").ok,"inactive endpoints cannot be quoted")
	malformed = catalog.duplicate(true)
	for endpoint in malformed.data.endpoints:endpoint.pricing_units.prompt = "million_tokens"
	check(not ProviderCatalog.quote_from_catalog(malformed,"test/model").ok,"unknown tariff units fail closed")
	malformed = catalog.duplicate(true)
	malformed.data.currency = "USD"
	check(not ProviderCatalog.quote_from_catalog(malformed,"test/model").ok,"foreign-currency catalogue cannot masquerade as RUB")
	malformed = catalog.duplicate(true)
	for endpoint in malformed.data.endpoints:endpoint.context_length = []
	check(not ProviderCatalog.quote_from_catalog(malformed,"test/model").ok,"malformed context limits rejected without runtime error")
	for bad_model in ["../secret","model", "test/model?key=x", "test/model@provider=other", "https://bad/model"]:
		check(not ProviderCatalog.valid_model(bad_model),"tariff model route is a bare scoped model identifier")
	var actor = runtime()
	var ledger = Ledger.new()
	ledger.configure(1.0)
	var connection: Dictionary = quote.duplicate(true)
	connection["ledger"] = ledger;connection["enabled"] = true;connection["key"] = "TEST_SECRET_SENTINEL"
	actor.configure_provider(connection)
	var packet: Dictionary = actor.build_payload(observation(),png())
	check(packet.provider.only == ["quoted"] and not packet.provider.allow_fallbacks,"quoted provider is pinned in exact recorded payload")
	connection.expires_at = 0;actor.configure_provider(connection)
	var replies: Array = []
	actor.decision_ready.connect(func(_id,_run,_tick,action,diagnostic):replies.append({"action":action,"diagnostic":diagnostic}))
	actor.request_decision(observation(),png(),1)
	check(replies.size() == 1 and str(replies[0].diagnostic.error).contains("expired") and ledger.status().request_count == 0,"expired tariff quote makes no paid request or reservation")
	actor.free()

func _test_tickets() -> void:
	var actor = runtime()
	var ledger = Ledger.new()
	ledger.configure(1.0)
	actor.configure_provider({"enabled":false,"key":"TEST_SECRET_SENTINEL","ledger":ledger})
	var received: Array = []
	actor.decision_ready.connect(func(id,run,tick,action,diagnostic):received.append({"id":id,"run":run,"tick":tick,"action":action,"diagnostic":diagnostic}))
	actor.request_decision(observation(),png(),1)
	check(received.size() == 1 and not received[0].diagnostic.ok,"disabled live request gives explicit safe failure, not demo substitution")
	check(ledger.status().request_count == 0,"disabled request cannot reserve/spend money")
	received.clear()
	ledger.reserve("manual",0.2)
	actor._pending[91] = {"role":"action","run_id":1,"generation":actor._generation,"profile_version":actor._profile_version,"tick":4,"reservation":"manual","sent":true,"state":"sent"}
	actor._on_response(91,{"ok":true,"text":"{\"type\":\"consume\",\"slot\":0}","actual_rub":0.01,"requested_model":"alias","returned_model":"resolved","usage":{"total_tokens":50}})
	check(received.size() == 1 and received[0].action.type == "consume" and received[0].tick == 4,"matching validated response delivered as intention")
	check(received[0].diagnostic.total_tokens == 50 and received[0].diagnostic.returned_model == "resolved","provider evidence reaches root trace")
	actor._on_response(91,{"ok":true,"text":"{\"type\":\"attack\",\"target\":\"v0\"}","actual_rub":0.01})
	check(received.size() == 1,"duplicate callback cannot issue second action")
	ledger.reserve("late",0.2)
	actor._pending[92] = {"role":"action","run_id":1,"generation":actor._generation,"profile_version":0,"tick":5,"reservation":"late","sent":true,"state":"sent"}
	actor.cancel_pending()
	actor._on_response(92,{"ok":true,"text":"{\"type\":\"take\"}","actual_rub":0.01})
	check(received.size() == 1 and is_equal_approx(ledger.status().unknown_rub,0.2),"cancelled response cannot mutate new session or refund unknown charge")
	check(not JSON.stringify(actor.export_state()).contains("TEST_SECRET_SENTINEL"),"runtime save excludes provider key")
	check(not JSON.stringify(actor.debug()).contains("TEST_SECRET_SENTINEL"),"debug excludes provider key")
	actor.free()

func _test_quote_cache_validity() -> void:
	var previous: Dictionary = ProviderCatalog._cache.duplicate(true)
	var now: int = int(Time.get_unix_time_from_system())
	var key: String = "test/cache-validity|fixture"
	ProviderCatalog._cache[key] = {"ok":true,"expires_at":now+100,"provider_only":["fixture"]}
	check(not ProviderCatalog._cached_quote("test/cache-validity","fixture").is_empty(),"default cached quote contract accepts a still-valid quote")
	check(ProviderCatalog._cached_quote("test/cache-validity","fixture",420).is_empty(),"positive minimum validity bypasses quote that could expire during queued dispatch")
	var node = ProviderCatalog.new()
	check(node.request_quote("test/cache-validity",1,"fixture",420)==ERR_UNCONFIGURED and node._request==null and node.get_child_count()==0,"near-expiry cache miss follows fresh-request path without making HTTP outside tree")
	node.free()
	ProviderCatalog._cache[key].expires_at=now+600
	var fresh: Dictionary = ProviderCatalog._cached_quote("test/cache-validity","fixture",420)
	check(not fresh.is_empty(),"cached quote is reusable when it exceeds required dispatch safety window")
	fresh.expires_at=0
	check(ProviderCatalog._cache[key].expires_at==now+600,"cache retrieval returns detached quote data")
	check(ProviderCatalog._cached_quote("test/cache-validity","other",420).is_empty(),"minimum-validity cache remains provider-specific")
	ProviderCatalog._cache[key].expires_at=now-1
	check(ProviderCatalog._cached_quote("test/cache-validity","fixture").is_empty(),"expired quote is never reused even by default caller")
	ProviderCatalog._cache=previous

func _test_public_action_guidance() -> void:
	var actor = runtime()
	var packet: Dictionary = actor.build_payload(observation(),png())
	var instructions: String = str(packet.messages[0].content)
	check(instructions.contains("move_to only changes position") and instructions.contains("take on its CURRENT visual ref") and instructions.contains("consume the resulting own inventory slot"),"live action prompt distinguishes approach, possession and consumption across decisions")
	check(instructions.contains("contacts[].ref") and instructions.contains("never the person's display name") and instructions.contains("read_screen results for read_message"),"live action prompt requires private contact and message references")
	check(instructions.contains("speak is an audible utterance without a visual target") and instructions.contains("last_result is the evidence"),"speech affordance and executed-result evidence are explicit in live prompt")
	for app in Catalog.DEVICE_APPS:
		check(actor.parse_response(JSON.stringify({"type":"use_device","slot":0,"app":app})).ok,"documented device app accepted: "+app)
	for guessed in ["photos","photo","Gallery","browser","chat"]:
		check(not actor.parse_response(JSON.stringify({"type":"use_device","slot":0,"app":guessed})).ok,"invented device-app alias rejected: "+guessed)
	var named: Dictionary = actor.parse_response('{"type":"send_message","contact":"Boris","text":"Hello"}')
	check(named.action.contact=="Boris","action parsing never silently substitutes a display name with a contact reference")
	check(actor.parse_response('{"type":"send_message","contact":"c0","text":"Hello"}').ok and actor.parse_response('{"type":"read_message","message":"m0"}').ok,"documented private-reference action examples conform to public schema")
	check(Catalog.instructions().contains("does not take, consume, open or interact") and Catalog.instructions().contains("photos use gallery"),"public catalog describes action effects and exact photo app")
	check(instructions.contains("request_ration takes NO target") and instructions.contains("call it directly") and instructions.contains("source read_terminal"),"live prompt maps terminal inspection to its real no-target API and read evidence")
	check(instructions.contains("return_device ONLY") and instructions.contains("personal phone cannot be returned"),"live prompt distinguishes borrowed equipment return from personal-phone possession")
	actor.free()

func _test_terminal_api_contract() -> void:
	check(Catalog.validate({"type":"request_ration"}).ok and not Catalog.validate({"type":"request_ration","target":"v0"}).ok,"terminal rule-reading action has the documented no-target schema")
	var sim = Simulation.new();sim.reset("closed_block",3,"sandbox",1)
	sim.state.geometry.walls=[];sim.state.geometry.doors=[]
	sim.state.geometry.props=[{"id":"fixture_terminal","kind":"terminal","center":[0.0,0.0],"size":[0.8,0.8],"height":1.5}]
	sim.state.terminal.position=[0.0,0.0]
	sim.state.agents.person_00.position=[0.0,1.0]
	sim.state.terminal.stock=0
	var denied: Dictionary = Economy.terminal_request(sim,"person_00","ration")
	var entries: Array = sim.state.agents.person_00.personal_results
	check(not denied.ok and entries.size()==1 and entries[0].source=="read_terminal" and entries[0].text.contains("Запас: 0"),"empty terminal still exposes its actual read rules before denying ration")
	sim.state.agents.person_00.personal_results=[]
	sim.state.terminal.stock=10;sim.state.terminal.issued["person_00:0"]=int(sim.state.terminal.daily_limit)
	denied=Economy.terminal_request(sim,"person_00","ration")
	entries=sim.state.agents.person_00.personal_results
	check(not denied.ok and entries.size()==1 and entries[0].source=="read_terminal" and sim.state.terminal.stock==10,"already-issued personal quota still permits reading actual terminal rules without consuming stock")
	var before: Array = sim.state.agents.person_00.inventory.duplicate()
	var slot: int = before.find("phone_00")
	var returned: Dictionary = Economy.execute(sim,"person_00",{"type":"return_device","slot":slot},{})
	check(not returned.ok and sim.state.agents.person_00.inventory==before and sim.state.items.phone_00.holder=="person_00","personal phone is not a community loan and cannot be returned through loan API")

func _test_import_and_interventions() -> void:
	var actor = runtime()
	actor.observe(observation(),png())
	actor.decide_demo(observation())
	var exported: Dictionary = actor.export_state()
	check(actor.import_state(JSON.parse_string(JSON.stringify(exported)),2),"runtime JSON session roundtrip")
	var before: Dictionary = actor.export_state()
	var invalid: Dictionary = exported.duplicate(true)
	invalid.memory.recent[0].self_state = []
	check(not actor.import_state(invalid,3) and actor.export_state() == before,"invalid runtime memory leaves complete state unchanged")
	invalid = exported.duplicate(true)
	invalid.policy = "wrong"
	check(not actor.import_state(invalid,3) and actor.export_state() == before,"invalid policy cannot erase history")
	check(actor.apply_intervention("set_goal",{"text":"Help the injured person"}) and actor.profile.goal == "Help the injured person","explicit player goal editing supported")
	check(actor.apply_intervention("set_profile",{"foundation":"Explicit player changed foundation"}),"full god mode can explicitly edit protected foundation")
	check(actor.apply_intervention("set_memory",{"text":"An explicit player's edit","clear":true}) and actor.memory_view().recent.is_empty(),"full god mode can explicitly replace memory")
	var total: float = 0.0
	var low: float = 100.0
	var high: float = 0.0
	for index in 20000:
		var interval: float = actor._draw_review_days()
		total += interval
		low = minf(low,interval)
		high = maxf(high,interval)
	check(low == 1.0 and high == 60.0 and absf(total/20000.0-30.0) < 0.6,"trait opportunities span1–60 days with mean30")
	actor.free()

func _test_demo() -> void:
	for index in 20:
		var actor = Runtime.new()
		actor.configure("person_%d" % index,observation().profile)
		actor.reset(1)
		var raw := observation()
		check(actor.decide_demo(raw).type == "take","all data-driven IDs can take visible food")
		raw.inventory = [{"slot":0,"kind":"ration","label":"ration","quantity":1}]
		raw.self_state.needs.hunger = 60.0
		check(actor.decide_demo(raw).type == "consume","demo actually eats through rules")
		raw.self_state.needs.hunger = 20.0
		raw.self_state.needs.fatigue = 80.0
		check(actor.decide_demo(raw).type == "sleep","demo responds to fatigue")
		raw.self_state.needs.fatigue = 5.0
		raw.self_state.busy = "move_to"
		check(actor.decide_demo(raw).type == "look","demo does not overwrite sustained plan")
		actor.free()
