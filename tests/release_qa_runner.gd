extends SceneTree
func _initialize()->void:
	if "--all-novault" in OS.get_cmdline_user_args():
		var all_failures:Array=[]
		# Credential-store self-test belongs to the root's storage acceptance.
		# This runner explicitly performs no vault operations or provider calls.
		for path in ["res://tests/test_release_simulation.gd","res://tests/test_release_ai.gd","res://tests/test_release_integration.gd","res://tests/test_release_qa.gd"]:
			var suite=load(path).new();var result:Array=suite.run();all_failures.append_array(result)
			print("NOVault SUITE ",path," ","PASS" if result.is_empty() else "FAIL")
		for failure in all_failures:printerr(failure)
		quit(0 if all_failures.is_empty() else 1);return
	if "--diagnose" in OS.get_cmdline_user_args():
		var sim=preload("res://scripts/game/session_simulation.gd").new()
		sim.reset("closed_block",20,"scarcity",13)
		print("DIAG services ",sim._valid_services(sim.state)," JSON ",sim._json_value(sim.state))
		for actor in sim.state.agents.values():
			print("DIAG actor ",actor.id," ",sim._valid_actor_details(actor,sim.state.agents))
	if "--json-diagnose" in OS.get_cmdline_user_args():
		var sim=preload("res://scripts/game/session_simulation.gd").new()
		var suite=preload("res://tests/test_release_qa.gd").new()
		for i in 12:sim.advance(5.0)
		var actual:Dictionary=sim.snapshot();var restored:Dictionary=JSON.parse_string(JSON.stringify(actual))
		print("JSON equality ",actual==restored," semantic difference: ",suite._qa_difference(actual,restored))
		quit();return
	var suite=preload("res://tests/test_release_qa.gd").new()
	var failures:Array
	if "--soak" in OS.get_cmdline_user_args():failures=suite.run_soak()
	elif "--gameplay" in OS.get_cmdline_user_args():failures=suite.run_gameplay_acceptance()
	else:failures=suite.run()
	for failure in failures:printerr(failure)
	quit(0 if failures.is_empty() else 1)
