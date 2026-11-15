extends Node
## Free, unauthenticated RouterAI endpoint preflight. No generation calls/key.
## Official units are RUB per pricing_units, not OpenRouter's USD assumptions:
## https://routerai.ru/docs/guides/overview/provider-selection

signal quote_ready(tag: int, quote: Dictionary)
const ROOT: String = "https://routerai.ru/api/v1/models/"
const TTL_SECONDS: int = 900
static var _cache: Dictionary = {}
var _request: HTTPRequest
var _serial: int = 0

func request_quote(model: String, tag: int = 0, provider_preference: String = "", min_valid_seconds: int = 0) -> Error:
	cancel()
	_serial += 1
	var serial: int = _serial
	if not valid_model(model):
		quote_ready.emit.call_deferred(tag,{"ok":false,"error":"Use a plain author/model identifier for tariff preflight"})
		return ERR_INVALID_PARAMETER
	var cached: Dictionary = _cached_quote(model,provider_preference,min_valid_seconds)
	if not cached.is_empty():
		quote_ready.emit.call_deferred(tag,cached)
		return OK
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	_request = HTTPRequest.new()
	_request.timeout = 12.0
	_request.max_redirects = 0
	_request.body_size_limit = 4 * 1024 * 1024
	add_child(_request)
	_request.request_completed.connect(_completed.bind(serial,model,tag,provider_preference))
	var parts: PackedStringArray = model.split("/")
	var address: String = ROOT + parts[0].uri_encode() + "/" + parts[1].uri_encode() + "/endpoints"
	var error: Error = _request.request(address,PackedStringArray(["Accept: application/json"]))
	if error != OK:
		_request.queue_free()
		_request = null
		quote_ready.emit.call_deferred(tag,{"ok":false,"error":"Could not request free tariff catalogue"})
	return error

static func _cached_quote(model: String, provider_preference: String = "", min_valid_seconds: int = 0) -> Dictionary:
	var cache_key: String = model + "|" + provider_preference
	if not _cache.has(cache_key) or not _cache[cache_key] is Dictionary:return {}
	var expiry: Variant = _cache[cache_key].get("expires_at")
	if not (expiry is int or expiry is float) or not is_finite(float(expiry)):return {}
	if float(expiry)<=Time.get_unix_time_from_system()+maxi(0,min_valid_seconds):return {}
	return _cache[cache_key].duplicate(true)

func cancel() -> void:
	_serial += 1
	if is_instance_valid(_request):
		_request.cancel_request()
		_request.queue_free()
	_request = null

func _completed(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray, serial: int, model: String, tag: int, provider_preference: String) -> void:
	if serial != _serial:
		return
	if is_instance_valid(_request):
		_request.queue_free()
	_request = null
	if result != HTTPRequest.RESULT_SUCCESS or status < 200 or status >= 300:
		quote_ready.emit(tag,{"ok":false,"error":"Free RouterAI tariff preflight failed (%d/%d)" % [result,status]})
		return
	var quote: Dictionary = parse_quote(body.get_string_from_utf8(),model,provider_preference)
	if quote.ok:
		_cache[model + "|" + provider_preference] = quote.duplicate(true)
	quote_ready.emit(tag,quote)

static func parse_quote(text: String, model: String, provider_preference: String = "") -> Dictionary:
	if text.length() > 4 * 1024 * 1024 or not valid_model(model):
		return _bad("Invalid catalogue input")
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return _bad("Catalogue is not valid JSON")
	return quote_from_catalog(parser.data,model,provider_preference)

