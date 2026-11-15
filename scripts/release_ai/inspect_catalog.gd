extends SceneTree
## Optional free public preflight diagnostic. Never loads a key or generates text.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var catalog = load("res://scripts/release_ai/provider_catalog.gd").new()
	root.add_child(catalog)
	catalog.quote_ready.connect(func(_tag,quote):
		print(JSON.stringify(quote))
		quit(0 if quote.get("ok",false) else 1))
	catalog.request_quote("~deepseek/deepseek-v4-flash-latest")
