extends Node
## User-key transport. No endpoint override, redirects or hidden retries.

signal response_ready(token: int, response: Dictionary)
const ENDPOINT: String = "https://routerai.ru/api/v1/chat/completions"
const RECEIPT_ENDPOINT: String = "https://routerai.ru/api/v1/generation?id="
const DEFAULT_MODEL: String = "~deepseek/deepseek-v4-flash-latest"
const WebBridge = preload("res://scripts/release_storage/web_bridge.gd")
var enabled: bool = false
var model: String = DEFAULT_MODEL
var timeout_seconds: float = 30.0
var fixture_response: Callable = Callable()
var _key: String = ""
var _requests: Dictionary = {}
var _provider_only: Array = []
var _generation_parameters: Dictionary = {}

func configure(config: Dictionary) -> void:
	cancel_all()
	_key = str(config.get("key", "")).strip_edges()
	model = str(config.get("model", DEFAULT_MODEL)).strip_edges().left(256)
	if model.is_empty():
		model = DEFAULT_MODEL
	enabled = bool(config.get("enabled", false))
	_provider_only = []
	_generation_parameters = {}
	if config.get("generation_parameters") is Dictionary:
		for parameter in ["reasoning","include_reasoning","response_format"]:
			if config.generation_parameters.has(parameter):
				_generation_parameters[parameter] = config.generation_parameters[parameter]
	if config.get("provider_only") is Array:
		for provider in config.provider_only:
			if provider is String and not provider.is_empty() and provider.length() <= 120:
				_provider_only.append(provider)
	fixture_response = config.get("fixture_response", Callable()) if config.get("fixture_response", Callable()) is Callable else Callable()

func available() -> bool:
	return fixture_response.is_valid() or (enabled and not _key.is_empty() and not _provider_only.is_empty())

func provider_only() -> Array:
	return _provider_only.duplicate()

func is_fixture() -> bool:
	return fixture_response.is_valid()

func send(payload: Dictionary, token: int, role: String, reservation_id: String = "") -> Error:
	if not available():
		return ERR_UNAUTHORIZED
	if fixture_response.is_valid():
		_requests[token] = null
		_emit_fixture.call_deferred(token, payload.duplicate(true), role)
		return OK
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	request.max_redirects = 0
	request.body_size_limit = 2 * 1024 * 1024
	add_child(request)
	_requests[token] = request
	request.request_completed.connect(_completed.bind(token, request, reservation_id))
	var headers := PackedStringArray(["Content-Type: application/json","Authorization: Bearer " + _key])
	var packet: Dictionary = payload.duplicate(true)
	packet["provider"] = {"only":_provider_only.duplicate(),"allow_fallbacks":false}
	packet.merge(_generation_parameters,true)
	if WebBridge.is_web():
		_send_after_durable_reservation(token,request,headers,packet,WebBridge.ledger_revision())
		return OK
	var result: Error = request.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(packet))
	if result != OK:
		_requests.erase(token)
		request.queue_free()
	return result

func _send_after_durable_reservation(token: int, request: HTTPRequest, headers: PackedStringArray, packet: Dictionary, revision: int) -> void:
	# A reserve() call is synchronous; its browser IDB transaction is not. Never
	# dispatch a paid HTTP request until the reservation has committed to disk.
	var deadline := Time.get_ticks_msec()+15000
	while _requests.has(token) and Time.get_ticks_msec()<deadline:
		if not WebBridge.has_lease() or not str(WebBridge.status().get("storage_error","")).is_empty():break
		if WebBridge.ledger_durable(revision):
			var error := request.request(ENDPOINT,headers,HTTPClient.METHOD_POST,JSON.stringify(packet))
			if error!=OK:
				_requests.erase(token);request.queue_free()
				response_ready.emit(token,{"ok":false,"error":"Browser HTTP request could not start","actual_rub":0.0,"currency":"RUB"})
			return
		await get_tree().process_frame
	if _requests.has(token):
		_requests.erase(token);request.queue_free()
		response_ready.emit(token,{"ok":false,"error":"Browser reservation was not durably saved; no paid request sent","actual_rub":0.0,"currency":"RUB"})