static func quote_from_catalog(raw: Dictionary, model: String, provider_preference: String = "") -> Dictionary:
	var data: Variant = raw.get("data",raw)
	if not data is Dictionary or not data.get("architecture") is Dictionary or not data.get("endpoints") is Array:
		return _bad("Catalogue does not describe model endpoints")
	if str(data.get("currency","RUB")).to_upper() not in ["RUB","RUR","₽"]:
		return _bad("Catalogue currency is not RUB")
	var modalities: Variant = data.architecture.get("input_modalities")
	var output: Variant = data.architecture.get("output_modalities")
	if not modalities is Array or not modalities.has("image") or not output is Array or not output.has("text"):
		return _bad("Selected model does not declare image input and text output")
	var chosen: Dictionary = {}
	var best: float = INF
	var best_vision_declaration: int = -1
	for raw_endpoint in data.endpoints:
		if not raw_endpoint is Dictionary:
			continue
		var endpoint: Dictionary = raw_endpoint
		var status: Variant = endpoint.get("status",0)
		if not (status is int or status is float) or not is_finite(float(status)) or float(status) < 0 or not endpoint.get("tag") is String or endpoint.tag.is_empty() or endpoint.tag.length() > 120:
			continue
		if not provider_preference.is_empty() and endpoint.tag != provider_preference:
			continue
		var parameters: Variant = endpoint.get("supported_parameters",[])
		if not parameters is Array or not parameters.has("max_tokens"):
			continue
		var endpoint_modalities: Variant = endpoint.get("input_modalities",[])
		if endpoint.get("architecture") is Dictionary:
			endpoint_modalities = endpoint.architecture.get("input_modalities",endpoint_modalities)
		if endpoint_modalities is Array and not endpoint_modalities.is_empty() and not endpoint_modalities.has("image"):
			continue
		if not endpoint.get("pricing") is Dictionary or not endpoint.get("pricing_units") is Dictionary:
			continue
		var pricing: Dictionary = endpoint.pricing
		var units: Dictionary = endpoint.pricing_units
		if units.get("prompt") != "token" or units.get("completion") != "token":
			continue
		var prompt: float = _price(pricing.get("prompt"))
		var completion: float = _price(pricing.get("completion"))
		if prompt < 0.0 or completion < 0.0:
			continue
		var variable: Variant = endpoint.get("variable_pricings",[])
		if variable is Array:
			for band in variable:
				if band is Dictionary:
					prompt = maxf(prompt,_price(band.get("prompt")))
					completion = maxf(completion,_price(band.get("completion")))
		var request_cost: float = 0.0
		if units.get("request") == "request":
			request_cost = maxf(0.0,_price(pricing.get("request")))
		var image_token_cost: float = 0.0
		var image_cost: float = 0.0
		if pricing.has("image"):
			if units.get("image") == "token":
				image_token_cost = maxf(0.0,_price(pricing.image))
			elif units.get("image") == "image":
				image_cost = maxf(0.0,_price(pricing.image))
			elif _price(pricing.image) > 0.0:
				continue # An unknown non-zero unit cannot be safely estimated.
		if units.get("internal_reasoning") == "token":
			completion += maxf(0.0,_price(pricing.get("internal_reasoning")))
		var maximum: Variant = endpoint.get("max_completion_tokens",0)
		var context_size: Variant = endpoint.get("context_length",0)
		if not (maximum is int or maximum is float) or not is_finite(float(maximum)) or float(maximum) < 1400 or not (context_size is int or context_size is float) or not is_finite(float(context_size)) or float(context_size) < 16000:
			continue
		var score: float = 16000.0 * prompt + 1400.0 * completion + request_cost + 2.0 * (8192.0 * image_token_cost + image_cost)
		var vision_declaration: int = 1 if endpoint_modalities is Array and endpoint_modalities.has("image") else 0
		if vision_declaration > best_vision_declaration or (vision_declaration == best_vision_declaration and score < best):
			best = score
			best_vision_declaration = vision_declaration
			var generation_parameters: Dictionary = {}
			if parameters.has("response_format"):
				generation_parameters["response_format"] = {"type":"json_object"}
			if model.contains("deepseek/deepseek-v4") and parameters.has("reasoning"):
				generation_parameters["reasoning"] = {"effort":"none"}
			if parameters.has("include_reasoning"):
				generation_parameters["include_reasoning"] = false
			chosen = {"ok":true,"model":model,"model_name":str(data.get("name",model)),
				"provider_only":[endpoint.tag],"provider_name":str(endpoint.get("provider_name",endpoint.tag)),
				"input_rub_per_million":prompt * 1000000.0,"output_rub_per_million":completion * 1000000.0,
				"request_rub":request_cost,"image_rub_per_token":image_token_cost,"image_rub":image_cost,"image_token_reserve":8192,
				"context_length":int(endpoint.get("context_length",0)),"max_completion_tokens":int(maximum),
				"supports_images":true,"endpoint_image_support":"endpoint_declared" if endpoint_modalities is Array and endpoint_modalities.has("image") else "model_declared_endpoint_unverified",
				"generation_parameters":generation_parameters,"currency":"RUB","pricing_basis":"worst_published_variable_RUB_per_token",
				"checked_at":int(Time.get_unix_time_from_system()),"expires_at":int(Time.get_unix_time_from_system()) + TTL_SECONDS,
				"source":"https://routerai.ru/api/v1/models/" + model + "/endpoints"}
	if chosen.is_empty():
		return _bad("No active image-capable endpoint has supported RUB token pricing and action/memory limits")
	return chosen

static func valid_model(value: String) -> bool:
	return value.length() <= 200 and RegEx.create_from_string("^[A-Za-z0-9~._:-]+/[A-Za-z0-9._:-]+$").search(value) != null and not value.contains("..")

static func _price(value: Variant) -> float:
	var parsed: float = -1.0
	if value is int or value is float:
		parsed = float(value)
	elif value is String and value.is_valid_float():
		parsed = value.to_float()
	return parsed if is_finite(parsed) and parsed >= 0.0 and parsed <= 1000000.0 else -1.0

static func _bad(error: String) -> Dictionary:
	return {"ok":false,"error":error}
