extends RefCounted
## Browser boundary. Secrets stay in the page closure / live GDScript memory.
static var _next_fps_sample := 0
static func is_web() -> bool:
	return OS.has_feature("web")

static func interface() -> JavaScriptObject:
	return JavaScriptBridge.get_interface("AISimsWeb") if is_web() else null

static func ready() -> bool:
	var bridge = interface()
	return bridge != null and bool(bridge.isReady())

static func game_ready() -> void:
	var bridge = interface()
	if bridge != null:bridge.gameReady()

static func has_lease() -> bool:
	var bridge = interface()
	return bridge != null and bool(bridge.hasLease())

static func key() -> String:
	var bridge = interface()
	return str(bridge.getKey()) if bridge != null else ""

static func set_key(value: String) -> bool:
	var bridge = interface()
	return bridge != null and bool(bridge.setKey(value))

static func clear_key() -> bool:
	var bridge = interface()
	return bridge != null and bool(bridge.clearKey())

static func connect_router() -> void:
	var bridge = interface()
	if bridge != null:bridge.connectRouter()

static func status() -> Dictionary:
	var bridge = interface()
	var raw: Variant = JSON.parse_string(str(bridge.getStatus())) if bridge != null else null
	return raw if raw is Dictionary else {}

static func poll_command() -> Dictionary:
	var bridge = interface()
	if bridge == null:return {}
	var now := Time.get_ticks_msec()
	if now >= _next_fps_sample:
		_next_fps_sample = now + 1000
		bridge.frameSample(Engine.get_frames_per_second())
	var text := str(bridge.pollCommand())
	if text.is_empty():return {}
	var raw: Variant = JSON.parse_string(text)
	if raw is Dictionary and raw.get("type") in ["export_image","import_image"]:
		var ok := _transfer_image(bridge,raw)
		bridge.completeCommand(int(raw.get("id",-1)),ok)
		return {}
	return raw if raw is Dictionary else {}

static func _transfer_image(bridge:JavaScriptObject,command:Dictionary) -> bool:
	var archive=preload("res://scripts/release_ai/media_archive.gd").new()
	if command.type=="export_image":
		var digest:=str(command.get("hash",""))
		var bytes:PackedByteArray=archive.retrieve(digest)
		if bytes.is_empty():return false
		bridge.acceptImage(digest,Marshalls.raw_to_base64(bytes))
		return true
	var packet:Variant=JSON.parse_string(str(bridge.restoreImage()))
	if not packet is Dictionary or not archive.valid_hash(packet.get("hash")):return false
	var image_bytes:=Marshalls.base64_to_raw(str(packet.get("data","")))
	if image_bytes.size()<33 or image_bytes.size()>8388608 or archive.digest_bytes(image_bytes)!=packet.hash:return false
	# Validate dimensions before decoding any user-supplied PNG.
	if image_bytes.slice(0,8).hex_encode()!="89504e470d0a1a0a":return false
	for offset in [16,20]:
		var dimension:int=(int(image_bytes[offset])<<24)|(int(image_bytes[offset+1])<<16)|(int(image_bytes[offset+2])<<8)|int(image_bytes[offset+3])
		if dimension<1 or dimension>4096:return false
	return archive.store_png(image_bytes).get("hash","")==packet.hash

static func request_backup() -> void:
	var bridge = interface()
	if bridge != null:bridge.requestBackup()

static func request_import() -> void:
	var bridge = interface()
	if bridge != null:bridge.requestImport()

static func commit_import(contents:Dictionary) -> bool:
	var bridge = interface()
	return bridge != null and bool(bridge.commitImport(JSON.stringify(contents)))

static func save_committed(tree:SceneTree) -> bool:
	if not is_web():return true
	var revision := int(status().get("save_revision",-1))
	var deadline := Time.get_ticks_msec() + 10000
	while revision >= 0 and Time.get_ticks_msec() < deadline:
		var current := status()
		if not bool(current.get("lease",false)) or not str(current.get("storage_error","")).is_empty():return false
		if int(current.get("save_persisted",-1)) >= revision:return true
		await tree.process_frame
	return false

static func complete_command(id: int, ok: bool) -> void:
	var bridge = interface()
	if bridge != null:bridge.completeCommand(id,ok)

static func ledger_json() -> String:
	var bridge = interface()
	return str(bridge.getLedger()) if bridge != null else ""

static func persist_ledger(value: String) -> int:
	var bridge = interface()
	return int(bridge.persistLedger(value)) if bridge != null else -1

static func ledger_revision() -> int:
	return int(status().get("ledger_revision",0))

static func ledger_durable(revision: int) -> bool:
	var state := status()
	return has_lease() and str(state.get("storage_error","")).is_empty() and int(state.get("ledger_persisted",-1)) >= revision

static func slot_json(name: String) -> String:
	var bridge = interface()
	return str(bridge.getSlot(name)) if bridge != null else ""

static func persist_slot(name: String, value: String) -> bool:
	var bridge = interface()
	return bridge != null and int(bridge.persistSlot(name,value)) >= 0

static func imported_save() -> Dictionary:
	var bridge = interface()
	var raw: Variant = JSON.parse_string(str(bridge.takeImport())) if bridge != null else null
	return raw if raw is Dictionary else {}

static func ensure_map_pack(map_id: String, tree: SceneTree) -> bool:
	if not is_web():return true
	var bridge = interface()
	if bridge == null or not has_lease():return false
	bridge.startMapPack(map_id)
	var deadline := Time.get_ticks_msec()+120000
	while Time.get_ticks_msec()<deadline:
		var raw: Variant = JSON.parse_string(str(bridge.packStatus(map_id)))
		if raw is Dictionary and bool(raw.get("done",false)):
			if not str(raw.get("error","")).is_empty():return false
			var path := str(raw.get("path",""))
			return path.is_empty() or ProjectSettings.load_resource_pack(path,false)
		await tree.process_frame
	return false
