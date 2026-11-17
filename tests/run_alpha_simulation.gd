extends SceneTree
func _initialize()->void:
	var failures:Array=[]
	var paths:Array=["res://tests/test_alpha_simulation.gd"]
	if "--legacy" in OS.get_cmdline_user_args():paths.append("res://tests/test_release_simulation.gd")
	for path in paths:
		var script=load(path)
		if script==null or not script.can_instantiate():quit(1);return
		var suite=script.new()
		failures.append_array(suite.run())
	for failure in failures:printerr("FAIL ",failure)
	quit(0 if failures.is_empty() else 1)
