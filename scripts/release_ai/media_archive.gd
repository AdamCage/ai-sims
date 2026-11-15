extends RefCounted
## Exact captured bytes. Only PersonalMemory decides which references an agent
## may retrieve; a file remaining in this observer archive is not agent access.

var directory: String = "user://ai_media"

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
	var matches: bool = existing != null and existing.get_length() == bytes.size() and existing.get_buffer(existing.get_length()) == bytes
	if existing != null:
		existing.close()
	if not matches:
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory)) != OK:
			return {}
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return {}
		file.store_buffer(bytes)
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