func cancel(token: int) -> void:
	if not _requests.has(token):
		return
	var request: Variant = _requests[token]
	if is_instance_valid(request):
		request.cancel_request()
		request.queue_free()
	_requests.erase(token)

func cancel_all() -> void:
	for token in _requests.keys():
		cancel(int(token))

func _emit_fixture(token: int, payload: Dictionary, role: String) -> void:
	if not _requests.has(token):
		return
	_requests.erase(token)
	var raw: Variant = fixture_response.call(payload, role)
	var result: Dictionary = raw if raw is Dictionary else {"ok":false,"error":"invalid_fixture"}
	result["fixture"] = true
	result["actual_rub"] = 0.0
	result["requested_model"] = model
	response_ready.emit(token, result)

func _completed(result: int, status: int, headers: PackedStringArray, body: PackedByteArray, token: int, request: HTTPRequest, reservation_id: String = "") -> void:
	if not _requests.has(token):
		return
	_requests.erase(token)
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or status < 200 or status >= 300:
		var failure: Dictionary = {"ok":false,"error":"RouterAI request failed (%d/%d)" % [result,status],"status":status,"retryable":status == 429 or status >= 500,"actual_rub":-1.0}
		var failure_parser := JSON.new()
		if body.size() <= 2 * 1024 * 1024 and failure_parser.parse(body.get_string_from_utf8()) == OK and failure_parser.data is Dictionary:
			failure.merge(completion_structure(failure_parser.data),true)
		response_ready.emit(token,failure)
		return
	var parsed: Dictionary = parse_completion(body.get_string_from_utf8())
	parsed["requested_model"] = model
	if str(parsed.get("generation_ref","")).is_empty():
		parsed["generation_ref"] = generation_header(headers)
	parsed["quoted_provider"] = ",".join(_provider_only)
	if float(parsed.get("actual_rub",-1.0)) < 0.0 and valid_generation_ref(str(parsed.get("generation_ref",""))):
		if WebBridge.is_web() and not reservation_id.is_empty():
			var bridge = WebBridge.interface()
			if bridge != null:bridge.noteReceipt(reservation_id,str(parsed.generation_ref))
		_begin_receipt(token,parsed)
	else:
		parsed["cost_source"] = "explicit_RUB_response" if float(parsed.get("actual_rub",-1.0)) >= 0.0 else "unknown"
		response_ready.emit(token,parsed)

func _begin_receipt(token: int, parsed: Dictionary) -> void:
	# This is a read-only usage lookup, never a second generation or retry.
	# RouterAI documents total_cost for this endpoint in roubles.
	var request := HTTPRequest.new()
	request.timeout = 5.0
	request.max_redirects = 0
	request.body_size_limit = 1024 * 1024
	add_child(request)
	_requests[token] = request
	request.request_completed.connect(_receipt_completed.bind(token,request,parsed))
	var error: Error = request.request(RECEIPT_ENDPOINT + str(parsed.generation_ref).uri_encode(),
		PackedStringArray(["Accept: application/json","Authorization: Bearer " + _key]),HTTPClient.METHOD_GET)
	if error != OK:
		_requests.erase(token)
		request.queue_free()
		parsed["cost_source"] = "unknown_receipt_unavailable"
		response_ready.emit(token,parsed)

func _receipt_completed(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray, token: int, request: HTTPRequest, parsed: Dictionary) -> void:
	if not _requests.has(token):
		return
	_requests.erase(token)
	request.queue_free()
	var receipt: Dictionary = parse_receipt(body.get_string_from_utf8()) if result == HTTPRequest.RESULT_SUCCESS and status >= 200 and status < 300 else {"ok":false}
	if receipt.ok:
		parsed["actual_rub"] = receipt.actual_rub
		parsed["currency"] = "RUB"
		parsed["cost_source"] = "RouterAI_generation_receipt"
		parsed["provider_name"] = receipt.provider_name
		if not str(receipt.returned_model).is_empty():
			parsed["returned_model"] = receipt.returned_model
		var usage: Dictionary = parsed.get("usage",{}) if parsed.get("usage",{}) is Dictionary else {}
		usage["cost_rub"] = receipt.actual_rub
		usage["currency"] = "RUB"
		for field in ["prompt_tokens","completion_tokens"]:
			if receipt.has(field):
				usage[field] = receipt[field]
		parsed["usage"] = usage
	else:
		parsed["cost_source"] = "unknown_receipt_unavailable"
	response_ready.emit(token,parsed)

