extends RefCounted
## Separate role: it receives only one owner's experience and never actions/world.

const INSTRUCTIONS: String = "You are the separate subjective memory role for one fictional character. " + \
	"Use only the provided personal experience, previous subjective memories and personal profile. " + \
	"Preserve provenance: heard reports are not direct sight. Do not deliberately add false events. " + \
	"You may interpret, prioritise and compress, but cannot access objective truth or other minds. " + \
	"Never change the personality foundation and never issue game actions, diary entries or photos. " + \
	"Return only JSON: {\"episodes\":[{\"text\":string,\"images\":[allowed_image_hash]}]," + \
	"\"semantic_summary\":string,\"traits\":[string]}. Maximum 8 episodes,1600 chars each,2 images each; " + \
	"semantic summary at most6000 chars. Images must come from allowed_images. " + \
	"Keep traits unchanged unless allow_trait_review=true; then at most2 total additions/removals. " + \
	"It is valid to keep the personality unchanged. Never rewrite the recent protected context."

func payload(job: Dictionary, model: String, archive: RefCounted) -> Dictionary:
	var private_job: Dictionary = job.duplicate(true)
	private_job.erase("owner")
	private_job.erase("base_version")
	private_job.erase("consume_ids")
	for entry in private_job.get("entries",[]):
		entry.erase("profile") # Current own profile is already provided once.
	var content: Array = [{"type":"text","text":JSON.stringify(private_job)}]
	var added: int = 0
	for digest in job.get("allowed_images", []):
		if added >= 2:
			break
		var bytes: PackedByteArray = archive.retrieve(str(digest))
		if not bytes.is_empty():
			content.append({"type":"text","text":"Personal past image " + str(digest)})
			content.append({"type":"image_url","image_url":{"url":"data:image/png;base64," + Marshalls.raw_to_base64(bytes)}})
			added += 1
	return {"model":model,"temperature":0.25,"max_tokens":1400,"messages":[{"role":"system","content":INSTRUCTIONS},{"role":"user","content":content}]}

func parse(text: String, job: Dictionary) -> Dictionary:
	if text.length() > 24000:
		return _invalid("Memory response too large")
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return _invalid("Memory response must be JSON")
	var proposal: Dictionary = parser.data
	for key in proposal:
		if not key in ["episodes","semantic_summary","traits"]:
			return _invalid("Memory role attempted an unsupported field")
	if not proposal.get("episodes") is Array or proposal.episodes.size() > 8 or not proposal.get("semantic_summary") is String or proposal.semantic_summary.length() > 6000:
		return _invalid("Invalid subjective layers")
	if proposal.episodes.is_empty() and proposal.semantic_summary.is_empty():
		return _invalid("Empty consolidation cannot discard experience")
	for episode in proposal.episodes:
		if not episode is Dictionary or episode.size() != 2 or not episode.get("text") is String or episode.text.is_empty() or episode.text.length() > 1600 or not episode.get("images") is Array or episode.images.size() > 2:
			return _invalid("Invalid memory episode")
		for image_ref in episode.images:
			if not image_ref is String or not job.allowed_images.has(image_ref):
				return _invalid("Memory attempted to restore inaccessible imagery")
	var traits: Variant = proposal.get("traits", job.profile.traits)
	if not traits is Array or traits.size() > 32:
		return _invalid("Invalid traits")
	var unique: Array = []
	for personality_trait in traits:
		if not personality_trait is String or personality_trait.is_empty() or personality_trait.length() > 120 or unique.has(personality_trait):
			return _invalid("Invalid trait value")
		unique.append(personality_trait)
	var changes: int = 0
	for personality_trait in unique:
		if not job.profile.traits.has(personality_trait):
			changes += 1
	for personality_trait in job.profile.traits:
		if not unique.has(personality_trait):
			changes += 1
	if changes > 2 or (changes > 0 and not bool(job.allow_trait_review)):
		return _invalid("Secondary trait review is not allowed now")
	proposal["traits"] = unique
	return {"ok":true,"proposal":proposal.duplicate(true),"error":""}

func fixture(job: Dictionary) -> Dictionary:
	# Deterministic loss-prioritisation for offline development, labelled as such.
	# All details are copied from personal inputs; no false detail generator.
	var facts: Array[String] = []
	var observant: bool = job.profile.traits.has("observant")
	for entry in job.entries:
		var result: Dictionary = entry.get("last_result", {})
		if result.get("message") is String and not result.message.is_empty():
			facts.append("My action result: " + str(result.message))
		for speech in entry.get("heard", []):
			facts.append("I heard " + str(speech.speaker) + " say: " + str(speech.text))
		for record in entry.get("personal_results", []):
			if not str(record.get("text", "")).is_empty():
				facts.append("Personal " + str(record.get("channel", "experience")) + ": " + str(record.text))
	var keep: int = 12 if observant else 6
	var selected: Array[String] = []
	for fact in facts.slice(maxi(0, facts.size() - keep)):
		selected.append(fact)
	var text: String = ("I remember my own experience. " + " ".join(selected)).left(1600)
	var image_refs: Array = []
	if observant and not job.allowed_images.is_empty():
		image_refs.append(job.allowed_images[-1])
	var semantic: String = ""
	if float(job.now) - float(job.entries[0].minute) > 10080.0:
		semantic = (str(job.previous_semantic) + "\n" + text).right(6000)
	return {"episodes":[{"text":text,"images":image_refs}],"semantic_summary":semantic,"traits":job.profile.traits.duplicate()}

static func _invalid(message: String) -> Dictionary:
	return {"ok":false,"proposal":{},"error":message}
