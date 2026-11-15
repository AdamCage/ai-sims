extends SceneTree

func _initialize() -> void:
	var failures: Array = load("res://tests/test_release_ai.gd").new().run()
	for failure in failures:
		printerr(failure)
	quit(0 if failures.is_empty() else 1)