static func parse_completion(text: String) -> Dictionary:
	if text.length() > 2 * 1024 * 1024:
		return {"ok":false,"error":"Provider response too large","actual_rub":-1.0}
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return {"ok":false,"error":"Provider returned invalid JSON","actual_rub":-1.0}
	var raw: Dictionary = parser.data
	var usage: Dictionary = raw.get("usage", {}) if raw.get("usage", {}) is Dictionary else {}
	var choices: Variant = raw.get("choices")
	var actual: float = cost_rub(raw, usage)
	var result: Dictionary = {"ok":false,"error":"Provider returned no textual result","usage":usage.duplicate(true),"actual_rub":actual,
		"returned_model":str(raw.get("model","not_disclosed")),"generation_ref":str(raw.get("id",""))}
	result.merge(completion_structure(raw),true)
	var content: String = ""
	if choices is Array and not choices.is_empty() and choices[0] is Dictionary:
		var first: Dictionary = choices[0]
		if first.get("message") is Dictionary:
			var returned: Variant = first.message.get("content")
			if returned is String:
				content = returned
			elif returned is Array:
				var parts: Array[String] = []
				for block in returned:
					if block is Dictionary and block.get("type") in ["text","output_text"] and block.get("text") is String:
						parts.append(block.text)
				content = "\n".join(parts)
		elif first.get("text") is String:
			content = first.text
	if not content.strip_edges().is_empty() and not result.get("has_provider_error",false):
		result.ok = true
		result.error = ""
		result["text"] = content
	elif result.get("has_provider_error",false):
		result.error = str(result.get("provider_error_message","Provider returned an error"))
	elif result.get("finish_reason") == "length" and int(result.get("reasoning_characters",0)) > 0:
		result.error = "Provider exhausted output budget before returning a final JSON action"
	return result

static func completion_structure(raw: Dictionary) -> Dictionary:
	# Structural facts and mapped error categories only. No response content,
	# reasoning text, headers, account bodies or arbitrary provider strings.
	var output := {"choices_count":0,"message_content_type":"absent","finish_reason":"absent",
		"reasoning_characters":0,"tool_calls_count":0,"refusal_present":false,"has_provider_error":false,"provider_error_code":"","provider_error_message":""}
	var error: Variant = raw.get("error")
	var choices: Variant = raw.get("choices")
	if choices is Array:
		output.choices_count = choices.size()
		if not choices.is_empty() and choices[0] is Dictionary:
			var first: Dictionary = choices[0]
			var finish: Variant = first.get("finish_reason")
			if finish is String:
				output.finish_reason = finish if finish in ["stop","length","tool_calls","function_call","content_filter","error","eos","complete"] else "other"
			if first.has("error"):
				error = first.error
			var message: Variant = first.get("message")
			if message is Dictionary:
				if message.has("content"):
					output.message_content_type = type_string(typeof(message.content))
				for field in ["reasoning","reasoning_content"]:
					if message.get(field) is String:
						output.reasoning_characters += message[field].length()
				if message.get("tool_calls") is Array:
					output.tool_calls_count = message.tool_calls.size()
				output.refusal_present = message.get("refusal") is String and not str(message.refusal).is_empty()
				if message.has("error"):
					error = message.error
	if error != null:
		output.has_provider_error = true
		var code: Variant = error.get("code",error.get("type","")) if error is Dictionary else ""
		if code is int or code is float:
			output.provider_error_code = str(code)
		elif code is String and code.length() <= 64 and not code.to_lower().contains("sk-") and RegEx.create_from_string("^[A-Za-z0-9_.:-]*$").search(code) != null:
			output.provider_error_code = code
		var explanation: String = str(error.get("message","")) if error is Dictionary else str(error)
		output.provider_error_message = error_category(explanation)
	var usage: Variant = raw.get("usage")
	if usage is Dictionary and usage.get("completion_tokens_details") is Dictionary:
		var reasoning_tokens: Variant = usage.completion_tokens_details.get("reasoning_tokens")
		if (reasoning_tokens is int or reasoning_tokens is float) and is_finite(float(reasoning_tokens)) and float(reasoning_tokens) >= 0.0:
			output["reasoning_tokens"] = int(reasoning_tokens)
	return output

