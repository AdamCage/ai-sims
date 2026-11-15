extends Node
## RouterAI's OpenAI-compatible multimodal endpoint. Disabled by default.
## API reference: https://routerai.ru/docs/guides/overview/multimodal/images

signal response_ready(request_token: int, response: Dictionary)

const DEFAULT_MODEL := "~deepseek/deepseek-v4-flash-latest"
const ENDPOINT := "https://routerai.ru/api/v1/chat/completions"

var enabled: bool = false
var model: String = DEFAULT_MODEL
var timeout_seconds: float = 25.0
var _requests: Dictionary = {}


func _ready() -> void:
	var configured_model: String = OS.get_environment("ROUTERAI_MODEL")
	if not configured_model.is_empty():
		model = configured_model


func available() -> bool:
	return enabled and not OS.get_environment("ROUTERAI_API_KEY").is_empty()


func send_request(payload: Dictionary, request_token: int) -> Error:
	# A key alone is never permission to spend. Only an explicitly enabled
	# adapter can issue a paid call; the default game does not enable it.
	if not available():
		return ERR_UNAUTHORIZED
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	request.max_redirects = 0
	request.body_size_limit = 2 * 1024 * 1024
	add_child(request)
	_requests[request_token] = request
	request.request_completed.connect(_on_completed.bind(request_token, request))
	var headers := PackedStringArray(["Content-Type: application/json",
		"Authorization: Bearer " + OS.get_environment("ROUTERAI_API_KEY")])
	var error: Error = request.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		_requests.erase(request_token)
		request.queue_free()
	return error


func cancel_all() -> void:
	for request in _requests.values():
		if is_instance_valid(request):
			request.cancel_request()
			request.queue_free()
	_requests.clear()


func _on_completed(result: int, status: int, _headers: PackedStringArray,
		body: PackedByteArray, request_token: int, request: HTTPRequest) -> void:
	if not _requests.has(request_token):
		return
	_requests.erase(request_token)
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or status < 200 or status >= 300:
		# Do not retain raw HTTP error bodies: they may contain account details.
		response_ready.emit(request_token, {"ok": false, "error": "RouterAI transport error (%s/%s)" % [result, status]})
		return
	var response: Dictionary = parse_completion(body.get_string_from_utf8())
	response["requested_model"] = model
	response_ready.emit(request_token, response)


static func parse_completion(body_text: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(body_text) != OK or not parser.data is Dictionary:
		return {"ok": false, "error": "RouterAI returned invalid JSON"}
	var parsed: Dictionary = parser.data
	var choices: Variant = parsed.get("choices", [])
	if not choices is Array or choices.is_empty() or not choices[0] is Dictionary:
		return {"ok": false, "error": "RouterAI returned no choices"}
	var message: Variant = choices[0].get("message", {})
	if not message is Dictionary or not message.get("content", null) is String:
		return {"ok": false, "error": "RouterAI returned no textual command"}
	return {"ok": true, "text": message["content"],
		"returned_model": str(parsed.get("model", "not_disclosed")),
		"usage": parsed.get("usage", {}).duplicate(true) if parsed.get("usage", {}) is Dictionary else {}}
