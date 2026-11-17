extends RefCounted
## Windows Credential Manager. No secrets in settings, save files or argv.
const BINARY = "res://assets/release/bin/credential_bridge.exe"
const WebBridge = preload("res://scripts/release_storage/web_bridge.gd")

func _binary_path() -> String:
	if OS.get_name() != "Windows" or not FileAccess.file_exists(BINARY):
		return ""
	var source := FileAccess.get_file_as_bytes(BINARY)
	var folder := ProjectSettings.globalize_path("user://bin")
	DirAccess.make_dir_recursive_absolute(folder)
	# Versioned names also permit a new game build while another process holds
	# the previous helper open for its monetary-ledger lease.
	var target := folder.path_join("credential_bridge-"+FileAccess.get_sha256(BINARY).left(16)+".exe")
	if not FileAccess.file_exists(target) or FileAccess.get_sha256(target) != FileAccess.get_sha256(BINARY):
		var output := FileAccess.open(target, FileAccess.WRITE)
		if output == null:
			return ""
		output.store_buffer(source)
		output.close()
	return target

func helper_path() -> String:
	return _binary_path()

func _call(operation: String, secret: String = "", testing: bool = false) -> Dictionary:
	var binary := _binary_path()
	if binary.is_empty():
		return {"ok":false,"value":"","error":"Windows Credential Manager unavailable"}
	var args := PackedStringArray([operation])
	if testing:
		args.append("test")
	var child := OS.execute_with_pipe(binary, args, true)
	if child.is_empty():
		return {"ok":false,"value":"","error":"Credential helper could not start"}
	var pipe: FileAccess = child.stdio
	if operation == "put":
		pipe.store_line(Marshalls.utf8_to_base64(secret))
		pipe.flush()
	var response := pipe.get_line()
	pipe.close()
	if child.has("stderr"):
		child.stderr.close()
	if not response.begins_with("OK:"):
		return {"ok":false,"value":"","error":"Credential operation failed"}
	return {"ok":true,"value":Marshalls.base64_to_utf8(response.trim_prefix("OK:")) if operation == "get" and response.length()>3 else "","error":""}

func save_key(key: String) -> bool:
	if WebBridge.is_web():return WebBridge.set_key(key)
	return bool(_call("put", key).ok)

func load_key() -> String:
	if WebBridge.is_web():return WebBridge.key()
	var result := _call("get")
	return str(result.value) if result.ok else ""

func delete_key() -> bool:
	if WebBridge.is_web():return WebBridge.clear_key()
	return bool(_call("delete").ok)

func self_test() -> bool:
	if WebBridge.is_web():return WebBridge.ready() and WebBridge.has_lease()
	var sentinel := "ai-sims-local-test-"+str(Time.get_ticks_usec())
	var written := _call("put", sentinel, true)
	var retrieved := _call("get", "", true)
	_call("delete", "", true)
	return written.ok and retrieved.ok and retrieved.value == sentinel
