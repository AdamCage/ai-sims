extends RefCounted
## Keep completed chunks immutable so an autosave compresses only the suffix.

const CHUNK_BYTES := 512 * 1024
const MAX_CHUNK_BYTES := 8 * 1024 * 1024
const MAX_TOTAL_BYTES := 512 * 1024 * 1024
var initial:Dictionary = {}
var chunks:Array = []
var tail := PackedByteArray()
var images:Dictionary = {}

static func pack(bytes:PackedByteArray) -> Dictionary:
	return {"bytes":bytes.size(),"gzip":Marshalls.raw_to_base64(bytes.compress(FileAccess.COMPRESSION_GZIP))}

static func unpack(part:Variant) -> PackedByteArray:
	if not part is Dictionary or not part.get("gzip") is String:return PackedByteArray()
	var size := int(part.get("bytes",0))
	if size<=0 or size>MAX_CHUNK_BYTES or part.gzip.length()>2*MAX_CHUNK_BYTES:return PackedByteArray()
	var compressed := Marshalls.base64_to_raw(part.gzip)
	if compressed.is_empty():return PackedByteArray()
	var bytes := compressed.decompress(size,FileAccess.COMPRESSION_GZIP)
	return bytes if bytes.size()==size else PackedByteArray()

func begin(state:Dictionary) -> void:
	initial=pack(JSON.stringify(state).to_utf8_buffer())
	chunks=[];tail=PackedByteArray();images={}
	collect_images(state)

func collect_images(value:Variant) -> void:
	if value is Array:
		for child in value:collect_images(child)
	elif value is Dictionary:
		for key in value:
			var child:Variant=value[key]
			if key in ["image_ref","hash"] and child is String and child.length()==64 and child.is_valid_hex_number():
				images[child]=true
			elif child is Array or child is Dictionary:collect_images(child)

func append(line:String, entry:Dictionary) -> void:
	tail.append_array((line+"\n").to_utf8_buffer())
	for patch in entry.patches:
		var child:Variant=patch.get("value")
		if patch.path[-1] in ["image_ref","hash"]:collect_images({str(patch.path[-1]):child})
		else:collect_images(child)
	collect_images(entry.events)
	if tail.size()>=CHUNK_BYTES:
		chunks.append(pack(tail));tail=PackedByteArray()

func snapshot(sequence:int) -> Dictionary:
	var parts:=chunks.duplicate()
	if not tail.is_empty():parts.append(pack(tail))
	var media:Array=[]
	for hash in images:media.append({"hash":hash})
	return {"version":1,"sequence":sequence,"initial":initial,"chunks":parts,"media":media}
