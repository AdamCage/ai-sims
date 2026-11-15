extends RefCounted
## Reserved integration points, deliberately unavailable in first-slice gameplay.
## An extension must return a proposal; only WorldSimulation may commit it.

const SUPPORTED := false

static func terminal_request(_actor: String, _operation: String, _request: Dictionary) -> Dictionary:
	return _deferred("terminal issuance and queue")

static func network_request(_actor: String, _operation: String, _request: Dictionary) -> Dictionary:
	# Future operations: send, deliver, read, delay, delete, replace.
	# Original server version and delivered version must remain separate.
	return _deferred("network messages and intervention permissions")

static func device_request(_actor: String, _operation: String, _request: Dictionary) -> Dictionary:
	return _deferred("devices, diary and photo artifacts")

static func _deferred(feature: String) -> Dictionary:
	return {"ok":false,"reason":"not_implemented","feature":feature,"world_changes":[]}
