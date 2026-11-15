extends SceneTree
func _initialize()->void:
	var failures:Array=[]
	for path in ["res://tests/test_release_simulation.gd","res://tests/test_release_ai.gd","res://tests/test_release_storage.gd","res://tests/test_release_integration.gd","res://tests/test_release_qa.gd"]:
		var script=load(path)
		if script==null or not script.can_instantiate():failures.append("Cannot load "+path);continue
		var suite=script.new();var result:Array=suite.run()
		print("SUITE ",path," ","PASS" if result.is_empty() else "FAIL");failures.append_array(result)
	for failure in failures:printerr("FAIL ",failure)
	print("RELEASE RESULT: ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
