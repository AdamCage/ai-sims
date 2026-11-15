extends SceneTree

func _initialize() -> void:
	var failures: Array = []
	for path in ["res://tests/test_simulation.gd", "res://tests/test_runtime.gd", "res://tests/test_integration.gd", "res://tests/test_qa.gd"]:
		var script = load(path)
		if script == null or not script.can_instantiate():
			failures.append("Cannot load " + path)
			continue
		var suite = script.new()
		var result: Array = suite.run()
		print("SUITE ", path, " : ", "PASS" if result.is_empty() else "FAIL")
		failures.append_array(result)
	for failure in failures:
		printerr("FAIL: ", failure)
	print("RESULT: ", failures.size(), " failure(s)")
	quit(0 if failures.is_empty() else 1)
