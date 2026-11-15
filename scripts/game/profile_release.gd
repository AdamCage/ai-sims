extends SceneTree
func _initialize()->void:
	var sim=preload("res://scripts/game/session_simulation.gd").new()
	sim.reset("research_station",20,"sandbox",1)
	var actors:Dictionary={}
	for id in sim.state.agents:
		var runtime=preload("res://scripts/release_ai/agent_runtime.gd").new()
		runtime.configure(id,sim.state.agents[id].profile)
		runtime.reset(sim.state.run_id)
		actors[id]=runtime
	var observe_us:=0;var action_us:=0;var advance_us:=0
	for cycle in 10:
		for id in actors:
			var start:=Time.get_ticks_usec()
			var observation:Dictionary=sim.observe(id)
			observe_us+=Time.get_ticks_usec()-start
			start=Time.get_ticks_usec()
			var action:Dictionary=actors[id].decide_demo(observation)
			sim.submit(id,action,sim.state.run_id)
			action_us+=Time.get_ticks_usec()-start
		var start:=Time.get_ticks_usec();sim.advance(.5);advance_us+=Time.get_ticks_usec()-start
	print("PROFILE 20 agents x10: observe_ms ",observe_us/1000.0," action_ms ",action_us/1000.0," advance_ms ",advance_us/1000.0)
	for runtime in actors.values():runtime.free()
	quit()
