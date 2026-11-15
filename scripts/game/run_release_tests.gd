extends SceneTree
func _initialize()->void:
	var suite=preload("res://tests/test_release_simulation.gd").new()
	var failures:Array=suite.run()
	for failure in failures:printerr(failure)
	quit(0 if failures.is_empty() else 1)
