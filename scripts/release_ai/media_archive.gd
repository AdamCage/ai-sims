extends RefCounted
## Exact captured bytes. Only PersonalMemory decides which references an agent
## may retrieve; a file remaining in this observer archive is not agent access.

var directory: String = "user://ai_media"
const WEB_LIMIT_BYTES := 512 * 1024 * 1024
static var _web_directory_sizes: Dictionary = {}
static var _next_collection_ms := 0

func _web_usage() -> int:
	if not _web_directory_sizes.has(directory):
		var size := 0
		var files := DirAccess.open(directory)
		if files != null:
			for name in files.get_files():
				if name.ends_with(".png"):
					var file := FileAccess.open(directory.path_join(name), FileAccess.READ)
					if file != null:
						size += file.get_length()
		_web_directory_sizes[directory] = size
	return int(_web_directory_sizes[directory])

func collect_browser_cache(slot_name:String, latest:String) -> void:
	if not OS.has_feature("web") or Time.get_ticks_msec()<_next_collection_ms or _web_usage()<WEB_LIMIT_BYTES*0.7:return
	_next_collection_ms=Time.get_ticks_msec()+30000
	var bridge:=JavaScriptBridge.get_interface("AISimsWeb")
	var keep:Variant=JSON.parse_string(str(bridge.protectedImages(slot_name,latest)))
	if not keep is Dictionary:return
	# Earlier web versions also wrote Godot fallback slots on the virtual disk.
	var legacy=preload("res://scripts/release_storage/replay_archive.gd").new()
	for slot in range(1,4):
		for suffix in [".json",".json.bak"]:
			var path:="user://release_saves/slot_%d"%slot+str(suffix)
			if not FileAccess.file_exists(path):continue
			var saved:Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
			if not saved is Dictionary or not saved.get("payload") is String:return
			var payload:Variant=JSON.parse_string(saved.payload)
			if not payload is Dictionary:return
			legacy.collect_images(payload)
	keep.merge(legacy.images)
	var files:=DirAccess.open(directory)
	if files==null:return
	var usage:=_web_usage()
	for name in files.get_files():
		var digest:=name.get_basename()
		if name.get_extension()!="png" or not valid_hash(digest) or keep.has(digest):continue
		var file:=FileAccess.open(directory.path_join(name),FileAccess.READ)
		if file==null:continue
		var size:=file.get_length();file.close()
		if files.remove(name)==OK:usage-=size
	_web_directory_sizes[directory]=usage

func store_png(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > 8 * 1024 * 1024:
		return {}
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK or image.get_width() > 4096 or image.get_height() > 4096:
		return {}
	var digest: String = digest_bytes(bytes)
	var path: String = directory.path_join(digest + ".png")
	# A filename is not evidence that an older capture finished writing. Repair
	# a truncated/corrupt entry when the genuine source pixels are available.
	var existing := FileAccess.open(path,FileAccess.READ)
	var existing_size := existing.get_length() if existing != null else 0
	var matches: bool = existing != null and existing.get_length() == bytes.size() and existing.get_buffer(existing.get_length()) == bytes
	if existing != null:
		existing.close()
	if not matches:
		var delta := bytes.size() - existing_size
		if OS.has_feature("web") and _web_usage() + delta > WEB_LIMIT_BYTES:
			var bridge := JavaScriptBridge.get_interface("AISimsWeb")
			if bridge != null: bridge.mediaLimitReached()
			return {}
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory)) != OK:
			return {}
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return {}
		file.store_buffer(bytes)
		if file.get_error() != OK: return {}
		file.close()
		if OS.has_feature("web"): _web_directory_sizes[directory] = _web_usage() + delta
	return {"hash":digest,"mime":"image/png","bytes":bytes.size()}

func retrieve(digest: String) -> PackedByteArray:
	if not valid_hash(digest):
		return PackedByteArray()
	var file := FileAccess.open(directory.path_join(digest + ".png"), FileAccess.READ)
	if file == null or file.get_length() > 8 * 1024 * 1024:
		return PackedByteArray()
	var bytes: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	# Archive hashes are an authority boundary: edited files must never replace
	# a previously granted photograph or immutable visual memory.
	if digest_bytes(bytes) != digest:
		return PackedByteArray()
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK or image.get_width() > 4096 or image.get_height() > 4096:
		return PackedByteArray()
	return bytes

static func digest_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

static func valid_hash(value: Variant) -> bool:
	if not value is String or value.length() != 64:
		return false
	return RegEx.create_from_string("^[0-9a-f]{64}$").search(value) != null
