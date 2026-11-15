extends RefCounted
const Simulation=preload("res://scripts/game/session_simulation.gd")
const Runtime=preload("res://scripts/release_ai/agent_runtime.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
var failures:Array=[]
var checks:=0
func check(condition:bool,message:String)->void:
	checks+=1
	if not condition:failures.append("Integration: "+message)
func run()->Array:
	for map_id in ["closed_block","residence","research_station"]:
		var sim=Simulation.new();sim.reset(map_id,20,"scarcity",17)
		var runtimes:Dictionary={}
		var initial:Dictionary=sim.snapshot()
		for id in initial.agents:
			var runtime=Runtime.new();runtime.configure(id,initial.agents[id].profile);runtime.reset(int(initial.run_id));runtimes[id]=runtime
		var movement:=false
		for cycle in 80:
			for id in sim.state.agents:
				var actor:Dictionary=sim.state.agents[id]
				if not actor.alive or actor.sleeping or actor.unconscious or not actor.busy.is_empty():continue
				var obs:Dictionary=sim.observe(id)
				runtimes[id].observe(obs)
				var intention:Dictionary=runtimes[id].decide_demo(obs)
				var result:Dictionary=sim.submit(id,intention,int(sim.state.run_id))
				check(result.has("ok"),"intention returns defined result")
			sim.advance(1.0)
			for id in sim.state.agents:
				var actor:Dictionary=sim.state.agents[id]
				movement=movement or actor.position!=initial.agents[id].position
				check(float(actor.health)>=0.0 and float(actor.health)<=100.0,"health range")
				check(float(actor.needs.hunger)>=0.0 and float(actor.needs.hunger)<=100.0,"hunger range")
			for item_id in sim.state.items:
				var item:Dictionary=sim.state.items[item_id]
				var holders:=0
				for actor in sim.state.agents.values():holders+=actor.inventory.count(item_id)
				check(holders==(0 if str(item.holder).is_empty() else 1),"inventory bijection for "+str(item_id))
		check(movement,"20-agent episode physically moves: "+map_id)
		check(int(sim.state.tick)==80,"exact logical steps")
		var restored=Simulation.new()
		check(restored.import_state(sim.export_state()),"integrated save remains loadable: "+map_id)
		for runtime in runtimes.values():runtime.free()
	print("Release integration: ",checks," checks; ",failures.size()," failures")
	return failures