static func error_category(message: String) -> String:
	var lower: String = message.to_lower().left(2048)
	if lower.contains("image") or lower.contains("vision") or lower.contains("multimodal"):
		return "Provider rejected or failed to process image input"
	if lower.contains("reasoning") or lower.contains("parameter") or lower.contains("unsupported"):
		return "Provider rejected a generation parameter"
	if lower.contains("auth") or lower.contains("api key") or lower.contains("credential"):
		return "Provider authentication failed"
	if lower.contains("quota") or lower.contains("balance") or lower.contains("credit"):
		return "Provider quota or balance unavailable"
	if lower.contains("rate") or lower.contains("429"):
		return "Provider rate limit reached"
	if lower.contains("timeout") or lower.contains("timed out"):
		return "Provider timed out"
	if lower.contains("model"):
		return "Provider reports the selected model unavailable"
	return "Provider returned an upstream error"

static func cost_rub(raw: Dictionary, usage: Dictionary) -> float:
	for container in [usage,raw]:
		for key in ["cost_rub","total_cost_rub"]:
			var value: Variant = container.get(key)
			if (value is int or value is float) and is_finite(float(value)) and float(value) >= 0:
				return float(value)
		var currency: String = str(container.get("currency", "")).to_upper()
		var value: Variant = container.get("cost")
		if currency in ["RUB","RUR","₽"] and (value is int or value is float) and is_finite(float(value)) and float(value) >= 0:
			return float(value)
	# Never silently treat unspecified USD-denominated cost as roubles.
	return -1.0

static func parse_receipt(text: String) -> Dictionary:
	if text.length() > 1024 * 1024:
		return {"ok":false,"error":"Usage receipt too large"}
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return {"ok":false,"error":"Invalid usage receipt"}
	var data: Variant = parser.data.get("data",parser.data)
	if not data is Dictionary:
		return {"ok":false,"error":"Missing usage receipt data"}
	var currency: String = str(data.get("currency","RUB")).to_upper()
	var cost: Variant = data.get("total_cost")
	if currency not in ["RUB","RUR","₽"] or not (cost is int or cost is float) or not is_finite(float(cost)) or float(cost) < 0.0 or float(cost) > 1000000.0:
		return {"ok":false,"error":"Usage receipt has no valid RUB total_cost"}
	var receipt := {"ok":true,"actual_rub":float(cost),"returned_model":str(data.get("model","")),"provider_name":str(data.get("provider_name",""))}
	for pair in [["tokens_prompt","prompt_tokens"],["tokens_completion","completion_tokens"]]:
		var value: Variant = data.get(pair[0])
		if (value is int or value is float) and is_finite(float(value)) and float(value) >= 0:
			receipt[pair[1]] = int(value)
	return receipt

static func generation_header(headers: PackedStringArray) -> String:
	for header in headers:
		var separator: int = header.find(":")
		if separator >= 0 and header.substr(0,separator).strip_edges().to_lower() == "x-generation-id":
			var value: String = header.substr(separator+1).strip_edges()
			return value if valid_generation_ref(value) else ""
	return ""

static func valid_generation_ref(value: String) -> bool:
	return value.length() <= 256 and RegEx.create_from_string("^[A-Za-z0-9_.:-]+$").search(value) != null
